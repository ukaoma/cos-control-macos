import Foundation

/// Lane D1 (0.5.387): DictationShortcutGap, lifted from Sources/MacDictation.swift by Tests/run-dictation-shortcut-gap.sh
/// and compiled alone. Dictation on with no way to start it must say so; anything else must not.
@main struct DictationShortcutGapChecks {
    nonisolated(unsafe) static var passed = 0
    static func check(_ condition: Bool, _ what: String) {
        guard condition else { print("dictation shortcut gap check FAILED: \(what)"); exit(1) }
        passed += 1
    }
    static func main() {
        let gap = DictationShortcutGap.needsShortcut
        check(gap(true, false, false), "on with neither shortcut: warn")
        check(!gap(true, true, false), "on with Push to talk: no warning")
        check(!gap(true, false, true), "on with Start and stop: no warning")
        check(!gap(true, true, true), "on with both: no warning")
        check(!gap(false, false, false), "off: no warning, even with no shortcut")
        check(!gap(false, true, true), "off with shortcuts: no warning")
        check(DictationShortcutGap.warning == "Dictation is on but has no shortcut yet. Record one to start.", "the words")
        for banned in ["\u{2014}", "\u{2013}", "\u{2192}", "->"] {
            check(!DictationShortcutGap.warning.contains(banned), "no dash or arrow: \(banned)")
        }
        print("dictation shortcut gap checks: \(passed) passed")
    }
}
