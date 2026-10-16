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
            for pending in [false, true] {
                for stopped in [false, true] {
                    for delivering in [false, true] {
                        let permitted = MacRecordingRecoveryPolicy.canKeepForLater(noSpeech: noSpeech, pending: pending, stopped: stopped, delivering: delivering)
                        check(permitted == (noSpeech && pending && stopped && !delivering), "only confirmed stopped silence with no in-flight delivery may release the composer")
                    }
                }
            }
        }
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
        check(MacRecordingLiveRow.label(stopped: true, saved: false, acknowledged: 51, chunks: 1_200) == "Capture stopped · saving 51/1200", "a stopped, unsaved capture says it is saving, with progress")
        check(MacRecordingLiveRow.label(stopped: false, saved: false, acknowledged: 51, chunks: 60) == nil, "a running capture stays Live now")
        check(MacRecordingLiveRow.label(stopped: true, saved: true, acknowledged: 60, chunks: 60) == nil, "a saved capture leaves the row to the saved hand-off")
        // 0.5.310: delivery stopped on an error; the row must not claim it is still saving.
        check(MacRecordingLiveRow.label(stopped: true, saved: false, acknowledged: 51, chunks: 1_200, paused: true) == "Capture stopped · delivery paused 51/1200", "a paused delivery says paused, with progress")
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
            check(run([(0, true, open), (10, true, busy), (12, true, open), (40, true, open)]).isEmpty,
                  "never while a Mac recording is active, pending or recoverable, and not later in that meeting")
            var dictating = open; dictating.dictating = true
            check(run([(0, true, open), (10, true, dictating), (11, true, dictating), (12, true, open)]) == ["suggest@12"], "dictation defers it")
            var showing = open; showing.cardShowing = true
            check(run([(0, true, open), (10, true, showing), (14, true, open)]) == ["suggest@14"], "one card at a time")
            var off = open; off.suggestEnabled = false
            var noZoom = open; noZoom.allowed = [.teams, .meet]
            check(run([(0, true, off), (10, true, off), (12, true, open)]).isEmpty && run([(0, true, noZoom), (12, true, noZoom)]).isEmpty,
                  "the setting and the per-app toggle")
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
            // The one-time recording notice and the automatic title.
            check(MacRecordingNotice.step(acknowledged: false) == .notice && MacRecordingNotice.step(acknowledged: true) == .start,
                  "the notice the first time, then every Record starts at once")
            check(MacRecordingNotice.title == "Record this Mac's audio" && MacRecordingNotice.lines.count == 2
                  && MacRecordingNotice.lines[1] == "Let people know you're recording."
                  && MacRecordingNotice.reminder == "Recording · let people know", "the notice's words")
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
        print("Mac recording core checks: \(checks) passed (fixture bytes only)")
    }
}
