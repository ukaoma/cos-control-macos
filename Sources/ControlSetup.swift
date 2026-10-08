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
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 680))
            window.isReleasedWhenClosed = false
            window.center()
            controller = NSWindowController(window: window)
        }
        // The same window is the setup guide once COS is set up (Dock menu, Help, the panel, the pet).
        controller?.window?.title = model.status.needsFirstRun || !model.status.running ? "Welcome to COS" : "COS setup guide"
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
                Text(ready && !model.permissionGuide.onboardingDone
                     ? "COS is running. Before you start, choose what it can do on this Mac."
                     : ready
                     ? "Start with a task in your AI app. Open Sessions in COS to follow its progress and continue the conversation."
                     : "COS brings your AI sessions, meetings and work together. We’ll prepare what it needs on this Mac.")
                    .foregroundStyle(.secondary)
                if ready && !model.permissionGuide.onboardingDone {
                    // After Connect your AI and Get started: what this Mac can allow. Skippable.
                    OnboardingPermissionsStep(guide: model.permissionGuide) { model.objectWillChange.send() }
                } else if ready {
                    Button("Open Sessions") { model.openActivity?(.sessions) }
                        .buttonStyle(COSPrimaryButtonStyle())
                    PetIntroLine(model: model)
                    // The setup guide: every AI and the settings that go with it, each skippable and resumable here.
                    Text("Finish setting up").font(COSType.body(18, weight: .semibold))
                    Text("Skip anything for now. This guide stays in the Dock menu, Help, the menu-bar panel and the pet's menu.")
                        .font(COSType.body(13)).foregroundStyle(.secondary)
                    SetupGuideView(model: model, provider: model.providerGuide, guide: model.setupGuide, permissions: model.permissionGuide)
                } else if model.status.needsFirstRun {
                    // Connect your AI (onboarding P1): per provider, installed and signed in, with Sign in, Skip for now
                    // and Pass to an AI app. Get started's hard gate is unchanged from 0.5.267 (installed).
                    ConnectYourAIStep(guide: model.providerGuide,
                                      setupProviderInstalled: model.status.setupProviderInstalled,
                                      busy: model.busy, failed: model.error != nil,
                                      recheckGate: { if !model.busy { Task { await model.refresh(quiet: true) } } },
                                      getStarted: { model.perform("setup") })
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
