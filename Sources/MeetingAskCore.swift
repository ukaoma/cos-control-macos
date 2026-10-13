import Foundation
import Combine
import CryptoKit

enum MeetingAskHistoryState {
    static func emptyText(loading: Bool, failed: Bool, live: Bool) -> String {
        if loading { return "Loading saved questions…" }
        if failed { return "Saved questions could not be checked. Refresh to retry." }
        return live ? "No questions yet. Answers are saved with this recording." : "No saved questions found for this recording."
    }
}

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
    var capabilities: MeetingAskFeatureCapabilities?
}
/// Where meeting assistance stands with the server, as the last config read found it (0.5.282).
enum MeetingAskReach: Equatable, Sendable {
    /// No config read has finished yet.
    case checking
    case online
    /// The server or the helper could not be reached.
    case offline
    /// The server answered but does not speak this app's protocol (an older server, or this app is older).
    case outdated
}

/// 0.5.282 (Miles, 2026-10-10, live test): "There should be a way to switch the model from within this chat dialog with
/// the live meeting." The Meeting assistant model is ONE server setting (PUT /api/meeting-ask/config, the helper's
/// `configure` operation). Settings and the Live COS Ask panel draw the same control (`MeetingAskModelControl`) and both
/// change the model through `MeetingAskStore.selectModel`, which runs that one `configure` and then re-reads the config.
/// Neither keeps a copy of the choice, so they cannot disagree. A question already sent keeps the model it was asked
/// with: its request carries that model and the server pins it. Pure: Tests/MeetingAskChecks.swift.
enum MeetingAskModelPicker {
    /// One row of the model list. `id` is `engine:model`, the value both controls bind to.
    struct Row: Equatable, Sendable {
        let id: String
        let title: String
        /// Why a row cannot be chosen; nil when it can.
        let note: String?
        let enabled: Bool
    }

    static func id(_ model: MeetingAskModel) -> String { model.engine + ":" + model.model }
    static func selectedID(_ config: MeetingAskConfig) -> String { id(config.selected) }

    /// Every model the server lists, in its order, titled as Settings has always titled them ("Claude · haiku"). An
    /// unavailable model is listed and cannot be chosen; its note says why. A selection the server no longer lists still
    /// leads the list, so the control always shows the model in use.
    static func rows(_ config: MeetingAskConfig) -> [Row] {
        var rows = config.models.map { option in
            Row(id: option.id, title: option.choice.label, note: option.available ? nil : reason(option.reason), enabled: option.available)
        }
        if !rows.contains(where: { $0.id == selectedID(config) }) {
            rows.insert(Row(id: selectedID(config), title: config.selected.label, note: "No longer offered", enabled: false), at: 0)
        }
        return rows
    }

    /// A server reason in words. The server sends codes ("provider_unavailable") or a provider's own detail.
    static func reason(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "", "meeting_adapter_not_qualified": return "Not qualified for meeting assistance"
        case "provider_unavailable": return "Not connected"
        case "binary not_found": return "Not found on this Mac"
        default:
            if value.hasPrefix("binary ") { return "Not usable on this Mac" }
            let words = String(value.replacingOccurrences(of: "_", with: " ").prefix(80))
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// Why neither control can change the model right now, or nil when it can. While a change is with the server, both
    /// lock until it answers, so a second pick can never race the first.
    static func lock(config: MeetingAskConfig?, reach: MeetingAskReach, pending: MeetingAskModel?) -> String? {
        if let pending { return "Switching to \(pending.label)…" }
        switch reach {
        case .checking: return "Checking connected models…"
        case .offline: return "Reconnect COS to switch models."
        case .outdated: return "Update COS to switch models."
        case .online: return config == nil ? "Checking connected models…" : nil
        }
    }

    /// The model a pick of `id` switches to, or nil when the pick changes nothing: the controls are locked, the id is
    /// the model already in use, or it names a model the server does not offer as available.
    static func change(to id: String, config: MeetingAskConfig?, reach: MeetingAskReach, pending: MeetingAskModel?) -> MeetingAskModel? {
        guard lock(config: config, reach: reach, pending: pending) == nil, let config, id != selectedID(config),
              let option = config.models.first(where: { $0.id == id && $0.available }) else { return nil }
        return option.choice
    }
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
    /// 0.5.283: the answer in labeled sections (server 6.71.0). Older servers omit it; `answer` then carries the labels.
    var sections: MeetingAskSectionList?
    var sources: [LiveAskSource]
    var notices: [String]
    var throughMs: Int
    var files: [MeetingAskFile]
    var error: String?
    var retryOf: String?
    var id: String { requestId }
    var terminal: Bool { !["pending", "running"].contains(status) }
}
/// One labeled part of an answer (server 6.71.0): "So what", "Decided", "You owe" and so on, with the ids it cites.
/// Lenient: a missing or wrong-typed field reads as empty, so one bad section can never drop the exchange it sits in.
struct MeetingAskSection: Codable, Equatable, Sendable {
    var label: String
    var text: String
    var sources: [String]
    init(label: String, text: String, sources: [String] = []) { self.label = label; self.text = text; self.sources = sources }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        label = (try? values.decode(String.self, forKey: .label)) ?? ""
        text = (try? values.decode(String.self, forKey: .text)) ?? ""
        sources = (try? values.decode([String].self, forKey: .sources)) ?? []
    }
}
/// `sections` as the server sends it. Anything that is not an array of sections reads as no sections, and an entry
/// that is not a section is skipped, so a malformed field falls back to `answer` instead of failing the whole history.
struct MeetingAskSectionList: Codable, Equatable, Sendable {
    var items: [MeetingAskSection]
    init(_ items: [MeetingAskSection]) { self.items = items }
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }
    init(from decoder: Decoder) throws {
        items = []
        guard var list = try? decoder.unkeyedContainer() else { return }
        while !list.isAtEnd {
            if let section = try? list.decode(MeetingAskSection.self) { items.append(section) } else { _ = try list.decode(Skip.self) }
        }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        try value.encode(items)
    }
}

/// 0.5.283 (Miles, 2026-10-11, the Meeting Ask polish round): an answer is drawn as bold-label rows, So what first. The
/// rows come from the server's `sections` (6.71.0), else from the `**Label:** text` lines 6.71.0 also writes into
/// `answer`, else there are none and the answer is drawn as plain Markdown, as 0.5.282 drew it. Pure:
/// Tests/MeetingAskChecks.swift.
enum MeetingAskAnswerRows {
    struct Row: Equatable, Sendable {
        let label: String
        let text: String
    }

    /// Every label the server's contract allows (catch_up, summary, actions, questions, ask). Only these start a row
    /// when `answer` is read, so a bolded word in an older server's free Markdown is never taken for a label.
    static let known = ["So what", "Decided", "Open", "You owe", "Next", "Covered", "Others owe", "Unowned", "Proposed", "Ask", "Details", "Confidence"]

    static func rows(sections: [MeetingAskSection]?, answer: String?) -> [Row]? {
        let given = (sections ?? []).compactMap { section -> Row? in
            let label = section.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = section.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty || text.isEmpty ? nil : Row(label: label, text: text)
        }
        if !given.isEmpty { return soWhatFirst(given) }
        return answer.flatMap(parse)
    }

    /// `**Label:** text` lines, one row each; an unlabeled line joins the row above it. Nil, so the answer stays plain
    /// Markdown, unless the first line with words is a known label. Server 6.71.0 puts a blank line between rows, and a
    /// row can hold a whole free-form reply: blank lines between rows are dropped, blank lines inside a row stay as one
    /// paragraph break, and a continuation line keeps its indent (nested lists).
    static func parse(_ answer: String) -> [Row]? {
        var rows: [(label: String, lines: [String])] = []
        var gap = false
        for raw in answer.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { gap = true; continue }
            if let (label, rest) = labelLine(line) {
                rows.append((label, rest.isEmpty ? [] : [rest]))
            } else {
                guard !rows.isEmpty else { return nil }
                if gap, !rows[rows.count - 1].lines.isEmpty { rows[rows.count - 1].lines.append("") }
                var kept = raw
                while kept.last?.isWhitespace == true { kept.removeLast() }
                rows[rows.count - 1].lines.append(kept)
            }
            gap = false
        }
        let built = rows.compactMap { row -> Row? in
            let text = row.lines.joined(separator: "\n")
            return text.isEmpty ? nil : Row(label: row.label, text: text)
        }
        return built.isEmpty ? nil : soWhatFirst(built)
    }

    /// A row's words split for drawing. `lead` follows the label on its line; `rest`, the paragraphs after the first
    /// blank line, is drawn under it as Markdown blocks (lists, headings, more paragraphs). A row that opens with a block
    /// (a list, a heading, a quote, a fence) has no lead, so that block is never flattened into the label's line.
    static func split(_ text: String) -> (lead: String, rest: String?) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = body.drop(while: { $0 == " " })
        let block = ["- ", "* ", "+ ", "#", "> ", "```", "~~~", "|"].contains { first.hasPrefix($0) }
            || first.range(of: #"^\d{1,3}[.)] "#, options: .regularExpression) != nil
        if block { return ("", body.isEmpty ? nil : body) }
        guard let gap = body.range(of: #"\n[ \t]*\n"#, options: .regularExpression) else { return (body, nil) }
        let rest = body[gap.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(body[..<gap.lowerBound]), rest.isEmpty ? nil : rest)
    }

    /// `**So what:** words` (or `**So what**: words`) with a known label, as (that label, words); nil for any other line.
    static func labelLine(_ line: String) -> (String, String)? {
        guard line.hasPrefix("**") else { return nil }
        let body = line.dropFirst(2)
        for close in [":**", "**:"] {
            guard let end = body.range(of: close) else { continue }
            let name = body[..<end.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let label = known.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            return (label, String(body[end.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// So what leads; every other row keeps its place.
    static func soWhatFirst(_ rows: [Row]) -> [Row] {
        rows.filter { $0.label == "So what" } + rows.filter { $0.label != "So what" }
    }

    /// A row's words as drawn: a Markdown list marker at the start of a line becomes a bullet.
    static func display(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            for marker in ["- ", "* "] where line.hasPrefix(marker) { return "\u{2022} " + line.dropFirst(marker.count) }
            return line
        }.joined(separator: "\n")
    }
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

/// 0.5.282: the file observer fires for every meeting on any file change, so 0.5.281 re-sent every meeting's list
/// each time one file changed. A list is sent when it was never sent to this server or differs from what was sent.
enum MeetingAskFileSync {
    static func needsRegistration(published: [MeetingAskFile]?, current: [MeetingAskFile]) -> Bool {
        guard let published else { return true }
        return published != current
    }
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

/// Request-local citation URLs are presentation only; source resolution stays in the owning exchange.
enum MeetingAskCitationText {
    static func markdown(_ text: String, ids: Set<String>) -> String {
        let regex = try! NSRegularExpression(pattern: #"\[([THFW]\d+)\]"#)
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result), let idRange = Range(match.range(at: 1), in: text) else { continue }
            let id = String(text[idRange])
            if ids.contains(id) { result.replaceSubrange(range, with: "[" + id + "](cos-ask-citation:" + id + ")") }
        }
        return result
    }
    static func attributed(_ text: String, ids: Set<String>) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        var value = (try? AttributedString(markdown: markdown(text, ids: ids), options: options)) ?? AttributedString(text)
        var refused: [Range<AttributedString.Index>] = []
        for run in value.runs {
            guard let url = run.link else { continue }
            let web = ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false
            if id(url, ids: ids) == nil && !web { refused.append(run.range) }
        }
        for range in refused { value[range].link = nil }
        return value
    }
    static func id(_ url: URL, ids: Set<String>) -> String? {
        guard url.scheme == "cos-ask-citation" else { return nil }
        let id = url.absoluteString.dropFirst("cos-ask-citation:".count)
        return ids.contains(String(id)) ? String(id) : nil
    }
}

/// Canonical server evidence for an ended capture, never a fabricated live feed.
struct MeetingAskSnapshot: Codable, Sendable {
    var turns: [MeetingAskTurn]
    var elapsedMs: Int
    var notices: [String]
    var ended: Bool?
    var source: String?
    var validSaved: Bool {
        ended == true && elapsedMs >= 0 && !turns.isEmpty
            && Set(turns.map(\.id)).count == turns.count
            && turns.allSatisfy { $0.id >= 0 && $0.elapsedMs >= 0 && $0.elapsedMs <= elapsedMs && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct MeetingAskFeatureCapabilities: Codable, Sendable { var followUpReview: Bool?; var factCheck: Bool? }
struct MeetingAskSourceHealth: Decodable, Sendable {
    struct Availability: Decodable, Sendable { var available: Bool; var total: Int }
    var memory: Availability
    var threads: Availability
}
struct MeetingAskOrientationReply: Decodable, Sendable {
    struct Orientation: Decodable, Sendable { var domain: String? }
    var orientation: Orientation
}
struct MeetingAskFollowUpReply: Decodable, Sendable {
    struct Item: Decodable, Sendable { var id: String; var status: String }
    var ok: Bool
    var item: Item
}

// MARK: Home city (server 6.71.13)
//
// Where a Meeting Ask fact check starts when the question leaves it implicit ("flying from here to Kansas City").
// The server owns the value and its validation (GET/PUT /api/home-area through the helper's `home-area` and
// `set-home-area`); this store only shows what the server answered. A 404 is a server from before the route, so
// the setting is hidden rather than shown as an error. A 400 is the server refusing the label, and its sentence
// shows under the field. A blank field sends "" so the server clears the city and uses the phone's area again.
struct HomeAreaEffective: Equatable, Sendable { var text: String; var source: String }

enum HomeArea {
    static let placeholder = "Austin, TX"
    static let caption = "Used only when a fact check needs a starting point. City and state, no street address. Leave blank to use your phone's area."
    /// What the helper forwards as the PUT body. Blank (or spaces only) is "", the server's clear.
    static func payload(_ draft: String) -> [String: String] {
        ["homeCity": normalized(draft)]
    }
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    /// The line under the field once the server has answered.
    static func effectiveLine(_ effective: HomeAreaEffective?) -> String {
        guard let effective, !effective.text.isEmpty else { return "No starting point is set yet." }
        return effective.source == "profile"
            ? "Fact checks start from \(effective.text)"
            : "Fact checks use your phone's area: \(effective.text)"
    }
}

@MainActor
final class HomeAreaStore: ObservableObject {
    enum Availability: Equatable, Sendable { case unknown, supported, unsupported }
    /// The helper call: (arguments, stdin) to its JSON answer. ControllerModel.runHelper in the app, a fake in checks.
    typealias Run = @MainActor ([String], Data?) async throws -> HelperResponse
    @Published private(set) var availability = Availability.unknown
    /// The city the server holds, nil when none is set.
    @Published private(set) var saved: String?
    @Published private(set) var effective: HomeAreaEffective?
    /// The server's 400 sentence, or why the call did not reach it. Cleared by the next edit.
    @Published private(set) var error: String?
    @Published private(set) var saving = false
    @Published var draft = "" { didSet { if draft != oldValue { error = nil } } }
    /// False before the first answer, on an older server (404), and while the server cannot be reached.
    var visible: Bool { availability == .supported }
    /// Save does nothing when the field already says what the server holds.
    var changed: Bool { HomeArea.normalized(draft) != (saved ?? "") }
    var effectiveLine: String { HomeArea.effectiveLine(effective) }

    func load(_ run: Run) async {
        do { apply(try await run(["home-area"], nil), refill: draft == (saved ?? "")) }
        catch { if availability == .supported { self.error = error.localizedDescription } }
    }

    func save(_ run: Run) async {
        guard availability == .supported, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let data = try JSONSerialization.data(withJSONObject: HomeArea.payload(draft), options: [.sortedKeys])
            apply(try await run(["set-home-area"], data), refill: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ response: HelperResponse, refill: Bool) {
        switch response.details["httpStatus"]?.int {
        case 404:
            availability = .unsupported
            error = nil
        case 400:
            availability = .supported
            error = response.details["error"]?.string ?? response.message
        case 200:
            availability = .supported
            let city = response.details["homeCity"]?.string
            saved = (city?.isEmpty ?? true) ? nil : city
            let object = response.details["effective"]?.object
            if let text = object?["text"]?.string, !text.isEmpty {
                effective = HomeAreaEffective(text: text, source: object?["source"]?.string ?? "")
            } else {
                effective = nil
            }
            if refill { draft = saved ?? "" }
            error = nil
        default:
            error = response.message
        }
    }
}

// MARK: Transcription switcher (server 6.72.0)
//
// Which speech-to-text engines the glasses server runs: the Preview model for live chunks, the HQ model for a saved
// meeting, an optional second opinion with the resolver that refines HQ from it, and two Advanced front-end choices.
// The server owns every choice, its availability and its refusal sentences (GET/PUT /api/stt-settings through the
// helper's `stt-settings` and `set-stt-settings`); this store only shows what the server answered. A 404 is a server
// from before the route, so the card is hidden rather than shown as an error. A 400 is the server refusing a choice,
// and its sentence shows inline. "Install Parakeet" POSTs the install route (`install-parakeet`) and then polls GET,
// whose `parakeet` object is the progress. Control never starts it while a recording is live.
struct SttOption: Equatable, Sendable {
    var id: String
    var label: String?
    var available: Bool
    var experimental: Bool
    var note: String?
}

struct SttChoice: Equatable, Sendable {
    var selected: String
    var options: [SttOption]
    /// 6.72.0: the engine actually running (Whisper Turbo while a selected Parakeet warms up). nil when not reported.
    var effective: String?
    init(selected: String, options: [SttOption], effective: String? = nil) { self.selected = selected; self.options = options; self.effective = effective }
    init?(_ value: JSONValue?) {
        guard let object = value?.object, let selected = object["selected"]?.string, let rows = object["options"]?.array else { return nil }
        self.selected = selected
        effective = object["effective"]?.string
        options = rows.compactMap { row in
            guard let row = row.object, let id = row["id"]?.string, !id.isEmpty else { return nil }
            return SttOption(id: id, label: row["label"]?.string, available: row["available"]?.bool ?? true,
                             experimental: row["experimental"]?.bool ?? false, note: row["note"]?.string)
        }
    }
}

struct SttInstallProgress: Equatable, Sendable {
    /// idle, downloading, verifying, installed or failed.
    var state: String
    var bytesDone: Int
    var bytesTotal: Int
    var error: String?
}

struct SttParakeet: Equatable, Sendable {
    var installed: Bool
    var installable: Bool
    var version: String?
    /// Before 6.72.0's `progress`, the only progress signal. Kept as the fallback.
    var bytes: Int
    var progress: SttInstallProgress? = nil
    /// cold, warming, warm or failed: whether Parakeet is ready to run previews.
    var warmPreview: String? = nil
    /// The server's plain sentence about Parakeet, shown under the Preview picker while Parakeet is selected there.
    var note: String? = nil
    /// The server is downloading or verifying right now.
    var serverInstalling: Bool { progress?.state == "downloading" || progress?.state == "verifying" }
    var failed: Bool { !installed && progress?.state == "failed" }
    var done: Bool { installed || progress?.state == "installed" }
}

struct SttSettings: Equatable, Sendable {
    var preview: SttChoice
    var hq: SttChoice
    var secondOpinion: SttChoice
    var frontEnd: SttChoice
    var quietGate: SttChoice
    var resolverEnabled: Bool
    /// 6.72.0: false when the resolver is on but has nothing to refine with (the second opinion is effectively off).
    var resolverEffective: Bool?
    var parakeet: SttParakeet
    var appliesPreview: String?
    var appliesHQ: String?

    /// The helper's `details.settings`, which is already the contract's GET shape with its keys whitelisted.
    init?(_ value: JSONValue?) {
        guard let object = value?.object,
              let preview = SttChoice(object["preview"]), let hq = SttChoice(object["hq"]),
              let second = SttChoice(object["secondOpinion"]), let frontEnd = SttChoice(object["frontEnd"]),
              let quiet = SttChoice(object["quietGate"]), let resolver = object["resolver"]?.object?["enabled"]?.bool else { return nil }
        self.preview = preview; self.hq = hq; secondOpinion = second; self.frontEnd = frontEnd; quietGate = quiet
        resolverEnabled = resolver
        resolverEffective = object["resolver"]?.object?["effective"]?.bool
        let parakeet = object["parakeet"]?.object ?? [:]
        var progress: SttInstallProgress?
        if let row = parakeet["progress"]?.object, let state = row["state"]?.string {
            progress = SttInstallProgress(state: state, bytesDone: max(0, row["bytesDone"]?.int ?? 0), bytesTotal: max(0, row["bytesTotal"]?.int ?? 0),
                                          error: row["error"]?.string.flatMap { $0.isEmpty ? nil : $0 })
        }
        self.parakeet = SttParakeet(installed: parakeet["installed"]?.bool ?? false, installable: parakeet["installable"]?.bool ?? false,
                                    version: parakeet["version"]?.string, bytes: max(0, parakeet["bytes"]?.int ?? 0), progress: progress,
                                    warmPreview: parakeet["warm"]?.object?["preview"]?.string,
                                    note: parakeet["note"]?.string.flatMap { $0.isEmpty ? nil : $0 })
        let applies = object["appliesTo"]?.object ?? [:]
        appliesPreview = applies["preview"]?.string
        appliesHQ = applies["hq"]?.string
    }
}

/// One row the card's pickers draw.
struct SttPickerRow: Equatable, Sendable { var id: String; var title: String; var note: String?; var enabled: Bool }

enum Transcription {
    /// Option keys the card sends, the same names the server's PUT takes.
    enum Key: String, CaseIterable, Sendable { case preview, hq, secondOpinion, frontEnd, quietGate }
    /// Control's own words for the ids the plan fixes, used only when the server sends no label.
    static let fallbackLabels: [String: String] = [
        "off": "Off", "highpass": "Highpass only", "full": "Full chain", "silero": "Speech detector", "rms": "Volume threshold",
    ]
    static func rows(_ choice: SttChoice) -> [SttPickerRow] {
        var rows = choice.options.map { option in
            let label = option.label.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackLabels[option.id] ?? option.id
            let said = option.note.flatMap { $0.isEmpty ? nil : $0 }
            // Only an option that cannot be chosen carries its note: the dropdown face shows the selection's note
            // too, and a note there truncated the model name in the 390 pt panel (render, 2026-10-13).
            let note = option.available ? (option.experimental ? "Experimental" : nil) : (said ?? "Not available")
            return SttPickerRow(id: option.id, title: label, note: note, enabled: option.available)
        }
        // The selection always has a row, even when the server forgot to list it.
        if !rows.contains(where: { $0.id == choice.selected }) {
            rows.insert(SttPickerRow(id: choice.selected, title: fallbackLabels[choice.selected] ?? choice.selected, note: nil, enabled: true), at: 0)
        }
        return rows
    }
    /// The one plain line under the pickers, from appliesTo.
    static func appliesLine(_ settings: SttSettings) -> String {
        let preview = settings.appliesPreview.flatMap { $0.isEmpty ? nil : $0 } ?? "next live chunk"
        let hq = settings.appliesHQ.flatMap { $0.isEmpty ? nil : $0 } ?? "next saved meeting"
        return "Preview changes apply to the \(preview). HQ changes apply to the \(hq)."
    }
    static func title(_ choice: SttChoice, _ id: String) -> String {
        rows(choice).first { $0.id == id }?.title ?? fallbackLabels[id] ?? id
    }
    /// One quiet line when the engine running is not the one chosen, e.g. while Parakeet warms up. nil when they match.
    static func effectiveLine(_ choice: SttChoice) -> String? {
        guard let effective = choice.effective, !effective.isEmpty, effective != choice.selected else { return nil }
        let chosen = title(choice, choice.selected)
        return effective == "off" ? "No second opinion until \(chosen) is ready." : "Using \(title(choice, effective)) until \(chosen) is ready."
    }
    /// What the card shows under the Preview picker: the effective line, then the server's Parakeet note (or its warm
    /// state when there is no note) while Parakeet is the selected preview. One line, nothing said twice.
    static func previewLine(_ settings: SttSettings) -> String? {
        var parts: [String] = []
        if let line = effectiveLine(settings.preview) { parts.append(line) }
        if settings.preview.selected == "parakeet" {
            let warm: String? = switch settings.parakeet.warmPreview {
            case "warming": "Parakeet is warming up."
            case "failed": "Parakeet could not start for previews."
            default: nil
            }
            if let said = settings.parakeet.note ?? warm, !parts.contains(said) { parts.append(said) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
    /// The resolver switch stays usable (it is the setting); this says why it is not refining right now.
    static func resolverInactiveLine(_ settings: SttSettings) -> String? {
        guard settings.resolverEnabled, settings.resolverEffective == false else { return nil }
        let second = settings.secondOpinion
        if second.selected == "off" { return "Not refining: Second opinion is off." }
        if let effective = second.effective, effective != second.selected { return "Not refining until \(title(second, second.selected)) is ready." }
        return "Not refining right now."
    }
    static func megabytes(_ bytes: Int) -> String {
        let value = Double(bytes) / 1_000_000
        return value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))
    }
    /// The progress line while the server installs: X of Y MB, Verifying, or the older bytes-so-far fallback.
    static func progressLine(_ parakeet: SttParakeet) -> String {
        if let progress = parakeet.progress {
            if progress.state == "verifying" { return "Verifying the Parakeet download." }
            if progress.bytesTotal > 0 { return "Installing Parakeet. \(megabytes(progress.bytesDone)) of \(megabytes(progress.bytesTotal)) MB." }
            if progress.bytesDone > 0 { return installingLine(bytes: progress.bytesDone) }
        }
        return installingLine(bytes: parakeet.bytes)
    }
    /// The server's plain reason when the install failed (for example the FluidAudio command line tool is missing).
    static func failureLine(_ parakeet: SttParakeet) -> String? {
        guard parakeet.failed else { return nil }
        return parakeet.progress?.error ?? "The Parakeet install did not finish. Try again."
    }
    static let installCaption = "Parakeet runs on this Mac as the second opinion. The download is checked before it is installed."
    static let recordingHold = "Install Parakeet after the recording ends."
    static func installingLine(bytes: Int) -> String {
        bytes > 0 ? "Installing Parakeet. \(megabytes(bytes)) MB so far." : "Installing Parakeet."
    }
    static func installedLine(_ parakeet: SttParakeet) -> String? {
        guard parakeet.installed else { return nil }
        guard let version = parakeet.version, !version.isEmpty else { return "Parakeet is installed." }
        return "Parakeet \(version) is installed."
    }
    static let installTimedOut = "The Parakeet install is taking longer than expected. Check again in a few minutes."
    /// 15 minutes at one check every 2 seconds: a backstop only, the server's installed or failed state ends the poll.
    static let installPollLimit = 450
    static let installPollNanoseconds: UInt64 = 2_000_000_000
}

@MainActor
final class TranscriptionSettingsStore: ObservableObject {
    enum Availability: Equatable, Sendable { case unknown, supported, unsupported }
    /// The helper call: (arguments, stdin) to its JSON answer. ControllerModel.runHelper in the app, a fake in checks.
    typealias Run = @MainActor ([String], Data?) async throws -> HelperResponse
    typealias Pause = @MainActor (UInt64) async -> Void
    @Published private(set) var availability = Availability.unknown
    @Published private(set) var settings: SttSettings?
    /// The server's 400 sentence, or why the call did not reach it. Cleared by the next successful answer.
    @Published private(set) var error: String?
    /// The change on its way to the server, so its control can wait for the answer.
    @Published private(set) var pending: String?
    @Published private(set) var installing = false
    /// False before the first answer, on an older server (404), and while no settings have been read.
    var visible: Bool { availability == .supported && settings != nil }

    /// The Install Parakeet button: only when it is missing, the server can install it, nothing is in flight (here or
    /// on the server), and no recording is live. After a failed install it is offered again.
    func offersInstall(recording: Bool) -> Bool {
        guard visible, !installing, !recording, let parakeet = settings?.parakeet else { return false }
        return !parakeet.installed && parakeet.installable && !parakeet.serverInstalling
    }
    /// The card shows progress while this store polls or while the server says it is downloading or verifying.
    var showsProgress: Bool { installing || settings?.parakeet.serverInstalling == true }

    /// A read. When the server is already installing (started from another open of the panel), it follows that
    /// install the same way the button does, until installed or failed.
    func load(_ run: Run, pause: Pause = { try? await Task.sleep(nanoseconds: $0) }) async {
        do { apply(try await run(["stt-settings"], nil)) }
        catch { if availability == .supported { self.error = error.localizedDescription }; return }
        guard visible, !installing, settings?.parakeet.serverInstalling == true else { return }
        installing = true
        defer { installing = false }
        do { try await follow(run, pause: pause) } catch { self.error = error.localizedDescription }
    }

    /// One partial PUT: an option id for a picker, a bool for the resolver.
    func set(_ key: String, _ value: JSONValue, run: Run) async {
        guard visible, pending == nil else { return }
        let payload: Any
        switch value {
        case .string(let id): payload = id
        case .bool(let on): payload = on
        default: return
        }
        pending = key
        defer { pending = nil }
        do {
            let data = try JSONSerialization.data(withJSONObject: [key: payload], options: [.sortedKeys])
            apply(try await run(["set-stt-settings"], data))
        } catch {
            self.error = error.localizedDescription
        }
    }

    func install(_ run: Run, recording: Bool, pause: Pause = { try? await Task.sleep(nanoseconds: $0) }) async {
        guard offersInstall(recording: recording) else { return }
        installing = true
        defer { installing = false }
        error = nil
        do {
            let started = try await run(["install-parakeet"], nil)
            switch started.details["httpStatus"]?.int {
            case 200, 202:
                if let settings = SttSettings(started.details["settings"]) { self.settings = settings }
                // 200 {started:false}: already installed, nothing to follow.
                if started.details["started"]?.bool == false { return }
            case 404:
                error = "This server cannot install Parakeet."; return
            default:
                error = started.details["error"]?.string ?? started.message; return
            }
            try await follow(run, pause: pause)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// GET every 2 s until the server says installed or failed. The 15 minute limit is only a backstop.
    private func follow(_ run: Run, pause: Pause) async throws {
        for _ in 0..<Transcription.installPollLimit {
            if let parakeet = settings?.parakeet, parakeet.done || parakeet.failed { return }
            await pause(Transcription.installPollNanoseconds)
            // The panel closed (its .task was cancelled): stop; the next open reads the state again.
            if Task.isCancelled { return }
            apply(try await run(["stt-settings"], nil))
            if availability != .supported || error != nil { return }
        }
        if let parakeet = settings?.parakeet, !parakeet.done, !parakeet.failed { error = Transcription.installTimedOut }
    }

    private func apply(_ response: HelperResponse) {
        switch response.details["httpStatus"]?.int {
        case 404:
            availability = .unsupported
            settings = nil
            error = nil
        case 400, 409:
            availability = .supported
            error = response.details["error"]?.string ?? response.message
        case 200, 202:
            guard let settings = SttSettings(response.details["settings"]) else {
                error = "The server's transcription settings were not readable."; return
            }
            availability = .supported
            self.settings = settings
            error = nil
        default:
            error = response.message
        }
    }
}
