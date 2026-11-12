import AppKit
import Foundation

/// Anand parity (D4, 2026-11-12): the Mac's words for the items Control Web 7.0.30 settled (W1 in COORD 10:38): the Speakers
/// copy buttons. Compiled with Sources/Models.swift alone (Tests/run-anand-parity.sh).
@main struct AnandParityChecks {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0
    static func check(_ ok: Bool, _ label: String) {
        if ok { passes += 1 } else { failures += 1; print("check failed [\(label)]") }
    }

    static func main() {
        // Item 3: "Copy summary", "Copy full (N KB)", and Copied on the tapped one only.
        let W = MeetingCopyWords.self
        check(W.label(W.summary, copied: nil, fullChars: 52_000) == "Copy summary", "copy words")
        check(W.label(W.full, copied: nil, fullChars: 52_000) == "Copy full (50 KB)" && W.label(W.full, copied: nil, fullChars: 10) == "Copy full (1 KB)", "copy words")
        check(W.label(W.summary, copied: W.summary, fullChars: 52_000) == "Copied" && W.label(W.full, copied: W.summary, fullChars: 52_000) == "Copy full (50 KB)",
              "copied shows only on the tapped one")
        check(W.label(W.full, copied: W.full, fullChars: 52_000) == "Copied" && W.label(W.summary, copied: W.full, fullChars: 52_000) == "Copy summary",
              "copied shows only on the tapped one")
        check(W.copiedSeconds == 2.5, "copied for 2.5 s")
        let all = [W.copied, W.label(W.summary, copied: nil, fullChars: 0)]
        check(all.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("\u{2192}") && !$0.contains("Miles") }, "no dash, arrow or name")
        print("anand parity checks: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
