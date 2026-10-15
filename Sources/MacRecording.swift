import SwiftUI

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
    @Published var selectedID: UInt32 = 0
    @Published var title = "Mac recording"
    @Published private(set) var phase = "idle" {
        didSet { if ["starting", "recording", "stopping"].contains(oldValue) != ["starting", "recording", "stopping"].contains(phase) { activeChanged?(["starting", "recording", "stopping"].contains(phase)) } }
    }
    @Published private(set) var message = "Record audio played by a selected app. Your microphone is not recorded. Glasses are optional."
    @Published private(set) var error: String?
    @Published private(set) var manifest: MacRecordingManifest?
    @Published private(set) var recoverable: [MacRecordingManifest] = []
    @Published private(set) var available = false
    @Published private(set) var noSpeech = false
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
    init(spool: MacRecordingSpool = MacRecordingSpool()) { self.spool = spool }

    func prepare(bridge: @escaping Bridge) async {
        self.bridge = bridge
        guard !occupied else { return }
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
                sources = try await Task.detached(priority: .utility) { try MacAudioCapture.sources() }.value
                if !sources.contains(where: { $0.id == selectedID }) { selectedID = 0 }
            } else { throw MacRecordingError.unavailable("Manual system audio recording requires macOS 14.2 or later.") }
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
    /// Only the explicit Start button calls this; no initialization, detection, or permission probe records audio.
    func start() async {
        guard canStart, available, let instance, let source = sources.first(where: { $0.id == selectedID }) else { return }
        guard #available(macOS 14.2, *) else { return }
        phase = "starting"; error = nil; noSpeech = false; captureInterruption = nil
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
                    do { self.manifest = try await self.spool.append(chunk, captureId: id); self.deliverPending() }
                    catch { self.captureInterruption = error.localizedDescription; self.error = error.localizedDescription; Task { await self.stop() }; break }
                }
            }
            let engine = MacAudioCapture(chunk: { value in
                if case .enqueued = continuation.yield(value) { return true }
                return false
            }, failure: { [weak self] reason in
                Task { @MainActor in self?.captureInterruption = reason; self?.error = reason; await self?.stop() }
            })
            localCapture = engine; capture = engine
            try await engine.start(source: source)
            guard startAttempt == attempt, phase == "starting" else { _ = await engine.stop(); throw CancellationError() }
            phase = "recording"
            message = "Recording \(source.name) playback only. Microphone off · high-confidence voice identity."
        } catch {
            let interruption = await localCapture?.stop(); localContinuation?.finish()
            guard startAttempt == attempt else { return }
            capture = nil
            streamContinuation?.finish(); await chunksTask?.value
            streamContinuation = nil; chunksTask = nil
            for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers.removeAll()
            if manifest?.captureId == id {
                if let reason = interruption ?? captureInterruption { _ = try? await spool.interrupt(id, reason: reason) }
                manifest = try? await spool.markStopped(id)
            }
            phase = "pending"; self.error = error.localizedDescription
        }
    }
    private func installStopObservers() {
        guard observers.isEmpty else { return }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    let reason = "Recording stopped because this Mac slept or the user session changed."
                    self?.captureInterruption = reason; self?.error = reason; await self?.stop()
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
        if let reason = await capture?.stop() { captureInterruption = reason; error = reason }
        capture = nil
        streamContinuation?.finish(); streamContinuation = nil
        await chunksTask?.value; chunksTask = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }; observers.removeAll()
        if let id = manifest?.captureId {
            do {
                if let reason = captureInterruption { _ = try await spool.interrupt(id, reason: reason) }
                manifest = try await spool.markStopped(id)
            }
            catch { self.error = error.localizedDescription }
        }
        phase = "pending"; message = "Capture stopped. Audio stays on this Mac until its saved-meeting receipt is verified."
        deliverPending()
    }
    /// Quit defers only for native teardown and local flush, never network or ASR.
    func prepareToQuit() async { await stop() }
    func recover(_ value: MacRecordingManifest) async {
        guard canStart else { return }
        do {
            // A restart never resumes the tap. Pinning refuses replay into a different server instance.
            if !value.stopped { _ = try await spool.interrupt(value.captureId, reason: "The app ended during recording. Unflushed audio may be missing; retained chunks can be recovered.") }
            manifest = try await spool.markStopped(value.captureId); phase = "pending"; error = nil; noSpeech = false
            deliverPending()
        } catch { self.error = error.localizedDescription }
    }
    /// Leaves the immutable journal and WAVs untouched; only releases the current editor.
    /// Offered only after the server positively reported that no speech was saved.
    func keepSilentAudioForLater() async {
        guard MacRecordingRecoveryPolicy.canKeepForLater(noSpeech: noSpeech, pending: phase == "pending", stopped: manifest?.stopped == true, delivering: deliveryTask != nil) else { return }
        do {
            let retained = try await spool.recoverable()
            recoverable = retained; manifest = nil; selectedID = 0; noSpeech = false; error = nil; phase = "idle"
            message = "Previous audio is kept on this Mac. Select the app actually playing the meeting audio before recording again."
        } catch { self.error = error.localizedDescription }
    }
    func deliverPending() {
        if deliveryTask != nil { deliveryWake = true; return }
        guard let id = manifest?.captureId else { return }
        deliveryWake = false
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            var failed = false
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
                        self.phase = "saved"; self.message = "Saved Mac recording. Open Meetings to review the transcript."
                        self.recoverable = try await self.spool.recoverable()
                    }
                    break
                }
            } catch { failed = true; self.error = "Delivery paused: \(error.localizedDescription) Audio is retained. Retry does not restart recording." }
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
    @State private var expanded = false
    @State private var confirmStart = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(store.isRecording ? "Recording on this Mac" : "Record on Mac · pilot", systemImage: store.isRecording ? "record.circle.fill" : "waveform")
                    .font(COSType.body(12, weight: .semibold)).foregroundStyle(store.isRecording ? COSPalette.danger : COSPalette.ink)
                Spacer()
                if store.isRecording || store.phase == "starting" { Button("Stop and save") { Task { await store.stop() } }.buttonStyle(COSQuietButtonStyle()) }
                else { Button(expanded ? "Hide" : "Set up recording") { expanded.toggle() }.buttonStyle(COSQuietButtonStyle()) }
            }
            if expanded || store.occupied || store.manifest != nil {
                Text(store.message).font(COSType.body(11)).foregroundStyle(.secondary)
                if !store.occupied {
                    HStack {
                        TextField("Recording title", text: $store.title).textFieldStyle(.plain).cosField().frame(maxWidth: 260)
                        COSDropdown("Audio app", selection: $store.selectedID,
                            options: [COSDropdownOption(UInt32(0), "Select app playing audio")] + store.sources.map {
                                COSDropdownOption($0.id, "\($0.name) (\($0.pid))")
                            }).frame(maxWidth: 320)
                        Button("Refresh apps") { Task { await store.prepare(bridge: bridge) } }
                        Button("Start recording") { confirmStart = true }.disabled(!store.canStart || !store.available || store.selectedID == 0)
                    }
                }
                if let value = store.manifest {
                    Text("\(value.acknowledged)/\(value.chunks.count) audio chunks received · \(store.phase)").font(COSType.body(11)).foregroundStyle(.secondary)
                    if let interruption = value.interruption { Text("Incomplete recording: \(interruption)").font(COSType.body(11)).foregroundStyle(COSPalette.danger) }
                    if store.phase == "pending", !value.chunks.isEmpty {
                        Text(store.noSpeech ? "The selected app supplied no speech. Its audio remains available below." : "Save this retained recording before starting another.").font(COSType.body(11)).foregroundStyle(.secondary)
                        if store.noSpeech {
                            Button("Keep audio and choose another app") { Task { await store.keepSilentAudioForLater() } }
                        }
                        Button("Retry saving retained audio") { store.deliverPending() }
                    }
                }
                if let error = store.error { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.danger) }
                ForEach(store.recoverable.filter { $0.captureId != store.manifest?.captureId }) { value in
                    Button("Recover \(value.title) · \(value.chunks.count) chunks") { Task { await store.recover(value) } }.disabled(!store.canStart)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12).background(COSPalette.amber.opacity(0.06))
        .overlay(alignment: .bottom) { Divider() }
        .task { await store.prepare(bridge: bridge) }
        .confirmationDialog("Record selected app’s audio?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Start recording") { Task { await store.start() } }.keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Confirm participants know you are recording. This pilot captures selected-app playback only, including audio unrelated to the meeting in that app. Your microphone is off. Audio is retained locally; transcription follows your meeting settings. macOS may ask for system audio permission.")
        }
    }
}
