import Foundation

// Pure DTO/Today input checks, compiled with Sources/Models.swift. No helper requests, UI, stores or inference.
@main @MainActor struct TodaySummarySubagentChecks {
    static var ran = 0
    static let now = Date(timeIntervalSince1970: 1_794_146_400)

    static func check(_ condition: Bool, _ behavior: String, line: UInt = #line) {
        ran += 1
        if !condition { fatalError("check failed [\(behavior)] at line \(line)") }
    }

    static func counts(_ active: Double = 2, _ completed: Double = 3, _ total: Double = 5) -> JSONValue {
        .object(["active": .number(active), "completed": .number(completed), "total": .number(total)])
    }

    static func session(_ id: String, state: String = "running", provider: String = "claude", alive: Bool = true,
                        activity: JSONValue? = nil) -> ClaudeSession {
        var row: [String: JSONValue] = ["id": .string(id), "provider": .string(provider), "name": .string("Review " + id),
                                      "state": .string(state), "alive": .bool(alive), "namedTitle": .bool(true)]
        if let activity { row["subagentActivity"] = activity }
        return ClaudeSession(.object(row))!
    }

    static func inputRows(_ sessions: [ClaudeSession]) -> [JSONValue] {
        TodaySummary.inputs(sessions: sessions, needs: [], folded: 0, sessionsRead: true, settled: true,
                            failed: [], recording: false, now: now).object?["sessions"]?.array ?? []
    }

    static func main() throws {
        for provider in ["claude", "codex", "cursor"] {
            let row = session("counts-" + provider, provider: provider, activity: counts())
            check(row.subagentActivity?.active == 2 && row.subagentActivity?.completed == 3 && row.subagentActivity?.total == 5,
                  "valid optional counts decode for " + provider)
        }
        let wire = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"id":"server-wire","subagent_activity":{"active":1,"completed":4,"total":5}}"#.utf8))
        check(ClaudeSession(wire)?.subagentActivity?.completed == 4, "the server's snake-case DTO decodes too")
        check(session("older-server").subagentActivity == nil, "an older helper or server has unknown counts")
        check(SessionSubagentActivity(counts(0, 0, 0))?.total == 0, "an explicit measured zero stays valid")

        let malformed: [JSONValue] = [
            .null, .array([]), .string("2"), .object([:]),
            .object(["active": .number(1), "completed": .number(2)]),
            .object(["active": .bool(true), "completed": .number(2), "total": .number(3)]),
            .object(["active": .number(1), "completed": .string("2"), "total": .number(3)]),
            counts(-1, 2, 3), counts(1, 2.5, 3), counts(1, 2, -3),
            counts(Double.infinity, 0, 0), counts(0, Double.nan, 0), counts(0, 0, Double.greatestFiniteMagnitude),
        ]
        for (index, value) in malformed.enumerated() {
            let row = session("malformed-\(index)", activity: value)
            check(row.subagentActivity == nil, "malformed count reading \(index) stays unknown")
            check(inputRows([row]).first?.object?["agents"] == nil, "malformed count reading \(index) invents no fallback")
        }

        let sessions = [
            session("working-counts", activity: counts(2, 3, 5)),
            session("waiting-counts", state: "waiting", provider: "codex", activity: counts(0, 4, 4)),
            session("open-counts", state: "recent", provider: "cursor", activity: counts(1, 1, 2)),
            session("ended-counts", state: "stale", alive: false, activity: counts(9, 9, 18)),
        ]
        let rows = inputRows(sessions)
        check(rows.count == 3, "subagents are counts on the three eligible sessions, never top-level sessions")
        check(rows.compactMap { $0.object?["state"]?.string } == ["working", "waiting", "open"], "counts do not change session classification")
        for (index, expected) in [5, 4, 2].enumerated() {
            let agents = rows[index].object?["agents"]?.object
            check(agents?["total"]?.int == expected, "eligible session \(index) forwards its observed total")
            check(Set(agents?.keys.map { $0 } ?? []) == Set(["active", "completed", "total"]), "only web-compatible count fields are forwarded")
        }
        check(inputRows([session("no-reading")]).first?.object?["agents"] == nil, "absence emits no agents key, preserving old-client behavior")

        let many = (0..<9).map { session("fallback-\($0)", activity: counts(Double($0), 1, Double($0 + 1))) }
        let ninth = inputRows(many).last?.object?["agents"]?.object
        check(inputRows(many).count == 9 && ninth?["active"]?.int == 8 && ninth?["total"]?.int == 9,
              "the ninth session retains counts when server enrichment is limited to eight")

        let listed = session("matched-live", activity: counts(2, 3, 5))
        let noReading = session("matched-live")
        let fallback = TodayHome.liveSessions(list: [listed], live: [noReading])
        check(fallback.count == 1 && fallback.first?.subagentActivity?.total == 5, "a live row without counts keeps the catalog fallback without duplicating the session")
        let liveZero = session("matched-live", activity: counts(0, 0, 0))
        let zero = TodayHome.liveSessions(list: [listed], live: [liveZero])
        check(zero.first?.subagentActivity?.total == 0, "valid live zero outranks older catalog counts")
        let liveNew = session("matched-live", activity: counts(4, 3, 7))
        check(TodayHome.liveSessions(list: [listed], live: [liveNew]).first?.subagentActivity?.active == 4,
              "valid live counts outrank the catalog fallback")
        check(TodayHome.liveSessions(list: [listed], live: nil).first?.subagentActivity?.total == 5, "pet-off list counts survive")

        let initial = TodaySummary.inputs(sessions: [listed], needs: [], folded: 0, sessionsRead: true, settled: true, failed: [], recording: false, now: now)
        let changed = TodaySummary.inputs(sessions: [liveNew], needs: [], folded: 0, sessionsRead: true, settled: true, failed: [], recording: false, now: now)
        check(TodaySummary.key(initial) != TodaySummary.key(changed), "a changed subagent reading changes the summary refresh fingerprint")
        print("PASS: Today subagent fallback: \(ran) checks")
    }
}
