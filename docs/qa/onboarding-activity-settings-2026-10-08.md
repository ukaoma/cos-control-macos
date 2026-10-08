# October 8 onboarding review and Activity Settings

## Current state

Installed app verified locally: **0.5.270 (323)**. The **0.5.272 (325)** notarized ZIP is a local candidate, not evidence of a public release. It predates the Activity Settings change in this report. The auto-generated memory describing 0.5.272/server 6.66.0 as “shipped” is inaccurate; the earlier explicit artifact receipt says candidate-only.

Sources: October 8 Chris/Miles meeting supplied by Miles; onboarding addendum; installed Info.plist; Control candidate source; server candidate source; Hub `release-6.10.619.json` and its QA report.

## Findings and remaining work

| Finding | Evidence / disposition |
|---|---|
| Damaged Mac download | Prior hotfix 0.5.269 recorded as published; the later voice candidate passed signing, Apple notarization, stapling and Gatekeeper. Fresh download/upgrade acceptance still required for the next release. |
| CLI installation versus authentication unclear | P1 guide distinguishes installation/sign-in, provides actions and resumable setup. Installed 0.5.270 predates the merged P1 fix pass. |
| Claude missing under managed-service PATH | Confirmed still present in server candidate; fixed in this pass to use the shared absolute binary resolver. Invalid explicit override reports unresolved instead of silently falling back. Version availability is not authentication. |
| Dock discoverability | P1 provides Dock presence and Activity launch; user's screenshot confirms Activity is available. |
| Settings inaccessible inside Activity | Added persistent Settings button and an in-window panel. The panel is the existing ControlPanel, using the same ControllerModel/actions. Back/Escape return to the previous Activity section; Home and peer tabs leave settings. Window-hosted mode avoids claiming menu-bar visibility. |
| Unexpected pet / no obvious setup | P1 includes pet introduction and resumable setup guide. |
| Whisper requires Homebrew / external npm | Voice candidate uses bundled Node, a separately downloaded signed runtime, and transactional setup. Runtime asset and matching server must be hosted/published before public Control promotion. See voice-runtime report for real package tests. |
| Existing Max reset / cancellation leaves partial settings | Candidate tests cover saved choice preservation, cancellation and recovery. Must still exercise an upgrade on a separate account/device. |
| Memory alignment | Transcript identifies the Memory section but does not include the reported screenshot. Cannot reproduce or claim fixed from the two Activity/status screenshots provided. |
| Glasses setup, sessions, dictation recovery / Chris bugs | Hub receipt identifies 6.10.619 source 23e0c8a as a device-test candidate, 58/58 mutants and 39/39 WebKit layouts passed. Physical acceptance pending; marketplace not submitted and alias not moved. No blanket claim that every field symptom is verified fixed. |

## Release gates still open

1. Fresh macOS account/device without Homebrew, Node/npm/npx or existing CLI credentials: download, launch, provider install/login, server setup, voice runtime/model download, pairing, first meeting, Continue and Open in platform.
2. Upgrade existing installation: preserve Max, provider choices, tasks/meetings, pet/Dock preferences and privacy permissions; cancel/retry voice setup.
3. Calibrate the provisional voice recommendation on 8 GB and 16 GB Macs. Ultra measurements alone do not qualify the threshold.
4. Physical G2 619 acceptance: queued follow-ups, interrupted dictation, resend/restore, session clock and image strip.
5. Resolve Memory alignment with the original screenshot/reproduction.
6. After acceptance: publish matching runtime/server/Control and verify appcast/download/site claims against the actual hosted bytes.

## This pass validation

- Server: 27 tests passed across health probes, provider binary resolution and health route contracts. Includes executing a real fixture CLI outside PATH and rejecting a missing explicit override. TypeScript passed.
- Activity: full-source Swift compile passed; final light/dark renders at 1000×760 and minimum 760×560 were visually reviewed. Screenshots are in `activity-settings-images/`.
- Onboarding regressions: 200 guide checks, 101 provider fixtures and 3 pet-migration checks passed. The old wiring pin expected Activity to redirect to the menu bar; it was updated to require the embedded shared panel, both Activity entry points and Back handling. The revised pin suite passed. Static rendering and source wiring checks do not substitute for live click/persistence acceptance.
- Server fix commit: `a090c28`. Previously built server TGZ and Control 0.5.272 ZIP do not contain this pass; rebuild before distribution.
- No live app replacement, live preference changes or public promotion performed.

## Manual acceptance for Activity Settings

Open Activity from Dock, open Settings, compare status and every settings group to menu-bar controls. Change a reversible preference, verify both surfaces agree, restore it, close/reopen and verify persistence. Exercise Back, Escape, Home, peer tabs, setup-guide actions and settings while server is offline. Check light/dark and minimum window size. Do not treat static renders as proof of live interaction or clean-device onboarding.
