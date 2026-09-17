import AppKit
import SwiftUI
import Foundation

/// Offscreen native render of the 0.5.234 pet composer card, LIGHT AND DARK, in the
/// four phases a send passes through: a draft in the field, in flight (the chip is
/// out of the field, the button is a ring), landed (check, gold edge, status line),
/// and refused (amber copy, text back in the field, the way to the session view).
/// Plus the RUNNING list at rest with the wider four-glyph slot. Same harness shape
/// as MarkdownPaneUI. Run by hand on a logged-in Mac:
///     ./Tests/run-pet-composer-ui.sh /tmp/cos-pet-composer-ui
/// Asserts: each render is not blank, the draft is in the field, in flight the field
/// is empty and disabled, the refused phase put the text back in the field, and the
/// column never grows past the window it is given. Plain SwiftUI Text is not
/// enumerable offscreen (only text fields are), so the target line and the status
/// copy are judged from the PNGs, not from strings.
@main @MainActor
struct PetComposerUIContract {
    static func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.16)) }

    static func render<V: View>(
        _ view: V, size: NSSize, name: String, output: URL, dark: Bool
    ) throws -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // A busy desktop stand-in, so the material surfaces are judged over
        // something other than flat white.
        window.backgroundColor = dark ? NSColor(calibratedRed: 0.16, green: 0.14, blue: 0.20, alpha: 1)
                                      : NSColor(calibratedRed: 0.92, green: 0.78, blue: 0.36, alpha: 1)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        window.orderFrontRegardless()
        pump(); host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); pump(); pump()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fatalError("No native bitmap for \(name)")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG for \(name)") }
        try png.write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        precondition(host.bounds.width <= size.width && host.bounds.height <= size.height,
                     "the pet column escaped its window in \(name): \(host.bounds.size) vs \(size)")
        precondition(png.count > 5000, "native render of \(name) came out blank")
        return host
    }

    static func strings(_ view: NSView) -> [String] {
        var out: [String] = []
        if let field = view as? NSTextField { out.append(field.stringValue); out.append(field.placeholderString ?? "") }
        if let text = view as? NSTextView { out.append(text.string) }
        for sub in view.subviews { out.append(contentsOf: strings(sub)) }
        return out
    }

    static func session(_ id: String, provider: String, name: String, state: String) -> ClaudeSession {
        guard let s = ClaudeSession(.object([
            "id": .string(id), "sessionId": .string(id), "provider": .string(provider),
            "name": .string(name), "workspace": .string("MU-Chief-Staff"),
            "state": .string(state), "alive": .bool(true), "waitingFor": .string(""),
            "createdAt": .string("2026-09-17T18:40:00Z"), "updatedAt": .string("2026-09-17T18:58:00Z"),
            "discussionSummary": .string("Wiring the pet composer into the binding routes"),
        ])) else { fatalError("session fixture failed to parse") }
        return s
    }

    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/cos-pet-composer-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let model = ControllerModel(startBackgroundWork: false)
        precondition(!model.backgroundWorkEnabled)
        let presenter = SessionPetPresenter()
        let claude = session("11111111-1111-4111-8111-111111111111", provider: "claude",
                             name: "COS Control 0.5.234 pet composer", state: "running")
        let codex = session("codex-2026-09-17-abc", provider: "codex",
                            name: "Homepage 3D hardware pass", state: "running")
        model.petEnabled = true
        model.petSessions = [claude, codex]
        // The gate the row reads: the server publishes the providers it binds.
        model.status = ServerStatus([
            "threadAttachSupported": .bool(true), "threadAttachEnabled": .bool(true),
            "threadAttachProviders": .array([.string("claude"), .string("codex"), .string("cursor")]),
        ])
        precondition(model.canMessagePetSession(claude) && model.canMessagePetSession(codex),
                     "both live rows must offer the message path against a binding server")
        let size = NSSize(width: 412, height: 640)

        for dark in [false, true] {
            // RUNNING list at rest: two rows, the wider slot.
            model.petComposeTarget = nil
            model.petExpanded = true
            _ = try render(SessionPetCanary.column(model: model, presenter: presenter),
                           size: size, name: "pet-list", output: output, dark: dark)

            // 1. A draft in the field.
            model.petExpanded = false
            model.petComposeTarget = claude
            model.petSendPhase = .idle
            model.petSentText = nil
            model.petComposeDraft = "Ship the pet composer once the harness renders clean."
            // The probe saw a busy thread: the hint says the message will queue.
            model.petComposeHint = ControllerModel.petParkHint(for: claude)
            let draft = try render(SessionPetCanary.column(model: model, presenter: presenter),
                                   size: size, name: "pet-composer-draft", output: output, dark: dark)
            let draftStrings = strings(draft).joined(separator: "\n")
            precondition(draftStrings.contains("Ship the pet composer"), "the draft is not in the field")
            precondition(draftStrings.contains("Message this Claude session"), "the field placeholder does not name the provider")

            // 2. In flight: the text left the field, the button is a ring.
            model.petSentText = model.petComposeDraft
            model.petComposeDraft = ""
            model.petSendPhase = .sending
            let sending = try render(SessionPetCanary.column(model: model, presenter: presenter),
                                     size: size, name: "pet-composer-sending", output: output, dark: dark)
            precondition(!strings(sending).joined(separator: "\n").contains("Ship the pet composer"),
                         "in flight, the text must have left the field")

            // 3. Landed.
            model.petSendPhase = .landed("Landed in the live session.")
            _ = try render(SessionPetCanary.column(model: model, presenter: presenter),
                           size: size, name: "pet-composer-landed", output: output, dark: dark)

            // 4. Refused, on the Codex row: copy verbatim, text back in the field.
            model.petComposeTarget = codex
            model.petComposeDraft = "Ship the pet composer once the harness renders clean."
            model.petSentText = nil
            model.petSendPhase = .failed("Another app on this Mac has this thread open and is working. Wait, or fork it.")
            let failed = try render(SessionPetCanary.column(model: model, presenter: presenter),
                                    size: size, name: "pet-composer-failed", output: output, dark: dark)
            let failedStrings = strings(failed).joined(separator: "\n")
            precondition(failedStrings.contains("Ship the pet composer"), "the refused text did not return to the field")
            precondition(failedStrings.contains("Message this Codex session"), "the refused card lost its Codex target")
        }
        print("COS Control: pet composer renders in four phases, light and dark; list slot holds four glyphs")
    }
}
