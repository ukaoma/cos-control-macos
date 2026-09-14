import AppKit
import SwiftUI
import Foundation

@main @MainActor
struct HeldNamingUIContract {
    static func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.16)) }
    static func scrolls(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls($0) }
    }
    static func render<V: View>(_ view: V, size: NSSize, name: String, output: URL) throws -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        pump(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); pump()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No native bitmap for \(name)") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        precondition(host.bounds.width == size.width && host.bounds.height == size.height, "content escaped window clamp")
        precondition(png.count > 5000, "native render unexpectedly blank")
        return (window, host)
    }
    static func fixture() -> [String: JSONValue] {
        let members: [JSONValue] = [.object(["sessionId": .string("meeting_1789131711342_fixture"), "chunkIndex": .number(7), "status": .string("ready")])]
        return ["kind": .string("preview"), "speaker": .string("Brigitta Pólya"), "previewHash": .string(String(repeating: "a", count: 64)), "expiresAt": .number(Date().addingTimeInterval(900).timeIntervalSince1970 * 1000), "owner": .bool(true), "requiresListening": .bool(true), "members": .array(members), "profileEmbeddings": .number(40), "meetings": .array([.object([
            "sessionId": .string("meeting_1789131711342_fixture"), "status": .string("ready"), "namedChunks": .array([.number(3)]), "widerChunks": .array([.number(4), .number(5), .number(6)]), "labelled": .number(4), "roomRisk": .bool(true), "copies": .array([.object(["copy": .string("local")]), .object(["copy": .string("operations")])]), "playback": .array([.object(["sessionId": .string("meeting_1789131711342_fixture"), "chunkIndex": .number(7), "position": .number(3)])])])])]
    }
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/cos-held-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let model = ControllerModel(startBackgroundWork: false)
        precondition(!model.backgroundWorkEnabled)
        model.heldGroupsState = "ready"; model.heldNamingAvailable = true; model.heldGroupsSamples = 239; model.heldGroupsEmbedded = 239
        model.heldLoose = (0..<239).compactMap { index in HeldSampleRef(.object(["sessionId": .string("meeting_1789131711342_fixture"), "chunkIndex": .number(Double(index)), "suggestion": index < 16 ? .object(["name": .string("Brigitta Pólya"), "similarity": .number(0.71), "agreeing": .number(2), "ownerCaution": .bool(index == 1)]) : .null])) }
        precondition(model.heldLoose.count == 239)
        for size in [NSSize(width: 760, height: 560), NSSize(width: 1100, height: 820)] {
            let name = "samples-\(Int(size.width))"
            let (window, host) = try render(ActivityWindow.heldSamplesCanary(model: model), size: size, name: name, output: output)
            let lists = scrolls(host)
            precondition(!lists.isEmpty, "239 rows need a native scrolling surface")
            let list = lists.max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }!
            precondition((list.documentView?.frame.height ?? 0) > list.contentSize.height * 3, "all 239 rows must scroll inside the view")
            precondition(list.contentSize.height >= 80, "sample list lost its visible floor")
            let original = list.contentView.bounds.origin.y
            list.contentView.scroll(to: NSPoint(x: 0, y: min(600, (list.documentView?.frame.height ?? 0) - list.contentSize.height)))
            list.reflectScrolledClipView(list.contentView); pump()
            precondition(list.contentView.bounds.origin.y != original, "scrolling cannot stay frozen on the first samples")
            precondition(host.bounds.size == size, "scrolling moved the window chrome")
            window.orderOut(nil)
            print("PASS \(name): 239 rows scroll in place; native viewport \(Int(list.contentSize.height)) points")
        }
        model.heldNamingPreview = HeldNamingReceipt(fixture())
        precondition(!model.heldNamingCanApply)
        model.heldNamingOwnerAck = true; precondition(!model.heldNamingCanApply)
        model.heldNamingListened = true; precondition(model.heldNamingCanApply)
        model.heldNamingAvailable = false; precondition(!model.heldNamingCanApply)
        let (oldWindow, _) = try render(ActivityWindow.heldSamplesCanary(model: model), size: NSSize(width: 760, height: 560), name: "samples-old-server", output: output)
        oldWindow.orderOut(nil); model.heldNamingAvailable = true
        model.heldNamingOwnerAck = false; model.heldNamingListened = false
        for size in [NSSize(width: 640, height: 520), NSSize(width: 740, height: 660)] {
            let (window, _) = try render(HeldNamingReviewSheet(model: model), size: size, name: "preview-\(Int(size.width))", output: output)
            window.orderOut(nil)
        }
        var expired = fixture(); expired["expiresAt"] = .number(1); model.heldNamingPreview = HeldNamingReceipt(expired)
        model.heldNamingOwnerAck = true; model.heldNamingListened = true; precondition(!model.heldNamingCanApply)
        let (expiredWindow, _) = try render(HeldNamingReviewSheet(model: model), size: NSSize(width: 640, height: 520), name: "preview-expired", output: output)
        expiredWindow.orderOut(nil)
        var applied = fixture(); applied["kind"] = .string("applied"); applied["batchId"] = .string("fixture-batch"); applied["undoHandle"] = .string("fixture-batch"); applied["enrolled"] = .number(1); applied["deleted"] = .number(239); applied["status"] = .string("partial"); applied["partial"] = .bool(true)
        var meeting = applied["meetings"]!.array![0].object!
        meeting["status"] = .string("failed"); meeting["labelsNewerThanGraph"] = .bool(true); meeting["error"] = .string("Operations copy was unavailable. Review before retrying.")
        meeting["receipts"] = .array([.object(["copy": .string("local"), "status": .string("applied")]), .object(["copy": .string("operations"), "status": .string("failed")])])
        applied["meetings"] = .array([.object(meeting)])
        model.heldNamingResult = HeldNamingReceipt(applied); model.heldLoose = []
        model.heldNamingBatches = [HeldNamingBatch(.object(applied))!]
        precondition(model.heldNamingResult?.undoHandle != nil && model.heldNamingBatches[0].needsReview)
        for size in [NSSize(width: 640, height: 520), NSSize(width: 740, height: 660)] {
            let (resultWindow, _) = try render(HeldNamingResultSheet(model: model), size: size, name: "result-\(Int(size.width))", output: output); resultWindow.orderOut(nil)
            let (historyWindow, _) = try render(HeldNamingHistorySheet(model: model), size: size, name: "recovery-\(Int(size.width))", output: output); historyWindow.orderOut(nil)
        }
        print("PASS naming gates: owner, listening, expired preview, old server, partial copy receipt and persistent Undo with no held audio")
        print("COS Control: native naming fixtures rendered to \(output.path)")
    }
}
