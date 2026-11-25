import json
import unittest
from copy import deepcopy
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from threading import Thread
from urllib.request import Request, urlopen

from vape.contracts import digest
from vape.policy.service import PolicyService


class Audit:
    def __init__(self):
        self.bundles = []

    def append(self, policy, event):
        event['eventId'] = str(len(self.bundles) + 1)
        bundle = deepcopy({'policy': policy, 'event': event})
        self.bundles.append(bundle)
        return deepcopy(bundle)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parents[1]
        self.policy = json.loads((root / 'fixtures/policy.json').read_text())
        self.document = json.loads((root / 'fixtures/document.json').read_text())
        self.service = PolicyService(self.policy)
        self.audit = Audit()
        self.calls = []

    def request(self, operation='read', destination=None, **extra):
        return dict(subject={'id': 'synthetic-user', 'role': 'analyst'},
                    resourceId=self.document['id'], operation=operation,
                    destination=destination, **extra)

    def dispatch(self, destination, content):
        self.calls.append((destination, content))
        return 'synthetic summary'

    def execute(self, request):
        return self.service.execute(request, self.document, self.dispatch, self.audit)

    def test_same_document_read_model_tool_boundary_and_historical_snapshot(self):
        self.assertEqual(self.execute(self.request())['output'], self.document['content'])
        self.assertEqual(self.execute(self.request('model_send', 'local-model'))['decision'], 'allow')
        self.assertEqual(self.execute(self.request('model_send', 'cloud-model'))['decision'], 'allow')
        self.assertEqual(self.execute(self.request('tool_send', 'test-tool'))['decision'], 'deny')
        old_bundle = deepcopy(self.audit.bundles[-1])
        self.assertEqual(len(self.calls), 2)
        new = self.service.update_test_tool('allow', 1)
        expected = deepcopy(self.policy)
        expected['version'] = 2
        expected['rules'][-1]['effect'] = 'allow'
        self.assertEqual(new, expected)
        self.assertEqual(self.execute(self.request('tool_send', 'test-tool'))['decision'], 'allow')
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(next(b for b in self.audit.bundles if b["event"]["eventId"] == old_bundle["event"]["eventId"]), old_bundle)
        self.assertEqual(old_bundle['event']['decision'], 'deny')
        self.assertEqual(old_bundle['policy']['version'], 1)

    def test_write_requires_independent_rule_and_hides_plaintext(self):
        req = self.request('write', content='synthetic replacement')
        before = deepcopy(self.document)
        self.assertEqual(self.execute(req)['decision'], 'deny')
        self.assertEqual(self.document, before)
        policy = deepcopy(self.policy)
        rule = dict(policy['rules'][0], id='write-contract', operation='write')
        policy['rules'].append(rule)
        self.service = PolicyService(policy)
        self.assertEqual(self.execute(req)['output'], req['content'])
        self.assertEqual(self.document['content'], req['content'])
        event = self.audit.bundles[-1]['event']
        self.assertEqual(event['resource']['contentHash'], digest(before['content']))
        self.assertEqual(event['outputHash'], digest(req['content']))
        self.assertNotIn('content', event['request'])
        self.assertNotIn(before['content'], json.dumps(event, ensure_ascii=False))
        self.assertEqual(self.calls, [])

    def test_invalid_requests_fail_closed_through_execute(self):
        requests = [None, [], {}, self.request('unknown'),
                    self.request('read', 'local-model'), self.request('model_send'),
                    self.request('tool_send', 'local-model'), self.request('model_send', 'test-tool'),
                    self.request('model_send', 'http://127.0.0.1/'),
                    self.request('model_send', 'local-model/'),
                    self.request('read', classification='public'),
                    self.request('read', url='http://127.0.0.1/'),
                    self.request('read', content='forged'), self.request('write'),
                    self.request('write', content=123)]
        for changes in ({'subject': None}, {'subject': {'id': '', 'role': 'analyst'}},
                        {'subject': {'id': 'x', 'role': 'unknown'}},
                        {'operation': []}, {'destination': {}}, {'resourceId': 'unknown'}):
            req = self.request()
            req.update(changes)
            requests.append(req)
        for req in requests:
            with self.subTest(request=req):
                self.assertEqual(self.execute(req)['decision'], 'deny')
        self.assertEqual(self.calls, [])

    def test_resource_classification_is_authoritative(self):
        for classification in ('unknown', 'public'):
            self.document['classification'] = classification
            self.assertEqual(self.execute(self.request())['decision'], 'deny')
        for resource in (None, {}, dict(self.document, content=None)):
            result = self.service.execute(self.request(), resource, self.dispatch, self.audit)
            self.assertEqual(result['decision'], 'deny')

    def test_explicit_deny_wins_in_either_order(self):
        for reverse in (False, True):
            policy = deepcopy(self.policy)
            policy['rules'].append(dict(policy['rules'][0], id='override', effect='deny'))
            if reverse:
                policy['rules'].reverse()
            self.service = PolicyService(policy)
            result = self.execute(self.request())
            self.assertEqual(result['decision'], 'deny')
            self.assertEqual(set(self.audit.bundles[-1]['event']['matchedRuleIds']), {'read-contract', 'override'})

    def test_arbitrary_organization_labels_and_no_clearance_ranking(self):
        policy = deepcopy(self.policy)
        policy['roles'] = ['reviewer-x']
        policy['classifications'] = ['internal-blue', 'internal-green']
        for rule in policy['rules']:
            rule.update(role='reviewer-x', classification='internal-blue')
        self.service = PolicyService(policy)
        req = self.request()
        req['subject']['role'] = 'reviewer-x'
        self.document['classification'] = 'internal-blue'
        self.assertEqual(self.execute(req)['decision'], 'allow')
        self.document['classification'] = 'internal-green'
        self.assertEqual(self.execute(req)['decision'], 'deny')

    def test_version_validation_and_copy_isolation(self):
        self.policy['rules'][0]['effect'] = 'deny'
        snapshot = self.service.get_policy()
        snapshot['rules'][0]['effect'] = 'deny'
        result = self.service.evaluate(self.request(), self.document)
        result['policy']['rules'].clear()
        self.assertEqual(self.execute(self.request())['decision'], 'allow')
        for effect, version in [('ALLOW', 1), ('allow', True), ('allow', 0), ('allow', '1')]:
            with self.assertRaises(ValueError):
                self.service.update_test_tool(effect, version)
        new = self.service.update_test_tool('allow', 1)
        new['rules'].clear()
        with self.assertRaises(ValueError):
            self.service.update_test_tool('deny', 1)
        self.assertEqual(self.service.get_policy()['version'], 2)
        self.assertEqual(len(self.service.get_policy()['rules']), 4)
        self.assertEqual(self.service.update_test_tool('allow', 2)['version'], 3)

    def test_invalid_policy_rejected(self):
        policies = [None, {}, dict(self.policy, version=True), dict(self.policy, default='allow'),
                    dict(self.policy, roles=[]), dict(self.policy, classifications=['x', 'x'])]
        for changes in ({'destination': 'unknown'}, {'operation': 'model_send'},
                        {'role': 'unknown'}, {'effect': 'other'}, {'extra': 'ignored?'}):
            p = deepcopy(self.policy)
            p['rules'][0].update(changes)
            policies.append(p)
        p = deepcopy(self.policy)
        p['rules'].append(deepcopy(p['rules'][0]))
        policies.append(p)
        for policy in policies:
            with self.subTest(policy=policy), self.assertRaises(ValueError):
                PolicyService(policy)

    def test_dispatch_and_audit_failures_never_claim_success(self):
        def broken(*args):
            raise RuntimeError('sensitive exception')
        req = self.request('model_send', 'local-model')
        result = self.service.execute(req, self.document, broken, self.audit)
        self.assertEqual(result['decision'], 'indeterminate')
        self.assertIsNone(result['output'])
        self.assertFalse(self.audit.bundles[-1]['event']['dispatched'])
        self.assertNotIn('sensitive', result['reason'])
        self.audit.append = broken
        result = self.execute(req)
        self.assertEqual(result['decision'], 'indeterminate')
        self.assertIsNone(result['eventId'])
        self.assertIsNone(result['output'])

    def test_audit_failure_does_not_apply_write(self):
        policy = deepcopy(self.policy)
        policy['rules'].append(dict(policy['rules'][0], id='write', operation='write'))
        self.service = PolicyService(policy)
        before = deepcopy(self.document)
        def broken(*args):
            raise OSError('synthetic audit failure')
        self.audit.append = broken
        result = self.execute(self.request('write', content='synthetic update'))
        self.assertEqual(result['decision'], 'indeterminate')
        self.assertEqual(self.document, before)
        self.assertIsNone(result['output'])

    def test_audit_dependency_cannot_mutate_policy_or_result(self):
        class MutatingAudit:
            def append(self, policy, event):
                policy['rules'].clear()
                event['decision'] = 'deny'
                return {'event': {'eventId': 'synthetic-event'}}
        result = self.service.execute(self.request(), self.document, self.dispatch, MutatingAudit())
        self.assertEqual(result['decision'], 'allow')
        self.assertEqual(len(self.service.get_policy()['rules']), 4)

    def test_real_loopback_receiver_counts_at_execute_entrypoint(self):
        receipts = []
        class Receiver(BaseHTTPRequestHandler):
            def do_POST(self):
                receipts.append((self.path, self.rfile.read(int(self.headers['Content-Length'])).decode()))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'synthetic receipt')
            def log_message(self, *args):
                pass
        server = HTTPServer(('127.0.0.1', 0), Receiver)
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        def dispatch(destination, content):
            url = 'http://127.0.0.1:%d/%s' % (server.server_port, destination)
            with urlopen(Request(url, data=content.encode(), method='POST'), timeout=3) as response:
                return response.read().decode()
        try:
            for operation, destination, decision in [('read', None, 'allow'), ('model_send', 'local-model', 'allow'), ('tool_send', 'test-tool', 'deny')]:
                result = self.service.execute(self.request(operation, destination), self.document, dispatch, self.audit)
                self.assertEqual(result['decision'], decision)
            self.assertEqual(receipts, [('/local-model', self.document['content'])])
            self.service.update_test_tool('allow', 1)
            result = self.service.execute(self.request('tool_send', 'test-tool'), self.document, dispatch, self.audit)
            self.assertEqual(result['decision'], 'allow')
            self.assertEqual(receipts[-1], ('/test-tool', self.document['content']))
            self.assertEqual(len(receipts), 2)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)


if __name__ == '__main__':
    unittest.main()
