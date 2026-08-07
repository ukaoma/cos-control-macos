import AppKit
import Foundation

@main
struct ModelsContract {
    private static func attachment(_ idDigit: Character, timestamp: String, width: Double = 640) -> [String: JSONValue] {
        [
            "id": .string("m_" + String(repeating: String(idDigit), count: 24)),
            "kind": .string("user_photo"),
            "mime": .string("image/png"),
            "width": .number(width),
            "height": .number(480),
            "createdAt": .string(timestamp),
        ]
    }

    /// A speaker row, built from the shape the server actually sends.
    private static func voice(
        label: String, reliability: String, isOwner: Bool = false, segments: Int = 12
    ) -> ReviewVoice? {
        ReviewVoice(.object([
            "label": .string(label),
            "segments": .number(Double(segments)),
            "isOwner": .bool(isOwner),
            "reliability": .string(reliability),
            "nameAsserted": .bool(reliability == "confident"),
            "assertionBlockers": .array([]),
            "thrashesWith": .array([]),
            "phrases": .array([]),
        ]))
    }

    /// Who may be renamed, and who may never be.
    ///
    /// Regression: `canRename` excluded `.unattributed` while the row's copy read
    /// "Give it one from the list above" — the panel instructed an action it then
    /// refused to offer. Naming an unheard voice is the entire point of reviewing
    /// one, and the server always supported it.
    private static func checkRenameEligibility() {
        // The fix, stated as behaviour.
        precondition(voice(label: "Ext", reliability: "unattributed")?.canRename == true,
                     "an unattributed voice must be nameable")
        precondition(voice(label: "Unidentified 2", reliability: "unattributed")?.canRename == true,
                     "a numbered unattributed voice must be nameable")

        // Unchanged, and the reason the guard exists at all: the wearer is
        // established by the device, not by cosine, and absorbing them into
        // another profile would break identification for every later chunk.
        precondition(voice(label: "MU", reliability: "confident", isOwner: true)?.canRename == false,
                     "the owner must never be renameable")
        precondition(voice(label: "MU", reliability: "unattributed", isOwner: true)?.canRename == false,
                     "the owner must never be renameable, even unattributed")

        // Still true for ordinary rows.
        precondition(voice(label: "Queen Ukaoma", reliability: "confident")?.canRename == true)
        precondition(voice(label: "Luke Henry", reliability: "weak")?.canRename == true)

        // Naming an unattributed row is an ASSIGNMENT, and the confirm card says
        // so — a large unmatched cluster is frequently several people.
        precondition(voice(label: "Ext", reliability: "unattributed")?.isNameAssignment == true)
        precondition(voice(label: "Queen Ukaoma", reliability: "confident")?.isNameAssignment == false)

        // De-attribution stays scoped to rows that actually carry a name: there
        // is nothing to take back from a voice nobody was ever called.
        precondition(voice(label: "Ext", reliability: "unattributed")?.canDeattribute == false)
        precondition(voice(label: "Queen Ukaoma", reliability: "confident")?.canDeattribute == true)
    }

    /// A meetings row as the HELPER now projects it.
    private static func meetingRow(
        topics: Int = 4, decisions: Int = 2,
        actions: Int = 1, attendees: Int = 3, source: String = "G2 Glasses"
    ) -> ReviewableMeeting? {
        ReviewableMeeting(.object([
            "sessionId": .string("meeting_1786073313411_d77gck"),
            "title": .string("Crypto Clarity Act Senate Standoff (G2)"),
            "date": .string("2026-08-06"),
            "domain": .string("personal"),
            "duration": .string("8 minutes"),
            "month": .string("2026-08"),
            "filename": .string("2026-08-06_Crypto_Clarity_Act_Senate_Standoff_(G2).md"),
            "source": .string(source),
            // Numbers, matching the wire. String fixtures hid a real blank-count bug.
            "topicCount": .number(Double(topics)),
            "decisionCount": .number(Double(decisions)),
            "actionCount": .number(Double(actions)),
            "attendeeCount": .number(Double(attendees)),
        ]))
    }

    /// The fields the helper projection must actually deliver.
    ///
    /// Regression: these were dropped in `emitMeetings`, not in this model, and
    /// `ReviewableMeeting.init?` defaults every non-sessionId field to "" — so a
    /// broken projection yields empty strings with no compile error and no test
    /// failure. Only an execution check catches it.
    private static func checkMeetingRowFields() {
        guard let row = meetingRow() else { preconditionFailure("row failed to parse") }

        // Join keys for the meeting-detail route.
        precondition(row.month == "2026-08", "month must survive the helper projection")
        precondition(row.filename.hasSuffix(".md"), "filename must survive the helper projection")
        precondition(!row.filename.isEmpty)

        // Counts arrive as STRINGS in this payload, not numbers.
        precondition(row.topicCount == 4, "topicCount must parse from a JSON number")
        precondition(row.decisionCount == 2)
        precondition(row.actionCount == 1)
        precondition(row.attendeeCount == 3)
    }

    /// The subtitle, including the case that would otherwise render blank.
    private static func checkCountsSummary() {
        precondition(meetingRow()?.countsSummary == "4 topics · 2 decisions · 1 action · 3 attendees")

        // Singulars, so a one-topic meeting does not read "1 topics".
        precondition(meetingRow(topics: 1, decisions: 0, actions: 0, attendees: 1)?
            .countsSummary == "1 topic · 1 attendee")

        // Zeros are omitted rather than printed as "0 decisions".
        precondition(meetingRow(topics: 5, decisions: 0, actions: 0, attendees: 0)?
            .countsSummary == "5 topics")

        // ALL zero falls back to the capture source. An empty line here reads as
        // a rendering bug rather than as a meeting with no extracted structure.
        precondition(meetingRow(topics: 0, decisions: 0, actions: 0, attendees: 0,
                                source: "Granola")?.countsSummary == "Granola")
    }

    static func main() throws {
        checkRenameEligibility()
        checkMeetingRowFields()
        checkCountsSummary()

        precondition(GlassesAttachmentRef(object: attachment("a", timestamp: "2026-08-03T12:00:00.000Z")) != nil)
        precondition(GlassesAttachmentRef(object: attachment("b", timestamp: "2026-08-03T12:00:00.123Z")) != nil)
        precondition(GlassesAttachmentRef(object: attachment("c", timestamp: "2026-08-03T12:00:00Z")) != nil)
        precondition(GlassesAttachmentRef(object: attachment("d", timestamp: "not-a-date")) == nil)
        precondition(GlassesAttachmentRef(object: attachment("e", timestamp: "2026-08-03T12:00:00Z", width: .infinity)) == nil)
        precondition(GlassesAttachmentRef(object: attachment("f", timestamp: "2026-08-03T12:00:00Z", width: 1e100)) == nil)

        let refs = (0..<6).map { index -> JSONValue in
            let digit = Character(String(index))
            return .object(attachment(digit, timestamp: "2026-08-03T12:00:00.000Z"))
        }
        let turn = GlassesTurn([
            "query": .string("photo"),
            "text": .string("answer"),
            "sessionId": .string("session"),
            "source": .string("live"),
            "attachments": .array(refs),
        ])
        precondition(turn?.attachments.count == 5)

        let status = ServerStatus([
            "meetingPreviewSupported": .bool(true),
            "meetingPreviewEnabled": .bool(true),
            "idleMetalHqSupported": .bool(true),
            "idleMetalHqEnabled": .bool(true),
            "idleMetalHqForceCpu": .bool(false),
        ])
        precondition(status.meetingPreviewSupported && status.meetingPreviewEnabled == true)
        precondition(status.idleMetalHqSupported && status.idleMetalHqEnabled == true && status.idleMetalHqForceCpu == false)

        // Decode into an owned in-memory image before deleting the source.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try png.write(to: source, options: .atomic)
        let decoded = RecentMediaImageDecoder.decode(url: source, expectedBytes: png.count)
        try FileManager.default.removeItem(at: source)
        precondition(decoded?.tiffRepresentation != nil)

        print("COS Control: Swift attachment parsing and owned-image decoding passed")
    }
}
