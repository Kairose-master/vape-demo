import copy
import hashlib
import hmac
import json
import tempfile
import unittest
from pathlib import Path

from vape.audit.service import AuditService, _leaf, _parent
from vape.contracts import canonical, digest


class AuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.audit = AuditService(self.path)
        self.policy = {"version": 1, "rules": [{"id": "synthetic", "effect": "deny"}]}
        self.event = {"request": {"subject": {"id": "demo", "role": "analyst"},
                                  "resourceId": "synthetic", "operation": "tool_send", "destination": "test-tool"},
                      "resource": {"id": "synthetic", "classification": "confidential", "contentHash": digest("synthetic")},
                      "decision": "deny", "reason": "Synthetic rule", "matchedRuleIds": ["synthetic"],
                      "dispatched": False, "outputHash": None}

    def bundle(self, decision="deny"):
        event = copy.deepcopy(self.event)
        event["decision"] = decision
        return self.audit.append(self.policy, event)

    def assertUnknown(self, bundle):
        result = self.audit.verify(bundle)
        self.assertFalse(result["valid"])
        self.assertEqual(result["verdict"], "indeterminate")

    def test_historical_decision_and_copy_isolation(self):
        old = self.bundle()
        frozen = canonical(old)
        self.policy["version"] = 2
        self.policy["rules"][0]["effect"] = "allow"
        new = self.bundle("allow")
        self.assertEqual(self.audit.verify(old)["verdict"], "deny")
        self.assertEqual(self.audit.verify(new)["verdict"], "allow")
        old["policy"]["rules"].clear()
        events = self.audit.list_events()
        events[0]["decision"] = "allow"
        retrieved = self.audit.get_bundle(events[0]["eventId"])
        self.assertEqual(canonical(retrieved), frozen)
        retrieved["proof"]["siblings"].append({})
        self.assertEqual(canonical(self.audit.get_bundle(events[0]["eventId"])), frozen)

    def test_restart_and_frozen_checkpoints(self):
        bundles = [self.bundle() for _ in range(9)]
        restarted = AuditService(self.path)
        for i, bundle in enumerate(bundles):
            self.assertEqual(bundle["proof"]["treeSize"], i + 1)
            self.assertEqual(restarted.get_bundle(bundle["event"]["eventId"]), bundle)
            self.assertTrue(restarted.verify(bundle)["valid"])
        self.assertEqual(len(restarted.list_events()), 9)
        self.assertTrue(restarted.verify(restarted.append(self.policy, self.event))["valid"])

    def test_merkle_formula_and_odd_duplication(self):
        a, b, c = [self.bundle() for _ in range(3)]
        la, lb, lc = [_leaf(x["event"], x["signature"]) for x in (a, b, c)]
        self.assertEqual(a["checkpoint"]["root"], la)
        self.assertEqual(b["checkpoint"]["root"], _parent(la, lb))
        self.assertEqual(c["checkpoint"]["root"], _parent(_parent(la, lb), _parent(lc, lc)))
        self.assertEqual(c["proof"]["siblings"][0], {"side": "right", "hash": lc})
        c["proof"]["siblings"][0]["hash"] = "0" * 64
        self.assertUnknown(c)

    def test_missing_and_malformed_evidence_never_raises(self):
        original = self.bundle()
        for value in (None, [], "", 42, {}, True):
            self.assertUnknown(value)
        for key in original:
            for replacement in (None, [], "bad", 0, True, {}):
                changed = copy.deepcopy(original)
                changed[key] = replacement
                with self.subTest(key=key, replacement=replacement):
                    self.assertUnknown(changed)
            changed = copy.deepcopy(original)
            del changed[key]
            self.assertUnknown(changed)

    def test_signature_policy_and_checkpoint_tampering(self):
        original = self.bundle()
        for section, field, value in (("event", "decision", "allow"), ("event", "policyVersion", 2),
                                      ("policy", "version", 2), ("policy", "rules", []),
                                      ("checkpoint", "root", "0" * 64), ("checkpoint", "id", "../demo-hmac.key"),
                                      ("checkpoint", "kind", "permissioned-chain"), ("checkpoint", "treeSize", True)):
            changed = copy.deepcopy(original)
            changed[section][field] = value
            self.assertUnknown(changed)
        original["signature"] = "0" * 64
        self.assertUnknown(original)

    def test_malformed_proof_positions_directions_and_lengths(self):
        self.bundle()
        original = self.bundle()
        for field, value in (("leafIndex", -1), ("leafIndex", 0), ("leafIndex", True), ("leafIndex", 2),
                             ("treeSize", True), ("treeSize", 3), ("siblings", []), ("siblings", [{}]),
                             ("siblings", [None]), ("siblings", [{"side": "right", "hash": "0" * 64}])):
            changed = copy.deepcopy(original)
            changed["proof"][field] = value
            self.assertUnknown(changed)
        original["proof"]["siblings"] *= 2
        self.assertUnknown(original)

    def test_self_consistent_untrusted_root_and_missing_local_records(self):
        bundle = self.bundle()
        forged = copy.deepcopy(bundle)
        forged["checkpoint"]["id"] = "00000000-0000-0000-0000-000000000000"
        self.assertUnknown(forged)
        anchor = self.path / "checkpoints" / (bundle["checkpoint"]["id"] + ".json")
        saved = anchor.read_bytes()
        anchor.unlink()
        self.assertUnknown(bundle)
        anchor.write_bytes(saved)
        (self.path / "policies" / (bundle["event"]["policyHash"] + ".json")).unlink()
        self.assertUnknown(bundle)

    def test_signature_binding_even_with_recomputed_untrusted_merkle(self):
        forged = self.bundle()
        forged["event"]["decision"] = "allow"
        forged["signature"] = hmac.new(b"untrusted-demo-key", canonical(forged["event"]), hashlib.sha256).hexdigest()
        forged["checkpoint"]["root"] = _leaf(forged["event"], forged["signature"])
        self.assertUnknown(forged)

    def test_restart_refuses_log_corruption_and_missing_key(self):
        bundle = self.bundle()
        log = self.path / "events.jsonl"
        saved = log.read_bytes()
        bundle["event"]["decision"] = "allow"
        log.write_bytes(canonical(bundle) + b"\n")
        with self.assertRaises(ValueError):
            AuditService(self.path)
        log.write_bytes(saved)
        (self.path / "demo-hmac.key").unlink()
        with self.assertRaises(ValueError):
            AuditService(self.path)

    def test_incomplete_signed_event_is_indeterminate(self):
        bundle = self.bundle()
        del bundle["event"]["resource"]
        key = (self.path / "demo-hmac.key").read_bytes()
        bundle["signature"] = hmac.new(key, canonical(bundle["event"]), hashlib.sha256).hexdigest()
        self.assertUnknown(bundle)
        with self.assertRaises(ValueError):
            self.audit.append(self.policy, {"decision": "allow"})
        self.assertEqual(len(self.audit.list_events()), 1)

    def test_write_plaintext_redacted_and_inputs_unchanged(self):
        self.event["request"]["content"] = "synthetic replacement text"
        saved = copy.deepcopy(self.event)
        bundle = self.audit.append(self.policy, self.event)
        self.assertEqual(self.event, saved)
        self.assertNotIn("content", bundle["event"]["request"])
        self.assertEqual(bundle["event"]["request"]["contentHash"], digest(saved["request"]["content"]))
        self.assertNotIn(b"synthetic replacement text", (self.path / "events.jsonl").read_bytes())
        self.assertTrue(self.audit.verify(bundle)["valid"])


if __name__ == "__main__":
    unittest.main()
