import AppKit
import SwiftUI

// The SwiftUI half of the Markdown renderer (0.5.232): see COSMarkdownParser.swift for
// the block model, the parser and the rationale. Everything here is the pane's own
// vocabulary: Fraunces for headings with a hairline under them, DM Sans for body,
// JetBrains Mono for labels and speaker names, the raised card for tables and
// disclosures.

// MARK: - Inline text

enum COSMarkdownInline {
    /// Bold, italic, code and links through the parser's inline layer (web links only);
    /// what it cannot parse renders verbatim, never dropped.
    /// `italicSize`: the DM Sans body size the run sits in. DM Sans ships no italic face, so
    /// an `*emphasis*` run would draw upright; it takes the system italic at the same size.
    static func attributed(_ text: String, italicSize: CGFloat? = nil) -> AttributedString {
        var string = COSMarkdownParser.inline(text)
        for run in string.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            if let italicSize, intent.contains(.emphasized), !intent.contains(.code) {
                string[run.range].font = .system(size: italicSize, weight: intent.contains(.stronglyEmphasized) ? .bold : .regular).italic()
            }
        }
        // Inline code in the COS files is a marker as often as code: `[REVIEW]`, `[BLOCKED]`.
        for run in string.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.code) else { continue }
            string[run.range].font = COSType.mono(11, weight: .medium)
            let body = String(string[run.range].characters)
            if body.hasPrefix("["), body.hasSuffix("]") {
                string[run.range].foregroundColor = COSPalette.accent
            }
        }
        return string
    }

    /// Marks every case-insensitive occurrence of `query` in the RENDERED characters, so a
    /// search term inside `**bold**` still lights up. Yellow on dark, amber on light; both
    /// carry dark ink (the Messages search mark, 2026-08-31).
    static func highlighting(_ base: AttributedString, query: String, dark: Bool) -> AttributedString {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 2 else { return base }
        var string = base
        let plain = String(string.characters)
        let fill = dark ? Color(red: 1.0, green: 0.85, blue: 0.30) : Color(red: 1.0, green: 0.80, blue: 0.20)
        var from = plain.startIndex
        while let r = plain.range(of: needle, options: .caseInsensitive, range: from..<plain.endIndex) {
            let lo = string.characters.index(string.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: r.lowerBound))
            let hi = string.characters.index(lo, offsetBy: plain.distance(from: r.lowerBound, to: r.upperBound))
            string[lo..<hi].backgroundColor = fill
            string[lo..<hi].foregroundColor = Color.black
            from = r.upperBound
        }
        return string
    }
}

/// Inline runs, built once per distinct string. Before 2026-10-09 every redraw of every
/// paragraph re-ran Foundation's Markdown parser; a long Messages answer redraws on every
/// scroll and every streamed token.
@MainActor
enum COSMarkdownInlineCache {
    private static var runs: [String: AttributedString] = [:]
    private static var plains: [String: String] = [:]
    static let capacity = 1024
    private(set) static var parseCount = 0

    static func attributed(_ text: String, italicSize: CGFloat? = nil) -> AttributedString {
        let key = "\(italicSize ?? 0)|" + text
        if let hit = runs[key] { return hit }
        parseCount += 1
        if runs.count >= capacity { runs.removeAll(keepingCapacity: true) }
        let built = COSMarkdownInline.attributed(text, italicSize: italicSize)
        runs[key] = built
        return built
    }

    /// A list row's one-line preview of a Markdown answer.
    static func plain(_ text: String) -> String {
        if let hit = plains[text] { return hit }
        if plains.count >= capacity { plains.removeAll(keepingCapacity: true) }
        let built = COSMarkdownParser.plainText(text)
        plains[text] = built
        return built
    }
}

private struct COSMarkdownHighlightKey: EnvironmentKey { static let defaultValue = "" }

extension EnvironmentValues {
    /// A search term the rendered document marks wherever it appears (Messages search).
    var cosMarkdownHighlight: String {
        get { self[COSMarkdownHighlightKey.self] }
        set { self[COSMarkdownHighlightKey.self] = newValue }
    }
}

/// One run of inline Markdown as a Text: cached runs, plus the search mark when one is set.
/// Links keep SwiftUI's own open action (the default browser), the path every pane uses.
struct COSMarkdownText: View {
    let text: String
    /// The DM Sans size this text is set in, for the italic fallback; nil for display and mono.
    var bodySize: CGFloat? = nil
    @Environment(\.cosMarkdownHighlight) private var highlight
    @Environment(\.colorScheme) private var colorScheme

    init(_ text: String, bodySize: CGFloat? = nil) { self.text = text; self.bodySize = bodySize }

    var body: some View {
        let runs = COSMarkdownInlineCache.attributed(text, italicSize: bodySize)
        Text(highlight.isEmpty ? runs : COSMarkdownInline.highlighting(runs, query: highlight, dark: colorScheme == .dark))
    }
}

// MARK: - View

/// Parsed documents, kept for the life of this process. A resize must not parse the review
/// again, and neither must a redraw of a Messages answer (2026-10-09: the one-slot cache this
/// replaced re-parsed every turn of a session pane on every redraw, because two documents on
/// screen evicted each other). A caller with a stable id (a message) holds ONE slot per id,
/// so a streaming answer replaces its own entry instead of filling the cache; the stored text
/// is compared on every hit, so a hash collision can never hand back another document.
@MainActor
enum COSMarkdownCache {
    private struct Entry { let text: String; let dropLeadingTitle: Bool; let blocks: [COSMarkdownBlock] }
    private static var entries: [String: Entry] = [:]
    private static var order: [String] = []
    static let capacity = 128
    private(set) static var parseCount = 0

    static func blocks(_ text: String, id: String? = nil, dropLeadingTitle: Bool = false) -> [COSMarkdownBlock] {
        let key = id.map { "id:\($0)|\(dropLeadingTitle)" } ?? "h:\(text.hashValue)|\(text.utf16.count)|\(dropLeadingTitle)"
        if let hit = entries[key], hit.dropLeadingTitle == dropLeadingTitle, hit.text == text {
            touch(key)
            return hit.blocks
        }
        parseCount += 1
        let blocks = COSMarkdownParser.parse(text, dropLeadingTitle: dropLeadingTitle)
        entries[key] = Entry(text: text, dropLeadingTitle: dropLeadingTitle, blocks: blocks)
        touch(key)
        while order.count > capacity { entries.removeValue(forKey: order.removeFirst()) }
        return blocks
    }

    private static func touch(_ key: String) {
        if let i = order.firstIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }
}

/// The pane body. `dropLeadingTitle` when the pane header already shows the H1.
/// `cacheID` (a message id) keeps one parsed slot per message; see COSMarkdownCache.
struct COSMarkdownView: View {
    let text: String
    var cacheID: String? = nil
    var dropLeadingTitle = false
    var bodySize: CGFloat = 12.5

    var body: some View {
        COSMarkdownBlocks(blocks: COSMarkdownCache.blocks(text, id: cacheID, dropLeadingTitle: dropLeadingTitle), bodySize: bodySize)
    }
}

struct COSMarkdownBlocks: View {
    let blocks: [COSMarkdownBlock]
    var bodySize: CGFloat = 12.5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                COSMarkdownBlockView(block: block, bodySize: bodySize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct COSMarkdownBlockView: View {
    let block: COSMarkdownBlock
    var bodySize: CGFloat = 12.5

    var body: some View {
        switch block {
        case .heading(let level, let text):
            heading(level: level, text: text)
        case .paragraph(let text):
            COSMarkdownText(text, bodySize: bodySize)
                .font(COSType.body(bodySize))
                .lineSpacing(2.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .list(let ordered, let items):
            COSMarkdownList(ordered: ordered, items: items, bodySize: bodySize)
        case .table(let header, let rows):
            COSMarkdownTable(header: header, rows: rows, bodySize: bodySize)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(COSType.mono(11))
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(COSPalette.raised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(COSPalette.line, lineWidth: 1))
        case .quote(let inner):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1).fill(COSPalette.gold.opacity(0.7)).frame(width: 2)
                COSMarkdownBlocks(blocks: inner, bodySize: bodySize)
                    .foregroundStyle(COSPalette.muted)
            }
        case .rule:
            Rectangle().fill(COSPalette.line).frame(height: 1).padding(.vertical, 4)
        case .details(let summary, let inner):
            COSMarkdownDetails(summary: summary, blocks: inner, bodySize: bodySize)
        case .speakerLines(let lines):
            COSMarkdownSpeakerLines(lines: lines, bodySize: bodySize)
        }
    }

    @ViewBuilder
    private func heading(level: Int, text: String) -> some View {
        switch level {
        case 1:
            COSMarkdownText(text)
                .font(COSType.display(20, weight: .medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        case 2:
            // The section heading the files lean on: Fraunces with a hairline under it.
            VStack(alignment: .leading, spacing: 6) {
                COSMarkdownText(text)
                    .font(COSType.display(17, weight: .medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(COSPalette.line).frame(height: 1)
            }
            .padding(.top, 10)
        case 3:
            COSMarkdownText(text, bodySize: 13)
                .font(COSType.body(13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        default:
            COSMarkdownText(text.uppercased())
                .font(COSType.mono(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }
}

private struct COSMarkdownList: View {
    let ordered: Bool
    let items: [COSMarkdownListItem]
    let bodySize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(index: index, item: item)
                    VStack(alignment: .leading, spacing: 4) {
                        COSMarkdownText(item.text, bodySize: bodySize)
                            .font(COSType.body(bodySize))
                            .lineSpacing(2.5)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if !item.children.isEmpty {
                            COSMarkdownBlocks(blocks: item.children, bodySize: bodySize)
                        }
                    }
                }
            }
        }
        .padding(.leading, 2)
    }

    @ViewBuilder
    private func marker(index: Int, item: COSMarkdownListItem) -> some View {
        if let checked = item.checked {
            // A task box: the scribe's `- [ ]`. Checked fills gold with an ink tick.
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(checked ? COSPalette.gold : Color.clear)
                RoundedRectangle(cornerRadius: 3)
                    .stroke(checked ? COSPalette.gold : COSPalette.muted.opacity(0.7), lineWidth: 1.2)
                if checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(COSPalette.ink)
                }
            }
            .frame(width: 13, height: 13)
            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 2 }
        } else if ordered {
            Text("\(index + 1).")
                .font(COSType.mono(10.5, weight: .medium))
                .foregroundStyle(COSPalette.muted)
                .frame(minWidth: 16, alignment: .trailing)
        } else {
            Text("•")
                .font(COSType.body(bodySize, weight: .semibold))
                .foregroundStyle(COSPalette.muted)
        }
    }
}

private struct COSMarkdownTable: View {
    let header: [String]
    let rows: [[String]]
    let bodySize: CGFloat

    /// Two columns with a bold first cell in every row is the scribe's key/value block.
    private var isKeyValue: Bool {
        header.count == 2 && !rows.isEmpty && rows.allSatisfy { $0.count == 2 && $0[0].hasPrefix("**") }
    }

    var body: some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                if !isKeyValue {
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            cell(c < header.count ? header[c] : "", header: true)
                        }
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { c in
                            cell(c < row.count ? row[c] : "", header: false, key: isKeyValue && c == 0)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(COSPalette.line, lineWidth: 1))
        }
    }

    private func cell(_ text: String, header: Bool, key: Bool = false) -> some View {
        COSMarkdownText(text, bodySize: bodySize - 0.5)
            .font(COSType.body(bodySize - 0.5, weight: header ? .semibold : .regular))
            .foregroundStyle(key ? Color.secondary : Color.primary)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((header || key) ? COSPalette.raised : Color.clear)
            .overlay(Rectangle().stroke(COSPalette.line.opacity(0.7), lineWidth: 0.5))
    }
}

private struct COSMarkdownDetails: View {
    let summary: String
    let blocks: [COSMarkdownBlock]
    let bodySize: CGFloat
    @State private var expanded = true

    private var count: String? {
        for block in blocks {
            if case .speakerLines(let lines) = block {
                let speakers = Set(lines.map(\.speaker)).count
                return "\(lines.count) line\(lines.count == 1 ? "" : "s") · \(speakers) speaker\(speakers == 1 ? "" : "s")"
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(COSPalette.muted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    // The scribe's summary is "Click to expand transcript" under a
                    // "## Transcript" heading; saying Transcript twice is noise, so that
                    // generic summary becomes the count and a real summary keeps its words.
                    let generic = summary.lowercased().hasPrefix("click to expand")
                    if generic {
                        Text(count ?? "Show").font(COSType.body(bodySize, weight: .semibold))
                    } else {
                        Text(summary).font(COSType.body(bodySize, weight: .semibold))
                    }
                    Spacer()
                    if !generic, let count {
                        Text(count).font(COSType.mono(10.5)).foregroundStyle(COSPalette.muted)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Rectangle().fill(COSPalette.line).frame(height: 1)
                COSMarkdownBlocks(blocks: blocks, bodySize: bodySize)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .background(COSPalette.raised)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(COSPalette.line, lineWidth: 1))
    }
}

private struct COSMarkdownSpeakerLines: View {
    let lines: [COSMarkdownSpeakerLine]
    let bodySize: CGFloat

    /// The scribe's labels for a voice it could not name.
    private func isUnnamed(_ speaker: String) -> Bool {
        let s = speaker.lowercased()
        return s == "ext" || s.hasPrefix("speaker ") || s.hasPrefix("unknown")
    }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                GridRow {
                    Text(line.speaker)
                        .font(COSType.mono(10.5, weight: .semibold))
                        .foregroundStyle(isUnnamed(line.speaker) ? COSPalette.muted : COSPalette.accent)
                        .frame(width: 96, alignment: .leading)
                        .padding(.top, 2)
                    COSMarkdownText(line.text, bodySize: bodySize)
                        .font(COSType.body(bodySize))
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
