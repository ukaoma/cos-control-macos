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

    private static func confirmableVoice(
        label: String, reliability: String, asserted: Bool,
        isOwner: Bool = false, confirmed: Bool = false
    ) -> ReviewVoice? {
        ReviewVoice(.object([
            "label": .string(label),
            "segments": .number(1),
            "isOwner": .bool(isOwner),
            "reliability": .string(reliability),
            "nameAsserted": .bool(asserted),
            "confirmedByHuman": .bool(confirmed),
            "assertionBlockers": .array([.string("similarity 0.56 below 0.65")]),
            "thrashesWith": .array([]),
            "phrases": .array([]),
        ]))
    }

    /// Who can have their own candidate name vouched for.
    ///
    /// The case that prompted this: a row displaying "Unidentified voice" whose
    /// LABEL is already "Queen Ukaoma" at 0.56. A rename cannot express it
    /// (from == to is rejected server-side) and the match list excluded the
    /// name, so the panel offered no way forward at all.
    private static func checkConfirmEligibility() {
        precondition(confirmableVoice(label: "Queen Ukaoma", reliability: "weak", asserted: false)?
            .canConfirmCandidate == true, "a demoted candidate must be confirmable")
        precondition(confirmableVoice(label: "Luke Henry", reliability: "unreliable", asserted: false)?
            .canConfirmCandidate == true, "an unreliable candidate must be confirmable")

        // Nothing to confirm: no candidate was ever proposed.
        precondition(confirmableVoice(label: "Ext", reliability: "unattributed", asserted: false)?
            .canConfirmCandidate == false, "an unattributed row has no candidate")
        // Already asserted — confirming adds nothing.
        precondition(confirmableVoice(label: "Gina Obert", reliability: "confident", asserted: true)?
            .canConfirmCandidate == false, "an asserted name needs no confirmation")
        // The wearer is established by the device, not by vouching.
        precondition(confirmableVoice(label: "MU", reliability: "weak", asserted: false, isOwner: true)?
            .canConfirmCandidate == false, "the owner is never confirmed this way")
        // Idempotent: the button disappears once it has been used.
        precondition(confirmableVoice(label: "Queen Ukaoma", reliability: "weak", asserted: true, confirmed: true)?
            .canConfirmCandidate == false, "an already-confirmed row stops offering it")
        // Defensive, and the only case that actually exercises the confirmed
        // term: a server reporting confirmed WITHOUT asserting would be a bug,
        // and re-offering the action would append a second identical row to an
        // append-only ledger. The mutation that removes `!confirmedByHuman`
        // passes without this, because `!nameAsserted` short-circuits above.
        precondition(confirmableVoice(label: "Queen Ukaoma", reliability: "weak", asserted: false, confirmed: true)?
            .canConfirmCandidate == false, "confirmed never re-offers, even if the server did not assert")

        // Old server: the flag is absent, which must read as not-confirmed
        // rather than crashing or defaulting to true.
        let legacy = ReviewVoice(.object([
            "label": .string("Queen Ukaoma"), "segments": .number(1), "isOwner": .bool(false),
            "reliability": .string("weak"), "nameAsserted": .bool(false),
            "assertionBlockers": .array([]), "thrashesWith": .array([]), "phrases": .array([]),
        ]))
        precondition(legacy?.confirmedByHuman == false, "absent flag reads as not confirmed")
        precondition(legacy?.canConfirmCandidate == true, "an old server still offers the action")
    }

    /// A review payload, optionally carrying the 6.21.26+ coverage field.
    private static func review(assertedSegments: Int?) -> SpeakerReview? {
        var o: [String: JSONValue] = [
            "sessionId": .string("meeting_1786109145248_0i1xv3"),
            "title": .string("International TEFL Engagement Scoping"),
            "segments": .number(379),
            "attributed": .bool(true),
            "durationMs": .number(1_800_000),
            "voices": .array([]),
            "timeline": .array([]),
        ]
        if let a = assertedSegments { o["assertedSegments"] = .number(Double(a)) }
        return SpeakerReview(.object(o))
    }

    /// An older server omits `assertedSegments`. It must read as UNKNOWN, never
    /// as zero: the house `?? 0` would render "0 of 379 segments named" on a
    /// perfectly well-attributed meeting — a confident false statement, and the
    /// same class as the 404-means-audio-expired bug guarded in run.sh.
    private static func checkAssertedSegmentsBackCompat() {
        precondition(review(assertedSegments: 177)?.assertedSegments == 177, "present value decodes")
        precondition(review(assertedSegments: 0)?.assertedSegments == 0, "a real zero survives")
        precondition(review(assertedSegments: nil)?.assertedSegments == nil, "absent must be nil, NOT 0")
        // The rest of the struct still decodes when the field is missing.
        precondition(review(assertedSegments: nil)?.segments == 379, "old server still usable")
    }

    /// Talk time must never be invented for a voice the panel will not name,
    /// and must read as UNKNOWN rather than zero on a server that omits it.
    private static func checkSpeakingTime() {
        func rv(_ label: String, _ ms: Int?, asserted: Bool) -> ReviewVoice? {
            var o: [String: JSONValue] = [
                "label": .string(label), "segments": .number(12),
                "reliability": .string(asserted ? "confident" : "weak"),
                "nameAsserted": .bool(asserted), "assertionBlockers": .array([]),
                "thrashesWith": .array([]), "phrases": .array([]),
            ]
            if let ms { o["speakingMs"] = .number(Double(ms)) }
            return ReviewVoice(.object(o))
        }
        func review(_ voices: [JSONValue], attributed: Int?, unattributed: Int?) -> SpeakerReview? {
            var o: [String: JSONValue] = [
                "sessionId": .string("meeting_x"), "title": .string("t"),
                "segments": .number(100), "attributed": .bool(true),
                "durationMs": .number(600_000), "voices": .array(voices),
                "timeline": .array([]),
            ]
            if let attributed { o["attributedSpeakingMs"] = .number(Double(attributed)) }
            if let unattributed { o["unattributedSpeakingMs"] = .number(Double(unattributed)) }
            return SpeakerReview(.object(o))
        }
        precondition(rv("A", 5000, asserted: true)?.speakingMs == 5000, "present decodes")
        precondition(rv("A", nil, asserted: true)?.speakingMs == nil, "absent must be nil, NOT 0")

        let named = rv("Gina", 30_000, asserted: true)!
        let weak = rv("Navaz", 10_000, asserted: false)!
        // Two named voices whose union is SMALLER than their sum — the crosstalk
        // case. Shares must still total 100%, not 105%.
        let two = review([
            .object(["label": .string("MU"), "segments": .number(1), "reliability": .string("confident"),
                     "nameAsserted": .bool(true), "speakingMs": .number(258_000),
                     "assertionBlockers": .array([]), "thrashesWith": .array([]), "phrases": .array([])]),
            .object(["label": .string("Edward"), "segments": .number(1), "reliability": .string("confident"),
                     "nameAsserted": .bool(true), "speakingMs": .number(156_000),
                     "assertionBlockers": .array([]), "thrashesWith": .array([]), "phrases": .array([])]),
        ], attributed: 396_000, unattributed: 0)!
        let shares = two.voices.compactMap { two.shareOfIdentified($0) }
        precondition(shares.count == 2, "both named voices get a share")
        precondition(abs(shares.reduce(0, +) - 1.0) < 0.001,
                     "shares must total 100% — a union denominator gave 105%")

        // The review must carry the SAME voices the share is computed over — the
        // denominator now reads `voices`, so a stub array yields no share.
        let r = review([
            .object(["label": .string("Gina"), "segments": .number(12), "reliability": .string("confident"),
                     "nameAsserted": .bool(true), "speakingMs": .number(30_000),
                     "assertionBlockers": .array([]), "thrashesWith": .array([]), "phrases": .array([])]),
        ], attributed: 30_000, unattributed: 10_000)!
        // Share is over NAMED speech, so the only named voice holds 100%.
        precondition(r.shareOfIdentified(named).map { abs($0 - 1.0) < 0.001 } == true, "share over named speech")
        // A voice the panel will not name gets no share at all.
        precondition(r.shareOfIdentified(weak) == nil, "unnamed voice must not get a share")
        // Coverage is named / (named + unnamed) = 75%.
        precondition(r.speakingCoverage.map { abs($0 - 0.75) < 0.001 } == true, "coverage")
        // An old server reporting neither bucket yields no coverage, not 0%.
        precondition(review([], attributed: nil, unattributed: nil)?.speakingCoverage == nil,
                     "absent buckets must be nil coverage, NOT zero")
    }

    /// The readable meeting: section selection, and the popover text transform.
    ///
    /// `MeetingContent` had ZERO execution coverage — the same gap SpeakerReview
    /// had, which is why `checkAssertedSegmentsBackCompat` exists.
    private static func checkMeetingContent() {
        func content(_ extra: [JSONValue] = [], summary: String = "the summary",
                     decisions: String = "   ") -> MeetingContent? {
            MeetingContent(.object([
                "sessionId": .string("meeting_x"),
                "title": .string("A Meeting"),
                "date": .string("2026-08-06"),
                "durationMin": .number(26),
                "scribeAvailable": .bool(true),
                "summary": .string(summary),
                "topics": .string(""),
                "decisions": .string(decisions),
                "actions": .string("### High Confidence\n- [ ] do the thing (**Gina**)"),
                "transcriptChars": .number(26789),
                "summaryChars": .number(2184),
                "fullChars": .number(28925),
                "coverage": .number(0.099),
                "sharesReported": .bool(false),
                "extras": .array(extra),
                "clipboardSummary": .string("s"),
                "clipboardFull": .string("f"),
            ]))
        }
        let c = content()!
        // Whitespace-only sections are dropped, not rendered as bare headings.
        precondition(c.sections.map(\.0) == ["Summary", "Action items"], "empty sections dropped")
        precondition(c.summaryChars == 2184 && c.fullChars == 28925, "both sizes decode")
        precondition(c.sharesReported == false, "share suppression carried from the server")

        // Unrecognised sections are carried, not discarded — v1 lost 116,820
        // characters corpus-wide including Miles's own Granola write-up.
        let withExtra = content([.object([
            "heading": .string("Granola Structured Notes (canonical)"),
            "body": .string("the canonical notes"),
        ])])!
        precondition(withExtra.sections.map(\.0).contains("Granola Structured Notes (canonical)"),
                     "extras reach the panel")
        // An empty-bodied extra is filtered at decode.
        let emptyExtra = content([.object([
            "heading": .string("Nothing"), "body": .string("   "),
        ])])!
        precondition(!emptyExtra.sections.map(\.0).contains("Nothing"), "blank extra dropped")

        // Text(_: String) does not parse markdown, so the panel softens it.
        let panel = MeetingContent.panelText(c.actions)
        precondition(!panel.contains("###"), "heading markers softened")
        precondition(!panel.contains("- [ ]"), "task box softened")
        precondition(!panel.contains("**"), "bold markers softened")
        precondition(panel.contains("HIGH CONFIDENCE"), "heading text survives, uppercased")
        precondition(panel.contains("do the thing"), "content survives")

        // Never silence: a 404 names the version, anything else names the failure.
        precondition(MeetingContent.unavailableMessage(nil) == nil, "loaded content renders nothing")
        precondition(MeetingContent.unavailableMessage("route_absent")?.contains("6.21.28") == true,
                     "an old server is told which version it needs")
        precondition(MeetingContent.unavailableMessage("error")?.contains("could not be loaded") == true,
                     "a real failure is named, not hidden")
        precondition(MeetingContent.unavailableMessage("something new") != nil,
                     "an unrecognised reason still says something")

        // An older server sends none of it; init? must still succeed.
        let bare = MeetingContent(.object(["sessionId": .string("meeting_y")]))
        precondition(bare != nil && bare?.scribeAvailable == false, "older server degrades")
        precondition(bare?.sections.isEmpty == true, "no sections without bodies")
    }

    static func main() throws {
        checkRenameEligibility()
        checkConfirmEligibility()
        checkMeetingRowFields()
        checkCountsSummary()
        checkAssertedSegmentsBackCompat()
        checkSpeakingTime()
        checkMeetingContent()

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
