import AppKit
import SwiftUI

// Runs only in a disposable home. Never shows a window or starts background work.
@main @MainActor struct SimplePetDefault {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        precondition(NSHomeDirectory().contains("cos-simple-pet-test"))
        let directory = PetSpriteStore.supportDirectory()
        precondition(directory.path.hasPrefix(NSHomeDirectory() + "/"))
        let bundled = Bundle.main.resourceURL!.appendingPathComponent("StarterPet/cloud-puff.webp")
        let expected = try Data(contentsOf: bundled)
        let installed = directory.appendingPathComponent("\(PetSpriteStore.fileStem).webp")
        // CLI test binaries can share a preferences domain across disposable
        // homes through cfprefsd. Explicitly start this test's domain fresh.
        precondition(Bundle.main.bundleIdentifier != "com.gotcos.control")
        UserDefaults.standard.removeObject(forKey: "cos.sessionPetDefaultSeeded")
        UserDefaults.standard.removeObject(forKey: "cos.sessionPetDefaultArtGeneration")
        let model = ControllerModel(startBackgroundWork: false)
        model.loadPetSprite() // the no-background initializer intentionally skips startup work
        precondition(model.petCustomSprite != nil && (try! Data(contentsOf: installed)) == expected,
                     "fresh setup must install the bundled Cloud Puff without a network request")
        model.loadPetSprite()
        precondition((try! Data(contentsOf: installed)) == expected)
        print("PASS: fresh setup and repeated loading use the exact bundled Cloud Puff")
        model.resetPetSprite()
        model.loadPetSprite()
        precondition(model.petCustomSprite == nil && model.petSpriteKit.frames(for: .idle).isEmpty)
        print("PASS: explicit COS robot choice survives reload")

        for character in PetSpriteStore.bundledCharacters {
            let source = PetSpriteStore.bundledCharacterURL(character)!
            precondition(PetSpriteStore.installDefault(into: directory, from: source))
            let stateURL = directory.appendingPathComponent(PetSpriteStore.stateFileName)
            let before = try Data(contentsOf: stateURL)
            UserDefaults.standard.removeObject(forKey: "cos.sessionPetDefaultSeeded")
            model.loadPetSprite()
            precondition(try! Data(contentsOf: stateURL) == before)
            precondition(!model.petSpriteKit.frames(for: .idle).isEmpty)
            print("PASS: missing seed preference preserves chosen \(character.displayName)")
            // 0.5.328: Miles ships Version 15, four casts on Session 1 and three on Sessions 2 to 4; the other Jedi rotate
            // three casts on Sessions 2 to 4. Every cast-rotating pose renders here through the production view.
            do {
                let proof = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
                let casts: [PetSpritePose: Int] = character.id == PetSpriteStore.legacyDefaultCharacterID
                    ? [.working: 4, .duel: 3, .trio: 3, .swarm: 3] : [.duel: 3, .trio: 3, .swarm: 3]
                precondition(model.petSpriteKit.rotations.mapValues(\.variants.count) == casts,
                             "\(character.id) rotates \(casts), loaded \(model.petSpriteKit.rotations.mapValues(\.variants.count))")
                for pose in [PetSpritePose.working, .duel, .trio, .swarm] where casts[pose] != nil {
                    let rotation = model.petSpriteKit.rotations[pose]!
                    let clock = PetEncounterPlayback(seed: 17)
                    let now = ProcessInfo.processInfo.systemUptime
                    _ = clock.sample(pose: pose, rotation: rotation, now: now, speed: 1, interval: 0.06, paused: false)
                    var end: PetEncounterPlayback.Snapshot?
                    for f in 1..<rotation.frames {
                        end = clock.sample(pose: pose, rotation: rotation, now: now + Double(f)*0.06, speed: 1, interval: 0.06, paused: false)
                    }
                    precondition(end!.frame == rotation.frames - 1)
                    let incoming = end!.incoming
                    let view = SessionPetSprite(working: true, reduceMotion: true,
                        frames: model.petSpriteKit.frames(for: pose), pose: pose,
                        frameInterval: 0.06, size: 120, characterScale: 2,
                        rotation: rotation, encounterPlayback: clock)
                        .frame(width: 440, height: 280).background(Color(nsColor: .windowBackgroundColor))
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 440, height: 280),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: .darkAqua)
                    window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 440, height: 280)
                    for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); host.layoutSubtreeIfNeeded() }
                    host.displayIfNeeded()
                    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])!.write(to: proof.appendingPathComponent("\(character.id)-\(pose.rawValue)-native-tail.png"))
                    window.close()
                    // Reduced-motion drawing must not silently advance the reserved cast.
                    let held = clock.sample(pose: pose, rotation: rotation, now: now + 20, speed: 1, interval: 0.06, paused: true)!
                    precondition(held.frame == end!.frame && held.incoming == incoming)
                    print("PASS: production SessionPetSprite rendered \(character.id)/\(pose.rawValue), \(rotation.frames) frames, held cast continuity")
                }
            }
            model.resetPetSprite()
        }

        let source = PetSpriteStore.bundledDefaultURL()!
        let map = PetSpriteStore.loadStateMap(in: source)
        let custom = try Data(contentsOf: source.appendingPathComponent(map[.idle]!.file))
        let customURL = directory.appendingPathComponent("\(PetSpriteStore.fileStem).png")
        try custom.write(to: customURL)
        UserDefaults.standard.removeObject(forKey: "cos.sessionPetDefaultSeeded")
        model.loadPetSprite()
        precondition(model.petCustomSprite != nil && (try! Data(contentsOf: customURL)) == custom)
        model.restoreDefaultCharacter()
        model.loadPetSprite()
        precondition(model.petCustomSprite != nil && (try! Data(contentsOf: installed)) == expected)
        print("PASS: custom artwork survives loading; explicit restore returns to Cloud Puff")

        model.resetPetSprite()
        UserDefaults.standard.removeObject(forKey: "cos.sessionPetDefaultSeeded")
        let held = bundled.appendingPathExtension("held")
        try FileManager.default.moveItem(at: bundled, to: held)
        model.loadPetSprite()
        precondition(!UserDefaults.standard.bool(forKey: "cos.sessionPetDefaultSeeded"))
        try FileManager.default.moveItem(at: held, to: bundled)
        model.loadPetSprite()
        precondition((try! Data(contentsOf: installed)) == expected)
        print("PASS: missing starter artwork does not consume first-run seeding; retry succeeds")

        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let view = VStack(spacing: 12) {
                SessionPetSprite(working: false, reduceMotion: true, customImage: model.petCustomSprite, size: 88)
                Text("Cloud Puff").font(COSType.display(22))
                Text("Simple default session pet").font(COSType.body(13))
            }.foregroundStyle(.primary).frame(width: 360, height: 200)
                .background(Color(nsColor: .windowBackgroundColor))
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 360, height: 200),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            host.appearance = window.appearance
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 360, height: 200)
            for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let suffix = appearance == .aqua ? "light" : "dark"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("cloud-puff-\(suffix).png"))
            window.close()
        }
        print("PASS: bundled Cloud Puff rendered in light and dark")

        // 0.5.328: an installed stock V14 (both exact forms the stock history names: flat as 0.5.325 to 0.5.327 shipped it,
        // and with its layers under rotation/v14-timing-v2/ as Miles installed it) moves to Version 15 on the first launch
        // of this build after any earlier one (no art generation, 21 or 22). Nothing is deleted: every V14 file stays with
        // its bytes. A V14 with its own speed is the person's pack and stays untouched, and an installed V15 is current.
        let fm = FileManager.default
        let miles = PetSpriteStore.bundledDefaultURL()!
        let bundledMap = PetSpriteStore.loadStateMap(in: miles)
        let bundledRows = (try JSONSerialization.jsonObject(with: Data(contentsOf: miles.appendingPathComponent(PetSpriteStore.stateFileName))) as! [String: Any])["poses"] as! [String: [String: Any]]
        let retinaFiles = Set(bundledRows.values.compactMap { PetRetinaRow($0["retina"]) }.flatMap(\.files))
        let v15Files = Set(bundledMap.values.map(\.file)).union(PetSpriteStore.loadRotations(in: miles).values.flatMap {
            $0.manifest.variants.flatMap { [$0.file, $0.bodyFile, $0.entryFile] } }).union(retinaFiles)
        precondition(v15Files.count == 96, "the bundled Version 15 names 96 files (45 at 1x, 51 retina)")
        let history = (try JSONSerialization.jsonObject(with: Data(contentsOf: miles.appendingPathComponent("stock-state-history.json"))) as! [String: Any])["maps"] as! [[String: Any]]
        precondition(history.count == 3, "V12.6 plus both V14 forms")
        func state() -> [String: (Data, Date)] {
            var out: [String: (Data, Date)] = [:]
            for url in fm.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])!.compactMap({ $0 as? URL })
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out[url.path] = (try! Data(contentsOf: url), try! url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!)
            }
            return out
        }
        func fresh() throws {
            model.resetPetSprite()
            try? fm.removeItem(at: directory)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func launch(_ generation: Int?) {
            if let generation { UserDefaults.standard.set(generation, forKey: "cos.sessionPetDefaultArtGeneration") }
            else { UserDefaults.standard.removeObject(forKey: "cos.sessionPetDefaultArtGeneration") }
            UserDefaults.standard.removeObject(forKey: "cos.sessionPetDefaultSeeded")
            model.loadPetSprite()
        }
        for (form, label) in [(1, "flat"), (2, "rotation/ subfolder")] {
            for tuned in [false, true] {
                for generation in [nil, 21, 22] as [Int?] {
                    try fresh()
                    var v14 = history[form]["state"] as! [String: Any]
                    var poses = v14["poses"] as! [String: [String: Any]]
                    // The four V13 strips and the V12/V14 signal and ambient strips are retained in DefaultPet. V14's cast
                    // layers are not (they no longer ship); the upgrade compares only the pose strips' bytes.
                    for row in poses.values {
                        let file = row["file"] as! String
                        try fm.copyItem(at: miles.appendingPathComponent(file), to: directory.appendingPathComponent(file))
                    }
                    if tuned { poses["waiting"]!["interval"] = 0.2; v14["poses"] = poses }
                    try JSONSerialization.data(withJSONObject: v14, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent(PetSpriteStore.stateFileName))
                    let before = state()
                    Thread.sleep(forTimeInterval: 1.1) // a rewrite would carry a later modification date
                    launch(generation)
                    let after = state()
                    let what = "V14 \(label)\(tuned ? ", tuned" : ""), generation \(String(describing: generation))"
                    if tuned {
                        precondition(after.count == before.count && after.allSatisfy { path, entry in
                            before[path].map { $0.0 == entry.0 && $0.1 == entry.1 } ?? false
                        }, "a launch rewrote the person's tuned \(what)")
                        continue
                    }
                    precondition(before.allSatisfy { path, entry in
                        path.hasSuffix(PetSpriteStore.stateFileName) || after[path]?.0 == entry.0
                    }, "the upgrade deleted or changed a V14 file (\(what))")
                    let installedMap = PetSpriteStore.loadStateMap(in: directory)
                    precondition(installedMap.count == bundledMap.count && bundledMap.allSatisfy { pose, row in
                        installedMap[pose]?.file == row.file && installedMap[pose]?.frames == row.frames
                    }, "\(what) did not move to the V15 map")
                    precondition(v15Files.allSatisfy { file in
                        (try? Data(contentsOf: directory.appendingPathComponent(file))) == (try? Data(contentsOf: miles.appendingPathComponent(file)))
                    }, "\(what): a V15 file did not land byte for byte")
                    precondition(PetSpriteStore.loadFrameIntervals(in: directory) == PetSpriteStore.loadFrameIntervals(in: miles)
                                 && PetSpriteStore.loadRenderScales(in: directory) == PetSpriteStore.loadRenderScales(in: miles),
                                 "\(what): V15 cadence and pack scales")
                    precondition(model.petSpriteKit.rotations.mapValues(\.variants.count) == [.working: 4, .duel: 3, .trio: 3, .swarm: 3],
                                 "\(what) plays four Session 1 casts and three on Sessions 2 to 4")
                    let upgraded = state()
                    Thread.sleep(forTimeInterval: 1.1)
                    launch(nil)
                    launch(22)
                    model.loadPetSprite()
                    let repeated = state()
                    precondition(repeated.count == upgraded.count && repeated.allSatisfy { path, entry in
                        upgraded[path].map { $0.0 == entry.0 && $0.1 == entry.1 } ?? false
                    }, "a later launch rewrote the upgraded V15 (\(what))")
                }
                print("PASS: installed V14 (\(label)\(tuned ? ", tuned: left alone" : "")) \(tuned ? "" : "moves to Version 15 with no file deleted, ")on a first, a post-0.5.324 and a post-0.5.327 launch")
            }
        }
        // An installed Version 15 is current on every launch path: nothing written.
        try fresh()
        for file in v15Files.union([PetSpriteStore.stateFileName]) {
            try fm.copyItem(at: miles.appendingPathComponent(file), to: directory.appendingPathComponent(file))
        }
        let installedV15 = state()
        Thread.sleep(forTimeInterval: 1.1)
        for generation in [nil, 21, 22, 23] as [Int?] {
            launch(generation)
            let after = state()
            precondition(after.count == installedV15.count && after.allSatisfy { path, entry in
                installedV15[path].map { $0.0 == entry.0 && $0.1 == entry.1 } ?? false
            }, "a launch rewrote the installed V15 (generation \(String(describing: generation)))")
            precondition(model.petSpriteKit.rotations.mapValues(\.variants.count) == [.working: 4, .duel: 3, .trio: 3, .swarm: 3])
        }
        print("PASS: installed Version 15 survives first, post-0.5.324, post-0.5.327 and repeat launches untouched")
        // Retina vs 1x display: the same pack, the same point sizes, twice the pixels. A 1x-to-2x screen move re-picks.
        func cellPixels(_ image: NSImage) -> Int {
            var rect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!.width
        }
        var seen: [CGFloat: (sizes: [NSSize], pixels: [Int])] = [:]
        for scale in [CGFloat(1), 2, 1] {
            model.setPetDisplayScale(scale)
            // Cast poses play their casts (checked here); their plain strip stays 1x and only sizes the view.
            let poses: [PetSpritePose] = [.attention, .done, .error]
            let rotationCells = [PetSpritePose.working, .duel, .trio, .swarm].map { model.petSpriteKit.rotations[$0]!.variants[0].full[0] }
            let poseCells = poses.map { model.petSpriteKit.frames(for: $0).first! }
            seen[scale] = ((rotationCells + poseCells).map(\.size), (rotationCells + poseCells).map(cellPixels))
        }
        precondition(seen[1]!.sizes == seen[2]!.sizes, "retina and 1x cells have identical point sizes (the figure does not change size)")
        precondition(zip(seen[1]!.pixels, seen[2]!.pixels).allSatisfy { $1 == 2 * $0 }, "retina cells carry twice the pixels")
        precondition(zip(seen[1]!.sizes, seen[1]!.pixels).allSatisfy { Int($0.width) == $1 }, "1x cells are one pixel per point")
        precondition([PetSpritePose.working, .duel, .trio, .swarm].allSatisfy { pose in
            model.petSpriteKit.frames(for: pose).first.map { cellPixels($0) == Int($0.size.width) } ?? false
        }, "cast poses keep the 1x strip they size the view with")
        print("PASS: Version 15 plays 2x cells on a retina display and 1x cells on a 1x display, at identical point sizes, and re-picks on a screen change")
        model.resetPetSprite()
    }
}
