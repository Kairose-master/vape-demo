"""Native-verifier-gated roots. Pins are independent local-operator trust, not self-authenticating input."""
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import subprocess
from vape.contracts import canonical


def sha(data): return hashlib.sha256(data).hexdigest()


def policy_snapshot_merkle_root(policy):
    """One leaf covering a complete policy snapshot; NOT a per-rule policy tree or bare policyHash."""
    return sha(b'\x00'+canonical(policy))


@dataclass(frozen=True)
class NativeEvidenceInput:
    package: Path
    public_key: Path
    checkpoints: Path
    verifier: Path
    verifier_sha256: str
    expected_key_id: str
    expected_run_id: str
    expected_producer_pid: int
    expected_policy_hash: str
    expected_package_hash: str
    expected_checkpoints_hash: str

    def verify_roots(self):
        # Read bytes once and compare against separately acquired immutable pins.
        package_data=self.package.read_bytes(); key=self.public_key.read_bytes(); trust=self.checkpoints.read_bytes()
        if (sha(self.verifier.read_bytes()) != self.verifier_sha256 or sha(key) != self.expected_key_id
                or sha(package_data) != self.expected_package_hash or sha(trust) != self.expected_checkpoints_hash):
            raise ValueError('Native provenance/pinned material mismatch; anchor not attempted')
        checked=subprocess.run([str(self.verifier),str(self.package),str(self.public_key),str(self.checkpoints)],capture_output=True,text=True,timeout=15)
        result=json.loads(checked.stdout)
        if checked.returncode or result.get('valid') is not True or result.get('complete') is not True:
            raise ValueError('Native independent verifier rejected evidence; anchor not attempted')
        # Fail if any source/pin changed while the separate process was reading it.
        if (self.package.read_bytes()!=package_data or self.public_key.read_bytes()!=key or self.checkpoints.read_bytes()!=trust
                or sha(self.verifier.read_bytes()) != self.verifier_sha256):
            raise ValueError('Native input changed during verification')
        package=json.loads(package_data); bundles=package['bundles']
        if package['runID'] != self.expected_run_id or len(bundles) != 3:
            raise ValueError('Not the newly observed synthetic CLI run')
        expected=[('L2','result','deny','app-policy'),('L3','intent','indeterminate','broker-filesystem'),('L3','result','allow','broker-filesystem')]
        policy=bundles[0]['policy']
        for bundle,wanted in zip(bundles,expected):
            e=bundle['leaf']['event']
            if ((e['resourceID'],e['phase'],e['decision'],e['enforcement']) != wanted
                    or e['brokerPID'] != str(self.expected_producer_pid) or e['runID'] != self.expected_run_id
                    or e['keyID'] != self.expected_key_id or e['operation']!='write' or e['destination']!='file'
                    or e['role']!='operator' or e['policyHash']!=self.expected_policy_hash
                    or canonical(bundle['policy'])!=canonical(policy)):
                raise ValueError('Signed execution does not match the pinned producer/policy')
        if sha(canonical(policy)) != self.expected_policy_hash:
            raise ValueError('Policy encoding/hash mismatch')
        root=policy_snapshot_merkle_root(policy)
        if root==self.expected_policy_hash:raise ValueError('Domain separation failure')
        return {'policyVersion':policy['version'],'policyRoot':root,
                'executionRoot':bundles[-1]['checkpoint']['checkpoint']['root'],
                'policySnapshotHash':self.expected_policy_hash,
                'policyRootDefinition':'sha256(0x00 || canonical complete policy snapshot); single leaf',
                'executionRootDefinition':'native signed event Merkle root, final pinned checkpoint',
                'nativeVerdict':result['verdict'],'runID':self.expected_run_id}
