# Jedi Elara Vale

Approved animation pack shipped in COS Control 0.5.151 (build 189).
Original identity, single-blade ownership and registered character scale are preserved.

| Role | Frames | Seconds/frame | Cell size |
| --- | ---: | ---: | --- |
| idle | 8 | 0.24 | 256 × 256 |
| working | 16 | 0.14 | 358 × 256 |
| duel | 16 | 0.16 | 544 × 256 |
| trio | 16 | 0.18 | 544 × 256 |
| swarm | 24 | 0.18 | 704 × 256 |

Idle uses a 1.00x pack scale, matched to this character's combat art. Miles
Windu's separate source pack keeps its approved 1.45x idle multiplier.
Control 0.5.153 routed patrol and waiting to this idle instead of a still.
Since Control 0.5.154 (build 192), patrol has a dedicated eight-frame walking
cycle (0.14 s/frame; 256 × 256 cells), with planted steps and moving coat tails.
Waiting retains the eight-frame breathing/glance idle (0.24 s/frame).
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

Approved source manifest SHA-256: `40c8072d6dce1306fc11ca6706ec6b8a4c108e1ae42417843564985cf92e6d4e`.
Runtime provenance and hashes: `approved-art-v2.json` and `approved-ambient-v3.json`.
The original idle/combat PNGs remain byte-identical. Exact-stock 0.5.153 maps
are also retained in the migration history; the new versioned files land first.
