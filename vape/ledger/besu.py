"""Project-local Besu provisioning and read-only identity preflight.

Registry write/read and disposable signing live in besu_registry/local_signer.
Provisioning requires a separately supplied Besu executable and JDK. It never
installs software, starts a daemon, downloads data, or touches an existing node.
"""
import http.client
import json
import re
import shutil
import subprocess
from pathlib import Path
from urllib.parse import urlsplit

CHAIN_ID = 2026112403
_HEX32 = re.compile(r"0x[0-9a-f]{64}\Z")
_ADDRESS = re.compile(r"0x[0-9a-f]{40}\Z")
_READ_METHODS = frozenset(("eth_chainId", "eth_getBlockByNumber", "qbft_getValidatorsByBlockNumber",
                           "perm_getAccountsAllowlist", "perm_getNodesAllowlist"))


def generator_config(writer_address):
    if not isinstance(writer_address, str) or not _ADDRESS.fullmatch(writer_address):
        raise ValueError("Supply an address from a NEW disposable local test signer")
    return {"genesis": {"config": {"chainId": CHAIN_ID, "berlinBlock": 0,
                                   "qbft": {"blockperiodseconds": 2, "epochlength": 30000,
                                            "requesttimeoutseconds": 4}},
                        "nonce": "0x0", "timestamp": "0x0", "gasLimit": "0x47b760",
                        "difficulty": "0x1", "mixHash": "0x63746963616c2062797a616e74696e65206661756c7420746f6c6572616e6365",
                        "coinbase": "0x" + "0" * 40,
                        "alloc": {writer_address[2:]: {"balance": "0xad78ebc5ac6200000"}}},
            "blockchain": {"nodes": {"generate": True, "count": 1}}}


def node_config(root, node_key, rpc_port):
    if type(rpc_port) is not int or not 1024 <= rpc_port <= 65535 or rpc_port == 8765:
        raise ValueError("Use a dedicated unprivileged loopback port, never 8765")
    root, node_key = Path(root).resolve(), Path(node_key).resolve()
    if root not in node_key.parents:
        raise ValueError("Node key must be generated inside the new project runtime")
    # P2P stays on loopback for the QBFT engine. No public bootnodes,
    # discovery, mining on existing chains, or permissive CORS are configured.
    values = {"data-path": str(root / "data"), "genesis-file": str(root / "generated/genesis.json"),
              "node-private-key-file": str(node_key), "network-id": CHAIN_ID,
              "p2p-enabled": True, "p2p-interface": "127.0.0.1", "p2p-host": "127.0.0.1",
              "p2p-port": 0, "nat-method": "NONE", "sync-min-peers": 0,
              "sync-mode": "FULL", "discovery-enabled": False, "bootnodes": [],
              "rpc-http-enabled": True, "rpc-http-host": "127.0.0.1", "rpc-http-port": rpc_port,
              "rpc-http-api": ["ETH", "QBFT", "PERM"],
              "host-allowlist": ["127.0.0.1"], "rpc-ws-enabled": False,
              "metrics-enabled": False, "permissions-nodes-config-file-enabled": True,
              "permissions-accounts-config-file-enabled": True,
              "permissions-nodes-config-file": str(root / "permissions.toml"),
              "permissions-accounts-config-file": str(root / "permissions.toml")}
    return "\n".join(key + "=" + json.dumps(value) for key, value in values.items()) + "\n"


def provision(root, writer_address, besu="besu", rpc_port=18545, process_env=None):
    """Generate keys/genesis only into a NEW directory; do not start the node.

    Failure retains the directory for inspection; never overwrite/retry in place.
    Caller must separately establish the provenance of the disposable signer.
    """
    config = generator_config(writer_address)
    root = Path(root).absolute()
    node_config(root, root / "generated/key", rpc_port)  # validate before effects
    binary = shutil.which(besu)
    if binary is None:
        raise RuntimeError("Besu executable missing; supply project-local Besu and compatible JDK (current docs: 25+)")
    subprocess.run([binary, "--version"], check=True, capture_output=True, timeout=30, env=process_env)
    # Existing directory, including a symlink, is a hard stop.
    root.mkdir(mode=0o700, parents=False, exist_ok=False)
    source = root / "qbft-config.json"
    source.write_text(json.dumps(config, indent=2), encoding="utf-8")
    subprocess.run([binary, "operator", "generate-blockchain-config", "--config-file=" + str(source),
                    "--to=" + str(root / "generated"), "--private-key-file-name=key"],
                   cwd=str(root), check=True, capture_output=True, timeout=60, env=process_env)
    keys = list((root / "generated/keys").glob("*/key"))
    if len(keys) != 1:
        raise RuntimeError("Expected exactly one newly generated validator key")
    keys[0].chmod(0o600)
    (root / "permissions.toml").write_text(
        "accounts-allowlist=" + json.dumps([writer_address]) + "\nnodes-allowlist=[]\n", encoding="utf-8")
    path = root / "node.toml"
    path.write_text(node_config(root, keys[0], rpc_port), encoding="utf-8")
    return {"status": "configuration-generated-not-running", "command": [binary, "--config-file=" + str(path)],
            "chainId": CHAIN_ID, "testOnly": True, "byzantineFaultTolerant": False}


class LocalBesuReader:
    """Separate HTTP connection per read; no proxies, redirects, or writes.

    Loopback is a transport restriction, not independent operator authentication.
    Caller must pin genesis hash/validator addresses from its own fresh runtime.
    This preflight does not authorize transaction submission or verify root storage.
    """
    def __init__(self, endpoint):
        parsed = urlsplit(endpoint)
        if (parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or parsed.username
                or parsed.password or parsed.path not in ("", "/") or parsed.query or parsed.fragment
                or parsed.port is None or not 1024 <= parsed.port <= 65535 or parsed.port == 8765):
            raise ValueError("Only dedicated numeric 127.0.0.1 HTTP endpoints are supported; 8765 is forbidden")
        self.port = parsed.port

    def call(self, method, params):
        if method not in _READ_METHODS:
            raise ValueError("Method is not in the read-only preflight allowlist")
        return self._request(method, params)

    def _request(self, method, params):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3)
        try:
            connection.request("POST", "/", json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}),
                               {"Content-Type": "application/json"})
            response = connection.getresponse()
            if response.status != 200:
                raise ValueError("RPC HTTP status is not 200; redirects are not followed")
            raw = response.read(65537)
            if len(raw) > 65536:
                raise ValueError("RPC reply exceeds preflight limit")
            result = json.loads(raw)
            if isinstance(result, dict) and isinstance(result.get("error"), dict):
                raise ValueError("RPC error " + str(result["error"].get("code")) + ": " + str(result["error"].get("message"))[:512])
            if (not isinstance(result, dict) or result.get("jsonrpc") != "2.0"
                    or type(result.get("id")) is not int or result["id"] != 1
                    or "error" in result or "result" not in result):
                raise ValueError("Invalid or failed JSON-RPC reply")
            return result["result"]
        finally:
            connection.close()

    def preflight(self, genesis_hash, validator, writer_address):
        try:
            if (not isinstance(genesis_hash, str) or not _HEX32.fullmatch(genesis_hash)
                    or not isinstance(validator, str) or not _ADDRESS.fullmatch(validator)
                    or not isinstance(writer_address, str) or not _ADDRESS.fullmatch(writer_address)):
                raise ValueError("Expected identity pins are malformed")
            if self.call("eth_chainId", []) != hex(CHAIN_ID):
                raise ValueError("Wrong private chain ID")
            genesis = self.call("eth_getBlockByNumber", ["0x0", False])
            if not isinstance(genesis, dict) or genesis.get("hash") != genesis_hash:
                raise ValueError("Genesis identity mismatch")
            if self.call("qbft_getValidatorsByBlockNumber", ["latest"]) != [validator]:
                raise ValueError("Unexpected QBFT validator set")
            if self.call("perm_getAccountsAllowlist", []) != [writer_address]:
                raise ValueError("Unexpected account permission allowlist")
            if self.call("perm_getNodesAllowlist", []) != []:
                raise ValueError("Unexpected peer permission allowlist")
            return {"valid": True, "status": "configuration-observed", "chainId": CHAIN_ID,
                    "anchorVerified": False, "permissionEnforcementProven": False}
        except Exception as error:
            return {"valid": False, "status": "indeterminate", "anchorVerified": False, "reason": str(error)}
