# Native encounter rotation v1

Optional `rotation` inside an existing pose in `session-pet-states.json`:

```json
{
  "poses": {
    "duel": {
      "file": "session-pet-duel.png",
      "frames": 37,
      "interval": 0.08,
      "renderScale": 1.45,
      "rotation": {
        "version": 1,
        "handoffFrame": 28,
        "variants": [
          {"id":"duel-a","file":"rotation/duel-a-full.png","bodyFile":"rotation/duel-a-body.png","entryFile":"rotation/duel-a-entry.png"},
          {"id":"duel-b","file":"rotation/duel-b-full.png","bodyFile":"rotation/duel-b-body.png","entryFile":"rotation/duel-b-entry.png"},
          {"id":"duel-c","file":"rotation/duel-c-full.png","bodyFile":"rotation/duel-c-body.png","entryFile":"rotation/duel-c-entry.png"}
        ]
      }
    }
  }
}
```

The example renderScale is illustrative: retain each accepted pose's actual scale. Supported poses are `duel`, `trio`, `swarm`. Keep legacy pose files for old builds and safe fallback. Every variant's three PNG strips must match the fallback strip's dimensions and declared frame count exactly. Paths are relative to the pack directory; escaping paths/symlinks and malformed/incomplete rotations are rejected per pose. There must be 2–8 distinct nonempty variant IDs (this pack uses three). The format requires every encounter in a pose to share frame count, cadence, hero registration, handoff and loop endpoints. `handoffFrame` is one-based inclusive: Session 2 is 28 of37; Session3 is31 of43. Session4 declares its own authored handoff. `rotation.seed` is optional UInt64 for deterministic native QA; omit for a random launch seed.

Before handoff: draw CURRENT.full. From handoff through the final frame: draw NEXT.entry, then CURRENT.body. At wrap: NEXT becomes CURRENT. The next cast is reserved at cycle start; current corpses never change identity when the next entrance begins. New bags contain each cast once and never repeat the last cast of the preceding bag.

`PetEncounterPlayback` is owned by `ControllerModel`, not by its periodically rebuilt hosting view. Repeated renders and 20-second root refreshes retain state. Time integrates against monotonic uptime using the previously active speed, so speed changes do not seek. Reduced motion holds the current frame/cast. Switching poses pauses each pose's state; returning resumes it. Hidden panel or an unexpected callback gap (over one second or 2.5 authored ticks, whichever is longer) holds the animation rather than fast-forwarding unseen combat. Asset/metadata content fingerprints reset only changed rotations. Legacy packs retain their existing absolute-time playback path. Existing size and renderScale controls apply to the same fallback-matched canvas.

Changing a pose's frame count retires its rotation metadata; replacing its art also retires it, even if file/count are unchanged. Changes to unrelated poses preserve it. Whole-pack installation should stage and copy the complete manifest and all referenced PNGs together. This extension does not add a new external pack import format or remote installation API.

Diagnostics are off by default. Launch with `COS_PET_ROTATION_DIAGNOSTICS=1` for unified-log `COSPetRotation` records (subsystem `com.gotcos.control`, category `pet-rotation`) on pose activation/resume and loop wrap, including pose, cycle, current/incoming IDs, frame, and handoff. No logging occurs per frame and no diagnostic files are written.

Run `Tests/run-pet-rotation.sh` for the real Models.swift scheduler, clock, layer-order and strict-loader tests. The script uses the repository's memory/compile guard. No app bundle is built or installed. The parent build owns full-app compilation, asset packaging and native visual QA.
