"""Defensive tests use authenticated metadata fixtures or explicit RPC doubles only."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from vape.unified_ledger.helper import anchor
import test_ledger_registry as protocol

class UnifiedBoundaryTests(unittest.TestCase):
    def test_invalid_signature_never_starts_chain(self):
        with tempfile.TemporaryDirectory() as tmp, patch('vape.unified_ledger.helper.VerifiedInput.verify_roots',side_effect=ValueError('invalid')), patch('vape.unified_ledger.helper.run') as node:
            with self.assertRaises(ValueError):anchor('unused',tmp,{},None)
            node.assert_not_called()

class UnifiedRPCFailureTests(unittest.TestCase):
    def setUp(self):protocol.RegistryProtocolTests.setUp(self)
    def test_rpc_unavailable_no_send(self):
        with patch.object(self.write_rpc,'call',side_effect=OSError('offline')):
            result=self.service.anchor(self.record)
        self.assertFalse(result['valid']);self.assertEqual(result['status'],'indeterminate')
        self.assertNotIn('eth_sendRawTransaction',self.write_rpc.calls)
    def test_receipt_transaction_mismatch_not_success(self):
        original=self.write_rpc.call
        def rpc(method,params):
            value=original(method,params)
            if method=='eth_getTransactionReceipt':value['transactionHash']='0x'+'9'*64
            return value
        with patch.object(self.write_rpc,'call',side_effect=rpc):result=self.service.anchor(self.record)
        self.assertFalse(result['valid']);self.assertEqual(result['status'],'indeterminate')
        self.assertFalse(result['retryAutomatically'])
        self.assertEqual(self.write_rpc.calls.count('eth_sendRawTransaction'),1)
