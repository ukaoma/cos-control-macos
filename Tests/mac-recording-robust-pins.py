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
loop = between(store, "            chunksTask = Task { [weak self] in", "            let engine = makeEngine(")
writer = between(store, "            writerTask = Task.detached(priority: .userInitiated) {", "            chunksTask = Task { [weak self] in")
pin("if await self.hearingCheck(chunk, allMacAudio: source.isAllMacAudio) == .cannotHear {" in loop
    and loop.index("self.takeStored(journal)") < loop.index("hearingCheck(") < loop.index("self.deliverPending()"),
    "hearing check per chunk", "each stored chunk is checked before delivery (0.5.351: the writer stored it; the main actor reads it)")
pin("await MacRecordingWriter.run(stream: stream, spool: spool, captureId: id, progress: progress," in writer, "writer stores", "the detached writer, not the main actor, appends each chunk (0.5.351: through the core loop the checks run)")
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
pin(all(x in fail for x in ("failFast = true", "await stop()", "await discardNoSound(cannotHear: true)"))
    and fail.index("failFast = true") < fail.index("await stop()") < fail.index("await discardNoSound(cannotHear: true)"),
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
pin('if store.canRetrySave {\n                            Button("Retry saving retained audio") { Task { await store.retryNow() } }' in panel
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

# 7. Quick save (0.5.351, Miles 2026-10-26: "We should just show like a quick save."). The rules run in
# Tests/MacRecordingChecks.swift; these pins prove the store and panel use them.
client, core = code("Sources/HelperClient.swift"), code("Sources/MacRecordingCore.swift")
bridge = between(model, "    var macRecordingBridge: MacRecordingStore.Bridge {", "    func runHelper(")
pin('self.runHelper(["mac-recording"], timeout: 90, stdinData: data, answers: true)' in bridge, "bridge answers",
    "a helper refusal reaches invoke with its status and reason, so a passing failure can be told from a real one")
inv = between(store, "    private func invoke(", "    var noticeAcknowledged: Bool {")
marks = ("try await bridge(operation, payload)", 'throw MacRecordingHelperRefusal(message: response.message, httpStatus: response.details["httpStatus"]?.int, reason: response.details["reason"]?.string)')
pin(all(m in inv for m in marks) and [inv.index(m) for m in marks] == sorted(inv.index(m) for m in marks) and "lastFailure" not in store, "failure recorded",
    "a refusal carries its own status and reason in the error it throws; no store state another call can reset (quick-save QA N2)")
pin('case .timedOut: "The COS operation took too long."' in client and '"The COS operation took too long."]' in core, "timeout sentence",
    "the retry rule's timeout sentence is the helper client's own")
call = between(store, "    private func deliveryCall(", "    private func armSlowSave() {")
pin("let refusal = error as? MacRecordingHelperRefusal" in call
    and "MacRecordingSaveRetry.transient(httpStatus: refusal?.httpStatus, reason: refusal?.reason, message: error.localizedDescription)" in call
    and call.index("MacRecordingSaveRetry.transient(") < call.index("await spool.snapshot(id)"), "transient read first",
    "the failure is classified before the next await, so no other call can overwrite it")
pin('guard !Task.isCancelled, phase == "pending", manifest?.captureId == id, attempt < retryDelays.count,' in call
    and "let pause = MacRecordingSaveRetry.pause(delays: retryDelays, attempt: attempt, stopped: stopped, transient: transient," in call
    and "since: quietSince, now: now, window: retryWindow) else { throw error }" in call,
    "retry only after stop", "a quiet try only for the current, stopped, pending capture, bounded by the policy and by a wall-clock window")
pin("if quietSince == nil { quietSince = now }" in call and call.index("if quietSince == nil") < call.index("waitingToRetry = true"), "window starts at the first wait",
    "the window is counted from the first quiet wait of the delivery (quick-save QA W4)")
pin(call.count("try? await Task.sleep(") == 1 and call.index("waitingToRetry = true") < call.index("try? await Task.sleep(")
    and "waitingToRetry = false" not in call
    and 'guard !Task.isCancelled, phase == "pending", manifest?.captureId == id else { throw error }' in call.split("try? await Task.sleep(", 1)[1],
    "retry stops on change", "the wait is marked until the delivery ends (no flicker), and a discard, cancel or phase change after it ends the tries")
pin("deliveryFailureTransient = false\n                return answer" in call, "success clears", "a call that succeeds is never read as a passing failure")
deliver = between(store, "    func deliverPending() {", "    private func deliveryCall(")
pin(deliver.count('self.deliveryCall("chunk", captureId: id,') == 1 and deliver.count('self.deliveryCall("save", captureId: id,') == 1
    and "self.invoke(" not in deliver, "delivery uses the quiet call", "both chunk and save go through the bounded quiet tries")
pin("if manifest?.stopped == true, manifest?.saved == false { armSlowSave() }" in deliver
    and deliver.index("armSlowSave()") < deliver.index("if deliveryTask != nil { deliveryWake = true; return }"), "slow timer armed",
    "every save after Stop, and every Retry, starts the slow-save clock, even when a delivery is already running")
pin('self.error = ["recording", "stopping"].contains(self.phase) && self.deliveryFailureTransient ? nil : "Delivery paused:' in deliver, "quiet while recording",
    "a passing failure while recording or stopping never paints the red line; a real one and any failure after the capture is pending still do (quick-save QA W6)")
pin("self.deliveryFailureTransient = false; self.quietSince = nil" in deliver
    and deliver.index("self.deliveryFailureTransient = false") < deliver.index("defer {") and "self.deliveryWake && (!failed || self.deliveryFailureTransient)" in deliver
    and "self.deliveryTask = nil; self.waitingToRetry = false" in deliver, "delivery starts clean and ends clean",
    "a new delivery starts with no stale passing flag (QA W7); a wake that arrived during a passing failure still runs (QA W6); the wait mark ends with the delivery")
pin("deliveryPaused = false; deliveryFailureTransient = false" in start and "deliveryFailureTransient = false\n        if let id = manifest?.captureId { MacRecordingOpenCaptures" in finish,
    "stale passing flag reset on start and stop", "a passing failure from an earlier recording never speaks for this one (quick-save QA W7)")
pin("self.slowTask?.cancel(); self.slowTask = nil; self.slowSave = false" in deliver and deliver.index("markSaved(id)") < deliver.index("self.slowSave = false"),
    "saved clears slow", "a saved capture is never shown as slow")
pin("MacRecordingDiscard.retryOffered(noSpeech: noSpeech, allZero: manifest?.allDigitalSilence == true, pending: phase == \"pending\",\n                                         hasChunks: manifest?.chunks.isEmpty == false, delivering: deliveryTask != nil, waiting: quietWaitControls)" in store,
    "retry hidden while saving", "Retry saving is never offered while the save runs")
pin("delivering: deliveryTask != nil, paused: deliveryPaused, waiting: waitingToRetry, slow: slowSave," in store, "status inputs",
    "the panel's line reads the store's own delivery, pause, wait and slow state")
pin("let line = store.saveLine" in panel and "Text(line.headline)" in panel and "if let progress = line.progress" in panel
    and "audio chunks received" not in panel and "Text(store.message)" not in panel, "panel reads the line",
    "the panel shows the quick-save line, never the raw counter and phase word")
pin("if line.showsActions, store.phase == \"pending\", !value.chunks.isEmpty {" in panel, "actions gated",
    "the retained-recording line and its buttons only where the line allows")
pin("paused: macRecording.deliveryPaused, slow: macRecording.slowSave)" in model, "row reads slow", "the Meetings row's label knows when the save is slow")

# 8. Reconcile before Recover (0.5.351, mac_b0bd6732) and a grayed-out Recover says why (Miles 2026-10-26).
prep = between(store, "    func prepare(bridge: @escaping Bridge) async {", "    private func invoke(")
pin("let checked = await reconciled(recoverable)" in prep and prep.index('serverDiscard = result["discard"]?.bool == true') < prep.index("reconciled(recoverable)")
    and prep.index("sources = [.allMacAudio]") < prep.index("reconciled(recoverable)") and "if !occupied { recoverable = checked }" in prep,
    "reconcile after the server answered", "retained captures are checked against the server only once capabilities answered and the audio sources are loaded; a Record pressed meanwhile is not undone (quick-save QA W8)")
rec_fn = between(store, "    private func reconciled(", "    func refreshRecoverable() async {")
pin("guard MacRecordingReconcile.shouldAsk(value, current: manifest?.captureId), await savedOnServer(value) else { kept.append(value); continue }" in rec_fn,
    "reconcile keeps by default", "a capture is dropped only when the policy asks and the server verified it saved")
pin("_ = try await spool.markSavedOnServer(value.captureId)" in rec_fn and rec_fn.count("kept.append(value)") == 2, "reconcile marks the journal",
    "a dropped capture is marked saved in its journal; a failed mark keeps the row")
pin('bridge("status", ["captureId": .string(value.captureId), "serverInstanceId": .string(value.serverInstanceId)])' in rec_fn
    and "MacRecordingReconcile.savedOnServer(captureId: value.captureId, serverInstanceId: value.serverInstanceId, chunkCount: value.chunks.count," in rec_fn
    and 'integrity = receipt?["transferIntegrity"]?.object' in rec_fn and "ok: response.ok" in rec_fn, "reconcile reads the receipt",
    "the helper's status op is asked with the capture's own pin and its answer goes through the tested rule")
pin("removeItem" not in rec_fn and "discard" not in rec_fn, "reconcile never removes", "reconcile only marks a journal; audio stays")
pin("MacRecordingRecoveryPolicy.recoverUnavailable(phase: phase, delivering: deliveryTask != nil," in store
    and "currentUnsaved: manifest.map { !$0.saved && !$0.chunks.isEmpty } ?? false,\n                                                      nothingToKeep: noSpeech || manifest?.allDigitalSilence == true)" in store, "recover reason inputs",
    "the reason reads the same state as canStart, and names Discard behind a recording with no sound (quick-save QA W3)")
pin("let stillSaving = deliveryTask != nil && !quietWaitControls" in store and "pendingCapture: pendingCapture, stillSaving: stillSaving)" in store, "record refusal knows the controls",
    "Record names Meetings only where Meetings offers a control (quick-save QA W4)")
pin("delivering: deliveryTask != nil, waiting: quietWaitControls)" in store and "MacRecordingSaveStatus.offersControls(delivering: deliveryTask != nil, waiting: waitingToRetry, slow: slowSave)" in store,
    "quiet wait controls", "Keep and Retry are offered during a slow quiet wait")
canKeep = between(store, "    var canKeepForLater: Bool {", "    func keepSilentAudioForLater() async {")
pin("stopped: manifest?.stopped == true,\n                                                   delivering: deliveryTask != nil, waiting: quietWaitControls)" in canKeep, "keep offered in a quiet wait",
    "Keep audio for later is offered while a slow quiet retry runs (quick-save QA W4)")
keep = between(store, "    func keepSilentAudioForLater() async {", "    func retryNow() async {")
pin("if let delivering = deliveryTask { deliveryWake = false; delivering.cancel(); await delivering.value }" in keep and keep.index("delivering.cancel()") < keep.index("recoverable = retained"),
    "keep ends the delivery first", "Keep audio for later during a quiet wait ends the running delivery before it releases the capture")
retry = between(store, "    func retryNow() async {", "    func deliverPending() {")
pin("guard quietWaitControls else { return }" in retry and "delivering.cancel(); await delivering.value" in retry and "deliverPending()" in retry.split("await delivering.value", 1)[1],
    "retry now", "Retry during a quiet wait ends the wait and tries again at once")
pin("if !retained.isEmpty, !store.canStart, let reason = store.recoverUnavailable {" in panel and panel.count("Text(reason)") == 1, "recover says why",
    "a grayed-out Recover shows its reason once under the buttons")
print(f"mac recording robust pins: {passed} passed")
