import Foundation

/// Desktop dictation is a user gesture, separate from meeting recording and glasses gestures.
enum MacDictationPolicy {
    static let maximumSeconds = 120
    static let maximumPCMBytes = maximumSeconds * 16_000 * 2
    static func mayInsert(originalPID: Int32, currentPID: Int32, sameElement: Bool,
                          sameSelection: Bool, secure: Bool, trusted: Bool) -> Bool {
        originalPID > 0 && originalPID == currentPID && sameElement && sameSelection && !secure && trusted
    }
    static func mayStart(enabled: Bool, busy: Bool) -> Bool {
        enabled && !busy
    }
    static func wav(_ pcm: Data) throws -> Data {
        guard !pcm.isEmpty, pcm.count % 2 == 0, pcm.count <= maximumPCMBytes else {
            throw NSError(domain: "COSDictation", code: 1, userInfo: [NSLocalizedDescriptionKey: "Dictation audio is empty or exceeds two minutes."])
        }
        var result = Data()
        func ascii(_ s: String) { result.append(contentsOf: s.utf8) }
        func u16(_ x: UInt16) { var n = x.littleEndian; withUnsafeBytes(of: &n) { result.append(contentsOf: $0) } }
        func u32(_ x: UInt32) { var n = x.littleEndian; withUnsafeBytes(of: &n) { result.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(pcm.count + 36)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        ascii("data"); u32(UInt32(pcm.count)); result.append(pcm)
        return result
    }
}

/// Serial microphone callback owns conversion; this lock protects its bounded result from Stop.
final class DictationPCMBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var failure: String?
    private var level: Double = 0
    func append(_ bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return }
        // A callback may straddle the deadline. Keep the completed clip, rather than
        // turning a valid two-minute recording into an unrecoverable overflow error.
        let remaining = MacDictationPolicy.maximumPCMBytes - data.count
        data.append(bytes.prefix(max(0, min(remaining, bytes.count / 2 * 2))))
        level = bytes.withUnsafeBytes { raw in
            var peak = 0.0
            for offset in stride(from: 0, to: raw.count - raw.count % 2, by: 2) {
                peak = max(peak, abs(Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))) / 32768)
            }
            return peak
        }
    }
    func fail(_ message: String) { lock.lock(); failure = message; lock.unlock() }
    func result() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw NSError(domain: "COSDictation", code: 1, userInfo: [NSLocalizedDescriptionKey: failure]) }
        return data
    }
    func snapshot(maximumBytes: Int) -> Data { lock.lock(); defer { lock.unlock() }; return Data(data.suffix(max(0, maximumBytes / 2 * 2))) }
    func failureMessage() -> String? { lock.lock(); defer { lock.unlock() }; return failure }
    func currentLevel() -> Double { lock.lock(); defer { lock.unlock() }; return level }
}
