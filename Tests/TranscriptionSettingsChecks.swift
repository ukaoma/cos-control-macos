import Foundation

// Transcription switcher (server 6.72.0): the store against a stand-in helper, fed the contract fixture
// (Tests/fixtures/stt-settings-6.72.0.json, the plan's GET shape). Pins what the Settings card relies on: a 404 hides
// the card, a 400 shows the server's own sentence, every change is ONE partial PUT through `set-stt-settings` with the
// contract's key, an unavailable option cannot be chosen and shows its note, and Install Parakeet POSTs, polls GET until
// installed, and is never offered while a recording is live. No server, helper binary or account.
extension SttSettings {
    func with(effective: Bool) -> SttSettings { var copy = self; copy.resolverEffective = effective; return copy }
}

/// Every store here sees plenty of free disk unless a check says otherwise, so the disk rule never depends on this Mac.
@MainActor func makeStore(free: Int64? = 50_000_000_000) -> TranscriptionSettingsStore {
    let store = TranscriptionSettingsStore(); store.freeBytes = { free }; return store
}

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
        let old = makeStore(); let oldCalls = Calls()
        await old.load(fake(oldCalls, [reply(404, message: "Needs server 6.72.0")]))
        check(oldCalls.log.first?.args == ["stt-settings"] && oldCalls.log.first?.body == nil, "load is a plain GET (`stt-settings`, no stdin)")
        check(old.availability == .unsupported && !old.visible, "404 hides the card")
        check(old.error == nil, "404 is not shown as an error")
        await old.set("hq", .string("parakeet-ultra"), run: fake(oldCalls, [reply(200, settings: settings())]))
        check(oldCalls.log.count == 1, "a hidden card never sends a change")
        check(!old.offersInstall(recording: false), "a hidden card never offers the install")

        // 2. A current server: the card shows the server's selections and options.
        let store = makeStore(); let calls = Calls()
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
        // 0.5.317: the install carries {cliPath} on stdin; a build without the bundled tool sends {} (the server finds its own).
        check(calls.log[before].args == ["install-parakeet"] && calls.log[before].body == "{}", "install is the POST command (`install-parakeet`), {} without a bundled tool")
        check(calls.log.dropFirst(before + 1).allSatisfy { $0.args == ["stt-settings"] } && calls.log.count == before + 4, "then GET until installed, and stops")
        check(pauses == 3 && progress == [0, 41_000_000, 160_000_000], "one pause before each poll; bytes seen as progress")
        check(store.settings?.parakeet.installed == true && !store.installing && store.error == nil, "installed, done")
        check(!store.offersInstall(recording: false), "an installed Parakeet is not offered again")
        check(Transcription.installingLine(bytes: 160_000_000) == "Installing Parakeet. 160 MB so far.", "progress line")
        check(Transcription.installedLine(store.settings!.parakeet) == "Parakeet 0.6.3 is installed.", "installed line")

        // 6. The install route refusing shows its sentence and stops; an install that never finishes times out once.
        let fresh = makeStore(); let freshCalls = Calls()
        await fresh.load(fake(freshCalls, [reply(200, settings: settings())]))
        await fresh.install(fake(freshCalls, [reply(409, error: "A recording is live. Install Parakeet after it is saved.")]), recording: false)
        check(fresh.error == "A recording is live. Install Parakeet after it is saved." && freshCalls.log.count == 2, "a refused install shows the server sentence and does not poll")
        let stuck = Array(repeating: reply(200, settings: parakeet(false, 1_000)), count: Transcription.installPollLimit)
        await fresh.install(fake(freshCalls, [reply(202)] + stuck), recording: false, pause: { _ in })
        check(fresh.error == Transcription.installTimedOut && !fresh.installing, "the poll is bounded")

        // 8. 6.72.0 additions: effective engines, warm state and note, resolver.effective, install progress and states.
        func choice(_ key: String, selected: String, effective: String) -> (inout [String: JSONValue]) -> Void {
            { object in
                var row = object[key]!.object!; row["selected"] = .string(selected); row["effective"] = .string(effective); object[key] = .object(row)
            }
        }
        func progressed(_ state: String, done: Double = 0, total: Double = 0, error: String? = nil, installed: Bool = false) -> JSONValue {
            settings { $0["parakeet"] = .object(["installed": .bool(installed), "installable": .bool(true), "version": .string("0.6.3"), "bytes": .number(done),
                "progress": .object(["state": .string(state), "bytesDone": .number(done), "bytesTotal": .number(total), "error": error.map(JSONValue.string) ?? .null])]) }
        }
        let base = SttSettings(settings())!
        check(Transcription.effectiveLine(base.preview) == nil && Transcription.effectiveLine(base.hq) == nil && Transcription.effectiveLine(base.secondOpinion) == nil,
              "no effective line when effective matches")
        check(base.parakeet.note != nil && Transcription.previewLine(base) == nil, "the Parakeet note only shows while Parakeet is the preview")
        var warming = SttSettings(settings(choice("preview", selected: "parakeet", effective: "turbo")))!
        warming.parakeet.warmPreview = "warming"; warming.parakeet.note = "Parakeet is warming up for previews."
        check(Transcription.previewLine(warming) == "Using Whisper Turbo until Parakeet is ready. Parakeet is warming up for previews.", "warming: effective line and the server note")
        warming.parakeet.note = nil
        check(Transcription.previewLine(warming) == "Using Whisper Turbo until Parakeet is ready. Parakeet is warming up.", "warming without a note: the warm state")
        var waiting = SttSettings(settings(choice("secondOpinion", selected: "parakeet-ultra", effective: "off")))!
        check(Transcription.effectiveLine(waiting.secondOpinion) == "No second opinion until Parakeet is ready.", "second opinion effectively off")
        waiting.resolverEnabled = true; waiting.resolverEffective = false
        check(Transcription.resolverInactiveLine(waiting) == "Not refining until Parakeet is ready.", "resolver inactive reason: waiting for the second opinion")
        var noSecond = base; noSecond.resolverEnabled = true; noSecond.resolverEffective = false
        check(Transcription.resolverInactiveLine(noSecond) == "Not refining: Second opinion is off.", "resolver inactive reason: second opinion off")
        noSecond.resolverEffective = true
        check(Transcription.resolverInactiveLine(noSecond) == nil && Transcription.resolverInactiveLine(base) == nil, "no resolver line when it is refining or off")
        check(Transcription.progressLine(SttSettings(progressed("downloading", done: 184_000_000, total: 612_000_000))!.parakeet) == "Installing Parakeet. 184 of 612 MB.", "progress line X of Y")
        check(Transcription.progressLine(SttSettings(progressed("verifying", done: 612_000_000, total: 612_000_000))!.parakeet) == "Verifying the Parakeet download.", "verifying line")
        check(Transcription.progressLine(SttParakeet(installed: false, installable: true, version: nil, bytes: 41_000_000)) == "Installing Parakeet. 41 MB so far.", "bytes fallback without progress")

        // A failed install stops polling at once and shows the server's plain reason; the button comes back.
        let missing = "Parakeet needs the FluidAudio command line tool 0.17.4 in ~/.cos-glasses/bin. Install it, then try again."
        let failedStore = makeStore(); let failCalls = Calls()
        await failedStore.load(fake(failCalls, [reply(200, settings: settings())]))
        await failedStore.install(fake(failCalls, [reply(202, settings: progressed("downloading", total: 612_000_000)), reply(200, settings: progressed("failed", error: missing))]),
                              recording: false, pause: { _ in })
        check(failCalls.log.count == 3 && !failedStore.installing, "a failed install stops polling")
        check(Transcription.failureLine(failedStore.settings!.parakeet) == missing && failedStore.error == nil, "a failed install shows the server's reason")
        check(failedStore.offersInstall(recording: false), "after a failure the install is offered again")
        // 200 {started:false}: already installed, nothing to follow.
        await failedStore.install(fake(failCalls, [HelperResponse(ok: true, message: "", details: ["httpStatus": .number(200), "started": .bool(false), "settings": progressed("installed", installed: true)])]),
                              recording: false, pause: { _ in })
        check(failCalls.log.count == 4 && failedStore.settings?.parakeet.installed == true, "already installed: no polling")
        // started:false is never followed, even when the settings in it do not say installed.
        let idle = makeStore(); let idleCalls = Calls()
        await idle.load(fake(idleCalls, [reply(200, settings: settings())]))
        await idle.install(fake(idleCalls, [HelperResponse(ok: true, message: "", details: ["httpStatus": .number(200), "started": .bool(false), "settings": settings()])]),
                           recording: false, pause: { _ in })
        check(idleCalls.log.count == 2 && !idle.installing, "started false: no polling")
        // A panel opened while the server installs follows that install, and offers no second one meanwhile.
        let follower = makeStore(); let followCalls = Calls()
        var seen: [Bool] = []
        await follower.load(fake(followCalls, [reply(200, settings: progressed("downloading", done: 10_000_000, total: 612_000_000)),
                                               reply(200, settings: progressed("verifying", done: 612_000_000, total: 612_000_000)),
                                               reply(200, settings: progressed("installed", done: 612_000_000, total: 612_000_000, installed: true))]),
                            pause: { _ in seen.append(follower.showsProgress && !follower.offersInstall(recording: false)) })
        check(followCalls.log.count == 3 && seen == [true, true], "a load during a server install polls until installed")
        check(follower.settings?.parakeet.installed == true && !follower.showsProgress, "followed to installed")
        // The server is still installing but this store stopped following (its read failed): progress still shows and
        // no second install is offered.
        let stalled = makeStore()
        var stalledAnswers = [reply(200, settings: progressed("downloading", done: 10_000_000, total: 612_000_000))]
        await stalled.load({ _, _ in
            if stalledAnswers.isEmpty { throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not reach the glasses server."]) }
            return stalledAnswers.removeFirst()
        }, pause: { _ in })
        check(!stalled.installing && stalled.showsProgress && !stalled.offersInstall(recording: false), "no second install while the server installs")

        // 5. of the additions: PUT hq parakeet-ultra may move the second opinion; the card shows the server's reply.
        let moved = settings { o in
            choice("hq", selected: "parakeet-ultra", effective: "parakeet-ultra")(&o)
            choice("secondOpinion", selected: "large-v3", effective: "large-v3")(&o)
        }
        let mover = makeStore(); let moverCalls = Calls()
        await mover.load(fake(moverCalls, [reply(200, settings: settings(choice("secondOpinion", selected: "parakeet-ultra", effective: "parakeet-ultra")))]))
        await mover.set("hq", .string("parakeet-ultra"), run: fake(moverCalls, [reply(200, settings: moved)]))
        check(moverCalls.log.last?.body == #"{"hq":"parakeet-ultra"}"# && mover.settings?.hq.selected == "parakeet-ultra" && mover.settings?.secondOpinion.selected == "large-v3",
              "the moved second opinion shows after the PUT")

        // 7. A helper failure (server unreachable) is shown once the card is visible.
        let failing: TranscriptionSettingsStore.Run = { _, _ in throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not reach the glasses server."]) }
        await store.set("preview", .string("large-v3"), run: failing)
        check(store.error == "Could not reach the glasses server." && store.visible && store.pending == nil, "unreachable is a sentence in the card")
        for line in [Transcription.installCaption, Transcription.recordingHold, Transcription.installTimedOut, Transcription.appliesLine(store.settings!),
                     Transcription.progressLine(SttSettings(progressed("verifying"))!.parakeet), Transcription.resolverInactiveLine(noSecond.with(effective: false)) ?? "",
                     Transcription.effectiveLine(waiting.secondOpinion) ?? "", Transcription.previewLine(warming) ?? ""] {
            check(!line.contains("\u{2014}") && !line.contains("\u{2192}"), "copy has no em dash or arrow: \(line)")
        }
        check(!Transcription.failureLine(SttSettings(progressed("failed"))!.parakeet)!.contains("\u{2014}"), "fallback failure line has no em dash")

        // 9. 0.5.317 (server 6.74.0): the Dictation engine, the Parakeet row's reason and action, the bundled tool,
        // the disk floor, Cancel, and the install's new refusals.
        func dictated(_ selected: String, effective: String, note: String? = nil, installed: Bool = false, installable: Bool = true,
                      errorCode: String? = nil, state: String = "idle", cliReason: String? = nil, parakeetNote: String? = nil) -> JSONValue {
            settings { o in
                var desktop: [String: JSONValue] = ["selected": .string(selected), "effective": .string(effective),
                    "options": .array(["auto", "parakeet-ultra", "whisper"].map { .object(["id": .string($0), "available": .bool($0 != "parakeet-ultra" || installed),
                                                                                         "note": $0 == "parakeet-ultra" && !installed ? .string("Install Parakeet first.") : .null]) })]
                if let note { desktop["note"] = .string(note) }
                o["dictation"] = .object(desktop)
                var parakeet: [String: JSONValue] = ["installed": .bool(installed), "installable": .bool(installable), "version": .string("Ultra 95eaa59a, CLI 0.17.4"), "bytes": .number(0),
                    "progress": .object(["state": .string(state), "bytesDone": .number(0), "bytesTotal": .number(654_000_000), "error": .null, "errorCode": errorCode.map(JSONValue.string) ?? .null])]
                if let cliReason { parakeet["cli"] = .object(["trust": .null, "reason": .string(cliReason)]) }
                parakeet["note"] = parakeetNote.map(JSONValue.string) ?? .null
                o["parakeet"] = .object(parakeet)
            }
        }
        let v2 = SttSettings(dictated("auto", effective: "whisper"))!
        check(v2.dictation?.selected == "auto" && v2.dictation?.effective == "whisper", "dictation.desktop is read when the server sends it")
        check(SttSettings(settings())?.dictation == nil, "a 6.73.14 answer (no dictation) still reads, as Parakeet-only dictation")
        check(Transcription.dictationLine(SttSettings(settings())!) == Transcription.dictationOldServer, "an older server says dictation is Parakeet only")
        let rows = Transcription.dictationRows(v2.dictation!)
        check(rows.map(\.title) == ["Automatic (recommended)", "Parakeet Ultra", "Whisper"], "engine picker names: Automatic (recommended), Parakeet Ultra, Whisper")
        check(rows[1].enabled == false && rows[1].note == "Install Parakeet first.", "an uninstalled Parakeet is not choosable and says why")
        check(Transcription.dictationLine(v2) == "Dictation uses Whisper until Parakeet Ultra is installed.", "Automatic on Whisper says why")
        check(Transcription.dictationLine(SttSettings(dictated("auto", effective: "whisper", note: "Parakeet Ultra is warming up. Whisper takes dictation meanwhile."))!)
              == "Parakeet Ultra is warming up. Whisper takes dictation meanwhile.", "the server's note reaches the screen verbatim")
        check(Transcription.dictationLine(SttSettings(dictated("auto", effective: "parakeet-ultra", installed: true))!) == "Dictation uses Parakeet Ultra on this Mac.", "Parakeet in use")
        // The row: never greyed out without a reason and an action.
        check(Transcription.parakeetState(v2, installing: false, recording: false, freeBytes: 50_000_000_000) == .offer(title: "Install Parakeet (654 MB)", line: nil),
              "missing and installable: Install Parakeet (654 MB)")
        check(Transcription.parakeetState(v2, installing: false, recording: false, freeBytes: 900_000_000) == .blocked(reason: Transcription.diskLine(free: 900_000_000), action: .checkAgain),
              "under 1.5 GB free: the reason and Check again, before anything downloads")
        check(Transcription.diskLine(free: 900_000_000) == "Parakeet needs 1.5 GB free; 900 MB is free. Free some space, then check again.", "disk line")
        check(Transcription.parakeetState(v2, installing: false, recording: true, freeBytes: nil) == .blocked(reason: Transcription.recordingHold, action: .afterRecording), "recording: says when")
        let untrusted = SttSettings(dictated("auto", effective: "whisper", installable: false, cliReason: "wrong_team"))!
        check(Transcription.parakeetState(untrusted, installing: false, recording: false, freeBytes: nil)
              == .blocked(reason: "COS Control's speech tool does not match this server. Update COS Control, then check again.", action: .checkAgain), "an untrusted tool: its reason and Check again")
        let noted = SttSettings(dictated("parakeet-ultra", effective: "none", installable: false, parakeetNote: "Parakeet Ultra needs Apple silicon."))!
        check(Transcription.parakeetState(noted, installing: false, recording: false, freeBytes: nil) == .blocked(reason: "Parakeet Ultra needs Apple silicon.", action: .useWhisper),
              "explicit Parakeet that cannot install: the server's note and Use Whisper")
        let cancelledRow = SttSettings(dictated("auto", effective: "whisper", errorCode: "cancelled", state: "failed"))!
        check(Transcription.parakeetState(cancelledRow, installing: false, recording: false, freeBytes: nil)
              == .offer(title: "Install Parakeet (654 MB)", line: "Install cancelled. Nothing was kept, and dictation keeps using Whisper."), "cancelled: says nothing was kept, offers the install again")
        let corrupt = SttSettings(dictated("auto", effective: "whisper", errorCode: "sha_mismatch", state: "failed"))!
        check(Transcription.parakeetState(corrupt, installing: false, recording: false, freeBytes: nil)
              == .offer(title: "Try again", line: "A downloaded file did not match its checksum, so nothing was installed. Try again."), "a SHA mismatch: its reason and Try again")
        check(Transcription.parakeetState(SttSettings(dictated("auto", effective: "whisper", state: "downloading"))!, installing: false, recording: false, freeBytes: nil)
              == .installing("Installing Parakeet. 0.0 of 654 MB."), "installing on the server: progress")
        check(Transcription.parakeetState(SttSettings(dictated("auto", effective: "parakeet-ultra", installed: true))!, installing: false, recording: false, freeBytes: nil)
              == .installed("Parakeet Ultra 95eaa59a, CLI 0.17.4 is installed."), "installed")
        // The store: the bundled tool's path rides on stdin, the disk floor refuses before the POST, 507 and 422 say why.
        let bundled = makeStore(); let bundledCalls = Calls()
        bundled.cliPath = { "/Applications/COS Control.app/Contents/Helpers/fluidaudiocli" }
        await bundled.load(fake(bundledCalls, [HelperResponse(ok: true, message: "Speech tool trusted", details: ["httpStatus": .number(200), "trusted": .bool(true)]), reply(200, settings: dictated("auto", effective: "whisper"))]))
        check(bundledCalls.log.map(\.args) == [["register-parakeet-cli"], ["stt-settings"]] && bundledCalls.log[0].body == #"{"cliPath":"\/Applications\/COS Control.app\/Contents\/Helpers\/fluidaudiocli"}"#,
              "the first read of a launch registers the bundled tool, path on stdin")
        check(bundled.cliTrusted == true, "the server's trust answer is kept")
        await bundled.load(fake(bundledCalls, [reply(200, settings: dictated("auto", effective: "whisper"))]))
        check(bundledCalls.log.count == 3, "registered once per launch, not on every read")
        await bundled.install(fake(bundledCalls, [reply(202, settings: dictated("auto", effective: "whisper", state: "downloading")),
                                                 reply(200, settings: dictated("auto", effective: "parakeet-ultra", installed: true, state: "installed"))]), recording: false, pause: { _ in })
        check(bundledCalls.log[3].args == ["install-parakeet"] && bundledCalls.log[3].body == #"{"cliPath":"\/Applications\/COS Control.app\/Contents\/Helpers\/fluidaudiocli"}"#, "install passes the bundled tool's path")
        check(bundled.settings?.parakeet.installed == true && bundled.settings?.dictation?.effective == "parakeet-ultra", "installed, and the next dictation uses Parakeet")
        let low = makeStore(free: 700_000_000); let lowCalls = Calls()
        await low.load(fake(lowCalls, [reply(200, settings: dictated("auto", effective: "whisper"))]))
        await low.install(fake(lowCalls, []), recording: false)
        check(lowCalls.log.count == 1 && low.error == Transcription.diskLine(free: 700_000_000) && !low.installing, "too little disk: refused before any request, with the reason")
        let full = makeStore(); let fullCalls = Calls()
        await full.load(fake(fullCalls, [reply(200, settings: dictated("auto", effective: "whisper"))]))
        await full.install(fake(fullCalls, [HelperResponse(ok: true, message: "", details: ["httpStatus": .number(507), "reason": .string("insufficient_disk"), "freeBytes": .number(1_200_000_000)])]), recording: false)
        check(full.error == Transcription.diskLine(free: 1_200_000_000) && fullCalls.log.count == 2, "the server's 507 says how much is free, and stops")
        await full.install(fake(fullCalls, [HelperResponse(ok: true, message: "", details: ["httpStatus": .number(422), "reason": .string("cli_untrusted"), "cliReason": .string("unsigned")])]), recording: false)
        check(full.error == Transcription.cliLine("unsigned") && fullCalls.log.count == 3, "422 cli_untrusted names the tool's problem")
        // Cancel: a DELETE while the install runs; the server's cancelled state ends the poll and Install comes back.
        let canceller = makeStore(); let cancelCalls = Calls()
        await canceller.load(fake(cancelCalls, [reply(200, settings: dictated("auto", effective: "whisper"))]))
        var cancelOffered = false
        await canceller.install(fake(cancelCalls, [reply(202, settings: dictated("auto", effective: "whisper", state: "downloading")),
                                                   reply(200, settings: dictated("auto", effective: "whisper", errorCode: "cancelled", state: "failed"), message: "Parakeet install cancelled"),
                                                   reply(200, settings: dictated("auto", effective: "whisper", errorCode: "cancelled", state: "failed"))]),
                                recording: false, pause: { _ in
                                    cancelOffered = canceller.offersCancel
                                    await canceller.cancelInstall(fake(cancelCalls, [reply(200, settings: dictated("auto", effective: "whisper", errorCode: "cancelled", state: "failed"), message: "Parakeet install cancelled")]))
                                })
        check(cancelOffered, "Cancel is offered while the install runs")
        check(cancelCalls.log.contains { $0.args == ["cancel-parakeet-install"] }, "Cancel is the DELETE command (`cancel-parakeet-install`)")
        check(!canceller.installing && canceller.settings?.parakeet.cancelled == true && canceller.offersInstall(recording: false), "after Cancel, nothing installs and Install is offered again")
        // Use Whisper is one PUT of the dictation key.
        await canceller.set("dictation", .string("whisper"), run: fake(cancelCalls, [reply(200, settings: dictated("whisper", effective: "whisper"))]))
        check(cancelCalls.log.last?.args == ["set-stt-settings"] && cancelCalls.log.last?.body == #"{"dictation":"whisper"}"#, "the engine pick is one PUT of `dictation`")
        for line in [Transcription.installTitle, Transcription.dictationCaption, Transcription.dictationOldServer, Transcription.licensesLine,
                     Transcription.diskLine(free: 1), Transcription.cliLine("missing")!, Transcription.cliLine("unsigned")!, Transcription.cliLine("wrong_team")!,
                     Transcription.installFailureLine(cancelledRow.parakeet)!, Transcription.installFailureLine(corrupt.parakeet)!, Transcription.dictationLine(v2)] {
            check(!line.contains("\u{2014}") && !line.contains("\u{2192}") && !line.contains("->"), "0.5.317 copy has no em dash or arrow: \(line)")
        }
        print("PASS Transcription settings: \(count) checks")
    }
}
