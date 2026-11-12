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
need(".announcementRequested" in copy and "[.announcement: note," in copy, "[copy] VoiceOver hears what was copied")
need(views.count("MeetingCopyWords.label(MeetingCopyWords.summary, copied: model.copiedMeetingKind, fullChars: content.fullChars)") == 1
     and views.count("MeetingCopyWords.label(MeetingCopyWords.full, copied: model.copiedMeetingKind, fullChars: content.fullChars)") == 1
     and 'Label("Summary", systemImage' not in views, "[copy] the buttons use the web's words")
if fails:
    print("\n".join("anand parity pin FAILED " + f for f in fails)); sys.exit(1)
print("anand parity pins: passed")
