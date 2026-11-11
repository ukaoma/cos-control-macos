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
mount = 'MessageReplyBlock(store: model.messageReply, handoff: handoffStore, turn: turn, onAppear: wireMessageReply)\n                    .id("reply:" + turn.id)'
need(win.count("MessageReplyBlock(") == 1 and mount in detail, "[reader] Reply mounts once, in the single-message reader, one block per turn")
need(detail.find('fallback: "From COS")') < detail.find("MessageReplyBlock("), "[reader] under the answer and its files, as on the web")
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
need("threadSessionID: session, modelID: model, effort: effort" in job and "MessageReply.modelKey" in job and "MessageReply.effortKey" in job,
     "[run] a reply runs the Today Work run with the turn's session and the picked model and effort")
run = body(win, "    func startRun(target: String", "\n    static let startedNote")
need("guard let index = modelID == nil ? TodayHome.pickRunModel(choices) : MessageReply.modelIndex(picked: modelID, models: choices) else {" in run
     and "MessageReply.effortOffered(e, provider: handoff.models[index].provider, efforts: handoff.efforts) ? e : nil" in run
     and "effort: sentEffort)" in run, "[run] a chosen model only while a Today run may use it; an effort only one the server served for that model's agent")
need("if mode == .newSession, let effort { job[\"effort\"] = effort }" in handoff and "efforts = (try? JSONDecoder().decode([String: [WorkEffortChoice]].self" in handoff,
     "[handoff] the effort rides only a new Work run; the served efforts are read with the models")
reply = body(drop, "    func reply(_ text: String, to turnID: String, session: String?) async -> Bool {", "\n    /// Reads back the runs")
need("var start = await askJob(MessageReply.target(turnID: turnID, replyID: replyID), words, ids, session, nil)" in reply
     and "if case .refused = start, session != nil {" in reply and "made.replyTo = turnID" in reply and "threadOn()" not in reply,
     "[store] a reply continues the turn's session, retries fresh once, is tagged to its turn and never uses the COS thread")
need("    func ask(_ text: String, files separateFiles: [DropIt.Attachment]? = nil) async -> Bool {" in drop, "[chat] the COS chat's Ask is unchanged")
need("if !efforts.isEmpty {" in view and 'COSDropdown("Effort", selection: $pickedEffort,' in view, "[effort] Effort shows only when the server serves efforts for the model's agent")
need('COSDropdown("Model", selection:' in view and "let models = MessageReply.offered(" in view and "MessageReply.available(handoff.models.map" in view, "[shown] Model always, the block only where Work has a model")
need('static let footReturn = "Return asks. Shift-Return starts a new line."' in view and "MeetingAskComposer(text: $draft, placeholder: label" in view
     and "Text(MessageReply.subline(sessionId: turn.sessionId))" in view and "Text(MessageReply.title)" in view,
     "[words] the web's words: Reply, the session line, Reply to Message #N, the Return hint")
need("store.reply(words, to: turn.id, session: MessageReply.session(turn.sessionId))" in view, "[send] Ask sends the reply with the turn's session when the helper would take it")
need("static let workEffortValues = [\"high\", \"xhigh\", \"max\", \"ultracode\"]" in helper and "guard let effort = Self.workEffort(body[\"effort\"])" in helper
     and "if !catalog.efforts.isEmpty { details[\"efforts\"] = catalog.efforts }" in helper and "Work effort contract self-test failed" in helper,
     "[helper] work-new takes only the server's effort values; work-models passes the efforts through, cleaned; both self-tested")
copy = [s for s in (view + body(models, "enum MessageReply {", "\n}\n")).split('"') if s.strip()]
need(not any("Miles" in s or "—" in s or "→" in s for s in copy), "[copy] no name, em dash or arrow")
if fails:
    for f in fails: print("FAIL:", f, file=sys.stderr)
    sys.exit(1)
print("message reply pins: %d passed" % sum(1 for l in open(__file__).read().splitlines() if l.startswith("need(")))
