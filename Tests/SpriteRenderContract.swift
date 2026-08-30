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
// Run: swiftc Sources/Models.swift Tests/SpriteRenderContract.swift -framework AppKit

import AppKit

enum SpriteRenderContract {
    struct Measure {
        var holesPercent: Double
        var minMargin: Int
        var heightSwingPercent: Double
    }

    /// Share of solid pixels that are see-through holes, tightest edge margin,
    /// and height swing, across every cell of a strip.
    static func measure(strip url: URL, frames: Int) -> Measure? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let cells = PetSpriteStrip.slice(image, frames: frames).compactMap { PetSpriteStrip.raster($0) }
        guard !cells.isEmpty else { return nil }

        var holed = 0
        var opaque = 0
        var minMargin = Int.max
        var heights: [Int] = []

        for cg in cells {
            let w = cg.width, h = cg.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            px.withUnsafeMutableBytes { buffer in
                CGContext(
                    data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            func alpha(_ x: Int, _ y: Int) -> Int { Int(px[(y * w + x) * 4 + 3]) }

            var top = h, bottom = -1, left = w, right = -1
            for y in 0..<h {
                for x in 0..<w where alpha(x, y) > 40 {
                    if y < top { top = y }
                    if y > bottom { bottom = y }
                    if x < left { left = x }
                    if x > right { right = x }
                }
            }
            guard bottom >= top, right >= left else { continue }
            heights.append(bottom - top + 1)
            minMargin = min(minMargin, min(left, w - 1 - right, top, h - 1 - bottom))

            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let a = alpha(x, y)
                    if a > 235 { opaque += 1 }
                    // Interior only: all four neighbours inked. An edge pixel
                    // has an empty neighbour and is legitimate antialiasing.
                    if a > 25, a < 205,
                       alpha(x - 1, y) > 25, alpha(x + 1, y) > 25,
                       alpha(x, y - 1) > 25, alpha(x, y + 1) > 25 {
                        holed += 1
                    }
                }
            }
        }

        let tallest = Double(heights.max() ?? 1)
        let shortest = Double(heights.min() ?? 0)
        return Measure(
            holesPercent: Double(holed) / Double(max(opaque, 1)) * 100,
            minMargin: minMargin == Int.max ? 0 : minMargin,
            heightSwingPercent: (tallest - shortest) / max(tallest, 1) * 100
        )
    }

    static let maxHolesPercent = 1.0
    static let minEdgeMargin = 6

    /// Empty when the strip is acceptable; otherwise one line per violation.
    static func violations(_ m: Measure, label: String) -> [String] {
        var out: [String] = []
        if m.holesPercent > maxHolesPercent {
            out.append(String(
                format: "%@: %.2f%% of the figure is see-through (max %.1f%%). Interior alpha was eaten; the garment reads translucent on screen.",
                label, m.holesPercent, maxHolesPercent))
        }
        if m.minMargin < minEdgeMargin {
            out.append(
                "\(label): figure comes within \(m.minMargin)px of a cell edge (min \(minEdgeMargin)px). Reads as cropped.")
        }
        return out
    }
}

@main
struct SpriteRenderMain {
    static func main() {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources")
        var failures: [String] = []
        var checked = 0

        func check(_ url: URL, frames: Int, label: String) {
            guard let m = SpriteRenderContract.measure(strip: url, frames: frames) else {
                failures.append("\(label): unreadable")
                return
            }
            checked += 1
            print(String(format: "  %-46@ holes %5.2f%%  margin %2dpx  swing %3.0f%%",
                         label as NSString, m.holesPercent, m.minMargin, m.heightSwingPercent))
            failures.append(contentsOf: SpriteRenderContract.violations(m, label: label))
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
