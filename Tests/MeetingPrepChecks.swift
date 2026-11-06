import Foundation

/// Pure presentation transitions. No helper, server, UI, provider, filesystem or wall-clock waits.
@main
struct MeetingPrepChecks {
    static func main() {
        typealias State = MeetingPrepState<String>
        typealias Draft = State.Draft
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, "FAIL MeetingPrep: " + name)
            checks += 1
        }

        let ordinary = Draft(text: "Unsent ordinary Ask", attachments: ["ordinary-photo", "ordinary-document"])
        let prep = Draft(text: "Discuss the renewal and the attached agenda", attachments: ["prep-agenda"])
        // Keys are opaque and case-sensitive; no calendar/title matching happens in presentation state.
        let first = "provider:calendar:event/occurrence-A"
        let second = "provider:calendar:event/occurrence-a"
        var state = State()
        check(!state.open(occurrence: "", ordinaryDraft: ordinary), "an absent occurrence cannot open")
        check(state.open(occurrence: first, ordinaryDraft: ordinary), "open occurrence")
        check(state.presentation?.phase == .needsPreparation, "opening never starts a job")
        check(!state.open(occurrence: second, ordinaryDraft: Draft(text: "replacement")), "second opener cannot replace active draft")
        check(state.beginSend() == nil, "no send before preparation")
        check(state.edit(prep), "context and attachments can be staged")
        let read = state.beginPreparation()!
        check(read.occurrence == first && read.draft == prep, "prepare captures exact occurrence and draft")
        check(state.presentation?.phase == .preparing && state.beginPreparation() == nil, "duplicate prepare suppressed")
        check(state.finishPreparation(read), "prepare completes")
        check(state.presentation?.phase == .ready && state.presentation?.draft == prep, "prepare does not send or discard words")
        check(state.cancel() == ordinary, "cancel restores exact ordinary text and ordered attachment values")
        check(state.presentation == nil && state.cancel() == nil, "cancel is idempotent")
        check(!state.finishPreparation(read, draft: Draft(text: "late overwrite")), "read after dismissal ignored")

        check(state.open(occurrence: first, ordinaryDraft: ordinary), "same occurrence reopens")
        check(state.presentation?.draft == prep, "unsent prep draft survives presentation close")
        let oldRead = state.beginPreparation()!
        let edited = Draft(text: "New context while reading", attachments: ["new-agenda", "second-file"])
        check(state.edit(edited), "edit during prepare")
        check(state.presentation?.phase == .needsPreparation, "local edit invalidates read and requires a fresh preparation")
        check(!state.finishPreparation(oldRead, draft: Draft(text: "stale server draft")), "CAS rejects stale draft read")
        check(!state.failPreparation(oldRead, message: "stale error"), "stale read failure ignored")
        check(state.presentation?.draft == edited && state.presentation?.notice == nil, "stale callbacks leave current words and notice unchanged")
        let freshRead = state.beginPreparation()!
        check(freshRead.revision != oldRead.revision, "revision changes with an edit")
        check(state.failPreparation(freshRead, message: "Server unavailable"), "current read failure exposed")
        check(state.presentation?.phase == .needsPreparation && state.presentation?.draft == edited, "read failure keeps context")
        let retryRead = state.beginPreparation()!
        check(state.finishPreparation(retryRead), "explicit read retry succeeds")
        let send = state.beginSend()!
        check(state.presentation?.phase == .sending && send.draft == edited, "explicit send captures exact draft")
        check(state.beginSend() == nil && state.beginPreparation() == nil, "sending suppresses second send and conflicting refresh")
        check(!state.edit(Draft(text: "lost edit")), "in-flight send cannot change its captured context")
        check(!state.finishPreparation(retryRead), "consumed read cannot finish again")
        check(state.finishSend(send, outcome: .uncertain("Response lost")), "ambiguous send kept unresolved")
        check(state.presentation?.phase == .awaitingConfirmation && state.beginSend() == nil, "timeout cannot create another job")
        check(state.unresolvedRequest(for: first) == send, "exact submission snapshot retained for authoritative reconciliation")
        check(!state.finishSend(send, outcome: .accepted(job: "late-job")), "consumed send callback ignored")
        check(state.cancel() == ordinary, "uncertain send dismissal restores ordinary draft")

        check(state.open(occurrence: second, ordinaryDraft: ordinary), "different opaque occurrence opens separately")
        check(state.presentation?.draft == Draft(), "different occurrence does not inherit prior context")
        let otherRead = state.beginPreparation()!
        check(state.finishPreparation(otherRead), "different occurrence prepared")
        check(state.unresolvedRequest(for: first) == send, "opening another event does not discard unresolved send")
        check(state.cancel() == ordinary, "other occurrence restores ordinary draft")
        check(state.open(occurrence: first, ordinaryDraft: ordinary), "uncertain occurrence reopens")
        let resumedRead = state.beginPreparation()!
        check(resumedRead.generation != read.generation, "reopen has a new presentation generation")
        check(!state.finishSend(send, outcome: .accepted(job: "old-generation")), "old generation cannot apply a send result")
        check(!state.finishPreparation(resumedRead, confirmation: .init(requestID: UUID(), outcome: .refused("Wrong request"))), "foreign reconciliation refused")
        check(state.finishPreparation(resumedRead), "fresh read without submission disposition accepted")
        check(state.presentation?.phase == .awaitingConfirmation && state.beginSend() == nil, "plain read cannot clear an unresolved send")
        let reconcile = state.beginPreparation()!
        check(state.finishPreparation(reconcile, confirmation: .init(requestID: send.id, outcome: .accepted(job: "job-1"))), "fresh authoritative confirmation binds existing job")
        check(state.presentation?.phase == .job("job-1") && state.unresolvedRequest(for: first) == nil, "confirmed job replaces uncertainty")
        check(state.beginSend() == nil && state.beginPreparation() == nil, "running job prevents duplicate work")
        let generation = state.presentation!.generation
        check(!state.finishJob("other-job", generation: generation), "foreign job result ignored")
        check(!state.finishJob("job-1", generation: UUID()), "foreign generation result ignored")
        check(state.cancel() == ordinary, "closing running job restores ordinary draft without cancelling job")
        check(!state.finishJob("job-1", generation: generation), "job callback after close ignored")
        check(state.open(occurrence: first, ordinaryDraft: ordinary), "running job presentation reopens")
        let jobRead = state.beginPreparation()!
        check(state.finishPreparation(jobRead) && state.presentation?.phase == .job("job-1"), "reopen remembers existing job")
        check(!state.finishJob("job-1", generation: generation), "old poll cannot finish reopened job")
        check(state.finishJob("job-1", generation: state.presentation!.generation), "current terminal poll permits next conversational turn")
        check(state.edit(Draft(text: "Focus on pricing", attachments: ["pricing-file"])), "next turn is steerable")
        let followup = state.beginSend()!
        check(followup.id != send.id && followup.draft.text == "Focus on pricing", "next explicit send has new identity and new context")
        check(state.finishSend(followup, outcome: .refused("Not accepted")), "definitive refusal permits user correction")
        check(state.presentation?.phase == .ready && state.presentation?.draft == followup.draft, "refusal retains draft")
        let finalSend = state.beginSend()!
        check(state.cancel() == ordinary, "cancel during sending restores ordinary draft")
        check(!state.finishSend(finalSend, outcome: .accepted(job: "late")), "cancelled presentation fences response")
        check(state.open(occurrence: first, ordinaryDraft: ordinary), "reopen after cancellation")
        let cancelledRead = state.beginPreparation()!
        check(state.finishPreparation(cancelledRead) && state.presentation?.phase == .awaitingConfirmation, "cancel during sending retains duplicate-send fence")
        let refusedRead = state.beginPreparation()!
        check(state.finishPreparation(refusedRead, confirmation: .init(requestID: finalSend.id, outcome: .refused("Confirmed not accepted"))), "authoritative not-accepted result releases fence")
        check(state.presentation?.phase == .ready && state.beginSend() != nil, "only explicit send can follow confirmed refusal")

        print("PASS MeetingPrep state: \(checks) draft preservation, occurrence isolation, explicit send, CAS, generation, cancellation, reconciliation and job checks")
    }
}
