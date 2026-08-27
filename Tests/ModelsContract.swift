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

    static func main() throws {
        checkRenameEligibility()
        checkAmbiguousTitles()
        checkConfirmEligibility()
        checkMeetingRowFields()
        checkCountsSummary()
        checkSpeakerListMemory()
        checkReviewVoiceQueue()
        checkLibraryMeeting()
        checkContextSearchHit()
        checkSessionSearchHit()
        checkOrphanCapture()
        checkClaudeSession()
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
