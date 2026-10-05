// Renders the shipped memories-app.js and checks the quarantine review paths added in 0.5.257 from the entry point
// a person touches: a prune survives a reload (the card offers Restore, not Accept and Prune again), Restore sends
// Accept on the wire, and To review groups Prune ready memories with one guarded Quarantine all.
'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict'), crypto = require('node:crypto');
const page = fs.readFileSync(path.join(__dirname, '../Resources/memories/memories-app.js'), 'utf8');
const status = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/memories-applied/status-bridge.json'), 'utf8'));
const flush = async (n = 12) => { for (let i = 0; i < n; i++) await new Promise(r => setImmediate(r)); };

function element(id) {
  return { id, innerHTML: '', textContent: '', value: '', style: {}, children: [], listeners: {},
    classList: { _s: new Set(), toggle(c, on) { on === undefined ? (this._s.has(c) ? this._s.delete(c) : this._s.add(c)) : (on ? this._s.add(c) : this._s.delete(c)); }, add(c) { this._s.add(c); }, remove(c) { this._s.delete(c); }, contains(c) { return this._s.has(c); } },
    setAttribute() {}, removeAttribute() {}, focus() {}, setSelectionRange() {}, querySelectorAll() { return []; }, querySelector() { return null; },
    addEventListener(name, fn) { (this.listeners[name] ||= []).push(fn); }, appendChild(c) { this.children.push(c); return c; }, replaceChildren() {}, contains() { return false; } };
}

const ev = (id, type, lesson, ts, extra) => Object.assign({ event_id: id, event_type: type, lesson_id: lesson, ts, store: 'bot_memory', title: 'Memory ' + lesson,
  scope: 'unknown', category: null, source_refs: [{ kind: 'memory', id: lesson, excerpt: 'Memory ' + lesson }] }, extra || {});
const READY = 'Prune ready · never recalled, created 2025-01-01';

function boot(o) {
  const calls = [], els = {};
  const document = { activeElement: null, addEventListener() {}, removeEventListener() {}, createElement: () => element('anon'),
    querySelector(sel) { return els[sel] ||= element(sel); }, querySelectorAll() { return []; }, body: element('body') };
  const context = { crypto, console, setTimeout, clearTimeout, setInterval, clearInterval, document, Intl, Date, Promise, JSON, Math, Number, String, Array, Object, Error, navigator: { language: 'en-US' }, location: { search: '' } };
  context.window = context;
  const all = () => o.recent.concat(o.review);
  context.webkit = { messageHandlers: { cos: { postMessage(msg) {
    calls.push(msg);
    setImmediate(() => {
      let details = null, ok = true, message = '';
      const a = msg.args || {};
      switch (msg.op) {
        case 'status': details = status; break;
        case 'learning.list': details = a.kind ? { state: 'empty', events: [], shown: 0, total: 0, nextCursor: null, coverage: {}, days: a.days }
          : { state: 'ready', events: o.recent, shown: o.recent.length, total: o.recent.length, nextCursor: null, coverage: {} }; break;
        case 'learning.review': details = { state: 'ready', events: o.review, shown: o.review.length, total: o.review.length, reviewCount: o.review.length, coverage: {} }; break;
        case 'learning.event': details = Object.assign({}, all().find(e => e.event_id === a.id) || {}, { detail: {} }); break;
        case 'learning.status': details = { counts_by_type: {}, stores: {}, complete: true }; break;
        case 'memories.list': details = { memories: [], total: 0 }; break;
        case 'graph.status': details = {}; break;
        case 'memory.review':
          if (o.failOn && o.failOn === a.id) { ok = false; message = 'memory_unavailable'; break; }
          details = { decision: { lesson_id: a.id, decision: a.decision === 'prune' ? 'pruned' : 'accepted' } }; break;
        default: ok = false; message = 'Snapshot browsing unavailable in this version.';
      }
      context.window.cosBridge.resolve(msg.id, { ok, message, details });
    });
  } } } };
  vm.runInNewContext(page, context, { filename: 'memories-app.js' });
  const get = sel => (els[sel] || (els[sel] = element(sel)));
  return { app: context.window.cosApp, calls, html: sel => get(sel).innerHTML, text: sel => get(sel).textContent };
}

async function main() {
  // A. A memory pruned earlier (ledger event, any session) shows as quarantined after a reload, with Restore.
  const captured = ev('evt_cap_a', 'captured', 'mem_a', '2026-10-05T20:00:00+00:00');
  const prunedRow = ev('evt_led_a', 'pruned', 'mem_a', '2026-10-05T21:00:00+00:00', { store: 'review_ledger', title: 'pruned: mem_a' });
  let b = boot({ recent: [prunedRow, captured], review: [] }); await flush();
  b.app.select('evt_cap_a'); await flush();
  let detail = b.html('#detail');
  assert.match(detail, /Quarantined from active recall/, 'a reload remembers the prune');
  assert.match(b.html('#inbox'), /class="kind">Quarantined</, 'the list labels the card Quarantined');
  assert.match(detail, /Restore to recall/, 'a quarantined memory offers Restore');
  assert.doesNotMatch(detail, />Accept</, 'no Accept on a memory already out of recall');
  assert.ok(detail.includes("cosApp.reviewMemory(&quot;mem_a&quot;, 'restore')"), 'the Restore button sends restore');

  // B. Restore sends Accept on the wire and lands as accepted.
  b.app.reviewMemory('mem_a', 'restore'); await flush();
  const sent = b.calls.filter(c => c.op === 'memory.review');
  assert.deepEqual(sent.map(c => c.args.decision), ['accept'], 'restore is accept to the helper and the server');
  assert.match(b.html('#detail'), /Accepted/, 'the card shows the memory back in recall');
  assert.equal(b.text('#toast'), 'Memory restored to recall.');

  // C. Newest decision wins: an accepted ledger row after a prune shows Accepted; a stale prune never undoes a
  //    decision made in this session.
  const acceptedLater = ev('evt_led_a2', 'accepted', 'mem_a', '2026-10-05T22:00:00+00:00', { store: 'review_ledger', title: 'accepted: mem_a' });
  b = boot({ recent: [acceptedLater, prunedRow, captured], review: [] }); await flush();
  b.app.select('evt_cap_a'); await flush();
  assert.match(b.html('#detail'), /Accepted/); assert.doesNotMatch(b.html('#detail'), /Restore to recall/);
  const o = { recent: [captured], review: [] };
  b = boot(o); await flush();
  b.app.select('evt_cap_a'); await flush();
  b.app.reviewMemory('mem_a', 'accept'); await flush();
  o.recent = [prunedRow, captured];           // the reload still carries the older prune
  b.app.refresh(); await flush(20);
  b.app.select('evt_cap_a'); await flush();
  assert.match(b.html('#detail'), /Accepted/, 'a session decision outranks an older ledger row');
  assert.doesNotMatch(b.html('#detail'), /Restore to recall/);

  // D. To review: Prune ready rows sit under their own header with the reason and one guarded bulk action.
  const r1 = ev('evt_pr_1', 'captured', 'mem_old_1', '2025-01-01T10:00:00+00:00', { category: READY });
  const r2 = ev('evt_pr_2', 'captured', 'mem_old_2', '2025-02-01T10:00:00+00:00', { category: READY });
  const proposal = ev('evt_prop', 'proposed', 'siq_1', '2026-10-04T10:00:00+00:00', { store: 'self_improvement_queue', title: 'A proposal' });
  b = boot({ recent: [], review: [proposal, r2, r1] }); await flush();
  b.app.setFilter('review'); await flush();
  let inbox = b.html('#inbox');
  assert.match(inbox, /PRUNE READY · 2/);
  assert.ok(inbox.indexOf('A proposal') < inbox.indexOf('PRUNE READY'), 'other review items come first');
  assert.ok(inbox.indexOf('PRUNE READY') < inbox.indexOf('Memory mem_old_2') && inbox.indexOf('PRUNE READY') < inbox.indexOf('Memory mem_old_1'), 'the header leads its rows');
  assert.equal((inbox.match(/class="kind">Prune ready</g) || []).length, 2, 'each row is labelled Prune ready');
  assert.match(inbox, /Quarantine all 2/);
  b.app.select('evt_pr_1'); await flush();
  assert.match(b.html('#detail'), /Prune ready: never recalled, created 2025-01-01\./, 'the card says why');
  assert.match(b.html('#detail'), />Accept</); assert.match(b.html('#detail'), />Prune</);

  // E. Quarantine all arms first, skips a memory already decided, then prunes each remaining one once, in order.
  b.app.reviewMemory('mem_old_1', 'accept'); await flush();
  assert.match(b.html('#inbox'), /Quarantine all 1/, 'a decided row leaves the bulk count');
  assert.match(b.html('#inbox'), /PRUNE READY · 1</, 'the header counts what is still undecided');
  b.app.reviewMemory('mem_old_1', 'restore'); await flush();   // still decided (accepted); stays out of the bulk run
  b.app.pruneAllReady(); await flush();
  assert.equal(b.calls.filter(c => c.op === 'memory.review' && c.args.decision === 'prune').length, 0, 'the first click only arms');
  assert.match(b.html('#inbox'), /Click again to quarantine 1/);
  b.app.pruneAllReady(); await flush(30);
  const prunes = b.calls.filter(c => c.op === 'memory.review' && c.args.decision === 'prune');
  assert.deepEqual(prunes.map(c => c.args.id), ['mem_old_2'], 'only the undecided memory is pruned');
  inbox = b.html('#inbox');
  assert.doesNotMatch(inbox, /Quarantine all/, 'nothing left to quarantine');
  assert.match(inbox, /PRUNE READY · ALL DECIDED/);
  assert.equal((inbox.match(/class="kind">Prune ready</g) || []).length, 0, 'decided rows lose the label');
  b.app.select('evt_pr_2'); await flush();
  assert.match(b.html('#detail'), /Restore to recall/, 'each one can come back');

  // F. The first failure stops the run and leaves the rest open.
  b = boot({ recent: [], review: [r2, r1], failOn: 'mem_old_2' }); await flush();
  b.app.setFilter('review'); await flush();
  b.app.pruneAllReady(); b.app.pruneAllReady(); await flush(30);
  assert.deepEqual(b.calls.filter(c => c.op === 'memory.review').map(c => c.args.id), ['mem_old_2'], 'stops at the first failure');
  assert.match(b.html('#inbox'), /Quarantine all 2/, 'nothing was decided, so both stay open');

  console.log('MemoriesQuarantineCanary: 6 scenarios ok');
}
main().catch(e => { console.error(e); process.exit(1); });
