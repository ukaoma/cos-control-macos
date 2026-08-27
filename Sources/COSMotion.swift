import SwiftUI

// MARK: - Section glyphs

/// The six section marks as real `Shape`s rather than SF Symbols.
///
/// They are vector paths so they can be `trim`med, which is what makes the gotcos
/// sketch-then-ink draw possible: an `Image(systemName:)` is a raster at draw time and
/// has no length to travel along. Every path is authored in a 20x20 design space and
/// scaled to the rect, so the same shape serves the 17pt icon and the large ghosted plate.
/// The filled type mark that rides the corner of a message bubble.
///
/// FILLED, not stroked, and that is the whole reason it works. The first pass
/// drew these as 1.15pt outlines at 10pt and every one collapsed into an
/// indistinct speck; a solid silhouette survives at that size where a hairline
/// cannot. Rendered at 64pt during design to confirm each shape is the thing
/// it claims to be -- which is how the original "mixed" paperclip was caught
/// reading as a battery, and became stacked cards instead.
struct AttachmentMark: Shape {
    /// "video" | "photo" | "document" | "mixed"
    let category: String

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 10
        let ox = rect.minX, oy = rect.minY
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }
        var path = Path()
        switch category {
        case "video":
            // Camcorder body plus lens wedge. A bare triangle would read as
            // "play" on anything, including a photo.
            path.addRoundedRect(in: box(1.9, 3.2, 4.6, 3.9), cornerSize: CGSize(width: 0.9 * s, height: 0.9 * s))
            path.move(to: p(7, 4.4)); path.addLine(to: p(8.4, 3.3))
            path.addLine(to: p(8.4, 7)); path.addLine(to: p(7, 5.9)); path.closeSubpath()
        case "photo":
            // Frame with the peak knocked out, so the silhouette is not just a
            // rectangle at 11pt.
            path.addRoundedRect(in: box(1.7, 2.6, 6.6, 5.2), cornerSize: CGSize(width: s, height: s))
            path.move(to: p(2.5, 7)); path.addLine(to: p(4.3, 4.9))
            path.addLine(to: p(6.1, 7)); path.closeSubpath()
        case "document":
            // Page with a folded corner; the fold is what separates it from
            // the photo frame in a glance.
            path.move(to: p(2.6, 2.2)); path.addLine(to: p(6, 2.2)); path.addLine(to: p(7.6, 3.8))
            path.addLine(to: p(7.6, 7.8)); path.addLine(to: p(2.6, 7.8)); path.closeSubpath()
        default:
            // Stacked cards for a mixed turn. Deliberately NOT a paperclip: a
            // clip needs a thin curved stem, and at this size that stem fills
            // in and reads as a battery.
            path.addRoundedRect(in: box(1.6, 1.6, 5, 5), cornerSize: CGSize(width: s, height: s))
            path.addRoundedRect(in: box(3.2, 3.2, 2.2, 2.2), cornerSize: CGSize(width: 0.6 * s, height: 0.6 * s))
            path.addRoundedRect(in: box(3.9, 3.9, 5, 5), cornerSize: CGSize(width: s, height: s))
        }
        return path
    }
}

struct SectionGlyph: Shape {
    let section: ActivitySection

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 20
        let ox = rect.minX + (rect.width - 20 * s) / 2
        let oy = rect.minY + (rect.height - 20 * s) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ox + x * s, y: oy + y * s, width: w * s, height: h * s)
        }
        func node(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGRect {
            CGRect(x: ox + (x - r) * s, y: oy + (y - r) * s, width: r * 2 * s, height: r * 2 * s)
        }

        var path = Path()
        switch section {
        case .messages:
            path.addRoundedRect(in: box(3, 4, 14, 9.5), cornerSize: CGSize(width: 2.5 * s, height: 2.5 * s))
            path.move(to: p(6.6, 13.5)); path.addLine(to: p(4.4, 16.6)); path.addLine(to: p(4.4, 13.5))

        case .speakers:
            for (x, h) in [(4.0, 2.5), (7.0, 4.6), (10.0, 6.6), (13.0, 3.6), (16.0, 1.6)] {
                path.move(to: p(x, 10 - h)); path.addLine(to: p(x, 10 + h))
            }

        case .meetings:
            path.addRoundedRect(in: box(3, 4.5, 14, 12), cornerSize: CGSize(width: 2 * s, height: 2 * s))
            path.move(to: p(3, 8.6)); path.addLine(to: p(17, 8.6))
            path.move(to: p(7, 3)); path.addLine(to: p(7, 6))
            path.move(to: p(13, 3)); path.addLine(to: p(13, 6))

        case .memories:
            // four-point spark, drawn as one continuous outline so the trim reads cleanly
            path.move(to: p(10, 3.4))
            path.addQuadCurve(to: p(16.6, 10), control: p(11.3, 8.7))
            path.addQuadCurve(to: p(10, 16.6), control: p(11.3, 11.3))
            path.addQuadCurve(to: p(3.4, 10), control: p(8.7, 11.3))
            path.addQuadCurve(to: p(10, 3.4), control: p(8.7, 8.7))

        case .threads:
            path.move(to: p(5, 4.8)); path.addLine(to: p(5, 8))
            path.addQuadCurve(to: p(8, 10), control: p(5, 10))
            path.addLine(to: p(12, 10))
            path.addQuadCurve(to: p(15, 12), control: p(15, 10))
            path.addLine(to: p(15, 15))
            path.addEllipse(in: node(5, 3.4, 1.4))
            path.addEllipse(in: node(15, 16.6, 1.4))

        case .sessions:
            path.addRoundedRect(in: box(2.8, 4, 14.4, 12), cornerSize: CGSize(width: 2 * s, height: 2 * s))
            path.move(to: p(6, 8.6)); path.addLine(to: p(8.5, 10.8)); path.addLine(to: p(6, 13))
            path.move(to: p(10.6, 13)); path.addLine(to: p(14.2, 13))
        }
        return path
    }
}

// MARK: - Halftone plate

/// Full-card stipple, the gotcos.com `.chapcard` paper — not a corner glyph.
///
/// Site CSS:
///   background-image: radial-gradient(gold .10 / 1px, transparent 1.1px);
///   background-size: 9px 9px;
///   mask-image: linear-gradient(135deg, transparent 12%, #000 100%);
///
/// Earlier Control cuts confined the same 5pt screen to a section mark in the
/// trailing corner. That is a different object than the brand: the public cards
/// are a FIELD of dots the copy sits on. Drawn in Canvas (a layer, never a
/// `.drawingGroup()` mask — that rasterises to nothing, 0.5.54).
struct HalftonePlate: View {
    var strong: Bool

    var body: some View {
        Canvas { ctx, size in
            let pitch: CGFloat = 9
            let r: CGFloat = 1.05
            let ink = COSPalette.plateInk.opacity(strong ? 0.28 : 0.14)
            var y: CGFloat = 0
            while y < size.height + pitch {
                var x: CGFloat = 0
                while x < size.width + pitch {
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                        with: .color(ink)
                    )
                    x += pitch
                }
                y += pitch
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.12),
                    .init(color: .black, location: 1),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .allowsHitTesting(false)
    }
}

// MARK: - Paint-in

/// Sketch-then-ink, the gotcos lockup's own motion: the outline draws itself on.
///
/// `trim(from:to:)` is the SwiftUI equivalent of anime.js `svg.createDrawable` — both
/// animate how much of a path is revealed along its length.
struct DrawIn: ViewModifier {
    let progress: CGFloat
    func body(content: Content) -> some View { content }
}

extension View {
    /// Left-to-right paint, the wipe the lockup uses for its four sections.
    ///
    /// Type cannot be dash-drawn — text is not a single path with a length to travel —
    /// so headings take this half of the same language while glyphs take the draw.
    func wipeIn(_ shown: Bool, delay: Double, reduceMotion: Bool) -> some View {
        self.mask(
            GeometryReader { geo in
                Rectangle()
                    .frame(width: (reduceMotion || shown) ? geo.size.width + 2 : 0)
                    .frame(width: geo.size.width, alignment: .leading)
            }
        )
        .animation(reduceMotion ? nil : .timingCurve(0.3, 0.72, 0, 1, duration: 0.46).delay(delay),
                   value: shown)
    }
}

// MARK: - Palette additions

extension COSPalette {
    /// Plate ink. Dark dots multiplied into cream; a warm light on espresso, because a
    /// dark plate on a dark card is the black-on-black failure this app has hit before.
    static let plateInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.79, green: 0.66, blue: 0.43, alpha: 1)   // gold
            : NSColor(red: 0.17, green: 0.13, blue: 0.09, alpha: 1)   // #2b2117
    })

}

/// Pixel COS figure for the desktop session pet. Working opens the visor dots;
/// waiting keeps them as dashes. Drawn on a 16-unit grid so nearest-neighbor
/// scale stays blocky at the 48pt sprite size.
struct SessionPetSprite: View {
    var working: Bool
    var reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 3600 : 0.42, paused: reduceMotion)) { timeline in
            let phase = reduceMotion ? 0.0 : sin(timeline.date.timeIntervalSinceReferenceDate * (working ? 6.2 : 2.4))
            Canvas { ctx, size in
                let unit = floor(min(size.width, size.height) / 16)
                let ox = (size.width - unit * 16) / 2
                let oy = (size.height - unit * 16) / 2 + (working && !reduceMotion ? CGFloat(phase) * 1.4 : 0)
                func cell(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color) {
                    ctx.fill(
                        Path(CGRect(x: ox + x * unit, y: oy + y * unit, width: w * unit, height: h * unit)),
                        with: .color(color)
                    )
                }
                let ink = COSPalette.ink
                let gold = COSPalette.gold
                let cream = COSPalette.cream
                let visor = Color(red: 0.18, green: 0.12, blue: 0.08)
                cell(3, 2, 10, 7, ink)
                cell(4, 3, 8, 5, gold)
                cell(5, 4, 6, 3, visor)
                if working {
                    cell(6, 5, 1, 1, cream)
                    cell(9, 5, 1, 1, cream)
                } else {
                    cell(6, 5, 2, 1, cream)
                    cell(8, 5, 2, 1, cream)
                }
                cell(5, 9, 6, 5, gold)
                cell(6, 10, 4, 2, cream)
                cell(6, 11, 1, 1, ink)
                cell(8, 11, 2, 1, ink)
                cell(5, 14, 2, 1, ink)
                cell(9, 14, 2, 1, ink)
            }
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
    }
}
