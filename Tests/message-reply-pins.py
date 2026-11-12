#!/usr/bin/env python3
"""Reply in the message reader (D4; Miles 2026-11-11 13:59): the wiring pins."""
import sys
root = sys.argv[1]
def read(p): return open(f"{root}/{p}").read()
win, view, models, drop = read("Sources/ActivityWindow.swift"), read("Sources/MessageReplyView.swift"), read("Sources/Models.swift"), read("Sources/DropIt.swift")
handoff, helper, control = read("Sources/WorkHandoffStore.swift"), read("HelperSources/main.swift"), read("Sources/ControllerModel.swift")
fails = []
def need(cond, label):
    if not cond: fails.append(label)
def body(text, start, end):
    i = text.find(start); j = text.find(end, i + 1) if i >= 0 else -1
    return text[i:j] if i >= 0 and j > i else ""

detail = body(win, "    private func messageDetail(_ turn: GlassesTurn) -> some View {", "\n    /// Offered on its own when the keyword answer")
# Anand parity (lead 2026-11-12, as the web's reader): the Reply card is pinned under the scroll; this Mac's replies read in the
# scroll under the answer.
mount = 'MessageReplyBlock(store: model.messageReply, handoff: handoffStore, turn: turn, onAppear: wireMessageReply, part: .composer)\n            .id("reply:" + turn.id)'
replies_mount = 'MessageReplyBlock(store: model.messageReply, handoff: handoffStore, turn: turn, part: .replies)\n                    .id("replies:" + turn.id)'
need(win.count("MessageReplyBlock(") == 2 and mount in detail and detail.count("onAppear: wireMessageReply") == 1,
     "[reader] Reply mounts once, in the single-message reader, one block per turn")
scroll_end = detail.find("\n        }\n        Divider()\n")
need(detail.startswith("    private func messageDetail(_ turn: GlassesTurn) -> some View {") and "        VStack(spacing: 0) {\n        ScrollView {" in detail
     and scroll_end > 0 and detail.find(mount) > scroll_end, "[reader] the Reply card is pinned under the scroll, outside it")
need(replies_mount in detail and 0 < detail.find('fallback: "From COS")') < detail.find(replies_mount) < scroll_end,
     "[reader] this Mac's replies read under the answer and its files, in the scroll")
need("if part == .replies { repliesList } else { block }" in view and "if part == .all, !replies.isEmpty {" in view
     and "guard part != .replies else { return }" in view, "[reader] the pinned card holds the box, the scroll holds the replies")
chat = body(win, "@ViewBuilder private func archiveChatDetail(", "\n    private func ")
need("MessageReplyBlock" not in chat and 'Button("Copy turn") { model.copyArchiveMessage(message) }' in chat,
     "[archive] the day chat keeps Copy turn only (the web's archive day has no Reply)")
for banned in (".sheet(", ".popover(", ".confirmationDialog(", ".alert(", "NSAlert"):
    need(banned not in view, "[inline] the reply block opens no sheet, popover or alert: " + banned)
need("lazy var messageReply: DropItStore = {" in control and '"cos-message-reply-attachments"' in control,
     "[store] replies have their own store and staging folder, so the COS chat's composer and files are never touched")
wire = body(win, "    func wireMessageReply() {", "\n    }\n")
need("model.messageReply.askJob = messageReplyAskJob" in wire and "model.messageReply.askState = dropItAskState" in wire and "model.dropIt." not in wire,
     "[wiring] the reply store gets its own run; the chat's wiring is not changed")
job = body(win, "    var messageReplyAskJob:", "\n    /// The reply store's run")
need("threadSessionID: session, modelID: model, effort: effort" in job and "MessageReply.modelKey" in job and "MessageReply.effortKey" in job
     and "let model = MessageReply.model(picked:" in job,
     "[run] a reply runs the Today Work run with the turn's session and the picked model and effort")
run = body(win, "    func startRun(target: String", "\n    static let startedNote")
need("let picked = modelID.flatMap { id in handoff.models.firstIndex { $0.id == id && $0.available } }" in run
     and "guard let index = modelID == nil ? TodayHome.pickRunModel(handoff.models.map { ($0.id, $0.provider, $0.available) }) : picked else {" in run
     and "runNote = modelID == nil ? \"No model is available for a Work run. Open Work to start one.\" : MessageReply.modelGoneLine" in run,
     "[run] a picked model only while Work can run it, never a substitute; a run COS starts by itself keeps pickRunModel")
need("MessageReply.effortOffered(e, provider: handoff.models[index].provider, efforts: handoff.efforts) ? e : nil" in run and "effort: sentEffort)" in run,
     "[run] an effort only one the server served for that model's agent")
need("if mode == .newSession, let effort { job[\"effort\"] = effort }" in handoff and "efforts = (try? JSONDecoder().decode([String: [WorkEffortChoice]].self" in handoff,
     "[handoff] the effort rides only a new Work run; the served efforts are read with the models")
reply = body(drop, "    func reply(_ text: String, to turnID: String, session: String?) async -> Bool {", "\n    /// Reads back the runs")
need("var start = await askJob(MessageReply.target(turnID: turnID, replyID: replyID), words, ids, session, nil)" in reply
     and "if case .refused = start, session != nil {" in reply and "made.replyTo = turnID" in reply and "threadOn()" not in reply,
     "[store] a reply continues the turn's session, retries fresh once, is tagged to its turn and never uses the COS thread")
need("    func ask(_ text: String, files separateFiles: [DropIt.Attachment]? = nil) async -> Bool {" in drop, "[chat] the COS chat's Ask is unchanged")
need("if !efforts.isEmpty {" in view and 'COSDropdown("Effort", selection: $pickedEffort,' in view, "[effort] Effort shows only when the server serves efforts for the model's agent")
need('COSDropdown("Model", selection:' in view and "let menu = MessageReply.menu(handoff.models.map { ($0.id, $0.available, $0.resolvedModel) })" in view
     and "options: menu.map { COSDropdownOption($0.id, $0.label) })" in view and "MessageReply.available(handoff.models.map" in view, "[shown] Model always, the block only where Work has a model")
need('static let footReturn = "Return asks. Shift-Return starts a new line."' in view and "MeetingAskComposer(text: $draft, placeholder: label" in view
     and "Text(MessageReply.subline(sessionId: turn.sessionId))" in view and "Text(MessageReply.title)" in view,
     "[words] the web's words: Reply, the session line, Reply to Message #N, the Return hint")
need("store.reply(words, to: turn.id, session: MessageReply.session(turn.sessionId))" in view, "[send] Ask sends the reply with the turn's session when the helper would take it")
need("static let workEffortValues = [\"high\", \"xhigh\", \"max\", \"ultracode\"]" in helper and "guard let effort = Self.workEffort(body[\"effort\"])" in helper
     and "if !catalog.efforts.isEmpty { details[\"efforts\"] = catalog.efforts }" in helper and "Work effort contract self-test failed" in helper,
     "[helper] work-new takes only the server's effort values; work-models passes the efforts through, cleaned; both self-tested")
# Parity with Control Web's menu (Miles 2026-11-11 20:31): the server's cos-chat.js CLAUDE_MENU, ENGINE and FALLBACK, read from the
# server checkout ($COS_SERVER_ROOT, else a sibling or ~/Documents/GitHub cos-glasses-server), must be exactly MessageReply's lists.
# Missing: a failure.
import os, re as _re
candidates = [os.environ.get("COS_SERVER_ROOT") or "", os.path.join(os.path.dirname(os.path.abspath(root)), "cos-glasses-server"),
              os.path.expanduser("~/Documents/GitHub/cos-glasses-server")]
web_path = next((os.path.join(c, "server/web-control/panes/cos-chat.js") for c in candidates
                 if c and os.path.exists(os.path.join(c, "server/web-control/panes/cos-chat.js"))),
                os.path.join(candidates[1], "server/web-control/panes/cos-chat.js"))
if not os.path.exists(web_path):
    need(False, "[parity] the server's cos-chat.js was not found at " + web_path + " (set COS_SERVER_ROOT)")
else:
    web = open(web_path).read()
    def js_pairs(name):
        m = _re.search(r"var " + name + r" = \[(.*?)\];", web, _re.S)
        return _re.findall(r"\['([^']*)', '([^']*)'\]", m.group(1)) if m else None
    def js_map(name):
        m = _re.search(r"var " + name + r" = \{(.*?)\};", web, _re.S)
        return dict(_re.findall(r"'?([A-Za-z0-9-]+)'?: '([^']*)'", m.group(1))) if m else None
    mac_claude = _re.findall(r'\("([a-z]+)", "(Claude [A-Za-z]+)"\)', body(models, "static let claudeMenu:", "\n"))
    mac_engines = _re.findall(r'\("([a-z-]+)", "([A-Za-z]+)", "([A-Za-z]*)"\)', body(models, "static let engines:", "\n    ]"))
    need(js_pairs("CLAUDE_MENU") is not None and list(map(tuple, js_pairs("CLAUDE_MENU"))) == mac_claude,
         "[parity] the Claude tiers, their order and names are the web's CLAUDE_MENU")
    engine, fallback = js_map("ENGINE"), js_map("FALLBACK")
    need(engine is not None and fallback is not None and sorted(engine) == sorted(e[0] for e in mac_engines)
         and all(engine[e[0]] == e[1] and fallback.get(e[0], "") == e[2] for e in mac_engines),
         "[parity] the engines, their names and fallback words are the web's ENGINE and FALLBACK")
    need("seen = { opus: 1, fable: 1, sonnet: 1 }" in web and "haiku" not in body(web, "function modelsFrom(m) {", "\n  }\n"),
         "[parity] the web's menu still lists no Haiku")
    need('defaultModel = "sonnet"' in models.replace("static let ", ""), "[parity] Sonnet is the default until a pick")
copy = [s for s in (view + body(models, "enum MessageReply {", "\n}\n")).split('"') if s.strip()]
need(not any("Miles" in s or "—" in s or "→" in s for s in copy), "[copy] no name, em dash or arrow")
if fails:
    for f in fails: print("FAIL:", f, file=sys.stderr)
    sys.exit(1)
print("message reply pins: %d passed" % sum(1 for l in open(__file__).read().splitlines() if l.startswith("need(")))
