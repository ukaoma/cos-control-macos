import Foundation

@main @MainActor struct IntervalWordNamingControllerChecks {
    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        precondition(dir.path.hasPrefix("/tmp/cos-interval-word-checks."))
        let helper = dir.appendingPathComponent("fixture-helper"), input = dir.appendingPathComponent("fixture.json")
        let log = dir.appendingPathComponent("calls.jsonl"), started = dir.appendingPathComponent("preview-started")
        let sid = "mac_11111111-1111-4111-8111-111111111111", other = "mac_22222222-2222-4222-8222-222222222222"
        let revision = String(repeating: "a", count: 64), hash = String(repeating: "b", count: 64)
        let rows: [[String: Any]] = [
            ["id": String(repeating: "c", count: 64), "text": "same", "startElapsedMs": 123.4375, "endElapsedMs": 223.5, "elapsedMs": 123.4375, "wordCount": 1],
            ["id": String(repeating: "d", count: 64), "text": "crossing", "startElapsedMs": 190, "endElapsedMs": 350, "elapsedMs": 190, "wordCount": 1]]
        let group: [String: Any] = ["kind": "interval-words", "identityId": "fluid256_fixture", "displayLabel": "Anonymous group 1", "scopeSHA256": hash, "members": rows, "fieldCount": 2]
        let action: [String: Any] = ["actionId": "action_1", "to": "Fixture Person", "memberIds": [String(repeating: "d", count: 64)]]
        func review(_ revision: String) -> [String: Any] {
            ["sessionId": sid, "recordId": "fixture-record", "sourceRevision": revision, "mutable": false,
             "intervalHumanRecoveryRequired": false, "intervalGroupScopes": [group], "intervalHumanAnnotation": ["revision": 1, "annotationSHA256": hash, "activeActions": [action]]]
        }
        let script = """
        #!/usr/bin/python3
        import json,pathlib,sys,time
        p=pathlib.Path(__file__).parent
        f=json.loads((p/'fixture.json').read_text());a=sys.argv[1:]
        body=json.load(sys.stdin) if a[0].startswith('meeting-interval-') else None
        with (p/'calls.jsonl').open('a') as log:log.write(json.dumps({'argv':a,'body':body})+'\\n')
        if a[0]=='meeting-speakers':
          r=f['review'];r['sessionId']=a[a.index('--session')+1];out={'ok':True,'message':'fixture','details':{'review':r}}
        elif a[0]=='meeting-interval-group-preview':
          (p/'preview-started').write_text('started');time.sleep(f.get('delay',0));g=f['review']['intervalGroupScopes'][0]
          members=[m for m in g['members'] if m['id'] in body['memberIds']]
          out=f.get('previewResponse',{'ok':True,'message':'fixture','details':{'state':'preview','result':{'preview':{'identityId':g['identityId'],'scopeSHA256':g['scopeSHA256'],'sourceRevision':body['expectedRevision'],'to':body['to'],'enrollmentAllowed':False,'members':members,'fields':len(members)}}}})
        elif a[0]=='meeting-interval-group-original':
          for key in ('intervalGroupScopes','intervalHumanAnnotation','intervalHumanRecoveryRequired','intervalOriginalViewAvailable'):f['review'].pop(key,None)
          f['review']['sourceRevision']='f'*64;f['review']['mutable']=True
          (p/'fixture.json').write_text(json.dumps(f))
          out={'ok':True,'message':'fixture','details':{'state':'applied','result':{'ok':True,'confirmed':True,'enrollmentAllowed':False,'sourceRevision':'f'*64}}}
        elif a[0]=='meeting-interval-group-recover':
          f['review']['intervalHumanRecoveryRequired']=False;f['review']['sourceRevision']='e'*64
          (p/'fixture.json').write_text(json.dumps(f))
          out={'ok':True,'message':'fixture','details':{'state':'applied','result':{'ok':True,'confirmed':True,'enrollmentAllowed':False,'sourceRevision':'e'*64}}}
        elif a[0] in ('meeting-interval-group-relabel','meeting-interval-group-undo'):
          correction={'correctionId':'action_1','revision':2}
          if a[0].endswith('-undo'):correction['undone']=True
          else:correction.update(members=len(body['memberIds']),fields=len(body['memberIds']))
          out=f.get('mutationResponse',{'ok':True,'message':'fixture','details':{'state':'applied','result':{'ok':True,'confirmed':True,'enrollmentAllowed':False,'sourceRevision':'e'*64,'correction':correction}}})
        else:out={'ok':True,'message':'fixture','details':{'profiles':[],'unavailable':'fixture'}}
        print(json.dumps(out))
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        func fixture(_ extras: [String: Any] = [:]) throws {
            var f: [String: Any] = ["review": review(revision)]; f.merge(extras) { _, new in new }
            try JSONSerialization.data(withJSONObject: f).write(to: input, options: .atomic)
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ note: String) { checks += 1; precondition(condition(), note) }
        func calls() -> [[String: Any]] { ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } }
        func mutationCalls() -> [[String: Any]] { calls().filter { ($0["argv"] as? [String])?.first == "meeting-interval-group-relabel" } }
        func wait(_ predicate: () -> Bool) async throws { for _ in 0..<300 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }; preconditionFailure("Fixture timeout") }
        try fixture()
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        func open() async throws { model.openSpeakerReview(sessionId: sid); try await wait { model.openReview?.sessionId == sid && !model.reviewLoading } }
        try await open()
        let scope = model.openReview!.intervalGroupScopes[0], id = scope.members[1].id
        check(scope.members[0].startElapsedMs == 123.4375 && scope.members[0].endElapsedMs == 223.5, "Controller cross-wire preserves server fractional sample clock")
        check(!model.openReview!.mutable && model.openReview!.intervalHumanAnnotation!.activeActions.count == 1, "Producer-off saved annotations remain actionable without old mutation route")
        model.previewIntervalWordName(scope, memberIds: [id, id], to: "Fixture Person")
        check(!model.mergeInFlight && model.pendingIntervalWordName == nil, "Duplicate selection fails before helper")
        try fixture(["delay": 0.25]); try? FileManager.default.removeItem(at: started)
        model.previewIntervalWordName(scope, memberIds: [id], to: "Fixture Person")
        try await wait { FileManager.default.fileExists(atPath: started.path) }
        model.openSpeakerReview(sessionId: other); try await wait { model.openReview?.sessionId == other && !model.reviewLoading }
        try await Task.sleep(for: .milliseconds(350))
        check(model.pendingIntervalWordName == nil && !model.mergeInFlight, "Late preview cannot enter another selected meeting")
        try fixture(); try await open()
        model.previewIntervalWordName(scope, memberIds: [id], to: "Fixture Person"); try await wait { !model.mergeInFlight }
        check(model.pendingIntervalWordName?.members.map(\.text) == ["crossing"], "Partial exact word preview staged")
        let stale = model.pendingIntervalWordName!, count = mutationCalls().count
        let changed = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: review(String(repeating: "f", count: 64))))
        model.openReview = SpeakerReview(changed); model.confirmIntervalWordName(stale)
        check(model.pendingIntervalWordName == nil && mutationCalls().count == count, "Local stale revision cannot send save")
        try await open(); model.previewIntervalWordName(scope, memberIds: [id], to: "Fixture Person"); try await wait { !model.mergeInFlight }
        let preview = model.pendingIntervalWordName!; model.pendingIntervalWordName = nil; model.confirmIntervalWordName(preview)
        check(mutationCalls().count == count, "Cancelled selection cannot save held preview")
        model.previewIntervalWordName(scope, memberIds: [id], to: "Fixture Person"); try await wait { !model.mergeInFlight }
        model.confirmIntervalWordName(model.pendingIntervalWordName!); try await wait { !model.mergeInFlight }
        check(mutationCalls().count == count + 1, "One explicit second click writes once")
        check((mutationCalls().last?["body"] as? [String: Any])?["memberIds"] as? [String] == [id], "Confirmation never widens selection")
        check(model.pendingIntervalWordName == nil && model.notice?.contains("1 reviewed words") == true, "Confirmed save reports exact subset and refreshes")
        let currentAction = model.openReview!.intervalHumanAnnotation!.activeActions[0]
        model.undoIntervalWordName(currentAction); try await wait { !model.mergeInFlight }
        let undos = calls().filter { ($0["argv"] as? [String])?.first == "meeting-interval-group-undo" }
        let undo = undos.last?["body"] as? [String: Any]
        check(undos.count == 1 && undo?["actionId"] as? String == "action_1" && undo?["annotationRevision"] as? Int == 1, "Undo transports current action and annotation guards")
        try fixture(["previewResponse": ["ok": true, "message": "stale", "details": ["state": "declined", "result": ["message": "Words changed"]]]])
        model.previewIntervalWordName(scope, memberIds: [id], to: "Fixture Person"); try await wait { !model.mergeInFlight }
        check(model.pendingIntervalWordName == nil && model.reviewError == "Words changed", "Stale server refusal refreshes before retry")
        check(calls().filter { ($0["argv"] as? [String])?.first?.hasPrefix("meeting-interval-") == true }.allSatisfy { ($0["argv"] as? [String])?.count == 1 }, "Word IDs and names never appear in argv")
        var recoveryReview = review(revision); recoveryReview["intervalHumanRecoveryRequired"] = true
        try fixture(["review": recoveryReview]); try await open()
        check(model.openReview!.intervalHumanRecoveryRequired && model.openReview!.intervalGroupScopes.isEmpty && model.openReview!.intervalHumanAnnotation == nil, "Interrupted state blocks naming and Undo")
        let beforeRecovery = calls().count
        model.recoverIntervalWordNaming()
        check(!model.mergeInFlight && calls().count == beforeRecovery, "Recovery cannot run without separate confirmation")
        model.intervalWordRecoveryArmed = true; model.recoverIntervalWordNaming(); try await wait { !model.mergeInFlight }
        let recoveries = calls().filter { ($0["argv"] as? [String])?.first == "meeting-interval-group-recover" }
        let recoverBody = recoveries.last?["body"] as? [String: Any]
        check(recoveries.count == 1 && Set(recoverBody!.keys) == ["sessionId", "recordId", "confirm"], "Recovery confirms only saved journal and never resubmits name or members")
        check(!model.openReview!.intervalHumanRecoveryRequired && model.openReview!.sourceRevision == String(repeating: "e", count: 64), "Recovery reloads latest review and source revision")
        check(!model.intervalWordRecoveryArmed && model.notice == "Finished interrupted word naming", "Recovery confirmation clears after use")
        let firstID = scope.members[0].id
        var unresolved = group; unresolved["kind"] = "unresolved-words"; unresolved["identityId"] = "unresolved"; unresolved["displayLabel"] = "Unresolved speech"; unresolved["selectionRuns"] = [[firstID, id]]
        var unresolvedReview = review(revision); unresolvedReview["intervalGroupScopes"] = [unresolved]; unresolvedReview["intervalHumanAnnotation"] = NSNull()
        try fixture(["review": unresolvedReview]); try await open()
        let unresolvedScope = model.openReview!.intervalGroupScopes[0]
        model.previewIntervalWordName(unresolvedScope, memberIds: [firstID, id], to: "Manual Person"); try await wait { !model.mergeInFlight }
        check(model.pendingIntervalWordName?.memberIds == [firstID, id], "Unresolved consecutive passage uses exact preview independently of voice grouping")
        model.pendingIntervalWordName = nil
        let humanID = "action-11111111-1111-4111-8111-111111111111"
        var human = group; human["kind"] = "human-words"; human["identityId"] = humanID; human["displayLabel"] = "Fixture Person"
        var renameAction = action; renameAction["identityId"] = humanID; renameAction["memberIds"] = [firstID, id]
        var renameReview = review(revision); renameReview["intervalGroupScopes"] = [human]; renameReview["intervalHumanAnnotation"] = ["revision": 1, "annotationSHA256": hash, "activeActions": [renameAction]]
        try fixture(["review": renameReview]); try await open()
        let humanScope = model.openReview!.humanScope(for: model.openReview!.intervalHumanAnnotation!.activeActions[0])!
        let beforePartialRename = calls().count
        model.previewIntervalWordName(humanScope, memberIds: [id], to: "Renamed Person")
        check(!model.mergeInFlight && calls().count == beforePartialRename, "Human action cannot be renamed through partial selection")
        model.previewIntervalWordName(humanScope, memberIds: [firstID, id], to: "Renamed Person"); try await wait { !model.mergeInFlight }
        check(model.pendingIntervalWordName?.scope.identityId == humanID, "Human rename is previewed through explicit active action identity")
        model.confirmIntervalWordName(model.pendingIntervalWordName!); try await wait { !model.mergeInFlight }
        check((mutationCalls().last?["body"] as? [String: Any])?["memberIds"] as? [String] == [firstID, id], "Confirmed human rename preserves exactwhole action")
        var originalReview = review(revision); originalReview["intervalHumanAnnotation"] = NSNull(); originalReview["intervalOriginalViewAvailable"] = true
        try fixture(["review": originalReview]); try await open()
        check(model.openReview!.intervalOriginalViewAvailable, "Original-view capability is independent of grouped voice rows")
        let beforeOriginal = calls().count; model.useOriginalRecordingView()
        check(!model.mergeInFlight && calls().count == beforeOriginal, "Original-view exit requires separate confirmation")
        model.intervalOriginalViewArmed = true; model.useOriginalRecordingView(); try await wait { !model.mergeInFlight }
        let originals = calls().filter { ($0["argv"] as? [String])?.first == "meeting-interval-group-original" }, originalBody = originals.last?["body"] as? [String: Any]
        check(originals.count == 1 && Set(originalBody!.keys) == ["sessionId", "recordId", "expectedRevision", "confirm"], "Original-view exit sends exact record/revision/confirmation only")
        check(model.openReview!.sourceRevision == String(repeating: "f", count: 64) && !model.openReview!.intervalViewReadOnly, "Original-view exit fully reloads the original source view")
        check(!model.intervalOriginalViewArmed && model.notice == "Using original recording view", "Original-view confirmation is consumed")
        model.closeSpeakerReview(); check(model.pendingIntervalWordName == nil && !model.intervalWordRecoveryArmed && !model.intervalOriginalViewArmed, "Close clears pending word confirmation and recovery")
        print("PASS IntervalWordNamingControllerChecks: \(checks) exact selection, stale preview/save, confirmed save and Undo; no windows")
    }
}
