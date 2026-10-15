# Work follow-up recovery — Control 0.5.297 / build 350

## Report and cause

A delivered native session turn remained a barrier after its answer arrived. Work chat attempted a second assignment, but the local handoff guard rejected it before creating a receipt. Chat kept the new assignment labeled Sending and cleared the composer, leaving the saved request difficult to recover. An empty composer correctly disables Send; receipt refresh also temporarily disables it.

## Resolution

For Work chat only, a preceding delivered native turn can be continued when its exact prompt has a subsequent reply, history is available, and the helper has fresh explicit idle evidence. Read at most 40 recent entries so a long response can include its prompt. Recheck the complete receipt under the journal lock before releasing the guard. The provider attach/queue checks still arbitrate actual delivery. Unknown, active, degraded, app-owned and mismatched turns remain protected.

Link the old receipt to the accepted follow-up in the same journal save. Preserve its answer, review state and the task's stage. This keeps old prompts falling out of the history window from blocking subsequent follow-ups.

Pre-intent refusals become Not sent and remain so after refresh. Use this request again restores the durable question without sending it or overwriting a newer draft. Historical Sending assignments without receipts become No delivery receipt; restoring those requires checking the connected session first. Partial deliveries are never replayed by recovery. Explain temporary receipt refresh beside Send. Observe recovery edits in a small separate view to preserve typing performance.

## Validation

- Native session hub/orchestration canaries: exact-target routing, four consecutive follow-ups, restart, duplicate intent, active/unknown/app-owned/mismatched turns, missing activity evidence, journal changed during the read, refused-request restoration, unconfirmed historical recovery, draft overwrite protection and rich-text persistence.
- Native handoff regression: queue identity, provider ownership, ambiguous delivery, legacy journals, persistence refusal and separate-process journal locking.
- Helper contract self-test: 68 checks, including absent/degraded activity evidence.
- Native typing and offscreen layout: 1,200 chat edits with no history invalidations or burst disk writes; 200 context edits and 1,000 capture edits without workspace/board redraws.
- Read-only production probe: server 6.73.5 supplies explicit idle evidence; the affected native prompt is present in the 40-entry window, absent in the 12-entry window.

No production session messages, request replay, task status changes or manual journal edits are part of this validation. Full desktop typing/recovery and an intentional next user turn remain manual acceptance. Public appcast promotion is separate. Server, companion and transcription/cue settings are unchanged.

## User check after installing

1. Open the affected task and select Refresh updates. The older Sending assignment should become No delivery receipt.
2. Open its exact linked session and check whether the spreadsheet request arrived. If absent, return to Work chat, choose Use this request again, then confirm the check. This fills the composer only.
3. Review the restored text and attachments, then Send once. Expect an actual receipt and an update from the same linked session. Do not resend if the request is already present.
4. After that turn answers and the session is idle, send another short follow-up. It must not require marking the earlier answer reviewed or change the shared task's stage.
