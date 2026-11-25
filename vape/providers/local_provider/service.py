"""Ollama local-only boundary. Trust runtime isolation, not the word localhost.

Only LocalGateway.execute is the integration entrypoint. File selection and
classification come from an injected trusted broker; request-supplied resources,
URLs, models and content are rejected. No start/pull/install/cloud fallback exists.
"""
from copy import deepcopy
from dataclasses import dataclass
import hashlib
import http.client
import json
from pathlib import Path
import re

from vape.contracts import digest

HOST = '127.0.0.1'
DESTINATION = 'local-model'
MAX_CONTENT = 64 * 1024
MAX_REPLY = 1024 * 1024
_HASH = re.compile(r'[0-9a-f]{64}\Z')
_MODEL = re.compile(r'[a-zA-Z0-9_.-]+:[a-zA-Z0-9_.-]+\Z')


class LocalFailure(Exception):
    def __init__(self, code, delivery='not_sent'):
        super().__init__(code)
        self.code, self.delivery = code, delivery


@dataclass(frozen=True)
class LocalConfig:
    enabled: bool = False
    model: str = ''
    approved_models: tuple = ()
    model_digest: str = ''
    port: int = 11434  # Fixed by trusted constructor, never read from a request/URL.

    def blocked_reason(self):
        if self.enabled is not True:
            return 'local_disabled'
        if (not isinstance(self.model, str) or not _MODEL.fullmatch(self.model)
                or any(x in self.model.lower() for x in ('cloud', 'remote'))
                or not isinstance(self.approved_models, tuple) or self.model not in self.approved_models):
            return 'local_model_not_approved'
        if not isinstance(self.model_digest, str) or not _HASH.fullmatch(self.model_digest):
            return 'local_model_digest_missing'
        if type(self.port) is not int or not 1024 <= self.port <= 65535 or self.port == 8765:
            return 'local_endpoint_invalid'
        return None


@dataclass(frozen=True)
class RuntimeEvidence:
    """Operator pins, not client input. Hashes do not prove process isolation.

    The runtime_guard additionally must attest the owned listener/process, exact
    model-to-weight mapping, OLLAMA_NO_CLOUD=1 and enforced no-external-egress
    boundary. Missing guard means no HTTP request is made.
    """
    project_root: Path
    executable: Path
    executable_sha256: str
    weights: Path
    weights_sha256: str

    def verify_files(self):
        try:
            root = Path(self.project_root).resolve(strict=True)
            for path, expected, model in ((self.executable, self.executable_sha256, False),
                                          (self.weights, self.weights_sha256, True)):
                path = Path(path)
                if not isinstance(expected, str) or not _HASH.fullmatch(expected):
                    return False
                if path.is_symlink() or root not in path.resolve(strict=True).parents or not path.is_file():
                    return False
                checksum = hashlib.sha256()
                with path.open('rb') as stream:
                    if model and stream.read(4) != b'GGUF':
                        return False
                    stream.seek(0)
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                        checksum.update(chunk)
                if checksum.hexdigest() != expected:
                    return False
            return True
        except (OSError, ValueError, TypeError):
            return False


def _request(port, method, path, payload=None):
    """Direct numeric loopback; http.client ignores proxy env and redirects."""
    if (method, path) not in (('GET', '/api/tags'), ('POST', '/api/show'), ('POST', '/api/generate')):
        raise LocalFailure('local_route_forbidden')
    connection = http.client.HTTPConnection(HOST, port, timeout=20)
    attempted = False
    try:
        body = None if payload is None else json.dumps(payload, ensure_ascii=False, allow_nan=False).encode('utf-8')
        attempted = True
        connection.request(method, path, body=body, headers={'Content-Type': 'application/json'})
        response = connection.getresponse()
        if response.status != 200:
            raise LocalFailure('local_http_error', 'received')
        if response.getheader('Content-Type', '').split(';')[0].strip() != 'application/json':
            raise LocalFailure('local_response_type_invalid', 'received')
        raw = response.read(MAX_REPLY + 1)
        if len(raw) > MAX_REPLY:
            raise LocalFailure('local_response_too_large', 'received')
        value = json.loads(raw, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if not isinstance(value, dict):
            raise LocalFailure('local_response_invalid', 'received')
        return value
    except LocalFailure:
        raise
    except (ValueError, UnicodeError):
        raise LocalFailure('local_response_invalid', 'received') from None
    except Exception:
        raise LocalFailure('local_transport_unconfirmed', 'unknown' if attempted else 'not_sent') from None
    finally:
        connection.close()


def _remote(value):
    if isinstance(value, dict):
        return any((key in ('remote_host', 'remote_model', 'remote', 'cloud') and item not in (None, '', False))
                   or _remote(item) for key, item in value.items())
    if isinstance(value, list):
        return any(_remote(item) for item in value)
    return False


class LocalGateway:
    def __init__(self, policy, audit, config=None, *, resolve_selection=None, evidence=None, runtime_guard=None):
        self.policy, self.audit = policy, audit
        self.config = LocalConfig() if config is None else config
        self.resolve_selection, self.evidence, self.runtime_guard = resolve_selection, evidence, runtime_guard

    def _runtime_ready(self):
        reason = self.config.blocked_reason()
        if reason:
            raise LocalFailure(reason)
        if (not isinstance(self.evidence, RuntimeEvidence) or not self.evidence.verify_files()
                or not callable(self.runtime_guard)):
            raise LocalFailure('local_runtime_or_weights_unverified')
        try:
            ready = self.runtime_guard(self.evidence, HOST, self.config.port,
                                       self.config.model, self.config.model_digest)
        except Exception:
            ready = False
        if ready is not True:
            raise LocalFailure('local_runtime_isolation_unverified')

    def _model_ready(self):
        self._runtime_ready()
        listed = _request(self.config.port, 'GET', '/api/tags')
        models = listed.get('models')
        if not isinstance(models, list):
            raise LocalFailure('local_model_metadata_invalid')
        matches = [m for m in models if isinstance(m, dict) and m.get('name') == self.config.model]
        if len(matches) != 1:
            raise LocalFailure('local_model_not_installed')
        model = matches[0]
        if (_remote(model) or model.get('digest') != self.config.model_digest
                or not isinstance(model.get('details'), dict) or model['details'].get('format') != 'gguf'
                or type(model.get('size')) is not int or model['size'] <= 0):
            raise LocalFailure('local_model_identity_invalid')
        shown = _request(self.config.port, 'POST', '/api/show', {'model': self.config.model})
        if (_remote(shown) or not isinstance(shown.get('details'), dict)
                or shown['details'].get('format') != 'gguf'
                or not isinstance(shown.get('capabilities'), list) or 'completion' not in shown['capabilities']):
            raise LocalFailure('local_model_capability_invalid')

    def execute(self, request, selection_id):
        """Under the coordinator's serialization lock; no public direct-dispatch API.

        resolver(selection_id) must revalidate an explicit native file selection
        and trusted classification and return {id, classification, content}.
        In-process injected code is trusted; never derive it from JSON requests.
        """
        outcome = {'decision': 'deny', 'policyDecision': None, 'reason': 'local_request_invalid',
                   'policyVersion': None, 'eventId': None, 'intentEventId': None, 'output': None,
                   'deliveryStatus': 'not_sent', 'effectStatus': 'not_started', 'retryAutomatically': False}
        if (not isinstance(request, dict) or set(request) != {'subject','resourceId','operation','destination'}
                or request.get('operation') != 'model_send' or request.get('destination') != DESTINATION):
            return outcome
        subject = request.get('subject')
        if (not isinstance(subject, dict) or set(subject) != {'id','role'}
                or not all(isinstance(v,str) and 0 < len(v) <= 128 for v in subject.values())
                or not isinstance(request.get('resourceId'),str) or not 0 < len(request['resourceId']) <= 128):
            return outcome
        if not isinstance(selection_id, str) or not selection_id or not callable(self.resolve_selection):
            outcome['reason'] = 'trusted_file_selection_required'
            return outcome
        request = deepcopy(request)
        try:
            resource = deepcopy(self.resolve_selection(selection_id))
            if (not isinstance(resource, dict) or set(resource) != {'id','classification','content'}
                    or not all(isinstance(v,str) and v for v in resource.values())
                    or len(resource['content'].encode('utf-8')) > MAX_CONTENT):
                raise ValueError()
        except Exception:
            outcome['reason'] = 'trusted_file_selection_invalid'
            return outcome
        try:
            evaluated = self.policy.evaluate(request, resource)
        except Exception:
            outcome.update(decision='indeterminate', reason='local_policy_unavailable')
            return outcome
        policy = evaluated['policy']
        outcome.update(decision=evaluated['decision'], policyDecision=evaluated['decision'],
                       reason=evaluated['reason'], policyVersion=policy['version'])
        event = {'request': request, 'resource': {'id':resource['id'], 'classification':resource['classification'],
                  'contentHash':digest(resource['content'])}, 'matchedRuleIds':evaluated['matchedRuleIds'],
                 'provider': {'name':'ollama-local', 'model':self.config.model, 'modelDigest':self.config.model_digest,
                              'endpoint':'http://'+HOST+':'+str(self.config.port), 'cloudFallback':False}}

        def append(phase):
            facts = dict(event, **{k:outcome[k] for k in ('decision','policyDecision','reason','intentEventId',
                                                       'deliveryStatus','effectStatus')})
            facts.update(phase=phase, dispatched=outcome['deliveryStatus']=='received',
                         outputHash=digest(outcome['output']) if outcome['output'] is not None else None)
            receipt = self.audit.append(deepcopy(policy), deepcopy(facts))['event']['eventId']
            if not isinstance(receipt,str) or not receipt:
                raise ValueError('audit_receipt_invalid')
            return receipt

        if outcome['decision'] == 'allow':
            try:
                self._model_ready()  # Only metadata; never carries selected plaintext.
            except Exception as failure:
                outcome.update(decision='deny', reason=failure.code if isinstance(failure,LocalFailure) else 'local_preflight_failed')
            else:
                outcome.update(decision='indeterminate', reason='local_intent_recorded')
                try:
                    outcome['intentEventId'] = append('intent')
                except Exception:
                    outcome['reason'] = 'local_intent_audit_failed'
                    return outcome
                try:
                    self._runtime_ready()  # Guard must keep model/process immutable across the call.
                    value = _request(self.config.port, 'POST', '/api/generate',
                                     {'model':self.config.model, 'prompt':resource['content'], 'stream':False,
                                      'keep_alive':0, 'options':{'num_predict':256}})
                    if (_remote(value) or value.get('model') != self.config.model or value.get('done') is not True
                            or value.get('done_reason') != 'stop' or not isinstance(value.get('response'),str)
                            or not value['response'].strip()):
                        raise LocalFailure('local_generation_incomplete', 'received')
                    value['response'].encode('utf-8')
                    outcome.update(decision='allow', reason='local_generation_completed', output=value['response'],
                                   deliveryStatus='received', effectStatus='completed')
                except LocalFailure as failure:
                    outcome.update(decision='deny' if failure.delivery=='not_sent' else 'indeterminate',
                                   reason=failure.code, deliveryStatus=failure.delivery,
                                   effectStatus='not_started' if failure.delivery=='not_sent' else 'unknown')
                except Exception:
                    outcome.update(decision='indeterminate', reason='local_generation_unconfirmed',
                                   deliveryStatus='unknown', effectStatus='unknown')
        try:
            outcome['eventId'] = append('result')
        except Exception:
            outcome.update(decision='indeterminate', reason='local_result_audit_failed', output=None)
        return deepcopy(outcome)
