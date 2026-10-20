# Version 15 (V15) Miles Windu: release notes for 0.5.329

For whoever cuts 0.5.329: paste the CHANGELOG section under the new version heading and add the What's New item to
`Resources/WhatsNew.json` (the item into the 0.5.329 section, the sentence at the front of the summary). Then delete this
file. Naming: always "Version 15" or "V15", described as "V14 to V15". Never "V1.5", which was the superseded first bake.
QA, measurements and sheets: `operations/personal/wk42_2026/miles-windu-refinement/installation-v1-5/` in the COS repo
(`NATIVE-QA.md`, `compare/CLAIMS.md`).

## CHANGELOG section

### Miles Windu Version 15

Miles, 2026-10-19: "deploy these updated sprites for our jedi. Needs to be the default for our future releases as well."

- The bundled Jedi Miles Windu is Version 15 (V14 to V15), re-rendered from a 2x source. Session 1 (one running session)
  now rotates four opponents (tan droid, heavy droid, rolling droid, alien), like Sessions 2 to 4. Blaster bolts travel
  instead of hanging as static beams, the left droid walks instead of sliding (duel F8 to 15), the F52 swarm shots no
  longer collide, the white specks on the shoulder and collar are gone, and the violet ghost at Session 1 F22 is gone.
- Fixed before ship, each with a check that fails on the unfixed art: the heavy droid's wreck no longer fades violet
  (duel, trio, swarm); the done saber is no longer cut at the cell edge (done cell 99 to 199 pt, figure the same size);
  the duel loop seam F37 to F1 is exact again; Windu no longer shrinks mid-swing in Session 1 F22 to F24 (head was at
  72 to 76% of his other frames); the attention (F4 to 6, F13 to 15) and done (F9 to 11) bridge frames are no longer
  55 to 59% see-through and stand at his standing height.
- Attention runs 18 frames (was 13) and done 14 (was 10), because Version 15 adds drawn bridge frames: the loops are
  0.34 and 0.36 s longer.
- Memory: casts now decode for the state on screen only, off the main thread. The old state keeps animating until the
  new state's casts are ready (about 0.5 s at most), then the old casts are released. Cells live in their own mapped
  pages, so a released state really gives its memory back (before, freed cells stayed resident). Measured over 20 cycles
  through every state: peak +222 MB over the bare app against V14's +215 MB, idle +46 to +76 MB (V14 held +214 MB all
  the time), longest main-thread slice 6.2 ms.
- Retina: the pack carries 2x strips and the loader can play them at the same size on screen, but this release plays the
  1x strips on every display. Two cast states at 2x, held during a decode, peaked at +589 MB, over the gate of V14 plus
  150 MB. `ControllerModel.petRetinaArtScaleCeiling` stays 1 until casts decode one variant at a time.
- Upgrade (art generation 23): a stock V12.6 or V14 (flat or rotation/ layout) moves to Version 15 on first launch with
  no file deleted. A tuned V14 is left alone. V14 timing-v2's strips stay in the bundle, so a later release can return to
  V14 as stock.
- Tests: `Tests/jedi-v15-pack-pins.py` (96 files and the map pinned by hash; display scale, art ceiling, off-main decode,
  stale-decode and display-pose wiring; 45 in-memory mutants, each proven to land and caught). PetRotationChecks: retina
  segments and fallbacks, Session 1 casts, `only:` loading, memory release (63 MB loaded and dropped three times, back
  within 12 MB) and a use-after-free sample (three cells held past their release read back identical to a fresh decode).
  SimplePetDefault: production renderer for every cast state of all four Jedi, V14 to V15 upgrade paths, 2x strips at
  identical point sizes, the 1x ceiling; pool-scoped, peak footprint 703 to 770 MB (an earlier eager version reached 21.5 GB).
  Memory mutants (cell never unmapped, cells on malloc, cell unmapped while held, loader ignoring `only:`): 4 of 4 caught.

## What's New

Section item:

"Jedi Miles Windu is Version 15: four rotating opponents on one session too, blaster bolts that travel, smoother droid
movement, and cleaner art. Your Mac also uses less memory for the pet: only the scene on screen is loaded."

Summary sentence (front of the summary):

"Jedi Miles Windu is Version 15: four rotating opponents on one session too, traveling blaster bolts, smoother droids and
cleaner art, and the pet now loads only the scene on screen, so it uses less memory."
