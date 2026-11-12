#!/usr/bin/env python3
"""Anand parity (D4, 2026-11-12): the Mac wiring for Control Web 7.0.30's settled items. Source pins; the words run in
Tests/AnandParityChecks.swift."""
import sys
root = sys.argv[1]
def read(p): return open(f"{root}/{p}").read()
model, views, meetings = read("Sources/ControllerModel.swift"), read("Sources/Views.swift"), read("Sources/ActivityMeetings.swift")
fails = []
def need(cond, label):
    if not cond: fails.append(label)
def body(text, start, end):
    i = text.find(start); j = text.find(end, i + 1) if i >= 0 else -1
    return text[i:j] if i >= 0 and j > i else ""

# Item 3: the Speakers copy buttons.
copy = body(model, "    func copyMeeting(full: Bool) {", "\n    }\n")
need("copiedMeetingKind = full ? MeetingCopyWords.full : MeetingCopyWords.summary" in copy, "[copy] the tapped button is the one that says Copied")
need("try? await Task.sleep(for: .seconds(MeetingCopyWords.copiedSeconds))" in copy and "self?.copiedMeetingKind = nil" in copy
     and "copiedMeetingReset?.cancel()" in copy, "[copy] Copied lasts copiedSeconds, and a new copy restarts it")
need("        if let note = copyNote {\n            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested," in copy
     and "[.announcement: note," in copy, "[copy] VoiceOver hears what was copied")
need(views.count("MeetingCopyWords.label(MeetingCopyWords.summary, copied: model.copiedMeetingKind, fullChars: content.fullChars)") == 1
     and views.count("MeetingCopyWords.label(MeetingCopyWords.full, copied: model.copiedMeetingKind, fullChars: content.fullChars)") == 1
     and 'Label("Summary", systemImage' not in views, "[copy] the buttons use the web's words")
# Item 4: Meetings opens on today.
load = body(model, "            if !libraryDayAutoApplied, libraryMonth == Self.currentMeetingMonth() {", "            libraryError = nil")
need("libraryDay = Self.currentMeetingDay()" in load and "count > 0" not in load, "[today] Meetings opens on today, with or without meetings")
cal = body(meetings, "struct MeetingMonthCalendar: View {", "\n}\n")
need(".stroke(cell.date == today ? tint : Color.clear, lineWidth: 1.2)" in cal, "[today] today is ringed")
need(".disabled(count == 0 && cell.date != today)" in cal and '\\(cell.date == today ? ", today" : "")' in cal,
     "[today] an empty today can be picked, and VoiceOver says today")
need("today: ControllerModel.currentMeetingDay()" in meetings, "[today] the calendar is told today")
need("Text(MeetingTodayWords.emptyToday)" in meetings and "Button(MeetingTodayWords.jump(to: last, today: today)) {" in meetings
     and "if let last { model.selectLibraryDay(last) } else { model.shiftLibraryMonth(-1) }" in meetings,
     "[today] an empty today says so, with one tap to the latest earlier day or last month")

# Item 1: Back by path in the Activity window.
win = read("Sources/ActivityWindow.swift")
go = body(win, "    private func goBack() {", "\n    /// Open one archived day.")
need("if let step = backStep {\n            tookStep = true\n            backPath.removeLast()\n            returnTo(step.from)\n            return\n        }" in go
     and go.find("if let step = backStep {") < go.find("if section == .sessions, showingLinkedSession {"), "[back] Back goes back along the path first")
need("backMoving = true" in go and "if currentPlace == placeBefore { backMoving = false }" in go
     and "if section != sectionBefore, !tookStep { backPath = ActivityBackPath.settle(" in go
     and "            // Back's own move has landed (one change per move): the next change is a step again.\n            backMoving = false" in win,
     "[back] Back's own moves are not steps")
# Miles's pick B: the trail row.
crumb = body(win, "    @ViewBuilder private var breadcrumb: some View {", "\n    }\n")
need("let trail = backStep == nil ? [] : ActivityBackPath.trail(backPath, current: currentPlace, hasDetail: hasDetail)" in crumb
     and "if trail.isEmpty { locationCrumb } else { trailRow(trail) }" in crumb, "[trail] the trail shows only while Back goes along the path")
row = body(win, "    private func trailRow(_ trail: [ActivityPlace]) -> some View {", "\n    /// A place's word in the trail")
need("Button(word) { goBackAlongPath(to: index) }" in row and "if let index, index == trail.count - 1 {" in row
     and "ActivityBackPath.shortened(trail.count)" in row and ".lineLimit(1)" in row, "[trail] earlier places are links, this page last, one line")
along = body(win, "    private func goBackAlongPath(to index: Int) {", "\n    }\n")
need("backMoving = true" in along and "backPath = Array(backPath.prefix(index))" in along and "returnTo(place)" in along, "[trail] a link goes back to that place")
need(".onChange(of: currentPlace) { old, new in\n            let recorded = ActivityBackPath.record(backPath, old: old, new: new, goingBack: backMoving, pick: backPick)\n            backPath = recorded.path\n            backPick = recorded.pick" in win,
     "[back] every change of section is a step")
# A pick from the sidebar (the rail), the home's cards, Home and the shortcuts starts a fresh path.
pick = body(win, "    private func pickSection(_ item: ActivitySection?) {", "\n    }\n")
need("backPath = []" in pick and "backPick = currentPlace == target ? nil : target" in pick, "[back] a pick clears the path")
need(win.count("pickSection(item)") == 5 and win.count("pickSection(nil)") == 3, "[back] the rail, the home cards, Home and the shortcuts are picks")
need("!isolatedWorkPreview, !showingLinkedSession, !meetingReturnToWork, meetingReturnSpeakerSessionID == nil" in body(win, "    private var backStep: ActivityBackStep? {", "\n    }\n"),
     "[back] the Work preview, the linked session and the meeting returns keep their own Back")
# Speakers, a review, Open meeting, Back: the existing return, kept.
need("else if let sessionId = meetingReturnSpeakerSessionID { returnFromMeetingToSpeakers(sessionId) }" in go
     and "meetingReturnSpeakerSessionID = sessionId" in win, "[back] Speakers, a review, Open meeting, Back lands on the review")
need('Label("Back", systemImage: "chevron.left")' in win and ".help(backLabel)" in win
     and '.accessibilityLabel(backWord == nil ? "Back" : backLabel)' in win and win.count("ActivityBackPath.word(") == 1,
     "[back] Back says where it goes, from one place")
ret = body(win, "    private func returnTo(_ place: ActivityPlace) {", "\n    }\n")
need("model.openSpeakerReview(sessionId: id)" in ret and "model.openLibraryMeeting(row)" in ret and "model.openClaudeSession(row)" in ret
     and "selectedTurnID = id" in ret and "Task { await load(target) }" in ret, "[back] the item that was open comes back")

# Miles's pick A: sides in the message reader.
detail = body(win, "    private func messageDetail(_ turn: GlassesTurn) -> some View {", "\n    /// Offered on its own when the keyword answer")
need("side: .you, caption: MessageSides.youCaption(time: turn.timeLabel))" in detail and 'markdownID: "turn:" + turn.id, side: .cos)' in detail,
     "[sides] his words right, COS left, in the reader")
card = body(win, "struct ActivityMessageCard: View {", "\n    private var card: some View {")
need(".fill(DropInk.youBg)" in card and ".stroke(DropInk.youBorder, lineWidth: 1)" in card and "DropInk.youInk" in card
     and ".frame(maxWidth: .infinity, alignment: .trailing)" in card, "[sides] his words in the COS chat's own bubble, on the right")
need("DropItAvatar(size: 26)" in card and 'ActivityCopyMenu(label: "Copy answer"' in card, "[sides] COS by its mark, Copy answer kept")
need("var side: Side = .card" in card, "[sides] every other caller keeps the card")
if fails:
    print("\n".join("anand parity pin FAILED " + f for f in fails)); sys.exit(1)
print("anand parity pins: passed")
