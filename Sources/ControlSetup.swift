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
                let firstRun = model.status.needsFirstRun
                // The Permissions step belongs to the first-run sequence (Get started, then this). Upgraders and anyone
                // reopening the guide get the guide, which has a Permissions row (QA 2026-10-08 W6).
                let permissionsStep = ready && !model.permissionGuide.onboardingDone && model.firstRunPresentedThisLaunch
                Image(systemName: ready ? "checkmark.circle" : "sparkles")
                    .font(.system(size: 32)).foregroundStyle(COSPalette.accent)
                Text(firstRun ? "Your work, with you." : ready ? "COS is ready on this Mac" : "COS setup guide")
                    .font(COSType.body(28, weight: .semibold))
                Text(permissionsStep
                     ? "COS is running. Before you start, choose what it can do on this Mac."
                     : firstRun
                     ? "COS brings your AI sessions, meetings and work together. We’ll prepare what it needs on this Mac."
                     : ready
                     ? "Start with a task in your AI app. Open Sessions in COS to follow its progress and continue the conversation."
                     : "Everything COS can use on this Mac, one row each. COS is not running right now; its status is in the menu-bar panel.")
                    .foregroundStyle(.secondary)
                if permissionsStep {
                    // After Connect your AI and Get started: what this Mac can allow. Skippable.
                    OnboardingPermissionsStep(guide: model.permissionGuide) { model.objectWillChange.send() }
                } else if firstRun {
                    // Connect your AI (onboarding P1): per provider, installed and signed in, with Sign in, Skip for now
                    // and Pass to an AI app. Get started's hard gate is unchanged from 0.5.267 (installed).
                    ConnectYourAIStep(guide: model.providerGuide,
                                      setupProviderInstalled: model.status.setupProviderInstalled,
                                      busy: model.busy, failed: model.error != nil,
                                      recheckGate: { if !model.busy { Task { await model.refresh(quiet: true) } } },
                                      getStarted: { model.perform("setup") })
                } else {
                    HStack(spacing: 14) {
                        if ready {
                            Button("Open Sessions") { model.openActivity?(.sessions) }
                                .buttonStyle(COSPrimaryButtonStyle())
                        }
                        if model.status.transactionPending && !model.busy {
                            Button("Repair setup") { model.perform("repair") }
                        }
                        if !ready && !model.busy {
                            Button("Refresh status") { Task { await model.refresh() } }
                        }
                        Button("Open settings") { model.showSettings?() }
                            .buttonStyle(COSTextButtonStyle())
                    }
                    PetIntroLine(model: model)
                    // The setup guide: every AI and the settings that go with it, each skippable and resumable here.
                    Text("Finish setting up").font(COSType.body(18, weight: .semibold))
                    Text("Skip anything for now. This guide stays in the Dock menu, Help, the menu-bar panel and the pet's menu.")
                        .font(COSType.body(13)).foregroundStyle(.secondary)
                    SetupGuideView(model: model, provider: model.providerGuide, guide: model.setupGuide, permissions: model.permissionGuide)
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
                if model.status.needsFirstRun {
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
