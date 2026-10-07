import AppKit
import SwiftUI

/// 0.5.259, run by hand (Tests/run-speakers-header-render.sh <folder> <fixtures>): the Speakers meeting review header with
/// Open meeting beside Summary, Full and Next to name, in dark and light, at the Activity detail width and a narrow one,
/// plus the amber line a miss leaves. The review and its write-up load through the real path from a stand-in helper that
/// serves saved helper answers (QA U-N13, 2026-10-07). No window is ordered in and nothing is clicked.
@main @MainActor struct SpeakersHeaderRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard let session = ProcessInfo.processInfo.environment["COS_RENDER_SESSION"], !session.isEmpty else {
            fputs("COS_RENDER_SESSION is not set: run Tests/run-speakers-header-render.sh\n", stderr); exit(2)
        }
        let model = ControllerModel(startBackgroundWork: false)
        model.openSpeakerReview(sessionId: session)
        for _ in 0..<200 where model.openReview == nil || model.openContent == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(model.openReview != nil, "the stand-in helper did not load the review: \(model.reviewError ?? "?")")
        precondition(model.openContent != nil, "the stand-in helper did not load the write-up")
        func pane() -> some View {
            SpeakerReviewPane(model: model, showsBackButton: false, onNextUnnamed: {}, nextUnnamedAvailable: true, onOpenMeeting: {})
        }
        try render(pane(), width: 920, height: 300, name: "speakers-header-wide", out: out)
        try render(pane(), width: 600, height: 300, name: "speakers-header-narrow", out: out)
        model.openMeetingNote = SpeakersMeetingLink.missNote([.failed("Request failed (502)")])
        try render(pane(), width: 920, height: 300, name: "speakers-header-miss", out: out)
    }

    static func settle(_ host: NSView, seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
    }

    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, out: URL) throws {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .top).background(COSPalette.panel))
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
            settle(host, seconds: 2)
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png"))
            window.close()
        }
    }
}
