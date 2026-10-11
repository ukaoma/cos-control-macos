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
    /// 0.5.282: what the last config read found (checking, online, offline, or a server on another protocol).
    @Published private(set) var reach = MeetingAskReach.checking
    var online: Bool { reach == .online }
    /// 0.5.282: the model a change is switching to while the server has it. Both model controls lock until it answers.
    @Published private(set) var pendingModel: MeetingAskModel?
    /// 0.5.282: why the last model change did not take; cleared by the next change.
    @Published private(set) var modelError: String?
    /// 0.5.281: the line the Ask panel shows after files were dropped or pasted on it, by session.
    @Published private(set) var attachNotes: [String: String] = [:]
    private var attaching: Set<String> = []
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
        var mismatch = false
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
            guard next.protocolVersion == 2, let pairing = next.pairingContext, !pairing.isEmpty else { mismatch = true; throw HelperClientError.commandFailed("Update COS Control and the server together to use meeting assistance.") }
            let scope = next.serverInstanceId + ":" + pairing
            if scope != identity {
                flushAll()
                for task in jobs.values { task.cancel() }; jobs = [:]
                // A different server has none of this Mac's file lists yet.
                records = [:]; loaded = []; errors = [:]; running = []; publishedFiles = [:]; identity = scope
            }
            config = next; reach = .online; notice = nil
            try disk.writeConfig(next)
        } catch {
            // A 404 on config is a server from before meeting assistance; its helper says so in the notice.
            reach = mismatch || (error as? MeetingAskTransportFailure)?.status == 404 ? .outdated : .offline
            notice = message(error)
        }
    }
    /// 0.5.282: the one way either model control (Settings, the Live COS Ask panel) changes the Meeting assistant model.
    /// False when the pick changes nothing (`MeetingAskModelPicker.change`): locked, the model in use, or unavailable.
    /// The lock is taken before this returns, so a second pick while the first is with the server is refused.
    @discardableResult func selectModel(_ id: String, model: ControllerModel) -> Bool {
        guard let choice = MeetingAskModelPicker.change(to: id, config: config, reach: reach, pending: pendingModel) else { return false }
        pendingModel = choice; modelError = nil
        Task { [weak self] in await self?.configure(choice, model: model) }
        return true
    }
    /// What both model controls bind to: the server's selection, written through `selectModel`.
    func modelSelection(model: ControllerModel) -> Binding<String> {
        Binding(get: { [weak self] in self?.config.map(MeetingAskModelPicker.selectedID) ?? "" },
                set: { [weak self] id in self?.selectModel(id, model: model) })
    }
    func configure(_ selection: MeetingAskModel, model: ControllerModel) async {
        pendingModel = selection
        defer { pendingModel = nil }
        do {
            let reply: MeetingAskConfig = try await transport("configure", payload: ["engine": selection.engine, "model": selection.model], model: model, as: MeetingAskConfig.self)
            // The server's answer is its new config: both controls show it now, even if the re-read below fails.
            if var current = config, current.serverInstanceId == reply.serverInstanceId {
                current.selected = reply.selected; current.models = reply.models; config = current
            }
            await refreshConfig(model: model)
            if config?.selected != selection { modelError = "The server kept \(config?.selected.label ?? "its model"). Refresh connected models to check." }
        } catch { notice = message(error); modelError = message(error) }
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
        let question = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        // Rule C (0.5.281, MeetingAskComposerIntake.localFiles says exactly what qualifies): a question that is nothing but
        // the path of a file on this Mac is that file, dropped or pasted somewhere the composer could not catch it. It is
        // attached to this meeting and never sent. Its path text leaves the composer only once the file is in.
        if action == "ask", let urls = MeetingAskComposerIntake.localFiles(in: question, isFile: MeetingAskComposerIntake.regularFileExists) {
            // A second Return while the first copy runs is the same file again, not a second attach.
            guard attaching.insert(session).inserted else { return }
            Task { [weak self] in
                guard let self else { return }
                defer { attaching.remove(session) }
                let added = await attach(.files(urls), session: session, model: model, pathOnly: true)
                if !added.isEmpty, draft(session).trimmingCharacters(in: .whitespacesAndNewlines) == question { setDraft("", session: session); _ = flush(session) }
            }
            return
        }
        guard let config, online, !running.contains(session), records[session]?.outbox == nil, records[session] != nil, !feed.turns.isEmpty else { return }
        guard !question.isEmpty else { return }
        attachNotes[session] = nil
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
    /// 0.5.281: files dropped on or pasted into the Ask panel go to this meeting's Files through the Files box's own intake
    /// (`intakeMeeting` for files and drops, `pasteMeeting` for image data), never into the question. Returns the names
    /// that landed; a refusal is the intake's own line, shown in the panel and in Files shared in this meeting.
    @discardableResult func attach(_ attachment: MeetingAskAttachment, session: String, model: ControllerModel, pathOnly: Bool = false) async -> [String] {
        let key = "g2:" + session
        guard let files = model.workHandoffStore?.meetingFiles, files.enabled, WorkCardFiles.meetingID(forKey: key) != nil else {
            attachNotes[session] = MeetingAskText.attachUnavailable; return []
        }
        let info = WorkMeetingInfo(recordId: "", title: "Live meeting", date: "")
        let before = Set(files.meetingFiles(keys: [key]).map(\.file.id))
        switch attachment {
        case .files(let urls): await files.intakeMeeting(urls: urls, key: key, info: info)
        case .image(let data): await files.pasteMeeting(MeetingPastePayload(urls: [], image: data), key: key, info: info)
        case .providers(let providers): await files.intakeMeeting(providers: providers, key: key, info: info)
        }
        let added = files.meetingFiles(keys: [key]).filter { !before.contains($0.file.id) }.map(\.file.display)
        attachNotes[session] = MeetingAskText.attached(added, pathOnly: pathOnly)
        return added
    }
    func observeFiles(_ files: WorkCardFileStore, model: ControllerModel) {
        fileObserver = files.$manifests.debounce(for: .milliseconds(600), scheduler: RunLoop.main).sink { [weak self, weak model] manifests in
            guard let self, let model else { return }
            let sessions = manifests.keys.compactMap { key -> String? in
                let prefix = "meetingctx:g2:"
                return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
            }
            // Any file change republishes the manifests of every meeting; send only the lists that changed.
            Task { for session in sessions { _ = await self.registerFiles(session, model: model, onlyIfChanged: true) } }
        }
    }
    /// `onlyIfChanged` is for the background observer only. The send before a question stays unconditional, so the
    /// server can never lack a file that question references.
    @discardableResult func registerFiles(_ session: String, model: ControllerModel, onlyIfChanged: Bool = false) async -> Bool {
        while fileSyncing.contains(session), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
        guard !Task.isCancelled else { return false }
        fileSyncing.insert(session)
        defer { fileSyncing.remove(session) }
        if config == nil { await refreshConfig(model: model) }
        ensure(session)
        guard let config, online else { return false }
        let ticket = identity
        let files = model.meetingAskFiles(session: session)
        if onlyIfChanged, !MeetingAskFileSync.needsRegistration(published: publishedFiles[session], current: files) { return true }
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
/// What the Ask panel was handed to attach: local files, image data (a copied screenshot), or a drop's providers.
enum MeetingAskAttachment {
    case files([URL])
    case image(Data)
    case providers([NSItemProvider])
}
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
            // 0.5.282: the same control the Live COS Ask panel shows, so a change in either shows in both.
            MeetingAskModelControl(store: store, model: model)
            if let config = store.config {
                if let web = config.web {
                    Text(web.available ? "Public web lookup uses \(web.engine?.capitalized ?? "the connected search provider") when a question needs it." : "Public web lookup unavailable: " + (web.reason ?? "No qualified search provider"))
                        .font(COSType.body(11)).foregroundStyle(.secondary)
                }
                ForEach(config.models.filter { !$0.available }) { option in Text(option.choice.label + ": " + MeetingAskModelPicker.reason(option.reason)).font(COSType.body(10.5)).foregroundStyle(.secondary) }
            }
            if let notice = store.notice { Text(notice).font(COSType.body(11)).foregroundStyle(.secondary) }
            Button("Refresh connected models") { Task { await store.refreshConfig(model: model) } }.buttonStyle(COSQuietButtonStyle())
        }.padding(12).background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .task { await store.refreshConfig(model: model) }
    }
}

/// 0.5.282: the Meeting assistant model control (`MeetingAskModelPicker` has the rules). Settings draws it full width
/// with its "Model" label; the Live COS Ask panel draws it `compact`, one line under the composer. Both bind to
/// `MeetingAskStore.modelSelection`, so a pick in either runs the same `configure` and shows in both. Locked (dimmed,
/// with the reason under it) while a change is with the server, or while the server is offline or on another protocol.
struct MeetingAskModelControl: View {
    @ObservedObject var store: MeetingAskStore
    @ObservedObject var model: ControllerModel
    var compact = false
    var body: some View {
        let lock = store.modelLock
        VStack(alignment: .leading, spacing: 4) {
            if let config = store.config {
                if compact {
                    HStack(spacing: 8) {
                        Text("Model").font(COSType.body(11.5)).foregroundStyle(.secondary).accessibilityHidden(true)
                        dropdown(config, showsLabel: false, locked: lock != nil).frame(maxWidth: 240)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    dropdown(config, showsLabel: true, locked: lock != nil)
                }
            }
            if let lock { Text(lock).font(COSType.body(compact ? 10.5 : 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            // Settings shows the same failure in its notice line; the panel shows no notice while online.
            if compact, let error = store.modelError {
                Text(error).font(COSType.body(10.5)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func dropdown(_ config: MeetingAskConfig, showsLabel: Bool, locked: Bool) -> some View {
        COSDropdown("Model", selection: store.modelSelection(model: model), options: Self.options(config), showsLabel: showsLabel)
            .disabled(locked)
    }
    /// The list both surfaces open: the picker's rows, an unavailable model muted, unchoosable, its reason beside it.
    static func options(_ config: MeetingAskConfig) -> [COSDropdownOption<String>] {
        MeetingAskModelPicker.rows(config).map { row in
            COSDropdownOption(row.id, row.title, note: row.note, muted: !row.enabled, enabled: row.enabled)
        }
    }
}

extension MeetingAskStore {
    /// Why the model controls are locked right now, or nil.
    var modelLock: String? { MeetingAskModelPicker.lock(config: config, reach: reach, pending: pendingModel) }
}

struct LiveAskPanel: View {
    @ObservedObject var state: MeetingAskStore
    @ObservedObject var model: ControllerModel
    let session: String
    var feed: LiveTranscriptFeed?
    var jump: (Int) -> Void = { _ in }
    private let actions = [("catch_up", "Catch me up"), ("summary", "Summarize so far"), ("questions", "Suggest questions"), ("actions", "Action items")]
    private var record: MeetingAskLocalRecord? { state.records[session] }
    @State private var dropTargeted = false
    /// 0.5.281: the live panel takes files anywhere on it, through the Files box's own drop, when this meeting can hold them.
    private var takesFiles: Bool {
        feed != nil && model.workHandoffStore?.meetingFiles.enabled == true && WorkCardFiles.meetingID(forKey: "g2:" + session) != nil
    }
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
                if let note = state.attachNotes[session] {
                    Text(note).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let files = model.workHandoffStore?.meetingFiles, let id = WorkCardFiles.meetingID(forKey: "g2:" + session) {
                    WorkCardFlashView(files: files, workID: id)
                }
                HStack(alignment: .bottom) {
                    // 0.5.281: a drop or a paste of files here attaches them to this meeting and leaves the question as it was.
                    MeetingAskComposer(text: Binding(get: { state.draft(session) }, set: { state.setDraft($0, session: session) }),
                                       placeholder: "Ask about this meeting", enabled: state.config != nil,
                                       onSubmit: { send(feed) },
                                       onAttach: { attachment in Task { await state.attach(attachment, session: session, model: model) } })
                        .cosField()
                    Button("Ask") { send(feed) }.buttonStyle(COSPrimaryButtonStyle())
                        .disabled(!state.online || state.running.contains(session) || record?.outbox != nil || state.draft(session).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || feed.turns.isEmpty)
                }
                // 0.5.282: the model the next question goes to, switchable here (the same control and setting as
                // Settings). An answer already running keeps its model, shown in its footer. Live only: a saved
                // meeting's history asks nothing, so it has no model to choose.
                MeetingAskModelControl(store: state, model: model, compact: true)
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(COSPalette.panel)
        // The Files box's own drop (files only, on the panel itself, never in an overlay); the stroke only draws.
        .modifier(MeetingFilesDrop(enabled: takesFiles, targeted: $dropTargeted) { providers in
            Task { await state.attach(.providers(providers), session: session, model: model) }
        })
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 9).stroke(COSPalette.gold, lineWidth: 1.5).allowsHitTesting(false) } }
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

// MARK: - The Ask composer (0.5.281)

/// The Live COS Ask question box: plain text, 1 to 6 lines, Return asks, Shift-Return or Option-Return starts a new line.
///
/// WHY AN APPKIT TEXT VIEW (Miles, 2026-10-10, on 0.5.280): the box was a SwiftUI `TextField`. A drop on it lands on the
/// AppKit text view under it (the field editor, the deepest view registered for the drag's types), which takes a file
/// as its path in plain text, so a screenshot thumbnail dropped on it became `/var/folders/.../Screenshot ... .png` as
/// typed text and that path was asked as the question with no file. A SwiftUI `.onDrop` on or around the field never
/// sees that drop, and a pasted image did nothing at all. Owning the text view is the one place both can be caught:
/// `MeetingAskComposerTextView` reads a drop or a paste, and when `MeetingAskComposerIntake.route` says it is files it
/// hands them to `onAttach` (this meeting's Files intake) and inserts nothing. Text still types and pastes as text.
struct MeetingAskComposer: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var enabled = true
    var onSubmit: () -> Void
    var onAttach: (MeetingAskAttachment) -> Void
    static let maxLines = 6
    /// The `.cosField()` face's font (DM Sans 12.5), as AppKit needs it.
    static var font: NSFont {
        _ = COSType.body(12.5)
        return NSFontManager.shared.font(withFamily: "DM Sans", traits: [], weight: 5, size: 12.5) ?? .systemFont(ofSize: 12.5)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MeetingAskComposerScroll()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        let view = MeetingAskComposerTextView.make(font: Self.font)
        view.delegate = context.coordinator
        scroll.documentView = view
        apply(to: view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? MeetingAskComposerTextView else { return }
        apply(to: view)
    }

    private func apply(to view: MeetingAskComposerTextView) {
        if !view.hasMarkedText(), view.string != text { view.string = text; view.needsDisplay = true }
        if view.placeholder != placeholder { view.placeholder = placeholder }
        if view.isEditable != enabled { view.isEditable = enabled; view.isSelectable = enabled }
        view.onAttach = onAttach
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let view = scroll.documentView as? MeetingAskComposerTextView else { return nil }
        let width = max(40, proposal.width ?? 240)
        return CGSize(width: width, height: view.fittingHeight(width: width, maxLines: Self.maxLines))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MeetingAskComposer
        init(_ parent: MeetingAskComposer) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) { textView.insertNewlineIgnoringFieldEditor(nil); return true }
            parent.onSubmit()
            return true
        }
    }
}

/// The composer's scroll view keeps its text view exactly as wide as what it shows, so a long question wraps instead of
/// running off to the right (the first offscreen render clipped it to its tail: a 240 pt starting width plus the
/// autoresizing delta). The text view also starts 0 pt wide, so either one alone holds the width; the production-shell
/// canary's "wraps at the field's width" check fails only when both are gone (mutants M16, M17, M18, 2026-10-10).
final class MeetingAskComposerScroll: NSScrollView {
    override func tile() {
        super.tile()
        guard let text = documentView as? NSTextView else { return }
        let size = contentSize
        if text.minSize.height != size.height { text.minSize = NSSize(width: 0, height: size.height) }
        if abs(text.frame.width - size.width) > 0.5 {
            text.setFrameSize(NSSize(width: size.width, height: max(text.frame.height, size.height)))
            text.sizeToFit()
        }
    }
}

/// The composer's text view. A drop or a paste that `MeetingAskComposerIntake.route` calls files goes to `onAttach`
/// and changes nothing in the text; anything else is the stock plain-text behavior.
final class MeetingAskComposerTextView: NSTextView {
    var onAttach: ((MeetingAskAttachment) -> Void)?
    var placeholder = "" {
        didSet { setAccessibilityPlaceholderValue(placeholder); setAccessibilityLabel(placeholder); needsDisplay = true }
    }
    /// Where Command-V reads: the general pasteboard. A check hands its own, so no test touches the clipboard.
    var pasteSource: NSPasteboard = .general

    static func make(font: NSFont) -> MeetingAskComposerTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(containerSize: NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = MeetingAskComposerTextView(frame: NSRect(x: 0, y: 0, width: 0, height: 17), textContainer: container)
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = font
        view.textColor = .labelColor
        view.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // The question is the user's words: no curly quotes or em dashes typed in on their behalf.
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.updateDragTypeRegistration()
        return view
    }

    /// Image data and files are readable here (Paste is enabled for a copied screenshot), and `receive` takes them.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        for extra in [NSPasteboard.PasteboardType.fileURL, .png, .tiff] where !types.contains(extra) { types.append(extra) }
        return types
    }
    /// What a drag must carry for this view to take it: words, a link, files, or PNG or TIFF data. Nothing else, so a
    /// file promise (Photos, Mail) or a movie is never this view's: it falls through to the Ask panel, whose drop is the
    /// Files box's own and keeps promises (an NSTextView takes those by default and would type their names).
    static let dragTypes: [NSPasteboard.PasteboardType] = [.string, .rtf, .html, .URL, .fileURL, .png, .tiff,
        .init("NSStringPboardType"), .init("NeXT Rich Text Format v1.0 pasteboard type"), .init("Apple HTML pasteboard type"),
        .init("Apple URL pasteboard type"), .init("WebURLsWithTitlesPboardType"), .init("NSFilenamesPboardType"),
        .init("Apple PNG pasteboard type"), .init("NeXT TIFF v4.0 pasteboard type")]
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { Self.dragTypes }
    /// AppKit registers a text view's drag types only once it is in a window (observed 2026-10-10: none until this runs there).
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateDragTypeRegistration() }

    /// What a pasteboard is for this question. Asked on every drag move, so it reads types, file URLs and the text, never
    /// image bytes (those are read once, by `receive`).
    func route(_ pasteboard: NSPasteboard) -> MeetingAskComposerIntake.Route {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return MeetingAskComposerIntake.route(types: (pasteboard.types ?? []).map(\.rawValue), fileURLs: urls,
                                              text: pasteboard.string(forType: .string), draft: string,
                                              isFile: MeetingAskComposerIntake.regularFileExists)
    }

    /// A drop or a paste that is files goes to `onAttach`, and the text is untouched. True when it was taken. The image
    /// bytes are read here, inside the drop or the paste, with the Files box's own reader.
    @discardableResult func receive(_ pasteboard: NSPasteboard) -> Bool {
        switch route(pasteboard) {
        case .attachFiles(let urls): onAttach?(.files(urls)); return true
        case .attachImage:
            guard let image = WorkCardFileStore.meetingPastePayload(pasteboard).image else { return false }
            onAttach?(.image(image)); return true
        case .text: return false
        }
    }

    // Text goes to the stock paste, which reads the general pasteboard, so it runs only when that is the source: a check
    // that hands its own pasteboard never reads the person's clipboard, even when something is routed wrong.
    private var stockPasteAllowed: Bool { pasteSource == NSPasteboard.general }
    override func paste(_ sender: Any?) { if !receive(pasteSource), stockPasteAllowed { super.paste(sender) } }
    override func pasteAsPlainText(_ sender: Any?) { if !receive(pasteSource), stockPasteAllowed { super.pasteAsPlainText(sender) } }
    override func pasteAsRichText(_ sender: Any?) { if !receive(pasteSource), stockPasteAllowed { super.pasteAsRichText(sender) } }

    private func takes(_ info: NSDraggingInfo) -> Bool {
        if case .text = route(info.draggingPasteboard) { return false }
        return true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { takes(sender) ? .copy : super.draggingEntered(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { takes(sender) ? .copy : super.draggingUpdated(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { takes(sender) || super.prepareForDragOperation(sender) }
    /// The drop itself: files never reach `super`, which would insert their paths.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { receive(sender.draggingPasteboard) || super.performDragOperation(sender) }

    override func didChangeText() { super.didChangeText(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.placeholderTextColor]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height), withAttributes: attributes)
    }

    /// One line at least, `maxLines` at most (then it scrolls), at this width.
    func fittingHeight(width: CGFloat, maxLines: Int) -> CGFloat {
        guard let layout = layoutManager, let container = textContainer else { return 17 }
        let line = ceil(layout.defaultLineHeight(for: font ?? NSFont.systemFont(ofSize: 12.5)))
        if abs(container.containerSize.width - width) > 0.5 { container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude) }
        layout.ensureLayout(for: container)
        let used = ceil(layout.usedRect(for: container).height)
        return min(max(line, used), line * CGFloat(maxLines))
    }
}
