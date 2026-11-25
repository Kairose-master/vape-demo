import json
import unittest
from pathlib import Path
from vape.contracts import OPERATIONS, canonical, digest
class ContractTest(unittest.TestCase):
    def test_canonical_order(self):
        self.assertEqual(canonical({"b":2,"a":1}), b'{"a":1,"b":2}')
        self.assertEqual(digest({"a":1,"b":2}), digest({"b":2,"a":1}))
    def test_fixture_branches(self):
        policy=json.loads(Path("fixtures/policy.json").read_text())
        self.assertEqual(set(OPERATIONS), {"read","write","model_send","tool_send"})
        self.assertEqual(policy["default"], "deny")
        by_id={r["id"]:r for r in policy["rules"]}
        self.assertEqual(by_id["read-contract"]["effect"], "allow")
        self.assertEqual(by_id["summarize-local"]["effect"], "allow")
        self.assertEqual(by_id["test-tool-rule"]["effect"], "deny")
