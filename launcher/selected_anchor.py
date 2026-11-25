"""Metadata-only selected-file anchor. The pinned verifier runs before any chain work."""
import copy
import contextlib
import io
import json
import subprocess
import threading
from pathlib import Path
from vape.ledger.local_exercise import run

class SelectedAnchor:
    def __init__(self, verifier, tools, runner=run):
        self.verifier=Path(verifier);self.tools=tools;self.runner=runner
        self.public_key=None;self.used=set();self.lock=threading.Lock()
    def pin(self, value):
        import base64
        if set(value)!={'publicKey'} or len(base64.b64decode(value['publicKey'],validate=True))!=32:
            raise ValueError('Invalid identity')
        with self.lock:
            if self.public_key not in (None,value['publicKey']):raise ValueError('Identity changed')
            self.public_key=value['publicKey']
        return {'status':'pinned','trust':'local native producer; not external attestation'}
    def verify(self, package):
        if not self.public_key:raise ValueError('Identity not pinned')
        raw=json.dumps({'publicKey':self.public_key,'package':package}).encode()
        if len(raw)>65536:raise ValueError('Evidence exceeds limit')
        p=subprocess.run([str(self.verifier)],input=raw,capture_output=True,timeout=10)
        if p.returncode:raise ValueError('Signed evidence invalid')
        result=json.loads(p.stdout)
        if result.get('status')!='verified':raise ValueError('Unverified evidence')
        return result
    def anchor(self, package):
        package=copy.deepcopy(package);roots=self.verify(package)
        with self.lock:
            if roots['runID'] in self.used:raise ValueError('Already consumed; no retry')
            self.used.add(roots['runID'])
        owner=self
        class Input:
            def verify_roots(self):
                fresh=owner.verify(package)
                if fresh!=roots:raise ValueError('Evidence changed')
                return fresh
        with contextlib.redirect_stdout(io.StringIO()):
            chain=self.runner(tools_dir=self.tools,native_input=Input())
        if chain['status']!='passed' or not chain['nodeStopped'] or not chain['independentRead']['valid'] or chain['nativeEvidence']!=roots:
            raise ValueError('Chain verification failed')
        result=dict(roots,transaction=chain['rootTransaction'],block=chain['rootBlock'],chainId=chain['chainId'],
                    verifiedAt=chain['independentReadAt'],nodeStopped=True,independentRead=True,
                    chain='real-private-local-besu',scope='same selected file revision and local execution; roots only on chain')
        # Persist only verified metadata next to this isolated verifier, never content/keys.
        target=self.verifier.parent/('selected-anchor-'+roots['runID']+'.json')
        with target.open('x') as stream:json.dump(result,stream,indent=2)
        target.chmod(0o600)
        return result
