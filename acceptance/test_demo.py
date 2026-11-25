"""Run against the real entrypoint with `make acceptance`; expected to fail at baseline."""
import json
import os
import unittest
from urllib.request import Request, build_opener, ProxyHandler
from pathlib import Path
from urllib.parse import urlsplit
BASE = os.environ.get("VAPE_TEST_BASE", "")
ready_path = os.environ.get("VAPE_TEST_READY", "")
if not ready_path:
    raise RuntimeError("Run make acceptance/e2e: isolated runtime readiness is required")
ready = json.loads(Path(ready_path).read_text())
url = urlsplit(BASE)
if (ready.get("url") != BASE or ready.get("pid") != int(os.environ.get("VAPE_TEST_PID", "0"))
        or url.hostname != "127.0.0.1" or url.port in (8765,50831,50898)
        or url.scheme != "http" or not url.port):
    raise RuntimeError("Refusing a non-isolated acceptance target")
OPENER = build_opener(ProxyHandler({}))
def api(path, body=None):
    req=Request(BASE+path, data=None if body is None else json.dumps(body).encode(), headers={"Content-Type":"application/json"})
    with OPENER.open(req, timeout=5) as response:
        return json.load(response)
class DemoAcceptance(unittest.TestCase):
    def test_actual_gateway_and_immutable_evidence(self):
        def execute(operation, destination=None, **extra):
            return api("/api/execute", {"subject":{"id":"demo-user","role":"analyst"},"resourceId":"synthetic-contract","operation":operation,"destination":destination, **extra})
        before=api("/api/destinations")
        self.assertEqual(execute("write", content="합성 변경 시도")["decision"], "deny")
        read=execute("read")
        self.assertEqual(read["decision"],"allow")
        self.assertIn("합성",read["output"])
        model=execute("model_send","local-model")
        self.assertEqual(model["decision"],"allow")
        self.assertTrue(model["output"])
        self.assertEqual(model["deliveryStatus"],"received")
        self.assertFalse(model["retryAutomatically"])
        cloud=execute("model_send","cloud-model")
        self.assertEqual(cloud["decision"],"allow")
        denied=execute("tool_send","test-tool")
        self.assertEqual(denied["decision"],"deny")
        self.assertEqual(denied["deliveryStatus"],"not_sent")
        after=api("/api/destinations")
        self.assertEqual(after["receipts"]["test-tool"],before["receipts"]["test-tool"])
        self.assertEqual(after["receipts"]["local-model"],before["receipts"]["local-model"]+1)
        self.assertEqual(after["receipts"]["cloud-model"],before["receipts"]["cloud-model"]+1)
        old=api("/api/evidence/"+denied["eventId"])
        self.assertEqual(api("/api/verify",{"bundle":old})["verdict"],"deny")
        p=api("/api/policy")
        updated=api("/api/policy/test-tool",{"expectedVersion":p["version"],"effect":"allow"})
        self.assertGreater(updated["version"],p["version"])
        expected=json.loads(json.dumps(p))
        expected["version"]=updated["version"]
        for rule in expected["rules"]:
            if rule["id"] == "test-tool-rule":
                rule["effect"]="allow"
        self.assertEqual(updated,expected)
        self.assertEqual(execute("tool_send","test-tool")["decision"],"allow")
        self.assertEqual(api("/api/destinations")["receipts"]["test-tool"],before["receipts"]["test-tool"]+1)
        self.assertEqual(api("/api/evidence/"+denied["eventId"]),old)
        self.assertEqual(api("/api/verify",{"bundle":old})["verdict"],"deny")
        self.assertEqual(api("/api/verify",{"bundle":{}})["verdict"],"indeterminate")
        old["event"]["decision"]="allow"
        self.assertEqual(api("/api/verify",{"bundle":old})["verdict"],"indeterminate")
