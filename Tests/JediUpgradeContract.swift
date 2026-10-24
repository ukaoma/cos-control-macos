import AppKit
import Foundation

@main
struct JediUpgradeContract {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let bundles = root.appendingPathComponent("Resources/BundledCharacters")
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("cos-jedi-upgrade-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        func referencedPNGs(_ value: Any) -> Set<String> {
            if let d = value as? [String: Any] { return d.values.reduce(into: Set<String>()) { $0.formUnion(referencedPNGs($1)) } }
            if let a = value as? [Any] { return a.reduce(into: Set<String>()) { $0.formUnion(referencedPNGs($1)) } }
            if let s = value as? String, s.hasSuffix(".png") { return [s] }; return []
        }
        var retinaFiles = 0
        var migrations = 0
        var frames = 0
        var rotationLayers = 0
        for character in PetSpriteStore.bundledCharacters where character.id != PetSpriteStore.legacyDefaultCharacterID {
            try autoreleasepool {
            let source = bundles.appendingPathComponent(character.id)
            let expected = PetSpriteStore.loadStateMap(in: source)
            let sourceState = try Data(contentsOf: source.appendingPathComponent(PetSpriteStore.stateFileName))
            let history = try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("stock-state-history.json"))) as! [String: Any]
            let maps = history["maps"] as! [[String: Any]]
            let fresh = scratch.appendingPathComponent("fresh-\(character.id)")
            precondition(PetSpriteStore.installDefault(into: fresh, from: source), "fresh stock install must succeed")
            for pose in [PetSpritePose.idle, .patrol, .waiting, .working, .duel, .trio, .swarm] {
                let row = expected[pose]!
                let data = try Data(contentsOf: fresh.appendingPathComponent(row.file))
                precondition(data == (try! Data(contentsOf: source.appendingPathComponent(row.file))))
                let slices = PetSpriteStrip.slice(NSImage(data: data)!, frames: row.frames)
                precondition(slices.count == row.frames)
                frames += slices.count
            }
            let rotations = PetSpriteStore.loadRotations(in: fresh)
            precondition(rotations.count == 3, "all three combat states must load rotations")
            let layers = rotations.values.flatMap { rotation in
                precondition(rotation.frames == expected.first(where: { $0.value.frames == rotation.frames })?.value.frames)
                precondition(rotation.variants.count == 3)
                precondition(rotation.variants.allSatisfy { $0.full.count == rotation.frames && $0.body.count == rotation.frames && $0.entry.count == rotation.frames })
                return rotation.manifest.variants.flatMap { [$0.file, $0.bodyFile, $0.entryFile] }
            }
            precondition(layers.count == 27)
            for file in layers {
                precondition(try! Data(contentsOf: fresh.appendingPathComponent(file)) == Data(contentsOf: source.appendingPathComponent(file)))
            }
            rotationLayers += layers.count
            let sourceJSON = try JSONSerialization.jsonObject(with: sourceState)
            let allSourceFiles = referencedPNGs(sourceJSON)
            let retinaSourceFiles = allSourceFiles.filter { $0.contains("-2x-") }
            precondition(retinaSourceFiles.count >= 54, "all segmented Retina casts must ship")
            retinaFiles += retinaSourceFiles.count
            let retinaRotations = PetSpriteStore.loadRotations(in: fresh, displayScale: 2)
            for pose in [PetSpritePose.duel, .trio, .swarm] {
                let image = retinaRotations[pose]!.variants[0].full[0]
                precondition(PetSpriteStrip.raster(image)!.width == 880, "Retina install silently fell back to 1x")
            }
            for entry in maps {
                try autoreleasepool {
                let version = entry["version"] as! String
                let state = entry["state"] as! [String: Any]
                let poses = state["poses"] as! [String: [String: Any]]
                let original = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                let dest = scratch.appendingPathComponent("\(character.id)-\(version)")
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for file in referencedPNGs(poses) {
                    try fm.copyItem(at: source.appendingPathComponent(file), to: dest.appendingPathComponent(file))
                }
                let stateURL = dest.appendingPathComponent(PetSpriteStore.stateFileName)
                try original.write(to: stateURL, options: .atomic)

                // Timing, scale and extra metadata are all user customization.
                for field in ["interval", "renderScale", "customMarker"] {
                    var custom = state
                    var rows = poses
                    rows["idle"]?[field] = field == "customMarker" ? ("keep me" as Any) : (1.75 as Any)
                    custom["poses"] = rows
                    let bytes = try JSONSerialization.data(withJSONObject: custom, options: [.sortedKeys])
                    try bytes.write(to: stateURL, options: .atomic)
                    precondition(PetSpriteStore.refreshRecognizedBundledCharacter(into: dest, sourceRootOverride: bundles) == .notApplicable)
                    precondition(try! Data(contentsOf: stateURL) == bytes, "custom map must survive")
                }
                try original.write(to: stateURL, options: .atomic)
                let oldFile = dest.appendingPathComponent(poses["idle"]!["file"] as! String)
                let oldBytes = try Data(contentsOf: oldFile)
                try Data("user artwork".utf8).write(to: oldFile, options: .atomic)
                precondition(PetSpriteStore.refreshRecognizedBundledCharacter(into: dest, sourceRootOverride: bundles) == .notApplicable)
                precondition(try! Data(contentsOf: stateURL) == original)
                try oldBytes.write(to: oldFile, options: .atomic)

                // A user's alternate cast or high-resolution edit is also custom art.
                for file in referencedPNGs(poses).filter({ $0.contains("body") || $0.contains("-2x") }).sorted().prefix(2) {
                    let url = dest.appendingPathComponent(file), saved = try Data(contentsOf: dest.appendingPathComponent(file))
                    try Data("custom layer".utf8).write(to: url, options: .atomic)
                    precondition(PetSpriteStore.refreshRecognizedBundledCharacter(into: dest, sourceRootOverride: bundles) == .notApplicable,
                                 "custom alternate/Retina layer was overwritten")
                    precondition(try! Data(contentsOf: stateURL) == original)
                    try saved.write(to: url, options: .atomic)
                }

                // New-file failures leave the old map intact. Map-only upgrades
                // already have this file and do not take the new-file write path.
                if !referencedPNGs(poses).contains(expected[.patrol]!.file) {
                    let blocked = dest.appendingPathComponent(expected[.patrol]!.file)
                    try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
                    let blockedResult = PetSpriteStore.refreshRecognizedBundledCharacter(into: dest, sourceRootOverride: bundles)
                    precondition(blockedResult == .failed, "\(character.id)/\(version) must report the blocked destination")
                    precondition(try! Data(contentsOf: stateURL) == original, "failed write changed active map")
                    precondition(try! Data(contentsOf: oldFile) == oldBytes, "failed write damaged retained art")
                    try fm.removeItem(at: blocked)
                }

                precondition(PetSpriteStore.refreshRecognizedBundledCharacter(into: dest, sourceRootOverride: bundles) == .refreshed(character.id))
                precondition(try! Data(contentsOf: stateURL) == sourceState)
                for file in allSourceFiles {
                    precondition(try! Data(contentsOf: dest.appendingPathComponent(file)) == Data(contentsOf: source.appendingPathComponent(file)), "migration omitted a rotation layer")
                }
                for row in expected.values {
                    precondition(try! Data(contentsOf: dest.appendingPathComponent(row.file)) == Data(contentsOf: source.appendingPathComponent(row.file)))
                }
                precondition(PetSpriteStore.refreshRecognizedBundledCharacter(into: dest, sourceRootOverride: bundles) == .notApplicable, "repeat migration must be a no-op")
                migrations += 1
                }
            }

            // Corrupt replacement source: preflight must fail before map writes.
            let badRoot = scratch.appendingPathComponent("bad-\(character.id)")
            try fm.createDirectory(at: badRoot, withIntermediateDirectories: true)
            let bad = badRoot.appendingPathComponent(character.id)
            try fm.copyItem(at: source, to: bad)
            // Missing entry layer must fail before activating the new map.
            try fm.removeItem(at: bad.appendingPathComponent(rotations[.swarm]!.manifest.variants[1].entryFile))
            let oldState = maps.first!["state"] as! [String: Any]
            let oldRows = oldState["poses"] as! [String: [String: Any]]
            let dest = scratch.appendingPathComponent("missing-\(character.id)")
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for file in Set(oldRows.values.map { $0["file"] as! String }) {
                try fm.copyItem(at: source.appendingPathComponent(file), to: dest.appendingPathComponent(file))
            }
            let original = try JSONSerialization.data(withJSONObject: oldState, options: [.sortedKeys])
            let stateURL = dest.appendingPathComponent(PetSpriteStore.stateFileName)
            try original.write(to: stateURL, options: .atomic)
            precondition(PetSpriteStore.refreshRecognizedBundledCharacter(into: dest, sourceRootOverride: badRoot) == .failed)
            precondition(try! Data(contentsOf: stateURL) == original)
            let missingEntry = rotations[.swarm]!.manifest.variants[1].entryFile
            try fm.copyItem(at: source.appendingPathComponent(missingEntry), to: bad.appendingPathComponent(missingEntry))
            let missingRetina = retinaSourceFiles.sorted().last!
            try fm.removeItem(at: bad.appendingPathComponent(missingRetina))
            precondition(PetSpriteStore.refreshRecognizedBundledCharacter(into: dest, sourceRootOverride: badRoot) == .failed,
                         "missing Retina segment must fail before activation")
            precondition(try! Data(contentsOf: stateURL) == original)
        }
        }
        precondition(migrations == 22 && frames == 800 && rotationLayers == 81)
        print("Jedi upgrade contracts PASS: 22 stock histories, 800 native frames, \(retinaFiles) Retina files, 81 rotation layers, custom preservation, interrupted new-file writes, missing-source failure, retry and idempotence")
    }
}
