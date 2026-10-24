import Foundation

// 0.5.343 Build-up, in place (mock: operations/personal/wk43_2026/mock-skeleton/skeleton-reveal.html, "BUILD-UP, IN
// PLACE"; rules from Miles's brief, the 6.10.654 QA and the 0.5.343 QA round 1), executed against the pure half in
// Sources/Models.swift: the shapes, the per-site geometry, the cap and the squeeze into today's height, the timing table,
// the eased look the stage draws every frame, the tint, the draw clock that never jumps when the data lands, the settle
// derived from the steps, the wire's contrast, and the state machine (driven both by events and by its own deadlines
// alone) with the session and cross-launch memory. Compiled with Sources/Models.swift alone (Tests/run-build-up.sh).
// Nothing is drawn, clicked, shown or activated. Every check names its behaviour, so Tests/mutate-build-up.py attributes
// each kill. The live view runs in Tests/BuildUpViewChecks.swift.

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
        heightChecks()
        answerChecks()
        timingChecks()
        settleChecks()
        curtainChecks()
        progressChecks()
        continuityChecks()
        contrastChecks()
        graceChecks()
        firstOpenChecks()
        reduceMotionChecks()
        buildChecks()
        wordsChecks()
        pulseChecks()
        deadlineChecks()
        timeoutChecks()
        handoffChecks()
        midLandingChecks()
        interruptChecks()
        memoryChecks()
        freshChecks()
        fitChecks()
        breadcrumbChecks()
        visibilityChecks()
        print("PASS build up: \(ran) checks; the cap, the site geometry, no extra height, the answer re-fit, the timing table, the settle, the tint, "
              + "the eased look, the draw clock through a landing, the wire's contrast, the grace, first open only, Reduce Motion, the build, "
              + "the words, the pulse, the deadlines alone, the timeout, the hand-off, a new load mid-landing, interrupted and abandoned, "
              + "the memory across launches, a late load, the fit, the breadcrumb, what shows")
    }

    /// A machine that starts loading at t0 and builds at t0 + grace.
    static func building(_ count: Int = 6, timeout: Double = 20) -> M {
        var m = M(at: t0, loading: true, landed: false, reduceMotion: false, count: count, timeout: timeout)
        m.update(at: t0 + P.graceSeconds, loading: true, landed: false)
        return m
    }

    // MARK: Never more than 8, never more than fit, never more than remembered

    static func capChecks() {
        check(P.maxItems == 8, "cap", "\(P.maxItems)")
        for shape in [COSBuildUpShape.rows(20), .list(20), .turns(20), .summary(turns: 20), .cardRows(20, badge: true)] {
            check(P.items(shape).count == 8, "cap", "\(shape) drew \(P.items(shape).count)")
        }
        check(P.items(.rows(3)).count == 3 && P.items(.list(1)).count == 1 && P.items(.rows(0)).isEmpty && P.items(.rows(-2)).isEmpty,
              "cap", "a short list draws what it asked for")
        check(P.items(.summary(turns: 2)).count == 3 && P.items(.answer).count == 1, "cap", "a body is its summary and its turns")
        check(P.items(.rows(8), limit: 2).count == 2 && P.items(.summary(turns: 6), limit: 3).count == 3 && P.items(.answer, limit: 0).isEmpty,
              "cap", "a limit caps the rows")
        check(M(at: t0, loading: true, landed: false, reduceMotion: false, count: 0).phase == .settled, "cap", "nothing to draw: no build")
        // Rows are 62 pt with 6 pt between them, 12 pt down: 3 fit in 210 (12 + 62 + 6 + 62 + 6 + 62), 2 in 209.
        check(P.items(.rows(8), fitting: 210).count == 3, "fits", "\(P.items(.rows(8), fitting: 210).count)")
        check(P.items(.rows(8), fitting: 209).count == 2, "fits", "\(P.items(.rows(8), fitting: 209).count)")
        check(P.items(.rows(8), fitting: 100_000).count == 8, "fits", "room never lifts the cap")
        check(P.items(.rows(8), fitting: 150).count == 2, "fits", "a 150 pt pane: \(P.items(.rows(8), fitting: 150).count)")
    }

    // MARK: Each site's geometry (measured from the real rows by Tests/BuildUpRender.swift)

    static func layoutChecks() {
        let layout = P.layout(.rows(4)), items = P.items(.rows(4))
        check(near(P.top(0, in: items, layout: layout), 12) && near(P.top(2, in: items, layout: layout), 12 + 2 * (62 + 6)), "layout",
              "\(P.top(2, in: items, layout: layout))")
        check(near(P.height(items, layout: layout), 12 + 4 * 62 + 3 * 6), "layout", "\(P.height(items, layout: layout))")
        check(near(P.junctionY(1, in: items, layout: layout), 12 + 68 + 18), "junction", "\(P.junctionY(1, in: items, layout: layout))")
        let turns = P.items(.turns(2)), turnLayout = P.layout(.turns(2))
        check(near(P.junctionY(0, in: turns, layout: turnLayout), turnLayout.top + 12), "junction", "\(P.junctionY(0, in: turns, layout: turnLayout))")
        check(P.layout(.rows(1)).fills && P.layout(.summary(turns: 1)).fills && !P.layout(.answer).fills && !P.layout(.cardRows(2, badge: false)).fills,
              "layout", "a pane fills, an answer and a card's rows sit inside today's view")
        check(P.layout(.answer).spineX == nil && P.layout(.cardRows(1, badge: true)).spineX == nil && P.layout(.cardRows(2, badge: false)).spineX == 8,
              "layout", "no spine where there is no room inside the view")
        for (tune, top, row, spacing) in [(COSBuildUpTune.sessions, 0.0, 62.0, 6.0), (.tasks, 0, 62, 6), (.memories, 1, 78, 7), (.threads, 1, 60, 7),
                                          (.messages, 14, 74, 6), (.voices, 32, 62, 1)] {
            let l = P.layout(.rows(4), tune), i = P.items(.rows(4), tune)
            check(near(l.top, top) && i.allSatisfy { near($0.height, row) } && near(l.spacing, spacing), "site geometry",
                  "\(tune): top \(l.top), rows \(i.map(\.height)), spacing \(l.spacing)")
        }
        check(P.items(.rows(8), .memories, fitting: 1 + 78 + 7 + 78).count == 2 && P.items(.rows(8), .memories, fitting: 1 + 78 + 7 + 77).count == 1,
              "site geometry", "a site's rows fit by its own height")
    }

    // MARK: No extra height: inline views draw inside today's loading view

    static func heightChecks() {
        for shape in [COSBuildUpShape.answer, .cardRows(2, badge: false), .cardRows(1, badge: true)] {
            for room in [14.0, 16, 20, 31, 35, 48, 64, 98, 200] {
                let items = P.items(shape, fitting: room)
                check(!items.isEmpty && P.height(items, layout: P.layout(shape)) <= room + 1e-9, "no extra height",
                      "\(shape) in \(room) pt drew \(P.height(items, layout: P.layout(shape))) pt")
                for item in items {
                    let used = item.lines.reduce(0) { $0 + $1.height } + Double(max(0, item.lines.count - 1)) * item.lineGap + 2 * item.padV
                    check(used <= item.height + 1e-9, "no extra height", "\(shape) in \(room): its lines take \(used) of \(item.height)")
                }
            }
        }
        check(P.items(.cardRows(2, badge: false), fitting: 35).count == 1 && near(P.items(.cardRows(2, badge: false), fitting: 35)[0].height, 35),
              "no extra height", "Needs you's one loading line holds one squeezed row")
        check(P.items(.rows(8), fitting: 4).isEmpty, "no extra height", "no room, no wire")
    }

    // MARK: The answer: inside today's one line, re-fit to the real text when it lands

    static func answerChecks() {
        let short = P.items(.answer)
        check(short.count == 1 && short[0].lines.count == 1 && near(short[0].height, 18), "answer size", "one line: \(short)")
        let one = P.items(.answer, measured: 17)[0], four = P.items(.answer, measured: 70)[0], tall = P.items(.answer, measured: 900)[0]
        check(one.lines.count == 1 && four.lines.count == 4 && near(four.height, 70) && tall.lines.count == 8, "answer refit",
              "lines follow the real text: \(one.lines.count) \(four.lines.count) \(tall.lines.count)")
        check(near(P.timeoutSeconds(.answer), 35) && P.timeoutSeconds(.answer) >= 30 + 5 && near(P.timeoutSeconds(.rows(1)), 20), "timeout",
              "an answer outlasts Meeting Ask's 30 s helper")
    }

    // MARK: The timing table

    static func timingChecks() {
        check(near(P.outline, 0.64) && near(P.nodes, 0.26) && near(P.wireText, 0.44), "durations", "the mock's draw: outline 640, nodes 260, wire 440")
        check(P.easeOut == (0.16, 0.84, 0.24, 1.0) && P.pop == (0.3, 1.6, 0.5, 1.0), "durations", "the mock's two curves")
        for i in 0..<8 {
            let d = Double(i)
            check(near(P.outlineStep(i).delay, d * 0.05) && near(P.wireTextStep(i).delay, d * 0.05 + 0.30) && near(P.nodeStep(i).delay, d * 0.05 + 0.46),
                  "stagger", "draw \(i): 50 ms per component")
            check(near(P.fillStep(i).delay, d * 0.015) && near(P.inkStep(i).delay, d * 0.015) && near(P.outlineFadeStep(i).delay, d * 0.015 + 0.10),
                  "stagger", "land \(i): 15 ms per component")
            check(near(P.branchStep(i).delay, d * 0.045 + 0.16) && near(P.junctionStep(i).delay, d * 0.045 + 0.28), "stagger", "traces \(i)")
            check(P.wireFadeStep(i).end <= P.inkStep(i).end, "ink order", "the wire text fades before the ink finishes \(i)")
        }
        check(P.inkStep(0).delay == 0, "ink soon", "the tint starts wiping at the data")
        check(P.inkStep(7).end <= 0.3 + 1e-9, "ink soon", "the tint is gone by 300 ms for 8 rows: \(P.inkStep(7).end)")
        check(P.outlineStep(3).delay < P.wireTextStep(3).delay && P.wireTextStep(3).delay < P.nodeStep(3).delay, "ink order", "outline, wire text, nodes")
        check(near(P.drawDuration(count: 1), 0.74) && near(P.drawDuration(count: 8), 7 * 0.05 + 0.74), "draw duration", "\(P.drawDuration(count: 8))")
        check(near(P.pulseSeconds, 0.7 + 3 * 1.4) && near(P.pingStart + 3 * P.pingPeriod, P.pulseSeconds), "pulse cap",
              "three flows, and three pings for the first node: \(P.pulseSeconds)")
    }

    // MARK: The settle comes from the same steps

    static func settleChecks() {
        for n in 1...8 {
            let settle = P.landDuration(count: n)
            check(settle <= 0.45 + 1e-9, "land duration", "\(n) components land within 450 ms: \(settle)")
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
    }

    // MARK: The tint: light, from the data, gone by 300 ms

    static func curtainChecks() {
        check(P.curtainAlpha <= 0.35, "curtain light", "\(P.curtainAlpha)")
        for i in 0..<8 {
            check(P.curtain(P.look(i, drawT: 2, landT: nil), landing: false) == 0, "curtain light", "no tint before the data")
            check(near(P.curtain(P.look(i, drawT: 2, landT: 0), landing: true), P.curtainAlpha), "curtain light", "the tint at the data, \(i)")
            check(P.curtain(P.look(i, drawT: 2, landT: 0.3), landing: true) < 1e-9, "curtain light", "gone by 300 ms, \(i)")
            var last = 1.0
            for k in 0...30 {
                let c = P.curtain(P.look(i, drawT: 2, landT: Double(k) * 0.01), landing: true)
                check(c <= P.curtainAlpha + 1e-9 && c <= last + 1e-9, "curtain light", "never more, only less: \(i) \(k) \(c)")
                last = c
            }
        }
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

    // MARK: The wire reads on its surface: the Running card is dark in both appearances

    static func contrastChecks() {
        func rgb(_ hex: Int) -> (r: Double, g: Double, b: Double) { (Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255) }
        func lum(_ c: (r: Double, g: Double, b: Double)) -> Double {
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }
        for (name, hex) in [("Running light", 0x2b211a), ("Running dark", 0x2f241b), ("panel dark", 0x17120d), ("Today panel dark", 0x221b15)] {
            let bg = rgb(hex)
            let ratio = P.contrast(wire: P.wire(onLuminance: lum(bg)), on: bg)
            check(ratio >= 3, "wire contrast", "\(name): \(ratio)")
        }
        let cream = rgb(0xf5f0e6)
        let mock = P.wire(onLuminance: lum(cream))
        check(near(mock.r, 137.0 / 255) && near(mock.a, 0.62), "wire contrast", "the mock's own wire on cream")
    }

    // MARK: Data inside 150 ms never builds

    static func graceChecks() {
        check(near(P.graceSeconds, 0.15), "grace delay", "\(P.graceSeconds)")
        var m = M(at: t0, loading: true, landed: false, reduceMotion: false, count: 6)
        check(m.phase == .grace && m.hidesContent && !m.drawsWire, "grace delay", "loading at open waits, drawing nothing")
        check(m.deadline.map { near($0, t0 + 0.15) } == true, "grace delay", "\(String(describing: m.deadline))")
        m.update(at: t0 + 0.149, loading: true, landed: false)
        check(m.phase == .grace, "grace delay", "still waiting at 149 ms: \(m.phase)")
        m.update(at: t0 + 0.12, loading: false, landed: true)
        check(m.phase == .settled && !m.hidesContent && !m.drawsWire && m.outcome == .direct, "grace skips build",
              "a fast load shows the content directly: \(m.phase)")
        var empty = M(at: t0, loading: true, landed: false, reduceMotion: false, count: 6)
        empty.update(at: t0 + 0.05, loading: false, landed: false)
        check(empty.phase == .settled && empty.outcome == .empty, "grace skips build", "a fast empty answer shows today's view directly, and counts as empty")
    }

    // MARK: First open only

    static func firstOpenChecks() {
        var m = building()
        m.update(at: t0 + 1, loading: false, landed: true)
        m.update(at: t0 + 5, loading: false, landed: true)
        check(m.phase == .settled, "first open only", "\(m.phase)")
        for k in 0..<20 {
            m.update(at: t0 + 10 + Double(k), loading: k % 2 == 0, landed: k % 3 == 0)
            check(m.phase == .settled && m.deadline == nil && !m.hidesContent && !m.drawsWire, "first open only",
                  "a refresh or poll never builds again: \(k) \(m.phase)")
        }
        let cached = M(at: t0, loading: true, landed: true, reduceMotion: false, count: 6)
        check(cached.phase == .settled && cached.deadline == nil, "cached open", "\(cached.phase)")
        let quiet = M(at: t0, loading: true, landed: false, reduceMotion: false, count: 6, quiet: true)
        check(quiet.phase == .settled && !quiet.hidesContent, "reopen", "a view COS has seen (or that was empty) opens quietly")
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
              "the data lands: the content shows at once, under the fading tint: \(m.phase)")
        check(m.landT(at: t0 + 2.3).map { near($0, 0.1, 1e-6) } == true && m.drawT(at: t0 + 2.3).map { near($0, 2.15, 1e-6) } == true, "land",
              "the landing has its clock, the draw keeps its own")
        let settle = P.landDuration(count: 6)
        check(m.deadline.map { near($0, t0 + 2.2 + settle) } == true, "land duration", "\(String(describing: m.deadline))")
        m.update(at: t0 + 2.2 + settle - 0.01, loading: false, landed: true)
        check(m.phase == .landing, "land duration", "not cut short: \(m.phase)")
        m.update(at: t0 + 2.2 + settle, loading: false, landed: true)
        check(m.phase == .settled && m.deadline == nil && !m.needsFrames(windowActive: true), "loop stops", "settled, nothing wakes again")
    }

    // MARK: After 3 s, today's words show and the wire text fades from them

    static func wordsChecks() {
        check(near(P.wordsSeconds, 3), "words", "\(P.wordsSeconds)")
        var m = building()
        m.update(at: t0 + 0.15 + 2.9, loading: true, landed: false)
        check(m.hidesContent && !m.wordsShown, "words", "the wire alone for a short wait")
        m.update(at: t0 + 0.15 + 3.01, loading: true, landed: false)
        check(m.wordsShown && !m.hidesContent && m.drawsWire, "words", "today's loading words join the wire")
        check(P.look(0, drawT: 2.9, landT: nil).textShown > 0.99 && P.look(0, drawT: P.wordsFadeStep.end, landT: nil).textShown < 1e-9
              && P.look(0, drawT: P.wordsFadeStep.end, landT: nil).outlineShown > 0.99, "words", "the wire text fades from the words; the outline stays")
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
    }

    // MARK: Driven by its own deadlines alone, the machine wakes exactly at each moment

    static func deadlineChecks() {
        var m = M(at: t0, loading: true, landed: false, reduceMotion: false, count: 4, timeout: 20)
        var wakes: [Double] = []
        while let next = m.deadline, wakes.count < 20 {
            wakes.append(next - t0)
            m.update(at: next, loading: true, landed: false)
            if near(next - t0, 0.15 + P.wordsSeconds, 1e-6) { check(m.wordsShown, "deadline wakes", "the words show at the 3 s wake itself") }
            if near(next - t0, 0.15 + P.pulseSeconds, 1e-6) { check(m.pulseDone && !m.needsFrames(windowActive: true), "deadline wakes", "the pulse stops at its wake") }
        }
        let expected = [0.15, 0.15 + P.drawDuration(count: 4), 0.15 + P.wordsSeconds, 0.15 + P.pulseSeconds, 0.15 + 20, 0.15 + 20 + P.handoffSeconds]
        check(wakes.count == expected.count && zip(wakes, expected).allSatisfy { near($0, $1, 1e-6) }, "deadline wakes", "woke at \(wakes), expected \(expected)")
        check(m.phase == .settled && m.outcome == .timeout && m.deadline == nil, "deadline wakes", "it ends settled on the timeout, with nothing left to wake")
    }

    // MARK: A load that never answers hands over to today's view

    static func timeoutChecks() {
        var m = building()
        m.update(at: t0 + 0.15 + 19.9, loading: true, landed: false)
        check(m.phase == .building, "timeout", "\(m.phase)")
        m.update(at: t0 + 0.15 + 20.01, loading: true, landed: false)
        check(m.phase == .handoff && m.outcome == .timeout && !m.hidesContent, "timeout", "no stuck wire, and today's view shows at once: \(m.phase)")
        m.update(at: t0 + 0.15 + 20.3, loading: true, landed: false)
        check(m.phase == .settled && !m.hidesContent && !m.drawsWire, "timeout", "today's spinner and words, as before")
        var ask = building(1, timeout: P.timeoutSeconds(.answer))
        ask.update(at: t0 + 0.15 + 30.5, loading: true, landed: false)
        check(ask.phase == .building, "timeout", "an answer still waits past the helper's 30 s")
    }

    // MARK: An error or an empty answer: today's view at once, the wire fades over it

    static func handoffChecks() {
        check(near(P.handoffSeconds, 0.2), "handoff fade", "\(P.handoffSeconds)")
        var m = building()
        m.update(at: t0 + 2, loading: false, landed: false)
        check(m.phase == .handoff && m.drawsWire && !m.hidesContent && m.outcome == .empty, "error handoff",
              "no data: the empty view shows at once, the wire fades over it: \(m.phase)")
        check(m.deadline.map { near($0, t0 + 2.2) } == true && m.handoffT(at: t0 + 2.1).map { near($0, 0.1, 1e-6) } == true,
              "handoff fade", "\(String(describing: m.deadline))")
        m.update(at: t0 + 2.19, loading: false, landed: false)
        check(m.phase == .handoff, "handoff fade", "\(m.phase)")
        m.update(at: t0 + 2.2001, loading: false, landed: false)
        check(m.phase == .settled && !m.hidesContent, "error handoff", "then today's view, as is: \(m.phase)")
        check(!P.hides(.handoff, wordsShown: false) && !P.hides(.landing, wordsShown: false) && P.hides(.building, wordsShown: false)
              && !P.hides(.building, wordsShown: true), "error handoff", "only a build before its words hides the content")
    }

    // MARK: A new load mid-landing settles the old one first

    static func midLandingChecks() {
        var m = building()
        m.update(at: t0 + 1, loading: false, landed: true)
        check(m.phase == .landing, "mid landing", "\(m.phase)")
        m.update(at: t0 + 1.2, loading: true, landed: true)
        check(m.phase == .settled && !m.drawsWire && !m.hidesContent, "mid landing", "the old landing settles at once: \(m.phase)")
    }

    // MARK: A search or tab switch during the first load; a view taken away

    static func interruptChecks() {
        var m = building()
        m.update(at: t0 + 1, loading: false, landed: false, interrupted: true)
        check(m.phase == .settled && m.outcome == .interrupted && !m.hidesContent, "interrupted", "settles quietly: \(m.phase) \(String(describing: m.outcome))")
        var grace = M(at: t0, loading: true, landed: false, reduceMotion: false, count: 6)
        grace.update(at: t0 + 0.05, loading: false, landed: false, interrupted: true)
        check(grace.outcome == .interrupted, "interrupted", "even inside the grace")
        var away = building()
        check(away.abandon(at: t0 + 1) && away.phase == .settled && away.outcome == .abandoned, "abandoned", "a view taken away mid-build")
        var done = building()
        done.update(at: t0 + 1, loading: false, landed: true)
        done.update(at: t0 + 3, loading: false, landed: true)
        check(!done.abandon(at: t0 + 4) && done.outcome == .landed, "abandoned", "a settled view abandons nothing")
    }

    // MARK: The memory: this session's views, and empty views across launches

    static func memoryChecks() {
        var memory = COSBuildUpMemory()
        check(memory.builds("Loading meetings|"), "memory", "a new view builds")
        check(!memory.record("Loading meetings|", .landed, persists: true) && !memory.builds("Loading meetings|") && memory.builds("Loading tasks|"),
              "memory", "seen once this session: lands quietly after, only that view")
        check(memory.record("Loading tasks|", .empty, persists: true) && memory.empty == ["Loading tasks|"], "memory", "an empty view is kept")
        let relaunched = COSBuildUpMemory(empty: memory.empty)
        check(!relaunched.builds("Loading tasks|") && relaunched.builds("Loading meetings|"), "memory",
              "after a relaunch an empty view shows today's view with no wire; a seen one builds again")
        var again = relaunched
        check(again.record("Loading tasks|", .landed, persists: true) && again.empty.isEmpty, "memory", "data again clears it")
        var keyed = COSBuildUpMemory()
        check(!keyed.record("Checking the meeting|abc", .empty, persists: false) && keyed.empty.isEmpty, "memory", "only label keys are kept")
        var bounded = COSBuildUpMemory()
        for k in 0..<100 { bounded.record("View \(k)|", .empty, persists: true) }
        check(bounded.empty.count == COSBuildUpMemory.emptyLimit && bounded.empty.last == "View 99|" && !bounded.empty.contains("View 0|"), "memory",
              "bounded to the newest \(COSBuildUpMemory.emptyLimit)")
        check(COSBuildUpMemory(empty: (0..<100).map { "V\($0)" }).empty.count == COSBuildUpMemory.emptyLimit, "memory", "bounded when read back")
        var quiet = COSBuildUpMemory()
        quiet.record("Loading sessions|", .interrupted, persists: true)
        quiet.record("Loading sessions|", .abandoned, persists: true)
        check(quiet.builds("Loading sessions|") && quiet.empty.isEmpty, "memory", "an interrupted or abandoned load is not remembered")
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
        check(m.count == 3 && m.deadline.map { near($0, t0 + 0.15 + P.drawDuration(count: 3)) } == true, "fit",
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
        check(P.breadcrumb(.answer, outcome: .abandoned, rows: 1, ms: 950) == "build-up answer outcome=abandoned rows=1 ms=950", "breadcrumb", "")
        var m = building()
        m.update(at: t0 + 0.9, loading: false, landed: true)
        check(m.outcome == .landed && m.loadStarted == t0 && m.outcomeAt == t0 + 0.9, "breadcrumb", "the machine keeps what the line reports")
    }

    // MARK: What each phase shows

    static func visibilityChecks() {
        let table: [(M.Phase, Bool, Bool)] = [(.fresh, false, false), (.grace, true, false), (.building, true, true),
                                              (.landing, false, true), (.handoff, false, true), (.settled, false, false)]
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
