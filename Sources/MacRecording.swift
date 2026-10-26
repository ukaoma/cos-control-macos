import SwiftUI
import Combine
import CoreAudio
import ApplicationServices
import os

private let recordingLog = Logger(subsystem: "com.gotcos.control", category: "mac-recording")

@MainActor enum MacRecordingTermination {
    static var prepare: (@MainActor () async -> Void)?
    /// 0.5.320: whether a quit has anything to finish first (a Mac recording starting, recording or stopping). Without
    /// one, a quit is immediate, so no quit can wait on a Task (see AppQuit). Nil keeps the old always-defer behaviour.
    static var needsPrepare: (@MainActor () -> Bool)?
    static var pending = false
    /// 0.5.319: bumped by every quit request and by a cancel, so a save that finishes after its quit was cancelled
    /// (the update's 75 s deadline) never quits the app later on its own.
    static var generation = 0

    /// Cancels a quit that is still waiting on the recording save. Control stays open and its window can say why.
    static func cancelPendingQuit() {
        guard pending else { return }
        pending = false
        generation += 1
        NSApp.reply(toApplicationShouldTerminate: false)
    }
}

/// 0.5.351: SIGTERM skips applicationShouldTerminate, so a recording was never marked stopped (mac_b0bd6732). The handler
/// closes every open capture's journal within MacRecordingSigterm.waitSeconds, then lets the signal end the process as it
/// always did.
enum MacRecordingSigtermWiring {
    nonisolated(unsafe) private static var source: DispatchSourceSignal?
    static func install() {
        guard source == nil else { return }
        source = MacRecordingSigterm.install { result in
            recordingLog.notice("sigterm: open=\(result.total) closed=\(result.finished) timedOut=\(result.timedOut) ms=\(result.elapsedMs)")
            signal(SIGTERM, SIG_DFL); raise(SIGTERM)
        }
    }
}

@MainActor extension COSAppDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepare = MacRecordingTermination.prepare,
              MacRecordingTermination.pending || MacRecordingTermination.needsPrepare?() ?? true else { return .terminateNow }
        guard !MacRecordingTermination.pending else { return .terminateLater }
        MacRecordingTermination.pending = true
        MacRecordingTermination.generation += 1
        let mine = MacRecordingTermination.generation
        Task {
            await prepare()
            guard MacRecordingTermination.generation == mine else { return }   // cancelled meanwhile
            MacRecordingTermination.pending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor
final class MacRecordingStore: ObservableObject {
    typealias Bridge = @MainActor @Sendable (String, [String: JSONValue]) async throws -> HelperResponse
    @Published var sources: [MacAudioSource] = []
    @Published var selectedID: UInt32 = MacAudioSource.allMacAudioID
    /// Typed under Options; empty means the automatic title (MacRecordingNotice.title).
    @Published var title = ""
    @Published private(set) var phase = "idle" {
        didSet {
            // 0.5.322: every change reaches the update swap's state file first (MacCaptureStateFile), so the swap never
            // forces a quit on a recording that has just started.
            if oldValue != phase { phaseRecorder?(phase) }
            if ["starting", "recording", "stopping"].contains(oldValue) != ["starting", "recording", "stopping"].contains(phase) { activeChanged?(["starting", "recording", "stopping"].contains(phase)) }
        }
    }
    @Published private(set) var message = "Record what this Mac plays: every app, or one you pick. Your microphone is not recorded. Glasses are optional."
    @Published private(set) var error: String?
    @Published private(set) var manifest: MacRecordingManifest?
    @Published private(set) var recoverable: [MacRecordingManifest] = []
    @Published private(set) var available = false
    @Published private(set) var noSpeech = false
    /// Consecutive stored chunks below the silence floor; resets on the first chunk with sound.
    @Published private(set) var silentChunks = 0
    @Published private(set) var heardSound = false
    /// 0.5.310: the last delivery attempt stopped on an error; cleared when delivery runs again.
    @Published private(set) var deliveryPaused = false
    /// 0.5.351 (quick save): a quiet try after a passing failure is waiting (MacRecordingSaveRetry).
    @Published private(set) var waitingToRetry = false
    /// 0.5.351: the save has run slowAfterSeconds since Stop or Retry; only then does the panel show how far it got.
    @Published private(set) var slowSave = false
    /// The waits between quiet tries and the slow-save threshold. Fixed policy; a render or test harness shortens them.
    var retryDelays = MacRecordingSaveRetry.delays
    var slowSaveAfter = MacRecordingSaveStatus.slowAfterSeconds
    private var slowTask: Task<Void, Never>?
    /// The last refusal's HTTP status and reason code (never its text), for MacRecordingSaveRetry.transient.
    private var lastFailure: (httpStatus: Int?, reason: String?) = (nil, nil)
    /// Whether the delivery call that just failed failed in a passing way; false after any call that succeeded.
    private var deliveryFailureTransient = false
    /// 0.5.334: can COS hear this Mac (MacRecordingHearing): the probe's warning and the fail-fast's count.
    @Published private(set) var hearing = MacRecordingHearing.State()
    /// 0.5.334: the last capture stopped because it heard only exact zeros: the panel shows the message, Open System
    /// Settings and Try again until the next recording starts.
    @Published private(set) var cannotHear = false
    /// 0.5.334: Mac captures that will never have a meeting (no speech, discarded). The live hand-off ends for these
    /// instead of "Saved meeting not found yet" (MacRecordingNoMeeting).
    /// 0.5.337 (loop audit W16): kept across launches (the last 100), so a discarded capture never comes back as an unsaved
    /// row after a restart.
    @Published private(set) var noMeetingCaptureIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: MacRecordingStore.discardedKey) ?? []) {
        didSet { UserDefaults.standard.set(Array(noMeetingCaptureIDs.sorted().suffix(100)), forKey: MacRecordingStore.discardedKey) }
    }
    nonisolated static let discardedKey = "macRecording.discardedCaptureIDs"
    /// 0.5.334: the server advertises POST /api/meeting/sessions/:id/discard (capabilities `discard: true`, 6.84.0).
    @Published private(set) var serverDiscard = false
    /// 0.5.336 (server 6.86.0): the start's answer about live cues, for "Cues off: ..." in the live view. nil when the
    /// start did not ask, or the server did not say. A refusal never fails the recording.
    @Published private(set) var liveCuesArm: MacLiveCuesArm?
    /// Whether a start asks the server for live cues (COSControlApp: LiveMeetingCapability.sendsMacLiveCues).
    var liveCuesWanted: (@MainActor () -> Bool)?
    /// Whether the grey line's preview posts now, for this capture id (COSControlApp: the capability, the setting and the
    /// live view open on this recording).
    var previewWanted: (@MainActor (String) -> Bool)?
    /// Where a preview answer goes (ControllerModel.liveProvisional, memory only).
    var previewDelivered: (@MainActor (String, LiveProvisionalLine) -> Void)?
    private var previewTask: Task<Void, Never>?
    /// The title the fail-fast capture had, for Try again.
    private var cannotHearTitle: String?
    private var failFast = false
    /// Only while recording (Miles 2026-10-15: "No sound… for 24s" stayed on the live pane and this panel after the capture
    /// stopped and saved). Once stopped, a silent capture is reported by the save (noSpeech), not by this live check.
    var signalWarning: String? {
        guard isRecording else { return nil }
        if let stall = stallLine { return stall }
        if let line = MacRecordingHearing.line(hearing, recording: isRecording) { return line }
        return MacRecordingSignal.warning(silentChunks: silentChunks, source: manifest?.sourceName ?? "the selected source")
    }
    /// 0.5.334: Discard is offered for a stopped capture the server called no speech or that is exact zeros here.
    var canDiscard: Bool {
        MacRecordingDiscard.offered(noSpeech: noSpeech, allZero: manifest?.allDigitalSilence == true, pending: phase == "pending",
                                    stopped: manifest?.stopped == true, delivering: deliveryTask != nil)
    }
    /// "Retry saving retained audio" only where a retry can work.
    var canRetrySave: Bool {
        MacRecordingDiscard.retryOffered(noSpeech: noSpeech, allZero: manifest?.allDigitalSilence == true, pending: phase == "pending",
                                         hasChunks: manifest?.chunks.isEmpty == false, delivering: deliveryTask != nil)
    }
    /// 0.5.351: what the panel says about this capture (MacRecordingSaveStatus): Saving…, then Saved.
    var saveLine: MacRecordingSaveStatus.Line {
        MacRecordingSaveStatus.line(phase: phase, message: message, chunks: manifest?.chunks.count ?? 0, acknowledged: manifest?.acknowledged ?? 0,
                                    delivering: deliveryTask != nil, paused: deliveryPaused, waiting: waitingToRetry, slow: slowSave,
                                    noSpeech: noSpeech, allZero: manifest?.allDigitalSilence == true)
    }
    /// 0.5.334: the pane the panel's Open System Settings shows (ControllerModel.requestSystemAudio with the pane).
    var openSystemAudioSettings: (@MainActor () async -> Void)?
    /// A capture was discarded (Meetings re-reads its stranded list).
    var discarded: ((String) -> Void)?
    var isRecording: Bool { phase == "recording" }
    /// 0.5.320: prepareToQuit (stop) has work to do only in these phases; any other phase quits at once.
    var needsQuitTeardown: Bool { ["starting", "recording", "stopping"].contains(phase) }
    var occupied: Bool { !["idle", "saved", "pending"].contains(phase) }
    var canStart: Bool { !occupied && deliveryTask == nil && (manifest == nil || manifest!.saved || manifest!.chunks.isEmpty) }
    private var bridge: Bridge?
    private let spool: MacRecordingSpool
    private var capture: (any MacCaptureSession)?
    private var chunksTask: Task<Void, Never>?
    /// 0.5.351: stores chunks on its own executor, never the main actor (see MacRecordingWriterEvent); `chunksTask` only
    /// reads what it stored.
    private var writerTask: Task<Void, Never>?
    private var progress: MacRecordingProgress?
    private var watchdogTask: Task<Void, Never>?
    private var watchdog = MacRecordingWatchdog.State()
    private var restartInFlight = false
    /// 0.5.351: the watchdog's line while no chunk is being written (MacRecordingWatchdog.line); nil otherwise.
    @Published private(set) var stallLine: String?
    private var streamContinuation: AsyncStream<MacRecordingChunk>.Continuation?
    private var deliveryTask: Task<Void, Never>?
    private var deliveryWake = false
    private var instance: String?
    private var startAttempt: UUID?
    private var captureInterruption: String?
    private let stopGate = MacRecordingStopGate()
    private var observers: [NSObjectProtocol] = []
    var activeChanged: ((Bool) -> Void)?
    /// 0.5.322: every phase change, for MacCaptureStateFile (ControllerModel.recordMacCaptureState). Nil in a test model.
    var phaseRecorder: ((String) -> Void)?
    /// A stop the person did not make (limit, sleep, capture failure), with its reason.
    var stoppedOnItsOwn: ((String) -> Void)?
    var openLiveMeeting: ((String) -> Void)?
    /// 0.5.318: ControllerModel.requestSystemAudio, wired in COSControlApp. Whether System Audio Recording is allowed.
    var requestSystemAudio: (@MainActor () async -> Bool)?
    private var askingSystemAudio = false
    init(spool: MacRecordingSpool = MacRecordingSpool()) { self.spool = spool }

    func prepare(bridge: @escaping Bridge) async {
        self.bridge = bridge
        guard !occupied else { return }
        do {
            do {
                recoverable = try await spool.recoverable()
                let warnings = await spool.recoveryWarnings()
                if !warnings.isEmpty { error = warnings.joined(separator: " ") }
                if #available(macOS 14.2, *) {
                    let result = try await invoke("capabilities", [:])
                    guard result["available"]?.bool == true, let id = result["serverInstanceId"]?.string, !id.isEmpty else {
                        throw MacRecordingError.unavailable("Manual Mac recording needs the matched server candidate. Your current recording settings have not changed.")
                    }
                    instance = id; available = true
                    serverDiscard = result["discard"]?.bool == true
                    // 0.5.351: the server answered, so drop retained captures it already saved (MacRecordingReconcile).
                    recoverable = await reconciled(recoverable)
                    sources = [.allMacAudio] + (try await Task.detached(priority: .utility) { try MacAudioCapture.sources() }.value)
                    if !sources.contains(where: { $0.id == selectedID }) { selectedID = MacAudioSource.allMacAudioID }
                } else { throw MacRecordingError.unavailable("Manual system audio recording requires macOS 14.2 or later.") }
            } catch where !(error is CancellationError) {
                // QA 0.5.313 telemetry: the reason, once; cancellation is not a failure and is not logged.
                let reason = error.localizedDescription
                recordingLog.error("prepare failed: \(reason, privacy: .public)")
                throw error
            }
        } catch is CancellationError {
            // The panel's .task is cancelled when Meetings goes away (Miles 2026-10-15: the panel showed "The operation
            // couldn't be completed. (Swift.CancellationError error 1.)"). Leaving is not a failure: keep what was known.
            return
        } catch { available = false; self.error = error.localizedDescription }
    }
    private func invoke(_ operation: String, _ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let bridge else { throw MacRecordingError.unavailable("Recording transport is not connected.") }
        lastFailure = (nil, nil)
        let response = try await bridge(operation, payload)
        guard response.ok else {
            lastFailure = (response.details["httpStatus"]?.int, response.details["reason"]?.string)
            if operation == "save", response.details["reason"]?.string == "nothing_to_save" { noSpeech = true }
            throw MacRecordingError.unavailable(response.message)
        }
        return response.details
    }
    /// The one-time notice, acknowledged on this Mac (0.5.313).
    var noticeAcknowledged: Bool { UserDefaults.standard.bool(forKey: MacRecordingNotice.acknowledgedKey) }
    /// Only the notice card's Record calls this, in the panel and on the pet.
    func acknowledgeNotice() { UserDefaults.standard.set(true, forKey: MacRecordingNotice.acknowledgedKey); objectWillChange.send() }
    /// Settings → Show the recording notice again.
    func resetNotice() { UserDefaults.standard.set(false, forKey: MacRecordingNotice.acknowledgedKey); objectWillChange.send() }

    /// THE way to start a Mac recording (0.5.313): Meetings' Record and the pet's meeting card both come here, behind
    /// the same one-time notice. Returns the capture id once recording, or nil with `error` saying why.
    func record(title chosen: String, sourceID: UInt32, bridge: @escaping Bridge) async -> String? {
        guard MacRecordingNotice.step(acknowledged: noticeAcknowledged) == .start else { return nil }
        if !available || self.bridge == nil { await prepare(bridge: bridge) }
        // A retained capture has its own id and spool folder and stays listed with Recover; it never blocks a new one
        // (0.5.311 recorded beside one; QA 2026-10-15: a recoverable gate here made Record and the meeting card dead).
        guard available, canStart else {
            let pendingCapture = deliveryTask != nil || (manifest.map { !$0.saved && !$0.chunks.isEmpty } ?? false)
            switch MacRecordingRefusal.decide(available: available, currentError: error, live: occupied, pendingCapture: pendingCapture) {
            case .keep: break
            case .set(let text): error = text
            }
            recordingLog.notice("record refused: available=\(self.available) live=\(self.occupied) pending=\(pendingCapture)")
            return nil
        }
        let previousTitle = title, previousSource = selectedID
        selectedID = sourceID; title = chosen
        await start()
        title = previousTitle; selectedID = previousSource
        return isRecording ? manifest?.captureId : nil
    }

    /// Only `record` calls this; no initialization, detection, or permission probe records audio.
    private func start() async {
        guard noticeAcknowledged else { return }
        guard canStart, available, let instance, let source = sources.first(where: { $0.id == selectedID }) else { return }
        guard #available(macOS 14.2, *) else { return }
        // 0.5.318: every tap needs System Audio Recording, and macOS lists COS Control only once COS has asked. Ask
        // before the capture starts, so the prompt is answered before the first chunk. A no still records as before:
        // the drag flow is up, and the silence warning says so if nothing arrives.
        if !DictationQuietController.tapPermitted, let ask = requestSystemAudio {
            guard !askingSystemAudio else { return }
            askingSystemAudio = true
            let allowed = await ask()
            askingSystemAudio = false
            recordingLog.notice("system audio before recording: allowed=\(allowed)")
            guard noticeAcknowledged, canStart, available else { return }
        }
        phase = "starting"; error = nil; noSpeech = false; captureInterruption = nil; silentChunks = 0; heardSound = false; deliveryPaused = false
        LiveAudiogramFeed.live.reset()
        hearing = MacRecordingHearing.State(); cannotHear = false; failFast = false; cannotHearTitle = nil
        slowTask?.cancel(); slowTask = nil; slowSave = false; waitingToRetry = false
        let attempt = UUID(); startAttempt = attempt
        watchdog = MacRecordingWatchdog.State(); stallLine = nil; restartInFlight = false
        installStopObservers()
        var localCapture: MacAudioCapture?
        var localContinuation: AsyncStream<MacRecordingChunk>.Continuation?
        let id = "mac_" + UUID().uuidString.lowercased()
        let startTime = (Date().timeIntervalSince1970 * 1_000).rounded(.down)
        liveCuesArm = nil
        do {
            // 0.5.336 (server 6.86.0): live cues ride on the start, only when the person has Live cues on and the server
            // takes the flag. Never /live-cues/start for a mac_ id.
            var startPayload: [String: JSONValue] = ["captureId": .string(id), "serverInstanceId": .string(instance), "startTime": .number(startTime)]
            let asksCues = liveCuesWanted?() == true
            if asksCues { startPayload["liveCues"] = .bool(true) }
            let response = try await invoke("start", startPayload)
            guard startAttempt == attempt, phase == "starting" else { throw CancellationError() }
            guard response["sessionId"]?.string == id, response["speakerPolicy"]?.string == "high-confidence",
                  response["sourceType"]?.string == "mac_system_audio", response["sampleRate"]?.int == 16_000,
                  response["channels"]?.int == 1, response["bitsPerSample"]?.int == 16 else {
                throw MacRecordingError.unavailable("The server did not confirm this recording’s source and strict speaker policy.")
            }
            if asksCues { liveCuesArm = LiveMeeting.arm(response["liveCues"]) }
            let initial = MacRecordingManifest(captureId: id, startTime: startTime, serverInstanceId: instance,
                sourceName: source.name, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Mac recording" : String(title.prefix(160)),
                stopped: false, saved: false, acknowledged: 0, chunks: [])
            try await spool.write(initial)
            guard startAttempt == attempt, phase == "starting" else { _ = try await spool.markStopped(id); throw CancellationError() }
            manifest = initial
            let (stream, continuation) = AsyncStream<MacRecordingChunk>.makeStream(bufferingPolicy: .bufferingOldest(8))
            localContinuation = continuation
            streamContinuation = continuation
            // 0.5.351: the writer stores every chunk on its own executor and keeps storing while the main actor is busy or
            // blocked. Before, the main actor stored them, so a stalled app let the tap's 8-chunk buffer fill and the
            // capture failed without a word (mac_b0bd6732, 12:39 to 12:40). The index and end frame are the journal's own,
            // so a restarted tap continues the same sequence.
            let progress = MacRecordingProgress(); self.progress = progress
            let (stored, storedContinuation) = AsyncStream<MacRecordingWriterEvent>.makeStream(bufferingPolicy: .unbounded)
            let spool = self.spool
            MacRecordingOpenCaptures.shared.add(id, spool: spool)
            writerTask = Task.detached(priority: .userInitiated) {
                var sequence = MacRecordingSequencer()
                for await raw in stream {
                    let silent = MacRecordingSignal.isSilent(raw.pcm)
                    let chunk = sequence.next(raw)
                    do {
                        let journal = try await spool.append(chunk, captureId: id)
                        sequence.stored(journal); progress.mark()
                        storedContinuation.yield(.init(chunk: MacRecordingWriterEvent.slim(chunk), silent: silent, manifest: journal))
                    } catch {
                        let reason = error.localizedDescription
                        recordingLog.error("append failed: \(reason, privacy: .public)")
                        storedContinuation.yield(.init(failure: reason)); break
                    }
                }
                storedContinuation.finish()
            }
            chunksTask = Task { [weak self] in
                for await event in stored {
                    guard let self else { break }
                    if let reason = event.failure { self.captureInterruption = reason; Task { await self.stop() }; break }
                    guard let chunk = event.chunk, let journal = event.manifest else { continue }
                    self.takeStored(journal)
                    if event.silent { self.silentChunks += 1 } else { self.silentChunks = 0; self.heardSound = true }
                    if self.silentChunks == MacRecordingSignal.warnAfterSilentChunks {
                        let count = self.silentChunks, source = self.manifest?.sourceName ?? "?"
                        recordingLog.warning("silent capture: \(count) chunks below the peak floor from \(source, privacy: .public)")
                    }
                    // 0.5.334: exact zeros from All Mac audio while another app plays is macOS not letting COS record.
                    if await self.hearingCheck(chunk, allMacAudio: source.isAllMacAudio) == .cannotHear {
                        Task { await self.stopCannotHear(id) }; break
                    }
                    self.deliverPending()
                }
            }
            let engine = makeEngine(id: id, source: source, continuation: continuation)
            localCapture = engine; capture = engine
            try await engine.start(source: source)
            guard startAttempt == attempt, phase == "starting" else { _ = await engine.stop(); throw CancellationError() }
            phase = "recording"
            startWatchdog(id: id, source: source)
            startPreviews(id)
            recordingLog.notice("start ok source=\(source.isAllMacAudio ? "all Mac audio" : "one app", privacy: .public) cues=\(asksCues ? (self.liveCuesArm?.armed == true ? "armed" : "refused") : "not asked", privacy: .public)")
            message = source.isAllMacAudio ? "Recording everything this Mac plays. Microphone off." : "Recording \(source.name) playback only. Microphone off."
        } catch {
            MacRecordingOpenCaptures.shared.remove(id)
            watchdogTask?.cancel(); watchdogTask = nil; stallLine = nil
            let interruption = await localCapture?.stop(); localContinuation?.finish()
            let reason = error is CancellationError ? "cancelled" : error.localizedDescription
            recordingLog.error("start failed: \(reason, privacy: .public)")
            guard startAttempt == attempt else { return }
            capture = nil
            streamContinuation?.finish(); await writerTask?.value; await chunksTask?.value
            streamContinuation = nil; writerTask = nil; chunksTask = nil
            for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers.removeAll()
            if manifest?.captureId == id {
                if let reason = interruption ?? captureInterruption { _ = try? await spool.interrupt(id, reason: reason) }
                manifest = try? await spool.markStopped(id)
            }
            // Pending only when this attempt left a capture to save; a start that failed before its manifest existed
            // goes back to where it was, never showing the previous (saved) recording as unsaved.
            if manifest?.captureId == id { phase = "pending" } else { phase = manifest?.saved == true ? "saved" : "idle" }
            self.error = error.localizedDescription
        }
    }
    /// The tap with this store's callbacks. Used by the start and by the watchdog's restart.
    @available(macOS 14.2, *)
    private func makeEngine(id: String, source: MacAudioSource, continuation: AsyncStream<MacRecordingChunk>.Continuation) -> MacAudioCapture {
        MacAudioCapture(chunk: { value in
            if case .enqueued = continuation.yield(value) { return true }
            return false
        }, failure: { [weak self] reason in
            Task { @MainActor in
                recordingLog.error("capture failed: \(reason, privacy: .public)")
                self?.captureInterruption = reason; await self?.stop()
            }
        }, probe: { [weak self] sawSignal in
            Task { @MainActor in await self?.hearingProbe(sawSignal, captureId: id, allMacAudio: source.isAllMacAudio) }
        }, level: { rms in
            // 0.5.336: the audiogram. A number, ten a second, into its own feed (never this store or the model).
            Task { @MainActor in LiveAudiogramFeed.live.push(rms: rms) }
        })
    }
    /// What the writer stored, into the panel's manifest. Never older than what is shown, never fewer acknowledgements.
    private func takeStored(_ journal: MacRecordingManifest) {
        guard let current = manifest, current.captureId == journal.captureId else { manifest = journal; return }
        if current.chunks.count > journal.chunks.count { return }
        var next = journal; next.acknowledged = max(next.acknowledged, current.acknowledged); manifest = next
    }

    // MARK: Watchdog (0.5.351)
    //
    // Every chunk length it looks at when the writer last stored a chunk (MacRecordingProgress). Five chunk lengths of
    // nothing: one bounded tap restart, said on the panel; if that does not bring audio back, the panel says Stop and save
    // keeps everything up to then. It never stops the recording itself (the person may be mid-call) and never touches a
    // stored chunk. The restart's chunks continue the journal's own sequence (MacRecordingSequencer).

    private func startWatchdog(id: String, source: MacAudioSource) {
        watchdogTask?.cancel()
        guard let progress else { return }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(MacRecordingWatchdog.pollSeconds) * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.watchdogTick(id: id, source: source, progress: progress)
            }
        }
    }
    private func watchdogTick(id: String, source: MacAudioSource, progress: MacRecordingProgress) async {
        guard phase == "recording", manifest?.captureId == id else { return }
        let now = Date(), last = progress.lastWrite
        let action = MacRecordingWatchdog.step(&watchdog, now: now, lastChunk: last, restartInFlight: restartInFlight)
        stallLine = MacRecordingWatchdog.line(watchdog)
        let quiet = Int(now.timeIntervalSince(last))
        switch action {
        case .none: break
        case .giveUp:
            recordingLog.error("watchdog: no chunk for \(quiet)s after \(self.watchdog.totalRestarts) restart(s); the recording keeps what it has")
        case .restart:
            recordingLog.error("watchdog: no chunk for \(quiet)s; restarting the tap (restart \(self.watchdog.totalRestarts) of \(MacRecordingWatchdog.maxRestartsPerRecording))")
            restartInFlight = true
            let worked = await MacRecordingBounded.run(seconds: TimeInterval(MacRecordingWatchdog.restartSeconds)) { [weak self] in
                await self?.restartTap(id: id, source: source) ?? false
            }
            restartInFlight = false
            recordingLog.notice("watchdog: restart \(worked == true ? "ok" : (worked == nil ? "timed out" : "failed"), privacy: .public)")
            if worked != true { watchdog.restartFailed(); stallLine = MacRecordingWatchdog.line(watchdog) }
        }
    }
    /// Stops the tap (its tail goes to the writer like any chunk), then starts a new one on the same stream.
    private func restartTap(id: String, source: MacAudioSource) async -> Bool {
        guard #available(macOS 14.2, *), let continuation = streamContinuation, let old = capture else { return false }
        _ = await old.stop()
        guard phase == "recording", manifest?.captureId == id else { return false }
        let engine = makeEngine(id: id, source: source, continuation: continuation)
        do { try await engine.start(source: source) }
        catch { recordingLog.error("watchdog: the new tap did not start: \(error.localizedDescription, privacy: .public)"); return false }
        guard phase == "recording", manifest?.captureId == id else { _ = await engine.stop(); return false }
        capture = engine
        return true
    }
    private func installStopObservers() {
        guard observers.isEmpty else { return }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    let reason = "Recording stopped because this Mac slept or the user session changed."
                    self?.captureInterruption = reason; await self?.stop()
                }
            })
        }
    }
    func stop() async {
        await stopGate.run { [self] in await finishStop() }
    }
    private func finishStop() async {
        guard ["recording", "starting"].contains(phase) else { return }
        startAttempt = nil
        phase = "stopping"
        recordingLog.notice("stop")
        previewTask?.cancel(); previewTask = nil
        watchdogTask?.cancel(); watchdogTask = nil; stallLine = nil
        // QA 0.5.313: an interruption is written to the journal and shown once, by MacRecordingInterruption.line (muted for
        // the two-hour limit). Copying it into `error` too showed the same news again in red, and nothing cleared it.
        if let reason = await capture?.stop() { captureInterruption = reason }
        capture = nil
        streamContinuation?.finish(); streamContinuation = nil
        // The writer first: every chunk the tap handed over is stored before the journal is marked stopped.
        await writerTask?.value; writerTask = nil
        await chunksTask?.value; chunksTask = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers.removeAll()
        if let id = manifest?.captureId {
            await spool.removePreview(captureId: id)
            do {
                if let reason = captureInterruption { _ = try await spool.interrupt(id, reason: reason) }
                manifest = try await spool.markStopped(id)
            }
            catch {
                let reason = error.localizedDescription
                recordingLog.error("markStopped failed: \(reason, privacy: .public)")
                self.error = reason
            }
            MacRecordingOpenCaptures.shared.remove(id)
        }
        phase = "pending"
        message = manifest?.chunks.isEmpty == true ? "Capture stopped before any audio was stored. There is nothing to save."
            : "Capture stopped. Audio stays on this Mac until its saved-meeting receipt is verified."
        if let reason = captureInterruption { stoppedOnItsOwn?(reason) }
        // 0.5.334: exact zeros are discarded (stopCannotHear), never delivered.
        if !failFast { deliverPending() }
    }

    // MARK: The grey line's previews (0.5.336, server 6.86.0)
    //
    // While a Mac recording runs and its live view is open on a server that advertises the grey line, the open chunk's
    // newest audio (at most 15 s; a chunk is 6 s) goes to POST /api/transcribe-stream/preview through the helper, every 2 s
    // at most and one at a time (LiveMeetingPreviewGate), and the answer's text goes to the live view. Cosmetic: a miss
    // or a failure changes nothing on the recording, three failures in a row pause the previews for a minute (0.5.337), and
    // the WAV is removed after each post. SECRET BOUNDARY: the text goes only to `previewDelivered`; nothing here logs.

    private func startPreviews(_ id: String) {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            var gate = LiveMeetingPreviewGate()
            // 0.5.337 (loop audit N14): the gate pauses after three failures and tries again a minute later.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, self.isRecording, self.manifest?.captureId == id else { return }
                guard self.previewWanted?(id) == true, gate.mayPost(now: Date()) else { continue }
                await self.postPreview(id, gate: &gate)
            }
        }
    }

    private func postPreview(_ id: String, gate: inout LiveMeetingPreviewGate) async {
        guard let capture, let bridge, let instance = manifest?.serverInstanceId, let open = await capture.openChunk() else { return }
        let pcm = LiveMeetingPreviewGate.window(open.pcm)
        guard let generation = gate.begin(chunkIndex: open.index, bytes: pcm.count, now: Date()) else { return }
        var answered = false
        defer { gate.finish(answered: answered) }
        guard let path = try? await spool.writePreview(pcm, captureId: id) else { return }
        let response = try? await bridge("preview", ["captureId": .string(id), "serverInstanceId": .string(instance), "path": .string(path),
                                                     "chunkIndex": .number(Double(open.index)), "previewGen": .number(Double(generation))])
        await spool.removePreview(captureId: id)
        guard let response, response.ok else { return }
        answered = true
        guard isRecording, manifest?.captureId == id,
              let line = LiveMeeting.previewAnswer(response.details, chunkIndex: open.index, previewGen: generation),
              gate.accept(chunkIndex: line.chunkIndex, previewGen: line.previewGen) else { return }
        previewDelivered?(id, line)
    }

    // MARK: Can COS hear this Mac? (0.5.334)

    /// One stored chunk through MacRecordingHearing. Reads whether another app is playing only when it can matter.
    private func hearingCheck(_ chunk: MacRecordingChunk, allMacAudio: Bool) async -> MacRecordingHearing.Verdict {
        let silence = chunk.digitalSilence
        var playing: Bool? = true
        if silence, allMacAudio, !hearing.heardSignal {
            if #available(macOS 14.2, *) { playing = await Task.detached(priority: .utility) { MacAudioCapture.othersPlaying() }.value }
        }
        var next = hearing
        let verdict = MacRecordingHearing.step(&next, digitalSilence: silence, othersPlaying: playing, allMacAudio: allMacAudio)
        if next != hearing { hearing = next }
        if silence, allMacAudio, !next.heardSignal {
            recordingLog.warning("hearing: chunk \(chunk.index) exact zeros playing=\(playing.map { $0 ? "yes" : "no" } ?? "unknown", privacy: .public) count=\(next.zeroChunksWhilePlaying)")
        }
        return verdict
    }
    /// The ~1 s probe through the same tap: sets the warning only; the fail-fast decides.
    private func hearingProbe(_ sawSignal: Bool, captureId: String, allMacAudio: Bool) async {
        guard manifest?.captureId == captureId, ["starting", "recording"].contains(phase) else { return }
        var playing: Bool? = true
        if !sawSignal, allMacAudio {
            if #available(macOS 14.2, *) { playing = await Task.detached(priority: .utility) { MacAudioCapture.othersPlaying() }.value }
        }
        guard manifest?.captureId == captureId else { return }
        var next = hearing
        MacRecordingHearing.probe(&next, sawSignal: sawSignal, othersPlaying: playing, allMacAudio: allMacAudio)
        if next != hearing { hearing = next }
        recordingLog.notice("hearing probe: signal=\(sawSignal) playing=\(playing.map { $0 ? "yes" : "no" } ?? "unknown", privacy: .public) suspect=\(next.suspect)")
    }
    /// The fail-fast: stop, keep nothing pending (the zero audio moves to the discarded folder, the server is asked to let
    /// its side go) and show the one message with Open System Settings and Try again.
    private func stopCannotHear(_ id: String) async {
        guard manifest?.captureId == id, ["starting", "recording"].contains(phase) else { return }
        recordingLog.error("cannot hear: exact zeros from All Mac audio while another app played; stopping and discarding")
        failFast = true
        cannotHearTitle = manifest?.title
        captureInterruption = MacRecordingHearing.cannotHearMessage
        await stop()
        await discardNoSound(cannotHear: true)
    }
    /// Try again after the fail-fast: a fresh capture of All Mac audio with the same title.
    func tryAgainAfterCannotHear(bridge: @escaping Bridge) async -> String? {
        let again = cannotHearTitle ?? MacRecordingNotice.autoTitle(meetingApp: nil, at: Date())
        cannotHear = false
        return await record(title: again, sourceID: MacAudioSource.allMacAudioID, bridge: bridge)
    }

    // MARK: Discard a capture with no sound (0.5.334)

    private var discarder: MacRecordingDiscarder {
        MacRecordingDiscarder(spool: spool, server: { [weak self] captureId, serverInstanceId in
            await self?.askServerDiscard(captureId: captureId, serverInstanceId: serverInstanceId) ?? .unreachable
        })
    }
    @MainActor private func askServerDiscard(captureId: String, serverInstanceId: String) async -> MacRecordingDiscard.Server {
        guard let bridge else { return .unreachable }
        do {
            let response = try await bridge("discard", ["captureId": .string(captureId), "serverInstanceId": .string(serverInstanceId), "confirm": .bool(true)])
            return MacRecordingDiscard.serverAnswer(ok: response.ok, httpStatus: response.details["httpStatus"]?.int, reason: response.details["reason"]?.string,
                                                    discarded: response.details["discarded"]?.bool, replayed: response.details["replayed"]?.bool)
        } catch { return .unreachable }
    }
    /// A not-yet-idle server is asked again past its idle window, a bounded number of times, while Control runs.
    private func retryServerDiscard(captureId: String, serverInstanceId: String, left: Int) {
        guard left > 0 else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(MacRecordingDiscard.retryAfterSeconds))
            guard let self else { return }
            let answer = await self.askServerDiscard(captureId: captureId, serverInstanceId: serverInstanceId)
            recordingLog.notice("discard retry: server=\(String(describing: answer), privacy: .public)")
            if answer == .notIdle { self.retryServerDiscard(captureId: captureId, serverInstanceId: serverInstanceId, left: left - 1) }
            else { self.discarded?(captureId) }
        }
    }
    /// Discard (no sound was captured), after the panel's confirm, and the fail-fast. Never removes a file.
    func discardNoSound(cannotHear failFastStop: Bool = false) async {
        guard let value = manifest, phase == "pending", value.stopped, !value.saved,
              failFastStop || canDiscard || value.chunks.isEmpty else { return }
        phase = "discarding"
        deliveryWake = false
        if let delivering = deliveryTask { delivering.cancel(); await delivering.value }
        let outcome = await discarder.discard(captureId: value.captureId, serverInstanceId: value.serverInstanceId, serverSupported: serverDiscard)
        recordingLog.notice("discard: moved=\(outcome.moved != nil) server=\(String(describing: outcome.server), privacy: .public) chunks=\(value.chunks.count)")
        if let localError = outcome.localError {
            recordingLog.error("discard failed: \(localError, privacy: .public)")
            phase = "pending"; error = outcome.line; return
        }
        noMeetingCaptureIDs.insert(value.captureId)
        manifest = nil; noSpeech = false; deliveryPaused = false; silentChunks = 0; error = nil
        selectedID = MacAudioSource.allMacAudioID
        if failFastStop { cannotHear = true }
        phase = "idle"
        message = failFastStop ? MacRecordingHearing.cannotHearMessage : outcome.line
        recoverable = (try? await spool.recoverable()) ?? recoverable
        if outcome.server == .notIdle { retryServerDiscard(captureId: value.captureId, serverInstanceId: value.serverInstanceId, left: MacRecordingDiscard.retries) }
        discarded?(value.captureId)
    }
    /// A stranded Mac row on Meetings (the server says no speech): its local copy, if this Mac has it, and the server's.
    func discardStranded(_ sessionId: String, bridge passed: Bridge? = nil) async -> String {
        if let passed, bridge == nil { bridge = passed }
        if manifest?.captureId == sessionId {
            guard canDiscard else { return "This Mac recording is still being delivered. Discard it once it stops." }
            await discardNoSound(); return error ?? message
        }
        if !available || instance == nil, let bridge { await prepare(bridge: bridge) }
        let retained = try? await spool.recoverable()
        let local = retained?.first { $0.captureId == sessionId }
        guard let pin = local?.serverInstanceId ?? instance else { return "COS couldn't reach its recording helper. Try again in a moment." }
        let outcome = await discarder.discard(captureId: sessionId, serverInstanceId: pin, serverSupported: serverDiscard, localPresent: local != nil)
        recordingLog.notice("discard stranded: local=\(local != nil) server=\(String(describing: outcome.server), privacy: .public)")
        if outcome.localError == nil {
            noMeetingCaptureIDs.insert(sessionId)
            recoverable = (try? await spool.recoverable()) ?? recoverable
            if outcome.server == .notIdle { retryServerDiscard(captureId: sessionId, serverInstanceId: pin, left: MacRecordingDiscard.retries) }
            discarded?(sessionId)
        }
        return outcome.line
    }
    /// 0.5.313: Record on the pet's meeting card. Always All Mac audio, the proven source, never a per-app tap.
    func startFromMeetingSuggestion(title meetingTitle: String, bridge: @escaping Bridge) async -> String? {
        await record(title: meetingTitle, sourceID: MacAudioSource.allMacAudioID, bridge: bridge)
    }
    /// 0.5.351 (MacRecordingReconcile, mac_b0bd6732): a retained capture the server already saved is marked saved in its
    /// journal and leaves the list. Asked once per retained capture whose every chunk reached the server; a refusal, an
    /// unreachable server or any doubt keeps the row. Never touches audio.
    private func reconciled(_ retained: [MacRecordingManifest]) async -> [MacRecordingManifest] {
        var kept: [MacRecordingManifest] = []
        for value in retained {
            guard MacRecordingReconcile.shouldAsk(value, current: manifest?.captureId), await savedOnServer(value) else { kept.append(value); continue }
            do {
                _ = try await spool.markSavedOnServer(value.captureId)
                recordingLog.notice("reconcile: saved on server, journal marked saved chunks=\(value.chunks.count)")
            } catch {
                kept.append(value)
                recordingLog.error("reconcile: journal not marked, kept")
            }
        }
        return kept
    }
    private func savedOnServer(_ value: MacRecordingManifest) async -> Bool {
        guard let bridge,
              let response = try? await bridge("status", ["captureId": .string(value.captureId), "serverInstanceId": .string(value.serverInstanceId)]) else { return false }
        let receipt = response.details["saveReceipt"]?.object
        return MacRecordingReconcile.savedOnServer(captureId: value.captureId, .init(
            ok: response.ok, state: response.details["state"]?.string, sessionId: response.details["sessionId"]?.string,
            receiptSaved: receipt?["saved"]?.bool, receiptVersion: receipt?["receiptVersion"]?.int, receiptSessionId: receipt?["sessionId"]?.string,
            receiptCaptureId: receipt?["captureId"]?.string, receiptSourceType: receipt?["sourceType"]?.string))
    }
    /// The spool's recoverable list, read locally (no helper, no capture), so a meeting suggestion never buries one.
    func refreshRecoverable() async {
        guard !occupied, let retained = try? await spool.recoverable() else { return }
        recoverable = retained
    }
    /// Quit defers only for native teardown and local flush, never network or ASR.
    func prepareToQuit() async { await stop() }
    enum RecoverOutcome: Equatable { case started, busy, failed(String) }
    /// The spool's retained captures, read now: nil only when the read itself failed (never "absent" on a failed read).
    func retainedCaptures() async -> [MacRecordingManifest]? {
        do { return try await spool.recoverable() } catch {
            recordingLog.error("retained read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    /// Replays a retained capture. Callers outside the Meetings panel pass the bridge (QA 0.5.313: Save on a stranded
    /// Mac row before Meetings was opened had no transport and failed with "Recording transport is not connected.").
    @discardableResult
    func recover(_ value: MacRecordingManifest, bridge: Bridge? = nil) async -> RecoverOutcome {
        guard canStart else { recordingLog.notice("recover refused: a capture is live or delivering"); return .busy }
        if let bridge, self.bridge == nil { self.bridge = bridge }
        // Occupied before the first await, so Record cannot start in the gap (QA 0.5.313: the interleave ended in a raw
        // CancellationError and an idle panel while delivery ran).
        let before = phase
        phase = "recovering"
        do {
            // A restart never resumes the tap. Pinning refuses replay into a different server instance.
            if !value.stopped { _ = try await spool.interrupt(value.captureId, reason: "The app ended during recording. Unflushed audio may be missing; retained chunks can be recovered.") }
            manifest = try await spool.markStopped(value.captureId); phase = "pending"; error = nil; noSpeech = false; deliveryPaused = false
            recordingLog.notice("recover chunks=\(value.chunks.count)")
            deliverPending()
            return .started
        } catch {
            let reason = error.localizedDescription
            recordingLog.error("recover failed: \(reason, privacy: .public)")
            phase = before
            self.error = reason
            return .failed(reason)
        }
    }
    /// 0.5.351: why Recover is grayed out right now, shown under the Recover buttons (nil when it is available).
    var recoverUnavailable: String? {
        MacRecordingRecoveryPolicy.recoverUnavailable(phase: phase, delivering: deliveryTask != nil,
                                                      currentUnsaved: manifest.map { !$0.saved && !$0.chunks.isEmpty } ?? false)
    }
    var canKeepForLater: Bool {
        MacRecordingRecoveryPolicy.canKeepForLater(noSpeech: noSpeech, paused: deliveryPaused, pending: phase == "pending", stopped: manifest?.stopped == true, delivering: deliveryTask != nil)
    }
    /// Leaves the immutable journal and WAVs untouched; only releases the current editor.
    /// Offered only after the server positively reported that no speech was saved.
    func keepSilentAudioForLater() async {
        guard canKeepForLater else { return }
        recordingLog.notice("keep for later noSpeech=\(self.noSpeech) paused=\(self.deliveryPaused)")
        do {
            let retained = try await spool.recoverable()
            recoverable = retained; manifest = nil; deliveryPaused = false; selectedID = MacAudioSource.allMacAudioID; noSpeech = false; silentChunks = 0; error = nil; phase = "idle"
            message = "Previous audio is kept on this Mac. All Mac audio is selected: it records whatever app plays the call."
        } catch {
            let reason = error.localizedDescription
            recordingLog.error("keep for later failed: \(reason, privacy: .public)")
            self.error = reason
        }
    }
    func deliverPending() {
        guard phase != "discarding" else { return }
        if manifest?.stopped == true, manifest?.saved == false { armSlowSave() }
        if deliveryTask != nil { deliveryWake = true; return }
        guard let id = manifest?.captureId else { return }
        deliveryWake = false
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            var failed = false
            // A new attempt replaces the last attempt's "Delivery paused: …" (it stayed red through a later save).
            if self.deliveryPaused { self.error = nil }
            self.deliveryPaused = false
            defer {
                self.deliveryTask = nil
                if self.deliveryWake && !failed { self.deliveryWake = false; self.deliverPending() }
            }
            do {
                while !Task.isCancelled {
                    var current = try await self.spool.snapshot(id)
                    if current.acknowledged < current.chunks.count {
                        let chunk = current.chunks[current.acknowledged]
                        let path = try await self.spool.path(for: chunk, captureId: id)
                        let receipt = try await self.deliveryCall("chunk", captureId: id, ["captureId": .string(id), "serverInstanceId": .string(current.serverInstanceId),
                            "path": .string(path), "chunkIndex": .number(Double(chunk.index)), "elapsed": .number(Double(chunk.endFrame) / 16)])
                        guard receipt["sessionId"]?.string == id, receipt["chunkIndex"]?.int == chunk.index,
                              receipt["serverInstanceId"]?.string == current.serverInstanceId, receipt["asrCompleted"]?.bool == true,
                              receipt["canonical"]?.bool != nil else {
                            throw MacRecordingError.unavailable("The server did not acknowledge this exact audio chunk. Its local copy is retained.")
                        }
                        current = try await self.spool.acknowledge(id, index: chunk.index); self.manifest = current
                        continue
                    }
                    if current.stopped, !current.chunks.isEmpty, !current.saved {
                        let saved = try await self.deliveryCall("save", captureId: id, ["captureId": .string(id), "serverInstanceId": .string(current.serverInstanceId), "title": .string(current.title), "expectedChunkCount": .number(Double(current.chunks.count))])
                        guard saved["saved"]?.bool == true, saved["receiptVersion"]?.int == 1,
                              saved["serverInstanceId"]?.string == current.serverInstanceId,
                              saved["sessionId"]?.string == id, saved["captureId"]?.string == id,
                              saved["sourceType"]?.string == "mac_system_audio" else {
                            throw MacRecordingError.unavailable("A saved-meeting receipt was not verified. Audio is retained for recovery.")
                        }
                        self.manifest = try await self.spool.markSaved(id)
                        self.slowTask?.cancel(); self.slowTask = nil; self.slowSave = false
                        recordingLog.notice("save ok chunks=\(current.chunks.count)")
                        if self.error?.hasPrefix("Delivery paused:") == true { self.error = nil }
                        self.phase = "saved"; self.message = "Saved Mac recording. Open Meetings to review the transcript."
                        self.recoverable = try await self.spool.recoverable()
                    }
                    break
                }
            } catch { failed = true; self.deliveryPaused = true; let reason = error.localizedDescription; recordingLog.error("delivery paused: \(reason, privacy: .public)")
                // 0.5.334: no speech is not a paused delivery to retry. The panel offers Discard and says why; no red
                // "Delivery paused: ... Choose the app" line, and the hand-off stops looking for a meeting.
                // 0.5.351: while recording, a passing failure is retried by the next chunk; it shows as "COS is not
                // answering" once COS falls behind (MacRecordingSaveStatus), never as a red line that clears 6 s later.
                if self.noSpeech { self.noMeetingCaptureIDs.insert(id); self.error = nil }
                else { self.error = self.isRecording && self.deliveryFailureTransient ? nil : "Delivery paused: \(error.localizedDescription) Audio is retained. Retry does not restart recording." }
            }
        }
    }
    /// 0.5.351: one chunk or save call. Once the capture is stopped, a passing failure is tried again quietly, at most
    /// retryDelays.count more times; anything else, a cancel or a phase change ends it and the caller pauses as before.
    private func deliveryCall(_ operation: String, captureId id: String, _ payload: [String: JSONValue]) async throws -> [String: JSONValue] {
        var attempt = 0
        while true {
            do {
                let answer = try await invoke(operation, payload)
                deliveryFailureTransient = false
                return answer
            } catch {
                // Read before the next await: the refusal's status and reason when the helper answered, else the
                // helper's own "did not answer" sentence.
                let transient = MacRecordingSaveRetry.transient(httpStatus: lastFailure.httpStatus, reason: lastFailure.reason, message: error.localizedDescription)
                deliveryFailureTransient = transient
                let stopped = (try? await spool.snapshot(id))?.stopped == true
                guard !Task.isCancelled, phase == "pending", manifest?.captureId == id, attempt < retryDelays.count,
                      MacRecordingSaveRetry.delay(afterAttempt: attempt, stopped: stopped, transient: transient) != nil else { throw error }
                let pause = retryDelays[attempt]
                attempt += 1
                recordingLog.notice("save retry: op=\(operation, privacy: .public) attempt=\(attempt) wait=\(pause)s status=\(self.lastFailure.httpStatus ?? 0) reason=\(self.lastFailure.reason ?? "none", privacy: .public)")
                waitingToRetry = true
                try? await Task.sleep(for: .seconds(pause))
                waitingToRetry = false
                guard !Task.isCancelled, phase == "pending", manifest?.captureId == id else { throw error }
            }
        }
    }
    /// 0.5.351: after slowSaveAfter, a save still running says how far it got. One timer per save; a new one on Retry.
    private func armSlowSave() {
        guard slowTask == nil else { return }
        slowSave = false
        let id = manifest?.captureId
        slowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.slowSaveAfter ?? MacRecordingSaveStatus.slowAfterSeconds))
            guard let self, !Task.isCancelled else { return }
            self.slowTask = nil
            if self.manifest?.captureId == id, self.manifest?.saved == false, self.deliveryTask != nil { self.slowSave = true }
        }
    }
}

protocol MacCaptureSession: AnyObject, Sendable {
    /// 0.5.336: the open chunk's index and PCM so far, for the grey line's preview.
    func openChunk() async -> (index: Int, pcm: Data)?
    func stop() async -> String?
}
@available(macOS 14.2, *)
extension MacAudioCapture: MacCaptureSession {}

struct MacRecordingPanel: View {
    @ObservedObject var store: MacRecordingStore
    let bridge: MacRecordingStore.Bridge
    /// 0.5.313: the detected meeting app names the recording ("Zoom meeting 2:05 PM").
    @ObservedObject var meetings: MeetingDetectorStore = MeetingDetectorStore.shared
    /// Title, audio source and Refresh apps live under Options, collapsed until the person opens it (remembered).
    @AppStorage(MacRecordingNotice.optionsExpandedKey) private var optionsExpanded = false
    /// The one-time notice, inline (never a system alert; Tests/run.sh keeps confirmations inline).
    @State private var showingNotice = false
    /// The notice hides the moment it is acknowledged anywhere (the pet's notice too), not only by this card.
    @AppStorage(MacRecordingNotice.acknowledgedKey) private var acknowledged = false
    /// 0.5.334: Discard (no sound was captured) asks once, inline.
    @State private var confirmDiscard = false
    private var noticeVisible: Bool { MacRecordingNotice.panelShowsNotice(requested: showingNotice, acknowledged: acknowledged, occupied: store.occupied) }
    private var recordable: Bool { store.canStart && store.available && store.sources.contains { $0.id == store.selectedID } }
    private var automaticTitle: String { MacRecordingNotice.autoTitle(meetingApp: meetings.current?.app.title, at: Date()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(store.isRecording ? "Recording on this Mac" : "Record on Mac · pilot", systemImage: store.isRecording ? "record.circle.fill" : "waveform")
                    .font(COSType.body(12, weight: .semibold)).foregroundStyle(store.isRecording ? COSPalette.danger : COSPalette.ink)
                if store.isRecording {
                    Text(MacRecordingNotice.reminder).font(COSType.body(10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isRecording, let id = store.manifest?.captureId {
                    Button("Open live meeting") { store.openLiveMeeting?(id) }.buttonStyle(COSQuietButtonStyle())
                }
                if store.isRecording || store.phase == "starting" { Button("Stop and save") { Task { await store.stop() } }.buttonStyle(COSQuietButtonStyle()) }
                else if !store.occupied, !noticeVisible {
                    Button("Record") { record() }.buttonStyle(COSPrimaryButtonStyle()).disabled(!recordable)
                        .help("Records everything this Mac plays, with a live transcript. Your microphone stays off")
                }
            }
            // 0.5.334: the fail-fast's one message, with the two things that can fix it.
            if store.cannotHear && !store.occupied {
                VStack(alignment: .leading, spacing: 6) {
                    Text(MacRecordingHearing.cannotHearMessage).font(COSType.body(11.5, weight: .semibold)).foregroundStyle(COSPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button(MacRecordingHearing.openSettingsTitle) { Task { await store.openSystemAudioSettings?() } }
                            .buttonStyle(COSQuietButtonStyle())
                        Button(MacRecordingHearing.tryAgainTitle) { Task { _ = await store.tryAgainAfterCannotHear(bridge: bridge) } }
                            .buttonStyle(COSPrimaryButtonStyle()).disabled(!store.canStart || !store.available)
                    }
                }
            }
            if noticeVisible {
                MacRecordingNoticeCard(onRecord: {
                    store.acknowledgeNotice(); showingNotice = false; record()
                }, onNotNow: { showingNotice = false })
            }
            if !store.occupied {
                DisclosureGroup("Options", isExpanded: $optionsExpanded) {
                    HStack {
                        TextField(automaticTitle, text: $store.title).textFieldStyle(.plain).cosField().frame(maxWidth: 260)
                            .help("Leave empty for the automatic title")
                        COSDropdown("Audio source", selection: $store.selectedID,
                            options: store.sources.map {
                                COSDropdownOption($0.id, $0.isAllMacAudio ? "All Mac audio (recommended)" : "\($0.name) only (\($0.pid))")
                            }).frame(maxWidth: 320)
                        Button("Refresh apps") { Task { await store.prepare(bridge: bridge) } }
                    }
                    .padding(.top, 4)
                }
                .font(COSType.body(11))
            }
            if store.occupied || store.manifest != nil {
                // 0.5.351 (quick save): Saving…, then Saved. The count and the retained-recording buttons only when the
                // save is slow or stopped on an error (MacRecordingSaveStatus), never through an ordinary save.
                let line = store.saveLine
                Text(line.headline).font(COSType.body(11, weight: line.tone == .quiet ? .regular : .semibold))
                    .foregroundStyle(line.tone == .quiet ? COSPalette.muted : COSPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = line.detail {
                    Text(detail).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let progress = line.progress { Text(progress).font(COSType.body(11)).foregroundStyle(.secondary) }
                if let value = store.manifest {
                    if let warning = store.signalWarning {
                        Text(warning).font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.danger)
                    } else if store.isRecording {
                        Text(store.heardSound ? "Sound detected" : "Listening for sound…").font(COSType.body(11)).foregroundStyle(store.heardSound ? COSPalette.ink : COSPalette.muted)
                    }
                    if let interruption = value.interruption {
                        let line = MacRecordingInterruption.line(interruption)
                        Text(line.text).font(COSType.body(11)).foregroundStyle(line.problem ? COSPalette.danger : COSPalette.muted)
                    }
                    if line.showsActions, store.phase == "pending", !value.chunks.isEmpty {
                        let nothing = store.noSpeech || value.allDigitalSilence
                        Text(nothing ? "No sound was captured in this recording, so there is nothing to save." : "Save this retained recording before starting another.").font(COSType.body(11)).foregroundStyle(.secondary)
                        // 0.5.334: Keep only where it can help (a paused delivery); Retry only where a retry can work.
                        if store.canKeepForLater {
                            Button("Keep audio for later") { Task { await store.keepSilentAudioForLater() } }
                        }
                        if store.canDiscard {
                            Button(MacRecordingDiscard.buttonTitle) { confirmDiscard = true }
                        }
                        if store.canRetrySave {
                            Button("Retry saving retained audio") { store.deliverPending() }
                        }
                    }
                }
            }
            if let error = store.error { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.danger) }
            let retained = MacRecordingRecoveryPolicy.listed(store.recoverable, current: store.manifest?.captureId)
            ForEach(retained) { value in
                Button("Recover \(value.title) · \(value.chunks.count) chunks") { Task { await store.recover(value) } }.disabled(!store.canStart)
                    .help(store.canStart ? "Save this retained recording" : store.recoverUnavailable ?? "")
            }
            // 0.5.351 (Miles 2026-10-26): a grayed-out Recover says why, once, under the buttons.
            if !retained.isEmpty, !store.canStart, let reason = store.recoverUnavailable {
                Text(reason).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12).background(COSPalette.amber.opacity(0.06))
        .overlay(alignment: .bottom) { Divider() }
        .cosConfirm(MacRecordingDiscard.confirmTitle, isPresented: $confirmDiscard, message: MacRecordingDiscard.confirmLine, actions: [
            .destructive(MacRecordingDiscard.confirmButton) { confirmDiscard = false; Task { await store.discardNoSound() } },
            .cancel { confirmDiscard = false },
        ])
        .task { await store.prepare(bridge: bridge) }
    }
    /// Record: the one-time notice first on this Mac, then every Record starts at once.
    private func record() {
        guard MacRecordingNotice.step(acknowledged: store.noticeAcknowledged) == .start else { showingNotice = true; return }
        let title = MacRecordingNotice.title(typed: store.title, meetingApp: meetings.current?.app.title, at: Date())
        let source = store.selectedID
        Task {
            if await store.record(title: title, sourceID: source, bridge: bridge) != nil { store.title = "" }
        }
    }
}

/// The one-time recording notice (0.5.313), COS-styled and inline: in Meetings' Record on Mac and in the pet's card
/// slot. macOS's own System Audio Recording prompt is named in the footnote only while it has not been granted.
struct MacRecordingNoticeCard: View {
    var size: PetSize? = nil
    let onRecord: () -> Void
    let onNotNow: () -> Void
    @State private var permitted = DictationQuietController.tapPermitted
    private func scaled(_ value: CGFloat) -> CGFloat { size.map { $0.typeSize(value) } ?? value }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MacRecordingNotice.title).font(COSType.body(scaled(12.5), weight: .semibold)).foregroundStyle(COSPalette.ink)
            ForEach(MacRecordingNotice.lines, id: \.self) { line in
                Text(line).font(COSType.body(scaled(11))).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let footnote = MacRecordingNotice.footnote(permissionGranted: permitted) {
                Text(footnote).font(COSType.body(scaled(10))).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Record", action: onRecord).buttonStyle(COSPrimaryButtonStyle())
                Button("Not now", action: onNotNow).buttonStyle(COSQuietButtonStyle())
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(COSPalette.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(MacRecordingNotice.title)
    }
}

// MARK: - Meeting detection and the record suggestion (0.5.313)

enum MeetingCardKind: Equatable {
    case suggest
    /// The one-time recording notice, when Record on the suggestion is this Mac's first recording.
    case notice
    case ended
}

struct MeetingCard: Equatable, Identifiable {
    let id = UUID()
    let kind: MeetingCardKind
    let source: MeetingSource
}

/// Watches which processes hold the microphone (CoreAudio property listeners; a 2 s tick only while a meeting app
/// holds it or a meeting has not ended), and offers to record. Reads no audio and no screen; for a browser, only its
/// window titles through Accessibility, never logged. Logs name the app only.
@MainActor final class MeetingDetectorStore: ObservableObject {
    static let shared = MeetingDetectorStore()
    private static let neverKey = "meetingSuggest.never"

    @Published var suggestEnabled: Bool = UserDefaults.standard.object(forKey: "meetingSuggest.enabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(suggestEnabled, forKey: "meetingSuggest.enabled"); suggestEnabled ? activate() : deactivate() }
    }
    @Published private(set) var allowed: Set<MeetingApp> = Set(MeetingApp.allCases.filter {
        UserDefaults.standard.object(forKey: "meetingSuggest.app." + $0.rawValue) as? Bool ?? true
    })
    /// Owner bundle ID → name, for "Never for <App>" and its Remove in Settings.
    @Published private(set) var never: [String: String] = (UserDefaults.standard.dictionary(forKey: neverKey) as? [String: String]) ?? [:]
    @Published private(set) var card: MeetingCard?
    @Published private(set) var surface: DictationSurface = .pet
    @Published private(set) var floatingScreen: CGRect?
    /// A browser held the microphone but its titles could not be read: Google Meet needs Accessibility.
    @Published private(set) var browserNeedsAccessibility = false

    var recordingBusy: (() -> Bool)?
    var dictating: (() -> Bool)?
    var petFrame: (() -> NSRect?)?
    var runningCaptureID: (() -> String?)?
    var noticeAcknowledged: (() -> Bool)?
    var acknowledgeNotice: (() -> Void)?
    var record: ((MeetingSource) async -> String?)?
    var stopRecording: (() async -> Void)?

    private var state = MeetingDetectionState()
    /// The meeting app on the microphone now (the Record button's automatic title). Read when Record is pressed.
    var current: MeetingSource? { state.current }
    private var startedFrom: (source: MeetingSource, captureID: String)?
    private var listBlock: AudioObjectPropertyListenerBlock?
    private var inputBlocks: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var listenersUnavailable = false
    private var tickTask: Task<Void, Never>?
    /// QA 0.5.313: browser pids that showed a Meet title while on the mic (a tab switch never ends the call), the last
    /// title answer per browser, the reads in flight, and what held the mic at the last evaluation.
    private var browserLatch = Set<Int32>()
    private var titleCache: [String: Bool?] = [:]
    private var titleReads = Set<String>()
    private var lastHolders = Set<String>()
    private var tick = 0
    private var dismissTask: Task<Void, Never>?
    private let presenter = MeetingCardPresenter()

    private init() {}

    func setAllowed(_ app: MeetingApp, _ on: Bool) {
        if on { allowed.insert(app) } else { allowed.remove(app) }
        UserDefaults.standard.set(on, forKey: "meetingSuggest.app." + app.rawValue)
    }
    func removeNever(_ owner: String) {
        never[owner] = nil
        UserDefaults.standard.set(never, forKey: Self.neverKey)
    }

    // MARK: Listening

    func activate() {
        presenter.bind(store: self)
        guard suggestEnabled, listBlock == nil, !listenersUnavailable || tickTask == nil else { return }
        guard #available(macOS 14.2, *) else { return }
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.processesChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block) == noErr {
            listBlock = block
        } else {
            listenersUnavailable = true
            recordingLog.notice("meeting detection: no process listener; checking every 2 s")
        }
        processesChanged()
    }
    func deactivate() {
        tickTask?.cancel(); tickTask = nil
        if let listBlock, #available(macOS 14.2, *) {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, listBlock)
        }
        listBlock = nil
        unbindInputs(keeping: [])
        listenersUnavailable = false
        state = MeetingDetectionState()
        browserLatch = []; titleCache = [:]; lastHolders = []; tick = 0
        if card?.kind == .suggest || card?.kind == .notice { dismiss() }
    }

    private func processesChanged() {
        guard #available(macOS 14.2, *), suggestEnabled else { return }
        // 0.5.345 (A-W1 freeze instrumentation): a call that held the main thread over 100 ms is counted, so a
        // dictation's timing line can say whether meeting detection was what stalled it. A count, never a process name.
        let began = ProcessInfo.processInfo.systemUptime
        defer { MeetingListenerStats.note(ms: Int((ProcessInfo.processInfo.systemUptime - began) * 1000)) }
        let ids = Self.processObjects()
        if !listenersUnavailable { bindInputs(ids) }
        evaluate(ids)
    }

    @available(macOS 14.2, *)
    private func bindInputs(_ ids: [AudioObjectID]) {
        unbindInputs(keeping: Set(ids))
        for id in ids where inputBlocks[id] == nil {
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.processesChanged() }
            }
            if AudioObjectAddPropertyListenerBlock(id, &address, DispatchQueue.main, block) == noErr { inputBlocks[id] = block }
        }
    }
    private func unbindInputs(keeping: Set<AudioObjectID>) {
        guard #available(macOS 14.2, *) else { return }
        for (id, block) in inputBlocks where !keeping.contains(id) {
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(id, &address, DispatchQueue.main, block)
            inputBlocks[id] = nil
        }
    }

    @available(macOS 14.2, *)
    private func evaluate(_ ids: [AudioObjectID]) {
        let processes = ids.compactMap { Self.process($0) }
        let holders = Set(processes.filter(\.input).map { "\($0.pid):\($0.bundleID)" })
        let holdersChanged = holders != lastHolders
        lastHolders = holders; tick += 1
        // Titles come from the cache; a read runs off the main actor only when due and feeds the next evaluation.
        let found = MeetingApps.holding(processes, ownPID: ProcessInfo.processInfo.processIdentifier, never: Set(never.keys),
                                        latched: browserLatch) { owner in
            let due = MeetingApps.titleReadDue(holdersChanged: holdersChanged, cached: titleCache[owner] != nil, tick: tick)
            // QA 0.5.313: a new set of microphone holders never latches on the last read (a finished Meet call's
            // "true" named the next Teams web call or voice chat in that browser "Google Meet"). Read again; until the
            // answer arrives the browser is not a meeting. An already latched pid is unaffected.
            if holdersChanged { titleCache[owner] = nil }
            if due { readTitles(owner) }
            // readTitles answers at once without Accessibility or without the app (so "needs Accessibility" shows on
            // the first evaluation); a real read answers later and re-evaluates.
            if let cached = titleCache[owner] { return cached }
            return false
        }
        browserLatch = found.latched
        if browserNeedsAccessibility != found.browserUnchecked { browserNeedsAccessibility = found.browserUnchecked }
        let context = MeetingDetectionState.Context(
            suggestEnabled: suggestEnabled, allowed: allowed, recordingBusy: recordingBusy?() ?? true,
            dictating: dictating?() ?? false, cardShowing: card != nil)
        for event in state.step(holding: found.sources, now: Date(), context: context) { handle(event) }
        scheduleTick()
    }
    /// Thresholds pass without a property change, so a 2 s tick runs while it can matter, and never otherwise.
    private func scheduleTick() {
        let needed = state.wantsTicks || listenersUnavailable
        if !needed { tickTask?.cancel(); tickTask = nil; return }
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                self.tickTask = nil
                self.processesChanged()
                return
            }
        }
    }

    // MARK: The card

    private func handle(_ event: MeetingDetectionState.Event) {
        switch event {
        case .suggest(let source):
            recordingLog.notice("meeting detected app=\(source.app.title, privacy: .public)")
            show(MeetingCard(kind: .suggest, source: source))
        case .skipped(let source, let reason):
            recordingLog.notice("meeting not offered app=\(source.app.title, privacy: .public) reason=\(reason, privacy: .public)")
        case .ended(let source):
            if card?.kind != .ended, card?.source == source { dismiss() }
            if MeetingDetectedCard.offersEnd(ended: source, startedFrom: startedFrom?.source, startedCaptureID: startedFrom?.captureID,
                                           runningCaptureID: runningCaptureID?()) {
                recordingLog.notice("meeting ended app=\(source.app.title, privacy: .public); offering stop")
                show(MeetingCard(kind: .ended, source: source))
            }
        }
    }
    private func show(_ next: MeetingCard) {
        let placement = DictationPlacement.choose(petFrame: petFrame?(), focusedWindow: DictationFocusedWindow.frame(),
                                                  screens: NSScreen.screens.map(\.frame), mainScreen: NSScreen.main?.frame)
        if case .floating(let screen)? = placement { surface = .floating; floatingScreen = screen } else { surface = .pet; floatingScreen = nil }
        card = next
        dismissTask?.cancel(); dismissTask = nil
        // The suggestion (and its notice) fold away after 60 s; the end offer waits for an answer (COS never stops on its own).
        guard next.kind != .ended else { return }
        let id = next.id
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(MeetingDetectedCard.dismissSeconds))
            guard !Task.isCancelled, let self, self.card?.id == id else { return }
            self.card = nil
        }
    }
    func dismiss() { dismissTask?.cancel(); dismissTask = nil; card = nil }

    /// Record: one click. The first recording on this Mac shows the one-time notice in the card's place first.
    func recordSuggested() {
        guard let current = card, current.kind == .suggest else { return }
        guard MacRecordingNotice.step(acknowledged: noticeAcknowledged?() ?? false) == .start else {
            show(MeetingCard(kind: .notice, source: current.source)); return
        }
        startRecording(current)
    }
    /// The notice's Record: remembered on this Mac, then the recording starts.
    func recordAfterNotice() {
        guard let current = card, current.kind == .notice else { return }
        acknowledgeNotice?()
        startRecording(current)
    }
    private func startRecording(_ current: MeetingCard) {
        dismiss()
        Task {
            // A failure is shown by the record closure (pet notice, and Meetings opened on Record on Mac).
            guard let captureID = await record?(current.source) else {
                recordingLog.error("meeting card start failed app=\(current.source.app.title, privacy: .public)")
                return
            }
            startedFrom = (current.source, captureID)
            recordingLog.notice("recording started from a meeting suggestion app=\(current.source.app.title, privacy: .public)")
        }
    }
    func notNow() { dismiss() }
    func neverFor() {
        guard let current = card else { return }
        never[current.source.ownerBundleID] = current.source.ownerName
        UserDefaults.standard.set(never, forKey: Self.neverKey)
        dismiss()
    }
    /// "Meeting ended? Stop and save": only this button stops the recording.
    func stopAndSave() {
        guard card?.kind == .ended else { return }
        dismiss(); startedFrom = nil
        Task { await stopRecording?() }
    }
    func keepRecording() { dismiss() }
    /// The end offer has nothing to stop once the recording stopped some other way.
    func recordingStopped() {
        startedFrom = nil
        if card?.kind == .ended { dismiss() }
    }

    // MARK: CoreAudio and AX reads

    nonisolated private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    @available(macOS 14.2, *)
    nonisolated private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList); var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes) == noErr,
              bytes > 0, bytes <= 65_536 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(bytes) / MemoryLayout<AudioObjectID>.size))
    }
    @available(macOS 14.2, *)
    nonisolated private static func process(_ id: AudioObjectID) -> MeetingAudioProcess? {
        var pid: pid_t = 0, input: UInt32 = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        var pidAddress = address(kAudioProcessPropertyPID)
        guard AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &size, &pid) == noErr else { return nil }
        size = UInt32(MemoryLayout<UInt32>.size)
        var inputAddress = address(kAudioProcessPropertyIsRunningInput)
        guard AudioObjectGetPropertyData(id, &inputAddress, 0, nil, &size, &input) == noErr else { return nil }
        var bundleRef: Unmanaged<CFString>?
        var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var bundleAddress = address(kAudioProcessPropertyBundleID)
        guard AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, &bundleRef) == noErr else { return nil }
        let bundle = bundleRef?.takeRetainedValue() as String? ?? ""
        return MeetingAudioProcess(pid: pid, bundleID: bundle, input: input != 0)
    }
    /// The browser's window titles, read for that one app and only to look for Google Meet. nil without Accessibility.
    /// One browser's window titles, read off the main actor (a hung browser cannot stall COS): the app element and
    /// every window bounded at 0.25 s, at most 40 windows and about 1 s in all. Titles are matched, never kept or logged.
    private func readTitles(_ owner: String) {
        guard !titleReads.contains(owner) else { return }
        guard AXIsProcessTrusted() else { titleCache[owner] = .some(nil); return }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: owner).first?.processIdentifier else {
            titleCache[owner] = .some(false); return
        }
        titleReads.insert(owner)
        Task { @MainActor [weak self] in
            let shows = await Self.windowTitlesShowMeet(pid: pid)
            guard let self else { return }
            self.titleReads.remove(owner)
            let changed = self.titleCache[owner] != .some(shows)
            self.titleCache[owner] = .some(shows)
            if changed { self.processesChanged() }
        }
    }
    nonisolated private static func windowTitlesShowMeet(pid: pid_t) async -> Bool {
        let started = Date()
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.25)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return false }
        var titles: [String] = []
        for window in list.prefix(40) {
            guard Date().timeIntervalSince(started) < 1 else { break }
            AXUIElementSetMessagingTimeout(window, 0.25)
            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success, let text = title as? String { titles.append(text) }
        }
        return MeetingApps.showsMeet(titles)
    }
}

/// The meeting card (same family as the dictation card): on the pet, or above the Dock pill's spot on the focused
/// screen when the pet is hidden.
struct MeetingCardView: View {
    @ObservedObject var store: MeetingDetectorStore
    let card: MeetingCard
    let size: PetSize
    var body: some View {
        if card.kind == .notice {
            MacRecordingNoticeCard(size: size, onRecord: { store.recordAfterNotice() }, onNotNow: { store.notNow() })
                .frame(width: size.length(300), alignment: .leading)
        } else {
            suggestionOrEnd
        }
    }
    private var suggestionOrEnd: some View {
        VStack(alignment: .leading, spacing: size.length(7)) {
            HStack(spacing: size.length(7)) {
                Circle().fill(card.kind == .suggest ? COSPalette.danger : COSPalette.amber)
                    .frame(width: size.length(7), height: size.length(7))
                Text(card.kind == .suggest ? MeetingDetectedCard.headline(card.source) : MeetingDetectedCard.endHeadline)
                    .font(COSType.mono(size.typeSize(8), weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button { card.kind == .suggest ? store.notNow() : store.keepRecording() } label: {
                    Image(systemName: "xmark").font(.system(size: size.typeSize(8), weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: size.length(20), height: size.length(20)).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(card.kind == .suggest ? "Not now" : "Keep recording")
            }
            Text(card.kind == .suggest ? MeetingDetectedCard.line : MeetingDetectedCard.endLine(card.source))
                .font(COSType.body(size.typeSize(11)))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: size.length(7)) {
                switch card.kind {
                case .suggest:
                    Button("Record") { store.recordSuggested() }
                        .buttonStyle(DictationButtonStyle(primary: true, size: size))
                    Button("Not now") { store.notNow() }
                        .buttonStyle(DictationButtonStyle(size: size))
                    Spacer(minLength: 0)
                    Button(MeetingDetectedCard.never(card.source)) { store.neverFor() }
                        .buttonStyle(COSTextButtonStyle())
                        .font(COSType.body(size.typeSize(9)))
                case .notice:
                    EmptyView()
                case .ended:
                    Button("Stop and save") { store.stopAndSave() }
                        .buttonStyle(DictationButtonStyle(primary: true, size: size))
                    Button("Keep recording") { store.keepRecording() }
                        .buttonStyle(DictationButtonStyle(size: size))
                }
            }
        }
        .frame(width: size.length(300), alignment: .leading)
        .dictationSurface(size)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.kind == .suggest ? "Meeting detected" : "Meeting ended")
    }
}

final class MeetingCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class MeetingCardHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Pet hidden: the card floats above where the dictation pill sits, bottom center of the focused screen. Borderless
/// and nonactivating, so it never takes focus from the meeting.
@MainActor final class MeetingCardPresenter {
    private var panel: MeetingCardPanel?
    private var host: MeetingCardHostingView<AnyView>?
    private var observers: [AnyCancellable] = []
    private weak var store: MeetingDetectorStore?
    private let size = PetSize(preset: .medium, customPixels: PetSize.mediumPixels)

    func bind(store: MeetingDetectorStore) {
        guard self.store == nil else { return }
        self.store = store
        observers = [
            store.$card.map { $0?.id }.removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.sync() } },
            store.$surface.removeDuplicates().sink { [weak self] _ in Task { @MainActor in self?.sync() } },
        ]
    }
    private func sync() {
        guard let store, store.surface == .floating, let card = store.card else {
            if panel?.isVisible == true { panel?.orderOut(nil) }
            return
        }
        let view = AnyView(MeetingCardView(store: store, card: card, size: size).padding(14).fixedSize())
        if host == nil {
            let host = MeetingCardHostingView(rootView: view)
            let panel = MeetingCardPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 140),
                                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true; panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.contentView = host
            self.host = host; self.panel = panel
        } else {
            host?.rootView = view
        }
        guard let panel else { return }
        let fitted = host?.fittingSize ?? NSSize(width: 340, height: 140)
        let chosen = store.floatingScreen.flatMap { frame in NSScreen.screens.first { $0.frame == frame } } ?? NSScreen.main ?? NSScreen.screens.first
        if let screen = chosen?.visibleFrame {
            panel.setFrame(NSRect(x: (screen.midX - fitted.width / 2).rounded(), y: screen.minY + 64, width: fitted.width, height: fitted.height), display: true)
        }
        panel.orderFrontRegardless()
    }
}

/// Settings → Meetings: suggest recording when a meeting starts.
struct MeetingSuggestSettings: View {
    @ObservedObject var store: MeetingDetectorStore
    @AppStorage(MacRecordingNotice.acknowledgedKey) private var acknowledged = false
    /// Settings passes the model's recording store so the reset publishes to every view reading it.
    var recording: MacRecordingStore? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 0.5.313: the one-time recording notice can be shown again.
            Button("Show the recording notice again") {
                if let recording { recording.resetNotice() } else { acknowledged = false }
            }
                .controlSize(.small)
                .disabled(!acknowledged)
                .help("The next Mac recording shows what COS records and asks once more before it starts")
            Toggle("Suggest recording when a meeting starts", isOn: $store.suggestEnabled)
                .toggleStyle(COSSwitchStyle())
                .help("When Zoom, Microsoft Teams or Google Meet has used the microphone for 10 seconds, the pet offers Record on Mac with live transcript. COS never starts or stops a recording on its own")
            if store.suggestEnabled {
                ForEach(MeetingApp.allCases, id: \.self) { app in
                    Toggle(app.title, isOn: Binding(get: { store.allowed.contains(app) }, set: { store.setAllowed(app, $0) }))
                        .toggleStyle(COSSwitchStyle()).controlSize(.small)
                }
                if store.browserNeedsAccessibility {
                    Text("Google Meet in a browser needs Accessibility (the same permission dictation uses) to see the Meet tab's title. Until then COS watches Zoom and Teams only.")
                        .font(.caption2).foregroundStyle(COSPalette.amber)
                }
                ForEach(store.never.keys.sorted(), id: \.self) { owner in
                    HStack {
                        Text("Never for \(store.never[owner] ?? owner)").font(.caption)
                        Button("Remove") { store.removeNever(owner) }.controlSize(.mini)
                    }
                }
            }
        }
    }
}

/// 0.5.345 (A-W1): meeting-detection work on the main thread that took over `slowMilliseconds`, counted since launch.
/// Dictation reads the count at the microphone's close and at the first text (DictationTiming.slowListenerCalls).
@MainActor enum MeetingListenerStats {
    static let slowMilliseconds = 100
    private(set) static var slowCalls = 0
    static func note(ms: Int) { if ms > slowMilliseconds { slowCalls += 1 } }
}
