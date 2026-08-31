import AppKit
import Foundation

@main
struct JediGalleryContract {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func rgba(_ image: NSImage) throws -> (Int, Int, [UInt8]) {
        guard let cg = PetSpriteStrip.raster(image) else {
            throw Failure(description: "Thumbnail has no raster")
        }
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        return (cg.width, cg.height, bytes)
    }

    static func visible(_ bytes: [UInt8]) -> Int {
        stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 16 }.count
    }

    static func main() throws {
        // Accept the actual Resources directory, including a downloaded/installed app.
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("cos-gallery-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        var thumbnails: [(String, NSImage)] = []
        var oldBlankCount = 0
        for character in PetSpriteStore.bundledCharacters {
            let folder = resources.appendingPathComponent(character.folderName)
            let row = PetSpriteStore.loadStateMap(in: folder)[.idle]!
            guard let thumb = PetSpriteStore.galleryThumbnail(in: folder) else {
                throw Failure(description: "\(character.id): missing gallery thumbnail")
            }
            let actual = try rgba(thumb)
            let strip = NSImage(data: try Data(contentsOf: folder.appendingPathComponent(row.file)))!
            let expected = try rgba(PetSpriteStrip.slice(strip, frames: row.frames).first!)
            try check(actual.0 == expected.0 && actual.1 == expected.1 && actual.2 == expected.2,
                "\(character.id): gallery must show the first DECLARED idle frame")
            let pixels = visible(actual.2)
            try check(pixels > 100, "\(character.id): invisible gallery thumbnail")

            // Reproduce the shipped failure using its real retained portrait, not a mock.
            let old = NSImage(data: try Data(contentsOf: folder.appendingPathComponent(PetSpriteStore.poseFileName(.idle))))!
            if visible(try rgba(PetSpriteStrip.slice(old, frames: row.frames).first!).2) == 0 {
                oldBlankCount += 1
            }
            thumbnails.append((character.displayName, thumb))
            print("\(character.id): \(actual.0)x\(actual.1), \(pixels) visible pixels, \(row.file)")
        }
        try check(thumbnails.count == 4 && oldBlankCount == 3,
            "Exercise all four Jedi and reproduce the three previously blank previews")

        // A different filename AND a different count prevent an eight-frame special case.
        let source = resources.appendingPathComponent("DefaultPet/session-pet-idle.png")
        try fm.copyItem(at: source, to: scratch.appendingPathComponent("renamed.png"))
        let state = scratch.appendingPathComponent(PetSpriteStore.stateFileName)
        try Data(#"{"poses":{"idle":{"file":"renamed.png","frames":2}}}"#.utf8).write(to: state)
        let renamed = PetSpriteStore.galleryThumbnail(in: scratch)!
        let original = NSImage(data: try Data(contentsOf: source))!
        try check(try rgba(renamed).0 == rgba(original).0 / 2, "Declared frame count ignored")
        try fm.removeItem(at: scratch.appendingPathComponent("renamed.png"))
        try check(PetSpriteStore.galleryThumbnail(in: scratch) == nil, "Missing image needs placeholder")
        try Data("not an image".utf8).write(to: scratch.appendingPathComponent("renamed.png"))
        try check(PetSpriteStore.galleryThumbnail(in: scratch) == nil, "Invalid image needs placeholder")
        try fm.removeItem(at: state)
        let legacy = resources.appendingPathComponent("BundledCharacters/jedi-nia-solari/session-pet-idle.png")
        try fm.copyItem(at: legacy, to: scratch.appendingPathComponent(PetSpriteStore.poseFileName(.idle)))
        let legacyThumb = PetSpriteStore.galleryThumbnail(in: scratch)!
        try check(try rgba(legacyThumb).0 == rgba(NSImage(data: Data(contentsOf: legacy))!).0,
            "Legacy portrait without a map must not be sliced into slivers")

        if CommandLine.arguments.count > 2 {
            // Diagnostic render of the production loader at the gallery's real 44pt size.
            let image = NSImage(size: NSSize(width: 720, height: 150))
            image.lockFocus()
            NSColor(calibratedRed: 0.96, green: 0.94, blue: 0.89, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 720, height: 150).fill()
            for (index, row) in thumbnails.enumerated() {
                let x = CGFloat(index * 180)
                let ratio = min(44 / row.1.size.width, 44 / row.1.size.height)
                let size = NSSize(width: row.1.size.width * ratio, height: row.1.size.height * ratio)
                NSGraphicsContext.current?.imageInterpolation = .none
                row.1.draw(in: NSRect(x: x + 90 - size.width / 2, y: 74, width: size.width, height: size.height))
                (row.0 as NSString).draw(at: NSPoint(x: x + 15, y: 35),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black])
            }
            image.unlockFocus()
            let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        print("Jedi gallery: four visible thumbnails, metadata/legacy/error cases passed")
    }
}
