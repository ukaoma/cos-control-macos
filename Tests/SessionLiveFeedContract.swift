import Foundation

// The live feed reducer against recorded frames (0.5.233). `Tests/fixtures/
// session-stream-6.48.2.ndjson` is a `session-stream` capture from the release Mac
// (server 6.48.2, seed=turn, paths and prompt redacted): an opening status with the
// derived state, the prompt, sixteen tool lines. Executed here, then the rules a
// recording cannot show: a seq gap counts as missed, a reseed clears, a new prompt
// starts a new tool window, the status fields ride through, elapsed reads off
// state_since, and the SSE frame parser survives torn chunks.

@main
struct SessionLiveFeedContract {
    nonisolated(unsafe) static var failures: [String] = []
    static func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

    static func main() {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        recorded(root)
        rules()
        if failures.isEmpty {
            print("COS Control: live session feed pinned on recorded 6.48.2 frames, reseed, gap, prompt window, state line (0.5.233)")
        } else {
            for f in failures { FileHandle.standardError.write(("SessionLiveFeedContract: " + f + "\n").data(using: .utf8)!) }
            exit(1)
        }
    }

    static func recorded(_ root: URL) {
        let path = root.appendingPathComponent("Tests/fixtures/session-stream-6.48.2.ndjson")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return expect(false, "fixture missing at \(path.path)") }
        var feed = SessionLiveFeed()
        var count = 0
        for line in text.split(separator: "\n") {
            guard let event = SessionLiveEvent(line: String(line)) else { return expect(false, "a recorded line did not parse: \(line.prefix(80))") }
            feed = feed.applying(event)
            count += 1
        }
        expect(count == 18, "18 recorded frames, got \(count)")
        expect(feed.lastSeq == 18, "lastSeq follows the frames: \(feed.lastSeq)")
        expect(feed.missed == 0, "a contiguous recording misses nothing: \(feed.missed)")
        expect(feed.state == "working" && feed.agentState == "running" && feed.stateSource == "hook", "the opening status carries the derived state: \(feed.state) \(String(describing: feed.agentState)) \(String(describing: feed.stateSource))")
        expect(feed.stateSince != nil, "state_since parses")
        expect(feed.stateWord == "Working" && feed.stateDetail.isEmpty, "Working with no detail while running")
        expect(feed.prompt == "Confirm the fix was server-side, then update the docs.", "the prompt line is the turn's prompt: \(feed.prompt)")
        expect(feed.tools.count == SessionLiveFeed.toolWindow, "the tool window holds the last \(SessionLiveFeed.toolWindow): \(feed.tools.count)")
        // Two prose frames (7 and 17) sit among the sixteen tools, so the newest eight
        // tool lines are seqs 10 to 18 without 17.
        expect(feed.tools.map(\.seq) == [10, 11, 12, 13, 14, 15, 16, 18], "the window keeps the NEWEST eight tools, prose skipped: \(feed.tools.map(\.seq))")
        expect(feed.tools.allSatisfy { $0.line.hasPrefix("Ran ") }, "bash tools read as Ran …")
        let later = feed.stateSince!.addingTimeInterval(4 * 60 + 12)
        expect(feed.elapsed(now: later) == "4m 12s", "elapsed reads off state_since: \(feed.elapsed(now: later))")
    }

    static func rules() {
        func ev(_ seq: Int, _ kind: String, _ extra: String = "") -> SessionLiveEvent {
            SessionLiveEvent(line: "{\"seq\":\(seq),\"kind\":\"\(kind)\",\"at\":1789560000000\(extra.isEmpty ? "" : "," + extra)}")!
        }
        var feed = SessionLiveFeed()
        feed = feed.applying(ev(1, "status", "\"state\":\"working\""))
        feed = feed.applying(ev(2, "prompt", "\"text\":\"first\""))
        feed = feed.applying(ev(3, "tool", "\"verb\":\"read\",\"target\":\"a.ts\",\"id\":\"1700.3\""))
        feed = feed.applying(ev(6, "tool", "\"verb\":\"edit\",\"target\":\"b.ts\",\"id\":\"1700.6\""))
        expect(feed.missed == 2, "a seq gap of two is two missed: \(feed.missed)")
        expect(feed.lastID == "1700.6", "the last id is what a reconnect resumes from: \(String(describing: feed.lastID))")
        expect(feed.tools.map(\.line) == ["Read a.ts", "Edited b.ts"], "verbs read as words: \(feed.tools.map(\.line))")
        feed = feed.applying(ev(7, "prompt", "\"text\":\"second\""))
        expect(feed.tools.isEmpty && feed.prompt == "second", "a new prompt starts a new tool window")
        feed = feed.applying(ev(8, "status", "\"state\":\"working\",\"agent_state\":\"waiting\",\"state_source\":\"hook\",\"waiting_kind\":\"permission\",\"waiting_detail\":\"Bash git push\",\"state_since\":\"2026-09-16T12:00:00.000Z\""))
        expect(feed.stateWord == "Waiting" && feed.stateDetail == "Permission: Bash git push", "a permission wait names the command: \(feed.stateWord) / \(feed.stateDetail)")
        feed = feed.applying(ev(9, "status", "\"state\":\"idle\",\"agent_state\":\"failed\",\"state_source\":\"hook\",\"failure\":\"rate_limit\""))
        expect(feed.stateWord == "Failed" && feed.stateDetail == "rate limit", "a failure reads as words: \(feed.stateDetail)")
        feed = feed.applying(ev(10, "status", "\"state\":\"idle\",\"agent_state\":\"idle\",\"state_source\":\"hook\",\"last_reply\":\"done\""))
        expect(feed.stateWord == "Idle" && feed.stateDetail == "last reply: done", "idle carries the last reply")
        // A reseed: seq restarts at 1 after a live run, and the previous connection's lines go.
        feed.connected = true
        feed = feed.applying(ev(1, "status", "\"state\":\"working\""))
        expect(feed.tools.isEmpty && feed.prompt.isEmpty && feed.missed == 0 && feed.lastSeq == 1 && feed.connected, "a reseed clears the feed and keeps the connection flag")
        expect(feed.applying(ev(2, "heartbeat")).lastSeq == 2, "a heartbeat advances seq and draws nothing")
        expect(SessionLiveEvent(line: "not json") == nil && SessionLiveEvent(line: "{\"kind\":\"tool\"}") == nil, "a line without seq or kind is not an event")
        // The state word without the derived fields follows the transport state.
        var bare = SessionLiveFeed()
        bare = bare.applying(ev(1, "status", "\"state\":\"done\""))
        expect(bare.stateWord == "Done", "done without agent_state reads Done: \(bare.stateWord)")
    }
}
