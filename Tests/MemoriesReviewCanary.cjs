// 0.5.379: the Memories page's To review, from the entry point a person touches, against the one review predicate
// (Resources/memories/memory-review.js, a copy of COS Control Web's server/web-control/memory-review.js; MU's
// learning_events.py review_state is the producer's copy). A suggested rule under its bar is Learning: listed calmly with
// its confidence, never counted, never "Needs your review". At or over the bar it needs review. A suggestion dismissed here
// leaves To review, and its reader stays on it so Restore is one tap away. COS_MEMORIES_PAGE runs another page (red proof).
'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict'), crypto = require('node:crypto');
const page = fs.readFileSync(process.env.COS_MEMORIES_PAGE || path.join(__dirname, '../Resources/memories/memories-app.js'), 'utf8');
const review = fs.readFileSync(path.join(__dirname, '../Resources/memories/memory-review.js'), 'utf8');
const status = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/memories-applied/status-bridge.json'), 'utf8'));
const flush = async (n = 12) => { for (let i = 0; i < n; i++) await new Promise(r => setImmediate(r)); };

function element(id) {
  return { id, innerHTML: '', textContent: '', value: '', style: {}, children: [], listeners: {},
    classList: { _s: new Set(), toggle(c, on) { on === undefined ? (this._s.has(c) ? this._s.delete(c) : this._s.add(c)) : (on ? this._s.add(c) : this._s.delete(c)); }, add(c) { this._s.add(c); }, remove(c) { this._s.delete(c); }, contains(c) { return this._s.has(c); } },
    setAttribute() {}, removeAttribute() {}, focus() {}, setSelectionRange() {}, querySelectorAll() { return []; }, querySelector() { return null; },
    addEventListener(name, fn) { (this.listeners[name] ||= []).push(fn); }, appendChild(c) { this.children.push(c); return c; }, replaceChildren() {}, contains() { return false; } };
}
const pattern = (id, lesson, title) => ({ event_id: id, event_type: 'promotable', lesson_id: lesson, ts: '2026-11-07T15:00:00+00:00', store: 'correction_journal',
  title, scope: 'unknown', engine: 'unknown', category: null, target: { kind: 'pattern', id: lesson }, source_refs: [] });
const proposal = (id, lesson, title) => ({ event_id: id, event_type: 'proposed', lesson_id: lesson, ts: '2026-11-07T16:00:00+00:00', store: 'self_improvement_queue',
  title, scope: 'unknown', engine: 'unknown', category: null, target: { kind: 'task-proposal', id: lesson }, source_refs: [] });

function boot(o) {
  const calls = [], els = {};
  const document = { activeElement: null, addEventListener() {}, removeEventListener() {}, createElement: () => element('anon'),
    querySelector(sel) { return els[sel] ||= element(sel); }, querySelectorAll() { return []; }, body: element('body') };
  const context = { crypto, console, setTimeout, clearTimeout, setInterval, clearInterval, document, Intl, Date, Promise, JSON, Math, Number, String, Array, Object, Error, navigator: { language: 'en-US' }, location: { search: '' } };
  context.window = context;
  context.webkit = { messageHandlers: { cos: { postMessage(msg) {
    calls.push(msg);
    setImmediate(() => {
      let details = null, ok = true, message = '';
      const a = msg.args || {};
      switch (msg.op) {
        case 'status': details = Object.assign({}, status, { needs_you: o.needs }); break;
        case 'learning.list': details = { state: 'ready', events: o.recent, shown: o.recent.length, total: o.recent.length, nextCursor: null, coverage: {} }; break;
        case 'learning.review': details = { state: 'ready', events: o.review, shown: o.review.length, total: o.review.length, reviewCount: o.review.length, coverage: {} }; break;
        case 'learning.event': details = Object.assign({}, o.review.concat(o.recent).find(e => e.event_id === a.id) || {}, { detail: {} }); break;
        case 'learning.status': details = { counts_by_type: {}, stores: {}, complete: true }; break;
        case 'learning.decide': details = { ok: true }; break;
        case 'memories.list': details = { memories: [], total: 0 }; break;
        case 'graph.status': details = {}; break;
        default: ok = false; message = 'Snapshot browsing unavailable in this version.';
      }
      context.window.cosBridge.resolve(msg.id, { ok, message, details });
    });
  } } } };
  vm.runInNewContext(review, context, { filename: 'memory-review.js' });
  vm.runInNewContext(page, context, { filename: 'memories-app.js' });
  const get = sel => (els[sel] || (els[sel] = element(sel)));
  return { app: context.window.cosApp, calls, html: sel => get(sel).innerHTML };
}

async function main() {
  // An older producer (low_confidence in items, no learning list) and the 2026-11-08 producer (rule_ready at the bar plus a
  // learning list) must read the same way: one below-bar suggestion is Learning, the at-bar one needs review.
  const below = pattern('evt_low', 'pat_low', 'Use the brand voice in Slack drafts');
  const ready = pattern('evt_ready', 'pat_ready', 'Never pin Quilt people into the Lean Labs portal');
  const prop = proposal('evt_prop', 'prop_1', 'Tighten the reflect grade rubric');
  const older = { count: 2, limit: 7, items: [
    { lesson_id: 'pat_low', event_id: 'evt_low', gate: 'low_confidence', confidence: 0.62, reason: 'promotable at confidence 0.62 (< 0.8)', title: below.title, ts: below.ts },
    { lesson_id: 'pat_ready', event_id: 'evt_ready', gate: 'rule_ready', confidence: 0.86, bar: 0.8, reason: 'promotable at confidence 0.86 (>= 0.8)', title: ready.title, ts: ready.ts } ] };
  const newer = { count: 1, limit: 7, bar: 0.8, items: [older.items[1]],
    learning: [Object.assign({}, older.items[0], { gate: 'rule_ready', bar: 0.8, state: 'learning' })], learning_count: 1 };
  for (const [name, needs] of [['older producer', older], ['2026-11-08 producer', newer]]) {
    const b = boot({ needs, recent: [], review: [ready, below, prop] }); await flush();
    b.app.setFilter('review'); await flush();
    const inbox = b.html('#inbox'), nav = b.html('#memoryNav');
    assert.match(nav, /To review \(1\)/, name + ': To review counts only what needs review');
    assert.match(inbox, /LEARNING · 1 SUGGESTION</, name + ': a calm Learning group');
    assert.match(inbox, /Learning\. Confidence 0\.62, under the 0\.8 bar for a rule/, name + ': the learning row says its confidence and the bar');
    const lowRow = inbox.slice(inbox.indexOf("'evt_low'"));
    assert.doesNotMatch(lowRow.slice(0, lowRow.indexOf('</button>')), /Needs your review/, name + ': a below-bar suggestion never reads Needs your review');
    const readyRow = inbox.slice(inbox.indexOf("'evt_ready'"));
    assert.match(readyRow.slice(0, readyRow.indexOf('</button>')), /Needs your review/, name + ': at the bar it needs review');
    assert.ok(inbox.indexOf("'evt_ready'") < inbox.indexOf('LEARNING'), name + ': Learning comes after what needs review');
    assert.equal(inbox.split("'evt_low'").length - 1, 1, name + ': a learning suggestion is listed once');
    assert.ok(inbox.indexOf("'evt_low'") > inbox.indexOf('LEARNING'), name + ': and only under Learning');
    assert.match(b.html('#summary'), /<strong>1 change<\/strong> to review/, name + ': the summary counts the same one');
    b.app.select('evt_low'); await flush();
    assert.match(b.html('#detail'), /Learning: Confidence 0\.62, under the 0\.8 bar for a rule\. It moves to To review on its own/, name + ': the reader explains Learning');
  }

  // Dismissed here: the suggestion leaves To review and the count, the reader stays on it with Restore.
  const b = boot({ needs: newer, recent: [], review: [ready, below, prop] }); await flush();
  b.app.setFilter('review'); await flush();
  b.app.select('evt_ready'); await flush();
  b.app.decide('evt_ready', 'dismissed'); await flush();
  assert.deepEqual(b.calls.filter(c => c.op === 'learning.decide').map(c => c.args.decision), ['dismissed']);
  assert.doesNotMatch(b.html('#inbox'), /'evt_ready'/, 'a dismissed suggestion leaves To review');
  assert.doesNotMatch(b.html('#memoryNav'), /To review \(/, 'and leaves the count');
  assert.match(b.html('#detail'), /Restore proposal/, 'its reader stays on it, Restore one tap away');
  console.log('PASS: Memories To review: one predicate (older and new producers), Learning group, counts, dismissed leaves with Restore');
}
main().catch(e => { console.error(e && e.stack || e); process.exit(1); });
