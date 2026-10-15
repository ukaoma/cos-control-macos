import Foundation
import Darwin

/// Pure fixture audio bytes only. Never opens a tap, microphone, socket, or permission prompt.
@main struct MacRecordingChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let scratch = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("cos-mac-spool-" + UUID().uuidString)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        let gate = MacRecordingStopGate()
        var releaseFlush: CheckedContinuation<Void, Never>?
        var starts = 0, firstFinished = false, quitFinished = false
        let firstStop = Task { await gate.run { starts += 1; await withCheckedContinuation { releaseFlush = $0 } }; firstFinished = true }
        for _ in 0..<1000 { if releaseFlush != nil { break }; await Task.yield() }
        check(releaseFlush != nil, "first Stop begins asynchronous flush")
        let quit = Task { await gate.run { starts += 1 }; quitFinished = true }
        for _ in 0..<10 { await Task.yield() }
        check(starts == 1 && !firstFinished && !quitFinished, "quit awaits existing Stop without starting duplicate teardown")
        releaseFlush?.resume(); await firstStop.value; await quit.value
        check(firstFinished && quitFinished && starts == 1, "all Stop callers complete only after local flush")
        await gate.run { starts += 1 }
        check(starts == 2, "later recording can use Stop gate again")
        func rejects(_ name: String, _ action: () async throws -> Void) async {
            do { try await action(); preconditionFailure(name) } catch { checks += 1 }
        }
        func manifest(_ n: Int) -> MacRecordingManifest {
            MacRecordingManifest(captureId: String(format: "mac_%08d-1234-1234-1234-123456789abc", n), startTime: 1_792_026_000_000 + Double(n), serverInstanceId: "fixture-server", sourceName: "Fixture app", title: "Fixture recording", stopped: false, saved: false, acknowledged: 0, chunks: [])
        }
        let pcm = Data(repeating: 0, count: 32_000)
        let wav = try MacRecordingWAV.encode(pcm)
        check(wav.count == pcm.count + 44 && String(data: wav.prefix(4), encoding: .ascii) == "RIFF", "canonical WAV header and exact size")
        await rejects("empty WAV rejected") { _ = try MacRecordingWAV.encode(Data()) }
        await rejects("odd PCM rejected") { _ = try MacRecordingWAV.encode(Data([0])) }
        await rejects("WAV over 30 seconds rejected") { _ = try MacRecordingWAV.encode(Data(repeating: 0, count: 960_002)) }
        let root = scratch.appendingPathComponent("recordings")
        let spool = MacRecordingSpool(root: root)
        let initial = manifest(1)
        try await spool.write(initial)
        await rejects("nonconsecutive chunk rejected") { _ = try await spool.append(.init(index: 1, pcm: pcm, endFrame: 16_000), captureId: initial.id) }
        await rejects("endFrame must match PCM frames") { _ = try await spool.append(.init(index: 0, pcm: pcm, endFrame: 15_999), captureId: initial.id) }
        let appended = try await spool.append(.init(index: 0, pcm: pcm, endFrame: 16_000), captureId: initial.id)
        check(appended.chunks.count == 1 && appended.chunks[0].endFrame == 16_000, "journal advances exact frame count")
        let audioURL = URL(fileURLWithPath: try await spool.path(for: appended.chunks[0], captureId: initial.id))
        check(try Data(contentsOf: audioURL) == wav, "disk audio canonical and unchanged")
        for url in [root, root.appendingPathComponent(initial.id), audioURL, audioURL.deletingLastPathComponent().appendingPathComponent("manifest.json")] {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            check((attributes[.posixPermissions] as! NSNumber).intValue & 0o077 == 0, "private spool permissions")
        }
        await rejects("cannot save pending audio") { _ = try await spool.markSaved(initial.id) }
        let acknowledged = try await spool.acknowledge(initial.id, index: 0)
        check(acknowledged.acknowledged == 1 && acknowledged.chunks.count == 1, "acknowledgement preserves captured journal")
        await rejects("duplicate ack rejected") { _ = try await spool.acknowledge(initial.id, index: 0) }
        _ = try await spool.markStopped(initial.id)
        await rejects("stopped capture cannot append") { _ = try await spool.append(.init(index: 1, pcm: pcm, endFrame: 32_000), captureId: initial.id) }
        _ = try await spool.markSaved(initial.id)
        await rejects("saved capture cannot append") { _ = try await spool.append(.init(index: 1, pcm: pcm, endFrame: 32_000), captureId: initial.id) }
        let reopened = MacRecordingSpool(root: root)
        check(try await reopened.snapshot(initial.id).saved, "saved state survives restart")
        check(try await reopened.recoverable().isEmpty, "saved captures excluded from recovery")
        let healthy = manifest(2)
        try await spool.write(healthy)
        _ = try await spool.append(.init(index: 0, pcm: pcm, endFrame: 16_000), captureId: healthy.id)
        let corrupt = manifest(3)
        try await spool.write(corrupt)
        let corruptFile = root.appendingPathComponent(corrupt.id).appendingPathComponent("manifest.json")
        try Data("broken json".utf8).write(to: corruptFile)
        let recovered = MacRecordingSpool(root: root)
        check(try await recovered.recoverable().map(\.id) == [healthy.id], "one corrupt journal cannot hide healthy recovery")
        check(await recovered.recoveryWarnings().count == 1, "corrupt recovery is reported")
        let interrupted = try await spool.interrupt(healthy.id, reason: "Fixture interruption\n" + String(repeating: "x", count: 300))
        check(interrupted.interruption?.count == 256 && interrupted.interruption?.contains("\n") == false, "interruption is bounded and persisted")
        _ = try await spool.interrupt(healthy.id, reason: "Replacement reason")
        check(try await MacRecordingSpool(root: root).snapshot(healthy.id).interruption == interrupted.interruption, "first interruption survives restart and retries")
        let orphan = root.appendingPathComponent(healthy.id).appendingPathComponent("000001.wav")
        try wav.write(to: orphan); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: orphan.path)
        let orphanRecovery = MacRecordingSpool(root: root)
        let orphanManifests = try await orphanRecovery.recoverable()
        check(orphanManifests.first?.chunks.count == 1, "orphan WAV never guessed into journal")
        check(await orphanRecovery.recoveryWarnings().count == 2 && fm.fileExists(atPath: orphan.path), "orphan audio retained and warning reported alongside corrupt journal")
        let oversized = manifest(4)
        try await spool.write(oversized)
        let oversizedFile = root.appendingPathComponent(oversized.id).appendingPathComponent("manifest.json")
        try Data(repeating: 32, count: 512_001).write(to: oversizedFile)
        await rejects("bounded journal reads") { _ = try await MacRecordingSpool(root: root).snapshot(oversized.id) }
        let linked = manifest(5)
        try await spool.write(linked)
        let linkedFile = root.appendingPathComponent(linked.id).appendingPathComponent("manifest.json")
        try fm.removeItem(at: linkedFile)
        try fm.createSymbolicLink(at: linkedFile, withDestinationURL: oversizedFile)
        await rejects("journal symlink refused") { _ = try await MacRecordingSpool(root: root).snapshot(linked.id) }
        let hardlinked = manifest(6)
        try await spool.write(hardlinked)
        let hardFile = root.appendingPathComponent(hardlinked.id).appendingPathComponent("manifest.json")
        let hardCopy = scratch.appendingPathComponent("copied-manifest.json")
        try fm.linkItem(at: hardFile, to: hardCopy)
        await rejects("journal hardlink refused") { _ = try await MacRecordingSpool(root: root).snapshot(hardlinked.id) }
        let aliasedRoot = scratch.appendingPathComponent("root-link")
        try fm.createSymbolicLink(at: aliasedRoot, withDestinationURL: root)
        await rejects("root symlink refused") { try await MacRecordingSpool(root: aliasedRoot).write(manifest(7)) }
        let aliasedCapture = manifest(8)
        try fm.createSymbolicLink(at: root.appendingPathComponent(aliasedCapture.id), withDestinationURL: root.appendingPathComponent(healthy.id))
        await rejects("capture directory symlink refused") { try await spool.write(aliasedCapture) }
        let publicRoot = scratch.appendingPathComponent("public-root")
        try fm.createDirectory(at: publicRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        await rejects("shared storage refused") { try await MacRecordingSpool(root: publicRoot).write(manifest(9)) }
        var unsafe = manifest(10); unsafe.acknowledged = -1
        await rejects("negative ack rejected") { try await spool.write(unsafe) }
        var malformed = manifest(11); malformed.chunks = [.init(index: 0, filename: "../outside.wav", endFrame: 16_000)]
        await rejects("journal traversal filename rejected") { try await spool.write(malformed) }
        var title = manifest(12); title.title = String(repeating: "a", count: 161)
        await rejects("title matches helper bound") { try await spool.write(title) }
        print("Mac recording core checks: \(checks) passed (fixture bytes only)")
    }
}
