import AppKit
import SwiftUI

/// Run by hand (Tests/run-quick-save-render.sh <folder> [base]): the Record on Mac panel after Stop, drawn off screen,
/// light and dark, at the 390 pt panel width, through the real MacRecordingStore and MacRecordingPanel with a stand-in
/// helper bridge and a fixture spool in a scratch folder (tiny fixture chunks, no microphone, no tap, no server). Windows
/// are never ordered in, the process never becomes active, and nothing is clicked or typed.
///
/// Built with -D QUICK_SAVE on 0.5.351; built without it on 3cb0602 (release/0.5.350) it is the canary that shows the
/// old behaviour: the counter and Retry through an ordinary save, and a passing failure at Stop left paused.
@main @MainActor struct QuickSaveRender {
    static let instance = FakeServer.pin
    static var serial = 0

    /// The helper, as COS Control's bridge sees it, for one scenario.
    @MainActor final class FakeServer {
        enum Mode { case answer, hold, failThenAnswer(Int), alwaysStopped, refuse, noSpeech }
        var mode: Mode
        var chunkCalls = 0, saveCalls = 0, statusCalls = 0, discardCalls = 0
        /// What the server answers to each discard call, in order; the last one repeats.
        enum DiscardAnswer { case discarded, notIdle }
        var discardAnswers: [DiscardAnswer] = [.discarded]
        /// Runs when the status op is asked (the reconcile check reads the store's sources then).
        var onStatus: (@MainActor () -> Void)?
        /// The status op (0.5.351 reconcile): "saved" with a receipt, "missing", or the helper not answering.
        enum Status { case saved, missing, unreachable }
        var status = Status.missing
        private var held: [CheckedContinuation<Void, Never>] = []
        init(_ mode: Mode) { self.mode = mode }
        func release() { let all = held; held = []; all.forEach { $0.resume() } }
        func answer(_ operation: String, _ payload: [String: JSONValue]) async throws -> HelperResponse {
            let id = payload["captureId"]?.string ?? ""
            switch operation {
            case "capabilities":
                return HelperResponse(ok: true, message: "Mac recording", details: ["available": .bool(true), "serverInstanceId": .string(Self.pin), "discard": .bool(true)])
            case "status":
                statusCalls += 1; onStatus?()
                switch status {
                case .unreachable: throw HelperClientError.commandFailed("Server stopped")
                case .missing: return HelperResponse(ok: true, message: "Mac recording", details: ["sessionId": .string(id), "state": .string("missing"), "saveReceipt": .null])
                case .saved:
                    return HelperResponse(ok: true, message: "Mac recording", details: ["sessionId": .string(id), "state": .string("saved"), "saveReceipt": .object([
                        "saved": .bool(true), "receiptVersion": .number(1), "sessionId": .string(id), "captureId": .string(id), "sourceType": .string("mac_system_audio"),
                        "serverInstanceId": .string(Self.pin)])])
                }
            case "chunk":
                chunkCalls += 1
                switch mode {
                case .hold: await withCheckedContinuation { held.append($0) }
                case .failThenAnswer(let n) where chunkCalls <= n: throw HelperClientError.commandFailed("Server stopped")
                case .alwaysStopped: throw HelperClientError.commandFailed("Server stopped")
                case .refuse:
                    return HelperResponse(ok: false, message: "Mac recording could not continue. Check its receipt before retrying.",
                                          details: ["httpStatus": .number(409), "reason": .string("server_instance_mismatch")])
                default: break
                }
                return HelperResponse(ok: true, message: "Mac recording", details: [
                    "sessionId": .string(id), "chunkIndex": payload["chunkIndex"] ?? .number(-1), "serverInstanceId": .string(Self.pin),
                    "asrCompleted": .bool(true), "canonical": .bool(true), "httpStatus": .number(200)])
            case "discard":
                discardCalls += 1
                let answer = discardAnswers[min(discardCalls - 1, discardAnswers.count - 1)]
                switch answer {
                case .discarded: return HelperResponse(ok: true, message: "Mac recording", details: ["discarded": .bool(true), "httpStatus": .number(200)])
                case .notIdle: return HelperResponse(ok: false, message: "Mac recording could not continue.", details: ["httpStatus": .number(409), "reason": .string("not_idle")])
                }
            case "save":
                saveCalls += 1
                if case .noSpeech = mode {
                    return HelperResponse(ok: false, message: "Mac recording has nothing to save.", details: ["httpStatus": .number(404), "reason": .string("nothing_to_save")])
                }
                return HelperResponse(ok: true, message: "Mac recording", details: [
                    "saved": .bool(true), "receiptVersion": .number(1), "serverInstanceId": .string(Self.pin), "sessionId": .string(id),
                    "captureId": .string(id), "sourceType": .string("mac_system_audio"), "httpStatus": .number(200)])
            default:
                return HelperResponse(ok: false, message: "unsupported in this render", details: [:])
            }
        }
        nonisolated static let pin = "fixture-server-instance"
    }

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let scratch = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("cos-quick-save-render." + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        var summary: [String] = []
        /// A check that may `await` in its condition (precondition's autoclosure cannot).
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message) }

        /// A stopped capture of 345 tiny chunks, 340 of them acknowledged (Miles's 13:38 save had 345), in its own spool.
        func scenario(_ server: FakeServer, retainedToo: Bool = false, tune: (MacRecordingStore) -> Void = { _ in }) async throws -> (MacRecordingStore, MacRecordingManifest, MacRecordingStore.Bridge) {
            serial += 1
            let root = scratch.appendingPathComponent("s\(serial)/cos-data/mac-recordings", isDirectory: true)
            let spool = MacRecordingSpool(root: root)
            let id = "mac_" + UUID().uuidString.lowercased()
            let start = MacRecordingManifest(captureId: id, startTime: 1_792_600_000_000, serverInstanceId: instance, sourceName: MacAudioSource.allMacAudio.name,
                                             title: "Microsoft Teams meeting 1:04 PM", stopped: false, saved: false, acknowledged: 0, chunks: [])
            try await spool.write(start)
            let pcm = Data((0..<320).map { UInt8(truncatingIfNeeded: $0 * 7 + 1) })
            for index in 0..<345 { _ = try await spool.append(.init(index: index, pcm: pcm, endFrame: (index + 1) * 160), captureId: id) }
            for index in 0..<340 { _ = try await spool.acknowledge(id, index: index) }
            let stopped = try await spool.markStopped(id)
            if retainedToo {
                // A second capture, ended by the app quitting mid-recording (never stopped), every chunk delivered: the
                // 12:02 Teams meeting's shape, in miniature.
                let other = "mac_" + UUID().uuidString.lowercased()
                try await spool.write(MacRecordingManifest(captureId: other, startTime: 1_792_599_000_000, serverInstanceId: instance, sourceName: MacAudioSource.allMacAudio.name,
                                                           title: "Microsoft Teams meeting 12:02 PM", stopped: false, saved: false, acknowledged: 0, chunks: []))
                for index in 0..<367 { _ = try await spool.append(.init(index: index, pcm: pcm, endFrame: (index + 1) * 160), captureId: other) }
                for index in 0..<367 { _ = try await spool.acknowledge(other, index: index) }
            }
            let store = MacRecordingStore(spool: MacRecordingSpool(root: root))
            tune(store)
            let bridge: MacRecordingStore.Bridge = { operation, payload in try await server.answer(operation, payload) }
            await store.prepare(bridge: bridge)
            return (store, stopped, bridge)
        }
        func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { if condition() { return true }; try? await Task.sleep(for: .milliseconds(20)) }
            return condition()
        }

        // 1. An ordinary save, mid-flight: the last chunks are on their way.
        let holding = FakeServer(.hold)
        let (a, aValue, aBridge) = try await scenario(holding, retainedToo: true)
        expect(await a.recover(aValue, bridge: aBridge) == .started, "saving: recover starts")
        expect(await until(5) { holding.chunkCalls == 1 }, "saving: the first chunk is in flight")
        expect(a.phase == "pending", "saving: pending while it delivers")
        #if QUICK_SAVE
        expect(!a.canRetrySave && a.saveLine.headline == "Saving…" && a.saveLine.progress == nil && !a.saveLine.showsActions,
                     "saving: Saving… only, no Retry")
        expect(a.recoverable.count == 2 && a.recoverUnavailable == "Recover is available once this recording is saved." && holding.statusCalls == 1,
                     "saving: the other retained capture stays (server says missing) and its grayed-out Recover says why")
        summary.append("saving: headline=\(a.saveLine.headline) retryOffered=\(a.canRetrySave) recoverReason=\(a.recoverUnavailable ?? "-")")
        #else
        summary.append("CANARY base saving: retryOffered=\(a.canRetrySave) (the Retry button shows mid-save)")
        #endif
        try render(MacRecordingPanel(store: a, bridge: aBridge), name: "quick-save-1-saving", out: out)
        holding.release()

        #if QUICK_SAVE
        // 2. The same save, slow: past the threshold it says how far it got.
        let slowHold = FakeServer(.hold)
        let (b, bValue, bBridge) = try await scenario(slowHold) { $0.slowSaveAfter = 0.3 }
        expect(await b.recover(bValue, bridge: bBridge) == .started, "slow: recover starts")
        expect(await until(5) { b.slowSave }, "slow: the slow flag rises")
        expect(b.saveLine.detail == "Still saving. 340 of 345 audio chunks have reached COS." && !b.canRetrySave, "slow: still saving, how far")
        summary.append("slow: detail=\(b.saveLine.detail ?? "-")")
        try render(MacRecordingPanel(store: b, bridge: bBridge), name: "quick-save-2-slow", out: out)
        slowHold.release()
        #endif

        // 3. Saved.
        let answering = FakeServer(.answer)
        let (c, cValue, cBridge) = try await scenario(answering)
        expect(await c.recover(cValue, bridge: cBridge) == .started, "saved: recover starts")
        expect(await until(5) { c.phase == "saved" }, "saved: the receipt lands")
        expect(answering.chunkCalls == 5 && answering.saveCalls == 1, "saved: five chunks and one save")
        #if QUICK_SAVE
        expect(c.saveLine.headline == "Saved" && c.saveLine.progress == nil && !c.slowSave, "saved: Saved, no counter")
        #endif
        summary.append("saved: phase=\(c.phase) chunks=\(answering.chunkCalls) saves=\(answering.saveCalls)")
        try render(MacRecordingPanel(store: c, bridge: cBridge), name: "quick-save-3-saved", out: out)

        // 4. The 10:58 case: the helper's health probe misses twice right after Stop ("Server stopped"), then answers.
        let blip = FakeServer(.failThenAnswer(2))
        let (d, dValue, dBridge) = try await scenario(blip) { store in
            #if QUICK_SAVE
            store.retryDelays = [0.05, 0.05, 0.05, 0.05, 0.05, 0.05]
            #endif
        }
        expect(await d.recover(dValue, bridge: dBridge) == .started, "blip: recover starts")
        _ = await until(5) { d.phase == "saved" || d.deliveryPaused }
        try? await Task.sleep(for: .milliseconds(300))
        #if QUICK_SAVE
        expect(d.phase == "saved" && d.error == nil && !d.deliveryPaused && blip.chunkCalls == 7, "blip: saved with no tap, two quiet tries")
        summary.append("blip: phase=\(d.phase) paused=\(d.deliveryPaused) chunkCalls=\(blip.chunkCalls) (saved with no tap)")
        #else
        expect(d.phase == "pending" && d.deliveryPaused && blip.chunkCalls == 1, "CANARY base blip: paused after one miss, stuck until Retry")
        summary.append("CANARY base blip: phase=\(d.phase) paused=\(d.deliveryPaused) chunkCalls=\(blip.chunkCalls) (stuck until Retry)")
        #endif
        try render(MacRecordingPanel(store: d, bridge: dBridge), name: "quick-save-4-blip-after", out: out)

        #if QUICK_SAVE
        // 5. A real failure: the server refuses (a different server instance). Honest: Not saved yet, the error, Retry.
        let refusing = FakeServer(.refuse)
        let (e, eValue, eBridge) = try await scenario(refusing)
        expect(await e.recover(eValue, bridge: eBridge) == .started, "refused: recover starts")
        expect(await until(5) { e.deliveryPaused }, "refused: delivery stops")
        expect(refusing.chunkCalls == 1 && e.saveLine.headline == MacRecordingSaveStatus.notSaved && e.canRetrySave && e.canKeepForLater
                     && e.error?.hasPrefix("Delivery paused:") == true, "refused: no quiet tries, Not saved yet, Retry and Keep")
        summary.append("refused: chunkCalls=\(refusing.chunkCalls) headline=\(e.saveLine.headline) retry=\(e.canRetrySave)")
        try render(MacRecordingPanel(store: e, bridge: eBridge), name: "quick-save-5-failed", out: out)

        // 6. COS not answering, still inside the quiet minute, and slow: Saving… with why.
        let down = FakeServer(.alwaysStopped)
        let (f, fValue, fBridge) = try await scenario(down) { $0.slowSaveAfter = 0.3; $0.retryDelays = [30, 30, 30, 30, 30, 30] }
        expect(await f.recover(fValue, bridge: fBridge) == .started, "down: recover starts")
        expect(await until(5) { f.waitingToRetry && f.slowSave }, "down: waiting and slow")
        expect(f.saveLine.headline == "Saving…" && f.saveLine.detail == MacRecordingSaveStatus.notAnswering && f.error == nil,
                     "down: Saving…, COS is not answering, no red line")
        expect(f.quietWaitControls && f.canRetrySave && f.canKeepForLater && f.saveLine.showsActions && f.canStart == false,
                     "down: a slow quiet wait offers Keep and Retry (quick-save QA W4)")
        summary.append("down: detail=\(f.saveLine.detail ?? "-")")
        try render(MacRecordingPanel(store: f, bridge: fBridge), name: "quick-save-6-not-answering", out: out)

        // 7. COS still not answering after the quiet minute: Not saved yet, with the error and Retry.
        let gone = FakeServer(.alwaysStopped)
        let (g, gValue, gBridge) = try await scenario(gone) { $0.retryDelays = [0.02, 0.02, 0.02, 0.02, 0.02, 0.02] }
        expect(await g.recover(gValue, bridge: gBridge) == .started, "gone: recover starts")
        expect(await until(5) { g.deliveryPaused }, "gone: the quiet tries end")
        expect(gone.chunkCalls == 7 && g.saveLine.headline == MacRecordingSaveStatus.notSaved && g.canRetrySave, "gone: seven calls, then Not saved yet and Retry")
        summary.append("gone: chunkCalls=\(gone.chunkCalls) headline=\(g.saveLine.headline)")
        try render(MacRecordingPanel(store: g, bridge: gBridge), name: "quick-save-7-gave-up", out: out)
        #endif

        #if QUICK_SAVE
        // 8. Reconcile: the server already saved the retained capture, so it leaves the list and its journal says saved.
        let reconciling = FakeServer(.answer); reconciling.status = .saved
        let (h, _, _) = try await scenario(reconciling, retainedToo: true)
        let hRetained = MacRecordingRecoveryPolicy.listed(h.recoverable, current: nil)
        expect(reconciling.statusCalls == 1 && hRetained.count == 1 && hRetained.first?.title != "Microsoft Teams meeting 12:02 PM",
                     "reconcile: the saved capture is hidden, the unsaved one stays")
        summary.append("reconcile saved: statusCalls=\(reconciling.statusCalls) listed=\(hRetained.count)")
        try render(MacRecordingPanel(store: h, bridge: { op, payload in try await reconciling.answer(op, payload) }), name: "quick-save-8-reconciled", out: out)

        // 9. Reconcile, server not answering the status: the row stays.
        let unsure = FakeServer(.answer); unsure.status = .unreachable
        let (k, _, _) = try await scenario(unsure, retainedToo: true)
        expect(unsure.statusCalls == 1 && k.recoverable.count == 2, "reconcile: an unreachable status keeps the row")
        summary.append("reconcile unreachable: statusCalls=\(unsure.statusCalls) listed=\(k.recoverable.count)")

        // 10. Quick-save QA W4: Keep during a slow quiet wait frees Record, with the audio kept for Recover.
        let waitingServer = FakeServer(.alwaysStopped)
        let (w, wValue, wBridge) = try await scenario(waitingServer) { $0.slowSaveAfter = 0.2; $0.retryDelays = [30, 30, 30, 30, 30, 30] }
        expect(await w.recover(wValue, bridge: wBridge) == .started, "keep: recover starts")
        expect(await until(5) { w.quietWaitControls }, "keep: the quiet wait shows its controls")
        await w.keepSilentAudioForLater()
        expect(w.phase == "idle" && w.manifest == nil && w.canStart && w.error == nil && !w.deliveryPaused && !w.waitingToRetry && !w.slowSave,
                     "keep: ends the delivery, frees Record, leaves no red line")
        expect(w.recoverable.contains { $0.captureId == wValue.captureId && !$0.saved && $0.chunks.count == 345 }, "keep: the audio is still offered for Recover, nothing lost")
        summary.append("keep during quiet wait: phase=\(w.phase) canStart=\(w.canStart) recoverable=\(w.recoverable.count)")

        // 11. Retry now during a slow quiet wait: tries at once instead of waiting out the pause.
        let nowServer = FakeServer(.failThenAnswer(1))
        let (n, nValue, nBridge) = try await scenario(nowServer) { $0.slowSaveAfter = 0.2; $0.retryDelays = [30, 30, 30, 30, 30, 30] }
        expect(await n.recover(nValue, bridge: nBridge) == .started, "retry now: recover starts")
        expect(await until(5) { n.quietWaitControls }, "retry now: the quiet wait shows its controls")
        await n.retryNow()
        expect(await until(5) { n.phase == "saved" }, "retry now: saves without waiting out the 30 s pause")
        summary.append("retry now: phase=\(n.phase) chunkCalls=\(nowServer.chunkCalls)")

        // 12. Quick-save QA W4: the quiet tries end on the wall clock, not only by count.
        let clockServer = FakeServer(.alwaysStopped)
        let (q, qValue, qBridge) = try await scenario(clockServer) { $0.retryDelays = [0.2, 0.2, 0.2, 0.2, 0.2, 0.2]; $0.retryWindow = 0.3 }
        expect(await q.recover(qValue, bridge: qBridge) == .started, "window: recover starts")
        expect(await until(5) { q.deliveryPaused }, "window: the tries end")
        expect((3...4).contains(clockServer.chunkCalls), "window: a 0.3 s window allows three or four tries, not the seven the table would (got \(clockServer.chunkCalls))")
        summary.append("window: chunkCalls=\(clockServer.chunkCalls)")

        // 13. Quick-save QA W5/W3: a capture the server finds no speech in. Discard is the only action, Recover says so, and the
        // server's not-idle answers are retried a bounded number of times.
        let silent = FakeServer(.noSpeech)
        silent.discardAnswers = [.notIdle, .discarded]
        final class Box<T> { var value: T; init(_ value: T) { self.value = value } }
        let discardedIDs = Box<[String]>([])
        let (z, zValue, zBridge) = try await scenario(silent, retainedToo: true) { $0.discardRetryDelay = 0.05 }
        z.discarded = { discardedIDs.value.append($0) }
        expect(await z.recover(zValue, bridge: zBridge) == .started, "no speech: recover starts")
        expect(await until(5) { z.noSpeech && z.canDiscard }, "no speech: the server's nothing_to_save is read as no speech")
        expect(z.canDiscard && !z.canKeepForLater && !z.canRetrySave && z.error == nil && z.noMeetingCaptureIDs.contains(zValue.captureId),
                     "no speech: only Discard is offered, no red line, and the hand-off stops looking")
        expect(z.recoverUnavailable == "Recover is available once the recording above is discarded.", "no speech: Recover names Discard, the only thing offered")
        summary.append("no speech: canDiscard=\(z.canDiscard) keep=\(z.canKeepForLater) retry=\(z.canRetrySave) reason=\(z.recoverUnavailable ?? "-")")
        try render(MacRecordingPanel(store: z, bridge: zBridge), name: "quick-save-10-no-speech", out: out)
        await z.discardNoSound()
        expect(z.phase == "idle" && silent.discardCalls == 1, "no speech: discard asks the server once")
        expect(await until(5) { silent.discardCalls == 2 && discardedIDs.value.count == 2 }, "no speech: a not-idle server is asked again, and the list is told again")
        summary.append("discard retry: serverCalls=\(silent.discardCalls) notified=\(discardedIDs.value.count)")
        let stubborn = FakeServer(.noSpeech)
        stubborn.discardAnswers = [.notIdle]
        let (y, yValue, yBridge) = try await scenario(stubborn) { $0.discardRetryDelay = 0.03 }
        expect(await y.recover(yValue, bridge: yBridge) == .started, "stubborn: recover starts")
        expect(await until(5) { y.noSpeech && y.canDiscard }, "stubborn: no speech")
        await y.discardNoSound()
        expect(await until(5) { stubborn.discardCalls == 1 + MacRecordingDiscard.retries }, "stubborn: asked again exactly twice")
        try? await Task.sleep(for: .milliseconds(300))
        expect(stubborn.discardCalls == 1 + MacRecordingDiscard.retries, "stubborn: and then it stops asking")
        summary.append("discard retries bounded: serverCalls=\(stubborn.discardCalls)")

        // 14. Quick-save QA W8: the audio sources are loaded before reconcile asks the server anything.
        let sourcesSeen = Box(-1)
        let ordering = FakeServer(.answer); ordering.status = .saved
        _ = try await scenario(ordering, retainedToo: true) { store in ordering.onStatus = { sourcesSeen.value = store.sources.count } }
        expect(ordering.statusCalls == 1 && sourcesSeen.value >= 1, "reconcile order: the audio sources are already loaded when the server is asked (saw \(sourcesSeen.value))")
        summary.append("reconcile order: sourcesWhenAsked=\(sourcesSeen.value)")
        #endif

        for line in summary { print(line) }
        print("quick save renders: \(summary.count) scenarios")
    }

    static func settle(_ view: NSView, seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); view.layoutSubtreeIfNeeded() }
    }

    static func render<V: View>(_ view: V, name: String, out: URL) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let root = VStack(alignment: .leading) { view; Spacer(minLength: 0) }.frame(maxWidth: .infinity, alignment: .leading)
                .frame(width: 390, height: 420, alignment: .top)
                .font(COSType.body(13)).background(COSPalette.panel).cosControlTheme()
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 390, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 390, height: 420)
            settle(host, seconds: 1.0)
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png"))
            window.close()
        }
    }
}
