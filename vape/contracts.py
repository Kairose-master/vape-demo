"""Frozen v1 vocabulary. JSON objects are the cross-worktree boundary."""
import hashlib
import json
OPERATIONS = ("read", "write", "model_send", "tool_send")
VERDICTS = ("allow", "deny", "indeterminate")
DESTINATIONS = {
    "local-model": {"kind": "model", "deployment": "local", "path": "/model/local"},
    "cloud-model": {"kind": "model", "deployment": "cloud-simulated", "path": "/model/cloud"},
    "test-tool": {"kind": "tool", "deployment": "local", "path": "/tool/test"},
}
def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()
