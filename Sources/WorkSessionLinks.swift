import Foundation
import CryptoKit
import Darwin

struct WorkSessionCardLink: Codable, Equatable, Sendable {
    let workID: String
    let title: String
    let sourceRevision: String
    let at: Double
}

/// Both Control and the headless helper use the same locked read/merge/write path.
/// This remains the existing session-to-card map; it creates no job or delivery receipt.
struct WorkNoticeDismissal: Codable, Equatable, Sendable {
    let signature: String
    let at: Double
}
enum WorkSessionLinks {
    enum Failure: LocalizedError, CustomStringConvertible {
        case unsafeFile, corrupt, busy, conflict
        var description: String { errorDescription ?? "Session association unavailable." }
        var errorDescription: String? {
            switch self {
            case .unsafeFile: "The session association file is unsafe. No associations were changed."
            case .corrupt: "The session association file could not be read. No associations were changed."
            case .busy: "Session associations are being updated. Refresh and try again."
            case .conflict: "The session association changed. Read fresh context before replacing it."
            }
        }
    }
    static let limit = 2_000_000
    static func defaultURL(testHome: String? = ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"]) -> URL {
        let base = testHome.flatMap { $0.hasPrefix("/tmp/") ? $0 : nil }.map { URL(fileURLWithPath: $0).appendingPathComponent("work-handoffs") }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/COS Control/work-handoffs")
        return base.appendingPathComponent("handoffs.session-cards.json")
    }
    static func revision(_ link: WorkSessionCardLink) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(link)).map { String(format: "%02x", $0) }.joined()
    }
    static func validSessionID(_ value: String, includeCursor: Bool = false) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && (includeCursor ? ["codex", "claude", "cursor"] : ["codex", "claude"]).contains(String(parts[0]))
            && parts[1].count == 36 && UUID(uuidString: String(parts[1])) != nil
    }
    static func load(_ url: URL) throws -> [String: WorkSessionCardLink] {
        try withLock(url) { try read(url) }
    }
    @discardableResult
    static func associate(_ url: URL, sessionID: String, link: WorkSessionCardLink, expected: String) throws -> [String: WorkSessionCardLink] {
        guard validSessionID(sessionID, includeCursor: true), !link.workID.isEmpty, link.workID.utf8.count <= 256,
              !link.title.isEmpty, link.title.utf8.count <= 32_000, !link.sourceRevision.isEmpty,
              link.sourceRevision.utf8.count <= 256, link.at.isFinite,
              expected == "none" || expected.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw Failure.corrupt }
        let sessionID = sessionID.lowercased()
        return try withLock(url) {
            var links = try read(url)
            // Retrying an already-established association preserves its original timestamp and digest.
            if links[sessionID]?.workID == link.workID { return links }
            let current = try links[sessionID].map(revision) ?? "none"
            guard current == expected else { throw Failure.conflict }
            links[sessionID] = link
            guard links.count <= 10_000 else { throw Failure.corrupt }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(links)
            guard data.count < limit else { throw Failure.corrupt }
            try write(data, to: url)
            return links
        }
    }
    @discardableResult
    static func remove(_ url: URL, sessionID: String, workID: String, expected: String) throws -> [String: WorkSessionCardLink] {
        guard validSessionID(sessionID, includeCursor: true), expected.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw Failure.corrupt }
        let sessionID = sessionID.lowercased()
        return try withLock(url) {
            var links = try read(url)
            guard let current = links[sessionID], current.workID == workID, try revision(current) == expected else { throw Failure.conflict }
            links.removeValue(forKey: sessionID)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try write(encoder.encode(links), to: url)
            return links
        }
    }
    static func loadNotices(_ url: URL) throws -> [String: WorkNoticeDismissal] {
        try withLock(url) { try readNotices(url) }
    }
    static func setNotice(_ url: URL, receiptID: String, signature: String?) throws -> [String: WorkNoticeDismissal] {
        guard !receiptID.isEmpty, receiptID.utf8.count <= 256 else { throw Failure.corrupt }
        return try withLock(url) {
            var notices = try readNotices(url)
            if let signature {
                guard signature.count == 64 else { throw Failure.corrupt }
                notices[receiptID] = WorkNoticeDismissal(signature: signature, at: Date().timeIntervalSince1970)
            } else { notices.removeValue(forKey: receiptID) }
            guard notices.count <= 10_000 else { throw Failure.corrupt }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(notices)
            guard data.count < limit else { throw Failure.corrupt }
            try write(data, to: url)
            return notices
        }
    }
    private static func readNotices(_ url: URL) throws -> [String: WorkNoticeDismissal] {
        guard let data = try readData(url) else { return [:] }
        guard let result = try? JSONDecoder().decode([String: WorkNoticeDismissal].self, from: data),
              result.count <= 10_000, result.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256
                  && $0.value.signature.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil && $0.value.at.isFinite }) else { throw Failure.corrupt }
        return result
    }
    private static func withLock<T>(_ url: URL, body: () throws -> T) throws -> T {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directory = stat()
        guard lstat(parent.path, &directory) == 0, (directory.st_mode & S_IFMT) == S_IFDIR,
              directory.st_uid == getuid(), (directory.st_mode & 0o022) == 0 else { throw Failure.unsafeFile }
        let lock = url.deletingPathExtension().appendingPathExtension("lock")
        let fd = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.unsafeFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, (info.st_mode & 0o077) == 0 else { throw Failure.unsafeFile }
        let deadline = Date().addingTimeInterval(5)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else { throw Failure.busy }
            usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private static func read(_ url: URL) throws -> [String: WorkSessionCardLink] {
        guard let data = try readData(url) else { return [:] }
        guard let links = try? JSONDecoder().decode([String: WorkSessionCardLink].self, from: data), links.count <= 10_000,
              links.allSatisfy({ validSessionID($0.key, includeCursor: true) && !$0.value.workID.isEmpty && $0.value.workID.utf8.count <= 256
                && !$0.value.title.isEmpty && $0.value.title.utf8.count <= 32_000 && !$0.value.sourceRevision.isEmpty
                && $0.value.sourceRevision.utf8.count <= 256 && $0.value.at.isFinite }) else { throw Failure.corrupt }
        var normalized: [String: WorkSessionCardLink] = [:]
        for (key, value) in links {
            guard normalized[key.lowercased()] == nil else { throw Failure.corrupt }
            normalized[key.lowercased()] = value
        }
        return normalized
    }
    private static func readData(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw Failure.unsafeFile }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_size >= 0, info.st_size < limit else { throw Failure.unsafeFile }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw Failure.corrupt }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count < limit else { throw Failure.corrupt }
        }
        return data
    }
    private static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".session-cards-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure.unsafeFile }
        defer { close(fd); unlink(temp.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw Failure.unsafeFile }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temp.path, url.path) == 0 else { throw Failure.unsafeFile }
    }
}
