"""Build and run ONE sandboxed native console. No mode or model runs by default."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import threading
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from launcher.backend import Console,server
from portable.preflight import check

def configure():
    settings=ROOT/'.runtime/launcher-settings.json'
    data=json.loads(settings.read_text()) if settings.exists() else {}
    def relative(value):
        path=Path(value);return (ROOT/path).resolve() if not path.is_absolute() else path
    if data.get('nodeDirectory'):os.environ['PATH']=str(relative(data['nodeDirectory']))+os.pathsep+os.environ.get('PATH','/usr/bin:/bin')
    return relative(data.get('toolsDirectory','../tools'))

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--self-test',action='store_true');p.add_argument('--check',action='store_true');p.add_argument('--ui-test',action='store_true');p.add_argument('--tools-dir',type=Path);p.add_argument('--action',choices=['apple','besu','mock'],help='Headless explicit local job, never cloud')
    a=p.parse_args();configured=configure();tools=a.tools_dir.resolve() if a.tools_dir else configured
    if a.self_test:
        return subprocess.call([sys.executable,'-B','-m','unittest','discover','-s','tests','-p','test_launcher.py','-v'],cwd=str(ROOT))
    if a.check:
        report=check(tools);print(json.dumps(report,indent=2));return 0 if report['ready'] else 2
    console=Console(tools)
    if a.action:
        console.request(a.action)
        while console.snapshot()['phase']=='running':threading.Event().wait(.2)
        value=console.snapshot();print(json.dumps(value,indent=2));return 0 if value['jobs'][a.action]['status'] in ('passed','verified') else 2
    token=secrets.token_urlsafe(32);http=server(console,token)
    worker=threading.Thread(target=http.serve_forever,daemon=True);worker.start()
    try:
        from native.Console.build import build
        app=build({'endpoint':'http://127.0.0.1:'+str(http.server_port),'capability':token})
        # Execute our new app only; no existing key-entry window is activated or inspected.
        command=[str(app/'Contents/MacOS/Console')]+(['--ui-test'] if a.ui_test else [])
        return subprocess.call(command,env={k:v for k,v in os.environ.items() if k in ('HOME','PATH','TMPDIR','LANG','LC_ALL')})
    finally:http.shutdown();http.server_close()
if __name__=='__main__':
    try:sys.exit(main())
    except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as e:print('VAPE console stopped; no fallback: '+str(e),file=sys.stderr);sys.exit(1)
