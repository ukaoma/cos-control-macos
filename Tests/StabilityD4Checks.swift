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

    /// 0.5.387 (D4) item 5: a Claude question at the session's own prompt names the app to answer it in.
    static func waiting(_ native: String, provider: String = "claude", kind: String = "question", state: String = "waiting",
                        question: String = "Ship the footer now, or wait for review?", job: String? = nil) -> ClaudeSession {
        var o: [String: JSONValue] = ["id": .string(native), "provider": .string(provider), "name": .string("Footer"), "state": .string(state),
                                      "alive": .bool(true), "waitingKind": .string(kind), "waitingQuestion": .string(question),
                                      "workspace": .string("cos"), "updatedAt": .string("2026-11-09T14:10:00Z"), "createdAt": .string("2026-11-09T14:00:00Z")]
        if let job { o["origin"] = .string("job"); o["jobLabel"] = .string(job) }
        return ClaudeSession(.object(o))!
    }

    static func checkAnswerAtPrompt() {
        let desktop = TodayHome.Host(app: "Claude", terminal: false)
        let terminal = TodayHome.Host(app: "iTerm2", terminal: true)
        let q = waiting("q1")
        precondition(TodayHome.answerAtPrompt(q, host: desktop) == "Answer in Claude", "a Claude desktop question answers in Claude")
        precondition(TodayHome.answerAtPrompt(q, host: terminal) == "Answer in iTerm2", "a terminal question names its terminal app")
        precondition(TodayHome.answerAtPrompt(q, host: nil) == "Answer at its prompt", "no host read: no app is guessed")
        for kind in ["plan", "permission", "mcp_input"] {
            precondition(TodayHome.answerAtPrompt(waiting("k-" + kind, kind: kind), host: desktop) == nil, "a \(kind) keeps today's Open")
        }
        precondition(TodayHome.answerAtPrompt(waiting("c1", provider: "cursor"), host: nil) == nil, "Cursor keeps its own Open")
        precondition(TodayHome.answerAtPrompt(waiting("r1", state: "running"), host: desktop) == nil, "a running session has no question")
        precondition(TodayHome.answerAtPrompt(waiting("j1", job: "Meeting watcher"), host: desktop) == nil,
            "a run only the COS server writes has no desk prompt")
        precondition(TodayHome.promptPendingLine == "This session is waiting on a question at its own prompt. Answer it there.",
            "the detail line's copy")

        var input = TodayHome.NeedInputs()
        input.waiting = [q, waiting("p1", kind: "plan")]
        input.hosts = ["claude:q1": desktop, "claude:p1": desktop]
        let rows = TodayHome.things(input).filter { $0.kind == .session }
        let question = rows.first { $0.id == "session:claude:q1" }, plan = rows.first { $0.id == "session:claude:p1" }
        precondition(question?.openLabel == "Answer in Claude" && question?.answersAtPrompt == true,
            "the Needs you row for a question says Answer in Claude, with Open session second")
        precondition(plan?.openLabel == "Open session" && plan?.answersAtPrompt == false, "a plan row is unchanged")
    }

    /// 0.5.387 (D4) item 6: no server has the work-loop routes, so nothing in Work promises a newer one.
    static func checkWorkLoopCopy() {
        precondition(WorkLoopSupport.undoMissing == "Undo is not available. To change a card, open it in Work.", "the Undo line's copy")
        precondition(WorkLoopSupport.cardActionsLine(batchAvailable: false) == "Keep, Drop and Delegate are not available here. To change a card, open it in Work.",
            "no card batch on the server: one line stands in for Keep, Drop and Delegate")
        precondition(WorkLoopSupport.cardActionsLine(batchAvailable: true) == nil, "a server with the card batch keeps the controls")
        precondition(WorkLoopSupport.listMissing(dropped: false) == "Waiting on is not available."
            && WorkLoopSupport.listMissing(dropped: true) == "Dropped cards are not available.", "the list lines' copy")
        let lines = [WorkLoopSupport.undoMissing, WorkLoopSupport.cardActionsMissing, WorkLoopSupport.listMissing(dropped: false), WorkLoopSupport.listMissing(dropped: true)]
        precondition(lines.allSatisfy { !$0.localizedCaseInsensitiveContains("newer") && !$0.contains("\u{2014}") && !$0.contains("\u{2192}") },
            "no Work loop line promises a newer server, and none has an em dash or an arrow")
    }

    static func main() {
        checkPetDuplicates()
        checkCalendarDuplicates()
        checkAnswerAtPrompt()
        checkWorkLoopCopy()
        print("StabilityD4Checks: pet duplicate ids, calendar duplicate dates, Answer at the prompt and Work loop copy PASS")
    }
}
