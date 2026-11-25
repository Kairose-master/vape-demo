import json
from pathlib import Path
import threading
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request,urlopen
from unittest.mock import Mock
from launcher.backend import Console,server,public_steps

class ConsoleTests(unittest.TestCase):
 def wait(self,c):
  for _ in range(100):
   if c.snapshot()['phase']!='running':return c.snapshot()
   time.sleep(.01)
  self.fail('Job did not finish')
 def test_initially_no_mode_runs(self):
  probe=Mock();runner=Mock();c=Console(Path('unused'),probe,runner)
  self.assertEqual(c.snapshot()['jobs'],{});probe.assert_not_called();runner.assert_not_called()
 def test_apple_unavailable_is_blocked_no_fallback(self):
  for status in ['disabled','not_ready','os_unsupported','device_unsupported','probe_failed']:
   runner=Mock();c=Console(Path('unused'),lambda _:dict(ready=False,apple={'status':status},ledger={'status':'ready'}),runner)
   c.request('apple');v=self.wait(c);self.assertEqual(v['jobs']['apple']['status'],'blocked');runner.assert_not_called()
 def test_missing_tools_blocks_ready_apple(self):
  runner=Mock();c=Console(None,lambda _:dict(ready=False,apple={'status':'ready'},ledger={'status':'not_ready'}),runner)
  c.request('apple');self.wait(c);runner.assert_not_called()
 def test_besu_independent_when_apple_disabled(self):
  runner=Mock(return_value={'status':'passed'});c=Console(None,lambda _:dict(ready=False,apple={'status':'disabled'},ledger={'status':'ready'}),runner)
  c.request('besu');self.wait(c);runner.assert_called_once_with('besu')
 def test_failed_dispatch_indeterminate_consumed_no_retry(self):
  runner=Mock(side_effect=RuntimeError('synthetic failure'));c=Console(None,runner=runner)
  c.request('mock');self.assertEqual(self.wait(c)['jobs']['mock']['status'],'indeterminate')
  with self.assertRaises(ValueError):c.request('mock')
  runner.assert_called_once_with('mock')
 def test_mock_never_calls_preflight_or_models(self):
  probe=Mock();runner=Mock(return_value={'status':'passed','scope':'mock'});c=Console(None,probe,runner)
  c.request('mock');self.wait(c);probe.assert_not_called();runner.assert_called_once_with('mock')
 def test_cloud_and_arbitrary_actions_rejected(self):
  c=Console(None)
  for action in ['cloud','open','/bin/sh','https://example.invalid']:
   with self.assertRaises(ValueError):c.request(action)
 def test_http_boundary_no_keys_content_origin_or_unauthenticated(self):
  c=Console(None,runner=Mock(return_value={'status':'passed'}));s=server(c,'test-capability');t=threading.Thread(target=s.serve_forever);t.start()
  base='http://127.0.0.1:'+str(s.server_port)
  def request(path='/action',body=None,auth=True,origin=None):
   headers={'Content-Type':'application/json'}
   if auth:headers['Authorization']='Bearer test-capability'
   if origin:headers['Origin']=origin
   return urlopen(Request(base+path,data=json.dumps(body).encode() if body is not None else None,headers=headers),timeout=3)
  try:
   for body in [{'action':'cloud'},{'action':'mock','key':'SYNTHETIC-NOT-A-KEY'},{'action':'mock','content':'synthetic'},{'action':'mock','path':'unused'}]:
    with self.assertRaises(HTTPError) as e:request(body=body)
    self.assertEqual(e.exception.code,400)
   for kwargs in [dict(auth=False),dict(origin='http://example.invalid')]:
    with self.assertRaises(HTTPError) as e:request(body={'action':'mock'},**kwargs)
    self.assertEqual(e.exception.code,403)
   self.assertEqual(c.snapshot()['jobs'],{})
   with request('/state') as r:self.assertEqual(json.load(r)['phase'],'idle')
   with request(body={'action':'mock'}) as r:self.assertEqual(r.status,202)
   self.wait(c);c.runner.assert_called_once_with('mock')
  finally:s.shutdown();s.server_close();t.join()
 def test_same_cloud_security_code_and_permissions(self):
  root=Path(__file__).resolve().parents[1];build=(root/'native/Console/build.py').read_text();ui=(root/'native/Console/App.swift').read_text()
  self.assertIn('native/ReadyCloud/Core.swift',build);self.assertNotIn('temporary-exception',build)
  self.assertIn('NSSecureTextField()',ui);self.assertIn('executeL2(key:credential,approved:true)',ui)
  self.assertNotIn("['open'",(root/'launcher/start.py').read_text())

 def test_verified_step_projection_never_includes_body_paths_or_keys(self):
  import base64
  event={'phase':'result','route':'local','decision':'allow','delivery':'received','policyVersion':1,'content':'SYNTHETIC SECRET','path':'PRIVATE SYNTHETIC PATH','key':'SYNTHETIC CREDENTIAL'}
  package={'events':[{'metadata':base64.b64encode(json.dumps(event).encode()).decode()}]}
  self.assertEqual(set(public_steps(package)[0]),{'phase','route','decision','delivery','policyVersion'})
  with self.assertRaises(ValueError):public_steps({'events':[{'metadata':'!!'}]})
