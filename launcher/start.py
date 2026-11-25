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
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--self-test',action='store_true');p.add_argument('--check',action='store_true');p.add_argument('--ui-test',action='store_true');p.add_argument('--gui-qa',action='store_true');p.add_argument('--tools-dir',type=Path);p.add_argument('--action',choices=['apple','besu','mock'],help='Headless explicit local job, never cloud')
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
        app=build({'endpoint':'http://127.0.0.1:'+str(http.server_port),'capability':token,'qa':'true' if a.ui_test or a.gui_qa else 'false'})
        from launcher.selected_anchor import SelectedAnchor
        console.selected_anchor=SelectedAnchor(app.parent/'SelectedVerifier',tools)
        helper=app.parent/'VAPE File Registry.app/Contents/MacOS/FilePipeline'
        if a.ui_test:
            subprocess.run([str(helper),'--self-test'],check=True,env=__import__('demo').environment())
            from native.scripts.check_file_bridge import check as check_file_bridge
            check_file_bridge(helper,env=__import__('demo').environment())
        to_read,to_write=os.pipe();from_read,from_write=os.pipe()
        file_process=subprocess.Popen([str(helper),'--bridge']+(['--qa'] if a.ui_test or a.gui_qa else []),stdin=to_read,stdout=from_write,stderr=subprocess.DEVNULL,env=__import__('demo').environment())
        os.close(to_read);os.close(from_write)
        command=[str(app/'Contents/MacOS/Console'),'--file-read-fd',str(from_read),'--file-write-fd',str(to_write)]+(['--ui-test'] if a.ui_test else [])+(['--gui-qa'] if a.gui_qa else [])
        try:
            ui=subprocess.Popen(command,pass_fds=(from_read,to_write),env=__import__('demo').environment())
            os.close(from_read);os.close(to_write)
            return ui.wait()
        finally:
            try:file_process.wait(timeout=3)
            except subprocess.TimeoutExpired:file_process.terminate();file_process.wait(timeout=5)
    finally:http.shutdown();http.server_close()
if __name__=='__main__':
    try:sys.exit(main())
    except (OSError,ValueError,RuntimeError,subprocess.SubprocessError) as e:print('VAPE console stopped; no fallback: '+str(e),file=sys.stderr);sys.exit(1)
