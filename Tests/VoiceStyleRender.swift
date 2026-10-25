import AppKit
import SwiftUI

/// Run by hand (Tests/run-voice-style-render.sh <folder>): Settings, Dictation, Your style drawn off screen, light and
/// dark, at the 390 pt panel width, through the real DictationStyleStore with a stand-in helper bridge and a ledger file
/// in a scratch folder (fictional rules only). States: Sonnet with active, pending and Previous polish (server 6.91.0);
/// an older server with Haiku; Suggest only with a suggested rule and the server's switch off. Windows are never ordered
/// in, the process never becomes active, and nothing is clicked or typed.
@main @MainActor struct VoiceStyleRender {
    typealias S = DictationStyle
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        let out = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cos-style-render.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let now = Date()
        func ledger(_ build: (inout S.Ledger) -> Void) throws -> URL {
            var l = S.Ledger(); build(&l)
            let url = scratch.appendingPathComponent(UUID().uuidString).appendingPathComponent(S.fileName)
            try S.save(l, to: url)
            return url
        }
        func observed(_ l: inout S.Ledger, _ key: S.Key, times: Int, suggest: Bool = false) {
            for _ in 0..<times { S.observe(&l, dictation: UUID(), observations: [S.Observation(key: key)], appliedHash: nil, suggestOnly: suggest, now: now) }
        }
        func rule(_ key: S.Key, count: Int) -> JSONValue {
            .object(["id": .string(key.id), "kind": .string(key.kind.rawValue), "register": .string("all"), "param": .string(key.param), "count": .number(Double(count))])
        }
        func bridge(_ details: [String: JSONValue]) -> @MainActor (Data) async throws -> HelperResponse {
            { _ in HelperResponse(ok: true, message: "Learned style", details: details) }
        }
        let honestly = S.Key(kind: .dropPhrase, param: "honestly"), frankly = S.Key(kind: .dropPhrase, param: "frankly")
        let use = S.Key(kind: .contractions, param: "use"), guess = S.Key(kind: .dropPhrase, param: "i guess")
        let allowlist: JSONValue = .array(S.defaultAllowlist.map(JSONValue.string))
        let dictation = MacDictationStore.shared
        dictation.learnMode = .automatic

        // 1. Server 6.91.0, Sonnet: two active rules, one pending, Previous polish offered.
        let a = DictationStyleStore(url: try ledger { observed(&$0, honestly, times: 3); observed(&$0, use, times: 2); observed(&$0, frankly, times: 1) })
        a.bridge = bridge(["available": .bool(true), "enabled": .bool(true), "serverEnabled": .bool(true), "hash": .string("0a1b2c3d"),
                           "rules": .array([rule(honestly, count: 3), rule(use, count: 2)]), "allowlist": allowlist, "maxRules": .number(20)])
        a.optionsBridge = { _ in HelperResponse(ok: true, message: "Polish options", details: ["available": .bool(true), "promptVersion": .string("default")]) }
        dictation.polishModel = .sonnet
        // The store's real decode path (JSONValue to DictationStyle.Server): a number reads as an Int, the rules match.
        await a.load()
        precondition(a.available && a.checked && a.rules(.active).count == 2 && a.rules(.pending).count == 1 && a.message == nil, "server 6.91.0 state")
        try render(DictationStyleCard(style: a, dictation: dictation), name: "style-sonnet", out: out)

        // 2. An older server, Haiku: the ledger stays on this Mac.
        let b = DictationStyleStore(url: try ledger { observed(&$0, honestly, times: 2) })
        b.bridge = bridge(["available": .bool(false)])
        dictation.polishModel = .haiku
        await b.load()
        precondition(!b.available && b.checked, "older server state")
        try render(DictationStyleCard(style: b, dictation: dictation), name: "style-older-server", out: out)

        // 3. Suggest only, and the server's switch off: a suggested rule waits for Add.
        let c = DictationStyleStore(url: try ledger { observed(&$0, guess, times: 2, suggest: true) })
        c.suggestOnly = { true }
        c.bridge = bridge(["available": .bool(true), "enabled": .bool(true), "serverEnabled": .bool(false), "hash": .string(""), "rules": .array([]),
                           "allowlist": allowlist, "maxRules": .number(20)])
        dictation.polishModel = .sonnet
        dictation.learnMode = .suggest
        await c.load()
        precondition(c.available && !c.serverEnabled && c.rules(.suggested).count == 1, "suggest only state")
        try render(DictationStyleCard(style: c, dictation: dictation), name: "style-suggest-server-off", out: out)
        dictation.learnMode = .automatic
        dictation.polishModel = .off
        print("PASS: Your style rendered (3 states, light and dark) to \(out.path)")
    }

    static func settle(_ host: NSView, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
    }

    /// The panel's 390 pt width less its 16 pt padding, on the panel background, with the panel's theme and font.
    static func render<V: View>(_ view: V, name: String, out: URL) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let root = VStack(alignment: .leading) { view; Spacer(minLength: 0) }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).frame(width: 390, height: 640, alignment: .top)
                .font(COSType.body(13)).background(COSPalette.panel).cosControlTheme()
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 390, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 390, height: 640)
            settle(host, seconds: 1.5)
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png"))
            window.close()
        }
    }
}
