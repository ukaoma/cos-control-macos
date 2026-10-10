# Live COS Ask and saved recording readability

Candidate on `codex/recording-indicators`, paired with server `codex/live-cos-ask` (base server 6.67.0). Not installed, notarized or published. Public Control remains 0.5.278/build 331. Assign new versions before distribution; do not ship this candidate with the base version identity.

## Accepted behavior

Live COS Ask is beside the live transcript. Catch me up (last minute), Summarize so far, Suggest questions, Action items and free-form questions run only when selected. Opening, recording, polling and receiving new transcript chunks do not call Haiku. The four presets use the current meeting only. Free-form questions may trigger relevant COS memory/earlier-meeting retrieval when the question needs it. Current and historical sources are distinguished; current passage buttons jump into the transcript. Answers are suggestions, not saved tasks.

Each request captures the visible meeting feed at ask time. Up to four recent exchanges help disambiguate follow-ups but are not evidence. At most two retrieval hops and three Haiku calls occur per explicit question; presets use one call. One request runs at a time, with no queue, automatic retry or provider fallback. A five-minute bounded in-memory result cache reuses unchanged preset requests. Meeting evidence is bounded to about 32,000 characters including metadata; oversized meetings show a selected-passages notice. Each Haiku response is capped at 1,400 output tokens and 45 seconds. The endpoint deadline is 150 seconds.

Stored Claude CLI sign-in is reused through the existing isolated runner. No new terminal commands, API keys or sign-in steps are needed when that connection already works. Closing the pane, hiding Ask, stopping or changing the meeting cancels pending work and rejects late answers. Chat exchanges are transient; no meeting files or tasks are written. The helper transports transcript/question JSON on stdin and uses the stored pairing token for loopback HTTP. Raw provider errors are not surfaced.

Saved recordings now receive deterministic formatting too: inline `[Speaker]:` labels become speaker sections, consecutive same-speaker fragments are grouped up to 600 characters, oversized chunks get readable paragraphs of at most 420 graphemes, with larger text and spacing. The reading area clips below the fixed header and above the footer. No AI rewriting, invented speaker identity or timestamps. Original files and saved Copy transcript content are unchanged. These presentation rules are scoped to meeting parsing rather than ordinary Markdown documents.

## Verification

- Native app sources, excluding the unchanged launch entry point, compile with Swift 6 strict concurrency for macOS 14. Native wiring/model suite: **66 passed**, including zero calls on open, duplicate-click protection, stdin-only payload, meeting switch and late-answer cancellation.
- Saved Markdown contract passed: inline labels, unlabeled prefix, nested transcript section, grouping/paragraph bounds, Unicode and source wording preservation.
- Live transcript wiring pins: **102 passed**. Desktop safety check passed. Existing helper live-transcript checks: **34 passed**.
- Actual compiled helper against an authenticated fixture endpoint passed success, missing route, unauthorized, busy, provider-error redaction, empty recent window and invalid-input checks.
- Server focused suite: **137 tests passed** across Ask core/HTTP, isolated engine, existing lens gist and work-search. TypeScript typecheck passed.
- Actual compiled helper → pairing-authenticated ephemeral Express API route → real Haiku: **passed in 2.276 seconds**, model `claude-haiku-5-5`, with two valid transcript citations and the unstated deadline left unresolved. [Receipt](live-cos-ask/haiku-integrated-canary.json).
- Real Haiku with injected historical-search fixtures passed in **7.024 seconds**, making one targeted search and distinguishing current and earlier sources. [Receipt](live-cos-ask/haiku-history-canary.json). This verifies hop orchestration, not live COS memory retrieval quality.
- Light/dark offscreen renders reviewed for transcript+Ask, answer cards and saved recordings. Invented fixture speech only; no app window activated.

The first integrated canary used macOS's default temporary directory, which did not satisfy the helper's `/tmp/` test-isolation guard; the helper contacted the existing server and got a missing-route response. The canary now explicitly creates its home under `/tmp/` and requires evidence that its own ephemeral endpoint received the Ask. No production route was changed by that failed probe.

## Previews

- [Transcript and Ask, light](live-cos-ask/pane-live-short-light.png) / [dark](live-cos-ask/pane-live-short-dark.png)
- [Answer card, light](live-cos-ask/live-ask-answer-light.png) / [dark](live-cos-ask/live-ask-answer-dark.png)
- [Saved recording, light](live-cos-ask/saved-recording-readable-light.png) / [dark](live-cos-ask/saved-recording-readable-dark.png)

## Release boundaries

Requires the companion server route; old servers show an update message. No EHPK change is required for this Control feature. Full release-wide testing, physical clean-install/onboarding canary, signed build, notarization and publication remain release gates. No changes were installed on Miles's running app or recording server.

W-b (duplicate row identity) was fixed by the preceding readability commit. W-a (five-minute cap on visible post-meeting helper-failure polling) remains outstanding for the next release and is separate from this on-demand Ask loop.
