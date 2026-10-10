# Recording indicators and live transcript shortcut

Candidate based on Control 0.5.278 (e0c3060), intended for the next release. Not published or installed by this change.

## Behavior

- Menu bar: a red dot while the server reports a live recording. Gold glasses remain when an update is also available. VoiceOver announces both states.
- Dock: REC for one recording, REC plus the count for several. Stopped/offline status clears the badge.
- The menu-bar panel shows Meeting recording and View live transcript. The Dock menu and the Meetings application menu provide the same action; Command-Shift-L works while COS Control is active.
- Clicking/reopening the Dock app during a recording goes directly to Meetings and selects the single live transcript after a fresh session listing. Several recordings open the chooser. A minimized Activity window is restored.
- Recording indicators remain visible if live transcripts are disabled; the panel explains how to enable transcripts. The action respects that setting.

## Architecture and limits

The existing 12-second status refresh supplies liveTranscriptionSessions (falling back to activeTranscriptionSessions for older servers). No new watcher, server endpoint, notification permission, background transcript reader, or glasses package is introduced. Status failures clear the indicators. Detection latency includes the status request and its existing refresh interval; this is not an instant push notification.

Dock writes are wired by COSControlApp, not test models. Transcript text still reads only in the visible Meetings view. The route intent expires after 30 seconds and is cleared on navigation; a session is never guessed when several recordings are active. No transcript text appears in indicators.

The published 0.5.278 archive is unchanged. W-a (five-minute failed-handoff polling cap) and W-b (duplicate fallback row ID) remain separate 0.5.279 follow-ups.

## Validation

Results recorded after the focused tests and macOS 14 app build below. Tests use invented transcript fixtures, a stand-in helper and scratch homes. No live app activation, server restart or user recording modification.

- Update/recording icon model suite: 115 checks passed.
- Live transcript model and helper-stand-in suite: 59 checks passed, including hidden-window polling, saved handoff, start/stop/offline badges, preference handling, shortcut expiry/cancellation and Dock menu dispatch.
- Existing live transcript wiring pins: 102 passed. Update badge wiring pins and desktop-safety check passed.
- Offscreen panel renders reviewed in light and dark mode: [light](recording-indicators/panel-light.png), [dark](recording-indicators/panel-dark.png). These are fixtures, so their version/server setup labels do not describe the installed app.
- Focused validation only; the full release suite, signed/notarized archive and publication remain release gates. Real Dock/menu-bar interaction has not been driven on the user's desktop.

- Full app compiled for arm64 macOS 14 with Swift 6 strict concurrency through the machine-wide compile guard. Exit 0; existing warnings only.
