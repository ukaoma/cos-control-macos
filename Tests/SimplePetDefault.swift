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
            // 0.5.325: Miles ships V14 timing-v2 with three casts on Sessions 2 to 4, so he renders here too.
            do {
                let proof = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
                try FileManager.default.createDirectory(at: proof, withIntermediateDirectories: true)
                for pose in [PetSpritePose.duel, .trio, .swarm] {
                    let rotation = model.petSpriteKit.rotations[pose]!
                    precondition(rotation.variants.count == 3)
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

        // 0.5.325 (Miles's V14 reverted to the shipped pack twice on 2026-10-18): an installed V14, in the flat form this
        // release ships and in the rotation/v14-timing-v2/ form on Miles's Mac, survives every launch path this model
        // runs: a first launch of a new build (no art generation), a launch after 0.5.324 (generation 21), and repeat
        // launches. Nothing in the folder is written: same bytes, same modification dates.
        let fm = FileManager.default
        let miles = PetSpriteStore.bundledDefaultURL()!
        let layers = Set(PetSpriteStore.loadRotations(in: miles).values.flatMap { $0.manifest.variants.flatMap { [$0.file, $0.bodyFile, $0.entryFile] } })
        precondition(layers.count == 27, "the bundled V14 declares 27 cast layers")
        let prefix = "session-pet-windu-v14-timing-v2-"
        func install(subfolder: Bool, tuned: Bool) throws {
            model.resetPetSprite()
            for file in Set(PetSpriteStore.loadStateMap(in: miles).values.map(\.file)) {
                try fm.copyItem(at: miles.appendingPathComponent(file), to: directory.appendingPathComponent(file))
            }
            var text = try String(contentsOf: miles.appendingPathComponent(PetSpriteStore.stateFileName), encoding: .utf8)
            if subfolder {
                try fm.createDirectory(at: directory.appendingPathComponent("rotation/v14-timing-v2"), withIntermediateDirectories: true)
                for file in layers {
                    try fm.copyItem(at: miles.appendingPathComponent(file),
                                    to: directory.appendingPathComponent("rotation/v14-timing-v2/" + file.dropFirst(prefix.count)))
                }
                text = text.replacingOccurrences(of: "\"" + prefix, with: "\"rotation/v14-timing-v2/")
            } else {
                for file in layers { try fm.copyItem(at: miles.appendingPathComponent(file), to: directory.appendingPathComponent(file)) }
            }
            if tuned { text = text.replacingOccurrences(of: "\"interval\": 0.18", with: "\"interval\": 0.2") }
            try Data(text.utf8).write(to: directory.appendingPathComponent(PetSpriteStore.stateFileName))
        }
        func state() -> [String: (Data, Date)] {
            var out: [String: (Data, Date)] = [:]
            for url in fm.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])!.compactMap({ $0 as? URL })
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out[url.path] = (try! Data(contentsOf: url), try! url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!)
            }
            return out
        }
        for (subfolder, tuned) in [(true, false), (false, false), (true, true)] {
            try install(subfolder: subfolder, tuned: tuned)
            let before = state()
            Thread.sleep(forTimeInterval: 1.1) // a rewrite would carry a later modification date
            for generation in [nil, 21, 22] as [Int?] {
                if let generation { UserDefaults.standard.set(generation, forKey: "cos.sessionPetDefaultArtGeneration") }
                else { UserDefaults.standard.removeObject(forKey: "cos.sessionPetDefaultArtGeneration") }
                UserDefaults.standard.removeObject(forKey: "cos.sessionPetDefaultSeeded")
                model.loadPetSprite()
                let after = state()
                precondition(after.count == before.count && after.allSatisfy { path, entry in
                    before[path].map { $0.0 == entry.0 && $0.1 == entry.1 } ?? false
                }, "a launch rewrote the installed V14 (subfolder \(subfolder), tuned \(tuned), generation \(String(describing: generation)))")
                precondition(model.petSpriteKit.rotations.count == 3 && model.petSpriteKit.rotations.values.allSatisfy { $0.variants.count == 3 },
                             "the installed V14 plays its three casts")
            }
            print("PASS: installed V14 (\(subfolder ? "rotation/ subfolder" : "flat")\(tuned ? ", tuned" : "")) survives first launch, a 0.5.324 launch and a repeat launch untouched")
        }
        model.resetPetSprite()
    }
}
