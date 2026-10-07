import AppKit
import AVFoundation
import CoreText
import SwiftUI

/// 0.5.254, run by hand (Tests/run-work-card-files-render.sh <folder>): the shipped Work views with files on a sample
/// card, drawn off screen to PNGs for a side-by-side check against design/work-card-files-0.5.254-mock.html. The board
/// with card face A, the Agent workspace's Files to send (New session, a local model, and a Continue with new and sent
/// files), and the Start sheet's files row and stop lines. The isolated preview store only: no server, no provider.
/// Windows are never ordered in, the process can never become active, and nothing is clicked, typed or dragged.
@main @MainActor struct WorkCardFilesRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("cos-card-render-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }

        let store = WorkHandoffStore(isolated: true)
        let files = store.cardFiles
        let task = WorkWorkspaceProjection.previewRows(store.previewTasks).first { !$0.checked }!
        let source = WorkSource.taskSnapshot(task)
        let urls = try await makeFixtures(fixtures)
        await files.intake(urls: urls, source: source)
        await files.waitForCompanions()
        files.reload(source.id)
        print("files on \(source.id): \(files.files(for: source.id).map { "\($0.display) [\($0.state)]" })")

        // The Agent workspace, New session in Claude.
        var draft = store.draft(for: source)
        draft.mode = .newSession; draft.provider = "claude"; draft.modelID = "opus"
        draft.prompt = "Rewrite the Korona blog post for Bottle POS. Keep the pricing gated: only Starter $59, link /pricing. Use the attached pricing sheet and the demo walkthrough for the switch story."
        _ = store.updateDraft(draft, for: source)
        try render(WorkHandoffView(store: store, source: source, isPreview: true, onOpenSession: { _ in }).padding(18), width: 440, name: "workspace-new-session", out: out)
        // The same with a local model: the warning.
        draft = store.draft(for: source); draft.provider = "ollama"; draft.modelID = "ollama"
        _ = store.updateDraft(draft, for: source)
        try render(WorkHandoffView(store: store, source: source, isPreview: true, onOpenSession: { _ in }).padding(18), width: 440, name: "workspace-local-model", out: out)
        // A Continue after one send, with two files added since.
        let session = store.sessions.first { $0.provider == "claude" }!
        await store.submit(source: source, mode: .continueSession, session: session, model: nil, prompt: "First send.")
        if let receipt = store.receipts.first { store.simulate(receiptID: receipt.id, outcome: "completed") }
        let later = [fixtures.appendingPathComponent("Bottle POS pricing page export.pdf"), fixtures.appendingPathComponent("Screenshot 2026-09-30 at 9.41.12 PM.png")]
        try pdf(later[0], pages: 3)
        _ = WorkCardFiles.writeImage(image(2880, 1800, 0.4), to: later[1], type: .png)
        await files.intake(urls: later, source: source)
        await files.waitForCompanions()
        draft = store.draft(for: source); draft.mode = .continueSession; draft.sessionID = session.id
        _ = store.updateDraft(draft, for: source)
        try render(WorkCardFilesSection(files: files, store: store, source: source, mode: .continueSession, sessionID: session.id,
                                        sessionTitle: session.title, provider: "claude", resendAll: .constant(false)).padding(18),
                   width: 440, name: "workspace-continue-delta", out: out)
        // Fix pass 1: a removed file shows Undo, and a companion that failed leaves the copy Ready with its own note.
        if let pdf = files.files(for: source.id).first(where: { $0.kind == "pdf" }), let folder = files.folder(for: source.id) {
            try WorkCardFiles.update(root: folder.deletingLastPathComponent(), workID: source.id) { manifest, _ in
                guard let index = manifest.files.firstIndex(where: { $0.id == pdf.id }) else { return }
                manifest.files[index].companions[0].state = "failed"; manifest.files[index].companions[0].failure = "this PDF has no text layer (a scan)"
            }
            files.reload(source.id)
        }
        if let shot = files.files(for: source.id).first(where: { $0.display.hasPrefix("Screenshot") }) { files.remove(shot.id, workID: source.id) }
        try render(WorkCardFilesSection(files: files, store: store, source: source, mode: .newSession, sessionID: nil,
                                        sessionTitle: nil, provider: "claude", resendAll: .constant(false)).padding(18),
                   width: 440, name: "workspace-undo-and-note", out: out)
        // The Start sheet's files row, and the lines that stop its countdown.
        let plan = WorkSendPlan(mode: .newSession, session: nil, model: store.models.first { $0.provider == "ollama" }, crossPlatform: false, prompt: "x")
        try render(VStack(alignment: .leading, spacing: 12) {
            WorkStartFilesRow(files: files, store: store, source: source, plan: plan)
            WorkStartFileAlerts(lines: [WorkCardFiles.localModelWarning])
        }.padding(18), width: 600, name: "start-sheet-files", out: out)
        // The board, card face A.
        let model = ControllerModel(startBackgroundWork: false)
        let board = WorkWorkspaceView(model: model, handoffStore: store, reviewStore: WorkWorkspaceProjection.previewReviewStore(),
                                      state: WorkWorkspaceState(), onOpenSession: { _ in }, onEditTask: { _ in }, onReviewMeeting: { _ in })
        try render(board, width: 1500, height: 900, name: "board", out: out)
        files.flash([.secret(".env")], on: source.id)
        try render(board, width: 1500, height: 900, name: "board-refusal", out: out)
        // 0.5.258: files on a meeting. A slide with words (Vision reads them on this Mac), a PDF, and a screenshot whose
        // words read like a credential (kept, marked, sent nowhere); then the same files in a linked card's send.
        let meetings = store.meetingFiles
        let key = "g2:meeting_1790800343639_lfbilg"
        let info = WorkMeetingInfo(recordId: "ops:quilt:2026-09:2026-09-30_Marketing_Performance_and_Planning_Review.md",
                                   title: "Marketing Performance and Planning Review", date: "2026-09-30")
        let slide = fixtures.appendingPathComponent("Q3 pipeline slide.png")
        try textPNG(slide, lines: ["Q3 pipeline review", "Grocery opportunities up 18 percent", "Liquor demos flat"])
        let deck = fixtures.appendingPathComponent("Planning deck.pdf")
        try pdf(deck, pages: 6)
        let secret = fixtures.appendingPathComponent("Env screenshot.png")
        try textPNG(secret, lines: ["OPENAI_API_KEY=sk-proj-Zq8vT41mWb2LxR9kHn3P", "deploy notes"])
        await meetings.intakeMeeting(urls: [slide, deck, secret], key: key, info: info)
        await meetings.waitForCompanions()
        print("meeting files: \(meetings.meetingFiles(keys: [key]).map { "\($0.file.display) [\($0.file.companions.map { "\($0.kind):\($0.state)" })]" })")
        try render(MeetingFilesSection(files: meetings, keys: [key], supported: true, ambiguous: false, reason: "", info: info).padding(18),
                   width: 712, name: "meeting-files", out: out)
        try render(VStack(alignment: .leading, spacing: 12) {
            MeetingFilesSection(files: meetings, keys: [], supported: nil, ambiguous: false, reason: "", info: info)
            MeetingFilesSection(files: meetings, keys: [key], supported: false, ambiguous: true, reason: "ambiguous", info: info)
            MeetingFilesSection(files: meetings, keys: [], supported: false, ambiguous: false, reason: "read_only_record", info: info)
        }.padding(18), width: 712, name: "meeting-files-states", out: out)
        let ref = WorkMeetingReference(.object(["recordId": .string(info.recordId), "domain": .string("quilt"), "month": .string("2026-09"),
                                                "filename": .string("2026-09-30_Marketing_Performance_and_Planning_Review.md"), "title": .string(info.title)]))!
        files.meetingGroups = { _ in meetings.meetingGroups(for: [ref]) { _ in [key] } }
        try render(WorkCardFilesSection(files: files, store: store, source: source, mode: .newSession, sessionID: nil,
                                        sessionTitle: nil, provider: "claude", resendAll: .constant(false)).padding(18),
                   width: 440, name: "workspace-with-meeting-files", out: out)
        try render(WorkStartFilesRow(files: files, store: store, source: source, plan: plan).padding(18), width: 600, name: "start-sheet-with-meeting-files", out: out)
        print("wrote PNGs to \(out.path)")
    }

    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, name: String, out: URL) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingView(rootView: view.frame(width: width).frame(height: height).background(COSPalette.panel))
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height ?? 1600), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            let size = height.map { NSSize(width: width, height: $0) } ?? host.fittingSize
            host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: max(size.height, 40)))
            for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png"))
            window.close()
        }
    }

    /// A PNG with real words on it, for Vision to read.
    static func textPNG(_ url: URL, lines: [String]) throws {
        let w = 1600, h = 140 + lines.count * 100
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica" as CFString, 60, nil)
        for (index, line) in lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                     NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)])
            context.textPosition = CGPoint(x: 50, y: CGFloat(h - 110 - index * 100))
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        _ = WorkCardFiles.writeImage(context.makeImage()!, to: url, type: .png)
    }

    static func image(_ w: Int, _ h: Int, _ hue: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: hue, green: 0.4, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()!
    }
    static func pdf(_ url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Korona pricing page \(page)", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            context.textPosition = CGPoint(x: 20, y: 100); CTLineDraw(line, context); context.endPDFPage()
        }
        context.closePDF()
    }
    static func makeFixtures(_ dir: URL) async throws -> [URL] {
        let pdfURL = dir.appendingPathComponent("Korona vs Bottle POS pricing.pdf"); try pdf(pdfURL, pages: 14)
        let heic = dir.appendingPathComponent("IMG_4821.HEIC"); _ = WorkCardFiles.writeImage(image(4032, 3024, 0.7), to: heic, type: .heic)
        let video = dir.appendingPathComponent("Demo walkthrough.mp4"); try await movie(video)
        let folder = dir.appendingPathComponent("bottle-pos-brand-assets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<38 { try Data("asset \(index)".utf8).write(to: folder.appendingPathComponent("asset-\(index).svg")) }
        return [pdfURL, heic, video, folder]
    }
    static func movie(_ url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input); _ = writer.startWriting(); writer.startSession(atSourceTime: .zero)
        for index in 0..<140 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, []); memset(CVPixelBufferGetBaseAddress(buffer!), Int32(index % 255), CVPixelBufferGetDataSize(buffer!)); CVPixelBufferUnlockBaseAddress(buffer!, [])
            _ = adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(index), timescale: 1))
        }
        input.markAsFinished()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
    }
}
