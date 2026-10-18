import AppKit
import Foundation

@main @MainActor
struct PetRotationChecks {
    static var checks = 0
    static func check(_ ok: Bool, _ name: String) {
        precondition(ok, "Pet rotation check failed: \(name)"); checks += 1
    }
    static func manifest(handoff: Int = 28) -> PetRotationManifest {
        .init(version: 1, handoffFrame: handoff, seed: 42, variants: (0..<3).map {
            .init(id: "cast-\($0)", file: "r/\($0)-full.png", bodyFile: "r/\($0)-body.png", entryFile: "r/\($0)-entry.png")
        })
    }
    static func art(frames: Int = 37, handoff: Int = 28, fingerprint: String = "first") -> PetEncounterRotation {
        .init(fingerprint: fingerprint, manifest: manifest(handoff: handoff), frames: frames,
              variants: (0..<3).map { i in
                  .init(id: "cast-\(i)", full: (0..<frames).map { _ in NSImage(size: NSSize(width: 4, height: 4)) },
                        body: (0..<frames).map { _ in NSImage(size: NSSize(width: 4, height: 4)) },
                        entry: (0..<frames).map { _ in NSImage(size: NSSize(width: 4, height: 4)) })
    }
    static func sample(_ bank: PetEncounterPlayback, _ art: PetEncounterRotation, _ time: Double, speed: Double = 1, paused: Bool = false, pose: PetSpritePose = .duel) -> PetEncounterPlayback.Snapshot {
        bank.sample(pose: pose, rotation: art, now: time, speed: speed, interval: 0.08, paused: paused)!
    }
    static func main() throws {
        for (frames, handoff) in [(37,28),(43,31),(64,55)] {
            for seed in UInt64(0)..<10 {
                var a = PetEncounterSequence(count: 3, frames: frames, handoffFrame: handoff, seed: seed)
                var b = a
                var choices: [Int] = []
                for _ in 0..<300 {
                    let current = a.current, incoming = a.incoming
                    choices.append(current)
                    check(current != incoming, "no immediate repeat")
                    for f in 0..<frames {
                        check(a.current == current && a.incoming == incoming, "reservation stable for entire loop")
                        check(a.frame == f && a.inTail == (f+1 >= handoff), "handoff inclusive")
                        check(a.current == b.current && a.incoming == b.incoming && a.frame == b.frame, "seed deterministic")
                        a.advance(); b.advance()
                    }
                    check(a.current == incoming && a.frame == 0, "incoming becomes current on wrap")
                }
                for start in stride(from: 0, to: choices.count, by: 3) {
                    check(Set(choices[start..<start+3]).count == 3, "complete shuffle bags")
                }
            }
        }
        let pack = art(), bank = PetEncounterPlayback(seed: 8)
        let initial = sample(bank, pack, 0)
        check(initial.frame == 0, "first frame")
        check(sample(bank, pack, 0) == initial, "re-render consumes no randomness or time")
        let step = sample(bank, pack, 0.08)
        check(step.frame == 1, "authored cadence")
        let quarter = sample(bank, pack, 0.08, speed: 0.25)
        check(quarter == step, "speed change does not jump")
        check(sample(bank, pack, 0.40, speed: 0.25).frame == 2, "quarter speed integrates elapsed")
        let pause = sample(bank, pack, 0.40, speed: 0.25, paused: true)
        check(sample(bank, pack, 100, paused: true) == pause, "reduced motion freezes exact pose/cast")
        check(sample(bank, pack, 100) == pause, "resume no hidden-time catchup")
        check(sample(bank, pack, 100.08).frame == 3, "resume advances")
        let other = art(frames: 43, handoff: 31, fingerprint: "trio")
        check(sample(bank, other, 101, pose: .trio).frame == 0, "new pose starts at opening")
        check(sample(bank, pack, 102).frame == 3, "returning pose resumes without inactive advancement")
        check(sample(bank, pack, 999).frame == 3, "sleep does not skip fight")
        bank.pause()
        check(sample(bank, pack, 1500).frame == 3, "hidden panel resumes held state")
        let copy = pack
        check(sample(bank, copy, 1500).frame == 3, "reloaded identical art preserves state")
        check(sample(bank, art(fingerprint: "replacement"), 1500).frame == 0, "changed pack resets state")
        check(bank.sample(pose: .idle, rotation: nil, now: 1501, speed: 1, interval: 0.08, paused: false) == nil, "legacy pack fallback")
        let slowBank = PetEncounterPlayback(seed: 9)
        _ = slowBank.sample(pose: .duel, rotation: pack, now: 0, speed: 0.25, interval: 0.4, paused: false)
        check(slowBank.sample(pose: .duel, rotation: pack, now: 1.6, speed: 0.25, interval: 0.4, paused: false)?.frame == 1, "slow authored cadence does not look like sleep")
        let transitionBank = PetEncounterPlayback(seed: 9)
        var snapshot = sample(transitionBank, pack, 0)
        for f in 1..<37 { snapshot = sample(transitionBank, pack, Double(f) * 0.08)
            let layers = pack.layers(for: snapshot)
            if f >= 27 {
                check(layers.count == 2 && layers[0] === pack.variants[snapshot.incoming].entry[f] && layers[1] === pack.variants[snapshot.current].body[f], "next entry behind current corpse and hero")
            } else { check(layers.count == 1 && layers[0] === pack.variants[snapshot.current].full[f], "current full strip before tail") }
        }
        let reserved = snapshot.incoming
        snapshot = sample(transitionBank, pack, 37 * 0.08)
        check(snapshot.current == reserved && snapshot.frame == 0 && snapshot.cycle == 1, "native clock commits reserved cast at wrap")
        try loader()
        print("PASS: PetRotationChecks \(checks) assertions; 9000 loops; real scheduler, clock, layer selector, loader and legacy fallback")
    }
    static func loader() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pet-rotation-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("r"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bmp.representation(using: .png, properties: [:])!
        let m = manifest(handoff: 3)
        for v in m.variants { for file in [v.file,v.bodyFile,v.entryFile] { try png.write(to: root.appendingPathComponent(file)) } }
        try png.write(to: root.appendingPathComponent("duel.png"))
        let rotation = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m))
        func write(_ value: Any?, frames: Int = 4) throws {
            var row: [String: Any] = ["file":"duel.png","frames":frames]
            if let value { row["rotation"] = value }
            try JSONSerialization.data(withJSONObject: ["poses":["duel":row]]).write(to: root.appendingPathComponent(PetSpriteStore.stateFileName))
        }
        try write(rotation)
        let loaded = PetSpriteStore.loadRotations(in: root)
        check(loaded[.duel]?.variants.count == 3 && loaded[.duel]?.frames == 4, "valid optional rotation loaded")
        check(loaded[.duel]?.fingerprint == PetSpriteStore.loadRotations(in: root)[.duel]?.fingerprint, "reload fingerprint stable")
        PetSpriteStore.setFrames(.duel, frames: 4, in: root)
        check(PetSpriteStore.loadRotations(in: root)[.duel] != nil, "unchanged frame setting preserves rotation")
        PetSpriteStore.setFrames(.duel, frames: 2, in: root)
        check(PetSpriteStore.loadRotations(in: root).isEmpty, "frame override retires incompatible rotation")
        try write("invalid scalar")
        check(PetSpriteStore.loadRotations(in: root).isEmpty, "scalar rotation safely rejected")
        try write(nil)
        check(PetSpriteStore.loadRotations(in: root).isEmpty, "legacy manifest valid without rotations")
        try write(rotation)
        try fm.removeItem(at: root.appendingPathComponent(m.variants[1].entryFile))
        check(PetSpriteStore.loadRotations(in: root).isEmpty, "missing one layer falls back whole pose")
        try png.write(to: root.appendingPathComponent(m.variants[1].entryFile))
        var invalid = m; invalid.variants[0].entryFile = "../outside.png"
        check(!invalid.isValid(frames: 4), "path traversal rejected")
        invalid = m; invalid.variants[1].id = invalid.variants[0].id
        check(!invalid.isValid(frames: 4), "duplicate cast rejected")
        invalid = m; invalid.version = 2
        check(!invalid.isValid(frames: 4), "unknown version rejected")
        invalid = m; invalid.handoffFrame = 5
        check(!invalid.isValid(frames: 4), "bad handoff rejected")
        try write(rotation, frames: 3)
        check(PetSpriteStore.loadRotations(in: root).isEmpty, "non-integral frame dimensions rejected")
        try write(rotation)
        try fm.removeItem(at: root.appendingPathComponent(m.variants[0].bodyFile))
        try fm.createSymbolicLink(at: root.appendingPathComponent(m.variants[0].bodyFile), withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("outside.png"))
        check(PetSpriteStore.loadRotations(in: root).isEmpty, "outside-root symlink rejected")
    }
}
