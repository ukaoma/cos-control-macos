#!/usr/bin/env python3
"""0.5.313: Open live meeting must land in the live transcript (Miles 2026-10-15 22:40). The Activity section switch
clears detail routes, so the button hands the id to the window, which opens it AFTER select(.meetings)."""
import pathlib, re, sys
root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.')
app = (root / 'Sources/COSControlApp.swift').read_text()
win = (root / 'Sources/ActivityWindow.swift').read_text()
fails = []
m = re.search(r'model\.macRecording\.openLiveMeeting = \{ \[weak model\] id in(.*?)\n        \}', app, re.S)
body = m.group(1) if m else ''
if 'model?.activityOpenLiveTranscriptID = id' not in body: fails.append('the button must hand the id to the window')
if 'openLiveTranscript(' in body: fails.append('the button must not open the transcript before the section switch')
if body.find('activityOpenLiveTranscriptID') > body.find('openActivity?(.meetings)'): fails.append('the id must be set before the window is asked to switch')
a = win[win.find('private func applyLaunchSection()'):]
a = a[:a.find('\n    }\n')]
sel, opn = a.find('if let next { select(next) }'), a.find('model.openLiveTranscript(openLiveTranscript)')
if sel < 0 or opn < 0 or opn < sel: fails.append('the window must open the live transcript after select(next)')
if fails:
    print('FAIL live meeting open pins: ' + '; '.join(fails)); sys.exit(1)
print('PASS live meeting open pins: Open live meeting hands the id to Activity, which opens it after switching to Meetings')
