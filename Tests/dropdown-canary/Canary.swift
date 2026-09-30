import AppKit
import SwiftUI

// Does a COSDropdown's popover work inside MenuBarExtra(.window)? Run: Tests/dropdown-canary/run.sh
// Automated in-process: open the status item, click each variant's face, then a row, with real NSEvents posted to the
// app's queue, and log what the panel and the selection did. It compiles the SHIPPED Sources/COSBrand.swift.
//
// Result 2026-09-30 (0.5.251, macOS 26.6.2):
//   P  popover opened (_NSPopoverWindow); a row click chose Codex; Down then Return chose Cursor; the panel stayed open
//   I  inline list opened under the face; a row click chose Codex; the panel stayed open
//   C  calibration: .confirmationDialog's Release did NOT run and the panel closed, the on-device finding of 2026-08-23
// So Control's panel uses the popover, like the Activity window. `.environment(\.cosDropdownInline, true)` on the
// panel root is the fallback if a real click ever dismisses it.
//   P  COSDropdown in popover mode (the Activity window's presentation)
//   I  COSDropdown inline (the list dropped under the face)
//   C  .confirmationDialog destructive button (calibration: proven dead on-device 2026-08-23)

let logURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/dropdown-canary.log")
nonisolated(unsafe) var logLines: [String] = []
func log(_ line: String) {
    let row = String(format: "%.2f  ", ProcessInfo.processInfo.systemUptime) + line
    print(row); logLines.append(row)
    try? logLines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)
}

@MainActor final class Probe: ObservableObject {
    static let shared = Probe()
    @Published var popoverChoice = "claude"
    @Published var inlineChoice = "claude"
    @Published var confirmShown = false
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
    .init("", "Choose provider", placeholder: true), .init("claude", "Claude"), .init("codex", "Codex"), .init("cursor", "Cursor"),
]

struct Panel: View {
    @ObservedObject var probe = Probe.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dropdown canary").font(.headline)
            COSDropdown("Popover", selection: $probe.popoverChoice, options: providerOptions, labelWidth: 60)
                .modifier(FrameReporter(key: "P"))
            COSDropdown("Inline", selection: $probe.inlineChoice, options: providerOptions, labelWidth: 60)
                .environment(\.cosDropdownInline, true)
                .modifier(FrameReporter(key: "I"))
            Button("Confirm variant") { probe.confirmShown = true }.modifier(FrameReporter(key: "C"))
            Text("P=\(probe.popoverChoice) I=\(probe.inlineChoice)").font(.caption)
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

@main struct CanaryApp: App {
    init() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainActor.assumeIsolated { Driver.start() } }
    }
    var body: some Scene {
        MenuBarExtra("Canary", systemImage: "testtube.2") { Panel() }.menuBarExtraStyle(.window)
    }
}

@MainActor enum Driver {
    static func windows() -> String {
        NSApp.windows.map { "\(type(of: $0))[vis=\($0.isVisible) key=\($0.isKeyWindow) lvl=\($0.level.rawValue)]" }.joined(separator: " ")
    }
    static var panel: NSWindow? {
        NSApp.windows.first { $0.isVisible && !String(describing: type(of: $0)).contains("StatusBar") && !String(describing: type(of: $0)).contains("Popover") && $0.frame.width > 300 }
    }
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
    static func click(_ window: NSWindow, _ p: NSPoint, _ tag: String) {
        log("\(tag)  click at \(Int(p.x)),\(Int(p.y)) in \(type(of: window))")
        let t = ProcessInfo.processInfo.systemUptime
        for (type, dt) in [(NSEvent.EventType.leftMouseDown, 0.0), (.leftMouseUp, 0.05)] {
            let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: t + dt, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(e, atStart: false)
        }
    }
    /// A global SwiftUI frame (top-left origin in the window's content) to a window point (bottom-left origin).
    static func point(_ window: NSWindow, _ frame: CGRect, dx: CGFloat? = nil, dy: CGFloat? = nil) -> NSPoint {
        let h = window.contentView?.bounds.height ?? window.frame.height
        return NSPoint(x: frame.minX + (dx ?? frame.width * 0.75), y: h - (frame.minY + (dy ?? frame.height / 2)))
    }
    static func after(_ s: Double, _ f: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } }
    }
    static func start() {
        log("start: \(windows())")
        guard let button = statusButton() else { log("FAIL no status button"); NSApp.terminate(nil); return }
        button.performClick(nil)
        after(1.0) {
            log("panel open? \(windows())")
            guard let panel = panel, let p = Probe.shared.frames["P"] else { log("FAIL no panel or P frame"); NSApp.terminate(nil); return }
            // Popover variant: click the face (the face sits after the 60 pt label and a 10 pt gap).
            click(panel, point(panel, p, dx: 60 + 10 + 60), "P")
            after(1.0) {
                let pops = NSApp.windows.filter { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
                log("P  after face click: panelVisible=\(panel.isVisible) popovers=\(pops.count) \(windows())")
                if let pop = pops.first, let content = pop.contentView {
                    // Row 3 (Codex): rows are ~28 pt from a 4 pt top inset. Find the list's top in the popover content.
                    let b = content.bounds
                    log("P  popover content bounds \(b)")
                    // Walk from the top: the list fills the content under the arrow; aim at row index 2.
                    let listTop = b.maxY - (pop.frame.height - (pop.contentLayoutRect.height))
                    _ = listTop
                    let top: CGFloat = pop.contentLayoutRect.maxY
                    click(pop, NSPoint(x: b.midX, y: top - 74), "P row")
                }
                after(1.0) {
                    log("P  after row click: panelVisible=\(panel.isVisible) choice=\(Probe.shared.popoverChoice) \(windows())")
                    // Keyboard path in the popover: reopen, Down, Return.
                    if panel.isVisible, let p2 = Probe.shared.frames["P"] {
                        click(panel, point(panel, p2, dx: 130), "P reopen")
                        after(0.8) {
                            let pop = NSApp.windows.first { String(describing: type(of: $0)).contains("Popover") && $0.isVisible }
                            log("P  reopened: popover=\(pop != nil) key=\(pop?.isKeyWindow ?? false) panelVisible=\(panel.isVisible)")
                            if let pop { key(pop, 125, "\u{F701}"); key(pop, 36, "\r") }
                            after(0.8) {
                                log("P  after Down+Return: panelVisible=\(panel.isVisible) choice=\(Probe.shared.popoverChoice)")
                                inlineVariant(panel)
                            }
                        }
                    } else {
                        reopenPanelThen { inlineVariant($0) }
                    }
                }
            }
        }
    }
    static func key(_ window: NSWindow, _ code: UInt16, _ chars: String) {
        let t = ProcessInfo.processInfo.systemUptime
        let flags: NSEvent.ModifierFlags = code == 125 ? [.numericPad, .function] : []
        let number = window.windowNumber
        for type in [NSEvent.EventType.keyDown, NSEvent.EventType.keyUp] {
            let event: NSEvent? = NSEvent.keyEvent(with: type, location: NSPoint.zero, modifierFlags: flags, timestamp: t,
                                                   windowNumber: number, context: nil, characters: chars,
                                                   charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            if let event { NSApp.postEvent(event, atStart: false) }
        }
    }
    static func reopenPanelThen(_ next: @escaping @MainActor (NSWindow) -> Void) {
        log("panel closed; reopening")
        statusButton()?.performClick(nil)
        after(1.0) {
            guard let panel = panel else { log("FAIL panel did not reopen"); NSApp.terminate(nil); return }
            next(panel)
        }
    }
    static func inlineVariant(_ panel: NSWindow) {
        guard let i = Probe.shared.frames["I"] else { log("FAIL no I frame"); NSApp.terminate(nil); return }
        click(panel, point(panel, i, dx: 130, dy: 15), "I")
        after(0.8) {
            let f = Probe.shared.frames["I"] ?? i
            log("I  after face click: panelVisible=\(panel.isVisible) frameHeight=\(Int(f.height)) (closed ~30)")
            // The inline list sits under the face: face 30 + gap 4 + inset 4 + two rows of 28, aim at row index 2 (Codex).
            let rowY: CGFloat = 108
            click(panel, point(panel, f, dx: 130, dy: rowY), "I row")
            after(0.8) {
                log("I  after row click: panelVisible=\(panel.isVisible) choice=\(Probe.shared.inlineChoice)")
                confirmVariant(panel)
            }
        }
    }
    static func confirmVariant(_ panel: NSWindow) {
        guard let c = Probe.shared.frames["C"] else { log("FAIL no C frame"); NSApp.terminate(nil); return }
        click(panel, point(panel, c, dx: c.width / 2), "C")
        after(1.0) {
            log("C  after button: panelVisible=\(panel.isVisible) shown=\(Probe.shared.confirmShown) \(windows())")
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
                    click(w, NSPoint(x: r.midX, y: r.midY), "C Release in \(type(of: w))")
                    hit = true; break
                }
            }
            if !hit { log("C  no Release NSButton found in any window") }
            after(1.0) {
                log("C  result: releaseRan=\(Probe.shared.releaseRan) panelVisible=\(panel.isVisible)")
                log("DONE")
                NSApp.terminate(nil)
            }
        }
    }
}
