# Jedi Elara Vale

Bundled COS Control character. One normalized 960x900 RGBA master covers the seven
single-session states. Green saber; charcoal, teal, copper, and cream kit.

## Multi-session combat strips

`duel`, `trio`, and `swarm` each carry an authored 1024x256 strip of four 256x256 cells:

| Cell | Beat |
| ---: | --- |
| 1 | Guard. Saber lit and raised, droids established. |
| 2 | Threat. Droids fire; each bolt starts at a visible muzzle. |
| 3 | Contact. The blade strikes exactly one droid, with a green impact burst. |
| 4 | Aftermath. The struck droid is knocked back with a cut scar and its blaster down; the others stay upright. |

Escalation reads from droid count: 1 for `duel`, 3 for `trio`, 5 for `swarm`. Cell 4 cuts
back to cell 1 on the same camera and ground line, so the four cells loop continuously.

Droid counts were authored to hold across all four cells but are not machine-verified, and
spot checks suggest one or two cells drift by a droid. Cosmetic at pet scale; worth a
re-render if it reads badly on screen.

Machine-verified and pinned by `Tests/run.sh`: 1024x256, real alpha (all corners
transparent), and zero ink at every cell-boundary column, so no figure is clipped by a cut.

Not normalized against the portrait: the seven still states render from a 960x900 master
whose subject fills ~84% of the canvas, while these cells fill 51-92%, so the character
changes apparent size when a second session starts. Fixing that needs a re-render, not a
code change.
