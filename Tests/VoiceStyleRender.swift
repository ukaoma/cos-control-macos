import AppKit
import SwiftUI

/// Run by hand (Tests/run-voice-style-render.sh <folder>): Settings, Dictation, Your style drawn off screen, light and
/// dark, at the 390 pt panel width, through the real DictationStyleStore with a stand-in helper bridge and a ledger file
/// in a scratch folder (fictional rules only). States: Sonnet with active, not active yet and Previous polish (server
/// 6.91.0); Not used on Haiku; Paused; an older server; Previous polish set on the server; Suggest only. Windows are never ordered
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
        func options(_ version: String, sonnet: String, env: Bool) -> @MainActor (Data) async throws -> HelperResponse {
            { _ in HelperResponse(ok: true, message: "Polish options", details: ["available": .bool(true), "promptVersion": .string(version),
                                                                                 "effectiveByModel": .object(["sonnet": .string(sonnet), "haiku": .string("v3")]),
                                                                                 "envOverride": .bool(env)]) }
        }
        let applied: [String: JSONValue] = ["available": .bool(true), "enabled": .bool(true), "serverEnabled": .bool(true), "hash": .string("0a1b2c3d"),
                                            "revision": .string("11112222"), "rules": .array([rule(honestly, count: 3), rule(use, count: 2)]),
                                            "allowlist": allowlist, "maxRules": .number(20)]
        func store(_ build: (inout S.Ledger) -> Void, server: [String: JSONValue], options optionsBridge: (@MainActor (Data) async throws -> HelperResponse)?) async throws
            -> DictationStyleStore {
            let style = DictationStyleStore(url: try ledger(build))
            style.bridge = bridge(server)
            style.optionsBridge = optionsBridge
            await style.load(); await style.loadOptions()
            return style
        }
        let learned: (inout S.Ledger) -> Void = { observed(&$0, honestly, times: 3); observed(&$0, use, times: 2); observed(&$0, frankly, times: 1) }

        // 1. Server 6.91.0, Sonnet, the new prompt: two active rules, one not active yet, Previous polish offered.
        dictation.polishModel = .sonnet
        let a = try await store(learned, server: applied, options: options("default", sonnet: "v4", env: false))
        precondition(a.available && a.checked && a.notUsed(model: .sonnet) == nil && a.rules(.active).count == 2 && a.rules(.pending).count == 1 && a.message == nil,
                     "server 6.91.0 state")
        try render(DictationStyleCard(style: a, dictation: dictation), name: "style-sonnet", out: out)

        // 2. The same rules with AI polish on Haiku: Not used, and why.
        dictation.polishModel = .haiku
        let b = try await store(learned, server: applied, options: options("default", sonnet: "v4", env: false))
        precondition(b.notUsed(model: .haiku) == .notSonnet, "Haiku state")
        try render(DictationStyleCard(style: b, dictation: dictation), name: "style-not-used-haiku", out: out)

        // 3. Learning off: the rules are Paused, here and on G2.
        dictation.polishModel = .sonnet
        var paused = applied; paused["enabled"] = .bool(false)
        let c = try await store({ learned(&$0); $0.enabled = false }, server: paused, options: options("default", sonnet: "v4", env: false))
        precondition(!c.ledger.enabled, "paused state")
        try render(DictationStyleCard(style: c, dictation: dictation), name: "style-paused", out: out)

        // 4. An older server: Not used, the rules stay on this Mac.
        let d = try await store({ observed(&$0, honestly, times: 2) }, server: ["available": .bool(false)], options: nil)
        precondition(!d.available && d.checked && d.notUsed(model: .sonnet) == .oldServer, "older server state")
        try render(DictationStyleCard(style: d, dictation: dictation), name: "style-older-server", out: out)

        // 5. The server's environment names the previous prompt: Not used, and Previous polish is set on the server.
        let e = try await store(learned, server: applied, options: options("default", sonnet: "v3", env: true))
        precondition(e.notUsed(model: .sonnet) == .serverPrompt && e.options.envOverride, "environment state")
        try render(DictationStyleCard(style: e, dictation: dictation), name: "style-set-on-server", out: out)

        // 6. Suggest only: a suggested rule waits for Add.
        dictation.learnMode = .suggest
        let f = DictationStyleStore(url: try ledger { observed(&$0, guess, times: 2, suggest: true) })
        f.suggestOnly = { true }
        f.bridge = bridge(["available": .bool(true), "enabled": .bool(true), "serverEnabled": .bool(true), "hash": .string(""), "revision": .string("33334444"),
                           "rules": .array([]), "allowlist": allowlist, "maxRules": .number(20)])
        f.optionsBridge = options("default", sonnet: "v4", env: false)
        await f.load(); await f.loadOptions()
        precondition(f.rules(.suggested).count == 1, "suggest only state")
        try render(DictationStyleCard(style: f, dictation: dictation), name: "style-suggest", out: out)
        dictation.learnMode = .automatic
        dictation.polishModel = .off
        print("PASS: Your style rendered (6 states, light and dark) to \(out.path)")
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
