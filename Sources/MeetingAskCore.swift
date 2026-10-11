import Foundation
import CryptoKit

// Server-owned accepted history; this file holds wire types and private, per-client recovery state.
struct MeetingAskModel: Codable, Equatable, Sendable {
    var engine: String
    var model: String
    var label: String { "\(engine.capitalized) · \(model)" }
}
struct MeetingAskModelOption: Codable, Identifiable, Sendable {
    var engine: String
    var model: String
    var available: Bool
    var reason: String?
    var id: String { engine + ":" + model }
    var choice: MeetingAskModel { .init(engine: engine, model: model) }
}
struct MeetingAskWeb: Codable, Sendable { var available: Bool; var reason: String?; var engine: String? }
struct MeetingAskConfig: Codable, Sendable {
    var protocolVersion: Int
    var serverInstanceId: String
    var selected: MeetingAskModel
    var models: [MeetingAskModelOption]
    var pairingContext: String?
    var web: MeetingAskWeb?
}
struct LiveAskSource: Codable, Identifiable, Sendable {
    let id: String
    let kind: String
    let title: String
    let text: String
    var turnId: Int?
    var elapsedMs: Int?
    var sessionId: String?
    var recordId: String?
    var memoryId: String?
    var domain: String?
    var month: String?
    var filename: String?
    var fileId: String?
    var revision: String?
    var url: String?
    var retrievedAt: String?
    var retrievalId: String?
}
struct MeetingAskFile: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var revision: String
    var name: String
    var status: String
    var text: String
    var notice: String?
}
struct MeetingAskExchange: Codable, Identifiable, Sendable {
    var requestId: String
    var sessionId: String
    var serverInstanceId: String
    var action: String
    var question: String
    var status: String
    var createdAt: String
    var updatedAt: String
    var completedAt: String?
    var selectedModel: MeetingAskModel
    var model: String?
    var answer: String?
    var sources: [LiveAskSource]
    var notices: [String]
    var throughMs: Int
    var files: [MeetingAskFile]
    var error: String?
    var retryOf: String?
    var id: String { requestId }
    var terminal: Bool { !["pending", "running"].contains(status) }
}
struct MeetingAskHistory: Codable, Sendable {
    var exchanges: [MeetingAskExchange]
    var nextOffset: Int?
    var files: [MeetingAskFile]
}
struct MeetingAskReceipt: Codable { var exchange: MeetingAskExchange }
struct MeetingAskTurn: Codable, Sendable { var id: Int; var elapsedMs: Int; var speaker: String; var text: String }
struct MeetingAskFileRef: Codable, Sendable { var id: String; var revision: String }
struct MeetingAskSubmit: Codable, Sendable {
    var consumesComposer: Bool { action == "ask" && retryOf == nil }
    var requestId: String
    var sessionId: String
    var serverInstanceId: String
    var action: String
    var question: String
    var elapsedMs: Int
    var turns: [MeetingAskTurn]
    var model: MeetingAskModel
    var files: [MeetingAskFileRef]
    var retryOf: String?
}
struct MeetingAskLocalRecord: Codable {
    var schema = 1
    var scope: String
    var draft = ""
    var outbox: MeetingAskSubmit?
    var exchanges: [MeetingAskExchange] = []
    var files: [MeetingAskFile] = []
}

/// No automatic inference replay. An outbox can only be reconciled using its original request ID.
struct MeetingAskDisk {
    let root: URL
    static let maxBytes = 16_000_000
    static func scope(server: String, pairing: String, session: String) -> String {
        SHA256.hash(data: Data((server + "\n" + pairing + "\n" + session).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func file(_ scope: String) throws -> URL {
        guard scope.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw CocoaError(.fileWriteNoPermission) }
        let url = root.appendingPathComponent(scope + ".json")
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true { throw CocoaError(.fileReadNoPermission) }
        return url
    }
    func read(_ scope: String) throws -> MeetingAskLocalRecord {
        let url = try file(scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return .init(scope: scope) }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attrs[.size] as? NSNumber)?.intValue ?? (Self.maxBytes + 1)) <= Self.maxBytes else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(MeetingAskLocalRecord.self, from: Data(contentsOf: url))
        guard value.schema == 1, value.scope == scope else { throw CocoaError(.coderReadCorrupt) }
        return value
    }
    func readConfig(pairing: String) throws -> MeetingAskConfig? {
        let url = try file(Self.scope(server: "connection-cache", pairing: pairing, session: "config"))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard ((attrs[.size] as? NSNumber)?.intValue ?? 100_001) <= 100_000 else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url)
        guard data.count <= 100_000 else { throw CocoaError(.fileReadTooLarge) }
        let value = try JSONDecoder().decode(MeetingAskConfig.self, from: data)
        guard value.pairingContext == pairing else { throw CocoaError(.coderReadCorrupt) }
        return value
    }
    func writeConfig(_ config: MeetingAskConfig) throws {
        guard let pairing = config.pairingContext else { return }
        let url = try file(Self.scope(server: "connection-cache", pairing: pairing, session: "config"))
        try JSONEncoder().encode(config).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func write(_ record: MeetingAskLocalRecord) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let url = try file(record.scope)
        let siblings = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        let used = try siblings.filter { $0 != url }.reduce(0) { total, item in
            let values = try item.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return total + (values.isRegularFile == true ? (values.fileSize ?? 0) : 0)
        }
        guard used + data.count <= 128_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
        // Class C, never class B (complete unless open). The keybag locks about five minutes after
        // the screen does, and a class-B record then cannot be reopened for the fsync below or read
        // back, so every background save during a locked-Mac G2 meeting failed and blocked Ask
        // (observed Oct 10 2026; the class-C config write in the same process kept working).
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize(); try handle.close()
    }
}

enum MeetingAskText {
    static func failure(_ reason: String) -> String {
        switch reason {
        case "provider_timeout": return "The selected model took too long. Retry when you’re ready."
        case "provider_unavailable", "model_unavailable": return "The selected model is unavailable. Check Meeting assistant settings, then retry."
        case "invalid_answer", "invalid_provider_output": return "The model returned an unreadable answer. Your question is saved; you can retry."
        case "journal_write_failed": return "This answer could not be saved. Copy available context before restarting COS."
        case "server_restarted": return "COS restarted before this answer finished. Retry to ask again."
        case "cancelled", "cancelled_by_user": return "This answer was stopped. Your question remains saved."
        default: return "Meeting assistance could not finish. Check the connected model and retry."
        }
    }
    static func evidenceFiles(exchanges: [MeetingAskExchange], current: [MeetingAskFile]) -> [MeetingAskFile] {
        var seen = Set<String>()
        return (exchanges.flatMap(\.files) + current).filter { seen.insert($0.id + "@" + $0.revision).inserted }
    }
    /// No rewrite of canonical Markdown. Ambiguous documents remain honestly labelled documents.
    static func transcript(_ raw: String) -> (text: String, document: Bool) {
        let lines = raw.components(separatedBy: "\n")
        let heading = try! NSRegularExpression(pattern: #"^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$"#)
        var start: Int?, level = 0, end = lines.count, fenced = false
        var document = false
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") { fenced.toggle(); continue }
            guard !fenced, let match = heading.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let lr = Range(match.range(at: 1), in: line), let tr = Range(match.range(at: 2), in: line) else { continue }
            document = true
            let depth = line[lr].count
            let title = line[tr].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " *_:"))
            if start != nil, depth <= level { end = index; break }
            if ["transcript", "full transcript", "meeting transcript", "raw transcript"].contains(title) { start = index + 1; level = depth }
        }
        if let start { return (lines[start..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), false) }
        return (raw, document)
    }
    static func fullContext(title: String, transcript: String, exchanges: [MeetingAskExchange], files: [MeetingAskFile]) -> String {
        var sections = ["# " + title, "## Transcript\n" + transcript]
        for (index, exchange) in exchanges.enumerated() {
            let namespace = "Q\(index + 1)"
            var answer = exchange.answer ?? "No answer (\(exchange.status))."
            // Citation IDs are per answer, never global across a meeting.
            for source in exchange.sources { answer = answer.replacingOccurrences(of: "[\(source.id)]", with: "[\(namespace):\(source.id)]") }
            var part = "## \(namespace) · \(exchange.question)\n\(answer)\nModel: \(exchange.model ?? exchange.selectedModel.label) · through \(exchange.throughMs) ms · \(exchange.status)"
            for source in exchange.sources {
                part += "\n[\(namespace):\(source.id)] \(source.kind): \(source.title)\n\(source.text)"
                if let url = safeURL(source.url) { part += "\n" + url.absoluteString }
            }
            if !exchange.notices.isEmpty { part += "\n" + exchange.notices.joined(separator: "\n") }
            sections.append(part)
        }
        if !files.isEmpty {
            sections.append("## Files\n" + files.map { "### \($0.name) [\($0.id)@\($0.revision)] · \($0.status)\n" + ($0.status == "ready" ? $0.text : "Text unavailable: " + ($0.notice ?? $0.status)) }.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n")
    }
    static func safeURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil,
              host != "localhost", host != "::1", !host.hasSuffix(".local"), !host.hasPrefix("127."), !host.hasPrefix("10."), !host.hasPrefix("192.168."), !host.contains(":"), !host.hasPrefix("169.254."), !host.hasPrefix("0.") else { return nil }
        let parts = host.split(separator: ".")
        if parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]),
           (first == 172 && (16...31).contains(second)) || first >= 224 { return nil }
        return url
    }
}

/// 0.5.281 (Miles, 2026-10-10, on 0.5.280): a screenshot thumbnail dragged onto "Ask about this meeting" became its
/// `/var/folders/.../Screenshot ... .png` path as typed text, and that path went to the model as the question with no file.
/// The composer is now an attachment target. This decides, from what a drop or a paste carries, whether it is a file for
/// this meeting's Files (the same intake the Files box uses) or text for the question. Pure: Tests/MeetingAskChecks.swift.
enum MeetingAskComposerIntake {
    enum Route: Equatable {
        /// Local files: Finder files, the screenshot thumbnail, or rule C's path-only text.
        case attachFiles([URL])
        /// PNG or TIFF data with no text beside it (a copied screenshot).
        case attachImage
        /// Text for the question, inserted as typed.
        case text
    }
    /// Image data the meeting paste intake reads (`WorkCardFileStore.meetingPastePayload` takes PNG, else TIFF).
    static let imageTypes: Set<String> = ["public.png", "public.tiff", "NeXT TIFF v4.0 pasteboard type", "Apple PNG pasteboard type"]
    /// Anything that is words. Copying from Keynote, Pages or a browser puts a picture of the selection beside its text;
    /// that paste is text, so an image counts as an attachment only when nothing here comes with it.
    static let textTypes: Set<String> = ["public.utf8-plain-text", "public.utf16-plain-text", "public.utf16-external-plain-text",
        "public.plain-text", "NSStringPboardType", "public.rtf", "NeXT Rich Text Format v1.0 pasteboard type", "com.apple.flat-rtfd",
        "NeXT RTFD pasteboard type", "public.html", "Apple HTML pasteboard type", "public.url", "Apple URL pasteboard type"]

    /// - types: the pasteboard's type identifiers. fileURLs: the file URLs it holds (read with file URLs only).
    /// - text: the plain text it would insert. draft: the composer's text before the insert.
    static func route(types: [String], fileURLs: [URL], text: String?, draft: String, isFile: (String) -> Bool) -> Route {
        let local = fileURLs.filter(\.isFileURL)
        if !local.isEmpty { return .attachFiles(local) }
        let offered = Set(types)
        if !offered.isDisjoint(with: imageTypes), offered.isDisjoint(with: textTypes) { return .attachImage }
        // Rule C at the insert: only into an empty composer, so a path dropped or pasted after words stays text.
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let text, let urls = localFiles(in: text, isFile: isFile) {
            return .attachFiles(urls)
        }
        return .text
    }

    /// Rule C, defense in depth (0.5.281). Text is treated as files, never sent as a question, only when ALL of it is
    /// one to 20 lines and EVERY line, alone, is an absolute path ("/...", "~/...", optionally quoted, or with Terminal's
    /// backslash-escaped spaces) or a file:// URL, naming a regular file that exists on this Mac right now. That is
    /// exactly the shape a file drop or a "Copy as Pathname" leaves behind. Why so narrow: a question that MENTIONS a path
    /// ("What does /etc/hosts do?") has other words on its line, so it is a question; "/" alone, a folder, and a path that
    /// does not exist (a typo, a slash command, a path on another machine) are never files here, so they still go as
    /// questions. Nil means: this is a question.
    static func localFiles(in text: String, isFile: (String) -> Bool, home: String = NSHomeDirectory()) -> [URL]? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 20 else { return nil }
        var urls: [URL] = []
        for line in lines {
            guard let path = candidates(line, home: home).first(where: { $0 != "/" && isFile($0) }) else { return nil }
            urls.append(URL(fileURLWithPath: path))
        }
        return urls
    }

    /// The paths one line could mean: as written, and with Terminal's `\ ` escapes undone.
    static func candidates(_ line: String, home: String) -> [String] {
        var value = line
        if value.count >= 2, let first = value.first, first == "'" || first == "\"", value.last == first { value = String(value.dropFirst().dropLast()) }
        if value.lowercased().hasPrefix("file://") {
            var rest = String(value.dropFirst(7))
            if rest.lowercased().hasPrefix("localhost/") { rest = String(rest.dropFirst(9)) }
            guard rest.hasPrefix("/"), let decoded = rest.removingPercentEncoding else { return [] }
            return [decoded]
        }
        if value.hasPrefix("~/") { value = home + String(value.dropFirst(1)) }
        guard value.hasPrefix("/") else { return [] }
        let unescaped = value.replacingOccurrences(of: "\\ ", with: " ")
        return unescaped == value ? [value] : [value, unescaped]
    }

    /// The live check: a regular file (or a link to one), never a folder.
    static func regularFileExists(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
    }
}

extension MeetingAskText {
    /// The line the Ask panel shows after a drop or a paste on it. names: the files that landed in this meeting's Files.
    static func attached(_ names: [String], pathOnly: Bool = false) -> String {
        let lead = pathOnly ? "That question was only a file path, so it was not sent. " : ""
        switch names.count {
        case 0: return lead + "Nothing new was attached to this meeting."
        case 1: return lead + "Attached \(names[0]) to this meeting. Ask about it when it shows Ready."
        default: return lead + "Attached \(names.count) files to this meeting. Ask about them when they show Ready."
        }
    }
    static let attachUnavailable = "Files can't be added to this meeting from here right now, so nothing was attached."
}
