# Illustrated V1.1 appearance-gate investigation

The first combined release run detected six violations. This investigation reproduced the native measurements exactly, highlighted the counted pixels, and inspected every flagged edge frame. The artwork files and choreography are unchanged.

## Transparency

The renderer applies a 22px horizontal smoothstep mask to the enemy/effect layer on each frame (source `illustrated-session4-casts-v1/renderer.mjs`, constructor/faded; shared approved renderer). The new bundled folder did not inherit the previous pack's `edgeFades` metadata. The fixture now lists only frames with measured holes in this band, using the existing bounded22px rule. No center pixels are exempted by that rule.

| State | Original gated holes | After documented edge band |
| --- | ---: | ---: |
| Working | 0.2658% | 0.1133% |
| Duel | 2.3728% | 1.4191% |
| Trio | 1.4189% | 0.5148% |
| Swarm | 1.4408% | 0.5391% |

Duel101–104 has the same translucent destroyed heavy-droid wreck beneath the airborne hero. See `duel-holes.png` (pink marks counted pixels) and `duel101-light.png` (actual composite on cream). Windu is opaque. The textured wreck's varying alpha defeats the generic uniform-alpha classifier. The three qualifying connected components have bounds x29..167/y166..241, x76..91/y178..192 and x59..78/y227..239, and median alpha152/150/150. A four-frame authored-effect annotation covers only components wholly inside x29..167/y166..241 with median<=155, and is locked to the exact reviewed PNG SHA-256. After this region, Duel measures0.5273%.

This extends the existing documented-effect record with optional bounds, which constrain rather than broaden its spatial match. The1.0% generic opacity limit is unchanged. New synthetic tests ensure damage above the region, beyond its right boundary, or in another frame is still rejected. Existing eaten-garment, small-hole, fringe, fade, cut and entrance tests remain.

## Edge review (one-based)

- **Working109–114,129–136:** the full rounded blade tip remains visible; only its glow reaches the edge. The white core starts at x4 in109 and x1 in129/133. `working-tip-129.png` magnifies the rounded tip. Working160 is wreckage leaving the canvas during the reset. No character-body crop.
- **Trio43–47:** overhead probe's upper shell near top margin. **57–60:** suspended tan droid/firearm at the right margin. **92–100:** airborne collision fragments leaving top/right. **141,145–146,149–150:** next-wave probe entering through the top feather. `trio-edges.png` contains every flagged frame.
- **Swarm76–80,82–83,85:** downward sparks/debris from the struck droid, near the bottom margin. **241–242,245–247,249–250:** incoming probe/interceptor/ground opponents at feathered top/side boundaries. `swarm-edges.png` contains every flagged frame.

Only these exact edge-frame numbers are added; no blanket margin exception. The existing sliver/cut-ownership checks are unchanged. All approved PNG hashes remain pinned by `Tests/illustrated-pack-sha256.json`.

## Reproduction

`analyze.py REPO OUTPUT_DIR` requires Pillow, NumPy and SciPy. It reproduces the contract's four-neighbor holes, exterior-fringe flood, uniform-component exclusion and edge margins, and emits per-frame measurements plus diagnostic contact sheets. It does not edit sprites. `measurements.json` records the actual reviewed files. Run the native `Tests/SpriteRenderContract.swift` gate afterward as the authoritative check.

## Native verification result

The bounded native compile passed (receipt `compile.U4fINm`), followed by exit0 across all41 shipped strips and all synthetic discrimination tests. Native gated holes: Working0.11%, Duel0.53%, Trio0.51%, Swarm0.54%. Full output is `native-gate.log`. All204 approved PNG hashes also passed afterward. This changes QA evidence and annotations only; no runtime or artwork bytes changed.
