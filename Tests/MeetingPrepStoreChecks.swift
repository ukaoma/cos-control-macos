import Foundation
import CryptoKit

// Real store + journal behavior. The closed transport never invokes a helper, provider, or live server.
// Compile/run only after source freeze with a private COS_CONTROL_TEST_HOME and CFFIXED_USER_HOME.
private let prepFixtureStamp = "2026-11-06T18:00:00.000Z"
private let prepFixtureHash = String(repeating: "a", count: 64)
private func prepHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

@MainActor private final class PrepStoreFixture {
    enum Admission: Equatable { case accept, refuse, loseBeforeAdmission, strandBeforeAdmission, failAfterReceipt, loseAfterAdmission }
    enum RunLookup: Equatable { case normal, inFlight, unknown }
    enum FileAdoption: Equatable { case copy, missingMedia, loseAfterCopy }
    enum BlockingReply { case actual, foreignJob, missingFromDraft }
    struct RunOptions: Equatable {
        let model: String?
        let effort: String?
        let continuation: Bool?
    }
    let root: URL
    var server = "prep-fixture-server-a"
    var available = true
    var nextAdmission: Admission = .accept
    var nextFileAdoption: FileAdoption = .copy
    var runLookup: RunLookup = .normal
    var blockingReply: BlockingReply = .actual
    var mismatchFailureReceipt = false
    var foreignDraftServer: String?
    var foreignJobID: String?
    var corruptDownload = false
    var bindingState = "applied"
    var calls: [String] = []
    var runRequestIDs: [String] = []
    var runRevisions: [Int] = []
    var runOptions: [RunOptions] = []
    var updateRevisions: [Int] = []
    var runLookupIDs: [String] = []
    var providerStarts = 0
    var admittedSteers: [String] = []
    var fileDraftIDs: [String] = []
    var fileOperationIDs: [String] = []
    var fileRevisions: [Int] = []
    var fileMedia: [[[String: String]]] = []
    var bindRevisions: [Int] = []
    var photoUploadHash: String?
    let normalizedPhoto = Data("Synthetic /api/media normalized JPEG".utf8)
    private var drafts: [String: [String: Any]] = [:]
    private var draftByClient: [String: String] = [:]
    private var runs: [String: [String: Any]] = [:]
    private var jobs: [String: [String: Any]] = [:]
    private var frozenSteers: [String: String] = [:]
    private var snapshotsBySession: [String: [[String: Any]]] = [:]
    private var heldOperation: String?
    private var held: CheckedContinuation<Void, Never>?
    private var filesSerial = 0
    private var media: [String: (uploadHash: String, stored: Data, photo: Bool)] = [:]
    init(root: URL) { self.root = root }
    var paused: Bool { held != nil }
    func pauseNext(_ operation: String) { heldOperation = operation }
    func resume() { let saved = held; held = nil; saved?.resume() }
    func count(_ operation: String) -> Int { calls.filter { $0 == operation }.count }

    private func reply(_ values: [String: Any] = [:], status: Int = 200) throws -> HelperResponse {
        var out = values
        out["httpStatus"] = status
        out["serverInstanceId"] = server
        let details = try JSONDecoder().decode([String: JSONValue].self, from: JSONSerialization.data(withJSONObject: out))
        return HelperResponse(ok: true, message: "Synthetic Prep transport", details: details)
    }

    private func remote(_ id: String) -> [String: Any] {
        guard var result = drafts[id] else { preconditionFailure("Unknown fixture draft") }
        if let foreignDraftServer { result["serverInstanceId"] = foreignDraftServer }
        return result
    }

    private func runValue(draftID: String, requestID: String, revision: Int,
                          options: RunOptions = .init(model: nil, effort: nil, continuation: true)) -> [String: Any] {
        var hex = Array(prepHash(Data("prep-run:v1:\(draftID):\(requestID)".utf8)).prefix(32))
        hex[12] = "4"; hex[16] = Array("89ab")[hex[16].hexDigitValue! & 3]
        let jobID = [hex[0..<8], hex[8..<12], hex[12..<16], hex[16..<20], hex[20..<32]]
            .map { String($0) }.joined(separator: "-")
        var value: [String: Any] = ["clientRequestId": requestID, "clientJobId": jobID,
            "jobId": NSNull(), "sessionId": NSNull(),
            "draftRevision": revision, "createdAt": prepFixtureStamp, "state": "submitting",
            "fingerprint": prepFixtureHash, "promptSha256": prepFixtureHash, "steerSha256": prepFixtureHash, "files": []]
        if let model = options.model { value["model"] = model }
        if let effort = options.effort { value["effort"] = effort }
        if options.continuation == true { value["continue"] = true }
        return value
    }

    func seedEarlierRun(draftID: String, options: RunOptions) -> String {
        let id = UUID().uuidString.lowercased()
        var value = remote(draftID)
        let revision = value["revision"] as! Int
        let receipt = runValue(draftID: draftID, requestID: id, revision: revision, options: options)
        var saved = value["runs"] as! [[String: Any]]
        saved.append(receipt); value["runs"] = saved
        value["revision"] = revision + 1; drafts[draftID] = value
        runs[id] = receipt; frozenSteers[id] = value["steer"] as? String
        return id
    }

    func failEarlierRun(_ requestID: String, draftID: String) {
        var receipt = runs[requestID]!
        receipt["state"] = "failed"; receipt["error"] = "provider_busy"
        runs[requestID] = receipt
        var value = remote(draftID)
        var saved = value["runs"] as! [[String: Any]]
        saved[saved.firstIndex { $0["clientRequestId"] as? String == requestID }!] = receipt
        value["runs"] = saved
        value["revision"] = (value["revision"] as! Int) + 1
        drafts[draftID] = value
    }

    // Exact relevant QueryJobSnapshot wire names: status and response; never synthetic answer/result aliases.
    private func jobValue(_ run: [String: Any]) -> [String: Any] {
        ["schemaVersion": 1, "jobId": run["jobId"]!, "clientJobId": run["clientJobId"]!, "generation": 1,
         "turnId": "prep_fixture_turn", "requestFingerprint": prepFixtureHash, "status": "running",
         "eventSeq": 2, "oldestEventSeq": 1, "sessionId": run["sessionId"]!, "attachments": [],
         "partialText": "", "partialTruncated": false, "activity": [],
         "acceptedAt": prepFixtureStamp, "updatedAt": prepFixtureStamp, "retentionUntil": "2026-11-13T18:00:00.000Z"]
    }

    func externalSteer(_ id: String, _ text: String) {
        var value = remote(id)
        value["steer"] = text
        value["revision"] = (value["revision"] as! Int) + 1
        drafts[id] = value
    }

    func externalReplaceFileHash(_ draftID: String, fileID: String) {
        var value = remote(draftID)
        var files = value["files"] as! [[String: Any]]
        let index = files.firstIndex { $0["id"] as? String == fileID }!
        files[index]["sha256"] = prepFixtureHash
        value["files"] = files
        value["revision"] = (value["revision"] as! Int) + 1
        drafts[draftID] = value
    }

    func settle(_ requestID: String, status: String, response: String? = nil, partial: String = "") {
        guard let run = runs[requestID], let id = run["jobId"] as? String, var job = jobs[id] else {
            preconditionFailure("No admitted fixture run")
        }
        job["status"] = status; job["partialText"] = partial
        if let response { job["response"] = response }
        if status == "interrupted" {
            job["error"] = ["code": "server_restarted", "message": "Fixture restart interrupted the provider"]
        }
        jobs[id] = job
    }

    private func recordSettlement(_ requestID: String, status: String, answer: String) {
        guard var run = runs[requestID] else { preconditionFailure("No run") }
        guard run["settledAt"] == nil else { return }
        run["status"] = status; run["answer"] = answer; run["settledAt"] = prepFixtureStamp
        runs[requestID] = run
        for key in Array(drafts.keys) {
            var value = drafts[key]!
            var saved = value["runs"] as! [[String: Any]]
            if let index = saved.firstIndex(where: { $0["clientRequestId"] as? String == requestID }) {
                saved[index] = run; value["runs"] = saved
                value["revision"] = (value["revision"] as! Int) + 1
                drafts[key] = value
            }
        }
    }

    func expireJobWithFrozenAnswer(_ requestID: String, answer: String) {
        guard let id = runs[requestID]?["jobId"] as? String else { preconditionFailure("No run") }
        recordSettlement(requestID, status: "completed", answer: answer)
        jobs.removeValue(forKey: id)
    }

    func expireJobWithoutSettlement(_ requestID: String) {
        guard let id = runs[requestID]?["jobId"] as? String else { preconditionFailure("No admitted fixture job") }
        jobs.removeValue(forKey: id)
    }

    func run(_ arguments: [String], _ data: Data?) async throws -> HelperResponse {
        precondition(arguments.count == 3 && arguments[0] == "meeting-prep" && arguments[1] == "--op",
                     "Prep must not dispatch Work, start recording, invoke a generic Ask fallback, or use a live helper")
        let op = arguments[2]; calls.append(op)
        let input = try data.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] } ?? [:]
        if op == heldOperation {
            heldOperation = nil
            await withCheckedContinuation { held = $0 }
        }
        if op == "capabilities" {
            return try reply(["available": available,
                "capability": ["protocol": 1, "maxFiles": 10, "steerChars": 4000,
                               "bind": true, "suggest": true, "serverInstanceId": server]])
        }
        guard input["serverInstanceId"] as? String == server else {
            return try reply(["error": "server_instance_mismatch"], status: 409)
        }
        let payload = input["payload"] as? [String: Any] ?? [:]
        let draftID = input["draftId"] as? String ?? ""
        switch op {
        case "create":
            let client = payload["clientDraftId"] as! String
            if let id = draftByClient[client] { return try reply(["draft": remote(id)]) }
            let suffix = String(UnicodeScalar(97 + drafts.count)!)
            let id = "prep_" + String(repeating: "a", count: 25) + suffix
            drafts[id] = ["id": id, "clientDraftId": client, "serverInstanceId": server,
                "revision": 1, "createdAt": prepFixtureStamp, "updatedAt": prepFixtureStamp,
                "title": payload["title"] ?? "Fixture call", "startsAt": payload["startsAt"] ?? NSNull(),
                "occurrence": NSNull(), "identity": "none", "steer": "", "files": [], "fileOperations": [],
                "runs": [], "conversation": ["sessionId": NSNull()], "bindings": [], "state": "active"]
            draftByClient[client] = id
            return try reply(["draft": remote(id)], status: 201)
        case "get": return try reply(["draft": remote(draftID)])
        case "list": return try reply(["drafts": drafts.keys.sorted().map { remote($0) }])
        case "update":
            updateRevisions.append(payload["revision"] as! Int)
            var value = remote(draftID)
            guard payload["revision"] as? Int == value["revision"] as? Int else {
                return try reply(["error": "revision_conflict", "draft": value], status: 409)
            }
            value["steer"] = payload["steer"] ?? value["steer"]
            value["revision"] = (value["revision"] as! Int) + 1; drafts[draftID] = value
            return try reply(["draft": remote(draftID)])
        case "run":
            let requestID = payload["clientRequestId"] as! String
            runRequestIDs.append(requestID)
            runRevisions.append(payload["revision"] as! Int)
            let options = RunOptions(model: payload["model"] as? String, effort: payload["effort"] as? String,
                                     continuation: payload["continue"] as? Bool)
            runOptions.append(options)
            if var previous = runs[requestID], previous["state"] as? String == "failed" {
                if mismatchFailureReceipt { previous["effort"] = "unrelated-effort" }
                return try reply(["error": "run_failed", "run": previous], status: 409)
            }
            if let previous = runs[requestID], let jobID = previous["jobId"] as? String {
                return try reply(["draft": remote(draftID), "run": previous,
                                  "job": jobs[jobID] as Any? ?? NSNull()], status: 202)
            }
            let mode = nextAdmission; nextAdmission = .accept
            if mode == .refuse { return try reply(["error": "maintenance"], status: 503) }
            if mode == .loseBeforeAdmission { throw URLError(.networkConnectionLost) }
            var value = remote(draftID)
            var receipt: [String: Any]
            var saved = value["runs"] as! [[String: Any]]
            if let previous = runs[requestID] {
                precondition(payload["revision"] as? Int == previous["draftRevision"] as? Int,
                             "Replay sends the original revision, not the current draft revision")
                precondition(options.model == previous["model"] as? String && options.effort == previous["effort"] as? String
                             && (options.continuation == true) == (previous["continue"] as? Bool == true),
                             "Replay sends the original model, effort, and continuation")
                receipt = previous
            } else {
                if var blocking = saved.first(where: { $0["state"] as? String == "submitting" }) {
                    switch blockingReply {
                    case .actual: break
                    case .foreignJob: blocking["clientJobId"] = UUID().uuidString.lowercased()
                    case .missingFromDraft:
                        blocking = runValue(draftID: draftID, requestID: UUID().uuidString.lowercased(),
                                            revision: blocking["draftRevision"] as! Int)
                    }
                    return try reply(["error": "run_in_progress", "run": blocking], status: 409)
                }
                guard payload["revision"] as? Int == value["revision"] as? Int else {
                    return try reply(["error": "revision_conflict", "draft": value], status: 409)
                }
                receipt = runValue(draftID: draftID, requestID: requestID, revision: value["revision"] as! Int, options: options)
                saved.append(receipt); value["runs"] = saved
                value["revision"] = (value["revision"] as! Int) + 1; drafts[draftID] = value
                runs[requestID] = receipt; frozenSteers[requestID] = value["steer"] as? String
            }
            if mode == .strandBeforeAdmission { throw URLError(.networkConnectionLost) }
            if mode == .failAfterReceipt {
                receipt["state"] = "failed"; receipt["error"] = "provider_busy"
                runs[requestID] = receipt
                saved[saved.firstIndex { $0["clientRequestId"] as? String == requestID }!] = receipt
                value["runs"] = saved
                value["revision"] = (value["revision"] as! Int) + 1; drafts[draftID] = value
                return try reply(["error": "provider_busy"], status: 503)
            }
            providerStarts += 1
            admittedSteers.append(frozenSteers[requestID]!)
            let jobID = "prep_job_\(providerStarts)"
            receipt["jobId"] = jobID; receipt["sessionId"] = "prep_conversation_\(providerStarts)"; receipt["state"] = "accepted"
            runs[requestID] = receipt; jobs[jobID] = jobValue(receipt)
            saved[saved.firstIndex { $0["clientRequestId"] as? String == requestID }!] = receipt
            value["runs"] = saved
            value["revision"] = (value["revision"] as! Int) + 1; drafts[draftID] = value
            if mode == .loseAfterAdmission { throw URLError(.networkConnectionLost) }
            return try reply(["draft": remote(draftID), "run": receipt, "job": jobValue(receipt)], status: 202)
        case "run-status":
            let requestID = input["clientRequestId"] as! String
            runLookupIDs.append(requestID)
            guard let accepted = runs[requestID] else { return try reply(["error": "run_not_accepted"], status: 404) }
            if runLookup == .inFlight { return try reply(["run": accepted], status: 202) }
            if runLookup == .unknown { return try reply(["error": "run_status_unknown"], status: 503) }
            if ["submitting", "failed"].contains(accepted["state"] as! String) {
                return try reply(["error": "run_not_accepted", "run": accepted], status: 404)
            }
            var job = (accepted["jobId"] as? String).flatMap { jobs[$0] }
            if let status = job?["status"] as? String, ["completed", "failed", "canceled", "interrupted"].contains(status) {
                recordSettlement(requestID, status: status, answer: job?["response"] as? String ?? "")
            }
            if let foreignJobID { job?["jobId"] = foreignJobID }
            return try reply(["run": runs[requestID]!, "job": job as Any? ?? NSNull()])
        case "job":
            guard let job = jobs[input["jobId"] as? String ?? ""] else { return try reply(["error": "job_not_found"], status: 404) }
            var value = job
            if let foreignJobID { value["jobId"] = foreignJobID }
            return try reply(["job": value])
        case "upload":
            precondition((payload["path"] as? String)?.hasPrefix(root.path + "/") == true,
                         "Fixture uploads read only private fixture files")
            filesSerial += 1
            let mediaID = "m_" + String(format: "%024x", filesSerial)
            let bytes = try Data(contentsOf: URL(fileURLWithPath: payload["path"] as! String))
            let hash = prepHash(bytes)
            let photo = payload["kind"] as? String == "photo"
            if photo { photoUploadHash = hash }
            media[mediaID] = (hash, photo ? normalizedPhoto : bytes, photo)
            return try reply(["transport": "answered", "status": "ok", "mediaId": mediaID])
        case "files":
            let operation = payload["operationId"] as? String ?? ""
            precondition(UUID(uuidString: operation) != nil, "v1.1 durable file operation identity is required")
            fileOperationIDs.append(operation); fileDraftIDs.append(draftID)
            fileRevisions.append(payload["revision"] as! Int)
            fileMedia.append(payload["media"] as! [[String: String]])
            var value = remote(draftID)
            guard payload["revision"] as? Int == value["revision"] as? Int else {
                return try reply(["error": "revision_conflict", "draft": value], status: 409)
            }
            let mode = nextFileAdoption; nextFileAdoption = .copy
            if mode == .missingMedia { return try reply(["error": "media_not_found"], status: 404) }
            var files = value["files"] as! [[String: Any]]
            for item in payload["media"] as! [[String: Any]] where !files.contains(where: { $0["mediaId"] as? String == item["id"] as? String }) {
                let staged = media[item["id"] as! String]!
                precondition(item["sha256"] as? String == staged.uploadHash, "File adoption must pin the uploaded bytes")
                files.append(["id": "pf_" + String(format: "%016x", files.count + 1), "mediaId": item["id"]!,
                    "name": item["name"] ?? "Fixture.pdf", "mime": staged.photo ? "image/jpeg" : "application/pdf",
                    "bytes": staged.stored.count, "sha256": prepHash(staged.stored), "uploadSha256": staged.uploadHash,
                    "addedAt": prepFixtureStamp, "kind": staged.photo ? "image" : "document", "status": "ready",
                    "textChars": 8, "source": "control-local", "sourceRef": item["sourceRef"] ?? ""])
            }
            value["files"] = files; value["revision"] = (value["revision"] as! Int) + 1; drafts[draftID] = value
            if mode == .loseAfterCopy { throw URLError(.networkConnectionLost) }
            return try reply(["draft": remote(draftID)])
        case "bind":
            var value = remote(draftID)
            let sessionID = payload["sessionId"] as! String
            let revision = payload["revision"] as! Int
            bindRevisions.append(revision)
            let prior = (value["bindings"] as! [[String: Any]]).first {
                $0["sessionId"] as? String == sessionID && $0["revision"] as? Int == revision
            }
            guard prior != nil || value["revision"] as? Int == revision else {
                return try reply(["error": "revision_conflict", "draft": value], status: 409)
            }
            let files = (value["files"] as! [[String: Any]]).filter { $0["status"] as? String == "ready" }
            let adopted = files.map { file -> [String: Any] in
                ["id": file["id"]!, "name": file["name"]!, "revision": "copy_revision_\(revision)", "sha256": file["sha256"]!]
            }
            let snapshot = prior?["snapshot"] as? [String: Any] ?? ["draftRevision": revision, "steer": value["steer"]!, "files": adopted]
            var binding: [String: Any] = prior ?? ["sessionId": sessionID, "serverInstanceId": server,
                "revision": revision, "state": bindingState, "boundAt": prepFixtureStamp, "surface": "control",
                "fileIds": files.map { "prep_\(draftID)_\($0["id"] as! String)" }, "snapshot": snapshot,
                "title": value["title"]!, "startsAt": value["startsAt"]!]
            binding["state"] = bindingState
            value["bindings"] = [binding]
            value["revision"] = (value["revision"] as! Int) + 1
            drafts[draftID] = value
            snapshotsBySession[sessionID] = [snapshot.merging([
                "draftId": draftID, "sessionId": sessionID, "title": binding["title"]!, "startsAt": binding["startsAt"]!,
                "state": bindingState, "surface": "control", "boundAt": prepFixtureStamp, "current": true
            ], uniquingKeysWith: { first, _ in first })]
            return try reply(["draft": value, "files": []])
        case "session":
            return try reply(["snapshots": snapshotsBySession[input["sessionId"] as! String] ?? []])
        case "download":
            let fileID = input["fileId"] as! String
            let files = remote(draftID)["files"] as! [[String: Any]]
            let file = files.first { $0["id"] as? String == fileID }!
            let original = media[file["mediaId"] as! String]!.stored
            precondition(input["sha256"] as? String == prepHash(original) && input["bytes"] as? Int == original.count,
                         "Download must pin the frozen file's stored bytes, not the upload bytes")
            let data = corruptDownload ? Data(repeating: 0, count: original.count) : original
            let destination = root.appendingPathComponent("fixture-download-\(count("download")).bin")
            try data.write(to: destination)
            return try reply(["path": destination.path, "sha256": prepHash(data), "bytes": data.count])
        default: preconditionFailure("Unmocked Prep operation: \(op)")
        }
    }
}

@MainActor private struct PrepHarness {
    let fixture: PrepStoreFixture
    let store: MeetingPrepStore
    let launch: MeetingPrepStore.Launch
    let root: URL
    let ordinary: MeetingPrepStore.Flow.Draft
    func freshStore() -> MeetingPrepStore {
        let value = MeetingPrepStore()
        value.journalRoot = root.appendingPathComponent("journal")
        value.run = { args, data in try await fixture.run(args, data) }
        return value
    }
}

@MainActor private func prepHarness(_ root: URL, _ name: String) async throws -> PrepHarness {
    let home = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let ordinaryFile = home.appendingPathComponent("ordinary.pdf")
    try Data("ordinary attachment".utf8).write(to: ordinaryFile)
    let attachment = DropIt.Attachment(id: "ordinary-file", name: "ordinary.pdf", kind: .doc, mime: "application/pdf",
        bytes: 19, source: ordinaryFile, state: .ready, mediaId: "m_" + String(repeating: "f", count: 24), owned: [ordinaryFile])
    let ordinary = MeetingPrepStore.Flow.Draft(text: "Unsent ordinary Ask words", attachments: [attachment])
    let fixture = PrepStoreFixture(root: home)
    let store = MeetingPrepStore()
    store.journalRoot = home.appendingPathComponent("journal")
    store.run = { args, data in try await fixture.run(args, data) }
    let launch = MeetingPrepStore.Launch(title: "Fixture call", startsAt: prepFixtureStamp)
    let result = PrepHarness(fixture: fixture, store: store, launch: launch, root: home, ordinary: ordinary)
    await store.open(launch, ordinary: ordinary)
    store.uploads.stagingRoot = home.appendingPathComponent("uploads")
    precondition(store.active != nil && store.canSend, "Fixture must open a ready real Prep store")
    return result
}

@MainActor private func eventually(_ label: String, _ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    preconditionFailure("Timed out: \(label)")
}

@main struct MeetingPrepStoreChecks {
    @MainActor static func main() async throws {
        guard let home = ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"], home.hasPrefix("/tmp/"),
              ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]?.hasPrefix("/tmp/") == true else {
            preconditionFailure("Run with a private /tmp test home and CFFIXED_USER_HOME; never the real journals")
        }
        let root = URL(fileURLWithPath: home).appendingPathComponent("prep-store-checks-" + UUID().uuidString)
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }

        // Opening/closing Prep never submits a job or consumes the ordinary Ask snapshot.
        do {
            let h = try await prepHarness(root, "ordinary")
            h.store.setText("Separate Prep notes")
            check(h.fixture.providerStarts == 0 && h.fixture.count("run") == 0, "Opening and editing are not provider actions")
            check(h.store.close() == h.ordinary, "Restore exact ordinary text and ordered attachment values")
            check(FileManager.default.fileExists(atPath: h.ordinary.attachments[0].source.path), "Prep close must not delete ordinary Ask's owned file")
            await h.store.open(h.launch, ordinary: h.ordinary)
            check(h.store.text == "Separate Prep notes", "Unsent Prep notes persist independently")
            check(h.fixture.providerStarts == 0, "Reopen must not auto-run Prep")
        }

        // Older-server mode remains an explicit plain Ask and restores the separate ordinary draft.
        do {
            let h = try await prepHarness(root, "older-server")
            _ = h.store.close()
            h.fixture.available = false
            var plainRequests: [String] = []
            h.store.plainAsk = { text, _ in plainRequests.append(text); return false }
            await h.store.open(h.launch, ordinary: h.ordinary)
            check(!h.store.supported && h.store.canSend && plainRequests.isEmpty, "Unsupported Prep does not submit a plain Ask automatically")
            h.store.setText("Explicit plain Ask words")
            let sent = await h.store.sendPlainAsk()
            check(!sent && plainRequests == ["Explicit plain Ask words"] && h.store.text == "Explicit plain Ask words",
                  "A failed explicit plain Ask preserves its composer")
            check(h.store.close() == h.ordinary && h.fixture.providerStarts == 0, "Fallback cannot consume the ordinary draft or run Prep")
        }

        // A lost response after admission recovers the original job across a real journal reload, exactly once.
        do {
            let h = try await prepHarness(root, "lost-response")
            h.store.setText("Review the supplied agenda")
            h.fixture.nextAdmission = .loseAfterAdmission
            await h.store.send()
            let request = h.store.pending!.clientRequestId
            check(h.fixture.providerStarts == 1 && !h.store.canSend, "Unknown response retains duplicate-send fence")
            _ = h.store.close()
            let restarted = h.freshStore()
            await restarted.open(h.launch, ordinary: h.ordinary)
            check(restarted.pending?.clientRequestId == request && !restarted.canSend, "Restart retains original request identity")
            check(h.fixture.count("run") == 1, "Restart never reissues POST run")
            h.fixture.settle(request, status: "completed", response: "Exact query-job response")
            await restarted.checkRequest()
            check(restarted.answer == "Exact query-job response", "Decode real QueryJobSnapshot.response")
            check(restarted.pending == nil && restarted.canSend, "Terminal accepted job releases the fence")
            check(h.fixture.providerStarts == 1 && h.fixture.runRequestIDs == [request], "Status recovery does not launch a second job")
            _ = restarted.close()
            let again = h.freshStore()
            await again.open(h.launch, ordinary: h.ordinary)
            check(again.answer == "Exact query-job response", "Recovered answer survives another restart")
        }

        // Neither a definitive rejection nor a transport loss before admission can permanently poison this draft.
        for (name, mode) in [("refused", PrepStoreFixture.Admission.refuse), ("not-admitted", .loseBeforeAdmission)] {
            let h = try await prepHarness(root, name)
            h.store.setText("Please prepare this call")
            h.fixture.nextAdmission = mode
            await h.store.send()
            if h.store.pending != nil { await h.store.checkRequest() }
            check(h.fixture.providerStarts == 0 && h.store.pending == nil && h.store.canSend, "Authoritative run_not_accepted releases the saved request")
            await h.store.send()
            check(h.fixture.providerStarts == 1 && h.fixture.count("run") == 2, "Only a new explicit send starts work after refusal")
        }

        do {
            let h = try await prepHarness(root, "failed-receipt")
            let initialRevision = h.store.active!.revision
            h.fixture.nextAdmission = .failAfterReceipt
            await h.store.send()
            let request = h.store.pending!.clientRequestId
            check(!h.store.canSend && h.fixture.providerStarts == 0, "A failed POST alone cannot release the admission fence")
            await h.store.checkRequest()
            check(h.fixture.runLookupIDs == [request] && h.store.pending == nil && h.store.jobState == "failed"
                  && h.store.canSend && !h.store.canRetryRequest,
                  "Matching authoritative 404 with a failed receipt releases the fence without enabling replay")
            check(h.store.active?.revision == initialRevision + 2 && h.store.recoveryDrafts.first?.draft?.revision == initialRevision + 2,
                  "Release refreshes the draft after both the receipt write and the failure write")
            await h.store.send()
            check(h.fixture.providerStarts == 1 && h.fixture.runRequestIDs.last != request
                  && h.fixture.runRevisions.last == initialRevision + 2,
                  "A new explicit send uses the refreshed revision and its own request ID")
        }

        // Simulate the crash window after local intent fsync but before any POST reached the server.
        do {
            let h = try await prepHarness(root, "crash-before-post")
            let revision = h.store.active!.revision
            _ = h.store.close()
            let journal = MeetingPrepJournal(root: h.root.appendingPathComponent("journal"), server: h.fixture.server)
            var snapshot = try journal.read()
            let expected = snapshot.generation
            let request = UUID().uuidString.lowercased()
            snapshot.entries[0].pending = .init(clientRequestId: request, revision: revision)
            _ = try journal.write(snapshot, expected: expected)
            let restarted = h.freshStore()
            await restarted.open(h.launch, ordinary: h.ordinary)
            check(!restarted.canSend && restarted.pending?.clientRequestId == request, "Pre-admission intent is recovered conservatively")
            await restarted.checkRequest()
            check(restarted.pending == nil && restarted.canSend && h.fixture.count("run") == 0, "Lookup resolves crash window without issuing a provider request")
        }

        // An in-flight or indeterminate status cannot authorize a second admission. Only an authoritative
        // 404 with a stranded receipt enables explicit replay of the same frozen request, even after edits.
        do {
            let h = try await prepHarness(root, "submitting")
            h.store.setText("Frozen context at the original revision")
            h.fixture.nextAdmission = .strandBeforeAdmission
            await h.store.send()
            let request = h.store.pending!.clientRequestId
            check(h.fixture.providerStarts == 0 && !h.store.canSend, "A lost response with a stranded receipt stays fenced")
            _ = h.store.close()
            let restarted = h.freshStore()
            await restarted.open(h.launch, ordinary: h.ordinary)
            check(restarted.pending?.clientRequestId == request && !restarted.canSend, "Restart keeps the stranded request and its fence")

            h.fixture.runLookup = .inFlight
            await restarted.checkRequest()
            await restarted.retryRequest()
            await restarted.send()
            check(restarted.pending?.clientRequestId == request && !restarted.canSend && h.fixture.runRequestIDs == [request],
                  "HTTP 202 submitting keeps the fence; neither Send nor Retry issues another POST")

            h.fixture.runLookup = .unknown
            await restarted.checkRequest()
            await restarted.retryRequest()
            await restarted.send()
            check(restarted.pending?.clientRequestId == request && !restarted.canSend && h.fixture.runRequestIDs == [request],
                  "HTTP 503 run_status_unknown keeps the fence; neither Send nor Retry issues another POST")

            h.fixture.runLookup = .normal
            h.fixture.externalSteer(restarted.active!.id, "A later edit cannot change the frozen run")
            await restarted.checkRequest()
            check(restarted.pending?.clientRequestId == request && !restarted.canSend && h.fixture.providerStarts == 0,
                  "Authoritative 404 with a stranded receipt retains the identity and does not start work")
            await restarted.send()
            check(h.fixture.runRequestIDs == [request], "A fresh Send cannot replace the stranded request with a new ID")
            await restarted.retryRequest()
            check(h.fixture.runRequestIDs == [request, request] && h.fixture.providerStarts == 1
                  && h.fixture.admittedSteers == ["Frozen context at the original revision"],
                  "Explicit retry replays the original ID and frozen prompt exactly once")

            h.fixture.settle(request, status: "completed", response: "Admission settled")
            await restarted.checkRequest()
            check(restarted.answer == "Admission settled" && restarted.canSend, "The original submitting request can settle normally")
            check(h.fixture.runLookupIDs == [request, request, request, request], "Status lookups keep the same request identity throughout recovery")
        }

        // A newly attempted ID can be refused in favor of a distinct frozen earlier request.
        do {
            let h = try await prepHarness(root, "blocked-by-earlier-run")
            let draftID = h.store.active!.id
            let frozenOptions = PrepStoreFixture.RunOptions(model: "claude-sonnet", effort: "high", continuation: nil)
            h.fixture.externalSteer(draftID, "Earlier Web context")
            let earlier = h.fixture.seedEarlierRun(draftID: draftID, options: frozenOptions)
            await h.store.refreshDraft()
            h.store.setText("New desktop context")
            await h.store.send()
            check(h.store.pending?.clientRequestId == earlier && !h.store.canSend && !h.store.canRetryRequest
                  && h.fixture.runRequestIDs.count == 1 && h.fixture.providerStarts == 0,
                  "409 run_in_progress transfers the durable fence to the earlier run without retrying it")
            let attempted = h.fixture.runRequestIDs[0]
            check(attempted != earlier && h.store.text == "New desktop context", "The earlier request never consumes new notes")

            h.fixture.runLookup = .inFlight
            await h.store.checkRequest()
            await h.store.retryRequest()
            h.fixture.runLookup = .unknown
            await h.store.checkRequest()
            await h.store.retryRequest()
            check(h.fixture.runRequestIDs == [attempted] && h.fixture.runLookupIDs == [earlier, earlier],
                  "In-flight and unknown status of the earlier run authorize no POST")
            h.fixture.runLookup = .normal
            await h.store.checkRequest()
            check(h.store.canRetryRequest && h.store.pending?.clientRequestId == earlier, "Authoritative 404 authorizes only the earlier replay")
            h.fixture.externalSteer(draftID, "A later server edit")
            await h.store.retryRequest()
            check(h.fixture.runRequestIDs == [attempted, earlier] && h.fixture.runOptions.last == frozenOptions
                  && h.fixture.admittedSteers == ["Earlier Web context"] && h.fixture.providerStarts == 1,
                  "Explicit replay preserves the earlier ID, original model and effort, and omitted continuation")
            h.fixture.settle(earlier, status: "completed", response: "Earlier answer")
            await h.store.checkRequest()
            check(h.store.canSend && h.store.answer == "Earlier answer" && h.store.text == "New desktop context",
                  "Earlier settlement keeps new typed notes even if another client edited the draft")
            await h.store.send()
            check(h.fixture.admittedSteers == ["Earlier Web context", "New desktop context"]
                  && h.fixture.runRequestIDs.last != earlier && h.fixture.runRequestIDs.last != attempted,
                  "New notes run only after their own subsequent explicit send")
        }
        for (name, reply) in [("foreign-blocking-receipt", PrepStoreFixture.BlockingReply.foreignJob),
                              ("unlisted-blocking-receipt", .missingFromDraft)] {
            let h = try await prepHarness(root, name)
            let earlier = h.fixture.seedEarlierRun(draftID: h.store.active!.id, options: .init(model: nil, effort: nil, continuation: true))
            h.fixture.blockingReply = reply
            await h.store.send()
            let attempted = h.fixture.runRequestIDs[0]
            check(h.store.pending?.clientRequestId == attempted && attempted != earlier && !h.store.canRetryRequest
                  && h.fixture.providerStarts == 0, "Malformed or unlisted 409 receipt cannot redirect the local pending identity")
            h.fixture.foreignDraftServer = "foreign-fixture-server"
            await h.store.checkRequest()
            check(h.store.pending?.clientRequestId == attempted && !h.store.canSend,
                  "No-receipt 404 cannot release the fence before the draft refresh is verified")
            h.fixture.foreignDraftServer = nil
            await h.store.checkRequest()
            check(h.store.pending?.clientRequestId == earlier && !h.store.canSend && !h.store.canRetryRequest
                  && h.fixture.runRequestIDs == [attempted], "Verified draft refresh can recover an earlier unresolved receipt without posting")
        }
        for mismatch in [false, true] {
            let h = try await prepHarness(root, mismatch ? "mismatched-run-failed" : "matching-run-failed")
            h.fixture.nextAdmission = .strandBeforeAdmission
            await h.store.send()
            let request = h.store.pending!.clientRequestId
            await h.store.checkRequest()
            check(h.store.canRetryRequest, "Authoritative stranded receipt enables explicit retry")
            h.fixture.failEarlierRun(request, draftID: h.store.active!.id)
            h.fixture.mismatchFailureReceipt = mismatch
            await h.store.retryRequest()
            check(h.fixture.runRequestIDs == [request, request] && h.fixture.providerStarts == 0,
                  "Failed replay returns 409 without starting a provider")
            if mismatch {
                check(h.store.pending?.clientRequestId == request && !h.store.canSend && !h.store.canRetryRequest,
                      "Failure receipt with mismatched frozen options cannot release the fence")
                await h.store.checkRequest()
            }
            check(h.store.pending == nil && h.store.canSend && h.store.jobState == "failed",
                  "Only a matching failed receipt refreshes the draft and releases the fence")
        }

        // Exact terminal states, foreign job rejection, and retained run answer after query-job expiry.
        do {
            let h = try await prepHarness(root, "foreign-job")
            await h.store.send()
            let request = h.store.pending!.clientRequestId
            h.fixture.settle(request, status: "completed", response: "Must not display a foreign answer")
            h.fixture.foreignJobID = "foreign_job"
            await h.store.checkRequest()
            check(h.store.answer == nil && h.store.pending?.clientRequestId == request && !h.store.canSend,
                  "Foreign job identity cannot settle this draft or expose its answer")
            check(h.store.notice != nil, "Foreign job rejection remains visible")
            h.fixture.foreignJobID = nil
            await h.store.checkRequest()
            check(h.store.canSend, "A later matching job can recover after the foreign response")
        }
        do {
            let h = try await prepHarness(root, "interrupted")
            await h.store.send()
            let request = h.store.pending!.clientRequestId
            h.fixture.settle(request, status: "interrupted", partial: "Incomplete provider output")
            await h.store.checkRequest()
            check(h.store.jobState == "interrupted" && h.store.pending == nil && h.store.canSend, "Interrupted is terminal, not an eternal running fence")
            check(h.store.partialText == "Incomplete provider output", "Interrupted partial output remains distinct from a completed answer")
            check(h.store.notice != nil, "Interruption remains visible instead of claiming completion")
        }
        do {
            let h = try await prepHarness(root, "retained-answer")
            await h.store.send()
            let request = h.store.pending!.clientRequestId
            h.fixture.expireJobWithFrozenAnswer(request, answer: "Frozen Prep answer")
            await h.store.checkRequest()
            check(h.store.answer == "Frozen Prep answer" && h.store.pending == nil, "Frozen run survives ordinary job retention")
            check(h.fixture.providerStarts == 1, "Expired query-job lookup must not start another provider")
        }
        do {
            let h = try await prepHarness(root, "missing-job-without-settlement")
            await h.store.send()
            let request = h.store.pending!.clientRequestId
            h.fixture.expireJobWithoutSettlement(request)
            await h.store.checkRequest()
            check(h.store.pending?.clientRequestId == request && !h.store.canSend && !h.store.canRetryRequest
                  && h.store.notice?.contains("could not confirm") == true,
                  "An accepted receipt without a job or terminal status stays fenced and explains the uncertainty")
            await h.store.send()
            check(h.fixture.count("run") == 1 && h.fixture.providerStarts == 1,
                  "An unavailable job snapshot never permits another provider dispatch")
        }

        // The status lookup can commit the frozen terminal answer and advance the draft CAS revision.
        do {
            let h = try await prepHarness(root, "terminal-revision")
            await h.store.send()
            let firstRequest = h.store.pending!.clientRequestId
            let firstAcceptedRevision = h.store.active!.revision
            h.fixture.settle(firstRequest, status: "completed", response: "First terminal answer")
            await h.store.checkRequest()
            check(h.store.canSend && h.store.active?.revision == firstAcceptedRevision + 1
                  && h.store.recoveryDrafts.first?.draft?.revision == firstAcceptedRevision + 1,
                  "Terminal polling refreshes and persists the new CAS baseline before re-enabling Prep")
            await h.store.send()
            check(h.fixture.providerStarts == 2 && h.fixture.runRevisions.last == firstAcceptedRevision + 1,
                  "A clean follow-up uses the revision bumped by terminal status, without manual refresh")

            let secondRequest = h.store.pending!.clientRequestId
            let secondAcceptedRevision = h.store.active!.revision
            h.fixture.settle(secondRequest, status: "completed", response: "Second terminal answer")
            await h.store.checkRequest()
            h.store.setText("New notes after the follow-up")
            let notesSaved = await h.store.saveNotes()
            check(notesSaved && h.fixture.updateRevisions.last == secondAcceptedRevision + 1
                  && h.store.active?.steer == "New notes after the follow-up",
                  "Saving edited notes after settlement uses the refreshed CAS baseline")
        }

        // A clean composer adopts a fresh remote steer; dirty local notes survive a revision refresh for explicit review.
        do {
            let h = try await prepHarness(root, "clean-refresh")
            h.fixture.externalSteer(h.store.active!.id, "New notes from the other client")
            await h.store.refreshDraft()
            check(h.store.text == "New notes from the other client", "Clean refresh must display the context the next run will use")
            await h.store.send()
            check(h.fixture.admittedSteers == [h.store.text], "Provider receives the visible refreshed steer")
        }
        do {
            let h = try await prepHarness(root, "dirty-refresh")
            h.store.setText("My unsent local notes")
            h.fixture.externalSteer(h.store.active!.id, "Other client's change")
            await h.store.refreshDraft()
            check(h.store.text == "My unsent local notes" && h.store.notice != nil, "Dirty local steer is retained with review notice")
            await h.store.send()
            check(h.fixture.admittedSteers == ["My unsent local notes"], "Explicit send saves the user's reviewed local steer")
        }

        // Two store instances share the real CAS journal. Failure must preserve the other writer and allow safe reopen.
        do {
            let h = try await prepHarness(root, "journal-cas")
            let second = h.freshStore()
            await second.open(h.launch, ordinary: h.ordinary)
            second.setText("Other writer's saved notes")
            _ = second.close() // explicit flush is part of close's public contract
            h.store.setText("My unsaved recovery copy")
            _ = h.store.close()
            let journal = MeetingPrepJournal(root: h.root.appendingPathComponent("journal"), server: h.fixture.server)
            let conflicted = try journal.read()
            check(conflicted.entries.contains { $0.steer == "Other writer's saved notes" }, "Failed CAS cannot erase the winning writer")
            await h.store.open(h.launch, ordinary: h.ordinary)
            check(h.store.canSend, "Reopen reloads CAS generation instead of permanently retaining diskFailed")
            let recoveryFiles = try FileManager.default.contentsOfDirectory(at: h.root.appendingPathComponent("journal"), includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("recovery-") && $0.pathExtension == "json" }
            let copies = try recoveryFiles.map { try JSONDecoder().decode(MeetingPrepJournal.Snapshot.self, from: Data(contentsOf: $0)) }
            check(copies.contains { $0.entries.contains { $0.steer == "My unsaved recovery copy" } }, "The losing local words survive in a separate on-disk recovery copy")
            check(h.store.text == "My unsaved recovery copy", "Recovered local notes remain visible for explicit review")
            check(h.fixture.providerStarts == 0, "Journal recovery never runs a provider")
        }

        // A status response returning after the user switches drafts must not settle the new presentation.
        do {
            let h = try await prepHarness(root, "late-job")
            await h.store.send()
            let request = h.store.pending!.clientRequestId
            h.fixture.settle(request, status: "completed", response: "Only belongs to draft A")
            h.fixture.pauseNext("run-status")
            let checking = Task { await h.store.checkRequest() }
            try await eventually("old job lookup reached transport") { h.fixture.paused }
            _ = h.store.close()
            let next = MeetingPrepStore.Launch(title: "Draft B")
            await h.store.open(next, ordinary: h.ordinary)
            let idB = h.store.active!.id
            h.fixture.resume()
            await checking.value
            check(h.store.active?.id == idB && h.store.answer == nil && h.store.pending == nil,
                  "Late A status cannot overwrite B's answer, identity, or pending state")
            check(h.fixture.providerStarts == 1, "Switching during status recovery never launches another provider")
        }

        do {
            let h = try await prepHarness(root, "late-note-save")
            h.store.setText("Local context for the first presentation")
            h.fixture.pauseNext("update")
            let sending = Task { await h.store.send() }
            try await eventually("notes PATCH reached transport") { h.fixture.paused }
            _ = h.store.close()
            await h.store.open(h.launch, ordinary: h.ordinary)
            let reopenedRevision = h.store.active!.revision
            h.fixture.resume()
            await sending.value
            check(h.fixture.count("update") == 1 && h.fixture.count("run") == 0 && h.store.pending == nil,
                  "Closing and reopening the same draft during note save cannot send from the old button")
            check(h.store.active?.revision == reopenedRevision && h.store.recoveryDrafts.first?.dirty == true
                  && h.store.text == "Local context for the first presentation",
                  "Late note-save response cannot rewrite the reopened composer's baseline or clear its recovery notes")
            await h.store.refreshDraft()
            await h.store.send()
            check(h.fixture.admittedSteers == ["Local context for the first presentation"],
                  "The reopened draft can still send its reviewed notes explicitly")
        }

        // Delayed upload completion from A cannot land in B. A keeps either its pending chip or durable file.
        do {
            let h = try await prepHarness(root, "upload-isolation")
            let file = h.root.appendingPathComponent("Agenda-A.pdf")
            try Data("fixture agenda".utf8).write(to: file)
            let uploadsA = h.store.uploads
            h.fixture.pauseNext("upload")
            uploadsA.attach([(url: file, name: "Agenda-A.pdf")])
            try await eventually("upload reached fake transport") { h.fixture.paused }
            check(h.store.close() == h.ordinary, "Closing an upload restores ordinary Ask without mixing its files")
            let next = MeetingPrepStore.Launch(title: "Another call", startsAt: prepFixtureStamp)
            await h.store.open(next, ordinary: h.ordinary)
            let secondID = h.store.active!.id
            check(h.store.uploads.attachments.isEmpty, "New draft must not inherit A's attachment chips")
            h.fixture.resume()
            try await eventually("old upload settled") { !uploadsA.attachments.contains(where: \.busy) }
            await h.store.saveUploadedFiles()
            check(!h.fixture.fileDraftIDs.contains(secondID) && h.store.active!.currentFiles.isEmpty, "Late upload must never be adopted into B")
            _ = h.store.close()
            await h.store.open(h.launch, ordinary: h.ordinary)
            check(h.store.uploads.attachments.contains { $0.name == "Agenda-A.pdf" }
                  || h.store.active!.currentFiles.contains { $0.name == "Agenda-A.pdf" }, "Returning to A retains A's pending or saved file")
            await h.store.saveUploadedFiles()
            try await eventually("A's original is durably saved") { h.store.active?.currentFiles.contains { $0.name == "Agenda-A.pdf" } == true }
            check(!h.fixture.fileDraftIDs.contains(secondID), "Automatic upload adoption preserves the original draft identity")
            check(!h.fixture.fileOperationIDs.isEmpty, "Files use v1.1 operation identity")
        }

        do {
            let h = try await prepHarness(root, "file-save-steer")
            let file = h.root.appendingPathComponent("Latest agenda.pdf")
            try Data("fixture current agenda".utf8).write(to: file)
            let remoteNotes = "New notes saved before uploading the agenda"
            h.fixture.externalSteer(h.store.active!.id, remoteNotes)
            h.store.uploads.attach([(url: file, name: file.lastPathComponent)])
            try await eventually("file and clean steer adopted") { h.store.active?.currentFiles.count == 1 && !h.store.busy }
            check(h.store.text == remoteNotes && h.store.recoveryDrafts.first?.steer == remoteNotes
                  && h.store.recoveryDrafts.first?.dirty == false,
                  "Successful file copy displays and persists the clean steer at the adopted revision")
            await h.store.send()
            check(h.fixture.admittedSteers == [remoteNotes] && h.fixture.count("update") == 0,
                  "Prep runs exactly the visible, clean context without writing it back")
        }
        do {
            let h = try await prepHarness(root, "file-save-dirty-steer")
            let file = h.root.appendingPathComponent("Draft agenda.pdf")
            try Data("fixture draft agenda".utf8).write(to: file)
            h.fixture.externalSteer(h.store.active!.id, "Notes from another client")
            h.fixture.pauseNext("files")
            h.store.uploads.attach([(url: file, name: file.lastPathComponent)])
            try await eventually("file copy reached transport") { h.fixture.paused }
            let localNotes = "Newer local notes while the file is saving"
            h.store.setText(localNotes)
            h.fixture.resume()
            try await eventually("file adopted with dirty local steer") { h.store.active?.currentFiles.count == 1 && !h.store.busy }
            check(h.store.text == localNotes && h.store.recoveryDrafts.first?.steer == localNotes
                  && h.store.recoveryDrafts.first?.dirty == true,
                  "Successful file copy preserves newer dirty local notes")
            await h.store.send()
            check(h.fixture.admittedSteers == [localNotes], "The explicit send saves and runs the preserved local notes")
        }

        // A concurrent edit between GET and POST advances CAS without changing the durable upload intent.
        do {
            let h = try await prepHarness(root, "file-cas")
            let draftID = h.store.active!.id
            let originalRevision = h.store.active!.revision
            let file = h.root.appendingPathComponent("Review copy.pdf")
            try Data("fixture file CAS".utf8).write(to: file)
            h.fixture.pauseNext("files")
            h.store.uploads.attach([(url: file, name: "Review copy.pdf")])
            try await eventually("first file adoption reached the transport") { h.fixture.paused }
            let originalBatch = h.store.recoveryDrafts.first!.fileOperation!
            h.fixture.externalSteer(draftID, "Another client edited Prep")
            h.fixture.resume()
            try await eventually("authenticated file revision conflict returned") { !h.store.busy }

            let recoveredBatch = h.store.recoveryDrafts.first!.fileOperation!
            check(h.fixture.count("files") == 1 && h.store.active?.currentFiles.isEmpty == true && h.store.notice != nil,
                  "The conflict does not write files or silently retry")
            check(recoveredBatch.id == originalBatch.id && recoveredBatch.media == originalBatch.media
                  && originalBatch.revision == originalRevision && recoveredBatch.revision == originalRevision + 1
                  && h.store.active?.revision == recoveredBatch.revision,
                  "Authenticated conflict updates only the batch and draft revision, keeping the original upload identity and media")

            await h.store.saveUploadedFiles()
            check(h.fixture.fileOperationIDs == [originalBatch.id, originalBatch.id]
                  && h.fixture.fileRevisions == [originalRevision, originalRevision + 1]
                  && h.fixture.fileMedia.count == 2 && h.fixture.fileMedia[0] == h.fixture.fileMedia[1],
                  "Explicit retry sends the exact same operation ID and media, changing only the CAS revision")
            check(h.store.active?.currentFiles.map(\.name) == ["Review copy.pdf"]
                  && h.store.recoveryDrafts.first?.fileOperation == nil && h.store.recoveryDrafts.first?.files.isEmpty == true,
                  "Successful replay adopts one file and clears its durable queue")
        }

        for (name, mode) in [("queued-missing-media", PrepStoreFixture.FileAdoption.missingMedia), ("queued-lost-copy", .loseAfterCopy)] {
            let h = try await prepHarness(root, name)
            let file = h.root.appendingPathComponent("Queued review copy.pdf")
            try Data("queued fixture file".utf8).write(to: file)
            h.fixture.nextFileAdoption = mode
            h.store.uploads.attach([(url: file, name: file.lastPathComponent)])
            try await eventually("queued file POST finished") { h.fixture.count("files") == 1 && !h.store.busy }
            let queued = h.store.queuedFiles[0]
            _ = h.store.close()

            let restarted = h.freshStore()
            await restarted.open(h.launch, ordinary: h.ordinary)
            check(restarted.uploads.attachments.isEmpty && restarted.queuedFiles == [queued]
                  && restarted.hasQueuedFiles && !restarted.canSend,
                  "Restart exposes durable queued files and fences Prep without relying on upload chips")
            await restarted.send()
            check(h.fixture.count("files") == 1 && h.fixture.providerStarts == 0,
                  "Reopen and Send do not implicitly retry a queued file POST or start Prep")

            restarted.removeQueuedFile(sourceRef: queued.sourceRef)
            if mode == .missingMedia {
                check(restarted.queuedFiles.isEmpty && !restarted.hasQueuedFiles && restarted.canSend
                      && restarted.recoveryDrafts.first?.fileOperation == nil,
                      "Definitive media_not_found permits discarding the queued file and unblocks Prep")
            } else {
                check(restarted.queuedFiles == [queued] && restarted.hasQueuedFiles && !restarted.canSend && restarted.notice != nil,
                      "Removal is refused while the lost POST may already have saved the file")
                await restarted.saveUploadedFiles()
                check(restarted.queuedFiles.isEmpty && !restarted.hasQueuedFiles && restarted.canSend
                      && restarted.active?.currentFiles.map(\.name) == [file.lastPathComponent] && h.fixture.count("files") == 1,
                      "Explicit reconciliation recognizes the already saved original and clears its queue without a second POST")
            }
        }

        // /api/media normalizes the photo again after Control's own JPEG encoding. The store must adopt it
        // using uploadSha256 but pin the kept bytes' sha256 for a saved meeting's original download.
        do {
            let h = try await prepHarness(root, "normalized-photo")
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFElEQVR4nGP4z8DAAMIM////ZwAAHu8E/KPItPcAAAAASUVORK5CYII=")!
            h.store.uploads.attachImage(png)
            try await eventually("photo whose stored bytes differ from the upload is adopted") {
                h.store.active?.currentFiles.count == 1 && h.store.uploads.attachments.isEmpty && !h.store.busy
            }
            let file = h.store.active!.currentFiles[0]
            let storedHash = prepHash(h.fixture.normalizedPhoto)
            check(file.kind == "image" && file.sha256 == storedHash && file.uploadSha256 == h.fixture.photoUploadHash
                  && file.uploadSha256 != storedHash, "Photo keeps separate upload and stored-original hashes")
            check(h.fixture.count("files") == 1 && h.store.recoveryDrafts.first?.files.isEmpty == true
                  && h.store.recoveryDrafts.first?.fileOperation == nil,
                  "A verified transformed photo clears the pending upload and operation journal")

            h.store.setText("Notes the meeting actually received")
            let notesSaved = await h.store.saveNotes()
            check(notesSaved, "Save notes before the explicit bind")
            let bound = h.store.active!
            let session = "meeting_frozen_photo"
            try await h.store.bind(bound, session: session)
            h.fixture.externalSteer(bound.id, "New draft notes after the meeting was bound")
            let snapshots = try await h.store.meetingSnapshots(session: session)
            check(snapshots.count == 1, "Saved review reads exactly the bound meeting snapshot")
            let snapshot = snapshots[0]
            check(snapshot.draftRevision == bound.revision && snapshot.steer == "Notes the meeting actually received",
                  "Saved review still shows the notes and revision frozen at bind")
            check(snapshot.files.count == 1 && snapshot.files[0].sha256 == storedHash && snapshot.files[0].id == file.id,
                  "Frozen file records the kept original hash rather than the pre-normalization upload hash")
            let original = try await h.store.downloadSnapshotFile(snapshot.files[0], snapshot: snapshot)
            let downloaded = try Data(contentsOf: original)
            check(downloaded == h.fixture.normalizedPhoto && h.fixture.count("download") == 1, "Saved review opens the exact stored bytes")

            h.fixture.corruptDownload = true
            var refused = false
            do { _ = try await h.store.downloadSnapshotFile(snapshot.files[0], snapshot: snapshot) }
            catch { refused = true }
            check(refused && h.fixture.count("download") == 2, "Saved review refuses a same-size download with a mismatching hash")

            h.fixture.externalReplaceFileHash(bound.id, fileID: file.id)
            refused = false
            do { _ = try await h.store.downloadSnapshotFile(snapshot.files[0], snapshot: snapshot) }
            catch { refused = true }
            check(refused && h.fixture.count("download") == 2, "A newer draft file hash cannot replace the saved original or request a download")
        }

        // Server replacement or a foreign draft body cannot silently move this local journal onto another server.
        do {
            let h = try await prepHarness(root, "server-switch")
            h.store.setText("Keep these local words")
            h.fixture.server = "prep-fixture-server-b"
            await h.store.send()
            check(h.fixture.providerStarts == 0 && h.store.text == "Keep these local words", "Foreign server cannot receive a Prep run")
            check(h.store.notice != nil, "Server mismatch remains visible")
        }
        do {
            let h = try await prepHarness(root, "foreign-draft")
            let revision = h.store.active!.revision
            h.fixture.foreignDraftServer = "foreign-server"
            await h.store.refreshDraft()
            check(h.store.active?.serverInstanceId == h.fixture.server && h.store.active?.revision == revision,
                  "A matching transport envelope cannot launder a foreign draft")
            check(h.store.notice != nil, "Foreign draft is rejected visibly")
        }

        // An applying receipt is not proof that context has been carried into the selected recording.
        do {
            let h = try await prepHarness(root, "binding")
            h.fixture.bindingState = "applying"
            var refused = false
            do { try await h.store.bind(h.store.active!, session: "meeting_fixture") }
            catch { refused = true }
            check(refused, "Only an applied binding can confirm carried Prep")
            let snapshots = try await h.store.meetingSnapshots(session: "meeting_fixture")
            let original = snapshots[0]
            h.fixture.externalSteer(original.draftId, "Later draft notes cannot change the pending attachment")
            h.fixture.bindingState = "applied"
            try await h.store.retryBinding(original)
            let settled = try await h.store.meetingSnapshots(session: "meeting_fixture")
            check(h.fixture.bindRevisions == [original.draftRevision, original.draftRevision] && h.fixture.providerStarts == 0
                  && settled.first?.steer == original.steer && settled.first?.state == "applied",
                  "Retry confirms the exact frozen binding after a later draft edit, without starting Prep")
        }

        print("PASS MeetingPrep real store: \(checks) assertions covering admission recovery, frozen downloads, transformed uploads, job DTOs, journal CAS, draft isolation, and server identity")
    }
}
