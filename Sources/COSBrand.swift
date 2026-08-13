import AppKit
import CoreText
import SwiftUI

/// Official COS lockup and gotcos.com typefaces (Fraunces, DM Sans, JetBrains Mono).
enum COSBrand {
    static func svg(_ name: String) -> NSImage {
        let empty = NSImage(size: NSSize(width: 1, height: 1))
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return empty }
        image.isTemplate = true
        return image
    }
}

enum COSType {
    private static let bundled: Bool = {
        registerBundledFonts()
        return true
    }()

    static func display(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        _ = bundled
        var font = Font.custom("Fraunces", size: size).weight(weight)
        if italic { font = font.italic() }
        return font
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        _ = bundled
        return Font.custom("DM Sans", size: size).weight(weight)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        _ = bundled
        return Font.custom("JetBrains Mono", size: size).weight(weight)
    }

    private static func registerBundledFonts() {
        let names = ["Fraunces", "Fraunces-Italic", "DMSans", "JetBrainsMono"]
        let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true)
        for name in names {
            let url = folder?.appendingPathComponent("\(name).ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
            guard let url else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

struct COSLockupView: View {
    var height: CGFloat = 17

    var body: some View {
        Image(nsImage: COSBrand.svg("COSLockup"))
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityLabel("COS")
    }
}

struct COSGotcosCaption: View {
    var size: CGFloat = 12

    var body: some View {
        Text("gotcos")
            .font(COSType.display(size, italic: true))
            .foregroundStyle(COSPalette.gold)
            .accessibilityLabel("gotcos")
    }
}
