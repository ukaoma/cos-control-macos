import Foundation
import Combine
import CryptoKit
import Darwin

/// Private recovery journal. It stores references and unsent words, never file bytes or credentials.
struct MeetingPrepJournal {
    struct PendingRun: Codable, Equatable {
        let clientRequestId: String
        let revision: Int
        var run: MeetingPrep.Run?
        var retryAllowed: Bool? = nil
        var trackingEarlier: Bool? = nil
    }
    struct PendingFile: Codable, Equatable {
        let id: String
        let name: String
        let sourceRef: String
        let sha256: String
    }
    struct FileOperation: Codable {
        let id: String
        var revision: Int
        let media: [PendingFile]
        var removalAllowed: Bool? = nil
    }
    struct Entry: Codable, Identifiable {
        var id: String
        var title: String
        var startsAt: String?
        var steer: String
        var dirty = false
        var draft: MeetingPrep.Draft?
        var pending: PendingRun?
        var files: [PendingFile] = []
        var fileOperation: FileOperation?
        var answer: String?
        var jobState: String?
    }
    struct Snapshot: Codable {
        var generation = UUID()
        var entries: [Entry] = []
    }
    let root: URL
    let server: String
    private var file: URL {
        let key = SHA256.hash(data: Data(server.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key + ".json")
    }
    private func locked<T>(_ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid() else { throw CocoaError(.fileWriteNoPermission) }
        let fd = Darwin.open(file.path + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { Darwin.close(fd) }
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CocoaError(.fileLocking) }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
    private func readUnlocked() throws -> Snapshot? {
        var info = stat()
        if lstat(file.path, &info) != 0 {
            guard errno == ENOENT else { throw CocoaError(.fileReadNoPermission) }
            return nil
        }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_size <= 32_000_000 else { throw CocoaError(.fileReadNoPermission) }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try handle.readToEnd() ?? Data()
        guard data.count <= 32_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.entries.count <= 500, Set(snapshot.entries.map(\.id)).count == snapshot.entries.count else { throw CocoaError(.coderReadCorrupt) }
        return snapshot
    }
    func read() throws -> Snapshot { try locked { try readUnlocked() ?? Snapshot() } }
    func write(_ snapshot: Snapshot, expected: UUID?) throws -> Snapshot {
        try locked {
            let current = try readUnlocked()
            guard current?.generation == expected else { throw CocoaError(.fileWriteFileExists) }
            var next = snapshot; next.generation = UUID()
            let data = try JSONEncoder().encode(next)
            guard data.count <= 32_000_000, next.entries.count <= 500 else { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let handle = try FileHandle(forWritingTo: file); try handle.synchronize(); try handle.close()
            return next
        }
    }
    var exists: Bool { FileManager.default.fileExists(atPath: file.path) }
    func preserveRecovery(_ snapshot: Snapshot) throws {
        try locked {
            let destination = root.appendingPathComponent("recovery-\(UUID().uuidString.lowercased()).json")
            let data = try JSONEncoder().encode(snapshot)
            guard data.count <= 32_000_000 else { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        }
    }
}

@MainActor
final class MeetingPrepStore: ObservableObject {
    typealias Flow = MeetingPrepState<DropIt.Attachment>
    typealias Run = @MainActor ([String], Data?) async throws -> HelperResponse
    struct Launch: Identifiable, Equatable {
        var id = UUID().uuidString.lowercased()
        var title: String
        var startsAt: String?
        var resume: MeetingPrep.Draft?
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    @Published private(set) var flow = Flow()
    @Published var launch: Launch?
    @Published private(set) var active: MeetingPrep.Draft?
    @Published private(set) var recent: [MeetingPrep.Draft] = []
    @Published private(set) var supported = false
    @Published private(set) var discovered = false
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    @Published private(set) var answer: String?
    @Published private(set) var partialText = ""
    @Published private(set) var jobState: String?
    @Published private(set) var recoveryDrafts: [MeetingPrepJournal.Entry] = []
    @Published private(set) var uploads = DropItStore()
    var run: Run = { _, _ in throw CancellationError() }
    var plainAsk: (@MainActor (String, [DropIt.Attachment]) async -> Bool)?
    var plainUpload: Run?
    var revealComposer: (@MainActor () -> Void)?
    var journalRoot: URL = {
        if let home = ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"] { return URL(fileURLWithPath: home).appendingPathComponent("MeetingPrep") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("COS Control/MeetingPrep")
    }()
    private(set) var serverID: String?
    private var journal: MeetingPrepJournal?
    private var disk = MeetingPrepJournal.Snapshot()
    private var diskGeneration: UUID?
    private var diskFailed = false
    private var uploadStores: [String: DropItStore] = [:]
    private var uploadObservers: [String: AnyCancellable] = [:]
    private var operations: Set<UUID> = []
    private var draftWriter: Task<Void, Never>?
    private var recoveredNotes: [String: String] = [:]
    private var needsRecoveryReview = false
    private var activeKey: String? { flow.presentation?.occurrence }
    private var entry: MeetingPrepJournal.Entry? { disk.entries.first { $0.id == activeKey } }
    var text: String { flow.presentation?.draft.text ?? "" }
    var isOpen: Bool { flow.presentation != nil }
    var queuedFiles: [MeetingPrepJournal.PendingFile] { entry?.files ?? [] }
    var hasQueuedFiles: Bool { !queuedFiles.isEmpty || entry?.fileOperation != nil }
    var canSend: Bool { !busy && !diskFailed && !hasQueuedFiles && pending == nil && flow.presentation?.phase == .ready && !uploads.attachments.contains(where: \.busy) }
    var pending: MeetingPrepJournal.PendingRun? { entry?.pending }
    var canRetryRequest: Bool { !busy && !diskFailed && pending?.retryAllowed == true }
    private func beginOperation() -> UUID { let id = UUID(); operations.insert(id); busy = true; return id }
    private func endOperation(_ id: UUID) { operations.remove(id); busy = !operations.isEmpty }

    private func request(_ op: String, fields: [String: Any] = [:]) async throws -> [String: JSONValue] {
        var body = fields
        if op != "capabilities" {
            guard let serverID else { throw Failure(message: "Refresh Prep to connect to its server.") }
            body["serverInstanceId"] = serverID
        }
        let input = op == "capabilities" ? nil : try JSONSerialization.data(withJSONObject: body)
        let response = try await run(["meeting-prep", "--op", op], input)
        if op != "capabilities", response.details["serverInstanceId"]?.string != serverID { throw Failure(message: "The server changed. Reopen Prep before continuing.") }
        return response.details
    }
    private func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue?) throws -> T {
        guard let value else { throw Failure(message: "The Prep response was incomplete. Refresh to check it.") }
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
    private func draft(_ details: [String: JSONValue], expected: String? = nil) throws -> MeetingPrep.Draft {
        let value = try decode(MeetingPrep.Draft.self, details["draft"])
        guard value.valid, value.serverInstanceId == serverID, expected == nil || value.id == expected else { throw Failure(message: "The response did not match this Prep draft and server.") }
        return value
    }
    private func runReceipt(_ raw: JSONValue?, draftID: String) throws -> MeetingPrep.Run {
        try validatedRun(decode(MeetingPrep.Run.self, raw), draftID: draftID)
    }
    private func validatedRun(_ receipt: MeetingPrep.Run, draftID: String) throws -> MeetingPrep.Run {
        guard receipt.clientRequestId.range(of: "\\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\\z", options: .regularExpression) != nil,
              receipt.draftRevision >= 0, ["submitting", "accepted", "failed"].contains(receipt.state),
              (receipt.state == "accepted" ? receipt.jobId?.isEmpty == false : receipt.jobId == nil) else {
            throw Failure(message: "The Prep receipt did not contain a valid request identity.")
        }
        let digest = SHA256.hash(data: Data("prep-run:v1:\(draftID):\(receipt.clientRequestId)".utf8))
        var hex = Array(digest.prefix(16).map { String(format: "%02x", $0) }.joined())
        hex[12] = "4"; hex[16] = Array("89ab")[hex[16].hexDigitValue! & 3]
        let expected = [hex[0..<8], hex[8..<12], hex[12..<16], hex[16..<20], hex[20..<32]].map { String($0) }.joined(separator: "-")
        guard receipt.clientJobId == expected else { throw Failure(message: "The Prep receipt did not belong to this draft.") }
        return receipt
    }
    private func sameFrozenRun(_ first: MeetingPrep.Run, _ second: MeetingPrep.Run) -> Bool {
        first.clientRequestId == second.clientRequestId && first.clientJobId == second.clientJobId &&
            first.draftRevision == second.draftRevision && first.createdAt == second.createdAt &&
            first.model == second.model && first.effort == second.effort &&
            (first.continueRun == true) == (second.continueRun == true) &&
            (first.jobId == nil || first.jobId == second.jobId)
    }
    private func matchesPending(_ receipt: MeetingPrep.Run, _ pending: MeetingPrepJournal.PendingRun) -> Bool {
        receipt.clientRequestId == pending.clientRequestId && receipt.draftRevision == pending.revision &&
            (pending.run.map { sameFrozenRun($0, receipt) } ?? true)
    }
    private func checked(_ details: [String: JSONValue]) throws {
        guard let status = details["httpStatus"]?.int, (200...299).contains(status) else {
            let status = details["httpStatus"]?.int ?? 0
            if status == 409 { throw Failure(message: "Prep changed elsewhere. Refresh, review both versions, and save your notes again.") }
            if status == 503 { throw Failure(message: "The server is busy or updating. Your draft is kept. Check again shortly.") }
            if status == 507 { throw Failure(message: "The Prep store is full. Your unsent draft is kept on this Mac.") }
            throw Failure(message: "The server refused this Prep request (\(status)). Your draft is kept.")
        }
    }
    @discardableResult private func persist() -> Bool {
        guard let journal, !diskFailed else { return false }
        do {
            disk = try journal.write(disk, expected: diskGeneration); diskGeneration = disk.generation
            recoveryDrafts = disk.entries
            return true
        } catch {
            diskFailed = true
            notice = "Prep could not save its recovery record or another window changed it. Reopen Prep before sending. Existing recovery data was kept."
            return false
        }
    }
    private func mutate(_ key: String, _ change: (inout MeetingPrepJournal.Entry) -> Void) {
        guard let i = disk.entries.firstIndex(where: { $0.id == key }) else { return }
        change(&disk.entries[i])
    }

    func discover() async throws {
        let response = try await request("capabilities")
        guard let identity = response["serverInstanceId"]?.string, !identity.isEmpty else { throw Failure(message: "The server identity is unavailable.") }
        if let serverID, serverID != identity { throw Failure(message: "The server identity changed. Close Prep and reconnect before continuing.") }
        serverID = identity
        supported = response["available"]?.bool == true && ((try? decode(MeetingPrep.Capability.self, response["capability"]))?.supported == true)
        discovered = true
        if supported, journal == nil {
            let store = MeetingPrepJournal(root: journalRoot, server: identity)
            let existed = store.exists
            disk = try store.read(); diskGeneration = existed ? disk.generation : nil
            journal = store; recoveryDrafts = disk.entries
        }
        if supported, diskFailed, let journal {
            try journal.preserveRecovery(disk)
            recoveredNotes = Dictionary(uniqueKeysWithValues: disk.entries.filter(\.dirty).map { ($0.id, $0.steer) })
            let existed = journal.exists
            disk = try journal.read(); diskGeneration = existed ? disk.generation : nil
            diskFailed = false; needsRecoveryReview = !recoveredNotes.isEmpty
        }
        uploads.isSecret = { WorkCardFiles.looksSecret(name: $0) }
        uploads.run = { [weak self] arguments, input in
            guard let self, arguments == ["drop-it", "--op", "upload"], let input,
                  let payload = try JSONSerialization.jsonObject(with: input) as? [String: Any] else { throw CancellationError() }
            if !self.supported, let plainUpload = self.plainUpload { return try await plainUpload(arguments, input) }
            let details = try await self.request("upload", fields: ["payload": payload])
            return HelperResponse(ok: true, message: "Prep file upload", details: details)
        }
    }

    func open(_ requested: Launch, ordinary: Flow.Draft) async {
        guard !isOpen else { return }
        let key = requested.resume?.clientDraftId ?? requested.id
        uploads = uploadStores[key] ?? DropItStore()
        uploadStores[key] = uploads
        if uploadObservers[key] == nil {
            uploadObservers[key] = uploads.$attachments.dropFirst().sink { [weak self] files in
                guard files.contains(where: { $0.state == .ready }) else { return }
                Task { @MainActor [weak self] in await self?.saveUploadedFiles(key: key) }
            }
        }
        guard flow.open(occurrence: key, ordinaryDraft: ordinary), let ticket = flow.beginPreparation() else { return }
        let operation = beginOperation(); notice = nil; active = nil; answer = nil; partialText = ""; jobState = nil
        defer {
            endOperation(operation)
            Task { [weak self] in await self?.saveUploadedFiles(key: key) }
        }
        do {
            try await discover()
            guard flow.presentation?.generation == ticket.generation else { return }
            if !supported {
                _ = flow.finishPreparation(ticket, draft: .init(text: "Prep me for \(requested.title). " + (requested.startsAt.map { "Starts at \($0). " } ?? "")))
                notice = "This server supports plain Ask only. Files will go with that Ask, but will not carry into a meeting."
                return
            }
            if !disk.entries.contains(where: { $0.id == key }) {
                disk.entries.append(.init(id: key, title: requested.title, startsAt: requested.startsAt, steer: requested.resume?.steer ?? "", draft: requested.resume))
                guard persist() else { throw Failure(message: notice ?? "Could not save Prep.") }
            }
            guard let local = entry else { throw CancellationError() }
            let response: [String: JSONValue]
            if let saved = local.draft {
                response = try await request("get", fields: ["draftId": saved.id])
            } else {
                var payload: [String: Any] = ["clientDraftId": key, "title": local.title]
                if let startsAt = local.startsAt { payload["startsAt"] = startsAt }
                response = try await request("create", fields: ["payload": payload])
            }
            try checked(response)
            let remote = try draft(response, expected: local.draft?.id)
            guard remote.clientDraftId == key, flow.presentation?.generation == ticket.generation else { throw CancellationError() }
            mutate(key) { value in value.draft = remote; if !value.dirty { value.steer = remote.steer } }
            guard persist(), let latest = entry else { throw Failure(message: notice ?? "Could not save Prep.") }
            active = remote; answer = latest.answer; jobState = latest.jobState
            if let recovered = recoveredNotes.removeValue(forKey: key) {
                mutate(key) { $0.steer = recovered; $0.dirty = true }
                _ = flow.finishPreparation(ticket, draft: .init(text: recovered))
                notice = "A newer recovery record was loaded. Your unsaved notes were preserved separately and remain here. Review before saving or sending."
            } else { _ = flow.finishPreparation(ticket, draft: .init(text: latest.steer)) }
            // A durable pending request blocks new sends even after the application was closed.
            if let pending = latest.pending, let id = UUID(uuidString: pending.clientRequestId) {
                _ = flow.recoverSubmission(id, draft: .init(text: latest.steer))
                notice = "A previous Prep request needs a status check. No new request will start until it is resolved."
            }
            await refreshRecent()
        } catch {
            if !Task.isCancelled { notice = error.localizedDescription; _ = flow.failPreparation(ticket, message: error.localizedDescription) }
        }
    }

    func setText(_ value: String) {
        let bounded = String(value.prefix(4000))
        guard flow.edit(.init(text: bounded, attachments: uploads.attachments)) else { return }
        if let key = activeKey, supported {
            mutate(key) { $0.steer = bounded; $0.dirty = true }
            draftWriter?.cancel()
            draftWriter = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self, self.activeKey == key, !self.needsRecoveryReview else { return }
                _ = self.persist()
            }
        }
    }
    func close() -> Flow.Draft? {
        draftWriter?.cancel(); draftWriter = nil
        if supported, let journal {
            if needsRecoveryReview { try? journal.preserveRecovery(disk) }
            else { _ = persist() }
        }
        launch = nil; active = nil; answer = nil; jobState = nil
        return flow.cancel()
    }

    func sendPlainAsk() async -> Bool {
        guard !supported, canSend, let plainAsk, DropIt.askBlock(text: text, files: uploads.attachments) == nil else { return false }
        let operation = beginOperation(); defer { endOperation(operation) }
        let files = uploads.attachments
        let sent = await plainAsk(text, files)
        if sent { uploads.consumeAttachments(Set(files.map(\.id))) }
        else { notice = "The plain Ask did not start. Your words and files are still here." }
        return sent
    }

    func refreshDraft() async {
        guard !busy, let current = active, let key = activeKey else { return }
        let operation = beginOperation(); defer { endOperation(operation) }
        do {
            let response = try await request("get", fields: ["draftId": current.id]); try checked(response)
            let remote = try draft(response, expected: current.id)
            guard activeKey == key else { return }
            let wasDirty = entry?.dirty == true
            mutate(key) { $0.draft = remote; if !$0.dirty { $0.steer = remote.steer } }
            guard persist() else { return }; active = remote
            if !wasDirty { _ = flow.edit(.init(text: remote.steer, attachments: uploads.attachments)) }
            notice = entry?.dirty == true ? "The server version is refreshed. Your unsent notes remain in the composer; review them before saving." : nil
        } catch { notice = error.localizedDescription }
    }

    func removeFile(_ file: MeetingPrep.File) async {
        guard !busy, let current = active, let key = activeKey, !diskFailed else { return }
        let operation = beginOperation(); defer { endOperation(operation) }
        do {
            let response = try await request("remove-file", fields: ["draftId": current.id, "fileId": file.id, "payload": ["revision": current.revision]])
            try checked(response); let remote = try draft(response, expected: current.id)
            guard activeKey == key else { return }
            mutate(key) { $0.draft = remote }; guard persist() else { return }; active = remote
        } catch { notice = error.localizedDescription }
    }

    func meetingDrafts(session: String, startedAt: Date?, suggestions: Bool) async throws -> [MeetingPrep.Draft] {
        guard suggestions else { throw Failure(message: "Use the frozen recording snapshot to review adopted Prep.") }
        try await discover()
        guard supported else { return [] }
        var fields: [String: Any] = ["sessionId": session]
        if suggestions {
            guard let startedAt else { return [] }
            fields["startedAt"] = Int(startedAt.timeIntervalSince1970 * 1000)
        }
        let response = try await request("suggest", fields: fields); try checked(response)
        return try decode([MeetingPrep.Draft].self, response["drafts"]).filter { $0.valid && $0.serverInstanceId == serverID }
    }

    func openLatestDraft(_ id: String) async {
        guard !isOpen else { notice = "Close the current Prep draft before opening another."; revealComposer?(); return }
        do {
            let response = try await request("get", fields: ["draftId": id]); try checked(response)
            let remote = try draft(response, expected: id)
            guard !isOpen else { return }
            launch = .init(title: remote.title, startsAt: remote.startsAt, resume: remote)
            revealComposer?()
        } catch { notice = error.localizedDescription }
    }

    func meetingSnapshots(session: String) async throws -> [MeetingPrep.SessionSnapshot] {
        try await discover()
        guard supported else { return [] }
        let response = try await request("session", fields: ["sessionId": session]); try checked(response)
        let snapshots = try decode([MeetingPrep.SessionSnapshot].self, response["snapshots"])
        guard snapshots.allSatisfy({ $0.sessionId == session && MeetingPrep.Draft.validID($0.draftId) && $0.draftRevision >= 0 }) else { throw Failure(message: "The saved Prep context did not match this recording.") }
        return snapshots
    }

    func downloadSnapshotFile(_ file: MeetingPrep.SessionSnapshot.File, snapshot: MeetingPrep.SessionSnapshot) async throws -> URL {
        let response = try await request("get", fields: ["draftId": snapshot.draftId]); try checked(response)
        let remote = try draft(response, expected: snapshot.draftId)
        guard let original = remote.files.first(where: { $0.id == file.id && $0.sha256 == file.sha256 }) else {
            throw Failure(message: "This saved file is no longer available as a verified Prep original.")
        }
        return try await download(original, draft: remote)
    }

    func bind(_ draft: MeetingPrep.Draft, session: String) async throws {
        try await bind(draftID: draft.id, revision: draft.revision, session: session)
    }

    func retryBinding(_ snapshot: MeetingPrep.SessionSnapshot) async throws {
        guard snapshot.state == "applying", snapshot.removedAt == nil,
              MeetingPrep.Draft.validID(snapshot.draftId), snapshot.draftRevision >= 0 else {
            throw Failure(message: "Only a pending Prep attachment can be retried.")
        }
        try await bind(draftID: snapshot.draftId, revision: snapshot.draftRevision, session: snapshot.sessionId)
    }

    private func bind(draftID: String, revision: Int, session: String) async throws {
        guard let serverID, supported else { throw Failure(message: "Refresh Prep before adding it to this recording.") }
        let response = try await request("bind", fields: ["draftId": draftID, "payload": ["revision": revision, "sessionId": session, "serverInstanceId": serverID, "surface": "control"]])
        try checked(response)
        let returned = try draft(response, expected: draftID)
        guard returned.bindings.contains(where: { $0.sessionId == session && $0.serverInstanceId == serverID && $0.revision == revision && $0.state == "applied" && $0.removedAt == nil }) else {
            throw Failure(message: "The server has not confirmed adding this Prep to the selected recording.")
        }
    }

    func download(_ file: MeetingPrep.File, draft: MeetingPrep.Draft) async throws -> URL {
        let response = try await request("download", fields: ["draftId": draft.id, "fileId": file.id, "sha256": file.sha256, "bytes": file.bytes])
        guard let path = response["path"]?.string, path.hasPrefix("/"), response["sha256"]?.string == file.sha256,
              response["bytes"]?.int == file.bytes else { throw Failure(message: "The original file could not be verified.") }
        return URL(fileURLWithPath: path)
    }
    func refreshRecent() async {
        guard supported else { return }
        do { recent = try await readActiveDrafts() }
        catch { notice = error.localizedDescription }
    }

    func availableDrafts() async throws -> [MeetingPrep.Draft] {
        try await discover()
        guard supported else { return [] }
        return try await readActiveDrafts()
    }

    private func readActiveDrafts() async throws -> [MeetingPrep.Draft] {
        let response = try await request("list"); try checked(response)
        return try decode([MeetingPrep.Draft].self, response["drafts"])
            .filter { $0.valid && $0.serverInstanceId == serverID && $0.state == "active" }
    }

    /// Keep each immutable upload batch with its own id before asking the server to copy the originals.
    func saveUploadedFiles() async {
        guard let key = activeKey else { return }
        await saveUploadedFiles(key: key, explicit: true)
    }
    private func saveUploadedFiles(key: String, explicit: Bool = false) async {
        guard !busy, supported, !diskFailed, let uploadStore = uploadStores[key],
              let local = disk.entries.first(where: { $0.id == key }), let current = local.draft,
              explicit || local.fileOperation == nil else { return }
        let ready = uploadStore.attachments.filter { $0.state == .ready && $0.mediaId != nil }
        guard !ready.isEmpty || !local.files.isEmpty || local.fileOperation != nil else { return }
        let operation = beginOperation(); defer { endOperation(operation) }
        do {
            var captured: [MeetingPrepJournal.PendingFile] = []
            for file in ready where !local.files.contains(where: { $0.sourceRef == file.id }) {
                let source = file.source
                let hash = try await Task.detached(priority: .utility) {
                    let data = try Data(contentsOf: source, options: .mappedIfSafe)
                    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }.value
                captured.append(.init(id: file.mediaId!, name: file.name, sourceRef: file.id, sha256: hash))
            }
            mutate(key) { value in
                for file in captured where !value.files.contains(where: { $0.sourceRef == file.sourceRef }) { value.files.append(file) }
            }
            guard persist() else { return }
            let fresh = try await request("get", fields: ["draftId": current.id]); try checked(fresh)
            var remote = try draft(fresh, expected: current.id)
            func wasCopied(_ file: MeetingPrepJournal.PendingFile) -> Bool {
                remote.files.contains { $0.mediaId == file.id && ($0.uploadSha256 ?? $0.sha256) == file.sha256 && $0.status != "removed" }
            }
            guard let queued = disk.entries.first(where: { $0.id == key }) else { return }
            if let previous = queued.fileOperation, previous.media.allSatisfy({ wasCopied($0) }) {
                mutate(key) { $0.fileOperation = nil }
            }
            let remaining = queued.files.filter { !wasCopied($0) }
            if !remaining.isEmpty {
                guard remote.currentFiles.count + remaining.count <= 10 else { throw Failure(message: "Prep holds up to 10 files. Remove one before adding more.") }
                if disk.entries.first(where: { $0.id == key })?.fileOperation == nil {
                    mutate(key) { $0.fileOperation = .init(id: UUID().uuidString.lowercased(), revision: remote.revision, media: remaining) }
                    guard persist() else { return }
                }
                guard let batch = disk.entries.first(where: { $0.id == key })?.fileOperation else { return }
                mutate(key) { $0.fileOperation?.removalAllowed = false }
                guard persist() else { return }
                let response = try await request("files", fields: ["draftId": current.id, "payload": ["operationId": batch.id, "revision": batch.revision,
                    "media": batch.media.map { ["id": $0.id, "name": $0.name, "sourceRef": $0.sourceRef, "sha256": $0.sha256] }]])
                if let error = response["error"]?.string, ["revision_conflict", "media_not_found", "media_deleted", "media_expired", "media_hash_mismatch", "prep_file_limit", "prep_storage_limit"].contains(error), (response["httpStatus"]?.int ?? 0) >= 400 {
                    mutate(key) { $0.fileOperation?.removalAllowed = true }
                    guard persist() else { return }
                }
                if response["httpStatus"]?.int == 409, response["error"]?.string == "revision_conflict" {
                    let refreshed = try draft(response, expected: current.id)
                    mutate(key) { $0.fileOperation?.revision = refreshed.revision; $0.draft = refreshed; if !$0.dirty { $0.steer = refreshed.steer } }
                    guard persist() else { return }
                    if activeKey == key { active = refreshed; if entry?.dirty == false { _ = flow.edit(.init(text: refreshed.steer, attachments: uploads.attachments)) } }
                    throw Failure(message: "Prep changed elsewhere. Your file batch is kept. Choose Save files to retry adding these same files.")
                }
                try checked(response); remote = try draft(response, expected: current.id)
                guard batch.media.allSatisfy({ wasCopied($0) }) else { throw Failure(message: "The server did not confirm every original file. Your upload record is kept.") }
                mutate(key) { $0.fileOperation = nil }
            }
            let copied = Set((disk.entries.first(where: { $0.id == key })?.files ?? []).filter { wasCopied($0) }.map(\.sourceRef))
            mutate(key) { $0.draft = remote; $0.files.removeAll { copied.contains($0.sourceRef) } }
            guard persist() else { return }
            for file in uploadStore.attachments where copied.contains(file.id) { uploadStore.removeAttachment(file.id) }
            if activeKey == key {
                active = remote
                notice = remote.files.contains { ["failed", "secret-held", "unsupported"].contains($0.status) } ? "Some files need attention. Review their status before running Prep." : nil
            }
        } catch { if activeKey == key { notice = error.localizedDescription } }
    }

    /// Never cancel an ambiguous admitted batch: first replay its immutable receipt.
    func removeQueuedFile(sourceRef: String) {
        guard !busy, pending == nil, !diskFailed else { return }
        guard let key = activeKey else { return }
        if let batch = entry?.fileOperation, batch.media.contains(where: { $0.sourceRef == sourceRef }), batch.removalAllowed != true {
            notice = "This file may already be saved. Choose Save uploaded files to check its receipt, then remove the saved file."
            return
        }
        if entry != nil {
            mutate(key) { value in
                value.files.removeAll { $0.sourceRef == sourceRef }
                if value.fileOperation?.media.contains(where: { $0.sourceRef == sourceRef }) == true { value.fileOperation = nil }
            }
            guard persist() else { return }
        }
        uploads.removeAttachment(sourceRef)
        notice = nil
    }

    func saveNotes() async -> Bool {
        guard !busy, pending == nil else { return false }
        let operation = beginOperation(); defer { endOperation(operation) }
        return await saveNotesForSend()
    }

    private func saveNotesForSend() async -> Bool {
        guard let key = activeKey, let current = active, let local = entry, !diskFailed else { return false }
        draftWriter?.cancel(); draftWriter = nil
        needsRecoveryReview = false
        guard local.dirty else { return persist() }
        guard persist() else { return false }
        do {
            let response = try await request("update", fields: ["draftId": current.id, "payload": ["revision": current.revision, "steer": local.steer]])
            try checked(response)
            let remote = try draft(response, expected: current.id)
            guard activeKey == key, entry?.steer == local.steer else { return false }
            mutate(key) { $0.draft = remote; $0.dirty = false }
            guard persist() else { return false }
            active = remote; return true
        } catch { notice = error.localizedDescription; return false }
    }

    /// Only the explicit Prep button creates a run; recovery and polling only look up its existing identity.
    func send() async {
        guard canSend, supported, pending == nil, uploads.attachments.isEmpty, entry?.files.isEmpty == true else { return }
        let operation = beginOperation(); notice = nil; defer { endOperation(operation) }
        guard await saveNotesForSend(), let key = activeKey, let current = active, let ticket = flow.beginSend() else { return }
        let requestID = ticket.id.uuidString.lowercased()
        mutate(key) { $0.pending = .init(clientRequestId: requestID, revision: current.revision); $0.answer = nil; $0.jobState = "submitting" }
        guard persist() else { _ = flow.finishSend(ticket, outcome: .uncertain("The recovery record could not be saved.")); return }
        do {
            let response = try await request("run", fields: ["draftId": current.id, "payload": ["clientRequestId": requestID, "revision": current.revision, "continue": true]])
            guard let attempted = pending, attempted.clientRequestId == requestID, activeKey == key,
                  flow.presentation?.generation == ticket.generation else { return }
            if response["httpStatus"]?.int == 409, response["error"]?.string == "run_in_progress" {
                let blocking = try runReceipt(response["run"], draftID: current.id)
                guard blocking.clientRequestId != requestID, ["submitting", "accepted"].contains(blocking.state) else {
                    throw Failure(message: "The blocking Prep receipt did not identify an earlier request.")
                }
                let remote = try await readPendingDraft(key: key, requestID: requestID)
                guard let stored = remote.runs.first(where: { $0.clientRequestId == blocking.clientRequestId }),
                      sameFrozenRun(blocking, stored) else {
                    throw Failure(message: "The blocking Prep receipt was not found in this draft. Check status before sending again.")
                }
                try trackEarlierRun(validatedRun(stored, draftID: remote.id), replacing: attempted, draft: remote, key: key, ticket: ticket)
                return
            }
            try checked(response)
            let remote = try draft(response, expected: current.id)
            let accepted = try runReceipt(response["run"], draftID: current.id)
            guard accepted.clientRequestId == requestID, accepted.draftRevision == current.revision,
                  remote.runs.contains(accepted), activeKey == key, flow.presentation?.generation == ticket.generation else { throw Failure(message: "The Prep receipt did not match this request. Check status before sending again.") }
            mutate(key) { $0.draft = remote; $0.pending?.run = accepted; $0.jobState = accepted.state }
            guard persist() else { return }
            active = remote; answer = nil; partialText = ""
            if let job = accepted.jobId, accepted.state == "accepted" { _ = flow.finishSend(ticket, outcome: .accepted(job: job)) }
            else { _ = flow.finishSend(ticket, outcome: .uncertain("Checking the saved request.")) }
            try await settle(accepted, job: response["job"], key: key)
        } catch {
            if activeKey == key, flow.presentation?.generation == ticket.generation { notice = error.localizedDescription }
            _ = flow.finishSend(ticket, outcome: .uncertain("Check the saved request before sending again."))
        }
    }

    /// The fresh POST was refused. Follow the earlier receipt without sending or saving its context again.
    private func trackEarlierRun(_ earlier: MeetingPrep.Run, replacing attempted: MeetingPrepJournal.PendingRun,
                                 draft remote: MeetingPrep.Draft, key: String, ticket: Flow.Request? = nil) throws {
        guard activeKey == key, pending?.clientRequestId == attempted.clientRequestId,
              earlier.clientRequestId != attempted.clientRequestId, earlier.draftRevision < remote.revision,
              let id = UUID(uuidString: earlier.clientRequestId) else { throw CancellationError() }
        var nextFlow = flow
        let message = "An earlier Prep request is being checked. Your new context was kept for a separate send."
        if let ticket {
            guard nextFlow.finishSend(ticket, outcome: .refused(message)) else { throw CancellationError() }
        } else {
            guard let check = nextFlow.beginPreparation(), let previous = UUID(uuidString: attempted.clientRequestId),
                  nextFlow.finishPreparation(check, confirmation: .init(requestID: previous, outcome: .refused(message))) else {
                throw CancellationError()
            }
        }
        guard nextFlow.recoverSubmission(id, draft: .init(text: text, attachments: uploads.attachments)) else { throw CancellationError() }
        mutate(key) { entry in
            entry.pending = .init(clientRequestId: earlier.clientRequestId, revision: earlier.draftRevision,
                                  run: earlier, trackingEarlier: true)
            entry.draft = remote; entry.jobState = earlier.state
            if entry.steer != remote.steer { entry.dirty = true }
        }
        guard persist() else { throw Failure(message: "The earlier Prep receipt could not be saved. Reopen Prep to check it.") }
        flow = nextFlow; active = remote; jobState = earlier.state
        answer = nil; partialText = ""; notice = message
    }

    func checkRequest() async {
        guard !busy, let key = activeKey, let current = active, let pending, let generation = flow.presentation?.generation else { return }
        let operation = beginOperation(); defer { endOperation(operation) }
        do {
            let response = try await request("run-status", fields: ["draftId": current.id, "clientRequestId": pending.clientRequestId])
            guard activeKey == key, flow.presentation?.generation == generation, self.pending?.clientRequestId == pending.clientRequestId else { return }
            if response["httpStatus"]?.int == 404, response["error"]?.string == "run_not_accepted" {
                if let raw = response["run"], case .null = raw { /* No saved receipt. */ }
                else if let raw = response["run"] {
                    let receipt = try runReceipt(raw, draftID: current.id)
                    guard matchesPending(receipt, pending),
                          ["submitting", "failed"].contains(receipt.state), receipt.jobId == nil else {
                        throw Failure(message: "The saved request did not match this Prep revision. Check again before retrying.")
                    }
                    if receipt.state == "failed" {
                        try await settle(receipt, job: nil, key: key)
                        return
                    }
                    mutate(key) { $0.pending?.run = receipt; $0.pending?.retryAllowed = true }
                    guard persist() else { return }
                    notice = "The saved request has not started. Choose Retry request to continue the same request with its original context."
                    return
                }
                let remote = try await readPendingDraft(key: key, requestID: pending.clientRequestId)
                // If the draft moved between the 404 and refresh, keep the fence instead of discarding an observed run.
                if remote.runs.contains(where: { $0.clientRequestId == pending.clientRequestId }) || pending.run?.jobId != nil {
                    throw Failure(message: "The Prep draft still references this request. Check it again before sending.")
                }
                let unresolved = remote.runs.filter {
                    $0.state == "submitting" || ($0.state == "accepted" && !["completed", "failed", "canceled", "interrupted"].contains($0.status ?? ""))
                }
                if let earlier = unresolved.first(where: { $0.state == "submitting" }) ?? unresolved.last {
                    let verified = try validatedRun(earlier, draftID: remote.id)
                    try trackEarlierRun(verified, replacing: pending, draft: remote, key: key)
                    return
                }
                try applyPendingDraft(remote, key: key, preserveContext: true)
                releasePending(key: key, message: "This request was not accepted. Review your context, then choose Prep to send.")
                return
            }
            try checked(response)
            let accepted = try runReceipt(response["run"], draftID: current.id)
            guard matchesPending(accepted, pending) else { throw Failure(message: "The saved request did not match this Prep revision.") }
            mutate(key) { $0.pending?.run = accepted; $0.pending?.retryAllowed = false }; guard persist() else { return }
            try await settle(accepted, job: response["job"], key: key)
        } catch {
            if activeKey == key, flow.presentation?.generation == generation, self.pending?.clientRequestId == pending.clientRequestId {
                if self.pending?.retryAllowed == true {
                    mutate(key) { $0.pending?.retryAllowed = false }
                    _ = persist()
                }
                notice = error.localizedDescription
            }
        }
    }

    /// Explicit recovery replays the frozen request identity; it never saves newer notes or creates a new job identity.
    func retryRequest() async {
        guard canRetryRequest, supported, let key = activeKey, let current = active, let pending, let frozen = pending.run,
              let generation = flow.presentation?.generation else { return }
        let operation = beginOperation(); defer { endOperation(operation) }
        mutate(key) { $0.pending?.retryAllowed = false }
        guard persist() else { return }
        do {
            var payload: [String: Any] = ["clientRequestId": pending.clientRequestId, "revision": pending.revision]
            if let model = frozen.model { payload["model"] = model }
            if let effort = frozen.effort { payload["effort"] = effort }
            if let continuation = frozen.continueRun { payload["continue"] = continuation }
            let response = try await request("run", fields: ["draftId": current.id, "payload": payload])
            guard activeKey == key, flow.presentation?.generation == generation,
                  self.pending?.clientRequestId == pending.clientRequestId else { return }
            if response["httpStatus"]?.int == 409, response["error"]?.string == "run_failed" {
                let failed = try runReceipt(response["run"], draftID: current.id)
                guard matchesPending(failed, pending), failed.state == "failed" else {
                    throw Failure(message: "The failure receipt did not match the saved Prep request.")
                }
                try await settle(failed, job: nil, key: key)
                return
            }
            try checked(response)
            let remote = try draft(response, expected: current.id)
            let accepted = try runReceipt(response["run"], draftID: current.id)
            guard matchesPending(accepted, pending),
                  remote.runs.contains(accepted), activeKey == key, flow.presentation?.generation == generation,
                  self.pending?.clientRequestId == pending.clientRequestId else {
                throw Failure(message: "The Prep receipt did not match the saved request. Check its status before retrying.")
            }
            mutate(key) { $0.draft = remote; $0.pending?.run = accepted; $0.jobState = accepted.state }
            guard persist() else { return }
            active = remote
            try await settle(accepted, job: response["job"], key: key)
        } catch { if activeKey == key, flow.presentation?.generation == generation { notice = error.localizedDescription } }
    }

    private func readPendingDraft(key: String, requestID: String) async throws -> MeetingPrep.Draft {
        guard let current = active, let generation = flow.presentation?.generation, activeKey == key else { throw CancellationError() }
        let response = try await request("get", fields: ["draftId": current.id]); try checked(response)
        let remote = try draft(response, expected: current.id)
        guard activeKey == key, flow.presentation?.generation == generation,
              pending?.clientRequestId == requestID else { throw CancellationError() }
        return remote
    }
    private func applyPendingDraft(_ remote: MeetingPrep.Draft, key: String, preserveContext: Bool = false) throws {
        // Preserve dirty local notes; clean notes follow the refreshed server baseline.
        mutate(key) {
            $0.draft = remote
            if (preserveContext || $0.pending?.trackingEarlier == true) && $0.steer != remote.steer { $0.dirty = true }
            if !$0.dirty { $0.steer = remote.steer }
        }
        guard persist() else { throw Failure(message: "The updated Prep receipt could not be saved. Check again before sending.") }
        active = remote
    }
    private func refreshSettledDraft(key: String) async throws {
        guard let pending else { throw CancellationError() }
        let remote = try await readPendingDraft(key: key, requestID: pending.clientRequestId)
        try applyPendingDraft(remote, key: key)
    }

    private func releasePending(key: String, message: String?) {
        guard let pending = disk.entries.first(where: { $0.id == key })?.pending else { return }
        mutate(key) { $0.pending = nil }; guard persist() else { return }
        if flow.presentation?.phase == .awaitingConfirmation, let check = flow.beginPreparation(), let id = UUID(uuidString: pending.clientRequestId) {
            _ = flow.finishPreparation(check, confirmation: .init(requestID: id, outcome: .refused(message ?? "Prep finished.")))
        } else if case .job(let job) = flow.presentation?.phase, let generation = flow.presentation?.generation {
            _ = flow.finishJob(job, generation: generation)
        }
        if let local = entry, !local.dirty { _ = flow.edit(.init(text: local.steer, attachments: uploads.attachments)) }
        notice = message
    }

    private func settle(_ accepted: MeetingPrep.Run, job value: JSONValue?, key: String) async throws {
        guard activeKey == key else { return }
        if accepted.state == "failed" {
            try await refreshSettledDraft(key: key)
            mutate(key) { $0.jobState = "failed" }; jobState = "failed"
            releasePending(key: key, message: "The Prep request was refused. Your context is kept; review it before sending again.")
            return
        }
        guard accepted.state == "accepted", let jobID = accepted.jobId else {
            jobState = "submitting"; notice = "The server is resolving this request. No new request will be sent."; return
        }
        if flow.presentation?.phase == .awaitingConfirmation, let check = flow.beginPreparation(), let id = UUID(uuidString: accepted.clientRequestId) {
            _ = flow.finishPreparation(check, confirmation: .init(requestID: id, outcome: .accepted(job: jobID)))
        }
        var state = accepted.status
        var result = accepted.answer
        var partial = ""
        if let value, case .null = value { /* A retained run may outlive its job. */ }
        else if let value {
            let job = try decode(MeetingPrep.Job.self, value)
            guard job.jobId == jobID, job.clientJobId == accepted.clientJobId, job.generation == 1,
                  accepted.sessionId == nil || accepted.sessionId == job.sessionId else { throw Failure(message: "The response did not match this Prep job.") }
            state = job.status; result = job.response ?? result; partial = job.partialText
        }
        guard let state else { notice = "The answer is no longer available. The saved request is kept; check again before starting another."; return }
        let terminal = ["completed", "failed", "canceled", "interrupted"].contains(state)
        mutate(key) { $0.jobState = state; if let result { $0.answer = result } }
        guard persist() else { return }
        jobState = state; partialText = partial; if let result { answer = result }
        if terminal {
            try await refreshSettledDraft(key: key)
            releasePending(key: key, message: state == "completed" ? (result == nil ? "The answer is no longer available. Your Prep context is kept." : nil) : "Prep \(state). Your context is kept; review it before another explicit send.")
        }
        else { notice = nil }
    }
}
