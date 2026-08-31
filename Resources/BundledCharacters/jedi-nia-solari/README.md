# Jedi Nia Solari

Approved animation pack shipped in COS Control 0.5.151 (build 189).
Original identity, single-blade ownership and registered character scale are preserved.

| Role | Frames | Seconds/frame | Cell size |
| --- | ---: | ---: | --- |
| idle | 8 | 0.24 | 348 × 256 |
| working | 12 | 0.14 | 348 × 256 |
| duel | 16 | 0.14 | 440 × 256 |
| trio | 14 | 0.14 | 440 × 256 |
| swarm | 19 | 0.14 | 440 × 256 |

Idle uses a 1.00x pack scale, matched to this character's combat art. Miles
Windu's separate source pack keeps its approved 1.30x idle multiplier.
Control 0.5.153 routed patrol and waiting to this idle instead of a still.
Since Control 0.5.154 (build 192), patrol has a dedicated eight-frame walking
cycle (0.14 s/frame; 348 × 256 cells), with planted steps and moving coat tails.
Waiting uses a separate eight-frame seated meditation loop (0.24 s/frame),
with restrained breathing and an electric aura.
These new loops use 1.00x pack scale, registered to the existing idle face size.
Distinct idle/meditation clips remain available as walking rests; shared clips
are deduplicated. Attention, done and error retain their single-frame fallbacks.

All 15 replacement strips across the three Jedi packs passed independent
visual review, native slicing and transparent-gutter checks. Generated art
uses discrete authored keyframes, not pose interpolation.

## Upgrade contract

Retained PNGs and `stock-state-history.json` identify untouched still,
four-frame, V1/V1.1 and 0.5.151/0.5.152 stock installs. The entire state dictionary and all
referenced image bytes must match. Custom art, timing, scale or metadata is
not automatically replaced. Versioned V2 files land before the state map
changes atomically; interrupted installs remain readable and retryable.

Approved source manifest SHA-256: `cf3927cd826527840ffcc05bf5a6a96297a44fdde3ce52a542d461951083ea7d`.
Runtime provenance and hashes: `approved-art-v2.json` and `approved-ambient-v3.json`.
The original idle/combat PNGs remain byte-identical. Exact-stock 0.5.153 maps
are also retained in the migration history; the new versioned files land first.
