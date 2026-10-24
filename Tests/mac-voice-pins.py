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
    ('Sources/ControllerModel.swift', 'let reason = skipped == "mac_capture" ? " · text only, Mac recordings never train a voice profile"',
     'the notice after a Mac rename says it was text only'),
    ('Sources/Views.swift', 'if model.openReview?.isMacRecording == true {',
     'the naming row shows the text-only note instead of the scope switch'),
    ('Sources/Views.swift', 'Text(review.isMacRecording ? MacVoiceCopy.unattributedNote',
     'a Mac review explains why nobody is named instead of blaming recovered audio'),
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
    print(f'PASS mac voice pins: {len(PINS)} call sites (Rename voice, text-only Mac renames, the Voice N count)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
