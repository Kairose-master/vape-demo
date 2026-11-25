"""Actual Apple + actual isolated Besu; no GUI, clipboard, OpenAI or existing server access."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import threading
import uuid
from vape.unified_ledger.helper import serve, VerifiedInput

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--tools-dir',type=Path,required=True);a=parser.parse_args()
    root=Path(__file__).resolve().parents[2];run=root/'.runtime'/('unified-check-'+uuid.uuid4().hex);run.mkdir(parents=True,mode=0o700)
    sys.path.insert(0,str(root/'native/scripts'))
    from build_support import discover_tools,compiler_flags,module_cache
    swift,sdk=discover_tools();flags=compiler_flags(swift,sdk,module_cache(root,'selected-flow'))
    common=['Classification/FileRegistry.swift','SelectedFlow/PrivateModelHandoff.swift','UnifiedLedger/Evidence.swift']
    verifier=run/'Verify';probe=run/'Probe'
    subprocess.run(flags+[str(root/'native'/p) for p in common+['UnifiedLedger/Verify.swift']]+['-o',str(verifier)],check=True)
    subprocess.run(flags+[str(root/'native'/p) for p in common+['Classification/PrivateRegistryStore.swift','SelectedFlow/AppleLocalModel.swift','UnifiedLedger/Probe.swift']]+['-o',str(probe)],check=True)
    stop=threading.Event();worker=threading.Thread(target=serve,args=(verifier,run/'exchange',a.tools_dir,stop));worker.start()
    try:
        result=subprocess.run([str(probe),str(run)],capture_output=True,text=True,timeout=160)
        print(result.stdout,flush=True)
        if result.returncode:raise RuntimeError('Native probe failed')
        worker.join(timeout=180)
        summary=json.loads((run/'exchange/result.json').read_text())
        if summary['status']!='verified':raise RuntimeError('Chain not verified')
        print(json.dumps(summary,indent=2),flush=True)
        identity=json.loads((run/'exchange/identity.json').read_text())
        original=json.loads((run/'exchange/package.json').read_text())
        for name,change in [('missing',lambda x:x['events'].pop()),('policy',lambda x:x['policy'].update(version=2))]:
            import copy
            altered=copy.deepcopy(original);change(altered);p=run/(name+'.json');p.write_text(json.dumps(altered))
            try:VerifiedInput(verifier,p,identity).verify_roots()
            except ValueError:pass
            else:raise RuntimeError('Altered evidence accepted')
        try:VerifiedInput(verifier,run/'exchange/package.json',dict(identity,runID=str(uuid.uuid4()))).verify_roots()
        except ValueError:pass
        else:raise RuntimeError('Wrong run accepted')
        serialized=(run/'exchange/package.json').read_text()
        import base64
        metadata=' '.join(base64.b64decode(e['metadata']).decode() for e in [original['plan'],*original['events'],original['checkpoint']])
        assert all(s not in serialized+metadata for s in ['fictional library','/Users/','synthetic.txt','Authorization','sk-'])
        print('PASS: actual Apple + Besu; tampered/missing/policy/wrong-run rejected; metadata redacted. Evidence: '+str(run),flush=True)
    finally:stop.set();worker.join(timeout=30)
if __name__=='__main__':main()
