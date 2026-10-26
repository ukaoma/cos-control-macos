# Windu illustrated ambient hotfix

Miles requested polishing the idle states and publishing a hotfix after Control 0.5.348. This candidate is based on the released main revision f827477. COS Product Work owns 0.5.349/build 403 integration and publication.

## Delivered behavior

- Idle: one sharp illustrated drawing, a continuous 80-frame breath at 40 ms (3.2 seconds). The inverse-sampled breathing movement anchors at the hips; the feet do not move. There are no double-exposure pose blends.
- Waiting: a proportion-matched seated meditation drawing, with 100 breathing frames at 40 ms (4 seconds). The old jagged flame aura is removed for a clean seated silhouette.
- Patrol: all eight existing gait phases redrawn in the same style, preserving the forward sequence and 140 ms cadence (1.12 seconds). This is a drawing-quality pass, not a newly choreographed walk.
- Each state ships 1x and 2x transparent PNG strips. Existing 1x playback policy remains unchanged.

All 204 PNGs shipped in the previous illustrated pack remain byte-identical. All four combat rows, 13 shuffled casts, recovery/entrance layers, frame counts and timing are unchanged. Done, attention and error are unchanged. The three old ambient files stay available with the exact previous map in `illustrated-v1-1-state-map.json`; DefaultPet V15 is also untouched. Six PNGs are added, about 6.4 MB total.

## Safe upgrade

Art generation 26 runs the existing exact-stock migration. The bundled history explicitly selects either retained DefaultPet V15 or the retained illustrated assets beside the new pack; it cannot select an arbitrary path. Both the complete state dictionary and every referenced PNG must match before replacement. Custom timing, scale, art or added metadata remains chosen. The existing transaction validates every new layer before writing files and commits the state map last. Old files are never overwritten or deleted.

## Focused verification

- All 204 previous PNG hashes, all six new PNG hashes, the exact previous map and new map, complete RGBA cells, cadence and Retina dimensions are pinned by `Tests/illustrated-pack-pins.py`.
- `Tests/run-illustrated-pet.sh` passed native V15 and 348 upgrades, unchanged/custom state handling, custom image protection, missing-file transaction refusal, retention of both rollback generations, repeated-launch no-op, native ambient frame slicing and all 13 combat casts.
- The actual SessionPetSprite implementation was extracted unchanged into an offscreen harness. Every ambient frame index and wrap was checked; 24 dark/light snapshots rendered with the real 80pt/210% presentation. No keyboard/mouse or computer-use automation ran.
- Reviewed generated keys, quarter-loop dark/light sheets and native snapshots. The first generated walk sheet was rejected for repeated leg roles; only the replacement based on all eight original gait frames is packaged.

The unchanged native appearance gate passed all 41 shipped strips. New idle and waiting have 0.00% interior holes; patrol has 0.02%, below the unchanged 1% ceiling. Minimum new ink margins are 25/8/17 pixels. Idle feet are byte-identical throughout its loop, and no white pixels occur in the arm/waist audit band. Bright boot and knee specular highlights are intentional and retained. No appearance exception or threshold was changed.

Full release QA, signed/notarized archive verification and served appcast-byte verification remain the release owner's final gates. No publication is claimed by this candidate document.

## Review / provenance

Local side-by-side preview: http://127.0.0.1:8789/index.html

Editable build, generated source sheets, exact prompts, renderer and export receipts are preserved under `operations/personal/wk42_2026/miles-windu-refinement/ambient-illustrated-v1` in the COS workspace. Images were edited with the built-in image-generation tool. The versioned preview offers normal/quarter speed, pause, frame scrub and light/dark/checkerboard backgrounds. Native production playback does not depend on this review page.
