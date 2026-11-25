# VAPE contract v1 (frozen baseline)
## Scope
Offline Python 3.9+ stdlib, JSON over localhost HTTP; UTF-8. Synthetic document and policy are in fixtures. Organization-defined classifications and roles are arbitrary nonempty strings, never a hardcoded clearance ranking. Operations are distinct: read, write, model_send, tool_send. Default deny; explicit matching deny wins; otherwise matching allow; otherwise deny. Invalid requests fail closed and never dispatch. Resource classification comes from stored document, never from request. Destination kind must match operation; read/write destination is null. Unknown destination/role/classification/operation denies. Write requires its own rule, never inherits read.

## Python boundary — policy owner
Implement `vape/policy/service.py`:
- `PolicyService(initial_policy: dict)`; deep-copy all inputs/outputs.
- `get_policy() -> dict`
- `update_test_tool(effect: str, expected_version: int) -> dict`: only test-tool-rule.effect changes, new monotonically incremented version; stale version raises ValueError. Old policy remains immutable. effect allow/deny only.
- `evaluate(request: dict, resource: dict) -> dict`: returns {decision: allow|deny, reason: str, matchedRuleIds: list[str], policy: dict}. Does not dispatch.
- `execute(request: dict, resource: dict, dispatch: callable, audit: object) -> dict`: dispatch(destination_id, content) only for allowed model_send/tool_send; read returns resource content; write accepts request.content and mutates provided resource only when allowed. Dispatch returns output string. On unconfirmed effect or audit failure return decision indeterminate; never imply blocking after a possible delivery. Record via audit.append(policy, event). Returns {decision, policyDecision, reason, policyVersion, eventId, intentEventId, output, deliveryStatus, effectStatus, retryAutomatically:false}; output null on deny/indeterminate.
Request: {subject:{id:str,role:str}, resourceId:str, operation:str, destination:str|null, content?:str}. No request-supplied URLs accepted.
Event before audit: {request:dict, resource:{id,classification,contentHash}, decision, reason, matchedRuleIds, dispatched:bool, outputHash:str|null}, plus integration outcome fields described below. contentHash hashes canonical content string using shared digest. Do not log document plaintext in event. Preserve subject and operation as independent facts. Integration serializes requests; no concurrency requirement beyond lock at HTTP integration boundary.

## Python boundary — audit owner
Implement `vape/audit/service.py`:
- `AuditService(data_dir: pathlib.Path)` owns ONLY its runtime directory, with demo HMAC key generated there; do not commit keys. HMAC-SHA256 is a symmetric demo signature, not independent identity/nonrepudiation. stdlib only.
- `append(policy: dict, event: dict) -> dict`: adds eventId UUID, timestamp UTC, policyVersion and policyHash; stores immutable snapshot and signed event; append-only log; returns complete evidence bundle.
- `get_bundle(event_id: str) -> dict`: deep-copy frozen bundle, never upgrade its checkpoint after later events.
- `list_events() -> list[dict]`: recorded event dicts.
- `verify(bundle: dict) -> dict`: {verdict:allow|deny|indeterminate, valid:bool, checks:dict, reason:str}; missing/malformed evidence, bad signatures, snapshot mismatch, untrusted/missing checkpoint or invalid inclusion => indeterminate, never deny/allow. Valid historical evidence returns historical decision, not current policy. A valid intent/unresolved result has valid:true but verdict:indeterminate; validity does not imply successful execution. Catch malformed bundles instead of raising.
Bundle keys: {event:dict, policy:dict, signature:str, proof:{leafIndex:int,treeSize:int,siblings:list[{side:left|right,hash:str}]}, checkpoint:{id:str,root:str,treeSize:int,kind:"file-mock-anchor"}}. Signature covers canonical event; event includes policy hash. Leaf = SHA256(0x00 || canonical({event,signature})); parent = SHA256(0x01 || left_digest_bytes || right_digest_bytes). Odd node duplicates itself. Checkpoints are locally persisted immutable file records, verified against trusted local files; a supplied self-consistent root alone is not trusted. Local files/key can be altered by machine owner: clearly disclose no external trust/chain. Future permissioned chain adapter is documentation only.

## HTTP boundary — integration owner
Use JSON errors with appropriate status, no 500 for routine invalid input. Bind loopback, disallow cross-origin mutations, cap bodies. Serve local assets without external fonts/CDNs. Mock destination server is separate loopback listener on ephemeral port; registry IDs map to that server ONLY. local-model/cloud-model are BOTH mock endpoints; deployment label does not imply real cloud access. Tool receipt count is measured at mock receiver, not inferred from policy.
- GET /api/health -> {status,contract}
- GET /api/document -> stored synthetic document
- GET /api/policy -> policy snapshot
- POST /api/policy/test-tool {expectedVersion,effect} -> new policy; only this rule editable in demo workflow
- POST /api/execute request -> PolicyService.execute result
- GET /api/events -> {events:[event,...]}
- GET /api/evidence/{eventId} -> evidence bundle
- POST /api/verify {bundle} -> audit verification result
- GET /api/destinations -> {destinations: shared registry, receipts:{local-model:int,cloud-model:int,test-tool:int}}

## UI owner
Implement web/index.html, web/app.js, web/styles.css (additional web assets allowed). Korean presentable dashboard: clear synthetic/offline/demo labels, organization classification/role policy table, read/write/model/tool distinction, destination deployment labels, document preview, run sequence read -> approved model summary -> blocked tool; show actual receiver counters. Let user change ONLY test destination rule, rerun and compare old/new immutable policy/evidence. Event explorer shows policy version, signature, Merkle path/root/checkpoint type and verifier checks. Include verify original / tampered copy / absent evidence controls. Indeterminate is visible and distinct from deny. API errors must remain errors, never display pretend success. Use fetch only same-origin API; no external assets. Baseline endpoints intentionally 501.

## Acceptance beyond baseline
Actual HTTP test must prove same document read allowed, approved mock model receives once, blocked mock tool receives zero; changing only test rule allows tool, previous full evidence unchanged and still denied; corrupted/missing evidence indeterminate. Component tests also cover write vs read, unknown subject/classification/destination, explicit deny priority, stale policy edit, malformed proofs, changed signature/policy/root, odd tree size, immutable old checkpoints, restart persistence. No offensive testing or external targets.

## Integration outcome amendment (2026-11-24)
Before any allowed model/tool send or write, append an immutable `phase:intent` event with `decision:indeterminate`, `policyDecision:allow`. On intent append failure, stop before the effect. On effect completion/exception append `phase:result`, linked by `intentEventId`; never retry dispatch automatically. Denied requests and reads need a result record only. Missing result cannot be interpreted as deny or allow.

Response and signed event fields:
- `policyDecision`: original authorization allow/deny; separate from execution `decision` (allow/deny/indeterminate).
- `deliveryStatus`: not_sent, received (receiver acknowledgement), unknown (attempted but unconfirmed), not_applicable (read/write).
- `effectStatus`: not_started, completed, unknown.
- `intentEventId`: immutable pre-effect record ID or null. `eventId`: final record ID or null on final audit failure.
- `retryAutomatically:false` on response. No background retry exists. Before any manual rerun of an indeterminate execution inspect receiver counters and available evidence.
Final audit failure after acknowledgement returns indeterminate + received/completed, not deny. Lost acknowledgement returns indeterminate + unknown even if the actual receiver counter increased. UI must show 판정 불가, distinguish policy permission from effect, and not coerce indeterminate to blocked.

Audit append uses an internal RLock in addition to the integration lock. An OSError while writing poisons further appends in that service instance; restart validates persisted evidence before more effects. This is conservative local failure handling, not cross-process transaction or exactly-once delivery. Do not run multiple servers against the same runtime directory.
