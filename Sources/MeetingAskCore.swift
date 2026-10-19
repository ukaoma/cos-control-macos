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
    /// 0.5.321: how long the server took to answer (server 6.76.0 `timings.totalMs`). Older servers omit it.
    var timings: MeetingAskTimings? = nil
    var id: String { requestId }
    var terminal: Bool { !["pending", "running"].contains(status) }
}
/// `timings` as the server sends it. Lenient: anything that is not an object with a finite, non-negative `totalMs`
/// reads as no timing, so a malformed field never drops the exchange it sits in.
struct MeetingAskTimings: Codable, Equatable, Sendable {
    var totalMs: Double?
    init(totalMs: Double?) { self.totalMs = totalMs }
    init(from decoder: Decoder) throws {
        let values = try? decoder.container(keyedBy: CodingKeys.self)
        let raw = values.flatMap { try? $0.decode(Double.self, forKey: .totalMs) }
        totalMs = raw.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
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
            // 0.5.321: `throughMs` is where in the meeting the answer reached, not how long it took (Queen read
            // "through 210666 ms" as a 3.5 minute wait). The meeting position prints as the Ask panel does, "Through 3:30";
            // the answer's own time prints only when the server measured it.
            var part = "## \(namespace) · \(exchange.question)\n\(answer)\n" + exportStatusLine(exchange)
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
    /// "Model: Haiku · Through 3:30 · completed · Answer time: 6.4 s" (the answer time only when the server sent it).
    static func exportStatusLine(_ exchange: MeetingAskExchange) -> String {
        let through = LiveTranscript.stamp(exchange.throughMs, hours: exchange.throughMs >= 3_600_000)
        var line = "Model: \(exchange.model ?? exchange.selectedModel.label) · Through \(through) · \(exchange.status)"
        if let total = exchange.timings?.totalMs { line += " · Answer time: " + String(format: "%.1f s", total / 1000) }
        return line
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

// MARK: Live cues (server 6.76.2)
//
// 0.5.322 (Miles, 2026-10-17): live cues v2 on or off from Settings, so nobody edits ~/.cos-glasses/.env by hand. The
// server owns the switch, where it came from and whether cues can run (GET and POST /api/live-cues/v2/settings through
// the helper's `live-cues-settings`, `--set on|off` to change it); this store only words what the server answered. The
// helper emits every answer as ok with `transport` (`answered`, `unavailable` when nothing answered, `no_token`) and
// `httpStatus`, so each failure has its own words here. A 404 is a server from before the route ("Needs server 6.76.2"),
// a 409 `env_forced` is the server's environment holding it on. Nothing is shown as current that the last read did not
// say: every read starts at Checking, and an unreachable server replaces whatever was shown before.
struct LiveCuesCapability: Equatable, Sendable {
    var available: Bool
    var reason: String?
    var model: String?
    var memory: String?
    /// Which decision model gates and judges the cues: `jev` or `subq` (server 6.76.2). nil from a server that does not say.
    var decisionProvider: String? = nil
}

struct LiveCuesSettings: Equatable, Sendable {
    var enabled: Bool
    /// `env` (the server's environment decides; Control cannot change it), `setting` or `default`.
    var source: String
    var capability: LiveCuesCapability
    var locked: Bool { source == "env" }
}

enum LiveCues {
    enum State: Equatable, Sendable {
        case checking
        case loaded(LiveCuesSettings)
        /// 404: a server from before the route.
        case olderServer
        /// Nothing answered.
        case unreachable
        /// 401 or 403, or no pairing token on this Mac.
        case reconnect
        /// The helper itself failed (it never says why the server did not answer; its own error is not the server's).
        case notChecked
        /// A 200 without the contract's shape.
        case unreadable
        case failed(status: Int)
    }
    enum Action: Equatable, Sendable { case none, addDecisionKey, checkAgain }

    static let title = "Live cues"
    static let minimumServer = "6.76.2"
    /// The panel scrolls here and opens the Decision models disclosure, where the Jev and SubQ key fields are (ControlPanel).
    static let decisionKeysAnchor = "decision-models"
    static let addKeyLabel = "Add a Jev or SubQ key"
    static let checkAgainLabel = "Check again"
    static let glassesLine = "Cues also need Live Cues on in the glasses app."
    static let envOnPrefix = "Turned on in the server's environment."
    static let envForcedNote = "Turned on in the server's environment, so it cannot be turned off here."
    static let offLine = "Off. Turn it on to see cues on the glasses during a meeting."

    /// The helper's details to a state. nil (the helper failed) is `notChecked`.
    static func state(_ details: [String: JSONValue]?) -> State {
        guard let details else { return .notChecked }
        switch details["transport"]?.string {
        case "unavailable": return .unreachable
        case "no_token": return .reconnect
        case "answered": break
        default: return .notChecked
        }
        switch details["httpStatus"]?.int {
        case 200: return settings(details).map(State.loaded) ?? .unreadable
        case 404: return .olderServer
        case 401, 403: return .reconnect
        case let status?: return .failed(status: status)
        case nil: return .notChecked
        }
    }

    /// The contract's shape, or nil. `memory` and `reason` are read when sent and never required.
    static func settings(_ details: [String: JSONValue]) -> LiveCuesSettings? {
        guard let enabled = details["enabled"]?.bool, let source = details["source"]?.string,
              ["env", "setting", "default"].contains(source),
              let capability = details["capability"]?.object, let available = capability["available"]?.bool else { return nil }
        return LiveCuesSettings(enabled: enabled, source: source,
                                capability: LiveCuesCapability(available: available, reason: capability["reason"]?.string,
                                                               model: capability["model"]?.string, memory: capability["memory"]?.string,
                                                               decisionProvider: capability["decisionProvider"]?.string))
    }

    /// True for the 409 the server sends when its environment holds live cues on and the request turned them off.
    static func envForced(_ details: [String: JSONValue]?) -> Bool {
        details?["transport"]?.string == "answered" && details?["httpStatus"]?.int == 409 && details?["error"]?.string == "env_forced"
    }

    /// "claude-sonnet-5-5" reads "Sonnet 5.5"; an id in another shape reads as sent; nil when there is none.
    static func modelName(_ id: String?) -> String? {
        guard let id = id?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts[0] == "claude", let first = parts[1].first, first.isLetter else { return id }
        let family = first.uppercased() + parts[1].dropFirst()
        let version = parts.dropFirst(2).prefix { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        return version.isEmpty ? family : family + " " + version.joined(separator: ".")
    }

    /// The decision model by name, or nil when the server did not say (or said something else).
    static func providerName(_ provider: String?) -> String? {
        switch provider {
        case "jev": return "Jev"
        case "subq": return "SubQ"
        default: return nil
        }
    }

    /// What cues are built from, in words: "Cues use Claude Sonnet 5.5, SubQ, and your notes."
    static func usesLine(_ capability: LiveCuesCapability) -> String {
        var parts = [modelName(capability.model).map { "Claude " + $0 } ?? "Claude"]
        if let provider = providerName(capability.decisionProvider) { parts.append(provider) }
        switch capability.memory {
        case "notes": parts.append("your notes")
        case "cue_memory": parts.append("your meetings")
        case "none": parts.append("the conversation only")
        default: break
        }
        let list = parts.count < 3 ? parts.joined(separator: " and ") : parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
        return "Cues use \(list)."
    }

    /// The jev_ reasons name Jev; the decision_ reasons name the provider the server reports.
    private static func decisionName(_ reason: String?, _ provider: String?) -> String? {
        reason?.hasPrefix("jev_") == true ? "Jev" : providerName(provider)
    }

    /// Why cues cannot run, in words that say what to do. The server's `reason` codes (server 6.76.2). The decision-model
    /// reasons come in two spellings: `jev_` from 6.76.1 and older, provider-neutral `decision_` from 6.76.2.
    static func reasonLine(_ reason: String?, provider: String? = nil) -> String {
        switch reason {
        case "master_flag_off": return offLine
        case "api_key_in_env": return "An Anthropic API key is set in the server's environment; live cues stay off while it is there."
        case "jev_not_configured", "decision_not_configured": return "Needs a Jev or SubQ key."
        case "claude_not_found": return "Install the Claude command-line tool, then check again."
        case "budget_exhausted": return "This week's live cues limit is used up. Cues start again next week."
        case "jev_cap_reached", "decision_cap_reached":
            switch decisionName(reason, provider) {
            case "Jev": return "Today's Jev limit for live cues is used up. Cues start again tomorrow."
            case let name?: return "The \(name) limit for live cues is used up. Cues start again by themselves."
            case nil: return "The decision model's limit for live cues is used up. Cues start again by themselves."
            }
        case "jev_breaker_open", "decision_breaker_open":
            switch decisionName(reason, provider) {
            case "Jev": return "Jev failed several times in a row, so cues are paused for up to an hour. They start again by themselves."
            case let name?: return "\(name) failed several times in a row, so cues are paused for a while. They start again by themselves."
            case nil: return "The decision model failed several times in a row, so cues are paused for a while. They start again by themselves."
            }
        case "unavailable", nil: return "The server could not tell whether cues can run. Check again."
        default: return "Cues cannot run right now. Check again in a minute."
        }
    }

    /// The one status line under the switch.
    static func line(_ state: State, pending: Bool? = nil) -> String {
        if let pending { return pending ? "Turning live cues on…" : "Turning live cues off…" }
        switch state {
        case .checking: return "Checking live cues…"
        case .loaded(let settings):
            if !settings.enabled { return settings.locked ? "Turned off in the server's environment." : offLine }
            let capability = settings.capability
            if capability.reason == "master_flag_off", !capability.available { return offLine }
            let status = capability.available ? usesLine(capability) : reasonLine(capability.reason, provider: capability.decisionProvider)
            return settings.locked ? envOnPrefix + " " + status : (capability.available ? "On. " + status : status)
        case .olderServer: return "Needs server \(minimumServer). Update the server in Settings."
        case .unreachable: return "COS server unreachable. Live cues show here once it answers."
        case .reconnect: return "Reconnect COS Control to the server to change live cues."
        case .notChecked: return "COS Control could not check live cues. Check again."
        case .unreadable: return "The server's answer about live cues was not readable. Update the server in Settings."
        case .failed(let status): return "The server could not answer about live cues (HTTP \(status)). Check again."
        }
    }

    /// The one control a line asks for, if any: the Jev key field, or another read.
    static func action(_ state: State) -> Action {
        switch state {
        case .loaded(let settings):
            guard settings.enabled, !settings.capability.available else { return .none }
            switch settings.capability.reason {
            case "jev_not_configured", "decision_not_configured": return .addDecisionKey
            case "master_flag_off", "api_key_in_env", "budget_exhausted", "jev_cap_reached", "decision_cap_reached",
                 "jev_breaker_open", "decision_breaker_open": return .none
            default: return .checkAgain
            }
        case .unreachable, .notChecked, .failed: return .checkAgain
        case .checking, .olderServer, .reconnect, .unreadable: return .none
        }
    }

    /// Amber, not grey: the line says something stops cues.
    static func isProblem(_ state: State) -> Bool {
        switch state {
        case .loaded(let settings): return settings.enabled && !settings.capability.available && settings.capability.reason != "master_flag_off"
        case .checking: return false
        default: return true
        }
    }
}

@MainActor
final class LiveCuesStore: ObservableObject {
    /// The helper call: (arguments, stdin) to its JSON answer. ControllerModel.runHelper in the app, a fake in checks.
    typealias Run = @MainActor ([String], Data?) async throws -> HelperResponse
    @Published private(set) var state = LiveCues.State.checking
    /// The value a change is asking the server for, while it asks.
    @Published private(set) var pending: Bool?
    /// The 409 env_forced sentence; cleared by the next change.
    @Published private(set) var note: String?
    /// One call at a time: a read and a change never cross.
    @Published private(set) var busy = false

    var settings: LiveCuesSettings? { if case .loaded(let settings) = state { settings } else { nil } }
    var line: String { LiveCues.line(state, pending: pending) }
    var action: LiveCues.Action { pending == nil ? LiveCues.action(state) : .none }
    /// The switch moves only on a server that answered, set from Control's own setting, with nothing in flight.
    var switchEnabled: Bool { settings.map { !$0.locked } == true && !busy }

    func load(_ run: Run) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        state = .checking
        state = LiveCues.state(try? await run(["live-cues-settings"], nil).details)
    }

    func set(_ enabled: Bool, run: Run) async {
        guard !busy, let current = settings, !current.locked, current.enabled != enabled else { return }
        busy = true
        pending = enabled
        note = nil
        let answer = try? await run(["live-cues-settings", "--set", enabled ? "on" : "off"], nil)
        pending = nil
        busy = false
        if LiveCues.envForced(answer?.details) {
            note = LiveCues.envForcedNote
            await load(run)
            return
        }
        state = LiveCues.state(answer?.details)
    }
}

// MARK: Live cue verdicts (server 6.79.0)
//
// 0.5.327 (Miles, 2026-10-19): rate every live cue this week, so Friday's tuning reads real verdicts. Two surfaces read
// one store: Memories → Cues to rate and Rated cues (CueReviewPane), and the Cues view beside Live COS Ask on a glasses
// meeting, live or saved (MeetingCuesPanel). The server keeps the cue log and the verdicts (GET /api/live-cues/history and
// POST /api/live-cues/feedback, through the helper's `live-cues-history` and `live-cues-rate`); this store words what it
// answered. The history read is the capability check: a 404 is a server from before the routes, and both surfaces hide.
// A verdict saved here never touches the lens's up or down vote, which the server keeps beside it.
enum CueVerdict: String, CaseIterable, Sendable {
    case useful, late, `repeat`, wrong, obvious

    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    /// The key that gives this verdict while a cue card has focus: 1 to 5 in this order.
    var key: String { String((Self.allCases.firstIndex(of: self) ?? 0) + 1) }
}

struct LiveCueSource: Equatable, Sendable {
    var id: String
    var date: String
    var title: String
}

/// What the server stores for a cue: the verdict from Control, its note, and the lens's up or down, kept apart.
struct LiveCueRating: Equatable, Sendable {
    var verdict: CueVerdict?
    var note: String?
    var vote: String?
    var at: Date?
}

/// One cue from the server's log (`live-cues-log.jsonl`, 30 days).
struct LiveCueRecord: Identifiable, Equatable, Sendable {
    var id: String
    var sessionId: String
    var meetingTitle: String
    var createdAt: Date
    /// `reinforce` or `challenge`.
    var kind: String
    var headline: String
    var detail: String
    /// The gate's admission probability, 0 to 1.
    var gate: Double?
    var sources: [LiveCueSource]
    /// The last few hundred characters said before the cue was written.
    var before: String
    var rating: LiveCueRating?

    var verdict: CueVerdict? { rating?.verdict }

    init(id: String, sessionId: String, meetingTitle: String = "", createdAt: Date, kind: String, headline: String = "", detail: String,
         gate: Double? = nil, sources: [LiveCueSource] = [], before: String = "", rating: LiveCueRating? = nil) {
        self.id = id; self.sessionId = sessionId; self.meetingTitle = meetingTitle; self.createdAt = createdAt; self.kind = kind
        self.headline = headline; self.detail = detail; self.gate = gate; self.sources = sources; self.before = before; self.rating = rating
    }

    /// A row of the helper's history, or nil without what a card needs.
    init?(_ value: JSONValue) {
        guard let row = value.object, let id = row["cueId"]?.string, !id.isEmpty, let sessionId = row["sessionId"]?.string, !sessionId.isEmpty,
              let created = row["createdAt"]?.double, created > 0, let kind = row["kind"]?.string,
              let detail = row["detail"]?.string, !detail.isEmpty else { return nil }
        self.init(id: id, sessionId: sessionId, meetingTitle: row["meetingTitle"]?.string ?? "", createdAt: Date(timeIntervalSince1970: created / 1000),
                  kind: kind, headline: row["headline"]?.string ?? "", detail: detail, gate: row["gate"]?.double,
                  sources: (row["sources"]?.array ?? []).compactMap { item in
                      item.object.flatMap { s in s["title"]?.string.map { LiveCueSource(id: s["id"]?.string ?? "", date: s["date"]?.string ?? "", title: $0) } }
                  },
                  before: row["before"]?.string ?? "")
        if let stored = row["verdict"]?.object {
            let rating = LiveCueRating(verdict: stored["verdict"]?.string.flatMap(CueVerdict.init(rawValue:)), note: stored["note"]?.string,
                                       vote: stored["vote"]?.string, at: stored["at"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) })
            self.rating = rating.verdict == nil && rating.vote == nil ? nil : rating
        }
    }
}

/// The server's counts for the whole window, whatever the read was filtered to.
struct LiveCueCounts: Equatable, Sendable {
    var total: Int
    var rated: Int
    var unrated: Int
    var byVerdict: [CueVerdict: Int] = [:]

    /// The counts once one cue goes from `old` to `new` (nil is unrated), as the server will count them on the next read.
    func moving(from old: CueVerdict?, to new: CueVerdict?) -> LiveCueCounts {
        guard old != new else { return self }
        var next = self
        if let old { next.byVerdict[old] = max(0, (next.byVerdict[old] ?? 0) - 1) }
        if let new { next.byVerdict[new, default: 0] += 1 }
        if old == nil { next.rated += 1; next.unrated = max(0, next.unrated - 1) }
        if new == nil { next.rated = max(0, next.rated - 1); next.unrated += 1 }
        return next
    }
}

enum CueVerdicts {
    enum State: Equatable, Sendable {
        case checking
        case loaded
        /// 404: a server from before the routes. Both surfaces hide.
        case olderServer
        case unreachable
        /// 401 or 403, or no pairing token on this Mac.
        case reconnect
        /// The helper itself failed.
        case notChecked
        /// A 200 without the contract's shape.
        case unreadable
        case failed(status: Int)
    }

    struct History: Equatable, Sendable {
        var cues: [LiveCueRecord]
        var counts: LiveCueCounts
    }

    /// Memories' two views, the route the Memories page and the rail write (ControllerModel.cueReview).
    enum Review: String, Sendable { case toRate = "rate", rated }

    enum RateOutcome: Equatable, Sendable {
        /// The verdict the server now holds (nil when cleared) and the lens vote beside it.
        case saved(CueVerdict?, vote: String?)
        case unknownCue
        case olderServer
        case unreachable
        case reconnect
        case refused
        case failed(status: Int)
        case notChecked
    }

    enum Key: Equatable, Sendable { case rate(CueVerdict), note, skip }

    static let minimumServer = "6.79.0"
    /// Cues a meeting may get (server 6.78.2).
    static let meetingCap = 25
    /// A meeting's list is read again no sooner than this while it shows (CueVerdictsStore.loadMeeting).
    static let pollSeconds: TimeInterval = 15
    static let weekDays = 7
    /// A live meeting's list: two days, so one that runs past midnight keeps its first cues.
    static let liveDays = 2
    /// A saved meeting's list: the server keeps cues 30 days.
    static let savedDays = 30
    /// The server's CUE_FEEDBACK_REASON_MAX, in UTF-16 units as it counts them.
    static let noteMax = 200
    static let keysLine = "Oldest first. Keys 1 to 5 rate, N adds a note, S skips."
    static let notePlaceholder = "What would have made it useful?"

    /// The helper's details to a state and, from a 200 in the contract's shape, the cues and counts.
    static func read(_ details: [String: JSONValue]?) -> (State, History?) {
        guard let details else { return (.notChecked, nil) }
        switch details["transport"]?.string {
        case "unavailable": return (.unreachable, nil)
        case "no_token": return (.reconnect, nil)
        case "answered": break
        default: return (.notChecked, nil)
        }
        switch details["httpStatus"]?.int {
        case 200:
            guard details["v"]?.int == 1, let rows = details["cues"]?.array, let counts = details["counts"]?.object,
                  let total = counts["total"]?.int, let rated = counts["rated"]?.int, let unrated = counts["unrated"]?.int else { return (.unreadable, nil) }
            var by: [CueVerdict: Int] = [:]
            for verdict in CueVerdict.allCases { if let n = counts["byVerdict"]?.object?[verdict.rawValue]?.int { by[verdict] = n } }
            return (.loaded, History(cues: rows.compactMap(LiveCueRecord.init), counts: LiveCueCounts(total: total, rated: rated, unrated: unrated, byVerdict: by)))
        case 404: return (.olderServer, nil)
        case 401, 403: return (.reconnect, nil)
        case let status?: return (.failed(status: status), nil)
        case nil: return (.notChecked, nil)
        }
    }

    /// The one line a surface shows instead of cues, or nil when it has them.
    static func line(_ state: State) -> String? {
        switch state {
        case .loaded: return nil
        case .checking: return "Loading cues…"
        case .olderServer: return "Rating cues needs server \(minimumServer). Update the server in Settings."
        case .unreachable: return "COS server unreachable. Cues show here once it answers."
        case .reconnect: return "Reconnect COS Control to the server to see cues."
        case .notChecked: return "COS Control could not read cues. Check again."
        case .unreadable: return "The server's answer about cues was not readable. Update the server in Settings."
        case .failed(let status): return "The server could not list cues (HTTP \(status)). Check again."
        }
    }

    static func historyArguments(days: Int, session: String?, unrated: Bool) -> [String] {
        var arguments = ["live-cues-history", "--days", String(min(max(days, 1), 30))]
        if let session { arguments += ["--session", session] }
        if unrated { arguments.append("--unrated") }
        return arguments
    }

    /// A note as the server stores it: whitespace collapsed, at most `noteMax` UTF-16 units, cut on a character.
    static func note(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        var out = ""
        for character in collapsed {
            guard out.utf16.count + String(character).utf16.count <= noteMax else { break }
            out.append(character)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// One verdict for one cue; nil clears it (and carries no note).
    static func rateArguments(_ cue: LiveCueRecord, verdict: CueVerdict?, note raw: String?) -> [String] {
        var arguments = ["live-cues-rate", "--session", cue.sessionId, "--cue", cue.id, "--verdict", verdict?.rawValue ?? "clear"]
        if verdict != nil, let text = raw.map(note), !text.isEmpty { arguments += ["--note", text] }
        return arguments
    }

    static func rateOutcome(_ details: [String: JSONValue]?) -> RateOutcome {
        guard let details else { return .notChecked }
        switch details["transport"]?.string {
        case "unavailable": return .unreachable
        case "no_token": return .reconnect
        case "answered": break
        default: return .notChecked
        }
        switch details["httpStatus"]?.int {
        case 200:
            guard details["ok"]?.bool == true else { return .failed(status: 200) }
            return .saved(details["verdict"]?.string.flatMap(CueVerdict.init(rawValue:)), vote: details["vote"]?.string)
        case 404: return details["error"]?.string == "unknown_cue" ? .unknownCue : .olderServer
        case 400: return .refused
        case 401, 403: return .reconnect
        case let status?: return .failed(status: status)
        case nil: return .notChecked
        }
    }

    /// Why a rating did not save, or nil when it did.
    static func rateLine(_ outcome: RateOutcome) -> String? {
        switch outcome {
        case .saved: return nil
        case .unknownCue: return "The server no longer has this cue. Cues are kept 30 days."
        case .olderServer: return "Rating cues needs server \(minimumServer). Update the server in Settings."
        case .unreachable: return "COS server unreachable. The rating was not saved."
        case .reconnect: return "Reconnect COS Control to the server to rate cues."
        case .refused: return "The server did not accept this rating."
        case .failed(let status): return "The rating was not saved (HTTP \(status)). Try again."
        case .notChecked: return "COS Control could not save the rating. Try again."
        }
    }

    /// What a key does on a cue card: 1 to 5 rate, N goes to the note, S skips. Only while the card itself has focus and
    /// without Command, Option or Control, so typing anywhere else (the note included) and the window's shortcuts keep
    /// their keys.
    static func key(_ characters: String, modified: Bool, cardFocused: Bool) -> Key? {
        guard cardFocused, !modified else { return nil }
        switch characters {
        case "n", "N": return .note
        case "s", "S": return .skip
        default: return CueVerdict.allCases.first { $0.key == characters }.map(Key.rate)
        }
    }

    /// The queue's order: oldest first, then the skipped cues in the order they were skipped.
    static func queueOrder(_ cues: [LiveCueRecord], skipped: [String]) -> [LiveCueRecord] {
        let fresh = cues.filter { !skipped.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
        return fresh + skipped.compactMap { id in cues.first { $0.id == id } }
    }

    /// When a G2 meeting started, from its session id (`meeting_<epoch ms>_<suffix>`), or nil.
    static func meetingStart(_ sessionId: String) -> Date? {
        let parts = sessionId.split(separator: "_")
        guard parts.count >= 2, parts[0] == "meeting", parts[1].count == 13, let ms = Double(parts[1]) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Minutes into the meeting when the cue came, when that can be told (0 to 12 hours).
    static func minutesIn(_ cue: LiveCueRecord) -> Int? {
        guard let start = meetingStart(cue.sessionId) else { return nil }
        let seconds = cue.createdAt.timeIntervalSince(start)
        guard seconds >= 0, seconds < 12 * 3600 else { return nil }
        return Int(seconds / 60)
    }

    static func clock(_ date: Date, style: ClockStyle, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return style.format(String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0))
    }

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "Today 7:48 AM, 7 min in"; "Yesterday", a weekday within the week, else "Oct 12".
    static func when(_ cue: LiveCueRecord, now: Date, style: ClockStyle, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: cue.createdAt), to: calendar.startOfDay(for: now)).day ?? 0
        let day: String
        switch days {
        case 0: day = "Today"
        case 1: day = "Yesterday"
        case 2...6: day = weekdays[(calendar.component(.weekday, from: cue.createdAt) + 6) % 7]
        default: day = months[calendar.component(.month, from: cue.createdAt) - 1] + " " + String(calendar.component(.day, from: cue.createdAt))
        }
        let base = day + " " + clock(cue.createdAt, style: style, calendar: calendar)
        return minutesIn(cue).map { base + ", \($0) min in" } ?? base
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "challenge": return "Challenge"
        case "reinforce": return "Reinforce"
        default: return kind
        }
    }

    static func score(_ gate: Double?) -> String? { gate.map { String(format: "%.2f", $0) } }

    static func sourcesLine(_ sources: [LiveCueSource]) -> String {
        guard !sources.isEmpty else { return "Sources: none, from the room only" }
        return "Sources: " + sources.map { $0.date.isEmpty ? $0.title : "\($0.title) (\($0.date))" }.joined(separator: "; ")
    }

    /// "7:54 · Challenge · 0.91", a meeting card's first line.
    static func cardLine(_ cue: LiveCueRecord, style: ClockStyle, calendar: Calendar = .current) -> String {
        ([clock(cue.createdAt, style: style, calendar: calendar), kindLabel(cue.kind)] + [score(cue.gate)].compactMap { $0 }).joined(separator: " · ")
    }

    /// "Rated Repeat · “same ask as 7:49”", or nil when not rated.
    static func ratedLine(_ rating: LiveCueRating?) -> String? {
        guard let verdict = rating?.verdict else { return nil }
        guard let note = rating?.note, !note.isEmpty else { return "Rated " + verdict.label }
        return "Rated " + verdict.label + " · \u{201C}" + note + "\u{201D}"
    }

    /// The lens's vote, which a verdict here never replaces.
    static func voteLine(_ rating: LiveCueRating?) -> String? {
        switch rating?.vote {
        case "up": return "Voted up on the glasses"
        case "down": return "Voted down on the glasses"
        default: return nil
        }
    }

    static func ratingsLine(_ counts: LiveCueCounts) -> String { "Ratings this week: \(counts.rated) of \(counts.total)." }
    static func usedLine(_ count: Int) -> String { "\(count) of \(meetingCap) used" }
    static func leftLine(_ count: Int) -> String { count == 1 ? "1 left" : "\(count) left" }
    static func doneLine(_ counts: LiveCueCounts?) -> String {
        (counts?.total ?? 0) == 0 ? "No cues in the last 7 days." : "Every cue from the last 7 days is rated."
    }

    /// "Next up: 7:49 · LMS pages went to the 1517 team…", the cue after this one.
    static func nextLine(_ cue: LiveCueRecord, style: ClockStyle, calendar: Calendar = .current) -> String {
        let text = cue.headline.isEmpty ? cue.detail : cue.headline
        return "Next up: " + clock(cue.createdAt, style: style, calendar: calendar) + " · " + (text.count > 80 ? String(text.prefix(79)) + "…" : text)
    }

    /// What the Memories page is told for its two entries: nothing but whether to show them and the counts.
    static func summary(available: Bool?, counts: LiveCueCounts?) -> [String: JSONValue] {
        guard available == true, let counts else { return ["available": .bool(false)] }
        return ["available": .bool(true), "unrated": .number(Double(counts.unrated)), "rated": .number(Double(counts.rated)),
                "total": .number(Double(counts.total))]
    }
}

@MainActor
final class CueVerdictsStore: ObservableObject {
    typealias Run = LiveCuesStore.Run

    struct Meeting: Equatable, Sendable {
        var state = CueVerdicts.State.checking
        /// Oldest first, as the server sends them.
        var cues: [LiveCueRecord] = []
        var readAt: Date?
    }

    /// nil until a history read answers; true from a 200 in the contract, false from a 404 (both surfaces hide).
    @Published private(set) var available: Bool?
    @Published private(set) var weekState = CueVerdicts.State.checking
    /// This week's unrated cues, oldest first, the skipped ones last.
    @Published private(set) var queue: [LiveCueRecord] = []
    @Published private(set) var counts: LiveCueCounts?
    @Published private(set) var ratedState = CueVerdicts.State.checking
    /// This week's rated cues, newest first.
    @Published private(set) var rated: [LiveCueRecord] = []
    /// Each meeting's cues, by session id.
    @Published private(set) var meetings: [String: Meeting] = [:]
    /// Cues whose rating is on its way.
    @Published private(set) var saving: Set<String> = []
    /// Why a cue's last rating did not save; cleared by its next rating.
    @Published private(set) var rateErrors: [String: String] = [:]
    private var skipped: [String] = []
    private var reading: Set<String> = []
    var now: @MainActor () -> Date = { Date() }

    private func learn(_ state: CueVerdicts.State) {
        if state == .loaded { available = true } else if state == .olderServer { available = false }
    }

    /// This week's queue and counts (the unrated read; counts cover the whole week).
    func loadWeek(_ run: Run) async {
        guard reading.insert("week").inserted else { return }
        defer { reading.remove("week") }
        let (state, history) = CueVerdicts.read(try? await run(CueVerdicts.historyArguments(days: CueVerdicts.weekDays, session: nil, unrated: true), nil).details)
        learn(state)
        weekState = state
        queue = CueVerdicts.queueOrder((history?.cues ?? []).filter { $0.verdict == nil }, skipped: skipped)
        if let history { counts = history.counts }
    }

    /// This week's rated cues (the whole week's read, rated ones kept).
    func loadRated(_ run: Run) async {
        guard reading.insert("rated").inserted else { return }
        defer { reading.remove("rated") }
        let (state, history) = CueVerdicts.read(try? await run(CueVerdicts.historyArguments(days: CueVerdicts.weekDays, session: nil, unrated: false), nil).details)
        learn(state)
        ratedState = state
        rated = (history?.cues ?? []).filter { $0.verdict != nil }.sorted { $0.createdAt > $1.createdAt }
        if let history { counts = history.counts }
    }

    /// One meeting's cues. Never read again sooner than `pollSeconds` after the last read unless forced (Refresh), and
    /// one read per meeting at a time, so the live list polls no faster than every 15 seconds however often it asks.
    func loadMeeting(_ session: String, days: Int, force: Bool = false, run: Run) async {
        if !force, let last = meetings[session]?.readAt, now().timeIntervalSince(last) < CueVerdicts.pollSeconds { return }
        guard reading.insert(session).inserted else { return }
        defer { reading.remove(session) }
        meetings[session, default: Meeting()].readAt = now()
        let (state, history) = CueVerdicts.read(try? await run(CueVerdicts.historyArguments(days: days, session: session, unrated: false), nil).details)
        learn(state)
        meetings[session]?.state = state
        meetings[session]?.cues = history?.cues.filter { $0.sessionId == session } ?? []
    }

    /// The cue moves to the end of the queue; nothing is sent.
    func skip(_ cue: LiveCueRecord) {
        skipped.removeAll { $0 == cue.id }
        skipped.append(cue.id)
        queue = CueVerdicts.queueOrder(queue, skipped: skipped)
    }

    /// Save a verdict (nil clears it). One call per cue at a time; on success every list that holds the cue shows it.
    func rate(_ cue: LiveCueRecord, verdict: CueVerdict?, note: String? = nil, run: Run) async {
        guard !saving.contains(cue.id) else { return }
        saving.insert(cue.id)
        rateErrors[cue.id] = nil
        let outcome = CueVerdicts.rateOutcome(try? await run(CueVerdicts.rateArguments(cue, verdict: verdict, note: note), nil).details)
        saving.remove(cue.id)
        guard case .saved(let stored, let vote) = outcome else {
            if outcome == .olderServer { available = false }
            rateErrors[cue.id] = CueVerdicts.rateLine(outcome)
            return
        }
        let old = current(cue.id)?.verdict ?? cue.verdict
        var updated = current(cue.id) ?? cue
        let text = stored == nil ? nil : note.map(CueVerdicts.note).flatMap { $0.isEmpty ? nil : $0 }
        updated.rating = stored == nil && vote == nil ? nil : LiveCueRating(verdict: stored, note: text, vote: vote, at: now())
        apply(updated, from: old)
    }

    /// The latest copy of a cue in any list.
    private func current(_ id: String) -> LiveCueRecord? {
        queue.first { $0.id == id } ?? rated.first { $0.id == id } ?? meetings.values.lazy.compactMap { $0.cues.first { $0.id == id } }.first
    }

    private func apply(_ cue: LiveCueRecord, from old: CueVerdict?) {
        counts = counts?.moving(from: old, to: cue.verdict)
        skipped.removeAll { $0 == cue.id }
        var waiting = queue.filter { $0.id != cue.id }
        if cue.verdict == nil, weekState == .loaded, cue.createdAt > now().addingTimeInterval(-Double(CueVerdicts.weekDays) * 86_400) { waiting.append(cue) }
        queue = CueVerdicts.queueOrder(waiting, skipped: skipped)
        var done = rated.filter { $0.id != cue.id }
        if cue.verdict != nil, ratedState == .loaded { done.append(cue) }
        rated = done.sorted { $0.createdAt > $1.createdAt }
        for (session, meeting) in meetings where meeting.cues.contains(where: { $0.id == cue.id }) {
            meetings[session]?.cues = meeting.cues.map { $0.id == cue.id ? cue : $0 }
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
    /// 6.74.0: cancelled, insufficient_disk, sha_mismatch, download_failed, stalled, cli_untrusted or cli_missing.
    var errorCode: String? = nil
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
    /// 6.74.0: how the server trusts the FluidAudio tool (developer-id for COS Control's bundled copy, sha256 for a
    /// hand-placed pinned copy), or why it does not (missing, unsigned, signature_invalid, wrong_team, wrong_version).
    var cliTrust: String? = nil
    var cliReason: String? = nil
    /// The server is downloading or verifying right now.
    var serverInstalling: Bool { progress?.state == "downloading" || progress?.state == "verifying" }
    var failed: Bool { !installed && progress?.state == "failed" }
    var cancelled: Bool { failed && progress?.errorCode == "cancelled" }
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
    /// 0.5.317 (server 6.74.0): Mac dictation's engine (auto, parakeet-ultra or whisper). nil on an older server, whose
    /// dictation is Parakeet Ultra only.
    var dictation: SttDictationChoice? = nil

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
                                          error: row["error"]?.string.flatMap { $0.isEmpty ? nil : $0 }, errorCode: row["errorCode"]?.string)
        }
        self.parakeet = SttParakeet(installed: parakeet["installed"]?.bool ?? false, installable: parakeet["installable"]?.bool ?? false,
                                    version: parakeet["version"]?.string, bytes: max(0, parakeet["bytes"]?.int ?? 0), progress: progress,
                                    warmPreview: parakeet["warm"]?.object?["preview"]?.string,
                                    note: parakeet["note"]?.string.flatMap { $0.isEmpty ? nil : $0 },
                                    cliTrust: parakeet["cli"]?.object?["trust"]?.string, cliReason: parakeet["cli"]?.object?["reason"]?.string)
        let applies = object["appliesTo"]?.object ?? [:]
        appliesPreview = applies["preview"]?.string
        appliesHQ = applies["hq"]?.string
        dictation = SttDictationChoice(object["dictation"])
    }
}

/// The server's `dictation.desktop` (6.74.0), whitelisted by the helper: the person's choice, the engine a dictation
/// would use right now (`effective`: parakeet-ultra, whisper or none) and why.
struct SttDictationChoice: Equatable, Sendable {
    var selected: String
    var options: [SttOption]
    var effective: String?
    var reason: String?
    var reasonCode: String?
    var note: String?
    init(selected: String, options: [SttOption] = [], effective: String? = nil, reason: String? = nil, reasonCode: String? = nil, note: String? = nil) {
        self.selected = selected; self.options = options; self.effective = effective; self.reason = reason; self.reasonCode = reasonCode; self.note = note
    }
    init?(_ value: JSONValue?) {
        guard let object = value?.object, let selected = object["selected"]?.string, !selected.isEmpty else { return nil }
        self.selected = selected
        effective = object["effective"]?.string
        func text(_ key: String) -> String? { object[key]?.string.flatMap { $0.isEmpty ? nil : $0 } }
        reason = text("reason"); reasonCode = text("reasonCode"); note = text("note")
        options = (object["options"]?.array ?? []).compactMap { row in
            guard let row = row.object, let id = row["id"]?.string, !id.isEmpty else { return nil }
            return SttOption(id: id, label: row["label"]?.string, available: row["available"]?.bool ?? true,
                             experimental: row["experimental"]?.bool ?? false, note: row["note"]?.string)
        }
    }
}

/// What the Parakeet row says and offers. Never a greyed-out control without its reason and one action (0.5.317).
enum ParakeetRowState: Equatable, Sendable {
    enum Action: String, Equatable, Sendable { case install, retryInstall, cancel, checkAgain, afterRecording, useWhisper, none }
    case installed(String)
    case installing(String)
    /// Install (or Try again after a failure) is offered. `line` is the failure's reason, when there was one.
    case offer(title: String, line: String?)
    /// Parakeet cannot be installed right now: why, and what to do about it.
    case blocked(reason: String, action: Action)
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
    static let installCaption = "Parakeet Ultra runs on this Mac, for dictation and as the second opinion. Every file is checked before it is installed, and dictation keeps working with Whisper meanwhile."
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

    // MARK: Dictation engine and the Parakeet row (0.5.317, server 6.74.0)

    static let installTitle = "Install Parakeet (654 MB)"
    /// The server's own precheck (507 insufficient_disk) uses the same floor: the 654 MB download, staging and the swap.
    static let requiredFreeBytes: Int64 = 1_500_000_000
    static let dictationCaption = "Automatic uses Parakeet Ultra when it is installed and ready, and Whisper on this Mac otherwise. Dictation never uses the cloud."
    static let dictationOldServer = "This COS server dictates with Parakeet Ultra only. Update the server to dictate with Whisper."
    static let licensesLine = "Parakeet Ultra model: CC BY 4.0, FluidInference. FluidAudio: Apache 2.0."
    static let dictationTitles = ["auto": "Automatic (recommended)", "parakeet-ultra": "Parakeet Ultra", "whisper": "Whisper"]

    /// The Dictation engine picker's rows: the server's options in its order, with COS's names for the three ids.
    /// `compact`: Settings' 390 pt dropdown face truncated "Automatic (recommended)" (render, 0.5.317), so there it is
    /// "Automatic" and the line under it says what Automatic does.
    static func dictationRows(_ choice: SttDictationChoice, compact: Bool = false) -> [SttPickerRow] {
        let options = choice.options.isEmpty ? ["auto", "parakeet-ultra", "whisper"].map { SttOption(id: $0, label: nil, available: true, experimental: false, note: nil) } : choice.options
        var rows = options.map { option in
            let title = compact && option.id == "auto" ? "Automatic" : dictationTitles[option.id] ?? option.label.flatMap { $0.isEmpty ? nil : $0 } ?? option.id
            return SttPickerRow(id: option.id, title: title, note: option.available ? nil : (option.note.flatMap { $0.isEmpty ? nil : $0 } ?? "Not available"), enabled: option.available)
        }
        if !rows.contains(where: { $0.id == choice.selected }) {
            rows.insert(SttPickerRow(id: choice.selected, title: dictationTitles[choice.selected] ?? choice.selected, note: nil, enabled: true), at: 0)
        }
        return rows
    }

    /// One line under the picker: what a dictation uses right now. The server's note wins; nil fields read plainly.
    static func dictationLine(_ settings: SttSettings) -> String {
        guard let choice = settings.dictation else { return dictationOldServer }
        if let note = choice.note { return note }
        switch choice.effective {
        case "parakeet-ultra": return "Dictation uses Parakeet Ultra on this Mac."
        case "whisper":
            return choice.selected == "whisper" ? "Dictation uses Whisper on this Mac."
                : settings.parakeet.installed ? "Dictation uses Whisper until Parakeet Ultra is ready." : "Dictation uses Whisper until Parakeet Ultra is installed."
        case "none": return choice.reason ?? "No speech engine is ready for dictation. Set up voice in the setup guide."
        default: return choice.reason ?? dictationCaption
        }
    }

    /// Why the server cannot install Parakeet, in its own words when it sent them.
    static func notInstallableLine(_ parakeet: SttParakeet) -> String {
        if let note = parakeet.note { return note }
        if let line = cliLine(parakeet.cliReason) { return line }
        return "This COS server cannot install Parakeet on this Mac."
    }
    static func cliLine(_ reason: String?) -> String? {
        switch reason {
        case "missing": "COS Control's speech tool was not found. Download COS Control again, then check again."
        case "unsigned", "signature_invalid": "COS Control's speech tool failed its signature check. Download COS Control again, then check again."
        case "wrong_team", "wrong_version": "COS Control's speech tool does not match this server. Update COS Control, then check again."
        default: nil
        }
    }
    static func diskLine(free: Int64) -> String {
        "Parakeet needs 1.5 GB free; \(gigabytes(free)) is free. Free some space, then check again."
    }
    static func gigabytes(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1_000_000_000) : "\(max(0, bytes / 1_000_000)) MB"
    }
    /// A failed install's reason: the server's sentence first, else COS's words for its error code.
    static func installFailureLine(_ parakeet: SttParakeet) -> String? {
        guard parakeet.failed else { return nil }
        if parakeet.cancelled { return "Install cancelled. Nothing was kept, and dictation keeps using Whisper." }
        if let said = parakeet.progress?.error { return said }
        switch parakeet.progress?.errorCode {
        case "insufficient_disk": return "Not enough free disk space. Parakeet needs 1.5 GB free."
        case "sha_mismatch": return "A downloaded file did not match its checksum, so nothing was installed. Try again."
        case "download_failed", "stalled": return "The download did not finish. Nothing was installed. Try again."
        case "cli_untrusted", "cli_missing": return cliLine(parakeet.cliReason) ?? "COS Control's speech tool could not be verified. Download COS Control again."
        default: return "The Parakeet install did not finish. Try again."
        }
    }

    /// The Parakeet row: installed, installing, Install offered, or why not with one action. Never a dead control.
    static func parakeetState(_ settings: SttSettings, installing: Bool, recording: Bool, freeBytes: Int64?) -> ParakeetRowState {
        let parakeet = settings.parakeet
        if installing || parakeet.serverInstalling { return .installing(progressLine(parakeet)) }
        if let line = installedLine(parakeet) { return .installed(line) }
        if recording { return .blocked(reason: recordingHold, action: .afterRecording) }
        if !parakeet.installable {
            let explicit = settings.dictation?.selected == "parakeet-ultra"
            return .blocked(reason: notInstallableLine(parakeet), action: explicit ? .useWhisper : .checkAgain)
        }
        if let freeBytes, freeBytes < requiredFreeBytes { return .blocked(reason: diskLine(free: freeBytes), action: .checkAgain) }
        if let failure = installFailureLine(parakeet) { return .offer(title: parakeet.cancelled ? installTitle : "Try again", line: failure) }
        return .offer(title: installTitle, line: nil)
    }
    static func actionTitle(_ action: ParakeetRowState.Action) -> String? {
        switch action {
        case .install: installTitle
        case .retryInstall: "Try again"
        case .cancel: "Cancel"
        case .checkAgain: "Check again"
        case .useWhisper: "Use Whisper"
        case .afterRecording, .none: nil
        }
    }
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
    /// 0.5.317: free space on this Mac's home volume, read when the card asks (nil: unknown, the server still checks).
    var freeBytes: () -> Int64? = {
        (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
    /// COS Control's bundled FluidAudio tool (Contents/Helpers/fluidaudiocli), passed to the server's install. nil in a
    /// build without it (the server then looks for its own copy).
    var cliPath: () -> String? = {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/fluidaudiocli").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    /// The server's answer to register-parakeet-cli, once per launch: nil before it, or on a server before 6.74.0.
    @Published private(set) var cliTrusted: Bool?
    func rowState(recording: Bool) -> ParakeetRowState? {
        guard visible, let settings else { return nil }
        return Transcription.parakeetState(settings, installing: installing, recording: recording, freeBytes: freeBytes())
    }
    /// Cancel is offered while an install runs here or on the server.
    var offersCancel: Bool { showsProgress && settings?.dictation != nil }
    private var cancelRequested = false
    private var cliRegistered = false

    /// Tells the server where COS Control's bundled tool is (POST /api/stt-settings/parakeet/cli). Called at launch and
    /// from Check again; the server also looks in /Applications on its own.
    func registerCLI(_ run: Run) async {
        guard let path = cliPath() else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["cliPath": path]),
              let answer = try? await run(["register-parakeet-cli"], data), answer.ok else { return }
        cliTrusted = answer.details["httpStatus"]?.int == 200 ? answer.details["trusted"]?.bool : nil
    }

    /// Check again: re-register the bundled tool, then read the settings.
    func checkAgain(_ run: Run) async {
        await registerCLI(run)
        await load(run)
    }

    /// DELETE the install. The server keeps nothing partial; the next read shows it cancelled.
    func cancelInstall(_ run: Run) async {
        guard showsProgress else { return }
        cancelRequested = true
        do {
            let answer = try await run(["cancel-parakeet-install"], nil)
            if let settings = SttSettings(answer.details["settings"]) { self.settings = settings }
            if !answer.ok { error = answer.message }
        } catch { self.error = error.localizedDescription }
    }
    /// The card shows progress while this store polls or while the server says it is downloading or verifying.
    var showsProgress: Bool { installing || settings?.parakeet.serverInstalling == true }

    /// A read. When the server is already installing (started from another open of the panel), it follows that
    /// install the same way the button does, until installed or failed.
    func load(_ run: Run, pause: Pause = { try? await Task.sleep(nanoseconds: $0) }) async {
        // 0.5.317: the first read of a launch tells the server where COS Control's speech tool is.
        if !cliRegistered { cliRegistered = true; await registerCLI(run) }
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
        // The same floor the server checks (507), before anything downloads.
        if let free = freeBytes(), free < Transcription.requiredFreeBytes { error = Transcription.diskLine(free: free); return }
        installing = true
        cancelRequested = false
        defer { installing = false }
        error = nil
        do {
            let request = try JSONSerialization.data(withJSONObject: cliPath().map { ["cliPath": $0] } ?? [String: String]())
            let started = try await run(["install-parakeet"], request)
            switch started.details["httpStatus"]?.int {
            case 200, 202:
                if let settings = SttSettings(started.details["settings"]) { self.settings = settings }
                // 200 {started:false}: already installed, nothing to follow.
                if started.details["started"]?.bool == false { return }
            case 404:
                error = "This server cannot install Parakeet."; return
            case 507:
                error = Transcription.diskLine(free: Int64(started.details["freeBytes"]?.int ?? 0)); return
            case 422:
                error = Transcription.cliLine(started.details["cliReason"]?.string) ?? started.details["error"]?.string ?? started.message; return
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
            // Cancelled here: one more read shows the server's cancelled state, then stop.
            if cancelRequested, settings?.parakeet.serverInstalling != true { return }
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
