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
    let discussionSummary: String

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

    /// Live pet gate: keep-warm off, then `alive` or Running/Waiting.
    /// Not `showsStateChip` — `stale` chips and `alive && recent` does not.
    var isPetVisible: Bool {
        if isKeepWarm { return false }
        if alive { return true }
        return state == "running" || state == "waiting"
    }

    var petSubtitle: String {
        let summary = discussionSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { return summary }
        if !waitingFor.isEmpty { return waitingFor }
        return workspace
    }

    /// Running vs idle for the desktop pet. `alive` still shows the row; this
    /// is what the figure and list print so a waiting Cursor thread is not
    /// mistaken for work in flight.
    var petStateCaption: String {
        switch state {
        case "running": "Running"
        case "waiting": "Waiting"
        case "stale": "Stale"
        default: "Idle"
        }
    }

    var isPetWorking: Bool { state == "running" }

    /// Cursor rows use the platform jump (Agents raise). Claude and Codex still
    /// open the Activity row from the target control.
    var petTargetOpensAgentWindow: Bool { provider == "cursor" }

    /// Running first, then waiting, then the newest stamp. An idle-but-alive
    /// Claude row must not sit above a Cursor turn that is actually in flight.
    static func petVisibleSessions(in sessions: [ClaudeSession]) -> [ClaudeSession] {
        sessions.filter(\.isPetVisible).sorted { a, b in
            let aRank = petLiveRank(a)
            let bRank = petLiveRank(b)
            if aRank != bRank { return aRank < bRank }
            return a.updatedAt > b.updatedAt
        }
    }

    /// Mission-rows sectioning (0.5.155, design B): the live list groups by
    /// weight — running rich, waiting amber, idle receded. Pure so the
    /// contract executes the grouping; within each section the sorted input
    /// order (petVisibleSessions) is preserved.
    static func petSections(_ sessions: [ClaudeSession])
        -> (running: [ClaudeSession], waiting: [ClaudeSession], idle: [ClaudeSession]) {
        (sessions.filter(\.isPetWorking),
         sessions.filter { $0.state == "waiting" },
         sessions.filter { !$0.isPetWorking && $0.state != "waiting" })
    }

    private static func petLiveRank(_ session: ClaudeSession) -> Int {
        switch session.state {
        case "running": 0
        case "waiting": 1
        default: 2
        }
    }

    /// Follow the working session. A clicked idle row stays only when nothing
    /// else is Running, so a leftover Claude PID cannot pin the bubble.
    static func petPreferredFocus(in sessions: [ClaudeSession], focusedID: String?) -> ClaudeSession? {
        let working = sessions.filter(\.isPetWorking)
        if let focusedID, let row = working.first(where: { $0.id == focusedID }) {
            return row
        }
        if let firstWorking = working.first {
            return firstWorking
        }
        if let focusedID, let row = sessions.first(where: { $0.id == focusedID }) {
            return row
        }
        return sessions.first
    }

    /// The mission row's mono LIVE line (0.5.155, design B): what the agent
    /// is doing RIGHT NOW. A waiting row names what it waits on; a running
    /// row speaks its live summary — the field the helper has shipped all
    /// along and the pet never rendered.
    var petLiveLine: String {
        if state == "waiting" {
            let need = waitingFor.trimmingCharacters(in: .whitespacesAndNewlines)
            return need.isEmpty || need == "user" ? "needs you" : need
        }
        let summary = discussionSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? "working" : summary
    }

    /// The mission row's right-aligned figure: "4s", "12m", "1h", "2d" — the
    /// bare duration. relativeAgeLabel keeps its "Updated …" prose for
    /// surfaces that read as sentences.
    func compactAgeLabel(now: Date = Date()) -> String? {
        guard let updated = updatedDate else { return nil }
        let seconds = max(0, now.timeIntervalSince(updated))
        if seconds < 60 { return "\(Int(seconds.rounded(.down)))s" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded(.down)))m" }
        if seconds < 86400 { return "\(Int((seconds / 3600).rounded(.down)))h" }
        return "\(Int((seconds / 86400).rounded(.down)))d"
    }

    func relativeAgeLabel(now: Date = Date()) -> String? {
        guard let updated = updatedDate else { return nil }
        let seconds = max(0, now.timeIntervalSince(updated))
        let value: String
        if seconds < 60 {
            value = "\(Int(seconds.rounded(.down)))s ago"
        } else if seconds < 3600 {
            value = "\(Int((seconds / 60).rounded(.down)))m ago"
        } else if seconds < 86400 {
            value = "\(Int((seconds / 3600).rounded(.down)))h ago"
        } else {
            value = "\(Int((seconds / 86400).rounded(.down)))d ago"
        }
        return "Updated \(value)"
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
        discussionSummary = o["discussion_summary"]?.string ?? o["discussionSummary"]?.string ?? ""
    }

    static func isKeepWarmSessionTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "ready" { return true }
        return t.hasPrefix("this is an automated local readiness check")
    }
}

/// Match an Agents list row to a pet session name.
///
/// Never used against Cursor window titles. That raise is the IDE.
enum CursorAgentTabMatch {
    static let minimumCount = 8

    static func matches(_ rawHave: String, want rawWant: String) -> Bool {
        var have = rawHave.trimmingCharacters(in: .whitespacesAndNewlines)
        // Cursor's Agents rows expose their accessible title as
        // "Chat title. <name>" (AX tree probed 2026-08-27). Strip that chrome;
        // the minimum-length gate applies to what remains.
        for prefix in ["chat title.", "chat title"] where have.lowercased().hasPrefix(prefix) {
            have = String(have.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        let want = rawWant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard have.count >= minimumCount, want.count >= minimumCount else { return false }
        if have.caseInsensitiveCompare(want) == .orderedSame { return true }
        let haveCore = have.trimmingCharacters(in: CharacterSet(charactersIn: ".…"))
        if haveCore.count >= minimumCount, want.lowercased().hasPrefix(haveCore.lowercased()) {
            return true
        }
        if have.lowercased().hasPrefix(want.lowercased()) { return true }
        return false
    }
}

/// Claude Desktop prefixes sidebar rows with Idle / Awaiting input / etc.
/// Strip that before reusing the Agents matcher. Never used against window
/// titles.
enum ClaudeSessionRowMatch {
    static let statusPrefixes = [
        "Idle ",
        "Awaiting input ",
        "Unread response ",
        "Error ",
        "Running ",
    ]

    static func displayLabel(_ rawHave: String) -> String {
        let have = rawHave.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = have.lowercased()
        for prefix in statusPrefixes {
            if lower.hasPrefix(prefix.lowercased()) {
                return String(have.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return have
    }

    static func matches(_ rawHave: String, want: String) -> Bool {
        CursorAgentTabMatch.matches(displayLabel(rawHave), want: want)
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
/// Dropping an idle row from the pet list is a VIEW decision, never a session
/// lifecycle change: nothing is stopped, killed, or deleted. What gets stored
/// is the row's `updatedAt` AT THE MOMENT it was dismissed, so a session that
/// starts moving again re-appears on its own rather than staying hidden behind
/// a stale decision. The point is the escalation pose — four parked sessions
/// pin the pet in the five-droid swarm and hide the one that is actually live.
/// One finished session, kept so a completion outlives its 2-second flash.
/// D2: the pet used to flash .done and keep no record of WHICH session finished.
struct PetCompletion: Identifiable, Sendable, Equatable {
    let id: String          // ClaudeSession.id == "provider:sessionId"
    let sessionId: String   // native id, what session-reveal --session takes
    let name: String
    let provider: String
    let workspace: String
    let finishedAt: Date
    var seen: Bool
}

// Codable by hand in BOTH directions: decode defaults provider/workspace to ""
// and seen to false so a partial live blob still decodes, and a type with only
// init(from:) does not compile.
extension PetCompletion: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, name, provider, workspace, finishedAt, seen
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace) ?? ""
        finishedAt = try c.decode(Date.self, forKey: .finishedAt)
        seen = try c.decodeIfPresent(Bool.self, forKey: .seen) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(name, forKey: .name)
        try c.encode(provider, forKey: .provider)
        try c.encode(workspace, forKey: .workspace)
        try c.encode(finishedAt, forKey: .finishedAt)
        try c.encode(seen, forKey: .seen)
    }
}

extension ClaudeSession {
    /// A finished chip re-hydrated into a routable session. `state: "recent"`
    /// + `alive: true` keeps it isPetVisible-shaped for the reveal path.
    static func fromCompletion(_ row: PetCompletion) -> ClaudeSession? {
        ClaudeSession(.object([
            "id": .string(row.sessionId),
            "provider": .string(row.provider),
            "name": .string(row.name),
            "workspace": .string(row.workspace),
            "state": .string("recent"),
            "alive": .bool(true),
            "waitingFor": .string(""),
        ]))
    }

    /// The ONLY terminals the jump may target — pinned by ModelsContract with
    /// negative-membership asserts for all three non-terminal tty owners the
    /// 2026-08-30 census found (Claude Desktop itself owned ttys006). tty
    /// presence is NEVER the classifier; this list is.
    static let terminalHostBundleIds: Set<String> = [
        "com.googlecode.iterm2",
        "com.apple.Terminal",
    ]
}

/// Where a claude session's jump should land. Pure and payload-free so
/// ModelsContract can execute the whole matrix; the caller holds the resolved
/// NSRunningApplication and acts on it when the route says .terminal.
enum PetJumpRoute: Equatable {
    case terminal
    case desktopSidebar

    /// Default-deny: anything that is not exactly a cli entrypoint plus an
    /// allowlisted host falls through to the Desktop sidebar path unchanged.
    static func route(entrypoint: String?, hostBundleId: String?) -> PetJumpRoute {
        let ep = entrypoint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard ep == "cli", let host = hostBundleId, !host.isEmpty,
              ClaudeSession.terminalHostBundleIds.contains(host) else {
            return .desktopSidebar
        }
        return .terminal
    }

    /// The procStart liveness comparator, executable and mutation-testable.
    /// `recorded` is the session JSON's `procStart` — a ctime-style string
    /// rendered in UTC with NO timezone token ("Sun Aug 30 12:34:55 2026").
    /// `kernelSeconds` is kinfo_proc.kp_proc.p_un.__p_starttime.tv_sec.
    /// Returns nil (fail OPEN — keep 0.5.139 routing) when either side is
    /// unavailable or unparseable; a naive local-time comparison here failed
    /// closed by exactly the machine's UTC offset and would have killed every
    /// jump. Tolerance ±1s, measured Δ=0 on live pids; startedAt (JS clock,
    /// +1.4/+2.9s off) must never be substituted.
    static func procStartMatches(
        recorded: String?, kernelSeconds: Int?, tolerance: TimeInterval = 1
    ) -> Bool? {
        guard let recorded, let kernelSeconds else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        guard let parsed = f.date(from: recorded.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return abs(parsed.timeIntervalSince1970 - Double(kernelSeconds)) <= tolerance
    }
}

/// The idle-state health bar riding above the sprite (0.5.142 ledger design,
/// Miles 2026-08-30). Pure so ModelsContract executes the whole vocabulary.
///
/// Counts use the SAME predicates as PetSpritePose.resolve (`isPetWorking`,
/// state == "waiting") — a bar that disagrees with the fight ladder would read
/// as a bug. `done`/`unseen` come from the completion chips, so the bar and
/// the DONE pill can never diverge either.
struct PetLedger: Equatable {
    var running: Int
    var waiting: Int
    var done: Int
    var unseen: Int

    enum SegmentKind: Equatable { case waiting, running, done }
    struct Segment: Equatable {
        var kind: SegmentKind
        var count: Int
    }

    static func resolve(sessions: [ClaudeSession], completions: [PetCompletion]) -> PetLedger {
        PetLedger(
            running: sessions.filter(\.isPetWorking).count,
            waiting: sessions.filter { $0.state == "waiting" }.count,
            done: completions.count,
            unseen: completions.filter { !$0.seen }.count
        )
    }

    var isQuiet: Bool { running + waiting + done == 0 }

    /// Waiting takes the FRONT of the bar in amber — it is the state allowed
    /// to interrupt the visual order. Zero-count segments never render.
    var segments: [Segment] {
        var out: [Segment] = []
        if waiting > 0 { out.append(Segment(kind: .waiting, count: waiting)) }
        if running > 0 { out.append(Segment(kind: .running, count: running)) }
        if done > 0 { out.append(Segment(kind: .done, count: done)) }
        return out
    }

    /// The words under the bar. Waiting leads when present; an all-done day
    /// reads "N DONE · M NEW" so fresh finishes are legible at a glance; a
    /// quiet pet says IDLE rather than rendering an empty row of zeros.
    var caption: String {
        if isQuiet { return "IDLE" }
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) WAITING") }
        if running > 0 { parts.append("\(running) RUNNING") }
        if done > 0 { parts.append("\(done) DONE") }
        if unseen > 0, running == 0, waiting == 0 { parts.append("\(unseen) NEW") }
        return parts.joined(separator: " · ")
    }
}

/// D1: the fleet wasWorking && !isWorking Bool could only say "someone
/// finished" — one of N finishing while others still ran never fired. The
/// detector diffs per id, so every finish emits exactly once.
enum PetCompletionDetector {
    static let ringCap = 8
    static let maxAge: TimeInterval = 4 * 60 * 60

    /// `previous`/`current` are pet-visible, dismissals-unfiltered snapshots.
    /// `suppressedIDs` = keep-warm ids ∪ ids currently hidden by
    /// `petDismissals.hides()`. Never union raw stamp keys: a dismissed row
    /// that later runs again has a leftover stamp but hides() is false, and
    /// that finish must still emit.
    static func diff(
        previous: [ClaudeSession],
        current: [ClaudeSession],
        suppressedIDs: Set<String>,
        now: Date = Date()
    ) -> [PetCompletion] {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var out: [PetCompletion] = []
        for prior in previous where prior.isPetWorking {
            guard !suppressedIDs.contains(prior.id) else { continue }
            if let now_ = currentByID[prior.id] {
                // running -> waiting is a handoff to Miles, not a finish.
                guard !now_.isPetWorking, now_.state != "waiting" else { continue }
            }
            out.append(PetCompletion(
                id: prior.id, sessionId: prior.sessionId, name: prior.name,
                provider: prior.provider, workspace: prior.workspace,
                finishedAt: now, seen: false
            ))
        }
        return out
    }

    /// Merge, pruned and capped — extracted so it is execution-testable
    /// without ControllerModel. Drops chips whose id is running or waiting in
    /// `current`, upserts `fresh` (seen resets to false when the prior row was
    /// working), ages out past `maxAge`, caps at `ringCap` by oldest.
    static func apply(
        existing: [PetCompletion],
        fresh: [PetCompletion],
        previous: [ClaudeSession],
        current: [ClaudeSession],
        now: Date = Date()
    ) -> [PetCompletion] {
        let active = Set(current.filter { $0.isPetWorking || $0.state == "waiting" }.map(\.id))
        let workingBefore = Set(previous.filter(\.isPetWorking).map(\.id))
        var rows = existing.filter { !active.contains($0.id) }
        for row in fresh {
            var next = row
            if let i = rows.firstIndex(where: { $0.id == row.id }) {
                next.seen = workingBefore.contains(row.id) ? false : rows[i].seen
                rows[i] = next
            } else {
                rows.append(next)
            }
        }
        rows = canonicalized(rows)
        rows.removeAll { now.timeIntervalSince($0.finishedAt) > maxAge }
        if rows.count > ringCap {
            rows.sort { $0.finishedAt > $1.finishedAt }
            rows = Array(rows.prefix(ringCap))
        }
        return rows
    }

    /// One session, one chip. The live list carries the same session under two
    /// ids at once — the full UUID from the sessions list and the 8-char short
    /// form from the helper's live overlay — so a finish emitted TWO chips
    /// (observed live: claude:9644b527 and claude:9644b527-da59-…). Merge
    /// prefix-related same-provider rows, keeping the longest sessionId (the
    /// full id is what the transcript lookup wants), the newest finishedAt,
    /// and unseen-wins so a merge never hides news.
    static func canonicalized(_ rows: [PetCompletion]) -> [PetCompletion] {
        var out: [PetCompletion] = []
        for row in rows.sorted(by: { $0.sessionId.count > $1.sessionId.count }) {
            if let i = out.firstIndex(where: {
                $0.provider == row.provider
                    && ($0.sessionId.lowercased().hasPrefix(row.sessionId.lowercased())
                        || row.sessionId.lowercased().hasPrefix($0.sessionId.lowercased()))
            }) {
                let keep = out[i]
                out[i] = PetCompletion(
                    id: keep.id, sessionId: keep.sessionId,
                    name: keep.name.count >= row.name.count ? keep.name : row.name,
                    provider: keep.provider,
                    workspace: keep.workspace.isEmpty ? row.workspace : keep.workspace,
                    finishedAt: max(keep.finishedAt, row.finishedAt),
                    seen: keep.seen && row.seen
                )
            } else {
                out.append(row)
            }
        }
        return out
    }
}

struct PetDismissals: Sendable, Equatable {
    /// How long a row must sit still before the drop control is offered.
    static let idleGrace: TimeInterval = 600

    private(set) var stamps: [String: String]

    init(stamps: [String: String] = [:]) { self.stamps = stamps }

    /// A running row is never dismissable, however old its stamp looks.
    static func isDismissable(_ session: ClaudeSession, now: Date = Date()) -> Bool {
        guard !session.isPetWorking else { return false }
        guard let updated = session.updatedDate else { return false }
        return now.timeIntervalSince(updated) >= idleGrace
    }

    mutating func dismiss(_ session: ClaudeSession) { stamps[session.id] = session.updatedAt }

    func hides(_ session: ClaudeSession) -> Bool {
        guard let stamp = stamps[session.id] else { return false }
        return stamp == session.updatedAt
    }

    func filter(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        sessions.filter { !hides($0) }
    }

    /// Forget rows that are gone. Must be handed the UNFILTERED list — pruning
    /// against the filtered one would drop every dismissal on the next poll and
    /// walk the row straight back in.
    mutating func prune(against sessions: [ClaudeSession]) {
        let live = Set(sessions.map(\.id))
        stamps = stamps.filter { live.contains($0.key) }
    }
}

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

    /// The row badge's icon, chosen by what is actually attached.
    ///
    /// Every attachment used to render `photo`, so Message #29 -- a 75-second
    /// video -- wore an image icon and you could not tell a video from a
    /// picture from a file without opening it (Miles, 2026-08-26). A mixed
    /// turn gets a paperclip rather than picking a winner among its parts.
    var attachmentGlyph: String? {
        guard !attachments.isEmpty else { return nil }
        let categories = Set(attachments.map(\.category))
        guard categories.count == 1 else { return "paperclip" }
        switch categories.first {
        case "video": return "video"
        case "document": return "doc.text"
        default: return "photo"
        }
    }

    /// The single category this turn's attachments share, or "mixed". Nil when
    /// the turn has no attachments at all.
    var attachmentCategory: String? {
        guard !attachments.isEmpty else { return nil }
        let categories = Set(attachments.map(\.category))
        return categories.count == 1 ? categories.first : "mixed"
    }

    /// Hover text naming the type in words, because a 9.5pt glyph is a hint
    /// and the tooltip is where the answer should be unambiguous.
    var attachmentSummary: String? {
        guard !attachments.isEmpty else { return nil }
        let count = attachments.count
        let categories = Set(attachments.map(\.category))
        guard categories.count == 1 else { return "\(count) attachments" }
        let noun: String
        switch categories.first {
        case "video": noun = count == 1 ? "video" : "videos"
        case "document": noun = count == 1 ? "file" : "files"
        default: noun = count == 1 ? "image" : "images"
        }
        return "\(count) \(noun)"
    }

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

    /// Background ticks must not erase a live offer when the helper returns
    /// ok:true with reason unreachable or malformed. Those payloads look like
    /// "no update" (`updateAvailable: false`) because the helper never throws
    /// on a missed fetch. A completed check (upToDate, newer, killSwitch,
    /// requiresMacOS) always replaces.
    static func merging(previous: AppUpdateInfo, incoming: AppUpdateInfo) -> AppUpdateInfo {
        if previous.shouldSurface && (incoming.reason == "unreachable" || incoming.reason == "malformed") {
            return previous
        }
        return incoming
    }
}

/// Status-item glyph. Template image so it follows the menu bar tint.
/// The eyeglasses / eyeglasses.slash literals stay at the call site so running
/// state remains visible with the panel closed. The badge is a mask pip, not
/// a colored overlay.
enum MenuBarIcon {
    static let pointSize: CGFloat = 16

    static func compose(systemName: String, updateAvailable: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let base = (NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)) ?? NSImage(size: NSSize(width: pointSize * 1.6, height: pointSize * 0.7))
        let glyph = base.size
        guard glyph.width > 0, glyph.height > 0 else {
            let empty = NSImage(size: NSSize(width: pointSize, height: pointSize))
            empty.isTemplate = true
            return empty
        }
        // Draw 1:1 at the symbol's own size. Filling a square is what squashed
        // eyeglasses in 0.5.90.
        let pip: CGFloat = 5
        let composed = NSImage(size: glyph, flipped: false) { rect in
            base.draw(in: NSRect(origin: .zero, size: glyph))
            if updateAvailable {
                let pipRect = NSRect(x: rect.maxX - pip, y: rect.maxY - pip, width: pip, height: pip)
                NSColor.black.setFill()
                NSBezierPath(ovalIn: pipRect).fill()
            }
            return true
        }
        composed.isTemplate = true
        return composed
    }
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
    /// Zero-padded "HH:MM" from the server. `date` is day-granularity, so
    /// without this a newest-first sort ties every meeting captured on the same
    /// day — and a heavy G2 day is a dozen of them. Empty when a server does not
    /// send it; those rows sort to the end of their day rather than being
    /// silently treated as midnight.
    let time: String
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

    /// "2026-08-28 · 11:51 · 52 minutes". The clock time earns its place once
    /// the list can be sorted chronologically: a dozen rows all reading
    /// "2026-08-28" give the reader no way to see that the order is real.
    var dateLine: String {
        var parts = [date]
        if !time.isEmpty { parts.append(time) }
        parts.append(duration)
        return parts.joined(separator: " · ")
    }

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
        time = o["time"]?.string ?? ""
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

    /// Chronological ordering, newest or oldest first.
    ///
    /// Ignores review rank entirely — that is the point. `ranked` answers "what
    /// should I work on next", this answers "what happened when", and blending
    /// them would produce a list that is neither.
    func chronological(_ meetings: [ReviewableMeeting], newestFirst: Bool) -> [ReviewableMeeting] {
        meetings.sorted { a, b in
            if a.date != b.date { return newestFirst ? a.date > b.date : a.date < b.date }
            // Same day: fall to clock time. An empty time sorts LAST within its
            // day in both directions, because "unknown" is not "00:00" — a
            // missing time must never claim to be the earliest meeting.
            if a.time != b.time {
                if a.time.isEmpty { return false }
                if b.time.isEmpty { return true }
                return newestFirst ? a.time > b.time : a.time < b.time
            }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    func visible(
        _ meetings: [ReviewableMeeting],
        hideReviewed: Bool,
        sort: MeetingReviewSort = .reviewPriority
    ) -> [ReviewableMeeting] {
        let ordered: [ReviewableMeeting]
        switch sort {
        case .reviewPriority: ordered = ranked(meetings)
        case .newest: ordered = chronological(meetings, newestFirst: true)
        case .oldest: ordered = chronological(meetings, newestFirst: false)
        }
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

/// How the "Meetings to review" list is ordered.
///
/// Default stays `reviewPriority` — the list is a work queue first, and the
/// unnamed-speaker rows are why the surface exists. Chronological is opt-in for
/// "what did I record on Thursday", which the priority order actively hides by
/// interleaving old unnamed meetings above today's captures.
enum MeetingReviewSort: String, CaseIterable, Identifiable, Sendable {
    case reviewPriority
    case newest
    case oldest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reviewPriority: "Needs review first"
        case .newest: "Newest first"
        case .oldest: "Oldest first"
        }
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

/// One archived conversation inside a day. The archive stores a day as a list of
/// chats, so this is the middle rung of the drill-through: Archive lists dates,
/// a date lists these, and opening one loads its `ArchiveMessage` turns.
struct ArchiveChat: Identifiable, Sendable, Hashable {
    let index: Int
    let summary: String?
    let exchangeCount: Int
    let startedAt: TimeInterval?

    var id: Int { index }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let index = o["index"]?.int else { return nil }
        self.index = index
        summary = o["summary"]?.string
        exchangeCount = o["exchangeCount"]?.int ?? 0
        // Same millisecond heuristic the live turns use: the archive writes epoch
        // milliseconds, and reading those as seconds would date every chat to 1970.
        if let number = o["startedAt"]?.int {
            startedAt = TimeInterval(number) / (number > 10_000_000_000 ? 1000 : 1)
        } else {
            startedAt = nil
        }
    }

    var countLabel: String { "\(exchangeCount) message\(exchangeCount == 1 ? "" : "s")" }

    var timeLabel: String { GlassesTurn.dayAnchoredTime(startedAt) }
}

/// One paired question and answer inside an archived chat. Deliberately separate
/// from `GlassesTurn`: an archived turn carries no session id, no source, and no
/// attachment refs, and inventing empty ones would let the detail view render
/// affordances (Copy + images, attachment strips) that can never resolve.
struct ArchiveMessage: Identifiable, Sendable, Hashable {
    let ordinal: Int
    let no: Int?
    let query: String
    let text: String
    let timestamp: TimeInterval?

    /// Keyed by POSITION, never by `no`. The archive spans era resets, so message
    /// numbers can repeat within a day, and a duplicate id silently drops rows
    /// from a ForEach.
    var id: Int { ordinal }

    init?(_ value: JSONValue?, ordinal: Int) {
        guard let o = value?.object else { return nil }
        self.ordinal = ordinal
        no = o["no"]?.int
        query = o["query"]?.string ?? ""
        text = o["text"]?.string ?? ""
        if let number = o["timestamp"]?.int {
            timestamp = TimeInterval(number) / (number > 10_000_000_000 ? 1000 : 1)
        } else {
            timestamp = nil
        }
    }

    var title: String { no.map { "Message #\($0)" } ?? "Message" }

    var timeLabel: String { GlassesTurn.dayAnchoredTime(timestamp) }

    /// Byte-for-byte the live turn's format. Text pasted out of the archive should
    /// not be distinguishable from text pasted out of Recent.
    var clipboardText: String {
        let label = no.map { "Msg \($0)" } ?? "Msg"
        return "[\(label)] User: \(query)\n[\(label)] COS: \(text)"
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

/// Desktop pet figure size. Medium is the original 64 px sprite. Small and
/// Large are 25% off that. Custom is the sprite in pixels.
enum PetSizePreset: String, CaseIterable, Hashable {
    case small
    case medium
    case large
    case custom

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .custom: "Custom"
        }
    }
}

struct PetSize: Equatable {
    static let mediumPixels = 64
    static let minPixels = 32
    static let maxPixels = 128

    var preset: PetSizePreset
    var customPixels: Int

    var pixels: Int {
        switch preset {
        case .small: Int((Double(Self.mediumPixels) * 0.75).rounded())
        case .medium: Self.mediumPixels
        case .large: Int((Double(Self.mediumPixels) * 1.25).rounded())
        case .custom: Self.clamp(customPixels)
        }
    }

    var scale: CGFloat { CGFloat(pixels) / CGFloat(Self.mediumPixels) }

    func length(_ base: CGFloat) -> CGFloat { (base * scale).rounded() }

    func typeSize(_ base: CGFloat) -> CGFloat { max(8, length(base)) }

    static func clamp(_ value: Int) -> Int {
        min(max(value, minPixels), maxPixels)
    }

    static func load(preset raw: String?, pixels: Int?) -> PetSize {
        let preset = PetSizePreset(rawValue: (raw ?? "").lowercased()) ?? .medium
        return PetSize(preset: preset, customPixels: clamp(pixels ?? mediumPixels))
    }
}

/// Patrol is a transition, not a resting state. It plays as periodic bursts
/// against the exact idle/meditation clips instead of walking forever. Running
/// and combat stories are authored directly into their own strips, so their
/// causal frame order never depends on the ambient scheduler.
///
/// Seeded by segment index and nothing else — no stored state, so a re-render
/// of the same instant always paints the same frame.
enum PetPlaylist {
    /// One beat. Long enough to read as a deliberate change, short enough that
    /// the pet still feels responsive.
    static let segmentSeconds: Double = 2.4
    /// Roughly one beat in three is action; the rest settle.
    static let actionInterval: UInt64 = 3

    private static func rawPick(_ segment: Int) -> Bool {
        var x = UInt64(bitPattern: Int64(segment)) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 30
        x = x &* 0xBF58_476D_1CE4_E5B9
        x ^= x >> 27
        x = x &* 0x94D0_49BB_1331_11EB
        x ^= x >> 31
        return x % actionInterval == 0
    }

    /// The raw hash alone produced runs of eight consecutive action beats —
    /// nineteen seconds of unbroken sprinting, which is the problem this
    /// exists to solve. Two beats is a burst; a third would be a loop, so the
    /// third is always a rest. Still a pure function of the segment index.
    static func isActionSegment(_ segment: Int) -> Bool {
        guard rawPick(segment) else { return false }
        return !(rawPick(segment - 1) && rawPick(segment - 2))
    }

    /// Which calm secondary clip a settled beat draws from. Independent of the
    /// action hash so idle and meditation do not move with the burst cadence.
    /// Signal poses such as flourish and guard stay out of this rotation.
    static func restClip(_ segment: Int, count: Int) -> Int {
        guard count > 1 else { return 0 }
        var x = UInt64(bitPattern: Int64(segment)) &* 0xD6E8_FEB8_6659_FD93
        x ^= x >> 32
        x = x &* 0xFF51_AFD7_ED55_8CCD
        x ^= x >> 29
        return Int(x % UInt64(count))
    }

    /// Which clip to draw from, and which frame of it, at `elapsed` seconds.
    /// `restCounts` is the frame count of each available rest clip.
    static func plan(
        elapsed: Double,
        actionCount: Int,
        restCounts: [Int],
        interval: Double,
        restIntervals: [Double] = []
    ) -> (useAction: Bool, restClip: Int, index: Int) {
        let rests = restCounts.enumerated().compactMap { index, count -> (count: Int, interval: Double)? in
            guard count > 0 else { return nil }
            let restInterval = index < restIntervals.count ? restIntervals[index] : interval
            return (count, restInterval > 0 ? restInterval : interval)
        }
        guard actionCount > 0, interval > 0 else { return (true, 0, 0) }
        let segment = Int((max(0, elapsed) / segmentSeconds).rounded(.down))
        let useAction = rests.isEmpty || isActionSegment(segment)
        let within = max(0, elapsed) - Double(segment) * segmentSeconds
        let clip = useAction ? 0 : restClip(segment, count: rests.count)
        let count = useAction ? actionCount : rests[clip].count
        let frameInterval = useAction ? interval : rests[clip].interval
        let index = count > 0 ? Int(within / frameInterval) % count : 0
        return (useAction, clip, index)
    }
}

/// The character dial, independent of PetSize. Pet size sets the CARD (buttons,
/// text, bubbles, list); this scales only the figure inside it, so the art can
/// be read at detail without inflating the chrome around it.
enum PetCharacterScale {
    static let legacyDefaultPercent = 150
    static let legacyMinPercent = 100
    static let legacyMaxPercent = 300
    static let defaultPercent = 300
    static let minPercent = 100
    static let maxPercent = 600

    static func clamp(_ value: Int) -> Int {
        min(max(value, minPercent), maxPercent)
    }

    static func factor(_ percent: Int) -> CGFloat {
        CGFloat(clamp(percent)) / 100
    }

    /// Version 2 doubles the whole character dial, including an existing saved
    /// preference. Merely raising the slider ceiling would leave someone who
    /// was already at the old 300% maximum looking at the same tiny figure.
    static func migratedLegacyPercent(_ stored: Int?) -> Int {
        let legacy = min(
            max(stored ?? legacyDefaultPercent, legacyMinPercent),
            legacyMaxPercent
        )
        return clamp(legacy * 2)
    }

    /// Load the dial and perform a named, one-time preference migration. The
    /// keys stay caller-owned so this logic is executable without constructing
    /// the full ControllerModel or touching the user's standard defaults.
    static func loadPersistedPercent(
        defaults: UserDefaults,
        percentKey: String,
        generationKey: String,
        generation: Int
    ) -> Int {
        let stored = defaults.object(forKey: percentKey) as? Int
        guard defaults.integer(forKey: generationKey) < generation else {
            return clamp(stored ?? defaultPercent)
        }
        let migrated = migratedLegacyPercent(stored)
        defaults.set(migrated, forKey: percentKey)
        defaults.set(generation, forKey: generationKey)
        return migrated
    }
}

/// Playback rate for every authored pet animation, independent of PetSize and
/// PetCharacterScale. Scaling the animation CLOCK rather than rewriting each
/// pose interval keeps complete stories and ambient playlist beats intact.
enum PetAnimationSpeed {
    static let defaultPercent = 100
    static let minPercent = 25
    static let maxPercent = 200

    static func clamp(_ value: Int) -> Int {
        min(max(value, minPercent), maxPercent)
    }

    static func factor(_ percent: Int) -> Double {
        Double(clamp(percent)) / 100
    }

    static func loadPersistedPercent(defaults: UserDefaults, percentKey: String) -> Int {
        clamp(defaults.object(forKey: percentKey) as? Int ?? defaultPercent)
    }
}

/// Keep the floating pet on a visible display. 0.5.97 grew Large downward from
/// the bottom corner and autosave parked the panel under the screen.
enum PetPanelFrame {
    static func clamped(_ frame: CGRect, screens: [CGRect]) -> CGRect {
        var frame = frame
        guard let fallback = screens.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return frame
        }
        if !screens.contains(where: { $0.intersects(frame) }) {
            frame.origin = CGPoint(x: fallback.maxX - frame.width - 20, y: fallback.minY + 28)
        }
        let screen = screens.first(where: { $0.intersects(frame) }) ?? fallback
        if frame.height > screen.height { frame.size.height = screen.height }
        if frame.width > screen.width { frame.size.width = screen.width }
        if frame.minY < screen.minY { frame.origin.y = screen.minY }
        if frame.maxY > screen.maxY { frame.origin.y = screen.maxY - frame.height }
        if frame.minX < screen.minX { frame.origin.x = screen.minX }
        if frame.maxX > screen.maxX { frame.origin.x = screen.maxX - frame.width }
        return frame
    }
}

private func petSpriteJSONInt(_ value: Any?, fallback: Int) -> Int {
    if let number = value as? Int { return number }
    if let number = value as? NSNumber { return number.intValue }
    return fallback
}

/// Live pose the desktop pet plays. One identity PNG still covers any pose
/// that has no strip of its own.
enum PetSpritePose: String, CaseIterable, Hashable, Sendable {
    case idle
    case thinking
    case reading
    case writing
    case searching
    case grepping
    case waiting
    case working
    case patrol
    case duel
    case trio
    case swarm
    case done
    case error
    case attention
    case stopped

    static let liveCases: [PetSpritePose] = [
        .idle, .patrol, .waiting, .working, .done, .error, .attention, .duel, .trio, .swarm,
    ]

    static var catalogCases: [PetSpritePose] {
        allCases.filter { !liveCases.contains($0) }
    }

    var title: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .reading: "Reading"
        case .writing: "Writing"
        case .searching: "Searching"
        case .grepping: "Grepping"
        case .waiting: "Waiting"
        case .working: "Running"
        case .patrol: "Patrol"
        case .duel: "Duel"
        case .trio: "Three"
        case .swarm: "Swarm"
        case .done: "Success"
        case .error: "Error"
        case .attention: "Attention"
        case .stopped: "Stopped"
        }
    }

    var detail: String {
        switch self {
        case .idle: "Blade off. One quiet session."
        case .thinking: "Thought orb."
        case .reading: "Violet hologram."
        case .writing: "Glowing glyph."
        case .searching: "Scan rings."
        case .grepping: "Matching fragments."
        case .waiting: "Meditation. Waiting on you."
        case .working: "Sprint, then slash an incoming error."
        case .patrol: "One session. Walking the beat."
        case .duel: "Two sessions. Two-droid counterattack."
        case .trio: "Three sessions. Three droids."
        case .swarm: "Four or more. Five-droid swarm."
        case .done: "Restrained blade flourish."
        case .error: "Deflect a red error bolt."
        case .attention: "Alert, blade ignited."
        case .stopped: "Composed, blade off."
        }
    }

    var defaultFrameCount: Int {
        switch self {
        case .idle, .done: 6
        case .waiting, .working: 8
        case .duel, .swarm: 10
        default: 1
        }
    }

    /// Frames the shipped Miles Windu strip carries for this pose. `frameInterval`
    /// is the per-frame rate authored against exactly these counts.
    var authoredFrameCount: Int {
        switch self {
        case .working, .duel, .swarm: 16
        case .trio: 12
        case .attention: 6
        default: 8
        }
    }

    /// Per-frame rate for a strip of `count` frames, holding the LOOP duration
    /// constant rather than the frame rate.
    ///
    /// `frameInterval` alone is the rate authored for Miles Windu's 16/12/16
    /// strips. Applied to a shorter strip it runs the whole loop proportionally
    /// faster: the three bundled Jedi ship four cells, so a duel authored to
    /// take 1.76s played in 0.44s — a 2.3 Hz strobe, not a fight. A strip at or
    /// above the authored count keeps its own rate, so Miles is untouched.
    func frameInterval(forFrames count: Int) -> Double {
        guard count > 0, count < authoredFrameCount else { return frameInterval }
        return frameInterval * Double(authoredFrameCount) / Double(count)
    }

    var frameInterval: Double {
        switch self {
        case .idle, .patrol, .stopped: 0.28
        case .waiting, .thinking, .reading, .writing: 0.18
        case .searching, .grepping: 0.14
        case .working: 0.10
        case .duel: 0.11
        case .trio: 0.22
        case .swarm: 0.22
        case .done: 0.16
        case .error, .attention: 0.14
        }
    }

    var animates: Bool {
        switch self {
        case .working, .duel, .trio, .swarm, .error, .attention: true
        default: false
        }
    }

    var cinematic: Bool {
        switch self {
        case .patrol, .duel, .trio, .swarm: true
        default: false
        }
    }

    /// Patrol reads as an action rather than a state, so it periodically breaks
    /// out of calm idle/meditation beats. Running and duel each carry one
    /// authored story strip and must play continuously in their declared order.
    var usesActivityPlaylist: Bool {
        switch self {
        case .patrol: true
        default: false
        }
    }

    /// `scale` is the CHARACTER dial only (PetCharacterScale). Buttons, text,
    /// bubbles, and the session list size off PetSize and never read this, so
    /// the figure can grow without the card growing with it.
    func spriteHeight(_ pixels: Int, scale: CGFloat = 1) -> CGFloat {
        // One authored character height across every lifecycle state. The old
        // cinematic 1.55x multiplier made a swarm visibly jump larger than a
        // solo run and forced the floating panel to resize with session count.
        (CGFloat(pixels) * scale).rounded()
    }

    func spriteWidth(_ pixels: Int, scale: CGFloat = 1) -> CGFloat {
        cinematic
            ? (spriteHeight(pixels, scale: scale) * 2.6).rounded()
            : (CGFloat(pixels) * scale).rounded()
    }

    /// ONE width for the panel and the rendered frame. The panel reserved a
    /// fixed 2.6 cinematic aspect while the view measured the real art, so the
    /// card claimed up to 2.7x the width the figure needed (installed cinematic
    /// cells measure 0.97:1) — which read as the card growing with the
    /// character — and a wider scene rendered past the panel and clipped.
    func renderSize(_ pixels: Int, scale: CGFloat = 1, aspect: CGFloat? = nil) -> CGSize {
        let height = spriteHeight(pixels, scale: scale)
        guard let aspect, aspect > 0 else {
            return CGSize(width: spriteWidth(pixels, scale: scale), height: height)
        }
        let lo: CGFloat = cinematic ? 0.75 : 0.6
        let hi: CGFloat = cinematic ? 3.6 : 1.4
        return CGSize(width: (height * min(max(aspect, lo), hi)).rounded(), height: height)
    }

    /// Preserve the requested character scale until it would exceed the active
    /// display. At that point only the figure is reduced; the user's saved dial
    /// remains unchanged and returns at full size on a roomier display.
    func fittedCharacterScale(
        _ requested: CGFloat,
        pixels: Int,
        aspect: CGFloat?,
        available: CGSize,
        reservedChrome: CGSize
    ) -> CGFloat {
        let baseHeight = CGFloat(pixels)
        let lo: CGFloat = cinematic ? 0.75 : 0.6
        let hi: CGFloat = cinematic ? 3.6 : 1.4
        let resolvedAspect = aspect.map { min(max($0, lo), hi) } ?? (cinematic ? 2.6 : 1)
        let baseWidth = baseHeight * resolvedAspect
        let usableWidth = max(CGFloat(pixels), available.width - reservedChrome.width)
        let usableHeight = max(CGFloat(pixels), available.height - reservedChrome.height)
        let widthFit = usableWidth / max(baseWidth, 1)
        let heightFit = usableHeight / max(baseHeight, 1)
        return max(PetCharacterScale.factor(PetCharacterScale.minPercent),
                   min(requested, widthFit, heightFit))
    }

    var fallbackPoses: [PetSpritePose] {
        switch self {
        case .patrol: [.idle]
        // These three used to cycle only among themselves, so a pack declaring
        // core states and no escalation art resolved trio and swarm to nothing
        // and painted the stock drawn figure. 0.5.130 made that reachable by
        // removing the previous pack's leftovers that had been covering for it.
        case .duel: [.swarm, .working, .idle]
        case .trio: [.swarm, .duel, .working, .idle]
        case .swarm: [.duel, .trio, .working, .idle]
        // Every chain has to terminate somewhere a MINIMAL pack actually
        // declares. error and attention used to point only at each other, so a
        // legacy pack carrying neither rendered nothing at all for both states
        // once the previous pack's leftovers stopped covering for it.
        case .error: [.attention, .working, .idle]
        case .attention: [.error, .waiting, .idle]
        case .done: [.idle]
        case .working, .waiting: [.idle]
        case .thinking, .reading, .writing: [.waiting, .idle]
        case .searching, .grepping: [.working, .waiting, .idle]
        case .stopped: [.idle, .done]
        default: []
        }
    }

    /// Error and attention beat the swarm so a jump miss still reads. Completing
    /// still flashes success. Sessions IN PLAY then escalate one droid →
    /// duel → three droids → five-droid swarm.
    /// `workingCount`/`waitingCount` have NO defaults on purpose: the fleet
    /// Bool this replaces flashed .done while three other sessions still ran,
    /// and a defaulted 0 would silently reproduce that at any call site that
    /// forgot to pass them.
    static func resolve(
        sessionCount: Int,
        workingCount: Int,
        waitingCount: Int,
        focusState: String?,
        completing: Bool,
        attention: Bool = false,
        errored: Bool = false
    ) -> PetSpritePose {
        if errored || focusState == "error" { return .error }
        if attention { return .attention }
        if completing && workingCount == 0 && waitingCount == 0 { return .done }
        // Waiting with NOTHING running is amber, not a fight. One waiting plus
        // three idle-alive must not render a swarm; one running + one waiting
        // still escalates through the count ladder below.
        if waitingCount > 0 && workingCount == 0 { return .waiting }
        // Escalation reads from sessions IN PLAY (working + waiting) — the
        // same units the ledger's colored segments count, so the droids on
        // screen can never disagree with the numbers under the figure. Total
        // alive count used to summon droids: three alive with ONE running
        // rendered a trio over a "1 RUNNING" caption (Miles, 2026-08-30).
        // Idle-alive sessions read as patrol instead.
        let active = workingCount + waitingCount
        if active >= 4 { return .swarm }
        if active == 3 { return .trio }
        if active == 2 { return .duel }
        // Exactly one in play here means one RUNNING — a lone waiting
        // session already returned amber above.
        if active == 1 { return .working }
        return sessionCount >= 1 ? .patrol : .idle
    }

    static func matching(fileName: String) -> PetSpritePose? {
        let name = fileName.lowercased()
        if name.contains("core-agent-states") || name.contains("multi-session-escalation") {
            return nil
        }
        let checks: [(PetSpritePose, [String])] = [
            (.working, ["lightsaber-run", "02-lightsaber"]),
            (.duel, ["droid-combat", "03-droid"]),
            (.idle, ["01-idle", "idle-strip", "-idle-"]),
            (.waiting, ["02-search", "search-strip", "-search-"]),
            (.working, ["03-grep", "grep-strip", "inspect-strip", "-grep-"]),
            (.swarm, ["04-combat", "combat-strip", "fight-strip", "-combat-"]),
            (.done, ["05-success", "success-strip", "complete-strip", "-success-", "-done-"]),
        ]
        for (pose, keys) in checks {
            if keys.contains(where: { name.contains($0) }) { return pose }
        }
        return nil
    }

    static let coreStateCells: [(pose: PetSpritePose, index: Int)] = [
        (.idle, 0), (.thinking, 1), (.reading, 2), (.writing, 3),
        (.searching, 4), (.grepping, 5), (.working, 6), (.waiting, 7),
        (.done, 8), (.error, 9), (.attention, 10), (.stopped, 11),
    ]

    static let escalationCells: [(pose: PetSpritePose, index: Int)] = [
        (.patrol, 0), (.duel, 1), (.trio, 2), (.swarm, 3),
    ]
}

struct PetSpriteKit {
    var fallback: NSImage?
    var poses: [PetSpritePose: [NSImage]] = [:]
    var cinematic: [NSImage] = []

    /// The escalation strip is a ladder: patrol, duel, trio, swarm. Playing all
    /// of it for BOTH trio and swarm made three sessions and five look
    /// identical and showed the lone patrol scene while three were running.
    /// Each level plays the ladder up to its own rung, so the pet never depicts
    /// more sessions than are live.
    func frames(for pose: PetSpritePose) -> [NSImage] {
        // A direct animated fight strip is more specific than the four-rung
        // cinematic fallback. This lets an installed V3 pack animate trio and
        // swarm without a stale bundled ladder shadowing those strips, while a
        // one-frame pose still climbs the cinematic sequence as before.
        if [.duel, .trio, .swarm].contains(pose),
           let fight = poses[pose], fight.count > 1 {
            return fight
        }
        if pose == .trio, cinematic.count >= 3 { return Array(cinematic.prefix(3)) }
        if pose == .swarm, cinematic.count > 1 { return cinematic }
        if let frames = poses[pose], !frames.isEmpty { return frames }
        for fallback in pose.fallbackPoses {
            if let frames = poses[fallback], !frames.isEmpty { return frames }
        }
        if let fallback { return [fallback] }
        return []
    }

    /// Story/ambient composition may only borrow art that the pack explicitly
    /// declares for that pose. Falling through the live-state fallback chain can
    /// turn a missing meditation into a signal animation or a two-session scene
    /// into three/four-session art.
    func exactFrames(for pose: PetSpritePose) -> [NSImage] {
        poses[pose] ?? []
    }

    /// Widest aspect among the supplied frames. A missing pose resolves to the
    /// square COS-figure fallback, so the child renderer and its parent reserve
    /// the same envelope even while a pack is incomplete or being replaced.
    static func resolvedAspect(frames: [NSImage]) -> CGFloat {
        let playing = frames.filter { $0.size.height > 1 }
        guard !playing.isEmpty else { return 1 }
        return playing.map { $0.size.width / $0.size.height }.max() ?? 1
    }

    func resolvedAspect(for pose: PetSpritePose) -> CGFloat {
        Self.resolvedAspect(frames: frames(for: pose))
    }

    func aspect(for pose: PetSpritePose) -> CGFloat? {
        let playing = frames(for: pose)
        return playing.isEmpty ? nil : resolvedAspect(for: pose)
    }

    /// The full lifecycle ENVELOPE: max render size over every live state.
    /// This is what scale fitting and width stability are computed against.
    /// The PANEL mounts the pose-aware `viewportSize(current:...)` overload —
    /// stable width from this envelope, height tracking the current pose so
    /// the ledger and reveals hug the figure instead of the tallest pose's
    /// headroom. The figure itself never moves: bottom-aligned in a
    /// bottom-anchored panel.
    func viewportSize(
        pixels: Int,
        scale: CGFloat,
        poseScales: [PetSpritePose: CGFloat] = [:]
    ) -> CGSize {
        let sizes = PetSpritePose.liveCases.map { pose in
            pose.renderSize(
                pixels,
                scale: scale * max(poseScales[pose] ?? 1, 0.01),
                aspect: resolvedAspect(for: pose)
            )
        }
        return CGSize(
            width: sizes.map(\.width).max() ?? CGFloat(pixels),
            height: sizes.map(\.height).max() ?? CGFloat(pixels)
        )
    }

    /// The panel's viewport for what is on screen RIGHT NOW: the stable
    /// max-pose WIDTH (a poll must never re-center the pet) with the CURRENT
    /// pose's height. Height reserved for the tallest pose put ~2 idle-units
    /// of invisible slack above every 1x combat figure once idle went 3x, and
    /// the 0.5.142 ledger rendered at the top of that slack — a bar floating
    /// ~700px above the character (Miles, 2026-08-30). The figure is
    /// bottom-aligned and the panel bottom-anchored, so tracking the current
    /// pose height moves only the above-figure chrome, never the figure.
    func viewportSize(
        current pose: PetSpritePose,
        pixels: Int,
        scale: CGFloat,
        poseScales: [PetSpritePose: CGFloat] = [:]
    ) -> CGSize {
        let envelope = viewportSize(pixels: pixels, scale: scale, poseScales: poseScales)
        let current = pose.renderSize(
            pixels,
            scale: scale * max(poseScales[pose] ?? 1, 0.01),
            aspect: resolvedAspect(for: pose)
        )
        return CGSize(width: envelope.width, height: min(current.height, envelope.height))
    }

    /// Fit the whole lifecycle envelope, not only the pose visible during this
    /// poll. Otherwise the scale changes at the same moment as the artwork.
    func fittedViewportScale(
        _ requested: CGFloat,
        pixels: Int,
        available: CGSize,
        reservedChrome: CGSize,
        poseScales: [PetSpritePose: CGFloat] = [:]
    ) -> CGFloat {
        PetSpritePose.liveCases.map { pose in
            let poseScale = max(poseScales[pose] ?? 1, 0.01)
            return pose.fittedCharacterScale(
                requested * poseScale,
                pixels: pixels,
                aspect: resolvedAspect(for: pose),
                available: available,
                reservedChrome: reservedChrome
            ) / poseScale
        }.min() ?? requested
    }

    var hasAnyCustom: Bool {
        fallback != nil || !cinematic.isEmpty || poses.contains { !$0.value.isEmpty }
    }

    func preview(for pose: PetSpritePose) -> NSImage? {
        poses[pose]?.first
    }
}

enum PetSpriteStrip {
    static let maxHeight = 256
    static let minFrames = 1
    // Longer authored stories need their exact count for cell slicing. Keep a
    // bounded import limit without silently truncating the 17/23-frame stories.
    static let maxFrames = 32

    static func clampFrames(_ value: Int) -> Int {
        min(max(value, minFrames), maxFrames)
    }

    static func raster(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            return cg
        }
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let cg = rep.cgImage {
            return cg
        }
        return nil
    }

    static func slice(_ image: NSImage, frames: Int) -> [NSImage] {
        let count = clampFrames(frames)
        guard let cg = raster(image) else { return [image] }
        if count <= 1 {
            return [NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))]
        }
        let frameWidth = max(1, cg.width / count)
        var out: [NSImage] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            let rect = CGRect(x: index * frameWidth, y: 0, width: frameWidth, height: cg.height)
            guard let cropped = cg.cropping(to: rect) else { continue }
            out.append(NSImage(cgImage: cropped, size: NSSize(width: frameWidth, height: cg.height)))
        }
        return out.isEmpty ? [image] : out
    }

    static func sliceGrid(_ image: NSImage, columns: Int, rows: Int) -> [NSImage] {
        let cols = max(1, columns)
        let rowCount = max(1, rows)
        guard let cg = raster(image) else { return [image] }
        let cellWidth = max(1, cg.width / cols)
        let cellHeight = max(1, cg.height / rowCount)
        var out: [NSImage] = []
        out.reserveCapacity(cols * rowCount)
        for row in 0..<rowCount {
            for col in 0..<cols {
                let rect = CGRect(x: col * cellWidth, y: row * cellHeight, width: cellWidth, height: cellHeight)
                guard let cropped = cg.cropping(to: rect) else { continue }
                out.append(NSImage(cgImage: cropped, size: NSSize(width: cellWidth, height: cellHeight)))
            }
        }
        return out.isEmpty ? [image] : out
    }

    /// Escalation boards pack scenes of different widths — equal columns cut
    /// droids in half. Scenes are ink islands found at a low column threshold.
    /// A detached blaster bolt or debris cloud sits a SMALL gap from its scene
    /// while scene gutters are wide, so narrow gaps merge before cutting, and a
    /// speck island attaches to its nearest neighbor. `count` is a hint: with
    /// `forceCount` (cell boards whose manifest names each scene) islands merge
    /// down to exactly `count` or the equal grid applies; otherwise the natural
    /// scene count wins.
    static func sliceRowByIslands(_ image: NSImage, count: Int, forceCount: Bool = false) -> [NSImage] {
        let hint = max(1, count)
        guard let buffer = PetSpriteAlpha.rgbaBuffer(image),
              let cg = raster(image) else {
            return sliceGrid(image, columns: hint, rows: 1)
        }
        var opaqueCol = [Double](repeating: 0, count: buffer.width)
        for x in 0..<buffer.width {
            var hits = 0
            for y in 0..<buffer.height {
                let byte = (y * buffer.width + x) * 4
                if PetSpriteAlpha.isSpriteInk(buffer.pixels, at: byte) { hits += 1 }
            }
            opaqueCol[x] = Double(hits) / Double(max(buffer.height, 1))
        }
        var islands: [(x: Int, w: Int)] = []
        var i = 0
        while i < buffer.width {
            while i < buffer.width && opaqueCol[i] <= 0.015 { i += 1 }
            guard i < buffer.width else { break }
            let start = i
            while i < buffer.width && opaqueCol[i] > 0.015 { i += 1 }
            islands.append((start, i - start))
        }
        // Intra-scene gaps (a bolt or debris beside its figure) and scene
        // gutters form two clusters, and their sizes vary per board — a fixed
        // divisor swallowed six fight scenes into one cell. Take the threshold
        // from the data: the largest relative jump in the sorted gap sizes,
        // clamped to scale; fixed width/64 when the gaps have no structure.
        var gaps: [Int] = []
        for j in 1..<max(1, islands.count) {
            gaps.append(islands[j].x - (islands[j - 1].x + islands[j - 1].w))
        }
        let distinct = Array(Set(gaps.filter { $0 >= 2 })).sorted()
        var gutter = max(2, buffer.width / 64)
        if distinct.count >= 2 {
            var bestRatio = 0.0
            var bestMid = gutter
            for j in 1..<distinct.count {
                let ratio = Double(distinct[j]) / Double(max(distinct[j - 1], 1))
                if ratio > bestRatio {
                    bestRatio = ratio
                    bestMid = (distinct[j - 1] + distinct[j]) / 2
                }
            }
            if bestRatio >= 1.8 {
                gutter = min(max(bestMid, max(2, buffer.width / 200)), max(2, buffer.width / 32))
            }
        }
        var scenes: [(x: Int, w: Int)] = []
        for island in islands {
            if let last = scenes.last, island.x - (last.x + last.w) < gutter {
                scenes[scenes.count - 1] = (last.x, island.x + island.w - last.x)
            } else {
                scenes.append(island)
            }
        }
        let speck = max(2, buffer.width / 200)
        func mergePair(at index: Int) {
            let a = scenes[index - 1]
            let b = scenes[index]
            scenes[index - 1] = (a.x, b.x + b.w - a.x)
            scenes.remove(at: index)
        }
        while scenes.count > 1, let speckIndex = scenes.firstIndex(where: { $0.w < speck }) {
            if speckIndex == 0 {
                mergePair(at: 1)
            } else if speckIndex == scenes.count - 1 {
                mergePair(at: speckIndex)
            } else {
                let leftGap = scenes[speckIndex].x - (scenes[speckIndex - 1].x + scenes[speckIndex - 1].w)
                let rightGap = scenes[speckIndex + 1].x - (scenes[speckIndex].x + scenes[speckIndex].w)
                mergePair(at: leftGap <= rightGap ? speckIndex : speckIndex + 1)
            }
        }
        func mergeClosestPair() {
            guard scenes.count > 1 else { return }
            var best = 1
            var bestGap = Int.max
            for j in 1..<scenes.count {
                let gap = scenes[j].x - (scenes[j - 1].x + scenes[j - 1].w)
                if gap < bestGap {
                    bestGap = gap
                    best = j
                }
            }
            mergePair(at: best)
        }
        let cap = forceCount ? hint : maxFrames
        while scenes.count > cap { mergeClosestPair() }
        if forceCount && scenes.count != hint {
            return sliceGrid(image, columns: hint, rows: 1)
        }
        guard scenes.count > 1 else {
            // One island with a multi-frame hint is a tight-packed uniform sheet
            // (frames touch, no gutters) — the classic strip format. Gutters win
            // when they exist; the hint wins when they do not.
            return hint > 1
                ? sliceGrid(image, columns: hint, rows: 1)
                : [NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))]
        }
        var out: [NSImage] = []
        out.reserveCapacity(scenes.count)
        for (idx, island) in scenes.enumerated() {
            let left = idx == 0 ? 0 : (scenes[idx - 1].x + scenes[idx - 1].w + island.x) / 2
            let right = idx == scenes.count - 1 ? buffer.width : (island.x + island.w + scenes[idx + 1].x) / 2
            let rect = CGRect(x: left, y: 0, width: max(1, right - left), height: cg.height)
            guard let cropped = cg.cropping(to: rect) else { continue }
            out.append(NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height)))
        }
        return out.count > 1 ? out : sliceGrid(image, columns: hint, rows: 1)
    }

    static func fitHeight(_ image: NSImage, maxHeight: Int = maxHeight) -> NSImage {
        guard let cg = raster(image), cg.height > maxHeight else { return image }
        let scale = CGFloat(maxHeight) / CGFloat(cg.height)
        let width = max(1, Int((CGFloat(cg.width) * scale).rounded()))
        guard let buffer = PetSpriteAlpha.rgbaBuffer(image, width: width, height: maxHeight) else {
            return image
        }
        return PetSpriteAlpha.image(from: buffer)
    }

    /// Drop the empty board cell around the figure so Large is the character, not padding.
    static func cropOpaque(_ image: NSImage, paddingRatio: CGFloat = 0.24) -> NSImage {
        guard let buffer = PetSpriteAlpha.rgbaBuffer(image),
              let cg = raster(image) else { return image }
        var minX = buffer.width
        var minY = buffer.height
        var maxX = 0
        var maxY = 0
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                if !PetSpriteAlpha.isSpriteInk(buffer.pixels, at: (y * buffer.width + x) * 4) { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard minX <= maxX, minY <= maxY else { return image }
        let span = max(maxX - minX + 1, maxY - minY + 1)
        let pad = max(12, Int((CGFloat(span) * paddingRatio).rounded()))
        let padX = max(pad, Int((Double(pad) * 1.6).rounded()))
        let x = max(0, minX - padX)
        let y = max(0, minY - pad)
        let maxX2 = min(buffer.width - 1, maxX + padX)
        let maxY2 = min(buffer.height - 1, maxY + pad)
        let rect = CGRect(x: x, y: y, width: maxX2 - x + 1, height: maxY2 - y + 1)
        if rect.width >= CGFloat(cg.width) && rect.height >= CGFloat(cg.height) { return image }
        guard let cropped = cg.cropping(to: rect) else { return image }
        return NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height))
    }

    /// A strip's manifest declares its frame count — that is artistic intent,
    /// not a hint. Cuts start at the equal-grid positions and nudge to the
    /// emptiest nearby column WITHIN cell/6, so a figure is not bisected when a
    /// valley exists that close to the authored cut; a boundary with no valley
    /// in reach keeps the equal cut and may still split a figure. Continuous
    /// art degrades to a plain equal slice. Measured on
    /// the Windu combat board: the fight scenes connect through 2px bolt
    /// bridges, so zero-gap island logic cannot separate them, but each scene
    /// boundary is still the local ink minimum.
    static func sliceStripByValleys(_ image: NSImage, frames: Int) -> [NSImage] {
        let count = clampFrames(frames)
        guard count > 1,
              let buffer = PetSpriteAlpha.rgbaBuffer(image),
              let cg = raster(image) else {
            return slice(image, frames: count)
        }
        var opaqueCol = [Double](repeating: 0, count: buffer.width)
        for x in 0..<buffer.width {
            var hits = 0
            for y in 0..<buffer.height {
                let byte = (y * buffer.width + x) * 4
                if PetSpriteAlpha.isSpriteInk(buffer.pixels, at: byte) { hits += 1 }
            }
            opaqueCol[x] = Double(hits) / Double(max(buffer.height, 1))
        }
        let cell = Double(buffer.width) / Double(count)
        // A cut may only MOVE to a column that is genuinely empty. Searching a
        // third of a cell for the "emptiest" column let cuts wander deep into
        // the figure whenever a strip has no real gaps: the meditation board
        // was sliced through the character in all eight frames, one of them on
        // both sides at 206px against a 271px cell, which clipped his crossed
        // leg. Evenly drawn art is better served by the equal cut it was
        // authored on, so an ambiguous boundary stays put.
        // Keep the search near the authored grid. A wider sweep was measured
        // worse: it finds columns that clear the ink threshold inside a dim
        // aura edge and still clip the figure (a 200px frame against a 271px
        // cell). The threshold is deliberately strict — a cut only moves to a
        // column that is essentially clean.
        let window = max(2, Int(cell / 6))
        // Absolute rows, not a fraction. opaqueCol is hits/height on the RAW
        // source, so a fixed fraction means different things per pack: 0.005 is
        // one stray pixel on a 256-tall board and ten rows of real ink on a
        // 2000-tall one, and it disabled the valley search entirely on short art.
        let emptyEnough = Double(max(1, buffer.height / 400)) / Double(max(buffer.height, 1))
        var cuts: [Int] = [0]
        for k in 1..<count {
            let center = Int((Double(k) * cell).rounded())
            let lo = max((cuts.last ?? 0) + 1, center - window)
            let hi = min(buffer.width - (count - k), center + window)
            let fallback = min(max(center, (cuts.last ?? 0) + 1), buffer.width - 1)
            guard lo <= hi else {
                cuts.append(fallback)
                continue
            }
            var best = center
            var bestInk = Double.greatestFiniteMagnitude
            for x in lo...hi {
                let ink = opaqueCol[x]
                if ink + 1e-9 < bestInk
                    || (abs(ink - bestInk) <= 1e-9 && abs(x - center) < abs(best - center)) {
                    bestInk = ink
                    best = x
                }
            }
            // No valley here — do not carve one out of the subject.
            // `best` is the argmin over a window that contains `center`, so it
            // is never worse than the grid column — rejecting it outright threw
            // away a strictly cleaner cut and put the blade back through the
            // figure on unevenly spaced art. Move when the column is empty, or
            // when it is clearly better than the grid column.
            let centerInk = opaqueCol[min(max(fallback, 0), buffer.width - 1)]
            let clearlyBetter = bestInk < centerInk * 0.5
            cuts.append(bestInk <= emptyEnough || clearlyBetter ? best : fallback)
        }
        cuts.append(buffer.width)
        var out: [NSImage] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let rect = CGRect(x: cuts[i], y: 0, width: max(1, cuts[i + 1] - cuts[i]), height: cg.height)
            guard let cropped = cg.cropping(to: rect) else { continue }
            out.append(NSImage(cgImage: cropped, size: NSSize(width: rect.width, height: rect.height)))
        }
        return out.count == count ? out : slice(image, frames: count)
    }

    /// A cut that lands inside a figure leaves a truncated sliver of the
    /// NEIGHBOUR frame at this frame's edge; it flickers during playback and
    /// breaks the animation. Signature: a connected component, not the frame's
    /// largest, that meets the edge band (first or last two columns). Size and
    /// row span are NOT consulted — a small fragment cut by the boundary goes
    /// too, because being cut is the signal. The primary stays even when it
    /// reaches the edge: it is the subject.
    static func suppressTruncatedEdgeSlivers(_ image: NSImage) -> NSImage {
        guard var buffer = PetSpriteAlpha.rgbaBuffer(image) else { return image }
        let width = buffer.width
        let height = buffer.height
        // 2D connected components (4-neighbor, same pattern as the paper
        // knockout): a fragment can overlap the figure's column span, which a
        // column projection cannot see — it hid three run-cycle slivers.
        var label = [Int](repeating: 0, count: width * height)
        var areas: [Int] = [0]
        var touchesEdge: [Bool] = [false]
        var next = 1
        var queue: [Int] = []
        for start in 0..<(width * height) {
            guard label[start] == 0, PetSpriteAlpha.isSpriteInk(buffer.pixels, at: start * 4) else { continue }
            label[start] = next
            areas.append(0)
            touchesEdge.append(false)
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var head = 0
            while head < queue.count {
                let index = queue[head]
                head += 1
                areas[next] += 1
                let x = index % width
                if x <= 1 || x >= width - 2 { touchesEdge[next] = true }
                let y = index / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let nIndex = ny * width + nx
                    guard label[nIndex] == 0, PetSpriteAlpha.isSpriteInk(buffer.pixels, at: nIndex * 4) else { continue }
                    label[nIndex] = next
                    queue.append(nIndex)
                }
            }
            next += 1
        }
        guard next > 2, let largest = areas.max(), largest > 0,
              let primary = (1..<next).max(by: { areas[$0] < areas[$1] }) else { return image }
        // Neither area nor cut-face height is the discriminator — being CUT is.
        // This runs on the raw slice, where the frame boundary IS the cut line,
        // so anything reaching it continues into the neighbouring scene: a
        // bisected figure, or a fragment of one. The combat board leaves a
        // 540px blaster bolt from the next scene against the left edge — 5% of
        // the figure and a few rows tall, which an area rule and a cut-face
        // rule both kept, and which reads as a flash in the corner. Art
        // composed inside the frame never abuts the boundary, because
        // cropOpaque pads afterwards. The primary is exempt: it is the subject.
        var erase = [Bool](repeating: false, count: next)
        var cleared = false
        for id in 1..<next where id != primary && touchesEdge[id] {
            erase[id] = true
            cleared = true
        }
        guard cleared else { return image }
        for index in 0..<(width * height) where label[index] > 0 && erase[label[index]] {
            let byte = index * 4
            buffer.pixels[byte] = 0
            buffer.pixels[byte + 1] = 0
            buffer.pixels[byte + 2] = 0
            buffer.pixels[byte + 3] = 0
        }
        return PetSpriteAlpha.image(from: buffer)
    }

    /// Share of a frame's ink that carries saturated colour. Measured on the
    /// Windu combat strip: the hero's violet tunic, gold armour, and blade run
    /// 0.21-0.43; the droid-only scenes, which are grey metal with red eyes,
    /// run 0.012-0.10. The metric is the strip's own palette, not a named hue,
    /// so a monochrome pack scores uniformly and nothing is dropped.
    static func chromaFraction(_ image: NSImage) -> Double {
        guard let buffer = PetSpriteAlpha.rgbaBuffer(image) else { return 0 }
        var ink = 0
        var chroma = 0
        for index in 0..<(buffer.width * buffer.height) {
            let byte = index * 4
            guard buffer.pixels[byte + 3] > 89 else { continue }
            ink += 1
            let r = Int(buffer.pixels[byte])
            let g = Int(buffer.pixels[byte + 1])
            let b = Int(buffer.pixels[byte + 2])
            let maxc = max(r, g, b)
            let minc = min(r, g, b)
            guard maxc > 38 else { continue }
            if Double(maxc - minc) / Double(maxc) > 0.25 { chroma += 1 }
        }
        return ink > 0 ? Double(chroma) / Double(ink) : 0
    }

    /// A story strip contains scenes the pet's subject is absent from — in the
    /// combat board, three of ten are the droid alone. Looped at 0.11s they
    /// read as the character blinking out of existence. Drop frames whose
    /// colour content falls far below the strip's median (a relative test, so
    /// a uniformly monochrome pack keeps every frame). Never drops more than
    /// half, and never below two frames.
    static func dropSubjectlessFrames(_ frames: [NSImage]) -> [NSImage] {
        guard frames.count >= 3 else { return frames }
        let scores = frames.map { chromaFraction($0) }
        let sorted = scores.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
        guard median > 0 else { return frames }
        // Take the cut from the data, not a fixed fraction: the combat strip
        // separates into three groups (bare droid 0.012-0.016, droid holding
        // the blade 0.10, hero 0.21+), and a fraction-of-median cut lands in
        // whichever gap it happens to hit. Use the HIGHEST decisive gap below
        // the median, so every subjectless scene falls below it. A strip with
        // no decisive gap — a real run cycle, whose frames vary by at most
        // 1.07x — keeps every frame. Measured boundary here: 1.79x.
        var cut = 0.0
        for j in 1..<sorted.count where sorted[j] <= median {
            if sorted[j] / max(sorted[j - 1], 0.0001) >= 1.7 {
                cut = (sorted[j - 1] + sorted[j]) / 2
            }
        }
        guard cut > 0 else { return frames }
        let kept = zip(frames, scores).filter { $0.1 >= cut }.map(\.0)
        guard kept.count >= 2, kept.count >= frames.count - frames.count / 2 else { return frames }
        return kept
    }

    /// Ink bounds of a frame, or nil when it holds no ink.
    static func inkBounds(_ image: NSImage) -> (x: Int, y: Int, w: Int, h: Int)? {
        guard let buffer = PetSpriteAlpha.rgbaBuffer(image) else { return nil }
        var minX = buffer.width, minY = buffer.height, maxX = -1, maxY = -1
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                guard PetSpriteAlpha.isSpriteInk(buffer.pixels, at: (y * buffer.width + x) * 4) else { continue }
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    /// Cropping and height-fitting each frame INDEPENDENTLY re-scales every
    /// pose to fill the same box, so the character changes size between frames
    /// of one animation. Measured on the V3 running strip: the figure rendered
    /// at 54% of frame height in one frame and 62% in another — a 15% jump,
    /// which reads as the character growing and shrinking as it runs.
    ///
    /// Normalise the STRIP instead: one canvas, one scale, ink bottoms on a
    /// shared baseline. Authored size differences survive (a crouch stays
    /// shorter than a stand) and the figure does not bob.
    static func normalizeStrip(_ frames: [NSImage], paddingRatio: CGFloat = 0.12) -> [NSImage] {
        guard frames.count > 1 else { return frames }
        var boxes: [(x: Int, y: Int, w: Int, h: Int)] = []
        var rasters: [CGImage] = []
        for frame in frames {
            guard let box = inkBounds(frame), let cg = raster(frame) else { return frames }
            boxes.append(box)
            rasters.append(cg)
        }
        let unionW = boxes.map(\.w).max() ?? 1
        let unionH = boxes.map(\.h).max() ?? 1
        // Per-axis. Driving both from max(w,h) let one wide effect frame inflate
        // VERTICAL padding for every frame, widening the canvas aspect and
        // shrinking the figure at render — the "runner tiny" failure again.
        let padX = max(8, Int((CGFloat(unionW) * paddingRatio).rounded()))
        let pad = max(8, Int((CGFloat(unionH) * paddingRatio).rounded()))
        let canvasW = unionW + padX * 2
        // The canvas is the strip's own union ink. Sizing it from the source
        // cell instead was measured worse: the art is not drawn at one scale
        // across strips — the runner occupies 25% of its cell where idle
        // occupies 70% — so source-relative canvases rendered the runner tiny.
        // No scaling happens HERE; prepare's fitHeight applies one factor to
        // this shared canvas, which is what keeps a strip internally consistent.
        let canvasH = unionH + pad * 2
        var out: [NSImage] = []
        out.reserveCapacity(frames.count)
        for (index, cg) in rasters.enumerated() {
            let box = boxes[index]
            guard let ink = cg.cropping(to: CGRect(x: box.x, y: box.y, width: box.w, height: box.h)),
                  let ctx = CGContext(
                    data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8,
                    bytesPerRow: canvasW * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return frames }
            ctx.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
            // Horizontally centred; ink BOTTOM on a shared baseline. A CGContext
            // is bottom-up, so the baseline sits `pad` above its origin.
            ctx.draw(ink, in: CGRect(x: (canvasW - box.w) / 2, y: pad, width: box.w, height: box.h))
            guard let made = ctx.makeImage() else { return frames }
            out.append(NSImage(cgImage: made, size: NSSize(width: canvasW, height: canvasH)))
        }
        return out
    }

    /// Returns the prepared image AND the frame count that was stitched, so
    /// playback slices exactly what exists.
    static func prepare(_ image: NSImage, frames: Int = 1) -> (image: NSImage, frames: Int) {
        let count = clampFrames(frames)
        if count <= 1 {
            return (fitHeight(cropOpaque(image)), 1)
        }
        let parts = dropSubjectlessFrames(sliceStripByValleys(image, frames: count))
        let cleaned = parts.map { suppressTruncatedEdgeSlivers($0) }
        // One scale and one baseline for the whole strip. Per-frame
        // cropOpaque + fitHeight here is what changed the character's size
        // between frames of the same animation.
        let prepared = normalizeStrip(cleaned).map { fitHeight($0) }
        guard let stitched = stitch(prepared) else { return (image, 1) }
        return (stitched, clampFrames(prepared.count))
    }

    static func stitch(_ frames: [NSImage]) -> NSImage? {
        let reps = frames.compactMap { image -> NSBitmapImageRep? in
            guard let tiff = image.tiffRepresentation else { return nil }
            return NSBitmapImageRep(data: tiff)
        }
        guard !reps.isEmpty else { return nil }
        let height = reps.map(\.pixelsHigh).max() ?? 1
        let cellWidth = max(1, reps.map(\.pixelsWide).max() ?? 1)
        let width = cellWidth * reps.count
        guard let dest = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ) else { return nil }
        for y in 0..<height {
            for x in 0..<width {
                dest.setColor(NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 0), atX: x, y: y)
            }
        }
        for (index, rep) in reps.enumerated() {
            let dx = index * cellWidth + (cellWidth - rep.pixelsWide) / 2
            let dy = (height - rep.pixelsHigh) / 2
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    let color = rep.colorAt(x: x, y: y) ?? NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 0)
                    dest.setColor(color, atX: dx + x, y: dy + y)
                }
            }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(dest)
        return image
    }
}

enum PetSpriteAlpha {
    static func needsPaperKnockout(_ image: NSImage) -> Bool {
        guard let buffer = rgbaBuffer(image) else { return false }
        let width = buffer.width
        let height = buffer.height
        let sample = min(16, width, height)
        guard sample > 0 else { return false }
        var transparent = 0
        var total = 0
        for origin in [(0, 0), (width - sample, 0), (0, height - sample), (width - sample, height - sample)] {
            for y in origin.1..<(origin.1 + sample) {
                for x in origin.0..<(origin.0 + sample) {
                    total += 1
                    if buffer.pixels[(y * width + x) * 4 + 3] < 16 { transparent += 1 }
                }
            }
        }
        if total == 0 { return false }
        if Double(transparent) / Double(total) >= 0.45 { return false }
        return isPaper(buffer.pixels, at: 0)
    }

    static func knockOutEdgePaper(_ image: NSImage) -> NSImage {
        guard var buffer = rgbaBuffer(image) else { return image }
        let width = buffer.width
        let height = buffer.height
        var seen = [UInt8](repeating: 0, count: width * height)
        var queue: [Int] = []
        func enqueue(_ x: Int, _ y: Int) {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            let index = y * width + x
            if seen[index] == 1 { return }
            if !isPaper(buffer.pixels, at: index * 4) { return }
            seen[index] = 1
            queue.append(index)
        }
        for x in 0..<width {
            enqueue(x, 0)
            enqueue(x, height - 1)
        }
        for y in 0..<height {
            enqueue(0, y)
            enqueue(width - 1, y)
        }
        var head = 0
        while head < queue.count {
            let index = queue[head]
            head += 1
            let x = index % width
            let y = index / width
            let byte = index * 4
            buffer.pixels[byte] = 0
            buffer.pixels[byte + 1] = 0
            buffer.pixels[byte + 2] = 0
            buffer.pixels[byte + 3] = 0
            enqueue(x - 1, y)
            enqueue(x + 1, y)
            enqueue(x, y - 1)
            enqueue(x, y + 1)
        }
        return PetSpriteAlpha.image(from: buffer)
    }

    fileprivate struct RGBABuffer {
        var pixels: [UInt8]
        var width: Int
        var height: Int
    }

    fileprivate static func isSpriteInk(_ pixels: [UInt8], at byte: Int) -> Bool {
        guard byte + 3 < pixels.count else { return false }
        let r = pixels[byte]
        let g = pixels[byte + 1]
        let b = pixels[byte + 2]
        let a = pixels[byte + 3]
        if a < 24 { return false }
        if isPaper(pixels, at: byte) { return false }
        if r < 14 && g < 14 && b < 14 && a < 48 { return false }
        return true
    }

    private static func isPaper(_ pixels: [UInt8], at byte: Int) -> Bool {
        guard byte + 3 < pixels.count else { return false }
        let r = pixels[byte]
        let g = pixels[byte + 1]
        let b = pixels[byte + 2]
        let a = pixels[byte + 3]
        if a < 16 { return true }
        let maxc = max(r, g, b)
        let minc = min(r, g, b)
        if (maxc - minc) > 22 { return false }
        return maxc >= 160
    }

    fileprivate static func rgbaBuffer(
        _ image: NSImage,
        width targetWidth: Int? = nil,
        height targetHeight: Int? = nil
    ) -> RGBABuffer? {
        guard let cg = PetSpriteStrip.raster(image) else { return nil }
        let width = targetWidth ?? cg.width
        let height = targetHeight ?? cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            // A bitmap-context draw plus a CGImage built from the same buffer is
            // orientation-TRUE: memory row 0 is the top scanline on both sides.
            // The old flip transform here inverted every round trip, so whether a
            // sprite rendered upright depended on how many buffer passes its path
            // made (and cropOpaque measured a mirrored bbox). Never re-add a flip
            // without an executable orientation probe proving it is needed.
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return RGBABuffer(pixels: pixels, width: width, height: height)
    }

    fileprivate static func image(from buffer: RGBABuffer) -> NSImage {
        let data = Data(buffer.pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(
                width: buffer.width,
                height: buffer.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: buffer.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else {
            return NSImage(size: NSSize(width: buffer.width, height: buffer.height))
        }
        return NSImage(cgImage: cg, size: NSSize(width: buffer.width, height: buffer.height))
    }
}

enum PetSpritePack {
    struct Item {
        var pose: PetSpritePose?
        var url: URL
        var frames: Int
        var columns: Int = 0
        var rows: Int = 0
        var cells: [(pose: PetSpritePose, index: Int)] = []

        var isGrid: Bool { !cells.isEmpty }
    }

    enum LoadError: LocalizedError {
        case empty

        var errorDescription: String? {
            switch self {
            case .empty:
                return "That folder has no sprite strips or state boards."
            }
        }
    }

    static func load(from root: URL, fileManager: FileManager = .default) throws -> [Item] {
        let directory = resolvedDirectory(root)
        if let manifest = loadManifest(in: directory, fileManager: fileManager), !manifest.isEmpty {
            return manifest
        }
        let scanned = scanFiles(in: directory, fileManager: fileManager)
        if scanned.isEmpty { throw LoadError.empty }
        return scanned
    }

    static func resolvedDirectory(_ root: URL) -> URL {
        if root.lastPathComponent.lowercased() == "manifest.json" {
            return root.deletingLastPathComponent()
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return root.deletingLastPathComponent()
        }
        return root
    }

    static func scanFiles(in directory: URL, fileManager: FileManager = .default) -> [Item] {
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var boards: [Item] = []
        var best: [PetSpritePose: (url: URL, score: Int)] = [:]
        for url in urls where PetSpriteStore.isAllowedImage(url) {
            if let board = recognizedBoard(url) {
                boards.append(board)
                continue
            }
            guard let pose = PetSpritePose.matching(fileName: url.lastPathComponent) else { continue }
            let name = url.lastPathComponent.lowercased()
            let score = name.contains("alpha") ? 2 : 1
            if let current = best[pose], current.score >= score { continue }
            best[pose] = (url, score)
        }
        let strips = PetSpritePose.allCases.compactMap { pose -> Item? in
            guard let hit = best[pose] else { return nil }
            return Item(pose: pose, url: hit.url, frames: pose.defaultFrameCount)
        }
        return boards + strips
    }

    static func recognizedBoard(_ url: URL) -> Item? {
        let name = url.lastPathComponent.lowercased()
        if name.contains("core-agent-states") {
            return Item(
                pose: nil,
                url: url,
                frames: 1,
                columns: 6,
                rows: 2,
                cells: PetSpritePose.coreStateCells
            )
        }
        if name.contains("multi-session-escalation") {
            return Item(
                pose: nil,
                url: url,
                frames: 1,
                columns: 4,
                rows: 1,
                cells: PetSpritePose.escalationCells
            )
        }
        return nil
    }

    private static func loadManifest(in directory: URL, fileManager: FileManager) -> [Item]? {
        let url = directory.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let boards = json["boards"] as? [[String: Any]], !boards.isEmpty {
            let items = boards.compactMap { board -> Item? in
                let file = (board["file"] as? String) ?? ""
                guard !file.isEmpty else { return nil }
                let candidate = directory.appendingPathComponent(file)
                guard fileManager.fileExists(atPath: candidate.path) else { return nil }
                if let cellList = board["cells"] as? [[String: Any]] {
                    let cells: [(pose: PetSpritePose, index: Int)] = cellList.compactMap { cell in
                        guard let name = cell["pose"] as? String,
                              let pose = PetSpritePose(rawValue: name) else { return nil }
                        return (pose, petSpriteJSONInt(cell["index"], fallback: 0))
                    }
                    guard !cells.isEmpty else { return nil }
                    return Item(
                        pose: nil,
                        url: candidate,
                        frames: 1,
                        columns: petSpriteJSONInt(board["columns"], fallback: 1),
                        rows: petSpriteJSONInt(board["rows"], fallback: 1),
                        cells: cells
                    )
                }
                guard let poseName = board["pose"] as? String,
                      let pose = PetSpritePose(rawValue: poseName) else { return nil }
                return Item(
                    pose: pose,
                    url: candidate,
                    frames: petSpriteJSONInt(board["frames"], fallback: pose.defaultFrameCount)
                )
            }
            return items.isEmpty ? nil : items
        }
        let poses = (json["poses"] as? [String: Any]) ?? json
        var items: [Item] = []
        for pose in PetSpritePose.allCases {
            guard let entry = poses[pose.rawValue] as? [String: Any] else { continue }
            let file = (entry["file"] as? String) ?? ""
            guard !file.isEmpty else { continue }
            let candidate = directory.appendingPathComponent(file)
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            let frames = PetSpriteStrip.clampFrames(petSpriteJSONInt(entry["frames"], fallback: pose.defaultFrameCount))
            items.append(Item(pose: pose, url: candidate, frames: frames))
        }
        return items
    }
}

struct BundledPetCharacter: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let summary: String
    let searchTerms: String
    let folderName: String
    let isAdvanced: Bool
}

/// Custom session-pet figure. Identity PNGs stay byte-for-byte so a 32x32
/// sprite stays blocky. Pose strips may be cleaned and scaled on install.
enum PetSpriteStore {
    static let fileStem = "session-pet-sprite"
    static let stateFileName = "session-pet-states.json"
    static let cinematicFileName = "session-pet-cinematic.png"
    static let cinematicMetaFileName = "session-pet-cinematic.json"

    /// The stitched cinematic strip's true frame count. Nil when the meta file
    /// is absent (a pre-0.5.114 install) — callers fall back to the aspect
    /// guess, which is wrong for non-square cells; reinstalling the pack fixes it.
    static func cinematicFrameCount(in directory: URL, fileManager: FileManager = .default) -> Int? {
        let url = directory.appendingPathComponent(cinematicMetaFileName)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frames = json["frames"] as? Int, frames >= 1
        else { return nil }
        return PetSpriteStrip.clampFrames(frames)
    }
    static let maxBytes = 8 * 1024 * 1024
    static let allowedExtensions: Set<String> = ["png", "gif", "jpg", "jpeg", "tiff", "tif", "webp"]

    enum InstallError: LocalizedError {
        case notAnImage
        case empty
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notAnImage: return "Choose a PNG, GIF, or JPEG of the figure."
            case .empty: return "That file is empty."
            case .tooLarge: return "Sprite must be 8 MB or smaller."
            }
        }
    }

    enum BundledDefaultRefreshResult: Equatable {
        case notApplicable
        case refreshed
        case failed
    }

    enum BundledCharacterRefreshResult: Equatable {
        case notApplicable
        case refreshed(String)
        case failed
    }

    static func supportDirectory(fileManager: FileManager = .default, home: URL? = nil) -> URL {
        let root = home ?? fileManager.homeDirectoryForCurrentUser
        return root.appendingPathComponent("Library/Application Support/COS Control", isDirectory: true)
    }

    static func isAllowedImage(_ url: URL) -> Bool {
        allowedExtensions.contains(url.pathExtension.lowercased())
    }

    static func poseFileName(_ pose: PetSpritePose) -> String {
        "session-pet-\(pose.rawValue).png"
    }

    static func existingSpriteURL(in directory: URL, fileManager: FileManager = .default) -> URL? {
        for ext in ["png", "gif", "webp", "jpg", "jpeg", "tiff", "tif"] {
            let candidate = directory.appendingPathComponent("\(fileStem).\(ext)")
            if fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func existingPoseURL(_ pose: PetSpritePose, in directory: URL, fileManager: FileManager = .default) -> URL? {
        let candidate = directory.appendingPathComponent(poseFileName(pose))
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Every reason `install` can reject a file, checked against the SOURCE and
    /// writing nothing. Callers that clear the installed character first must
    /// run this BEFORE clearing: `install` did its own guards after the copy,
    /// so picking a 9 MB PNG deleted the pet and then refused the replacement.
    static func assertInstallable(_ source: URL, fileManager: FileManager = .default) throws {
        guard isAllowedImage(source) else { throw InstallError.notAnImage }
        let size = (try fileManager.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
        if size <= 0 { throw InstallError.empty }
        if size > maxBytes { throw InstallError.tooLarge }
        guard NSImage(contentsOf: source) != nil else { throw InstallError.notAnImage }
    }

    static func install(from source: URL, into directory: URL, fileManager: FileManager = .default) throws -> URL {
        guard isAllowedImage(source) else { throw InstallError.notAnImage }
        let size = (try fileManager.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
        if size <= 0 { throw InstallError.empty }
        if size > maxBytes { throw InstallError.tooLarge }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        remove(from: directory, fileManager: fileManager)
        let dest = directory.appendingPathComponent("\(fileStem).\(source.pathExtension.lowercased())")
        try fileManager.copyItem(at: source, to: dest)
        guard NSImage(contentsOf: dest) != nil else {
            try? fileManager.removeItem(at: dest)
            throw InstallError.notAnImage
        }
        return dest
    }

    /// `retireCinematic` is false during a PACK install: the pack's own board
    /// writes the stitched strip, and a pose strip later in the same manifest
    /// (the combat board is exactly that) would otherwise delete it.
    static func installPose(
        _ pose: PetSpritePose,
        from source: URL,
        frames: Int,
        into directory: URL,
        retireCinematic: Bool = true,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard isAllowedImage(source) else { throw InstallError.notAnImage }
        let size = (try fileManager.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
        if size <= 0 { throw InstallError.empty }
        if size > maxBytes { throw InstallError.tooLarge }
        guard let loaded = NSImage(contentsOf: source) else { throw InstallError.notAnImage }
        var image = loaded
        if PetSpriteAlpha.needsPaperKnockout(image) {
            image = PetSpriteAlpha.knockOutEdgePaper(image)
        }
        let prepared = PetSpriteStrip.prepare(image, frames: frames)
        image = prepared.image
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(poseFileName(pose))
        try? fileManager.removeItem(at: dest)
        guard let data = pngData(image) else { throw InstallError.notAnImage }
        try data.write(to: dest, options: .atomic)
        // frames(for:) prefers the stitched cinematic for trio and swarm (and
        // duel), so a newly chosen sprite for one of those would render behind
        // the old strip forever unless the strip is retired with it.
        if retireCinematic, [.patrol, .duel, .trio, .swarm].contains(pose) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(cinematicFileName))
            try? fileManager.removeItem(at: directory.appendingPathComponent(cinematicMetaFileName))
        }
        var map = loadStateMap(in: directory, fileManager: fileManager)
        map[pose] = (poseFileName(pose), prepared.frames)
        try saveStateMap(map, in: directory, fileManager: fileManager)
        return dest
    }

    static func installGrid(
        from source: URL,
        columns: Int,
        rows: Int,
        cells: [(pose: PetSpritePose, index: Int)],
        into directory: URL,
        fileManager: FileManager = .default
    ) throws {
        guard isAllowedImage(source) else { throw InstallError.notAnImage }
        let size = (try fileManager.attributesOfItem(atPath: source.path)[.size] as? Int) ?? 0
        if size <= 0 { throw InstallError.empty }
        if size > maxBytes { throw InstallError.tooLarge }
        guard let loaded = NSImage(contentsOf: source) else { throw InstallError.notAnImage }
        var image = loaded
        if PetSpriteAlpha.needsPaperKnockout(image) {
            image = PetSpriteAlpha.knockOutEdgePaper(image)
        }
        let sliced = rows == 1 && columns > 1
            ? PetSpriteStrip.sliceRowByIslands(image, count: columns, forceCount: true)
            : PetSpriteStrip.sliceGrid(image, columns: columns, rows: rows)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var map = loadStateMap(in: directory, fileManager: fileManager)
        var preparedPoses: [PetSpritePose: NSImage] = [:]
        for cell in cells {
            guard cell.index >= 0, cell.index < sliced.count else { continue }
            // Board cells need the same edge-sliver pass as strip frames: a
            // cell cut leaves the neighbour scene's truncated content at the
            // border, which is where the bleed was first seen.
            let cleaned = PetSpriteStrip.suppressTruncatedEdgeSlivers(sliced[cell.index])
            let prepared = rows == 1
                ? PetSpriteStrip.fitHeight(PetSpriteStrip.cropOpaque(cleaned, paddingRatio: 0.30))
                : PetSpriteStrip.prepare(cleaned).image
            let dest = directory.appendingPathComponent(poseFileName(cell.pose))
            try? fileManager.removeItem(at: dest)
            guard let data = pngData(prepared) else { continue }
            try data.write(to: dest, options: .atomic)
            map[cell.pose] = (poseFileName(cell.pose), 1)
            preparedPoses[cell.pose] = prepared
        }
        let sequence: [PetSpritePose] = [.patrol, .duel, .trio, .swarm]
        // Clear unconditionally: a board that cannot rebuild the strip must not
        // leave the PREVIOUS pack's cinematic in place, or trio and swarm play
        // one pack's art while every other pose comes from another.
        let dest = directory.appendingPathComponent(cinematicFileName)
        try? fileManager.removeItem(at: dest)
        try? fileManager.removeItem(at: directory.appendingPathComponent(cinematicMetaFileName))
        if sequence.allSatisfy({ preparedPoses[$0] != nil }),
           let strip = PetSpriteStrip.stitch(sequence.compactMap { preparedPoses[$0] }) {
            if let data = pngData(strip) {
                try data.write(to: dest, options: .atomic)
                // Playback must slice by the count that was stitched. Guessing
                // it back from the aspect ratio landed on 3 for a 4-cell strip
                // and cut every frame mid-cell — the half-droid bleed.
                let meta = try JSONSerialization.data(withJSONObject: ["frames": sequence.count])
                try meta.write(to: directory.appendingPathComponent(cinematicMetaFileName), options: .atomic)
            }
        }
        try saveStateMap(map, in: directory, fileManager: fileManager)
    }

    static func setFrames(
        _ pose: PetSpritePose,
        frames: Int,
        in directory: URL,
        fileManager: FileManager = .default
    ) {
        var map = loadStateMap(in: directory, fileManager: fileManager)
        let file = map[pose]?.file ?? poseFileName(pose)
        guard fileManager.fileExists(atPath: directory.appendingPathComponent(file).path) else { return }
        map[pose] = (file, PetSpriteStrip.clampFrames(frames))
        try? saveStateMap(map, in: directory, fileManager: fileManager)
    }

    static func loadStateMap(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [PetSpritePose: (file: String, frames: Int)] {
        let url = directory.appendingPathComponent(stateFileName)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let poses = json["poses"] as? [String: Any]
        else {
            var inferred: [PetSpritePose: (file: String, frames: Int)] = [:]
            for pose in PetSpritePose.allCases {
                guard let url = existingPoseURL(pose, in: directory, fileManager: fileManager) else { continue }
                // Without the state file the pose's DEFAULT count is a guess,
                // and guessing high shreds a single-cell PNG into that many
                // vertical slivers. A still is a survivable wrong answer;
                // confetti is not. Only claim a strip when the file looks wide.
                var frames = 1
                if let image = NSImage(contentsOf: url), let cg = PetSpriteStrip.raster(image),
                   CGFloat(cg.width) >= CGFloat(cg.height) * 1.6 {
                    frames = pose.defaultFrameCount
                }
                inferred[pose] = (poseFileName(pose), frames)
            }
            return inferred
        }
        var map: [PetSpritePose: (file: String, frames: Int)] = [:]
        for pose in PetSpritePose.allCases {
            guard let entry = poses[pose.rawValue] as? [String: Any] else { continue }
            let file = (entry["file"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? poseFileName(pose)
            let frames = PetSpriteStrip.clampFrames(petSpriteJSONInt(entry["frames"], fallback: pose.defaultFrameCount))
            map[pose] = (file, frames)
        }
        return map
    }

    /// An ambient alias is the same clip, not another rest to reschedule at a
    /// different cadence. Distinct Miles patrol/idle/meditation clips remain.
    static func restPoses(
        for pose: PetSpritePose,
        stateMap: [PetSpritePose: (file: String, frames: Int)]
    ) -> [PetSpritePose] {
        guard pose == .patrol else { return [] }
        var seen: Set<String> = []
        if let primary = stateMap[pose] { seen.insert("\(primary.file)#\(primary.frames)") }
        return [PetSpritePose.idle, .waiting].filter { candidate in
            guard let row = stateMap[candidate], row.frames > 1 else { return false }
            return seen.insert("\(row.file)#\(row.frames)").inserted
        }
    }

    /// Gallery thumbnails use the declared idle strip, not a legacy filename
    /// paired with a newer strip's frame count (which can crop transparent air).
    static func galleryThumbnail(in directory: URL) -> NSImage? {
        guard let idle = loadStateMap(in: directory)[.idle],
              let data = try? Data(contentsOf: directory.appendingPathComponent(idle.file)),
              let strip = NSImage(data: data) else { return nil }
        return PetSpriteStrip.slice(strip, frames: idle.frames).first
    }

    /// Optional per-strip cadence authored by a bundled pack. Legacy and
    /// custom packs omit it and continue to use the pose's duration-preserving
    /// fallback. Keeping timing beside the strip prevents a 16-frame swarm
    /// from silently playing at another character's speed.
    static func loadFrameIntervals(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [PetSpritePose: Double] {
        let url = directory.appendingPathComponent(stateFileName)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let poses = json["poses"] as? [String: Any]
        else { return [:] }
        var intervals: [PetSpritePose: Double] = [:]
        for pose in PetSpritePose.allCases {
            guard let entry = poses[pose.rawValue] as? [String: Any],
                  let value = entry["interval"] as? NSNumber,
                  value.doubleValue > 0
            else { continue }
            intervals[pose] = value.doubleValue
        }
        return intervals
    }

    /// Optional figure scale authored by a sprite pack for a specific pose.
    /// This fixes art whose subject occupies a smaller share of its cell without
    /// inflating every other state through the user's global character dial.
    static func loadRenderScales(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [PetSpritePose: CGFloat] {
        let url = directory.appendingPathComponent(stateFileName)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let poses = json["poses"] as? [String: Any]
        else { return [:] }
        var scales: [PetSpritePose: CGFloat] = [:]
        for pose in PetSpritePose.allCases {
            guard let entry = poses[pose.rawValue] as? [String: Any],
                  let value = entry["renderScale"] as? NSNumber
            else { continue }
            scales[pose] = CGFloat(min(max(value.doubleValue, 0.5), 3.0))
        }
        return scales
    }

    /// Shipped characters are already PROCESSED (sliced, cleaned, stitched,
    /// with state maps). Keep their data registry separate from OpenPets even
    /// though Settings presents both sources in one catalog; attribution still
    /// applies only to community stills. Adding the next character is one asset
    /// folder plus one record.
    static let bundledCharacters = [
        BundledPetCharacter(
            id: "jedi-miles-windu",
            displayName: "Jedi Miles Windu",
            summary: "Ten animated states. Purple saber and escalating droid fights.",
            searchTerms: "Miles Windu Black male Jedi purple lightsaber action RPG droids",
            folderName: "DefaultPet",
            isAdvanced: true
        ),
        BundledPetCharacter(
            id: "jedi-nia-solari",
            displayName: "Jedi Nia Solari",
            summary: "Eight-frame idle and four combat loops. Purple saber, braided silhouette, and Force counters.",
            searchTerms: "Nia Solari Black African American female woman Jedi purple lightsaber action RPG braids",
            folderName: "BundledCharacters/jedi-nia-solari",
            isAdvanced: true
        ),
        BundledPetCharacter(
            id: "jedi-elara-vale",
            displayName: "Jedi Elara Vale",
            summary: "Eight-frame idle and four combat loops. Green saber, auburn braid, and agile redirects.",
            searchTerms: "Elara Vale white female woman Jedi green lightsaber action RPG auburn braid",
            folderName: "BundledCharacters/jedi-elara-vale",
            isAdvanced: true
        ),
        BundledPetCharacter(
            id: "jedi-rowan-vale",
            displayName: "Jedi Rowan Vale",
            summary: "Eight-frame idle and four combat loops. Blue saber, two-handed guard, and grounded strikes.",
            searchTerms: "Rowan Vale white male man Jedi blue lightsaber action RPG",
            folderName: "BundledCharacters/jedi-rowan-vale",
            isAdvanced: true
        ),
    ]
    static let defaultCharacterID = "jedi-miles-windu"
    static var defaultCharacterName: String {
        bundledCharacters.first(where: { $0.id == defaultCharacterID })?.displayName
            ?? "Jedi Miles Windu"
    }

    static func bundledCharacter(id: String) -> BundledPetCharacter? {
        bundledCharacters.first { $0.id == id }
    }

    static func bundledCharacterURL(
        _ character: BundledPetCharacter,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let folder = character.folderName.split(separator: "/").reduce(resources) {
            $0.appendingPathComponent(String($1), isDirectory: true)
        }
        return fileManager.fileExists(atPath: folder.path) ? folder : nil
    }

    static func bundledDefaultURL(bundle: Bundle = .main) -> URL? {
        guard let character = bundledCharacter(id: defaultCharacterID) else { return nil }
        return bundledCharacterURL(character, bundle: bundle)
    }

    /// Copies the bundled character in only when the user has none of their
    /// own. Returns false when anything is already installed, so this can never
    /// overwrite a chosen sprite or undo "Use COS figure".
    @discardableResult
    static func installBundledDefault(
        into directory: URL,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> Bool {
        installDefault(into: directory, from: bundledDefaultURL(bundle: bundle), fileManager: fileManager)
    }

    @discardableResult
    static func installBundledCharacter(
        id: String,
        into directory: URL,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let character = bundledCharacter(id: id) else { return false }
        return installDefault(
            into: directory,
            from: bundledCharacterURL(character, bundle: bundle, fileManager: fileManager),
            fileManager: fileManager
        )
    }

    /// Promote only exact retained stock Jedi packs. Comparing the complete
    /// state dictionary also protects custom timing, scale, and extra fields.
    /// Every old referenced image must match the retained bundled bytes.
    /// Replacement files are validated and written first; the active map is
    /// atomically replaced last so an interrupted upgrade remains retryable.
    @discardableResult
    static func refreshRecognizedBundledCharacter(
        into directory: URL,
        sourceRootOverride: URL? = nil,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> BundledCharacterRefreshResult {
        // Foundation's untyped NSNumber equality can distinguish 0.085 from
        // its own reserialization (0.085000000000000006). Decode through the
        // shared Double-valued JSON model, then compare every key canonically.
        // No numeric tolerance: an actual changed playback value still differs.
        func canonicalState(_ data: Data) -> Data? {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try? encoder.encode(value)
        }
        guard existingSpriteURL(in: directory, fileManager: fileManager) == nil,
              let installedData = try? Data(contentsOf: directory.appendingPathComponent(stateFileName)),
              let installedState = canonicalState(installedData)
        else { return .notApplicable }

        for character in bundledCharacters where character.id != defaultCharacterID {
            let source: URL? = if let sourceRootOverride {
                sourceRootOverride.appendingPathComponent(character.id, isDirectory: true)
            } else {
                bundledCharacterURL(character, bundle: bundle, fileManager: fileManager)
            }
            guard let source,
                  let historyData = try? Data(contentsOf: source.appendingPathComponent("stock-state-history.json")),
                  let history = try? JSONSerialization.jsonObject(with: historyData) as? [String: Any],
                  let maps = history["maps"] as? [[String: Any]],
                  let match = maps.first(where: {
                      guard let state = $0["state"] as? [String: Any],
                            let data = try? JSONSerialization.data(withJSONObject: state)
                      else { return false }
                      return canonicalState(data) == installedState
                  }),
                  let state = match["state"] as? [String: Any],
                  let oldPoses = state["poses"] as? [String: [String: Any]]
            else { continue }

            let oldFiles = Set(oldPoses.values.compactMap { $0["file"] as? String })
            guard oldFiles.count > 0,
                  oldFiles.allSatisfy({ file in
                      guard file == URL(fileURLWithPath: file).lastPathComponent,
                            let installed = try? Data(contentsOf: directory.appendingPathComponent(file)),
                            let retained = try? Data(contentsOf: source.appendingPathComponent(file))
                      else { return false }
                      return installed == retained
                  })
            else { continue }

            let bundled = loadStateMap(in: source, fileManager: fileManager)
            let intervals = loadFrameIntervals(in: source, fileManager: fileManager)
            let animated: [PetSpritePose] = [.idle, .patrol, .waiting, .working, .duel, .trio, .swarm]
            guard bundled.count == PetSpritePose.liveCases.count,
                  animated.allSatisfy({ pose in
                      guard let row = bundled[pose] else { return false }
                      return row.frames > 1 && row.frames <= PetSpriteStrip.maxFrames
                          && (intervals[pose] ?? 0) > 0
                  }),
                  let sourceState = try? Data(contentsOf: source.appendingPathComponent(stateFileName))
            else { return .failed }

            var replacements: [String: Data] = [:]
            for row in bundled.values {
                guard row.file == URL(fileURLWithPath: row.file).lastPathComponent,
                      let data = try? Data(contentsOf: source.appendingPathComponent(row.file)),
                      let image = NSImage(data: data),
                      let raster = PetSpriteStrip.raster(image),
                      (row.frames == 1 || raster.height <= PetSpriteStrip.maxHeight),
                      raster.width >= row.frames,
                      raster.width % row.frames == 0,
                      PetSpriteStrip.slice(image, frames: row.frames).count == row.frames
                else {
                    NSLog("COSControl Jedi upgrade rejected incomplete art: %@/%@", character.id, row.file)
                    return .failed
                }
                // Never rewrite an actively referenced old file to new bytes.
                // Versioned destination names make interruption safe.
                if oldFiles.contains(row.file),
                   (try? Data(contentsOf: directory.appendingPathComponent(row.file))) != data {
                    return .failed
                }
                replacements[row.file] = data
            }

            do {
                for (file, data) in replacements where !oldFiles.contains(file) {
                    try data.write(to: directory.appendingPathComponent(file), options: .atomic)
                }
                guard replacements.allSatisfy({ file, data in
                    (try? Data(contentsOf: directory.appendingPathComponent(file))) == data
                }) else { return .failed }
                try sourceState.write(
                    to: directory.appendingPathComponent(stateFileName), options: .atomic
                )
                return .refreshed(character.id)
            } catch {
                NSLog("COSControl Jedi upgrade failed: %@", error.localizedDescription)
                return .failed
            }
        }
        return .notApplicable
    }

    static func installDefault(
        into directory: URL,
        from source: URL?,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let source else { return false }
        let hasState = fileManager.fileExists(atPath: directory.appendingPathComponent(stateFileName).path)
        let hasPose = PetSpritePose.allCases.contains {
            existingPoseURL($0, in: directory, fileManager: fileManager) != nil
        }
        let hasCustom = existingSpriteURL(in: directory, fileManager: fileManager) != nil
        guard !hasState, !hasPose, !hasCustom else { return false }
        guard let files = try? fileManager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil
        ) else { return false }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Every file must land. Reporting success off the FIRST copy let a
        // partial install through — idle.png present, the state map missing —
        // which leaves a pet that cannot be read back.
        var wanted = 0
        var copied = 0
        for file in files {
            let ext = file.pathExtension.lowercased()
            guard ext == "png" || ext == "json" else { continue }
            wanted += 1
            let dest = directory.appendingPathComponent(file.lastPathComponent)
            try? fileManager.removeItem(at: dest)
            do {
                try fileManager.copyItem(at: file, to: dest)
                copied += 1
            } catch {
                NSLog("COSControl pet-default copy failed: %@", file.lastPathComponent)
            }
        }
        let stateLanded = fileManager.fileExists(
            atPath: directory.appendingPathComponent(stateFileName).path
        )
        return wanted > 0 && copied == wanted && stateLanded
    }

    /// Upgrade a retained stock Miles pack without touching a chosen OpenPets
    /// still, COS figure, custom animation, or another bundled Jedi. Every
    /// recognized mapping and asset must be byte-identical to the retained stock
    /// files. The four replacement strips land first and the state map changes
    /// last, so
    /// an interrupted write leaves the old pack readable and retryable.
    @discardableResult
    static func refreshRecognizedBundledDefault(
        into directory: URL,
        from sourceOverride: URL? = nil,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> BundledDefaultRefreshResult {
        guard let source = sourceOverride ?? bundledDefaultURL(bundle: bundle) else { return .failed }
        let installed = loadStateMap(in: directory, fileManager: fileManager)
        let retainedStock: [PetSpritePose: [(file: String, frames: Int)]] = [
            .idle: [(poseFileName(.idle), 8)],
            .patrol: [(poseFileName(.patrol), 8)],
            .waiting: [(poseFileName(.waiting), 8)],
            .working: [
                (poseFileName(.working), 8),
                ("session-pet-working-error-story.png", 16),
                ("session-pet-working-story-v7.png", 16),
                ("session-pet-working-one-droid-v15.png", 16),
                ("session-pet-working-one-droid-v15-1.png", 16),
                ("session-pet-working-one-droid-v15-2.png", 16),
            ],
            .done: [(poseFileName(.done), 8)],
            .error: [(poseFileName(.error), 8)],
            .attention: [(poseFileName(.attention), 6)],
            .duel: [
                (poseFileName(.duel), 8),
                ("session-pet-duel-two-droid-v5.png", 13),
                ("session-pet-duel-story-v7.png", 16),
                ("session-pet-duel-two-droid-v15.png", 13),
                ("session-pet-duel-two-droid-v15-1.png", 12),
                ("session-pet-duel-two-droid-v15-2.png", 17),
            ],
            .trio: [
                (poseFileName(.trio), 6),
                ("session-pet-trio-story-v7.png", 12),
                ("session-pet-trio-story-v15.png", 13),
                ("session-pet-trio-story-v15-1.png", 13),
                ("session-pet-trio-story-v15-2.png", 13),
            ],
            .swarm: [
                (poseFileName(.swarm), 6),
                ("session-pet-swarm-story-v7.png", 16),
                ("session-pet-swarm-story-v15.png", 16),
                ("session-pet-swarm-story-v15-1.png", 16),
                ("session-pet-swarm-story-v15-2.png", 23),
                ("session-pet-swarm-story-v15-3.png", 25),
                ("session-pet-swarm-story-v15-4.png", 26),
            ],
        ]
        guard installed.count == retainedStock.count,
              retainedStock.allSatisfy({ pose, accepted in
                  guard let row = installed[pose] else { return false }
                  return accepted.contains(where: {
                      $0.file == row.file && $0.frames == row.frames
                  })
              })
        else { return .notApplicable }
        guard retainedStock.keys.allSatisfy({ pose in
            guard let row = installed[pose] else { return false }
            guard let installedData = try? Data(
                contentsOf: directory.appendingPathComponent(row.file)
            ), let bundledData = try? Data(
                contentsOf: source.appendingPathComponent(row.file)
            ) else { return false }
            return installedData == bundledData
        }) else { return .notApplicable }

        let bundled = loadStateMap(in: source, fileManager: fileManager)
        let storyPoses: [PetSpritePose] = [.working, .duel, .trio, .swarm]
        var stories: [(pose: PetSpritePose, file: String, frames: Int, data: Data)] = []
        for pose in storyPoses {
            guard let row = bundled[pose], row.file != poseFileName(pose),
                  let data = try? Data(contentsOf: source.appendingPathComponent(row.file)),
                  NSImage(data: data) != nil
            else { return .failed }
            stories.append((pose, row.file, row.frames, data))
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for story in stories {
                try story.data.write(
                    to: directory.appendingPathComponent(story.file), options: .atomic
                )
            }
            guard stories.allSatisfy({ story in
                (try? Data(contentsOf: directory.appendingPathComponent(story.file))) == story.data
            })
            else { return .failed }
            var updated = installed
            for story in stories {
                updated[story.pose] = (story.file, story.frames)
            }
            let installedScales = loadRenderScales(in: directory, fileManager: fileManager)
            let bundledScales = loadRenderScales(in: source, fileManager: fileManager)
            let idleScaleWasStock = installedScales[.idle] == nil
                || abs((installedScales[.idle] ?? 0) - 2) < 0.001
                || abs((installedScales[.idle] ?? 0) - 3) < 0.001
            let scaleOverrides: [PetSpritePose: CGFloat] = idleScaleWasStock
                ? bundledScales.filter { $0.key == .idle }
                : [:]
            // Every pose whose FILE this refresh replaces takes the bundled
            // interval; untouched poses keep whatever the user has.
            let bundledIntervals = loadFrameIntervals(in: source, fileManager: fileManager)
            var intervalOverrides: [PetSpritePose: Double] = [:]
            for story in stories {
                if let interval = bundledIntervals[story.pose] {
                    intervalOverrides[story.pose] = interval
                }
            }
            try saveStateMap(
                updated,
                frameIntervalDefaults: bundledIntervals,
                frameIntervalOverrides: intervalOverrides,
                renderScaleDefaults: loadRenderScales(in: source, fileManager: fileManager),
                renderScaleOverrides: scaleOverrides,
                in: directory,
                fileManager: fileManager
            )
            return .refreshed
        } catch {
            NSLog("COSControl pet-default refresh failed: %@", error.localizedDescription)
            return .failed
        }
    }

    static func remove(from directory: URL, fileManager: FileManager = .default) {
        for ext in allowedExtensions {
            let url = directory.appendingPathComponent("\(fileStem).\(ext)")
            try? fileManager.removeItem(at: url)
        }
    }

    static func removeAll(from directory: URL, fileManager: FileManager = .default) {
        remove(from: directory, fileManager: fileManager)
        let referenced = Set(loadStateMap(in: directory, fileManager: fileManager).values.map(\.file))
        for file in referenced {
            try? fileManager.removeItem(at: directory.appendingPathComponent(file))
        }
        for pose in PetSpritePose.allCases {
            try? fileManager.removeItem(at: directory.appendingPathComponent(poseFileName(pose)))
        }
        try? fileManager.removeItem(at: directory.appendingPathComponent(cinematicFileName))
        try? fileManager.removeItem(at: directory.appendingPathComponent(cinematicMetaFileName))
        try? fileManager.removeItem(at: directory.appendingPathComponent(stateFileName))
    }

    /// Swap a fully-staged pack in as the WHOLE installed character. Clearing
    /// first is the point: installing a pack in place left every pose the new
    /// pack does not declare owned by the previous one, and because the plain
    /// custom sprite is only the last-resort fallback in `frames(for:)`, a
    /// legacy pack layered under an advanced one was structurally unreachable.
    /// Staging then swapping means a pack that fails halfway leaves the
    /// existing character untouched instead of half-erased.
    static func replaceContents(
        of directory: URL,
        with staging: URL,
        fileManager: FileManager = .default
    ) throws {
        let staged = try fileManager.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        )
        guard !staged.isEmpty else { throw InstallError.empty }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // Hold the outgoing character aside rather than deleting it. Clearing
        // first and then throwing mid-copy -- disk full, sandbox denial -- left
        // a half-erased directory whose state map could reference PNGs that
        // never arrived, which is exactly what the staging design claims to
        // prevent. Staging only ever protected the BUILD; this protects the swap.
        let backup = staging.appendingPathComponent("__outgoing", isDirectory: true)
        try fileManager.createDirectory(at: backup, withIntermediateDirectories: true)
        var held: [(live: URL, saved: URL)] = []
        for file in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let saved = backup.appendingPathComponent(file.lastPathComponent)
            if (try? fileManager.moveItem(at: file, to: saved)) != nil {
                held.append((file, saved))
            }
        }
        do {
            for file in staged where file.lastPathComponent != "__outgoing" {
                let dest = directory.appendingPathComponent(file.lastPathComponent)
                try? fileManager.removeItem(at: dest)
                try fileManager.copyItem(at: file, to: dest)
            }
        } catch {
            NSLog("COSControl pack swap failed, restoring previous character: %@",
                  error.localizedDescription)
            for file in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? fileManager.removeItem(at: file)
            }
            for row in held { try? fileManager.moveItem(at: row.saved, to: row.live) }
            throw error
        }
    }

    private static func saveStateMap(
        _ map: [PetSpritePose: (file: String, frames: Int)],
        frameIntervalDefaults: [PetSpritePose: Double] = [:],
        frameIntervalOverrides: [PetSpritePose: Double] = [:],
        renderScaleDefaults: [PetSpritePose: CGFloat] = [:],
        renderScaleOverrides: [PetSpritePose: CGFloat] = [:],
        in directory: URL,
        fileManager: FileManager
    ) throws {
        var retainedIntervals = frameIntervalDefaults
        for (pose, interval) in loadFrameIntervals(in: directory, fileManager: fileManager) {
            retainedIntervals[pose] = interval
        }
        // A pose getting NEW art has no business keeping the old art's cadence.
        // Retention alone left Miles's 17-frame V15.2 duel playing at the
        // 12-frame V15.1 interval — a 33% slowdown the speed slider could not
        // fix without desyncing every other pose.
        for (pose, interval) in frameIntervalOverrides {
            retainedIntervals[pose] = interval
        }
        var retainedScales = renderScaleDefaults
        for (pose, scale) in loadRenderScales(in: directory, fileManager: fileManager) {
            retainedScales[pose] = scale
        }
        for (pose, scale) in renderScaleOverrides {
            retainedScales[pose] = scale
        }
        var poses: [String: [String: Any]] = [:]
        for pose in PetSpritePose.allCases {
            guard let row = map[pose] else { continue }
            var payload: [String: Any] = ["file": row.file, "frames": row.frames]
            if let interval = retainedIntervals[pose] { payload["interval"] = interval }
            if let scale = retainedScales[pose] { payload["renderScale"] = scale }
            poses[pose.rawValue] = payload
        }
        let data = try JSONSerialization.data(withJSONObject: ["poses": poses], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent(stateFileName), options: .atomic)
    }

    private static func pngData(_ image: NSImage) -> Data? {
        guard let cg = PetSpriteStrip.raster(image) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}

/// One OpenPets gallery row. Preview is the catalog URL; never reconstructed from id.
struct OpenPetsCatalogRow: Identifiable, Sendable, Hashable {
    let id: String
    let displayName: String
    let category: String
    let preview: String

    init?(_ value: JSONValue) {
        guard let object = value.object else { return nil }
        guard let id = object["id"]?.string, !id.isEmpty else { return nil }
        guard let displayName = object["displayName"]?.string, !displayName.isEmpty else { return nil }
        guard let preview = object["preview"]?.string, !preview.isEmpty else { return nil }
        self.id = id
        self.displayName = displayName
        self.category = object["category"]?.string ?? ""
        self.preview = preview
    }
}
