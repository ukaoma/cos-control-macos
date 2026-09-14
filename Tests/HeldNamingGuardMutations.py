"""Compile the actual naming model definitions and prove every new Apply guard can fail.
No app launch, helper execution, network, or production state is involved.
"""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parent.parent
source=(root/'Sources/Models.swift').read_text()
source='import Foundation\n'+source[source.index('enum JSONValue:'):source.index('struct HelperResponse:')]+source[source.index('struct HeldVoiceSuggestion:'):source.index('/// 0.5.219 — held samples that')]
tests=r'''
import Foundation
@main struct NamingGuards {
static func main() {
 var p: [String: JSONValue] = ["kind":.string("preview"),"httpStatus":.number(200),"previewHash":.string(String(repeating:"a",count:64)),"expiresAt":.number(Date().addingTimeInterval(300).timeIntervalSince1970*1000),"owner":.bool(true),"requiresListening":.bool(true),"members":.array([.object(["sessionId":.string("m"),"chunkIndex":.number(7),"status":.string("ready")])])]
 let good=HeldNamingReceipt(p)
 precondition(good.canApply(ownerAcknowledged:true,listened:true))
 precondition(!good.canApply(ownerAcknowledged:false,listened:true))
 precondition(!good.canApply(ownerAcknowledged:true,listened:false))
 var bad=p;bad["expiresAt"] = .number(1);precondition(!HeldNamingReceipt(bad).canApply)
 bad=p;bad["httpStatus"] = .number(409);precondition(!HeldNamingReceipt(bad).canApply)
 bad=p;bad["previewHash"] = .string("stale");precondition(!HeldNamingReceipt(bad).canApply)
 bad=p;bad["members"] = .array([]);precondition(!HeldNamingReceipt(bad).canApply)
 bad=p;bad["kind"] = .string("applied");precondition(!HeldNamingReceipt(bad).canApply)
 let null:JSONValue = .object(["sessionId":.string("m"),"chunkIndex":.number(7),"position":.null])
 precondition(HeldNamingPlayback(null)==nil)
 let raw:JSONValue = .object(["sessionId":.string("m"),"chunkIndex":.number(7),"position":.number(3)])
 precondition(HeldNamingPlayback(raw)?.chunkIndex==7)
}
}
'''
mutations={
 'owner acknowledgment':('&& (!owner || ownerAcknowledged)',''),
 'required listening':('&& (!requiresListening || listened)',''),
 'preview expiry':('&& expiresAt.map { $0 > Date() } == true',''),
 'HTTP refusal':('&& httpStatus == 200',''),
 'hash presence':('&& previewHash?.count == 64',''),
 'eligible samples':('&& eligibleSamples > 0',''),
 'preview-only kind':('kind == "preview" &&','true &&'),
 'null playback mapping':('let position = o["position"]?.int, position >= 0','let position = Optional(o["position"]?.int ?? 0), position >= 0'),
}
with tempfile.TemporaryDirectory(prefix='cos-naming-mutations-',dir='/tmp') as folder:
    path=Path(folder)
    for name,pair in [('baseline',None),*mutations.items()]:
        text=source
        if pair:
            before,after=pair
            assert text.count(before)==1,(name,'mutation did not uniquely land')
            text=text.replace(before,after,1)
        (path/'Models.swift').write_text(text)
        (path/'Probe.swift').write_text(tests)
        compiled=subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(path/'Models.swift'),str(path/'Probe.swift'),'-o',str(path/'probe')],capture_output=True,text=True)
        assert compiled.returncode==0,(name,'invalid mutation',compiled.stderr)
        result=subprocess.run([str(path/'probe')],capture_output=True,text=True)
        if pair: assert result.returncode!=0,(name,'guard mutation survived')
        else: assert result.returncode==0,('baseline failed',result.stderr)
        print('PASS '+('baseline' if pair is None else name+' mutation killed'),flush=True)
print(f'COS Control: {len(mutations)} naming guard mutations landed, compiled, and were killed')
