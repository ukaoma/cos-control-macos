import SwiftUI
import Combine
import CoreAudio
import ApplicationServices
import os

private let recordingLog = Logger(subsystem: "com.gotcos.control", category: "mac-recording")

@MainActor enum MacRecordingTermination {
    static var prepare: (@MainActor () async -> Void)?
    static var pending = false
}

@MainActor extension COSAppDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepare = MacRecordingTermination.prepare else { return .terminateNow }
        guard !MacRecordingTermination.pending else { return .terminateLater }
        MacRecordingTermination.pending = true
        Task { await prepare(); sender.reply(toApplicationShouldTerminate: true) }
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
        didSet { if ["starting", "recording", "stopping"].contains(oldValue) != ["starting", "recording", "stopping"].contains(phase) { activeChanged?(["starting", "recording", "stopping"].contains(phase)) } }
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
    /// Only while recording (Miles 2026-10-15: "No sound… for 24s" stayed on the live pane and this panel after the capture
    /// stopped and saved). Once stopped, a silent capture is reported by the save (noSpeech), not by this live check.
    var signalWarning: String? {
        guard isRecording else { return nil }
        return MacRecordingSignal.warning(silentChunks: silentChunks, source: manifest?.sourceName ?? "the selected source")
    }
    var isRecording: Bool { phase == "recording" }
    var occupied: Bool { !["idle", "saved", "pending"].contains(phase) }
    var canStart: Bool { !occupied && deliveryTask == nil && (manifest == nil || manifest!.saved || manifest!.chunks.isEmpty) }
    private var bridge: Bridge?
    private let spool: MacRecordingSpool
    private var capture: (any MacCaptureSession)?
    private var chunksTask: Task<Void, Never>?
    private var streamContinuation: AsyncStream<MacRecordingChunk>.Continuation?
    private var deliveryTask: Task<Void, Never>?
    private var deliveryWake = false
    private var instance: String?
    private var startAttempt: UUID?
    private var captureInterruption: String?
    private let stopGate = MacRecordingStopGate()
    private var observers: [NSObjectProtocol] = []
    var activeChanged: ((Bool) -> Void)?
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
        let response = try await bridge(operation, payload)
        guard response.ok else {
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
        let attempt = UUID(); startAttempt = attempt
        installStopObservers()
        var localCapture: MacAudioCapture?
        var localContinuation: AsyncStream<MacRecordingChunk>.Continuation?
        let id = "mac_" + UUID().uuidString.lowercased()
        let startTime = (Date().timeIntervalSince1970 * 1_000).rounded(.down)
        do {
            let response = try await invoke("start", ["captureId": .string(id), "serverInstanceId": .string(instance), "startTime": .number(startTime)])
            guard startAttempt == attempt, phase == "starting" else { throw CancellationError() }
            guard response["sessionId"]?.string == id, response["speakerPolicy"]?.string == "high-confidence",
                  response["sourceType"]?.string == "mac_system_audio", response["sampleRate"]?.int == 16_000,
                  response["channels"]?.int == 1, response["bitsPerSample"]?.int == 16 else {
                throw MacRecordingError.unavailable("The server did not confirm this recording’s source and strict speaker policy.")
            }
            let initial = MacRecordingManifest(captureId: id, startTime: startTime, serverInstanceId: instance,
                sourceName: source.name, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Mac recording" : String(title.prefix(160)),
                stopped: false, saved: false, acknowledged: 0, chunks: [])
            try await spool.write(initial)
            guard startAttempt == attempt, phase == "starting" else { _ = try await spool.markStopped(id); throw CancellationError() }
            manifest = initial
            let (stream, continuation) = AsyncStream<MacRecordingChunk>.makeStream(bufferingPolicy: .bufferingOldest(8))
            localContinuation = continuation
            streamContinuation = continuation
            chunksTask = Task { [weak self] in
                for await chunk in stream {
                    guard let self else { break }
                    let silent = MacRecordingSignal.isSilent(chunk.pcm)
                    do {
                        self.manifest = try await self.spool.append(chunk, captureId: id)
                        if silent { self.silentChunks += 1 } else { self.silentChunks = 0; self.heardSound = true }
                        if self.silentChunks == MacRecordingSignal.warnAfterSilentChunks {
                            let count = self.silentChunks, source = self.manifest?.sourceName ?? "?"
                            recordingLog.warning("silent capture: \(count) chunks below the peak floor from \(source, privacy: .public)")
                        }
                        self.deliverPending()
                    }
                    catch {
                        let reason = error.localizedDescription
                        recordingLog.error("append failed: \(reason, privacy: .public)")
                        self.captureInterruption = reason; Task { await self.stop() }; break
                    }
                }
            }
            let engine = MacAudioCapture(chunk: { value in
                if case .enqueued = continuation.yield(value) { return true }
                return false
            }, failure: { [weak self] reason in
                Task { @MainActor in
                    recordingLog.error("capture failed: \(reason, privacy: .public)")
                    self?.captureInterruption = reason; await self?.stop()
                }
            })
            localCapture = engine; capture = engine
            try await engine.start(source: source)
            guard startAttempt == attempt, phase == "starting" else { _ = await engine.stop(); throw CancellationError() }
            phase = "recording"
            recordingLog.notice("start ok source=\(source.isAllMacAudio ? "all Mac audio" : "one app", privacy: .public)")
            message = source.isAllMacAudio ? "Recording everything this Mac plays. Microphone off." : "Recording \(source.name) playback only. Microphone off."
        } catch {
            let interruption = await localCapture?.stop(); localContinuation?.finish()
            let reason = error is CancellationError ? "cancelled" : error.localizedDescription
            recordingLog.error("start failed: \(reason, privacy: .public)")
            guard startAttempt == attempt else { return }
            capture = nil
            streamContinuation?.finish(); await chunksTask?.value
            streamContinuation = nil; chunksTask = nil
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
        // QA 0.5.313: an interruption is written to the journal and shown once, by MacRecordingInterruption.line (muted for
        // the two-hour limit). Copying it into `error` too showed the same news again in red, and nothing cleared it.
        if let reason = await capture?.stop() { captureInterruption = reason }
        capture = nil
        streamContinuation?.finish(); streamContinuation = nil
        await chunksTask?.value; chunksTask = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers.removeAll()
        if let id = manifest?.captureId {
            do {
                if let reason = captureInterruption { _ = try await spool.interrupt(id, reason: reason) }
                manifest = try await spool.markStopped(id)
            }
            catch {
                let reason = error.localizedDescription
                recordingLog.error("markStopped failed: \(reason, privacy: .public)")
                self.error = reason
            }
        }
        phase = "pending"
        message = manifest?.chunks.isEmpty == true ? "Capture stopped before any audio was stored. There is nothing to save."
            : "Capture stopped. Audio stays on this Mac until its saved-meeting receipt is verified."
        if let reason = captureInterruption { stoppedOnItsOwn?(reason) }
        deliverPending()
    }
    /// 0.5.313: Record on the pet's meeting card. Always All Mac audio, the proven source, never a per-app tap.
    func startFromMeetingSuggestion(title meetingTitle: String, bridge: @escaping Bridge) async -> String? {
        await record(title: meetingTitle, sourceID: MacAudioSource.allMacAudioID, bridge: bridge)
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
                        let receipt = try await self.invoke("chunk", ["captureId": .string(id), "serverInstanceId": .string(current.serverInstanceId),
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
                        let saved = try await self.invoke("save", ["captureId": .string(id), "serverInstanceId": .string(current.serverInstanceId), "title": .string(current.title), "expectedChunkCount": .number(Double(current.chunks.count))])
                        guard saved["saved"]?.bool == true, saved["receiptVersion"]?.int == 1,
                              saved["serverInstanceId"]?.string == current.serverInstanceId,
                              saved["sessionId"]?.string == id, saved["captureId"]?.string == id,
                              saved["sourceType"]?.string == "mac_system_audio" else {
                            throw MacRecordingError.unavailable("A saved-meeting receipt was not verified. Audio is retained for recovery.")
                        }
                        self.manifest = try await self.spool.markSaved(id)
                        recordingLog.notice("save ok chunks=\(current.chunks.count)")
                        if self.error?.hasPrefix("Delivery paused:") == true { self.error = nil }
                        self.phase = "saved"; self.message = "Saved Mac recording. Open Meetings to review the transcript."
                        self.recoverable = try await self.spool.recoverable()
                    }
                    break
                }
            } catch { failed = true; self.deliveryPaused = true; let reason = error.localizedDescription; recordingLog.error("delivery paused: \(reason, privacy: .public)"); self.error = "Delivery paused: \(error.localizedDescription) Audio is retained. Retry does not restart recording." }
        }
    }
}

protocol MacCaptureSession: AnyObject, Sendable {
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
                Text(store.message).font(COSType.body(11)).foregroundStyle(.secondary)
                if let value = store.manifest {
                    Text("\(value.acknowledged)/\(value.chunks.count) audio chunks received · \(store.phase)").font(COSType.body(11)).foregroundStyle(.secondary)
                    if let warning = store.signalWarning {
                        Text(warning).font(COSType.body(11, weight: .semibold)).foregroundStyle(COSPalette.danger)
                    } else if store.isRecording {
                        Text(store.heardSound ? "Sound detected" : "Listening for sound…").font(COSType.body(11)).foregroundStyle(store.heardSound ? COSPalette.ink : COSPalette.muted)
                    }
                    if let interruption = value.interruption {
                        let line = MacRecordingInterruption.line(interruption)
                        Text(line.text).font(COSType.body(11)).foregroundStyle(line.problem ? COSPalette.danger : COSPalette.muted)
                    }
                    if store.phase == "pending", !value.chunks.isEmpty {
                        Text(store.noSpeech ? "No speech was found in this audio. It stays on this Mac." : "Save this retained recording before starting another.").font(COSType.body(11)).foregroundStyle(.secondary)
                        if store.canKeepForLater {
                            Button(store.noSpeech ? "Keep audio and record again" : "Keep audio for later") { Task { await store.keepSilentAudioForLater() } }
                        }
                        Button("Retry saving retained audio") { store.deliverPending() }
                    }
                }
            }
            if let error = store.error { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.danger) }
            ForEach(MacRecordingRecoveryPolicy.listed(store.recoverable, current: store.manifest?.captureId)) { value in
                Button("Recover \(value.title) · \(value.chunks.count) chunks") { Task { await store.recover(value) } }.disabled(!store.canStart)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12).background(COSPalette.amber.opacity(0.06))
        .overlay(alignment: .bottom) { Divider() }
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
