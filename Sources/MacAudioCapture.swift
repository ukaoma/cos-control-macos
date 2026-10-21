import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Owns only a private, unmuted process tap. This object is never instantiated at app launch.
/// Native resources and converter state are confined to one utility queue; IO only copies to ring.
@available(macOS 14.2, *)
final class MacAudioCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.gotcos.control.mac-recording", qos: .utility)
    private let ioQueue = DispatchQueue(label: "com.gotcos.control.mac-recording.io", qos: .userInitiated)
    private let ring = MacAudioRing()
    private var tap: AudioObjectID = kAudioObjectUnknown
    private var aggregate: AudioObjectID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private var timer: DispatchSourceTimer?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var frames = 0
    private var index = 0
    private var stopped = false
    private var interruption: String?
    private var lastInput = Date()
    private var started = Date()
    /// 0.5.334: the hearing check (MacRecordingHearing). Raw input since the last chunk, and in all, that was not 0.0.
    private var rawSignalSinceChunk = false
    private var rawSignalEver = false
    private var rawFrames = 0
    private var probed = false
    private let chunk: @Sendable (MacRecordingChunk) -> Bool
    private let failure: @Sendable (String) -> Void
    /// Called once, on the capture queue, after the tap's first `MacRecordingHearing.probeSeconds` of input: whether any
    /// of it was not exactly 0.0. Never blocks the capture.
    private let probe: (@Sendable (Bool) -> Void)?

    init(chunk: @escaping @Sendable (MacRecordingChunk) -> Bool, failure: @escaping @Sendable (String) -> Void,
         probe: (@Sendable (Bool) -> Void)? = nil) {
        self.chunk = chunk; self.failure = failure; self.probe = probe
    }
    /// 0.5.334: whether another app has audio output running now (the hearing check's "something is playing"). nil
    /// when the process list cannot be read. COS itself is excluded (sources() skips this process).
    static func othersPlaying() -> Bool? {
        guard let list = try? sources() else { return nil }
        return !list.isEmpty
    }
    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
    private static func value<T: BitwiseCopyable>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T) throws {
        var address = address(selector); var size = UInt32(MemoryLayout<T>.size)
        try checked(AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value), "Read audio metadata")
    }
    private static func checked(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw MacRecordingError.unavailable("\(operation) failed (\(status)). Check System Settings → Privacy & Security → Screen & System Audio Recording. No microphone is used.")
        }
    }
    static func sources() throws -> [MacAudioSource] {
        var address = address(kAudioHardwarePropertyProcessObjectList); var bytes: UInt32 = 0
        try checked(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes), "List audio apps")
        guard bytes <= 65_536 else { throw MacRecordingError.unavailable("Audio process list is too large.") }
        var ids = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
        try checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &bytes, &ids), "List audio apps")
        return ids.compactMap { id in
            var pid: pid_t = 0; var output: UInt32 = 0
            do {
                try value(id, kAudioProcessPropertyPID, into: &pid)
                try value(id, kAudioProcessPropertyIsRunningOutput, into: &output)
                var bundleRef: Unmanaged<CFString>?
                var bundleAddress = Self.address(kAudioProcessPropertyBundleID)
                var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                try checked(AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, &bundleRef), "Read audio app")
                let bundle = bundleRef?.takeRetainedValue() as String? ?? ""
                guard output != 0, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
                let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? bundle
                return .init(id: id, pid: pid, bundleID: bundle, name: name.isEmpty ? "Audio app (\(pid))" : name)
            } catch { return nil }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func start(source: MacAudioSource) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do { try configure(source); continuation.resume() }
                catch { tearDown(); continuation.resume(throwing: error) }
            }
        }
    }
    /// COS's own audio object, excluded from the global tap so its sounds never enter a meeting. Absent until COS has
    /// played audio, which is fine: nothing to exclude yet.
    private static func ownProcessObject() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? [object] : []
    }
    private func configure(_ source: MacAudioSource) throws {
        let description: CATapDescription
        if source.isAllMacAudio {
            description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcessObject())
        } else {
            guard try Self.sources().contains(source) else {
                throw MacRecordingError.unavailable("That audio app has changed or stopped. Refresh and select it again.")
            }
            description = CATapDescription(monoMixdownOfProcesses: [source.id])
        }
        description.name = "COS manual system audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.checked(AudioHardwareCreateProcessTap(description, &tap), "Start system audio capture")
        var asbd = AudioStreamBasicDescription()
        try Self.value(tap, kAudioTapPropertyFormat, into: &asbd)
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32, asbd.mChannelsPerFrame == 1,
              asbd.mSampleRate >= 16_000, asbd.mSampleRate <= Double(MacAudioRing.maximumSampleRate),
              let format = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: output) else {
            throw MacRecordingError.unavailable("This app’s audio format is not supported by the manual recording pilot.")
        }
        self.format = format; self.converter = converter
        let device: [String: Any] = [
            kAudioAggregateDeviceNameKey: "COS private recording",
            kAudioAggregateDeviceUIDKey: "com.gotcos.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
        ]
        try Self.checked(AudioHardwareCreateAggregateDevice(device as CFDictionary, &aggregate), "Create private audio capture")
        let ring = ring
        try Self.checked(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, ioQueue) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if buffers.isEmpty || (buffers.count == 1 && buffers[0].mDataByteSize == 0) { return }
            guard buffers.count == 1, let data = buffers[0].mData else { ring.rejectFormat(); return }
            ring.push(bytes: data, count: Int(buffers[0].mDataByteSize))
        }, "Attach audio capture")
        try Self.checked(AudioDeviceStart(aggregate, ioProc), "Begin audio capture")
        started = Date(); lastInput = started
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.drainOrFail() }
        self.timer = timer; timer.resume()
    }
    private func drainOrFail() {
        guard !stopped else { return }
        do {
            if let reason = ring.interruption { throw MacRecordingError.unavailable(reason) }
            try drain()
            guard Date().timeIntervalSince(lastInput) < 15 else {
                throw MacRecordingError.unavailable("Recording stopped: no audio buffers arrived for 15 seconds. Check the selected app and system audio permission.")
            }
            guard Date().timeIntervalSince(started) < 7_200 else {
                throw MacRecordingError.unavailable(MacRecordingInterruption.pilotLimit)
            }
        } catch {
            interruption = error.localizedDescription
            stopped = true; tearDown(); try? drain(); emitPartial(); failure(error.localizedDescription)
        }
    }
    private func drain() throws {
        guard let format, let converter else { return }
        while let raw = ring.pop() {
            guard raw.count % 4 == 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(raw.count / 4)) else {
                throw MacRecordingError.unavailable("The captured audio buffer is invalid.")
            }
            input.frameLength = input.frameCapacity
            guard let data = input.floatChannelData?[0] else { throw MacRecordingError.unavailable("Audio conversion could not read the input.") }
            raw.withUnsafeBytes { data.update(from: $0.bindMemory(to: Float.self).baseAddress!, count: raw.count / 4) }
            if !rawSignalSinceChunk, MacRecordingSignal.hasRawSignal(UnsafeBufferPointer(start: data, count: raw.count / 4)) {
                rawSignalSinceChunk = true; rawSignalEver = true
            }
            rawFrames += raw.count / 4
            if !probed, Double(rawFrames) >= format.sampleRate * MacRecordingHearing.probeSeconds {
                probed = true; probe?(rawSignalEver)
            }
            var supplied = false
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * 16_000 / format.sampleRate)) + 64) else {
                throw MacRecordingError.unavailable("Audio conversion could not allocate a bounded output buffer.")
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return input
            }
            guard status != .error, error == nil, let samples = output.int16ChannelData?[0] else {
                throw MacRecordingError.unavailable("Audio resampling failed; earlier chunks are retained.")
            }
            lastInput = Date()
            pending.append(Data(bytes: samples, count: Int(output.frameLength) * 2))
            let size = MacRecordingWAV.framesPerChunk * 2
            while pending.count >= size {
                let data = Data(pending.prefix(size)); pending.removeFirst(size)
                frames += size / 2
                let signal = rawSignalSinceChunk; rawSignalSinceChunk = false
                guard chunk(.init(index: index, pcm: data, endFrame: frames, rawSignal: signal)) else {
                    throw MacRecordingError.unavailable("Local audio storage fell behind. This recording is incomplete; earlier chunks are retained.")
                }
                index += 1
            }
        }
    }
    private func emitPartial() {
        guard !pending.isEmpty else { return }
        frames += pending.count / 2
        let signal = rawSignalSinceChunk; rawSignalSinceChunk = false
        if !chunk(.init(index: index, pcm: pending, endFrame: frames, rawSignal: signal)) {
            interruption = interruption ?? "Local audio storage fell behind. This recording is incomplete; earlier chunks are retained."
        }
        pending.removeAll()
    }
    private func tearDown() {
        timer?.cancel(); timer = nil
        if aggregate != kAudioObjectUnknown, let ioProc {
            AudioDeviceStop(aggregate, ioProc); AudioDeviceDestroyIOProcID(aggregate, ioProc)
        }
        ioProc = nil
        if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate); aggregate = kAudioObjectUnknown }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = kAudioObjectUnknown }
    }
    func stop() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if !stopped {
                    stopped = true; tearDown()
                    if let reason = ring.interruption { interruption = reason }
                    do { try drain() } catch { interruption = interruption ?? error.localizedDescription }
                    emitPartial()
                }
                continuation.resume(returning: interruption)
            }
        }
    }
}
