import SwiftUI
import AppKit

/// A real window, not a MenuBarExtra sheet that disappears as soon as a user
/// switches to their AI app to sign in. Closing it never cancels installation.
@MainActor
final class SetupWindowPresenter: ObservableObject {
    private var controller: NSWindowController?

    func show(model: ControllerModel) {
        if controller == nil {
            let host = NSHostingController(rootView: ControlSetupView(model: model))
            let window = NSWindow(contentViewController: host)
            window.title = "Welcome to COS"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 540, height: 540))
            window.isReleasedWhenClosed = false
            window.center()
            controller = NSWindowController(window: window)
        }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ControlSetupView: View {
    @ObservedObject var model: ControllerModel

    private var ready: Bool {
        model.status.running && model.status.ownershipVerified
            && model.status.runtimeState == "managedHealthy"
            && !model.status.transactionPending && !model.busy
    }

    private var progressMessage: String {
        let message = model.operationProgress ?? "Checking your Mac…"
        if message.contains("Resolving npm") { return "Checking for COS updates…" }
        if message.hasPrefix("Downloading server") { return "Downloading COS components…" }
        if message == "Verifying staged package…" { return "Checking the download…" }
        if message == "Starting managed server…" || message == "Starting setup…" { return "Starting COS…" }
        if message.hasPrefix("Proving ") { return "Checking your AI connection…" }
        return message
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: ready ? "checkmark.circle" : "sparkles")
                    .font(.system(size: 32)).foregroundStyle(COSPalette.accent)
                Text(ready ? "COS is ready on this Mac" : "Your work, with you.")
                    .font(COSType.body(28, weight: .semibold))
                Text(ready
                     ? "Start with a task in your AI app. Open Sessions in COS to follow its progress and continue the conversation."
                     : "COS brings your AI sessions, meetings and work together. We’ll prepare what it needs on this Mac.")
                    .foregroundStyle(.secondary)
                if ready {
                    Button("Open Sessions") { model.openActivity?(.sessions) }
                        .buttonStyle(COSPrimaryButtonStyle())
                    Text("Connect your meeting sources and glasses when you’re ready. Voice features have additional downloads.")
                        .font(COSType.body(13)).foregroundStyle(.secondary)
                } else if model.status.needsFirstRun {
                    if !model.status.setupProviderInstalled {
                        Text("Connect your AI").font(COSType.body(18, weight: .semibold))
                        Text("Install and sign in to Codex, Claude Code or Cursor Agent. COS uses your existing AI account. Then come back here.")
                        Link("Get Codex for Mac", destination: URL(string: "https://developers.openai.com/codex/app/")!)
                        Button("Check again") { Task { await model.refresh() } }
                            .disabled(model.busy)
                    } else {
                        Label("AI app found", systemImage: "checkmark.circle")
                        Text("Keep your AI app signed in. Get started downloads the COS components and starts them automatically. No Terminal or separate server setup.")
                        Button(model.error == nil ? "Get started" : "Try again") { model.perform("setup") }
                            .buttonStyle(COSPrimaryButtonStyle()).disabled(model.busy)
                    }
                } else if !model.busy {
                    Text("Your Mac has an existing COS setup. Review its status before making changes.")
                    Button("Refresh status") { Task { await model.refresh() } }
                    if model.status.transactionPending {
                        Button("Repair setup") { model.perform("repair") }
                    }
                }
                if model.busy {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(progressMessage)
                    }
                    Text("You can leave this window open while COS gets ready.")
                        .font(COSType.body(12)).foregroundStyle(.secondary)
                }
                if let error = model.error {
                    Text(error).foregroundStyle(COSPalette.danger).textSelection(.enabled)
                }
                if !ready {
                    Text("An internet connection is needed for setup. macOS asks for access when you use a feature that needs it.")
                        .font(COSType.body(12)).foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(COSType.body(15))
        .background(COSPalette.panel)
        .cosControlTheme()
    }
}
