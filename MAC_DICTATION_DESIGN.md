# Mac dictation and live meetings

This worktree adds microphone dictation and exposes the existing live meeting workspace for Mac app-audio recordings. It retains COS styling. Glasses are optional.

## Dictation

Settings → Dictate into Mac apps offers a microphone picker, a push-to-talk shortcut and a start/stop shortcut. The feature starts disabled with no shortcut assigned. This first implementation supports a modifier plus a key; Fn-only and double-Fn gestures are not implemented.

The shortcut opens a nonactivating listening panel beside the visible pet, or near the bottom of the main display when the pet is hidden. It shows microphone level and provisional words. Provisional text is never inserted. Releasing the hold shortcut, pressing the toggle shortcut again, or clicking Stop finalizes the current clip. The final result remains visible with Copy text.

Capture uses this app's input AudioUnit and never changes the Mac's system input/output device. Microphone permission is requested only after a recording gesture. Sleep, session change and Cancel discard an unfinished dictation. Clips are bounded to two minutes of mono PCM16 at 16 kHz and held in memory.

The helper checks the matched server's capabilities before sending audio over authenticated loopback. It calls the existing one-shot transcription path with `requiredEngine=parakeet-ultra`. The server applies the same COS correction dictionary, vocabulary and hallucination filters. If Parakeet is not selected, warm or available, this mode returns an error rather than substituting Whisper or a cloud provider. No LLM polish is added. Microphone dictation can be used while a Mac or G2 meeting is running. If the local transcription lane is unavailable, the bounded clip stays in memory for Retry transcription until Cancel, app exit or the next dictation. The existing legacy callers keep their prior behavior.

COS captures the original app, accessibility element and caret/selection. It inserts only if all still match and secure input is inactive. Unsupported or changed focus keeps the text available to copy. Accessibility permission is requested only from the explicit settings button. Paste-event delivery is described as requested, not verified insertion. COS never presses Return or Send.

A preview decode already running is drained before the final decode to avoid competing with itself for the local model. Late preview/final responses are generation-checked and cannot insert after cancellation or into a later attempt.

## Mac live meeting

Record on Mac → Open live meeting opens the same live transcript pane used by G2. It reuses Live COS Ask, transcript navigation, Copy full context and the meeting files drop/paste/add controls. Mac attachments use `mac:<captureId>` consistently with saved meetings and Ask, so files follow the recording into the saved view. The live pane can Stop and save the current Mac capture. The menu-bar View live transcript action, Dock recording badge and recording shortcut also recognize a local Mac capture before the server status catches up.

Mac meeting audio remains app playback only, with microphone off. The strict server speaker policy remains in force; the live pane does not offer a control that weakens it. Automatic meeting detection and the pet's suggested Start recording notification are separate work, not implemented here.

## Release separation and acceptance

The accepted 0.5.302 artifact remains immutable. Its native Teams canary captured and saved speech, but stopped early after a buffer failure, so it is not approved for installation. Control 0.5.303/build 356 and server 6.73.7 combine the buffer correction, dictation and live view with the existing onboarding/SubQ work. They require their own release gates. Nothing here is installed yet.

Required acceptance before installation of these additions:

- Strict local Parakeet + dictionary route, unavailable engine, malformed/oversized audio and unmatched-server refusal.
- Native Swift 6 compile, microphone entitlement and usage string checks, bounded audio/focus policy checks.
- Hold and toggle behavior with a real selected microphone, cancellation while starting/finalizing, silence and disconnected microphone.
- Insertion into a native text editor and a browser editor; focus/caret change, secure field and Accessibility denial retain text for copy.
- Provisional/result readability in light/dark, with the pet visible and hidden, and with a different display active.
- Mac recording → live transcript → COS Ask with a dropped image → Stop and save → same saved meeting and files.
- Full matched release QA, Developer ID signing/notarization and signed permission canary. No public publication is authorized by this document.

`COS_IOS_ASR_CANDIDATES=0` and `COS_LIVE_CUES=0` remain disabled. No pairing, recording history, selected model, external message or production deployment is changed by this worktree.
