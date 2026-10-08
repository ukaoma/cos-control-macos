import Foundation

// QA 2026-10-08 B1: the session pet introduction never showed, because the character-scale migration writes
// cos.sessionPetCharacterPercent on every first launch and that key counted as "the person changed a pet setting".
// This runs the REAL migration (PetCharacterScale.loadPersistedPercent, Sources/Models.swift) on a fresh defaults
// suite with ControllerModel's own keys, then asks PetIntro. Nothing is shown.

@main
struct PetIntroMigrationCheck {
    static func main() {
        let name = "cos.pet-intro-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        _ = PetCharacterScale.loadPersistedPercent(defaults: defaults, percentKey: "cos.sessionPetCharacterPercent",
                                                   generationKey: "cos.sessionPetCharacterScaleGeneration", generation: 2)
        var failed: [String] = []
        if defaults.object(forKey: "cos.sessionPetCharacterPercent") == nil {
            failed.append("the migration no longer writes its key, so this check proves nothing: update it")
        }
        if !PetIntro.shouldShow(seen: false, touchedKeys: PetIntro.touchedCount(defaults), petEnabled: true) {
            failed.append("after the first-launch migration the pet introduction is hidden (touched \(PetIntro.touchedCount(defaults)))")
        }
        defaults.set(true, forKey: "cos.sessionPetCalmMotion")
        if PetIntro.shouldShow(seen: false, touchedKeys: PetIntro.touchedCount(defaults), petEnabled: true) {
            failed.append("someone who chose Calm still gets the introduction")
        }
        defaults.removePersistentDomain(forName: name)
        if !failed.isEmpty {
            FileHandle.standardError.write(Data(("check failed [pet intro migration]: " + failed.joined(separator: "; ") + "\n").utf8))
            exit(1)
        }
        print("pet intro migration check: 3 passed (shows after the real first-launch migration; hides for a person's choice)")
    }
}
