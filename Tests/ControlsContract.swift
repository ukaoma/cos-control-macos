import AppKit
import SwiftUI

// 0.5.251 to 0.5.253 GOTCOS controls, checked without driving any UI. Miles, 2026-09-30 19:06: "We don't want the
// testing 'computer use' where we jump and click. It doesn't work and it now causes random missed clicked error sound."
// From 0.5.253 this contract sends no click, key, scroll or pointer event (not even into its own process), orders no
// window in (not even off screen), activates nothing and plays nothing:
//   - behaviour is checked by calling the rules the controls run on (COSDropdownRules: keys, highlight, choice, widths,
//     placement, reopening, and an open list that follows its options; COSViewSwitch.step; COSStepper.stepped);
//   - looks are checked on static bitmaps of views that are never put on screen (an NSHostingView drawn with
//     cacheDisplay, in a window that is never ordered in): the switch, checkbox, spinner, theme, the open list's card,
//     icon labels and the menu-bar panel itself (Tests/PanelLabelsRender.swift).
// What it cannot check, and is pinned in Tests/run.sh by source instead: the open list's child panel, its event monitor
// and its dismissals; focus with Keyboard navigation on; where a tap lands on a switch.
//
// Run: Tests/run-controls.sh (called by Tests/run.sh).

@MainActor private final class Probe: ObservableObject {
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

/// 0.5.253: labels with an icon, under every COS style and the window root's theme, on one line and wrapped to two.
/// Each title and icon reports its own frame, so the check reads where the style put them.
private struct LabelBoard: View {
    @ObservedObject var probe: Probe
    /// The width that wraps "Check for updates" to two lines in each button style (the words get 58 to 70 pt).
    static let narrow: CGFloat = 110
    enum Kind: String, CaseIterable { case quiet, primary, text, themed, plain, bare, menu, system }

    private func label(_ key: String) -> some View {
        Label {
            Text("Check for updates").modifier(Frame(key: key + ".title", probe: probe))
        } icon: {
            Image(systemName: "arrow.triangle.2.circlepath").modifier(Frame(key: key + ".icon", probe: probe))
        }
    }
    @ViewBuilder private func item(_ kind: Kind, _ key: String) -> some View {
        switch kind {
        case .quiet: Button {} label: { label(key) }.buttonStyle(COSQuietButtonStyle())
        case .primary: Button {} label: { label(key) }.buttonStyle(COSPrimaryButtonStyle())
        case .text: Button {} label: { label(key) }.buttonStyle(COSTextButtonStyle())
        // No style of its own: the window root's theme gives it the quiet button, and its label the COS style.
        case .themed: Button {} label: { label(key) }
        case .plain: Button {} label: { label(key) }.buttonStyle(.plain)
        case .bare: label(key)
        case .menu: Menu { Button("Now") {} } label: { label(key) }.cosMenu()
        // The system's own label style inside the quiet button: the reference for widths and wrapping.
        case .system: Button {} label: { label(key).labelStyle(.titleAndIcon) }.buttonStyle(COSQuietButtonStyle())
        }
    }
    /// The button styles (and the menu face, a quiet button) with no window root theme above them: each must center its
    /// label itself (a window without the theme, a panel of its own). The rest under the root theme, which is what gives
    /// a plain button, a bare Label and a button with no style of its own theirs.
    static let ownStyle: [Kind] = [.quiet, .primary, .text, .menu, .system]
    private func row(_ kind: Kind) -> some View {
        HStack(alignment: .top, spacing: 12) {
            item(kind, kind.rawValue + ".one").fixedSize().modifier(Frame(key: kind.rawValue + ".one", probe: probe))
            item(kind, kind.rawValue + ".two").frame(width: Self.narrow, alignment: .leading)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Self.ownStyle, id: \.self) { kind in row(kind) }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Kind.allCases.filter { !Self.ownStyle.contains($0) }, id: \.self) { kind in row(kind) }
            }
            .cosControlTheme()
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 360, height: Self.height, alignment: .top)
        .background(COSPalette.card)
    }
    static let height: CGFloat = 640
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
        optionsChange()
        theme()
        renders()
        lists()
        await labels()
        panel()
        check(!activated && !app.isActive, "the contract never became the active app (a shared desktop is left alone)")
        check(NSApp.windows.allSatisfy { !$0.isVisible }, "no window was ever put on screen")
        print("PASS: GOTCOS controls, no UI driven (dropdown rules: keys, highlight, choice, list width and placement, reopening; an open list follows changed options; view switch and stepper rules; root theme: button, progress, disclosure, tint; light-mode contrast; switch, checkbox and spinner pixels; the open list's card; labels: icon in the middle of one and two lines under every style, the system's gap and wrapping; the menu-bar panel's Create Folders, rendered)")
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


    /// 0.5.253 (QA, deferred from 0.5.252): an open list whose options change shows the new ones, and its keys choose
    /// from them. The dropdown re-opens its list on the options it has now when their signature changes; these are the
    /// rules it runs on (the wiring is pinned in Tests/run.sh).
    @MainActor static func optionsChange() {
        typealias R = COSDropdownRules
        let two = [COSDropdownOption("claude", "Claude"), COSDropdownOption("gemini", "Gemini")]
        check(R.signature(providers) == R.signature(providers), "the same options read the same")
        check(R.signature(providers) != R.signature(two), "new options read as a change")
        var renamed = providers; renamed[2] = COSDropdownOption("codex", "Codex CLI")
        var disabled = providers; disabled[2] = COSDropdownOption("codex", "Codex", enabled: false)
        var noted = providers; noted[2] = COSDropdownOption("codex", "Codex", note: "not pulled")
        var muted = providers; muted[2] = COSDropdownOption("codex", "Codex", muted: true)
        for (name, changed) in [("a title", renamed), ("enabled", disabled), ("a note", noted), ("muted", muted)] {
            check(R.signature(providers) != R.signature(changed), "\(name) changing reads as a change")
        }
        // Re-opened on the new options, the list highlights the selection there, and the keys move through those rows.
        check(R.openingHighlight(two, selection: "claude") == 0, "the selection's row in the new options")
        check(R.handle(.down, isOpen: true, highlight: 0, options: two, selection: "claude", enabled: true) == .highlight(1), "Down moves within the new rows")
        check(R.handle(.confirm, isOpen: true, highlight: 1, options: two, selection: "claude", enabled: true) == .choose("gemini"), "Return chooses from them")
        check(R.handle(.down, isOpen: true, highlight: 1, options: two, selection: "claude", enabled: true) == .highlight(1), "and stops at their end")
    }

    /// The open list's card, drawn on its own (never on screen): the chosen row carries the gold rule on its leading
    /// edge, the highlighted row the gold wash, and no other row either.
    @MainActor static func lists() {
        let rows = providers.count
        let size = CGSize(width: 240, height: CGFloat(rows) * 40 + 40)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let word = appearance == .darkAqua ? "dark" : "light"
            let draw = sample(COSDropdownList(options: providers, selection: "codex", highlight: .constant(4), framed: false) { _ in }.frame(width: 240),
                              size: size, appearance: appearance)
            // Rows start 4 pt down; find each row's band by the rule's gold at x = 1.
            var goldRows = Set<Int>()
            for y in 0..<Int(size.height) where isGold(draw(0, y)) || isGold(draw(1, y)) { goldRows.insert(y) }
            check(!goldRows.isEmpty, "the chosen row has its gold rule (\(word))")
            let band = (goldRows.min()!, goldRows.max()!)
            check(band.1 - band.0 <= 18, "one row's rule, not more (\(word)): \(band)")
            // The rule sits on the third row (Codex): below the first two rows' height.
            check(band.0 > 50 && band.0 < 110, "on the chosen row (\(word)): \(band)")
        }
    }

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

    // MARK: - Labels (0.5.253)

    /// Miles, 2026-09-30 16:51: a wrapped label showed its icon by its first line. Under every COS button style, the
    /// menu face, a plain button and a bare Label under the root theme, the icon's middle is the words' middle (within
    /// 1 pt) on one line and on two, the gap is the system's 8 pt, and a label is as wide, and wraps where, the system's
    /// own style would have it.
    @MainActor static func labels() async {
        let probe = Probe()
        let window = unordered(LabelBoard(probe: probe), height: LabelBoard.height)
        defer { window.close() }
        await settle(400)
        func frame(_ key: String) -> CGRect {
            guard let frame = probe.frames[key] else { fatalError("ControlsContract: no frame for \(key)") }
            return frame
        }
        let oneLine = frame("system.one.title").height
        for kind in LabelBoard.Kind.allCases where kind != .system {
            for lines in ["one", "two"] {
                let key = kind.rawValue + "." + lines
                let icon = frame(key + ".icon"), title = frame(key + ".title")
                check(abs(icon.midY - title.midY) <= 1, "\(key): the icon's middle \(icon.midY) is the words' middle \(title.midY)")
                check(abs((title.minX - icon.maxX) - COSLabelStyle.spacing) <= 0.5, "\(key): the system's 8 pt gap, not \(title.minX - icon.maxX)")
                if lines == "two" { check(title.height >= 1.8 * oneLine, "\(key): the narrow label wraps to two lines (\(title.height) vs \(oneLine))") }
                else { check(abs(title.height - oneLine) <= 0.5, "\(key): one line (\(title.height))") }
            }
        }
        // Widths stay: the quiet button is as wide on one line, and its words wrap to the same height, as with the
        // system's own style; and that style still puts the icon by the first line (so this board can see the fault).
        check(abs(frame("quiet.one").width - frame("system.one").width) <= 0.5, "a label is as wide as the system's: \(frame("quiet.one").width) vs \(frame("system.one").width)")
        check(abs(frame("quiet.two.title").width - frame("system.two.title").width) <= 0.5 && abs(frame("quiet.two.title").height - frame("system.two.title").height) <= 0.5,
              "a narrow label wraps as the system's does")
        let systemTwo = (icon: frame("system.two.icon"), title: frame("system.two.title"))
        check(systemTwo.title.midY - systemTwo.icon.midY > 4, "the system style still tops the icon of two lines (the fault this pins): \(systemTwo.icon.midY) vs \(systemTwo.title.midY)")
    }

    /// The real menu-bar panel, off screen, light and dark: Create Folders (the buttons grid) wraps to two lines there
    /// (Check for updates did too, until its card went, 2026-10-09), and each icon is within 1 pt of its text block's middle; so are the
    /// one-line Work Folder and Run Doctor. COS_PANEL_RENDER_OUT names a folder for its PNGs.
    @MainActor static func panel() {
        let output = ProcessInfo.processInfo.environment["COS_PANEL_RENDER_OUT"].map { URL(fileURLWithPath: $0) }
        let measures = PanelLabels.run(output: output, label: "after")
        for measure in measures {
            print("  panel: \(measure)")
            check(measure.offBy <= 1, "the panel's \(measure)")
        }
        for name in ["Create Folders"] {
            check(measures.contains { $0.name == name && $0.lines == 2 }, "\(name) wraps to two lines in the panel render, so it measures the case Miles saw")
        }
        check(measures.contains { $0.lines == 1 }, "the panel render measures a one-line label too")
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

    /// A window holding `view` that is never ordered in: SwiftUI lays it out and draws it, and nothing reaches the
    /// screen. (0.5.253: no test orders a window in, even far off screen.)
    @MainActor private static func unordered<V: View>(_ view: V, height: CGFloat, appearance: NSAppearance.Name = .aqua) -> NSWindow {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 360, height: height)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 360, height: height), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return window
    }

    // MARK: - Helpers

    @MainActor private static func settle(_ milliseconds: Int = 250) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
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
