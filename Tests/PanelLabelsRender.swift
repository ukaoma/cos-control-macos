import AppKit
import SwiftUI
import Vision

/// 0.5.253 (Miles, 2026-09-30 16:51, with screenshots): "Center the refresh icon on Check for updates." and "There are
/// several places where that same top vertical alignment is happening." The shipped menu-bar panel (`ControlPanel`,
/// the real Views.swift) rendered off screen, light and dark, whole (its scroll view's document, top to bottom), with
/// the two buttons he pointed at, "Check for updates" in the updates card and "Create Folders" in the buttons grid, and
/// one-line icon buttons beside them.
///
/// A button is read from the pixels alone. Vision finds its words (each line of them); the words' block is the union
/// of those lines. In the 8 pt gap between the icon and the words, a column runs from the button's top hairline to its
/// bottom one: the middle of those two is the text block's middle (the label sits between equal padding, and the words
/// are its tallest part). The icon is the ink left of the gap, between those hairlines; its middle is its ink's middle.
///
/// Nothing here contacts the server or a provider: Tests/run-controls.sh runs it with a scratch home
/// (CFFIXED_USER_HOME), so the panel's own loads find no helper. Its window is never ordered in (0.5.253), the process can
/// never become active (.prohibited), and no event is sent or posted.
@MainActor enum PanelLabels {
    struct Measure: CustomStringConvertible {
        let name: String
        let appearance: String
        let lines: Int
        /// Points from the top of the panel's document.
        let iconMid: CGFloat
        let blockMid: CGFloat
        let button: CGRect
        var offBy: CGFloat { abs(iconMid - blockMid) }
        var description: String {
            String(format: "%@ (%@, %d line%@): icon middle %.2f, text block middle %.2f, off by %.2f pt",
                   name, appearance, lines, lines == 1 ? "" : "s", iconMid, blockMid, offBy)
        }
    }

    /// The two buttons Miles pointed at, and one-line icon buttons in the same panel.
    static let targets = ["Check for updates", "Create Folders", "Work Folder", "Run Doctor"]

    static func model() -> ControllerModel {
        let model = ControllerModel(startBackgroundWork: false)
        precondition(!model.backgroundWorkEnabled)
        // A managed, healthy server whose COS Data notes folder is chosen but has no memory/ or threads/ yet: the panel
        // offers Create Folders beside the folder's path, and with no update waiting the card carries Check for updates.
        model.status = ServerStatus([
            "installed": .bool(true), "serviceLoaded": .bool(true), "running": .bool(true), "managedContract": .bool(true),
            "runtimeState": .string("managedHealthy"), "ownershipVerified": .bool(true),
            "version": .string("6.59.0"), "installedVersion": .string("6.59.0"),
            "contextSuggestedRoot": .string("/Users/you/Documents/COS Data"),
            "contextFilesDirectory": .string("/Users/you/Documents/COS Data"),
        ])
        return model
    }

    /// The panel's whole document in one appearance, as AppKit draws it, with legacy scroll bars (a Mac with a mouse:
    /// they take some of the panel's width, where these labels wrap).
    static func render(_ appearance: NSAppearance.Name) -> (NSBitmapImageRep, CGSize) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = model()
        let host = NSHostingView(rootView: ControlPanel(model: model, openActivity: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 390, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 390, height: 640)
        // 0.5.253: never ordered in, even off screen. SwiftUI lays out and draws a window that is not on screen.
        defer { window.close() }
        pump(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); pump()
        guard let scroll = scrollView(in: host), let document = scroll.documentView else { fatalError("the panel has no scroll view") }
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        pump(); host.layoutSubtreeIfNeeded(); pump()
        precondition(model.error == nil, "the panel raised an error while rendering: \(model.error ?? "")")
        document.layoutSubtreeIfNeeded(); document.displayIfNeeded()
        guard let rep = document.bitmapImageRepForCachingDisplay(in: document.bounds) else { fatalError("no bitmap") }
        document.cacheDisplay(in: document.bounds, to: rep)
        return (rep, document.bounds.size)
    }

    /// Renders both appearances, measures every target, and writes PNGs (the updates card, the buttons grid, the whole
    /// panel) to `output` when given, named `label`-....
    static func run(output: URL?, label: String) -> [Measure] {
        if let output { try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        var out: [Measure] = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let word = appearance == .darkAqua ? "dark" : "light"
            let (rep, size) = render(appearance)
            let lines = recognizedLines(rep, size: size)
            var buttons: [String: CGRect] = [:]
            for name in targets {
                guard let measure = measure(name, lines: lines, rep: rep, size: size, appearance: word) else {
                    fatalError("could not find \u{201C}\(name)\u{201D}, its icon and its words in the panel (\(word)); read: \(lines.map(\.text))")
                }
                buttons[name] = measure.button
                out.append(measure)
            }
            if let output {
                let card = buttons["Check for updates"]!
                write(rep, size: size, crop: CGRect(x: 0, y: max(0, card.minY - 20), width: size.width, height: card.height + 40),
                      appearance: appearance, to: output.appendingPathComponent("\(label)-updates-card-\(word).png"))
                let grid = buttons["Create Folders"]!.union(buttons["Work Folder"]!)
                let top = max(0, grid.minY - 80), bottom = min(size.height, grid.maxY + 80)
                write(rep, size: size, crop: CGRect(x: 0, y: top, width: size.width, height: bottom - top),
                      appearance: appearance, to: output.appendingPathComponent("\(label)-buttons-grid-\(word).png"))
                write(rep, size: size, crop: CGRect(origin: .zero, size: size), appearance: appearance,
                      to: output.appendingPathComponent("\(label)-panel-\(word).png"))
            }
        }
        return out
    }

    // MARK: - Reading the pixels

    static func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    struct Line { let text: String; let box: CGRect }

    /// Every line of words Vision reads in the render, with its box in points from the top left.
    static func recognizedLines(_ rep: NSBitmapImageRep, size: CGSize) -> [Line] {
        guard let image = rep.cgImage else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { fatalError("Vision could not read the render: \(error)") }
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let b = observation.boundingBox
            return Line(text: text, box: CGRect(x: b.minX * size.width, y: (1 - b.maxY) * size.height, width: b.width * size.width, height: b.height * size.height))
        }
    }

    static func luminance(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh, let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return -1 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    /// The words' block: a line that ends with the whole name, or (wrapped) a line ending with its first words and the
    /// line right under it holding the rest. Vision may read the icon as a character or two of the line: the icon's
    /// gap is found in the pixels, not from this box.
    static func block(_ name: String, lines: [Line]) -> (CGRect, Int)? {
        if let whole = lines.first(where: { $0.text.hasSuffix(name) }) { return (whole.box, 1) }
        let words = name.split(separator: " ").map(String.init)
        for split in 1..<words.count {
            let head = words[..<split].joined(separator: " "), tail = words[split...].joined(separator: " ")
            for first in lines where first.text.hasSuffix(head) {
                guard let second = lines.first(where: { $0.text == tail && $0.box.minY > first.box.minY && $0.box.minY - first.box.maxY < 10
                                                          && $0.box.minX < first.box.maxX && $0.box.maxX > first.box.minX }) else { continue }
                return (first.box.union(second.box), 2)
            }
        }
        return nil
    }

    static func measure(_ name: String, lines: [Line], rep: NSBitmapImageRep, size: CGSize, appearance: String) -> Measure? {
        guard let (words, count) = block(name, lines: lines) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / size.width
        let point = Int(scale.rounded())
        let rows = Int(words.minY * scale)..<Int(words.maxY * scale)
        // The button's fill: the most common shade across the words' box (most of it is the space around letters).
        var shades: [Int: Int] = [:]
        for y in rows { for x in Int(words.minX * scale)..<Int(words.maxX * scale) { shades[Int(luminance(rep, x, y) * 200), default: 0] += 1 } }
        guard let common = shades.max(by: { $0.value < $1.value })?.key else { return nil }
        let fill = CGFloat(common) / 200
        func off(_ x: Int, _ y: Int, by threshold: CGFloat) -> Bool { abs(luminance(rep, x, y) - fill) > threshold }
        func inked(_ x: Int) -> Bool { rows.contains { off(x, $0, by: 0.3) } }
        // The gap between the icon and the words: the first run of 5 pt with no ink, walking left from the words' middle
        // (the space between two words is about 3 pt; the gap after an icon is 8).
        var x = Int(words.midX * scale), run = 0
        while x > 0, run < 5 * point { run = inked(x) ? 0 : run + 1; x -= 1 }
        guard run >= 5 * point else { return nil }
        let gap = x + run / 2, wordsLeft = x + run
        // From the words' middle, up and down the gap to the button's hairlines.
        let middle = Int(words.midY * scale)
        var top = middle, bottom = middle
        while top > 0, !off(gap, top, by: 0.03) { top -= 1 }
        while bottom < rep.pixelsHigh - 1, !off(gap, bottom, by: 0.03) { bottom += 1 }
        guard CGFloat(bottom - top) / scale >= 14, top < rows.lowerBound + 4 * point, bottom > rows.upperBound - 4 * point else { return nil }
        // The icon: the ink left of the gap, inside the hairlines (2 pt in), at most 26 pt wide.
        var iconTop: Int?, iconBottom: Int?, iconLeft = gap
        for y in (top + 2 * point)..<(bottom - 2 * point) {
            for x in max(0, gap - 26 * point)..<gap where off(x, y, by: 0.3) {
                iconTop = iconTop ?? y; iconBottom = y; iconLeft = min(iconLeft, x)
            }
        }
        guard let iconTop, let iconBottom else { return nil }
        let left = CGFloat(iconLeft) / scale - 10
        let button = CGRect(x: left, y: CGFloat(top) / scale, width: max(words.maxX, CGFloat(wordsLeft) / scale) - left + 10,
                            height: CGFloat(bottom - top + 1) / scale)
        return Measure(name: name, appearance: appearance, lines: count,
                       iconMid: CGFloat(iconTop + iconBottom + 1) / 2 / scale,
                       blockMid: CGFloat(top + bottom + 1) / 2 / scale, button: button)
    }

    /// Writes a crop of the render as a PNG, over the panel's own background (the scroll view's document draws none).
    static func write(_ rep: NSBitmapImageRep, size: CGSize, crop: CGRect, appearance: NSAppearance.Name, to url: URL) {
        let scale = CGFloat(rep.pixelsWide) / size.width
        let pixels = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale).integral
        guard let image = rep.cgImage?.cropping(to: pixels),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fatalError("no crop") }
        var panel = NSColor.white
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance { panel = NSColor(COSPalette.panel).usingColorSpace(.sRGB) ?? .white }
        context.setFillColor(panel.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flat = context.makeImage(), let png = NSBitmapImageRep(cgImage: flat).representation(using: .png, properties: [:]) else { fatalError("no PNG") }
        do { try png.write(to: url) } catch { fatalError("could not write \(url.path): \(error)") }
    }
}
