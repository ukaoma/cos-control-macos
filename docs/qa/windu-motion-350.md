# Windu running cadence and cast-load recovery

## Changes

- Session 1's opening run goes from 28 to 24 display frames; its second run goes from 16 to 24. The raised-saber hold goes from 8 to 4. Both running bursts are now .48 seconds at 50 fps; the overhead hold is .08 seconds.
- The whole composition is retimed together. Source frames 84–183 (zero-based), including contact, destruction, recovery and incoming tail, are pixel-identical at the same indices. Total 184 frames, .02s interval and handoff 145 stay fixed for all four casts.
- Twelve new full-strip PNGs retain the original character pixels, size and alpha. Prior 349 map and all 204 illustrated plus 6 ambient PNG hashes remain preserved. Generation 27 upgrades exact stock only; custom cadence/art stays intact.
- A failed asynchronous cast load previously left `petRotationPose` equal to the requested pose indefinitely. The next request returned early, replaying the first-cast fallback. Completed loads now clear the pending task; missing art becomes eligible for a retry on a later panel refresh after a five-second backoff. Healthy casts retain the same playback bank and never reload on a normal poll.

## Evidence and scope

The installed 349 map, native loader and fresh native SwiftUI renderer all showed three distinct Session 4 lineups. The native renderer was observed over 18 seconds, rendering C→A→B→A. The reported fault in the existing running app was **not reproduced**. The failed-load latch is a demonstrated recovery defect and a plausible explanation, not a confirmed historical diagnosis of that process.

The isolated controller lifecycle test extracts the production loading methods, redirecting only their disk root to a temporary fixture. It exercises a real failed asynchronous load, repair of the source without a pose change, delayed retry, all three casts loading, and retention of healthy art. It starts no full Control process and touches no installed user files.

## Checks

- `Tests/run-pet-rotation.sh`: 11,599,412 scheduler assertions; actual packaged retime pixels; 48 swarm cycles; no immediate repeat; complete shuffle bags; current-body/incoming-entry composition; asynchronous failed-load recovery.
- `Tests/run-illustrated-pet.sh`: V15/348/349 stock upgrades, rollback retention, custom image/cadence protection, atomic rejection of incomplete candidates.
- `Tests/illustrated-pack-pins.py`: preserved 204 + 6 files, 12 new pinned files, 184/148/172/256 frame counts, 4/3/3/3 casts, unchanged intervals and handoffs.
- `Tests/dictation-wispr-pins.py`: exact character filename fixture updated; 343 checks.
- Native appearance contract: same thresholds; the Session 1 entrance-feather frame annotations are transformed with the exact timing map. No exception is broadened.

## Final app release gate

Run the integrated full suite and signed-app checks. In the actual app, hold Session 4 active for at least four complete loops and confirm the three different lineups and their incoming entrances. Check Session 1 through both run bursts, parries and strike on each of its four casts. Keep the prior pack and require the usual release owner's publication checks. This source candidate is not itself a public release.
