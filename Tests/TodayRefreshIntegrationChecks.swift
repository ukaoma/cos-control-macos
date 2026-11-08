import AppKit
import Foundation

/// Calls the real ControllerModel and HelperClient with a private executable fixture.
/// No view/window, live server, credentials, provider, or Accessibility request is involved.
@main @MainActor struct TodayRefreshIntegrationChecks {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ behavior: String) {
        checks += 1
        guard condition() else {
            print("FAIL: Today refresh integration [\(behavior)]")
            exit(1)
        }
    }

    /// The lock protects only invocation numbering, never the wait. If production starts a
    /// second read too early, it really reaches this process and the test can observe it.
    static let fixtureScript = #"""
    #!/usr/bin/python3
    import fcntl,json,pathlib,sys,time
    root=pathlib.Path(__file__).parent
    def log(value):
      with (root/'events.jsonl').open('a') as stream:
        fcntl.flock(stream,fcntl.LOCK_EX)
        stream.write(json.dumps(value)+'\n');stream.flush()
    verb=sys.argv[1] if len(sys.argv)>1 else ''
    if verb!='session-pet-live':
      log({'event':'unexpected','verb':verb})
      print(json.dumps({'ok':False,'message':'Fixture refuses this command','details':{}}))
      sys.exit(1)
    with (root/'counter.lock').open('a') as lock:
      fcntl.flock(lock,fcntl.LOCK_EX)
      count=root/'count'
      number=int(count.read_text())+1 if count.exists() else 1
      count.write_text(str(number))
      plan=json.loads((root/'plan.json').read_text())
      step=plan['steps'][number-1] if number<=len(plan['steps']) else None
    log({'event':'start','number':number,'verb':verb})
    (root/('entered-'+str(number))).write_text('ready')
    if step is None:
      print(json.dumps({'ok':False,'message':'Unexpected extra fixture read','details':{}}))
      sys.exit(1)
    if step.get('hold'):
      deadline=time.monotonic()+12
      while not (root/('release-'+str(number))).exists():
        if time.monotonic()>deadline:
          log({'event':'expired','number':number})
          sys.exit(9)
        time.sleep(0.01)
    if step.get('delay'):
      time.sleep(step['delay'])
    log({'event':'finish','number':number})
    if 'raw' in step:
      print(step['raw'])
    else:
      print(json.dumps(step['reply']))
    """#

    @MainActor final class Fixture {
        let root: URL
        let helper: URL

        init(base: URL, name: String, steps: [[String: Any]]) throws {
            root = base.appendingPathComponent(name, isDirectory: true)
            helper = root.appendingPathComponent("fixture-helper")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try fixtureScript.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            try JSONSerialization.data(withJSONObject: ["steps": steps]).write(to: root.appendingPathComponent("plan.json"), options: .atomic)
        }

        var count: Int {
            Int((try? String(contentsOf: root.appendingPathComponent("count"), encoding: .utf8)) ?? "") ?? 0
        }

        var events: [[String: Any]] {
            ((try? String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8)) ?? "")
                .split(separator: "\n").compactMap {
                    (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
                }
        }

        func entered(_ number: Int) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("entered-\(number)").path)
        }

        func release(_ number: Int) throws {
            try Data("release".utf8).write(to: root.appendingPathComponent("release-\(number)"), options: .atomic)
        }

        func model(seed: Int = 2) -> ControllerModel {
            let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
            // setPetEnabled would request Accessibility. Fixtures assign the public state directly.
            model.petEnabled = true
            model.claudeSessions = sessions(5)
            model.claudeSessionsReadState = .answered
            model.petSessions = sessions(seed)
            return model
        }
    }

    static func wireRows(_ count: Int) -> [[String: Any]] {
        guard count > 0 else { return [] }
        let stamp = ISO8601DateFormatter().string(from: Date())
        return (1...count).map { number in
            ["id": "fixture-native-\(number)", "provider": ["claude", "codex", "cursor"][(number - 1) % 3],
             "name": "Synthetic session \(number)", "state": "running", "alive": true,
             "agentState": "running", "stateSource": "registry", "updatedAt": stamp, "stateSince": stamp]
        }
    }

    static func sessions(_ count: Int) -> [ClaudeSession] {
        wireRows(count).compactMap { row in
            let data = try! JSONSerialization.data(withJSONObject: row)
            return ClaudeSession(try! JSONDecoder().decode(JSONValue.self, from: data))
        }
    }

    static func reply(_ count: Int, complete: Bool? = true) -> [String: Any] {
        var details: [String: Any] = ["sessions": wireRows(count)]
        if let complete { details["liveReadComplete"] = complete }
        return ["ok": true, "message": "Synthetic inventory", "details": details]
    }

    /// Production's selected-inventory state and row composition, populated by actual controller reads.
    static func summaryBody(_ model: ControllerModel) -> [String: JSONValue] {
        let state = TodaySummary.displayedSessionReadState(petEnabled: model.petEnabled,
                                                         catalog: model.claudeSessionsReadState, live: model.petSessionsReadState)
        let rows = TodayHome.liveSessions(list: model.claudeSessions, live: model.petEnabled ? model.petSessions : nil)
        return TodaySummary.inputs(sessions: rows, needs: [], folded: 0, sessionsRead: state == .answered,
                                   settled: state == .answered, failed: state == .failed ? [.sessions] : [],
                                   recording: false, now: Date()).object ?? [:]
    }

    static func waitFor(_ behavior: String, until predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !predicate() && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        check(predicate(), behavior)
    }

    static func goodAndEmpty(_ base: URL) async throws {
        let fixture = try Fixture(base: base, name: "good-and-empty", steps: [["reply": reply(5)], ["reply": reply(0)]])
        let model = fixture.model()
        await model.loadPetSessions(force: true)
        check(fixture.count == 1, "one live helper request for a full force read")
        check(model.petSessions.count == 5 && model.petSessions.filter(\.isPetWorking).count == 5, "the five actual helper rows replace the old two")
        check(model.petSessionsReadState == .answered, "a full live receipt certifies the selected inventory")
        let body = summaryBody(model)
        check(body["sessions"]?.array?.count == 5 && body["sessionsRead"]?.bool == true && body["needsComplete"]?.bool == true,
              "a successful live read reaches the real summary input as five complete rows")
        await model.loadPetSessions(force: true)
        check(fixture.count == 2 && model.petSessions.isEmpty, "a valid empty live inventory clears retained rows")
        check(model.petSessionsReadState == .answered && summaryBody(model)["sessionsRead"]?.bool == true,
              "an explicit valid empty receipt remains answered")
    }

    static func failures(_ base: URL) async throws {
        let bad: [(String, [String: Any])] = [
            ("refused", ["reply": ["ok": false, "message": "Synthetic refusal", "details": [:]]]),
            ("missing-array", ["reply": ["ok": true, "message": "Synthetic malformed reply", "details": ["liveReadComplete": true]]]),
            ("wrong-array", ["reply": ["ok": true, "message": "Synthetic malformed array", "details": ["sessions": "not an array", "liveReadComplete": true]]]),
            ("invalid-row", ["reply": ["ok": true, "message": "Synthetic invalid row", "details": ["sessions": [[:]], "liveReadComplete": true]]]),
            ("invalid-json", ["raw": "{synthetic invalid json"]),
        ]
        for (name, step) in bad {
            let fixture = try Fixture(base: base, name: name, steps: [step])
            let model = fixture.model()
            let old = model.petSessions.map(\.id)
            await model.loadPetSessions(force: true)
            check(fixture.count == 1 && model.petSessions.map(\.id) == old, "\(name) keeps the prior rows")
            check(model.petSessionsReadState == .failed, "\(name) is a failed selected-inventory read")
            let body = summaryBody(model)
            check(body["sessionsRead"]?.bool == false && body["needsComplete"]?.bool == false,
                  "\(name) cannot certify a fresh count using the healthy catalog")
        }
    }

    static func partialAndCompatibility(_ base: URL) async throws {
        let fixture = try Fixture(base: base, name: "partial-and-compatibility", steps: [
            ["reply": reply(3, complete: false)], ["reply": reply(4, complete: nil)],
        ])
        let model = fixture.model()
        await model.loadPetSessions(force: true)
        check(model.petSessions.count == 3, "partial activity can still update visible rows")
        check(model.petSessionsReadState != .answered, "an explicit incomplete live receipt cannot certify the list")
        check(summaryBody(model)["sessionsRead"]?.bool == false && summaryBody(model)["needsComplete"]?.bool == false,
              "partial helper rows keep the actual summary incomplete")
        await model.loadPetSessions(force: true)
        check(model.petSessions.count == 4 && model.petSessionsReadState == .pending,
              "an older helper without the completeness field stays usable and pending")
        check(summaryBody(model)["needsComplete"]?.bool == false, "missing receipt metadata never means a complete empty queue")
    }

    static func forceBarrier(_ base: URL) async throws {
        let fixture = try Fixture(base: base, name: "force-barrier", steps: [
            ["hold": true, "reply": reply(2)], ["reply": reply(5)],
        ])
        let model = fixture.model()
        let oldPoll = Task { @MainActor in await model.loadPetSessions() }
        try await waitFor("the old real helper poll reaches its barrier") { fixture.entered(1) }
        check(model.petSessionsReadState == .pending, "an actual in-flight poll marks live inventory pending")
        var forcedEntered = false
        var forcedReturned = false
        let force = Task { @MainActor in
            forcedEntered = true
            await model.loadPetSessions(force: true)
            forcedReturned = true
        }
        try await waitFor("the force caller reaches the pending queue") { forcedEntered }
        await model.loadPetSessions() // must coalesce, not start or wait for another helper process
        check(fixture.count == 1 && !forcedReturned, "non-force coalesces while force waits for the old helper")
        try fixture.release(1)
        await oldPoll.value
        await force.value
        check(fixture.count == 2 && forcedReturned, "force completes exactly one new read after the old poll")
        check(model.petSessions.count == 5 && model.petSessionsReadState == .answered,
              "the late old two-row reply cannot become the final forced snapshot")
        let events = fixture.events
        let firstFinish = events.firstIndex { $0["event"] as? String == "finish" && $0["number"] as? Int == 1 }
        let secondStart = events.firstIndex { $0["event"] as? String == "start" && $0["number"] as? Int == 2 }
        check(firstFinish != nil && secondStart != nil && firstFinish! < secondStart!,
              "the second helper is not launched until the first helper finished")
        check(summaryBody(model)["sessions"]?.array?.count == 5 && summaryBody(model)["needsComplete"]?.bool == true,
              "force returns only after the fresh five-row summary input exists")
    }

    static func bypassAndDisabled(_ base: URL) async throws {
        let fixture = try Fixture(base: base, name: "catalog-loading", steps: [["reply": reply(5)]])
        let model = fixture.model()
        model.claudeSessionsLoading = true
        await model.loadPetSessions()
        check(fixture.count == 0 && model.petSessions.count == 2, "an ordinary poll keeps the existing catalog-load coalescing rule")
        await model.loadPetSessions(force: true)
        check(fixture.count == 1 && model.petSessions.count == 5 && model.petSessionsReadState == .answered,
              "an explicit force bypasses catalog-loading suppression")
        model.petEnabled = false
        await model.loadPetSessions(force: true)
        check(fixture.count == 1 && model.petSessions.isEmpty && model.petSessionsReadState == .off,
              "disabled reads are off, clear old figure rows, and never launch a helper")
        let body = summaryBody(model)
        check(body["sessions"]?.array?.count == 5 && body["sessionsRead"]?.bool == true,
              "disabled pet selection uses the healthy catalog instead")
    }

    static func cancellation(_ base: URL) async throws {
        let fixture = try Fixture(base: base, name: "cancel-owner", steps: [["hold": true, "reply": reply(5)]])
        let model = fixture.model()
        let old = model.petSessions.map(\.id)
        let read = Task { @MainActor in await model.loadPetSessions(force: true) }
        try await waitFor("the cancellable helper request actually started") { fixture.entered(1) }
        read.cancel()
        await read.value
        check(model.petSessions.map(\.id) == old && model.petSessionsReadState == .failed,
              "cancelling the real helper read keeps old rows and fails completeness")
        check(summaryBody(model)["needsComplete"]?.bool == false, "cancellation cannot become an answered summary")
    }

    static func timeout(_ base: URL) async throws {
        // Exercise ControllerModel's actual 19-second timeout, not a fake error message or a copied budget.
        let fixture = try Fixture(base: base, name: "actual-timeout", steps: [["delay": 30, "reply": reply(5)]])
        let model = fixture.model()
        let old = model.petSessions.map(\.id)
        let started = ProcessInfo.processInfo.systemUptime
        await model.loadPetSessions(force: true)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        check(fixture.count == 1 && fixture.entered(1), "the timeout reaches the real fixture helper")
        check(elapsed >= 1 && elapsed < 29, "the read returns before the fixture's successful delayed reply")
        check(!fixture.events.contains { $0["event"] as? String == "finish" }, "the timed-out helper never supplies its late successful reply")
        check(model.petSessions.map(\.id) == old && model.petSessionsReadState == .failed,
              "actual timeout preserves the old rows and marks the live read failed")
        check(summaryBody(model)["needsComplete"]?.bool == false, "a timed-out figure cannot borrow fresh catalog completeness")
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { preconditionFailure("Use run-today-refresh-integration.sh") }
        let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        precondition(base.path.hasPrefix("/tmp/cos-today-refresh-integration.") || base.path.hasPrefix("/private/tmp/cos-today-refresh-integration."))
        let expectedHome = base.appendingPathComponent("home", isDirectory: true).path
        let env = ProcessInfo.processInfo.environment
        precondition(["HOME", "CFFIXED_USER_HOME", "COS_CONTROL_TEST_HOME"].allSatisfy { env[$0] == expectedHome }, "Private fixture home required")
        precondition(FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path == URL(fileURLWithPath: expectedHome).resolvingSymlinksInPath().path)
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await goodAndEmpty(base)
        try await failures(base)
        try await partialAndCompatibility(base)
        try await forceBarrier(base)
        try await bypassAndDisabled(base)
        try await cancellation(base)
        try await timeout(base)
        print("PASS: Today refresh integration: \(checks) checks (actual ControllerModel/helper, five sessions, empty, failures, partial provenance, force barrier, coalescing, disabled, cancellation and timeout)")
    }
}
