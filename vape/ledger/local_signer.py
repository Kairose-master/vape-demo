"""Disposable in-memory signer restricted to the new local chain and zero value.

Uses the checksum-verified Besu distribution's Bouncy Castle implementation;
not a general wallet and never loads an existing key. Secret scalar is not logged,
written to disk, placed in argv or exported in evidence. Destroy by exiting.
"""
import secrets
import subprocess

from vape.ledger.besu import CHAIN_ID
from vape.ledger.ethereum_encoding import keccak256, rlp

_N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141


class DisposableSigner:
    def __init__(self, java, classpath):
        self._command = [str(java), '-cp', str(classpath), 'DemoSigner']
        self._secret = secrets.randbelow(_N - 1) + 1
        public = bytes.fromhex(self._invoke('')[0])
        if len(public) != 65 or public[0] != 4:
            raise ValueError('Malformed signer public key')
        self.address = '0x' + keccak256(public[1:])[-20:].hex()

    def _invoke(self, hashed):
        result = subprocess.run(self._command, input=format(self._secret, 'x')+'\n'+hashed+'\n',
                                capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise ValueError('Disposable signer failed; private input suppressed')
        return result.stdout.strip().splitlines()

    def __call__(self, tx):
        if int(tx['chainId'], 16) != CHAIN_ID or int(tx['value'], 16) != 0:
            raise ValueError('Signer only supports zero-value private test-chain transactions')
        if tx.get('from') != self.address:
            raise ValueError('Signer identity mismatch')
        destination = bytes.fromhex(tx['to'][2:]) if tx['to'] else b''
        if len(destination) not in (0, 20):
            raise ValueError('Invalid test destination')
        fields = [int(tx['nonce'],16), int(tx['gasPrice'],16), int(tx['gas'],16), destination,
                  0, bytes.fromhex(tx['data'][2:])]
        hash_to_sign = keccak256(rlp(fields + [CHAIN_ID, 0, 0]))
        response = self._invoke(hash_to_sign.hex())
        if len(response) != 4:
            raise ValueError('Malformed signer response')
        r, s, recovery = int(response[1],16), int(response[2],16), int(response[3])
        if recovery not in (0, 1) or not 0 < r < _N or not 0 < s <= _N//2:
            raise ValueError('Invalid canonical signature')
        return '0x'+rlp(fields + [CHAIN_ID*2+35+recovery, r, s]).hex()
