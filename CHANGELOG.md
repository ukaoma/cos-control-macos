# Changelog

## 0.2.5 (build 16)

- Target the verified public `@gotcos/glasses-server` **6.16.1** release, which
  keeps truthful HQ transcription and adds managed Cursor Agent slots
  (Composer 2.5 / Grok 4.5) plus Silero VAD weights in the npm tarball.
- Preserve the existing companion-owned HQ-default/Fast-mode preference; this
  release does not introduce a conflicting Control-side preference.
- Keep public packaging fail-closed: source is releasable independently, but
  the public download must not advance without Developer ID signing,
  notarization, hash verification, and an appcast/site update in that order.

## 0.2.4 (build 15)

- Target server 6.15.5 and require an installed local Whisper runtime to report
  ready before a managed candidate is accepted. Repair Whisper now releases the
  maintenance gate before its final readiness check, so a failed optional audio
  repair never strands the otherwise healthy server offline.
- Show Whisper preflight/loading/failure state instead of a generic unavailable
  label and include the bounded startup error in diagnostics.
- Report the actual maintenance work classes and countdown while draining,
  replacing the indefinite-looking “Draining active work” message.
- Bound candidate verification, provider queries, and Kokoro playback to one
  monotonic operation deadline with explicit proof-phase progress.
- Add boundary coverage for migrated pairing tokens and prove both stale PID
  text and a SIGKILLed lock-holder process cannot block a later helper.
- Gate persistent Whisper readiness on whisper-server/model prerequisites, not
  batch-only whisper-cli, and show the bounded startup error in the main status
  card, Doctor, and Copy Report.
- Public packaging now fails closed without Developer ID signing and
  notarization, then validates the extracted ZIP with codesign, stapler, and
  Gatekeeper. Ad-hoc output requires an explicit local-QA override.

## 0.2.3 (build 14)

- Fix Choose Folder for adopted self-managed LaunchAgents. The selected
  workspace is written to both neutral and legacy provider keys, safely
  reloaded through the maintenance gate, and rolled back if activation fails.
- Apply managed workspace changes immediately through a full plist reload;
  status no longer reports a folder that launchd has not loaded.
- Keep server `WorkingDirectory` and `COS_GLASSES_APP_DIR` on the verified
  server package while Claude, Codex, and Cursor use the selected workspace.
- Tighten rewritten LaunchAgent plists to mode 0600, require exact adopted
  ownership, and preserve pending recovery state. Older adopted servers never
  auto-restart; an explicit, confirmation-gated Restart performs a full
  bootout/bootstrap so launchd actually loads the new environment.
- Preserve custom Cursor paths and target public server 6.15.3.

## 0.2.2 (build 13)

- Require a real, authenticated provider turn before a 6.15.2+ managed
  install, update, restart, repair, or rollback is reported as verified.
- When Kokoro reports ready, prepare speech and fetch the short-lived playback
  URL without an API header, matching the native phone audio path.
- Preserve the managed COS work folder, MCP selectors/config, compatible
  Kokoro Python overrides, and provider binary paths across runtime changes.
- Accept migrated pairing tokens with at least 16 characters and explain the
  generated 64-character format for shorter invalid values.
- Keep lifecycle locking kernel-owned and clear normal-operation PID metadata
  on unlock; a dead helper cannot leave a held lock.
- Target public server 6.15.2.

## 0.2.1 (build 12)

- Preserve discovered Claude, Codex, and Cursor executable directories in the
  canonical managed LaunchAgent PATH, including user-local CLI installs.
- Replace HTTP-200-only update, restart, and in-place gates with provider
  capability verification. A missing provider bridge now fails the candidate
  switch and restores the previous runtime instead of reporting false-green.
- Target `@gotcos/glasses-server` 6.15.1 for the Kokoro Python compatibility
  fix.

## 0.2.0 (build 11)

- Add the check-only in-app update banner and signed appcast parser.
