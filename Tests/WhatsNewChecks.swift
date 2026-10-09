import AppKit
import Foundation

/// 2026-10-09 (Miles, 13:09, with screenshots of Vorssant): the What's New window's pure pieces, executed against
/// Sources/Models.swift alone. The appcast's whatsNew as the app reads it (valid, absent, wrong types, oversize, control
/// characters), the notes fallback, the release line, and the footer for every phase of the install (ready, staging,
/// applying, failed, Try again, Cancel, busy). No helper, no network, no window. Every failure names its behaviour as
/// "check failed [<behaviour>]", which Tests/mutate-whats-new.py matches a killing failure against.
@main @MainActor struct WhatsNewChecks {
    static var passed = 0

    static func check(_ condition: Bool, _ behaviour: String, _ detail: String = "") {
        guard condition else {
            print("check failed [\(behaviour)]: \(detail)")
            exit(1)
        }
        passed += 1
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        parsing()
        limits()
        cleaning()
        content()
        footer()
        print("WhatsNew checks: \(passed) passed (whatsNew parsing, limits, cleaning, notes fallback, footer phases)")
    }

    static func s(_ text: String) -> JSONValue { .string(text) }
    static func section(_ title: JSONValue, _ items: [JSONValue]) -> JSONValue { .object(["title": title, "items": .array(items)]) }

    // MARK: parsing

    static func parsing() {
        let valid: JSONValue = .object([
            "summary": s("Update shows a What's New window."),
            "sections": .array([section(s("Added"), [s("One"), s("Two")]), section(s("Fixed"), [s("Three")])]),
        ])
        guard let parsed = AppUpdateWhatsNew(valid) else { return check(false, "whatsNew valid", "a valid object must parse") }
        check(parsed.summary == "Update shows a What's New window.", "whatsNew valid", "summary: \(parsed.summary ?? "nil")")
        check(parsed.sections == [.init(title: "Added", items: ["One", "Two"]), .init(title: "Fixed", items: ["Three"])],
              "whatsNew valid", "sections in order: \(parsed.sections)")

        check(AppUpdateWhatsNew(nil) == nil, "whatsNew absent", "no key, no whatsNew")
        check(AppUpdateWhatsNew(.null) == nil, "whatsNew absent", "null is absent")
        for wrong: JSONValue in [s("text"), .number(3), .bool(true), .array([valid])] {
            check(AppUpdateWhatsNew(wrong) == nil, "whatsNew wrong types", "\(wrong) is not an object")
        }
        check(AppUpdateWhatsNew(.object([:])) == nil, "whatsNew wrong types", "an empty object has nothing to show")
        check(AppUpdateWhatsNew(.object(["summary": .number(1), "sections": s("Added")])) == nil, "whatsNew wrong types",
              "a number summary and a string for sections leave nothing")
        // Wrong types drop one by one: a bad item drops that item, a bad section drops that section.
        let mixed = AppUpdateWhatsNew(.object([
            "summary": .array([s("x")]),
            "sections": .array([
                s("not a section"),
                .object(["title": .number(4), "items": .array([s("no title")])]),
                .object(["items": .array([s("missing title")])]),
                section(s("Kept"), [.number(1), s("kept item"), .null, .object([:]), s("   ")]),
                section(s("Empty"), [.bool(false)]),
                .object(["title": s("Items not an array"), "items": s("one")]),
            ]),
        ]))
        check(mixed?.summary == nil, "whatsNew wrong types", "a summary that is not a string is dropped")
        check(mixed?.sections == [.init(title: "Kept", items: ["kept item"])], "whatsNew wrong types",
              "only the section with a title and a real item survives: \(String(describing: mixed?.sections))")
        let summaryOnly = AppUpdateWhatsNew(.object(["summary": s("Just words.")]))
        check(summaryOnly?.summary == "Just words." && summaryOnly?.sections == [], "whatsNew valid", "a summary alone is enough")
        let sectionsOnly = AppUpdateWhatsNew(.object(["sections": .array([section(s("Added"), [s("One")])])]))
        check(sectionsOnly?.summary == nil && sectionsOnly?.sections.count == 1, "whatsNew valid", "sections alone are enough")

        // Through AppUpdateInfo, the way the helper's details arrive.
        let info = AppUpdateInfo(["updateAvailable": .bool(true), "latestVersion": s("0.5.275"), "latestBuild": .number(328),
                                  "notes": s("Old notes."), "whatsNew": valid, "reason": s("newer")])
        check(info.whatsNew == parsed, "whatsNew valid", "AppUpdateInfo reads details.whatsNew")
        let old = AppUpdateInfo(["updateAvailable": .bool(true), "latestVersion": s("0.5.275"), "notes": s("Old notes.")])
        check(old.whatsNew == nil, "whatsNew absent", "an appcast without whatsNew leaves it nil")
    }

    // MARK: limits

    static func limits() {
        let long = String(repeating: "a", count: 5000)
        let parsed = AppUpdateWhatsNew(.object([
            "summary": s(long),
            "sections": .array((0..<20).map { index in
                section(s("Section \(index) " + String(repeating: "t", count: 200)), (0..<30).map { s("item \($0) " + long) })
            }),
        ]))
        guard let parsed, let summary = parsed.summary else { return check(false, "whatsNew oversize", "oversize content must still parse") }
        check(summary.count == 1200 && summary.hasSuffix("…"), "whatsNew oversize",
              "summary cut to \(AppUpdateWhatsNew.summaryLimit) with an ellipsis, got \(summary.count)")
        check(parsed.sections.count == 8, "whatsNew oversize", "at most 8 sections, got \(parsed.sections.count)")
        check(parsed.sections.allSatisfy { $0.items.count == 12 }, "whatsNew oversize", "at most 12 items each")
        check(parsed.sections.allSatisfy { $0.items.allSatisfy { $0.count == 400 } }, "whatsNew oversize",
              "an item at most 400 characters")
        check(parsed.sections.allSatisfy { $0.title.count == AppUpdateWhatsNew.titleLength }, "whatsNew oversize", "a title at most 80 characters")
        check(parsed.sections.first?.title.hasPrefix("Section 0 ") == true && parsed.sections.last?.title.hasPrefix("Section 7 ") == true,
              "whatsNew oversize", "the FIRST eight sections are kept, in order")
        check(parsed.sections[0].items[11].hasPrefix("item 11 "), "whatsNew oversize", "the first twelve items, in order")
        check(AppUpdateWhatsNew.summaryLimit == 1200 && AppUpdateWhatsNew.sectionLimit == 8 && AppUpdateWhatsNew.itemLimit == 12
              && AppUpdateWhatsNew.itemLength == 400, "whatsNew oversize", "the limits are the contract's")
        // Exactly at the limit: not cut.
        let exact = String(repeating: "b", count: 400)
        check(AppUpdateWhatsNew.clean(exact, limit: 400, keepNewlines: false) == exact, "whatsNew oversize", "400 characters stay whole")
        // Counted in characters, not bytes: 400 accented letters are whole.
        let accented = String(repeating: "é", count: 400)
        check(AppUpdateWhatsNew.clean(accented, limit: 400, keepNewlines: false) == accented, "whatsNew oversize", "characters, not UTF-8 bytes")
    }

    // MARK: cleaning

    static func cleaning() {
        func clean(_ text: String, newlines: Bool = false) -> String? { AppUpdateWhatsNew.clean(text, limit: 400, keepNewlines: newlines) }
        check(clean("bell\u{07}and\u{00}nul") == "bell and nul", "whatsNew control chars", "C0 controls become spaces: \(clean("bell\u{07}and\u{00}nul") ?? "nil")")
        check(clean("esc\u{1B}[31mred") == "esc [31mred", "whatsNew control chars", "ESC cannot start a terminal sequence")
        check(clean("next\u{85}line\u{9B}c1") == "next line c1", "whatsNew control chars", "C1 controls too")
        check(clean("tab\there") == "tab here", "whatsNew control chars", "a tab is a space")
        check(clean("abc\u{202E}gnp.exe") == "abcgnp.exe", "whatsNew bidi", "a right-to-left override is removed")
        check(clean("\u{2066}iso\u{2069} \u{200F}mark") == "iso mark", "whatsNew bidi", "isolates and marks are removed")
        check(clean("one\ntwo\r\nthree") == "one two three", "whatsNew control chars", "no line breaks in an item or a title")
        check(clean("one\ntwo\r\nthree", newlines: true) == "one\ntwo\nthree", "whatsNew summary newlines", "the summary keeps its line breaks")
        check(clean("a\n\n\n\nb", newlines: true) == "a\n\nb", "whatsNew summary newlines", "at most one blank line")
        check(clean("\n\n  lead and trail  \n\n", newlines: true) == "lead and trail", "whatsNew summary newlines", "trimmed")
        check(clean("a   b  \u{0B} c") == "a b c", "whatsNew control chars", "runs of spaces close up")
        check(clean(" \u{07}\u{202E} ") == nil, "whatsNew control chars", "nothing left is nil")
        check(clean("Café, naïve, 日本語, emoji 👋🏽") == "Café, naïve, 日本語, emoji 👋🏽", "whatsNew control chars", "ordinary text is untouched")
        let parsed = AppUpdateWhatsNew(.object(["summary": s("\u{07}\u{202E}"), "sections": .array([section(s("Ti\u{0}tle"), [s("x\u{1B}y")])])]))
        check(parsed?.summary == nil && parsed?.sections == [.init(title: "Ti tle", items: ["x y"])], "whatsNew control chars",
              "applied to every field: \(String(describing: parsed))")
    }

    // MARK: content

    static func content() {
        func info(_ extra: [String: JSONValue]) -> AppUpdateInfo {
            var details: [String: JSONValue] = ["updateAvailable": .bool(true), "latestVersion": s("0.5.275"), "latestBuild": .number(328)]
            details.merge(extra) { $1 }
            return AppUpdateInfo(details)
        }
        let full = WhatsNewContent(info(["notes": s("Old notes."), "whatsNew": .object([
            "summary": s("New summary."), "sections": .array([section(s("Added"), [s("One")])])])]))
        check(full.summary == "New summary." && full.sections.count == 1, "content whatsNew", "whatsNew wins over notes")
        let fallback = WhatsNewContent(info(["notes": s("Old notes, the only words.")]))
        check(fallback.summary == "Old notes, the only words." && fallback.sections.isEmpty, "content notes fallback",
              "no whatsNew: notes is the summary, no sections")
        let broken = WhatsNewContent(info(["notes": s("Old notes."), "whatsNew": s("not an object")]))
        check(broken.summary == "Old notes." && broken.sections.isEmpty, "content notes fallback", "an unusable whatsNew falls back to notes")
        let sectionsOnly = WhatsNewContent(info(["notes": s("Old notes."), "whatsNew": .object(["sections": .array([section(s("Added"), [s("One")])])])]))
        check(sectionsOnly.summary == "Old notes." && sectionsOnly.sections.count == 1, "content notes fallback",
              "sections without a summary borrow notes as the summary")
        let nothing = WhatsNewContent(info([:]))
        check(nothing.summary == nil && nothing.summaryText == "No release notes were published with this update.", "content empty",
              "no words at all still says something")
        let dirtyNotes = WhatsNewContent(info(["notes": s("notes\u{07}with\u{202E}junk")]))
        check(dirtyNotes.summary == "notes withjunk", "content notes fallback", "notes are cleaned like a summary")

        var flow = AppUpdateFlow()
        flow.offer(info([:]), currentVersion: "0.5.274", currentBuild: 327)
        check(flow.releaseLine == "0.5.275 (build 328)", "release line", "the accent line: \(flow.releaseLine)")
        var noBuild = AppUpdateFlow()
        noBuild.offer(AppUpdateInfo(["updateAvailable": .bool(true), "latestVersion": s("0.5.275")]), currentVersion: "0.5.274", currentBuild: 327)
        check(noBuild.releaseLine == "0.5.275", "release line", "no build named: the version alone")
        check(AppUpdateFlow().releaseLine.isEmpty, "release line", "no offer: no line")
    }

    // MARK: footer

    static func footer() {
        let info = AppUpdateInfo(["updateAvailable": .bool(true), "latestVersion": s("0.5.275"), "latestBuild": .number(328)])
        var flow = AppUpdateFlow()
        flow.offer(info, currentVersion: "0.5.274", currentBuild: 327)

        let ready = WhatsNewFooter(flow.phase, busy: false)
        check(ready.primary == .install && ready.primaryTitle == "Download and install" && ready.primaryEnabled, "footer ready",
              "Download and install, enabled")
        check(ready.cancelTitle == "Cancel" && ready.cancelEnabled && ready.status == nil && !ready.working && !ready.failed,
              "footer ready", "Cancel, no status")
        let readyBusy = WhatsNewFooter(flow.phase, busy: true)
        check(readyBusy.primary == .install && !readyBusy.primaryEnabled && readyBusy.cancelEnabled, "footer busy",
              "busy with something else: install waits, Cancel still closes")
        check(readyBusy.status?.contains("finishing another task") == true, "footer busy", "and says why")

        check(flow.beginInstall(), "footer staging", "Download and install starts staging")
        let downloading = WhatsNewFooter(flow.phase, busy: true)
        check(downloading.status == "Downloading…" && downloading.working, "footer staging", "no line yet: Downloading…")
        check(!downloading.primaryEnabled && !downloading.cancelEnabled, "footer staging", "both buttons disabled while staging")
        flow.progress("Downloading COS Control update…")
        check(WhatsNewFooter(flow.phase, busy: true).status == "Downloading…", "footer staging", "the download line")
        flow.progress("Checking SHA-256…")
        check(WhatsNewFooter(flow.phase, busy: true).status == "Checking…", "footer staging", "the SHA-256 line")
        flow.progress("Unpacking update…")
        check(WhatsNewFooter(flow.phase, busy: true).status == "Unpacking…", "footer staging", "the unpack line")
        flow.progress("Something new from a later helper")
        check(WhatsNewFooter(flow.phase, busy: true).status == "Something new from a later helper", "footer staging",
              "an unknown line as itself")

        flow.staged()
        let applying = WhatsNewFooter(flow.phase, busy: true)
        check(applying.status == "Installing, COS Control will reopen" && applying.working, "footer applying", "installing words")
        check(!applying.primaryEnabled && !applying.cancelEnabled, "footer applying", "both buttons disabled while applying")

        flow.fail("Finish this first, then install: an active meeting. The glasses server was not touched.")
        let failed = WhatsNewFooter(flow.phase, busy: false)
        check(failed.primary == .tryAgain && failed.primaryTitle == "Try again" && failed.primaryEnabled, "footer failed", "Try again")
        check(failed.failed && !failed.working && failed.status?.hasPrefix("Finish this first") == true, "footer failed",
              "the helper's own words")
        check(failed.cancelEnabled && failed.cancelTitle == "Cancel", "footer failed", "Cancel closes after a failure")
        check(!WhatsNewFooter(flow.phase, busy: true).primaryEnabled, "footer busy", "Try again waits while busy too")
        check(flow.beginInstall() && WhatsNewFooter(flow.phase, busy: true).working, "footer retry", "Try again stages again")

        let none = WhatsNewFooter(.none, busy: false)
        check(none.primary == .hidden && none.primaryTitle == nil && none.cancelTitle == "Close" && none.cancelEnabled,
              "footer none", "no offer: only Close")
        check(none.status == "COS Control is up to date.", "footer none", "and says so")

        check(WhatsNewFooter.reassurance == "COS Control quits and reopens by itself. The glasses server keeps running.",
              "footer copy", "the line under the buttons")
        check(WhatsNewFooter.closeNote.contains("does not stop the install"), "footer copy", "closing during an install is said to be safe")
        // House rules for words this window shows: no em dashes, no arrows.
        let copy = [WhatsNewFooter.reassurance, WhatsNewFooter.closeNote, WhatsNewFooter.installTitle, WhatsNewFooter.retryTitle,
                    ready.cancelTitle, none.cancelTitle, none.status ?? "", readyBusy.status ?? "", applying.status ?? "",
                    WhatsNewContent(AppUpdateInfo()).summaryText]
        for line in copy {
            check(!line.contains("\u{2014}") && !line.contains("\u{2192}") && !line.contains("->"), "footer copy", "no em dash or arrow: \(line)")
        }
    }
}
