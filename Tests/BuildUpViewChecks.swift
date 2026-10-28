import AppKit
import SwiftUI

/// 0.5.343 Build-up, in place: the REAL COSBuildUp, live, hosted off screen and driven by wall-clock time while a loader
/// flips its state the way a call site's model does, and one REAL call site (the classic Activity window's Sessions list on
/// a ControllerModel with background work off). COSBuildUpProbe reports what COSBuildUpStage draws on every frame, from
/// inside its body (each component's look and the tint over the content), and what the wrapper hides, so these checks
/// watch the real view and state code run:
///   - a landing at 200 ms, 600 ms and 1.2 s never shows a wire that was not drawn, never hides the data, keeps the tint at
///     35% or less and gone by 300 ms, and stops drawing; a real Sessions list does the same and its text reads through
///     the tint on the pixels;
///   - in a key window the pulse runs and stops after its cycles; a slow load then draws no frames at all;
///   - a hand-off (an empty answer) never hides the content; a fast load draws nothing; an interrupted load settles quietly
///     and is not remembered as empty; an empty view stays quiet after a relaunch; a view taken away mid-build logs
///     abandoned;
///   - a 150 pt container fits its rows, a resize mid-build refits them, and nothing is drawn past the view;
///   - the answer draws inside today's one line and re-fits its lines to the real text; the inline views (the answer,
///     Today's two cards) are exactly today's height loading, empty and landed.
/// No window is ordered in, no event is sent, nothing becomes active. Prints "build up view: N checks".
@main @MainActor struct BuildUpViewChecks {
    static var ran = 0
    static func check(_ condition: Bool, _ behavior: String, _ detail: @autoclosure () -> String = "") {
        ran += 1
        if !condition { print("check failed [\(behavior)]: \(detail())"); exit(1) }
    }

    final class Loader: ObservableObject {
        @Published var loading = true
        @Published var landed = false
        @Published var interrupted = false
        @Published var height: CGFloat = 420
        @Published var gone = false
        @Published var failed = false
        @Published var label = ""
    }

    /// A pane whose content can be taken away (a navigation mid-build).
    struct Away: View {
        @ObservedObject var loader: Loader
        var body: some View {
            VStack { if !loader.gone { Host(loader: loader, shape: .rows(4), label: "Loading rows away") } }.frame(width: 520, height: 420)
        }
    }

    struct Host: View {
        @ObservedObject var loader: Loader
        let shape: COSBuildUpShape
        let label: String
        var body: some View {
            COSBuildUp(shape, loading: loader.loading && !loader.landed, landed: loader.landed, interrupted: loader.interrupted, failed: loader.failed,
                       label: loader.label.isEmpty ? label : loader.label) {
                if loader.landed {
                    VStack(spacing: 6) { ForEach(0..<4, id: \.self) { Text("Row \($0)").frame(maxWidth: .infinity).cosRowCard() } }
                        .padding(22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else if loader.loading {
                    ProgressView("Loading rows…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("No rows yet.").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 520, height: loader.height)
        }
    }

    /// A Meeting Ask exchange shaped as MeetingAsk.swift `answer` (0.5.353): the question, the Working line while it is
    /// written (outside the build-up), then the answer's COSBuildUp. The Working line's frame is kept for the wrap check.
    struct Answer: View {
        @ObservedObject var loader: Loader
        @MainActor static var working = CGRect.zero
        var body: some View {
            VStack(alignment: .leading, spacing: 9) {
                Text("A question").font(COSType.body(12, weight: .semibold))
                if loader.loading && !loader.landed {
                    Text(MeetingAskText.working).font(COSType.body(12)).foregroundStyle(.secondary)
                        .background(GeometryReader { g in Color.clear.onAppear { Answer.working = g.frame(in: .global) } })
                }
                COSBuildUp(.answer, loading: loader.loading && !loader.landed, landed: loader.landed, label: "Checking the meeting",
                           key: AnyHashable("view-check"), background: COSPalette.raised) {
                    if loader.landed {
                        Text(String(repeating: "The offer stays live through October 31 and the sign-ups are reviewed on Monday. ", count: 4))
                            .font(COSType.body(13)).fixedSize(horizontal: false, vertical: true)
                    } else if !loader.loading {
                        Text("No answer · failed").font(COSType.body(12)).foregroundStyle(.secondary)
                    } else {
                        Color.clear.frame(height: 0)
                    }
                }
                Text("Through 31:00").font(COSType.body(10.5))
            }
            .padding(12)
            .frame(width: 480)
        }
    }

    struct Run {
        var frames: [(t: Double, frame: COSBuildUpProbeFrame)] = []
        var hidden: [(t: Double, kind: String, hide: Bool)] = []
        var crumbs: [String] = []
        func phase(_ p: COSBuildUpMachine.Phase) -> [(t: Double, frame: COSBuildUpProbeFrame)] { frames.filter { $0.frame.phase == p } }
    }

    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Hosts `view` off screen for `seconds`, calling `act(t)` as the wall clock passes, collecting what the probes report.
    static func run(_ view: some View, key: Bool = false, for seconds: Double, act: (Double) -> Void = { _ in }) -> Run {
        var result = Run()
        let start = now()
        COSBuildUpProbe.stage = { result.frames.append((now() - start, $0)) }
        COSBuildUpProbe.wrapper = { result.hidden.append((now() - start, $0, $1)) }
        COSBuildUpProbe.breadcrumb = { result.crumbs.append($0) }
        defer { COSBuildUpProbe.stage = nil; COSBuildUpProbe.wrapper = nil; COSBuildUpProbe.breadcrumb = nil }
        let root = AnyView(view.environment(\.controlActiveState, key ? .key : .inactive).background(COSPalette.panel))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 520, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        defer { window.contentView = nil; window.close() }
        while now() - start < seconds {
            act(now() - start)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }
        return result
    }

    static func fresh() {
        COSBuildUpSession.memory = COSBuildUpMemory()
        UserDefaults.standard.removeObject(forKey: COSBuildUpSession.emptyKey)
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        fresh()
        // First, before any live view below is hosted: a hosted view that outlives its check still reports its stage.
        layoutLane()
        landings()
        realSessions()
        pulse()
        outcomes()
        fitting()
        answer()
        answerStill()
        answerEqual()
        answerCounts()
        heights()
        cover()
        geometry()
        print("build up view: \(ran) checks; the real stage and a real Sessions list drew, landed readable with no jump and stopped; "
              + "the pulse, the hand-off, the grace, interrupted, empty across a relaunch, abandoned, the fit, the answer, the heights")
    }

    /// The landing rules every live landing must keep, read from the frames the stage drew.
    static func landingRules(_ run: Run, _ name: String) {
        let drawn = run.frames.filter { $0.frame.phase == .building || $0.frame.phase == .landing }
        check(drawn.count >= 6, "live frames", "\(name): the stage drew \(drawn.count) frames")
        check(drawn.contains { $0.frame.phase == .landing } && drawn.contains { $0.frame.phase == .building }, "live frames", "\(name): built, then landed")
        if let first = drawn.first {
            let began = first.t - first.frame.drawT
            for (t, frame) in drawn {
                // The draw clock is the wall clock since the build began: never reset, never jumped ahead by a landing.
                check(abs(frame.drawT - (t - began)) < 0.06, "landing continuous", "\(name): the draw clock read \(frame.drawT) at \(t - began) s")
                let allowed = COSBuildUpPlan.look(0, drawT: t - began + 0.06, landT: nil).outline
                check((frame.looks.first?.outline ?? 0) <= allowed + 1e-9, "landing continuous",
                      "\(name): the outline showed \(frame.looks.first?.outline ?? 0), more than \(allowed) could have drawn")
            }
        }
        let landing = run.phase(.landing)
        if let land = landing.first?.t {
            for (t, frame) in landing {
                check(frame.curtains.allSatisfy { $0 <= COSBuildUpPlan.curtainAlpha + 1e-9 }, "curtain light", "\(name): a tint over \(COSBuildUpPlan.curtainAlpha)")
                if t - land > 0.33 { check(frame.curtains.allSatisfy { $0 < 1e-9 }, "curtain light", "\(name): a tint left \(t - land) s after the data") }
            }
            let hiddenAfter = run.hidden.filter { $0.t >= land - 0.001 && $0.hide && $0.kind == landing[0].frame.kind }
            check(hiddenAfter.isEmpty, "never hides data", "\(name): the content was hidden \(hiddenAfter.count) times after the data landed")
        }
        check((run.frames.last?.t ?? 0) < (landing.first?.t ?? 0) + COSBuildUpPlan.landDuration(count: 8) + 0.25, "frames stop",
              "\(name): frames still drawn at \(run.frames.last?.t ?? 0)")
    }

    // MARK: Landings at 200 ms, 600 ms and 1.2 s

    static func landings() {
        for (index, land) in [0.2, 0.6, 1.2].enumerated() {
            let loader = Loader()
            let at = COSBuildUpPlan.graceSeconds + land
            let run = run(Host(loader: loader, shape: .rows(4), label: "Loading rows \(index)"), for: at + 1.2) { t in
                if t >= at, !loader.landed { loader.landed = true }
            }
            landingRules(run, "land at \(land) s")
            check(run.crumbs.count == 1 && run.crumbs[0].hasPrefix("build-up rows outcome=landed rows="), "breadcrumb", "\(run.crumbs)")
            check(!run.crumbs[0].contains("Loading") && !run.crumbs[0].contains("Row"), "breadcrumb", "counts only: \(run.crumbs[0])")
        }
    }

    // MARK: A real call site: the classic Activity window's Sessions list

    static func sessionsModel(loaded: Bool) -> ControllerModel {
        let model = ControllerModel(startBackgroundWork: false)
        model.petEnabled = false
        model.claudeSessionsEnabled = true
        if loaded { fill(model) } else { model.claudeSessionsLoading = true }
        model.activityOpenSection = .sessions
        return model
    }

    static func fill(_ model: ControllerModel) {
        let iso = ISO8601DateFormatter().string(from: Date())
        model.claudeSessions = (0..<6).compactMap { ClaudeSession(.object(["id": .string("s\($0)"), "provider": .string("claude"), "name": .string("Session \($0)"),
                                                                            "state": .string("recent"), "updatedAt": .string(iso), "workspace": .string("MU-Chief-Staff")])) }
    }

    static func realSessions() {
        UserDefaults.standard.set(false, forKey: TodayHome.enabledKey)
        fresh()
        let model = sessionsModel(loaded: false)
        let at = COSBuildUpPlan.graceSeconds + 0.6
        let live = run(ActivityWindow(model: model).frame(width: 900, height: 700), for: at + 1.2) { t in
            if t >= at, model.claudeSessions.isEmpty { fill(model); model.claudeSessionsLoading = false }
        }
        landingRules(live, "real Sessions list")
        check(live.crumbs == live.crumbs.filter { $0.hasPrefix("build-up rows outcome=landed") } && live.crumbs.count == 1, "breadcrumb", "\(live.crumbs)")

        // The text reads through the tint from the first frame of the landing: the settled list's dark text pixels stay
        // dark in the frozen landing frame at t = 0.
        COSBuildUpProbe.freeze = nil
        let settled = bitmap(ActivityWindow(model: sessionsModel(loaded: true)))
        COSBuildUpProbe.freeze = COSBuildUpFrame(phase: .landing, drawT: 1.5, phaseT: 0)
        var frame = CGRect.zero
        COSBuildUpProbe.stage = { if $0.kind == "rows" { frame = $0.frame } }
        let landing = bitmap(ActivityWindow(model: sessionsModel(loaded: true)))
        COSBuildUpProbe.freeze = nil
        COSBuildUpProbe.stage = nil
        check(frame.height > 100, "curtain light", "the frozen landing drew the real list's wire: \(frame)")
        var text = 0, readable = 0
        let scale = CGFloat(settled.pixelsWide) / 900
        var y = Int(frame.minY * scale)
        while y < min(settled.pixelsHigh, Int(frame.maxY * scale)) {
            var x = Int((frame.minX + 30) * scale)
            while x < Int((frame.maxX - 30) * scale) {
                if luminance(settled, x, y) < 0.35 {
                    text += 1
                    if luminance(landing, x, y) < 0.55 { readable += 1 }
                }
                x += 3
            }
            y += 2
        }
        check(text > 200 && Double(readable) / Double(max(1, text)) > 0.9, "curtain light",
              "the real list's text reads through the tint at the landing's first frame: \(readable) of \(text) text pixels")
    }

    static func bitmap(_ view: some View) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(view.frame(width: 900, height: 700).background(COSPalette.panel)))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua); host.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
        host.displayIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.close()
        return rep
    }

    static func luminance(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Double {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 1 }
        return Double(0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
    }

    // MARK: The pulse in a key window, then a still wire

    static func pulse() {
        let loader = Loader()
        let run = run(Host(loader: loader, shape: .rows(4), label: "Loading rows slow"), key: true, for: 6.6) { t in
            if t >= 6.2, !loader.landed { loader.landed = true }
        }
        let pulsing = run.frames.filter { $0.frame.pulsing && $0.frame.phase == .building }
        check(pulsing.count >= 30, "pulse runs", "a key window pulses while it loads: \(pulsing.count) frames")
        check(pulsing.allSatisfy { $0.frame.drawT < COSBuildUpPlan.pulseSeconds + 0.05 }, "pulse stops", "no pulse past its cycles")
        let still = run.frames.filter { $0.t > COSBuildUpPlan.graceSeconds + COSBuildUpPlan.pulseSeconds + 0.3 && $0.t < 6.15 }
        check(still.isEmpty, "frames stop", "\(still.count) frames while the wire stood still waiting")
        check(run.hidden.contains { !$0.hide && $0.t > COSBuildUpPlan.graceSeconds + COSBuildUpPlan.wordsSeconds + 0.05 && $0.t < 6.1 }, "words",
              "today's loading words show after 3 s")
        let late = run.frames.filter { $0.frame.phase == .building && $0.frame.drawT > COSBuildUpPlan.wordsFadeStep.end + 0.05 }
        check(late.allSatisfy { $0.frame.looks.allSatisfy { $0.textShown < 1e-6 } }, "words", "the wire text is gone once the words show")
        check(run.phase(.landing).count > 0, "live frames", "it still lands")
    }

    // MARK: Outcomes: the hand-off, the grace, interrupted, empty across a relaunch, abandoned

    static func outcomes() {
        // An empty answer: the wire fades over the empty view, which shows at once.
        let empty = Loader()
        let gone = run(Host(loader: empty, shape: .rows(4), label: "Loading rows empty"), for: 1.6) { t in
            if t >= 0.6, empty.loading { empty.loading = false }
        }
        let handoff = gone.phase(.handoff)
        check(!handoff.isEmpty, "error handoff", "the wire faded out")
        if let start = handoff.first?.t {
            check(!gone.hidden.contains { $0.t >= start - 0.001 && $0.hide }, "never hides data", "the empty view was hidden during the hand-off")
        }
        check((gone.frames.last?.t ?? 0) < 1.3, "frames stop", "frames still drawn at \(gone.frames.last?.t ?? 0)")
        check(gone.crumbs.count == 1 && gone.crumbs[0].hasPrefix("build-up rows outcome=empty"), "breadcrumb", "\(gone.crumbs)")
        check(UserDefaults.standard.stringArray(forKey: COSBuildUpSession.emptyKey) == ["Loading rows empty|"], "empty remembered",
              "\(String(describing: UserDefaults.standard.stringArray(forKey: COSBuildUpSession.emptyKey)))")

        // A relaunch: the session forgets what it saw, the empty list comes back from UserDefaults, and the view stays quiet.
        COSBuildUpSession.memory = COSBuildUpMemory(empty: UserDefaults.standard.stringArray(forKey: COSBuildUpSession.emptyKey) ?? [])
        let again = Loader()
        let relaunch = run(Host(loader: again, shape: .rows(4), label: "Loading rows empty"), for: 1.0) { t in
            if t >= 0.6, again.loading { again.loading = false }
        }
        check(relaunch.frames.isEmpty && relaunch.crumbs.isEmpty, "empty remembered", "an empty view drew \(relaunch.frames.count) frames after a relaunch")

        // A load inside the grace draws nothing.
        let fast = Loader()
        let quick = run(Host(loader: fast, shape: .rows(4), label: "Loading rows fast"), for: 0.6) { t in
            if t >= 0.05, !fast.landed { fast.landed = true }
        }
        check(quick.frames.isEmpty, "grace skips build", "a fast load drew \(quick.frames.count) frames")
        check(quick.crumbs.count == 1 && quick.crumbs[0].hasPrefix("build-up rows outcome=direct"), "breadcrumb", "\(quick.crumbs)")

        // A search during the first load: settles quietly, never remembered as empty, and the view may build next time.
        let search = Loader()
        let interrupted = run(Host(loader: search, shape: .rows(4), label: "Loading rows search"), for: 1.2) { t in
            if t >= 0.6, !search.interrupted { search.interrupted = true }
        }
        check(interrupted.crumbs.count == 1 && interrupted.crumbs[0].hasPrefix("build-up rows outcome=interrupted"), "interrupted", "\(interrupted.crumbs)")
        check(!(UserDefaults.standard.stringArray(forKey: COSBuildUpSession.emptyKey) ?? []).contains("Loading rows search|")
              && COSBuildUpSession.memory.builds("Loading rows search|"), "interrupted", "an interrupted load is not remembered")
        check(!interrupted.hidden.contains { $0.t > 0.62 && $0.hide }, "interrupted", "the search results are never hidden")

        // A view taken away mid-build: one breadcrumb, abandoned.
        let away = Loader()
        let abandoned = run(Away(loader: away), for: 0.9) { t in
            if t >= 0.6, !away.gone { away.gone = true }
        }
        check(abandoned.crumbs.count == 1 && abandoned.crumbs[0].hasPrefix("build-up rows outcome=abandoned"), "abandoned", "\(abandoned.crumbs)")

        // The empty view has data again: it opened quiet (no frames), and its data clears the mark, so the next launch builds.
        let back = Loader()
        let data = run(Host(loader: back, shape: .rows(4), label: "Loading rows empty"), for: 0.9) { t in
            if t >= 0.4, back.loading { back.landed = true }
        }
        check(data.frames.isEmpty, "empty remembered", "the remembered view stayed quiet: \(data.frames.count) frames")
        check(!(UserDefaults.standard.stringArray(forKey: COSBuildUpSession.emptyKey) ?? []).contains("Loading rows empty|"), "empty cleared",
              "data clears the mark: \(String(describing: UserDefaults.standard.stringArray(forKey: COSBuildUpSession.emptyKey)))")
        COSBuildUpSession.memory = COSBuildUpMemory(empty: UserDefaults.standard.stringArray(forKey: COSBuildUpSession.emptyKey) ?? [])
        let rebuilt = Loader()
        let builds = run(Host(loader: rebuilt, shape: .rows(4), label: "Loading rows empty"), for: 1.2) { t in
            if t >= 0.6, !rebuilt.landed { rebuilt.landed = true }
        }
        check(!builds.frames.isEmpty && builds.crumbs.first?.hasPrefix("build-up rows outcome=landed") == true, "empty cleared",
              "the next launch builds again: \(builds.frames.count) frames, \(builds.crumbs)")

        // A failed load: handed off as failed, never kept as empty.
        let broken = Loader()
        let failed = run(Host(loader: broken, shape: .rows(4), label: "Loading rows failed"), for: 1.2) { t in
            if t >= 0.6, broken.loading { broken.failed = true; broken.loading = false }
        }
        check(failed.crumbs.count == 1 && failed.crumbs[0].hasPrefix("build-up rows outcome=failed"), "failed", "\(failed.crumbs)")
        check(!(UserDefaults.standard.stringArray(forKey: COSBuildUpSession.emptyKey) ?? []).contains("Loading rows failed|"), "failed",
              "an error is never kept as empty")

        // A tab switch mid-build (To review and Recent learning share a place): the old load is interrupted, the new one opens.
        let tabs = Loader()
        tabs.label = "Loading tab one"
        let switched = run(Host(loader: tabs, shape: .rows(4), label: ""), for: 1.4) { t in
            if t >= 0.5, tabs.label == "Loading tab one" { tabs.label = "Loading tab two" }
            if t >= 1.0, !tabs.landed { tabs.landed = true }
        }
        check(switched.crumbs.first?.hasPrefix("build-up rows outcome=interrupted") == true && switched.crumbs.count == 2
              && switched.crumbs[1].hasPrefix("build-up rows outcome=landed"), "relabel", "\(switched.crumbs)")
        check(!(UserDefaults.standard.stringArray(forKey: COSBuildUpSession.emptyKey) ?? []).contains { $0.hasPrefix("Loading tab") }, "relabel",
              "a switch is never kept as empty")

        // A view this session has seen (the one that just built again after the relaunch) reopens quietly.
        let seen = Loader()
        let quiet = run(Host(loader: seen, shape: .rows(4), label: "Loading rows empty"), for: 1.0) { t in
            if t >= 0.6, !seen.landed { seen.landed = true }
        }
        check(quiet.frames.isEmpty && quiet.crumbs.isEmpty, "reopen quiet", "a seen view built again: \(quiet.frames.count) frames, \(quiet.crumbs)")
    }

    // MARK: The fit: a 150 pt container, a resize mid-build, nothing past the view

    static func fitting() {
        let loader = Loader()
        loader.height = 150
        let run = run(Host(loader: loader, shape: .rows(6), label: "Loading rows short"), for: 1.6) { t in
            if t >= 0.8, loader.height == 150 { loader.height = 330 }
            if t >= 1.3, !loader.landed { loader.landed = true }
        }
        let short = run.frames.filter { $0.t < 0.75 && $0.frame.phase == .building }
        let tall = run.frames.filter { $0.t > 1.0 && $0.frame.phase == .building }
        // 0.5.353: a pane fills its height, the last row clipped as a scrolled list shows it (12 + 68 + 68 = 148 < 150).
        check(!short.isEmpty && short.allSatisfy { $0.frame.rects.count == 3 }, "fit", "a 150 pt container draws 3 rows: \(short.map(\.frame.rects.count))")
        check(!tall.isEmpty && tall.allSatisfy { $0.frame.rects.count == 5 }, "fit", "resized to 330 pt it draws 5: \(tall.map(\.frame.rects.count))")
        check(run.frames.allSatisfy { f in f.frame.rects.allSatisfy { $0.minY < f.frame.size.height } }, "fit", "a row that starts past the view")
    }

    // MARK: The answer: inside today's one line, re-fit to the real text

    static func answer() {
        let history = COSBuildUpSession.answers
        let loader = Loader()
        let run = run(Answer(loader: loader), for: 1.4) { t in
            if t >= 0.75, !loader.landed { loader.landed = true }
        }
        // Before the answer arrives (the loader flips at 0.75 s; the frame in flight then may already lay out the answer).
        let building = run.phase(.building).filter { $0.t < 0.74 && $0.frame.kind == "answer" }, landing = run.phase(.landing).filter { $0.frame.kind == "answer" }
        // 0.5.353, the approved phone spec: the answer-shaped block (the 16-line cycle), the session's block height, across the card.
        let reserve = COSBuildUpPlan.answerBlock(history)
        check(!building.isEmpty && building.allSatisfy { abs($0.frame.size.height - reserve) < 0.5 && $0.frame.lines == [16] && $0.frame.size.width > 440 && $0.frame.wired }, "answer size",
              "the answer reserves its block across the card: \(building.filter { !(abs($0.frame.size.height - reserve) < 0.5 && $0.frame.lines == [16] && $0.frame.size.width > 440) }.map { "\($0.frame.size) \($0.frame.lines)" }.prefix(6)) of \(building.count)")
        // The wire wraps the block, never the Working line: the stage starts below the line.
        check(Answer.working.height > 8 && building.allSatisfy { $0.frame.frame.minY >= Answer.working.maxY - 0.5 }, "answer wraps block",
              "Working line \(Answer.working), wire tops \(Set(building.map { $0.frame.frame.minY }))")
        check(!landing.isEmpty && landing.allSatisfy { $0.frame.lines.first ?? 0 >= 4 && $0.frame.size.height > 60 }, "answer refit",
              "landed, the wire re-fits to the real text's lines: \(landing.filter { !(($0.frame.lines.first ?? 0) >= 4 && $0.frame.size.height > 60) }.map { "\($0.frame.size.height) \($0.frame.lines)" }.prefix(6)) of \(landing.count)")
    }

    /// The running card is the answered card's height (glasses 6.10.666's rule, in points): a card shaped as MeetingAsk.swift
    /// `answer` with the Working line and the frozen block, against the same card answered with a body of the typical height,
    /// at the default and at both clamp ends (a typical of 120 and of 480).
    static func answerEqual() {
        struct Card: View {
            let running: Bool
            let body_: Double
            var body: some View {
                VStack(alignment: .leading, spacing: 9) {
                    Text("What did we decide about the October offer?").font(COSType.body(12, weight: .semibold))
                    if running { Text(MeetingAskText.working).font(COSType.body(12)).foregroundStyle(.secondary) }
                    COSBuildUp(.answer, loading: running, landed: !running, label: "Checking the meeting", key: AnyHashable("equal"), background: COSPalette.raised,
                               frozen: running ? COSBuildUpFrame(phase: .building, drawT: 1.4) : nil) {
                        if running { Color.clear.frame(height: 0) } else { Color.clear.frame(height: CGFloat(body_)) }
                    }
                    Text("Through 31:00 · Claude Sonnet").font(COSType.body(10.5))
                }
                .padding(12)
                .frame(width: 480)
            }
        }
        func height(_ v: some View) -> CGFloat { NSHostingView(rootView: AnyView(v)).fittingSize.height }
        for history in [[Double](), [40], [900]] {
            COSBuildUpSession.forgetAnswers()
            for (i, h) in history.enumerated() { COSBuildUpSession.recordAnswer("h\(i)", height: h) }
            let typical = COSBuildUpPlan.answerBody(history)
            let running = height(Card(running: true, body_: 0)), answered = height(Card(running: false, body_: typical))
            check(abs(running - answered) <= 1, "answer equal", "typical \(typical): running card \(running) pt, answered card \(answered) pt")
            print("answer card typical \(Int(typical)): running \(String(format: "%.1f", running)) pt, answered \(String(format: "%.1f", answered)) pt")
        }
        COSBuildUpSession.forgetAnswers()
    }

    /// A completed answer's body is kept for the next answer's block; a failed or stopped one is not (COSBuildUpPlan.countsAnswer,
    /// through the same cosAnswerBody the real card uses).
    static func answerCounts() {
        COSBuildUpSession.forgetAnswers()
        for (key, status, failed, height) in [("done", "completed", false, 210.0), ("stopped", "cancelled", false, 400.0), ("failed", "completed", true, 90.0)] {
            _ = bitmap(VStack { Color.clear.frame(width: 300, height: CGFloat(height))
                .cosAnswerBody(key: key, counts: COSBuildUpPlan.countsAnswer(status: status, failed: failed)) }, size: CGSize(width: 320, height: 500))
        }
        check(COSBuildUpSession.answers == [210], "answer counts", "kept \(COSBuildUpSession.answers): only the completed answer")
        COSBuildUpSession.forgetAnswers()
    }

    /// Reduce Motion (0.5.353, the approved spec): the reserved block stays, drawn still, while the answer is written; no
    /// clock, no pulse, no wire animation.
    static func answerStill() {
        COSBuildUpProbe.reduceMotion = true
        defer { COSBuildUpProbe.reduceMotion = nil }
        COSBuildUpSession.forgetAnswers()
        let loader = Loader()
        let run = run(Answer(loader: loader), for: 0.9)
        let frames = run.frames.filter { $0.frame.kind == "answer" }
        check(!frames.isEmpty && frames.allSatisfy { $0.frame.phase == .building && $0.frame.drawT == COSBuildUpPlan.stillDrawT && !$0.frame.pulsing && !$0.frame.wired },
              "answer still", "\(frames.count) frames: \(Set(frames.map { "\($0.frame.phase) \($0.frame.drawT) pulse \($0.frame.pulsing) wired \($0.frame.wired)" }))")
        check(frames.allSatisfy { abs($0.frame.size.height - COSBuildUpPlan.answerBlock([])) < 0.5 && $0.frame.lines == [16] }, "answer still",
              "the still block keeps its reservation: \(Set(frames.map { "\($0.frame.size.height) \($0.frame.lines)" }))")
        check(run.hidden.allSatisfy { !$0.hide }, "answer still", "nothing is hidden under Reduce Motion")
    }

    // MARK: The inline views: their reservation while they build, today's height once the build ends (0.5.353)

    static func heights() {
        func height(_ view: some View) -> CGFloat { NSHostingView(rootView: AnyView(view.frame(width: 480))).fittingSize.height }
        let sites: [(String, COSBuildUpShape, COSBuildUpTune, Color, [(String, AnyView)])] = [
            ("answer", .answer, .none, COSPalette.raised, [
                ("loading", AnyView(Color.clear.frame(height: 0))),
                ("empty", AnyView(Text("No answer · failed").font(COSType.body(12)))),
                ("typical", AnyView(Text(String(repeating: "The offer stays live through October 31. ", count: 5)).font(COSType.body(13)).fixedSize(horizontal: false, vertical: true))),
            ]),
            ("needs you", .cardRows(2, badge: false), .needsYou, COSPalette.card, [
                ("loading", AnyView(VStack(alignment: .leading, spacing: 0) { Text(TodayHome.loadingLine).font(COSType.body(13.5)).padding(.horizontal, 18).padding(.bottom, 18) }.frame(maxWidth: .infinity, alignment: .leading))),
                ("empty", AnyView(VStack(alignment: .leading, spacing: 0) { VStack(alignment: .leading, spacing: 6) { Text(TodayHome.caughtUpLine).font(COSType.display(20)); Text("Checked at 9:41.").font(COSType.body(12)) }.padding(.horizontal, 18).padding(.bottom, 18) }.frame(maxWidth: .infinity, alignment: .leading))),
                ("typical", AnyView(VStack(alignment: .leading, spacing: 0) { ForEach(0..<3, id: \.self) { _ in VStack(alignment: .leading, spacing: 3) { Text("Name 2 voices").font(COSType.body(14, weight: .semibold)); Text("Speakers").font(COSType.body(12.5)) }.padding(.horizontal, 18).padding(.vertical, 12) } }.frame(maxWidth: .infinity, alignment: .leading))),
            ]),
            ("running", .cardRows(2, badge: true), .running, COSPalette.ink, [
                ("loading", AnyView(VStack(alignment: .leading, spacing: 0) { Text("Reading sessions").font(COSType.body(13.5)).padding(.top, 4).padding(.bottom, 10) }.frame(maxWidth: .infinity, alignment: .leading))),
                ("empty", AnyView(VStack(alignment: .leading, spacing: 0) { Text("Nothing is running.").font(COSType.body(13.5)).padding(.top, 4).padding(.bottom, 10) }.frame(maxWidth: .infinity, alignment: .leading))),
                ("typical", AnyView(VStack(alignment: .leading, spacing: 0) { ForEach(0..<2, id: \.self) { _ in HStack { Text("CLAUDE").frame(width: 84); Text("Holiday promo landing page").font(COSType.body(14, weight: .semibold)) }.padding(.vertical, 10) } }.frame(maxWidth: .infinity, alignment: .leading))),
            ]),
        ]
        for (name, shape, tune, background, states) in sites {
            let reserve = CGFloat(COSBuildUpPlan.reserve(shape, tune, answers: COSBuildUpSession.answers) ?? 0)
            for (state, content) in states {
                let today = height(content)
                var seen: [CGFloat] = []
                for frame in [COSBuildUpFrame(phase: .grace, drawT: 0), .init(phase: .building, drawT: 1.4), .init(phase: .building, drawT: 3.5),
                              .init(phase: .landing, drawT: 2, phaseT: 0.1), .init(phase: .handoff, drawT: 2, phaseT: 0.1)] {
                    let built = height(COSBuildUp(shape, tune: tune, loading: true, landed: false, label: "Heights", background: background, frozen: frame) { content })
                    // Building (the grace and the wire): the reservation, or today's view where that is taller. Landed or handed
                    // off: exactly today's view, so an empty or failed answer never keeps a full-height skeleton.
                    let want = frame.phase == .grace || frame.phase == .building ? max(today, reserve) : today
                    check(abs(built - want) < 0.5, frame.phase == .grace || frame.phase == .building ? "reserve height" : "no extra height",
                          "\(name) \(state) \(frame.phase): today \(today) pt, reserve \(reserve) pt, drawn \(built) pt")
                    seen.append(built)
                }
                if name == "needs you", state == "loading" {
                    var width: CGFloat = 0
                    COSBuildUpProbe.stage = { width = $0.rects.first?.width ?? 0 }
                    _ = bitmap(COSBuildUp(shape, tune: tune, loading: true, landed: false, label: "Heights", background: background, frozen: .init(phase: .building, drawT: 1.4)) { content }
                        .frame(width: 480).frame(maxHeight: .infinity, alignment: .top), size: CGSize(width: 480, height: 200))
                    COSBuildUpProbe.stage = nil
                    check(width > 400, "needs you width", "the Needs you wire spans the card, not just its words: \(width) pt")
                }
                print("height \(name) \(state): today \(String(format: "%.1f", today)) pt; built \(seen.map { String(format: "%.1f", $0) }.joined(separator: " / ")) pt (grace / wire / words / landing / hand-off)")
            }
        }
    }

    // MARK: The tint as drawn: one layer, never more than 35%, read on the pixels at landT 0.03 s

    static func cover() {
        // Black content under a white surface: a grey pixel's luminance is the cover drawn over the content there.
        let host = COSBuildUp(.rows(4), loading: true, landed: false, label: "Cover", background: .white,
                              frozen: COSBuildUpFrame(phase: .landing, drawT: 2, phaseT: 0.03)) { Color.black }
        let view = AnyView(host.frame(width: 520, height: 420).environment(\.colorScheme, .light))
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 520, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua); hosting.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.08)); hosting.layoutSubtreeIfNeeded() }
        hosting.displayIfNeeded()
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.contentView = nil
        window.close()
        var most = 0.0, grey = 0
        var buckets = [Int](repeating: 0, count: 10)
        let scale = CGFloat(rep.pixelsWide) / 520
        // Clear of the corner nodes and the spine: from 30 pt inside the rows' left edge to 30 pt inside their right.
        let x0 = Int((22 + 30) * scale), x1 = Int((520 - 22 - 30) * scale)
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: x0, to: x1, by: 2) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // The wire's lines are tinted gold or brown; the tint over black is grey.
                guard abs(c.redComponent - c.blueComponent) < 0.02, abs(c.redComponent - c.greenComponent) < 0.02 else { continue }
                let lum = Double(0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
                // The wire's corner and junction nodes are filled with the surface (white here): left out.
                guard lum < 0.9 else { continue }
                grey += 1
                buckets[min(9, Int(lum * 10))] += 1
                most = max(most, lum)
            }
        }
        // The reference: the same pipeline drawing ONE white layer at the tint's alpha over black. Two layers stacked (the
        // surface and the card fill each at 35%) would draw about 58% instead.
        let reference = bitmap(ZStack { Color.black; Color.white.opacity(COSBuildUpPlan.curtainAlpha) }, size: CGSize(width: 40, height: 40))
        let one = luminance(reference, reference.pixelsWide / 2, reference.pixelsHigh / 2)
        let limit = one + 0.03
        check(grey > 1000 && most > one - 0.05 && most <= limit, "curtain light", "the cover drawn reaches \(most) (one layer at the tint draws \(one), limit \(limit)) over \(grey) grey pixels; by tenths \(buckets)")
    }

    // MARK: Geometry parity: the wire's rows against the real rows, on the pixels of the real Activity window

    struct Site { let name: String; let section: ActivitySection; let kind: String; let fill: (ControllerModel) -> Void; let dividers: Bool }

    static func geometry() {
        UserDefaults.standard.set(false, forKey: TodayHome.enabledKey)
        let now = Date()
        func iso(_ m: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(-m * 60)) }
        let day = String(iso(0).prefix(10))
        let sites = [
            Site(name: "meetings", section: .meetings, kind: "rows", fill: { model in
                model.libraryMonth = String(day.prefix(7))
                model.libraryMeetings = (0..<8).compactMap { LibraryMeeting(.object(["filename": .string("\(day)_M_\($0).md"), "month": .string(String(day.prefix(7))),
                                                                                       "domain": .string("quilt"), "title": .string("Meeting \($0)"), "date": .string(day)])) }
            }, dividers: false),
            Site(name: "sessions", section: .sessions, kind: "rows", fill: { model in
                model.claudeSessionsEnabled = true
                model.claudeSessions = (0..<8).compactMap { ClaudeSession(.object(["id": .string("s\($0)"), "provider": .string("claude"), "name": .string("Session \($0)"),
                                                                                    "state": .string("recent"), "updatedAt": .string(iso(Double($0 * 30))), "workspace": .string("MU-Chief-Staff")])) }
            }, dividers: false),
            Site(name: "memories", section: .memories, kind: "rows", fill: { model in
                model.memoryRecords = (0..<8).map { ContextRecord.memory(["id": .string("m\($0)"), "content": .string("Memory number \($0) about the October offer"),
                                                                          "created_at": .string(iso(Double($0 * 60)))]) }
            }, dividers: false),
            Site(name: "threads", section: .threads, kind: "rows", fill: { model in
                // 0.5.353: a realistic thread row, with its meetings and topics line.
                model.threadRecords = (0..<8).map { (i: Int) -> ContextRecord in
                    let raw: [String: JSONValue] = ["id": .string("th\(i)"), "name": .string("Thread \(i)"), "meeting_count": .number(Double(3 + i)),
                                                    "topics": .array([.string("organic decline"), .string("redirects")]), "last_seen": .string(iso(Double(i * 90)))]
                    return ContextRecord.thread(raw)
                }
            }, dividers: false),
            Site(name: "messages", section: .messages, kind: "list", fill: { model in
                model.recentMessages = (0..<8).map { GlassesTurn(id: "g\($0)", no: 300 - $0, timestamp: now.addingTimeInterval(Double(-$0) * 3600).timeIntervalSince1970,
                                                                 query: "Question \($0)", text: "", sessionId: "s", source: "G2") }
                model.recentGlassesStatus = .ready
            }, dividers: true),
        ]
        for site in sites {
            func window() -> some View {
                let model = ControllerModel(startBackgroundWork: false)
                model.petEnabled = false
                var status = model.status
                status.running = true; status.memoryAvailable = true; status.memoryCount = 412; status.threadsAvailable = true; status.threadCount = 66
                model.status = status
                site.fill(model)
                model.activityOpenSection = site.section
                return ActivityWindow(model: model).frame(width: 900, height: 1100)
            }
            var probe: COSBuildUpProbeFrame?
            COSBuildUpProbe.stage = { if $0.kind == site.kind { probe = $0 } }
            COSBuildUpProbe.freeze = COSBuildUpFrame(phase: .landing, drawT: 2, phaseT: 0)
            _ = bitmap(window(), size: CGSize(width: 900, height: 1100))
            COSBuildUpProbe.freeze = nil
            COSBuildUpProbe.stage = nil
            let rep = bitmap(window(), size: CGSize(width: 900, height: 1100))
            guard let probe else { check(false, "geometry parity", "\(site.name): no build-up on screen"); continue }
            let scale = CGFloat(rep.pixelsWide) / 900
            let wire = probe.rects.prefix(4).map { (Double($0.minY), Double($0.height)) }
            let real = site.dividers ? dividedRows(rep, scale: scale, frame: probe.frame) : cardRows(rep, scale: scale, frame: probe.frame)
            func fmt(_ list: [(Double, Double)]) -> String { list.prefix(4).map { "y\(Int($0.0.rounded())) h\(Int($0.1.rounded()))" }.joined(separator: ", ") }
            print("geometry \(site.name): real \(fmt(real)) | wire \(fmt(wire))")
            check(real.count >= 4 && wire.count >= 3, "geometry parity", "\(site.name): rows found \(real.count), wire \(wire.count)")
            for (r, w) in zip(real, wire) {
                check(abs(r.0 - w.0) <= 1.01 && abs(r.1 - w.1) <= 1.01, "geometry parity", "\(site.name): real \(fmt(real)) vs wire \(fmt(wire))")
            }
        }
    }

    // MARK: 0.5.353 The skeleton is the loaded view's geometry, per site, window and appearance

    /// Every build-up site (Tests/BuildUpSites.swift) at a 760 and a 1280 pt window, light and dark: the skeleton's frame
    /// against the loaded content's (x, width and top within 1 pt: no header jump), its rows against the real rows (x,
    /// right edge and height within 1 pt, where the rows can be read), and the height it fills against the loaded view's
    /// (a pane: within one row pitch of the loaded rows' bottom; an inline view: within one row, an answer two lines).
    /// `COS_BUILD_UP_LAYOUT_SITES=a,b` narrows it (the mutation lane uses the full set).
    static func layoutLane() {
        let only = ProcessInfo.processInfo.environment["COS_BUILD_UP_LAYOUT_SITES"].map { Set($0.split(separator: ",").map(String.init)) }
        _ = BuildUpSites.railWidth(CGSize(width: 760, height: 900)); _ = BuildUpSites.railWidth(CGSize(width: 1280, height: 900))
        var measured = 0
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for size in [CGSize(width: 760, height: 900), CGSize(width: 1280, height: 900)] {
                for site in BuildUpSites.all() where only == nil || only!.contains(site.name) {
                    guard let m = try? BuildUpSites.measure(site, size: size, appearance: appearance, out: nil) else {
                        check(false, "geometry width", "\(site.name): the measure threw"); continue
                    }
                    measured += 1
                    let tag = "\(site.name) \(m.width) \(m.theme)"
                    check(m.skFrame.count == 4 && m.ldFrame.count == 4, "geometry width", "\(tag): \(m.note)")
                    guard m.skFrame.count == 4, m.ldFrame.count == 4 else { continue }
                    // An answer's wrapped text measures its longest line, so the loaded frame may end up to a word short of the
                    // card; the skeleton spans the card, as the text wraps in it.
                    let narrower = site.kind == "answer" ? 48.0 : 1
                    check(abs(m.skFrame[0] - m.ldFrame[0]) <= 1 && m.ldFrame[2] <= m.skFrame[2] + 1 && m.skFrame[2] - m.ldFrame[2] <= narrower, "geometry width",
                          "\(tag): skeleton x \(m.skFrame[0]) w \(m.skFrame[2]), loaded x \(m.ldFrame[0]) w \(m.ldFrame[2])")
                    // An answer's block sits under its Working line, where the answer's second line of room begins: the
                    // answer itself starts where the Working line stood.
                    let lead = site.kind == "answer" ? COSBuildUpPlan.answerWorking : 0
                    check(abs(m.skFrame[1] - lead - m.ldFrame[1]) <= 1, "geometry top", "\(tag): skeleton top \(m.skFrame[1]) less \(lead), loaded \(m.ldFrame[1])")
                    if site.rows != .ink {
                        check(m.ldRows >= 3 && m.skRows >= 3, "geometry rows", "\(tag): rows read \(m.ldRows), drawn \(m.skRows)")
                        let x = m.ldRowX - site.ruleInset, right = m.ldRowX + m.ldRowW
                        check(abs(m.skRowX - x) <= 1 && abs(m.skRowX + m.skRowW - right) <= 1, "geometry width",
                              "\(tag): skeleton rows \(m.skRowX) to \(m.skRowX + m.skRowW), loaded \(x) to \(right)")
                        // Realistic rows vary (one or two line titles, answers or none): the skeleton's row sits inside the
                        // real rows' range, and a card list's first row starts where the real one does.
                        check(m.ldMaxH > 0 && m.skRowH >= m.ldMinH - 1.01 && m.skRowH <= m.ldMaxH + 1.01, "geometry rows",
                              "\(tag): skeleton rows \(m.skRowH) pt, real rows \(m.ldMinH) to \(m.ldMaxH) pt")
                        if site.rows == .cards {
                            check(abs((m.skBoxes.first?[1] ?? -99) - m.ldTop) <= 1.01, "geometry rows", "\(tag): skeleton first row at \(m.skBoxes.first?[1] ?? -1), real at \(m.ldTop)")
                        }
                    }
                    if site.rows == .ink, site.kind == "turns" || site.kind == "summary" {
                        // A detail's body: its text and cards end inside the skeleton's rows, within a word of their edge.
                        let right = m.skRowX + m.skRowW
                        check(m.ldInkRight > 0 && m.ldInkRight <= right + 1 && right - m.ldInkRight <= 48, "geometry width",
                              "\(tag): skeleton rows end at \(right), the body's ink at \(m.ldInkRight)")
                    }
                    let fills = site.kind != "cardRows" && site.kind != "answer"
                    if fills {
                        let pitch = max(m.skPitch, m.ldPitch, m.skRowH)
                        let sk = min(m.skExtent, m.skFrame[3]), ld = min(m.ldExtent, m.ldFrame[3])
                        check(abs(sk - ld) <= pitch + 1, "geometry height", "\(tag): skeleton fills to \(sk) pt, loaded to \(ld) pt (band \(pitch))")
                    } else {
                        // An answer: the block plus its Working line against one typical answer's body, within 30% of that
                        // body (the block is the session's typical answer, not this one). Today's cards: within one row.
                        if site.kind == "answer" {
                            // An answer's block is the session's typical answer (the default here, nothing has completed), not
                            // this one; that the running card is the answered card is answerEqual's check.
                            check(abs(m.skFrame[3] - COSBuildUpPlan.answerBlock([])) <= 0.5, "geometry height",
                                  "\(tag): the block \(m.skFrame[3]) pt, the default \(COSBuildUpPlan.answerBlock([])) pt")
                        } else {
                            check(abs(m.skFrame[3] - m.ldFrame[3]) <= m.skRowH + 1, "geometry height",
                                  "\(tag): skeleton \(m.skFrame[3]) pt, loaded \(m.ldFrame[3]) pt (band one row, \(m.skRowH))")
                        }
                    }
                }
            }
        }
        check(only != nil || measured >= 48, "geometry width", "measured \(measured) site cases")
        print("layout lane: \(measured) site cases (sites x 760/1280 x light/dark)")
    }

    static func bitmap(_ view: some View, size: CGSize) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: AnyView(view.background(COSPalette.panel)))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua); host.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
        host.displayIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        window.close()
        return rep
    }

    /// Runs of card fill down the middle of the wire's frame: each run is a row card (top and height in points from the
    /// frame's top).
    static func cardRows(_ rep: NSBitmapImageRep, scale: CGFloat, frame: CGRect) -> [(Double, Double)] {
        let x = Int((frame.minX + frame.width * 0.5) * scale)
        let top = Int(frame.minY * scale)
        var rows: [(Double, Double)] = []
        var start: Int?
        for y in top..<min(rep.pixelsHigh, Int(frame.maxY * scale)) {
            let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            let white = (c?.redComponent ?? 0) > 0.985 && (c?.greenComponent ?? 0) > 0.985 && (c?.blueComponent ?? 0) > 0.985
            if white, start == nil { start = y }
            if !white, let s = start { rows.append((Double(CGFloat(s - top) / scale), Double(CGFloat(y - s) / scale))); start = nil }
        }
        return rows.filter { $0.1 > 12 }
    }

    /// A divided list: the 1 pt rules between rows, found where three points across the right half are all a little darker
    /// than the surface. Each row runs from the rule above it (or the first rule less a row) to the rule below.
    static func dividedRows(_ rep: NSBitmapImageRep, scale: CGFloat, frame: CGRect) -> [(Double, Double)] {
        let top = Int(frame.minY * scale)
        let xs = [0.62, 0.75, 0.88].map { Int((frame.minX + frame.width * $0) * scale) }
        let surface = luminance(rep, xs[0], top + 2)
        var rules: [Double] = []
        var last = -10
        for y in top..<min(rep.pixelsHigh, Int(frame.maxY * scale)) {
            let dim = xs.allSatisfy { luminance(rep, $0, y) < surface - 0.03 && luminance(rep, $0, y) > surface - 0.35 }
            if dim, y - last > 4 { rules.append(Double(CGFloat(y - top) / scale)) }
            if dim { last = y }
        }
        guard rules.count >= 2 else { return [] }
        let pitch = rules[1] - rules[0]
        var rows: [(Double, Double)] = [(rules[0] - (pitch - 1), pitch - 1)]
        for k in 0..<(rules.count - 1) { rows.append((rules[k] + 1, rules[k + 1] - rules[k] - 1)) }
        return rows
    }

}
