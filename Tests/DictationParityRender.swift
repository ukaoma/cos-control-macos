import AppKit
import SwiftUI

/// Run by hand (Tests/run-dictation-parity-render.sh <folder>): the Settings, Dictation rows 0.5.345 Wave A changed, and
/// an edited dictation's card with its next-time lines (A-W12), drawn off screen, light and dark, at the 390 pt panel
/// width, through the real stores with stand-in helper bridges and a scratch home (fictional text only). States: Sonnet
/// on the newest polish with two style rules; Haiku on the earlier polish with sounds and muting paused and a microphone
/// fallback note; Off with the filler strip; and cards for polish had it, a style rule on its way, a filler removed and
/// nothing to learn. Windows are never ordered in, the process never becomes active, nothing is clicked or typed.
@main @MainActor struct DictationParityRender {
    typealias S = DictationStyle
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Before the stores first load: dictation on (no hot key is registered by the init), and a style ledger with one
        // rule on its way and one active, at the shared store's own path in the scratch home.
        UserDefaults.standard.set(true, forKey: "dictation.enabled")
        let now = Date()
        let use = S.Key(kind: .contractions, param: "use"), honestly = S.Key(kind: .dropPhrase, param: "honestly")
        var ledger = S.Ledger()
        S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: use)], appliedHash: nil, suggestOnly: false, now: now)
        for _ in 0..<2 { S.observe(&ledger, dictation: UUID(), observations: [S.Observation(key: honestly)], appliedHash: nil, suggestOnly: false, now: now) }
        guard let url = DictationStyleStore.defaultURL() else { fatalError("no scratch history folder") }
        try S.save(ledger, to: url)

        let style = DictationStyleStore.shared
        let dictation = MacDictationStore.shared
        func options(_ sonnet: String, haiku: String, version: String) -> @MainActor (Data) async throws -> HelperResponse {
            { _ in HelperResponse(ok: true, message: "Polish options", details: [
                "available": .bool(true), "promptVersion": .string(version), "envOverride": .bool(false), "meaningGuard": .bool(true),
                "effectiveByModel": .object(["sonnet": .string(sonnet), "haiku": .string(haiku)]),
                "stylePairs": .object(sonnet == "v4" ? ["sonnet": .string("v4")] : [:])]) }
        }
        style.bridge = { _ in HelperResponse(ok: true, message: "Learned style", details: [
            "available": .bool(true), "enabled": .bool(true), "serverEnabled": .bool(true), "hash": .string("0a1b2c3d"), "revision": .string("11112222"),
            "rules": .array([]), "allowlist": .array(S.defaultAllowlist.map(JSONValue.string)), "maxRules": .number(20)]) }

        // 1. Sonnet on the newest polish, the guard on: the newest line with the rule count, the paste-first note, the
        // filler, casing, ⌘/⌃ wait and microphone fallback switches.
        style.optionsBridge = options("v4", haiku: "v3", version: "default")
        await style.load(); await style.loadOptions()
        dictation.polishModel = .sonnet
        dictation.pasteThenPolish = true
        try render(MacDictationSettings(store: dictation, activityShortcut: nil, style: style), name: "settings-sonnet-newest", height: 2300, out: out)

        // 2. Haiku on the earlier polish, with sounds and muting paused after an audio error and a fallback note.
        style.optionsBridge = options("v4", haiku: "v3", version: "default")
        await style.loadOptions()
        dictation.polishModel = .haiku
        dictation.soundsPaused = true
        dictation.mutePaused = true
        dictation.quietMode = .mute
        dictation.micNote = DictationMicFallback.usedMessage(failed: "Studio Display Microphone", used: "AT2020USB+")
        try render(MacDictationSettings(store: dictation, activityShortcut: nil, style: style), name: "settings-haiku-paused", height: 2400, out: out)
        dictation.soundsPaused = false; dictation.mutePaused = false; dictation.micNote = nil

        // 3. Off, with the filler strip on: the one Off line.
        dictation.polishModel = .off
        try render(MacDictationSettings(store: dictation, activityShortcut: nil, style: style), name: "settings-off", height: 2000, out: out)

        // 4. Edited dictations' cards: polish had it; a style rule on its way and one active; a filler removed by hand;
        // nothing to learn.
        dictation.polishModel = .sonnet
        let at = now.addingTimeInterval(-90)
        func card(_ text: String, edited: String, matched: Bool = false, keys: [String] = [], heard: String? = nil) -> DictationRecord {
            DictationRecord(id: UUID(), text: text, createdAt: at, delivery: .inserted(app: "Notes"), engine: "parakeet-ultra", heard: heard,
                            polishModel: heard == nil ? nil : "sonnet",
                            edit: DictationUserEdit(text: edited, app: "Notes", at: now, edits: 1, matchedPolish: matched, styleKeys: keys))
        }
        let size = PetSize(preset: .medium, customPixels: PetSize.mediumPixels)
        let cards: [(String, DictationRecord)] = [
            ("card-polish-had-it", card("so I clicked the button for the deck", edited: "so I click to button for the deck", matched: true)),
            ("card-style", card("I do not know if honestly we can ship", edited: "I don't know if we can ship", keys: [use.id, honestly.id])),
            ("card-filler", card("so um we go with the deck", edited: "so we go with the deck")),
            ("card-nothing", card("send the deck today", edited: "send the slides today")),
        ]
        for (name, record) in cards {
            try render(DictationRecordDetail(store: dictation, record: record, size: size).frame(width: 340), name: name, height: 420, out: out)
        }
        print("PASS dictation parity render: \(3 + cards.count) states, light and dark, 390 pt, written to \(out.path)")
    }

    static func render<V: View>(_ view: V, name: String, height: CGFloat, out: URL) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let root = VStack(alignment: .leading) { view; Spacer(minLength: 0) }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).frame(width: 390, height: height, alignment: .top)
                .font(COSType.body(13)).background(COSPalette.panel).cosControlTheme()
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 390, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 390, height: height)
            settle(host, seconds: 1.5)
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png"))
            window.close()
        }
    }

    static func settle(_ host: NSView, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
    }
}
