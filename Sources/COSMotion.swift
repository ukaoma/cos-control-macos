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

/// The shared motion scale gotcos.com and the Glasses companion use (transitions.dev, commit 54fbee8): only the values
/// Control uses so far. `quick` folds and dismisses, `fast` opens, routes and scrolls.
enum Motion {
    static let quick = 0.15
    static let fast = 0.25

    /// `nil` under Reduce Motion, so `withAnimation(Motion.gated(...))` changes state with no animation at all. The
    /// transcript fold, the setup-guide scroll and the chat match scroll go through it (0.5.343).
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
    /// The build-up's wire on `background`: the mock's brown rgba(137,102,45,.62) on a light surface, the brand gold on a
    /// dark one (COSBuildUpPlan.wire), chosen from the surface itself, so the Running card (dark in both appearances)
    /// gets the gold in light mode too.
    @MainActor static func wire(on background: Color, in environment: EnvironmentValues) -> Color {
        let w = COSBuildUpPlan.wire(onLuminance: buildUpLuminance(background, environment))
        return Color(.sRGB, red: w.r, green: w.g, blue: w.b, opacity: w.a)
    }
    /// A wire capsule filled solid (the mock's --bone): ink at 10% on a light surface, cream at 10% on a dark one.
    @MainActor static func wireBone(on background: Color, in environment: EnvironmentValues) -> Color {
        buildUpLuminance(background, environment) < 0.18 ? Color(.sRGB, red: 0.96, green: 0.94, blue: 0.90, opacity: 0.10)
            : Color(.sRGB, red: 31.0 / 255, green: 23.0 / 255, blue: 18.0 / 255, opacity: 0.10)
    }
    @MainActor static func buildUpLuminance(_ color: Color, _ environment: EnvironmentValues) -> Double {
        let resolved = color.resolve(in: environment)
        return 0.2126 * Double(resolved.linearRed) + 0.7152 * Double(resolved.linearGreen) + 0.0722 * Double(resolved.linearBlue)
    }
}

/// A frozen moment of the build, for static renders only: `phase`, `drawT` seconds into the build (its own clock, which
/// keeps running through the landing), `phaseT` seconds into a landing or a hand-off. The app never passes one.
struct COSBuildUpFrame: Equatable {
    var phase: COSBuildUpMachine.Phase
    var drawT: Double
    var phaseT: Double = 0
}

/// What the stage drew on one frame, for the view checks: per component its look and the tint over the content.
struct COSBuildUpProbeFrame {
    var kind: String
    var phase: COSBuildUpMachine.Phase
    var drawT: Double
    var size: CGSize
    /// The wire's frame in the window (the view's own frame), and each component's rect inside it.
    var frame: CGRect
    var rects: [CGRect]
    var looks: [COSBuildUpLook]
    var curtains: [Double]
    var lines: [Int]
    var pulsing: Bool
}

/// Test hooks, nil in the app. `stage`: every frame COSBuildUpStage draws, from inside its body. `wrapper`: whether the
/// wrapper hides its content, each time it draws. `breadcrumb`: every breadcrumb. `freeze`: every COSBuildUp draws this
/// frozen moment instead of its own clock (renders of the real call sites).
@MainActor enum COSBuildUpProbe {
    static var stage: ((COSBuildUpProbeFrame) -> Void)?
    static var wrapper: ((String, Bool) -> Void)?
    static var breadcrumb: ((String) -> Void)?
    static var freeze: COSBuildUpFrame?
}

/// What COS remembers per view (COSBuildUpMemory). The empty list is kept across launches in UserDefaults, label keys
/// only (a label is UI copy, never data), at most COSBuildUpMemory.emptyLimit of them.
@MainActor enum COSBuildUpSession {
    static let emptyKey = "COSBuildUpEmptyViews"
    static var memory = COSBuildUpMemory(empty: UserDefaults.standard.stringArray(forKey: emptyKey) ?? [])
    static func record(_ key: String, _ outcome: COSBuildUpMachine.Outcome, persists: Bool) {
        if memory.record(key, outcome, persists: persists) { UserDefaults.standard.set(memory.empty, forKey: emptyKey) }
    }
}

private let buildUpLog = Logger(subsystem: "com.gotcos.control", category: "build-up")

/// The approved "build-up, in place" loading reveal, as one reusable wrapper (the timing, the memory and the state machine
/// are COSBuildUpPlan, COSBuildUpMemory and COSBuildUpMachine in Models.swift). A call site wraps its existing view,
/// untouched, and declares only the placeholder shape and its loading state:
///
///     COSBuildUp(.rows(6), loading: model.tasksLoading && model.tasks.isEmpty, landed: !model.tasks.isEmpty,
///                label: "Loading tasks") { …today's if / else chain, spinner, error and empty views included… }
///
/// The wrapped view is ALWAYS laid out and live, so its loads, tasks, error and empty paths run exactly as before, and the
/// wrapper never changes its size. While the first load builds it is only hidden (opacity, hit testing and accessibility),
/// and the wire is an overlay clipped to the view that never takes a click. Landed data shows at once, readable and
/// clickable, under a light tint. An error or empty answer shows at once, with the wire fading over it.
struct COSBuildUp<Content: View>: View {
    let shape: COSBuildUpShape
    let tune: COSBuildUpTune
    let loading: Bool
    let landed: Bool
    let interrupted: Bool
    let failed: Bool
    let enabled: Bool
    let timeout: Double
    let label: String
    let key: AnyHashable?
    let background: Color
    let frozen: COSBuildUpFrame?
    @ViewBuilder let content: () -> Content

    /// `tune`: this site's own row geometry. `interrupted`: a search or tab switch has taken the view elsewhere (the first
    /// load settles quietly and is not remembered as empty). `failed`: the site's error flag (an error is never remembered
    /// as empty). `enabled`: false where this view never builds (Work's meeting picker). `timeout`: the site's own helper
    /// timeout plus COSBuildUpPlan.helperMargin (default COSBuildUpPlan.defaultTimeout). `label`: what VoiceOver hears
    /// while it builds ("Loading meetings"), and with `key` what COS remembers; a new label is a new view (a tab switch).
    /// `key`: the thing the view shows (a meeting's id); when it changes the view counts as opened again. `background`:
    /// the surface behind the content (the tint and the wire's colour). `frozen`: static renders only.
    init(_ shape: COSBuildUpShape, tune: COSBuildUpTune = .none, loading: Bool, landed: Bool, interrupted: Bool = false, failed: Bool = false,
         enabled: Bool = true, timeout: Double = COSBuildUpPlan.defaultTimeout, label: String, key: AnyHashable? = nil,
         background: Color = COSPalette.panel, frozen: COSBuildUpFrame? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.shape = shape
        self.tune = tune
        self.loading = loading
        self.landed = landed
        self.interrupted = interrupted
        self.failed = failed
        self.enabled = enabled
        self.timeout = timeout
        self.label = label
        self.key = key
        self.background = background
        self.frozen = frozen
        self.content = content
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var machine: COSBuildUpMachine?

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    private var layout: COSBuildUpLayout { COSBuildUpPlan.layout(shape, tune) }
    private var memoryKey: String { label + "|" + (key.map { String(describing: $0) } ?? "") }

    private func opened(at t: Double) -> COSBuildUpMachine {
        COSBuildUpMachine(at: t, loading: loading && !interrupted, landed: landed, reduceMotion: reduceMotion,
                          count: COSBuildUpPlan.items(shape, tune).count, quiet: !enabled || !COSBuildUpSession.memory.builds(memoryKey),
                          timeout: timeout)
    }

    var body: some View {
        let now = Self.now()
        let frozen = self.frozen ?? COSBuildUpProbe.freeze
        let current = machine ?? opened(at: now)
        let hide = frozen.map { COSBuildUpPlan.hides($0.phase, wordsShown: $0.drawT >= COSBuildUpPlan.wordsSeconds) } ?? current.hidesContent
        let wire = frozen.map { $0.phase == .building || $0.phase == .landing || $0.phase == .handoff } ?? current.drawsWire
        let _ = COSBuildUpProbe.wrapper?(shape.kind, hide)
        sized(content()
            .opacity(hide ? 0 : 1)
            .allowsHitTesting(!hide)
            .accessibilityHidden(hide), hide: hide)
            .overlay(alignment: .topLeading) {
                if wire {
                    COSBuildUpLiveStage(shape: shape, tune: tune, machine: current, frozen: frozen, background: background, onFit: fit)
                        .clipped()
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
            .onAppear {
                if frozen == nil, machine == nil { machine = opened(at: Self.now()) }
                clearEmptyOnData()
            }
            .onDisappear { abandon() }
            .onChange(of: label) { _, _ in relabel() }
            .onChange(of: failed) { _, _ in step() }
            .onChange(of: loading) { _, _ in step() }
            .onChange(of: landed) { _, _ in step() }
            .onChange(of: interrupted) { _, _ in step() }
            .onChange(of: reduceMotion) { _, _ in step() }
            .onChange(of: key) { _, _ in reopen() }
            .task(id: frozen == nil ? machine?.deadline : nil) {
                // Sleep until the machine's next moment (a wake can come early), then feed it the clock.
                guard frozen == nil, let deadline = machine?.deadline else { return }
                while !Task.isCancelled, Self.now() < deadline {
                    try? await Task.sleep(nanoseconds: UInt64(max(0.001, deadline - Self.now()) * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                step()
            }
    }

    /// A pane-filling view takes the whole container while the wire stands in for it, so the wire fits the room the
    /// content will have. An inline view (a Today card, an answer) is never resized: the wire draws inside today's view.
    @ViewBuilder
    private func sized<V: View>(_ view: V, hide: Bool) -> some View {
        if layout.fills {
            view.frame(maxWidth: hide ? .infinity : nil, maxHeight: hide ? .infinity : nil, alignment: .topLeading)
        } else {
            view
        }
    }

    private func fit(_ count: Int) {
        guard frozen == nil, var next = machine, next.phase == .building || next.phase == .grace, next.count != count else { return }
        next.fit(count)
        if next != machine { machine = next }
    }

    private func step() {
        guard frozen == nil else { return }
        clearEmptyOnData()
        var next = machine ?? opened(at: Self.now())
        let before = next.outcome
        next.update(at: Self.now(), loading: loading && !interrupted, landed: landed, reduceMotion: reduceMotion, interrupted: interrupted,
                    failed: failed)
        // Settled and unchanged (every refresh and poll after the first load): nothing is written, so nothing redraws.
        guard next != machine else { return }
        if before == nil, let outcome = next.outcome { remember(outcome, next) }
        machine = next
    }

    /// A view remembered as empty has data again (it opened quiet, so its machine never lands): clear it, so the next
    /// launch builds again.
    private func clearEmptyOnData() {
        guard frozen == nil, landed, key == nil, COSBuildUpSession.memory.empty.contains(memoryKey) else { return }
        COSBuildUpSession.record(memoryKey, .landed, persists: true)
    }

    /// A new label is a new view in the same place (To review and Recent learning): a load still waiting for the old one
    /// settles quietly as interrupted, never remembered as empty, and the new one opens.
    private func relabel() {
        guard frozen == nil else { return }
        if var old = machine, old.phase == .grace || old.phase == .building {
            old.update(at: Self.now(), loading: true, landed: false, interrupted: true)
            if let outcome = old.outcome { remember(outcome, old) }
        }
        let next = opened(at: Self.now())
        if next != machine { machine = next }
    }

    /// The view went away, or shows something else, while it was still waiting: log it, never as empty.
    private func abandon() {
        guard frozen == nil, var next = machine, next.abandon(at: Self.now()) else { return }
        remember(.abandoned, next)
        machine = next
    }

    private func reopen() {
        guard frozen == nil else { return }
        abandon()
        let next = opened(at: Self.now())
        if next != machine { machine = next }
    }

    /// One breadcrumb per load the build was ready for, through the app's log: shape, outcome, rows and time, no text.
    private func remember(_ outcome: COSBuildUpMachine.Outcome, _ machine: COSBuildUpMachine) {
        // An interrupted load is not recorded under any key (the label may already be the next view's).
        if outcome != .interrupted { COSBuildUpSession.record(memoryKey, outcome, persists: key == nil) }
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
    let tune: COSBuildUpTune
    let machine: COSBuildUpMachine
    let frozen: COSBuildUpFrame?
    let background: Color
    let onFit: (Int) -> Void
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        GeometryReader { geometry in
            let active = activeState != .inactive
            Group {
                if let frozen {
                    COSBuildUpStage(shape: shape, tune: tune, phase: frozen.phase, drawT: frozen.drawT,
                                    landT: frozen.phase == .landing ? frozen.phaseT : nil, handoffT: frozen.phase == .handoff ? frozen.phaseT : nil,
                                    pulsing: frozen.phase == .building, limit: nil, size: geometry.size, frame: geometry.frame(in: .global),
                                    background: background)
                } else {
                    TimelineView(COSBuildUpSchedule(paused: !machine.needsFrames(windowActive: active))) { _ in
                        let t = ProcessInfo.processInfo.systemUptime
                        COSBuildUpStage(shape: shape, tune: tune, phase: machine.phase, drawT: machine.drawT(at: t) ?? 0, landT: machine.landT(at: t),
                                        handoffT: machine.handoffT(at: t), pulsing: machine.pulses(windowActive: active), limit: machine.count,
                                        size: geometry.size, frame: geometry.frame(in: .global), background: background)
                    }
                }
            }
            .onAppear { onFit(fitted(geometry.size.height)) }
            .onChange(of: geometry.size.height) { _, height in onFit(fitted(height)) }
        }
    }

    private func fitted(_ height: CGFloat) -> Int {
        COSBuildUpPlan.items(shape, tune, fitting: Double(height)).count
    }
}

/// The wire itself, drawn from COSBuildUpPlan.look at one moment: every layer at the coordinates the plan gives, fitted
/// to the view's own size every frame, so it follows a resize and never draws past the view. No SwiftUI animation and no
/// repeating animation: the clock is the frame.
private struct COSBuildUpStage: View {
    let shape: COSBuildUpShape
    let tune: COSBuildUpTune
    let phase: COSBuildUpMachine.Phase
    let drawT: Double
    let landT: Double?
    let handoffT: Double?
    let pulsing: Bool
    let limit: Int?
    let size: CGSize
    let frame: CGRect
    let background: Color
    @Environment(\.self) private var environment

    private var layout: COSBuildUpLayout { COSBuildUpPlan.layout(shape, tune) }

    var body: some View {
        let height = Double(size.height)
        let items = COSBuildUpPlan.items(shape, tune, limit: limit, fitting: height,
                                         measured: shape == .answer && phase == .landing ? height : nil)
        let looks = items.indices.map { COSBuildUpPlan.look($0, drawT: drawT, landT: landT) }
        let curtains = looks.map { COSBuildUpPlan.curtain($0, landing: phase == .landing) }
        let wire = COSPalette.wire(on: background, in: environment)
        let bone = COSPalette.wireBone(on: background, in: environment)
        // The pulse fades with the traces when the data lands, rather than vanishing in one frame.
        let pulse = pulsing || (phase == .landing && COSBuildUpPlan.flow(drawT: drawT) != nil)
        let _ = COSBuildUpProbe.stage?(COSBuildUpProbeFrame(kind: shape.kind, phase: phase, drawT: drawT, size: size, frame: frame,
                                                            rects: items.indices.map { rect($0, items[$0], items: items) }, looks: looks,
                                                            curtains: curtains, lines: items.map(\.lines.count), pulsing: pulse))
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                band(index, item, looks[index], curtain: curtains[index], items: items, wire: wire, bone: bone)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                wireFrame(index, item, looks[index], items: items, wire: wire)
            }
            ZStack(alignment: .topLeading) {
                traces(items, wire: wire)
                if pulse { pulseView(items, wire: wire) }
            }
            .opacity(1 - (landT.map { COSBuildUpPlan.progress(COSBuildUpPlan.tracesFadeStep, at: $0) } ?? 0))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .opacity(handoffT.map { max(0, 1 - $0 / COSBuildUpPlan.handoffSeconds) } ?? 1)
    }

    private func rect(_ index: Int, _ item: COSBuildUpItem, items: [COSBuildUpItem]) -> CGRect {
        CGRect(x: layout.leading, y: COSBuildUpPlan.top(index, in: items, layout: layout),
               width: max(0, Double(size.width) - layout.leading - layout.trailing), height: item.height)
    }

    /// One band over the content, from this component's top (the first also covers the inset above it) to the next one's
    /// (the last to the bottom), cut back to the right of its ink edge: a light tint of the surface and the fill, never
    /// more than COSBuildUpPlan.curtainAlpha, and the wire text. Clicks pass through it to the content.
    @ViewBuilder
    private func band(_ index: Int, _ item: COSBuildUpItem, _ look: COSBuildUpLook, curtain: Double, items: [COSBuildUpItem],
                      wire: Color, bone: Color) -> some View {
        let box = rect(index, item, items: items)
        let top = index == 0 ? 0 : box.minY
        let bottom = index == items.count - 1 ? max(Double(size.height), box.maxY) : COSBuildUpPlan.top(index + 1, in: items, layout: layout)
        ZStack(alignment: .topLeading) {
            // The surface and the card fill as ONE layer at the tint's alpha, so the cover drawn never passes it.
            ZStack(alignment: .topLeading) {
                Rectangle().fill(background)
                if item.style == .card {
                    RoundedRectangle(cornerRadius: item.radius, style: .continuous)
                        .fill(COSPalette.card)
                        .frame(width: box.width, height: box.height)
                        .mask(alignment: .leading) { Rectangle().frame(width: box.width * look.fill) }
                        .offset(x: box.minX, y: box.minY - top)
                }
            }
            .compositingGroup()
            .opacity(curtain)
            capsules(item, look, box: box, wire: wire, bone: bone)
                .offset(x: box.minX, y: box.minY - top)
        }
        .frame(width: size.width, height: max(0, bottom - top), alignment: .topLeading)
        .clipped()
        .mask(alignment: .trailing) { Rectangle().frame(width: max(0, size.width * (1 - look.ink))) }
        .offset(y: top)
    }

    /// Step 4 (the text as outlined capsules, left to right), then gone: when the words show, or ahead of the ink.
    private func capsules(_ item: COSBuildUpItem, _ look: COSBuildUpLook, box: CGRect, wire: Color, bone: Color) -> some View {
        let inner = box.insetBy(dx: item.padH, dy: item.padV)
        let lead = item.lead.map { CGFloat($0) + 10 } ?? 0
        let trailingRoom = item.trailing.isEmpty ? 0 : CGFloat(item.trailing.reduce(0, +)) + CGFloat(item.trailing.count) * 6 + 12
        let room = max(0, inner.width - lead - trailingRoom)
        let block = item.lines.reduce(0) { $0 + $1.height } + Double(max(0, item.lines.count - 1)) * item.lineGap
        let y0 = max(0, (Double(inner.height) - block) / 2)
        return ZStack(alignment: .topLeading) {
            if let leadWidth = item.lead {
                wireCapsule(width: CGFloat(leadWidth), height: CGFloat(min(Double(inner.height), (item.lines.first?.height ?? 10) + (item.lines.count > 1 ? 6 : 0))),
                            look: look, wire: wire, bone: bone)
                    .offset(x: 0, y: CGFloat(y0))
            }
            VStack(alignment: .leading, spacing: CGFloat(item.lineGap)) {
                ForEach(Array(item.lines.enumerated()), id: \.offset) { _, line in
                    wireCapsule(width: room * CGFloat(line.width), height: CGFloat(line.height), look: look, wire: wire, bone: bone)
                }
            }
            .offset(x: lead, y: CGFloat(y0))
            if !item.trailing.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(item.trailing.enumerated()), id: \.offset) { _, pill in
                        wireCapsule(width: CGFloat(pill), height: min(16, inner.height), look: look, wire: wire, bone: bone)
                    }
                }
                .frame(width: inner.width, height: inner.height, alignment: .trailing)
                .padding(.trailing, 12)
            }
        }
        .frame(width: inner.width, height: max(0, inner.height), alignment: .topLeading)
        .offset(x: CGFloat(item.padH), y: CGFloat(item.padV))
        .opacity((1 - look.wordsFade) * (1 - look.wireFade))
    }

    private func wireCapsule(width: CGFloat, height: CGFloat, look: COSBuildUpLook, wire: Color, bone: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: max(0, height / 2), style: .continuous)
        return ZStack {
            shape.fill(bone).opacity(look.solid)
            shape.stroke(wire, lineWidth: 1).opacity(1 - look.solid)
        }
        .frame(width: max(0, width), height: max(0, height))
        .mask(alignment: .leading) { Rectangle().frame(width: max(0, width) * look.wireText) }
    }

    /// Steps 1 and 2, then 8: the outline traces on, the four corner nodes pop, and both hand over to the real border.
    private func wireFrame(_ index: Int, _ item: COSBuildUpItem, _ look: COSBuildUpLook, items: [COSBuildUpItem], wire: Color) -> some View {
        let box = rect(index, item, items: items)
        let node = 7 * CGFloat(look.nodes)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: min(item.radius, box.height / 2), style: .continuous)
                .trim(from: 0, to: look.outline)
                .stroke(wire, lineWidth: 1)
                .opacity(1 - look.outlineFade)
                .frame(width: box.width, height: box.height)
            ForEach(0..<4, id: \.self) { corner in
                Circle().fill(background)
                    .overlay(Circle().stroke(wire, lineWidth: 1.2))
                    .frame(width: node, height: node)
                    .frame(width: 7, height: 7)
                    .opacity(1 - look.nodeFade)
                    // Kept inside the view, so the clip never cuts a node in half (a row as tall as an inline view).
                    .offset(x: nodeX(box.minX + (corner % 2 == 0 ? 0 : box.width)) - box.minX - 3.5,
                            y: nodeY(box.minY + (corner < 2 ? 0 : box.height)) - box.minY - 3.5)
            }
        }
        .offset(x: box.minX, y: box.minY)
    }

    private func nodeX(_ x: CGFloat) -> CGFloat { min(max(x, 4), max(4, size.width - 4)) }
    private func nodeY(_ y: CGFloat) -> CGFloat { min(max(y, 4), max(4, size.height - 4)) }

    private func spine(_ items: [COSBuildUpItem]) -> (x: CGFloat, top: CGFloat, bottom: CGFloat)? {
        guard let x = layout.spineX, !items.isEmpty else { return nil }
        return (CGFloat(x), CGFloat(max(0, COSBuildUpPlan.junctionY(0, in: items, layout: layout) - 10)),
                CGFloat(COSBuildUpPlan.junctionY(items.count - 1, in: items, layout: layout)))
    }

    /// Step 3: the spine down the left, a branch and a junction node to each component.
    @ViewBuilder
    private func traces(_ items: [COSBuildUpItem], wire: Color) -> some View {
        if let spine = spine(items) {
            ZStack(alignment: .topLeading) {
                Path { path in path.move(to: CGPoint(x: spine.x, y: spine.top)); path.addLine(to: CGPoint(x: spine.x, y: spine.bottom)) }
                    .trim(from: 0, to: COSBuildUpPlan.progress(COSBuildUpPlan.spineStep, at: drawT))
                    .stroke(wire, lineWidth: 1)
                ForEach(items.indices, id: \.self) { index in
                    let y = CGFloat(COSBuildUpPlan.junctionY(index, in: items, layout: layout))
                    let pop = 6 * CGFloat(COSBuildUpPlan.progress(COSBuildUpPlan.junctionStep(index), at: drawT, curve: COSBuildUpPlan.pop))
                    Path { path in path.move(to: CGPoint(x: spine.x, y: y)); path.addLine(to: CGPoint(x: CGFloat(layout.leading) - 4, y: y)) }
                        .trim(from: 0, to: COSBuildUpPlan.progress(COSBuildUpPlan.branchStep(index), at: drawT))
                        .stroke(wire, lineWidth: 1)
                    Circle().fill(background)
                        .overlay(Circle().stroke(wire, lineWidth: 1.2))
                        .frame(width: pop, height: pop)
                        .frame(width: 6, height: 6)
                        .offset(x: spine.x - 3, y: y - 3)
                }
            }
        }
    }

    /// While it loads, for its cycles: a short bright segment flows down the spine and each first corner node pings.
    @ViewBuilder
    private func pulseView(_ items: [COSBuildUpItem], wire: Color) -> some View {
        ZStack(alignment: .topLeading) {
            if let spine = spine(items), let head = COSBuildUpPlan.flow(drawT: drawT) {
                Path { path in path.move(to: CGPoint(x: spine.x, y: spine.top)); path.addLine(to: CGPoint(x: spine.x, y: spine.bottom)) }
                    .trim(from: head, to: min(1, head + COSBuildUpPlan.flowLength))
                    .stroke(wire, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            ForEach(items.indices, id: \.self) { index in
                if let spread = COSBuildUpPlan.ping(index, drawT: drawT) {
                    Circle().stroke(wire.opacity(0.45), lineWidth: 2)
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
