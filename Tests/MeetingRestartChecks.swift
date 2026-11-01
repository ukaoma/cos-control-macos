import Foundation

// What the panel does with a helper `status`: `check <file>` reads one reply and prints what the buttons would be told.
// Run by Tests/meeting-restart-checks.py, so a server-side fix cannot pass while the button stays disabled. With no
// argument it runs the rules that need no helper.
@main struct MeetingRestartChecks {
    static func main() throws {
        func check(_ yes: Bool, _ label: String) { if !yes { fatalError(label) } }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "check" {
            let reply = try JSONDecoder().decode(HelperResponse.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            let status = ServerStatus(reply.details)
            let summary: [String: Any] = [
                "blocking": status.meetingWorkBlockingRestart, "label": status.displayedMeetingSync.label, "reason": status.meetingWorkBlockReason,
                "note": status.heldAudioNote ?? NSNull(), "lastError": status.meetingFinalizationLastError ?? NSNull(),
                "active": status.meetingSyncActive, "blocksFlag": status.meetingSyncBlocksRestart,
                "rows": status.meetingSyncMeetings.map { ["stage": $0.stage, "waiting": $0.isWaiting, "held": $0.isHeld] },
            ]
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: summary))
            return
        }
        func row(_ fields: [String: JSONValue]) -> JSONValue { .object(fields.merging(["meetingId": .string("meeting_1789754707558_277naf"), "chunkFiles": .number(216)]) { a, _ in a }) }
        func status(_ fields: [String: JSONValue]) -> ServerStatus { ServerStatus(fields) }
        let serverWords = "HQ polish stopped · audio kept · retries later"
        // A stopped row shows the server's own words, and never reads as waiting.
        let stopped = MeetingSyncRow(row(["phase": .string("stopped"), "percent": .null, "label": .string(serverWords)]))!
        check(stopped.isHeld && !stopped.isWaiting && stopped.stage == serverWords, "a stopped row shows the server's words and is not waiting")
        check(MeetingSyncRow(row(["phase": .string("stopped")]))?.stage == "stopped", "a stopped row with no label still says stopped")
        let pending = MeetingSyncRow(row(["phase": .string("pending")]))!
        check(!pending.isHeld && pending.isWaiting && pending.stage.hasPrefix("Waiting"), "an older server's waiting row is unchanged")
        let working = MeetingSyncRow(row(["phase": .string("hq_polish"), "percent": .number(40), "label": .string("HQ polish 40%")]))!
        check(!working.isHeld && MeetingSyncRow.ordered([stopped, pending, working]).map(\.phase) == ["hq_polish", "pending", "stopped"], "held rows sort after work and the queue")
        // The note only ever appears when nothing is blocked, and each block names its own cause.
        let kept = status(["meetingSyncLabel": .string("Audio kept for 2 meetings"), "meetingSyncHeldCount": .number(2)])
        check(!kept.meetingWorkBlockingRestart && kept.heldAudioNote?.hasPrefix("The server is stopped") == true && kept.heldAudioNote?.contains("Update Server") == true, "stopped, held audio blocks nothing and says what still works")
        let heldRow = status(["meetingSyncLabel": .string(serverWords), "meetingSyncMeetings": .array([row(["phase": .string("stopped"), "label": .string(serverWords)])])])
        check(!heldRow.meetingWorkBlockingRestart && heldRow.heldAudioNote?.hasPrefix("This meeting's save stopped") == true && heldRow.displayedMeetingSync.label == serverWords, "a stopped job blocks nothing and says so")
        let busy = status(["meetingSyncActive": .bool(true), "meetingSyncBlocksRestart": .bool(true), "meetingSyncMeetings": .array([row(["phase": .string("stopped")])])])
        check(busy.meetingWorkBlockingRestart && busy.heldAudioNote == nil, "real work beside a held job still blocks, with no note saying otherwise")
        let unanswered = status(["meetingSyncActive": .bool(true), "meetingSyncBlocksRestart": .bool(true), "meetingSyncUnconfirmed": .bool(true)])
        check(unanswered.meetingWorkBlockingRestart && unanswered.meetingWorkBlockReason.contains("not answering") && unanswered.meetingWorkBlockReason.contains("Doctor") && unanswered.meetingWorkBlockReason.contains("Repair server"), "a server that does not answer stays blocked and says why")
        check(!status(["meetingFinalizationLastError": .string("decode failed")]).meetingWorkBlockingRestart, "a last error with nothing pending is not a lock")
        let saving = status(["meetingFinalizationPending": .number(1)])
        check(saving.meetingWorkBlockingRestart && saving.meetingWorkBlockReason.contains("library"), "a real save still blocks")
        check(status(["activeTranscriptionSessions": .number(1)]).meetingWorkBlockReason.contains("recording"), "a recording names itself")
        check(!status([:]).meetingWorkBlockingRestart && status([:]).heldAudioNote == nil, "an old payload with none of this says nothing")
        // A speaker correction refused as finalizing: the truth for a stopped meeting, the old words for one really saving.
        let heldId = "meeting_1789754707558_277naf"
        let stoppedWords = "This meeting's final transcript stopped. Speaker changes wait until it finishes, which COS retries later. Its audio is kept."
        let savingWords = "This meeting is still being saved. Try again in a minute."
        check(heldRow.meetingFinalizingWords(session: heldId) == stoppedWords, "a stopped meeting is told the truth about speaker changes")
        check(heldRow.meetingFinalizingWords(session: "meeting_1789761552246_qfcpyr") == savingWords && heldRow.meetingFinalizingWords(session: nil) == savingWords, "another meeting keeps the saving words")
        let savingRow = status(["meetingSyncMeetings": .array([row(["phase": .string("persisting"), "label": .string("Saving to meeting library")])])])
        check(savingRow.meetingFinalizingWords(session: heldId) == savingWords, "a meeting really saving keeps the saving words")
        check(status([:]).meetingFinalizingWords(session: heldId) == savingWords, "an older server's payload keeps the saving words")
        // The voice check and the one-click batch share a server code with those refusals, so they tell the same truth.
        check(VoiceDisplayCopy.refusal("meeting_finalizing", saveStopped: true) == stoppedWords, "a voice check refused on a stopped meeting says so")
        check(VoiceDisplayCopy.refusal("meeting_finalizing") == savingWords, "a voice check refused on a saving meeting keeps its words")
        check(VoiceDisplayCopy.failure("meeting_finalizing", saveStopped: true) == stoppedWords, "a voice check that stops on a stopped meeting says so")
        check(VoiceDisplayCopy.failure("meeting_finalizing") == "This meeting is being saved, so the voice check stopped. Try again in a minute.", "a voice check that stops on a saving meeting keeps its words")
        check(VoiceDisplayCopy.batchReason("meeting_finalizing", saveStopped: true) + "." == stoppedWords, "a batch refused on a stopped meeting says so")
        check(VoiceDisplayCopy.batchReason("meeting_finalizing") == "This meeting is still being saved", "a batch refused on a saving meeting keeps its words")
        let refusedBatch = JSONValue.object(["state": .string("refused"), "reason": .string("meeting_finalizing")])
        check(VoiceBatchResult(refusedBatch)?.line(saveStopped: true) == "Nothing was named. " + stoppedWords, "a refused batch's own line says so")
        check(VoiceBatchUndoResult(refusedBatch)?.line(saveStopped: true) == "Nothing was undone. " + stoppedWords, "a refused undo's own line says so")
        check(VoiceBatchResult(refusedBatch)?.line == "Nothing was named. This meeting is still being saved.", "a saving meeting's batch line keeps its words")
        for words in [kept.heldAudioNote ?? "", heldRow.heldAudioNote ?? ""] {
            check(!words.lowercased().contains("retry") && !words.lowercased().contains("retrying") && !words.lowercased().contains("delete") && !words.lowercased().contains("discard"), "Control's own words claim no retry and offer no delete")
        }
        print("meeting restart rules: pass")
    }
}
