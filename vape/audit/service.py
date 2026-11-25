"""Synthetic local audit evidence; no external trust or chain.

HMAC-SHA256 is a symmetric demo signature, not independent identity or
nonrepudiation. The machine owner can change the key and file-mock anchors.
An eventual permissioned-chain adapter is outside this demo's trust boundary.
"""
import copy
import hashlib
import hmac
import json
import os
import re
import secrets
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path

from vape.contracts import canonical, digest


_HEX = re.compile(r"[0-9a-f]{64}\Z")
_UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\Z")


def _validate_event(event):
    required = {"request", "resource", "decision", "reason", "matchedRuleIds", "dispatched", "outputHash"}
    if not isinstance(event, dict) or not required.issubset(event):
        raise ValueError("Missing required audit event facts")
    if (event["decision"] not in ("allow", "deny", "indeterminate") or not isinstance(event["reason"], str)
            or type(event["dispatched"]) is not bool
            or not isinstance(event["matchedRuleIds"], list)
            or not all(isinstance(rule, str) for rule in event["matchedRuleIds"])
            or (event["outputHash"] is not None and not _HEX.fullmatch(event["outputHash"]))):
        raise ValueError("Malformed audit event facts")
    resource = event["resource"]
    if (not isinstance(resource, dict) or not {"id", "classification", "contentHash"}.issubset(resource)
            or not _HEX.fullmatch(resource["contentHash"])):
        raise ValueError("Malformed audit resource facts")


def _leaf(event, signature):
    return hashlib.sha256(b"\x00" + canonical({"event": event, "signature": signature})).hexdigest()


def _parent(left, right):
    return hashlib.sha256(b"\x01" + bytes.fromhex(left) + bytes.fromhex(right)).hexdigest()


def _proof(leaves, index):
    level = list(leaves)
    siblings = []
    position = index
    while len(level) > 1:
        peer = position ^ 1
        siblings.append({"side": "left" if position % 2 else "right",
                         "hash": level[peer] if peer < len(level) else level[position]})
        if len(level) % 2:
            level.append(level[-1])
        level = [_parent(level[i], level[i + 1]) for i in range(0, len(level), 2)]
        position //= 2
    return level[0], {"leafIndex": index, "treeSize": len(leaves), "siblings": siblings}


def _immutable_json(path, value):
    encoded = canonical(value)
    try:
        with path.open("xb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
    except FileExistsError:
        if path.read_bytes() != encoded:
            raise ValueError("Immutable audit record conflicts with existing file")


class AuditService:
    """Injected private runtime directory; construction does no network I/O.

    Appends are serialized here; HTTP additionally serializes policy and dispatch.
    A failed append must not be reported as a successful audited execution.
    """

    def __init__(self, data_dir: Path):
        self._append_lock = threading.RLock()
        self._write_failed = False
        self.data_dir = Path(data_dir)
        self.data_dir.mkdir(parents=True, exist_ok=True)
        self._log = self.data_dir / "events.jsonl"
        self._anchors = self.data_dir / "checkpoints"
        self._policies = self.data_dir / "policies"
        self._anchors.mkdir(exist_ok=True)
        self._policies.mkdir(exist_ok=True)
        key_path = self.data_dir / "demo-hmac.key"
        if not key_path.exists():
            if self._log.exists() and self._log.stat().st_size:
                raise ValueError("Demo HMAC key missing for existing audit log")
            with key_path.open("xb") as stream:
                stream.write(secrets.token_bytes(32))
            key_path.chmod(0o600)
        self._key = key_path.read_bytes()
        if len(self._key) != 32:
            raise ValueError("Invalid demo HMAC key")
        self._bundles = {}
        self._leaves = []
        if self._log.exists():
            for line in self._log.read_text(encoding="utf-8").splitlines():
                bundle = json.loads(line)
                if not self.verify(bundle)["valid"]:
                    raise ValueError("Stored audit evidence is invalid")
                event_id = bundle["event"]["eventId"]
                leaf = _leaf(bundle["event"], bundle["signature"])
                root, proof = _proof(self._leaves + [leaf], len(self._leaves))
                if (event_id in self._bundles or bundle["proof"] != proof
                        or bundle["checkpoint"]["root"] != root):
                    raise ValueError("Stored audit log order is invalid")
                self._bundles[event_id] = bundle
                self._leaves.append(leaf)

    def append(self, policy: dict, event: dict) -> dict:
        # Serialize even when used outside the HTTP integration lock.
        with self._append_lock:
            if self._write_failed:
                raise OSError("Audit write state uncertain; restart and validate before new effects")
            try:
                return self._append(policy, event)
            except OSError:
                self._write_failed = True
                raise

    def _append(self, policy: dict, event: dict) -> dict:
        policy = copy.deepcopy(policy)
        event = copy.deepcopy(event)
        if not isinstance(policy, dict) or type(policy.get("version")) is not int or policy["version"] < 1:
            raise ValueError("Policy requires a positive integer version")
        if not isinstance(event, dict) or event.get("decision") not in ("allow", "deny", "indeterminate"):
            raise ValueError("Event requires an allow, deny or indeterminate decision")
        _validate_event(event)
        # Write requests may contain plaintext: retain its digest, not its content.
        if isinstance(event.get("request"), dict) and "content" in event["request"]:
            event["request"]["contentHash"] = digest(event["request"].pop("content"))
        event.update(eventId=str(uuid.uuid4()), timestamp=datetime.now(timezone.utc).isoformat(),
                     policyVersion=policy["version"], policyHash=digest(policy))
        signature = hmac.new(self._key, canonical(event), hashlib.sha256).hexdigest()
        leaf = _leaf(event, signature)
        root, proof = _proof(self._leaves + [leaf], len(self._leaves))
        checkpoint = {"id": str(uuid.uuid4()), "root": root, "treeSize": proof["treeSize"],
                      "kind": "file-mock-anchor"}
        bundle = {"event": event, "policy": policy, "signature": signature,
                  "proof": proof, "checkpoint": checkpoint}
        # Validate serializability before any persistent writes.
        encoded = canonical(bundle) + b"\n"
        _immutable_json(self._policies / (event["policyHash"] + ".json"), policy)
        _immutable_json(self._anchors / (checkpoint["id"] + ".json"), checkpoint)
        with self._log.open("ab") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        self._leaves.append(leaf)
        self._bundles[event["eventId"]] = bundle
        return copy.deepcopy(bundle)

    def get_bundle(self, event_id: str) -> dict:
        return copy.deepcopy(self._bundles[event_id])

    def list_events(self) -> list:
        return [copy.deepcopy(bundle["event"]) for bundle in self._bundles.values()]

    def verify(self, bundle: dict) -> dict:
        checks = dict.fromkeys(("structure", "signature", "policy", "checkpoint", "inclusion"), False)
        try:
            if not isinstance(bundle, dict):
                raise ValueError("Missing evidence bundle")
            event, policy = bundle["event"], bundle["policy"]
            signature, proof, checkpoint = bundle["signature"], bundle["proof"], bundle["checkpoint"]
            if not all(isinstance(x, dict) for x in (event, policy, proof, checkpoint)):
                raise ValueError("Malformed evidence objects")
            if (event["decision"] not in ("allow", "deny", "indeterminate") or not _UUID.fullmatch(event["eventId"])
                    or not isinstance(event["timestamp"], str)
                    or datetime.fromisoformat(event["timestamp"]).utcoffset() is None
                    or type(event["policyVersion"]) is not int or event["policyVersion"] < 1
                    or not _HEX.fullmatch(event["policyHash"]) or not _HEX.fullmatch(signature)):
                raise ValueError("Malformed signed event")
            _validate_event(event)
            checks["structure"] = True
            expected = hmac.new(self._key, canonical(event), hashlib.sha256).hexdigest()
            if not hmac.compare_digest(signature, expected):
                raise ValueError("Invalid demo HMAC signature")
            checks["signature"] = True
            if (type(policy["version"]) is not int or policy["version"] != event["policyVersion"]
                    or digest(policy) != event["policyHash"]):
                raise ValueError("Policy snapshot does not match signed version and hash")
            saved_policy = json.loads((self._policies / (event["policyHash"] + ".json")).read_text(encoding="utf-8"))
            if canonical(saved_policy) != canonical(policy):
                raise ValueError("Policy snapshot differs from local immutable snapshot")
            checks["policy"] = True
            if (not _UUID.fullmatch(checkpoint["id"]) or checkpoint["kind"] != "file-mock-anchor"
                    or not _HEX.fullmatch(checkpoint["root"])
                    or type(checkpoint["treeSize"]) is not int or checkpoint["treeSize"] < 1):
                raise ValueError("Malformed checkpoint")
            trusted = json.loads((self._anchors / (checkpoint["id"] + ".json")).read_text(encoding="utf-8"))
            if canonical(trusted) != canonical(checkpoint):
                raise ValueError("Checkpoint does not match trusted local file")
            checks["checkpoint"] = True
            index, size, siblings = proof["leafIndex"], proof["treeSize"], proof["siblings"]
            if (type(index) is not int or type(size) is not int or not 0 <= index < size
                    or size != checkpoint["treeSize"] or not isinstance(siblings, list)):
                raise ValueError("Invalid inclusion proof position or size")
            node = _leaf(event, signature)
            for sibling in siblings:
                if size <= 1 or not isinstance(sibling, dict) or not _HEX.fullmatch(sibling["hash"]):
                    raise ValueError("Malformed inclusion path")
                side = "left" if index % 2 else "right"
                if sibling["side"] != side:
                    raise ValueError("Inclusion path direction mismatch")
                if index % 2 == 0 and index + 1 == size and sibling["hash"] != node:
                    raise ValueError("Invalid odd-node duplication")
                node = _parent(sibling["hash"], node) if side == "left" else _parent(node, sibling["hash"])
                index //= 2
                size = (size + 1) // 2
            if size != 1 or node != checkpoint["root"]:
                raise ValueError("Incomplete inclusion path or root mismatch")
            checks["inclusion"] = True
            return {"verdict": event["decision"], "valid": True, "checks": checks,
                    "reason": ("Valid evidence records an unresolved execution outcome" if event["decision"] == "indeterminate" else "Valid historical evidence under local demo HMAC/file-mock-anchor trust only")}
        except (KeyError, TypeError, ValueError, OSError, OverflowError, RecursionError) as error:
            return {"verdict": "indeterminate", "valid": False, "checks": checks,
                    "reason": "Evidence cannot establish a decision: " + str(error)}
