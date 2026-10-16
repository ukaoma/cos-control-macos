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
    // MARK: 0.5.316 reference links (Miles 2026-10-16 12:16)
    //
    // A working link (the map above) is one card per session: it receives handoffs, reports to that card and counts for
    // the fence and the queue. A REFERENCE is read-only and may name any number of cards: the card's planner and new
    // assignments may read the session's summary, outputs and change counts, and nothing else. References live in their
    // own file, so every reader of the working map (the helper, the tracker, the send targets, the links digest) sees
    // exactly what it saw before.
    static let maxReferencesPerSession = 50
    static func referencesURL(cards: URL) -> URL {
        cards.deletingLastPathComponent().appendingPathComponent(cards.lastPathComponent.replacingOccurrences(of: ".session-cards.json", with: ".session-references.json"))
    }
    static func loadReferences(_ url: URL) throws -> [String: [WorkSessionCardLink]] {
        try withLock(url) { try readReferences(url) }
    }
    /// Adds `link` as a reference of `sessionID`. Linking the same card again keeps the first link. Never touches a
    /// working link; the caller refuses a reference to the card the session already works on.
    @discardableResult
    static func addReference(_ url: URL, sessionID: String, link: WorkSessionCardLink) throws -> [String: [WorkSessionCardLink]] {
        guard validSessionID(sessionID, includeCursor: true), valid(link) else { throw Failure.corrupt }
        let sessionID = sessionID.lowercased()
        return try withLock(url) {
            var refs = try readReferences(url)
            var rows = refs[sessionID] ?? []
            if rows.contains(where: { $0.workID == link.workID }) { return refs }
            rows.append(link)
            guard rows.count <= maxReferencesPerSession else { throw Failure.corrupt }
            refs[sessionID] = rows
            guard refs.count <= 10_000 else { throw Failure.corrupt }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(refs)
            guard data.count < limit else { throw Failure.corrupt }
            try write(data, to: url)
            return refs
        }
    }
    @discardableResult
    static func removeReference(_ url: URL, sessionID: String, workID: String) throws -> [String: [WorkSessionCardLink]] {
        guard validSessionID(sessionID, includeCursor: true), !workID.isEmpty else { throw Failure.corrupt }
        let sessionID = sessionID.lowercased()
        return try withLock(url) {
            var refs = try readReferences(url)
            guard let rows = refs[sessionID], rows.contains(where: { $0.workID == workID }) else { throw Failure.conflict }
            let left = rows.filter { $0.workID != workID }
            refs[sessionID] = left.isEmpty ? nil : left
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try write(encoder.encode(refs), to: url)
            return refs
        }
    }
    private static func valid(_ link: WorkSessionCardLink) -> Bool {
        !link.workID.isEmpty && link.workID.utf8.count <= 256 && !link.title.isEmpty && link.title.utf8.count <= 32_000
            && !link.sourceRevision.isEmpty && link.sourceRevision.utf8.count <= 256 && link.at.isFinite
    }
    private static func readReferences(_ url: URL) throws -> [String: [WorkSessionCardLink]] {
        guard let data = try readData(url) else { return [:] }
        guard let refs = try? JSONDecoder().decode([String: [WorkSessionCardLink]].self, from: data), refs.count <= 10_000,
              refs.allSatisfy({ validSessionID($0.key, includeCursor: true) && $0.value.count <= maxReferencesPerSession && $0.value.allSatisfy(valid)
                && Set($0.value.map(\.workID)).count == $0.value.count }) else { throw Failure.corrupt }
        var normalized: [String: [WorkSessionCardLink]] = [:]
        for (key, value) in refs {
            guard normalized[key.lowercased()] == nil else { throw Failure.corrupt }
            normalized[key.lowercased()] = value
        }
        return normalized
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
    /// Private, per-task chat state shares the same no-follow locking and fsync writer.
    static func chatRead(_ url: URL) throws -> Data? { try withLock(url) { try readData(url) } }
    static func chatWrite(_ url: URL, data: Data, expected: Data?) throws {
        guard data.count < limit else { throw Failure.corrupt }
        try withLock(url) {
            guard try readData(url) == expected else { throw Failure.conflict }
            try write(data, to: url)
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

// MARK: - 0.5.312 Work session meter (Connections: context, outputs, changes)
//
// Miles approved the Work Context Meter on 2026-10-15 21:00 (design/work-context-mock.html, right column), with
// A/A/A: estimates, each session's usage read from its own local transcript, and Changes as a git diff of the
// session's working folder since the handoff. Pure, so the helper (which reads the files) and Control (which draws
// them) share one parser, and Tests/WorkSessionMeterChecks.swift runs every branch. Paths and counts only: no
// transcript text ever leaves these functions.
enum WorkSessionMeter {
    struct Context: Equatable, Sendable {
        let used: Int
        let window: Int
        let model: String
        var fraction: Double { window > 0 ? min(1, max(0, Double(used) / Double(window))) : 0 }
        var percent: Int { Int((fraction * 100).rounded()) }
        /// The mock's orange state.
        var nearlyFull: Bool { fraction >= WorkSessionMeter.compactingFraction }
        /// "24% · 124k / 512k"
        var label: String { "\(percent)% · \(WorkSessionMeter.tokens(used)) / \(WorkSessionMeter.tokens(window))" }
    }
    struct Output: Equatable, Sendable {
        let path: String
        let at: Date
    }
    struct Changes: Equatable, Sendable {
        let files: Int
        let insertions: Int
        let deletions: Int
        var isEmpty: Bool { files == 0 && insertions == 0 && deletions == 0 }
    }
    struct FileChange: Equatable, Sendable {
        let path: String
        /// Nil for a binary file (git prints "-").
        let insertions: Int?
        let deletions: Int?
    }

    static let compactingFraction = 0.85
    static let compactingNote = "Close to compacting. A fresh session keeps this send intact."
    /// Bytes read from the END of a transcript: enough for the newest usage line, then widened to find one.
    static let contextTailBytes = 512 * 1024
    static let contextTailMaxBytes = 4 * 1024 * 1024
    /// Outputs since the handoff are read from at most this much of the tail; older ones are reported as partial.
    static let outputsTailBytes = 4 * 1024 * 1024
    static let claudeWriteTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    /// THE context-window table, and it is an ESTIMATE. A window the transcript states (Codex `model_context_window`)
    /// wins. Claude, by the model id the JSONL records (claude-opus-5-5, claude-opus-5, claude-fable-5-1,
    /// claude-sonnet-5-5, claude-haiku-5-5 seen on this Mac 2026-10-15): the 5 family is 1M (Miles's panel: Opus 5.5
    /// "238.3k / 1M"). Only the 4 and 3 families are 200k, unless the id carries the 1M marker or usage already passed
    /// 200k. Any other id (an alias such as "opus") is unknown. Codex without a stated window: 272k for gpt-5.
    /// An unknown window hides the meter rather than drawing a guess.
    static func window(provider: String, model: String, reported: Int?, used: Int) -> Int? {
        if let reported, reported > 0 { return reported }
        let id = model.lowercased()
        switch provider {
        case "claude":
            if ["claude-opus-5", "claude-sonnet-5", "claude-fable-5", "claude-haiku-5"].contains(where: { id.hasPrefix($0) }) { return 1_000_000 }
            guard ["claude-opus-4", "claude-sonnet-4", "claude-haiku-4", "claude-3"].contains(where: { id.hasPrefix($0) }) else { return nil }
            return id.contains("[1m]") || id.hasSuffix("-1m") || used > 200_000 ? 1_000_000 : 200_000
        case "codex":
            return id.hasPrefix("gpt-5") ? 272_000 : nil
        default:
            return nil
        }
    }

    /// "124k", "1M", "1.2M", "640".
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            let m = (Double(n) / 1_000_000 * 10).rounded() / 10
            return (m == m.rounded() ? String(Int(m)) : String(m)) + "M"
        }
        if n >= 1_000 { return "\(Int((Double(n) / 1_000).rounded()))k" }
        return "\(max(0, n))"
    }

    /// Whole lines from a tail read. A read that did not start at byte 0 drops its first, partial line.
    static func lines(_ data: Data, fromStart: Bool) -> [String] {
        var rows = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        if !fromStart, !rows.isEmpty { rows.removeFirst() }
        return rows
    }

    private static func object(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    static func date(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }

    /// The newest main-thread assistant turn's usage: input + cache read + cache creation is what the context holds.
    static func claudeContext(lines: [String]) -> Context? {
        for line in lines.reversed() where line.contains("\"usage\"") {
            guard let row = object(line), row["type"] as? String == "assistant", row["isSidechain"] as? Bool != true,
                  let message = row["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { continue }
            let model = message["model"] as? String ?? ""
            if model == "<synthetic>" { continue }
            let used = (int(usage["input_tokens"]) ?? 0) + (int(usage["cache_read_input_tokens"]) ?? 0) + (int(usage["cache_creation_input_tokens"]) ?? 0)
            guard used > 0, let window = window(provider: "claude", model: model, reported: nil, used: used) else { continue }
            return Context(used: used, window: window, model: model)
        }
        return nil
    }

    /// The newest `token_count` event: last_token_usage is what the last turn put in the window.
    static func codexContext(lines: [String]) -> Context? {
        var model = ""
        for line in lines.reversed() where line.contains("\"turn_context\"") {
            if let row = object(line), row["type"] as? String == "turn_context", let payload = row["payload"] as? [String: Any],
               let name = payload["model"] as? String { model = name; break }
        }
        for line in lines.reversed() where line.contains("\"token_count\"") {
            guard let row = object(line), let payload = row["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any], let last = info["last_token_usage"] as? [String: Any] else { continue }
            let used = int(last["total_tokens"]) ?? ((int(last["input_tokens"]) ?? 0) + (int(last["output_tokens"]) ?? 0))
            guard used > 0, let window = window(provider: "codex", model: model, reported: int(info["model_context_window"]), used: used) else { continue }
            return Context(used: used, window: window, model: model)
        }
        return nil
    }

    /// The session's working folder: Claude stamps `cwd` on every line; Codex on session_meta and turn_context.
    static func workingFolder(provider: String, lines: [String]) -> String? {
        for line in lines.reversed() where line.contains("\"cwd\"") {
            guard let row = object(line) else { continue }
            let cwd = provider == "codex" ? (row["payload"] as? [String: Any])?["cwd"] as? String : row["cwd"] as? String
            if let cwd, cwd.hasPrefix("/") { return cwd }
        }
        return nil
    }

    /// Files a Claude session wrote at or after `since`: Write, Edit, MultiEdit and NotebookEdit tool calls.
    static func claudeOutputs(lines: [String], since: Date) -> [Output] {
        var found: [Output] = []
        for line in lines where line.contains("\"tool_use\"") {
            guard let row = object(line), row["type"] as? String == "assistant", let at = date(row["timestamp"]), at >= since,
                  let content = (row["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for item in content where item["type"] as? String == "tool_use" {
                guard let name = item["name"] as? String, claudeWriteTools.contains(name), let input = item["input"] as? [String: Any],
                      let path = (input["file_path"] as? String) ?? (input["notebook_path"] as? String), path.hasPrefix("/") else { continue }
                found.append(Output(path: path, at: at))
            }
        }
        return found
    }

    /// Files a Codex session added or updated at or after `since`, from apply_patch headers anywhere in a response
    /// item (a custom tool call's input, or a shell call's escaped arguments). Relative paths resolve against `cwd`.
    static func codexOutputs(lines: [String], since: Date, cwd: String?) -> [Output] {
        var found: [Output] = []
        for line in lines where line.contains("*** Add File: ") || line.contains("*** Update File: ") || line.contains("*** Move to: ") {
            guard let row = object(line), let at = date(row["timestamp"]), at >= since else { continue }
            var texts: [String] = []
            collectStrings(row["payload"], into: &texts, depth: 0)
            for text in texts {
                for path in patchPaths(text) {
                    if path.hasPrefix("/") { found.append(Output(path: path, at: at)) }
                    else if let cwd { found.append(Output(path: (cwd as NSString).appendingPathComponent(path), at: at)) }
                }
            }
        }
        return found
    }

    private static func collectStrings(_ value: Any?, into out: inout [String], depth: Int) {
        guard depth < 6 else { return }
        if let text = value as? String {
            out.append(text)
            // Shell and function calls carry their arguments as a JSON string; the patch is one level further in.
            if text.hasPrefix("{") || text.hasPrefix("["), let data = text.data(using: .utf8),
               let inner = try? JSONSerialization.jsonObject(with: data) { collectStrings(inner, into: &out, depth: depth + 1) }
        } else if let list = value as? [Any] {
            for item in list { collectStrings(item, into: &out, depth: depth + 1) }
        } else if let map = value as? [String: Any] {
            for item in map.values { collectStrings(item, into: &out, depth: depth + 1) }
        }
    }

    /// apply_patch headers for files that exist afterwards: Add, Update and the destination of a Move. Never Delete.
    static func patchPaths(_ patch: String) -> [String] {
        patch.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            let line = String(raw)
            for prefix in ["*** Add File: ", "*** Update File: ", "*** Move to: "] where line.hasPrefix(prefix) {
                let path = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                return path.isEmpty ? nil : path
            }
            return nil
        }
    }

    /// Newest first, one row per file.
    static func newestUnique(_ outputs: [Output]) -> [Output] {
        var seen = Set<String>()
        return outputs.sorted { $0.at > $1.at }.filter { seen.insert(($0.path as NSString).standardizingPath).inserted }
    }

    static func isImage(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp", "svg"].contains((path as NSString).pathExtension.lowercased())
    }

    /// `git diff --shortstat`: " 9 files changed, 1284 insertions(+), 312 deletions(-)". Empty output is no change.
    /// Other lines (a warning on stderr) are ignored.
    static func shortstat(_ output: String) -> Changes {
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let files = firstNumber(line, before: " file") else { continue }
            return Changes(files: files, insertions: firstNumber(line, before: " insertion") ?? 0, deletions: firstNumber(line, before: " deletion") ?? 0)
        }
        return Changes(files: 0, insertions: 0, deletions: 0)
    }

    private static func firstNumber(_ line: String, before marker: String) -> Int? {
        guard let range = line.range(of: marker) else { return nil }
        let digits = line[..<range.lowerBound].reversed().prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(String(digits.reversed()))
    }

    /// `git diff --numstat`: "12\t3\tpath", "-\t-\timage.png" for binary files.
    static func numstat(_ output: String) -> [FileChange] {
        output.split(whereSeparator: \.isNewline).compactMap { raw -> FileChange? in
            let parts = raw.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[2].isEmpty,
                  parts[0] == "-" || Int(parts[0]) != nil, parts[1] == "-" || Int(parts[1]) != nil else { return nil }
            return FileChange(path: String(parts[2]), insertions: Int(parts[0]), deletions: Int(parts[1]))
        }
    }

    /// "+1,284 −312 · 9 files · since this handoff", or the mock's quiet line when nothing changed.
    static func changesLine(_ changes: Changes?) -> String {
        guard let changes, !changes.isEmpty else { return noChanges }
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        let n: (Int) -> String = { f.string(from: NSNumber(value: $0)) ?? String($0) }
        return "+\(n(changes.insertions)) −\(n(changes.deletions)) · \(n(changes.files)) \(changes.files == 1 ? "file" : "files") · since this handoff"
    }
    static let noChanges = "No code changes since its last handoff"
}
