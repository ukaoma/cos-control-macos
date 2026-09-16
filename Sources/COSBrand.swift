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

// ── Shared surface styles (0.5.193) ──────────────────────────────
//
// The Memories tab hosts the reviewed design: Fraunces for the hero, DM Sans
// for prose, JetBrains Mono for instrument chrome, warm cards with a hairline,
// gold on hover. These styles give the native panes the same vocabulary so a
// row, a field, or a button reads the same on every tab (Miles, 2026-09-06:
// "those other tabs are on a generic boilerplate theme").

/// A live number with what it counts, the same pair the home tiles show.
struct COSStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(COSType.display(18, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
            Text(label)
                .font(COSType.mono(9.5))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A list row as a warm card: card fill, hairline, gold on hover.
private struct COSRowCard: ViewModifier {
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(hovered ? COSPalette.gold.opacity(0.06) : Color.clear)
            .background(COSPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(hovered ? COSPalette.gold.opacity(0.85) : COSPalette.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
    }
}

/// A search or capture field: the same card and hairline as a row, so a field
/// does not introduce a second surface treatment.
private struct COSField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(COSType.body(12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(COSPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(COSPalette.line, lineWidth: 1))
    }
}

/// A quiet button: DM Sans, card fill, hairline; gold when hovered or pressed.
/// `.destructive` (0.5.221) is for the CONFIRMING step of a destructive action:
/// danger ink at rest and a danger hairline when hovered. Arming one stays a
/// `COSTextButtonStyle(tone: .destructive)`, so a list of rows is not a wall of red.
///
/// THREE WEIGHTS OF ACTION ON A PANE (0.5.232, Miles: "create some distinction on the
/// high use UI elements"): the one thing the pane is for is a `COSPrimaryButtonStyle`
/// (gold fill, first in the row); everything else is this style at `.standard`; and
/// a capability that just landed is `.featured`, a gold hairline with accent ink at
/// rest and its `COSNewPill` inside the label, until it is familiar.
struct COSQuietButtonStyle: ButtonStyle {
    enum Tone { case standard, destructive, featured }
    var tone: Tone = .standard

    func makeBody(configuration: Configuration) -> some View {
        QuietBody(configuration: configuration, tone: tone)
    }

    private struct QuietBody: View {
        let configuration: Configuration
        let tone: Tone
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let hot = (hovered || configuration.isPressed) && isEnabled
            let signal = tone == .destructive ? COSPalette.danger : COSPalette.gold
            let ink: Color = switch tone {
            case .destructive: isEnabled ? COSPalette.danger : Color.secondary
            case .featured: isEnabled ? (hot ? COSPalette.gold : COSPalette.accent) : Color.secondary
            case .standard: hot ? COSPalette.gold : (isEnabled ? Color.primary : Color.secondary)
            }
            let restLine: Color = tone == .featured && isEnabled ? COSPalette.gold.opacity(0.7) : COSPalette.line
            configuration.label
                .font(COSType.body(11.5, weight: tone == .featured ? .semibold : .medium))
                .foregroundStyle(ink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(configuration.isPressed ? signal.opacity(0.12) : COSPalette.card)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(hot ? signal.opacity(0.85) : restLine, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.55)
                .onHover { hovered = $0 }
        }
    }
}

/// An inline text action beside a chip (Cancel, Keep), or the arming step of a
/// destructive one (Discard): DM Sans, warm muted ink, no chrome; accent when
/// hovered, danger when the tone is destructive. Replaces system link buttons,
/// whose blue reads as a web hyperlink in a warm pane (Miles, 2026-09-13).
struct COSTextButtonStyle: ButtonStyle {
    enum Tone { case standard, destructive }
    var tone: Tone = .standard

    func makeBody(configuration: Configuration) -> some View {
        TextBody(configuration: configuration, tone: tone)
    }

    private struct TextBody: View {
        let configuration: Configuration
        let tone: Tone
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let hot = (hovered || configuration.isPressed) && isEnabled
            let signal = tone == .destructive ? COSPalette.danger : COSPalette.accent
            configuration.label
                .font(COSType.body(11.5, weight: .medium))
                .foregroundStyle(hot ? signal : COSPalette.muted)
                .padding(.horizontal, 2)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovered = $0 }
        }
    }
}

/// A round icon control (play, previous, next): card fill and hairline with a
/// muted glyph; `prominent` fills it gold with ink, for the control that is live
/// right now (a sample playing).
struct COSIconButtonStyle: ButtonStyle {
    var size: CGFloat = 22
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size, prominent: prominent)
    }

    private struct IconBody: View {
        let configuration: Configuration
        let size: CGFloat
        let prominent: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let hot = (hovered || configuration.isPressed) && isEnabled
            configuration.label
                .font(.system(size: max(7, size * 0.40), weight: .semibold))
                .foregroundStyle(prominent ? COSPalette.ink : (hot ? COSPalette.accent : COSPalette.muted))
                .frame(width: size, height: size)
                .background(Circle().fill(prominent
                    ? COSPalette.gold.opacity(configuration.isPressed ? 0.8 : 1)
                    : (configuration.isPressed ? COSPalette.gold.opacity(0.12) : COSPalette.card)))
                .overlay(Circle().stroke(prominent ? Color.clear : (hot ? COSPalette.gold.opacity(0.85) : COSPalette.line), lineWidth: 1))
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovered = $0 }
        }
    }
}

/// The NEW marker that rides INSIDE a featured button's label (0.5.232), so the
/// button and its newness are one object rather than a pill floating beside it.
struct COSNewPill: View {
    var body: some View {
        Text("NEW")
            .font(COSType.mono(8.5, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(COSPalette.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(COSPalette.gold))
    }
}

/// The one loud button on a pane: gold fill, ink text.
struct COSPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(COSType.body(11.5, weight: .semibold))
            .foregroundStyle(COSPalette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(COSPalette.gold.opacity(configuration.isPressed ? 0.8 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

extension View {
    func cosRowCard() -> some View { modifier(COSRowCard()) }
    func cosField() -> some View { modifier(COSField()) }
}
