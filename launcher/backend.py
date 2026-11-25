"""Fixed synthetic local jobs only. Never accepts credentials, documents, paths or URLs."""
import copy
import base64
import hmac
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import demo
from portable.preflight import check

def public_steps(package):
    steps=[]
    for envelope in package['events']:
        event=json.loads(base64.b64decode(envelope['metadata'],validate=True))
        steps.append({k:event[k] for k in ('phase','route','decision','delivery','policyVersion') if k in event})
    return steps

class Console:
    def __init__(self, tools, probe=check, runner=None):
        self.tools=tools; self.probe=probe; self.runner=runner or self.run
        self.lock=threading.Lock(); self.used=set()
        self.state={'phase':'idle','readiness':None,'jobs':{},'cloud':'native-only; no credentials accepted by backend'}
    def snapshot(self):
        with self.lock:return copy.deepcopy(self.state)
    def request(self, action):
        if action not in ('readiness','apple','besu','mock'):raise ValueError('Unsupported action')
        with self.lock:
            if self.state['phase']=='running':raise ValueError('Busy; no automatic retry')
            if action!='readiness' and action in self.used:raise ValueError('One-shot consumed; inspect evidence before a new console session')
            if action!='readiness':self.used.add(action)
            self.state['phase']='running'; self.state['active']=action
            self.state['jobs'][action]={'status':'running','stage':'준비 상태 확인','runID':str(uuid.uuid4())}
        threading.Thread(target=self.perform,args=(action,),daemon=False).start()
    def perform(self, action):
        try:
            if action=='mock':result=self.runner(action)
            else:
                report=self.probe(self.tools)
                with self.lock:self.state['readiness']=report
                allowed=action=='readiness' or (report['ready'] if action=='apple' else report['ledger']['status']=='ready')
                if not allowed:result={'status':'blocked','reason':'Apple='+report['apple']['status']+'; Besu='+report['ledger']['status'],'fallback':False}
                elif action=='readiness':result={'status':'checked','modelCalls':0,'chainStarted':False}
                else:
                    with self.lock:self.state['jobs'][action]['stage']='고정 합성 자료 실검증 중 · 자동 재시도 없음'
                    result=self.runner(action)
        except Exception:
            result={'status':'indeterminate','reason':'Local verification failed; no success inferred, no retry','fallback':False}
        with self.lock:
            self.state['jobs'][action].update(result);self.state['jobs'][action]['stage']={'passed':'검증 완료','verified':'검증 완료','checked':'준비 상태 확인 완료','blocked':'실행 전 차단','indeterminate':'판정 불가'}.get(result['status'],'판정 불가');self.state['phase']='idle'
    def run(self, action):
        # Each job gets a clean source copy; raw evidence remains private on this device.
        directory=Path(tempfile.mkdtemp(prefix='vape-console-'))/'Source With Spaces';directory.mkdir(mode=0o700)
        demo.copy_source(directory)
        if action=='apple':
            command=[sys.executable,'-B','-m','vape.unified_ledger.check','--tools-dir',str(self.tools)]
        elif action=='besu':
            command=[sys.executable,'-B','-c','import json,sys;from vape.ledger.local_exercise import run;from pathlib import Path;r=run(sys.argv[1]);Path("console-result.json").write_text(json.dumps(r))',str(self.tools)]
        else:command=[sys.executable,'-B','demo.py','--self-test']
        # These fixed workers never receive API keys or user content. Do not publish their stdout.
        result=subprocess.run(command,cwd=str(directory),env=demo.environment(),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if result.returncode:raise RuntimeError('Worker verification failed')
        if action=='mock':return {'status':'passed','scope':'OFFLINE MOCK ONLY: policy/audit/HTTP synthetic tests; no real model or chain'}
        if action=='apple':
            reports=list(directory.glob('.runtime/unified-check-*/exchange/result.json'))
            if len(reports)!=1:raise ValueError('Missing unique result')
            value=json.loads(reports[0].read_text())
            if value.get('status')!='verified':raise ValueError('Unverified Apple/Besu result')
            # The worker exited successfully only after signature, binding and RPC verification.
            package=json.loads((reports[0].parent/'package.json').read_text())
            value['steps']=public_steps(package)
            keys=('status','runID','resourceID','policyRoot','executionRoot','block','transaction','verifiedAt','currentChain','chainId','contract','tamperedCopy','steps')
        else:
            value=json.loads((directory/'console-result.json').read_text())
            if value.get('status')!='passed' or not value.get('nodeStopped') or not value.get('independentRead',{}).get('valid'):raise ValueError('Unverified Besu result')
            keys=('status','chainId','rootTransaction','rootBlock','independentReadAt','nodeStopped','contract','missingRecordRejected','rootMismatchRejected','unauthorizedRejected')
        return dict({k:value[k] for k in keys if k in value},scope='Actual Apple → Besu, fixed synthetic fixture; test selection adapter' if action=='apple' else 'Actual Besu only; synthetic roots, no Apple model evidence')

def server(console, token):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*args):pass
        def reply(self, code, data):
            body=json.dumps(data).encode();self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(body)
        def authorized(self):
            return (self.headers.get('Host')=='127.0.0.1:'+str(self.server.server_port) and not self.headers.get('Origin') and hmac.compare_digest(self.headers.get('Authorization',''),'Bearer '+token))
        def do_GET(self):
            if not self.authorized():return self.reply(403,{'error':'forbidden'})
            if self.path!='/state':return self.reply(404,{'error':'not found'})
            self.reply(200,console.snapshot())
        def do_POST(self):
            if not self.authorized():return self.reply(403,{'error':'forbidden'})
            if self.path!='/action':return self.reply(404,{'error':'not found'})
            try:
                size=int(self.headers.get('Content-Length','0'))
                if not 0<size<=64 or self.headers.get('Transfer-Encoding'):raise ValueError('body rejected')
                value=json.loads(self.rfile.read(size))
                if not isinstance(value,dict) or set(value)!={'action'}:raise ValueError('Only an action is accepted')
                console.request(value['action'])
            except (ValueError,TypeError):return self.reply(400,{'error':'rejected; no retry'})
            self.reply(202,{'accepted':True})
    result=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    if result.server_port==8765:result.server_close();raise RuntimeError('Reserved port selected')
    return result
