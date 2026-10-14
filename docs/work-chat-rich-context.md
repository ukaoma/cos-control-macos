# Work chat rich context candidate

Extends the installed chat without replacing Connections or Agent workspace. A native editor supports bold, italic, headings, lists and linked rich-text paste. Draft formatting is persisted as local RTF; provider messages use Markdown. The 2,000-character request limit rejects whole over-limit edits rather than truncating them.

Drop/paste files on the editor or use the existing Work file controls. Reuse WorkCardFileStore snapshots, thumbnails, readable companions, Remove/Undo and target-specific file delivery. Media is attached to the task, never inserted as a file path into the question. The planner receives metadata and makes no claim to inspect pixels; assigned native agents receive local file paths and readable companions. This does not add a cloud upload or a transcription worker.

Send waits for ready local copies. A digest guards attachment changes between planning and each dispatch. Each saved question lists the attachments observed at submission; receipts retain exact file references. Existing history decodes without RTF fields. Failed/unknown delivery retains the original intent.

Gates: native RTF-to-Markdown and relaunch tests; isolated paste/drop ingestion for image and PDF; provider prompts and receipt references contain each saved file; file-ready and mutation fences; Work regression and offscreen renders; signed/notarized package; actual Control composer paste/drop and persistence. The original 0.5.292/6.73.4 candidate remains frozen. This follow-up is 0.5.293/build346 with the same server 6.73.4; installation waits for its own release gates.

Evidence on the release Mac: Work regression and native formatting/paste serialization passed. Actual Claude and Codex canaries both read the secret from a saved attachment, retained their independent seed-turn continuity, returned results through live Sonnet synthesis, and preserved the shared task stage. The canary uses disposable task metadata and real native sessions; it does not message the IT Retail production sessions. Signing/notarization and the visible composer checks are separate final gates.
