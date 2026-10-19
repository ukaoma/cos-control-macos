import AppKit
import SwiftUI
import Vision

/// 0.5.322: the Live cues row as drawn, by hand (Tests/run-live-cues.sh render <dir>). The whole app is compiled; a
/// stand-in helper written beside the binary answers `live-cues-settings` from a file this harness rewrites, so nothing
/// reaches the real helper or a server, and all text is invented.
///
///   - the Meeting assistant card at the panel's 390 pt, for every state the row can say, light and dark: a PNG each; what
///     cannot wrap (the switch row, Add a Jev or SubQ key, Check again) measured against the card's inside at 390 pt;
///     and Vision reads each state's line, its button and the glasses app line whole on the pixels (a clipped or
///     truncated line fails);
///   - the whole Settings panel at 390 x 640 with the jump the key button makes (panelScrollTarget = the Decision
///     models anchor): Decision models opens and its Jev key and SubQ key fields are on screen.
///
/// No window is ordered in, no event is sent, nothing becomes active. Prints "live cues render: N passed".
@main @MainActor struct LiveCuesRender {
    static var passed = 0
    static func expect(_ condition: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        guard condition else { print("live cues render FAILED: \(what) \(detail())"); exit(1) }
        passed += 1
    }

    static func shape(enabled: Bool, source: String = "setting", available: Bool, reason: String? = nil,
                      memory: String = "notes", provider: String? = "subq") -> String {
        let why = reason.map { ",\"reason\":\"\($0)\"" } ?? ""
        let decision = provider.map { ",\"decisionProvider\":\"\($0)\"" } ?? ""
        return #"{"ok":true,"message":"x","details":{"transport":"answered","httpStatus":200,"enabled":\#(enabled),"source":"\#(source)","capability":{"available":\#(available)\#(why)\#(decision),"protocol":2,"model":"claude-sonnet-5-5","memory":"\#(memory)"}}}"#
    }
    static func status(_ code: Int, _ extra: String = "") -> String {
        #"{"ok":true,"message":"x","details":{"transport":"answered","httpStatus":\#(code)\#(extra)}}"#
    }

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let stand = FileManager.default.temporaryDirectory.appendingPathComponent("cos-live-cues-stand-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stand, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stand) }
        let helper = stand.appendingPathComponent("helper")
        try """
        #!/bin/sh
        D="$(cd "$(dirname "$0")" && pwd)"
        if [ "$1" = live-cues-settings ] && [ "$2" = --set ]; then f="$D/live-cues-set.json"; else f="$D/$1.json"; fi
        if [ -f "$f" ]; then cat "$f"; printf '\\n'; exit 0; fi
        printf '{"ok":false,"message":"the stand-in does not answer %s","details":{}}\\n' "$1"
        exit 1

        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        func answer(_ text: String?, set: String? = nil) {
            let file = stand.appendingPathComponent("live-cues-settings.json")
            if let text { try? text.write(to: file, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: file) }
            let setFile = stand.appendingPathComponent("live-cues-set.json")
            if let set { try? set.write(to: setFile, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: setFile) }
        }

        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        let store = model.meetingAsk.liveCues
        let run = LiveCuesSettingsRow.run(model)
        // What cannot wrap must fit the card's inside at 390 pt: the panel's 16 pt padding, then the card's 12 pt.
        let inside: CGFloat = 390 - 16 * 2 - 12 * 2
        let controls: [(String, CGFloat)] = [
            ("the switch row", NSHostingView(rootView: Toggle(LiveCues.title, isOn: .constant(true)).toggleStyle(COSSwitchStyle())
                .font(COSType.body(12, weight: .semibold)).fixedSize()).fittingSize.width),
            (LiveCues.addKeyLabel, NSHostingView(rootView: Button(LiveCues.addKeyLabel) {}.buttonStyle(COSTextButtonStyle()).fixedSize()).fittingSize.width),
            (LiveCues.checkAgainLabel, NSHostingView(rootView: Button(LiveCues.checkAgainLabel) {}.buttonStyle(COSQuietButtonStyle()).fixedSize()).fittingSize.width),
            // 0.5.329: the widest limit row, a stepper with the longest title and value.
            (LiveCues.gapTitle, NSHostingView(rootView: COSStepper(LiveCues.gapTitle, value: .constant(3), in: 0...10, valueText: "1.5 min")
                .font(COSType.body(12)).fixedSize()).fittingSize.width),
            (LiveCues.dailyTitle + " locked", NSHostingView(rootView: HStack(spacing: 8) {
                Text(LiveCues.dailyTitle); Text("5000").font(COSType.mono(11.5)); Text(LiveCues.envNote).font(COSType.body(11))
            }.font(COSType.body(12)).fixedSize()).fittingSize.width),
        ]
        for (what, width) in controls {
            expect(width > 20 && width <= inside, "\(what) fits the card at 390 pt", "\(width) of \(inside) pt")
            print("\(what): \(Int(width)) of \(Int(inside)) pt")
        }
        let states: [(String, String?)] = [
            ("on-subq-notes", shape(enabled: true, available: true)),
            ("on-jev-meetings", shape(enabled: true, available: true, memory: "cue_memory", provider: "jev")),
            ("on-conversation-only", shape(enabled: true, available: true, memory: "none", provider: nil)),
            ("off", shape(enabled: false, source: "default", available: false, reason: "master_flag_off")),
            ("env-on", shape(enabled: true, source: "env", available: true)),
            ("env-needs-key", shape(enabled: true, source: "env", available: false, reason: "decision_not_configured")),
            ("needs-key", shape(enabled: true, available: false, reason: "decision_not_configured")),
            ("api-key-in-env", shape(enabled: true, available: false, reason: "api_key_in_env")),
            ("claude-not-found", shape(enabled: true, available: false, reason: "claude_not_found")),
            ("budget-exhausted", shape(enabled: true, available: false, reason: "budget_exhausted")),
            ("jev-cap-reached", shape(enabled: true, available: false, reason: "jev_cap_reached")),
            ("decision-breaker-subq", shape(enabled: true, available: false, reason: "decision_breaker_open")),
            ("unavailable", shape(enabled: true, available: false, reason: "unavailable")),
            ("older-server", status(404)),
            ("unreachable", #"{"ok":true,"message":"x","details":{"transport":"unavailable"}}"#),
            ("reconnect", status(401)),
            ("failed-500", status(500)),
            ("helper-failed", nil),
        ]
        // 0.5.329: the limits under the switch (server 6.79.2), one set from .env.
        let limitsJSON = #","gate":{"value":0.8,"source":"default","locked":false,"bounds":{"min":0.5,"max":0.95,"step":0.05}},"maxCuesPerMeeting":{"value":25,"source":"setting","locked":false,"bounds":{"min":1,"max":25}},"cooldownSeconds":{"value":45,"source":"default","locked":false,"bounds":{"min":0,"max":600}},"dailyWriterCalls":{"value":300,"source":"env","locked":true,"bounds":{"min":0,"max":5000}},"usage":{"writerCalls":12,"writerTokensIn":41200,"writerTokensOut":2900,"cues":7,"jevTokens":9100}}}"#
        let withLimits = String(shape(enabled: true, available: true).dropLast(2)) + limitsJSON
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let theme = appearance == .darkAqua ? "dark" : "light"
            for (name, text) in states {
                answer(text)
                await store.load(run)
                let line = store.line
                try card(model, appearance: appearance, name: "\(name)-\(theme)", out: out, words: [line, LiveCues.glassesLine]
                         + (store.action == .addDecisionKey ? [LiveCues.addKeyLabel] : store.action == .checkAgain ? [LiveCues.checkAgainLabel] : []))
            }
            answer(withLimits)
            await store.load(run)
            expect(store.settings?.limits?.values.count == 4, "the limits fixture reads", store.line)
            try card(model, appearance: appearance, name: "limits-\(theme)", out: out,
                     words: [LiveCues.barTitle, LiveCues.moreCues, LiveCues.fewerCues, "0.80", LiveCues.maxCuesTitle, LiveCues.gapTitle, "45",
                             LiveCues.dailyTitle, LiveCues.envNote, "Today: 7 cues, 12 writer calls, ~44K tokens", LiveCues.glassesLine])
            // The 409: the server's environment holds it on, the row says so and shows the switch held.
            answer(shape(enabled: true, available: true))
            await store.load(run)
            answer(shape(enabled: true, source: "env", available: true), set: status(409, #","error":"env_forced""#))
            await store.set(false, run: run)
            expect(store.note == LiveCues.envForcedNote && store.settings?.locked == true, "409 env_forced in the drawn row", store.line)
            try card(model, appearance: appearance, name: "env-forced-409-\(theme)", out: out, words: [store.line, LiveCues.envForcedNote])
            answer(nil)
            await store.load(run)
        }
        try await jump(model, out: out)
        print("live cues render: \(passed) passed")
        exit(0)
    }

    /// The Meeting assistant card at 390 pt with the panel's 16 pt padding, measured, drawn and read.
    static func card(_ model: ControllerModel, appearance: NSAppearance.Name, name: String, out: URL, words: [String]) throws {
        let view = MeetingAskSettings(store: model.meetingAsk, model: model).padding(16).frame(width: 390, alignment: .top)
        let fit = NSHostingView(rootView: view).fittingSize
        let height = ceil(fit.height) + 8
        let host = NSHostingView(rootView: view.frame(height: height, alignment: .top).background(COSPalette.panel))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 390, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 390, height: height)
        defer { window.close() }
        settle(host, 0.5)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("card-\(name).png"))
        let read = flat(ocr(rep))
        for text in words {
            let want = flat(text)
            expect(read.contains(want), "\(name): reads whole on the pixels: \(text)", "read: \(ocr(rep))")
        }
        print("card \(name): \(Int(fit.width)) x \(Int(fit.height)) pt")
    }

    /// The whole panel at 390 x 640: the key button's jump opens Decision models with both key fields on screen.
    static func jump(_ model: ControllerModel, out: URL) async throws {
        let host = NSHostingView(rootView: ControlPanel(model: model, openActivity: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 390, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua); host.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 390, height: 640)
        defer { window.close() }
        settle(host, 1.0)
        let before = flat(ocr(snapshot(host)))
        expect(!before.contains(flat("Jev key")), "before the jump, Decision models is closed or off screen")
        model.panelScrollTarget = LiveCues.decisionKeysAnchor
        // The panel scrolls in a DispatchQueue.main.async block. This harness runs inside a main-actor job (async main),
        // where a nested run loop cannot drain the main queue, so suspend once to let the block run, as it does in the app.
        settle(host, 0.5)
        try await Task.sleep(nanoseconds: 400_000_000)
        settle(host, 1.0)
        let rep = snapshot(host)
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("panel-after-key-jump-light.png"))
        let after = ocr(rep)
        expect(model.panelScrollTarget == nil, "the panel took the jump")
        expect(flat(after).contains(flat("Decision models")) && flat(after).contains(flat("Jev key")) && flat(after).contains(flat("SubQ key")),
               "after the jump, Decision models is open with the Jev key and SubQ key fields on screen", "read: \(after)")
    }

    static func snapshot(_ host: NSView) -> NSBitmapImageRep {
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    static func settle(_ host: NSView, _ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        host.displayIfNeeded()
    }

    static func ocr(_ rep: NSBitmapImageRep) -> String {
        guard let image = rep.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    /// Letters and digits only, lowercased: Vision's apostrophes, ellipses and line breaks never decide a check.
    static func flat(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
