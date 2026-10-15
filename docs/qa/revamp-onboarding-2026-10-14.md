# COS Revamp: onboarding refinement

Work: `task:personal:ce1f04b2f016`
Branch: `codex/revamp-onboarding-20261014`
Base: `bcb6d69` (Control 0.5.289 source tree)
Scope: native onboarding only. No public release or version promotion.

## Result

A staged welcome in the existing COS theme. Mac-only is selected by default. People with Even G2 glasses can choose the additional pairing step; everyone can change their device choice later in Setup guide. This preference changes the guide, not an existing pairing or server configuration.

The path is Welcome → Connect your AI / prepare this Mac → Choose access → optional Glasses → Make yourself at home. The last screen opens the real Work, Sessions and Meetings destinations. Session access and Continue are described as optional settings, not guaranteed enabled features.

The journey saves its start/completion and device choice. An unfinished journey resumes once after relaunch. Closing the window does not reopen it on every status refresh or cancel installation. Existing installations that never started this journey retain Setup guide and are not forced into new onboarding. Permissions and deferred glasses choices remain remembered; this is not a reset-all-preferences feature.

Readiness comes from the existing runtime status, ownership verification and transaction/busy state. The provider installation gate is unchanged. Permissions and glasses can be deferred. Stopped runtimes offer Start COS; interrupted transactions offer Repair; idle recovery is distinguished from active preparation. No recording implementation, provider authentication mechanism or permission grant was changed.

## Reference decisions

Reference evidence: nine October 14 meeting screenshots and their text companions in `/Users/ukaoma/cos-data/meeting-context/bf228839c4e1/`.

Adopted: a focused welcome, explicit steps, clear value explanations, connection status, and a short introduction with real destinations. Kept the COS cream/espresso/gold palette, Fraunces heading typography, existing buttons and shared provider/permission/pairing components.

The reference's redesigned sidebar, Today dashboard, agent screens, calendar connector flow and profile form are not part of this onboarding assignment. This change does not add controls for capabilities without an existing native setup contract. The existing gotcos glasses wizard remains linked from the optional glasses step. No website claims or download links were changed.

## Checks

- Provider-status fixtures: **101 passed**.
- Provider, setup and pairing model checks, including new journey persistence, all state combinations, upgrade behavior and relaunch rules: **427 passed**.
- Pet preference migration: **3 passed**.
- Permission guide logic: **122 passed**.
- Provider and permission wiring pins: passed. Updated the pins to follow the tested journey resolver and existing permission component.
- Full-source native compile through `Tests/run-onboarding-render.sh`: passed with Swift 6 strict concurrency. The renderer includes all production Sources except the app entry point and substitutes an isolated fixture entry point.
- Real SwiftUI views rendered in eleven states, two widths (390 and 560 points), light/dark. Fixture preconditions verify each named stage. These are static offscreen renders with fixture provider status, not live installation or pairing evidence.
- Four read-only QA perspectives: User, Skeptic, Completionist and Ghost Hunter. Initial findings about idle recovery, relaunch resume, a mislabeled fixture and Sessions capability copy were fixed. Final review found no remaining blocker or warning.

Compiler receipts and logs: `/Users/ukaoma/cos-release-candidates/revamp-onboarding-2026-10-14/`. The bounded compile profile uses the shared machine-wide lock and owned-process memory watchdog. No user apps were closed.

## Untested and release gates

- Clean-account download/install with no Homebrew, Node/npm/npx or AI credentials; real AI login; interrupted download recovery.
- Physical G2/iPhone/Tailscale pairing, scanning and reconnect. Existing pairing behavior was reused and model-tested, not physically exercised.
- VoiceOver announcements, keyboard-only navigation and actual window close/relaunch on an installed candidate. Accessibility heading focus and selected-device semantics are wired but require interactive acceptance.
- Live clicks into Work/Sessions/Meetings and live service Start/Repair. Their existing callbacks are reused; fixture renders perform no service mutation.
- Full release regression suite, signing, notarization, packaged download validation and installation. This source branch is ready for integration/user QA, not public release qualification.

No implementation blockers remain. No install, stable update, external publication or recording-code changes were performed.

## Acceptance path for the integrated candidate

1. On a fresh isolated account, open COS: welcome selects Just my Mac. Choose glasses, go forward then Back, and confirm selection persists. Return to Mac-only.
2. Connect an installed AI. Confirm missing-provider setup remains blocked, and skipping sign-in does not bypass the installed-provider gate. Prepare the Mac using the existing setup action.
3. Close/relaunch at an unfinished step: resume the same route once. Close without finishing and refresh status: it should not repeatedly reopen during that launch.
4. Choose or defer permissions. Mac-only proceeds to the introduction with no glasses section. Complete setup and relaunch: no welcome interruption.
5. Reopen Setup guide, select My Mac and glasses, and use the existing pairing flow. Defer it; confirm Mac functionality remains available and the optional guide can be reopened.
6. In a disposable stopped/interrupted setup, verify Start/Repair and Refresh recover to the next valid step. Never bypass an ownership conflict.
7. Test light/dark, 390-point width and short-window scrolling; keyboard and VoiceOver transitions; each introduction link with optional Sessions access both on and off.
