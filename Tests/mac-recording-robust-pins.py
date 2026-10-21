#!/usr/bin/env python3
"""0.5.334 (Miles 2026-10-21 13:15, "clean up the Record on Mac pilot"): where the hearing check, the fail-fast and
Discard are wired. The rules themselves run in Tests/MacRecordingChecks.swift; these pins prove the store, the panel,
Meetings and the helper call them. Comments are stripped, so an explanatory comment can never satisfy a pin. Each
failure names its behaviour as "FAILED: [<behaviour>]" for Tests/mutate-mac-recording-robust.py.

    python3 Tests/mac-recording-robust-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
def code(rel):
    return "\n".join(l for l in (root / rel).read_text(encoding="utf-8").splitlines() if not l.lstrip().startswith("//"))
store_src, capture, model, meetings, app, helper = (code(p) for p in (
    "Sources/MacRecording.swift", "Sources/MacAudioCapture.swift", "Sources/ControllerModel.swift",
    "Sources/ActivityMeetings.swift", "Sources/COSControlApp.swift", "HelperSources/main.swift"))
passed = 0
def pin(ok, behaviour, why):
    global passed
    if not ok:
        sys.exit(f"FAILED: [{behaviour}] {why}")
    passed += 1
def between(text, start, end):
    pin(start in text and end in text.split(start, 1)[1], "source shape", f"cannot find {start!r} .. {end!r}")
    return text.split(start, 1)[1].split(end, 1)[0]

store = store_src.split("struct MacRecordingPanel: View {")[0]
panel = between(store_src, "struct MacRecordingPanel: View {", "struct MacRecordingNoticeCard: View {")

# 1. The capture reads raw input before resampling, flags each chunk, and probes once.
drain = between(capture, "    private func drain() throws {", "    private func emitPartial() {")
pin("MacRecordingSignal.hasRawSignal(UnsafeBufferPointer(start: data, count: raw.count / 4))" in drain
    and drain.index("hasRawSignal") < drain.index("converter.convert("), "raw scan before resampling",
    "the zero test reads the float input, before a quiet sample can round to an Int16 zero")
pin("rawSignal: signal))" in drain and "let signal = rawSignalSinceChunk; rawSignalSinceChunk = false" in drain, "chunk carries raw flag",
    "every emitted chunk carries whether its raw input had signal, and the flag resets per chunk")
pin("rawSignal: signal))" in between(capture, "    private func emitPartial() {", "    private func tearDown() {"), "chunk carries raw flag",
    "the partial tail carries the flag too")
pin("if !probed, Double(rawFrames) >= format.sampleRate * MacRecordingHearing.probeSeconds {" in drain and "probed = true; probe?(rawSignalEver)" in drain,
    "probe once after a second", "the probe runs once, after the tap's first second, and never blocks")

# 2. The store: every stored chunk goes through the hearing check BEFORE it is delivered; the fail-fast stops and discards.
loop = between(store, "            chunksTask = Task { [weak self] in", "            let engine = MacAudioCapture(")
pin("if await self.hearingCheck(chunk, allMacAudio: source.isAllMacAudio) == .cannotHear {" in loop
    and loop.index("self.spool.append(chunk") < loop.index("hearingCheck(") < loop.index("self.deliverPending()"),
    "hearing check per chunk", "each stored chunk is checked before delivery")
pin(re.search(r"== \.cannotHear \{\s*Task \{ await self\.stopCannotHear\(id\) \}; break\s*\}", loop) is not None, "fail-fast stops",
    "cannot hear stops this capture and stops consuming chunks")
pin("probe: { [weak self] sawSignal in" in store and "await self?.hearingProbe(sawSignal, captureId: id, allMacAudio: source.isAllMacAudio)" in store,
    "probe wired", "the engine's probe reaches the store's warning")
check = between(store, "    private func hearingCheck(", "    private func hearingProbe(")
pin("MacRecordingHearing.step(&next, digitalSilence: silence, othersPlaying: playing, allMacAudio: allMacAudio)" in check
    and "let silence = chunk.digitalSilence" in check, "hearing rule", "the store uses the tested rule on the chunk's own digital-silence flag")
pin("MacAudioCapture.othersPlaying()" in check and "if silence, allMacAudio, !hearing.heardSignal {" in check, "playing read only when it matters",
    "the process list is read only for an exact-zero chunk of All Mac audio before any sound")
fail = between(store, "    private func stopCannotHear(", "    func tryAgainAfterCannotHear(")
pin("failFast = true" in fail and fail.index("failFast = true") < fail.index("await stop()") < fail.index("await discardNoSound(cannotHear: true)"),
    "fail-fast keeps nothing pending", "it marks the stop, stops, then discards (outside the stop gate)")
pin("captureInterruption = MacRecordingHearing.cannotHearMessage" in fail, "fail-fast notifies", "the stop nobody made says it cannot hear")
finish = between(store, "    private func finishStop() async {", "    private func hearingCheck(")
pin("if !failFast { deliverPending() }" in finish and "\n        deliverPending()\n" not in finish, "zeros never delivered",
    "a fail-fast stop never starts a save of the zeros")
start = between(store, "    private func start() async {", "    private func installStopObservers() {")
pin("hearing = MacRecordingHearing.State(); cannotHear = false; failFast = false" in start, "fresh start resets", "Try again starts clean")
again = between(store, "    func tryAgainAfterCannotHear(", "    private var discarder: MacRecordingDiscarder {")
pin("record(title: again, sourceID: MacAudioSource.allMacAudioID, bridge: bridge)" in again, "try again records",
    "Try again is a fresh All Mac audio capture through the one record path")
pin('serverDiscard = result["discard"]?.bool == true' in store, "capability read", "the server's discard capability is read at prepare")

# 3. Discard: moves, asks, never removes; delivery cannot restart under it.
disc = between(store, "    func discardNoSound(", "    func discardStranded(")
pin('phase = "discarding"' in disc and disc.index('phase = "discarding"') < disc.index("await"), "discard occupies first",
    "Discard is occupied before its first await, so Record and delivery cannot start in the gap")
pin("if let delivering = deliveryTask { delivering.cancel(); await delivering.value }" in disc, "discard waits for delivery",
    "an in-flight delivery finishes before the folder moves")
pin("serverSupported: serverDiscard)" in disc and "noMeetingCaptureIDs.insert(value.captureId)" in disc, "discard asks and ends the hand-off",
    "the server is asked only when it advertises discard, and the capture never looks for a meeting again")
pin('if failFastStop { cannotHear = true }' in disc and 'phase = "idle"' in disc and "manifest = nil" in disc, "nothing pending after discard",
    "the composer is free and the fail-fast message shows")
pin("retryServerDiscard(" in disc and "outcome.server == .notIdle" in disc, "server asked again", "a not-yet-idle server is asked again past its window")
pin("removeItem" not in store and "unlink" not in store and "rmSync" not in store, "never removes", "the store never deletes audio")
deliver = between(store, "    func deliverPending() {", "protocol MacCaptureSession")
pin(deliver.lstrip().startswith('guard phase != "discarding" else { return }'), "no delivery while discarding", "delivery never restarts during a discard")
pin("if self.noSpeech { self.noMeetingCaptureIDs.insert(id); self.error = nil }" in deliver, "no speech is not a red dead end",
    "no speech clears the 'Delivery paused ... Choose the app' line and ends the hand-off")

# 4. The panel: one message with two buttons; Discard with confirm; Retry and Keep only where they can work.
pin("if store.cannotHear && !store.occupied {" in panel and "Text(MacRecordingHearing.cannotHearMessage)" in panel, "the message", "the fail-fast's one message")
pin("Button(MacRecordingHearing.openSettingsTitle) { Task { await store.openSystemAudioSettings?() } }" in panel, "open settings",
    "Open System Settings goes to the System Audio Recording pane")
pin("Button(MacRecordingHearing.tryAgainTitle) { Task { _ = await store.tryAgainAfterCannotHear(bridge: bridge) } }" in panel, "try again button", "Try again starts a fresh capture")
pin("if store.canDiscard {\n                            Button(MacRecordingDiscard.buttonTitle) { confirmDiscard = true }" in panel, "discard confirms",
    "Discard opens the inline confirm, never discards on the first click")
pin(".destructive(MacRecordingDiscard.confirmButton) { confirmDiscard = false; Task { await store.discardNoSound() } }" in panel, "discard confirms",
    "only the confirm's Discard discards")
pin('if store.canRetrySave {\n                            Button("Retry saving retained audio") { store.deliverPending() }' in panel
    and panel.count("Retry saving retained audio") == 1, "retry gated", "Retry saving only where a retry can work")
pin('if store.canKeepForLater {\n                            Button("Keep audio for later")' in panel and "Keep audio and record again" not in panel, "keep gated",
    "Keep audio for later only where it can help")
pin("var canDiscard: Bool {" in store and "MacRecordingDiscard.offered(noSpeech: noSpeech, allZero: manifest?.allDigitalSilence == true" in store,
    "discard policy", "the panel's Discard follows the tested policy")
pin("MacRecordingDiscard.retryOffered(noSpeech: noSpeech, allZero: manifest?.allDigitalSilence == true" in store, "retry policy", "Retry follows the tested policy")

# 5. Meetings: the stranded Save that could never work, and "Saved meeting not found yet".
banner = between(meetings, "    private var unsavedCaptureBanner: some View {", "    private var toolbar: some View {")
pin("if MacRecordingDiscard.strandedOffersDiscard(sessionId: capture.sessionId, transcriptState: capture.transcriptState, canSave: capture.canSave) {" in banner
    and "Button(MacRecordingDiscard.buttonTitle) { discardStrandedTarget = capture.sessionId }" in banner, "stranded discard",
    "a no-speech Mac row offers Discard (with confirm) instead of Save")
actions = between(meetings, "    private var discardStrandedActions: [COSConfirmAction] {", "\n    }\n")
pin("let pending = discardStrandedTarget" in actions and actions.index("let pending = discardStrandedTarget") < actions.index(".destructive(")
    and "guard let pending else { return }" in actions and "model.discardStrandedMac(pending)" in actions
    and "discardStrandedTarget" not in actions.split(".destructive(", 1)[1] and "actions: discardStrandedActions)" in banner,
    "stranded discard confirms", "only the confirm discards, with the id captured before cosConfirm's dismissal clears it")
pin("MacRecordingNoMeeting.endsHandoff(sessionId: feed.sessionId, noMeeting: model.macRecording.noMeetingCaptureIDs)" in meetings
    and "Text(MacRecordingNoMeeting.line)" in meetings, "no meeting to find", "the live pane says there is no meeting instead of looking for one")
rows = between(model, "    var liveTranscriptRows: [LiveTranscriptRow] {", "    var openLiveTranscriptFeed:")
pin(".filter { !MacRecordingNoMeeting.endsHandoff(sessionId: $0.sessionId, noMeeting: noMeeting) }" in rows, "no row", "a no-sound capture pins no Live now row")
hand = between(model, "    func checkLiveTranscriptHandoffs(now: Date) async {", "    private func liveTranscriptServerState(")
pin("if found == nil, MacRecordingNoMeeting.endsHandoff(sessionId: id, noMeeting: macRecording.noMeetingCaptureIDs) { feed.phase = .ended }" in hand
    and hand.index("LiveTranscript.handoff(") < hand.index("MacRecordingNoMeeting.endsHandoff("), "hand-off ends", "never Saved meeting not found yet for a no-sound capture")
strand = between(model, "    func discardStrandedMac(_ sessionId: String) {", "    func saveStranded(_ sessionId: String) {")
pin("self.macRecording.discardStranded(sessionId, bridge: self.macRecordingBridge)" in strand and "await self.loadOrphans(quiet: true)" in strand,
    "stranded discard wired", "Meetings' Discard runs the store's discard with the transport, then re-reads the stranded list")
pin("macRecording.discarded = { [weak self] _ in guard let self else { return }; Task { await self.loadOrphans(quiet: true) } }" in model, "discard refreshes", "every discard re-reads the stranded list")
pin('model.macRecording.openSystemAudioSettings = { [weak model] in _ = await model?.requestSystemAudio(for: "All Mac audio", wantsPane: true) }' in app,
    "settings wired", "Open System Settings shows the pane even when the preflight says allowed")

# 6. The helper: discard only with a boolean confirm, on the server's route.
mac = between(helper, "    private func emitMacRecording() throws {", "    static func macRecordingAudio(")
case = between(mac, '        case "discard":', '        default: emit(ok: false, message: "Mac recording operation is unsupported."); return')
pin('guard payload["confirm"] as? Bool == true, (payload["confirm"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true else {' in case,
    "helper confirm", "the helper sends a discard only with confirm: true, a real boolean")
pin('path = "/api/meeting/sessions/" + capture + "/discard"; method = "POST"' in case and '["confirm": true, "serverInstanceId": instance]' in case,
    "helper route", "the discard goes to the server's route with confirm and the pin")
print(f"mac recording robust pins: {passed} passed")
