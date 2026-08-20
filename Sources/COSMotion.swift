import SwiftUI

// MARK: - Section glyphs

/// The six section marks as real `Shape`s rather than SF Symbols.
///
/// They are vector paths so they can be `trim`med, which is what makes the gotcos
/// sketch-then-ink draw possible: an `Image(systemName:)` is a raster at draw time and
/// has no length to travel along. Every path is authored in a 20x20 design space and
/// scaled to the rect, so the same shape serves the 17pt icon and the large ghosted plate.
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

/// A dot screen, drawn rather than bundled.
///
/// Used as a mask: the glyph is stroked, then punched through this grid, which is what
/// turns a line drawing into the engraving-halftone treatment the brand already uses on
/// gotcos and milesukaoma. 5pt pitch matches the site's `background-size:5px 5px`.
private struct DotScreen: View {
    var body: some View {
        Canvas { ctx, size in
            let pitch: CGFloat = 5, r: CGFloat = 1.05
            var y: CGFloat = 0
            while y < size.height + pitch {
                var x: CGFloat = 0
                while x < size.width + pitch {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(.white))
                    x += pitch
                }
                y += pitch
            }
        }
        .drawingGroup()
    }
}

/// The section's own mark at plate scale, dot-screened and radially faded.
///
/// Deliberately the SAME shape as the small icon rather than a separate illustration:
/// one mark at two scales is a decision, where a drawn "engraving" would be a stand-in
/// for the real public-domain plates the brand rule actually calls for. Swapping in real
/// plates later means replacing this view and nothing else.
struct HalftonePlate: View {
    let section: ActivitySection
    var strong: Bool

    var body: some View {
        SectionGlyph(section: section)
            .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .foregroundStyle(COSPalette.plateInk)
            .mask(DotScreen())
            .mask(
                RadialGradient(colors: [.black, .black.opacity(0.55), .clear],
                               center: .init(x: 0.52, y: 0.48),
                               startRadius: 0, endRadius: 78)
            )
            .opacity(strong ? COSPalette.plateOpacityHover : COSPalette.plateOpacity)
            .scaleEffect(strong ? 1.05 : 1)
            .rotationEffect(.degrees(strong ? -1.2 : 0))
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

    static let plateOpacity: Double = 0.07
    static let plateOpacityHover: Double = 0.26
}
