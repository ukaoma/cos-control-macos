#!/usr/bin/env python3
"""0.5.379: the Today summary's wiring, pinned where Tests/ActivityTodayChecks.swift cannot reach (the view, the store and
the helper). The rules themselves (when to ask, what shows, Refresh's floor and reasons, the body) execute there."""
import pathlib, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
win = (root / "Sources/ActivityWindow.swift").read_text()
helper = (root / "HelperSources/main.swift").read_text()
failures = []
def need(ok, what):
    if not ok: failures.append(what)
def in_order(text, *parts):
    at = 0
    for part in parts:
        at = text.find(part, at)
        if at < 0: return False
        at += len(part)
    return True
def body(text, start, stop):
    a = text.index(start); b = text.index(stop, a)
    return text[a:b]

home = body(win, "    func todayHomeView(", "    func todayHeader(now: Date)")
need(home.count("Text(TodaySummary.headline(todayBriefCounts(frame, now: now), summary: todaySummaryShown(frame)))") == 1,
     "the headline is the server's exact summary, over the quiet-hours fold")
need("todaySummaryLine(frame, now: now)" in home, "the Updated line and Refresh sit under the headline")
shown = body(win, "    func todaySummaryShown(", "    func todaySummaryLine(")
need("TodaySummary.shown(today.summary.reply, sessionsRead: frame.counts.sessionsKnown)" in shown, "a summary shows only over a session list that was read")
need("guard frame.reachable else { return nil }" in shown, "no summary while the server is not answering (Control Web's offline Today)")
line = body(win, "    func todaySummaryLine(", "    func todaySummaryBody(")
need("COSTextButtonStyle()" in line and ".disabled(refresh.busy || counting)" in line, "Refresh is a COS text button, off while busy or counting down")
need("TimelineView(.periodic(from: now, by: 1))" in line and line.index("if counting {") < line.index("TimelineView("),
     "the note ticks once a second only while a countdown runs")
tick = body(win, "    func todayTick() async {", "    func todayOpenLoads() async {")
need(tick.count("today.askSummary(") == 1 and "if section == nil && !showingSettings { await today.askSummary(" in tick,
     "Today asks once per tick, only while the home is on screen")
need(win.count("today.askSummary(") == 1 and win.count("today.refreshToday(") == 1, "one automatic ask and one Refresh path")
refresh = body(win, "    func todayRefresh() async {", "    func todayHeader(now: Date)")
need("Self.allowsLiveSectionLoads(" in refresh, "Refresh never reaches a server from a preview or render")
reload_sources = body(win, "    func todayReloadSources() async {", "    /// Refresh: all source reads again")
need("await todayReloadSources()" in refresh and "await model.refresh(quiet: true)" in reload_sources
     and "await model.loadWorkTasks(force: true)" in reload_sources and "await today.tick(model: model, force: true)" in reload_sources,
     "Refresh rereads Memories, Work, calendar and intake before the forced summary")
need("await model.loadClaudeSessions(force: true)" in reload_sources and "await model.loadPetSessions(force: true)" in reload_sources,
     "Refresh awaits fresh catalog and live inventories")
retry = body(win, "    func todayRetryLine(", "    func todayNeedRow(")
need("await todayReloadSources()" in retry and "todayRefresh()" not in retry, "source retry reloads both session inventories without the summary floor")
need("input.yourMovePending = !model.workYourMoveAvailable && !model.workYourMoveFailed && !model.workYourMoveOff" in win,
     "pending handoffs keep Work pending until your move answered, failed or said it is off")
store_refresh = body(win, "    func refreshToday(", "    /// Ordinary ticks coalesce;")
need("guard refresh.begin(now: Date()) else { return }" in store_refresh and "TodaySummary.forced(rows)" in store_refresh
     and "summary.reply?.switchedOff == true || summary.unavailable" in store_refresh, "Refresh: the floor first, force only when the summary is on and the route exists")
need(win.count("TodaySummary.forced(") == 1, "force is sent only by Refresh")
send = body(win, "    func sendSummary(", "    func askSummary(")
need('model.todayHelper(["today-brief"], timeout: 50, stdinData: bounded.data)' in send, "the rows go to the helper on stdin, never argv")
need('case "today-brief": try emitTodayBrief()' in helper, "the helper has the today-brief command")
h = body(helper, "    private func emitTodayBrief() throws {", "    private func emitTodayBriefSettings(args: [String]) throws {")
need("readBoundedStdin(Self.todayBriefBodyMaxBytes)" in h and "static let todayBriefBodyMaxBytes = 48 * 1024" in h, "the body is bounded to the server's 48 KiB")
need("let answer = try Self.todayBriefExchange(body) { payload in" in h and "emit(ok: true, message: answer.message, details: answer.details)" in h,
     "the helper runs the exchange its self-test drives")
need("Self.todayBriefExchange(" in helper.split("private func selfTest() throws {", 1)[1], "the self-test drives todayBriefExchange")
need('request("/api/today/brief", method: "POST"' in h and h.count("request(") == 1, "one POST route, asked through one call site")
need('if response.status == 404 { return ("Not available on this server", ["available": false, "reason": "older_server"]) }' in h, "a missing route is an older server, not a failure")
need('== "invalid_today_brief"' in h and 'for key in ["reason", "force"] where response.status == 400 && body[key] != nil' in h
     and "body.removeValue(forKey: key)" in h, "a 7.0.0 server's 400 to force (0.5.380: and a pre-7.0.5 server's 400 to reason) is asked again without it")
need("print(" not in h and "token" not in h.replace("let token = try candidate?.token ?? readToken()", "").replace("token: token", ""), "the token is only passed to the request")
st = body(helper, "    private func emitTodayBriefSettings(args: [String]) throws {", "    private func emitWorkTasks() throws {")
need('case "today-brief-settings": try emitTodayBriefSettings(args: args)' in helper and st.count('"/api/today/brief/settings"') == 2
     and 'if let change, change != "on" && change != "off" { throw' in st, "the switch: one read, one write of on or off only")
blk = body(win, "struct TodaySummarySettingsBlock: View {", "\n}\n") if "struct TodaySummarySettingsBlock: View {" in win else ""
need(".toggleStyle(COSCheckStyle())" in blk and ".disabled(settings.locked || store.busy)" in blk, "the switch is a COS check, locked when the Mac's environment sets it")
need("TodaySummarySettingsBlock(model: model)" in (root / "Sources/Views.swift").read_text(), "Settings, Activity home draws the switch")
need("summaryEpoch != TodaySummarySettingsStore.epoch" in win and "Self.epoch &+= 1" in body(win, "@MainActor final class TodaySummarySettingsStore", "struct TodaySummarySettingsBlock"), "a change in Settings resets the Today summary")
src_inputs = body(win, "    func todaySourceInputs() -> TodayHome.SourceInputs {", "    func todayCardFacts(")
need("TodaySummary.displayedSessionReadState(petEnabled: model.petEnabled" in src_inputs
     and "catalog: model.claudeSessionsReadState, live: model.petSessionsReadState" in src_inputs,
     "fresh catalog state cannot certify retained live rows")
need("TodayHome.intakeReadFailed(model.workIntake, readError: model.workIntakeError, actionError: today.lastResolveError)" in src_inputs,
     "an Intake503 reaches source completeness without a thrown helper error")
need("input.yourMoveFailed = model.workYourMoveFailed" in src_inputs, "a failed your-move read reaches Today's Work source")
cm = (root / "Sources/ControllerModel.swift").read_text()
session_read = body(cm, "    private func fetchClaudeSessions(quick: Bool) async {", "    /// 0.5.254 resize pass:")
need('TodaySummary.sessionReadState(partial: partial, cached: cached, fresh: !quick)' in session_read and 'if !quick, !partial, !cached {' in session_read,
     "cached and partial session inventories never certify freshness or advance the fresh-cache clock")
pet_read = body(cm, "    func loadPetSessions(force: Bool = false) async {", "    /// `authoritative` gates the prune.")
need("petSessionReads.run(force: force)" in pet_read and "if !force, claudeSessionsLoading" in pet_read
     and 'TodaySummary.liveSessionReadState(complete: response.details["liveReadComplete"]?.bool)' in pet_read
     and "authoritative: state == .answered" in pet_read,
     "forced pet reads wait, bypass a catalog poll and retain independent freshness")
live_helper = body(helper, "    private func emitLiveClaudeSessions(", "    private func emitQuickClaudeSessions(")
need("Self.petLiveReadComplete(body)" in live_helper and "partial: !serverAnswered, liveReadComplete: serverAnswered" in live_helper,
     "the helper emits live provenance only from a structurally valid server response")
need('TodaySummary.componentReadFailed([' in win, "component server failures reach the Today refresh warning")
ym = body(cm, "    func loadYourMove() async {", "    @Published var workTasksLoading")
need('workYourMoveOff = !workYourMoveAvailable && response.details["reason"]?.string == "older_server"' in ym
     and "workYourMoveFailed = !workYourMoveAvailable && !workYourMoveOff" in ym and ym.count("workYourMoveFailed = true") == 1
     and "workYourMoveOff = !workYourMoveAvailable\n" not in ym,
     "your move is off only for an older server (the helper's 404); a server's {available:false} is failed, as on Control Web")
need("timeout: Self.workYourMoveHelperTimeout" in ym and "static let workYourMoveHelperTimeout: TimeInterval = 14" in cm, "the app waits past the helper's request")
wym = body(helper, "    private func emitWorkYourMove() throws {", "    /// 0.5.379: the Today summary")
need("timeout: Self.workYourMoveRequestTimeout" in wym and "static let workYourMoveServerLookupSeconds = 8" in helper
     and "static let workYourMoveRequestTimeout = workYourMoveServerLookupSeconds + 2" in helper, "the helper waits past the server's 8 s lookup")
need('if response.status == 404 { emit(ok: true, message: "Not available on this server", details: ["available": false, "reason": "older_server", "items": []]); return }' in wym,
     "the helper tags a missing route older_server, the only your-move answer the app reads as off")
# QA 0.5.379: the tick's opening loads are marked done only after they ran; summary failures are logged.
need(in_order(tick, "await todayOpenLoads()", "if !Task.isCancelled { today.openLoadsDone = true }"), "opening loads are done only after they finish")
need("today.openLoadsDone = true\n            await todayOpenLoads()" not in tick, "never marked done before the loads")
need("today.catalogRetry.due(state: model.claudeSessionsReadState, loading: model.claudeSessionsLoading, now: Date())" in tick
     and "today.catalogRetry.finished(model.claudeSessionsReadState)" in tick, "an unanswered catalog is walked by the tick, pet on or off")
need(send.count("todayLog.") >= 5 and "TodaySummary.encodedBody(body)" in send and "stdinData: bounded.data" in send, "every summary failure is logged; the bounded body is sent")
need(all("reply?.text" not in l and "details[\"text\"]" not in l and "response.message" not in l and "localizedDescription" not in l
         for l in send.split("\n") if "todayLog." in l), "no summary text or helper message in a summary log line")
need("failed=\\(failedNames.isEmpty" in win, "the tick's log line names failed components")
need("input.memoriesTotal = model.status.learningToReviewTotal" in win and "facts.memoriesTotal = model.status.learningToReviewTotal" in win
     and "toReviewEvents.count" not in body(win, "    func todayNeedInputs(", "    func todayIntakeSplit("), "Next N of total uses learningToReviewTotal, as Control Web")
ask = body(win, "    func askSummary(", "    func refreshToday(")
need("TodaySummary.kept(previous: summary.reply, answer: answer)" in ask and "TodaySummary.kept(previous: summary.reply, answer: answer)" in store_refresh,
     "a failed or unreachable ask keeps the summary shown (TodaySummary.kept)")
need("summaryReads.run(force: false)" in ask and "guard !refresh.busy else { return }" in ask and "summaryReads.run(force: true)" in store_refresh, "automatic and forced asks share one awaited queue")
need('let reason = response.details["reason"]?.string ?? "none"' in send and 'return reason == "older_server" ? (nil, false) : nil' in send, "only a missing route is an older server; unreachable or failed is no answer")
held = body(cm, "    private func performLoadHeldGroups() async {", "    /// Every Add/Name starts")
cancel = held[held.index("} catch is CancellationError {"):held.index("        } catch {\n")] if "} catch is CancellationError {" in held else ""
need("if heldGroupsState == nil {" in cancel and 'heldGroupsState = "error"' in cancel and "heldGroupsError = " in cancel and "return" not in cancel,
     "a cancelled first held-voice read ends failed, never pending")
if failures:
    for f in failures: print("FAIL: Today summary pin: " + f, file=sys.stderr)
    sys.exit(1)
print("PASS: Today summary wiring (headline, Updated line, Refresh, one ask per tick on the home, helper today-brief)")
