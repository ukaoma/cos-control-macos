import Foundation
import Darwin

/// Pure fixture audio bytes only. Never opens a tap, microphone, socket, or permission prompt.
@main struct MacRecordingChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("cos-mac-spool-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        check(MacAudioRing.defaultCapacity >= MacAudioRing.maximumSampleRate * MacAudioRing.bytesPerFrame * MacAudioRing.bufferedSeconds, "buffer covers the highest supported input rate")
        let pattern = Data((0..<64).map { UInt8($0) })
        for start in [UInt32(0), UInt32(Int32.max) - 3, UInt32.max - 15] {
            let ring = MacAudioRing(capacity: 64, initialCursor: start)
            for _ in 0..<1000 {
                check(pattern.withUnsafeBytes { ring.push(bytes: $0.baseAddress!, count: 48) }, "producer publishes bounded bytes")
                check(ring.pop(maximumBytes: 28) == pattern.prefix(28), "consumer reads the published prefix across cursor wrap")
                check(ring.pop() == pattern.subdata(in: 28..<48), "wrapped tail preserves exact byte order")
                check(ring.pop() == nil && ring.interruption == nil, "drained ring remains healthy")
            }
        }
        let full = MacAudioRing(capacity: 64)
        check(pattern.withUnsafeBytes { full.push(bytes: $0.baseAddress!, count: 64) }, "exact capacity is accepted")
        check(!pattern.withUnsafeBytes { full.push(bytes: $0.baseAddress!, count: 4) }, "actual overflow is refused")
        check(full.interruption != nil && full.pop() == pattern, "overflow retains previously accepted bytes")
        let malformedRing = MacAudioRing(capacity: 64)
        check(!pattern.withUnsafeBytes { malformedRing.push(bytes: $0.baseAddress!, count: 3) }, "partial float frame is refused")
        check(malformedRing.interruption?.contains("format") == true, "format failures are distinct from buffer capacity")
        // Concurrent copy/publication with no possibility of genuine capacity exhaustion:
        // all fixture bytes fit even if the consumer is descheduled until the producer ends.
        let concurrent = MacAudioRing(capacity: 1 << 20)
        let payload = Data(repeating: 0x6d, count: 512)
        let producer = Task.detached {
            for _ in 0..<1024 { precondition(payload.withUnsafeBytes { concurrent.push(bytes: $0.baseAddress!, count: $0.count) }) }
        }
        let consumer = Task.detached { () -> Int in
            var received = 0
            while received < 512 * 1024 {
                if let data = concurrent.pop(maximumBytes: 252) {
                    precondition(data.allSatisfy { $0 == 0x6d }); received += data.count
                } else { await Task.yield() }
            }
            return received
        }
        await producer.value
        let received = await consumer.value
        check(received == 512 * 1024 && concurrent.interruption == nil && concurrent.pop() == nil, "concurrent producer and consumer neither lose bytes nor report false overflow")
        for noSpeech in [false, true] {
            for paused in [false, true] {
                for pending in [false, true] {
                    for stopped in [false, true] {
                        for delivering in [false, true] {
                            let permitted = MacRecordingRecoveryPolicy.canKeepForLater(noSpeech: noSpeech, paused: paused, pending: pending, stopped: stopped, delivering: delivering)
                            check(permitted == (paused && !noSpeech && pending && stopped && !delivering),
                                  "Keep audio for later only for a paused delivery, never for no speech (Discard is offered there), with no delivery in flight")
                        }
                    }
                }
            }
        }
        // QA 0.5.313: a stop nobody made says so outside the panel, in the panel's own words.
        let limitNote = MacRecordingInterruption.notification(MacRecordingInterruption.pilotLimit)
        check(limitNote.title == "Mac recording stopped" && limitNote.body.hasPrefix(MacRecordingInterruption.line(MacRecordingInterruption.pilotLimit).text)
              && limitNote.body.hasSuffix("start a new recording."), "the two-hour stop notification reads as kept, and says to start again")
        check(MacRecordingInterruption.notification("slept").body.hasPrefix("Incomplete recording: slept"), "any other stop names its reason")
        // 2026-10-15: a Vorssaint tap stored 22 chunks of exact zeros and the panel still read "22/22 received".
        func pcm16(_ samples: [Int16]) -> Data { samples.withUnsafeBufferPointer { Data(buffer: $0) } }
        let zeros = Data(repeating: 0, count: MacRecordingWAV.framesPerChunk * 2)
        check(MacRecordingSignal.isSilent(zeros) && MacRecordingSignal.peak(zeros) == 0, "digital silence is silent")
        check(MacRecordingSignal.isSilent(pcm16([Int16](repeating: 63, count: 1000))), "below the floor is silent")
        check(!MacRecordingSignal.isSilent(pcm16([Int16](repeating: 0, count: 999) + [64])), "one sample at the floor is sound")
        check(MacRecordingSignal.peak(pcm16([0, Int16.min, 5])) == 32_768, "full-scale negative peak does not overflow")
        check(MacRecordingSignal.peak(pcm16([0, -20_000, 19_987])) == 20_000, "peak is absolute")
        check(MacRecordingSignal.warning(silentChunks: MacRecordingSignal.warnAfterSilentChunks - 1, source: "Vorssaint") == nil, "a single quiet chunk is a pause, not a warning")
        let warnSeconds = MacRecordingSignal.warnAfterSilentChunks * MacRecordingWAV.framesPerChunk / MacRecordingWAV.sampleRate
        let appWarning = MacRecordingSignal.warning(silentChunks: MacRecordingSignal.warnAfterSilentChunks, source: "Vorssaint")
        check(appWarning?.contains("Vorssaint for \(warnSeconds)s") == true, "warning names the source and the silent span")
        check(appWarning?.contains("record All Mac audio") == true, "an app source is pointed at All Mac audio")
        let allWarning = MacRecordingSignal.warning(silentChunks: MacRecordingSignal.warnAfterSilentChunks, source: MacAudioSource.allMacAudio.name)
        check(allWarning != nil && allWarning?.contains("record All Mac audio") == false, "All Mac audio is never told to switch to itself")
        check(allWarning?.contains("not muted") == true, "All Mac audio points at the call's own output")
        // 2026-10-15: a stopped capture with 51/1,200 delivered still read "Live now".
        // 0.5.351 (quick save): an ordinary save is "Saving…" with no counter; the count shows once it is slow.
        check(MacRecordingLiveRow.label(stopped: true, saved: false, acknowledged: 51, chunks: 1_200) == "Saving…", "a stopped, unsaved capture says Saving…, no counter")
        check(MacRecordingLiveRow.label(stopped: true, saved: false, acknowledged: 51, chunks: 1_200, slow: true) == "Saving · 51 of 1200 audio chunks sent", "a slow save shows how far it got")
        check(MacRecordingLiveRow.label(stopped: false, saved: false, acknowledged: 51, chunks: 60) == nil, "a running capture stays Live now")
        check(MacRecordingLiveRow.label(stopped: true, saved: true, acknowledged: 60, chunks: 60) == nil, "a saved capture leaves the row to the saved hand-off")
        // 0.5.310: delivery stopped on an error; the row must not claim it is still saving.
        check(MacRecordingLiveRow.label(stopped: true, saved: false, acknowledged: 51, chunks: 1_200, paused: true) == "Not saved yet · 51 of 1200 audio chunks reached COS", "a paused delivery says not saved, with progress")
        check(MacRecordingLiveRow.label(stopped: true, saved: false, acknowledged: 51, chunks: 1_200, paused: true, slow: true) == "Not saved yet · 51 of 1200 audio chunks reached COS", "paused wins over slow")
        check(MacRecordingLiveRow.label(stopped: false, saved: false, acknowledged: 51, chunks: 60, paused: true) == nil, "a running capture stays Live now even while delivery is paused")
        check(MacRecordingLiveRow.label(stopped: true, saved: true, acknowledged: 60, chunks: 60, paused: true) == nil, "a saved capture is never shown as paused")
        check(MacAudioSource.allMacAudio.isAllMacAudio && MacAudioSource.allMacAudio.id == UInt32.max, "All Mac audio is a fixed sentinel")
        check(!MacAudioSource(id: 7, pid: 1, bundleID: "x", name: "App").isAllMacAudio, "an app source is never the system mix")
        let normalRoot = fm.homeDirectoryForCurrentUser.appendingPathComponent("cos-data/mac-recordings")
        check(MacRecordingSpool.defaultRoot(environment: [:]) == normalRoot, "production keeps the user's recording directory")
        check(MacRecordingSpool.defaultRoot(environment: ["COS_CONTROL_TEST_HOME": "/Users/other"]) == normalRoot, "non-temporary override is ignored")
        check(MacRecordingSpool.defaultRoot(environment: ["COS_CONTROL_TEST_HOME": "/tmp/../../Users/other"]) == normalRoot, "escaping temporary override is ignored")
        let canaryRoot = MacRecordingSpool.defaultRoot(environment: ["COS_CONTROL_TEST_HOME": "/tmp/cos-signed-mac-canary/home"])
        check(canaryRoot.path == "/private/tmp/cos-signed-mac-canary/home/cos-data/mac-recordings", "signed canary spool shares the isolated helper home")
        let gate = MacRecordingStopGate()
        var releaseFlush: CheckedContinuation<Void, Never>?
        var starts = 0, firstFinished = false, quitFinished = false
        let firstStop = Task { await gate.run { starts += 1; await withCheckedContinuation { releaseFlush = $0 } }; firstFinished = true }
        for _ in 0..<1000 { if releaseFlush != nil { break }; await Task.yield() }
        check(releaseFlush != nil, "first Stop begins asynchronous flush")
        let quit = Task { await gate.run { starts += 1 }; quitFinished = true }
        for _ in 0..<10 { await Task.yield() }
        check(starts == 1 && !firstFinished && !quitFinished, "quit awaits existing Stop without starting duplicate teardown")
        releaseFlush?.resume(); await firstStop.value; await quit.value
        check(firstFinished && quitFinished && starts == 1, "all Stop callers complete only after local flush")
        await gate.run { starts += 1 }
        check(starts == 2, "later recording can use Stop gate again")
        func rejects(_ name: String, _ action: () async throws -> Void) async {
            do { try await action(); preconditionFailure(name) } catch { checks += 1 }
        }
        func manifest(_ n: Int) -> MacRecordingManifest {
            MacRecordingManifest(captureId: String(format: "mac_%08d-1234-1234-1234-123456789abc", n), startTime: 1_792_026_000_000 + Double(n), serverInstanceId: "fixture-server", sourceName: "Fixture app", title: "Fixture recording", stopped: false, saved: false, acknowledged: 0, chunks: [])
        }
        let pcm = Data(repeating: 0, count: 32_000)
        let wav = try MacRecordingWAV.encode(pcm)
        check(wav.count == pcm.count + 44 && String(data: wav.prefix(4), encoding: .ascii) == "RIFF", "canonical WAV header and exact size")
        await rejects("empty WAV rejected") { _ = try MacRecordingWAV.encode(Data()) }
        await rejects("odd PCM rejected") { _ = try MacRecordingWAV.encode(Data([0])) }
        await rejects("WAV over 30 seconds rejected") { _ = try MacRecordingWAV.encode(Data(repeating: 0, count: 960_002)) }
        let root = scratch.appendingPathComponent("recordings")
        let spool = MacRecordingSpool(root: root)
        let initial = manifest(1)
        try await spool.write(initial)
        await rejects("nonconsecutive chunk rejected") { _ = try await spool.append(.init(index: 1, pcm: pcm, endFrame: 16_000), captureId: initial.id) }
        await rejects("endFrame must match PCM frames") { _ = try await spool.append(.init(index: 0, pcm: pcm, endFrame: 15_999), captureId: initial.id) }
        let appended = try await spool.append(.init(index: 0, pcm: pcm, endFrame: 16_000), captureId: initial.id)
        check(appended.chunks.count == 1 && appended.chunks[0].endFrame == 16_000, "journal advances exact frame count")
        // 0.5.336: the grey line's preview WAV, beside the chunks and never in the journal.
        let previewPath = try await spool.writePreview(pcm, captureId: initial.id)
        check(previewPath.hasSuffix("/" + MacRecordingSpool.previewFilename) && (try? Data(contentsOf: URL(fileURLWithPath: previewPath))) == wav,
              "preview WAV canonical, beside the chunks")
        let previewRecovery = MacRecordingSpool(root: root)
        let previewRecoverable = try await previewRecovery.recoverable().map(\.id)
        let previewWarnings = await previewRecovery.recoveryWarnings()
        check(previewRecoverable == [initial.id] && previewWarnings.isEmpty, "a preview WAV is never audio outside the journal")
        check(try await spool.snapshot(initial.id).chunks.count == 1, "the preview never enters the journal")
        _ = try await spool.writePreview(pcm + pcm, captureId: initial.id)
        check((try? Data(contentsOf: URL(fileURLWithPath: previewPath)))?.count == pcm.count * 2 + 44, "the next preview replaces the last")
        await spool.removePreview(captureId: initial.id)
        check(!fm.fileExists(atPath: previewPath), "the preview WAV is removed after its post")
        await spool.removePreview(captureId: initial.id)
        await rejects("a preview over 15 s refused") { _ = try await spool.writePreview(Data(count: LiveMeetingPreviewLimit.maximumBytes + 2), captureId: initial.id) }
        await rejects("an empty preview refused") { _ = try await spool.writePreview(Data(), captureId: initial.id) }
        await rejects("an odd preview refused") { _ = try await spool.writePreview(Data([0, 0, 0]), captureId: initial.id) }
        check(LiveMeetingPreviewLimit.maximumBytes == 480_000, "the preview ceiling is 15 s")
        let squares: [Float] = [0.5, -0.5, .nan, .infinity, 0]
        check(squares.withUnsafeBufferPointer { MacRecordingSignal.sumOfSquares($0) } == 0.5, "the audiogram's sum of squares skips NaN and infinity")
        let audioURL = URL(fileURLWithPath: try await spool.path(for: appended.chunks[0], captureId: initial.id))
        check(try Data(contentsOf: audioURL) == wav, "disk audio canonical and unchanged")
        for url in [root, root.appendingPathComponent(initial.id), audioURL, audioURL.deletingLastPathComponent().appendingPathComponent("manifest.json")] {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            check((attributes[.posixPermissions] as! NSNumber).intValue & 0o077 == 0, "private spool permissions")
        }
        await rejects("cannot save pending audio") { _ = try await spool.markSaved(initial.id) }
        let acknowledged = try await spool.acknowledge(initial.id, index: 0)
        check(acknowledged.acknowledged == 1 && acknowledged.chunks.count == 1, "acknowledgement preserves captured journal")
        await rejects("duplicate ack rejected") { _ = try await spool.acknowledge(initial.id, index: 0) }
        _ = try await spool.markStopped(initial.id)
        await rejects("a stopped capture takes no preview") { _ = try await spool.writePreview(pcm, captureId: initial.id) }
        await rejects("stopped capture cannot append") { _ = try await spool.append(.init(index: 1, pcm: pcm, endFrame: 32_000), captureId: initial.id) }
        _ = try await spool.markSaved(initial.id)
        await rejects("saved capture cannot append") { _ = try await spool.append(.init(index: 1, pcm: pcm, endFrame: 32_000), captureId: initial.id) }
        let reopened = MacRecordingSpool(root: root)
        check(try await reopened.snapshot(initial.id).saved, "saved state survives restart")
        check(try await reopened.recoverable().isEmpty, "saved captures excluded from recovery")
        let healthy = manifest(2)
        try await spool.write(healthy)
        _ = try await spool.append(.init(index: 0, pcm: pcm, endFrame: 16_000), captureId: healthy.id)
        let corrupt = manifest(3)
        try await spool.write(corrupt)
        let corruptFile = root.appendingPathComponent(corrupt.id).appendingPathComponent("manifest.json")
        try Data("broken json".utf8).write(to: corruptFile)
        let recovered = MacRecordingSpool(root: root)
        check(try await recovered.recoverable().map(\.id) == [healthy.id], "one corrupt journal cannot hide healthy recovery")
        check(await recovered.recoveryWarnings().count == 1, "corrupt recovery is reported")
        let interrupted = try await spool.interrupt(healthy.id, reason: "Fixture interruption\n" + String(repeating: "x", count: 300))
        check(interrupted.interruption?.count == 256 && interrupted.interruption?.contains("\n") == false, "interruption is bounded and persisted")
        _ = try await spool.interrupt(healthy.id, reason: "Replacement reason")
        check(try await MacRecordingSpool(root: root).snapshot(healthy.id).interruption == interrupted.interruption, "first interruption survives restart and retries")
        let orphan = root.appendingPathComponent(healthy.id).appendingPathComponent("000001.wav")
        try wav.write(to: orphan); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: orphan.path)
        let orphanRecovery = MacRecordingSpool(root: root)
        let orphanManifests = try await orphanRecovery.recoverable()
        check(orphanManifests.first?.chunks.count == 1, "orphan WAV never guessed into journal")
        check(await orphanRecovery.recoveryWarnings().count == 2 && fm.fileExists(atPath: orphan.path), "orphan audio retained and warning reported alongside corrupt journal")
        let oversized = manifest(4)
        try await spool.write(oversized)
        let oversizedFile = root.appendingPathComponent(oversized.id).appendingPathComponent("manifest.json")
        try Data(repeating: 32, count: 512_001).write(to: oversizedFile)
        await rejects("bounded journal reads") { _ = try await MacRecordingSpool(root: root).snapshot(oversized.id) }
        let linked = manifest(5)
        try await spool.write(linked)
        let linkedFile = root.appendingPathComponent(linked.id).appendingPathComponent("manifest.json")
        try fm.removeItem(at: linkedFile)
        try fm.createSymbolicLink(at: linkedFile, withDestinationURL: oversizedFile)
        await rejects("journal symlink refused") { _ = try await MacRecordingSpool(root: root).snapshot(linked.id) }
        let hardlinked = manifest(6)
        try await spool.write(hardlinked)
        let hardFile = root.appendingPathComponent(hardlinked.id).appendingPathComponent("manifest.json")
        let hardCopy = scratch.appendingPathComponent("copied-manifest.json")
        try fm.linkItem(at: hardFile, to: hardCopy)
        await rejects("journal hardlink refused") { _ = try await MacRecordingSpool(root: root).snapshot(hardlinked.id) }
        let aliasedRoot = scratch.appendingPathComponent("root-link")
        try fm.createSymbolicLink(at: aliasedRoot, withDestinationURL: root)
        await rejects("root symlink refused") { try await MacRecordingSpool(root: aliasedRoot).write(manifest(7)) }
        let aliasedCapture = manifest(8)
        try fm.createSymbolicLink(at: root.appendingPathComponent(aliasedCapture.id), withDestinationURL: root.appendingPathComponent(healthy.id))
        await rejects("capture directory symlink refused") { try await spool.write(aliasedCapture) }
        let publicRoot = scratch.appendingPathComponent("public-root")
        try fm.createDirectory(at: publicRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        await rejects("shared storage refused") { try await MacRecordingSpool(root: publicRoot).write(manifest(9)) }
        var unsafe = manifest(10); unsafe.acknowledged = -1
        await rejects("negative ack rejected") { try await spool.write(unsafe) }
        var malformed = manifest(11); malformed.chunks = [.init(index: 0, filename: "../outside.wav", endFrame: 16_000)]
        await rejects("journal traversal filename rejected") { try await spool.write(malformed) }
        var title = manifest(12); title.title = String(repeating: "a", count: 161)
        await rejects("title matches helper bound") { try await spool.write(title) }
        do { // 0.5.313 meeting detection; own scope
            func app(_ bundle: String) -> String? { MeetingApps.rule(forBundleID: bundle).map { $0.app.rawValue + ":" + $0.owner } }
            check(app("us.zoom.xos") == "zoom:us.zoom.xos" && app("us.zoom.CptHost") == "zoom:us.zoom.xos", "Zoom and its CptHost helper")
            check(app("com.microsoft.teams2") == "teams:com.microsoft.teams2" && app("com.microsoft.teams2.modulehost") == "teams:com.microsoft.teams2",
                  "Teams and its ModuleHost helper")
            check(app("com.google.Chrome.helper") == "meet:com.google.Chrome" && app("com.apple.WebKit.GPU") == "meet:com.apple.Safari"
                  && app("company.thebrowser.browser.helper") == "meet:company.thebrowser.Browser" && app("org.mozilla.plugincontainer") == "meet:org.mozilla.firefox",
                  "browser helpers map to their browser")
            check(app("com.gotcos.control") == nil && app("com.gotcos.control.helper") == nil && app("") == nil, "COS itself never counts")
            check(app("com.microsoft.teamsfake") == nil && app("com.google.Chromecast") == nil && app("com.apple.Music") == nil,
                  "a prefix matches whole name parts only")
            check(MeetingApps.showsMeet(["Meet - abc-defg-hij"]) && MeetingApps.showsMeet(["Inbox", "Meet – Weekly sync - Google Chrome"])
                  && MeetingApps.showsMeet(["https://meet.google.com/abc-defg-hij"]), "a Meet tab title")
            check(!MeetingApps.showsMeet(["Meeting notes"]) && !MeetingApps.showsMeet(["Gmail", "Calendar"]) && !MeetingApps.showsMeet([]),
                  "Meeting notes is not a Meet")
            let processes = [MeetingAudioProcess(pid: 10, bundleID: "us.zoom.CptHost", input: true),
                             MeetingAudioProcess(pid: 11, bundleID: "com.google.Chrome.helper", input: true),
                             MeetingAudioProcess(pid: 12, bundleID: "com.apple.WebKit.GPU", input: true),
                             MeetingAudioProcess(pid: 13, bundleID: "com.microsoft.teams2", input: false),
                             MeetingAudioProcess(pid: 99, bundleID: "com.microsoft.teams2", input: true),
                             MeetingAudioProcess(pid: 14, bundleID: "com.brave.Browser.helper", input: true)]
            var asked: [String] = []
            let found = MeetingApps.holding(processes, ownPID: 99, never: [], browserShowsMeet: { owner in
                asked.append(owner)
                return ["com.google.Chrome": true, "com.brave.Browser": false][owner] ?? nil
            })
            check(Set(found.sources.map(\.ownerBundleID)) == ["us.zoom.xos", "com.google.Chrome"] && found.browserUnchecked,
                  "Zoom holds the mic; Chrome only with a Meet title; Safari unreadable without Accessibility; Teams off the mic; own pid out")
            check(asked.sorted() == ["com.apple.Safari", "com.brave.Browser", "com.google.Chrome"], "titles are read only for browsers holding the mic")
            let never = MeetingApps.holding(processes, ownPID: 99, never: ["us.zoom.xos", "com.google.Chrome"], browserShowsMeet: { _ in true })
            check(Set(never.sources.map(\.ownerBundleID)) == ["com.apple.Safari", "com.brave.Browser"], "the Never list excludes the app and its helpers")
            // The state machine.
            let zoom = MeetingApps.rule(forBundleID: "us.zoom.xos")!.source
            let t0 = Date(timeIntervalSince1970: 1_760_570_000)
            let open = MeetingDetectionState.Context(suggestEnabled: true, allowed: Set(MeetingApp.allCases), recordingBusy: false, dictating: false, cardShowing: false)
            func run(_ steps: [(Double, Bool, MeetingDetectionState.Context)]) -> [String] {
                var state = MeetingDetectionState(); var out: [String] = []
                for (at, held, context) in steps {
                    for event in state.step(holding: held ? [zoom] : [], now: t0.addingTimeInterval(at), context: context) {
                        switch event {
                        case .suggest: out.append("suggest@\(Int(at))")
                        case .ended: out.append("ended@\(Int(at))")
                        case .skipped(_, let reason): out.append("skipped@\(Int(at)):\(reason)")
                        }
                    }
                }
                return out
            }
            check(run([(0, true, open), (9, true, open), (10, true, open), (20, true, open)]) == ["suggest@10"], "10 s on the mic, then once")
            check(run([(0, true, open), (5, false, open), (6, true, open), (15, true, open), (16, true, open)]) == ["suggest@16"],
                  "the 10 s must be continuous")
            check(run([(0, true, open), (10, true, open), (30, false, open), (60, false, open), (70, true, open), (85, true, open),
                       (90, false, open), (149, false, open), (150, false, open), (160, true, open), (170, true, open)])
                  == ["suggest@10", "ended@150", "suggest@170"], "a release under 60 s is the same meeting; 60 s ends it; the next one is offered again")
            var busy = open; busy.recordingBusy = true
            check(run([(0, true, open), (10, true, busy), (12, true, open), (40, true, open)]) == ["skipped@10:recording busy"],
                  "never while a Mac recording is active, pending or recoverable, and not later in that meeting")
            var dictating = open; dictating.dictating = true
            check(run([(0, true, open), (10, true, dictating), (11, true, dictating), (12, true, open)]) == ["suggest@12"], "dictation defers it")
            var showing = open; showing.cardShowing = true
            check(run([(0, true, open), (10, true, showing), (14, true, open)]) == ["suggest@14"], "one card at a time")
            var off = open; off.suggestEnabled = false
            var noZoom = open; noZoom.allowed = [.teams, .meet]
            check(run([(0, true, off), (10, true, off), (12, true, open)]) == ["skipped@10:off"]
                  && run([(0, true, noZoom), (12, true, noZoom)]) == ["skipped@12:app not allowed"],
                  "the setting and the per-app toggle")
            // QA 0.5.313: a Meet tab switched away mid-call stays the meeting while the browser holds the mic.
            let chromeMic = [MeetingAudioProcess(pid: 11, bundleID: "com.google.Chrome.helper", input: true)]
            let chromeOff = [MeetingAudioProcess(pid: 11, bundleID: "com.google.Chrome.helper", input: false)]
            var latch = Set<Int32>()
            var meetTitle = true
            var browserState = MeetingDetectionState(); var browserEvents: [String] = []
            for (at, processes, showsMeet) in [(0.0, chromeMic, true), (12, chromeMic, false), (80, chromeMic, false), (100, chromeOff, false),
                                               (170, chromeOff, false), (180, chromeMic, false), (200, chromeMic, false)] {
                meetTitle = showsMeet
                let found = MeetingApps.holding(processes, ownPID: 99, never: [], latched: latch, browserShowsMeet: { _ in meetTitle })
                latch = found.latched
                for event in browserState.step(holding: found.sources, now: t0.addingTimeInterval(at), context: open) {
                    if case .suggest = event { browserEvents.append("suggest@\(Int(at))") }
                    if case .ended = event { browserEvents.append("ended@\(Int(at))") }
                }
            }
            check(browserEvents == ["suggest@12", "ended@170"],
                  "a Meet tab switched away stays the meeting until the browser lets go of the mic; the latch drops then")
            check(MeetingApps.holding(chromeMic, ownPID: 99, never: [], latched: [11], browserShowsMeet: { _ in nil }).sources.count == 1
                  && MeetingApps.holding(chromeOff, ownPID: 99, never: [], latched: [11], browserShowsMeet: { _ in true }).latched.isEmpty,
                  "a latched pid needs no title; the latch keeps only pids still on the mic")
            check(MeetingApps.titleReadDue(holdersChanged: true, cached: true, tick: 1) && MeetingApps.titleReadDue(holdersChanged: false, cached: false, tick: 1)
                  && !MeetingApps.titleReadDue(holdersChanged: false, cached: true, tick: 1) && MeetingApps.titleReadDue(holdersChanged: false, cached: true, tick: 5)
                  && !MeetingApps.titleReadDue(holdersChanged: false, cached: true, tick: 4),
                  "browser titles are read when the holders change, when nothing is cached, or every 5th tick")
            var idle = MeetingDetectionState()
            _ = idle.step(holding: [zoom], now: t0, context: open)
            check(idle.wantsTicks, "ticks while a meeting app holds the mic")
            _ = idle.step(holding: [], now: t0.addingTimeInterval(1), context: open)
            _ = idle.step(holding: [], now: t0.addingTimeInterval(61), context: open)
            check(!idle.wantsTicks && idle.tracks.isEmpty, "no ticks once the meeting ended")
            // Words, title and the end offer.
            var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
            check(MeetingDetectedCard.title(zoom, at: Date(timeIntervalSince1970: 1_760_544_300), calendar: utc) == "Zoom meeting 4:05 PM", "the recording's title")
            check(MeetingDetectedCard.headline(zoom) == "Meeting detected · Zoom"
                  && MeetingDetectedCard.line == "Record on Mac with live transcript? Let people know you're recording."
                  && MeetingDetectedCard.never(MeetingApps.rule(forBundleID: "com.google.Chrome")!.source) == "Never for Google Chrome"
                  && MeetingDetectedCard.dismissSeconds == 60, "the card's words")
            let chrome = MeetingApps.rule(forBundleID: "com.google.Chrome")!.source
            check(MeetingDetectedCard.offersEnd(ended: zoom, startedFrom: zoom, startedCaptureID: "mac_1", runningCaptureID: "mac_1"), "the recording this card started")
            check(!MeetingDetectedCard.offersEnd(ended: zoom, startedFrom: zoom, startedCaptureID: "mac_1", runningCaptureID: "mac_2")
                  && !MeetingDetectedCard.offersEnd(ended: zoom, startedFrom: zoom, startedCaptureID: "mac_1", runningCaptureID: nil)
                  && !MeetingDetectedCard.offersEnd(ended: zoom, startedFrom: nil, startedCaptureID: nil, runningCaptureID: "mac_1")
                  && !MeetingDetectedCard.offersEnd(ended: chrome, startedFrom: zoom, startedCaptureID: "mac_1", runningCaptureID: "mac_1"),
                  "no end offer for a manual recording, another meeting, or one already stopped")
            check(!MeetingDetectedCard.recordingBusy(macOccupied: false, macCanStart: true, liveRecordings: 0)
                  && MeetingDetectedCard.recordingBusy(macOccupied: true, macCanStart: true, liveRecordings: 0)
                  && MeetingDetectedCard.recordingBusy(macOccupied: false, macCanStart: false, liveRecordings: 0)
                  && MeetingDetectedCard.recordingBusy(macOccupied: false, macCanStart: true, liveRecordings: 1),
                  "busy: recording, starting, pending, or any live COS recording; a retained capture is not busy")
            // QA 2026-10-15: the two-hour limit is a complete recording up to then, never "Incomplete".
            let limit = MacRecordingInterruption.line(MacRecordingInterruption.pilotLimit)
            check(!limit.problem && !limit.text.contains("Incomplete") && limit.text.contains("two-hour"), "the pilot limit reads as stopped, not incomplete")
            let broken = MacRecordingInterruption.line("The app ended during recording.")
            check(broken.problem && broken.text == "Incomplete recording: The app ended during recording.", "any other interruption stays Incomplete")
            // The one-time recording notice and the automatic title.
            check(MacRecordingNotice.step(acknowledged: false) == .notice && MacRecordingNotice.step(acknowledged: true) == .start,
                  "the notice the first time, then every Record starts at once")
            check(MacRecordingNotice.title == "Record this Mac's audio" && MacRecordingNotice.lines.count == 2
                  && MacRecordingNotice.lines[1] == "Let people know you're recording."
                  && MacRecordingNotice.reminder == "Recording · let people know", "the notice's words")
            check(MacRecordingNotice.panelShowsNotice(requested: true, acknowledged: false, occupied: false)
                  && !MacRecordingNotice.panelShowsNotice(requested: true, acknowledged: true, occupied: false)
                  && !MacRecordingNotice.panelShowsNotice(requested: true, acknowledged: false, occupied: true)
                  && !MacRecordingNotice.panelShowsNotice(requested: false, acknowledged: false, occupied: false),
                  "the panel's notice hides once acknowledged anywhere, or once a recording runs")
            // Record's refusal, by cause.
            check(MacRecordingRefusal.decide(available: true, currentError: "Delivery paused: old", live: true, pendingCapture: false) == .keep
                  && MacRecordingRefusal.decide(available: false, currentError: nil, live: true, pendingCapture: true) == .keep,
                  "a second click while recording starts leaves the line alone")
            check(MacRecordingRefusal.decide(available: false, currentError: "Manual Mac recording needs the matched server candidate.", live: false, pendingCapture: false)
                  == .set("Manual Mac recording needs the matched server candidate."), "unavailable keeps prepare's reason")
            if case .set(let text) = MacRecordingRefusal.decide(available: false, currentError: nil, live: false, pendingCapture: true) {
                check(text.hasPrefix("Mac recording isn't available:"), "unavailable with no reason says so")
            } else { check(false, "unavailable is never silent") }
            check(MacRecordingRefusal.decide(available: true, currentError: "Recording stopped because this Mac slept", live: false, pendingCapture: true)
                  == .set(MacRecordingRefusal.pending), "a pending capture says so, replacing a stale unrelated line")
            // The Recover list hides journals with nothing in them.
            var withAudio = manifest(7); withAudio.stopped = true
            withAudio.chunks = [MacRecordingManifest.Chunk(index: 0, filename: "000000.wav", endFrame: 0)]
            var empty = manifest(8); empty.stopped = true
            check(MacRecordingRecoveryPolicy.listed([withAudio, empty], current: nil).map(\.captureId) == [withAudio.captureId]
                  && MacRecordingRecoveryPolicy.listed([withAudio], current: withAudio.captureId).isEmpty,
                  "Recover never offers a zero-chunk journal or the current capture")
            check(MacRecordingNotice.footnote(permissionGranted: false) == MacRecordingNotice.permissionFootnote
                  && MacRecordingNotice.footnote(permissionGranted: true) == nil, "macOS's prompt is mentioned only while not granted")
            let at = Date(timeIntervalSince1970: 1_760_544_300)
            check(MacRecordingNotice.autoTitle(meetingApp: "Zoom", at: at, calendar: utc) == "Zoom meeting 4:05 PM"
                  && MacRecordingNotice.autoTitle(meetingApp: nil, at: at, calendar: utc) == "Mac recording 4:05 PM", "the automatic title")
            check(MacRecordingNotice.title(typed: "  ", meetingApp: "Microsoft Teams", at: at, calendar: utc) == "Microsoft Teams meeting 4:05 PM"
                  && MacRecordingNotice.title(typed: " Board prep ", meetingApp: "Zoom", at: at, calendar: utc) == "Board prep"
                  && MacRecordingNotice.title(typed: String(repeating: "x", count: 200), meetingApp: nil, at: at, calendar: utc).count == 160,
                  "a typed title wins, trimmed and bounded; empty means automatic")
        }
        // 0.5.322: the Mac recording state the update swap reads before it may force a quit (MacCaptureStateFile).
        do {
            check(MacCaptureStateFile.url(environment: ["COS_CONTROL_TEST_HOME": "/tmp/h"]).path == "/tmp/h/Library/Application Support/COS Control/mac-capture-state.json",
                  "capture state: a /tmp/ test home, the helper's own rule")
            let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/COS Control/mac-capture-state.json")
            check(MacCaptureStateFile.url(environment: ["COS_CONTROL_TEST_HOME": "/Users/x/h"]) == real && MacCaptureStateFile.url(environment: [:]) == real,
                  "capture state: a home outside /tmp/ is ignored, as the helper ignores it")
            check(MacCaptureStateFile.activePhases == ["starting", "recording", "stopping"], "capture state: the phases a quit finishes first")
            let url = scratch.appendingPathComponent("state/Library/Application Support/COS Control/mac-capture-state.json")
            let when = Date(timeIntervalSince1970: 1_792_300_000)
            try MacCaptureStateFile.write(phase: "recording", pid: 4242, at: when, to: url)
            let first = try Data(contentsOf: url)
            check(MacCaptureStateFile.decode(first)?.phase == "recording" && MacCaptureStateFile.decode(first)?.pid == 4242, "capture state: written and read back")
            let object = try JSONSerialization.jsonObject(with: first) as? [String: Any]
            check(object?["schema"] as? Int == 1 && object?["at"] as? String == "2026-10-18T05:06:40Z" && object?.count == 4,
                  "capture state: schema, phase, pid and time, nothing else")
            let attributes = try fm.attributesOfItem(atPath: url.path)
            check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "capture state: owner only")
            let folder = try fm.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            check((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700, "capture state: a folder it makes is owner only")
            let protection = try url.resourceValues(forKeys: [.fileProtectionKey]).fileProtection
            check(protection != .complete && protection != .completeUnlessOpen, "capture state: never class A or B (a locked Mac must still write it)")
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.intValue
            try MacCaptureStateFile.write(phase: "idle", to: url)
            let second = try fm.attributesOfItem(atPath: url.path)
            let rewritten = MacCaptureStateFile.decode(try Data(contentsOf: url))
            check(rewritten?.phase == "idle" && rewritten?.pid == getpid(), "capture state: a rewrite names this process")
            check((second[.systemFileNumber] as? NSNumber)?.intValue != inode, "capture state: replaced atomically (a new file), never written in place")
            check(MacCaptureStateFile.decode(Data("{}".utf8)) == nil && MacCaptureStateFile.decode(Data("x".utf8)) == nil, "capture state: junk reads as nothing")
        }
        // MARK: 0.5.334, can COS hear this Mac (Miles 2026-10-21: 211 chunks of exact zeros from a 21-minute Zoom call)
        do {
            var floats: [Float] = [0, 0, 0, 0]
            check(!floats.withUnsafeBufferPointer { MacRecordingSignal.hasRawSignal($0) }, "hearing: exact 0.0 input is no signal")
            floats[3] = 1e-7
            check(floats.withUnsafeBufferPointer { MacRecordingSignal.hasRawSignal($0) }, "hearing: a sample far below one Int16 step is still signal")
            floats = [-0.0]
            check(!floats.withUnsafeBufferPointer { MacRecordingSignal.hasRawSignal($0) }, "hearing: negative zero is zero")
            let zeroChunk = MacRecordingChunk(index: 0, pcm: zeros, endFrame: MacRecordingWAV.framesPerChunk, rawSignal: false)
            check(zeroChunk.digitalSilence, "hearing: exact zeros in and out is digital silence")
            check(!MacRecordingChunk(index: 0, pcm: zeros, endFrame: MacRecordingWAV.framesPerChunk, rawSignal: true).digitalSilence,
                  "hearing: quiet input that rounded to Int16 zeros is NOT digital silence (a quiet room keeps recording)")
            check(!MacRecordingChunk(index: 0, pcm: zeros, endFrame: MacRecordingWAV.framesPerChunk).digitalSilence, "hearing: unknown raw input is never digital silence")
            check(!MacRecordingChunk(index: 0, pcm: pcm16([0, 0, 1]), endFrame: 3, rawSignal: false).digitalSilence, "hearing: a nonzero Int16 sample is never digital silence")
            // The incident, replayed: All Mac audio, Zoom playing, exact zeros. Fails fast at the second chunk (12 s).
            var state = MacRecordingHearing.State()
            check(MacRecordingHearing.step(&state, digitalSilence: true, othersPlaying: true, allMacAudio: true) == .keep, "fail-fast: one zero chunk is not enough")
            check(MacRecordingHearing.step(&state, digitalSilence: true, othersPlaying: true, allMacAudio: true) == .cannotHear, "fail-fast: two zero chunks while another app plays stop it")
            check(MacRecordingHearing.failFastChunks * MacRecordingWAV.framesPerChunk / MacRecordingWAV.sampleRate == 12, "fail-fast: within the first ~12 s")
            // A quiet meeting with any nonzero sample never fails fast, even if it later goes to exact digital silence.
            state = MacRecordingHearing.State()
            check(MacRecordingHearing.step(&state, digitalSilence: false, othersPlaying: true, allMacAudio: true) == .keep && state.heardSignal, "fail-fast: quiet nonzero keeps recording")
            for _ in 0..<50 { check(MacRecordingHearing.step(&state, digitalSilence: true, othersPlaying: true, allMacAudio: true) == .keep, "fail-fast: never after any sound") }
            // Nothing playing: zeros are expected, not a permission problem.
            state = MacRecordingHearing.State()
            for _ in 0..<10 { check(MacRecordingHearing.step(&state, digitalSilence: true, othersPlaying: false, allMacAudio: true) == .keep, "fail-fast: nothing playing keeps recording") }
            check(MacRecordingHearing.step(&state, digitalSilence: true, othersPlaying: true, allMacAudio: true) == .keep
                  && MacRecordingHearing.step(&state, digitalSilence: true, othersPlaying: nil, allMacAudio: true) == .cannotHear,
                  "fail-fast: counts only while something plays (unreadable counts), so a call that starts later is still caught")
            // A per-app source has its own advice (the silence warning); the fail-fast is All Mac audio only.
            state = MacRecordingHearing.State()
            for _ in 0..<5 { check(MacRecordingHearing.step(&state, digitalSilence: true, othersPlaying: true, allMacAudio: false) == .keep, "fail-fast: not for a per-app source") }
            // The probe: warning only.
            state = MacRecordingHearing.State()
            MacRecordingHearing.probe(&state, sawSignal: false, othersPlaying: true, allMacAudio: true)
            check(state.suspect && MacRecordingHearing.line(state, recording: true) == MacRecordingHearing.suspectLine, "probe: zeros while playing warn")
            check(MacRecordingHearing.line(state, recording: false) == nil, "probe: the warning is live only")
            check(MacRecordingHearing.step(&state, digitalSilence: false, othersPlaying: true, allMacAudio: true) == .keep && !state.suspect
                  && MacRecordingHearing.line(state, recording: true) == nil, "probe: the first sound clears the warning")
            state = MacRecordingHearing.State()
            MacRecordingHearing.probe(&state, sawSignal: false, othersPlaying: false, allMacAudio: true)
            check(!state.suspect, "probe: nothing playing, no warning")
            MacRecordingHearing.probe(&state, sawSignal: true, othersPlaying: true, allMacAudio: true)
            check(state.heardSignal && !state.suspect, "probe: signal in the first second counts as heard")
            state = MacRecordingHearing.State()
            MacRecordingHearing.probe(&state, sawSignal: false, othersPlaying: true, allMacAudio: false)
            check(!state.suspect, "probe: not for a per-app source")
            check(MacRecordingHearing.cannotHearMessage == "COS Control can't hear your Mac's audio. macOS may not be letting it record system audio.", "the message, verbatim")
            let note = MacRecordingInterruption.notification(MacRecordingHearing.cannotHearMessage)
            check(note.body.hasPrefix(MacRecordingHearing.cannotHearMessage) && !note.body.contains("Incomplete") && !note.body.contains("→"),
                  "the no-sound stop notifies with the message, never as an incomplete recording")
            for text in [MacRecordingHearing.cannotHearMessage, MacRecordingHearing.notificationBody, MacRecordingHearing.suspectLine,
                         MacRecordingDiscard.buttonTitle, MacRecordingDiscard.confirmLine, MacRecordingNoMeeting.line] {
                check(!text.contains("—") && !text.contains("→"), "no em dash or arrow in the new copy")
            }
        }
        // MARK: 0.5.334, the dead ends become Discard
        do {
            for noSpeech in [false, true] { for allZero in [false, true] { for pending in [false, true] { for stopped in [false, true] { for delivering in [false, true] {
                check(MacRecordingDiscard.offered(noSpeech: noSpeech, allZero: allZero, pending: pending, stopped: stopped, delivering: delivering)
                      == ((noSpeech || allZero) && pending && stopped && !delivering), "Discard: only for a stopped, idle capture with no sound")
                for hasChunks in [false, true] {
                    check(MacRecordingDiscard.retryOffered(noSpeech: noSpeech, allZero: allZero, pending: pending, hasChunks: hasChunks, delivering: delivering)
                          == (pending && hasChunks && !noSpeech && !allZero && !delivering), "Retry saving: never for no sound (it cannot work)")
                    // 0.5.351: the button showed through every ordinary save and read as "retrying chunks".
                    if delivering { check(!MacRecordingDiscard.retryOffered(noSpeech: noSpeech, allZero: allZero, pending: pending, hasChunks: hasChunks, delivering: true), "Retry saving: never while the save is running") }
                }
            } } } } }
            check(MacRecordingDiscard.strandedOffersDiscard(sessionId: "mac_x", transcriptState: "no_speech", canSave: false), "stranded: a no-speech Mac row offers Discard")
            check(!MacRecordingDiscard.strandedOffersDiscard(sessionId: "mac_x", transcriptState: "ready", canSave: true), "stranded: a savable Mac row keeps Save")
            check(!MacRecordingDiscard.strandedOffersDiscard(sessionId: "mac_x", transcriptState: "processing", canSave: false), "stranded: a Mac row still transcribing keeps Save")
            check(!MacRecordingDiscard.strandedOffersDiscard(sessionId: "g2_1", transcriptState: "no_speech", canSave: false), "stranded: glasses rows are untouched")
            typealias S = MacRecordingDiscard.Server
            check(MacRecordingDiscard.serverAnswer(ok: true, httpStatus: 200, reason: nil, discarded: true, replayed: false) == S.discarded, "server: discarded")
            check(MacRecordingDiscard.serverAnswer(ok: true, httpStatus: 200, reason: nil, discarded: true, replayed: true) == S.replayed, "server: replayed")
            check(MacRecordingDiscard.serverAnswer(ok: false, httpStatus: 409, reason: "not_idle", discarded: nil, replayed: nil) == S.notIdle
                  && MacRecordingDiscard.serverAnswer(ok: false, httpStatus: 409, reason: "asr_in_progress", discarded: nil, replayed: nil) == S.notIdle,
                  "server: still fresh or transcribing is asked again later")
            check(MacRecordingDiscard.serverAnswer(ok: false, httpStatus: 404, reason: "session_not_found", discarded: nil, replayed: nil) == S.absent, "server: already gone")
            check(MacRecordingDiscard.serverAnswer(ok: false, httpStatus: 404, reason: "route_absent", discarded: nil, replayed: nil) == S.unsupported
                  && MacRecordingDiscard.serverAnswer(ok: false, httpStatus: 404, reason: nil, discarded: nil, replayed: nil) == S.unsupported,
                  "server: an older server without the route")
            check(MacRecordingDiscard.serverAnswer(ok: false, httpStatus: 409, reason: "has_speech", discarded: nil, replayed: nil) == S.refused("has_speech"), "server: speech is refused")
            check(MacRecordingDiscard.serverAnswer(ok: false, httpStatus: nil, reason: "server_unavailable", discarded: nil, replayed: nil) == S.unreachable, "server: unreachable")
            check(MacRecordingDiscard.note(localMoved: true, server: .unsupported).contains("This COS server is older"), "older server: the note is honest that only this Mac's copy went")
            check(!MacRecordingDiscard.note(localMoved: true, server: .discarded).contains("server"), "a full discard needs no server caveat")
            check(MacRecordingDiscard.dayFolder(Date(timeIntervalSince1970: 1_792_600_000), calendar: { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c }()) == "2026-10-21",
                  "discarded folder is dated")
            check(MacRecordingNoMeeting.endsHandoff(sessionId: "mac_a", noMeeting: ["mac_a"]) && !MacRecordingNoMeeting.endsHandoff(sessionId: "mac_b", noMeeting: ["mac_a"])
                  && !MacRecordingNoMeeting.endsHandoff(sessionId: "g2_a", noMeeting: ["g2_a"]), "no meeting to find: only a known no-sound Mac capture")
        }
        // MARK: 0.5.334, execution: the spool's heard flag, discard to a dated folder, against a fake server
        do {
            let droot = scratch.appendingPathComponent("discard-home/cos-data/mac-recordings")
            let dspool = MacRecordingSpool(root: droot)
            func journal(_ n: Int) -> MacRecordingManifest {
                MacRecordingManifest(captureId: String(format: "mac_%08d-aaaa-4aaa-8aaa-123456789abc", n), startTime: 1_792_600_000_000, serverInstanceId: "fixture-server",
                                     sourceName: MacAudioSource.allMacAudio.name, title: "Zoom meeting 8:44 AM", stopped: false, saved: false, acknowledged: 0, chunks: [])
            }
            let silent = journal(1)
            try await dspool.write(silent)
            var value = try await dspool.append(.init(index: 0, pcm: zeros, endFrame: MacRecordingWAV.framesPerChunk, rawSignal: false), captureId: silent.id)
            value = try await dspool.append(.init(index: 1, pcm: zeros, endFrame: MacRecordingWAV.framesPerChunk * 2, rawSignal: false), captureId: silent.id)
            check(value.heardSignal == false && value.allDigitalSilence, "spool: exact zeros are known to be all silence")
            check(try await MacRecordingSpool(root: droot).snapshot(silent.id).allDigitalSilence, "spool: the flag survives a restart")
            let quiet = journal(2)
            try await dspool.write(quiet)
            _ = try await dspool.append(.init(index: 0, pcm: zeros, endFrame: MacRecordingWAV.framesPerChunk, rawSignal: false), captureId: quiet.id)
            let heard = try await dspool.append(.init(index: 1, pcm: zeros, endFrame: MacRecordingWAV.framesPerChunk * 2, rawSignal: true), captureId: quiet.id)
            check(heard.heardSignal == true && !heard.allDigitalSilence, "spool: one chunk with signal clears it for good")
            let after = try await dspool.append(.init(index: 2, pcm: zeros, endFrame: MacRecordingWAV.framesPerChunk * 3, rawSignal: false), captureId: quiet.id)
            check(after.heardSignal == true, "spool: exact zeros after sound never forget the sound")
            var legacyJournal = journal(4); legacyJournal.chunks = [.init(index: 0, filename: "000000.wav", endFrame: MacRecordingWAV.framesPerChunk)]
            try await dspool.write(legacyJournal)
            let appendedOld = try await dspool.append(.init(index: 1, pcm: zeros, endFrame: MacRecordingWAV.framesPerChunk * 2, rawSignal: false), captureId: legacyJournal.id)
            check(appendedOld.heardSignal == true && !appendedOld.allDigitalSilence, "spool: a journal begun before 0.5.334 (unknown) is never turned silent by a later zero chunk")
            var legacy = journal(3); legacy.chunks = [.init(index: 0, filename: "000000.wav", endFrame: 16_000)]
            check(!legacy.allDigitalSilence, "spool: a journal from before 0.5.334 is never assumed silent")
            check(try JSONDecoder().decode(MacRecordingManifest.self, from: Data(#"{"captureId":"mac_00000003-aaaa-4aaa-8aaa-123456789abc","startTime":1,"serverInstanceId":"s","sourceName":"x","title":"t","stopped":true,"saved":false,"acknowledged":0,"chunks":[]}"#.utf8)).heardSignal == nil,
                  "spool: an older journal still decodes")
            _ = try await dspool.markStopped(silent.id)
            // The fake helper: records what it was asked and answers like server 6.84.0, then like an older server.
            final class Calls: @unchecked Sendable { var asked: [(String, String)] = [] }
            let calls = Calls()
            let discarder = MacRecordingDiscarder(spool: dspool, server: { id, pin in calls.asked.append((id, pin)); return .discarded })
            let when = Date(timeIntervalSince1970: 1_792_600_000)
            let outcome = await discarder.discard(captureId: silent.id, serverInstanceId: "fixture-server", serverSupported: true, at: when)
            let day = MacRecordingDiscard.dayFolder(when)
            let movedTo = droot.deletingLastPathComponent().appendingPathComponent("mac-recordings-discarded/\(day)/\(silent.id)")
            check(outcome.localError == nil && outcome.moved?.path == movedTo.path && outcome.server == .discarded, "discard: moved to the dated folder and the server was asked")
            check(calls.asked.count == 1 && calls.asked[0] == (silent.id, "fixture-server"), "discard: the server is asked once, for this capture and pin")
            check(!fm.fileExists(atPath: droot.appendingPathComponent(silent.id).path), "discard: nothing pending remains in the spool")
            check(fm.fileExists(atPath: movedTo.appendingPathComponent("000000.wav").path) && fm.fileExists(atPath: movedTo.appendingPathComponent("000001.wav").path)
                  && fm.fileExists(atPath: movedTo.appendingPathComponent("manifest.json").path), "discard: every file moved, none removed")
            check(Set(try await MacRecordingSpool(root: droot).recoverable().map(\.id)) == [quiet.id, legacyJournal.id], "discard: gone from Recover, the other captures untouched")
            check(outcome.line == MacRecordingDiscard.note(localMoved: true, server: .discarded), "discard: one honest line")
            // An older server: only the local copy, and it says so; nothing is sent.
            _ = try await dspool.markStopped(quiet.id)
            let older = await discarder.discard(captureId: quiet.id, serverInstanceId: "fixture-server", serverSupported: false, at: when)
            check(older.server == .unsupported && calls.asked.count == 1 && older.line.contains("This COS server is older"), "older server: local discard, no request, honest note")
            // Discarding the same id again (a capture folder with that name already discarded today) never overwrites.
            let again = journal(1)
            try await dspool.write(again); _ = try await dspool.markStopped(again.id)
            let second = await discarder.discard(captureId: again.id, serverInstanceId: "fixture-server", serverSupported: true, at: when)
            check(second.moved != nil && second.moved?.path != movedTo.path && fm.fileExists(atPath: movedTo.appendingPathComponent("manifest.json").path),
                  "discard: a second folder of the same name gets its own name; the first is kept")
            // A stranded row this Mac has no copy of: only the server is asked.
            let remote = await discarder.discard(captureId: journal(9).id, serverInstanceId: "fixture-server", serverSupported: true, localPresent: false, at: when)
            check(remote.moved == nil && remote.localError == nil && remote.server == .discarded && calls.asked.count == 3, "discard: no local copy, the server's side only")
            // A missing local folder is an error that leaves the server alone.
            let missing = await discarder.discard(captureId: journal(8).id, serverInstanceId: "fixture-server", serverSupported: true, at: when)
            check(missing.localError != nil && calls.asked.count == 3 && missing.line.hasPrefix("Couldn't discard"), "discard: a local failure is reported and the server is not asked")
            await rejects("discard refuses an invalid capture id") { _ = try await dspool.discard("../escape") }
            let folder = try fm.attributesOfItem(atPath: movedTo.deletingLastPathComponent().path)
            check((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700, "discard: the discarded folder is owner only")
        }
        // MARK: 0.5.351, quick save (Miles 2026-10-26: "We should just show like a quick save.")
        do {
            typealias Q = MacRecordingSaveStatus
            let msg = "Some message"
            func line(_ phase: String, chunks: Int = 345, ack: Int = 340, delivering: Bool = false, paused: Bool = false, waiting: Bool = false,
                      slow: Bool = false, noSpeech: Bool = false, allZero: Bool = false) -> Q.Line {
                Q.line(phase: phase, message: msg, chunks: chunks, acknowledged: ack, delivering: delivering, paused: paused, waiting: waiting,
                       slow: slow, noSpeech: noSpeech, allZero: allZero)
            }
            // The ordinary save: Saving…, nothing else, from Stop until the receipt.
            let stopping = line("stopping")
            check(stopping.headline == "Saving…" && stopping.detail == nil && stopping.progress == nil && !stopping.showsActions, "quick save: Stop says Saving… at once")
            let saving = line("pending", delivering: true)
            check(saving.headline == "Saving…" && saving.detail == nil && saving.progress == nil && !saving.showsActions && saving.tone == .quiet,
                  "quick save: an ordinary save shows no counter, no retained-recording line and no buttons")
            let quietRetry = line("pending", delivering: true, paused: false, waiting: true)
            check(quietRetry == saving, "quick save: a quiet try in the first seconds looks exactly like an ordinary save")
            let slow = line("pending", delivering: true, slow: true)
            check(slow.headline == "Saving…" && slow.detail == "Still saving. 340 of 345 audio chunks have reached COS." && !slow.showsActions,
                  "quick save: a slow save says how far it got")
            let down = line("pending", delivering: true, waiting: true, slow: true)
            check(down.headline == "Saving…" && down.detail == Q.notAnswering && !down.showsActions, "quick save: COS not answering is said once the save is slow")
            let saved = line("saved", ack: 345)
            check(saved.headline == "Saved" && saved.detail == "Open Meetings to review the transcript." && saved.progress == nil && saved.tone == .done && !saved.showsActions,
                  "quick save: Saved, with no 345/345 counter")
            // A real failure stays honest: Not saved yet, how far, and the buttons.
            let failed = line("pending", paused: true)
            check(failed.headline == Q.notSaved && failed.progress == "340 of 345 audio chunks reached COS." && failed.tone == .problem && failed.showsActions,
                  "quick save: a stopped delivery says Not saved yet, how far, and offers the buttons")
            check(line("pending", paused: true, slow: true) == failed && line("pending", paused: true, waiting: true) == failed, "quick save: paused is paused, slow or not")
            let idle = line("pending")
            check(idle.headline == msg && idle.progress == "340 of 345 audio chunks reached COS." && idle.tone == .quiet && idle.showsActions,
                  "quick save: a retained capture not being saved keeps its message, count and buttons")
            // No sound and an empty capture are unchanged (0.5.334): their message and their own buttons.
            for (noSpeech, allZero) in [(true, false), (false, true), (true, true)] {
                for delivering in [false, true] {
                    let none = line("pending", delivering: delivering, noSpeech: noSpeech, allZero: allZero)
                    check(none.headline == msg && none.progress == nil && none.showsActions, "quick save: no sound keeps its own message and Discard")
                }
            }
            check(line("pending", chunks: 0, ack: 0, delivering: true).headline == msg, "quick save: nothing stored keeps its message")
            // Recording: the count only when COS is behind; the not-answering line only then.
            let live = line("recording", chunks: 20, ack: 19)
            check(live.headline == msg && live.progress == nil && live.detail == nil && !live.showsActions, "quick save: recording in step shows no counter")
            check(line("recording", chunks: 20, ack: 18).progress == nil, "quick save: two chunks behind is in step")
            let behind = line("recording", chunks: 20, ack: 17)
            check(behind.progress == "Sending audio to COS: 17 of 20 chunks received." && behind.detail == nil, "quick save: three chunks behind shows the count")
            check(line("recording", chunks: 20, ack: 17, paused: true).detail == Q.notAnsweringWhileRecording, "quick save: behind and paused says COS is not answering")
            check(line("recording", chunks: 20, ack: 19, paused: true).detail == nil, "quick save: a pause that has not left COS behind says nothing")
            for phase in ["idle", "starting", "recovering", "discarding"] {
                let other = line(phase)
                check(other.headline == msg && other.progress == nil && other.detail == nil, "quick save: other phases keep their message, no counter")
            }
            // Copy rules.
            for text in [Q.saving, Q.saved, Q.savedDetail, Q.notSaved, Q.notAnswering, Q.notAnsweringWhileRecording, Q.stillSaving(1, of: 2), Q.reached(1, of: 2), Q.sending(1, of: 2),
                         MacRecordingLiveRow.label(stopped: true, saved: false, acknowledged: 1, chunks: 2, paused: true) ?? "",
                         MacRecordingLiveRow.label(stopped: true, saved: false, acknowledged: 1, chunks: 2, slow: true) ?? ""] {
                check(!text.contains("—") && !text.contains("→") && !text.lowercased().contains("retry"), "quick save: no em dash, arrow or retry in the copy")
            }
            check(Q.slowAfterSeconds == 20 && Q.behindChunks == 3, "quick save: thresholds")

            typealias R = MacRecordingSaveRetry
            // Passing failures only.
            check(R.transient(httpStatus: nil, reason: nil, message: "Server stopped"), "retry: the helper's health probe failing is passing")
            check(R.transient(httpStatus: nil, reason: nil, message: "The COS operation took too long."), "retry: a helper timeout is passing")
            check(R.transient(httpStatus: nil, reason: "server_unavailable", message: "x"), "retry: server unreachable is passing")
            check(R.transient(httpStatus: 409, reason: "mac_chunk_in_progress", message: "x"), "retry: a chunk still in flight is passing")
            check(R.transient(httpStatus: 409, reason: "save_in_progress", message: "x"), "retry: a save still in flight is passing")
            for status in [502, 503, 504] { check(R.transient(httpStatus: status, reason: nil, message: "x"), "retry: a gateway or busy status is passing") }
            check(R.transient(httpStatus: 503, reason: "mac_parakeet_cli_failed", message: "x"), "retry: a busy ASR is passing")
            check(!R.transient(httpStatus: 503, reason: "openai_whisper_budget_exhausted", message: "x"), "retry: an exhausted budget is not passing")
            for (status, reason) in [(409, "server_instance_mismatch"), (409, "mac_chunk_conflict"), (410, "session_closed"), (404, "nothing_to_save"),
                                     (400, "invalid_elapsed"), (401, nil), (413, nil), (500, "meeting_save_error"), (404, nil)] as [(Int, String?)] {
                check(!R.transient(httpStatus: status, reason: reason, message: "Server stopped"), "retry: a real refusal is never retried, whatever its text")
            }
            for message in ["The server did not acknowledge this exact audio chunk. Its local copy is retained.",
                            "A saved-meeting receipt was not verified. Audio is retained for recovery.",
                            "The recording journal or private storage is invalid. Existing audio is retained.", "Unauthorized", ""] {
                check(!R.transient(httpStatus: nil, reason: nil, message: message), "retry: verification, spool and auth failures are never retried")
            }
            // Bounded, and only after Stop.
            check(R.delays == [1, 2, 4, 8, 15, 30] && R.delays.reduce(0, +) == 60, "retry: six quiet tries in about a minute")
            for attempt in -1...8 {
                for stopped in [false, true] { for transient in [false, true] {
                    let wait = R.delay(afterAttempt: attempt, stopped: stopped, transient: transient)
                    check(wait == (stopped && transient && attempt >= 0 && attempt < 6 ? R.delays[attempt] : nil), "retry: only after Stop, only passing, at most six")
                } }
            }
        }
        // MARK: 0.5.351, Recover says why it is unavailable (Miles 2026-10-26: grayed out during a live recording, no reason)
        do {
            let occupiedPhases: Set<String> = ["starting", "recording", "stopping", "recovering", "discarding"]
            for phase in ["idle", "saved", "pending", "starting", "recording", "stopping", "recovering", "discarding"] {
                for delivering in [false, true] { for currentUnsaved in [false, true] {
                    // MacRecordingStore.canStart: !occupied && deliveryTask == nil && (manifest nil, saved or empty).
                    let canStart = !occupiedPhases.contains(phase) && !delivering && !currentUnsaved
                    let reason = MacRecordingRecoveryPolicy.recoverUnavailable(phase: phase, delivering: delivering, currentUnsaved: currentUnsaved)
                    check((reason == nil) == canStart, "Recover: a reason exactly when it is grayed out")
                    if let reason { check(reason.hasPrefix("Recover is available ") && !reason.contains("—") && !reason.contains("→"), "Recover: the reason's copy") }
                } }
            }
            check(MacRecordingRecoveryPolicy.recoverUnavailable(phase: "recording", delivering: true, currentUnsaved: true) == "Recover is available after this recording.",
                  "Recover: during a live recording it says after this recording")
            check(MacRecordingRecoveryPolicy.recoverUnavailable(phase: "pending", delivering: true, currentUnsaved: true) == "Recover is available once this recording is saved.",
                  "Recover: during a save it says once this recording is saved")
            check(MacRecordingRecoveryPolicy.recoverUnavailable(phase: "pending", delivering: false, currentUnsaved: true) == "Recover is available once the recording above is saved or kept for later.",
                  "Recover: behind a paused recording it names what to do")
        }
        // MARK: 0.5.351, reconcile a retained capture the server already saved (mac_b0bd6732)
        do {
            typealias C = MacRecordingReconcile
            let id = "mac_0000b0bd-d95a-4276-8b3d-af4c32719e24"
            let value = MacRecordingManifest(captureId: id, startTime: 1_792_026_000_000, serverInstanceId: "fixture-server", sourceName: "All Mac audio",
                                         title: "Fixture recording", stopped: false, saved: false, acknowledged: 3, chunks: (0..<3).map { .init(index: $0, filename: String(format: "%06d.wav", $0), endFrame: ($0 + 1) * 160) })
            check(C.shouldAsk(value, current: nil), "reconcile: a retained capture fully acknowledged is worth asking about")
            check(!C.shouldAsk(value, current: id), "reconcile: never the current capture")
            var partial = value; partial.acknowledged = 2
            check(!C.shouldAsk(partial, current: nil), "reconcile: a capture with audio only this Mac holds is never hidden")
            var done = value; done.stopped = true; done.saved = true
            check(!C.shouldAsk(done, current: nil), "reconcile: a saved journal is not asked about")
            var empty = value; empty.chunks = []; empty.acknowledged = 0
            check(!C.shouldAsk(empty, current: nil), "reconcile: an empty journal is not asked about")
            let good = C.Answer(ok: true, state: "saved", sessionId: id, receiptSaved: true, receiptVersion: 1, receiptSessionId: id, receiptCaptureId: id, receiptSourceType: "mac_system_audio")
            check(C.savedOnServer(captureId: id, good), "reconcile: a verified receipt for this capture is saved")
            var variants: [(String, C.Answer)] = []
            var a = good; a.ok = false; variants.append(("a refusal", a))
            a = good; a.state = "active"; variants.append(("a live session", a))
            a = good; a.state = "missing"; variants.append(("missing", a))
            a = good; a.state = nil; variants.append(("no state", a))
            a = good; a.sessionId = "mac_other"; variants.append(("another session", a))
            a = good; a.receiptSaved = nil; variants.append(("no receipt", a))
            a = good; a.receiptSaved = false; variants.append(("an unsaved receipt", a))
            a = good; a.receiptVersion = 2; variants.append(("another receipt version", a))
            a = good; a.receiptSessionId = "mac_other"; variants.append(("a receipt for another session", a))
            a = good; a.receiptCaptureId = nil; variants.append(("a receipt with no capture", a))
            a = good; a.receiptSourceType = nil; variants.append(("a receipt that is not a Mac capture", a))
            for (name, answer) in variants { check(!C.savedOnServer(captureId: id, answer), "reconcile: \(name) keeps the row") }
            // The spool marks only a fully acknowledged journal, and never touches its audio.
            let rroot = scratch.appendingPathComponent("reconcile-home/cos-data/mac-recordings")
            let rspool = MacRecordingSpool(root: rroot)
            let start = MacRecordingManifest(captureId: id, startTime: 1_792_026_000_000, serverInstanceId: "fixture-server", sourceName: "All Mac audio",
                                             title: "Fixture recording", stopped: false, saved: false, acknowledged: 0, chunks: [])
            try await rspool.write(start)
            let tiny = Data((0..<320).map { UInt8(truncatingIfNeeded: $0 + 1) })
            for index in 0..<3 { _ = try await rspool.append(.init(index: index, pcm: tiny, endFrame: (index + 1) * 160), captureId: id) }
            _ = try await rspool.acknowledge(id, index: 0); _ = try await rspool.acknowledge(id, index: 1)
            await rejects("reconcile: a journal with an unacknowledged chunk is never marked saved") { _ = try await rspool.markSavedOnServer(id) }
            check(try await MacRecordingSpool(root: rroot).snapshot(id).saved == false, "reconcile: the refused mark changed nothing on disk")
            _ = try await rspool.acknowledge(id, index: 2)
            let wavs = try fm.contentsOfDirectory(atPath: rroot.appendingPathComponent(id).path).filter { $0.hasSuffix(".wav") }.sorted()
            let marked = try await rspool.markSavedOnServer(id)
            check(marked.saved && marked.stopped && marked.acknowledged == 3 && marked.chunks.count == 3, "reconcile: an unstopped, fully acknowledged journal is marked stopped and saved")
            check(try await MacRecordingSpool(root: rroot).recoverable().isEmpty, "reconcile: a marked journal is no longer offered for Recover, after a restart too")
            check(try fm.contentsOfDirectory(atPath: rroot.appendingPathComponent(id).path).filter { $0.hasSuffix(".wav") }.sorted() == wavs && wavs.count == 3,
                  "reconcile: the audio files are untouched")
            await rejects("reconcile: an invalid id is refused") { _ = try await rspool.markSavedOnServer("../escape") }
        }
        print("Mac recording core checks: \(checks) passed (fixture bytes only)")
    }
}
