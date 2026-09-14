# Resume Control UI after explicit mock approval

Worktree: `/Users/ukaoma/codex-worktrees/speaker-slice1/control`
Branch: `codex/speaker-slice1-05223`
Target: Control 0.5.223 (build 261), server 6.46.0.

Current scope is helper/controller/models/tests plus a concrete mock. `Sources/ActivityWindow.swift` is deliberately unchanged. Do not install this intermediate branch: Add currently requests a preview, but the preview sheet has not been built. The user approved the release number, sample preservation and Clinton listening check; none of those answers approves the layout.

Mock: `design/speaker-naming-0.5.223.html`. Wire and test evidence: `design/speaker-naming-wire-0.5.223.md`.

## Implementation sequence after approval

1. Build the preview sheet using the controller’s dedicated `heldNamingShowReview` route flag and `heldNamingPreview`. Every Add/Name calls `nameHeld`, which only requests a preview. The explicit Apply button calls `applyHeldNaming`. Cancel calls `cancelHeldNamingPreview`. Remove the old likely/high confirmation distinction; both suggestion tiers preview before Apply.
2. Render individual loose rows with `ForEach(model.heldLoose)` and stable sample identity. The row exposes suggestion name, score and owner caution, existing Listen, Name and Discard. Count loose samples individually in `heldGroupsBody`; its current count treats all loose samples as one row and would fail to scroll a 239-sample fixture. Keep the existing toolbar clamp and a flexible list with the existing 88-point floor.
3. Preview separates eligible held samples, planned selected voiceprints and transcript positions. Do not promise every coherent sample becomes a stored embedding: diversity selection and the 40-sample cap apply. Show per-meeting named/wider chunks, scores and room caution. Play only `HeldNamingPlayback` values via `playHeldNamingMatch`; the player uses raw `chunkIndex`, never compacted `position`. A null triple has no play button. Respect `heldNamingOwnerAck`, `heldNamingListened`, `heldNamingCanApply`, and expiration.
4. Show applied/partial/undone receipts, copy outcomes and graph-staleness badges. `.copySummaries` prefers write receipts over snapshot copies. `.enrolled` is accepted selected voiceprints; `.profileEmbeddings` is a nullable retained total. `.memberOutcomes` separates enrollment, label and audio status; `represented` is not another enrollment. Undo uses the durable `undoHandle` and explicit confirmation, retains enrolled samples and never restores audio. `.restoredSegments` is distinct from remaining `.labelled` on partial Undo.
5. Expose `heldNamingBatches.filter(\.needsReview)` as interrupted/partial naming with explicit Resume (`resumeHeldNaming`) and Revert (`undoHeldNaming`). Resume only opens a new preview. No silent retries. Include a compact recent-batch disclosure to retain Undo access after Control restarts. The parent approved this necessary persistence detail; no additional user question is needed once the main layout is approved.
6. Gate new naming/Undo/label copy on `heldNamingAvailable`, including a capability downgrade while the view is open. The helper independently rechecks capabilities before every naming request. Preserve old-server listening and discard; explain the 6.46.0 requirement.
7. Update `nameHint` for the server’s NFKC/case-folded resolution, ambiguous case duplicates and the retained 40-sample cap. Do not claim a new voice when a differently-cased existing voice will be selected.
8. Update old source pins in `Tests/run.sh` around held groups and the 0.5.222 layout: opener → actual preview render, Preview → Apply, Undo after audio deletion, capability/minimum server, loose-row scroll count, and case-folded hints. Preserve the fixed-toolbar and scroll-in-place assertions. Add executable UI/offscreen coverage of 239 rows at the minimum window and a normal window.
9. Remove the pending-UI note in the changelog only after implementation and verification. Run the complete suite. Commit locally. Publishing, signing, appcast, installation and restarts belong to the parent’s release train.

## Verification commands

```sh
cd /Users/ukaoma/codex-worktrees/speaker-slice1/control
Tests/run.sh
```

`run.sh` builds the whole app with Swift 6 strict concurrency and macOS 14, compiles/runs the helper self-test, executes isolated HTTP transport tests, and proves all eight naming model guard mutations land, compile, and fail their assertions.

For server-produced JSON receipts stored outside the repo:

```sh
swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete \
  Sources/Models.swift Tests/HeldNamingWire.swift -framework AppKit \
  -o /tmp/cos-control-slice1-wire
/tmp/cos-control-slice1-wire /absolute/path/to/wire-real-preview.json \
  /absolute/path/to/wire-real-applied.json /absolute/path/to/wire-real-undone.json \
  /absolute/path/to/wire-real-history.json
```

Do not copy private meeting receipts into this repository. The decoder emits only aggregate counts.
