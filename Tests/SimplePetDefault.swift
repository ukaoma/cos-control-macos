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
    }
}
