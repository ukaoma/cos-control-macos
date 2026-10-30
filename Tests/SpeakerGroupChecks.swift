import Foundation

@main struct SpeakerGroupChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { checks += 1; precondition(condition(), message) }
        func json(_ object: Any) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: object)) }
        let sid = "mac_11111111-1111-4111-8111-111111111111", revision = String(repeating: "a", count: 64)
        let hash = String(repeating: "b", count: 64)
        let rows: [[String: Any]] = [
            ["rawChunkIndex": 4, "position": 2, "before": "Voice 3", "text": "First fixture passage", "elapsedMs": 24000],
            ["rawChunkIndex": 9, "position": 6, "before": "Voice 8", "text": "Second fixture passage", "elapsedMs": 54000]]
        let object: [String: Any] = ["identityId": "fluid256_fixture", "displayLabel": "Voice 3", "scopeSHA256": hash, "members": rows, "fieldCount": 6]
        let scope = SpeakerGroupScope(json(object))!
        check(scope.reviewBasis == .acoustic, "Older acoustic DTO stays compatible")
        for basis in ["accepted-acoustic-group", "automatic-label-only", "human-authored"] {
            var o=object;o["reviewBasis"]=basis
            check(SpeakerGroupScope(json(o))?.reviewBasis.rawValue == basis, "Explicit scope basis preserved")
        }
        for basis in ["unknown-basis", NSNull(), 7] as [Any] {
            var o=object;o["reviewBasis"]=basis
            check(SpeakerGroupScope(json(o)) == nil, "Unknown or malformed basis cannot inherit acoustic authority")
        }
        var human=object;human["displayLabel"]="Fixture Person";human["reviewBasis"]="human-authored"
        check(SpeakerGroupScope(json(human))?.reviewExplanation.contains("previously named") == true, "Human-authored review is distinct from acoustic identity")
        var automatic=object;automatic["reviewBasis"]="automatic-label-only"
        check(SpeakerGroupScope(json(automatic))?.reviewExplanation.contains("not been verified") == true, "Automatic-only label never claims one verified voice")
        check(scope.members.map(\.rawChunkIndex) == [4, 9], "Membership uses original raw indices, never compacted positions")
        check(scope.members[0].stamp == "0:24", "Source clock rendered")
        for bad in [[], [4, 4], [2], [4, 9, 10], [-1]] { check(scope.selectedMembers(bad) == nil, "Empty, duplicate, compacted, expanded and negative selections rejected") }
        check(scope.selectedMembers([9, 4])?.map(\.rawChunkIndex) == [4, 9], "Selection preserves server source order")
        func args(_ selected: [Int] = [9,4], to: String = "Case Person", rev: String? = nil, confirm: Bool = false) -> [String]? {
            scope.arguments(sessionId: sid, recordId: "ops:quilt:2026-10:fixture.md", revision: rev ?? revision, rawChunkIndices: selected, to: to, confirm: confirm)
        }
        let previewArgs = args()!, confirmArgs = args(confirm: true)!
        check(previewArgs.first == "meeting-group-relabel" && !previewArgs.contains("--confirm"), "Preview cannot apply")
        check(confirmArgs == previewArgs + ["--confirm"], "Explicit second click alone adds confirmation")
        check(previewArgs[previewArgs.firstIndex(of: "--raw-chunks")! + 1] == "4,9", "Canonical unique raw set transported")
        check(!previewArgs.contains("--force") && !previewArgs.contains("--assign-voice-profile"), "No force or enrollment options")
        for name in ["", "A", "Ext", "Unknown", "MU", "Unidentified", "Voice 1", "bad\nname", String(repeating: "x", count: 201)] { check(args(to: name) == nil, "Invalid/unassigned names refused") }
        for bad in ["", String(repeating: "a", count: 63), String(repeating: "A", count: 64), String(repeating: "g", count: 64)] { check(args(rev: bad) == nil, "Revision is exact lowerhex SHA") }
        for key in ["rawChunkIndex", "position"] {
            var badRows = rows; badRows[1][key] = badRows[0][key]; var o = object; o["members"] = badRows
            check(SpeakerGroupScope(json(o)) == nil, "Duplicate source membership rejected")
        }
        for label in ["Ext", "Unknown", "MU", "Unidentified"] {
            var badRows = rows; badRows[0]["before"] = label; var o = object; o["members"] = badRows
            check(SpeakerGroupScope(json(o)) == nil, "Unassigned/protected source cannot be vouched for")
        }
        for key in ["rawChunkIndex", "position", "elapsedMs"] {
            var badRows = rows; badRows[0][key] = 4.5; var o = object; o["members"] = badRows
            check(SpeakerGroupScope(json(o)) == nil, "Fractional source coordinates cannot silently select a different source")
        }
        var fractionalFields = object; fractionalFields["fieldCount"] = 1.5
        check(SpeakerGroupScope(json(fractionalFields)) == nil, "Fractional field count refused")
        for key in ["identityId", "scopeSHA256", "displayLabel"] {
            var o = object; o[key] = key == "displayLabel" ? "Ext" : "../../wrong"; check(SpeakerGroupScope(json(o)) == nil, "Malformed identity/scope/display rejected")
        }
        var reviewObject: [String: Any] = ["sessionId": sid, "recordId": "ops:quilt:2026-10:fixture.md", "sourceRevision": revision, "mutable": false, "groupScopes": [object]]
        let review = SpeakerReview(json(reviewObject))!
        check(review.groupScopes == [scope], "Read-only derived review exposes explicit safe group scope")
        for altered in ["missingRevision", "foreignSession", "duplicateIdentity", "duplicateDisplay", "duplicateMember"] {
            var o = reviewObject
            if altered == "missingRevision" { o.removeValue(forKey: "sourceRevision") }
            if altered == "foreignSession" { o["sessionId"] = "meeting_g2_fixture" }
            if altered == "duplicateIdentity" { o["groupScopes"] = [object, object] }
            if altered == "duplicateDisplay" { var other=object;other["identityId"]="fluid256_other";other["members"]=[["rawChunkIndex":12,"position":8,"before":"Voice 3","text":"Third fixture passage"]];o["groupScopes"]=[object,other] }
            if altered == "duplicateMember" { var other=object;other["identityId"]="fluid256_other";other["displayLabel"]="Voice 9";o["groupScopes"]=[object,other] }
            check(SpeakerReview(json(o))!.groupScopes.isEmpty, "Malformed/overlapping scope set must fail all-or-none: \(altered)")
        }
        func response(_ change: (inout [String: Any]) -> Void = { _ in }) -> HelperResponse {
            var p: [String: Any] = ["identityId": scope.identityId, "scopeSHA256": hash, "sourceRevision": revision, "to": "Case Person", "enrollmentAllowed": false, "fields": 6, "members": rows]
            change(&p)
            return HelperResponse(ok: true, message: "fixture", details: ["state": .string("preview"), "result": json(["preview": p])])
        }
        func pending(_ r: HelperResponse, selected: [Int] = [4,9]) -> PendingSpeakerGroupName? { PendingSpeakerGroupName(scope: scope, review: review, rawChunkIndices: selected, to: "Case Person", response: r) }
        check(pending(response())?.rawChunkIndices == [4,9], "Exact scoped preview stages")
        for key in ["identityId", "scopeSHA256", "sourceRevision", "to"] { check(pending(response { $0[key] = "changed" }) == nil, "Preview binding changed: \(key)") }
        check(pending(response { $0["enrollmentAllowed"] = true }) == nil, "A preview cannot enroll")
        check(pending(response { $0.removeValue(forKey:"enrollmentAllowed") }) == nil, "Missing no-enrollment evidence refused")
        for count in [0,7,40001] { check(pending(response { $0["fields"] = count }) == nil, "Preview field bound enforced") }
        check(pending(response { $0["fields"] = 1.5 }) == nil, "Fractional preview field count refused")
        check(pending(response(), selected: [4]) == nil, "Expanded server preview cannot widen user subset")
        check(pending(response { $0["members"] = [rows[0],rows[0]] }) == nil, "Duplicated preview cannot replace a member")
        for key in ["before","text","elapsedMs","position","rawChunkIndex"] {
            check(pending(response { var changed=rows;changed[0][key] = key == "before" || key == "text" ? "Changed" : 999;$0["members"]=changed }) == nil, "Preview exact source member changed: \(key)")
        }
        var declined=response();declined=HelperResponse(ok:true,message:"declined",details:["state":.string("declined"),"result":declined.details["result"]!]);check(pending(declined)==nil,"Declined cannot stage")
        reviewObject["groupScopes"] = []
        print("PASS SpeakerGroupChecks: \(checks) exact-membership, revision, preview, duplicate/protection checks")
    }
}
