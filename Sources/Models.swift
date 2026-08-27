import AppKit
import Foundation

enum JSONValue: Codable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var int: Int? { if case .number(let value) = self { Int(value) } else { nil } }
    var double: Double? { if case .number(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}

struct HelperResponse: Codable, Sendable {
    let ok: Bool
    let message: String
    let details: [String: JSONValue]
}

struct ServerStatus: Sendable {
    var installed = false
    var serviceLoaded = false
    var running = false
    var managedContract = false
    var runtimeState = "unknown"
    var ownershipVerified = false
    var ownerConflict = false
    var launchAgentKind = "absent"
    var transactionPending = false
    var desiredState = "running"
    var serviceDisabled = false
    var recoveryInstalled = false
    var recoveryLoaded = false
    var version: String?
    var installedVersion: String?
    var workDirectory: String?
    var activeWorkDirectory: String?
    var workDirectoryPending = false
    var operationsDirectory: String?
    var meetingLibraryLayout = "standalone"
    var meetingLibraryCount = 0
    var meetingLibraryWarning: String?
    var contextBrowserSupported = false
    var contextAvailable: Bool?
    var contextState: String?
    var contextProtocol: Int?
    var contextScriptsDirectory: String?
    /// Set when Memory and Threads come from plain markdown rather than the
    /// Python bridge. Exactly one of the two is populated.
    var contextFilesDirectory: String?
    /// The root the server will actually resolve, or nil when none holds notes.
    var contextResolvedRoot: String?
    /// Roots consulted in order, so the panel can say where it looked.
    var contextCandidateRoots: [String] = []
    /// Where a Create would put memory/ and threads/.
    var contextSuggestedRoot: String?
    /// A complete Python bridge sitting unused because COS_SCRIPTS_DIR is unset.
    var dormantBridgeScripts: String?
    var memoryAvailable: Bool?
    var memoryCount = 0
    var memoryState: String?
    var threadsAvailable: Bool?
    var threadCount = 0
    var activeThreadCount = 0
    var threadState: String?
    var safeToRestart = false
    var activeJobs: Int?
    var activeTranscriptionSessions: Int?
    var backgroundJobsSupported = false
    var backgroundJobsEnabled: Bool?
    var meetingPreviewSupported = false
    var meetingPreviewEnabled: Bool?
    var threadAttachSupported = false
    var threadAttachEnabled: Bool?
    /// Optional on purpose: absent means a server too old to report it, and the
    /// panel must then leave the toggle where it is rather than force it off.
    var claudeSessionsEnabled: Bool?
    var threadAttachProviders: [String] = []
    /// The configured COS_OLLAMA_MODEL pin; nil means automatic (newest pull).
    var ollamaConfiguredModel: String?
    var videoUploadV2Supported = false
    var videoUploadV2Enabled: Bool?
    var videoUploadV2Receiving = 0
    var videoUploadV2Finalizing = 0
    var videoUploadV2Unacknowledged = 0
    var videoUploadV2BlocksRollback = false
    var idleMetalHqSupported = false
    var idleMetalHqEnabled: Bool?
    var idleMetalHqForceCpu: Bool?
    var adaptiveAudioCleanupSupported = false
    var adaptiveAudioCleanupEnabled: Bool?
    var whisperReady = false
    var whisperCircuitOpen = false
    var whisperStartupState: String?
    var whisperError: String?
    var livePreviewModel: String?
    var livePreviewReady: Bool?
    var livePreviewDegraded = false

    /// `active` | `unavailable` | `error`, straight from /api/health. nil means an
    /// older server that predates the field -- treated as "say nothing", never as
    /// broken, so an upgrade path does not start nagging.
    var speakerId: String?
    /// Named diarization is off unless the server says `active`. nil stays quiet.
    var speakerIdNeedsSetup: Bool { speakerId != nil && speakerId != "active" }
    var liveCommitModel: String?
    var transcriptionRequestedTier: String?
    var transcriptionEffectiveTier: String?
    var transcriptionRequestedCommitModel: String?
    var transcriptionTierDegraded = false
    var transcriptionTierReason: String?
    var hqPolishModel: String?
    var hqPolishReady: Bool?
    var transcriptionVocabularyTerms: Int?
    var apiURL = "http://127.0.0.1:3141"
    var cursorReady = false
    var cursorState = "unavailable"
    var cursorDetail: String?
    var meetingSyncActive = false
    var meetingSyncPercent: Int?
    var meetingSyncLabel = "Idle"
    var meetingSyncBlocksRestart = false
    var meetingSyncCount = 0
    var earlyMeetingSyncEnabled: Bool?
    var earlyMeetingSyncRequested: Bool?
    var earlyMeetingSyncAvailable: Bool?
    var earlyMeetingSyncReason: String?
    var earlyMeetingSyncInFlight = false
    var earlyMeetingSyncPendingCount = 0
    var earlyMeetingSyncLastOutcome: String?
    var earlyMeetingSyncLastError: String?
    var earlyMeetingSyncLastAt: String?
    var progressiveHqEnabled: Bool?
    var progressiveHqRequested: Bool?
    var progressiveHqTier: String?
    var progressiveHqMode: String?
    var progressiveHqThreads: Int?
    var progressiveHqReason: String?
    var progressiveHqActive = false
    var progressiveHqSealedDone = 0
    var progressiveHqSealedTotal = 0
    var meetingFinalizationPending = 0
    var meetingFinalizationFailed = 0
    var meetingFinalizationLastError: String?
    var meetingFinalizationMalformed = 0
    /// Quarantined unsaved meeting captures (server 6.19.0+). 0 on older
    /// servers — the key is simply absent from health.
    var unsavedCaptures = 0
    /// Per-CLI readiness for the three agent backends. nil = unknown (server
    /// too old to publish `features`, or unreachable) — deliberately distinct
    /// from false so the UI never shows a confident red on missing data.
    var claudeCliReady: Bool?

    /// Ollama local-model state (server 6.39.0+). nil = unknown or an older
    /// server; the About row renders ONLY on true + a non-empty model, so nil
    /// can never paint a red mark on a server that predates the feature.
    var ollamaReady: Bool?
    var ollamaModel: String?
    var claudeCliVersion: String?
    var codexCliReady: Bool?
    var codexCliVersion: String?
    var cursorCliVersion: String?

    init() {}

    init(_ details: [String: JSONValue]) {
        installed = details["installed"]?.bool ?? false
        serviceLoaded = details["serviceLoaded"]?.bool ?? false
        running = details["running"]?.bool ?? false
        managedContract = details["managedContract"]?.bool ?? false
        runtimeState = details["runtimeState"]?.string ?? "unknown"
        ownershipVerified = details["ownershipVerified"]?.bool ?? false
        ownerConflict = details["ownerConflict"]?.bool ?? false
        launchAgentKind = details["launchAgentKind"]?.string ?? "absent"
        transactionPending = details["transactionPending"]?.bool ?? false
        desiredState = details["desiredState"]?.string ?? "running"
        serviceDisabled = details["serviceDisabled"]?.bool ?? false
        recoveryInstalled = details["recoveryInstalled"]?.bool ?? false
        recoveryLoaded = details["recoveryLoaded"]?.bool ?? false
        version = details["version"]?.string
        installedVersion = details["installedVersion"]?.string
        workDirectory = details["workDirectory"]?.string
        activeWorkDirectory = details["activeWorkDirectory"]?.string
        workDirectoryPending = details["workDirectoryPending"]?.bool ?? false
        operationsDirectory = details["operationsDirectory"]?.string
        meetingLibraryLayout = details["meetingLibraryLayout"]?.string ?? "standalone"
        meetingLibraryCount = details["meetingLibraryCount"]?.int ?? 0
        meetingLibraryWarning = details["meetingLibraryWarning"]?.string
        contextBrowserSupported = details["contextBrowserSupported"]?.bool ?? false
        contextAvailable = details["contextAvailable"]?.bool
        contextState = details["contextState"]?.string
        contextProtocol = details["contextProtocol"]?.int
        contextScriptsDirectory = details["contextScriptsDirectory"]?.string
        contextFilesDirectory = details["contextFilesDirectory"]?.string
        contextResolvedRoot = details["contextResolvedRoot"]?.string
        contextCandidateRoots = details["contextCandidateRoots"]?.array?.compactMap { $0.string } ?? []
        contextSuggestedRoot = details["contextSuggestedRoot"]?.string
        dormantBridgeScripts = details["dormantBridgeScripts"]?.string
        memoryAvailable = details["memoryAvailable"]?.bool
        memoryCount = details["memoryCount"]?.int ?? 0
        memoryState = details["memoryState"]?.string
        threadsAvailable = details["threadsAvailable"]?.bool
        threadCount = details["threadCount"]?.int ?? 0
        activeThreadCount = details["activeThreadCount"]?.int ?? 0
        threadState = details["threadState"]?.string
        safeToRestart = details["safeToRestart"]?.bool ?? false
        activeJobs = details["activeJobs"]?.int
        activeTranscriptionSessions = details["activeTranscriptionSessions"]?.int
        backgroundJobsSupported = details["backgroundJobsSupported"]?.bool ?? false
        backgroundJobsEnabled = details["backgroundJobsEnabled"]?.bool
        meetingPreviewSupported = details["meetingPreviewSupported"]?.bool ?? false
        meetingPreviewEnabled = details["meetingPreviewEnabled"]?.bool
        threadAttachSupported = details["threadAttachSupported"]?.bool ?? false
        threadAttachEnabled = details["threadAttachEnabled"]?.bool
        claudeSessionsEnabled = details["claudeSessionsEnabled"]?.bool
        threadAttachProviders = (details["threadAttachProviders"]?.array ?? []).compactMap(\.string)
        ollamaConfiguredModel = details["ollamaConfiguredModel"]?.string
        videoUploadV2Supported = details["videoUploadV2Supported"]?.bool ?? false
        videoUploadV2Enabled = details["videoUploadV2Enabled"]?.bool
        videoUploadV2Receiving = details["videoUploadV2Receiving"]?.int ?? 0
        videoUploadV2Finalizing = details["videoUploadV2Finalizing"]?.int ?? 0
        videoUploadV2Unacknowledged = details["videoUploadV2Unacknowledged"]?.int ?? 0
        videoUploadV2BlocksRollback = details["videoUploadV2BlocksRollback"]?.bool ?? false
        idleMetalHqSupported = details["idleMetalHqSupported"]?.bool ?? false
        idleMetalHqEnabled = details["idleMetalHqEnabled"]?.bool
        idleMetalHqForceCpu = details["idleMetalHqForceCpu"]?.bool
        adaptiveAudioCleanupSupported = details["adaptiveAudioCleanupSupported"]?.bool ?? false
        adaptiveAudioCleanupEnabled = details["adaptiveAudioCleanupEnabled"]?.bool
        whisperReady = details["whisperReady"]?.bool ?? false
        whisperCircuitOpen = details["whisperCircuitOpen"]?.bool ?? false
        whisperStartupState = details["whisperStartupState"]?.string
        whisperError = details["whisperError"]?.string
        livePreviewModel = details["livePreviewModel"]?.string
        livePreviewReady = details["livePreviewReady"]?.bool
        livePreviewDegraded = details["livePreviewDegraded"]?.bool ?? false
        speakerId = details["speakerId"]?.string
        liveCommitModel = details["liveCommitModel"]?.string
        transcriptionRequestedTier = details["transcriptionRequestedTier"]?.string
        transcriptionEffectiveTier = details["transcriptionEffectiveTier"]?.string
        transcriptionRequestedCommitModel = details["transcriptionRequestedCommitModel"]?.string
        transcriptionTierDegraded = details["transcriptionTierDegraded"]?.bool ?? false
        transcriptionTierReason = details["transcriptionTierReason"]?.string
        hqPolishModel = details["hqPolishModel"]?.string
        hqPolishReady = details["hqPolishReady"]?.bool
        transcriptionVocabularyTerms = details["transcriptionVocabularyTerms"]?.int
        apiURL = details["apiURL"]?.string ?? apiURL
        cursorReady = details["cursorReady"]?.bool ?? false
        cursorState = details["cursorState"]?.string ?? "unavailable"
        cursorDetail = details["cursorDetail"]?.string
        meetingSyncActive = details["meetingSyncActive"]?.bool ?? false
        meetingSyncPercent = details["meetingSyncPercent"]?.int
        meetingSyncLabel = details["meetingSyncLabel"]?.string ?? (meetingSyncActive ? "Syncing…" : "Idle")
        meetingSyncBlocksRestart = details["meetingSyncBlocksRestart"]?.bool ?? meetingSyncActive
        meetingSyncCount = details["meetingSyncCount"]?.int ?? 0
        earlyMeetingSyncEnabled = details["earlyMeetingSyncEnabled"]?.bool
        earlyMeetingSyncRequested = details["earlyMeetingSyncRequested"]?.bool
        earlyMeetingSyncAvailable = details["earlyMeetingSyncAvailable"]?.bool
        earlyMeetingSyncReason = details["earlyMeetingSyncReason"]?.string
        earlyMeetingSyncInFlight = details["earlyMeetingSyncInFlight"]?.bool ?? false
        earlyMeetingSyncPendingCount = details["earlyMeetingSyncPendingCount"]?.int ?? 0
        earlyMeetingSyncLastOutcome = details["earlyMeetingSyncLastOutcome"]?.string
        earlyMeetingSyncLastError = details["earlyMeetingSyncLastError"]?.string
        earlyMeetingSyncLastAt = details["earlyMeetingSyncLastAt"]?.string
        progressiveHqEnabled = details["progressiveHqEnabled"]?.bool
        progressiveHqRequested = details["progressiveHqRequested"]?.bool
        progressiveHqTier = details["progressiveHqTier"]?.string
        progressiveHqMode = details["progressiveHqMode"]?.string
        progressiveHqThreads = details["progressiveHqThreads"]?.int
        progressiveHqReason = details["progressiveHqReason"]?.string
        progressiveHqActive = details["progressiveHqActive"]?.bool ?? false
        progressiveHqSealedDone = details["progressiveHqSealedDone"]?.int ?? 0
        progressiveHqSealedTotal = details["progressiveHqSealedTotal"]?.int ?? 0
        meetingFinalizationPending = details["meetingFinalizationPending"]?.int ?? 0
        meetingFinalizationFailed = details["meetingFinalizationFailed"]?.int ?? 0
        meetingFinalizationLastError = details["meetingFinalizationLastError"]?.string
        meetingFinalizationMalformed = details["meetingFinalizationMalformed"]?.int ?? 0
        unsavedCaptures = details["unsavedCaptures"]?.int ?? 0
        claudeCliReady = details["claudeCliReady"]?.bool
        ollamaReady = details["ollamaReady"]?.bool
        ollamaModel = details["ollamaModel"]?.string
        claudeCliVersion = details["claudeCliVersion"]?.string
        codexCliReady = details["codexCliReady"]?.bool
        codexCliVersion = details["codexCliVersion"]?.string
        cursorCliVersion = details["cursorCliVersion"]?.string
    }
}

/// One Memory or Thread row, as browsed from the desktop.
///
/// Read-only by construction: no mutation route exists behind any of this, and
/// Control has no send path to the agent. `filePath` is present only for the file
/// tier, where a record IS a file and the desktop can reveal it — something the
/// glasses cannot do.
struct ContextRecord: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var body: String
    var createdAt: String
    /// nil for a vector-store record, which has no file behind it.
    var filePath: String?
    var meetingCount: Int = 0
    var isResolved: Bool = false

    static func memory(_ raw: [String: JSONValue]) -> ContextRecord {
        ContextRecord(
            id: raw["id"]?.string ?? "",
            title: raw["summary"]?.string ?? raw["content"]?.string ?? "(untitled)",
            subtitle: [raw["type"]?.string, raw["created_at"]?.string].compactMap { $0 }.joined(separator: " · "),
            body: raw["content"]?.string ?? "",
            createdAt: raw["created_at"]?.string ?? "",
            filePath: raw["filePath"]?.string
        )
    }

    static func thread(_ raw: [String: JSONValue]) -> ContextRecord {
        let meetings = raw["meeting_count"]?.int ?? 0
        let topics = raw["topics"]?.array?.compactMap { $0.string } ?? []
        return ContextRecord(
            id: raw["id"]?.string ?? "",
            title: raw["name"]?.string ?? "(untitled)",
            subtitle: [
                meetings > 0 ? "\(meetings) meeting\(meetings == 1 ? "" : "s")" : nil,
                topics.isEmpty ? nil : topics.prefix(3).joined(separator: ", "),
                raw["is_resolved"]?.bool == true ? "resolved" : nil,
            ].compactMap { $0 }.joined(separator: " · "),
            body: (raw["manual_updates"]?.array?.compactMap { $0.object?["content"]?.string } ?? []).joined(separator: "\n\n"),
            createdAt: raw["last_seen"]?.string ?? raw["created_at"]?.string ?? "",
            filePath: raw["filePath"]?.string,
            meetingCount: meetings,
            isResolved: raw["is_resolved"]?.bool == true
        )
    }
}

/// A native thread COS has shut because an earlier turn may already have landed.
///
/// The server addresses a fence by DIGEST and never emits the raw target key, which
/// embeds the private native thread id — so `target` is the only handle there is,
/// and it is what the release call sends back.
struct FenceRecord: Identifiable, Equatable {
    var id: String { target }
    var target: String
    var provider: String
    var reason: String
    /// The thread head as it stood BEFORE the ambiguous turn. Absent only when the
    /// failure happened before the head was read.
    var headBefore: String?
    var turnId: String
    var fencedAt: Double

    static func from(_ raw: [String: JSONValue]) -> FenceRecord {
        FenceRecord(
            target: raw["target"]?.string ?? "",
            provider: raw["provider"]?.string ?? "",
            reason: raw["reason"]?.string ?? "",
            headBefore: raw["headBefore"]?.string,
            turnId: raw["turnId"]?.string ?? "",
            fencedAt: raw["fencedAt"]?.double ?? 0
        )
    }

    var fencedAtLabel: String {
        guard fencedAt > 0 else { return "unknown time" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: Date(timeIntervalSince1970: fencedAt / 1000))
    }

    /// What the user is actually being told. The server's own copy is 126
    /// characters, which is right for a Mac panel and far too long for the lens.
    var explanation: String {
        "An earlier turn on this thread may or may not have been delivered. "
            + "Open the thread on your Mac and check before releasing this."
    }
}

/// Quarantined meeting audio that Control can turn into a saved call.
///
/// Distinct from Speakers' "Meetings to review" — those are identity
/// corrections on already-saved meetings. This is unsaved capture recovery.
struct OrphanCapture: Identifiable, Sendable {
    let sessionId: String
    let chunkFiles: Int
    let ageHours: Double?
    let recovered: Bool
    let recovering: Bool
    let recoverable: Bool
    let expiresAt: String

    var id: String { sessionId }

    var label: String {
        let chunks = chunkFiles == 1 ? "1 chunk" : "\(chunkFiles) chunks"
        if recovering { return "\(shortId) · recovering · \(chunks)" }
        if let ageHours {
            return "\(shortId) · \(chunks) · \(ageHours)h"
        }
        return "\(shortId) · \(chunks)"
    }

    var shortId: String {
        sessionId.count > 18 ? String(sessionId.prefix(18)) + "…" : sessionId
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let sessionId = o["sessionId"]?.string, !sessionId.isEmpty else { return nil }
        self.sessionId = sessionId
        chunkFiles = o["chunkFiles"]?.int ?? Int(o["chunkFiles"]?.string ?? "") ?? 0
        ageHours = o["ageHours"]?.double
        recovered = o["recovered"]?.bool ?? false
        recovering = o["recovering"]?.bool ?? false
        recoverable = o["recoverable"]?.bool ?? (!recovered && chunkFiles >= 2)
        expiresAt = o["expiresAt"]?.string ?? ""
    }
}

/// A live recording whose phone went quiet. Not quarantined yet — do not
/// delete its session files. Save it with POST /api/meeting/save; the
/// quarantine recover route will 404 until the 4h cutoff.
struct StrandedCapture: Identifiable, Sendable {
    let sessionId: String
    let idleMinutes: Int
    let capturedMinutes: Int
    let chunks: Int

    var id: String { sessionId }

    var label: String {
        let idle = idleMinutes == 1 ? "1 min idle" : "\(idleMinutes) min idle"
        return "\(shortId) · \(idle) · still live"
    }

    var shortId: String {
        sessionId.count > 18 ? String(sessionId.prefix(18)) + "…" : sessionId
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let sessionId = o["sessionId"]?.string, !sessionId.isEmpty else { return nil }
        self.sessionId = sessionId
        idleMinutes = o["idleMinutes"]?.int ?? Int(o["idleMinutes"]?.string ?? "") ?? 0
        capturedMinutes = o["capturedMinutes"]?.int ?? Int(o["capturedMinutes"]?.string ?? "") ?? 0
        chunks = o["chunks"]?.int ?? Int(o["chunks"]?.string ?? "") ?? 0
    }
}

// ── Session Chat (0.5.75) ───────────────────────────────────────────

struct SessionChatMessage: Identifiable, Sendable {
    enum Role: Sendable { case user, assistant, status }
    let id = UUID()
    let role: Role
    let text: String
}

struct SessionChatBinding: Sendable {
    let bindingId: String
    let epoch: Int
    let boundTo: String
    /// Server epoch-millis. The binding self-expires in ~30 minutes and there
    /// is no detach route — expiry is the only cleanup, and the composer must
    /// not fight it.
    let expiresAt: Double

    var expired: Bool { Date().timeIntervalSince1970 * 1000 >= expiresAt }
}

struct SessionChatVerdict: Sendable {
    let attachable: Bool
    let reason: String
    let reasonCopy: String
    /// The only wire signal for the idle-holder case: attachable with owners
    /// means a live process holds this thread and merely looks quiet this
    /// second. Rendered as caution behind an explicit confirm, never green.
    let ownerCount: Int

    var caution: Bool { attachable && ownerCount > 0 }
}

/// Persisted at send so a relaunched panel can resume polling the SAME
/// clientTurnId — the idempotency key that prevents a second copy landing in a
/// real conversation. The server's bindings listing is redacted past the point
/// of reconnecting, so this local record is the only way back.
struct SessionChatPendingTurn: Codable, Sendable {
    let provider: String
    let sessionId: String
    let bindingId: String
    let epoch: Int
    let boundTo: String
    let clientTurnId: String
    let prompt: String
    let sentAt: Double
}

struct ClaudeSession: Identifiable, Sendable {
    let id: String
    let sessionId: String
    let provider: String
    let name: String
    let workspace: String
    let state: String
    let waitingFor: String
    let alive: Bool
    let createdAt: String
    let updatedAt: String
    let pinned: Bool

    var stateLabel: String {
        switch state {
        case "waiting": "Waiting"
        case "stale": "Stale"
        case "running": "Running"
        case "recent": ""
        default: "Running"
        }
    }

    /// `recent` means "not running". It has never been a date. Control used to
    /// print "Today" for that bucket, so an 82-day-old row looked like it moved
    /// this morning. The date lives in `clockHint`.
    var showsStateChip: Bool { !stateLabel.isEmpty }

    static func shortSessionDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    func clockHint(clock: SessionClock, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let updated = updatedDate else { return nil }
        switch clock {
        case .updated, .opened, .pinned:
            return "Updated \(Self.shortSessionDate(updated, now: now, calendar: calendar))"
        }
    }

    var title: String {
        if !name.isEmpty { return name }
        if !workspace.isEmpty { return workspace }
        return sessionId
    }

    /// Titles that appear more than once in a set of rows.
    ///
    /// A Claude fork (`--resume <id> --fork-session`) inherits the parent's history, so
    /// the derived title is IDENTICAL to the parent's. Measured 2026-08-18: two live
    /// sessions both named "COS-glasses Server work (meetings)" with distinct ids, and 8
    /// duplicate-title groups across 69 rows. The forks were never missing from the
    /// index — nothing on the row distinguished them.
    ///
    /// Pure and static so it is covered by execution rather than by reading the view.
    static func ambiguousTitles(in sessions: [ClaudeSession]) -> Set<String> {
        var seen: Set<String> = []
        var dupes: Set<String> = []
        for session in sessions {
            let key = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            if seen.contains(key) { dupes.insert(key) } else { seen.insert(key) }
        }
        return dupes
    }

    var isKeepWarm: Bool {
        Self.isKeepWarmSessionTitle(name)
    }

    var providerLabel: String {
        switch provider {
        case "codex": "Codex"
        case "cursor": "Cursor"
        default: "Claude"
        }
    }

    var createdDate: Date? { Self.parseStamp(createdAt) }
    var updatedDate: Date? { Self.parseStamp(updatedAt) }

    private static func parseStamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: trimmed)
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let native = o["id"]?.string, !native.isEmpty else { return nil }
        provider = o["provider"]?.string ?? "claude"
        sessionId = native
        id = "\(provider):\(native)"
        name = o["name"]?.string ?? ""
        workspace = o["workspace"]?.string ?? ""
        state = o["state"]?.string ?? "stale"
        waitingFor = o["waitingFor"]?.string ?? ""
        alive = o["alive"]?.bool ?? false
        createdAt = o["createdAt"]?.string ?? ""
        updatedAt = o["updatedAt"]?.string ?? ""
        pinned = o["pinned"]?.bool ?? false
    }

    static func isKeepWarmSessionTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "ready" { return true }
        return t.hasPrefix("this is an automated local readiness check")
    }
}

struct SessionSearchHit: Identifiable, Sendable {
    let session: ClaudeSession
    let snippet: String
    let match: String
    let score: Double

    var id: String { session.id }

    var matchLabel: String {
        switch match {
        case "both": "Keyword + meaning"
        case "semantic": "Meaning"
        default: "Keyword"
        }
    }

    init(session: ClaudeSession, snippet: String, match: String = "keyword", score: Double) {
        self.session = session
        self.snippet = snippet
        self.match = match
        self.score = score
    }

    init?(_ value: JSONValue?) {
        guard let session = ClaudeSession(value), let o = value?.object else { return nil }
        self.session = session
        snippet = o["snippet"]?.string ?? ""
        match = o["match"]?.string ?? "keyword"
        let keyword = o["keywordScore"]?.double ?? 0
        let semantic = o["semanticScore"]?.double ?? 0
        score = o["score"]?.double ?? max(keyword, semantic)
    }

    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "for", "on", "at", "by",
        "with", "from", "vs", "is", "it", "be", "as", "we", "our",
    ]

    static func tokenize(_ query: String) -> [String] {
        let matches = query.lowercased().split { !$0.isLetter && !$0.isNumber }
        var seen = Set<String>()
        var tokens: [String] = []
        for part in matches {
            let token = String(part)
            guard token.count >= 2, !stopwords.contains(token), !seen.contains(token) else { continue }
            seen.insert(token)
            tokens.append(token)
        }
        return tokens
    }

    static func score(tokens: [String], title: String, haystack: String) -> Double {
        guard !tokens.isEmpty else { return 0 }
        let titleL = title.lowercased()
        let hayL = haystack.lowercased()
        var hits = 0
        var titleHits = 0
        for token in tokens {
            let inTitle = titleL.contains(token)
            let inHay = hayL.contains(token)
            if !inTitle && !inHay { continue }
            hits += 1
            if inTitle { titleHits += 1 }
        }
        if hits == 0 { return 0 }
        let coverage = Double(hits) / Double(tokens.count)
        if coverage < 0.5 && titleHits == 0 { return 0 }
        return min(1, coverage * 0.65 + (Double(titleHits) / Double(tokens.count)) * 0.35)
    }

    static func keywordHits(query: String, sessions: [ClaudeSession], limit: Int = 20) -> [SessionSearchHit] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }
        var hits: [SessionSearchHit] = []
        for session in sessions {
            let haystack = "\(session.name)\n\(session.workspace)\n\(session.title)"
            let value = score(tokens: tokens, title: session.title, haystack: haystack)
            if value <= 0 { continue }
            hits.append(SessionSearchHit(session: session, snippet: session.title, match: "keyword", score: value))
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(max(1, min(limit, 50))))
    }
}

/// LIST caps that hid rows. Sibling of the session array, not a 13th row key.
struct SessionListDropped: Sendable, Equatable {
    var age: Int
    var limit: Int
    var oversized: Int

    var total: Int { age + limit + oversized }

    init(age: Int = 0, limit: Int = 0, oversized: Int = 0) {
        self.age = max(0, age)
        self.limit = max(0, limit)
        self.oversized = max(0, oversized)
    }

    init(_ value: JSONValue?) {
        let object = value?.object
        self.init(
            age: object?["age"]?.int ?? 0,
            limit: object?["limit"]?.int ?? 0,
            oversized: object?["oversized"]?.int ?? 0
        )
    }

    var summary: String? {
        guard total > 0 else { return nil }
        var parts: [String] = []
        if age > 0 { parts.append("\(age) older than 7 days") }
        if limit > 0 { parts.append("\(limit) over the cap") }
        if oversized > 0 { parts.append("\(oversized) too large") }
        return parts.joined(separator: " · ") + " not shown"
    }
}

enum SessionClock: String, CaseIterable, Identifiable, Sendable {
    case updated
    case opened
    case pinned
    var id: String { rawValue }
    var title: String {
        switch self {
        case .updated: return "Updated"
        case .opened: return "Opened"
        case .pinned: return "Pinned"
        }
    }
}

/// Lookup sort next to Domain. Newest is the default so this morning's call
/// beats an older higher-score hit. Best match keeps keyword/meaning order.
enum SearchRecency: String, CaseIterable, Identifiable, Sendable {
    case newest
    case oldest
    case match
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        case .match: return "Best match"
        }
    }

    static func sorted<T>(
        _ items: [T],
        recency: SearchRecency,
        date: (T) -> Date?,
        score: (T) -> Double
    ) -> [T] {
        items.sorted { lhs, rhs in
            switch recency {
            case .match:
                let left = score(lhs), right = score(rhs)
                if left != right { return left > right }
                return (date(lhs) ?? .distantPast) > (date(rhs) ?? .distantPast)
            case .newest:
                let left = date(lhs) ?? .distantPast
                let right = date(rhs) ?? .distantPast
                if left != right { return left > right }
                return score(lhs) > score(rhs)
            case .oldest:
                let left = date(lhs) ?? .distantFuture
                let right = date(rhs) ?? .distantFuture
                if left != right { return left < right }
                return score(lhs) > score(rhs)
            }
        }
    }

    static func parseStamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        if let date = basic.date(from: trimmed) { return date }
        return meetingStamp(date: trimmed, time: "", filename: "")
    }

    static func meetingStamp(date: String, time: String, filename: String) -> Date? {
        let daySource = date.count >= 10 ? date : filename
        let day = String(daySource.prefix(10))
        let parts = day.split(separator: "-")
        guard parts.count >= 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayNum = Int(parts[2]) else {
            return nil
        }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = dayNum
        comps.hour = 0
        comps.minute = 0
        if let clock = parseClock(time) {
            comps.hour = clock.hour
            comps.minute = clock.minute
        }
        return Calendar.current.date(from: comps)
    }

    private static func parseClock(_ raw: String) -> (hour: Int, minute: Int)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["h:mm a", "h:mma", "HH:mm", "H:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                return (parts.hour ?? 0, parts.minute ?? 0)
            }
        }
        return nil
    }
}

struct ClaudeSessionTurn: Identifiable, Sendable {
    let id: String
    let role: String
    let text: String
    let timestamp: String

    var isUser: Bool { role == "user" }

    init?(_ value: JSONValue?) {
        guard let o = value?.object else { return nil }
        let text = o["text"]?.string ?? ""
        guard !text.isEmpty else { return nil }
        id = o["id"]?.string ?? UUID().uuidString
        role = o["role"]?.string == "assistant" ? "assistant" : "user"
        self.text = text
        timestamp = o["timestamp"]?.string ?? ""
    }
}

struct ClaudeSessionDetail: Sendable {
    let title: String
    let cwd: String
    let branch: String
    let sessionId: String
    let provider: String
    let turns: [ClaudeSessionTurn]
    let totalTurns: Int
    let omittedTools: Int
    let omittedSidechain: Int
    let truncated: Bool
    let copyText: String

    var subtitle: String {
        var parts: [String] = []
        parts.append(provider == "codex" ? "Codex" : provider == "cursor" ? "Cursor" : "Claude")
        if !cwd.isEmpty { parts.append((cwd as NSString).lastPathComponent) }
        if !branch.isEmpty { parts.append(branch) }
        if truncated { parts.append("last \(turns.count) of \(totalTurns) turns") }
        else { parts.append("\(totalTurns) turn\(totalTurns == 1 ? "" : "s")") }
        if omittedTools > 0 { parts.append("tools omitted") }
        return parts.joined(separator: " · ")
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object else { return nil }
        let copyText = o["copyText"]?.string ?? ""
        let turns = (o["turns"]?.array ?? []).compactMap(ClaudeSessionTurn.init)
        guard !copyText.isEmpty || !turns.isEmpty else { return nil }
        title = o["title"]?.string ?? "Claude session"
        cwd = o["cwd"]?.string ?? ""
        branch = o["branch"]?.string ?? ""
        sessionId = o["sessionId"]?.string ?? ""
        provider = o["provider"]?.string ?? "claude"
        self.turns = turns
        totalTurns = o["totalTurns"]?.int ?? turns.count
        omittedTools = o["omittedTools"]?.int ?? 0
        omittedSidechain = o["omittedSidechain"]?.int ?? 0
        truncated = o["truncated"]?.bool ?? false
        self.copyText = copyText
    }
}

struct GlassesAttachmentRef: Identifiable, Sendable, Equatable {
    let id: String
    let kind: String
    let mime: String
    let width: Int
    let height: Int
    let createdAt: String
    let label: String?
    /// Additive discriminator from the server contract. Legacy image refs
    /// omit it, so `category` below falls back to the mime.
    let declaredCategory: String?
    let bytes: Int?
    let durationMs: Int?

    /// The canonical vocabulary from shared/media-attachment.ts. Control used
    /// to accept images ONLY -- `user_photo|traffic_frame|generated_visual`
    /// crossed with `image/jpeg|image/png` -- so a video or document ref
    /// failed this initializer and was dropped in silence. The server was
    /// sending it the whole time: Message #29 carried a 75-second
    /// video/quicktime with 13 extracted frames, and the Mac showed nothing at
    /// all (Miles, 2026-08-26). Widened to the full contract.
    static let acceptedKinds: Set<String> = [
        "user_photo", "traffic_frame", "generated_visual", "user_video", "user_document",
    ]
    static let acceptedMimes: Set<String> = [
        "image/jpeg", "image/png",
        "video/mp4", "video/quicktime",
        "application/pdf", "application/json",
        "text/plain", "text/markdown", "text/csv",
    ]

    init?(object: [String: JSONValue]) {
        guard let id = object["id"]?.string,
              id.count == 26, id.hasPrefix("m_"),
              id.dropFirst(2).allSatisfy({ "0123456789abcdef".contains($0) }),
              let kind = object["kind"]?.string,
              Self.acceptedKinds.contains(kind),
              let mime = object["mime"]?.string,
              Self.acceptedMimes.contains(mime),
              let widthValue = object["width"]?.double,
              widthValue.isFinite, widthValue.rounded() == widthValue,
              (1.0...65_535.0).contains(widthValue),
              let heightValue = object["height"]?.double,
              heightValue.isFinite, heightValue.rounded() == heightValue,
              (1.0...65_535.0).contains(heightValue),
              let createdAt = object["createdAt"]?.string,
              Self.validTimestamp(createdAt) else { return nil }
        self.id = id
        self.kind = kind
        self.mime = mime
        self.width = Int(widthValue)
        self.height = Int(heightValue)
        self.createdAt = createdAt
        self.label = object["label"]?.string.map { String($0.prefix(120)) }
        self.declaredCategory = object["category"]?.string
        self.bytes = object["bytes"]?.int
        self.durationMs = object["durationMs"]?.int
    }

    private static func validTimestamp(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        let wholeSecond = ISO8601DateFormatter()
        wholeSecond.formatOptions = [.withInternetDateTime]
        return wholeSecond.date(from: value) != nil
    }

    /// image | video | document. Trusts the server's discriminator when it is
    /// present and falls back to the mime, so a legacy ref that predates
    /// `category` still classifies correctly.
    var category: String {
        if let declaredCategory, ["image", "video", "document"].contains(declaredCategory) {
            return declaredCategory
        }
        if mime.hasPrefix("video/") { return "video" }
        if mime.hasPrefix("image/") { return "image" }
        return "document"
    }

    /// Whether a FETCHED payload's mime is one this app will accept off the
    /// helper. Extracted so the contract test can execute the decision: this
    /// was the FOURTH image-only filter, sitting in `fetchMediaFile`, and it
    /// rejected the helper's own `state: ready` video response — so the poster
    /// rendered and the click failed anyway.
    static func acceptsFetchedMime(_ mime: String) -> Bool {
        acceptedMimes.contains(mime)
    }

    var isVideo: Bool { category == "video" }
    var isDocument: Bool { category == "document" }
    /// True only for things this app can render as an inline picture. A video
    /// still HAS a poster frame (the thumb variant is a JPEG), so this gates
    /// the full-size open path, never the thumbnail.
    var opensInline: Bool { category == "image" }

    var isUserPhoto: Bool { kind == "user_photo" || kind == "user_video" || kind == "user_document" }

    var displayLabel: String {
        switch category {
        case "video": return isUserPhoto ? "Your video" : "Answer video"
        case "document": return isUserPhoto ? "Your file" : "Answer file"
        default: return isUserPhoto ? "Your image" : "Answer image"
        }
    }

    /// "1:15" / "12s" -- shown on the poster so a video reads as a video.
    var durationLabel: String? {
        guard let durationMs, durationMs > 0 else { return nil }
        let total = Int((Double(durationMs) / 1000).rounded())
        if total < 60 { return "\(total)s" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var sizeLabel: String? {
        guard let bytes, bytes > 0 else { return nil }
        if bytes < 1_024 * 1_024 { return "\(max(1, bytes / 1_024)) KB" }
        return String(format: "%.1f MB", Double(bytes) / (1_024 * 1_024))
    }

    /// A filename for the temp file the external opener hands to QuickTime or
    /// Preview. The extension is derived from the MIME, never from the
    /// server-supplied label, which is untrusted text.
    var fileExtension: String {
        switch mime {
        case "video/quicktime": return "mov"
        case "video/mp4": return "mp4"
        case "application/pdf": return "pdf"
        case "application/json": return "json"
        case "text/markdown": return "md"
        case "text/csv": return "csv"
        case "text/plain": return "txt"
        case "image/png": return "png"
        default: return "jpg"
        }
    }
}

enum RecentMediaPreviewState {
    case loading
    case ready(NSImage)
    case unavailable(String)
}

enum RecentMediaImageDecoder {
    static func decode(url: URL, expectedBytes: Int) -> NSImage? {
        guard expectedBytes > 0, expectedBytes <= 12 * 1_024 * 1_024,
              let data = try? Data(contentsOf: url), data.count == expectedBytes,
              let image = NSImage(data: data), image.isValid else { return nil }
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) != nil else { return nil }
        return image
    }
}

struct SelectedMediaPreview: Identifiable {
    let attachment: GlassesAttachmentRef
    let image: NSImage
    var id: String { attachment.id }
}

struct GlassesTurn: Identifiable, Sendable, Equatable {
    let id: String
    let no: Int?
    let timestamp: TimeInterval?
    let query: String
    let text: String
    let sessionId: String
    let source: String
    let attachments: [GlassesAttachmentRef]

    init(id: String, no: Int?, timestamp: TimeInterval?, query: String, text: String, sessionId: String, source: String, attachments: [GlassesAttachmentRef] = []) {
        self.id = id
        self.no = no
        self.timestamp = timestamp
        self.query = query
        self.text = text
        self.sessionId = sessionId
        self.source = source
        self.attachments = Array(attachments.prefix(5))
    }

    init?(_ object: [String: JSONValue]) {
        let query = object["query"]?.string ?? ""
        let text = object["text"]?.string ?? ""
        let sessionId = object["sessionId"]?.string ?? ""
        let source = object["source"]?.string ?? ""
        let no = object["no"]?.int
        var seen = Set<String>()
        let attachments: [GlassesAttachmentRef]
        if let values = object["attachments"]?.array {
            attachments = Array(values.compactMap { item -> GlassesAttachmentRef? in
                guard let value = item.object,
                      let attachment = GlassesAttachmentRef(object: value),
                      seen.insert(attachment.id).inserted else { return nil }
                return attachment
            }.prefix(5))
        } else {
            attachments = []
        }
        let timestamp: TimeInterval?
        if let number = object["timestamp"]?.int {
            timestamp = TimeInterval(number) / (number > 10_000_000_000 ? 1000 : 1)
        } else {
            timestamp = nil
        }
        let idBase = [no.map(String.init) ?? "x", sessionId, object["timestamp"]?.int.map(String.init) ?? UUID().uuidString].joined(separator: "|")
        self.init(id: idBase, no: no, timestamp: timestamp, query: query, text: text, sessionId: sessionId, source: source, attachments: attachments)
    }

    var previewQuery: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 60 { return trimmed.isEmpty ? "(empty query)" : trimmed }
        return String(trimmed.prefix(57)) + "…"
    }

    /// Day-anchored, locale-formatted time.
    ///
    /// This was a hardcoded `HH:mm`, so a list spanning several days rendered
    /// every row as a bare 24-hour clock: "19:15" over "18:31" over "17:42"
    /// with no way to tell today from Monday, and no AM/PM on a machine whose
    /// locale uses it (a fixed dateFormat ignores locale entirely). Miles,
    /// 2026-08-26: "hard to skim".
    ///
    /// Every row now carries its day. The TIME half is `.shortened`, which is
    /// locale-driven -- an en_US machine gets "7:15 PM" while a 24-hour locale
    /// keeps 24-hour rather than having AM/PM forced onto it.
    static func dayAnchoredTime(
        _ timestamp: TimeInterval?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard let timestamp, timestamp > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: timestamp)
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(day), \(time)"
    }

    var timeLabel: String { Self.dayAnchoredTime(timestamp) }

    var turnClipboardText: String {
        let label = no.map { "Msg \($0)" } ?? "Msg"
        return "[\(label)] User: \(query)\n[\(label)] COS: \(text)"
    }
}

enum RecentGlassesStatus: String, Sendable {
    case idle
    case loading
    case ready
    case empty
    case serverStopped
    case unauthorized
    case error
}

struct DoctorCheck: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let state: String
    let detail: String
}

/// Result of the appcast probe. This build can also download, SHA-check, and
/// swap the .app — the check-only era ended in 0.5.51.
struct AppUpdateInfo: Sendable {
    var updateAvailable = false
    var latestVersion: String?
    var latestBuild: Int?
    var url: String?
    var sha256: String?
    var notes: String?
    /// Publisher notice, independent of whether an update is offered. Someone who
    /// just updated is up to date, so gating this on `updateAvailable` would hide
    /// it from the exact audience it is written for.
    var noticeId: String?
    var noticeTitle: String?
    var noticeBody: String?
    /// newer / upToDate / killSwitch / unreachable / malformed / idle / requiresMacOS
    var reason: String = "idle"

    init() {}

    init(_ details: [String: JSONValue]) {
        updateAvailable = details["updateAvailable"]?.bool ?? false
        latestVersion = details["latestVersion"]?.string
        latestBuild = details["latestBuild"]?.int
        url = details["url"]?.string
        sha256 = details["sha256"]?.string
        notes = details["notes"]?.string
        noticeId = details["noticeId"]?.string
        noticeTitle = details["noticeTitle"]?.string
        noticeBody = details["noticeBody"]?.string
        reason = details["reason"]?.string ?? "idle"
    }

    /// Only a reachable, well-formed, genuinely-newer appcast may surface UI.
    var shouldSurface: Bool { updateAvailable && latestVersion != nil }

    /// Deliberately NOT gated on `shouldSurface`. The helper already applied
    /// minBuild, so anything that arrives here is meant for this build.
    var hasNotice: Bool { noticeId != nil && noticeTitle != nil && noticeBody != nil }
}

// MARK: - Speaker review (0.4.0)
//
// Backs the naming panel. The design principle the shapes encode: a similarity
// score cannot tell you who someone is, a remembered sentence can — so
// `phrases` is the primary content of a row and `meanSimilarity` is metadata.

struct ReviewableMeeting: Identifiable, Sendable, Hashable {
    let sessionId: String
    let title: String
    let date: String
    let domain: String
    let duration: String
    /// Join keys for the meeting-detail route. Present on every row the server
    /// sends; the helper used to discard them.
    let month: String
    let filename: String
    /// How the meeting was captured (G2 Glasses, Granola, Fireflies).
    let source: String
    /// Pre-computed by the server, so the subtitle costs no extra fetch.
    let topicCount: Int
    let decisionCount: Int
    let actionCount: Int
    let attendeeCount: Int
    let recordId: String
    let mutable: Bool
    let librarySource: String
    /// Additive 6.36.18+. Nil on older servers — do not treat as zero unnamed.
    let voiceCount: Int?
    let unattributedVoices: Int?
    let namedVoices: Int?
    let humanTouched: Bool?

    var id: String { sessionId }

    /// "4 topics · 2 decisions · 1 action · 3 attendees", zero counts omitted.
    ///
    /// Falls back to the capture source when everything is zero, because an
    /// empty line reads as a rendering bug rather than as a meeting with no
    /// extracted structure.
    var countsSummary: String {
        var parts: [String] = []
        if topicCount > 0 { parts.append("\(topicCount) topic\(topicCount == 1 ? "" : "s")") }
        if decisionCount > 0 { parts.append("\(decisionCount) decision\(decisionCount == 1 ? "" : "s")") }
        if actionCount > 0 { parts.append("\(actionCount) action\(actionCount == 1 ? "" : "s")") }
        if attendeeCount > 0 { parts.append("\(attendeeCount) attendee\(attendeeCount == 1 ? "" : "s")") }
        if parts.isEmpty { return source }
        return parts.joined(separator: " · ")
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object,
              let sessionId = o["sessionId"]?.string, !sessionId.isEmpty else { return nil }
        self.sessionId = sessionId
        title = o["title"]?.string ?? "Untitled meeting"
        date = o["date"]?.string ?? ""
        domain = o["domain"]?.string ?? ""
        duration = o["duration"]?.string ?? ""
        month = o["month"]?.string ?? ""
        filename = o["filename"]?.string ?? ""
        source = o["source"]?.string ?? ""
        // Numbers on the wire; the string branch is a belt-and-braces fallback.
        topicCount = o["topicCount"]?.int ?? Int(o["topicCount"]?.string ?? "") ?? 0
        decisionCount = o["decisionCount"]?.int ?? Int(o["decisionCount"]?.string ?? "") ?? 0
        actionCount = o["actionCount"]?.int ?? Int(o["actionCount"]?.string ?? "") ?? 0
        attendeeCount = o["attendeeCount"]?.int ?? Int(o["attendeeCount"]?.string ?? "") ?? 0
        recordId = o["recordId"]?.string ?? ""
        mutable = o["mutable"]?.bool ?? true
        librarySource = o["librarySource"]?.string ?? "standalone_recordings"
        let review = o["voiceReview"]?.object
        voiceCount = review?["voices"]?.int
        unattributedVoices = review?["unattributedVoices"]?.int
        namedVoices = review?["namedVoices"]?.int
        humanTouched = review?["humanTouched"]?.bool
    }
}

/// Local Speakers-list memory: which meetings are new, opened, or finished.
///
/// Server `voiceReview` is the assignment truth. This overlay remembers visits
/// so a just-named meeting shows REVIEWED before the next list refresh, and so
/// NEW does not re-tag the whole inbox on first launch of this feature.
struct SpeakerListMemory: Codable, Equatable, Sendable {
    struct Visit: Codable, Equatable, Sendable {
        var voices: Int
        var unattributedVoices: Int
        var humanTouched: Bool
    }

    var acknowledged: [String] = []
    var opened: [String] = []
    var visits: [String: Visit] = [:]

    private static let defaultsKey = "cos.speakerListMemory.v1"

    var acknowledgedSet: Set<String> { Set(acknowledged) }
    var openedSet: Set<String> { Set(opened) }

    static func load() -> SpeakerListMemory {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let memory = try? JSONDecoder().decode(SpeakerListMemory.self, from: data)
        else { return SpeakerListMemory() }
        return memory
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    mutating func seedIfEmpty(_ ids: [String]) {
        guard acknowledged.isEmpty else { return }
        acknowledged = ids
    }

    func isNew(_ sessionId: String) -> Bool {
        !acknowledged.isEmpty && !acknowledgedSet.contains(sessionId)
    }

    mutating func markOpened(_ sessionId: String) {
        if !acknowledged.contains(sessionId) { acknowledged.append(sessionId) }
        if !opened.contains(sessionId) { opened.append(sessionId) }
    }

    mutating func recordVisit(_ sessionId: String, voices: Int, unattributedVoices: Int) {
        markOpened(sessionId)
        visits[sessionId] = Visit(
            voices: voices,
            unattributedVoices: unattributedVoices,
            humanTouched: true
        )
    }

    func voiceTag(for meeting: ReviewableMeeting) -> MeetingVoiceTag? {
        let visit = visits[meeting.sessionId]
        let unattributed = visit?.unattributedVoices ?? meeting.unattributedVoices
        let finished = visit?.humanTouched == true || meeting.humanTouched == true
        if let unattributed, unattributed == 0, finished { return .reviewed }
        if let unattributed, unattributed > 0 { return .needsNames(unattributed) }
        return nil
    }

    /// Overlay-only tag for a library row that is not in the Speakers inbox.
    func voiceTag(sessionId: String) -> MeetingVoiceTag? {
        guard let visit = visits[sessionId] else { return nil }
        if visit.unattributedVoices == 0, visit.humanTouched { return .reviewed }
        if visit.unattributedVoices > 0 { return .needsNames(visit.unattributedVoices) }
        return nil
    }

    /// Inbox order: still need names, then new, then untouched, reviewed last.
    func reviewRank(of meeting: ReviewableMeeting) -> Int {
        switch voiceTag(for: meeting) {
        case .needsNames: return 0
        case nil: return isNew(meeting.sessionId) ? 1 : 2
        case .reviewed: return 3
        }
    }

    func ranked(_ meetings: [ReviewableMeeting]) -> [ReviewableMeeting] {
        meetings.sorted { a, b in
            let ra = reviewRank(of: a)
            let rb = reviewRank(of: b)
            if ra != rb { return ra < rb }
            if a.date != b.date { return a.date > b.date }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    func visible(_ meetings: [ReviewableMeeting], hideReviewed: Bool) -> [ReviewableMeeting] {
        let ordered = ranked(meetings)
        return hideReviewed ? ordered.filter { voiceTag(for: $0) != .reviewed } : ordered
    }

    func nextUnnamed(after sessionId: String, in meetings: [ReviewableMeeting]) -> ReviewableMeeting? {
        let queue = ranked(meetings).filter { voiceTag(for: $0) != .reviewed }
        guard let index = queue.firstIndex(where: { $0.sessionId == sessionId }) else {
            return queue.first
        }
        if index + 1 < queue.count { return queue[index + 1] }
        return queue.first { $0.sessionId != sessionId }
    }
}

enum MeetingVoiceTag: Equatable, Sendable {
    case needsNames(Int)
    case reviewed
}

/// A saved meeting in the Activity library. sessionId is optional — Granola and
/// Fireflies rows still open transcript and summary.
struct LibraryMeeting: Identifiable, Sendable, Hashable {
    let recordId: String
    let sessionId: String
    let title: String
    let date: String
    let time: String
    let domain: String
    let domainAbbr: String
    let duration: String
    let durationMinutes: Int
    let month: String
    let filename: String
    let source: String
    let librarySource: String
    let topicCount: Int
    let decisionCount: Int
    let actionCount: Int
    let attendeeCount: Int

    var id: String { recordId }

    var domainLabel: String {
        if !domainAbbr.isEmpty { return domainAbbr }
        let spaced = domain.replacingOccurrences(of: "_", with: " ")
        return spaced.localizedCapitalized
    }

    var subtitle: String {
        var parts: [String] = []
        if !date.isEmpty { parts.append(date) }
        if !time.isEmpty { parts.append(time) }
        if !domainLabel.isEmpty { parts.append(domainLabel) }
        if !duration.isEmpty { parts.append(duration) }
        else if durationMinutes > 0 { parts.append("\(durationMinutes) min") }
        if !source.isEmpty { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    var canReviewVoices: Bool { !sessionId.isEmpty }

    init?(_ value: JSONValue?) {
        guard let o = value?.object else { return nil }
        let filename = o["filename"]?.string ?? ""
        let month = o["month"]?.string ?? ""
        guard !filename.isEmpty, !month.isEmpty else { return nil }
        let domain = o["domain"]?.string ?? ""
        let providedId = o["recordId"]?.string ?? ""
        recordId = providedId.isEmpty ? "\(domain):\(month):\(filename)" : providedId
        sessionId = o["sessionId"]?.string ?? ""
        title = o["title"]?.string ?? "Untitled meeting"
        date = o["date"]?.string ?? ""
        time = o["time"]?.string ?? ""
        self.domain = domain
        domainAbbr = o["domainAbbr"]?.string ?? ""
        duration = o["duration"]?.string ?? ""
        durationMinutes = o["durationMinutes"]?.int ?? Int(o["durationMinutes"]?.string ?? "") ?? 0
        self.month = month
        self.filename = filename
        source = o["source"]?.string ?? ""
        librarySource = o["librarySource"]?.string ?? ""
        topicCount = o["topicCount"]?.int ?? Int(o["topicCount"]?.string ?? "") ?? 0
        decisionCount = o["decisionCount"]?.int ?? Int(o["decisionCount"]?.string ?? "") ?? 0
        actionCount = o["actionCount"]?.int ?? Int(o["actionCount"]?.string ?? "") ?? 0
        attendeeCount = o["attendeeCount"]?.int ?? Int(o["attendeeCount"]?.string ?? "") ?? 0
    }

    var recencyDate: Date? {
        SearchRecency.meetingStamp(date: date, time: time, filename: filename)
    }
}

struct LibrarySearchHit: Identifiable, Sendable {
    let meeting: LibraryMeeting
    let snippet: String
    let match: String
    let score: Double

    var id: String { meeting.id }

    var matchLabel: String {
        switch match {
        case "both": "Keyword + meaning"
        case "semantic": "Meaning"
        default: "Keyword"
        }
    }

    init?(_ value: JSONValue?) {
        guard let meeting = LibraryMeeting(value), let o = value?.object else { return nil }
        self.meeting = meeting
        snippet = o["snippet"]?.string ?? ""
        match = o["match"]?.string ?? "keyword"
        let keyword = o["keywordScore"]?.double ?? 0
        let semantic = o["semanticScore"]?.double ?? 0
        score = o["score"]?.double ?? max(keyword, semantic)
    }
}

struct ContextSearchHit: Identifiable, Sendable {
    let record: ContextRecord
    let snippet: String
    let match: String
    let score: Double

    var id: String { record.id }

    var matchLabel: String {
        switch match {
        case "both": "Keyword + meaning"
        case "semantic": "Meaning"
        default: "Keyword"
        }
    }

    init?(kind: String, _ value: JSONValue?) {
        guard let o = value?.object, let id = o["id"]?.string, !id.isEmpty else { return nil }
        let record = kind == "thread" ? ContextRecord.thread(o) : ContextRecord.memory(o)
        guard !record.id.isEmpty else { return nil }
        self.record = record
        snippet = o["snippet"]?.string ?? ""
        match = o["match"]?.string ?? "keyword"
        let keyword = o["keywordScore"]?.double ?? 0
        let semantic = o["semanticScore"]?.double ?? 0
        score = o["score"]?.double ?? max(keyword, semantic)
    }
}

enum MeetingMonth {
    static func parse(_ value: String) -> Date? {
        let parts = value.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]) else { return nil }
        return Calendar.current.date(from: DateComponents(year: year, month: month, day: 1))
    }

    static func title(_ month: String) -> String {
        guard let date = parse(month) else { return month }
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter.string(from: date)
    }

    static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

struct LibraryMeetingDay: Sendable, Hashable {
    let date: String
    let count: Int

    init(date: String, count: Int) {
        self.date = date
        self.count = count
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let date = o["date"]?.string, !date.isEmpty else { return nil }
        self.date = date
        count = o["count"]?.int ?? Int(o["count"]?.string ?? "") ?? 0
    }
}

struct LibraryMeetingDetail: Sendable {
    let title: String
    let date: String
    let time: String
    let domain: String
    let duration: String
    let source: String
    let summary: String
    let transcript: String
    let sourceContent: String
    let sourceTruncated: Bool
    let attendees: [String]
    let topics: [String]
    let decisions: [String]
    let actionItems: [(task: String, owner: String)]

    init?(_ value: JSONValue?) {
        guard let o = value?.object else { return nil }
        title = o["title"]?.string ?? "Untitled meeting"
        date = o["date"]?.string ?? ""
        time = o["time"]?.string ?? ""
        domain = o["domain"]?.string ?? ""
        duration = o["duration"]?.string ?? ""
        source = o["source"]?.string ?? ""
        summary = o["summary"]?.string ?? ""
        transcript = o["transcript"]?.string ?? ""
        sourceContent = o["sourceContent"]?.string ?? ""
        sourceTruncated = o["sourceTruncated"]?.bool ?? false
        attendees = o["attendees"]?.array?.compactMap(\.string) ?? []
        topics = o["topics"]?.array?.compactMap(\.string) ?? []
        decisions = o["decisions"]?.array?.compactMap(\.string) ?? []
        actionItems = o["actionItems"]?.array?.compactMap { item in
            guard let object = item.object else { return nil }
            let task = object["task"]?.string ?? ""
            guard !task.isEmpty else { return nil }
            return (task, object["owner"]?.string ?? "")
        } ?? []
    }
}

struct SpeakerPhrase: Identifiable, Sendable, Hashable {
    let text: String
    let atMs: Int
    /**
     RAW capture index for this line's audio, or nil when the sidecar could not
     supply one.

     NOT the position in the chunk array. Those differ and the gap grows through a
     meeting — measured on the 2026-08-06 Ditto sidecar, position 884 is really
     raw chunk 940. nil means DO NOT offer playback: a guessed index plays a
     different speaker, which is worse than no button on a screen whose entire
     purpose is confirming who spoke.
     */
    let chunkIndex: Int?
    var id: String { "\(atMs)-\(text.prefix(24))" }

    /// The sidecar stores milliseconds. Rendered as a meeting timestamp so a
    /// reviewer can place the line against their memory of the conversation.
    var stamp: String {
        let total = atMs / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let text = o["text"]?.string, !text.isEmpty else { return nil }
        self.text = text
        atMs = o["atMs"]?.int ?? 0
        chunkIndex = o["chunkIndex"]?.int
    }
}

struct SpeakerThrashPair: Sendable, Hashable {
    let speaker: String
    let meanRun: Double

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let speaker = o["speaker"]?.string else { return nil }
        self.speaker = speaker
        meanRun = o["meanRun"]?.double ?? 0
    }
}

struct ReviewVoice: Identifiable, Sendable, Hashable {
    /// Voiced milliseconds for this voice. nil on a server that does not report it.
    var speakingMs: Int?
    enum Reliability: String, Sendable {
        case confident, weak, unreliable, unattributed
    }

    let label: String
    let segments: Int
    let meanSimilarity: Double?
    let isOwner: Bool
    let reliability: Reliability
    /// Whether the server considers this label EARNED enough to show as a name.
    /// Read, never re-derived here: the floor lives on the server so the phone,
    /// the lens and this panel cannot disagree about who has been identified.
    let nameAsserted: Bool
    /// Why the name is not asserted — shown to the reviewer rather than silently
    /// hiding it, because "2 segments" and "similarity 0.58" call for different
    /// judgements.
    let assertionBlockers: [String]
    /// A human vouched for this label in this meeting, so the floor is waived.
    /// Server 6.21.25+; absent on older servers, which simply never confirm.
    let confirmedByHuman: Bool
    let thrashesWith: [SpeakerThrashPair]
    let phrases: [SpeakerPhrase]

    var id: String { label }
    /// What the row is allowed to CALL this voice. An unearned label is a
    /// candidate, not an identity.
    var displayName: String { nameAsserted ? label : "Unidentified voice" }
    /// Any voice but the wearer can be given a name — INCLUDING an unattributed
    /// cluster, which is the whole reason to review one.
    ///
    /// This excluded `.unattributed` until 0.5.2, while the row's own copy told
    /// the user to "give it one from the list above". The panel instructed an
    /// action the panel then refused to offer. The server was never the blocker:
    /// `relabelSidecarJson` operates on any label, `Ext` and `Unidentified N`
    /// included.
    ///
    /// The owner stays excluded deliberately — the wearer is established by the
    /// device, not by cosine, and must never be absorbed into someone else.
    var canRename: Bool { !isOwner }
    /// Naming an unattributed row ASSIGNS an identity rather than correcting a
    /// wrong one. Worth distinguishing on the button, because "Actually someone
    /// else" reads as fixing a mistake the system made.
    var isNameAssignment: Bool { reliability == .unattributed }
    /// Review pane order: unnamed first, then withheld names, then asserted.
    var reviewQueueRank: Int {
        if isNameAssignment { return 0 }
        if !nameAsserted { return 1 }
        return 2
    }
    /// Can this row's OWN label be vouched for?
    ///
    /// Only when the identifier proposed a name that the floor then withheld.
    /// An unattributed row has no candidate to confirm, the owner needs none,
    /// and a row already asserted has nothing to add.
    var canConfirmCandidate: Bool {
        !isOwner && !nameAsserted && reliability != .unattributed && !confirmedByHuman
    }
    /// A voice that was never in the room can be removed. Only meaningful where
    /// a name was actually applied — there is nothing to take back otherwise.
    var canDeattribute: Bool { reliability != .unattributed }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let label = o["label"]?.string else { return nil }
        self.label = label
        segments = o["segments"]?.int ?? 0
        // Server 6.21.27+. Optional with no `?? 0`: a count has no safe scalar
        // default, and zero would read as "this person never spoke".
        speakingMs = o["speakingMs"]?.int
        meanSimilarity = o["meanSimilarity"]?.double
        isOwner = o["isOwner"]?.bool ?? false
        reliability = Reliability(rawValue: o["reliability"]?.string ?? "") ?? .weak
        // Absent on a server older than 6.21.18. Defaulting to TRUE keeps an old
        // server's panel working exactly as it did rather than blanking every
        // name; the floor is then simply not enforced until the server ships it.
        nameAsserted = o["nameAsserted"]?.bool ?? true
        assertionBlockers = (o["assertionBlockers"]?.array ?? []).compactMap { $0.string }
        confirmedByHuman = o["confirmedByHuman"]?.bool ?? false
        thrashesWith = (o["thrashesWith"]?.array ?? []).compactMap(SpeakerThrashPair.init)
        phrases = (o["phrases"]?.array ?? []).compactMap(SpeakerPhrase.init)
    }
}

/// One stretch of the meeting held by a single label.
///
/// The ribbon used to draw one rectangle per voice sized by share of segments
/// while calling itself "who spoke, in order" — there was no ordering in it, so
/// hovering could not report anything true. These spans are what make it a
/// timeline.
struct SpeakerTimelineSpan: Identifiable, Sendable, Hashable {
    let speaker: String
    let startMs: Int
    let endMs: Int
    let segments: Int

    /// POSITIONAL identity.
    ///
    /// A value-based id collided badly: `speakerTimeline` clamps non-monotonic
    /// `elapsed` forward, and 48 of 381 real sidecars have a backwards step that
    /// pins many spans to the same start. On 2026-05-11 that produced 161
    /// duplicate ids across 509 spans, which SwiftUI answers with dropped or
    /// misdrawn rows. The index makes duplicates impossible by construction.
    let index: Int
    var id: Int { index }
    var durationMs: Int { max(0, endMs - startMs) }

    var stamp: String {
        let total = startMs / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    init?(_ value: JSONValue?, index: Int) {
        guard let o = value?.object, let speaker = o["speaker"]?.string else { return nil }
        self.index = index
        self.speaker = speaker
        startMs = o["startMs"]?.int ?? 0
        endMs = o["endMs"]?.int ?? 0
        segments = o["segments"]?.int ?? 0
    }
}

struct SpeakerReview: Sendable {
    let sessionId: String
    let title: String
    let segments: Int
    let attributed: Bool
    /// Segments belonging to voices the server asserts a NAME for.
    ///
    /// Server 6.21.26+; absent on older servers. OPTIONAL ON PURPOSE — the house
    /// `?? 0` here would render "0 of 379 identified" for a perfectly
    /// well-attributed meeting served by an older build: a confident false
    /// statement of exactly the kind this panel exists to stop making, and the
    /// same class as the 404-means-audio-expired bug Tests/run.sh already
    /// guards. There is no safe scalar default for a count, so nil means "this
    /// server does not report it" and the view omits the line.
    let assertedSegments: Int?
    /// Voiced ms of voices shown WITH A NAME, and the two buckets beside it.
    /// All nil together on a server older than 6.21.27.
    let attributedSpeakingMs: Int?
    let unattributedSpeakingMs: Int?
    let notCapturedMs: Int?
    /// "words" (real voiced time) or "chunks" (capped wall clock). Not
    /// comparable across meetings, so never trend a mix of the two.
    let speakingTimeSource: String?
    let durationMs: Int
    let voices: [ReviewVoice]
    let timeline: [SpeakerTimelineSpan]
    let recordId: String
    let mutable: Bool
    let librarySource: String

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let sessionId = o["sessionId"]?.string else { return nil }
        self.sessionId = sessionId
        title = o["title"]?.string ?? "Untitled meeting"
        segments = o["segments"]?.int ?? 0
        attributed = o["attributed"]?.bool ?? false
        assertedSegments = o["assertedSegments"]?.int
        attributedSpeakingMs = o["attributedSpeakingMs"]?.int
        unattributedSpeakingMs = o["unattributedSpeakingMs"]?.int
        notCapturedMs = o["notCapturedMs"]?.int
        speakingTimeSource = o["speakingTimeSource"]?.string
        durationMs = o["durationMs"]?.int ?? 0
        voices = (o["voices"]?.array ?? []).compactMap(ReviewVoice.init)
        timeline = (o["timeline"]?.array ?? []).enumerated().compactMap { SpeakerTimelineSpan($1, index: $0) }
        recordId = o["recordId"]?.string ?? ""
        mutable = o["mutable"]?.bool ?? true
        librarySource = o["source"]?.string ?? "standalone_recordings"
    }

    /// Whether a name may be shown for a label, from the voice rows. The ribbon
    /// asks this rather than deciding for itself, so a span and its list row can
    /// never disagree about whether someone was identified.
    func assertsName(_ label: String) -> Bool {
        voices.first(where: { $0.label == label })?.nameAsserted ?? false
    }

    /// Share of IDENTIFIED speech held by this voice, 0...1.
    ///
    /// Deliberately a share of NAMED speech, not of the meeting: the
    /// unattributed bucket is routinely the largest single slice (44.8% of
    /// retained speaking time corpus-wide), so a share of wall clock would make
    /// every real participant look marginal.
    /// Denominator is the SUM of named voices, NOT `attributedSpeakingMs`.
    ///
    /// That field is a UNION — crosstalk counted once — so dividing by it lets
    /// the shares total more than 100%. Measured on a real 19.6-minute meeting
    /// the union is 6.6m while the participants sum to 6.9m, which rendered
    /// "MU 66% · Edward Addo 39%". Share of voice is conventionally a share of
    /// everyone's talking, and this denominator totals exactly 100%.
    /// Coverage below which a per-voice share is not shown. Must equal the
    /// server's `SHARE_COVERAGE_FLOOR`, because the clipboard and this panel
    /// describe the same meeting and a reader comparing them will notice.
    static let shareCoverageFloor = 0.6

    /// Share of IDENTIFIED speech, or nil when it would mislead.
    ///
    /// The floor lives HERE rather than in the view. The panel's own comment
    /// claimed it already hid these below 60% coverage; it never did — every
    /// asserted voice got a percentage and the only `0.6` test in the app
    /// swapped a caption's colour. Measured across 355 real reviews, the panel
    /// showed a share the clipboard refused on 170 of them. A share is a
    /// fraction of what was identified, so at 40% coverage "53%" can be 21% of
    /// the room. One function, so a future row cannot forget the gate.
    func shareOfIdentified(_ voice: ReviewVoice) -> Double? {
        guard voice.nameAsserted, let ms = voice.speakingMs else { return nil }
        // FAIL CLOSED on unknown coverage, exactly as the server does
        // (`coverage !== null && coverage >= FLOOR`). `if let c = ...` alone
        // would SHOW a share when coverage is nil — reintroducing the same
        // asymmetry on the one path where we know least.
        guard let c = speakingCoverage, c >= Self.shareCoverageFloor else { return nil }
        let total = voices.reduce(0) { $0 + ($1.nameAsserted ? ($1.speakingMs ?? 0) : 0) }
        guard total > 0 else { return nil }
        return Double(ms) / Double(total)
    }

    /// How much of the meeting's voice was named. nil when unreported.
    var speakingCoverage: Double? {
        guard let a = attributedSpeakingMs, let u = unattributedSpeakingMs, a + u > 0 else { return nil }
        return Double(a) / Double(a + u)
    }

    func displayName(for label: String) -> String {
        voices.first(where: { $0.label == label })?.displayName ?? label
    }

    var unnamedVoiceCount: Int { voices.filter(\.isNameAssignment).count }

    /// Voice rows for the review list. Timeline stays in speaking order.
    var voicesForReview: [ReviewVoice] {
        voices.enumerated().sorted { a, b in
            let ra = a.element.reviewQueueRank
            let rb = b.element.reviewQueueRank
            if ra != rb { return ra < rb }
            if a.element.segments != b.element.segments { return a.element.segments > b.element.segments }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// The readable meeting behind a speaker review, plus its clipboard forms.
///
/// The clipboard strings are built SERVER-SIDE and passed through untouched.
/// They apply the display floor to the attendee block — the scribe's own
/// `## Attendees` does not, and on one real 26-minute meeting lists 15 people
/// including a name already confirmed absent. Re-deriving them here would put
/// that formatting somewhere with no execution tests.
struct MeetingContent: Sendable {
    let sessionId: String
    let title: String
    let date: String
    let durationMin: Int
    /// False when the meeting has no scribe markdown on disk. The speaker rows
    /// still render — who spoke is worth having without the write-up.
    let scribeAvailable: Bool
    let summary: String
    let topics: String
    let decisions: String
    let actions: String
    let transcriptChars: Int
    /// Sizes of the ACTUAL strings, from the server. The button label and the
    /// copy confirmation previously quoted two different numbers for one click
    /// (transcriptChars vs clipboardFull.count) and disagreed on 81% of meetings.
    let summaryChars: Int
    let fullChars: Int
    /// Transcript characters in the RECORDING, whether or not it is written up.
    let capturedChars: Int
    /// Which business this meeting belongs to, '' when the server omits it.
    let domain: String
    /// Names the user explicitly de-attributed from this meeting.
    ///
    /// De-attribution rewrites the sidecar, the attendee list and the transcript
    /// labels but deliberately leaves narrative prose alone. So a removed person
    /// can still be named in the LLM summary shown right below the voice rows —
    /// which is exactly what happened on 2026-08-07: "Clem Ukaoma" was removed
    /// from a call that was only Miles and Queen, all 8 label sites were rewritten,
    /// and the panel still read "Miles, Queen, and Clem talk through...". Server
    /// 6.21.30+; empty on older servers, which simply show no warning.
    let removedNames: [(label: String, proseStale: Bool)]

    /// The warning to show above the write-up, or nil when there is nothing to say.
    ///
    /// A pure function so the wording is covered by execution rather than by a
    /// grep for a string literal.
    static func removalWarning(_ removed: [(label: String, proseStale: Bool)]) -> String? {
        let stale = removed.filter { $0.proseStale }.map { $0.label }
        guard !stale.isEmpty else { return nil }
        let names = stale.map { "\u{0022}\($0)\u{0022}" }.joined(separator: ", ")
        return "You removed \(names) from this meeting. The write-up below was written "
             + "before that and still uses the name."
    }
    /// Identified share of voiced time, or nil when unknown.
    let coverage: Double?
    /// Whether the server reported per-voice shares. False below its floor.
    let sharesReported: Bool
    /// Sections the parser did not recognise, carried rather than discarded.
    let extras: [(String, String)]
    let clipboardSummary: String
    let clipboardFull: String

    /// Sections with content, in reading order. Empty ones are dropped rather
    /// than rendered as bare headings.
    var sections: [(String, String)] {
        ([("Summary", summary), ("Topics", topics),
          ("Decisions", decisions), ("Action items", actions)] + extras)
            .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// What to tell the user when there is no write-up.
    ///
    /// A pure function on purpose. The previous guard for this was a `grep` for
    /// "route_absent", which a mutation defeated by leaving the string in place
    /// while changing the assignment — source-shape greps cannot see behaviour.
    /// nil means render nothing (content loaded, or genuinely no scribe).
    static func unavailableMessage(_ reason: String?) -> String? {
        switch reason {
        case nil: return nil
        case "route_absent":
            return "The meeting write-up needs glasses-server 6.21.28 or newer. Use Update Server in Settings."
        default:
            return "The meeting write-up could not be loaded."
        }
    }

    /// Body text with markdown markers softened for a 390pt popover.
    ///
    /// `Text(_: String)` binds the StringProtocol overload and does NOT parse
    /// markdown, so `###`, `- [ ]` and `**` rendered literally. The clipboard
    /// still gets the real markdown — a model wants the structure — so this
    /// transform is display-only.
    /// Per-section ceiling for the INLINE panel render.
    ///
    /// The write-up is inside the sheet's own ScrollView, so it cannot be given a
    /// bounded scroll view of its own without the two fighting for the same
    /// gesture. Bound the TEXT instead: measured, a 5,000-character write-up
    /// renders ~1,448pt and the worst real one ~2,700pt inside a 640pt pane,
    /// which pushes the voice rows this sheet exists for far off-screen and
    /// leaves an 18-20% scroll thumb. The clipboard forms carry the whole thing;
    /// this is a preview.
    static let panelSectionMaxChars = 900

    /// `panelText`, bounded, with the remainder accounted for rather than hidden.
    static func panelPreview(_ raw: String) -> String {
        let full = panelText(raw)
        guard full.count > panelSectionMaxChars else { return full }
        // Cut on a whitespace boundary so the preview does not end mid-word.
        let hard = full.index(full.startIndex, offsetBy: panelSectionMaxChars)
        let cut = full[..<hard].lastIndex(where: { $0 == " " || $0 == "\n" }) ?? hard
        let shown = full[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
        return shown + "\n\n… \(full.count - shown.count) more characters — use the copy buttons above."
    }

    static func panelText(_ body: String) -> String {
        body.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var s = String(line)
            if let m = s.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                s = String(s[m.upperBound...]).uppercased()
            }
            s = s.replacingOccurrences(of: "- [ ] ", with: "• ")
            s = s.replacingOccurrences(of: "- [x] ", with: "✓ ")
            // Only when they PAIR. Unconditional stripping turned `2**3` into
            // `23` and `**/blog` into `/blog` (18 real occurrences).
            if s.components(separatedBy: "**").count % 2 == 1 {
                s = s.replacingOccurrences(of: "**", with: "")
            }
            return s
        }.joined(separator: "\n")
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let sessionId = o["sessionId"]?.string else { return nil }
        self.sessionId = sessionId
        title = o["title"]?.string ?? "Untitled meeting"
        date = o["date"]?.string ?? ""
        durationMin = o["durationMin"]?.int ?? 0
        scribeAvailable = o["scribeAvailable"]?.bool ?? false
        summary = o["summary"]?.string ?? ""
        topics = o["topics"]?.string ?? ""
        decisions = o["decisions"]?.string ?? ""
        actions = o["actions"]?.string ?? ""
        transcriptChars = o["transcriptChars"]?.int ?? 0
        capturedChars = o["capturedChars"]?.int ?? 0
        domain = o["domain"]?.string ?? ""
        removedNames = (o["removedNames"]?.array ?? []).compactMap { item in
            guard let e = item.object, let l = e["label"]?.string, !l.isEmpty else { return nil }
            return (label: l, proseStale: e["proseStale"]?.bool ?? false)
        }
        // Read BEFORE the counts, which fall back to these lengths.
        let sumText = o["clipboardSummary"]?.string ?? ""
        let fullText = o["clipboardFull"]?.string ?? ""
        clipboardSummary = sumText
        clipboardFull = fullText
        // Fall back to the STRINGS we were actually given. Published server
        // 6.21.28 has the /content route but NOT these two fields, so `?? 0`
        // labelled every button "Full (1 KB)" against real payloads of 54,451 /
        // 43,815 / 39,334 characters — wrong on the very first click, and
        // "Copied full meeting (1 KB)" in the confirmation afterwards. The
        // string is the truth; the count is a convenience.
        summaryChars = o["summaryChars"]?.int ?? sumText.count
        fullChars = o["fullChars"]?.int ?? fullText.count
        coverage = o["coverage"]?.double
        sharesReported = o["sharesReported"]?.bool ?? false
        extras = (o["extras"]?.array ?? []).compactMap { item in
            guard let e = item.object, let h = e["heading"]?.string,
                  let b = e["body"]?.string, !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (h, b)
        }
    }
}

struct VoiceProfileOption: Identifiable, Sendable, Hashable {
    let name: String
    let embeddings: Int
    var id: String { name }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let name = o["name"]?.string else { return nil }
        self.name = name
        embeddings = o["embeddings"]?.int ?? 0
    }

    init(name: String, embeddings: Int) {
        self.name = name
        self.embeddings = embeddings
    }
}

/// One occurrence of an enrolled voice in a saved meeting.
///
/// `observedMatch` is deliberately not called confidence: it is the mean
/// similarity of this occurrence, not a permanent confidence score for a human.
struct VoiceDirectoryAppearance: Identifiable, Sendable, Hashable {
    let sessionId: String
    let title: String
    let date: String
    let source: String
    let mutable: Bool
    let segments: Int
    let speakingMs: Int
    let speakingTimeSource: String
    let observedMatch: Double?
    let reliability: String
    let confirmedByHuman: Bool
    let needsReview: Bool

    var id: String { "\(sessionId):\(title)" }

    init?(_ value: JSONValue?) {
        guard let o = value?.object,
              let sessionId = o["sessionId"]?.string,
              !sessionId.isEmpty else { return nil }
        self.sessionId = sessionId
        title = o["title"]?.string ?? "Untitled meeting"
        date = o["date"]?.string ?? ""
        source = o["source"]?.string ?? ""
        mutable = o["mutable"]?.bool ?? true
        segments = o["segments"]?.int ?? 0
        speakingMs = o["speakingMs"]?.int ?? 0
        speakingTimeSource = o["speakingTimeSource"]?.string ?? "chunks"
        observedMatch = o["observedMatch"]?.double
        reliability = o["reliability"]?.string ?? "weak"
        confirmedByHuman = o["confirmedByHuman"]?.bool ?? false
        needsReview = o["needsReview"]?.bool ?? false
    }
}

/// Server-built, bounded aggregate for one enrolled identity.
/// One held session of unrecognized-speaker audio, the raw material for adding a
/// net-new voice.
///
/// The server keeps this for 72 hours and then deletes it, so `expiresIn` is not
/// decoration: it is the window in which a voice can still be named from real
/// meeting audio rather than a cold sample.
struct ExtAudioSession: Identifiable, Sendable, Hashable {
    let sessionId: String
    let chunks: Int
    let ageHours: Double
    /// Server-rendered, e.g. "68.4h". Rendered rather than computed so the
    /// countdown cannot drift from the retention the server actually enforces.
    let expiresIn: String

    var id: String { sessionId }

    init?(_ value: JSONValue?) {
        guard let o = value?.object,
              let sessionId = o["sessionId"]?.string,
              !sessionId.isEmpty else { return nil }
        self.sessionId = sessionId
        chunks = o["chunks"]?.int ?? 0
        ageHours = o["ageHours"]?.double ?? 0
        expiresIn = o["expiresIn"]?.string ?? ""
    }
}

struct VoiceDirectoryPerson: Identifiable, Sendable, Hashable {
    let name: String
    let isOwner: Bool
    let embeddings: Int
    let sources: [String: Int]
    let sourcesAligned: Bool
    let assertedSegments: Int
    let candidateSegments: Int
    let assertedSpeakingMs: Int
    let candidateSpeakingMs: Int
    let meetingCount: Int
    let reviewMeetingCount: Int
    let observedMatch: Double?
    let observedMatchSegments: Int
    let reliabilityCounts: [String: Int]
    let firstSeen: String?
    let lastSeen: String?
    let appearances: [VoiceDirectoryAppearance]

    var id: String { name }
    var needsAttention: Bool { reviewMeetingCount > 0 || !sourcesAligned }

    init?(_ value: JSONValue?) {
        guard let o = value?.object,
              let name = o["name"]?.string,
              !name.isEmpty else { return nil }
        self.name = name
        isOwner = o["isOwner"]?.bool ?? false
        embeddings = o["embeddings"]?.int ?? 0
        sources = (o["sources"]?.object ?? [:]).reduce(into: [:]) { result, pair in
            result[pair.key] = pair.value.int ?? 0
        }
        sourcesAligned = o["sourcesAligned"]?.bool ?? true
        assertedSegments = o["assertedSegments"]?.int ?? 0
        candidateSegments = o["candidateSegments"]?.int ?? 0
        assertedSpeakingMs = o["assertedSpeakingMs"]?.int ?? 0
        candidateSpeakingMs = o["candidateSpeakingMs"]?.int ?? 0
        meetingCount = o["meetingCount"]?.int ?? 0
        reviewMeetingCount = o["reviewMeetingCount"]?.int ?? 0
        observedMatch = o["observedMatch"]?.double
        observedMatchSegments = o["observedMatchSegments"]?.int ?? 0
        reliabilityCounts = (o["reliabilityCounts"]?.object ?? [:]).reduce(into: [:]) { result, pair in
            result[pair.key] = pair.value.int ?? 0
        }
        firstSeen = o["firstSeen"]?.string
        lastSeen = o["lastSeen"]?.string
        appearances = (o["appearances"]?.array ?? []).compactMap(VoiceDirectoryAppearance.init)
    }
}

/// How far a correction reaches.
///
/// `thisMeeting` is the DEFAULT and the reason this type exists. Until 0.5.0 the
/// panel only ever called the global merge, so renaming a voice rewrote every
/// meeting that person appears in — Miles: "I thought that what we wanted to do
/// was make this much more segmented." A voice misheard in one room is not
/// evidence that every past attribution was wrong.
/// One archived day, from the server's sidecar index. Counts come from the index,
/// never from parsing the day — a single real day can cost gigabytes to
/// materialise, which is why the index exists at all.
struct ArchiveDay: Identifiable, Sendable, Hashable {
    let date: String
    let summary: String?
    let chatCount: Int
    let exchangeCount: Int

    var id: String { date }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let date = o["date"]?.string, !date.isEmpty else { return nil }
        self.date = date
        summary = o["summary"]?.string
        chatCount = o["chatCount"]?.int ?? 0
        exchangeCount = o["exchangeCount"]?.int ?? 0
    }

    /// Miles, 2026: a date list must show VOLUME, not just the latest line —
    /// "date, N chats, topic". Without the counts there is no way to tell a busy
    /// day from an idle one at a glance.
    var countsSummary: String {
        let chats = "\(chatCount) chat\(chatCount == 1 ? "" : "s")"
        let ex = "\(exchangeCount) message\(exchangeCount == 1 ? "" : "s")"
        return "\(chats) · \(ex)"
    }
}

/// A day that matched an archive search, with the text around the match. Hits are
/// attributed to a DATE, not a chat: the server scans day files as raw bytes and
/// never materialises one, so chat-level attribution is not available from a
/// search. Opening the day loads its chats through the normal route.
struct ArchiveHit: Identifiable, Sendable, Hashable {
    let date: String
    let matches: Int
    let snippets: [String]

    var id: String { date }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let date = o["date"]?.string, !date.isEmpty else { return nil }
        self.date = date
        matches = o["matches"]?.int ?? 0
        snippets = (o["snippets"]?.array ?? []).compactMap { $0.string }
    }
}

enum CorrectionScope: String, Sendable, CaseIterable, Identifiable {
    case thisMeeting
    case everywhere

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thisMeeting: return "Just this meeting"
        case .everywhere: return "Every meeting"
        }
    }

    var detail: String {
        switch self {
        case .thisMeeting:
            // Server 6.36.17+: a real target name enrols those chunks into a
            // profile (creates one when the name is new). Other meetings are
            // not rewritten — that remains the explicit "Every meeting" fold.
            return "Corrects this meeting and adds samples to the voice profile. Other meetings are left alone."
        case .everywhere:
            return "Folds one profile into the other across every meeting. Cannot be undone here."
        }
    }
}

/// What changed, per surface, so a correction reporting success can be checked
/// rather than trusted.
struct CorrectionSurfaces: Sendable, Hashable {
    let sidecar: Int
    let attendees: Int
    let transcript: Int

    init(_ value: JSONValue?) {
        let o = value?.object ?? [:]
        sidecar = o["sidecar"]?.int ?? 0
        attendees = o["attendees"]?.int ?? 0
        transcript = o["transcript"]?.int ?? 0
    }
}

/// A correction the user has been shown but not yet confirmed. Holding the
/// preview in state — rather than applying and reporting afterwards — is what
/// makes the confirmation real.
struct PendingCorrection: Identifiable, Sendable {
    /// The label being corrected.
    let from: String
    /// The new name, or nil to REMOVE the name (this voice was not in the room).
    let to: String?
    let scope: CorrectionScope
    let message: String
    let surfaces: CorrectionSurfaces
    let similarity: Double?
    /// Server declined — shown with its reason instead of read as a failure.
    let refused: Bool
    /// True when the refusal is only a STALLED earlier correction, which the user
    /// can override. A genuine decline (wrong label, no such chunk) cannot be
    /// forced, so the two are kept distinct rather than both being "refused".
    let forceable: Bool
    /// Narrative prose still names the old speaker and is deliberately not
    /// rewritten, because summaries refer to people by first name.
    let proseStale: Bool
    /// True when this names a voice that was never attributed to anyone.
    ///
    /// An unattributed row is a cluster the identifier could NOT match, so
    /// nothing ever established it is one person — a big cluster on a G2 mic is
    /// frequently several. Naming it writes that name onto every one of its
    /// segments, so the card says so before the click rather than after.
    let isNameAssignment: Bool
    /// True when `to` is not in the enrolled-profile list. Saving should create
    /// that profile so the next cluster in this meeting can pick the name.
    let createsProfile: Bool
    /// Training samples this correction would retract from the profile.
    let wouldRetract: Int
    /// Samples that predate meeting-level provenance and cannot be retracted.
    let untraceable: Int

    var id: String { "\(from)->\(to ?? "«unidentified»")@\(scope.rawValue)" }
    var isDeattribution: Bool { to == nil }
}
