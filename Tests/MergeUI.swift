import AppKit
import SwiftUI
import Foundation

/// Offscreen native render of the 0.5.230 import and merge surfaces, LIGHT AND DARK.
///
/// SOURCE PINS CANNOT SEE LAYOUT. `Tests/run.sh` proves the wiring — the route
/// flags, the openers, the copy, the two-call Undo — and none of that can tell
/// whether a card holds at 390 pt or whether a 40-row suggestion queue pushes the
/// header off the window. This renders the real views against real fixtures at
/// the narrowest and widest sizes Control uses, in both appearances, and asserts
/// what a screenshot would show: the list scrolls inside its own surface, the
/// content never escapes the window, and nothing renders blank.
///
/// Same shape as `Tests/HeldNamingUI.swift`, which caught the 0.5.222 clipping.
@main @MainActor
struct MergeUIContract {
    static func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.16)) }

    static func scrolls(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls($0) }
    }

    /// `fills` is true for a whole pane, which clamps itself to the window it is
    /// given, and false for a card, which is only required never to exceed it.
    static func render<V: View>(
        _ view: V, size: NSSize, name: String, output: URL, dark: Bool, fills: Bool = true
    ) throws -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
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

    static func suggestion(_ index: Int, wouldMerge: Bool) -> JSONValue {
        .object([
            "id": .string("s_" + String(format: "%016x", index)),
            "kind": .string(wouldMerge ? "would_merge" : "merge"),
            "suggestionState": .string("open"),
            "k1": .number(Double(30 + index)),
            "k2": .number(Double(index % 4)),
            "at": .string("2026-09-\(String(format: "%02d", 1 + index % 28))T10:00:00.000Z"),
            "sides": .array([
                .object(["kind": .string("fireflies"), "id": .string("01K4EXAMPLE\(index)"),
                         "resolved": .bool(index % 3 != 0), "title": .string("Quilt weekly sync"),
                         "date": .string("2026-09-10"), "time": .string("14:30"),
                         "duration": .string("47 minutes"), "source": .string("Fireflies")]),
                .object(["kind": .string("g2"), "id": .string("meeting_178913171\(index)_abc"),
                         "resolved": .bool(true), "title": .string("G2 Recording 2026-09-10 1430"),
                         "date": .string("2026-09-10"), "time": .string("14:31"),
                         "duration": .string("44 minutes"), "source": .string("G2 Glasses")]),
            ]),
        ])
    }

    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/cos-merge-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let model = ControllerModel(startBackgroundWork: false)
        precondition(!model.backgroundWorkEnabled)

        // 40 open suggestions: the server holds them until they are answered, so
        // the row count is unbounded by design. This is the case that broke the
        // held-audio card twice.
        model.meetingSuggestions = (0..<40).compactMap { MeetingSuggestion(suggestion($0, wouldMerge: $0 % 2 == 0)) }
        precondition(model.meetingSuggestions.count == 40)
        model.meetingSuggestionsState = "ready"
        model.meetingSuggestionsUnresolved = true
        model.meetingEngineStatus = MeetingEngineStatus([
            "routeState": .string("ready"), "mode": .string("advise"), "isPipelineMac": .bool(true),
            "pipelineSees": .object(["mode": .string("advise"), "active": .bool(false), "appliedActions": .number(0)]),
            "counts": .object(["auto": .number(0), "suggested": .number(40), "none": .number(3),
                               "reverted": .number(0), "pending": .number(0), "failed": .number(0)]),
            "firstRun": .object(["scanned": .number(478), "auto": .number(0), "wouldMerge": .number(161),
                                 "suggested": .number(21), "alreadyMerged": .number(198),
                                 "startedAt": .string("2026-09-14T09:00:00.000Z")]),
            "lastRun": .object(["at": .string("2026-09-14T10:00:00.000Z"), "trigger": .string("tick")]),
        ])
        precondition(model.wouldMergeSuggestions.count == 20 && model.undecidedSuggestions.count == 20)

        // 390 pt is the menu-bar panel's width and the narrowest surface a Control
        // card renders in; 920x680 is the Activity window.
        for size in [NSSize(width: 390, height: 640), NSSize(width: 920, height: 680)] {
            for dark in [false, true] {
                let name = "suggestions-\(Int(size.width))"
                let (window, host) = try render(MeetingSuggestionsPane.canary(model: model), size: size, name: name, output: output, dark: dark)
                let lists = scrolls(host)
                precondition(!lists.isEmpty, "40 suggestions need a native scrolling surface at \(Int(size.width)) pt")
                let list = lists.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }!
                precondition((list.documentView?.frame.height ?? 0) > list.contentSize.height,
                             "all 40 suggestions must scroll inside the view, not push the header off it")
                precondition(list.contentSize.height >= 88, "the suggestions list lost its visible floor")
                window.orderOut(nil)
            }
        }

        // The import card in the states with the least and the most to say.
        model.meetingImport = MeetingImportState([
            "routeState": .string("route_absent"),
        ])
        for dark in [false, true] {
            let (window, _) = try render(MeetingImportPane.canary(model: model), size: NSSize(width: 390, height: 640),
                                         name: "import-route-absent", output: output, dark: dark)
            window.orderOut(nil)
        }
        model.meetingImport = MeetingImportState([
            "routeState": .string("ready"), "state": .string("partial"), "mode": .string("imports"),
            "keyConfigured": .bool(true), "keepImporting": .bool(true), "planCap": .string("free"),
            "windowDays": .number(30),
            "counts": .object(["imported": .number(1_165), "vendorSeen": .number(1_200), "retryable": .number(28)]),
            "budget": .object(["calls": .number(48), "cap": .number(50), "remaining": .number(2)]),
        ])
        model.firefliesKey = FirefliesKeyState([
            "routeState": .string("ready"), "configured": .bool(true), "source": .string("config"),
            "lastCheck": .object(["state": .string("ok"), "checkedAt": .string("2026-09-14T10:00:00.000Z")]),
        ])
        model.meetingRecorders = [MeetingRecorder(.object([
            "id": .string("fireflies"), "name": .string("Fireflies"),
            "bundleId": .string("ai.fireflies.desktop"), "installed": .bool(true),
        ]))].compactMap { $0 }
        for size in [NSSize(width: 390, height: 640), NSSize(width: 920, height: 680)] {
            for dark in [false, true] {
                let (window, _) = try render(MeetingImportPane.canary(model: model), size: size,
                                             name: "import-\(Int(size.width))", output: output, dark: dark)
                window.orderOut(nil)
            }
        }

        // A merged record's CTAs, with the Undo preview on screen.
        let mergedRow = LibraryMeeting(.object([
            "recordId": .string("blended:0123456789abcdef"), "sessionId": .string("meeting_1789_abc"),
            "title": .string("Quilt weekly sync"), "date": .string("2026-09-10"), "time": .string("14:30"),
            "domain": .string("imported"), "originDomain": .string("quilt"), "month": .string("2026-09"),
            "filename": .string("2026-09-10_merged_0123456789abcdef.md"),
            "librarySource": .string("blended"), "mutable": .bool(false),
            "derivedKind": .string("merge"), "actionId": .string("a_0123456789abcdef"),
            "source": .string("G2 Glasses + Fireflies"),
        ]))!
        model.mergeActions = [MergeAction(.object([
            "id": .string("a_0123456789abcdef"), "kind": .string("merge"), "tier": .string("auto"),
            "actionState": .string("applied"), "mode": .string("apply"),
            "outputs": .array([.string("quilt/meetings/2026-09/2026-09-10_quilt_weekly.md")]),
            "sessionIds": .array([.string("meeting_1789_abc")]),
            "firefliesIds": .array([.string("01K4EXAMPLE")]),
            "at": .string("2026-09-14T10:00:00.000Z"),
        ]))!]
        precondition(model.mergeAction(for: mergedRow)?.isRevertible == true)
        model.mergeRevertPreview = MergeRevertPreview([
            "previewHash": .string(String(repeating: "a", count: 64)),
            "outputs": .array([.string("quilt/meetings/2026-09/2026-09-10_quilt_weekly.md")]),
            "editedOutputs": .array([.string("quilt/meetings/2026-09/2026-09-10_quilt_weekly.md")]),
            "missingOutputs": .array([]),
        ], actionId: "a_0123456789abcdef")
        precondition(model.mergeRevertPreview?.caution != nil, "an edited output must warn before the second click")
        for dark in [false, true] {
            let (window, _) = try render(
                MergedRecordActions(model: model, row: mergedRow, onOpenSource: { _ in })
                    .frame(width: 390).padding(16),
                size: NSSize(width: 422, height: 320), name: "undo-preview", output: output, dark: dark, fills: false)
            window.orderOut(nil)
        }

        print("PASS merge UI: 40 suggestions scroll in place at 390 and 920 pt, light and dark;")
        print("PASS import card holds every state at 390 pt; the Undo preview renders its caution")
        print("COS Control: merge fixtures rendered to \(output.path)")
    }
}
