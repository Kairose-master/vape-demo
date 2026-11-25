"""Roots only: injected permissioned-write and independent-read boundaries.

Hash binding is not a signature. Trust in a future chain adapter must come from
separately provisioned identities, finality checks, and authenticated reads.
This module does not connect to any network or assert a production trust level.
"""
import copy
import hashlib
import re
from typing import Protocol

from vape.contracts import canonical

_FIELDS = {"version", "chainId", "authority", "namespace", "sequence", "policyVersion",
           "policyRoot", "executionRoot", "bindingRoot"}
_TOKEN = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,127}\Z")
_HEX = re.compile(r"[0-9a-f]{64}\Z")
_MAX_SEQUENCE = 2 ** 63 - 1


def _token(value):
    return isinstance(value, str) and _TOKEN.fullmatch(value) is not None


def _number(value):
    return type(value) is int and 1 <= value <= _MAX_SEQUENCE


def _binding(record):
    payload = {key: value for key, value in record.items() if key != "bindingRoot"}
    return hashlib.sha256(b"VAPE-ROOT-ANCHOR-V1\x00" + canonical(payload)).hexdigest()


def validate_record(record):
    """Strict schema prevents accidental storage of event or document bodies."""
    if not isinstance(record, dict) or set(record) != _FIELDS:
        raise ValueError("Anchor must contain only the v1 root record fields")
    if type(record["version"]) is not int or record["version"] != 1:
        raise ValueError("Unsupported anchor contract version")
    if not all(_token(record[key]) for key in ("chainId", "authority", "namespace")):
        raise ValueError("Invalid chain, authority or namespace")
    if not all(_number(record[key]) for key in ("sequence", "policyVersion")):
        raise ValueError("Invalid sequence or policy version")
    if not all(isinstance(record[key], str) and _HEX.fullmatch(record[key])
               for key in ("policyRoot", "executionRoot", "bindingRoot")):
        raise ValueError("Invalid SHA-256 root")
    if record["bindingRoot"] != _binding(record):
        raise ValueError("Policy and execution binding mismatch")
    return copy.deepcopy(record)


def make_record(chain_id, authority, namespace, sequence, policy_version, policy_root, execution_root):
    record = {"version": 1, "chainId": chain_id, "authority": authority, "namespace": namespace,
              "sequence": sequence, "policyVersion": policy_version, "policyRoot": policy_root,
              "executionRoot": execution_root}
    record["bindingRoot"] = _binding(record)
    return validate_record(record)


class AnchorWriter(Protocol):
    def commit(self, record: dict) -> None:
        """Authenticate writer, enforce scope and strictly sequential append.

        Return only after finality; exceptions may follow a committed write.
        The caller must reconcile through a separate reader, never auto-retry.
        """
        ...


class AnchorReader(Protocol):
    def read(self, chain_id: str, authority: str, namespace: str, sequence: int) -> dict:
        """Return {record, finalized:bool} using an independently configured read.

        Authenticate chain identity, authorization and finality before returning.
        Missing records return None. Transport errors must raise, not invent data.
        """
        ...


class AnchorService:
    def __init__(self, chain_id, authority, namespace, writer: AnchorWriter, reader: AnchorReader):
        if not all(_token(value) for value in (chain_id, authority, namespace)):
            raise ValueError("Invalid configured anchor scope")
        if writer is reader:
            raise ValueError("Writer and reader must be separate adapter objects")
        self.scope = (chain_id, authority, namespace)
        self.writer = writer
        self.reader = reader

    def _expected(self, record):
        record = validate_record(record)
        if tuple(record[key] for key in ("chainId", "authority", "namespace")) != self.scope:
            raise ValueError("Record is outside configured chain/authority/namespace")
        return record

    def verify(self, expected):
        checks = {"record": False, "independentRead": False, "finalized": False, "roots": False}
        try:
            expected = self._expected(expected)
            checks["record"] = True
            found = self.reader.read(*self.scope, expected["sequence"])
            if not isinstance(found, dict) or set(found) != {"record", "finalized"}:
                raise ValueError("Missing or malformed independent read evidence")
            checks["independentRead"] = True
            if found["finalized"] is not True:
                raise ValueError("Anchor finality is not established")
            checks["finalized"] = True
            actual = self._expected(found["record"])
            if canonical(actual) != canonical(expected):
                raise ValueError("Independent root record differs from expected evidence")
            checks["roots"] = True
            return {"valid": True, "status": "matched", "checks": checks,
                    "assurance": "adapter-boundary-only", "retryAutomatically": False,
                    "reason": "Roots match adapter read; this is not an execution verdict or proof of a real chain"}
        except Exception as error:
            # Adapter/network failures must never be interpreted as an absent effect.
            return {"valid": False, "status": "indeterminate", "checks": checks,
                    "assurance": "adapter-boundary-only", "retryAutomatically": False,
                    "reason": str(error)}

    def anchor(self, record):
        record = self._expected(record)  # invalid caller input never reaches writer
        try:
            self.writer.commit(copy.deepcopy(record))
        except Exception as error:
            # Even a successful reconciliation cannot turn a failed submission into
            # a new success; it may be a duplicate or a lost acknowledgement.
            reconciliation = self.verify(record)
            return {"valid": False, "status": "indeterminate", "retryAutomatically": False,
                    "assurance": "adapter-boundary-only", "reason": str(error),
                    "reconciliation": reconciliation}
        return self.verify(record)
