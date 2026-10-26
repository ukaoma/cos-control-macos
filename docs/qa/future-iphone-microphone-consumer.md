# Future iPhone microphone consumer candidate

This branch starts at Control `1930036547519ae71f2bbf1b2cbe9aa58262f792` and is
excluded from Control 0.5.350/current release. No version, appcast, package,
installed app, permission, voice profile or runtime setting changes here.
Companion candidate: `9fe6d0b8` (after `4e49cd8c` / `b34f1632`). Server candidate:
`b59c9a2` (after the reviewed `05f84ec`, `ebf2251`, `6cd1e34` safeguards).

## Consumer behavior

- Exact `phone_<uuid>` / `phone_<13-digit epochMs>_<uuid>` lowercase identities,
  `iphone_microphone` DTO provenance and `phone:<captureId>` file keys remain
  distinct from G2/Mac, including identical UUIDs. Malformed phone prefixes
  cannot enter legacy source actions. Existing G2/Mac namespaces remain.
- Live switcher/status, Today running detail, saved source and recovery rows
  identify iPhone microphone. Offline recording remains local phone audio plus
  server Parakeet; Control adds no recorder, on-device ASR or alternate STT.
- Ask's file observer includes the phone namespace. Saved phone history and file
  context bind to the exact canonical ID, not a title/filename or foreign key.
  Existing disk scope still includes server, pairing and full capture ID. Nothing
  migrates phone questions/files into G2 or Mac storage.
- Local helper reads require the admitted phone registry, anonymous policy and
  exact source/start identity; changed journals also require anonymous chunks.
  Metadata reads are bounded/no-follow/nonblocking. An unchanged transcript
  rechecks registry/policy before returning the fast path. Invalid phone evidence
  stays on disk and returns a reason code without transcript leakage.
- Phone status requests carry explicit provenance and require the admitted DTO.
  Older/foreign-source status cannot silently reinterpret phone as G2/Mac.
- Phone controls show **Stop on iPhone**. G2's remote Stop/display bus and direct
  Control live save/save-all exclude phone. Only the owning phone's existing
  indexed/WAL Stop/save workflow is qualified by this protocol. Already retained,
  admitted orphan audio can use the server's strict recovery path; unadmitted
  phone evidence is not offered to Recover all.
- Phone naming, voice-review entry, policy controls, relabel/confirmation and held
  enrollment are refused. Anonymous copy explains the restriction. Mac's existing
  text-only rename policy is retained. Phone does not poll provisional preview or
  enable G2/Mac-only cue surfaces.

## Checks performed without the native lane

- Source/grammar fixture checks: 47 passed. These extract the actual Swift regex
  and check boundary wiring; they do not execute Swift or the helper.
- Existing pure Python guards passed: live transcript 147, live meeting 338,
  G2 Stop 28, Mac voice 13 call sites, and Work card files wiring.
- Python syntax validation and `git diff --check` passed. No native compilation,
  helper binary execution, UI, model/provider, microphone or device test ran.
- Final static receipt: `/tmp/control-phone-final-static-2.json` includes the
  recovery DTO/old-server status refinements. An earlier runner attempted a
  nonexistent Mac guard filename; the corrected final run above passed.

## Bounded native fixture qualification

Root granted these two sequential fixture lanes after continuous36v2 released
compilation. Production source is `dfd2bad`; test-only commit `62a97ab` fixes the
new fixture's attempted mutation of a `let` property. With explicit bounded
profile and isolated kit/home data, both final runs passed:

- Initial models attempt: production meeting-core compiled, then the new fixture
  failed to compile. `models.json`: 23.563 seconds, exit 1.
- Corrected models run: 43 compiled checks passed. `models-rerun.json`: 2.187
  seconds, exit 0, reusing the already compiled unchanged production core.
- Helper compile, 965 deterministic self-tests and 53 live-transcript helper
  checks passed. `helper.json`: 72.922 seconds, exit 0. Existing unrelated
  `Any?`-to-`Any` warning at `HelperSources/main.swift:14180` remains.

All receipts are under
`/Users/ukaoma/cos-release-candidates/control-iphone-microphone-20261026`.
Native lane explicitly relinquished after helper completion. Exact final
commands (do not rerun without the release owner's lane):

```sh
python3 '/Users/ukaoma/Documents/GitHub/Ukaoma Chief Of Staff/MU-Chief-Staff/.agents/skills/cos-glasses/scripts/release_lane.py' --receipt /Users/ukaoma/cos-release-candidates/control-iphone-microphone-20261026/models-rerun.json --timeout-seconds 600 -- env COS_COMPILE_PROFILE=bounded COS_TEST_KIT_DIR=/Users/ukaoma/cos-release-candidates/control-iphone-microphone-20261026/kits zsh Tests/run-phone-meeting.sh
python3 '/Users/ukaoma/Documents/GitHub/Ukaoma Chief Of Staff/MU-Chief-Staff/.agents/skills/cos-glasses/scripts/release_lane.py' --receipt /Users/ukaoma/cos-release-candidates/control-iphone-microphone-20261026/helper.json --timeout-seconds 600 -- env COS_COMPILE_PROFILE=bounded COS_TEST_KIT_DIR=/Users/ukaoma/cos-release-candidates/control-iphone-microphone-20261026/kits COS_LIVE_TRANSCRIPT_LANE=helper zsh Tests/run-live-transcript.sh
```

Both scripts route Swift jobs through `kit-compile.py` and
`compile-guard.sh`; no global lock override. The first checks source DTOs, same
UUID history/file caches, live-to-saved reopen, anonymous reducer refusal and
source-aware Stop/status rules using temporary data. The second executes synthetic
phone registry/policy/journal fixtures to existing helper tests, including no
registry, forged names, policy change despite matching stamp, symlink metadata,
foreign status, and pre-network mutation/Stop refusal. No model or capture runs.

A later full app build/full existing regressions are still required for modified
SwiftUI/model integration. Work card file intake/reopen must also be exercised
with the compiled source, rather than inferred from grammar pins. Static checks
are not native acceptance. Independent source review uses production `dfd2bad`; the subsequent `62a97ab` changes only the fixture. Source review remains separate from native qualification.

## Physical and release gates

User-supplied iPhone Duo / iOS 27.1; Even App Store listing 2.3.3/Open is not proof
of installed host version/build. Device permission/first tagged frame, glasses
switched off launch, never-paired onboarding, lock/background/interruption,
long capture, offline/process-kill recovery and actual installed Parakeet plus
dictionary remain **not run**. The companion's `docs/iphone-device-acceptance.md`
is the matrix. No Zoom/Teams/app-playback or native iOS capture claim exists.
Root's read-only host check found active developer directory
`/Library/Developer/CommandLineTools`; `xcodebuild -version` requires Xcode and
`xcrun --sdk iphoneos --show-sdk-version` cannot locate the iPhoneOS SDK. This
proves the active toolchain lacks that SDK, without establishing whether Xcode
exists elsewhere. A future native app-audio spike needs an explicitly selected
qualified Xcode/iPhoneOS SDK; do not switch toolchains during current Swift lanes.
The Even-hosted microphone JavaScript candidate does not need a native iOS build.
Ship only as a coordinated future companion/server/Control release after these
source, native and physical gates pass; no public activation from this branch.

## Prepared real WorkCardFiles intake/reopen lane (not run)

Independent review found that detail keys could override a selected phone row,
while a valid phone key on a row missing its source could enter files. The narrow
correction requires explicit row source and exact phone identity, binds phone
detail to the selected record, and uses that resolution for Files/Ask render,
remembered routes, grounded copy and file blocks. A rejected phone detail disables
intake and clears its stale remembered route. Legacy merged G2/Fireflies keys
retain their existing behavior.

`Tests/run-phone-meeting-files.sh` selects only the new synthetic plain-text
fixture in the existing WorkCardFiles harness. It runs actual WorkCardFileStore
intake, physical snapshot/manifest reads, saved/retitled aliases and store reopen;
it checks same-UUID G2/Mac/phone separation, source/foreign-detail refusal,
invalid aliases and preservation of existing attachment identity/bytes. No OCR,
pasteboard, UI, helper, network, audio or model code is called by this selection.

The existing harness needs the shared **app type test kit** (all Sources except
COSControlApp), so this command includes a cold kit compile; it does not build a
shipping app or execute app startup. Cold runtime is unmeasured. It uses the
bounded compiler's 8 GiB owned-tree cap/16 GiB start floor and a 600-second outer
scheduler deadline, one native job at a time, without overrides. Root must grant
this exact compile scope before execution:

```sh
python3 '/Users/ukaoma/Documents/GitHub/Ukaoma Chief Of Staff/MU-Chief-Staff/.agents/skills/cos-glasses/scripts/release_lane.py' --receipt /Users/ukaoma/cos-release-candidates/control-iphone-microphone-20261026/files.json --timeout-seconds 600 -- env COS_COMPILE_PROFILE=bounded COS_TEST_KIT_DIR=/Users/ukaoma/cos-release-candidates/control-iphone-microphone-20261026/kits zsh Tests/run-phone-meeting-files.sh
```

New static pins 51 and existing transcript147/live338/G2Stop28/Macvoice13/files
wiring passed in `/tmp/control-phone-files-static.json`. These are preparation
checks, not evidence that the new executable fixture has passed. The preceding
43 model/965 self-test/53 helper results apply to the earlier production source;
requalify affected models after this narrow correction. No native run occurred
while preparing this lane.
