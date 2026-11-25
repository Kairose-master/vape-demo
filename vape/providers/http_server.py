"""Isolated web gateway: unchanged mock routes plus explicit provider routes."""
import argparse
import json
import re
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from vape.audit.service import AuditService
from vape.contracts import canonical
from vape.server import Application, Handler, MAX_BODY
from vape.providers.openai_cloud import CloudConfig, CloudGateway, OpenAICloudAdapter, SYNTHETIC_RESOURCE, _post


class ProviderApplication(Application):
    def __init__(self, data_dir, config=None, transport=None):
        super().__init__(data_dir)
        try:
            self.provider_audit = AuditService(Path(data_dir) / 'provider-audit')
            self.provider_adapter = OpenAICloudAdapter(
                CloudConfig.from_environment() if config is None else config, transport)
            self.provider = CloudGateway(self.policy, self.provider_audit, self.provider_adapter)
        except Exception:
            self.close()
            raise

    def provider_status(self):
        config = self.provider_adapter.config
        return {'mode': 'isolated-provider-gateway', 'syntheticOnly': True,
                'defaultDemoMode': 'offline-mock', 'nativeAppConnected': False,
                'transportMode': 'real-https' if self.provider_adapter._transport is _post else 'injected-test',
                'configurationReady': config.blocked_reason() is None,
                'blockedReason': config.blocked_reason(),
                'resourceId': SYNTHETIC_RESOURCE['id'], 'destination': 'cloud-model'}


class ProviderHandler(Handler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if not path.startswith('/api/provider/'):
            return super().do_GET()
        if not self.trusted_request():
            return self.reply(403, {'error': 'local_origin_required'})
        app = self.server.app
        with app.lock:
            if path == '/api/provider/status':
                return self.reply(200, app.provider_status())
            if path == '/api/provider/events':
                return self.reply(200, {'events': app.provider_audit.list_events()})
            if path.startswith('/api/provider/evidence/'):
                event_id = path.rsplit('/', 1)[-1]
                if not re.fullmatch(r'[0-9a-fA-F-]{36}', event_id):
                    return self.reply(400, {'error': 'invalid_event_id'})
                try:
                    return self.reply(200, app.provider_audit.get_bundle(event_id))
                except (KeyError, FileNotFoundError, ValueError):
                    return self.reply(404, {'error': 'evidence_not_found'})
        return self.reply(404, {'error': 'provider_route_not_found'})

    def do_POST(self):
        path = urlsplit(self.path).path
        if not path.startswith('/api/provider/'):
            return super().do_POST()
        self.close_connection = True
        if not self.trusted_request():
            return self.reply(403, {'error': 'local_origin_required'})
        if path not in ('/api/provider/execute', '/api/provider/verify'):
            return self.reply(404, {'error': 'provider_route_not_found'})
        if self.headers.get('Content-Type', '').split(';')[0].strip() != 'application/json':
            return self.reply(415, {'error': 'json_required'})
        try:
            if self.headers.get('Transfer-Encoding'):
                raise ValueError('unsupported encoding')
            lengths = self.headers.get_all('Content-Length', [])
            if len(lengths) != 1:
                raise ValueError('ambiguous body size')
            size = int(lengths[0])
            if not 0 < size <= MAX_BODY:
                return self.reply(413, {'error': 'invalid_body_size'})
            self.connection.settimeout(5)
            body = json.loads(self.rfile.read(size).decode('utf-8'),
                              parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
            if not isinstance(body, dict):
                raise ValueError('object required')
            canonical(body)  # Reject invalid Unicode before policy/audit serialization.
        except (ValueError, UnicodeError, TimeoutError):
            return self.reply(400, {'error': 'invalid_json'})
        app = self.server.app
        with app.lock:
            if path == '/api/provider/verify':
                return self.reply(200, app.provider_audit.verify(body.get('bundle', {})))
            # No client document, model, URL or credentials accepted at this boundary.
            if set(body) != {'subject', 'resourceId', 'operation', 'destination'}:
                return self.reply(400, {'error': 'provider_request_fields_invalid'})
            try:
                result = app.provider.execute(body, SYNTHETIC_RESOURCE)
            except Exception:
                return self.reply(503, {'error': 'provider_execution_unconfirmed', 'retryAutomatically': False})
            result['gatewayMode'] = 'isolated-provider-gateway'
            result['transportMode'] = app.provider_status()['transportMode']
            status = 200 if result['decision'] == 'allow' else 403 if result['decision'] == 'deny' else 503
            return self.reply(status, result)


def create_provider_server(app, port=0):
    if type(port) is not int or not 0 <= port <= 65535 or port == 8765:
        raise ValueError('Use a fresh port; presentation port 8765 is prohibited')
    server = ThreadingHTTPServer(('127.0.0.1', port), ProviderHandler)
    server.app = app
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data-dir', required=True, type=Path, help='New private runtime directory')
    parser.add_argument('--port', type=int, default=0, help='Default: fresh ephemeral loopback port')
    args = parser.parse_args()
    if args.port == 8765 or not 0 <= args.port <= 65535:
        parser.error('Use port 0 or a new port other than 8765')
    if args.data_dir.exists():
        parser.error('--data-dir must be a new directory, separate from all demo sessions')
    app = ProviderApplication(args.data_dir)
    server = None
    try:
        server = create_provider_server(app, args.port)
        print(json.dumps({'url': 'http://127.0.0.1:%d' % server.server_port,
                          **app.provider_status()}), flush=True)
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if server is not None:
            server.server_close()
        app.close()


if __name__ == '__main__':
    main()
