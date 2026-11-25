"""Explicit, synthetic-only OpenAI Responses adapter and audited gateway.

This module is not installed into the offline HTTP server automatically.
"""
from copy import deepcopy
from dataclasses import dataclass, field
import http.client
import json
import os
import re
import ssl

from vape.contracts import digest

HOST = 'api.openai.com'
PATH = '/v1/responses'
DESTINATION = 'cloud-model'
SYNTHETIC_RESOURCE = {
    'id': 'vape-provider-synthetic', 'classification': 'confidential',
    'content': '[SYNTHETIC VAPE TEST] Fictional Acme orders three blue pencils. Summarize in one sentence.'}
MAX_RESPONSE = 1024 * 1024


class ProviderFailure(Exception):
    """Only fixed, non-sensitive status codes may escape the transport."""
    def __init__(self, code, delivery='unknown'):
        super().__init__(code)
        self.code = code
        self.delivery = delivery


@dataclass(frozen=True)
class CloudConfig:
    enabled: bool = False
    model: str = ''
    approved_models: tuple = ()
    api_key: str = field(default='', repr=False, compare=False)

    @classmethod
    def from_environment(cls, environ=None):
        env = os.environ if environ is None else environ
        return cls(enabled=env.get('VAPE_CLOUD_ENABLED') == '1',
                   model=env.get('VAPE_OPENAI_MODEL', ''),
                   approved_models=tuple(x.strip() for x in env.get('VAPE_OPENAI_APPROVED_MODELS', '').split(',') if x.strip()),
                   api_key=env.get('VAPE_OPENAI_API_KEY', ''))

    def blocked_reason(self):
        if self.enabled is not True:
            return 'cloud_disabled'
        if (not isinstance(self.model, str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{1,150}', self.model)
                or not isinstance(self.approved_models, tuple)
                or self.model not in self.approved_models):
            return 'model_not_approved'
        if (not isinstance(self.api_key, str) or not self.api_key
                or any(ord(c) < 33 or ord(c) > 126 for c in self.api_key)):
            return 'project_credential_missing_or_invalid'
        return None


def _post(api_key, payload):
    """Direct TLS only: no proxy environment, redirects, retries, or URL input."""
    connection = http.client.HTTPSConnection(HOST, port=443, timeout=20,
                                             context=ssl.create_default_context())
    try:
        connection.request('POST', PATH, body=json.dumps(payload).encode('utf-8'),
                           headers={'Authorization': 'Bearer ' + api_key,
                                    'Content-Type': 'application/json'})
        response = connection.getresponse()
        # Never read or expose remote error bodies (may contain request content).
        if response.status != 200:
            raise ProviderFailure('provider_http_error', 'received')
        raw = response.read(MAX_RESPONSE + 1)
        if len(raw) > MAX_RESPONSE:
            raise ProviderFailure('provider_response_too_large', 'received')
        try:
            return json.loads(raw)
        except (ValueError, UnicodeError):
            raise ProviderFailure('provider_invalid_json', 'received') from None
    except ProviderFailure:
        raise
    except Exception:
        raise ProviderFailure('provider_transport_unconfirmed') from None
    finally:
        connection.close()


class OpenAICloudAdapter:
    def __init__(self, config, transport=None):
        self.config = config
        # Injection is for trusted local tests, never request input.
        self._transport = _post if transport is None else transport

    def preflight(self, destination, content):
        if destination != DESTINATION:
            return 'destination_not_approved'
        reason = self.config.blocked_reason()
        if reason:
            return reason
        if content != SYNTHETIC_RESOURCE['content']:
            return 'synthetic_fixture_required'
        return None

    def dispatch(self, destination, content):
        reason = self.preflight(destination, content)
        if reason:
            raise ProviderFailure(reason, 'not_sent')
        payload = {'model': self.config.model, 'input': content, 'store': False,
                   'stream': False, 'max_output_tokens': 256, 'tools': []}
        try:
            response = self._transport(self.config.api_key, payload)
        except ProviderFailure:
            raise
        except Exception:
            raise ProviderFailure('provider_transport_unconfirmed') from None
        if not isinstance(response, dict) or response.get('status') != 'completed':
            raise ProviderFailure('provider_incomplete', 'received')
        output = response.get('output')
        if not isinstance(output, list):
            raise ProviderFailure('provider_invalid_output', 'received')
        texts = []
        for item in output:
            if not isinstance(item, dict):
                raise ProviderFailure('provider_invalid_output', 'received')
            if item.get('type') == 'reasoning':
                continue
            if item.get('type') != 'message' or item.get('role') != 'assistant' or item.get('status') != 'completed':
                raise ProviderFailure('provider_unexpected_output', 'received')
            parts = item.get('content')
            if not isinstance(parts, list):
                raise ProviderFailure('provider_invalid_output', 'received')
            for part in parts:
                if not isinstance(part, dict):
                    raise ProviderFailure('provider_invalid_output', 'received')
                if part.get('type') == 'refusal':
                    raise ProviderFailure('provider_refused', 'received')
                if part.get('type') != 'output_text' or not isinstance(part.get('text'), str):
                    raise ProviderFailure('provider_invalid_output', 'received')
                texts.append(part['text'])
        text = '\n'.join(texts)
        if not text.strip():
            raise ProviderFailure('provider_empty_output', 'received')
        try:
            text.encode('utf-8')
        except UnicodeError:
            raise ProviderFailure('provider_invalid_output', 'received') from None
        return text


class CloudGateway:
    """Use the shared evaluator and audit; keep provider outcomes explicit.

    Call under the integration lock if shared across concurrent callers.
    Only this dedicated entrypoint supplies provider metadata and refusal status.
    """
    def __init__(self, policy, audit, adapter):
        self.policy, self.audit, self.adapter = policy, audit, adapter

    def execute(self, request, resource):
        request, resource = deepcopy(request), deepcopy(resource)
        evaluated = self.policy.evaluate(request, resource)
        policy = evaluated['policy']
        valid_request = request if isinstance(request, dict) else {}
        subject = valid_request.get('subject')
        subject = subject if isinstance(subject, dict) else {}
        safe = lambda value: value if isinstance(value, str) else None
        event = {
            'request': {key: safe(valid_request.get(key)) for key in ('resourceId', 'operation', 'destination')},
            'resource': {key: safe(resource.get(key)) if isinstance(resource, dict) else None for key in ('id', 'classification')},
            'decision': evaluated['decision'], 'policyDecision': evaluated['decision'],
            'matchedRuleIds': evaluated['matchedRuleIds'], 'reason': evaluated['reason'],
            'phase': 'result', 'dispatched': False, 'deliveryStatus': 'not_sent',
            'effectStatus': 'not_started', 'outputHash': None, 'intentEventId': None,
            'provider': {'name': 'openai', 'endpoint': 'https://' + HOST + PATH,
                         'model': self.adapter.config.model, 'syntheticOnly': True}}
        event['request']['subject'] = {key: safe(subject.get(key)) for key in ('id', 'role')}
        content = resource.get('content') if isinstance(resource, dict) else None
        event['resource']['contentHash'] = digest(content) if isinstance(content, str) else None
        output, event_id = None, None

        def append(facts):
            receipt = self.audit.append(deepcopy(policy), deepcopy(facts))['event']['eventId']
            if not isinstance(receipt, str) or not receipt:
                raise ValueError('invalid_audit_receipt')
            return receipt

        def result():
            return {key: deepcopy(event[key]) for key in
                    ('decision', 'policyDecision', 'reason', 'deliveryStatus', 'effectStatus', 'intentEventId')} | {
                        'eventId': event_id, 'policyVersion': policy['version'],
                        'output': output, 'retryAutomatically': False}

        if event['decision'] == 'allow':
            reason = ('operation_not_approved' if valid_request.get('operation') != 'model_send'
                      else self.adapter.preflight(valid_request.get('destination'), content))
            if resource != SYNTHETIC_RESOURCE:
                reason = 'synthetic_fixture_required'
            if reason:
                event.update(decision='deny', reason=reason)
            else:
                intent = dict(event, phase='intent', decision='indeterminate', reason='provider_intent_recorded')
                try:
                    event['intentEventId'] = append(intent)
                except Exception:
                    event.update(decision='indeterminate', reason='intent_audit_failed')
                    return result()
                try:
                    output = self.adapter.dispatch(DESTINATION, content)
                    event.update(deliveryStatus='received', effectStatus='completed', dispatched=True,
                                 reason='provider_completed', outputHash=digest(output))
                except ProviderFailure as failure:
                    definitive = failure.code == 'provider_refused' or failure.delivery == 'not_sent'
                    event.update(decision='deny' if definitive else 'indeterminate', reason=failure.code,
                                 deliveryStatus=failure.delivery, dispatched=failure.delivery == 'received',
                                 effectStatus='refused' if failure.code == 'provider_refused' else 'unknown')
                except Exception:
                    event.update(decision='indeterminate', reason='provider_outcome_unconfirmed',
                                 deliveryStatus='unknown', effectStatus='unknown')
        try:
            event_id = append(event)
        except Exception:
            event.update(decision='indeterminate', reason='result_audit_failed')
            output = None
        return result()
