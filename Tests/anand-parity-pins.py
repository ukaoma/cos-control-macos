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
need(".stroke(cell.date == today ? tint : Color.clear, lineWidth: 1.5)" in cal and "selectedDay == cell.date || cell.date == today ? .semibold" in cal,
     "[today] today is ringed")
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
     and "if trail.isEmpty { locationCrumb } else {" in crumb, "[trail] the trail shows only while Back goes along the path")
need("ViewThatFits(in: .horizontal) {\n                trailRow(trail, room: trail.count)\n                trailRow(trail, room: 12)" in crumb,
     "[trail] one line: steps leave from the middle as it narrows")
row = body(win, "    private func trailRow(_ trail: [ActivityPlace], room: Int) -> some View {", "\n    /// A place's word in the trail")
need("Button(word) { goBackAlongPath(to: index) }" in row and "if let index, index == trail.count - 1 {" in row
     and "ActivityBackPath.shortened(trail.count, room: room)" in row and ".lineLimit(1)" in row and ".fixedSize()" in row,
     "[trail] earlier places are links, this page last, one line")
need(".accessibilityValue(trail.map(trailWord).joined(separator: \", \"))" in row, "[trail] left-out steps stay readable by VoiceOver")
words = body(win, "    private func trailWord(_ place: ActivityPlace) -> String {", "\n    }\n")
need('return "Naming voices"' in words and 'return "Meeting"' in words and 'return "Session"' in words and '"Message #\\($0)"' in words
     and "detailTitle" not in words,
     "[trail] steps named by kind, as the web, this page too")
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
     and '.accessibilityLabel(backLabel)' in win and win.count("ActivityBackPath.word(") == 1,
     "[back] Back says where it goes, from one place")
ret = body(win, "    private func returnTo(_ place: ActivityPlace) {", "\n    }\n")
need("model.openSpeakerReview(sessionId: id)" in ret and "model.openLibraryMeeting(row)" in ret and "model.openClaudeSession(row)" in ret
     and "selectedTurnID = id" in ret and "Task { await load(target) }" in ret, "[back] the item that was open comes back")

# Miles's pick A: sides in the message reader.
detail = body(win, "    private func messageDetail(_ turn: GlassesTurn) -> some View {", "\n    /// Offered on its own when the keyword answer")
need("side: .you, caption: MessageSides.youCaption)" in detail and 'markdownID: "turn:" + turn.id, side: .cos)' in detail,
     "[sides] his words right, COS left, in the reader")
card = body(win, "struct ActivityMessageCard: View {", "\n    private var card: some View {")
need(".fill(DropInk.youBg)" in card and ".stroke(DropInk.youEdgeReader, lineWidth: 1)" in card and "DropInk.youInk" in card
     and ".frame(maxWidth: .infinity, alignment: .trailing)" in card, "[sides] his words in the COS chat's own bubble, on the right")
need("DropItAvatar(size: 30)" in card and ".accessibilityLabel(MessageSides.youSaid + \": \" + text)" in card
     and ".accessibilityLabel(MessageSides.cosSaid)" in card and ".accessibilityHidden(caption == MessageSides.youCaption)" in card and 'ActivityCopyMenu(label: "Copy answer"' in card, "[sides] COS by its mark, Copy answer kept")
need("var side: Side = .card" in card, "[sides] every other caller keeps the card")
# The reader's bubble edge reaches 3 to 1 in light (0xab8436 on the page 0xf5f0e6 is 3.04), dark unchanged; the COS chat keeps
# its own edge. And this Mac's replies sit on the same sides.
dropit = read("Sources/DropItViews.swift")
need("static let youEdgeReader = pair(0xa27937, 0x6e5937)" in dropit and "static let youBorder = pair(0xe3cfa6, 0x56422c)" in dropit,
     "[sides] the reader's bubble edge is 3 to 1 in light, dark unchanged, the chat's own edge kept")
replyview = read("Sources/MessageReplyView.swift")
row = body(replyview, "    private func replyRow(_ reply: DropIt.Ask) -> some View {", "\n    static func stateWord(")
need("ActivityMessageCard(label: \"You\", text: reply.words, tint: ActivitySection.messages.tint, side: .you," in row
     and "DropItAvatar(size: 30)" in row, "[sides] this Mac's replies sit on the same sides")
# Q1 FIX 2 and 3 (2026-11-12): an untracked detail marks the place; Back's label names the parent without a jump; the trail
# drops one step at a time; archive chats draw the sides; a pick that moved nothing leaves no pick.
need("        place.detail = hasDetail && place.item == nil" in win, "[back] an untracked detail marks the place")
need('if hasDetail, let section { return "Back to " + section.title }' in win and 'if section != nil { return "Back to " + home }' in win
     and ".accessibilityLabel(backLabel)" in win, "[back] Back names its parent without a jump")
need("                trailRow(trail, room: 12)\n                trailRow(trail, room: 11)" in win and "                trailRow(trail, room: 5)\n                trailRow(trail, room: 4)" in win,
     "[trail] one step leaves at a time")
need("        if let day = place.archiveDate { return day }" in win, "[trail] a day by its raw date, as the web")
chats = body(win, "@ViewBuilder private func archiveChatDetail(", "\n    private func ")
need("side: .you, caption: MessageSides.youCaption)" in chats and "side: .cos)" in chats, "[sides] archive chats too")
need("        if currentPlace == before { backPick = nil }" in pick, "[back] a pick that moved nothing leaves no pick")
need("                Text(caption).font(COSType.body(12)).foregroundStyle(DropInk.tertiary).padding(.trailing, 4)" in card,
     "[sides] the caption at 12, as the web")
if fails:
    print("\n".join("anand parity pin FAILED " + f for f in fails)); sys.exit(1)
print("anand parity pins: passed")
