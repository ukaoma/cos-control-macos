import Foundation

@main struct EffectiveSpeakerReviewChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { checks += 1; precondition(condition(), message) }
        func json(_ o: Any) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: o)) }
        let anon: [String: Any] = ["label": "Anonymous group 1", "kind": "anonymous-group", "identityId": "fluid256_fixture", "nameAsserted": false, "reliability": "unattributed", "speakingMs": 1800, "wordCount": 5]
        let unresolved: [String: Any] = ["label": "Ext", "kind": "unresolved", "nameAsserted": false, "reliability": "unattributed", "speakingMs": 1200]
        let named: [String: Any] = ["label": "Preserved Example", "kind": "name", "nameAsserted": true, "reliability": "confident", "speakingMs": 900]
        let summary: [String: Any] = ["version": 1, "basis": "source-bound-hq-words", "anonymousGroupCount": 1, "preservedAnonymousGroupCount": 0, "namedVoiceCount": 1, "withheldNameCount": 0, "unresolvedSpeakingMs": 1200, "unresolvedWordCount": 7, "displayRowCount": 3]
        let base: [String: Any] = ["sessionId": "mac_11111111-1111-4111-8111-111111111111", "segments": 783, "mutable": true, "voices": [anon, unresolved, named], "effectiveSpeakerSummary": summary]
        let review = SpeakerReview(json(base))!
        check(review.inventoryHeader == "1 estimated group · 1 named voice", "Counts groups and preserved names, not remainder as a person")
        check(review.effectiveSpeakerSummary?.unresolvedNote == "Unresolved speech: 7 words · 1s", "Remainder reported independently")
        check(review.voices[0].displayName == "Anonymous group 1" && !review.voices[0].nameAsserted, "Anonymous identity visible without asserting a name")
        check(review.voices[1].displayName == "Unresolved speech", "Generic speech never renders as another person")
        check(review.voices[2].displayName == "Preserved Example", "Existing asserted name stays visible")
        check(!review.mutable && review.groupScopes.isEmpty, "Interval scopes stay read-only despite forged mutable true")
        check(!review.voices[0].canRename && !review.voices[1].canRename, "No old-label naming action for interval groups/remainder")
        check(review.voices[0].intervalWordCount == 5, "Word-backed row does not invent a whole-chunk segment count")
        var preserved = anon; preserved["kind"] = "preserved-anonymous"; preserved["label"] = "Voice 39"; preserved.removeValue(forKey: "identityId")
        check(ReviewVoice(json(preserved))!.intervalKind == .preservedAnonymous && !ReviewVoice(json(preserved))!.nameAsserted, "Human-protected numbered words remain distinct without acquiring a name")

        for key in ["anonymousGroupCount", "preservedAnonymousGroupCount", "namedVoiceCount", "withheldNameCount", "unresolvedSpeakingMs", "unresolvedWordCount", "displayRowCount", "version"] {
            for bad: Any in [-1, 1.5, "1", NSNull(), true] {
                var s = summary; s[key] = bad; var o = base; o["effectiveSpeakerSummary"] = s
                let rejected = SpeakerReview(json(o))!
                check(rejected.effectiveSpeakerSummary == nil, "Malformed exact counter rejected: \(key)")
                check(!rejected.mutable && rejected.groupScopes.isEmpty, "Malformed summary never enables naming")
                check(rejected.inventoryHeader == "Speaker grouping unavailable", "Malformed summary never becomes person count")
            }
        }
        for key in ["anonymousGroupCount", "namedVoiceCount", "withheldNameCount", "displayRowCount", "unresolvedSpeakingMs"] {
            var s = summary; s[key] = 9; var o = base; o["effectiveSpeakerSummary"] = s
            check(SpeakerReview(json(o))!.effectiveSpeakerSummary == nil, "Forged summary must agree with actual rows: \(key)")
        }
        var wrongBasis = summary; wrongBasis["basis"] = "legacy-alias"; var wrong = base; wrong["effectiveSpeakerSummary"] = wrongBasis
        check(SpeakerReview(json(wrong))!.effectiveSpeakerSummary == nil, "Unknown basis does not inherit interval semantics")
        var noSummary = base; noSummary.removeValue(forKey: "effectiveSpeakerSummary")
        let partial = SpeakerReview(json(noSummary))!
        check(!partial.mutable && partial.groupScopes.isEmpty && partial.inventoryHeader == "Speaker grouping unavailable", "Partial interval metadata remains read-only")
        var duplicate = base; duplicate["voices"] = [anon, anon, unresolved, named]
        var duplicateSummary = summary; duplicateSummary["anonymousGroupCount"] = 2; duplicateSummary["displayRowCount"] = 4; duplicate["effectiveSpeakerSummary"] = duplicateSummary
        check(SpeakerReview(json(duplicate))!.effectiveSpeakerSummary == nil, "Duplicate identity cannot inflate groups")
        for label in ["Preserved Example", "Voice 5", "Anonymous group 0", "Anonymous group 1000000"] {
            var a = anon; a["label"] = label
            check(ReviewVoice(json(a))!.intervalKind == nil, "Malformed identity display label rejected")
        }
        for ordinal in [100, 1024] {
            var a = anon; a["label"] = "Anonymous group \(ordinal)"
            let parsed = ReviewVoice(json(a))!
            check(parsed.displayName == "Anonymous group \(ordinal)" && parsed.intervalKind == .anonymousGroup && !parsed.canRename, "Stable retired-identity ordinals remain visible and read-only")
        }
        var badId = anon; badId["identityId"] = "../../source"
        check(ReviewVoice(json(badId))!.intervalKind == nil, "Malformed identity cannot gain interval actions/display authority")
        var asserted = anon; asserted["nameAsserted"] = true
        check(!ReviewVoice(json(asserted))!.nameAsserted && ReviewVoice(json(asserted))!.reliability == .unattributed, "Anonymous metadata cannot qualify a name")
        let legacy: [String: Any] = ["sessionId": "mac_legacy", "segments": 12, "voices": [["label": "Voice 5", "reliability": "unattributed", "nameAsserted": false]], "mutable": true]
        let old = SpeakerReview(json(legacy))!
        check(old.inventoryHeader == "12 segments · 1 voices" && old.mutable, "Absent-field compatibility unchanged")
        check(old.voices[0].displayName == "Voice 5" && old.voices[0].canRename, "Legacy Voice labels preserve behavior")
        print("PASS: \(checks) effective word-review model and malformed-metadata checks")
    }
}
