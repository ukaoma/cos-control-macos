# Work session hub morning test

Candidate is an isolated native Control preview. The stable installed Control and server remain untouched; no transcription or cue setting changes. Plan, validation and source are on branch codex/work-session-hub, base9434695.

## First pass: sample GUI
1. Open the candidate's start-work-session-hub.command. It creates a private scratch home and opens the real Activity shell with sample Work data.
2. Your move shows IT Retail launch contributions: Claude needs input, Codex response ready, Cursor working. Open the IT Retail card.
3. Connections lists all three native identities and each result separately. The task remains Draft even though Codex reports done. Copy ID and copy context; pasted context names the shared canonical task and exact link commands.
4. Unlink Cursor, press Return to confirm. Other explicit links remain; Cursor's receipt stays as history. Link existing session can re-establish the association without sending a prompt.
5. Return to Your move. Hide a notice; select the History tab and Restore. The underlying delivery status and task stage must not change.
6. Switch to Board. Planned/Draft/Built/QA are visible; Mentioned and Complete are folded menus. Try 820px width and both appearances. Sample stage actions mutate sample state only.
7. Quit the candidate to return to the installed app. Scratch files may be inspected; they are separate from real journal data.

Sample Open deliberately navigates within the isolated shell. It does not open real native sessions and cannot establish the physical-native opening gate.

## Exact native / shared work gate (separate connected acceptance)
Use a disposable existing task and disposable native chats, not the real IT Retail launch until this passes. This stage requires an explicitly installed/connected candidate helper; the preview launcher is not connected.
1. Copy the task context into independent Claude, Codex and Cursor sessions already opened in the intended workspace. Obtain each exact provider UUID; never choose a recent session by title.
2. Each session runs work-context --work-id '<canonical-id>' --session-id '<provider>:<uuid>', then work-link-session with its returned sessionLinkRevision. Inspect returned linkedSessions: all three refer to the same task.
3. Refresh the candidate Work view while it stays open. All three contributors appear. Claude input, Codex done and Cursor working stay independent across refresh/restart.
4. Open Claude and Codex: exact native child appears, without a new turn or duplicate chat. A catalog-aged-out explicit ID must still target the same child.
5. Cursor button says Open Cursor Agents. Confirm the exact chat manually; no claim that raising Agents is an exact native chat open. Copy session ID is available.
6. Unlink one contributor with fresh digest. Test an old digest and wrong task: both refuse. Native chat, receipts, other links and stage stay intact.
7. A single contributor finishing cannot automatically move the shared task. A previously queued QA move must also be withheld after another contributor links. An explicit user-requested GUI/helper stage move with fresh workRevision should succeed.
8. Unknown delivery stays blocking even while its notice is hidden. Restore shows its original warning; a material new result resurfaces automatically.

## Automated gates
- Authenticated disposable helper fixture: fresh task CAS, current native identity, three providers, concurrent link merge, unlink CAS/wrong-task refusal, restart, unsafe/corrupt files, no provider job or phantom receipt.
- Swift canaries: independent contributor states, latest canceled/refused/failed/cleared outcomes with labeled older output, observed external summaries, fork parent exclusion, exact-ID normalization, history after remap, stale/missing live status, notice persistence/new evidence, unchanged epochs, queued shared-stage guard.
- Existing Work activity, board cache and clipboard context contracts.
- Native offscreen rendering (no window ordered, no provider contacted), bounded compilation, bundle signature verification and artifact hash.

Physical native opening and connected GUI/headless roundtrip are manual gates. Public release approval follows those results; this build does not promote a release.

## Design acceptance
Compare this candidate to the agreed work-tab-preview.html before connected testing. Your move, Board and History must be the primary navigation. The default decision view must not duplicate a priority task list underneath or use the old permanent session carousel/sidebar. Provider names and exact session identities must distinguish contributors. Task detail must put the finish line and task controls alongside Connections. Confirm no repeated evidence/result paragraph, visible keyboard confirmation, warm COS colors and bundled Fraunces/DM Sans typography.

Source reproducibility: use scripts/build-foundation-lab.sh with COS_WORK_SESSION_HUB_BUILD=1, COS_COMPILE_PROFILE=bounded, and COS_FOUNDATION_APP_PATH pointing to the desired .app bundle. Preview identity is com.gotcos.COSControl.WorkHubPreview020, version0.2.0 build11. The opt-in launcher supplies a new private scratch home; reopening it starts a new sample. Automated persistence canaries use the same scratch journal across store/helper restarts.
