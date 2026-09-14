# COS Control speaker naming wire — 0.5.223 / server 6.46.0

Local build review. No production naming or release action was performed.

| Control command | Server request | Authorization / outcome |
|---|---|---|
| `voice-held-groups` | GET `/api/voice/held-groups` | Read; preserves suggestions and adds `namingAvailable` only from the full capability object |
| `voice-held-preview` | POST `/api/voice/held-groups/enroll` | `{name,members}` only; strips even a caller-supplied `--confirm` |
| `voice-held-enroll` | Same as preview | Legacy helper command alias is read-only |
| `voice-held-apply` | POST `/api/voice/held-groups/enroll` | Requires `--preview-hash` (64 hex) and `--confirm`; forwards owner acknowledgment and listening acknowledgment |
| `voice-held-undo` | POST `/api/voice/held-groups/undo` | Requires batch ID and explicit confirmation; does not use held audio |
| `voice-held-resume` | POST `/api/voice/held-groups/resume` | Requires explicit user action; response is a new preview, never automatic Apply |
| `voice-held-batches` | GET `/api/voice/held-groups/batches` | Persists recovery and Undo affordances across a Control restart |

Every new naming request first verifies GET returns `namingCapabilities: {version:1,preview:true,apply:true,undo:true}`. This matters because an old server has an enroll route which could otherwise interpret a new preview as a write. An old server receives **zero POST requests** in the executable compatibility fixture. Old helper → new server is safe because absence of `previewHash` returns a preview.

Helper responses retain all server JSON fields, including `previewHash`, `expiresAt`, per-member status, `batchId`, `undoHandle`, `meetings`, copy snapshots, write `receipts`, and raw playback triples. Each reply adds `httpStatus` and a `state`; 400, 409, 422 and 503 stay distinct review refusals, preserving their reason and message.

Playback requires all three server fields: `{sessionId,chunkIndex,position}`. `chunkIndex` selects the raw WAV. `position` proves the mapping but is never used as the WAV index. Null mapping suppresses Play. The fixture explicitly uses raw chunk 7 / compacted position 3.

Receipt display separates samples enrolled, transcript segments labelled, and deleted audio. Per-copy results prefer `receipts` over preview `copies`. `no_transcript_position` is a valid enrollment sample with no transcript position. Apply cannot arm for blocked/missing/left-held-only members. A missing capability, bad hash, expired preview, error status, wrong kind, missing owner acknowledgment, or missing required listening acknowledgment also prevents Apply.

## Verification

- Full `Tests/run.sh` baseline passed after helper/controller/model wiring (before UI implementation).
- Helper self-test: 514 deterministic checks.
- `Tests/HeldNamingTransport.py`: actual helper process plus isolated loopback HTTP server and `/tmp` home; no production token or port. Exercises old-server zero-POST, preview stripping confirm, Apply validation, 400/409/422/503 preservation, actual expired-preview / unavailable-model error envelopes, partial per-copy receipts, Undo after 239 audio deletions, and restart history / Resume.
- `Tests/ModelsContract.swift`: 239 unique loose rows, unicode suggestion, raw playback mapping, per-copy receipts, zero eligible samples, owner/listening acknowledgment, stale previews, and durable Undo handle.
- `Tests/HeldNamingGuardMutations.py`: 8 mutations uniquely land in actual model definitions, compile, and fail their expected guard test. Covers owner, listening, expiry, HTTP refusal, hash, eligibility, preview kind, and null playback.

Release appcast and `serverTarget` live in the separate `cos-starter/control/appcast.json`. This repository owns `Resources/Info.plist` (0.5.223, build 261) and its changelog. Signing, appcast publication, installation and server/npm release remain separate actions.
