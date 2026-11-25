"""One synthetic call only, with explicit activation and durable local audit."""
import argparse
import json
from pathlib import Path

from vape.audit.service import AuditService
from vape.policy.service import PolicyService
from vape.providers.openai_cloud import CloudConfig, CloudGateway, OpenAICloudAdapter, SYNTHETIC_RESOURCE


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live-once', action='store_true')
    parser.add_argument('--audit-dir', type=Path)
    args = parser.parse_args()
    config = CloudConfig.from_environment()
    if not args.live_once:
        print(json.dumps({'liveAttempted': False, 'configurationReady': config.blocked_reason() is None,
                          'blockedReason': config.blocked_reason(), 'serverWired': False}))
        return 0
    if config.blocked_reason():
        print(json.dumps({'liveAttempted': False, 'blockedReason': config.blocked_reason()}))
        return 2
    if args.audit_dir is None:
        parser.error('--audit-dir is required with --live-once')
    # Frozen fixture policy, never runtime/user documents or the running demo server.
    root = Path(__file__).resolve().parents[2]
    policy = PolicyService(json.loads((root / 'fixtures/policy.json').read_text()))
    audit = AuditService(args.audit_dir)
    gateway = CloudGateway(policy, audit, OpenAICloudAdapter(config))
    request = {'subject': {'id': 'vape-synthetic-probe', 'role': 'analyst'},
               'resourceId': SYNTHETIC_RESOURCE['id'], 'operation': 'model_send', 'destination': 'cloud-model'}
    result = gateway.execute(request, SYNTHETIC_RESOURCE)
    # No key, prompt, output, or remote error body in terminal output.
    result.pop('output', None)
    result['serverWired'] = False
    print(json.dumps(result))
    return 0 if result['decision'] == 'allow' else 2


if __name__ == '__main__':
    raise SystemExit(main())
