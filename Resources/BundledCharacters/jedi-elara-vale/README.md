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
Windu's separate source pack keeps its approved 1.30x idle multiplier.
Attention, done, error, patrol and waiting retain their existing single-frame
fallbacks; this release does not claim new animations for those states.

All 15 replacement strips across the three Jedi packs passed independent
visual review, native slicing and transparent-gutter checks. Generated art
uses discrete authored keyframes, not pose interpolation.

## Upgrade contract

Retained PNGs and `stock-state-history.json` identify untouched still,
four-frame and V1/V1.1 stock installs. The entire state dictionary and all
referenced image bytes must match. Custom art, timing, scale or metadata is
not automatically replaced. Versioned V2 files land before the state map
changes atomically; interrupted installs remain readable and retryable.

Approved source manifest SHA-256: `40c8072d6dce1306fc11ca6706ec6b8a4c108e1ae42417843564985cf92e6d4e`.
Runtime provenance and hashes: `approved-art-v2.json`.
