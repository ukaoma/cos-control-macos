import OSLog
import SwiftUI

// MARK: - Section glyphs

/// The six section marks as real `Shape`s rather than SF Symbols.
///
/// They are vector paths so they can be `trim`med, which is what makes the gotcos
/// sketch-then-ink draw possible: an `Image(systemName:)` is a raster at draw time and
/// has no length to travel along. Every path is authored in a 20x20 design space and
/// scaled to the rect, so the same shape serves the 17pt icon and the large ghosted plate.
/// The filled type mark that rides the corner of a message bubble.
///
/// FILLED, not stroked, and that is the whole reason it works. The first pass
/// drew these as 1.15pt outlines at 10pt and every one collapsed into an
/// indistinct speck; a solid silhouette survives at that size where a hairline
/// cannot. Rendered at 64pt during design to confirm each shape is the thing
/// it claims to be -- which is how the original "mixed" paperclip was caught
/// reading as a battery, and became stacked cards instead.
struct AttachmentMark: Shape {
    /// "video" | "photo" | "document" | "mixed"
    let category: String

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 10
        let ox = rect.minX, oy = rect.minY
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }
        var path = Path()
        switch category {
        case "video":
            // Camcorder body plus lens wedge. A bare triangle would read as
            // "play" on anything, including a photo.
            path.addRoundedRect(in: box(1.9, 3.2, 4.6, 3.9), cornerSize: CGSize(width: 0.9 * s, height: 0.9 * s))
            path.move(to: p(7, 4.4)); path.addLine(to: p(8.4, 3.3))
            path.addLine(to: p(8.4, 7)); path.addLine(to: p(7, 5.9)); path.closeSubpath()
        case "photo":
            // Frame with the peak knocked out, so the silhouette is not just a
            // rectangle at 11pt.
            path.addRoundedRect(in: box(1.7, 2.6, 6.6, 5.2), cornerSize: CGSize(width: s, height: s))
            path.move(to: p(2.5, 7)); path.addLine(to: p(4.3, 4.9))
            path.addLine(to: p(6.1, 7)); path.closeSubpath()
        case "document":
            // Page with a folded corner; the fold is what separates it from
            // the photo frame in a glance.
            path.move(to: p(2.6, 2.2)); path.addLine(to: p(6, 2.2)); path.addLine(to: p(7.6, 3.8))
            path.addLine(to: p(7.6, 7.8)); path.addLine(to: p(2.6, 7.8)); path.closeSubpath()
        default:
            // Stacked cards for a mixed turn. Deliberately NOT a paperclip: a
            // clip needs a thin curved stem, and at this size that stem fills
            // in and reads as a battery.
            path.addRoundedRect(in: box(1.6, 1.6, 5, 5), cornerSize: CGSize(width: s, height: s))
            path.addRoundedRect(in: box(3.2, 3.2, 2.2, 2.2), cornerSize: CGSize(width: 0.6 * s, height: 0.6 * s))
            path.addRoundedRect(in: box(3.9, 3.9, 5, 5), cornerSize: CGSize(width: s, height: s))
        }
        return path
    }
}

struct SectionGlyph: Shape {
    let section: ActivitySection

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 20
        let ox = rect.minX + (rect.width - 20 * s) / 2
        let oy = rect.minY + (rect.height - 20 * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }
        func node(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGRect {
            CGRect(x: ox + (x - r) * s, y: oy + (y - r) * s, width: r * 2 * s, height: r * 2 * s)
        }

        var path = Path()
        switch section {
        case .messages:
            path.addRoundedRect(in: box(3, 4, 14, 9.5), cornerSize: CGSize(width: 2.5 * s, height: 2.5 * s))
            path.move(to: p(6.6, 13.5)); path.addLine(to: p(4.4, 16.6)); path.addLine(to: p(4.4, 13.5))

        case .speakers:
            for (x, h) in [(4.0, 2.5), (7.0, 4.6), (10.0, 6.6), (13.0, 3.6), (16.0, 1.6)] {
                path.move(to: p(x, 10 - h)); path.addLine(to: p(x, 10 + h))
            }

        case .meetings:
            path.addRoundedRect(in: box(3, 4.5, 14, 12), cornerSize: CGSize(width: 2 * s, height: 2 * s))
            path.move(to: p(3, 8.6)); path.addLine(to: p(17, 8.6))
            path.move(to: p(7, 3)); path.addLine(to: p(7, 6))
            path.move(to: p(13, 3)); path.addLine(to: p(13, 6))

        case .memories:
            // four-point spark, drawn as one continuous outline so the trim reads cleanly
            path.move(to: p(10, 3.4))
            path.addQuadCurve(to: p(16.6, 10), control: p(11.3, 8.7))
            path.addQuadCurve(to: p(10, 16.6), control: p(11.3, 11.3))
            path.addQuadCurve(to: p(3.4, 10), control: p(8.7, 11.3))
            path.addQuadCurve(to: p(10, 3.4), control: p(8.7, 8.7))

        case .threads:
            path.move(to: p(5, 4.8)); path.addLine(to: p(5, 8))
            path.addQuadCurve(to: p(8, 10), control: p(5, 10))
            path.addLine(to: p(12, 10))
            path.addQuadCurve(to: p(15, 12), control: p(15, 10))
            path.addLine(to: p(15, 15))
            path.addEllipse(in: node(5, 3.4, 1.4))
            path.addEllipse(in: node(15, 16.6, 1.4))

        case .sessions:
            path.addRoundedRect(in: box(2.8, 4, 14.4, 12), cornerSize: CGSize(width: 2 * s, height: 2 * s))
            path.move(to: p(6, 8.6)); path.addLine(to: p(8.5, 10.8)); path.addLine(to: p(6, 13))
            path.move(to: p(10.6, 13)); path.addLine(to: p(14.2, 13))

        case .work:
            path.addRoundedRect(in: box(3, 6, 14, 10), cornerSize: CGSize(width: 2 * s, height: 2 * s))
            path.move(to: p(7, 6)); path.addLine(to: p(7, 3.8)); path.addLine(to: p(13, 3.8)); path.addLine(to: p(13, 6))
            path.move(to: p(3, 10)); path.addLine(to: p(17, 10))

        case .dictation:
            // a microphone: capsule head, cradle arc, stem and foot
            path.addRoundedRect(in: box(7.4, 2.8, 5.2, 9), cornerSize: CGSize(width: 2.6 * s, height: 2.6 * s))
            path.move(to: p(4.6, 9.4)); path.addQuadCurve(to: p(15.4, 9.4), control: p(10, 18.6))
            path.move(to: p(10, 14)); path.addLine(to: p(10, 17))
            path.move(to: p(7, 17)); path.addLine(to: p(13, 17))

        case .tasks:
            path.addRoundedRect(in: box(4, 3.2, 12, 13.6), cornerSize: CGSize(width: 1.6 * s, height: 1.6 * s))
            path.move(to: p(6.4, 7.2)); path.addLine(to: p(8.2, 9.2)); path.addLine(to: p(13.4, 5.6))
            path.move(to: p(6.4, 12.4)); path.addLine(to: p(13.6, 12.4))
        }
        return path
    }
}

// MARK: - Halftone plate

/// Full-card stipple, the gotcos.com `.chapcard` paper — not a corner glyph.
///
/// Site CSS:
///   background-image: radial-gradient(gold .10 / 1px, transparent 1.1px);
///   background-size: 9px 9px;
///   mask-image: linear-gradient(135deg, transparent 12%, #000 100%);
///
/// Earlier Control cuts confined the same 5pt screen to a section mark in the
/// trailing corner. That is a different object than the brand: the public cards
/// are a FIELD of dots the copy sits on. Drawn in Canvas (a layer, never a
/// `.drawingGroup()` mask — that rasterises to nothing, 0.5.54).
struct HalftonePlate: View {
    var strong: Bool

    var body: some View {
        Canvas { ctx, size in
            let pitch: CGFloat = 9
            let r: CGFloat = 1.05
            let ink = COSPalette.plateInk.opacity(strong ? 0.28 : 0.14)
            var y: CGFloat = 0
            while y < size.height + pitch {
                var x: CGFloat = 0
                while x < size.width + pitch {
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(ink)
                    )
                    x += pitch
                }
                y += pitch
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.12),
                    .init(color: .black, location: 1),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .allowsHitTesting(false)
    }
}

// MARK: - Paint-in

/// Sketch-then-ink, the gotcos lockup's own motion: the outline draws itself on.
///
/// `trim(from:to:)` is the SwiftUI equivalent of anime.js `svg.createDrawable` — both
/// animate how much of a path is revealed along its length.
struct DrawIn: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View { content }
}

extension View {
    /// Left-to-right paint, the wipe the lockup uses for its four sections.
    ///
    /// Type cannot be dash-drawn — text is not a single path with a length to travel —
    /// so headings take this half of the same language while glyphs take the draw.
    func wipeIn(_ shown: Bool, delay: Double, reduceMotion: Bool) -> some View {
        self.mask(
            GeometryReader { geo in
                Rectangle()
                    .frame(width: (reduceMotion || shown) ? geo.size.width + 2 : 0)
                    .frame(width: geo.size.width, alignment: .leading)
            }
        )
        .animation(reduceMotion ? nil : .timingCurve(0.3, 0.72, 0, 1, duration: 0.46).delay(delay),
                   value: shown)
    }
}

// MARK: - Motion tokens

/// The shared motion scale gotcos.com and the Glasses companion use (transitions.dev,
/// commit 54fbee8): `cos-starter/assets/motion.css` and the companion's `public/tokens.css`.
/// Match a value on what the motion does, not on the nearest number. Opens are slower
/// than closes, overshoot is for entrances only, and a stagger is 40 ms per item with the
/// total kept under ~300 ms.
enum Motion {
    static let stagger = 0.04    // per-item offset
    static let micro = 0.08      // intent delay, shake segment
    static let quick = 0.15      // close, dismiss, text swap
    static let fast = 0.25       // open, route change, accordion, list to detail
    static let medium = 0.35     // panel close, notice arriving
    static let slow = 0.40       // panel open, skeleton to content
    static let verySlow = 0.50   // emphasis: counters, success check
    static let distance: CGFloat = 8  // a side-by-side page travels this far, not full width

    /// The default curve for anything that opens, closes, slides or resizes.
    static func smoothOut(_ duration: Double) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }

    /// Overshoot for entrances only (a count arriving, a badge). Never for a close.
    static func bounce(_ duration: Double) -> Animation {
        .timingCurve(0.34, 1.36, 0.64, 1, duration: duration)
    }

    /// `nil` under Reduce Motion, so `withAnimation(Motion.gated(...))` changes state with
    /// no animation at all. Every withAnimation that moves or scrolls goes through this.
    static func gated(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - Palette additions

extension COSPalette {
    /// Plate ink. Dark dots multiplied into cream; a warm light on espresso, because a
    /// dark plate on a dark card is the black-on-black failure this app has hit before.
    static let plateInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.79, green: 0.66, blue: 0.43, alpha: 1)   // gold
            : NSColor(red: 0.17, green: 0.13, blue: 0.09, alpha: 1)   // #2b2117
    })

}

// MARK: - Build-up, in place (0.5.343)

extension COSPalette {
    /// The build-up's gold wire: rgba(137,102,45,.62) on Control's cream, the brand gold at the same weight on espresso.
    static let wire = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.79, green: 0.66, blue: 0.43, alpha: 0.62)
            : NSColor(red: 137 / 255, green: 102 / 255, blue: 45 / 255, alpha: 0.62)
    })
    /// The node ping's ring (the mock's --wire-soft).
    static let wireSoft = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.79, green: 0.66, blue: 0.43, alpha: 0.30)
            : NSColor(red: 137 / 255, green: 102 / 255, blue: 45 / 255, alpha: 0.28)
    })
    /// A wire capsule filled solid (the mock's --bone): ink at 10% on cream, cream at 10% on espresso.
    static let wireBone = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 0.10)
            : NSColor(red: 31 / 255, green: 23 / 255, blue: 18 / 255, alpha: 0.10)
    })
}

/// A frozen moment of the build, for static renders only: `phase`, `drawT` seconds into the build (its own clock, which
/// keeps running through the landing), `phaseT` seconds into a landing or a hand-off. The app never passes one.
struct COSBuildUpFrame: Equatable {
    var phase: COSBuildUpMachine.Phase
    var drawT: Double
    var phaseT: Double = 0
}

/// Test hooks, nil in the app: every live frame the stage draws (shape, phase, draw clock, the first outline as shown) and
/// every breadcrumb. Tests/BuildUpViewChecks.swift sets them to watch the real view run.
@MainActor enum COSBuildUpProbe {
    static var frame: ((String, COSBuildUpMachine.Phase, Double, Double) -> Void)?
    static var breadcrumb: ((String) -> Void)?
}

/// What this app session remembers per view (COSBuildUpMemory): seen views reopen quietly, empty ones draw no rows.
@MainActor enum COSBuildUpSession {
    static var memory = COSBuildUpMemory()
}

private let buildUpLog = Logger(subsystem: "com.gotcos.control", category: "build-up")

/// The approved "build-up, in place" loading reveal, as one reusable wrapper (the timing, the memory and the state machine
/// are COSBuildUpPlan, COSBuildUpMemory and COSBuildUpMachine in Models.swift). A call site wraps its existing view,
/// untouched, and declares only the placeholder shape and its loading state:
///
///     COSBuildUp(.rows(6), loading: model.tasksLoading && model.tasks.isEmpty, landed: !model.tasks.isEmpty,
///                label: "Loading tasks") { …today's if / else chain, spinner, error and empty views included… }
///
/// The wrapped view is ALWAYS laid out and live, so its loads, tasks, error and empty paths run exactly as before. While the
/// first load builds it is only hidden (opacity, hit testing and accessibility), and the wire is an overlay that never
/// takes a click. Once the data lands the content is live and clickable at once; the ink is a curtain over it that clicks
/// pass through. After 3 s with no data today's loading words show under the wire.
struct COSBuildUp<Content: View>: View {
    let shape: COSBuildUpShape
    let loading: Bool
    let landed: Bool
    let label: String
    let key: AnyHashable?
    let background: Color
    let frozen: COSBuildUpFrame?
    @ViewBuilder let content: () -> Content

    /// `label`: what VoiceOver hears while it builds ("Loading meetings"), and with `key` what the session remembers.
    /// `key`: the thing the view shows (a meeting's id); when it changes the view counts as opened again. `background`: the
    /// surface behind the content, which the ink wipes away as it reveals the content. `frozen`: static renders only.
    init(_ shape: COSBuildUpShape, loading: Bool, landed: Bool, label: String, key: AnyHashable? = nil,
         background: Color = COSPalette.panel, frozen: COSBuildUpFrame? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.shape = shape
        self.loading = loading
        self.landed = landed
        self.label = label
        self.key = key
        self.background = background
        self.frozen = frozen
        self.content = content
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var machine: COSBuildUpMachine?
    /// An inline view's real height once it lands (the answer re-fits its wire to the text's lines).
    @State private var measured: Double?

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    private var layout: COSBuildUpLayout { COSBuildUpPlan.layout(shape) }
    private var memoryKey: String { label + "|" + (key.map { String(describing: $0) } ?? "") }

    private func opened(at t: Double) -> COSBuildUpMachine {
        COSBuildUpMachine(at: t, loading: loading, landed: landed, reduceMotion: reduceMotion, count: COSBuildUpPlan.items(shape).count,
                          quiet: frozen == nil && !COSBuildUpSession.memory.builds(memoryKey))
    }

    var body: some View {
        let now = Self.now()
        let live = frozen == nil
        let current = machine ?? opened(at: now)
        let phase = frozen?.phase ?? current.phase
        let hide = frozen.map { $0.phase == .grace || $0.phase == .handoff || ($0.phase == .building && $0.drawT < COSBuildUpPlan.wordsSeconds) }
            ?? current.hidesContent
        let wire = phase == .building || phase == .landing || phase == .handoff
        sized(content()
            .opacity(hide ? 0 : 1)
            .allowsHitTesting(!hide)
            .accessibilityHidden(hide), hide: hide, reserve: phase == .grace || phase == .building || phase == .handoff)
            .overlay(alignment: .topLeading) {
                if wire {
                    COSBuildUpLiveStage(shape: shape, machine: current, frozen: frozen, measured: measured, background: background,
                                        onFit: fit)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                if hide {
                    // While it builds, the container says what it is waiting for.
                    Color.clear
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(label)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .onAppear { if live, machine == nil { machine = opened(at: Self.now()) } }
            .onChange(of: loading) { _, _ in step() }
            .onChange(of: landed) { _, _ in step() }
            .onChange(of: reduceMotion) { _, _ in step() }
            .onChange(of: key) { _, _ in reopen() }
            .task(id: live ? machine?.deadline(after: now) : nil) {
                guard live, let deadline = machine?.deadline(after: Self.now()) else { return }
                let wait = deadline - Self.now()
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000) + 1_000_000) }
                guard !Task.isCancelled else { return }
                step()
            }
    }

    /// A pane-filling view takes the whole container while it builds, so the wire is fitted to the room the content will
    /// have, not to the loading view's own size. An inline component holds the space its short wire needs while it
    /// builds, then takes its real height when it lands.
    @ViewBuilder
    private func sized<V: View>(_ view: V, hide: Bool, reserve: Bool) -> some View {
        if layout.fills {
            view.frame(maxWidth: hide ? .infinity : nil, maxHeight: hide ? .infinity : nil, alignment: .topLeading)
        } else {
            view
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in measure(Double(height)) }
                })
                .frame(maxWidth: reserve ? .infinity : nil, minHeight: reserve ? CGFloat(COSBuildUpPlan.height(COSBuildUpPlan.items(shape), layout: layout)) : nil,
                       alignment: .topLeading)
        }
    }

    private func measure(_ height: Double) {
        guard (frozen?.phase ?? machine?.phase) == .landing, abs(height - (measured ?? -1)) > 0.5 else { return }
        measured = height
    }

    private func fit(_ count: Int) {
        guard frozen == nil, var next = machine, next.phase == .building || next.phase == .grace, next.count != count else { return }
        next.fit(count)
        if next != machine { machine = next }
    }

    private func step() {
        guard frozen == nil else { return }
        var next = machine ?? opened(at: Self.now())
        let before = next.outcome
        next.update(at: Self.now(), loading: loading, landed: landed, reduceMotion: reduceMotion)
        // Settled and unchanged (every refresh and poll after the first load): nothing is written, so nothing redraws.
        guard next != machine else { return }
        if before == nil, let outcome = next.outcome { remember(outcome, next) }
        machine = next
    }

    private func reopen() {
        guard frozen == nil else { return }
        let next = opened(at: Self.now())
        measured = nil
        if next != machine { machine = next }
    }

    /// One breadcrumb per load the build was ready for, through the app's log: shape, outcome, rows and time, no text.
    private func remember(_ outcome: COSBuildUpMachine.Outcome, _ machine: COSBuildUpMachine) {
        COSBuildUpSession.memory.record(memoryKey, outcome)
        let started = machine.loadStarted ?? machine.opened
        let line = COSBuildUpPlan.breadcrumb(shape, outcome: outcome, rows: machine.count,
                                             ms: Int((((machine.outcomeAt ?? started) - started) * 1000).rounded()))
        buildUpLog.notice("\(line, privacy: .public)")
        COSBuildUpProbe.breadcrumb?(line)
    }
}

/// Frames for the stage while something moves (the draw, the pulse, the landing, the hand-off), one entry when it stands
/// still. The view that holds it exists only while the wire is on screen.
private struct COSBuildUpSchedule: TimelineSchedule {
    let paused: Bool
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        var done = false
        let paused = paused
        return AnyIterator {
            if paused {
                if done { return nil }
                done = true
                return startDate
            }
            defer { next = next.addingTimeInterval(1.0 / 60) }
            return next
        }
    }
}

/// The live clock around the stage: it reads the window's state here (so a window becoming key never re-evaluates the
/// wrapped content), fits the wire to the container as it resizes, and draws a frame only while something moves.
private struct COSBuildUpLiveStage: View {
    let shape: COSBuildUpShape
    let machine: COSBuildUpMachine
    let frozen: COSBuildUpFrame?
    let measured: Double?
    let background: Color
    let onFit: (Int) -> Void
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        GeometryReader { geometry in
            let active = activeState != .inactive
            Group {
                if let frozen {
                    COSBuildUpStage(shape: shape, phase: frozen.phase, drawT: frozen.drawT,
                                    landT: frozen.phase == .landing ? frozen.phaseT : nil, handoffT: frozen.phase == .handoff ? frozen.phaseT : nil,
                                    pulsing: frozen.phase == .building, limit: nil, measured: measured, size: geometry.size, background: background)
                } else {
                    TimelineView(COSBuildUpSchedule(paused: !machine.needsFrames(windowActive: active))) { _ in
                        let t = ProcessInfo.processInfo.systemUptime
                        let drawT = machine.drawT(at: t) ?? 0
                        let _ = COSBuildUpProbe.frame?(shape.kind, machine.phase, drawT,
                                                       COSBuildUpPlan.look(0, drawT: drawT, landT: machine.landT(at: t)).outlineShown)
                        COSBuildUpStage(shape: shape, phase: machine.phase, drawT: drawT, landT: machine.landT(at: t), handoffT: machine.handoffT(at: t),
                                        pulsing: machine.pulses(windowActive: active), limit: machine.count, measured: measured,
                                        size: geometry.size, background: background)
                    }
                }
            }
            .onAppear { onFit(fitted(geometry.size.height)) }
            .onChange(of: geometry.size.height) { _, height in onFit(fitted(height)) }
        }
    }

    private func fitted(_ height: CGFloat) -> Int {
        COSBuildUpPlan.items(shape, fitting: COSBuildUpPlan.layout(shape).fills ? Double(height) : nil).count
    }
}

/// The wire itself, drawn from COSBuildUpPlan.look at one moment: every layer at the coordinates the plan gives, so nothing
/// ever moves position. No SwiftUI animation, no repeating animation: the clock is the frame.
private struct COSBuildUpStage: View {
    let shape: COSBuildUpShape
    let phase: COSBuildUpMachine.Phase
    let drawT: Double
    let landT: Double?
    let handoffT: Double?
    let pulsing: Bool
    let limit: Int?
    let measured: Double?
    let size: CGSize
    let background: Color

    private var layout: COSBuildUpLayout { COSBuildUpPlan.layout(shape) }

    var body: some View {
        // A filling view fits the container (and follows a resize); a landed inline view fits its real content, and an
        // answer re-fits its lines to the real text before it inks.
        let landedInline = phase == .landing && !layout.fills ? measured : nil
        let items = COSBuildUpPlan.items(shape, limit: limit, fitting: layout.fills ? Double(size.height) : landedInline,
                                         measured: shape == .answer ? landedInline : nil)
        let looks = items.indices.map { COSBuildUpPlan.look($0, drawT: drawT, landT: landT) }
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                curtain(index, item, looks[index], items: items)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                wireFrame(index, item, looks[index], items: items)
            }
            traces(items)
            if pulsing { pulse(items) }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .opacity(handoffT.map { max(0, 1 - $0 / COSBuildUpPlan.handoffSeconds) } ?? 1)
    }

    private func rect(_ index: Int, _ item: COSBuildUpItem, items: [COSBuildUpItem]) -> CGRect {
        CGRect(x: layout.leading, y: COSBuildUpPlan.top(index, in: items, layout: layout),
               width: max(0, Double(size.width) - layout.leading - layout.trailing), height: item.height)
    }

    /// One band of the curtain over the content: the surface, the fill and the wire text, from this component's top (the
    /// first also covers the inset above it) to the next one's (the last to the bottom), cut back to the right of its ink
    /// edge. Clicks pass through it to the content, which is live the moment the data lands.
    @ViewBuilder
    private func curtain(_ index: Int, _ item: COSBuildUpItem, _ look: COSBuildUpLook, items: [COSBuildUpItem]) -> some View {
        let box = rect(index, item, items: items)
        let top = index == 0 ? 0 : box.minY
        let bottom = index == items.count - 1 ? max(Double(size.height), box.maxY) : COSBuildUpPlan.top(index + 1, in: items, layout: layout)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(background).opacity(phase == .landing ? 1 : 0)
            if item.style == .card {
                RoundedRectangle(cornerRadius: item.radius, style: .continuous)
                    .fill(COSPalette.card)
                    .frame(width: box.width, height: box.height)
                    .mask(alignment: .leading) { Rectangle().frame(width: box.width * look.fill) }
                    .offset(x: box.minX, y: box.minY - top)
            }
            capsules(item, look, box: box)
                .offset(x: box.minX, y: box.minY - top)
        }
        .frame(width: size.width, height: max(0, bottom - top), alignment: .topLeading)
        .clipped()
        .mask(alignment: .trailing) { Rectangle().frame(width: max(0, size.width * (1 - look.ink))) }
        .offset(y: top)
    }

    /// Step 4 (the text as outlined capsules, left to right), then step 6 (solid, and gone ahead of the ink).
    private func capsules(_ item: COSBuildUpItem, _ look: COSBuildUpLook, box: CGRect) -> some View {
        let inner = box.insetBy(dx: item.padH, dy: item.padV)
        let lead = item.lead.map { CGFloat($0) + 10 } ?? 0
        let trailingRoom = item.trailing.isEmpty ? 0 : CGFloat(item.trailing.reduce(0, +)) + CGFloat(item.trailing.count) * 6 + 12
        let room = max(0, inner.width - lead - trailingRoom)
        let block = item.lines.reduce(0) { $0 + $1.height } + Double(max(0, item.lines.count - 1)) * item.lineGap
            + (item.chips.isEmpty ? 0 : item.lineGap + item.chipHeight)
        let y0 = max(0, (Double(inner.height) - block) / 2)
        return ZStack(alignment: .topLeading) {
            if let leadWidth = item.lead {
                wireCapsule(width: CGFloat(leadWidth), height: CGFloat(item.lines.first?.height ?? 10) + (item.lines.count > 1 ? 6 : 0), look: look)
                    .offset(x: 0, y: CGFloat(y0))
            }
            VStack(alignment: .leading, spacing: CGFloat(item.lineGap)) {
                ForEach(Array(item.lines.enumerated()), id: \.offset) { _, line in
                    wireCapsule(width: room * CGFloat(line.width), height: CGFloat(line.height), look: look)
                }
                if !item.chips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(item.chips.enumerated()), id: \.offset) { _, chip in
                            wireCapsule(width: CGFloat(chip), height: CGFloat(item.chipHeight), look: look, radius: 5)
                        }
                    }
                }
            }
            .offset(x: lead, y: CGFloat(y0))
            if !item.trailing.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(item.trailing.enumerated()), id: \.offset) { _, pill in
                        wireCapsule(width: CGFloat(pill), height: 16, look: look)
                    }
                }
                .frame(width: inner.width, height: inner.height, alignment: .trailing)
                .padding(.trailing, 12)
            }
        }
        .frame(width: inner.width, height: inner.height, alignment: .topLeading)
        .offset(x: CGFloat(item.padH), y: CGFloat(item.padV))
        .opacity(1 - look.wireFade)
    }

    private func wireCapsule(width: CGFloat, height: CGFloat, look: COSBuildUpLook, radius: CGFloat? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? height / 2, style: .continuous)
        return ZStack {
            shape.fill(COSPalette.wireBone).opacity(look.solid)
            shape.stroke(COSPalette.wire, lineWidth: 1).opacity(1 - look.solid)
        }
        .frame(width: max(0, width), height: height)
        .mask(alignment: .leading) { Rectangle().frame(width: max(0, width) * look.wireText) }
    }

    /// Steps 1 and 2, then 8: the outline traces on, the four corner nodes pop, and both hand over to the real border.
    private func wireFrame(_ index: Int, _ item: COSBuildUpItem, _ look: COSBuildUpLook, items: [COSBuildUpItem]) -> some View {
        let box = rect(index, item, items: items)
        let node = 7 * CGFloat(look.nodes)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: item.radius, style: .continuous)
                .trim(from: 0, to: look.outline)
                .stroke(COSPalette.wire, lineWidth: 1)
                .opacity(1 - look.outlineFade)
                .frame(width: box.width, height: box.height)
            ForEach(0..<4, id: \.self) { corner in
                Circle().fill(background)
                    .overlay(Circle().stroke(COSPalette.wire, lineWidth: 1.2))
                    .frame(width: node, height: node)
                    .frame(width: 7, height: 7)
                    .opacity(1 - look.nodeFade)
                    .offset(x: (corner % 2 == 0 ? 0 : box.width) - 3.5, y: (corner < 2 ? 0 : box.height) - 3.5)
            }
        }
        .offset(x: box.minX, y: box.minY)
    }

    private func spine(_ items: [COSBuildUpItem]) -> (x: CGFloat, top: CGFloat, bottom: CGFloat)? {
        guard let x = layout.spineX, !items.isEmpty else { return nil }
        return (CGFloat(x), CGFloat(COSBuildUpPlan.junctionY(0, in: items, layout: layout) - 10),
                CGFloat(COSBuildUpPlan.junctionY(items.count - 1, in: items, layout: layout)))
    }

    /// Step 3: the spine down the left, a branch and a junction node to each component; all of it fades once the data lands.
    @ViewBuilder
    private func traces(_ items: [COSBuildUpItem]) -> some View {
        if let spine = spine(items) {
            ZStack(alignment: .topLeading) {
                Path { path in path.move(to: CGPoint(x: spine.x, y: spine.top)); path.addLine(to: CGPoint(x: spine.x, y: spine.bottom)) }
                    .trim(from: 0, to: COSBuildUpPlan.progress(COSBuildUpPlan.spineStep, at: drawT))
                    .stroke(COSPalette.wire, lineWidth: 1)
                ForEach(items.indices, id: \.self) { index in
                    let y = CGFloat(COSBuildUpPlan.junctionY(index, in: items, layout: layout))
                    let pop = 6 * CGFloat(COSBuildUpPlan.progress(COSBuildUpPlan.junctionStep(index), at: drawT, curve: COSBuildUpPlan.pop))
                    Path { path in path.move(to: CGPoint(x: spine.x, y: y)); path.addLine(to: CGPoint(x: CGFloat(layout.leading) - 4, y: y)) }
                        .trim(from: 0, to: COSBuildUpPlan.progress(COSBuildUpPlan.branchStep(index), at: drawT))
                        .stroke(COSPalette.wire, lineWidth: 1)
                    Circle().fill(background)
                        .overlay(Circle().stroke(COSPalette.wire, lineWidth: 1.2))
                        .frame(width: pop, height: pop)
                        .frame(width: 6, height: 6)
                        .offset(x: spine.x - 3, y: y - 3)
                }
            }
            .opacity(1 - (landT.map { COSBuildUpPlan.progress(COSBuildUpPlan.tracesFadeStep, at: $0) } ?? 0))
        }
    }

    /// While it loads, for its cycles: a short bright segment flows down the spine and each first corner node pings.
    @ViewBuilder
    private func pulse(_ items: [COSBuildUpItem]) -> some View {
        ZStack(alignment: .topLeading) {
            if let spine = spine(items), let head = COSBuildUpPlan.flow(drawT: drawT) {
                Path { path in path.move(to: CGPoint(x: spine.x, y: spine.top)); path.addLine(to: CGPoint(x: spine.x, y: spine.bottom)) }
                    .trim(from: head, to: min(1, head + COSBuildUpPlan.flowLength))
                    .stroke(COSPalette.wire, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            ForEach(items.indices, id: \.self) { index in
                if let spread = COSBuildUpPlan.ping(index, drawT: drawT) {
                    Circle().stroke(COSPalette.wireSoft, lineWidth: 2)
                        .frame(width: 7 + 10 * spread, height: 7 + 10 * spread)
                        .opacity(1 - spread)
                        .frame(width: 7, height: 7)
                        .offset(x: CGFloat(layout.leading) - 3.5, y: CGFloat(COSBuildUpPlan.top(index, in: items, layout: layout)) - 3.5)
                }
            }
        }
    }
}

/// Pixel COS figure for the desktop session pet. Working opens the visor dots;
/// waiting keeps them as dashes. Drawn on a 16-unit grid so nearest-neighbor
/// scale stays blocky. Medium is 64 pt. A custom PNG or pose strip skips the
/// canvas and scales with interpolation off so pixel art stays blocky.
struct PetSpriteClip {
    var frames: [NSImage]
    var frameInterval: Double
}

struct SessionPetSprite: View {
    var working: Bool
    var reduceMotion: Bool
    var customImage: NSImage? = nil
    var frames: [NSImage] = []
    var pose: PetSpritePose = .idle
    var frameInterval: Double? = nil
    var size: CGFloat = 64
    /// The character dial only; the card around this view sizes off PetSize.
    var characterScale: CGFloat = 1
    /// Multiplies the animation clock only. 0.25 is quarter speed, 2 is double.
    var animationSpeed: Double = 1
    /// Exact secondary clips an ambient action rotates through between bursts.
    var restClips: [PetSpriteClip] = []
    var rotation: PetEncounterRotation? = nil
    var encounterPlayback: PetEncounterPlayback? = nil
    /// 0.5.337 (performance audit W4): nobody can see the pet (covered, locked, displays asleep), so its clock stops.
    var paused: Bool = false

    /// Patrol is an ambient action rather than a state. Authored running and
    /// duel story strips bypass this scheduler and play in order.
    private var playlists: Bool {
        pose.usesActivityPlaylist && frames.count > 1 && !usableRestClips.isEmpty && !reduceMotion
    }

    private var usableRestClips: [PetSpriteClip] {
        restClips.filter { $0.frames.count > 1 }
    }

    private var timelineInterval: Double {
        guard !reduceMotion else { return 3600 }
        let candidates = [primaryFrameInterval]
            + (playlists ? usableRestClips.map(\.frameInterval) : [])
        let authored = candidates.filter { $0 > 0 }.min() ?? primaryFrameInterval
        return authored / resolvedAnimationSpeed
    }

    private var primaryFrameInterval: Double {
        frameInterval ?? pose.frameInterval(forFrames: frames.count)
    }

    private var resolvedAnimationSpeed: Double {
        min(max(animationSpeed, 0.25), 2)
    }

    var body: some View {
        let interval = timelineInterval
        // V4's duel, trio and swarm strips are continuous animations. Blending
        // adjacent cells double-exposes two different fight poses and reads as
        // a washed-out ghost, so every authored animation advances frame-clean.
        TimelineView(.animation(minimumInterval: interval, paused: paused || (reduceMotion && frames.count <= 1))) { timeline in
            let encounter = encounterPlayback?.sample(pose: pose, rotation: rotation, now: ProcessInfo.processInfo.systemUptime,
                                                       speed: resolvedAnimationSpeed, interval: primaryFrameInterval, paused: reduceMotion)
            let elapsed = timeline.date.timeIntervalSinceReferenceDate * resolvedAnimationSpeed
            let phase = reduceMotion ? 0.0 : sin(elapsed * (working ? 6.2 : 2.4))
            // Encounter strips already author their landing and ground contact.
            let bounce = working && !reduceMotion && encounter == nil ? CGFloat(phase) * max(1, size * 0.022) : 0
            Group {
                if let rotation, let encounter {
                    ZStack {
                        ForEach(Array(rotation.layers(for: encounter).enumerated()), id: \.offset) { _, image in
                            frameImage(image)
                        }
                    }
                } else if playlists, let frame = playlistFrame(elapsed: elapsed) {
                    frameImage(frame)
                } else if let frame = playbackFrame(elapsed: elapsed) {
                    frameImage(frame)
                } else if let customImage {
                    Image(nsImage: customImage)
                        .interpolation(.none)
                        .antialiased(false)
                        .resizable()
                        .scaledToFit()
                } else {
                    Canvas { ctx, canvasSize in
                        let unit = floor(min(canvasSize.width, canvasSize.height) / 16)
                        let ox = (canvasSize.width - unit * 16) / 2
                        let oy = (canvasSize.height - unit * 16) / 2
                        func cell(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
                            ctx.fill(
                                Path(CGRect(x: ox + x * unit, y: oy + y * unit, width: w * unit, height: h * unit)),
                                with: .color(color)
                            )
                        }
                        let ink = COSPalette.ink
                        let gold = COSPalette.gold
                        let cream = COSPalette.cream
                        let visor = Color(red: 0.18, green: 0.12, blue: 0.08)
                        cell(3, 2, 10, 7, ink)
                        cell(4, 3, 8, 5, gold)
                        cell(5, 4, 6, 3, visor)
                        if working {
                            cell(6, 5, 1, 1, cream)
                            cell(9, 5, 1, 1, cream)
                        } else {
                            cell(6, 5, 2, 1, cream)
                            cell(8, 5, 2, 1, cream)
                        }
                        cell(5, 9, 6, 5, gold)
                        cell(6, 10, 4, 2, cream)
                        cell(6, 11, 1, 1, ink)
                        cell(8, 11, 2, 1, ink)
                        cell(5, 14, 2, 1, ink)
                        cell(9, 14, 2, 1, ink)
                    }
                }
            }
            .offset(y: bounce)
        }
        .frame(width: displayWidth, height: displayHeight)
        .accessibilityHidden(true)
    }

    /// Measured aspect of the art actually playing; nil falls back to the pose
    /// default. The panel sizes off this same number.
    private var measuredAspect: CGFloat {
        PetSpriteKit.resolvedAspect(frames: frames)
    }

    private var displayHeight: CGFloat {
        pose.renderSize(Int(size.rounded()), scale: characterScale, aspect: measuredAspect).height
    }

    private var displayWidth: CGFloat {
        pose.renderSize(Int(size.rounded()), scale: characterScale, aspect: measuredAspect).width
    }

    private func frameImage(_ frame: NSImage) -> some View {
        // Compare against the size it is DRAWN at, not the configured pixel
        // size: the character dial and cinematic envelope can enlarge that
        // substantially, so a fixed threshold blurs upscaled pixel art.
        let pixelated = max(frame.size.width, frame.size.height) <= displayHeight
        return Image(nsImage: frame)
            .interpolation(pixelated ? .none : .medium)
            .antialiased(false)
            .resizable()
            .scaledToFit()
    }

    /// Absolute-time schedule, so no per-instance state has to survive the
    /// panel rebuilding its root view on every poll.
    private func playlistFrame(elapsed: Double) -> NSImage? {
        let rests = usableRestClips
        let plan = PetPlaylist.plan(
            elapsed: elapsed,
            actionCount: frames.count,
            restCounts: rests.map { $0.frames.count },
            interval: primaryFrameInterval,
            restIntervals: rests.map(\.frameInterval)
        )
        let clip = plan.useAction ? frames : rests[min(plan.restClip, rests.count - 1)].frames
        guard !clip.isEmpty else { return nil }
        return clip[min(plan.index, clip.count - 1)]
    }

    // Internal so the native runtime canary can exercise the actual selector.
    func playbackFrame(elapsed: Double) -> NSImage? {
        guard !frames.isEmpty else { return nil }
        if reduceMotion || frames.count == 1 {
            let index = pose.cinematic ? min(frames.count - 1, max(0, frames.count / 2)) : 0
            return frames[index]
        }
        let index = Int(elapsed / primaryFrameInterval) % frames.count
        return frames[index]
    }
}


/// The pet's panel geometry had no telemetry at all: `grep` for a logger in
/// SessionPet.swift returned one hit and it was the word "logo" in a comment.
/// Three separate attempts at the open/close jump each needed a round trip
/// through Miles to disprove, because the only evidence available was a
/// screenshot. These four values — the guard, the parked anchor, the frame we
/// found and the frame we set — are what discriminate between "the handler
/// never ran", "it ran and declined" and "it ran and corrected".
enum PetLog {
    private static let log = Logger(subsystem: "com.gotcos.control", category: "pet-panel")
    static func panel(_ message: String) { log.debug("\(message, privacy: .public)") }
}
