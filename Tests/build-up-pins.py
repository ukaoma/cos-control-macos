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
# error or empty copy that must stay inside it, what else its arguments must say).
SITES = [
    ("meetings", '"Loading meetings") { libraryContent }', ".rows(6)", None, None, ["interrupted: model.isLibraryQueryActive", "enabled: !selectionOnly",
                                                                                "failed: model.libraryError != nil"]),
    ("meetings", 'label: "Loading meeting", key:', ".summary(turns: 5)", 'ProgressView("Loading meeting…")', 'Button("Retry") { model.openLibraryMeeting(row) }', ["tune: .meetingBody"]),
    ("window", 'label: "Loading sessions")', ".rows(6)", 'centeredProgress("Loading sessions…")', "emptyState(.sessions, text: sessionsEmptyCopy)",
     ["tune: .sessions", "interrupted: model.isSessionQueryActive", "timeout: ControllerModel.claudeSessionsFreshTimeout + COSBuildUpPlan.helperMargin"]),
    ("window", 'label: "Loading tasks")', ".rows(6)", 'centeredProgress("Loading tasks…")', 'emptyState(.tasks, text: "No open tasks.',
     ["tune: .tasks", "failed: model.tasksError != nil", "timeout: ControllerModel.tasksHelperTimeout + COSBuildUpPlan.helperMargin"]),
    ("window", 'label: "Loading messages")', ".list(6)", 'centeredProgress("Loading messages…")', "emptyState(.messages, text: messagesEmptyCopy)",
     ["tune: .messages", "interrupted: messagesSubview == .archive"]),
    ("window", 'label: "Building the voice directory")', ".list(6)", 'centeredProgress("Building the voice directory…")', None, ["tune: .voices"]),
    ("window", 'label: "Loading meetings to review")', ".list(6)", 'centeredProgress("Loading meetings…")', '"No reviewable meetings yet."', ["tune: .reviewMeetings"]),
    ("window", 'label: toReview ? "Loading the review queue" : "Loading recent learning")', ".list(6)",
     'centeredProgress(toReview ? "Loading review queue…" : "Loading recent learning…")', '"Nothing to review."', ["tune: .learning"]),
    ("window", 'label: "Loading \\(item.title.lowercased())")', ".rows(6)", 'centeredProgress("Loading \\(item.title.lowercased())…")',
     '"Choose a notes folder in Settings to connect this library."', ["tune: isThread ? .threads : .memories", "interrupted: queryActive"]),
    ("window", 'label: "Reading \\(date)", key: AnyHashable(date)', ".list(6)", 'centeredProgress("Reading \\(date)…")', '"No conversations were archived on \\(date)."', []),
    ("window", 'label: "Reading chat \\(index + 1)"', ".turns(6)", 'centeredProgress("Reading chat \\(index + 1)…")', '"That chat holds no messages."', []),
    ("window", 'label: "Loading session", key:', ".turns(6)", 'ProgressView("Loading session…")', "ScheduledJobFacts(row: row)", ["tune: .sessionTurns"]),
    ("window", 'label: "Reading sessions and Work", background: TodayInk.panel)', ".cardRows(2, badge: false)", "Text(TodayHome.loadingLine)",
     "Text(TodayHome.caughtUpLine)", ["tune: .needsYou", "failed: !frame.reachable || !TodayHome.failed(states).isEmpty"]),
    # 0.5.353: Running reserves two rows (was one), the height its two common runs take.
    ("window", 'label: "Reading sessions", background: TodayInk.runBg)', ".cardRows(2, badge: true)", 'Text("Reading sessions")', 'Text("Nothing is running.")', ["tune: .running"]),
    ("views", 'label: "Reading the transcript", key: model.reviewRequest.map { AnyHashable($0) })', ".turns(6)", 'ProgressView("Reading the transcript…")',
     'Button("Try again") { model.retryOpenReview() }', ["loading: model.reviewLoading, landed: model.openReview != nil && !model.reviewLoading"]),
    ("ask", 'label: "Checking the meeting", key: AnyHashable(exchange.id), background: COSPalette.raised)', ".answer", '"Checking the meeting…"', '"No answer · "',
     ["failed: exchange.error != nil", "timeout: MeetingAskStore.helperTimeout + COSBuildUpPlan.helperMargin"]),
]


def site_body(src, label):
    pin(src.count(label) == 1, "call site", f"{label!r} must appear exactly once")
    at = src.index(label)
    start = src.rindex("COSBuildUp(", 0, at)
    pin(at - start < 700, "call site", f"{label!r} is not an argument of a COSBuildUp call")
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

    # 2. The wrapped view is always laid out and live: hidden only while the wire stands in for it before the words, never
    #    replaced, never resized; once the data lands, or a load ends empty, it shows at once.
    pin(view.count("content()") == 1 and "sized(content()" in view, "content always live", "content() once, outside any if")
    pin(".opacity(hide ? 0 : 1)" in view and ".allowsHitTesting(!hide)" in view and ".accessibilityHidden(hide)" in view,
        "content always live", "while it builds the content is hidden, not removed")
    pin("?? current.hidesContent" in view and "var hidesContent: Bool { COSBuildUpPlan.hides(phase, wordsShown: wordsShown) }" in c["models"]
        and "phase == .grace || (phase == .building && !wordsShown)" in c["models"], "never hides data",
        "only the grace and a build before its words hide the content; never a landing or a hand-off")
    sized = body(component, "    private func sized<V: View>(")
    # 0.5.353 (moved subject, was "an inline view is never resized"): an inline view reserves its typical height and the
    # container's width only while it builds (the grace and the wire, never under Reduce Motion), and is its own size the
    # moment the build ends, so an empty or failed answer never keeps a full-height skeleton.
    pin("view.frame(maxWidth: hide ? .infinity : nil, maxHeight: hide ? .infinity : nil, alignment: .topLeading)" in sized
        and sized.count("frame(") == 2
        and "view.frame(maxWidth: reserving ? .infinity : nil, minHeight: reserving ? reserve.map { CGFloat($0) } : nil, alignment: .topLeading)" in sized,
        "no extra height", "a pane fills only while hidden; an inline view reserves only while it builds")
    pin("let reserving = COSBuildUpPlan.reserves(phase, reduceMotion: reduceMotion)" in view and "hide: hide, reserving: reserving)" in view,
        "no extra height", "the reservation is the build's alone, never under Reduce Motion")

    # 3. The wire never takes a click, never draws past the view, and is hidden from accessibility; the container says what
    #    it waits for.
    overlay = view[view.index(".overlay(alignment: .topLeading) {"):]
    stage = overlay[overlay.index("COSBuildUpLiveStage("):overlay.index("if hide {")]
    pin(".clipped()" in stage and ".accessibilityHidden(true)" in stage and ".allowsHitTesting(false)" in stage, "wire hidden",
        "the wire is clipped to the view, passes clicks and is hidden from accessibility")
    pin("if hide {" in overlay and ".accessibilityLabel(label)" in overlay[overlay.index("if hide {"):], "loading label",
        "while it builds, the container reads its label")
    stage_src = body(motion, "private struct COSBuildUpStage: View {")
    pin("COSBuildUpPlan.items(shape, tune, limit: limit, fitting: height," in stage_src and "let height = Double(size.height)" in stage_src,
        "fit", "the stage fits its rows to the view's own height every frame")

    # 4. Reduce Motion, the memory, interruptions and the machine.
    pin("@Environment(\\.accessibilityReduceMotion) private var reduceMotion" in component, "reduce motion", "the component reads it")
    pin("reduceMotion: reduceMotion," in component and ".onChange(of: reduceMotion) { _, _ in step() }" in view
        and "reduceMotion: reduceMotion, interrupted: interrupted," in component, "reduce motion",
        "every machine sees it, and a change mid-build settles")
    pin(".onChange(of: failed) { _, _ in step() }" in view and "interrupted: interrupted,\n                    failed: failed)" in body(component, "    private func step() {"), "failed",
        "the site's error flag reaches the machine, so an error is never kept as empty")
    clear = body(component, "    private func clearEmptyOnData() {")
    pin("landed, key == nil, COSBuildUpSession.memory.empty.contains(memoryKey)" in clear and "COSBuildUpSession.record(memoryKey, .landed, persists: true)" in clear
        and component.count("clearEmptyOnData()") == 3, "empty cleared", "a remembered empty view that has data again is cleared, on open and on every change")
    pin(".onChange(of: label) { _, _ in relabel() }" in view and "old.update(at: Self.now(), loading: true, landed: false, interrupted: true)" in component,
        "relabel", "a new label mid-build interrupts the old load")
    pin("quiet: !enabled ||" in component, "enabled", "a disabled site never builds")
    pin(".onChange(of: loading) { _, _ in step() }" in view and ".onChange(of: landed) { _, _ in step() }" in view
        and ".onChange(of: interrupted) { _, _ in step() }" in view and ".onChange(of: key) { _, _ in reopen() }" in view, "machine fed",
        "loading, landed, an interruption and the shown thing drive the machine")
    task = view[view.index(".task(id: frozen == nil ? machine?.deadline : nil) {"):]
    pin("while !Task.isCancelled, Self.now() < deadline {" in task, "machine fed", "the wake sleeps until the deadline has passed, however early it wakes")
    pin("|| !COSBuildUpSession.memory.builds(memoryKey)" in component and "COSBuildUpSession.record(memoryKey, outcome, persists: key == nil)" in component,
        "memory", "a view seen this session, or empty last time, opens quietly; only label keys are kept")
    session = body(motion, "@MainActor enum COSBuildUpSession {")
    pin('UserDefaults.standard.stringArray(forKey: emptyKey)' in session and "UserDefaults.standard.set(memory.empty, forKey: emptyKey)" in session,
        "memory", "the empty views are kept across launches")
    pin(".onDisappear { abandon() }" in view and "abandon()\n        let next = opened(at: Self.now())" in component
        and "remember(.abandoned, next)" in component, "abandoned", "a view taken away, or shown something else, mid-build logs abandoned")

    # 5. No idle cost: one clock, only while something moves, never in the wrapper; no animation that repeats.
    start = motion.rindex("extension COSPalette {", 0, motion.index("static func wire(on background: Color"))
    section = motion[start:motion.index("struct PetSpriteClip {")]
    live = body(motion, "private struct COSBuildUpLiveStage: View {")
    pin(section.count("TimelineView(") == 1 and "TimelineView(COSBuildUpSchedule(paused: !machine.needsFrames(windowActive: active)))" in live,
        "no idle cost", "the one clock pauses whenever nothing moves")
    pin("@Environment(\\.controlActiveState) private var activeState" in live and "let active = activeState != .inactive" in live
        and "pulsing: machine.pulses(windowActive: active)" in live, "pulse gated", "the pulse needs the machine and an active window")
    pin("if pulse { pulseView(items, wire: wire) }" in stage_src, "pulse gated", "the pulse draws only while pulsing, or fading out with the landing")
    pin("controlActiveState" not in component, "no idle cost", "the wrapper never reads the window state, so focus changes never re-evaluate the content")
    pin("guard next != machine else { return }" in body(component, "    private func step() {"), "no idle cost",
        "a settled view writes no state on a refresh")
    for banned in ("repeatForever", "withAnimation", ".animation(", "Timer", "DispatchQueue", ".onTapGesture", ".gesture(", ".contentShape("):
        pin(banned not in section, "no idle cost", f"{banned} in the build-up")
    pin("struct COSBuildUpMachine" in c["models"] and "mutating func reopen(" not in c["models"], "no dead code", "the machine has no unused reopen")

    # 6. One source of truth: every frame is COSBuildUpPlan.look on the machine's clocks; the tint is the plan's; the
    #    wire's colour comes from the surface it is on. One breadcrumb per load through the app's log, counts only.
    pin("COSBuildUpPlan.look($0, drawT: drawT, landT: landT)" in stage_src and "drawT: machine.drawT(at: t) ?? 0, landT: machine.landT(at: t)," in live,
        "tokens", "the stage draws the plan's look on the machine's clocks")
    pin("let curtains = looks.map { COSBuildUpPlan.curtain($0, landing: phase == .landing) }" in stage_src
        and "            .compositingGroup()\n            .opacity(curtain)\n" in stage_src and "Rectangle().fill(background)\n" in stage_src
        and stage_src.count(".opacity(curtain)") == 1, "curtain light", "the surface and the fill are one layer at the plan's tint, never stacked or opaque")
    pin("let wire = COSPalette.wire(on: background, in: environment)" in stage_src and "COSBuildUpPlan.wire(onLuminance: buildUpLuminance(background, environment))" in section,
        "tokens", "the wire's colour comes from the surface behind it")
    remember = body(component, "    private func remember(")
    pin('buildUpLog.notice("\\(line, privacy: .public)")' in remember and "COSBuildUpPlan.breadcrumb(shape, outcome: outcome, rows: machine.count," in remember
        and 'Logger(subsystem: "com.gotcos.control", category: "build-up")' in section, "breadcrumb", "one line per load through the app's log")
    pin("if before == nil, let outcome = next.outcome { remember(outcome, next) }" in component, "breadcrumb", "once per load, when it ends")

    # 7. Every class-A call site wraps today's view, untouched, with its error and empty paths inside.
    total = sum(c[k].count("COSBuildUp(") for k in SWIFT if k != "motion")
    pin(total == len(SITES), "call site", f"{total} COSBuildUp call sites, expected {len(SITES)}")
    for key, label, shape, waiting, fallback, says in SITES:
        args, closure = site_body(c[key], label)
        for said in says:
            pin(said in args, "call site", f"{label!r} declares {said!r}")
        pin(args.startswith("COSBuildUp(" + shape + ","), "call site", f"{label!r} declares {shape}")
        pin("loading:" in args and "landed:" in args, "call site", f"{label!r} declares its loading state")
        if waiting:
            pin(c[key].count(waiting) >= 1 and waiting in closure, "today inside", f"{label!r} keeps {waiting!r} inside")
        if fallback:
            pin(fallback in closure, "today inside", f"{label!r} keeps {fallback!r} inside")
        for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', args):
            pin("—" not in literal and "→" not in literal and " -> " not in literal, "copy", f"no em dash or arrow: {literal!r}")
    for dropped in ('label: "Loading entity"', 'label: "Loading lesson"', 'label: "Loading record"'):
        pin(dropped not in c["views"], "call site", f"{dropped}: those details are set at once and never build")
    pin("{ libraryContent }" in c["meetings"] and "private var libraryContent: some View {" in c["meetings"], "today inside",
        "the meetings list's chain is today's, renamed")

    # 8. The version touchpoints. 0.5.343 shipped as build 397; from 0.5.344 on it is history: a later build, its notes
    # chained after the newer release's ("Plus everything in 0.5.343: ..."), its section and CHANGELOG entry kept.
    build = re.search(r"<key>CFBundleVersion</key>\s*<string>(\d+)</string>", src["plist"])
    short = re.search(r"<key>CFBundleShortVersionString</key>\s*<string>([0-9.]+)</string>", src["plist"])
    pin(build is not None and int(build.group(1)) >= 397 and short is not None
        and tuple(map(int, short.group(1).split("."))) >= (0, 5, 343), "version", "Info.plist at 0.5.343 (397) or later")
    notes = json.loads(src["whatsnew"])
    pin(short is not None and notes.get("version") == short.group(1), "version", "WhatsNew.json version matches Info.plist")
    summary = notes["whatsNew"]["summary"]
    lead = "Views draw the outline of their rows while they load"
    # 0.5.345 (plan r3): the summary is capped at 1,200 characters (the window's cap) and chains only the release before
    # it, so 0.5.343's words are read from its own section from 0.5.345 on.
    mine = [section for section in notes["whatsNew"]["sections"] if section["title"] == "0.5.343"]
    pin((summary.startswith(lead) and "Plus everything in 0.5.342: " in summary) if notes.get("version") == "0.5.343"
        else (len(mine) == 1 and any("draw the outline of their rows while they load" in item for item in mine[0]["items"])),
        "version", "the summary leads with 0.5.343, or a later release keeps 0.5.343's own section describing it")
    pin(len(mine) == 1 and len(mine[0]["items"]) >= 3, "version", "a 0.5.343 section")
    first = mine[0] if mine else {"items": []}
    entries = src["changelog"].split("\n## ")
    entry = next(("## " + e if i else e for i, e in enumerate(entries) if ("## " + e if i else e).startswith("## 0.5.343 (build 397)")), "")
    pin(entry != "", "version", "CHANGELOG keeps 0.5.343 (build 397)")
    for text in first["items"] + [entry]:
        pin("—" not in text and "→" not in text, "copy", f"no em dash or arrow: {text[:80]!r}")

    # 9. The lane runs.
    pin('zsh "$ROOT/Tests/run-build-up.sh"' in src["run"], "lane wired", "Tests/run.sh runs the build-up lane")
    pin("Tests/BuildUpChecks.swift" in src["lane"] and "Sources/Models.swift" in src["lane"] and "build-up-pins.py" in src["lane"], "lane wired",
        "the lane compiles the checks with Models.swift and runs these pins")


MUTANTS = [
    ("content removed while building", "motion", "        sized(content()\n", "        sized(EmptyView()\n"),
    ("content shown under the wire", "motion", "            .opacity(hide ? 0 : 1)\n", "            .opacity(1)\n"),
    ("content not clickable after it lands", "motion", "            .allowsHitTesting(!hide)\n", "            .allowsHitTesting(false)\n"),
    ("content read while building", "motion", "            .accessibilityHidden(hide), hide: hide, reserving: reserving)", "            .accessibilityHidden(false), hide: hide, reserving: reserving)"),
    ("the hand-off hides the content", "models", "phase == .grace || (phase == .building && !wordsShown)", "phase == .grace || phase == .handoff || (phase == .building && !wordsShown)"),
    ("words never show", "models", "phase == .grace || (phase == .building && !wordsShown)", "phase == .grace || phase == .building"),
    ("an inline view reserves height", "motion", "view.frame(maxWidth: reserving ? .infinity : nil, minHeight: reserving ? reserve.map { CGFloat($0) } : nil, alignment: .topLeading)",
     "view.frame(maxWidth: .infinity, minHeight: reserve.map { CGFloat($0) }, alignment: .topLeading)"),
    ("the reservation outlives the build", "motion", "let reserving = COSBuildUpPlan.reserves(phase, reduceMotion: reduceMotion)",
     "let reserving = phase != .settled"),
    ("the wire draws past the view", "motion", "                        .clipped()\n                        .allowsHitTesting(false)\n", "                        .allowsHitTesting(false)\n"),
    ("wire takes clicks", "motion", "                        .clipped()\n                        .allowsHitTesting(false)\n", "                        .clipped()\n"),
    ("wire visible to accessibility", "motion", "                        .allowsHitTesting(false)\n                        .accessibilityHidden(true)\n",
     "                        .allowsHitTesting(false)\n"),
    ("no loading label", "motion", "                        .accessibilityLabel(label)\n", ""),
    ("the stage ignores the view's height", "motion", "COSBuildUpPlan.items(shape, tune, limit: limit, fitting: height,", "COSBuildUpPlan.items(shape, tune, limit: limit, fitting: nil,"),
    ("reduce motion ignored mid-build", "motion", "            .onChange(of: reduceMotion) { _, _ in step() }\n", ""),
    ("landed never fed", "motion", "            .onChange(of: landed) { _, _ in step() }\n", ""),
    ("an interruption never fed", "motion", "            .onChange(of: interrupted) { _, _ in step() }\n", ""),
    ("an early wake gives up", "motion", "                while !Task.isCancelled, Self.now() < deadline {", "                if !Task.isCancelled, Self.now() < deadline {"),
    ("a seen view builds again", "motion", "quiet: !enabled || !COSBuildUpSession.memory.builds(memoryKey)", "quiet: !enabled || false"),
    ("keyed views kept across launches", "motion", "COSBuildUpSession.record(memoryKey, outcome, persists: key == nil)", "COSBuildUpSession.record(memoryKey, outcome, persists: true)"),
    ("empty views forgotten at quit", "motion", "        if memory.record(key, outcome, persists: persists) { UserDefaults.standard.set(memory.empty, forKey: emptyKey) }\n",
     "        memory.record(key, outcome, persists: persists)\n"),
    ("a view taken away is not logged", "motion", "            .onDisappear { abandon() }\n", ""),
    ("the clock never pauses", "motion", "TimelineView(COSBuildUpSchedule(paused: !machine.needsFrames(windowActive: active)))", "TimelineView(COSBuildUpSchedule(paused: false))"),
    ("pulse in an inactive window", "motion", "pulsing: machine.pulses(windowActive: active)", "pulsing: machine.pulses(windowActive: true)"),
    ("pulse always", "motion", "if pulse { pulseView(items, wire: wire) }", "if true { pulseView(items, wire: wire) }"),
    ("the stage repeats", "motion", "        .opacity(handoffT.map { max(0, 1 - $0 / COSBuildUpPlan.handoffSeconds) } ?? 1)\n",
     "        .opacity(handoffT.map { max(0, 1 - $0 / COSBuildUpPlan.handoffSeconds) } ?? 1)\n        .animation(.linear.repeatForever(), value: drawT)\n"),
    ("the wrapper reads the window", "motion", "    @Environment(\\.accessibilityReduceMotion) private var reduceMotion\n    @State private var machine",
     "    @Environment(\\.accessibilityReduceMotion) private var reduceMotion\n    @Environment(\\.controlActiveState) private var windowState\n    @State private var machine"),
    ("a refresh rewrites state", "motion", "        guard next != machine else { return }\n", ""),
    ("the landing restarts the draw", "motion", "drawT: machine.drawT(at: t) ?? 0, landT: machine.landT(at: t),", "drawT: machine.landT(at: t) ?? (machine.drawT(at: t) ?? 0), landT: machine.landT(at: t),"),
    ("the stage skips the plan", "motion", "COSBuildUpPlan.look($0, drawT: drawT, landT: landT)", "COSBuildUpPlan.look($0, drawT: 9, landT: landT)"),
    ("an opaque tint", "motion", "            .compositingGroup()\n            .opacity(curtain)\n", "            .compositingGroup()\n            .opacity(curtain > 0 ? 1 : 0)\n"),
    ("a stacked fill", "motion", "                        .fill(COSPalette.card)\n                        .frame(width: box.width, height: box.height)",
     "                        .fill(COSPalette.card)\n                        .opacity(curtain)\n                        .frame(width: box.width, height: box.height)"),
    ("data never clears the empty mark", "motion", "        guard frozen == nil else { return }\n        clearEmptyOnData()\n", "        guard frozen == nil else { return }\n"),
    ("errors kept as empty", "motion", "interrupted: interrupted,\n                    failed: failed)", "interrupted: interrupted,\n                    failed: false)"),
    ("a tab switch is a refresh", "motion", "            .onChange(of: label) { _, _ in relabel() }\n", ""),
    ("the picker builds", "meetings", "enabled: !selectionOnly,", ""),
    ("tasks give up before their helper", "window", "timeout: ControllerModel.tasksHelperTimeout + COSBuildUpPlan.helperMargin, ", ""),
    ("one wire colour for every surface", "motion", "let wire = COSPalette.wire(on: background, in: environment)", "let wire = COSPalette.wire(on: COSPalette.panel, in: environment)"),
    ("breadcrumb holds text", "motion", 'buildUpLog.notice("\\(line, privacy: .public)")', 'buildUpLog.notice("\\(line) \\(label, privacy: .public)")'),
    ("breadcrumb every change", "motion", "if before == nil, let outcome = next.outcome { remember(outcome, next) }", "if let outcome = next.outcome { remember(outcome, next) }"),
    ("a dead reopen comes back", "models", "    /// The container's room changed while building", "    mutating func reopen(at t: Double) { self.phase = .fresh }\n    /// The container's room changed while building"),
    ("tasks unwrapped", "window", '            COSBuildUp(.rows(6), tune: .tasks, loading: model.tasksLoading && model.tasks.isEmpty, landed: !model.tasks.isEmpty, failed: model.tasksError != nil,\n                       timeout: ControllerModel.tasksHelperTimeout + COSBuildUpPlan.helperMargin, label: "Loading tasks") {\n',
     "            Group {\n"),
    ("tasks spinner gone", "window", 'centeredProgress("Loading tasks…")', "ProgressView()"),
    ("tasks empty copy gone", "window", 'emptyState(.tasks, text: "No open tasks.', 'emptyState(.tasks, text: "Nothing.'),
    ("answer shape wrong", "ask", "COSBuildUp(.answer, loading:", "COSBuildUp(.rows(3), loading:"),
    ("answer loading not declared", "ask", "COSBuildUp(.answer, loading: !exchange.terminal", "COSBuildUp(.answer, waiting: !exchange.terminal"),
    ("Today running unwrapped", "window", 'label: "Reading sessions", background: TodayInk.runBg)', 'label: "Reading", background: TodayInk.runBg)'),
    ("a detail wrapper comes back", "views", 'ProgressView("Reading the transcript…")', 'ProgressView("Reading the transcript…"); let _ = #"label: "Loading record")"#'),
    ("speaker review lands on a spinner", "views", "landed: model.openReview != nil && !model.reviewLoading,", "landed: model.openReview != nil,"),
    ("sessions forget the search", "window", "interrupted: model.isSessionQueryActive, ", ""),
    ("memories lose their geometry", "window", "tune: isThread ? .threads : .memories, ", ""),
    ("an em dash in a label", "window", 'label: "Loading tasks")', 'label: "Loading — tasks")'),
    ("meetings chain moved", "meetings", "{ libraryContent }", "{ EmptyView() }"),
    ("version not bumped", "plist", "<key>CFBundleVersion</key>", "<key>CFBundleVersionNumber</key>"),
    # 0.5.345 (plan r3): the capped summary chains only 0.5.344, so these now act on 0.5.343's own section.
    ("What's New not chained", "whatsnew", "cards draw the outline of their rows while they load, then fill in", "cards fill in"),
    ("an em dash in What's New", "whatsnew", "cards draw the outline of their rows while they load, then fill in", "cards draw the outline of their rows while they load \\u2014 then fill in"),
    ("CHANGELOG not led", "changelog", "## 0.5.343 (build 397), Build-up, in place", "## 0.5.343, Build-up, in place"),
    ("0.5.343 not chained by a later release", "whatsnew", '"title": "0.5.343"', '"title": "0.5.343 build-up"'),
    ("lane not wired", "run", 'zsh "$ROOT/Tests/run-build-up.sh"', 'true "$ROOT/Tests/run-build-up.sh"'),
]

# Each mutant must fail the pin that names what it breaks, not just any pin.
EXPECTED = {'content removed while building': 'content always live', 'content shown under the wire': 'content always live', 'content not clickable after it lands': 'content always live', 'content read while building': 'content always live', 'the hand-off hides the content': 'never hides data', 'words never show': 'never hides data', 'an inline view reserves height': 'no extra height', 'the reservation outlives the build': 'no extra height', 'the wire draws past the view': 'wire hidden', 'wire takes clicks': 'wire hidden', 'wire visible to accessibility': 'wire hidden', 'no loading label': 'loading label', "the stage ignores the view's height": 'fit', 'reduce motion ignored mid-build': 'reduce motion', 'landed never fed': 'machine fed', 'an interruption never fed': 'machine fed', 'an early wake gives up': 'machine fed', 'a seen view builds again': 'memory', 'keyed views kept across launches': 'memory', 'empty views forgotten at quit': 'memory', 'a view taken away is not logged': 'abandoned', 'the clock never pauses': 'no idle cost', 'pulse in an inactive window': 'pulse gated', 'pulse always': 'pulse gated', 'the stage repeats': 'no idle cost', 'the wrapper reads the window': 'no idle cost', 'a refresh rewrites state': 'no idle cost', 'the landing restarts the draw': 'tokens', 'the stage skips the plan': 'tokens', 'an opaque tint': 'curtain light', 'an opaque fill': 'curtain light', 'one wire colour for every surface': 'tokens', 'breadcrumb holds text': 'breadcrumb', 'breadcrumb every change': 'breadcrumb', 'a dead reopen comes back': 'no dead code', 'tasks unwrapped': 'call site', 'tasks spinner gone': 'today inside', 'tasks empty copy gone': 'today inside', 'answer shape wrong': 'call site', 'answer loading not declared': 'call site', 'Today running unwrapped': 'call site', 'a detail wrapper comes back': 'call site', 'speaker review lands on a spinner': 'call site', 'sessions forget the search': 'call site', 'memories lose their geometry': 'call site', 'an em dash in a label': 'call site', 'meetings chain moved': 'call site', 'version not bumped': 'version', "What's New not chained": 'version', "an em dash in What's New": 'copy', 'CHANGELOG not led': 'version', '0.5.343 not chained by a later release': 'version', 'lane not wired': 'lane wired', 'a stacked fill': 'curtain light', 'data never clears the empty mark': 'empty cleared', 'errors kept as empty': 'failed', 'a tab switch is a refresh': 'relabel', 'the picker builds': 'call site', 'tasks give up before their helper': 'call site'}

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
        if f"pin failed [{EXPECTED.get(name)}]" not in str(e):
            sys.exit(f"pin self-test: mutant '{name}' failed another pin first ({e}); expected [{EXPECTED.get(name)}]")
        caught += 1
        print(f"KILLED  {name}  <- {e}")
        continue
    sys.exit(f"pin self-test: mutant '{name}' landed and every pin still passed")
print(f"PASS build up pins: one component, content always live and clickable once landed, the wire hidden and click-through, "
      f"the loading label, Reduce Motion, the session memory, the paused clock, the gated pulse, one source of truth, the breadcrumb, {len(SITES)} call sites with today's views inside, the version, the lane; "
      f"{caught} of {len(MUTANTS)} in-memory mutants caught")
