'use strict';
(() => {
  const $ = id => document.getElementById(id);
  const labels = {allow: '허용', deny: '차단', indeterminate: '판정 불가', read: '읽기', write: '쓰기', model_send: '모델 전송', tool_send: '도구 전송'};
  const deliveryLabels = {not_sent: '미전송', received: '수신 확인', unknown: '수신 여부 확인 불가', not_applicable: '전송 작업 아님'};
  const effectLabels = {not_started: '미시작', completed: '완료', unknown: '확인 불가'};
  const state = {policy: null, document: null, bundle: null, busy: false, ready: false};
  const actionIds = ['refresh', 'sequence', 'read', 'write', 'tool', 'update-policy', 'verify-original', 'verify-tampered', 'verify-absent', 'events', 'subject', 'role', 'model', 'effect', 'write-content'];
  function node(tag, text, className) {
    const element = document.createElement(tag);
    if (text !== undefined) element.textContent = String(text);
    if (className) element.className = className;
    return element;
  }
  function badge(value) { return node('span', labels[value] || '알 수 없음', 'badge ' + (['allow', 'deny', 'indeterminate'].includes(value) ? value : 'indeterminate')); }
  function controls() {
    actionIds.forEach(id => { $(id).disabled = state.busy || (id !== 'refresh' && !state.ready) || (['verify-original', 'verify-tampered'].includes(id) && !state.bundle); });
  }
  async function api(path, body) {
    const response = await fetch(path, {method: body === undefined ? 'GET' : 'POST', headers: {'Content-Type': 'application/json'}, credentials: 'same-origin', ...(body === undefined ? {} : {body: JSON.stringify(body)})});
    let data;
    try { data = await response.json(); } catch (_) { throw new Error(`HTTP ${response.status}: JSON 응답이 아닙니다 (${path})`); }
    if (!response.ok) throw new Error(`HTTP ${response.status}: ${data.error || data.reason || 'API 오류'} (${path})`);
    return data;
  }
  async function task(fn) {
    if (state.busy) return;
    const initiator = document.activeElement;
    state.busy = true; $('error').hidden = true; $('main').setAttribute('aria-busy', 'true'); $('status').textContent = '처리 중 · API 응답을 기다리고 있습니다.'; controls();
    try { await fn(); } catch (error) { $('observation').textContent = '관측 갱신 실패 · 남아 있는 값은 마지막 성공 응답입니다. 현재 상태를 보장하지 않습니다.'; $('error').textContent = error.message; $('error').hidden = false; $('status').textContent = '요청 확인 실패 · 자동 재전송하지 않습니다. 수신 횟수와 기록을 확인한 뒤 수동 실행 여부를 결정하세요.'; }
    finally { state.busy = false; $('main').setAttribute('aria-busy', 'false'); controls(); if (initiator && initiator !== document.body && document.activeElement === document.body) initiator.focus(); }
  }
  function renderPolicy(policy) {
    if (!Array.isArray(policy.rules) || !Array.isArray(policy.roles) || !Array.isArray(policy.classifications) || !Number.isInteger(policy.version)) throw new Error('정책 응답 형식 오류');
    state.policy = policy; $('overview-policy').textContent = `v${policy.version}`;
    $('policy-version').textContent = `현재 정책 v${policy.version}`;
    $('vocabulary').textContent = `${policy.organization} · 역할: ${policy.roles.join(', ')} · 분류: ${policy.classifications.join(', ')} · 기본: ${labels[policy.default] || policy.default}`;
    $('rules').replaceChildren(...policy.rules.map(rule => {
      const row = node('tr');
      [rule.id, rule.role, rule.classification, labels[rule.operation] || rule.operation, rule.destination || '없음'].forEach(value => row.append(node('td', value)));
      const cell = node('td'); cell.append(badge(rule.effect)); row.append(cell); return row;
    }));
    const selectedRole = $('role').value;
    $('role').replaceChildren(...policy.roles.map(role => { const option = node('option', role); option.value = role; return option; }));
    if (policy.roles.includes(selectedRole)) $('role').value = selectedRole;
    const rule = policy.rules.find(item => item.id === 'test-tool-rule');
    if (rule) $('effect').value = rule.effect;
    renderHistorical();
  }
  async function refreshDestinations() {
    const data = await api('/api/destinations');
    if (!data.destinations || !data.receipts) throw new Error('목적지 응답 형식 오류');
    const cards = Object.entries(data.destinations).map(([id, destination]) => {
      const count = data.receipts[id];
      if (!Number.isInteger(count) || count < 0) throw new Error('실제 수신 횟수 응답 형식 오류');
      const card = node('div', undefined, 'receipt'); card.append(node('span', id), node('strong', count), node('small', `${destination.kind} · ${destination.deployment} · 모의`)); return card;
    });
    if (!Number.isInteger(data.receipts['local-model']) || !Number.isInteger(data.receipts['test-tool'])) throw new Error('필수 목적지 수신 횟수 없음');
    $('receipts').replaceChildren(...cards);
    $('overview-model').textContent = String(data.receipts['local-model']);
    $('overview-tool').textContent = String(data.receipts['test-tool']);
    $('observation').textContent = `수신 관측 시각 ${new Date().toLocaleTimeString('ko-KR')} · 세션 누적값 / native 실측 아님`;
  }
  function renderHistorical() {
    const event = state.bundle && state.bundle.event;
    $('historical').textContent = event ? `선택 기록 정책 v${event.policyVersion} / 현재 v${state.policy.version} · ${event.policyVersion === state.policy.version ? '현재 버전 기록' : '구 정책 기록 (당시 판정 유지)'} · 기록 판정: ${labels[event.decision] || event.decision}` : '선택한 증거 없음';
  }
  async function selectEvidence(id) {
    state.bundle = null; $('overview-audit').textContent = '미검증'; $('audit-context').textContent = '선택한 증거의 검증 대기'; $('evidence').textContent = '선택한 증거 없음'; $('verification').textContent = '아직 검증하지 않았습니다.'; renderHistorical();
    if (!id) return;
    const bundle = await api('/api/evidence/' + encodeURIComponent(id));
    if (!bundle.event) throw new Error('증거 응답 형식 오류');
    state.bundle = bundle; $('evidence').textContent = JSON.stringify(bundle, null, 2); renderHistorical();
    await verify('original');
  }
  async function refreshEvents(preferred) {
    const data = await api('/api/events');
    if (!Array.isArray(data.events)) throw new Error('기록 응답 형식 오류');
    const selected = preferred || $('events').value || (data.events.length ? data.events[data.events.length - 1].eventId : '');
    const lastRead = data.events.slice().reverse().find(event => event.request.operation === 'read');
    $('overview-read').textContent = lastRead ? (labels[lastRead.decision] || '알 수 없음') : '기록 없음';
    const placeholder = node('option', data.events.length ? '기록 선택' : '기록 없음 · 요청을 먼저 실행하세요'); placeholder.value = '';
    $('events').replaceChildren(placeholder, ...data.events.slice().reverse().map(event => {
      const option = node('option', `v${event.policyVersion} · ${labels[event.decision] || event.decision} · ${labels[event.request.operation] || event.request.operation} · ${event.phase === 'intent' ? '의도 (결과 미확정)' : '결과'} · ${event.eventId}`); option.value = event.eventId; return option;
    }));
    $('events').value = data.events.some(event => event.eventId === selected) ? selected : '';
    await selectEvidence($('events').value);
  }
  async function refresh() {
    state.ready = false;
    const health = await api('/api/health');
    $('session').textContent = `발표 세션: ${health.session || '기존 로컬 세션'} · 새 시작은 런처를 다시 실행하세요. 기존 기록은 보존됩니다.`;
    const document = await api('/api/document');
    if (typeof document.content !== 'string' || typeof document.id !== 'string') throw new Error('문서 응답 형식 오류');
    state.document = document; $('document-meta').textContent = `${document.id} · 분류: ${document.classification}`; $('document').textContent = document.content;
    renderPolicy(await api('/api/policy')); await refreshDestinations(); await refreshEvents();
    state.ready = true; $('status').textContent = `연결됨 · ${health.status} · 계약 ${health.contract}`;
  }
  async function execute(operation, destination) {
    const request = {subject: {id: $('subject').value, role: $('role').value}, resourceId: state.document.id, operation, destination};
    if (operation === 'write') request.content = $('write-content').value;
    const result = await api('/api/execute', request);
    if (!['allow', 'deny', 'indeterminate'].includes(result.decision) || !['allow', 'deny'].includes(result.policyDecision) || !Number.isInteger(result.policyVersion) || !Object.hasOwn(deliveryLabels, result.deliveryStatus) || !Object.hasOwn(effectLabels, result.effectStatus) || result.retryAutomatically !== false) throw new Error('판정 응답 형식 오류 · 자동 재전송하지 않습니다');
    const card = node('article', undefined, 'run');
    card.append(badge(result.decision), node('strong', ` ${labels[operation]} · ${destination || '목적지 없음'} · v${result.policyVersion}`), node('p', result.reason), node('p', `정책 권한: ${labels[result.policyDecision]} · 수신 상태: ${deliveryLabels[result.deliveryStatus]} · 집행 상태: ${effectLabels[result.effectStatus]}`), node('small', `결과 기록: ${result.eventId || '없음'} · 의도 기록: ${result.intentEventId || '없음'}`));
    if (result.output !== null && result.output !== undefined) card.append(node('pre', result.output));
    $('runs-empty').hidden = true; $('runs').prepend(card);
    if (result.decision === 'indeterminate') card.append(node('p', '판정 불가 · 차단 또는 미수신을 의미하지 않습니다. 자동 재전송하지 않습니다. 실제 수신 횟수와 의도/결과 기록을 먼저 확인하세요.', 'notice'));
    await refreshDestinations(); await refreshEvents(result.eventId || result.intentEventId);
    $('status').textContent = result.decision === 'indeterminate' ? '판정 불가 · 자동 진행 중단. 실제 수신 횟수와 기록을 확인하세요.' : '요청 완료 · 판정과 실제 수신 횟수를 확인하세요.';
    return result;
  }
  async function verify(mode) {
    $('verification').textContent = '검증 요청 중…'; $('overview-audit').textContent = '검증 중';
    let bundle = mode === 'absent' ? {} : JSON.parse(JSON.stringify(state.bundle));
    if (mode === 'tampered') bundle.event.decision = bundle.event.decision === 'allow' ? 'deny' : 'allow';
    try {
      const result = await api('/api/verify', {bundle});
      if (!['allow', 'deny', 'indeterminate'].includes(result.verdict) || typeof result.valid !== 'boolean' || !result.checks) throw new Error('검증 응답 형식 오류');
      $('overview-audit').textContent = `${result.valid ? '유효' : '유효하지 않음'} · ${labels[result.verdict]}`;
      $('audit-context').textContent = `${{original: '원본', tampered: '변조 사본', absent: '증거 없음'}[mode]}${bundle.event ? ` · v${bundle.event.policyVersion}` : ''} / 집행 성공과 구분`;
      $('status').textContent = '검증 API 응답 수신 · 선택한 증거의 결과입니다.';
      $('verification').replaceChildren(node('p', {original: '원본 증거', tampered: '판정 필드 변조 사본 (원본 보존)', absent: '증거 없는 요청'}[mode]), badge(result.verdict), node('p', `유효성: ${result.valid ? '유효' : '유효하지 않음'} · ${result.reason}`), node('pre', JSON.stringify(result.checks, null, 2)));
    } catch (error) { $('overview-audit').textContent = '검증 오류'; $('audit-context').textContent = '검증 결과 없음'; $('verification').textContent = '검증 API 오류 · 검증 결과 없음'; throw error; }
  }
  $('refresh').addEventListener('click', () => task(refresh));
  $('sequence').addEventListener('click', () => task(async () => { const model = $('model').value; if ((await execute('read', null)).decision !== 'allow') return; if ((await execute('model_send', model)).decision !== 'allow') return; await execute('tool_send', 'test-tool'); }));
  $('read').addEventListener('click', () => task(() => execute('read', null)));
  $('write').addEventListener('click', () => task(() => execute('write', null)));
  $('tool').addEventListener('click', () => task(() => execute('tool_send', 'test-tool')));
  $('events').addEventListener('change', () => task(() => selectEvidence($('events').value)));
  ['original', 'tampered', 'absent'].forEach(mode => $('verify-' + mode).addEventListener('click', () => task(() => verify(mode))));
  $('update-policy').addEventListener('click', () => task(async () => {
    const policy = await api('/api/policy/test-tool', {expectedVersion: state.policy.version, effect: $('effect').value});
    renderPolicy(policy); $('status').textContent = `정책 v${policy.version} 저장됨 · 도구를 재실행해 비교하세요. 과거 증거는 유지됩니다.`;
  }));
  task(refresh);
})();
