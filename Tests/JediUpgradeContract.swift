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
        var migrations = 0
        var frames = 0
        for character in PetSpriteStore.bundledCharacters where character.id != PetSpriteStore.defaultCharacterID {
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
            for entry in maps {
                let version = entry["version"] as! String
                let state = entry["state"] as! [String: Any]
                let poses = state["poses"] as! [String: [String: Any]]
                let original = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
                let dest = scratch.appendingPathComponent("\(character.id)-\(version)")
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for file in Set(poses.values.map { $0["file"] as! String }) {
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

                // New-file failures leave the old map intact. Map-only upgrades
                // already have this file and do not take the new-file write path.
                if !Set(poses.values.map { $0["file"] as! String }).contains(expected[.patrol]!.file) {
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
                for row in expected.values {
                    precondition(try! Data(contentsOf: dest.appendingPathComponent(row.file)) == Data(contentsOf: source.appendingPathComponent(row.file)))
                }
                precondition(PetSpriteStore.refreshRecognizedBundledCharacter(into: dest, sourceRootOverride: bundles) == .notApplicable, "repeat migration must be a no-op")
                migrations += 1
            }

            // Corrupt replacement source: preflight must fail before map writes.
            let badRoot = scratch.appendingPathComponent("bad-\(character.id)")
            try fm.createDirectory(at: badRoot, withIntermediateDirectories: true)
            let bad = badRoot.appendingPathComponent(character.id)
            try fm.copyItem(at: source, to: bad)
            try fm.removeItem(at: bad.appendingPathComponent(expected[.swarm]!.file))
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
        }
        precondition(migrations == 16 && frames == 271)
        print("Jedi upgrade contracts PASS: 16 stock histories, 271 native frames, custom preservation, interrupted new-file writes, missing-source failure, retry and idempotence")
    }
}
