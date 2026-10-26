import AppKit
import Foundation
import CryptoKit
import ImageIO
import OSLog

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
    /// Truncates toward zero; nil (never a trap) when the number cannot be an Int.
    var int: Int? { if case .number(let value) = self { Int(exactly: value.rounded(.towardZero)) } else { nil } }
    var double: Double? { if case .number(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}

/// 0.5.237: one meeting the server is polishing or saving (`meeting_sync.meetings`).
struct MeetingSyncRow: Sendable, Equatable, Identifiable {
    let meetingId: String
    let phase: String
    let percent: Int?
    let chunkFiles: Int
    let label: String
    var id: String { meetingId }

    init?(_ value: JSONValue) {
        guard let o = value.object, let id = o["meetingId"]?.string, !id.isEmpty else { return nil }
        meetingId = id
        phase = o["phase"]?.string ?? "pending"
        percent = o["percent"]?.int
        chunkFiles = o["chunkFiles"]?.int ?? 0
        label = o["label"]?.string ?? ""
    }

    /// The glasses app names a session `meeting_<epoch ms>_<suffix>`; nil for any other id.
    var startedAt: Date? {
        let parts = meetingId.split(separator: "_")
        guard parts.count >= 3, parts[0] == "meeting", parts[1].count == 13, let ms = Double(parts[1]) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Waiting its turn: no progress yet. The server writes progress when HQ starts.
    var isWaiting: Bool { percent == nil && (phase == "pending" || phase == "queued") }

    /// "1:05 PM meeting" today, "Sep 17, 1:05 PM meeting" another day, the id's tail otherwise.
    func title(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let start = startedAt else { return "Meeting …\(meetingId.suffix(6))" }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(calendar.isDate(start, inSameDayAs: now) ? "jmm" : "MMMd jmm")
        return "\(f.string(from: start)) meeting"
    }

    /// The server's own words, minus the restart warning the panel already shows once;
    /// a waiting row says so, with its audio length (the app records 6 s chunks).
    var stage: String {
        if isWaiting {
            let minutes = chunkFiles * 6 / 60
            return chunkFiles > 0 ? "Waiting · \(max(1, minutes)) min of audio" : "Waiting"
        }
        let trimmed = label.replacingOccurrences(of: " · do not update/restart", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? phase.replacingOccurrences(of: "_", with: " ") : trimmed
    }

    /// Working rows first (what the Mac is doing now), then oldest first (the queue order).
    static func ordered(_ rows: [MeetingSyncRow]) -> [MeetingSyncRow] {
        rows.enumerated().sorted { a, b in
            if a.element.isWaiting != b.element.isWaiting { return !a.element.isWaiting }
            let sa = a.element.startedAt ?? .distantFuture, sb = b.element.startedAt ?? .distantFuture
            return sa != sb ? sa < sb : a.offset < b.offset
        }.map(\.element)
    }
}

struct HelperResponse: Codable, Sendable {
    let ok: Bool
    let message: String
    let details: [String: JSONValue]
}

/// 0.5.336 (server 6.86.0). The live meeting view's gates; the rules that use them are in Sources/LiveTranscript.swift
/// (LiveMeeting). Here so ServerStatus can hold it in every lane that compiles Models.swift alone.
/// What the server says about the 6.86.0 live meeting surface. All false on an older server.
struct LiveMeetingCapability: Equatable, Sendable {
    /// `capabilities.liveMeeting.protocol`.
    var protocolVersion: Int? = nil
    /// `capabilities.liveMeeting.macLiveCues`: POST /api/mac-recording/start takes `liveCues: true`.
    var macLiveCues = false
    /// `capabilities.liveMeeting.provisional` names the grey line's route.
    var provisional = false
    /// `capabilities.liveCues.kinds`; empty when the server does not list them.
    var cueKinds: [String] = []
    /// `capabilities.liveCuesV2` is advertised, which the server does only while the Live cues switch is on.
    var liveCuesOn = false
    /// 0.5.339: `capabilities.liveMeeting.chunkLevels` (server 6.87.0): the session file keeps each chunk's level.
    var chunkLevels = false

    /// The 6.86.0 live meeting surface exists.
    var available: Bool { protocolVersion == 1 }
    /// Each cue drawn under its turn, labelled by kind.
    var inlineCues: Bool { available }
    /// The header's "2 decisions, 1 promise and 1 follow-up so far": only when the server lists the kinds it writes.
    var counts: Bool { available && !cueKinds.isEmpty }
    /// The grey provisional line.
    var greyLine: Bool { available && provisional }
    /// Send `liveCues: true` on a Mac recording's start: the Live cues switch on and the server taking the flag.
    var sendsMacLiveCues: Bool { available && macLiveCues && liveCuesOn }
    /// The Cues tab beside a Mac recording: the server can cue Mac recordings.
    var macCues: Bool { available && macLiveCues }
    /// 0.5.339: the glasses meeting's level strip in the bar. Off: today's still glyph.
    var levelStrip: Bool { available && chunkLevels }
}

extension LiveMeetingCapability {
    /// The helper's status keys (from /api/health) to a capability. A key the server did not send stays off.
    init(statusDetails details: [String: JSONValue]) {
        self.init(protocolVersion: details["liveMeetingProtocol"]?.int,
                  macLiveCues: details["liveMeetingMacLiveCues"]?.bool == true,
                  provisional: details["liveMeetingProvisional"]?.bool == true,
                  cueKinds: (details["liveCueKinds"]?.array ?? []).compactMap(\.string),
                  liveCuesOn: details["liveCuesOn"]?.bool == true,
                  chunkLevels: details["liveMeetingChunkLevels"]?.bool == true)
    }
}

struct ServerStatus: Sendable {
    /// Absence must be proven. A failed probe, foreign owner, disabled service,
    /// or interrupted transaction is never a fresh install.
    var needsFirstRun: Bool {
        runtimeState == "notInstalled" && !installed && !running && !serviceLoaded
            && launchAgentKind == "absent" && !ownerConflict && !transactionPending
    }
    var installed = false
    var serviceLoaded = false
    var running = false
    var managedContract = false
    var runtimeState = "unknown"
    var setupProviderInstalled = false
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
    /// Recent learning and Knowledge (server 6.44.5). OPTIONALS with no `?? 0`:
    /// absent means a server without the blocks, and the chip must then show no
    /// number rather than a confident zero. Dates arrive as ISO strings.
    var learningAvailable: Bool?
    var learningState: String?
    var learningCount: Int?
    var learningToReview: Int?
    var learningPatterns: Int?
    var learningTaskProposals: Int?
    var learningLastTs: String?
    var graphAvailable: Bool?
    var graphState: String?
    var graphEntities: Int?
    var graphRelationships: Int?
    var graphSourceUpdatedAt: String?
    var graphIndexState: String?
    var graphQueuePending: Int?
    var graphOwnerHost: String?
    var graphIsOwner: Bool?
    var graphReplica: Bool?
    var graphProcessorState: String?
    var graphLockState: String?
    var safeToRestart = false
    var activeJobs: Int?
    var activeTranscriptionSessions: Int?
    /// 0.5.278: the server's own split of activeTranscriptionSessions (maintenance status): live sessions, and the ids it
    /// calls stale (quiet 30 min, or empty for 2). The live transcript row follows this, never the files' clocks.
    var liveTranscriptionSessions: Int?
    var staleTranscriptionSessionIds: [String] = []
    /// 0.5.336 (server 6.86.0): what /api/health says about the live meeting view (`capabilities.liveMeeting`,
    /// `capabilities.liveCues.kinds`, `capabilities.liveCuesV2`). All absent on an older server.
    var liveMeeting = LiveMeetingCapability()
    var backgroundJobsSupported = false
    var backgroundJobsEnabled: Bool?
    var meetingPreviewSupported = false
    var meetingPreviewEnabled: Bool?
    /// Morning brief (server 6.43.0). Supported comes from health; the rest is
    /// the public capability summary -- times and gate, never a prompt or an id.
    var morningBriefSupported = false
    var morningBriefEnabled: Bool?
    var morningBriefTime: String?
    var morningBriefTimezone: String?
    var morningBriefNextRunAt: String?
    var morningBriefLastRunAt: String?
    var morningBriefLastRunStatus: String?
    var morningBriefGate: String?
    var tasksGate: String?
    var threadAttachSupported = false
    /// Server 6.67.0+: /api/health carries capabilities.pairing (the Glasses section of the setup guide).
    var pairingSupported = false
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
    /// 0.5.237: each meeting behind "N meetings syncing", in panel order.
    var meetingSyncMeetings: [MeetingSyncRow] = []
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

    /// HQ polish can report Idle while library handoff or a live recording still
    /// holds the restart gate. Keep this in lockstep with
    /// `COSControlHelper.overlayIdleMeetingWork`.
    var displayedMeetingSync: (active: Bool, label: String, blocksRestart: Bool) {
        let trimmed = meetingSyncLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let idle = !meetingSyncActive && (trimmed.isEmpty || trimmed == "Idle" || trimmed.hasPrefix("Idle"))
        guard idle else {
            return (meetingSyncActive, trimmed.isEmpty ? (meetingSyncActive ? "Syncing…" : "Idle") : trimmed, meetingSyncBlocksRestart)
        }
        if meetingFinalizationPending > 0 {
            return (true, "Saving to meeting library", true)
        }
        if (activeTranscriptionSessions ?? 0) > 0 {
            return (false, "Recording in progress", true)
        }
        return (false, trimmed.isEmpty ? "Idle" : trimmed, false)
    }

    /// 0.5.237: "0/0 sealed" with nothing recording read as a stuck meeting (Miles,
    /// 2026-09-18 15:31). Prefill only runs DURING a recording; between recordings it is Ready.
    var progressiveHqValue: String? {
        guard let progressive = progressiveHqEnabled else { return nil }
        let tier = progressiveHqTier == "max" ? "Max" : "Balanced"
        let threads = progressiveHqThreads.map { " · \($0)t" } ?? ""
        guard progressive else { return progressiveHqRequested == true ? "Unavailable" : "Off" }
        let recording = progressiveHqActive || progressiveHqSealedTotal > 0 || (activeTranscriptionSessions ?? 0) > 0
        return recording
            ? "\(progressiveHqSealedDone)/\(progressiveHqSealedTotal) sealed · \(tier)\(threads)"
            : "Ready · \(tier)\(threads)"
    }

    var meetingWorkBlockingRestart: Bool {
        meetingSyncActive
            || meetingSyncBlocksRestart
            || meetingFinalizationPending > 0
            || (activeTranscriptionSessions ?? 0) > 0
            || displayedMeetingSync.blocksRestart
    }
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
        setupProviderInstalled = details["setupProviderInstalled"]?.bool ?? false
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
        learningAvailable = details["learningAvailable"]?.bool
        learningState = details["learningState"]?.string
        learningCount = details["learningCount"]?.int
        learningToReview = details["learningToReview"]?.int
        learningPatterns = details["learningPatterns"]?.int
        learningTaskProposals = details["learningTaskProposals"]?.int
        learningLastTs = details["learningLastTs"]?.string
        graphAvailable = details["graphAvailable"]?.bool
        graphState = details["graphState"]?.string
        graphEntities = details["graphEntities"]?.int
        graphRelationships = details["graphRelationships"]?.int
        graphSourceUpdatedAt = details["graphSourceUpdatedAt"]?.string
        graphIndexState = details["graphIndexState"]?.string
        graphQueuePending = details["graphQueuePending"]?.int
        graphOwnerHost = details["graphOwnerHost"]?.string
        graphIsOwner = details["graphIsOwner"]?.bool
        graphReplica = details["graphReplica"]?.bool
        graphProcessorState = details["graphProcessorState"]?.string
        graphLockState = details["graphLockState"]?.string
        safeToRestart = details["safeToRestart"]?.bool ?? false
        activeJobs = details["activeJobs"]?.int
        activeTranscriptionSessions = details["activeTranscriptionSessions"]?.int
        liveTranscriptionSessions = details["liveTranscriptionSessions"]?.int
        staleTranscriptionSessionIds = (details["staleTranscriptionSessionIds"]?.array ?? []).compactMap(\.string)
        liveMeeting = LiveMeetingCapability(statusDetails: details)
        backgroundJobsSupported = details["backgroundJobsSupported"]?.bool ?? false
        backgroundJobsEnabled = details["backgroundJobsEnabled"]?.bool
        meetingPreviewSupported = details["meetingPreviewSupported"]?.bool ?? false
        meetingPreviewEnabled = details["meetingPreviewEnabled"]?.bool
        morningBriefSupported = details["morningBriefSupported"]?.bool ?? false
        morningBriefEnabled = details["morningBriefEnabled"]?.bool
        morningBriefTime = details["morningBriefTime"]?.string
        morningBriefTimezone = details["morningBriefTimezone"]?.string
        morningBriefNextRunAt = details["morningBriefNextRunAt"]?.string
        morningBriefLastRunAt = details["morningBriefLastRunAt"]?.string
        morningBriefLastRunStatus = details["morningBriefLastRunStatus"]?.string
        morningBriefGate = details["morningBriefGate"]?.string
        tasksGate = details["tasksGate"]?.string
        threadAttachSupported = details["threadAttachSupported"]?.bool ?? false
        pairingSupported = details["pairingSupported"]?.bool ?? false
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
        meetingSyncMeetings = MeetingSyncRow.ordered((details["meetingSyncMeetings"]?.array ?? []).compactMap(MeetingSyncRow.init))
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
            body: threadBody(raw, topics: topics, meetingCount: meetings),
            createdAt: raw["last_seen"]?.string ?? raw["created_at"]?.string ?? "",
            filePath: raw["filePath"]?.string,
            meetingCount: meetings,
            isResolved: raw["is_resolved"]?.bool == true
        )
    }

    /// Everything the server sends for a thread, as one selectable body that Copy as
    /// Context copies whole.
    ///
    /// Through 0.5.230 this was `manual_updates` alone. Stakeholders, meetings,
    /// milestones and sources crossed the helper and were dropped here, so a thread
    /// holding 42 sources rendered and copied as its one-line initial note. Section
    /// order follows the lens (`formatThreadDetailBody` in cos-glasses-app
    /// display-pages.ts) without its caps. A count is what arrived, not what the
    /// thread holds, except Meetings, where the server sends both.
    static func threadBody(_ raw: [String: JSONValue], topics: [String], meetingCount: Int) -> String {
        func trimmed(_ value: String?) -> String? {
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        var sections: [String] = []
        let notes = (raw["manual_updates"]?.array ?? []).compactMap { trimmed($0.object?["content"]?.string) }
        if !notes.isEmpty { sections.append(notes.joined(separator: "\n\n")) }

        var facts: [String] = []
        if let target = trimmed(raw["target_date"]?.string) { facts.append("Target: \(target)") }
        if let goal = trimmed(raw["serves_goal"]?.string) { facts.append("Goal: \(goal)") }
        let first = trimmed(raw["first_seen"]?.string)
        let last = trimmed(raw["last_seen"]?.string)
        if first != nil || last != nil { facts.append("Seen: \(first ?? "?") to \(last ?? "?")") }
        if !topics.isEmpty { facts.append("Topics: \(topics.joined(separator: ", "))") }
        if !facts.isEmpty { sections.append(facts.joined(separator: "\n")) }

        func section(_ title: String, _ items: [String], total: Int = 0) {
            guard !items.isEmpty else { return }
            let count = total > items.count ? "\(items.count) of \(total)" : "\(items.count)"
            sections.append("\(title) (\(count))\n" + items.map { "- \($0)" }.joined(separator: "\n"))
        }
        func strings(_ key: String) -> [String] {
            (raw[key]?.array ?? []).compactMap { trimmed($0.string) }
        }
        section("Stakeholders", strings("stakeholders"))
        let meetingRows = (raw["meetings"]?.array ?? []).compactMap { value -> String? in
            guard let meeting = value.object, let name = trimmed(meeting["name"]?.string) else { return nil }
            return trimmed(meeting["date"]?.string).map { "\($0) \(name)" } ?? name
        }
        section("Meetings", meetingRows, total: meetingCount)
        section("Milestones", strings("milestones"))
        section("Sources", strings("sources"))
        return sections.joined(separator: "\n\n")
    }
}


// ── Recent learning and Knowledge (server 6.44.5, Control 0.5.190) ──
//
// Read-only projections of /api/context/learning* and /api/context/graph/*,
// decoded from the helper's pass-through details. Every count is an optional:
// the server omits what it cannot count, and a zero here would be a claim.

struct LearningSourceRef: Sendable, Equatable {
    let kind: String
    let id: String
    let excerpt: String

    init?(_ value: JSONValue?) {
        guard let o = value?.object else { return nil }
        kind = o["kind"]?.string ?? ""
        id = o["id"]?.string ?? ""
        excerpt = o["excerpt"]?.string ?? ""
    }
}

/// The store's own record behind one event, allowlisted server-side
/// (LEARNING_DETAIL_KEYS). Present only on the detail route.
struct LearningEventDetail: Sendable, Equatable {
    let task: String?
    let kind: String?
    let layer: String?
    let date: String?
    let future: Bool?
    let loggedTimes: Int?
    let memoryType: String?
    let content: String?
    let before: String?
    let after: String?
    let rule: String?
    let status: String?
    let occurrences: Int?
    let threshold: Int?
    let entry: String?
    let truncated: Bool?
    let bodies: [String]

    init?(_ value: JSONValue?) {
        guard let o = value?.object else { return nil }
        task = o["task"]?.string
        kind = o["kind"]?.string
        layer = o["layer"]?.string
        date = o["date"]?.string
        future = o["future"]?.bool
        loggedTimes = o["logged_times"]?.int
        memoryType = o["memory_type"]?.string
        content = o["content"]?.string
        before = o["before"]?.string
        after = o["after"]?.string
        rule = o["rule"]?.string
        status = o["status"]?.string
        occurrences = o["occurrences"]?.int
        threshold = o["threshold"]?.int
        entry = o["entry"]?.string
        truncated = o["truncated"]?.bool
        bodies = o["bodies"]?.array?.compactMap { $0.string } ?? []
    }
}

struct LearningEvent: Identifiable, Sendable, Equatable {
    let id: String
    let lessonID: String
    let eventType: String
    let ts: String
    let store: String
    let title: String
    /// The engine enum (claude-code, codex, cursor, g2, task, unknown); free
    /// text lives in `category`.
    let scope: String
    let category: String
    let engine: String
    let targetKind: String
    let targetID: String
    let targetVersion: String?
    let appliesTo: [String]
    let sourceRefs: [LearningSourceRef]
    let priorEventID: String?
    /// The check's verdict (`outcome.result`), and what was checked (`outcome.name`).
    /// The wire shape is `{ name, result, evaluator, ts }` (QA 2026-09-06).
    let outcome: String?
    let outcomeName: String?
    let provenance: String
    let ordinal: Int?
    let detail: LearningEventDetail?

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let id = o["event_id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        lessonID = o["lesson_id"]?.string ?? ""
        eventType = o["event_type"]?.string ?? ""
        ts = o["ts"]?.string ?? ""
        store = o["store"]?.string ?? ""
        title = o["title"]?.string ?? "(untitled)"
        scope = o["scope"]?.string ?? "unknown"
        category = o["category"]?.string ?? ""
        engine = o["engine"]?.string ?? "unknown"
        let target = o["target"]?.object
        targetKind = target?["kind"]?.string ?? ""
        targetID = target?["id"]?.string ?? ""
        targetVersion = target?["version"]?.string
        // applies_to entries are `{ kind, name, cadence, evidence }` objects from
        // the resolver (or plain strings); the row keeps name and cadence.
        appliesTo = o["applies_to"]?.array?.compactMap { entry -> String? in
            if let text = entry.string { return text }
            guard let object = entry.object else { return nil }
            let name = object["name"]?.string ?? object["path"]?.string ?? object["id"]?.string ?? ""
            let cadence = object["cadence"]?.string ?? ""
            guard !name.isEmpty else { return nil }
            return cadence.isEmpty ? name : "\(name) · \(cadence)"
        } ?? []
        sourceRefs = o["source_refs"]?.array?.compactMap { LearningSourceRef($0) } ?? []
        priorEventID = o["prior_event_id"]?.string
        outcome = o["outcome"]?.string ?? o["outcome"]?.object?["result"]?.string
        outcomeName = o["outcome"]?.object?["name"]?.string
        provenance = o["provenance"]?.string ?? ""
        ordinal = o["ordinal"]?.int
        detail = LearningEventDetail(o["detail"])
    }

    /// Task proposals come from the self-improvement queue; patterns from the
    /// correction journal. Both sit in To review until a later release can move
    /// them (0.5.190 is read-only: there is no Dismiss).
    var isTaskProposal: Bool { targetKind == "task-proposal" }
    var isPattern: Bool { eventType == "promotable" || targetKind == "pattern" }
    var needsReview: Bool { isTaskProposal || isPattern }

    var kindLabel: String {
        if isTaskProposal { return "Task proposal" }
        switch eventType {
        case "captured": return "Captured"
        case "proposed": return "Proposed"
        case "promotable": return "Promotable pattern"
        case "saved": return "Saved"
        case "retrieved": return "Retrieved"
        case "used": return "Used"
        case "checked": return "Checked"
        case "dismissed": return "Dismissed"
        case "reverted": return "Reverted"
        case "reopened": return "Reopened"
        case "consolidated": return "Consolidated"
        case "previewed": return "Previewed"
        default: return eventType.isEmpty ? "Event" : eventType
        }
    }

    var kindGlyph: String {
        if isTaskProposal { return "checklist" }
        switch eventType {
        case "captured", "saved": return "tray.and.arrow.down"
        case "proposed", "promotable": return "lightbulb"
        case "checked", "used", "retrieved": return "checkmark.circle"
        case "dismissed", "reverted": return "arrow.uturn.backward"
        case "reopened": return "arrow.clockwise"
        case "consolidated": return "square.stack"
        case "previewed": return "eye"
        default: return "sparkles"
        }
    }

    /// `scope · engine · time`, the row's second line.
    var rowSubtitle: String {
        [scope, engine == scope ? nil : engine, Self.shortStamp(ts)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The store, said the way the panel says it.
    var storeLabel: String {
        switch store {
        case "self_improvement_queue": return "Self-improvement queue"
        case "correction_journal": return "Correction journal"
        case "bot_memory": return "Bot memory"
        case "review_ledger": return "Review ledger"
        case "git_versions": return "Skill versions"
        case "eval_scores": return "Eval scores"
        case "reflect_log": return "Reflect log"
        case "capture_ledger": return "Capture ledger"
        default: return store.isEmpty ? "unknown store" : store
        }
    }

    /// A stamp that may arrive as epoch seconds (the graph's `created_at`) or as
    /// an ISO string, as `YYYY-MM-DD HH:MM`.
    static func stamp(_ value: JSONValue?) -> String? {
        if let text = value?.string, !text.isEmpty { return shortStamp(text) }
        guard let seconds = value?.double, seconds > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds))
    }

    /// `2026-09-06T05:00:00.000000+00:00` reads as `2026-09-06 05:00`.
    static func shortStamp(_ iso: String) -> String {
        guard iso.count >= 16 else { return iso }
        return String(iso.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }
}

struct LearningCoverage: Identifiable, Sendable, Equatable {
    let store: String
    let state: String
    let count: Int?

    var id: String { store }

    static func list(_ value: JSONValue?) -> [LearningCoverage] {
        guard let o = value?.object else { return [] }
        return o.keys.sorted().compactMap { key in
            guard let entry = o[key]?.object else { return nil }
            return LearningCoverage(store: key, state: entry["state"]?.string ?? "unknown", count: entry["count"]?.int)
        }
    }
}

/// The ingest lock as the pipeline reports it. The pid is advisory text the
/// holder wrote; the state comes from a real flock probe.
struct GraphLock: Sendable, Equatable {
    let state: String
    let ownerPID: Int?
    let error: String?

    init(_ value: JSONValue?) {
        let o = value?.object
        state = o?["state"]?.string ?? "unknown"
        ownerPID = o?["owner_pid"]?.int
        error = o?["error"]?.string
    }
}

/// One index build receipt (the current build or the last run).
struct IndexBuildReceipt: Sendable, Equatable {
    let state: String
    let reason: String?
    let startedAt: String?
    let endedAt: String?
    let pid: Int?
    let host: String?
    let error: String?
    let wallSeconds: Double?
    let nodeCount: Int?
    let edgeCount: Int?
    let buildSeq: Int?
    let peakRssMB: Int?

    init?(_ value: JSONValue?) {
        guard let o = value?.object else { return nil }
        state = o["state"]?.string ?? "unknown"
        reason = o["reason"]?.string
        startedAt = o["started_at"]?.string
        endedAt = o["ended_at"]?.string
        pid = o["pid"]?.int
        host = o["host"]?.string
        error = o["error"]?.string
        wallSeconds = o["wall_s"]?.double
        nodeCount = o["node_count"]?.int
        edgeCount = o["edge_count"]?.int
        buildSeq = o["build_seq"]?.int
        peakRssMB = o["peak_rss_mb"]?.int
    }
}

/// /api/context/graph/status as the server shapes it: counts, the source
/// topology, the queue census, the budget, the lock, the processor, and the
/// build receipts. Nothing here is a path.
struct GraphStatus: Sendable, Equatable {
    let entities: Int?
    let relationships: Int?
    let sourceUpdatedAt: String?
    let indexBuiltAt: String?
    let indexState: String
    let indexDegraded: Bool
    let ownerHost: String?
    let thisHost: String?
    let isOwner: Bool?
    let ownerState: String?
    let indexBuiltOnHost: String?
    let indexHostMismatch: Bool
    let queueLiveTotal: Int?
    let queuePending: Int?
    let queueFailed: Int?
    let queueDeferred: Int?
    let oldestPendingAt: String?
    let oldestPendingAgeSeconds: Int?
    let missingSources: Int?
    let conflictCopies: Int?
    let budgetUsed: Int?
    let budgetCap: Int?
    let lock: GraphLock
    let processorState: String?
    let processorCadenceSeconds: Int?
    let processorLastRunAt: String?
    let processorLastOutcome: String?
    let build: IndexBuildReceipt?
    let lastRun: IndexBuildReceipt?

    init(_ o: [String: JSONValue]) {
        entities = o["entities"]?.int
        relationships = o["relationships"]?.int
        sourceUpdatedAt = o["source_updated_at"]?.string
        indexBuiltAt = o["index_built_at"]?.string
        indexState = o["index_state"]?.string ?? "missing"
        indexDegraded = o["index_degraded"]?.bool ?? false
        let source = o["source"]?.object
        ownerHost = source?["owner_host"]?.string
        thisHost = source?["this_host"]?.string
        isOwner = source?["is_owner"]?.bool
        ownerState = source?["owner_state"]?.string
        indexBuiltOnHost = source?["index_built_on_host"]?.string
        indexHostMismatch = source?["index_host_mismatch"]?.bool ?? false
        let queue = o["queue"]?.object
        queueLiveTotal = queue?["live_total"]?.int
        queuePending = queue?["pending"]?.int
        queueFailed = queue?["failed"]?.int
        queueDeferred = queue?["deferred"]?.int
        oldestPendingAt = queue?["oldest_pending_at"]?.string
        oldestPendingAgeSeconds = queue?["oldest_pending_age_s"]?.int
        missingSources = queue?["missing_sources"]?.int
        conflictCopies = queue?["conflict_copies"]?.int
        let budget = o["budget"]?.object
        budgetUsed = budget?["used"]?.int
        budgetCap = budget?["cap"]?.int
        lock = GraphLock(o["lock"])
        let processor = o["processor"]?.object
        processorState = processor?["state"]?.string
        processorCadenceSeconds = processor?["cadence_s"]?.int
        processorLastRunAt = processor?["last_run_at"]?.string
        processorLastOutcome = processor?["last_outcome"]?.string
        build = IndexBuildReceipt(o["build"])
        lastRun = IndexBuildReceipt(o["last_run"])
    }

    /// What the Sync card says about the processor, by its reported state. The
    /// two sentences Miles asked for by name are pinned in ModelsContract.
    var processorLine: String {
        // The vocabulary is graph_context.PROCESSOR_STATES; every state has its sentence.
        switch processorState {
        case nil, "none": return "No processor configured on this Mac"
        case "installed-idle": return "Processor installed, no run recorded yet"
        case "cadence_unknown": return "Processor installed; cadence not readable"
        case "active": return "Processor active"
        case "contended": return "Processor contended: another ingest holds the lock"
        case "misconfigured": return "Processor misconfigured; check its LaunchAgent"
        case "stale": return "Processor installed; its last run is older than its cadence"
        case "stalled": return "Processor stalled: a run started and never finished"
        case "failed": return "Processor last run failed"
        case let state?: return "Processor \(state)"
        }
    }

    /// Build offer: only a missing or stale index invites a rebuild.
    var invitesIndexBuild: Bool { indexState == "missing" || indexState == "stale" }
}

struct GraphRelationship: Identifiable, Sendable, Equatable {
    let source: String
    let target: String
    let weight: Double?
    let description: String

    var id: String { "\(source)\u{1F}\(target)" }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let source = o["source"]?.string, let target = o["target"]?.string,
              !source.isEmpty, !target.isEmpty else { return nil }
        self.source = source
        self.target = target
        weight = o["weight"]?.double
        description = o["description"]?.string ?? ""
    }

    func other(than entity: String) -> String { source == entity ? target : source }
}

struct GraphNeighbor: Identifiable, Sendable, Equatable {
    let id: String
    let type: String
    let degree: Int?

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let id = o["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        type = o["type"]?.string ?? ""
        degree = o["degree"]?.int
    }
}

/// A graph entity, from a search hit (thin) or the entity route (with edges,
/// neighbors and the source-record status).
struct GraphEntity: Identifiable, Sendable, Equatable {
    let id: String
    let type: String
    let degree: Int?
    let description: String
    let descriptions: [String]
    let edges: [GraphRelationship]
    let neighbors: [GraphNeighbor]
    let totalRelationships: Int?
    let sourceStatus: String?
    let sourceCount: Int?
    let sourceResolved: Int?
    let createdAt: String?
    let firstSeenBuild: Int?

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let id = o["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        type = o["type"]?.string ?? ""
        degree = o["degree"]?.int
        description = o["description"]?.string ?? ""
        descriptions = Array((o["descriptions"]?.array?.compactMap { $0.string } ?? []).prefix(6))
        edges = o["edges"]?.array?.compactMap { GraphRelationship($0) }.sorted { ($0.weight ?? 0) > ($1.weight ?? 0) } ?? []
        neighbors = o["neighbors"]?.array?.compactMap { GraphNeighbor($0) } ?? []
        totalRelationships = o["total_relationships"]?.int
        sourceStatus = o["source_status"]?.string
        sourceCount = o["source_count"]?.int
        sourceResolved = o["source_resolved"]?.int
        // Epoch seconds on the wire (integerOrAbsent server-side), rendered as a date.
        createdAt = LearningEvent.stamp(o["created_at"])
        firstSeenBuild = o["first_seen_build"]?.int
    }

    private init(placeholderID id: String, type: String) {
        self.id = id
        self.type = type
        degree = nil
        description = ""
        descriptions = []
        edges = []
        neighbors = []
        totalRelationships = nil
        sourceStatus = nil
        sourceCount = nil
        sourceResolved = nil
        createdAt = nil
        firstSeenBuild = nil
    }

    /// A row for an entity known only by name (a neighbor chip), until the
    /// entity route fills it in. Never traps: an empty name is refused upstream
    /// and, should one arrive, becomes a row that the route answers not found.
    static func placeholder(_ id: String, type: String = "") -> GraphEntity {
        GraphEntity(placeholderID: id.isEmpty ? "(unnamed)" : id, type: type)
    }

    var sourceLine: String? {
        guard let sourceStatus else { return nil }
        switch sourceStatus {
        case "resolved": return "Source records: \(sourceResolved ?? 0) of \(sourceCount ?? 0) resolved"
        case "partial": return "Source records: \(sourceResolved ?? 0) of \(sourceCount ?? 0) resolved; the rest have no document id in the archive"
        case "unresolved": return "Source records: none of \(sourceCount ?? 0) carry a document id in the archive"
        default: return "Source records: \(sourceStatus)"
        }
    }
}

struct GraphPassage: Identifiable, Sendable, Equatable {
    let chunkID: String
    let docID: String?
    let order: Int?
    let excerpt: String
    let sourceStatus: String?
    let sourceKey: String?
    let sourceTitle: String?
    let sourceDate: String?
    let sourceSummary: String?

    var id: String { chunkID }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let chunkID = o["chunk_id"]?.string, !chunkID.isEmpty else { return nil }
        self.chunkID = chunkID
        docID = o["doc_id"]?.string
        order = o["order"]?.int
        excerpt = o["excerpt"]?.string ?? ""
        let source = o["source"]?.object
        sourceStatus = source?["status"]?.string
        sourceKey = source?["key"]?.string
        sourceTitle = source?["title"]?.string
        sourceDate = source?["date"]?.string
        sourceSummary = source?["summary"]?.string
    }
}

/// What each Activity chip may mark, from the helper's `activity-signals`. A
/// NUMBER means needs you, a DOT means something newer than the cursor the app
/// keeps per section. Every count is optional: an absent source is no mark.
struct ActivitySignals: Sendable, Equatable {
    struct Mark: Sendable, Equatable {
        let needsYou: Int?
        let newest: String?
        let inboxIDs: [String]
        let source: String
    }

    let marks: [String: Mark]
    let legend: String

    init(_ details: [String: JSONValue]) {
        var marks: [String: Mark] = [:]
        for (section, value) in details {
            guard let o = value.object, o["source"]?.string != nil else { continue }
            marks[section] = Mark(
                needsYou: o["needsYou"]?.int,
                newest: o["newest"]?.string,
                inboxIDs: o["inboxIDs"]?.array?.compactMap { $0.string } ?? [],
                source: o["source"]?.string ?? ""
            )
        }
        self.marks = marks
        legend = details["legend"]?.string ?? ""
    }

    func mark(_ section: String) -> Mark? { marks[section] }

    /// The number a chip shows, or nil. Zero is not a number worth a mark, and
    /// an absent count (older server, missing source) is never zero.
    func number(for section: String, unseenInbox: Int = 0) -> Int? {
        guard let mark = marks[section] else { return nil }
        let base = mark.needsYou
        if section == "tasks" {
            guard base != nil || unseenInbox > 0 else { return nil }
            let total = (base ?? 0) + unseenInbox
            return total > 0 ? total : nil
        }
        guard let base, base > 0 else { return nil }
        return base
    }

    /// A stored cursor is trusted only in the stamp shape the helper writes
    /// (a four-digit year first); anything else, including a future date past a
    /// day of clock skew, reads as never opened (QA 2026-09-06).
    static func validCursor(_ raw: String?, now: Date = Date()) -> String? {
        // The shape is `YYYY-MM-DD…`; an epoch string also starts with digits.
        guard let raw, raw.count >= 10 else { return nil }
        let parts = raw.prefix(10).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let tomorrow = formatter.string(from: now.addingTimeInterval(86_400))
        return String(raw.prefix(10)) > tomorrow ? nil : raw
    }

    /// A dot only when a newer item exists: no stamp, no dot; a stamp and no
    /// cursor (never opened) is new by definition.
    static func hasNewer(newest: String?, cursor: String?) -> Bool {
        guard let newest, !newest.isEmpty else { return false }
        guard let cursor, !cursor.isEmpty else { return true }
        return newest > cursor
    }
}

/// A global keyboard shortcut that opens the Activity window (0.5.190, Miles
/// 2026-09-06). Carbon flag values, so the struct stays pure and testable
/// without HIToolbox: cmd 0x100, shift 0x200, option 0x800, control 0x1000.
struct HotKeyCombo: Equatable, Sendable {
    static let command: UInt32 = 0x100
    static let shift: UInt32 = 0x200
    static let option: UInt32 = 0x800
    static let control: UInt32 = 0x1000
    static let keyCodeKey = "activityHotKey.keyCode"
    static let modifiersKey = "activityHotKey.modifiers"
    static let enabledKey = "activityHotKey.enabled"
    /// Control-Option-Command-A: three modifiers, so no app's own shortcut is shadowed.
    static let defaultCombo = HotKeyCombo(keyCode: 0, modifiers: control | option | command)!

    let keyCode: UInt32
    let modifiers: UInt32

    /// A shortcut with no Command, Control or Option would capture plain typing.
    init?(keyCode: UInt32, modifiers: UInt32) {
        guard modifiers & (Self.command | Self.control | Self.option) != 0 else { return nil }
        self.keyCode = keyCode
        self.modifiers = modifiers & (Self.command | Self.shift | Self.option | Self.control)
    }

    /// NSEvent modifier flags to Carbon flags (AppKit is already imported here).
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= command }
        if flags.contains(.shift) { value |= shift }
        if flags.contains(.option) { value |= option }
        if flags.contains(.control) { value |= control }
        return value
    }

    /// Menu-style rendering: ⌃⌥⇧⌘ then the key.
    var display: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// ANSI key codes for the US layout, the way menu shortcuts name them.
    static func keyName(_ code: UInt32) -> String {
        let letters: [UInt32: String] = [0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L",
                                         46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W",
                                         7: "X", 16: "Y", 6: "Z", 29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
                                         28: "8", 25: "9", 49: "Space", 36: "Return", 48: "Tab", 53: "Esc", 51: "Delete",
                                         123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
                                         97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
                                         27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`"]
        return letters[code] ?? "Key \(code)"
    }

    /// nil when the user turned the hotkey off; the default when nothing was ever set.
    static func load(from defaults: UserDefaults = .standard) -> HotKeyCombo? {
        if defaults.object(forKey: enabledKey) != nil, !defaults.bool(forKey: enabledKey) { return nil }
        guard defaults.object(forKey: keyCodeKey) != nil else { return defaultCombo }
        return HotKeyCombo(keyCode: UInt32(clamping: defaults.integer(forKey: keyCodeKey)),
                           modifiers: UInt32(clamping: defaults.integer(forKey: modifiersKey))) ?? defaultCombo
    }

    static func save(_ combo: HotKeyCombo?, to defaults: UserDefaults = .standard) {
        defaults.set(combo != nil, forKey: enabledKey)
        if let combo {
            defaults.set(Int(combo.keyCode), forKey: keyCodeKey)
            defaults.set(Int(combo.modifiers), forKey: modifiersKey)
        }
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
    let sourceType: String?
    let provenanceState: String?
    let chunkFiles: Int
    let ageHours: Double?
    let recovered: Bool
    let recovering: Bool
    let recoverable: Bool
    let expiresAt: String

    var id: String { sessionId }

    var label: String {
        let source = PhoneMeetingCapture.protected(sessionId, sourceType: sourceType) ? "iPhone microphone · " : ""
        let chunks = chunkFiles == 1 ? "1 chunk" : "\(chunkFiles) chunks"
        if recovering { return "\(source)\(shortId) · recovering · \(chunks)" }
        if let ageHours {
            return "\(source)\(shortId) · \(chunks) · \(ageHours)h"
        }
        return "\(source)\(shortId) · \(chunks)"
    }

    var shortId: String {
        sessionId.count > 18 ? String(sessionId.prefix(18)) + "…" : sessionId
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let sessionId = o["sessionId"]?.string, !sessionId.isEmpty else { return nil }
        self.sessionId = sessionId
        sourceType = o["sourceType"]?.string
        provenanceState = o["provenanceState"]?.string
        chunkFiles = o["chunkFiles"]?.int ?? Int(o["chunkFiles"]?.string ?? "") ?? 0
        ageHours = o["ageHours"]?.double
        recovered = o["recovered"]?.bool ?? false
        recovering = o["recovering"]?.bool ?? false
        recoverable = (!PhoneMeetingCapture.protected(sessionId, sourceType: sourceType) || (PhoneMeetingCapture.validID(sessionId) && sourceType == "iphone_microphone" && provenanceState == "admitted")) && (o["recoverable"]?.bool ?? (!recovered && chunkFiles >= 2))
        expiresAt = o["expiresAt"]?.string ?? ""
    }
}

/// 0.5.227. One live meeting as COS Control sees it: is its audio still reaching this Mac?
/// `state` is reaching | stopped | paused | delayed | phone_quiet | ending; stopped and paused alert.
struct MeetingAudioWatch: Identifiable, Sendable, Equatable {
    let sessionId: String
    let state: String
    let alert: Bool
    let silenceSeconds: Int
    let heartbeatAgeSeconds: Int?
    let lastChunkAt: Date?
    let startedAt: Date?
    /// While paused, the phone's capture pause reason: budget | overflow | quota | failed | permanent, or a re-arm refusal.
    let pauseReason: String?
    let visibilityState: String?
    let bridgeProbe: String?

    var id: String { sessionId }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let sessionId = o["sessionId"]?.string, !sessionId.isEmpty,
              let state = o["state"]?.string, !state.isEmpty else { return nil }
        self.sessionId = sessionId
        self.state = state
        alert = o["alert"]?.bool ?? (state == "stopped" || state == "paused")
        silenceSeconds = o["silenceSeconds"]?.int ?? 0
        heartbeatAgeSeconds = o["heartbeatAgeSeconds"]?.int
        lastChunkAt = o["lastChunkAt"]?.string.flatMap { ISO8601DateFormatter().date(from: $0) }
        startedAt = o["startedAt"]?.string.flatMap { ISO8601DateFormatter().date(from: $0) }
        pauseReason = o["pauseReason"]?.string
        visibilityState = o["visibilityState"]?.string
        bridgeProbe = o["bridgeProbe"]?.string
    }

    static func minutes(_ seconds: Int) -> String {
        let value = max(1, Int((Double(seconds) / 60).rounded()))
        return "\(value) min"
    }

    /// Storage limits and storage failures read differently; the phone also pauses for other reasons.
    private var pauseKind: String {
        switch pauseReason {
        case "budget", "overflow", "quota": return "storage"
        case "failed", "permanent": return "storageError"
        default: return "other"
        }
    }

    /// "Meeting audio", with its start time when more than one meeting is live.
    func rowLabel(amongLive count: Int) -> String {
        guard count > 1, let startedAt else { return "Meeting audio" }
        return "Meeting audio, \(startedAt.formatted(date: .omitted, time: .shortened))"
    }

    /// The panel's Meeting audio value.
    var rowValue: String {
        switch state {
        case "stopped": return "Stopped \(Self.minutes(silenceSeconds)) ago"
        case "paused": return "Paused on phone \(Self.minutes(silenceSeconds))"
        case "delayed": return "Phone catching up"
        case "phone_quiet": return "No word from phone \(Self.minutes(silenceSeconds))"
        case "ending": return "Ending"
        default: return "Reaching this Mac"
        }
    }

    /// The amber line under an alerting row.
    var panelCaption: String {
        guard state == "paused" else {
            let since = lastChunkAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "the last chunk"
            return "No audio has reached this Mac since \(since). Unlock the phone and open COS to reconnect."
        }
        switch pauseKind {
        case "storage": return "The phone paused recording to protect its storage. Open COS on the phone."
        case "storageError": return "A storage error on the phone paused recording. Open COS on the phone."
        default: return "The phone paused recording. Open COS on the phone."
        }
    }

    var notificationTitle: String {
        state == "paused" ? "Meeting audio paused on your phone" : "Meeting audio stopped reaching your Mac"
    }

    /// Tells two live meetings apart.
    var notificationSubtitle: String? {
        startedAt.map { "Meeting started \($0.formatted(date: .omitted, time: .shortened))" }
    }

    var notificationBody: String {
        guard state == "paused" else {
            return "No audio from your phone for \(Self.minutes(silenceSeconds)). Unlock your phone and open COS to reconnect."
        }
        let ago = Self.minutes(silenceSeconds)
        switch pauseKind {
        case "storage": return "Phone storage paused the recording \(ago) ago. Open COS on your phone."
        case "storageError": return "A storage error on your phone paused the recording \(ago) ago. Open COS on your phone."
        default: return "Your phone paused the recording \(ago) ago. Open COS on your phone."
        }
    }
}

/// 0.5.228. What one check changes: notifications to post, and sessions whose audio reached this
/// Mac again, so their delivered notification is out of date.
struct MeetingAudioAlertUpdate: Sendable, Equatable {
    var post: [MeetingAudioWatch] = []
    var resolved: [String] = []
}

/// 0.5.227. One notification per drop while COS Control stays open; a relaunch mid-drop notifies again.
/// A meeting notifies when it enters `stopped` or `paused`, again only after its audio reaches this Mac
/// again, and is forgotten once it is no longer live.
struct MeetingAudioAlertLedger: Sendable, Equatable {
    private(set) var notified: [String: String] = [:]

    mutating func update(_ watches: [MeetingAudioWatch]) -> MeetingAudioAlertUpdate {
        var update = MeetingAudioAlertUpdate()
        var live: Set<String> = []
        for watch in watches {
            live.insert(watch.sessionId)
            if watch.alert {
                if notified[watch.sessionId] != watch.state {
                    notified[watch.sessionId] = watch.state
                    update.post.append(watch)
                }
            } else if watch.state == "reaching" {
                if notified.removeValue(forKey: watch.sessionId) != nil {
                    update.resolved.append(watch.sessionId)
                }
            }
        }
        for id in notified.keys where !live.contains(id) { notified[id] = nil }
        return update
    }
}

/// A live recording whose phone went quiet. Not quarantined yet — do not
/// delete its session files. Save it with POST /api/meeting/save; the
/// quarantine recover route will 404 until the 4h cutoff.
struct StrandedCapture: Identifiable, Sendable {
    /// 0.5.337 (loop audit W16): the server can still list a capture this Mac discarded (its own discard retries ran out,
    /// or it was not idle yet); it is not offered again.
    static func shown(_ rows: [StrandedCapture], discarded: Set<String>) -> [StrandedCapture] { rows.filter { !discarded.contains($0.sessionId) } }
    let sessionId: String
    let sourceType: String?
    let speakerPolicy: String?
    let idleMinutes: Int
    let capturedMinutes: Int
    let chunks: Int
    let canSave: Bool
    let transcriptState: String

    var id: String { sessionId }

    var label: String {
        if PhoneMeetingCapture.protected(sessionId, sourceType: sourceType) { return "iPhone microphone · audio retained · finish on iPhone" }
        let idle = idleMinutes == 1 ? "1 min idle" : "\(idleMinutes) min idle"
        if transcriptState == "no_speech" { return "\(shortId) · No usable speech detected; audio retained" }
        if !canSave { return "\(shortId) · Transcript unavailable; audio retained" }
        return "\(shortId) · \(idle) · ready to save"
    }

    var shortId: String {
        sessionId.count > 18 ? String(sessionId.prefix(18)) + "…" : sessionId
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let sessionId = o["sessionId"]?.string, !sessionId.isEmpty else { return nil }
        self.sessionId = sessionId
        sourceType = o["sourceType"]?.string
        speakerPolicy = o["speakerPolicy"]?.string
        idleMinutes = o["idleMinutes"]?.int ?? Int(o["idleMinutes"]?.string ?? "") ?? 0
        capturedMinutes = o["capturedMinutes"]?.int ?? Int(o["capturedMinutes"]?.string ?? "") ?? 0
        chunks = o["chunks"]?.int ?? Int(o["chunks"]?.string ?? "") ?? 0
        canSave = !PhoneMeetingCapture.protected(sessionId, sourceType: sourceType) && (o["canSave"]?.bool ?? (chunks > 0))
        transcriptState = o["transcriptState"]?.string ?? (chunks > 0 ? "ready" : "unknown")
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

/// One turn parked behind a thread (0.5.235; server 6.48.1's queued-turns GET).
///
/// `preview` is the server's 80-character head of the prompt: the full text is
/// never on the wire by design. `text` is what Control draws: the full prompt
/// when this Mac queued the turn (kept in a local ledger by `clientTurnId`),
/// the preview otherwise, so a turn the lens or the phone parked still reads.
struct QueuedSessionTurn: Identifiable, Sendable, Equatable {
    let clientTurnId: String
    let status: String
    /// 0 is next; -1 once the row is no longer waiting.
    let position: Int
    /// Epoch milliseconds.
    let queuedAt: Double
    let attempts: Int
    let preview: String
    let reason: String
    let settledAt: Double

    var id: String { clientTurnId }
    var isWaiting: Bool { status == "waiting" }
    var isDelivering: Bool { status == "delivering" }
    /// A cancel can reach only a waiting row; the adapter holds a delivering one.
    var cancellable: Bool { isWaiting }
    /// Rows a person still needs to see: what is parked, what is in the adapter's
    /// hands, and what the server gave up on. Delivered and cancelled rows are
    /// the transcript's and the user's own doing; they drop off the list.
    var showsInQueue: Bool { ["waiting", "delivering", "refused", "expired"].contains(status) }

    /// A parked turn has not been delivered. Keep the reason visible instead of promising a turn-end send.
    var waitingDetail: String? {
        guard isWaiting, !reason.isEmpty else { return nil }
        switch reason {
        case "native_target_fenced": return "An earlier send is unconfirmed. Check the session on your Mac before releasing its fence."
        case "native_head_unavailable": return "COS cannot read the latest transcript. Open the original session, then check again."
        case "native_target_busy", "native_turn_in_progress", "native_thread_working": return "Waiting for this session to become available."
        case "live_desktop_process": return "The AI app still owns this session. COS is waiting for it to become available."
        default: return "Waiting: " + reason.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// "Next", "2nd in line", "Delivering…", "Refused · delivery attempts exhausted".
    var stateLine: String {
        switch status {
        case "waiting":
            switch position {
            case 0: return "Next"
            case 1: return "2nd in line"
            case 2: return "3rd in line"
            default: return position > 2 ? "\(position + 1)th in line" : "Waiting"
            }
        case "delivering": return "Delivering…"
        case "refused": return reason.isEmpty ? "Refused" : "Refused · \(reason.replacingOccurrences(of: "_", with: " "))"
        case "expired": return "Expired · not delivered"
        default: return status.capitalized
        }
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let id = o["clientTurnId"]?.string, !id.isEmpty else { return nil }
        clientTurnId = id
        status = o["status"]?.string ?? "waiting"
        position = o["position"]?.int ?? -1
        queuedAt = o["queuedAt"]?.double ?? 0
        attempts = o["attempts"]?.int ?? 0
        preview = o["preview"]?.string ?? ""
        reason = o["reason"]?.string ?? ""
        settledAt = o["settledAt"]?.double ?? 0
    }

    /// What a cancel answer means (0.5.236). The server answers 200 to a cancel
    /// of a row that already settled, with that row's final status riding
    /// along; only "cancelled" (or no status at all, an older server) means the
    /// message will not be sent. A "delivered" status on a 200 is the too-late
    /// case, and an edit built on it would send the message twice.
    static func cancelVerdict(state: String, status: String) -> String {
        switch state {
        case "cancelled": return status.isEmpty || status == "cancelled" ? "cancelled" : "already_delivering"
        case "already_delivering", "unknown_turn": return state
        default: return "unavailable"
        }
    }

    /// The rows the pet card shows: waiting and delivering only, in queue order,
    /// capped so the card stays a card. The pane shows everything `showsInQueue`.
    static func cardRows(_ turns: [QueuedSessionTurn], limit: Int = 3) -> [QueuedSessionTurn] {
        Array(turns.filter { $0.isWaiting || $0.isDelivering }
            .sorted { ($0.isWaiting ? 0 : 1, $0.position, $0.queuedAt) < ($1.isWaiting ? 0 : 1, $1.position, $1.queuedAt) }
            .prefix(limit))
    }
}

/// Where a message sent from the pet is (0.5.234). One card, one phase.
///
/// `landed` is the live hand-off: the session's own process took the message
/// into its window (server 6.49.0 answers 200 with `via: live`). `queued` is
/// the 202: the server opens the thread and the reply lands in its transcript.
/// Both are "the session has it"; the card shows the word, pulses, and closes
/// itself after `settleSeconds`. `failed` keeps the draft so the user can fix
/// and resend; `blocked` is the attachability probe saying no before a send,
/// with the send disabled and the server's copy shown verbatim.
enum PetSendPhase: Equatable, Sendable {
    case idle
    case sending
    case landed(String)
    case queued(String)
    case failed(String)
    case blocked(String)

    /// How long an accepted card stays before it closes on its own.
    static let settleSeconds: Double = 2.8

    /// The session has the message. The card pulses on this and the draft clears.
    var accepted: Bool {
        switch self {
        case .landed, .queued: true
        default: false
        }
    }

    var isSending: Bool { if case .sending = self { true } else { false } }

    var isBlocked: Bool { if case .blocked = self { true } else { false } }

    /// The one line under the field. Nothing at rest.
    var statusLine: String? {
        switch self {
        case .idle: nil
        case .sending: "Sending…"
        case .landed(let copy), .queued(let copy), .failed(let copy), .blocked(let copy): copy
        }
    }
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
    /// 0.5.229. "job" when COS automation started this run (the helper's scheduledJobOrigin), with
    /// the job's name ("Meeting watcher") and the script that ran Claude ("sync_meetings.py").
    let origin: String
    let jobLabel: String
    let jobScript: String
    /// 0.5.232, glasses-server 6.48.0+: the server's one derived state and its source
    /// (`agent_state`/`state_source` on the wire; the helper carries them camelCase). Empty
    /// on an older server, where `state` is the helper's own reading.
    let agentState: String
    let stateSource: String
    let stateSince: String
    let waitingKind: String
    let waitingDetail: String
    let failure: String
    let lastReply: String
    /// Follow-ups queued at this session and not yet delivered (6.48.1's `queued_turns`).
    let queuedTurns: Int
    /// 0.5.259: the transcript holds a question to the user still open (the helper's `waitingOnUser`), so a wait the
    /// helper read from the transcript is known, not inferred from quiet.
    let waitingOnUser: Bool

    /// 0.5.247: a Work handoff names this session. The COS server starts every Work New session with `claude -p`,
    /// and the helper calls any run the server starts "COS server", a scheduled job, so Miles's handoff showed in
    /// Sessions as `COS server · Scheduled job` with no transcript and no Continue (2026-09-29). Work is his work.
    var fromWork = false
    /// 0.5.250: a Work New session the COS server is still running (its job-channel receipt has not finished). The
    /// server is writing it, so nothing else may: no Open in platform, no Continue, no pet tap into the app (QA,
    /// 2026-09-29: two writers into one Claude session).
    var workRunning = false
    /// 0.5.250: the name came from a title someone gave the session (Claude Desktop's, or a `custom-title` in its
    /// transcript, such as a Work session named after its task), never from its first prompt. Such a row is never
    /// hidden as a warm-up, even when it is called "Ready".
    var namedTitle = false
    /// Activity Today (B1): the pending AskUserQuestion's own words, from the helper's transcript tail read (`waitingQuestion`).
    var waitingQuestion = ""
    var waitingQuestionCount = 0

    var isScheduledJob: Bool { origin == "job" && !fromWork }
    /// Only the COS server may write this session now: a scheduled job, or a Work New session still running.
    var heldByServer: Bool { isScheduledJob || workRunning }

    /// The list with every session a Work handoff names (receipt `sessionID`, `provider:native`) marked as work.
    /// 0.5.250: matched with `sameSession`, since the live list can give a Claude session by its first 8 characters while
    /// the receipt holds the full id its job named (from the start of the run with server 6.58.2).
    /// `runningWorkSessionIDs`: the sessions of Work New sessions the COS server is still running (WorkHandoffStore.serverHolds).
    static func markingWork(_ sessions: [ClaudeSession], workSessionIDs: Set<String>,
                            runningWorkSessionIDs: Set<String> = []) -> [ClaudeSession] {
        sessions.map { session in
            var next = session
            next.fromWork = workSessionIDs.contains { sameSession($0, session.id) }
            next.workRunning = runningWorkSessionIDs.contains { sameSession($0, session.id) }
            return next
        }
    }

    /// 0.5.250: two `provider:native` ids name the same session when the provider matches and the native ids are equal,
    /// or one is the first 8 or more characters of the other (the live list's short Claude id).
    static func sameSession(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: ":", maxSplits: 1).map { String($0).lowercased() }
        let y = b.split(separator: ":", maxSplits: 1).map { String($0).lowercased() }
        guard x.count == 2, y.count == 2, x[0] == y[0], !x[1].isEmpty, !y[1].isEmpty else { return false }
        if x[1] == y[1] { return true }
        let (short, long) = x[1].count <= y[1].count ? (x[1], y[1]) : (y[1], x[1])
        return short.count >= 8 && long.hasPrefix(short)
    }

    /// The chip word. `error` is the failed state (a rate limit, an overloaded engine),
    /// which reads FAILED and never "Running"; `waiting` names what it waits on when the
    /// server said (a permission, a question, a plan); a queued follow-up is counted.
    var stateLabel: String {
        let base: String = switch state {
        case "waiting": waitingKindLabel.isEmpty ? "Waiting" : "Waiting · \(waitingKindLabel)"
        case "stale": "Stale"
        case "running": "Running"
        case "error": failure.isEmpty ? "Failed" : "Failed · \(failure.replacingOccurrences(of: "_", with: " "))"
        case "recent": ""
        default: "Running"
        }
        if queuedTurns > 0 {
            let queued = "\(queuedTurns) queued"
            return base.isEmpty ? queued : base + " · " + queued
        }
        return base
    }

    /// "Permission: Bash git push", "Question", "Plan approval", "Input".
    var waitingKindLabel: String {
        let detail = waitingDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        switch waitingKind {
        case "permission": return detail.isEmpty ? "Permission" : "Permission: \(detail)"
        case "question": return "Question"
        case "plan": return "Plan approval"
        case "mcp_input": return "Input"
        case "": return detail.isEmpty ? "" : detail
        default: return detail.isEmpty ? waitingKind.capitalized : "\(waitingKind.capitalized): \(detail)"
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
        if isScheduledJob, !jobLabel.isEmpty { return jobLabel }
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

    /// A warm-up is known by its first prompt, never by a title someone gave the session (0.5.250).
    var isKeepWarm: Bool {
        !namedTitle && Self.isKeepWarmSessionTitle(name)
    }

    /// Live pet gate: keep-warm off, then `alive` or Running/Waiting.
    /// Not `showsStateChip` — `stale` chips and `alive && recent` does not.
    var isPetVisible: Bool {
        if isKeepWarm { return false }
        if alive { return true }
        return state == "running" || state == "waiting" || state == "error"
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
        case "error": "Failed"      // 0.5.232: never "Idle" for a failed turn
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

    /// Where the WAITING pill sends you (0.5.158). One waiting session has
    /// nothing to choose, so the pill jumps straight into it. Two or more and
    /// jumping picks an arbitrary session while silently ignoring the rest —
    /// exactly the state where you most need to choose — so the pill opens
    /// the live list instead, where WAITING has its own amber section.
    static func petWaitingJumpTarget(_ sessions: [ClaudeSession]) -> ClaudeSession? {
        let waiting = sessions.filter(needsAPerson)
        return waiting.count == 1 ? waiting[0] : nil
    }

    /// Mission-rows sectioning (0.5.155, design B): the live list groups by
    /// weight — running rich, waiting amber, idle receded. Pure so the
    /// contract executes the grouping; within each section the sorted input
    /// order (petVisibleSessions) is preserved.
    /// 0.5.232: a failed turn (`error`) rides the WAITING channel. It needs a person
    /// the way a question does, and the idle bucket would print it as idle.
    static func needsAPerson(_ session: ClaudeSession) -> Bool {
        session.state == "waiting" || session.state == "error"
    }

    static func petSections(_ sessions: [ClaudeSession])
        -> (running: [ClaudeSession], waiting: [ClaudeSession], idle: [ClaudeSession]) {
        (sessions.filter(\.isPetWorking),
         sessions.filter(needsAPerson),
         sessions.filter { !$0.isPetWorking && !needsAPerson($0) })
    }

    private static func petLiveRank(_ session: ClaudeSession) -> Int {
        switch session.state {
        case "running": 0
        case "waiting", "error": 1
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
        // 0.5.229: a scheduled job's live line is the script it runs.
        if isScheduledJob { return jobScript.isEmpty ? "running" : jobScript }
        if state == "waiting" {
            // 0.5.232: the server names the kind (a permission with its command, a
            // question, a plan); the registry's `waitingFor` and "needs you" stay as before.
            if !waitingKindLabel.isEmpty { return waitingKindLabel.lowercased() }
            let need = waitingFor.trimmingCharacters(in: .whitespacesAndNewlines)
            return need.isEmpty || need == "user" ? "needs you" : need
        }
        if state == "error" {
            return failure.isEmpty ? "failed" : "failed · " + failure.replacingOccurrences(of: "_", with: " ")
        }
        let summary = discussionSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? "working" : summary
    }

    /// 0.5.226: the second line of an idle-alive row. petLiveLine falls back to "working",
    /// which the pet printed under IDLE for every session without a summary (Miles,
    /// 2026-09-14); an idle row falls back to "idle".
    var petIdleLine: String {
        let summary = discussionSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? "idle" : summary
    }

    /// What this session DID, for a row that has already finished. petLiveLine
    /// answers "what is it doing" and falls back to "working", which is wrong
    /// once nothing is running; this falls back to "Finished", the literal the
    /// finished list used to print for every row on every line.
    var petOutcomeLine: String {
        let summary = discussionSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? "Finished" : summary
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

    var petProviderMark: PetProvider.Mark { PetProvider.mark(provider) }

    var providerLabel: String {
        if isScheduledJob { return "Scheduled job" }
        switch provider {
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        default: return "Claude"
        }
    }

    var createdDate: Date? { Self.parseStamp(createdAt) }
    var updatedDate: Date? { Self.parseStamp(updatedAt) }

    /// 0.5.337 (performance audit B1): the two shared ISO 8601 formatters (WorkIntakeItem.stamp), made once. This built two
    /// new ISO8601DateFormatters on every read, and the Sessions list reads it for every row on every redraw.
    static func parseStamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return WorkIntakeItem.stamp(trimmed)
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
        origin = o["origin"]?.string ?? ""
        jobLabel = o["jobLabel"]?.string ?? ""
        jobScript = o["jobScript"]?.string ?? ""
        agentState = o["agentState"]?.string ?? ""
        stateSource = o["stateSource"]?.string ?? ""
        stateSince = o["stateSince"]?.string ?? ""
        waitingKind = o["waitingKind"]?.string ?? ""
        waitingDetail = o["waitingDetail"]?.string ?? ""
        failure = o["failure"]?.string ?? ""
        lastReply = o["lastReply"]?.string ?? ""
        queuedTurns = o["queuedTurns"]?.int ?? 0
        waitingOnUser = o["waitingOnUser"]?.bool ?? false
        namedTitle = o["namedTitle"]?.bool ?? false
        waitingQuestion = o["waitingQuestion"]?.string ?? ""
        waitingQuestionCount = o["waitingQuestionCount"]?.int ?? 0
    }

    static func isKeepWarmSessionTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t == "ready" { return true }
        return t.hasPrefix("this is an automated local readiness check")
    }
}

/// A domain the SERVER resolved, from the user's own config and their own
/// `operations/` tree. The picker used to hardcode four names — one user's
/// business units — so a second COS install had nothing it could file against.
struct DomainOption: Identifiable, Sendable, Equatable {
    let name: String
    let label: String
    let abbr: String

    var id: String { name }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let name = o["name"]?.string, !name.isEmpty else { return nil }
        self.name = name
        // Fall back to the key rather than rendering an empty row.
        label = o["label"]?.string ?? name
        abbr = o["abbr"]?.string ?? String(name.prefix(2)).uppercased()
    }
}

/// Meeting-derived Work that is not on the board yet (server 6.57.0 `/api/work-intake`): suggested links, other
/// people's asks, and his own items that need a look. A producer scores them; nothing here is written to tasks
/// until the user accepts it.
struct WorkIntakeItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case link, ask }
    let id: String
    let kind: Kind
    let status: String
    let producedAt: String
    /// 0.5.313: `producedAt` read once, when the row is decoded. The Work tab's title asked for every row's date on every
    /// redraw, with two new date formatters each time (3% of the main thread while idle, 2026-10-15 22:30 sample).
    let producedDate: Date?
    let meeting: WorkMeetingReference
    let confidence: Double
    let text: String
    let owner: String?
    let ownerIsMiles: Bool
    let pullTitle: String?
    let pullConfidence: Double?
    /// Why an item landed in Review (server 6.57.0): `outside_window`, `unclear_task` or `owner_uncertain`.
    let reason: String?
    let askEvidenceText: String?

    /// ISO 8601 with or without fractional seconds. The formatters are made once (they are thread-safe to read with).
    nonisolated(unsafe) private static let fractionStamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let plainStamp = ISO8601DateFormatter()
    static func stamp(_ text: String) -> Date? { fractionStamp.date(from: text) ?? plainStamp.date(from: text) }
    var isReview: Bool { status == "review" }
    /// A short reason shown on a Review row; an unknown reason from a newer server shows nothing.
    var reasonLabel: String? {
        switch reason {
        case "outside_window": return "older meeting"
        case "unclear_task": return "may not be a task"
        case "owner_uncertain": return "owner unclear"
        default: return nil
        }
    }
    var isSuggestedLink: Bool { kind == .link && status == "suggested" }
    var isAsk: Bool { kind == .ask && status == "ask" }
    var percent: String { "\(Int((confidence * 100).rounded()))%" }
    var pullPercent: String? { pullConfidence.map { "\(Int(($0 * 100).rounded()))%" } }
    var meetingDate: String {
        let prefix = String(meeting.filename.prefix(10))
        guard prefix.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
              let month = Int(prefix.dropFirst(5).prefix(2)), let day = Int(prefix.suffix(2)) else { return "" }
        return "\(month)/\(day)"
    }

    init?(_ value: JSONValue) {
        guard let row = value.object,
              let id = row["id"]?.string, id.range(of: "^wi_[a-f0-9]{32}$", options: .regularExpression) != nil,
              let kind = row["kind"]?.string.flatMap(Kind.init(rawValue:)),
              let status = row["status"]?.string, ["suggested", "review", "ask", "accepted", "dismissed"].contains(status),
              let meeting = WorkMeetingReference(row["meeting"]),
              let confidence = row["confidence"]?.double, (0...1).contains(confidence) else { return nil }
        let task = row["task"]?.object
        let text = kind == .link ? task?["text"]?.string : row["text"]?.string
        guard let text, !text.isEmpty else { return nil }
        producedAt = row["producedAt"]?.string ?? ""
        producedDate = Self.stamp(producedAt)
        self.id = id; self.kind = kind; self.status = status; self.meeting = meeting; self.confidence = confidence; self.text = text
        owner = row["owner"]?.string
        ownerIsMiles = row["ownerIsMiles"]?.bool == true
        let pull = row["pull"]?.object
        pullTitle = pull?["title"]?.string
        pullConfidence = pull?["p"]?.double
        reason = row["reason"]?.string
        if let evidence = row["askEvidence"]?.object {
            var lines: [String] = []
            if let question = evidence["question"]?.string { lines.append("You asked: " + question) }
            if let answer = evidence["answer"]?.string { lines.append("Original answer: " + answer + (evidence["answerTruncated"]?.bool == true ? "\nRetained answer excerpt; open the meeting for the full answer." : "")) }
            for value in evidence["sources"]?.array ?? [] {
                guard let source = value.object else { continue }
                let id = source["id"]?.string ?? ""
                let title = source["title"]?.string ?? ""
                let quote = source["text"]?.string ?? ""
                let suffix = source["truncated"]?.bool == true ? "\nRetained source excerpt." : ""
                lines.append("[\(id)] \(title)\n\(quote)\(suffix)")
            }
            askEvidenceText = lines.joined(separator: "\n\n")
        } else { askEvidenceText = nil }
    }
}

struct WorkIntakeSnapshot: Sendable {
    var available: Bool
    var message: String?
    var items: [WorkIntakeItem]
    var cardCreation: Bool
    var linkWrites: Bool
    /// The server's task bridge did not answer (accept is refused until it does), not an older server.
    var bridgeUnavailable = false
    /// Server 6.57.0 or later whose Intake store is down (503): shown with its reason, never hidden.
    var storeUnavailable = false

    static let unavailable = WorkIntakeSnapshot(available: false, message: nil, items: [], cardCreation: false, linkWrites: false)
    func newItems(now: Date = Date()) -> [WorkIntakeItem] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: now))!
        return items.filter { row in
            guard let stamp = row.producedDate else { return false }
            return stamp >= cutoff
        }
    }
    var newCount: Int { newItems().count }
    var catchUpCount: Int { max(0, openCount - newCount) }
    func daily(catchUp: Bool, domain: String? = nil, now: Date = Date()) -> WorkIntakeSnapshot {
        let fresh = Set(newItems(now: now).map(\.id))
        var result = self
        result.items = items.filter { fresh.contains($0.id) != catchUp && (domain == nil || $0.meeting.domain == domain) }
        return result
    }
    var asks: [WorkIntakeItem] {
        items.filter(\.isAsk).sorted { left, right in
            // Pulled forward first, likeliest session match first (one of Miles's sessions may already be on it),
            // then newest meeting.
            if (left.pullConfidence ?? -1) != (right.pullConfidence ?? -1) { return (left.pullConfidence ?? -1) > (right.pullConfidence ?? -1) }
            return left.meeting.filename > right.meeting.filename
        }
    }
    var reviews: [WorkIntakeItem] { items.filter(\.isReview).sorted { $0.meeting.filename > $1.meeting.filename } }
    var suggestedLinks: [WorkIntakeItem] { items.filter(\.isSuggestedLink).sorted { $0.confidence > $1.confidence } }
    var openCount: Int { asks.count + reviews.count + suggestedLinks.count }

    init(available: Bool, message: String?, items: [WorkIntakeItem], cardCreation: Bool, linkWrites: Bool) {
        self.available = available; self.message = message; self.items = items; self.cardCreation = cardCreation; self.linkWrites = linkWrites
    }

    /// Helper details: `available` false means an older server (404) or an unavailable store (503).
    init(details: [String: JSONValue]) {
        let raw = details["items"]?.array ?? []
        let capabilities = details["capabilities"]?.object ?? [:]
        self.init(available: details["available"]?.bool != false, message: details["message"]?.string,
                  items: raw.compactMap(WorkIntakeItem.init), cardCreation: capabilities["cardCreation"]?.bool == true,
                  linkWrites: capabilities["linkWrites"]?.bool == true)
        bridgeUnavailable = capabilities["bridgeUnavailable"]?.bool == true
        storeUnavailable = details["storeUnavailable"]?.bool == true
    }
}

/// Exact saved-meeting reference. No title or capture-session matching is allowed.
struct WorkMeetingReference: Identifiable, Hashable, Sendable {
    let recordId: String
    let domain: String
    let month: String
    let filename: String
    let title: String
    var id: String { recordId }
    var json: [String: String] { ["recordId": recordId, "domain": domain, "month": month, "filename": filename, "title": title] }
    var jsonValue: JSONValue { .object(json.mapValues { .string($0) }) }
    var libraryMeeting: LibraryMeeting? { LibraryMeeting(jsonValue) }

    init?(_ value: JSONValue?) {
        guard let row = value?.object,
              let recordId = row["recordId"]?.string, !recordId.isEmpty, recordId.utf8.count <= 2048,
              !recordId.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let domain = row["domain"]?.string, domain.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              let month = row["month"]?.string, month.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil,
              let filename = row["filename"]?.string, !filename.isEmpty, filename.utf8.count <= 1024,
              filename != ".", filename != "..", !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        self.recordId = recordId; self.domain = domain; self.month = month; self.filename = filename
        title = row["title"]?.string ?? "Saved meeting"
    }

    init?(meeting: LibraryMeeting) {
        self.init(.object(["recordId": .string(meeting.recordId), "domain": .string(meeting.domain),
            "month": .string(meeting.month), "filename": .string(meeting.filename), "title": .string(meeting.title)]))
    }

    func matches(_ meeting: LibraryMeeting) -> Bool {
        recordId == meeting.recordId && domain == meeting.domain && month == meeting.month && filename == meeting.filename
    }
}

/// Decision services are separate from the agent provider (Claude, Codex, etc.). Unknown identities fail closed.
enum DecisionProvider: String, CaseIterable, Sendable {
    case jev, subq
    var title: String { self == .jev ? "Jev" : "SubQ" }
    /// New server failures intentionally identify no successful provider. Do not guess who served a failed request.
    static func failureText(_ reason: String?) -> String? {
        switch reason {
        case "decision_not_configured": "The selected decision provider needs an API key in Settings."
        case "decision_key_rejected": "The selected decision provider rejected its API key. Check it in Settings."
        case "decision_credits_required": "The selected decision provider needs available credits."
        case "decision_rate_limited": "The selected decision provider is rate limited. Try again later."
        case "decision_cap_reached": "The selected decision provider has used today’s budget."
        case "decision_usage_unavailable": "Decision usage accounting is unavailable. Requests are paused until it is repaired."
        case "decision_breaker_open": "The selected decision provider is paused after repeated failures."
        case "decision_invalid_provider": "The decision provider setting is invalid. Check it in Settings."
        case "decision_request_rejected": "The selected decision provider could not accept this request."
        case "decision_bad_answer": "The selected decision provider returned an unreadable answer."
        case "decision_unavailable": "The selected decision provider is temporarily unavailable."
        case "decision_cancelled": "The decision request was cancelled."
        default: nil
        }
    }
}

/// Public server configuration only. Credentials never belong in a settings response or local preferences.
struct DecisionProviderSettings: Equatable, Sendable {
    static let workflows = ["session", "completion", "search"]
    let revision: String
    let provider: DecisionProvider
    let savedProvider: DecisionProvider?
    let overrides: [String: DecisionProvider]
    let effective: [String: DecisionProvider]
    let sources: [String: String]
    let configured: [String: Bool]
    let models: [String: String]
    init?(details: [String: JSONValue]) {
        guard details["schema"]?.double == 1,
              let revision = details["revision"]?.string, revision.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let raw = details["provider"]?.string, let provider = DecisionProvider(rawValue: raw),
              let saved = details["saved"]?.object, let rawOverrides = saved["overrides"]?.object,
              let rawEffective = details["effective"]?.object,
              Set(rawOverrides.keys).isSubset(of: Set(Self.workflows)) else { return nil }
        var overrides: [String: DecisionProvider] = [:], effective: [String: DecisionProvider] = [:]
        for (key, value) in rawOverrides {
            guard let raw = value.string, let choice = DecisionProvider(rawValue: raw) else { return nil }
            overrides[key] = choice
        }
        for key in Self.workflows {
            guard let raw = rawEffective[key]?.string, let choice = DecisionProvider(rawValue: raw) else { return nil }
            effective[key] = choice
        }
        var savedProvider: DecisionProvider?
        if let raw = saved["provider"]?.string {
            guard let choice = DecisionProvider(rawValue: raw) else { return nil }; savedProvider = choice
        } else if let value = saved["provider"] { guard case .null = value else { return nil } }
        self.revision = revision; self.provider = provider; self.savedProvider = savedProvider
        self.overrides = overrides; self.effective = effective
        sources = details["sources"]?.object?.compactMapValues(\.string) ?? [:]
        configured = details["configured"]?.object?.compactMapValues(\.bool) ?? [:]
        models = details["models"]?.object?.compactMapValues(\.string) ?? [:]
    }
    func patch(workflow: String?, selection: String) -> [String: JSONValue]? {
        guard selection == "inherit" || DecisionProvider(rawValue: selection) != nil,
              workflow == nil || Self.workflows.contains(workflow!) else { return nil }
        let value: JSONValue = selection == "inherit" ? .null : .string(selection)
        var body: [String: JSONValue] = ["expectedRevision": .string(revision)]
        if let workflow { body["overrides"] = .object([workflow: value]) } else { body["provider"] = value }
        return body
    }
    func effectiveText(_ workflow: String) -> String {
        guard let choice = effective[workflow] else { return "Unavailable" }
        return choice.title + " · " + (models[choice.rawValue] ?? "model unavailable") + " · " + (sources[workflow] ?? "server")
    }
}

struct SubQKeyStatus: Equatable, Sendable {
    let configured: Bool
    let source: String
    let savedAt: String?
    let validatedAt: String?
    init(details: [String: JSONValue]) {
        configured = details["configured"]?.bool == true
        source = details["source"]?.string ?? "none"
        savedAt = details["savedAt"]?.string; validatedAt = details["validatedAt"]?.string
    }
    var summary: String {
        guard configured else { return "No SubQ key configured." }
        return source == "env" ? "SubQ key from the server environment." : "SubQ key accepted and saved on the server."
    }
}

/// Jev key state from the server (6.57.0). Never carries the key itself.
struct JevStatus: Sendable, Equatable {
    var available: Bool
    var configured: Bool
    var source: String
    var savedAt: String?
    var usedToday: Int
    var dailyCap: Int
    var breakerOpenUntil: String?
    var lastError: String?
    init(details: [String: JSONValue]) {
        available = details["available"]?.bool != false
        configured = details["configured"]?.bool == true
        source = details["source"]?.string ?? "none"
        savedAt = details["savedAt"]?.string
        usedToday = Int(details["usedToday"]?.double ?? 0)
        dailyCap = Int(details["dailyCap"]?.double ?? 0)
        breakerOpenUntil = details["breakerOpenUntil"]?.string
        lastError = details["lastError"]?.string
    }
    /// One line for Settings. Since 6.57.0 a key saved here wins over any .env, so say which one is in use.
    var summary: String {
        guard available else { return "Needs server 6.57.0 or later." }
        guard configured else { return "Not set. Work uses word matching for session suggestions." }
        let origin = source == "env" ? "from the server environment" : source == "scripts-env" ? "from the COS .env"
            : "saved here" + (savedAt.map { " on \($0.prefix(10))" } ?? "")
        return "Active, \(origin). Today \(usedToday.formatted()) of \(dailyCap.formatted()) tokens."
    }
    /// The last thing that went wrong with Jev, in words, or nil. A revoked key otherwise still reads "Active".
    var problem: String? {
        switch lastError {
        case nil: return nil
        case "jev_key_rejected": return "Last request: TypeSafe rejected the key. Save a new one."
        case "jev_cap_reached": return "Last request: today's token limit was reached."
        case "jev_unavailable": return "Last request: TypeSafe did not answer."
        case "jev_bad_answer", "jev_request_rejected": return "Last request: TypeSafe refused or garbled one answer."
        case let other?: return "Last request failed (\(other))."
        }
    }
}

/// Continue / Fork / New advice for one Work task (server 6.57.0, Jev). Advice only.
struct SessionAdvice: Sendable, Equatable {
    enum Action: String, Sendable { case continueSession = "continue", fork, newSession = "new" }
    let action: Action
    let provider: DecisionProvider
    let sessionID: String?
    let confidence: Double
    let reason: String
    init?(details: [String: JSONValue]) {
        guard let providerRaw = details["provider"]?.string, let provider = DecisionProvider(rawValue: providerRaw),
              let raw = details["action"]?.string, let action = Action(rawValue: raw),
              let confidence = details["confidence"]?.double, (0...1).contains(confidence) else { return nil }
        let sessionID = details["sessionId"]?.string
        if action != .newSession && (sessionID ?? "").isEmpty { return nil }
        self.action = action; self.provider = provider; self.sessionID = action == .newSession ? nil : sessionID
        self.confidence = confidence; self.reason = details["reason"]?.string ?? ""
    }
    var percent: String { "\(Int((confidence * 100).rounded()))%" }
}

/// Who a saved meeting involved: attendees plus action-item owners, with each person's items from it.
/// Miles himself is left out; his items are already his cards.
struct WorkMeetingPeople: Sendable, Equatable {
    let recordID: String
    let people: [String]
    let items: [String: [String]]

    static let milesNames: Set<String> = ["miles", "miles ukaoma", "mu", "miles u", "me"]
    static let placeholders: Set<String> = ["", "unassigned", "tbd", "team", "all", "everyone", "n/a", "none", "unknown"]

    /// "**Ryan Hopkins** (ryan@x.com)" → "Ryan Hopkins".
    static func cleanName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        if let paren = name.firstIndex(of: "(") { name = String(name[..<paren]) }
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: " -–—:,.\t\n"))
    }
    /// Transcript labels, not people: "Speaker 3" (G2 recordings list them as attendees), "Unknown speaker".
    static func isPlaceholder(_ lower: String) -> Bool {
        placeholders.contains(lower) || lower.hasPrefix("unknown") || lower.hasPrefix("unidentified")
            || lower.range(of: #"^(speaker|participant|guest|voice)\s*\d+$"#, options: .regularExpression) != nil
    }
    /// A calendar handle ("miles.ukaoma", from "**miles.ukaoma** (email)") is Miles too.
    static func isMiles(_ lower: String) -> Bool {
        milesNames.contains(lower) || lower.hasPrefix("miles.") || lower == "milesukaoma"
    }
    static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame
    }

    init(recordID: String, attendees: [String], actionItems: [(task: String, owner: String)]) {
        self.recordID = recordID
        var order: [String] = [], items: [String: [String]] = [:]
        func add(_ raw: String) -> String? {
            let name = Self.cleanName(raw)
            guard !Self.isPlaceholder(name.lowercased()), !Self.isMiles(name.lowercased()), name.count <= 60 else { return nil }
            if let existing = order.first(where: { Self.same($0, name) }) { return existing }
            order.append(name); return name
        }
        for item in actionItems {
            let owners = item.owner.replacingOccurrences(of: " and ", with: ",", options: .caseInsensitive)
            for owner in owners.split(whereSeparator: { ",/&".contains($0) }).map(String.init) {
                if let name = add(owner) { items[name, default: []].append(item.task) }
            }
        }
        for attendee in attendees { _ = add(attendee) }
        // People with items from this meeting first, then attendees, each in the meeting's own order:
        // owners are added before attendees above, so `order` already is that order.
        people = order
        self.items = items
    }
}

/// Everything Work knows about one person: their items from a meeting (and where each stands), their other open
/// asks in Intake, and open tasks that mention them. Built from data Control already holds; no extra calls.
struct WorkPersonNetwork: Sendable {
    enum ItemState: Sendable, Equatable { case onBoard(taskTitle: String), inIntake(id: String), untracked }
    struct Item: Sendable, Equatable, Identifiable { let text: String; let state: ItemState; var id: String { text } }
    let name: String
    let meetingItems: [Item]
    let otherAsks: [WorkIntakeItem]
    let mentions: [TaskRow]

    static let stopWords: Set<String> = ["the", "and", "for", "with", "from", "this", "that", "into", "onto", "our", "your", "their", "them", "then"]
    /// Key words: three or more letters, or any token with a digit ("H1", "Q4"), minus filler.
    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { ($0.count >= 3 || $0.contains(where: \.isNumber)) && !stopWords.contains($0) })
    }
    /// The meeting item's key words are (nearly) all in the task. Cards gain words ("(from Name)", a due date), so
    /// coverage of the item, not overlap of both, is the test. Only tasks and asks from the SAME meeting are compared.
    static func similar(_ item: String, _ task: String) -> Bool {
        let x = words(item), y = words(task)
        guard x.count >= 2 || (x.count == 1 && y.count == 1) else { return x == y && !x.isEmpty }
        return Double(x.intersection(y).count) / Double(x.count) >= 0.75
    }
    /// Whole-word match on the full name, or on a first name of four or more letters.
    static func mentions(_ text: String, name: String) -> Bool {
        let lower = " " + String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }) + " "
        let full = name.lowercased()
        if lower.contains(" " + full + " ") { return true }
        let first = full.split(separator: " ").first.map(String.init) ?? full
        return first.count >= 4 && lower.contains(" " + first + " ")
    }

    init(name: String, meeting: WorkMeetingPeople, intake: WorkIntakeSnapshot, tasks: [TaskRow]) {
        self.name = name
        let owned = intake.items.filter { $0.kind == .ask && ($0.status == "ask" || $0.status == "review") && $0.owner.map { WorkMeetingPeople.same(WorkMeetingPeople.cleanName($0), name) } == true }
        let open = tasks.filter { !$0.checked }
        meetingItems = (meeting.items[name] ?? []).map { text in
            if let task = open.first(where: { $0.meetingRefs.contains { $0.recordId == meeting.recordID } && Self.similar(text, $0.text.isEmpty ? $0.title : $0.text) }) {
                return Item(text: text, state: .onBoard(taskTitle: task.title))
            }
            if let ask = owned.first(where: { $0.meeting.recordId == meeting.recordID && Self.similar(text, $0.text) }) {
                return Item(text: text, state: .inIntake(id: ask.id))
            }
            return Item(text: text, state: .untracked)
        }
        let shown = Set(meetingItems.compactMap { if case .inIntake(let id) = $0.state { return id } else { return nil } })
        otherAsks = owned.filter { !shown.contains($0.id) }.sorted { $0.meeting.filename > $1.meeting.filename }
        self.mentions = Array(open.filter { Self.mentions($0.text.isEmpty ? $0.title : $0.text, name: name) }.prefix(8))
    }
}

struct TaskRow: Identifiable, Sendable {
    let id: String
    let ref: String
    let domain: String
    let title: String
    let column: String
    let section: String
    let due: Bool?
    let missed: Bool?
    let failed: Bool?
    let late: Bool?
    let carriedOver: Bool?
    let runAt: String
    /// Whole description. `title` is capped at 44 for a G2 lens row; a Mac
    /// window has no business rendering that cap. Server 6.44.3 and newer.
    let text: String
    let source: String
    let createdAt: String
    let dueDate: String
    let owner: String
    let priority: String
    let checked: Bool
    let agentState: String
    /// Board stage. Absent or unknown means planning, the unmarked default every
    /// captured row starts in, so an older server degrades to a full PLANNING lane
    /// rather than an empty board. Server 6.44.4 and newer.
    let stage: String
    /// What finished looks like. A dispatch is refused while this is empty: the
    /// server answers `run` with 409 done_when_required.
    let doneWhen: String
    /// Separate Work lifecycle metadata; legacy stage remains planning/active/review.
    let workStage: String
    let workIdentity: String
    let workRevision: String
    let meetingRefs: [WorkMeetingReference]
    let workMetadataError: String?
    /// 0.5.259 (server 6.65.0): the day the card was created (`YYYY-MM-DD`), where that day came from (`source`, the
    /// date in its source label, or `git`, the day its line first appeared), and when its line last changed (ISO).
    /// An older server sends none of them: nil, and Control reads the source label's date itself.
    let createdOn: String?
    let createdFrom: String?
    let lineChangedAt: String?
    static let workStages = ["mentioned", "planned", "draft", "built", "qa", "complete"]
    var workSourceID: String { "task:\(domain):\(workIdentity)" }

    var runAtDate: Date? {
        let trimmed = runAt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        if let date = basic.date(from: trimmed) { return date }
        // Control Schedule writes `yyyy-MM-dd HH:mm`, not ISO-8601.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.dateFormat = "yyyy-MM-dd HH:mm"
        return local.date(from: trimmed)
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let id = o["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        ref = o["ref"]?.string ?? ""
        domain = o["domain"]?.string ?? ""
        title = o["title"]?.string ?? ""
        column = o["column"]?.string ?? ""
        section = o["section"]?.string ?? ""
        due = o["due"]?.bool
        missed = o["missed"]?.bool
        failed = o["failed"]?.bool
        late = o["late"]?.bool
        carriedOver = o["carriedOver"]?.bool
        runAt = o["runAt"]?.string ?? ""
        // Falls back to the capped title on an older server, so the detail view
        // shows something real rather than an empty body.
        text = o["text"]?.string ?? o["title"]?.string ?? ""
        source = o["source"]?.string ?? ""
        createdAt = o["createdAt"]?.string ?? ""
        dueDate = o["dueDate"]?.string ?? ""
        owner = o["owner"]?.string ?? ""
        priority = o["priority"]?.string ?? ""
        let rawStage = o["stage"]?.string ?? ""
        stage = (rawStage == "active" || rawStage == "review") ? rawStage : "planning"
        doneWhen = o["doneWhen"]?.string ?? ""
        checked = o["checked"]?.bool ?? false
        agentState = o["agentState"]?.string ?? ""
        let suppliedMetadataError = o["workMetadataError"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        var metadataError = suppliedMetadataError.flatMap { $0.isEmpty ? nil : $0 }
        let rawWorkStage = o["workStage"]?.string ?? ""
        workStage = Self.workStages.contains(rawWorkStage) ? rawWorkStage : (checked ? "complete" : stage == "active" ? "draft" : stage == "review" ? "qa" : "planned")
        if !rawWorkStage.isEmpty && !Self.workStages.contains(rawWorkStage) { metadataError = "Unsupported Work stage. Refresh before changing this task." }
        let identity = o["workIdentity"]?.string ?? id
        if identity.isEmpty || identity.utf8.count > 2048 || identity.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            workIdentity = id; metadataError = "Invalid Work identity. Refresh before changing this task."
        } else { workIdentity = identity }
        workRevision = o["workRevision"]?.string ?? ""
        let rawRefs = o["meetingRefs"]?.array ?? []
        meetingRefs = rawRefs.compactMap { WorkMeetingReference($0) }
        if meetingRefs.count != rawRefs.count || (o["meetingRefs"] != nil && o["meetingRefs"]?.array == nil) {
            metadataError = "Some saved meeting references are invalid. Refresh before changing this task."
        }
        workMetadataError = metadataError
        createdOn = o["createdOn"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        createdFrom = o["createdFrom"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        lineChangedAt = o["lineChangedAt"]?.string.flatMap { $0.isEmpty ? nil : $0 }
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
    /// The last thing the session was doing, captured at the moment it stopped.
    /// Empty on rows written before 0.5.171, which render the old literal.
    var summary: String = ""
    /// 0.5.229. A scheduled job keeps ONE row per job (sessionId "job:<label>"): its last finish and
    /// how many runs finished on `runsDay`, so a burst of runs never pushes a session's finish out.
    var jobLabel: String = ""
    var jobScript: String = ""
    var runsToday: Int = 0
    var runsDay: String = ""

    var isScheduledJob: Bool { !jobLabel.isEmpty }

    /// yyyy-MM-dd in the given calendar.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// "1 run today", "4 runs today"; a job row still showing after midnight says "4 runs".
    func runsLabel(now: Date = Date(), calendar: Calendar = .current) -> String {
        let count = max(1, runsToday)
        let noun = count == 1 ? "run" : "runs"
        return runsDay == Self.dayKey(now, calendar: calendar) ? "\(count) \(noun) today" : "\(count) \(noun)"
    }
}

// Codable by hand in BOTH directions: decode defaults provider/workspace to ""
// and seen to false so a partial live blob still decodes, and a type with only
// init(from:) does not compile.
extension PetCompletion {
    /// The same compact figure the live rows show, from a finish timestamp:
    /// "4s", "12m", "1h", "2d".
    static func compactAge(_ finished: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(finished))
        if seconds < 60 { return "\(Int(seconds.rounded(.down)))s" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded(.down)))m" }
        if seconds < 86400 { return "\(Int((seconds / 3600).rounded(.down)))h" }
        return "\(Int((seconds / 86400).rounded(.down)))d"
    }
}

extension PetCompletion: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, name, provider, workspace, finishedAt, seen, summary
        case jobLabel, jobScript, runsToday, runsDay
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
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        jobLabel = try c.decodeIfPresent(String.self, forKey: .jobLabel) ?? ""
        jobScript = try c.decodeIfPresent(String.self, forKey: .jobScript) ?? ""
        runsToday = try c.decodeIfPresent(Int.self, forKey: .runsToday) ?? 0
        runsDay = try c.decodeIfPresent(String.self, forKey: .runsDay) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(name, forKey: .name)
        try c.encode(provider, forKey: .provider)
        try c.encode(workspace, forKey: .workspace)
        try c.encode(finishedAt, forKey: .finishedAt)
        try c.encode(summary, forKey: .summary)
        try c.encode(seen, forKey: .seen)
        try c.encode(jobLabel, forKey: .jobLabel)
        try c.encode(jobScript, forKey: .jobScript)
        try c.encode(runsToday, forKey: .runsToday)
        try c.encode(runsDay, forKey: .runsDay)
    }
}

extension ClaudeSession {
    /// A finished chip re-hydrated into a routable session. `state: "recent"`
    /// + `alive: true` keeps it isPetVisible-shaped for the reveal path.
    /// 0.5.229: a finished scheduled job is never revealed; it reopens as its facts, not alive.
    static func fromCompletion(_ row: PetCompletion) -> ClaudeSession? {
        if row.isScheduledJob {
            return ClaudeSession(.object([
                "id": .string(row.sessionId),
                "provider": .string(row.provider),
                "name": .string(row.name),
                "workspace": .string(row.workspace),
                "state": .string("recent"),
                "alive": .bool(false),
                "waitingFor": .string(""),
                "updatedAt": .string(ISO8601DateFormatter().string(from: row.finishedAt)),
                "origin": .string("job"),
                "jobLabel": .string(row.jobLabel),
                "jobScript": .string(row.jobScript),
            ]))
        }
        return ClaudeSession(.object([
            "id": .string(row.sessionId),
            "provider": .string(row.provider),
            "name": .string(row.name),
            "workspace": .string(row.workspace),
            "state": .string("recent"),
            "alive": .bool(true),
            "waitingFor": .string(""),
        ]))
    }

    /// 0.5.229. One finished run from the Sessions tab's Scheduled jobs today list, opened as its facts.
    static func fromJobRun(_ run: ScheduledJobRun) -> ClaudeSession? {
        let iso = ISO8601DateFormatter()
        return ClaudeSession(.object([
            "id": .string(run.id),
            "provider": .string("claude"),
            "name": .string(run.label),
            "workspace": .string("Scheduled job"),
            "state": .string("recent"),
            "alive": .bool(false),
            "createdAt": .string(run.startedAt.map { iso.string(from: $0) } ?? ""),
            "updatedAt": .string(iso.string(from: run.finishedAt)),
            "origin": .string("job"),
            "jobLabel": .string(run.label),
            "jobScript": .string(run.script),
        ]))
    }

    /// The ONLY terminals the jump may target — pinned by ModelsContract with
    /// negative-membership asserts for all three non-terminal tty owners the
    /// 2026-08-30 census found (Claude Desktop itself owned ttys006). tty
    /// presence is NEVER the classifier; this list is.
    /// Dictation's KnownApps.terminals (MacDictationCore.swift) is the wider set that gets ⌘V instead of Accessibility;
    /// this jump list must stay inside it (Tests/dictation-wispr-pins.py). Not derived from it: the jump is implemented
    /// only for these two hosts, and ModelsContract pins exactly them.
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

/// Which pet rows cannot be told apart by what is already on screen.
///
/// A Claude fork inherits its parent's history, so the derived title is
/// identical; when both rows also sit in the same workspace, the slot's second
/// line is spending itself on a value that distinguishes nothing. Measured
/// 2026-09-01 against the live session index: 8 rows shared one label, 5 more
/// shared "Codex session", and every one of those pairs shared a workspace too.
///
/// Pure, and shared by both lists, so there is ONE implementation under test
/// rather than a copy per call site.
enum PetRowIdentity {
    /// Ids whose (name, workspace) pair repeats in `rows`. Rows with a unique
    /// name are never included, and neither are rows that merely share a name
    /// while sitting in different workspaces — there the workspace is already
    /// doing the job and must be left alone.
    static func indistinguishable(_ rows: [(id: String, name: String, workspace: String)]) -> Set<String> {
        var byKey: [String: [String]] = [:]
        for row in rows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            byKey["\(name)\u{0000}\(row.workspace.trimmingCharacters(in: .whitespacesAndNewlines))",
                  default: []].append(row.id)
        }
        var out: Set<String> = []
        for (_, ids) in byKey where ids.count > 1 { out.formUnion(ids) }
        return out
    }

    /// The wall-clock time a row happened, for the slot's second line: "2:41 PM".
    /// Deliberately time-only — the slot is 57pt and every row in a pet list is
    /// recent enough that the date is noise.
    static func clockLabel(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: date)
    }
}

/// The two lists the pet can show. Stored so the sprite's double-tap can
/// reopen whichever one was last closed.
enum PetListTab: String, Codable, Sendable {
    case running
    case done
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
            waiting: sessions.filter(ClaudeSession.needsAPerson).count,
            done: completions.count,
            unseen: completions.filter { !$0.seen }.count
        )
    }

    var isQuiet: Bool { running + waiting + done == 0 }

    /// 0.5.316 (Miles 2026-10-16 15:33, "RUNNING 0 · DONE 8 · WAITING 0 · DICTATIONS"): the WAITING pill shows only while
    /// a session waits on a person, so the row uses less space; it is back the moment one does. No other pill changes.
    var showsWaitingPill: Bool { waiting > 0 }

    /// 0.5.316 (Miles 2026-10-16 15:55, "When there are items that are complete, like done, and waiting, we should remove
    /// them"): DONE shows only while something finished is listed, or while its own list is open, so an emptied list can
    /// still be closed from the pill that opened it. RUNNING stays, REC follows recording, DICTATIONS follows history.
    func showsDonePill(listOpen: Bool) -> Bool { done > 0 || listOpen }

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
            if prior.isScheduledJob {
                // 0.5.229: one row per job, keyed by its name and already seen: a job finishing is not news.
                let label = prior.title
                out.append(PetCompletion(
                    id: "\(prior.provider):job:\(label)", sessionId: "job:\(label)", name: label,
                    provider: prior.provider, workspace: "Scheduled job",
                    finishedAt: now, seen: true, summary: prior.jobScript,
                    jobLabel: label, jobScript: prior.jobScript,
                    runsToday: 1, runsDay: PetCompletion.dayKey(now)
                ))
                continue
            }
            out.append(PetCompletion(
                id: prior.id, sessionId: prior.sessionId, name: prior.name,
                provider: prior.provider, workspace: prior.workspace,
                finishedAt: now, seen: false, summary: prior.petOutcomeLine
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
        let active = Set(current.filter { $0.isPetWorking || ClaudeSession.needsAPerson($0) }.map(\.id))
        let workingBefore = Set(previous.filter(\.isPetWorking).map(\.id))
        var rows = existing.filter { !active.contains($0.id) }
        for row in fresh {
            var next = row
            if let i = rows.firstIndex(where: { $0.id == row.id }) {
                if row.isScheduledJob {
                    // 0.5.229: the job's one row counts runs finished on the same day.
                    next.runsToday = (rows[i].runsDay == row.runsDay ? rows[i].runsToday : 0) + row.runsToday
                    next.seen = true
                } else {
                    next.seen = workingBefore.contains(row.id) ? false : rows[i].seen
                }
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
        // 0.5.229: job rows are keyed by name and never prefix-merged ("Meeting watcher" vs "Meeting watcher sync").
        for row in rows.filter({ !$0.isScheduledJob }).sorted(by: { $0.sessionId.count > $1.sessionId.count }) {
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
        return out + rows.filter(\.isScheduledJob)
    }
}

/// 0.5.229. One finished run of a COS scheduled job, kept for the Sessions tab's Scheduled jobs today list.
struct ScheduledJobRun: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let label: String
    let script: String
    let startedAt: Date?
    let finishedAt: Date

    var duration: TimeInterval? {
        startedAt.map { max(0, finishedAt.timeIntervalSince($0)) }
    }

    /// "38s", "4m 12s", "1h 3m".
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s" }
        let minutes = (total % 3600) / 60
        return minutes == 0 ? "\(total / 3600)h" : "\(total / 3600)h \(minutes)m"
    }
}

/// 0.5.229. A scheduled job row that was running and is no longer running finished now. The pet's poll
/// is the clock, so a run that starts and ends between two polls is never seen.
enum ScheduledJobLedger {
    static let cap = 200

    static func record(
        existing: [ScheduledJobRun], previous: [ClaudeSession], current: [ClaudeSession],
        now: Date = Date(), calendar: Calendar = .current
    ) -> [ScheduledJobRun] {
        let stillRunning = Set(current.filter(\.isPetWorking).map(\.id))
        var runs = existing
        for prior in previous where prior.isScheduledJob && prior.isPetWorking && !stillRunning.contains(prior.id) {
            guard !runs.contains(where: { $0.id == prior.sessionId }) else { continue }
            runs.append(ScheduledJobRun(
                id: prior.sessionId, label: prior.title, script: prior.jobScript,
                startedAt: prior.createdDate, finishedAt: now
            ))
        }
        return prune(runs, now: now, calendar: calendar)
    }

    static func prune(_ runs: [ScheduledJobRun], now: Date = Date(), calendar: Calendar = .current) -> [ScheduledJobRun] {
        let today = runs.filter { calendar.isDate($0.finishedAt, inSameDayAs: now) }
        return Array(today.sorted { $0.finishedAt > $1.finishedAt }.prefix(cap))
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

/// Last successful Sessions list. First paint reads this file; the helper
/// refreshes it after a full walk. Counts come from mtime/size/name, never
/// from opening hidden transcript bodies.
struct SessionListCache: Sendable {
    static let fileName = "session-list-cache.json"
    static let staleAfter: TimeInterval = 45
    static let maxAge: TimeInterval = 7 * 24 * 3600
    static let listCap = 80
    static let perProviderCap = 20
    static let maxFileBytes = 32 * 1024 * 1024
    static let window: TimeInterval = 7 * 24 * 3600

    struct IndexRecord: Sendable {
        var provider: String
        var mtime: Date
        var size: Int
        var pinned: Bool
    }

    var savedAt: Date
    var enabled: Bool
    var reason: String
    var dropped: SessionListDropped
    var sessions: [ClaudeSession]
    var partial: Bool

    var isStale: Bool { isStale(now: Date()) }
    func isStale(now: Date) -> Bool { now.timeIntervalSince(savedAt) > Self.staleAfter }

    static func fileURL(support: URL = PetSpriteStore.supportDirectory()) -> URL {
        support.appendingPathComponent(fileName)
    }

    static func load(from url: URL? = nil, now: Date = Date()) -> SessionListCache? {
        let file = url ?? fileURL()
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let savedText = object["savedAt"] as? String,
              let savedAt = SearchRecency.parseStamp(savedText),
              now.timeIntervalSince(savedAt) <= maxAge else { return nil }
        let dropped = SessionListDropped(
            age: intValue(object["dropped"], key: "age"),
            limit: intValue(object["dropped"], key: "limit"),
            oversized: intValue(object["dropped"], key: "oversized")
        )
        let rows = (object["sessions"] as? [[String: Any]] ?? []).compactMap { row -> ClaudeSession? in
            ClaudeSession(.object(jsonObject(row)))
        }
        return SessionListCache(
            savedAt: savedAt,
            enabled: object["enabled"] as? Bool ?? true,
            reason: object["reason"] as? String ?? "",
            dropped: dropped,
            sessions: rows,
            partial: object["partial"] as? Bool ?? false
        )
    }

    /// Cap/older/oversized from mtime, size, pin, and provider. No file body.
    static func indexDropped(
        _ records: [IndexRecord],
        now: Date = Date(),
        window: TimeInterval = window,
        perProviderCap: Int = perProviderCap,
        listCap: Int = listCap,
        maxFileBytes: Int = maxFileBytes
    ) -> SessionListDropped {
        var age = 0, limit = 0, oversized = 0
        var candidates: [IndexRecord] = []
        for record in records {
            if !record.pinned && record.provider == "cursor" && record.size > maxFileBytes {
                oversized += 1
                continue
            }
            if !record.pinned && now.timeIntervalSince(record.mtime) > window {
                age += 1
                continue
            }
            candidates.append(record)
        }
        var kept: [IndexRecord] = []
        let groups = Dictionary(grouping: candidates, by: \.provider)
        for rows in groups.values {
            let pins = rows.filter(\.pinned).sorted { $0.mtime > $1.mtime }
            let recent = rows.filter { !$0.pinned }.sorted { $0.mtime > $1.mtime }
            kept.append(contentsOf: pins)
            kept.append(contentsOf: recent.prefix(perProviderCap))
            if recent.count > perProviderCap {
                limit += recent.count - perProviderCap
            }
        }
        kept.sort { $0.mtime > $1.mtime }
        if kept.count > listCap {
            limit += kept.count - listCap
        }
        return SessionListDropped(age: age, limit: limit, oversized: oversized)
    }

    private static func intValue(_ raw: Any?, key: String) -> Int {
        let object = raw as? [String: Any] ?? [:]
        if let n = object[key] as? Int { return max(0, n) }
        if let n = object[key] as? Double { return max(0, Int(n)) }
        if let s = object[key] as? String, let n = Int(s) { return max(0, n) }
        return 0
    }

    private static func jsonObject(_ row: [String: Any]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (key, value) in row {
            if let text = value as? String { out[key] = .string(text) }
            else if let flag = value as? Bool { out[key] = .bool(flag) }
            else if let number = value as? Int { out[key] = .number(Double(number)) }
            else if let number = value as? Double { out[key] = .number(number) }
        }
        return out
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
    /// The transcript was too big to parse whole, so the middle was skipped:
    /// the newest turns are here, the earliest are not. It is never a refusal.
    let windowed: Bool
    let copyText: String

    var subtitle: String {
        var parts: [String] = []
        parts.append(provider == "codex" ? "Codex" : provider == "cursor" ? "Cursor" : "Claude")
        if !cwd.isEmpty { parts.append((cwd as NSString).lastPathComponent) }
        if !branch.isEmpty { parts.append(branch) }
        if truncated { parts.append("last \(turns.count) of \(totalTurns) turns") }
        else { parts.append("\(totalTurns) turn\(totalTurns == 1 ? "" : "s")") }
        if omittedTools > 0 { parts.append("tools omitted") }
        if windowed { parts.append("large session · earlier turns skipped") }
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
        windowed = o["windowed"]?.bool ?? false
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
    /// 0.5.185 — the model, as the server reports it: a live row may carry the
    /// session's current preference when the exchange itself was not stamped,
    /// and an archived row carries none. Nil when the server did not say.
    let modelPreference: String?
    /// 0.5.185 — "routine" or "task" when the Mac started the run (server
    /// 6.43.4 stamps it at submission). Nil means Miles started it himself;
    /// nothing is ever inferred from absence.
    let origin: String?
    /// The routine slug or task id behind `origin`; only ever set beside it.
    let originId: String?
    /// Carried for Phase B (`ref: { messageEra, globalMsgNum, originId }`); not
    /// rendered by 0.5.185.
    let messageEra: String?

    init(id: String, no: Int?, timestamp: TimeInterval?, query: String, text: String, sessionId: String, source: String, attachments: [GlassesAttachmentRef] = [], modelPreference: String? = nil, origin: String? = nil, originId: String? = nil, messageEra: String? = nil) {
        self.id = id
        self.no = no
        self.timestamp = timestamp
        self.query = query
        self.text = text
        self.sessionId = sessionId
        self.source = source
        self.attachments = Array(attachments.prefix(5))
        self.modelPreference = modelPreference
        self.origin = origin
        self.originId = originId
        self.messageEra = messageEra
    }

    /// The same allowlist the helper applies, so a value the helper did not
    /// bound (a direct decode in a test, a future transport) cannot widen it.
    static let originKinds: Set<String> = ["routine", "task"]

    static func boundedString(_ value: String?, max: Int) -> String? {
        guard let value, !value.isEmpty, value.count <= max else { return nil }
        return value
    }

    /// A rendered identifier: bounded AND confined to `A-Za-z0-9._:-`, so a
    /// value the server never sends (whitespace, a newline, a bidi override)
    /// cannot reach a Text. The model ids are short lowercase slugs.
    static func boundedToken(_ value: String?, max: Int) -> String? {
        guard let value = boundedString(value, max: max) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        guard value.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return nil }
        return value
    }

    /// Mirrors the server's `QUERY_JOB_ORIGIN_ID_RE` (`^[a-z0-9][a-z0-9-]{0,63}$`).
    static func validOriginID(_ value: String?) -> String? {
        guard let value, (1...64).contains(value.count), let first = value.unicodeScalars.first else { return nil }
        let head = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let body = head.union(CharacterSet(charactersIn: "-"))
        guard head.contains(first), value.unicodeScalars.dropFirst().allSatisfy({ body.contains($0) }) else { return nil }
        return value
    }

    init?(_ object: [String: JSONValue]) {
        let query = object["query"]?.string ?? ""
        let text = object["text"]?.string ?? ""
        let sessionId = object["sessionId"]?.string ?? ""
        let source = object["source"]?.string ?? ""
        let no = object["no"]?.int
        let modelPreference = Self.boundedToken(object["modelPreference"]?.string, max: 64)
        let origin = object["origin"]?.string.flatMap { Self.originKinds.contains($0) ? $0 : nil }
        let originId = origin == nil ? nil : Self.validOriginID(object["originId"]?.string)
        let messageEra = Self.boundedString(object["messageEra"]?.string, max: 80)
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
        self.init(id: idBase, no: no, timestamp: timestamp, query: query, text: text, sessionId: sessionId, source: source, attachments: attachments, modelPreference: modelPreference, origin: origin, originId: originId, messageEra: messageEra)
    }

    /// The label a row wears when the Mac started the run. Nil for a row Miles
    /// started himself, which is what makes the label mean something.
    var originLabel: String? {
        switch origin {
        case "routine": return "ROUTINE"
        case "task": return "TASK"
        default: return nil
        }
    }

    /// Hover text for the label.
    var originTitle: String? {
        switch origin {
        case "routine": return "Produced by a scheduled routine on your Mac" + (originId.map { " (\($0))" } ?? "")
        case "task": return "Produced by an agent working a task on your Mac" + (originId.map { " (\($0))" } ?? "")
        default: return nil
        }
    }

    /// The model badge, nil when the server did not say.
    var modelLabel: String? { modelPreference }

    var sourceLabel: String { source.isEmpty ? "COS Glasses" : source }

    /// Second line of the detail header: time · source · model · origin, each
    /// segment present only when known.
    var detailMetaLine: String {
        [timeLabel, sourceLabel, modelLabel, originLabel].compactMap { $0 }.joined(separator: " · ")
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
    /// 2026-10-09: the stable channel's optional `whatsNew` (summary and sections), already cleaned by the helper and
    /// cleaned again here. Nil when the appcast has none; the What's New window then shows `notes` as its summary.
    var whatsNew: AppUpdateWhatsNew?
    /// The stable entry's minMacOS, so "This update needs macOS 15.0 or later." can say which.
    var minMacOS: String?
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
        whatsNew = AppUpdateWhatsNew(details["whatsNew"])
        minMacOS = details["minMacOS"]?.string
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

// MARK: - Update ready (Miles, 2026-10-09 08:14, with screenshots of Vorssant)
//
// "Color the Glasses when an update is ready and then we expose the update when a new appcast has been pushed."
// Four pieces, all pure so Tests/AppUpdateBadgeChecks.swift executes them without a helper, a network or a window:
//   AppUpdateVersion        is the appcast's stable offer newer than the running build (the helper's rule, again)
//   AppUpdateFlow           none, ready, staging, applying, failed: what the banner and the icon show
//   AppUpdateCheckSchedule  at launch, every 6 hours, on panel open after 15 minutes, never two at once
//   MenuBarIcon             the template glasses, or the gold glasses with a dot when an update is ready

/// The helper decides `updateAvailable` with `appUpdateIsNewer` (build authoritative; HelperSources/main.swift). The app
/// asks the same question again before it colors anything, so an offer that is not a genuine upgrade of THIS build (a
/// malformed version, an equal or older build, a sticky offer outliving the update it advertised) never tints the icon.
enum AppUpdateVersion {
    /// "0.5.273" -> [0, 5, 273]. Nil for anything that is not dot-separated ASCII digits ("", "0.5.", "v0.5", "0.5.x").
    static func components(_ version: String) -> [Int]? {
        let trimmed = version.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var parts: [Int] = []
        for piece in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            // An empty piece ("0..5", "0.5.") fails Int("").
            guard piece.count <= 9, piece.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
                  let value = Int(piece) else { return nil }
            parts.append(value)
        }
        return parts
    }

    /// Numeric, component by component, missing components read as 0 ("0.5" == "0.5.0"). Nil when either is malformed.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let a = components(lhs), let b = components(rhs) else { return nil }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// Build is authoritative when the appcast names one (a republished or rolled-back appcast can never advertise a
    /// downgrade, and a rebuild of the same version is an update). Without a build, the version decides. A malformed
    /// offer version is never newer.
    static func isNewer(latestVersion: String?, latestBuild: Int?, currentVersion: String, currentBuild: Int) -> Bool {
        guard let latestVersion, components(latestVersion) != nil else { return false }
        if let latestBuild { return latestBuild > currentBuild }
        return compare(latestVersion, currentVersion) == .orderedDescending
    }
}

/// What the update banner shows and the menu-bar icon follows.
enum AppUpdatePhase: Equatable, Sendable {
    /// No update: no banner. The header's version stamp and its refresh button (which also checks) answer instead.
    case none
    /// The appcast offers a newer build: the banner with Update, and the gold glasses.
    case ready
    /// stage-app-update is downloading and checking the SHA-256; the helper's latest progress line, when it sent one.
    case staging(String?)
    /// apply-app-update was started; Control quits and the detached helper reopens it.
    case applying
    /// Staging or applying failed. The helper's own words, and Try again.
    case failed(String)
}

struct AppUpdateFlow: Equatable, Sendable {
    private(set) var phase: AppUpdatePhase = .none
    /// The offer the banner names. Kept while an install runs, even if a later check changes the appcast.
    private(set) var version: String?
    private(set) var build: Int?
    /// 0.5.319 (Miles 2026-10-17: "Can we at least get a view of how long the install and download is going to take?"):
    /// when the download began reporting bytes, and how many it had then, so the line can say how long is left.
    private(set) var downloadFirstAt: Date?
    private(set) var downloadFirstBytes: Double = 0
    /// When apply-app-update started. Control should be gone within `applyDeadline`; still here means the helper gave
    /// up (it waits 60 s for Control to quit) and the window must say so instead of "Installing" forever.
    private(set) var applyingStartedAt: Date?
    /// What Control is finishing before it can quit (the Mac recording's save), shown while installing.
    private(set) var quitWaitingOn: String?
    /// 0.5.322: the ready offer is a build already downloaded and checked (updates/pending.json) whose install could not
    /// close Control last time (AppUpdateFinishOffer). Finish installing applies it with no download.
    private(set) var finishesStaged = false
    /// The detached swap gives Control 20 s to quit, then (no Mac recording in flight) SIGTERM, 10 s, SIGKILL, 5 s; it
    /// waits up to 60 s without a signal when the recording state cannot be read, and 10 s more in case Control quits
    /// after all. 75 s covers all of it: still here then means nothing was installed.
    static let applyDeadline: TimeInterval = 75

    /// Every new check result. While an install runs it owns the banner, so an offer change waits. A failure stays on
    /// screen while the offer stands, and goes when the appcast no longer offers an update.
    mutating func offer(_ info: AppUpdateInfo, currentVersion: String, currentBuild: Int) {
        let available = info.shouldSurface && AppUpdateVersion.isNewer(
            latestVersion: info.latestVersion, latestBuild: info.latestBuild,
            currentVersion: currentVersion, currentBuild: currentBuild)
        switch phase {
        case .staging, .applying:
            return
        case .none, .ready:
            // 0.5.322: a staged build stays on offer while the feed cannot be read or still offers that build. A newer
            // build, or no update at all (up to date, paused, needs a newer macOS), replaces it.
            if finishesStaged {
                if info.reason == "unreachable" || info.reason == "malformed" { return }
                if available, let offered = info.latestBuild, offered == build { return }
                finishesStaged = false
            }
            phase = available ? .ready : .none
        case .failed:
            if !available { phase = .none }
        }
        if available {
            version = info.latestVersion
            build = info.latestBuild
        } else if phase == .none {
            version = nil
            build = nil
        }
    }

    /// Update (from ready) or Try again (from failed). False in any other phase, so a second press never starts a
    /// second install.
    mutating func beginInstall() -> Bool {
        switch phase {
        case .ready, .failed:
            phase = .staging(nil)
            downloadFirstAt = nil; downloadFirstBytes = 0; applyingStartedAt = nil; quitWaitingOn = nil
            finishesStaged = false
            return true
        default:
            return false
        }
    }

    /// 0.5.322: at launch, a verified staged build whose install could not close Control (AppUpdateFinishOffer): the
    /// banner offers Finish installing it. Never during an install, never for a build that is not newer.
    mutating func offerFinish(version: String, build: Int, currentBuild: Int) {
        guard build > currentBuild, AppUpdateVersion.components(version) != nil else { return }
        switch phase {
        case .none, .ready, .failed:
            phase = .ready
            self.version = version
            self.build = build
            finishesStaged = true
        case .staging, .applying:
            return
        }
    }

    /// Finish installing: straight to applying (the build is already staged, so no download). False unless the offer
    /// is a staged build, so a second press never starts a second apply.
    mutating func beginFinish(now: Date = Date()) -> Bool {
        guard phase == .ready, finishesStaged else { return false }
        phase = .applying
        applyingStartedAt = now
        quitWaitingOn = nil
        downloadFirstAt = nil; downloadFirstBytes = 0
        finishesStaged = false
        return true
    }

    mutating func progress(_ line: String, now: Date = Date()) {
        guard case .staging = phase else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let bytes = AppUpdateDownloadLine.parse(trimmed) {
            if downloadFirstAt == nil { downloadFirstAt = now; downloadFirstBytes = bytes.received }
            phase = .staging(AppUpdateDownloadLine.words(bytes, since: downloadFirstAt, firstBytes: downloadFirstBytes, now: now))
        } else {
            phase = .staging(trimmed)
        }
    }

    mutating func staged(now: Date = Date()) {
        guard case .staging = phase else { return }
        phase = .applying
        applyingStartedAt = now
    }

    /// While installing: what Control is finishing before it can quit, or nil.
    mutating func waitingToQuit(on what: String?) {
        guard case .applying = phase else { return }
        quitWaitingOn = what
    }

    /// Still installing after `applyDeadline`: Control did not quit, so the helper gave up and nothing was installed.
    func applyOverdue(now: Date = Date()) -> Bool {
        guard case .applying = phase, let started = applyingStartedAt else { return false }
        return now.timeIntervalSince(started) >= Self.applyDeadline
    }

    /// A refusal the helper recorded after this launch's Control had already quit (it reopened the old build): shown on
    /// the offer, so the person learns why nothing changed. Only while the offer stands.
    mutating func restoreFailure(_ message: String) {
        // 0.5.322: Finish installing already answers that failure, with a button that fixes it.
        guard phase == .ready, !finishesStaged else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { phase = .failed(trimmed) }
    }

    mutating func fail(_ message: String) {
        switch phase {
        case .staging, .applying:
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .failed(trimmed.isEmpty ? "The update did not install." : trimmed)
            applyingStartedAt = nil; quitWaitingOn = nil
        default:
            return
        }
    }

    var showsBanner: Bool { phase != .none }
    var installing: Bool {
        switch phase {
        case .staging, .applying: return true
        default: return false
        }
    }

    /// 0.5.322: the words while applying, the same in the banner and the What's New footer: what Control is finishing
    /// first, else "Closing COS Control…" (then nothing: Control is gone, and the new build opens).
    var applyingWords: String {
        quitWaitingOn.map { "Saving \($0) first, then COS Control closes and installs." } ?? WhatsNewFooter.installingWords
    }

    /// "Version 0.5.274 (build 330)"; the build only when the appcast names one.
    var versionLine: String {
        guard let version else { return "" }
        return build.map { "Version \(version) (build \($0))" } ?? "Version \(version)"
    }
}

/// The update banner's words for each phase (Views.swift AppUpdateBanner draws them). 0.5.322: pure, so the checks read
/// the staged offer ("Finish installing <version>") and the words while applying ("Closing COS Control…").
struct AppUpdateBannerWords: Equatable, Sendable {
    let title: String
    let detail: String
    /// The button: Update, Install (a staged build), Try again; nil while an install runs.
    let action: String?

    init(_ flow: AppUpdateFlow) {
        switch flow.phase {
        case .ready where flow.finishesStaged:
            title = "Finish installing \(flow.version ?? "the update")"
            detail = WhatsNewFooter.finishWords
            action = "Install"
        case .none, .ready:
            title = "Update available"
            detail = flow.versionLine
            action = "Update"
        case .staging(let line):
            title = "Downloading update"
            detail = line ?? "\(flow.versionLine). Checking the download as it arrives."
            action = nil
        case .applying:
            title = "Installing update"
            // In words, as the What's New footer says it; then Control is gone and the new build opens.
            detail = flow.applyingWords
            action = nil
        case .failed(let message):
            title = "Update did not install"
            detail = message
            action = "Try again"
        }
    }
}

// MARK: - What's New (Miles, 2026-10-09 13:09, with screenshots of Vorssant)
//
// "When an update is ready and the user clicks Update, show a proper What's New window." Update in the banner, and Check
// for updates when it finds one, open a real window (WhatsNewWindowPresenter in Views.swift): a title naming the
// release, a byline with its build, a summary, sections of bullets, and a footer with Cancel and Download and install.
// That click IS the confirmation: the small "Install COS Control X?" alert is gone. After an update the same window
// shows once on the first launch of the new build, with Done only. Pure pieces here, so Tests/WhatsNewChecks.swift runs
// them with Models.swift alone:
//   AppUpdateWhatsNew      the appcast's optional whatsNew, typed, capped and cleaned (the helper already did; again here)
//   WhatsNewContent        what the window shows: whatsNew, or the old `notes` as the summary with no sections
//   WhatsNewFooter         the footer for each phase of AppUpdateFlow, and Done after an update
//   WhatsNewPresentation   title, byline, content and footer, for an offer or for the build just installed
//   AppUpdateStageCheck    QA 2026-10-09: only a stage that proves it staged the offered build may be applied
//   WhatsNewAfterUpdate    the once-per-build window after an update (first run, deferral, which notes)

/// `channels.stable.whatsNew` in the appcast: `{ "summary": "…", "sections": [ { "title": "…", "items": ["…"] } ] }`.
/// Untrusted text from the network. HelperSources/main.swift (`sanitizedWhatsNew`) applies the same rules before it
/// passes the object on, and this applies them again, so a helper from another build can never put more on screen.
/// A section needs a title and at least one item; a whatsNew needs a summary or at least one section.
struct AppUpdateWhatsNew: Equatable, Sendable {
    struct Section: Equatable, Sendable {
        let title: String
        let items: [String]
    }

    static let summaryLimit = 1200
    static let sectionLimit = 8
    static let itemLimit = 12
    static let itemLength = 400
    static let titleLength = 80
    /// Unicode scalars per character allowed (QA 2026-10-09: a combining-mark bomb is one character of thousands).
    static let scalarsPerCharacter = 4

    let summary: String?
    let sections: [Section]

    init(summary: String?, sections: [Section]) {
        self.summary = summary
        self.sections = sections
    }

    /// Nil for anything that is not an object, and for an object with no usable summary and no usable section. Wrong
    /// types are dropped one by one (a number for an item drops that item, not the section). A summary or a title that
    /// is empty after cleaning is absent.
    init?(_ value: JSONValue?) {
        guard let object = value?.object else { return nil }
        let summary = object["summary"]?.string.flatMap { Self.clean($0, limit: Self.summaryLimit, keepNewlines: true) }
        var sections: [Section] = []
        for entry in object["sections"]?.array ?? [] {
            guard sections.count < Self.sectionLimit else { break }
            guard let section = entry.object,
                  let title = section["title"]?.string.flatMap({ Self.clean($0, limit: Self.titleLength, keepNewlines: false) })
            else { continue }
            var items: [String] = []
            for item in section["items"]?.array ?? [] {
                guard items.count < Self.itemLimit else { break }
                if let text = item.string, let cleaned = Self.clean(text, limit: Self.itemLength, keepNewlines: false) {
                    items.append(cleaned)
                }
            }
            if !items.isEmpty { sections.append(Section(title: title, items: items)) }
        }
        guard summary != nil || !sections.isEmpty else { return nil }
        self.summary = summary
        self.sections = sections
    }

    /// Control characters (Cc) become spaces (a newline stays one only in the summary, at most one blank line in a
    /// row); format characters (Cf: bidi overrides and isolates, zero-width spaces and joiners, the BOM, word joiners,
    /// tags) go; runs of spaces close up; the ends are trimmed. Nil when nothing is left. Longer than `limit`
    /// characters, or than `scalarsPerCharacter` times that in Unicode scalars: cut, with an ellipsis as the last.
    static func clean(_ text: String, limit: Int, keepNewlines: Bool) -> String? {
        var scalars = String.UnicodeScalarView()
        var previous: Unicode.Scalar?
        for scalar in text.unicodeScalars {
            defer { previous = scalar }
            if scalar == "\n" && previous == "\r" { continue }  // CR LF is one line break
            let breaks = scalar == "\n" || scalar == "\r" || scalar.value == 0x2028 || scalar.value == 0x2029
            if breaks {
                scalars.append(keepNewlines ? "\n" : " ")
            } else if scalar.properties.generalCategory == .control {
                scalars.append(" ")
            } else if scalar.properties.generalCategory != .format {
                scalars.append(scalar)
            }
        }
        var lines: [String] = []
        for line in String(scalars).split(separator: "\n", omittingEmptySubsequences: false) {
            let words = line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            if words.isEmpty && (lines.last?.isEmpty ?? true) { continue }
            lines.append(words)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        var result = lines.joined(separator: "\n")
        guard !result.isEmpty else { return nil }
        if result.count > limit {
            result = String(result.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        let scalarLimit = limit * scalarsPerCharacter
        if result.unicodeScalars.count > scalarLimit {
            let kept = String(String.UnicodeScalarView(result.unicodeScalars.prefix(max(0, scalarLimit - 1))))
            result = kept.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return result
    }
}

/// What the What's New window shows.
struct WhatsNewContent: Equatable, Sendable {
    let summary: String?
    let sections: [AppUpdateWhatsNew.Section]

    init(summary: String?, sections: [AppUpdateWhatsNew.Section]) {
        self.summary = summary
        self.sections = sections
    }

    /// The appcast's whatsNew when it has one. Without it (every appcast before 0.5.275, or one whose whatsNew was all
    /// wrong types) the old `notes` string is the summary and there are no sections. A whatsNew with sections but no
    /// summary takes `notes` as its summary.
    init(_ info: AppUpdateInfo) {
        let notes = info.notes.flatMap { AppUpdateWhatsNew.clean($0, limit: AppUpdateWhatsNew.summaryLimit, keepNewlines: true) }
        summary = info.whatsNew?.summary ?? notes
        sections = info.whatsNew?.sections ?? []
    }

    /// The summary paragraph, or a plain line when the appcast published no words at all.
    var summaryText: String { summary ?? "No release notes were published with this update." }
}

/// 0.5.319: the helper's download line with bytes ("Downloading COS Control update… 12.4 MB of 137.2 MB") and the words the
/// window shows for it ("Downloading 12.4 of 137.2 MB, about 40 s left"). The estimate uses the average rate since the
/// first byte line, after 2 s of data, so one slow second does not swing it.
enum AppUpdateDownloadLine {
    struct Bytes: Equatable, Sendable { let received: Double; let total: Double? }

    static func parse(_ line: String) -> Bytes? {
        guard line.hasPrefix("Downloading"), let mb = line.range(of: #"([0-9]+(?:\.[0-9]+)?) MB(?: of ([0-9]+(?:\.[0-9]+)?) MB)?"#, options: .regularExpression) else { return nil }
        let numbers = line[mb].split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
        guard let received = numbers.first else { return nil }
        return Bytes(received: received, total: numbers.count > 1 ? numbers[1] : nil)
    }

    static func words(_ b: Bytes, since first: Date?, firstBytes: Double, now: Date) -> String {
        let got = String(format: "%.1f", b.received)
        guard let total = b.total, total > 0 else { return "Downloading \(got) MB" }
        let head = "Downloading \(got) of \(String(format: "%.1f", total)) MB"
        guard let first, now.timeIntervalSince(first) >= 2, b.received > firstBytes else { return head }
        let rate = (b.received - firstBytes) / now.timeIntervalSince(first)
        guard rate > 0 else { return head }
        return "\(head), \(timeLeft((total - b.received) / rate))"
    }

    static func timeLeft(_ seconds: Double) -> String {
        if seconds < 10 { return "a few seconds left" }
        if seconds < 60 { return "about \(Int((seconds / 5).rounded()) * 5) s left" }
        let minutes = Int((seconds / 60).rounded())
        return minutes <= 1 ? "about a minute left" : "about \(minutes) min left"
    }
}

/// 0.5.319: the helper's `updates/last-failure.json` ({"reason":"busy","blockers":[...]}, {"reason":"quitTimeout"},
/// {"reason":"notStaged","message":...}, each with "at"). Before 0.5.319 nothing in Control read it, so a refused or timed
/// out install left "Installing, COS Control will reopen" on screen forever.
struct AppUpdateFailureRecord: Equatable, Sendable {
    let reason: String
    let blockers: [String]
    let at: Date?

    static func parse(_ data: Data) -> AppUpdateFailureRecord? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let reason = object["reason"] as? String else { return nil }
        let at = (object["at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return AppUpdateFailureRecord(reason: reason, blockers: (object["blockers"] as? [String]) ?? [], at: at)
    }

    var words: String {
        switch reason {
        case "busy":
            return WhatsNewFooter.words("Finish this first, then install: \(blockers.joined(separator: ", ")). The glasses server was not touched.")
        case "quitTimeout":
            return AppUpdateFailureRecord.quitTimeoutWords
        case "recording":
            return AppUpdateFailureRecord.recordingWords
        case "notStaged":
            return "The downloaded update could not be checked, so nothing was installed. Choose Try again."
        default:
            return "The update did not install. Choose Try again."
        }
    }

    static let quitTimeoutWords = "COS Control could not close for the update, so nothing was installed. Choose Try again. If it happens again, quit COS Control from the menu bar, reopen it, and try once more."
    /// 0.5.322: the swap never closes Control while a Mac recording is starting, recording or stopping.
    static let recordingWords = "A Mac recording is running, so nothing was installed. Finish the Mac recording, then choose Try again."

    /// 0.5.322: the swap gave up with Control still open (it reopens nothing): the install ends at once, in these words,
    /// instead of at the 75 s deadline. busy and notStaged are not here: the swap waits for Control to quit and reopens it.
    static let endsApply: Set<String> = ["quitTimeout", "recording"]
    var endsApply: Bool { Self.endsApply.contains(reason) }
}

/// 0.5.322: the launch offer "Finish installing <version>". The helper's `staged-app-update` reports the pending stage
/// and the swap's last records; the offer stands only for a stage it checked (signature, bundle id, version, build),
/// newer than the running build, whose last install stopped on a quit that could not happen (quitTimeout or recording)
/// in the last 30 minutes, with no successful install since.
enum AppUpdateFinishOffer {
    static let window: TimeInterval = 30 * 60
    /// The helper and the app clocks may differ a little; a record this far in the future still counts.
    static let skew: TimeInterval = 120

    static func offer(_ details: [String: JSONValue], currentBuild: Int, now: Date = Date()) -> (version: String, build: Int)? {
        guard details["reason"]?.string == "staged", let version = details["version"]?.string,
              AppUpdateVersion.components(version) != nil,
              let raw = details["build"]?.int, raw > currentBuild,
              let reason = details["failureReason"]?.string, AppUpdateFailureRecord.endsApply.contains(reason),
              let at = details["failureAt"]?.string.flatMap({ ISO8601DateFormatter().date(from: $0) }) else { return nil }
        let age = now.timeIntervalSince(at)
        guard age <= window, age >= -skew else { return nil }
        if let success = details["successAt"]?.string.flatMap({ ISO8601DateFormatter().date(from: $0) }), success >= at { return nil }
        return (version, raw)
    }
}

/// The What's New footer for each phase of AppUpdateFlow, and after an update. Download and install runs
/// installAppUpdate, the existing path (busy refusal, the helper's meeting and drain refusals, the SHA-256 check, and
/// AppUpdateStageCheck); the window only reflects it.
struct WhatsNewFooter: Equatable, Sendable {
    enum Primary: Equatable, Sendable {
        /// Ready: Download and install.
        case install
        /// The install failed: Try again (the same path again).
        case tryAgain
        /// 0.5.322: a staged build is ready: Finish installing (no download).
        case finish
        /// Nothing to install: the offer went away, or this is the window after an update.
        case hidden
    }

    static let installTitle = "Download and install"
    static let retryTitle = "Try again"
    static let finishTitle = "Finish installing"
    /// 0.5.322: under the staged offer.
    static let finishWords = "Already downloaded and checked. COS Control could not close last time, so it was not installed."
    /// Under the buttons while there is something to install: what an install does to Control and to the server.
    static let reassurance = "COS Control quits and reopens by itself. The glasses server keeps running."
    /// While an install runs: closing the window is allowed and stops nothing.
    static let closeNote = "Closing this window does not stop the install."

    let primary: Primary
    let primaryEnabled: Bool
    let cancelTitle: String
    let cancelEnabled: Bool
    /// The progress word, the failure in plain words, or why Download and install is waiting.
    let status: String?
    let failed: Bool
    let working: Bool
    /// The reassurance line under the buttons; not on the window after an update.
    let showsReassurance: Bool

    var primaryTitle: String? {
        switch primary {
        case .install: return Self.installTitle
        case .tryAgain: return Self.retryTitle
        case .finish: return Self.finishTitle
        case .hidden: return nil
        }
    }

    private init(primary: Primary, primaryEnabled: Bool, cancelTitle: String, cancelEnabled: Bool, status: String?,
                 failed: Bool, working: Bool, showsReassurance: Bool) {
        self.primary = primary; self.primaryEnabled = primaryEnabled
        self.cancelTitle = cancelTitle; self.cancelEnabled = cancelEnabled
        self.status = status; self.failed = failed; self.working = working; self.showsReassurance = showsReassurance
    }

    /// The window after an update: Done, and nothing to install.
    static let installed = WhatsNewFooter(primary: .hidden, primaryEnabled: false, cancelTitle: "Done", cancelEnabled: true,
                                          status: nil, failed: false, working: false, showsReassurance: false)

    /// `reason` and `minMacOS` are the last check's (AppUpdateInfo), for the words when nothing is offered.
    /// 0.5.322: while applying, until Control is gone (the swap reopens the new build).
    static let installingWords = "Closing COS Control\u{2026}"

    init(_ phase: AppUpdatePhase, busy: Bool, reason: String? = nil, minMacOS: String? = nil, quitWaitingOn: String? = nil,
         finishesStaged: Bool = false) {
        let waiting = "COS Control is finishing another task. Download and install is available when it is done."
        switch phase {
        case .none:
            self.init(primary: .hidden, primaryEnabled: false, cancelTitle: "Close", cancelEnabled: true,
                      status: Self.noOfferWords(reason: reason, minMacOS: minMacOS), failed: false, working: false, showsReassurance: false)
        case .ready where finishesStaged:
            self.init(primary: .finish, primaryEnabled: !busy, cancelTitle: "Cancel", cancelEnabled: true,
                      status: busy ? waiting : Self.finishWords, failed: false, working: false, showsReassurance: true)
        case .ready:
            self.init(primary: .install, primaryEnabled: !busy, cancelTitle: "Cancel", cancelEnabled: true,
                      status: busy ? waiting : nil, failed: false, working: false, showsReassurance: true)
        case .staging(let line):
            // Close, enabled: closing the window stops nothing (the close note says so).
            self.init(primary: .install, primaryEnabled: false, cancelTitle: "Close", cancelEnabled: true,
                      status: Self.progressWord(line), failed: false, working: true, showsReassurance: true)
        case .applying:
            self.init(primary: .install, primaryEnabled: false, cancelTitle: "Close", cancelEnabled: true,
                      status: quitWaitingOn.map { "Saving \($0) first, then COS Control closes and installs." } ?? Self.installingWords,
                      failed: false, working: true, showsReassurance: true)
        case .failed(let message):
            self.init(primary: .tryAgain, primaryEnabled: !busy, cancelTitle: "Cancel", cancelEnabled: true,
                      status: Self.words(message), failed: true, working: false, showsReassurance: true)
        }
    }

    /// Nothing offered: why, in words. A paused feed or a newer macOS is never "up to date".
    static func noOfferWords(reason: String?, minMacOS: String?) -> String {
        switch reason {
        case "killSwitch": return "Updates are paused by the publisher right now."
        case "requiresMacOS":
            return minMacOS.map { "This update needs macOS \($0) or later." } ?? "This update needs a newer version of macOS."
        case "unreachable", "malformed": return "COS Control could not reach the update feed."
        default: return "COS Control is up to date."
        }
    }

    /// The helper's staging lines ("Downloading COS Control update…", "Checking SHA-256…", "Unpacking update…") as one
    /// short word each; any other line as itself.
    static func progressWord(_ line: String?) -> String {
        guard let line, !line.isEmpty else { return "Downloading…" }
        if line.hasPrefix("Downloading ") && line.contains(" MB") { return line }   // the flow's byte line, with time left
        if line.contains("Downloading") { return "Downloading…" }
        if line.contains("SHA-256") || line.hasPrefix("Checking") { return "Checking…" }
        if line.contains("Unpacking") { return "Unpacking…" }
        return line
    }

    /// The helper's refusal while COS is busy ("Finish this first, then install: meeting=1, video upload. The glasses
    /// server was not touched.") in words: "Finish your meeting and the video upload first, then install. The glasses
    /// server was not touched." Any other message as itself.
    static func words(_ message: String) -> String {
        let prefix = "Finish this first, then install: "
        guard message.hasPrefix(prefix) else { return message }
        let tail = "The glasses server was not touched."
        var list = String(message.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        let untouched = list.hasSuffix(tail)
        if untouched { list = String(list.dropLast(tail.count)).trimmingCharacters(in: .whitespaces) }
        if list.hasSuffix(".") { list.removeLast() }
        var names: [String] = []
        for key in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !key.isEmpty {
            let kind = key.split(separator: "=").first.map(String.init) ?? key
            let name: String
            if kind.contains("meeting") || kind.contains("recording") || kind.contains("transcri") { name = "your meeting" }
            else if kind.contains("video") { name = "the video upload" }
            else if kind.contains("agent") || kind.contains("job") || kind.contains("turn") { name = "the agent work" }
            else { name = "the active COS work" }
            if !names.contains(name) { names.append(name) }
        }
        let joined: String
        switch names.count {
        case 0: joined = "the active COS work"
        case 1: joined = names[0]
        default: joined = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
        return "Finish \(joined) first, then install." + (untouched ? " \(tail)" : "")
    }
}

/// Which window: an offer to install, or the build just installed (once, after an update).
enum WhatsNewMode: Equatable, Sendable {
    case offer
    case installed(content: WhatsNewContent, version: String, build: Int)
}

/// Everything the window draws, for either mode.
struct WhatsNewPresentation: Equatable, Sendable {
    /// "What's New in 0.5.275"; "What's New" when no version is known.
    let title: String
    /// "Build 328", a small line under the rule; nil when the appcast names no build.
    let byline: String?
    let content: WhatsNewContent
    let footer: WhatsNewFooter

    static func title(_ version: String?) -> String { version.map { "What's New in \($0)" } ?? "What's New" }

    /// An offer. While an install runs, `frozen` (the content when Download and install was pressed) is shown, so a
    /// check that lands mid-install cannot swap the words; the version and build are the flow's, which an install
    /// also holds.
    static func offer(_ info: AppUpdateInfo, flow: AppUpdateFlow, frozen: WhatsNewContent?, busy: Bool) -> WhatsNewPresentation {
        let content = flow.installing ? (frozen ?? WhatsNewContent(info)) : WhatsNewContent(info)
        return WhatsNewPresentation(title: title(flow.version), byline: flow.build.map { "Build \($0)" }, content: content,
                                    footer: WhatsNewFooter(flow.phase, busy: busy, reason: info.reason, minMacOS: info.minMacOS, quitWaitingOn: flow.quitWaitingOn,
                                                           finishesStaged: flow.finishesStaged))
    }

    static func present(_ mode: WhatsNewMode, info: AppUpdateInfo, flow: AppUpdateFlow, frozen: WhatsNewContent?, busy: Bool) -> WhatsNewPresentation {
        switch mode {
        case .offer:
            return offer(info, flow: flow, frozen: frozen, busy: busy)
        case let .installed(content, version, build):
            return WhatsNewPresentation(title: title(version), byline: "Build \(build)", content: content, footer: .installed)
        }
    }
}

/// QA 2026-10-09 (live in 0.5.274): stage-app-update answered ok:true WITHOUT staging when the feed was unreachable,
/// paused, malformed or already up to date, and installAppUpdate then applied, quit, and the detached swap found
/// nothing to install, so Control never reopened. The helper now refuses those (ok:false), and the app asks again: only
/// a stage that says it staged (reason "staged", or none from a helper that names none), names the staged app, and
/// staged the build that was offered may be applied. Anything else is a failure in words, with no apply and no quit.
enum AppUpdateStageCheck {
    static func refusal(_ details: [String: JSONValue], offeredBuild: Int?) -> String? {
        let reason = details["reason"]?.string
        switch reason {
        case nil, "staged": break
        case "unreachable": return "COS Control could not reach the update feed. Nothing was installed."
        case "killSwitch": return "Updates are paused by the publisher right now. Nothing was installed."
        case "malformed": return "The update listing is missing a SHA-256. Nothing was installed."
        case "upToDate": return "COS Control is already up to date. Nothing was installed."
        default: return "The update was not staged. Nothing was installed."
        }
        guard let path = details["stagedAppPath"]?.string, !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "The update was not staged. Nothing was installed."
        }
        if let offeredBuild {
            guard let staged = details["latestBuild"]?.int else { return "The update was not staged. Nothing was installed." }
            if staged != offeredBuild {
                return "The staged update is build \(staged), not the offered build \(offeredBuild). Nothing was installed."
            }
        }
        return nil
    }
}

/// The window after an update: once, on the first launch of a new build. The first launch ever only remembers the
/// build. The window waits for a check that reached the feed (so it can show this build's whatsNew), and while a
/// meeting is recording it waits for the meeting to end, so it never takes the focus mid-meeting.
enum WhatsNewAfterUpdate {
    static let defaultsKey = "cos.whatsNew.lastSeenBuild"

    enum Launch: Equatable, Sendable {
        /// No build remembered: remember this one, show nothing.
        case firstRun
        /// A newer build than the one remembered: show once.
        case updated
        /// The same build (or an older one, after a rollback): nothing.
        case seen
    }

    /// `installedByUpdater` is the build in the updater's success record (updates/success.json, written by the swap).
    /// QA round 2: 0.5.274 never stored a build, so a launch with nothing remembered is an UPDATE when the updater just
    /// installed this very build, and a first run otherwise (a fresh install, or a record of another build).
    static func launch(lastSeen: Int?, running: Int, installedByUpdater: Int? = nil) -> Launch {
        guard let lastSeen else { return installedByUpdater == running ? .updated : .firstRun }
        return lastSeen < running ? .updated : .seen
    }

    /// The build in updates/success.json (`{"version": "0.5.275", "build": 328, "appliedAt": "…"}`); nil for anything else.
    static func updaterBuild(_ data: Data?) -> Int? {
        guard let data, let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return value.object?["build"]?.int
    }

    /// Show now? Only for an update, after a check that reached the feed, with no meeting recording.
    static func shouldShow(_ launch: Launch, checkReached: Bool, meetingActive: Bool) -> Bool {
        launch == .updated && checkReached && !meetingActive
    }

    /// The words for the build that is running: the appcast's when its stable entry IS this build, else the copy that
    /// shipped inside this build (Resources/WhatsNew.json, used only when its version is this one), else one line.
    static func content(appcast info: AppUpdateInfo, bundled: Data?, version: String, build: Int) -> WhatsNewContent {
        if info.latestBuild == build, info.latestVersion == version, info.whatsNew != nil || info.notes != nil {
            return WhatsNewContent(info)
        }
        if let bundled, let shipped = bundledWhatsNew(bundled, version: version) {
            return WhatsNewContent(summary: shipped.summary, sections: shipped.sections)
        }
        return WhatsNewContent(summary: "COS Control \(version) is installed.", sections: [])
    }

    /// Resources/WhatsNew.json: `{ "version": "0.5.275", "whatsNew": { … } }`. Nil unless the version is `version`, so
    /// a file left over from an older release is never shown as this one's.
    static func bundledWhatsNew(_ data: Data, version: String) -> AppUpdateWhatsNew? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let object = value.object,
              object["version"]?.string == version else { return nil }
        return AppUpdateWhatsNew(object["whatsNew"])
    }
}

/// Where the last build that showed (or skipped) the window is remembered. UserDefaults in the app; memory in a test
/// or render model, so a check never writes the real defaults.
final class WhatsNewSeenStore: @unchecked Sendable {
    private let defaults: UserDefaults?
    private var memory: Int?

    init(defaults: UserDefaults?, initial: Int? = nil) {
        self.defaults = defaults
        memory = initial
    }

    var lastSeenBuild: Int? {
        get {
            guard let defaults else { return memory }
            return defaults.object(forKey: WhatsNewAfterUpdate.defaultsKey) as? Int
        }
        set {
            guard let defaults else { memory = newValue; return }
            defaults.set(newValue, forKey: WhatsNewAfterUpdate.defaultsKey)
        }
    }
}

/// What a manual update check found. `skipped`: a manual check was already running, so this one never started.
enum ManualUpdateCheckOutcome: Equatable, Sendable {
    case updateFound, upToDate, skipped
    /// The check failed; its own words (the helper's error, or the feed being unreachable).
    case failed(String)
}

/// 2026-10-09 (Miles, after the 0.5.276 gold banner): the standing version card is gone. The panel header's refresh
/// button also checks for updates and answers in the header's subtitle line, under "Control". An update found needs no
/// words there: the gold banner and What's New answer it. A result holds for a few seconds, then the line goes back to
/// what it always says. The version itself is the header's stamp after the title, so "Up to date" stands alone.
enum HeaderUpdateStatus: Equatable, Sendable {
    case idle, checking, upToDate, failed

    static let checkingText = "Checking for updates…"
    static let upToDateText = "Up to date"
    static let failedText = "Couldn't check for updates"
    static let upToDateHold: Duration = .seconds(4)
    static let failedHold: Duration = .seconds(6)

    /// The words for the subtitle line; `idle` is the line's own words (the panel's, or Settings').
    func text(idle: String) -> String {
        switch self {
        case .idle: idle
        case .checking: Self.checkingText
        case .upToDate: Self.upToDateText
        case .failed: Self.failedText
        }
    }

    /// How long a result stays before the line goes back to idle. Nil: it stays until something changes it.
    var hold: Duration? {
        switch self {
        case .upToDate: Self.upToDateHold
        case .failed: Self.failedHold
        case .idle, .checking: nil
        }
    }

    /// The line after a check from the header ends.
    static func after(_ outcome: ManualUpdateCheckOutcome) -> HeaderUpdateStatus {
        switch outcome {
        case .upToDate: .upToDate
        case .failed: .failed
        case .updateFound, .skipped: .idle
        }
    }

    /// What the line shows: Checking while any manual check runs, else the last header result.
    static func shown(inFlight: Bool, status: HeaderUpdateStatus) -> HeaderUpdateStatus {
        inFlight ? .checking : status
    }

    /// What VoiceOver announces when a result lands: the results only, never idle or Checking.
    var announcement: String? {
        switch self {
        case .upToDate: Self.upToDateText
        case .failed: Self.failedText
        case .idle, .checking: nil
        }
    }

    /// The refresh button checks for updates only when nothing else owns the app: not while an install is staging or
    /// applying, and not while the panel is busy (QA 2026-10-09, W2). The refresh itself always runs.
    static func checkAllowed(phase: AppUpdatePhase, busy: Bool) -> Bool {
        if busy { return false }
        switch phase {
        case .staging, .applying: return false
        case .none, .ready, .failed: return true
        }
    }
}

/// When the appcast is read. The helper's own fetch is bounded (6 s request, 8 s wait); the app bounds the whole helper
/// run as well, so a wedged helper never holds the in-flight slot. Only one check runs at a time: a trigger that
/// arrives during a check is dropped (launch, periodic, panel open) or waits for it (the header's refresh button).
struct AppUpdateCheckSchedule: Equatable, Sendable {
    enum Trigger: String, Sendable {
        case launch, periodic, panelOpen, manual
    }

    static let periodicInterval: TimeInterval = 6 * 60 * 60
    static let panelOpenStaleAfter: TimeInterval = 15 * 60
    static let helperTimeout: TimeInterval = 20
    /// The periodic loop wakes at least this often, so a Mac that slept through the 6-hour mark checks soon after it
    /// wakes rather than a full interval later.
    static let maximumNap: TimeInterval = 15 * 60

    private(set) var lastStarted: Date?
    private(set) var inFlight = false

    func shouldStart(_ trigger: Trigger, now: Date) -> Bool {
        guard !inFlight else { return false }
        guard let lastStarted else { return true }
        let age = now.timeIntervalSince(lastStarted)
        switch trigger {
        case .launch, .manual: return true
        case .periodic: return age >= Self.periodicInterval
        case .panelOpen: return age >= Self.panelOpenStaleAfter
        }
    }

    mutating func begin(_ trigger: Trigger, now: Date) -> Bool {
        guard shouldStart(trigger, now: now) else { return false }
        inFlight = true
        lastStarted = now
        return true
    }

    mutating func finish() { inFlight = false }

    /// How long the periodic loop sleeps before it asks again: until 6 hours after the last check of any kind, at most
    /// `maximumNap`, never less than a second.
    func nextNap(now: Date) -> TimeInterval {
        guard let lastStarted else { return 1 }
        let due = Self.periodicInterval - now.timeIntervalSince(lastStarted)
        return min(Self.maximumNap, max(1, due))
    }
}

/// The status-item glyph. The eyeglasses / eyeglasses.slash name stays at the call site so running state shows with
/// the panel closed.
///
/// `.normal` is a template image, so the menu bar tints it (black, white, or the highlight) exactly as before.
/// `.updateReady` is NOT a template: a menu bar ignores color in a template image, so this one is drawn in COS gold
/// with a dot above-right of the right lens, in a canvas `dotRoom` wider so the dot never touches the glyph (no knockout:
/// 2026-10-09 QA, a ring cut the lens into a broken "C"). The gold is resolved
/// when the menu bar draws the image, against the menu bar's own appearance: #89662d on a light bar, #c9a86e on a dark
/// one (COSInk.accentNS; Tests/AppUpdateBadgeRender.swift compares the two). The light value alone is above 4:1 against
/// white and black, so the icon stays legible even where the appearance is resolved differently. Drawn 1:1 at the
/// symbol's own size: filling a square is what squashed the eyeglasses in 0.5.90.
enum MenuBarIcon {
    enum Variant: String, Sendable {
        case normal, updateReady, recording, recordingAndUpdate
    }

    static let pointSize: CGFloat = 16
    static let dotDiameter: CGFloat = 4.5
    /// Extra width on the right of the ready image, so the dot sits outside the glyph's ink. The glyph is still drawn
    /// 1:1 at its own size (never stretched: the 0.5.90 squash).
    static let dotRoom: CGFloat = 2

    static let updateTint = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.788, green: 0.659, blue: 0.431, alpha: 1)
            : NSColor(red: 0.537, green: 0.400, blue: 0.176, alpha: 1)
    }

    /// Any phase but `.none` means an update is waiting (an install that failed still has its update waiting). A failed
    /// CHECK never gets here: it leaves the phase at none, so it never tints the icon.
    static func variant(for phase: AppUpdatePhase, recording: Bool = false) -> Variant {
        if recording { return phase == .none ? .recording : .recordingAndUpdate }
        return phase == .none ? .normal : .updateReady
    }

    static func accessibilityLabel(_ variant: Variant) -> String {
        switch variant {
        case .normal: "COS Control"
        case .updateReady: "COS Control, update available"
        case .recording: "COS Control, meeting recording"
        case .recordingAndUpdate: "COS Control, meeting recording, update available"
        }
    }

    /// The label re-renders on every status refresh; each image (server state, recording and update state) is made once.
    @MainActor private static var made: [String: NSImage] = [:]
    @MainActor static func image(systemName: String, variant: Variant) -> NSImage {
        let key = systemName + "|" + variant.rawValue
        if let image = made[key] { return image }
        let image = compose(systemName: systemName, variant: variant)
        made[key] = image
        return image
    }

    static func compose(systemName: String, variant: Variant) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let base = (NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)) ?? NSImage(size: NSSize(width: pointSize * 1.6, height: pointSize * 0.7))
        let glyph = base.size
        guard glyph.width > 0, glyph.height > 0 else {
            let empty = NSImage(size: NSSize(width: pointSize, height: pointSize))
            empty.isTemplate = true
            return empty
        }
        let ready = variant != .normal
        let recording = variant == .recording || variant == .recordingAndUpdate
        let canvas = ready ? NSSize(width: glyph.width + dotRoom, height: glyph.height) : glyph
        let composed = NSImage(size: canvas, flipped: false) { rect in
            base.draw(in: NSRect(origin: .zero, size: glyph))
            guard ready, let context = NSGraphicsContext.current else { return true }
            context.saveGraphicsState()
            // Keep the glyph alpha: gold for an update, appearance-aware ink for recording alone.
            context.compositingOperation = .sourceAtop
            (variant == .recording ? NSColor.labelColor : updateTint).setFill()
            rect.fill()
            // The dot in the canvas's top-right corner, clear of the lens (Tests/AppUpdateBadgeChecks.swift measures it).
            let dot = NSRect(x: rect.maxX - dotDiameter, y: rect.maxY - dotDiameter, width: dotDiameter, height: dotDiameter)
            context.compositingOperation = .sourceOver
            (recording ? NSColor.systemRed : updateTint).setFill()
            NSBezierPath(ovalIn: dot).fill()
            context.restoreGraphicsState()
            return true
        }
        composed.isTemplate = !ready
        composed.accessibilityDescription = accessibilityLabel(variant)
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
    /// 6.47.0. "merge" or "split" on a record COS derived; nil on a real capture.
    /// NIL AND "" ARE DIFFERENT HERE: an optional says the server did not claim
    /// this row is derived, which an empty string would quietly make into a claim.
    let derivedKind: String?
    /// The action that made this record, so a detail can offer Undo.
    let actionId: String?
    /// Where the meeting actually came from, when `domain` reads "imported".
    let originDomain: String?
    /// Additive 6.36.18+. Nil on older servers — do not treat as zero unnamed.
    let voiceCount: Int?
    let unattributedVoices: Int?
    let namedVoices: Int?
    let humanTouched: Bool?

    var id: String { sessionId }

    /// "2026-08-28 · 11:51 · 52 minutes". The clock time earns its place once
    /// the list can be sorted chronologically: a dozen rows all reading
    /// "2026-08-28" give the reader no way to see that the order is real.
    var dateLine: String { dateLine(clock: .twentyFourHour) }

    func dateLine(clock: ClockStyle) -> String {
        var parts = [date]
        if !time.isEmpty { parts.append(clock.format(time)) }
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
        derivedKind = o["derivedKind"]?.string
        actionId = o["actionId"]?.string
        originDomain = o["originDomain"]?.string
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

/// How a clock time reads on screen (0.5.234). The server sends every meeting
/// time as a zero-padded 24-hour `HH:mm`, and through 0.5.233 the Meetings tab
/// printed it as-is: "13:02" (Miles, 2026-09-17: "Rather than 13, we should see
/// 1:02 pm"). Twelve-hour is the default; the 24-hour reading is a setting
/// under Advanced. The wire string is never rewritten — sorting, recency and
/// the merge sides all keep reading `time` raw — only what is drawn changes.
enum ClockStyle: String, CaseIterable, Sendable {
    case twelveHour
    case twentyFourHour

    static let defaultsKey = "cos.clockStyle"

    static func load(_ raw: String?) -> ClockStyle {
        raw.flatMap(ClockStyle.init(rawValue:)) ?? .twelveHour
    }

    var label: String {
        switch self {
        case .twelveHour: "12-hour (1:02 PM)"
        case .twentyFourHour: "24-hour (13:02)"
        }
    }

    /// "13:02" reads as "1:02 PM"; "00:37" as "12:37 AM"; "12:00" as "12:00 PM".
    /// Anything that is not `H:mm` / `HH:mm` (an empty string, a stray
    /// "14:30:12", a word) comes back untouched, so a server that changes the
    /// shape of `time` degrades to the old rendering rather than to nothing.
    func format(_ hhmm: String) -> String {
        guard self == .twelveHour else { return hhmm }
        let parts = hhmm.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 2,
              (1...2).contains(parts[0].count),
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return hhmm }
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", twelve, minute, hour < 12 ? "AM" : "PM")
    }
}

/// Future phone consumer boundary. IDs are immutable and namespaces never cross sources.
enum PhoneMeetingCapture {
    static let idPattern = #"\Aphone_(?:[0-9]{13}_)?[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\z"#
    static let contextPattern = #"\A(?:(?:g2|ff|mac):(?!phone_)[A-Za-z0-9:_-]{3,96}|phone:phone_(?:[0-9]{13}_)?[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\z"#
    static let anonymousNote = "iPhone microphone recordings are anonymous. Names and voice training are unavailable."
    static let stopNote = "Stop on iPhone"
    nonisolated static func validID(_ id: String) -> Bool { id.range(of: idPattern, options: .regularExpression) != nil }
    /// Prefix detection also fences malformed phone input; it must never become a glasses or Mac action.
    nonisolated static func protected(_ id: String, sourceType: String? = nil) -> Bool {
        id.hasPrefix("phone_") || sourceType == "iphone_microphone"
    }
    nonisolated static func validContextKey(_ key: String) -> Bool { key.range(of: contextPattern, options: .regularExpression) != nil }
    nonisolated static func contextKeys(_ keys: [String], sessionId: String, sourceType: String?) -> [String] {
        keys.filter { key in
            guard validContextKey(key) else { return false }
            if protected(sessionId, sourceType: sourceType) { return validID(sessionId) && key == "phone:" + sessionId }
            return !key.hasPrefix("phone:")
        }
    }
    nonisolated static func askSession(forKey key: String) -> String? {
        guard validContextKey(key), let colon = key.firstIndex(of: ":") else { return nil }
        let prefix = String(key[..<colon]), id = String(key[key.index(after: colon)...])
        switch prefix {
        case "phone": return validID(id) ? id : nil
        case "mac": return id.range(of: #"\Amac_[A-Fa-f0-9]{8}(?:-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}\z"#, options: .regularExpression) != nil ? id : nil
        case "g2": return id.range(of: #"\Ameeting_[A-Za-z0-9_-]{1,89}\z"#, options: .regularExpression) != nil ? id : nil
        default: return nil
        }
    }
}

/// A saved meeting in the Activity library. sessionId is optional — Granola and
/// Fireflies rows still open transcript and summary.
struct LibraryMeeting: Identifiable, Sendable, Hashable {
    /// 0.5.258: a server context key (`g2:` or `ff:` and the server's marker grammar). The same rule as
    /// `WorkCardFiles.validMeetingKey`, kept here because some compile lists build the models without the card files
    /// (Tests/work-card-files-pins.py pins the two patterns equal).
    nonisolated static func validContextKey(_ key: String) -> Bool {
        PhoneMeetingCapture.validContextKey(key)
    }
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
    let sourceType: String?
    let speakerPolicy: String?
    /// One of five values from 6.47.0 on: `cos_operations`, `direct_library`,
    /// `standalone_recordings`, `imported`, `blended`. Empty on an older server.
    let librarySource: String
    let topicCount: Int
    let decisionCount: Int
    let actionCount: Int
    let attendeeCount: Int
    /// 6.47.0 derived records. Nil on a capture, an import, or an older server.
    let derivedKind: String?
    let actionId: String?
    /// Every G2 capture a merged record holds, earliest first.
    let g2SessionIds: [String]
    /// The long recording a split piece came out of.
    let sourceSessionId: String?
    /// Original recording identities survive renames and Fireflies merges. Older/direct rows may carry only sessionId.
    func meetingAskSessions(keys: [String]) -> [String] {
        var seen = Set<String>()
        let candidates = keys.compactMap(PhoneMeetingCapture.askSession(forKey:))
            + g2SessionIds + (sourceSessionId.map { [$0] } ?? [sessionId])
        return candidates.filter { id in
            if PhoneMeetingCapture.protected(sessionId, sourceType: sourceType) && !PhoneMeetingCapture.protected(id) { return false }
            if PhoneMeetingCapture.protected(id) {
                return sourceType == "iphone_microphone" && id == sessionId && PhoneMeetingCapture.validID(id) && seen.insert(id).inserted
            }
            return PhoneMeetingCapture.askSession(forKey: Self.captureContextKey(id)) != nil && seen.insert(id).inserted
        }
    }
    nonisolated static func captureContextKey(_ session: String) -> String {
        if PhoneMeetingCapture.protected(session) { return PhoneMeetingCapture.validID(session) ? "phone:" + session : "" }
        return (session.hasPrefix("mac_") ? "mac:" : "g2:") + session
    }

    /// Which piece of that recording this is. Nil on anything but a split.
    let pieceIndex: Int?
    /// Where an imported or derived meeting actually came from.
    let originDomain: String?
    /// False on an imported or derived record: nothing here may be corrected in
    /// place, because the capture that could be corrected is a different file.
    let mutable: Bool
    /// 0.5.258 (server 6.64.0): the keys this meeting's dropped files are filed under, first = primary; whether files can
    /// be added (nil: an older server said nothing); and why not.
    let contextKeys: [String]
    let contextSupported: Bool?
    let contextAmbiguous: Bool
    let contextReason: String

    /// IDENTITY IS `recordId`, and that is load-bearing for split pieces. Two
    /// pieces of one recording share a source session and differ only by their
    /// own record id; keying on the session would collapse them onto each other.
    var id: String { recordId }

    var isDerived: Bool { !(derivedKind ?? "").isEmpty }
    var isMerged: Bool { derivedKind == "merge" }
    var isSplitPiece: Bool { derivedKind == "split" }
    var isImported: Bool { librarySource == "imported" }

    var domainLabel: String {
        if !domainAbbr.isEmpty { return domainAbbr }
        // An imported row's `domain` is the literal routing word "imported"; the
        // domain a reader recognizes is where the meeting came from.
        let name = domain == "imported" ? (originDomain ?? domain) : domain
        let spaced = name.replacingOccurrences(of: "_", with: " ")
        return spaced.localizedCapitalized
    }

    /// The wire reading, 24-hour. Views draw `subtitle(clock:)`; this stays the
    /// stable form for tests and for anything that compares rows by text.
    var subtitle: String { subtitle(clock: .twentyFourHour) }

    func subtitle(clock: ClockStyle) -> String {
        var parts: [String] = []
        if !date.isEmpty { parts.append(date) }
        if !time.isEmpty { parts.append(clock.format(time)) }
        if !domainLabel.isEmpty { parts.append(domainLabel) }
        if !duration.isEmpty { parts.append(duration) }
        else if durationMinutes > 0 { parts.append("\(durationMinutes) min") }
        if PhoneMeetingCapture.protected(sessionId, sourceType: sourceType) { parts.append("iPhone Microphone") }
        else if !source.isEmpty { parts.append(source) }
        return parts.joined(separator: " · ")
    }

    /// Whether this row can offer Review voices.
    ///
    /// THE MUTABLE GUARD, stated once. An imported meeting has no audio at all,
    /// and a split piece is a span rather than a capture — neither has anything a
    /// correction could rewrite, and the server refuses both by id kind
    /// (`imported_read_only`, `blended_derived_record`). A MERGED row is
    /// different and deliberately allowed: its `sessionId` is the earliest G2
    /// capture it holds, that capture is a real recording with real audio, and
    /// relabelling it is how its voice profile gets better.
    var canReviewVoices: Bool { !sessionId.isEmpty && !isImported && !isSplitPiece && !PhoneMeetingCapture.protected(sessionId, sourceType: sourceType) }

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
        sourceType = o["sourceType"]?.string
        speakerPolicy = o["speakerPolicy"]?.string
        librarySource = o["librarySource"]?.string ?? ""
        topicCount = o["topicCount"]?.int ?? Int(o["topicCount"]?.string ?? "") ?? 0
        decisionCount = o["decisionCount"]?.int ?? Int(o["decisionCount"]?.string ?? "") ?? 0
        actionCount = o["actionCount"]?.int ?? Int(o["actionCount"]?.string ?? "") ?? 0
        attendeeCount = o["attendeeCount"]?.int ?? Int(o["attendeeCount"]?.string ?? "") ?? 0
        derivedKind = o["derivedKind"]?.string
        actionId = o["actionId"]?.string
        g2SessionIds = o["g2SessionIds"]?.array?.compactMap(\.string) ?? []
        contextKeys = PhoneMeetingCapture.contextKeys(o["contextKeys"]?.array?.compactMap(\.string) ?? [], sessionId: o["sessionId"]?.string ?? "", sourceType: o["sourceType"]?.string)
        contextSupported = o["contextSupported"]?.bool
        contextAmbiguous = o["contextAmbiguous"]?.bool ?? false
        contextReason = o["contextReason"]?.string ?? ""
        sourceSessionId = o["sourceSessionId"]?.string
        pieceIndex = o["pieceIndex"]?.int ?? Int(o["pieceIndex"]?.string ?? "")
        originDomain = o["originDomain"]?.string
        // DEFAULTS TRUE, because every row before 6.47.0 was correctable and a
        // false default would take Review voices away from the whole library on
        // an older server.
        mutable = o["mutable"]?.bool ?? true
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

/// 0.5.259 (Miles, 2026-10-06: "We need the ability to get to a meeting from the speaker view."): which Meetings row a
/// speaker review belongs to. The merged record comes first, because it is the row Meetings lists; then the capture's
/// own record; then any row carrying the review's session.
enum SpeakersMeetingLink {
    static func row(in rows: [LibraryMeeting], recordIds: [String], sessionId: String) -> LibraryMeeting? {
        for id in recordIds where !id.isEmpty {
            if let row = rows.first(where: { $0.recordId == id }) { return row }
        }
        guard !sessionId.isEmpty else { return nil }
        return rows.first { $0.sessionId == sessionId }
    }

    /// The days to look the meeting up on, best first (QA G-W1, 2026-10-07). A month read stops at 200 rows, and August
    /// 2026 held 320 meetings, so a month list cannot prove a meeting is missing; one day holds a few dozen at most. In
    /// order: the day a record's file name starts with (`ops:`, `direct:`, a filed `standalone:`), the review's own date
    /// (its write-up, then its Speakers row), then the start a G2 session id carries.
    static func days(recordIds: [String], reviewDates: [String?], sessionId: String, calendar: Calendar = .current) -> [String] {
        var out: [String] = []
        func add(_ day: String?) { if let day, isDay(day), !out.contains(day) { out.append(day) } }
        for id in recordIds { add(fileDay(ofRecordID: id)) }
        for date in reviewDates { add(date) }
        add(sessionDay(sessionId, calendar: calendar))
        return out
    }

    static func isDay(_ value: String) -> Bool {
        value.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$", options: .regularExpression) != nil
    }

    /// `ops:<domain>:<YYYY-MM>:<file>`, `direct:<YYYY-MM>:<file>` and `standalone:<domain>:<YYYY-MM>:<file>` name a file
    /// whose name starts with its day. A merge, an import or a `standalone:<session>` id names none.
    static func fileDay(ofRecordID id: String) -> String? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        let month: String, file: String
        switch parts.first {
        case "ops" where parts.count >= 4, "standalone" where parts.count >= 4:
            month = parts[2]; file = parts[3...].joined(separator: ":")
        case "direct" where parts.count >= 3:
            month = parts[1]; file = parts[2...].joined(separator: ":")
        default:
            return nil
        }
        let day = String(file.prefix(10))
        return isDay(day) && day.hasPrefix(month + "-") ? day : nil
    }

    /// `meeting_<epoch ms>_…`: the local day the capture started.
    static func sessionDay(_ sessionId: String, calendar: Calendar = .current) -> String? {
        let parts = sessionId.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "meeting", parts[1].count == 13, parts[1].allSatisfy(\.isASCII), parts[1].allSatisfy(\.isNumber),
              let ms = Double(parts[1]) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ms / 1000))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// One day's read of the library.
    enum DayRead: Sendable { case rows([LibraryMeeting]), failed(String) }
    /// What one day's read said.
    enum Lookup: Equatable { case answered(rows: Int), failed(String) }
    /// The helper's own cap on a day read. A day that fills it may hold more.
    static let dayLimit = 200

    /// The line a miss leaves in the review. Absence is said only when every day it could be on answered in full and none
    /// held it; anything less is a failure to load, with the reason when there is one.
    static func missNote(_ lookups: [Lookup]) -> String {
        if lookups.isEmpty { return "Couldn't load this meeting: its date isn't known." }
        for lookup in lookups {
            if case .failed(let reason) = lookup {
                let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return "Couldn't load this meeting." }
                return "Couldn't load this meeting: " + (trimmed.hasSuffix(".") ? trimmed : trimmed + ".")
            }
        }
        if lookups.contains(where: { if case .answered(let n) = $0 { return n >= dayLimit }; return false }) {
            return "Couldn't load this meeting: its day has more meetings than one read returns."
        }
        return "This meeting isn't in the meetings list."
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
    /// 6.47.0. The five `librarySource` values; empty on an older server.
    let librarySource: String
    /// "merge" or "split" on a derived record; nil on anything else.
    let derivedKind: String?
    let actionId: String?
    let recordId: String
    let mutable: Bool
    /// One row per input a merged record holds, so its sources stay reachable.
    let sources: [LibraryMeetingSource]
    /// 0.5.258 (server 6.64.0): as on the row.
    let contextKeys: [String]
    let contextSupported: Bool?
    let contextAmbiguous: Bool
    let contextReason: String

    var isDerived: Bool { !(derivedKind ?? "").isEmpty }

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
        librarySource = o["librarySource"]?.string ?? ""
        derivedKind = o["derivedKind"]?.string
        actionId = o["actionId"]?.string
        recordId = o["recordId"]?.string ?? ""
        mutable = o["mutable"]?.bool ?? true
        sources = o["sources"]?.array?.compactMap(LibraryMeetingSource.init) ?? []
        contextKeys = (o["contextKeys"]?.array?.compactMap(\.string) ?? []).filter(LibraryMeeting.validContextKey)
        contextSupported = o["contextSupported"]?.bool
        contextAmbiguous = o["contextAmbiguous"]?.bool ?? false
        contextReason = o["contextReason"]?.string ?? ""
    }
}

/// One input a merged record holds: the G2 capture or the Fireflies meeting it
/// was built from, and the record that still holds it.
///
/// A merge is ADDITIVE. Nothing is deleted, so the detail can always offer a way
/// back to each original, and a reader who disagrees with a merge can look at
/// what went into it before undoing anything.
struct LibraryMeetingSource: Identifiable, Sendable, Hashable {
    let kind: String
    let sourceId: String
    let recordId: String

    var id: String { recordId.isEmpty ? "\(kind):\(sourceId)" : recordId }

    var label: String {
        switch kind {
        case "g2": "G2 recording"
        case "mac": "Mac recording"
        case "fireflies": "Fireflies meeting"
        default: kind.localizedCapitalized
        }
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object else { return nil }
        let kind = o["kind"]?.string ?? ""
        let sourceId = o["id"]?.string ?? ""
        guard !kind.isEmpty, !sourceId.isEmpty else { return nil }
        self.kind = kind
        self.sourceId = sourceId
        recordId = o["recordId"]?.string ?? ""
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

/// 0.5.340 (server 6.90.0): a saved Mac recording's voices are labelled `Voice 1`, `Voice 2`, ... after save. Unnamed and
/// stable for the meeting, never a profile name. Everywhere Control asks "is this a name", a Voice label is not one, and
/// renaming it is text only: a Mac recording never makes or trains a voice profile.
enum MacVoiceLabel {
    /// Exactly the server's `^Voice [1-9]\d?$`.
    static func isVoice(_ label: String) -> Bool {
        label.range(of: #"\AVoice [1-9][0-9]?\z"#, options: .regularExpression) != nil
    }

    /// The Voice labels a transcript's `[Voice N]:` turns carry, in first-turn order, each once.
    static func voices(inTranscript transcript: String) -> [String] {
        var seen: Set<String> = [], out: [String] = []
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"), line[line.index(after: close)...].hasPrefix(":") else { continue }
            let label = String(line[line.index(after: line.startIndex)..<close])
            if isVoice(label), seen.insert(label).inserted { out.append(label) }
        }
        return out
    }

    /// Voices still waiting for a name. Each `Voice N` is one voice to name; an `Ext` or `Unknown` bucket left beside
    /// them is the low-confidence remainder of those same voices, never one more (Miles 2026-10-23: Voice N must never
    /// inflate "voices to name" for Ext). A meeting with no Voice label counts its placeholders exactly as before.
    static func unnamedCount(_ labels: [String]) -> Int {
        let voices = labels.filter(isVoice).count
        return voices > 0 ? voices : labels.count
    }

    /// A Mac recording's session id.
    static func isMacSession(_ sessionId: String) -> Bool { sessionId.hasPrefix("mac_") }
}

/// 0.5.340 copy for Mac recording voices. No em dashes or arrows.
enum MacVoiceCopy {
    static let renameNote = "Mac recordings rename text only, in this meeting. No voice profile is made or trained."
    static let menuTitle = "Rename voice"
    /// Voice numbers are anonymous; confirmed names and meeting-only renames remain separate.
    static let unattributedNote = "Voice numbers do not identify people. When voices can be distinguished, they appear as Voice 1, Voice 2 and so on; names appear only at high confidence. Name the ones you know; this changes this meeting only."

    static func menuItem(_ label: String) -> String { "Name \(label)" }
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
    /// 0.5.340: a Mac `Voice N` shows as itself, so Voice 1 and Voice 2 stay told apart while unnamed.
    var displayName: String { nameAsserted || MacVoiceLabel.isVoice(label) ? label : "Unidentified voice" }
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
    let sourceRevision: String?
    let identityVersion: Int?
    let mutable: Bool
    let librarySource: String
    /// 6.47.0. The merged record that holds this capture, when the panel asked
    /// through one.
    ///
    /// `recordId`, `mutable` and `librarySource` keep describing the CAPTURE —
    /// the file that holds the chunks and the one a correction rewrites — because
    /// a merge does not make a real recording uncorrectable. This field is the
    /// merged record beside it, not a replacement for any of them.
    let blendedRecordId: String?

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
        sourceRevision = o["sourceRevision"]?.string
        identityVersion = o["reviewIdentityVersion"]?.int
        mutable = o["mutable"]?.bool ?? true
        librarySource = o["source"]?.string ?? "standalone_recordings"
        blendedRecordId = o["blendedRecordId"]?.string
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

    /// 0.5.340: counted by `MacVoiceLabel.unnamedCount`, so a Mac recording's Ext remainder never adds a voice.
    var unnamedVoiceCount: Int { MacVoiceLabel.unnamedCount(voices.filter(\.isNameAssignment).map(\.label)) }
    /// A Mac recording renames text only: no profile is made, trained or offered for a global fold.
    var isMacRecording: Bool { MacVoiceLabel.isMacSession(sessionId) }

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
    /// 0.5.218 — the chunk indices the server will play back (`?chunk=` on the
    /// sample route; glasses-server 6.45.3). Empty on an older server, and then
    /// the panel shows no Listen control rather than one whose click would fail.
    let chunkIndices: [Int]

    var id: String { sessionId }

    init?(_ value: JSONValue?) {
        guard let o = value?.object,
              let sessionId = o["sessionId"]?.string,
              !sessionId.isEmpty else { return nil }
        self.sessionId = sessionId
        chunks = o["chunks"]?.int ?? 0
        ageHours = o["ageHours"]?.double ?? 0
        expiresIn = o["expiresIn"]?.string ?? ""
        chunkIndices = (o["chunkIndices"]?.array ?? []).compactMap { $0.int }.filter { $0 >= 0 }.sorted()
    }
}

/// 0.5.219 — one held sample, addressed the way glasses-server 6.45.4 addresses it.
struct HeldVoiceSuggestion: Sendable, Hashable {
    let name: String
    let similarity: Double
    let tier: String
    let agreeing: Int
    let ownerCaution: Bool
    init?(_ value: JSONValue?) {
        guard let o = value?.object, let name = o["name"]?.string, !name.isEmpty else { return nil }
        self.name = name
        similarity = o["similarity"]?.double ?? 0
        tier = o["tier"]?.string ?? "likely"
        agreeing = o["agreeing"]?.int ?? 0
        ownerCaution = o["ownerCaution"]?.bool ?? false
    }
}

struct HeldSampleRef: Identifiable, Sendable, Hashable {
    let sessionId: String
    let chunkIndex: Int
    let suggestion: HeldVoiceSuggestion?
    var id: String { "\(sessionId)#\(chunkIndex)" }

    init(sessionId: String, chunkIndex: Int) {
        self.sessionId = sessionId
        self.chunkIndex = chunkIndex
        suggestion = nil
    }
    init?(_ value: JSONValue?) {
        guard let o = value?.object,
              let sessionId = o["sessionId"]?.string, !sessionId.isEmpty,
              let chunkIndex = o["chunkIndex"]?.int, chunkIndex >= 0 else { return nil }
        self.sessionId = sessionId
        self.chunkIndex = chunkIndex
        suggestion = HeldVoiceSuggestion(o["suggestion"])
    }
    // Suggestion refreshes cannot change which sample a cursor or seed addresses.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    var payload: [String: Any] { ["sessionId": sessionId, "chunkIndex": chunkIndex] }
}

/// All three positions are required. A null mapping suppresses playback entirely.
struct HeldNamingPlayback: Identifiable, Sendable {
    let sessionId: String
    let chunkIndex: Int
    let position: Int
    var id: String { "\(sessionId)#\(chunkIndex)#\(position)" }
    init?(_ value: JSONValue?) {
        guard let o = value?.object, let session = o["sessionId"]?.string, !session.isEmpty,
              let chunk = o["chunkIndex"]?.int, chunk >= 0,
              let position = o["position"]?.int, position >= 0 else { return nil }
        sessionId = session; chunkIndex = chunk; self.position = position
    }
}

struct HeldNamingMeeting: Identifiable, Sendable {
    let raw: [String: JSONValue]
    let sessionId: String
    let status: String
    let error: String?
    let named: [Int]
    let wider: [Int]
    let labelled: Int
    let roomRisk: Bool
    let labelsNewerThanGraph: Bool
    let playback: [HeldNamingPlayback]
    var id: String { sessionId }
    var copySummaries: [String] {
        (raw["receipts"]?.array ?? raw["copies"]?.array ?? []).compactMap { value in
            guard let o = value.object, let copy = o["copy"]?.string else { return nil }
            return "\(copy): \(o["status"]?.string ?? status)\(o["error"]?.string.map { " — \($0)" } ?? "")"
        }
    }
    init?(_ value: JSONValue?) {
        guard let o = value?.object, let session = o["sessionId"]?.string, !session.isEmpty else { return nil }
        raw = o; sessionId = session; status = o["status"]?.string ?? "unknown"
        error = o["error"]?.string
        named = (o["namedChunks"]?.array ?? []).compactMap { $0.int }
        wider = (o["widerChunks"]?.array ?? []).compactMap { $0.int }
        labelled = o["labelled"]?.int ?? (named.count + wider.count)
        roomRisk = o["roomRisk"]?.bool ?? false
        labelsNewerThanGraph = o["labelsNewerThanGraph"]?.bool ?? false
        playback = (o["playback"]?.array ?? []).compactMap(HeldNamingPlayback.init)
    }
}

/// Preview readiness and durable enrollment/label/audio outcomes are separate.
/// A coherent member can be represented without adding another stored voiceprint.
struct HeldNamingMemberOutcome: Identifiable, Sendable {
    let sample: HeldSampleRef
    let status: String
    let enrollmentStatus: String
    let labelStatus: String
    let audioStatus: String
    let position: Int?
    let reason: String?
    var id: String { sample.id }
    var hasNoTranscriptPosition: Bool { labelStatus == "no_transcript_position" || status == "no_transcript_position" }
    init?(_ value: JSONValue?) {
        guard let o = value?.object, let sample = HeldSampleRef(value) else { return nil }
        self.sample = sample
        status = o["status"]?.string ?? "unknown"
        enrollmentStatus = o["enrollmentStatus"]?.string ?? "unknown"
        labelStatus = o["labelStatus"]?.string ?? "unknown"
        audioStatus = o["audioStatus"]?.string ?? "unknown"
        position = o["position"]?.int
        reason = o["reason"]?.string
    }
}

struct HeldNamingReceipt: Identifiable, Sendable {
    let raw: [String: JSONValue]
    let kind: String
    let speaker: String
    let previewHash: String?
    let expiresAt: Date?
    let owner: Bool
    let ownerWarning: String?
    let requiresListening: Bool
    let meetings: [HeldNamingMeeting]
    let batchId: String?
    let undoHandle: String?
    let members: [HeldSampleRef]
    let httpStatus: Int
    var id: String { previewHash ?? batchId ?? kind }
    var enrolled: Int { raw["enrolled"]?.int ?? 0 }
    var deleted: Int { raw["deleted"]?.int ?? 0 }
    /// Server's retained count: enrollment can replace samples at the cap.
    var profileEmbeddings: Int? { raw["profileEmbeddings"]?.int }
    var memberOutcomes: [HeldNamingMemberOutcome] { (raw["members"]?.array ?? []).compactMap(HeldNamingMemberOutcome.init) }
    var restoredSegments: Int { meetings.filter { $0.status == "reverted" }.reduce(0) { $0 + $1.labelled } }
    var partial: Bool { raw["partial"]?.bool ?? false }
    var noTranscriptCount: Int { memberOutcomes.filter(\.hasNoTranscriptPosition).count }
    var eligibleSamples: Int { (raw["members"]?.array ?? []).filter { ["ready", "no_transcript_position"].contains($0.object?["status"]?.string ?? "") }.count }
    var labelled: Int { meetings.filter { $0.status == "ready" || $0.status == "applied" }.reduce(0) { $0 + $1.labelled } }
    var canApply: Bool { kind == "preview" && httpStatus == 200 && eligibleSamples > 0 && previewHash?.count == 64 && expiresAt.map { $0 > Date() } == true }
    func canApply(ownerAcknowledged: Bool, listened: Bool) -> Bool {
        canApply && (!owner || ownerAcknowledged) && (!requiresListening || listened)
    }
    init(_ raw: [String: JSONValue]) {
        self.raw = raw; kind = raw["kind"]?.string ?? "unknown"
        speaker = raw["speaker"]?.string ?? raw["name"]?.string ?? "Voice"
        previewHash = raw["previewHash"]?.string
        if let ms = raw["expiresAt"]?.double { expiresAt = Date(timeIntervalSince1970: ms / 1000) }
        else if let iso = raw["expiresAt"]?.string {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiresAt = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        } else { expiresAt = nil }
        owner = raw["owner"]?.bool ?? false; ownerWarning = raw["ownerWarning"]?.string
        requiresListening = raw["requiresListening"]?.bool ?? false
        meetings = (raw["meetings"]?.array ?? []).compactMap(HeldNamingMeeting.init)
        batchId = raw["batchId"]?.string; undoHandle = raw["undoHandle"]?.string
        members = (raw["members"]?.array ?? []).compactMap(HeldSampleRef.init)
        httpStatus = raw["httpStatus"]?.int ?? 200
    }
}

struct HeldNamingBatch: Identifiable, Sendable {
    let raw: [String: JSONValue]
    let batchId: String
    let speaker: String
    let status: String
    let undoHandle: String?
    let meetings: [HeldNamingMeeting]
    var id: String { batchId }
    var needsReview: Bool { status == "interrupted" || status == "partial" }
    var memberOutcomes: [HeldNamingMemberOutcome] { (raw["members"]?.array ?? []).compactMap(HeldNamingMemberOutcome.init) }
    var profileEmbeddings: Int? { raw["profileEmbeddings"]?.int }
    init?(_ value: JSONValue?) {
        guard let o = value?.object, let batch = o["batchId"]?.string, !batch.isEmpty else { return nil }
        raw = o
        batchId = batch; speaker = o["speaker"]?.string ?? "Voice"; status = o["status"]?.string ?? "unknown"
        undoHandle = o["undoHandle"]?.string
        meetings = (o["meetings"]?.array ?? []).compactMap(HeldNamingMeeting.init)
    }
}

/// 0.5.219 — held samples that sound like ONE person, across every meeting in the
/// window (`GET /api/voice/held-groups`, glasses-server 6.45.4). The server
/// groups at its identifier's own floor; Control only shows and names.
struct HeldVoiceGroup: Identifiable, Sendable, Hashable {
    let id: String
    let members: [HeldSampleRef]
    let sessions: [String]
    let sampleCount: Int
    let coherence: Double
    /// The member closest to everyone else — the one to play first.
    let seed: HeldSampleRef
    /// The enrolled profile this group sounds like, when the server is willing
    /// to say so (above its own floor). Tier is "high" (the live identifier's
    /// auto-enrol bar) or "likely".
    let suggestionName: String?
    let suggestionSimilarity: Double
    let suggestionTier: String?
    /// How many of that profile's samples agree, out of how many — the server
    /// vouches only with two or more, one of them from an anchored source.
    let suggestionAgreeing: Int
    let suggestionOf: Int
    let ownerCaution: Bool

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let id = o["id"]?.string, !id.isEmpty else { return nil }
        let members = (o["members"]?.array ?? []).compactMap(HeldSampleRef.init)
        guard !members.isEmpty else { return nil }
        self.id = id
        self.members = members
        sessions = (o["sessions"]?.array ?? []).compactMap { $0.string }
        sampleCount = o["sampleCount"]?.int ?? members.count
        coherence = o["coherence"]?.double ?? 0
        seed = HeldSampleRef(o["seed"]) ?? members[0]
        let suggestion = o["suggestion"]?.object
        suggestionName = suggestion?["name"]?.string
        suggestionSimilarity = suggestion?["similarity"]?.double ?? 0
        suggestionTier = suggestion?["tier"]?.string
        suggestionAgreeing = suggestion?["agreeing"]?.int ?? 0
        suggestionOf = suggestion?["of"]?.int ?? 0
        ownerCaution = suggestion?["ownerCaution"]?.bool ?? false
    }

    /// Seed first, then the rest: the Listen control starts on the sample that
    /// best represents the voice.
    var playOrder: [HeldSampleRef] { [seed] + members.filter { $0 != seed } }
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
    /// What the chat kept returning to, derived from the user's own words.
    /// "Chat 1 … Chat 11" told you nothing, and every summary opens with the
    /// same "Alright, I want you to…" (Miles, 2026-08-31).
    let topic: String
    let exchangeCount: Int
    let startedAt: TimeInterval?
    /// Populated only when the day was loaded with an active search.
    let matches: Int
    let snippet: String

    var id: Int { index }

    /// The line the row leads with: the topic when there is one, the opening
    /// line when there is not. Never "Chat N" alone.
    var headline: String {
        if !topic.isEmpty { return topic }
        let opening = (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return opening.isEmpty ? "Untitled chat" : opening
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let index = o["index"]?.int else { return nil }
        self.index = index
        summary = o["summary"]?.string
        topic = o["topic"]?.string ?? ""
        matches = o["matches"]?.int ?? 0
        snippet = o["snippet"]?.string ?? ""
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

/// How much the pet moves (0.5.238). Miles, 2026-09-19, after Codex's own
/// pet menu: "full motion vs no motion if people don't like it moving so
/// much". Set from the figure's right-click menu and from Session pet
/// settings. It is two stored flags so the Calm choice made before this
/// existed keeps its key: calm rests the character on its idle loop; still
/// holds it on one frame and stops the pet's animations, what macOS Reduce
/// Motion does, for the pet only. Still wins if both are ever set. A figure
/// preference only: no choice here may cost the ledger a count.
enum PetMotion: String, CaseIterable, Identifiable, Sendable {
    case full
    case calm
    case still

    var id: String { rawValue }

    static func resolve(calm: Bool, still: Bool) -> PetMotion {
        still ? .still : (calm ? .calm : .full)
    }

    /// The pet stops its own animations under either switch.
    static func reducesMotion(system: Bool, choice: PetMotion) -> Bool {
        system || choice == .still
    }

    var title: String {
        switch self {
        case .full: "Full motion"
        case .calm: "Calm motion"
        case .still: "No motion"
        }
    }

    /// The segmented control in settings has room for one word each.
    var shortTitle: String {
        switch self {
        case .full: "Full"
        case .calm: "Calm"
        case .still: "None"
        }
    }

    var calm: Bool { self == .calm }
    var still: Bool { self == .still }
}

/// The running row's LIVE line as a news ticker: the visible window is fixed
/// and the text slides through it, so a long activity summary stays readable
/// without widening the row (Miles, 2026-08-31 — "urgent/breaking news
/// ticker"). JetBrains Mono is monospaced at a 0.6em advance, so overflow and
/// loop timing are COMPUTED rather than measured through a layout pass.
/// Kerning is not applied to this line, so the estimate is exact; the gap
/// between the two loop copies absorbs any sub-point rounding.
/// Platform marks for the agent rows: each platform's REAL logo, bundled as
/// a monochrome SVG and tinted like every other template mark in the app —
/// the Anthropic sunburst, the OpenAI knot, the Cursor prism. Stand-in SF
/// Symbols (a spark, a terminal, a cube) read as generic and were replaced
/// on sight (Miles, 2026-08-31). A local model has no brand mark and keeps a
/// symbol. Shared by live rows and finished chips so one provider can never
/// wear two marks. The contract LOADS AND RASTERIZES every asset: a missing
/// or empty SVG renders as nothing at all.
/// Search marking and filtering, kept OUT of the view so it can be executed by
/// the contract. Two mutations survived while this lived in ActivityWindow —
/// a grep can see that a highlight function exists, never that it highlights
/// (2026-08-31).
/// A day the meaning-search proposed AND the archive confirmed still holds
/// conversations. Unverified suggestions never reach this type.
struct ArchiveSemanticHit: Identifiable, Sendable, Hashable {
    let date: String
    let why: String
    let chatCount: Int
    var id: String { date }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let date = o["date"]?.string, !date.isEmpty else { return nil }
        self.date = date
        why = o["why"]?.string ?? ""
        chatCount = o["chatCount"]?.int ?? 0
    }
}

enum SearchMark {
    /// Below this a mark is noise: one letter paints most of a paragraph.
    static let minimumQuery = 2

    /// Every occurrence of `query` in `text`, case-insensitively.
    static func ranges(in text: String, query: String) -> [Range<String.Index>] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= minimumQuery else { return [] }
        let hay = text.lowercased()
        var out: [Range<String.Index>] = []
        var from = hay.startIndex
        while let r = hay.range(of: needle, range: from..<hay.endIndex) {
            out.append(r)
            from = r.upperBound
        }
        return out
    }

    /// Does either side of this turn carry the query? A query too short to
    /// mark also does not filter — the list stays whole rather than empty.
    static func matches(query: String, in fields: [String]) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.count >= minimumQuery else { return true }
        return fields.contains { $0.lowercased().contains(needle) }
    }
}

enum PetProvider {
    /// A bundled brand SVG, or an SF Symbol where no brand mark ships.
    enum Mark: Hashable {
        case asset(String)
        case symbol(String)
    }

    static func mark(_ provider: String) -> Mark {
        switch provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "codex": .asset("mark-codex")
        case "cursor": .asset("mark-cursor")
        case "local", "ollama": .symbol("cpu")
        default: .asset("mark-claude")
        }
    }
}

enum PetTicker {
    static let advanceRatio: CGFloat = 0.6
    /// Blank run between the loop's two copies, so the wrap reads as a gap
    /// rather than the same words colliding with themselves.
    static let gap: CGFloat = 30
    /// Points per second. Slow enough to read a path or a file count.
    static let speed: CGFloat = 26
    /// A beat at rest before it moves, so a short glance sees the beginning.
    static let startHold: TimeInterval = 1.4

    /// ASCII is EXACTLY 0.6em in JetBrains Mono — measured against the shipped
    /// face, error 0.00 — so the common case needs no text measurement. Every
    /// other script does not: the font carries no CJK, kana or emoji, so those
    /// fall back to full-width faces at 1.67x to 2.29x the monospace advance.
    /// The estimate then said "it fits" for text that overflowed, and the
    /// window clipped it with neither motion nor an ellipsis (QA, 2026-08-31).
    enum Face: Equatable {
        case mono, body

        func nsFont(_ size: CGFloat) -> NSFont {
            switch self {
            case .mono:
                NSFont(name: "JetBrains Mono", size: size)
                    ?? .monospacedSystemFont(ofSize: size, weight: .bold)
            case .body:
                NSFont(name: "DM Sans", size: size)
                    ?? .systemFont(ofSize: size, weight: .semibold)
            }
        }
    }

    static func width(_ text: String, fontSize: CGFloat, face: Face = .mono) -> CGFloat {
        if face == .mono, text.allSatisfy(\.isASCII) {
            return CGFloat(text.count) * fontSize * advanceRatio
        }
        return measuredWidth(text, fontSize: fontSize, face: face)
    }

    /// Real typographic width, including whatever fallback face supplies the
    /// glyphs the mono font lacks.
    static func measuredWidth(
        _ text: String, fontSize: CGFloat, face: Face = .mono
    ) -> CGFloat {
        let font = face.nsFont(fontSize)
        return (NSAttributedString(string: text, attributes: [.font: font])
            .size().width).rounded(.up)
    }

    /// Only text that genuinely overflows scrolls; anything that fits stays
    /// still. A ticker that moves when it does not need to is noise.
    static func scrolls(
        _ text: String, fontSize: CGFloat, container: CGFloat, face: Face = .mono
    ) -> Bool {
        container > 0 && width(text, fontSize: fontSize, face: face) > container
    }

    /// One full loop travels the text plus the gap at a constant reading
    /// speed, so a longer summary scrolls for longer instead of faster.
    static func loopDuration(
        _ text: String, fontSize: CGFloat, face: Face = .mono
    ) -> TimeInterval {
        max(Double((width(text, fontSize: fontSize, face: face) + gap) / speed), 1)
    }
}

/// Keep the floating pet on a visible display. 0.5.97 grew Large downward
/// from the bottom corner and autosave parked the panel under the screen.
enum PetPanelFrame {
    /// Build the panel's frame from the anchor the user parked it at, then
    /// clamp it onto a screen. Rebuilding from the ANCHOR — never from the
    /// last clamped origin — is the whole fix for the open/close walk: an
    /// expanded panel that overflows the screen top gets slid down to fit,
    /// and feeding that slid origin back in made the slide permanent. A
    /// high-parked pet ratcheted 450pt down in one open (Miles, 2026-08-31).
    static func positioned(size: CGSize, anchor: CGPoint, screens: [CGRect]) -> CGRect {
        clamped(CGRect(origin: anchor, size: size), screens: screens)
    }

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
        // The panel is anchored by its BOTTOM edge and the menu opens UPWARD, so
        // the figure holds still and the list grows above it. Sliding down is
        // correct in exactly one case: parked so high that the open menu would
        // run off the top of the display. That is the behaviour Miles asked for
        // on 2026-09-01 ("it would only be in instances where the pet is at the
        // very top of the screen that we want to push the pet down"). Trimming
        // the height instead was wrong — it shrank the panel while the real
        // defect was elsewhere, in NSHostingController re-anchoring the window
        // to its top-left.
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
    /// Calm motion (0.5.165): an advanced character rests instead of fighting.
    /// Combat is the whole appeal for most people and motion sickness or plain
    /// distraction for others, and until now the only alternative was macOS
    /// Reduce Motion, which freezes the figure to a single frame. Calm keeps
    /// the gentle idle loop — the same register as the 300 still characters —
    /// and lets the LEDGER carry every count, so nothing about status is lost.
    ///
    /// Error and attention deliberately still break through: they mean the app
    /// could not do something and needs you, they are brief, and silencing an
    /// alert is not a motion preference.
    static func calmed(_ pose: PetSpritePose) -> PetSpritePose {
        switch pose {
        case .error, .attention: pose
        default: .idle
        }
    }

    static func resolve(
        sessionCount: Int,
        workingCount: Int,
        waitingCount: Int,
        focusState: String?,
        completing: Bool,
        attention: Bool = false,
        errored: Bool = false,
        calm: Bool = false
    ) -> PetSpritePose {
        if calm {
            return calmed(resolve(
                sessionCount: sessionCount, workingCount: workingCount,
                waitingCount: waitingCount, focusState: focusState,
                completing: completing, attention: attention, errored: errored
            ))
        }
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

/// 0.5.328 (Version 15): a pose's optional retina strips, beside its 1x `file` and `rotation`. Each list is one strip's
/// ordered segments: a strip wider than 32,760 px or larger than 16,777,216 px is split at a cell boundary. Only scale 2
/// is defined. Older builds ignore the block and play the 1x strips, so a map carrying it stays readable everywhere.
struct PetRetinaRow: Equatable {
    struct Variant: Equatable {
        var id: String
        var file: [String]
        var bodyFile: [String]
        var entryFile: [String]
    }
    var scale: Int
    var file: [String]
    var variants: [Variant]

    init?(_ value: Any?) {
        guard let row = value as? [String: Any], let scale = row["scale"] as? Int, scale == 2,
              let file = row["file"] as? [String], !file.isEmpty, file.allSatisfy(PetRotationManifest.isRelativePath)
        else { return nil }
        var variants: [Variant] = []
        if let items = row["variants"] {
            guard let items = items as? [[String: Any]], !items.isEmpty else { return nil }
            for item in items {
                guard let id = item["id"] as? String, let full = item["file"] as? [String],
                      let body = item["bodyFile"] as? [String], let entry = item["entryFile"] as? [String],
                      ![full, body, entry].contains(where: \.isEmpty),
                      (full + body + entry).allSatisfy(PetRotationManifest.isRelativePath) else { return nil }
                variants.append(Variant(id: id, file: full, bodyFile: body, entryFile: entry))
            }
        }
        self.scale = scale
        self.file = file
        self.variants = variants
    }

    /// Every file the block names, in map order.
    var files: [String] { file + variants.flatMap { $0.file + $0.bodyFile + $0.entryFile } }

    /// A retina strip is chosen only on a display that draws at least `scale` pixels per point.
    static func chosen(_ value: Any?, displayScale: CGFloat) -> PetRetinaRow? {
        guard let row = PetRetinaRow(value), displayScale >= CGFloat(row.scale) else { return nil }
        return row
    }
}

/// Carries decoded cast art from a background decode to the main actor. The images are never touched off the main
/// actor once handed over.
final class PetRotationBox: @unchecked Sendable {
    let value: [PetSpritePose: PetEncounterRotation]
    init(_ value: [PetSpritePose: PetEncounterRotation]) { self.value = value }
}

/// Optional versioned encounter art. The legacy pose strip remains the fallback.
struct PetRotationManifest: Codable, Equatable {
    struct Variant: Codable, Equatable {
        var id: String
        var file: String
        var bodyFile: String
        var entryFile: String
    }
    var version: Int
    var handoffFrame: Int // one-based, inclusive
    var seed: UInt64?
    var variants: [Variant]

    func isValid(frames: Int) -> Bool {
        version == 1 && frames > 1 && frames <= PetSpriteStrip.maxFrames
            && (2...frames).contains(handoffFrame) && (2...8).contains(variants.count)
            && Set(variants.map(\.id)).count == variants.count
            && variants.allSatisfy { !$0.id.isEmpty && [$0.file, $0.bodyFile, $0.entryFile].allSatisfy(Self.isRelativePath) }
    }

    static func isRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty })
            && path.lowercased().hasSuffix(".png")
    }
}

struct PetEncounterRotation {
    struct Variant {
        var id: String
        var full: [NSImage]
        var body: [NSImage]
        var entry: [NSImage]
    }
    var fingerprint: String
    var manifest: PetRotationManifest
    var frames: Int
    var variants: [Variant]

    func layers(for snapshot: PetEncounterPlayback.Snapshot) -> [NSImage] {
        if snapshot.inTail {
            return [variants[snapshot.incoming].entry[snapshot.frame], variants[snapshot.current].body[snapshot.frame]]
        }
        return [variants[snapshot.current].full[snapshot.frame]]
    }
}

/// Pure state machine shared by native playback and its tests. Randomness is
/// consumed only when reserving a cast, never while rendering or scrubbing.
struct PetEncounterSequence {
    private var rng: UInt64
    private var bag: [Int] = []
    private var previous: Int?
    let count: Int
    let frames: Int
    let handoffFrame: Int
    private(set) var current = 0
    private(set) var incoming = 0
    private(set) var frame = 0
    private(set) var cycle = 0
    var inTail: Bool { frame + 1 >= handoffFrame }

    init(count: Int, frames: Int, handoffFrame: Int, seed: UInt64) {
        precondition(count >= 2 && frames > 1 && (2...frames).contains(handoffFrame))
        self.count = count; self.frames = frames; self.handoffFrame = handoffFrame; rng = seed
        current = pick(); incoming = pick()
    }
    private mutating func random() -> UInt64 {
        rng &+= 0x9e3779b97f4a7c15
        var z = rng
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
    private mutating func pick() -> Int {
        if bag.isEmpty {
            bag = Array(0..<count)
            for i in stride(from: count - 1, through: 1, by: -1) { bag.swapAt(i, Int(random() % UInt64(i + 1))) }
            if bag[0] == previous { bag.swapAt(0, 1 + Int(random() % UInt64(count - 1))) }
        }
        let next = bag.removeFirst(); previous = next; return next
    }
    mutating func advance() {
        frame += 1
        if frame == frames { frame = 0; cycle += 1; current = incoming; incoming = pick() }
    }
}

/// Owned by ControllerModel, whose lifetime outlasts the hosting root's 20s
/// refresh. Inactive poses pause in place; returning resumes the same encounter.
/// Content fingerprints replace state only when the actual pack changes.
@MainActor
final class PetEncounterPlayback {
    struct Snapshot: Equatable {
        let current: Int
        let incoming: Int
        let frame: Int
        let cycle: Int
        let inTail: Bool
    }
    private struct Playback {
        var fingerprint: String
        var sequence: PetEncounterSequence
        var fraction = 0.0
        var last: Double?
        var speed = 1.0
        var interval = 0.08
        var paused = false
    }
    private var states: [PetSpritePose: Playback] = [:]
    private var active: PetSpritePose?
    private let seed: UInt64
    /// Opt-in console only. No files or unbounded event retention.
    private let diagnostics: Bool
    private let logger = Logger(subsystem: "com.gotcos.control", category: "pet-rotation")
    init(seed: UInt64 = UInt64.random(in: UInt64.min...UInt64.max), diagnostics: Bool = ProcessInfo.processInfo.environment["COS_PET_ROTATION_DIAGNOSTICS"] == "1") {
        self.seed = seed; self.diagnostics = diagnostics
    }
    func pause() {
        if let active { states[active]?.last = nil }
        active = nil
    }
    func sample(pose: PetSpritePose, rotation: PetEncounterRotation?, now: Double, speed: Double, interval: Double, paused: Bool) -> Snapshot? {
        guard let rotation, now.isFinite else { pause(); return nil }
        if active != pose { self.pause(); active = pose; states[pose]?.last = nil }
        if states[pose]?.fingerprint != rotation.fingerprint {
            let salt = pose.rawValue.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
            states[pose] = Playback(fingerprint: rotation.fingerprint, sequence: PetEncounterSequence(count: rotation.variants.count, frames: rotation.frames, handoffFrame: rotation.manifest.handoffFrame, seed: (rotation.manifest.seed ?? seed) ^ salt))
        }
        guard var state = states[pose] else { return nil }
        let firstSample = state.last == nil
        let oldCycle = state.sequence.cycle
        if let last = state.last, !state.paused {
            let delta = now - last
            // A sleeping/hidden window resumes its held pose, not a skipped fight.
            let longestTick = max(1, state.interval / state.speed * 2.5)
            if delta >= 0 && delta <= longestTick {
                state.fraction += delta * state.speed / state.interval
                while state.fraction + 1e-9 >= 1 { state.sequence.advance(); state.fraction = max(0, state.fraction - 1) }
            }
        }
        state.last = now
        state.speed = speed.isFinite ? min(max(speed, 0.25), 2) : 1
        state.interval = interval.isFinite ? max(interval, 0.016) : 0.08
        state.paused = paused
        states[pose] = state
        if diagnostics && (oldCycle != state.sequence.cycle || firstSample) {
            logger.notice("COSPetRotation pose=\(pose.rawValue, privacy: .public) cycle=\(state.sequence.cycle) current=\(rotation.variants[state.sequence.current].id, privacy: .public) incoming=\(rotation.variants[state.sequence.incoming].id, privacy: .public) frame=\(state.sequence.frame + 1) handoff=\(rotation.manifest.handoffFrame)")
        }
        return Snapshot(current: state.sequence.current, incoming: state.sequence.incoming, frame: state.sequence.frame, cycle: state.sequence.cycle, inTail: state.sequence.inTail)
    }
}

/// A failed cast decode must not permanently pin the fallback's first cast.
/// Retry on a later panel refresh; never launch concurrent decodes or reload healthy art.
enum PetRotationLoadPolicy {
    static func shouldRequest(wanted: PetSpritePose?, requested: PetSpritePose?, hasArt: Bool,
                              loading: Bool, retryAfter: Double, now: Double) -> Bool {
        if wanted != requested { return true }
        return wanted != nil && !hasArt && !loading && now >= retryAfter
    }
}

struct PetSpriteKit {
    var fallback: NSImage?
    var poses: [PetSpritePose: [NSImage]] = [:]
    var cinematic: [NSImage] = []
    var rotations: [PetSpritePose: PetEncounterRotation] = [:]

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
    // bounded import limit without truncating the longer recovery/entrance stories.
    static let maxFrames = 256

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

    /// `scale` (0.5.328, Version 15): a 2x strip's cells keep their pixels but report half their pixel size, so the
    /// figure is the same size on screen as the 1x strip and a retina display draws every pixel.
    static func slice(_ image: NSImage, frames: Int, scale: CGFloat = 1) -> [NSImage] {
        let count = clampFrames(frames)
        guard let cg = raster(image) else { return [image] }
        if count <= 1 {
            return [NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))]
        }
        let frameWidth = max(1, cg.width / count)
        var out: [NSImage] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            let rect = CGRect(x: index * frameWidth, y: 0, width: frameWidth, height: cg.height)
            guard let cropped = cg.cropping(to: rect) else { continue }
            out.append(NSImage(cgImage: cropped, size: NSSize(width: CGFloat(frameWidth) / scale, height: CGFloat(cg.height) / scale)))
        }
        return out.isEmpty ? [image] : out
    }

    /// Rotation layers repeat guard poses and whole body frames. Cropped CGImages
    /// otherwise retain every decoded atlas, including duplicate and blank cells.
    /// Copy each unique cell once; cache identity is exact premultiplied pixels.
    static func sliceCompact(_ cg: CGImage, frames: Int, scale: CGFloat = 1, cache: inout [String: NSImage]) -> [NSImage] {
        let count = clampFrames(frames), w = cg.width / count, h = cg.height
        guard w > 0, let context = CGContext(data: nil, width: cg.width, height: h,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let pixels = context.data else { return [] }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: h))
        let cellBytes = w * h * 4
        var scratch = Data(count: cellBytes)
        return (0..<count).compactMap { frame in
            scratch.withUnsafeMutableBytes { dst in
                for y in 0..<h {
                    dst.baseAddress!.advanced(by: y * w * 4).copyMemory(
                        from: pixels.advanced(by: (y * cg.width + frame * w) * 4), byteCount: w * 4)
                }
            }
            let key = "\(w):\(h):\(scale):" + SHA256.hash(data: scratch).map { String(format: "%02x", $0) }.joined()
            if let image = cache[key] { return image }
            // 0.5.328 memory gate: a kept cell lives in its own anonymous mapping, unmapped when the image goes. A malloc'd
            // cell of 600x512 px (1.2 MB) was freed into malloc's small region, which kept the pages dirty: releasing one
            // state's casts returned nothing (measured: footprint stayed at its peak, 434 MB of empty-but-resident small
            // regions after the release).
            guard let mapped = mmap(nil, cellBytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
                  mapped != MAP_FAILED else { return nil }
            scratch.withUnsafeBytes { mapped.copyMemory(from: $0.baseAddress!, byteCount: cellBytes) }
            guard let provider = CGDataProvider(dataInfo: nil, data: mapped, size: cellBytes, releaseData: { _, data, size in
                munmap(UnsafeMutableRawPointer(mutating: data), size)
            }) else { munmap(mapped, cellBytes); return nil }
            guard let cell = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
            let image = NSImage(cgImage: cell, size: NSSize(width: CGFloat(w) / scale, height: CGFloat(h) / scale))
            cache[key] = image
            return image
        }
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

    /// The cells of one retina strip given as ordered segments. Every cell must be `scale` times a 1x cell of `cell`
    /// points, so the figure is exactly as big on screen as the 1x strip; the 256-point height rule applies to points.
    /// Nil, and the caller keeps the 1x strip, when a segment is missing, outside the folder, unreadable, over a native
    /// cap (32,760 px wide, 16,777,216 px, 1024 px cells), not cut at a cell boundary, or the cells do not add to `frames`.
    static func retinaCells(
        _ files: [String],
        frames: Int,
        cell: CGSize,
        scale: Int,
        in directory: URL,
        slicer: (CGImage, Int) -> [NSImage]
    ) -> [NSImage]? {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let w = Int(cell.width.rounded()) * scale, h = Int(cell.height.rounded()) * scale
        guard scale >= 2, frames >= 1, w > 0, w <= 1024, h > 0, h <= 1024, Int(cell.height.rounded()) <= maxHeight
        else { return nil }
        var out: [NSImage] = []
        for file in files {
            let url = directory.appendingPathComponent(file).resolvingSymlinksInPath().standardizedFileURL
            // ImageIO, not NSImage: the full pixel image whatever DPI the PNG declares.
            guard url.path.hasPrefix(root), let data = try? Data(contentsOf: url), data.count <= 32 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  cg.height == h, cg.width % w == 0, cg.width <= 32_760, cg.width * cg.height <= 16_777_216
            else { return nil }
            out += slicer(cg, cg.width / w)
        }
        return out.count == frames ? out : nil
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
    /// Strict all-or-nothing loading per pose. Bad or absent optional metadata
    /// falls back to the legacy strip without changing other poses.
    /// `only` (0.5.328): decode just these poses. The live pet asks for the pose on screen alone: Version 15's 2x casts
    /// measured 798 MB decoded together against V14's 219 MB, and one state at a time peaks near 282 MB (swarm).
    static func loadRotations(
        in directory: URL,
        fileManager: FileManager = .default,
        displayScale: CGFloat = 1,
        only: Set<PetSpritePose>? = nil
    ) -> [PetSpritePose: PetEncounterRotation] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(stateFileName)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let poses = json["poses"] as? [String: [String: Any]] else { return [:] }
        var result: [PetSpritePose: PetEncounterRotation] = [:]
        var frameCache: [String: NSImage] = [:]
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        // 0.5.328: Session 1 (working) rotates casts too (Jedi Version 15: four casts for Miles Windu). The renderer was
        // already pose-generic; only this loader limited rotation to duel, trio and swarm.
        for pose in [PetSpritePose.working, .duel, .trio, .swarm] where only?.contains(pose) ?? true {
            guard let row = poses[pose.rawValue], let rotationJSON = row["rotation"] as? [String: Any],
                  let rotationData = try? JSONSerialization.data(withJSONObject: rotationJSON, options: [.sortedKeys]),
                  let manifest = try? JSONDecoder().decode(PetRotationManifest.self, from: rotationData),
                  let frames = row["frames"] as? Int, manifest.isValid(frames: frames),
                  let fallbackFile = row["file"] as? String, PetRotationManifest.isRelativePath(fallbackFile),
                  let fallback = NSImage(contentsOf: directory.appendingPathComponent(fallbackFile)),
                  let raster = PetSpriteStrip.raster(fallback), raster.width % frames == 0 else { continue }
            let width = raster.width, height = raster.height
            // The 256-frame illustrated swarm is 79,616 x 256 (20.4M pixels).
            // Retain a finite decoded-strip budget; per-file bytes and cell dimensions stay bounded.
            guard height > 0, height <= 1024, width / frames > 0, width / frames <= 1024,
                  width * height <= 33_554_432 else { continue }
            // Version 15: on a display of scale 2 or more, the retina casts when every one of their layers is valid;
            // otherwise the 1x casts below. Either way the cells measure the 1x strip's points.
            if let retina = PetRetinaRow.chosen(row["retina"], displayScale: displayScale),
               retina.variants.map(\.id) == manifest.variants.map(\.id) {
                var hasher = SHA256(); hasher.update(data: rotationData)
                var variants: [PetEncounterRotation.Variant] = []
                for variant in retina.variants {
                    let strips = [variant.file, variant.bodyFile, variant.entryFile].compactMap { files in
                        PetSpriteStrip.retinaCells(files, frames: frames, cell: CGSize(width: width / frames, height: height),
                                                   scale: retina.scale, in: directory) { cg, count in
                            PetSpriteStrip.sliceCompact(cg, frames: count, scale: CGFloat(retina.scale), cache: &frameCache)
                        }
                    }
                    guard strips.count == 3 else { break }
                    hasher.update(data: Data((variant.file + variant.bodyFile + variant.entryFile).joined(separator: "\n").utf8))
                    variants.append(.init(id: variant.id, full: strips[0], body: strips[1], entry: strips[2]))
                }
                if variants.count == manifest.variants.count {
                    hasher.update(data: Data("retina\(retina.scale):\(frames):\(width):\(height)".utf8))
                    let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                    result[pose] = PetEncounterRotation(fingerprint: fingerprint, manifest: manifest, frames: frames, variants: variants)
                    continue
                }
            }
            var hasher = SHA256(); hasher.update(data: rotationData)
            var variants: [PetEncounterRotation.Variant] = []
            for variant in manifest.variants {
                var strips: [[NSImage]] = []
                for file in [variant.file, variant.bodyFile, variant.entryFile] {
                    let url = directory.appendingPathComponent(file).resolvingSymlinksInPath().standardizedFileURL
                    guard url.path.hasPrefix(root),
                          let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 0, size <= 32 * 1024 * 1024,
                          let bytes = try? Data(contentsOf: url), let image = NSImage(data: bytes),
                          let cg = PetSpriteStrip.raster(image), cg.width == width, cg.height == height else { break }
                    hasher.update(data: bytes)
                    strips.append(PetSpriteStrip.sliceCompact(cg, frames: frames, cache: &frameCache))
                }
                guard strips.count == 3, strips.allSatisfy({ $0.count == frames }) else { break }
                variants.append(.init(id: variant.id, full: strips[0], body: strips[1], entry: strips[2]))
            }
            guard variants.count == manifest.variants.count else { continue }
            hasher.update(data: Data("\(frames):\(width):\(height)".utf8))
            let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            result[pose] = PetEncounterRotation(fingerprint: fingerprint, manifest: manifest, frames: frames, variants: variants)
        }
        return result
    }

    /// Poses whose map row declares a cast rotation, read without decoding any art.
    static func castPoses(in directory: URL) -> Set<PetSpritePose> {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(stateFileName)),
              let poses = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["poses"] as? [String: [String: Any]]
        else { return [] }
        return Set(poses.compactMap { name, row in row["rotation"] == nil ? nil : PetSpritePose(rawValue: name) })
    }

    /// Every pose's frames as the live pet plays them (0.5.328). On a display of scale 2 or more a pose whose map row
    /// carries a valid retina block plays its 2x cells (pixel-for-pixel, at the 1x strip's point size); every other pose,
    /// and any retina block that fails a check, plays the 1x strip exactly as before. `castPoses` keep their 1x strip:
    /// their casts are what plays, the strip only sizes the view, and its 2x decode measured 240 MB for nothing.
    static func loadPoseFrames(
        in directory: URL,
        stateMap: [PetSpritePose: (file: String, frames: Int)],
        displayScale: CGFloat,
        castPoses: Set<PetSpritePose> = []
    ) -> [PetSpritePose: [NSImage]] {
        let rows = (try? Data(contentsOf: directory.appendingPathComponent(stateFileName)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["poses"] as? [String: Any] ?? [:]
        var poses: [PetSpritePose: [NSImage]] = [:]
        for (pose, record) in stateMap {
            guard let image = NSImage(contentsOf: directory.appendingPathComponent(record.file)) else { continue }
            let oneX = PetSpriteStrip.slice(image, frames: record.frames)
            poses[pose] = oneX
            guard !castPoses.contains(pose),
                  let retina = PetRetinaRow.chosen((rows[pose.rawValue] as? [String: Any])?["retina"], displayScale: displayScale),
                  let cell = oneX.first?.size, oneX.count == record.frames,
                  let cells = PetSpriteStrip.retinaCells(retina.file, frames: record.frames, cell: cell, scale: retina.scale,
                                                         in: directory, slicer: { cg, count in
                                                             PetSpriteStrip.slice(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)),
                                                                                  frames: count, scale: CGFloat(retina.scale))
                                                         })
            else { continue }
            poses[pose] = cells
        }
        return poses
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
        /// Already the bundled pack, file for file and byte for byte (0.5.316: Miles installed V12.6 by hand before it
        /// shipped). Nothing is written; the art generation still advances, and a later release that lists this pack
        /// as retained stock can promote it.
        case current
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
        try saveStateMap(map, clearRotations: [pose], in: directory, fileManager: fileManager)
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
        try saveStateMap(map, clearRotations: Set(preparedPoses.keys), in: directory, fileManager: fileManager)
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
            folderName: "BundledCharacters/jedi-miles-windu",
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
    // Cloud Puff is bundled for offline first launch. Keep the historical Miles
    // identity separate: stock-art upgrades must never replace a user's choice.
    static let defaultCharacterID = "cloud-puff"
    static let defaultCharacterName = "Cloud Puff"
    static let legacyDefaultCharacterID = "jedi-miles-windu"

    /// Existing artwork is a choice, even when the seed preference is missing.
    /// Missing or unwritable bundled art returns false so first launch can retry.
    @discardableResult
    static func seedStarterDefault(into directory: URL, bundle: Bundle = .main,
                                   fileManager: FileManager = .default) -> Bool {
        if existingSpriteURL(in: directory, fileManager: fileManager) != nil
            || fileManager.fileExists(atPath: directory.appendingPathComponent(stateFileName).path)
            || PetSpritePose.allCases.contains(where: {
                existingPoseURL($0, in: directory, fileManager: fileManager) != nil
            }) { return true }
        guard let source = bundle.resourceURL?.appendingPathComponent("StarterPet/cloud-puff.webp"),
              let bytes = try? Data(contentsOf: source), NSImage(data: bytes) != nil
        else { return false }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: directory.appendingPathComponent("\(fileStem).webp"), options: .atomic)
            return true
        } catch { return false }
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
        // Retained V15 is the legacy upgrade checkpoint and rollback pack.
        bundle.resourceURL?.appendingPathComponent("DefaultPet", isDirectory: true)
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
        installBundledCharacter(id: legacyDefaultCharacterID, into: directory, bundle: bundle, fileManager: fileManager)
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
        retainedMilesOverride: URL? = nil,
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

        for character in bundledCharacters {
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

            // Every referenced layer participates in stock recognition. A custom
            // rotation or Retina image must not be overwritten just because the
            // first full strip still matches the shipped pack.
            func referencedPNGs(_ value: Any) -> Set<String> {
                if let object = value as? [String: Any] {
                    return object.values.reduce(into: Set<String>()) { $0.formUnion(referencedPNGs($1)) }
                }
                if let list = value as? [Any] {
                    return list.reduce(into: Set<String>()) { $0.formUnion(referencedPNGs($1)) }
                }
                if let file = value as? String, file.hasSuffix(".png") { return [file] }
                return []
            }
            // Miles V15 stays in DefaultPet. The illustrated 348 checkpoint
            // and other Jedi retain all prior assets beside the new generation.
            // This bundled metadata selects a fixed root, never an external path.
            let retainedInCharacter = match["retainedSource"] as? String == "bundled-character"
            let retainedSource = character.id == legacyDefaultCharacterID && !retainedInCharacter
                ? (retainedMilesOverride ?? bundledDefaultURL(bundle: bundle) ?? source) : source
            let oldFiles = referencedPNGs(oldPoses)
            guard oldFiles.count > 0,
                  oldFiles.allSatisfy({ file in
                      guard file == URL(fileURLWithPath: file).lastPathComponent,
                            let installed = try? Data(contentsOf: directory.appendingPathComponent(file)),
                            let retained = try? Data(contentsOf: retainedSource.appendingPathComponent(file))
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
                          && (intervals[pose] ?? pose.frameInterval(forFrames: row.frames)) > 0
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

            // Rotation layers are part of the atomic stock upgrade, not optional
            // decoration. Refuse a partial cast before writing the active map.
            guard let sourceJSON = try? JSONSerialization.jsonObject(with: sourceState) as? [String: Any],
                  let sourceRows = sourceJSON["poses"] as? [String: [String: Any]]
            else { return .failed }
            // Validate one pose at a time. The illustrated pack contains up
            // to 256 frames; retaining all four decoded casts here wastes RAM.
            var rotationManifests: [PetSpritePose: PetRotationManifest] = [:]
            for (poseName, row) in sourceRows where row["rotation"] != nil {
                guard let pose = PetSpritePose(rawValue: poseName),
                      let manifest = autoreleasepool(invoking: {
                          loadRotations(in: source, fileManager: fileManager, only: [pose])[pose]?.manifest
                      })
                else { return .failed }
                rotationManifests[pose] = manifest
                for variant in manifest.variants {
                    for file in [variant.file, variant.bodyFile, variant.entryFile] {
                        guard file == URL(fileURLWithPath: file).lastPathComponent,
                              let data = try? Data(contentsOf: source.appendingPathComponent(file)),
                              !oldFiles.contains(file) || (try? Data(contentsOf: directory.appendingPathComponent(file))) == data
                        else { return .failed }
                        replacements[file] = data
                    }
                }
            }

            // Retina is part of the transaction, not a best-effort fallback.
            // Validate segmented cell counts, dimensions and cast identity before
            // writing anything; the state map is still the final atomic write.
            for (poseName, row) in sourceRows {
                guard let retinaJSON = row["retina"] else { continue }
                guard let pose = PetSpritePose(rawValue: poseName), let record = bundled[pose],
                      let retina = PetRetinaRow(retinaJSON),
                      let data = replacements[record.file],
                      let raster = NSImage(data: data).flatMap(PetSpriteStrip.raster)
                else { return .failed }
                let cell = CGSize(width: raster.width / record.frames, height: raster.height)
                if let rotation = rotationManifests[pose],
                   rotation.variants.map(\.id) != retina.variants.map(\.id) { return .failed }
                for files in [retina.file] + retina.variants.flatMap({ [$0.file, $0.bodyFile, $0.entryFile] }) {
                    guard files.allSatisfy({ $0 == URL(fileURLWithPath: $0).lastPathComponent }),
                          PetSpriteStrip.retinaCells(files, frames: record.frames, cell: cell, scale: retina.scale,
                                                    in: source, slicer: { _, count in Array(repeating: NSImage(), count: count) }) != nil
                    else { return .failed }
                    for file in files {
                        guard let data = try? Data(contentsOf: source.appendingPathComponent(file)),
                              !oldFiles.contains(file) || (try? Data(contentsOf: directory.appendingPathComponent(file))) == data
                        else { return .failed }
                        replacements[file] = data
                    }
                }
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
    /// files. The replacement strips land first and the state map changes
    /// last, so
    /// an interrupted write leaves the old pack readable and retryable.
    /// 0.5.316 (V12.6): every pose is new art, so a recognized stock pack takes
    /// the WHOLE bundled pack (all ten poses, their intervals and pack-owned
    /// scales), not only the four stories. The bytes are written raw: no
    /// importer cleanup (suppressTruncatedEdgeSlivers, normalizeStrip) runs here.
    @discardableResult
    static func refreshRecognizedBundledDefault(
        into directory: URL,
        from sourceOverride: URL? = nil,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> BundledDefaultRefreshResult {
        guard let source = sourceOverride ?? bundledDefaultURL(bundle: bundle) else { return .failed }
        let installed = loadStateMap(in: directory, fileManager: fileManager)
        let bundled = loadStateMap(in: source, fileManager: fileManager)
        // 0.5.325: the raw rows, for the rotation blocks (V14 timing-v2: duel, trio and swarm each shuffle three casts).
        func rawPoses(_ folder: URL) -> [String: [String: Any]] {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(stateFileName)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return json["poses"] as? [String: [String: Any]] ?? [:]
        }
        let installedRows = rawPoses(directory)
        let bundledRows = rawPoses(source)
        // The installed rotation is the bundled one when every variant's three layers are the bundled bytes, in the
        // same order, at the same handoff. File NAMES may differ: Miles's Mac holds V14 as installed by hand, under
        // rotation/v14-timing-v2/, and the bundle carries the same bytes under flat names.
        // 0.5.328: the bundled retina strips are part of "already current": the same block, every file the same bytes.
        func sameRetina(_ pose: PetSpritePose) -> Bool {
            guard let wanted = bundledRows[pose.rawValue]?["retina"] else { return true }
            guard let mine = installedRows[pose.rawValue]?["retina"],
                  let wantedData = try? JSONSerialization.data(withJSONObject: wanted, options: [.sortedKeys]),
                  let mineData = try? JSONSerialization.data(withJSONObject: mine, options: [.sortedKeys]),
                  wantedData == mineData, let row = PetRetinaRow(wanted) else { return false }
            return row.files.allSatisfy { file in
                guard let mineBytes = try? Data(contentsOf: directory.appendingPathComponent(file)),
                      let wantedBytes = try? Data(contentsOf: source.appendingPathComponent(file)) else { return false }
                return mineBytes == wantedBytes
            }
        }
        func sameRotation(_ pose: PetSpritePose) -> Bool {
            guard let wanted = bundledRows[pose.rawValue]?["rotation"] as? [String: Any] else { return true }
            guard let mine = installedRows[pose.rawValue]?["rotation"] as? [String: Any],
                  (mine["version"] as? Int) == (wanted["version"] as? Int),
                  (mine["handoffFrame"] as? Int) == (wanted["handoffFrame"] as? Int),
                  let mineVariants = mine["variants"] as? [[String: Any]],
                  let wantedVariants = wanted["variants"] as? [[String: Any]],
                  mineVariants.count == wantedVariants.count else { return false }
            return zip(mineVariants, wantedVariants).allSatisfy { m, w in
                (m["id"] as? String) == (w["id"] as? String) && ["file", "bodyFile", "entryFile"].allSatisfy { key in
                    guard let mineFile = m[key] as? String, PetRotationManifest.isRelativePath(mineFile),
                          let wantedFile = w[key] as? String,
                          let mineData = try? Data(contentsOf: directory.appendingPathComponent(mineFile)),
                          let wantedData = try? Data(contentsOf: source.appendingPathComponent(wantedFile))
                    else { return false }
                    return mineData == wantedData
                }
            }
        }
        // Already the bundled pack: a clean no-op, never a rewrite or a downgrade.
        if !bundled.isEmpty, installed.count == bundled.count,
           bundled.allSatisfy({ pose, row in
               guard let mine = installed[pose], mine.file == row.file, mine.frames == row.frames,
                     let installedData = try? Data(contentsOf: directory.appendingPathComponent(row.file)),
                     let bundledData = try? Data(contentsOf: source.appendingPathComponent(row.file))
               else { return false }
               return installedData == bundledData && sameRotation(pose) && sameRetina(pose)
           }) {
            return .current
        }
        // 0.5.325: a pack the earlier releases shipped WHOLE (V12.6, 0.5.316 to 0.5.324) is stock only as its exact
        // map. Same files with another speed, scale, count or an added rotation is the person's pack: left alone.
        // 0.5.328: V14 has two exact stock maps with the same pose files (flat as 0.5.325 to 0.5.327 shipped it, and
        // its layers under rotation/v14-timing-v2/ as Miles installed it), so the pack is stock when ANY map with its
        // files matches exactly, and the person's only when maps share its files and none matches.
        if let historyData = try? Data(contentsOf: source.appendingPathComponent("stock-state-history.json")),
           let history = try? JSONSerialization.jsonObject(with: historyData) as? [String: Any],
           let maps = history["maps"] as? [[String: Any]] {
            func canonical(_ object: Any) -> Data? {
                guard let data = try? JSONSerialization.data(withJSONObject: object),
                      let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                return try? encoder.encode(value)
            }
            let installedCanonical = (try? Data(contentsOf: directory.appendingPathComponent(stateFileName)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) }.flatMap(canonical)
            var sharesFiles = false
            var exactStock = false
            for map in maps {
                guard let state = map["state"] as? [String: Any], let poses = state["poses"] as? [String: [String: Any]],
                      poses.count == installedRows.count,
                      poses.allSatisfy({ name, row in
                          (installedRows[name]?["file"] as? String) == (row["file"] as? String)
                      })
                else { continue }
                sharesFiles = true
                if installedCanonical != nil, installedCanonical == canonical(state) { exactStock = true }
            }
            if sharesFiles && !exactStock { return .notApplicable }
        }
        let retainedStock: [PetSpritePose: [(file: String, frames: Int)]] = [
            .idle: [(poseFileName(.idle), 8), ("session-pet-idle-cutouts-v2.png", 8)],
            .patrol: [(poseFileName(.patrol), 8), ("session-pet-patrol-polish-v3.png", 8)],
            .waiting: [(poseFileName(.waiting), 8), ("session-pet-waiting-release-v1.png", 11)],
            .working: [
                (poseFileName(.working), 8),
                ("session-pet-working-error-story.png", 16),
                ("session-pet-working-story-v7.png", 16),
                ("session-pet-working-one-droid-v15.png", 16),
                ("session-pet-working-one-droid-v15-1.png", 16),
                ("session-pet-working-one-droid-v15-2.png", 16),
                ("session-pet-working-run-slowed-v12-1.png", 46),
                // 0.5.325 to 0.5.327 shipped V14 timing-v2: these four strips are its Sessions 1 to 4.
                ("session-pet-working-v13.png", 46),
            ],
            .done: [(poseFileName(.done), 8), ("session-pet-done-retime-v12-v1.png", 10)],
            .error: [(poseFileName(.error), 8), ("session-pet-error-reassembled-v12-v5.png", 8)],
            .attention: [(poseFileName(.attention), 6), ("session-pet-attention-retime-v12-v1.png", 13)],
            .duel: [
                (poseFileName(.duel), 8),
                ("session-pet-duel-two-droid-v5.png", 13),
                ("session-pet-duel-story-v7.png", 16),
                ("session-pet-duel-two-droid-v15.png", 13),
                ("session-pet-duel-two-droid-v15-1.png", 12),
                ("session-pet-duel-two-droid-v15-2.png", 17),
                ("session-pet-duel-tail-tighter-v12-5.png", 37),
                ("session-pet-duel-v13.png", 37),
            ],
            .trio: [
                (poseFileName(.trio), 6),
                ("session-pet-trio-story-v7.png", 12),
                ("session-pet-trio-story-v15.png", 13),
                ("session-pet-trio-story-v15-1.png", 13),
                ("session-pet-trio-story-v15-2.png", 13),
                ("session-pet-trio-story-v16.png", 26),
                ("session-pet-trio-story-v17.png", 26),
                ("session-pet-trio-deflect-eased-v12-6.png", 42),
                ("session-pet-trio-v13.png", 43),
            ],
            .swarm: [
                (poseFileName(.swarm), 6),
                ("session-pet-swarm-story-v7.png", 16),
                ("session-pet-swarm-story-v15.png", 16),
                ("session-pet-swarm-story-v15-1.png", 16),
                ("session-pet-swarm-story-v15-2.png", 23),
                ("session-pet-swarm-story-v15-3.png", 25),
                ("session-pet-swarm-story-v15-4.png", 26),
                ("session-pet-swarm-story-v16.png", 52),
                ("session-pet-swarm-alpha-v11-r2.png", 64),
                ("session-pet-swarm-v13.png", 64),
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

        // Every pose the bundled pack declares, and it must declare every pose the stock pack had.
        guard bundled.count == retainedStock.count else { return .failed }
        var stories: [(pose: PetSpritePose, file: String, frames: Int, data: Data)] = []
        for pose in PetSpritePose.allCases where retainedStock[pose] != nil {
            guard let row = bundled[pose],
                  let data = try? Data(contentsOf: source.appendingPathComponent(row.file)),
                  NSImage(data: data) != nil
            else { return .failed }
            stories.append((pose, row.file, row.frames, data))
        }
        // 0.5.325: every rotation layer the bundled pack declares is part of the upgrade, never optional decoration
        // (the 0.5.324 Jedi rule). Each one is checked, as the runtime reads it, before anything is written: a flat
        // name, a readable image the size of its pose strip. One bad layer refuses the whole upgrade.
        var layers: [String: Data] = [:]
        var rotationRows: [PetSpritePose: Any] = [:]
        for story in stories {
            guard let rotation = bundledRows[story.pose.rawValue]?["rotation"] else { continue }
            guard let rotationJSON = rotation as? [String: Any],
                  let rotationData = try? JSONSerialization.data(withJSONObject: rotationJSON, options: [.sortedKeys]),
                  let manifest = try? JSONDecoder().decode(PetRotationManifest.self, from: rotationData),
                  manifest.isValid(frames: story.frames),
                  let strip = NSImage(data: story.data).flatMap(PetSpriteStrip.raster)
            else { return .failed }
            for variant in manifest.variants {
                for file in [variant.file, variant.bodyFile, variant.entryFile] {
                    guard file == URL(fileURLWithPath: file).lastPathComponent,
                          let data = try? Data(contentsOf: source.appendingPathComponent(file)),
                          let layer = NSImage(data: data).flatMap(PetSpriteStrip.raster),
                          layer.width == strip.width, layer.height == strip.height
                    else {
                        NSLog("COSControl Miles upgrade rejected an incomplete rotation layer: %@", file)
                        return .failed
                    }
                    layers[file] = data
                }
            }
            rotationRows[story.pose] = rotationJSON
        }
        // 0.5.328 (Version 15): the retina strips land with the art they belong to, checked as the runtime reads them
        // (flat names, the 1x strip's cells at twice the pixels, native caps, cells adding up to the frame count).
        var retinaRows: [PetSpritePose: Any] = [:]
        for story in stories {
            guard let retinaJSON = bundledRows[story.pose.rawValue]?["retina"] else { continue }
            guard let retina = PetRetinaRow(retinaJSON),
                  let strip = NSImage(data: story.data).flatMap(PetSpriteStrip.raster), strip.width % story.frames == 0
            else { return .failed }
            let cell = CGSize(width: strip.width / story.frames, height: strip.height)
            for files in [retina.file] + retina.variants.flatMap({ [$0.file, $0.bodyFile, $0.entryFile] }) {
                guard files.allSatisfy({ $0 == URL(fileURLWithPath: $0).lastPathComponent }),
                      PetSpriteStrip.retinaCells(files, frames: story.frames, cell: cell, scale: retina.scale, in: source,
                                                 slicer: { _, count in Array(repeating: NSImage(), count: count) }) != nil
                else {
                    NSLog("COSControl Miles upgrade rejected an incomplete retina strip: %@", files.joined(separator: ","))
                    return .failed
                }
                for file in files {
                    guard let data = try? Data(contentsOf: source.appendingPathComponent(file)) else { return .failed }
                    layers[file] = data
                }
            }
            if let manifest = bundledRows[story.pose.rawValue]?["rotation"] as? [String: Any],
               let ids = (manifest["variants"] as? [[String: Any]])?.compactMap({ $0["id"] as? String }),
               ids != retina.variants.map(\.id) {
                return .failed
            }
            retinaRows[story.pose] = retinaJSON
        }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for story in stories {
                try story.data.write(
                    to: directory.appendingPathComponent(story.file), options: .atomic
                )
            }
            for (file, data) in layers {
                try data.write(to: directory.appendingPathComponent(file), options: .atomic)
            }
            guard stories.allSatisfy({ story in
                (try? Data(contentsOf: directory.appendingPathComponent(story.file))) == story.data
            }), layers.allSatisfy({ file, data in
                (try? Data(contentsOf: directory.appendingPathComponent(file))) == data
            })
            else { return .failed }
            var updated = installed
            for story in stories {
                updated[story.pose] = (story.file, story.frames)
            }
            let installedScales = loadRenderScales(in: directory, fileManager: fileManager)
            let bundledScales = loadRenderScales(in: source, fileManager: fileManager)
            let idleScaleWasStock = installedScales[.idle] == nil
                || abs((installedScales[.idle] ?? 0) - 1.2) < 0.001
                || abs((installedScales[.idle] ?? 0) - 1.3) < 0.001
                || abs((installedScales[.idle] ?? 0) - 1.45) < 0.001
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
                clearRotations: Set(stories.map(\.pose)),
                rotations: rotationRows,
                retinas: retinaRows,
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
        clearRotations: Set<PetSpritePose> = [],
        rotations: [PetSpritePose: Any] = [:],
        retinas: [PetSpritePose: Any] = [:],
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
        let previousData = try? Data(contentsOf: directory.appendingPathComponent(stateFileName))
        let previousJSON = previousData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let previousPoses = previousJSON?["poses"] as? [String: [String: Any]] ?? [:]
        var poses: [String: [String: Any]] = [:]
        for pose in PetSpritePose.allCases {
            guard let row = map[pose] else { continue }
            var payload: [String: Any] = ["file": row.file, "frames": row.frames]
            if let interval = retainedIntervals[pose] { payload["interval"] = interval }
            if let scale = retainedScales[pose] { payload["renderScale"] = scale }
            // Unrelated pose/settings changes retain valid optional metadata.
            // New art and frame-count changes retire its old choreography.
            if !clearRotations.contains(pose), let old = previousPoses[pose.rawValue],
               old["file"] as? String == row.file, old["frames"] as? Int == row.frames,
               let rotation = old["rotation"] { payload["rotation"] = rotation }
            // 0.5.328: the retina strips belong to the same art, so they follow the same rule (a speed or scale change
            // keeps them; new art or another frame count retires them).
            if !clearRotations.contains(pose), let old = previousPoses[pose.rawValue],
               old["file"] as? String == row.file, old["frames"] as? Int == row.frames,
               let retina = old["retina"] { payload["retina"] = retina }
            // A stock upgrade lands the bundled cast with the new art (its layers are already written and checked).
            if let rotation = rotations[pose] { payload["rotation"] = rotation }
            if let retina = retinas[pose] { payload["retina"] = retina }
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

extension JSONValue {
    /// Foundation form for JSONSerialization. Used to hand a settings patch back
    /// to the helper on stdin exactly as the server will parse it.
    var foundationValue: Any {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value
        case .number(let value): return value == value.rounded() && abs(value) < 1e15 ? Int(value) : value
        case .object(let value): return value.mapValues { $0.foundationValue }
        case .array(let value): return value.map(\.foundationValue)
        case .null: return NSNull()
        }
    }
}

/// The morning brief as the server describes it: the saved config, the source
/// catalog a settings screen renders from, the status line, and recent runs.
/// Parsed from `GET /api/morning-brief` via the helper's `morning-brief` command.
struct MorningBriefSettings: Sendable {
    struct OptionSpec: Sendable, Identifiable {
        let key: String
        let type: String
        let label: String
        let unit: String?
        let placeholder: String?
        let min: Int?
        let max: Int?
        let defaultValue: JSONValue
        var id: String { key }
    }

    struct SourceSpec: Sendable, Identifiable {
        let id: String
        let label: String
        let description: String
        let options: [OptionSpec]
    }

    struct Source: Sendable, Identifiable {
        var id: String
        var enabled: Bool
        var options: [String: JSONValue]
    }

    /// Server 6.43.1: what the server can see behind one source. `state` is
    /// ready / empty / unavailable / runtime; `summary` is one settings line.
    struct Coverage: Sendable {
        let state: String
        let summary: String
    }

    /// Server 6.43.1: one asked-for section of a finished run and how it came
    /// back (present / unavailable / skipped / missing / pending).
    struct SectionOutcome: Sendable, Identifiable {
        let id: String
        let label: String
        let state: String
    }

    struct Run: Sendable, Identifiable {
        let id: String
        let trigger: String
        let firedAt: String
        let status: String
        let globalMsgNum: Int?
        let preview: String?
        let errorMessage: String?
        let sections: [SectionOutcome]

        /// "3 of 4 sections · calendar not delivered", or nil before completion.
        var sectionsLabel: String? {
            guard status == "completed", !sections.isEmpty else { return nil }
            let present = sections.filter { $0.state == "present" }.count
            let notDelivered = sections.filter { $0.state == "unavailable" || $0.state == "missing" }.map { $0.label.lowercased() }
            var line = "\(present) of \(sections.count) section\(sections.count == 1 ? "" : "s")"
            if !notDelivered.isEmpty {
                line += " · " + notDelivered.prefix(2).joined(separator: ", ")
                if notDelivered.count > 2 { line += " +\(notDelivered.count - 2)" }
                line += " not delivered"
            }
            return line
        }
    }

    var enabled: Bool
    var time: String
    var timezone: String
    var days: [Int]
    var model: String?
    var sources: [Source]
    var closingInstruction: String
    var updatedAt: String
    let catalog: [SourceSpec]
    let nextRunAt: String?
    let gate: String
    let serverTimezone: String
    let runs: [Run]
    /// Keyed by source id. Empty on a 6.43.0 server (no `coverage` in the reply).
    let coverage: [String: Coverage]

    init?(_ details: [String: JSONValue]) {
        guard let config = details["config"]?.object,
              let time = config["time"]?.string,
              let timezone = config["timezone"]?.string else { return nil }
        enabled = config["enabled"]?.bool ?? true
        self.time = time
        self.timezone = timezone
        days = (config["days"]?.array ?? []).compactMap(\.int)
        model = config["model"]?.string
        sources = (config["sources"]?.array ?? []).compactMap { entry in
            guard let object = entry.object, let id = object["id"]?.string else { return nil }
            return Source(id: id, enabled: object["enabled"]?.bool ?? false, options: object["options"]?.object ?? [:])
        }
        closingInstruction = config["closingInstruction"]?.string ?? ""
        updatedAt = config["updatedAt"]?.string ?? ""
        catalog = (details["sources"]?.array ?? []).compactMap { entry in
            guard let object = entry.object, let id = object["id"]?.string else { return nil }
            let options = (object["options"]?.object ?? [:]).compactMap { key, value -> OptionSpec? in
                guard let spec = value.object, let type = spec["type"]?.string else { return nil }
                return OptionSpec(
                    key: key,
                    type: type,
                    label: spec["label"]?.string ?? key,
                    unit: spec["unit"]?.string,
                    placeholder: spec["placeholder"]?.string,
                    min: spec["min"]?.int,
                    max: spec["max"]?.int,
                    defaultValue: spec["default"] ?? .null
                )
            }.sorted { $0.key < $1.key }
            return SourceSpec(
                id: id,
                label: object["label"]?.string ?? id,
                description: object["description"]?.string ?? "",
                options: options
            )
        }
        let status = details["status"]?.object ?? [:]
        nextRunAt = status["nextRunAt"]?.string
        gate = status["gate"]?.string ?? "ready"
        serverTimezone = status["serverTimezone"]?.string ?? timezone
        runs = (details["runs"]?.array ?? []).compactMap { entry in
            guard let object = entry.object, let id = object["id"]?.string else { return nil }
            let sections = (object["sections"]?.array ?? []).compactMap { entry -> SectionOutcome? in
                guard let section = entry.object, let sectionID = section["id"]?.string else { return nil }
                return SectionOutcome(
                    id: sectionID,
                    label: section["label"]?.string ?? sectionID,
                    state: section["state"]?.string ?? "pending"
                )
            }
            return Run(
                id: id,
                trigger: object["trigger"]?.string ?? "scheduled",
                firedAt: object["firedAt"]?.string ?? "",
                status: object["status"]?.string ?? "unknown",
                globalMsgNum: object["globalMsgNum"]?.int,
                preview: object["preview"]?.string,
                errorMessage: object["error"]?.object?["message"]?.string,
                sections: sections
            )
        }
        var coverage: [String: Coverage] = [:]
        for entry in details["coverage"]?.object?["sources"]?.array ?? [] {
            guard let row = entry.object, let sourceID = row["id"]?.string,
                  let summary = row["summary"]?.string, !summary.isEmpty else { continue }
            coverage[sourceID] = Coverage(state: row["state"]?.string ?? "runtime", summary: summary)
        }
        self.coverage = coverage
    }

    func spec(for sourceID: String) -> SourceSpec? {
        catalog.first { $0.id == sourceID }
    }

    /// The patch `PUT /api/morning-brief` accepts, built from the editable fields.
    func patch() -> [String: Any] {
        [
            "enabled": enabled,
            "time": time,
            "timezone": timezone,
            "days": days,
            "model": model ?? NSNull(),
            "sources": sources.map { source -> [String: Any] in
                ["id": source.id, "enabled": source.enabled, "options": source.options.mapValues { $0.foundationValue }]
            },
            "closingInstruction": closingInstruction,
        ]
    }

    /// "Tue 7:00 AM" in the Mac's locale, or nil when the brief is off.
    /// Formatters are built per call: ISO8601DateFormatter is not Sendable, so a
    /// static instance fails strict concurrency, and this runs on a click.
    var nextRunLabel: String? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let nextRunAt, let date = iso.date(from: nextRunAt) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = TimeZone(identifier: timezone) ?? .current
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Import and merge meetings (server 6.47.0)
//
// Three surfaces share these: the Import meetings card, the Suggested merges
// list, and the merged-record CTAs on a meeting detail.
//
// EVERY TYPE HERE CARRIES ITS OWN "the server does not have this route" STATE.
// COS Control ships on its own appcast and @gotcos/glasses-server ships on npm,
// so a Mac running 0.5.230 against 6.46.x is an ordinary, expected pairing. It
// has to read as "Update the COS server to 6.47.0" with a button, never as a
// failure and never as an empty list that looks like nothing to do.

/// What this Mac does with Fireflies meetings and G2 recordings.
///
/// `imports` is a Mac with no COS pipeline: the server imports and merges on its
/// own. `advise` and `apply` are a pipeline Mac, and the difference between them
/// is whether anything is written into the operations tree.
enum MeetingEngineMode: String, Sendable, CaseIterable {
    case imports
    case advise
    case apply

    /// Nil for `imports`: that is not a mode anyone chose and not one they can leave.
    var switchTitle: String? {
        switch self {
        case .imports: nil
        case .advise: "Suggesting only"
        case .apply: "Merging into your meetings"
        }
    }
}

/// How a merge route answered.
///
/// `routeAbsent` and `refused` are deliberately separate from a thrown error:
/// both have copy and an affordance, and an error has neither.
enum MergeRouteState: String, Sendable {
    case ready
    case preview
    case routeAbsent = "route_absent"
    case refused

    init(_ raw: String?) {
        self = MergeRouteState(rawValue: raw ?? "") ?? .ready
    }
}

/// A meeting recorder this Mac has installed.
///
/// Answered by a LaunchServices registry lookup, which opens no app and reads no
/// app data. The card uses it for one sentence — "Fireflies is on this Mac" —
/// because a person who has the app is a person who has a key to paste.
struct MeetingRecorder: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let bundleId: String
    let installed: Bool

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let id = o["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        name = o["name"]?.string ?? id.localizedCapitalized
        bundleId = o["bundleId"]?.string ?? ""
        installed = o["installed"]?.bool ?? false
    }
}

struct FirefliesKeyState: Sendable, Equatable {
    var configured = false
    /// "config" for the stored file, "env" for FIREFLIES_API_KEY, "none".
    var source = "none"
    var savedAt = ""
    var validatedAt = ""
    /// "ok", "invalid_key", "rate_limited", "vendor_down", "unreachable",
    /// "not_configured". Empty when the key has never been checked.
    var lastCheck = ""
    var lastCheckAt = ""
    var routeAbsent = false

    /// The one line the card shows about the key.
    var summary: String {
        if routeAbsent { return "Needs COS server 6.47.0" }
        if !configured { return "No key yet" }
        switch lastCheck {
        case "ok": return source == "env" ? "Key from the environment, accepted" : "Key accepted"
        case "invalid_key": return "Fireflies refused this key"
        case "rate_limited": return "Fireflies is rate limiting this key"
        case "vendor_down": return "Fireflies is down"
        case "unreachable": return "Fireflies could not be reached"
        default: return "Key stored, not checked yet"
        }
    }

    /// True when the only way forward is a different key.
    var needsNewKey: Bool { configured && lastCheck == "invalid_key" }

    init() {}

    init(_ details: [String: JSONValue]) {
        routeAbsent = MergeRouteState(details["routeState"]?.string) == .routeAbsent
        configured = details["configured"]?.bool ?? false
        source = details["source"]?.string ?? "none"
        savedAt = details["savedAt"]?.string ?? ""
        validatedAt = details["validatedAt"]?.string ?? ""
        let check = details["lastCheck"]?.object
        lastCheck = check?["state"]?.string ?? ""
        lastCheckAt = check?["checkedAt"]?.string ?? ""
    }
}

/// One Fireflies plan and the calls a day it allows. `calls` is nil for a plan
/// with no cap.
struct FirefliesPlanCap: Sendable, Equatable, Hashable {
    let id: String
    let label: String
    let calls: Int?
}

/// What the importer is doing, and what it has brought in.
struct MeetingImportState: Sendable, Equatable {
    /// THE SERVER OWNS BOTH OF THESE. They are restated here only as the answer
    /// for a server that does not send them, and `Tests/run.sh` pins the values
    /// against their definitions:
    ///   `IMPORT_WINDOW_DAYS`     — server/lib/meeting-import.ts
    ///   `FIREFLIES_PLAN_CAPS`    — server/lib/fireflies-client.ts
    /// A number typed into a sentence is the thing that goes stale silently, so
    /// nothing below renders a literal: the picker and the budget line are both
    /// built from whichever list is in force.
    static let fallbackWindowOptions = [7, 30, 90]
    static let fallbackPlanCaps = [
        FirefliesPlanCap(id: "free", label: "Free", calls: 50),
        FirefliesPlanCap(id: "pro", label: "Pro", calls: 500),
        FirefliesPlanCap(id: "business", label: "Business", calls: nil),
    ]

    var routeAbsent = false
    /// `idle`, `running`, `ok`, `partial`, `invalid_key`, `rate_limited`,
    /// `vendor_down`, `unreachable`, `write_unlisted`, `refused_pipeline`.
    var state = "idle"
    var mode: MeetingEngineMode = .imports
    var running = false
    var keyConfigured = false
    var keepImporting = false
    var planCap = "free"
    var windowDays = 30
    /// The windows this server accepts, and the plans it knows, as IT reports
    /// them. Both fall back to the pinned lists above for a server that is quiet.
    var windowOptions = MeetingImportState.fallbackWindowOptions
    var planCaps = MeetingImportState.fallbackPlanCaps
    var imported = 0
    var vendorSeen = 0
    var retryable = 0
    var budgetCalls = 0
    /// Nil on a Business plan, which has no daily cap.
    var budgetCap: Int?
    var budgetRemaining: Int?
    var lastRunWritten = 0
    var lastRunFinishedAt = ""
    var nextAttemptAt = ""

    /// The headline the card shows. ONE SENTENCE PER STATE, and every one of them
    /// is followed by an affordance in the card: a state with no way forward is
    /// the failure this release's principle 6 exists to prevent.
    var headline: String {
        if routeAbsent { return "Update the COS server to 6.47.0" }
        switch state {
        case "refused_pipeline": return "Your COS pipeline already brings in Fireflies meetings."
        case "running": return "Bringing in your Fireflies meetings"
        case "invalid_key": return "Fireflies refused this key"
        case "rate_limited": return "Fireflies is rate limiting this key"
        case "vendor_down": return "Fireflies is down"
        case "unreachable": return "Fireflies could not be reached"
        case "write_unlisted": return "A meeting was written that Fireflies then did not list"
        case "partial": return "Some meetings are still to come"
        case "ok": return imported == 0 ? "Nothing to bring in yet" : "\(imported) meeting\(imported == 1 ? "" : "s") brought in"
        default: return keyConfigured ? "Ready to bring in your meetings" : "Connect Fireflies to bring in meetings it recorded"
        }
    }

    /// The second line: what a person can do about the headline.
    var guidance: String {
        if routeAbsent { return "This Mac's COS server does not have the import routes yet." }
        switch state {
        case "refused_pipeline": return "COS files them into your meetings tree, so the server does not import them a second time."
        case "invalid_key": return "Paste a new key and check it."
        case "rate_limited": return nextAttemptAt.isEmpty ? "COS waits and tries again." : "COS tries again at \(nextAttemptAt)."
        case "vendor_down", "unreachable": return "COS tries again on its own. Import now retries straight away."
        case "write_unlisted": return "COS stopped rather than write more. Import now tries again."
        case "partial": return retryable > 0 ? "\(retryable) still processing at Fireflies. COS retries them." : "COS reached its daily call limit and resumes tomorrow."
        default: return budgetLine
        }
    }

    /// Calls used against the plan's daily cap, or nothing on an uncapped plan.
    var budgetLine: String {
        guard let cap = budgetCap else { return "This plan has no daily call limit." }
        let left = budgetRemaining ?? max(0, cap - budgetCalls)
        return "\(budgetCalls) of \(cap) Fireflies calls used today. \(left) left."
    }

    /// "Your plan sets how many calls a day COS may make. Free is 50, Pro is 500,
    /// Business has no limit." BUILT, never typed: the caps belong to the server,
    /// and a sentence with them spelled into it goes stale without a word.
    var planCapLine: String {
        guard !planCaps.isEmpty else { return "Your plan sets how many calls a day COS may make." }
        let parts = planCaps.map { plan in
            plan.calls.map { "\(plan.label) is \($0)" } ?? "\(plan.label) has no limit"
        }
        return "Your plan sets how many calls a day COS may make. " + parts.joined(separator: ", ") + "."
    }

    /// Whether this Mac's server will import at all. False in advise and apply.
    var importsHere: Bool { mode == .imports }

    init() {}

    init(_ details: [String: JSONValue]) {
        // TWO STATES, TWO KEYS. `routeState` is the helper's verdict about the
        // ROUTE (present, absent, refused); `state` is the importer's own run
        // state. One key for both is how a 6.46.x server's "route_absent" would
        // have read as an importer that is merely idle.
        routeAbsent = MergeRouteState(details["routeState"]?.string) == .routeAbsent
        state = routeAbsent ? "idle" : (details["state"]?.string ?? "idle")
        mode = MeetingEngineMode(rawValue: details["mode"]?.string ?? "") ?? .imports
        running = details["running"]?.bool ?? false
        keyConfigured = details["keyConfigured"]?.bool ?? false
        keepImporting = details["keepImporting"]?.bool ?? false
        planCap = details["planCap"]?.string ?? "free"
        windowDays = details["windowDays"]?.int ?? 30
        let counts = details["counts"]?.object
        imported = counts?["imported"]?.int ?? 0
        vendorSeen = counts?["vendorSeen"]?.int ?? 0
        retryable = counts?["retryable"]?.int ?? 0
        let budget = details["budget"]?.object
        budgetCalls = budget?["calls"]?.int ?? 0
        budgetCap = budget?["cap"]?.int
        budgetRemaining = budget?["remaining"]?.int
        let lastRun = details["lastRun"]?.object
        lastRunWritten = lastRun?["written"]?.int ?? 0
        lastRunFinishedAt = lastRun?["finishedAt"]?.string ?? ""
        nextAttemptAt = details["nextAttemptAt"]?.string ?? ""
        // THE SERVER'S LISTS WIN, and the pinned fallbacks are for a server that
        // does not send them. Last, because an unknown plan borrows the budget's
        // own cap, which is decoded above.
        let servedWindows = (details["windowOptions"]?.array ?? []).compactMap(\.int).filter { $0 > 0 }
        windowOptions = servedWindows.isEmpty ? Self.fallbackWindowOptions : servedWindows
        let servedPlans = (details["planCaps"]?.array ?? []).compactMap { entry -> FirefliesPlanCap? in
            guard let o = entry.object, let id = o["id"]?.string, !id.isEmpty else { return nil }
            return FirefliesPlanCap(id: id, label: o["label"]?.string ?? id.localizedCapitalized,
                                    calls: o["calls"]?.int)
        }
        planCaps = servedPlans.isEmpty ? Self.fallbackPlanCaps : servedPlans
        // A picker must hold the value it is bound to, or SwiftUI renders an
        // empty menu and a person cannot get back to what they had.
        if !windowOptions.contains(windowDays) { windowOptions = (windowOptions + [windowDays]).sorted() }
        if !planCaps.contains(where: { $0.id == planCap }) {
            planCaps.append(FirefliesPlanCap(id: planCap, label: planCap.localizedCapitalized, calls: budgetCap))
        }
    }
}

/// One side of a suggestion: a Fireflies meeting or a G2 recording.
///
/// THE SERVER RESOLVES BOTH SIDES. Only it can see a pipeline Mac's operations
/// tree, so `resolved` is its answer and not a guess made from a list Control
/// happened to hold. 0.5.230 re-derived an imported record id here and joined it
/// against the recent list, which resolved imported records only: on a pipeline
/// Mac, the Mac this pane exists for, every Fireflies side rendered as an id.
struct MeetingSuggestionSide: Identifiable, Sendable, Hashable {
    let kind: String
    let sourceId: String
    let resolved: Bool
    let title: String
    let date: String
    let time: String
    let duration: String
    let source: String
    let recordId: String

    var id: String { "\(kind):\(sourceId)" }

    var kindLabel: String { kind == "g2" ? "G2 recording" : "Fireflies meeting" }

    /// Which library the server found this side in, IN WORDS.
    ///
    /// The server sends a store name: `imported`, `cos_operations` or
    /// `standalone_recordings` (`SuggestionSide` in
    /// server/lib/meeting-suggestion-sides.ts). Those are not something to put in
    /// front of a person. Anything else passes through unchanged, so a store COS
    /// has no word for still reads as itself rather than vanishing.
    var sourceLabel: String {
        switch source {
        case "imported": "Brought in from Fireflies"
        case "cos_operations": "In your meetings tree"
        case "standalone_recordings": "Recorded on this Mac"
        default: source
        }
    }

    /// "2026-09-10 · 14:30 · 47 minutes · Fireflies", or nothing.
    ///
    /// EMPTY WHEN THERE IS NOTHING TO SAY, and the row leaves it out. A side the
    /// server could not place already reads as its kind and a short id in
    /// `displayTitle`, so a fallback here printed that same string twice.
    var line: String { line(clock: .twentyFourHour) }

    func line(clock: ClockStyle) -> String {
        var parts: [String] = []
        if !date.isEmpty { parts.append(date) }
        if !time.isEmpty { parts.append(clock.format(time)) }
        if !duration.isEmpty { parts.append(duration) }
        if !sourceLabel.isEmpty { parts.append(sourceLabel) }
        return parts.joined(separator: " · ")
    }

    /// Shown under an unresolved side, and under nothing else. 0.5.230 put this
    /// on the pane's header, where it spoke for rows that were perfectly fine.
    var unresolvedNote: String? {
        resolved ? nil : "Not in the library"
    }

    var displayTitle: String { resolved && !title.isEmpty ? title : "\(kindLabel) \(shortId)" }

    var shortId: String { sourceId.count <= 12 ? sourceId : String(sourceId.suffix(8)) }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let kind = o["kind"]?.string, let sourceId = o["id"]?.string,
              !kind.isEmpty, !sourceId.isEmpty else { return nil }
        self.kind = kind
        self.sourceId = sourceId
        resolved = o["resolved"]?.bool ?? false
        title = o["title"]?.string ?? ""
        date = o["date"]?.string ?? ""
        time = o["time"]?.string ?? ""
        duration = o["duration"]?.string ?? ""
        source = o["source"]?.string ?? ""
        recordId = o["recordId"]?.string ?? ""
    }
}

/// Something the engine wants a person to decide.
struct MeetingSuggestion: Identifiable, Sendable, Hashable {
    let id: String
    /// `merge` (imports mode), `would_merge` (advise mode), `split`.
    let kind: String
    let suggestionState: String
    let k1: Int
    let k2: Int
    let spans: Int
    let at: String
    let sides: [MeetingSuggestionSide]

    /// An advise-mode row the engine WOULD have merged on its own.
    var isWouldMerge: Bool { kind == "would_merge" }
    var isSplit: Bool { kind == "split" }
    var isOpen: Bool { suggestionState == "open" }

    /// "Shares 41 phrases". The evidence, in the unit the engine actually counted.
    var evidenceLine: String {
        if isSplit { return spans > 0 ? "\(spans) span\(spans == 1 ? "" : "s") of one long recording" : "One long recording" }
        return "Shares \(k1) phrase\(k1 == 1 ? "" : "s")"
    }

    var headline: String {
        if isSplit { return "Split from a longer recording" }
        return isWouldMerge ? "Would merge automatically" : "Same meeting?"
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let id = o["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        kind = o["kind"]?.string ?? "merge"
        suggestionState = o["suggestionState"]?.string ?? "open"
        k1 = o["k1"]?.int ?? 0
        k2 = o["k2"]?.int ?? 0
        spans = o["spans"]?.int ?? 0
        at = o["at"]?.string ?? ""
        sides = (o["sides"]?.array ?? []).compactMap(MeetingSuggestionSide.init)
    }
}

/// What the engine did, and whether it can still be undone.
struct MergeAction: Identifiable, Sendable, Hashable {
    let id: String
    let kind: String
    /// `auto`, `accepted_suggestion`, or `legacy_applied` for a merge the COS
    /// pipeline made before the engine existed.
    let tier: String
    /// `pending`, `applied`, `failed`, `revert_pending`, `reverted`.
    let actionState: String
    /// `apply` or `revert`: which way the last attempt was going.
    ///
    /// A FAILED REVERT IS NOT A FAILED MERGE. Without this, "This merge did not
    /// finish" sat on a row whose undo failed, and Retry read as "try the merge
    /// again" — the opposite of what the person asked for.
    let direction: String
    /// `imports` or `apply` — where the effect landed.
    let mode: String
    let outputs: [String]
    let recordIds: [String]
    let error: String
    let at: String
    let attempts: Int
    let sessionIds: [String]
    let firefliesIds: [String]
    let legacyParentPath: String
    /// A failed action's spawn detail, one `name value` line each, as the server
    /// recorded it: `{ code, signal, timedOut, elapsedMs, stderr?,
    /// decisionInvalid?, spawnError? }`. "Command failed" with an empty stderr is
    /// three different bugs (a non-zero exit, a timeout kill, a failed fork) and
    /// each is its own field, so Copy diagnostics carries all of them rather than
    /// whichever one happened to be non-empty.
    let diagnosticLines: [String]

    /// A pipeline merge from before the engine. It is real, and COS did not make
    /// it, so COS does not offer to undo it.
    var isLegacy: Bool { tier == "legacy_applied" }
    var isRevertible: Bool { actionState == "applied" && !isLegacy }
    var isFailed: Bool { actionState == "failed" }
    var isPending: Bool { actionState == "pending" || actionState == "revert_pending" }
    /// An undo the server accepted but has not run yet.
    var isRevertPending: Bool { actionState == "revert_pending" }
    var isUndoing: Bool { direction == "revert" }

    /// Retry is offered for a state a person can actually get out of.
    ///
    /// `revert_pending` IS ONE OF THEM. The server defers an undo behind the sync
    /// lock or a drain, and before 6.47.0's retry route nothing re-drove it until
    /// the server restarted: the row sat there and the mode switch stayed frozen,
    /// with no affordance anywhere.
    var isRetryable: Bool { isFailed || isRevertPending }

    /// The line a merged detail shows above its Undo.
    var headline: String {
        if kind == "split" { return "Split from a longer recording" }
        if isLegacy { return "Merged by your COS pipeline" }
        return tier == "accepted_suggestion" ? "Merged from your suggestion" : "Merged automatically: G2 + Fireflies"
    }

    var stateLine: String {
        switch actionState {
        case "pending": return "Still finishing"
        // NOT "Undo running". The server parks a deferred undo here when the
        // meeting sync holds the lock, and a line that claims it is running is
        // why a stuck row looked like a slow one.
        case "revert_pending": return "Undo waiting for the meeting sync"
        case "reverted": return "Undone"
        case "failed":
            let head = isUndoing ? "Undo failed" : "This merge did not finish"
            return error.isEmpty ? head : "\(head): \(error)"
        default: return at.isEmpty ? "Applied" : "Applied \(at)"
        }
    }

    /// The direction to display, for a row that may not carry one.
    ///
    /// THE SERVER DOES NOT DERIVE THIS, and says why: a retryable failure sends
    /// an action back to a waiting state, so reading the direction out of the
    /// state turned the retry of an undo into a redo. This is the display-only
    /// fallback for a row written BEFORE the field existed, and it derives only
    /// from the two states nothing but an undo can produce. A legacy `failed`
    /// row stays an apply, because that is the ambiguous case and guessing it
    /// wrong is exactly the bug the server's rule exists to prevent.
    static func resolvedDirection(_ served: String?, actionState: String) -> String {
        if let served, !served.isEmpty { return served }
        return (actionState == "revert_pending" || actionState == "reverted") ? "revert" : "apply"
    }

    /// The word on the button that re-drives it.
    ///
    /// FOLLOWS THE DIRECTION, and a parked undo gets its own word: the server
    /// refuses a retry on anything that is not `failed` with "That one is already
    /// queued. Give it a moment." so "Try the undo again" would promise something
    /// the button cannot do. What it CAN do is ask, and say what came back.
    var retryLabel: String {
        if isRevertPending { return "Check on it" }
        return isUndoing ? "Try the undo again" : "Try the merge again"
    }

    /// Everything a person would paste into a bug report, and nothing they would
    /// not: ids, state and paths this Mac already shows, never file content.
    var diagnostics: String {
        var lines = ["action \(id)", "kind \(kind)", "tier \(tier)", "state \(actionState)",
                     "direction \(direction)", "mode \(mode)"]
        if attempts > 0 { lines.append("attempts \(attempts)") }
        if !at.isEmpty { lines.append("at \(at)") }
        if !error.isEmpty { lines.append("error \(error)") }
        if !sessionIds.isEmpty { lines.append("g2 \(sessionIds.joined(separator: ", "))") }
        if !firefliesIds.isEmpty { lines.append("fireflies \(firefliesIds.joined(separator: ", "))") }
        if !outputs.isEmpty { lines.append("outputs \(outputs.joined(separator: ", "))") }
        if !legacyParentPath.isEmpty { lines.append("pipeline parent \(legacyParentPath)") }
        lines += diagnosticLines
        return lines.joined(separator: "\n")
    }

    init?(_ value: JSONValue?) {
        guard let o = value?.object, let id = o["id"]?.string, !id.isEmpty else { return nil }
        self.id = id
        kind = o["kind"]?.string ?? "merge"
        tier = o["tier"]?.string ?? "auto"
        actionState = o["actionState"]?.string ?? "applied"
        direction = Self.resolvedDirection(o["direction"]?.string,
                                          actionState: o["actionState"]?.string ?? "applied")
        mode = o["mode"]?.string ?? "imports"
        outputs = o["outputs"]?.array?.compactMap(\.string) ?? []
        recordIds = o["recordIds"]?.array?.compactMap(\.string) ?? []
        error = o["error"]?.string ?? ""
        at = o["at"]?.string ?? ""
        attempts = o["attempts"]?.int ?? 0
        sessionIds = o["sessionIds"]?.array?.compactMap(\.string) ?? []
        firefliesIds = o["firefliesIds"]?.array?.compactMap(\.string) ?? []
        legacyParentPath = o["legacyParentPath"]?.string ?? ""
        diagnosticLines = Self.diagnosticLines(o["diagnostics"]?.object)
    }

    /// EVERY FIELD, including the ones that are zero or false.
    ///
    /// `code 0` with `timedOut true` is a different bug from `code 1`, and a
    /// diagnostics block that prints only the truthy fields cannot tell them
    /// apart. `stderr` is the server's own capture of the child's output and is
    /// carried whole; nothing here reads a file.
    static func diagnosticLines(_ diagnostics: [String: JSONValue]?) -> [String] {
        guard let diagnostics, !diagnostics.isEmpty else { return [] }
        var lines: [String] = []
        for key in ["code", "signal", "timedOut", "elapsedMs", "spawnError", "decisionInvalid"] {
            guard let value = diagnostics[key] else { continue }
            if let text = value.string { lines.append("\(key) \(text)") }
            else if let number = value.int { lines.append("\(key) \(number)") }
            else if let flag = value.bool { lines.append("\(key) \(flag)") }
        }
        if let stderr = diagnostics["stderr"]?.string, !stderr.isEmpty {
            lines.append("stderr \(stderr)")
        }
        return lines
    }
}

/// The dry run an Undo must show before it may apply.
///
/// TWO CALLS, ALWAYS. `previewHash` covers the outputs' CURRENT bytes, so an edit
/// that lands between the preview and the confirm invalidates the confirm rather
/// than silently deleting the edit. This mirrors the held-groups enroll gate.
struct MergeRevertPreview: Sendable, Equatable {
    let actionId: String
    let previewHash: String
    let outputs: [String]
    let editedOutputs: [String]
    let missingOutputs: [String]
    /// Set only by revert-all, which previews every applied action at once.
    let actions: [String]

    var isAll: Bool { actionId.isEmpty }

    /// What Undo is about to do, in files rather than ids.
    var summary: String {
        if isAll {
            return actions.count == 1
                ? "Undo 1 merge."
                : "Undo \(actions.count) merges."
        }
        return outputs.count == 1 ? "Removes 1 merged record." : "Removes \(outputs.count) merged records."
    }

    /// The warning that earns the second click, or nil when there is nothing to warn about.
    var caution: String? {
        var notes: [String] = []
        if !editedOutputs.isEmpty {
            notes.append(editedOutputs.count == 1
                ? "1 record changed since COS wrote it and is copied aside, not lost."
                : "\(editedOutputs.count) records changed since COS wrote them and are copied aside, not lost.")
        }
        if !missingOutputs.isEmpty {
            notes.append(missingOutputs.count == 1 ? "1 record is already gone." : "\(missingOutputs.count) records are already gone.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    init?(_ details: [String: JSONValue], actionId: String) {
        guard let hash = details["previewHash"]?.string, !hash.isEmpty else { return nil }
        self.actionId = actionId
        previewHash = hash
        outputs = details["outputs"]?.array?.compactMap(\.string) ?? []
        editedOutputs = details["editedOutputs"]?.array?.compactMap(\.string) ?? []
        missingOutputs = details["missingOutputs"]?.array?.compactMap(\.string) ?? []
        actions = details["actions"]?.array?.compactMap(\.string) ?? []
    }
}

/// Mode, first-run progress, counts, and the one disagreement a person cannot see
/// for themselves.
struct MeetingEngineStatus: Sendable, Equatable {
    var routeAbsent = false
    /// NIL UNTIL THE SERVER SAYS. A failed status load used to leave the default
    /// `.imports` in place, so a pipeline Mac in advise mode rendered the imports
    /// surface: "Merge", on a screen where agreeing writes nothing.
    var mode: MeetingEngineMode?
    var isPipelineMac = false
    var running = false
    /// What `sync_meetings.py --merge-engine-status` answered, or nil when it
    /// could not be asked. NOT KNOWN IS NOT DISAGREES.
    var pipelineSeesMode: String?
    var pipelineSeesActive = false
    var mismatch = false
    /// Advise mode with merges still applied. THE EXPECTED STATE AFTER A
    /// ROLLBACK, not a disagreement: `merge_engine_active()` stays true while any
    /// applied action exists, precisely so the old blend does not restart over
    /// merged scribes. A FLAG, not a count: the server reports the state, not how
    /// many (`mergesRemainApplied: true`, docs/meeting-merge-contract.md).
    var mergesRemainApplied = false
    /// What kind of Mac the server has OBSERVED this to be, what it had on
    /// record, and whether those differ. An OBJECT on the wire
    /// (`{ observed, recorded?, changed }`), and absent on a server without it.
    var macClassObserved = ""
    var macClassRecorded = ""
    var macClassChanged = false
    /// Why the last run did nothing, when it did nothing.
    var lastRunSkippedReason = ""
    var auto = 0
    var suggested = 0
    var reverted = 0
    var pending = 0
    /// SEPARATE FROM `pending` on purpose. An undo that cannot finish is the
    /// state a mode change is refused on, and folding it into `pending` hid it.
    var revertPending = 0
    var failed = 0
    var firstRunScanned = 0
    var firstRunAuto = 0
    var firstRunWouldMerge = 0
    var firstRunSuggested = 0
    var firstRunAlreadyMerged = 0
    var firstRunCompleted = false
    var lastRunAt = ""
    var lastRunTrigger = ""

    /// True while the one-per-install first run is still going.
    var firstRunInProgress: Bool { firstRunScanned > 0 && !firstRunCompleted }

    /// False until a status load succeeds. Everything that depends on the mode
    /// waits on this rather than acting on a default.
    var modeKnown: Bool { mode != nil }

    /// `counts.applied`: every action in the `applied` state, auto or
    /// accepted_suggestion, and NEVER `legacy_applied` (a merge the pipeline made
    /// itself, which COS does not undo). It is exactly the set Undo all removes:
    /// the server pins revert-all's dry-run `actions.length` to this count. Nil
    /// on a server that does not send it, which is not the same as zero.
    var appliedActions: Int?

    /// Merges COS made and has not undone, as the ENGINE counts them.
    ///
    /// `counts.applied` IS THE WHOLE ANSWER when the server sends it. 0.5.230
    /// summed `auto + suggested - reverted`, and `counts.suggested` is the number
    /// of OPEN suggestions: things nobody has answered, which are not merges and
    /// have nothing to undo. A fresh Mac with 21 suggestions and no applied
    /// action offered "Undo all merges" and then previewed "Undo 0 merges."
    /// (QA round 2 blocker 5). A server with no `applied` leaves `auto`, the
    /// nearest count it has. AN OPEN SUGGESTION NEVER ENTERS THIS NUMBER.
    var appliedMergeCount: Int { max(appliedActions ?? auto, 0) }

    var modeLine: String {
        if routeAbsent { return "Needs COS server 6.47.0" }
        switch mode {
        case .imports: return "COS merges the meetings it imports"
        case .advise: return "Suggesting only. COS does not change your pipeline's files."
        case .apply: return "Merging into your meetings, archived and revertible"
        case nil: return "COS could not say how it is merging right now."
        }
    }

    /// The warning the status row must carry, or nil.
    ///
    /// A MISMATCH IS THE ONE THING A PERSON CANNOT SEE. The server acting on apply
    /// while the pipeline on the same Mac still believes it owns the blend means
    /// two writers on one file. The sentence NAMES BOTH SIDES, because "still
    /// reads advise" without saying what the server reads describes half of a
    /// disagreement.
    var mismatchWarning: String? {
        guard mismatch else { return nil }
        let seen = (pipelineSeesMode?.isEmpty == false) ? pipelineSeesMode! : "something else"
        let here = mode?.rawValue ?? "an unknown mode"
        return "COS's server is on \(here) and your COS pipeline reads \(seen). "
            + "Until both agree, leave the mode where it is, run a meeting sync, then refresh this."
    }

    /// Applied merges under advise mode. NOT A MISMATCH: this is what a rollback
    /// to advise looks like, and the merges stay until someone undoes them.
    var mergesRemainAppliedLine: String? {
        guard mergesRemainApplied, mode == .advise else { return nil }
        return "Merges COS already made stay in your meetings tree. Suggesting only does not undo them, "
            + "and your pipeline leaves them alone while they are there."
    }

    /// The one alarm on this row. A Mac that changed class changed which writer
    /// owns the blend, and nothing else on screen says so.
    var macClassAlarm: String? {
        guard macClassChanged else { return nil }
        let now = Self.macClassLabel(macClassObserved) ?? "a different kind of Mac"
        let was = Self.macClassLabel(macClassRecorded)
        let head = was == nil
            ? "COS now sees this Mac as \(now)."
            : "COS saw this Mac as \(was!) and now sees it as \(now)."
        return head + " How meetings are merged here has changed. Check the mode before the next sync."
    }

    /// `pipeline` or `standalone` on the wire. Anything else is passed through,
    /// and an empty one is nothing to say rather than a blank in a sentence.
    static func macClassLabel(_ raw: String) -> String? {
        switch raw {
        case "": nil
        case "pipeline": "a Mac with the COS pipeline"
        case "standalone": "a Mac with no COS pipeline"
        default: raw
        }
    }

    /// One sentence per reason the last run did nothing, so a quiet engine is
    /// legible rather than indistinguishable from a broken one. The five reasons
    /// are the server's (`lastRun.skippedReason`,
    /// docs/meeting-merge-contract.md); an unknown one is shown, never swallowed.
    var skippedReasonLine: String? {
        guard !lastRunSkippedReason.isEmpty else { return nil }
        switch lastRunSkippedReason {
        case "maintenance_deferred":
            return "Last run did nothing: COS Control was working on the server. COS tries again on its next pass."
        case "capture_active":
            return "Last run did nothing: a recording was going. COS waits rather than read a meeting mid-capture."
        case "inputs_unchanged":
            return "Last run found nothing new to look at."
        case "inputs_unreadable":
            return "Last run stopped: COS could not read some of your meeting files. Check Copy diagnostics on a failed merge."
        case "too_many_inputs":
            return "Last run stopped: more meetings changed at once than COS reads in one pass. It continues on its next pass."
        default:
            return "Last run did nothing: \(lastRunSkippedReason)."
        }
    }

    var firstRunLine: String? {
        guard firstRunScanned > 0 else { return nil }
        let head = firstRunCompleted ? "First look finished" : "First look running"
        var parts = ["\(head): \(firstRunScanned) recording\(firstRunScanned == 1 ? "" : "s") read"]
        if firstRunAuto > 0 { parts.append("\(firstRunAuto) merged") }
        if firstRunWouldMerge > 0 { parts.append("\(firstRunWouldMerge) would merge") }
        if firstRunSuggested > 0 { parts.append("\(firstRunSuggested) to decide") }
        if firstRunAlreadyMerged > 0 { parts.append("\(firstRunAlreadyMerged) already merged") }
        return parts.joined(separator: " · ")
    }

    var lastRunLine: String? {
        guard !lastRunAt.isEmpty else { return nil }
        return lastRunTrigger.isEmpty ? "Last run \(lastRunAt)" : "Last run \(lastRunAt) · \(lastRunTrigger)"
    }

    init() {}

    init(_ details: [String: JSONValue]) {
        routeAbsent = MergeRouteState(details["routeState"]?.string) == .routeAbsent
        // NO DEFAULT. A body with no mode leaves it unknown, and the pane says so.
        mode = MeetingEngineMode(rawValue: details["mode"]?.string ?? "")
        isPipelineMac = details["isPipelineMac"]?.bool ?? false
        running = details["running"]?.bool ?? false
        // `pipelineSees` is null when the pipeline could not be asked, and both
        // flags stay false: NOT KNOWN IS NOT DISAGREES.
        if let sees = details["pipelineSees"]?.object {
            pipelineSeesMode = sees["mode"]?.string
            pipelineSeesActive = sees["active"]?.bool ?? false
        }
        mismatch = details["mismatch"]?.bool ?? false
        mergesRemainApplied = details["mergesRemainApplied"]?.bool ?? false
        // AN OBJECT, and absent on a 6.47.0 server without it. Decoding it as a
        // string left the observed class empty and the alarm nameless.
        if let macClass = details["macClass"]?.object {
            macClassObserved = macClass["observed"]?.string ?? ""
            macClassRecorded = macClass["recorded"]?.string ?? ""
            macClassChanged = macClass["changed"]?.bool ?? false
        }
        let counts = details["counts"]?.object
        auto = counts?["auto"]?.int ?? 0
        suggested = counts?["suggested"]?.int ?? 0
        reverted = counts?["reverted"]?.int ?? 0
        pending = counts?["pending"]?.int ?? 0
        revertPending = counts?["revertPending"]?.int ?? 0
        failed = counts?["failed"]?.int ?? 0
        // NOT DEFAULTED: an absent `applied` is an older server, and zero would
        // hide its `auto` count.
        appliedActions = counts?["applied"]?.int
        if let first = details["firstRun"]?.object {
            firstRunScanned = first["scanned"]?.int ?? 0
            firstRunAuto = first["auto"]?.int ?? 0
            firstRunWouldMerge = first["wouldMerge"]?.int ?? 0
            firstRunSuggested = first["suggested"]?.int ?? 0
            firstRunAlreadyMerged = first["alreadyMerged"]?.int ?? 0
            firstRunCompleted = !(first["completedAt"]?.string ?? "").isEmpty
        }
        if let last = details["lastRun"]?.object {
            lastRunAt = last["at"]?.string ?? ""
            lastRunTrigger = last["trigger"]?.string ?? ""
            lastRunSkippedReason = last["skippedReason"]?.string ?? ""
        }
    }
}


struct WorkYourMove: Identifiable, Sendable {
    let id: String
    let workID: String
    let title: String
    let kind: String
    let action: String
    let sessionID: String?
    init?(_ value: JSONValue) {
        guard let row = value.object, let id = row["id"]?.string, let work = row["workId"]?.string,
              let kind = row["kind"]?.string, ["question", "qa", "unknown"].contains(kind),
              let action = row["action"]?.string else { return nil }
        self.id = id; workID = work; title = row["title"]?.string ?? "Work item"; self.kind = kind; self.action = action
        sessionID = row["activity"]?.object?["sessionId"]?.string
    }
    var actionTitle: String { action == "answer" ? "Answer" : action == "review" ? "Review" : action == "startFresh" ? "Start fresh" : "Check session" }
}

/// One small decision group. Self-captures lead; dates come from each card.
struct WorkSortGroup: Identifiable {
    let id: String
    let title: String
    var items: [WorkIntakeItem] = []
    var cards: [TaskRow] = []
    var date: String = ""
    static func mentioned(_ tasks: [TaskRow], catchUp: Bool, domain: String?, now: Date = Date()) -> [TaskRow] {
        let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"
        let cutoff = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: now))!
        return tasks.filter { row in
            guard row.workStage == "mentioned", !row.checked, domain == nil || row.domain == domain else { return false }
            let fresh = (format.date(from: row.createdAt).map { $0 >= cutoff } ?? false) || row.priority == "urgent"
            return fresh != catchUp
        }
    }
    static func groups(snapshot: WorkIntakeSnapshot, cards: [TaskRow]) -> [WorkSortGroup] {
        var groups: [String: WorkSortGroup] = [:]
        for item in snapshot.items {
            let key = item.meeting.recordId
            var group = groups[key] ?? WorkSortGroup(id: key, title: item.meeting.title, date: String(item.meeting.filename.prefix(10)))
            group.items.append(item); groups[key] = group
        }
        for card in cards {
            let ref = card.meetingRefs.first
            let key = ref?.recordId ?? "self-captured"
            var group = groups[key] ?? WorkSortGroup(id: key, title: ref?.title ?? "Your captures", date: card.createdAt)
            group.cards.append(card); groups[key] = group
        }
        return groups.values.sorted { a, b in
            if (a.id == "self-captured") != (b.id == "self-captured") { return a.id == "self-captured" }
            return a.date == b.date ? a.id < b.id : a.date > b.date
        }
    }
}

// MARK: - Activity home: Needs you, live cards, desks (0.5.259)

/// 0.5.259 (Miles, 2026-10-06; boards 1 to 3 of MOCK_activity_work_search_2026-10-06): the Activity home says what is true
/// now. A Needs you line above the cards, a lead line on every card, and a desk per session on the Sessions card. Pure, and
/// reads only what Control already holds, so Tests/ActivityHomeChecks.swift executes every rule. A source Control has not
/// loaded is nil here, and its item or line is left out: never a made-up 0.
enum ActivityHome {
    /// Desks drawn before "+N", at most.
    static let deskCap = 12
    /// A desk's size, the gap between desks, and the room "+N" takes: the strip is one row (deskFit).
    static let deskWidth: CGFloat = 26
    static let deskHeight: CGFloat = 22
    static let deskGap: CGFloat = 5
    static let deskMoreWidth: CGFloat = 30
    /// Session items the Needs you line draws before "+N sessions".
    static let sessionCap = 3
    /// What a single waiting session asked, shown in the line up to this many characters.
    static let detailLimit = 60
    static let quietLine = "Nothing is waiting on you."

    // MARK: Desks

    enum DeskState: String, Sendable {
        case asked, maybe, working, finished

        var label: String {
            switch self {
            case .asked: "asked you something"
            case .maybe: "quiet, may need you"
            case .working: "working"
            case .finished: "finished today"
            }
        }
        /// Strip order: what waits on Miles first, then work in flight, then today's finishes.
        var rank: Int {
            switch self {
            case .asked: 0
            case .maybe: 1
            case .working: 2
            case .finished: 3
            }
        }
        /// Only a working desk glows, and never under Reduce Motion: there it is drawn still.
        func glows(reduceMotion: Bool) -> Bool { self == .working && !reduceMotion }
    }

    /// One session as the home reads it: the row whose state it shows, the row Sessions opens (the list's, which carries
    /// the full id), its state (nil: idle, not today), and whether the list holds it (the big number counts the list).
    struct Seat {
        let row: ClaudeSession
        let open: ClaudeSession
        let state: DeskState?
        let inList: Bool
        /// The row's last write, read once.
        let updated: Date?
    }

    struct Desk: Identifiable {
        let session: ClaudeSession
        let openRow: ClaudeSession
        let state: DeskState
        /// When it started waiting (asked), or its last write (every other state).
        let since: Date?
        var id: String { session.id }

        var stateLabel: String { state == .asked ? ActivityHome.askedWords(session) : state.label }
        /// "<title> · <state> · <age>".
        func help(now: Date) -> String {
            ([session.title, stateLabel] + [since.map { ActivityHome.age($0, now: now) }].compactMap { $0 }).joined(separator: " · ")
        }
    }

    /// A session's desk state. `live`: its state is current (it came from the live list, or there is no live list). A
    /// row the live list does not carry is not running or waiting any more, whatever its last snapshot said.
    ///
    /// Asked is a wait COS knows of (knownWait) or a failed turn. "Quiet, may need you" is a wait the helper only read
    /// from an open turn quiet for 15 minutes, which may be a permission prompt COS cannot see. Running is working: the
    /// helper counts a live subagent as activity, and with hooks the server sees every prompt, so COS adds no timer of
    /// its own (QA 2026-10-07: sessions busy with subagents read as quiet).
    static func deskState(_ session: ClaudeSession, live: Bool, now: Date, calendar: Calendar = .current) -> DeskState? {
        deskState(session, updated: session.updatedDate, live: live, now: now, calendar: calendar)
    }

    /// The same, with the session's last write already read (a seat reads it once: parsing it is the costly part).
    static func deskState(_ session: ClaudeSession, updated: Date?, live: Bool, now: Date, calendar: Calendar) -> DeskState? {
        guard !session.isKeepWarm else { return nil }
        if live {
            if session.state == "error" { return .asked }
            if session.state == "waiting" {
                if knownWait(session) { return .asked }
                // A run the COS server holds (a scheduled job, a Work New session) cannot stop on a prompt.
                return session.heldByServer ? .working : .maybe
            }
            if session.isPetWorking { return .working }
        }
        if let updated, calendar.isDate(updated, inSameDayAs: now) { return .finished }
        return nil
    }

    /// A wait COS knows of: the hooks or the registry said so (`stateSource`), the server named its kind, the registry
    /// said what it waits for, or the transcript holds a question still open.
    static func knownWait(_ session: ClaudeSession) -> Bool {
        session.stateSource == "hook" || session.stateSource == "registry" || !session.waitingKind.isEmpty
            || !session.waitingFor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.waitingOnUser
    }

    /// What a session waiting on Miles is doing, by the server's waiting kind (permission, question, plan, mcp_input).
    /// An unknown kind keeps the question words.
    static func askedWords(_ session: ClaudeSession) -> String {
        if session.state == "error" { return "stopped with an error" }
        switch session.waitingKind {
        case "permission": return "wants your permission"
        case "plan": return "has a plan to approve"
        case "mcp_input": return "needs your input"
        default: return "asked you a question"
        }
    }

    /// With one session waiting there is room for what it asked (its waiting detail, up to `detailLimit` characters):
    /// "asked: “Use the sandbox homepage or a new draft?”", "wants your permission: Bash git push". A plan (long), a
    /// failed turn or no detail keeps the plain words.
    static func askedDetail(_ session: ClaudeSession) -> String {
        let detail = clip(session.waitingDetail.trimmingCharacters(in: .whitespacesAndNewlines), detailLimit)
        guard session.state == "waiting", !detail.isEmpty, session.waitingKind != "plan" else { return askedWords(session) }
        switch session.waitingKind {
        case "permission": return "wants your permission: " + detail
        case "mcp_input": return "needs your input: " + detail
        default: return "asked: \u{201C}" + detail + "\u{201D}"
        }
    }

    /// The pet's live list (petSessions) when the pet is on, so the home and the pet never disagree; the Sessions list
    /// otherwise. Live rows are matched to list rows by `ClaudeSession.sameSession` (the live list may carry a short id).
    static func seats(list: [ClaudeSession], live: [ClaudeSession]?, now: Date, calendar: Calendar = .current) -> [Seat] {
        func seat(_ row: ClaudeSession, open: ClaudeSession, live: Bool, inList: Bool) -> Seat {
            let updated = stamp(row.updatedAt)
            return Seat(row: row, open: open, state: deskState(row, updated: updated, live: live, now: now, calendar: calendar),
                        inList: inList, updated: updated)
        }
        let real = list.filter { !$0.isKeepWarm }
        guard let live else {
            return real.map { seat($0, open: $0, live: true, inList: true) }
        }
        var seats: [Seat] = []
        var taken = Set<String>()
        var liveSeen: [ClaudeSession] = []
        for row in live where !row.isKeepWarm {
            guard !liveSeen.contains(where: { ClaudeSession.sameSession($0.id, row.id) }) else { continue }
            liveSeen.append(row)
            let listed = real.first { !taken.contains($0.id) && ClaudeSession.sameSession($0.id, row.id) }
            if let listed { taken.insert(listed.id) }
            seats.append(seat(row, open: listed ?? row, live: true, inList: listed != nil))
        }
        for row in real where !taken.contains(row.id) {
            seats.append(seat(row, open: row, live: false, inList: true))
        }
        return seats
    }

    /// Running, waiting and finished-today sessions, never a scheduled job (Sessions lists those apart). What waits on
    /// Miles leads, oldest first; then working and finished, newest first.
    static func desks(_ seats: [Seat]) -> [Desk] {
        seats.compactMap { seat -> Desk? in
            guard let state = seat.state, !seat.row.isScheduledJob else { return nil }
            let since = state == .asked ? (stamp(seat.row.stateSince) ?? seat.updated) : seat.updated
            return Desk(session: seat.row, openRow: seat.open, state: state, since: since)
        }.sorted { a, b in
            if a.state.rank != b.state.rank { return a.state.rank < b.state.rank }
            let x = a.since ?? .distantPast, y = b.since ?? .distantPast
            if x != y { return a.state.rank <= DeskState.maybe.rank ? x < y : x > y }
            return a.id < b.id
        }
    }

    /// The desk strip is one row: as many desks as the card's width holds (`deskCap` at most), then "+N" for the rest,
    /// so the card is the same height whatever the count.
    static func deskFit(count: Int, width: CGFloat) -> (shown: Int, more: Int) {
        func span(_ n: Int, more: Bool) -> CGFloat {
            CGFloat(n) * deskWidth + CGFloat(max(0, n - 1)) * deskGap + (more ? (n > 0 ? deskGap : 0) + deskMoreWidth : 0)
        }
        if count <= deskCap, span(count, more: false) <= width { return (count, 0) }
        var shown = min(count, deskCap)
        while shown > 0, span(shown, more: true) > width { shown -= 1 }
        return (shown, count - shown)
    }

    struct SessionTally: Equatable {
        var onDisk = 0, working = 0, asked = 0, finished = 0, idle = 0
    }

    /// The Sessions card's numbers, as its desks show them: a quiet desk is neither working nor waiting (the Needs you
    /// line says it may need Miles). Idle: listed sessions with nothing today.
    static func tally(_ seats: [Seat]) -> SessionTally {
        var tally = SessionTally()
        tally.onDisk = seats.filter(\.inList).count
        for desk in desks(seats) {
            switch desk.state {
            case .asked: tally.asked += 1
            case .working: tally.working += 1
            case .maybe: break
            case .finished: tally.finished += 1
            }
        }
        tally.idle = seats.filter { $0.inList && $0.state == nil }.count
        return tally
    }

    // MARK: Needs you

    /// Voices still to name across the recent saved meetings (the Speakers meetings to review).
    struct VoicesToName {
        let voices: Int
        let meetings: Int
        let newest: ReviewableMeeting?
    }

    /// nil until Speakers has loaded its meetings. Only a meeting the server reports with unnamed voices counts; a meeting
    /// from an older server that does not say is never counted as zero or as waiting.
    static func voicesToName(_ meetings: [ReviewableMeeting], tag: (ReviewableMeeting) -> MeetingVoiceTag?) -> VoicesToName? {
        guard !meetings.isEmpty else { return nil }
        var voices = 0
        var waiting: [ReviewableMeeting] = []
        for meeting in meetings {
            if case .needsNames(let count) = tag(meeting), count > 0 { voices += count; waiting.append(meeting) }
        }
        let newest = waiting.max { ($0.date, $0.time, $1.title) < ($1.date, $1.time, $0.title) }
        return VoicesToName(voices: voices, meetings: waiting.count, newest: newest)
    }

    struct Need: Identifiable {
        enum Kind: String {
            case asked, maybe, voices, memories, work

            /// The line's order: a session that asked (or failed), then one only quiet, then the backlog (voices,
            /// memories, Work), which the cards below also show.
            var order: Int {
                switch self {
                case .asked: 0
                case .maybe: 1
                case .voices: 2
                case .memories: 3
                case .work: 4
                }
            }
        }
        let kind: Kind
        let what: String
        let why: String
        let since: Date?
        var desk: Desk? = nil
        var meeting: ReviewableMeeting? = nil
        var id: String { kind.rawValue + ":" + (desk?.id ?? meeting?.sessionId ?? "") }
        /// Filled dot: a fact. Open dot: "may need you", never a fact.
        var isFact: Bool { kind != .maybe }
        var isSession: Bool { kind == .asked || kind == .maybe }
        func age(now: Date) -> String? { isSession ? since.map { ActivityHome.age($0, now: now) } : nil }
    }

    struct NeedSources {
        /// nil: no session list yet.
        var desks: [Desk]?
        /// nil: Speakers has not loaded its meetings.
        var voices: VoicesToName?
        /// nil: a server that does not report the count.
        var memoriesToReview: Int?
        var memoriesOldest: Date?
        /// nil: Work has not loaded, or is off.
        var workAttention: Int?
    }

    static func needs(_ sources: NeedSources, calendar: Calendar = .current) -> [Need] {
        var out: [Need] = []
        let waiting = (sources.desks ?? []).filter { $0.state == .asked || $0.state == .maybe }
        for desk in waiting {
            switch desk.state {
            case .asked:
                out.append(Need(kind: .asked, what: desk.session.title,
                                why: waiting.count == 1 ? askedDetail(desk.session) : askedWords(desk.session),
                                since: desk.since, desk: desk))
            case .maybe:
                out.append(Need(kind: .maybe, what: desk.session.title, why: "quiet, may need you", since: desk.since, desk: desk))
            case .working, .finished:
                break
            }
        }
        if let voices = sources.voices, voices.voices > 0 {
            out.append(Need(kind: .voices, what: voices.voices == 1 ? "1 voice to name" : "\(voices.voices) voices to name",
                            why: voices.newest?.title ?? "", since: voices.newest.flatMap { meetingDate($0, calendar: calendar) },
                            meeting: voices.newest))
        }
        if let count = sources.memoriesToReview, count > 0 {
            out.append(Need(kind: .memories, what: count == 1 ? "1 memory" : "\(count) memories", why: "to review", since: sources.memoriesOldest))
        }
        if let count = sources.workAttention, count > 0 {
            out.append(Need(kind: .work, what: count == 1 ? "1 work item" : "\(count) work items",
                            why: count == 1 ? "needs attention" : "need attention", since: nil))
        }
        return ordered(out)
    }

    /// What blocks a session comes first: a question or a failed turn, then a session that is only quiet, oldest first
    /// within each. Then the backlog in a fixed order: voices, memories, Work. Next ⌘] follows this order, so it opens a
    /// blocked session before any backlog. An item with no date follows the dated ones of its kind, in the order it was
    /// listed: it is never placed by a date it does not have.
    static func ordered(_ items: [Need]) -> [Need] {
        items.enumerated().sorted { a, b in
            let x = a.element.kind.order, y = b.element.kind.order
            if x != y { return x < y }
            switch (a.element.since, b.element.since) {
            case let (p?, q?) where p != q: return p < q
            case (.some, .none): return true
            case (.none, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// The line in two parts: session items in full (mark, title, why, age), then the backlog as one short segment of
    /// counts ("Also · 1 voice to name · 3 memories · 7 work items"). The cards below already name the meeting and say
    /// what each count means, so the segment carries neither. "Also" only follows session items.
    struct LineParts {
        let sessions: [Need]
        let backlog: [Need]
        /// The session items drawn in full: `sessionCap` at most, so a run of waiting sessions never pushes the cards
        /// down the window.
        var shown: [Need] { Array(sessions.prefix(sessionCap)) }
        /// The rest, behind "+N sessions", which opens Sessions.
        var moreSessions: Int { max(0, sessions.count - sessionCap) }
        var alsoPrefix: Bool { !sessions.isEmpty && !backlog.isEmpty }
    }

    static func parts(_ items: [Need]) -> LineParts {
        LineParts(sessions: items.filter(\.isSession), backlog: items.filter { !$0.isSession })
    }

    static func moreSessionsLabel(_ count: Int) -> String { count == 1 ? "+1 session" : "+\(count) sessions" }

    /// The backlog segment as drawn, piece by piece: "Also" after session items, a dot between parts, and each count
    /// alone ("1 voice to name", "3 memories", "7 work items"), never a meeting name or a description.
    enum BacklogPiece: Identifiable {
        case also
        case dot(Int)
        case count(Need)

        var id: String {
            switch self {
            case .also: "also"
            case .dot(let index): "dot\(index)"
            case .count(let need): need.id
            }
        }

        var text: String {
            switch self {
            case .also: "Also"
            case .dot: "·"
            case .count(let need): need.what
            }
        }
    }

    static func backlogPieces(_ parts: LineParts) -> [BacklogPiece] {
        var pieces: [BacklogPiece] = parts.alsoPrefix ? [.also] : []
        for (index, need) in parts.backlog.enumerated() {
            if !pieces.isEmpty { pieces.append(.dot(index)) }
            pieces.append(.count(need))
        }
        return pieces
    }

    /// The sources the line reads. Work counts only when Work is connected; memories only on a server that reports
    /// the review count.
    enum Source: String, CaseIterable { case sessions, voices, memories, work }
    enum SourceState: Equatable { case pending, answered, failed, off }

    /// A source's state for the quiet line: off when it does not apply; failed when its last load failed, even with
    /// older rows in hand; answered when its load came back or its rows are in hand; pending otherwise.
    static func sourceState(enabled: Bool, loaded: SourceState?, hasData: Bool) -> SourceState {
        guard enabled else { return .off }
        switch loaded {
        case .failed: return .failed
        case .off: return .off
        case .answered: return .answered
        case .pending, nil: return hasData ? .answered : .pending
        }
    }

    enum Line: Equatable { case hidden, quiet, items }
    /// Items when anything waits. The one quiet line only once every source that applies has answered: "Nothing is
    /// waiting on you" is a claim, so it is not made while a source is still loading, or after one failed.
    static func line(_ items: [Need], states: [Source: SourceState]) -> Line {
        if !items.isEmpty { return .items }
        let counted = Source.allCases.map { states[$0] ?? .pending }.filter { $0 != .off }
        return !counted.isEmpty && counted.allSatisfy { $0 == .answered } ? .quiet : .hidden
    }

    /// Where an item of the line sits: its row, its x and the width it is given.
    struct FlowPlace: Equatable {
        let row: Int
        let x: CGFloat
        let width: CGFloat
    }

    /// A session item that does not quite fit the rest of a row may give up to a quarter of its width (its title
    /// truncates) rather than start a new row. Anything less wraps.
    static let flowMinShare: CGFloat = 0.75

    /// The Needs you line's rows. Each item keeps its own width where it fits; one that may shrink (`shrinks`: a session
    /// item, never the backlog segment) takes the rest of the row when that keeps at least `flowMinShare` of it; otherwise
    /// it starts the next row. An item wider than a whole row gets the row.
    static func flow(ideal: [CGFloat], shrinks: [Bool], width: CGFloat, spacing: CGFloat) -> [FlowPlace] {
        var places: [FlowPlace] = []
        var row = 0
        var x: CGFloat = 0
        for (index, want) in ideal.enumerated() {
            let room = width - x
            if x == 0 || want <= room {
                let given = min(want, width)
                places.append(FlowPlace(row: row, x: x, width: given))
                x += given + spacing
            } else if index < shrinks.count, shrinks[index], room >= want * flowMinShare {
                places.append(FlowPlace(row: row, x: x, width: room))
                x = width + spacing
            } else {
                row += 1
                let given = min(want, width)
                places.append(FlowPlace(row: row, x: 0, width: given))
                x = given + spacing
            }
        }
        return places
    }

    /// The item Next ⌘] opened last, and where it stood.
    struct NextCursor: Equatable {
        let id: String
        let index: Int
    }

    /// What Next ⌘] opens: the first item in the line's order, then the one after the item it opened last, wrapping.
    /// When that item has gone (answered, named, reviewed), the one now in its place is next.
    static func nextTarget(_ items: [Need], after cursor: NextCursor?) -> Need? {
        guard !items.isEmpty else { return nil }
        guard let cursor else { return items.first }
        if let index = items.firstIndex(where: { $0.id == cursor.id }) { return items[(index + 1) % items.count] }
        return cursor.index < items.count ? items[cursor.index] : items.first
    }
    /// With one item the button reads "Open".
    static func nextLabel(_ items: [Need]) -> String { items.count == 1 ? "Open" : "Next" }

    // MARK: Card bodies

    struct Span: Equatable {
        let text: String
        /// Amber: it waits on Miles.
        var waits = false
    }

    struct CardBody: Equatable {
        /// The big number; nil until its source has loaded (drawn as nothing, never a placeholder).
        var count: String?
        var lead: [Span] = []
        var subs: [String] = []
        /// What the big number counts.
        var footer: String?
        var leadText: String { lead.map(\.text).joined() }
    }

    struct CardInputs {
        var now = Date()
        var calendar = Calendar.current
        var clock = ClockStyle.twelveHour
        var messages: [GlassesTurn] = []
        var messagesStatus = RecentGlassesStatus.idle
        var enrolled: Int?
        var voices: VoicesToName?
        var monthCount: Int?
        var monthTitle = ""
        var storedMeetings: Int?
        var recentMeetings: [ReviewableMeeting] = []
        var toReview: Int?
        var oldestReview: Date?
        /// nil: memory is not set up, or the status has not said.
        var memories: Int?
        /// The status said memory is not set up (false, never nil).
        var memorySetupNeeded = false
        /// nil: threads are not set up, or the status has not said.
        var threads: Int?
        var threadSetupNeeded = false
        var activeThreads = 0
        var latestThread: String?
        /// nil: no session list yet.
        var sessions: SessionTally?
        /// nil: Work has not loaded.
        var workAttention: Int?
        var workInProgress = 0
        /// nil: Intake has not loaded (or the server is older than 6.57.0).
        var newToSort: Int?
        var tasks: [TaskRow]?
        /// nil: no dictations kept on this Mac.
        var dictations: Int?
        var dictationSuggestions = 0
        var lastDictation: Date?
    }

    /// The Activity cards, by the same raw values as ActivitySection (Tests/activity-home-pins.py pins the two lists
    /// equal), so these rules compile with the models alone. Eight show: Work, or Tasks when Work is off, and Dictation.
    enum Card: String, CaseIterable { case messages, speakers, meetings, memories, threads, sessions, tasks, work, dictation }

    static func card(_ section: Card, _ input: CardInputs) -> CardBody {
        func n(_ value: Int) -> String { value.formatted(.number) }
        var body = CardBody()
        switch section {
        case .messages:
            let turns = input.messages.filter { ($0.timestamp ?? 0) > 0 }
            if input.messagesStatus == .ready, !input.messages.isEmpty {
                body.count = n(input.messages.count)
                body.footer = "\(n(input.messages.count)) recent"
                if let last = turns.max(by: { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }) {
                    body.lead = [Span(text: "Last from the glasses, " + when(Date(timeIntervalSince1970: last.timestamp ?? 0), now: input.now, calendar: input.calendar))]
                    let query = last.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !query.isEmpty { body.subs = ["\u{201C}" + clip(query, 90) + "\u{201D}"] }
                }
            } else if input.messagesStatus == .empty {
                body.lead = [Span(text: "No messages today")]
            }
        case .speakers:
            if let enrolled = input.enrolled {
                body.count = n(enrolled)
                body.footer = "\(n(enrolled)) enrolled"
            }
            if let voices = input.voices, voices.voices > 0 {
                body.lead = [Span(text: voices.voices == 1 ? "1 voice to name" : "\(n(voices.voices)) voices to name", waits: true)]
                if let newest = voices.newest { body.subs.append(newest.title) }
                if voices.meetings > 1 { body.subs.append("In \(voices.meetings) meetings") }
            }
        case .meetings:
            if let month = input.monthCount {
                body.count = n(month)
                body.footer = "\(n(month)) in \(input.monthTitle)"
            } else if let stored = input.storedMeetings, stored > 0 {
                body.count = n(stored)
                body.footer = "\(n(stored)) stored"
            }
            let dated = input.recentMeetings.filter { !$0.date.isEmpty }
            if let latest = dated.max(by: { ($0.date, $0.time) < ($1.date, $1.time) }) {
                let today = dayKey(input.now, calendar: input.calendar)
                let todays = dated.filter { $0.date == today }.count
                let time = latest.time.isEmpty ? "" : input.clock.format(latest.time)
                if todays > 0 {
                    body.lead = [Span(text: "\(todays) today" + (time.isEmpty ? "" : " · latest \(time)"))]
                } else if let day = meetingDate(latest, calendar: input.calendar) {
                    body.lead = [Span(text: "Latest " + dayWord(day, now: input.now, calendar: input.calendar) + (time.isEmpty ? "" : " \(time)"))]
                }
                body.subs = [latest.title]
            }
        case .memories:
            // The big number is the memories kept, as before 0.5.259. The lead says what waits to be reviewed.
            if let memories = input.memories {
                body.count = n(memories)
                body.footer = "\(n(memories)) kept"
            }
            if let review = input.toReview {
                if review > 0 {
                    body.lead = [Span(text: "\(n(review)) to review", waits: true)]
                    if let oldest = input.oldestReview {
                        body.subs = ["Oldest waiting since " + dayWord(oldest, now: input.now, calendar: input.calendar)]
                    }
                } else {
                    body.lead = [Span(text: "Nothing to review")]
                }
            } else if input.memories == nil, input.memorySetupNeeded {
                body.lead = [Span(text: "Setup needed")]
            }
        case .threads:
            if let threads = input.threads {
                body.count = n(threads)
                body.footer = "\(n(threads)) tracked"
                if input.activeThreads > 0 { body.lead = [Span(text: "\(n(input.activeThreads)) active")] }
                if let latest = input.latestThread { body.subs = ["Latest: " + latest] }
            } else if input.threadSetupNeeded {
                body.lead = [Span(text: "Setup needed")]
            }
        case .sessions:
            if let tally = input.sessions {
                body.count = n(tally.onDisk)
                body.footer = "\(n(tally.onDisk)) on disk" + (tally.idle > 0 ? " · \(n(tally.idle)) idle" : "")
                if tally.working == 0 && tally.asked == 0 {
                    body.lead = [Span(text: "None running")]
                } else {
                    if tally.working > 0 { body.lead.append(Span(text: "\(n(tally.working)) working")) }
                    if tally.asked > 0 {
                        if !body.lead.isEmpty { body.lead.append(Span(text: " · ")) }
                        body.lead.append(Span(text: "\(n(tally.asked)) waiting on you", waits: true))
                    }
                }
                if tally.finished > 0 { body.subs = ["\(n(tally.finished)) finished today"] }
            }
        case .work:
            if let attention = input.workAttention {
                body.count = n(attention)
                body.footer = attention == 1 ? "1 needs attention" : "\(n(attention)) need attention"
                if let fresh = input.newToSort, fresh > 0 {
                    body.lead = [Span(text: "\(n(fresh)) new to sort", waits: true)]
                    body.subs = ["\(n(input.workInProgress)) in progress"]
                } else if input.workInProgress > 0 {
                    body.lead = [Span(text: "\(n(input.workInProgress)) in progress")]
                }
            }
        case .tasks:
            if let tasks = input.tasks, !tasks.isEmpty {
                body.count = n(tasks.count)
                body.footer = "\(n(tasks.count)) open"
                let flagged = tasks.filter { $0.missed == true || $0.failed == true }.count
                if flagged > 0 { body.lead = [Span(text: flagged == 1 ? "1 needs attention" : "\(n(flagged)) need attention", waits: true)] }
            }
        case .dictation:
            if let dictations = input.dictations {
                body.count = n(dictations)
                body.footer = dictations == 1 ? "1 kept" : "\(n(dictations)) kept"
            }
            if input.dictationSuggestions > 0 {
                let s = input.dictationSuggestions
                body.lead = [Span(text: s == 1 ? "1 suggested correction" : "\(n(s)) suggested corrections", waits: true)]
            } else if let last = input.lastDictation {
                body.lead = [Span(text: "Last dictated " + when(last, now: input.now, calendar: input.calendar))]
            }
        }
        return body
    }

    // MARK: Words and dates

    /// "now", "12 min", "3 h", "2 d".
    static func age(_ since: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86_400)) d"
    }

    /// "today", "yesterday", a weekday within the week ("Sunday"), else "Oct 1".
    static func dayWord(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if (2...6).contains(days) { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// "today 9:00 AM", "Mon 9:00 AM", "Oct 1, 9:00 AM".
    static func when(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let day = dayWord(date, now: now, calendar: calendar)
        if day == "today" || day == "yesterday" { return day + " " + time }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if (2...6).contains(days) { return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time }
        return day + ", " + time
    }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// A saved meeting's start, from its `yyyy-MM-dd` day and `HH:mm` time (midnight when the time is missing).
    static func meetingDate(_ meeting: ReviewableMeeting, calendar: Calendar = .current) -> Date? {
        let day = meeting.date.split(separator: "-").compactMap { Int($0) }
        guard day.count == 3 else { return nil }
        let clock = meeting.time.split(separator: ":").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: day[0], month: day[1], day: day[2],
                                                  hour: clock.count == 2 ? clock[0] : 0, minute: clock.count == 2 ? clock[1] : 0))
    }

    /// An ISO 8601 stamp, with or without fractional seconds. Date.ISO8601FormatStyle, which reads one in about 1 µs:
    /// ClaudeSession.updatedDate builds two formatters per read (about 0.2 ms), and the home reads every session's stamp
    /// each time it draws.
    static func stamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed))
            ?? (try? Date.ISO8601FormatStyle().parse(trimmed))
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }
}

// MARK: - Status refresh cadence (0.5.337, performance audit W5)

/// The status refresh spawned 4 to 5 helpers every 12 s whatever was on screen, and republished unchanged values (Activity
/// body rebuilds 22 to 58 a minute for hours). Now: every 12 s while a Control surface is on screen or a meeting records;
/// every 60 s when nothing is on screen or the screen is locked or asleep. The loop still wakes every 12 s, so opening the
/// panel is read within one tick.
enum RefreshCadence {
    static let tick: TimeInterval = 12
    static let idle: TimeInterval = 60
    static func seconds(panelVisible: Bool, activityOnScreen: Bool, locked: Bool, recording: Bool) -> TimeInterval {
        if recording { return tick }
        if locked { return idle }
        return panelVisible || activityOnScreen ? tick : idle
    }
    /// A tick refreshes when the cadence has passed since the last refresh (a little early counts: ticks drift).
    static func due(last: Date?, now: Date, every seconds: TimeInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= seconds - 1
    }
    /// The extra reads (orphans, your move) are for what is on screen; a recording keeps them.
    static func readsExtras(panelVisible: Bool, activityOnScreen: Bool, recording: Bool) -> Bool { panelVisible || activityOnScreen || recording }
}

/// 0.5.337 (performance audit W4): the pet's animation pauses while nobody can see it.
enum PetPause {
    static func paused(occluded: Bool, locked: Bool, displayAsleep: Bool) -> Bool { occluded || locked || displayAsleep }
}

// MARK: - Work loop support (0.5.337, loop audit W1)

/// The shipped server has only the four Intake routes; the work-loop routes (seen, undo, expired, waiting, dropped, batch)
/// arrive with a newer server. The helper answers every 404 as `unsupported`; these are the rules Control reads it with.
enum WorkLoopSupport {
    static func unsupported(_ details: [String: JSONValue]) -> Bool { details["unsupported"]?.bool == true }
    /// Undo is offered only on a server that has the routes, and never after this server said undo is missing.
    static func undoOffered(available: Bool?, unsupported: Set<String>) -> Bool { available == true && !unsupported.contains("undo") }
    /// Said where Undo would be, on a server without it.
    static let undoMissing = "Undo needs a newer COS server. To change a card, open it in Work."
}

// MARK: - One Intake resolve's answer (0.5.337)

/// What one Intake resolve (`work-intake-resolve`) came back with. Only the server's own confirmation is `changed`; the
/// undo id is `<item id>:<resolution at>`, the batch id the server's `/api/work-intake/undo` takes for a single resolve, and
/// only when the server says it made this decision (a repeat on an item already decided the other way gives no undo, so
/// Undo can never reverse a different decision). A 404 on an older server (`unsupported`) changed nothing.
enum WorkIntakeResolveResult: Equatable {
    case changed(undo: String?)
    case refused(String, code: String)
    case busy

    init(details: [String: JSONValue], message: String, itemID: String, accept: Bool) {
        if details["unsupported"]?.bool == true { self = .refused(message, code: "unsupported"); return }
        let resolution = details["item"]?.object?["resolution"]?.object
        let at: String? = resolution?["at"]?.string
        let decided: String? = resolution?["action"]?.string
        let undo: String? = decided == (accept ? "accept" : "dismiss") ? at.map { itemID + ":" + $0 } : nil
        self = .changed(undo: undo)
    }
}

/// Today's Dismiss on "From today's meetings" (0.5.337, Miles 2026-10-22: some suggestions are not real tasks). Pure, so
/// Tests/ActivityTodayChecks executes every rule: a dismiss the server confirmed collapses its row to "Dismissed. Undo"
/// for `undoSeconds`, then the row leaves; a refusal keeps the row with the server's reason; Undo sends that row's own undo
/// id and only a confirmed undo removes the line (a failed one keeps it, with the reason, for another `undoSeconds`).
struct TodayDismissals: Equatable {
    static let undoSeconds: TimeInterval = 8

    struct Row: Equatable {
        let item: WorkIntakeItem
        /// The undo id the server gave (`<item id>:<at>`); nil: nothing to undo, so the line says only "Dismissed."
        let undo: String?
        var until: Date
        var undoing = false
        var undoError: String?
    }

    var rows: [String: Row] = [:]
    var dismissing: Set<String> = []
    var failures: [String: String] = [:]

    /// One dismiss starts: not one already in flight for this row, and not a row already collapsed.
    mutating func begin(_ id: String) -> Bool {
        guard !dismissing.contains(id), rows[id] == nil else { return false }
        dismissing.insert(id)
        failures[id] = nil
        return true
    }

    /// The resolve's answer. Only `changed` collapses the row.
    mutating func finish(_ item: WorkIntakeItem, result: WorkIntakeResolveResult, now: Date) {
        dismissing.remove(item.id)
        switch result {
        case .changed(let undo):
            rows[item.id] = Row(item: item, undo: undo, until: now.addingTimeInterval(Self.undoSeconds))
        case .refused(let reason, _):
            failures[item.id] = reason
        case .busy:
            break
        }
    }

    /// Undo starts: the row's own undo id, once.
    mutating func beginUndo(_ id: String) -> String? {
        guard var row = rows[id], !row.undoing, let undo = row.undo else { return nil }
        row.undoing = true
        row.undoError = nil
        rows[id] = row
        return undo
    }

    /// nil error: the server restored it, and the line goes (the item is open again in the next read).
    mutating func finishUndo(_ id: String, error: String?, now: Date) {
        guard var row = rows[id] else { return }
        guard let error else { rows[id] = nil; return }
        row.undoing = false
        row.undoError = error
        row.until = now.addingTimeInterval(Self.undoSeconds)
        rows[id] = row
    }

    /// The collapsed lines still showing: inside their window, or with an undo in flight.
    func live(now: Date) -> [Row] { rows.values.filter { $0.undoing || $0.until > now } }

    /// Drop the lines whose window has passed.
    mutating func expire(now: Date) { rows = rows.filter { $0.value.undoing || $0.value.until > now } }

    /// The ids ControllerModel keeps hidden after an undo: a single resolve's undo id (`<item id>:<at>`) gives its item
    /// back; a batch id (a UUID) names no item here.
    static func afterUndo(_ dismissed: Set<String>, batchId: String) -> Set<String> {
        dismissed.filter { !batchId.hasPrefix($0 + ":") }
    }
}

// MARK: - Activity Today home (plan v2, 2026-10-21)

/// The Activity window's Today home (PLAN_control_activity_home_v2_2026-10-21, direction A). Pure: every number the rail,
/// the Needs you header, the brief, the cards and the tabs show comes from one function here, so Tests/ActivityTodayChecks
/// executes each rule and pins that they agree. A source Control has not loaded is nil, never a made-up 0. Zero LLM: the
/// brief is fixed templates over these counts.
enum TodayHome {
    // MARK: Settings (UserDefaults keys; Settings > Activity)

    /// The integrated candidate's opt-in switch. Off: the stable 0.5.259 home and the top lens rail, unchanged.
    static let enabledKey = "activityTodayHomeEnabled"
    /// Quiet hours (Miles's default, 2026-10-21): after 6 PM and on weekends, fold Needs you below agent-blocking items.
    static let quietHoursKey = "activityTodayQuietHours"
    /// "Start Work runs from Today": Prep me and Return in the Ask box. Off hides Prep me and files Return to the inbox.
    static let workRunsKey = "activityTodayStartsWorkRuns"

    static func enabled(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? false }
    static func quietHoursOn(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: quietHoursKey) as? Bool ?? true }
    static func workRunsOn(_ defaults: UserDefaults) -> Bool { defaults.object(forKey: workRunsKey) as? Bool ?? true }

    // MARK: Layout (B2)

    /// At this window width and wider the rail shows names and stories; below it, icons.
    static let fullRailBreakpoint: CGFloat = 1100
    static let fullRailWidth: CGFloat = 248
    static let iconRailWidth: CGFloat = 64
    /// The main column's side padding, each side.
    static let mainPadding: CGFloat = 40
    static let narrowPadding: CGFloat = 28
    /// Two columns from this window width (the main column is then 900 pt). Decided from the window, never in icon-rail mode.
    static let twoColumnWindow: CGFloat = 1228
    /// The right column (Running, Next up, today's meetings) is never narrower than this (the canvas's flex basis).
    static let rightColumnFloor: CGFloat = 380
    /// Below this right-column width, Running's Open links say just "Open" (the full words stay in help and VoiceOver).
    static let runOpenWordsWidth: CGFloat = 430
    /// Running rows before "N more in Sessions": six beside Needs you, three when stacked (Running above the fold).
    static let runningCapWide = 6
    static let runningCapStacked = 2
    /// Needs you rows drawn before "Show N more".
    static let needsShown = 4

    enum RailMode: Equatable { case full, icons }
    static func railMode(windowWidth: CGFloat) -> RailMode { windowWidth >= fullRailBreakpoint ? .full : .icons }
    static func railWidth(_ mode: RailMode) -> CGFloat { mode == .full ? fullRailWidth : iconRailWidth }
    static func padding(windowWidth: CGFloat) -> CGFloat { railMode(windowWidth: windowWidth) == .full ? mainPadding : narrowPadding }
    /// The main column's content width: the window less the rail and the main column's padding.
    static func mainContentWidth(windowWidth: CGFloat) -> CGFloat {
        max(0, windowWidth - railWidth(railMode(windowWidth: windowWidth)) - 2 * padding(windowWidth: windowWidth))
    }
    static func twoColumns(windowWidth: CGFloat) -> Bool {
        windowWidth >= twoColumnWindow && railMode(windowWidth: windowWidth) == .full
    }
    /// The two columns' widths: the right one at least `rightColumnFloor`, Needs you the rest (flex 1.6 to 1 above that).
    static func columns(windowWidth: CGFloat, gap: CGFloat = 28) -> (left: CGFloat, right: CGFloat) {
        let content = mainContentWidth(windowWidth: windowWidth)
        let right = max(rightColumnFloor, (content - gap) / 2.6)
        return (max(0, content - gap - right), right)
    }
    /// Stacked (icon rail), two Running rows keep "N more running" and the first Needs you row above the fold at 920 x 680.
    static func runningCap(windowWidth: CGFloat) -> Int { twoColumns(windowWidth: windowWidth) ? runningCapWide : runningCapStacked }

    // MARK: Days (D2: today's intake by the meeting filename's date)

    /// The `YYYY-MM-DD` prefix of a meeting record's filename; nil when it has none (such an item is older, never Today).
    static func meetingDay(_ filename: String) -> String? {
        let prefix = String(filename.prefix(10))
        guard prefix.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$", options: .regularExpression) != nil else { return nil }
        return prefix
    }

    static func isToday(filename: String, now: Date, calendar: Calendar = .current) -> Bool {
        meetingDay(filename) == ActivityHome.dayKey(now, calendar: calendar)
    }

    /// Open intake: not yet accepted or dismissed (`suggested`, `review`, `ask`).
    static func isOpen(_ item: WorkIntakeItem) -> Bool { ["suggested", "review", "ask"].contains(item.status) }
    /// 0.5.337: open, and not dismissed on this Mac since the last read (ControllerModel.workIntakeDismissedIDs), so a
    /// dismissed item leaves Today, the counts and midnight's move at once, before the next Intake read says so.
    static func isShown(_ item: WorkIntakeItem, dismissed: Set<String>) -> Bool { isOpen(item) && !dismissed.contains(item.id) }
    static func mentionedCards(_ tasks: [TaskRow]) -> [TaskRow] { tasks.filter { $0.workStage == "mentioned" && !$0.checked } }
    /// A mentioned card's meeting: its first linked meeting's filename. A card with none is older.
    static func cardIsToday(_ card: TaskRow, now: Date, calendar: Calendar = .current) -> Bool {
        guard let ref = card.meetingRefs.first else { return false }
        return isToday(filename: ref.filename, now: now, calendar: calendar)
    }

    struct IntakeSplit: Equatable {
        var today: [WorkIntakeItem] = []
        var older: [WorkIntakeItem] = []
        var todayCards: [TaskRow] = []
        var olderCards: [TaskRow] = []
        var todayCount: Int { today.count + todayCards.count }
        var olderCount: Int { older.count + olderCards.count }
        static func == (a: IntakeSplit, b: IntakeSplit) -> Bool {
            a.today.map(\.id) == b.today.map(\.id) && a.older.map(\.id) == b.older.map(\.id)
                && a.todayCards.map(\.id) == b.todayCards.map(\.id) && a.olderCards.map(\.id) == b.olderCards.map(\.id)
        }
    }

    /// The one split home, Needs you and Work's Sort view read (replaces `newItems` "since yesterday" and the mentioned
    /// cutoff for them): today's meetings on Today, everything else in Work. A filter only: midnight moves an item with no
    /// server call, and `today + older` is every open item. 0.5.337: an item dismissed here is in neither (`isShown`).
    static func intakeSplit(items: [WorkIntakeItem], tasks: [TaskRow], now: Date, calendar: Calendar = .current,
                            dismissed: Set<String> = []) -> IntakeSplit {
        var split = IntakeSplit()
        for item in items where isShown(item, dismissed: dismissed) {
            if isToday(filename: item.meeting.filename, now: now, calendar: calendar) { split.today.append(item) } else { split.older.append(item) }
        }
        for card in mentionedCards(tasks) {
            if cardIsToday(card, now: now, calendar: calendar) { split.todayCards.append(card) } else { split.olderCards.append(card) }
        }
        split.today.sort { ($0.meeting.filename, $0.id) < ($1.meeting.filename, $1.id) }
        return split
    }

    // MARK: Sessions

    /// The sessions home reads: the pet's live list when the pet is on (so the two never disagree), else the Sessions list.
    /// A live row keeps the list row's question text when the live read has none.
    static func liveSessions(list: [ClaudeSession], live: [ClaudeSession]?) -> [ClaudeSession] {
        guard let live else { return list.filter { !$0.isKeepWarm } }
        var out: [ClaudeSession] = []
        for row in live where !row.isKeepWarm {
            guard !out.contains(where: { ClaudeSession.sameSession($0.id, row.id) }) else { continue }
            var next = row
            if next.waitingQuestion.isEmpty, let listed = list.first(where: { ClaudeSession.sameSession($0.id, row.id) }) {
                next.waitingQuestion = listed.waitingQuestion
            }
            out.append(next)
        }
        return out
    }

    /// Waiting on Miles: `state == "waiting"` on any provider. A run only the COS server writes cannot stop on a prompt.
    static func isWaiting(_ session: ClaudeSession) -> Bool {
        session.state == "waiting" && !session.heldByServer && !session.isKeepWarm
    }
    /// Working now: running, or a server-held run (a Work New session, a scheduled job) the helper reads as waiting.
    static func isWorking(_ session: ClaudeSession) -> Bool {
        guard !session.isKeepWarm else { return false }
        return session.state == "running" || (session.state == "waiting" && session.heldByServer)
    }

    static func waitingSessions(_ sessions: [ClaudeSession]) -> [ClaudeSession] {
        sessions.filter(isWaiting).sorted { a, b in
            let x = waitingSince(a) ?? .distantPast, y = waitingSince(b) ?? .distantPast
            return x == y ? a.id < b.id : x < y
        }
    }
    static func waitingSince(_ session: ClaudeSession) -> Date? { ActivityHome.stamp(session.stateSince) ?? ActivityHome.stamp(session.updatedAt) }

    // MARK: Tool-name guard (B1)

    static let toolNames: Set<String> = ["AskUserQuestion", "ExitPlanMode", "Bash", "BashOutput", "KillShell", "Edit", "Write", "Read",
                                         "Grep", "Glob", "LS", "Task", "Agent", "WebFetch", "WebSearch", "TodoWrite", "NotebookEdit",
                                         "MultiEdit", "SlashCommand", "Skill", "ToolSearch"]
    /// A bare tool name is never shown. Only known tool names: a single CamelCase word is often a brand or a title
    /// (ThriftCart, MarktPOS, DiveShop360, HubSpot), and those stay.
    static func isBareToolName(_ text: String) -> Bool {
        toolNames.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    /// Text with every bare tool name dropped; nil when nothing is left.
    static func guarded(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || isBareToolName(t) ? nil : t
    }

    /// What a waiting session asked, read only (B1): the AskUserQuestion's own words, or a question's detail when it is
    /// words and not a tool name. A plan, Codex and Cursor carry none.
    static func questionText(_ session: ClaudeSession) -> String? {
        guard session.provider == "claude", session.waitingKind != "plan" else { return nil }
        if let text = guarded(session.waitingQuestion) { return ActivityHome.clip(text, 240) }
        if session.waitingKind == "question", let text = guarded(session.waitingDetail) { return ActivityHome.clip(text, 240) }
        return nil
    }

    /// "<title> asked you a question", by what the session waits on.
    static func askedTitle(_ session: ClaudeSession) -> String {
        let title = guarded(session.title) ?? "A session"
        if session.provider != "claude" { return title + " is waiting for your reply" }
        switch session.waitingKind {
        case "plan": return title + " has a plan for you to approve"
        case "permission": return title + " wants your permission"
        case "mcp_input": return title + " needs your input"
        default: return title + " asked you a question"
        }
    }

    /// A permission's command ("Bash git push") as its why line; a bare tool name alone is dropped.
    static func askedWhy(_ session: ClaudeSession) -> String? {
        guard session.provider == "claude" else { return nil }
        if session.waitingQuestionCount > 1, questionText(session) != nil { return "Question 1 of \(session.waitingQuestionCount)" }
        if session.waitingKind == "plan" { return "Has a plan for you to approve" }
        if session.waitingKind == "permission", let detail = guarded(session.waitingDetail) { return "Wants to run " + ActivityHome.clip(detail, 80) }
        return nil
    }

    // MARK: Platforms (section 6)

    enum Platform: String, CaseIterable {
        case claudeCode, claude, codex, codexCLI, cursor, work, glasses, question, routine
        /// Spelled words in a small rounded label, never a monogram.
        var badge: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .claude: "Claude"
            case .codex: "Codex"
            case .codexCLI: "Codex CLI"
            case .cursor: "Cursor"
            case .work: "Work"
            case .glasses: "Glasses"
            // The server cannot tell a glasses question from a phone one (6.84.1 `origin: person`).
            case .question: "Question"
            case .routine: "Routine"
            }
        }
        /// The group order of the Running panel (section 6).
        var order: Int { Self.allCases.firstIndex(of: self) ?? 99 }
    }

    /// The app a live Claude Code session runs in, from its process (the Terminal or iTerm window, or Claude Desktop).
    struct Host: Equatable, Sendable {
        let app: String
        let terminal: Bool
    }

    static func platform(_ session: ClaudeSession, host: Host?) -> Platform {
        if session.workRunning { return .work }
        if session.isScheduledJob { return .routine }
        switch session.provider {
        case "codex": return .codex
        case "cursor": return .cursor
        default: return host.map { $0.terminal ? .claudeCode : .claude } ?? .claudeCode
        }
    }

    /// Where Open goes and its label; `note` is the fallback copy when it cannot be focused.
    enum OpenAction: Equatable {
        case platform(String)
        case inSessions(String?)
        case workRun(String)
        case liveView(String)
        case messages(Int?)
    }

    static func openFor(_ session: ClaudeSession, host: Host?, cursorTrusted: Bool, hostsRead: Bool = false) -> (label: String, action: OpenAction, note: String?) {
        let platform = platform(session, host: host)
        switch platform {
        case .work, .routine: return ("In Sessions", .inSessions(session.id), nil)
        case .codex, .codexCLI: return ("Open in Codex", .platform(session.id), nil)
        case .cursor:
            return cursorTrusted ? ("Open in Cursor", .platform(session.id), nil)
                : ("In Sessions", .inSessions(session.id), "Open in Cursor needs Accessibility. Turn on in Settings")
        case .claude: return ("Open in Claude", .platform(session.id), nil)
        case .claudeCode:
            if let host { return ("Open in " + host.app, .platform(session.id), nil) }
            // Hosts not read yet: Open session lets the platform route decide. Read, and no process holds it: section 6's fallback.
            return hostsRead ? ("In Sessions", .inSessions(session.id), "Terminal is not running this session any more.")
                : ("Open session", .platform(session.id), nil)
        case .glasses, .question: return ("Open in Messages", .messages(nil), nil)
        }
    }

    /// "in Terminal", "in Claude", "in the Codex app", "in Cursor", "from Work, on the server".
    static func placeWords(_ platform: Platform, host: Host?) -> String {
        switch platform {
        case .claudeCode: host.map { "in " + $0.app } ?? "on this Mac"
        case .claude: "in Claude"
        case .codex: "in Codex"
        case .codexCLI: "in Terminal"
        case .cursor: "in Cursor"
        case .work: "from Work, on the server"
        case .glasses: "glasses recording, live transcript"
        case .question: "COS is answering"
        case .routine: "on the server"
        }
    }

    // MARK: Running (D3, D4, section 6)

    struct WorkRun: Equatable, Sendable {
        let id: String
        let title: String
        let sessionID: String?
        let jobIDs: Set<String>
        let startedAt: Date
        /// 0.5.337 (loop audit W5): the server job behind the run, which Stop cancels (work-job-cancel). nil: no Stop yet.
        var jobID: String? = nil
    }
    struct Recording: Equatable, Sendable {
        let sessionId: String
        let start: Date?
        let isMac: Bool
        var isPhone: Bool { PhoneMeetingCapture.protected(sessionId) }
    }
    /// One in-flight job from GET /api/query-jobs/active (server 6.84.1).
    struct ActiveJob: Equatable, Sendable {
        let jobId: String
        let origin: String
        let title: String
        let elapsedMs: Double
        let messageNo: Int?
        /// When it was accepted, on this Mac's clock: the moment the answer arrived less its `elapsedMs` (the server's own
        /// count), so a clock difference between the two machines never shows. Rows count up from it between ticks.
        let started: Date
        init?(_ value: JSONValue, receivedAt: Date = Date()) {
            guard let o = value.object, let id = o["jobId"]?.string, !id.isEmpty else { return nil }
            jobId = id
            // An origin the server does not send (or does not know) is `other`: shown only as a row Control already has.
            let raw = o["origin"]?.string ?? "other"
            origin = ["person", "routine", "task", "other"].contains(raw) ? raw : "other"
            title = ActivityHome.clip(o["title"]?.string ?? "", 80)
            elapsedMs = max(0, o["elapsedMs"]?.double ?? 0)
            messageNo = o["messageNo"]?.int
            started = receivedAt.addingTimeInterval(-elapsedMs / 1000)
        }
    }
    struct RoutineRun: Equatable, Sendable {
        let id: String
        let label: String
        let firedAt: Date?
        let jobId: String?
        let messageNo: Int?
        let status: String
        init?(_ value: JSONValue) {
            guard let o = value.object, let id = o["id"]?.string, !id.isEmpty else { return nil }
            self.id = id
            status = o["status"]?.string ?? "running"
            label = ActivityHome.clip(o["label"]?.string ?? o["routineId"]?.string ?? "Routine", 80)
            firedAt = (o["firedAt"]?.string).flatMap(ActivityHome.stamp)
            jobId = o["jobId"]?.string
            messageNo = o["messageNo"]?.int
        }
    }
    struct Finished: Equatable, Sendable {
        let id: String
        let title: String
        let provider: String
        let finishedAt: Date
        /// 0.5.337 (loop audit W5): a run started from Today opens its result ("Open result"), not just Sessions.
        var openLabel: String? = nil
    }

    struct RunRow: Identifiable, Equatable {
        let id: String
        let platform: Platform
        var title: String
        let detail: String
        let openLabel: String
        let open: OpenAction
        var note: String? = nil
        /// Working now: the pulse dot (never under Reduce Motion), and counted in Running N.
        let working: Bool
        let finished: Bool
        let started: Date?
        /// Repo or meeting time, added after a separator when two rows share a title.
        var disambiguator: String? = nil
        /// 0.5.337 (loop audit W5): a Work run's server job, which the row's Stop cancels.
        var stopJobID: String? = nil
        /// VoiceOver: "Claude Code in Terminal, Holiday promo landing page, working 12 minutes, Open in Terminal".
        var voiceLabel: String {
            var spoken = detail
            if !placeLead.isEmpty, spoken.hasPrefix(placeLead + ", ") { spoken.removeFirst(placeLead.count + 2) }
            spoken = spoken.replacingOccurrences(of: "([0-9]) min\\b", with: "$1 minutes", options: .regularExpression)
                .replacingOccurrences(of: "([0-9]) s\\b", with: "$1 seconds", options: .regularExpression)
            return [platform.badge + (placeLead.isEmpty ? "" : " " + placeLead), title, spoken, openLabel].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        var placeLead = ""
    }

    struct RunInputs {
        var sessions: [ClaudeSession] = []
        var hosts: [String: Host] = [:]
        /// The host lookup has run at least once (until then a Claude row without a host is unknown, not gone).
        var hostsRead = false
        var cursorTrusted = true
        var workRuns: [WorkRun] = []
        var recordings: [Recording] = []
        /// nil: the server does not advertise the in-flight route (older server), and glasses questions do not appear.
        var jobs: [ActiveJob]?
        var routines: [RoutineRun] = []
        var finished: [Finished] = []
        var event: NextEvent?
        var now = Date()
        var calendar = Calendar.current
    }

    /// "12 min", "40 s", "2 h 5 min".
    static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        let minutes = (s % 3600) / 60
        return "\(s / 3600) h" + (minutes > 0 ? " \(minutes) min" : "")
    }

    /// What is running now, one row per thing, grouped by platform in section 6's order, newest first in a group. A
    /// session waiting on Miles is never here (it is in Needs you); a Work run whose session is listed shows once.
    static func inFlight(_ input: RunInputs) -> [RunRow] {
        var rows: [RunRow] = []
        let working = input.sessions.filter(isWorking)
        for session in working {
            let host = input.hosts[session.id]
            let platform = platform(session, host: host)
            let open = openFor(session, host: host, cursorTrusted: input.cursorTrusted, hostsRead: input.hostsRead)
            let started = ActivityHome.stamp(session.stateSince) ?? ActivityHome.stamp(session.createdAt)
            let place = placeWords(platform, host: host)
            let detail: String
            if platform == .routine {
                detail = started.map { "running since " + clock($0, calendar: input.calendar) } ?? "running"
            } else {
                detail = place + ", working" + (started.map { " " + duration(input.now.timeIntervalSince($0)) } ?? "")
            }
            rows.append(RunRow(id: "session:" + session.id, platform: platform, title: guarded(session.title) ?? "Untitled session",
                               detail: detail, openLabel: open.label, open: open.action, note: open.note, working: true, finished: false,
                               started: started, disambiguator: session.workspace.isEmpty ? nil : session.workspace,
                               placeLead: platform == .claudeCode ? (host.map { "in " + $0.app } ?? "") : ""))
        }
        var workJobIDs = Set<String>()
        for run in input.workRuns {
            workJobIDs.formUnion(run.jobIDs); workJobIDs.insert(run.id)
            if let sid = run.sessionID, input.sessions.contains(where: { ClaudeSession.sameSession($0.id, sid) && (isWorking($0) || isWaiting($0)) }) { continue }
            rows.append(RunRow(id: "work:" + run.id, platform: .work, title: guarded(run.title) ?? "Work run",
                               detail: "from Work, on the server, " + duration(input.now.timeIntervalSince(run.startedAt)),
                               openLabel: "In Sessions", open: .workRun(run.id), working: true, finished: false, started: run.startedAt,
                               stopJobID: run.jobID))
        }
        for recording in input.recordings {
            let start = recording.start
            var title = start.map { "Recording from " + clock($0, calendar: input.calendar) } ?? "Recording now"
            if let event = input.event, let start, abs(event.start.timeIntervalSince(start)) <= 15 * 60 { title = event.title }
            rows.append(RunRow(id: "recording:" + recording.sessionId, platform: .glasses, title: title,
                               detail: (recording.isPhone ? "iPhone microphone recording, live transcript" : recording.isMac ? "recording on this Mac, live transcript" : "glasses recording, live transcript")
                                   + (start.map { ", " + duration(input.now.timeIntervalSince($0)) } ?? ""),
                               openLabel: "Live view", open: .liveView(recording.sessionId), working: true, finished: false, started: start))
        }
        let routineJobs = Set(input.routines.compactMap(\.jobId))
        for job in input.jobs ?? [] {
            guard !workJobIDs.contains(job.jobId), !routineJobs.contains(job.jobId) else { continue }
            switch job.origin {
            case "routine":
                rows.append(RunRow(id: "job:" + job.jobId, platform: .routine, title: guarded(job.title) ?? "Routine",
                                   detail: "running since " + clock(job.started, calendar: input.calendar),
                                   openLabel: "Open in Messages", open: .messages(job.messageNo), working: true, finished: false,
                                   started: job.started))
            case "person":
                rows.append(RunRow(id: "job:" + job.jobId, platform: .question, title: guarded(job.title) ?? "A question to COS",
                                   detail: "COS is answering, " + duration(input.now.timeIntervalSince(job.started)),
                                   openLabel: "Open in Messages", open: .messages(job.messageNo), working: true, finished: false,
                                   started: job.started))
            case "task":
                // A captured task's dispatch Control did not start: on the server, In Sessions.
                rows.append(RunRow(id: "job:" + job.jobId, platform: .work, title: guarded(job.title) ?? "A captured task",
                                   detail: "a captured task, on the server, " + duration(input.now.timeIntervalSince(job.started)), openLabel: "In Sessions",
                                   open: .inSessions(nil), working: true, finished: false, started: job.started))
            default:
                // `other`: a Control Work session or a meeting review. Shown only as the row it already is (a Work receipt
                // or a session), never a second one.
                break
            }
        }
        for run in input.routines where !routineStale(run, now: input.now) {
            rows.append(RunRow(id: "routine:" + run.id, platform: .routine, title: run.label,
                               detail: run.firedAt.map { "running since " + clock($0, calendar: input.calendar) } ?? "running",
                               openLabel: "Open in Messages", open: .messages(run.messageNo), working: true, finished: false, started: run.firedAt))
        }
        var seen = Set<String>()
        rows = rows.filter { seen.insert($0.id).inserted }
        return disambiguate(rows.sorted { a, b in
            if a.platform.order != b.platform.order { return a.platform.order < b.platform.order }
            let x = a.started ?? .distantPast, y = b.started ?? .distantPast
            return x == y ? a.id < b.id : x > y
        })
    }

    /// A routine run with no job that still says `submitting` after this long never started (the scheduler keeps the row).
    static let routineSubmitWindow: TimeInterval = 600
    static func routineStale(_ run: RoutineRun, now: Date) -> Bool {
        guard run.jobId == nil || run.status == "submitting" else { return false }
        guard let fired = run.firedAt else { return true }
        return now.timeIntervalSince(fired) > routineSubmitWindow
    }

    static let finishedWindow: TimeInterval = 3600
    static let finishedCap = 3

    /// Finished within the hour (D3), newest first, at most three, never a row that is running or waiting again.
    static func finishedRows(_ input: RunInputs) -> [RunRow] {
        let live = input.sessions.filter { isWorking($0) || isWaiting($0) }
        return input.finished
            .filter { input.now.timeIntervalSince($0.finishedAt) >= 0 && input.now.timeIntervalSince($0.finishedAt) <= finishedWindow }
            .filter { row in !live.contains { ClaudeSession.sameSession($0.id, row.id) } }
            .sorted { $0.finishedAt > $1.finishedAt }
            .prefix(finishedCap)
            .map { row in
                let platform: Platform = row.provider == "codex" ? .codex : row.provider == "cursor" ? .cursor : .claudeCode
                let minutes = Int(input.now.timeIntervalSince(row.finishedAt) / 60)
                return RunRow(id: "finished:" + row.id, platform: platform, title: guarded(row.title) ?? "Untitled session",
                              detail: minutes < 1 ? "finished just now" : "finished \(minutes) min ago", openLabel: row.openLabel ?? "In Sessions",
                              open: .inSessions(row.id), working: false, finished: true, started: row.finishedAt)
            }
    }

    /// Two rows with one title get their repo or meeting time after a separator: "Footer tweak, Bottle POS".
    static func disambiguate(_ rows: [RunRow]) -> [RunRow] {
        var counts: [String: Int] = [:]
        for row in rows { counts[row.title, default: 0] += 1 }
        return rows.map { row in
            guard counts[row.title, default: 0] > 1, let extra = row.disambiguator ?? row.started.map({ clock($0, calendar: .current) }) else { return row }
            var next = row; next.title = row.title + ", " + extra; return next
        }
    }

    struct RunningView: Equatable {
        let shown: [RunRow]
        let finished: [RunRow]
        let moreRunning: Int
        let moreFinished: Int
        /// Running N: things in flight. Finished rows are never counted.
        let count: Int
        var moreLabel: String? {
            switch (moreRunning, moreFinished) {
            case (0, 0): nil
            case (let r, 0): "\(r) more running"
            case (0, let f): f == 1 ? "1 more finished" : "\(f) more finished"
            case (let r, let f): "\(r) more running, and \(f) finished"
            }
        }
    }

    /// The cap (six, or three stacked) counts every row; finished rows give way first.
    static func runningView(inFlight: [RunRow], finished: [RunRow], cap: Int) -> RunningView {
        let shown = Array(inFlight.prefix(cap))
        let room = max(0, cap - shown.count)
        let done = Array(finished.prefix(room))
        return RunningView(shown: shown, finished: done, moreRunning: inFlight.count - shown.count,
                           moreFinished: finished.count - done.count, count: inFlight.count)
    }

    // MARK: Next up (section 4)

    struct NextEvent: Equatable, Sendable {
        let title: String
        let start: Date
        func minutes(until now: Date) -> Int { max(0, Int((start.timeIntervalSince(now) / 60).rounded())) }
    }

    /// welcome-context's one event, if it starts today and has not started more than an hour ago.
    static func nextEvent(_ value: JSONValue?, now: Date, calendar: Calendar = .current) -> NextEvent? {
        guard let o = value?.object, let title = o["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let time = o["time"]?.string, let start = ActivityHome.stamp(time) ?? localStamp(time),
              calendar.isDate(start, inSameDayAs: now), start.timeIntervalSince(now) > -3600 else { return nil }
        return NextEvent(title: ActivityHome.clip(title, 120), start: start)
    }
    /// A calendar time without a zone ("2026-10-21T15:30:00"): local.
    static func localStamp(_ text: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: String(text.prefix(19)))
    }
    /// "In 43 min", "In 2 h 5 min", "Now".
    static func eventWhen(_ event: NextEvent, now: Date) -> String {
        let m = event.minutes(until: now)
        if m == 0 { return event.start <= now ? "Started at " + clock(event.start) : "Now" }
        return "In " + duration(Double(m * 60))
    }

    // MARK: Needs you (B1, B3, B4)

    enum NeedKind: String { case session, voice, meetingVoices, heldVoices, work, memories, olderToSort, dictation }

    /// Voice and meeting rows shown one by one; the rest fold into one row each (Miles's Mac held 130 groups on 10/22,
    /// which read as "128 need you").
    static let voiceRowLimit = 3

    struct NeedRow: Identifiable {
        let id: String
        let kind: NeedKind
        /// 1 blocks an agent and never folds; 2 to 5 fold under quiet hours.
        let tier: Int
        let title: String
        var quote: String? = nil
        var why: String? = nil
        var source: String? = nil
        var since: Date? = nil
        /// Items inside the thing ("Review 7 memories" is one thing of 7 items).
        var items = 1
        var session: ClaudeSession? = nil
        var group: HeldVoiceGroup? = nil
        var meeting: ReviewableMeeting? = nil
        var move: WorkYourMove? = nil
        var openLabel: String? = nil
    }

    struct NeedInputs {
        var waiting: [ClaudeSession] = []
        var hosts: [String: Host] = [:]
        var cursorTrusted = true
        /// nil: Speakers' held groups have not loaded.
        var voiceGroups: [HeldVoiceGroup]?
        var groupMeeting: [String: String] = [:]
        var groupStart: [String: Date] = [:]
        var meetingsToName: [ReviewableMeeting] = []
        /// 0.5.340: each meeting's voices to name as Speakers tags it (the server's list count, or the visit's). A saved
        /// Mac recording has no server count, so without this its row read "0 speakers have no name yet".
        var meetingUnnamed: [String: Int] = [:]
        var yourMove: [WorkYourMove]?
        var memoriesToReview: Int?
        var memoriesTotal: Int?
        var olderToSort: Int?
        var dictationFixes = 0
        var now = Date()
        var calendar = Calendar.current
    }

    /// "Claude Code in Terminal, MU-Chief-Staff. Paused until you answer there."
    static func sessionSource(_ session: ClaudeSession, host: Host?) -> String {
        let platform = platform(session, host: host)
        let lead: String
        switch platform {
        case .cursor: lead = "Cursor on this Mac"
        case .codex, .codexCLI: lead = "Codex on this Mac"
        default: lead = platform.badge + " " + placeWords(platform, host: host)
        }
        let repo = session.workspace.isEmpty ? "" : ", " + session.workspace
        return lead + repo + (session.provider == "claude" ? ". Paused until you answer there." : "")
    }

    /// Every thing waiting on Miles, one row per thing, ranked: sessions (oldest first), voices, Work's your move, memories,
    /// older to sort, dictation fixes. A thing is in one place only: no id twice, and a Work row for a waiting session is
    /// the session's row.
    static func things(_ input: NeedInputs) -> [NeedRow] {
        var rows: [NeedRow] = []
        for session in waitingSessions(input.waiting) {
            let host = input.hosts[session.id]
            let open = openFor(session, host: host, cursorTrusted: input.cursorTrusted)
            let label = session.provider == "claude" ? "Open session" : open.label
            rows.append(NeedRow(id: "session:" + session.id, kind: .session, tier: 1, title: askedTitle(session),
                                quote: questionText(session), why: askedWhy(session), source: sessionSource(session, host: host),
                                since: waitingSince(session), session: session, openLabel: label))
        }
        // One by one: a group with a name to confirm, or one heard today. Everything else is one row that opens Speakers.
        var voiceRows = 0, heldVoices = 0
        for group in input.voiceGroups ?? [] {
            let name = group.suggestionName.flatMap(guarded)
            let today = input.groupStart[group.id].map { input.calendar.isDate($0, inSameDayAs: input.now) } ?? false
            guard voiceRows < voiceRowLimit, name != nil || today else { heldVoices += 1; continue }
            voiceRows += 1
            let meeting = input.groupMeeting[group.id]
            let title = meeting.map { "Name a voice from " + $0 } ?? (input.groupStart[group.id].map { "Name a voice from a " + clock($0, calendar: input.calendar) + " recording" } ?? "Name a voice")
            rows.append(NeedRow(id: "voice:" + group.id, kind: .voice, tier: 2, title: title,
                                why: name.map { "Sounds like \($0), similarity " + String(format: "%.2f", group.suggestionSimilarity) + "." },
                                source: group.sampleCount == 1 ? "1 sample held" : "\(group.sampleCount) samples held",
                                since: input.groupStart[group.id], items: max(1, group.sampleCount), group: group))
        }
        var meetingRows = 0, olderMeetings: [ReviewableMeeting] = []
        for meeting in input.meetingsToName {
            let today = ActivityHome.meetingDate(meeting, calendar: input.calendar).map { input.calendar.isDate($0, inSameDayAs: input.now) } ?? false
            guard meetingRows < voiceRowLimit, today else { olderMeetings.append(meeting); continue }
            meetingRows += 1
            let unnamed = input.meetingUnnamed[meeting.sessionId] ?? meeting.unattributedVoices
            rows.append(NeedRow(id: "meeting-voices:" + meeting.sessionId, kind: .meetingVoices, tier: 2,
                                title: "Name the voices in " + (guarded(meeting.title) ?? "a saved meeting"),
                                why: (unnamed ?? 0) == 1 ? "1 speaker has no name yet." : "\(unnamed ?? 0) speakers have no name yet.",
                                since: ActivityHome.meetingDate(meeting, calendar: input.calendar), items: max(1, unnamed ?? 1), meeting: meeting))
        }
        if heldVoices > 0 || !olderMeetings.isEmpty {
            let parts = [heldVoices > 0 ? (heldVoices == 1 ? "1 held voice" : "\(heldVoices) held voices") : nil,
                         olderMeetings.isEmpty ? nil : (olderMeetings.count == 1 ? "1 earlier meeting" : "\(olderMeetings.count) earlier meetings")].compactMap { $0 }
            rows.append(NeedRow(id: "held-voices", kind: .heldVoices, tier: 5, title: "Name voices in Speakers",
                                why: parts.joined(separator: " and ") + " without a name yet.",
                                items: heldVoices + olderMeetings.count, openLabel: "Open Speakers"))
        }
        let waitingIDs = input.waiting.filter(isWaiting).map(\.id)
        for move in input.yourMove ?? [] {
            if let sid = move.sessionID, waitingIDs.contains(where: { ClaudeSession.sameSession($0, sid) }) { continue }
            rows.append(NeedRow(id: "work:" + move.id, kind: .work, tier: 3, title: (move.action == "review" ? "Review " : "") + (guarded(move.title) ?? "a Work item"),
                                why: move.kind == "question" ? "The Work card is waiting on your answer before it moves on." : "The Work card is waiting on your review before it moves on.",
                                source: "In Work", move: move, openLabel: move.actionTitle))
        }
        if let count = input.memoriesToReview, count > 0 {
            rows.append(NeedRow(id: "memories", kind: .memories, tier: 4, title: count == 1 ? "Review 1 memory" : "Review \(count) memories",
                                why: memoriesStory(count, total: input.memoriesTotal), items: count, openLabel: "Review all"))
        }
        if let older = input.olderToSort, older > 0 {
            rows.append(NeedRow(id: "older-to-sort", kind: .olderToSort, tier: 5,
                                title: older == 1 ? "Sort 1 older suggestion in Work" : "Sort \(older) older suggestions in Work",
                                why: "From meetings before today.", items: older, openLabel: "Open in Work"))
        }
        if input.dictationFixes > 0 {
            let n = input.dictationFixes
            rows.append(NeedRow(id: "dictation", kind: .dictation, tier: 5, title: n == 1 ? "Check 1 dictation fix" : "Check \(n) dictation fixes",
                                why: "COS learned from your edits.", items: n, openLabel: "Open Dictation"))
        }
        var seen = Set<String>()
        return rows.filter { seen.insert($0.id).inserted }.enumerated().sorted { a, b in
            if a.element.tier != b.element.tier { return a.element.tier < b.element.tier }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// "7 to review" only when To review opens on those same 7; else "Next 7 of 23".
    static func memoriesStory(_ count: Int, total: Int?) -> String {
        if let total, total > count { return "Next \(count) of \(total)" }
        return "\(count) to review"
    }

    /// The model a run from Today uses: Sonnet when the catalog has it, else another Claude model that is not Opus, else any
    /// available non-Opus model that runs on the server (never Cursor, which waits for a person). Never Opus by default.
    static func pickRunModel(_ choices: [(id: String, provider: String, available: Bool)]) -> Int? {
        let usable = choices.indices.filter { choices[$0].available && choices[$0].provider != "cursor" && !choices[$0].id.lowercased().contains("opus") }
        return usable.first { choices[$0].provider == "claude" && choices[$0].id.lowercased().contains("sonnet") }
            ?? usable.first { choices[$0].provider == "claude" } ?? usable.first
    }

    /// "Show 4 more: review 7 memories, sort 23 older suggestions in Work and 2 more". Two labels at most.
    static func showMoreLabel(_ hidden: [NeedRow]) -> String {
        let labels = hidden.prefix(2).map(shortLabel)
        let rest = hidden.count - labels.count
        return "Show \(hidden.count) more: " + labels.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
    }

    /// What a suggestion row offers: an ask or a review becomes a task (one resolve accept); a link to an existing card opens
    /// that card. 0.5.337: every ready row also has a quiet Dismiss (one resolve dismiss), whatever this returns.
    enum SuggestionAction: Equatable { case createTask, openCard(String), unavailable }
    static func suggestionAction(_ item: WorkIntakeItem, cardCreation: Bool) -> SuggestionAction {
        if item.kind == .link { return .openCard(item.pullTitle ?? item.text) }
        return cardCreation ? .createTask : .unavailable
    }
    enum SuggestionState: Equatable { case ready, creating, created, failed(String), dismissing, dismissFailed(String) }
    /// A row's state from the one resolve path (ControllerModel.resolveWorkIntake): busy ids, what Today saw created, and the
    /// refusal it kept. 0.5.337: a busy id Today is dismissing reads Dismissing, and a refused dismiss keeps the row with
    /// the server's reason (its buttons stay, so Dismiss is the retry).
    static func suggestionState(_ id: String, busy: Set<String>, created: Set<String>, failures: [String: String],
                                dismissals: TodayDismissals = TodayDismissals()) -> SuggestionState {
        if busy.contains(id) { return dismissals.dismissing.contains(id) ? .dismissing : .creating }
        if created.contains(id) { return .created }
        if let reason = failures[id] { return .failed(reason) }
        if let reason = dismissals.failures[id] { return .dismissFailed(reason) }
        return .ready
    }

    /// 0.5.337 (loop audit W5): a Work run's session, once its receipt names one.
    static func workRunSession(id: String, receipts: [(id: String, sessionID: String?)]) -> String? {
        guard !id.isEmpty else { return nil }
        return receipts.first { $0.id == id }?.sessionID
    }

    /// 0.5.337 (loop audit W12): "Named <name>. Undo" after naming a voice from Today, for this long.
    struct LastNaming: Equatable { let name: String; let undo: String?; let at: Date }
    static let namedLineSeconds: TimeInterval = 120
    static func showsNamed(_ named: LastNaming, now: Date) -> Bool {
        now >= named.at && now.timeIntervalSince(named.at) < namedLineSeconds
    }

    /// VoiceOver's name for a row's Dismiss.
    static func dismissLabel(_ item: WorkIntakeItem) -> String { "Dismiss suggestion: " + item.text }

    /// One place in "From today's meetings": an open suggestion, or one dismissed here and still offering Undo.
    enum SuggestionSlot: Equatable {
        case open(WorkIntakeItem)
        case dismissed(TodayDismissals.Row)
        var id: String {
            switch self {
            case .open(let item): item.id
            case .dismissed(let row): row.item.id
            }
        }
        var isDismissed: Bool {
            if case .dismissed = self { return true }
            return false
        }
    }
    /// Today's open suggestions with the collapsed "Dismissed. Undo" rows in the places they had (the split's order:
    /// meeting filename, then id). A collapsed row wins over an open copy of the same item from a stale read.
    static func suggestionSlots(open: [WorkIntakeItem], dismissals: TodayDismissals, now: Date) -> [SuggestionSlot] {
        let live = dismissals.live(now: now)
        let collapsed = Set(live.map(\.item.id))
        let slots = open.filter { !collapsed.contains($0.id) }.map(SuggestionSlot.open) + live.map(SuggestionSlot.dismissed)
        func key(_ slot: SuggestionSlot) -> (String, String) {
            switch slot {
            case .open(let item): (item.meeting.filename, item.id)
            case .dismissed(let row): (row.item.meeting.filename, row.item.id)
            }
        }
        return slots.sorted { key($0) < key($1) }
    }

    /// The row's line in "Show N more: …".
    static func shortLabel(_ row: NeedRow) -> String {
        switch row.kind {
        case .olderToSort: row.title.replacingOccurrences(of: "Sort", with: "sort")
        case .heldVoices: row.title.replacingOccurrences(of: "Name", with: "name")
        case .memories: row.title.replacingOccurrences(of: "Review", with: "review")
        case .dictation: row.title.replacingOccurrences(of: "Check", with: "check")
        default: row.title
        }
    }

    // MARK: Quiet hours

    /// After 6 PM and before 6 AM local, and on weekends.
    static func isQuiet(now: Date, enabled: Bool, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let hour = calendar.component(.hour, from: now)
        return calendar.isDateInWeekend(now) || hour >= 18 || hour < 6
    }

    /// Under quiet hours, tiers 2 to 5 fold under "For tomorrow". Session questions never fold. Running is not in here.
    static func fold(_ rows: [NeedRow], quiet: Bool) -> (now: [NeedRow], tomorrow: [NeedRow]) {
        guard quiet else { return (rows, []) }
        return (rows.filter { $0.tier == 1 }, rows.filter { $0.tier != 1 })
    }

    static func tomorrowLine(_ rows: [NeedRow]) -> String {
        rows.count == 1 ? "For tomorrow: 1 more thing" : "For tomorrow: \(rows.count) more things"
    }

    // MARK: Sources and states (section 7)

    enum Source: String, CaseIterable { case sessions, voices, memories, work, dictation
        var name: String {
            switch self {
            case .sessions: "sessions"
            case .voices: "voices"
            case .memories: "memories"
            case .work: "Work"
            case .dictation: "dictation"
            }
        }
    }

    /// Each source as its loader left it, plus whether the server answers at all. `reachable` false comes only from a
    /// transport failure (the status loop, or a tick where nothing answered), never from one source's error.
    struct SourceInputs: Equatable {
        var reachable = true
        var sessions: ActivityHome.SourceState = .pending
        var voices: ActivityHome.SourceState = .pending
        var memories: ActivityHome.SourceState = .pending
        var work: ActivityHome.SourceState = .pending
        /// Work's Intake read failed (a Create task refusal is not a read failure).
        var intakeFailed = false
        var dictation: ActivityHome.SourceState = .answered
    }

    /// The states every surface reads. Unreachable: the server's sources failed (sessions are this Mac's). Intake failing
    /// fails Work.
    static func sourceStates(_ input: SourceInputs) -> [Source: ActivityHome.SourceState] {
        func server(_ state: ActivityHome.SourceState) -> ActivityHome.SourceState { input.reachable || state == .off ? state : .failed }
        var work = server(input.work)
        if input.intakeFailed, work != .off { work = .failed }
        return [.sessions: input.sessions, .voices: server(input.voices), .memories: server(input.memories), .work: work, .dictation: input.dictation]
    }

    /// Every source that applies answered. Only then may anything say "nothing" ("Nothing is waiting on you", "Every voice has
    /// a name", "Nothing to sort").
    static func settled(_ states: [Source: ActivityHome.SourceState]) -> Bool {
        let counted = Source.allCases.map { states[$0] ?? .pending }.filter { $0 != .off }
        return !counted.isEmpty && counted.allSatisfy { $0 == .answered }
    }
    static func answered(_ source: Source, _ states: [Source: ActivityHome.SourceState]) -> Bool { states[source] == .answered }

    enum NeedsLine: Equatable { case loading, rows, caughtUp }

    /// Rows when anything waits. "Nothing is waiting on you" only once every source that applies answered: never while one
    /// is loading or after one failed.
    static func needsLine(rows: Int, states: [Source: ActivityHome.SourceState]) -> NeedsLine {
        if rows > 0 { return .rows }
        return settled(states) ? .caughtUp : .loading
    }
    static func failed(_ states: [Source: ActivityHome.SourceState]) -> [Source] { Source.allCases.filter { states[$0] == .failed } }
    static func failureLine(_ source: Source) -> String { "Couldn't read \(source.name). Try again" }
    static let caughtUpLine = "Nothing is waiting on you."
    static let loadingLine = "Reading sessions and Work"
    static let unreachableLine = "Voices, memories and Work are on the server. Try again"
    static func checkedLine(_ at: Date, states: [Source: ActivityHome.SourceState], calendar: Calendar = .current) -> String {
        let names = Source.allCases.filter { (states[$0] ?? .pending) != .off }.map(\.name)
        return "Checked " + list(names) + " at " + clock(at, calendar: calendar) + "."
    }

    // MARK: Counts (B3): one struct read by the rail, the headers, the brief and the cards

    struct Counts: Equatable {
        var needs = 0
        var running = 0
        var sessionsWaiting = 0
        var agentsWorking = 0
        var finishedHour = 0
        var glassesQuestions = 0
        var recording = false
        var routinesRunning = 0
        var voicesToName: Int?
        var memoriesToReview: Int?
        var memoriesTotal: Int?
        var oldestReview: Date?
        var workNeedsYou: Int?
        var olderToSort: Int?
        var todaySuggestions: Int?
        var meetingsReady: Int?
        var latestMeetingToday: String?
        var threadsActive: Int?
        var newestThread: String?
        var dictationLast: Date?
        var dictationFixes = 0
        var nextEvent: NextEvent?
        /// True only when the server said it read the calendar (welcome-context `calendarRead`); nil or false says nothing.
        var calendarRead = false
        var morningBrief: Date?
        var lastMessage: Date?
        /// Every source answered; until then nothing says "nothing".
        var settled = false
        /// The session list answered (until then nothing says no agents are running).
        var sessionsKnown = false
        var failedSources: [Source] = []
    }

    static let agentPlatforms: Set<Platform> = [.claudeCode, .claude, .codex, .codexCLI, .cursor, .work]

    static func counts(needs: [NeedRow], running: [RunRow], finished: [RunRow]) -> Counts {
        var c = Counts()
        c.needs = needs.count
        c.sessionsWaiting = needs.filter { $0.kind == .session }.count
        c.running = running.count
        c.agentsWorking = running.filter { agentPlatforms.contains($0.platform) }.count
        c.glassesQuestions = running.filter { $0.platform == .question }.count
        c.recording = running.contains { $0.platform == .glasses }
        c.routinesRunning = running.filter { $0.platform == .routine }.count
        c.finishedHour = finished.count
        return c
    }

    // MARK: Composition: the one frame the rail, the home and every count read

    /// Facts for the story cards, read from the model by the window (nil: not loaded).
    struct CardFacts: Equatable {
        var memoriesToReview: Int?
        var memoriesTotal: Int?
        var oldestReview: Date?
        var meetingsReady: Int?
        var latestMeetingToday: String?
        var threadsActive: Int?
        var newestThread: String?
        var dictationLast: Date?
        var dictationFixes = 0
        var calendarRead: Bool?
        var morningBrief: Date?
        var lastMessage: Date?
        /// The voice groups loaded (Speakers answered); nil while not.
        var voicesLoaded = false
        var yourMoveLoaded = false
    }

    struct HomeInputs {
        var run = RunInputs()
        var need = NeedInputs()
        var sources = SourceInputs()
        var facts = CardFacts()
        var split: IntakeSplit?
    }

    struct Frame {
        let needs: [NeedRow]
        let running: [RunRow]
        let finished: [RunRow]
        let counts: Counts
        let states: [Source: ActivityHome.SourceState]
        let line: NeedsLine
        let reachable: Bool
        let split: IntakeSplit?
    }

    /// The whole home from its inputs. Unreachable: Needs you keeps this Mac's sessions only. A source that has not answered
    /// gives nil to every count that reads it, so no surface can say "nothing" for it.
    /// 0.5.337 (performance audit B2): the Today frame's clock (TodayFrameSchedule): every 30 s from the start, or the
    /// start alone while the window is off screen.
    static let frameInterval: TimeInterval = 30
    static func frameEntries(from start: Date, paused: Bool) -> AnyIterator<Date> {
        var next: Date? = start
        return AnyIterator {
            guard let current = next else { return nil }
            next = paused ? nil : current.addingTimeInterval(frameInterval)
            return current
        }
    }

    /// 0.5.337 (performance audit B2): how many times the home was composed (the resize gate counts it; never read by the app).
    nonisolated(unsafe) static var composeRuns = 0
    static func compose(_ input: HomeInputs) -> Frame {
        composeRuns += 1
        let states = sourceStates(input.sources)
        let reachable = input.sources.reachable
        var need = input.need
        if !reachable {
            need.voiceGroups = nil; need.meetingsToName = []; need.yourMove = nil; need.memoriesToReview = nil; need.olderToSort = nil
        }
        if states[.work] != .answered { need.olderToSort = nil }
        let needs = things(need)
        let running = inFlight(input.run)
        let finished = finishedRows(input.run)
        var c = counts(needs: needs, running: running, finished: finished)
        let facts = input.facts
        c.voicesToName = answered(.voices, states) && facts.voicesLoaded ? needs.filter { $0.kind == .voice || $0.kind == .meetingVoices || $0.kind == .heldVoices }.reduce(0) { $0 + ($1.kind == .voice ? 1 : $1.items) } : nil
        c.memoriesToReview = answered(.memories, states) ? facts.memoriesToReview : nil
        c.memoriesTotal = c.memoriesToReview == nil ? nil : facts.memoriesTotal
        c.oldestReview = facts.oldestReview
        c.workNeedsYou = answered(.work, states) && facts.yourMoveLoaded ? needs.filter { $0.kind == .work }.count : nil
        c.olderToSort = answered(.work, states) ? input.split?.olderCount : nil
        c.todaySuggestions = answered(.work, states) ? input.split?.todayCount : nil
        c.meetingsReady = reachable ? facts.meetingsReady : nil
        c.latestMeetingToday = facts.latestMeetingToday
        c.threadsActive = reachable ? facts.threadsActive : nil
        c.newestThread = facts.newestThread
        c.dictationLast = facts.dictationLast
        c.dictationFixes = facts.dictationFixes
        c.nextEvent = input.run.event.flatMap { $0.start.timeIntervalSince(input.run.now) > -3600 ? $0 : nil }
        c.calendarRead = facts.calendarRead == true
        c.morningBrief = facts.morningBrief
        c.lastMessage = facts.lastMessage
        c.settled = settled(states)
        c.sessionsKnown = answered(.sessions, states)
        c.failedSources = failed(states)
        return Frame(needs: needs, running: running, finished: finished, counts: c, states: states,
                     line: needsLine(rows: needs.count, states: states), reachable: reachable,
                     split: reachable && states[.work] == .answered ? input.split : nil)
    }

    // MARK: Brief (zero LLM, fixed templates)

    static func number(_ n: Int, capital: Bool = false) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        let w = n >= 0 && n < words.count ? words[n] : "\(n)"
        return capital ? w.prefix(1).uppercased() + w.dropFirst() : w
    }

    static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        default: parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
    }

    /// Formatters are made once per format and time zone (the home draws every minute on every tab).
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
    private static let formatterLock = NSLock()
    static func format(_ date: Date, _ pattern: String, calendar: Calendar) -> String {
        formatterLock.lock(); defer { formatterLock.unlock() }
        let key = pattern + "|" + calendar.timeZone.identifier
        let f = formatters[key] ?? {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = calendar.timeZone; f.dateFormat = pattern
            formatters[key] = f
            return f
        }()
        return f.string(from: date)
    }
    static func clock(_ date: Date, calendar: Calendar = .current) -> String { format(date, "h:mm a", calendar: calendar) }
    static func monthDay(_ date: Date, calendar: Calendar = .current) -> String { format(date, "MMM d", calendar: calendar) }
    /// "Wednesday, October 21, 2:47 PM".
    static func headerDate(_ date: Date, calendar: Calendar = .current) -> String { format(date, "EEEE, MMMM d, h:mm a", calendar: calendar) }

    /// Fixed templates over the counts. "Nothing is waiting on you" only once every source answered; until then the
    /// brief says only what it knows, or that it is still reading (or what it could not read). The calendar is "clear"
    /// only when the server said it read it.
    static func brief(_ c: Counts, calendar: Calendar = .current) -> String {
        var first: String?
        if c.sessionsWaiting > 0 {
            first = number(c.sessionsWaiting, capital: true) + (c.sessionsWaiting == 1 ? " session is waiting on you" : " sessions are waiting on you")
        } else if c.needs > 0 {
            first = number(c.needs, capital: true) + (c.needs == 1 ? " thing needs you" : " things need you") + (c.settled ? "" : " so far")
        } else if c.settled {
            first = "Nothing is waiting on you"
        }
        if let event = c.nextEvent {
            let words = event.title + " starts at " + clock(event.start, calendar: calendar)
            first = first.map { $0 + ", and " + words } ?? words
        } else if c.calendarRead {
            first = first.map { $0 + ", and your calendar is clear for the rest of the day" } ?? "Your calendar is clear for the rest of the day"
        }
        var parts: [String] = []
        if c.agentsWorking > 0 { parts.append(number(c.agentsWorking) + (c.agentsWorking == 1 ? " agent is working" : " agents are working")) }
        if c.glassesQuestions > 0 {
            parts.append(c.glassesQuestions == 1 ? "COS is answering a question" : "COS is answering " + number(c.glassesQuestions) + " questions")
        }
        if c.routinesRunning > 0 { parts.append(c.routinesRunning == 1 ? "a routine is running" : number(c.routinesRunning) + " routines are running") }
        if c.recording { parts.append("the glasses are recording") }
        var sentences: [String] = []
        if let first { sentences.append(first + ".") }
        if !parts.isEmpty { let second = list(parts); sentences.append(second.prefix(1).uppercased() + second.dropFirst() + ".") }
        if !c.settled && c.needs == 0 {
            sentences.append(c.failedSources.isEmpty ? "Still reading what needs you."
                             : "Couldn't read " + list(c.failedSources.map(\.name)) + ", so this may not be everything.")
        }
        return sentences.joined(separator: " ")
    }

    // MARK: Rail stories (one line per tab; the same counts the tab lists)

    struct Story: Equatable {
        let text: String
        let hot: Bool
    }

    /// `tab`: "today" or an ActivitySection raw value.
    static func story(_ tab: String, _ c: Counts, now: Date, calendar: Calendar = .current) -> Story {
        switch tab {
        case "today":
            let needs: String?
            if c.needs > 0 { needs = c.needs == 1 ? "1 needs you" : "\(c.needs) need you" }
            else if c.settled { needs = "Nothing needs you" }
            else { needs = c.failedSources.isEmpty ? "Reading" : "Couldn't read " + list(c.failedSources.map(\.name)) }
            let running = c.running > 0 ? "\(c.running) running" : nil
            return Story(text: [needs, running].compactMap { $0 }.joined(separator: ", "), hot: c.needs > 0)
        case "messages":
            if let brief = c.morningBrief, calendar.isDate(brief, inSameDayAs: now) {
                return Story(text: "Morning brief reached the glasses at " + clock(brief, calendar: calendar), hot: false)
            }
            if let last = c.lastMessage, calendar.isDate(last, inSameDayAs: now) {
                return Story(text: "Last from the glasses at " + clock(last, calendar: calendar), hot: false)
            }
            return Story(text: "Questions and answers from your glasses", hot: false)
        case "speakers":
            guard let n = c.voicesToName else { return Story(text: "Voices from your meetings", hot: false) }
            return n > 0 ? Story(text: n == 1 ? "1 voice to name" : "\(n) voices to name", hot: true) : Story(text: "Every voice has a name", hot: false)
        case "meetings":
            var bits: [String] = []
            if let ready = c.meetingsReady, ready > 0 { bits.append("\(ready) ready to review") }
            if let event = c.nextEvent { bits.append((bits.isEmpty ? "Next at " : "next at ") + clock(event.start, calendar: calendar)) }
            return Story(text: bits.isEmpty ? "Saved meetings by day" : bits.joined(separator: ", "), hot: false)
        case "memories":
            guard let n = c.memoriesToReview else { return Story(text: "What your COS can recall", hot: false) }
            return n > 0 ? Story(text: memoriesStory(n, total: c.memoriesTotal), hot: true) : Story(text: "Nothing to review", hot: false)
        case "threads":
            guard let active = c.threadsActive, active > 0 else { return Story(text: "Work that develops over time", hot: false) }
            return Story(text: "\(active) active" + (c.newestThread.map { ", newest " + ActivityHome.clip($0, 40) } ?? ""), hot: false)
        case "sessions":
            let working = c.agentsWorking
            if c.sessionsWaiting == 0 && working == 0 { return Story(text: c.sessionsKnown ? "No agents running" : "Claude, Codex and Cursor on this Mac", hot: false) }
            var bits: [String] = []
            if c.sessionsWaiting > 0 { bits.append("\(c.sessionsWaiting) waiting on you") }
            if working > 0 { bits.append("\(working) working") }
            return Story(text: bits.joined(separator: ", "), hot: c.sessionsWaiting > 0)
        case "work", "tasks":
            var bits: [String] = []
            if let n = c.workNeedsYou, n > 0 { bits.append(n == 1 ? "1 needs you" : "\(n) need you") }
            if let n = c.olderToSort, n > 0 { bits.append("\(n) older to sort") }
            if !bits.isEmpty { return Story(text: bits.joined(separator: ", "), hot: c.workNeedsYou ?? 0 > 0) }
            return Story(text: c.olderToSort == nil || c.workNeedsYou == nil ? "Your tasks and meeting follow-ups" : "Nothing to sort", hot: false)
        case "dictation":
            var text = c.dictationLast.map { calendar.isDate($0, inSameDayAs: now) ? "Last at " + clock($0, calendar: calendar) : "Last on " + monthDay($0, calendar: calendar) } ?? "Dictate anywhere on this Mac"
            if c.dictationFixes > 0 { text += c.dictationFixes == 1 ? ", 1 fix waiting" : ", \(c.dictationFixes) fixes waiting" }
            return Story(text: text, hot: c.dictationFixes > 0)
        default:
            return Story(text: "", hot: false)
        }
    }

    // MARK: Story cards ("Activity / Views into the work your COS already holds.")

    struct StoryCard: Equatable {
        var tag: String?
        var story: String
        var sub: String?
        var foot: String?
        var hot: Bool { tag != nil }
    }

    static func card(_ tab: String, _ c: Counts, now: Date, calendar: Calendar = .current) -> StoryCard {
        switch tab {
        case "messages":
            if let brief = c.morningBrief, calendar.isDate(brief, inSameDayAs: now) {
                return StoryCard(story: "Your morning brief reached the glasses at " + clock(brief, calendar: calendar) + ".", sub: "Open Messages to read it again.")
            }
            if let last = c.lastMessage, calendar.isDate(last, inSameDayAs: now) {
                return StoryCard(story: "Your last question from the glasses was at " + clock(last, calendar: calendar) + ".")
            }
            return StoryCard(story: "Questions and answers from your glasses land here.")
        case "speakers":
            guard let n = c.voicesToName else { return StoryCard(story: "The voices from your meetings, by name.") }
            if n == 0 { return StoryCard(story: "Every voice from your meetings has a name.") }
            return StoryCard(tag: "\(n) to name", story: n == 1 ? "One new voice is waiting for a name." : number(n, capital: true) + " new voices are waiting for names.",
                             sub: n == 1 ? "Its suggestion is in Needs you." : "Their suggestions are in Needs you.")
        case "meetings":
            let next = c.nextEvent.map { "Next is \($0.title) at " + clock($0.start, calendar: calendar) + "." }
            let foot = c.nextEvent.map { "Next at " + clock($0.start, calendar: calendar) }
            guard let ready = c.meetingsReady else { return StoryCard(story: "Saved meetings, by day.", sub: next, foot: foot) }
            if ready == 0 { return StoryCard(story: "Every saved meeting has been reviewed.", sub: next, foot: foot) }
            let story = c.latestMeetingToday.map { $0 + " is saved and ready to review." }
                ?? (ready == 1 ? "One meeting is ready to review." : number(ready, capital: true) + " meetings are ready to review.")
            let sub = next ?? ""
            return StoryCard(tag: "\(ready) to review", story: story, sub: sub.isEmpty ? nil : sub, foot: foot)
        case "memories":
            guard let n = c.memoriesToReview else { return StoryCard(story: "What your COS can recall.") }
            if n == 0 { return StoryCard(story: "Nothing COS learned is waiting on you.") }
            return StoryCard(tag: "\(n) to review", story: "\(n) new " + (n == 1 ? "thing COS learned is" : "things COS learned are") + " waiting for a keep or drop.",
                             sub: c.oldestReview.map { "The oldest has waited since " + monthDay($0, calendar: calendar) + "." })
        case "threads":
            guard let active = c.threadsActive, active > 0 else { return StoryCard(story: "No threads are active.") }
            if let newest = c.newestThread {
                return StoryCard(story: newest + " is the newest of \(active) active " + (active == 1 ? "thread." : "threads."), foot: "\(active) active")
            }
            return StoryCard(story: "\(active) " + (active == 1 ? "thread is" : "threads are") + " active.", foot: "\(active) active")
        case "sessions":
            let tag = c.sessionsWaiting > 0 ? "\(c.sessionsWaiting) waiting" : nil
            var story: String
            if c.agentsWorking == 0 && c.finishedHour == 0 { story = c.sessionsKnown ? "No agents are running." : "Claude, Codex and Cursor sessions on this Mac." }
            else {
                story = c.agentsWorking == 0 ? "No agents are working" : "\(c.agentsWorking) " + (c.agentsWorking == 1 ? "agent is working" : "agents are working")
                if c.finishedHour > 0 { story += " and \(c.finishedHour) finished in the last hour" }
                story += "."
            }
            let sub = c.sessionsWaiting == 0 ? nil : (c.sessionsWaiting == 1 ? "The waiting session is at the top of Needs you." : "The waiting sessions are at the top of Needs you.")
            return StoryCard(tag: tag, story: story, sub: sub)
        case "work", "tasks":
            let tag = (c.workNeedsYou ?? 0) > 0 ? "\(c.workNeedsYou!) needs you" : nil
            guard let older = c.olderToSort else { return StoryCard(tag: tag, story: "Your tasks, and what your meetings asked for.") }
            if older == 0 { return StoryCard(tag: tag, story: "Nothing is waiting to be sorted.") }
            return StoryCard(tag: tag, story: "\(older) older " + (older == 1 ? "suggestion is" : "suggestions are") + " waiting to be sorted.",
                             sub: "Today's suggestions stay on Today until midnight.")
        case "dictation":
            let story = c.dictationLast.map { calendar.isDate($0, inSameDayAs: now) ? "Your last dictation was at " + clock($0, calendar: calendar) + "."
                : "Your last dictation was on " + monthDay($0, calendar: calendar) + "." } ?? "Dictate anywhere on this Mac."
            let sub = c.dictationFixes > 0 ? (c.dictationFixes == 1 ? "1 fix is waiting." : "\(c.dictationFixes) fixes are waiting.") : (c.dictationLast == nil ? nil : "No fixes are waiting.")
            return StoryCard(tag: c.dictationFixes > 0 ? "\(c.dictationFixes) to check" : nil, story: story, sub: sub)
        default:
            return StoryCard(story: "")
        }
    }
}

/// Prep me and Return in the Ask box each start one Work run (a `claude -p` on the COS server): bounded here, on the
/// Control side, because the admission route has no per-day cap or breaker. Cap: 20 home-started runs per local day. Switch:
/// Settings, "Start Work runs from Today". Breaker: 3 admission failures in a row pause home starts for 15 minutes. One run in
/// flight per target (a meeting, or an ask). Work's own New is never counted or blocked.
struct TodayRunGuard {
    static let dailyCap = 20
    static let breakerFailures = 3
    static let breakerPause: TimeInterval = 15 * 60
    static let dayKey = "activityTodayRunDay"
    static let countKey = "activityTodayRunCount"
    static let failuresKey = "activityTodayRunFailures"
    static let pausedKey = "activityTodayRunPausedUntil"

    enum Admission: Equatable {
        case allowed
        case switchOff
        case capReached
        case paused(until: Date)
        case inFlight
    }

    let defaults: UserDefaults
    var calendar = Calendar.current

    func used(now: Date) -> Int {
        defaults.string(forKey: Self.dayKey) == ActivityHome.dayKey(now, calendar: calendar) ? defaults.integer(forKey: Self.countKey) : 0
    }
    func pausedUntil(now: Date) -> Date? {
        let raw = defaults.double(forKey: Self.pausedKey)
        guard raw > 0 else { return nil }
        let until = Date(timeIntervalSince1970: raw)
        return until > now ? until : nil
    }

    func admission(target: String, inFlight: Set<String>, switchOn: Bool, now: Date) -> Admission {
        guard switchOn else { return .switchOff }
        if inFlight.contains(target) { return .inFlight }
        if let until = pausedUntil(now: now) { return .paused(until: until) }
        if used(now: now) >= Self.dailyCap { return .capReached }
        return .allowed
    }

    /// Counted when the run is asked for, before the server answers: a refused start still used a try.
    func recordStart(now: Date) {
        let today = ActivityHome.dayKey(now, calendar: calendar)
        let count = defaults.string(forKey: Self.dayKey) == today ? defaults.integer(forKey: Self.countKey) : 0
        defaults.set(today, forKey: Self.dayKey)
        defaults.set(count + 1, forKey: Self.countKey)
    }

    func recordOutcome(admitted: Bool, now: Date) {
        guard !admitted else { defaults.set(0, forKey: Self.failuresKey); return }
        let failures = defaults.integer(forKey: Self.failuresKey) + 1
        if failures >= Self.breakerFailures {
            defaults.set(now.addingTimeInterval(Self.breakerPause).timeIntervalSince1970, forKey: Self.pausedKey)
            defaults.set(0, forKey: Self.failuresKey)
        } else {
            defaults.set(failures, forKey: Self.failuresKey)
        }
    }

    /// How one start ended. `notStarted`: refused before anything was recorded (Work was busy, an earlier run holds the
    /// target, no model): never a start and never a breaker failure. `refused`: the server did not admit it.
    enum Outcome: Equatable { case notStarted(String), admitted, refused(String) }
    static func outcome(receiptStatus: String?, error: String?) -> Outcome {
        guard let status = receiptStatus else { return .notStarted(error ?? "Nothing was started.") }
        if ["refused", "failed"].contains(status) { return .refused(error ?? "The server did not start it.") }
        return .admitted
    }
    /// The cap and the breaker count only starts that reached the server.
    func account(_ outcome: Outcome, now: Date) {
        switch outcome {
        case .notStarted: break
        case .admitted: recordStart(now: now); recordOutcome(admitted: true, now: now)
        case .refused: recordStart(now: now); recordOutcome(admitted: false, now: now)
        }
    }
    /// Checked before anything is recorded: Work is sending something else, or an earlier run still holds this target.
    static func preflight(busy: Bool, holds: Bool) -> String? {
        if busy { return "Work is sending something else. Try again in a moment." }
        if holds { return "This already has a run in Work. It shows in Sessions." }
        return nil
    }

    /// The words on the button when a start is not allowed.
    static func line(_ admission: Admission, calendar: Calendar = .current) -> String? {
        switch admission {
        case .allowed, .switchOff: nil
        // 0.5.337 (loop audit N6): when the limit lifts.
        case .capReached: "Today's limit of \(TodayRunGuard.dailyCap) runs on this Mac is reached. It resets at midnight; open Work to start more now."
        case .paused(let until): "Paused after 3 failed starts. Try again at " + TodayHome.clock(until, calendar: calendar) + "."
        case .inFlight: "Prep in Sessions"
        }
    }
}

/// The Today home's tick loop, apart from the view so a test can run it on a fake clock. One tick at a time; a tick only
/// while the window is visible (never minimized, hidden or closed); the first only after the window's opening loads are
/// done; a window that comes back gets a tick at once when the last is a minute old.
enum TodayTickLoop {
    static let interval: TimeInterval = 60
    static let step: TimeInterval = 1
    /// 0.5.337 (performance audit note): off screen the loop wakes every 5 s, not every second; coming back still ticks
    /// within one of these.
    static let hiddenStep: TimeInterval = 5
    static let readyLimit: TimeInterval = 60

    @MainActor
    static func run(now: () -> Date, visible: () -> Bool, ready: () -> Bool, tick: () async -> Void,
                    wait: (TimeInterval) async -> Bool) async {
        let start = now()
        while !ready(), now().timeIntervalSince(start) < readyLimit {
            guard await wait(0.5) else { return }
        }
        var last: Date?
        while true {
            if visible(), last.map({ now().timeIntervalSince($0) >= interval }) ?? true {
                last = now()
                await tick()
            }
            guard await wait(visible() ? step : hiddenStep) else { return }
        }
    }
}



// MARK: - Build-up, in place (0.5.343)

/// The approved loading reveal (operations/personal/wk43_2026/mock-skeleton/skeleton-reveal.html, "BUILD-UP, IN PLACE").
/// While a view waits on data, the wireframe of its final layout draws itself where the content will sit: (1) outlines
/// trace on, (2) four corner nodes pop, (3) traces wire each component to a spine on the left with a junction node, (4) the
/// text draws as outlined capsules. A short bright segment flows down the spine and each first corner node pings for
/// three cycles. When the data lands the content shows at once, readable and clickable, under a light tint that wipes
/// away left to right while the wire hands over to the real borders.
///
/// Rules (Miles's brief, the 6.10.654 QA and the 0.5.343 QA round 1), all executed by Tests/BuildUpChecks.swift:
///   - data inside 150 ms never builds; Reduce Motion keeps that grace, then shows today's loading view, never a wire;
///   - the build plays once per view per app session; a view whose last load was empty (kept across launches, by label
///     only) shows today's loading view with no wire; a search or tab switch during the first load settles quietly;
///   - the draw keeps its own clock through the landing; the settle is derived from the steps the stage draws;
///   - landed data is never hidden: the tint is at most 35% and gone within 300 ms; the landing ends within 450 ms;
///   - an error, an empty answer or the timeout never hides content: the wire fades over today's view;
///   - after 3 s today's loading words show and the wire text fades; the pulse stops after its cycles;
///   - the wire never adds height: inline views draw inside today's loading view, panes clip to themselves.
///
/// This half is pure (Foundation only) so the checks run it with Models.swift alone. The SwiftUI half is `COSBuildUp` in
/// COSMotion.swift, which draws every frame from `COSBuildUpPlan.look`.
enum COSBuildUpShape: Equatable, Sendable {
    /// Card rows (`cosRowCard`): a title, a meta line and two trailing pills.
    case rows(Int)
    /// Plain rows on a divided list: a title and a meta line.
    case list(Int)
    /// A detail page's body under a header that is already on screen: the summary card, then transcript turns.
    case summary(turns: Int)
    /// Transcript turns alone: a speaker capsule and a line each.
    case turns(Int)
    /// A Meeting Ask answer: drawn inside today's one-line "Checking the meeting…", re-fit to the real text when it lands.
    case answer
    /// Rows inside a Today card (Needs you, Running), drawn inside the card's loading line. `badge`: a platform badge leads.
    case cardRows(Int, badge: Bool)

    /// The breadcrumb's name for the shape (no user text ever goes in a breadcrumb).
    var kind: String {
        switch self {
        case .rows: return "rows"
        case .list: return "list"
        case .summary: return "summary"
        case .turns: return "turns"
        case .answer: return "answer"
        case .cardRows: return "cardRows"
        }
    }
}

/// A call site's own geometry where its rows differ from the shape's (the 0.5.343 QA: the wire sits where the rows sit).
struct COSBuildUpTune: Equatable, Sendable {
    var top: Double? = nil
    var leading: Double? = nil
    var trailing: Double? = nil
    var spacing: Double? = nil
    var rowHeight: Double? = nil
    static let none = COSBuildUpTune()
    // Meetings (the shape's default), Sessions, Memories, Threads and Messages: measured on the real rows, and held there by
    // the geometry parity check in Tests/BuildUpViewChecks.swift. Tasks and the voice directory: from their row layout code.
    static let sessions = COSBuildUpTune(top: 0)
    static let tasks = COSBuildUpTune(top: 0)
    static let memories = COSBuildUpTune(top: 1, spacing: 7, rowHeight: 78)
    static let threads = COSBuildUpTune(top: 1, spacing: 7, rowHeight: 60)
    static let messages = COSBuildUpTune(top: 21, spacing: 1, rowHeight: 79)
    /// The voice directory: its column header (about 32 pt), then 62 pt rows with a 1 pt rule (from the row's code).
    static let voices = COSBuildUpTune(top: 32, spacing: 1, rowHeight: 62)
}

struct COSBuildUpLine: Equatable, Sendable {
    /// A fraction of the row's inner width.
    var width: Double
    var height: Double
}

/// One component of a placeholder, at the size the stage lays it out. Heights are points.
struct COSBuildUpItem: Equatable, Sendable {
    enum Style: String, Sendable { case card, plain }
    var style: Style
    var height: Double
    var radius: Double
    var padH: Double
    var padV: Double
    var lines: [COSBuildUpLine]
    var lineGap: Double = 8
    /// Pills on the trailing edge, vertically centred (a meeting row's status pills), in points.
    var trailing: [Double] = []
    /// A fixed capsule leading the row on the same line (a turn's speaker, a run's platform badge), in points.
    var lead: Double? = nil
}

/// Where a stage's components sit inside the view, and where the spine runs.
struct COSBuildUpLayout: Equatable, Sendable {
    var top: Double
    var leading: Double
    var trailing: Double
    var spacing: Double
    /// The view fills its pane (a list, a detail). False: an inline component inside today's loading view.
    var fills: Bool
    /// The spine's x, from the view's leading edge. Nil: no traces (no room inside the view to the left).
    var spineX: Double?
}

struct COSBuildUpStep: Equatable, Sendable {
    var delay: Double
    var duration: Double
    var end: Double { delay + duration }
}

/// Every fraction one component draws at one moment: 0 to 1 (a node pop overshoots past 1 on its way in).
struct COSBuildUpLook: Equatable, Sendable {
    var outline: Double
    var nodes: Double
    var wireText: Double
    var wordsFade: Double
    var fill: Double
    var solid: Double
    var wireFade: Double
    var ink: Double
    var outlineFade: Double
    var nodeFade: Double
    /// What the outline actually shows: drawn so far, times what has not handed over yet.
    var outlineShown: Double { outline * (1 - outlineFade) }
    /// How visible the wire text is: drawn so far, gone when the words show or the data lands.
    var textShown: Double { wireText * (1 - wordsFade) * (1 - wireFade) }
}

enum COSBuildUpPlan {
    /// Never more placeholder components than this, and never more than fit the container.
    static let maxItems = 8
    /// Data inside this window after the load starts skips the build entirely (and under Reduce Motion, the spinner).
    static let graceSeconds = 0.15
    /// A view that opens before its load starts may still build when the load starts inside this window.
    static let freshSeconds = 1.0
    /// An error, an empty answer or the timeout: the wire fades over today's view this fast.
    static let handoffSeconds = 0.2
    /// After this long with no data, today's loading words show and the wire text fades away from them.
    static let wordsSeconds = 3.0
    static let wordsFadeStep = COSBuildUpStep(delay: wordsSeconds, duration: 0.3)
    /// The spine flow and the node ping run for three flows, then stop.
    static let pulseSeconds = flowStart + 3 * flowPeriod
    /// A load that has not answered by its timeout hands over to today's view. A call site passes its own helper's
    /// timeout plus `helperMargin` (Tasks, Sessions, Meeting Ask, learning); the rest wait `defaultTimeout`, the common
    /// 30 s helper timeout plus the margin.
    static let helperMargin = 5.0
    static let defaultTimeout = 30 + helperMargin
    /// The tint over landed content: never more than this, so the real text reads from the first frame.
    static let curtainAlpha = 0.35

    // Draw (the mock's numbers, seconds): from the moment the build starts, on its own clock through the landing.
    static let outline = 0.64, nodes = 0.26, wireText = 0.44, trace = 0.52, junction = 0.24
    static let drawStagger = 0.05, traceStagger = 0.045
    static let flowStart = 0.70, flowPeriod = 1.40, flowLength = 0.06, pingStart = 0.90, pingStagger = 0.12, pingPeriod = 4.0 / 3
    // Land (the 6.10.654 QA and round 1): the tint starts at the data and is gone by 300 ms for 8 rows; the outline
    // hands over by 450 ms.
    static let landStagger = 0.015, fill = 0.15, solid = 0.05, wireFade = 0.10, ink = 0.18
    static let outlineFadeLead = 0.10, outlineFade = 0.20, nodeFade = 0.10, tracesFade = 0.25
    /// ease-out cubic-bezier(.16,.84,.24,1); nodes pop on cubic-bezier(.3,1.6,.5,1).
    static let easeOut = (0.16, 0.84, 0.24, 1.0)
    static let pop = (0.3, 1.6, 0.5, 1.0)

    static func outlineStep(_ i: Int) -> COSBuildUpStep { .init(delay: Double(i) * drawStagger, duration: outline) }
    static func nodeStep(_ i: Int) -> COSBuildUpStep { .init(delay: Double(i) * drawStagger + 0.46, duration: nodes) }
    static func wireTextStep(_ i: Int) -> COSBuildUpStep { .init(delay: Double(i) * drawStagger + 0.30, duration: wireText) }
    static let spineStep = COSBuildUpStep(delay: 0, duration: trace)
    static func branchStep(_ i: Int) -> COSBuildUpStep { .init(delay: Double(i) * traceStagger + 0.16, duration: trace) }
    static func junctionStep(_ i: Int) -> COSBuildUpStep { .init(delay: Double(i) * traceStagger + 0.28, duration: junction) }
    static func pingDelay(_ i: Int) -> Double { Double(i) * pingStagger + pingStart }

    static func fillStep(_ i: Int) -> COSBuildUpStep { .init(delay: Double(i) * landStagger, duration: fill) }
    static func solidStep(_ i: Int) -> COSBuildUpStep { .init(delay: Double(i) * landStagger, duration: solid) }
    static func wireFadeStep(_ i: Int) -> COSBuildUpStep { .init(delay: Double(i) * landStagger, duration: wireFade) }
    static func inkStep(_ i: Int) -> COSBuildUpStep { .init(delay: Double(i) * landStagger, duration: ink) }
    static func outlineFadeStep(_ i: Int) -> COSBuildUpStep { .init(delay: Double(i) * landStagger + outlineFadeLead, duration: outlineFade) }
    static func nodeFadeStep(_ i: Int) -> COSBuildUpStep { .init(delay: Double(i) * landStagger, duration: nodeFade) }
    static let tracesFadeStep = COSBuildUpStep(delay: 0, duration: tracesFade)

    /// Every step the landing draws for component `i` (the settle time is derived from exactly these).
    static func landSteps(_ i: Int) -> [COSBuildUpStep] {
        [fillStep(i), solidStep(i), wireFadeStep(i), inkStep(i), outlineFadeStep(i), nodeFadeStep(i), tracesFadeStep]
    }
    static func drawSteps(_ i: Int) -> [COSBuildUpStep] {
        [outlineStep(i), nodeStep(i), wireTextStep(i), spineStep, branchStep(i), junctionStep(i)]
    }
    /// How long the landing runs for `count` components: the end of the last step of any of them.
    static func landDuration(count: Int) -> Double {
        (0..<max(1, min(count, maxItems))).flatMap(landSteps).map(\.end).max() ?? 0
    }
    /// How long the wire takes to finish drawing for `count` components.
    static func drawDuration(count: Int) -> Double {
        (0..<max(1, min(count, maxItems))).flatMap(drawSteps).map(\.end).max() ?? 0
    }

    /// The eased fraction of `step` at `t` seconds.
    static func progress(_ step: COSBuildUpStep, at t: Double, curve: (Double, Double, Double, Double) = easeOut) -> Double {
        guard step.duration > 0 else { return t >= step.delay ? 1 : 0 }
        let x = min(max((t - step.delay) / step.duration, 0), 1)
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        return bezier(x, curve)
    }

    /// cubic-bezier(x1,y1,x2,y2) at x, solved by bisection (monotone in x for every curve used here).
    static func bezier(_ x: Double, _ c: (Double, Double, Double, Double)) -> Double {
        func sample(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<40 {
            t = (lo + hi) / 2
            if sample(t, c.0, c.2) < x { lo = t } else { hi = t }
        }
        return sample(t, c.1, c.3)
    }

    /// Component `i` at `drawT` seconds into the build and `landT` seconds into the landing (nil before it lands). The draw
    /// never resets when the data lands: a wire the eye did not see drawn is never shown drawn.
    static func look(_ i: Int, drawT: Double, landT: Double?) -> COSBuildUpLook {
        func l(_ step: COSBuildUpStep) -> Double { landT.map { progress(step, at: $0) } ?? 0 }
        return COSBuildUpLook(outline: progress(outlineStep(i), at: drawT), nodes: progress(nodeStep(i), at: drawT, curve: pop),
                              wireText: progress(wireTextStep(i), at: drawT), wordsFade: progress(wordsFadeStep, at: drawT),
                              fill: l(fillStep(i)), solid: l(solidStep(i)), wireFade: l(wireFadeStep(i)), ink: l(inkStep(i)),
                              outlineFade: l(outlineFadeStep(i)), nodeFade: l(nodeFadeStep(i)))
    }

    /// The tint over the content to the right of component `i`'s ink edge: none while building (the content is hidden
    /// then), at most `curtainAlpha` from the moment the data lands, and gone when the ink has passed.
    static func curtain(_ look: COSBuildUpLook, landing: Bool) -> Double { landing ? curtainAlpha * (1 - look.ink) : 0 }

    /// Where the bright segment's head is on the spine (0 to 1), or nil once the pulse is over or before it starts.
    static func flow(drawT: Double) -> Double? {
        guard drawT >= flowStart, drawT < pulseSeconds else { return nil }
        return (drawT - flowStart).truncatingRemainder(dividingBy: flowPeriod) / flowPeriod
    }
    /// How far component `i`'s first-node ping has spread (0 to 1), or nil outside its cycles.
    static func ping(_ i: Int, drawT: Double) -> Double? {
        guard drawT >= pingDelay(i), drawT < pulseSeconds else { return nil }
        return (drawT - pingDelay(i)).truncatingRemainder(dividingBy: pingPeriod) / pingPeriod
    }

    /// Whether the content is hidden: only while the wire stands in for it before the words (and the 150 ms grace).
    /// Never in a hand-off: an error or empty view is there at once, with the wire fading over it.
    static func hides(_ phase: COSBuildUpMachine.Phase, wordsShown: Bool) -> Bool {
        phase == .grace || (phase == .building && !wordsShown)
    }

    /// The wire's colour on `luminance` (the background's relative luminance, 0 to 1): the mock's brown on a light
    /// surface, the brand gold on a dark one (the Running card is dark in both appearances), as sRGB plus alpha.
    static func wire(onLuminance luminance: Double) -> (r: Double, g: Double, b: Double, a: Double) {
        luminance < 0.18 ? (0.79, 0.66, 0.43, 0.72) : (137.0 / 255, 102.0 / 255, 45.0 / 255, 0.62)
    }
    /// The wire composited over `background` (sRGB), and its WCAG contrast against that background.
    static func contrast(wire w: (r: Double, g: Double, b: Double, a: Double), on background: (r: Double, g: Double, b: Double)) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func lum(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) }
        let mixed = (w.r * w.a + background.r * (1 - w.a), w.g * w.a + background.g * (1 - w.a), w.b * w.a + background.b * (1 - w.a))
        let a = lum(mixed.0, mixed.1, mixed.2), b = lum(background.r, background.g, background.b)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    static func layout(_ shape: COSBuildUpShape, _ tune: COSBuildUpTune = .none) -> COSBuildUpLayout {
        var base: COSBuildUpLayout
        switch shape {
        case .rows: base = .init(top: 12, leading: 22, trailing: 22, spacing: 6, fills: true, spineX: 10)
        case .list: base = .init(top: 8, leading: 22, trailing: 22, spacing: 6, fills: true, spineX: 10)
        case .summary: base = .init(top: 18, leading: 24, trailing: 24, spacing: 12, fills: true, spineX: 11)
        case .turns: base = .init(top: 16, leading: 24, trailing: 24, spacing: 12, fills: true, spineX: 11)
        case .answer: base = .init(top: 0, leading: 0, trailing: 0, spacing: 0, fills: false, spineX: nil)
        case .cardRows(_, let badge): base = .init(top: 0, leading: badge ? 0 : 18, trailing: badge ? 0 : 18, spacing: 4, fills: false,
                                                   spineX: badge ? nil : 8)
        }
        if let v = tune.top { base.top = v }
        if let v = tune.leading { base.leading = v }
        if let v = tune.trailing { base.trailing = v }
        if let v = tune.spacing { base.spacing = v }
        return base
    }

    private static let titles = [0.62, 0.48, 0.56, 0.44, 0.52]
    private static let metas = [0.40, 0.36, 0.30, 0.42, 0.34]
    private static let says = [0.70, 0.62, 0.58, 0.66, 0.54]
    /// A Meeting Ask answer line: the capsule and the pitch of 13 pt body text.
    static let answerLine = 10.0, answerPitch = 17.5

    /// The components a shape draws. At most `limit` and `maxItems`; with `fitting`, only as many as fit that many points
    /// of height, and when even one does not fit (an inline view inside its one-line loading view) that one is squeezed
    /// to the room, keeping the lines that fit. `measured`: a landed answer's real height, to re-fit its lines.
    static func items(_ shape: COSBuildUpShape, _ tune: COSBuildUpTune = .none, limit: Int? = nil, fitting height: Double? = nil,
                      measured: Double? = nil) -> [COSBuildUpItem] {
        let cap = min(maxItems, limit ?? maxItems)
        func n(_ asked: Int) -> Int { max(0, min(asked, cap)) }
        var all: [COSBuildUpItem]
        switch shape {
        case .rows(let count):
            all = (0..<n(count)).map { i in
                COSBuildUpItem(style: .card, height: 62, radius: 10, padH: 14, padV: 13,
                               lines: [.init(width: titles[i % 5], height: 12), .init(width: metas[i % 5], height: 9)],
                               lineGap: 9, trailing: [30, 30])
            }
        case .list(let count):
            all = (0..<n(count)).map { i in
                COSBuildUpItem(style: .plain, height: 48, radius: 8, padH: 10, padV: 10,
                               lines: [.init(width: titles[i % 5], height: 11), .init(width: metas[i % 5], height: 8)], lineGap: 8)
            }
        case .summary(let turns):
            all = Array(([summaryCard] + (0..<max(0, turns)).map(turn)).prefix(cap))
        case .turns(let count):
            all = (0..<n(count)).map(turn)
        case .answer:
            let lines = measured.map { max(1, min(maxItems, Int(($0 / answerPitch).rounded()))) } ?? 1
            let widths = [0.92, 0.84, 0.88, 0.80, 0.86, 0.90, 0.82, 0.58]
            all = cap < 1 ? [] : [COSBuildUpItem(style: .plain, height: measured ?? 18, radius: 4, padH: 0, padV: 4,
                                                 lines: (0..<lines).map { .init(width: $0 == lines - 1 && lines > 1 ? 0.58 : widths[$0], height: answerLine) },
                                                 lineGap: answerPitch - answerLine)]
        case .cardRows(let count, let badge):
            all = (0..<n(count)).map { i in
                COSBuildUpItem(style: .plain, height: 46, radius: 8, padH: badge ? 8 : 0, padV: 8,
                               lines: [.init(width: titles[i % 5] + 0.18, height: 11), .init(width: metas[i % 5] + 0.12, height: 8)],
                               lineGap: 7, lead: badge ? 84 : nil)
            }
        }
        if let row = tune.rowHeight { all = all.map { var item = $0; item.height = row; return item } }
        guard let height else { return all }
        let layout = layout(shape, tune)
        let room = max(0, height - layout.top)
        var used = 0.0
        var fitted: [COSBuildUpItem] = []
        for item in all {
            let next = used + (fitted.isEmpty ? 0 : layout.spacing) + item.height
            if next > room {
                if fitted.isEmpty, room >= 6 { fitted.append(squeezed(item, to: room)) }
                break
            }
            fitted.append(item)
            used = next
        }
        return fitted
    }

    /// `item` made to fit `room` points: its padding shrinks first, then lines that do not fit drop.
    static func squeezed(_ item: COSBuildUpItem, to room: Double) -> COSBuildUpItem {
        var out = item
        out.height = room
        out.padV = min(item.padV, max(1, room / 6))
        var lines: [COSBuildUpLine] = []
        var used = 0.0
        for line in item.lines {
            let next = used + (lines.isEmpty ? 0 : item.lineGap) + line.height
            if next > room - 2 * out.padV { break }
            lines.append(line)
            used = next
        }
        if lines.isEmpty, let first = item.lines.first { lines = [.init(width: first.width, height: max(2, min(first.height, room - 2 * out.padV)))] }
        out.lines = lines
        out.trailing = room >= 20 ? item.trailing : []
        out.lead = item.lead
        return out
    }

    private static let summaryCard = COSBuildUpItem(style: .card, height: 78, radius: 9, padH: 12, padV: 12,
                                                    lines: [.init(width: 0.22, height: 7), .init(width: 0.94, height: 10), .init(width: 0.76, height: 10)])

    private static func turn(_ i: Int) -> COSBuildUpItem {
        COSBuildUpItem(style: .plain, height: 24, radius: 4, padH: 0, padV: 6, lines: [.init(width: says[i % 5], height: 10)], lead: 58)
    }

    /// The top of component `index` from the view's top edge, and the y a trace meets it at (the mock's min(18, h/2)).
    static func top(_ index: Int, in items: [COSBuildUpItem], layout: COSBuildUpLayout) -> Double {
        layout.top + items.prefix(index).reduce(0) { $0 + $1.height + layout.spacing }
    }
    static func junctionY(_ index: Int, in items: [COSBuildUpItem], layout: COSBuildUpLayout) -> Double {
        top(index, in: items, layout: layout) + min(18, items[index].height / 2)
    }
    /// The height a stage's components take.
    static func height(_ items: [COSBuildUpItem], layout: COSBuildUpLayout) -> Double {
        items.isEmpty ? 0 : top(items.count - 1, in: items, layout: layout) + items[items.count - 1].height
    }

    /// One log line per load the build was ready for: counts and verdicts only, never a label, a title or user text.
    static func breadcrumb(_ shape: COSBuildUpShape, outcome: COSBuildUpMachine.Outcome, rows: Int, ms: Int) -> String {
        "build-up \(shape.kind) outcome=\(outcome.rawValue) rows=\(rows) ms=\(ms)"
    }
}

/// What COS remembers per view. `seen` (this app session, per label and key): a view seen once reopens quietly. `empty`
/// (kept across launches by the view layer, label keys only, at most `emptyLimit`): a view whose last load came back
/// empty (never an error) shows today's loading view with no wire, so it never draws rows that will not come; the first
/// time it has data again, it is cleared (the view records .landed even when it opened quiet).
struct COSBuildUpMemory: Equatable, Sendable {
    static let emptyLimit = 64
    private(set) var seen: Set<String> = []
    private(set) var empty: [String] = []

    init(empty: [String] = []) { self.empty = Array(empty.suffix(Self.emptyLimit)) }

    /// Whether the next open of `key` may build.
    func builds(_ key: String) -> Bool { !seen.contains(key) && !empty.contains(key) }

    /// Records how a load ended. Returns true when the persisted empty list changed.
    @discardableResult
    mutating func record(_ key: String, _ outcome: COSBuildUpMachine.Outcome, persists: Bool) -> Bool {
        if outcome != .interrupted && outcome != .abandoned { seen.insert(key) }
        guard persists else { return false }
        let before = empty
        switch outcome {
        case .empty:
            empty.removeAll { $0 == key }
            empty.append(key)
            if empty.count > Self.emptyLimit { empty.removeFirst(empty.count - Self.emptyLimit) }
        case .landed, .direct:
            empty.removeAll { $0 == key }
        default:
            // An error, a timeout, Reduce Motion, an interruption or an abandoned build says nothing about emptiness.
            break
        }
        return empty != before
    }
}

/// The build's state machine. Times are seconds on any monotonic clock.
///
///   fresh    the view is open and its load has not started: today's view shows, and a load that starts within
///            `freshSeconds` may still build
///   grace    the load started: nothing shows for `graceSeconds`, so a fast or cached load never flashes
///   building the wire is on screen (today's loading words join it after `wordsSeconds`)
///   landing  the data landed: the content shows at once under a fading tint while the wire hands over
///   handoff  no data (an error, an empty answer, or the timeout): today's view shows at once, the wire fades over it
///   settled  today's view, for good: a later refresh or poll swaps exactly as before and never builds again
struct COSBuildUpMachine: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable { case fresh, grace, building, landing, handoff, settled }
    /// How the load the build was ready for ended (the breadcrumb). `still`: Reduce Motion. `interrupted`: a search or tab
    /// switch took the view elsewhere. `abandoned`: the view went away or showed something else mid-build. `failed`: the
    /// load ended with an error (never remembered as empty).
    enum Outcome: String, Equatable, Sendable { case direct, landed, empty, failed, timeout, still, interrupted, abandoned }

    private(set) var phase: Phase
    private(set) var since: Double
    private(set) var opened: Double
    /// The components the build drew (fitted to the container); the landing's length follows it.
    private(set) var count: Int
    /// Reduce Motion, latched: once on, this machine never draws a wire again.
    private(set) var reduced: Bool
    let timeout: Double
    private(set) var loadStarted: Double?
    private(set) var builtAt: Double?
    private(set) var landedAt: Double?
    private(set) var outcome: Outcome?
    private(set) var outcomeAt: Double?
    /// Flags the machine sets as it passes each moment, so every change is a state change the view redraws on.
    private(set) var drawDone = false
    private(set) var wordsShown = false
    private(set) var wordsFaded = false
    private(set) var pulseDone = false

    /// `quiet`: this session has seen this view, or its last load was empty: today's view, no build.
    init(at t: Double, loading: Bool, landed: Bool, reduceMotion: Bool, count: Int, quiet: Bool = false, timeout: Double = COSBuildUpPlan.defaultTimeout) {
        opened = t
        since = t
        self.count = max(0, min(count, COSBuildUpPlan.maxItems))
        self.reduced = reduceMotion
        self.timeout = timeout
        if landed || self.count == 0 || quiet { phase = .settled }
        else if loading { phase = .grace; loadStarted = t }
        else { phase = .fresh }
    }

    var hidesContent: Bool { COSBuildUpPlan.hides(phase, wordsShown: wordsShown) }
    var drawsWire: Bool { phase == .building || phase == .landing || phase == .handoff }
    /// The spine flow and the node ping: only while building, only for their cycles, only while the window is active.
    func pulses(windowActive: Bool) -> Bool { phase == .building && windowActive && !pulseDone }
    /// Whether the stage needs a new frame at all: while the wire draws, while it pulses, while the wire text fades from
    /// the words (in any window), while it lands or hands off. Never once it stands still, so nothing redraws while a
    /// slow load waits.
    func needsFrames(windowActive: Bool) -> Bool {
        switch phase {
        case .building: return !drawDone || pulses(windowActive: windowActive) || (wordsShown && !wordsFaded)
        case .landing, .handoff: return true
        default: return false
        }
    }

    func drawT(at t: Double) -> Double? { builtAt.map { t - $0 } }
    func landT(at t: Double) -> Double? { phase == .landing ? landedAt.map { t - $0 } : nil }
    func handoffT(at t: Double) -> Double? { phase == .handoff ? t - since : nil }

    /// The next moment the machine changes on its own (nil once it never will, so nothing keeps waking). Each moment it
    /// passes sets a flag, so the next read names the one after it.
    var deadline: Double? {
        switch phase {
        case .fresh: return opened + COSBuildUpPlan.freshSeconds
        case .grace: return since + COSBuildUpPlan.graceSeconds
        case .building:
            let start = builtAt ?? since
            var next = [start + timeout]
            if !drawDone { next.append(start + COSBuildUpPlan.drawDuration(count: count)) }
            if !wordsShown { next.append(start + COSBuildUpPlan.wordsSeconds) }
            if !wordsFaded { next.append(start + COSBuildUpPlan.wordsFadeStep.end) }
            if !pulseDone { next.append(start + COSBuildUpPlan.pulseSeconds) }
            return next.min()
        case .landing: return (landedAt ?? since) + COSBuildUpPlan.landDuration(count: count)
        case .handoff: return since + COSBuildUpPlan.handoffSeconds
        case .settled: return nil
        }
    }

    /// Feed every change: the clock, whether the view is loading, whether data has landed, Reduce Motion, whether a search
    /// or tab switch has taken the view elsewhere, and whether the load failed (an error is never an empty answer).
    @discardableResult
    mutating func update(at t: Double, loading: Bool, landed: Bool, reduceMotion turnedOn: Bool = false, interrupted: Bool = false,
                         failed: Bool = false) -> Phase {
        if interrupted, phase == .fresh {
            // The load never started: nothing to log.
            move(.settled, t)
            return phase
        }
        if interrupted, phase == .grace || phase == .building || phase == .landing {
            settle(t, .interrupted)
            return phase
        }
        if turnedOn { reduced = true }
        if turnedOn, phase == .building || phase == .landing { settle(t, .still) }
        switch phase {
        case .fresh:
            if landed { move(.settled, t) }
            else if loading { move(.grace, t); loadStarted = t }
            else if t >= opened + COSBuildUpPlan.freshSeconds { move(.settled, t) }
        case .grace:
            if !loading { settle(t, landed ? .direct : (failed ? .failed : .empty)) }
            else if t >= since + COSBuildUpPlan.graceSeconds {
                if reduced { settle(t, .still) } else { move(.building, t); builtAt = t }
            }
        case .building:
            let start = builtAt ?? since
            if !loading {
                if landed { move(.landing, t); landedAt = t; finish(t, .landed) } else { move(.handoff, t); finish(t, failed ? .failed : .empty) }
            } else if t >= start + timeout {
                move(.handoff, t); finish(t, .timeout)
            } else {
                if t >= start + COSBuildUpPlan.drawDuration(count: count) { drawDone = true }
                if t >= start + COSBuildUpPlan.wordsSeconds { wordsShown = true }
                if t >= start + COSBuildUpPlan.wordsFadeStep.end { wordsFaded = true }
                if t >= start + COSBuildUpPlan.pulseSeconds { pulseDone = true }
            }
        case .landing:
            // A new load mid-landing: settle the old one first, then today's view takes the new load.
            if loading || t >= (landedAt ?? since) + COSBuildUpPlan.landDuration(count: count) { move(.settled, t) }
        case .handoff:
            if t >= since + COSBuildUpPlan.handoffSeconds { move(.settled, t) }
        case .settled:
            break
        }
        return phase
    }

    /// The view went away or now shows something else while it was still waiting. Returns true when that abandons a load
    /// the build was ready for (the view logs it); the machine settles.
    @discardableResult
    mutating func abandon(at t: Double) -> Bool {
        guard phase == .grace || phase == .building else { return false }
        settle(t, .abandoned)
        return true
    }

    /// The container's room changed while building (a window resize): the wire follows it.
    mutating func fit(_ n: Int) {
        guard phase == .building || phase == .grace else { return }
        count = max(1, min(n, COSBuildUpPlan.maxItems))
    }

    private mutating func settle(_ t: Double, _ how: Outcome) {
        if outcome == nil { finish(t, how) }
        move(.settled, t)
    }
    private mutating func finish(_ t: Double, _ how: Outcome) {
        outcome = how
        outcomeAt = t
    }
    private mutating func move(_ next: Phase, _ t: Double) {
        phase = next
        since = t
    }
}
