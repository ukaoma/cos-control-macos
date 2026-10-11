import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import SwiftUI

@MainActor
final class MeetingAskStore: ObservableObject {
    @Published private(set) var config: MeetingAskConfig?
    @Published private(set) var records: [String: MeetingAskLocalRecord] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var running: Set<String> = []
    @Published var notice: String?
    @Published private(set) var online = false
    private var fileObserver: AnyCancellable?
    private var publishedFiles: [String: [MeetingAskFile]] = [:]
    private var fileSyncing: Set<String> = []
    private var writers: [String: Task<Void, Never>] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var loaded: Set<String> = []
    private var identity = ""
    private var refreshing = false
    var injectedTransport: ((String, Data) async throws -> Data)?
    let disk: MeetingAskDisk
    init(root: URL? = nil) {
        let home = ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        disk = MeetingAskDisk(root: root ?? home.appendingPathComponent("cos-data/meeting-ask-client"))
    }
    func transport<T: Decodable>(_ operation: String, payload: [String: Any] = [:], model: ControllerModel, as: T.Type) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: ["operation": operation, "payload": payload])
        guard data.count <= 1_000_000 else { throw HelperClientError.commandFailed("Meeting context exceeds the request limit.") }
        if let injectedTransport { return try JSONDecoder().decode(T.self, from: await injectedTransport(operation, data)) }
        let reply = try await model.runHelper(["meeting-ask"], timeout: 30, stdinData: data)
        guard reply.ok else { throw MeetingAskTransportFailure(status: reply.details["httpStatus"]?.int ?? 0, message: reply.message) }
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(reply.details))
    }
    private func message(_ error: Error) -> String {
        if let failure = error as? MeetingAskTransportFailure { return failure.message }
        if case HelperClientError.commandFailed(let value) = error { return value }
        return "Meeting assistance could not save or load its context. Your draft has not been discarded."
    }
    func refreshConfig(model: ControllerModel) async {
        if refreshing {
            while refreshing && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            return
        }
        refreshing = true
        defer { refreshing = false }
        do {
            let local = try await transport("identity", model: model, as: MeetingAskPairing.self)
            if config?.pairingContext != local.pairingContext {
                flushAll(); for task in jobs.values { task.cancel() }; jobs = [:]
                records = [:]; loaded = []; errors = [:]; running = []; publishedFiles = [:]; config = nil; identity = ""
                if let cached = try disk.readConfig(pairing: local.pairingContext) {
                    config = cached; identity = cached.serverInstanceId + ":" + local.pairingContext
                }
            }
            let next = try await transport("config", model: model, as: MeetingAskConfig.self)
            guard next.protocolVersion == 2, let pairing = next.pairingContext, !pairing.isEmpty else { throw HelperClientError.commandFailed("Update COS Control and the server together to use meeting assistance.") }
            let scope = next.serverInstanceId + ":" + pairing
            if scope != identity {
                flushAll()
                for task in jobs.values { task.cancel() }; jobs = [:]
                records = [:]; loaded = []; errors = [:]; running = []; identity = scope
            }
            config = next; online = true; notice = nil
            try disk.writeConfig(next)
        } catch { online = false; notice = message(error) }
    }
    func configure(_ selection: MeetingAskModel, model: ControllerModel) async {
        do {
            let _: MeetingAskConfig = try await transport("configure", payload: ["engine": selection.engine, "model": selection.model], model: model, as: MeetingAskConfig.self)
            await refreshConfig(model: model)
        } catch { notice = message(error) }
    }
    func ensure(_ session: String) {
        guard !loaded.contains(session), let config, let pairing = config.pairingContext else { return }
        let key = MeetingAskDisk.scope(server: config.serverInstanceId, pairing: pairing, session: session)
        do { records[session] = try disk.read(key); loaded.insert(session) }
        catch { errors[session] = "Saved meeting assistance could not be read. Its recovery file was preserved; no request will run." }
    }
    func draft(_ session: String) -> String { records[session]?.draft ?? "" }
    func setDraft(_ value: String, session: String) {
        ensure(session); guard records[session] != nil else { return }
        records[session]?.draft = String(value.prefix(2000))
        writers[session]?.cancel()
        writers[session] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }; _ = self?.flush(session)
        }
    }
    @discardableResult func flush(_ session: String) -> Bool {
        writers[session]?.cancel(); writers[session] = nil
        guard let record = records[session] else { return false }
        do { try disk.write(record); return true }
        catch { errors[session] = "Could not save meeting context. Check free disk space. Nothing new will run until it can be saved."; return false }
    }
    func flushAll() { for session in records.keys { _ = flush(session) } }
    func open(_ session: String, model: ControllerModel) async {
        await refreshConfig(model: model); ensure(session)
        guard let config, records[session] != nil else { return }
        let ticket = identity
        do {
            var offset = 0, history: [MeetingAskExchange] = [], files: [MeetingAskFile] = []
            repeat {
                let page = try await transport("history", payload: ["sessionId": session, "serverInstanceId": config.serverInstanceId, "offset": offset], model: model, as: MeetingAskHistory.self)
                guard ticket == identity else { return }
                history += page.exchanges; files = page.files
                if let next = page.nextOffset, next > offset { offset = next } else { break }
                guard history.count < 10_000 else { throw HelperClientError.commandFailed("Meeting history exceeds this app's local cache limit. Saved server history is retained.") }
            } while true
            guard history.allSatisfy({ $0.sessionId == session && $0.serverInstanceId == config.serverInstanceId }) else { throw HelperClientError.commandFailed("Meeting history identity did not match. Local recovery is preserved.") }
            var merged = Dictionary(uniqueKeysWithValues: (records[session]?.exchanges ?? []).map { ($0.id, $0) })
            for row in history {
                if let local = merged[row.id], local.updatedAt > row.updatedAt || (local.terminal && !row.terminal) { continue }
                merged[row.id] = row
            }
            history = merged.values.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
            records[session]?.exchanges = history; records[session]?.files = files
            errors[session] = nil
            if let outbox = records[session]?.outbox {
                if history.contains(where: { $0.requestId == outbox.requestId }) { records[session]?.outbox = nil; if outbox.consumesComposer, records[session]?.draft == outbox.question { records[session]?.draft = "" } }
                else { errors[session] = "The last question's admission is uncertain. Check its status before sending another." }
            }
            _ = flush(session)
            if let active = history.first(where: { !$0.terminal }) { watch(active, model: model) }
        } catch { errors[session] = message(error) }
    }
    func reconcile(_ session: String, model: ControllerModel) async {
        guard let request = records[session]?.outbox else { return }
        let ticket = identity
        do {
            let receipt = try await transport("status", payload: ["requestId": request.requestId], model: model, as: MeetingAskReceipt.self)
            guard ticket == identity else { return }
            guard receipt.exchange.requestId == request.requestId, accept(receipt.exchange, session: session) else { throw HelperClientError.commandFailed("Question identity did not match. Local recovery is preserved.") }
            records[session]?.outbox = nil; if request.consumesComposer, records[session]?.draft == request.question { records[session]?.draft = "" }; _ = flush(session)
            if !receipt.exchange.terminal { watch(receipt.exchange, model: model) }
        } catch {
            if let failure = error as? MeetingAskTransportFailure, failure.status == 404 {
                errors[session] = "The server has not confirmed this question yet. Retry the same question to reconcile its original request; your draft is retained."
            } else { errors[session] = message(error) + " The question remains recoverable. No automatic resend occurred." }
        }
    }
    /// A missing status can race an original POST still awaiting admission. Explicit retry reuses its exact identity and bytes.
    func retryOutbox(_ session: String, model: ControllerModel) {
        guard let request = records[session]?.outbox, online, !running.contains(session), request.serverInstanceId == config?.serverInstanceId else { return }
        let ticket = identity
        running.insert(session); errors[session] = nil
        jobs[session] = Task { [weak self] in
            guard let self else { return }
            defer { if ticket == identity { jobs[session] = nil; running.remove(session) } }
            do {
                let receipt = try await transport("submit", payload: try object(request) as? [String: Any] ?? [:], model: model, as: MeetingAskReceipt.self)
                guard ticket == identity else { return }
                guard receipt.exchange.requestId == request.requestId, accept(receipt.exchange, session: session) else { throw HelperClientError.commandFailed("Question identity did not match. Local recovery is preserved.") }
                records[session]?.outbox = nil
                if request.consumesComposer, records[session]?.draft == request.question { records[session]?.draft = "" }
                _ = flush(session)
                await poll(receipt.exchange, model: model, ticket: ticket)
            } catch { if ticket == identity { errors[session] = message(error) + " The original question remains recoverable." } }
        }
    }
    @discardableResult private func accept(_ exchange: MeetingAskExchange, session: String) -> Bool {
        guard exchange.sessionId == session, exchange.serverInstanceId == config?.serverInstanceId else { return false }
        var rows = records[session]?.exchanges ?? []
        if let index = rows.firstIndex(where: { $0.id == exchange.id }) {
            if rows[index].updatedAt > exchange.updatedAt || (rows[index].terminal && !exchange.terminal) { return true }
            rows[index] = exchange
        } else { rows.append(exchange) }
        records[session]?.exchanges = rows; _ = flush(session); return true
    }
    func ask(action: String, question: String, feed: LiveTranscriptFeed, model: ControllerModel, retryOf: String? = nil) {
        let session = feed.sessionId
        ensure(session)
        guard let config, online, !running.contains(session), records[session]?.outbox == nil, records[session] != nil, !feed.turns.isEmpty else { return }
        let question = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !question.isEmpty else { return }
        // Freeze the evidence cutoff at the user's tap, before any file registration or transport wait.
        let now = feed.endedAt ?? Date()
        let elapsed = max(feed.turns.map(\.elapsedMs).max() ?? 0, Int(max(0, now.timeIntervalSince(feed.startTime ?? now)) * 1000))
        let turns = feed.turns.map { MeetingAskTurn(id: $0.id, elapsedMs: $0.elapsedMs, speaker: $0.speaker, text: $0.text) }
        if action == "ask", retryOf == nil { records[session]?.draft = question }
        guard flush(session) else { return }
        running.insert(session); errors[session] = nil
        let ticket = identity
        jobs[session] = Task { [weak self] in
            guard let self else { return }
            defer { if ticket == identity { running.remove(session); jobs[session] = nil } }
            do {
                guard await registerFiles(session, model: model), ticket == identity, !Task.isCancelled else { return }
                let files = records[session]?.files ?? []
                let request = MeetingAskSubmit(requestId: UUID().uuidString.lowercased(), sessionId: session, serverInstanceId: config.serverInstanceId, action: action, question: question, elapsedMs: elapsed,
                    turns: turns, model: config.selected,
                    files: files.filter { $0.status != "removed" }.map { .init(id: $0.id, revision: $0.revision) }, retryOf: retryOf)
                records[session]?.outbox = request
                guard flush(session) else { return }
                let receipt = try await transport("submit", payload: try object(request) as? [String: Any] ?? [:], model: model, as: MeetingAskReceipt.self)
                guard ticket == identity else { return }
                guard receipt.exchange.requestId == request.requestId, accept(receipt.exchange, session: session) else { throw HelperClientError.commandFailed("Question identity did not match. Local recovery is preserved.") }
                records[session]?.outbox = nil; if request.consumesComposer, records[session]?.draft == request.question { records[session]?.draft = "" }; _ = flush(session)
                await poll(receipt.exchange, model: model, ticket: ticket)
            } catch {
                if ticket == identity {
                    if let failure = error as? MeetingAskTransportFailure, [400, 401, 403, 404, 413, 422, 429].contains(failure.status) {
                        records[session]?.outbox = nil; _ = flush(session)
                    }
                    errors[session] = message(error)
                }
            }
        }
    }
    func observeFiles(_ files: WorkCardFileStore, model: ControllerModel) {
        fileObserver = files.$manifests.debounce(for: .milliseconds(600), scheduler: RunLoop.main).sink { [weak self, weak model] manifests in
            guard let self, let model else { return }
            let sessions = manifests.keys.compactMap { key -> String? in
                let prefix = "meetingctx:g2:"
                return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
            }
            Task { for session in sessions { _ = await self.registerFiles(session, model: model) } }
        }
    }
    @discardableResult func registerFiles(_ session: String, model: ControllerModel) async -> Bool {
        while fileSyncing.contains(session), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
        guard !Task.isCancelled else { return false }
        fileSyncing.insert(session)
        defer { fileSyncing.remove(session) }
        if config == nil { await refreshConfig(model: model) }
        ensure(session)
        guard let config, online else { return false }
        let ticket = identity
        let files = model.meetingAskFiles(session: session)
        do {
            let registered: MeetingAskFileReply = try await transport("files", payload: ["sessionId": session, "serverInstanceId": config.serverInstanceId, "files": try object(files)], model: model, as: MeetingAskFileReply.self)
            guard ticket == identity else { return false }
            publishedFiles[session] = files; records[session]?.files = registered.files
            return flush(session)
        } catch { errors[session] = "Files are saved on this Mac; sharing their text with meeting assistance failed. " + message(error); return false }
    }
    private func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) }
    private func watch(_ exchange: MeetingAskExchange, model: ControllerModel) {
        guard jobs[exchange.sessionId] == nil else { return }
        let ticket = identity, session = exchange.sessionId
        running.insert(session)
        jobs[session] = Task { [weak self] in
            guard let self else { return }
            await poll(exchange, model: model, ticket: ticket)
            if ticket == identity { jobs[session] = nil; running.remove(session) }
        }
    }
    private func poll(_ first: MeetingAskExchange, model: ControllerModel, ticket: String) async {
        var row = first
        let deadline = Date().addingTimeInterval(180)
        while !row.terminal, Date() < deadline, ticket == identity, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, ticket == identity else { return }
            do {
                let receipt = try await transport("status", payload: ["requestId": row.requestId], model: model, as: MeetingAskReceipt.self)
                guard ticket == identity else { return }
                guard receipt.exchange.requestId == row.requestId, accept(receipt.exchange, session: row.sessionId) else { throw HelperClientError.commandFailed("Answer identity did not match. Saved context is preserved.") }
                row = receipt.exchange
            } catch { errors[row.sessionId] = message(error); return }
        }
        if !row.terminal, ticket == identity { errors[row.sessionId] = "Answer is still pending on the server. Refresh to check its status; nothing was resubmitted." }
    }
    func cancel(_ exchange: MeetingAskExchange, model: ControllerModel) async {
        do {
            let receipt = try await transport("cancel", payload: ["requestId": exchange.requestId, "serverInstanceId": exchange.serverInstanceId], model: model, as: MeetingAskReceipt.self)
            accept(receipt.exchange, session: exchange.sessionId)
        } catch { errors[exchange.sessionId] = message(error) }
    }
    func captureCopy(title: String, transcript: String, sessions: [String], localFiles: [MeetingAskFile] = []) -> MeetingAskCopySnapshot? {
        if sessions.isEmpty { return .init(title: title, transcript: transcript, sessions: [], localFiles: localFiles, serverInstanceId: "", pairingContext: "") }
        guard let config, let pairing = config.pairingContext else { notice = "Refresh meeting assistance before copying its full context."; return nil }
        return .init(title: title, transcript: transcript, sessions: sessions, localFiles: localFiles, serverInstanceId: config.serverInstanceId, pairingContext: pairing)
    }
    /// Every byte from the transcript is captured synchronously by the caller, before history I/O.
    /// Navigation may continue. A server/pairing switch aborts the copy instead of mixing contexts.
    func prepareCopy(_ snapshot: MeetingAskCopySnapshot, model: ControllerModel) async -> String? {
        func matches() -> Bool { snapshot.sessions.isEmpty || (config?.serverInstanceId == snapshot.serverInstanceId && config?.pairingContext == snapshot.pairingContext) }
        guard matches() else { notice = "COS connection changed. Nothing was copied."; return nil }
        for session in snapshot.sessions {
            await open(session, model: model)
            guard matches() else { notice = "COS connection changed. Nothing was copied."; return nil }
        }
        var seen = Set<String>()
        let rows = snapshot.sessions.flatMap { records[$0]?.exchanges ?? [] }.filter { seen.insert($0.id).inserted }
        let files = MeetingAskText.evidenceFiles(exchanges: rows, current: snapshot.localFiles + snapshot.sessions.flatMap { records[$0]?.files ?? [] })
        let coverage = snapshot.sessions.compactMap { errors[$0].map { "Context coverage: " + $0 } }.joined(separator: "\n")
        let text = MeetingAskText.fullContext(title: snapshot.title, transcript: snapshot.transcript, exchanges: rows, files: files) + (coverage.isEmpty ? "" : "\n\n" + coverage)
        guard text.utf8.count <= 4_000_000 else { notice = "Full context exceeds the 4 MB clipboard limit. Nothing was copied; saved history remains available."; return nil }
        return text
    }
    func copyPrepared(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        notice = "Copied full meeting context"
    }

}
struct MeetingAskCopySnapshot: Sendable {
    let title: String
    let transcript: String
    let sessions: [String]
    let localFiles: [MeetingAskFile]
    let serverInstanceId: String
    let pairingContext: String
}
struct MeetingAskTransportFailure: Error { var status: Int; var message: String }
struct MeetingAskPairing: Codable { var pairingContext: String }
struct MeetingAskFileReply: Codable { var files: [MeetingAskFile] }

extension LibraryMeeting {
    func meetingAskSessions(keys: [String]) -> [String] {
        var seen = Set<String>()
        let candidates = keys.filter { $0.hasPrefix("g2:") }.map { String($0.dropFirst(3)) } + g2SessionIds + (sourceSessionId.map { [$0] } ?? [])
        return candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

extension ControllerModel {
    func meetingAskFiles(session: String) -> [MeetingAskFile] {
        meetingAskFileSnapshots(keys: ["g2:" + session], previous: meetingAsk.records[session]?.files ?? [])
    }
    func meetingAskFileSnapshots(keys: [String], previous: [MeetingAskFile] = []) -> [MeetingAskFile] {
        guard let store = workHandoffStore?.meetingFiles, let root = store.root else { return [] }
        let entries = store.meetingFiles(keys: keys)
        var files: [MeetingAskFile] = entries.map { entry in
            let file = entry.file
            var result = MeetingAskFile(id: file.id, revision: file.sha256, name: file.display, status: "unsupported", text: "", notice: "No readable text is available for this file.")
            guard WorkCardFiles.validEntry(file), !file.isLink else { return result }
            if WorkCardFiles.secretFlagged(file) { result.status = "secret-held"; result.notice = "Content appears to contain credentials."; return result }
            if let hold = WorkCardFiles.ocrHold(file) { result.status = file.state == "preparing" ? "pending" : "failed"; result.notice = hold; return result }
            let companion = file.companions.first { $0.kind == "text" }
            if let companion, companion.state != "ready" { result.status = companion.state == "preparing" ? "pending" : "failed"; result.notice = "Text extraction is " + companion.state; return result }
            let name = companion?.stored ?? (file.kind == "text" ? file.stored : "")
            guard !name.isEmpty else { return result }
            do {
                let url = try WorkCardFiles.guardTarget(root: root, folder: entry.folder, name: name)
                let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
                defer { Darwin.close(fd) }
                var statValue = stat()
                guard fstat(fd, &statValue) == 0, statValue.st_mode & S_IFMT == S_IFREG, statValue.st_size <= 100_000 else { throw CocoaError(.fileReadTooLarge) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                let data = try handle.read(upToCount: 100_001) ?? Data()
                guard data.count <= 100_000, let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                if WorkCardFiles.ocrLooksSecret(text) { result.status = "secret-held"; result.notice = "Content appears to contain credentials."; return result }
                result.text = text; result.status = "ready"; result.notice = nil
                result.revision = SHA256.hash(data: Data((file.sha256 + "\n" + text).utf8)).map { String(format: "%02x", $0) }.joined()
            } catch { result.status = "failed"; result.notice = "Text could not be read safely or exceeds 100 KB." }
            return result
        }
        // Explicit tombstones prevent removed local evidence being used by a later phone question.
        let removed = Set(keys.compactMap(WorkCardFiles.meetingID(forKey:)).flatMap { store.manifests[$0]?.files ?? [] }.filter { $0.hiddenAt != nil }.map(\.id))
        for previous in previous where removed.contains(previous.id) {
            files.append(.init(id: previous.id, revision: previous.revision, name: previous.name, status: "removed", text: "", notice: "Removed from this meeting"))
        }
        return files
    }
}

/// Natural-width, leading-aligned actions with consistent gaps and keyboard order.
struct MeetingAskActionsLayout: Layout {
    var gap: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 330, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.points.enumerated() { subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: ProposedViewSize(width: min(subviews[index].sizeThatFits(.unspecified).width, bounds.width), height: nil)) }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: min(width, view.sizeThatFits(.unspecified).width), height: nil))
            if x > 0, x + size.width > width { x = 0; y += row + gap; row = 0 }
            points.append(CGPoint(x: x, y: y)); x += size.width + gap; row = max(row, size.height)
        }
        return (CGSize(width: width, height: y + row), points)
    }
}

struct MeetingAskSettings: View {
    @ObservedObject var store: MeetingAskStore
    @ObservedObject var model: ControllerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meeting assistant").font(COSType.body(13, weight: .semibold))
            Text("Used only when you ask during a meeting. Defaults to Haiku; other chats keep their own models.").font(COSType.body(11)).foregroundStyle(.secondary)
            if let config = store.config {
                COSDropdown("Model", selection: Binding(get: { config.selected.engine + ":" + config.selected.model }, set: { id in
                    if let option = config.models.first(where: { $0.id == id && $0.available }) { Task { await store.configure(option.choice, model: model) } }
                }), options: config.models.map { option in
                    COSDropdownOption(option.id, option.choice.label, note: option.available ? nil : "unavailable",
                                      muted: !option.available, enabled: option.available)
                })
                if let web = config.web {
                    Text(web.available ? "Public web lookup uses \(web.engine?.capitalized ?? "the connected search provider") when a question needs it." : "Public web lookup unavailable: " + (web.reason ?? "No qualified search provider"))
                        .font(COSType.body(11)).foregroundStyle(.secondary)
                }
                ForEach(config.models.filter { !$0.available }) { option in Text(option.choice.label + ": " + (option.reason ?? "Not qualified for meeting assistance")).font(COSType.body(10.5)).foregroundStyle(.secondary) }
            }
            if let notice = store.notice { Text(notice).font(COSType.body(11)).foregroundStyle(.secondary) }
            Button("Refresh connected models") { Task { await store.refreshConfig(model: model) } }.buttonStyle(COSQuietButtonStyle())
        }.padding(12).background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .task { await store.refreshConfig(model: model) }
    }
}

struct LiveAskPanel: View {
    @ObservedObject var state: MeetingAskStore
    @ObservedObject var model: ControllerModel
    let session: String
    var feed: LiveTranscriptFeed?
    var jump: (Int) -> Void = { _ in }
    private let actions = [("catch_up", "Catch me up"), ("summary", "Summarize so far"), ("questions", "Suggest questions"), ("actions", "Action items")]
    private var record: MeetingAskLocalRecord? { state.records[session] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(feed == nil ? "Meeting Ask history" : "Live COS Ask").font(COSType.display(19, weight: .medium)); Spacer(); Button { Task { await state.open(session, model: model) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(COSTextButtonStyle()).help("Refresh saved answers") }
            Text("Ask when you need it. Uses this meeting first.").font(COSType.body(11.5)).foregroundStyle(.secondary)
            if let feed {
                MeetingAskActionsLayout {
                    ForEach(actions, id: \.0) { action, title in
                        Button(title) { state.ask(action: action, question: title == "Catch me up" ? "Catch me up on the last minute" : title, feed: feed, model: model) }
                            .buttonStyle(COSQuietButtonStyle()).disabled(!state.online || state.running.contains(session) || record?.outbox != nil || feed.turns.isEmpty)
                    }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if record?.exchanges.isEmpty != false { Text("Your questions and answers stay with this meeting, including after you leave this screen.").font(COSType.body(12)).foregroundStyle(.secondary) }
                        ForEach(record?.exchanges ?? []) { exchange in answer(exchange) }
                        Color.clear.frame(height: 1).id("ask-bottom")
                    }
                }.onChange(of: record?.exchanges.count) { _, _ in proxy.scrollTo("ask-bottom", anchor: .bottom) }
            }.frame(minHeight: 100, maxHeight: .infinity).clipped()
            if let error = state.errors[session] ?? (!state.online ? state.notice : nil) { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.amber) }
            if record?.outbox != nil {
                MeetingAskActionsLayout {
                    Button("Check pending question") { Task { await state.reconcile(session, model: model) } }.buttonStyle(COSQuietButtonStyle())
                    Button("Retry same question") { state.retryOutbox(session, model: model) }.buttonStyle(COSQuietButtonStyle()).disabled(!state.online || state.running.contains(session))
                }
            }
            if let feed {
                HStack(alignment: .bottom) {
                    TextField("Ask about this meeting", text: Binding(get: { state.draft(session) }, set: { state.setDraft($0, session: session) }), axis: .vertical)
                        .lineLimit(1...6).textFieldStyle(.plain).cosField().disabled(state.config == nil)
                        .onSubmit { send(feed) }
                    Button("Ask") { send(feed) }.buttonStyle(COSPrimaryButtonStyle())
                        .disabled(!state.online || state.running.contains(session) || record?.outbox != nil || state.draft(session).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || feed.turns.isEmpty)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(COSPalette.panel)
        .task(id: session) { await state.open(session, model: model) }
        .onChange(of: session) { previous, _ in _ = state.flush(previous) }
        .onDisappear { _ = state.flush(session) }
    }
    private func send(_ feed: LiveTranscriptFeed) { state.ask(action: "ask", question: state.draft(session), feed: feed, model: model) }
    private func answer(_ exchange: MeetingAskExchange) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(verbatim: exchange.question).font(COSType.body(12, weight: .semibold))
            if let answer = exchange.answer { COSMarkdownView(text: answer, cacheID: exchange.id + exchange.updatedAt, bodySize: 13) }
            else { Text(exchange.terminal ? "No answer · " + exchange.status : "Checking the meeting…").font(COSType.body(12)).foregroundStyle(.secondary) }
            if let reason = exchange.error { Text(MeetingAskText.failure(reason)).font(COSType.body(11)).foregroundStyle(COSPalette.amber) }
            ForEach(exchange.sources) { source in sourceRow(source) }.font(COSType.body(11))
            ForEach(exchange.notices, id: \.self) { Text($0).font(COSType.body(11)).foregroundStyle(COSPalette.amber) }
            HStack {
                Text("Through \(LiveTranscript.stamp(exchange.throughMs, hours: false)) · \(exchange.model ?? exchange.selectedModel.label)").foregroundStyle(.secondary)
                Spacer()
                if exchange.terminal, ["failed", "cancelled", "interrupted"].contains(exchange.status), let feed {
                    Button("Retry") { state.ask(action: exchange.action, question: exchange.question, feed: feed, model: model, retryOf: exchange.id) }
                        .buttonStyle(COSTextButtonStyle()).disabled(state.running.contains(session) || record?.outbox != nil || !state.online)
                }
                if !exchange.terminal { Button("Stop") { Task { await state.cancel(exchange, model: model) } }.buttonStyle(COSTextButtonStyle()) }
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(exchange.answer ?? exchange.question, forType: .string) }.buttonStyle(COSTextButtonStyle())
            }.font(COSType.body(10.5))
        }.padding(12).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 9))
    }
    private func sourceRow(_ source: LiveAskSource) -> some View {
        DisclosureGroup("[\(source.id)] \(source.kind.capitalized) · \(source.title)") {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: source.text).textSelection(.enabled)
                if source.kind == "transcript", let turn = source.turnId, feed?.turns.contains(where: { $0.id == turn }) == true { Button("Show in transcript") { jump(turn) }.buttonStyle(COSTextButtonStyle()) }
                if source.kind == "web", let url = MeetingAskText.safeURL(source.url) {
                    Link(url.host ?? "Open source", destination: url).foregroundStyle(COSPalette.accent)
                    Text("Retained search evidence" + (source.retrievedAt.map { " · " + $0 } ?? "")).foregroundStyle(.secondary)
                }
                if let id = source.recordId {
                    if let row = model.libraryMeetings.first(where: { $0.recordId == id }) { Button("Open earlier meeting") { model.meetingAskOpenRecordID = row.recordId }.buttonStyle(COSTextButtonStyle()) }
                    else { Text("Retained source excerpt · meeting is not in the loaded list").foregroundStyle(.secondary) }
                }
                if source.kind == "memory", let id = source.memoryId, !id.isEmpty {
                    Button("Open COS memory") {
                        model.meetingAskOpenMemory = model.memoryRecords.first(where: { $0.id == id }) ?? ContextRecord(id: id, title: source.title, subtitle: "Retained source excerpt", body: source.text, createdAt: "", filePath: nil)
                    }.buttonStyle(COSTextButtonStyle())
                }
                if source.kind == "file", let id = source.fileId, let file = model.workHandoffStore?.meetingFiles.meetingFiles(keys: ["g2:" + session]).first(where: { $0.file.id == id }), !file.file.isLink {
                    Button("Reveal file") { NSWorkspace.shared.activateFileViewerSelecting([file.folder.appendingPathComponent(file.file.stored)]) }.buttonStyle(COSTextButtonStyle())
                }
            }
        }
    }
}
