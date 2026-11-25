"""Protocol tests with explicitly fake RPC and signatures, NOT EVM/chain tests."""
import copy
import hashlib
import unittest

from vape.ledger.besu import CHAIN_ID
from vape.ledger.besu_registry import RegistryReader, RegistryWriter
from vape.ledger.ethereum_encoding import decode_legacy, encode_call, keccak256, rlp
from vape.ledger.service import AnchorService, make_record

WRITER = '0x'+'1'*40
VALIDATOR = '0x'+'2'*40
CONTRACT = '0x'+'3'*40
GENESIS = '0x'+'4'*64
BLOCK = '0x'+'5'*64
CODE = b'SYNTHETIC BYTECODE DOUBLE, NOT COMPILED SOLIDITY'


def fake_signer(tx):
    # Deliberately not a valid ECDSA signature; RPC double only.
    return '0x'+rlp([int(tx['nonce'],16), int(tx['gasPrice'],16), int(tx['gas'],16),
                      bytes.fromhex(tx['to'][2:]), int(tx['value'],16), bytes.fromhex(tx['data'][2:]),
                      CHAIN_ID*2+35, 1, 1]).hex()


class FakeRPC:
    def __init__(self, store):
        self.store = store
        self.calls = []
        self.bad_pin = False
        self.lost_ack = False
        self.failed_receipt = False
        self.bad_binding = False

    def preflight(self, *pins):
        return {'valid': not self.bad_pin}

    def call(self, method, params):
        self.calls.append(method)
        if method == 'eth_getCode':
            return '0x'+CODE.hex()
        if method == 'eth_getBlockByNumber':
            return {'number': '0x1', 'hash': BLOCK}
        if method == 'qbft_getValidatorsByBlockNumber':
            return [VALIDATOR]
        if method == 'eth_getTransactionCount':
            return hex(len(self.store))
        if method == 'eth_call':
            data = bytes.fromhex(params[0]['data'][2:])
            seq = int.from_bytes(data[36:68], 'big')
            if len(data) == 196:
                if seq != len(self.store)+1:
                    raise ValueError('double: duplicate or gap')
                return '0x'
            if seq not in self.store:
                raise ValueError('double: absent record')
            result = self.store[seq]
            if self.bad_binding:
                result = result[:-32] + b'\x00'*32
            return '0x'+result.hex()
        if method == 'eth_sendRawTransaction':
            raw = bytes.fromhex(params[0][2:])
            values = decode_legacy(raw)
            data = values[5]
            seq = int.from_bytes(data[36:68], 'big')
            if seq in self.store:
                raise ValueError('double: duplicate')
            self.store[seq] = data[68:]
            self.txhash = '0x'+keccak256(raw).hex()
            if self.lost_ack:
                raise OSError('double: lost response after commit')
            return self.txhash
        if method == 'eth_getTransactionReceipt':
            return {'transactionHash': self.txhash, 'status': '0x0' if self.failed_receipt else '0x1',
                    'from': WRITER, 'to': CONTRACT, 'blockHash': BLOCK, 'blockNumber': '0x1'}
        raise AssertionError(method)


class RegistryProtocolTests(unittest.TestCase):
    def setUp(self):
        self.store = {}
        self.write_rpc, self.read_rpc = FakeRPC(self.store), FakeRPC(self.store)
        def reader(rpc):
            return RegistryReader(rpc, GENESIS, VALIDATOR, WRITER, 'synthetic', CONTRACT,
                                  hashlib.sha256(CODE).hexdigest())
        self.write_reader, self.reader = reader(self.write_rpc), reader(self.read_rpc)
        self.writer = RegistryWriter(self.write_reader, fake_signer)
        self.service = AnchorService(str(CHAIN_ID), WRITER, 'synthetic', self.writer, self.reader)
        self.record = make_record(str(CHAIN_ID), WRITER, 'synthetic', 1, 2, '6'*64, '7'*64)

    def test_known_keccak_vectors_and_abi_selector(self):
        self.assertEqual(keccak256(b'').hex(), 'c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470')
        self.assertEqual(keccak256(b'abc').hex(), '4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45')
        self.assertEqual(encode_call('transfer(address,uint256)', [])[:10], '0xa9059cbb')

    def test_complete_adapter_entrypoint_and_separate_read(self):
        self.assertTrue(self.service.anchor(self.record)['valid'])
        self.assertEqual(self.write_rpc.calls.count('eth_sendRawTransaction'), 1)
        self.assertEqual(self.writer.last_receipt['status'], '0x1')
        self.assertIn('eth_call', self.read_rpc.calls)
        self.assertNotIn('eth_sendRawTransaction', self.read_rpc.calls)
        self.assertEqual(self.reader.read(str(CHAIN_ID), WRITER, 'synthetic', 1)['record'], self.record)
        # Old record remains stable when a new policy root is added.
        second = make_record(str(CHAIN_ID), WRITER, 'synthetic', 2, 3, '8'*64, '9'*64)
        self.assertTrue(self.service.anchor(second)['valid'])
        self.assertTrue(self.service.verify(self.record)['valid'])

    def test_duplicate_and_gap_never_reach_signer_or_send(self):
        self.service.anchor(self.record)
        before = self.write_rpc.calls.count('eth_sendRawTransaction')
        result = self.service.anchor(self.record)
        self.assertEqual(result['status'], 'indeterminate')
        self.assertTrue(result['reconciliation']['valid'])
        gap = make_record(str(CHAIN_ID), WRITER, 'synthetic', 3, 2, '6'*64, '7'*64)
        self.assertEqual(self.service.anchor(gap)['status'], 'indeterminate')
        self.assertEqual(self.write_rpc.calls.count('eth_sendRawTransaction'), before)

    def test_replayed_chain_or_changed_signed_value_rejected_before_send(self):
        for field, value in (('value','0x1'), ('to','0x'+'a'*40), ('data','0x1234'), ('nonce','0x99')):
            def changed(tx):
                tx[field] = value
                return fake_signer(tx)
            service = AnchorService(*self.reader.scope, RegistryWriter(self.write_reader, changed), self.reader)
            self.assertFalse(service.anchor(self.record)['valid'])
        def wrong_chain(tx):
            values = decode_legacy(bytes.fromhex(fake_signer(tx)[2:]))
            values[6] = (37).to_bytes(1,'big')
            return '0x'+rlp(values).hex()
        service = AnchorService(*self.reader.scope, RegistryWriter(self.write_reader, wrong_chain), self.reader)
        self.assertFalse(service.anchor(self.record)['valid'])
        self.assertNotIn('eth_sendRawTransaction', self.write_rpc.calls)

    def test_wrong_scope_code_and_permission_pins_block_write(self):
        self.write_rpc.bad_pin = True
        self.assertFalse(self.service.anchor(self.record)['valid'])
        self.assertNotIn('eth_sendRawTransaction', self.write_rpc.calls)
        self.write_rpc.bad_pin = False
        self.write_reader.code_sha256 = '0'*64
        self.assertFalse(self.service.anchor(self.record)['valid'])
        self.assertNotIn('eth_sendRawTransaction', self.write_rpc.calls)
        wrong = make_record('wrong-chain', WRITER, 'synthetic', 1, 2, '6'*64, '7'*64)
        with self.assertRaises(ValueError):
            self.writer.commit(wrong)

    def test_lost_ack_preserves_indeterminate_and_reconciles_once(self):
        self.write_rpc.lost_ack = True
        result = self.service.anchor(self.record)
        self.assertEqual(result['status'], 'indeterminate')
        self.assertTrue(result['reconciliation']['valid'])
        self.assertFalse(result['retryAutomatically'])
        self.assertEqual(self.write_rpc.calls.count('eth_sendRawTransaction'), 1)

    def test_bad_receipt_and_independent_read_fail_closed(self):
        self.write_rpc.failed_receipt = True
        self.assertEqual(self.service.anchor(self.record)['status'], 'indeterminate')
        self.read_rpc.bad_binding = True
        self.assertFalse(self.service.verify(self.record)['valid'])
        self.read_rpc.bad_binding = False
        self.read_rpc.bad_pin = True
        self.assertFalse(self.service.verify(self.record)['valid'])

    def test_malformed_rlp(self):
        for raw in (b'', b'\x80', b'\xc1', b'\xc0', b'\xff', rlp([b'']*8), rlp([b'\x00']*9)):
            with self.assertRaises((ValueError, RecursionError)):
                decode_legacy(raw)


if __name__ == '__main__':
    unittest.main()
