#!/usr/bin/env python3
"""VAPE private source demo: no-key mock core by default, optional modes explicitly selected."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent

def environment():
    result = {key: os.environ[key] for key in ('PATH','HOME','TMPDIR','TMP','TEMP','SYSTEMROOT','WINDIR','LANG','LC_ALL') if key in os.environ}
    result['PYTHONDONTWRITEBYTECODE'] = '1'
    # This launcher never consumes a cloud credential. Optional native UI owns key entry.
    return result

def copy_source(destination):
    names = json.loads((ROOT / 'portable/files.json').read_text())
    for name in names:
        source = ROOT / name
        if source.is_symlink() or not source.is_file():
            raise RuntimeError('Source manifest file missing or unsafe: ' + name)
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)

def core(ready_file=None):
    from vape.server import Application, create_server
    with tempfile.TemporaryDirectory(prefix='vape-core-') as directory:
        app = Application(Path(directory) / 'synthetic-session')
        server = None
        try:
            server = create_server(app, 0)
            if server.server_port == 8765:
                raise RuntimeError('Reserved port selected; stop without serving')
            url = 'http://127.0.0.1:%d' % server.server_port
            if ready_file:
                with Path(ready_file).open('x') as handle:
                    json.dump({'url':url,'pid':os.getpid(),'session':app.session}, handle)
            print('VAPE 키 없는 모의 데모 — 실제 AI·Cloud·체인 아님', flush=True)
            print(url, flush=True)
            print('브라우저에서 주소를 여세요. 종료: Ctrl-C. 이 실행의 임시 자료만 정리합니다.', flush=True)
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            if server:
                server.server_close()
            app.close()

def self_test():
    patterns = ['test_contracts.py','test_policy_service.py','test_audit_service.py',
                'test_execution_outcomes.py','test_integration_boundary.py','test_ui.py','test_ui_http.py','test_unified_ledger.py','test_portable_preflight.py']
    for pattern in patterns:
        subprocess.run([sys.executable,'-B','-m','unittest','discover','-s','tests','-p',pattern],
                       cwd=str(ROOT), env=environment(), check=True)
    # Exercise the public entrypoint on its own fresh port, never an existing server.
    with tempfile.TemporaryDirectory(prefix='vape-http-test-') as directory:
        ready = Path(directory) / 'ready.json'
        process = subprocess.Popen([sys.executable,'-B',str(ROOT/'demo.py'),'--ready-file',str(ready)],
                                   cwd=str(ROOT), env=environment(), stdout=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 15
            while not ready.exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('Isolated core did not start')
                time.sleep(0.05)
            # Readiness is written only by this child; allow an in-progress JSON write to finish.
            while True:
                try:
                    record = json.loads(ready.read_text()); break
                except json.JSONDecodeError:
                    if time.monotonic() > deadline: raise
                    time.sleep(0.01)
            env = environment()
            env.update(VAPE_TEST_BASE=record['url'], VAPE_TEST_READY=str(ready), VAPE_TEST_PID=str(process.pid))
            subprocess.run([sys.executable,'-B','-m','unittest','discover','-s','acceptance','-v'],
                           cwd=str(ROOT),env=env,check=True,timeout=90)
        finally:
            # Only our child, graceful interrupt lets it clean its own TemporaryDirectory.
            import signal
            if process.poll() is None:
                process.terminate() if os.name == 'nt' else process.send_signal(signal.SIGINT)
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate(); process.wait(timeout=5)
    print('PASS no-key core: policy, audit, UI contracts and isolated HTTP acceptance; all destinations MOCK')

def optional(mode, tools_dir):
    if mode in ('preflight','unified','unified-check'):
        command=[sys.executable,'-B',str(ROOT/'portable/preflight.py')]
        if tools_dir:command += ['--tools-dir',str(Path(tools_dir).resolve())]
        subprocess.run(command,cwd=str(ROOT),env=environment(),check=True)
        if mode == 'preflight':return
    if mode != 'besu' and sys.platform != 'darwin':
        raise RuntimeError('Native modes require macOS; use the no-key mock core on this platform')
    if mode == 'besu' and not tools_dir:
        raise RuntimeError('Besu is separate: supply pre-existing verified tools with --tools-dir; no download attempted')
    # Retain optional app outputs so an open app is never deleted when its launcher exits.
    directory = Path(tempfile.mkdtemp(prefix='vape-optional-')) / 'Source With Spaces'
    directory.mkdir(); copy_source(directory)
    print('새 독립 임시 소스/출력: ' + str(directory), flush=True)
    if mode in ('native','apple','unified'):
        command = [sys.executable,'-B','-m','vape.selected_flow.launch']
        if mode in ('apple','unified'): command.append('--apple-local')
        if mode == 'unified':command += ['--unified-ledger','--tools-dir',str(Path(tools_dir).resolve())]
    elif mode == 'unified-check':
        command=[sys.executable,'-B','-m','vape.unified_ledger.check','--tools-dir',str(Path(tools_dir).resolve())]
    elif mode == 'cloud-build':
        command = [sys.executable,'-B','native/ReadyCloud/build.py']
    elif mode == 'native-check':
        command = [sys.executable,'-B','portable/check_native.py']
    else:
        command = [sys.executable,'-B','-c','import sys;from vape.ledger.local_exercise import run;run(sys.argv[1])',str(Path(tools_dir).resolve())]
    subprocess.run(command,cwd=str(directory),env=environment(),check=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test',action='store_true')
    parser.add_argument('--mode',choices=['core','native','apple','native-check','cloud-build','besu','preflight','unified','unified-check'],default='core')
    parser.add_argument('--tools-dir')
    parser.add_argument('--ready-file',help=argparse.SUPPRESS)
    args=parser.parse_args()
    if sys.version_info < (3,9): parser.error('Python 3.9+ is required; no automatic installation')
    if args.self_test:
        if args.mode != 'core': parser.error('--self-test tests the no-key core only')
        self_test()
    elif args.mode == 'core': core(args.ready_file)
    else: optional(args.mode,args.tools_dir)

if __name__ == '__main__':
    try: main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print('VAPE stopped: '+str(error),file=sys.stderr);sys.exit(1)
