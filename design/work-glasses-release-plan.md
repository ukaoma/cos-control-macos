# Work across Control and Glasses — release plan

27 September 2026. Authorized: extend the existing Work candidate into the EHPK/HUD and phone, then release the COS Control Mac companion. Existing sessions remain destinations; task completion and provider completion remain separate.

## Validation findings and responses

Three independent code reviewers checked HUD navigation, phone/API correctness, and release packaging. Findings: shipping Control hid Work behind a preview flag; standalone task runtime was read-only and not wired into live Work; Mac receipts had no cross-device API; manual-review opt-out was lost during repair; a meeting reader can implicitly ask a model; only stable local signing is configured. Each is a release gate, not a claim of completed work.

- Production Control exposes Work, preserves Tasks links and badge/cursor semantics, and offers `COS_CONTROL_WORK_DISABLED=1` for rollback. Preview fixture isolation remains explicit.
- Phone/HUD negotiate `/api/work-board`; only an unsupported endpoint/capability falls back to legacy Tasks. Network/auth/malformed responses show unavailable or stale information.
- Six phases: Mentioned, Planned, Draft, Built, QA, Complete. Complete is the canonical checkbox, never inferred from an agent result. Domain plus stable work identity joins sources and activity.
- Shared runtime continues to store tasks in `tasks.md`. A bounded, packaged canonical task bridge supports fresh installs and uses the existing bridge when configured. No second task database or migration rewrite.
- Authenticated activity API reads an exact, bounded Mac journal projection. It never returns prompts, drafts, results, or arbitrary file paths; missing history is explicitly unavailable. It does not grant execution authority.
- Work-linked source browsing uses validated canonical meeting identity and existing text readers, without entering the legacy automatic gist path. Session targets are provider-qualified.
- Manual meeting review is available on request with a preserved opt-out. No background preparation or publishing is added by this release.

## Canary and candidate gates

Run disposable fixtures through the actual HTTP → canonical Python writer chain: capture, revision-checked stage change, stale-write refusal, exact source link, completion/reopen, rename identity preservation, and duplicate IDs across domains. Compare legacy parser IDs and old app/new server behavior. Run packaged runtime outside both source checkouts, including empty first install and offline/malformed cases.

Use the existing integrated candidate to test Work in the full Activity shell. Exercise meetings ↔ work ↔ sessions, normal production launch without preview flags, and rollback navigation. Phone/headset use the production navigation and display owner, not a separate mock harness. Verify reader limits, gestures, escape/back, editor preservation, and no provider calls while browsing.

Required automated checks: native full suite and release build/signature self-test; server full suite/typecheck and exact npm inventory; glasses full suite/release typecheck, manufacturer gate, timer quarantine and WebKit gate. Physical EHPK acceptance is a separate evidence row: exact package, lock/background, two-minute idle, navigation and recovery.

## Versions, rollback, promotion

Verified remote baseline: glasses 6.9.555/build555; npm6.55.0; Control0.5.239/build277. Planned versions: glasses6.9.556/build556, server6.56.0, Control0.5.240/build278. Preserve prior signed ZIP and EHPK. Existing pre-board rollback tags remain in native/server/MU.

Freeze tested commits and hashes before publication. Use the stable `COS Control Local` identity already used for distribution; do not claim Apple notarization. Publish the exact verified npm tarball through its browser/passkey gate, then deliver the stable-signed Control ZIP and matching appcast server target. Build the EHPK from app source and stage byte-identical versioned/canonical Hub artifacts. Distinguish staged, uploaded, reviewed and publicly released marketplace state.

Do not promote the appcast if its paired server is unavailable or any required qualification failed. Record remaining hardware or authentication steps explicitly in the release ledger rather than calling them passed.
