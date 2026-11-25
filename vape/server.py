"""Offline demo HTTP integration. Component services are loaded only at startup."""
import argparse
import json
import mimetypes
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
from vape.contracts import DESTINATIONS
from vape.mock_destinations import MockDestinations
ROOT = Path(__file__).resolve().parent.parent
MAX_BODY = 262144

class Application:
    def __init__(self, data_dir):
        from vape.policy.service import PolicyService
        from vape.audit.service import AuditService
        self.lock = threading.RLock()
        self.data_dir = Path(data_dir)
        self.session = self.data_dir.name
        self.data_dir.mkdir(parents=True, exist_ok=True)
        policy_file = self.data_dir / 'current-policy.json'
        self.policy = PolicyService(json.loads((policy_file if policy_file.exists() else ROOT / 'fixtures/policy.json').read_text()))
        self.document = json.loads((ROOT / 'fixtures/document.json').read_text())
        self.audit = AuditService(self.data_dir / 'audit')
        self.destinations = MockDestinations()
    def close(self):
        self.destinations.close()
    def save_policy(self, policy):
        temporary = self.data_dir / 'current-policy.tmp'
        temporary.write_text(json.dumps(policy, ensure_ascii=False, indent=2))
        temporary.replace(self.data_dir / 'current-policy.json')

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # No request body, document text, key or evidence in HTTP logs.
        pass
    def reply(self, status, value, content_type='application/json; charset=utf-8'):
        body = value if isinstance(value, bytes) else json.dumps(value, ensure_ascii=False, allow_nan=False).encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Content-Security-Policy', "default-src 'self'; connect-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(body)
    def trusted_request(self):
        port = self.server.server_port
        hosts = {'127.0.0.1:%d' % port, 'localhost:%d' % port}
        if self.headers.get('Host') not in hosts:
            return False
        origin = self.headers.get('Origin')
        return origin is None or origin in {'http://' + host for host in hosts}
    def do_GET(self):
        if not self.trusted_request():
            return self.reply(403, {'error':'local_origin_required'})
        path = urlsplit(self.path).path
        app = self.server.app
        with app.lock:
            if path == '/api/health':
                return self.reply(200, {'status':'ready', 'contract':'v1', 'mode':'offline-mock', 'session':getattr(app, 'session', 'local')})
            if path == '/api/document':
                return self.reply(200, app.document)
            if path == '/api/policy':
                return self.reply(200, app.policy.get_policy())
            if path == '/api/events':
                return self.reply(200, {'events':app.audit.list_events()})
            if path == '/api/destinations':
                return self.reply(200, {'destinations':DESTINATIONS, 'receipts':app.destinations.receipts()})
            if path.startswith('/api/evidence/'):
                event_id = path[len('/api/evidence/'):]
                if not event_id or any(c not in '0123456789abcdefABCDEF-' for c in event_id):
                    return self.reply(400, {'error':'invalid_event_id'})
                try:
                    return self.reply(200, app.audit.get_bundle(event_id))
                except (KeyError, FileNotFoundError, ValueError):
                    return self.reply(404, {'error':'evidence_not_found'})
        if path.startswith('/api/'):
            return self.reply(404, {'error':'route_not_found'})
        assets = (ROOT / 'web').resolve()
        asset = (assets / ('index.html' if path == '/' else path.lstrip('/'))).resolve()
        if assets not in asset.parents or not asset.is_file():
            return self.reply(404, {'error':'asset_not_found'})
        return self.reply(200, asset.read_bytes(), mimetypes.guess_type(str(asset))[0] or 'application/octet-stream')
    def do_POST(self):
        self.close_connection = True
        if not self.trusted_request():
            return self.reply(403, {'error':'local_origin_required'})
        if self.headers.get('Content-Type', '').split(';')[0].strip() != 'application/json':
            return self.reply(415, {'error':'json_required'})
        try:
            if self.headers.get('Transfer-Encoding'):
                raise ValueError('Transfer encoding not supported')
            size = int(self.headers.get('Content-Length', '0'))
            if not 0 < size <= MAX_BODY:
                return self.reply(413, {'error':'invalid_body_size'})
            self.connection.settimeout(5)
            body = json.loads(self.rfile.read(size), parse_constant=lambda x: (_ for _ in ()).throw(ValueError(x)))
            if not isinstance(body, dict):
                raise ValueError('JSON object required')
        except (ValueError, UnicodeDecodeError, TimeoutError):
            return self.reply(400, {'error':'invalid_json'})
        path = urlsplit(self.path).path
        app = self.server.app
        with app.lock:
            if path == '/api/execute':
                try:
                    result = app.policy.execute(body, app.document, app.destinations.dispatch, app.audit)
                    return self.reply(200, result)
                except (ValueError, TypeError, KeyError):
                    return self.reply(400, {'error':'invalid_execution_request'})
                except Exception:
                    return self.reply(503, {'error':'execution_or_audit_failed', 'message':'전송 여부를 포함한 집행 완료를 확인할 수 없습니다.'})
            if path == '/api/policy/test-tool':
                if set(body) != {'effect', 'expectedVersion'} or body['effect'] not in ('allow', 'deny') or type(body['expectedVersion']) is not int:
                    return self.reply(400, {'error':'invalid_policy_change'})
                try:
                    updated = app.policy.update_test_tool(body['effect'], body['expectedVersion'])
                except ValueError:
                    return self.reply(409, {'error':'stale_or_invalid_policy_change'})
                app.save_policy(updated)
                return self.reply(200, updated)
            if path == '/api/verify':
                try:
                    return self.reply(200, app.audit.verify(body.get('bundle', {})))
                except Exception:
                    return self.reply(200, {'verdict':'indeterminate','valid':False,'checks':{},'reason':'검증 증거를 처리할 수 없습니다.'})
        return self.reply(404, {'error':'route_not_found'})

def create_server(app, port=0):
    server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
    server.app = app
    return server

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--data-dir', type=Path, default=ROOT / '.runtime')
    parser.add_argument('--ready-file', type=Path, help='Fresh launcher readiness record')
    args = parser.parse_args()
    try:
        app = Application(args.data_dir)
    except ModuleNotFoundError as error:
        parser.exit(2, '기능 브랜치 통합 대기: %s\n' % error.name)
    server = None
    try:
        server = create_server(app, args.port)
        url = 'http://127.0.0.1:%s' % server.server_port
        if args.ready_file:
            # The launcher creates a unique directory; exclusive create prevents overwrites.
            with args.ready_file.open('x') as ready:
                json.dump({'url':url, 'pid':os.getpid(), 'session':app.session}, ready)
        print('VAPE %s (offline mock)' % url, flush=True)
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if server is not None:
            server.server_close()
        app.close()
if __name__ == '__main__':
    main()
