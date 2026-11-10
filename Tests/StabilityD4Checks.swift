import AppKit
import Foundation

/// 0.5.387 (D4): duplicate ids from the helper or the server never trap.
/// Control 0.5.383 crashed twice on 2026-11-09 08:18 in Dictionary(uniqueKeysWithValues:) inside
/// PetCompletionDetector.diff when the session list carried two rows with one id.
/// Compiled with Sources/Models.swift only (Tests/run-stability-d4.sh).
@main
struct StabilityD4Checks {
    static func session(_ native: String, _ state: String, name: String = "Lane") -> ClaudeSession {
        ClaudeSession(.object([
            "id": .string(native), "name": .string(name), "workspace": .string("cos"),
            "state": .string(state), "alive": .bool(state == "running"),
            "createdAt": .string("2026-11-09T14:00:00Z"), "updatedAt": .string("2026-11-09T14:10:00Z"),
        ]))!
    }

    static func checkPetDuplicates() {
        let now = ISO8601DateFormatter().date(from: "2026-11-09T14:18:25Z")!
        let running = session("9644b527", "running")
        let idle = session("9644b527", "idle")
        let waiting = session("9644b527", "waiting")
        precondition(running.id == idle.id && idle.id == waiting.id, "fixture: the three rows share one id")

        // The crash shape: the current list carries the same id twice. Any order, any mix, no trap.
        _ = PetCompletionDetector.diff(previous: [running], current: [running, running], suppressedIDs: [], now: now)

        // A copy still running means the session has not finished, whichever copy comes first.
        precondition(PetCompletionDetector.diff(previous: [running], current: [idle, running], suppressedIDs: [], now: now).isEmpty,
            "an idle copy listed first does not hide a copy that still runs")
        precondition(PetCompletionDetector.diff(previous: [running], current: [running, idle], suppressedIDs: [], now: now).isEmpty,
            "an idle copy listed second does not hide a copy that still runs")
        // A waiting copy is a handoff to Miles, never a finish.
        precondition(PetCompletionDetector.diff(previous: [running], current: [idle, waiting], suppressedIDs: [], now: now).isEmpty,
            "a waiting copy wins over an idle copy")
        // Every copy idle: the session finished, and emits exactly once.
        let done = PetCompletionDetector.diff(previous: [running], current: [idle, idle], suppressedIDs: [], now: now)
        precondition(done.count == 1 && done[0].id == running.id, "two idle copies emit one finish")

        // A repeated prior emits once, not once per copy.
        let twice = PetCompletionDetector.diff(previous: [running, running], current: [idle], suppressedIDs: [], now: now)
        precondition(twice.count == 1, "a prior listed twice emits one finish, got \(twice.count)")
        let gone = PetCompletionDetector.diff(previous: [running, running], current: [], suppressedIDs: [], now: now)
        precondition(gone.count == 1, "a prior listed twice that left the list emits one finish, got \(gone.count)")

        // Unchanged behaviour for unique ids.
        let other = session("5200eb02", "running", name: "Other")
        let mixed = PetCompletionDetector.diff(previous: [running, other], current: [idle, session("5200eb02", "running")], suppressedIDs: [], now: now)
        precondition(mixed.map(\.id) == [running.id], "unique ids behave as before")
        precondition(PetCompletionDetector.diff(previous: [running], current: [idle, idle], suppressedIDs: [running.id], now: now).isEmpty,
            "a suppressed id still emits nothing")
    }

    static func checkCalendarDuplicates() {
        let days = [
            LibraryMeetingDay(date: "2026-11-09", count: 2),
            LibraryMeetingDay(date: "2026-11-08", count: 1),
            LibraryMeetingDay(date: "2026-11-09", count: 5),
            LibraryMeetingDay(date: "2026-11-09", count: 3),
        ]
        let counts = LibraryMeetingDay.countsByDate(days)
        precondition(counts == ["2026-11-09": 5, "2026-11-08": 1], "a repeated date keeps its largest count, got \(counts)")
        precondition(LibraryMeetingDay.countsByDate([]) == [:], "no days, no counts")
    }

    static func main() {
        checkPetDuplicates()
        checkCalendarDuplicates()
        print("StabilityD4Checks: pet duplicate ids and calendar duplicate dates PASS")
    }
}
