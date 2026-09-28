# Work activity and theme — candidate 0.1.7 / build 8

Work now uses the existing cream/taupe palette for navigation, lists, activity, the agent workspace and its text editor. White button surfaces retain the shared button style. The global card token is unchanged.

Work list rows and the selected item show their latest recorded handoff, exact associated session, observed state, waiting/failure detail and saved result. Open session retains the Work backlink. A provider/session identity and source revision must match; title similarity does not establish an association. An idle session does not complete a task. Finished responses remain ready for review even when that session later starts unrelated work.

Foreground Work observes sessions at 15-second intervals when handoffs exist. This reads the same inventory as Sessions; it does not invoke a model. Discovery requests are coalesced. Observations expire after 45 seconds when projected and clear on failed discovery. Saved history remains visible. Draft/journal mutation and receipt reconciliation are independent of the read-only activity request. Receipt reconciliation skips delivered/terminal history during periodic refresh.

## Verification

- `zsh Tests/run.sh`: passed, including native macOS 14 compilation, helper self-tests, existing canaries/mutations and update rollback checks.
- `zsh Tests/run-work.sh`: passed. Workspace/review/foundation contracts, 14 existing handoff groups, plus activity association, cross-provider collision, revision fencing, waiting/errors, idle/completion separation, concurrent discovery coalescing, stale/offline observations, legacy decoding and byte-for-byte journal preservation.
- Candidate compiled with Swift 6 strict concurrency, ad-hoc signed and verified with `codesign --verify --deep --strict`.
- Native UI: cream/taupe light view, adaptive dark view, 780pt compact view; simulated continue → running → result; exact session navigation and return to the same work; app restart retained the draft, destination and result.
- Connected candidate loaded 202 existing tasks and successfully read session inventory. No live provider message or canonical task mutation was used for this verification.

An initial focused compile was restarted because a fixture changed during compilation. The complete focused rerun passed. Existing deprecation/style warnings remain in ControllerModel/SessionPet; no new compile errors remain.

## User test

1. Compare Work with Memories. Navigation and agent panels should use warm tones.
2. In the isolated preview, select the homepage task, choose the suggested website session, and Send to session. Use Show running and Show result in Handoff history.
3. Expect the list, overview count and Activity panel to update. The task remains open until explicitly completed.
4. Open session, then Back to work. Verify the same task and result.
5. In connected Work, use an intended real handoff to verify observed activity with your chosen provider. No unrelated sessions should acquire task links.

## Scope and rollback

Native-only delta; server source did not change. Existing server test evidence remains the 0.1.6 baseline, not a new server-suite run. No EHPK, glasses app, or glasses hub change is required for this display update. Installed Control 0.5.239/server 6.55.0 and glasses source 6.9.555 remain preserved. Candidate 0.1.6 and its version-pinned launchers remain available.

This candidate is for local QA. Confidence-based preparation, semantic matching and publication approval are still unfinished MVP gates; this update does not enable automatic runs. No public release or notarization is claimed.
