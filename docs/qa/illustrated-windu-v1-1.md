# Illustrated Windu V1.1 release integration

Approved for public inclusion by Miles on October 25, 2026, in COS Product Work's upcoming release. Version allocation, signing and publication belong to that release owner.

## What ships

The native sprite format carries the approved illustrated character and choreography. Sessions 1–4 contain 4/3/3/3 casts, respectively, with shuffled rotation and no immediate repeats. Frame counts are 184/148/172/256 at 50 fps (3.68/2.96/3.44/5.12 seconds). One-based entry handoffs are 145/109/121/217. All three Session 4 casts are adapted, including matching suspension and entrance poses. The original approved Session 4 cast is byte-identical to its approved rendered source.

The new gallery pack is `Resources/BundledCharacters/jedi-miles-windu`. Six ambient/signal state rows are unchanged from V15. There are 204 referenced PNGs, including 195 combat strips. The pack adds about 375 MiB before archive compression. Existing 1x playback policy remains in place; the retained segmented 2x assets are not enabled by this change.

## Upgrade and rollback

Generation 25 first runs the existing historical upgrade to the retained V15 checkpoint. Only an exact V15 state map with every referenced old PNG unchanged qualifies for the illustrated upgrade. Changed timing, scale, extra metadata, body/entry layers or custom art remain chosen. Every replacement is validated before writing; the map is committed last. A missing incoming layer refuses the entire upgrade. Validation decodes one pose at a time.

`Resources/DefaultPet` remains byte-identical to the previous V15 bundle, with its historical assets and tests. Installed old files are retained. Repeated launches leave the new map untouched. Cloud Puff remains the starter pet, and the other three Jedi retain their approved packs.

## Completed evidence

- `Tests/illustrated-pack-pins.py`: all 204 file hashes, exact approved map, alpha PNG format, counts, 50 fps cadence, handoffs, unchanged ambient rows and retained V15 map pass.
- `Tests/run-illustrated-pet.sh`: native stock upgrade, custom interval/body protection, missing incoming-layer failure before any write, all new bytes, all 96 retained V15 bytes, repeat no-op and all 13 native casts pass.
- Existing pet source mutation gate passes. Compatibility commit 990ef13 additionally passed ModelsContract and 11,599,412 rotation assertions over 21,000 loops.
- Exact production SessionPetSprite extracted into an offscreen harness rendered 39 start/entry/wrap snapshots across all 13 casts at 1x, 80pt, 210%. No keyboard or mouse automation. Local evidence: `/Users/ukaoma/cos-release-candidates/illustrated-sprites-v1/native/render.log` and `rendered/`.
- Sprite-export evidence remains with the versioned review: 2x RGBA frame identity, all 195 combat-strip hashes, exact Session 4 tail compositing, and the three cast contact/grounding audits.

## Combined release gates still required

Run the complete release suite on the combined source. `Tests/run.sh` includes the new test; SimplePetDefault now expects the V14→V15→illustrated chain and tests generation-24 V15 promotion. Run native gallery/idle contracts and packaged artifact tests. Preserve signing, notarization, extracted ZIP Gatekeeper checks, served-byte verification and appcast ordering. No live-app interactive QA or public publication is claimed by this handoff.

## User acceptance

With Windu selected, inspect Sessions 1–4 at saved character size and 100% speed. Watch at least six loops per state. Confirm no repeated cast at a boundary, incoming opponents keep identity across the reset, strike reactions start at contact, and Session 4 keeps the handoff, overhead arc, suspended hit and guard recovery. Check light/dark backgrounds and ambient idle/walk/waiting states. Slow playback to 25% for contact inspection, then restore 100%.
