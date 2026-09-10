// Renders the shipped memories-app.js against real helper payloads (captured 2026-09-09)
// and checks the reward chrome from the entry point a person touches: the Applied
// filter, its card, the empty copy per memory path and per status state, the activity
// log, and the nav. Live mode: COS_CONTROL_HELPER=<path> replays the same scenarios
// on this Mac's helper answers. Scenarios B..K were added after the 0.5.216 QA round.
'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict'), crypto = require('node:crypto'), cp = require('node:child_process');
const root = path.join(__dirname, '../Resources/memories');
const page = fs.readFileSync(path.join(root, 'memories-app.js'), 'utf8');
const fx = name => JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures/memories-applied', name + '.json'), 'utf8'));
const helper = process.env.COS_CONTROL_HELPER;
function live(args) { const out = cp.execFileSync(helper, args, { encoding: 'utf8', timeout: 90000 }); const j = JSON.parse(out.slice(out.indexOf('{'))); assert.equal(j.ok, true, 'helper ' + args.join(' ')); return j.details; }
const payloads = helper ? {
  status: live(['status']), used: live(['context-learning', '--kind', 'used', '--days', '7', '--limit', '50']),
  used90: live(['context-learning', '--kind', 'used', '--days', '90', '--limit', '50']),
  lstatus: live(['context-learning-status']), graph: live(['context-graph-status']),
} : { status: fx('status-bridge'), used: fx('learning-used-7d'), used90: fx('learning-used-90d'), lstatus: fx('learning-status'), graph: fx('graph-status') };
const lessonId = (payloads.used.events[0] || {}).lesson_id || 'mem_20260616_203905_258554';
const memoryDetail = helper ? (id => live(['context-memories', '--id', id || lessonId])) : (() => fx('memory-detail'));
const rewardLive = payloads.status.learningRewardEnabled === true;
const flush = async (n = 8) => { for (let i = 0; i < n; i++) await new Promise(r => setImmediate(r)); };

function element(id) {
  return { id, innerHTML: '', textContent: '', value: '', style: {}, children: [], listeners: {},
    classList: { _s: new Set(), toggle(c, on) { on === undefined ? (this._s.has(c) ? this._s.delete(c) : this._s.add(c)) : (on ? this._s.add(c) : this._s.delete(c)); }, add(c) { this._s.add(c); }, remove(c) { this._s.delete(c); }, contains(c) { return this._s.has(c); } },
    setAttribute() {}, removeAttribute() {}, focus() {}, setSelectionRange() {}, querySelectorAll() { return []; }, querySelector() { return null; },
    addEventListener(name, fn) { (this.listeners[name] ||= []).push(fn); }, appendChild(c) { this.children.push(c); return c; }, replaceChildren() {}, contains() { return false; } };
}
// overrides: status (merge or null), statusFails, statusDelay (resolve status after N ticks), noUsed, coverage,
// graph, usedTitle, listFails, unfiltered, memoryFails
function boot(overrides) {
  const status = overrides.status === null ? null : Object.assign({}, payloads.status, overrides.status || {});
  const calls = []; const els = {};
  const document = { activeElement: null, addEventListener() {}, removeEventListener() {}, createElement: () => element('anon'),
    querySelector(sel) { return els[sel] ||= element(sel); }, querySelectorAll() { return []; }, body: element('body') };
  const context = { crypto, console, setTimeout, clearTimeout, setInterval, clearInterval, document, Intl, Date, Promise, JSON, Math, Number, String, Array, Object, Error, navigator: { language: 'en-US' }, location: { search: '' } };
  context.window = context;
  context.webkit = { messageHandlers: { cos: { postMessage(msg) {
    calls.push(msg);
    const deliver = () => {
      let details = null, ok = true, message = '';
      const a = msg.args || {};
      switch (msg.op) {
        case 'status': if (overrides.statusFails) { ok = false; message = 'The helper timed out.'; } else details = status; break;
        case 'learning.list':
          if (a.kind === 'used') {
            if (overrides.listFails) { ok = false; message = 'unrecognized arguments: --kind'; break; }
            if (overrides.unfiltered) { details = { state: 'ready', events: [Object.assign({}, payloads.used.events[0], { event_type: 'captured', event_id: 'evt_cap' })], shown: 1, total: 200, nextCursor: null, coverage: {}, days: a.days }; break; }
            const base = a.days === 90 ? payloads.used90 : payloads.used;
            if (overrides.noUsed) { details = { state: 'empty', events: [], shown: 0, total: 0, nextCursor: null, coverage: overrides.coverage || {}, days: a.days }; break; }
            const events = base.events.map(e => overrides.usedTitle && e.event_id === base.events[0].event_id ? Object.assign({}, e, { title: overrides.usedTitle }) : e);
            details = Object.assign({}, base, { events, coverage: overrides.coverage || base.coverage });
          } else details = { state: 'empty', events: [], shown: 0, total: 0, nextCursor: null, coverage: {}, days: a.days };
          break;
        case 'learning.review': details = { state: 'empty', events: [], shown: 0, total: 0, reviewCount: 5, coverage: {} }; break;
        case 'learning.status': details = payloads.lstatus; break;
        case 'memories.list': details = { memories: [], total: 0 }; break;
        case 'memory.detail': if (overrides.memoryFails) { ok = false; message = 'memory_not_found'; } else details = memoryDetail(a.id); break;
        case 'graph.status': details = Object.assign({}, payloads.graph, overrides.graph || {}); break;
        case 'graph.search': details = { items: [] }; break;
        case 'workspace.request':
          if (overrides.workspaceLearning && a.action === 'learning_page') { details = { protocol: 1, items: [], matched_total: 0, next_cursor: null, coverage: { used: { state: 'legacy', count: 1 } }, stores: { used: { state: 'legacy', count: 1, readable: false }, memory_trace: { state: 'legacy', count: 220, readable: false }, bot_memory: { state: 'ok', count: 12, readable: true } }, counts_by_type: { used: 1 }, complete: true, generated_at: '2026-09-10T00:00:00Z', window_start: '2026-06-12T00:00:00Z', window_end: '2026-09-10T00:00:00Z' }; break; }
          ok = false; message = 'Snapshot browsing unavailable in this version.'; break;
        default: ok = false; message = 'This page cannot ask for ' + msg.op;
      }
      context.window.cosBridge.resolve(msg.id, { ok, message, details });
    };
    if (msg.op === 'status' && overrides.statusDelay) { let n = overrides.statusDelay; const tick = () => (--n > 0 ? setImmediate(tick) : deliver()); setImmediate(tick); }
    else if (msg.op === 'status' && overrides.statusNever) { /* never answers */ }
    else setImmediate(deliver);
  } } } };
  vm.runInNewContext(page, context, { filename: 'memories-app.js' });
  return { context, calls, el: sel => els[sel] || (els[sel] = element(sel)) };
}
const html = (b, sel) => b.el(sel).innerHTML;
const open = async (b) => { b.context.window.cosApp.setFilter('applied'); await flush(10); };
const noLeak = (s, label) => { for (const leak of ['+0.03', '+0.05', '0.05', '0.03', 'reward_term', 'moved later recall']) assert.ok(!s.includes(leak), label + ': leak ' + leak); };

async function main() {
  // A. bridge path, reward on, one used row.
  let b = boot({}); await flush();
  assert.match(html(b, '#memoryNav'), /Applied this week/); assert.doesNotMatch(html(b, '#memoryNav'), /Applied this week \(/, 'Applied is never a count');
  assert.match(html(b, '#memoryNav'), /To review \(5\)/, 'the chip number stays Needs you');
  const usedCall = b.calls.find(c => c.op === 'learning.list' && c.args.kind === 'used');
  assert.ok(usedCall && usedCall.args.days === 7, 'Applied asks the helper for kind used over 7 days');
  await open(b);
  let inbox = html(b, '#inbox'), detail = html(b, '#detail');
  assert.match(inbox, /APPLIED · THIS WEEK/); assert.match(inbox, /class="kind">Application recorded</);
  assert.match(inbox, /Show 90 days/, 'the window switch sits in the header');
  const lesson = memoryDetail(lessonId).content.slice(0, 20);
  assert.ok(inbox.includes(lesson), 'the row shows the lesson text, not the projector title');
  assert.match(inbox, /From past sessions/, 'the row shows the assistant excerpt'); assert.match(inbox, /status green excerpt/, 'excerpt is clamped');
  assert.match(detail, /A later answer used it/);
  assert.match(detail, /Recorded 1 time since first use/, 'the count comes from the projector title');
  if (!helper || rewardLive) assert.match(detail, /This lesson now ranks ahead of unused memories like it in later recall\./, 'reward on: the sentence shows');
  else { assert.doesNotMatch(detail, /ranks ahead/, 'installed helper carries no flag: no claim'); console.log('  note: live helper reports no reward flag; ranking sentence correctly absent'); }
  noLeak(inbox + detail, 'A');
  b.context.window.cosApp.openLog(); await flush();
  assert.match(html(b, '#modalRoot'), /Applied this week/); assert.ok(html(b, '#modalRoot').includes(lesson), 'the activity log names the lesson');
  b.context.window.cosApp.appliedDays(90); await flush(10);
  assert.ok(b.calls.some(c => c.op === 'learning.list' && c.args.kind === 'used' && c.args.days === 90), 'the 90-day switch asks the helper');
  assert.match(html(b, '#inbox'), /90 DAYS/);
  if (!helper) assert.equal((html(b, '#inbox').match(/class="kind">Application recorded</g) || []).length, 2, 'the 90-day window lists the older use too');

  // B. reward flag absent or off: the used block stays, the sentence does not.
  for (const flag of [null, false]) { b = boot({ status: { learningRewardEnabled: flag } }); await flush(); await open(b); assert.match(html(b, '#detail'), /A later answer used it/); assert.doesNotMatch(html(b, '#detail'), /ranks ahead/, 'flag ' + flag + ': no claim'); }

  // C. bridge path, trace present, nothing used this week.
  b = boot({ noUsed: true, coverage: { used: { state: 'legacy', count: 0 } } }); await flush(); await open(b);
  assert.match(html(b, '#detail'), /No later answer has used a lesson this week\./); assert.match(html(b, '#detail'), /Retrieval without acknowledgment is not use\./);

  // D. fresh install on the bridge: no trace ever written. Not a zero.
  b = boot({ noUsed: true, coverage: { used: { state: 'uninstrumented', count: 0 } } }); await flush(); await open(b);
  assert.match(html(b, '#detail'), /Use has not been recorded on this Mac yet\./); assert.doesNotMatch(html(b, '#detail'), /No later answer has used/);
  b = boot({ noUsed: true, coverage: {} }); await flush(); await open(b);
  assert.match(html(b, '#detail'), /Use has not been recorded on this Mac yet\./, 'missing coverage is not a zero either');

  // E. files path and Knowledge-only path.
  b = boot({ noUsed: true, status: { contextScriptsDirectory: null, contextState: 'files' }, graph: { entities: null, engine: null } }); await flush(); await open(b);
  assert.match(html(b, '#detail'), /This memory path cannot detect use\./);
  b = boot({ noUsed: true, status: { contextScriptsDirectory: null, contextState: 'files' }, graph: { entities: 40359, engine: 'lightrag' } }); await flush(); await open(b);
  assert.match(html(b, '#detail'), /Knowledge citations are not lesson reward\./);

  // F. unreadable trace on the bridge.
  b = boot({ noUsed: true, coverage: { used: { state: 'unavailable', count: 0 } } }); await flush(); await open(b);
  assert.match(html(b, '#detail'), /could not be read on this Mac/);

  // G. status never answers (a helper blocked in a permission prompt): no path verdict, no tier claim, no ranking claim.
  b = boot({ statusNever: true, noUsed: true }); await flush(); await open(b);
  assert.match(html(b, '#detail'), /Checking this install.{0,6}s memory path/); assert.doesNotMatch(html(b, '#detail'), /Turn on the COS Data bridge|cannot detect use/);
  assert.equal(b.el('#storage').textContent, 'Stored on this Mac', 'no tier asserted before status lands');
  b = boot({ statusNever: true }); await flush(); await open(b);
  assert.doesNotMatch(html(b, '#detail'), /ranks ahead/, 'no flag, no claim');
  // H. status fails outright.
  b = boot({ statusFails: true, noUsed: true }); await flush(); await open(b);
  assert.match(html(b, '#detail'), /Could not read this Mac.{0,6}s status\./); assert.match(html(b, '#detail'), /timed out/);
  // I. Applied rows land before status: still no verdict until status answers, then the real one.
  b = boot({ statusDelay: 30, noUsed: true, coverage: { used: { state: 'legacy', count: 0 } } }); await flush(4); await open(b);
  assert.match(html(b, '#detail'), /Checking this install.{0,6}s memory path/, 'rows before status: no verdict yet');
  await flush(40); b.context.window.cosApp.setFilter('applied'); await flush(4);
  assert.match(html(b, '#detail'), /No later answer has used a lesson this week\./, 'after status: the bridge verdict');

  // J. honest counts and a lesson record that fails to load.
  b = boot({ usedTitle: 'Applied 4 times · deterministic_check' }); await flush(); await open(b);
  assert.match(html(b, '#detail'), /Recorded 4 times since first use/); assert.doesNotMatch(html(b, '#detail'), /Recorded 1 time/);
  b = boot({ usedTitle: 'Application evidence' }); await flush(); await open(b);
  assert.doesNotMatch(html(b, '#detail'), /Recorded \d+ time/, 'no count in the title: no number invented');
  b = boot({ memoryFails: true }); await flush(); await open(b);
  assert.match(html(b, '#detail'), /could not be read \(memory_not_found\)/); assert.doesNotMatch(html(b, '#detail'), /Loading the record/);
  assert.doesNotMatch(html(b, '#detail'), /<h2[^>]*>[^<]*mem_/, 'the raw id never becomes the heading');
  assert.equal((html(b, '#detail').match(new RegExp(lessonId, 'g')) || []).length, 3, 'the raw id appears in the meta and the two Open source record buttons only');

  // K. the list fails, or the server ignored kind: fail closed, say so in the list column.
  b = boot({ listFails: true }); await flush(); await open(b);
  assert.match(html(b, '#inbox'), /Not available/); assert.match(html(b, '#inbox'), /unrecognized arguments/); assert.match(html(b, '#detail'), /Applied is not available right now\./);
  b = boot({ unfiltered: true }); await flush(); await open(b);
  assert.match(html(b, '#detail'), /unfiltered learning rows/); assert.doesNotMatch(html(b, '#inbox'), /· 200/, 'an unfiltered total never wears the Applied header');
  // L. the activity log reads the legacy sink as readable, next to the lessons it names.
  b = boot({ workspaceLearning: true }); await flush(); await open(b); b.context.window.cosApp.openLog(); await flush();
  assert.match(html(b, '#modalRoot'), /readable \(legacy sink\) · 220/, 'the legacy trace store reads as readable');
  assert.doesNotMatch(html(b, '#modalRoot'), /not readable \(legacy\)/, 'no store is declared unreadable while its rows are listed');
  console.log('COS Control: Memories Applied-this-week render canary passed' + (helper ? ' (live helper)' : ' (captured fixtures)'));
}
main().catch(e => { console.error(e && e.stack || e); process.exit(1); });
