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
def body(text, start, stop):
    a = text.index(start); b = text.index(stop, a)
    return text[a:b]

home = body(win, "    func todayHomeView(", "    func todayHeader(now: Date)")
need(home.count("Text(TodaySummary.headline(todayBriefCounts(frame, now: now), summary: todaySummaryShown(frame)))") == 1,
     "the headline is COS's count line plus the summary, over the quiet-hours fold")
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
store_refresh = body(win, "    func refreshToday(", "    /// One tick: the helper's serial reads")
need("guard refresh.begin(now: Date()) else { return }" in store_refresh and "TodaySummary.forced(rows)" in store_refresh
     and "summary.reply?.switchedOff == true || summary.unavailable" in store_refresh, "Refresh: the floor first, force only when the summary is on and the route exists")
need(win.count("TodaySummary.forced(") == 1, "force is sent only by Refresh")
send = body(win, "    func sendSummary(", "    func askSummary(")
need('model.todayHelper(["today-brief"], timeout: 50, stdinData: data)' in send, "the rows go to the helper on stdin, never argv")
need('case "today-brief": try emitTodayBrief()' in helper, "the helper has the today-brief command")
h = body(helper, "    private func emitTodayBrief() throws {", "    private func emitTodayBriefSettings(args: [String]) throws {")
need("readBoundedStdin(48 * 1024)" in h, "the body is bounded to the server's 48 KiB")
need('request("/api/today/brief", method: "POST"' in h and h.count("request(") == 1, "one POST route, asked through one call site")
need('response.status == 404 { emit(ok: true, message: "Not available on this server", details: ["available": false' in h, "a missing route is an older server, not a failure")
need('== "invalid_today_brief"' in h and 'body.removeValue(forKey: "force")' in h, "a 7.0.0 server's 400 to force is asked again without it")
need("print(" not in h and "token" not in h.replace("let token = try candidate?.token ?? readToken()", "").replace("token: token", ""), "the token is only passed to the request")
st = body(helper, "    private func emitTodayBriefSettings(args: [String]) throws {", "    private func emitWorkTasks() throws {")
need('case "today-brief-settings": try emitTodayBriefSettings(args: args)' in helper and st.count('"/api/today/brief/settings"') == 2
     and 'if let change, change != "on" && change != "off" { throw' in st, "the switch: one read, one write of on or off only")
blk = body(win, "struct TodaySummarySettingsBlock: View {", "\n}\n") if "struct TodaySummarySettingsBlock: View {" in win else ""
need(".toggleStyle(COSCheckStyle())" in blk and ".disabled(settings.locked || store.busy)" in blk, "the switch is a COS check, locked when the Mac's environment sets it")
need("TodaySummarySettingsBlock(model: model)" in (root / "Sources/Views.swift").read_text(), "Settings, Activity home draws the switch")
need("summaryEpoch != TodaySummarySettingsStore.epoch" in win and "Self.epoch &+= 1" in body(win, "@MainActor final class TodaySummarySettingsStore", "struct TodaySummarySettingsBlock"), "a change in Settings resets the Today summary")
src_inputs = body(win, "    func todaySourceInputs() -> TodayHome.SourceInputs {", "    func todayCardFacts(")
need("input.yourMoveFailed = model.workYourMoveFailed" in src_inputs, "a failed your-move read reaches Today's Work source")
cm = (root / "Sources/ControllerModel.swift").read_text()
ym = body(cm, "    func loadYourMove() async {", "    @Published var workTasksLoading")
need("workYourMoveFailed = !workYourMoveAvailable" in ym and ym.count("workYourMoveFailed = true") == 1, "your move unavailable or failed is recorded as failed")
ask = body(win, "    func askSummary(", "    func refreshToday(")
need("TodaySummary.kept(previous: summary.reply, answer: answer)" in ask and "TodaySummary.kept(previous: summary.reply, answer: answer)" in store_refresh,
     "a failed or unreachable ask keeps the summary shown (TodaySummary.kept)")
need('response.details["reason"]?.string == "older_server" ? (nil, false) : nil' in send, "only a missing route is an older server; unreachable or failed is no answer")
if failures:
    for f in failures: print("FAIL: Today summary pin: " + f, file=sys.stderr)
    sys.exit(1)
print("PASS: Today summary wiring (headline, Updated line, Refresh, one ask per tick on the home, helper today-brief)")
