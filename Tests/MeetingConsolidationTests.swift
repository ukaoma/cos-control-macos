import AppKit
import SwiftUI
import Foundation

private actor CleanupTransport {
    var available = true
    var loseReply = false
    var sends = 0
    var intent = ""
    var state = "running"
    func configure(available: Bool = true, loseReply: Bool = false, state: String = "running") {
        self.available = available; self.loseReply = loseReply; self.state = state
    }
    func count() -> Int { sends }
    func run(_ args: [String], _ data: Data?) throws -> HelperResponse {
        var details: [String: JSONValue] = [:]
        switch args.first {
        case "work-models":
            details = ["models": .array([.object(["id": .string("opus"), "provider": .string("claude"),
                "title": .string("Opus"), "available": .bool(available)])])]
        case "claude-sessions": details = ["sessions": .array([])]
        case "work-new":
            let body = try JSONSerialization.jsonObject(with: data!) as! [String: Any]
            precondition(body["model"] as? String == "opus")
            precondition((body["query"] as? String)?.contains(MeetingConsolidation.prompt) == true)
            sends += 1; intent = body["clientJobId"] as! String
            if loseReply { throw HelperClientError.commandFailed("Synthetic lost response") }
            fallthrough
        case "work-job":
            details = ["job": .object(["clientJobId": .string(intent), "generation": .number(1),
                "jobId": .string("cleanup-job"), "provider": .string("claude"), "status": .string(state),
                "response": .string("Transcript segments merged: 2. Audio clips: 0. Originals preserved. One uncertain boundary remains.")])]
        default: fatalError("Unexpected cleanup transport: \(args)")
        }
        return HelperResponse(ok: true, message: "Fixture", details: details)
    }
}

@MainActor enum MeetingConsolidationContract {
    static func checks(output: URL) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wire = CleanupTransport()
        let journal = root.appendingPathComponent("handoffs.json")
        func store() -> WorkHandoffStore {
            WorkHandoffStore(storageURL: journal, transport: { args, data in try await wire.run(args, data) })
        }
        let first = store()
        await wire.configure(available: false)
        await MeetingConsolidation.start(store: first, modelID: "opus")
        var sends = await wire.count()
        precondition(sends == 0 && first.error != nil, "Unavailable model must not silently substitute")
        await wire.configure()
        await MeetingConsolidation.start(store: first, modelID: "sonnet")
        sends = await wire.count()
        precondition(sends == 0, "Only the explicitly selected supported model may run")
        await wire.configure(loseReply: true)
        await MeetingConsolidation.start(store: first, modelID: "opus")
        sends = await wire.count()
        precondition(sends == 1 && first.receipts.first?.status == "unknown")
        let recovered = store()
        await MeetingConsolidation.start(store: recovered, modelID: "opus")
        sends = await wire.count()
        precondition(sends == 1 && recovered.error != nil, "Restart and duplicate click must not resend uncertain delivery")
        await wire.configure()
        await recovered.refreshReceipts(asked: true)
        precondition(recovered.receipts.first?.status == "running")
        await MeetingConsolidation.start(store: recovered, modelID: "opus")
        sends = await wire.count()
        precondition(sends == 1, "Active cleanup must block a second job")
        await wire.configure(state: "completed")
        await recovered.refreshReceipts(asked: true)
        precondition(recovered.receipts.first?.result?.contains("uncertain boundary") == true)
        precondition(recovered.receipts.first?.blocksNewHandoff == false)

        let model = ControllerModel(startBackgroundWork: false)
        model.meetingEngineStatus = MeetingEngineStatus(["mode": .string("advise")])
        for width in [390.0, 920.0] {
            for dark in [false, true] {
                let (window, _) = try MergeUIContract.render(
                    MeetingSuggestionsPane.canary(model: model, consolidationStore: recovered),
                    size: NSSize(width: width, height: 640), name: "cleanup-report-\(Int(width))", output: output, dark: dark)
                window.orderOut(nil)
            }
        }
        await MeetingConsolidation.start(store: recovered, modelID: "opus")
        sends = await wire.count()
        precondition(sends == 2, "A terminal receipt should permit a new explicit sweep")
        print("PASS cleanup: unavailable model, no fallback, lost reply, restart fence, active fence, report, repeat sweep, narrow/wide UI")
    }
}
