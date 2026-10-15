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
    static func warning(silentChunks: Int, source: String) -> String? {
        guard silentChunks >= warnAfterSilentChunks else { return nil }
        let seconds = silentChunks * MacRecordingWAV.framesPerChunk / MacRecordingWAV.sampleRate
        return "No sound reaching COS from \(source) for \(seconds)s. If the call is playing, stop and record All Mac audio."
    }
}

struct MacRecordingChunk: Sendable {
    let index: Int
    let pcm: Data
    let endFrame: Int
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
    private func rootFD(create: Bool) throws -> Int32 {
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
        try write(next); return next
    }
    func path(for chunk: MacRecordingManifest.Chunk, captureId: String) throws -> String {
        guard chunk.index >= 0, chunk.filename == String(format: "%06d.wav", chunk.index) else { throw invalid() }
        return try directory(captureId).appendingPathComponent(chunk.filename).path
    }
    func recoveryWarnings() -> [String] { warnings }
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
                if files.contains(where: { $0.lowercased().hasSuffix(".wav") && !expected.contains($0) }) {
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

/// A confirmed no-speech result may release the composer, never an uncertain or live delivery.
enum MacRecordingRecoveryPolicy {
    static func canKeepForLater(noSpeech: Bool, pending: Bool, stopped: Bool, delivering: Bool) -> Bool {
        noSpeech && pending && stopped && !delivering
    }
}
