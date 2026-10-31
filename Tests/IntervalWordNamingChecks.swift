import Foundation

@main struct IntervalWordNamingChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ note: String) { checks += 1; precondition(value(), note) }
        func json(_ value: Any) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value)) }
        let hash = String(repeating: "a", count: 64), sid = "mac_11111111-1111-4111-8111-111111111111"
        // Both are from raw chunk 4; the second crosses its raw boundary. Neither raw coordinate is a selector.
        let words: [[String: Any]] = [
            ["id": String(repeating: "b", count: 64), "text": "same", "startElapsedMs": 123.4375, "endElapsedMs": 223.5, "elapsedMs": 123.4375, "wordCount": 1, "rawChunkIndex": 4],
            ["id": String(repeating: "c", count: 64), "text": "crossing", "startElapsedMs": 190, "endElapsedMs": 350, "elapsedMs": 190, "wordCount": 1, "rawChunkIndex": 4]]
        let group: [String: Any] = ["kind": "interval-words", "identityId": "fluid256_fixture", "displayLabel": "Anonymous group 1", "scopeSHA256": hash, "members": words, "fieldCount": 2]
        let scope = IntervalWordGroupScope(json(group))!
        check(scope.members.count == 2 && scope.members[0].id != scope.members[1].id, "Two word IDs within one raw chunk remain separate")
        check(scope.members[0].startElapsedMs == 123.4375 && scope.members[0].endElapsedMs == 223.5, "Cross-wire sample-clock fractions remain exact doubles")
        check(scope.members[0].stamp == "123.4375–223.5000 ms", "Exact sample fraction renders safely without integer truncation")
        check(scope.members[1].endElapsedMs == 350, "Word crossing raw boundary retains exact full range")
        let anonymous = ReviewVoice(json(["label": "Anonymous group 1", "kind": "anonymous-group", "identityId": "fluid256_fixture", "nameAsserted": false, "reliability": "unattributed"]))!
        let namedLikeGroup = ReviewVoice(json(["label": "Anonymous group 1", "kind": "name", "nameAsserted": true, "reliability": "confident"]))!
        let otherIdentity = ReviewVoice(json(["label": "Anonymous group 1", "kind": "anonymous-group", "identityId": "fluid256_other", "nameAsserted": false, "reliability": "unattributed"]))!
        check(scope.matches(anonymous), "Validated anonymous identity binds its exact word scope")
        check(!scope.matches(namedLikeGroup), "Human name resembling anonymous display label never binds scope")
        check(!scope.matches(otherIdentity), "Available mismatched identity never falls back by same display label")
        for label in ["Fixture Person", "Anonymous group 0", "Anonymous group 1000000", "Ext", "Voice 2"] {
            var altered = group; altered["displayLabel"] = label
            check(IntervalWordGroupScope(json(altered)) == nil, "Only unique Anonymous group N scope labels are accepted")
        }
        let ids = scope.members.map(\.id)
        check(scope.selectedMembers([ids[1]])?.map(\.text) == ["crossing"], "Partial selection does not widen to chunk or group")
        for invalid in [[], [ids[0], ids[0]], [String(repeating: "d", count: 64)]] { check(scope.selectedMembers(invalid) == nil, "Empty, duplicate and foreign selections rejected") }
        func request(_ chosen: [String], _ confirm: Bool = false, _ to: String = "Fixture Person") -> [String: Any]? {
            guard let data = scope.request(sessionId: sid, recordId: "fixture-record", revision: hash, memberIds: chosen, to: to, confirm: confirm) else { return nil }
            return try! JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let body = request([ids[1]])!
        check(body["memberIds"] as? [String] == [ids[1]] && body["dryRun"] as? Bool == true && body["confirm"] == nil, "Preview only transports exact IDs with dryRun")
        check(request([ids[1]], true)?["confirm"] as? Bool == true, "Explicit save supplies confirmation")
        check(Set(body.keys) == ["sessionId", "recordId", "expectedRevision", "identityId", "scopeSHA256", "memberIds", "to", "dryRun"], "No raw/profile/force fields")
        for name in ["Ext", "Unknown", "Voice 2", "bad\nname", "A"] { check(request(ids, false, name) == nil, "Invalid target rejected") }
        var reviewObject: [String: Any] = ["sessionId": sid, "recordId": "fixture-record", "sourceRevision": hash, "speakerCallView": ["mode": "source-bound-intervals"], "intervalGroupScopes": [group]]
        let annotation: [String: Any] = ["revision": 1, "annotationSHA256": hash, "activeActions": [["actionId": "action_1", "to": "Fixture Person", "memberIds": [ids[1]]]]]
        reviewObject["intervalHumanAnnotation"] = annotation
        let review = SpeakerReview(json(reviewObject))!
        check(!review.mutable && review.groupScopes.isEmpty && review.intervalGroupScopes == [scope], "Only new word scopes enable safe naming")
        let ann = review.intervalHumanAnnotation!, action = ann.activeActions[0]
        let undo = try JSONSerialization.jsonObject(with: ann.undoRequest(action: action, review: review)!) as! [String: Any]
        check(undo["actionId"] as? String == "action_1" && undo["annotationRevision"] as? Int == 1 && undo["annotationSHA256"] as? String == hash, "Undo is tied to current action and annotation")
        check(undo["confirm"] as? Bool == true && undo["memberIds"] == nil, "Undo never reconstructs a broader range")
        func preview(_ alter: (inout [String: Any]) -> Void = { _ in }) -> PendingIntervalWordName? {
            var p: [String: Any] = ["identityId": scope.identityId, "scopeSHA256": hash, "sourceRevision": hash, "to": "Fixture Person", "enrollmentAllowed": false, "members": [words[1]], "fields": 1]
            alter(&p)
            let response = HelperResponse(ok: true, message: "fixture", details: ["state": .string("preview"), "result": json(["preview": p])])
            return PendingIntervalWordName(scope: scope, review: review, memberIds: [ids[1]], to: "Fixture Person", response: response)
        }
        check(preview()?.memberIds == [ids[1]], "Exact selected preview accepted")
        for key in ["identityId", "scopeSHA256", "sourceRevision", "to"] { check(preview { $0[key] = "changed" } == nil, "Stale or changed preview binding refused") }
        check(preview { $0["members"] = words } == nil, "Server cannot widen partial selection")
        check(preview { $0["enrollmentAllowed"] = true } == nil, "Enrollment never accepted")
        check(preview { var row = words[1]; row["endElapsedMs"] = 999; $0["members"] = [row] } == nil, "Changed exact range refused")
        for key in ["id", "wordCount"] {
            var malformed = group, bad = words; bad[0][key] = key == "id" ? "raw-4" : 1.5; malformed["members"] = bad
            check(IntervalWordGroupScope(json(malformed)) == nil, "Malformed word selectors fail closed")
        }
        for key in ["startElapsedMs", "endElapsedMs", "elapsedMs"] {
            for invalid: Any in [-1, 1_000_000_000_001.0, "123.4375", true, NSNull()] {
                var malformed = group, bad = words; bad[0][key] = invalid; malformed["members"] = bad
                check(IntervalWordGroupScope(json(malformed)) == nil, "Malformed, negative or unbounded timing rejected")
            }
        }
        var duplicate = group; duplicate["members"] = [words[0], words[0]]
        check(IntervalWordGroupScope(json(duplicate)) == nil, "Duplicate opaque IDs rejected")
        var wrongKind = group; wrongKind["kind"] = "raw-chunks"
        check(IntervalWordGroupScope(json(wrongKind)) == nil, "Legacy scopes cannot acquire word semantics")
        for key in ["sourceRevision", "recordId"] {
            var altered = reviewObject; altered.removeValue(forKey: key)
            check(SpeakerReview(json(altered))!.intervalGroupScopes.isEmpty, "Review requires exact source guards")
        }
        for malformed: Any in ["true", "false", 1, 0, NSNull(), [String](), [String: String]()] {
            var altered = reviewObject; altered["intervalHumanRecoveryRequired"] = malformed
            let bad = SpeakerReview(json(altered))!
            check(!bad.mutable && bad.intervalGroupScopes.isEmpty && bad.intervalHumanAnnotation == nil && !bad.intervalHumanRecoveryRequired, "Malformed recovery flag cannot enable naming, Undo, or recovery")
        }
        var recovering = reviewObject; recovering["intervalHumanRecoveryRequired"] = true
        let blocked = SpeakerReview(json(recovering))!
        check(blocked.intervalHumanRecoveryRequired && blocked.intervalGroupScopes.isEmpty && blocked.intervalHumanAnnotation == nil, "Verified recovery state blocks new naming and Undo")
        recovering["intervalHumanRecoveryRequired"] = false
        check(SpeakerReview(json(recovering))!.intervalGroupScopes == [scope], "Exact false recovery flag enables valid scopes")
        // Producer switches never gate consumption of already confirmed human annotations.
        check(review.intervalHumanAnnotation?.activeActions.count == 1, "Saved human actions remain visible with producer flags off")
        let third: [String: Any] = ["id": String(repeating: "d", count: 64), "text": "third", "startElapsedMs": 400, "endElapsedMs": 500, "elapsedMs": 400, "wordCount": 1]
        let fourth: [String: Any] = ["id": String(repeating: "e", count: 64), "text": "next batch", "startElapsedMs": 600, "endElapsedMs": 700, "elapsedMs": 600, "wordCount": 1]
        let runIDs = ids + [String(repeating: "d", count: 64), String(repeating: "e", count: 64)]
        let unresolvedObject: [String: Any] = ["kind": "unresolved-words", "identityId": "unresolved", "displayLabel": "Unresolved speech", "scopeSHA256": hash,
            "members": words + [third, fourth], "fieldCount": 4, "selectionRuns": [Array(runIDs.prefix(3)), [runIDs[3]]]]
        let unresolvedScope = IntervalWordGroupScope(json(unresolvedObject))!
        check(unresolvedScope.selectedMembers(Array(runIDs.prefix(2)))?.count == 2, "Unresolved selector accepts one consecutive range in one run")
        check(unresolvedScope.selectedMembers([runIDs[0], runIDs[2]]) == nil, "Unresolved selector rejects a gap")
        check(unresolvedScope.selectedMembers([runIDs[2], runIDs[3]]) == nil, "Unresolved selector rejects a cross-run range")
        check(unresolvedScope.selectedMembers([runIDs[3]])?.count == 1, "A second passage can be selected independently")
        for brokenRuns: Any in [[[runIDs[0], runIDs[0]]], [[runIDs[0]]], "all", NSNull()] {
            var altered = unresolvedObject; altered["selectionRuns"] = brokenRuns
            check(IntervalWordGroupScope(json(altered)) == nil, "Malformed, duplicate or incomplete allowed runs fail closed")
        }
        var noRuns = unresolvedObject; noRuns.removeValue(forKey: "selectionRuns")
        check(IntervalWordGroupScope(json(noRuns)) == nil, "Unresolved words require server-issued contiguous runs")
        let humanID = "action-11111111-1111-4111-8111-111111111111"
        var humanObject = group; humanObject["kind"] = "human-words"; humanObject["identityId"] = humanID; humanObject["displayLabel"] = "Fixture Person"
        let humanScope = IntervalWordGroupScope(json(humanObject))!
        check(humanScope.selectedMembers([ids[0]]) == nil && humanScope.selectedMembers(ids)?.count == 2, "Human rename is atomic over the complete active action")
        check(!humanScope.matches(anonymous) && !humanScope.matches(namedLikeGroup), "Human scopes never bind through a grouped voice row")
        let humanAction: [String: Any] = ["actionId": action.actionId, "to": action.to, "memberIds": ids, "identityId": humanID]
        var humanAnnotation = annotation; humanAnnotation["activeActions"] = [humanAction]
        var humanReview = reviewObject; humanReview["intervalGroupScopes"] = [humanObject]; humanReview["intervalHumanAnnotation"] = humanAnnotation
        let renameReview = SpeakerReview(json(humanReview))!, renameAction = IntervalHumanAnnotation.Action(json(humanAction))!
        check(renameReview.humanScope(for: renameAction) == humanScope, "Review-level rename binds explicit server action identity plus complete members")
        var secondHuman = humanObject; secondHuman["identityId"] = "action-22222222-2222-4222-8222-222222222222"; secondHuman["members"] = [third, fourth]
        var duplicateNames = humanReview; duplicateNames["intervalGroupScopes"] = [humanObject, secondHuman]
        check(SpeakerReview(json(duplicateNames))!.intervalGroupScopes.count == 2, "Separate human action identities may share display text without collapsing scopes")
        var wrongAction = humanAction; wrongAction["identityId"] = "action-22222222-2222-4222-8222-222222222222"
        check(renameReview.humanScope(for: IntervalHumanAnnotation.Action(json(wrongAction))!) == nil, "Identical human display text cannot bind another action")
        var original = reviewObject; original["intervalHumanAnnotation"] = NSNull(); original["intervalOriginalViewAvailable"] = true
        check(SpeakerReview(json(original))!.intervalOriginalViewAvailable, "Explicit original-view availability with valid empty annotation is actionable")
        for flag: Any in [false, "true", 1, NSNull()] {
            var altered = original; altered["intervalOriginalViewAvailable"] = flag
            check(!SpeakerReview(json(altered))!.intervalOriginalViewAvailable, "Original-view flag must be exact true")
        }
        check(!review.intervalOriginalViewAvailable, "Missing original-view capability remains unavailable")
        original["intervalHumanAnnotation"] = annotation
        check(!SpeakerReview(json(original))!.intervalOriginalViewAvailable, "Active human actions block original-view exit")
        original["intervalHumanAnnotation"] = NSNull(); original["intervalHumanRecoveryRequired"] = true
        check(!SpeakerReview(json(original))!.intervalOriginalViewAvailable, "Interrupted action blocks original-view exit")
        var overlapping = group; overlapping["identityId"] = "fluid256_second"; overlapping["displayLabel"] = "Anonymous group 2"
        var altered = reviewObject; altered["intervalGroupScopes"] = [group, overlapping]
        check(SpeakerReview(json(altered))!.intervalGroupScopes.isEmpty, "Overlapping public word scopes fail all-or-none")
        // Private local layout only, after accepted grouping. This does not qualify hybrid
        // evidence or alter people/group counts, words, scopes, timelines or clipboard output.
        let durations: [Any?] = [14_999, 15_000, 15_001, 1, 0, -1, 14_999.5, nil, "14999", true, NSNull()]
        var fragmentVoices: [[String: Any]] = []
        var fragmentScopes: [[String: Any]] = []
        for (index, duration) in durations.enumerated() {
            let label = "Anonymous group \(index + 1)", identity = "fluid256_fragment_\(index)"
            var row: [String: Any] = ["label": label, "kind": "anonymous-group", "identityId": identity,
                "nameAsserted": false, "reliability": "unattributed", "segments": index + 1, "wordCount": 1]
            if let duration { row["speakingMs"] = duration }
            fragmentVoices.append(row)
            var word = words[0]; word["id"] = String(format: "%064x", index + 100)
            fragmentScopes.append(["kind": "interval-words", "identityId": identity, "displayLabel": label,
                "scopeSHA256": hash, "members": [word], "fieldCount": 1])
        }
        fragmentVoices.insert(["label": "Ext", "kind": "unresolved", "nameAsserted": false, "reliability": "unattributed", "speakingMs": 40, "segments": 99], at: 0)
        fragmentVoices.append(["label": "Fixture Person", "kind": "name", "nameAsserted": true, "reliability": "confident", "speakingMs": 1])
        fragmentVoices.append(["label": "Voice 39", "kind": "preserved-anonymous", "nameAsserted": false, "reliability": "unattributed", "speakingMs": 1])
        let fragmentSummary: [String: Any] = ["version": 1, "basis": "source-bound-hq-words", "anonymousGroupCount": durations.count,
            "preservedAnonymousGroupCount": 1, "namedVoiceCount": 1, "withheldNameCount": 0,
            "unresolvedSpeakingMs": 40, "unresolvedWordCount": 1, "displayRowCount": fragmentVoices.count]
        var fragmentObject: [String: Any] = ["sessionId": sid, "recordId": "fixture-record", "sourceRevision": hash,
            "voices": fragmentVoices, "effectiveSpeakerSummary": fragmentSummary, "intervalGroupScopes": fragmentScopes,
            "timeline": [["speaker": "Anonymous group 1", "startMs": 100, "endMs": 200, "segments": 1]]]
        let fragmentReview = SpeakerReview(json(fragmentObject))!, displayRows = fragmentReview.displayVoiceRows
        check(fragmentReview.effectiveSpeakerSummary != nil, "Fragment fixture uses validated accepted effective metadata")
        check(displayRows.shortFragments.map(\.label) == ["Anonymous group 4", "Anonymous group 1"], "Only known positive durations strictly under fifteen seconds fold, in stable review order")
        let acceptedMain = fragmentReview.voicesForReview.filter { $0.intervalKind == .anonymousGroup && !["Anonymous group 4", "Anonymous group 1"].contains($0.label) }
        check(Array(displayRows.main.prefix(acceptedMain.count)) == acceptedMain, "Accepted anonymous main rows come first in their existing stable order")
        check(Array(displayRows.main.dropFirst(acceptedMain.count)) == fragmentReview.voicesForReview.filter { $0.intervalKind != .anonymousGroup }, "Remaining unresolved, named and preserved rows retain their stable order")
        check(Set((displayRows.main + displayRows.shortFragments).map(\.label)) == Set(fragmentReview.voices.map(\.label)), "Partition preserves every original row exactly once")
        check(displayRows.main.count + displayRows.shortFragments.count == fragmentReview.voices.count, "Folding neither merges nor duplicates rows")
        for voice in displayRows.shortFragments {
            let originalScope = fragmentReview.intervalGroupScopes.first { $0.matches(voice) }!
            check(originalScope.members.count == 1 && originalScope.request(sessionId: sid, recordId: "fixture-record", revision: hash, memberIds: originalScope.members.map(\.id), to: "Fixture Other", confirm: false) != nil, "Expanded original fragment retains its exact word preview/name path")
        }
        check(fragmentReview.voices[0].label == "Ext" && fragmentReview.voicesForReview[0].label == "Ext", "Canonical source and review order stay untouched")
        check(fragmentReview.timeline.count == 1 && fragmentReview.timeline[0].speaker == "Anonymous group 1", "Timeline is unchanged by list folding")
        check(fragmentReview.inventoryHeader.contains("11 estimated groups") && !fragmentReview.inventoryHeader.contains("people"), "Fold count never changes the grouping summary or implies people")
        var allLarge = fragmentVoices
        for index in allLarge.indices where allLarge[index]["kind"] as? String == "anonymous-group" { allLarge[index]["speakingMs"] = 15_000 }
        fragmentObject["voices"] = allLarge
        check(SpeakerReview(json(fragmentObject))!.displayVoiceRows.shortFragments.isEmpty, "No short accepted rows means no disclosure, including the current all-large packet")
        fragmentObject["voices"] = fragmentVoices
        for key in ["effectiveSpeakerSummary", "intervalGroupScopes", "sourceRevision"] {
            var unsupported = fragmentObject; unsupported.removeValue(forKey: key)
            let review = SpeakerReview(json(unsupported))!
            check(review.displayVoiceRows.shortFragments.isEmpty && review.displayVoiceRows.main == review.voicesForReview, "Missing accepted metadata/scope authority retains the original main list")
        }
        var mismatchedScopes = fragmentScopes
        for index in mismatchedScopes.indices { mismatchedScopes[index]["identityId"] = "fluid256_other_\(index)" }
        var unsupported = fragmentObject; unsupported["intervalGroupScopes"] = mismatchedScopes
        check(SpeakerReview(json(unsupported))!.displayVoiceRows.shortFragments.isEmpty, "Matching label text cannot fold a row with a different exact identity")
        unsupported = fragmentObject; unsupported["sessionId"] = "g2_fixture"
        check(SpeakerReview(json(unsupported))!.displayVoiceRows.main == SpeakerReview(json(unsupported))!.voicesForReview, "G2 and legacy/hybrid views remain unchanged")
        print("PASS IntervalWordNamingChecks: \(checks) exact word, partial preview and Undo guard checks")
    }
}
