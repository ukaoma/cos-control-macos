import AppKit
import SwiftUI

// K1 P10 (QA G2): the shipping case. The menu-bar panel's whole scroll content drawn off screen twice with NO key-lane
// answer: on a 6.79.0 server (the K0 golden case) and on a 6.80.0 server (key lanes off, no key). The 6.80.0 drawing
// must be the 6.79.0 drawing with exactly ONE horizontal band inserted (the Settings row "Answer with your own key",
// plan 3.2): every pixel row above the band identical, every row below it identical once shifted by the band's height.
// Prints JSON; fails with "key lanes one-row check FAILED: ..." otherwise. Same desktop rules as every render harness:
// no window ordered in, never active, no helper or server (the model never starts background work).

@MainActor func pump(_ rounds: Int = 16) { for _ in 0..<rounds { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) } }

func fail(_ what: String) -> Never { print("key lanes one-row check FAILED: \(what)"); exit(1) }

@MainActor func rows(_ version: String, width: CGFloat, height: CGFloat) -> (rows: [Data], width: Int) {
    let model = ControllerModel(startBackgroundWork: false)
    model.status = ServerStatus([
        "installed": .bool(true), "serviceLoaded": .bool(true), "running": .bool(true), "managedContract": .bool(true),
        "runtimeState": .string("managedHealthy"), "ownershipVerified": .bool(true),
        "version": .string(version), "installedVersion": .string(version),
        "claudeCliReady": .bool(true), "codexCliReady": .bool(true), "cursorState": .string("ready"),
    ])
    model.setupGuide = SetupGuideState(defaults: UserDefaults(suiteName: "cos.key-lanes-onerow.\(UUID().uuidString)")!)
    let view = ControlPanel(model: model, openActivity: { _ in }).frame(width: width, height: height, alignment: .top)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua); host.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
    pump(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); pump(6)
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fail("no bitmap") }
    host.cacheDisplay(in: host.bounds, to: rep)
    window.close()
    guard let base = rep.bitmapData else { fail("no pixels") }
    let stride = rep.bytesPerRow, used = rep.pixelsWide * rep.bitsPerPixel / 8
    return ((0..<rep.pixelsHigh).map { Data(bytes: base + $0 * stride, count: used) }, rep.pixelsWide)
}

@main @MainActor struct KeyLanesOneRowRender {
    static func main() async {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-key-lanes") else { exit(2) }
        let (old, w1) = rows("6.79.0", width: 390, height: 9000)
        let (new, w2) = rows("6.80.0", width: 390, height: 9000)
        let again = rows("6.79.0", width: 390, height: 9000).rows
        guard old == again else { fail("two drawings at 6.79.0 differ, so this fixture cannot prove anything") }
        guard w1 == w2, old.count == new.count else { fail("the drawings differ in size") }
        guard let top = (0..<old.count).first(where: { old[$0] != new[$0] }) else { fail("6.80.0 with lanes off draws no Settings row") }
        // The background rows below the content are all alike; the band is the smallest shift that lines the rest up.
        var band: Int?
        for h in 1...600 where top + h < new.count {
            if (top..<(old.count - h)).allSatisfy({ old[$0] == new[$0 + h] }) { band = h; break }
        }
        guard let h = band else { fail("6.80.0 differs from 6.79.0 by more than one inserted band (first difference at pixel row \(top))") }
        let content = Set(new[top..<(top + h)]).count
        guard content > 2 else { fail("the inserted band is blank") }
        // On a 2x backing store a Settings card with a title and one line is roughly 100 to 300 pixel rows.
        guard (60...400).contains(h) else { fail("the inserted band is \(h) pixel rows, not one Settings row") }
        print(#"{"schema":"key-lanes-onerow/1","identicalAbove":\#(top),"bandRows":\#(h),"distinctRowsInBand":\#(content),"rowsCompared":\#(old.count)}"#)
        print("key lanes one-row check: 6.80.0 lanes off = 6.79.0 plus exactly one Settings row (\(h) pixel rows at row \(top))")
    }
}
