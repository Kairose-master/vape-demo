"""Separate loopback HTTP receiver; no real model, tools or external destinations."""
import json
import secrets
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, build_opener, ProxyHandler, HTTPRedirectHandler
from vape.contracts import DESTINATIONS

class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

class MockDestinations:
    def __init__(self):
        self._lock = threading.Lock()
        self._receipts = {key: 0 for key in DESTINATIONS}
        self._token = secrets.token_hex(32)
        owner = self
        paths = {value['path']: key for key, value in DESTINATIONS.items()}
        class Receiver(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_POST(self):
                if self.headers.get('Authorization') != 'Bearer ' + owner._token:
                    self.send_error(403)
                    return
                key = paths.get(self.path)
                try:
                    size = int(self.headers.get('Content-Length', '0'))
                    if key is None or not 0 < size <= 262144:
                        raise ValueError('Invalid receiver request')
                    content = json.loads(self.rfile.read(size))['content']
                    if not isinstance(content, str):
                        raise ValueError('Content must be text')
                except (ValueError, KeyError, TypeError):
                    self.send_error(400)
                    return
                with owner._lock:
                    owner._receipts[key] += 1
                output = ('[모의 모델 요약] ' + content[:180]) if DESTINATIONS[key]['kind'] == 'model' else '[모의 도구] 합성 자료 수신 완료'
                body = json.dumps({'output': output}, ensure_ascii=False).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Receiver)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.opener = build_opener(ProxyHandler({}), NoRedirect())
    def dispatch(self, destination_id, content):
        if destination_id not in DESTINATIONS or not isinstance(content, str):
            raise ValueError('Unknown destination or invalid content')
        url = 'http://127.0.0.1:%d%s' % (self.server.server_port, DESTINATIONS[destination_id]['path'])
        request = Request(url, data=json.dumps({'content': content}).encode(), headers={'Content-Type':'application/json','Authorization':'Bearer '+self._token})
        with self.opener.open(request, timeout=3) as response:
            return json.load(response)['output']
    def receipts(self):
        with self._lock:
            return dict(self._receipts)
    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
