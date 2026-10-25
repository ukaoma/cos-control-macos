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
    @Published private(set) var loadingHistory: Set<String> = []
    @Published private(set) var savedSnapshots: [String: MeetingAskSnapshot] = [:]
    @Published private(set) var sourceHealth: [String: String] = [:]
    @Published private(set) var loadingSnapshots: Set<String> = []
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
    /// Home city for fact checks (server 6.71.13). Its own store: the server owns it, not the meeting config.
    let homeArea = HomeAreaStore()
    /// 0.5.322: live cues v2 on or off (server 6.76.2). Its own store, like the home city: the server owns the switch.
    let liveCues = LiveCuesStore()
    /// 0.5.327: rating live cues (server 6.79.0): Memories' cue review and the Cues view beside Live COS Ask read this one store.
    let cueVerdicts = CueVerdictsStore()
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
    /// The meeting-ask helper's timeout (0.5.343: named, so an answer's build-up waits at least this long).
    static let helperTimeout: TimeInterval = 30
    func transport<T: Decodable>(_ operation: String, payload: [String: Any] = [:], model: ControllerModel, as: T.Type) async throws -> T {
        let data = try JSONSerialization.data(withJSONObject: ["operation": operation, "payload": payload])
        guard data.count <= 1_000_000 else { throw HelperClientError.commandFailed("Meeting context exceeds the request limit.") }
        if let injectedTransport { return try JSONDecoder().decode(T.self, from: await injectedTransport(operation, data)) }
        let reply = try await model.runHelper(["meeting-ask"], timeout: Self.helperTimeout, stdinData: data)
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
                records = [:]; loaded = []; errors = [:]; running = []; publishedFiles = [:]; savedSnapshots = [:]; sourceHealth = [:]; config = nil; identity = ""
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
                records = [:]; loaded = []; errors = [:]; running = []; publishedFiles = [:]; savedSnapshots = [:]; sourceHealth = [:]; identity = scope
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
        if loadingHistory.contains(session) {
            // Copy full context also awaits open: let it finish loading before it captures the answers.
            while loadingHistory.contains(session), !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            return
        }
        loadingHistory.insert(session)
        defer { loadingHistory.remove(session) }
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
    func loadSavedSnapshot(_ session: String, model: ControllerModel) async {
        guard let config, online, !loadingSnapshots.contains(session) else { return }
        let ticket = identity
        loadingSnapshots.insert(session)
        defer { loadingSnapshots.remove(session) }
        do {
            let snapshot: MeetingAskSnapshot = try await transport("transcript", payload: ["sessionId": session, "serverInstanceId": config.serverInstanceId], model: model, as: MeetingAskSnapshot.self)
            guard ticket == identity else { return }
            guard snapshot.validSaved else { throw HelperClientError.commandFailed("This recording is not ready for saved-meeting questions. Open its live transcript or refresh after saving.") }
            savedSnapshots[session] = snapshot; errors[session] = nil
        } catch { if ticket == identity { savedSnapshots[session] = nil; errors[session] = message(error) } }
    }
    func checkSources(_ session: String, model: ControllerModel) async {
        guard let config, online else { return }
        let ticket = identity
        do {
            let health: MeetingAskSourceHealth = try await transport("context-status", model: model, as: MeetingAskSourceHealth.self)
            let context: MeetingAskOrientationReply = try await transport("context", payload: ["sessionId": session, "serverInstanceId": config.serverInstanceId], model: model, as: MeetingAskOrientationReply.self)
            guard ticket == identity else { return }
            let time = Date().formatted(date: .omitted, time: .shortened)
            sourceHealth[session] = "Memory: \(health.memory.available ? String(health.memory.total) + " available" : "unavailable"). Threads: \(health.threads.available ? String(health.threads.total) + " available" : "unavailable"). Domain: \(context.orientation.domain ?? "not confirmed"). Checked \(time). Last sync is not reported by this source."
        } catch { if ticket == identity { sourceHealth[session] = "Source status could not be checked. Refresh to retry." } }
    }
    func saveFollowUp(_ exchange: MeetingAskExchange, text: String, meeting: LibraryMeeting, model: ControllerModel) async -> Bool {
        guard let config, online, config.capabilities?.followUpReview == true, exchange.status == "completed", exchange.serverInstanceId == config.serverInstanceId else { return false }
        let ticket = identity
        do {
            let reply: MeetingAskFollowUpReply = try await transport("follow-up", payload: ["serverInstanceId": config.serverInstanceId, "requestId": exchange.requestId, "text": text, "meeting": ["domain": meeting.domain, "month": meeting.month, "filename": meeting.filename, "recordId": meeting.recordId]], model: model, as: MeetingAskFollowUpReply.self)
            guard ticket == identity, reply.ok, !reply.item.id.isEmpty else { return false }
            errors[exchange.sessionId] = nil
            notice = reply.item.status == "review" ? "Saved in Work Review. Review it before adding it to your work." : "This follow-up was already reviewed."
            return true
        } catch { if ticket == identity { errors[exchange.sessionId] = "Save was not confirmed. Your follow-up draft is retained; retry the same words after checking COS." }; return false }
    }
    func ask(action: String, question: String, feed: LiveTranscriptFeed, model: ControllerModel, retryOf: String? = nil) {
        let now = feed.endedAt ?? Date()
        let elapsed = max(feed.turns.map(\.elapsedMs).max() ?? 0, Int(max(0, now.timeIntervalSince(feed.startTime ?? now)) * 1000))
        let turns = feed.turns.map { MeetingAskTurn(id: $0.id, elapsedMs: $0.elapsedMs, speaker: $0.speaker, text: $0.text) }
        ask(action: action, question: question, session: feed.sessionId, turns: turns, elapsed: elapsed, model: model, retryOf: retryOf)
    }
    func askSaved(action: String, question: String, session: String, model: ControllerModel, retryOf: String? = nil) {
        guard let snapshot = savedSnapshots[session], snapshot.validSaved else { return }
        ask(action: action, question: question, session: session, turns: snapshot.turns, elapsed: snapshot.elapsedMs, model: model, retryOf: retryOf)
    }
    private func ask(action: String, question: String, session: String, turns: [MeetingAskTurn], elapsed: Int, model: ControllerModel, retryOf: String? = nil) {
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
        guard let config, online, !running.contains(session), records[session]?.outbox == nil, records[session] != nil, !turns.isEmpty else { return }
        guard !question.isEmpty else { return }
        attachNotes[session] = nil
        // The caller freezes original turn IDs and cutoff before file registration or transport.
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
    /// that landed; a refusal is the intake's own line, shown in the panel and under the live Files row.
    @discardableResult func attach(_ attachment: MeetingAskAttachment, session: String, model: ControllerModel, pathOnly: Bool = false) async -> [String] {
        let key = LibraryMeeting.captureContextKey(session)
        guard let files = model.workHandoffStore?.meetingFiles, files.enabled, WorkCardFiles.meetingID(forKey: key) != nil else {
            attachNotes[session] = MeetingAskText.attachUnavailable; return []
        }
        let info = model.liveMeetingFileInfo(session)
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
                for prefix in ["meetingctx:g2:", "meetingctx:mac:"] where key.hasPrefix(prefix) {
                    return String(key.dropFirst(prefix.count))
                }
                return nil
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

extension ControllerModel {
    func meetingAskFiles(session: String) -> [MeetingAskFile] {
        meetingAskFileSnapshots(keys: [LibraryMeeting.captureContextKey(session)], previous: meetingAsk.records[session]?.files ?? [])
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
    @State private var showUnavailableModels = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meeting assistant").font(COSType.body(13, weight: .semibold))
            Text("Used only when you ask during a meeting. Defaults to Sonnet; other chats keep their own models.").font(COSType.body(11)).foregroundStyle(.secondary)
            // 0.5.282: the same control the Live COS Ask panel shows, so a change in either shows in both.
            MeetingAskModelControl(store: store, model: model)
            if let config = store.config {
                if let web = config.web {
                    Text(web.available ? "Public web lookup uses \(web.engine?.capitalized ?? "the connected search provider") when a question needs it." : "Public web lookup unavailable: " + (web.reason ?? "No qualified search provider"))
                        .font(COSType.body(11)).foregroundStyle(.secondary)
                }
                MeetingAskModelDetails(options: config.models.filter { !$0.available }, expanded: $showUnavailableModels)
            }
            if let notice = store.notice { Text(notice).font(COSType.body(11)).foregroundStyle(.secondary) }
            Button("Refresh connected models") {
                Task { await store.refreshConfig(model: model); await store.homeArea.load(HomeCitySettings.run(model)) }
            }.buttonStyle(COSQuietButtonStyle())
            HomeCitySettings(store: store.homeArea, model: model)
            LiveCuesSettingsRow(store: store.liveCues, model: model)
        }.padding(12).background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .task { await store.refreshConfig(model: model); await store.homeArea.load(HomeCitySettings.run(model)) }
    }
}

/// Home city (server 6.71.13), inside the Meeting assistant card: where a fact check starts when a question leaves
/// it implicit. Not drawn on a server without the route (404) or before the server has answered. The server
/// checks the label; its refusal shows under the field in its own words. Blank plus Save clears it.
struct HomeCitySettings: View {
    @ObservedObject var store: HomeAreaStore
    @ObservedObject var model: ControllerModel
    static func run(_ model: ControllerModel) -> HomeAreaStore.Run {
        { arguments, input in try await model.runHelper(arguments, timeout: 20, stdinData: input) }
    }
    var body: some View {
        if store.visible {
            VStack(alignment: .leading, spacing: 6) {
                Text("Home city").font(COSType.body(12, weight: .semibold))
                HStack(spacing: 8) {
                    TextField(HomeArea.placeholder, text: $store.draft)
                        .textFieldStyle(.plain)
                        .cosField()
                        .accessibilityLabel("Home city")
                        .onSubmit(save)
                    Button("Save", action: save)
                        .buttonStyle(COSQuietButtonStyle())
                        .disabled(store.saving || !store.changed)
                }
                Text(HomeArea.caption).font(COSType.body(11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = store.error {
                    Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(store.effectiveLine).font(COSType.body(11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
        }
    }
    private func save() {
        guard store.changed, !store.saving else { return }
        Task { await store.save(Self.run(model)) }
    }
}

/// 0.5.322 (Miles, 2026-10-17): Live cues on or off, inside the Meeting assistant card, so nobody edits the server's
/// .env by hand. A switch and one line in words (LiveCues in Sources/MeetingAskCore.swift) for every state the server
/// can be in. The switch is drawn only for a server that answered; set in the server's environment it shows and cannot
/// move. "Add a Jev or SubQ key" opens Decision models below, where the Jev and SubQ key fields are. Read on appear and
/// whenever the server starts, stops or changes version, so a stopped or updated server never leaves the last answer.
struct LiveCuesSettingsRow: View {
    @ObservedObject var store: LiveCuesStore
    @ObservedObject var model: ControllerModel
    static func run(_ model: ControllerModel) -> LiveCuesStore.Run {
        { arguments, input in try await model.runHelper(arguments, timeout: 20, stdinData: input) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let settings = store.settings {
                Toggle(LiveCues.title, isOn: Binding(get: { store.pending ?? settings.enabled },
                                                     set: { on in Task { await store.set(on, run: Self.run(model)) } }))
                    .toggleStyle(COSSwitchStyle())
                    .font(COSType.body(12, weight: .semibold))
                    .disabled(!store.switchEnabled)
                    .accessibilityIdentifier("settings-live-cues")
            } else {
                HStack(spacing: 8) {
                    Text(LiveCues.title).font(COSType.body(12, weight: .semibold))
                    Spacer(minLength: 8)
                    if store.busy { ProgressView().controlSize(.small) }
                }
            }
            Text(store.line).font(COSType.body(11))
                .foregroundStyle(LiveCues.isProblem(store.state) && store.pending == nil ? AnyShapeStyle(COSPalette.amber) : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
            if let note = store.note {
                Text(note).font(COSType.body(11)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            }
            switch store.action {
            case .addDecisionKey:
                Button(LiveCues.addKeyLabel) { model.panelScrollTarget = LiveCues.decisionKeysAnchor }
                    .buttonStyle(COSTextButtonStyle())
            case .checkAgain:
                Button(LiveCues.checkAgainLabel) { Task { await store.load(Self.run(model)) } }
                    .buttonStyle(COSQuietButtonStyle())
                    .disabled(store.busy)
            case .none:
                EmptyView()
            }
            // 0.5.329: the spend limits, only from a server that reports them (6.79.2); an older one shows the switch alone.
            if let limits = store.settings?.limits {
                LiveCuesLimitsRows(store: store, limits: limits, run: Self.run(model))
            }
            Text(LiveCues.glassesLine).font(COSType.body(11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
        .task(id: "\(model.status.running) \(model.status.version ?? "")") { await store.load(Self.run(model)) }
    }
}

/// 0.5.329 (Miles, 2026-10-19): cap live cue spend from Settings. The bar (a slider: lower gives more cues), the most cues
/// a meeting may get, the shortest gap between two cues and the daily writer limit, each inside the server's bounds, and
/// today's usage. A limit set in the server's .env shows its value with "Set in .env" and cannot move. A move is sent
/// after the person stops (LiveCues.limitsDebounce), and the row shows "Saving…" until the server's answer, whose values
/// it then shows: never ahead of the server.
struct LiveCuesLimitsRows: View {
    @ObservedObject var store: LiveCuesStore
    let limits: LiveCuesLimits
    let run: LiveCuesStore.Run

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let gate = limits.values[.gate] { bar(gate) }
            ForEach([LiveCuesLimits.Key.maxCuesPerMeeting, .cooldownSeconds, .dailyWriterCalls], id: \.self) { key in
                if let limit = limits.values[key] { stepper(key, limit) }
            }
            if !store.pendingLimits.isEmpty {
                Text(LiveCues.savingLine).font(COSType.body(11)).foregroundStyle(.secondary)
            }
            if let note = store.limitsNote {
                Text(note).font(COSType.body(11)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            }
            if let usage = limits.usage {
                Text(LiveCues.usageLine(usage)).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(COSType.body(12))
        .padding(.top, 2)
    }

    private func locked(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(COSType.mono(11.5)).monospacedDigit()
            Text(LiveCues.envNote).font(COSType.body(11)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func bar(_ limit: LiveCuesLimit) -> some View {
        let shown = store.limitValue(.gate) ?? limit.value
        if limit.locked {
            locked(LiveCues.barTitle, LiveCues.gateText(limit.value))
        } else {
            let steps = LiveCues.gateSteps(limit)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(LiveCues.barTitle)
                    Spacer(minLength: 8)
                    Text(LiveCues.gateText(shown)).font(COSType.mono(11.5)).monospacedDigit()
                }
                Slider(value: Binding(get: { shown }, set: { store.propose(.gate, (($0 * 100).rounded()) / 100, run: run) }),
                       in: (steps.first ?? limit.value)...(steps.last ?? limit.value), step: 0.05)
                    .controlSize(.small)
                    .accessibilityLabel(LiveCues.barTitle)
                    .accessibilityValue(LiveCues.gateText(shown))
                HStack {
                    Text(LiveCues.moreCues)
                    Spacer(minLength: 8)
                    Text(LiveCues.fewerCues)
                }
                .font(COSType.body(10.5))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func title(_ key: LiveCuesLimits.Key) -> String {
        switch key {
        case .gate: LiveCues.barTitle
        case .maxCuesPerMeeting: LiveCues.maxCuesTitle
        case .cooldownSeconds: LiveCues.gapTitle
        case .dailyWriterCalls: LiveCues.dailyTitle
        }
    }

    @ViewBuilder
    private func stepper(_ key: LiveCuesLimits.Key, _ limit: LiveCuesLimit) -> some View {
        let shown = Int((store.limitValue(key) ?? limit.value).rounded())
        if limit.locked {
            locked(title(key), LiveCues.countText(key, Int(limit.value.rounded())))
        } else {
            let ladder = LiveCues.ladder(key, limit)
            let index = ladder.firstIndex(of: shown) ?? ladder.lastIndex { $0 <= shown } ?? 0
            COSStepper(title(key), value: Binding(get: { index }, set: { store.propose(key, Double(ladder[$0]), run: run) }),
                       in: 0...max(0, ladder.count - 1), valueText: LiveCues.countText(key, shown))
        }
    }
}

/// Transcription (server 6.72.0): its own Settings card. Preview model, HQ model, Second opinion, the resolver switch,
/// one line saying when a change takes effect, an Advanced disclosure for the front end and the quiet gate, and Install
/// Parakeet when the server can install it. Not drawn on a server without the route (404) or before the server has
/// answered. Every change is one PUT and the card then shows what the server answered; a refusal shows in its words.
/// The install button is never offered while a recording is live (ControllerModel.recordingCount).
struct TranscriptionSettingsCard: View {
    @ObservedObject var store: TranscriptionSettingsStore
    @ObservedObject var model: ControllerModel
    @State private var showAdvanced: Bool
    init(store: TranscriptionSettingsStore, model: ControllerModel, advancedOpen: Bool = false) {
        self.store = store; self.model = model; _showAdvanced = State(initialValue: advancedOpen)
    }
    static func run(_ model: ControllerModel) -> TranscriptionSettingsStore.Run {
        { arguments, input in try await model.runHelper(arguments, timeout: 20, stdinData: input) }
    }
    var body: some View {
        if store.visible, let settings = store.settings {
            card(settings)
        }
    }
    private func card(_ settings: SttSettings) -> some View {
        let recording = model.recordingCount > 0
        return VStack(alignment: .leading, spacing: 8) {
            Text("Transcription").font(COSType.body(13, weight: .semibold))
            dictationPicker(settings)
            picker("Preview model", .preview, settings.preview)
            quiet(Transcription.previewLine(settings))
            picker("HQ model", .hq, settings.hq)
            quiet(Transcription.effectiveLine(settings.hq))
            picker("Second opinion", .secondOpinion, settings.secondOpinion)
            quiet(Transcription.effectiveLine(settings.secondOpinion))
            Text(Transcription.appliesLine(settings)).font(COSType.body(11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // The server's refusal (or why it was not reached), next to the choices it is about.
            if let error = store.error {
                Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Refine with second opinion", isOn: Binding(
                get: { store.settings?.resolverEnabled ?? false },
                set: { on in Task { await store.set("resolver", .bool(on), run: Self.run(model)) } }))
                .toggleStyle(COSSwitchStyle())
                .font(COSType.body(12))
                .disabled(store.pending != nil)
            // On but not refining (6.72.0 resolver.effective false): the switch stays usable, this says why.
            quiet(Transcription.resolverInactiveLine(settings))
            parakeetRow(settings.parakeet, recording: recording)
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    picker("Front end", .frontEnd, settings.frontEnd)
                    picker("Quiet detection", .quietGate, settings.quietGate)
                }.padding(.top, 6)
            }
            .font(COSType.body(12))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
    }
    private func picker(_ label: String, _ key: Transcription.Key, _ choice: SttChoice) -> some View {
        COSDropdown(label, selection: Binding(
            get: { store.settings.map { Self.selected($0, key) } ?? choice.selected },
            set: { id in
                guard id != choice.selected else { return }
                Task { await store.set(key.rawValue, .string(id), run: Self.run(model)) }
            }), options: Transcription.rows(choice).map { row in
                COSDropdownOption(row.id, row.title, note: row.note, muted: !row.enabled, enabled: row.enabled)
            }, labelWidth: 112)
            .font(COSType.body(12))
            .disabled(store.pending != nil)
    }
    static func selected(_ settings: SttSettings, _ key: Transcription.Key) -> String {
        switch key {
        case .preview: settings.preview.selected
        case .hq: settings.hq.selected
        case .secondOpinion: settings.secondOpinion.selected
        case .frontEnd: settings.frontEnd.selected
        case .quietGate: settings.quietGate.selected
        }
    }
    /// A quiet caption under a control, or nothing.
    @ViewBuilder
    private func quiet(_ line: String?) -> some View {
        if let line {
            Text(line).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    /// 0.5.317: Mac dictation's engine (server 6.74.0). On an older server, one line says dictation is Parakeet only.
    @ViewBuilder
    private func dictationPicker(_ settings: SttSettings) -> some View {
        if let choice = settings.dictation {
            COSDropdown("Dictation engine", selection: Binding(
                get: { store.settings?.dictation?.selected ?? choice.selected },
                set: { id in
                    guard id != choice.selected else { return }
                    Task { await store.set("dictation", .string(id), run: Self.run(model)) }
                }), options: Transcription.dictationRows(choice, compact: true).map { row in
                    COSDropdownOption(row.id, row.title, note: row.note, muted: !row.enabled, enabled: row.enabled)
                }, labelWidth: 112)
                .font(COSType.body(12))
                .disabled(store.pending != nil)
                .accessibilityIdentifier("dictation-engine")
        }
        quiet(Transcription.dictationLine(settings))
    }

    /// The Parakeet row (0.5.317): installed, installing with Cancel, Install Parakeet (654 MB), or the reason it cannot
    /// be installed with the one thing to do about it. Never a greyed-out control without its reason.
    @ViewBuilder
    private func parakeetRow(_ parakeet: SttParakeet, recording: Bool) -> some View {
        if let state = store.rowState(recording: recording) {
            VStack(alignment: .leading, spacing: 4) {
                ParakeetRowView(state: state, offersCancel: store.offersCancel,
                                install: { Task { await store.install(Self.run(model), recording: model.recordingCount > 0) } },
                                cancel: { Task { await store.cancelInstall(Self.run(model)) } },
                                checkAgain: { Task { await store.checkAgain(Self.run(model)) } },
                                useWhisper: { Task { await store.set("dictation", .string("whisper"), run: Self.run(model)) } })
                // A small link under the Parakeet note, on the row's left edge (render review 0.5.317).
                LicensesLink { model.openLicenses() }
            }
        }
    }
}

/// 0.5.317: the menu bar panel's Parakeet line, while dictation is on and Parakeet Ultra is not installed (or is
/// installing). Hidden on a server that cannot say (the card is not visible) and once Parakeet is installed.
struct PanelParakeetRow: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var store: TranscriptionSettingsStore
    /// Read, not observed: the dictation store publishes every phase change, and the panel redraws on the model's.
    let dictationOn: Bool
    static func shows(enabled: Bool, settings: SttSettings?, installing: Bool) -> Bool {
        guard enabled, let settings else { return false }
        return installing || settings.parakeet.serverInstalling || !settings.parakeet.installed
    }
    var body: some View {
        if Self.shows(enabled: dictationOn, settings: store.visible ? store.settings : nil, installing: store.installing),
           let state = store.rowState(recording: model.recordingCount > 0), let settings = store.settings {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dictation").font(COSType.body(12, weight: .semibold))
                Text(Transcription.dictationLine(settings)).font(COSType.body(11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ParakeetRowView(state: state, offersCancel: store.offersCancel, compact: true,
                                install: { model.installParakeet() },
                                cancel: { Task { await store.cancelInstall(TranscriptionSettingsCard.run(model)) } },
                                checkAgain: { Task { await store.checkAgain(TranscriptionSettingsCard.run(model)) } },
                                useWhisper: { Task { await store.set("dictation", .string("whisper"), run: TranscriptionSettingsCard.run(model)) } })
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// "Licenses" as a link: aligned with the text above it (no button padding), accent color, underlined on hover.
struct LicensesLink: View {
    let open: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: open) {
            Text("Licenses").font(COSType.body(11)).foregroundStyle(COSPalette.accent).underline(hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(Transcription.licensesLine)
        .accessibilityLabel("Licenses")
    }
}

/// One Parakeet row, shared by Settings, the menu bar panel and the setup guide's engine step, so every place says the
/// same thing and offers the same action.
struct ParakeetRowView: View {
    let state: ParakeetRowState
    var offersCancel = false
    var compact = false
    let install: () -> Void
    let cancel: () -> Void
    let checkAgain: () -> Void
    let useWhisper: () -> Void
    var body: some View {
        switch state {
        case .installing(let line):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                caption(line)
                if offersCancel { Button("Cancel", action: cancel).buttonStyle(COSQuietButtonStyle()) }
            }
        case .installed(let line):
            caption(line)
        case .offer(let title, let line):
            VStack(alignment: .leading, spacing: 4) {
                if let line { Text(line).font(COSType.body(11)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true) }
                Button(title, action: install).buttonStyle(COSQuietButtonStyle())
                if !compact { caption(Transcription.installCaption) }
            }
        case .blocked(let reason, let action):
            VStack(alignment: .leading, spacing: 4) {
                caption(reason)
                switch action {
                case .checkAgain: Button("Check again", action: checkAgain).buttonStyle(COSQuietButtonStyle())
                case .useWhisper: Button("Use Whisper", action: useWhisper).buttonStyle(COSQuietButtonStyle())
                case .install, .retryInstall: Button(Transcription.installTitle, action: install).buttonStyle(COSQuietButtonStyle())
                case .cancel: Button("Cancel", action: cancel).buttonStyle(COSQuietButtonStyle())
                case .afterRecording, .none: EmptyView()
                }
            }
        }
    }
    private func caption(_ line: String) -> some View {
        Text(line).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Keep qualification details available without stretching the toolbar's settings panel.
struct MeetingAskModelDetails: View {
    let options: [MeetingAskModelOption]
    @Binding var expanded: Bool
    var body: some View {
        if !options.isEmpty {
            DisclosureGroup("Unavailable models (\(options.count))", isExpanded: $expanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(options) { option in
                            Text(option.choice.label + ": " + MeetingAskModelPicker.reason(option.reason))
                                .font(COSType.body(10.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 180)
            }.disclosureGroupStyle(COSDisclosureStyle())
        }
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
    var saved = false
    var captureLabel: String?
    var meeting: LibraryMeeting?
    private var askEnabled: Bool { feed?.turns.isEmpty == false || state.savedSnapshots[session]?.validSaved == true }
    var jump: (Int) -> Void = { _ in }
    private let actions = [("catch_up", "Catch me up"), ("summary", "Summarize so far"), ("questions", "What to ask"), ("actions", "Action items")]
    private var record: MeetingAskLocalRecord? { state.records[session] }
    @State private var dropTargeted = false
    @State private var followUpExchange: MeetingAskExchange?
    @State private var followUpText = ""
    @State private var savingFollowUp = false
    @State private var expandedSources: Set<String> = []
    /// 0.5.281: the live panel takes files anywhere on it, through the Files box's own drop, when this meeting can hold them.
    private var takesFiles: Bool {
        (feed != nil || saved) && model.workHandoffStore?.meetingFiles.enabled == true && WorkCardFiles.meetingID(forKey: LibraryMeeting.captureContextKey(session)) != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(saved ? "Meeting Ask" : feed == nil ? "Meeting Ask history" : "Live COS Ask").font(COSType.display(19, weight: .medium)); Spacer(); Button { Task { await state.open(session, model: model); if saved { await state.loadSavedSnapshot(session, model: model) }; await state.checkSources(session, model: model) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(COSTextButtonStyle()).help("Refresh saved answers") }
            Text("Ask when you need it. Uses this meeting first.").font(COSType.body(11.5)).foregroundStyle(.secondary)
            DisclosureGroup("Sources and context") { Text(state.sourceHealth[session] ?? "Source status has not been checked.").font(COSType.body(11)).foregroundStyle(.secondary) }
            if let captureLabel { Text(captureLabel).font(COSType.body(11)).foregroundStyle(.secondary) }
            if feed != nil || saved {
                MeetingAskActionsLayout {
                    ForEach(actions, id: \.0) { action, title in
                        Button(title) { submit(action: action, question: title == "Catch me up" ? "Catch me up on this recording" : title) }
                            .buttonStyle(COSQuietButtonStyle()).disabled(!state.online || state.running.contains(session) || record?.outbox != nil || !askEnabled)
                    }
                    if state.config?.capabilities?.factCheck == true {
                        Button("Fact check") { submit(action: "ask", question: "Fact check the latest public factual claim in this meeting. Find a readable source and say whether it supports the claim.") }
                            .buttonStyle(COSQuietButtonStyle()).disabled(!state.online || state.running.contains(session) || record?.outbox != nil || !askEnabled)
                    }
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if record?.exchanges.isEmpty != false {
                            Text(MeetingAskHistoryState.emptyText(loading: state.loadingHistory.contains(session), failed: state.errors[session] != nil || !state.online, live: feed != nil))
                                .font(COSType.body(12)).foregroundStyle(.secondary)
                        }
                        ForEach(record?.exchanges ?? []) { exchange in answer(exchange, proxy: proxy) }
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
            if feed != nil || saved {
                if let note = state.attachNotes[session] {
                    Text(note).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let files = model.workHandoffStore?.meetingFiles, let id = WorkCardFiles.meetingID(forKey: LibraryMeeting.captureContextKey(session)) {
                    WorkCardFlashView(files: files, workID: id)
                }
                HStack(alignment: .bottom) {
                    // 0.5.281: a drop or a paste of files here attaches them to this meeting and leaves the question as it was.
                    MeetingAskComposer(text: Binding(get: { state.draft(session) }, set: { state.setDraft($0, session: session) }),
                                       placeholder: "Ask about this meeting", enabled: state.config != nil,
                                       onSubmit: { submit(action: "ask", question: state.draft(session)) },
                                       onAttach: { attachment in Task { await state.attach(attachment, session: session, model: model) } })
                        .cosField()
                    Button("Ask") { submit(action: "ask", question: state.draft(session)) }.buttonStyle(COSPrimaryButtonStyle())
                        .disabled(!state.online || state.running.contains(session) || record?.outbox != nil || state.draft(session).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !askEnabled)
                }
                HStack {
                    Button("Challenge an assumption") { submit(action: "ask", question: "For my own thinking, challenge one assumption supported by this recording. Give one short reason. If no assumption is clear, say so.") }
                    Button("Find my next decision") { submit(action: "ask", question: "For my own thinking, identify one unresolved decision from this recording and one useful question to move it forward. Do not invent a decision.") }
                }.buttonStyle(COSTextButtonStyle()).font(COSType.body(11)).disabled(!state.online || !askEnabled || state.running.contains(session) || record?.outbox != nil)
                // 0.5.282: the model the next question goes to, switchable here (the same control and setting as
                // Settings). An answer already running keeps its model, shown in its footer.
                MeetingAskModelControl(store: state, model: model, compact: true)
            }
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(COSPalette.panel)
        // The Files box's own drop (files only, on the panel itself, never in an overlay); the stroke only draws.
        .modifier(MeetingFilesDrop(enabled: takesFiles, targeted: $dropTargeted) { providers in
            Task { await state.attach(.providers(providers), session: session, model: model) }
        })
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 9).stroke(COSPalette.gold, lineWidth: 1.5).allowsHitTesting(false) } }
        .task(id: session) { await state.open(session, model: model); if saved { await state.loadSavedSnapshot(session, model: model) }; await state.checkSources(session, model: model) }
        .sheet(item: $followUpExchange) { exchange in
            VStack(alignment: .leading, spacing: 14) {
                Text("Save as follow-up").font(COSType.display(20))
                Text("Review these words. This creates a Work Review item with the original answer and sources; it does not commit a task.").font(COSType.body(12))
                TextEditor(text: $followUpText).frame(width: 480, height: 120).disabled(savingFollowUp)
                if let error = state.errors[session] { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.amber) }
                HStack {
                    Button("Cancel") { followUpExchange = nil }.disabled(savingFollowUp)
                    Spacer()
                    Button(savingFollowUp ? "Saving…" : "Save in Work Review") {
                        guard let meeting else { return }; savingFollowUp = true
                        Task { let saved = await state.saveFollowUp(exchange, text: followUpText.trimmingCharacters(in: .whitespacesAndNewlines), meeting: meeting, model: model); savingFollowUp = false; if saved { followUpExchange = nil } }
                    }.disabled(savingFollowUp || followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || followUpText.count > 600 || !state.online)
                }
            }.padding(24).interactiveDismissDisabled(savingFollowUp)
        }
        .onChange(of: session) { previous, _ in _ = state.flush(previous); followUpExchange = nil }
        .onDisappear { _ = state.flush(session) }
    }
    private func submit(action: String, question: String, retryOf: String? = nil) {
        if let feed { state.ask(action: action, question: question, feed: feed, model: model, retryOf: retryOf) }
        else if saved { state.askSaved(action: action, question: question, session: session, model: model, retryOf: retryOf) }
    }
    private func answer(_ exchange: MeetingAskExchange, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(verbatim: exchange.question).font(COSType.body(12, weight: .semibold))
            // 0.5.283: bold-label rows, So what first, when the answer has labels; an older answer stays plain Markdown.
            // 0.5.343: a new answer builds in place while COS reads the meeting (COSBuildUp); the chain is today's.
            COSBuildUp(.answer, loading: !exchange.terminal && exchange.answer == nil && MeetingAskAnswerRows.rows(sections: exchange.sections?.items, answer: nil) == nil,
                       landed: exchange.answer != nil || MeetingAskAnswerRows.rows(sections: exchange.sections?.items, answer: nil) != nil,
                       failed: exchange.error != nil,
                       timeout: MeetingAskStore.helperTimeout + COSBuildUpPlan.helperMargin, label: "Checking the meeting", key: AnyHashable(exchange.id), background: COSPalette.raised) {
            if let rows = MeetingAskAnswerRows.rows(sections: exchange.sections?.items, answer: exchange.answer) { MeetingAskAnswerRowsView(rows: rows, bodySize: 13, citationIDs: Set(exchange.sources.map(\.id))) }
            else if let answer = exchange.answer { COSMarkdownView(text: answer, cacheID: exchange.id + exchange.updatedAt, bodySize: 13) }
            else { Text(exchange.terminal ? "No answer · " + exchange.status : "Checking the meeting…").font(COSType.body(12)).foregroundStyle(.secondary) }
            }
            if let reason = exchange.error { Text(MeetingAskText.failure(reason)).font(COSType.body(11)).foregroundStyle(COSPalette.amber) }
            ForEach(exchange.sources) { source in sourceRow(source, exchangeID: exchange.id) }.font(COSType.body(11))
            ForEach(exchange.notices, id: \.self) { Text($0).font(COSType.body(11)).foregroundStyle(COSPalette.amber) }
            HStack {
                Text("Through \(LiveTranscript.stamp(exchange.throughMs, hours: false)) · \(exchange.model ?? exchange.selectedModel.label)").foregroundStyle(.secondary)
                Spacer()
                if exchange.terminal, ["failed", "cancelled", "interrupted"].contains(exchange.status), askEnabled {
                    Button("Retry") { submit(action: exchange.action, question: exchange.question, retryOf: exchange.id) }
                        .buttonStyle(COSTextButtonStyle()).disabled(state.running.contains(session) || record?.outbox != nil || !state.online)
                }
                if !exchange.terminal { Button("Stop") { Task { await state.cancel(exchange, model: model) } }.buttonStyle(COSTextButtonStyle()) }
                if exchange.status == "completed", state.config?.capabilities?.followUpReview == true {
                    Button("Save as follow-up") {
                        followUpText = String((exchange.sections?.items.first(where: { $0.label == "So what" })?.text ?? exchange.answer ?? "").replacingOccurrences(of: "\\[[A-Za-z][0-9]+\\]", with: "", options: .regularExpression).prefix(600))
                        followUpExchange = exchange
                    }.buttonStyle(COSTextButtonStyle()).disabled(!saved || meeting == nil || !state.online).help(saved ? "Review this answer in Work" : "Save this meeting before adding a follow-up")
                }
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(exchange.answer ?? exchange.question, forType: .string) }.buttonStyle(COSTextButtonStyle())
            }.font(COSType.body(10.5))
        }.padding(12).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 9))
        .environment(\.cosMarkdownCitationIDs, Set(exchange.sources.map(\.id)))
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "cos-ask-citation" else { return .systemAction }
            guard let id = MeetingAskCitationText.id(url, ids: Set(exchange.sources.map(\.id))) else { return .discarded }
            let key = exchange.id + ":" + id
            expandedSources.insert(key)
            Task { @MainActor in await Task.yield(); proxy.scrollTo(key, anchor: .center) }
            return .handled
        })
    }
    private func sourceRow(_ source: LiveAskSource, exchangeID: String) -> some View {
        let key = exchangeID + ":" + source.id
        return DisclosureGroup("[\(source.id)] \(source.kind.capitalized) · \(source.title)", isExpanded: Binding(get: { expandedSources.contains(key) }, set: { if $0 { expandedSources.insert(key) } else { expandedSources.remove(key) } })) {
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
                if source.kind == "file", let id = source.fileId, let file = model.workHandoffStore?.meetingFiles.meetingFiles(keys: [LibraryMeeting.captureContextKey(session)]).first(where: { $0.file.id == id }), !file.file.isLink {
                    Button("Reveal file") { NSWorkspace.shared.activateFileViewerSelecting([file.folder.appendingPathComponent(file.file.stored)]) }.buttonStyle(COSTextButtonStyle())
                }
            }
        }.id(key)
    }
}

/// 0.5.283: an answer's labeled rows (MeetingAskAnswerRows): the label in semibold, then its words with their inline
/// Markdown and [T1] citations kept, and any further paragraphs as Markdown blocks under it. Selectable, like the
/// Markdown answer it replaces.
struct MeetingAskAnswerRowsView: View {
    let rows: [MeetingAskAnswerRows.Row]
    var bodySize: CGFloat = 13
    var citationIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                // More than one paragraph (a whole free-form reply under So what): the first paragraph sits beside the
                // label and the rest is drawn under it as Markdown blocks (MeetingAskAnswerRows.split).
                let parts = MeetingAskAnswerRows.split(row.text)
                VStack(alignment: .leading, spacing: 8) {
                    (Text(verbatim: row.label + ":").font(COSType.body(bodySize, weight: .semibold))
                        + Text(verbatim: parts.lead.isEmpty ? "" : " ")
                        + Text(MeetingAskCitationText.attributed(MeetingAskAnswerRows.display(parts.lead), ids: citationIDs)))
                        .font(COSType.body(bodySize))
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let rest = parts.rest { COSMarkdownView(text: rest, bodySize: bodySize) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: Live cue verdicts (0.5.327, server 6.79.0)

/// The five verdicts as one row of buttons: the stored one filled, the rest quiet. `showsKeys` prints each key (the cue
/// card in Memories, where 1 to 5 rate).
struct CueVerdictButtons: View {
    let selected: CueVerdict?
    var showsKeys = false
    var disabled = false
    let pick: (CueVerdict) -> Void
    var body: some View {
        MeetingAskActionsLayout {
            ForEach(CueVerdict.allCases, id: \.self) { verdict in
                let label = HStack(spacing: 6) {
                    if showsKeys { Text(verdict.key).font(COSType.mono(10.5)).opacity(0.7) }
                    Text(verdict.label)
                }
                if verdict == selected {
                    Button { pick(verdict) } label: { label }.buttonStyle(COSPrimaryButtonStyle())
                        .accessibilityValue("Selected")
                } else {
                    Button { pick(verdict) } label: { label }.buttonStyle(COSQuietButtonStyle())
                }
            }
        }
        .disabled(disabled)
    }
}

/// COS Activity → Memories → Cues to rate and Rated cues (mock A, approved 2026-10-19). Mounted on
/// `model.cueReviewRouteActive`, which only `openCueReview(_:)` and `closeCueReview()` write; the Memories page's two
/// entries open it. The rail's To review and Recent learning go back to the page on that view.
struct CueReviewPane: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var store: CueVerdictsStore
    var openMemories: (String) -> Void
    /// The helper bridge. The helper gives the server 10 seconds; this is the process's own limit around that.
    static func run(_ model: ControllerModel) -> CueVerdictsStore.Run {
        { arguments, input in try await model.runHelper(arguments, timeout: 15, stdinData: input) }
    }

    private var view: CueVerdicts.Review { model.cueReview ?? .toRate }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            rail.frame(width: 210, alignment: .topLeading)
            Rectangle().fill(COSPalette.line).frame(width: 1)
            Group {
                switch view {
                case .toRate: queueView
                case .rated: ratedView
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .background(COSPalette.panel)
        .task(id: view) { await load(view) }
    }

    private func load(_ view: CueVerdicts.Review) async {
        switch view {
        case .toRate: await store.loadWeek(Self.run(model))
        case .rated: await store.loadRated(Self.run(model))
        }
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            railLink("To review", active: false) { openMemories("review") }
            railLink("Recent learning", active: false) { openMemories("recent") }
            railLink("Cues to rate", count: store.counts?.unrated, active: view == .toRate) { model.openCueReview(.toRate) }
            railLink("Rated cues", active: view == .rated) { model.openCueReview(.rated) }
            if let counts = store.counts {
                Text(CueVerdicts.ratingsLine(counts))
                    .font(COSType.body(11.5))
                    .foregroundStyle(COSPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 20)
            }
        }
        .padding(.top, 22)
        .padding(.leading, 22)
        .padding(.trailing, 14)
    }

    private func railLink(_ title: String, count: Int? = nil, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(COSType.body(13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.primary : COSPalette.muted)
                if let count { Text("\(count)").font(COSType.body(12.5)).foregroundStyle(COSPalette.accent).monospacedDigit() }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.leading, active ? 10 : 0)
            .overlay(alignment: .leading) { if active { Rectangle().fill(COSPalette.gold).frame(width: 2) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(COSType.display(24, weight: .medium))
            Text(detail).font(COSType.body(12)).foregroundStyle(COSPalette.muted)
            Spacer(minLength: 8)
            Button { Task { await load(view) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(COSTextButtonStyle()).help("Check again")
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    /// The one line in place of cues, with Check again when another read can help.
    @ViewBuilder
    private func stateLine(_ state: CueVerdicts.State) -> some View {
        if let line = CueVerdicts.line(state) {
            VStack(alignment: .leading, spacing: 8) {
                Text(line).font(COSType.body(12.5))
                    .foregroundStyle(state == .checking ? AnyShapeStyle(.secondary) : AnyShapeStyle(COSPalette.amber))
                    .fixedSize(horizontal: false, vertical: true)
                if state != .checking && state != .olderServer {
                    Button("Check again") { Task { await load(view) } }.buttonStyle(COSQuietButtonStyle())
                }
            }
        }
    }

    private var queueView: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Cues to rate", CueVerdicts.keysLine)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if store.weekState != .loaded {
                        stateLine(store.weekState)
                    } else if let cue = store.queue.first {
                        CueRateCard(cue: cue, title: CueVerdicts.title(cue, library: model.libraryMeetings), when: CueVerdicts.when(cue, now: Date(), style: model.clockStyle),
                                    left: max(store.queue.count, store.counts?.unrated ?? 0), saving: store.saving.contains(cue.id), error: store.rateErrors[cue.id],
                                    rate: { verdict, note in Task { await store.rate(cue, verdict: verdict, note: note, run: Self.run(model)) } },
                                    skip: { store.skip(cue) })
                            .id(cue.id)
                        if store.queue.count > 1 {
                            Text(CueVerdicts.nextLine(store.queue[1], style: model.clockStyle))
                                .font(COSType.body(12)).foregroundStyle(COSPalette.muted).lineLimit(1)
                        }
                    } else {
                        Text(CueVerdicts.doneLine(store.counts)).font(COSType.body(13)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
        }
    }

    private var ratedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("Rated cues", "Newest first. Pick another verdict to change one.")
            if store.ratedState != .loaded {
                stateLine(store.ratedState).padding(.horizontal, 28)
                Spacer(minLength: 0)
            } else if store.rated.isEmpty {
                Text("No rated cues in the last 7 days.").font(COSType.body(13)).foregroundStyle(.secondary).padding(.horizontal, 28)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.rated) { cue in
                            CueRatedRow(cue: cue, title: CueVerdicts.title(cue, library: model.libraryMeetings), when: CueVerdicts.when(cue, now: Date(), style: model.clockStyle),
                                        saving: store.saving.contains(cue.id), error: store.rateErrors[cue.id]) { verdict in
                                Task { await store.rate(cue, verdict: verdict, note: verdict == nil ? nil : cue.rating?.note, run: Self.run(model)) }
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 0, maxHeight: .infinity)
            }
        }
    }
}

/// One cue to rate. Keys 1 to 5, N and S act only while the card itself has focus (CueVerdicts.key), never while the
/// note field or anything else has it. The note lives here, so typing in it redraws this card and nothing above it.
struct CueRateCard: View {
    let cue: LiveCueRecord
    let title: String
    let when: String
    let left: Int
    let saving: Bool
    let error: String?
    let rate: (CueVerdict, String) -> Void
    let skip: () -> Void
    private enum Focus: Hashable { case card, note }
    @FocusState private var focus: Focus?
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).font(COSType.body(12.5, weight: .semibold)).lineLimit(1)
                    Text(when)
                    Text(CueVerdicts.kindLabel(cue.kind))
                    if let score = CueVerdicts.score(cue.gate) { Text("score " + score).font(COSType.mono(11)) }
                    Spacer(minLength: 8)
                    Text(CueVerdicts.leftLine(left))
                }
                .font(COSType.body(12))
                .foregroundStyle(COSPalette.muted)
                Text(cue.detail)
                    .font(COSType.body(17))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(CueVerdicts.sourcesLine(cue.sources)).font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                if !cue.before.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What was said just before").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                        Text(cue.before).font(COSType.body(12.5)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(COSPalette.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                if let vote = CueVerdicts.voteLine(cue.rating) { Text(vote).font(COSType.body(11.5)).foregroundStyle(COSPalette.muted) }
                CueVerdictButtons(selected: nil, showsKeys: true, disabled: saving) { verdict in rate(verdict, note) }
            }
            .contentShape(Rectangle())
            .focusable(interactions: .edit)
            .focused($focus, equals: .card)
            .focusEffectDisabled()
            .onTapGesture { focus = .card }
            .onKeyPress(phases: .down) { press in
                let modified = !press.modifiers.isDisjoint(with: [.command, .option, .control])
                guard let key = CueVerdicts.key(press.characters, modified: modified, cardFocused: focus == .card) else { return .ignored }
                switch key {
                case .rate(let verdict): if !saving { rate(verdict, note) }
                case .note: focus = .note
                case .skip: skip()
                }
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityHint("Keys 1 to 5 rate this cue, N adds a note, S skips")
            VStack(alignment: .leading, spacing: 6) {
                Text("Note (optional)").font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                TextField(CueVerdicts.notePlaceholder, text: $note)
                    .textFieldStyle(.plain)
                    .cosField()
                    .focused($focus, equals: .note)
                    .onSubmit { focus = .card }
                    .onExitCommand { focus = .card }
            }
            HStack(spacing: 10) {
                Button("Skip") { skip() }.buttonStyle(COSQuietButtonStyle())
                if saving { ProgressView().controlSize(.small) }
                if let error { Text(error).font(COSType.body(11.5)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .padding(22)
        .background(COSPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(focus == .card ? COSPalette.accent : COSPalette.line, lineWidth: 1))
        .onAppear { focus = .card }
    }
}

/// A rated cue in Memories → Rated cues: its verdict and note, the five verdicts to change it, and Clear.
struct CueRatedRow: View {
    let cue: LiveCueRecord
    let title: String
    let when: String
    let saving: Bool
    let error: String?
    let rate: (CueVerdict?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(title).font(COSType.body(12, weight: .semibold)).lineLimit(1)
                Text(when)
                Text(CueVerdicts.kindLabel(cue.kind))
                if let score = CueVerdicts.score(cue.gate) { Text(score).font(COSType.mono(10.5)) }
            }
            .font(COSType.body(11.5))
            .foregroundStyle(COSPalette.muted)
            Text(cue.detail).font(COSType.body(13.5)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if let rated = CueVerdicts.ratedLine(cue.rating) { Text(rated).font(COSType.body(11.5, weight: .medium)).foregroundStyle(COSPalette.accent) }
            HStack(alignment: .top, spacing: 10) {
                CueVerdictButtons(selected: cue.verdict, disabled: saving) { verdict in if verdict != cue.verdict { rate(verdict) } }
                Button("Clear") { rate(nil) }.buttonStyle(COSTextButtonStyle()).disabled(saving).help("Back to Cues to rate")
            }
            if let error { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(COSPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line, lineWidth: 1))
    }
}

/// The panel beside a meeting (mock B): Live COS Ask and, for a glasses meeting on a server with the cue history, its
/// Cues. The switch shows only once a history read has answered in the contract (`store.available == true`); on an
/// older server the panel is the Ask panel alone, as before. Hide Ask still hides the whole panel.
struct MeetingSidePanel<Ask: View>: View {
    @ObservedObject var store: CueVerdictsStore
    let model: ControllerModel
    let session: String
    /// The live meeting is still running: its Cues list polls (MeetingCuesPanel).
    let live: Bool
    /// 0.5.336 (server 6.86.0): the server can cue a Mac recording (LiveMeetingCapability.macCues), so its Cues show too.
    let macCues: Bool
    let askTitle: String
    let ask: () -> Ask
    private enum Shown: Hashable { case ask, cues }
    @State private var shown: Shown

    /// `showsCues` opens on Cues (the render harness); the app always opens on Ask.
    init(store: CueVerdictsStore, model: ControllerModel, session: String, live: Bool = false, macCues: Bool = false, askTitle: String = "Live COS Ask",
         showsCues: Bool = false, @ViewBuilder ask: @escaping () -> Ask) {
        _store = ObservedObject(wrappedValue: store)
        self.model = model
        self.session = session
        self.live = live
        self.macCues = macCues
        self.askTitle = askTitle
        self.ask = ask
        _shown = State(initialValue: showsCues ? .cues : .ask)
    }

    private var cuesOffered: Bool { store.available == true && Self.cuesSession(session, macCues: macCues) }
    /// A glasses meeting, or (0.5.336) a Mac recording on a server that cues them.
    static func cuesSession(_ session: String, macCues: Bool) -> Bool {
        G2MeetingStop.isGlassesSession(session) || (macCues && session.hasPrefix("mac_"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if cuesOffered {
                COSViewSwitch("Meeting panel", selection: $shown, options: [
                    COSViewOption(Shown.ask, askTitle),
                    COSViewOption(Shown.cues, "Cues \(store.meetings[session]?.cues.count ?? 0)"),
                ])
                .padding(.horizontal, 16)
                .padding(.top, 12)
            }
            if cuesOffered && shown == .cues {
                MeetingCuesPanel(store: store, session: session, polls: live, days: live ? CueVerdicts.liveDays : CueVerdicts.savedDays,
                                 clock: model.clockStyle, run: CueReviewPane.run(model),
                                 limits: model.meetingAsk.liveCues.settings?.limits, cuesOn: model.meetingAsk.liveCues.settings?.enabled)
            } else {
                ask()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(COSPalette.panel)
        // One read when the panel shows a meeting: it is the capability check and the count on the switch.
        .task(id: session) {
            guard Self.cuesSession(session, macCues: macCues) else { return }
            await store.loadMeeting(session, days: live ? CueVerdicts.liveDays : CueVerdicts.savedDays, force: true, run: CueReviewPane.run(model))
        }
    }
}

/// One meeting's cues, newest first, each with the five verdicts inline; a rated cue shows its verdict. While the
/// meeting runs it reads again every 15 seconds, and only while this view shows (the task ends with it).
struct MeetingCuesPanel: View {
    @ObservedObject var store: CueVerdictsStore
    let session: String
    let polls: Bool
    let days: Int
    let clock: ClockStyle
    let run: CueVerdictsStore.Run
    /// 0.5.337 (loop audit W8): the server's limits and today's usage, and whether Live cues is on, for the lines below.
    var limits: LiveCuesLimits? = nil
    var cuesOn: Bool? = nil

    var body: some View {
        let meeting = store.meetings[session]
        let cues = (meeting?.cues ?? []).sorted { $0.createdAt > $1.createdAt }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(CueVerdicts.usedLine(meeting?.count ?? CueVerdicts.MeetingCount(cues: cues.count, cap: nil)))
                    .font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                Spacer(minLength: 8)
                Button { Task { await store.loadMeeting(session, days: days, force: true, run: run) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(COSTextButtonStyle()).help("Check again")
            }
            if let state = meeting?.state, state != .loaded, let line = CueVerdicts.line(state) {
                Text(line).font(COSType.body(11.5))
                    .foregroundStyle(state == .checking ? AnyShapeStyle(.secondary) : AnyShapeStyle(COSPalette.amber))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let line = CueVerdicts.limitLine(meeting?.count ?? CueVerdicts.MeetingCount(cues: cues.count, cap: nil), limits: polls ? limits : nil) {
                Text(line).font(COSType.body(11.5)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            } else if cues.isEmpty {
                Text(CueVerdicts.emptyLine(polls: polls, cuesOn: polls ? cuesOn : nil))
                    .font(COSType.body(12)).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(cues) { cue in
                        MeetingCueCard(cue: cue, line: CueVerdicts.cardLine(cue, style: clock), saving: store.saving.contains(cue.id),
                                       error: store.rateErrors[cue.id]) { verdict in
                            Task { await store.rate(cue, verdict: verdict, note: cue.rating?.note, run: run) }
                        }
                    }
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(session) \(polls)") {
            guard polls else { return }
            // A read as Cues opens (skipped by the store's floor when the panel read in the last 15 seconds), then every 15.
            while !Task.isCancelled {
                await store.loadMeeting(session, days: days, run: run)
                try? await Task.sleep(for: .seconds(CueVerdicts.pollSeconds))
            }
        }
    }
}

/// One cue beside a meeting: time, kind and score, the cue, and the verdicts (or the verdict it has, with Change). A
/// tap on the cue shows what was said just before it.
struct MeetingCueCard: View {
    let cue: LiveCueRecord
    let line: String
    let saving: Bool
    let error: String?
    let rate: (CueVerdict) -> Void
    @State private var changing = false
    @State private var showsBefore = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(line).font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
            Button { showsBefore.toggle() } label: {
                Text(cue.detail).font(COSType.body(13.5)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showsBefore ? "Hide what was said" : "Show what was said just before")
            if showsBefore {
                VStack(alignment: .leading, spacing: 4) {
                    if !cue.before.isEmpty { Text(cue.before).font(COSType.body(12)).fixedSize(horizontal: false, vertical: true) }
                    Text(CueVerdicts.sourcesLine(cue.sources)).font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(COSPalette.raised)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            if let rated = CueVerdicts.ratedLine(cue.rating), !changing {
                HStack(spacing: 8) {
                    Text(rated).font(COSType.body(11.5, weight: .medium)).foregroundStyle(COSPalette.accent)
                    Button("Change") { changing = true }.buttonStyle(COSTextButtonStyle())
                }
            } else {
                CueVerdictButtons(selected: cue.verdict, disabled: saving) { verdict in
                    changing = false
                    if verdict != cue.verdict { rate(verdict) }
                }
                if cue.verdict == nil, !showsBefore {
                    Text(cue.before.isEmpty ? "Not rated" : "Not rated · tap the cue to see what was said").font(COSType.body(11)).foregroundStyle(COSPalette.muted)
                }
            }
            if let vote = CueVerdicts.voteLine(cue.rating) { Text(vote).font(COSType.body(11)).foregroundStyle(COSPalette.muted) }
            if let error { Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(COSPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line, lineWidth: 1))
    }
}
