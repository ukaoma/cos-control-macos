import Foundation
/// Repeated Stop/quit requests await the same flush rather than exiting during teardown.
@MainActor final class MacRecordingStopGate {
    private var task: Task<Void, Never>?
    func run(_ operation: @escaping @MainActor () async -> Void) async {
        if let task { await task.value; return }
        let next = Task { await operation() }
        task = next
        await next.value
        task = nil
    }
}
import Darwin

/// Single producer (the serial audio IO queue), single consumer (the conversion queue).
/// Publish cursors only after copying. The callback never takes a consumer-held lock,
/// allocates, or waits. Four seconds at the largest supported sample rate fit in memory.
final class MacAudioRing: @unchecked Sendable {
    static let maximumSampleRate = 192_000
    static let bytesPerFrame = 4
    static let bufferedSeconds = 4
    static let requiredBytes = maximumSampleRate * bytesPerFrame * bufferedSeconds
    static let defaultCapacity = 1 << (Int.bitWidth - (requiredBytes - 1).leadingZeroBitCount)
    private let capacity: Int
    private let memory: UnsafeMutableRawPointer
    private let readCursor = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let writeCursor = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let failureCode = UnsafeMutablePointer<Int32>.allocate(capacity: 1)

    init(capacity: Int = MacAudioRing.defaultCapacity, initialCursor: UInt32 = 0) {
        precondition(capacity >= 4 && capacity.nonzeroBitCount == 1 && capacity <= Int(Int32.max))
        precondition(initialCursor % UInt32(Self.bytesPerFrame) == 0)
        self.capacity = capacity
        memory = .allocate(byteCount: capacity, alignment: 16)
        readCursor.initialize(to: Int32(bitPattern: initialCursor)); writeCursor.initialize(to: Int32(bitPattern: initialCursor)); failureCode.initialize(to: 0)
    }
    deinit {
        memory.deallocate()
        readCursor.deinitialize(count: 1); readCursor.deallocate()
        writeCursor.deinitialize(count: 1); writeCursor.deallocate()
        failureCode.deinitialize(count: 1); failureCode.deallocate()
    }
    private func load(_ pointer: UnsafeMutablePointer<Int32>) -> UInt32 {
        UInt32(bitPattern: OSAtomicAdd32Barrier(0, pointer))
    }
    func rejectFormat() { _ = OSAtomicCompareAndSwap32Barrier(0, 2, failureCode) }
    @discardableResult func push(bytes: UnsafeRawPointer, count: Int) -> Bool {
        guard count > 0 else { return true }
        guard count % Self.bytesPerFrame == 0, count <= capacity else { rejectFormat(); return false }
        let written = load(writeCursor), read = load(readCursor)
        let used = Int(written &- read)
        guard used <= capacity, count <= capacity - used else {
            _ = OSAtomicCompareAndSwap32Barrier(0, 1, failureCode); return false
        }
        let offset = Int(written) & (capacity - 1)
        let first = min(count, capacity - offset)
        memory.advanced(by: offset).copyMemory(from: bytes, byteCount: first)
        if first < count { memory.copyMemory(from: bytes.advanced(by: first), byteCount: count - first) }
        _ = OSAtomicAdd32Barrier(Int32(count), writeCursor)
        return true
    }
    func pop(maximumBytes: Int = 65_536) -> Data? {
        let read = load(readCursor), written = load(writeCursor)
        let available = Int(written &- read)
        guard available > 0 else { return nil }
        precondition(available <= capacity)
        let count = min(available, max(Self.bytesPerFrame, maximumBytes / Self.bytesPerFrame * Self.bytesPerFrame))
        let offset = Int(read) & (capacity - 1)
        let first = min(count, capacity - offset)
        var result = Data(bytes: memory.advanced(by: offset), count: first)
        if first < count { result.append(memory.assumingMemoryBound(to: UInt8.self), count: count - first) }
        _ = OSAtomicAdd32Barrier(Int32(count), readCursor)
        return result
    }
    var interruption: String? {
        switch load(failureCode) {
        case 0: return nil
        case 1: return "Recording stopped because the audio buffer filled. Earlier audio is retained; this recording is incomplete."
        default: return "Recording stopped because the audio app changed its buffer format. Earlier audio is retained."
        }
    }
}

enum MacRecordingError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let reason) = self { return reason }; return nil }
}

struct MacAudioSource: Identifiable, Equatable, Sendable {
    let id: UInt32
    let pid: Int32
    let bundleID: String
    let name: String
    /// 2026-10-15: the default source. Every app's playback except COS itself, one global tap. A per-app tap on a
    /// listener (Vorssaint, the Fireflies helper) returned 128s of exact zeros: those processes tap others and play nothing.
    static let allMacAudioID = UInt32.max
    static let allMacAudio = MacAudioSource(id: allMacAudioID, pid: 0, bundleID: "", name: "All Mac audio")
    var isAllMacAudio: Bool { id == Self.allMacAudioID }
}

/// How a capture's interruption reads (QA 2026-10-15): reaching the pilot's two-hour limit is a complete recording up to
/// that point, not an incomplete one.
enum MacRecordingInterruption {
    static let pilotLimit = "The two-hour recording pilot limit was reached."
    static func line(_ reason: String) -> (text: String, problem: Bool) {
        reason == pilotLimit ? ("Stopped at the two-hour limit. Everything recorded up to then is kept.", false)
            : ("Incomplete recording: " + reason, true)
    }
    /// QA 0.5.313: a recording that stops without the person stopping it says so outside the panel, which is usually
    /// closed during a call. The call may still be going.
    static func notification(_ reason: String) -> (title: String, body: String) {
        // 0.5.334: the no-sound stop is not an incomplete recording; it says what to do instead.
        if reason == MacRecordingHearing.cannotHearMessage { return ("Mac recording stopped", MacRecordingHearing.notificationBody) }
        return ("Mac recording stopped", line(reason).text + " If the meeting is still going, start a new recording.")
    }
}

/// Signal check per stored chunk, so "N/N chunks received" can no longer stand in for usable audio.
enum MacRecordingSignal {
    /// About -54 dBFS. A tap that reaches nothing delivers exact zeros; quiet room tone sits well above this.
    static let silentPeak = 64
    /// Two 6-second chunks: long enough to ride out a pause, short enough to catch a wrong source in the first minute.
    static let warnAfterSilentChunks = 2
    static func peak(_ pcm: Data) -> Int {
        pcm.withUnsafeBytes { raw in
            var peak = 0
            for sample in raw.bindMemory(to: Int16.self) { peak = max(peak, abs(Int(Int16(littleEndian: sample)))) }
            return peak
        }
    }
    static func isSilent(_ pcm: Data) -> Bool { peak(pcm) < silentPeak }
    /// 0.5.334: any captured float sample that is not exactly 0.0. A tap macOS has not authorized delivers exact zeros;
    /// a quiet room, however quiet, does not. Read BEFORE resampling: a sample below 1/32768 rounds to an Int16 zero.
    static func hasRawSignal(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        for sample in samples where sample != 0 { return true }
        return false
    }
    /// Every Int16 sample is exactly zero (what an unauthorized tap's chunk is after conversion).
    static func isDigitalZero(_ pcm: Data) -> Bool { peak(pcm) == 0 }
    /// 0.5.336: the audiogram's sum of squares over raw float samples (RMS is its mean, rooted). NaN and infinity count 0.
    static func sumOfSquares(_ samples: UnsafeBufferPointer<Float>) -> Double {
        var total = 0.0
        for sample in samples where sample.isFinite { total += Double(sample) * Double(sample) }
        return total
    }
    static func warning(silentChunks: Int, source: String) -> String? {
        guard silentChunks >= warnAfterSilentChunks else { return nil }
        let seconds = silentChunks * MacRecordingWAV.framesPerChunk / MacRecordingWAV.sampleRate
        // All Mac audio is already the whole output, so switching to it is no advice there: point at the call's own output.
        if source == MacAudioSource.allMacAudio.name {
            return "No sound reaching COS from All Mac audio for \(seconds)s. Check the call is playing through this Mac and is not muted."
        }
        return "No sound reaching COS from \(source) for \(seconds)s. If the call is playing, stop and record All Mac audio."
    }
}

/// 2026-10-15: a capture that stopped at the pilot limit, with 51 of 1,200 chunks delivered, still showed as "Live now"
/// on Meetings for as long as the server held its session. Control knows its own capture stopped, so it says so.
/// 0.5.310: when delivery has stopped on an error the row says it paused, not that it is saving (Finish saving stays).
/// 0.5.351 (quick save): an ordinary save says "Saving…" with no counter; the count appears once the save is slow
/// (MacRecordingSaveStatus.slowAfterSeconds) or has stopped on an error.
enum MacRecordingLiveRow {
    static func label(stopped: Bool, saved: Bool, acknowledged: Int, chunks: Int, paused: Bool = false, slow: Bool = false) -> String? {
        guard stopped, !saved else { return nil }
        if paused { return "Not saved yet · \(acknowledged) of \(chunks) audio chunks reached COS" }
        return slow ? "Saving · \(acknowledged) of \(chunks) audio chunks sent" : MacRecordingSaveStatus.saving
    }
}

struct MacRecordingChunk: Sendable {
    let index: Int
    let pcm: Data
    let endFrame: Int
    /// 0.5.334: some raw (pre-resampling) input since the previous chunk was not exactly 0.0. A chunk made only of
    /// exact zeros is what macOS delivers when it does not let COS record system audio. True when unknown.
    var rawSignal: Bool = true
    /// Digital silence for the hearing check: exact zeros in, exact zeros out.
    var digitalSilence: Bool { !rawSignal && MacRecordingSignal.isDigitalZero(pcm) }
}

/// One explicit remote-playback track. No microphone, glasses, device rerouting, or auto-detection.
enum MacRecordingWAV {
    static let sampleRate = 16_000
    static let framesPerChunk = sampleRate * 6
    static func encode(_ pcm: Data) throws -> Data {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= sampleRate * 2 * 30 else {
            throw MacRecordingError.unavailable("The captured audio chunk has an invalid size.")
        }
        var result = Data()
        func ascii(_ value: String) { result.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var n = value.littleEndian; withUnsafeBytes(of: &n) { result.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { result.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(pcm.count + 36)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        ascii("data"); u32(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}

struct MacRecordingManifest: Codable, Equatable, Sendable, Identifiable {
    var id: String { captureId }
    let captureId: String
    let startTime: Double
    let serverInstanceId: String
    let sourceName: String
    var title: String
    var stopped: Bool
    var saved: Bool
    var acknowledged: Int
    var interruption: String? = nil
    var chunks: [Chunk]
    /// 0.5.334: whether any stored chunk carried a nonzero sample. nil in a journal written before 0.5.334 (unknown).
    var heardSignal: Bool? = nil
    /// Stored audio known to be exact zeros from start to end: nothing to save, ever.
    var allDigitalSilence: Bool { heardSignal == false && !chunks.isEmpty }
    struct Chunk: Codable, Equatable, Sendable {
        let index: Int
        let filename: String
        let endFrame: Int
    }
}

/// Disk work is isolated from SwiftUI and the audio callback. Files survive lost acknowledgements;
/// restart can replay the same immutable sequence, but can never restart the audio device.
actor MacRecordingSpool {
    let root: URL
    private let fm = FileManager.default
    private var active: [String: MacRecordingManifest] = [:]
    private var warnings: [String] = []
    // Foundation standardization can fold /private/var into the /var symlink; retain
    // the supplied path and validate every component with descriptor-relative opens.
    static func defaultRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let home = environment["COS_CONTROL_TEST_HOME"], home.hasPrefix("/tmp/") {
            let resolved = URL(fileURLWithPath: home, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            if resolved.path.hasPrefix("/private/tmp/") || resolved.path.hasPrefix("/tmp/") {
                // Foundation may present the resolved temporary home through /tmp again.
                // The spool's descriptor traversal requires the physical ancestor.
                let physical = resolved.path.hasPrefix("/tmp/") ? "/private" + resolved.path : resolved.path
                return URL(fileURLWithPath: physical + "/cos-data/mac-recordings", isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("cos-data/mac-recordings")
    }
    init(root: URL = MacRecordingSpool.defaultRoot()) { self.root = root }
    private func invalid() -> MacRecordingError { .unavailable("The recording journal or private storage is invalid. Existing audio is retained.") }
    private func validID(_ id: String) -> Bool {
        guard id.hasPrefix("mac_"), let uuid = UUID(uuidString: String(id.dropFirst(4))) else { return false }
        return id == "mac_" + uuid.uuidString.lowercased()
    }
    private func directory(_ id: String) throws -> URL {
        guard validID(id) else { throw invalid() }
        return root.appendingPathComponent(id, isDirectory: true)
    }
    /// Traverse from a stable directory descriptor. No ancestor symlink may redirect audio writes.
    private func rootFD(create: Bool) throws -> Int32 { try directoryFD(root, create: create) }
    private func directoryFD(_ root: URL, create: Bool) throws -> Int32 {
        guard root.isFileURL, root.path.hasPrefix("/"), root.pathComponents.count > 2,
              !root.pathComponents.contains("."), !root.pathComponents.contains("..") else { throw invalid() }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw invalid() }
        do {
            for component in root.pathComponents.dropFirst() {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                if next < 0, errno == ENOENT, create {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw invalid() }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                }
                guard next >= 0 else { throw invalid() }
                Darwin.close(fd); fd = next
            }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else { throw invalid() }
            return fd
        } catch { Darwin.close(fd); throw error }
    }
    private func captureFD(_ id: String, create: Bool) throws -> Int32 {
        guard validID(id) else { throw invalid() }
        let parent = try rootFD(create: create); defer { Darwin.close(parent) }
        var fd = openat(parent, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if fd < 0, errno == ENOENT, create {
            guard mkdirat(parent, id, 0o700) == 0 || errno == EEXIST else { throw invalid() }
            fd = openat(parent, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        guard fd >= 0 else { throw invalid() }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else { Darwin.close(fd); throw invalid() }
        return fd
    }
    private func read(_ name: String, in directory: Int32, limit: Int) throws -> Data {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw invalid() }; defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(),
              before.st_mode & 0o077 == 0, before.st_nlink == 1, before.st_size > 0, before.st_size <= limit else { throw invalid() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while result.count < Int(before.st_size) {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, Int(before.st_size) - result.count)) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw invalid() }; result.append(contentsOf: buffer[0..<count])
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size, before.st_ino == after.st_ino,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw invalid() }
        return result
    }
    private func atomicWrite(_ data: Data, name: String, in directory: Int32, immutable: Bool = false) throws {
        var existing = stat()
        if fstatat(directory, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            let old = try read(name, in: directory, limit: max(512_000, 960_044))
            if immutable { guard old == data else { throw invalid() }; return }
        } else if errno != ENOENT { throw invalid() }
        let temporary = ".recording-" + UUID().uuidString.lowercased() + ".tmp"
        let fd = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw invalid() }
        defer { Darwin.close(fd); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let address = bytes.baseAddress else { throw invalid() }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, address.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw invalid() }; offset += count
            }
        }
        guard fsync(fd) == 0, renameat(directory, temporary, directory, name) == 0, fsync(directory) == 0 else { throw invalid() }
    }
    private func validate(_ value: MacRecordingManifest) throws {
        guard validID(value.captureId), value.startTime.isFinite, value.startTime > 0,
              !value.serverInstanceId.isEmpty, value.serverInstanceId.utf8.count <= 128,
              value.serverInstanceId.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }),
              value.sourceName.utf8.count <= 2_048, value.title.count <= 160,
              !value.title.unicodeScalars.contains(where: { $0.value < 32 }),
              value.acknowledged >= 0, value.acknowledged <= value.chunks.count, value.chunks.count <= 1_201,
              !value.saved || (value.stopped && value.acknowledged == value.chunks.count) else { throw invalid() }
        if let interruption = value.interruption {
            guard interruption.count <= 256, !interruption.unicodeScalars.contains(where: { $0.value < 32 }) else { throw invalid() }
        }
        var endFrame = 0
        for (index, chunk) in value.chunks.enumerated() {
            guard chunk.index == index, chunk.filename == String(format: "%06d.wav", index), chunk.endFrame > endFrame,
                  chunk.endFrame - endFrame <= 16_000 * 30, chunk.endFrame <= 16_000 * 60 * 120 else { throw invalid() }
            endFrame = chunk.endFrame
        }
    }
    func write(_ value: MacRecordingManifest) throws {
        try validate(value)
        let fd = try captureFD(value.captureId, create: true); defer { Darwin.close(fd) }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 512_000 else { throw invalid() }
        try atomicWrite(data, name: "manifest.json", in: fd)
        active[value.captureId] = value
    }
    func snapshot(_ id: String) throws -> MacRecordingManifest {
        if let value = active[id] { return value }
        let fd = try captureFD(id, create: false); defer { Darwin.close(fd) }
        let value = try JSONDecoder().decode(MacRecordingManifest.self, from: read("manifest.json", in: fd, limit: 512_000))
        guard value.captureId == id else { throw invalid() }
        try validate(value); active[id] = value; return value
    }
    func acknowledge(_ id: String, index: Int) throws -> MacRecordingManifest {
        var value = try snapshot(id)
        guard !value.saved, value.acknowledged == index, index < value.chunks.count else { throw invalid() }
        value.acknowledged += 1; try write(value); return value
    }
    func interrupt(_ id: String, reason: String) throws -> MacRecordingManifest {
        var value = try snapshot(id)
        guard !value.saved else { throw invalid() }
        if value.interruption == nil {
            let safe = String(String.UnicodeScalarView(reason.unicodeScalars.filter { $0.value >= 32 })).prefix(256)
            value.interruption = safe.isEmpty ? "Recording was interrupted. Existing audio is retained." : String(safe)
            try write(value)
        }
        return value
    }
    func markStopped(_ id: String) throws -> MacRecordingManifest {
        var value = try snapshot(id); value.stopped = true; try write(value); return value
    }
    /// 0.5.351 (MacRecordingReconcile): the server holds this capture saved and every chunk reached it. Marks the journal
    /// stopped and saved so it is no longer offered for Recover. Never touches audio; refuses if any chunk is unacknowledged.
    func markSavedOnServer(_ id: String) throws -> MacRecordingManifest {
        var value = try snapshot(id)
        guard !value.chunks.isEmpty, value.acknowledged == value.chunks.count else { throw MacRecordingError.unavailable("Recording still has pending audio.") }
        value.stopped = true; value.saved = true; try write(value); return value
    }
    func markSaved(_ id: String) throws -> MacRecordingManifest {
        var value = try snapshot(id)
        guard value.stopped, value.acknowledged == value.chunks.count else { throw MacRecordingError.unavailable("Recording still has pending audio.") }
        value.saved = true; try write(value); return value
    }
    func append(_ chunk: MacRecordingChunk, captureId: String) throws -> MacRecordingManifest {
        let value = try snapshot(captureId)
        guard !value.stopped, !value.saved, value.chunks.count < 1_201, chunk.index == value.chunks.count,
              chunk.pcm.count % 2 == 0, chunk.endFrame == (value.chunks.last?.endFrame ?? 0) + chunk.pcm.count / 2,
              chunk.endFrame <= 16_000 * 60 * 120 else {
            throw MacRecordingError.unavailable("Recording stopped: the audio sequence or two-hour pilot limit was reached.")
        }
        let free = try fm.attributesOfFileSystem(forPath: directory(value.captureId).path)[.systemFreeSize] as? NSNumber
        guard let free, free.int64Value > 512 * 1_024 * 1_024 else {
            throw MacRecordingError.unavailable("Recording stopped: at least 512 MB of free disk space is required. Saved chunks are retained.")
        }
        let fd = try captureFD(value.captureId, create: false); defer { Darwin.close(fd) }
        let filename = String(format: "%06d.wav", chunk.index)
        try atomicWrite(MacRecordingWAV.encode(chunk.pcm), name: filename, in: fd, immutable: true)
        var next = value
        next.chunks.append(.init(index: chunk.index, filename: filename, endFrame: chunk.endFrame))
        next.heardSignal = (value.chunks.isEmpty ? false : (value.heardSignal ?? true)) || !chunk.digitalSilence
        try write(next); return next
    }
    func path(for chunk: MacRecordingManifest.Chunk, captureId: String) throws -> String {
        guard chunk.index >= 0, chunk.filename == String(format: "%06d.wav", chunk.index) else { throw invalid() }
        return try directory(captureId).appendingPathComponent(chunk.filename).path
    }
    func recoveryWarnings() -> [String] { warnings }
    /// 0.5.336: the grey line's preview WAV, beside the chunks and never in the journal: written before each preview
    /// post (replaced, not appended), removed after it and at stop, and never counted as audio outside the journal.
    static let previewFilename = "preview.wav"
    func writePreview(_ pcm: Data, captureId: String) throws -> String {
        let value = try snapshot(captureId)
        guard !value.stopped, !value.saved, !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= LiveMeetingPreviewLimit.maximumBytes else { throw invalid() }
        let fd = try captureFD(captureId, create: false); defer { Darwin.close(fd) }
        try atomicWrite(MacRecordingWAV.encode(pcm), name: Self.previewFilename, in: fd)
        return try directory(captureId).appendingPathComponent(Self.previewFilename).path
    }
    func removePreview(captureId: String) {
        guard let fd = try? captureFD(captureId, create: false) else { return }
        defer { Darwin.close(fd) }
        _ = unlinkat(fd, Self.previewFilename, 0)
    }
    /// 0.5.334: where a discarded capture goes, beside the spool: `mac-recordings-discarded/<yyyy-MM-dd>/`.
    var discardedRoot: URL { root.deletingLastPathComponent().appendingPathComponent(MacRecordingDiscard.discardedFolderName, isDirectory: true) }
    /// Moves one capture's folder, journal and WAVs untouched, into today's discarded folder. Never removes a file: a
    /// wrong discard is undone by moving the folder back. Same volume, one rename, so it is all or nothing.
    func discard(_ id: String, at date: Date = Date(), calendar: Calendar = .current) throws -> URL {
        guard validID(id) else { throw invalid() }
        let parent = try rootFD(create: false); defer { Darwin.close(parent) }
        var metadata = stat()
        guard fstatat(parent, id, &metadata, AT_SYMLINK_NOFOLLOW) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid() else { throw invalid() }
        let day = discardedRoot.appendingPathComponent(MacRecordingDiscard.dayFolder(date, calendar: calendar), isDirectory: true)
        let target = try directoryFD(day, create: true); defer { Darwin.close(target) }
        var name = id
        if fstatat(target, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { name = id + "." + String(Int(date.timeIntervalSince1970)) }
        guard renameat(parent, id, target, name) == 0 else {
            throw MacRecordingError.unavailable("COS couldn't move this recording to the discarded folder. Its audio is unchanged.")
        }
        _ = fsync(target); _ = fsync(parent)
        active[id] = nil
        return day.appendingPathComponent(name, isDirectory: true)
    }
    func recoverable() throws -> [MacRecordingManifest] {
        warnings = []
        guard fm.fileExists(atPath: root.path) else { return [] }
        let parent = try rootFD(create: false); defer { Darwin.close(parent) }
        // Directory names are inventory only; all content reads stay descriptor relative and bounded.
        let names = try fm.contentsOfDirectory(atPath: root.path).sorted()
        var result: [MacRecordingManifest] = []
        for name in names where name.hasPrefix("mac_") {
            do {
                guard validID(name) else { throw invalid() }
                let value = try snapshot(name)
                let expected = Set(value.chunks.map(\.filename))
                let files = try fm.contentsOfDirectory(atPath: directory(name).path)
                if files.contains(where: { $0.lowercased().hasSuffix(".wav") && !expected.contains($0) && $0 != Self.previewFilename }) {
                    warnings.append("A Mac recording has audio outside its saved journal. Those files were retained and will not be uploaded automatically.")
                }
                if !value.saved { result.append(value) }
            } catch {
                warnings.append("A Mac recording could not be recovered safely. Its files were retained; other recordings remain available.")
            }
        }
        return result.sorted { $0.startTime < $1.startTime }
    }
}

/// 0.5.336: the preview's byte ceiling, here so the spool (compiled alone in its lane) and the gate agree: 15 s of 16 kHz
/// mono PCM16 (LiveMeetingPreviewGate.maximumBytes says the same; Tests/live-meeting-pins.py pins the two equal).
enum LiveMeetingPreviewLimit {
    static let maximumBytes = 480_000
}

/// A confirmed no-speech result may release the composer, never an uncertain or live delivery.
enum MacRecordingRecoveryPolicy {
    /// QA 0.5.313: also when delivery paused on an error, so a capture that cannot reach the server never holds
    /// Record hostage; the audio stays in the spool and is listed with Recover.
    /// 0.5.334 (Miles 2026-10-21): not for no speech. Audio the server found no speech in, or exact zeros, saves no
    /// better later; Discard (MacRecordingDiscard) releases the composer for those instead.
    static func canKeepForLater(noSpeech: Bool, paused: Bool = false, pending: Bool, stopped: Bool, delivering: Bool) -> Bool {
        paused && !noSpeech && pending && stopped && !delivering
    }
    /// What the panel offers to Recover: retained captures with audio, other than the current one. A journal with no
    /// chunks (a start that failed after its manifest was written) has nothing to recover; it is hidden, never deleted.
    static func listed(_ retained: [MacRecordingManifest], current: String?) -> [MacRecordingManifest] {
        retained.filter { !$0.chunks.isEmpty && $0.captureId != current }
    }
    /// 0.5.351 (Miles 2026-10-26: Recover was grayed out during a live recording with no reason). Why Recover is not
    /// available right now, in the panel's words, or nil when it is.
    static func recoverUnavailable(phase: String, delivering: Bool, currentUnsaved: Bool) -> String? {
        switch phase {
        case "starting", "recording", "stopping": return "Recover is available after this recording."
        case "recovering": return "Recover is available after the recovery in progress."
        case "discarding": return "Recover is available after the discard finishes."
        default: break
        }
        if delivering { return "Recover is available once this recording is saved." }
        if currentUnsaved { return "Recover is available once the recording above is saved or kept for later." }
        return nil
    }
}

/// 0.5.351 (2026-10-26, mac_b0bd6732): the server saved a Mac capture whose app was ended (SIGTERM during an update), and
/// Control kept offering "Recover … · 367 chunks" because only its own save receipt ever marks a journal saved. Before
/// listing a retained capture, Control asks the server (the helper's status op). Hidden only on a verified saved receipt
/// for this exact capture AND only when every local chunk reached the server; anything else, unreachable included, keeps
/// the row.
enum MacRecordingReconcile {
    /// Worth asking the server: a retained capture with audio, every chunk acknowledged. A capture with chunks the
    /// server never received stays listed whatever the server says, because only this Mac holds that audio.
    static func shouldAsk(_ value: MacRecordingManifest, current: String?) -> Bool {
        !value.saved && !value.chunks.isEmpty && value.acknowledged == value.chunks.count && value.captureId != current
    }
    /// The status op's answer, as the store reads it.
    struct Answer: Equatable, Sendable {
        var ok: Bool
        var state: String?
        var sessionId: String?
        var receiptSaved: Bool?
        var receiptVersion: Int?
        var receiptSessionId: String?
        var receiptCaptureId: String?
        var receiptSourceType: String?
    }
    /// Saved on the server, by a receipt for this exact Mac capture. Everything else (a refusal, unreachable, active,
    /// missing, a receipt for another session or source) is not.
    static func savedOnServer(captureId: String, _ answer: Answer) -> Bool {
        answer.ok && answer.state == "saved" && answer.sessionId == captureId && answer.receiptSaved == true && answer.receiptVersion == 1
            && answer.receiptSessionId == captureId && answer.receiptCaptureId == captureId && answer.receiptSourceType == "mac_system_audio"
    }
}

/// Why Record did nothing, by cause (QA 0.5.313). `keep` leaves the line alone: a second click while the first start
/// is still starting must not put a red line under the live recording.
enum MacRecordingRefusal: Equatable, Sendable {
    case keep
    case set(String)
    static let pending = "A Mac recording is waiting to be saved. Open Meetings to finish it before recording another."
    static func decide(available: Bool, currentError: String?, live: Bool, pendingCapture: Bool) -> MacRecordingRefusal {
        if live { return .keep }
        if !available {
            // prepare() just ran and said why; keep that reason rather than replacing it.
            if let currentError, !currentError.isEmpty { return .set(currentError) }
            return .set("Mac recording isn't available: COS Control couldn't reach its recording helper. Try again in a moment.")
        }
        if pendingCapture { return .set(pending) }
        return .set("Mac recording couldn't start. Try again in a moment.")
    }
}

// MARK: - Can COS hear this Mac? (0.5.334, Miles 2026-10-21 13:15)
//
// "Clean up the Record on Mac pilot ... I want this functionality working moving forward." That morning All Mac audio
// recorded a 21-minute Zoom call as 211 chunks of EXACT zeros: macOS hands a process tap zeros, not an error, when it
// is not letting the app record system audio. COS logged "silent capture" 12 s in and recorded on for 21 minutes.
//
// What macOS offers to ask first (researched for this change): no public API reports System Audio Recording
// authorization. AudioHardwareCreateProcessTap and the aggregate device succeed either way and the IOProc runs; the
// samples are zero. AVAudioApplication's record permission is the microphone (kTCCServiceMicrophone), and
// CGPreflightScreenCaptureAccess is Screen Recording, not "System Audio Recording Only" (kTCCServiceAudioCapture).
// The only reader is the private TCCAccessPreflight that Apple's AudioCap sample uses (SystemAudioPermission), and on
// 2026-10-21 it let the recording start without asking (no "system audio before recording" line), so it can say no
// but cannot prove yes. The proof is the audio: exact zeros, not quiet.

enum MacRecordingHearing {
    static let cannotHearMessage = "COS Control can't hear your Mac's audio. macOS may not be letting it record system audio."
    static let notificationBody = cannotHearMessage + " Open Meetings in COS Control to allow it in System Settings, then try again."
    static let openSettingsTitle = "Open System Settings"
    static let tryAgainTitle = "Try again"
    /// The ~1 s probe's line while a capture has delivered only exact zeros with another app playing (a warning only;
    /// the fail-fast below decides).
    static let suspectLine = "No sound reaching COS yet. Checking that macOS lets it record system audio…"
    /// Two 6 s chunks: 12 s.
    static let failFastChunks = 2
    /// The probe reads the tap's first second of input.
    static let probeSeconds: Double = 1

    struct State: Equatable, Sendable {
        /// Any nonzero sample in this capture. Once true, never a fail-fast: a real meeting can go digitally silent.
        var heardSignal = false
        /// Exact-zero chunks stored while another app had audio output running.
        var zeroChunksWhilePlaying = 0
        /// The probe saw only zeros in the first second while another app was (or may have been) playing.
        var suspect = false
    }
    enum Verdict: Equatable, Sendable { case keep, cannotHear }

    /// One chunk stored. `othersPlaying`: another app had audio output running then (nil when it could not be read).
    /// Fires only for All Mac audio, only before any nonzero sample, only on exact zeros while something plays: a quiet
    /// meeting with any nonzero signal, a per-app source, and a Mac with nothing playing all keep recording.
    static func step(_ state: inout State, digitalSilence: Bool, othersPlaying: Bool?, allMacAudio: Bool) -> Verdict {
        guard digitalSilence else { state.heardSignal = true; state.suspect = false; state.zeroChunksWhilePlaying = 0; return .keep }
        guard allMacAudio, !state.heardSignal, othersPlaying != false else { return .keep }
        state.zeroChunksWhilePlaying += 1
        return state.zeroChunksWhilePlaying >= failFastChunks ? .cannotHear : .keep
    }
    /// The non-blocking probe: the first second through the same tap. Sets the warning; never stops anything.
    static func probe(_ state: inout State, sawSignal: Bool, othersPlaying: Bool?, allMacAudio: Bool) {
        if sawSignal { state.heardSignal = true; state.suspect = false; return }
        state.suspect = allMacAudio && !state.heardSignal && othersPlaying != false
    }
    static func line(_ state: State, recording: Bool) -> String? { recording && state.suspect && !state.heardSignal ? suspectLine : nil }
}

/// 0.5.334: Discard replaces the buttons that could not work for a capture with no sound ("Retry saving retained audio",
/// a stranded Save). Local audio moves to a dated folder (never removed); the server is asked to let its side go.
enum MacRecordingDiscard {
    static let buttonTitle = "Discard (no sound was captured)"
    static let confirmTitle = "Discard this recording?"
    static let confirmLine = "No sound was captured, so there is nothing to save. Its audio files move to a dated discarded folder on this Mac; nothing is deleted."
    static let confirmButton = "Discard"
    static let discardedFolderName = "mac-recordings-discarded"
    static func dayFolder(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    /// Offered for a stopped, pending capture the server called no speech or that is exact zeros here, while nothing
    /// is being delivered.
    static func offered(noSpeech: Bool, allZero: Bool, pending: Bool, stopped: Bool, delivering: Bool) -> Bool {
        (noSpeech || allZero) && pending && stopped && !delivering
    }
    /// "Retry saving retained audio" only where a retry can work: never for no speech or exact zeros, and never while a
    /// save is already running (0.5.351: the button showed through every ordinary save and read as "retrying chunks").
    static func retryOffered(noSpeech: Bool, allZero: Bool, pending: Bool, hasChunks: Bool, delivering: Bool) -> Bool {
        pending && hasChunks && !noSpeech && !allZero && !delivering
    }
    /// A stranded row on Meetings: Discard instead of Save for a Mac capture the server says has no speech.
    static func strandedOffersDiscard(sessionId: String, transcriptState: String, canSave: Bool) -> Bool {
        sessionId.hasPrefix("mac_") && !canSave && transcriptState == "no_speech"
    }

    enum Server: Equatable, Sendable {
        case discarded, replayed
        /// The server holds it but it is still too fresh (no audio for 2 min yet): ask again later.
        case notIdle
        /// The server refused (speech, still transcribing, saved): its reason.
        case refused(String)
        /// Already gone from the server (never had it, or it was cleared): nothing to do there.
        case absent
        /// An older server without the route: only the local copy was discarded.
        case unsupported
        case unreachable
    }
    /// The helper's answer for operation "discard".
    static func serverAnswer(ok: Bool, httpStatus: Int?, reason: String?, discarded: Bool?, replayed: Bool?) -> Server {
        if ok, discarded == true { return replayed == true ? .replayed : .discarded }
        switch reason {
        case "not_idle"?, "asr_in_progress"?, "chunk_in_progress"?: return .notIdle
        case "session_not_found"?: return .absent
        case "route_absent"?: return .unsupported
        case "server_unavailable"?: return .unreachable
        case let reason?: return .refused(reason)
        case nil: return httpStatus == 404 ? .unsupported : .unreachable
        }
    }
    /// The one honest line after a discard.
    static func note(localMoved: Bool, server: Server) -> String {
        let local = localMoved ? "Discarded. No sound was captured, so there was nothing to save. The audio is in a dated discarded folder on this Mac."
            : "Discarded. No sound was captured, so there was nothing to save."
        switch server {
        case .discarded, .replayed, .absent: return local
        case .notIdle: return local + " The server lets its copy go in a couple of minutes."
        case .unsupported: return local + " This COS server is older and keeps its copy until its own clean-up; update the server to clear it now."
        case .unreachable: return local + " The server could not be reached; its copy clears on its own."
        case .refused(let reason): return local + " The server kept its copy (\(reason))."
        }
    }
    /// How many more times a not-yet-idle server is asked, and how long Control waits before each: past the server's
    /// 2-minute idle window.
    static let retryAfterSeconds: Double = 130
    static let retries = 2
}

/// The discard itself, with its two sides as seams so the checks run it against a fake helper (MacRecordingChecks).
/// The local spool moves first: it is on this Mac and cannot fail for a network reason.
/// 0.5.351 (Miles 2026-10-26: "There's many times when you click save and it shows as like retrying chunks. We should
/// just show like a quick save."). On this Mac a stopped capture is saved about 5 s after Stop (median of 14 saves,
/// Oct 19-26, 3.4 to 8.0 s for 13 of them): the server keeps up live, so only the last chunk is left. The panel showed
/// that wait as a chunk counter, "Save this retained recording" and a Retry button. This rule is what the Record on Mac
/// panel shows instead: "Saving…", then "Saved", and the count and the buttons only when the save is slow or failed.
enum MacRecordingSaveStatus {
    enum Tone: Equatable, Sendable { case quiet, done, problem }
    struct Line: Equatable, Sendable {
        let headline: String
        let detail: String?
        let progress: String?
        let tone: Tone
        /// The retained-recording block (its line and Keep, Discard or Retry where their own rules allow).
        let showsActions: Bool
    }
    static let saving = "Saving…"
    static let saved = "Saved"
    static let savedDetail = "Open Meetings to review the transcript."
    static let notSaved = "Not saved yet. Audio is safe on this Mac."
    static let notAnswering = "COS is not answering yet. Audio is safe on this Mac, and COS keeps trying for a minute."
    static let notAnsweringWhileRecording = "COS is not answering. Audio is safe on this Mac and sends when COS is back."
    /// A save still running this long after Stop says how far it got (the slowest ordinary save measured 8.0 s).
    static let slowAfterSeconds: Double = 20
    /// While recording, the count appears only when COS is this many chunks (6 s each) behind.
    static let behindChunks = 3
    static func stillSaving(_ acknowledged: Int, of chunks: Int) -> String { "Still saving. \(acknowledged) of \(chunks) audio chunks have reached COS." }
    static func reached(_ acknowledged: Int, of chunks: Int) -> String { "\(acknowledged) of \(chunks) audio chunks reached COS." }
    static func sending(_ acknowledged: Int, of chunks: Int) -> String { "Sending audio to COS: \(acknowledged) of \(chunks) chunks received." }

    /// `delivering`: a delivery task is running, including a quiet wait to try again. `waiting`: that wait follows a
    /// transient failure. `paused`: delivery stopped on an error. `slow`: Stop was at least slowAfterSeconds ago.
    static func line(phase: String, message: String, chunks: Int, acknowledged: Int, delivering: Bool, paused: Bool,
                     waiting: Bool, slow: Bool, noSpeech: Bool, allZero: Bool) -> Line {
        switch phase {
        case "stopping":
            return Line(headline: saving, detail: nil, progress: nil, tone: .quiet, showsActions: false)
        case "saved":
            return Line(headline: saved, detail: savedDetail, progress: nil, tone: .done, showsActions: false)
        case "recording":
            let behind = chunks - acknowledged >= behindChunks
            return Line(headline: message, detail: behind && paused ? notAnsweringWhileRecording : nil,
                        progress: behind ? sending(acknowledged, of: chunks) : nil, tone: .quiet, showsActions: false)
        case "pending" where chunks > 0 && !noSpeech && !allZero:
            if delivering {
                let detail: String? = !slow ? nil : waiting ? notAnswering : stillSaving(acknowledged, of: chunks)
                return Line(headline: saving, detail: detail, progress: nil, tone: .quiet, showsActions: false)
            }
            return Line(headline: paused ? notSaved : message, detail: nil, progress: reached(acknowledged, of: chunks),
                        tone: paused ? .problem : .quiet, showsActions: true)
        default:
            return Line(headline: message, detail: nil, progress: nil, tone: .quiet, showsActions: true)
        }
    }
}

/// 0.5.351: the quiet tries after Stop. A save that hit a passing failure (the helper's 5 s health probe answering
/// "Server stopped" while the server was busy or restarting, a timeout, a chunk still in flight) waited for a tap on
/// Retry: 205 s on 2026-10-26 10:58. Only these causes, only once the capture is stopped, at most six more tries in about
/// a minute per delivery; then the panel says Not saved yet with Retry. Replays are safe: the server answers a chunk
/// index it already holds with the same audio from its receipt, and a second save from its saved receipt.
enum MacRecordingSaveRetry {
    static let delays: [Double] = [1, 2, 4, 8, 15, 30]
    static let transientReasons: Set<String> = ["server_unavailable", "mac_chunk_in_progress", "save_in_progress"]
    /// The helper's own sentences for a server that did not answer this time (main.swift speakerReviewToken, and
    /// HelperClientError.timedOut's description).
    static let transientMessages: Set<String> = ["Server stopped", "The COS operation took too long."]
    static func transient(httpStatus: Int?, reason: String?, message: String) -> Bool {
        if reason == "openai_whisper_budget_exhausted" { return false }
        if let reason, transientReasons.contains(reason) { return true }
        if let httpStatus, [502, 503, 504].contains(httpStatus) { return true }
        return reason == nil && httpStatus == nil && transientMessages.contains(message)
    }
    /// The wait before the next quiet try, or nil to stop and say so.
    static func delay(afterAttempt attempt: Int, stopped: Bool, transient: Bool) -> Double? {
        guard stopped, transient, attempt >= 0, attempt < delays.count else { return nil }
        return delays[attempt]
    }
}

struct MacRecordingDiscarder: Sendable {
    typealias Server = @Sendable (_ captureId: String, _ serverInstanceId: String) async -> MacRecordingDiscard.Server
    let spool: MacRecordingSpool
    let server: Server
    struct Outcome: Equatable, Sendable {
        let captureId: String
        let moved: URL?
        let localError: String?
        let server: MacRecordingDiscard.Server
        var line: String { localError.map { "Couldn't discard this recording: " + $0 } ?? MacRecordingDiscard.note(localMoved: moved != nil, server: server) }
    }
    /// `serverSupported`: the server advertised discard (capabilities `discard: true`); false asks nothing.
    func discard(captureId: String, serverInstanceId: String, serverSupported: Bool, localPresent: Bool = true, at date: Date = Date()) async -> Outcome {
        var moved: URL?
        if localPresent {
            do { moved = try await spool.discard(captureId, at: date) }
            catch { return Outcome(captureId: captureId, moved: nil, localError: error.localizedDescription, server: .unreachable) }
        }
        let answer = serverSupported ? await server(captureId, serverInstanceId) : .unsupported
        return Outcome(captureId: captureId, moved: moved, localError: nil, server: answer)
    }
}

/// 0.5.334: a Mac capture known to have no meeting (discarded, no speech) never shows "Saved meeting not found yet":
/// there is nothing to find. Its hand-off ends instead.
enum MacRecordingNoMeeting {
    static let line = "No sound was captured, so there is no meeting to open."
    static func endsHandoff(sessionId: String, noMeeting: Set<String>) -> Bool { sessionId.hasPrefix("mac_") && noMeeting.contains(sessionId) }
}

// MARK: - Meeting detection (0.5.313, Miles 2026-10-15 22:39)
//
// "When a meeting's been detected, something from Zoom, Google Meet, Microsoft Teams ... a recording request that
// allows us to fast track and start recording." Detection reads only which processes hold the microphone (CoreAudio
// process objects) and, for a browser, whether one of its window titles names Google Meet. Pure, so every rule is
// tested and mutated; the app reads CoreAudio and AX, calls these, and acts.

enum MeetingApp: String, CaseIterable, Sendable {
    case zoom, teams, meet
    var title: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .meet: "Google Meet"
        }
    }
}

/// The app a microphone holder belongs to: its meeting app, the app to name and to put on the Never list.
struct MeetingSource: Hashable, Sendable {
    let app: MeetingApp
    let ownerBundleID: String
    let ownerName: String
}

/// One CoreAudio process object, as read: no titles, no audio.
struct MeetingAudioProcess: Equatable, Sendable {
    let pid: Int32
    let bundleID: String
    let input: Bool
}

/// THE table of meeting apps (one place). A process matches a rule when its bundle ID equals one of the prefixes or
/// continues it after a dot (helpers: us.zoom.CptHost, com.microsoft.teams2.modulehost, com.google.Chrome.helper).
/// A prefix ending in "." matches anything under it. Browsers count only with a Google Meet window title.
enum MeetingApps {
    struct Rule: Sendable {
        let app: MeetingApp
        let owner: String
        let ownerName: String
        let prefixes: [String]
        var browser: Bool { app == .meet }
        var source: MeetingSource { MeetingSource(app: app, ownerBundleID: owner, ownerName: ownerName) }
    }
    static let rules: [Rule] = [
        Rule(app: .zoom, owner: "us.zoom.xos", ownerName: "Zoom", prefixes: ["us.zoom.xos", "us.zoom.CptHost", "us.zoom."]),
        Rule(app: .teams, owner: "com.microsoft.teams2", ownerName: "Microsoft Teams", prefixes: ["com.microsoft.teams2", "com.microsoft.teams"]),
        Rule(app: .meet, owner: "com.google.Chrome", ownerName: "Google Chrome", prefixes: ["com.google.Chrome"]),
        // Safari's microphone is held by WebKit's GPU process, which names no app; the Meet title in Safari decides.
        Rule(app: .meet, owner: "com.apple.Safari", ownerName: "Safari", prefixes: ["com.apple.Safari", "com.apple.WebKit.GPU"]),
        Rule(app: .meet, owner: "company.thebrowser.Browser", ownerName: "Arc", prefixes: ["company.thebrowser."]),
        Rule(app: .meet, owner: "ai.perplexity.comet", ownerName: "Comet", prefixes: ["ai.perplexity.comet"]),
        Rule(app: .meet, owner: "com.microsoft.edgemac", ownerName: "Microsoft Edge", prefixes: ["com.microsoft.edgemac"]),
        Rule(app: .meet, owner: "com.brave.Browser", ownerName: "Brave", prefixes: ["com.brave.Browser"]),
        Rule(app: .meet, owner: "org.mozilla.firefox", ownerName: "Firefox", prefixes: ["org.mozilla.firefox", "org.mozilla.plugincontainer"]),
    ]
    static func rule(forBundleID bundleID: String) -> Rule? {
        let id = bundleID.lowercased()
        // COS (Control, its helper, dictation's own capture) is in no rule, and its own pid is skipped in `holding`.
        guard !id.isEmpty else { return nil }
        return rules.first { rule in
            rule.prefixes.contains { raw in
                let prefix = raw.lowercased()
                return prefix.hasSuffix(".") ? id.hasPrefix(prefix) : (id == prefix || id.hasPrefix(prefix + "."))
            }
        }
    }
    /// A window title that names Google Meet: "Meet - abc-defg-hij", "Meet – Weekly sync", or the meet.google.com
    /// address. "Meeting notes" is not a Meet.
    static func showsMeet(_ titles: [String]) -> Bool {
        titles.contains { title in
            title.range(of: "meet.google.com", options: .caseInsensitive) != nil
                || title.range(of: #"(^|[^A-Za-z])Meet($|[^A-Za-z])"#, options: .regularExpression) != nil
        }
    }
    /// Who holds the microphone right now, after exclusions. `browserShowsMeet(owner)` is nil when it cannot be read
    /// (no Accessibility): that browser is skipped and `browserUnchecked` says so.
    /// `latched` (QA 0.5.313): browser pids that showed a Meet title while holding the microphone. The title is the
    /// ACTIVE tab, so a person switching tabs mid-call must not end the meeting: a latched pid counts until its input
    /// stops, and the returned latch keeps only pids still holding input.
    static func holding(_ processes: [MeetingAudioProcess], ownPID: Int32, never: Set<String>, latched: Set<Int32> = [],
                        browserShowsMeet: (String) -> Bool?) -> (sources: Set<MeetingSource>, browserUnchecked: Bool, latched: Set<Int32>) {
        var sources = Set<MeetingSource>()
        var unchecked = false
        var latch = Set<Int32>()
        var titles: [String: Bool?] = [:]
        for process in processes where process.input && process.pid != ownPID {
            guard let rule = rule(forBundleID: process.bundleID), !never.contains(rule.owner) else { continue }
            if rule.browser {
                if latched.contains(process.pid) {
                    sources.insert(rule.source); latch.insert(process.pid); continue
                }
                if titles[rule.owner] == nil { titles[rule.owner] = .some(browserShowsMeet(rule.owner)) }
                switch titles[rule.owner]! {
                case true?: sources.insert(rule.source); latch.insert(process.pid)
                case nil: unchecked = true
                case false?: break
                }
            } else {
                sources.insert(rule.source)
            }
        }
        return (sources, unchecked, latch)
    }
    /// Browser titles are read through Accessibility only when the microphone holders changed, when nothing is cached
    /// for that browser, or every `every`th 2 s tick; never every tick.
    static let titleEvery = 5
    static func titleReadDue(holdersChanged: Bool, cached: Bool, tick: Int, every: Int = titleEvery) -> Bool {
        holdersChanged || !cached || (every > 0 && tick % every == 0)
    }
}

/// A meeting is continuous microphone use by one app. It is detected after a 10 s hold, ends after a 60 s release,
/// and is offered at most once (Not now, the 60 s fold-away and Never all count as offered).
struct MeetingDetectionState: Equatable, Sendable {
    static let holdSeconds: TimeInterval = 10
    static let releaseSeconds: TimeInterval = 60
    struct Track: Equatable, Sendable {
        var holding = false
        var heldSince: Date?
        var releasedAt: Date?
        var inMeeting = false
        var handled = false
    }
    struct Context: Equatable, Sendable {
        var suggestEnabled: Bool
        var allowed: Set<MeetingApp>
        /// A Mac recording is active, starting, stopping or pending delivery; or a COS recording is live.
        var recordingBusy: Bool
        var dictating: Bool
        var cardShowing: Bool
    }
    enum Event: Equatable, Sendable {
        case suggest(MeetingSource)
        case ended(MeetingSource)
        /// Not offered this meeting, and why (for the log): "recording busy", "off", "app not allowed".
        case skipped(MeetingSource, String)
    }
    private(set) var tracks: [MeetingSource: Track] = [:]
    /// The meeting app on the microphone now, for the Record button's automatic title (first by bundle ID).
    var current: MeetingSource? {
        tracks.filter { $0.value.holding }.keys.sorted { $0.ownerBundleID < $1.ownerBundleID }.first
    }
    /// Ticks are needed only while something holds the microphone or a meeting has not ended yet.
    var wantsTicks: Bool { tracks.values.contains { $0.holding || $0.inMeeting } }

    mutating func step(holding: Set<MeetingSource>, now: Date, context: Context) -> [Event] {
        var events: [Event] = []
        for source in Set(tracks.keys).union(holding).sorted(by: { $0.ownerBundleID < $1.ownerBundleID }) {
            var t = tracks[source] ?? Track()
            if holding.contains(source) {
                if !t.holding {
                    t.holding = true; t.heldSince = now; t.releasedAt = nil
                    if !t.inMeeting { t.inMeeting = true; t.handled = false }
                }
            } else if t.holding {
                t.holding = false; t.releasedAt = now
            }
            if !t.holding, t.inMeeting, let released = t.releasedAt, now.timeIntervalSince(released) >= Self.releaseSeconds {
                t = Track()
                events.append(.ended(source))
            }
            if t.holding, t.inMeeting, !t.handled, let since = t.heldSince, now.timeIntervalSince(since) >= Self.holdSeconds {
                if !context.suggestEnabled || !context.allowed.contains(source.app) || context.recordingBusy {
                    // Off, not allowed, or already recording: not this meeting, even once that changes.
                    t.handled = true
                    events.append(.skipped(source, context.recordingBusy ? "recording busy" : (!context.suggestEnabled ? "off" : "app not allowed")))
                } else if !context.dictating, !context.cardShowing {
                    t.handled = true
                    events.append(.suggest(source))
                }
            }
            tracks[source] = t.holding || t.inMeeting ? t : nil
        }
        return events
    }
}

/// The card's words, the recording's title, and the end offer.
enum MeetingDetectedCard {
    static let dismissSeconds: TimeInterval = 60
    static func headline(_ source: MeetingSource) -> String { "Meeting detected · " + source.app.title }
    static let line = "Record on Mac with live transcript? Let people know you're recording."
    static func never(_ source: MeetingSource) -> String { "Never for " + source.ownerName }
    static let endHeadline = "Meeting ended?"
    static func endLine(_ source: MeetingSource) -> String {
        source.app.title + " has been off the microphone for a minute. COS is still recording."
    }
    /// "Zoom meeting 2:05 PM".
    static func title(_ source: MeetingSource, at date: Date, calendar: Calendar = .current) -> String {
        MacRecordingNotice.autoTitle(meetingApp: source.app.title, at: date, calendar: calendar)
    }
    /// "Meeting ended? Stop and save" only for the recording this card started, while it is still the one running.
    /// COS never stops it on its own.
    static func offersEnd(ended: MeetingSource, startedFrom: MeetingSource?, startedCaptureID: String?, runningCaptureID: String?) -> Bool {
        guard let startedFrom, startedFrom == ended, let startedCaptureID, let runningCaptureID else { return false }
        return startedCaptureID == runningCaptureID
    }
    /// Busy for suggestions: anything a new recording would collide with or bury.
    /// A retained (recoverable) capture is not busy: it never blocks a new recording (QA 2026-10-15).
    static func recordingBusy(macOccupied: Bool, macCanStart: Bool, liveRecordings: Int) -> Bool {
        macOccupied || !macCanStart || liveRecordings > 0
    }
}

/// The one-time recording notice (0.5.313, Miles 22:39: "should be stylized for COS and should be a one-time start.
/// Granola and all of the like ... shouldn't require this many steps"). Shown the first time a Mac recording starts,
/// on any path; once acknowledged on this Mac, every Record starts at once. Settings can show it again.
enum MacRecordingNotice {
    static let acknowledgedKey = "macRecording.noticeAcknowledged"
    static let optionsExpandedKey = "macRecording.optionsExpanded"
    static let title = "Record this Mac's audio"
    static let lines = [
        "COS records everything your Mac plays (your microphone stays off) and transcribes it live.",
        "Let people know you're recording.",
    ]
    /// Only while System Audio Recording has not been granted: macOS's own prompt, which COS cannot style.
    static let permissionFootnote = "macOS will ask once to allow System Audio Recording for COS Control."
    /// The quiet reminder on a recording row while it runs.
    static let reminder = "Recording · let people know"
    enum Step: Equatable, Sendable { case notice, start }
    /// Every start asks this, and only `start` records.
    static func step(acknowledged: Bool) -> Step { acknowledged ? .start : .notice }
    static func footnote(permissionGranted: Bool) -> String? { permissionGranted ? nil : permissionFootnote }
    /// The panel's notice shows only while asked for, not yet acknowledged (here or on the pet), and nothing records.
    static func panelShowsNotice(requested: Bool, acknowledged: Bool, occupied: Bool) -> Bool { requested && !acknowledged && !occupied }
    /// "Zoom meeting 2:05 PM" while a meeting app is detected, else "Mac recording 2:05 PM".
    static func autoTitle(meetingApp: String?, at date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h:mm a"
        return (meetingApp.map { $0 + " meeting" } ?? "Mac recording") + " " + f.string(from: date)
    }
    /// What Record names the recording: what the person typed under Options, else the automatic title.
    static func title(typed: String, meetingApp: String?, at date: Date, calendar: Calendar = .current) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? autoTitle(meetingApp: meetingApp, at: date, calendar: calendar) : String(trimmed.prefix(160))
    }
}

/// 0.5.322: the Mac recording's phase on disk, for the detached update swap (HelperSources/main.swift,
/// macCaptureQuitSafety). When Control does not quit within 20 s the swap may force it, but never while a recording is
/// starting, recording or stopping, and never when this record is missing or names another process. Control writes it
/// at launch and on every phase change (MacRecordingStore.phaseRecorder): `{"schema":1,"phase":…,"pid":…,"at":…}`,
/// atomically, owner only, default (class C) file protection so a locked Mac can still write it.
enum MacCaptureStateFile {
    static let name = "mac-capture-state.json"
    /// The phases MacRecordingStore.needsQuitTeardown finishes before a quit; the swap never signals during them.
    static let activePhases: Set<String> = ["starting", "recording", "stopping"]

    /// The helper's own rule for its home: a /tmp/ COS_CONTROL_TEST_HOME, else this user's home.
    static func url(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let home: URL
        if let test = environment["COS_CONTROL_TEST_HOME"], test.hasPrefix("/tmp/") {
            home = URL(fileURLWithPath: test, isDirectory: true).standardizedFileURL
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
        }
        return home.appendingPathComponent("Library/Application Support/COS Control", isDirectory: true).appendingPathComponent(name)
    }

    static func encode(phase: String, pid: Int32, at date: Date) -> Data {
        let object: [String: Any] = ["schema": 1, "phase": phase, "pid": Int(pid), "at": ISO8601DateFormatter().string(from: date)]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func decode(_ data: Data) -> (phase: String, pid: Int32)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let phase = object["phase"] as? String, let pid = (object["pid"] as? NSNumber)?.int32Value else { return nil }
        return (phase, pid)
    }

    static func write(phase: String, pid: Int32 = getpid(), at date: Date = Date(), to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try encode(phase: phase, pid: pid, at: date).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: Capture that survives a stalled app, a watchdog and a quit that keeps the recording (0.5.351)
//
// The incident (mac_b0bd6732, 2026-10-26): the last chunk was written at 12:39:02, the tap was torn down at 12:40:02 and
// nothing was logged or shown. The main thread was busy or blocked from about 12:39:05 (its last log line was 12:39:01,
// and the CPU report for 12:38 to 12:40 shows it inside one SwiftUI update that read the disk's free space). The chunk
// consumer ran on the main actor, so it stopped; the tap's 8-chunk buffer then filled (one chunk in flight plus eight
// queued is ten chunks, 60 s), and the capture queue failed with "storage fell behind", whose report also needs the main
// actor. The pieces below make each of those steps independent of the main actor.

/// A chunk once the writer has stored it, on its way to the main actor for the live checks and delivery. The PCM is
/// replaced: the main actor needs only the exact-zero flag, never the audio.
struct MacRecordingWriterEvent: Sendable {
    var chunk: MacRecordingChunk?
    /// MacRecordingSignal.isSilent of the chunk's own audio, read where the audio still was.
    var silent = false
    var manifest: MacRecordingManifest?
    /// Set instead of the others when the spool refused the chunk (disk, free space, the two-hour limit).
    var failure: String?

    /// Keeps `digitalSilence` and `index`/`endFrame` and nothing else.
    static func slim(_ chunk: MacRecordingChunk) -> MacRecordingChunk {
        chunk.digitalSilence ? .init(index: chunk.index, pcm: Data(count: 2), endFrame: chunk.endFrame, rawSignal: false)
                             : .init(index: chunk.index, pcm: Data(), endFrame: chunk.endFrame, rawSignal: true)
    }
}

/// Gives every stored chunk the next index and the next end frame of the JOURNAL, whichever tap produced it. A tap that
/// is restarted counts from zero again; the journal's own sequence is the one that must stay unbroken.
struct MacRecordingSequencer: Sendable {
    private(set) var count = 0
    private(set) var lastEnd = 0
    init(from manifest: MacRecordingManifest? = nil) { if let manifest { stored(manifest) } }
    func next(_ raw: MacRecordingChunk) -> MacRecordingChunk {
        .init(index: count, pcm: raw.pcm, endFrame: lastEnd + raw.pcm.count / 2, rawSignal: raw.rawSignal)
    }
    mutating func stored(_ manifest: MacRecordingManifest) {
        count = manifest.chunks.count; lastEnd = manifest.chunks.last?.endFrame ?? 0
    }
}

/// When the writer last stored a chunk. Written by the writer, read by the watchdog; never behind the main actor.
final class MacRecordingProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last: Date
    init(_ start: Date = Date()) { last = start }
    func mark(_ date: Date = Date()) { lock.lock(); last = max(last, date); lock.unlock() }
    var lastWrite: Date { lock.lock(); defer { lock.unlock() }; return last }
}

/// No chunk written for five chunk lengths while the recording says it is recording.
enum MacRecordingWatchdog {
    static let chunkSeconds = MacRecordingWAV.framesPerChunk / MacRecordingWAV.sampleRate
    static let stallChunks = 5
    static var stallSeconds: Int { chunkSeconds * stallChunks }
    /// One look per chunk length.
    static var pollSeconds: Int { chunkSeconds }
    /// One restart per stall; this many in a whole recording.
    static let maxRestartsPerRecording = 3

    enum Action: Equatable, Sendable { case none, restart, giveUp }
    struct State: Equatable, Sendable {
        /// When the last chunk before the stall was written (the time the panel names). nil while chunks are arriving.
        var stalledSince: Date?
        var restartAttemptAt: Date?
        var attemptsThisStall = 0
        var totalRestarts = 0
        var gaveUp = false
        mutating func restartFailed() { gaveUp = true }
    }

    static func step(_ state: inout State, now: Date, lastChunk: Date, restartInFlight: Bool) -> Action {
        if let since = state.stalledSince, lastChunk > since {   // a chunk arrived after the stall: it is over
            state.stalledSince = nil; state.restartAttemptAt = nil; state.attemptsThisStall = 0; state.gaveUp = false
        }
        guard !state.gaveUp, !restartInFlight else { return .none }
        let reference = max(lastChunk, state.restartAttemptAt ?? .distantPast)
        guard now.timeIntervalSince(reference) >= TimeInterval(stallSeconds) else { return .none }
        if state.stalledSince == nil { state.stalledSince = lastChunk }
        if state.attemptsThisStall < 1, state.totalRestarts < maxRestartsPerRecording {
            state.attemptsThisStall += 1; state.totalRestarts += 1; state.restartAttemptAt = now
            return .restart
        }
        state.gaveUp = true
        return .giveUp
    }

    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
    /// The panel's line while a stall is open.
    static func line(_ state: State, calendar: Calendar = .current) -> String? {
        guard let since = state.stalledSince else { return nil }
        let at = clock(since, calendar: calendar)
        return state.gaveUp ? "Recording stopped receiving audio at \(at). Stop and save keeps everything up to then."
                            : "Recording stopped receiving audio at \(at). Restarting."
    }
}

/// The captures being written right now, readable from any thread: what a termination signal has to close.
final class MacRecordingOpenCaptures: @unchecked Sendable {
    static let shared = MacRecordingOpenCaptures()
    private let lock = NSLock()
    private var spools: [String: MacRecordingSpool] = [:]
    func add(_ id: String, spool: MacRecordingSpool) { lock.lock(); spools[id] = spool; lock.unlock() }
    func remove(_ id: String) { lock.lock(); spools[id] = nil; lock.unlock() }
    var ids: [String] { lock.lock(); defer { lock.unlock() }; return spools.keys.sorted() }
    private func spool(for id: String) -> MacRecordingSpool? { lock.lock(); defer { lock.unlock() }; return spools[id] }
    /// Notes the interruption and marks the journal stopped. Chunks already written are never touched.
    func closeForExit(_ id: String) async -> Bool {
        guard let spool = spool(for: id) else { return false }
        _ = try? await spool.interrupt(id, reason: MacRecordingSigterm.reason)
        return (try? await spool.markStopped(id)) != nil
    }
}

/// SIGTERM (an update's quit, `kill`, a logout) skips applicationShouldTerminate, so a recording was never marked stopped.
enum MacRecordingSigterm {
    /// Under one second: a signal must not hold the process up.
    static let waitSeconds: TimeInterval = 0.8
    static let reason = "COS Control was quit while recording. Everything recorded up to then is kept."
    struct Result: Equatable, Sendable { var total: Int; var finished: Int; var timedOut: Bool; var elapsedMs: Int }

    /// Runs `work` for every id at once and waits at most `wait` for all of them.
    static func flush(ids: [String], wait: TimeInterval = waitSeconds, work: @escaping @Sendable (String) async -> Bool) -> Result {
        guard !ids.isEmpty else { return Result(total: 0, finished: 0, timedOut: false, elapsedMs: 0) }
        let began = DispatchTime.now()
        final class Tally: @unchecked Sendable {
            private let lock = NSLock(); private var count = 0
            func add() { lock.lock(); count += 1; lock.unlock() }
            var finished: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let tally = Tally(), group = DispatchGroup()
        for id in ids {
            group.enter()
            Task.detached {
                if await work(id) { tally.add() }
                group.leave()
            }
        }
        let timedOut = group.wait(timeout: .now() + wait) == .timedOut
        let finished = tally.finished
        let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - began.uptimeNanoseconds) / 1_000_000)
        return Result(total: ids.count, finished: finished, timedOut: timedOut, elapsedMs: ms)
    }

    /// Takes over `signalNumber` (the default action would end the process at once), closes every open capture within
    /// `wait`, then calls `finish` on the signal queue. The caller keeps the returned source alive.
    static func install(signalNumber: Int32 = SIGTERM, open: MacRecordingOpenCaptures = .shared, wait: TimeInterval = waitSeconds,
                        finish: @escaping @Sendable (Result) -> Void) -> DispatchSourceSignal {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: DispatchQueue(label: "com.gotcos.control.sigterm", qos: .userInitiated))
        source.setEventHandler {
            finish(flush(ids: open.ids, wait: wait) { await open.closeForExit($0) })
        }
        source.resume()
        return source
    }
}

extension MacRecordingWatchdog {
    /// One restart is allowed two chunk lengths.
    static var restartSeconds: Int { chunkSeconds * 2 }
}

/// Runs an operation and gives up waiting after `seconds`. The operation is not cancelled (a stuck tap call cannot be);
/// its answer is simply no longer waited for.
enum MacRecordingBounded {
    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        init(_ continuation: CheckedContinuation<T?, Never>) { self.continuation = continuation }
        func resume(_ value: T?) {
            lock.lock(); let next = continuation; continuation = nil; lock.unlock()
            next?.resume(returning: value)
        }
    }
    static func run<T: Sendable>(seconds: TimeInterval, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = Once<T>(continuation)
            Task { once.resume(await operation()) }
            Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); once.resume(nil) }
        }
    }
}
