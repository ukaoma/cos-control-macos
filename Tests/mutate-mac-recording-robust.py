#!/usr/bin/env python3
"""0.5.334: mutation gate for the Record on Mac hearing check, fail-fast and Discard (Miles 2026-10-21 13:15).

Runs the unmutated lanes first and refuses on any failure (a red baseline would "kill" every mutant). Then each mutant
must match its target EXACTLY ONCE, and is killed only when its lane fails with a NAMED check ("Precondition failed: <name>"
from Tests/MacRecordingChecks.swift, "FAILED: [<behaviour>]" from the pins, or "AssertionError: <label>" from the helper
checks); a compile failure is an infrastructure error, not a kill. Every lane compiles through Tests/compile-guard.sh,
one at a time, and the core lane is MacRecordingCore.swift alone (never a full COS Control compile).
Usage: python3 Tests/mutate-mac-recording-robust.py [--list] [name-prefix...]
"""
import os, re, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORE, STORE, CAP, MODEL, MEET, APP, HELPER = ("Sources/MacRecordingCore.swift", "Sources/MacRecording.swift", "Sources/MacAudioCapture.swift",
    "Sources/ControllerModel.swift", "Sources/ActivityMeetings.swift", "Sources/COSControlApp.swift", "HelperSources/main.swift")

MUTANTS = [
    # The rules (core lane: Tests/MacRecordingChecks.swift runs them).
    ("H1 a quiet sample below one Int16 step reads as zero", "core", CORE, "for sample in samples where sample != 0 { return true }", "for sample in samples where abs(sample) >= 1.0 / 32768 { return true }"),
    ("H2 digital silence ignores the raw flag", "core", CORE, "var digitalSilence: Bool { !rawSignal && MacRecordingSignal.isDigitalZero(pcm) }", "var digitalSilence: Bool { MacRecordingSignal.isDigitalZero(pcm) }"),
    ("H3 any sound does not end the fail-fast", "core", CORE, "guard allMacAudio, !state.heardSignal, othersPlaying != false else { return .keep }", "guard allMacAudio, othersPlaying != false else { return .keep }"),
    ("H4 the fail-fast ignores whether anything plays", "core", CORE, "guard allMacAudio, !state.heardSignal, othersPlaying != false else { return .keep }", "guard allMacAudio, !state.heardSignal else { return .keep }"),
    ("H5 the fail-fast fires for a per-app source", "core", CORE, "guard allMacAudio, !state.heardSignal, othersPlaying != false else { return .keep }", "guard !state.heardSignal, othersPlaying != false else { return .keep }"),
    ("H6 one zero chunk is enough", "core", CORE, "    static let failFastChunks = 2\n", "    static let failFastChunks = 1\n"),
    ("H7 sound does not mark heard", "core", CORE, "guard digitalSilence else { state.heardSignal = true; state.suspect = false; state.zeroChunksWhilePlaying = 0; return .keep }", "guard digitalSilence else { state.suspect = false; state.zeroChunksWhilePlaying = 0; return .keep }"),
    ("H8 the probe warns with nothing playing", "core", CORE, "state.suspect = allMacAudio && !state.heardSignal && othersPlaying != false", "state.suspect = allMacAudio && !state.heardSignal"),
    ("H9 the probe warning outlives the recording", "core", CORE, "recording && state.suspect && !state.heardSignal ? suspectLine : nil", "state.suspect && !state.heardSignal ? suspectLine : nil"),
    ("H10 the no-sound stop reads as an incomplete recording", "core", CORE, "        if reason == MacRecordingHearing.cannotHearMessage { return (\"Mac recording stopped\", MacRecordingHearing.notificationBody) }\n", ""),
    ("D1 Keep is offered for no speech", "core", CORE, "(paused && !delivering || waiting) && !noSpeech && pending && stopped", "(paused && !delivering || waiting || noSpeech) && pending && stopped"),
    ("D2 Discard offered while delivering", "core", CORE, "(noSpeech || allZero) && pending && stopped && !delivering", "(noSpeech || allZero) && pending && stopped"),
    ("D3 Discard not offered for local zeros", "core", CORE, "(noSpeech || allZero) && pending && stopped && !delivering", "noSpeech && pending && stopped && !delivering"),
    ("D4 Retry offered for no speech", "core", CORE, "pending && hasChunks && !noSpeech && !allZero", "pending && hasChunks && !allZero"),
    ("D5 a stranded row still transcribing offers Discard", "core", CORE, "sessionId.hasPrefix(\"mac_\") && !canSave && transcriptState == \"no_speech\"", "sessionId.hasPrefix(\"mac_\") && !canSave"),
    ("D6 an older server reads as discarded", "core", CORE, "case nil: return httpStatus == 404 ? .unsupported : .unreachable", "case nil: return httpStatus == 404 ? .absent : .unreachable"),
    ("D7 an older server's note hides that its copy stays", "core", CORE, "        case .unsupported: return local + \" This COS server is older and keeps its copy until its own clean-up; update the server to clear it now.\"\n", "        case .unsupported: return local\n"),
    ("D8 a pre-0.5.334 journal reads as silent", "core", CORE, "next.heardSignal = (value.chunks.isEmpty ? false : (value.heardSignal ?? true)) || !chunk.digitalSilence", "next.heardSignal = (value.chunks.isEmpty ? false : (value.heardSignal ?? false)) || !chunk.digitalSilence"),
    ("D9 one silent chunk after sound forgets the sound", "core", CORE, "next.heardSignal = (value.chunks.isEmpty ? false : (value.heardSignal ?? true)) || !chunk.digitalSilence", "next.heardSignal = !chunk.digitalSilence"),
    ("D10 a second discard of the same name overwrites", "core", CORE, "        if fstatat(target, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 { name = id + \".\" + String(Int(date.timeIntervalSince1970)) }\n", ""),
    ("D11 the server is asked though the local move failed", "core", CORE, "catch { return Outcome(captureId: captureId, moved: nil, localError: error.localizedDescription, server: .unreachable) }", "catch { _ = await server(captureId, serverInstanceId); return Outcome(captureId: captureId, moved: nil, localError: error.localizedDescription, server: .unreachable) }"),
    ("D12 an older server is asked anyway", "core", CORE, "let answer = serverSupported ? await server(captureId, serverInstanceId) : .unsupported", "let answer = await server(captureId, serverInstanceId)"),
    ("D13 a Glasses session ends its hand-off", "core", CORE, "sessionId.hasPrefix(\"mac_\") && noMeeting.contains(sessionId)", "noMeeting.contains(sessionId)"),
    ("D14 the discarded folder is not owner only", "core", CORE, "let target = try directoryFD(day, create: true); defer { Darwin.close(target) }", "try? FileManager.default.createDirectory(at: day, withIntermediateDirectories: true); let target = Darwin.open(day.path, O_RDONLY | O_DIRECTORY); defer { Darwin.close(target) }"),
    # The wiring (pins lane).
    ("W1 the zero test reads the resampled Int16", "pins", CAP, "            if !rawSignalSinceChunk, MacRecordingSignal.hasRawSignal(UnsafeBufferPointer(start: data, count: raw.count / 4)) {\n                rawSignalSinceChunk = true; rawSignalEver = true\n            }\n", ""),
    ("W2 the chunk flag never resets", "pins", CAP, "                let signal = rawSignalSinceChunk; rawSignalSinceChunk = false\n", "                let signal = rawSignalSinceChunk\n"),
    ("W3 the store delivers before checking", "pins", STORE, "                    if await self.hearingCheck(chunk, allMacAudio: source.isAllMacAudio) == .cannotHear {\n                        Task { await self.stopCannotHear(id) }; break\n                    }\n                    self.deliverPending()", "                    self.deliverPending()\n                    if await self.hearingCheck(chunk, allMacAudio: source.isAllMacAudio) == .cannotHear {\n                        Task { await self.stopCannotHear(id) }; break\n                    }"),
    ("W4 the fail-fast keeps recording", "pins", STORE, "                        Task { await self.stopCannotHear(id) }; break\n", "                        recordingLog.error(\"cannot hear\")\n"),
    ("W5 the zeros are delivered for saving", "pins", STORE, "        if !failFast { deliverPending() }\n", "        deliverPending()\n"),
    ("W6 the fail-fast leaves the capture pending", "pins", STORE, "        await stop()\n        await discardNoSound(cannotHear: true)\n", "        await stop()\n"),
    ("W7 the panel discards without a confirm", "pins", STORE, "Button(MacRecordingDiscard.buttonTitle) { confirmDiscard = true }", "Button(MacRecordingDiscard.buttonTitle) { Task { await store.discardNoSound() } }"),
    ("W8 Retry saving is back for no speech", "pins", STORE, "                        if store.canRetrySave {\n                            Button(\"Retry saving retained audio\") { store.deliverPending() }\n                        }", "                        Button(\"Retry saving retained audio\") { store.deliverPending() }"),
    ("W9 delivery restarts during a discard", "pins", STORE, "        guard phase != \"discarding\" else { return }\n", ""),
    ("W10 no speech keeps the red dead-end line", "pins", STORE, "                if self.noSpeech { self.noMeetingCaptureIDs.insert(id); self.error = nil }\n                else { self.error =", "                do { self.error ="),
    ("W11 the stranded row keeps a Save that cannot work", "pins", MEET, "                    if MacRecordingDiscard.strandedOffersDiscard(sessionId: capture.sessionId, transcriptState: capture.transcriptState, canSave: capture.canSave) {", "                    if false {"),
    ("W12 the hand-off still looks for a meeting", "pins", MODEL, "            if found == nil, MacRecordingNoMeeting.endsHandoff(sessionId: id, noMeeting: macRecording.noMeetingCaptureIDs) { feed.phase = .ended }\n", ""),
    ("W13 a no-sound capture pins a Live now row", "pins", MODEL, ".filter { !MacRecordingNoMeeting.endsHandoff(sessionId: $0.sessionId, noMeeting: noMeeting) }", ""),
    ("W14 Open System Settings asks without the pane", "pins", APP, "await model?.requestSystemAudio(for: \"All Mac audio\", wantsPane: true) }", "await model?.requestSystemAudio(for: \"All Mac audio\") }"),
    ("W15 the server capability is never read", "pins", STORE, "                    serverDiscard = result[\"discard\"]?.bool == true\n", ""),
    # 0.5.351 quick save: the rules (core lane).
    ("Q1 Retry offered while the save runs", "core", CORE, "pending && hasChunks && !noSpeech && !allZero && (!delivering || waiting)", "pending && hasChunks && !noSpeech && !allZero"),
    ("Q2 an ordinary save shows the counter", "core", CORE, "return Line(headline: saving, detail: detail, progress: nil, tone: .quiet, showsActions: offersControls(delivering: delivering, waiting: waiting, slow: slow))", "return Line(headline: saving, detail: detail, progress: reached(acknowledged, of: chunks), tone: .quiet, showsActions: offersControls(delivering: delivering, waiting: waiting, slow: slow))"),
    ("Q3 an ordinary save shows the buttons", "core", CORE, "return Line(headline: saving, detail: detail, progress: nil, tone: .quiet, showsActions: offersControls(delivering: delivering, waiting: waiting, slow: slow))", "return Line(headline: saving, detail: detail, progress: nil, tone: .quiet, showsActions: true)"),
    ("Q4 the slow line shows from the first second", "core", CORE, "let detail: String? = !slow ? nil : waiting ? notAnswering : stillSaving(acknowledged, of: chunks)", "let detail: String? = waiting ? notAnswering : stillSaving(acknowledged, of: chunks)"),
    ("Q5 Saved keeps the 345/345 counter", "core", CORE, "return Line(headline: saved, detail: savedDetail, progress: nil, tone: .done, showsActions: false)", "return Line(headline: saved, detail: savedDetail, progress: reached(acknowledged, of: chunks), tone: .done, showsActions: false)"),
    ("Q6 a real failure reads as quiet", "core", CORE, "tone: paused ? .problem : .quiet, showsActions: true)", "tone: .quiet, showsActions: true)"),
    ("Q7 recording always shows the counter", "core", CORE, "progress: behind ? sending(acknowledged, of: chunks) : nil, tone: .quiet, showsActions: false)", "progress: sending(acknowledged, of: chunks), tone: .quiet, showsActions: false)"),
    ("Q8 one chunk behind counts as behind", "core", CORE, "    static let behindChunks = 3\n", "    static let behindChunks = 1\n"),
    ("Q9 a 409 refusal is retried", "core", CORE, "if let httpStatus, [502, 503, 504].contains(httpStatus) { return true }", "if let httpStatus, [409, 502, 503, 504].contains(httpStatus) { return true }"),
    ("Q10 a refusal with a passing sentence is retried", "core", CORE, "return reason == nil && httpStatus == nil && transientMessages.contains(message)", "return transientMessages.contains(message)"),
    ("Q11 an exhausted budget is retried", "core", CORE, "        if reason == \"openai_whisper_budget_exhausted\" { return false }\n", ""),
    ("Q12 quiet tries while recording", "core", CORE, "guard stopped, transient, attempt >= 0, attempt < delays.count else { return nil }", "guard transient, attempt >= 0, attempt < delays.count else { return nil }"),
    ("Q13 more than a minute of quiet tries", "core", CORE, "static let delays: [Double] = [1, 2, 4, 8, 15, 30]", "static let delays: [Double] = [1, 2, 4, 8, 15, 30, 60]"),
    ("Q14 the Meetings row shows the counter through a save", "core", CORE, "return slow ? \"Saving · \\(acknowledged) of \\(chunks) audio chunks sent\" : MacRecordingSaveStatus.saving", "return \"Saving · \\(acknowledged) of \\(chunks) audio chunks sent\""),
    ("Q15 a passing failure is not passing", "core", CORE, "static let transientMessages: Set<String> = [\"Server stopped\", \"The COS operation took too long.\"]", "static let transientMessages: Set<String> = [\"The COS operation took too long.\"]"),
    # 0.5.351 quick save: the wiring (pins lane).
    ("P1 the bridge drops the refusal's details", "pins", MODEL, "self.runHelper([\"mac-recording\"], timeout: 90, stdinData: data, answers: true)", "self.runHelper([\"mac-recording\"], timeout: 90, stdinData: data)"),
    ("P2 chunks skip the quiet tries", "pins", STORE, "self.deliveryCall(\"chunk\", captureId: id, ", "self.invoke(\"chunk\", "),
    ("P3 quiet tries before the capture is pending", "pins", STORE, "guard !Task.isCancelled, phase == \"pending\", manifest?.captureId == id, attempt < retryDelays.count,", "guard !Task.isCancelled, manifest?.captureId == id, attempt < retryDelays.count,"),
    ("P4 a discard during the wait is ignored", "pins", STORE, "                guard !Task.isCancelled, phase == \"pending\", manifest?.captureId == id else { throw error }\n", ""),
    ("P5 the panel shows the raw counter again", "pins", STORE, "if let progress = line.progress { Text(progress).font(COSType.body(11)).foregroundStyle(.secondary) }", "Text(\"\\(store.manifest?.acknowledged ?? 0)/\\(store.manifest?.chunks.count ?? 0) audio chunks received · \\(store.phase)\").font(COSType.body(11)).foregroundStyle(.secondary)"),
    ("P6 Retry ignores a running save", "pins", STORE, "hasChunks: manifest?.chunks.isEmpty == false, delivering: deliveryTask != nil, waiting: quietWaitControls)", "hasChunks: manifest?.chunks.isEmpty == false, delivering: false, waiting: quietWaitControls)"),
    ("P7 the slow clock never starts", "pins", STORE, "        if manifest?.stopped == true, manifest?.saved == false { armSlowSave() }\n", ""),
    ("P8 a passing failure paints the red line while recording", "pins", STORE, "self.error = [\"recording\", \"stopping\"].contains(self.phase) && self.deliveryFailureTransient ? nil : \"Delivery paused:", "self.error = \"Delivery paused:"),
    ("P9 the buttons show through a save", "pins", STORE, "if line.showsActions, store.phase == \"pending\", !value.chunks.isEmpty {", "if store.phase == \"pending\", !value.chunks.isEmpty {"),
    ("P10 a refusal's status and reason are not kept", "pins", STORE, "            throw MacRecordingHelperRefusal(message: response.message, httpStatus: response.details[\"httpStatus\"]?.int, reason: response.details[\"reason\"]?.string)", "            throw MacRecordingError.unavailable(response.message)"),
    ("P11 a success leaves the passing flag set", "pins", STORE, "                deliveryFailureTransient = false\n", ""),
    ("P12 the Meetings row never hears the save is slow", "pins", MODEL, "paused: macRecording.deliveryPaused, slow: macRecording.slowSave)", "paused: macRecording.deliveryPaused)"),
    ("P13 Saved stays slow", "pins", STORE, "                        self.slowTask?.cancel(); self.slowTask = nil; self.slowSave = false\n", ""),
    # 0.5.351 reconcile and the Recover reason: rules (core lane).
    ("R1 reconcile hides audio only this Mac holds", "core", CORE, "!value.saved && !value.chunks.isEmpty && value.acknowledged == value.chunks.count && value.captureId != current", "!value.saved && !value.chunks.isEmpty && value.captureId != current"),
    ("R2 reconcile hides the current capture", "core", CORE, "!value.saved && !value.chunks.isEmpty && value.acknowledged == value.chunks.count && value.captureId != current", "!value.saved && !value.chunks.isEmpty && value.acknowledged == value.chunks.count"),
    ("R3 reconcile trusts any saved state", "core", CORE, "guard answer.ok && answer.state == \"saved\" && answer.sessionId == captureId && answer.receiptSaved == true && answer.receiptVersion == 1", "guard answer.state == \"saved\""),
    ("R4 reconcile trusts a receipt for another capture", "core", CORE, "            && answer.receiptSessionId == captureId && answer.receiptCaptureId == captureId && answer.receiptSourceType == \"mac_system_audio\"", "            && answer.receiptSourceType == \"mac_system_audio\""),
    ("R5 the spool marks a journal with unacknowledged audio", "core", CORE, "        guard !value.chunks.isEmpty, value.acknowledged == value.chunks.count else { throw MacRecordingError.unavailable(\"Recording still has pending audio.\") }\n        value.stopped = true; value.saved = true", "        value.stopped = true; value.saved = true"),
    ("R6 a marked journal stays unstopped", "core", CORE, "        value.stopped = true; value.saved = true; try write(value); return value", "        value.saved = true; try write(value); return value"),
    ("R7 Recover gives no reason during a recording", "core", CORE, "        case \"starting\", \"recording\", \"stopping\": return \"Recover is available after this recording.\"\n", ""),
    ("R8 Recover gives no reason during a save", "core", CORE, "        if delivering { return \"Recover is available once this recording is saved.\" }\n", ""),
    ("R9 Recover gives no reason behind a paused recording", "core", CORE, "        if currentUnsaved {\n            return nothingToKeep ? \"Recover is available once the recording above is discarded.\" : \"Recover is available once the recording above is saved or kept for later.\"\n        }\n", ""),
    # 0.5.351 reconcile and the Recover reason: wiring (pins lane).
    ("S1 reconcile is never called", "pins", STORE, "                    let checked = await reconciled(recoverable)\n                    if !occupied { recoverable = checked }\n", ""),
    ("S2 reconcile hides without asking the server", "pins", STORE, "guard MacRecordingReconcile.shouldAsk(value, current: manifest?.captureId), await savedOnServer(value) else { kept.append(value); continue }", "guard MacRecordingReconcile.shouldAsk(value, current: manifest?.captureId) else { kept.append(value); continue }"),
    ("S3 a failed journal mark drops the row anyway", "pins", STORE, "            } catch {\n                kept.append(value)\n                recordingLog.error(\"reconcile: journal not marked, kept\")", "            } catch {\n                recordingLog.error(\"reconcile: journal not marked, kept\")"),
    ("S4 a grayed-out Recover says nothing", "pins", STORE, "            if !retained.isEmpty, !store.canStart, let reason = store.recoverUnavailable {", "            if false, let reason = store.recoverUnavailable {"),
    ("S5 the reason ignores a running save", "pins", STORE, "MacRecordingRecoveryPolicy.recoverUnavailable(phase: phase, delivering: deliveryTask != nil,", "MacRecordingRecoveryPolicy.recoverUnavailable(phase: phase, delivering: false,"),
    # Quick-save QA fixes (W3, W4, W6, W7, W8, N3, N8): the rules (core lane).
    ("K1 Keep is not offered during a quiet wait", "core", CORE, "(paused && !delivering || waiting) && !noSpeech && pending && stopped", "(paused && !delivering) && !noSpeech && pending && stopped"),
    ("K2 Keep is offered for no speech during a wait", "core", CORE, "(paused && !delivering || waiting) && !noSpeech && pending && stopped", "(paused && !delivering || waiting) && pending && stopped"),
    ("K3 Retry is not offered during a quiet wait", "core", CORE, "pending && hasChunks && !noSpeech && !allZero && (!delivering || waiting)", "pending && hasChunks && !noSpeech && !allZero && !delivering"),
    ("K4 the controls show from the first quiet wait", "core", CORE, "static func offersControls(delivering: Bool, waiting: Bool, slow: Bool) -> Bool { delivering && waiting && slow }", "static func offersControls(delivering: Bool, waiting: Bool, slow: Bool) -> Bool { delivering && waiting }"),
    ("K5 the quiet tries have no wall clock", "core", CORE, "        guard elapsed < window else { return nil }\n", ""),
    ("K6 the last wait runs past the window", "core", CORE, "return min(table[attempt], window - elapsed)", "return table[attempt]"),
    ("K7 the window is ten minutes", "core", CORE, "static let windowSeconds: Double = 75", "static let windowSeconds: Double = 600"),
    ("K8 the window loosens the after-Stop rule", "core", CORE, "guard stopped, transient, attempt >= 0, attempt < table.count else { return nil }", "guard transient, attempt >= 0, attempt < table.count else { return nil }"),
    ("K9 thousands are not grouped", "core", CORE, "formatter.usesGroupingSeparator = true;", "formatter.usesGroupingSeparator = false;"),
    ("K10 Record always points at Meetings", "core", CORE, "if pendingCapture { return .set(saving ? stillSaving : pending) }", "if pendingCapture { return .set(pending) }"),
    ("K11 Recover never names Discard", "core", CORE, "return nothingToKeep ? \"Recover is available once the recording above is discarded.\" :", "return false ? \"Recover is available once the recording above is discarded.\" :"),
    ("K12 reconcile ignores the receipt's server", "core", CORE, "\n            && answer.receiptServerInstanceId == serverInstanceId else { return false }", " else { return false }"),
    ("K13 reconcile ignores the receipt's integrity", "core", CORE, "return integrity.missingChunks == 0 && integrity.expected == chunkCount", "return true"),
    ("K14 reconcile ignores how many chunks were expected", "core", CORE, "return integrity.missingChunks == 0 && integrity.expected == chunkCount", "return integrity.missingChunks == 0"),
    # Quick-save QA fixes: the wiring (pins lane).
    ("Z1 the quiet window never starts", "pins", STORE, "                if quietSince == nil { quietSince = now }\n", ""),
    ("Z2 the quiet tries ignore the window", "pins", STORE, "since: quietSince, now: now, window: retryWindow) else { throw error }", "since: nil, now: now, window: retryWindow) else { throw error }"),
    ("Z3 the wait mark flickers off after each sleep", "pins", STORE, "                try? await Task.sleep(for: .seconds(pause))\n", "                try? await Task.sleep(for: .seconds(pause))\n                waitingToRetry = false\n"),
    ("Z4 the wait mark outlives the delivery", "pins", STORE, "self.deliveryTask = nil; self.waitingToRetry = false", "self.deliveryTask = nil"),
    ("Z5 a stale passing flag speaks for a new delivery", "pins", STORE, "self.deliveryFailureTransient = false; self.quietSince = nil", "self.quietSince = nil"),
    ("Z6 a wake during a passing failure is dropped", "pins", STORE, "(!failed || self.deliveryFailureTransient)", "!failed"),
    ("Z7 a failure while stopping paints the red line", "pins", STORE, "[\"recording\", \"stopping\"].contains(self.phase) && self.deliveryFailureTransient", "[\"recording\"].contains(self.phase) && self.deliveryFailureTransient"),
    ("Z8 a new recording keeps the old passing flag", "pins", STORE, "deliveryPaused = false; deliveryFailureTransient = false\n", "deliveryPaused = false\n"),
    ("Z9 Stop keeps the old passing flag", "pins", STORE, "        deliveryFailureTransient = false\n        if let id = manifest?.captureId { MacRecordingOpenCaptures", "        if let id = manifest?.captureId { MacRecordingOpenCaptures"),
    ("Z10 reconcile replaces the list under a new recording", "pins", STORE, "if !occupied { recoverable = checked }", "recoverable = checked"),
    ("Z11 reconcile asks the server before the sources load", "pins", STORE, "                    serverDiscard = result[\"discard\"]?.bool == true\n", "                    serverDiscard = result[\"discard\"]?.bool == true\n                    _ = await reconciled(recoverable)\n"),
    ("Z12 Keep leaves the delivery running", "pins", STORE, "        if let delivering = deliveryTask { deliveryWake = false; delivering.cancel(); await delivering.value }\n        slowTask?.cancel()", "        slowTask?.cancel()"),
    ("Z13 Retry now works outside a quiet wait", "pins", STORE, "            guard quietWaitControls else { return }\n", ""),
    ("Z14 Record names Meetings while the save runs", "pins", STORE, "let stillSaving = deliveryTask != nil && !quietWaitControls", "let stillSaving = false"),
    ("Z15 Recover ignores a recording with no sound", "pins", STORE, "nothingToKeep: noSpeech || manifest?.allDigitalSilence == true)", "nothingToKeep: false)"),
    ("Z16 Keep ignores a quiet wait", "pins", STORE, "stopped: manifest?.stopped == true,\n                                                   delivering: deliveryTask != nil, waiting: quietWaitControls)", "stopped: manifest?.stopped == true,\n                                                   delivering: deliveryTask != nil)"),
    ("Z17 a retry reads the refusal from shared state", "pins", STORE, "let refusal = error as? MacRecordingHelperRefusal", "let refusal: MacRecordingHelperRefusal? = nil"),
    # The helper (helper lane: the compiled helper against the loopback stand-in).
    ("X1 the helper discards without confirm", "helper", HELPER, "            guard payload[\"confirm\"] as? Bool == true, (payload[\"confirm\"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true else {", "            guard true else {"),
    ("X2 the helper takes a number for confirm", "helper", HELPER, "            guard payload[\"confirm\"] as? Bool == true, (payload[\"confirm\"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true else {", "            guard payload[\"confirm\"] as? Bool == true else {"),
    ("X3 an older server's 404 has no reason", "helper", HELPER, "            else if operation == \"discard\", response.status == 404 { failure[\"reason\"] = \"route_absent\" }\n", ""),
]

def run(lane, root):
    # compile-bounded refuses (exit 75) while the Mac lacks memory headroom; that is a wait, never a kill.
    import time
    for _ in range(20):
        r = run_once(lane, root)
        if r.returncode == 75 or "compile-bounded: refused" in (r.stdout + r.stderr):
            time.sleep(60); continue
        return r
    return r

def run_once(lane, root):
    if lane == "helper":
        out = tempfile.mkdtemp(prefix="cos-mac-rec-helper-", dir="/private/tmp")
        # The helper exactly as Tests/run.sh builds it.
        build = subprocess.run(["/usr/bin/python3", str(root / "Tests/kit-compile.py"), str(root / "Tests/compile-guard.sh"), "swiftc",
            "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete",
            str(root / "HelperSources/main.swift"), str(root / "HelperSources/ProviderStatusCore.swift"), str(root / "HelperSources/PairingCore.swift"),
            str(root / "Sources/WorkSessionLinks.swift"), "-framework", "Security", "-framework", "AppKit",
            "-o", out + "/cos-control-helper"], cwd=root, capture_output=True, text=True)
        if build.returncode != 0:
            return build
        return subprocess.run(["/usr/bin/python3", str(root / "Tests/mac-recording-helper-checks.py"), out + "/cos-control-helper"], cwd=root, capture_output=True, text=True)
    return subprocess.run(["zsh", str(root / "Tests/run-mac-recording.sh")], cwd=root, env=dict(os.environ, COS_MAC_REC_LANE=lane), capture_output=True, text=True)

def named(out):
    for line in out.splitlines():
        if "Precondition failed" in line or "FAILED: [" in line or "AssertionError" in line:
            return line.strip()[:200]
    return None

args = [a for a in sys.argv[1:] if not a.startswith("--")]
if "--list" in sys.argv:
    for m in MUTANTS: print(m[0])
    sys.exit(0)
chosen = [m for m in MUTANTS if not args or any(m[0].startswith(a) for a in args)]
lanes = sorted({m[1] for m in chosen})
for lane in lanes:
    base = run(lane, ROOT)
    if base.returncode != 0:
        print(f"BASELINE RED ({lane}):\n{base.stdout[-2000:]}{base.stderr[-2000:]}"); sys.exit(2)
print("baseline green: " + ", ".join(lanes))
killed = survivors = infra = 0
for name, lane, rel, old, new in chosen:
    path = ROOT / rel
    src = path.read_text()
    if src.count(old) != 1 or old == new:
        print(f"{name}: NOT APPLIED (target found {src.count(old)} times)"); infra += 1; continue
    path.write_text(src.replace(old, new))
    try:
        if path.read_text() == src:
            print(f"{name}: NOT APPLIED (file unchanged)"); infra += 1; continue
        r = run(lane, ROOT)
        out = r.stdout + r.stderr
        line = named(out)
        if r.returncode != 0 and line:
            killed += 1; print(f"{name}: killed by {line}")
        elif r.returncode != 0:
            infra += 1; print(f"{name}: INFRASTRUCTURE (exit {r.returncode}, no named check)\n{out[-800:]}")
        else:
            survivors += 1; print(f"{name}: SURVIVED")
    finally:
        path.write_text(src)
        assert path.read_text() == src, f"restore failed for {rel}"
print(f"mac recording robust mutants: {killed} killed, {survivors} survived, {infra} infrastructure, of {len(chosen)}")
sys.exit(1 if survivors or infra else 0)
