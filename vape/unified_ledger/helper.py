"""No HTTP listener or document access. Reads only its new app's metadata exchange."""
import contextlib
import copy
import io
import json
from pathlib import Path
import subprocess
import time
from vape.ledger.local_exercise import run

class VerifiedInput:
    def __init__(self, verifier, package, identity):
        self.verifier, self.package, self.identity = verifier, Path(package), identity
    def verify_roots(self):
        if self.package.is_symlink() or self.package.stat().st_size > 65536:
            raise ValueError('Invalid evidence file')
        result = subprocess.run([str(self.verifier), str(self.package), self.identity['publicKey'], self.identity['runID']], capture_output=True, text=True)
        if result.returncode:
            raise ValueError('Signed evidence indeterminate')
        value = json.loads(result.stdout)
        if value.get('status') != 'verified' or value.get('runID') != self.identity['runID']:
            raise ValueError('Binding indeterminate')
        return value

def anchor(verifier, directory, identity, tools):
    directory=Path(directory)
    source=VerifiedInput(verifier,directory/'package.json',identity)
    roots=source.verify_roots()  # BEFORE tools/node/RPC
    bad=copy.deepcopy(json.loads(source.package.read_text()))
    bad['events'][0]['signature']='AA=='
    altered=directory/'tampered-copy.json'
    with altered.open('x') as out:json.dump(bad,out)
    try:VerifiedInput(verifier,altered,identity).verify_roots()
    except ValueError:pass
    else:raise ValueError('Tampered evidence accepted')
    # Existing vetted driver pins genesis, validator, writer, deployed contract/code,
    # checks mined receipt, and opens a separate reader connection; only own node stopped.
    with contextlib.redirect_stdout(io.StringIO()): result=run(tools_dir=tools,native_input=source)
    if result['status']!='passed' or not result['independentRead']['valid'] or result['nativeEvidence']!=roots or not result['nodeStopped']:
        raise ValueError('Chain verification indeterminate')
    return dict(status='verified',runID=roots['runID'],resourceID=roots['resourceID'],
                policyRoot=roots['policyRoot'],executionRoot=roots['executionRoot'],
                block=result['rootBlock'],transaction=result['rootTransaction'],verifiedAt=result['independentReadAt'],
                tamperedCopy='invalid',currentChain='offline-owned-node-stopped',chainId=result['chainId'],contract=result['contract'])

def serve(verifier,directory,tools,stop):
    directory=Path(directory)
    while not stop.is_set() and not (directory/'identity.json').exists():stop.wait(.2)
    if stop.is_set():return
    # Pin signer identity once, before the user can start the explicit one-shot demo.
    # Same-UID local operator trust; not remote attestation or a CA identity.
    identity=json.loads((directory/'identity.json').read_text())
    with (directory/'ready.json').open('x') as out:json.dump({'runID':identity['runID']},out)
    while not stop.is_set() and not (directory/'package.json').exists():stop.wait(.2)
    if stop.is_set():return
    try:result=anchor(verifier,directory,identity,tools)
    except Exception:result={'status':'indeterminate','runID':identity['runID'],'retryAutomatically':False}
    temp=directory/'result.tmp'
    temp.write_text(json.dumps(result));temp.chmod(0o600);temp.rename(directory/'result.json')
