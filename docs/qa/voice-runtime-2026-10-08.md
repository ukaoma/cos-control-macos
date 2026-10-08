# Voice runtime candidate — 2026-10-08

## Scope

COS Control 0.5.272 (325), server 6.66.0, and COS Whisper Runtime 1.9.1-r1.
Control includes onboarding P1 commit 1887f88 plus the new voice phase. Existing
installation and live voice settings are untouched by this development run.

This is a candidate, not a public release. The pinned runtime release URL must
be populated before the matching Control update is promoted. The public server
must also support the two preparation flags; older versions are refused with an
update instruction before their setup can change voice preferences.

## Implementation

- On Apple silicon/macOS 14+, voice setup downloads COS's own runtime (2,523,509
  bytes) over HTTPS, checks SHA-256, checks Developer ID team NV3X46LLCR, and asks
  Gatekeeper to assess the notarized app wrapper before moving it into its
  versioned support directory.
- Two static binaries, Metal embedded, with only Apple system dylibs. No
  Homebrew install, root permission, global npm, or global npx is needed for
  this voice path. Control uses its bundled Node. Existing provider sign-in is
  still required by server setup.
- Both server workers and the preparation CLI use the same explicit binary
  resolver. Invalid explicit paths fail closed; unset paths retain Homebrew
  and PATH fallback for older/direct installs.
- Prepare Turbo first, time 30 seconds of sample speech, then prepare the
  selected tier. Balanced still retains Large-v3 for saved-meeting HQ.
- Automatic preserves a saved tier from the manifest, settings file or live
  service. A genuinely new user receives the recommendation through the
  existing transactional tier application. Explicit model preparation does
  not apply a new tier; the separate Apply action does that.
- Cancellation kills the preparation process group. Downloads remain
  resumable and no tier keys are written during preparation. Interrupted
  snapshots from the preceding onboarding implementation are restored first.
- `voice-benchmark.json` contains chip, memory, disk, power state, runtime,
  sample/model, engine and wall-clock timings, peak RSS, Metal availability,
  recommendation, prepared tier, completion and policy version.

## Runtime provenance

Upstream whisper.cpp 1.9.1, commit
`f049fff95a089aa9969deb009cdd4892b3e74916`.

Runtime archive SHA-256:
`cf302b2ae4d7aa010a290c8f0a98b3dbb1a3307cac56bac0ceee87274423e6aa`.

Apple notarization accepted:
`63ea2d20-ca39-41ee-bedc-89a86f191862`. Ticket stapled and Gatekeeper accepted.
Build script: `scripts/build-whisper-runtime.sh`. Receipts and archive:
`dist/whisper-runtime/`.

Sample: 30 seconds made from upstream JFK public-domain speech, with source
and construction recorded in `Resources/VoiceBenchmark/SOURCE.md`.
This is a repeatable speed workload, not a transcription quality evaluation.

## Recommendation limits

Policy v1 provisionally recommends Max with at least 16 GiB, Metal, AC power,
and Turbo engine real-time factor <= 0.25. All other measured cases recommend
Balanced. Invalid timing fails without changing settings.

The engine timing includes model load from whisper.cpp's own timing start;
wall time is saved separately and includes process startup and teardown.
The first M3 Ultra/96 GiB run took 1.333 seconds inside Whisper, 10.45 seconds
wall time, with approximately 1.99 GB peak RSS for the 30-second sample.
This does not establish a smaller-Mac cutoff or Max's Large-v3 latency.

## Acceptance before stable promotion

1. Fresh Apple-silicon account without Homebrew/npm/npx: finish provider sign-in,
   start voice setup, verify runtime and model downloads, recommendation, one
   transactional application, then dictate and save a meeting.
2. Existing Max and existing Balanced: setup, retest, cancel and restart must
   leave the chosen tier unchanged. Choose another tier explicitly and Apply;
   verify it survives restart.
3. Cancel runtime and model downloads. Retry; verify no orphan processes, no
   partial tier change, and model download resumption.
4. Low disk and offline/network failure: actionable message, no silent switch.
   Corrupt runtime download: fail checksum before extraction.
5. 8 GB and 16 GB M1/M2 Mac: collect Turbo/preview timings and memory; compare
   actual dictation responsiveness and meeting commit latency. Calibrate the
   threshold before claiming the recommendation is broadly validated.
6. Upgrade from the previous Developer ID build: preserve privacy grants,
   account connections, tasks, meetings, custom pet and voice choice.
7. Publish the immutable runtime first, verify served bytes, then server npm,
   then the signed/notarized Control download and appcast. Do not promote only
   Control while its required runtime or server is unavailable.

## Evidence

Final test counts, packaged-app signature results and artifact hashes are
recorded below after the frozen candidate completes.

### Completed checks

- Runtime build: Apple Accepted, stapler validated, Gatekeeper accepted; dylib
  inspection contains only Apple system frameworks/libraries.
- Real helper installer: first install, repeat install, corrupt archive refusal,
  staging cleanup, interrupted old snapshot recovery, real Metal benchmark,
  unchanged saved Max, and cancellation with no surviving preparation child.
- Actual server npm tarball plus bundled Node in a disposable home: Turbo-first
  and complete model preparation, no saved tier invented for a new user, and
  recommendation receipt. Provider sign-in is a fixture and model bytes are
  existing read-only symlinks; this is not a full clean-Mac network-download test.
- Signed whisper-server: real 30-second WAV submitted to the local HTTP
  inference API; valid speech text returned, child terminated afterwards.
- Frozen-helper regression: 784 deterministic checks. Provider transport checks
  pass (identity, fallback, privacy, deadline/orphan cleanup, Ollama, old-server
  refusal, settings preservation).
- Server: 400 suites and 6,218 tests passed in the full run; only the changelog
  metadata check failed. After correcting its candidate labeling, all 20 package
  manifest checks passed; the nine focused CLI/resolver checks also passed.
  Two existing server tests are skipped. TypeScript check passes.
- Work-board resize gate: 71 steps, zero projection rebuilds, two body runs;
  each data change still rebuilds once. Desktop-safety gate passes.
- Light/dark onboarding voice rows rendered offscreen and visually reviewed.
  Screenshots in `voice-runtime-images/`; no UI automation changed the desktop.

The final warm M3 Ultra package canary measured 0.872 seconds inside Whisper,
1.072 seconds wall time (RTF 0.0291). Timing varies with process/Metal warm-up;
both measurements are retained rather than treating cold startup as inference.

Server source: `57808ccbf87459c137558cbe0daaa386226e8bc9`.
Server archive: `gotcos-glasses-server-6.66.0.tgz`, SHA-256
`4cf5e0de5f441f7811935d9d912e287e53951615d76ed185f109e1a4441cd946`.
