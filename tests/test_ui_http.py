"""Real UI/API smoke on fresh loopback listeners and disposable audit data."""
import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.request import Request, urlopen

from vape.server import Application, create_server


class UIHTTP(unittest.TestCase):
    def test_fresh_console_observations_and_historical_evidence(self):
        with tempfile.TemporaryDirectory(prefix='vape-ui-http-') as directory:
            app = Application(Path(directory))
            server = create_server(app, 0)
            self.assertNotEqual(server.server_port, 8765)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            base = 'http://127.0.0.1:%d' % server.server_port

            def api(path, body=None):
                payload = None if body is None else json.dumps(body).encode()
                request = Request(base + path, data=payload, headers={'Content-Type': 'application/json'})
                with urlopen(request, timeout=5) as response:
                    return json.load(response)

            try:
                with urlopen(base, timeout=5) as response:
                    self.assertIn('읽기 허용 ≠ 반출 허용', response.read().decode())
                for asset in ('app.js', 'styles.css'):
                    with urlopen(base + '/' + asset, timeout=5) as response:
                        self.assertEqual(response.status, 200)
                self.assertEqual(api('/api/events')['events'], [])
                resource = api('/api/document')
                policy = api('/api/policy')
                request = {'subject': {'id': 'ui-qa', 'role': 'analyst'}, 'resourceId': resource['id']}
                outcomes = []
                for operation, destination in [('read', None), ('model_send', 'local-model'), ('tool_send', 'test-tool')]:
                    outcomes.append(api('/api/execute', dict(request, operation=operation, destination=destination)))
                self.assertEqual([r['decision'] for r in outcomes], ['allow', 'allow', 'deny'])
                self.assertEqual(api('/api/destinations')['receipts'], {'local-model': 1, 'cloud-model': 0, 'test-tool': 0})
                old_id = outcomes[-1]['eventId']
                old = api('/api/evidence/' + old_id)
                updated = api('/api/policy/test-tool', {'expectedVersion': policy['version'], 'effect': 'allow'})
                self.assertGreater(updated['version'], policy['version'])
                result = api('/api/execute', dict(request, operation='tool_send', destination='test-tool'))
                self.assertEqual(result['decision'], 'allow')
                self.assertEqual(api('/api/destinations')['receipts']['test-tool'], 1)
                self.assertEqual(api('/api/evidence/' + old_id), old)
                verified = api('/api/verify', {'bundle': old})
                self.assertEqual((verified['valid'], verified['verdict']), (True, 'deny'))
                changed = json.loads(json.dumps(old))
                changed['event']['decision'] = 'allow'
                for bundle in (changed, {}):
                    self.assertEqual(api('/api/verify', {'bundle': bundle})['verdict'], 'indeterminate')
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)
                app.close()
