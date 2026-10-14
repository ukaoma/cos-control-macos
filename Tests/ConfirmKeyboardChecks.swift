import SwiftUI
import AppKit

@MainActor final class ConfirmationProbe: ObservableObject {
    @Published var shown = true
    @Published var busy = false
    var saves = 0
    var cancels = 0
    var background = 0
}
struct ConfirmationProbeView: View {
    @ObservedObject var probe: ConfirmationProbe
    var body: some View {
        VStack {
            Button("Background") { probe.background += 1 }.keyboardShortcut(.defaultAction)
            TextEditor(text: .constant("Text"))
        }.frame(width: 390, height: 260)
        .cosConfirm("Save?", isPresented: $probe.shown, message: "Keyboard canary", actions: [
            .normal("Save") { probe.saves += 1 },
            .cancel { probe.cancels += 1 }
        ]).disabled(probe.busy)
    }
}
@main @MainActor struct ConfirmKeyboardChecks {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let probe = ConfirmationProbe()
        let host = NSHostingView(rootView: ConfirmationProbeView(probe: probe))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 390, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        func settle() async throws { for _ in 0..<10 { try await Task.sleep(for: .milliseconds(20)); host.layoutSubtreeIfNeeded() } }
        func key(_ text: String, code: UInt16) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            return window.performKeyEquivalent(with: event)
        }
        try await settle()
        precondition(key("\r", code: 36), "Confirmation must handle Return")
        try await settle()
        precondition(probe.saves == 1 && !probe.shown && probe.background == 0, "Return must confirm once, not background action")
        probe.shown = true; probe.busy = true; try await settle()
        _ = key("\r", code: 36); try await settle()
        precondition(probe.saves == 1 && probe.background == 0 && probe.shown, "Disabled confirmation must ignore Return")
        probe.busy = false; try await settle()
        precondition(key("\u{1b}", code: 53), "Confirmation must handle Escape")
        try await settle()
        precondition(probe.cancels == 1 && probe.saves == 1 && !probe.shown, "Escape cancels without saving")
        window.close()
        print("PASS: actual COSConfirm Return, disabled guard, Escape and background action isolation")
    }
}
