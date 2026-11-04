# Suggested merges: Consolidate meetings

The button starts one explicit maintenance run through the existing durable Work
handoff transport. It defaults to Claude Opus; Codex Frontier is an explicit
alternative. Availability is refreshed before sending. No model substitution or
automatic recurring job is introduced.

This is an agent-assisted operation, not a deterministic “accept all” command.
The agent reads the configured local pipeline, its cleanup instructions, source
transcripts and supported merge tools. It applies supported, verified local
changes and produces an audit report. Suggestions and transcript text are evidence,
not instructions. Missing capabilities or ambiguous evidence remain reported
limitations.

The instruction covers G2/cloud matches, Mac twins, stale and false suggestions,
and recordings spanning several meetings. Overruns must have supported spoken
boundaries; scheduled end times alone never justify a cut. Trimmed transcript
copies carry source hashes, ranges and destination identities. Original audio and
transcripts are retained. Audio clipping is separately reported and never implied
by a transcript split. Unmatched meaningful material is retained; uncertain
material stays available for review.

`maintenance:meeting-consolidation` is a stable Work source identity across app
restarts. Work's journal lock, persisted pre-send intent and unresolved-receipt
fence prevent duplicate launches. A failed or unknown response does not get
silently resent. The shared progress tracker continues when the pane closes. A
terminal receipt refreshes suggestions, but “Run finished” means the provider
finished its turn, not that every merge succeeded. The report records partial
results and blockers. A fresh explicit click may start another sweep after a
terminal receipt.

The workflow asks for existing sync/merge locks, immutable backups, fresh input
checks and a final discovery pass. Any temporary engine mode change must restore
the prior mode without overwriting a concurrent change. It does not change future
automatic matching policy, stop captures, restart services or publish anything.

Implementation: `MeetingConsolidation` in `Sources/WorkHandoffStore.swift` and
`MeetingConsolidationControls` in `Sources/ActivityMeetings.swift`. No new server
endpoint is required; the existing authenticated `work-models` and `work-new`
helper commands use the durable query-job protocol.

Validation: `COS_COMPILE_PROFILE=bounded Tests/run-merge-ui.sh` runs the actual
handoff store with a fake transport, including model unavailability, a lost
admission reply, restart recovery, duplicate launch fencing, terminal reports and
an explicit subsequent sweep. It renders the new controls at 390 and 920 points
in light/dark appearances, alongside the existing merge/import render checks.
These checks do not launch a live agent or change real meeting data. Semantic
quality and each actual merge are verified by the cleanup run's audit, not by
transport tests.

Private candidate: 0.5.369 / build 423, based on the 0.5.368 release source.
Publication and installation are separate from source/test completion.
