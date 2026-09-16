import AppKit
import SwiftUI

// The SwiftUI half of the Markdown renderer (0.5.232): see COSMarkdownParser.swift for
// the block model, the parser and the rationale. Everything here is the pane's own
// vocabulary: Fraunces for headings with a hairline under them, DM Sans for body,
// JetBrains Mono for labels and speaker names, the raised card for tables and
// disclosures.

// MARK: - Inline text

enum COSMarkdownInline {
    /// Bold, italic, code and links through Foundation's inline-only parser; what it
    /// cannot parse renders verbatim, never dropped.
    static func attributed(_ text: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        var string: AttributedString
        do {
            string = try AttributedString(markdown: text, options: options)
        } catch {
            string = AttributedString(text)
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
}

// MARK: - View

/// The pane body. `dropLeadingTitle` when the pane header already shows the H1.
struct COSMarkdownView: View {
    let text: String
    var dropLeadingTitle = false
    var bodySize: CGFloat = 12.5

    var body: some View {
        let blocks = COSMarkdownParser.parse(text, dropLeadingTitle: dropLeadingTitle)
        COSMarkdownBlocks(blocks: blocks, bodySize: bodySize)
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
            Text(COSMarkdownInline.attributed(text))
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
            Text(COSMarkdownInline.attributed(text))
                .font(COSType.display(20, weight: .medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        case 2:
            // The section heading the files lean on: Fraunces with a hairline under it.
            VStack(alignment: .leading, spacing: 6) {
                Text(COSMarkdownInline.attributed(text))
                    .font(COSType.display(17, weight: .medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(COSPalette.line).frame(height: 1)
            }
            .padding(.top, 10)
        case 3:
            Text(COSMarkdownInline.attributed(text))
                .font(COSType.body(13, weight: .semibold))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        default:
            Text(COSMarkdownInline.attributed(text.uppercased()))
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
                        Text(COSMarkdownInline.attributed(item.text))
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
        Text(COSMarkdownInline.attributed(text))
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
                    Text(COSMarkdownInline.attributed(line.text))
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
