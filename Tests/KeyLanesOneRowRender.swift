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
    let view = ControlPanel(model: model, openActivity: { _ in }, hostedInActivity: true).frame(width: width, height: height, alignment: .top)
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
        // Walk both drawings. A short run of rows that differ in place (the server version printed in the panel, which
        // must differ: that is the switch) is a substitution; anything else must be ONE inserted band, the row.
        let n = old.count, look = 40
        func same(_ a: Int, _ b: Int, _ count: Int) -> Bool {
            guard a + count <= n, b + count <= n else { return false }
            return (0..<count).allSatisfy { old[a + $0] == new[b + $0] }
        }
        var i = 0, j = 0, substituted = 0
        var bands: [(at: Int, rows: Int)] = []
        var runs: [String] = []
        let blank = old[n - 1]
        let lastContent = (0..<n).last(where: { old[$0] != blank }) ?? -1
        let lastContentNew = (0..<n).last(where: { new[$0] != blank }) ?? -1
        while i < n && j < n {
            if old[i] == new[j] { i += 1; j += 1; continue }
            if let s = (1...30).first(where: { same(i + $0, j + $0, min(look, n - j - $0)) }) {
                substituted += s; runs.append("\(j)+\(s)"); i += s; j += s; continue
            }
            guard let h = (1...600).first(where: { same(i, j + $0, min(look, n - j - $0)) }) else {
                fail("6.80.0 differs from 6.79.0 by more than one inserted band and the version text (pixel row \(j))")
            }
            bands.append((j, h)); j += h
        }
        guard bands.count == 1, let band = bands.first else {
            fail((bands.isEmpty ? "6.80.0 with lanes off draws no Settings row" : "6.80.0 inserts \(bands.count) bands, not one")
                 + " (in-place runs \(runs.prefix(12)), last content row 6.79.0 \(lastContent), 6.80.0 \(lastContentNew) of \(n))")
        }
        let top = band.at, h = band.rows
        guard substituted <= 80 else { fail("\(substituted) pixel rows changed in place, more than the version text") }
        let content = Set(new[top..<(top + h)]).count
        guard content > 2 else { fail("the inserted band is blank") }
        // On a 2x backing store a Settings card with a title and one line is roughly 100 to 300 pixel rows.
        guard (60...400).contains(h) else { fail("the inserted band is \(h) pixel rows, not one Settings row") }
        print(#"{"schema":"key-lanes-onerow/2","bandAt":\#(top),"bandRows":\#(h),"distinctRowsInBand":\#(content),"rowsChangedInPlace":\#(substituted),"rowsCompared":\#(n)}"#)
        print("key lanes one-row check: 6.80.0 lanes off = 6.79.0 plus exactly one Settings row (\(h) pixel rows at row \(top))")
    }
}
