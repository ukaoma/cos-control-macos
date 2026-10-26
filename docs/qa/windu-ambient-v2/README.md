# Windu illustrated ambient V2 — approved visual candidate

This candidate fixes the effectively static V1 idle and meditation. Miles approved this visual candidate on 2026-10-26 at 08:53 CDT and explicitly authorized deployment. Native integration QA and final signed artifact verification are still required. V1 remains at port 8789; this comparison is on 8790.

- Idle: nine authored drawings, including an additional early head-turn bridge; grounded glance and return. 82 output frames at .04s, including intentional pose holds.
- Meditation: eight authored hand/head drawings plus eight generated violet aura stages, composited behind the character with a breathing-linked power envelope. 76 output frames at .04s. The aura is included in both exported sprite resolutions, not a preview-only effect.
- Patrol: unchanged V1 eight-pose illustrated forward gait at .14s; byte-identical copy.
- Combat and installed pack: untouched. Release 349 remains held with COS Product Work.

Run `node build.mjs`, `node audit.mjs`, then `node preview-check.mjs` with the preview server running. The latter checks the playback script and actual HTTP assets in a harness; it is not browser visual approval or native app QA.

Raster checks: transparent outer cell borders, distinct poses, lossless packing, and fixed opaque ground baseline. Preview has normal/quarter speed, dark/light/checker backgrounds, scrub/restart, and a 168px pet-scale view. Compare character consistency, visible motion, head-turn/return transitions, and aura power-up through the full loop before release. Perceptual sign-off is recorded above; native integration remains pending.

Image source provenance: built-in image generation; local generated originals retained in /Users/ukaoma/.codex/generated_images/01a141de-2178-7292-9a0c-b1cf9cd23603. Exact image bytes copied into references. The initial pose sheets are retained as development references; only increments-v2, idle-early-turn and aura-v2 enter this build. Generation was based on the V1 illustrated identities, not a new character design.

Approved state-map SHA-256: `2e020116b0c78da9346f07091c5514c92936c1f3b84af52a6a397fb2ef306500`


Native verification after visual approval: reused the unchanged compiled SessionPetSprite harness against the new runtime-loaded pack. All 82/76/8 frame selections and loop wraps passed, with 24 light/dark offscreen renders. The original appearance contract flagged the deliberately translucent aura as garment damage (24.62%). The follow-up test uses independently pinned pre-aura character artwork: it retains full-composite edge checks, runs the ordinary opacity checks on the source, and fails on any loss of opacity inside that source silhouette. Composite and source hashes are both pinned. Synthetic transparent and semi-transparent garment damage must fail; no percentage thresholds were relaxed. Final compiler/full-suite verification remains owned by COS Product Work.
