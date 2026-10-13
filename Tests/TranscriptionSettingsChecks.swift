import Foundation

// Transcription switcher (server 6.72.0): the store against a stand-in helper, fed the contract fixture
// (Tests/fixtures/stt-settings-6.72.0.json, the plan's GET shape). Pins what the Settings card relies on: a 404 hides
// the card, a 400 shows the server's own sentence, every change is ONE partial PUT through `set-stt-settings` with the
// contract's key, an unavailable option cannot be chosen and shows its note, and Install Parakeet POSTs, polls GET until
// installed, and is never offered while a recording is live. No server, helper binary or account.
@main struct TranscriptionSettingsChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) { precondition(value(), name); count += 1 }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: fixtureURL))
        func settings(_ edit: (inout [String: JSONValue]) -> Void = { _ in }) -> JSONValue {
            var object = fixture.object!; edit(&object); return .object(object)
        }
        func reply(_ status: Int, settings: JSONValue? = nil, error: String? = nil, message: String = "Transcription") -> HelperResponse {
            var details: [String: JSONValue] = ["httpStatus": .number(Double(status))]
            if let settings { details["settings"] = settings }
            if let error { details["error"] = .string(error) }
            return HelperResponse(ok: true, message: error ?? message, details: details)
        }
        final class Calls { var log: [(args: [String], body: String?)] = [] }
        func fake(_ calls: Calls, _ answers: [HelperResponse]) -> TranscriptionSettingsStore.Run {
            var queue = answers
            return { args, input in
                let body = input.map { String(decoding: $0, as: UTF8.self) }
                calls.log.append((args, body))
                // An extra call is answered (and logged), not a crash, so the check that counts calls is what fails.
                return queue.isEmpty ? HelperResponse(ok: true, message: "unexpected extra call", details: ["httpStatus": .number(599)]) : queue.removeFirst()
            }
        }

        // 1. A server from before the route answers 404: the card is hidden, never an error, and nothing is sent.
        let old = TranscriptionSettingsStore(); let oldCalls = Calls()
        await old.load(fake(oldCalls, [reply(404, message: "Needs server 6.72.0")]))
        check(oldCalls.log.first?.args == ["stt-settings"] && oldCalls.log.first?.body == nil, "load is a plain GET (`stt-settings`, no stdin)")
        check(old.availability == .unsupported && !old.visible, "404 hides the card")
        check(old.error == nil, "404 is not shown as an error")
        await old.set("hq", .string("parakeet-ultra"), run: fake(oldCalls, [reply(200, settings: settings())]))
        check(oldCalls.log.count == 1, "a hidden card never sends a change")
        check(!old.offersInstall(recording: false), "a hidden card never offers the install")

        // 2. A current server: the card shows the server's selections and options.
        let store = TranscriptionSettingsStore(); let calls = Calls()
        await store.load(fake(calls, [reply(200, settings: settings())]))
        check(store.visible, "a current server shows the card")
        check(store.settings?.preview.selected == "turbo" && store.settings?.hq.selected == "large-v3" && store.settings?.secondOpinion.selected == "off", "selections from GET")
        let preview = Transcription.rows(store.settings!.preview)
        check(preview.map(\.id) == ["turbo", "large-v3", "nemotron-560", "parakeet"], "preview options in server order")
        check(preview[2].enabled == false && preview[2].note == "Not wired on this server yet", "an unavailable option is not choosable and shows its note")
        check(preview[0].enabled && preview[0].note == nil, "an available option shows no note (the face would truncate the name)")
        let advanced = Transcription.rows(store.settings!.frontEnd) + Transcription.rows(store.settings!.quietGate)
        check(advanced.map(\.title) == ["Highpass only", "Full chain", "Speech detector", "Volume threshold"], "Advanced labels when the server sends none")
        check(Transcription.rows(store.settings!.secondOpinion).first?.title == "Off", "Second opinion includes Off")
        check(Transcription.appliesLine(store.settings!) == "Preview changes apply to the next live chunk. HQ changes apply to the next saved meeting.", "appliesTo line")

        // 3. A change is ONE partial PUT with the contract key, and the server's answer becomes what the card shows.
        let changed = settings { $0["hq"] = .object(["selected": .string("large-v3-legacy"), "options": $0["hq"]!.object!["options"]!]) }
        await store.set("hq", .string("large-v3-legacy"), run: fake(calls, [reply(200, settings: changed, message: "Transcription saved")]))
        check(calls.log.last?.args == ["set-stt-settings"], "a change is the PUT command (`set-stt-settings`)")
        check(calls.log.last?.body == #"{"hq":"large-v3-legacy"}"#, "the PUT body is the one changed key")
        check(store.settings?.hq.selected == "large-v3-legacy" && store.pending == nil, "the server's answer is shown")
        await store.set("resolver", .bool(true), run: fake(calls, [reply(200, settings: settings { $0["resolver"] = .object(["enabled": .bool(true)]) })]))
        check(calls.log.last?.body == #"{"resolver":true}"#, "the toggle sends resolver as a bool")
        check(store.settings?.resolverEnabled == true, "resolver on after the answer")

        // 4. A 400 shows the server's sentence inline and keeps the last good settings.
        let refusal = "Parakeet is not installed. Install it on the Mac first."
        await store.set("secondOpinion", .string("parakeet-ultra"), run: fake(calls, [reply(400, error: refusal)]))
        check(calls.log.last?.body == #"{"secondOpinion":"parakeet-ultra"}"#, "the refused choice was what was sent")
        check(store.error == refusal && store.visible, "400 shows the server's message and keeps the card")
        check(store.settings?.secondOpinion.selected == "off", "a refusal does not change the shown choice")

        // 5. Install Parakeet: never while recording; POST then GET until installed, progress from parakeet.bytes.
        check(store.offersInstall(recording: false), "missing and installable: the button is offered")
        check(!store.offersInstall(recording: true), "never offered while a recording is live")
        let before = calls.log.count
        await store.install(fake(calls, []), recording: true)
        check(calls.log.count == before && !store.installing, "a live recording never starts the install")
        func parakeet(_ installed: Bool, _ bytes: Double) -> JSONValue {
            settings { $0["parakeet"] = .object(["installed": .bool(installed), "installable": .bool(true), "version": .string("0.6.3"), "bytes": .number(bytes)]) }
        }
        var progress: [Int] = []
        var pauses = 0
        await store.install(fake(calls, [reply(202, message: "Parakeet install started"), reply(200, settings: parakeet(false, 41_000_000)),
                                         reply(200, settings: parakeet(false, 160_000_000)), reply(200, settings: parakeet(true, 612_000_000))]),
                            recording: false, pause: { _ in pauses += 1; progress.append(store.settings?.parakeet.bytes ?? -1); check(store.installing, "installing while polling") })
        check(calls.log[before].args == ["install-parakeet"] && calls.log[before].body == nil, "install is the POST command (`install-parakeet`), no stdin")
        check(calls.log.dropFirst(before + 1).allSatisfy { $0.args == ["stt-settings"] } && calls.log.count == before + 4, "then GET until installed, and stops")
        check(pauses == 3 && progress == [0, 41_000_000, 160_000_000], "one pause before each poll; bytes seen as progress")
        check(store.settings?.parakeet.installed == true && !store.installing && store.error == nil, "installed, done")
        check(!store.offersInstall(recording: false), "an installed Parakeet is not offered again")
        check(Transcription.installingLine(bytes: 160_000_000) == "Installing Parakeet. 160 MB so far.", "progress line")
        check(Transcription.installedLine(store.settings!.parakeet) == "Parakeet 0.6.3 is installed.", "installed line")

        // 6. The install route refusing shows its sentence and stops; an install that never finishes times out once.
        let fresh = TranscriptionSettingsStore(); let freshCalls = Calls()
        await fresh.load(fake(freshCalls, [reply(200, settings: settings())]))
        await fresh.install(fake(freshCalls, [reply(409, error: "A recording is live. Install Parakeet after it ends.")]), recording: false)
        check(fresh.error == "A recording is live. Install Parakeet after it ends." && freshCalls.log.count == 2, "a refused install shows the server sentence and does not poll")
        let stuck = Array(repeating: reply(200, settings: parakeet(false, 1_000)), count: Transcription.installPollLimit)
        await fresh.install(fake(freshCalls, [reply(202)] + stuck), recording: false, pause: { _ in })
        check(fresh.error == Transcription.installTimedOut && !fresh.installing, "the poll is bounded")

        // 7. A helper failure (server unreachable) is shown once the card is visible.
        let failing: TranscriptionSettingsStore.Run = { _, _ in throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not reach the glasses server."]) }
        await store.set("preview", .string("large-v3"), run: failing)
        check(store.error == "Could not reach the glasses server." && store.visible && store.pending == nil, "unreachable is a sentence in the card")
        for line in [Transcription.installCaption, Transcription.recordingHold, Transcription.installTimedOut, Transcription.appliesLine(store.settings!)] {
            check(!line.contains("\u{2014}") && !line.contains("\u{2192}"), "copy has no em dash or arrow: \(line)")
        }
        print("PASS Transcription settings: \(count) checks")
    }
}
