import AppKit
import Foundation

/// 2026-10-09 (Miles, after the 0.5.276 gold banner): the header's refresh button also checks for updates and answers
/// in the subtitle line. This is the line's state machine, executed against Sources/Models.swift alone: its words, how
/// long each result holds, what a check outcome becomes, and Checking while any manual check runs. No helper, no
/// network, no window. Every failure names its behaviour as "check failed [<behaviour>]" (Tests/mutate-refresh-check.py).
@main @MainActor struct RefreshCheckChecks {
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
        let idle = "Your local glasses server"
        // The words.
        check(HeaderUpdateStatus.idle.text(idle: idle) == idle, "idle words", "idle keeps the line's own words")
        check(HeaderUpdateStatus.idle.text(idle: "Settings words") == "Settings words", "idle words", "idle is the caller's words")
        check(HeaderUpdateStatus.checking.text(idle: idle) == "Checking for updates…", "checking words", HeaderUpdateStatus.checking.text(idle: idle))
        check(HeaderUpdateStatus.upToDate.text(idle: idle) == "Up to date", "up to date words", HeaderUpdateStatus.upToDate.text(idle: idle))
        check(HeaderUpdateStatus.failed.text(idle: idle) == "Couldn't check for updates", "failed words", HeaderUpdateStatus.failed.text(idle: idle))
        // Copy rules: no em dash, no arrow, in any of them.
        for status in [HeaderUpdateStatus.idle, .checking, .upToDate, .failed] {
            let words = status.text(idle: idle)
            check(!words.contains("\u{2014}") && !words.contains("\u{2192}") && !words.contains("->"), "copy rules", words)
        }
        // How long each holds.
        check(HeaderUpdateStatus.upToDate.hold == .seconds(4), "up to date hold", "\(String(describing: HeaderUpdateStatus.upToDate.hold))")
        check(HeaderUpdateStatus.failed.hold == .seconds(6), "failed hold", "\(String(describing: HeaderUpdateStatus.failed.hold))")
        check(HeaderUpdateStatus.idle.hold == nil, "idle hold", "idle never resets")
        check(HeaderUpdateStatus.checking.hold == nil, "checking hold", "Checking stays until the check ends")
        // What an outcome becomes.
        check(HeaderUpdateStatus.after(.upToDate) == .upToDate, "outcome up to date", "no update gives Up to date")
        check(HeaderUpdateStatus.after(.failed) == .failed, "outcome failed", "a failure gives Couldn't check")
        check(HeaderUpdateStatus.after(.updateFound) == .idle, "outcome update found", "an update is the banner's, not the line's")
        check(HeaderUpdateStatus.after(.skipped) == .idle, "outcome skipped", "a check that never started says nothing")
        // Checking while any manual check runs; otherwise the last result.
        for status in [HeaderUpdateStatus.idle, .upToDate, .failed, .checking] {
            check(HeaderUpdateStatus.shown(inFlight: true, status: status) == .checking, "shown in flight", "\(status) while in flight")
            check(HeaderUpdateStatus.shown(inFlight: false, status: status) == status, "shown at rest", "\(status) at rest")
        }
        print("PASS: refresh-check subtitle, \(passed) checks (words, holds, outcomes, Checking while in flight)")
    }
}
