#!/usr/bin/env python3
"""0.5.343 Build-up, in place: where the pure half (COSBuildUpPlan and COSBuildUpMachine in Sources/Models.swift, executed
by Tests/BuildUpChecks.swift) is wired. The component (COSBuildUp in Sources/COSMotion.swift) and every class-A call site
(operations/personal/wk43_2026/mock-skeleton/SURVEY_control_buildup.md). Each failure names its behaviour as
"pin failed [<behaviour>]". Code only: comments never satisfy a pin.

Then a self-test: each in-memory mutant below must land exactly once in its file and must make a named pin fail, so no
pin here is decoration. Text only: SwiftUI layout is compiled by the full app build, and drawn by
Tests/run-build-up-render.sh, not here.

    python3 Tests/build-up-pins.py <root>
"""
import json, pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
FILES = {"motion": "Sources/COSMotion.swift", "models": "Sources/Models.swift", "meetings": "Sources/ActivityMeetings.swift",
         "window": "Sources/ActivityWindow.swift", "views": "Sources/Views.swift", "ask": "Sources/MeetingAsk.swift",
         "plist": "Resources/Info.plist", "whatsnew": "Resources/WhatsNew.json", "changelog": "CHANGELOG.md", "run": "Tests/run.sh",
         "lane": "Tests/run-build-up.sh", "release": "scripts/build-release.sh"}
SWIFT = ("motion", "models", "meetings", "window", "views", "ask")


class PinFailed(Exception):
    pass


def code(text):
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//"))


def pin(ok, behaviour, why):
    if not ok:
        raise PinFailed(f"pin failed [{behaviour}]: {why}")


def braced(src, start):
    """From the first '{' at or after start to its match."""
    i = src.index("{", start)
    depth = 0
    for j in range(i, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[start:j + 1]
    return src[start:]


def body(src, opener):
    pin(src.count(opener) == 1, "source shape", f"{opener!r} must appear exactly once")
    return braced(src, src.index(opener))


# Every class-A call site: (file, the label it declares, the shape, today's loading view that must stay inside it, today's
# error or empty copy that must stay inside it).
SITES = [
    ("meetings", '"Loading meetings") { libraryContent }', ".rows(6)", None, None),
    ("meetings", 'label: "Loading meeting", key:', ".summary(turns: 5)", 'ProgressView("Loading meeting…")', 'Button("Retry") { model.openLibraryMeeting(row) }'),
    ("window", 'label: "Loading sessions")', ".rows(6)", 'centeredProgress("Loading sessions…")', "emptyState(.sessions, text: sessionsEmptyCopy)"),
    ("window", 'label: "Loading tasks")', ".rows(6)", 'centeredProgress("Loading tasks…")', 'emptyState(.tasks, text: "No open tasks.'),
    ("window", 'label: "Loading messages")', ".list(6)", 'centeredProgress("Loading messages…")', "emptyState(.messages, text: messagesEmptyCopy)"),
    ("window", 'label: "Building the voice directory")', ".list(6)", 'centeredProgress("Building the voice directory…")', None),
    ("window", 'label: "Loading meetings to review")', ".list(6)", 'centeredProgress("Loading meetings…")', '"No reviewable meetings yet."'),
    ("window", 'label: toReview ? "Loading the review queue" : "Loading recent learning"', ".list(6)",
     'centeredProgress(toReview ? "Loading review queue…" : "Loading recent learning…")', '"Nothing to review."'),
    ("window", 'label: "Loading \\(item.title.lowercased())", key: AnyHashable(kind)', ".rows(6)", 'centeredProgress("Loading \\(item.title.lowercased())…")',
     '"Choose COS Data in the menu-bar panel to connect this library."'),
    ("window", 'label: "Reading \\(date)", key: AnyHashable(date)', ".list(6)", 'centeredProgress("Reading \\(date)…")', '"No conversations were archived on \\(date)."'),
    ("window", 'label: "Reading chat \\(index + 1)"', ".turns(6)", 'centeredProgress("Reading chat \\(index + 1)…")', '"That chat holds no messages."'),
    ("window", 'label: "Loading session", key:', ".turns(6)", 'ProgressView("Loading session…")', "ScheduledJobFacts(row: row)"),
    ("window", 'label: "Reading sessions and Work", background: TodayInk.panel)', ".cardRows(2, badge: false)", "Text(TodayHome.loadingLine)",
     "Text(TodayHome.caughtUpLine)"),
    ("window", 'label: "Reading sessions", background: TodayInk.runBg)', ".cardRows(1, badge: true)", 'Text("Reading sessions")', 'Text("Nothing is running.")'),
    ("views", 'label: "Loading entity")', ".detail(turns: 4)", None, "if let error = model.graphEntityError {"),
    ("views", 'label: "Loading lesson")', ".detail(turns: 4)", None, "if let error = model.learningDetailError {"),
    ("views", 'label: "Loading record")', ".detail(turns: 4)", None, "if let error = model.contextDetailError {"),
    ("views", 'label: "Reading the transcript")', ".turns(6)", 'ProgressView("Reading the transcript…")', 'Button("Try again") { model.retryOpenReview() }'),
    ("ask", 'label: "Checking the meeting", key: AnyHashable(exchange.id), background: COSPalette.raised)', ".answer", '"Checking the meeting…"', '"No answer · "'),
]


def site_body(src, label):
    pin(src.count(label) == 1, "call site", f"{label!r} must appear exactly once")
    at = src.index(label)
    start = src.rindex("COSBuildUp(", 0, at)
    pin(at - start < 400, "call site", f"{label!r} is not an argument of a COSBuildUp call")
    close = src.index(") {", at)
    return src[start:close], braced(src, close + 2)


def check(src):
    c = {k: code(src[k]) for k in SWIFT}
    motion, window = c["motion"], c["window"]

    # 1. One component, in an existing Sources file; the pure half in Models.swift.
    pin(motion.count("struct COSBuildUp<Content: View>: View {") == 1, "one component", "COSBuildUp lives in COSMotion.swift")
    pin(all("struct COSBuildUp<" not in c[k] for k in SWIFT if k != "motion"), "one component", "no second copy")
    pin("struct COSBuildUpMachine: Equatable, Sendable {" in c["models"] and "enum COSBuildUpPlan {" in c["models"], "one component",
        "the machine and the plan are in Models.swift, where Tests/BuildUpChecks.swift runs them")
    pin(all(f'"$ROOT/Sources/{name}"' in src["release"] for name in ("COSMotion.swift", "Models.swift")), "one component",
        "the release build lists both files")
    component = body(motion, "struct COSBuildUp<Content: View>: View {")
    view = body(component, "    var body: some View {")

    # 2. The wrapped view is always laid out and live: hidden while it builds, never replaced, so its loads, tasks, error and
    #    empty paths run as before. Once the data lands it is live and clickable at once (the 6.10.654 QA: never block).
    pin(view.count("content()") == 1 and "sized(content()" in view, "content always live", "content() once, outside any if")
    pin(".opacity(hide ? 0 : 1)" in view and ".allowsHitTesting(!hide)" in view and ".accessibilityHidden(hide)" in view,
        "content always live", "while it builds the content is hidden, not removed")
    pin("?? current.hidesContent" in view and "var hidesContent: Bool { phase == .grace || phase == .handoff || (phase == .building && !wordsShown) }" in c["models"],
        "content always live", "the machine decides what hides it: the grace, the hand-off, a build before its words")

    # 3. The wire never takes a click and is hidden from accessibility; the container says what it waits for.
    overlay = view[view.index(".overlay(alignment: .topLeading) {"):]
    stage = overlay[overlay.index("COSBuildUpLiveStage("):overlay.index("if hide {")]
    pin(".accessibilityHidden(true)" in stage and ".allowsHitTesting(false)" in stage, "wire hidden", "the placeholder layers are hidden and pass clicks")
    pin("if hide {" in overlay and ".accessibilityLabel(label)" in overlay[overlay.index("if hide {"):], "loading label",
        "while it builds, the container reads its label")

    # 4. Reduce Motion, the session memory and the machine.
    pin("@Environment(\\.accessibilityReduceMotion) private var reduceMotion" in component, "reduce motion", "the component reads it")
    pin("reduceMotion: reduceMotion, count:" in component and ".onChange(of: reduceMotion) { _, _ in step() }" in view
        and "next.update(at: Self.now(), loading: loading, landed: landed, reduceMotion: reduceMotion)" in component, "reduce motion",
        "every machine sees it, and a change mid-build settles")
    pin(".onChange(of: loading) { _, _ in step() }" in view and ".onChange(of: landed) { _, _ in step() }" in view
        and ".onChange(of: key) { _, _ in reopen() }" in view, "machine fed", "loading, landed and the shown thing drive the machine")
    pin(".task(id: live ? machine?.deadline(after: now) : nil) {" in view, "machine fed", "the machine wakes only at its own deadline")
    pin("quiet: frozen == nil && !COSBuildUpSession.memory.builds(memoryKey)" in component
        and "COSBuildUpSession.memory.record(memoryKey, outcome)" in component, "memory",
        "a view seen this session reopens quietly; an empty one draws no rows")

    # 5. No idle cost: one clock, only while something moves, never in the wrapper; no animation that repeats.
    start = motion.rindex("extension COSPalette {", 0, motion.index("static let wire = Color("))
    section = motion[start:motion.index("struct PetSpriteClip {")]
    live = body(motion, "private struct COSBuildUpLiveStage: View {")
    pin(section.count("TimelineView(") == 1 and "TimelineView(COSBuildUpSchedule(paused: !machine.needsFrames(windowActive: active)))" in live,
        "no idle cost", "the one clock pauses whenever nothing moves")
    pin("@Environment(\\.controlActiveState) private var activeState" in live and "let active = activeState != .inactive" in live
        and "pulsing: machine.pulses(windowActive: active)" in live, "pulse gated", "the pulse needs the machine and an active window")
    pin("if pulsing { pulse(items) }" in body(motion, "private struct COSBuildUpStage: View {"), "pulse gated", "the pulse draws only while pulsing")
    pin("controlActiveState" not in component, "no idle cost", "the wrapper never reads the window state, so focus changes never re-evaluate the content")
    pin("guard next != machine else { return }" in body(component, "    private func step() {"), "no idle cost",
        "a settled view writes no state on a refresh")
    for banned in ("repeatForever", "withAnimation", ".animation(", "Timer", "DispatchQueue", ".onTapGesture", ".gesture(", ".contentShape("):
        pin(banned not in section, "no idle cost", f"{banned} in the build-up")

    # 6. One source of truth: every frame is COSBuildUpPlan.look, the clock is the machine's, and the wire colour reads in
    #    dark mode. One breadcrumb per load through the app's log, counts only.
    stage_src = body(motion, "private struct COSBuildUpStage: View {")
    pin("COSBuildUpPlan.look($0, drawT: drawT, landT: landT)" in stage_src and "let drawT = machine.drawT(at: t) ?? 0" in live
        and "landT: machine.landT(at: t)" in live, "tokens", "the stage draws the plan's look on the machine's clocks")
    wire = section[section.index("static let wire = "):section.index("static let wireSoft")]
    pin("== .darkAqua\n            ? NSColor(red: 0.79, green: 0.66, blue: 0.43, alpha: 0.62)\n            : NSColor(red: 137 / 255, green: 102 / 255, blue: 45 / 255, alpha: 0.62)" in wire,
        "tokens", "the mock's gold wire on cream, the brand gold on espresso so it reads in dark mode")
    remember = body(component, "    private func remember(")
    pin('buildUpLog.notice("\\(line, privacy: .public)")' in remember and "COSBuildUpPlan.breadcrumb(shape, outcome: outcome, rows: machine.count," in remember
        and 'Logger(subsystem: "com.gotcos.control", category: "build-up")' in section, "breadcrumb", "one line per load through the app's log")
    pin("if before == nil, let outcome = next.outcome { remember(outcome, next) }" in component, "breadcrumb", "once per load, when it ends")

    # 7. Every class-A call site wraps today's view, untouched, with its error and empty paths inside.
    total = sum(c[k].count("COSBuildUp(") for k in SWIFT if k != "motion")
    pin(total == len(SITES), "call site", f"{total} COSBuildUp call sites, expected {len(SITES)}")
    for key, label, shape, waiting, fallback in SITES:
        args, closure = site_body(c[key], label)
        pin(args.startswith("COSBuildUp(" + shape + ","), "call site", f"{label!r} declares {shape}")
        pin("loading:" in args and "landed:" in args, "call site", f"{label!r} declares its loading state")
        if waiting:
            pin(c[key].count(waiting) >= 1 and waiting in closure, "today inside", f"{label!r} keeps {waiting!r} inside")
        if fallback:
            pin(fallback in closure, "today inside", f"{label!r} keeps {fallback!r} inside")
        for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', args):
            pin("—" not in literal and "→" not in literal and " -> " not in literal, "copy", f"no em dash or arrow: {literal!r}")
    pin("{ libraryContent }" in c["meetings"] and "private var libraryContent: some View {" in c["meetings"], "today inside",
        "the meetings list's chain is today's, renamed")

    # 8. The version touchpoints the 0.5.342 commit touched, and the What's New copy.
    pin("<string>0.5.343</string>" in src["plist"] and "<string>397</string>" in src["plist"], "version", "Info.plist 0.5.343 (397)")
    notes = json.loads(src["whatsnew"])
    pin(notes.get("version") == "0.5.343", "version", "WhatsNew.json version")
    summary = notes["whatsNew"]["summary"]
    pin(summary.startswith("Views build in place while they load") and "Plus everything in 0.5.342: " in summary, "version",
        "the summary leads with 0.5.343 and chains 0.5.342")
    first = notes["whatsNew"]["sections"][0]
    pin(first["title"] == "0.5.343" and len(first["items"]) >= 3, "version", "a 0.5.343 section first")
    entry = src["changelog"].split("\n## ", 1)[0]
    pin(entry.startswith("## 0.5.343 (build 397)"), "version", "CHANGELOG leads with 0.5.343 (build 397)")
    for text in [summary.split(" Plus everything in 0.5.342: ")[0]] + first["items"] + [entry]:
        pin("—" not in text and "→" not in text, "copy", f"no em dash or arrow: {text[:80]!r}")

    # 9. The lane runs.
    pin('zsh "$ROOT/Tests/run-build-up.sh"' in src["run"], "lane wired", "Tests/run.sh runs the build-up lane")
    pin("Tests/BuildUpChecks.swift" in src["lane"] and "Sources/Models.swift" in src["lane"] and "build-up-pins.py" in src["lane"], "lane wired",
        "the lane compiles the checks with Models.swift and runs these pins")


MUTANTS = [
    ("content removed while building", "motion", "        sized(content()\n", "        sized(EmptyView()\n"),
    ("content shown under the wire", "motion", "            .opacity(hide ? 0 : 1)\n", "            .opacity(1)\n"),
    ("content not clickable after it lands", "motion", "            .allowsHitTesting(!hide)\n", "            .allowsHitTesting(phase == .settled)\n"),
    ("content read while building", "motion", "            .accessibilityHidden(hide), hide: hide,", "            .accessibilityHidden(false), hide: hide,"),
    ("words never show", "models", "(phase == .building && !wordsShown)", "phase == .building"),
    ("wire takes clicks", "motion", "                                        onFit: fit)\n                        .allowsHitTesting(false)\n",
     "                                        onFit: fit)\n"),
    ("wire visible to accessibility", "motion", "                        .allowsHitTesting(false)\n                        .accessibilityHidden(true)\n",
     "                        .allowsHitTesting(false)\n"),
    ("no loading label", "motion", "                        .accessibilityLabel(label)\n", ""),
    ("reduce motion ignored mid-build", "motion", "            .onChange(of: reduceMotion) { _, _ in step() }\n", ""),
    ("landed never fed", "motion", "            .onChange(of: landed) { _, _ in step() }\n", ""),
    ("machine wakes every second", "motion", ".task(id: live ? machine?.deadline(after: now) : nil) {", ".task(id: live ? Int(Self.now()) : nil) {"),
    ("a seen view builds again", "motion", "quiet: frozen == nil && !COSBuildUpSession.memory.builds(memoryKey)", "quiet: false"),
    ("the clock never pauses", "motion", "TimelineView(COSBuildUpSchedule(paused: !machine.needsFrames(windowActive: active)))", "TimelineView(COSBuildUpSchedule(paused: false))"),
    ("pulse in an inactive window", "motion", "pulsing: machine.pulses(windowActive: active)", "pulsing: machine.pulses(windowActive: true)"),
    ("pulse always", "motion", "if pulsing { pulse(items) }", "if true { pulse(items) }"),
    ("the stage repeats", "motion", "        .opacity(handoffT.map { max(0, 1 - $0 / COSBuildUpPlan.handoffSeconds) } ?? 1)\n",
     "        .opacity(handoffT.map { max(0, 1 - $0 / COSBuildUpPlan.handoffSeconds) } ?? 1)\n        .animation(.linear.repeatForever(), value: drawT)\n"),
    ("the wrapper reads the window", "motion", "    @Environment(\\.accessibilityReduceMotion) private var reduceMotion\n    @State private var machine",
     "    @Environment(\\.accessibilityReduceMotion) private var reduceMotion\n    @Environment(\\.controlActiveState) private var windowState\n    @State private var machine"),
    ("a refresh rewrites state", "motion", "        guard next != machine else { return }\n", ""),
    ("the landing restarts the draw", "motion", "let drawT = machine.drawT(at: t) ?? 0", "let drawT = machine.landT(at: t) ?? (machine.drawT(at: t) ?? 0)"),
    ("the stage skips the plan", "motion", "COSBuildUpPlan.look($0, drawT: drawT, landT: landT)", "COSBuildUpPlan.look($0, drawT: 9, landT: landT)"),
    ("wire unreadable in dark mode", "motion", "            ? NSColor(red: 0.79, green: 0.66, blue: 0.43, alpha: 0.62)\n            : NSColor(red: 137 / 255",
     "            ? NSColor(red: 137 / 255, green: 102 / 255, blue: 45 / 255, alpha: 0.62)\n            : NSColor(red: 137 / 255"),
    ("breadcrumb holds text", "motion", 'buildUpLog.notice("\\(line, privacy: .public)")', 'buildUpLog.notice("\\(line) \\(label, privacy: .public)")'),
    ("breadcrumb every change", "motion", "if before == nil, let outcome = next.outcome { remember(outcome, next) }", "if let outcome = next.outcome { remember(outcome, next) }"),
    ("tasks unwrapped", "window", '            COSBuildUp(.rows(6), loading: model.tasksLoading && model.tasks.isEmpty, landed: !model.tasks.isEmpty, label: "Loading tasks") {\n',
     "            Group {\n"),
    ("tasks spinner gone", "window", 'centeredProgress("Loading tasks…")', "ProgressView()"),
    ("tasks empty copy gone", "window", 'emptyState(.tasks, text: "No open tasks.', 'emptyState(.tasks, text: "Nothing.'),
    ("answer shape wrong", "ask", "COSBuildUp(.answer, loading:", "COSBuildUp(.rows(3), loading:"),
    ("answer loading not declared", "ask", "COSBuildUp(.answer, loading: !exchange.terminal", "COSBuildUp(.answer, waiting: !exchange.terminal"),
    ("Today running unwrapped", "window", 'label: "Reading sessions", background: TodayInk.runBg)', 'label: "Reading", background: TodayInk.runBg)'),
    ("record error dropped", "views", "            if let error = model.contextDetailError {\n", "            if let error = Optional<String>.none {\n"),
    ("an em dash in a label", "window", 'label: "Loading tasks")', 'label: "Loading — tasks")'),
    ("meetings chain moved", "meetings", "{ libraryContent }", "{ EmptyView() }"),
    ("version not bumped", "plist", "<string>397</string>", "<string>396</string>"),
    ("What's New not chained", "whatsnew", "Plus everything in 0.5.342: ", "Plus 0.5.342: "),
    ("an em dash in What's New", "whatsnew", "the layout draws itself, then fills in", "the layout draws itself \\u2014 then fills in"),
    ("CHANGELOG not led", "changelog", "## 0.5.343 (build 397), Build-up, in place", "## 0.5.343, Build-up, in place"),
    ("lane not wired", "run", 'zsh "$ROOT/Tests/run-build-up.sh"', 'true "$ROOT/Tests/run-build-up.sh"'),
]

sources = {k: (root / v).read_text(encoding="utf-8") for k, v in FILES.items()}
try:
    check(sources)
except PinFailed as e:
    sys.exit(str(e))
caught = 0
for name, key, old, new in MUTANTS:
    if sources[key].count(old) != 1:
        sys.exit(f"pin self-test: mutant '{name}' lands {sources[key].count(old)} times in {FILES[key]}; it must land exactly once")
    try:
        check(dict(sources, **{key: sources[key].replace(old, new)}))
    except PinFailed as e:
        caught += 1
        print(f"KILLED  {name}  <- {e}")
        continue
    sys.exit(f"pin self-test: mutant '{name}' landed and every pin still passed")
print(f"PASS build up pins: one component, content always live and clickable once landed, the wire hidden and click-through, "
      f"the loading label, Reduce Motion, the session memory, the paused clock, the gated pulse, one source of truth, the breadcrumb, {len(SITES)} call sites with today's views inside, the version, the lane; "
      f"{caught} of {len(MUTANTS)} in-memory mutants caught")
