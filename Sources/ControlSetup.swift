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
            window.contentMinSize = NSSize(width: 390, height: 440)
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
    @ObservedObject private var guide: SetupGuideState
    @ObservedObject private var permissions: PermissionGuide
    @AccessibilityFocusState private var stageFocused: Bool

    init(model: ControllerModel) {
        self.model = model
        self.guide = model.setupGuide
        self.permissions = model.permissionGuide
    }

    private var ready: Bool {
        model.status.running && model.status.ownershipVerified
            && model.status.runtimeState == "managedHealthy"
            && !model.status.transactionPending && !model.busy
    }

    private var stage: SetupJourneyStage {
        SetupJourneyStage.resolve(needsFirstRun: model.status.needsFirstRun, ready: ready,
                                  started: guide.journeyStarted, finished: guide.journeyFinished,
                                  permissionsDone: permissions.onboardingDone, path: guide.devicePath,
                                  glassesHandled: guide.glassesHandled)
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
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Color.clear.frame(height: 0).id("setup-top")
                    if let progress = stage.progress(path: guide.devicePath) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Step \(progress.step) of \(progress.total) · \(progress.title)")
                                .font(COSType.body(13)).foregroundStyle(.secondary)
                            ProgressView(value: Double(progress.step), total: Double(progress.total))
                                .tint(COSPalette.accent)
                                .accessibilityLabel("Setup progress")
                        }
                    }
                    stageContent
                    if model.busy {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text(progressMessage)
                        }
                        Text("You can close this window while COS gets ready. Reopen Setup guide from the COS menu.")
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
            .onChange(of: stage) { _, _ in
                scroll.scrollTo("setup-top", anchor: .top)
                stageFocused = true
            }
        }
        .font(COSType.body(15))
        .background(COSPalette.panel)
        .cosControlTheme()
    }

    @ViewBuilder private var stageContent: some View {
        switch stage {
        case .welcome:
            heading("Meet COS, your chief of staff.", detail: "Bring your AI conversations, work and meeting context together. Start with the devices you use.", symbol: "sparkles")
            SetupDeviceChoice(guide: guide)
            Text("Next, connect your AI and choose what COS can access. COS prepares its own components; you do not need Homebrew or a separate server setup.")
                .foregroundStyle(.secondary)
            Button("Get started") { guide.beginJourney() }
                .buttonStyle(COSPrimaryButtonStyle()).disabled(model.busy)
        case .connect:
            heading("Put your AI to work.", detail: "Connect an AI you already use. Its subscription and usage limits still apply.", symbol: "sparkles")
            ConnectYourAIStep(guide: model.providerGuide,
                              setupProviderInstalled: model.status.setupProviderInstalled,
                              busy: model.busy, failed: model.error != nil,
                              recheckGate: { if !model.busy { Task { await model.refresh(quiet: true) } } },
                              getStarted: { model.perform("setup") })
            Button("Back") { guide.backToWelcome() }
                .buttonStyle(COSTextButtonStyle()).disabled(model.busy)
        case .preparing:
            heading(model.busy ? "Getting COS ready." : "Let’s finish setting up.",
                    detail: model.busy ? "Once this Mac is ready, you can choose access and explore COS."
                        : "COS is not ready yet. Start it if stopped, repair an interrupted setup, or refresh its status. Settings has the full status and controls.",
                    symbol: "sparkles")
            recoveryActions
        case .permissions:
            heading("You choose the access.", detail: "COS is running on this Mac. Allow the features you want, or return to them later.", symbol: "hand.raised")
            OnboardingPermissionsStep(guide: model.permissionGuide) { model.objectWillChange.send() }
        case .glasses:
            heading("Bring COS to your glasses.", detail: "Connect your phone and Even G2 glasses to this Mac. This is optional; you can finish it from Setup guide later.", symbol: "eyeglasses")
            GlassesSetupRows(model: model, pairing: model.glassesPairing,
                             openURL: { _ = model.providerGuide.openURL($0) })
            Button("Open glasses setup guide") { _ = model.providerGuide.openURL(GuideExtras.glassesWizardURL) }
                .buttonStyle(COSTextButtonStyle())
            HStack(spacing: 14) {
                Button("Continue") { guide.finishGlassesStep() }.buttonStyle(COSPrimaryButtonStyle())
                Button("Set up later") { guide.finishGlassesStep() }.buttonStyle(COSTextButtonStyle())
            }
            Button("Use just my Mac") { guide.chooseDevicePath(.mac) }.buttonStyle(COSTextButtonStyle())
        case .ready:
            heading("Make yourself at home.", detail: "COS is ready on this Mac. Here are three places to start.", symbol: "checkmark.circle")
            firstSteps
            PetIntroLine(model: model)
            Button("Finish setup") { guide.finishJourney() }.buttonStyle(COSPrimaryButtonStyle())
            Text("Your setup guide stays in the Dock menu, Help, the menu-bar panel and the pet's menu.")
                .font(COSType.body(13)).foregroundStyle(.secondary)
        case .guide:
            heading(ready ? "COS is ready on this Mac" : "COS setup guide",
                    detail: "Change your setup or pick up anything you skipped. Your work stays available when you close this guide.",
                    symbol: ready ? "checkmark.circle" : "sparkles")
            recoveryActions
            if ready { firstSteps }
            PetIntroLine(model: model)
            Text("Finish setting up").font(COSType.body(18, weight: .semibold))
            Text("Skip anything for now. You can return to this guide whenever you need it.")
                .font(COSType.body(13)).foregroundStyle(.secondary)
            SetupGuideView(model: model, provider: model.providerGuide, guide: guide, permissions: permissions, pairing: model.glassesPairing)
        }
    }

    private func heading(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(COSPalette.accent)
            Text(title).font(COSType.display(28, weight: .semibold))
                .accessibilityAddTraits(.isHeader).accessibilityFocused($stageFocused)
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recoveryActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.status.runtimeState == "stopped" && !model.busy && !model.status.transactionPending {
                Button("Start COS") { model.perform("start") }.buttonStyle(COSPrimaryButtonStyle())
            }
            if model.status.transactionPending && !model.busy {
                Button("Repair setup") { model.perform("repair") }.buttonStyle(COSPrimaryButtonStyle())
            }
            HStack(spacing: 14) {
                if !ready && !model.busy {
                    Button("Refresh status") { Task { await model.refresh() } }.buttonStyle(COSTextButtonStyle())
                }
                Button("Open settings") { model.showSettings?() }.buttonStyle(COSTextButtonStyle())
            }
        }
    }

    private var firstSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            firstStep("Work", detail: "Review tasks and decide what needs your attention.", section: .work, symbol: "briefcase")
            firstStep("Sessions", detail: "Browse connected sessions. Session access and Continue are optional in Settings.", section: .sessions, symbol: "bubble.left.and.bubble.right")
            firstStep("Meetings", detail: "Find saved transcripts, summaries and supporting files.", section: .meetings, symbol: "calendar")
        }
    }

    private func firstStep(_ title: String, detail: String, section: ActivitySection, symbol: String) -> some View {
        Button {
            if stage == .ready { guide.finishJourney() }
            model.openActivity?(section)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).frame(width: 22).foregroundStyle(COSPalette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(COSType.body(15, weight: .semibold))
                    Text(detail).font(COSType.body(13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Open \(title). \(detail)")
    }
}
