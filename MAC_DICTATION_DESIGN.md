# Mac dictation and live meetings

This worktree adds microphone dictation and exposes the existing live meeting workspace for Mac app-audio recordings. It retains COS styling. Glasses are optional.

## Dictation

Settings → Dictate into Mac apps offers a microphone picker, a push-to-talk shortcut and a start/stop shortcut. The feature starts disabled with no shortcut assigned. This first implementation supports a modifier plus a key; Fn-only and double-Fn gestures are not implemented.

0.5.309 (Wispr-style, design/dictation-wispr-mock.html): no window opens. While the shortcut is held, the pet's ledger row becomes a listening pill with a live dBFS waveform and the elapsed time, and hands the row back after. With the pet hidden, the same pill floats at the bottom center of the main display above the Dock, borderless, nonactivating and ignoring clicks. Releasing the hold shortcut or pressing the toggle shortcut again finalizes the clip (TRANSCRIBING). There is no live preview decode.

Capture uses this app's input AudioUnit and never changes the Mac's system input/output device. Microphone permission is requested only after a recording gesture. Sleep, session change and Cancel discard an unfinished dictation. Clips are bounded to two minutes of mono PCM16 at 16 kHz and held in memory.

The helper checks the matched server's capabilities before sending audio over authenticated loopback. It calls the existing one-shot transcription path with `requiredEngine=parakeet-ultra`. The server applies the same COS correction dictionary, vocabulary and hallucination filters. If Parakeet is not selected, warm or available, this mode returns an error rather than substituting Whisper or a cloud provider. No LLM polish is added. Microphone dictation can be used while a Mac or G2 meeting is running. If the local transcription lane is unavailable, the bounded clip stays in memory for Retry transcription until Cancel, app exit or the next dictation. The existing legacy callers keep their prior behavior.

0.5.309: the finished text is always put on the clipboard and left there. It is then inserted into the editable text element focused when transcription finishes, in whatever app is frontmost, so the person may click elsewhere while it transcribes (AX selected text, else ⌘V). DictationInsertPolicy refuses when Accessibility is not granted, secure input is on, the field is a password field, the focus is COS's own pet or dictation panel, or the focus is not a text box. A refusal shows a short-lived card on the pet with Copy and Fix a word (20 s, paused on hover). ⌘V delivery is reported as pasted, not verified insertion. Accessibility permission is requested only from the explicit settings button. COS never presses Return or Send. Late responses are generation-checked and cannot insert after cancellation or into a later attempt.

Recent dictations (the last 50) are kept on this Mac in Application Support/COS Control/dictation-history.json (atomic, 0600) and listed from the pet's DICTATED pill. Dictated text is never logged. Fix a word sends one heard → written correction to the server's single dictionary (server 6.73.11, `POST /api/transcription-glossary/correction`), which live, meeting and dictation transcription share; COS Activity → Meetings → Dictionary shows and edits the whole dictionary, with Undo on recent corrections.

## Mac live meeting

Record on Mac → Open live meeting opens the same live transcript pane used by G2. It reuses Live COS Ask, transcript navigation, Copy full context and the meeting files drop/paste/add controls. Mac attachments use `mac:<captureId>` consistently with saved meetings and Ask, so files follow the recording into the saved view. The live pane can Stop and save the current Mac capture. The menu-bar View live transcript action, Dock recording badge and recording shortcut also recognize a local Mac capture before the server status catches up.

Mac meeting audio remains app playback only, with microphone off. The strict server speaker policy remains in force; the live pane does not offer a control that weakens it. Automatic meeting detection and the pet's suggested Start recording notification are separate work, not implemented here.

## Release separation and acceptance

The accepted 0.5.302 artifact remains immutable. Its native Teams canary captured and saved speech, but stopped early after a buffer failure, so it is not approved for installation. Control 0.5.303/build 356 and server 6.73.7 combine the buffer correction, dictation and live view with the existing onboarding/SubQ work. They require their own release gates. Nothing here is installed yet.

Required acceptance before installation of these additions:

- Strict local Parakeet + dictionary route, unavailable engine, malformed/oversized audio and unmatched-server refusal.
- Native Swift 6 compile, microphone entitlement and usage string checks, bounded audio/focus policy checks.
- Hold and toggle behavior with a real selected microphone, cancellation while starting/finalizing, silence and disconnected microphone.
- Insertion into a native text editor and a browser editor, including after clicking into a different field while transcribing; Finder/desktop focus, secure field and Accessibility denial leave the text on the clipboard with the pet's card.
- Provisional/result readability in light/dark, with the pet visible and hidden, and with a different display active.
- Mac recording → live transcript → COS Ask with a dropped image → Stop and save → same saved meeting and files.
- Full matched release QA, Developer ID signing/notarization and signed permission canary. No public publication is authorized by this document.

`COS_IOS_ASR_CANDIDATES=0` and `COS_LIVE_CUES=0` remain disabled. No pairing, recording history, selected model, external message or production deployment is changed by this worktree.
