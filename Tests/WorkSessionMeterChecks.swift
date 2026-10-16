import Foundation

/// 0.5.312 Work → Connections meter: the pure parsers the helper and Control share (Sources/WorkSessionLinks.swift).
/// Run by Tests/run-work-roundtrip.sh with the repo root as the only argument (fixtures under Tests/fixtures).
@main struct WorkSessionMeterChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fixtures = root.appendingPathComponent("Tests/fixtures/work-session-meter")
        var count = 0
        func expect(_ value: Bool, _ name: String) { precondition(value, name); count += 1 }
        func lines(_ name: String) throws -> [String] {
            WorkSessionMeter.lines(try Data(contentsOf: fixtures.appendingPathComponent(name)), fromStart: true)
        }
        let since = WorkSessionMeter.date("2026-10-15T11:00:00.000Z")!

        // Claude: the newest main-thread assistant usage; sidechain and synthetic turns never count.
        let claude = try lines("claude.jsonl")
        let claudeContext = WorkSessionMeter.claudeContext(lines: claude)
        expect(claudeContext == WorkSessionMeter.Context(used: 121_003, window: 200_000, model: "claude-opus-5-5"), "Claude usage = input + cache read + cache creation of the last real turn")
        expect(claudeContext?.label == "61% · 121k / 200k" && claudeContext?.nearlyFull == false, "Claude label")
        expect(WorkSessionMeter.claudeContext(lines: Array(claude.prefix(1))) == nil, "no usage line: unknown, never 0%")
        let sidechain = claude.first { $0.contains("SIDECHAIN.md") }!
        let synthetic = #"{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":5000}}}"#
        let empty = #"{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":0,"output_tokens":3}}}"#
        expect(WorkSessionMeter.claudeContext(lines: claude + [sidechain, synthetic, empty]) == claudeContext,
               "a newer subagent, synthetic or empty-usage turn never replaces the session's own context")
        expect(WorkSessionMeter.workingFolder(provider: "claude", lines: claude) == "/Users/fixture/proj", "Claude cwd")
        let claudeOut = WorkSessionMeter.newestUnique(WorkSessionMeter.claudeOutputs(lines: claude, since: since)).map(\.path)
        expect(claudeOut == ["/Users/fixture/proj/PLAN.md", "/Users/fixture/proj/a.ipynb", "/Users/fixture/proj/SIDECHAIN.md", "/Users/fixture/proj/shot.png"],
               "Claude outputs: Write/Edit/NotebookEdit after the handoff, newest first; not Bash, not relative, not before the handoff")
        let doubled = WorkSessionMeter.claudeOutputs(lines: claude + claude, since: since)
        expect(WorkSessionMeter.newestUnique(doubled).count == 4 && doubled.count == 8, "outputs de-duplicate by path")

        // Codex: the newest token_count with info; its stated window wins.
        let codex = try lines("codex.jsonl")
        let codexContext = WorkSessionMeter.codexContext(lines: codex)
        expect(codexContext == WorkSessionMeter.Context(used: 233_000, window: 258_400, model: "gpt-5-codex"), "Codex last_token_usage against model_context_window")
        expect(codexContext?.nearlyFull == true && codexContext?.percent == 90, "90% is close to compacting")
        expect(WorkSessionMeter.workingFolder(provider: "codex", lines: codex) == "/Users/fixture/codexproj", "Codex cwd")
        let codexOut = WorkSessionMeter.newestUnique(WorkSessionMeter.codexOutputs(lines: codex, since: since, cwd: "/Users/fixture/codexproj")).map(\.path)
        expect(Set(codexOut.prefix(2)) == ["/Users/fixture/codexproj/results.csv", "/Users/fixture/codexproj/final.csv"]
               && codexOut.last == "/Users/fixture/codexproj/docs/BAKEOFF.md" && codexOut.count == 3,
               "Codex outputs: apply_patch Add/Update/Move (custom tool input and escaped shell arguments), relative to cwd, never Delete, not before the handoff")
        expect(WorkSessionMeter.patchPaths("*** Delete File: a\n*** Add File: b\n*** Update File:  \n") == ["b"], "patch headers")

        // The window table, in one place, and an estimate.
        expect(WorkSessionMeter.window(provider: "claude", model: "claude-opus-5-5[1m]", reported: nil, used: 10) == 1_000_000, "Claude [1m] marker")
        expect(WorkSessionMeter.window(provider: "claude", model: "claude-opus-5-5", reported: nil, used: 250_000) == 1_000_000, "usage past 200k proves a 1M window")
        expect(WorkSessionMeter.window(provider: "claude", model: "claude-sonnet-5-5", reported: nil, used: 150_000) == 200_000, "Claude default 200k")
        expect(WorkSessionMeter.window(provider: "codex", model: "gpt-5-codex", reported: nil, used: 1) == 272_000, "Codex gpt-5 without a stated window")
        expect(WorkSessionMeter.window(provider: "codex", model: "o3", reported: nil, used: 1) == nil, "unknown Codex model: hidden")
        expect(WorkSessionMeter.window(provider: "codex", model: "", reported: 400_000, used: 1) == 400_000, "a stated window wins")
        expect(WorkSessionMeter.window(provider: "cursor", model: "x", reported: nil, used: 1) == nil, "Cursor: unknown")
        let noWindow = codex.map { $0.replacingOccurrences(of: "\"model_context_window\": 258400", with: "\"x\": 0").replacingOccurrences(of: "gpt-5-codex", with: "o3") }
        expect(WorkSessionMeter.codexContext(lines: noWindow) == nil, "Codex with no stated window and an unknown model hides")

        // Labels and the 85% line.
        expect(WorkSessionMeter.Context(used: 124_000, window: 512_000, model: "").label == "24% · 124k / 512k", "the mock's label")
        expect(WorkSessionMeter.Context(used: 850, window: 1_000, model: "").nearlyFull && !WorkSessionMeter.Context(used: 849, window: 1_000, model: "").nearlyFull,
               "orange from exactly 85%")
        expect(WorkSessionMeter.compactingNote == "Close to compacting. A fresh session keeps this send intact.", "the mock's sentence")
        expect(WorkSessionMeter.tokens(1_000_000) == "1M" && WorkSessionMeter.tokens(1_250_000) == "1.3M" && WorkSessionMeter.tokens(640) == "640"
               && WorkSessionMeter.tokens(380_400) == "380k", "token labels")
        expect(WorkSessionMeter.Context(used: 2_000, window: 1_000, model: "").fraction == 1, "over-full clamps")

        // Tail reads drop the partial first line.
        let tail = Data("rtial\n{\"a\":1}\n{\"b\":2}\n".utf8)
        expect(WorkSessionMeter.lines(tail, fromStart: false) == ["{\"a\":1}", "{\"b\":2}"] && WorkSessionMeter.lines(tail, fromStart: true).count == 3, "partial first line")

        // git --shortstat and --numstat.
        expect(WorkSessionMeter.shortstat(" 9 files changed, 1284 insertions(+), 312 deletions(-)\n") == WorkSessionMeter.Changes(files: 9, insertions: 1284, deletions: 312), "shortstat")
        expect(WorkSessionMeter.shortstat(" 1 file changed, 1 insertion(+)") == WorkSessionMeter.Changes(files: 1, insertions: 1, deletions: 0), "insertions only")
        expect(WorkSessionMeter.shortstat(" 2 files changed, 7 deletions(-)") == WorkSessionMeter.Changes(files: 2, insertions: 0, deletions: 7), "deletions only")
        expect(WorkSessionMeter.shortstat("").isEmpty, "no output is no change")
        expect(WorkSessionMeter.shortstat("warning: in the working copy of 'a', CRLF will be replaced by LF the next time Git touches it\n 3 files changed, 4 insertions(+), 5 deletions(-)")
               == WorkSessionMeter.Changes(files: 3, insertions: 4, deletions: 5), "a stderr warning is ignored")
        expect(WorkSessionMeter.numstat("12\t3\tSources/a b.swift\n-\t-\timg.png\nwarning: x\n") == [
            WorkSessionMeter.FileChange(path: "Sources/a b.swift", insertions: 12, deletions: 3),
            WorkSessionMeter.FileChange(path: "img.png", insertions: nil, deletions: nil)], "numstat, binary files, noise ignored")
        expect(WorkSessionMeter.changesLine(WorkSessionMeter.Changes(files: 9, insertions: 1284, deletions: 312)) == "+1,284 −312 · 9 files · since this handoff", "the mock's changes line")
        expect(WorkSessionMeter.changesLine(nil) == "No code changes since its last handoff"
               && WorkSessionMeter.changesLine(WorkSessionMeter.Changes(files: 0, insertions: 0, deletions: 0)) == WorkSessionMeter.noChanges, "no changes")
        expect(WorkSessionMeter.isImage("/a/B.PNG") && !WorkSessionMeter.isImage("/a/plan.md"), "image vs doc icon")
        print("PASS work session meter: \(count) checks; Claude and Codex context, window table, 85% line, outputs, tail, shortstat, numstat")
    }
}
