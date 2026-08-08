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
    var safeToRestart = false
    var activeJobs: Int?
    var activeTranscriptionSessions: Int?
    var backgroundJobsSupported = false
    var backgroundJobsEnabled: Bool?
    var meetingPreviewSupported = false
    var meetingPreviewEnabled: Bool?
    var idleMetalHqSupported = false
    var idleMetalHqEnabled: Bool?
    var idleMetalHqForceCpu: Bool?
    var whisperReady = false
    var whisperCircuitOpen = false
    var whisperStartupState: String?
    var whisperError: String?
    var livePreviewModel: String?
    var livePreviewReady: Bool?
    var livePreviewDegraded = false
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
        safeToRestart = details["safeToRestart"]?.bool ?? false
        activeJobs = details["activeJobs"]?.int
        activeTranscriptionSessions = details["activeTranscriptionSessions"]?.int
        backgroundJobsSupported = details["backgroundJobsSupported"]?.bool ?? false
        backgroundJobsEnabled = details["backgroundJobsEnabled"]?.bool
        meetingPreviewSupported = details["meetingPreviewSupported"]?.bool ?? false
        meetingPreviewEnabled = details["meetingPreviewEnabled"]?.bool
        idleMetalHqSupported = details["idleMetalHqSupported"]?.bool ?? false
        idleMetalHqEnabled = details["idleMetalHqEnabled"]?.bool
        idleMetalHqForceCpu = details["idleMetalHqForceCpu"]?.bool
        whisperReady = details["whisperReady"]?.bool ?? false
        whisperCircuitOpen = details["whisperCircuitOpen"]?.bool ?? false
        whisperStartupState = details["whisperStartupState"]?.string
        whisperError = details["whisperError"]?.string
        livePreviewModel = details["livePreviewModel"]?.string
        livePreviewReady = details["livePreviewReady"]?.bool
        livePreviewDegraded = details["livePreviewDegraded"]?.bool ?? false
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
        claudeCliVersion = details["claudeCliVersion"]?.string
        codexCliReady = details["codexCliReady"]?.bool
        codexCliVersion = details["codexCliVersion"]?.string
        cursorCliVersion = details["cursorCliVersion"]?.string
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

    init?(object: [String: JSONValue]) {
        guard let id = object["id"]?.string,
              id.count == 26, id.hasPrefix("m_"),
              id.dropFirst(2).allSatisfy({ "0123456789abcdef".contains($0) }),
              let kind = object["kind"]?.string,
              ["user_photo", "traffic_frame", "generated_visual"].contains(kind),
              let mime = object["mime"]?.string,
              ["image/jpeg", "image/png"].contains(mime),
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
    }

    private static func validTimestamp(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        let wholeSecond = ISO8601DateFormatter()
        wholeSecond.formatOptions = [.withInternetDateTime]
        return wholeSecond.date(from: value) != nil
    }

    var isUserPhoto: Bool { kind == "user_photo" }
    var displayLabel: String { isUserPhoto ? "Your image" : "Answer image" }
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

    var timeLabel: String {
        guard let timestamp else { return "--:--" }
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
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

/// Result of the P1 check-only update probe. Carries no ability to apply anything:
/// the only action it enables is opening the download page in a browser.
struct AppUpdateInfo: Sendable {
    var updateAvailable = false
    var latestVersion: String?
    var latestBuild: Int?
    var url: String?
    var notes: String?
    /// newer / upToDate / killSwitch / unreachable / malformed / idle
    var reason: String = "idle"

    init() {}

    init(_ details: [String: JSONValue]) {
        updateAvailable = details["updateAvailable"]?.bool ?? false
        latestVersion = details["latestVersion"]?.string
        latestBuild = details["latestBuild"]?.int
        url = details["url"]?.string
        notes = details["notes"]?.string
        reason = details["reason"]?.string ?? "idle"
    }

    /// Only a reachable, well-formed, genuinely-newer appcast may surface UI.
    var shouldSurface: Bool { updateAvailable && latestVersion != nil }
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
}

/// How far a correction reaches.
///
/// `thisMeeting` is the DEFAULT and the reason this type exists. Until 0.5.0 the
/// panel only ever called the global merge, so renaming a voice rewrote every
/// meeting that person appears in — Miles: "I thought that what we wanted to do
/// was make this much more segmented." A voice misheard in one room is not
/// evidence that every past attribution was wrong.
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
            // Deliberately does NOT claim to train the profile. The
            // correction-to-enrolment path is not built: the per-chunk embedding
            // store is write-only today and nothing writes `correction:` provenance.
            return "Corrects this meeting only. Other meetings are left alone."
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
    /// Training samples this correction would retract from the profile.
    let wouldRetract: Int
    /// Samples that predate meeting-level provenance and cannot be retracted.
    let untraceable: Int

    var id: String { "\(from)->\(to ?? "«unidentified»")@\(scope.rawValue)" }
    var isDeattribution: Bool { to == nil }
}
