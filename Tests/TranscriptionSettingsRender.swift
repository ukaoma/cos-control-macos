import AppKit
import SwiftUI

/// Run by hand (Tests/run-transcription-settings-render.sh <folder>): the Settings card "Transcription" drawn off screen,
/// light and dark, at the 390 pt panel width, from the contract fixture (Tests/fixtures/stt-settings-6.72.0.json) through
/// the real store and a stand-in helper. States: Parakeet installed (Advanced open), Parakeet not installed (Install
/// button), installing (progress), not installed during a live recording (no button), a 400 refusal, and a 404 (card
/// hidden, drawn between two harness marker lines so the gap is visible). Windows are never ordered in, the process
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
        let installed = settings {
            $0["secondOpinion"] = .object(["selected": .string("parakeet-ultra"), "options": .array([
                .object(["id": .string("off"), "label": .string("Off"), "available": .bool(true)]),
                .object(["id": .string("parakeet-ultra"), "label": .string("Parakeet"), "available": .bool(true), "note": .string("Runs on this Mac")]),
                .object(["id": .string("large-v3"), "label": .string("Whisper large-v3"), "available": .bool(true)])])])
            $0["resolver"] = .object(["enabled": .bool(true)])
            $0["parakeet"] = .object(["installed": .bool(true), "installable": .bool(true), "version": .string("0.6.3"), "bytes": .number(612_000_000)])
        }
        func store(_ first: HelperResponse) async -> TranscriptionSettingsStore {
            let store = TranscriptionSettingsStore()
            await store.load(answers([first]))
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
        await d.set("secondOpinion", .string("parakeet-ultra"), run: answers([reply(400, error: "Parakeet is not installed yet. Install it on this Mac first, then pick it as the second opinion.")]))
        precondition(d.error != nil && d.visible)
        try render(TranscriptionSettingsCard(store: d, model: model), name: "stt-400", out: out)
        // Installing: the install task is held at its first pause, after the POST and one GET with progress.
        let e = await store(reply(200, settings: settings()))
        final class Hold { var continuation: CheckedContinuation<Void, Never>? }
        let hold = Hold()
        let progress = settings { $0["parakeet"] = .object(["installed": .bool(false), "installable": .bool(true), "version": .string("0.6.3"), "bytes": .number(184_000_000)]) }
        let installTask = Task { @MainActor in
            await e.install(answers([reply(202, settings: progress), reply(200, settings: installed)]), recording: false,
                            pause: { _ in await withCheckedContinuation { hold.continuation = $0 } })
        }
        while hold.continuation == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(e.installing)
        try render(TranscriptionSettingsCard(store: e, model: model), name: "stt-installing", out: out)
        hold.continuation?.resume(); await installTask.value
        let f = await store(reply(404))
        precondition(!f.visible)
        try render(VStack(alignment: .leading, spacing: 14) {
            Text("Harness marker: the card above (Meeting assistant)").font(COSType.body(11)).foregroundStyle(.tertiary)
            TranscriptionSettingsCard(store: f, model: model)
            Text("Harness marker: the next card (Utilities)").font(COSType.body(11)).foregroundStyle(.tertiary)
        }, name: "stt-404-hidden", out: out)
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
