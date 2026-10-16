#!/usr/bin/env python3
"""0.5.313 mutation gate for the meeting detection rules (Sources/MacRecordingCore.swift + Tests/MacRecordingChecks.swift).

SERIAL by design: one small two-file compile at a time, each through Tests/compile-guard.sh (never parallel; see the
2026-10-07 kernel panics). Works on a scratch copy, so the checkout is never mutated. A GREEN baseline is required
before the first mutant. Each mutant must replace its target exactly once and must make the checks FAIL.

Usage: python3 Tests/mutate-meeting-detect.py <repo root>
"""
import pathlib, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]).resolve()
CORE = "Sources/MacRecordingCore.swift"
CHECKS = "Tests/MacRecordingChecks.swift"
MUTANTS = [
    # The state machine.
    ("suggests before 10 s", "now.timeIntervalSince(since) >= Self.holdSeconds", "now.timeIntervalSince(since) >= 0"),
    ("hold threshold changed", "    static let holdSeconds: TimeInterval = 10", "    static let holdSeconds: TimeInterval = 5"),
    ("a short release ends the meeting", "now.timeIntervalSince(released) >= Self.releaseSeconds", "now.timeIntervalSince(released) >= 0"),
    ("hold need not be continuous", "t.holding = true; t.heldSince = now; t.releasedAt = nil", "t.holding = true; t.heldSince = t.heldSince ?? now; t.releasedAt = nil"),
    ("offered more than once per meeting", "                    t.handled = true\n                    events.append(.suggest(source))", "                    events.append(.suggest(source))"),
    ("suggests during a recording", " || context.recordingBusy {", " {"),
    ("suggests while dictating", "                } else if !context.dictating, !context.cardShowing {", "                } else if !context.cardShowing {"),
    ("two cards at once", "                } else if !context.dictating, !context.cardShowing {", "                } else if !context.dictating {"),
    ("setting ignored", "                if !context.suggestEnabled || !context.allowed", "                if !context.allowed"),
    ("per-app toggle ignored", " || !context.allowed.contains(source.app)", ""),
    ("ticks forever", "    var wantsTicks: Bool { tracks.values.contains { $0.holding || $0.inMeeting } }", "    var wantsTicks: Bool { true }"),
    # Detection.
    ("browser counted without a Meet title", "                case false?: break", "                case false?: sources.insert(rule.source)"),
    ("browser counted without Accessibility", "                case nil: unchecked = true", "                case nil: unchecked = true; sources.insert(rule.source)"),
    ("microphone not required", "for process in processes where process.input && process.pid != ownPID {", "for process in processes where process.pid != ownPID {"),
    ("COS's own process counted", "for process in processes where process.input && process.pid != ownPID {", "for process in processes where process.input {"),
    ("Never list ignored", ", !never.contains(rule.owner) else { continue }", " else { continue }"),
    ("Meeting notes is a Meet", '|| title.range(of: #"(^|[^A-Za-z])Meet($|[^A-Za-z])"#, options: .regularExpression) != nil', '|| title.contains("Meet")'),
    ("prefix matches part of a name", '(id == prefix || id.hasPrefix(prefix + "."))', "id.hasPrefix(prefix)"),
    ("Zoom helper not mapped", '"us.zoom.xos", "us.zoom.CptHost", "us.zoom."]', '"us.zoom.xos"]'),
    # Words, title, end offer, busy.
    ("end offer for another recording", "        return startedCaptureID == runningCaptureID", "        return true"),
    ("end offer for another meeting", "guard let startedFrom, startedFrom == ended, let startedCaptureID", "guard let startedFrom, let startedCaptureID"),
    ("busy ignores live recordings", " || liveRecordings > 0", ""),
    ("busy ignores pending", "macOccupied || !macCanStart ||", "macOccupied ||"),
    ("fold-away changed", "    static let dismissSeconds: TimeInterval = 60", "    static let dismissSeconds: TimeInterval = 600"),
    ("title clock changed", 'f.dateFormat = "h:mm a"\n        return (meetingApp', 'f.dateFormat = "HH:mm"\n        return (meetingApp'),
    # The one-time notice (0.5.313, Miles 22:39).
    ("notice every time", "    static func step(acknowledged: Bool) -> Step { acknowledged ? .start : .notice }", "    static func step(acknowledged: Bool) -> Step { .notice }"),
    ("never a notice on first use", "    static func step(acknowledged: Bool) -> Step { acknowledged ? .start : .notice }", "    static func step(acknowledged: Bool) -> Step { .start }"),
    ("permission footnote always shown", "    static func footnote(permissionGranted: Bool) -> String? { permissionGranted ? nil : permissionFootnote }",
     "    static func footnote(permissionGranted: Bool) -> String? { permissionFootnote }"),
    ("typed title ignored", "        return trimmed.isEmpty ? autoTitle(meetingApp: meetingApp, at: date, calendar: calendar) : String(trimmed.prefix(160))",
     "        return autoTitle(meetingApp: meetingApp, at: date, calendar: calendar)"),
    ("detected app not in the title", '(meetingApp.map { $0 + " meeting" } ?? "Mac recording")', '"Mac recording"'),
    ("card asks no consent", '"Record on Mac with live transcript? Let people know you\'re recording."', '"Record on Mac with live transcript?"'),
]



def compile_and_run(work: pathlib.Path) -> int:
    out = work / "checks"
    if out.exists():
        out.unlink()
    build = subprocess.run(["/bin/zsh", str(root / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0",
                            "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
                            str(work / CORE), str(work / CHECKS), "-o", str(out)],
                           capture_output=True, text=True)
    if build.returncode != 0:
        return 2
    return subprocess.run([str(out)], capture_output=True, text=True).returncode


work = pathlib.Path(tempfile.mkdtemp(prefix="cos-meeting-mutants-", dir="/private/tmp"))
try:
    (work / "Sources").mkdir(); (work / "Tests").mkdir()
    shutil.copy(root / CORE, work / CORE)
    shutil.copy(root / CHECKS, work / CHECKS)
    original = (work / CORE).read_text()
    if compile_and_run(work) != 0:
        sys.exit("baseline is not green: fix the checks before reading any mutant")
    survivors = []
    for name, old, new in MUTANTS:
        if original.count(old) != 1:
            sys.exit(f"mutant '{name}' targets {original.count(old)} sites; it must land exactly once")
        (work / CORE).write_text(original.replace(old, new))
        code = compile_and_run(work)
        verdict = "KILLED (did not compile)" if code == 2 else ("KILLED" if code != 0 else "SURVIVED")
        print(f"{verdict:24} {name}")
        if code == 0:
            survivors.append(name)
        (work / CORE).write_text(original)
    if survivors:
        sys.exit(f"{len(survivors)} survivor(s): {survivors}")
    print(f"PASS meeting detection mutation gate: {len(MUTANTS)} mutants, all killed, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
