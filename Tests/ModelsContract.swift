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

        precondition(CorrectionScope.thisMeeting.detail.contains("voice profile"),
                     "this-meeting copy must mention the voice profile it enrols")
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
        precondition(row.voiceCount == nil, "older payload must not invent a zero unnamed count")
        precondition(row.unattributedVoices == nil)
        precondition(row.humanTouched == nil)
    }

    /// Chronological sort for the Meetings-to-review list (Miles, 2026-08-29).
    ///
    /// The list is priority-ordered by default, which lifts an old unnamed
    /// meeting above today's captures. These pins cover the three things that
    /// make a date sort trustworthy: it ignores review rank, it breaks same-day
    /// ties on clock time, and a missing time never masquerades as midnight.
    private static func checkMeetingReviewSort() {
        func row(_ id: String, _ date: String, _ time: String) -> ReviewableMeeting {
            guard let m = ReviewableMeeting(.object([
                "sessionId": .string(id), "title": .string("Row \(id)"),
                "date": .string(date), "time": .string(time),
                "duration": .string("5 minutes"), "month": .string(String(date.prefix(7))),
            ])) else { preconditionFailure("fixture failed to parse") }
            return m
        }

        let memory = SpeakerListMemory()
        let rows = [
            row("a", "2026-08-26", "09:00"),
            row("b", "2026-08-28", "07:47"),
            row("c", "2026-08-28", "15:08"),
            row("d", "2026-08-28", ""),
        ]

        let newest = memory.chronological(rows, newestFirst: true).map(\.sessionId)
        precondition(newest == ["c", "b", "d", "a"],
                     "newest-first orders by day then clock time, unknown time last within its day")

        let oldest = memory.chronological(rows, newestFirst: false).map(\.sessionId)
        precondition(oldest == ["a", "b", "c", "d"],
                     "oldest-first starts at the earliest DAY, then ascends by clock time")
        precondition(oldest.last == "d",
                     "an empty time sorts LAST inside its day in BOTH directions, never as 00:00")

        // The point of the feature: date order must survive to the visible list.
        precondition(memory.visible(rows, hideReviewed: false, sort: .newest).map(\.sessionId) == newest,
                     "the newest sort must reach the visible list unchanged by review rank")
        precondition(memory.visible(rows, hideReviewed: false, sort: .reviewPriority).map(\.sessionId)
                     == memory.ranked(rows).map(\.sessionId),
                     "the default must remain the review-priority queue")

        // Sorting the DISPLAY must never reshuffle the naming queue.
        precondition(memory.nextUnnamed(after: "c", in: rows)?.sessionId
                     == memory.nextUnnamed(after: "c", in: rows.reversed())?.sessionId,
                     "nextUnnamed is rank-ordered and must not depend on display order")

        precondition(row("x", "2026-08-28", "11:51").dateLine == "2026-08-28 · 11:51 · 5 minutes")
        precondition(row("y", "2026-08-28", "").dateLine == "2026-08-28 · 5 minutes",
                     "a missing time must not render an empty separator segment")
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

    private static func checkSpeakerListMemory() {
        guard let baseline = meetingRow() else { preconditionFailure("row failed to parse") }
        var memory = SpeakerListMemory()
        memory.seedIfEmpty([baseline.sessionId])
        precondition(memory.isNew(baseline.sessionId) == false, "first-load rows are the baseline, not NEW")

        guard let incoming = ReviewableMeeting(.object([
            "sessionId": .string("meeting_new_record"),
            "title": .string("New recording"),
            "date": .string("2026-08-21"),
            "domain": .string("quilt"),
            "duration": .string("12 minutes"),
            "month": .string("2026-08"),
            "filename": .string("2026-08-21_New.md"),
            "source": .string("G2 Glasses"),
            "voiceReview": .object([
                "voices": .number(4),
                "unattributedVoices": .number(2),
                "namedVoices": .number(2),
                "humanTouched": .bool(false),
            ]),
        ])) else { preconditionFailure("incoming row failed to parse") }
        precondition(incoming.unattributedVoices == 2)
        precondition(incoming.humanTouched == false)
        precondition(memory.isNew(incoming.sessionId), "a session not in the baseline is NEW")
        precondition(memory.voiceTag(for: incoming) == .needsNames(2))

        memory.recordVisit(incoming.sessionId, voices: 4, unattributedVoices: 0)
        precondition(memory.isNew(incoming.sessionId) == false, "opening a meeting clears NEW")
        precondition(memory.voiceTag(for: incoming) == .reviewed)

        memory.recordVisit(incoming.sessionId, voices: 4, unattributedVoices: 1)
        precondition(memory.voiceTag(for: incoming) == .needsNames(1), "partial review stays to-name")

        guard let reviewed = ReviewableMeeting(.object([
            "sessionId": .string("meeting_reviewed"),
            "title": .string("Already named"),
            "date": .string("2026-08-20"),
            "domain": .string("quilt"),
            "duration": .string("10 minutes"),
            "month": .string("2026-08"),
            "filename": .string("2026-08-20_Named.md"),
            "source": .string("G2 Glasses"),
            "voiceReview": .object([
                "voices": .number(3),
                "unattributedVoices": .number(0),
                "namedVoices": .number(3),
                "humanTouched": .bool(true),
            ]),
        ])), let untouched = ReviewableMeeting(.object([
            "sessionId": .string("meeting_untouched"),
            "title": .string("No tags yet"),
            "date": .string("2026-08-19"),
            "domain": .string("quilt"),
            "duration": .string("8 minutes"),
            "month": .string("2026-08"),
            "filename": .string("2026-08-19_Untouched.md"),
            "source": .string("G2 Glasses"),
        ]))         else { preconditionFailure("rank fixtures failed to parse") }

        let ranked = memory.ranked([reviewed, untouched, incoming, baseline])
        precondition(ranked.map(\.sessionId) == [
            incoming.sessionId, untouched.sessionId, baseline.sessionId, reviewed.sessionId
        ], "unnamed, then new, then untagged, then reviewed")

        let hidden = memory.visible([reviewed, incoming], hideReviewed: true)
        precondition(hidden.map(\.sessionId) == [incoming.sessionId], "hide reviewed drops finished rows")

        let next = memory.nextUnnamed(after: incoming.sessionId, in: [reviewed, incoming, untouched])
        precondition(next?.sessionId == untouched.sessionId, "next skips reviewed")
        precondition(memory.nextUnnamed(after: untouched.sessionId, in: [incoming, untouched])?.sessionId == incoming.sessionId,
                     "next wraps to remaining unnamed")
    }

    private static func checkReviewVoiceQueue() {
        guard let unnamed = voice(label: "Ext", reliability: "unattributed", segments: 4),
              let withheld = voice(label: "Ty Clement", reliability: "weak", segments: 20),
              let named = voice(label: "Queen Ukaoma", reliability: "confident", segments: 40)
        else { preconditionFailure("voice queue fixtures failed") }
        precondition(unnamed.reviewQueueRank < withheld.reviewQueueRank)
        precondition(withheld.reviewQueueRank < named.reviewQueueRank)

        guard let review = SpeakerReview(.object([
            "sessionId": .string("meeting_queue"),
            "title": .string("Queue"),
            "segments": .number(64),
            "attributed": .bool(true),
            "durationMs": .number(1),
            "voices": .array([
                .object([
                    "label": .string("Queen Ukaoma"),
                    "segments": .number(40),
                    "reliability": .string("confident"),
                    "nameAsserted": .bool(true),
                    "isOwner": .bool(false),
                    "phrases": .array([]),
                ]),
                .object([
                    "label": .string("Ext"),
                    "segments": .number(4),
                    "reliability": .string("unattributed"),
                    "nameAsserted": .bool(false),
                    "isOwner": .bool(false),
                    "phrases": .array([]),
                ]),
                .object([
                    "label": .string("Ty Clement"),
                    "segments": .number(20),
                    "reliability": .string("weak"),
                    "nameAsserted": .bool(false),
                    "isOwner": .bool(false),
                    "phrases": .array([]),
                ]),
            ]),
        ])) else { preconditionFailure("review queue failed to parse") }
        precondition(review.unnamedVoiceCount == 1)
        precondition(review.voicesForReview.map(\.label) == ["Ext", "Ty Clement", "Queen Ukaoma"])
    }

    /// Library rows must parse WITHOUT a sessionId. Reusing ReviewableMeeting
    /// for the Activity library would hide every Granola/Fireflies meeting.
    private static func checkLibraryMeeting() {
        let granola = LibraryMeeting(.object([
            "title": .string("Granola sync"),
            "date": .string("2026-08-12"),
            "domain": .string("quilt"),
            "month": .string("2026-08"),
            "filename": .string("2026-08-12_Granola_sync.md"),
            "duration": .string("16 minutes"),
            "source": .string("Granola"),
        ]))
        precondition(granola != nil, "library row parses without sessionId")
        precondition(granola?.sessionId == "", "sessionId stays empty")
        precondition(granola?.id == "quilt:2026-08:2026-08-12_Granola_sync.md", "synthesizes recordId")
        precondition(granola?.canReviewVoices == false, "no voice review without sessionId")
        precondition(ReviewableMeeting(.object([
            "title": .string("Granola sync"),
            "month": .string("2026-08"),
            "filename": .string("2026-08-12_Granola_sync.md"),
        ])) == nil, "speaker-review rows still require sessionId")

        let g2 = LibraryMeeting(.object([
            "recordId": .string("ops:quilt:2026-08:file.md"),
            "sessionId": .string("meeting_1"),
            "title": .string("Toast in Grocery"),
            "date": .string("2026-08-12"),
            "domain": .string("quilt"),
            "month": .string("2026-08"),
            "filename": .string("2026-08-12_Toast.md"),
            "duration": .string("47 minutes"),
        ]))
        precondition(g2?.id == "ops:quilt:2026-08:file.md")
        precondition(g2?.canReviewVoices == true)

        let detail = LibraryMeetingDetail(.object([
            "title": .string("Toast in Grocery"),
            "summary": .string("Counter Toast."),
            "transcript": .string("[MU]: We should lead with grocery."),
            "sourceContent": .string("# Toast\n\n## Transcript\n[MU]: We should lead with grocery."),
            "attendees": .array([.string("MU"), .string("Tyler Rhoton")]),
            "topics": .array([.string("Toast")]),
            "sourceTruncated": .bool(false),
        ]))
        precondition(detail?.summary == "Counter Toast.")
        precondition(detail?.attendees.count == 2)
        precondition(LibraryMeeting(.object(["title": .string("no keys")])) == nil,
                     "library row without filename/month is dropped")

        let hit = LibrarySearchHit(.object([
            "title": .string("Toast in Grocery"),
            "date": .string("2026-08-12"),
            "domain": .string("quilt"),
            "month": .string("2026-08"),
            "filename": .string("2026-08-12_Toast.md"),
            "snippet": .string("Counter Toast."),
            "match": .string("both"),
            "keywordScore": .number(0.8),
            "semanticScore": .number(0.61),
        ]))
        precondition(hit?.matchLabel == "Keyword + meaning")
        precondition(hit?.meeting.title == "Toast in Grocery")
        precondition(hit?.score == 0.8)

        let older = LibrarySearchHit(.object([
            "title": .string("Quarterly Budget Overspend Review Meeting"),
            "date": .string("2026-05-13"),
            "time": .string("2:00 PM"),
            "domain": .string("quilt"),
            "month": .string("2026-05"),
            "filename": .string("2026-05-13_Budget.md"),
            "keywordScore": .number(0.95),
            "semanticScore": .number(0.80),
        ]))
        let newer = LibrarySearchHit(.object([
            "title": .string("Aug 13, 10:03 AM"),
            "date": .string("2026-08-13"),
            "time": .string("10:03 AM"),
            "domain": .string("quilt"),
            "month": .string("2026-08"),
            "filename": .string("2026-08-13_Niala.md"),
            "keywordScore": .number(0.40),
            "semanticScore": .number(0.20),
        ]))
        precondition(older != nil && newer != nil, "recency fixtures parse")
        if let older, let newer {
            let newest = SearchRecency.sorted(
                [older, newer],
                recency: .newest,
                date: { $0.meeting.recencyDate },
                score: { $0.score }
            )
            precondition(newest.first?.meeting.title == "Aug 13, 10:03 AM",
                         "Newest puts this morning's call above a higher-score May hit")
            let match = SearchRecency.sorted(
                [older, newer],
                recency: .match,
                date: { $0.meeting.recencyDate },
                score: { $0.score }
            )
            precondition(match.first?.meeting.title == "Quarterly Budget Overspend Review Meeting",
                         "Best match keeps score order")
            let oldest = SearchRecency.sorted(
                [older, newer],
                recency: .oldest,
                date: { $0.meeting.recencyDate },
                score: { $0.score }
            )
            precondition(oldest.first?.meeting.title == "Quarterly Budget Overspend Review Meeting",
                         "Oldest puts May first")
        }
    }

    private static func checkContextSearchHit() {
        let memory = ContextSearchHit(kind: "memory", .object([
            "id": .string("mem_1"),
            "summary": .string("Toast decision"),
            "snippet": .string("Counter Toast."),
            "match": .string("both"),
            "keywordScore": .number(0.8),
            "semanticScore": .number(0.61),
        ]))
        precondition(memory?.matchLabel == "Keyword + meaning")
        precondition(memory?.record.title == "Toast decision")
        precondition(ContextSearchHit(kind: "memory", .object(["snippet": .string("no id")])) == nil,
                     "context search drops rows without id")
        let thread = ContextSearchHit(kind: "thread", .object([
            "id": .string("7ce8073d"),
            "name": .string("Hubspot Theme Settings"),
            "snippet": .string("theme"),
            "match": .string("keyword"),
            "keywordScore": .number(0.7),
        ]))
        precondition(thread?.matchLabel == "Keyword")
        precondition(thread?.record.title == "Hubspot Theme Settings")
    }

    private static func checkSessionSearchHit() {
        let hit = SessionSearchHit(.object([
            "id": .string("019dfe42-d4ba-7152-b5ae-60f600a2675a"),
            "provider": .string("codex"),
            "name": .string("Markt POS 2.0 build"),
            "snippet": .string("Jewelry Edge bridge"),
            "match": .string("both"),
            "keywordScore": .number(0.8),
            "semanticScore": .number(0.61),
        ]))
        precondition(hit?.matchLabel == "Keyword + meaning")
        precondition(hit?.session.title == "Markt POS 2.0 build")
        precondition(hit?.score == 0.8)
        precondition(SessionSearchHit(.object(["snippet": .string("no id")])) == nil,
                     "session search drops rows without id")
        let listed = ClaudeSession(.object([
            "id": .string("ae0ae0ae"),
            "name": .string("AEO HS Setup"),
            "workspace": .string("MU-Chief-Staff"),
            "state": .string("recent"),
        ]))
        precondition(SessionSearchHit.tokenize("aeo") == ["aeo"])
        if let listed {
            let instant = SessionSearchHit.keywordHits(query: "aeo", sessions: [listed])
            precondition(instant.contains(where: { $0.session.title == "AEO HS Setup" }),
                         "listed titles match before the helper returns")
        }
        let olderSession = SessionSearchHit(.object([
            "id": .string("old-session"),
            "name": .string("May POS"),
            "updatedAt": .string("2026-05-13T15:00:00Z"),
            "keywordScore": .number(0.9),
        ]))
        let newerSession = SessionSearchHit(.object([
            "id": .string("new-session"),
            "name": .string("POS complexity"),
            "updatedAt": .string("2026-08-13T16:00:00Z"),
            "keywordScore": .number(0.2),
        ]))
        if let olderSession, let newerSession {
            let newest = SearchRecency.sorted(
                [olderSession, newerSession],
                recency: .newest,
                date: { $0.session.updatedDate ?? $0.session.createdDate },
                score: { $0.score }
            )
            precondition(newest.first?.session.title == "POS complexity",
                         "Newest session lookup puts the latest write first")
        }
    }

    private static func checkClaudeSession() {
        let waiting = ClaudeSession(.object([
            "id": .string("sess_1"),
            "name": .string("hidden-name"),
            "workspace": .string("MU-Chief-Staff"),
            "state": .string("waiting"),
            "waitingFor": .string("user"),
            "alive": .bool(true),
        ]))
        precondition(waiting?.title == "hidden-name")
        precondition(waiting?.stateLabel == "Waiting")
        precondition(ClaudeSession(.object(["workspace": .string("MU-Chief-Staff")])) == nil,
                     "session rows without id are dropped")
        let unnamed = ClaudeSession(.object([
            "id": .string("sess_2"),
            "name": .string("analysis"),
            "workspace": .string(""),
            "state": .string("stale"),
            "alive": .bool(false),
        ]))
        precondition(unnamed?.title == "analysis")
        precondition(unnamed?.stateLabel == "Stale")
        let renamed = ClaudeSession(.object([
            "id": .string("d3786335"),
            "name": .string("Fireflies meeting sync"),
            "workspace": .string("MU-Chief-Staff"),
            "state": .string("running"),
            "alive": .bool(true),
        ]))
        precondition(renamed?.title == "Fireflies meeting sync")
        precondition(renamed?.providerLabel == "Claude")
        let cursorRow = ClaudeSession(.object([
            "id": .string("a488f8e0"),
            "provider": .string("cursor"),
            "name": .string("Session badges"),
            "workspace": .string("MU-Chief-Staff"),
            "state": .string("recent"),
            "alive": .bool(false),
        ]))
        precondition(cursorRow?.id == "cursor:a488f8e0")
        precondition(cursorRow?.sessionId == "a488f8e0")
        precondition(cursorRow?.providerLabel == "Cursor")
        let codexRow = ClaudeSession(.object([
            "id": .string("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            "provider": .string("codex"),
            "name": .string("Badge the sessions tab"),
            "workspace": .string("MU-Chief-Staff"),
            "state": .string("recent"),
            "alive": .bool(false),
        ]))
        precondition(codexRow?.id == "codex:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        precondition(codexRow?.providerLabel == "Codex")
        let stamped = ClaudeSession(.object([
            "id": .string("019e0943-62c4-7643-bcff-1a7be9a52a4c"),
            "provider": .string("codex"),
            "name": .string("Markt POS 2.0 build"),
            "createdAt": .string("2026-05-08T20:24:31Z"),
            "updatedAt": .string("2026-08-13T18:43:00Z"),
            "state": .string("recent"),
            "alive": .bool(false),
        ]))
        precondition(stamped?.createdDate != nil)
        precondition(stamped?.updatedDate != nil)
        precondition(stamped?.createdDate ?? .distantFuture < stamped?.updatedDate ?? .distantPast)
        let pinned = ClaudeSession(.object([
            "id": .string("0196aaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            "provider": .string("codex"),
            "name": .string("Jewelry 2.0 Build"),
            "pinned": .bool(true),
            "state": .string("recent"),
            "alive": .bool(false),
        ]))
        precondition(pinned?.pinned == true)
        precondition(cursorRow?.pinned == false)
        let pinnedRow = ClaudeSession(.object([
            "id": .string("019dfe42-d4ba-7152-b5ae-60f600a2675a"),
            "provider": .string("codex"),
            "name": .string("Jewelry 2.0 Build"),
            "pinned": .bool(true),
            "state": .string("recent"),
            "alive": .bool(false),
        ]))
        precondition(pinnedRow?.pinned == true)
        precondition(cursorRow?.pinned == false)
        let recent = ClaudeSession(.object([
            "id": .string("sess_3"),
            "name": .string("Fireflies meeting sync"),
            "workspace": .string("MU-Chief-Staff"),
            "state": .string("recent"),
            "alive": .bool(false),
        ]))
        precondition(recent?.stateLabel != "Today", "recent is not a date word")
        precondition(recent?.stateLabel == "", "recent has no chip; the date is on clockHint")
        precondition(recent?.showsStateChip == false)
        precondition(waiting?.showsStateChip == true)
        precondition(stamped?.clockHint(clock: .updated) != nil,
                     "a stamped recent row always shows when it was updated")
        precondition(!(stamped?.clockHint(clock: .updated) ?? "").localizedCaseInsensitiveContains("today"),
                     "clockHint must not resurrect the Today lie")
        let closeCreated = ClaudeSession(.object([
            "id": .string("sess_close"),
            "name": .string("Same-day edit"),
            "createdAt": .string("2026-08-19T16:00:00Z"),
            "updatedAt": .string("2026-08-19T17:00:00Z"),
            "state": .string("recent"),
            "alive": .bool(false),
        ]))
        precondition(closeCreated?.clockHint(clock: .updated) != nil,
                     "the 36-hour suppression is gone: a 1-hour span still shows Updated")
        let dropped = SessionListDropped(.object([
            "age": .number(412),
            "limit": .number(6),
            "oversized": .number(1),
        ]))
        precondition(dropped.total == 419)
        precondition(dropped.summary == "412 older than 7 days · 6 over the cap · 1 too large not shown")
        precondition(SessionListDropped().summary == nil)
        precondition(ClaudeSession.isKeepWarmSessionTitle("ready"))
        precondition(ClaudeSession.isKeepWarmSessionTitle("This is an automated local readiness check. Do not use tools. Reply with exactly"))
        precondition(ClaudeSession.isKeepWarmSessionTitle("ready") && !ClaudeSession.isKeepWarmSessionTitle("Fireflies meeting sync"))
        let warm = ClaudeSession(.object([
            "id": .string("warm1"),
            "name": .string("ready"),
            "workspace": .string("MU-Chief-Staff"),
            "state": .string("recent"),
            "alive": .bool(false),
        ]))
        precondition(warm?.isKeepWarm == true)
        precondition(renamed?.isKeepWarm == false)
        let petWaiting = ClaudeSession(.object([
            "id": .string("pet-wait"),
            "name": .string("Waiting on you"),
            "workspace": .string("MU-Chief-Staff"),
            "state": .string("waiting"),
            "waitingFor": .string("user"),
            "alive": .bool(true),
            "updatedAt": .string("2026-08-27T16:00:00Z"),
            "discussion_summary": .string("Inspecting cos-starter diffs"),
        ]))
        precondition(petWaiting?.isPetVisible == true, "waiting is a live pet session")
        precondition(petWaiting?.discussionSummary == "Inspecting cos-starter diffs")
        precondition(petWaiting?.petSubtitle == "Inspecting cos-starter diffs")
        precondition(petWaiting?.petStateCaption == "Waiting")
        precondition(petWaiting?.isPetWorking == false)
        let petRunning = ClaudeSession(.object([
            "id": .string("pet-run"),
            "name": .string("Live turn"),
            "workspace": .string("MU-Chief-Staff"),
            "state": .string("running"),
            "alive": .bool(true),
            "updatedAt": .string("2026-08-27T16:02:00Z"),
        ]))
        precondition(petRunning?.isPetWorking == true)
        precondition(petRunning?.petStateCaption == "Running")
        let petIdleAlive = ClaudeSession(.object([
            "id": .string("pet-idle"),
            "name": .string("COS session pet feature"),
            "workspace": .string("MU-Chief-Staff"),
            "state": .string("recent"),
            "alive": .bool(true),
            "updatedAt": .string("2026-08-27T16:01:00Z"),
        ]))
        precondition(petIdleAlive?.isPetVisible == true, "an alive idle row still belongs on the pet")
        precondition(petIdleAlive?.isPetWorking == false)
        precondition(petIdleAlive?.petStateCaption == "Idle")
        let petNow = ISO8601DateFormatter().date(from: "2026-08-27T16:03:00Z") ?? Date()
        precondition(petWaiting?.relativeAgeLabel(now: petNow) == "Updated 3m ago")
        let petWarm = ClaudeSession(.object([
            "id": .string("pet-warm"),
            "name": .string("ready"),
            "state": .string("running"),
            "alive": .bool(true),
        ]))
        precondition(petWarm?.isPetVisible == false, "keep-warm never becomes a pet")
        precondition(recent?.isPetVisible == false, "recent without alive is not a pet")
        let visible = ClaudeSession.petVisibleSessions(in: [warm!, recent!, petWaiting!, renamed!])
        precondition(visible.map(\.id) == ["claude:d3786335", "claude:pet-wait"],
                     "a running row sits above waiting even without a newer stamp")
        let petIdleNewer = ClaudeSession(.object([
            "id": .string("pet-claude-stuck"),
            "provider": .string("claude"),
            "name": .string("Plan validation and blocker clearance"),
            "workspace": .string("MU-Chief-Staff"),
            "state": .string("recent"),
            "alive": .bool(true),
            "updatedAt": .string("2026-08-27T18:51:00Z"),
        ]))
        let petCursorRun = ClaudeSession(.object([
            "id": .string("pet-cursor-live"),
            "provider": .string("cursor"),
            "name": .string("COS session pet feature"),
            "workspace": .string("MU-Chief-Staff"),
            "state": .string("running"),
            "alive": .bool(true),
            "updatedAt": .string("2026-08-27T18:50:00Z"),
        ]))
        let ranked = ClaudeSession.petVisibleSessions(in: [petIdleNewer!, petCursorRun!])
        precondition(ranked.map(\.id) == ["cursor:pet-cursor-live", "claude:pet-claude-stuck"],
                     "an idle-but-alive Claude row cannot outrank a running Cursor turn")
        precondition(
            ClaudeSession.petPreferredFocus(in: ranked, focusedID: "claude:pet-claude-stuck")?.id
                == "cursor:pet-cursor-live",
            "sticky focus on an idle Claude row yields to the running Cursor session"
        )
        precondition(
            ClaudeSession.petPreferredFocus(in: ranked, focusedID: "cursor:pet-cursor-live")?.id
                == "cursor:pet-cursor-live",
            "sticky focus on the running row is kept"
        )
        precondition(petCursorRun!.petTargetOpensAgentWindow,
                     "the pet target on a Cursor row opens the Agents Window")
        precondition(!petIdleNewer!.petTargetOpensAgentWindow,
                     "the pet target on a Claude row still opens Activity")
        let petCodexRun = ClaudeSession(.object([
            "id": .string("pet-codex-live"),
            "provider": .string("codex"),
            "name": .string("Execute POS Nation SEO fixes"),
            "workspace": .string("MU-Chief-Staff"),
            "state": .string("running"),
            "alive": .bool(true),
            "updatedAt": .string("2026-08-27T18:52:00Z"),
        ]))
        let vsCodex = ClaudeSession.petVisibleSessions(in: [petIdleNewer!, petCodexRun!])
        precondition(vsCodex.map(\.id) == ["codex:pet-codex-live", "claude:pet-claude-stuck"],
                     "an idle-but-alive Claude row cannot outrank a running Codex turn")
        precondition(
            ClaudeSession.petPreferredFocus(in: vsCodex, focusedID: "claude:pet-claude-stuck")?.id
                == "codex:pet-codex-live",
            "sticky focus on an idle Claude row yields to the running Codex session"
        )
        precondition(petCodexRun!.petTargetOpensAgentWindow == false,
                     "the pet target on a Codex row still opens Activity")
        let detail = ClaudeSessionDetail(.object([
            "title": .string("Fireflies meeting sync"),
            "cwd": .string("/repo"),
            "branch": .string("main"),
            "sessionId": .string("d3786335"),
            "totalTurns": .number(2),
            "omittedTools": .number(3),
            "omittedSidechain": .number(0),
            "truncated": .bool(false),
            "copyText": .string("# Kickstart: Fireflies meeting sync"),
            "turns": .array([
                .object([
                    "id": .string("1"),
                    "role": .string("user"),
                    "text": .string("Sync Fireflies"),
                    "timestamp": .string(""),
                ]),
                .object([
                    "id": .string("2"),
                    "role": .string("assistant"),
                    "text": .string("Synced the meeting."),
                    "timestamp": .string(""),
                ]),
            ]),
        ]))
        precondition(detail?.title == "Fireflies meeting sync")
        precondition(detail?.turns.count == 2)
        precondition(detail?.turns.first?.isUser == true)
        precondition(detail?.copyText.contains("Kickstart") == true)
        precondition(ClaudeSessionDetail(.object(["title": .string("x")])) == nil,
                     "session detail without turns or copy is dropped")
    }

    private static func checkPetSpriteStore() {
        precondition(PetSpriteStore.isAllowedImage(URL(fileURLWithPath: "/tmp/face.png")))
        precondition(PetSpriteStore.isAllowedImage(URL(fileURLWithPath: "/tmp/face.PNG")))
        precondition(PetSpriteStore.isAllowedImage(URL(fileURLWithPath: "/tmp/face.gif")))
        precondition(!PetSpriteStore.isAllowedImage(URL(fileURLWithPath: "/tmp/face.exe")))
        precondition(!PetSpriteStore.isAllowedImage(URL(fileURLWithPath: "/tmp/face.svg")))

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pet-sprite-\(UUID().uuidString)", isDirectory: true)
        try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // 1x1 PNG. Copied bytes must match so pixel art is not resampled.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let source = tmp.appendingPathComponent("face.png")
        try! png.write(to: source)
        let support = tmp.appendingPathComponent("support", isDirectory: true)
        let dest = try! PetSpriteStore.install(from: source, into: support)
        precondition(dest.lastPathComponent == "session-pet-sprite.png")
        precondition((try! Data(contentsOf: dest)) == png, "pixel art must be copied, not re-encoded")
        precondition(PetSpriteStore.existingSpriteURL(in: support)?.path == dest.path)

        let empty = tmp.appendingPathComponent("empty.png")
        try! Data().write(to: empty)
        do {
            _ = try PetSpriteStore.install(from: empty, into: support)
            precondition(false, "empty sprite must be refused")
        } catch PetSpriteStore.InstallError.empty {
        } catch {
            precondition(false, "empty sprite must throw InstallError.empty, got \(error)")
        }

        PetSpriteStore.remove(from: support)
        precondition(PetSpriteStore.existingSpriteURL(in: support) == nil)
        precondition(!PetSpriteStore.isAllowedImage(URL(fileURLWithPath: "/tmp/face.zip")))
    }

    private static func checkPetSpritePoses() {
        // D4: completing only shows .done when NOTHING is still working or
        // waiting, and waiting-with-no-running beats the fight ladder.
        precondition(PetSpritePose.resolve(sessionCount: 1, workingCount: 1, waitingCount: 0, focusState: "running", completing: false) == .working)
        precondition(PetSpritePose.resolve(sessionCount: 1, workingCount: 0, waitingCount: 1, focusState: "waiting", completing: false) == .waiting)
        precondition(PetSpritePose.resolve(sessionCount: 1, workingCount: 0, waitingCount: 0, focusState: "idle", completing: false) == .patrol)
        precondition(PetSpritePose.resolve(sessionCount: 2, workingCount: 0, waitingCount: 0, focusState: "idle", completing: false) == .duel)
        precondition(PetSpritePose.resolve(sessionCount: 3, workingCount: 3, waitingCount: 0, focusState: "running", completing: false) == .trio)
        precondition(PetSpritePose.resolve(sessionCount: 4, workingCount: 4, waitingCount: 0, focusState: "running", completing: false) == .swarm)
        precondition(PetSpritePose.resolve(sessionCount: 5, workingCount: 0, waitingCount: 0, focusState: "idle", completing: false) == .swarm)
        precondition(PetSpritePose.resolve(sessionCount: 1, workingCount: 0, waitingCount: 0, focusState: "running", completing: true) == .done)
        precondition(PetSpritePose.resolve(sessionCount: 3, workingCount: 3, waitingCount: 0, focusState: "running", completing: false, attention: true) == .attention)
        precondition(PetSpritePose.resolve(sessionCount: 1, workingCount: 0, waitingCount: 0, focusState: "error", completing: false) == .error)
        precondition(PetSpritePose.resolve(sessionCount: 4, workingCount: 3, waitingCount: 0, focusState: "running", completing: true) == .swarm,
                     "one of four finishing must not flash .done over a live fight")
        precondition(PetSpritePose.resolve(sessionCount: 4, workingCount: 0, waitingCount: 0, focusState: "idle", completing: true) == .done)
        precondition(PetSpritePose.resolve(sessionCount: 2, workingCount: 0, waitingCount: 1, focusState: "waiting", completing: true) == .waiting)
        precondition(PetSpritePose.resolve(sessionCount: 4, workingCount: 0, waitingCount: 1, focusState: "waiting", completing: false) == .waiting,
                     "one waiting + three idle-alive is amber, not a swarm")
        precondition(PetSpritePose.matching(fileName: "01-idle-strip.png") == .idle)
        precondition(PetSpritePose.matching(fileName: "02-search-strip-alpha.png") == .waiting)
        precondition(PetSpritePose.matching(fileName: "03-grep-strip-alpha.png") == .working)
        precondition(PetSpritePose.matching(fileName: "04-combat-strip-alpha.png") == .swarm)
        precondition(PetSpritePose.matching(fileName: "05-success-strip.png") == .done)
        precondition(PetSpritePose.matching(fileName: "02-lightsaber-run-v2.png") == .working)
        precondition(PetSpritePose.matching(fileName: "03-droid-combat-v2.png") == .duel)
        precondition(PetSpritePose.matching(fileName: "01-core-agent-states-v2.png") == nil)
        precondition(PetSpritePose.matching(fileName: "00-master-turnaround.png") == nil)

        var kit = PetSpriteKit()
        kit.poses[.swarm] = [rgbImage(width: 2, height: 2) { _, _ in (10, 10, 10, 255) }]
        precondition(kit.frames(for: .duel).count == 1, "a V1 combat strip must cover a two-session duel")
        precondition(kit.frames(for: .patrol).isEmpty, "patrol must not invent frames")

        let board = rgbImage(width: 4, height: 2) { x, y in
            (UInt8(x * 60 + 20), UInt8(y * 80 + 40), 200, 255)
        }
        let cells = PetSpriteStrip.sliceGrid(board, columns: 2, rows: 2)
        precondition(cells.count == 4, "a 2x2 board must yield 4 cells")
        for cell in cells {
            guard let cg = PetSpriteStrip.raster(cell) else {
                preconditionFailure("grid cell must rasterize")
            }
            precondition(cg.width == 2)
            precondition(cg.height == 1)
        }

        let strip = rgbImage(width: 6, height: 1) { x, _ in
            (UInt8(x * 40), 0, 255, 255)
        }
        let frames = PetSpriteStrip.slice(strip, frames: 6)
        precondition(frames.count == 6, "a 6-wide strip must yield 6 frames")
        for frame in frames {
            guard let cg = PetSpriteStrip.raster(frame) else {
                preconditionFailure("sliced frame must rasterize")
            }
            precondition(cg.width == 1, "each frame of a 6x1 strip is 1px wide, got \(cg.width)")
            precondition(cg.height == 1)
        }

        let paper = rgbImage(width: 5, height: 5) { x, y in
            if x == 2 && y == 2 { return (10, 10, 10, 255) }
            return (254, 254, 254, 255)
        }
        precondition(PetSpriteAlpha.needsPaperKnockout(paper))
        let cleaned = PetSpriteAlpha.knockOutEdgePaper(paper)
        let corner = rgbaPixel(cleaned, x: 0, y: 0)
        precondition(corner.3 < 16, "edge paper must become transparent, got alpha \(corner.3)")
        let center = rgbaPixel(cleaned, x: 2, y: 2)
        precondition(center.3 > 200, "interior ink must stay, got alpha \(center.3)")
        precondition(center.0 < 40, "interior ink must stay dark, got \(center.0)")

        let checker = rgbImage(width: 5, height: 5) { x, y in
            if x == 2 && y == 2 { return (10, 10, 10, 255) }
            return (200, 200, 200, 255)
        }
        precondition(PetSpriteAlpha.needsPaperKnockout(checker), "checkerboard gray is paper")

        let pole = rgbImage(width: 2, height: 300) { _, y in
            if y < 40 { return (220, 20, 20, 255) }
            if y > 259 { return (20, 20, 220, 255) }
            return (20, 180, 20, 255)
        }
        let scaled = PetSpriteStrip.fitHeight(pole, maxHeight: 256)
        let top = rgbaPixel(scaled, x: 0, y: 0)
        let bottom = rgbaPixel(scaled, x: 0, y: 255)
        precondition(top.0 > 150 && top.2 < 80, "fitHeight must keep the top red, got \(top)")
        precondition(bottom.2 > 150 && bottom.0 < 80, "fitHeight must keep the bottom blue, got \(bottom)")

        let padded = rgbImage(width: 80, height: 80) { x, y in
            if (37...42).contains(x) && (37...42).contains(y) { return (10, 10, 10, 255) }
            return (254, 254, 254, 255)
        }
        let cropped = PetSpriteStrip.cropOpaque(PetSpriteAlpha.knockOutEdgePaper(padded))
        guard let cropCG = PetSpriteStrip.raster(cropped) else {
            preconditionFailure("cropped sprite must rasterize")
        }
        precondition(cropCG.height < 60, "crop must drop the empty cell, got \(cropCG.height)")
        precondition(cropCG.width < 60, "crop must drop the empty cell, got \(cropCG.width)")

        let islandBoard = rgbImage(width: 40, height: 8) { x, _ in
            let inBlob = (2..<8).contains(x) || (12..<18).contains(x)
                || (22..<28).contains(x) || (32..<38).contains(x)
            return inBlob ? (10, 10, 10, 255) : (0, 0, 0, 0)
        }
        let islands = PetSpriteStrip.sliceRowByIslands(islandBoard, count: 4)
        precondition(islands.count == 4, "uneven scenes must split on gutters, got \(islands.count)")

        var cineKit = PetSpriteKit()
        cineKit.poses[.trio] = [rgbImage(width: 2, height: 2) { _, _ in (10, 10, 10, 255) }]
        cineKit.cinematic = (0..<4).map { i in
            rgbImage(width: 2, height: 2) { _, _ in (UInt8(40 + i * 40), 10, 10, 255) }
        }
        // Trio animates rather than showing the still, but climbs the ladder
        // only to its own rung — playing all four made three sessions and five
        // identical and showed the lone patrol scene during a three-way.
        precondition(cineKit.frames(for: .trio).count == 3,
                     "three-session fight must animate the ladder up to trio")
        precondition(cineKit.frames(for: .swarm).count == 4,
                     "swarm plays the full ladder")

        // A direct multi-frame combat strip is more specific than the ladder.
        // V3 packs install animated trio/swarm poses beside the bundled
        // cinematic, so the direct strips must not be shadowed forever.
        cineKit.poses[.trio] = (0..<6).map { i in
            rgbImage(width: 2, height: 2) { _, _ in (10, UInt8(40 + i * 20), 10, 255) }
        }
        cineKit.poses[.swarm] = (0..<6).map { i in
            rgbImage(width: 2, height: 2) { _, _ in (10, 10, UInt8(40 + i * 20), 255) }
        }
        precondition(cineKit.frames(for: .trio).count == 6,
                     "direct animated trio must beat the cinematic ladder")
        precondition(cineKit.frames(for: .swarm).count == 6,
                     "direct animated swarm must beat the cinematic ladder")

        let colored = rgbImage(width: 4, height: 4) { x, y in
            let col = x / 2
            let row = y / 2
            if row == 0 && col == 0 { return (220, 20, 20, 255) }
            if row == 0 && col == 1 { return (20, 220, 20, 255) }
            if row == 1 && col == 0 { return (20, 20, 220, 255) }
            return (220, 220, 20, 255)
        }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("pet-pack-\(UUID().uuidString)", isDirectory: true)
        try! fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let search = tmp.appendingPathComponent("02-search-strip.png")
        let searchAlpha = tmp.appendingPathComponent("02-search-strip-alpha.png")
        let combat = tmp.appendingPathComponent("04-combat-strip-alpha.png")
        try! pngData(strip).write(to: search)
        // Spaced 8-scene strip: installPose must record the natural island
        // count, and here nature and the manifest agree at 8.
        let spacedStrip = rgbImage(width: 160, height: 8) { x, _ in
            let inBlob = (x % 20) < 8 && x / 20 < 8
            return inBlob ? (10, 10, 10, 255) : (0, 0, 0, 0)
        }
        try! pngData(spacedStrip).write(to: searchAlpha)
        try! pngData(strip).write(to: combat)
        let scanned = PetSpritePack.scanFiles(in: tmp)
        let waiting = scanned.first { $0.pose == .waiting }
        let swarm = scanned.first { $0.pose == .swarm }
        precondition(waiting?.url.lastPathComponent == "02-search-strip-alpha.png",
                     "an alpha strip wins over the baked original")
        precondition(swarm?.frames == 10, "combat defaults to 10 frames")

        let boardFile = tmp.appendingPathComponent("01-core-agent-states-v2.png")
        try! pngData(board).write(to: boardFile)
        let recognized = PetSpritePack.recognizedBoard(boardFile)
        precondition(recognized?.columns == 6 && recognized?.rows == 2)
        precondition(recognized?.cells.count == 12)

        let gridSupport = tmp.appendingPathComponent("grid-support", isDirectory: true)
        try! PetSpriteStore.installGrid(
            from: boardFile,
            columns: 2,
            rows: 2,
            cells: [(.idle, 0), (.error, 3)],
            into: gridSupport
        )
        precondition(PetSpriteStore.existingPoseURL(.idle, in: gridSupport) != nil)
        precondition(PetSpriteStore.existingPoseURL(.error, in: gridSupport) != nil)
        precondition(PetSpriteStore.loadStateMap(in: gridSupport)[.error]?.frames == 1)

        let colorFile = tmp.appendingPathComponent("color-grid.png")
        try! pngData(colored).write(to: colorFile)
        let colorSupport = tmp.appendingPathComponent("color-support", isDirectory: true)
        try! PetSpriteStore.installGrid(
            from: colorFile,
            columns: 2,
            rows: 2,
            cells: [(.idle, 0), (.error, 3)],
            into: colorSupport
        )
        let idleInstalled = NSImage(contentsOf: PetSpriteStore.existingPoseURL(.idle, in: colorSupport)!)!
        guard let idleCG = PetSpriteStrip.raster(idleInstalled) else {
            preconditionFailure("installed idle cell must rasterize")
        }
        let idlePix = rgbaPixel(idleInstalled, x: idleCG.width / 2, y: idleCG.height / 2)
        precondition(idlePix.0 > 150 && idlePix.2 < 80,
                     "top-left cell must stay red and upright after install, got \(idlePix)")

        let manifest = """
        {"poses":{"idle":{"file":"02-search-strip.png","frames":4}}}
        """.data(using: .utf8)!
        try! manifest.write(to: tmp.appendingPathComponent("manifest.json"))
        let loaded = try! PetSpritePack.load(from: tmp)
        precondition(loaded.contains { $0.pose == .idle && $0.frames == 4 },
                     "manifest frames win over filename defaults")

        let support = tmp.appendingPathComponent("support", isDirectory: true)
        let dest = try! PetSpriteStore.installPose(.waiting, from: searchAlpha, frames: 8, into: support)
        precondition(dest.lastPathComponent == "session-pet-waiting.png")
        let map = PetSpriteStore.loadStateMap(in: support)
        precondition(map[.waiting]?.frames == 8)
        PetSpriteStore.setFrames(.waiting, frames: 5, in: support)
        precondition(PetSpriteStore.loadStateMap(in: support)[.waiting]?.frames == 5)
        print("COS Control: pet sprite poses passed")
    }

    private static func rgbImage(
        width: Int,
        height: Int,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> NSImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let index = (y * width + x) * 4
                pixels[index] = r
                pixels[index + 1] = g
                pixels[index + 2] = b
                pixels[index + 3] = a
            }
        }
        let data = Data(pixels) as CFData
        let provider = CGDataProvider(data: data)!
        let cg = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    private static func pngData(_ image: NSImage) -> Data {
        let tiff = image.tiffRepresentation!
        let rep = NSBitmapImageRep(data: tiff)!
        return rep.representation(using: .png, properties: [:])!
    }

    private static func rgbaPixel(_ image: NSImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        guard let cg = PetSpriteStrip.raster(image) else { return (0, 0, 0, 0) }
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: cg.width,
                height: cg.height,
                bitsPerComponent: 8,
                bytesPerRow: cg.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        // A bitmap-context draw is orientation-true: buffer row 0 IS the top
        // scanline. This reader used to invert the row (height-1-y), which
        // cancelled the pipeline's own spurious flip — green tests, upside-down
        // production. Read raster order; never re-add the inversion.
        let index = (y * cg.width + x) * 4
        return (pixels[index], pixels[index + 1], pixels[index + 2], pixels[index + 3])
    }

    private static func checkPetSize() {
        let medium = PetSize.load(preset: nil, pixels: nil)
        precondition(medium.preset == .medium)
        precondition(medium.pixels == 64, "medium is the original sprite size")
        precondition(PetSize.load(preset: "small", pixels: nil).pixels == 48,
                     "small is 25 percent under medium")
        precondition(PetSize.load(preset: "large", pixels: nil).pixels == 80,
                     "large is 25 percent over medium")
        let custom = PetSize.load(preset: "custom", pixels: 72)
        precondition(custom.preset == .custom)
        precondition(custom.pixels == 72)
        precondition(PetSize.load(preset: "custom", pixels: 12).pixels == 32,
                     "custom pixels clamp at the floor")
        precondition(PetSize.load(preset: "custom", pixels: 400).pixels == 128,
                     "custom pixels clamp at the ceiling")
        precondition(PetSize.load(preset: "CUSTOM", pixels: 90).pixels == 90)
        precondition(PetSize.load(preset: "huge", pixels: 90).preset == .medium,
                     "an unknown preset falls back to medium")
        precondition(abs(PetSize.load(preset: "small", pixels: nil).scale - 0.75) < 0.001)
        precondition(PetSize.load(preset: "medium", pixels: nil).length(248) == 248)
        let hidden = CGRect(x: 12, y: -401, width: 310, height: 362)
        let primary = CGRect(x: 0, y: 0, width: 2880, height: 1590)
        let healed = PetPanelFrame.clamped(hidden, screens: [primary])
        precondition(primary.intersects(healed),
                     "an off-screen pet frame must snap back onto a display")
        precondition(healed.minY >= primary.minY)
        let parked = CGRect(x: 2500, y: 40, width: 260, height: 180)
        precondition(PetPanelFrame.clamped(parked, screens: [primary]) == parked,
                     "an on-screen pet frame stays put")
    }

    /// Agents list rows, not Cursor window titles. Contains matching against
    /// windows raises the IDE because the workspace name sits in both.
    // MARK: - Pet sprite pipeline (executable, not source-grep)

    /// Opaque violet ink block: passes isSpriteInk (alpha high, saturated, not paper).
    private static func spriteProbe(
        width: Int,
        height: Int,
        blobs: [(x: Int, w: Int, y: Int, h: Int)],
        gray: Bool = false
    ) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
        ) else { preconditionFailure("probe rep") }
        let clear = NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 0)
        let ink = gray
            ? NSColor(calibratedRed: 0.42, green: 0.43, blue: 0.44, alpha: 1)
            : NSColor(calibratedRed: 0.25, green: 0.16, blue: 0.55, alpha: 1)
        for y in 0..<height {
            for x in 0..<width { rep.setColor(clear, atX: x, y: y) }
        }
        for blob in blobs {
            for y in blob.y..<min(height, blob.y + blob.h) {
                for x in blob.x..<min(width, blob.x + blob.w) { rep.setColor(ink, atX: x, y: y) }
            }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    private static func inkFraction(_ image: NSImage, topHalf: Bool) -> Double {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return -1 }
        let h = rep.pixelsHigh
        let w = rep.pixelsWide
        let rows = topHalf ? 0..<(h / 2) : (h / 2)..<h
        var hits = 0
        var total = 0
        for y in rows {
            for x in 0..<w {
                total += 1
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.2 { hits += 1 }
            }
        }
        return total == 0 ? -1 : Double(hits) / Double(total)
    }

    private static func checkPetSpritePipeline() {
        // ORIENTATION: ink lives ONLY in the top rows. Every public transform
        // must keep it there — one spurious flip in a buffer round trip shipped
        // upside-down duel scenes on 0.5.111.
        let topHeavy = spriteProbe(width: 64, height: 48, blobs: [(x: 4, w: 56, y: 4, h: 16)])
        let scaled = PetSpriteStrip.fitHeight(topHeavy, maxHeight: 24)
        precondition(inkFraction(scaled, topHalf: true) > 0.4,
                     "fitHeight lost the top-heavy ink: vertical flip in the buffer round trip")
        precondition(inkFraction(scaled, topHalf: false) < 0.05,
                     "fitHeight moved ink to the bottom: vertical flip in the buffer round trip")
        let cropped = PetSpriteStrip.cropOpaque(topHeavy, paddingRatio: 0.1)
        precondition(cropped.size.height < topHeavy.size.height,
                     "cropOpaque did not trim the empty bottom")
        precondition(inkFraction(cropped, topHalf: true) > 0.2,
                     "cropOpaque cropped the mirrored region: bbox measured on a flipped buffer")
        let prepared = PetSpriteStrip.prepare(topHeavy, frames: 1)
        precondition(inkFraction(prepared.image, topHalf: true) > inkFraction(prepared.image, topHalf: false),
                     "prepare flipped a top-heavy sprite")

        // VALLEY GATE. Both halves are mutation-checked: reverting the gate or
        // widening the window back to width/(count*3) must fail here. Earlier
        // fixtures could not tell the versions apart — one had perfectly empty
        // windows (the gate is a no-op), another uniform ink (the tie-break
        // already returned centre) — so seven mutations survived, including
        // deleting the gate outright.
        //
        // Case A: the emptiest column in the window is INKED and only mildly
        // better than the grid column (8 rows vs 12 of 100). The gate keeps the
        // authored cut; the old rule slid onto the thin spot.
        // Segments, not overlaps: spriteProbe only ADDS ink, so a "thin spot"
        // drawn on top of the bridge is not thinner at all.
        let mildlyBetter = spriteProbe(width: 400, height: 100, blobs: [
            (x: 10, w: 161, y: 10, h: 80),    // figure one, ends at 170
            (x: 171, w: 43, y: 44, h: 12),    // bridge, 12 rows, through the grid cut at 200
            (x: 214, w: 12, y: 46, h: 8),     // 8 rows — better, but not clearly so
            (x: 226, w: 4, y: 44, h: 12),     // bridge resumes
            (x: 230, w: 160, y: 10, h: 80),   // figure two
        ])
        do {
            let f = PetSpriteStrip.sliceStripByValleys(mildlyBetter, frames: 2)
            precondition(f.count == 2, "declared count survives")
            precondition(abs(Int(f[0].size.width) - 200) <= 1,
                         "a merely-thinner column must not pull the cut off the grid, got \(Int(f[0].size.width))")
        }

        // Case B: the only clean column sits outside cell/6 but inside the old
        // width/(count*3) sweep. The narrow window must not reach it.
        var farBlobs: [(x: Int, w: Int, y: Int, h: Int)] = [(x: 10, w: 180, y: 10, h: 80)]
        for x in stride(from: 190, to: 249, by: 1) { farBlobs.append((x: x, w: 1, y: 40, h: 20)) }
        farBlobs.append((x: 252, w: 140, y: 10, h: 80))
        let farValley = spriteProbe(width: 400, height: 100, blobs: farBlobs)
        do {
            let f = PetSpriteStrip.sliceStripByValleys(farValley, frames: 2)
            precondition(f.count == 2, "declared count survives")
            precondition(Int(f[0].size.width) < 240,
                         "the cut reached a column the narrow window excludes, got \(Int(f[0].size.width))")
        }

        // Case C: a genuine gap NEAR the grid cut still moves the cut, and both
        // figures survive whole.
        let realValley = spriteProbe(width: 400, height: 100, blobs: [
            (x: 10, w: 200, y: 10, h: 80),
            (x: 232, w: 158, y: 10, h: 80),
        ])
        do {
            let moved = PetSpriteStrip.sliceStripByValleys(realValley, frames: 2)
            precondition(moved.count == 2, "declared count survives a real valley")
            precondition(Int(moved[0].size.width) != 200,
                         "a genuine gap must pull the cut off the grid position")
            guard let b = PetSpriteStrip.inkBounds(moved[0]), let c = PetSpriteStrip.inkBounds(moved[1]) else {
                preconditionFailure("both valley frames must hold ink")
            }
            precondition(b.w == 200, "figure one was clipped, kept \(b.w) of 200 px")
            precondition(c.w == 158, "figure two was clipped, kept \(c.w) of 158 px")
        }

        // CELL BOARDS: islands + gap merge, forced to the manifest cell count.
        // The narrow 'bolt' 20px from scene one must ride with it.
        let strip = spriteProbe(width: 1600, height: 100, blobs: [
            (x: 80, w: 240, y: 20, h: 60),
            (x: 340, w: 40, y: 30, h: 20),
            (x: 700, w: 240, y: 20, h: 60),
            (x: 1200, w: 240, y: 20, h: 60),
        ])
        let forced = PetSpriteStrip.sliceRowByIslands(strip, count: 3, forceCount: true)
        precondition(forced.count == 3, "forceCount 3 failed on a 3-scene board")
        let forcedPair = PetSpriteStrip.sliceRowByIslands(strip, count: 2, forceCount: true)
        precondition(forcedPair.count == 2, "forceCount must merge closest scenes down to the cell count")

        // STRIPS: the declared frame count is intent. Cuts nudge to empty
        // valleys, so the bolt stays with scene one and no figure is bisected.
        let valley = PetSpriteStrip.sliceStripByValleys(strip, frames: 3)
        precondition(valley.count == 3, "valley slice must honor the declared frame count")
        precondition(valley[0].size.width > 380 && valley[0].size.width < 700,
                     "first cut must land in the empty span past the bolt, got width \(valley[0].size.width)")
        for frame in valley {
            precondition(inkFraction(frame, topHalf: true) + inkFraction(frame, topHalf: false) > 0,
                         "every valley frame keeps its scene")
        }
        let solid = spriteProbe(width: 160, height: 8, blobs: [(x: 0, w: 160, y: 0, h: 8)])
        precondition(PetSpriteStrip.sliceStripByValleys(solid, frames: 8).count == 8,
                     "continuous art must degrade to the equal slice")
        let prep = PetSpriteStrip.prepare(strip, frames: 3)
        precondition(prep.frames == 3,
                     "prepare must report the stitched frame count, got \(prep.frames)")

        // EDGE-SLIVER SUPPRESSION: a cut through a figure leaves truncated
        // neighbor content at the frame edge; it must be erased, while the
        // primary figure survives even when it reaches the edge itself.
        let bled = spriteProbe(width: 200, height: 40, blobs: [
            (x: 0, w: 10, y: 8, h: 24),
            (x: 60, w: 80, y: 8, h: 24),
            (x: 192, w: 8, y: 8, h: 24),
        ])
        let clean = PetSpriteStrip.suppressTruncatedEdgeSlivers(bled)
        do {
            guard let tiff = clean.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
                preconditionFailure("suppressed frame must rasterize")
            }
            precondition((rep.colorAt(x: 4, y: 20)?.alphaComponent ?? 1) < 0.1,
                         "left edge sliver must be erased")
            precondition((rep.colorAt(x: 196, y: 20)?.alphaComponent ?? 1) < 0.1,
                         "right edge sliver must be erased")
            precondition((rep.colorAt(x: 100, y: 20)?.alphaComponent ?? 0) > 0.5,
                         "the primary figure must survive sliver suppression")
        }
        // The hero touches the edge AND a second component exists, so the
        // filter is genuinely exercised (a one-blob frame returns early and
        // asserts nothing).
        let edgeHero = spriteProbe(width: 200, height: 40, blobs: [
            (x: 0, w: 120, y: 8, h: 24),
            (x: 150, w: 10, y: 18, h: 6),
        ])
        do {
            guard let tiff = PetSpriteStrip.suppressTruncatedEdgeSlivers(edgeHero).tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else {
                preconditionFailure("edge-hero frame must rasterize")
            }
            precondition((rep.colorAt(x: 4, y: 20)?.alphaComponent ?? 0) > 0.5,
                         "a primary figure touching the edge is the subject, not a sliver")
        }
        // A bisected neighbour at 42% of the primary's AREA survived the old
        // area rule; its cut face spans the full frame height, so the row-span
        // rule catches it.
        let bigSliver = spriteProbe(width: 200, height: 40, blobs: [
            (x: 40, w: 100, y: 4, h: 32),
            (x: 168, w: 32, y: 4, h: 32),
        ])
        do {
            guard let tiff = PetSpriteStrip.suppressTruncatedEdgeSlivers(bigSliver).tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else {
                preconditionFailure("big-sliver frame must rasterize")
            }
            precondition((rep.colorAt(x: 190, y: 20)?.alphaComponent ?? 1) < 0.1,
                         "a bisected neighbour must be erased whatever its area")
            precondition((rep.colorAt(x: 90, y: 20)?.alphaComponent ?? 0) > 0.5,
                         "the primary must survive")
        }
        // A small fragment CUT by the boundary is spillover however few rows it
        // spans — the real case is a 5%-area bolt from the next scene against
        // the left edge, which both an area rule and a cut-face-height rule
        // kept, and which reads on screen as a flash in the corner.
        let bolt = spriteProbe(width: 200, height: 40, blobs: [
            (x: 40, w: 100, y: 4, h: 32),
            (x: 194, w: 6, y: 18, h: 4),
        ])
        do {
            guard let tiff = PetSpriteStrip.suppressTruncatedEdgeSlivers(bolt).tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else {
                preconditionFailure("bolt frame must rasterize")
            }
            precondition((rep.colorAt(x: 196, y: 19)?.alphaComponent ?? 1) < 0.1,
                         "a fragment cut by the frame boundary is spillover and must go")
        }
        // Detail composed INSIDE the frame is part of the scene and stays.
        let insideDetail = spriteProbe(width: 200, height: 40, blobs: [
            (x: 40, w: 100, y: 4, h: 32),
            (x: 160, w: 8, y: 18, h: 4),
        ])
        do {
            guard let tiff = PetSpriteStrip.suppressTruncatedEdgeSlivers(insideDetail).tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else {
                preconditionFailure("inside-detail frame must rasterize")
            }
            precondition((rep.colorAt(x: 163, y: 19)?.alphaComponent ?? 0) > 0.5,
                         "a bolt inside the frame belongs to its scene and stays")
        }
        // A sliver whose COLUMNS overlap the figure is invisible to a column
        // projection; only 2D components catch it (three run-cycle slivers hid
        // this way on 0.5.115).
        let overlapped = spriteProbe(width: 200, height: 40, blobs: [
            (x: 40, w: 120, y: 4, h: 20),
            (x: 150, w: 50, y: 30, h: 8),
        ])
        do {
            guard let tiff = PetSpriteStrip.suppressTruncatedEdgeSlivers(overlapped).tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else {
                preconditionFailure("overlap frame must rasterize")
            }
            precondition((rep.colorAt(x: 190, y: 34)?.alphaComponent ?? 1) < 0.1,
                         "a column-overlapping edge sliver must still be erased")
            precondition((rep.colorAt(x: 100, y: 14)?.alphaComponent ?? 0) > 0.5,
                         "the figure must survive overlap-sliver suppression")
        }

        // SUBJECTLESS FRAMES: a story strip's droid-only scenes read as the
        // character blinking out. Colour content separates them (measured on
        // the combat board: hero 0.21-0.43, droid-only 0.012-0.10).
        let heroFrame = spriteProbe(width: 100, height: 40, blobs: [(x: 20, w: 60, y: 8, h: 24)])
        let droidFrame = spriteProbe(width: 100, height: 40, blobs: [(x: 20, w: 60, y: 8, h: 24)], gray: true)
        precondition(PetSpriteStrip.chromaFraction(heroFrame) > 0.9,
                     "a saturated frame must score near 1, got \(PetSpriteStrip.chromaFraction(heroFrame))")
        precondition(PetSpriteStrip.chromaFraction(droidFrame) < 0.1,
                     "a neutral frame must score near 0, got \(PetSpriteStrip.chromaFraction(droidFrame))")
        let story = [heroFrame, heroFrame, droidFrame, heroFrame, heroFrame]
        precondition(PetSpriteStrip.dropSubjectlessFrames(story).count == 4,
                     "the subjectless scene must be dropped from a story strip")
        let allGray = [droidFrame, droidFrame, droidFrame, droidFrame]
        precondition(PetSpriteStrip.dropSubjectlessFrames(allGray).count == 4,
                     "a uniformly monochrome pack is not a story strip; keep every frame")
        let mostlyGray = [droidFrame, droidFrame, droidFrame, heroFrame]
        precondition(PetSpriteStrip.dropSubjectlessFrames(mostlyGray).count == 4,
                     "never drop more than half a strip")
        precondition(PetSpriteStrip.dropSubjectlessFrames([heroFrame, droidFrame]).count == 2,
                     "a two-frame loop is left alone")

        // Realistic margins, not a 1.0/0.0 fixture: the combat board measures
        // heroes 0.21-0.43 and droid-only scenes 0.012-0.10, so the cut must
        // separate at THOSE values, not at a convenient extreme.
        // Three groups, as measured: bare droid 0.012, droid holding the blade
        // 0.10, heroes 0.21+. Both subjectless scenes must fall, and the
        // dimmest hero must survive.
        func cutFor(_ values: [Double]) -> Double {
            let s = values.sorted()
            let mid = s.count / 2
            let median = s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
            var cut = 0.0
            for j in 1..<s.count where s[j] <= median {
                if s[j] / max(s[j - 1], 0.0001) >= 1.7 { cut = (s[j - 1] + s[j]) / 2 }
            }
            return cut
        }
        let realCut = cutFor([0.21, 0.43, 0.012, 0.25, 0.10, 0.38])
        precondition(0.012 < realCut && 0.10 < realCut,
                     "both measured subjectless scenes must fall below the cut, got \(realCut)")
        precondition(0.21 > realCut,
                     "the dimmest measured hero frame must survive, cut \(realCut)")
        // A real run cycle has no decisive gap and must keep every frame.
        precondition(cutFor([0.29, 0.31, 0.31, 0.33, 0.35, 0.36, 0.37, 0.48]) == 0,
                     "a uniform run cycle must produce no cut")

        // ONE WIDTH: the panel and the rendered frame must agree, or the card
        // reserves space the art does not fill (or clips art it does).
        let cinematicAspect: CGFloat = 0.97
        let panel = PetSpritePose.swarm.renderSize(64, scale: 1.5, aspect: cinematicAspect)
        precondition(abs(panel.width - (panel.height * cinematicAspect).rounded()) < 1.5,
                     "renderSize must follow the measured aspect, got \(panel)")
        precondition(panel.width < PetSpritePose.swarm.spriteWidth(64, scale: 1.5),
                     "narrow art must claim less width than the fixed 2.6 default")
        let wide = PetSpritePose.swarm.renderSize(64, scale: 1.5, aspect: 9)
        precondition(wide.width <= (wide.height * 3.6).rounded() + 1,
                     "an absurd aspect must still be clamped so the frame cannot exceed the panel")
        precondition(PetSpritePose.swarm.spriteHeight(64, scale: 1.5)
                        == PetSpritePose.working.spriteHeight(64, scale: 1.5),
                     "cinematic and solo poses must share one authored height")
        var viewportKit = PetSpriteKit()
        viewportKit.poses[.idle] = [spriteProbe(
            width: 80, height: 100, blobs: [(x: 20, w: 40, y: 10, h: 80)]
        )]
        viewportKit.poses[.swarm] = [spriteProbe(
            width: 180, height: 100, blobs: [(x: 10, w: 160, y: 10, h: 80)]
        )]
        let viewport = viewportKit.viewportSize(pixels: 64, scale: 2)
        precondition(viewport.height == 128,
                     "the collapsed stage height must not change with session count")
        for pose in PetSpritePose.liveCases {
            let resolvedAspect = viewportKit.resolvedAspect(for: pose)
            let poseSize = pose.renderSize(64, scale: 2, aspect: resolvedAspect)
            precondition(poseSize.width <= viewport.width && poseSize.height <= viewport.height,
                         "the stable viewport must cover \(pose.rawValue)")
        }
        let idleDoubledViewport = viewportKit.viewportSize(
            pixels: 64, scale: 2, poseScales: [.idle: 2]
        )
        precondition(idleDoubledViewport.height == 256,
                     "a pack-owned 2x idle must reserve its full unclipped height")
        let emptyViewport = PetSpriteKit().viewportSize(pixels: 64, scale: 2)
        precondition(emptyViewport.width == emptyViewport.height,
                     "the square COS figure must not reserve a 2.6x cinematic viewport")
        for pose in PetSpritePose.liveCases {
            let emptyAspect = PetSpriteKit.resolvedAspect(frames: [])
            let rendered = pose.renderSize(64, scale: 2, aspect: emptyAspect)
            precondition(rendered == emptyViewport,
                         "empty \(pose.rawValue) rendering and its reserved viewport must agree")
        }

        // ESCALATION LADDER: three sessions must not look like five.
        var ladder = PetSpriteKit()
        ladder.cinematic = (0..<4).map { i in
            spriteProbe(width: 40, height: 40, blobs: [(x: 4 + i, w: 8, y: 4, h: 8)])
        }
        precondition(ladder.frames(for: .trio).count == 3,
                     "trio must climb the ladder only to its own rung")
        precondition(ladder.frames(for: .swarm).count == 4,
                     "swarm plays the full ladder")

        // ACTIVITY PLAYLIST: patrol is the one ambient transition. Running and
        // combat use authored story strips so their causal frame order cannot
        // be interrupted or replaced by a higher-session fallback.
        precondition(!PetSpritePose.working.usesActivityPlaylist)
        precondition(PetSpritePose.patrol.usesActivityPlaylist)
        precondition(!PetSpritePose.duel.usesActivityPlaylist)
        precondition(!PetSpritePose.idle.usesActivityPlaylist)
        var actionBeats = 0
        for segment in 0..<600 where PetPlaylist.isActionSegment(segment) { actionBeats += 1 }
        precondition(actionBeats > 120 && actionBeats < 280,
                     "action should be a minority of beats, got \(actionBeats)/600")
        precondition(PetPlaylist.isActionSegment(7) == PetPlaylist.isActionSegment(7),
                     "the schedule must be deterministic")
        var runs = 0, longest = 0, current = 0
        for segment in 0..<600 {
            if PetPlaylist.isActionSegment(segment) { current += 1; longest = max(longest, current) }
            else { if current > 0 { runs += 1 }; current = 0 }
        }
        precondition(runs > 40, "action beats must recur, not clump into one stretch")
        precondition(longest <= 2,
                     "a burst is at most two beats; a third is a loop, longest was \(longest)")
        let restPlan = PetPlaylist.plan(elapsed: 0.0, actionCount: 8, restCounts: [8], interval: 0.1)
        precondition(restPlan.index == 0, "a beat starts at its first frame")
        let midPlan = PetPlaylist.plan(elapsed: 0.35, actionCount: 8, restCounts: [8], interval: 0.1)
        precondition(midPlan.index == 3, "frames step at the pose interval, got \(midPlan.index)")
        let wrapPlan = PetPlaylist.plan(elapsed: 1.25, actionCount: 4, restCounts: [4], interval: 0.1)
        precondition(wrapPlan.index < 4, "the index must stay inside the clip")
        precondition(PetPlaylist.plan(elapsed: -5, actionCount: 8, restCounts: [8], interval: 0.1).index == 0,
                     "a negative clock must not index out of the clip")
        precondition(PetPlaylist.plan(elapsed: 3, actionCount: 0, restCounts: [], interval: 0).index == 0,
                     "an empty clip must degrade safely")
        precondition(PetPlaylist.plan(elapsed: 3, actionCount: 6, restCounts: [], interval: 0.1).useAction,
                     "with no rest clips the action must still play")
        guard let restSegment = (0..<100).first(where: { !PetPlaylist.isActionSegment($0) }) else {
            preconditionFailure("the deterministic playlist must contain a rest beat")
        }
        let slowerRest = PetPlaylist.plan(
            elapsed: Double(restSegment) * PetPlaylist.segmentSeconds + 0.35,
            actionCount: 8,
            restCounts: [8],
            interval: 0.1,
            restIntervals: [0.2]
        )
        precondition(!slowerRest.useAction && slowerRest.index == 1,
                     "secondary strips must retain their authored interval, got \(slowerRest)")
        var exactKit = PetSpriteKit()
        exactKit.poses[.duel] = [
            spriteProbe(width: 40, height: 40, blobs: [(x: 8, w: 24, y: 8, h: 24)]),
            spriteProbe(width: 40, height: 40, blobs: [(x: 9, w: 22, y: 8, h: 24)]),
        ]
        precondition(exactKit.exactFrames(for: .trio).isEmpty,
                     "secondary clips must not resolve through a higher-session fallback")

        // REST ROTATION: patrol's settled beats must spread across its two calm
        // exact clips (idle and waiting) without starving either one.
        var restUse = [Int: Int]()
        var restBeats = 0
        for segment in 0..<600 where !PetPlaylist.isActionSegment(segment) {
            restBeats += 1
            restUse[PetPlaylist.restClip(segment, count: 2), default: 0] += 1
        }
        precondition(restUse.count == 2, "both calm patrol clips must appear, saw \(restUse.count)")
        let leanest = restUse.values.min() ?? 0
        precondition(Double(leanest) > Double(restBeats) / 2.0 * 0.5,
                     "no rest clip may be starved, leanest got \(leanest) of \(restBeats)")
        precondition(PetPlaylist.restClip(9, count: 2) == PetPlaylist.restClip(9, count: 2),
                     "rest selection must be deterministic")
        precondition(PetPlaylist.restClip(9, count: 1) == 0, "a single rest clip is always index 0")

        // STRIP NORMALISATION: authored size differences must SURVIVE, and ink
        // must share a baseline. Per-frame fitHeight rendered a short pose and
        // a tall pose at the same height — the character resizing mid-animation.
        let shortPose = spriteProbe(width: 120, height: 120, blobs: [(x: 40, w: 30, y: 70, h: 30)])
        let tallPose = spriteProbe(width: 120, height: 120, blobs: [(x: 40, w: 30, y: 40, h: 60)])
        let normalized = PetSpriteStrip.normalizeStrip([shortPose, tallPose])
        precondition(normalized.count == 2, "normalisation must not change the frame count")
        guard let nShort = PetSpriteStrip.inkBounds(normalized[0]),
              let nTall = PetSpriteStrip.inkBounds(normalized[1]) else {
            preconditionFailure("normalised frames must hold ink")
        }
        precondition(normalized[0].size == normalized[1].size,
                     "every frame shares one canvas, so one scale applies to all")
        let sizeRatio = Double(nTall.h) / Double(nShort.h)
        precondition(sizeRatio > 1.8 && sizeRatio < 2.2,
                     "the 2:1 authored height ratio must survive, got \(String(format: "%.2f", sizeRatio))")
        precondition(abs((nShort.y + nShort.h) - (nTall.y + nTall.h)) <= 1,
                     "ink bottoms must land on a shared baseline")
        // Frames must also reach the SAME canvas independently of their own ink
        // box; that is what guarantees one scale downstream, since fitHeight
        // applies the same factor to identically sized inputs.
        let wideEffect = spriteProbe(width: 120, height: 120, blobs: [(x: 10, w: 100, y: 80, h: 20)])
        let three = PetSpriteStrip.normalizeStrip([shortPose, tallPose, wideEffect])
        precondition(Set(three.map(\.size.width)).count == 1 && Set(three.map(\.size.height)).count == 1,
                     "a frame with a wide effect must share the strip's canvas, not get its own")

        // AUTHORED MILES STORIES: every session-count state owns one directed,
        // physically continuous strip. Running bookends one and two sessions;
        // trio and swarm keep Miles plus their droids present until contact.
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let defaultPet = repositoryRoot.appendingPathComponent("Resources/DefaultPet")
        let shippedMap = PetSpriteStore.loadStateMap(in: defaultPet)
        precondition(PetSpriteStrip.clampFrames(-1) == 1
                        && PetSpriteStrip.clampFrames(17) == 17
                        && PetSpriteStrip.clampFrames(23) == 23
                        && PetSpriteStrip.clampFrames(32) == 32
                        && PetSpriteStrip.clampFrames(99) == 32,
                     "authored counts above 16 must survive the bounded frame contract")
        let authoredStories: [(pose: PetSpritePose, file: String, frames: Int)] = [
            (.working, "session-pet-working-one-droid-v15-2.png", 16),
            (.duel, "session-pet-duel-two-droid-v15-2.png", 17),
            (.trio, "session-pet-trio-story-v15-2.png", 13),
            (.swarm, "session-pet-swarm-story-v15-2.png", 23),
        ]
        var storyFrames: [PetSpritePose: [NSImage]] = [:]
        for story in authoredStories {
            precondition(shippedMap[story.pose]?.file == story.file
                            && shippedMap[story.pose]?.frames == story.frames,
                         "\(story.pose.rawValue) must map to its V15.2 story and declared count")
            guard let image = NSImage(contentsOf: defaultPet.appendingPathComponent(story.file))
            else { preconditionFailure("Miles \(story.pose.rawValue) story must be readable") }
            let frames = PetSpriteStrip.slice(image, frames: story.frames)
            precondition(frames.count == story.frames,
                         "\(story.pose.rawValue) must slice to its authored count")
            storyFrames[story.pose] = frames
        }
        func subjectColorCounts(_ frame: NSImage) -> (hero: Int, droidEye: Int) {
            guard let cg = PetSpriteStrip.raster(frame) else { return (0, 0) }
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            pixels.withUnsafeMutableBytes { raw in
                guard let context = CGContext(
                    data: raw.baseAddress,
                    width: cg.width,
                    height: cg.height,
                    bitsPerComponent: 8,
                    bytesPerRow: cg.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return }
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            var hero = 0
            var droidEye = 0
            for y in 0..<cg.height {
                for x in 0..<cg.width {
                    let index = (y * cg.width + x) * 4
                    let r = Int(pixels[index])
                    let g = Int(pixels[index + 1])
                    let b = Int(pixels[index + 2])
                    let a = Int(pixels[index + 3])
                    guard a > 32 else { continue }
                    if r > 75 && g > 30 && g < 155 && b < 75 { hero += 1 }
                    if r > 125 && g < 70 && b < 70 {
                        droidEye += 1
                    }
                }
            }
            return (hero, droidEye)
        }
        for story in authoredStories {
            let frames = storyFrames[story.pose]!
            for (index, frame) in frames.enumerated() {
                guard let raster = PetSpriteStrip.raster(frame),
                      let box = PetSpriteStrip.inkBounds(frame) else {
                    preconditionFailure("\(story.pose.rawValue) frame \(index) must contain art")
                }
                precondition(box.x >= 3 && box.x + box.w <= raster.width - 3,
                             "\(story.pose.rawValue) frame \(index) touches a cut boundary")
                precondition(box.y >= 3 && box.y + box.h <= raster.height - 3,
                             "\(story.pose.rawValue) frame \(index) crops authored art")
                // Swarm's late sprint-away beat intentionally pulls Miles back
                // to sell depth before the next rush; 80px still rejects the
                // genuinely tiny legacy figures without rejecting that shot.
                precondition(box.h >= 80,
                             "\(story.pose.rawValue) frame \(index) is undersized (\(box.h)px ink)")
                let subjects = subjectColorCounts(frame)
                precondition(subjects.hero >= 20,
                             "\(story.pose.rawValue) frame \(index) drops Miles")
                let authoredDroidFreeBeat = (story.pose == .duel && [12, 13, 14].contains(index + 1))
                    || (story.pose == .swarm && index + 1 == 22)
                if (story.pose == .duel || story.pose == .trio || story.pose == .swarm)
                    && !authoredDroidFreeBeat {
                    precondition(subjects.droidEye >= 1,
                                 "\(story.pose.rawValue) frame \(index) drops every droid")
                }
                if index > 0 {
                    precondition(pngData(frames[index - 1]) != pngData(frame),
                                 "\(story.pose.rawValue) frame \(index) stalls unexpectedly")
                }
            }
            // V15.1 uses a continuous seam rather than duplicating F1 at the
            // end: the final recovery beat leads into the opening beat. Exact
            // duplicate endpoints would add a visible one-frame stall.
            precondition(pngData(frames.first!) != pngData(frames.last!),
                         "\(story.pose.rawValue) must not stall on a duplicated seam frame")
        }

        // SHIPPED DEFAULT: seeds an empty install, and never overwrites the
        // user's own sprites (which would undo Choose sprite or Use COS figure).
        precondition(PetSpriteStore.bundledCharacters.count == 4,
                     "this release must expose Miles plus the three Jedi character additions")
        precondition(PetSpriteStore.bundledCharacter(id: "jedi-miles-windu")?.displayName
                        == "Jedi Miles Windu",
                     "the bundled character registry must resolve Miles by stable id")
        let addedCharacters = [
            ("jedi-nia-solari", "Jedi Nia Solari", "BundledCharacters/jedi-nia-solari"),
            ("jedi-elara-vale", "Jedi Elara Vale", "BundledCharacters/jedi-elara-vale"),
            ("jedi-rowan-vale", "Jedi Rowan Vale", "BundledCharacters/jedi-rowan-vale"),
        ]
        for (id, name, folder) in addedCharacters {
            guard let character = PetSpriteStore.bundledCharacter(id: id) else {
                preconditionFailure("the bundled character registry must resolve \(id)")
            }
            precondition(character.displayName == name,
                         "\(id) must keep the name shown in the character gallery")
            precondition(character.folderName == folder,
                         "\(id) must resolve its packaged resource folder")
        }
        precondition(PetSpriteStore.defaultCharacterName == "Jedi Miles Windu",
                     "the seeded default and selectable catalog entry must share one identity")
        let seedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cos-seed-\(ProcessInfo.processInfo.processIdentifier)")
        let seedSource = seedRoot.appendingPathComponent("DefaultPet", isDirectory: true)
        let seedDest = seedRoot.appendingPathComponent("support", isDirectory: true)
        try? FileManager.default.removeItem(at: seedRoot)
        try! FileManager.default.createDirectory(at: seedSource, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: seedDest, withIntermediateDirectories: true)
        let seedArt = spriteProbe(width: 40, height: 40, blobs: [(x: 8, w: 24, y: 8, h: 24)])
        try! NSBitmapImageRep(data: seedArt.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
            .write(to: seedSource.appendingPathComponent("session-pet-idle.png"))
        try! Data(#"{"poses":{"idle":{"file":"session-pet-idle.png","frames":1}}}"#.utf8)
            .write(to: seedSource.appendingPathComponent("session-pet-states.json"))
        precondition(PetSpriteStore.installDefault(into: seedDest, from: seedSource),
                     "an empty install must be seeded with the shipped character")
        precondition(PetSpriteStore.loadStateMap(in: seedDest)[.idle]?.frames == 1,
                     "the seeded state map must be readable")
        precondition(!PetSpriteStore.installDefault(into: seedDest, from: seedSource),
                     "seeding must never overwrite sprites that are already installed")
        precondition(!PetSpriteStore.installDefault(into: seedDest, from: nil),
                     "a build without the bundled character must degrade quietly")

        let bundledRoot = repositoryRoot.appendingPathComponent(
            "Resources/BundledCharacters", isDirectory: true
        )
        let legacyJediMap = #"{"poses":{"attention":{"file":"session-pet-idle.png","frames":1},"done":{"file":"session-pet-idle.png","frames":1},"duel":{"file":"session-pet-duel.png","frames":4},"error":{"file":"session-pet-idle.png","frames":1},"idle":{"file":"session-pet-idle.png","frames":1},"patrol":{"file":"session-pet-idle.png","frames":1},"swarm":{"file":"session-pet-swarm.png","frames":4},"trio":{"file":"session-pet-trio.png","frames":4},"waiting":{"file":"session-pet-idle.png","frames":1},"working":{"file":"session-pet-idle.png","frames":1}}}"#
        for (id, _, _) in addedCharacters {
            let source = bundledRoot.appendingPathComponent(id, isDirectory: true)
            let legacyDest = seedRoot.appendingPathComponent("legacy-\(id)", isDirectory: true)
            try! FileManager.default.createDirectory(at: legacyDest, withIntermediateDirectories: true)
            for file in [
                "session-pet-idle.png", "session-pet-duel.png",
                "session-pet-trio.png", "session-pet-swarm.png",
            ] {
                try! FileManager.default.copyItem(
                    at: source.appendingPathComponent(file),
                    to: legacyDest.appendingPathComponent(file)
                )
            }
            try! Data(legacyJediMap.utf8).write(
                to: legacyDest.appendingPathComponent("session-pet-states.json"),
                options: .atomic
            )
            precondition(PetSpriteStore.refreshRecognizedBundledCharacter(
                into: legacyDest, sourceRootOverride: bundledRoot
            ) == .refreshed(id), "\(id) must upgrade from retained four-frame art")
            let upgraded = PetSpriteStore.loadStateMap(in: legacyDest)
            let upgradedIntervals = PetSpriteStore.loadFrameIntervals(in: legacyDest)
            precondition(upgraded[.working]?.frames == 16
                            && upgraded[.duel]?.frames == 12
                            && upgraded[.trio]?.frames == 13
                            && upgraded[.swarm]?.frames == 16,
                         "\(id) did not receive its complete 16/12/13/16 stories")
            precondition(upgraded[.idle]?.file == "session-pet-idle.png",
                         "\(id) migration changed a non-story pose")
            let expectedWorkingInterval = id == "jedi-nia-solari" ? 0.095 : 0.1
            let expectedSwarmInterval = id == "jedi-nia-solari" ? 0.085 : 0.2
            precondition(abs((upgradedIntervals[.working] ?? 0) - expectedWorkingInterval) < 0.000001
                            && abs((upgradedIntervals[.swarm] ?? 0) - expectedSwarmInterval) < 0.000001,
                         "\(id) did not preserve its authored story cadence")

            let customDest = seedRoot.appendingPathComponent("custom-\(id)", isDirectory: true)
            try! FileManager.default.createDirectory(at: customDest, withIntermediateDirectories: true)
            for file in [
                "session-pet-idle.png", "session-pet-duel.png",
                "session-pet-trio.png", "session-pet-swarm.png",
            ] {
                try! FileManager.default.copyItem(
                    at: source.appendingPathComponent(file),
                    to: customDest.appendingPathComponent(file)
                )
            }
            try! Data(legacyJediMap.utf8).write(
                to: customDest.appendingPathComponent("session-pet-states.json"),
                options: .atomic
            )
            let customData = Data("custom duel art".utf8)
            try! customData.write(
                to: customDest.appendingPathComponent("session-pet-duel.png"),
                options: .atomic
            )
            precondition(PetSpriteStore.refreshRecognizedBundledCharacter(
                into: customDest, sourceRootOverride: bundledRoot
            ) == .notApplicable, "a customized \(id) pack must never be overwritten")
            precondition(try! Data(contentsOf: customDest.appendingPathComponent(
                "session-pet-duel.png"
            )) == customData, "\(id) migration changed customized bytes")
        }

        // 0.5.138 shipped Elara's complete V1 stories with an oversized white
        // extraction matte around the green saber. Generation 9 recognizes
        // only those exact retained bytes and atomically promotes them to V1.1.
        let elaraSource = bundledRoot.appendingPathComponent(
            "jedi-elara-vale", isDirectory: true
        )
        let elaraV1Template = seedRoot.appendingPathComponent(
            "elara-v1-template", isDirectory: true
        )
        try! FileManager.default.createDirectory(
            at: elaraV1Template, withIntermediateDirectories: true
        )
        for file in [
            "session-pet-idle.png",
            "session-pet-working-story-v1.png",
            "session-pet-duel-story-v1.png",
            "session-pet-trio-story-v1.png",
            "session-pet-swarm-story-v1.png",
        ] {
            try! FileManager.default.copyItem(
                at: elaraSource.appendingPathComponent(file),
                to: elaraV1Template.appendingPathComponent(file)
            )
        }
        let elaraV1Map = #"{"poses":{"attention":{"file":"session-pet-idle.png","frames":1},"done":{"file":"session-pet-idle.png","frames":1},"duel":{"file":"session-pet-duel-story-v1.png","frames":12,"interval":0.14},"error":{"file":"session-pet-idle.png","frames":1},"idle":{"file":"session-pet-idle.png","frames":1},"patrol":{"file":"session-pet-idle.png","frames":1},"swarm":{"file":"session-pet-swarm-story-v1.png","frames":16,"interval":0.2},"trio":{"file":"session-pet-trio-story-v1.png","frames":13,"interval":0.18},"waiting":{"file":"session-pet-idle.png","frames":1},"working":{"file":"session-pet-working-story-v1.png","frames":16,"interval":0.1}}}"#
        try! Data(elaraV1Map.utf8).write(
            to: elaraV1Template.appendingPathComponent("session-pet-states.json"),
            options: .atomic
        )
        let elaraV1Dest = seedRoot.appendingPathComponent(
            "elara-v1-stock", isDirectory: true
        )
        try! FileManager.default.copyItem(at: elaraV1Template, to: elaraV1Dest)
        let elaraV1Result = PetSpriteStore.refreshRecognizedBundledElaraV1(
            into: elaraV1Dest, sourceOverride: elaraSource
        )
        precondition(elaraV1Result == .refreshed("jedi-elara-vale"),
        "the retained Elara V1 story pack must upgrade to corrected V1.1 art")
        let elaraV1Refreshed = PetSpriteStore.loadStateMap(in: elaraV1Dest)
        for pose in [PetSpritePose.working, .duel, .trio, .swarm] {
            precondition(elaraV1Refreshed[pose]?.file
                            == "session-pet-\(pose.rawValue)-story-v1-1.png",
                         "Elara V1.1 migration did not replace \(pose.rawValue)")
        }

        let customElaraV1 = seedRoot.appendingPathComponent(
            "elara-v1-custom", isDirectory: true
        )
        try! FileManager.default.copyItem(at: elaraV1Template, to: customElaraV1)
        let customElaraBytes = Data("custom Elara story art".utf8)
        try! customElaraBytes.write(
            to: customElaraV1.appendingPathComponent("session-pet-working-story-v1.png"),
            options: .atomic
        )
        precondition(PetSpriteStore.refreshRecognizedBundledElaraV1(
            into: customElaraV1, sourceOverride: elaraSource
        ) == .notApplicable,
        "Elara V1.1 migration must not overwrite customized story art")
        precondition(try! Data(contentsOf: customElaraV1.appendingPathComponent(
            "session-pet-working-story-v1.png"
        )) == customElaraBytes, "Elara V1.1 migration changed customized bytes")

        let legacyTemplate = seedRoot.appendingPathComponent("legacy-template", isDirectory: true)
        try! FileManager.default.createDirectory(at: legacyTemplate, withIntermediateDirectories: true)
        for file in try! FileManager.default.contentsOfDirectory(
            at: defaultPet, includingPropertiesForKeys: nil
        ) where ["png", "json"].contains(file.pathExtension.lowercased()) {
            try! FileManager.default.copyItem(
                at: file, to: legacyTemplate.appendingPathComponent(file.lastPathComponent)
            )
        }
        let legacyMilesMap = #"{"poses":{"idle":{"file":"session-pet-idle.png","frames":8},"patrol":{"file":"session-pet-patrol.png","frames":8},"waiting":{"file":"session-pet-waiting.png","frames":8},"working":{"file":"session-pet-working.png","frames":8},"done":{"file":"session-pet-done.png","frames":8},"error":{"file":"session-pet-error.png","frames":8},"attention":{"file":"session-pet-attention.png","frames":6},"duel":{"file":"session-pet-duel.png","frames":8,"interval":0.14666666666666667},"trio":{"file":"session-pet-trio.png","frames":6},"swarm":{"file":"session-pet-swarm.png","frames":6}}}"#
        try! Data(legacyMilesMap.utf8).write(
            to: legacyTemplate.appendingPathComponent("session-pet-states.json"), options: .atomic
        )
        let refreshDest = seedRoot.appendingPathComponent("legacy-miles", isDirectory: true)
        try! FileManager.default.copyItem(at: legacyTemplate, to: refreshDest)
        precondition(PetSpriteStore.refreshRecognizedBundledDefault(
            into: refreshDest, from: defaultPet
        ) == .refreshed, "the recognized pre-story Miles pack must refresh once")
        let refreshedMap = PetSpriteStore.loadStateMap(in: refreshDest)
        let refreshedScales = PetSpriteStore.loadRenderScales(in: refreshDest)
        precondition(refreshedMap[.working]?.frames == 16
                        && refreshedMap[.duel]?.frames == 17
                        && refreshedMap[.trio]?.frames == 13
                        && refreshedMap[.swarm]?.frames == 23,
                     "the refresh must install all four authored story strips")
        precondition(refreshedScales[.idle] == 3,
                     "the refresh must land the pack-owned Miles idle scale")
        // The live 0.5.141 defect: the seed carries the stale V15-1 duel
        // interval (0.1467), and the refresh replaces the duel FILE — so the
        // cadence must come from the bundle, not be retained. Retention left
        // the 17-frame V15.2 duel playing 33% slow on Miles's machine.
        let refreshedIntervals = PetSpriteStore.loadFrameIntervals(in: refreshDest)
        precondition(refreshedIntervals[.duel].map { abs($0 - 0.11) < 0.0001 } == true,
                     "a pose whose art is replaced must take the bundled interval, "
                     + "got \(String(describing: refreshedIntervals[.duel]))")
        precondition(refreshedMap[.patrol]?.file == "session-pet-patrol.png",
                     "the targeted refresh must preserve every unrelated pose mapping")

        let priorStoryTemplate = seedRoot.appendingPathComponent(
            "prior-story-template", isDirectory: true
        )
        try! FileManager.default.copyItem(at: legacyTemplate, to: priorStoryTemplate)
        let priorStoryMap = #"{"poses":{"idle":{"file":"session-pet-idle.png","frames":8},"patrol":{"file":"session-pet-patrol.png","frames":8},"waiting":{"file":"session-pet-waiting.png","frames":8},"working":{"file":"session-pet-working-error-story.png","frames":16},"done":{"file":"session-pet-done.png","frames":8},"error":{"file":"session-pet-error.png","frames":8},"attention":{"file":"session-pet-attention.png","frames":6},"duel":{"file":"session-pet-duel-two-droid-v5.png","frames":13},"trio":{"file":"session-pet-trio.png","frames":6},"swarm":{"file":"session-pet-swarm.png","frames":6}}}"#
        try! Data(priorStoryMap.utf8).write(
            to: priorStoryTemplate.appendingPathComponent("session-pet-states.json"),
            options: .atomic
        )
        precondition(PetSpriteStore.refreshRecognizedBundledDefault(
            into: priorStoryTemplate, from: defaultPet
        ) == .refreshed, "the retained prior story pack must upgrade to V15.1")
        let priorRefreshedMap = PetSpriteStore.loadStateMap(in: priorStoryTemplate)
        for story in authoredStories {
            precondition(priorRefreshedMap[story.pose]?.file == story.file
                            && priorRefreshedMap[story.pose]?.frames == story.frames,
                         "prior story refresh must promote \(story.pose.rawValue) to V15.1")
        }

        // 0.5.134 already stamped the previous art generation after installing
        // V7. Generation 5 must recognize that exact retained pack and advance
        // it to V15.1 instead of leaving existing Miles users behind.
        let v7Template = seedRoot.appendingPathComponent("v7-template", isDirectory: true)
        try! FileManager.default.copyItem(at: legacyTemplate, to: v7Template)
        let v7Map = #"{"poses":{"idle":{"file":"session-pet-idle.png","frames":8},"patrol":{"file":"session-pet-patrol.png","frames":8},"waiting":{"file":"session-pet-waiting.png","frames":8},"working":{"file":"session-pet-working-story-v7.png","frames":16},"done":{"file":"session-pet-done.png","frames":8},"error":{"file":"session-pet-error.png","frames":8},"attention":{"file":"session-pet-attention.png","frames":6},"duel":{"file":"session-pet-duel-story-v7.png","frames":16},"trio":{"file":"session-pet-trio-story-v7.png","frames":12},"swarm":{"file":"session-pet-swarm-story-v7.png","frames":16}}}"#
        try! Data(v7Map.utf8).write(
            to: v7Template.appendingPathComponent("session-pet-states.json"), options: .atomic
        )
        precondition(PetSpriteStore.refreshRecognizedBundledDefault(
            into: v7Template, from: defaultPet
        ) == .refreshed, "the retained V7 Miles pack must upgrade to V15.1")
        let v7RefreshedMap = PetSpriteStore.loadStateMap(in: v7Template)
        for story in authoredStories {
            precondition(v7RefreshedMap[story.pose]?.file == story.file
                            && v7RefreshedMap[story.pose]?.frames == story.frames,
                         "V7 refresh must promote \(story.pose.rawValue) to V15.1")
        }

        // 0.5.138 shipped V15 even though V15.1 had been approved in canary.
        // Generation 8 must recognize those exact retained bytes and replace
        // them with V15.1 rather than stranding the current installed app.
        let v15Template = seedRoot.appendingPathComponent("v15-template", isDirectory: true)
        try! FileManager.default.copyItem(at: legacyTemplate, to: v15Template)
        let v15Map = #"{"poses":{"idle":{"file":"session-pet-idle.png","frames":8},"patrol":{"file":"session-pet-patrol.png","frames":8},"waiting":{"file":"session-pet-waiting.png","frames":8},"working":{"file":"session-pet-working-one-droid-v15.png","frames":16},"done":{"file":"session-pet-done.png","frames":8},"error":{"file":"session-pet-error.png","frames":8},"attention":{"file":"session-pet-attention.png","frames":6},"duel":{"file":"session-pet-duel-two-droid-v15.png","frames":13},"trio":{"file":"session-pet-trio-story-v15.png","frames":13},"swarm":{"file":"session-pet-swarm-story-v15.png","frames":16}}}"#
        try! Data(v15Map.utf8).write(
            to: v15Template.appendingPathComponent("session-pet-states.json"), options: .atomic
        )
        precondition(PetSpriteStore.refreshRecognizedBundledDefault(
            into: v15Template, from: defaultPet
        ) == .refreshed, "the retained V15 Miles pack must upgrade to V15.1")
        let v15RefreshedMap = PetSpriteStore.loadStateMap(in: v15Template)
        for story in authoredStories {
            precondition(v15RefreshedMap[story.pose]?.file == story.file
                            && v15RefreshedMap[story.pose]?.frames == story.frames,
                         "V15 refresh must promote \(story.pose.rawValue) to V15.1")
        }
        precondition(PetSpriteStore.loadRenderScales(in: v15Template)[.idle] == 3,
                     "V15 refresh must land the 3x idle scale")

        // 0.5.139 already carries the V15.1 story bytes and a stock 2x idle
        // scale. Generation 11 must recognize that exact install, upgrade the
        // stories and stock scale, and preserve a manually-authored scale.
        let stockV151 = seedRoot.appendingPathComponent("stock-v15-1", isDirectory: true)
        try! FileManager.default.copyItem(at: defaultPet, to: stockV151)
        let stockMapURL = stockV151.appendingPathComponent("session-pet-states.json")
        var stockPayload = try! JSONSerialization.jsonObject(
            with: Data(contentsOf: stockMapURL)
        ) as! [String: Any]
        var stockPoses = stockPayload["poses"] as! [String: [String: Any]]
        // Exercise the actual published V15.1 source map, not a clone of the
        // new map. Retained old bytes are required for the recognition gate.
        for (pose, file, count) in [
            ("working", "session-pet-working-one-droid-v15-1.png", 16),
            ("duel", "session-pet-duel-two-droid-v15-1.png", 12),
            ("trio", "session-pet-trio-story-v15-1.png", 13),
            ("swarm", "session-pet-swarm-story-v15-1.png", 16),
        ] {
            stockPoses[pose]?["file"] = file
            stockPoses[pose]?["frames"] = count
        }
        stockPoses[PetSpritePose.idle.rawValue]?["renderScale"] = 2
        stockPayload["poses"] = stockPoses
        try! JSONSerialization.data(
            withJSONObject: stockPayload, options: [.prettyPrinted, .sortedKeys]
        ).write(to: stockMapURL, options: .atomic)
        precondition(PetSpriteStore.refreshRecognizedBundledDefault(
            into: stockV151, from: defaultPet
        ) == .refreshed, "the retained V15.1 Miles pack must accept the 3x idle upgrade")
        precondition(PetSpriteStore.loadRenderScales(in: stockV151)[.idle] == 3,
                     "the retained stock 2x Miles idle must upgrade to 3x")
        let migratedV152 = PetSpriteStore.loadStateMap(in: stockV151)
        for story in authoredStories {
            precondition(migratedV152[story.pose]?.file == story.file
                            && migratedV152[story.pose]?.frames == story.frames,
                         "published V15.1 must migrate every story to V15.2")
        }
        let migratedIntervals = PetSpriteStore.loadFrameIntervals(in: stockV151)
        precondition(abs((migratedIntervals[.duel] ?? 0) - 0.11) < 0.000001,
                     "V15.2 duel migration must preserve all 17 frames at 0.11s")

        let customScaleV151 = seedRoot.appendingPathComponent(
            "custom-scale-v15-1", isDirectory: true
        )
        try! FileManager.default.copyItem(at: defaultPet, to: customScaleV151)
        let customScaleMapURL = customScaleV151.appendingPathComponent(
            "session-pet-states.json"
        )
        var customScalePayload = try! JSONSerialization.jsonObject(
            with: Data(contentsOf: customScaleMapURL)
        ) as! [String: Any]
        var customScalePoses = customScalePayload["poses"] as! [String: [String: Any]]
        customScalePoses[PetSpritePose.idle.rawValue]?["renderScale"] = 1.5
        customScalePayload["poses"] = customScalePoses
        try! JSONSerialization.data(
            withJSONObject: customScalePayload, options: [.prettyPrinted, .sortedKeys]
        ).write(to: customScaleMapURL, options: .atomic)
        precondition(PetSpriteStore.refreshRecognizedBundledDefault(
            into: customScaleV151, from: defaultPet
        ) == .refreshed, "custom-scale stock art must remain eligible for story refresh")
        precondition(PetSpriteStore.loadRenderScales(in: customScaleV151)[.idle] == 1.5,
                     "a manually-authored Miles idle scale must remain untouched")

        for pose in [PetSpritePose.working, .duel, .trio, .swarm, .patrol] {
            let customDest = seedRoot.appendingPathComponent(
                "custom-\(pose.rawValue)", isDirectory: true
            )
            try! FileManager.default.copyItem(at: legacyTemplate, to: customDest)
            let customData = Data("custom \(pose.rawValue) art".utf8)
            try! customData.write(
                to: customDest.appendingPathComponent(PetSpriteStore.poseFileName(pose)),
                options: .atomic
            )
            precondition(PetSpriteStore.refreshRecognizedBundledDefault(
                into: customDest, from: defaultPet
            ) == .notApplicable, "a customized \(pose.rawValue) pose must never be overwritten")
            precondition((try! Data(contentsOf: customDest.appendingPathComponent(
                PetSpriteStore.poseFileName(pose)
            ))) == customData, "migration changed customized \(pose.rawValue) bytes")
        }

        let brokenSource = seedRoot.appendingPathComponent("broken-source", isDirectory: true)
        try! FileManager.default.copyItem(at: defaultPet, to: brokenSource)
        try! FileManager.default.removeItem(
            at: brokenSource.appendingPathComponent("session-pet-swarm-story-v15-2.png")
        )
        let retryDest = seedRoot.appendingPathComponent("retryable-legacy", isDirectory: true)
        try! FileManager.default.copyItem(at: legacyTemplate, to: retryDest)
        let oldMapData = try! Data(contentsOf: retryDest.appendingPathComponent("session-pet-states.json"))
        precondition(PetSpriteStore.refreshRecognizedBundledDefault(
            into: retryDest, from: brokenSource
        ) == .failed, "a missing story asset must report a retryable migration failure")
        precondition(try! Data(contentsOf: retryDest.appendingPathComponent(
            "session-pet-states.json"
        )) == oldMapData, "failed refresh must leave the old state map active")
        try? FileManager.default.removeItem(at: seedRoot)

        // CHARACTER DIAL: scales the figure, never the card.
        precondition(PetCharacterScale.clamp(40) == PetCharacterScale.minPercent)
        precondition(PetCharacterScale.clamp(9000) == PetCharacterScale.maxPercent)
        precondition(PetCharacterScale.defaultPercent == 300)
        precondition(PetCharacterScale.maxPercent == 600)
        precondition(PetCharacterScale.migratedLegacyPercent(nil) == 300,
                     "a fresh install doubles the legacy 150% default")
        precondition(PetCharacterScale.migratedLegacyPercent(300) == 600,
                     "someone already at the old maximum must visibly grow after updating")
        precondition(PetCharacterScale.migratedLegacyPercent(40) == 200,
                     "migration clamps to the old range before doubling")
        let scaleSuite = "com.gotcos.control.tests.character-scale.\(UUID().uuidString)"
        let scaleDefaults = UserDefaults(suiteName: scaleSuite)!
        defer { scaleDefaults.removePersistentDomain(forName: scaleSuite) }
        scaleDefaults.set(300, forKey: "percent")
        precondition(PetCharacterScale.loadPersistedPercent(
            defaults: scaleDefaults,
            percentKey: "percent",
            generationKey: "generation",
            generation: 2
        ) == 600)
        precondition(scaleDefaults.integer(forKey: "percent") == 600
                     && scaleDefaults.integer(forKey: "generation") == 2,
                     "first load must persist both the doubled value and its generation")
        precondition(PetCharacterScale.loadPersistedPercent(
            defaults: scaleDefaults,
            percentKey: "percent",
            generationKey: "generation",
            generation: 2
        ) == 600, "restart must not double a migrated preference twice")
        precondition(PetCharacterScale.factor(200) == 2.0)

        // CHARACTER SPEED: scales the playback clock, never sprite or card geometry.
        precondition(PetAnimationSpeed.defaultPercent == 100)
        precondition(PetAnimationSpeed.clamp(1) == 25)
        precondition(PetAnimationSpeed.clamp(900) == 200)
        precondition(PetAnimationSpeed.factor(25) == 0.25)
        precondition(PetAnimationSpeed.factor(200) == 2.0)
        let speedSuite = "com.gotcos.control.tests.animation-speed.\(UUID().uuidString)"
        let speedDefaults = UserDefaults(suiteName: speedSuite)!
        defer { speedDefaults.removePersistentDomain(forName: speedSuite) }
        precondition(PetAnimationSpeed.loadPersistedPercent(
            defaults: speedDefaults,
            percentKey: "speed"
        ) == 100, "a fresh install must play authored speed")
        speedDefaults.set(10, forKey: "speed")
        precondition(PetAnimationSpeed.loadPersistedPercent(
            defaults: speedDefaults,
            percentKey: "speed"
        ) == 25, "a stored speed must clamp before playback")

        precondition(PetSpritePose.idle.spriteHeight(64, scale: 2) == 128,
                     "the character dial must scale the sprite frame")
        precondition(PetSpritePose.swarm.spriteHeight(64, scale: 2) == 128,
                     "multi-session art must not grow 1.55x above the solo character")
        precondition(PetSpritePose.idle.spriteHeight(64) == 64,
                     "an unscaled call must stay at the configured pixel size")
        precondition(PetSize(preset: .medium, customPixels: 64).length(22) == 22,
                     "card metrics must not read the character dial")
        let fitted = PetSpritePose.swarm.fittedCharacterScale(
            6,
            pixels: 128,
            aspect: 0.9,
            available: CGSize(width: 1440, height: 900),
            reservedChrome: CGSize(width: 72, height: 360)
        )
        let fittedSize = PetSpritePose.swarm.renderSize(128, scale: fitted, aspect: 0.9)
        precondition(fittedSize.height <= 540.5,
                     "maximum cinematic art must fit above the reserved chrome")
        precondition(PetSpritePose.swarm.fittedCharacterScale(
            6,
            pixels: 80,
            aspect: 0.9,
            available: CGSize(width: 2880, height: 1590),
            reservedChrome: CGSize(width: 45, height: 225)
        ) == 6, "Miles's saved 80px setting must receive the full doubled scale")

        // CINEMATIC COUNT PERSISTENCE: playback must slice the stitched strip
        // by its true cell count, not an aspect guess (996/256 -> 3 over a
        // 4-cell strip bled half-droids across every frame edge).
        let cineTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cos-cine-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: cineTmp)
        try! FileManager.default.createDirectory(at: cineTmp, withIntermediateDirectories: true)
        let board = spriteProbe(width: 1600, height: 100, blobs: [
            (x: 60, w: 240, y: 20, h: 60),
            (x: 460, w: 240, y: 20, h: 60),
            (x: 860, w: 240, y: 20, h: 60),
            (x: 1260, w: 240, y: 20, h: 60),
        ])
        let boardURL = cineTmp.appendingPathComponent("04-escalation.png")
        try! NSBitmapImageRep(data: board.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: boardURL)
        try! PetSpriteStore.installGrid(from: boardURL, columns: 4, rows: 1,
                                        cells: PetSpritePose.escalationCells, into: cineTmp)
        precondition(PetSpriteStore.cinematicFrameCount(in: cineTmp) == 4,
                     "installGrid must persist the cinematic strip's true frame count")
        // A newly chosen sprite for a cinematic pose must retire the stitched
        // strip; frames(for:) prefers it, so a stale strip would render the old
        // pack's art forever.
        let singleURL = cineTmp.appendingPathComponent("one-scene.png")
        let single = spriteProbe(width: 120, height: 100, blobs: [(x: 20, w: 80, y: 20, h: 60)])
        try! NSBitmapImageRep(data: single.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!.write(to: singleURL)
        // A PACK install runs boards and pose strips in one manifest loop, and
        // the combat strip (.duel) comes after the escalation board. Retiring
        // the cinematic there would delete the strip the board just wrote.
        _ = try! PetSpriteStore.installPose(.duel, from: singleURL, frames: 1,
                                            into: cineTmp, retireCinematic: false)
        precondition(PetSpriteStore.cinematicFrameCount(in: cineTmp) == 4,
                     "a pack's own pose strip must not delete the board's cinematic")
        _ = try! PetSpriteStore.installPose(.trio, from: singleURL, frames: 1, into: cineTmp)
        precondition(PetSpriteStore.cinematicFrameCount(in: cineTmp) == nil,
                     "choosing a cinematic pose sprite must retire the stale stitched strip")
        PetSpriteStore.removeAll(from: cineTmp)
        precondition(PetSpriteStore.cinematicFrameCount(in: cineTmp) == nil,
                     "removeAll must clear the cinematic frame-count meta")
        try? FileManager.default.removeItem(at: cineTmp)
    }

    private static func checkCursorAgentTabMatch() {
        precondition(CursorAgentTabMatch.matches("Hello there world", want: "Hello there world"))
        precondition(CursorAgentTabMatch.matches("HELLO THERE WORLD", want: "Hello there world"))
        precondition(!CursorAgentTabMatch.matches("short", want: "short"),
                     "short labels are too common to click")
        precondition(CursorAgentTabMatch.matches("Hello there…", want: "Hello there world extra"))
        precondition(CursorAgentTabMatch.matches("Hello there...", want: "Hello there world extra"))
        precondition(CursorAgentTabMatch.matches("Hello there world extra stuff", want: "Hello there world extra"))
        precondition(!CursorAgentTabMatch.matches("MU-Chief-Staff — ControllerModel.swift",
                                                  want: "ControllerModel.swift extra words"),
                     "an IDE window title must not match a session name")
        precondition(!CursorAgentTabMatch.matches("something else entirely here",
                                                  want: "Hello there world extra"))
        precondition(CursorAgentTabMatch.matches("Chat title. Voice profile creation bug",
                                                 want: "Voice profile creation bug"),
                     "Cursor's accessible row prefix must be stripped before matching")
        precondition(CursorAgentTabMatch.matches("chat title. HELLO THERE WORLD", want: "Hello there world"))
        precondition(!CursorAgentTabMatch.matches("Chat title. short", want: "short"),
                     "the minimum-length gate applies to the stripped label")
        precondition(CursorAgentTabMatch.matches("Chat title. Hello there…", want: "Hello there world extra"),
                     "prefix strip must compose with the truncation branch")
        precondition(
            ClaudeSessionRowMatch.matches(
                "Idle Reddit Posts GOTCOS.com(fork)",
                want: "Reddit Posts GOTCOS.com(fork)"
            ),
            "Claude sidebar rows prefix Idle"
        )
        precondition(
            ClaudeSessionRowMatch.matches(
                "Awaiting input Fireflies meeting sync",
                want: "Fireflies meeting sync"
            )
        )
        precondition(
            !CursorAgentTabMatch.matches(
                "Idle Reddit Posts GOTCOS.com(fork)",
                want: "Reddit Posts GOTCOS.com(fork)"
            ),
            "the Agents matcher must not treat Idle as part of the title"
        )
        precondition(
            !ClaudeSessionRowMatch.matches("Idle short", want: "short"),
            "short Claude labels are too common to click"
        )
    }

    private static func checkAppUpdateMerging() {
        let offer = AppUpdateInfo([
            "updateAvailable": .bool(true),
            "latestVersion": .string("0.5.89"),
            "latestBuild": .number(127),
            "reason": .string("newer"),
            "noticeId": .string("keep-me"),
            "noticeTitle": .string("Title"),
            "noticeBody": .string("Body"),
        ])
        precondition(offer.shouldSurface)
        precondition(offer.hasNotice)

        let unreachable = AppUpdateInfo([
            "updateAvailable": .bool(false),
            "reason": .string("unreachable"),
        ])
        let kept = AppUpdateInfo.merging(previous: offer, incoming: unreachable)
        precondition(kept.shouldSurface, "unreachable must not wipe a live offer")
        precondition(kept.latestVersion == "0.5.89")
        precondition(kept.hasNotice, "unreachable must not wipe the publisher notice")

        let malformed = AppUpdateInfo([
            "updateAvailable": .bool(false),
            "reason": .string("malformed"),
        ])
        precondition(AppUpdateInfo.merging(previous: offer, incoming: malformed).shouldSurface)

        let upToDate = AppUpdateInfo([
            "updateAvailable": .bool(false),
            "latestVersion": .string("0.5.89"),
            "reason": .string("upToDate"),
        ])
        let cleared = AppUpdateInfo.merging(previous: offer, incoming: upToDate)
        precondition(!cleared.shouldSurface, "upToDate must clear the badge")

        let kill = AppUpdateInfo([
            "updateAvailable": .bool(false),
            "reason": .string("killSwitch"),
        ])
        precondition(!AppUpdateInfo.merging(previous: offer, incoming: kill).shouldSurface)

        let idle = AppUpdateInfo()
        let fromIdle = AppUpdateInfo.merging(previous: idle, incoming: unreachable)
        precondition(!fromIdle.shouldSurface, "no prior offer means unreachable stays quiet")
        print("COS Control: AppUpdateInfo.merging sticky-offer contract passed")
    }

    private static func checkMenuBarIcon() {
        let running = MenuBarIcon.compose(systemName: "eyeglasses", updateAvailable: false)
        let runningBadge = MenuBarIcon.compose(systemName: "eyeglasses", updateAvailable: true)
        let down = MenuBarIcon.compose(systemName: "eyeglasses.slash", updateAvailable: false)
        let downBadge = MenuBarIcon.compose(systemName: "eyeglasses.slash", updateAvailable: true)
        let tiffs = [running, runningBadge, down, downBadge].map { $0.tiffRepresentation ?? Data() }
        precondition(tiffs.allSatisfy { !$0.isEmpty }, "composed status images must have pixels")
        precondition(Set(tiffs).count == 4, "running x update must produce 4 distinct template images")
        precondition(running.isTemplate && runningBadge.isTemplate)
        precondition(running.size.width > running.size.height + 1,
                     "eyeglasses must stay landscape; a square canvas is the 0.5.90 skew")
        print("COS Control: MenuBarIcon compose distinctness passed")
    }

    private static func checkOpenPetsCatalogRow() {
        let row = OpenPetsCatalogRow(.object([
            "id": .string("tmuxai"),
            "displayName": .string("TmuxAI Official"),
            "description": .string("ignored"),
            "preview": .string("https://openpets.dev/pets/tmuxai-openpets/thumb.webp"),
            "zip": .string("https://zip.openpets.dev/pets/tmuxai-openpets/tmuxai.zip"),
            "category": .string("western"),
            "subcategory": .string("tools"),
        ]))
        precondition(row?.id == "tmuxai")
        precondition(row?.preview == "https://openpets.dev/pets/tmuxai-openpets/thumb.webp",
                     "preview must be the catalog URL, never synthesized from id")
        precondition(OpenPetsCatalogRow(.object(["displayName": .string("x")])) == nil)
        print("COS Control: OpenPets catalog row decode passed")
    }

    private static func checkOrphanCapture() {
        let recoverable = OrphanCapture(.object([
            "sessionId": .string("meeting_1786237535593"),
            "chunkFiles": .number(12),
            "ageHours": .number(2.5),
            "recovered": .bool(false),
            "recovering": .bool(false),
            "recoverable": .bool(true),
        ]))
        precondition(recoverable?.recoverable == true)
        precondition(recoverable?.label.contains("12 chunks") == true)
        precondition(OrphanCapture(.object(["chunkFiles": .number(12)])) == nil,
                     "orphan rows without sessionId are dropped")
        let stranded = StrandedCapture(.object([
            "sessionId": .string("meeting_live"),
            "idleMinutes": .number(40),
            "capturedMinutes": .number(18),
            "chunks": .number(90),
        ]))
        precondition(stranded?.label.contains("still live") == true)
        precondition(stranded?.label.contains("Meetings to review") == false,
                     "stranded copy must never collide with Speakers review")
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

        // THE FLOOR. A share is a fraction of the IDENTIFIED speech, so at 40%
        // coverage "53%" can be 21% of the room. The clipboard has always
        // refused these; the panel drew them anyway on 170 of 355 real meetings
        // while a comment claimed the two could never disagree. Neither the gate
        // nor the 0.6 value had ANY execution coverage — both mutations passed.
        let lowCoverage = review([
            .object(["label": .string("MU"), "segments": .number(9), "reliability": .string("confident"),
                     "nameAsserted": .bool(true), "speakingMs": .number(450_000),
                     "assertionBlockers": .array([]), "thrashesWith": .array([]), "phrases": .array([])]),
            .object(["label": .string("Niala Samnarine"), "segments": .number(5), "reliability": .string("confident"),
                     "nameAsserted": .bool(true), "speakingMs": .number(314_000),
                     "assertionBlockers": .array([]), "thrashesWith": .array([]), "phrases": .array([])]),
        ], attributed: 404_000, unattributed: 596_000)!
        precondition(abs((lowCoverage.speakingCoverage ?? 1) - 0.404) < 0.001, "40.4% coverage fixture")
        precondition(lowCoverage.voices.allSatisfy { lowCoverage.shareOfIdentified($0) == nil },
                     "no share may be reported below the coverage floor")

        // Just ABOVE the floor, the same rows must still get their shares — a
        // gate that suppressed everything would also pass the test above.
        let okCoverage = review([
            .object(["label": .string("MU"), "segments": .number(9), "reliability": .string("confident"),
                     "nameAsserted": .bool(true), "speakingMs": .number(450_000),
                     "assertionBlockers": .array([]), "thrashesWith": .array([]), "phrases": .array([])]),
            .object(["label": .string("Niala Samnarine"), "segments": .number(5), "reliability": .string("confident"),
                     "nameAsserted": .bool(true), "speakingMs": .number(314_000),
                     "assertionBlockers": .array([]), "thrashesWith": .array([]), "phrases": .array([])]),
        ], attributed: 700_000, unattributed: 300_000)!
        precondition(lowCoverage.voices.count == okCoverage.voices.count, "same shape, different coverage")
        precondition(okCoverage.voices.compactMap { okCoverage.shareOfIdentified($0) }.count == 2,
                     "above the floor, shares are still reported")

        // Exactly AT the floor shows, matching the server's `>=` comparison.
        let atFloor = review([
            .object(["label": .string("MU"), "segments": .number(9), "reliability": .string("confident"),
                     "nameAsserted": .bool(true), "speakingMs": .number(600_000),
                     "assertionBlockers": .array([]), "thrashesWith": .array([]), "phrases": .array([])]),
            .object(["label": .string("Gina Obert"), "segments": .number(4), "reliability": .string("confident"),
                     "nameAsserted": .bool(true), "speakingMs": .number(200_000),
                     "assertionBlockers": .array([]), "thrashesWith": .array([]), "phrases": .array([])]),
        ], attributed: 600_000, unattributed: 400_000)!
        precondition(atFloor.speakingCoverage == 0.6, "exactly the floor")
        precondition(atFloor.voices.compactMap { atFloor.shareOfIdentified($0) }.count == 2,
                     "0.6 itself must SHOW, matching the server's >= comparison")

        // UNKNOWN coverage must suppress too. The server writes
        // `coverage !== null && coverage >= FLOOR`; an `if let` on this side
        // would show a share precisely where we know least about it.
        let noCoverage = review([
            .object(["label": .string("MU"), "segments": .number(9), "reliability": .string("confident"),
                     "nameAsserted": .bool(true), "speakingMs": .number(450_000),
                     "assertionBlockers": .array([]), "thrashesWith": .array([]), "phrases": .array([])]),
            .object(["label": .string("Gina Obert"), "segments": .number(4), "reliability": .string("confident"),
                     "nameAsserted": .bool(true), "speakingMs": .number(120_000),
                     "assertionBlockers": .array([]), "thrashesWith": .array([]), "phrases": .array([])]),
        ], attributed: nil, unattributed: nil)!
        precondition(noCoverage.speakingCoverage == nil, "coverage genuinely unknown")
        precondition(noCoverage.voices.allSatisfy { noCoverage.shareOfIdentified($0) == nil },
                     "unknown coverage must suppress shares, not show them")

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
        // UNPAIRED markers are not emphasis. Stripping unconditionally turned
        // `2**3` into `23` and `**/blog` into `/blog` (18 real occurrences).
        precondition(MeetingContent.panelText("use 2**3 exponent").contains("2**3"),
                     "an unpaired ** is content, not emphasis")
        precondition(MeetingContent.panelText("ignore **/blog paths").contains("**/blog"),
                     "a glob is content, not emphasis")
        precondition(!MeetingContent.panelText("a **bold** word").contains("**"),
                     "a paired ** is still softened")

        // The inline write-up is bounded; the clipboard is not.
        let long = String(repeating: "word ", count: 2_000)
        let preview = MeetingContent.panelPreview(long)
        precondition(preview.count < 1_100, "the panel preview must be bounded")
        precondition(preview.contains("more characters"), "the remainder must be accounted for, not hidden")
        precondition(!preview.hasSuffix("wor"), "the cut must land on a word boundary")
        precondition(MeetingContent.panelPreview("short enough") == "short enough",
                     "a short section is untouched")
        precondition(panel.contains("HIGH CONFIDENCE"), "heading text survives, uppercased")
        precondition(panel.contains("do the thing"), "content survives")

        // A real scribe repeats its own `##` headings, so two sections can share a
        // display name. They must both survive as distinct entries — the panel
        // keys the ForEach by position for exactly this reason.
        let dupes = content([
            .object(["heading": .string("Notes"), "body": .string("first")]),
            .object(["heading": .string("Notes"), "body": .string("second")]),
        ])!
        precondition(dupes.sections.filter { $0.0 == "Notes" }.count == 2,
                     "duplicate headings must not collapse")

        // Never silence: a 404 names the version, anything else names the failure.
        precondition(MeetingContent.unavailableMessage(nil) == nil, "loaded content renders nothing")
        precondition(MeetingContent.unavailableMessage("route_absent")?.contains("6.21.28") == true,
                     "an old server is told which version it needs")
        precondition(MeetingContent.unavailableMessage("error")?.contains("could not be loaded") == true,
                     "a real failure is named, not hidden")
        precondition(MeetingContent.unavailableMessage("something new") != nil,
                     "an unrecognised reason still says something")

        // An older server sends none of it; init? must still succeed.
        // BLOCKER, measured against the running server: published 6.21.28 serves
        // /content WITHOUT summaryChars/fullChars, so `?? 0` labelled the button
        // "Full (1 KB)" for real 54,451-character payloads. The strings are
        // present in that same response, so they are the fallback.
        let noSizes = MeetingContent(.object([
            "sessionId": .string("meeting_sizes"),
            "clipboardSummary": .string(String(repeating: "s", count: 3_500)),
            "clipboardFull": .string(String(repeating: "f", count: 54_451)),
        ]))
        precondition(noSizes?.fullChars == 54_451, "fullChars falls back to the string length")
        precondition(noSizes?.summaryChars == 3_500, "summaryChars falls back to the string length")
        precondition((noSizes?.fullChars ?? 0) / 1024 == 53, "the KB label reads 53, not 1")
        // An explicit server-sent count still wins.
        let withSizes = MeetingContent(.object([
            "sessionId": .string("meeting_sizes2"),
            "clipboardFull": .string("short"),
            "fullChars": .number(99),
        ]))
        precondition(withSizes?.fullChars == 99, "an explicit fullChars wins over the string length")

        // 2026-08-07: "Clem Ukaoma" removed from a call that was only Miles and
        // Queen. All 8 label sites rewritten; the panel still read "Miles, Queen,
        // and Clem talk through...". The server records proseStale; the panel must
        // say it before the user reads the prose.
        let removedC = MeetingContent(.object([
            "sessionId": .string("meeting_rm"),
            "removedNames": .array([.object([
                "label": .string("Clem Ukaoma"), "proseStale": .bool(true),
            ])]),
        ]))
        precondition(removedC?.removedNames.count == 1, "removedNames decodes")
        let warn = MeetingContent.removalWarning(removedC?.removedNames ?? [])
        precondition(warn?.contains("You removed") == true, "the warning states the removal")
        precondition(warn?.contains("Clem Ukaoma") == true, "the warning names the person")
        precondition(warn?.contains("still uses the name") == true, "it explains why the prose is wrong")
        precondition(MeetingContent.removalWarning([(label: "X", proseStale: false)]) == nil,
                     "a clean-prose removal needs no warning above the write-up")
        precondition(MeetingContent.removalWarning([]) == nil, "no removals, no warning")
        precondition(MeetingContent(.object(["sessionId": .string("m")]))?.removedNames.isEmpty == true,
                     "absent removedNames decodes to empty, not a crash")

        let bare = MeetingContent(.object(["sessionId": .string("meeting_y")]))
        precondition(bare != nil && bare?.scribeAvailable == false, "older server degrades")
        precondition(bare?.sections.isEmpty == true, "no sections without bodies")
    }

    /// A fork inherits its parent's title, so the two rows are pixel-identical without
    /// a disambiguator. Measured 2026-08-18: two live sessions both named "COS-glasses
    /// Server work (meetings)" with distinct ids, and 8 duplicate-title groups in 69 rows.
    private static func checkAmbiguousTitles() {
        func session(_ id: String, _ name: String) -> ClaudeSession {
            ClaudeSession(.object([
                "id": .string(id),
                "name": .string(name),
                "workspace": .string("MU-Chief-Staff"),
                "state": .string("running"),
                "alive": .bool(true),
            ]))!
        }
        // The real case: a fork and its parent, distinct ids, identical name.
        let forked = [
            session("31732572-0018-422f-a6fb-47913e15cf31", "COS-glasses Server work (meetings)"),
            session("a4b2b4dd-e40c-4b08-8a11-c89a018c197d", "COS-glasses Server work (meetings)"),
            session("sess_solo", "Quilt portfolio SEO audit review"),
        ]
        let dupes = ClaudeSession.ambiguousTitles(in: forked)
        precondition(dupes == ["COS-glasses Server work (meetings)"],
                     "a fork and its parent must be flagged ambiguous, and nothing else")

        // A unique set flags nothing — the badge must not appear on every row.
        precondition(ClaudeSession.ambiguousTitles(in: [session("a", "One"), session("b", "Two")]).isEmpty,
                     "distinct titles must not be flagged")

        // Whitespace must not create a false distinction.
        precondition(ClaudeSession.ambiguousTitles(in: [session("a", "Same "), session("b", " Same")])
                     == ["Same"], "titles differing only by whitespace are the same title")

        // Untitled rows (7 measured) fall back through `title`: name -> workspace -> id.
        // So two untitled sessions in the SAME workspace genuinely share a title and ARE
        // indistinguishable — flagging them is correct, not a false positive. This
        // assertion originally claimed the opposite and the test caught it.
        precondition(ClaudeSession.ambiguousTitles(in: [session("a", ""), session("b", "")])
                     == ["MU-Chief-Staff"],
                     "two untitled rows in one workspace share a title and must be flagged")

        // The guard that matters: a title that resolves to empty is skipped, never
        // grouped. Unreachable via `title` today (it ends at the unique session id), so
        // this pins the guard rather than a live case.

        print("COS Control: fork/duplicate title disambiguation passed")
    }

    /// Dropping an idle row is a VIEW decision: nothing about the session
    /// changes, and any new activity supersedes the drop on its own.
    private static func checkPetDismissals() {
        func session(_ id: String, state: String, ageMinutes: Double) -> ClaudeSession {
            let stamp = ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(-ageMinutes * 60)
            )
            return ClaudeSession(.object([
                "id": .string(id),
                "name": .string(id),
                "workspace": .string("MU-Chief-Staff"),
                "state": .string(state),
                "alive": .bool(true),
                "updatedAt": .string(stamp),
            ]))!
        }

        let parked = session("a", state: "waiting", ageMinutes: 30)
        let fresh = session("b", state: "waiting", ageMinutes: 2)
        let busy = session("c", state: "running", ageMinutes: 90)

        precondition(PetDismissals.isDismissable(parked), "a 30-minute-idle row must be droppable")
        precondition(!PetDismissals.isDismissable(fresh), "a 2-minute-idle row must not be droppable")
        precondition(!PetDismissals.isDismissable(busy),
                     "a RUNNING row is never droppable however old its stamp")
        precondition(PetDismissals.idleGrace == 600, "the idle grace is meant to be ten minutes")

        var drops = PetDismissals()
        drops.dismiss(parked)
        precondition(drops.hides(parked), "the dismissed row is still listed")
        // Ids carry the provider prefix ("claude:a"), which is also what the
        // dismissal map keys on -- so the two must agree.
        precondition(drops.filter([parked, fresh, busy]).map(\.id) == ["claude:b", "claude:c"],
                     "only the dismissed row may disappear")
        precondition(drops.stamps.keys.first == parked.id,
                     "the map must key on the same id the filter compares")

        // Same id, new stamp: the session started moving again, so the drop
        // no longer applies. This is what keeps a drop from being a delete.
        let revived = session("a", state: "running", ageMinutes: 0)
        precondition(!drops.hides(revived), "activity must supersede a dismissal")

        // Pruning is against the UNFILTERED list. Pruning against the filtered
        // one would forget the drop on the very next poll and walk it back in.
        var kept = drops
        kept.prune(against: [parked, fresh, busy])
        precondition(kept.hides(parked), "pruning against the full list must keep a live dismissal")
        var forgotten = drops
        forgotten.prune(against: [fresh, busy])
        precondition(!forgotten.hides(parked), "a row that is gone must not be remembered forever")
        precondition(forgotten.stamps.isEmpty, "the dismissal map must not grow without bound")

        print("COS Control: idle pet rows drop from the list without touching the session")
    }

    /// D1: the per-id detector, execution-tested without ControllerModel.
    private static func checkPetCompletionDetector() {
        func sess(_ native: String, _ state: String, keepWarm: Bool = false) -> ClaudeSession {
            ClaudeSession(.object([
                "id": .string(native),
                "name": .string(keepWarm ? "ready" : "task \(native)"),
                "workspace": .string("MU-Chief-Staff"),
                "state": .string(state),
                "alive": .bool(true),
                "updatedAt": .string("2026-08-30T18:00:00Z"),
            ]))!
        }
        let now = Date()
        func diff(_ prev: [ClaudeSession], _ cur: [ClaudeSession],
                  suppressed: Set<String> = []) -> [PetCompletion] {
            PetCompletionDetector.diff(previous: prev, current: cur,
                                       suppressedIDs: suppressed, now: now)
        }

        // 1. two running -> one idle-alive: exactly one completion
        var out = diff([sess("a", "running"), sess("b", "running")],
                       [sess("a", "running"), sess("b", "recent")])
        precondition(out.count == 1 && out[0].id == "claude:b",
                     "one of two finishing must emit exactly that one")
        precondition(out[0].seen == false && out[0].sessionId == "b")

        // 2. four running -> one idle-alive: one completion
        out = diff((0..<4).map { sess("s\($0)", "running") },
                   [sess("s0", "running"), sess("s1", "running"),
                    sess("s2", "running"), sess("s3", "recent")])
        precondition(out.count == 1 && out[0].id == "claude:s3",
                     "D1: one of FOUR finishing is the fleet-boolean miss")

        // 3. four running -> all vanish: four completions
        out = diff((0..<4).map { sess("v\($0)", "running") }, [])
        precondition(out.count == 4, "vanished running rows all emit")

        // 4. running -> waiting: zero (a handoff, not a finish)
        out = diff([sess("w", "running")], [sess("w", "waiting")])
        precondition(out.isEmpty, "running->waiting must not emit")

        // 5. waiting vanishes: zero
        out = diff([sess("x", "waiting")], [])
        precondition(out.isEmpty, "a never-running prior must not emit")

        // 6. keep-warm suppressed
        out = diff([sess("k", "running")], [sess("k", "recent")], suppressed: ["claude:k"])
        precondition(out.isEmpty, "keep-warm reclassification is not a finish")

        // 7. hides()-suppressed disappearance is silent; the SAME id running
        //    again later (hides false, unsuppressed) then finishing emits.
        out = diff([sess("h", "running")], [], suppressed: ["claude:h"])
        precondition(out.isEmpty)
        out = diff([sess("h", "running")], [sess("h", "recent")])
        precondition(out.count == 1, "a re-run after a dismissal must emit")

        // 8. finish -> running again -> finish: one upserted row, seen false
        let first = diff([sess("u", "running")], [sess("u", "recent")])
        var ring = PetCompletionDetector.apply(
            existing: [], fresh: first,
            previous: [sess("u", "running")], current: [sess("u", "recent")], now: now)
        precondition(ring.count == 1)
        ring[0].seen = true
        // runs again -> chip drops while active
        ring = PetCompletionDetector.apply(
            existing: ring, fresh: [],
            previous: [sess("u", "recent")], current: [sess("u", "running")], now: now)
        precondition(ring.isEmpty, "a chip whose session is running again must drop")
        // finishes again -> fresh row, seen reset to false
        let second = diff([sess("u", "running")], [sess("u", "recent")])
        ring = PetCompletionDetector.apply(
            existing: [], fresh: second,
            previous: [sess("u", "running")], current: [sess("u", "recent")], now: now)
        precondition(ring.count == 1 && ring[0].seen == false,
                     "a re-finish is news again")

        // 8b. The upsert path itself: one poll captures run+finish, so the OLD
        //     seen chip is still in the ring when the fresh emit lands. The
        //     seen reset must happen through the upsert, not only via drop.
        var held = PetCompletionDetector.apply(
            existing: [], fresh: diff([sess("u", "running")], [sess("u", "recent")]),
            previous: [sess("u", "running")], current: [sess("u", "recent")], now: now)
        held[0].seen = true
        held = PetCompletionDetector.apply(
            existing: held,
            fresh: diff([sess("u", "running")], [sess("u", "recent")]),
            previous: [sess("u", "running")], current: [sess("u", "recent")], now: now)
        precondition(held.count == 1 && held[0].seen == false,
                     "an UPSERTED re-finish must reset seen — the drop path alone cannot")

        // 9. cap and age via apply
        let many = (0..<12).map { i in
            PetCompletion(id: "claude:m\(i)", sessionId: "m\(i)", name: "m\(i)",
                          provider: "claude", workspace: "", 
                          finishedAt: now.addingTimeInterval(Double(-i * 60)), seen: false)
        }
        ring = PetCompletionDetector.apply(existing: many, fresh: [], previous: [], current: [], now: now)
        precondition(ring.count == PetCompletionDetector.ringCap, "ring caps at \(PetCompletionDetector.ringCap)")
        let stale = [PetCompletion(id: "claude:old", sessionId: "old", name: "old",
                                   provider: "claude", workspace: "",
                                   finishedAt: now.addingTimeInterval(-5 * 3600), seen: false)]
        ring = PetCompletionDetector.apply(existing: stale, fresh: [], previous: [], current: [], now: now)
        precondition(ring.isEmpty, "a 5h-old chip ages out at 4h")

        // 10. One session, one chip: the live list carries the same session
        //     as a full UUID and an 8-char short id at once, and both emitted.
        let full = PetCompletion(id: "claude:9644b527-da59-46e8-8172-c49f4d236fc4",
                                 sessionId: "9644b527-da59-46e8-8172-c49f4d236fc4",
                                 name: "All right can you give me", provider: "claude",
                                 workspace: "MU-Chief-Staff", finishedAt: now, seen: true)
        let short = PetCompletion(id: "claude:9644b527", sessionId: "9644b527",
                                  name: "mu-chief-staff-13", provider: "claude",
                                  workspace: "", finishedAt: now.addingTimeInterval(10),
                                  seen: false)
        let other = PetCompletion(id: "claude:74a39ab4", sessionId: "74a39ab4",
                                  name: "mu-chief-staff-db", provider: "claude",
                                  workspace: "", finishedAt: now, seen: false)
        let merged = PetCompletionDetector.canonicalized([short, full, other])
        precondition(merged.count == 2, "full+short twins must collapse to one chip")
        let winner = merged.first { $0.sessionId.count > 8 }!
        precondition(winner.sessionId == full.sessionId,
                     "the FULL id must win — it is what the transcript lookup wants")
        precondition(winner.seen == false, "unseen wins a merge; news must not be hidden")
        precondition(abs(winner.finishedAt.timeIntervalSince(now) - 10) < 0.01,
                     "the newest finishedAt survives")
        precondition(merged.contains { $0.sessionId == "74a39ab4" },
                     "an unrelated short id must NOT be swallowed")
        // 10b. THROUGH apply(): a fresh short-id emit must merge into an
        //      existing full-id chip inside the pipeline itself, not only when
        //      canonicalized() is called directly.
        let viaApply = PetCompletionDetector.apply(
            existing: [full], fresh: [short], previous: [], current: [], now: now)
        precondition(viaApply.count == 1 && viaApply[0].sessionId == full.sessionId,
                     "apply() must canonicalize; a short-id twin emitted a second chip live")

        // A codex session sharing a prefix with a claude session stays separate.
        let cross = PetCompletionDetector.canonicalized([full,
            PetCompletion(id: "codex:9644b527", sessionId: "9644b527", name: "x",
                          provider: "codex", workspace: "", finishedAt: now, seen: false)])
        precondition(cross.count == 2, "provider is part of chip identity")

        // fromCompletion round-trips into a routable session
        let chip = PetCompletion(id: "claude:r", sessionId: "r", name: "R",
                                 provider: "claude", workspace: "W",
                                 finishedAt: now, seen: false)
        let revived = ClaudeSession.fromCompletion(chip)
        precondition(revived?.id == "claude:r" && revived?.isPetVisible == true,
                     "a chip must revive isPetVisible-shaped")

        print("COS Control: per-id completion detector emits once per finish")
    }

    /// Persistence: injected suite ONLY, live-fixture scrub, age-out, cap.
    private static func checkPetCompletionsPersist() {
        let suiteName = "com.gotcos.control.tests.pet-completions.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("suite")
        }
        defer { suite.removePersistentDomain(forName: suiteName) }
        let standardBefore = UserDefaults.standard.data(forKey: "cos.sessionPetCompletions")

        let now = Date()
        let rows = [
            PetCompletion(id: "claude:keep", sessionId: "keep", name: "K",
                          provider: "claude", workspace: "", finishedAt: now, seen: true),
            PetCompletion(id: "claude:a", sessionId: "a", name: "leaked fixture",
                          provider: "claude", workspace: "", finishedAt: now, seen: false),
            PetCompletion(id: "claude:old", sessionId: "old", name: "stale",
                          provider: "claude", workspace: "",
                          finishedAt: now.addingTimeInterval(-5 * 3600), seen: false),
        ]
        let data = try! JSONEncoder().encode(rows)
        // default Date strategy IS timeIntervalSinceReferenceDate — pin it,
        // because the live blob under this key stores exactly that number.
        let decoded = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let raw = decoded.first { ($0["id"] as? String) == "claude:keep" }!["finishedAt"] as! Double
        precondition(abs(raw - now.timeIntervalSinceReferenceDate) < 1,
                     "Date must round-trip as timeIntervalSinceReferenceDate")
        suite.set(data, forKey: "cos.sessionPetCompletions")

        // partial blob (missing provider/workspace/seen) still decodes
        let partial = "[{\"id\":\"claude:p\",\"sessionId\":\"p\",\"finishedAt\":809798109.23}]"
        let partialRows = try! JSONDecoder().decode([PetCompletion].self, from: partial.data(using: .utf8)!)
        precondition(partialRows[0].provider == "" && partialRows[0].seen == false
                     && partialRows[0].name == "",
                     "custom decode must default missing fields")

        // load-order contract, replicated from loadPetCompletions
        var kept = (try! JSONDecoder().decode([PetCompletion].self,
                    from: suite.data(forKey: "cos.sessionPetCompletions")!))
            .filter { !$0.id.isEmpty && !$0.sessionId.isEmpty }
        kept.removeAll { $0.id == "claude:a" }
        kept.removeAll { now.timeIntervalSince($0.finishedAt) > PetCompletionDetector.maxAge }
        precondition(kept.count == 1 && kept[0].id == "claude:keep" && kept[0].seen == true,
                     "fixture scrubbed, stale aged out, seen survives")

        precondition(UserDefaults.standard.data(forKey: "cos.sessionPetCompletions") == standardBefore,
                     "tests must NEVER write UserDefaults.standard")
        print("COS Control: completion chips persist in an injected suite only")
    }

    /// Terminal-jump routing: the executable matrix that pins the tty
    /// falsification (Claude Desktop owned ttys006).
    private static func checkPetJumpRoute() {
        typealias R = PetJumpRoute
        precondition(R.route(entrypoint: "cli", hostBundleId: "com.googlecode.iterm2") == .terminal)
        precondition(R.route(entrypoint: "cli", hostBundleId: "com.apple.Terminal") == .terminal)
        precondition(R.route(entrypoint: " CLI ", hostBundleId: "com.googlecode.iterm2") == .terminal,
                     "entrypoint compares after trim + lowercase")
        precondition(R.route(entrypoint: "cli", hostBundleId: "com.todesktop.230313mzl4w4u92.helper") == .desktopSidebar)
        precondition(R.route(entrypoint: "cli", hostBundleId: nil) == .desktopSidebar, "tmux/no-app chain")
        precondition(R.route(entrypoint: "claude-desktop", hostBundleId: "com.googlecode.iterm2") == .desktopSidebar,
                     "a Desktop session in a tty-owning host must keep its sidebar jump")
        precondition(R.route(entrypoint: nil, hostBundleId: "com.googlecode.iterm2") == .desktopSidebar)
        precondition(R.route(entrypoint: "", hostBundleId: "com.googlecode.iterm2") == .desktopSidebar)
        precondition(R.route(entrypoint: "vscode", hostBundleId: "com.googlecode.iterm2") == .desktopSidebar,
                     "unknown future entrypoints fail closed to the sidebar")
        precondition(R.route(entrypoint: "cli", hostBundleId: "") == .desktopSidebar)

        // Negative membership for ALL THREE non-terminal tty owners the
        // 2026-08-30 census found. This is the falsification, pinned.
        for id in ["com.anthropic.claudefordesktop",
                   "com.todesktop.230313mzl4w4u92",
                   "com.openai.codex"] {
            precondition(!ClaudeSession.terminalHostBundleIds.contains(id),
                         "\(id) owns a tty on this machine and is NOT a terminal")
        }

        // procStart comparator: the 5h UTC regression arm is the trap.
        let utc = "Sun Aug 30 12:34:55 2026"       // what the JSON stores
        let epoch = 1788093295                      // == that instant
        precondition(R.procStartMatches(recorded: utc, kernelSeconds: epoch) == true)
        precondition(R.procStartMatches(recorded: utc, kernelSeconds: epoch + 1) == true, "±1s tolerance")
        precondition(R.procStartMatches(recorded: utc, kernelSeconds: epoch + 3) == false)
        precondition(R.procStartMatches(recorded: utc, kernelSeconds: epoch - 5 * 3600) == false,
                     "the local-time rendering of the same instant MUST fail — "
                     + "a naive comparison failed closed by exactly this offset")
        precondition(R.procStartMatches(recorded: "not a date", kernelSeconds: epoch) == nil,
                     "unparseable fails OPEN")
        precondition(R.procStartMatches(recorded: nil, kernelSeconds: epoch) == nil)
        precondition(R.procStartMatches(recorded: utc, kernelSeconds: nil) == nil)
        precondition(R.procStartMatches(recorded: "Sun Aug  3 07:34:55 2026",
                                        kernelSeconds: 1785742495) != nil,
                     "ctime double-space day padding must parse")
        print("COS Control: terminal routing is allowlist-gated and the UTC trap is pinned")
    }

    /// The ledger bar vocabulary (0.5.142). Every state Miles approved on the
    /// design canvas, asserted as EXACT strings so a mutation to caption
    /// ordering, the separator, or the NEW clause fails loudly.
    private static func checkPetLedger() {
        func live(_ id: String, _ state: String) -> ClaudeSession {
            ClaudeSession(.object([
                "id": .string(id),
                "name": .string(id),
                "workspace": .string("MU-Chief-Staff"),
                "state": .string(state),
                "alive": .bool(true),
            ]))!
        }
        func chip(_ id: String, seen: Bool) -> PetCompletion {
            PetCompletion(id: "claude:\(id)", sessionId: id, name: id, provider: "claude",
                          workspace: "w", finishedAt: Date(), seen: seen)
        }

        // Working day: green then gold, running leads the caption. The
        // idle-alive third session must not paint the bar.
        let working = PetLedger.resolve(
            sessions: [live("a", "running"), live("b", "running"), live("i", "recent")],
            completions: [chip("d1", seen: true), chip("d2", seen: false), chip("d3", seen: false)]
        )
        precondition(working.running == 2 && working.waiting == 0
                     && working.done == 3 && working.unseen == 2)
        precondition(working.caption == "2 RUNNING · 3 DONE")
        precondition(working.segments.map(\.kind) == [.running, .done],
                     "zero-count segments never render")
        precondition(!working.isQuiet)

        // Waiting takes the FRONT — bar order and caption order both.
        let waiting = PetLedger.resolve(
            sessions: [live("a", "waiting"), live("b", "running")],
            completions: [chip("d", seen: true)]
        )
        precondition(waiting.caption == "1 WAITING · 1 RUNNING · 1 DONE")
        precondition(waiting.segments.map(\.kind) == [.waiting, .running, .done])
        precondition(waiting.segments[0].count == 1)

        // All done: a gold day, fresh finishes called out as NEW.
        let allDone = PetLedger.resolve(
            sessions: [live("i", "recent")],
            completions: (0..<5).map { chip("d\($0)", seen: $0 >= 3) }
        )
        precondition(allDone.running == 0 && allDone.done == 5 && allDone.unseen == 3)
        precondition(allDone.caption == "5 DONE · 3 NEW")
        precondition(allDone.segments.map(\.kind) == [.done])

        // NEW is the all-done state's word, never a live-day ticker.
        let mixed = PetLedger.resolve(
            sessions: [live("a", "running")],
            completions: [chip("d", seen: false)]
        )
        precondition(mixed.caption == "1 RUNNING · 1 DONE")

        // Quiet pet: IDLE, no segments, nothing invented.
        let quiet = PetLedger.resolve(sessions: [live("i", "recent")], completions: [])
        precondition(quiet.isQuiet && quiet.caption == "IDLE" && quiet.segments.isEmpty)

        // Same predicates as the pose ladder: "error" is neither running nor
        // waiting, so the bar and the fight ladder can never disagree.
        let err = PetLedger.resolve(sessions: [live("e", "error")], completions: [])
        precondition(err.running == 0 && err.waiting == 0)
        print("COS Control: the ledger vocabulary matches the approved canvas")
    }

    static func main() throws {
        checkRenameEligibility()
        checkAmbiguousTitles()
        checkConfirmEligibility()
        checkMeetingRowFields()
        checkMeetingReviewSort()
        checkCountsSummary()
        checkSpeakerListMemory()
        checkReviewVoiceQueue()
        checkLibraryMeeting()
        checkContextSearchHit()
        checkSessionSearchHit()
        checkOrphanCapture()
        checkClaudeSession()
        checkPetSpriteStore()
        checkPetDismissals()
        checkPetCompletionDetector()
        checkPetCompletionsPersist()
        checkPetJumpRoute()
        checkPetLedger()
        checkPetSpritePoses()
        checkPetSize()
        checkCursorAgentTabMatch()
        checkPetSpritePipeline()
        checkAppUpdateMerging()
        checkMenuBarIcon()
        checkOpenPetsCatalogRow()
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
            "adaptiveAudioCleanupSupported": .bool(true),
            "adaptiveAudioCleanupEnabled": .bool(false),
            "threadAttachSupported": .bool(true),
            "threadAttachEnabled": .bool(true),
            "threadAttachProviders": .array([.string("claude"), .string("codex")]),
        ])
        precondition(status.meetingPreviewSupported && status.meetingPreviewEnabled == true)
        precondition(status.idleMetalHqSupported && status.idleMetalHqEnabled == true && status.idleMetalHqForceCpu == false)
        precondition(status.adaptiveAudioCleanupSupported && status.adaptiveAudioCleanupEnabled == false)
        precondition(status.threadAttachSupported && status.threadAttachEnabled == true)
        precondition(status.threadAttachProviders == ["claude", "codex"])

        // A server that predates the capability contract sends none of these
        // fields. Absent MUST resolve to off, never to "probably on" — the same
        // fail-closed posture the server's own contract mandates for clients.
        let legacy = ServerStatus(["meetingPreviewSupported": .bool(true)])
        precondition(!legacy.threadAttachSupported)
        precondition(legacy.threadAttachEnabled == nil)
        precondition(legacy.threadAttachProviders.isEmpty)

        // Decode into an owned in-memory image before deleting the source.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try png.write(to: source, options: .atomic)
        let decoded = RecentMediaImageDecoder.decode(url: source, expectedBytes: png.count)
        try FileManager.default.removeItem(at: source)
        precondition(decoded?.tiffRepresentation != nil)

        // ── Day-anchored timestamps (0.5.80) ──────────────────────────
        //
        // Every row used to render a bare `HH:mm`, so a list spanning days gave
        // no way to tell today from Monday and no AM/PM on a locale that uses
        // it. `now` and `calendar` are injected so these assertions do not
        // drift with the wall clock.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "America/Chicago")!
        gregorian.locale = Locale(identifier: "en_US")
        var when = DateComponents()
        when.year = 2026; when.month = 8; when.day = 26
        when.hour = 19; when.minute = 15
        let now = gregorian.date(from: when)!

        func label(_ date: Date) -> String {
            GlassesTurn.dayAnchoredTime(date.timeIntervalSince1970, now: now, calendar: gregorian)
        }
        let todayLabel = label(now)
        precondition(todayLabel.hasPrefix("Today "), "today must carry a day anchor, got \(todayLabel)")
        // The 24-hour "19:15" is exactly what Miles could not skim.
        precondition(!todayLabel.contains("19:15"), "en_US must not render 24-hour, got \(todayLabel)")
        precondition(todayLabel.contains("7:15"), "en_US must render 12-hour, got \(todayLabel)")

        let yesterdayLabel = label(gregorian.date(byAdding: .day, value: -1, to: now)!)
        precondition(yesterdayLabel.hasPrefix("Yesterday "), "got \(yesterdayLabel)")

        let olderLabel = label(gregorian.date(byAdding: .day, value: -3, to: now)!)
        precondition(olderLabel.contains("Aug 23"), "an older row must name its date, got \(olderLabel)")
        precondition(olderLabel.contains("7:15"), "an older row keeps its time, got \(olderLabel)")

        let lastYearLabel = label(gregorian.date(byAdding: .year, value: -1, to: now)!)
        precondition(lastYearLabel.contains("2025"), "a prior-year row must carry the year, got \(lastYearLabel)")
        precondition(GlassesTurn.dayAnchoredTime(nil, now: now, calendar: gregorian) == "—")

        // Row badge glyphs (0.5.84). Every attachment rendered `photo`, so a
        // 75-second video wore an image icon.
        func badgeTurn(_ refs: [GlassesAttachmentRef]) -> GlassesTurn {
            GlassesTurn(id: "t", no: 1, timestamp: 1, query: "q", text: "a",
                        sessionId: "s", source: "live", attachments: refs)
        }
        func badgeRef(_ kind: String, _ mime: String, _ category: String) -> GlassesAttachmentRef {
            GlassesAttachmentRef(object: [
                "id": .string("m_4b754cfbf2164a2722ae1b48"),
                "kind": .string(kind), "mime": .string(mime),
                "width": .number(10), "height": .number(10),
                "createdAt": .string("2026-08-26T22:30:20.926Z"),
                "category": .string(category),
            ])!
        }
        let videoRow = badgeTurn([badgeRef("user_video", "video/quicktime", "video")])
        precondition(videoRow.attachmentGlyph == "video",
                     "a video must not wear an image icon, got \(videoRow.attachmentGlyph ?? "nil")")
        precondition(videoRow.attachmentSummary == "1 video")
        let imageRow = badgeTurn([badgeRef("user_photo", "image/jpeg", "image")])
        precondition(imageRow.attachmentGlyph == "photo")
        precondition(imageRow.attachmentSummary == "1 image")
        let fileRow = badgeTurn([badgeRef("user_document", "application/pdf", "document")])
        precondition(fileRow.attachmentGlyph == "doc.text")
        precondition(fileRow.attachmentSummary == "1 file")
        let mixedRow = badgeTurn([
            badgeRef("user_video", "video/quicktime", "video"),
            badgeRef("user_photo", "image/jpeg", "image"),
        ])
        precondition(mixedRow.attachmentGlyph == "paperclip",
                     "a mixed turn must not claim to be one type")
        precondition(mixedRow.attachmentSummary == "2 attachments")
        precondition(badgeTurn([]).attachmentGlyph == nil, "no attachments means no badge")
        let twoVideos = badgeTurn([
            badgeRef("user_video", "video/quicktime", "video"),
            badgeRef("user_video", "video/mp4", "video"),
        ])
        precondition(twoVideos.attachmentSummary == "2 videos", "the noun must pluralize")

        // Corner-badge category (0.5.85). The badge is drawn from this.
        precondition(videoRow.attachmentCategory == "video")
        precondition(imageRow.attachmentCategory == "image")
        precondition(fileRow.attachmentCategory == "document")
        precondition(mixedRow.attachmentCategory == "mixed",
                     "a turn holding two kinds must not claim to be one of them")
        precondition(badgeTurn([]).attachmentCategory == nil, "no attachments means no badge")

        // The FOURTH image-only filter (0.5.83). The helper answered
        // `state: ready, mime: video/quicktime` and the app threw it away
        // here, so the poster rendered and the click still failed.
        precondition(GlassesAttachmentRef.acceptsFetchedMime("video/quicktime"),
                     "a fetched video payload must be accepted or the click cannot open it")
        precondition(GlassesAttachmentRef.acceptsFetchedMime("video/mp4"))
        precondition(GlassesAttachmentRef.acceptsFetchedMime("application/pdf"))
        precondition(GlassesAttachmentRef.acceptsFetchedMime("image/jpeg"),
                     "images must still be accepted exactly as before")
        precondition(!GlassesAttachmentRef.acceptsFetchedMime("application/x-mach-binary"),
                     "widening must not accept an arbitrary payload type")

        // ── Video and document attachments (0.5.80) ───────────────────
        //
        // Control accepted images ONLY, so the video ref the server sent for
        // Message #29 failed the parser and vanished: no badge, no poster, no
        // asset anywhere in the Mac UI. This is that exact payload.
        let videoRef = GlassesAttachmentRef(object: [
            "id": .string("m_93c30da025af44a2f617a926"),
            "kind": .string("user_video"),
            "mime": .string("video/quicktime"),
            "width": .number(480), "height": .number(360),
            "createdAt": .string("2026-08-26T22:30:20.926Z"),
            "category": .string("video"),
            "bytes": .number(2_196_720),
            "durationMs": .number(75_755),
            "label": .string("80947613953__F2726445.MOV"),
        ])
        precondition(videoRef != nil, "the server's real video ref must parse")
        precondition(videoRef?.isVideo == true)
        precondition(videoRef?.opensInline == false, "a .mov must never take the inline image path")
        precondition(videoRef?.durationLabel == "1:16", "got \(videoRef?.durationLabel ?? "nil")")
        precondition(videoRef?.sizeLabel == "2.1 MB", "got \(videoRef?.sizeLabel ?? "nil")")
        precondition(videoRef?.fileExtension == "mov", "LaunchServices routes on the extension")
        precondition(videoRef?.displayLabel == "Your video")

        let docRef = GlassesAttachmentRef(object: [
            "id": .string("m_4b754cfbf2164a2722ae1b48"),
            "kind": .string("user_document"),
            "mime": .string("application/pdf"),
            "width": .number(612), "height": .number(792),
            "createdAt": .string("2026-08-26T22:30:20.926Z"),
            "category": .string("document"),
            "bytes": .number(48_000),
        ])
        precondition(docRef?.isDocument == true)
        precondition(docRef?.opensInline == false)
        precondition(docRef?.fileExtension == "pdf")
        precondition(docRef?.displayLabel == "Your file")

        // A legacy image ref omits `category` on purpose, so classification
        // must still fall back to the mime rather than defaulting to document.
        let legacyImage = GlassesAttachmentRef(object: [
            "id": .string("m_4b754cfbf2164a2722ae1b48"),
            "kind": .string("user_photo"),
            "mime": .string("image/jpeg"),
            "width": .number(472), "height": .number(1024),
            "createdAt": .string("2026-08-24T13:01:38.348Z"),
        ])
        precondition(legacyImage?.category == "image", "a ref without category must classify by mime")
        precondition(legacyImage?.opensInline == true, "an image still opens inline")
        precondition(legacyImage?.displayLabel == "Your image")

        // Widening the vocabulary must not have opened the door to anything.
        precondition(GlassesAttachmentRef(object: [
            "id": .string("m_4b754cfbf2164a2722ae1b48"),
            "kind": .string("executable"), "mime": .string("application/x-mach-binary"),
            "width": .number(1), "height": .number(1),
            "createdAt": .string("2026-08-24T13:01:38.348Z"),
        ]) == nil, "an unknown kind/mime must still be refused")

        print("COS Control: Swift attachment parsing and owned-image decoding passed")
    }
}
