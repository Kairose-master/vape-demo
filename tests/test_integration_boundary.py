"""Independent transport tests: real HTTP mocks, no substitute policy/audit claims."""
import json
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, build_opener, ProxyHandler
from vape.mock_destinations import MockDestinations
from vape.server import create_server

class TransportTests(unittest.TestCase):
    def test_actual_mock_receiver_and_fixed_registry(self):
        receiver = MockDestinations()
        try:
            self.assertEqual(receiver.receipts(), {'local-model':0,'cloud-model':0,'test-tool':0})
            self.assertIn('모의 모델', receiver.dispatch('local-model', '합성 계약'))
            self.assertIn('모의 모델', receiver.dispatch('cloud-model', '합성 계약'))
            self.assertIn('수신', receiver.dispatch('test-tool', '합성 계약'))
            self.assertEqual(receiver.receipts(), {'local-model':1,'cloud-model':1,'test-tool':1})
            with self.assertRaises(ValueError):
                receiver.dispatch('unregistered', '합성 계약')
            self.assertEqual(receiver.receipts()['test-tool'],1)
        finally:
            receiver.close()
    def test_http_health_and_input_boundaries(self):
        class TransportOnly:
            lock = threading.RLock()
        server=create_server(TransportOnly())
        thread=threading.Thread(target=server.serve_forever,daemon=True)
        thread.start()
        base='http://127.0.0.1:'+str(server.server_port)
        opener=build_opener(ProxyHandler({}))
        try:
            with opener.open(base+'/api/health') as response:
                self.assertEqual(json.load(response)['mode'],'offline-mock')
            for asset, content_type in [('/app.js','javascript'),('/styles.css','text/css')]:
                with opener.open(base+asset) as response:
                    self.assertEqual(response.status,200)
                    self.assertIn(content_type,response.headers['Content-Type'])
                    self.assertGreater(len(response.read()),100)
            for data, headers, status in [
                (b'{}',{'Content-Type':'text/plain'},415),
                (b'[]',{'Content-Type':'application/json'},400),
                (b'{',{'Content-Type':'application/json'},400),
                (b'{}',{'Content-Type':'application/json','Origin':'null'},403),
            ]:
                with self.assertRaises(HTTPError) as caught:
                    opener.open(Request(base+'/api/execute',data=data,headers=headers))
                self.assertEqual(caught.exception.code,status)
                caught.exception.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
