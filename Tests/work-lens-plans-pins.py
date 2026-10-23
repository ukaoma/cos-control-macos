#!/usr/bin/env python3
"""0.5.333 lens plans wiring pins: what the execution checks cannot reach (the helper's HTTP side, the app start, the view,
the compile lists). Each pin names the behaviour it protects. Behaviour itself is executed in WorkLensPlansChecks (pure)
and WorkLensPlansStoreChecks (the real stores and pump against a fake transport)."""
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
read = lambda p: (root / p).read_text()
chat, helper, pump, model, lens = read("Sources/WorkTaskChat.swift"), read("HelperSources/main.swift"), read("Sources/WorkLensPlansPump.swift"), read("Sources/ControllerModel.swift"), read("Sources/WorkLensPlans.swift")
fails = []
def pin(ok, what):
    if not ok: fails.append(what)

# Helper: the capability passes through, and the three Control routes exist, each to its contract path.
pin('"lensPlans": body["lensPlans"] as? Int == 1' in helper, "the helper passes the server's lensPlans capability")
for cmd, fn in [("work-lens-inbox", "emitWorkLensInbox(args: args)"), ("work-lens-history", "emitWorkLensHistory(args: args)"), ("work-lens-result", "emitWorkLensResult(args: args)")]:
    pin(f'case "{cmd}": try {fn}' in helper, f"helper routes {cmd}")
pin('return "/api/work/chat/lens-inbox?since=\\(since)&autoSend=\\(autoSend)"' in helper, "the inbox is GET /api/work/chat/lens-inbox?since=<cursor>")
pin('workLensPost("/api/work/chat/lens-rounds/\\(id)/history", data)' in helper, "history is POST /api/work/chat/lens-rounds/:roundId/history")
pin('workLensPost("/api/work/chat/lens-send/\\(id)/result", data)' in helper, "a result is POST /api/work/chat/lens-send/:sendRequestId/result")
pin('raw["state"] as? String == "in_history"' in helper, "history always says in_history")
inbox = helper[helper.index("    private func emitWorkLensInbox(args: [String]) throws {"):helper.index("    private func emitWorkLensHistory(args: [String]) throws {")]
pin('request(path, token: try readToken(), timeout: 10)' in inbox and 'method: "POST"' not in inbox, "the inbox poll is a GET")

# App: the pump starts with the queue pump (Work chat enabled), and polls only a server that advertises lensPlans.
start = model[model.index('if Bundle.main.object(forInfoDictionaryKey: "COSWorkChatEnabled") as? Bool == true\n            || ProcessInfo'):]
start = start[:start.index("meetingAudioNotifier.onOpenWork")]
pin("let lens = WorkLensPlansPump(handoff: store," in start and "lens.start()" in start and "workLensPlansPump = lens" in start, "the app starts the lens pump with Work chat")
pin("store: background)" in start and start.count("store: background)") == 2 and "let background = WorkTaskChatStore()" in start, "the queue pump and the lens pump share one background store (one writer per card)")
body = pump[pump.index("    func pass() async {"):pump.index("    private func store(for workID: String)")]
pin(body.index("guard offered else { return }") < body.index('"work-lens-inbox"'), "no inbox poll from a server without lensPlans")
pin('offered = caps["lensPlans"]?.bool == true' in body, "lensPlans decides the poll")
pin("static let pollSeconds: Double = 5" in lens and "func start(interval: Duration = .seconds(WorkLensPlans.pollSeconds))" in pump, "the inbox is polled every 5 s")

# One send path: a lens send goes through dispatch (submit, fences, receipts, queue), never submit directly.
ext = chat[chat.index("// MARK: - 0.5.333 lens plans"):]
send = ext[ext.index("    func sendLensRequest("):ext.index("    func stopLensAssignments(")]
pin("await dispatch(roundID: current.rounds[index].id, assignmentIDs: ids, source: source, handoff: handoff, hold: holdChoice(nil, autoSend: true, handoff: handoff))" in send, "a lens send uses Send's own dispatch")
pin("submit(" not in ext and "submit(" not in pump, "nothing in lens plans calls submit directly")
pin(send.index("WorkLensPlans.maySend(confirm: send.confirm, cardAutoSend: cardAutoSend)") < send.index("await dispatch("), "the per-card rule is checked before any send")
record = ext[ext.index("    func recordLensRound("):ext.index("    func lensResults(")]
pin("dispatch(" not in record and "submit(" not in record and "sendAll(" not in record, "recording a lens round never sends it, whatever the card's Auto-send")
pin('case "work-lens-mac-send": try emitWorkLensMacSend(args: args)' in helper and 'workLensPost("/api/work/chat/lens-rounds/\\(id)/mac-send", data)' in helper, "a Mac send of a lens round goes to POST /api/work/chat/lens-rounds/:roundId/mac-send")
pin("if !lensDispatching, let lensRound = self.record?.rounds[index].lensRoundID { Self.onLensMacSend?(record.workID, lensRound) }" in chat, "Miles's own Send of a lens round is reported, a lens send is not reported twice")
stop = ext[ext.index("    func stopLensAssignments("):]
pin("await self.stop(roundID: round.id, assignmentID: a.receiptID, handoff: handoff)" in stop, "a lens stop uses the existing Stop")
pin("round.sentWithoutReview == true || round.sentFromGlasses == true)" in chat, "an assignment sent from the lens has a Stop")

# The view: the card open here is written and sent through this store; its rounds say From glasses with the time.
loop = chat[chat.index("WorkChatQueuePump.show(source.id); defer { WorkChatQueuePump.hide(source.id) }"):chat.index('}.confirmationDialog("Check the connected session first"')]
pin("WorkTaskChatStore.register(chat, for: source.id); defer { WorkTaskChatStore.unregister(chat, for: source.id) }" in loop, "an open card registers its store for the lens pump")
pin('if round.origin == WorkLensPlans.origin, let at = round.lensAt {' in chat and "WorkLensPlans.fromGlassesLabel(at: Date(timeIntervalSince1970: at), now: Date())" in chat, "a lens round shows From glasses and the time")

# Logs: ids and states only.
for src, name in [(pump, "WorkLensPlansPump.swift"), (ext, "WorkTaskChat.swift lens extension")]:
    lines = re.findall(r'(?:lensLog|workChatLog)\.\w+\("((?:[^"\\]|\\.)*)"', src)
    pin(lines and not any(re.search(r'\\\((?:[a-z.]*\.)?(?:question|answer|prompt|context)\b', l) for l in lines), f"{name} logs never carry question, answer, prompt or context text")

# Compile lists: wherever WorkTaskChat.swift is compiled, both lens files are too.
for script in ["scripts/build-release.sh", "scripts/build-foundation-lab.sh", "Tests/run.sh", "Tests/run-held-ui.sh", "Tests/run-markdown-ui.sh", "Tests/run-merge-ui.sh", "Tests/run-pet-composer-ui.sh", "Tests/run-control2-foundation-contract.sh"]:
    for line in read(script).splitlines():
        if '"$ROOT/Sources/WorkTaskChat.swift"' in line and "swift" in line and not line.lstrip().startswith(("python3", "/usr/bin/python3")):
            pin('"$ROOT/Sources/WorkLensPlans.swift" "$ROOT/Sources/WorkLensPlansPump.swift"' in line, f"{script} compiles the lens plans files with WorkTaskChat.swift")
if fails:
    print("FAIL work lens plans pins:\n  " + "\n  ".join(fails)); sys.exit(1)
print("PASS work lens plans pins: helper routes and capability, pump started with Work chat and gated on lensPlans, one send path, existing Stop, From glasses label, ids-only logs, compile lists")
