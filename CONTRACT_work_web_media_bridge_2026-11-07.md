# Work web media bridge — staged Control contract

This is a Control-side prerequisite for the lane after server 6.99.28 integration. It is not enabled by server 6.99.27 or the existing `webPlans: 1` capability. No installed or published version is implied.

## Wire contract

An inbox round may add `source: "web"` and `attachmentIds: string[]`. IDs are unique, ordered, at most five, exactly `m_` plus 24 lowercase hex characters. Omission is words-only. The exact list is part of server round replay equality and is persisted with both inbox rounds and `sends[].round`.

Control invokes its helper with:

```
work-lens-media --round-id lr_<16 hex> --work-id task:<domain>:<12 hex> --media-id m_<24 hex> --server-id <expected serverInstanceId>
```

The existing inbox GET adds `X-COS-Work-Attachment-Import: 1`. Old servers can ignore this header without changing their query schema. New servers record this import-capable Control heartbeat and **must withhold attachment-bearing rounds and nested send payloads from polls without this header**, including when multiple Control versions poll. Web attachment capability must not rely only on a generic connected heartbeat. Version 1 denotes exactly the limits below.

The helper makes authenticated loopback requests only, rejects redirects, and first reads `GET /api/work/chat/web-plans`. An attachment-enabled server must return HTTP 200 with `protocolVersion: 1`, `serverInstanceId` matching the expected server, and `workAttachments: { protocol: 1 }`. Merely advertising `webPlans: 1` does not enable downloads.

It then reads:

```
GET /api/work/chat/lens-rounds/:roundId/attachments/:mediaId?workID=task:<domain>:<12 hex>
```

Successful binary response must include all of:

```
X-COS-Work-Attachment: 1
X-COS-Server-Instance: <expected serverInstanceId>
X-COS-Work-ID: <exact workID>
X-COS-Round-ID: <exact roundId>
X-COS-Media-ID: <exact mediaId>
Content-Type: <supported MIME>
Content-Length: <actual response byte count>
Cache-Control: private, no-store
```

The endpoint must be token-authenticated and loopback-only. The server checks the round exists, source is web, its work ID is exactly the query value, the media ID belongs to the immutable round attachment list, and media reservation ownership belongs to this round. Missing/expired/foreign/unavailable data must fail explicitly. No generic `/api/media/:id/content` fallback is permitted. Server admission must validate and retain media for the round lifetime; generic staged upload TTL is insufficient. Files cannot be released while unacknowledged rounds need import. The server must not offer attachment-bearing web plans to an old Control that ignores additive IDs: capability negotiation with the connected Control is a separate required server integration step.

## Initial limits

Five files per round, 100 MiB per file; existing local 20-file and 2,000,000,000-byte card limits also apply. MIME support is JPEG, PNG, PDF, UTF-8 plain text/Markdown/CSV/JSON, MP4 and MOV. XLSX and larger chunked videos are deliberately unsupported in this bridge version. The server/web UI must advertise this intersection, not generic media-upload support.

The helper returns only `{state:"ready", path:<private disposable local file>, bytes, mime, serverInstanceId, workID, roundId, mediaId}` after header, length and MIME checks. Paths use the existing private MediaTransfers directory and UUID filenames. Control verifies this ownership before copying or removing a transfer. No tokens, server filesystem paths, data URLs or arbitrary remote URLs enter the round or card manifest.

## Persistence and send boundary

Control imports before attachment snapshot, history persistence or acknowledgement, through both normal inbox and nested send-round fallback. Per-file `(serverID,mediaID)` provenance is atomic with the card manifest entry. Exact-byte duplicates share a verified retained copy. Partial import survives retry/restart; hidden, missing or changed retained copies fail closed. Pending/failed companions leave the round unacknowledged. Existing attachment digest/revision checks still govern later dispatch.

The round records its exact imported media-ID list. Replaying the same round with a different list fails. The existing send path and card confirmation rules are unchanged.

Explicit assignment `contextItemIDs` remain explicit. Only the existing nil-selection behavior includes all context. Import does not automatically add files to each assignment. This bridge guarantees retained card evidence before history/send; it does not give the earlier web planner access to bytes or local file IDs. Pre-plan import and per-assignment selection translation require a later coordinated contract. Do not present this staged lane as full web planning parity.

## Required qualification

Pure round/transfer validation, duplicate/partial/restart import, changed/missing/hidden copies, identity-switch handling, explicit versus nil context selection, old-server rejection, helper transport bounds/proof, and history acknowledgement ordering. No production download, send, installation or release is part of development checks.
