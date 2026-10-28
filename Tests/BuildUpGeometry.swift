import AppKit
import SwiftUI

/// Build-up geometry, measured in points on the real call sites (Tests/run-build-up-geometry.sh <dir>): for every view that
/// shows a build-up skeleton, the skeleton (every COSBuildUp frozen at the drawn wire, its content still loading) against
/// the loaded view (the same site with fixture data, settled), in a narrow (760 pt) and a wide (1280 pt) window, light and
/// dark. Hand-run evidence, never a gate (the gate is the geometry lane in Tests/BuildUpViewChecks.swift).
///
/// What it reads, per site, window and appearance:
///   - the skeleton: the stage's frame (COSBuildUpProbe.stage, the frame the wire draws in) and each placeholder's rect;
///   - the loaded view: the content's frame (the same probe at the first landing frame, where nothing is hidden or
///     resized) and, on the settled pixels, the real rows: card rows by their fill, divided rows by their rules, and the
///     bounding box of everything drawn (ink) for the rest.
/// Writes <dir>/<site>-<width>-<theme>-skeleton.png and -loaded.png, <dir>/geometry.md and <dir>/geometry.json.
/// No window is ordered in, no event is sent, nothing becomes active.
@main @MainActor struct BuildUpGeometry {
    typealias Measure = BuildUpSites.Measure

    static let sizes = [CGSize(width: 760, height: 900), CGSize(width: 1280, height: 900)]

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let only = CommandLine.arguments.count > 2 ? Set(CommandLine.arguments[2].split(separator: ",").map(String.init)) : nil
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        UserDefaults.standard.set(false, forKey: TodayHome.quietHoursKey)
        var all: [Measure] = []
        for size in sizes { _ = BuildUpSites.railWidth(size) }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for size in sizes {
                for site in BuildUpSites.all() where only == nil || only!.contains(site.name) {
                    let m = try BuildUpSites.measure(site, size: size, appearance: appearance, out: out)
                    all.append(m)
                    print(line(m))
                }
            }
        }
        let json = JSONEncoder()
        json.outputFormatting = [.prettyPrinted, .sortedKeys]
        try json.encode(all).write(to: out.appendingPathComponent("geometry.json"))
        try table(all).write(to: out.appendingPathComponent("geometry.md"), atomically: true, encoding: .utf8)
        print("build up geometry: \(all.count) measures, \(all.count * 2) PNGs in \(out.path)")
    }

    nonisolated static func f(_ v: Double) -> String { String(format: "%.0f", v) }
    nonisolated static func line(_ m: Measure) -> String {
        let sk = m.skFrame.count == 4 ? "\(f(m.skFrame[2]))x\(f(m.skFrame[3]))@\(f(m.skFrame[0]))" : "-"
        let ld = m.ldFrame.count == 4 ? "\(f(m.ldFrame[2]))x\(f(m.ldFrame[3]))@\(f(m.ldFrame[0]))" : "-"
        return "geometry \(m.site) \(m.width) \(m.theme): skeleton \(sk) rows \(m.skRows) x\(f(m.skRowX)) w\(f(m.skRowW)) h\(f(m.skRowH)) extent \(f(m.skExtent)) | "
            + "loaded \(ld) rows \(m.ldRows) x\(f(m.ldRowX)) w\(f(m.ldRowW)) h\(f(m.ldRowH)) extent \(f(m.ldExtent)) ink \(m.ldInk.map(f)) \(m.note)"
    }

    nonisolated static func table(_ all: [Measure]) -> String {
        var s = "| Site | Window | Theme | Skeleton frame w x h | Loaded frame w x h | Row x (sk / ld) | Row w (sk / ld) | Row h (sk / ld) | Rows (sk / ld) | Filled height (sk / ld) | Note |\n"
        s += "|---|---|---|---|---|---|---|---|---|---|---|\n"
        for m in all {
            let sk = m.skFrame.count == 4 ? "\(f(m.skFrame[2])) x \(f(m.skFrame[3]))" : "none"
            let ld = m.ldFrame.count == 4 ? "\(f(m.ldFrame[2])) x \(f(m.ldFrame[3]))" : "none"
            s += "| \(m.site)\(m.alone ? " (pane alone)" : "") | \(m.width) | \(m.theme) | \(sk) | \(ld) | \(f(m.skRowX)) / \(f(m.ldRowX)) | \(f(m.skRowW)) / \(f(m.ldRowW)) | "
            s += "\(f(m.skRowH)) / \(f(m.ldRowH)) | \(m.skRows) / \(m.ldRows) | \(f(m.skExtent)) / \(f(m.ldExtent)) | \(m.note) |\n"
        }
        return s
    }

    static func fresh() { BuildUpSites.fresh() }
    static func bitmap(_ view: some View, size: CGSize, appearance: NSAppearance.Name) -> NSBitmapImageRep {
        BuildUpSites.bitmap(view, size: size, appearance: appearance)
    }
    static func png(_ rep: NSBitmapImageRep, _ url: URL) throws { try BuildUpSites.png(rep, url) }
}
