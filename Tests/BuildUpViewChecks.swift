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
            COSBuildUp(shape, loading: loader.loading && !loader.landed, landed: loader.landed, interrupted: loader.interrupted, label: label) {
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

    struct Answer: View {
        @ObservedObject var loader: Loader
        var body: some View {
            VStack(alignment: .leading, spacing: 9) {
                Text("A question").font(COSType.body(12, weight: .semibold))
                COSBuildUp(.answer, loading: loader.loading && !loader.landed, landed: loader.landed, label: "Checking the meeting",
                           key: AnyHashable("view-check"), background: COSPalette.raised) {
                    if loader.landed {
                        Text(String(repeating: "The offer stays live through October 31 and the sign-ups are reviewed on Monday. ", count: 4))
                            .font(COSType.body(13)).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(loader.loading ? "Checking the meeting…" : "No answer · failed").font(COSType.body(12)).foregroundStyle(.secondary)
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
        landings()
        realSessions()
        pulse()
        outcomes()
        fitting()
        answer()
        heights()
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

        // A view this session has seen (the fast one, after the relaunch) reopens quietly.
        let seen = Loader()
        let quiet = run(Host(loader: seen, shape: .rows(4), label: "Loading rows fast"), for: 1.0) { t in
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
        check(!short.isEmpty && short.allSatisfy { $0.frame.rects.count == 2 }, "fit", "a 150 pt container draws 2 rows: \(short.map(\.frame.rects.count))")
        check(!tall.isEmpty && tall.allSatisfy { $0.frame.rects.count == 4 }, "fit", "resized to 330 pt it draws 4: \(tall.map(\.frame.rects.count))")
        check(run.frames.allSatisfy { f in f.frame.rects.allSatisfy { $0.maxY <= f.frame.size.height + 0.5 } }, "fit", "a row past the view")
    }

    // MARK: The answer: inside today's one line, re-fit to the real text

    static func answer() {
        let loader = Loader()
        let run = run(Answer(loader: loader), for: 1.4) { t in
            if t >= 0.75, !loader.landed { loader.landed = true }
        }
        // Before the answer arrives (the loader flips at 0.75 s; the frame in flight then may already lay out the answer).
        let building = run.phase(.building).filter { $0.t < 0.74 && $0.frame.kind == "answer" }, landing = run.phase(.landing).filter { $0.frame.kind == "answer" }
        check(!building.isEmpty && building.allSatisfy { $0.frame.size.height < 20 && $0.frame.lines == [1] }, "answer size",
              "the answer's wire sits inside the one-line loading text: \(building.filter { !($0.frame.size.height < 20 && $0.frame.lines == [1]) }.map { "\($0.frame.size.height) \($0.frame.lines)" }.prefix(6)) of \(building.count)")
        check(!landing.isEmpty && landing.allSatisfy { $0.frame.lines.first ?? 0 >= 4 && $0.frame.size.height > 60 }, "answer refit",
              "landed, the wire re-fits to the real text's lines: \(landing.filter { !(($0.frame.lines.first ?? 0) >= 4 && $0.frame.size.height > 60) }.map { "\($0.frame.size.height) \($0.frame.lines)" }.prefix(6)) of \(landing.count)")
    }

    // MARK: The inline views are today's height: loading, empty and landed

    static func heights() {
        func height(_ view: some View) -> CGFloat { NSHostingView(rootView: AnyView(view.frame(width: 480))).fittingSize.height }
        let sites: [(String, COSBuildUpShape, Color, [(String, AnyView)])] = [
            ("answer", .answer, COSPalette.raised, [
                ("loading", AnyView(Text("Checking the meeting…").font(COSType.body(12)))),
                ("empty", AnyView(Text("No answer · failed").font(COSType.body(12)))),
                ("typical", AnyView(Text(String(repeating: "The offer stays live through October 31. ", count: 5)).font(COSType.body(13)).fixedSize(horizontal: false, vertical: true))),
            ]),
            ("needs you", .cardRows(2, badge: false), COSPalette.card, [
                ("loading", AnyView(VStack(alignment: .leading, spacing: 0) { Text(TodayHome.loadingLine).font(COSType.body(13.5)).padding(.horizontal, 18).padding(.bottom, 18) })),
                ("empty", AnyView(VStack(alignment: .leading, spacing: 6) { Text(TodayHome.caughtUpLine).font(COSType.display(20)); Text("Checked at 9:41.").font(COSType.body(12)) }.padding(.horizontal, 18).padding(.bottom, 18))),
                ("typical", AnyView(VStack(alignment: .leading, spacing: 0) { ForEach(0..<3, id: \.self) { _ in VStack(alignment: .leading, spacing: 3) { Text("Name 2 voices").font(COSType.body(14, weight: .semibold)); Text("Speakers").font(COSType.body(12.5)) }.padding(.horizontal, 18).padding(.vertical, 12) } })),
            ]),
            ("running", .cardRows(1, badge: true), COSPalette.ink, [
                ("loading", AnyView(Text("Reading sessions").font(COSType.body(13.5)).padding(.top, 4).padding(.bottom, 10))),
                ("empty", AnyView(Text("Nothing is running.").font(COSType.body(13.5)).padding(.top, 4).padding(.bottom, 10))),
                ("typical", AnyView(VStack(spacing: 0) { ForEach(0..<2, id: \.self) { _ in HStack { Text("CLAUDE").frame(width: 84); Text("Holiday promo landing page").font(COSType.body(14, weight: .semibold)) }.padding(.vertical, 10) } })),
            ]),
        ]
        for (name, shape, background, states) in sites {
            for (state, content) in states {
                let today = height(content)
                var seen: [CGFloat] = []
                for frame in [COSBuildUpFrame(phase: .grace, drawT: 0), .init(phase: .building, drawT: 1.4), .init(phase: .building, drawT: 3.5),
                              .init(phase: .landing, drawT: 2, phaseT: 0.1), .init(phase: .handoff, drawT: 2, phaseT: 0.1)] {
                    let built = height(COSBuildUp(shape, loading: true, landed: false, label: "Heights", background: background, frozen: frame) { content })
                    check(abs(built - today) < 0.5, "no extra height", "\(name) \(state) \(frame.phase): 0.5.342 \(today) pt, 0.5.343 \(built) pt")
                    seen.append(built)
                }
                print("height \(name) \(state): 0.5.342 \(String(format: "%.1f", today)) pt; 0.5.343 \(seen.map { String(format: "%.1f", $0) }.joined(separator: " / ")) pt (grace / wire / words / landing / hand-off)")
            }
        }
    }
}
