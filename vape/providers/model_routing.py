"""Server-owned classification/context boundary; no file reads or automatic effects.

The resource resolver must atomically resolve registered identity, classification
and bytes in the trusted server. Never construct its return value from HTTP JSON.
This is an in-process trust boundary, not an attestation of an arbitrary caller.
"""
from copy import deepcopy
from dataclasses import dataclass
import threading

from vape.contracts import digest
from vape.providers.openai_cloud import OpenAICloudAdapter, ProviderFailure, _post


@dataclass(frozen=True)
class VerifiedResource:
    id: str
    classification: str
    content: str


@dataclass(frozen=True)
class ServerContext:
    subject_id: str
    role: str
    workflow: str


class ModelPolicy:
    """Exact role/workflow/level/operation/destination/model rules, deny wins."""
    def __init__(self, snapshot):
        p = deepcopy(snapshot)
        if (not isinstance(p, dict) or type(p.get('version')) is not int or p['version'] < 1
                or p.get('default') != 'deny' or not isinstance(p.get('rules'), list)):
            raise ValueError('invalid_model_policy')
        fields = {'id', 'role', 'workflow', 'classification', 'operation', 'destination', 'model', 'effect'}
        ids = set()
        for rule in p['rules']:
            if (not isinstance(rule, dict) or set(rule) != fields
                    or not all(isinstance(rule[k], str) and rule[k].strip() for k in fields - {'model', 'destination'})
                    or rule['id'] in ids or rule['classification'] not in ('L1', 'L2', 'L3')
                    or rule['operation'] not in ('read', 'write', 'model_send', 'tool_send')
                    or rule['effect'] not in ('allow', 'deny')):
                raise ValueError('invalid_model_rule')
            if rule['operation'] == 'model_send':
                if rule['destination'] != 'cloud-model' or not isinstance(rule['model'], str) or not rule['model'].strip():
                    raise ValueError('invalid_model_route')
            elif rule['model'] is not None or (rule['operation'] in ('read', 'write') and rule['destination'] is not None):
                raise ValueError('invalid_effect_route')
            elif rule['operation'] == 'tool_send' and rule['destination'] != 'test-tool':
                raise ValueError('invalid_tool_route')
            ids.add(rule['id'])
        self._snapshot = p

    def snapshot(self):
        return deepcopy(self._snapshot)

    def evaluate(self, resource, context, operation, destination=None, model=None):
        result = {'decision': 'deny', 'reason': 'no_matching_rule', 'matchedRuleIds': []}
        if (type(resource) is not VerifiedResource or type(context) is not ServerContext
                or resource.classification not in ('L1', 'L2', 'L3')
                or not all(isinstance(v, str) and v.strip() for v in
                           (resource.id, context.subject_id, context.role, context.workflow))
                or not isinstance(resource.content, str)):
            result['reason'] = 'unverified_resource_or_context'
            return result
        if operation == 'model_send' and resource.classification == 'L1':
            result['reason'] = 'L1_cloud_forbidden'
            return result
        if operation == 'write' and resource.classification != 'L3':
            result['reason'] = 'original_write_forbidden'
            return result
        matches = [r for r in self._snapshot['rules'] if
                   (r['classification'], r['role'], r['workflow'], r['operation'], r['destination'], r['model']) ==
                   (resource.classification, context.role, context.workflow, operation, destination, model)]
        result['matchedRuleIds'] = [r['id'] for r in matches]
        if any(r['effect'] == 'deny' for r in matches):
            result['reason'] = 'explicit_deny'
        elif matches:
            result.update(decision='allow', reason='explicit_allow')
        return result


class ModelRouter:
    """Synthetic cloud execution only; effect checks never execute writes/tools.

    resolve_resource(id) and resolve_context() are trusted injected server services.
    approve_effect(facts) must check a separate server-owned approval bound to the
    exact identity, content hash, policy hash, operation and target. No client
    approval field is accepted. A returned permission check is NOT a reusable
    capability: the effect owner must recheck at execution under its own lock.
    """
    def __init__(self, policy, resolve_resource, resolve_context, adapter, audit,
                 approve_effect=None, allow_external=False):
        if type(adapter) is not OpenAICloudAdapter:
            raise ValueError('fixed_cloud_adapter_required')
        self.policy = policy
        self._resource, self._context = resolve_resource, resolve_context
        self.adapter, self.audit = adapter, audit
        self._approve = approve_effect
        self._allow_external = allow_external is True
        self._lock = threading.RLock()

    def _resolve(self, resource_id):
        if not isinstance(resource_id, str) or not resource_id.strip():
            raise ValueError('invalid_resource_id')
        resource, context = self._resource(resource_id), self._context()
        if type(resource) is not VerifiedResource or type(context) is not ServerContext or resource.id != resource_id:
            raise ValueError('unverified_resource_or_context')
        # Ensure hashes can be recorded before any side effect.
        digest(resource.content)
        return resource, context

    def check_effect(self, resource_id, operation, destination=None):
        """Check read/write/tool separately; no filesystem or tool side effect."""
        with self._lock:
            try:
                resource, context = self._resolve(resource_id)
            except Exception:
                return {'decision': 'deny', 'reason': 'resource_resolution_failed'}
            if operation not in ('read', 'write', 'tool_send'):
                return {'decision': 'deny', 'reason': 'invalid_effect_operation'}
            result = self.policy.evaluate(resource, context, operation, destination)
            if result['decision'] == 'allow' and operation in ('write', 'tool_send'):
                facts = {'resourceId': resource.id, 'classification': resource.classification,
                         'contentHash': digest(resource.content), 'subjectId': context.subject_id,
                         'role': context.role, 'workflow': context.workflow, 'operation': operation,
                         'destination': destination, 'policyHash': digest(self.policy.snapshot()),
                         'policyVersion': self.policy.snapshot()['version']}
                try:
                    approved = self._approve is not None and self._approve(deepcopy(facts)) is True
                except Exception:
                    approved = False
                if not approved:
                    result.update(decision='deny', reason='separate_server_approval_required')
            return result

    def execute(self, request):
        with self._lock:
            return self._execute(request)

    def _execute(self, request):
        snapshot = self.policy.snapshot()
        event = {'request': {'operation': 'model_send'},
                 'resource': {'id': None, 'classification': None, 'contentHash': digest(None)},
                 'resourceResolved': False,
                 'policyDecision': 'deny', 'decision': 'deny', 'reason': 'invalid_request',
                 'matchedRuleIds': [], 'phase': 'result', 'intentEventId': None,
                 'deliveryStatus': 'not_sent', 'effectStatus': 'not_started',
                 'dispatched': False, 'outputHash': None,
                 'provider': {'name': 'openai', 'destination': 'cloud-model',
                              'model': self.adapter.config.model, 'syntheticOnly': True}}
        output, event_id, resource = None, None, None
        try:
            if (not isinstance(request, dict) or set(request) != {'resourceId', 'model', 'destination'}
                    or not all(isinstance(v, str) and v.strip() for v in request.values())):
                raise ValueError('invalid_request')
            resource, context = self._resolve(request['resourceId'])
            event['request'].update(resourceId=resource.id, destination=request['destination'],
                                    subject={'id': context.subject_id, 'role': context.role},
                                    workflow=context.workflow, model=request['model'])
            event['resourceResolved'] = True
            event['resource'] = {'id': resource.id, 'classification': resource.classification,
                                 'contentHash': digest(resource.content)}
            evaluated = self.policy.evaluate(resource, context, 'model_send', request['destination'], request['model'])
            event.update(evaluated, policyDecision=evaluated['decision'])
            if event['decision'] == 'allow':
                reason = None
                if request['model'] != self.adapter.config.model:
                    reason = 'configured_model_mismatch'
                elif self.adapter._transport is _post and not self._allow_external:
                    reason = 'external_communication_not_authorized'
                else:
                    reason = self.adapter.preflight(request['destination'], resource.content)
                if reason:
                    event.update(decision='deny', reason=reason)
        except Exception:
            event.update(decision='deny', policyDecision='deny', reason='invalid_or_unverified_request')

        def append(facts):
            receipt = self.audit.append(deepcopy(snapshot), deepcopy(facts))['event']['eventId']
            if not isinstance(receipt, str) or not receipt:
                raise ValueError('invalid_audit_receipt')
            return receipt

        def response():
            return {key: deepcopy(event[key]) for key in ('decision', 'policyDecision', 'reason',
                    'deliveryStatus', 'effectStatus', 'intentEventId')} | {
                        'eventId': event_id, 'policyVersion': snapshot['version'], 'output': output,
                        'retryAutomatically': False, 'grantedEffects': []}

        if event['decision'] == 'allow':
            try:
                event['intentEventId'] = append(dict(event, phase='intent', decision='indeterminate', reason='model_intent'))
            except Exception:
                event.update(decision='indeterminate', reason='intent_audit_failed')
                return response()
            try:
                output = self.adapter.dispatch('cloud-model', resource.content)
                event.update(reason='model_completed', deliveryStatus='received', effectStatus='completed',
                             dispatched=True, outputHash=digest(output))
            except ProviderFailure as failure:
                event.update(decision='deny' if failure.code == 'provider_refused' or failure.delivery == 'not_sent' else 'indeterminate',
                             reason=failure.code, deliveryStatus=failure.delivery,
                             effectStatus='refused' if failure.code == 'provider_refused' else 'unknown',
                             dispatched=failure.delivery == 'received')
            except Exception:
                event.update(decision='indeterminate', reason='model_outcome_unconfirmed',
                             deliveryStatus='unknown', effectStatus='unknown')
        try:
            event_id = append(event)
        except Exception:
            output = None
            event.update(decision='indeterminate', reason='result_audit_failed')
        return response()
