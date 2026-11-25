"""Real-protocol registry adapter; unit tests use explicit RPC/signer doubles.

Pinned-tool local_exercise additionally verifies an actual single-node Besu chain.

A real deployment needs reviewed compiled bytecode, a new disposable local signer,
and the project-private Besu runtime. No key management or remote signer exists.
"""
import hashlib
import re
import time

from vape.contracts import digest
from vape.ledger.besu import CHAIN_ID, LocalBesuReader
from vape.ledger.ethereum_encoding import decode_legacy, encode_call, keccak256
from vape.ledger.service import make_record, validate_record

_COMMIT = 'commit(bytes32,uint64,uint64,bytes32,bytes32,bytes32)'
_READ = 'read(bytes32,uint64)'
_HEX = re.compile(r'0x(?:[0-9a-f]{2})*\Z')
_ADDR = re.compile(r'0x[0-9a-f]{40}\Z')
_EXTRA = {'eth_getCode', 'eth_call', 'eth_getTransactionCount', 'eth_sendRawTransaction',
          'eth_getTransactionReceipt', 'eth_getTransactionByHash'}


def _bytes(value):
    if not isinstance(value, str) or not _HEX.fullmatch(value):
        raise ValueError('Malformed hex bytes')
    return bytes.fromhex(value[2:])


def _word(value):
    return value.to_bytes(32, 'big')


class RegistryRPC(LocalBesuReader):
    def call(self, method, params):
        if method in _EXTRA:
            return self._request(method, params)
        return super().call(method, params)


class RegistryReader:
    def __init__(self, rpc, genesis_hash, validator, writer, namespace, contract, code_sha256):
        if not all(isinstance(x, str) and _ADDR.fullmatch(x) for x in (writer, validator, contract)):
            raise ValueError('Invalid pinned addresses')
        if not isinstance(code_sha256, str) or not re.fullmatch('[0-9a-f]{64}', code_sha256):
            raise ValueError('Pin the reviewed deployed bytecode SHA-256')
        self.rpc, self.genesis_hash, self.validator = rpc, genesis_hash, validator
        self.writer, self.namespace, self.contract, self.code_sha256 = writer, namespace, contract, code_sha256
        self.scope = (str(CHAIN_ID), writer, namespace)
        # Validate the full scope through the frozen contract, without any RPC.
        make_record(*self.scope, 1, 1, '0'*64, '0'*64)
        self.scope_hash = bytes.fromhex(digest(list(self.scope)))

    def guard(self):
        observed = self.rpc.preflight(self.genesis_hash, self.validator, self.writer)
        if not observed.get('valid'):
            raise ValueError('Private chain/permission preflight failed')
        code = _bytes(self.rpc.call('eth_getCode', [self.contract, 'latest']))
        if not code or hashlib.sha256(code).hexdigest() != self.code_sha256:
            raise ValueError('Registry bytecode pin mismatch')

    def read(self, chain_id, authority, namespace, sequence):
        if (chain_id, authority, namespace) != self.scope or type(sequence) is not int or not 1 <= sequence < 2**63:
            raise ValueError('Out-of-scope registry read')
        self.guard()
        block = self.rpc.call('eth_getBlockByNumber', ['latest', False])
        if not isinstance(block, dict) or not isinstance(block.get('number'), str) or len(_bytes(block.get('hash'))) != 32:
            raise ValueError('Missing committed block identity')
        tag = block['number']
        if not re.fullmatch(r'0x(?:0|[1-9a-f][0-9a-f]*)', tag):
            raise ValueError('Invalid read block number')
        if self.rpc.call('qbft_getValidatorsByBlockNumber', [tag]) != [self.validator]:
            raise ValueError('Unexpected validator at read block')
        data = encode_call(_READ, [self.scope_hash, _word(sequence)])
        result = _bytes(self.rpc.call('eth_call', [{'to': self.contract, 'data': data}, tag]))
        if len(result) != 128:
            raise ValueError('Missing or malformed registry record')
        version = int.from_bytes(result[:32], 'big')
        record = make_record(*self.scope, sequence, version, result[32:64].hex(), result[64:96].hex())
        if record['bindingRoot'] != result[96:].hex():
            raise ValueError('Stored binding root is invalid')
        again = self.rpc.call('eth_getBlockByNumber', [tag, False])
        if not isinstance(again, dict) or again.get('hash') != block['hash']:
            raise ValueError('Read block changed')
        # Finality assertion relies on the pinned local QBFT node, not BFT quorum proof.
        return {'record': record, 'finalized': True}


class RegistryWriter:
    def __init__(self, reader, signer, receipt_timeout=5):
        if not callable(signer) or not 0 < receipt_timeout <= 30:
            raise ValueError('Supply a local disposable signer and bounded timeout')
        self.reader, self.signer, self.receipt_timeout = reader, signer, receipt_timeout
        self.last_receipt = None

    def commit(self, record):
        self.last_receipt = None
        record = validate_record(record)
        r = self.reader
        if tuple(record[key] for key in ('chainId', 'authority', 'namespace')) != r.scope:
            raise ValueError('Out-of-scope registry write')
        r.guard()
        data = encode_call(_COMMIT, [r.scope_hash, _word(record['sequence']), _word(record['policyVersion']),
                                    bytes.fromhex(record['policyRoot']), bytes.fromhex(record['executionRoot']),
                                    bytes.fromhex(record['bindingRoot'])])
        tx = {'from': r.writer, 'to': r.contract, 'data': data, 'value': '0x0',
              'gas': hex(500000), 'gasPrice': hex(1000000000)}
        # Contract preflight rejects wrong authority, duplicate/gap before signing.
        r.rpc.call('eth_call', [tx, 'latest'])
        nonce = r.rpc.call('eth_getTransactionCount', [r.writer, 'pending'])
        tx.update(nonce=nonce, chainId=hex(CHAIN_ID))
        raw = self.signer(dict(tx))
        raw_bytes = _bytes(raw)
        if len(raw_bytes) > 4096:
            raise ValueError('Signed transaction exceeds limit')
        values = decode_legacy(raw_bytes)
        expected = [int(nonce, 16), int(tx['gasPrice'], 16), int(tx['gas'], 16),
                    bytes.fromhex(r.contract[2:]), 0, _bytes(data)]
        actual = [int.from_bytes(values[i], 'big') if i in (0,1,2,4) else values[i] for i in range(6)]
        v = int.from_bytes(values[6], 'big')
        if actual != expected or v not in (CHAIN_ID*2+35, CHAIN_ID*2+36) or not values[7] or not values[8]:
            raise ValueError('Signer changed transaction scope, payload, value or replay protection')
        expected_hash = '0x' + keccak256(raw_bytes).hex()
        returned_hash = r.rpc.call('eth_sendRawTransaction', [raw])  # exactly one submission
        if returned_hash != expected_hash:
            raise ValueError('Submission hash mismatch; reconcile, do not retry')
        deadline = time.monotonic() + self.receipt_timeout
        while True:
            receipt = r.rpc.call('eth_getTransactionReceipt', [expected_hash])
            if receipt is not None:
                break
            if time.monotonic() >= deadline:
                raise TimeoutError('Receipt not confirmed; reconcile, do not retry')
            time.sleep(0.05)
        if (not isinstance(receipt, dict) or receipt.get('status') != '0x1'
                or receipt.get('transactionHash') != expected_hash
                or receipt.get('from') != r.writer or receipt.get('to') != r.contract):
            raise ValueError('Receipt does not confirm authorized registry execution')
        if (not isinstance(receipt.get('blockNumber'), str)
                or not re.fullmatch(r'0x(?:0|[1-9a-f][0-9a-f]*)', receipt['blockNumber'])
                or len(_bytes(receipt.get('blockHash'))) != 32):
            raise ValueError('Receipt lacks a committed block identity')
        block = r.rpc.call('eth_getBlockByNumber', [receipt['blockNumber'], False])
        if not isinstance(block, dict) or block.get('hash') != receipt.get('blockHash'):
            raise ValueError('Receipt block identity mismatch')
        self.last_receipt = dict(receipt)
        # AnchorService performs its own independent-reader comparison after return.
