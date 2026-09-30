import AppKit
import SwiftUI

// 0.5.251 GOTCOS controls, executed. The shipped components (Sources/COSBrand.swift, with the real palette from
// Views.swift) run in a window ordered in far off screen and take clicks and keys posted in-process, the path a
// real click takes once it reaches the app. Pure rules are checked directly; the switch and checkbox are rendered
// and their pixels read. Nothing here contacts the server or a provider.
//
// Run: Tests/run-controls.sh (called by Tests/run.sh).

@MainActor private final class Probe: ObservableObject {
    @Published var inline = "claude"
    @Published var popover = "claude"
    @Published var disabledChoice = "claude"
    @Published var view = "board"
    @Published var on = false
    @Published var disabledOn = false
    @Published var checked = false
    @Published var count = 3
    var frames: [String: CGRect] = [:]
}

private struct Frame: ViewModifier {
    let key: String
    let probe: Probe
    func body(content: Content) -> some View {
        content.background(GeometryReader { proxy in
            Color.clear
                .onAppear { probe.frames[key] = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in probe.frames[key] = frame }
        })
    }
}

private let providers: [COSDropdownOption<String>] = [
    COSDropdownOption("", "Choose provider", placeholder: true),
    COSDropdownOption("claude", "Claude"),
    COSDropdownOption("codex", "Codex"),
    COSDropdownOption("cursor", "Cursor", note: "unavailable", enabled: false),
    COSDropdownOption("ollama", "Ollama"),
]

private struct Board: View {
    @ObservedObject var probe: Probe
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            COSDropdown("Inline", selection: $probe.inline, options: providers, labelWidth: 60)
                .environment(\.cosDropdownInline, true)
                .modifier(Frame(key: "inline", probe: probe))
            COSDropdown("Popover", selection: $probe.popover, options: providers, labelWidth: 60)
                .modifier(Frame(key: "popover", probe: probe))
            COSDropdown("Off", selection: $probe.disabledChoice, options: providers, labelWidth: 60)
                .environment(\.cosDropdownInline, true)
                .disabled(true)
                .modifier(Frame(key: "disabled", probe: probe))
            COSViewSwitch("Layout", selection: $probe.view,
                          options: [COSViewOption("board", "Board"), COSViewOption("focus", "Focus")])
                .fixedSize()
                .modifier(Frame(key: "switcher", probe: probe))
            Toggle("Background jobs", isOn: $probe.on).toggleStyle(COSSwitchStyle())
                .modifier(Frame(key: "switch", probe: probe))
            Toggle("Paused", isOn: $probe.disabledOn).toggleStyle(COSSwitchStyle()).disabled(true)
                .modifier(Frame(key: "switchOff", probe: probe))
            Toggle("Only mine", isOn: $probe.checked).toggleStyle(COSCheckStyle())
                .fixedSize()
                .modifier(Frame(key: "check", probe: probe))
            COSStepper("Items", value: $probe.count, in: 1...4, valueText: "\(probe.count)")
                .modifier(Frame(key: "stepper", probe: probe))
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 360, height: Self.height, alignment: .top)
        .cosControlTheme()
    }
    static let height: CGFloat = 560
}

@main struct ControlsContract {
    @MainActor static func main() async throws {
        rules()
        try await interaction()
        renders()
        print("PASS: GOTCOS controls (dropdown rules and keys, inline and popover choice, disabled dropdown and row, view switch, switch, checkbox, stepper bounds, switch and checkbox pixels, spinner sizes)")
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String, line: UInt = #line) {
        if !condition { fatalError("ControlsContract line \(line): \(message())") }
    }

    // MARK: - Pure rules

    @MainActor static func rules() {
        typealias R = COSDropdownRules
        // Opening highlights the selection, or the first row that can be chosen.
        check(R.openingHighlight(providers, selection: "codex") == 2, "opens on the selection")
        check(R.openingHighlight(providers, selection: "cursor") == 0, "a disabled selection opens on the first choosable row")
        // Closed: Space, Return, Up and Down open it; Escape and letters pass through.
        check(R.handle(.confirm, isOpen: false, highlight: nil, options: providers, selection: "claude", enabled: true) == .open(highlight: 1), "Return opens")
        check(R.handle(.space, isOpen: false, highlight: nil, options: providers, selection: "claude", enabled: true) == .open(highlight: 1), "Space opens")
        check(R.handle(.escape, isOpen: false, highlight: nil, options: providers, selection: "claude", enabled: true) == .ignored, "Escape passes through a closed dropdown")
        check(R.handle(.letter("c"), isOpen: false, highlight: nil, options: providers, selection: "claude", enabled: true) == .ignored, "letters pass through a closed dropdown")
        // Open: Down and Up move and skip a disabled row; they stop at the ends.
        check(R.handle(.down, isOpen: true, highlight: 1, options: providers, selection: "claude", enabled: true) == .highlight(2), "Down moves")
        check(R.handle(.down, isOpen: true, highlight: 2, options: providers, selection: "claude", enabled: true) == .highlight(4), "Down skips the disabled row")
        check(R.handle(.down, isOpen: true, highlight: 4, options: providers, selection: "claude", enabled: true) == .highlight(4), "Down stops at the end")
        check(R.handle(.up, isOpen: true, highlight: 4, options: providers, selection: "claude", enabled: true) == .highlight(2), "Up skips the disabled row")
        check(R.handle(.up, isOpen: true, highlight: 0, options: providers, selection: "claude", enabled: true) == .highlight(0), "Up stops at the top")
        // Return and Space choose the highlight; a disabled highlight chooses nothing.
        check(R.handle(.confirm, isOpen: true, highlight: 2, options: providers, selection: "claude", enabled: true) == .choose("codex"), "Return chooses")
        check(R.handle(.space, isOpen: true, highlight: 4, options: providers, selection: "claude", enabled: true) == .choose("ollama"), "Space chooses")
        check(R.handle(.confirm, isOpen: true, highlight: 3, options: providers, selection: "claude", enabled: true) == .close, "a disabled row is never chosen")
        check(R.handle(.escape, isOpen: true, highlight: 2, options: providers, selection: "claude", enabled: true) == .close, "Escape closes")
        // A letter jumps to the next row that starts with it, wrapping, never onto a disabled row.
        check(R.handle(.letter("o"), isOpen: true, highlight: 1, options: providers, selection: "claude", enabled: true) == .highlight(4), "o jumps to Ollama")
        check(R.handle(.letter("C"), isOpen: true, highlight: 1, options: providers, selection: "claude", enabled: true) == .highlight(2), "C jumps past Claude to Codex (not Cursor, disabled)")
        check(R.handle(.letter("c"), isOpen: true, highlight: 2, options: providers, selection: "claude", enabled: true) == .highlight(0), "c wraps to Choose provider")
        // A disabled dropdown takes no keys, and closes if it was open.
        check(R.handle(.confirm, isOpen: false, highlight: nil, options: providers, selection: "claude", enabled: false) == .ignored, "a disabled dropdown does not open")
        check(R.handle(.confirm, isOpen: true, highlight: 2, options: providers, selection: "claude", enabled: false) == .close, "a disabled dropdown chooses nothing")
        // A click chooses only a choosable row of an enabled dropdown.
        check(R.chosen(2, in: providers, enabled: true) == "codex", "a click chooses its row")
        check(R.chosen(3, in: providers, enabled: true) == nil, "a disabled row is not chosen by a click")
        check(R.chosen(2, in: providers, enabled: false) == nil, "a disabled dropdown is not chosen by a click")
        check(R.chosen(9, in: providers, enabled: true) == nil, "no row, no choice")
        // The view switch's arrows step one word and stop at the ends.
        let words = ["recent", "archive", "search"]
        check(COSViewSwitch<String>.step(words, from: "recent", by: 1) == "archive", "Right steps")
        check(COSViewSwitch<String>.step(words, from: "archive", by: -1) == "recent", "Left steps")
        check(COSViewSwitch<String>.step(words, from: "search", by: 1) == "search", "Right stops at the end")
        check(COSViewSwitch<String>.step(words, from: "recent", by: -1) == "recent", "Left stops at the start")
        // The stepper stays inside its range.
        check(COSStepper.stepped(4, by: 1, in: 1...4) == 4 && COSStepper.stepped(1, by: -1, in: 1...4) == 1, "the stepper stops at its bounds")
        check(COSStepper.stepped(2, by: 1, in: 1...4) == 3 && COSStepper.stepped(3, by: -1, in: 1...4) == 2, "the stepper steps")
        check(COSStepper.stepped(3, by: 5, in: 1...4) == 4, "a large step is clamped")
    }

    // MARK: - Clicks and keys through the real views

    @MainActor static func interaction() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let probe = Probe()
        let host = NSHostingView(rootView: Board(probe: probe))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: Board.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        await settle(400)
        func frame(_ key: String) -> CGRect {
            guard let frame = probe.frames[key] else { fatalError("ControlsContract: no frame for \(key)") }
            return frame
        }
        /// A point `dx` from the frame's left and `dy` from its top, in window coordinates.
        func point(_ key: String, dx: CGFloat, dy: CGFloat) -> NSPoint {
            let f = frame(key)
            return NSPoint(x: f.minX + dx, y: Board.height - (f.minY + dy))
        }

        // Inline dropdown: a click opens the list under the face; a click on a row chooses it and closes.
        let closed = frame("inline").height
        click(window, point("inline", dx: 200, dy: closed / 2)); await settle()
        check(frame("inline").height > closed + 100, "a click on the face opens the list (\(frame("inline").height))")
        // Rows sit under the face: gap 4, inset 4, 28 pt each. Row 2 is Codex.
        click(window, point("inline", dx: 200, dy: closed + 4 + 4 + 28 * 2 + 14)); await settle()
        check(probe.inline == "codex", "a row click chooses it: \(probe.inline)")
        check(frame("inline").height == closed, "choosing closes the list")
        // The disabled row (Cursor) is never chosen by a click.
        click(window, point("inline", dx: 200, dy: closed / 2)); await settle()
        click(window, point("inline", dx: 200, dy: closed + 4 + 4 + 28 * 3 + 14)); await settle()
        check(probe.inline == "codex", "a disabled row is not chosen: \(probe.inline)")
        // Keys: the face has focus while its list is open. Down, then Return, chooses the next row.
        key(window, .down); await settle()
        key(window, .return); await settle()
        check(probe.inline == "ollama", "Down skips the disabled row and Return chooses Ollama: \(probe.inline)")
        check(frame("inline").height == closed, "Return closes the list")
        // Escape closes without choosing.
        click(window, point("inline", dx: 200, dy: closed / 2)); await settle()
        key(window, .up); await settle()
        key(window, .escape); await settle()
        check(probe.inline == "ollama" && frame("inline").height == closed, "Escape closes without choosing: \(probe.inline)")

        // A disabled dropdown neither opens nor changes.
        let disabledHeight = frame("disabled").height
        click(window, point("disabled", dx: 200, dy: disabledHeight / 2)); await settle()
        check(frame("disabled").height == disabledHeight, "a disabled dropdown does not open")
        click(window, point("disabled", dx: 200, dy: disabledHeight + 4 + 4 + 28 * 2 + 14)); await settle()
        check(probe.disabledChoice == "claude", "a disabled dropdown keeps its value: \(probe.disabledChoice)")

        // Popover dropdown: a click opens a popover; a click on its row chooses it and closes it.
        click(window, point("popover", dx: 200, dy: frame("popover").height / 2)); await settle(500)
        let popovers = NSApp.windows.filter { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
        check(popovers.count == 1, "the face opens one popover (\(popovers.count))")
        if let pop = popovers.first {
            let top = pop.contentLayoutRect.maxY
            click(pop, NSPoint(x: pop.contentLayoutRect.midX, y: top - (4 + 28 * 2 + 14))); await settle(500)
        }
        check(probe.popover == "codex", "a popover row click chooses it: \(probe.popover)")
        check(NSApp.windows.filter { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }.isEmpty, "choosing closes the popover")

        // View switch: a click on Focus makes it current.
        click(window, point("switcher", dx: frame("switcher").width - 20, dy: frame("switcher").height / 2)); await settle()
        check(probe.view == "focus", "a click on a word switches to it: \(probe.view)")

        // Switch: a click on the track flips it, twice; a disabled switch does not.
        let track = point("switch", dx: frame("switch").width - 15, dy: frame("switch").height / 2)
        click(window, track); await settle()
        check(probe.on, "a click turns the switch on")
        click(window, track); await settle()
        check(!probe.on, "a second click turns it off")
        click(window, point("switchOff", dx: frame("switchOff").width - 15, dy: frame("switchOff").height / 2)); await settle()
        check(!probe.disabledOn, "a disabled switch does not flip")

        // Checkbox: a click on the square or its words flips it.
        click(window, point("check", dx: 7, dy: frame("check").height / 2)); await settle()
        check(probe.checked, "a click checks the box")
        click(window, point("check", dx: frame("check").width - 8, dy: frame("check").height / 2)); await settle()
        check(!probe.checked, "a click on its words unchecks it")

        // Stepper: plus stops at the upper bound; minus steps down and stops at the lower one.
        let stepper = frame("stepper")
        let plus = point("stepper", dx: stepper.width - 10, dy: stepper.height / 2)
        let minus = point("stepper", dx: stepper.width - 10 - 20 - 8 - 34 - 8, dy: stepper.height / 2)
        click(window, plus); await settle()
        check(probe.count == 4, "plus steps up: \(probe.count)")
        click(window, plus); await settle()
        check(probe.count == 4, "plus stops at the upper bound: \(probe.count)")
        for _ in 0..<5 { click(window, minus); await settle(120) }
        check(probe.count == 1, "minus stops at the lower bound: \(probe.count)")
    }

    // MARK: - Pixels

    @MainActor static func renders() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let dark = appearance == .darkAqua
            let on = sample(COSSwitchTrack(isOn: true), size: CGSize(width: 30, height: 17), appearance: appearance)
            let off = sample(COSSwitchTrack(isOn: false), size: CGSize(width: 30, height: 17), appearance: appearance)
            // On: the gold track shows at the left end, the ink knob at the right. Off: the knob (muted) at the left.
            check(isGold(on(5, 8)), "switch on: gold track at the left end (\(dark ? "dark" : "light")) \(on(5, 8))")
            check(isInk(on(23, 8)), "switch on: ink knob at the right (\(dark ? "dark" : "light")) \(on(23, 8))")
            check(!isGold(off(5, 8)) && !isGold(off(24, 8)), "switch off: no gold (\(dark ? "dark" : "light"))")
            check(!isInk(off(8, 8)), "switch off: the knob is not ink")
            let box = sample(COSCheckBox(isOn: true), size: CGSize(width: 14, height: 14), appearance: appearance)
            let empty = sample(COSCheckBox(isOn: false), size: CGSize(width: 14, height: 14), appearance: appearance)
            check(isGold(box(2, 2)), "checkbox on: gold fill (\(dark ? "dark" : "light")) \(box(2, 2))")
            check(!isGold(empty(4, 4)), "checkbox off: no gold fill (\(dark ? "dark" : "light"))")
            // The style draws the square it is given: a checked Toggle renders gold where the square sits.
            let styled = sample(Toggle("x", isOn: .constant(true)).toggleStyle(COSCheckStyle()).fixedSize(),
                                size: CGSize(width: 40, height: 20), appearance: appearance)
            check((0..<20).contains { y in isGold(styled(3, y)) }, "a checked COSCheckStyle Toggle draws the gold square")
            let unstyled = sample(Toggle("x", isOn: .constant(false)).toggleStyle(COSCheckStyle()).fixedSize(),
                                  size: CGSize(width: 40, height: 20), appearance: appearance)
            check(!(0..<20).contains { y in isGold(unstyled(3, y)) }, "an unchecked COSCheckStyle Toggle has no gold")
            let styledSwitch = sample(Toggle("x", isOn: .constant(true)).toggleStyle(COSSwitchStyle()).frame(width: 80),
                                      size: CGSize(width: 80, height: 20), appearance: appearance)
            check((0..<20).contains { y in isGold(styledSwitch(55, y)) }, "an on COSSwitchStyle Toggle draws the gold track at the trailing edge")
            let offSwitch = sample(Toggle("x", isOn: .constant(false)).toggleStyle(COSSwitchStyle()).frame(width: 80),
                                   size: CGSize(width: 80, height: 20), appearance: appearance)
            check(!(0..<20).contains { y in isGold(offSwitch(55, y)) }, "an off COSSwitchStyle Toggle has no gold")
        }
        // The spinner keeps the size macOS gave each control size.
        for (size, points) in [(ControlSize.mini, 10.0), (.small, 16.0), (.regular, 32.0)] {
            let fitted = NSHostingView(rootView: ProgressView().controlSize(size).progressViewStyle(COSProgressStyle())).fittingSize
            check(fitted.width == points && fitted.height == points, "a \(size) spinner is \(points) pt: \(fitted)")
        }
    }

    // MARK: - Helpers

    private enum Key { case up, down, `return`, escape }

    @MainActor private static func click(_ window: NSWindow, _ point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            window.sendEvent(event)
        }
    }

    @MainActor private static func key(_ window: NSWindow, _ key: Key) {
        let (code, characters): (UInt16, String) = switch key {
        case .up: (126, "\u{F700}")
        case .down: (125, "\u{F701}")
        case .return: (36, "\r")
        case .escape: (53, "\u{1B}")
        }
        let flags: NSEvent.ModifierFlags = key == .up || key == .down ? [.numericPad, .function] : []
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
            window.sendEvent(event)
        }
    }

    @MainActor private static func settle(_ milliseconds: Int = 250) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// Renders `view` at 2x and returns a reader of point (x, y) from the top left.
    @MainActor private static func sample<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name) -> (Int, Int) -> NSColor {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / size.width
        return { x, y in
            let color = rep.colorAt(x: Int(CGFloat(x) * scale + scale / 2), y: Int(CGFloat(y) * scale + scale / 2))
            return color?.usingColorSpace(.sRGB) ?? .clear
        }
    }

    /// COSPalette.gold is (0.79, 0.66, 0.43).
    private static func isGold(_ c: NSColor) -> Bool {
        c.alphaComponent > 0.9 && abs(c.redComponent - 0.79) < 0.06 && abs(c.greenComponent - 0.66) < 0.06 && abs(c.blueComponent - 0.43) < 0.06
    }

    /// COSPalette.ink is (0.12, 0.09, 0.07).
    private static func isInk(_ c: NSColor) -> Bool {
        c.alphaComponent > 0.9 && c.redComponent < 0.2 && c.greenComponent < 0.16 && c.blueComponent < 0.14
    }
}
