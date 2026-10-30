import AppKit
import SwiftUI

@main @MainActor struct SpeakerGroupReviewChecks {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        precondition(dir.path.hasPrefix("/tmp/cos-speaker-group-"))
        let helper = dir.appendingPathComponent("fixture-helper"), input = dir.appendingPathComponent("fixture.json")
        let log = dir.appendingPathComponent("calls.jsonl"), started = dir.appendingPathComponent("preview-started")
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ note: String) { checks += 1; precondition(value(), note) }
        func value(_ object: Any) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object)) }
        let sid = "mac_11111111-1111-4111-8111-111111111111", other = "mac_22222222-2222-4222-8222-222222222222"
        let scopeHash = String(repeating: "b", count: 64)
        let rows: [[String: Any]] = [["rawChunkIndex":4,"position":2,"before":"Voice 3","text":"Private fixture first passage","elapsedMs":24000], ["rawChunkIndex":9,"position":6,"before":"Voice 8","text":"Private fixture second passage","elapsedMs":54000]]
        let group: [String: Any] = ["identityId":"fluid256_fixture","displayLabel":"Voice 3","scopeSHA256":scopeHash,"members":rows,"fieldCount":6]
        func review(_ rev: String = String(repeating: "a", count: 64), groups: [[String:Any]]? = nil) -> [String:Any] {
            ["sessionId":sid,"recordId":"ops:quilt:2026-10:fixture.md","sourceRevision":rev,"reviewIdentityVersion":1,"mutable":false,"segments":2,"voices":[],"groupScopes":groups ?? [group]]
        }
        let script = """
        #!/usr/bin/python3
        import json,pathlib,sys,time
        p=pathlib.Path(__file__).parent
        f=json.loads((p/'fixture.json').read_text())
        a=sys.argv[1:]
        with (p/'calls.jsonl').open('a') as log:log.write(json.dumps(a)+'\\n')
        if a[0]=='meeting-speakers':
          r=f['review'];r['sessionId']=a[a.index('--session')+1];out={'ok':True,'message':'fixture','details':{'review':r}}
        elif a[0]=='meeting-group-relabel':
          (p/'preview-started').write_text('started')
          time.sleep(f.get('delay',0))
          if '--confirm' in a:out=f.get('confirmResponse',{'ok':True,'message':'fixture','details':{'state':'applied','result':{'confirmed':True,'enrollmentAllowed':False}}})
          else:
            g=f['review']['groupScopes'][0];selected=set(map(int,a[a.index('--raw-chunks')+1].split(',')));members=[r for r in g['members'] if r['rawChunkIndex'] in selected]
            out=f.get('previewResponse',{'ok':True,'message':'fixture','details':{'state':'preview','result':{'preview':{'identityId':g['identityId'],'scopeSHA256':g['scopeSHA256'],'sourceRevision':f['review']['sourceRevision'],'to':a[a.index('--to')+1],'enrollmentAllowed':False,'members':members,'fields':len(members)*2}}}})
        else:out={'ok':True,'message':'fixture','details':{'profiles':[],'unavailable':'fixture'}}
        print(json.dumps(out))
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:helper.path)
        func fixture(delay: Double = 0, extra: [String:Any] = [:]) throws {
            var f: [String:Any] = ["review":review(),"delay":delay];f.merge(extra){_,b in b}
            try JSONSerialization.data(withJSONObject:f).write(to:input,options:.atomic)
        }
        func calls() -> [[String]] { ((try? String(contentsOf:log,encoding:.utf8)) ?? "").split(separator:"\n").compactMap { try? JSONDecoder().decode([String].self,from:Data($0.utf8)) } }
        func wait(_ predicate: () -> Bool) async throws { for _ in 0..<300 { if predicate() { return };try await Task.sleep(for:.milliseconds(10)) };preconditionFailure("bounded fixture response never arrived") }
        try fixture()
        let model = ControllerModel(startBackgroundWork:false,helper:HelperClient(executableOverride:helper))
        func open() async throws { model.openSpeakerReview(sessionId:sid);try await wait { model.openReview?.sessionId == sid && !model.reviewLoading };check(model.openReview?.groupScopes.count == 1,"Actual controller loads explicit scoped group") }
        try await open();let scope=model.openReview!.groupScopes[0]
        model.previewSpeakerGroupName(scope,rawChunkIndices:[4,4],to:"Fixture Person")
        check(!model.mergeInFlight && model.pendingSpeakerGroupName == nil,"Duplicate selection refused before helper")
        let beforeNonmember = calls().count;model.previewSpeakerGroupName(scope,rawChunkIndices:[4,99],to:"Fixture Person")
        check(calls().count==beforeNonmember,"Selection cannot expand beyond server members")
        try fixture(delay:0.35);try? FileManager.default.removeItem(at:started)
        model.previewSpeakerGroupName(scope,rawChunkIndices:[4],to:"Fixture Person");try await wait { FileManager.default.fileExists(atPath:started.path) }
        model.openSpeakerReview(sessionId:other);try await wait { model.openReview?.sessionId == other && !model.reviewLoading };try await Task.sleep(for:.milliseconds(450))
        check(model.pendingSpeakerGroupName == nil && !model.mergeInFlight,"Late old-meeting preview cannot stage or lock new selection")
        try fixture();try await open()
        try fixture(delay:0.35);try? FileManager.default.removeItem(at:started)
        model.previewSpeakerGroupName(scope,rawChunkIndices:[4],to:"Fixture Person");try await wait { FileManager.default.fileExists(atPath:started.path) }
        model.openReview=SpeakerReview(value(review(String(repeating:"c",count:64))));try await wait { !model.mergeInFlight }
        check(model.pendingSpeakerGroupName == nil,"Same-meeting revision drift invalidates returned preview")
        try fixture();try await open();model.previewSpeakerGroupName(scope,rawChunkIndices:[9,4],to:"Fixture Person");try await wait { !model.mergeInFlight }
        check(model.pendingSpeakerGroupName?.rawChunkIndices == [4,9],"Actual controller stages only exact verified preview")
        let pending=model.pendingSpeakerGroupName!;let countBefore=calls().filter{$0.contains("--confirm")}.count
        model.openReview=SpeakerReview(value(review(String(repeating:"c",count:64))));model.confirmSpeakerGroupName(pending)
        try await Task.sleep(for:.milliseconds(60));check(calls().filter{$0.contains("--confirm")}.count==countBefore,"Stale revision cannot send a save")
        check(model.pendingSpeakerGroupName == nil && model.reviewError != nil,"Stale save invalidates pending confirmation")
        try fixture();try await open();model.previewSpeakerGroupName(scope,rawChunkIndices:[4],to:"Fixture Person");try await wait { !model.mergeInFlight };let selectedPending=model.pendingSpeakerGroupName!
        model.pendingSpeakerGroupName=nil;model.confirmSpeakerGroupName(selectedPending)
        check(calls().filter{$0.contains("--confirm")}.count==countBefore,"Cancelled or replaced selection cannot save held preview")
        try fixture(extra:["previewResponse":["ok":true,"message":"fixture","details":["state":"declined","result":["message":"Group drifted"]]]]);try await open()
        model.previewSpeakerGroupName(scope,rawChunkIndices:[4],to:"Fixture Person");try await wait { !model.mergeInFlight }
        check(model.pendingSpeakerGroupName == nil && model.reviewError == "Group drifted","Server refusal cannot stage")
        // A valid second click applies exactly the staged subset and refreshes.
        try fixture();try await open();model.previewSpeakerGroupName(scope,rawChunkIndices:[4],to:"Fixture Person");try await wait { !model.mergeInFlight }
        let validPending=model.pendingSpeakerGroupName!;model.confirmSpeakerGroupName(validPending)
        try await wait { !model.mergeInFlight }
        let appliedCalls=calls().filter{$0.contains("--confirm")}
        check(appliedCalls.count == countBefore + 1,"One valid second click sends exactly one confirmation")
        check(appliedCalls.last?.contains("--raw-chunks") == true && appliedCalls.last?[appliedCalls.last!.firstIndex(of:"--raw-chunks")!+1] == "4","Save cannot widen the staged subset")
        check(model.pendingSpeakerGroupName == nil && model.notice?.contains("Saved Fixture Person") == true,"Applied result clears preview and reports saved subset")
        // Build both real views without showing, activating, or sending events.
        try fixture();try await open();model.previewSpeakerGroupName(scope,rawChunkIndices:[4],to:"Fixture Person");try await wait { !model.mergeInFlight };let finalPending=model.pendingSpeakerGroupName!
        let host=NSHostingView(rootView:AnyView(SpeakerGroupNamingView(model:model,scope:scope)))
        let window=NSWindow(contentRect:NSRect(x:-20000,y:-20000,width:650,height:480),styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=host
        for confirmation in [false,true] {
            host.rootView = confirmation ? AnyView(SpeakerGroupConfirmationView(model:model,preview:finalPending)) : AnyView(SpeakerGroupNamingView(model:model,scope:scope))
            for mode in [NSAppearance.Name.aqua,.darkAqua] {
                window.appearance=NSAppearance(named:mode);host.layoutSubtreeIfNeeded();host.displayIfNeeded()
                check(!window.isVisible && window.isKeyWindow == false,"Offscreen group review cannot take focus")
                check(host.fittingSize.width.isFinite && host.fittingSize.height > 0,"Actual group view lays out in both appearances")
            }
        }
        model.closeSpeakerReview();window.contentView=nil;window.close()
        check(model.pendingSpeakerGroupName == nil,"Closing review clears staged group naming")
        let requests=calls().filter{$0.first=="meeting-group-relabel"};check(requests.allSatisfy{!$0.contains("--force") && !$0.contains("--assign-voice-profile")},"Controller never enables force/profile enrollment")
        print("PASS SpeakerGroupReviewChecks: \(checks) real controller stale/selection/refusal checks and never-shown light/dark views")
    }
}
