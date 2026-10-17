# COS Control full suite: shared Sources module (feat/suite-shared-module)

Base: ae13b68 (the 0.5.316 release candidate). Sources/ is unchanged; every change is in Tests/.

## Result

| | OLD (0.5.316 log, ae13b68) | NEW (this branch, same Sources) |
| --- | --- | --- |
| Wall clock (`/usr/bin/time -p zsh Tests/run.sh`) | **4171 s** (69.5 min) | **1153 s** (19.2 min), 3.6x faster |
| Exit | 0 | 0 |
| Guarded compiles printed (`compile-bounded: passed`) | 48 | 50 |
| swiftc jobs including HeldNamingGuardMutations' 9 silent ones | 57 | 59 (shim count) |
| Compiles of the whole app (44 or 42 Sources files) | 20 (19 lanes + the app) | **3** (shared `app` and `app-core` kits + the app) |
| Peak swift-frontend RSS (1 s sampler, all frontends together) | not sampled | **2.67 GB** (one frontend 2.67 GB) |
| Compile profile | bounded (memory below 40 GB free) | bounded (same conditions) |

0.5.315 for reference: 47 compiles, real 4167 s.

New-run compile time by kind (`COS_TEST_KIT_LOG`): 4 shared kit builds 369 s (app 174, app-core 170, meeting-core 13,
models 12); 31 harness compiles against a kit 95 s total (max 13 s, most about 2 s); 13 plain compiles run as written
118 s (helper 53 s); 27 kit reuses 1 s; 2 identical helper rebuilds skipped. The remaining time is the tests
themselves, the shipped app compile (reuse-compile.py, unchanged) and HeldNamingGuardMutations (9 Models.swift compiles).

## What changed

- **`Tests/kit-compile.py`** (new). Prefixed to every compile; takes the lane's command unchanged. When the command's
  Sources files are exactly one declared set and the rest is a plain executable build, it builds that set once per run
  into `COSControlKit` (`-c -emit-module -enable-testing -module-name COSControlKit` plus the lane's own flags, through
  `compile-guard.sh`), then compiles only the harness with the same flags plus `-I <kit>
  -Xfrontend -testable-import-module -Xfrontend COSControlKit` and links every kit object (`-Xlinker <obj>`).
  Harness files compile in place, so `#filePath` is unchanged. Sets: `app` (Sources minus COSControlApp.swift),
  `app-core` (also minus ControlSetup, ControlInstance), `models` (Models.swift), `meeting-core` (LiveTranscript,
  MeetingAskCore, Models). Anything else runs exactly as written; a byte-identical repeat of a plain build with
  identical inputs (the helper, three lanes) reuses the first binary.
  - Kit key: sha256 of every kit file's bytes, the full ordered flag vector, swiftc path/size/mtime/`--version`, SDK
    path and version, SDKROOT/DEVELOPER_DIR/TOOLCHAINS, and a recipe number. A reuse re-hashes every object and the
    module against the receipt; a source edited during the kit build fails the build. Kits live in `COS_TEST_KIT_DIR`
    (run.sh: `$TMP/kits`; mutation runners: their scratch dir; unset: a private dir removed on exit). 4 kits kept (LRU).
  - Two inputs with no `main.swift` are library files already, so a command without `-parse-as-library` gets it
    explicitly for kit and harness (ModelsContract, SpriteRenderContract); a single file or a `main.swift` runs as written.
  - `COS_TEST_KIT=0` runs every command exactly as written (the old layout).
- **`Tests/run.sh` and 52 `Tests/run-*.sh`**: 70 compile call sites got the one-word prefix
  `/usr/bin/python3 "$ROOT/Tests/kit-compile.py"`; source lists untouched (the pins that read them pass). run.sh exports
  `COS_TEST_KIT_DIR`. The shipped app compile through reuse-compile.py is unchanged. run.sh is still the single entry
  point and exits non-zero on any failure (each lane's compile exit code is returned unchanged).
- **`Tests/compile-bounded.py`**: accepts `-emit-module`, `-emit-module-path <p>`, and `-Xfrontend` only in the exact
  form `-Xfrontend -testable-import-module -Xfrontend <identifier>`; the plan check allows ONE module job without a
  primary file (`-emit-module` or `-merge-modules`, no `-c`). Every other rule is unchanged (-j 1, no WMO, num-threads 1,
  8 GiB owned RSS cap, one machine-wide lock). compile-guard.sh is unchanged.
- **20 `Tests/mutate-*.py`**: set `COS_TEST_KIT_DIR` to their scratch dir and route their direct compiles through the
  wrapper. A mutant in Sources rebuilds the kit once; a mutant in a harness reuses it.
- **Tests**: `Tests/test-kit-compile.py` (new, 16 tests, stand-in compiler, includes the one-byte Sources edit) and 2 new
  cases in `Tests/test-compile-bounded.py` (20 tests). Each new guard line was mutated and a test failed.
- **Sources changes: none.**

## Lanes left on the old path

None needed for correctness. Commands that are not one of the four sets run as written by design: the helper (3
HelperSources + WorkSessionLinks), the one-file cores (MacDictationCore, MacRecordingCore, PairingCore,
ProviderStatusCore, PermissionGuideModel, ProviderConnectModel, COSMarkdownParser, SessionLiveFeed, ControlInstance,
WorkSessionLinks), Models+HelperClient, Models+LiveTranscript, Models+ProviderConnectModel, the `-typecheck` lane, the
shipped app (with COSControlApp.swift), and HeldNamingGuardMutations (writes Models.swift to /tmp). No harness failed
to compile against the module: no private/fileprivate access, no Sendable-across-module diagnostics, no name clashes.

## Equivalence

`compare.py` normalizes both logs (worktree path, /tmp names, durations, pointer addresses, NSLog timestamps and PIDs,
compiler warning excerpts, compile-bounded/kit-compile lines) and diffs them in order.

- OLD 492 lines, NEW 492 lines, **zero differences, same order**.
- PASS / "passed" lines: 195 and 195, identical multiset and order. Every lane that printed in the old run printed the
  same lines in the same place in the new one, so no lane stopped running.
- Intentional differences: only the new `kit-compile:` notices and their timing lines (masked). The old log has no shim
  data; its compile count comes from its 48 `compile-bounded: passed` lines plus HeldNamingGuardMutations' 9 silent
  compiles (that script captures its compiler output in both layouts).

## Mutation proof (new layout, every runner proves an unmutated GREEN baseline first)

All runs 2026-10-16 20:04 to 20:51, serial, one compile at a time, all exit 0. 177 mutants landed exactly once;
176 KILLED, 1 SURVIVED, and that one is the survivor the runner already pins as expected (unchanged from the old layout).

| Runner (layout path) | Mutants | Result | Killed by (example) | Wall |
| --- | --- | --- | --- | --- |
| mutate-pet-refresh (`models` kit + ModelsContract) | 7 (all Models.swift) | 7 KILLED | ModelsContract exit non-zero, e.g. "an install that already is V12.6 is rewritten (no .current)" | 215 s |
| mutate-sprite-render (`models` kit + SpriteRenderContract) | 9 | 9 KILLED | SpriteRenderContract self-check, e.g. "fade never applies": "a uniform-alpha fade must be exempt from the hole gate" | 101 s |
| mutate-work-chat-helper (helper, run as written; identical rebuilds reused) | 7 | 6 KILLED, 1 expected survivor ("emitWorkChat ignores the mapping", pinned by run-work-session-hub) | `self-test-work`: "Work chat plan failure words self-test failed" | 434 s |
| mutate-messages-markdown (run.sh pins, MarkdownContract, `app-core` markdown-ui baseline) | 2 selected | 2 KILLED | "web only: refused links kept": 0.5.232 pin [messages]; "web only: no host check": MarkdownContract [web links only] | 192 s |
| mutate-work-board-cache (`app` kit + WorkBoardCacheChecks) | 2 selected | 2 KILLED | `main/WorkBoardCacheChecks.swift:10 check failed [stale after a stage move]` for both "epoch: a stage move" and "key: tasks" | 526 s |
| mutate-work-chat-review (`app` kit via run-work-session-hub) | 2 selected | 2 KILLED | "plan dispatches state": WorkOrchestrationChecks:130 "Planning stops at review"; "no revision check (isolated)": WorkOrchestrationChecks:195 "A changed task is never sent from a stale plan" | 571 s |
| mutate-mac-dictation-core (MacDictationCore + MacDictationChecks, run as written) | 121 | 121 KILLED | MacDictationChecks exit non-zero, e.g. "Fn counted as held again (the F17 bug)" | 773 s |

Each runner printed its own unmutated baseline GREEN before its first mutant. A Sources mutant in the `app` kit costs one
kit build (about 175 s, bounded), the same as one old full compile; a harness or pin mutant reuses the kit.

## Risks and notes

- The harness and the app are now two modules. Anything that only fails when test code and app code share one module
  (a test-only redeclaration) is no longer caught; that is test scaffolding, not app behaviour. Internal access is
  preserved by `@testable`; `#fileID` in harness code reads `main/...`, kit code `COSControlKit/...` (nothing reads it).
- A Sources mutant still pays one full kit build (about 175 s bounded), the same as one old full compile: the mutation
  speedup comes from harness mutants, lanes that compiled the app more than once, and identical helper builds.
- `app-core` is built for 2 suite lanes (markdown-ui, Jedi idle) at 170 s. Pointing them at `app` (2 more files visible)
  would save about 3 minutes more; not done, it changes what those harnesses see.
- Harness compiles are serial, through compile-guard like every compile. At 95 s total, running them concurrently
  would save about a minute; not worth a second path around the guard.
