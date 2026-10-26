import Foundation

/// Future source-only phone consumer checks. Run only after the release owner grants the native lane.
@main struct PhoneMeetingChecks {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message); count += 1 }
        let uuid = "abcdef01-2345-6789-abcd-0123456789ab"
        let phone = "phone_1700000000000_" + uuid, g2 = "meeting_" + uuid, mac = "mac_" + uuid
        check(PhoneMeetingCapture.validID(phone), "timestamped phone identity")
        check(PhoneMeetingCapture.validID("phone_" + uuid), "earlier phone form remains readable")
        for bad in ["phone_anything", phone + "_recovery", phone + "\n", phone.uppercased(), "phone_170000000000_" + uuid, "../" + phone] {
            check(!PhoneMeetingCapture.validID(bad), "bounded lowercase phone grammar")
        }
        for prefix in ["g2:", "mac:", "ff:"] { check(!LibraryMeeting.validContextKey(prefix + phone), "foreign namespace cannot alias phone") }
        check(LibraryMeeting.validContextKey("phone:" + phone), "phone files have exact namespace")
        check(LibraryMeeting.captureContextKey(phone) == "phone:" + phone, "phone canonical context key")
        check(LibraryMeeting.captureContextKey(g2) == "g2:" + g2 && LibraryMeeting.captureContextKey(mac) == "mac:" + mac, "existing source keys unchanged")
        check(LibraryMeeting.captureContextKey("phone_bad").isEmpty, "malformed phone cannot become G2")
        func row(_ id: String, source: String? = nil, extra: [String: JSONValue] = [:]) -> LibraryMeeting {
            var object: [String: JSONValue] = ["filename": .string("Fixture.md"), "month": .string("2026-10"), "sessionId": .string(id)]
            if let source { object["sourceType"] = .string(source) }
            object.merge(extra) { _, value in value }
            return LibraryMeeting(.object(object))!
        }
        let saved = row(phone, source: "iphone_microphone", extra: ["speakerPolicy": .string("anonymous"), "source": .string("G2 Glasses")])
        check(saved.sourceType == "iphone_microphone" && saved.speakerPolicy == "anonymous", "DTO keeps phone source and policy")
        check(saved.subtitle.contains("iPhone Microphone") && !saved.subtitle.contains("G2 Glasses"), "source provenance controls source copy")
        check(!saved.canReviewVoices && !row("phone_bad").canReviewVoices, "phone naming stays unavailable even for malformed input")
        check(row(g2).canReviewVoices && row(mac, source: "mac_system_audio").canReviewVoices, "legacy G2 and Mac review availability unchanged")
        check(saved.meetingAskSessions(keys: ["phone:" + phone, "g2:" + g2, "mac:" + mac]) == [phone], "phone saved Ask cannot join same-UUID other sources")
        check(row(phone).meetingAskSessions(keys: ["phone:" + phone]).isEmpty, "missing source provenance is unavailable")
        let otherPhone = "phone_1700000000000_11111111-1111-4111-8111-111111111111"
        check(saved.meetingAskSessions(keys: ["phone:" + otherPhone]) == [phone], "foreign phone key cannot claim another capture history")
        check(PhoneMeetingCapture.contextKeys(["phone:" + phone, "phone:" + otherPhone, "g2:" + g2], sessionId: phone, sourceType: "iphone_microphone") == ["phone:" + phone], "saved files bound to exact phone capture")
        check(row(g2).meetingAskSessions(keys: ["g2:" + phone, "mac:" + phone]) == [g2], "foreign aliases cannot enter G2 Ask")
        check(!G2MeetingStop.isGlassesSession(phone) && !G2MeetingStop.isGlassesSession("phone_bad"), "phone never enters glasses Stop")
        check(G2MeetingStop.isGlassesSession(g2), "G2 stop retained")
        check(LiveTranscript.sourceLabel(phone, start: nil) == "iPhone microphone", "live switcher source")
        check(LiveMeeting.statusLine(sessionId: phone, ended: false, kinds: nil) == "Recording on iPhone microphone", "live status source")
        check(LiveMeeting.statusLine(sessionId: phone, ended: true, kinds: nil) == "iPhone microphone recording ended", "ended status source")
        let liveRow = LiveTranscriptRow(sessionId: phone, startTime: nil, lastActivity: .distantPast, phase: .live)
        check(LiveTranscript.endActionTitle(row: liveRow, now: Date()) == nil, "Mac cannot directly save owning-phone recording")
        var feed = LiveTranscriptFeed(sessionId: phone)
        var read = LiveTranscriptRead(sessionId: phone, ended: false, unchanged: false)
        read.sourceType = "iphone_microphone"; read.speakerPolicy = "anonymous"; read.settledThrough = 0
        read.turns = [LiveTranscriptChunk(i: 0, elapsedMs: 0, speaker: "Ext", text: "Synthetic words")]
        check(feed.apply(read, now: Date()) && feed.chunkCount == 1, "admitted anonymous phone feed")
        read.speakerPolicy = "standard"; read.settledThrough = 1
        read.turns = [LiveTranscriptChunk(i: 1, elapsedMs: 6000, speaker: "Named person", text: "Rejected")]
        check(!feed.apply(read, now: Date()) && feed.chunkCount == 1 && feed.cursor == 0, "wrong source policy cannot advance data or cursor")
        _ = feed.markEnded(now: Date())
        read.unchanged = true
        check(!feed.apply(read, now: Date()) && feed.ended, "rejected unchanged read cannot revive phone feed")
        func orphan(_ id: String, source: String? = nil, admitted: Bool = false) -> OrphanCapture {
            var object: [String: JSONValue] = ["sessionId": .string(id), "chunkFiles": .number(2), "recoverable": .bool(true)]
            if let source { object["sourceType"] = .string(source) }
            if admitted { object["provenanceState"] = .string("admitted") }
            return OrphanCapture(.object(object))!
        }
        check(!orphan(phone).recoverable, "unadmitted phone recovery unavailable")
        check(orphan(phone, source: "iphone_microphone", admitted: true).recoverable, "admitted retained phone recovery remains available")
        check(!orphan("phone_bad", source: "iphone_microphone", admitted: true).recoverable, "malformed phone recovery refused")
        check(!orphan(g2, source: "iphone_microphone", admitted: true).recoverable, "phone source cannot alias G2 recovery")
        check(orphan(g2).recoverable && orphan(mac).recoverable, "legacy recovery unchanged")
        let stranded = StrandedCapture(.object(["sessionId": .string(phone), "sourceType": .string("iphone_microphone"), "chunks": .number(3), "canSave": .bool(true)]))!
        check(!stranded.canSave && stranded.label.contains("finish on iPhone"), "still-live phone never enters Control save")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cos-phone-consumer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let disk = MeetingAskDisk(root: root)
        var scopes: [String] = []
        for id in [phone, g2, mac] {
            let scope = MeetingAskDisk.scope(server: "fixture-server", pairing: "fixture-pairing", session: id)
            scopes.append(scope)
            var record = MeetingAskLocalRecord(scope: scope); record.draft = id
            record.files = [MeetingAskFile(id: "same-file-id", revision: "r1", name: id + ".txt", status: "ready", text: id, notice: nil)]
            try disk.write(record)
        }
        check(Set(scopes).count == 3, "same UUID source caches cannot collide")
        let reopened = try disk.read(MeetingAskDisk.scope(server: "fixture-server", pairing: "fixture-pairing", session: saved.meetingAskSessions(keys: ["phone:" + phone])[0]))
        check(reopened.draft == phone && reopened.files.first?.text == phone, "live-to-saved reopen retains exact phone draft/files")
        let g2Record = try disk.read(scopes[1]), macRecord = try disk.read(scopes[2])
        check(g2Record.files.first?.text == g2, "G2 file context unchanged")
        check(macRecord.files.first?.text == mac, "Mac file context unchanged")
        print("phone meeting checks: \(count) passed")
    }
}
