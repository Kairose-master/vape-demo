"""Failure injection at our own local dependencies, through the actual HTTP handler."""
import json
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch
from urllib.request import Request, build_opener, ProxyHandler
from vape.audit.service import AuditService
from vape.contracts import digest
from vape.server import Application, create_server

class ExecutionOutcomeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='vape-outcomes-')
        self.addCleanup(self.directory.cleanup)
        self.app = Application(Path(self.directory.name))
        self.server = create_server(self.app)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.close)
        self.opener = build_opener(ProxyHandler({}))
    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        self.app.close()
    def execute(self):
        payload={'subject':{'id':'demo-user','role':'analyst'}, 'resourceId':'synthetic-contract',
                 'operation':'model_send','destination':'local-model'}
        request=Request('http://127.0.0.1:%d/api/execute' % self.server.server_port,
                        data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'})
        with self.opener.open(request,timeout=5) as response:
            return json.load(response)
    def assert_no_plaintext(self):
        for path in (Path(self.directory.name) / 'audit').rglob('*'):
            if path.is_file() and path.suffix != '.key':
                self.assertNotIn(self.app.document['content'].encode(), path.read_bytes())
    def test_intent_failure_stops_before_receiver(self):
        with patch.object(self.app.audit, 'append', side_effect=OSError('simulated local failure')) as append:
            result=self.execute()
        self.assertEqual(append.call_count,1)
        self.assertEqual(self.app.destinations.receipts()['local-model'],0)
        self.assertEqual(result['decision'],'indeterminate')
        self.assertEqual(result['deliveryStatus'],'not_sent')
        self.assertIsNone(result['eventId'])
        self.assertIsNone(result['intentEventId'])
        self.assertFalse(result['retryAutomatically'])
    def test_receiver_acknowledged_but_result_audit_failed(self):
        original=self.app.audit.append
        calls=[]
        def append(policy,event):
            calls.append(event['phase'])
            if event['phase']=='result':
                raise OSError('simulated final audit failure')
            return original(policy,event)
        with patch.object(self.app.audit,'append',side_effect=append):
            result=self.execute()
        self.assertEqual(calls,['intent','result'])
        self.assertEqual(self.app.destinations.receipts()['local-model'],1)
        self.assertEqual(result['decision'],'indeterminate')
        self.assertEqual(result['policyDecision'],'allow')
        self.assertEqual(result['deliveryStatus'],'received')
        self.assertEqual(result['effectStatus'],'completed')
        self.assertFalse(result['retryAutomatically'])
        self.assertIsNone(result['eventId'])
        intent=self.app.audit.get_bundle(result['intentEventId'])
        self.assertEqual(self.app.audit.verify(intent)['verdict'],'indeterminate')
        self.assertTrue(self.app.audit.verify(intent)['valid'])
        self.assert_no_plaintext()
    def test_receiver_received_but_acknowledgement_lost_no_retry(self):
        original=self.app.destinations.dispatch
        attempts=[]
        def lost_ack(destination,content):
            attempts.append(destination)
            events=self.app.audit.list_events()
            self.assertEqual(events[-1]['phase'],'intent')
            self.assertEqual(self.app.audit.verify(self.app.audit.get_bundle(events[-1]['eventId']))['verdict'],'indeterminate')
            original(destination,content)
            raise TimeoutError('simulated acknowledgement loss after receiving')
        with patch.object(self.app.destinations,'dispatch',side_effect=lost_ack):
            result=self.execute()
        self.assertEqual(attempts,['local-model'])
        self.assertEqual(self.app.destinations.receipts()['local-model'],1)
        self.assertEqual(result['decision'],'indeterminate')
        self.assertEqual(result['deliveryStatus'],'unknown')
        self.assertFalse(result['retryAutomatically'])
        bundle=self.app.audit.get_bundle(result['eventId'])
        self.assertEqual(bundle['event']['deliveryStatus'],'unknown')
        self.assertEqual(self.app.audit.verify(bundle)['verdict'],'indeterminate')
        self.assertTrue(self.app.audit.verify(bundle)['valid'])
        self.assert_no_plaintext()

class AuditAppendSerializationTests(unittest.TestCase):
    def test_concurrent_appends_form_one_restartable_history(self):
        with tempfile.TemporaryDirectory(prefix='vape-serial-') as directory:
            audit=AuditService(Path(directory))
            policy={'version':1}
            event={'request':{},'resource':{'id':'synthetic','classification':'demo','contentHash':digest('synthetic')},
                   'decision':'deny','reason':'demo','matchedRuleIds':[],'dispatched':False,'outputHash':None}
            with ThreadPoolExecutor(max_workers=4) as pool:
                bundles=list(pool.map(lambda _:audit.append(policy,event),range(12)))
            self.assertEqual(sorted(b['proof']['treeSize'] for b in bundles),list(range(1,13)))
            restarted=AuditService(Path(directory))
            self.assertEqual(len(restarted.list_events()),12)
            for bundle in bundles:
                self.assertTrue(restarted.verify(bundle)['valid'])
    def test_uncertain_disk_write_blocks_further_appends(self):
        with tempfile.TemporaryDirectory(prefix='vape-write-failure-') as directory:
            audit=AuditService(Path(directory))
            with patch.object(audit,'_append',side_effect=OSError('simulated write failure')) as append:
                for _ in range(2):
                    with self.assertRaises(OSError):
                        audit.append({}, {})
                self.assertEqual(append.call_count,1)
