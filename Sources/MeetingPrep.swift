import Foundation

/// Local presentation state only. The adapter owns server DTOs, durable storage, uploads and jobs.
/// Attachment values are retained unchanged; this type never copies or deletes their files.
struct MeetingPrepState<Attachment: Equatable & Sendable>: Sendable {
    struct Draft: Equatable, Sendable {
        var text: String
        var attachments: [Attachment]
        init(text: String = "", attachments: [Attachment] = []) {
            self.text = text
            self.attachments = attachments
        }
    }

    enum Phase: Equatable, Sendable {
        case needsPreparation, preparing, ready, sending, awaitingConfirmation
        case job(String)
    }

    /// An opaque draft key (clientDraftId until the server returns its id). Never derive it from a title or a day.
    struct Request: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case prepare, send }
        let id: UUID
        let kind: Kind
        let occurrence: String
        let generation: UUID
        let revision: UUID
        let draft: Draft
    }

    enum SendOutcome: Equatable, Sendable {
        case accepted(job: String)
        /// Use only for a definitive refusal, not a timeout or a cancelled HTTP request.
        case refused(String)
        case uncertain(String)
    }

    /// A fresh authoritative read can reconcile a previous uncertain send. This is not a wire DTO.
    struct Confirmation: Sendable {
        let requestID: UUID
        let outcome: SendOutcome
    }

    struct Presentation: Sendable {
        let occurrence: String
        let generation: UUID
        let ordinaryDraft: Draft
        fileprivate(set) var draft: Draft
        fileprivate(set) var revision: UUID
        fileprivate(set) var phase: Phase
        fileprivate(set) var notice: String?
        fileprivate var pending: Request?
    }

    private struct Remembered: Sendable {
        var draft: Draft
        var unresolved: Request?
        var job: String?
    }

    private(set) var presentation: Presentation?
    private var remembered: [String: Remembered] = [:]

    /// Opening is not sending. Refuse a second opener so it cannot replace either composer's words.
    @discardableResult
    mutating func open(occurrence: String, ordinaryDraft: Draft) -> Bool {
        guard presentation == nil, !occurrence.isEmpty else { return false }
        let saved = remembered[occurrence]
        presentation = Presentation(occurrence: occurrence, generation: UUID(), ordinaryDraft: ordinaryDraft,
                                    draft: saved?.draft ?? Draft(), revision: UUID(), phase: .needsPreparation)
        return true
    }

    /// Editing invalidates a read in flight. Sending/running must settle before another turn is edited.
    @discardableResult
    mutating func edit(_ draft: Draft) -> Bool {
        guard var current = presentation else { return false }
        switch current.phase {
        case .sending, .awaitingConfirmation, .job: return false
        default: break
        }
        guard current.draft != draft else { return true }
        current.draft = draft
        current.revision = UUID()
        if current.phase == .preparing {
            current.pending = nil
            current.phase = .needsPreparation
        }
        current.notice = nil
        presentation = current
        remember(current)
        return true
    }

    mutating func beginPreparation() -> Request? {
        guard var current = presentation else { return nil }
        switch current.phase {
        case .needsPreparation, .ready, .awaitingConfirmation: break
        default: return nil
        }
        let request = ticket(.prepare, current)
        current.phase = .preparing
        current.pending = request
        current.notice = nil
        presentation = current
        return request
    }

    /// A draft from the server may replace the displayed draft only when this exact local revision is still current.
    /// An uncertain send stays fenced unless the fresh read explicitly confirms that same request's disposition.
    @discardableResult
    mutating func finishPreparation(_ request: Request, draft: Draft? = nil, confirmation: Confirmation? = nil) -> Bool {
        guard matches(request, kind: .prepare), var current = presentation else { return false }
        var saved = remembered[current.occurrence] ?? Remembered(draft: current.draft)
        if let confirmation {
            guard saved.unresolved?.id == confirmation.requestID else { return false }
            apply(confirmation.outcome, to: &saved, notice: &current.notice)
        }
        if let draft { current.draft = draft; current.revision = UUID() }
        saved.draft = current.draft
        remembered[current.occurrence] = saved
        current.pending = nil
        current.phase = phase(saved)
        presentation = current
        return true
    }

    @discardableResult
    mutating func failPreparation(_ request: Request, message: String) -> Bool {
        guard matches(request, kind: .prepare), var current = presentation else { return false }
        current.pending = nil
        current.phase = .needsPreparation
        current.notice = message
        presentation = current
        return true
    }

    /// The UI's explicit Prep/Send action is the only caller. Content/capability validation belongs to the adapter.
    mutating func beginSend() -> Request? {
        guard var current = presentation, current.phase == .ready,
              remembered[current.occurrence]?.unresolved == nil,
              remembered[current.occurrence]?.job == nil else { return nil }
        let request = ticket(.send, current)
        remembered[current.occurrence] = Remembered(draft: current.draft, unresolved: request)
        current.phase = .sending
        current.pending = request
        current.notice = nil
        presentation = current
        return request
    }

    @discardableResult
    mutating func finishSend(_ request: Request, outcome: SendOutcome) -> Bool {
        guard matches(request, kind: .send), var current = presentation,
              var saved = remembered[current.occurrence], saved.unresolved?.id == request.id else { return false }
        apply(outcome, to: &saved, notice: &current.notice)
        remembered[current.occurrence] = saved
        current.pending = nil
        current.phase = phase(saved)
        presentation = current
        return true
    }

    /// A terminal poll from the current presentation enables the next explicit conversational turn.
    @discardableResult
    mutating func finishJob(_ job: String, generation: UUID) -> Bool {
        guard var current = presentation, current.generation == generation, current.phase == .job(job),
              var saved = remembered[current.occurrence], saved.job == job else { return false }
        saved.job = nil
        remembered[current.occurrence] = saved
        current.phase = .ready
        presentation = current
        return true
    }

    /// Dismisses this UI, not a server job. Keeps an uncertain submission fenced across close/reopen.
    /// The caller restores this exact ordinary snapshot; ordinary attachments were never consumed by Prep.
    @discardableResult
    mutating func cancel() -> Draft? {
        guard let current = presentation else { return nil }
        remember(current)
        presentation = nil
        return current.ordinaryDraft
    }

    func unresolvedRequest(for occurrence: String) -> Request? { remembered[occurrence]?.unresolved }

    /// Restore the duplicate-send fence from this draft's private recovery journal, without issuing a request.
    @discardableResult
    mutating func recoverSubmission(_ id: UUID, draft: Draft) -> Bool {
        guard var current = presentation, current.phase == .ready,
              remembered[current.occurrence]?.unresolved == nil, remembered[current.occurrence]?.job == nil else { return false }
        let request = Request(id: id, kind: .send, occurrence: current.occurrence, generation: current.generation,
                              revision: current.revision, draft: draft)
        remembered[current.occurrence] = Remembered(draft: current.draft, unresolved: request)
        current.phase = .awaitingConfirmation
        presentation = current
        return true
    }

    private func ticket(_ kind: Request.Kind, _ current: Presentation) -> Request {
        Request(id: UUID(), kind: kind, occurrence: current.occurrence, generation: current.generation,
                revision: current.revision, draft: current.draft)
    }

    private func matches(_ request: Request, kind: Request.Kind) -> Bool {
        guard let current = presentation else { return false }
        return request.kind == kind && current.pending == request && current.occurrence == request.occurrence
            && current.generation == request.generation && current.revision == request.revision
    }

    private mutating func remember(_ current: Presentation) {
        var saved = remembered[current.occurrence] ?? Remembered(draft: current.draft)
        saved.draft = current.draft
        remembered[current.occurrence] = saved
    }

    private func phase(_ saved: Remembered) -> Phase {
        if let job = saved.job { return .job(job) }
        return saved.unresolved == nil ? .ready : .awaitingConfirmation
    }

    private func apply(_ outcome: SendOutcome, to saved: inout Remembered, notice: inout String?) {
        switch outcome {
        case .accepted(let job): saved.job = job; saved.unresolved = nil; notice = nil
        case .refused(let message): saved.unresolved = nil; notice = message
        case .uncertain(let message): notice = message
        }
    }
}

// MARK: Prep v1 data, separate from the local presentation state above

enum MeetingPrep {
    struct Capability: Decodable, Sendable {
        let `protocol`: Int
        let maxFiles: Int
        let steerChars: Int
        let bind: Bool
        let suggest: Bool
        var supported: Bool { `protocol` == 1 && maxFiles > 0 && maxFiles <= 10 && steerChars > 0 && steerChars <= 4000 }
    }

    struct File: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let mediaId: String
        let name: String
        let mime: String
        let bytes: Int
        let sha256: String
        let addedAt: String
        let kind: String
        let status: String
        let notice: String?
        let textChars: Int
        let source: String
        let sourceRef: String?
        var uploadSha256: String? = nil
    }

    struct Run: Codable, Equatable, Sendable {
        let clientRequestId: String
        let clientJobId: String
        let jobId: String?
        let sessionId: String?
        let draftRevision: Int
        let createdAt: String
        let state: String
        let status: String?
        let answer: String?
        var model: String? = nil
        var effort: String? = nil
        var continueRun: Bool? = nil

        enum CodingKeys: String, CodingKey {
            case clientRequestId, clientJobId, jobId, sessionId, draftRevision, createdAt, state, status, answer, model, effort
            case continueRun = "continue"
        }
    }

    struct Conversation: Codable, Equatable, Sendable { let sessionId: String? }

    struct Occurrence: Codable, Equatable, Sendable {
        let key: String
        let provider: String
        let account: String?
        let calendarId: String
        let eventId: String?
        let externalId: String?
        let startsAt: String
        let endsAt: String?
    }

    struct SessionSnapshot: Decodable, Identifiable, Sendable {
        struct File: Decodable, Identifiable, Sendable {
            let id: String
            let name: String
            let revision: String
            let sha256: String
        }
        let draftId: String
        let sessionId: String
        let surface: String
        let state: String
        let boundAt: String
        let removedAt: String?
        let draftRevision: Int
        let title: String
        let startsAt: String?
        let steer: String
        let files: [File]
        let held: Bool?
        let current: Bool?
        var id: String { draftId + ":" + sessionId + ":" + String(draftRevision) + ":" + boundAt }
    }

    struct Binding: Codable, Equatable, Sendable {
        let sessionId: String
        let serverInstanceId: String
        let revision: Int
        let state: String
        let boundAt: String
        let surface: String
        let fileIds: [String]
        let removedAt: String?
    }

    struct Draft: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let clientDraftId: String
        let serverInstanceId: String?
        let revision: Int
        let createdAt: String
        let updatedAt: String
        let title: String
        let startsAt: String?
        let occurrence: Occurrence?
        let identity: String
        let steer: String
        let files: [File]
        let runs: [Run]
        let conversation: Conversation
        let bindings: [Binding]
        let state: String
        var currentFiles: [File] { files.filter { $0.status != "removed" } }
        var valid: Bool {
            Self.validID(id) && !clientDraftId.isEmpty && clientDraftId.utf8.count <= 200 && revision >= 0
                && title.count <= 500 && steer.count <= 4000 && files.count <= 100
                && files.allSatisfy { file in
                    file.id.range(of: "\\Apf_[a-f0-9]{16}\\z", options: .regularExpression) != nil
                        && file.name.utf8.count <= 1000 && file.bytes >= 0 && file.bytes <= 100 * 1024 * 1024
                        && file.sha256.range(of: "\\A[a-f0-9]{64}\\z", options: .regularExpression) != nil
                        && (file.uploadSha256 == nil || file.uploadSha256?.range(of: "\\A[a-f0-9]{64}\\z", options: .regularExpression) != nil)
                }
                && Set(files.map(\.id)).count == files.count
        }
        static func validID(_ value: String) -> Bool {
            value.range(of: "\\Aprep_[a-z2-7]{26}\\z", options: .regularExpression) != nil
        }
    }

    struct Job: Decodable, Sendable {
        let jobId: String
        let clientJobId: String
        let generation: Int
        let status: String
        let sessionId: String
        let partialText: String
        let response: String?
        var terminal: Bool { ["completed", "failed", "canceled", "interrupted"].contains(status) }
    }
}
