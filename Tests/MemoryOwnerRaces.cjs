// Exercise actual UI callbacks using deferred replies and a synthetic canvas.
// No browser, helper process, provider, profile file or live service is used.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '../Resources/memories');
const page = fs.readFileSync(path.join(root, 'memories-app.js'), 'utf8');
const workspaceSource = fs.readFileSync(path.join(root, 'memory-workspace.js'), 'utf8');
const graphSource = fs.readFileSync(path.join(root, 'graph-explorer.js'), 'utf8');
const flush = () => new Promise(resolve => setImmediate(resolve));
const tests = [];
const test = (name, run) => tests.push({ name, run });

function between(source, start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a);
  assert.ok(a >= 0 && b > a, `Source boundary missing: ${start}`);
  return source.slice(a, b);
}
function ownerFixture() {
  const state = { ownerProfile: { owner_name: 'Synthetic Old' }, ownerDraft: 'Synthetic New' };
  const calls = [];
  const context = { state, renderModalIfOpen() {}, chooseDefaultFocus() {}, toast() {},
    call(route, args) { return new Promise((resolve, reject) => calls.push({ route, args, resolve, reject })); }
  };
  const load = between(page, '  var ownerReadSerial=', '  function openSettings(');
  const handlers = between(page, '    ownerDraft:function', '    openStewardship:function');
  vm.runInNewContext(`${load};globalThis.actions=({${handlers}});`, context);
  return { state, calls, actions: context.actions };
}

test('an older GET cannot restore profile state after a successful Save', async () => {
  const f = ownerFixture();
  f.actions.loadOwner(); f.actions.saveOwner();
  f.calls[1].resolve({ owner_name: 'Synthetic New' }); await flush();
  f.calls[0].resolve({ owner_name: 'Synthetic Old' }); await flush();
  assert.equal(f.state.ownerProfile.owner_name, 'Synthetic New');
  f.actions.ownerDraft('Synthetic Next'); f.actions.saveOwner();
  assert.equal(f.calls[2].args.expected, 'Synthetic New');
});

test('an older GET error cannot replace a successful Save with an error', async () => {
  const f = ownerFixture();
  f.actions.loadOwner(); f.actions.saveOwner();
  f.calls[1].resolve({ owner_name: 'Synthetic New' }); await flush();
  f.calls[0].reject(new Error('old read failed')); await flush();
  assert.equal(f.state.ownerError, null);
  assert.equal(f.state.ownerBusy, false);
});

test('the latest GET wins and preserves a draft already being typed', async () => {
  const f = ownerFixture();
  f.actions.loadOwner(); f.actions.loadOwner();
  f.actions.ownerDraft('Synthetic Draft');
  f.calls[1].resolve({ owner_name: 'Synthetic Current' }); await flush();
  f.calls[0].resolve({ owner_name: 'Synthetic Old' }); await flush();
  assert.equal(f.state.ownerProfile.owner_name, 'Synthetic Current');
  assert.equal(f.state.ownerDraft, 'Synthetic Draft');
});

test('typing during Save survives while the committed CAS owner advances', async () => {
  const f = ownerFixture();
  f.actions.saveOwner();
  f.actions.ownerDraft('Synthetic Still Typing');
  f.actions.loadOwner();
  assert.equal(f.calls.length, 1, 'A GET during the write must not race the receipt');
  f.calls[0].resolve({ owner_name: 'Synthetic New' }); await flush();
  assert.equal(f.state.ownerDraft, 'Synthetic Still Typing');
  assert.equal(f.state.ownerProfile.owner_name, 'Synthetic New');
  f.actions.saveOwner();
  assert.equal(f.calls[1].args.name, 'Synthetic Still Typing');
  assert.equal(f.calls[1].args.expected, 'Synthetic New');
});

test('owner rename invalidates the previous default-focus lookup', async () => {
  const state = { status: { ownerName: 'Synthetic Old' }, graphFocus: null,
    graphFocusChosen: false, view: 'knowledge', knowledgeTab: 'graph' };
  const calls = [];
  const context = { state, render() {}, call(route, args) {
    return new Promise(resolve => calls.push({ route, args, resolve }));
  }};
  const focus = between(page, '  function chooseDefaultFocus()', '  // While the ingest lock');
  vm.runInNewContext(`${focus};globalThis.choose=chooseDefaultFocus;`, context);
  context.choose();
  state.status.ownerName = 'Synthetic New'; state.graphFocusResolved = false;
  context.choose();
  calls[1].resolve({ items: [{ id: 'Synthetic New', type: 'person' }] }); await flush();
  calls[0].resolve({ items: [{ id: 'Synthetic Old', type: 'person' }] }); await flush();
  assert.equal(state.graphFocus, 'Synthetic New');
});

function element() {
  return { textContent: '', value: '', roles: {}, listeners: {}, children: [], dataset: {},
    setAttribute() {}, removeAttribute() {}, querySelectorAll() { return []; },
    addEventListener(name, fn) { (this.listeners[name] ||= []).push(fn); },
    appendChild(child) { this.children.push(child); return child; },
    replaceChildren(...children) { this.children = children; },
    querySelector(selector) {
      const key = selector.match(/data-role="([^"]+)/)[1];
      return this.roles[key] ||= element();
    }
  };
}
async function canvasFixture() {
  let data, options;
  const context = { window: {}, crypto, document: { createElement: element },
    COSGraphExplorer: { mount(_host, opts) {
      data = opts.data; options = opts;
      return { snapshot: () => data, replaceData(next) { data = next; } };
    }}
  };
  vm.runInNewContext(workspaceSource, context);
  const workspace = context.window.COSMemoryWorkspace.create({ toast() {},
    call: async (_route, args) => args.action === 'status'
      ? { protocol: 1, capabilities: ['graph_overview'] }
      : { protocol: 1, nodes: [{ id: 'Synthetic Point', x: 1, y: 2 }], links: [],
          generation: { base: 'synthetic', overlay: 'none', policy: 1 } }
  });
  workspace.attach(element(), null); await flush();
  const dragHandlers = {}, nodeHandlers = {};
  const dragApi = { clickDistance() { return this; }, on(name, fn) { dragHandlers[name] = fn; return this; } };
  const node = { call() {}, on(name, fn) { nodeHandlers[name] = fn; return this; } };
  const sim = { alphaTarget() { return this; }, restart() { return this; } };
  const renderer = { node, d3: { drag: () => dragApi }, sim, opts: options,
    state: { anchored: {} }, updateAnchors() {}, setTimeout() {}, select() {}, tracePath() {}
  };
  vm.runInNewContext(between(graphSource, '      var dragDist =', '      function updateAnchors()'), renderer);
  vm.runInNewContext(between(graphSource, '      // Click, double-click, keyboard on nodes.', '      // Hover tip.'), renderer);
  return { workspace, dragHandlers, nodeHandlers, point: data.nodes[0], options };
}
function plan() {
  return { nodes: [{ id: 'Synthetic Answer' }], links: [], anchors: ['Synthetic Answer'],
    filters: { hops: 3, direction: 'undirected', avoid: [] },
    generation: { base: 'synthetic', overlay: 'none', policy: 1 } };
}

test('initial drawing and passive reattachment do not invalidate the first question', async () => {
  const f = await canvasFixture();
  const token = f.workspace.questionToken();
  f.workspace.attach(element(), null); await flush();
  assert.equal(f.workspace.questionToken().epoch, token.epoch);
  assert.equal(f.workspace.applyQuestion(plan(), token), true);
});

test('a question resolving while a drag is held cannot replace the canvas', async () => {
  const f = await canvasFixture();
  const token = f.workspace.questionToken();
  f.dragHandlers.start({ x: 1, y: 2, active: false }, f.point);
  f.dragHandlers.drag({ x: 20, y: 30 }, f.point);
  assert.equal(f.workspace.applyQuestion(plan(), token), false);
  assert.equal(f.workspace.snapshot().nodes[0].id, 'Synthetic Point');
  f.dragHandlers.end({ active: false }, f.point);
});

test('completed drag-to-pin and double-click unpin both fence pending answers', async () => {
  const f = await canvasFixture();
  let token = f.workspace.questionToken();
  f.dragHandlers.start({ x: 1, y: 2, active: false }, f.point);
  f.dragHandlers.drag({ x: 20, y: 30 }, f.point);
  f.dragHandlers.end({ active: false }, f.point);
  assert.equal(f.workspace.applyQuestion(plan(), token), false);
  token = f.workspace.questionToken();
  f.nodeHandlers.dblclick({ stopPropagation() {} }, f.point);
  assert.equal(f.workspace.applyQuestion(plan(), token), false);
});

(async () => {
  let failed = 0;
  for (const { name, run } of tests) {
    try { await run(); console.log(`PASS ${name}`); }
    catch (error) { failed++; console.error(`FAIL ${name}\n${error.stack}`); }
  }
  console.log(`${tests.length - failed}/${tests.length} memory owner and canvas race tests passed`);
  if (failed) process.exitCode = 1;
})();
