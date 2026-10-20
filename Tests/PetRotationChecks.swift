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
              })
    }
    static func sample(_ bank: PetEncounterPlayback, _ art: PetEncounterRotation, _ time: Double, speed: Double = 1, paused: Bool = false, pose: PetSpritePose = .duel) -> PetEncounterPlayback.Snapshot {
        bank.sample(pose: pose, rotation: art, now: time, speed: speed, interval: 0.08, paused: paused)!
    }
    static func main() throws {
        for (frames, handoff) in [(37,28),(43,31),(64,55),(78,61),(82,65),(88,71),(128,111)] {
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
        let ctx = CGContext(data: nil, width: 12, height: 6, bitsPerComponent: 8, bytesPerRow: 48,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for f in 0..<3 {
            ctx.setFillColor(CGColor(red: f == 1 ? 0 : 1, green: 0.3, blue: 0.6, alpha: 0.6))
            ctx.fill(CGRect(x: f * 4, y: 1, width: 3, height: 2))
            ctx.setFillColor(CGColor(red: 0.1, green: 0.9, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: f * 4 + 2, y: 4, width: 1, height: 1))
        }
        let cg = ctx.makeImage()!
        var cache: [String: NSImage] = [:]
        let compact = PetSpriteStrip.sliceCompact(cg, frames: 3, cache: &cache)
        let legacy = PetSpriteStrip.slice(NSImage(cgImage: cg, size: NSSize(width: 12, height: 6)), frames: 3)
        func pixels(_ image: NSImage) -> Data {
            let raster = PetSpriteStrip.raster(image)!
            let c = CGContext(data: nil, width: 4, height: 6, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(raster, in: CGRect(x: 0, y: 0, width: 4, height: 6))
            return Data(bytes: c.data!, count: 96)
        }
        for i in 0..<3 {
            check(pixels(compact[i]) == pixels(legacy[i]),
                  "compact slicing preserves orientation, color, alpha and transparent margins")
        }
        check(cache.count == 2 && compact[0] === compact[2] && compact[0] !== compact[1], "equal cells share storage; different cells remain distinct")
        let again = PetSpriteStrip.sliceCompact(cg, frames: 3, cache: &cache)
        check(again[1] === compact[1], "identical body/full cells across layers share storage")
        try loader()
        try retina()
        try memoryRelease()
        print("PASS: PetRotationChecks \(checks) assertions; 21000 loops; real scheduler, clock, layer selector, loader and legacy fallback")
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
        // 0.5.328 (Version 15): Session 1 rotates casts. The same rows under working, idle and duel: working and duel load,
        // idle never does (only the four session poses carry casts).
        try JSONSerialization.data(withJSONObject: ["poses": ["working": ["file": "duel.png", "frames": 4, "rotation": rotation],
                                                              "idle": ["file": "duel.png", "frames": 4, "rotation": rotation]]])
            .write(to: root.appendingPathComponent(PetSpriteStore.stateFileName))
        let session1 = PetSpriteStore.loadRotations(in: root)
        check(session1[.working]?.variants.count == 3 && session1[.working]?.frames == 4 && session1[.idle] == nil && session1.count == 1,
              "Session 1 (working) casts load; idle casts do not")
        // The live pet asks for one pose at a time (0.5.328 memory gate): `only` decodes that pose and nothing else.
        try JSONSerialization.data(withJSONObject: ["poses": ["working": ["file": "duel.png", "frames": 4, "rotation": rotation],
                                                              "duel": ["file": "duel.png", "frames": 4, "rotation": rotation]]])
            .write(to: root.appendingPathComponent(PetSpriteStore.stateFileName))
        check(PetSpriteStore.loadRotations(in: root).count == 2
                && Array(PetSpriteStore.loadRotations(in: root, only: [.working]).keys) == [.working]
                && PetSpriteStore.loadRotations(in: root, only: [.idle]).isEmpty,
              "only: decodes the asked pose alone")
        check(PetSpriteStore.castPoses(in: root) == [.working, .duel], "cast poses are read from the map without decoding")
        try write(rotation)
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

    /// A strip of `frames` cells of `cell` px, each cell one flat colour: red channel = 40 * (first + index) + 20.
    static func strip(frames: Int, cell: Int, first: Int = 0, height: Int? = nil) -> Data {
        let bmp = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: frames * cell, pixelsHigh: height ?? cell, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<(frames * cell) {
            for y in 0..<(height ?? cell) {
                bmp.setColor(NSColor(deviceRed: CGFloat(40 * (first + x / cell) + 20) / 255, green: 0.2, blue: 0.3, alpha: 1), atX: x, y: y)
            }
        }
        return bmp.representation(using: .png, properties: [:])!
    }

    /// The red of a cell's centre pixel, read from its pixels (not its point size), and its pixel width.
    static func probe(_ image: NSImage) -> (red: Int, pixels: Int) {
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (Int(px[(cg.height / 2 * cg.width + cg.width / 2) * 4]), cg.width)
    }

    static func footprintMB() -> Double {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        precondition(ok == 0)
        return Double(info.ri_phys_footprint) / 1_048_576
    }

    /// 0.5.328 memory gate: the live pet decodes one state's casts at a time and drops them on a state change, so a
    /// dropped cast must give its memory back. Cells were malloc'd and freed into malloc's small region, which stayed
    /// resident (Version 15 swarm at 2x: 303 MB loaded, still 303 MB after the release). 54 distinct 600x512 cells
    /// (about 63 MB) are loaded and dropped three times; the process must end within 12 MB of where it began.
    static func memoryRelease() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pet-release-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let (w, h, frames) = (600, 512, 6)
        func strip(_ seed: Int) -> Data {
            let ctx = CGContext(data: nil, width: w * frames, height: h, bitsPerComponent: 8, bytesPerRow: w * frames * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for f in 0..<frames {
                ctx.setFillColor(red: CGFloat((seed * 7 + f * 13) % 255) / 255, green: CGFloat((seed * 3 + f) % 255) / 255, blue: 0.4, alpha: 1)
                ctx.fill(CGRect(x: f * w, y: 0, width: w, height: h))
            }
            return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        }
        var variants: [[String: String]] = []
        for v in 0..<3 {
            var row = ["id": "duel-\(v)"]
            for (k, key) in ["file", "bodyFile", "entryFile"].enumerated() {
                let name = "c\(v)-\(key).png"
                try strip(v * 3 + k + 1).write(to: root.appendingPathComponent(name))
                row[key] = name
            }
            variants.append(row)
        }
        try strip(0).write(to: root.appendingPathComponent("pose.png"))
        let map: [String: Any] = ["poses": ["duel": ["file": "pose.png", "frames": frames, "rotation": ["version": 1, "handoffFrame": 4, "variants": variants]]]]
        try JSONSerialization.data(withJSONObject: map).write(to: root.appendingPathComponent(PetSpriteStore.stateFileName))
        let before = footprintMB()
        autoreleasepool { _ = PetSpriteStore.loadRotations(in: root, only: [.duel]) } // first load: one-time framework setup counts too
        var loadedPeak = 0.0
        for _ in 0..<3 {
            autoreleasepool {
                let loaded = PetSpriteStore.loadRotations(in: root, only: [.duel])
                check(loaded[.duel]?.variants.count == 3, "the release test's casts load")
                loadedPeak = max(loadedPeak, footprintMB() - before)
            }
        }
        let after = footprintMB() - before
        check(loadedPeak > 40, "the release test holds its casts while loaded (\(Int(loadedPeak)) MB)")
        check(after < 12, "dropped casts give their memory back (\(Int(after)) MB still held after three loads)")
        // 0.5.329 use-after-free sample: a cell the view still holds when its state's casts are dropped keeps its own
        // pages. Cells are mapped and unmapped by their data provider; an early unmap would crash or read zeros here.
        // Three sampled cells outlive their load, two more loads churn the freed pages, then each is read and compared
        // with a fresh decode of the same cell.
        func cell(_ loaded: [PetSpritePose: PetEncounterRotation], _ v: Int, _ layer: Int, _ f: Int) -> NSImage {
            let variant = loaded[.duel]!.variants[v]
            return [variant.full, variant.body, variant.entry][layer][f]
        }
        let picks = [(0, 0, 0), (1, 1, 3), (2, 2, 5)]
        let held = autoreleasepool { picks.map { cell(PetSpriteStore.loadRotations(in: root, only: [.duel]), $0.0, $0.1, $0.2) } }
        for _ in 0..<2 { autoreleasepool { _ = PetSpriteStore.loadRotations(in: root, only: [.duel]) } }
        autoreleasepool {
            let fresh = PetSpriteStore.loadRotations(in: root, only: [.duel])
            for (i, pick) in picks.enumerated() {
                let want = probe(cell(fresh, pick.0, pick.1, pick.2)), got = probe(held[i])
                check(got.pixels == w && got.red == want.red && want.red > 0,
                      "a cell held past its state's release keeps its pixels (cast \(pick.0) layer \(pick.1) frame \(pick.2))")
            }
        }
    }

    /// 0.5.328 (Version 15): retina strips. A 4-frame pose of 4x4 px cells at 1x carries 8x8 px cells at 2x, split into
    /// two ordered segments of two cells. On a 2x display every cell is the 1x cell's point size with twice the pixels,
    /// in segment order; on a 1x display, or when a segment is wrong, the 1x cells play.
    static func retina() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pet-retina-test-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func write(_ name: String, _ data: Data) throws { try data.write(to: root.appendingPathComponent(name)) }
        try write("one.png", strip(frames: 4, cell: 4))
        try write("two-s1.png", strip(frames: 2, cell: 8, first: 0))
        try write("two-s2.png", strip(frames: 2, cell: 8, first: 2))
        let cast = ["id": "duel-a", "file": "one.png", "bodyFile": "one.png", "entryFile": "one.png"]
        let cast2 = ["id": "duel-b", "file": "one.png", "bodyFile": "one.png", "entryFile": "one.png"]
        let segments = ["two-s1.png", "two-s2.png"]
        func map(retinaSegments: [String] = segments, scale: Int = 2) throws {
            let retinaCast = { (id: String) in ["id": id, "file": retinaSegments, "bodyFile": retinaSegments, "entryFile": retinaSegments] as [String: Any] }
            let poses: [String: Any] = [
                "duel": ["file": "one.png", "frames": 4, "interval": 0.08,
                         "rotation": ["version": 1, "handoffFrame": 3, "variants": [cast, cast2]],
                         "retina": ["scale": scale, "file": retinaSegments, "variants": [retinaCast("duel-a"), retinaCast("duel-b")]]],
                "attention": ["file": "one.png", "frames": 4, "interval": 0.12, "retina": ["scale": scale, "file": retinaSegments]],
            ]
            try JSONSerialization.data(withJSONObject: ["poses": poses]).write(to: root.appendingPathComponent(PetSpriteStore.stateFileName))
        }
        func expectCells(_ cells: [NSImage]?, pixels: Int, _ name: String) {
            guard let cells else { return check(false, name) }
            check(cells.count == 4 && cells.allSatisfy { $0.size == NSSize(width: 4, height: 4) }, "\(name): four cells at the 1x point size")
            check(cells.map { probe($0).pixels } == Array(repeating: pixels, count: 4), "\(name): \(pixels) px per cell")
            check(cells.map { probe($0).red } == [20, 60, 100, 140], "\(name): cells in strip and segment order")
        }
        try map()
        let state = PetSpriteStore.loadStateMap(in: root)
        for (scale, pixels) in [(CGFloat(1), 4), (2, 8), (3, 8)] {
            expectCells(PetSpriteStore.loadRotations(in: root, displayScale: scale)[.duel]?.variants[1].body, pixels: pixels,
                        "rotation at display scale \(scale)")
            expectCells(PetSpriteStore.loadPoseFrames(in: root, stateMap: state, displayScale: scale)[.attention], pixels: pixels,
                        "plain strip at display scale \(scale)")
        }
        check(PetSpriteStore.loadRotations(in: root, displayScale: 1)[.duel]?.fingerprint
                != PetSpriteStore.loadRotations(in: root, displayScale: 2)[.duel]?.fingerprint,
              "switching strip sets restarts the encounter state (new fingerprint)")
        // Every broken retina block falls back to the 1x strip; the pose never disappears.
        // Each bad segment breaks exactly one rule (a mutation run found the old 6x6 fixture broke two, so neither the height
        // nor the cell-boundary rule was ever reached): short.png has 8 px cells but 6 px rows; narrow.png has 8 px rows and
        // is 20 px wide, two whole cells and half of one, so only the cell-boundary rule refuses it.
        try write("short.png", strip(frames: 2, cell: 8, first: 2, height: 6))
        try write("narrow.png", strip(frames: 2, cell: 10, first: 2, height: 8))
        for (name, segs, scale) in [("segments out of order", ["two-s2.png", "two-s1.png"], 2), ("a missing segment", ["two-s1.png", "gone.png"], 2),
                                    ("one segment only", ["two-s1.png"], 2), ("a segment of the wrong height", ["two-s1.png", "short.png"], 2),
                                    ("a segment not cut at the cell", ["two-s1.png", "narrow.png"], 2),
                                    ("an undefined scale", segments, 3), ("a path outside the folder", ["../two-s1.png", "two-s2.png"], 2)] {
            try map(retinaSegments: segs, scale: scale)
            let rows = PetSpriteStore.loadStateMap(in: root)
            if name == "segments out of order" {
                // Order is the map's, not the file names': the cells follow the segments as listed.
                check(PetSpriteStore.loadPoseFrames(in: root, stateMap: rows, displayScale: 2)[.attention]?.map { probe($0).red } == [100, 140, 20, 60],
                      "segments play in map order")
                continue
            }
            expectCells(PetSpriteStore.loadRotations(in: root, displayScale: 2)[.duel]?.variants[0].full, pixels: 4, "\(name): rotation keeps 1x")
            expectCells(PetSpriteStore.loadPoseFrames(in: root, stateMap: rows, displayScale: 2)[.attention], pixels: 4, "\(name): plain strip keeps 1x")
        }
        // A settings write keeps the retina block with its art; another frame count retires it with the rotation.
        try map()
        PetSpriteStore.setFrames(.attention, frames: 4, in: root)
        check(PetSpriteStore.loadPoseFrames(in: root, stateMap: PetSpriteStore.loadStateMap(in: root), displayScale: 2)[.attention]?
                .first.map { probe($0).pixels } == 8, "an unchanged frame count keeps the retina strip")
        PetSpriteStore.setFrames(.attention, frames: 2, in: root)
        let after = (try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(PetSpriteStore.stateFileName))) as! [String: Any])["poses"] as! [String: [String: Any]]
        check(after["attention"]?["retina"] == nil && after["duel"]?["retina"] != nil, "another frame count retires that pose's retina strip only")
    }
}
