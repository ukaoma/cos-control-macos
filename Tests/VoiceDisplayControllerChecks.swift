import Foundation

/// 0.5.357 (server 6.96.3): the group naming run and Suggest names through the real ControllerModel, against a stand-in helper that
/// holds a revision and refuses a stale one, the way the server's source guard does. No view is created and no window exists. All
/// names and words are invented. Each failure names its behaviour as "check failed [<behaviour>]".
@main @MainActor struct VoiceDisplayControllerChecks {
    nonisolated(unsafe) static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ behaviour: String, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if !condition() {
            print("check failed [\(behaviour)]: \(detail())")
            exit(1)
        }
    }

    static let script = """
    #!/usr/bin/python3
    import fcntl,hashlib,json,pathlib,sys,time
    p=pathlib.Path(__file__).parent
    # One at a time: the panel asks several things at once, and each answer rewrites this file.
    lock=open(p/'fixture.lock','w');fcntl.flock(lock,fcntl.LOCK_EX)
    fp=p/'fixture.json'
    f=json.loads(fp.read_text());a=sys.argv[1:]
    body=json.load(sys.stdin) if a[0].startswith('meeting-interval-') or a[0]=='meeting-voice-batch-apply' else None
    with (p/'calls.jsonl').open('a') as log:log.write(json.dumps({'argv':a,'body':body})+'\\n')
    def opt(k):return a[a.index(k)+1] if k in a else None
    def rev(n):return hashlib.sha256(str(n).encode()).hexdigest()
    review=f['review'];review['sourceRevision']=rev(f['revision'])
    def save():fp.write_text(json.dumps(f))
    if a[0]=='meeting-speakers':
      time.sleep(f.get('rereadDelay',0))
      review['sessionId']=opt('--session');out={'ok':True,'message':'fixture','details':{'review':review}}
      if f.get('rereadBroken') and f.get('writes',0)>0:out={'ok':True,'message':'fixture','details':{'review':{'nope':1}}}
    elif a[0]=='voice-profiles':
      out={'ok':True,'message':'fixture','details':{'profiles':[{'name':'Dana Reyes','embeddings':40},{'name':'Avery Stone','embeddings':20},{'name':'Owner Example','embeddings':90,'isOwner':True}]}}
    elif a[0]=='meeting-relabel':
      label=opt('--from');to=opt('--to')
      if opt('--expected-revision')!=rev(f['revision']):
        out={'ok':True,'message':'stale','details':{'state':'record_source_mismatch','result':{'reason':'record_source_mismatch','error':'Meeting changed since review; reopen before correcting it'}}}
      elif '--confirm' not in a:
        if label in f.get('previewRefuse',{}):
          out={'ok':True,'message':'no','details':{'state':'declined','result':{'error':f['previewRefuse'][label]}}}
        else:
          result={'surfaces':{'sidecar':2,'transcript':1,'attendees':0}}
          if '--assign-voice-profile' in a:
            flagged=label in f.get('flagged',[])
            result['enrolment']={'person':to,'enrolled':3,'attempted':3,'groupSize':3,'groupSec':30,'similarity':0.3 if flagged else 0.8,'belowFloor':flagged,'gates':['below_floor'] if flagged else []}
          out={'ok':True,'message':'preview','details':{'state':'preview','result':result}}
      elif label in f.get('refuse',{}):
        out={'ok':True,'message':'no','details':{'state':'declined','result':{'reason':'name_collision','error':f['refuse'][label]}}}
      else:
        review['voices']=[v for v in review['voices'] if v['label']!=label]
        if not any(v['label']==to for v in review['voices']):review['voices'].append({'label':to,'segments':2,'nameAsserted':True,'reliability':'confident','speakingMs':0})
        f['revision']+=1;f['writes']=f.get('writes',0)+1;f['jobs']=[{'state':'idle'}]
        out={'ok':True,'message':'applied','details':{'state':'applied','result':{'enrolment':{'enrolled':3 if '--assign-voice-profile' in a else 0}}}}
    elif a[0]=='meeting-voice-suggestions':
      if f.get('suggestRoute')=='absent':out={'ok':True,'message':'x','details':{'unavailable':'route_absent'}}
      elif f.get('suggestRoute')=='broken':out={'ok':False,'message':'Unauthorized','details':{}}
      else:
        time.sleep(f.get('suggestDelay',0))
        jobs=f.get('jobs',[])
        current=jobs.pop(0) if len(jobs)>1 else (jobs[0] if jobs else {'state':'idle'})
        job={'rule':{'floor':0.7,'margin':0.05},'modelSpace':'192d','sourceRevision':rev(f['revision'])};job.update(current)
        out={'ok':True,'message':'x','details':{'job':job,'httpStatus':200}}
    elif a[0]=='meeting-voice-batch':
      if f.get('batchRoute')=='absent':out={'ok':True,'message':'x','details':{'unavailable':'route_absent'}}
      else:out={'ok':True,'message':'x','details':{'batches':f.get('batches',[])}}
    elif a[0]=='meeting-voice-batch-apply':
      answer=f['batchAnswer']
      if answer.get('state')!='refused':
        for row in answer.get('named',[]):
          review['voices']=[v for v in review['voices'] if v['label'] not in row['labels']]
          if not any(v['label']==row['name'] for v in review['voices']):review['voices'].append({'label':row['name'],'segments':2,'nameAsserted':True,'reliability':'confident','speakingMs':0})
        f['revision']+=1;f['jobs']=[{'state':'idle'}]
        f.setdefault('batches',[]).append({'batchId':answer['batchId'],'at':'2026-10-30T20:00:00Z','state':answer['state'],'named':answer.get('named',[]),'undoAvailable':answer.get('undoAvailable',False)})
      out={'ok':True,'message':'x','details':{'result':answer,'httpStatus':200}}
    elif a[0]=='meeting-voice-batch-undo':
      answer=f['undoAnswer']
      if answer.get('state')!='refused':
        f['revision']+=1;f['jobs']=[{'state':'idle'}]
        for b in f.get('batches',[]):b['undoAvailable']=False
      out={'ok':True,'message':'x','details':{'result':answer,'httpStatus':200}}
    elif a[0]=='meeting-interval-group-preview':
      out={'ok':True,'message':'no','details':{'state':'declined','result':f['intervalRefusal']}}
    else:out={'ok':True,'message':'fixture','details':{'profiles':[],'unavailable':'fixture'}}
    save()
    print(json.dumps(out))
    """

    nonisolated static let sid = "mac_11111111-1111-4111-8111-111111111111", other = "mac_22222222-2222-4222-8222-222222222222"

    nonisolated static func voice(_ label: String) -> [String: Any] {
        ["label": label, "segments": 3, "nameAsserted": false, "reliability": "unattributed", "speakingMs": 0,
         "phrases": [["text": "invented words for \(label)", "chunkIndex": 1, "stamp": "0:01"]]]
    }
    nonisolated static func reviewBody(_ labels: [String], hint: Bool = true) -> [String: Any] {
        var o: [String: Any] = ["sessionId": sid, "recordId": "ops:quilt:2026-10:fixture.md", "reviewIdentityVersion": 1, "segments": 40, "attributed": false, "mutable": true,
                                "voices": labels.map(voice)]
        if hint {
            let grouped = labels.filter { ["Voice 1", "Voice 2", "Voice 3", "Voice 4"].contains($0) }
            o["voiceDisplay"] = ["source": "speaker-shadow", "recordedAt": "2026-10-30T16:09:00Z", "foldUnderSeconds": 15,
                                 "groups": [["id": "g1", "labels": grouped, "seconds": 300]], "singles": [["label": "Voice 5", "seconds": 90]], "short": [["label": "Voice 6", "seconds": 4]]]
        }
        return o
    }

    static func main() async throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        precondition(dir.path.hasPrefix("/tmp/cos-voice-display-checks."))
        let helper = dir.appendingPathComponent("fixture-helper"), input = dir.appendingPathComponent("fixture.json"), log = dir.appendingPathComponent("calls.jsonl")
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let labels = ["Voice 1", "Voice 2", "Voice 3", "Voice 4", "Voice 5", "Voice 6", "Ext"]

        func fixture(_ extras: [String: Any] = [:]) throws {
            var f: [String: Any] = ["review": reviewBody(labels), "revision": 1]
            f.merge(extras) { _, new in new }
            try JSONSerialization.data(withJSONObject: f).write(to: input, options: .atomic)
            try? FileManager.default.removeItem(at: log)
        }
        func calls() -> [[String]] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["argv"] as? [String]
            }
        }
        func relabels() -> [[String]] { calls().filter { $0.first == "meeting-relabel" } }
        func writes() -> [[String]] { relabels().filter { $0.contains("--confirm") } }
        func wait(_ note: String, _ predicate: () -> Bool) async throws {
            for _ in 0..<800 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            check(false, "fixture timeout", note)
        }
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        model.voiceSuggestionPollInterval = .milliseconds(20)
        func open(_ session: String = sid) async throws {
            model.openSpeakerReview(sessionId: session)
            try await wait("open") { model.openReview?.sessionId == session && !model.reviewLoading && model.voiceSuggestions.probed }
        }
        func mergedRow() -> VoiceDisplayLayout.MergedRow? {
            for row in model.openReview?.voiceDisplayLayout?.rows ?? [] {
                if case .merged(let merged) = row { return merged }
            }
            return nil
        }

        // ── Absent field: nothing about the panel changes, and no suggestion is read as a name.
        try fixture(["review": reviewBody(labels, hint: false), "suggestRoute": "absent"])
        try await open()
        check(model.openReview?.voiceDisplayLayout == nil, "absent field leaves today's list")
        check(model.voiceSuggestions.routeAbsent, "404 hides the button")
        check(model.openReview.map { !model.voiceSuggestions.showsButton(for: $0) } == true, "404 hides the button")
        check(model.openReview.map { model.voiceSuggestions.line(for: $0) == nil } == true, "404 says nothing")
        check(model.reviewError == nil && model.voiceSuggestions.note == nil, "404 says nothing")
        model.startVoiceSuggestions()
        try await Task.sleep(for: .milliseconds(150))
        check(!calls().contains { $0.first == "meeting-voice-suggestions" && $0.contains("--start") }, "404 hides the button", "a click on a hidden button started a check")

        // ── A helper failure on the first read is quiet and shows no button.
        try fixture(["suggestRoute": "broken"])
        model.openSpeakerReview(sessionId: sid)
        try await wait("open") { model.openReview?.sessionId == sid && !model.reviewLoading }
        try await Task.sleep(for: .milliseconds(200))
        check(model.openReview.map { !model.voiceSuggestions.showsButton(for: $0) } == true && model.voiceSuggestions.note == nil, "first read failure is quiet")

        // ── The group naming run, every label through the single row's route.
        try fixture()
        try await open()
        guard let row = mergedRow() else { check(false, "merged row exists"); return }
        check(row.labels == ["Voice 1", "Voice 2", "Voice 3", "Voice 4"], "merged row exists")
        model.previewVoiceGroupName(row, to: "Dana Reyes", assignVoiceProfile: true)
        try await wait("preview") { !model.mergeInFlight }
        guard let plan = model.pendingVoiceGroupName else { check(false, "preview staged", model.voiceGroupNamingOutcome?.line ?? "nothing"); return }
        check(writes().isEmpty, "preview writes nothing")
        check(relabels().count == 4, "one preview per label", "\(relabels().count)")
        check(relabels().map { $0[$0.firstIndex(of: "--from")! + 1] } == row.labels, "one preview per label")
        check(relabels().allSatisfy { $0.contains("--assign-voice-profile") && !$0.contains("--force") }, "picked profile asks for samples, never force")
        check(plan.labels == row.labels && plan.segments == 8 && plan.labelsAddingSamples == 4, "plan reads the previews")
        model.confirmVoiceGroupName(plan)
        try await wait("save") { !model.mergeInFlight && !model.reviewLoading }
        let sent = writes()
        check(sent.count == 4, "every label named", "\(sent.count) \(model.voiceGroupNamingOutcome?.line ?? "") \(model.reviewError ?? "")")
        check(sent.map { $0[$0.firstIndex(of: "--from")! + 1] } == row.labels, "every label named")
        check(Set(sent.map { $0[$0.firstIndex(of: "--expected-revision")! + 1] }).count == 4, "each write binds a fresh revision")
        check(sent.allSatisfy { $0.contains("--assign-voice-profile") && !$0.contains("--force") }, "saves carry the single row's flags")
        // A write, then a read, then the next write. The final read is the full refresh.
        let order = calls().filter { $0.first == "meeting-speakers" || ($0.first == "meeting-relabel" && $0.contains("--confirm")) }.map { $0.first == "meeting-speakers" ? "read" : "write" }
        check(Array(order.prefix(8)) == ["read", "write", "read", "write", "read", "write", "read", "write"], "reread between writes", "\(order)")
        check(model.voiceGroupNamingOutcome == nil && model.notice?.contains("Named Voice 1, 2, 3 and 4 Dana Reyes") == true, "all named notice", model.notice ?? "nil")
        check(model.notice?.contains("12 voice samples added") == true, "all named notice", model.notice ?? "nil")
        check(model.openReview?.voices.contains { $0.label == "Dana Reyes" } == true && model.openReview?.voices.contains { $0.label == "Voice 1" } == false, "panel refreshed")

        // ── The same argv a single VoiceRow sends.
        try fixture()
        try await open()
        model.previewRename(from: "Voice 5", to: "Dana Reyes", scope: .thisMeeting, isNameAssignment: true, assignVoiceProfile: true)
        try await wait("single preview") { !model.mergeInFlight && model.pendingCorrection != nil }
        let singlePreview = relabels().last!
        model.confirmCorrection(model.pendingCorrection!)
        try await wait("single save") { !model.mergeInFlight && !model.reviewLoading && model.pendingCorrection == nil }
        let singleWrite = writes().last!
        try fixture()
        try await open()
        model.previewVoiceGroupName(mergedRow()!, to: "Dana Reyes", assignVoiceProfile: true)
        try await wait("preview") { !model.mergeInFlight }
        let groupPreview = relabels().first!
        model.confirmVoiceGroupName(model.pendingVoiceGroupName!)
        try await wait("save") { !model.mergeInFlight && !model.reviewLoading }
        let groupWrite = writes().first!
        func shape(_ argv: [String]) -> [String] {
            var out = argv
            for key in ["--from", "--expected-revision"] { if let i = out.firstIndex(of: key) { out[i + 1] = "*" } }
            return out
        }
        check(shape(groupPreview) == shape(singlePreview), "same preview argv as a single row", "\(groupPreview) vs \(singlePreview)")
        check(shape(groupWrite) == shape(singleWrite), "same save argv as a single row", "\(groupWrite) vs \(singleWrite)")

        // ── A typed name stays text only.
        try fixture()
        try await open()
        model.previewVoiceGroupName(mergedRow()!, to: "New Name Example", assignVoiceProfile: false)
        try await wait("preview") { !model.mergeInFlight }
        check(relabels().allSatisfy { !$0.contains("--assign-voice-profile") }, "typed name is text only")
        check(model.pendingVoiceGroupName?.assignmentRequested == false, "typed name is text only")
        model.pendingVoiceGroupName = nil
        // The wearer's own profile never receives samples, however the name arrives.
        try fixture()
        try await open()
        model.previewVoiceGroupName(mergedRow()!, to: "Owner Example", assignVoiceProfile: true)
        try await wait("preview") { !model.mergeInFlight }
        check(relabels().allSatisfy { !$0.contains("--assign-voice-profile") }, "owner profile gets no samples")
        model.pendingVoiceGroupName = nil

        // ── A flagged label saves as text only, and the others still add samples.
        try fixture(["flagged": ["Voice 2"]])
        try await open()
        model.previewVoiceGroupName(mergedRow()!, to: "Dana Reyes", assignVoiceProfile: true)
        try await wait("preview") { !model.mergeInFlight }
        check(model.pendingVoiceGroupName?.labelsFlagged == 1 && model.pendingVoiceGroupName?.labelsAddingSamples == 3, "flagged label counted")
        model.confirmVoiceGroupName(model.pendingVoiceGroupName!)
        try await wait("save") { !model.mergeInFlight && !model.reviewLoading }
        let flaggedWrites = writes()
        check(flaggedWrites.count == 4, "flagged label still renamed", "\(flaggedWrites.count)")
        check(!flaggedWrites[1].contains("--assign-voice-profile") && !flaggedWrites[1].contains("--force"), "flagged label is text only")
        check(flaggedWrites[0].contains("--assign-voice-profile") && flaggedWrites[2].contains("--assign-voice-profile"), "others add samples")
        check(model.notice?.contains("9 voice samples added") == true, "notice counts what was added", model.notice ?? "nil")

        // ── A refusal partway stops, and the words name both lists.
        try fixture(["refuse": ["Voice 3": "That name is already used in this recording."]])
        try await open()
        model.previewVoiceGroupName(mergedRow()!, to: "Dana Reyes", assignVoiceProfile: true)
        try await wait("preview") { !model.mergeInFlight }
        model.confirmVoiceGroupName(model.pendingVoiceGroupName!)
        try await wait("save") { !model.mergeInFlight && !model.reviewLoading && model.voiceGroupNamingOutcome != nil }
        check(writes().count == 3, "refusal stops the run", "\(writes().count)")
        check(writes().last.map { $0[$0.firstIndex(of: "--from")! + 1] } == "Voice 3", "refusal stops the run")
        let partway = model.voiceGroupNamingOutcome
        check(partway?.named == ["Voice 1", "Voice 2"], "refusal names the named", "\(partway?.named ?? [])")
        check(partway?.notNamed == ["Voice 3", "Voice 4"], "refusal names the not named", "\(partway?.notNamed ?? [])")
        check(partway?.stoppedAt == "Voice 3", "refusal says where")
        check(partway?.line == "Named Voice 1 and 2 Dana Reyes. Not named: Voice 3 and 4. Stopped at Voice 3: That name is already used in this recording.", "refusal in plain words", partway?.line ?? "nil")
        check(model.openReview?.voices.contains { $0.label == "Voice 3" } == true && model.openReview?.voices.contains { $0.label == "Voice 2" } == false, "panel shows what happened")
        check(model.pendingVoiceGroupName == nil, "plan cleared")
        // The first label refused: nothing named, no refresh owed.
        try fixture(["refuse": ["Voice 1": "No."]])
        try await open()
        model.previewVoiceGroupName(mergedRow()!, to: "Dana Reyes", assignVoiceProfile: true)
        try await wait("preview") { !model.mergeInFlight }
        model.confirmVoiceGroupName(model.pendingVoiceGroupName!)
        try await wait("save") { !model.mergeInFlight && model.voiceGroupNamingOutcome != nil }
        check(model.voiceGroupNamingOutcome?.line == "Nothing was named. Stopped at Voice 1: No.", "first label refused", model.voiceGroupNamingOutcome?.line ?? "nil")

        // ── A refused preview ends with nothing written and no Save to press.
        try fixture(["previewRefuse": ["Voice 2": "A meeting is being recorded right now."]])
        try await open()
        model.previewVoiceGroupName(mergedRow()!, to: "Dana Reyes", assignVoiceProfile: true)
        try await wait("preview") { !model.mergeInFlight }
        check(model.pendingVoiceGroupName == nil && writes().isEmpty, "refused preview writes nothing")
        check(model.voiceGroupNamingOutcome?.line == "Nothing was named. Stopped at Voice 2: A meeting is being recorded right now.", "refused preview in words", model.voiceGroupNamingOutcome?.line ?? "nil")

        // ── A reread that fails stops the run where it stands.
        try fixture(["rereadBroken": true])
        try await open()
        model.previewVoiceGroupName(mergedRow()!, to: "Dana Reyes", assignVoiceProfile: true)
        try await wait("preview") { !model.mergeInFlight }
        model.confirmVoiceGroupName(model.pendingVoiceGroupName!)
        try await wait("save") { !model.mergeInFlight && model.voiceGroupNamingOutcome != nil }
        check(writes().count == 1 && model.voiceGroupNamingOutcome?.named == ["Voice 1"], "unreadable reread stops", "\(writes().count)")

        // ── A plan cannot be saved after the review moved, or once cancelled.
        try fixture()
        try await open()
        model.previewVoiceGroupName(mergedRow()!, to: "Dana Reyes", assignVoiceProfile: true)
        try await wait("preview") { !model.mergeInFlight }
        let held = model.pendingVoiceGroupName!
        model.pendingVoiceGroupName = nil
        model.confirmVoiceGroupName(held)
        try await Task.sleep(for: .milliseconds(100))
        check(writes().isEmpty, "cancelled plan writes nothing")
        model.previewVoiceGroupName(mergedRow()!, to: "Dana Reyes", assignVoiceProfile: true)
        try await wait("preview") { !model.mergeInFlight }
        let stale = model.pendingVoiceGroupName!
        var moved = reviewBody(labels); moved["sourceRevision"] = String(repeating: "f", count: 64)
        model.openReview = SpeakerReview(try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: moved)))
        model.confirmVoiceGroupName(stale)
        try await Task.sleep(for: .milliseconds(100))
        check(writes().isEmpty && model.pendingVoiceGroupName == nil, "moved review writes nothing")

        // ── Moving to another meeting mid-run still reports what happened.
        try fixture(["rereadDelay": 0.25])
        try await open()
        model.previewVoiceGroupName(mergedRow()!, to: "Dana Reyes", assignVoiceProfile: true)
        try await wait("preview") { !model.mergeInFlight }
        model.notice = nil
        model.confirmVoiceGroupName(model.pendingVoiceGroupName!)
        try await wait("first write") { writes().count == 1 }
        model.openSpeakerReview(sessionId: other)
        try await wait("report") { model.notice != nil }
        check(model.notice?.contains("Not named: Voice 2, 3 and 4") == true, "moved away still reported", model.notice ?? "nil")
        check(writes().count == 1, "moved away stops writing", "\(writes().count)")

        // ── Suggest names: nothing is named without a click.
        let done: [String: Any] = ["state": "done", "suggestions": [
            ["labels": ["Voice 1", "Voice 2", "Voice 3"], "name": "Dana Reyes", "score": 0.82, "margin": 0.11, "units": 12, "kept": 10, "requiresConfirmation": true],
            ["labels": ["Voice 4"], "name": "Blake Moss", "score": 0.78, "margin": 0.09, "units": 4, "kept": 4, "requiresConfirmation": true],
            ["labels": ["Voice 5"], "name": "Avery Stone", "score": 0.74, "margin": 0.08, "units": 4, "kept": 4, "requiresConfirmation": true],
            ["labels": ["Voice 6"], "name": "Owner Example", "score": 0.9, "margin": 0.2, "units": 4, "kept": 4, "requiresConfirmation": true],
            ["labels": ["Ext"], "name": "Blake Moss", "score": 0.9, "margin": 0.2, "units": 4, "kept": 4, "requiresConfirmation": true]],
            "unmatched": [["labels": ["Voice 9"], "gate": "below_rule"]]]
        let running: (Int, Int) -> [String: Any] = { ["state": "running", "progress": ["done": $0, "total": $1]] }
        try fixture(["jobs": [["state": "idle"], running(120, 753), running(400, 753), running(752, 753), done]])
        try await open()
        guard let idleReview = model.openReview else { check(false, "button after the first read"); return }
        check(model.voiceSuggestions.showsButton(for: idleReview), "button after the first read")
        check(model.voiceSuggestions.line(for: idleReview) == VoiceDisplayCopy.suggestionsOnly, "says these are suggestions")
        model.startVoiceSuggestions()
        var sawProgress = false
        try await wait("suggest") {
            if model.voiceSuggestions.line(for: idleReview)?.hasPrefix("Checking voices, ") == true { sawProgress = true }
            return model.voiceSuggestions.job?.state == .done
        }
        check(sawProgress, "progress line while running")
        check(calls().filter { $0.first == "meeting-voice-suggestions" && $0.contains("--start") }.count == 1, "one click starts one check")
        check(relabels().isEmpty, "nothing named without a click", "\(relabels())")
        guard let group = mergedRow() else { check(false, "merged row exists"); return }
        let heldByGroup = model.voiceNameSuggestions(heldBy: group.labels)
        check(heldByGroup.map(\.name) == ["Dana Reyes", "Blake Moss"], "merged row shows every suggestion", "\(heldByGroup.map(\.name))")
        check(heldByGroup[0].labels == ["Voice 1", "Voice 2", "Voice 3"], "a suggestion covers only its labels")
        check(model.voiceNameSuggestions(heldBy: ["Voice 5"]).map(\.name) == ["Avery Stone"], "single row shows its suggestion")
        check(model.voiceNameSuggestions(heldBy: ["Voice 6"]).isEmpty, "the wearer is never suggested for a mac voice")
        check(model.voiceNameSuggestions(heldBy: ["Ext"]).isEmpty, "no ext suggestions")
        check(model.voiceNameSuggestions(heldBy: ["Voice 9"]).isEmpty, "unmatched shows nothing")
        check(model.voiceSuggestions.note == nil && model.reviewError == nil, "unmatched shows nothing")
        // A click goes to a preview. The Save is still a separate click.
        model.useVoiceNameSuggestion(model.voiceNameSuggestions(heldBy: ["Voice 5"])[0], rowLabels: ["Voice 5"])
        try await wait("use") { !model.mergeInFlight && model.pendingCorrection != nil }
        check(writes().isEmpty && relabels().count == 1, "use this name only previews", "\(relabels())")
        check(relabels().first?.contains("--assign-voice-profile") == true, "use this name feeds the profile")
        check(model.pendingCorrection?.from == "Voice 5" && model.pendingCorrection?.to == "Avery Stone", "use this name opens the normal card")
        model.cancelCorrection()
        let beforeGroup = relabels().count
        model.useVoiceNameSuggestion(heldByGroup[0], rowLabels: group.labels)
        try await wait("use group") { !model.mergeInFlight && model.pendingVoiceGroupName != nil }
        check(writes().isEmpty, "use this name only previews")
        check(model.pendingVoiceGroupName?.labels == ["Voice 1", "Voice 2", "Voice 3"] && model.pendingVoiceGroupName?.to == "Dana Reyes", "use this name names exactly its labels", "\(model.pendingVoiceGroupName?.labels ?? [])")
        check(relabels().count == beforeGroup + 3, "use this name names exactly its labels", "\(relabels().count - beforeGroup)")
        model.confirmVoiceGroupName(model.pendingVoiceGroupName!)
        try await wait("use group saved") { !model.mergeInFlight && !model.reviewLoading }
        check(writes().map { $0[$0.firstIndex(of: "--from")! + 1] } == ["Voice 1", "Voice 2", "Voice 3"], "use this name saves exactly its labels", "\(writes())")
        check(model.openReview?.voices.contains { $0.label == "Voice 4" } == true, "the rest of the row stays unnamed")
        // After a name the revision moves, and every suggestion goes with it.
        model.previewRename(from: "Voice 5", to: "Avery Stone", scope: .thisMeeting, isNameAssignment: true, assignVoiceProfile: true)
        try await wait("preview") { !model.mergeInFlight && model.pendingCorrection != nil }
        model.confirmCorrection(model.pendingCorrection!)
        try await wait("saved") { !model.mergeInFlight && !model.reviewLoading && model.pendingCorrection == nil }
        check(model.voiceNameSuggestions(heldBy: group.labels).isEmpty, "revision change drops suggestions")
        try await Task.sleep(for: .milliseconds(150))
        check(model.openReview.map { model.voiceSuggestions.line(for: $0) == VoiceDisplayCopy.staleSuggestions } == true, "revision change says so", model.openReview.flatMap { model.voiceSuggestions.line(for: $0) } ?? "nil")

        // A refusal, in plain words, and the button is still there.
        try fixture(["jobs": [["state": "idle"], ["state": "refused", "reason": "recording_active"]]])
        try await open()
        model.startVoiceSuggestions()
        try await wait("refused") { model.voiceSuggestions.job?.state == .refused }
        check(model.openReview.map { model.voiceSuggestions.line(for: $0) == "A recording is active. Try again when it ends." } == true, "refusal in plain words")
        check(model.openReview.map { model.voiceSuggestions.showsButton(for: $0) } == true, "button stays after a refusal")

        // A late answer belongs to the meeting that asked.
        try fixture(["jobs": [["state": "idle"], running(1, 2)], "suggestDelay": 0.0])
        try await open()
        model.startVoiceSuggestions()
        try await wait("running") { model.voiceSuggestions.isRunning }
        try fixture(["jobs": [["state": "idle"]], "suggestDelay": 0.2])
        model.openSpeakerReview(sessionId: other)
        check(model.voiceSuggestions == VoiceSuggestionState(), "a new meeting starts clean")
        try await wait("other") { model.openReview?.sessionId == other && !model.reviewLoading && model.voiceSuggestions.probed }
        check(!model.voiceSuggestions.isRunning, "late answer dropped")
        try await Task.sleep(for: .milliseconds(150))
        check(!model.voiceSuggestions.isRunning, "late answer dropped")

        // The fold and the merged rows reset on a new meeting.
        try fixture()
        try await open()
        model.voiceDisplayShortExpanded = true
        model.voiceDisplayExpandedRows = ["group:g1"]
        try await open()
        check(!model.voiceDisplayShortExpanded && model.voiceDisplayExpandedRows.isEmpty, "fold resets on a new meeting")
        model.voiceDisplayShortExpanded = true
        model.closeSpeakerReview()
        check(!model.voiceDisplayShortExpanded, "fold resets on close")

        // ── The one-click batch. A merged row is one voice, under .80 stays out, nothing writes until Confirm, the server does it all.
        let highDone: [String: Any] = ["state": "done", "suggestions": [
            ["labels": ["Voice 1", "Voice 2", "Voice 3"], "name": "Dana Reyes", "score": 0.91, "margin": 0.11, "units": 12, "kept": 10, "requiresConfirmation": true, "highConfidence": true],
            ["labels": ["Voice 4"], "name": "Riley Park", "score": 0.81, "margin": 0.07, "units": 4, "kept": 4, "requiresConfirmation": true, "highConfidence": true],
            ["labels": ["Voice 5"], "name": "Avery Stone", "score": 0.84, "margin": 0.08, "units": 4, "kept": 4, "requiresConfirmation": true, "highConfidence": true],
            ["labels": ["Voice 6"], "name": "Blake Moss", "score": 0.74, "margin": 0.08, "units": 4, "kept": 4, "requiresConfirmation": true, "highConfidence": false]]]
        func batchFixture(_ extras: [String: Any] = [:]) async throws {
            var base: [String: Any] = ["jobs": [["state": "idle"], highDone], "batches": []]
            base.merge(extras) { _, new in new }
            try fixture(base)
            model.openSpeakerReview(sessionId: sid)
            try await wait("batch open") { model.openReview?.sessionId == sid && !model.reviewLoading && model.voiceSuggestions.probed && model.voiceBatch.probed }
            model.startVoiceSuggestions()
            try await wait("batch suggest") { model.voiceSuggestions.job?.state == .done }
        }
        func applies() -> [[String]] { calls().filter { $0.first == "meeting-voice-batch-apply" } }
        func applyBodies() -> [[String: Any]] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                let o = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                return (o?["argv"] as? [String])?.first == "meeting-voice-batch-apply" ? o?["body"] as? [String: Any] : nil
            }
        }
        let namedRow: (String, String) -> [String: Any] = { ["labels": $0.split(separator: ",").map(String.init), "name": $1, "samplesAdded": 3] }
        try await batchFixture(["batchAnswer": ["batchId": "b1", "state": "applied", "named": [namedRow("Voice 1,Voice 2,Voice 3,Voice 4", "Dana Reyes")], "notNamed": [], "undoAvailable": true],
                                "undoAnswer": ["state": "undone", "reverted": [namedRow("Voice 1,Voice 2,Voice 3,Voice 4", "Dana Reyes")], "left": [], "samplesRemoved": 12]])
        let offered = model.voiceBatchCandidates
        // Two suggestions on one merged row are two batch rows, each with its own labels.
        check(offered.map(\.title) == ["Voice 1 and 2 more", "Voice 4", "Voice 5"], "batch offers one row per suggestion", "\(offered.map(\.title))")
        check(model.voiceNameSuggestions(heldBy: ["Voice 6"]).map(\.name) == ["Blake Moss"], "under .80 keeps its single click")
        // Confirm does nothing until the list is open and something is ticked.
        model.confirmVoiceBatch()
        try await Task.sleep(for: .milliseconds(80))
        check(applies().isEmpty, "nothing writes until confirm")
        model.voiceBatch.previewOpen = true
        for candidate in offered { model.voiceBatch.unticked.insert(candidate.id) }
        model.confirmVoiceBatch()
        try await Task.sleep(for: .milliseconds(80))
        check(applies().isEmpty && !model.mergeInFlight, "zero ticks sends nothing")
        model.voiceBatch.unticked = [offered[1].id, offered[2].id]
        model.confirmVoiceBatch()
        try await wait("batch applied") { !model.mergeInFlight && !model.reviewLoading && model.voiceBatch.result != nil }
        check(applies().count == 1 && relabels().isEmpty, "the server does the batch", "\(relabels())")
        let sentBody = applyBodies().first ?? [:]
        check((sentBody["items"] as? [[String: Any]])?.count == 1, "only ticked rows travel", "\(sentBody)")
        check((sentBody["items"] as? [[String: Any]])?.first?["name"] as? String == "Dana Reyes", "only ticked rows travel")
        check((sentBody["items"] as? [[String: Any]])?.first?["labels"] as? [String] == ["Voice 1", "Voice 2", "Voice 3"], "the item carries the suggestion's labels")
        check(sentBody["confirm"] as? Bool == true && (sentBody["sourceRevision"] as? String)?.count == 64, "apply binds the revision")
        check(model.voiceBatch.result?.line == "Named 1 voice.", "all named line", model.voiceBatch.result?.line ?? "nil")
        check(!model.voiceBatch.previewOpen, "preview closes on confirm")
        // Refreshed: the names are on the rows, and suggestions bound to the old revision dropped.
        check(model.openReview?.voices.contains { $0.label == "Dana Reyes" } == true, "refresh after confirm")
        check(model.voiceBatchCandidates.isEmpty && model.voiceNameSuggestions(heldBy: ["Voice 5"]).isEmpty, "old revision drops the batch")
        try await wait("undo offered") { model.voiceBatch.undoableBatch?.batchId == "b1" }
        // Reopening the review still offers the Undo, from the server's list.
        model.closeSpeakerReview()
        check(model.voiceBatch == VoiceBatchState(), "a closed review starts over")
        model.openSpeakerReview(sessionId: sid)
        try await wait("reopen") { model.openReview?.sessionId == sid && !model.reviewLoading && model.voiceBatch.probed }
        check(model.voiceBatch.undoableBatch?.batchId == "b1", "undo survives reopening")
        let beforeUndo = calls().count
        model.undoVoiceBatch()
        try await wait("undone") { !model.mergeInFlight && !model.reviewLoading && model.voiceBatch.undoResult != nil }
        check(calls().dropFirst(beforeUndo).contains { $0 == ["meeting-voice-batch-undo", "--session", sid, "--batch", "b1"] }, "undo names its batch", "\(calls().suffix(5))")
        check(calls().dropFirst(beforeUndo).contains { $0.first == "meeting-speakers" }, "refresh after undo")
        check(model.voiceBatch.undoResult?.line == "Undid 1 name. Removed 12 profile samples.", "undo reported", model.voiceBatch.undoResult?.line ?? "nil")
        try await wait("undo gone") { model.voiceBatch.undoableBatch == nil }

        // A partial answer lists what happened; Undo stays for what was named.
        try await batchFixture(["batchAnswer": ["batchId": "b2", "state": "partial", "named": [namedRow("Voice 1,Voice 2,Voice 3,Voice 4", "Dana Reyes")],
                                                "notNamed": [["labels": ["Voice 5"], "name": "Avery Stone", "reason": "That name is already used differently."]], "undoAvailable": true]])
        model.voiceBatch.previewOpen = true
        model.confirmVoiceBatch()
        try await wait("partial") { !model.mergeInFlight && !model.reviewLoading && model.voiceBatch.result != nil }
        check(model.voiceBatch.result?.line == "Named 1 voice. Stopped at Voice 5: That name is already used differently. Not named: Voice 5.", "partial line", model.voiceBatch.result?.line ?? "nil")
        try await wait("partial undo") { model.voiceBatch.undoableBatch?.batchId == "b2" }

        // A refusal names nothing, and offers no undo.
        try await batchFixture(["batchAnswer": ["state": "refused", "reason": "recording_active", "named": [], "notNamed": [], "undoAvailable": false]])
        let before = model.openReview?.voices.map(\.label) ?? []
        model.voiceBatch.previewOpen = true
        model.confirmVoiceBatch()
        try await wait("refused") { !model.mergeInFlight && !model.reviewLoading && model.voiceBatch.result != nil }
        check(model.voiceBatch.result?.line == "Nothing was named. A recording is active.", "refusal line", model.voiceBatch.result?.line ?? "nil")
        check(model.openReview?.voices.map(\.label) == before && model.voiceBatch.undoableBatch == nil, "refusal names nothing")
        check(model.voiceBatchCandidates.count == 3, "refusal keeps the offer", "\(model.voiceBatchCandidates.count)")

        // An older server: every batch control is hidden, and Suggest names still works with its single clicks.
        try fixture(["jobs": [["state": "idle"], highDone], "batchRoute": "absent"])
        model.openSpeakerReview(sessionId: sid)
        try await wait("absent open") { model.openReview?.sessionId == sid && !model.reviewLoading && model.voiceBatch.probed }
        check(model.voiceBatch.routeAbsent, "404 hides the batch")
        model.startVoiceSuggestions()
        try await wait("absent suggest") { model.voiceSuggestions.job?.state == .done }
        check(model.voiceBatchCandidates.isEmpty, "404 hides the batch")
        check(model.voiceNameSuggestions(heldBy: ["Voice 5"]).map(\.name) == ["Avery Stone"], "single clicks survive a 404")
        model.voiceBatch.previewOpen = true
        model.confirmVoiceBatch()
        try await Task.sleep(for: .milliseconds(80))
        check(applies().isEmpty, "404 hides the batch")
        model.undoVoiceBatch()
        try await Task.sleep(for: .milliseconds(80))
        check(!calls().contains { $0.first == "meeting-voice-batch-undo" }, "404 hides the batch")

        // ── The collision message: the server sends `error`, and the panel now reads it.
        let word: [String: Any] = ["id": String(repeating: "c", count: 64), "text": "invented", "startElapsedMs": 100, "endElapsedMs": 200, "elapsedMs": 100, "wordCount": 1]
        let scope: [String: Any] = ["kind": "interval-words", "identityId": "fluid256_fixture", "displayLabel": "Anonymous group 1", "scopeSHA256": String(repeating: "b", count: 64), "members": [word], "fieldCount": 1]
        let interval: [String: Any] = ["sessionId": sid, "recordId": "fixture-record", "mutable": false, "reviewIdentityVersion": 1, "intervalHumanRecoveryRequired": false, "intervalGroupScopes": [scope],
                                       "intervalHumanAnnotation": NSNull(), "voices": []]
        try fixture(["review": interval, "intervalRefusal": ["reason": "interval_group_correction_refused", "error": "That name is already asserted in this recording."]])
        model.openSpeakerReview(sessionId: sid)
        try await wait("interval") { model.openReview?.sessionId == sid && !model.reviewLoading }
        let wordScope = model.openReview!.intervalGroupScopes[0]
        model.previewIntervalWordName(wordScope, memberIds: [wordScope.members[0].id], to: "Dana Reyes")
        try await wait("refused") { !model.mergeInFlight && !model.reviewLoading && model.reviewError != nil }
        check(model.reviewError == "That name is already asserted in this recording.", "collision shows the server's words", model.reviewError ?? "nil")

        print("PASS: \(checks) voice display controller checks")
    }
}
