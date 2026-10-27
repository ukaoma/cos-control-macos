#!/usr/bin/env python3
"""0.5.340 (server 6.90.0) Mac recording voices: where the Voice N rules are wired.

The rules themselves run in ModelsContract (MacVoiceLabel, MacVoiceCopy, the review's count) and ActivityTodayChecks
(Today's count). These pins read CODE ONLY (comment lines never count) at the call sites the views and the model use,
and the self-test proves each pin fails when its line is broken. Usage: mac-voice-pins.py <repo root> [--selftest]
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else '.')

# (file, exact code line fragment, why). Each must appear exactly once in code.
PINS = [
    ('Sources/ActivityMeetings.swift',
     'let macVoices = MacVoiceLabel.isMacSession(row.sessionId) ? MacVoiceLabel.voices(inTranscript: detail.transcript) : []',
     'Rename voice lists the Voice turns of a saved Mac recording only'),
    ('Sources/ActivityMeetings.swift', 'if let onRenameVoice, !macVoices.isEmpty {',
     'Rename voice shows only when the meeting has a Voice turn'),
    ('Sources/ActivityMeetings.swift', 'Button(MacVoiceCopy.menuItem(label)) { onRenameVoice(row.sessionId, row.recordId, label) }',
     'each item names that voice in that meeting'),
    ('Sources/ActivityWindow.swift',
     'onRenameVoice: { session, record, label in openVoiceReviewFromLibrary(session, record, nameVoice: label) },',
     'the saved meeting pane is given Rename voice'),
    ('Sources/ActivityWindow.swift', 'model.openSpeakerReview(sessionId: sessionId, recordId: recordId, nameVoice: nameVoice)',
     'the review opens with the picked voice'),
    ('Sources/ControllerModel.swift',
     "if let wanted = pendingNameVoice, review.voices.contains(where: { $0.label == wanted && $0.canRename }) { namingVoice = wanted }",
     'the picked voice opens on naming once its review loads'),
    ('Sources/ControllerModel.swift', 'let scope: CorrectionScope = review.isMacRecording ? .thisMeeting : scope',
     'a Mac recording renames in this meeting only, never the global profile fold'),
    ('Sources/ControllerModel.swift',
     'let createsProfile = !review.isMacRecording && !voiceProfiles.contains { $0.name.caseInsensitiveCompare(to) == .orderedSame }',
     'the confirm card never says a Mac rename makes a profile'),
    ('Sources/ControllerModel.swift', 'unattributedVoices: review.unnamedVoiceCount',
     "the Speakers visit records Voice N voices, never Ext as one more"),
    ('Sources/ControllerModel.swift', 'let reason = MacVoiceCopy.appliedNoteForSkip(skipped)',
     'the notice after a Mac rename says only what the server reported'),
    ('Sources/Views.swift', 'if model.openReview?.isMacRecording == true {',
     'the naming row shows the text-only note instead of the scope switch'),
    # 0.5.351 (server 6.93.0): a Mac voice assigned to an existing voice profile.
    ('Sources/Views.swift', 'assignVoiceProfile: model.openReview?.isMacRecording == true && MacVoiceLabel.isVoice(voice.label))',
     'picking an existing person for an unnamed Voice N asks the server to add its audio to that profile; no other row asks'),
    ('Sources/Views.swift', '.filter { $0.name.lowercased().contains(q) && $0.name != voice.label && !(mac && $0.isOwner) }',
     "the wearer's own profile is never offered as the person for a Mac voice"),
    ('Sources/Views.swift', 'Text(MacVoiceCopy.renameNote(forLabel: voice.label))',
     'the picker note promises voice samples only for an unnamed Voice N'),
    ('Sources/Views.swift', 'if correction.needsForceToAddSamples {',
     'a flagged assignment replaces Save with Rename only and a separate Add anyway'),
    ('Sources/Views.swift', 'Button(MacVoiceCopy.addAnywayTitle) { model.armAddAnyway() }',
     'Add anyway only arms the forced assignment'),
    ('Sources/Views.swift', 'Button(MacVoiceCopy.addAnywayConfirmTitle) { model.confirmCorrection(correction, addAnyway: true) }',
     'the forced assignment is sent only by the second, confirming press'),
    ('Sources/Views.swift', 'if correction.savesWithSamples {',
     'an unflagged assignment also offers Rename only'),
    ('Sources/Views.swift', 'ForEach(correction.assignLines, id: \\.self) { line in',
     'the confirm card shows the voice samples the server would add'),
    ('Sources/Views.swift', 'Text(MacVoiceCopy.typedNote)',
     'a typed Mac name says it adds no voice sample'),
    ('Sources/Views.swift', 'Text(model.openReview?.isMacRecording == true ? "text only" : "new name")',
     'a typed new name on a Mac recording says text only'),
    ('Sources/ControllerModel.swift', 'let assigned = assignVoiceProfile && review.isMacRecording && MacVoiceLabel.isVoice(from) ? voiceProfiles.first { $0.name == to && !$0.isOwner }?.name : nil',
     'only an enrolled non-wearer person, by exact name, on a Mac recording, for an unnamed Voice N, can receive a Mac voice'),
    ('Sources/ControllerModel.swift', '+ reviewRevisionArgs(review) + (assigned != nil ? ["--assign-voice-profile"] : [])',
     'the preview asks the server what assigning would add'),
    ('Sources/ControllerModel.swift', 'assignRequested: assigned != nil',
     'the preview card is told an assignment was asked for'),
    ('Sources/ControllerModel.swift', 'guard let assignFlags = MacAssignRequest.flags(for: correction, renameOnly: renameOnly, addAnyway: addAnyway, armed: forceAssignArmed) else { return }',
     'a flagged assignment is never sent by a plain Save'),
    ('Sources/ControllerModel.swift', 'args += assignFlags',
     'the confirm sends the assignment flags only as the rules decided'),
    ('Sources/ControllerModel.swift', 'if let gate = response.details["reason"]?.string, MacAssignRequest.gateReasons.contains(gate),',
     'a gate the server raises at confirm puts the measured numbers back on the card'),
    ('HelperSources/main.swift', 'let notApplicable = response.status == 400 && ["not_a_voice_label", "not_mac_capture"].contains((body["reason"] as? String) ?? "")',
     'a 400 that says the assignment does not apply is a decline, not "needs a newer server"'),
    ('HelperSources/main.swift', 'if args.contains("--assign-voice-profile") { payload["assignVoiceProfile"] = true }',
     'the helper sends assignVoiceProfile to the relabel route'),
    ('HelperSources/main.swift', 'let unknownProfile = response.status == 404 && (response.body?["reason"] as? String) == "unknown_profile"',
     'a 404 for an unenrolled name is a decline, not a missing route'),
    ('Sources/Views.swift', 'Text(review.isMacRecording ? MacVoiceCopy.unattributedNote',
     'a Mac review explains why nobody is named instead of blaming recovered audio'),
    # 0.5.351 polish: no server sentence that tells the caller to pass `{ force: true }` reaches the person.
    ('Sources/ControllerModel.swift', 'let serverMessage = MacVoiceCopy.withoutForceJargon(',
     'the preview card never shows a server sentence that tells the caller to force'),
    ('Sources/ControllerModel.swift', 'message = MacVoiceCopy.earlierCorrectionNote',
     'a stalled earlier correction on the preview card uses the one Control line'),
    ('Sources/ControllerModel.swift', 'let detailText = MacVoiceCopy.withoutForceJargon(rawDetail, fallback: "")',
     'the confirm-time server text never tells the person to force something Control does not offer'),
    ('Sources/ControllerModel.swift', 'reviewError = MacVoiceCopy.earlierCorrectionNote',
     'a stalled earlier correction at confirm says what happened and offers no force'),
    ('Sources/ActivityWindow.swift', 'input.meetingUnnamed = unnamed',
     "Today's meeting rows read Speakers' count"),
]


def code(path: Path, text: str | None = None) -> str:
    src = text if text is not None else path.read_text()
    return '\n'.join(line for line in src.splitlines() if not line.lstrip().startswith('//'))


def check(sources: dict[str, str]) -> list[str]:
    failures = []
    for rel, fragment, why in PINS:
        n = code(ROOT / rel, sources[rel]).count(fragment)
        if n != 1:
            failures.append(f'{rel}: {why} (found {n}x): {fragment}')
    return failures


def main() -> int:
    sources = {rel: (ROOT / rel).read_text() for rel in {p[0] for p in PINS}}
    failures = check(sources)
    if failures:
        for f in failures:
            print('FAIL mac voice pins:', f, file=sys.stderr)
        return 1
    if '--selftest' in sys.argv:
        for rel, fragment, why in PINS:
            # Break the pinned line: delete it, and comment it out. Both must fail the pin for this line.
            for label, broken in (('deleted', sources[rel].replace(fragment, '')),
                                  ('commented', re.sub(r'^([ \t]*)(.*' + re.escape(fragment) + ')', r'\1// \2', sources[rel], count=1, flags=re.M))):
                mutated = dict(sources)
                mutated[rel] = broken
                if not any(why in f for f in check(mutated)):
                    print(f'FAIL mac voice pins self-test: {label} line was not caught: {why}', file=sys.stderr)
                    return 1
        print(f'PASS mac voice pins self-test: each of {len(PINS)} pins fails when its line is deleted or commented out')
    print(f'PASS mac voice pins: {len(PINS)} call sites (Rename voice, text-only Mac renames, Mac voice to profile, the Voice N count)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
