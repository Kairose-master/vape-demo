"""Pure policy decisions with injected delivery and audit boundaries."""
from copy import deepcopy

from vape.contracts import DESTINATIONS, OPERATIONS, digest


def _text(value):
    return isinstance(value, str) and bool(value.strip())


def _destination(operation, destination):
    if operation in ('read', 'write'):
        return destination is None
    return (isinstance(destination, str) and destination in DESTINATIONS
            and DESTINATIONS[destination]['kind'] ==
            {'model_send': 'model', 'tool_send': 'tool'}.get(operation))


class PolicyService:
    def __init__(self, initial_policy):
        policy = deepcopy(initial_policy)
        self._validate_policy(policy)
        self._policy = policy

    @staticmethod
    def _validate_policy(policy):
        if not isinstance(policy, dict):
            raise ValueError('Policy must be an object')
        if type(policy.get('version')) is not int or policy['version'] < 1:
            raise ValueError('Policy version must be a positive integer')
        if policy.get('default') != 'deny' or not _text(policy.get('organization')):
            raise ValueError('Policy requires organization and default deny')
        for key in ('roles', 'classifications'):
            values = policy.get(key)
            if (not isinstance(values, list) or not values
                    or not all(_text(v) for v in values)
                    or len(set(values)) != len(values)):
                raise ValueError('Invalid ' + key)
        rules = policy.get('rules')
        if not isinstance(rules, list):
            raise ValueError('Rules must be a list')
        seen = set()
        fields = {'id', 'role', 'classification', 'operation', 'destination', 'effect'}
        for rule in rules:
            if (not isinstance(rule, dict) or set(rule) != fields
                    or not _text(rule.get('id')) or rule['id'] in seen
                    or rule.get('role') not in policy['roles']
                    or rule.get('classification') not in policy['classifications']
                    or rule.get('operation') not in OPERATIONS
                    or rule.get('effect') not in ('allow', 'deny')
                    or not _destination(rule['operation'], rule['destination'])):
                raise ValueError('Invalid policy rule')
            seen.add(rule['id'])

    def get_policy(self):
        return deepcopy(self._policy)

    def update_test_tool(self, effect, expected_version):
        if effect not in ('allow', 'deny'):
            raise ValueError('Effect must be allow or deny')
        if type(expected_version) is not int or expected_version != self._policy['version']:
            raise ValueError('Stale or invalid policy version')
        policy = self.get_policy()
        rule = next((r for r in policy['rules'] if r['id'] == 'test-tool-rule'), None)
        if rule is None or rule['operation'] != 'tool_send' or rule['destination'] != 'test-tool':
            raise ValueError('Test tool rule is unavailable')
        rule['effect'] = effect
        policy['version'] += 1
        self._policy = policy
        return self.get_policy()

    def evaluate(self, request, resource):
        request, resource = deepcopy(request), deepcopy(resource)
        policy = self.get_policy()
        result = {'decision': 'deny', 'reason': 'Invalid request or resource',
                  'matchedRuleIds': [], 'policy': policy}
        if not isinstance(request, dict) or not isinstance(resource, dict):
            return result
        required = {'subject', 'resourceId', 'operation', 'destination'}
        subject = request.get('subject')
        if (not required.issubset(request) or set(request) - (required | {'content'})
                or not isinstance(subject, dict) or set(subject) != {'id', 'role'}
                or not _text(subject.get('id')) or not _text(subject.get('role'))
                or not _text(resource.get('id')) or not _text(resource.get('classification'))
                or not isinstance(resource.get('content'), str)
                or request['resourceId'] != resource['id']
                or request['operation'] not in OPERATIONS):
            return result
        operation = request['operation']
        if ((operation == 'write' and not isinstance(request.get('content'), str))
                or (operation != 'write' and 'content' in request)
                or not _destination(operation, request['destination'])):
            return result
        if subject['role'] not in policy['roles'] or resource['classification'] not in policy['classifications']:
            result['reason'] = 'Unknown role or classification'
            return result
        matches = [r for r in policy['rules']
                   if r['role'] == subject['role']
                   and r['classification'] == resource['classification']
                   and r['operation'] == operation
                   and r['destination'] == request['destination']]
        result['matchedRuleIds'] = [r['id'] for r in matches]
        if any(r['effect'] == 'deny' for r in matches):
            result['reason'] = 'Explicit deny rule'
        elif matches:
            result.update(decision='allow', reason='Explicit allow rule')
        else:
            result['reason'] = 'Default deny: no matching rule'
        return result

    def execute(self, request, resource, dispatch, audit):
        original_resource = resource
        request, resource = deepcopy(request), deepcopy(resource)
        result = self.evaluate(request, resource)
        policy_decision = result['decision']
        operation = request.get('operation') if isinstance(request, dict) else None
        sending = operation in ('model_send', 'tool_send')
        output, event_id, intent_id = None, None, None
        delivery = 'not_sent' if sending else 'not_applicable'
        effect = 'not_started'
        safe_request = {}
        if isinstance(request, dict):
            for key in ('resourceId', 'operation', 'destination'):
                value = request.get(key)
                safe_request[key] = value if isinstance(value, str) else None
            subject = request.get('subject')
            safe_request['subject'] = {
                key: subject.get(key) if isinstance(subject, dict) and isinstance(subject.get(key), str) else None
                for key in ('id', 'role')}
            if operation == 'write' and isinstance(request.get('content'), str):
                safe_request['contentHash'] = digest(request['content'])
        safe_resource = resource if isinstance(resource, dict) else {}
        content = safe_resource.get('content')
        event = {'request': safe_request,
                 'resource': {key: safe_resource.get(key) if isinstance(safe_resource.get(key), str) else None
                              for key in ('id', 'classification')},
                 'decision': result['decision'], 'policyDecision': policy_decision,
                 'reason': result['reason'], 'matchedRuleIds': result['matchedRuleIds'],
                 'dispatched': False, 'outputHash': None, 'phase': 'result',
                 'deliveryStatus': delivery, 'effectStatus': effect}
        event['resource']['contentHash'] = digest(content) if isinstance(content, str) else None

        def append(facts):
            bundle = audit.append(deepcopy(result['policy']), deepcopy(facts))
            receipt = bundle['event']['eventId']
            if not _text(receipt):
                raise ValueError('Invalid audit receipt')
            return receipt

        def response():
            return deepcopy({'decision': result['decision'], 'policyDecision': policy_decision,
                             'reason': result['reason'], 'policyVersion': result['policy']['version'],
                             'eventId': event_id, 'intentEventId': intent_id, 'output': output,
                             'deliveryStatus': delivery, 'effectStatus': effect, 'retryAutomatically': False})

        if policy_decision == 'allow' and (sending or operation == 'write'):
            intent = dict(event, phase='intent', decision='indeterminate',
                          reason='Authorized intent recorded; execution outcome not yet established')
            try:
                intent_id = append(intent)
            except Exception:
                result.update(decision='indeterminate', reason='Intent audit unavailable; no side effect attempted')
                return response()
            try:
                if sending:
                    # One attempt only. A missing acknowledgement cannot establish non-delivery.
                    delivery, effect = 'unknown', 'unknown'
                    output = dispatch(request['destination'], resource['content'])
                    if not isinstance(output, str):
                        raise ValueError('Invalid dispatch output')
                    delivery, effect = 'received', 'completed'
                else:
                    effect = 'unknown'
                    original_resource['content'] = request['content']
                    output, effect = request['content'], 'completed'
            except Exception:
                result.update(decision='indeterminate', reason='Effect outcome unconfirmed; do not automatically retry')
                output = None
        elif policy_decision == 'allow':
            output = resource['content']
            effect = 'completed'

        event.update(decision=result['decision'], reason=result['reason'],
                     intentEventId=intent_id, deliveryStatus=delivery, effectStatus=effect,
                     dispatched=delivery == 'received', outputHash=digest(output) if output is not None else None)
        try:
            event_id = append(event)
        except Exception:
            result.update(decision='indeterminate', reason='Final audit unavailable; outcome cannot be fully verified; do not automatically retry')
            output, event_id = None, None
        return response()
