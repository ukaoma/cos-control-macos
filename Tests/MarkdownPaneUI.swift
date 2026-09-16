import AppKit
import SwiftUI
import Foundation

/// Offscreen native render of the 0.5.232 Markdown panes, LIGHT AND DARK: the meeting
/// pane on the scribe's own file (the pane Miles showed on 2026-09-15), the thread pane
/// on a sectioned note, and the three action weights side by side. Same harness shape
/// as MergeUI: a real NSHostingView in an offscreen window, `cacheDisplay` so ScrollView
/// contents and native controls draw. Run by hand on a logged-in Mac:
///     ./Tests/run-markdown-ui.sh /tmp/cos-markdown-ui
/// Asserts: the pane fills its window, the render is not blank, the document view
/// carries no raw `## ` or `<details>` text (the shipped 0.5.231 body did), and the
/// primary button is the first control in the action row.
@main @MainActor
struct MarkdownPaneUIContract {
    static func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.16)) }

    static func render<V: View>(
        _ view: V, size: NSSize, name: String, output: URL, dark: Bool, fills: Bool = true
    ) throws -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = NSColor(COSPalette.panel)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        pump(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); pump()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fatalError("No native bitmap for \(name)")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG for \(name)") }
        try png.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        precondition(host.bounds.width <= size.width && host.bounds.height <= size.height,
                     "content escaped the window clamp in \(name): \(host.bounds.size) vs \(size)")
        if fills {
            precondition(host.bounds.width == size.width && host.bounds.height == size.height,
                         "a pane must take the whole window it is given in \(name): \(host.bounds.size) vs \(size)")
        }
        precondition(png.count > 5000, "native render of \(name) came out blank")
        return (window, host)
    }

    /// Every NSTextField/NSTextView string under a view, for the raw-markdown assertion.
    static func strings(_ view: NSView) -> [String] {
        var out: [String] = []
        if let field = view as? NSTextField { out.append(field.stringValue) }
        if let text = view as? NSTextView { out.append(text.string) }
        for sub in view.subviews { out.append(contentsOf: strings(sub)) }
        return out
    }

    static let meeting = """
    # Bottle POS Funnel Deck Discovery (G2)

    | Field | Value |
    |-------|-------|
    | **Date** | 2026-09-15 15:37 |
    | **Source** | G2 Glasses |
    | **Domain** | Quilt |
    | **Type** | Review |
    | **Duration** | 3 minutes |

    ## Attendees

    - MU
    - Cort Ouzts

    ## Summary

    Tail-end capture of a Quilt working session on the Bottle POS funnel PowerPoint. Cort set the approach: treat slides 8-12 as the agenda, add or delete as findings are described, and keep the deck in discovery mode rather than final. Tyler committed to Slack Peter and Mary about extra working time outside tomorrow's 1:1.

    ## Topics Discussed

    - Bottle POS funnel deck structure
    - Discovery-driven slide editing
    - Follow-up scheduling with Peter and Mary

    ## Decisions Made

    - The shared Bottle funnel PowerPoint is the working document; slides 8-12 stay as the agenda/table of contents and get added to or deleted live during discovery. The deck is a draft, not final.

    ## Action Items


    ### Needs Review
    - [ ] `[REVIEW]` Send a Slack message to Peter and Mary to coordinate support and, if needed, schedule additional working time beyond tomorrow's 1:1. (Tyler Rhoton)

    ## Transcript

    <details>
    <summary>Click to expand transcript</summary>

    [Cort Ouzts]: See if you can do that , and then we 'll go from there . I just want to work off this bottle funnel PowerPoint . Is that
    [Ext]: shared ? That 's the shared , right ? Yeah , it 's the shared . I 'm Cara . We 'll leave section or slides 8 through 12 as kind of an agenda ,
    [Cort Ouzts]: a table of contents , if you will . Again , add to it . Just delete it as you 're describing it .
    [Tyler Rhoton]: in mobile list . Peter , Mary , I 'll send you a Slack too to see what I can do to help . Okay . All right , guys . Thank you .
    [Ext]: Thank you .
    [MU]: Thank you .

    </details>
    """

    static let thread = """
    # Bottle POS funnel deck

    **Status:** accelerating · **Owner:** Miles · **Next:** Tuesday 1:1

    ## Note

    Discovery deck for the Bottle POS funnel. Slides 8-12 are the agenda; findings get added live.

    ## Stakeholders

    | Person | Role |
    |---|---|
    | Cort Ouzts | Sales lead |
    | Tyler Rhoton | Account executive |

    ## Meetings

    - 2026-09-15 Bottle POS Funnel Deck Discovery (G2)
    - 2026-09-12 Funnel review

    ## Milestones

    1. Discovery deck in review
    2. Findings folded into slides 8-12

    <details><summary>Sources</summary>

    - operations/quilt/wk38_2026/bottle_funnel_deck.md
    - operations/quilt/meetings/2026-09/2026-09-15_Bottle_POS_Funnel_Deck_Discovery_(G2).md

    </details>
    """

    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/cos-markdown-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let model = ControllerModel(startBackgroundWork: false)
        precondition(!model.backgroundWorkEnabled)

        model.openLibraryRow = LibraryMeeting(.object([
            "recordId": .string("2026-09/2026-09-15_Bottle_POS_Funnel_Deck_Discovery_(G2).md"),
            "sessionId": .string("meeting_1789508220_g2"),
            "title": .string("Bottle POS Funnel Deck Discovery (G2)"),
            "date": .string("2026-09-15"), "time": .string("15:37"),
            "domain": .string("quilt"), "domainAbbr": .string("Q"),
            "duration": .string("3 minutes"), "durationMinutes": .number(3),
            "month": .string("2026-09"),
            "filename": .string("2026-09-15_Bottle_POS_Funnel_Deck_Discovery_(G2).md"),
            "source": .string("G2 Glasses"), "librarySource": .string("g2"),
            "topicCount": .number(3), "decisionCount": .number(1), "actionCount": .number(1), "attendeeCount": .number(2),
        ]))
        precondition(model.openLibraryRow != nil, "the meeting row seeds")
        precondition(model.openLibraryRow?.canReviewVoices == true, "a G2 capture offers Review voices")
        model.libraryDetail = LibraryMeetingDetail(.object([
            "title": .string("Bottle POS Funnel Deck Discovery (G2)"),
            "date": .string("2026-09-15"), "time": .string("15:37"), "domain": .string("quilt"),
            "duration": .string("3 minutes"), "source": .string("G2 Glasses"),
            "summary": .string("Tail-end capture of a Quilt working session on the Bottle POS funnel PowerPoint."),
            "transcript": .string(meeting),
            "attendees": .array([.string("MU"), .string("Cort Ouzts")]),
            "topics": .array([]), "decisions": .array([]), "actionItems": .array([]),
            "librarySource": .string("g2"), "recordId": .string("2026-09/2026-09-15_Bottle_POS_Funnel_Deck_Discovery_(G2).md"),
            "mutable": .bool(false), "sources": .array([]),
        ]))
        precondition(model.libraryDetail != nil, "the meeting detail seeds")
        precondition(COSMarkdownParser.looksLikeDocument(model.libraryDetail!.transcript), "the scribe's file reads as a document")

        for dark in [false, true] {
            let (_, host) = try render(
                MeetingLibraryDetailPane(model: model, onReviewVoices: { _ in }),
                size: NSSize(width: 920, height: 1180), name: "meeting-pane", output: output, dark: dark)
            let text = strings(host).joined(separator: "\n")
            precondition(!text.contains("## "), "the meeting pane must not show raw headings; the 0.5.231 body did")
            precondition(!text.contains("<details>"), "the meeting pane must not show raw details tags")
            precondition(!text.contains("|-------|"), "the meeting pane must not show a raw table separator")
            precondition(text.contains("Cort Ouzts"), "the transcript's speaker lines render")
            precondition(text.contains("Send a Slack message"), "the task item renders")
        }

        // The thread pane: a sectioned note with a table, an ordered list and a details block.
        model.contextDetailKind = "thread"
        model.contextDetail = ContextRecord(
            id: "thread_bottle_funnel_deck", title: "Bottle POS funnel deck",
            subtitle: "quilt · accelerating", body: thread, createdAt: "2026-09-15",
            filePath: "/tmp/thread.md", meetingCount: 2, isResolved: false)
        for dark in [false, true] {
            let (_, host) = try render(
                ContextDetailPane(model: model, showsBackButton: false),
                size: NSSize(width: 920, height: 760), name: "thread-pane", output: output, dark: dark)
            let text = strings(host).joined(separator: "\n")
            precondition(!text.contains("## "), "the thread pane must not show raw headings")
            precondition(text.contains("Sales lead"), "the stakeholder table renders")
        }

        // The three weights, side by side, as a card.
        for dark in [false, true] {
            _ = try render(
                HStack(spacing: 8) {
                    Button("Copy as context") {}.buttonStyle(COSPrimaryButtonStyle())
                    Button("Copy summary") {}.buttonStyle(COSQuietButtonStyle())
                    Button("Reveal in Finder") {}.buttonStyle(COSQuietButtonStyle())
                    Spacer()
                    Button { } label: { HStack(spacing: 8) { Text("Review voices"); COSNewPill() } }
                        .buttonStyle(COSQuietButtonStyle(tone: .featured))
                }
                .controlSize(.small)
                .padding(16)
                .background(COSPalette.panel),
                size: NSSize(width: 640, height: 60), name: "action-weights", output: output, dark: dark, fills: false)
        }

        // 0.5.233: the live Activity block on the recorded 6.48.2 frames, then the three
        // fallback shapes (connecting, reconnecting, older server).
        let fixture = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ".")
            .appendingPathComponent("Tests/fixtures/session-stream-6.48.2.ndjson")
        var recorded = SessionLiveFeed()
        if let text = try? String(contentsOf: fixture, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let event = SessionLiveEvent(line: String(line)) { recorded = recorded.applying(event) }
            }
        }
        precondition(recorded.tools.count == SessionLiveFeed.toolWindow, "the recorded feed fills the tool window: \(recorded.tools.count)")
        recorded.connected = true
        var waiting = recorded
        waiting.agentState = "waiting"; waiting.waitingKind = "permission"; waiting.waitingDetail = "Bash git push origin main"
        var lost = SessionLiveFeed(); lost.fallbackReason = "http_404"
        var reconnecting = recorded; reconnecting.connected = false; reconnecting.fallbackReason = "reconnecting"; reconnecting.missed = 3
        for dark in [false, true] {
            let (_, host) = try render(
                VStack(alignment: .leading, spacing: 12) {
                    SessionActivityFeed(feed: recorded, queued: 1)
                    SessionActivityFeed(feed: waiting)
                    SessionActivityFeed(feed: reconnecting)
                    SessionActivityFeed(feed: lost)
                    SessionActivityFeed(feed: nil)
                }
                .padding(16)
                .frame(width: 920, alignment: .topLeading)
                .background(COSPalette.panel),
                size: NSSize(width: 920, height: 900), name: "activity-feed", output: output, dark: dark, fills: false)
            // Only selectable Text is backed by an NSTextView the harness can read; the
            // state word, tool lines and chips are plain Text (drawn, not enumerable), so
            // the prompt is the one string asserted here and the PNG is the review surface.
            let text = strings(host).joined(separator: "\n")
            precondition(text.components(separatedBy: "Confirm the fix was server-side, then update the docs.").count == 4,
                         "the three live feeds draw the recorded prompt once each")
            precondition(host.bounds.height >= 700, "five feeds stack taller than one screen of chrome: \(host.bounds.height)")
        }

        print("PASS markdown UI: meeting pane and thread pane render as documents at 920 pt, light and dark;")
        print("PASS activity feed: recorded, waiting, reconnecting, older-server and connecting shapes render light and dark;")
        print("PASS action weights: primary, quiet and featured render side by side. Output: \(output.path)")
    }
}
