import AppKit
import SwiftUI

// Does a COSDropdown's open list, a borderless child panel under the face, work inside a real MenuBarExtra(.window)
// and inside a normal window? Run: Tests/dropdown-canary/run.sh [log] [frames-dir]
// The app drives itself with NSEvents posted to its own queue (so the dropdown's local event monitor runs, as it does
// for a person's click; nothing is posted to the system and the pointer never moves), logs what each surface did, and
// exits 0 only if every check held. It compiles the SHIPPED Sources/COSBrand.swift.
//
// Two modes (2026-09-30: Miles saw phantom clicks on his Mac while gates ran, so nothing here may touch a shared
// desktop by default):
//   off screen (the default): activation policy .prohibited (it can never become the active app), no status item, only
//     borderless windows 8,000 points off every screen. Runs F and S. Safe while someone uses the Mac.
//   desktop (COS_DESKTOP_CANARY=1, never set by any gate): adds a status item, opens its panel, opens a window on
//     screen and takes the keyboard focus for about 30 seconds. Runs M, I, C and W as well. Only with the Mac's owner
//     at the keyboard and expecting it.
//
//   F  frames: real frames of the open list (the shipped child panel, drawn by AppKit), dark and light, into frames-dir
//   S  calibration: what a click on a stock macOS switch's and checkbox's words does, against COSSwitchStyle and
//      COSCheckStyle beside them (a stock control's own click handling needs a running app, so it is measured here)
//   M  the child panel inside MenuBarExtra(.window): the surface that closes when it stops being key
//   W  the child panel inside a normal titled window, with a long list (keys scroll the highlight into view)
//   I  the inline list (`cosDropdownInline`), the fallback for a surface where a panel cannot show
//   C  calibration: .confirmationDialog's destructive button, proven dead in the menu-bar panel on-device 2026-08-23.
//      If C ever starts working here, this canary no longer reproduces the surface and its M result means nothing.
//
// Results 2026-09-30 (0.5.252 build 291, macOS 26.6.2). Off screen, 13:32: F saved 8 frames; S: a click on a stock
// switch's words leaves it as it was and a stock checkbox flips from its words, and the gotcos ones do the same;
// never active, no status item, nothing on screen. Desktop, 11:38 to 11:44, on the tree before two refinements (the
// shadow's room; a key or scroll no longer delaying the next click): M, I and W passed every check across runs (a
// person using the Mac closed the panel in some runs, which the focus log shows), and C held. Not run again since, to
// leave Miles's Mac alone.

let logURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/dropdown-canary.log")
let framesDir: URL? = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true) : nil
/// The desktop mode: only when the environment asks for it, outright.
let desktop = ProcessInfo.processInfo.environment["COS_DESKTOP_CANARY"] == "1"
nonisolated(unsafe) var logLines: [String] = []
func log(_ line: String) {
    let row = String(format: "%.2f  ", ProcessInfo.processInfo.systemUptime) + line
    print(row); logLines.append(row)
    try? logLines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
}

@MainActor final class Probe: ObservableObject {
    static let shared = Probe()
    @Published var menuChoice = "claude"
    @Published var inlineChoice = "claude"
    @Published var windowChoice = "claude"
    @Published var modelChoice = "m03"
    @Published var confirmShown = false
    @Published var stockSwitch = false
    @Published var cosSwitch = false
    @Published var stockBox = false
    @Published var cosBox = false
    var releaseRan = false
    var frames: [String: CGRect] = [:]
}

struct FrameReporter: ViewModifier {
    let key: String
    func body(content: Content) -> some View {
        content.background(GeometryReader { proxy in
            Color.clear.onAppear { Probe.shared.frames[key] = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, f in Probe.shared.frames[key] = f }
        })
    }
}

let providerOptions: [COSDropdownOption<String>] = [
    .init("", "Choose provider", placeholder: true), .init("claude", "Claude"), .init("codex", "Codex"),
    .init("cursor", "Cursor"), .init("ollama", "Ollama", note: "unavailable", muted: true),
]

/// Twelve models: more than ten rows, so the list scrolls; two long names that differ only at the tail.
let modelOptions: [COSDropdownOption<String>] = [
    .init("m00", "Opus 5.5"), .init("m01", "Opus 5.5 (1M context)"), .init("m02", "Sonnet 5.5"), .init("m03", "Haiku 5"),
    .init("m04", "GPT-6.1 Codex"), .init("m05", "GPT-6.1 Codex Max"), .init("m06", "GPT-6.1 Codex Mini"),
    .init("m07", "Grok 4.7 High Fast"),
    .init("m08", "claude-opus-5-5-20260915-extended-thinking-preview-a"),
    .init("m09", "claude-opus-5-5-20260915-extended-thinking-preview-b"),
    .init("m10", "Gemini 4 Pro", note: "unavailable", muted: true), .init("m11", "Local: qwen3-coder 32b"),
]

struct MenuPanel: View {
    @ObservedObject var probe = Probe.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dropdown canary").font(.headline).modifier(FrameReporter(key: "title"))
            COSDropdown("Panel", selection: $probe.menuChoice, options: providerOptions, labelWidth: 60)
                .modifier(FrameReporter(key: "M"))
            COSDropdown("Inline", selection: $probe.inlineChoice, options: providerOptions, labelWidth: 60)
                .environment(\.cosDropdownInline, true)
                .modifier(FrameReporter(key: "I"))
            Button("Confirm variant") { probe.confirmShown = true }.modifier(FrameReporter(key: "C"))
            Text("M=\(probe.menuChoice) I=\(probe.inlineChoice)").font(.caption)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 390, height: 420, alignment: .top)
        .confirmationDialog("Release?", isPresented: $probe.confirmShown, titleVisibility: .visible) {
            Button("Release", role: .destructive) { Probe.shared.releaseRan = true; log("C  Release ACTION RAN") }
            Button("Cancel", role: .cancel) { log("C  cancel ran") }
        }
    }
}

/// The normal window: the Agent workspace's two dropdowns as they sit in a card.
struct WindowPane: View {
    @ObservedObject var probe = Probe.shared
    static let size = CGSize(width: 420, height: 470)
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agent workspace").font(COSType.display(17, weight: .medium)).modifier(FrameReporter(key: "wtitle"))
            VStack(alignment: .leading, spacing: 10) {
                COSDropdown("Provider", selection: $probe.windowChoice, options: providerOptions, labelWidth: 60)
                    .modifier(FrameReporter(key: "W"))
                COSDropdown("Model", selection: $probe.modelChoice, options: modelOptions, labelWidth: 60)
                    .frame(width: 270, alignment: .leading)
                    .modifier(FrameReporter(key: "L"))
            }
            .padding(14)
            .background(COSPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line, lineWidth: 1))
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
        .background(COSPalette.panel)
    }
}

/// Stock and gotcos side by side, for the S calibration.
struct CalibrationPane: View {
    @ObservedObject var probe = Probe.shared
    static let size = CGSize(width: 320, height: 160)
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Stock switch words", isOn: $probe.stockSwitch).toggleStyle(.switch).fixedSize().modifier(FrameReporter(key: "stockSwitch"))
            Toggle("COS switch words", isOn: $probe.cosSwitch).toggleStyle(COSSwitchStyle()).frame(width: 220).modifier(FrameReporter(key: "cosSwitch"))
            Toggle("Stock checkbox words", isOn: $probe.stockBox).toggleStyle(.checkbox).fixedSize().modifier(FrameReporter(key: "stockBox"))
            Toggle("COS checkbox words", isOn: $probe.cosBox).toggleStyle(COSCheckStyle()).fixedSize().modifier(FrameReporter(key: "cosBox"))
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(COSPalette.panel)
    }
}

/// One of two apps, chosen before anything is shown: off screen by default, the desktop only when asked for.
@main enum CanaryMain {
    @MainActor static func main() {
        if desktop { DesktopCanary.main() } else { OffscreenCanary.main() }
    }
}

/// Off screen: no MenuBarExtra at all (one that is not inserted still made a status bar window), only a Settings scene
/// that is never opened, and an app that can never become active.
struct OffscreenCanary: App {
    init() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { Task { @MainActor in await Driver.run() } }
    }
    var body: some Scene { Settings { EmptyView() } }
}

/// The desktop mode: a real MenuBarExtra(.window), with its status item.
struct DesktopCanary: App {
    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { Task { @MainActor in await Driver.run() } }
    }
    var body: some Scene {
        MenuBarExtra("Canary", systemImage: "testtube.2") { MenuPanel() }.menuBarExtraStyle(.window)
    }
}

@MainActor enum Driver {
    static var failures = 0
    /// The face sits after the 60 pt label and a 10 pt gap.
    static let faceX: CGFloat = 130
    /// Inside the list's panel: the card starts `shadowRoom.top` down; rows are 28 pt after a 4 pt inset.
    static let rowHeight: CGFloat = 28

    static func expect(_ ok: Bool, _ what: String) {
        log((ok ? "ok    " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }
    static func pause(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
    static func name(_ window: NSWindow) -> String { String(describing: type(of: window)) }
    static func windows() -> String {
        NSApp.windows.filter(\.isVisible).map { "\(name($0))[key=\($0.isKeyWindow) lvl=\($0.level.rawValue)]" }.joined(separator: " ")
    }
    static var menuPanel: NSWindow? {
        NSApp.windows.first { $0.isVisible && !name($0).contains("StatusBar") && !name($0).contains("Popover")
            && $0.parent == nil && $0.frame.width > 300 && $0 !== normalWindow }
    }
    static var normalWindow: NSWindow?
    /// The dropdown's open list: a visible borderless child panel of `parent`.
    static func list(of parent: NSWindow) -> NSWindow? {
        parent.childWindows?.first { $0.isVisible && $0 is NSPanel && $0.styleMask.contains(.nonactivatingPanel) && !name($0).contains("Popover") }
    }
    static func popovers() -> Int { NSApp.windows.filter { $0.isVisible && name($0).contains("Popover") }.count }
    static func statusButton() -> NSStatusBarButton? {
        @MainActor func find(_ view: NSView?) -> NSStatusBarButton? {
            guard let view else { return nil }
            if let b = view as? NSStatusBarButton { return b }
            for s in view.subviews { if let b = find(s) { return b } }
            return nil
        }
        for w in NSApp.windows { if let b = find(w.contentView) { return b } }
        return nil
    }
    static func click(_ window: NSWindow, _ p: NSPoint) {
        let t = ProcessInfo.processInfo.systemUptime
        for (type, dt) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.05)] {
            let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: t + dt, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(e, atStart: false)
        }
    }
    static func key(_ window: NSWindow, _ code: UInt16, _ chars: String) {
        let t = ProcessInfo.processInfo.systemUptime
        let flags: NSEvent.ModifierFlags = code == 125 || code == 126 ? [.numericPad, .function] : []
        for type in [NSEvent.EventType.keyDown, NSEvent.EventType.keyUp] {
            let event: NSEvent? = NSEvent.keyEvent(with: type, location: NSPoint.zero, modifierFlags: flags, timestamp: t,
                                                   windowNumber: window.windowNumber, context: nil, characters: chars,
                                                   charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            if let event { NSApp.postEvent(event, atStart: false) }
        }
    }
    /// A global SwiftUI frame (top-left origin in the window's content) to a window point (bottom-left origin).
    static func point(_ window: NSWindow, _ frame: CGRect, dx: CGFloat, dy: CGFloat? = nil) -> NSPoint {
        // SwiftUI's global space starts at the window's top left, title bar included.
        let h = window.frame.height
        return NSPoint(x: frame.minX + dx, y: h - (frame.minY + (dy ?? frame.height / 2)))
    }
    /// The middle of row `index` of an open list, in the list panel's coordinates.
    static func row(_ list: NSWindow, _ index: Int) -> NSPoint {
        let room = COSDropdownPresenter.shadowRoom
        return NSPoint(x: list.frame.width / 2, y: list.frame.height - (room.top + 4 + rowHeight * CGFloat(index) + rowHeight / 2))
    }

    static func run() async {
        log("start: \(windows())")
        // Who took the focus, and when: a list closes when its app or its window stops being active, so a person
        // using the Mac during the run shows up here rather than as a mystery failure.
        for name in [NSApplication.didResignActiveNotification, NSApplication.didBecomeActiveNotification,
                     NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let who = (note.object as? NSWindow).map { String(describing: type(of: $0)) } ?? "app"
                log("      [\(name.rawValue.replacingOccurrences(of: "Notification", with: "")) \(who)]")
            }
        }
        // SwiftUI's launch may set the policy again; off screen it is .prohibited from here on, whatever it set.
        if !desktop { NSApp.setActivationPolicy(.prohibited) }
        log(desktop ? "mode: desktop (a status item, a window on screen, the keyboard focus)" : "mode: off screen (never active, no status item, nothing on screen)")
        if let framesDir { await frames(into: framesDir) }
        await calibration()
        if desktop {
            await menuBar()
            await window()
        } else {
            let onScreen = NSApp.windows.filter { window in window.isVisible && NSScreen.screens.contains { $0.frame.intersects(window.frame) } }
            expect(NSApp.activationPolicy() == .prohibited && !NSApp.isActive, "off screen: the app is .prohibited and never became active")
            expect(statusButton() == nil, "off screen: no status item")
            expect(onScreen.isEmpty, "off screen: no window on any screen: \(onScreen.map { "\(type(of: $0)) \($0.frame)" })")
        }
        log(failures == 0 ? "RESULT: PASS" : "RESULT: FAIL (\(failures) checks)")
        exit(failures == 0 ? 0 : 1)
    }

    /// The same checks on either surface: `parent` holds a dropdown whose frame is `frameKey`.
    static func exercise(_ tag: String, parent: NSWindow, frameKey: String, choice: @MainActor () -> String, outside: NSPoint) async {
        guard let frame = Probe.shared.frames[frameKey] else { expect(false, "\(tag)  no frame for the dropdown"); return }
        let face = point(parent, frame, dx: faceX)
        let faceWidth = frame.width - 70

        // A click on the face opens the list as a child panel: no popover, and the parent stays up and key.
        click(parent, face); await pause(0.4)
        var open = list(of: parent)
        expect(open != nil, "\(tag)  a click on the face opens the list as a child panel: \(windows())")
        expect(popovers() == 0, "\(tag)  no popover window (no arrow, no system chrome)")
        expect(parent.isVisible, "\(tag)  the parent stays open")
        if let open {
            let room = COSDropdownPresenter.shadowRoom
            let cardWidth = open.frame.width - room.left - room.right
            expect(abs(cardWidth - faceWidth) < 1.5, "\(tag)  the card is as wide as the face: card \(cardWidth), face \(faceWidth)")
            let faceOnScreen = parent.convertPoint(toScreen: NSPoint(x: frame.minX + 70, y: face.y - frame.height / 2))
            expect(abs((open.frame.minX + room.left) - faceOnScreen.x) < 1.5, "\(tag)  the card's leading edge sits under the face's")
            expect(abs((open.frame.maxY - room.top) - (faceOnScreen.y - 4)) < 1.5, "\(tag)  the card sits 4 pt under the face")
            expect(!open.isKeyWindow && !open.canBecomeKey, "\(tag)  the list never takes the keyboard from its parent")
            // A click on a row chooses it and closes the list.
            click(open, row(open, 2)); await pause(0.4)
        }
        expect(choice() == "codex", "\(tag)  a click on a row chooses it: \(choice())")
        expect(list(of: parent) == nil, "\(tag)  choosing closes the list")
        expect(parent.isVisible, "\(tag)  the parent is still open after a choice")

        // Keys reach the open list through the parent: Down, then Return.
        click(parent, face); await pause(0.4)
        expect(list(of: parent) != nil, "\(tag)  it opens again")
        key(parent, 125, "\u{F701}"); await pause(0.3)
        key(parent, 36, "\r"); await pause(0.4)
        expect(choice() == "cursor", "\(tag)  Down then Return chooses the next row: \(choice())")
        expect(list(of: parent) == nil && parent.isVisible, "\(tag)  Return closes the list and leaves the parent open")

        // A click on the face of an open list closes it, and that click does not open it again.
        click(parent, face); await pause(0.4)
        expect(list(of: parent) != nil, "\(tag)  open before the face click")
        click(parent, face); await pause(0.6)
        expect(list(of: parent) == nil, "\(tag)  a click on the open face closes the list and it stays closed")
        expect(choice() == "cursor" && parent.isVisible, "\(tag)  nothing was chosen and the parent is open")

        // Escape closes the list only: the parent does not take the key.
        click(parent, face); await pause(0.4)
        key(parent, 53, "\u{1B}"); await pause(0.6)
        expect(list(of: parent) == nil && choice() == "cursor", "\(tag)  Escape closes the list without choosing")
        expect(parent.isVisible, "\(tag)  Escape did not close the parent")

        // A click anywhere else closes it.
        click(parent, face); await pause(0.4)
        open = list(of: parent)
        expect(open != nil, "\(tag)  open before the outside click")
        click(parent, outside); await pause(0.4)
        expect(list(of: parent) == nil && choice() == "cursor", "\(tag)  a click outside closes the list without choosing")
        expect(parent.isVisible, "\(tag)  the parent is open after the outside click")
    }

    static func menuBar() async {
        guard let button = statusButton() else { expect(false, "M  no status button"); return }
        button.performClick(nil)
        await pause(1.0)
        guard let panel = menuPanel, let title = Probe.shared.frames["title"] else { expect(false, "M  the menu-bar panel did not open: \(windows())"); return }
        log("M  menu-bar panel: \(name(panel)) key=\(panel.isKeyWindow) lvl=\(panel.level.rawValue)")
        await exercise("M", parent: panel, frameKey: "M", choice: { Probe.shared.menuChoice },
                       outside: point(panel, title, dx: 300))
        expect(panel.isVisible, "M  the menu-bar panel stayed open through every step")

        // Inline fallback: the list drops under the face, inside the panel.
        if let i = Probe.shared.frames["I"] {
            click(panel, point(panel, i, dx: faceX, dy: 15)); await pause(0.4)
            let opened = Probe.shared.frames["I"] ?? i
            expect(opened.height > i.height + 100, "I  the inline list opens under the face (height \(Int(i.height)) to \(Int(opened.height)))")
            expect(list(of: panel) == nil, "I  inline opens no panel")
            click(panel, point(panel, opened, dx: faceX, dy: i.height + 4 + 4 + rowHeight * 2 + 14)); await pause(0.4)
            expect(Probe.shared.inlineChoice == "codex", "I  a click on an inline row chooses it: \(Probe.shared.inlineChoice)")
            expect(panel.isVisible, "I  the panel is open after an inline choice")
        } else { expect(false, "I  no frame") }

        // Calibration: the confirmation dialog's destructive button is dead in this surface.
        if let c = Probe.shared.frames["C"] {
            click(panel, point(panel, c, dx: c.width / 2)); await pause(1.0)
            @MainActor func find(_ view: NSView?, _ title: String) -> NSButton? {
                guard let view else { return nil }
                if let b = view as? NSButton, b.title == title { return b }
                for s in view.subviews { if let b = find(s, title) { return b } }
                return nil
            }
            var hit = false
            for w in NSApp.windows where w.isVisible {
                if let b = find(w.contentView, "Release") {
                    let r = b.convert(b.bounds, to: nil)
                    click(w, NSPoint(x: r.midX, y: r.midY)); hit = true; break
                }
            }
            await pause(1.0)
            log("C  calibration: releaseButtonFound=\(hit) releaseRan=\(Probe.shared.releaseRan) panelVisible=\(panel.isVisible)")
            expect(!Probe.shared.releaseRan, "C  calibration holds: the confirmation dialog's Release did not run in this surface")
        }
        if menuPanel != nil { statusButton()?.performClick(nil); await pause(0.5) }
    }

    /// S: a click on the words of a stock switch, and of a stock checkbox, against the gotcos ones, in a borderless
    /// window off screen (in either mode).
    static func calibration() async {
        let host = NSHostingView(rootView: CalibrationPane())
        host.frame = NSRect(origin: .zero, size: CalibrationPane.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        // Wait for the pane to lay out: every toggle has reported its frame.
        for _ in 0..<30 where ["stockSwitch", "cosSwitch", "stockBox", "cosBox"].contains(where: { Probe.shared.frames[$0] == nil }) { await pause(0.1) }
        await pause(0.8)
        func clickWords(_ key: String) async {
            guard let f = Probe.shared.frames[key] else { expect(false, "S  no frame for \(key)"); return }
            click(window, point(window, f, dx: 12)); await pause(0.6)
        }
        func clickControl(_ key: String, trailing: Bool) async {
            guard let f = Probe.shared.frames[key] else { return }
            click(window, point(window, f, dx: trailing ? f.width - 12 : 7)); await pause(0.6)
        }
        /// Whether a click flips the value `read` returns.
        func flips(_ read: @MainActor () -> Bool, _ act: () async -> Void) async -> Bool { let before = read(); await act(); return read() != before }
        // A click the stock control never received measures nothing, so each measurement is taken again (up to three
        // times) until the clicks on the stock controls themselves land; only a measurement that landed is judged.
        for attempt in 1...3 {
            let stockSwitchWords = await flips({ Probe.shared.stockSwitch }) { await clickWords("stockSwitch") }
            let cosSwitchWords = await flips({ Probe.shared.cosSwitch }) { await clickWords("cosSwitch") }
            let stockSwitchItself = await flips({ Probe.shared.stockSwitch }) { await clickControl("stockSwitch", trailing: true) }
            let cosSwitchItself = await flips({ Probe.shared.cosSwitch }) { await clickControl("cosSwitch", trailing: true) }
            let stockBoxWords = await flips({ Probe.shared.stockBox }) { await clickWords("stockBox") }
            let cosBoxWords = await flips({ Probe.shared.cosBox }) { await clickWords("cosBox") }
            let stockBoxItself = await flips({ Probe.shared.stockBox }) { await clickControl("stockBox", trailing: false) }
            let cosBoxItself = await flips({ Probe.shared.cosBox }) { await clickControl("cosBox", trailing: false) }
            log("S  attempt \(attempt): stock switch: a click on its words flips it=\(stockSwitchWords), on the switch=\(stockSwitchItself); COS switch: words=\(cosSwitchWords), switch=\(cosSwitchItself)")
            log("S  attempt \(attempt): stock checkbox: words=\(stockBoxWords), box=\(stockBoxItself); COS checkbox: words=\(cosBoxWords), box=\(cosBoxItself)")
            guard stockSwitchItself && stockBoxItself else {
                if attempt == 3 { expect(false, "S  calibration: the clicks never reached the stock controls themselves (this measures nothing)") }
                await pause(1.0)
                continue
            }
            expect(true, "S  calibration: the clicks reached the stock controls themselves")
            expect(cosSwitchWords == stockSwitchWords && cosSwitchItself == stockSwitchItself, "S  the COS switch does what the stock one does")
            expect(cosBoxWords == stockBoxWords && cosBoxItself == stockBoxItself, "S  the COS checkbox does what the stock one does")
            break
        }
    }

    static func window() async {
        let host = NSHostingView(rootView: WindowPane())
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: WindowPane.size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Dropdown canary"
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.center()
        normalWindow = window
        if ProcessInfo.processInfo.environment["COS_DESKTOP_CANARY"] == "1" { NSApp.activate(ignoringOtherApps: true) }
        if ProcessInfo.processInfo.environment["COS_DESKTOP_CANARY"] == "1" { window.makeKeyAndOrderFront(nil) }
        await pause(0.8)
        // Someone using the Mac keeps the focus, and a list closes when its app stops being active: say so plainly.
        if !window.isKeyWindow { log("W  NOTE the window is not key: another app kept the focus, so this run cannot prove W") }
        guard let title = Probe.shared.frames["wtitle"] else { expect(false, "W  no frame"); return }
        log("W  normal window: key=\(window.isKeyWindow) lvl=\(window.level.rawValue)")
        await exercise("W", parent: window, frameKey: "W", choice: { Probe.shared.windowChoice }, outside: point(window, title, dx: 330))

        // A long list: twelve rows scroll inside the card; keys bring the highlight into view; the card grows past a
        // narrow face only as far as its longest row needs.
        if let l = Probe.shared.frames["L"] {
            let face = point(window, l, dx: faceX)
            click(window, face); await pause(0.4)
            if let open = list(of: window) {
                let room = COSDropdownPresenter.shadowRoom
                let cardWidth = open.frame.width - room.left - room.right
                let cardHeight = open.frame.height - room.top - room.bottom
                expect(cardWidth > l.width - 70 + 40 && cardWidth <= COSDropdownRules.widestList,
                       "L  the card grew past its narrow face for the long names, within the cap: card \(cardWidth), face \(l.width - 70)")
                expect(abs(cardHeight - COSDropdownList<String>.scrollHeight) < 1.5, "L  twelve rows scroll inside a \(Int(COSDropdownList<String>.scrollHeight)) pt card: \(cardHeight)")
                // From Haiku (row 3), eight Downs land on the last row, which starts below the fold.
                for _ in 0..<8 { key(window, 125, "\u{F701}"); await pause(0.08) }
                await pause(0.4)
                key(window, 36, "\r"); await pause(0.6)
                expect(Probe.shared.modelChoice == "m11", "L  eight Downs then Return choose the last row: \(Probe.shared.modelChoice)")
            } else { expect(false, "L  the long list did not open") }
        }


        window.orderOut(nil)
    }

    // MARK: - Real frames of the open list

    static func bitmap(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
    static func save(_ rep: NSBitmapImageRep, _ url: URL) {
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
        log("frame  \(url.path)  \(rep.pixelsWide)x\(rep.pixelsHigh)")
    }
    /// The window's content and the open list, each drawn by AppKit (cacheDisplay), placed where they sit on screen.
    static func composite(_ window: NSWindow, _ list: NSWindow) -> NSBitmapImageRep? {
        guard let content = window.contentView, let listView = list.contentView,
              let base = bitmap(content), let top = bitmap(listView) else { return nil }
        let contentOnScreen = window.convertToScreen(content.convert(content.bounds, to: nil))
        let union = contentOnScreen.union(list.frame)
        let scale = CGFloat(base.pixelsWide) / content.bounds.width
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(union.width * scale), pixelsHigh: Int(union.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        out.size = union.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        (window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.09, green: 0.07, blue: 0.05, alpha: 1) : NSColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1)).setFill()
        NSRect(origin: .zero, size: union.size).fill()
        base.draw(in: NSRect(x: contentOnScreen.minX - union.minX, y: contentOnScreen.minY - union.minY,
                             width: contentOnScreen.width, height: contentOnScreen.height))
        top.draw(in: NSRect(x: list.frame.minX - union.minX, y: list.frame.minY - union.minY, width: list.frame.width, height: list.frame.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }
    /// Frames come from the same pane in a borderless window ordered in far off screen: it needs no focus, so a
    /// person using the Mac cannot close the list mid-capture, and nothing shows on their display. The list is the
    /// shipped dropdown's real child panel; each bitmap is AppKit's own drawing of it (cacheDisplay).
    static func frames(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: WindowPane())
        host.frame = NSRect(origin: .zero, size: WindowPane.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -8000, y: -8000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); Probe.shared.windowChoice = "claude"; Probe.shared.modelChoice = "m03" }
        await pause(0.6)
        Probe.shared.windowChoice = "codex"
        Probe.shared.modelChoice = "m08"
        for (appearance, word) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            window.appearance = NSAppearance(named: appearance)
            await pause(0.6)
            for (key, what, downs) in [("W", "provider", 1), ("L", "model", 1)] {
                guard let frame = Probe.shared.frames[key] else { continue }
                click(window, point(window, frame, dx: faceX)); await pause(0.4)
                for _ in 0..<downs { Driver.key(window, 125, "\u{F701}"); await pause(0.15) }
                await pause(0.4)
                if let open = list(of: window), let view = open.contentView {
                    if let rep = bitmap(view) { save(rep, dir.appendingPathComponent("open-list-\(what)-\(word)-panel-only.png")) }
                    if let rep = composite(window, open) { save(rep, dir.appendingPathComponent("open-list-\(what)-\(word).png")) }
                } else { expect(false, "frames  the \(what) list did not open (\(word))") }
                Driver.key(window, 53, "\u{1B}"); await pause(0.5)
            }
        }
    }
}
