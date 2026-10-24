import AppKit
import Foundation

@main
struct JediV2MigrationCheck {
    struct Failure: Error { let reason: String }
    static func require(_ ok: Bool, _ why: String) throws { if !ok { throw Failure(reason: why) } }
    static func files(_ value: Any) -> Set<String> {
        if let d = value as? [String: Any] { return d.values.reduce(into: Set<String>()) { $0.formUnion(files($1)) } }
        if let a = value as? [Any] { return a.reduce(into: Set<String>()) { $0.formUnion(files($1)) } }
        if let s = value as? String, s.hasSuffix(".png") { return [s] }; return []
    }
    static func main() {
        do { try autoreleasepool { try run() }; print("PASS Jedi V2 migration: Retina transaction, layer customization, retry, idempotence") }
        catch { fputs("FAIL Jedi V2 migration: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = root.appendingPathComponent("Resources/BundledCharacters/jedi-nia-solari")
        let scratch = fm.temporaryDirectory.appendingPathComponent("jedi-v2-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let bundles = scratch.appendingPathComponent("bundles")
        try fm.createDirectory(at: bundles, withIntermediateDirectories: true)
        let candidate = bundles.appendingPathComponent("jedi-nia-solari")
        try fm.copyItem(at: source, to: candidate)
        let old = (try JSONSerialization.jsonObject(with: Data(contentsOf: source.appendingPathComponent("stock-state-history.json"))) as! [String: Any])["maps"] as! [[String: Any]]
        let previous = old.last!["state"] as! [String: Any]
        let previousBytes = try JSONSerialization.data(withJSONObject: previous, options: [.sortedKeys])
        let dest = scratch.appendingPathComponent("active")
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        for file in files(previous) { try fm.copyItem(at: source.appendingPathComponent(file), to: dest.appendingPathComponent(file)) }
        let state = dest.appendingPathComponent(PetSpriteStore.stateFileName)
        try previousBytes.write(to: state)
        let body = files(previous).filter { $0.contains("body") }.sorted().last!
        let bodyURL = dest.appendingPathComponent(body), bodyBytes = try Data(contentsOf: bodyURL)
        try Data("user-edited alternate cast".utf8).write(to: bodyURL)
        try require(PetSpriteStore.refreshRecognizedBundledCharacter(into: dest, sourceRootOverride: bundles) == .notApplicable,
                    "custom alternate layer overwritten")
        try require(Data(contentsOf: state) == previousBytes, "custom map changed")
        try bodyBytes.write(to: bodyURL)
        let newBytes = try Data(contentsOf: source.appendingPathComponent(PetSpriteStore.stateFileName))
        let newState = try JSONSerialization.jsonObject(with: newBytes)
        let retina = files(newState).filter { $0.contains("-2x-") }.sorted().last!
        let retinaURL = candidate.appendingPathComponent(retina), retinaBytes = try Data(contentsOf: retinaURL)
        try fm.removeItem(at: retinaURL)
        try require(PetSpriteStore.refreshRecognizedBundledCharacter(into: dest, sourceRootOverride: bundles) == .failed,
                    "missing Retina accepted")
        try require(Data(contentsOf: state) == previousBytes, "failed preflight activated map")
        try retinaBytes.write(to: retinaURL)
        try require(PetSpriteStore.refreshRecognizedBundledCharacter(into: dest, sourceRootOverride: bundles) == .refreshed("jedi-nia-solari"), "complete retry failed")
        try require(Data(contentsOf: state) == newBytes, "new map missing")
        for file in files(newState) {
            try require(Data(contentsOf: dest.appendingPathComponent(file)) == Data(contentsOf: source.appendingPathComponent(file)), "layer not copied: \(file)")
        }
        try require(PetSpriteStore.refreshRecognizedBundledCharacter(into: dest, sourceRootOverride: bundles) == .notApplicable, "repeat migration rewrote current pack")
    }
}
