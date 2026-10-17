import AppKit
import SwiftUI

/// Run by hand (Tests/run-transcription-settings-render.sh <folder>): the Settings card "Transcription" drawn off screen,
/// light and dark, at the 390 pt panel width, from the contract fixture (Tests/fixtures/stt-settings-6.72.0.json) through
/// the real store and a stand-in helper. States: Parakeet installed (Advanced open), not installed (Install button),
/// installing (X of Y MB) and verifying (followed from a server mid-install), a failed install (the server's reason),
/// Parakeet warming for previews, effective engines that differ from the selection (resolver on but not refining), not
/// installed during a live recording (no button), a 400 refusal, and a 404 (card hidden, drawn between two harness
/// marker lines so the gap is visible). Windows are never ordered in, the process
/// never becomes active, and nothing is clicked or typed.
@main @MainActor struct TranscriptionSettingsRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let args = CommandLine.arguments
        let out = URL(fileURLWithPath: args[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        func settings(_ edit: (inout [String: JSONValue]) -> Void = { _ in }) -> JSONValue {
            var object = fixture.object!; edit(&object); return .object(object)
        }
        func reply(_ status: Int, settings: JSONValue? = nil, error: String? = nil) -> HelperResponse {
            var details: [String: JSONValue] = ["httpStatus": .number(Double(status))]
            if let settings { details["settings"] = settings }
            if let error { details["error"] = .string(error) }
            return HelperResponse(ok: true, message: error ?? "Transcription", details: details)
        }
        func answers(_ list: [HelperResponse]) -> TranscriptionSettingsStore.Run {
            var queue = list
            return { _, _ in queue.removeFirst() }
        }
        func choice(_ key: String, selected: String, effective: String) -> (inout [String: JSONValue]) -> Void {
            { object in
                var row = object[key]!.object!; row["selected"] = .string(selected); row["effective"] = .string(effective); object[key] = .object(row)
            }
        }
        func enable(_ key: String, _ id: String) -> (inout [String: JSONValue]) -> Void {
            { object in
                var row = object[key]!.object!
                row["options"] = .array(row["options"]!.array!.map { option in
                    var o = option.object!; if o["id"]?.string == id { o["available"] = .bool(true); o["note"] = .null }; return .object(o)
                })
                object[key] = .object(row)
            }
        }
        func parakeet(installed: Bool, state: String, done: Double = 0, total: Double = 0, error: String? = nil, warm: String = "cold", note: String? = nil) -> (inout [String: JSONValue]) -> Void {
            { $0["parakeet"] = .object(["installed": .bool(installed), "installable": .bool(true), "version": .string("0.6.3"), "bytes": .number(done),
                "progress": .object(["state": .string(state), "bytesDone": .number(done), "bytesTotal": .number(total), "error": error.map(JSONValue.string) ?? .null]),
                "warm": .object(["preview": .string(warm)]), "note": note.map(JSONValue.string) ?? .null]) }
        }
        let installedParakeet = parakeet(installed: true, state: "installed", done: 612_000_000, total: 612_000_000, warm: "warm")
        let installed = settings {
            for key in ["preview", "hq", "secondOpinion"] { enable(key, key == "preview" ? "parakeet" : "parakeet-ultra")(&$0) }
            choice("secondOpinion", selected: "parakeet-ultra", effective: "parakeet-ultra")(&$0)
            $0["resolver"] = .object(["enabled": .bool(true), "effective": .bool(true)])
            installedParakeet(&$0)
        }
        func store(_ first: HelperResponse) async -> TranscriptionSettingsStore {
            let store = TranscriptionSettingsStore()
            await store.load(answers([first]))
            return store
        }
        final class Hold { var continuation: CheckedContinuation<Void, Never>? }
        var holds: [Hold] = []
        /// A store that read a server mid-install and is following it, held at its first pause.
        func following(_ reply: HelperResponse) async throws -> TranscriptionSettingsStore {
            let store = TranscriptionSettingsStore(); let hold = Hold(); holds.append(hold)
            Task { @MainActor in await store.load(answers([reply]), pause: { _ in await withCheckedContinuation { hold.continuation = $0 } }) }
            while hold.continuation == nil { try await Task.sleep(nanoseconds: 20_000_000) }
            return store
        }
        let model = ControllerModel(startBackgroundWork: false)
        let live = ControllerModel(startBackgroundWork: false)
        live.status.running = true; live.status.liveTranscriptionSessions = 1
        precondition(live.recordingCount == 1 && model.recordingCount == 0, "recording seed")

        let a = await store(reply(200, settings: installed))
        try render(TranscriptionSettingsCard(store: a, model: model, advancedOpen: true), name: "stt-installed", out: out)
        let b = await store(reply(200, settings: settings()))
        precondition(b.offersInstall(recording: false))
        try render(TranscriptionSettingsCard(store: b, model: model), name: "stt-not-installed", out: out)
        let c = await store(reply(200, settings: settings()))
        try render(TranscriptionSettingsCard(store: c, model: live), name: "stt-not-installed-recording", out: out)
        let d = await store(reply(200, settings: settings()))
        await d.set("secondOpinion", .string("parakeet-ultra"), run: answers([reply(400, error: "Pick a different engine for the second opinion than for HQ.")]))
        precondition(d.error != nil && d.visible)
        try render(TranscriptionSettingsCard(store: d, model: model), name: "stt-400", out: out)
        let e = try await following(reply(200, settings: settings(parakeet(installed: false, state: "downloading", done: 184_000_000, total: 612_000_000))))
        precondition(e.showsProgress)
        try render(TranscriptionSettingsCard(store: e, model: model), name: "stt-installing", out: out)
        let v = try await following(reply(200, settings: settings(parakeet(installed: false, state: "verifying", done: 612_000_000, total: 612_000_000))))
        try render(TranscriptionSettingsCard(store: v, model: model), name: "stt-verifying", out: out)
        let failed = await store(reply(200, settings: settings(parakeet(installed: false, state: "failed",
            error: "Parakeet needs the FluidAudio command line tool 0.17.4 in ~/.cos-glasses/bin. Install it, then try again."))))
        precondition(Transcription.failureLine(failed.settings!.parakeet) != nil && failed.offersInstall(recording: false))
        try render(TranscriptionSettingsCard(store: failed, model: model), name: "stt-install-failed", out: out)
        let warming = await store(reply(200, settings: settings {
            for key in ["preview", "hq", "secondOpinion"] { enable(key, key == "preview" ? "parakeet" : "parakeet-ultra")(&$0) }
            choice("preview", selected: "parakeet", effective: "turbo")(&$0)
            parakeet(installed: true, state: "installed", done: 612_000_000, total: 612_000_000, warm: "warming", note: "Parakeet is warming up for previews.")(&$0)
        }))
        precondition(Transcription.previewLine(warming.settings!) != nil)
        try render(TranscriptionSettingsCard(store: warming, model: model), name: "stt-preview-warming", out: out)
        let effective = await store(reply(200, settings: settings {
            for key in ["preview", "hq", "secondOpinion"] { enable(key, key == "preview" ? "parakeet" : "parakeet-ultra")(&$0) }
            choice("hq", selected: "large-v3-legacy", effective: "large-v3")(&$0)
            choice("secondOpinion", selected: "parakeet-ultra", effective: "off")(&$0)
            $0["resolver"] = .object(["enabled": .bool(true), "effective": .bool(false)])
            parakeet(installed: true, state: "installed", done: 612_000_000, total: 612_000_000, warm: "warming")(&$0)
        }))
        precondition(Transcription.resolverInactiveLine(effective.settings!) != nil)
        try render(TranscriptionSettingsCard(store: effective, model: model), name: "stt-effective-differs", out: out)
        let f = await store(reply(404))
        precondition(!f.visible)
        try render(VStack(alignment: .leading, spacing: 14) {
            Text("Harness marker: the card above (Meeting assistant)").font(COSType.body(11)).foregroundStyle(.tertiary)
            TranscriptionSettingsCard(store: f, model: model)
            Text("Harness marker: the next card (Utilities)").font(COSType.body(11)).foregroundStyle(.tertiary)
        }, name: "stt-404-hidden", out: out)
        // 0.5.317 dictation for everyone (server 6.74.0): the Dictation engine, the Parakeet row's reason and action, the
        // menu bar line, the failure card's one action, and the setup guide's engine step.
        func dictated(_ selected: String, effective: String, installed: Bool = false, installable: Bool = true, state: String = "idle",
                      done: Double = 0, errorCode: String? = nil, cliReason: String? = nil, note: String? = nil) -> JSONValue {
            settings { o in
                o["dictation"] = .object(["selected": .string(selected), "effective": .string(effective),
                    "options": .array(["auto", "parakeet-ultra", "whisper"].map { .object(["id": .string($0), "available": .bool($0 != "parakeet-ultra" || installed),
                                                                                         "note": $0 == "parakeet-ultra" && !installed ? .string("Install Parakeet first.") : .null]) })])
                var p: [String: JSONValue] = ["installed": .bool(installed), "installable": .bool(installable), "version": .string("Ultra 95eaa59a, CLI 0.17.4"), "bytes": .number(done),
                    "progress": .object(["state": .string(state), "bytesDone": .number(done), "bytesTotal": .number(654_000_000), "error": .null, "errorCode": errorCode.map(JSONValue.string) ?? .null])]
                if let cliReason { p["cli"] = .object(["trust": .null, "reason": .string(cliReason)]) }
                p["note"] = note.map(JSONValue.string) ?? .null
                o["parakeet"] = .object(p)
            }
        }
        func store317(_ value: JSONValue, free: Int64? = 80_000_000_000) async -> TranscriptionSettingsStore {
            let s = TranscriptionSettingsStore(); s.freeBytes = { free }
            await s.load(answers([reply(200, settings: value)]))
            return s
        }
        let whisperOnly = await store317(dictated("auto", effective: "whisper"))
        precondition(whisperOnly.settings?.dictation != nil && whisperOnly.rowState(recording: false) == .offer(title: Transcription.installTitle, line: nil))
        try render(TranscriptionSettingsCard(store: whisperOnly, model: model), name: "d317-settings-whisper-install", out: out)
        let onParakeet = await store317(dictated("auto", effective: "parakeet-ultra", installed: true, state: "installed", done: 654_000_000))
        try render(TranscriptionSettingsCard(store: onParakeet, model: model), name: "d317-settings-parakeet", out: out)
        let installing317 = try await following(reply(200, settings: dictated("auto", effective: "whisper", state: "downloading", done: 212_000_000)))
        precondition(installing317.offersCancel)
        try render(TranscriptionSettingsCard(store: installing317, model: model), name: "d317-settings-installing-cancel", out: out)
        let untrusted = await store317(dictated("auto", effective: "whisper", installable: false, cliReason: "signature_invalid"))
        try render(TranscriptionSettingsCard(store: untrusted, model: model), name: "d317-settings-untrusted-tool", out: out)
        let lowDisk = await store317(dictated("auto", effective: "whisper"), free: 900_000_000)
        try render(TranscriptionSettingsCard(store: lowDisk, model: model), name: "d317-settings-low-disk", out: out)
        let cancelled = await store317(dictated("auto", effective: "whisper", state: "failed", errorCode: "cancelled"))
        try render(TranscriptionSettingsCard(store: cancelled, model: model), name: "d317-settings-cancelled", out: out)
        let explicitBlocked = await store317(dictated("parakeet-ultra", effective: "none", installable: false, note: "Parakeet Ultra needs Apple silicon."))
        try render(TranscriptionSettingsCard(store: explicitBlocked, model: model), name: "d317-settings-explicit-parakeet-blocked", out: out)
        let oldServer = await store317(settings())
        try render(TranscriptionSettingsCard(store: oldServer, model: model), name: "d317-settings-old-server", out: out)
        try render(PanelParakeetRow(model: model, store: whisperOnly, dictationOn: true), name: "d317-menubar-install", out: out)
        try render(PanelParakeetRow(model: model, store: installing317, dictationOn: true), name: "d317-menubar-installing", out: out)
        // The failure card: one action each (Retry needs held audio, so it is not drawn here).
        let pet = PetSize(preset: .medium, customPixels: PetSize.mediumPixels)
        for (name, reason, action) in [("install", "Parakeet Ultra is not installed on this Mac.", DictationFailureAction.installParakeet),
                                       ("use-whisper", "Parakeet Ultra cannot run right now. Whisper can take this dictation.", .useWhisper),
                                       ("settings", "No speech engine is set up on this Mac. Set one up in Transcription settings.", .openTranscriptionSettings)] {
            let card = DictationCard(kind: .failed(reason, action: action), recordID: nil, text: "", countdown: DictationCountdown(start: Date()))
            try render(DictationCardView(store: model.dictation, card: card, size: pet, reduceMotion: true), name: "d317-card-\(name)", out: out)
        }
        // The setup guide's engine step, before and after a test.
        let guide = SetupGuideState(defaults: UserDefaults(suiteName: "cos-d317-render-\(UUID().uuidString)")!)
        var engineVoice = VoiceFacts(); engineVoice.whisperCli = true; engineVoice.whisperServer = true; engineVoice.whisperReady = true; engineVoice.requestedTier = "balanced"
        engineVoice.adoptTranscription(Data(#"{"preview":{"selected":"turbo","effective":"turbo"},"hq":{"selected":"large-v3","effective":"large-v3"},"parakeet":{"installed":false,"installable":true},"dictation":{"selected":"auto","effective":"whisper"}}"#.utf8))
        guide.voice = engineVoice
        var stepFacts = SetupFacts(); stepFacts.serverRunning = true; stepFacts.voice = engineVoice; stepFacts.appleSilicon = true; stepFacts.memoryBytes = 16 * 1_073_741_824
        stepFacts.serverVersion = "6.74.0"
        let step = SetupGuideRules.dictationEngine(stepFacts, skipped: false)
        let engineModel = ControllerModel(startBackgroundWork: false)
        // The results read Whisper's state from the server's status, as in the app.
        engineModel.status.running = true; engineModel.status.whisperReady = true; engineModel.status.version = "6.74.0"
        await engineModel.transcriptionSettings.load(answers([reply(200, settings: dictated("auto", effective: "whisper"))]))
        try render(SetupRowView(model: engineModel, guide: guide, row: step), name: "d317-setup-engine-step", out: out)
        engineVoice.engineTest = EngineTest(results: [EngineTest.Result(engine: "whisper", ran: true, rtf: 0.08, peakRssBytes: nil, warmupMs: nil, wer: 0, words: 58, skipped: nil),
                                            EngineTest.Result(engine: "parakeet-ultra", ran: false, rtf: nil, peakRssBytes: nil, warmupMs: nil, wer: nil, words: nil, skipped: "not_installed")])
        stepFacts.voice = engineVoice; guide.voice = engineVoice
        try render(SetupRowView(model: engineModel, guide: guide, row: SetupGuideRules.dictationEngine(stepFacts, skipped: false)), name: "d317-setup-engine-tested", out: out)
        // Parakeet installed: untested (Installed and Test), then tested (speed, words, memory, its one-time start).
        var installedVoice = engineVoice
        installedVoice.adoptTranscription(Data(#"{"preview":{"selected":"turbo","effective":"turbo"},"hq":{"selected":"large-v3","effective":"large-v3"},"parakeet":{"installed":true,"installable":true},"dictation":{"selected":"auto","effective":"parakeet-ultra"}}"#.utf8))
        installedVoice.engineTest = nil
        var installedFacts = stepFacts; installedFacts.voice = installedVoice; guide.voice = installedVoice
        await engineModel.transcriptionSettings.load(answers([reply(200, settings: dictated("auto", effective: "parakeet-ultra", installed: true, state: "installed", done: 654_000_000))]))
        try render(SetupRowView(model: engineModel, guide: guide, row: SetupGuideRules.dictationEngine(installedFacts, skipped: false)), name: "d317-setup-engine-installed-untested", out: out)
        installedVoice.engineTest = EngineTest(results: [EngineTest.Result(engine: "whisper", ran: true, rtf: 0.08, peakRssBytes: nil, warmupMs: nil, wer: 0, words: 58, skipped: nil),
                                                         EngineTest.Result(engine: "parakeet-ultra", ran: true, rtf: 0.02, peakRssBytes: 1_200_000_000, warmupMs: 14_000, wer: 0, words: 58, skipped: nil)])
        installedFacts.voice = installedVoice; guide.voice = installedVoice
        try render(SetupRowView(model: engineModel, guide: guide, row: SetupGuideRules.dictationEngine(installedFacts, skipped: false)), name: "d317-setup-engine-parakeet-tested", out: out)
        guide.voice = engineVoice
        var voiceFacts = stepFacts; voiceFacts.dictationCheckAttempted = nil
        try render(SetupRowView(model: engineModel, guide: guide, row: SetupGuideRules.voice(voiceFacts, skipped: false)), name: "d317-setup-voice-checking", out: out)
        for hold in holds { hold.continuation?.resume() }
        print("wrote PNGs to \(out.path)")
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
                .padding(16).frame(width: 390, height: 520, alignment: .top)
                .font(COSType.body(13)).background(COSPalette.panel).cosControlTheme()
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 390, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 390, height: 520)
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
