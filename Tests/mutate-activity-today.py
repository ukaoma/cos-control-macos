#!/usr/bin/env python3
"""Activity Today home (plan v2) mutation lane. Run by hand, never by a gate.

    python3 Tests/mutate-activity-today.py <worktree> <scratch dir> [name ...]

Copies the worktree to <scratch dir>/copy, proves the UNMUTATED lane green first (Tests/activity-today-pins.py, then
Tests/run-activity-today.sh), then applies one mutant at a time: the target must appear exactly once, the mutant must make a
check fail, and the failure must name the behaviour it breaks. The copy is restored and compared byte for byte after every
mutant. A mutant that lands and survives is a finding. One suite at a time; every compile goes through the guard.
"""
import os
import filecmp, pathlib, shutil, subprocess, sys, time

M = "Sources/Models.swift"
W = "Sources/ActivityWindow.swift"
H = "HelperSources/main.swift"
CM = "Sources/ControllerModel.swift"
WW = "Sources/WorkWorkspaceView.swift"
P = "Sources/MeetingPrepStore.swift"
MUTANTS = [
    # The recording section (Miles, 2026-10-31): recordings leave Running, and nothing counts them twice
    ("recording: also in Running", M, "        let running = inFlightRows.filter { $0.recording == nil }\n", "        let running = inFlightRows\n", "[a recording is never also in Running]"),
    ("recording: no section", M, "        let recordings = inFlightRows.filter { $0.recording != nil }\n", "        let recordings: [RunRow] = []\n", "[recording section lists every recording]"),
    ("recording: not counted", M, "        c.recordings = recordings.filter { $0.recording?.saving == nil }.count\n", "", "[the count of recordings]"),
    ("recording: a saving Mac counts as recording", M, "        c.recordings = recordings.filter { $0.recording?.saving == nil }.count\n", "        c.recordings = recordings.count\n", "[a saving recording is no recording on the rail]"),
    ("recording: an unnamed one claims the glasses", M, '(recording.isUnknown ? "Recording, device not shown" : "Recording on your glasses")', '"Recording on your glasses"', "[an unnamed recording does not claim the glasses]"),
    ("recording: an unnamed stop note claims the glasses", M, '        if recording.isUnknown { return "Stop it where it started" }\n', "", "[an unnamed recording does not claim the glasses]"),
    ("recording: an unnamed row claims the glasses", M, ': recording.isUnknown ? "a recording the server counts" : "glasses recording, live transcript")', ': "glasses recording, live transcript")', "[an unnamed recording does not claim the glasses]"),
    ("recording: a Mac row is not counted out", M, '        var mac = Set(liveSessionIDs.filter { $0.hasPrefix("mac_") })\n', "        var mac = Set<String>()\n", "[a saved Mac capture is no unnamed recording]"),
    ("recording: the held capture is not counted out", M, "        if macHeld { mac.insert(captureID ?? \"\") }\n", "", "[a capture before the server knows]"),
    ("recording: a Mac capture counts twice", M, "        if macHeld { mac.insert(captureID ?? \"\") }\n", "        if macHeld { mac.insert(captureID ?? \"\"); mac.insert(\"held\") }\n", "[a Mac capture is counted once]"),
    ("recording: below zero", M, "        return max(0, (serverLive ?? 0) - mac.count)\n", "        return (serverLive ?? 0) - mac.count\n", "[never below zero]"),
    ("recording: the brief repeats it", M, '        if c.routinesRunning > 0 { parts.append(c.routinesRunning == 1 ? "a routine is running"', '        if c.recordings > 0 { parts.append("a meeting is recording") }\n        if c.routinesRunning > 0 { parts.append(c.routinesRunning == 1 ? "a routine is running"', "[the brief does not repeat a recording]"),
    ("recording: the rail says it last", M, 'text: ["\\(c.recordings) recording", waiting > 0 ? needs : nil].compactMap', 'text: [c.needs > 0 ? needs : nil, "\\(c.recordings) recording"].compactMap', "[the rail says recording first]"),
    ("recording: the rail wraps", M, 'text: ["\\(c.recordings) recording", waiting > 0 ? needs : nil].compactMap', 'text: ["\\(c.recordings) recording", c.needs > 0 ? needs : nil, running].compactMap', "[the rail says recording first]"),
    ("recording: the rail is not hot", M, '.compactMap { $0 }.joined(separator: ", "), hot: true)\n            }\n', '.compactMap { $0 }.joined(separator: ", "), hot: c.needs > 0)\n            }\n', "[the rail says recording first]"),
    ("recording: a Mac's title is lost", M, "            else if let own = recording.title.flatMap({ guarded($0) }) { title = own }\n", "", "[a Mac recording shows its title]"),
    ("recording: the row forgets it records", M, "started: start, recording: recording))\n", "started: start))\n", "[recording section lists every recording]"),
    ("recording: a saving Mac still says recording", M, "        if let saving = recording.saving { return saving }\n", "", "[a stopped recording says it is saving]"),
    # The rail and the Needs you header read the fold (0.5.361 QA U4)
    ("fold: the rail counts every need", M, "            let waiting = c.needs - c.folded\n", "            let waiting = c.needs\n", "[the rail agrees with the fold"),
    ("fold: the rail has no can-wait line", M, '            else if c.folded > 0 { needs = "\\(c.folded) can wait until tomorrow" }\n', "", "[the rail agrees with the fold"),
    ("fold: the rail is hot for folded things", M, 'return Story(text: [needs, running].compactMap { $0 }.joined(separator: ", "), hot: waiting > 0)', 'return Story(text: [needs, running].compactMap { $0 }.joined(separator: ", "), hot: c.needs > 0)', "[the rail agrees with the fold"),
    ("fold: a recording names folded things", M, 'text: ["\\(c.recordings) recording", waiting > 0 ? needs : nil].compactMap', 'text: ["\\(c.recordings) recording", c.needs > 0 ? needs : nil].compactMap', "[a recording names no folded things"),
    ("fold: the rail reads raw counts", W, "TodayHome.story(item.key, railCounts, now: now)", "TodayHome.story(item.key, frame.counts, now: now)", "[rail] the rail reads the quiet-hours fold"),
    ("fold: the header counts every need", W, 'if line == .rows, !folded.now.isEmpty { Text("\\(folded.now.count)")', 'if line == .rows { Text("\\(frame.needs.count)")', "[header] the Needs you header counts the rows it lists"),
    ("recording: glasses have no stop note", M, 'return recording.isPhone ? PhoneMeetingCapture.stopNote : "Stop it on the glasses"', "return nil", "[glasses say they stop on the glasses]"),
    ("recording: the Mac has a stop note", M, "        if recording.isMac { return nil }\n", "", "[glasses say they stop on the glasses]"),
    # B1 tool-name guard (QA round 1 item 9: known names only, brands stay)
    ("guard: a known tool name passes", M, "        toolNames.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))\n", "        false\n", "[a bare tool name is caught]"),
    ("guard: CamelCase brands taken for tools", M, "        toolNames.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))\n",
     '        toolNames.contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) || text.range(of: "^[A-Z][a-z0-9]+([A-Z][A-Za-z0-9]*)+$", options: .regularExpression) != nil\n', "[a brand title is never taken for a tool]"),
    ("guard: the question text is not guarded", M, "if let text = guarded(session.waitingQuestion) { return ActivityHome.clip(text, 240) }", "if !session.waitingQuestion.isEmpty { return session.waitingQuestion }", "[AskUserQuestion never renders"),
    ("guard: a plan shows question text", M, 'guard session.provider == "claude", session.waitingKind != "plan" else { return nil }', 'guard session.provider == "claude" else { return nil }', "[a plan has no question text]"),
    ("questions: 1 of N never said", M, '        if session.waitingQuestionCount > 1, questionText(session) != nil { return "Question 1 of \\(session.waitingQuestionCount)" }\n', "", "[several questions: 1 of N]"),
    # D2 intake split and midnight
    ("split: today by producedAt day, not the filename", M, "if isToday(filename: item.meeting.filename, now: now, calendar: calendar) { split.today.append(item) } else { split.older.append(item) }",
     "if item.producedDate.map({ calendar.isDate($0, inSameDayAs: now) }) ?? true { split.today.append(item) } else { split.older.append(item) }", "[today's meetings own"),
    ("split: closed items counted", M, "isOpen(item) && !dismissed.contains(item.id) }", "!dismissed.contains(item.id) }", "[today's meetings own"),
    ("split: an undated card goes to Today", M, "guard let ref = card.meetingRefs.first else { return false }", "guard let ref = card.meetingRefs.first else { return true }", "[today's meetings own"),
    # Running
    ("running: a waiting session is running", M, 'return session.state == "running" || (session.state == "waiting" && session.heldByServer)', 'return session.state == "running" || session.state == "waiting"', "[grouped by platform"),
    ("running: a Work run's server job is a second row", M, "guard !workJobIDs.contains(job.jobId), !routineJobs.contains(job.jobId) else { continue }", "guard !routineJobs.contains(job.jobId) else { continue }", "[grouped by platform"),
    ("running: a missing origin is a person", M, 'let raw = o["origin"]?.string ?? "other"', 'let raw = o["origin"]?.string ?? "person"', "[a missing origin is other"),
    ("running: the start ignores elapsed", M, "started = receivedAt.addingTimeInterval(-elapsedMs / 1000)", "started = receivedAt", "[a glasses question opens its conversation]"),
    ("running: elapsed frozen at the tick", M, 'detail: "COS is answering, " + duration(input.now.timeIntervalSince(job.started)),', 'detail: "COS is answering, " + duration(job.elapsedMs / 1000),', "[elapsed counts up between ticks]"),
    ("running: a jobless routine runs forever", M, "static let routineSubmitWindow: TimeInterval = 600", "static let routineSubmitWindow: TimeInterval = 600_000", "[a jobless run still submitting"),
    ("finished: the hour is two", M, "static let finishedWindow: TimeInterval = 3600", "static let finishedWindow: TimeInterval = 7200", "[finished within the hour"),
    ("finished: counted in Running", M, "                           moreFinished: finished.count - done.count, count: inFlight.count)", "                           moreFinished: finished.count - done.count, count: inFlight.count + done.count)", "[five running and one finished fit"),
    ("cap: finished rows keep their room", M, "        let room = max(0, cap - shown.count)\n", "        let room = finished.count\n", "[8 or more running"),
    ("platform: Cursor without Accessibility opens Cursor", M, ': ("In Sessions", .inSessions(session.id), "Open in Cursor needs Accessibility. Turn on in Settings")', ': ("Open in Cursor", .platform(session.id), nil)', "[Cursor without Accessibility"),
    ("platform: a Work run opens in an app", M, '        case .work, .routine: return ("In Sessions", .inSessions(session.id), nil)', '        case .work, .routine: return ("Open session", .platform(session.id), nil)', "[a Work run the server holds cannot open"),
    ("platform: no fallback when no host is found", M, "            return hostsRead ? (\"In Sessions\"", "            return false ? (\"In Sessions\"", "[no host after the lookup"),
    # Needs you
    ("needs: a Work item for a waiting session shows twice", M, "if let sid = move.sessionID, waitingIDs.contains(where: { ClaudeSession.sameSession($0, sid) }) { continue }", "", "[ranked"),
    ("needs: newest question first", M, "return x == y ? a.id < b.id : x < y\n        }\n    }\n    static func waitingSince", "return x == y ? a.id < b.id : x > y\n        }\n    }\n    static func waitingSince", "[the oldest question first"),
    ("needs: agreeing counts instead of similarity", M, 'why: name.map { "Sounds like \\($0), similarity " + String(format: "%.2f", group.suggestionSimilarity) + "." },', 'why: name.map { "Sounds like \\($0), \\(group.suggestionAgreeing) of \\(group.suggestionOf) agree." },', "[a voice shows its similarity"),
    ("memories: always 7 to review", M, "        if let total, total > count { return \"Next \\(count) of \\(total)\" }\n", "", "[Next 7 of 23"),
    ("show more: every hidden title", M, "        let labels = hidden.prefix(2).map(shortLabel)\n", "        let labels = hidden.map(shortLabel)\n", "[Show more names two at most]"),
    ("suggestions: a link creates a task", M, "        if item.kind == .link { return .openCard(item.pullTitle ?? item.text) }\n", "", "[an ask creates, a link opens"),
    # Composition (QA round 1 items 1, 2, 10)
    ("compose: unreachable keeps the server's rows", M, "        if !reachable {\n            need.voiceGroups = nil;", "        if false {\n            need.voiceGroups = nil;", "[unreachable: Needs you keeps"),
    ("compose: the server's sources stay answered when unreachable", M, "func server(_ state: ActivityHome.SourceState) -> ActivityHome.SourceState { input.reachable || state == .off ? state : .failed }",
     "func server(_ state: ActivityHome.SourceState) -> ActivityHome.SourceState { state }", "[unreachable: the server's sources are failed"),
    ("compose: a failed Intake ignored", M, "        if input.intakeFailed, work != .off { work = .failed }\n", "", "[a failed Intake read fails Work"),
    ("compose: voices counted while loading", M, "c.voicesToName = answered(.voices, states) && facts.voicesLoaded ?", "c.voicesToName = facts.voicesLoaded ?", "[unreachable: no count that reads the server]"),
    ("compose: the calendar clear unless the server said otherwise", M, "        c.calendarRead = facts.calendarRead == true\n", "        c.calendarRead = facts.calendarRead != false\n", "[no calendarRead from the server"),
    ("states: settled while a source failed", M, "return !counted.isEmpty && counted.allSatisfy { $0 == .answered }\n    }", "return !counted.isEmpty && counted.allSatisfy { $0 != .pending }\n    }", "[never nothing waiting while a source is down]"),
    ("brief: nothing waiting while still reading", M, "        } else if c.settled {\n            first = \"Nothing is waiting on you\"", "        } else {\n            first = \"Nothing is waiting on you\"", "[no false caught up while loading]"),
    ("brief: no clear-day claim when clear", M, '            first = first.map { $0 + ", and your calendar is clear for the rest of the day" } ?? "Your calendar is clear for the rest of the day"\n', "", "[the caught-up brief]"),
    # 0.5.361 QA item 2: a search hit keeps the guards a list row has
    ("hit: the loaded row is ignored", M, "        if let row = loaded.first(where: { sameSession($0.id, hit.id) }) { return row }\n", "", "[a hit the list holds is the list's row]"),
    ("hit: never marked as Work", M, "        return markingWork([hit], workSessionIDs: workSessionIDs, runningWorkSessionIDs: runningWorkSessionIDs)[0]\n", "        return hit\n", "[a hit of a running Work session is held by the server]"),
    ("hit: the running set is dropped", M, "        return markingWork([hit], workSessionIDs: workSessionIDs, runningWorkSessionIDs: runningWorkSessionIDs)[0]\n", "        return markingWork([hit], workSessionIDs: workSessionIDs, runningWorkSessionIDs: [])[0]\n", "[a hit of a running Work session is held by the server]"),
    ("model: Work's rail ignores the fold", M, '            let needsNow = max(0, (c.workNeedsYou ?? 0) - c.foldedWork)\n', '            let needsNow = c.workNeedsYou ?? 0\n', "Work's rail line agrees with the fold"),
    ("model: Work's rail is hot for folded rows", M, 'return Story(text: bits.joined(separator: ", "), hot: needsNow > 0)', 'return Story(text: bits.joined(separator: ", "), hot: c.workNeedsYou ?? 0 > 0)', "Work's rail line agrees with the fold"),
    ("model: Work's rail has no can-wait bit", M, '            if c.foldedWork > 0 { bits.append("\\(c.foldedWork) can wait") }\n', '', "Work's rail line agrees with the fold"),
    ('model: the search merge keeps both ids', M, 'if let at = out.firstIndex(where: { $0.id == hit.id || ClaudeSession.sameSession($0.id, hit.id) }) {', 'if let at = out.firstIndex(where: { $0.id == hit.id }) {', 'the search merge keeps one row for a session named two ways'),
    ('model: the search merge keeps the weaker score', M, 'if out[at].score < hit.score { out[at] = hit }', 'if out[at].score > hit.score { out[at] = hit }', 'the search merge keeps one row for a session named two ways'),
    ("view: Work's rail count never reads the fold", W, '        counts.foldedWork = tomorrow.filter { $0.kind == .work }.count\n', '', "[wording] Today's headline reads the quiet-hours fold"),
    ("hit: the loaded row matches on exact ids only", M, "loaded.first(where: { sameSession($0.id, hit.id) })", "loaded.first(where: { $0.id == hit.id })", "a hit the list names by its full id is the list's row"),
    # Quiet hours
    ("quiet: session questions fold", M, "return (rows.filter { $0.tier == 1 }, rows.filter { $0.tier != 1 })", "return ([], rows)", "[tiers 2 to 5 fold"),
    ("quiet: 7 PM, not 6 PM", M, "|| hour >= 18 ||", "|| hour >= 19 ||", "[6 PM is quiet]"),
    ("quiet: the early morning is not quiet", M, "|| hour >= 18 || hour < 6", "|| hour >= 18", "[before 6 AM on a weekday is quiet"),
    ("quiet: weekends are not quiet", M, "return calendar.isDateInWeekend(now) || hour >= 18", "return hour >= 18", "[Saturday is quiet]"),
    ("quiet: the switch ignored", M, "        guard enabled else { return false }\n        let hour", "        let hour", "[the switch off: never quiet]"),
    # Cost guards
    ("guard: the cap is 21", M, "if used(now: now) >= Self.dailyCap { return .capReached }", "if used(now: now) > Self.dailyCap { return .capReached }", "[the 21st of the day is refused]"),
    ("guard: the switch ignored", M, "        guard switchOn else { return .switchOff }\n", "", "[the switch off starts nothing]"),
    ("guard: two runs per meeting", M, "        if inFlight.contains(target) { return .inFlight }\n", "", "[one run in flight per meeting]"),
    ("guard: the breaker never opens", M, "        if let until = pausedUntil(now: now) { return .paused(until: until) }\n", "", "[3 failures in a row pause"),
    ("guard: a success does not reset", M, "        guard !admitted else { defaults.set(0, forKey: Self.failuresKey); return }", "        guard !admitted else { return }", "[a success in between resets"),
    ("guard: yesterday's count carries over", M, "defaults.string(forKey: Self.dayKey) == ActivityHome.dayKey(now, calendar: calendar) ? defaults.integer(forKey: Self.countKey) : 0", "defaults.integer(forKey: Self.countKey)", "[a new day starts a new count]"),
    ("guard: a refusal before submit counts", M, "        case .notStarted: break\n", "        case .notStarted: recordStart(now: now); recordOutcome(admitted: false, now: now)\n", "[refused before submit"),
    ("guard: a refused receipt reads as admitted", M, 'if ["refused", "failed"].contains(status) { return .refused(error ?? "The server did not start it.") }', 'if ["refused", "failed"].contains(status) { return .admitted }', "[the run outcome from the new receipt]"),
    ("guard: busy Work ignored", M, '        if busy { return "Work is sending something else. Try again in a moment." }\n', "", "[busy Work or an open run"),
    ("model: Opus allowed by default", M, ' && !choices[$0].id.lowercased().contains("opus") }', " }", "[never Opus by default]"),
    # Layout and the tick loop
    ("layout: the rail breakpoint at 1099", M, "windowWidth >= fullRailBreakpoint ? .full : .icons", "windowWidth > fullRailBreakpoint ? .full : .icons", "[the rail is icons at 1,099 pt"),
    ("layout: two columns from 1,100 pt", M, "static let twoColumnWindow: CGFloat = 1228", "static let twoColumnWindow: CGFloat = 1100", "[two columns only once"),
    ("layout: no right-column floor", M, "let right = max(rightColumnFloor, (content - gap) / 2.6)", "let right = (content - gap) / 2.6", "[the right column never narrower"),
    ("tick: hidden windows tick", M, "            if visible(), last.map", "            if true, last.map", "[one tick a minute while on screen"),
    ("tick: no wait for the opening loads", M, "        while !ready(), now().timeIntervalSince(start) < readyLimit {", "        while false, now().timeIntervalSince(start) < readyLimit {", "[the first tick waits"),
    # Wiring (pins)
    ("polling: the loop ignores the window", W, "visible: { today.windowVisible }", "visible: { true }", "[polling]"),
    ("polling: the loop ignores the opening loads", W, "ready: { today.overviewDone }", "ready: { true }", "[polling]"),
    ("polling: the calendar every tick", W, "        let calendar = lastCalendar.map { now.timeIntervalSince($0) >= Self.slowSeconds } ?? true\n", "        let calendar = true\n", "[polling]"),
    ("states: checked after a failed tick", W, "            if reachable == true { checkedAt = Date() }\n", "            checkedAt = Date()\n", "[states]"),
    ("pet off: no session refresh", W, "        } else if !model.petEnabled { await model.loadClaudeSessions() }\n", "        }\n", "[pet off]"),
    ("create: Create task dismisses", W, "await model.resolveWorkIntake(item, accept: true)", "await model.resolveWorkIntake(item, accept: false)", "[create accepts]"),
    ("one at a time: two creates at once", W, "        guard model.workIntakeBusyIDs.isEmpty, !created.contains(item.id) else { return }\n", "        guard !created.contains(item.id) else { return }\n", "[one at a time]"),
    ("cost: a run before admission", W, "        guard admission == .allowed else {", "        guard admission == .allowed || true else {", "[cost guards]"),
    ("cost: an earlier receipt read as this one", W, "let receipt = handoff.receipts.first { $0.id == id }", "let receipt = handoff.receipts.first { $0.workID == target }", "[cost guards]"),
    ("capability: questions on an older server", W, "input.jobs = today.jobsSupported == true ? today.jobs : nil", "input.jobs = today.jobs", "[capability]"),
    ("reduce motion: the setting is read once", W, "            .onChange(of: reduceMotion) { _, still in animate(!still) }\n", "", "[reduce motion]"),
    ("voices: a stale result reused", W, "        model.heldNamingResult = nil\n        model.cancelHeldNamingPreview()\n", "        model.cancelHeldNamingPreview()\n", "[voices]"),
    # 0.5.337 Dismiss on Today: the rules (Models, executed) and the wiring (pins)
    ("dismiss: a refusal collapses the row", M, "        case .refused(let reason, _):\n            failures[item.id] = reason\n",
     "        case .refused(let reason, _):\n            failures[item.id] = reason\n            rows[item.id] = Row(item: item, undo: nil, until: now.addingTimeInterval(Self.undoSeconds))\n", "[a failed dismiss keeps the row]"),
    ("dismiss: the window never ends", M, "    static let undoSeconds: TimeInterval = 8\n", "    static let undoSeconds: TimeInterval = 80\n", "[after about 8 seconds the Dismissed line leaves]"),
    ("dismiss: the window is 5 seconds", M, "    static let undoSeconds: TimeInterval = 8\n", "    static let undoSeconds: TimeInterval = 5\n", "[the Dismissed line stays for the undo window]"),
    ("dismiss: expire ignores the window", M, "    mutating func expire(now: Date) { rows = rows.filter { $0.value.undoing || $0.value.until > now } }", "    mutating func expire(now: Date) { rows = [:] }", "[the Dismissed line stays for the undo window]"),
    ("dismiss: one row twice in flight", M, "        guard !dismissing.contains(id), rows[id] == nil else { return false }", "        guard rows[id] == nil else { return false }", "[one dismiss per row in flight]"),
    ("split: a dismissed id still counted", M, "isOpen(item) && !dismissed.contains(item.id) }", "isOpen(item) }", "[the count drops as soon as the dismiss is confirmed]"),
    ("split: the split skips isShown", M, "        for item in items where isShown(item, dismissed: dismissed) {", "        for item in items where isOpen(item) {", "[the count drops as soon as the dismiss is confirmed]"),
    ("undo: the line stays after a confirmed undo", M, "        guard let error else { rows[id] = nil; return }\n", "        guard let error else { return }\n", "[Undo restores the row and the count]"),
    ("undo: the refusal's reason dropped", M, "        row.undoError = error\n", "", "[a refused undo keeps the line with the reason]"),
    ("undo: sent twice", M, "        guard var row = rows[id], !row.undoing, let undo = row.undo else { return nil }", "        guard var row = rows[id], let undo = row.undo else { return nil }", "[Undo sends that row's own undo id, once]"),
    ("resolve: an accept's undo offered on a dismiss", M, 'let undo: String? = decided == (accept ? "accept" : "dismiss") ? at.map { itemID + ":" + $0 } : nil',
     'let undo: String? = at.map { itemID + ":" + $0 }', "[a dismiss answered with another decision offers no undo"),
    ("resolve: an older server's 404 reads as dismissed", M, '        if details["unsupported"]?.bool == true { self = .refused(message, code: "unsupported"); return }\n', "", "[an older server's 404 changed nothing]"),
    ("undo: the item stays hidden", M, '        dismissed.filter { !batchId.hasPrefix($0 + ":") }', "        dismissed", "[an undo gives back only its own item]"),
    ("slots: the Dismissed line dropped", M, "map(SuggestionSlot.open) + live.map(SuggestionSlot.dismissed)", "map(SuggestionSlot.open)", "[the Dismissed line holds the row's place]"),
    ("slots: the line moves to the end", M, "        return slots.sorted { key($0) < key($1) }\n", "        return slots\n", "[the Dismissed line holds the row's place]"),
    ("slots: a stale open copy wins", M, "        let slots = open.filter { !collapsed.contains($0.id) }.map(SuggestionSlot.open)", "        let slots = open.map(SuggestionSlot.open)", "[the Dismissed line wins over an open copy"),
    ("state: a failed dismiss reads ready", M, "        if let reason = dismissals.failures[id] { return .dismissFailed(reason) }\n", "", "[a failed dismiss keeps the row]"),
    ("state: dismissing reads creating", M, "return dismissals.dismissing.contains(id) ? .dismissing : .creating", "return .creating", "[a dismissing row says Dismissing"),
    ("label: no title", M, '"Dismiss suggestion: " + item.text', '"Dismiss"', "[VoiceOver names what Dismiss removes]"),
    ("dismiss: two at once", W, "        guard model.workIntakeBusyIDs.isEmpty, !created.contains(item.id), dismissals.begin(item.id) else { return }", "        guard dismissals.begin(item.id) else { return }", "[one at a time]"),
    ("dismiss: a refusal hides the panel", W, '            lastResolveError = model.workIntakeError\n            todayLog.error("dismiss refused', '            todayLog.error("dismiss refused', "[refusal keeps the row]"),
    ("dismiss: the reason logged", W, 'todayLog.error("dismiss refused code=\\(code, privacy: .public)")', 'todayLog.error("dismiss refused \\(model.workIntakeError ?? "", privacy: .public)")', "[refusal keeps the row]"),
    ("undo: Work's last decision instead", W, "        let error = await model.undoWorkIntake(batchId: undo)", "        await model.undoWorkIntake(); let error: String? = nil", "[undo its own row]"),
    ("expiry: the line never leaves", W, "            self?.dismissals.expire(now: Date())\n", "            _ = self\n", "[collapsed line]"),
    ("panel: dismissed rows vanish", W, "                    case .dismissed(let row): todayDismissedRow(row)\n", "                    case .dismissed: EmptyView()\n", "[collapsed line]"),
    ("keyboard: Delete ignored", W, ".onKeyPress(keys: [.delete, .deleteForward], phases: .down)", ".onKeyPress(keys: [.return], phases: .down)", "[keyboard]"),
    ("quiet: a filled Dismiss", W, ".buttonStyle(TodayLinkStyle(color: TodayInk.sub, size: 12.5))\n            .padding(.leading, 6)", ".buttonStyle(TodayButtonStyle(small: true))\n            .padding(.leading, 6)", "[quiet]"),
    ("voiceover: Dismiss unnamed", W, "            .accessibilityLabel(TodayHome.dismissLabel(item))\n", "", "[voiceover]"),
    ("model: an unconfirmed dismiss hides the item", CM, "            if !accept, case .changed = result { workIntakeDismissedIDs.insert(item.id) }", "            if !accept { workIntakeDismissedIDs.insert(item.id) }", "[same predicate]"),
    ("model: undo keeps the item hidden", CM, "        workIntakeDismissedIDs = TodayDismissals.afterUndo(workIntakeDismissedIDs, batchId: batchId)\n", "", "[undo its own row]"),
    ("split: Work's Sort ignores Today's dismissals", WW, ", now: Date(), dismissed: model.workIntakeDismissedIDs) : TodayHome.IntakeSplit()", ", now: Date()) : TodayHome.IntakeSplit()", "[same predicate]"),
    ("capability: detected by status code", H, 'return features?["activeQueryJobs"] as? Bool == true && jsonInt(features?["activeQueryJobsProtocol"]) == 1', "return health != nil", "[capability]"),
    ("disk: the question cached on disk", H, '"sessions": sessions.map { $0.filter { $0.key != "waitingQuestion" && $0.key != "waitingQuestionCount" } },', '"sessions": sessions,', "[disk]"),
    # 0.5.384 Today round 2: Next up from /api/calendar/today, and Ask about this
    ("384: no 5-row cap", M, "        let shown = Array(live.prefix(nextUpRows))\n", "        let shown = live\n", "[5-row cap]"),
    ("384: no +N more", M, "        let more = max(0, calendar.remainingCount - ended - dropped - shown.count)\n", "        let more = 0\n", "[+N more]"),
    ("384: ended rows still counted", M, "        let more = max(0, calendar.remainingCount - ended - dropped - shown.count)\n", "        let more = max(0, calendar.remainingCount - dropped - shown.count)\n", "[+N more]"),
    ("384: all-day rows kept", M, "        let counted = calendar.rows.filter { !$0.allDay }\n", "        let counted = calendar.rows\n", "[all-day filter]"),
    ("384: not connected is a list", M, 'guard let o = value?.object, o["available"]?.bool == true, o["connected"]?.bool == true else { return nil }', 'guard let o = value?.object else { return nil }', "[fallback to one event]"),
    ("384: connected is ignored", M, 'guard let o = value?.object, o["available"]?.bool == true, o["connected"]?.bool == true else { return nil }', 'guard let o = value?.object, o["available"]?.bool == true else { return nil }', "[fallback to one event] not connected"),
    ("384: fallback drops the one event", M, "        guard let calendar else { return NextUp(events: single.map { [$0] } ?? [], more: 0, asOf: nil, fromCalendar: false) }", "        guard let calendar else { return NextUp(events: [], more: 0, asOf: nil, fromCalendar: false) }", "[fallback to one event]"),
    ("384: duplicates shown", M, '            return seen.insert(row.title.lowercased() + "|" + String(Int(row.start.timeIntervalSince1970 / 60))).inserted\n', "            return true\n", "[duplicates and cancellations]"),
    ("384: cancellations shown", M, "            guard !isCanceled(row.title) else { return false }\n", "", "[duplicates and cancellations]"),
    ("384: dropped rows still counted", M, "        let more = max(0, calendar.remainingCount - ended - dropped - shown.count)\n", "        let more = max(0, calendar.remainingCount - ended - shown.count)\n", "[duplicates and cancellations]"),
    ("384: no stale as-of", M, "asOf: calendar.stale ? calendar.asOf : nil, fromCalendar: true)", "asOf: nil, fromCalendar: true)", "[stale as of]"),
    ("384: as-of on a fresh calendar", M, "asOf: calendar.stale ? calendar.asOf : nil, fromCalendar: true)", "asOf: calendar.asOf, fromCalendar: true)", "[stale as of]"),
    ("384: ask without the sessions", M, '            lines.append("- " + parts.joined(separator: " | "))\n', "", "[ask context]"),
    ("384: ask without the summary time", M, '        lines.append("Today summary" + (summaryAt.map { ", written " + TodayHome.clock($0, calendar: calendar) } ?? "") + ":")\n', '        lines.append("Today summary:")\n', "[ask context]"),
    ("384: ask without the last ask", M, '            if let ask = row.lastAsk?.trimmingCharacters(in: .whitespacesAndNewlines), !ask.isEmpty {', '            if let ask = row.lastAsk?.trimmingCharacters(in: .whitespacesAndNewlines), ask.isEmpty {', "[ask context]"),
    ("384: the fence breaks", M, '    static func defenced(_ text: String) -> String { text.replacingOccurrences(of: "```", with: "\'\'\'") }', "    static func defenced(_ text: String) -> String { text }", "[ask context]"),
    ("384: field shown with the chat off", M, "        summaryShown && reachable && chatAvailable && workRunsOn && !preview\n", "        summaryShown && reachable && workRunsOn && !preview\n", "[field hidden]"),
    ("384: field shown offline", M, "        summaryShown && reachable && chatAvailable && workRunsOn && !preview\n", "        summaryShown && chatAvailable && workRunsOn && !preview\n", "[field hidden]"),
    ("384: field not under the summary", W, "                    todayAskAboutField(frame)\n", "", "[ask about] the field sits under the summary line"),
    ("384: helper skips calendar/today", H, '            let today = get("/api/calendar/today", timeout: 12)\n', "            let today: HTTPResponse? = nil\n", "[next up] the helper reads /api/calendar/today"),
    ("384: +N more opens nothing", W, "                    Button(more) { select(.meetings) }\n", "                    Button(more) { }\n", "[next up] +N more today opens Meetings"),
    # 0.5.385 Prep on every Next up row
    ("385: holds get Prep", M, "    static func offered(_ event: TodayHome.NextEvent, available: Bool) -> Bool { available && !isHold(event) }", "    static func offered(_ event: TodayHome.NextEvent, available: Bool) -> Bool { available }", "[prep rows]"),
    ("385: a meeting with someone is a hold", M, '        return !tokens.contains("with")\n', "        return true\n", "[prep rows]"),
    ("385: the hold words are not whole words", M, "        guard holdWords.contains(where: { t.hasPrefix($0) && !word(t.dropFirst($0.count).first) }) else { return false }", "        guard holdWords.contains(where: { t.hasPrefix($0) }) else { return false }", "[no prep on holds]"),
    ("385: leading punctuation hides a hold", M, "        let t = String(words.drop(while: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }))\n", "        let t = words\n", "[no prep on holds]"),
    ("385: the server's mark is ignored", M, "    static func isHold(_ event: TodayHome.NextEvent) -> Bool { event.hold ?? isHold(event.title) }", "    static func isHold(_ event: TodayHome.NextEvent) -> Bool { isHold(event.title) }", "[no prep on holds]"),
    ("385: calendar rows drop the mark", M, '                           hold: r["hold"]?.bool)', "                           hold: nil)", "[no prep on holds]"),
    ("385: welcome-context drops the mark", M, '        return NextEvent(title: ActivityHome.clip(title, 120), start: start, hold: o["hold"]?.bool)', "        return NextEvent(title: ActivityHome.clip(title, 120), start: start)", "[no prep on holds]"),
    ("385: Prep offline", M, "        reachable && chatAvailable && workRunsOn && !preview\n    }\n\n    /// Prep shows", "        chatAvailable && workRunsOn && !preview\n    }\n\n    /// Prep shows", "[prep hidden]"),
    ("385: Prep with the chat off", M, "        reachable && chatAvailable && workRunsOn && !preview\n    }\n\n    /// Prep shows", "        reachable && workRunsOn && !preview\n    }\n\n    /// Prep shows", "[prep hidden]"),
    ("385: Prep with Ask off", M, "        reachable && chatAvailable && workRunsOn && !preview\n    }\n\n    /// Prep shows", "        reachable && chatAvailable && !preview\n    }\n\n    /// Prep shows", "[prep hidden]"),
    ("385: Prep in a preview", M, "        reachable && chatAvailable && workRunsOn && !preview\n    }\n\n    /// Prep shows", "        reachable && chatAvailable && workRunsOn\n    }\n\n    /// Prep shows", "[prep hidden]"),
    ("385: a second panel stays open", M, "        mutating func toggle(_ key: String) { open = open == key ? nil : key; note = nil }", "        mutating func toggle(_ key: String) { if open == nil || open == key { open = open == key ? nil : key }; note = nil }", "[one panel]"),
    ("385: Escape drops the words", M, "        mutating func close() { open = nil; note = nil }", "        mutating func close() { if let o = open { drafts[o] = nil }; open = nil; note = nil }", "[one panel]"),
    ("385: Cancel keeps the words", M, "        mutating func cancel(_ key: String) { drafts[key] = nil; if open == key { open = nil }; note = nil }", "        mutating func cancel(_ key: String) { if open == key { open = nil }; note = nil }", "[one panel]"),
    ("385: drafts keyed by title only", M, '        event.title.lowercased() + "|" + String(Int((event.start.timeIntervalSince1970 / 60).rounded(.down)))', "        event.title.lowercased()", "[draft survives refresh]"),
    ("385: drafts keyed to the second", M, '        event.title.lowercased() + "|" + String(Int((event.start.timeIntervalSince1970 / 60).rounded(.down)))', '        event.title.lowercased() + "|" + String(Int(event.start.timeIntervalSince1970))', "[draft survives refresh]"),
    ("385: more than five files", M, "                if d.files.count >= TodayPrep.filesMax { refused.append(url.lastPathComponent); continue }\n", "", "[files]"),
    ("385: Start prep drops the files", M, "        return Seed(context: String(context.prefix(contextMax)), files: Array(draft.files.prefix(filesMax)),", "        return Seed(context: String(context.prefix(contextMax)), files: [],", "[start prep]"),
    ("385: the Ask has no time", M, '        var lines = ["Prep me for " + name + " at " + TodayHome.clock(start, calendar: calendar) + "."]', '        var lines = ["Prep me for " + name + "."]', "[start prep]"),
    ("385: the context breaks the fence", M, '        if !words.isEmpty { lines += ["Context:", TodayAskAbout.defenced(String(words.prefix(contextMax)))] }', '        if !words.isEmpty { lines += ["Context:", String(words.prefix(contextMax))] }', "[start prep]"),
    ("385: the Ask leaves out the files", M, '            lines += files.prefix(filesMax).map { "- " + TodayAskAbout.defenced($0).replacingOccurrences(of: "\\n", with: " ") }\n', "", "[start prep]"),
    ("385: Start prep drops the words at once", M, "        mutating func started(_ key: String, launch: String) { starting[launch] = key; if open == key { open = nil }; note = nil }", "        mutating func started(_ key: String, launch: String) { drafts[key] = nil; starting[launch] = key; if open == key { open = nil }; note = nil }", "[start prep]"),
    ("385: any carried launch drops the draft", M, "        mutating func carried(launch: String) { if let key = starting.removeValue(forKey: launch) { drafts[key] = nil } }", "        mutating func carried(launch: String) { for key in starting.values { drafts[key] = nil } }", "[start prep]"),
    ("385: later rows have no Prep", W, "todayLaterRow(later, prepOn: prepOn)", "todayLaterRow(later, prepOn: false)", "[prep wiring]"),
    ("385: Prep me on a hold", W, "            if !TodayPrep.isHold(event) {\n", "            if true {\n", "[prep wiring]"),
    ("385: Escape ignores the panel", W, "        if section == nil, todayPrep.open != nil { todayPrep.close(); return true }\n", "", "[prep wiring]"),
    ("385: Start prep skips the chat", W, "        openDropItChat()\n        model.meetingPrep.launch = launch\n", "        model.meetingPrep.launch = launch\n", "[prep wiring]"),
    ("385: Start prep replaces an open prep", W, "        guard !model.meetingPrep.isOpen else {\n            todayPrep.note", "        guard true else {\n            todayPrep.note", "[prep wiring]"),
    ("385: every open call carries the seed", P, "        if let seed = requested.seed, activeKey == key { await carry(seed, key: key, launch: requested.id) }", "        if let seed = requested.seed { await carry(seed, key: key, launch: requested.id) }", "[prep wiring]"),
    ("385: sends before the files are saved", P, "                if !uploading, !busy, saves < 3, !uploads.attachments.isEmpty || hasQueuedFiles {\n                    saves += 1; await saveUploadedFiles()\n                } else if", "                if false {\n                } else if", "[prep wiring]"),
    ("385: merge replaces the notes", M, '        return String((head + "\\n\\n" + a).prefix(limit))\n', "        return String(a.prefix(limit))\n", "[merge notes]"),
    ("385: merge repeats the context", M, "        if old.contains(a) { return old }\n", "", "[merge notes]"),
    ("385: the draft key forgets the start", M, '        "today-next:" + startsAt(event) + ":" + event.title.trimmingCharacters(in: .whitespacesAndNewlines)', '        "today-next:" + event.title.trimmingCharacters(in: .whitespacesAndNewlines)', "[draft reuse]"),
    ("385: Start prep opens a new draft", W, "        let draftID = MeetingPrepStore.clientDraftID(for: TodayPrep.draftKey(event))\n", "        let draftID = UUID().uuidString.lowercased()\n", "[prep wiring]"),
    ("385: Prep me opens its own draft", W, "                    openMeetingPrep(title: event.title, startsAt: TodayPrep.startsAt(event),\n                                    draftID: MeetingPrepStore.clientDraftID(for: TodayPrep.draftKey(event)))", "                    openMeetingPrep(title: event.title, startsAt: TodayPrep.startsAt(event))", "[draft reuse]"),
    ("385: a rule between the row and its panel", W, "        .padding(.bottom, bottom)\n        .onKeyPress(.escape)", "        .padding(.bottom, bottom)\n        .overlay(alignment: .top) { Rectangle().fill(TodayInk.rowBorder).frame(height: 1) }\n        .onKeyPress(.escape)", "[prep layout]"),
    ("385: helper drops the row's mark", H, '            if let hold = row["hold"] as? Bool { kept["hold"] = hold }\n', "", "[prep wiring]"),
]

def run(cmd, cwd):
    started = time.time()
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    # 0.5.267: every compile in the lane runs through Tests/compile-guard.sh; a guard stop ends the lane (it is not a kill).
    if "compile-guard: STOPPED" in proc.stdout + proc.stderr:
        sys.exit("compile-guard stopped a compile (memory); ending the mutation lane. " + (proc.stderr or "")[-400:])
    return proc.returncode, proc.stdout + proc.stderr, time.time() - started

def suite(copy):
    code, out, seconds = run(["/usr/bin/python3", "Tests/activity-today-pins.py", "."], copy)
    if code != 0:
        return code, out, seconds
    # The compile lock is shared with whoever else is building: waiting for it is not a kill.
    for _ in range(60):
        code2, out2, seconds2 = run(["zsh", "Tests/run-activity-today.sh"], copy)
        if "shared compile lock busy" not in out2:
            break
        time.sleep(30)
    return code2, out + out2, seconds + seconds2

def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    # COS_MUTATE_MINUTES: stop starting mutants after this long, baseline included. The result line counts what was not run.
    minutes = float(os.environ.get("COS_MUTATE_MINUTES", "0"))
    deadline = time.time() + minutes * 60 if minutes else None
    copy = scratch / "copy"
    # Lanes compile against shared builds of Sources (Tests/kit-compile.py): keep them for every mutant of this run.
    os.environ.setdefault("COS_TEST_KIT_DIR", str(scratch / "kits"))
    if copy.exists():
        shutil.rmtree(copy)
    for part in ("Sources", "Tests", "HelperSources"):
        shutil.copytree(src / part, copy / part)
    code, out, seconds = suite(copy)
    passed = [l for l in out.splitlines() if l.startswith("PASS:") or "wiring pinned" in l]
    print(f"BASELINE (unmutated): exit {code} in {seconds:.0f}s: {' / '.join(p[:140] for p in passed) or '(no PASS line)'}", flush=True)
    if code != 0 or len(passed) != 2:
        print(out[-3000:])
        sys.exit("baseline is not green; no mutant may be judged against a red suite")
    killed, survived = 0, 0
    not_run = []
    for name, rel, old, new, words in MUTANTS:
        if only and name not in only:
            continue
        if deadline and time.time() > deadline:
            not_run.append(name); continue
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            print(f"MISS  {name}: the target appears {text.count(old)} times", flush=True); survived += 1; continue
        mutated = text.replace(old, new)
        path.write_text(mutated, encoding="utf-8")
        try:
            code, out, seconds = suite(copy)
        finally:
            path.write_text(text, encoding="utf-8")
        if not filecmp.cmp(path, src / rel, shallow=False):
            sys.exit(f"RESTORE FAILED for {name}: {rel} differs from the worktree")
        lines = [l for l in out.splitlines() if "check failed [" in l or "Activity Today pin:" in l or ": error:" in l]
        reason = lines[0].strip() if lines else (out.strip().splitlines()[-1] if out.strip() else "")
        if code == 0:
            survived += 1; print(f"SURVIVED  {name}", flush=True)
        elif words.lower() in reason.lower():
            killed += 1; print(f"killed  {name} ({seconds:.0f}s): {reason[:240]}", flush=True)
        else:
            survived += 1; print(f"MISATTRIBUTED  {name}: {reason[:240]}", flush=True)
    for name in not_run:
        print(f"NOT RUN  {name}", flush=True)
    print(f"RESULT: {killed}/{killed + survived} killed by a check that names the behaviour; {len(not_run)} not run; every restore compared equal", flush=True)
    sys.exit(0 if survived == 0 and not not_run else 1)

if __name__ == "__main__":
    main()
