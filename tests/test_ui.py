"""UI contract checks; optional installed Node exercises the unmodified browser entrypoint.

No packages, servers, network, or shared runtime directories are used. Production
remains Python stdlib plus browser JavaScript. Node is only an optional test engine.
"""
from pathlib import Path
import re
import shutil
import subprocess
import unittest
from html.parser import HTMLParser

ROOT = Path(__file__).resolve().parents[1]


class Markup(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids = []
        self.assets = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'id' in attrs:
            self.ids.append(attrs['id'])
        if tag in ('link', 'script'):
            self.assets.append(attrs.get('href', attrs.get('src')))


class UIAssets(unittest.TestCase):
    def test_local_assets_and_unique_dom_bindings(self):
        markup = Markup()
        markup.feed((ROOT / 'web/index.html').read_text())
        self.assertEqual(len(markup.ids), len(set(markup.ids)))
        script = (ROOT / 'web/app.js').read_text()
        self.assertTrue(set(re.findall(r"\$\('([^']+)'\)", script)) <= set(markup.ids))
        self.assertEqual(set(markup.assets), {'/styles.css', '/app.js'})
        self.assertNotIn('innerHTML', script)
        for name in ('index.html', 'app.js', 'styles.css'):
            self.assertNotRegex((ROOT / 'web' / name).read_text(), r'https?://|@import')

    def test_disclosures_and_distinct_operations(self):
        html = (ROOT / 'web/index.html').read_text()
        for text in ('합성', 'file-mock-anchor', 'HMAC-SHA256', '판정 불가', '구 정책', '실제 체인'):
            self.assertIn(text, html + (ROOT / 'web/app.js').read_text())
        script = (ROOT / 'web/app.js').read_text()
        for operation in ('read', 'write', 'model_send', 'tool_send'):
            self.assertIn("execute('" + operation + "'", script)

    @unittest.skipUnless(shutil.which('node'), 'Optional installed Node unavailable')
    def test_browser_entrypoint_workflow_and_failures(self):
        result = subprocess.run(
            [shutil.which('node'), '-e', HARNESS, str(ROOT)],
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('UI entrypoint: all scenarios passed', result.stdout)


HARNESS = r"""
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const root = process.argv[1];
const source = fs.readFileSync(root + '/web/app.js', 'utf8');
const initial = JSON.parse(fs.readFileSync(root + '/fixtures/policy.json', 'utf8'));
const resource = JSON.parse(fs.readFileSync(root + '/fixtures/document.json', 'utf8'));
const clone = x => JSON.parse(JSON.stringify(x));
class Element {
  constructor(tag='div') { this.tag=tag; this.children=[]; this.textContent=''; this.value=''; this.listeners={}; this.disabled=false; this.hidden=false; }
  set textContent(value) { this._text=String(value); this.children=[]; }
  get textContent() { return this._text; }
  append(...nodes) { this.children.push(...nodes); }
  prepend(...nodes) { this.children.unshift(...nodes); }
  replaceChildren(...nodes) { this.textContent=''; this.children=nodes; if(this.tag==='select') this.value=nodes[0]?.value || ''; }
  setAttribute(name, value) { this[name]=value; }
  addEventListener(name, fn) { this.listeners[name]=fn; }
}
function setup(mode='normal') {
  const elements={};
  const html=fs.readFileSync(root+'/web/index.html','utf8');
  for(const match of html.matchAll(/<(\w+)[^>]*\bid="([^"]+)"/g)) elements[match[2]]=new Element(match[1]);
  elements.subject.value='demo-analyst'; elements.model.value='local-model'; elements['write-content'].value='[합성] 수정';
  let policy=clone(initial), events=[], bundles={}, receipts={'local-model':0,'cloud-model':0,'test-tool':0}, calls=[];
  let failNext=null;
  const response = (data, status=200) => ({ok:status<400,status,json:async()=>clone(data)});
  const fetch = async(path, options) => {
    assert(path.startsWith('/api/')); calls.push({path,options});
    if(mode==='pending') return new Promise(()=>{});
    if(mode==='baseline' && path!=='/api/health') return response({error:'not_implemented'},501);
    if(failNext === path) { failNext=null; return response({error:'forced_error'},409); }
    const body=options.body ? JSON.parse(options.body) : null;
    if(path==='/api/health') return response({status:mode,contract:'v1'});
    if(path==='/api/document') return response(resource);
    if(path==='/api/policy') return response(policy);
    if(path==='/api/destinations') return response({destinations:{'local-model':{kind:'model',deployment:'local'},'cloud-model':{kind:'model',deployment:'cloud-simulated'},'test-tool':{kind:'tool',deployment:'local'}},receipts});
    if(path==='/api/events') return response({events});
    if(path.startsWith('/api/evidence/')) return response(bundles[decodeURIComponent(path.split('/').pop())]);
    if(path==='/api/policy/test-tool') {
      assert.deepEqual(Object.keys(body).sort(), ['effect','expectedVersion']); assert.equal(body.expectedVersion,policy.version);
      policy=clone(policy); policy.version++; policy.rules.find(r=>r.id==='test-tool-rule').effect=body.effect; return response(policy);
    }
    if(path==='/api/execute') {
      assert.equal(body.resourceId,resource.id); assert.equal(body.subject.role,'analyst');
      assert(!('classification' in body)); assert(!('url' in body));
      const rule=policy.rules.find(r=>r.operation===body.operation && r.destination===body.destination);
      const permission=rule?.effect || 'deny';
      const uncertain=mode==='uncertain' && body.operation==='model_send';
      const decision=uncertain ? 'indeterminate' : permission;
      if(decision==='allow' && body.destination) receipts[body.destination]++;
      const event={eventId:'event-'+(events.length+1),policyVersion:policy.version,decision,request:body};
      events.push(event); bundles[event.eventId]={event:clone(event),policy:clone(policy),signature:'synthetic-signature',proof:{leafIndex:0,treeSize:1,siblings:[]},checkpoint:{id:'mock',root:'mock-root',treeSize:1,kind:'file-mock-anchor'}};
      return response({decision,policyDecision:permission,deliveryStatus:body.destination ? (uncertain ? 'unknown' : decision==='allow' ? 'received' : 'not_sent') : 'not_applicable',effectStatus:uncertain ? 'unknown' : decision==='allow' ? 'completed' : 'not_started',intentEventId:uncertain ? event.eventId : null,retryAutomatically:false,reason:'synthetic fixture decision',policyVersion:policy.version,eventId:uncertain ? null : event.eventId,output:decision==='allow' ? '[합성] 결과' : null});
    }
    if(path==='/api/verify') {
      const b=body.bundle, original=b.event && bundles[b.event.eventId];
      const valid=Boolean(original && JSON.stringify(original)===JSON.stringify(b));
      return response({verdict:valid ? b.event.decision : 'indeterminate',valid,checks:{signature:valid,checkpoint:valid},reason:'synthetic verifier fixture'});
    }
    throw new Error('Unexpected path '+path);
  };
  vm.runInNewContext(source,{document:{getElementById:id=>{assert(elements[id],id); return elements[id];},createElement:tag=>new Element(tag)},fetch});
  return {elements,calls,receipts,bundles,events, fail:path=>{failNext=path;}};
}
const settle=async()=>{await new Promise(resolve=>setImmediate(resolve));};
const click=async(s,id)=>{assert(!s.elements[id].disabled,'disabled '+id); s.elements[id].listeners.click(); await settle();};
const text=e=>e.textContent+' '+e.children.map(text).join(' ');
(async()=>{
  const pending=setup('pending');
  assert(pending.elements.sequence.disabled);
  assert.equal(pending.elements.main['aria-busy'],'true');
  assert.match(pending.elements.status.textContent,/처리 중/);
  const baseline=setup('baseline'); await settle();
  assert.equal(baseline.elements.error.hidden,false); assert.match(baseline.elements.error.textContent,/501/); assert(baseline.elements.sequence.disabled); assert.equal(baseline.elements.runs.children.length,0);
  const uncertain=setup('uncertain'); await settle(); await click(uncertain,'sequence');
  assert.deepEqual(uncertain.events.map(e=>e.request.operation),['read','model_send']);
  assert.equal(uncertain.calls.filter(c=>c.path==='/api/execute').length,2);
  assert.match(text(uncertain.elements.runs),/판정 불가/);
  assert.match(text(uncertain.elements.runs),/정책 권한: 허용/);
  assert.match(text(uncertain.elements.runs),/수신 여부 확인 불가/);
  assert.match(text(uncertain.elements.runs),/자동 재전송하지 않습니다/);
  assert.equal(uncertain.elements.error.hidden,true);
  const s=setup(); await settle(); assert(!s.elements.sequence.disabled);
  assert.equal(s.elements['overview-tool'].textContent,'0');
  assert.equal(s.elements['overview-read'].textContent,'기록 없음');
  await click(s,'sequence');
  assert.deepEqual(s.events.map(e=>e.request.operation),['read','model_send','tool_send']);
  assert.deepEqual(s.events.map(e=>e.decision),['allow','allow','deny']);
  assert.equal(s.receipts['local-model'],1); assert.equal(s.receipts['test-tool'],0);
  assert.match(text(s.elements.receipts),/test-tool\s+0/);
  assert.equal(s.elements['overview-model'].textContent,'1');
  assert.equal(s.elements['overview-tool'].textContent,'0');
  assert.equal(s.elements['overview-read'].textContent,'허용');
  assert.match(s.elements['overview-audit'].textContent,/유효 · 차단/);
  const old=JSON.stringify(s.bundles['event-3']);
  s.elements.effect.value='allow'; await click(s,'update-policy');
  assert.equal(s.elements['overview-policy'].textContent,'v2');
  assert.match(s.elements.historical.textContent,/구 정책/); assert.equal(s.elements.events.value,'event-3');
  await click(s,'verify-original'); assert.match(text(s.elements.verification),/차단/);
  await click(s,'tool'); assert.equal(s.receipts['test-tool'],1); assert.equal(s.events.at(-1).policyVersion,2);
  assert.equal(JSON.stringify(s.bundles['event-3']),old);
  await click(s,'verify-tampered'); assert.match(text(s.elements.verification),/판정 불가/);
  await click(s,'verify-original'); assert.match(text(s.elements.verification),/허용/);
  await click(s,'verify-absent'); assert.match(text(s.elements.verification),/판정 불가/);
  await click(s,'write'); assert.equal(s.events.at(-1).decision,'deny'); assert.equal(s.events.at(-1).request.destination,null);
  assert.equal(s.events.at(-1).request.content,'[합성] 수정');
  s.fail('/api/policy/test-tool'); await click(s,'update-policy'); assert.match(s.elements.error.textContent,/409/); assert.match(s.elements['policy-version'].textContent,/v2/);
  s.fail('/api/verify'); await click(s,'verify-original'); assert.match(text(s.elements.verification),/API 오류/); assert(!text(s.elements.verification).includes('유효성: 유효'));
  s.elements.model.value='cloud-model'; await click(s,'sequence'); assert.equal(s.receipts['cloud-model'],1);
  const previous=s.events.length; s.fail('/api/execute'); await click(s,'sequence'); assert.equal(s.events.length,previous); assert.match(s.elements.error.textContent,/409/);
  // Untrusted response strings must remain text, never become DOM markup.
  assert.match(s.elements.observation.textContent,/마지막 성공 응답/);
  assert(!source.includes('innerHTML'));
  console.log('UI entrypoint: all scenarios passed');
})().catch(error=>{console.error(error); process.exitCode=1;});
"""

if __name__ == '__main__':
    unittest.main()
