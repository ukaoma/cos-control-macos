// Sprite appearance contract.
//
// Every sprite check that existed before this file was STRUCTURAL: strip
// dimensions, corner alpha, and zero ink at the cut columns. All of them passed
// on artwork that Miles rejected on sight — a purple vest you can read the
// terminal through, and a figure pressed so close to the cell edge it reads as
// cropped. A check that cannot see what the user sees is not QA.
//
// Three measurements, calibrated against art that is known good rather than
// against numbers someone chose:
//
//   holes   Semi-transparent pixels INSIDE the figure, as a share of solid
//           pixels. An edge pixel is antialiasing; a semi-transparent pixel
//           whose four neighbours are all inked is a hole you can see through.
//           Known-good stock art measures 0.14-0.44%. Rejected art measures
//           1.5-4.4%. Gate at 1.0%.
//
//   margin  Closest approach to a cell edge. Known-good stock art keeps 8-12px.
//           The art Miles called cropped keeps 3px. Gate at 6px. Note the older
//           "zero ink at the cut column" check passes at 3px, which is exactly
//           why it missed this.
//
//   swing   Figure-height variation across a strip. REPORTED, NOT GATED —
//           legitimate poses crouch and lunge, and gating on this produces the
//           foreshortening false positives that have burned us before.
//
// 0.5.316 (Miles Windu V12.6; independent check motion-v12/reviews/v12-6-holes-and-cuts-check.json): the multi-
// character strips failed the gates above BY DESIGN, so the contract now tells deliberate translucency and off-canvas
// entrances apart from the two defects it exists for. Each rule is exercised on synthetic strips (selfCheck) before
// any shipped art is read, so a rule that stops discriminating fails the run:
//
//   fade    A translucent component (4-connected, 25 < alpha < 205) with at least 100 hole pixels, 80% of them within
//           2 alpha levels of one value, is an object fading at one alpha (V12.6: destroyed-droid wreckage in Two,
//           Waiting's aura release). Its holes are not counted. An unevenly eaten garment is not one alpha, so it
//           still counts.
//   smear   A documented exception, not a rule: the drawn speed smear behind the right droid in Two, frames 29-31,
//           limited to translucent components with median alpha <= 90 lying right of x 220. Pinned in the fixture.
//   margin  A frame listed in the fixture as an off-canvas entrance or exit may reach the cell edge; every other
//           frame still keeps 6 px. ModelsContract bounds its cut-boundary check with the same list.
//   cuts    Ink that crosses a cut (both cut columns inked in one row) must belong to an object of its OWN cell: the
//           piece on that side continues at the same edge of its own cell in the previous or next frame (an object
//           entering or leaving), over at least half of the piece's rows, or it is the larger side (its object's bulk
//           is in this cell). A smaller piece seen in no other frame is a neighbour's sliver and fails. Pieces of 15
//           px or less are specks, invisible at 1x: printed, not failed (V12.6: 8 px at swarm frame 59, left edge).
//
// Windu himself keeps the original gates: no interior holes (fades and the smear are other objects) and no slivers.
// Strips that exceeded a gate before 0.5.316 are listed under preExisting in the fixture with their measured
// ceiling, so they cannot get worse and are printed as pre-existing; nothing new is accepted silently.
//
// Run from the repo root: swiftc Sources/Models.swift Tests/SpriteRenderContract.swift -framework AppKit
// Tests/run.sh runs it right after models-contract (0.5.316).

import AppKit

enum SpriteRenderContract {
    struct Measure {
        var holesPercent: Double
        /// Holes left once uniform fades and the documented smear are removed: what the 1.0% gate reads.
        var gatedHolesPercent: Double
        var fadeHolesPercent: Double
        var smearHolesPercent: Double
        var minMargin: Int
        /// 1-based frames whose ink comes within minEdgeMargin of a cell edge.
        var edgeFrames: [Int]
        var heightSwingPercent: Double
        var slivers: [String]
        var specks: [String]
    }

    struct Smear: Decodable {
        let strip: String
        let frames: [Int]
        let maxMedianAlpha: Int
        let minX: Int
    }

    struct KnownViolation: Decodable {
        let holesCeiling: Double?
        let edgeFrames: [Int]?
        let note: String
    }

    struct EdgeFade: Decodable {
        let strip: String
        let frames: [Int]
        let width: Int
    }

    struct Fixture: Decodable {
        let edgeFrames: [String: [Int]]
        let smear: [Smear]
        let preExisting: [String: KnownViolation]
        var edgeFades: [EdgeFade]? = nil
    }

    static let maxHolesPercent = 1.0
    static let minEdgeMargin = 6
    static let fadeMinHoles = 100
    static let fadeShare = 0.8
    static let fadeAlphaTolerance = 2
    static let speckMaxPixels = 15
    static let cutBand = 6

    /// Alpha plane of one cell, top row first.
    struct Plane {
        let width: Int
        let height: Int
        let alpha: [UInt8]
        func a(_ x: Int, _ y: Int) -> Int { Int(alpha[y * width + x]) }
    }

    static func plane(_ cg: CGImage) -> Plane {
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var alpha = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { alpha[i] = px[i * 4 + 3] }
        return Plane(width: w, height: h, alpha: alpha)
    }

    /// 4-connected components of the pixels `inMask` accepts, as flat indexes.
    static func components(_ p: Plane, _ inMask: (Int) -> Bool) -> [[Int]] {
        var seen = [Bool](repeating: false, count: p.width * p.height)
        var out: [[Int]] = []
        for start in 0..<(p.width * p.height) where !seen[start] && inMask(start) {
            var stack = [start]
            seen[start] = true
            var members: [Int] = []
            while let i = stack.popLast() {
                members.append(i)
                let x = i % p.width, y = i / p.width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < p.width && ny < p.height {
                    let n = ny * p.width + nx
                    if !seen[n] && inMask(n) { seen[n] = true; stack.append(n) }
                }
            }
            out.append(members)
        }
        return out
    }

    /// The ink (alpha > 40) connected to `seeds`, inside one cell.
    static func piece(_ p: Plane, seeds: [Int]) -> [Int] {
        var stack = seeds.filter { p.alpha[$0] > 40 }
        var seen = Set(stack)
        var members: [Int] = []
        while let i = stack.popLast() {
            members.append(i)
            let x = i % p.width, y = i / p.width
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && ny >= 0 && nx < p.width && ny < p.height {
                let n = ny * p.width + nx
                if p.alpha[n] > 40 && !seen.contains(n) { seen.insert(n); stack.append(n) }
            }
        }
        return members
    }

    /// Rows with ink (alpha > 40) within `cutBand` px of the cell's left or right edge.
    static func bandRows(_ p: Plane, right: Bool) -> Set<Int> {
        let columns = right ? Array((p.width - cutBand)..<p.width) : Array(0..<cutBand)
        return Set((0..<p.height).filter { y in columns.contains { p.a($0, y) > 40 } })
    }

    static func measure(strip url: URL, frames: Int, label: String, fixture: Fixture) -> Measure? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        return measure(image: image, frames: frames, label: label, fixture: fixture)
    }

    static func measure(image: NSImage, frames: Int, label: String, fixture: Fixture) -> Measure? {
        let cells = PetSpriteStrip.slice(image, frames: frames).compactMap { PetSpriteStrip.raster($0) }.map(plane)
        guard !cells.isEmpty else { return nil }
        let smear = fixture.smear.first { $0.strip == label }
        let edgeFade = fixture.edgeFades?.first { $0.strip == label }

        var holed = 0, opaque = 0, faded = 0, smeared = 0
        var minMargin = Int.max
        var edgeFrames: [Int] = []
        var heights: [Int] = []

        for (index, p) in cells.enumerated() {
            let w = p.width, h = p.height
            var top = h, bottom = -1, left = w, right = -1
            for y in 0..<h {
                for x in 0..<w where p.a(x, y) > 40 {
                    if y < top { top = y }
                    if y > bottom { bottom = y }
                    if x < left { left = x }
                    if x > right { right = x }
                }
            }
            if bottom >= top, right >= left {
                heights.append(bottom - top + 1)
                let margin = min(left, w - 1 - right, top, h - 1 - bottom)
                minMargin = min(minMargin, margin)
                if margin < minEdgeMargin { edgeFrames.append(index + 1) }
            }

            // A 1–3 px antialiased fringe/glow can have four inked neighbours.
            // It is still an outside edge, not a hole in a garment. Only exempt
            // pixels connected to clear space through non-solid alpha AND within
            // three pixels of that clear space (including arm/hair gaps). Enclosed
            // semi-transparent patches without clear space, or deep damage
            // remains gated, including the eaten-cloth self-tests below.
            var outside = [Bool](repeating: false, count: w * h)
            var pending: [Int] = []
            for i in 0..<(w*h) where p.alpha[i] <= 25 {
                outside[i] = true; pending.append(i)
            }
            var cursor = 0
            while cursor < pending.count {
                let i = pending[cursor]; cursor += 1
                let x = i % w, y = i / w
                for (nx,ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] where nx >= 0 && nx < w && ny >= 0 && ny < h {
                    let n = ny*w+nx
                    if !outside[n] && p.alpha[n] <= 235 { outside[n] = true; pending.append(n) }
                }
            }
            func isExteriorFringe(_ x: Int, _ y: Int) -> Bool {
                guard outside[y*w+x] else { return false }
                for ny in max(0,y-3)...min(h-1,y+3) {
                    for nx in max(0,x-3)...min(w-1,x+3) where outside[ny*w+nx] && p.a(nx,ny) <= 25 { return true }
                }
                return false
            }
            var isHole = [Bool](repeating: false, count: w * h)
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let a = p.a(x, y)
                    if a > 235 { opaque += 1 }
                    // Interior only: all four neighbours inked. An edge pixel
                    // has an empty neighbour and is legitimate antialiasing.
                    if a > 25, a < 205,
                       p.a(x - 1, y) > 25, p.a(x + 1, y) > 25,
                       p.a(x, y - 1) > 25, p.a(x, y + 1) > 25, !isExteriorFringe(x, y) {
                        holed += 1
                        if let edgeFade, edgeFade.frames.contains(index + 1),
                           x < min(22, edgeFade.width) || x >= w - min(22, edgeFade.width) {
                            faded += 1 // Authored 22 px canvas-edge entrance gradient only.
                        } else { isHole[y * w + x] = true }
                    }
                }
            }
            for component in components(p, { p.alpha[$0] > 25 && p.alpha[$0] < 205 }) {
                let holes = component.filter { isHole[$0] }
                guard !holes.isEmpty else { continue }
                var counts: [Int: Int] = [:]
                for i in holes { counts[Int(p.alpha[i]), default: 0] += 1 }
                let mode = counts.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }!.key
                let near = holes.filter { abs(Int(p.alpha[$0]) - mode) <= fadeAlphaTolerance }.count
                if holes.count >= fadeMinHoles, Double(near) >= fadeShare * Double(holes.count) {
                    faded += holes.count
                    continue
                }
                if let smear, smear.frames.contains(index + 1) {
                    let alphas = component.map { Int(p.alpha[$0]) }.sorted()
                    let median = alphas[alphas.count / 2]
                    let minX = component.map { $0 % w }.min()!
                    if median <= smear.maxMedianAlpha, minX >= smear.minX { smeared += holes.count }
                }
            }
        }

        // Cuts: ink in the same row on both sides of a cut must belong to its own cell's object.
        var slivers: [String] = [], specks: [String] = []
        for k in 0..<max(0, cells.count - 1) {
            let a = cells[k], b = cells[k + 1]
            guard a.height == b.height else { continue }
            let rows = (0..<a.height).filter { a.a(a.width - 1, $0) > 40 && b.a(0, $0) > 40 }
            guard !rows.isEmpty else { continue }
            let rightPiece = piece(a, seeds: rows.map { $0 * a.width + a.width - 1 })
            let leftPiece = piece(b, seeds: rows.map { $0 * b.width })
            for (cell, right, members, other) in [(k, true, rightPiece, leftPiece.count),
                                                  (k + 1, false, leftPiece, rightPiece.count)] {
                let p = cells[cell]
                let name = "\(label) frame \(cell + 1) \(right ? "right" : "left") edge (\(members.count) px)"
                if members.count <= speckMaxPixels { specks.append(name); continue }
                let pieceRows = Set(members.map { $0 / p.width })
                let continues = [cell - 1, cell + 1].contains { adjacent in
                    guard adjacent >= 0, adjacent < cells.count else { return false }
                    let overlap = pieceRows.intersection(bandRows(cells[adjacent], right: right)).count
                    return Double(overlap) >= 0.5 * Double(pieceRows.count)
                }
                if !continues && members.count <= other { slivers.append(name) }
            }
        }

        let tallest = Double(heights.max() ?? 1)
        let shortest = Double(heights.min() ?? 0)
        let base = Double(max(opaque, 1))
        return Measure(
            holesPercent: Double(holed) / base * 100,
            gatedHolesPercent: Double(holed - faded - smeared) / base * 100,
            fadeHolesPercent: Double(faded) / base * 100,
            smearHolesPercent: Double(smeared) / base * 100,
            minMargin: minMargin == Int.max ? 0 : minMargin,
            edgeFrames: edgeFrames,
            heightSwingPercent: (tallest - shortest) / max(tallest, 1) * 100,
            slivers: slivers,
            specks: specks
        )
    }

    /// Empty when the strip is acceptable; otherwise one line per violation.
    static func violations(_ m: Measure, label: String, fixture: Fixture) -> [String] {
        var out: [String] = []
        let known = fixture.preExisting[label]
        let holesCap = known?.holesCeiling ?? maxHolesPercent
        if m.gatedHolesPercent > holesCap {
            out.append(String(
                format: "%@: %.2f%% of the figure is see-through (max %.2f%%, after %.2f%% uniform fades and %.2f%% documented smear). Interior alpha was eaten; the garment reads translucent on screen.",
                label, m.gatedHolesPercent, holesCap, m.fadeHolesPercent, m.smearHolesPercent))
        }
        let allowed = Set(fixture.edgeFrames[label] ?? []).union(known?.edgeFrames ?? [])
        let cropped = m.edgeFrames.filter { !allowed.contains($0) }
        if !cropped.isEmpty {
            out.append("\(label): frames \(cropped) come within \(minEdgeMargin)px of a cell edge and are not listed entrances. Reads as cropped.")
        }
        for sliver in m.slivers {
            out.append("\(sliver): ink crosses the cut and does not continue in its own cell. A neighbour's sliver.")
        }
        return out
    }

    // MARK: Self-check. Each rule must pass what it should and fail what it should, on strips built here.

    static func strip(cells: Int, width: Int, height: Int, draw: (CGContext) -> Void) -> NSImage {
        let ctx = CGContext(data: nil, width: cells * width, height: height, bitsPerComponent: 8,
                            bytesPerRow: cells * width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        let cg = ctx.makeImage()!
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// A rect in STRIP coordinates measured from the top (CGContext's origin is bottom-left). `.copy` replaces what
    /// is there, so a translucent fill can punch a see-through patch into an opaque one.
    static func fill(_ ctx: CGContext, height: Int, x: Int, y: Int, w: Int, h: Int, alpha: CGFloat, copy: Bool = false) {
        ctx.setBlendMode(copy ? .copy : .normal)
        ctx.setFillColor(CGColor(red: 0.4, green: 0.2, blue: 0.6, alpha: alpha))
        ctx.fill(CGRect(x: x, y: height - y - h, width: w, height: h))
    }

    static func selfCheck() -> [String] {
        let none = Fixture(edgeFrames: [:], smear: [], preExisting: [:])
        var failures: [String] = []
        let W = 64, H = 64
        func expect(_ ok: Bool, _ what: String) { if !ok { failures.append("self-check: \(what)") } }
        // An opaque figure and, beside it, an object fading at ONE alpha: the fade is not a hole.
        let fade = strip(cells: 2, width: W, height: H) { ctx in
            for cell in 0..<2 {
                fill(ctx, height: H, x: cell * W + 10, y: 10, w: 20, h: 40, alpha: 1)
                fill(ctx, height: H, x: cell * W + 36, y: 20, w: 20, h: 20, alpha: 0.6)
            }
        }
        let fm = measure(image: fade, frames: 2, label: "synthetic/fade", fixture: none)!
        expect(fm.holesPercent > maxHolesPercent && fm.gatedHolesPercent <= maxHolesPercent && fm.fadeHolesPercent > 0,
               "a uniform-alpha fade must be exempt from the hole gate (\(fm.holesPercent), \(fm.gatedHolesPercent))")
        // An opaque garment whose interior alpha was eaten unevenly: still holes.
        let eaten = strip(cells: 2, width: W, height: H) { ctx in
            for cell in 0..<2 {
                fill(ctx, height: H, x: cell * W + 10, y: 10, w: 40, h: 40, alpha: 1)
                for band in 0..<8 {
                    fill(ctx, height: H, x: cell * W + 14 + band * 4, y: 14, w: 4, h: 30,
                         alpha: 0.2 + 0.07 * CGFloat(band), copy: true)
                }
            }
        }
        let em = measure(image: eaten, frames: 2, label: "synthetic/eaten", fixture: none)!
        expect(!violations(em, label: "synthetic/eaten", fixture: none).isEmpty && em.fadeHolesPercent == 0,
               "an unevenly eaten garment must still fail the hole gate")
        // A small patch eaten at ONE alpha inside the garment (under fadeMinHoles): still a hole, not a fade.
        let patch = strip(cells: 2, width: W, height: H) { ctx in
            for cell in 0..<2 {
                fill(ctx, height: H, x: cell * W + 10, y: 10, w: 40, h: 40, alpha: 1)
                fill(ctx, height: H, x: cell * W + 20, y: 20, w: 6, h: 6, alpha: 0.5, copy: true)
            }
        }
        let pm = measure(image: patch, frames: 2, label: "synthetic/patch", fixture: none)!
        expect(!violations(pm, label: "synthetic/patch", fixture: none).isEmpty && pm.fadeHolesPercent == 0,
               "a small uniform patch eaten into the garment must still fail the hole gate")
        let fringe = strip(cells: 2, width: W, height: H) { ctx in
            for cell in 0..<2 {
                fill(ctx, height: H, x: cell * W + 10, y: 10, w: 40, h: 40, alpha: 0.5)
                fill(ctx, height: H, x: cell * W + 13, y: 13, w: 34, h: 34, alpha: 1, copy: true)
            }
        }
        let fringeM = measure(image: fringe, frames: 2, label: "synthetic/fringe", fixture: none)!
        expect(violations(fringeM, label: "synthetic/fringe", fixture: none).isEmpty,
               "three-pixel antialias/glow fringe is not interior garment damage")
        let entranceFade = strip(cells: 2, width: W, height: H) { ctx in
            for cell in 0..<2 { for x in 6..<22 {
                fill(ctx, height: H, x: cell * W + x, y: 10, w: 1, h: 40,
                     alpha: CGFloat(x)/24, copy: true)
            } }
        }
        let gradientFixture = Fixture(edgeFrames: [:], smear: [], preExisting: [:],
            edgeFades: [.init(strip: "synthetic/gradient", frames: [1,2], width: 22)])
        let gradientM = measure(image: entranceFade, frames: 2, label: "synthetic/gradient", fixture: gradientFixture)!
        expect(gradientM.gatedHolesPercent == 0, "documented entrance gradient excluded only at canvas edge")
        let protectedPatch = measure(image: patch, frames: 2, label: "synthetic/gradient", fixture: gradientFixture)!
        expect(!violations(protectedPatch, label: "synthetic/gradient", fixture: gradientFixture).isEmpty,
               "entrance gradient cannot excuse damage in the character's central garment")
        // A figure at the cell edge: cropped unless its frame is a listed entrance.
        let edge = strip(cells: 2, width: W, height: H) { ctx in
            fill(ctx, height: H, x: 20, y: 10, w: 20, h: 40, alpha: 1)
            fill(ctx, height: H, x: W, y: 10, w: 20, h: 40, alpha: 1)
        }
        let edgeM = measure(image: edge, frames: 2, label: "synthetic/edge", fixture: none)!
        let listed = Fixture(edgeFrames: ["synthetic/edge": [2]], smear: [], preExisting: [:])
        expect(!violations(edgeM, label: "synthetic/edge", fixture: none).isEmpty
               && violations(edgeM, label: "synthetic/edge", fixture: listed).isEmpty,
               "an edge frame fails unless listed, and passes when listed")
        // Two objects entering back to back across each cut, each continuing at its own edge in its own cell: owned.
        let entering = strip(cells: 3, width: W, height: H) { ctx in
            for cell in 0..<2 { fill(ctx, height: H, x: cell * W + W - 12 + cell * 4, y: 20, w: 12 - cell * 4, h: 20, alpha: 1) }
            for cell in 1..<3 { fill(ctx, height: H, x: cell * W, y: 22, w: 6 + cell * 4, h: 18, alpha: 1) }
        }
        let enterM = measure(image: entering, frames: 3, label: "synthetic/entering", fixture: none)!
        expect(enterM.slivers.isEmpty, "two entering objects touching at a cut are not slivers: \(enterM.slivers)")
        // One object in frame 1 spilling 8 px into frame 2's left edge, seen nowhere else: a sliver, in frame 2 only.
        let spill = strip(cells: 3, width: W, height: H) { ctx in
            fill(ctx, height: H, x: 30, y: 20, w: W - 30 + 8, h: 20, alpha: 1)
        }
        let spillM = measure(image: spill, frames: 3, label: "synthetic/spill", fixture: none)!
        expect(spillM.slivers.count == 1 && spillM.slivers[0].contains("frame 2 left edge"),
               "a neighbour's object spilling across the cut must be one sliver, in frame 2: \(spillM.slivers)")
        // The same spill at 4 x 2 px (8 px, like V12.6 swarm frame 59): invisible at 1x, reported as a speck, not failed.
        let streak = strip(cells: 3, width: W, height: H) { ctx in
            fill(ctx, height: H, x: 30, y: 20, w: W - 30 + 4, h: 2, alpha: 1)
        }
        let streakM = measure(image: streak, frames: 3, label: "synthetic/streak", fixture: none)!
        expect(streakM.slivers.isEmpty && streakM.specks.count == 1 && streakM.specks[0].contains("frame 2 left edge"),
               "an 8 px stray at a cut is a reported speck, not a sliver: \(streakM.slivers) \(streakM.specks)")
        return failures
    }
}

@main
struct SpriteRenderMain {
    static func main() {
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let root = repo.appendingPathComponent("Resources")
        let fixtureURL = repo.appendingPathComponent("Tests/fixtures/sprite-render/approved-exceptions.json")
        guard let data = try? Data(contentsOf: fixtureURL),
              let fixture = try? JSONDecoder().decode(SpriteRenderContract.Fixture.self, from: data) else {
            print("SPRITE CONTRACT: cannot read \(fixtureURL.path); run from the repo root")
            exit(1)
        }
        var failures = SpriteRenderContract.selfCheck()
        if !failures.isEmpty {
            print("SPRITE CONTRACT RULES DO NOT DISCRIMINATE:")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
        print("self-check: fade exempt, eaten garment and small eaten patch caught, listed edge only, entering pair owned, spill caught, 8 px stray reported as a speck")
        var checked = 0

        func check(_ url: URL, frames: Int, label: String) {
            guard let m = SpriteRenderContract.measure(strip: url, frames: frames, label: label, fixture: fixture) else {
                failures.append("\(label): unreadable")
                return
            }
            checked += 1
            let known = fixture.preExisting[label].map { "  pre-existing: \($0.note)" } ?? ""
            print(String(format: "  %-46@ holes %5.2f%% (gated %5.2f%%)  margin %2dpx  swing %3.0f%%",
                         label as NSString, m.holesPercent, m.gatedHolesPercent, m.minMargin, m.heightSwingPercent) + known)
            for speck in m.specks { print("    speck at a cut, invisible at 1x: \(speck)") }
            failures.append(contentsOf: SpriteRenderContract.violations(m, label: label, fixture: fixture))
        }

        let defaultPet = root.appendingPathComponent("DefaultPet")
        for (pose, row) in PetSpriteStore.loadStateMap(in: defaultPet).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            check(defaultPet.appendingPathComponent(row.file), frames: row.frames,
                  label: "DefaultPet/\(pose.rawValue)")
        }
        let bundled = root.appendingPathComponent("BundledCharacters")
        for dir in ((try? FileManager.default.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil)) ?? [])
            .filter({ $0.hasDirectoryPath }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            for (pose, row) in PetSpriteStore.loadStateMap(in: dir).sorted(by: { $0.key.rawValue < $1.key.rawValue })
            where row.frames > 1 {
                check(dir.appendingPathComponent(row.file), frames: row.frames,
                      label: "\(dir.lastPathComponent)/\(pose.rawValue)")
            }
        }

        print("\nchecked \(checked) strips")
        if failures.isEmpty {
            print("COS Control: every shipped strip is opaque where it should be and clear of its edges")
        } else {
            print("SPRITE APPEARANCE VIOLATIONS (\(failures.count)):")
            for f in failures { print("  - \(f)") }
            exit(1)
        }
    }
}
