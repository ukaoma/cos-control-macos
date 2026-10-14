# Work chat typing candidate

Control 0.5.294/build347, compatible with installed server 6.73.4. Local candidate only. No npm/appcast promotion, no server restart, no provider sends, no STT/cue setting changes.

The 0.5.293 editor synchronously encoded, locked and fsynced the whole chat record after each keystroke. Nested @Published draft changes also invalidated the transcript. Receipt refreshes used the sending busy flag, disabling typing throughout status/summary reads.

Draft state now has a separate small ObservableObject consumed only by the editor and Send controls. Saves coalesce after 350ms of idle; Send, navigation, view closure and normal application termination flush immediately through the same private no-follow/CAS writer. Receipt refresh has a separate state: it blocks concurrent dispatch but permits draft edits and preserves those edits when results arrive. Chat history, file intake and delivery routes retain their contracts.

Regression: 1,200 native NSTextView edit callbacks with 50 saved rounds; p95 0.409ms, zero transcript notifications and zero burst disk writes. Idle RTF persistence, immediate-draft availability, navigation recovery, edits during receipt refresh, stale-writer rejection, existing orchestration/attachment delivery checks and offscreen renders passed. This is a callback benchmark, not an end-to-end physical keyboard latency measurement.

Evidence: /Users/ukaoma/cos-release-candidates/work-chat-typing-20261014/work-checks-rerun.log. First compile was intentionally canceled while tightening the tests; its infrastructure-stop receipt is retained separately.

Manual acceptance after installing this candidate: use an existing task with returned results; type/paste 1,000 characters, move the caret and delete while an automatic status refresh occurs. Check the counter and selection, navigate away/back and verify draft formatting. Confirm Send uses the latest final character. Repeat image drop and wait for Ready. A pasted temporary path is text, not a saved attachment.
