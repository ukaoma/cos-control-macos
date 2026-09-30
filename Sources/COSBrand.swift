import AppKit
import CoreText
import SwiftUI

/// Official COS lockup and gotcos.com typefaces (Fraunces, DM Sans, JetBrains Mono).
enum COSBrand {
    static func svg(_ name: String) -> NSImage {
        let empty = NSImage(size: NSSize(width: 1, height: 1))
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return empty }
        image.isTemplate = true
        return image
    }
}

enum COSType {
    private static let bundled: Bool = {
        registerBundledFonts()
        return true
    }()

    static func display(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        _ = bundled
        var font = Font.custom("Fraunces", size: size).weight(weight)
        if italic { font = font.italic() }
        return font
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        _ = bundled
        return Font.custom("DM Sans", size: size).weight(weight)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        _ = bundled
        return Font.custom("JetBrains Mono", size: size).weight(weight)
    }

    private static func registerBundledFonts() {
        let names = ["Fraunces", "Fraunces-Italic", "DMSans", "JetBrainsMono"]
        let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true)
        for name in names {
            let url = folder?.appendingPathComponent("\(name).ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            guard let url else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

struct COSLockupView: View {
    var height: CGFloat = 17

    var body: some View {
        Image(nsImage: COSBrand.svg("COSLockup"))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel("COS")
    }
}

struct COSGotcosCaption: View {
    var size: CGFloat = 12

    var body: some View {
        Text("gotcos")
            .font(COSType.display(size, italic: true))
            .foregroundStyle(COSPalette.gold)
            .accessibilityLabel("gotcos")
    }
}

// ── Shared surface styles (0.5.193) ──────────────────────────────
//
// The Memories tab hosts the reviewed design: Fraunces for the hero, DM Sans
// for prose, JetBrains Mono for instrument chrome, warm cards with a hairline,
// gold on hover. These styles give the native panes the same vocabulary so a
// row, a field, or a button reads the same on every tab (Miles, 2026-09-06:
// "those other tabs are on a generic boilerplate theme").

/// A live number with what it counts, the same pair the home tiles show.
struct COSStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(COSType.display(18, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
            Text(label)
                .font(COSType.mono(9.5))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A list row as a warm card: card fill, hairline, gold on hover.
private struct COSRowCard: ViewModifier {
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(hovered ? COSPalette.gold.opacity(0.06) : Color.clear)
            .background(COSPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(hovered ? COSPalette.gold.opacity(0.85) : COSPalette.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
    }
}

/// A search or capture field: the same card and hairline as a row, so a field
/// does not introduce a second surface treatment.
private struct COSField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(COSType.body(12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(COSPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(COSPalette.line, lineWidth: 1))
    }
}

/// 0.5.253 (Miles, 2026-09-30 16:51, with screenshots: "Center the refresh icon on Check for updates." and "There are
/// several places where that same top vertical alignment is happening."): a label's icon sits in the middle of its
/// whole text block. The system's label style lines the icon up with the FIRST line, so a label that wraps ("Check for
/// updates" in the updates card, "Create Folders" in the menu-bar panel's grid) showed its icon at the top, 8.5 pt above
/// the middle. The gap is the system's own (8 pt, measured at every size the app uses), so no button changes width or
/// wraps differently, and a wrapped title stays leading-aligned. Every COS button style, the menu face and the dropdown
/// set it, and `cosControlTheme()` sets it on each window root, so a Label anywhere else takes it too.
/// Pinned by Tests/ControlsContract.swift (labels) and the panel render in Tests/PanelLabelsRender.swift.
struct COSLabelStyle: LabelStyle {
    /// The system label style's gap between icon and title (8 pt at 10, 11.5 and 13 pt, caption and headline).
    static let spacing: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: Self.spacing) {
            configuration.icon
            configuration.title.multilineTextAlignment(.leading)
        }
    }
}

/// A quiet button: DM Sans, card fill, hairline; gold when hovered or pressed.
/// `.destructive` (0.5.221) is for the CONFIRMING step of a destructive action:
/// danger ink at rest and a danger hairline when hovered. Arming one stays a
/// `COSTextButtonStyle(tone: .destructive)`, so a list of rows is not a wall of red.
///
/// THREE WEIGHTS OF ACTION ON A PANE (0.5.232, Miles: "create some distinction on the
/// high use UI elements"): the one thing the pane is for is a `COSPrimaryButtonStyle`
/// (gold fill, first in the row); everything else is this style at `.standard`; and
/// a capability that just landed is `.featured`, a gold hairline with accent ink at
/// rest and its `COSNewPill` inside the label, until it is familiar.
struct COSQuietButtonStyle: ButtonStyle {
    enum Tone { case standard, destructive, featured }
    var tone: Tone = .standard

    func makeBody(configuration: Configuration) -> some View {
        QuietBody(configuration: configuration, tone: tone)
    }

    private struct QuietBody: View {
        let configuration: Configuration
        let tone: Tone
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let hot = (hovered || configuration.isPressed) && isEnabled
            // 0.5.252: hovered ink and lines use the accent token, not raw gold. Gold on a white card is about 2.3:1 in
            // light mode; the accent is the same gold in dark and a deeper one in light (over 3:1).
            let signal = tone == .destructive ? COSPalette.danger : COSPalette.accent
            let ink: Color = switch tone {
            case .destructive: isEnabled ? COSPalette.danger : Color.secondary
            case .featured: isEnabled ? COSPalette.accent : Color.secondary
            case .standard: hot ? COSPalette.accent : (isEnabled ? Color.primary : Color.secondary)
            }
            let restLine: Color = tone == .featured && isEnabled ? COSPalette.accent.opacity(0.7) : COSPalette.line
            configuration.label
                .labelStyle(COSLabelStyle())
                .font(COSType.body(11.5, weight: tone == .featured ? .semibold : .medium))
                .foregroundStyle(ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(configuration.isPressed ? signal.opacity(0.12) : COSPalette.card)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(hot ? signal : restLine, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.55)
                .onHover { hovered = $0 }
        }
    }
}

/// An inline text action beside a chip (Cancel, Keep), or the arming step of a
/// destructive one (Discard): DM Sans, warm muted ink, no chrome; accent when
/// hovered, danger when the tone is destructive. Replaces system link buttons,
/// whose blue reads as a web hyperlink in a warm pane (Miles, 2026-09-13).
struct COSTextButtonStyle: ButtonStyle {
    enum Tone { case standard, destructive }
    var tone: Tone = .standard

    func makeBody(configuration: Configuration) -> some View {
        TextBody(configuration: configuration, tone: tone)
    }

    private struct TextBody: View {
        let configuration: Configuration
        let tone: Tone
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let hot = (hovered || configuration.isPressed) && isEnabled
            let signal = tone == .destructive ? COSPalette.danger : COSPalette.accent
            configuration.label
                .labelStyle(COSLabelStyle())
                .font(COSType.body(11.5, weight: .medium))
                .foregroundStyle(hot ? signal : COSPalette.muted)
                .padding(.horizontal, 2)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovered = $0 }
        }
    }
}

/// A round icon control (play, previous, next): card fill and hairline with a
/// muted glyph; `prominent` fills it gold with ink, for the control that is live
/// right now (a sample playing).
struct COSIconButtonStyle: ButtonStyle {
    var size: CGFloat = 22
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size, prominent: prominent)
    }

    private struct IconBody: View {
        let configuration: Configuration
        let size: CGFloat
        let prominent: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let hot = (hovered || configuration.isPressed) && isEnabled
            configuration.label
                .labelStyle(COSLabelStyle())
                .font(.system(size: max(7, size * 0.40), weight: .semibold))
                .foregroundStyle(prominent ? COSPalette.ink : (hot ? COSPalette.accent : COSPalette.muted))
                .frame(width: size, height: size)
                .background(Circle().fill(prominent
                    ? COSPalette.gold.opacity(configuration.isPressed ? 0.8 : 1)
                    : (configuration.isPressed ? COSPalette.gold.opacity(0.12) : COSPalette.card)))
                .overlay(Circle().stroke(prominent ? Color.clear : (hot ? COSPalette.accent : COSPalette.line), lineWidth: 1))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = $0 }
        }
    }
}

/// The NEW marker that rides INSIDE a featured button's label (0.5.232), so the
/// button and its newness are one object rather than a pill floating beside it.
struct COSNewPill: View {
    var body: some View {
        Text("NEW")
            .font(COSType.mono(8.5, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(COSPalette.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(COSPalette.gold))
    }
}

/// The one loud button on a pane: gold fill, ink text.
struct COSPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(COSLabelStyle())
            .font(COSType.body(11.5, weight: .semibold))
            .foregroundStyle(COSPalette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(COSPalette.gold.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

extension View {
    func cosRowCard() -> some View { modifier(COSRowCard()) }
    func cosField() -> some View { modifier(COSField()) }
}

// ── GOTCOS controls (0.5.251) ────────────────────────────────────
//
// Miles, 2026-09-29, on 0.5.250's Agent workspace: the Provider and Model dropdowns
// (grey fill, blue stepper) and the Board/Focus segmented control were macOS defaults;
// "we should be using our GOTCOS theme across the board." Approved 2026-09-30 ("Build
// all as shown"; an open dropdown shows the themed card list). Every stock control the
// panes drew is replaced by one of these, and `Tests/run.sh` fails if a Sources file
// other than this one uses a stock picker, toggle, stepper, or system button style.

/// Where a `COSDropdown` opens its list. By default it is a borderless child panel anchored under the face: the
/// approved card, with no popover arrow or system chrome, which no scroll view can clip. True drops the list inline
/// under the face instead, inside the pane's own layout: the fallback for a surface where a child panel cannot show.
/// `Tests/dropdown-canary` proves the panel in a real MenuBarExtra(.window) and in a normal window.
private struct COSDropdownInlineKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var cosDropdownInline: Bool {
        get { self[COSDropdownInlineKey.self] }
        set { self[COSDropdownInlineKey.self] = newValue }
    }
}

/// When the themed controls take keyboard focus. `.activate` is what a macOS control does: focusable when Keyboard
/// navigation is on (Tab reaches every control), and never a window's first focus without it. Nothing in the app sets
/// this. The controls contract sets `.automatic`, which stands in for a Mac with Keyboard navigation on (a test
/// process cannot turn that setting on for itself), so its Tab, Space and arrow keys run the shipped handlers.
private struct COSFocusInteractionsKey: EnvironmentKey {
    static let defaultValue = FocusInteractions.activate
}

extension EnvironmentValues {
    var cosFocusInteractions: FocusInteractions {
        get { self[COSFocusInteractionsKey.self] }
        set { self[COSFocusInteractionsKey.self] = newValue }
    }
}

/// One row of a `COSDropdown`.
struct COSDropdownOption<Value: Hashable> {
    let value: Value
    let title: String
    /// Muted words after the title, such as "unavailable".
    var note: String? = nil
    /// Muted, but still choosable: an unavailable model can be picked, then explained.
    var muted: Bool = false
    /// False: the row cannot be chosen at all.
    var enabled: Bool = true
    /// The "Choose ..." row. While it is the selection the face reads in muted ink.
    var placeholder: Bool = false

    init(_ value: Value, _ title: String, note: String? = nil, muted: Bool = false,
         enabled: Bool = true, placeholder: Bool = false) {
        self.value = value
        self.title = title
        self.note = note
        self.muted = muted
        self.enabled = enabled
        self.placeholder = placeholder
    }
}

extension COSDropdownOption: Sendable where Value: Sendable {}

/// The dropdown's keyboard, as pure rules so a contract can execute them.
enum COSDropdownKey: Equatable {
    case up, down, confirm, space, escape
    case letter(Character)
}

enum COSDropdownEffect<Value: Hashable>: Equatable {
    /// Not ours: let the key through.
    case ignored
    case open(highlight: Int?)
    case highlight(Int?)
    case choose(Value)
    case close
}

enum COSDropdownRules {
    /// The row to highlight when the list opens: the selection, else the first row that can be chosen.
    static func openingHighlight<Value: Hashable>(_ options: [COSDropdownOption<Value>], selection: Value) -> Int? {
        if let index = options.firstIndex(where: { $0.value == selection && $0.enabled }) { return index }
        return options.firstIndex(where: \.enabled)
    }

    /// The next row that can be chosen, `step` rows away; it stops at the ends.
    static func move<Value: Hashable>(_ options: [COSDropdownOption<Value>], from current: Int?, by step: Int) -> Int? {
        guard !options.isEmpty else { return nil }
        var index = current ?? (step > 0 ? -1 : options.count)
        while true {
            index += step
            guard options.indices.contains(index) else { return current }
            if options[index].enabled { return index }
        }
    }

    /// The next row after the highlight whose title starts with `letter`, wrapping once around.
    static func jump<Value: Hashable>(_ options: [COSDropdownOption<Value>], from current: Int?, letter: Character) -> Int? {
        guard !options.isEmpty else { return nil }
        let wanted = String(letter).lowercased()
        let start = current ?? -1
        for offset in 1...options.count {
            let index = (start + offset + options.count) % options.count
            let row = options[index]
            if row.enabled, row.title.lowercased().hasPrefix(wanted) { return index }
        }
        return current
    }

    /// A click on the face of an open list first dismisses it (a click outside the list), then lands on the face. That
    /// click must leave it closed: the face opens again only once this long has passed since the click was released.
    static let reopenDelay: TimeInterval = 0.3
    static func reopens(after sinceDismissal: TimeInterval) -> Bool { sinceDismissal > reopenDelay }

    /// The open list is as wide as its face. It grows only when a row would not fit, so long names that differ at the
    /// tail stay readable, and never past `widest` (a row that still does not fit truncates in the middle).
    static let widestList: CGFloat = 440
    static func listWidth(face: CGFloat, ideal: CGFloat, widest: CGFloat = widestList) -> CGFloat {
        max(face, min(ideal.rounded(.up), max(face, widest)))
    }

    /// Where the list's card goes on screen (AppKit coordinates, origin bottom left): under the face, its leading
    /// edges aligned; above the face when there is no room below and there is room above; kept on its screen.
    static let listGap: CGFloat = 4
    static func listOrigin(face: CGRect, card: CGSize, visible: CGRect?) -> CGPoint {
        var origin = CGPoint(x: face.minX, y: face.minY - listGap - card.height)
        guard let visible else { return origin }
        if origin.y < visible.minY, face.maxY + listGap + card.height <= visible.maxY { origin.y = face.maxY + listGap }
        origin.x = max(visible.minX, min(origin.x, visible.maxX - card.width))
        return origin
    }

    /// The same keys from an AppKit key-down, which is how the open panel hears them (it never becomes key).
    static func key(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> COSDropdownKey? {
        switch keyCode {
        case 126: return .up
        case 125: return .down
        case 36, 76: return .confirm
        case 49: return .space
        case 53: return .escape
        default:
            guard modifiers.isDisjoint(with: [.command, .control, .option]), let characters, characters.count == 1,
                  let character = characters.first, character.isLetter || character.isNumber else { return nil }
            return .letter(character)
        }
    }

    /// The value a click on row `index` chooses; nil for a disabled dropdown or a row that cannot be chosen.
    static func chosen<Value: Hashable>(_ index: Int, in options: [COSDropdownOption<Value>], enabled: Bool) -> Value? {
        guard enabled, options.indices.contains(index), options[index].enabled else { return nil }
        return options[index].value
    }

    /// What one key does. A disabled dropdown takes no keys.
    static func handle<Value: Hashable>(_ key: COSDropdownKey, isOpen: Bool, highlight: Int?,
                                        options: [COSDropdownOption<Value>], selection: Value,
                                        enabled: Bool) -> COSDropdownEffect<Value> {
        guard enabled else { return isOpen ? .close : .ignored }
        guard isOpen else {
            switch key {
            case .confirm, .space, .up, .down: return .open(highlight: openingHighlight(options, selection: selection))
            case .escape, .letter: return .ignored
            }
        }
        switch key {
        case .up: return .highlight(move(options, from: highlight, by: -1))
        case .down: return .highlight(move(options, from: highlight, by: 1))
        case .letter(let letter): return .highlight(jump(options, from: highlight, letter: letter))
        case .escape: return .close
        case .confirm, .space:
            guard let highlight, options.indices.contains(highlight), options[highlight].enabled else { return .close }
            return .choose(options[highlight].value)
        }
    }

    static func key(_ press: KeyPress) -> COSDropdownKey? {
        switch press.key {
        case .upArrow: return .up
        case .downArrow: return .down
        case .return: return .confirm
        case .space: return .space
        case .escape: return .escape
        default:
            guard press.modifiers.isDisjoint(with: [.command, .control, .option]),
                  press.characters.count == 1, let character = press.characters.first,
                  character.isLetter || character.isNumber else { return nil }
            return .letter(character)
        }
    }
}

/// The open list of a `COSDropdown`, as a borderless child panel under the face. The panel never takes the keyboard
/// from its parent window (a menu-bar panel closes when it stops being key), so while it shows, one local event
/// monitor feeds it the keys and closes it on a click or a scroll anywhere else.
@MainActor final class COSDropdownPresenter: ObservableObject {
    @Published var isOpen = false
    @Published var highlight: Int?
    /// Bumped when a key moved the highlight, so the list scrolls that row into view. The pointer never scrolls it.
    @Published private(set) var revealTick = 0
    /// Where the pointer is over the panel, in the list's own coordinates; nil outside it.
    @Published fileprivate(set) var pointer: CGPoint?
    /// True when the list had no window to open a panel in, and drops inline instead.
    @Published private(set) var inlineFallback = false
    /// The face, in the parent window.
    fileprivate(set) weak var anchor: NSView?
    private(set) var panel: NSPanel?
    /// When the click that closed the list from outside was released. That same click may land on the face. Only a
    /// click stamps it: a key, a scroll or another app taking the focus leave the face free to open at once.
    private(set) var dismissedAt = Date.distantPast
    /// What a key does while the list is open; true when the key was ours.
    var onKey: ((COSDropdownKey) -> Bool)?

    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var releasePending = false
    private var card = CGRect.zero

    /// Room around the card inside the panel for its shadow (a blur of 8 pt reaches about 16 pt, offset 4 pt), so no
    /// edge of the panel cuts it. The top has room for the offset either way: AppKit's own drawing of the panel
    /// (cacheDisplay) puts the offset upward, and a 12 pt top cut the shadow there with a hard edge. While the list is
    /// open the panel overlaps the face's lower edge; a click there closes the list, as a click on the face does.
    static let shadowRoom = NSEdgeInsets(top: 22, left: 20, bottom: 26, right: 20)

    func reveal() { revealTick &+= 1 }

    /// Opens the panel under the face. False (and the caller drops the list inline) when the face is in no window.
    func present<List: View>(faceWidth: CGFloat, @ViewBuilder list: () -> List, measuring: () -> some View) -> Bool {
        closePanel()
        guard let anchor, let parent = anchor.window else { inlineFallback = true; return false }
        inlineFallback = false
        let appearance = anchor.effectiveAppearance
        let measure = NSHostingView(rootView: measuring().fixedSize())
        measure.appearance = appearance
        let width = COSDropdownRules.listWidth(face: faceWidth, ideal: measure.fittingSize.width)
        let room = Self.shadowRoom
        let host = COSDropdownHost(rootView: AnyView(list().frame(width: width)
            .padding(EdgeInsets(top: room.top, leading: room.left, bottom: room.bottom, trailing: room.right))))
        host.appearance = appearance
        host.pointer = { [weak self] point in self?.pointer = point }
        let size = host.fittingSize
        let cardSize = CGSize(width: width, height: size.height - room.top - room.bottom)
        let face = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let origin = COSDropdownRules.listOrigin(face: face, card: cardSize, visible: parent.screen?.visibleFrame)
        let frame = NSRect(x: origin.x - room.left, y: origin.y - room.bottom, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = parent.level
        panel.appearance = appearance
        panel.contentView = host
        panel.setAccessibilityRole(.popover)
        parent.addChildWindow(panel, ordered: .above)
        self.panel = panel
        card = NSRect(x: room.left, y: room.bottom, width: cardSize.width, height: cardSize.height)
        watch(parent)
        return true
    }

    /// Closes the list from code: a choice, Escape, a disabled dropdown, a view that went away.
    func close() {
        isOpen = false
        releasePending = false
        closePanel()
    }

    private func closePanel() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        pointer = nil
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil
    }

    /// Closed by something outside the list. A mouse-down keeps the monitor until its mouse-up, which stamps
    /// `dismissedAt`: the tap that click delivers to the face then finds the list just closed and leaves it closed.
    private func dismiss(awaitingRelease: Bool = false) {
        guard isOpen else { return }
        let kept = monitor
        monitor = nil
        isOpen = false
        closePanel()
        if awaitingRelease {
            dismissedAt = Date()
            monitor = kept
            releasePending = true
        } else if let kept {
            NSEvent.removeMonitor(kept)
        }
    }

    private func watch(_ parent: NSWindow) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                                               .leftMouseUp, .scrollWheel]) { [weak self] event in
            let swallowed = MainActor.assumeIsolated { self?.swallows(event) ?? false }
            return swallowed ? nil : event
        }
        let center = NotificationCenter.default
        let closing: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
        observers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: parent, queue: .main, using: closing),
            center.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main, using: closing),
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: closing),
        ]
    }

    /// One event while the list is open (or while the click that closed it is still down). True swallows it.
    private func swallows(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseUp:
            guard releasePending else { return false }
            releasePending = false
            dismissedAt = Date()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            return false
        case .keyDown:
            guard isOpen else { return false }
            guard let key = COSDropdownRules.key(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                                 modifiers: event.modifierFlags) else {
                dismiss()     // Tab, a command key: close, and let the key do its own work.
                return false
            }
            return onKey?(key) ?? false
        case .scrollWheel:
            guard isOpen, event.window !== panel else { return false }
            dismiss()         // The face is about to scroll away from under the list.
            return false
        default:
            guard isOpen else { return false }
            if let panel, event.window === panel, card.contains(event.locationInWindow) { return false }
            dismiss(awaitingRelease: event.type == .leftMouseDown)
            return false
        }
    }

    /// VoiceOver does not follow a highlight in a panel that is not key, so the row a key lands on is spoken.
    func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// The panel's content view. A panel that is never key gets no hover from SwiftUI on every macOS, so this tracks the
/// pointer itself (active always) and takes the first click, as a menu does.
private final class COSDropdownHost: NSHostingView<AnyView> {
    var pointer: ((CGPoint?) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); report(event) }
    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); report(event) }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); pointer?(nil) }

    /// SwiftUI's global space in this view: origin at the top left.
    private func report(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointer?(CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
    }
}

/// An invisible view behind the face: the panel is placed from its frame on screen.
private struct COSDropdownAnchor: NSViewRepresentable {
    let presenter: COSDropdownPresenter

    private final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = Anchor()
        presenter.anchor = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { presenter.anchor = view }
}

/// The list inside the panel: it follows the presenter's highlight, pointer and reveal.
private struct COSDropdownPanelList<Value: Hashable>: View {
    @ObservedObject var presenter: COSDropdownPresenter
    let options: [COSDropdownOption<Value>]
    let selection: Value
    let choose: (Int) -> Void

    var body: some View {
        COSDropdownList(options: options, selection: selection, highlight: $presenter.highlight, framed: true,
                        reveal: presenter.revealTick, pointer: presenter.pointer, choose: choose)
    }
}

/// A dropdown in the gotcos theme: an optional leading label, then a face drawn like a
/// field (card, hairline, DM Sans value, a gold chevron). Open, it shows a themed card
/// list: the chosen row carries a gold rule, the highlighted row a gold wash, and a muted
/// row its note. Space or Return opens it; Up and Down move; Return chooses; Escape closes;
/// a letter jumps to the next row that starts with it. A click on the face, or anywhere
/// outside the list, closes it. VoiceOver reads the face as a button with its label and
/// value, and each row as a button, the chosen one selected.
struct COSDropdown<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [COSDropdownOption<Value>]
    var showsLabel: Bool = true
    var labelWidth: CGFloat? = nil
    /// A leading glyph on the face (the sort menus use arrow.up.arrow.down).
    var icon: String? = nil

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.cosDropdownInline) private var inline
    @Environment(\.cosFocusInteractions) private var focusInteractions
    @Environment(\.font) private var environmentFont
    @StateObject private var presenter = COSDropdownPresenter()
    @State private var hovered = false
    @State private var faceWidth: CGFloat = 180
    @FocusState private var faceFocused: Bool
    @FocusState private var listFocused: Bool

    init(_ label: String, selection: Binding<Value>, options: [COSDropdownOption<Value>],
         showsLabel: Bool = true, labelWidth: CGFloat? = nil, icon: String? = nil) {
        self.label = label
        self._selection = selection
        self.options = options
        self.showsLabel = showsLabel
        self.labelWidth = labelWidth
        self.icon = icon
    }

    private var current: COSDropdownOption<Value>? { options.first { $0.value == selection } }
    /// The list drops inline when the surface asks for it, or when there was no window to open a panel in.
    private var listsInline: Bool { inline || presenter.inlineFallback }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if showsLabel && !label.isEmpty {
                    Text(label)
                        .font(environmentFont ?? COSType.body(12.5))
                        .lineLimit(1)
                        .frame(width: labelWidth, alignment: .leading)
                        .accessibilityHidden(true)
                }
                face
            }
            if listsInline && presenter.isOpen {
                HStack(spacing: 10) {
                    if showsLabel && !label.isEmpty, let labelWidth { Color.clear.frame(width: labelWidth, height: 1) }
                    inlineList
                }
            }
        }
        .onChange(of: isEnabled) { _, enabled in if !enabled { presenter.close() } }
        .onDisappear { presenter.close() }
    }

    private var face: some View {
        COSDropdownFace(title: current?.title ?? "", note: current?.note, icon: icon,
                        placeholder: current?.placeholder ?? true, muted: current?.muted ?? false,
                        sizingTitles: options.map(\.title),
                        hot: (hovered || faceFocused) && isEnabled, open: presenter.isOpen)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { faceWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in faceWidth = width }
            })
            .background(COSDropdownAnchor(presenter: presenter).allowsHitTesting(false))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { toggle() }
            .onHover { hovered = $0 }
            .help(current?.title ?? "")
            .opacity(isEnabled ? 1 : 0.55)
            // Focusable as a macOS pop-up button is: with keyboard navigation on (Tab reaches every control). A plain
            // `.focusable()` took a window's first focus, so a face lit gold on open and took Space and Return.
            .focusable(isEnabled, interactions: focusInteractions)
            .focused($faceFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                // Closed, the face opens on a key; open, the list takes its own keys (the panel through its monitor).
                guard !presenter.isOpen, let key = COSDropdownRules.key(press) else { return .ignored }
                return apply(key) ? .handled : .ignored
            }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(label)
            .accessibilityValue(current.map { row in row.note.map { "\(row.title), \($0)" } ?? row.title } ?? "")
            .accessibilityHint(presenter.isOpen ? "Close list" : "Opens a list")
            .accessibilityAction { toggle() }
    }

    /// The inline list takes the keyboard while it shows.
    private var inlineList: some View {
        COSDropdownList(options: options, selection: selection, highlight: $presenter.highlight, framed: true,
                        reveal: presenter.revealTick) { index in
            choose(index)
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in
            guard let key = COSDropdownRules.key(press) else { return .ignored }
            return apply(key) ? .handled : .ignored
        }
        .onAppear { listFocused = true }
    }

    private func toggle() {
        guard isEnabled else { return }
        if presenter.isOpen {
            presenter.close()
        } else if COSDropdownRules.reopens(after: Date().timeIntervalSince(presenter.dismissedAt)) {
            open(COSDropdownRules.openingHighlight(options, selection: selection))
        }
    }

    private func open(_ row: Int?) {
        presenter.highlight = row
        presenter.onKey = { key in apply(key) }
        if !inline {
            _ = presenter.present(faceWidth: faceWidth) {
                COSDropdownPanelList(presenter: presenter, options: options, selection: selection) { index in choose(index) }
            } measuring: {
                COSDropdownList(options: options, selection: selection, highlight: .constant(nil), framed: true) { _ in }
            }
        }
        presenter.isOpen = true
        presenter.reveal()
    }

    private func choose(_ index: Int) {
        guard let value = COSDropdownRules.chosen(index, in: options, enabled: isEnabled) else { return }
        commit(value)
    }

    private func commit(_ value: Value) {
        selection = value
        presenter.close()
        faceFocused = true
    }

    /// True when the key was ours.
    private func apply(_ key: COSDropdownKey) -> Bool {
        switch COSDropdownRules.handle(key, isOpen: presenter.isOpen, highlight: presenter.highlight, options: options,
                                       selection: selection, enabled: isEnabled) {
        case .ignored: return false
        case .open(let row): open(row)
        case .highlight(let row):
            presenter.highlight = row
            presenter.reveal()
            if let row, options.indices.contains(row) { presenter.announce(options[row].title) }
        case .choose(let value): commit(value)
        case .close: presenter.close(); faceFocused = true
        }
        return true
    }
}

/// The closed face: the same card and hairline as a field, a gold chevron where macOS
/// draws its blue stepper, a gold hairline while it is open, hovered or focused.
struct COSDropdownFace: View {
    let title: String
    var note: String? = nil
    var icon: String? = nil
    var placeholder: Bool = false
    var muted: Bool = false
    /// Every row's title: the face's natural width fits the widest, as a macOS pop-up button's does, so it does not
    /// change width with the choice.
    var sizingTitles: [String] = []
    var hot: Bool = false
    var open: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(COSPalette.muted)
            }
            ZStack(alignment: .leading) {
                ForEach(Array(sizingTitles.enumerated()), id: \.offset) { _, sizing in
                    Text(sizing).font(COSType.body(12.5, weight: .medium)).lineLimit(1).hidden()
                }
                // A face too narrow for its value keeps both ends: model names differ at the tail.
                Text(title)
                    .font(COSType.body(12.5, weight: placeholder ? .regular : .medium))
                    .foregroundStyle(placeholder || muted ? COSPalette.muted : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let note {
                Text(note).font(COSType.body(11)).foregroundStyle(COSPalette.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: open ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(COSPalette.accent)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(COSPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(hot || open ? COSPalette.accent : COSPalette.line, lineWidth: 1))
    }
}

/// The open list, the approved card: warm card rows inside an 8 pt rounded card with a gold hairline and a soft
/// shadow; the chosen row marked by a gold rule on its leading edge, the highlighted row by a gold wash, a muted row
/// by its note. Past ten rows it scrolls, and a key that moves the highlight brings that row into view. A title too
/// long for the card keeps both its ends, and its tooltip gives it whole.
struct COSDropdownList<Value: Hashable>: View {
    let options: [COSDropdownOption<Value>]
    let selection: Value
    @Binding var highlight: Int?
    var framed: Bool = true
    /// Changes when a key moved the highlight: scroll that row into view.
    var reveal: Int = 0
    /// The pointer over the list (the panel tracks it itself); the row under it takes the highlight.
    var pointer: CGPoint? = nil
    let choose: (Int) -> Void

    /// More rows than this and the list scrolls inside `scrollHeight`.
    static var scrollsPast: Int { 10 }
    static var scrollHeight: CGFloat { 300 }

    var body: some View {
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(options.indices, id: \.self) { index in row(index).id(index) }
        }
        .padding(.vertical, 4)
        Group {
            if options.count > Self.scrollsPast {
                ScrollViewReader { proxy in
                    ScrollView { rows }
                        .frame(maxHeight: Self.scrollHeight)
                        .onAppear { if let highlight { proxy.scrollTo(highlight, anchor: .center) } }
                        .onChange(of: reveal) { _, _ in if let highlight { proxy.scrollTo(highlight) } }
                }
            } else {
                rows
            }
        }
        .labelStyle(COSLabelStyle())
        .background(COSPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: framed ? 8 : 0))
        .overlay {
            if framed { RoundedRectangle(cornerRadius: 8).stroke(COSPalette.accent.opacity(0.6), lineWidth: 1) }
        }
        .shadow(color: .black.opacity(framed ? 0.18 : 0), radius: 8, y: 4)
    }

    private func row(_ index: Int) -> some View {
        let option = options[index]
        let chosen = option.value == selection
        let lit = highlight == index && option.enabled
        return Button { choose(index) } label: {
            HStack(alignment: .center, spacing: 10) {
                Rectangle().fill(chosen ? COSPalette.gold : Color.clear).frame(width: 2, height: 16)
                Text(option.title)
                    .font(COSType.body(12.5, weight: chosen ? .semibold : .regular))
                    .foregroundStyle(option.enabled && !option.muted ? Color.primary : COSPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = option.note {
                    Text(note).font(COSType.body(11)).foregroundStyle(COSPalette.muted).lineLimit(1).layoutPriority(1)
                }
                Spacer(minLength: 10)
            }
            .padding(.vertical, 6)
            .padding(.trailing, 10)
            .background(lit ? COSPalette.gold.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.enabled)
        .help(option.title)
        .onHover { inside in if inside && option.enabled { highlight = index } }
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: pointer) { _, point in
                if let point, option.enabled, proxy.frame(in: .global).contains(point) { highlight = index }
            }
        })
        .accessibilityLabel(option.note.map { "\(option.title), \($0)" } ?? option.title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// One word of a `COSViewSwitch`.
struct COSViewOption<Value: Hashable> {
    let value: Value
    let title: String
    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

extension COSViewOption: Sendable where Value: Sendable {}

/// A view switcher (Board / Focus, Recent / Archive): words, the current one in ink with a
/// 2 pt gold rule under it, the others muted. Never a pill row (Miles, 2026-09-17: pill-row
/// tabs read as generated). Focusable; Left and Right change it. VoiceOver reads a tab
/// group whose current word is selected.
struct COSViewSwitch<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [COSViewOption<Value>]
    var showsLabel: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.font) private var environmentFont
    @Environment(\.cosFocusInteractions) private var focusInteractions
    @FocusState private var focused: Bool
    @State private var hovered: Int?

    init(_ label: String, selection: Binding<Value>, options: [COSViewOption<Value>], showsLabel: Bool = false) {
        self.label = label
        self._selection = selection
        self.options = options
        self.showsLabel = showsLabel
    }

    /// The value `step` words away from `current`; it stops at the ends.
    static func step(_ values: [Value], from current: Value, by step: Int) -> Value {
        guard let index = values.firstIndex(of: current) else { return values.first ?? current }
        let next = index + step
        return values.indices.contains(next) ? values[next] : current
    }

    var body: some View {
        HStack(spacing: 10) {
            if showsLabel && !label.isEmpty {
                Text(label).font(environmentFont ?? COSType.body(12.5)).lineLimit(1).accessibilityHidden(true)
            }
            HStack(spacing: 18) {
                ForEach(options.indices, id: \.self) { index in word(index) }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(focused ? COSPalette.accent : Color.clear, lineWidth: 1))
            // Focusable with keyboard navigation on, as a segmented control is; never a window's first focus.
            .focusable(isEnabled, interactions: focusInteractions)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { move(-1) }
            .onKeyPress(.rightArrow) { move(1) }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isTabBar)
            .accessibilityLabel(label)
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func word(_ index: Int) -> some View {
        let option = options[index]
        let current = option.value == selection
        return Button { if isEnabled { selection = option.value } } label: {
            VStack(spacing: 5) {
                Text(option.title)
                    .font(COSType.body(12.5, weight: current ? .semibold : .medium))
                    .foregroundStyle(current || hovered == index ? Color.primary : COSPalette.muted)
                    .lineLimit(1)
                Rectangle().fill(current ? COSPalette.gold : Color.clear).frame(height: 2)
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? index : (hovered == index ? nil : hovered) }
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        selection = Self.step(options.map(\.value), from: selection, by: step)
        return .handled
    }
}

/// On and off, for settings: a warm track that fills gold when on, an ink knob. The
/// words lead and the track sits at the trailing edge (`.fixedSize()` keeps it beside them).
struct COSSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration)
    }

    private struct SwitchBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.font) private var environmentFont
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.cosFocusInteractions) private var focusInteractions
        @FocusState private var focused: Bool

        var body: some View {
            // The switch itself flips it; its words do not, as with a stock macOS switch (measured 2026-09-30: a click
            // on a stock switch's label leaves it as it was). Space flips it when it has keyboard focus.
            HStack(spacing: 10) {
                configuration.label
                    .font(environmentFont ?? COSType.body(12.5))
                Spacer(minLength: 8)
                COSSwitchTrack(isOn: configuration.isOn)
                    .overlay(Capsule().stroke(focused ? COSPalette.accent : Color.clear, lineWidth: 1.5).padding(-2.5))
                    .contentShape(Capsule())
                    .onTapGesture { flip() }
                    .focusable(isEnabled, interactions: focusInteractions)
                    .focused($focused)
                    .focusEffectDisabled()
                    .onKeyPress(.space) { flip(); return .handled }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch)
            }
        }

        private func flip() {
            guard isEnabled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { configuration.isOn.toggle() }
        }
    }
}

/// The switch's track and knob, shared with the renders that pin it.
struct COSSwitchTrack: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? COSPalette.gold : COSPalette.raised)
                .overlay(Capsule().stroke(isOn ? Color.clear : COSPalette.line, lineWidth: 1))
                .frame(width: 30, height: 17)
            Circle()
                .fill(isOn ? COSPalette.ink : COSPalette.muted)
                .frame(width: 13, height: 13)
                .padding(2)
        }
        .frame(width: 30, height: 17)
    }
}

/// A checkbox, for filters and confirm steps: a hairline square that fills gold with an ink check.
struct COSCheckStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        CheckBody(configuration: configuration)
    }

    private struct CheckBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.font) private var environmentFont
        @Environment(\.cosFocusInteractions) private var focusInteractions
        @FocusState private var focused: Bool

        var body: some View {
            // The square sits on the label's first line, so a label of several lines keeps it at the top. A click on the
            // square or the words flips it, as with a stock macOS checkbox; Space flips it when it has keyboard focus.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                COSCheckBox(isOn: configuration.isOn)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused ? COSPalette.accent : Color.clear, lineWidth: 1.5).padding(-2.5))
                    .alignmentGuide(.firstTextBaseline) { box in box[.bottom] - 3 }
                configuration.label.font(environmentFont ?? COSType.body(12.5))
            }
            .contentShape(Rectangle())
            .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
            .focusable(isEnabled, interactions: focusInteractions)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(.space) { if isEnabled { configuration.isOn.toggle() }; return .handled }
            .opacity(isEnabled ? 1 : 0.5)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
            }
        }
    }
}

/// The checkbox square, shared with the renders that pin it.
struct COSCheckBox: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(isOn ? COSPalette.gold : COSPalette.card)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(isOn ? Color.clear : COSPalette.muted.opacity(0.6), lineWidth: 1))
                .frame(width: 14, height: 14)
            if isOn {
                Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)).foregroundStyle(COSPalette.ink)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// A toggle that reads as a small chip (a weekday, the Intake view): hairline and muted
/// ink off, gold fill and ink on.
struct COSChipToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(configuration: configuration)
    }

    private struct ChipBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false
        @Environment(\.cosFocusInteractions) private var focusInteractions
        @FocusState private var focused: Bool

        var body: some View {
            let on = configuration.isOn
            configuration.label
                .font(COSType.body(11, weight: on ? .semibold : .medium))
                .foregroundStyle(on ? COSPalette.ink : (hovered && isEnabled ? COSPalette.accent : COSPalette.muted))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .frame(minWidth: 22)
                .background(on ? COSPalette.gold : COSPalette.card)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(focused && isEnabled ? Color.primary.opacity(0.7)
                            : (on ? Color.clear : (hovered && isEnabled ? COSPalette.accent : COSPalette.line)), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
                .onHover { hovered = $0 }
                .focusable(isEnabled, interactions: focusInteractions)
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.space) { if isEnabled { configuration.isOn.toggle() }; return .handled }
                .opacity(isEnabled ? 1 : 0.5)
                .accessibilityRepresentation {
                    Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.button)
                }
        }
    }
}

/// Progress in the gotcos theme. Determinate: a gold line on a hairline track.
/// Indeterminate: a gold arc that turns, and holds still under Reduce Motion. The arc
/// keeps the size macOS gave each control size (mini 10, small 16, regular 32 pt), and a
/// label sits under it as it did.
struct COSProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProgressBody(configuration: configuration)
    }

    static func spinnerSize(_ size: ControlSize) -> CGFloat {
        switch size {
        case .mini: return 10
        case .small: return 16
        default: return 32
        }
    }

    private struct ProgressBody: View {
        let configuration: Configuration
        @Environment(\.controlSize) private var controlSize

        var body: some View {
            if let fraction = configuration.fractionCompleted {
                VStack(alignment: .leading, spacing: 4) {
                    configuration.label.font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                    COSProgressLine(fraction: fraction)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
            } else if configuration.label == nil {
                COSSpinner(size: COSProgressStyle.spinnerSize(controlSize))
                    .accessibilityElement()
                    .accessibilityLabel("In progress")
                    .accessibilityAddTraits(.updatesFrequently)
            } else {
                VStack(spacing: 6) {
                    COSSpinner(size: COSProgressStyle.spinnerSize(controlSize))
                    configuration.label.font(COSType.body(controlSize == .regular ? 12 : 11)).foregroundStyle(COSPalette.muted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }
}

/// A thin gold line on a hairline track.
struct COSProgressLine: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(COSPalette.line)
                Capsule().fill(COSPalette.accent).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
    }
}

/// Busy: a gold arc on a hairline ring. It turns once every 0.9 s; under Reduce Motion it holds still.
struct COSSpinner: View {
    var size: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let turns = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate / 0.9
            arc.rotationEffect(.degrees(-60 + 360 * turns.truncatingRemainder(dividingBy: 1)))
        }
        .frame(width: size, height: size)
    }

    private var arc: some View {
        let width = max(1.5, size / 8)
        return ZStack {
            Circle().stroke(COSPalette.line, lineWidth: width)
            Circle().trim(from: 0, to: 0.28)
                .stroke(COSPalette.accent, style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        .padding(width / 2)
    }
}

/// A stepper: the words, then the value between two icon buttons (minus, plus). The
/// value stays inside `range`; VoiceOver adjusts it as one control.
struct COSStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    /// What sits between the buttons; nil hides it (the value shows elsewhere).
    var valueText: String?
    var showsLabel: Bool = true

    @Environment(\.font) private var environmentFont
    @Environment(\.isEnabled) private var isEnabled

    init(_ label: String, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1,
         valueText: String?, showsLabel: Bool = true) {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.valueText = valueText
        self.showsLabel = showsLabel
    }

    /// `current` moved by `delta`, kept inside `range`.
    static func stepped(_ current: Int, by delta: Int, in range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, current + delta))
    }

    var body: some View {
        HStack(spacing: 8) {
            if showsLabel && !label.isEmpty {
                Text(label).font(environmentFont ?? COSType.body(12.5)).lineLimit(1)
                Spacer(minLength: 8)
            }
            Button { value = Self.stepped(value, by: -step, in: range) } label: { Image(systemName: "minus") }
                .buttonStyle(COSIconButtonStyle(size: 20))
                .disabled(value <= range.lowerBound)
            if let valueText {
                Text(valueText).font(COSType.mono(11.5)).monospacedDigit().lineLimit(1).frame(minWidth: 34)
            }
            Button { value = Self.stepped(value, by: step, in: range) } label: { Image(systemName: "plus") }
                .buttonStyle(COSIconButtonStyle(size: 20))
                .disabled(value >= range.upperBound)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText ?? "\(value)")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            switch direction {
            case .increment: value = Self.stepped(value, by: step, in: range)
            case .decrement: value = Self.stepped(value, by: -step, in: range)
            @unknown default: break
            }
        }
    }
}

/// Disclosure in the gotcos theme: the words, then a gold chevron that turns a quarter
/// when open. Applied once per window root, so every DisclosureGroup takes it.
struct COSDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        DisclosureBody(configuration: configuration)
    }

    private struct DisclosureBody: View {
        let configuration: Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { configuration.isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        configuration.label.font(COSType.body(12, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(COSPalette.accent)
                            .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
                if configuration.isExpanded {
                    configuration.content
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

/// A multi-line editor on the field's card and hairline.
private struct COSEditor: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(COSPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(COSPalette.line, lineWidth: 1))
    }
}

/// The face of a `Menu` in the theme: the quiet button with a gold chevron after the words.
struct COSMenuLabel: View {
    let title: String
    var icon: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(COSPalette.accent)
        }
    }
}

extension View {
    func cosEditor() -> some View { modifier(COSEditor()) }

    /// A `Menu` drawn as a quiet button with its own gold chevron.
    func cosMenu() -> some View {
        menuStyle(.button).menuIndicator(.hidden).buttonStyle(COSQuietButtonStyle()).labelStyle(COSLabelStyle())
    }

    /// Everything a window root sets once: progress, disclosure, the quiet button for any
    /// button that names no style of its own (a stock push button otherwise), the centered
    /// label (0.5.253), and a gold tint as the backstop for the two controls that stay
    /// native (Slider, DatePicker).
    func cosControlTheme() -> some View {
        progressViewStyle(COSProgressStyle())
            .disclosureGroupStyle(COSDisclosureStyle())
            .buttonStyle(COSQuietButtonStyle())
            // 0.5.253: a Label anywhere in the window has its icon in the middle of its words, not by the first line.
            .labelStyle(COSLabelStyle())
            .tint(COSPalette.gold)
    }
}
