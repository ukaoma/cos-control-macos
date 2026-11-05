#!/usr/bin/env python3
"""0.5.366: mutation gate for renaming a live recording.

Runs the unmutated lanes first and refuses on any failure (a red baseline would "kill" every mutant). Then each mutant must
match its target EXACTLY ONCE, and is killed only when its lane fails with a named check ("... FAILED: ..." or
"... FAILED [...]"); a compile failure or any other exit is an infrastructure error, not a kill. Compiles go through the lane, so
through Tests/compile-guard.sh, one at a time, never in parallel. The wiring lane compiles the whole app (about 5 minutes each),
so it has few mutants.
Usage: python3 Tests/mutate-title-steer.py [--lane pins|models|wiring|helper] [--only M1,M2,P3]
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANE = ROOT / "Tests" / "run-title-steer.sh"
CORE = "Sources/MeetingAskCore.swift"
LIVE = "Sources/LiveTranscript.swift"
MODELS = "Sources/Models.swift"
MODEL = "Sources/ControllerModel.swift"
WINDOW = "Sources/ActivityWindow.swift"
MEETINGS = "Sources/ActivityMeetings.swift"
REC = "Sources/MacRecording.swift"
RECCORE = "Sources/MacRecordingCore.swift"
HELPER = "HelperSources/main.swift"

MUTANTS = [
    # The rules and the store (Tests/TitleSteerChecks.swift).
    ("M1 the count is Characters", "models", CORE, "static func count(_ raw: String) -> Int { clean(raw).unicodeScalars.count }", "static func count(_ raw: String) -> Int { clean(raw).count }"),
    ("M2 120 is over", "models", CORE, "static func overLimit(_ raw: String) -> Bool { count(raw) > maxScalars }", "static func overLimit(_ raw: String) -> Bool { count(raw) >= maxScalars }"),
    ("M3 the cap is 121", "models", CORE, "    static let maxScalars = 120\n", "    static let maxScalars = 121\n"),
    ("M4 zero-width marks stay", "models", LIVE, "case 0x200b...0x200f, 0x202a...0x202e, 0x2060...0x2069, 0xfeff: continue", "case 0x202a...0x202e, 0x2060...0x2069, 0xfeff: continue"),
    ("M5 control characters vanish instead of spacing", "models", LIVE, 'case 0x00...0x1f, 0x7f...0x9f: scalars.append(" ")', "case 0x00...0x1f, 0x7f...0x9f: continue"),
    ("M6 no NFKC", "models", LIVE, "raw.precomposedStringWithCompatibilityMapping.unicodeScalars", "raw.unicodeScalars"),
    ("M7 whitespace is not collapsed", "models", LIVE, "return String(scalars).split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: \" \")\n    }\n\n    /// 0.5.366: the switcher",
     "return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)\n    }\n\n    /// 0.5.366: the switcher"),
    ("M8 Rename shows without the capability", "models", CORE, "guard capable, hasFeed, validSession(sessionId)", "guard hasFeed, validSession(sessionId)"),
    ("M9 an iPhone recording is renamed", "models", CORE, ", validSession(sessionId), !PhoneMeetingCapture.protected(sessionId) else", ", validSession(sessionId) else"),
    ("M10 an ended recording is not locked", "models", CORE, "return ended || saving ? .locked : .open", "return saving ? .locked : .open"),
    ("M11 a save in progress is not locked", "models", CORE, "return ended || saving ? .locked : .open", "return ended ? .locked : .open"),
    ("M12 the untouched automatic title is set", "models", CORE, "        if current == nil, text == clean(shown) { return .none }\n", ""),
    ("M13 the unchanged steer is sent again", "models", CORE, "        if text == current { return .none }\n", ""),
    ("M14 an emptied field with no steer sends a clear", "models", CORE, "if text.isEmpty { return current == nil ? .none : .clear }", "if text.isEmpty { return .clear }"),
    ("M15 the field ignores the steer", "models", CORE, "        if let steer = steer.map(clean), !steer.isEmpty { return steer }\n        return clean(shown)", "        return clean(shown)"),
    ("M16 the header ignores the steer", "models", CORE, "        if let steer = steer.map(clean), !steer.isEmpty { return steer }\n        return otherwise", "        return otherwise"),
    ("M17 the title goes in the arguments", "models", CORE, '"--title-stdin"], data)', '"--title-stdin", title], data)'),
    ("M18 the revision is not sent", "models", CORE, 'String(expectedRevision), "--title-stdin"', '"0", "--title-stdin"'),
    ("M19 a one-character session makes a call", "models", CORE, "[A-Za-z0-9:_-]{3,96}", "[A-Za-z0-9:_-]{1,96}"),
    ("M20 a negative revision makes a call", "models", CORE, "expectedRevision >= 0, let data", "let data"),
    ("M21 title_changed is a failure", "models", CORE, 'case "title_changed": return .changed(snapshot(details["current"]?.object))', 'case "title_changed": return .failed'),
    ("M22 save_in_progress is a failure", "models", CORE, 'case "save_in_progress": return .saving', 'case "save_in_progress": return .failed'),
    ("M23 any 404 is an ended recording", "models", CORE, 'case 404: return code == "session_not_live" ? .ended : .failed', "case 404: return .ended"),
    ("M24 an answer needs no transport", "models", CORE, 'guard let details, details["transport"]?.string == "answered", let status = details["httpStatus"]?.int else { return .failed }',
     'guard let details, let status = details["httpStatus"]?.int else { return .failed }'),
    ("M25 a negative revision is a view", "models", CORE, 'guard let details, let revision = details["revision"]?.int, revision >= 0 else { return nil }', 'guard let details, let revision = details["revision"]?.int else { return nil }'),
    ("M26 a title from the server is not cut", "models", CORE, "case .some(.string(let text)): let title = capped(text);", "case .some(.string(let text)): let title = clean(text);"),
    ("M27 a save has a line", "models", CORE, "        case .saved: nil\n", "        case .saved: failedLine\n"),
    ("M28 the feed never takes the steer", "models", LIVE, "        if steer != titleSteer { titleSteer = steer; changed = true }\n", ""),
    ("M29 the feed takes the steer as it came", "models", LIVE, "let steer = read.titleSteer.map(LiveTranscript.cleanTitle).flatMap { $0.isEmpty ? nil : $0 }", "let steer = read.titleSteer"),
    ("M30 a full read without a steer keeps the old one", "models", LIVE, "flatMap { $0.isEmpty ? nil : $0 }\n        if steer != titleSteer", "flatMap { $0.isEmpty ? nil : $0 } ?? titleSteer\n        if steer != titleSteer"),
    ("M31 the switcher ignores the steer", "models", LIVE, "        if let steer = steer.map(cleanTitle), !steer.isEmpty { return steer }\n        return sourceLabel(", "        return sourceLabel("),
    ("M32 the source line never carries the start", "models", LIVE, '(mac ? "Recording on this Mac" : "Recording on the glasses") + (started.map { " · started " + $0 } ?? "")', '(mac ? "Recording on this Mac" : "Recording on the glasses")'),
    ("M33 any value opens the capability", "models", MODELS, 'titleSteer: details["meetingTitleSteer"]?.bool == true)', 'titleSteer: details["meetingTitleSteer"] != nil)'),
    ("M34 a second Save goes out while one is out", "models", CORE, "guard let session = editing, !busy, let started = basis,", "guard let session = editing, let started = basis,"),
    ("M35 over the cap is sent", "models", CORE, ", started.session == session, !TitleSteer.overLimit(draft) else { return }", ", started.session == session else { return }"),
    ("M36 a 409 with our own name is a conflict line", "models", CORE, "if let current, current.title == (text.isEmpty ? nil : text) { close() } else {", "if false { close() } else {"),
    ("M54 any 409 is a save", "models", CORE, "if let current, current.title == (text.isEmpty ? nil : text) { close() } else {", "if true { close() } else {"),
    ("M55 a field left while a rename is out stays open", "models", CORE, "defer { busy = false; if fieldGone, editing != nil { close() } }", "defer { busy = false }"),
    ("M56 Escape is taken with no field on screen", "models", CORE, "guard editing != nil, !fieldGone else { return false }", "guard editing != nil else { return false }"),
    ("M57 a field leaving does not close", "models", CORE, "        if editing != nil, !busy { close(); messageToken += 1; message = nil; messageSession = nil }\n", ""),
    ("M58 begin leaves the pane marked gone", "models", CORE, "        fieldGone = false\n        editing = session\n", "        editing = session\n"),
    ("M37 the write names revision 0", "models", CORE, "expectedRevision: snapshot.revision)", "expectedRevision: 0)"),
    ("M38 busy never clears", "models", CORE, "        busy = true\n        // A field the pane no longer shows (it was left while this was out) must not stay open: nothing could close it.\n        defer { busy = false; if fieldGone, editing != nil { close() } }\n", "        busy = true\n"),
    ("M39 Cancel works while a rename is out", "models", CORE, "        guard !busy else { return }\n        close()\n        messageToken += 1", "        close()\n        messageToken += 1"),
    ("M40 Escape is always taken", "models", CORE, "guard editing != nil, !fieldGone else { return false }\n        cancel()", "cancel()"),
    ("M41 begin works while a rename is out", "models", CORE, "guard !busy, TitleSteer.validSession(session) else { return }", "guard TitleSteer.validSession(session) else { return }"),
    ("M42 moving to another recording keeps the field", "models", CORE, "        if editing != nil, editing != session { cancel() }\n", ""),
    ("M43 a line never goes", "models", CORE, "guard let self, self.messageToken == token else { return }", "guard let self, self.messageToken == -1 else { return }"),
    ("M44 an older line's timer clears a newer line", "models", CORE, "guard let self, self.messageToken == token else { return }", "guard let self else { return }"),
    ("M45 begin keeps the last line", "models", CORE, "        messageToken += 1; message = nil; messageSession = nil\n        fieldGone = false\n", "        fieldGone = false\n"),
    ("M46 save_in_progress closes the field", "models", CORE, "        case .saving: show(TitleSteer.savingLine, session: session)\n", "        case .saving: show(TitleSteer.savingLine, session: session); close()\n"),
    ("M47 a failure closes the field", "models", CORE, "        case .failed: show(TitleSteer.failedLine, session: session)\n", "        case .failed: show(TitleSteer.failedLine, session: session); close()\n"),
    ("M48 unchanged text leaves the field open", "models", CORE, "        case .none: close(); return\n", "        case .none: return\n"),
    ("M49 no second read when the first failed", "models", CORE, "        if snapshot == nil { snapshot = await read(session, run: run) }\n", ""),
    ("M50 Save does not wait for the read in flight", "models", CORE, "        if snapshot == nil { await reading?.value; snapshot = basis?.snapshot }\n", ""),
    ("M51 a saved rename is not applied", "models", CORE, "        case .saved(let now): apply(session, now.title); close()\n", "        case .saved: close()\n"),
    ("M52 a 409's current title is not adopted", "models", CORE, "            if let current { apply(session, current.title) }\n", ""),
    ("M53 the field opens empty", "models", CORE, "        initialDraft = TitleSteer.prefill(steer: current, shown: shown)\n", '        initialDraft = ""\n'),
    # The model and the pane with the whole app compiled (Tests/TitleSteerRender.swift check).
    ("W1 the header's title ignores the steer", "wiring", MODEL, "        if let steer = liveTranscriptFeeds[sessionId]?.titleSteer, !steer.isEmpty { return steer }\n", ""),
    ("W2 availability ignores the capability", "wiring", MODEL, "capable: liveMeetingCapability.titleSteer,", "capable: true,"),
    ("W3 a Mac save never sees the steer", "wiring", MODEL, "macRecording.steerTitle = { [weak self] id in self?.liveTranscriptFeeds[id]?.titleSteer }", "macRecording.steerTitle = { _ in nil }"),
    ("W4 the answer is not written into the feed", "wiring", MODEL, "self?.liveTranscriptFeeds[id]?.titleSteer = title }", "_ = title }"),
    ("W5 a Mac save ignores the steer", "wiring", RECCORE, "!steer.isEmpty else { return recording }\n        return steer", "!steer.isEmpty else { return recording }\n        return recording"),
    ("W6 begin does not re-check availability", "wiring", MODEL, "        guard titleSteerAvailability(sessionId) == .open else { return }\n", ""),
    ("W7 a late Save is written after the recording stopped", "wiring", MODEL, "guard let id = session ?? titleSteer.editing, titleSteerAvailability(id) == .open else { titleSteer.cancel(); return }", "guard let id = session ?? titleSteer.editing else { return }"),
    # Source pins (Tests/title-steer-pins.py).
    ("P1 the window never asks the title store", "pins", WINDOW, "        if model.titleSteer.escape() { return true }\n", ""),
    ("P2 Rename stays enabled while locked", "pins", MEETINGS, ".disabled(rename != .open || steerStore.busy)", ".disabled(steerStore.busy)"),
    ("P3 Return saves over the limit", "pins", MEETINGS, ".onSubmit { if !over, open { save(draft) } }", ".onSubmit { if open { save(draft) } }"),
    ("P4 the Mac save sends the recording's title", "pins", REC, "MacRecordingNotice.saveTitle(recording: current.title, steer: self.steerTitle?(id))", "current.title"),
    ("P5 the Mac stop is not checked for Rename", "pins", MODEL, "macRecording.manifest?.captureId == sessionId && !macRecording.isRecording", "false"),
    ("P6 the kept calendar title comes before the steer", "pins", MODEL,
     "        if let steer = liveTranscriptFeeds[sessionId]?.titleSteer, !steer.isEmpty { return steer }\n        // 0.5.337 (loop audit N10): a calendar title, once taken, stays for that meeting. The next event changes when this\n        // one passes, so the title could flip mid-meeting.\n        if let kept = liveMeetingTitlesKept[sessionId] { return kept }\n",
     "        // 0.5.337 (loop audit N10): a calendar title, once taken, stays for that meeting. The next event changes when this\n        // one passes, so the title could flip mid-meeting.\n        if let kept = liveMeetingTitlesKept[sessionId] { return kept }\n        if let steer = liveTranscriptFeeds[sessionId]?.titleSteer, !steer.isEmpty { return steer }\n"),
    ("P7 the field does not wait while a rename is out", "pins", MEETINGS, "                .disabled(store.busy)\n                .onSubmit", "                .onSubmit"),
    ("P8 the helper runs an iPhone rename", "pins", HELPER, '        guard !session.hasPrefix("phone_") else { throw HelperError.message("iPhone microphone recordings are not renamed here.") }\n', ""),
    ("P9 the title is read from argv", "pins", HELPER, "Self.meetingTitleSteerStdin(try readBoundedStdin(4_096))", "option(\"--title\", in: args)"),
    ("P10 the capability is read from a boolean", "pins", HELPER, "guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }", "guard let number = value as? NSNumber else { return false }"),
    ("P11 the pane keeps no observed store", "pins", MEETINGS, "    @ObservedObject private var steerStore: TitleSteerStore\n", "    private var steerStore: TitleSteerStore { model.titleSteer }\n"),
    ("P12 the version is 0.5.365 again", "pins", "Resources/Info.plist", "<string>0.5.369</string>", "<string>0.5.365</string>"),
    ("P13 Return saves once the recording has stopped", "pins", MEETINGS, ".onSubmit { if !over, open { save(draft) } }", ".onSubmit { if !over { save(draft) } }"),
    ("P14 Save stays on once the recording has stopped", "pins", MEETINGS, ".disabled(over || store.busy || !open)", ".disabled(over || store.busy)"),
    ("P15 the field stays open once the recording stops", "pins", MEETINGS, "        .onChange(of: open) { _, now in if !now { store.cancel() } }\n", ""),
    ("P16 the field does not take focus back", "pins", MEETINGS, "        .onChange(of: store.busy) { _, busy in if !busy { focused = true } }\n", ""),
    ("P17 the field never says it is on screen", "pins", MEETINGS, "        .onAppear { store.fieldAppeared() }\n", ""),
    ("P18 a late Save is not re-checked", "pins", MODEL, "guard let id = session ?? titleSteer.editing, titleSteerAvailability(id) == .open else { titleSteer.cancel(); return }", "guard let id = session ?? titleSteer.editing else { return }"),
    # The helper (its self-test and Tests/title-steer-helper-checks.py).
    ("H1 a write over 120 code points goes", "helper", HELPER, "        guard cleaned.unicodeScalars.count <= Self.meetingTitleSteerMax else { return nil }\n", ""),
    ("H2 a file steer is cut at 240", "helper", HELPER, "titleSteerClean(raw).unicodeScalars.prefix(Self.meetingTitleSteerMax)", "titleSteerClean(raw).unicodeScalars.prefix(Self.meetingTitleSteerMax * 2)"),
    ("H3 any server code crosses", "helper", HELPER, "guard let code = Self.liveCueErrorCode(body), Self.meetingTitleSteerCodes.contains(code) else { return out }", "guard let code = Self.liveCueErrorCode(body) else { return out }"),
    ("H4 a current view crosses on any 409", "helper", HELPER, 'if status == 409, code == "title_changed", let current', "if status == 409, let current"),
    ("H5 any number advertises", "helper", HELPER, "        return number.intValue == 1\n", "        return number.intValue >= 1\n"),
    ("H6 a write is a POST", "helper", HELPER, 'request(Self.meetingTitleSteerRoute, method: "PUT"', 'request(Self.meetingTitleSteerRoute, method: "POST"'),
    ("H7 a live read drops the file's steer", "helper", HELPER, '        if let steer = titleSteerText(object["titleSteer"]) { read["titleSteer"] = steer }\n', ""),
    ("H8 a null title is lost", "helper", HELPER, '        if raw["title"] is NSNull { out["title"] = NSNull() }\n        else if', "        if let title = raw[\"title\"] as? String, title.isEmpty { out[\"title\"] = NSNull() }\n        else if"),
    ("H9 zero-width marks stay in the helper's clean", "helper", HELPER, "            case 0x200b...0x200f, 0x202a...0x202e, 0x2060...0x2069, 0xfeff: continue\n", ""),
]


def run(lane):
    env = dict(os.environ, COS_TITLE_STEER_LANE=lane)
    return subprocess.run(["zsh", str(LANE)], cwd=ROOT, env=env, capture_output=True, text=True)


only = sys.argv[sys.argv.index("--lane") + 1] if "--lane" in sys.argv else None
lanes = [lane for lane in ("pins", "models", "wiring", "helper") if only in (None, lane)]
mutants = [m for m in MUTANTS if m[1] in lanes]
if "--only" in sys.argv:
    wanted = sys.argv[sys.argv.index("--only") + 1].split(",")
    mutants = [m for m in mutants if m[0].split(" ")[0] in wanted]
    lanes = [lane for lane in lanes if any(m[1] == lane for m in mutants)]
for lane in lanes:
    base = run(lane)
    if base.returncode != 0:
        print(f"BASELINE RED ({lane}):\n{base.stdout}{base.stderr}")
        sys.exit(2)
print("baseline green: " + ", ".join(lanes), flush=True)

survivors = infra = 0
for name, lane, rel, old, new in mutants:
    path = ROOT / rel
    src = path.read_text()
    count = src.count(old)
    if count != 1:
        print(f"{name}: NOT APPLIED (target found {count} times)", flush=True)
        infra += 1
        continue
    path.write_text(src.replace(old, new))
    try:
        r = run(lane)
        out = r.stdout + r.stderr
        failed_line = next((l for l in out.splitlines() if "FAILED:" in l or "FAILED [" in l or "Precondition failed" in l), None)
        if r.returncode != 0 and failed_line:
            print(f"{name}: killed by {failed_line.strip()[:220]}", flush=True)
        elif r.returncode != 0:
            print(f"{name}: INFRASTRUCTURE (exit {r.returncode}, no named check)\n{out[-600:]}", flush=True)
            infra += 1
        else:
            print(f"{name}: SURVIVED", flush=True)
            survivors += 1
    finally:
        path.write_text(src)
print(f"title steer mutants: {len(mutants) - survivors - infra} killed, {survivors} survived, {infra} infrastructure")
sys.exit(1 if survivors or infra else 0)
