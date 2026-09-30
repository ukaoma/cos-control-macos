import AppKit
import SwiftUI

// 0.5.251 and 0.5.252 GOTCOS controls, executed. The shipped components (Sources/COSBrand.swift, with the real palette
// from Views.swift) run in windows ordered in far off screen and take clicks and keys sent in-process. Clicks, and the
// keys an open dropdown takes, go through NSApp.sendEvent, the path a person's click takes once it reaches the app,
// so the dropdown's local event monitor runs. Keys for a focused control go to the window, as they would if it were
// key (a test window off screen never is). Pure rules are checked directly; pixels are read from AppKit's own drawing.
// Nothing here contacts the server or a provider, takes the keyboard focus, or shows on screen: the process can never
// become the active app (activation policy .prohibited, the same as the other UI suites), its windows sit 8,000 points
// off every screen, it adds no status item, and no event leaves the process (nothing is posted to the system, the
// pointer is never moved). A shared desktop is left alone; the contract fails if the app ever becomes active.
//
// What this cannot do, and what covers it instead:
//   - Turn on the Mac's Keyboard navigation setting. The keyboard board sets `cosFocusInteractions` to `.automatic`,
//     which is the state that setting puts the controls in. The first board keeps the default and proves that without
//     the setting nothing takes a window's first focus.
//   - Hover with a real pointer. A pressed button runs the same ink and hairline as a hovered one, and is read here.
//   - A real MenuBarExtra(.window), a key window, a stock control's own click handling: Tests/dropdown-canary.
//
// Run: Tests/run-controls.sh (called by Tests/run.sh).

@MainActor private final class Probe: ObservableObject {
    @Published var inline = "claude"
    @Published var panel = "claude"
    @Published var long = "n00"
    @Published var disabledChoice = "claude"
    @Published var view = "board"
    @Published var on = false
    @Published var disabledOn = false
    @Published var checked = false
    @Published var chip = false
    @Published var count = 3
    @Published var disclosed = false
    @Published var pressed = 0
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
                .onDisappear { probe.frames[key] = nil }
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

/// Twenty rows: past ten, the list scrolls inside its card.
private let twenty: [COSDropdownOption<String>] = (0..<20).map { COSDropdownOption(String(format: "n%02d", $0), String(format: "Row %02d", $0)) }

private struct Board: View {
    @ObservedObject var probe: Probe
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            COSDropdown("Inline", selection: $probe.inline, options: providers, labelWidth: 60)
                .environment(\.cosDropdownInline, true)
                .modifier(Frame(key: "inline", probe: probe))
            COSDropdown("Panel", selection: $probe.panel, options: providers, labelWidth: 60)
                .modifier(Frame(key: "panel", probe: probe))
            COSDropdown("Long", selection: $probe.long, options: twenty, labelWidth: 60)
                .modifier(Frame(key: "long", probe: probe))
            COSDropdown("Off", selection: $probe.disabledChoice, options: providers, labelWidth: 60)
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
            Toggle("Mon", isOn: $probe.chip).toggleStyle(COSChipToggleStyle())
                .fixedSize()
                .modifier(Frame(key: "chip", probe: probe))
            COSStepper("Items", value: $probe.count, in: 1...4, valueText: "\(probe.count)")
                .modifier(Frame(key: "stepper", probe: probe))
            // The two below name no style of their own: the window root's theme gives them theirs.
            DisclosureGroup("More", isExpanded: $probe.disclosed) {
                Text("Inside").modifier(Frame(key: "inside", probe: probe))
            }
            .modifier(Frame(key: "disclosure", probe: probe))
            Button("Plain") { probe.pressed += 1 }
                .modifier(Frame(key: "button", probe: probe))
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 360, height: Self.height, alignment: .top)
        .background(COSPalette.card)
        .cosControlTheme()
    }
    static let height: CGFloat = 640
}

/// The controls as they are on a Mac with Keyboard navigation on: Tab reaches each one.
private struct KeyboardBoard: View {
    @ObservedObject var probe: Probe
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            COSDropdown("Panel", selection: $probe.panel, options: providers, labelWidth: 60)
                .modifier(Frame(key: "panel", probe: probe))
            COSViewSwitch("Layout", selection: $probe.view,
                          options: [COSViewOption("board", "Board"), COSViewOption("focus", "Focus"), COSViewOption("list", "List")])
                .fixedSize()
            Toggle("Background jobs", isOn: $probe.on).toggleStyle(COSSwitchStyle())
            Toggle("Only mine", isOn: $probe.checked).toggleStyle(COSCheckStyle()).fixedSize()
            Toggle("Mon", isOn: $probe.chip).toggleStyle(COSChipToggleStyle()).fixedSize()
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 360, height: Self.height, alignment: .top)
        .cosControlTheme()
        .environment(\.cosFocusInteractions, .automatic)
    }
    static let height: CGFloat = 300
}

@main struct ControlsContract {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        nonisolated(unsafe) var activated = false
        let watch = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            activated = true
        }
        defer { NotificationCenter.default.removeObserver(watch) }
        rules()
        try await interaction()
        try await keyboard()
        theme()
        renders()
        check(!activated && !app.isActive, "the contract never became the active app (a shared desktop is left alone)")
        print("PASS: GOTCOS controls (dropdown rules and keys; the open list as a child panel: opens, chooses, keys, face click closes, outside click, Escape, Tab, card pixels, scrolls the highlight into view; inline list; disabled dropdown and row; no first focus by default; keyboard: face keys, view switch arrows, Space on switch, checkbox and chip; switch label does not flip; checkbox, chip, stepper bounds; disclosure expands; root theme: button, progress, disclosure, tint; light-mode contrast; switch and checkbox pixels; spinner sizes)")
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
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
        // A click on the face of an open list closes it (as a click outside the list), and that click's tap must not
        // open it again: the face reopens only once 0.3 s have passed since the click was released.
        check(!R.reopens(after: 0) && !R.reopens(after: 0.3) && R.reopens(after: 0.31), "the closing click does not reopen")
        // The open list is as wide as its face, wider only when a row needs it, and never past the cap.
        check(R.listWidth(face: 288, ideal: 150) == 288, "as wide as the face")
        check(R.listWidth(face: 200, ideal: 405.2) == 406, "wider when a long name needs it")
        check(R.listWidth(face: 200, ideal: 900) == R.widestList, "never past the cap")
        check(R.listWidth(face: 500, ideal: 900) == 500, "a face wider than the cap keeps its own width")
        // The card sits 4 pt under the face; above it when there is no room below and there is above; kept on screen.
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let card = CGSize(width: 300, height: 200)
        check(R.listOrigin(face: CGRect(x: 100, y: 500, width: 300, height: 30), card: card, visible: screen) == CGPoint(x: 100, y: 296), "under the face")
        check(R.listOrigin(face: CGRect(x: 100, y: 100, width: 300, height: 30), card: card, visible: screen) == CGPoint(x: 100, y: 134), "above when there is no room below")
        check(R.listOrigin(face: CGRect(x: 900, y: 500, width: 80, height: 30), card: card, visible: screen).x == 700, "kept on its screen")
        check(R.listOrigin(face: CGRect(x: -8000, y: -8000, width: 300, height: 30), card: card, visible: nil) == CGPoint(x: -8000, y: -8204), "no screen, no clamping")
        // The keys an open panel hears come as AppKit key-downs.
        check(R.key(keyCode: 126, characters: nil, modifiers: []) == .up && R.key(keyCode: 125, characters: nil, modifiers: []) == .down)
        check(R.key(keyCode: 36, characters: "\r", modifiers: []) == .confirm && R.key(keyCode: 76, characters: "\u{3}", modifiers: []) == .confirm)
        check(R.key(keyCode: 49, characters: " ", modifiers: []) == .space && R.key(keyCode: 53, characters: "\u{1B}", modifiers: []) == .escape)
        check(R.key(keyCode: 8, characters: "c", modifiers: []) == .letter("c") && R.key(keyCode: 18, characters: "1", modifiers: []) == .letter("1"))
        check(R.key(keyCode: 48, characters: "\t", modifiers: []) == nil, "Tab is not the list's")
        check(R.key(keyCode: 13, characters: "w", modifiers: [.command]) == nil, "a command key is not the list's")
    }


    // MARK: - Clicks and keys through the real views

    @MainActor private static func open<V: View>(_ view: V, height: CGFloat, appearance: NSAppearance.Name = .aqua) -> NSWindow {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        window.orderFrontRegardless()
        return window
    }

    /// The dropdown's open list: a visible borderless child panel of `window`.
    @MainActor private static func openList(_ window: NSWindow) -> NSWindow? {
        window.childWindows?.first { $0.isVisible && $0 is NSPanel && $0.styleMask.contains(.nonactivatingPanel) }
    }
    @MainActor private static func popovers() -> Int {
        NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }.count
    }
    /// The height of one row of the five-row list (the card less its 4 pt insets, over five).
    @MainActor private static func rowHeight(_ list: NSWindow) -> CGFloat {
        let room = COSDropdownPresenter.shadowRoom
        return (list.frame.height - room.top - room.bottom - 8) / 5
    }
    /// The middle of row `index` of the five-row list, in the list panel's coordinates.
    @MainActor private static func row(_ list: NSWindow, _ index: Int) -> NSPoint {
        let height = rowHeight(list)
        return NSPoint(x: list.frame.width / 2, y: list.frame.height - (COSDropdownPresenter.shadowRoom.top + 4 + height * CGFloat(index) + height / 2))
    }

    @MainActor static func interaction() async throws {
        let probe = Probe()
        let window = open(Board(probe: probe), height: Board.height)
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
        let room = COSDropdownPresenter.shadowRoom

        // Without Keyboard navigation, nothing takes the window's first focus: Space, Return and Down on a window just
        // opened do nothing at all. (0.5.251's first build had the first dropdown light up and open on Space.)
        let closed = frame("inline").height
        for key in [Key.space, .return, .down] { windowKey(window, key); await settle(120) }
        check(frame("inline").height == closed && openList(window) == nil && !probe.on && !probe.checked && !probe.chip,
              "nothing takes the keyboard by default")

        // Inline dropdown: a click opens the list under the face; a click on a row chooses it and closes.
        click(window, point("inline", dx: 200, dy: closed / 2)); await settle()
        check(frame("inline").height > closed + 100, "a click on the face opens the list (\(frame("inline").height))")
        check(openList(window) == nil, "an inline list opens no panel")
        // Rows sit under the face: gap 4, inset 4, 28 pt each. Row 2 is Codex.
        click(window, point("inline", dx: 200, dy: closed + 4 + 4 + 28 * 2 + 14)); await settle()
        check(probe.inline == "codex", "a row click chooses it: \(probe.inline)")
        check(frame("inline").height == closed, "choosing closes the list")
        // The disabled row (Cursor) is never chosen by a click.
        click(window, point("inline", dx: 200, dy: closed / 2)); await settle()
        click(window, point("inline", dx: 200, dy: closed + 4 + 4 + 28 * 3 + 14)); await settle()
        check(probe.inline == "codex", "a disabled row is not chosen: \(probe.inline)")
        // Keys: the inline list has focus while it is open. Down, then Return, chooses the next row.
        windowKey(window, .down); await settle()
        windowKey(window, .return); await settle()
        check(probe.inline == "ollama", "Down skips the disabled row and Return chooses Ollama: \(probe.inline)")
        check(frame("inline").height == closed, "Return closes the list")
        // Escape closes without choosing.
        click(window, point("inline", dx: 200, dy: closed / 2)); await settle()
        windowKey(window, .up); await settle()
        windowKey(window, .escape); await settle()
        check(probe.inline == "ollama" && frame("inline").height == closed, "Escape closes without choosing: \(probe.inline)")

        // A disabled dropdown neither opens nor changes.
        let disabledFace = point("disabled", dx: 200, dy: frame("disabled").height / 2)
        click(window, disabledFace); await settle()
        check(openList(window) == nil && frame("disabled").height == closed, "a disabled dropdown does not open")
        check(probe.disabledChoice == "claude", "a disabled dropdown keeps its value: \(probe.disabledChoice)")

        // The open list is a borderless child panel under the face: the approved card, no popover.
        let face = point("panel", dx: 200, dy: frame("panel").height / 2)
        let faceWidth = frame("panel").width - 70
        click(window, face); await settle(350)
        guard let list = openList(window) else { fatalError("ControlsContract: a click on the face opens no child panel") }
        check(popovers() == 0, "no popover: no arrow, no system chrome")
        check(list.styleMask.contains(.borderless) && !list.styleMask.contains(.titled) && !list.hasShadow && !list.isOpaque,
              "the panel is borderless and draws its own card")
        // A drawing of the content view cannot show the window's own background (the mutation gate found that on
        // 2026-09-30: a panel with the system window background passed the corner pixel), so it is read directly.
        check(list.backgroundColor.alphaComponent == 0, "the panel has no window background of its own: \(list.backgroundColor)")
        check(!list.canBecomeKey, "the list never takes the keyboard from its parent")
        let cardWidth = list.frame.width - room.left - room.right
        let cardHeight = list.frame.height - room.top - room.bottom
        check(abs(cardWidth - faceWidth) < 1.5, "the card is as wide as the face: \(cardWidth) and \(faceWidth)")
        let rh = rowHeight(list)
        check(rh > 24 && rh < 34, "five rows and the card's inset: \(cardHeight)")
        let faceOnScreen = window.convertPoint(toScreen: NSPoint(x: frame("panel").minX + 70, y: Board.height - frame("panel").maxY))
        check(abs(list.frame.minX + room.left - faceOnScreen.x) < 1.5, "the card's leading edge is the face's")
        check(abs(list.frame.maxY - room.top - (faceOnScreen.y - COSDropdownRules.listGap)) < 1.5, "the card sits 4 pt under the face")
        // Its pixels (light): nothing drawn at the panel's corner; the card's corner is rounded; a gold hairline; the
        // chosen row's gold rule; a soft shadow under it.
        let card = pixels(list.contentView!)
        check(card(1, 1).alphaComponent < 0.02, "no window background behind the card")
        check(card(Int(room.left) + 1, Int(room.top) + 1).alphaComponent < 0.6, "the card's corner is rounded")
        // The 1 pt hairline is centered on the card's edge: its inner half covers the pixel just inside the edge.
        let hairline = exact(list.contentView!)(room.left + 0.25, room.top + cardHeight / 2)
        check(hairline.alphaComponent > 0.9 && hairline.redComponent - hairline.blueComponent > 0.1 && hairline.redComponent < 0.9,
              "a gold hairline frames the card: \(hairline)")
        let middle = card(Int(room.left + cardWidth / 2), Int(room.top + 4 + rh * 4 + 3))
        check(middle.alphaComponent > 0.98 && middle.redComponent > 0.97 && middle.blueComponent > 0.97, "the card is the warm card fill (white in light): \(middle)")
        let precise = exact(list.contentView!)
        let rule = (0..<8).map { precise(room.left + CGFloat($0) * 0.5, room.top + 4 + rh * 1.5) }.first(where: isGoldish) ?? .clear
        check(isGoldish(rule), "the chosen row (Claude) carries the gold rule: \((0..<8).map { precise(room.left + CGFloat($0) * 0.5, room.top + 4 + rh * 1.5) }.map { String(format: "%.2f %.2f %.2f", $0.redComponent, $0.greenComponent, $0.blueComponent) })")
        check(!(0..<8).contains { isGoldish(precise(room.left + CGFloat($0) * 0.5, room.top + 4 + rh * 2.5)) }, "only the chosen row carries it")
        let under = (1...10).map { card(Int(room.left + cardWidth / 2), Int(room.top + cardHeight) + $0) }
        let deepest = under.map(\.alphaComponent).max() ?? 0
        check(deepest > 0.03 && deepest < 0.5 && under.allSatisfy { $0.redComponent < 0.2 }, "a soft shadow under the card: \(under.map(\.alphaComponent))")
        // A click on a row chooses it and closes the list.
        click(list, row(list, 2)); await settle(350)
        check(probe.panel == "codex", "a click on a panel row chooses it: \(probe.panel)")
        check(openList(window) == nil, "choosing closes the panel")
        // A disabled row is never chosen; keys reach the open list through the app: Down skips it, Return chooses.
        click(window, face); await settle(350)
        if let list = openList(window) { click(list, row(list, 3)); await settle(250) }
        check(probe.panel == "codex" && openList(window) != nil, "a disabled row is not chosen and the list stays: \(probe.panel)")
        appKey(.down); await settle(150)
        appKey(.return); await settle(350)
        check(probe.panel == "ollama" && openList(window) == nil, "Down skips the disabled row and Return chooses Ollama: \(probe.panel)")
        // A letter jumps; Space chooses.
        click(window, face); await settle(350)
        appKey(.letter("c")); await settle(150)
        appKey(.space); await settle(350)
        check(probe.panel == "" && openList(window) == nil, "c jumps to Choose provider and Space chooses it: \(probe.panel)")
        // A click on the face of an open list closes it, and that same click does not open it again.
        click(window, face); await settle(350)
        check(openList(window) != nil, "open before the face click")
        click(window, face); await settle(500)
        check(openList(window) == nil, "a click on the open face closes the list, and it stays closed")
        check(probe.panel == "", "the closing click chose nothing")
        // A slow click on the open face (held past the reopen delay) leaves it closed too: the delay runs from the
        // release, which is when the face's tap arrives.
        click(window, face); await settle(350)
        mouse(window, .leftMouseDown, face); await settle(600)
        mouse(window, .leftMouseUp, face); await settle(450)
        check(openList(window) == nil, "a slow click on the open face closes it, and it stays closed")
        // The next click opens it again.
        click(window, face); await settle(350)
        check(openList(window) != nil, "the next click on the face opens it")
        appKey(.escape); await settle(250)
        // Escape closes it. So does a click anywhere else, a scroll outside it, and a key that is not the list's (Tab).
        // Each is checked open first: a list that never opened would pass every one of these.
        click(window, face); await settle(350)
        check(openList(window) != nil, "open before Escape")
        appKey(.escape); await settle(250)
        check(openList(window) == nil && probe.panel == "", "Escape closes the panel without choosing")
        click(window, face); await settle(350)
        check(openList(window) != nil, "open before the outside click")
        click(window, point("switcher", dx: 300, dy: 8)); await settle(450)
        check(openList(window) == nil && probe.panel == "" && probe.view == "board", "a click outside closes the panel and chooses nothing")
        click(window, face); await settle(350)
        check(openList(window) != nil, "open before Tab")
        appKey(.tab); await settle(250)
        check(openList(window) == nil, "Tab closes the panel")
        // A key or a scroll closes it with no click to swallow: the face opens again at once.
        click(window, face); await settle(350)
        check(openList(window) != nil, "a click right after Tab opens it again")
        scrollElsewhere(); await settle(250)
        check(openList(window) == nil, "a scroll outside the list closes it")
        click(window, face); await settle(350)
        check(openList(window) != nil, "a click right after the scroll opens it again")
        if let list = openList(window) {
            // The pointer over a row takes the highlight (the panel tracks it itself: it is never key).
            pointer(list, row(list, 2)); await settle(150)
            appKey(.return); await settle(350)
            check(probe.panel == "codex", "the row under the pointer takes the highlight: \(probe.panel)")
        }

        // Past ten rows the list scrolls inside its card, and a key that moves the highlight brings that row into view.
        let longFace = point("long", dx: 200, dy: frame("long").height / 2)
        click(window, longFace); await settle(350)
        guard let longList = openList(window) else { fatalError("ControlsContract: the long list opened no panel") }
        let longHeight = longList.frame.height - room.top - room.bottom
        check(abs(longHeight - COSDropdownList<String>.scrollHeight) < 1.5, "twenty rows scroll inside a 300 pt card: \(longHeight)")
        check(washRows(longList) > 0, "the opening highlight (the selection) shows")
        for _ in 0..<16 { appKey(.down); await settle(60) }
        await settle(400)
        check(washRows(longList) > 0, "sixteen rows down, the highlight was scrolled into view")
        appKey(.return); await settle(350)
        check(probe.long == "n16" && openList(window) == nil, "Return chooses the row the keys reached: \(probe.long)")
        // Opened again, it opens scrolled to the selection.
        click(window, longFace); await settle(450)
        if let again = openList(window) { check(washRows(again) > 0, "it opens scrolled to its selection") }
        appKey(.escape); await settle(250)

        // View switch: a click on Focus makes it current.
        click(window, point("switcher", dx: frame("switcher").width - 20, dy: frame("switcher").height / 2)); await settle()
        check(probe.view == "focus", "a click on a word switches to it: \(probe.view)")

        // Switch: a click on the track flips it, twice; a click on its words does not, as with a stock macOS switch
        // (measured against the stock control in Tests/dropdown-canary); a disabled switch does not.
        let track = point("switch", dx: frame("switch").width - 15, dy: frame("switch").height / 2)
        click(window, track); await settle()
        check(probe.on, "a click turns the switch on")
        click(window, track); await settle()
        check(!probe.on, "a second click turns it off")
        click(window, point("switch", dx: 20, dy: frame("switch").height / 2)); await settle()
        check(!probe.on, "a click on a switch's words leaves it as it was")
        click(window, point("switchOff", dx: frame("switchOff").width - 15, dy: frame("switchOff").height / 2)); await settle()
        check(!probe.disabledOn, "a disabled switch does not flip")

        // Checkbox: a click on the square or its words flips it.
        click(window, point("check", dx: 7, dy: frame("check").height / 2)); await settle()
        check(probe.checked, "a click checks the box")
        click(window, point("check", dx: frame("check").width - 8, dy: frame("check").height / 2)); await settle()
        check(!probe.checked, "a click on its words unchecks it")

        // Chip: a click flips it, and again.
        let chip = point("chip", dx: frame("chip").width / 2, dy: frame("chip").height / 2)
        click(window, chip); await settle()
        check(probe.chip, "a click turns the chip on")
        let chipOn = pixels(window.contentView!)(Int(frame("chip").minX) + 3, Int(frame("chip").midY))
        check(isGoldish(chipOn), "a chip that is on fills gold: \(chipOn)")
        click(window, chip); await settle()
        check(!probe.chip, "a second click turns it off")

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

        // The root's theme reaches a DisclosureGroup that names no style: a click on its words expands it, and again
        // collapses it.
        check(probe.frames["inside"] == nil, "collapsed, its content is not there")
        click(window, point("disclosure", dx: 12, dy: 8)); await settle(400)
        check(probe.disclosed && probe.frames["inside"] != nil, "a click on the disclosure's words expands it")
        click(window, point("disclosure", dx: 12, dy: 8)); await settle(400)
        check(!probe.disclosed && probe.frames["inside"] == nil, "and again collapses it")

        // A Button that names no style is the quiet button: it acts on a click, and while it is pressed its hairline
        // is the accent ink, which in light mode is dark enough on a white card (3:1) where raw gold is not.
        let button = point("button", dx: frame("button").width / 2, dy: frame("button").height / 2)
        click(window, button); await settle()
        check(probe.pressed == 1, "the default button acts: \(probe.pressed)")
        mouse(window, .leftMouseDown, button); await settle(200)
        let pressedLine = exact(window.contentView!)(frame("button").midX, frame("button").minY + 0.25)
        mouse(window, .leftMouseUp, point("button", dx: -40, dy: 200)); await settle(150)
        check(probe.pressed == 1, "a press released elsewhere does not act")
        check(contrast(pressedLine, .white) >= 3, "a pressed (or hovered) quiet button's hairline is 3:1 on a white card: \(contrast(pressedLine, .white)) \(pressedLine)")
    }

    // MARK: - The keyboard, as with Keyboard navigation on

    @MainActor static func keyboard() async throws {
        let probe = Probe()
        let window = open(KeyboardBoard(probe: probe), height: KeyboardBoard.height)
        defer { window.orderOut(nil) }
        await settle(400)
        // The dropdown's face has the focus (the first control). A letter and Escape are not a closed face's keys.
        windowKey(window, .letter("c")); await settle(120)
        windowKey(window, .escape); await settle(120)
        check(openList(window) == nil, "a letter or Escape on a closed face opens nothing")
        // Space opens the list; keys then reach it through the app; Return chooses.
        windowKey(window, .space); await settle(350)
        check(openList(window) != nil, "Space on the focused face opens the list")
        appKey(.down); await settle(120)
        appKey(.return); await settle(350)
        check(probe.panel == "codex" && openList(window) == nil, "Down then Return: \(probe.panel)")
        // Return, and Down, open it too.
        windowKey(window, .return); await settle(350)
        check(openList(window) != nil, "Return on the focused face opens the list")
        appKey(.escape); await settle(250)
        windowKey(window, .down); await settle(350)
        check(openList(window) != nil, "Down on the focused face opens the list")
        appKey(.escape); await settle(250)
        check(openList(window) == nil && probe.panel == "codex", "Escape closes it and chooses nothing")

        // Tab reaches the view switch: Right and Left step one word and stop at the ends.
        windowKey(window, .tab); await settle(200)
        windowKey(window, .right); await settle(120)
        check(probe.view == "focus", "Right steps to the next word: \(probe.view)")
        windowKey(window, .right); await settle(120)
        windowKey(window, .right); await settle(120)
        check(probe.view == "list", "Right stops at the last word: \(probe.view)")
        windowKey(window, .left); await settle(120)
        check(probe.view == "focus", "Left steps back: \(probe.view)")
        check(probe.panel == "codex" && openList(window) == nil, "the arrows went to the view switch, not the dropdown")

        // Tab reaches the switch, the checkbox and the chip: Space flips each.
        windowKey(window, .tab); await settle(200)
        windowKey(window, .space); await settle(150)
        check(probe.on && !probe.checked && !probe.chip, "Space flips the focused switch")
        windowKey(window, .space); await settle(150)
        check(!probe.on, "and flips it back")
        windowKey(window, .tab); await settle(200)
        windowKey(window, .space); await settle(150)
        check(probe.checked && !probe.on && !probe.chip, "Space flips the focused checkbox")
        windowKey(window, .tab); await settle(200)
        windowKey(window, .space); await settle(150)
        check(probe.chip && probe.checked && !probe.on, "Space flips the focused chip")
    }

    // MARK: - The root theme

    /// `cosControlTheme()` on a window root gives every control that names no style the gotcos one. Each is drawn three
    /// ways: under the theme, with the style named outright, and stock. The first two must be the same picture, and
    /// not the third.
    @MainActor static func theme() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let word = appearance == .darkAqua ? "dark" : "light"
            let size = CGSize(width: 140, height: 40)
            func same(_ a: [UInt8], _ b: [UInt8]) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= 2 } }
            // A button that names no style is the quiet button.
            let themedButton = bytes(Button("Plain") {}.cosControlTheme(), size: size, appearance: appearance)
            let quietButton = bytes(Button("Plain") {}.buttonStyle(COSQuietButtonStyle()), size: size, appearance: appearance)
            let stockButton = bytes(Button("Plain") {}, size: size, appearance: appearance)
            check(same(themedButton, quietButton), "the theme's default button is the quiet button (\(word))")
            check(!same(themedButton, stockButton), "and not the stock push button (\(word))")
            // Determinate progress is the gold line.
            let themedBar = bytes(ProgressView(value: 0.4).frame(width: 120).cosControlTheme(), size: size, appearance: appearance)
            let lineBar = bytes(ProgressView(value: 0.4).frame(width: 120).progressViewStyle(COSProgressStyle()), size: size, appearance: appearance)
            let stockBar = bytes(ProgressView(value: 0.4).frame(width: 120), size: size, appearance: appearance)
            check(same(themedBar, lineBar), "the theme's progress bar is the gold line (\(word))")
            check(!same(themedBar, stockBar), "and not the stock bar (\(word))")
            // Disclosure is the words and a gold chevron.
            let themedGroup = bytes(DisclosureGroup("More") { Text("x") }.frame(width: 120).cosControlTheme(), size: size, appearance: appearance)
            let styledGroup = bytes(DisclosureGroup("More") { Text("x") }.frame(width: 120).disclosureGroupStyle(COSDisclosureStyle()), size: size, appearance: appearance)
            let stockGroup = bytes(DisclosureGroup("More") { Text("x") }.frame(width: 120), size: size, appearance: appearance)
            check(same(themedGroup, styledGroup), "the theme's disclosure is the gotcos one (\(word))")
            check(!same(themedGroup, stockGroup), "and not the stock triangle (\(word))")
            // The spinner turns, so two drawings differ: it is told by its ink. The themed one has accent pixels.
            let spinner = sample(ProgressView().controlSize(.regular).cosControlTheme(), size: CGSize(width: 32, height: 32), appearance: appearance)
            let accent = resolved(NSColor(COSPalette.accent), appearance)
            var accentPixels = 0
            for y in 0..<32 { for x in 0..<32 where near(spinner(x, y), accent, 0.08) { accentPixels += 1 } }
            check(accentPixels >= 8, "the theme's spinner is the accent arc (\(word)): \(accentPixels)")
            // Tint is gold: the two controls that stay native (Slider, DatePicker) take it in a key window. A drawing
            // off screen is an inactive window's, which macOS draws without any tint, so the tint is read where SwiftUI
            // resolves it: a shape filled with `.tint`.
            let tinted = sample(Rectangle().fill(.tint).frame(width: 20, height: 20).cosControlTheme(), size: CGSize(width: 20, height: 20), appearance: appearance)
            let untinted = sample(Rectangle().fill(.tint).frame(width: 20, height: 20), size: CGSize(width: 20, height: 20), appearance: appearance)
            check(isGold(tinted(10, 10)), "the theme's tint is gold (\(word)): \(tinted(10, 10))")
            check(!isGold(untinted(10, 10)), "and the system's is not (\(word))")
        }
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
        // Light mode: ink and lines that signal (a hovered button, the spinner, a featured button) use the accent token.
        // On a white card the accent is over 3:1; raw gold is not, which is why it is not used for them.
        let accentLight = resolved(NSColor(COSPalette.accent), .aqua), gold = NSColor(red: 0.79, green: 0.66, blue: 0.43, alpha: 1)
        check(contrast(accentLight, .white) >= 3, "the accent is 3:1 on white in light: \(contrast(accentLight, .white))")
        check(contrast(gold, .white) < 3, "raw gold is not: \(contrast(gold, .white))")
        let spinner = sample(COSSpinner(size: 32), size: CGSize(width: 32, height: 32), appearance: .aqua)
        var darkest = NSColor.white
        for y in 0..<32 { for x in 0..<32 where spinner(x, y).alphaComponent > 0.95 && contrast(spinner(x, y), .white) > contrast(darkest, .white) { darkest = spinner(x, y) } }
        check(contrast(darkest, .white) >= 3, "the spinner's arc is 3:1 on a white card in light: \(contrast(darkest, .white))")
        let featured = sample(Button("Featured") {}.buttonStyle(COSQuietButtonStyle(tone: .featured)), size: CGSize(width: 90, height: 28), appearance: .aqua)
        var ink = NSColor.white
        for y in 0..<28 { for x in 0..<90 where featured(x, y).alphaComponent > 0.95 && contrast(featured(x, y), .white) > contrast(ink, .white) { ink = featured(x, y) } }
        check(contrast(ink, .white) >= 3, "a featured button's ink is 3:1 on a white card in light: \(contrast(ink, .white))")
    }

    // MARK: - Helpers

    private enum Key: Equatable { case up, down, left, right, `return`, escape, space, tab, letter(Character) }

    @MainActor private static func event(_ key: Key, _ type: NSEvent.EventType, window: NSWindow?) -> NSEvent? {
        let (code, characters): (UInt16, String) = switch key {
        case .up: (126, "\u{F700}")
        case .down: (125, "\u{F701}")
        case .left: (123, "\u{F702}")
        case .right: (124, "\u{F703}")
        case .return: (36, "\r")
        case .escape: (53, "\u{1B}")
        case .space: (49, " ")
        case .tab: (48, "\t")
        case .letter(let letter): (8, String(letter))
        }
        let arrows: [Key] = [.up, .down, .left, .right]
        return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: arrows.contains(key) ? [.numericPad, .function] : [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0, context: nil,
                                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    /// A key through the app, as every key arrives: local event monitors see it first (an open dropdown's list takes
    /// its keys this way). With no key window the app delivers it nowhere else, so a swallowed key is all it can be.
    @MainActor private static func appKey(_ key: Key) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = event(key, type, window: nil) { NSApp.sendEvent(event) }
        }
    }

    /// A key to the window's focused control, where the app would deliver it if this window were key.
    @MainActor private static func windowKey(_ window: NSWindow, _ key: Key) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = event(key, type, window: window) { window.sendEvent(event) }
        }
    }

    @MainActor private static func mouse(_ window: NSWindow, _ type: NSEvent.EventType, _ point: NSPoint) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseDown ? 1 : 0) else { return }
        NSApp.sendEvent(event)
    }

    /// A click through the app: local event monitors see it, then its window takes it.
    @MainActor private static func click(_ window: NSWindow, _ point: NSPoint) {
        mouse(window, .leftMouseDown, point)
        mouse(window, .leftMouseUp, point)
    }

    /// The pointer moving over a window (the panel's own tracking area hears it as mouse-moved).
    @MainActor private static func pointer(_ window: NSWindow, _ point: NSPoint) {
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return }
        window.contentView?.mouseMoved(with: event)
    }

    /// A scroll-wheel event that belongs to no window of the list's: what the dropdown sees for a scroll anywhere
    /// that is not its own list. The CGEvent only carries the shape AppKit needs; it is never posted to the system.
    @MainActor private static func scrollElsewhere() {
        guard let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -10, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: wheel) else { fatalError("no scroll event") }
        NSApp.sendEvent(event)
    }

    @MainActor private static func settle(_ milliseconds: Int = 250) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    /// AppKit's own drawing of `view`, read by point from the top left.
    @MainActor private static func pixels(_ view: NSView) -> (Int, Int) -> NSColor {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("no bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return { x, y in
            rep.colorAt(x: Int(CGFloat(x) * scale + scale / 2), y: Int(CGFloat(y) * scale + scale / 2))?.usingColorSpace(.sRGB) ?? .clear
        }
    }

    /// The same drawing, read at a point given to a quarter point (a hairline is half a point wide on each side).
    @MainActor private static func exact(_ view: NSView) -> (CGFloat, CGFloat) -> NSColor {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("no bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return { x, y in rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) ?? .clear }
    }

    /// How many points down the middle-right of an open list's card carry the highlight's gold wash (light mode: the
    /// card is white, the wash a warm near-white). Zero when the highlighted row is scrolled out of sight.
    @MainActor private static func washRows(_ list: NSWindow) -> Int {
        guard let view = list.contentView else { return 0 }
        let room = COSDropdownPresenter.shadowRoom
        let read = pixels(view)
        let x = Int(list.frame.width - room.right) - 24
        var count = 0
        for y in (Int(room.top) + 2)..<(Int(list.frame.height - room.bottom) - 2) {
            let c = read(x, y)
            if c.alphaComponent > 0.98, c.redComponent > 0.95, c.blueComponent < 0.975, c.blueComponent > 0.9 { count += 1 }
        }
        return count
    }

    @MainActor private static func host<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name) -> (NSView, NSBitmapImageRep) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        return (host, rep)
    }

    /// Renders `view` at 2x and returns a reader of point (x, y) from the top left.
    @MainActor private static func sample<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name) -> (Int, Int) -> NSColor {
        let (_, rep) = host(view, size: size, appearance: appearance)
        let scale = CGFloat(rep.pixelsWide) / size.width
        return { x, y in
            let color = rep.colorAt(x: Int(CGFloat(x) * scale + scale / 2), y: Int(CGFloat(y) * scale + scale / 2))
            return color?.usingColorSpace(.sRGB) ?? .clear
        }
    }

    /// Every byte of `view`'s drawing, to compare two drawings.
    @MainActor private static func bytes<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name) -> [UInt8] {
        let (_, rep) = host(view, size: size, appearance: appearance)
        guard let data = rep.bitmapData else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: rep.bytesPerRow * rep.pixelsHigh))
    }

    @MainActor private static func resolved(_ color: NSColor, _ appearance: NSAppearance.Name) -> NSColor {
        var out = NSColor.clear
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance { out = color.usingColorSpace(.sRGB) ?? .clear }
        return out
    }

    private static func near(_ a: NSColor, _ b: NSColor, _ tolerance: CGFloat) -> Bool {
        a.alphaComponent > 0.9 && abs(a.redComponent - b.redComponent) < tolerance && abs(a.greenComponent - b.greenComponent) < tolerance
            && abs(a.blueComponent - b.blueComponent) < tolerance
    }

    /// WCAG relative luminance and contrast, in sRGB.
    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }
    private static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// COSPalette.gold is (0.79, 0.66, 0.43).
    private static func isGold(_ c: NSColor) -> Bool {
        c.alphaComponent > 0.9 && abs(c.redComponent - 0.79) < 0.06 && abs(c.greenComponent - 0.66) < 0.06 && abs(c.blueComponent - 0.43) < 0.06
    }

    /// Gold as a window draws it: a window's backing store is color-managed, so the token reads a few hundredths off
    /// (measured 0.81, 0.72, 0.53 for the list's rule); still far from the card, the wash and the hairline.
    private static func isGoldish(_ c: NSColor) -> Bool {
        c.alphaComponent > 0.9 && abs(c.redComponent - 0.79) < 0.08 && abs(c.greenComponent - 0.66) < 0.08 && abs(c.blueComponent - 0.43) < 0.12
    }

    /// COSPalette.ink is (0.12, 0.09, 0.07).
    private static func isInk(_ c: NSColor) -> Bool {
        c.alphaComponent > 0.9 && c.redComponent < 0.2 && c.greenComponent < 0.16 && c.blueComponent < 0.14
    }
}
