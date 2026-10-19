// 0.5.327: renders the shipped memories-app.js and checks the Cues to rate and Rated cues entries from the nav a person
// touches: they show only when the app says the server keeps a cue history (cues.summary `available: true`), with the
// unrated count; a refusal, a missing answer or `available: false` (an older server) shows neither; each entry asks the
// app for its native view (cues.open with `rate` or `rated`) and never renders a page view of its own.
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

// summary: the cues.summary answer, or 'refuse' (the app refuses, as a build without the op does).
function boot(summary) {
  const calls = [], els = {};
  const document = { activeElement: null, addEventListener() {}, removeEventListener() {}, createElement: () => element('anon'),
    querySelector(sel) { return els[sel] ||= element(sel); }, querySelectorAll() { return []; }, body: element('body') };
  const context = { crypto, console, setTimeout, clearTimeout, setInterval, clearInterval, document, Intl, Date, Promise, JSON, Math, Number, String, Array, Object, Error, navigator: { language: 'en-US' }, location: { search: '' } };
  context.window = context;
  context.webkit = { messageHandlers: { cos: { postMessage(msg) {
    calls.push(msg);
    setImmediate(() => {
      let details = null, ok = true, message = '';
      switch (msg.op) {
        case 'status': details = status; break;
        case 'learning.list': details = { state: 'empty', events: [], shown: 0, total: 0, nextCursor: null, coverage: {} }; break;
        case 'learning.review': details = { state: 'empty', events: [], shown: 0, total: 0, reviewCount: 0, coverage: {} }; break;
        case 'learning.status': details = { counts_by_type: {}, stores: {}, complete: true }; break;
        case 'memories.list': details = { memories: [], total: 0 }; break;
        case 'graph.status': details = {}; break;
        case 'cues.summary': if (summary === 'refuse') { ok = false; message = 'This page cannot ask for cues.summary.'; } else details = summary; break;
        case 'cues.open': details = {}; break;
        default: ok = false; message = 'This page cannot ask for ' + msg.op;
      }
      context.window.cosBridge.resolve(msg.id, { ok, message, details });
    });
  } } } };
  vm.runInNewContext(page, context, { filename: 'memories-app.js' });
  return { context, calls, nav: () => (els['#memoryNav'] || element('x')).innerHTML };
}

async function main() {
  let passed = 0;
  const ok = (cond, what) => { assert.ok(cond, what); passed++; };

  let b = boot({ available: true, unrated: 28, rated: 3, total: 31 });
  await flush();
  ok(b.calls.filter(c => c.op === 'cues.summary').length === 1, 'the page asks the app once on load');
  ok(/>Cues to rate \(28\)</.test(b.nav()), 'Cues to rate shows the unrated count');
  ok(/>Rated cues</.test(b.nav()), 'Rated cues shows');
  ok(b.nav().indexOf('Cues to rate') > b.nav().indexOf('To review') && b.nav().indexOf('Rated cues') < b.nav().indexOf('Knowledge'),
    'the entries sit after To review, before Knowledge');
  b.context.window.cosApp.openCues('rate'); await flush();
  ok(JSON.stringify(b.calls.at(-1)) === JSON.stringify({ id: b.calls.at(-1).id, op: 'cues.open', args: { view: 'rate' } }), 'Cues to rate asks for the native view');
  b.context.window.cosApp.openCues('rated'); await flush();
  ok(b.calls.at(-1).op === 'cues.open' && b.calls.at(-1).args.view === 'rated', 'Rated cues asks for its view');
  b.context.window.cosApp.openCues('<script>'); await flush();
  ok(b.calls.at(-1).args.view === 'rate', 'only the two view names cross');

  b = boot({ available: true, unrated: 0, rated: 31, total: 31 });
  await flush();
  ok(/>Cues to rate</.test(b.nav()) && !/Cues to rate \(/.test(b.nav()), 'nothing left to rate: no count');

  b = boot({ available: true, unrated: '<img src=x onerror=alert(1)>', rated: 0, total: 1 });
  await flush();
  ok(!/<img/.test(b.nav()) && />Cues to rate</.test(b.nav()), 'a count that is not a number is never drawn (no markup reaches the nav)');

  for (const [summary, label] of [[{ available: false }, 'available false (an older server)'], ['refuse', 'a refusal (an app without the op)'],
    [null, 'no answer'], [{ available: 'yes', unrated: 4 }, 'available that is not true']]) {
    b = boot(summary);
    await flush();
    ok(!/Cues to rate|Rated cues/.test(b.nav()), 'hidden on ' + label);
    ok(/Knowledge/.test(b.nav()), 'the rest of the nav still draws on ' + label);
  }
  console.log('memories cues canary: ' + passed + ' passed');
}
main().catch(e => { console.error('memories cues canary FAILED:', e.message); process.exit(1); });
