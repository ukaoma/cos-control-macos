/* COS Control · Memories (0.5.191).
   The reviewed prototype (operations/personal/wk36_2026/design/cos-control-learning/index.html),
   with every piece of demo state replaced by live data through the app's helper. This page never
   holds the server token: it posts {id, op, args} to the native host, which runs the helper and
   resolves the promise with {ok, message, details}. Actions without a backend tonight are shown
   disabled with the reason, never faked. */
(function () {
  'use strict';

  // ── bridge ──────────────────────────────────────────────────────
  var pending = {}, nextId = 1;
  function call(op, args) {
    return new Promise(function (resolve, reject) {
      var id = nextId++;
      pending[id] = { resolve: resolve, reject: reject };
      var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cos;
      if (!handler) { delete pending[id]; reject(new Error('Not connected to COS Control.')); return; }
      try { handler.postMessage({ id: id, op: op, args: args || {} }); }
      catch (e) { delete pending[id]; reject(e); }
    });
  }
  window.cosBridge = {
    resolve: function (id, payload) {
      var p = pending[id]; if (!p) return; delete pending[id];
      if (payload && payload.ok) p.resolve(payload.details || {});
      else p.reject(new Error((payload && payload.message) || 'The helper did not answer.'));
    },
    refresh: function () { loadAll(); },
    show: function (view) { if (view) { state.view = view === 'knowledge' ? 'knowledge' : 'learning'; if (view !== 'knowledge') state.filter = view; render(); } }
  };

  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]; }); };
  var fmt = function (n) { return Number(n || 0).toLocaleString(); };
  function stamp(iso) { if (!iso) return ''; var s = String(iso); return s.length >= 16 ? s.slice(0, 16).replace('T', ' ') : s; }
  function dateOnly(iso) { return iso ? String(iso).slice(0, 10) : ''; }
  function toast(text) { var el = document.querySelector('#toast'); el.textContent = text; el.classList.remove('hidden'); clearTimeout(window.toastTimer); window.toastTimer = setTimeout(function () { el.classList.add('hidden'); }, 3400); }

  // ── state ───────────────────────────────────────────────────────
  var state = {
    view: 'learning', filter: 'recent', selected: null, knowledgeTab: 'sources', knowledgeFocus: null,
    status: null, learningStatus: null, graphStatus: null,
    recent: [], recentTotal: null, recentCursor: null, review: [], reviewCount: null, memories: [], memoriesTotal: null,
    memoryQuery: '', memoryHits: null, coverage: {},
    detail: {}, memoryDetail: {}, passages: {}, loading: {}, errors: {},
    graphFocus: 'COS', graphFocusChosen: false, ingesting: null, ingestLimit: 10, ingestWatch: null, graphQuery: '',
    progress: null, fetchWatch: null, setup: null, setupLoading: false, setupError: null, setupBusy: null, armed: null, askQ: '', askAnswer: null, askBusy: false, knowledgeTabChosen: false, graphController: null, copyId: null, copyOptions: { sources: true, graph: false }
  };

  // ── loading ─────────────────────────────────────────────────────
  function loadAll() {
    state.errors = {};
    call('status').then(function (d) { state.status = d; chooseDefaultFocus(); render(); }, function (e) { state.errors.status = e.message; render(); });
    call('learning.list', { days: 90, limit: 50 }).then(function (d) {
      state.recent = (d.events || []); state.recentTotal = d.total; state.recentCursor = d.nextCursor || null; state.coverage = d.coverage || {}; render();
    }, function (e) { state.errors.recent = e.message; render(); });
    call('learning.review', { limit: 200 }).then(function (d) {
      state.review = d.events || []; state.reviewCount = d.reviewCount != null ? d.reviewCount : d.total; render();
    }, function (e) { state.errors.review = e.message; render(); });
    call('memories.list', { limit: 50 }).then(function (d) {
      state.memories = d.memories || []; state.memoriesTotal = d.total; render();
    }, function (e) { state.errors.memories = e.message; render(); });
    call('learning.status').then(function (d) { state.learningStatus = d; render(); }, function () {});
    loadGraphStatus();
  }
  // The graph opens on the person this COS is about (the profile's owner_name,
  // resolved through a search so the entity's exact spelling wins), not on "COS".
  // A focus the user picks or recenters on is never overridden.
  function chooseDefaultFocus() {
    var name = state.status && state.status.ownerName;
    if (!name || state.graphFocusChosen || state.graphFocusResolved) return;
    state.graphFocusResolved = true;
    call('graph.search', { q: name, limit: 5 }).then(function (d) {
      var items = d.items || [];
      var exact = items.find(function (it) { return String(it.id).toLowerCase() === String(name).toLowerCase(); });
      var pick = exact || items.find(function (it) { return String(it.type || '').toLowerCase() === 'person'; }) || items[0];
      if (pick && !state.graphFocusChosen) { state.graphFocus = pick.id; if (state.view === 'knowledge' && state.knowledgeTab === 'graph') render(); }
    }, function () {});
  }
  // While the ingest lock is held, read the run's progress every 5 s (and the
  // Sync card every 15 s), four hours at most; when the lock frees, say what
  // the run indexed and what is still queued. A run started elsewhere holds
  // the lock but writes no log here, so it shows as external with the counts.
  function watchIngest() {
    if (state.ingestWatch) return;
    var before = state.graphStatus && state.graphStatus.queue ? Number(state.graphStatus.queue.pending) : null, ticks = 0;
    function finish() {
      clearInterval(state.ingestWatch); state.ingestWatch = null;
      var pr = state.progress || {};
      loadGraphStatus().then(function () {
        var g = state.graphStatus || {}, after = g.queue ? Number(g.queue.pending) : null;
        var done = pr.done ? fmt(pr.done) + ' indexed' + (pr.failed ? ', ' + fmt(pr.failed) + ' failed' : '') : (before != null && after != null && before > after ? fmt(before - after) + ' indexed' : 'Indexing finished');
        state.ingesting = { note: done + (after != null ? ' · ' + fmt(after) + ' still queued' : '') };
        if (state.knowledgeTab === 'setup') loadSetup();
        setTimeout(function () { state.ingesting = null; if (state.view === 'knowledge') render(); }, 60000);
        if (state.view === 'knowledge') render();
      });
    }
    function tick() {
      ticks++;
      var reads = [call('graph.progress').then(function (d) { state.progress = d; }, function () {})];
      if (ticks % 3 === 0) reads.push(loadGraphStatus());
      Promise.all(reads).then(function () {
        var pr = state.progress || {}, g = state.graphStatus || {}, lk = pr.lock || g.lock || {};
        var held = pr.running === true || lk.state === 'exclusive' || lk.state === 'shared';
        if (!held || ticks > 2880) return finish();
        if (state.view === 'knowledge') render();
      });
    }
    state.ingestWatch = setInterval(tick, 5000); tick();
  }
  // The run as it stands: the Sync card and the setup's sample step both show it.
  function progressBlock() {
    var pr = state.progress, g = state.graphStatus || {}, lk = (pr && pr.lock) || g.lock || {};
    var held = (pr && pr.running === true) || lk.state === 'exclusive' || lk.state === 'shared';
    if (!held) return '';
    if (!pr) return '<div class="ingest-progress"><b>Indexing now</b><span class="muted"> · reading progress…</span></div>';
    var head, body = '';
    if (pr.external) head = '<b>Indexing now from another session</b>' + (pr.pid ? ' (pid ' + esc(pr.pid) + ')' : '') + ' · ' + fmt(pr.pending || 0) + ' pending · progress detail shows for runs started here';
    else {
      var seen = pr.done + pr.failed + (pr.current ? 1 : 0);
      head = '<b>Indexing ' + (pr.total != null ? fmt(Math.min(seen, pr.total)) + ' of ' + fmt(pr.total) : 'now') + '</b>' + (pr.pid ? ' (pid ' + esc(pr.pid) + ')' : '') + ' · ' + fmt(pr.pending || 0) + ' pending';
      if (pr.current) body += '<div class="muted">Now: ' + esc(pr.current.id) + (pr.current.est_calls != null ? ' · about ' + fmt(pr.current.est_calls) + ' calls' : '') + '</div>';
    }
    if (pr.items && pr.items.length) body += '<div class="ingest-items">' + pr.items.slice(-4).map(function (it) { return '<span class="' + (it.outcome === 'indexed' ? 'ok' : it.outcome === 'failed' ? 'bad' : '') + '">' + (it.outcome === 'indexed' ? '✓ ' : it.outcome === 'failed' ? '! ' : '') + esc(it.id) + (it.seconds != null ? ' ' + Math.round(it.seconds) + ' s' : '') + '</span>'; }).join('') + '</div>';
    if (pr.budget) body += '<div class="muted">Budget: ' + fmt(pr.budget.used) + ' of ' + fmt(pr.budget.cap) + ' calls today</div>';
    if (pr.log_tail && pr.log_tail.length) body += '<details class="ingest-log"><summary>Show log</summary><pre>' + esc(pr.log_tail.join('\n')) + '</pre></details>';
    return '<div class="ingest-progress" aria-live="polite"><div>' + head + '</div>' + body + '</div>';
  }
  function loadGraphStatus() {
    return call('graph.status').then(function (d) { state.graphStatus = d; state.errors.graph = null; var lk = d.lock || {}; if (lk.state === 'exclusive' || lk.state === 'shared') watchIngest(); if (d.entities == null && !state.knowledgeTabChosen) state.knowledgeTab = 'setup'; render(); }, function (e) { state.errors.graph = e.message; render(); });
  }
  function loadMore() {
    if (!state.recentCursor) return;
    call('learning.list', { days: 90, limit: 50, sinceTs: state.recentCursor.since_ts, sinceEventId: state.recentCursor.since_event_id }).then(function (d) {
      var seen = {}; state.recent.forEach(function (e) { seen[e.event_id] = 1; });
      (d.events || []).forEach(function (e) { if (!seen[e.event_id]) state.recent.push(e); });
      state.recentCursor = (d.events || []).length ? (d.nextCursor || null) : null; render();
    }, function (e) { toast(e.message); });
  }
  function ensureDetail(id) {
    if (!id || state.detail[id] || state.loading[id]) return;
    state.loading[id] = true;
    call('learning.event', { id: id }).then(function (d) { state.detail[id] = d; delete state.loading[id]; render(); }, function (e) { state.detail[id] = { _error: e.message }; delete state.loading[id]; render(); });
  }
  function ensureMemoryDetail(id) {
    if (!id || state.memoryDetail[id] || state.loading['m:' + id]) return;
    state.loading['m:' + id] = true;
    call('memory.detail', { id: id }).then(function (d) { state.memoryDetail[id] = d; delete state.loading['m:' + id]; render(); }, function (e) { state.memoryDetail[id] = { _error: e.message }; delete state.loading['m:' + id]; render(); });
  }

  // ── rows ────────────────────────────────────────────────────────
  var KIND = { captured: 'Captured', proposed: 'Proposed', promotable: 'Promotable pattern', saved: 'Saved', retrieved: 'Retrieved', used: 'Used', checked: 'Checked', dismissed: 'Dismissed', reverted: 'Reverted', reopened: 'Reopened', consolidated: 'Consolidated', previewed: 'Previewed' };
  var STORE = { self_improvement_queue: 'Self-improvement queue', correction_journal: 'Correction journal', bot_memory: 'Bot memory', review_ledger: 'Review ledger', git_versions: 'Skill versions', eval_scores: 'Eval scores', reflect_log: 'Reflect log', capture_ledger: 'Capture ledger' };
  function isProposal(e) { return e && e.target && e.target.kind === 'task-proposal'; }
  function isPattern(e) { return e && (e.event_type === 'promotable' || (e.target && e.target.kind === 'pattern')); }
  function kindLabel(e) { if (isProposal(e)) return 'Task proposal'; if (isPattern(e)) return 'Promotable pattern'; return KIND[e.event_type] || e.event_type || 'Event'; }
  function outcomeText(e) { var o = e && e.outcome; if (!o) return null; if (typeof o === 'string') return o; return o.result ? (o.result + (o.name ? ' · ' + o.name : '')) : null; }
  function rowStatus(e) {
    var o = outcomeText(e);
    if (o) return { text: 'Result checked', color: 'green' };
    if (isProposal(e) || isPattern(e)) return { text: 'Needs your review', color: '' };
    if (e.event_type === 'dismissed') return { text: 'Dismissed', color: '' };
    if (e.event_type === 'used' || e.event_type === 'retrieved') return { text: 'Used later', color: 'green' };
    return { text: 'Saved · No later use', color: '' };
  }
  function lessonRow(e, selected) {
    var st = rowStatus(e);
    var meta = [STORE[e.store] || e.store, e.scope, stamp(e.ts)].filter(Boolean).join(' · ');
    return '<button class="lesson ' + (selected ? 'selected' : '') + '" onclick="cosApp.select(\'' + esc(e.event_id) + '\')" aria-pressed="' + (selected ? 'true' : 'false') + '"><div class="kind">' + esc(kindLabel(e)) + '</div><span class="title">' + esc(e.title || '(untitled)') + '</span><div class="meta">' + esc(meta) + '</div><span class="status ' + st.color + '">' + esc(st.text) + '</span></button>';
  }
  function memoryRow(m, selected) {
    var title = m.summary || m.content || '(untitled)';
    var meta = [m.type, dateOnly(m.created_at)].filter(Boolean).join(' · ');
    return '<button class="lesson ' + (selected ? 'selected' : '') + '" onclick="cosApp.selectMemory(\'' + esc(m.id) + '\')" aria-pressed="' + (selected ? 'true' : 'false') + '"><div class="kind">Memory</div><span class="title">' + esc(String(title).slice(0, 140)) + '</span><div class="meta">' + esc(meta) + '</div></button>';
  }

  // ── summary and nav ─────────────────────────────────────────────
  function memoryNav() {
    var review = state.reviewCount != null ? state.reviewCount : (state.status && state.status.learningToReview) || 0;
    document.querySelector('#workspace').classList.toggle('knowledge', state.view === 'knowledge');
    document.querySelector('#memoryNav').innerHTML = [['recent', 'Recent learning'], ['memories', 'All memories'], ['review', 'To review' + (review ? ' (' + fmt(review) + ')' : '')]].map(function (p) {
      var on = state.view !== 'knowledge' && state.filter === p[0];
      return '<button class="' + (on ? 'active' : '') + '" aria-pressed="' + on + '" onclick="cosApp.setFilter(\'' + p[0] + '\')">' + p[1] + '</button>';
    }).join('') + '<button class="' + (state.view === 'knowledge' ? 'active' : '') + '" aria-pressed="' + (state.view === 'knowledge') + '" onclick="cosApp.openKnowledge()">Knowledge</button>';
  }
  function summary() {
    var review = state.reviewCount != null ? state.reviewCount : (state.status && state.status.learningToReview);
    var checked = state.recent.filter(function (e) { return outcomeText(e); }).length;
    var parts = [];
    if (review != null) parts.push('<span><strong>' + fmt(review) + ' change' + (review === 1 ? '' : 's') + '</strong> to review</span>');
    if (state.recentTotal != null) parts.push('<span><strong>' + fmt(state.recentTotal) + ' event' + (state.recentTotal === 1 ? '' : 's') + '</strong> in 90 days</span>');
    parts.push('<span><strong>' + fmt(checked) + ' result' + (checked === 1 ? '' : 's') + '</strong> checked on this page</span>');
    parts.push('<span>Learning on · <button class="link" onclick="cosApp.openLog()">View activity log</button></span>');
    document.querySelector('#summary').innerHTML = parts.join('');
    var s = state.status || {};
    var bridge = s.contextScriptsDirectory || (s.contextState === 'bridge');
    document.querySelector('#storage').textContent = 'Stored on this Mac · ' + (bridge ? 'Advanced search connected' : 'Plain files');
    document.querySelector('#footnote').textContent = state.status ? ('Server ' + (s.installedVersion || '') + ' · ' + (s.runtimeState || '')).trim() : '';
  }

  // ── render ──────────────────────────────────────────────────────
  function render() {
    summary(); memoryNav();
    if (state.view === 'knowledge') { renderKnowledge(); return; }
    var inbox = document.querySelector('#inbox'), detail = document.querySelector('#detail');
    document.querySelector('#workspace').style.gridTemplateColumns = ''; inbox.classList.remove('hidden');
    if (state.filter === 'memories') { renderMemories(inbox, detail); return; }
    var rows = state.filter === 'review' ? state.review : state.recent;
    var err = state.filter === 'review' ? state.errors.review : state.errors.recent;
    var loading = state.filter === 'review' ? (state.reviewCount == null && !err) : (state.recentTotal == null && !err);
    if (rows.length && !rows.some(function (x) { return x.event_id === state.selected; })) state.selected = rows[0].event_id;
    inbox.innerHTML = '<div class="date">' + (state.filter === 'recent' ? 'RECENT LEARNING · 90 DAYS' : 'PROPOSED CHANGES') + '</div>' +
      (err ? '<div class="host-state"><div><h3>Not available</h3><p>' + esc(err) + '</p><button onclick="cosApp.refresh()">Retry</button></div></div>' : '') +
      (loading ? '<div class="host-state">Loading…</div>' : '') +
      rows.map(function (e) { return lessonRow(e, e.event_id === state.selected); }).join('') +
      (state.filter === 'recent' && state.recentCursor ? '<div class="actions"><button class="quiet" onclick="cosApp.loadMore()">Load more</button></div>' : '') +
      coverageNote();
    if (!rows.length) {
      detail.innerHTML = loading ? '<div class="host-state">Loading…</div>' : (err ? '' : '<div class="empty"><div><h2>You’re up to date.</h2><p>' + (state.filter === 'review' ? 'No proposed changes are waiting for review.' : 'Nothing learned in the last 90 days.') + '</p>' + (state.filter === 'review' ? '<button onclick="cosApp.setFilter(\'recent\')">View recent learning</button>' : '') + '</div></div>');
      return;
    }
    var event = rows.find(function (x) { return x.event_id === state.selected; });
    ensureDetail(event.event_id);
    var full = state.detail[event.event_id];
    detail.innerHTML = detailActions(event) + lessonDetail(Object.assign({}, event, full && !full._error ? full : {}), full);
  }
  function coverageNote() {
    var gaps = Object.keys(state.coverage || {}).filter(function (k) { return state.coverage[k] && state.coverage[k].state !== 'ok'; });
    if (!gaps.length) return '';
    return '<p class="muted" style="font-size:10px;padding:10px 9px 0">Not instrumented: ' + esc(gaps.map(function (k) { return k + ' (' + state.coverage[k].state + ')'; }).join(', ')) + '</p>';
  }

  // ── lesson detail (the reviewed timeline) ───────────────────────
  function event(title, meta, body, done, last) { return '<section class="event ' + (done !== false ? 'complete' : '') + ' ' + (last ? 'last' : '') + '"><div class="row spread"><h3>' + title + '</h3><span class="meta">' + meta + '</span></div>' + body + '</section>'; }
  function detailActions(e) {
    return '<div class="context-actions row spread"><span class="eyebrow">' + esc(STORE[e.store] || e.store || '') + '</span><div class="row"><button class="quiet" onclick="cosApp.openKnowledge(\'' + esc(e.event_id) + '\')">Open sources</button><button class="quiet" onclick="cosApp.exploreInGraph(\'' + esc(e.event_id) + '\')">Explore in graph</button><button onclick="cosApp.openCopyContext(\'' + esc(e.event_id) + '\')">Copy context</button></div></div>';
  }
  function sourceEvent(e) {
    var ref = (e.source_refs || [])[0] || {};
    var d = e.detail || {};
    var quote = ref.excerpt || d.content || (d.bodies || [])[0] || '';
    var title = e.store === 'correction_journal' ? 'You corrected COS' : e.store === 'self_improvement_queue' ? 'A task proposed a change' : e.store === 'bot_memory' ? 'COS captured this' : e.store === 'eval_scores' || e.store === 'reflect_log' ? 'A run was checked' : 'Captured';
    var open = e.store === 'bot_memory' && e.lesson_id ? '<button class="link" onclick="cosApp.openMemoryRecord(\'' + esc(e.lesson_id) + '\')">Open source record</button>' : (ref.id ? '<span class="meta">' + esc(ref.kind || '') + ' · ' + esc(ref.id) + '</span>' : '');
    return event(title, esc(stamp(e.ts) || 'Source'), (quote ? '<div class="quote">' + esc(quote) + '</div>' : '<p>No excerpt was stored with this record.</p>') + open);
  }
  function changeEvent(e, full) {
    var d = e.detail || {};
    var proposal = isProposal(e), pattern = isPattern(e);
    var applies = (e.applies_to || []).map(function (a) { return typeof a === 'string' ? a : [a.name || a.path || a.id, a.cadence].filter(Boolean).join(' · '); }).filter(Boolean);
    var body = '';
    if (proposal) {
      body += '<p>Proposed by <b style="color:var(--fg)">' + esc(d.task || e.category || 'a scheduled task') + '</b>' + (d.layer ? ' · layer ' + esc(d.layer) : '') + (d.date ? ' · ' + esc(d.date) : '') + '.</p>';
      body += (d.entry || d.content ? '<div class="quote">' + esc(d.entry || d.content) + '</div>' : '') + (d.bodies || []).map(function (b) { return '<p>' + esc(b) + '</p>'; }).join('');
      if (d.logged_times) body += '<p>Logged ' + fmt(d.logged_times) + ' time' + (d.logged_times === 1 ? '' : 's') + '.</p>';
    } else if (d.before || d.after || d.rule) {
      body += '<div class="change">' + (d.before ? '<div><label>Before</label>' + esc(d.before) + '</div>' : '') + '<div class="after"><label>' + (d.after ? 'After' : 'Rule') + '</label>' + esc(d.after || d.rule || '') + '</div></div>';
      if (d.rule && d.after) body += '<p style="margin-top:8px"><b style="color:var(--fg)">Rule</b> ' + esc(d.rule) + '</p>';
    } else if (d.content) {
      body += '<div class="quote">' + esc(d.content) + '</div>';
    } else {
      body += '<p>' + esc(e.title || '') + '</p>';
    }
    if (e.target && e.target.version) body += '<p>Version <b style="color:var(--fg)">' + esc(e.target.version) + '</b></p>';
    body += effectBlock(e, applies);
    var decision = latestDecisionFor(e);
    var actions = '';
    if (proposal || pattern) {
      var dismissed = decision === 'dismissed';
      actions = '<div class="actions">' +
        '<button class="primary" disabled title="Accepting a change writes a skill version; that arrives with skill versioning in a later release.">Accept change</button>' +
        '<button disabled title="Editing a proposed instruction arrives with skill versioning.">Edit</button>' +
        (dismissed
          ? '<button onclick="cosApp.decide(\'' + esc(e.event_id) + '\',\'reopened\')">Restore proposal</button>'
          : '<button class="quiet" onclick="cosApp.decide(\'' + esc(e.event_id) + '\',\'dismissed\')">Dismiss</button>') +
        '</div>';
    }
    var title = decision === 'dismissed' ? 'Change dismissed' : proposal ? 'Proposed change' : e.event_type === 'promotable' ? 'Promotable pattern' : (KIND[e.event_type] || 'Change');
    return event(title, proposal ? 'Instruction' : esc(e.engine || e.scope || ''), body + actions);
  }
  function latestDecisionFor(e) { return state.decisions && state.decisions[e.lesson_id]; }
  function effectBlock(e, applies) {
    var d = e.detail || {};
    var o = outcomeText(e);
    var repeat = d.occurrences != null ? (fmt(d.occurrences) + ' occurrence' + (d.occurrences === 1 ? '' : 's') + (d.threshold ? ' (threshold ' + d.threshold + ')' : '')) : d.logged_times ? ('logged ' + fmt(d.logged_times) + ' time' + (d.logged_times === 1 ? '' : 's')) : 'No repeat data';
    return '<div class="effect"><div class="row spread"><label>Expected effect</label><span class="badge">Real data · projected rows are not observed</span></div><ul class="effect-list">' +
      '<li><b>Where it applies</b>' + (applies.length ? esc(applies.join(', ')) : 'Scope not resolved on this Mac') + '</li>' +
      '<li><b>Preview</b>Preview not available until 3.5</li>' +
      '<li><b>Checks</b>' + (o ? esc(o) : (d.status ? esc(d.status) : 'No check recorded')) + '</li>' +
      '<li><b>Repeat rate</b>' + esc(repeat) + '</li></ul></div>';
  }
  function useEvent(e) {
    var o = outcomeText(e);
    if (o) return event('A later result was checked', esc(e.outcome && e.outcome.evaluator ? e.outcome.evaluator : 'Checked'), '<div class="check">✓ ' + esc(o) + '</div><p>One recorded check. Evidence for that run, not a guarantee about every future answer.</p>');
    if (e.event_type === 'used' || e.event_type === 'retrieved') return event('Used in a later session', esc(e.engine || ''), '<p>This record was ' + esc(e.event_type) + ' by ' + esc(e.engine || 'an engine') + '.</p>');
    return event('Next use', 'Pending evidence', '<p>No later retrieval, use, or result has been recorded for this lesson.</p>', false);
  }
  function evidenceEvent(e) {
    var n = (e.source_refs || []).length;
    return event('Evidence for this lesson', 'Knowledge', '<p>' + fmt(n) + ' source record' + (n === 1 ? '' : 's') + '. Sources are what was actually said. Graph links are extracted context, not proof that the lesson worked.</p><div class="actions"><button onclick="cosApp.openKnowledge(\'' + esc(e.event_id) + '\')">Open sources</button><button onclick="cosApp.exploreInGraph(\'' + esc(e.event_id) + '\')">Explore in graph</button></div>' + (e.provenance && e.provenance !== 'complete' ? '<p>Provenance: ' + esc(e.provenance) + '.</p>' : ''), true, true);
  }
  function lessonDetail(e, full) {
    var o = outcomeText(e);
    var badge = o ? '<span class="badge green">Result checked</span>' : isProposal(e) ? '<span class="badge">Task proposal</span>' : isPattern(e) ? '<span class="badge">Promotable pattern</span>' : e.event_type === 'retrieved' || e.event_type === 'used' ? '<span class="badge purple">Retrieved in a later session</span>' : '<span class="badge">' + esc(kindLabel(e)) + '</span>';
    var head = '<div class="row spread">' + badge + '<span class="meta">' + esc(e.event_id) + '</span></div><h2 style="margin-top:12px">' + esc(e.title || '(untitled)') + '</h2><p class="intro">' + esc([STORE[e.store] || e.store, e.scope !== 'unknown' ? e.scope : null, e.engine !== e.scope && e.engine !== 'unknown' ? e.engine : null].filter(Boolean).join(' · ')) + '</p>';
    var note = full && full._error ? '<div class="notice">' + esc(full._error) + '</div>' : (!full ? '<p class="muted" style="font-size:11px">Loading the record…</p>' : '');
    if (e.detail && e.detail.truncated) note += '<div class="notice">Record truncated to fit; the store holds more than shown here.</div>';
    return head + note + '<div class="timeline">' + sourceEvent(e) + changeEvent(e, full) + useEvent(e) + evidenceEvent(e) + '</div>';
  }

  // ── all memories ────────────────────────────────────────────────
  function renderMemories(inbox, detail) {
    var rows = state.memoryHits != null ? state.memoryHits : state.memories;
    if (rows.length && !rows.some(function (x) { return x.id === state.selectedMemory; })) state.selectedMemory = rows[0].id;
    inbox.innerHTML = '<div class="date">SAVED MEMORIES' + (state.memoriesTotal != null ? ' · ' + fmt(state.memoriesTotal) + ' STORED' : '') + '</div>' +
      '<div class="search"><input type="search" placeholder="Search topics, ideas…" value="' + esc(state.memoryQuery) + '" oninput="cosApp.memoryQuery(this.value)" aria-label="Search memories"></div>' +
      (state.errors.memories ? '<div class="host-state"><div><h3>Not available</h3><p>' + esc(state.errors.memories) + '</p></div></div>' : '') +
      rows.map(function (m) { return memoryRow(m, m.id === state.selectedMemory); }).join('');
    if (!rows.length) { detail.innerHTML = '<div class="empty"><div><h2>' + (state.memoryQuery ? 'No memories match that lookup.' : 'No memories yet.') + '</h2><p>Drop markdown into memory/, or configure a bridge for the vector store.</p></div></div>'; return; }
    var m = rows.find(function (x) { return x.id === state.selectedMemory; });
    ensureMemoryDetail(m.id);
    var full = state.memoryDetail[m.id] || {};
    var record = full._error ? m : Object.assign({}, m, full);
    detail.innerHTML = '<div class="context-actions row spread"><span class="eyebrow">MEMORY</span><div class="row">' + (record.filePath ? '<button class="quiet" onclick="cosApp.reveal(\'' + esc(m.id) + '\')">Reveal in Finder</button>' : '') + '<button onclick="cosApp.copyMemory(\'' + esc(m.id) + '\')">Copy context</button></div></div>' +
      '<span class="badge green">Saved memory</span><h2 style="margin-top:12px">' + esc(record.summary || 'Memory') + '</h2><p class="intro">' + esc([record.type, dateOnly(record.created_at), record.source].filter(Boolean).join(' · ')) + '</p>' +
      (full._error ? '<div class="notice">' + esc(full._error) + '</div>' : '') +
      '<div class="timeline">' + event('What you asked COS to remember', esc(record.type || 'Memory'), '<div class="quote">' + esc(record.content || record.summary || '') + '</div>') + event('Available for recall', record.filePath ? 'Plain files' : 'Vector store', '<p>Saved memories are available to every session. Later retrieval, use, or result appears under Recent learning when it is recorded.</p>', false, true) + '</div>';
  }
  var memorySearchTimer = null;
  function memoryQuery(q) {
    state.memoryQuery = q; clearTimeout(memorySearchTimer);
    if (q.trim().length < 2) { state.memoryHits = null; render(); return; }
    memorySearchTimer = setTimeout(function () {
      call('memories.search', { q: q.trim(), limit: 20 }).then(function (d) { state.memoryHits = (d.hits || []); render(); }, function (e) { toast(e.message); });
    }, 350);
  }

  // ── knowledge ───────────────────────────────────────────────────
  function knowledgeAside() {
    var focus = state.knowledgeFocus && findEvent(state.knowledgeFocus);
    return '<div class="knowledge-label">EXPLORE KNOWLEDGE</div>' +
      '<button class="knowledge-route ' + (state.knowledgeTab === 'sources' ? 'active' : '') + '" aria-pressed="' + (state.knowledgeTab === 'sources') + '" onclick="cosApp.setKnowledgeTab(\'sources\')"><span>Source records</span><small>What was actually said</small></button>' +
      '<button class="knowledge-route ' + (state.knowledgeTab === 'graph' ? 'active' : '') + '" aria-pressed="' + (state.knowledgeTab === 'graph') + '" onclick="cosApp.setKnowledgeTab(\'graph\')"><span>Knowledge graph</span><small>Relationships · LightRAG</small></button>' +
      '<button class="knowledge-route ' + (state.knowledgeTab === 'setup' ? 'active' : '') + '" aria-pressed="' + (state.knowledgeTab === 'setup') + '" onclick="cosApp.setKnowledgeTab(\'setup\')"><span>Set up Knowledge</span><small>Sources, owner, first index</small></button>' +
      '<div class="knowledge-note"><h3>' + (focus ? 'Related to: ' + esc(focus.title) : 'Better context. Traceable learning.') + '</h3><p>Sources explain a memory. Relationships add context. Run evidence shows whether a change helped.</p><button class="link" onclick="cosApp.backToLearning()">← Back to recent learning</button></div>';
  }
  function hostLabel(h) { return String(h || '').replace(/\.local$/, '').replace(/-/g, ' '); }
  function syncCard() {
    var g = state.graphStatus, s = state.status || {};
    if (state.errors.graph) return '<section class="source-card sync-card"><div class="row spread"><h3>Sync</h3></div><p class="owner">' + esc(state.errors.graph) + '</p><div class="actions"><button onclick="cosApp.refreshGraph()">Retry</button></div></section>';
    if (!g) return '<section class="source-card sync-card"><div class="row spread"><h3>Sync</h3></div><p class="owner">Loading…</p></section>';
    var src = g.source || {}, q = g.queue || {}, b = g.budget || {}, lock = g.lock || {}, proc = g.processor || {};
    var ownerName = hostLabel(src.owner_host) || 'the owner Mac';
    var owner = (src.owner_state === 'owner' ? 'Owner: <b>this Mac</b> (' + esc(ownerName) + ') · canonical graph' : src.owner_state === 'replica' ? 'Owner: <b>' + esc(ownerName) + '</b> · this Mac reads an iCloud replica' : 'No ingestion owner set. Run --set-owner on the Mac that processes the queue.');
    var processor = (proc.state === 'none' || !proc.state ? 'No scheduled processor on this Mac' : proc.state === 'installed-idle' ? 'Processor installed, no run recorded yet' : 'Processor ' + esc(proc.state));
    // Index now (server 6.44.8): one bounded run of the queue, started here on the
    // owner Mac. A held lock (a Claude session, a scheduled run, a backup) shows
    // as "Indexing now" and the card refreshes until it is free again.
    var lockHeld = lock.state === 'exclusive' || lock.state === 'shared';
    var pendingN = q.pending != null ? Number(q.pending) : 0;
    {
      if (state.ingesting && state.ingesting.note) processor += ' · <span class="muted">' + esc(state.ingesting.note) + '</span>';
      else if (lockHeld) processor += ' · <span class="muted">Indexing now' + (lock.owner_pid ? ' (pid ' + esc(lock.owner_pid) + ')' : '') + '</span>';
      else if (src.owner_state === 'owner' && pendingN > 0) {
        var sizes = [5, 10, 25, 50].filter(function (n) { return n < pendingN; });
        var options = sizes.map(function (n) { return '<option value="' + n + '"' + (n === state.ingestLimit ? ' selected' : '') + '>the next ' + n + '</option>'; }).join('');
        if (pendingN <= 50) options += '<option value="' + pendingN + '"' + (sizes.indexOf(state.ingestLimit) === -1 ? ' selected' : '') + '>all ' + fmt(pendingN) + '</option>';
        processor += ' <span class="ingest-control"><label class="sr-only" for="ingestLimit">How many queued meetings to index</label><select id="ingestLimit">' + options + '</select><button class="quiet" onclick="cosApp.startIngest()">Index now</button></span>';
      }
    }
    var queued = (q.pending != null ? fmt(q.pending) + ' pending' : 'unknown') + (q.oldest_pending_at ? ' · oldest ' + esc(dateOnly(q.oldest_pending_at)) : '') + (q.missing_sources != null ? ' · ' + fmt(q.missing_sources) + ' missing sources' : '') + (q.conflict_copies != null ? ' · ' + fmt(q.conflict_copies) + ' conflict copies' : '');
    var indexed = (g.entities != null ? fmt(g.entities) + ' entities' : 'no graph') + (g.relationships != null ? ' · ' + fmt(g.relationships) + ' relationships' : '') + (g.source_updated_at ? ' · graph updated ' + esc(stamp(g.source_updated_at)) : '');
    var invites = g.index_state === 'missing' || g.index_state === 'stale';
    var build = state.building ? ' <span class="muted">' + esc(state.building) + '</span>' : (invites ? ' <button class="quiet" onclick="cosApp.buildIndex()">Build index (usually a few seconds)</button>' : '');
    var captured = s.meetingLibraryCount != null ? fmt(s.meetingLibraryCount) + ' meetings in the library' : 'unknown';
    var visible = state.graphController && state.graphVisible != null ? fmt(state.graphVisible) + ' entities in this view' : (state.knowledgeTab === 'graph' ? 'loading the neighborhood' : 'open the graph to load a neighborhood');
    return '<section class="source-card sync-card"><div class="row spread"><h3>Sync</h3></div>' +
      '<p class="owner">' + owner + '</p>' +
      '<dl class="sync-grid"><dt>Captured</dt><dd>' + esc(captured) + '</dd><dt>Queued</dt><dd>' + queued + '</dd><dt>Indexing</dt><dd>' + processor + '</dd><dt>Indexed</dt><dd>' + indexed + '</dd><dt>Visible</dt><dd>' + esc(visible) + '</dd><dt>Index</dt><dd>' + esc(g.index_state || 'unknown') + (g.index_built_at ? ' · built ' + esc(stamp(g.index_built_at)) : '') + (g.index_degraded ? ' · degraded' : '') + build + '</dd><dt>Budget</dt><dd>' + (b.used != null && b.cap != null ? fmt(b.used) + ' of ' + fmt(b.cap) + ' calls today' : 'unknown') + ' · lock ' + esc(lock.state || 'unknown') + (lock.owner_pid ? ' (pid ' + esc(lock.owner_pid) + ', advisory)' : '') + '</dd></dl>' +
      progressBlock() + '<p class="small">' + 'Values from this Mac.' + ' Changes you make in the graph appear as receipts under it once curation ships.</p></section>';
  }
  // ── Set up Knowledge (server 6.44.9): seven steps, each a live check with its own control ──
  function loadSetup() {
    state.setupLoading = true; state.setupError = null; if (state.view === 'knowledge') render();
    return call('graph.setup').then(function (d) { state.setup = d; state.setupLoading = false; render(); }, function (e) { state.setupError = e.message; state.setupLoading = false; render(); });
  }
  function setupAction(name, op, args, onDone) {
    state.setupBusy = name; state.armed = null; render();
    return call(op, args).then(function (d) { state.setupBusy = null; if (onDone) onDone(d); return loadSetup(); }, function (e) { state.setupBusy = null; toast(e.message); render(); });
  }
  function setupStep(n, done, title, body, cls) {
    return '<div class="setup-step ' + (done ? 'done' : (cls || 'todo')) + '"><div class="setup-mark">' + (done ? '✓' : n) + '</div><div class="setup-body"><h4>' + title + '</h4>' + body + '</div></div>';
  }
  function shortPath(p) { return String(p || '').replace(/^\/Users\/[^/]+/, '~'); }
  function attr(v) { return JSON.stringify(String(v)).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;'); }
  // The two pickers of step 4. A card is a radio: choosing posts the op and refreshes the checklist.
  function extractionCards(ext, busy) {
    var tiers = ext.tiers || [];
    if (!tiers.length) return '<p class="muted">Indexing tiers need server 6.44.11.</p>';
    return '<div class="pick-grid">' + tiers.map(function (tr) {
      return '<label class="pick-card ' + (tr.selected ? 'on' : '') + '"><input type="radio" name="extractionTier" ' + (tr.selected ? 'checked' : '') + (busy ? ' disabled' : '') + ' onchange="cosApp.chooseExtraction(' + attr(tr.id) + ')"><div><b>' + esc(tr.label) + '</b><p>' + esc(tr.detail) + '</p></div></label>';
    }).join('') + '</div>';
  }
  // The down-select (0.5.200, server 6.44.12). One question the user answers, may
  // text leave this Mac; one fact detected, an OpenAI key; Ollama running picks
  // premium over light. The answer moves the Recommended mark, never the choice.
  function localOnlyStrip(emb, busy) {
    if (!emb.preference) return '<p class="muted">The recommendation needs server 6.44.12.</p>';
    var v = emb.preference.local_only, rec = emb.recommended || null;
    function btn(value, text) { return '<button class="quiet' + (v === value ? ' on' : '') + '" ' + (busy ? 'disabled' : '') + ' onclick="cosApp.answerLocalOnly(' + value + ')">' + text + '</button>'; }
    return '<div class="setup-row ask-strip"><span>May your text leave this Mac for embeddings?</span>' + btn(false, 'Cloud is fine') + btn(true, 'Stays on this Mac') + '</div>' +
      (rec ? '<p class="pick-note"><b>Recommended: ' + esc(rec.label) + '.</b> ' + esc(rec.reason) + '</p>' : '');
  }
  function embeddingCards(emb, busy) {
    var rows = emb.providers || [];
    if (!rows.length) return '<p class="muted">Embedding choices need server 6.44.11.</p>';
    var fetch = emb.fetch || null;
    var recId = emb.recommended ? emb.recommended.id : null;
    var cards = rows.map(function (r) {
      var canPick = !emb.locked || r.selected;
      var fetching = fetch && fetch.state === 'running' && fetch.provider === r.id;
      var fetchFailed = fetch && fetch.state === 'failed' && fetch.provider === r.id;
      var offline = r.id === 'ollama' && /not running/.test(r.detail || '');
      var fetchBtn = r.kind === 'local' && !r.ready && !offline ? '<button class="quiet" ' + (busy || fetching ? 'disabled' : '') + ' onclick="cosApp.fetchEmbedding(' + attr(r.id) + ')">' + (fetching ? 'Fetching…' : 'Fetch model') + '</button>' : '';
      var badge = r.id === recId ? '<span class="pick-badge">Recommended</span>' : '';
      var fixLine = r.selected && !r.ready && r.fix ? '<p class="bad">' + esc(r.fix) + '</p>' : '';
      return '<label class="pick-card ' + (r.selected ? 'on' : '') + (canPick ? '' : ' off') + (r.id === recId ? ' rec' : '') + '"><input type="radio" name="embeddingProvider" ' + (r.selected ? 'checked' : '') + (canPick && !busy ? '' : ' disabled') + ' onchange="cosApp.chooseEmbedding(' + attr(r.id) + ')"><div><b>' + esc(r.label) + '</b> <span class="muted">' + esc(r.model) + (r.dimensions != null ? ' · ' + fmt(r.dimensions) + ' dims' : '') + '</span>' + badge + '<p>' + esc(r.cost) + '</p><p class="' + (r.ready ? 'ok' : '') + '">' + (r.ready ? '✓ ' : '') + esc(r.detail) + '</p>' + fixLine + (fetching ? '<p class="muted">Fetching ' + esc(fetch.model) + '… this page refreshes as it runs.</p>' : fetchFailed ? '<p class="bad">Fetch failed: ' + esc(fetch.error || 'unknown') + '</p>' : '') + fetchBtn + '</div></label>';
    }).join('');
    var note = '';
    if (emb.mismatch && emb.manifest) note = '<p class="pick-note bad">This graph was built with ' + esc(emb.manifest.provider) + ' (' + esc(emb.manifest.model) + ', ' + fmt(emb.manifest.dimensions) + ' dims) but ' + esc(emb.provider) + ' is chosen. Choose the one it was built with; Index now is blocked until then.</p>';
    else if (emb.locked) note = '<p class="pick-note">This graph was built with ' + esc(emb.label || emb.provider) + '. Changing the embedding means rebuilding the graph, and that path is not built yet.</p>';
    else if (emb.ready === false) note = '<p class="pick-note bad">' + esc(emb.label || emb.provider) + ' is chosen but not ready on this Mac. ' + esc(emb.fix || '') + ' Indexing is blocked until then.</p>';
    return '<div class="pick-grid">' + cards + '</div>' + note;
  }
  function watchFetch() {
    if (state.fetchWatch) return;
    var ticks = 0;
    state.fetchWatch = setInterval(function () {
      ticks++;
      loadSetup().then(function () {
        var f = state.setup && state.setup.embedding && state.setup.embedding.fetch;
        if (!f || f.state !== 'running' || ticks > 360) { clearInterval(state.fetchWatch); state.fetchWatch = null; if (f && f.state === 'done') toast('Model fetched.'); else if (f && f.state === 'failed') toast('Fetch failed: ' + (f.error || 'unknown')); }
      });
    }, 10000);
  }
  function setupDetail() {
    var s = state.setup;
    if (state.setupError) return '<section class="source-card setup-card"><h3>Set up Knowledge</h3><p class="owner">' + esc(state.setupError) + '</p><div class="actions"><button onclick="cosApp.setupRefresh()">Retry</button></div></section>';
    if (!s) return '<section class="source-card setup-card"><h3>Set up Knowledge</h3><p class="owner">Checking this Mac…</p></section>';
    var checks = s.checks || [], checksOk = checks.length > 0 && checks.every(function (c) { return c.ok; });
    var sources = s.sources || [], enabledWithFiles = sources.filter(function (r) { return r.enabled && r.exists && (r.files || 0) > 0; });
    var owner = s.owner || {}, isOwner = owner.is_owner === true, budget = s.budget || {}, sample = s.sample || {}, cands = sample.candidates || [];
    var graphN = (s.graph || {}).entities, hasGraph = graphN != null && graphN > 0, schedule = s.schedule || {}, lk = s.lock || {};
    var lockHeld = lk.state === 'exclusive' || lk.state === 'shared';
    var busy = state.setupBusy;
    var steps = [];
    steps.push(setupStep(1, checksOk, 'Enable Knowledge',
      '<p>What indexing needs on this Mac.</p>' + checks.map(function (c) { return '<div class="setup-source"><span class="' + (c.ok ? 'ok' : 'bad') + '">' + (c.ok ? '✓' : '!') + '</span><span>' + esc(c.detail) + '</span></div>'; }).join(''),
      checks.length && !checksOk ? 'blocked' : 'todo'));
    var sourceRows = sources.map(function (r) {
      return '<div class="setup-source"><code>' + esc(shortPath(r.path)) + '</code><span class="muted">' + (r.exists ? (r.files != null ? fmt(r.files) + ' document' + (r.files === 1 ? '' : 's') : '') : 'missing') + '</span>' +
        '<button class="quiet" ' + (busy ? 'disabled' : '') + ' onclick="cosApp.sourceToggle(' + attr(r.path) + ', ' + (!r.enabled) + ')">' + (r.enabled ? 'On' : 'Off') + '</button>' +
        '<button class="quiet" ' + (busy ? 'disabled' : '') + ' onclick="cosApp.sourceRemove(' + attr(r.path) + ')" aria-label="Remove this folder">×</button></div>';
    }).join('');
    steps.push(setupStep(2, enabledWithFiles.length > 0, 'Choose sources',
      '<p>Folders of notes or documents (Markdown and text). Only files in these folders are read.</p>' + sourceRows +
      '<div class="setup-row"><button ' + (busy ? 'disabled' : '') + ' onclick="cosApp.pickFolder()">' + (busy === 'add' ? 'Adding…' : 'Add a folder…') + '</button>' + (sources.length && !enabledWithFiles.length ? '<span class="muted">No documents found in the folders that are on.</span>' : '') + '</div>'));
    var ownerBody = isOwner ? '<p>This Mac (' + esc(hostLabel(owner.this_host)) + ') indexes the queue. Its graph, queue and sources stay here.</p>'
      : owner.owner_host ? '<p><b>' + esc(hostLabel(owner.owner_host)) + '</b> indexes the queue; this Mac reads a replica. Make this Mac the owner only if that Mac stops indexing.</p>'
      : '<p>No Mac is set to index yet.</p>';
    if (!isOwner) ownerBody += '<div class="setup-row"><button ' + (busy ? 'disabled' : '') + ' onclick="cosApp.claimOwner()">' + (state.armed === 'owner' ? 'Click again to make this Mac the owner' : busy === 'owner' ? 'Setting…' : 'Make this Mac the owner') + '</button></div>';
    steps.push(setupStep(3, isOwner, 'Owner Mac', ownerBody));
    var budgetOk = budget.used != null && budget.cap != null && budget.used < budget.cap;
    var embBlock = s.embedding || {}, extBlock = s.extraction || {};
    var localEmb = embBlock.kind === 'local';
    var embNotReady = embBlock.ready === false;
    steps.push(setupStep(4, checksOk && budgetOk && !embBlock.mismatch && !embNotReady, 'Choose how it indexes',
      '<p>Indexing tier for entity extraction. Under a Claude subscription the cost is time and the daily budget, not dollars. Takes effect on the next run.</p>' + extractionCards(extBlock, busy) +
      '<p style="margin-top:12px">Embeddings for search, one choice for the knowledge graph and every meeting index. A graph keeps the embedding it was built with.</p>' + localOnlyStrip(embBlock, busy) + embeddingCards(embBlock, busy) +
      '<div class="setup-source" style="margin-top:10px"><span>Budget today: ' + (budget.used != null ? fmt(budget.used) + ' of ' + fmt(budget.cap) + ' calls' : 'unknown') + (budgetOk ? '' : ' (used up until tomorrow)') + '</span></div>' +
      '<p>What leaves this Mac: each document\'s text goes to the model backend for entity extraction' + (localEmb ? '; embeddings are computed on this Mac' : ' and to OpenAI for embeddings') + '. The graph, the queue and this list of folders never leave it.</p>',
      embBlock.mismatch || embNotReady ? 'blocked' : 'todo'));
    var sampleDone = (sample.indexed || 0) >= 1 || hasGraph;
    var sampleBody = sampleDone ? '<p>' + ((sample.indexed || 0) >= 1 ? fmt(sample.indexed) + ' sample document' + (sample.indexed === 1 ? '' : 's') + ' indexed.' : 'Your graph already holds ' + fmt(graphN) + ' entities.') + '</p>' : '<p>The three newest documents from the folders that are on, through the same checks a meeting gets, in one bounded run.</p>';
    if (cands.length) sampleBody += cands.map(function (c) { return '<div class="setup-source"><code>' + esc(String(c.path).split('/').pop()) + '</code><span class="muted">' + (c.bytes != null ? fmt(Math.max(1, Math.round(c.bytes / 1024))) + ' KB' : '') + '</span></div>'; }).join('');
    if (state.ingesting && state.ingesting.note) sampleBody += '<p class="muted">' + esc(state.ingesting.note) + '</p>';
    else if (lockHeld) sampleBody += progressBlock();
    if ((sample.queued || 0) > 0 && !lockHeld) sampleBody += '<p class="muted">' + fmt(sample.queued) + ' queued and waiting for a run.</p>';
    if (cands.length && isOwner && !lockHeld) sampleBody += '<div class="setup-row"><button ' + (busy || !checksOk || embNotReady ? 'disabled' : '') + ' onclick="cosApp.indexSample()">' + (busy === 'sample' ? 'Queueing…' : 'Index ' + (cands.length === 1 ? 'this document' : 'these ' + cands.length)) + '</button>' +
      (embNotReady ? '<span class="muted">Blocked: ' + esc(embBlock.label || embBlock.provider) + ' is not ready. ' + esc(embBlock.fix || '') + '</span>' : '') + '</div>';
    else if (cands.length && !isOwner) sampleBody += '<p class="muted">Indexing runs on the owner Mac.</p>';
    steps.push(setupStep(5, sampleDone, 'Index three sample documents', sampleBody, checksOk ? 'todo' : 'blocked'));
    var askBody = '<p>One question, answered from the graph. About a minute; two model calls under today\'s budget.</p>' +
      '<div class="setup-row"><input id="askQ" placeholder="' + (hasGraph ? 'Who do I work with most?' : 'Index something first') + '" value="' + esc(state.askQ) + '" ' + (s.ask_ready ? '' : 'disabled') + ' onkeydown="if(event.key===\'Enter\')cosApp.askGraph()"><button ' + (s.ask_ready && !state.askBusy ? '' : 'disabled') + ' onclick="cosApp.askGraph()">' + (state.askBusy ? 'Asking…' : 'Ask') + '</button></div>' +
      (state.askAnswer ? '<div class="setup-answer">' + esc(state.askAnswer.answer) + '</div><p class="muted">' + (state.askAnswer.elapsed_s != null ? Math.round(state.askAnswer.elapsed_s) + ' s, ' : '') + esc(state.askAnswer.mode || 'hybrid') + ' mode</p>' : '');
    steps.push(setupStep(6, !!state.askAnswer, 'Ask one question', askBody, s.ask_ready ? 'todo' : 'blocked'));
    var scheduleBody = schedule.installed ? '<p>On: a batch of up to 4 queued documents every ' + (schedule.interval_s ? fmt(Math.round(schedule.interval_s / 60)) + ' minutes' : 'interval') + ', logged under ~/Library/Logs/COS.</p>' : '<p>Off. Turn it on and this Mac indexes what is queued on a schedule, in bounded batches of 4, under the daily budget.</p>';
    if (isOwner) scheduleBody += schedule.installed
      ? '<div class="setup-row"><button class="quiet" ' + (busy ? 'disabled' : '') + ' onclick="cosApp.scheduleSet(false)">' + (busy === 'schedule' ? 'Working…' : 'Turn off') + '</button></div>'
      : '<div class="setup-row"><select id="scheduleInterval"><option value="900">every 15 minutes</option><option value="3600" selected>every hour</option><option value="14400">every 4 hours</option><option value="86400">once a day</option></select><button ' + (busy ? 'disabled' : '') + ' onclick="cosApp.scheduleSet(true)">' + (busy === 'schedule' ? 'Working…' : 'Turn on') + '</button></div>';
    else scheduleBody += '<p class="muted">Schedules live on the owner Mac.</p>';
    steps.push(setupStep(7, schedule.installed === true, 'Scheduled batches', scheduleBody));
    var done = [checksOk, enabledWithFiles.length > 0, isOwner, checksOk && budgetOk, sampleDone, !!state.askAnswer, schedule.installed === true].filter(Boolean).length;
    return '<section class="source-card setup-card"><div class="row spread"><h3>Set up Knowledge</h3><span class="setup-progress">' + done + ' OF 7 DONE' + (state.setupLoading ? ' · REFRESHING' : '') + '</span></div>' +
      '<p class="owner">From zero to a first index on this Mac. Each step is a live check; do them in order.</p><div class="setup-steps">' + steps.join('') + '</div>' +
      '<div class="actions"><button class="quiet" onclick="cosApp.setupRefresh()">Refresh checks</button></div></section>';
  }
  function renderKnowledge() {
    document.querySelector('#workspace').style.gridTemplateColumns = ''; document.querySelector('#inbox').classList.remove('hidden');
    document.querySelector('#inbox').innerHTML = knowledgeAside();
    document.querySelector('#detail').innerHTML = syncCard() + (state.knowledgeTab === 'graph' ? graphDetail() : state.knowledgeTab === 'setup' ? setupDetail() : knowledgeSources());
    if (state.knowledgeTab === 'graph') mountKnowledgeGraph();
    if (state.knowledgeTab === 'setup' && !state.setup && !state.setupLoading && !state.setupError) loadSetup();
  }
  function knowledgeSources() {
    var focus = state.knowledgeFocus && findEvent(state.knowledgeFocus);
    var cards = [];
    if (focus) {
      var full = state.detail[focus.event_id]; if (!full) ensureDetail(focus.event_id);
      var e = Object.assign({}, focus, full && !full._error ? full : {});
      (e.source_refs || []).forEach(function (r, i) { cards.push({ title: STORE[r.kind] || r.kind || 'Source', kind: r.kind || '', id: r.id || '', text: r.excerpt || '', note: i === 0 ? 'The record this lesson was projected from.' : '' }); });
      var term = exploreTerm(e);
      if (!state.passages[term] && !state.loading['p:' + term]) { state.loading['p:' + term] = true; call('graph.passages', { entity: term, limit: 5 }).then(function (d) { state.passages[term] = d; delete state.loading['p:' + term]; render(); }, function (er) { state.passages[term] = { _error: er.message }; delete state.loading['p:' + term]; render(); }); }
      var p = state.passages[term];
      if (p && !p._error) (p.items || []).forEach(function (it) { var s = it.source || {}; cards.push({ title: s.title || 'Passage', kind: s.status === 'resolved' ? 'Meeting excerpt' : 'Passage (' + (s.status || 'unresolved') + ')', id: it.chunk_id, text: it.excerpt, note: s.date ? s.date : '' }); });
      else if (p && p._error) cards.push({ title: 'Passages', kind: 'unavailable', id: '', text: p._error, note: '' });
    } else {
      cards = state.recent.slice(0, 8).filter(function (e) { return (e.source_refs || []).length; }).map(function (e) { var r = e.source_refs[0]; return { title: e.title, kind: STORE[r.kind] || r.kind || 'Source', id: e.event_id, text: r.excerpt || '', note: stamp(e.ts), event: e.event_id }; });
    }
    return '<div class="row spread"><span class="eyebrow">MEMORIES / KNOWLEDGE / SOURCES</span><span class="badge">' + (cards.length ? 'Real records' : 'No records') + '</span></div><h2 style="margin-top:12px">The context behind the lesson.</h2><p class="intro">Open the original evidence before reusing an interpretation.</p>' +
      (cards.length ? cards.map(function (x) { return '<article class="source-card"><div class="row spread"><h3>' + esc(x.title) + '</h3><span class="badge">' + esc(x.kind) + '</span></div>' + (x.text ? '<div class="quote">' + esc(x.text) + '</div>' : '') + (x.note ? '<p>' + esc(x.note) + '</p>' : '') + (x.event ? '<div class="actions"><button class="link" onclick="cosApp.select(\'' + esc(x.event) + '\');cosApp.setFilter(\'recent\')">Inspect learning →</button></div>' : '') + '</article>'; }).join('') : '<div class="empty"><div><h3>No source records yet.</h3><p>Your first saved lesson will bring its source here.</p></div></div>');
  }
  function graphDetail() {
    return '<div class="row spread actual-header"><h2>Knowledge graph</h2><span class="row"><span class="badge green">Your LightRAG data</span><span class="meta">focus: ' + esc(state.graphFocus) + '</span></span></div><p class="intro">' + esc(state.graphFocus) + (state.status && state.status.ownerName && state.graphFocus === state.status.ownerName ? ' (you)' : '') + ' and its strongest neighbors from your graph, read through COS Control. Click an entity to inspect it; Explore from here loads that entity\'s own neighborhood.</p><div class="graph-search row"><input type="search" id="graphQuery" placeholder="Find an entity to focus…" value="' + esc(state.graphQuery) + '" aria-label="Find an entity"><button onclick="cosApp.graphSearch()">Focus</button><span id="graphSearchStatus" class="muted"></span></div><div id="graphMount" class="cgx-host"></div>';
  }
  function nodeFromEntity(en) { return { id: en.id, group: en.type || 'unknown', descs: en.descriptions && en.descriptions.length ? en.descriptions : (en.description ? [en.description] : []), ts: en.created_at || null, totalDegree: en.degree || 0 }; }
  function neighborhood(focus) {
    return call('graph.entity', { id: focus, limit: 30 }).then(function (en) {
      if (en.found === false) throw Object.assign(new Error('No entity named ' + focus + ' in the graph.'), { status: 404 });
      var nodes = [nodeFromEntity(en)], seen = {}; seen[en.id] = 1;
      (en.neighbors || []).forEach(function (n) { if (!seen[n.id]) { seen[n.id] = 1; nodes.push({ id: n.id, group: n.type || 'unknown', descs: [], ts: null, totalDegree: n.degree || 0 }); } });
      var links = (en.edges || []).filter(function (e) { return seen[e.source] && seen[e.target]; }).map(function (e) { return { source: e.source, target: e.target, weight: e.weight || 1, desc: e.description || '' }; });
      var g = state.graphStatus || {};
      state.graphVisible = nodes.length;
      return { nodes: nodes, links: links, corpus_total_nodes: g.entities || nodes.length, corpus_total_edges: g.relationships || links.length, generated_at: g.index_built_at || null,
        description_scope: 'the ' + focus + ' neighborhood', selection_description: focus + ' and up to 30 direct neighbors, read live from this Mac\'s index' };
    });
  }
  function mountKnowledgeGraph() {
    var host = document.querySelector('#graphMount'); if (!host) return;
    if (state.graphController) { try { state.graphController.destroy(); } catch (e) {} state.graphController = null; }
    var focus = state.graphFocus;
    state.graphController = COSGraphExplorer.mount(host, {
      scope: 'actual', status: 'ready', focus: focus, endpoint: '',
      request: function (path) { if (path.indexOf('/api/graph') === 0) return neighborhood(focus); return Promise.reject(Object.assign(new Error('Not served by this host'), { status: 404 })); },
      labels: { sourceStatus: 'Descriptions are extracted summaries. Show passages reads the index behind this entity.' },
      memoriesFor: function (id) { var hits = state.graphMemories[id]; if (hits === undefined) { state.graphMemories[id] = null; call('memories.search', { q: id, limit: 5 }).then(function (d) { state.graphMemories[id] = (d.hits || []).map(function (h) { return { id: h.id, title: h.summary || h.content || h.id }; }); if (state.graphController && state.graphController.select) state.graphController.select(id); }, function () { state.graphMemories[id] = []; }); } return hits || []; },
      onOpenMemory: function (memoryId) { state.view = 'learning'; state.filter = 'memories'; state.selectedMemory = memoryId; render(); },
      onCopy: function (text, label) { call('copy', { text: text, label: label }).then(function () { toast('Copied as grounded context'); }, function (e) { toast(e.message); }); },
      onRecenter: function (id) { state.graphFocus = id; state.graphFocusChosen = true; state.graphQuery = ''; render(); },
      onPassages: function (id) { call('graph.passages', { entity: id, limit: 5 }).then(function (d) { openPassages(id, d); }, function (e) { toast(e.message); }); },
      curation: { ownerLabel: hostLabel(state.graphStatus && state.graphStatus.source && state.graphStatus.source.owner_host) || 'the owner Mac', isOwner: !!(state.graphStatus && state.graphStatus.source && state.graphStatus.source.is_owner) },
      onCuration: function () { toast('Merging, renaming and removing arrive with the curation engine in a later release. Nothing was changed.'); return false; }
    });
    // "Visible" in the Sync card counts what the neighborhood returned.
    setTimeout(function () { var dd = document.querySelector('.sync-grid'); if (dd && state.graphVisible != null) { var cells = dd.querySelectorAll('dd'); if (cells[4]) cells[4].textContent = fmt(state.graphVisible) + ' entities in this view'; } }, 1500);
  }
  state.graphMemories = {};
  function openPassages(id, d) {
    var items = d.items || [];
    modal('Passages · ' + esc(id), (d.note ? '<p>' + esc(d.note) + '</p>' : '') + (items.length ? items.map(function (it) { var s = it.source || {}; return '<div class="logrow">' + esc(s.title || 'Passage') + (s.date ? ' · ' + esc(s.date) : '') + (s.status && s.status !== 'resolved' ? ' · ' + esc(s.status) : '') + '<small>' + esc(it.excerpt) + '</small></div>'; }).join('') : '<p>No passages behind this entity in the index.</p>') + '<p class="muted">' + fmt(d.total || 0) + ' passage' + (d.total === 1 ? '' : 's') + ' in the index' + (d.fallback ? ' · read from ' + esc(d.fallback) : '') + '.</p>');
  }
  function graphSearch() {
    var q = (document.querySelector('#graphQuery') || {}).value || ''; q = q.trim(); state.graphQuery = q;
    var status = document.querySelector('#graphSearchStatus');
    if (q.length < 2) { if (status) status.textContent = 'Type at least two characters.'; return; }
    if (status) status.textContent = 'Looking up…';
    call('graph.search', { q: q, limit: 5 }).then(function (d) {
      var items = d.items || [];
      if (!items.length) { if (status) status.textContent = d.indexState === 'missing' ? 'No knowledge index on this Mac yet. Build it above.' : 'No entities match that lookup.'; return; }
      state.graphFocus = items[0].id; state.graphFocusChosen = true; if (status) status.textContent = (d.total > 1 ? fmt(d.total) + ' matches · focusing ' : 'Focusing ') + items[0].id; render();
    }, function (e) { if (status) status.textContent = e.message; });
  }
  function exploreTerm(e) { if (e.category && e.category !== e.scope && e.category !== 'unknown') return e.category; return String(e.title || '').split(' ').slice(0, 4).join(' ') || 'COS'; }
  function exploreInGraph(id) {
    var e = findEvent(id); if (!e) return;
    state.knowledgeFocus = id; state.view = 'knowledge'; state.knowledgeTab = 'graph'; state.graphQuery = exploreTerm(e); render();
    call('graph.search', { q: state.graphQuery, limit: 3 }).then(function (d) { var items = d.items || []; if (items.length) { state.graphFocus = items[0].id; state.graphFocusChosen = true; render(); } else toast('No entity in the graph matches "' + state.graphQuery + '". Showing ' + state.graphFocus + '.'); }, function (er) { toast(er.message); });
  }
  function findEvent(id) { return state.recent.concat(state.review).find(function (x) { return x.event_id === id; }); }

  // ── decisions (the one write with a backend tonight) ────────────
  state.decisions = {};
  function decide(id, decision) {
    var e = findEvent(id); if (!e) return;
    call('learning.decide', { id: e.lesson_id, decision: decision }).then(function () {
      state.decisions[e.lesson_id] = decision;
      toast(decision === 'dismissed' ? 'Proposal dismissed. The To review count updates on the next refresh.' : 'Proposal restored.');
      call('learning.review', { limit: 200 }).then(function (d) { state.review = d.events || []; state.reviewCount = d.reviewCount != null ? d.reviewCount : d.total; render(); }, function () { render(); });
    }, function (er) { toast(er.message); });
  }

  // ── copy context ────────────────────────────────────────────────
  function contextText(e, opts) {
    var full = state.detail[e.event_id]; var x = Object.assign({}, e, full && !full._error ? full : {});
    var lines = ['Learning ' + x.event_id + ' (' + kindLabel(x) + ' · ' + (x.scope || '') + ' · ' + (x.ts || '') + ')', '', '"""', x.title || ''];
    var d = x.detail || {};
    if (d.before) lines.push('Before: ' + d.before); if (d.after) lines.push('After: ' + d.after); if (d.rule) lines.push('Rule: ' + d.rule); if (d.content) lines.push(d.content); (d.bodies || []).forEach(function (b) { lines.push(b); });
    lines.push('"""');
    if (opts.sources && (x.source_refs || []).length) { lines.push('', 'Sources:'); x.source_refs.forEach(function (r) { lines.push('- ' + (r.kind || '') + ' ' + (r.id || '') + (r.excerpt ? ': ' + r.excerpt : '')); }); }
    var o = outcomeText(x); if (o) lines.push('', 'Checked: ' + o);
    if (opts.graph) lines.push('', 'Related knowledge: open the entity in Knowledge and use its Copy context for descriptions and relationships.');
    return lines.join('\n');
  }
  function openCopyContext(id) {
    state.copyId = id; var e = findEvent(id); if (!e) return;
    modal('Copy context', '<p>Preview the exact text, then copy it. Sources are included by default.</p><div class="copy-options"><label><input type="checkbox" ' + (state.copyOptions.sources ? 'checked' : '') + ' onchange="cosApp.copyOption(\'sources\',this.checked)"> Include sources</label><label><input type="checkbox" ' + (state.copyOptions.graph ? 'checked' : '') + ' onchange="cosApp.copyOption(\'graph\',this.checked)"> Include a related-knowledge note</label></div><textarea class="editor context-preview" id="contextPreview" readonly>' + esc(contextText(e, state.copyOptions)) + '</textarea><div class="actions"><button class="primary" onclick="cosApp.copyNow()">Copy</button><button onclick="cosApp.selectContextText()">Select text</button></div><p class="copy-footnote muted">Quoted and labelled with its id: the same data-not-instructions contract the glasses use when they attach a reference.</p>');
  }
  function copyOption(k, v) { state.copyOptions[k] = v; var e = findEvent(state.copyId); var ta = document.querySelector('#contextPreview'); if (e && ta) ta.value = contextText(e, state.copyOptions); }
  function copyNow() { var e = findEvent(state.copyId); if (!e) return; call('copy', { text: contextText(e, state.copyOptions), label: 'Copy context' }).then(function () { toast('Copied as grounded context'); closeModal(); }, function (er) { toast(er.message); }); }
  function selectContextText() { var ta = document.querySelector('#contextPreview'); if (ta) { ta.focus(); ta.select(); } }
  function copyMemory(id) {
    var m = (state.memoryHits || state.memories).find(function (x) { return x.id === id; }) || {}; var full = state.memoryDetail[id] || {}; var r = Object.assign({}, m, full._error ? {} : full);
    var text = 'Memory ' + id + (r.type || r.created_at ? ' (' + [r.type, dateOnly(r.created_at)].filter(Boolean).join(' · ') + ')' : '') + '\n\n"""\n' + (r.content || r.summary || '') + '\n"""';
    call('copy', { text: text, label: 'Copy memory' }).then(function () { toast('Copied as grounded context'); }, function (er) { toast(er.message); });
  }

  // ── modals ──────────────────────────────────────────────────────
  function modal(title, body) {
    if (!document.querySelector('.modal')) window.previousFocus = document.activeElement;
    document.querySelector('#modalRoot').innerHTML = '<div class="modal-backdrop" onclick="if(event.target===this)cosApp.closeModal()"><section class="modal" role="dialog" aria-modal="true" aria-label="' + esc(title) + '"><div class="row spread"><h2>' + title + '</h2><button class="quiet" aria-label="Close dialog" onclick="cosApp.closeModal()">✕</button></div>' + body + '</section></div>';
    var first = document.querySelector('.modal button'); if (first) first.focus();
  }
  function closeModal() { var existed = !!document.querySelector('.modal'); document.querySelector('#modalRoot').innerHTML = ''; if (existed && window.previousFocus && window.previousFocus.isConnected && ['BODY', 'HTML'].indexOf(window.previousFocus.tagName) < 0) window.previousFocus.focus(); }
  function openSettings() {
    var s = state.status || {};
    var tier = s.contextScriptsDirectory ? 'COS Data bridge (vector store + files)' : s.contextFilesDirectory ? 'Plain files' : 'Not configured';
    function row(title, sub, on, reason) { return '<div class="setting row spread"><div><h3>' + title + '</h3><small>' + sub + '</small></div><button class="switch ' + (on ? 'on' : '') + '" role="switch" aria-checked="' + on + '" aria-label="' + title + '" disabled title="' + esc(reason) + '"><span></span></button></div>'; }
    modal('Learning settings', '<p>Control what COS saves and how changes become active.</p>' +
      row('Learn from completed sessions', 'Capture useful lessons after a session ends.', true, 'Pause and resume arrive with the learning-settings route in a later release.') +
      row('Review skill changes first', 'Read the change before it affects future work.', true, 'Always on until skill versioning ships; nothing is applied without you.') +
      row('Review memory additions', 'Confirm new memories before they are kept.', false, 'Arrives with the learning-settings route in a later release.') +
      '<div class="setting row spread"><div><h3>Current storage source</h3><small>' + esc(tier) + (s.contextResolvedRoot ? ' · ' + esc(s.contextResolvedRoot) : '') + '</small></div></div>' +
      '<p class="muted">Changing the source is done from the menu-bar panel (COS Data); this page never migrates files or activates the bridge.</p>');
  }
  function openLog() {
    var ls = state.learningStatus || {};
    var counts = ls.counts_by_type || {};
    var rows = Object.keys(counts).sort().map(function (k) { return '<div class="logrow">' + esc(KIND[k] || k) + '<small>' + fmt(counts[k]) + ' in the window</small></div>'; }).join('');
    var stores = Object.keys(ls.stores || {}).map(function (k) { var st = ls.stores[k]; return '<div class="logrow">' + esc(STORE[k] || k) + '<small>' + (st.readable ? 'readable · ' + fmt(st.count || 0) + (st.last_ts ? ' · last ' + esc(stamp(st.last_ts)) : '') : 'not readable (' + esc(st.state || '') + ')') + '</small></div>'; }).join('');
    modal('Recent learning activity', '<p>Counts by event type in the reporting window, then every store this Mac can read.</p>' + (rows || '<p>No events counted.</p>') + '<h3 style="margin-top:14px">Stores</h3>' + stores);
  }

  // ── public surface for inline handlers ──────────────────────────
  window.cosApp = {
    select: function (id) { state.selected = id; render(); },
    selectMemory: function (id) { state.selectedMemory = id; render(); },
    setFilter: function (f) { state.view = 'learning'; state.filter = f; render(); },
    openKnowledge: function (id) { state.view = 'knowledge'; state.knowledgeTab = 'sources'; state.knowledgeFocus = id || null; render(); },
    setKnowledgeTab: function (t) { state.knowledgeTab = t; state.knowledgeTabChosen = true; render(); },
    backToLearning: function () { state.view = 'learning'; state.filter = 'recent'; if (state.knowledgeFocus) state.selected = state.knowledgeFocus; render(); },
    exploreInGraph: exploreInGraph, graphSearch: graphSearch,
    refresh: loadAll, refreshGraph: loadGraphStatus, loadMore: loadMore, memoryQuery: memoryQuery,
    setupRefresh: function () { loadSetup(); },
    chooseExtraction: function (tier) { setupAction('extraction', 'graph.setup.extraction', { tier: tier }, function (d) { toast('Indexing set to ' + ((d.extraction || {}).label || tier) + '.'); }); },
    chooseEmbedding: function (provider) { setupAction('embedding', 'graph.setup.embedding', { provider: provider }, function (d) { toast('Embeddings set to ' + ((d.embedding || {}).label || provider) + '.'); }); },
    answerLocalOnly: function (localOnly) { setupAction('preference', 'graph.setup.embedding', { local_only: localOnly === true }, function (d) { var rec = (d.embedding || {}).recommended; toast(rec ? 'Recommended: ' + rec.label + '.' : 'Preference saved.'); }); },
    fetchEmbedding: function (provider) { setupAction('fetch', 'graph.setup.embedding', { provider: provider, fetch: true }, function (d) { var f = d.fetch || {}; toast(f.started ? 'Fetching the model in the background.' : f.already_running ? 'A fetch is already running.' : 'Nothing to fetch.'); watchFetch(); }); },
    pickFolder: function () {
      call('pick.folder').then(function (d) {
        if (!d || !d.path) return;
        setupAction('add', 'graph.setup.sources', { action: 'add', path: d.path }, function () { toast('Folder added.'); });
      }, function (e) { if (e.message !== 'No folder chosen.') toast(e.message); });
    },
    sourceToggle: function (path, enabled) { setupAction('toggle', 'graph.setup.sources', { action: enabled ? 'enable' : 'disable', path: path }); },
    sourceRemove: function (path) { setupAction('remove', 'graph.setup.sources', { action: 'remove', path: path }, function () { toast('Folder removed.'); }); },
    claimOwner: function () {
      if (state.armed !== 'owner') { state.armed = 'owner'; render(); setTimeout(function () { if (state.armed === 'owner') { state.armed = null; render(); } }, 6000); return; }
      setupAction('owner', 'graph.setup.owner', {}, function () { toast('This Mac is now the ingestion owner.'); });
    },
    indexSample: function () {
      setupAction('sample', 'graph.sample', { limit: 3 }, function (d) {
        var q = (d.queued || []).length;
        if (d.started) { state.ingesting = { pid: d.pid, note: 'Indexing ' + fmt(q) + ' sample document' + (q === 1 ? '' : 's') + ' (pid ' + esc(d.pid) + ')' }; watchIngest(); }
        else if (d.already_running) { toast((q ? fmt(q) + ' queued. ' : '') + 'Indexing is already running; this page refreshes as it runs.'); watchIngest(); }
        else if (d.nothing_pending) toast('Nothing new to index in the folders that are on.');
        else if (d.budget_exhausted) toast('Today\'s LightRAG budget is used up. It resets tomorrow.');
        if ((d.skipped || []).length) toast(fmt(d.skipped.length) + ' skipped: ' + d.skipped.map(function (x) { return x.reason; }).join(', '));
      });
    },
    askGraph: function () {
      var input = document.querySelector('#askQ'); var q = input ? input.value.trim() : state.askQ;
      if (q.length < 3) { toast('Ask a fuller question.'); return; }
      state.askQ = q; state.askBusy = true; state.askAnswer = null; render();
      call('graph.ask', { q: q }).then(function (d) { state.askBusy = false; state.askAnswer = d; render(); }, function (e) { state.askBusy = false; toast(e.message); render(); });
    },
    scheduleSet: function (enabled) {
      var sel = document.querySelector('#scheduleInterval'); var interval = sel ? Number(sel.value) || 3600 : 3600;
      setupAction('schedule', 'graph.schedule', { enabled: enabled, intervalS: interval }, function (d) { toast(d.installed ? 'Scheduled batches on.' : 'Scheduled batches off.'); });
    },
    startIngest: function () {
      var sel = document.querySelector('#ingestLimit'); var limit = sel ? (Number(sel.value) || 10) : 10; state.ingestLimit = limit;
      state.ingesting = { note: 'Starting…' }; render();
      call('graph.ingest', { limit: limit }).then(function (d) {
        if (d.started) { var batch = Math.min(d.limit || 0, d.pending || 0); state.ingesting = { pid: d.pid, limit: d.limit, startedAt: Date.now(), note: (d.pending <= batch ? 'Indexing all ' + fmt(d.pending) + ' queued' : 'Indexing the next ' + fmt(batch) + ' of ' + fmt(d.pending) + ' queued') + ' (pid ' + esc(d.pid) + ')' }; watchIngest(); }
        else if (d.already_running) { state.ingesting = null; toast('Indexing is already running' + (d.lock && d.lock.owner_pid ? ' (pid ' + d.lock.owner_pid + ')' : '') + '. This card refreshes as it runs.'); watchIngest(); }
        else if (d.nothing_pending) { state.ingesting = null; toast('Nothing is queued.'); }
        else if (d.budget_exhausted) { state.ingesting = null; toast('Today\'s LightRAG budget is used up' + (d.budget ? ' (' + fmt(d.budget.used) + ' of ' + fmt(d.budget.cap) + ' calls)' : '') + '. It resets tomorrow.'); }
        else { state.ingesting = null; toast('Nothing started.'); }
        render();
      }, function (e) { state.ingesting = null; toast(e.message); render(); });
    },
    buildIndex: function () { state.building = 'Starting…'; render(); call('graph.build').then(function (d) { state.building = d.already_running ? 'A build is already running' : 'Building…'; render(); var tries = 0; var poll = setInterval(function () { tries++; loadGraphStatus().then(function () { var b = state.graphStatus && state.graphStatus.build; if (b && (b.state === 'done' || b.state === 'failed')) { state.building = b.state === 'done' ? 'Index rebuilt' : ('Build failed: ' + (b.error || '')); clearInterval(poll); render(); } else if (tries > 150) { state.building = 'Still building after 5 minutes. Refresh later.'; clearInterval(poll); render(); } }); }, 2000); }, function (e) { state.building = null; toast(e.message); render(); }); },
    decide: decide, openMemoryRecord: function (id) { state.view = 'learning'; state.filter = 'memories'; state.selectedMemory = id; state.memoryQuery = ''; state.memoryHits = null; if (!state.memories.some(function (m) { return m.id === id; })) state.memories.unshift({ id: id, summary: 'Memory ' + id }); render(); },
    reveal: function (id) { call('memory.reveal', { id: id }).then(function () {}, function (e) { toast(e.message); }); },
    copyMemory: copyMemory, openCopyContext: openCopyContext, copyOption: copyOption, copyNow: copyNow, selectContextText: selectContextText,
    closeModal: closeModal, openSettings: openSettings, openLog: openLog
  };
  window.openSettings = openSettings;
  document.addEventListener('keydown', function (ev) { if (ev.key === 'Escape' && document.querySelector('.modal')) closeModal(); });

  render();
  loadAll();
})();
