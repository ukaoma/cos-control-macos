import Foundation

// 0.5.343 Build-up, in place (mock: operations/personal/wk43_2026/mock-skeleton/skeleton-reveal.html, "BUILD-UP, IN
// PLACE"; rules from Miles's brief and the 6.10.654 QA), executed against the pure half in Sources/Models.swift: the
// shapes and their cap, the timing table, the eased look the stage draws every frame, the draw clock that never jumps when
// the data lands, the settle derived from the steps, and the state machine (the grace, Reduce Motion, the words after
// 3 s, the pulse that stops, the timeout, the hand-off, a new load mid-landing, first open only and the session memory).
// Compiled with Sources/Models.swift alone (Tests/run-build-up.sh). Nothing is drawn, clicked, shown or activated. Every
// check names its behaviour, so Tests/mutate-build-up.py attributes each kill. The live view runs in
// Tests/BuildUpViewChecks.swift.

@main struct BuildUpChecks {
    nonisolated(unsafe) static var ran = 0

    static func check(_ condition: Bool, _ behavior: String, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
        ran += 1
        if !condition { fatalError("check failed [\(behavior)] at line \(line): \(detail())") }
    }
    static func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

    typealias P = COSBuildUpPlan
    typealias M = COSBuildUpMachine
    static let t0 = 1_000.0
    static let frame = 1.0 / 60

    static func main() {
        capChecks()
        layoutChecks()
        answerChecks()
        timingChecks()
        settleChecks()
        progressChecks()
        continuityChecks()
        graceChecks()
        reduceMotionChecks()
        buildChecks()
        wordsChecks()
        pulseChecks()
        timeoutChecks()
        handoffChecks()
        midLandingChecks()
        firstOpenChecks()
        memoryChecks()
        freshChecks()
        fitChecks()
        breadcrumbChecks()
        visibilityChecks()
        print("PASS build up: \(ran) checks; the cap, the layout, the answer re-fit, the timing table, the settle, the eased look, "
              + "the draw clock through a landing, the grace, Reduce Motion, the build, the words, the pulse, the timeout, the hand-off, "
              + "a new load mid-landing, first open only, the session memory, a late load, the fit, the breadcrumb, what shows")
    }

    /// A machine that starts loading at t0 and builds at t0 + grace.
    static func building(_ count: Int = 6) -> M {
        var m = M(at: t0, loading: true, landed: false, reduceMotion: false, count: count)
        m.update(at: t0 + P.graceSeconds, loading: true, landed: false)
        return m
    }

    // MARK: Never more than 8, never more than fit, never more than remembered

    static func capChecks() {
        check(P.maxItems == 8, "cap", "\(P.maxItems)")
        for shape in [COSBuildUpShape.rows(20), .list(20), .turns(20), .detail(turns: 20), .summary(turns: 20), .cardRows(20, badge: true)] {
            check(P.items(shape).count == 8, "cap", "\(shape) drew \(P.items(shape).count)")
        }
        check(P.items(.rows(3)).count == 3 && P.items(.list(1)).count == 1 && P.items(.rows(0)).isEmpty && P.items(.rows(-2)).isEmpty,
              "cap", "a short list draws what it asked for")
        check(P.items(.detail(turns: 2)).count == 4 && P.items(.summary(turns: 2)).count == 3 && P.items(.answer).count == 1,
              "cap", "a detail is its header, its summary and its turns")
        check(P.items(.rows(8), limit: 2).count == 2 && P.items(.detail(turns: 6), limit: 3).count == 3 && P.items(.answer, limit: 0).isEmpty,
              "cap", "a remembered count limits the rows")
        check(M(at: t0, loading: true, landed: false, reduceMotion: false, count: 0).phase == .settled, "cap", "nothing to draw: no build")
        // Rows are 62 pt with 6 pt between them, 12 pt down: 3 fit in 210 (12 + 62 + 6 + 62 + 6 + 62), 2 in 209.
        check(P.items(.rows(8), fitting: 210).count == 3, "fits", "\(P.items(.rows(8), fitting: 210).count)")
        check(P.items(.rows(8), fitting: 209).count == 2, "fits", "\(P.items(.rows(8), fitting: 209).count)")
        check(P.items(.rows(8), fitting: 10).count == 1, "fits", "a tiny pane still shows one")
        check(P.items(.rows(8), fitting: 100_000).count == 8, "fits", "room never lifts the cap")
    }

    // MARK: Where everything sits

    static func layoutChecks() {
        let layout = P.layout(.rows(4)), items = P.items(.rows(4))
        check(near(P.top(0, in: items, layout: layout), 12) && near(P.top(2, in: items, layout: layout), 12 + 2 * (62 + 6)), "layout",
              "\(P.top(2, in: items, layout: layout))")
        check(near(P.height(items, layout: layout), 12 + 4 * 62 + 3 * 6), "layout", "\(P.height(items, layout: layout))")
        check(near(P.height([], layout: layout), 0), "layout", "nothing to reserve")
        check(near(P.junctionY(1, in: items, layout: layout), 12 + 68 + 18), "junction", "\(P.junctionY(1, in: items, layout: layout))")
        let turns = P.items(.turns(2)), turnLayout = P.layout(.turns(2))
        check(near(P.junctionY(0, in: turns, layout: turnLayout), turnLayout.top + 12), "junction", "\(P.junctionY(0, in: turns, layout: turnLayout))")
        check(P.layout(.rows(1)).fills && P.layout(.detail(turns: 1)).fills && !P.layout(.answer).fills && !P.layout(.cardRows(2, badge: false)).fills,
              "layout", "a pane fills, an answer and a card's rows keep their own height")
        check(P.layout(.rows(1)).spineX.map { $0 < P.layout(.rows(1)).leading } == true, "layout", "the spine runs left of the components")
    }

    // MARK: The answer: sized to a short answer, re-fit to the real text when it lands

    static func answerChecks() {
        let short = P.items(.answer)
        let reserve = P.height(short, layout: P.layout(.answer))
        check(short.count == 1 && short[0].lines.count == 1 && short[0].chips.isEmpty && reserve <= 20, "answer size",
              "one line, no taller than the old one-line spinner by more than a few points: \(reserve)")
        let one = P.items(.answer, measured: 17)[0], four = P.items(.answer, measured: 70)[0], tall = P.items(.answer, measured: 900)[0]
        check(one.lines.count == 1 && four.lines.count == 4 && near(four.height, 70) && tall.lines.count == 8, "answer refit",
              "lines follow the real text: \(one.lines.count) \(four.lines.count) \(tall.lines.count)")
        let used = four.lines.reduce(0) { $0 + $1.height } + Double(four.lines.count - 1) * four.lineGap + 2 * four.padV
        check(used <= four.height + 2, "answer refit", "the re-fit lines sit inside the real text: \(used) of \(four.height)")
    }

    // MARK: The timing table

    static func timingChecks() {
        check(near(P.outline, 0.64) && near(P.nodes, 0.26) && near(P.wireText, 0.44), "durations", "the mock's draw: outline 640, nodes 260, wire 440")
        check(P.easeOut == (0.16, 0.84, 0.24, 1.0) && P.pop == (0.3, 1.6, 0.5, 1.0), "durations", "the mock's two curves")
        for i in 0..<8 {
            let d = Double(i)
            check(near(P.outlineStep(i).delay, d * 0.05) && near(P.wireTextStep(i).delay, d * 0.05 + 0.30) && near(P.nodeStep(i).delay, d * 0.05 + 0.46),
                  "stagger", "draw \(i): 50 ms per component")
            check(near(P.fillStep(i).delay, d * 0.03) && near(P.inkStep(i).delay, d * 0.03 + 0.04) && near(P.outlineFadeStep(i).delay, d * 0.03 + 0.15),
                  "stagger", "land \(i): 30 ms per component")
            check(near(P.branchStep(i).delay, d * 0.045 + 0.16) && near(P.junctionStep(i).delay, d * 0.045 + 0.28), "stagger", "traces \(i)")
            // The capsules are gone ahead of the ink: never solid over inking text.
            check(P.wireFadeStep(i).end <= P.inkStep(i).end && P.solidStep(i).end <= P.inkStep(i).delay + P.wireFade, "ink order",
                  "the wire text fades before the ink finishes \(i)")
        }
        check(P.inkStep(0).delay <= 0.1, "ink soon", "arrived data starts inking within 100 ms: \(P.inkStep(0).delay)")
        check(P.fillStep(3).delay < P.inkStep(3).delay && P.inkStep(3).delay < P.outlineFadeStep(3).delay, "ink order", "fill, ink, then the outline hands over")
        check(P.outlineStep(3).delay < P.wireTextStep(3).delay && P.wireTextStep(3).delay < P.nodeStep(3).delay, "ink order", "outline, wire text, nodes")
        check(near(P.drawDuration(count: 1), 0.74) && near(P.drawDuration(count: 8), 7 * 0.05 + 0.74), "draw duration", "\(P.drawDuration(count: 8))")
    }

    // MARK: The settle comes from the same steps, and the landing is short

    static func settleChecks() {
        for n in 1...8 {
            let settle = P.landDuration(count: n)
            check(settle <= 0.6 + 1e-9, "land duration", "\(n) components land within 600 ms: \(settle)")
            let lastEnd = (0..<n).flatMap(P.landSteps).map(\.end).max() ?? 0
            check(settle >= lastEnd - 1e-9, "land duration", "\(n): the settle is never before the last step ends")
            for i in 0..<n {
                let look = P.look(i, drawT: 9, landT: settle)
                let done = { (x: Double) in x >= 1 - 1e-6 }
                check(done(look.ink) && done(look.fill) && done(look.wireFade) && done(look.outlineFade) && done(look.nodeFade) && look.outlineShown <= 1e-6,
                      "land duration", "\(n), \(i): every layer is done at the settle: \(look)")
            }
        }
        check(near(P.landDuration(count: 50), P.landDuration(count: 8)) && near(P.landDuration(count: 0), P.landDuration(count: 1)), "land duration",
              "capped like the items")
        check(near(P.pulseSeconds, 0.7 + 3 * 1.4), "pulse cap", "three flows: \(P.pulseSeconds)")
    }

    // MARK: The eased fraction

    static func progressChecks() {
        let step = COSBuildUpStep(delay: 0.3, duration: 0.5)
        check(P.progress(step, at: 0) == 0 && P.progress(step, at: 0.3) == 0 && P.progress(step, at: 0.8) == 1 && P.progress(step, at: 9) == 1,
              "progress", "zero before, one after")
        var last = 0.0
        for k in 1...49 {
            let value = P.progress(step, at: 0.3 + 0.5 * Double(k) / 50)
            check(value >= last && value <= 1, "progress", "monotone at \(k): \(value)")
            last = value
        }
        check(P.progress(step, at: 0.425) > 0.5, "progress", "ease-out is front loaded: \(P.progress(step, at: 0.425))")
        check(near(P.bezier(0.5, (0.0, 0.0, 1.0, 1.0)), 0.5, 1e-6), "progress", "a linear bezier is linear")
        let pops = (1...49).map { P.progress(COSBuildUpStep(delay: 0, duration: 1), at: Double($0) / 50, curve: P.pop) }
        check((pops.max() ?? 0) > 1.05, "progress", "a node pop overshoots: \(pops.max() ?? 0)")
        let look = P.look(2, drawT: 0.5, landT: nil)
        check(near(look.outline, P.progress(P.outlineStep(2), at: 0.5)) && look.ink == 0 && look.fill == 0, "progress", "before the data, nothing lands")
    }

    // MARK: The 6.10.654 landing snap: the draw keeps its own clock, so the outline never jumps

    static func continuityChecks() {
        for land in [0.2, 0.6, 1.2] {
            var m = M(at: t0, loading: true, landed: false, reduceMotion: false, count: 6)
            var previous: (outline: Double, shown: Double)?
            var first = true
            var t = t0
            while m.phase != .settled && t < t0 + 5 {
                let landed = t >= t0 + P.graceSeconds + land
                m.update(at: t, loading: !landed, landed: landed)
                if m.drawsWire, let drawT = m.drawT(at: t) {
                    let look = P.look(0, drawT: drawT, landT: m.landT(at: t))
                    if first {
                        check(look.outline < 0.2, "landing continuous", "land at \(land): the first frame is the start of the draw: \(look.outline)")
                        first = false
                    }
                    if let previous {
                        check(look.outline >= previous.outline - 1e-12 && look.outline - previous.outline <= 0.15, "landing continuous",
                              "land at \(land) s, t \(t - t0): the outline grows a frame at a time: \(previous.outline) to \(look.outline)")
                        check(look.outlineShown - previous.shown <= 0.15, "landing continuous",
                              "land at \(land) s: the shown outline never jumps up: \(previous.shown) to \(look.outlineShown)")
                    }
                    previous = (look.outline, look.outlineShown)
                }
                t += frame
            }
            check(m.phase == .settled && !first, "landing continuous", "land at \(land) s: drew, landed and settled")
        }
    }

    // MARK: Data inside 150 ms never builds

    static func graceChecks() {
        check(near(P.graceSeconds, 0.15), "grace delay", "\(P.graceSeconds)")
        var m = M(at: t0, loading: true, landed: false, reduceMotion: false, count: 6)
        check(m.phase == .grace && m.hidesContent && !m.drawsWire, "grace delay", "loading at open waits, drawing nothing")
        check(m.deadline(after: t0).map { near($0, t0 + 0.15) } == true, "grace delay", "\(String(describing: m.deadline(after: t0)))")
        m.update(at: t0 + 0.149, loading: true, landed: false)
        check(m.phase == .grace, "grace delay", "still waiting at 149 ms: \(m.phase)")
        m.update(at: t0 + 0.12, loading: false, landed: true)
        check(m.phase == .settled && !m.hidesContent && !m.drawsWire && m.outcome == .direct, "grace skips build",
              "a fast load shows the content directly: \(m.phase)")
        var empty = M(at: t0, loading: true, landed: false, reduceMotion: false, count: 6)
        empty.update(at: t0 + 0.05, loading: false, landed: false)
        check(empty.phase == .settled && empty.outcome == .direct, "grace skips build", "a fast empty answer shows today's view directly")
    }

    // MARK: Reduce Motion keeps the grace, then today's loading view, never a wire

    static func reduceMotionChecks() {
        var m = M(at: t0, loading: true, landed: false, reduceMotion: true, count: 6)
        check(m.phase == .grace && m.hidesContent && !m.drawsWire, "reduce motion", "the grace still holds, so nothing flashes")
        m.update(at: t0 + 0.15, loading: true, landed: false)
        check(m.phase == .settled && !m.hidesContent && !m.drawsWire && m.outcome == .still, "reduce motion",
              "then today's loading view, no wire: \(m.phase)")
        var mid = building()
        mid.update(at: t0 + 0.4, loading: true, landed: false, reduceMotion: true)
        check(mid.phase == .settled && !mid.hidesContent, "reduce motion mid-build", "turning it on mid-build shows today's view: \(mid.phase)")
    }

    // MARK: The build and the landing

    static func buildChecks() {
        var m = building()
        check(m.phase == .building && m.drawsWire && m.hidesContent && m.drawT(at: t0 + 0.15) == 0, "build", "the wire draws once the grace passes")
        m.update(at: t0 + 2, loading: true, landed: false)
        check(m.phase == .building, "build", "it keeps building while it loads")
        m.update(at: t0 + 2.2, loading: false, landed: true)
        check(m.phase == .landing && m.drawsWire && !m.hidesContent && m.outcome == .landed, "land",
              "the data lands: the content is live, inking under the wire: \(m.phase)")
        check(m.landT(at: t0 + 2.3).map { near($0, 0.1, 1e-6) } == true && m.drawT(at: t0 + 2.3).map { near($0, 2.15, 1e-6) } == true, "land",
              "the landing has its clock, the draw keeps its own")
        let settle = P.landDuration(count: 6)
        check(m.deadline(after: t0 + 2.2).map { near($0, t0 + 2.2 + settle) } == true, "land duration", "\(String(describing: m.deadline(after: t0)))")
        m.update(at: t0 + 2.2 + settle - 0.01, loading: false, landed: true)
        check(m.phase == .landing, "land duration", "not cut short: \(m.phase)")
        m.update(at: t0 + 2.2 + settle, loading: false, landed: true)
        check(m.phase == .settled && m.deadline(after: t0 + 9) == nil && !m.needsFrames(windowActive: true), "loop stops", "settled, nothing wakes again")
    }

    // MARK: After 3 s with no data, today's words show under the wire

    static func wordsChecks() {
        check(near(P.wordsSeconds, 3), "words", "\(P.wordsSeconds)")
        var m = building()
        m.update(at: t0 + 0.15 + 2.9, loading: true, landed: false)
        check(m.hidesContent && !m.wordsShown, "words", "the wire alone for a short wait")
        m.update(at: t0 + 0.15 + 3.01, loading: true, landed: false)
        check(m.wordsShown && !m.hidesContent && m.drawsWire, "words", "today's loading words join the wire")
    }

    // MARK: The pulse runs its cycles and stops; nothing redraws while a slow load waits

    static func pulseChecks() {
        var m = building(4)
        check(m.pulses(windowActive: true) && !m.pulses(windowActive: false), "pulse window", "it pulses only in an active window")
        check(m.needsFrames(windowActive: false), "pulse window", "the draw itself still finishes in an inactive window")
        check(P.flow(drawT: 0.5) == nil && P.flow(drawT: 0.7).map { near($0, 0) } == true && P.flow(drawT: P.pulseSeconds) == nil, "pulse cap",
              "the flow runs from 0.7 s for its cycles")
        check(P.ping(0, drawT: 0.89) == nil && P.ping(0, drawT: 1.7) != nil && P.ping(3, drawT: P.pulseSeconds + 0.01) == nil, "pulse cap", "the pings too")
        m.update(at: t0 + 0.15 + P.drawDuration(count: 4) + 0.01, loading: true, landed: false)
        check(m.drawDone && !m.needsFrames(windowActive: false) && m.needsFrames(windowActive: true), "loop stops",
              "drawn: an inactive window needs no frames, an active one still pulses")
        m.update(at: t0 + 0.15 + P.pulseSeconds + 0.01, loading: true, landed: false)
        check(m.pulseDone && !m.pulses(windowActive: true) && !m.needsFrames(windowActive: true), "pulse cap",
              "after its cycles the wire stands still and nothing redraws")
        let next = m.deadline(after: t0 + 6)
        check(next.map { near($0, t0 + 0.15 + P.timeoutSeconds) } == true, "loop stops", "the next wake is the timeout: \(String(describing: next))")
    }

    // MARK: A load that never answers hands over to today's view

    static func timeoutChecks() {
        check(near(P.timeoutSeconds, 20), "timeout", "\(P.timeoutSeconds)")
        var m = building()
        m.update(at: t0 + 0.15 + 19.9, loading: true, landed: false)
        check(m.phase == .building, "timeout", "\(m.phase)")
        m.update(at: t0 + 0.15 + 20.01, loading: true, landed: false)
        check(m.phase == .handoff && m.outcome == .timeout, "timeout", "no stuck wire: \(m.phase)")
        m.update(at: t0 + 0.15 + 20.3, loading: true, landed: false)
        check(m.phase == .settled && !m.hidesContent && !m.drawsWire, "timeout", "today's spinner and words, as before")
    }

    // MARK: An error or an empty answer hands off to today's view

    static func handoffChecks() {
        check(near(P.handoffSeconds, 0.2), "handoff fade", "\(P.handoffSeconds)")
        var m = building()
        m.update(at: t0 + 2, loading: false, landed: false)
        check(m.phase == .handoff && m.drawsWire && m.hidesContent && m.outcome == .empty, "error handoff", "no data: the wire fades: \(m.phase)")
        check(m.deadline(after: t0 + 2).map { near($0, t0 + 2.2) } == true && m.handoffT(at: t0 + 2.1).map { near($0, 0.1, 1e-6) } == true,
              "handoff fade", "\(String(describing: m.deadline(after: t0 + 2)))")
        m.update(at: t0 + 2.19, loading: false, landed: false)
        check(m.phase == .handoff, "handoff fade", "\(m.phase)")
        m.update(at: t0 + 2.2001, loading: false, landed: false)
        check(m.phase == .settled && !m.hidesContent, "error handoff", "then today's error or empty view, as is: \(m.phase)")
    }

    // MARK: A new load mid-landing settles the old one first

    static func midLandingChecks() {
        var m = building()
        m.update(at: t0 + 1, loading: false, landed: true)
        check(m.phase == .landing, "mid landing", "\(m.phase)")
        m.update(at: t0 + 1.2, loading: true, landed: true)
        check(m.phase == .settled && !m.drawsWire && !m.hidesContent, "mid landing", "the old landing settles at once: \(m.phase)")
        m.update(at: t0 + 1.3, loading: false, landed: true)
        check(m.phase == .settled, "mid landing", "and the new load swaps as today")
    }

    // MARK: First open only

    static func firstOpenChecks() {
        var m = building()
        m.update(at: t0 + 1, loading: false, landed: true)
        m.update(at: t0 + 5, loading: false, landed: true)
        check(m.phase == .settled, "first open only", "\(m.phase)")
        for k in 0..<20 {
            m.update(at: t0 + 10 + Double(k), loading: k % 2 == 0, landed: k % 3 == 0)
            check(m.phase == .settled && m.deadline(after: t0 + 10 + Double(k)) == nil && !m.hidesContent && !m.drawsWire, "first open only",
                  "a refresh or poll never builds again: \(k) \(m.phase)")
        }
        let cached = M(at: t0, loading: true, landed: true, reduceMotion: false, count: 6)
        check(cached.phase == .settled && cached.deadline(after: t0) == nil, "cached open", "\(cached.phase)")
        var reopened = m
        reopened.reopen(at: t0 + 40, loading: true, landed: false, quiet: false)
        check(reopened.phase == .grace, "reopen", "\(reopened.phase)")
        reopened.reopen(at: t0 + 41, loading: true, landed: false, quiet: true)
        check(reopened.phase == .settled, "reopen", "a view this session has seen reopens quietly")
    }

    // MARK: The session memory

    static func memoryChecks() {
        var memory = COSBuildUpMemory()
        check(memory.builds("Loading meetings|"), "memory", "a new view builds")
        memory.record("Loading meetings|", .landed)
        check(!memory.builds("Loading meetings|") && memory.builds("Loading tasks|"), "memory", "seen once: lands quietly after, only that view")
        memory.record("Loading tasks|", .empty)
        check(!memory.builds("Loading tasks|") && memory.empty.contains("Loading tasks|"), "memory", "an empty view draws no phantom rows")
        memory.record("Loading tasks|", .landed)
        check(!memory.empty.contains("Loading tasks|"), "memory", "data again clears the empty mark")
        let quiet = M(at: t0, loading: true, landed: false, reduceMotion: false, count: 6, quiet: true)
        check(quiet.phase == .settled && !quiet.hidesContent, "memory", "quiet: today's view at once, no grace, no wire")
    }

    // MARK: A load that starts just after the view opens

    static func freshChecks() {
        check(near(P.freshSeconds, 1.0), "fresh expires", "\(P.freshSeconds)")
        var m = M(at: t0, loading: false, landed: false, reduceMotion: false, count: 6)
        check(m.phase == .fresh && !m.hidesContent && !m.drawsWire, "fresh", "today's view shows until the load starts: \(m.phase)")
        m.update(at: t0 + 0.4, loading: true, landed: false)
        check(m.phase == .grace && m.loadStarted == t0 + 0.4, "fresh", "a load that starts within the window builds: \(m.phase)")
        var late = M(at: t0, loading: false, landed: false, reduceMotion: false, count: 6)
        late.update(at: t0 + 1.0, loading: false, landed: false)
        check(late.phase == .settled, "fresh expires", "past the window the view counts as open: \(late.phase)")
        late.update(at: t0 + 1.2, loading: true, landed: false)
        check(late.phase == .settled, "fresh expires", "so a later load swaps as today: \(late.phase)")
        var landed = M(at: t0, loading: false, landed: false, reduceMotion: false, count: 6)
        landed.update(at: t0 + 0.3, loading: false, landed: true)
        check(landed.phase == .settled, "fresh landed", "data with no load shows directly: \(landed.phase)")
    }

    // MARK: The wire follows the container

    static func fitChecks() {
        var m = building(8)
        m.fit(3)
        check(m.count == 3 && m.deadline(after: t0 + 0.15).map { near($0, t0 + 0.15 + P.drawDuration(count: 3)) } == true, "fit",
              "a smaller container draws fewer rows, and the draw ends sooner")
        m.fit(20)
        check(m.count == 8, "fit", "never past the cap")
        m.update(at: t0 + 1, loading: false, landed: true)
        m.fit(2)
        check(m.count == 8, "fit", "a landing keeps the rows it drew")
    }

    // MARK: One breadcrumb per load, counts only

    static func breadcrumbChecks() {
        let line = P.breadcrumb(.rows(6), outcome: .landed, rows: 6, ms: 812)
        check(line == "build-up rows outcome=landed rows=6 ms=812", "breadcrumb", line)
        check(P.breadcrumb(.answer, outcome: .timeout, rows: 1, ms: 20150) == "build-up answer outcome=timeout rows=1 ms=20150", "breadcrumb", "")
        var m = building()
        m.update(at: t0 + 0.9, loading: false, landed: true)
        check(m.outcome == .landed && m.loadStarted == t0 && m.outcomeAt == t0 + 0.9, "breadcrumb", "the machine keeps what the line reports")
    }

    // MARK: What each phase shows

    static func visibilityChecks() {
        let table: [(M.Phase, Bool, Bool)] = [(.fresh, false, false), (.grace, true, false), (.building, true, true),
                                              (.landing, false, true), (.handoff, true, true), (.settled, false, false)]
        var seen = Set<M.Phase>()
        func read(_ m: M) {
            guard let row = table.first(where: { $0.0 == m.phase }) else { return }
            seen.insert(m.phase)
            check(m.hidesContent == row.1 && m.drawsWire == row.2, "phase visibility", "\(m.phase): hides \(m.hidesContent), wire \(m.drawsWire)")
        }
        var a = M(at: t0, loading: false, landed: false, reduceMotion: false, count: 2); read(a)
        a.update(at: t0 + 0.1, loading: true, landed: false); read(a)
        a.update(at: t0 + 0.3, loading: true, landed: false); read(a)
        a.update(at: t0 + 0.5, loading: false, landed: true); read(a)
        a.update(at: t0 + 9, loading: false, landed: true); read(a)
        var b = building(2)
        b.update(at: t0 + 0.5, loading: false, landed: false); read(b)
        check(seen.count == 6, "phase visibility", "every phase read: \(seen)")
    }
}
