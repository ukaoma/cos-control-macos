import AppKit
import SwiftUI

// Connect your AI's views (onboarding P1): the rows, the Welcome step, the card the menu-bar panel shows in place,
// and the small guide rows that sit with it (the session pet introduction, Jev, glasses). House rules: 390pt-safe, no
// eyebrow labels, no pill rows, inline cards and never sheets; a status is a dot and a word. Logic lives in
// ProviderConnectModel.swift.

extension DockPresence {
    /// Dock (a regular app) or menu bar only (an accessory app). The menu-bar icon is there either way.
    @MainActor static func apply(_ mode: Mode) {
        _ = NSApp.setActivationPolicy(mode == .dock ? .regular : .accessory)
    }
}

/// Receives the Dock click (and opening COS Control again from Finder or Spotlight) and applies the Dock setting at
/// launch. COSControlApp wires `onReopen`.
@MainActor
final class COSAppDelegate: NSObject, NSApplicationDelegate {
    static var onReopen: (@MainActor () -> Void)?
    static var onOpenActivity: (@MainActor () -> Void)?
    static var onSetupGuide: (@MainActor () -> Void)?
    static var onSettings: (@MainActor () -> Void)?

    /// Right-click on the Dock icon: Open Activity, Setup guide…, Settings….
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { Self.makeDockMenu(target: self) }
    @objc func dockOpenActivity() { Self.onOpenActivity?() }
    @objc func dockSetupGuide() { Self.onSetupGuide?() }
    @objc func dockSettings() { Self.onSettings?() }

    func applicationWillFinishLaunching(_ notification: Notification) {
        DockPresence.apply(DockPresence.mode(stored: UserDefaults.standard.string(forKey: DockPresence.modeKey)))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.onReopen?()
        return false
    }

    /// Cmd-Tab into COS Control with nothing on screen opens Activity, as a Dock click does. Checked a moment later,
    /// so the menu-bar panel opening (which also activates the app) is never mistaken for it.
    static var panelVisible: (@MainActor () -> Bool)?
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            let visible = NSApp.windows.filter { window in
                let name = String(describing: type(of: window))
                return window.isVisible && !(window is NSPanel) && window.level == .normal
                    && !name.contains("StatusBar") && !name.contains("MenuBarExtra")
            }.count
            let mode = DockPresence.mode(stored: UserDefaults.standard.string(forKey: DockPresence.modeKey))
            if DockPresence.openActivityOnActivate(mode: mode, visibleWindows: visible, panelVisible: Self.panelVisible?() ?? false) {
                Self.onReopen?()
            }
        }
    }
}

private func toneColor(_ tone: ProviderTone) -> Color {
    switch tone {
    case .good: COSPalette.green
    case .needsYou: COSPalette.amber
    case .neutral, .optional: COSPalette.muted
    }
}

struct ProviderStatusMark: View {
    let row: ProviderRowModel
    var body: some View {
        HStack(spacing: 5) {
            if row.waiting {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(toneColor(row.tone)).frame(width: 7, height: 7)
            }
            Text(row.status)
                .font(COSType.body(11, weight: row.tone == .needsYou ? .semibold : .regular))
                .foregroundStyle(row.tone == .good || row.tone == .needsYou ? toneColor(row.tone) : COSPalette.muted)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// A command with its Copy button. The text is selectable and wraps; nothing is truncated.
struct ProviderCommandLine: View {
    let command: String
    let copy: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(command)
                .font(COSType.mono(10.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                copy()
                copied = true
            }
            .buttonStyle(COSTextButtonStyle())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// One provider: its status, what to do next, the exact commands, and Pass to an installed AI app.
struct ProviderRowView: View {
    @ObservedObject var guide: ProviderGuide
    let provider: AIProvider

    var body: some View {
        let row = guide.row(provider)
        let status = guide.report?.status(provider)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(provider.title).font(COSType.body(12.5, weight: .semibold))
                Text(provider.cliName == provider.title ? "" : provider.cliName)
                    .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                Spacer(minLength: 6)
                ProviderStatusMark(row: row)
            }
            if let detail = row.detail {
                Text(detail)
                    .font(COSType.body(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider != .ollama, row.tone != .good, status != nil {
                Text(provider.usage).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch row.action {
            case .install: installSteps(status)
            case .signIn: signInSteps(status, row: row)
            case .none: EmptyView()
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func installSteps(_ status: ProviderLocalStatus?) -> some View {
        if let command = provider.installCommand {
            Text("Install it in Terminal, no administrator password needed:")
                .font(COSType.body(11)).foregroundStyle(.secondary)
            ProviderCommandLine(command: command) { guide.copy(command) }
        } else if provider == .codex {
            Text("Codex comes with the ChatGPT app for Mac. Install or update the app, then come back.")
                .font(COSType.body(11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 12) {
            Button("Get \(provider == .claude ? "Claude Code" : provider.appName)") {
                _ = guide.openURL(provider == .claude ? URL(string: "https://claude.com/product/claude-code")! : provider.downloadURL)
            }
            .buttonStyle(COSQuietButtonStyle())
            if provider != .ollama { passButton }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func signInSteps(_ status: ProviderLocalStatus?, row: ProviderRowModel) -> some View {
        if let command = ProviderLogin.command(provider, binaryPath: status?.binaryPath) {
            if !row.waiting {
                Text("Sign in so Sessions and Continue work. In Terminal, run:")
                    .font(COSType.body(11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProviderCommandLine(command: command) { guide.copy(command) }
        }
        HStack(spacing: 12) {
            if row.waiting {
                Button("Open Terminal again") { Task { await guide.signIn(provider) } }.buttonStyle(COSQuietButtonStyle())
                Button("Stop waiting") { guide.stopWaiting(provider) }.buttonStyle(COSTextButtonStyle())
            } else if guide.expired.contains(provider) {
                Button("Check again") { Task { await guide.checkAgain(provider) } }.buttonStyle(COSPrimaryButtonStyle())
                Button("Sign in") { Task { await guide.signIn(provider) } }.buttonStyle(COSQuietButtonStyle())
                Button("Skip for now") { guide.skip(provider) }.buttonStyle(COSTextButtonStyle())
            } else {
                Button("Sign in") { Task { await guide.signIn(provider) } }.buttonStyle(COSPrimaryButtonStyle())
                if row.canSkip {
                    Button("Skip for now") { guide.skip(provider) }.buttonStyle(COSTextButtonStyle())
                }
                passButton
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var passButton: some View {
        if provider != .ollama, let app = ProviderPass.target(for: provider, installedApps: guide.installedApps) {
            Button("Pass to \(app.appName)") {
                var generator = SystemRandomNumberGenerator()
                guide.pass(provider, to: app, tag: ProviderPass.newTag(using: &generator))
            }
            .buttonStyle(COSTextButtonStyle())
            .help("Opens a new \(app.appName) chat with COS's setup steps filled in. Nothing is sent until you press Send there.")
        }
    }
}

/// The rows, shared by the Welcome step and the panel card. Ollama is last and optional.
struct ProviderConnectList: View {
    @ObservedObject var guide: ProviderGuide
    var includeOllama = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array((includeOllama ? AIProvider.allCases : AIProvider.agents).enumerated()), id: \.element.id) { index, provider in
                if index > 0 { Divider() }
                ProviderRowView(guide: guide, provider: provider)
            }
        }
    }
}

/// Polls only while it is on screen (its own task ends when it goes away): every 3 s, backing off to 15 s, never past
/// 15 minutes. Reads the app list once on appear.
private struct ProviderPolling: ViewModifier {
    @ObservedObject var guide: ProviderGuide
    func body(content: Content) -> some View {
        content
            .task(id: guide.waiting.count) {
                guide.refreshApps()
                await guide.poll()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await guide.refresh() }
            }
    }
}

extension View {
    func providerPolling(_ guide: ProviderGuide) -> some View { modifier(ProviderPolling(guide: guide)) }
}

/// The Welcome window's Connect your AI step, before Get started.
struct ConnectYourAIStep: View {
    @ObservedObject var guide: ProviderGuide
    let setupProviderInstalled: Bool
    let busy: Bool
    let failed: Bool
    /// Re-reads Get started's gate (the helper's setupProviderInstalled) when a CLI appears while this is open.
    let recheckGate: () -> Void
    let getStarted: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your AI").font(COSType.body(18, weight: .semibold))
            Text("COS works through the AI plan you already have. Install one, then sign in, so Sessions and Continue work from the start.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ProviderConnectList(guide: guide)
                .padding(.horizontal, 14)
                .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
            if let notice = guide.notice {
                Text(notice).font(COSType.body(12)).foregroundStyle(COSPalette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = guide.error {
                Text(error).font(COSType.body(12)).foregroundStyle(COSPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !setupProviderInstalled {
                Text("Install Claude Code, Codex or Cursor Agent to continue. This list updates by itself.")
                    .font(COSType.body(12)).foregroundStyle(.secondary)
            } else if !guide.signInStepDone {
                Text("Sign in to each AI you installed, or choose Skip for now.")
                    .font(COSType.body(12)).foregroundStyle(.secondary)
            } else {
                Text("Get started downloads the COS components and starts them. No Terminal or separate server setup.")
                    .font(COSType.body(12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                // The hard gate is unchanged from 0.5.267: installed. Sign-in never disables Get started.
                if guide.signInStepDone {
                    Button(failed ? "Try again" : "Get started") { getStarted() }
                        .buttonStyle(COSPrimaryButtonStyle())
                        .disabled(!ProviderGate.getStartedEnabled(setupProviderInstalled: setupProviderInstalled, busy: busy))
                } else {
                    Button(failed ? "Try again" : "Get started") { getStarted() }
                        .buttonStyle(COSQuietButtonStyle())
                        .disabled(!ProviderGate.getStartedEnabled(setupProviderInstalled: setupProviderInstalled, busy: busy))
                }
                Button("Check again") { Task { await guide.refresh() } }
                    .buttonStyle(COSTextButtonStyle())
            }
        }
        .providerPolling(guide)
        // Re-read Get started's gate only when the set of installed CLIs changes, never on every poll.
        .onChange(of: Set(AIProvider.agents.filter { guide.report?.status($0)?.installed == true })) { _, installed in
            if !installed.isEmpty && !setupProviderInstalled { recheckGate() }
        }
    }
}

/// The card the menu-bar panel shows in place (its own route flag, `guide.panelRouteActive`, written only by
/// `openInPanel` and `closePanelRoute`).
struct ProviderConnectCard: View {
    @ObservedObject var guide: ProviderGuide
    @ObservedObject var model: ControllerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Setup guide").font(COSType.display(13, weight: .semibold))
                Text(SetupGuideRules.finishTitle(SetupGuideRules.rows(model.setupFacts(provider: guide, guide: model.setupGuide), skipped: model.setupGuide.skipped))
                        .replacingOccurrences(of: "Finish setup · ", with: ""))
                    .font(COSType.body(11)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { guide.closePanelRoute() }.buttonStyle(COSTextButtonStyle())
            }
            Text("Each AI you sign in to can run your sessions. Skip anything for now and come back here. COS checks again on its own while this is open.")
                .font(COSType.body(11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = guide.error {
                Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SetupGuideView(model: model, provider: guide, guide: model.setupGuide, permissions: model.permissionGuide)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
    }
}

/// The panel line ("AI apps · 1 needs you") that opens the card in place.
struct PanelConnectAIRow: View {
    @ObservedObject var guide: ProviderGuide
    @ObservedObject var model: ControllerModel

    var body: some View {
        Group {
            if guide.panelRouteActive {
                ProviderConnectCard(guide: guide, model: model)
            } else {
                Button { guide.openInPanel() } label: {
                    HStack(spacing: 8) {
                        Label("Setup guide", systemImage: "sparkles")
                            .font(COSType.body(12, weight: .medium))
                        Spacer(minLength: 6)
                        if guide.needCount > 0 {
                            Circle().fill(COSPalette.amber).frame(width: 7, height: 7)
                        }
                        Text(guide.summary)
                            .font(COSType.body(11.5, weight: guide.needCount > 0 ? .semibold : .regular))
                            .foregroundStyle(guide.needCount > 0 ? COSPalette.amber : Color.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Your AI apps, local voice and their settings, each with one click to set up")
                // One read for the summary; no polling until the card is open.
                .task { if guide.report == nil { await guide.refresh() } }
            }
        }
    }
}

/// F5: the glasses steps already on gotcos.com. No pairing logic here.
struct GlassesGuideRow: View {
    let openURL: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("COS Glasses").font(COSType.body(12.5, weight: .semibold))
            Text("Optional. If your Even G2 says something needs setup, follow the glasses steps: install the COS app on your phone, then pair it with this Mac.")
                .font(COSType.body(11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open the glasses steps") { openURL(GuideExtras.glassesWizardURL) }
                .buttonStyle(COSTextButtonStyle())
        }
        .padding(.vertical, 7)
    }
}

/// F4: one line that introduces the session pet, once, with Keep, Calm and Hide.
struct PetIntroLine: View {
    @ObservedObject var model: ControllerModel

    var body: some View {
        if model.petIntroVisible {
            VStack(alignment: .leading, spacing: 6) {
                Text("That small character by your windows is your session pet. It shows what your AI sessions are doing; click it to jump to one.")
                    .font(COSType.body(12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button("Keep") { model.answerPetIntro(.keep) }.buttonStyle(COSQuietButtonStyle())
                    Button("Calm") { model.answerPetIntro(.calm) }.buttonStyle(COSTextButtonStyle())
                        .help("Keep it, with gentler motion")
                    Button("Hide") { model.answerPetIntro(.hide) }.buttonStyle(COSTextButtonStyle())
                        .help("Turn the pet off. Settings, under Session pet, brings it back")
                    Spacer(minLength: 0)
                }
            }
            .padding(11)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line, lineWidth: 1))
        }
    }
}

/// The panel's "Agent CLIs" detail line, from local provider-status with the server's flags as the fallback.
struct AgentCliDetailLine: View {
    @ObservedObject var guide: ProviderGuide
    @ObservedObject var model: ControllerModel
    let allReady: Bool

    var body: some View {
        if let detail = text {
            Text(detail)
                .font(.caption2)
                .foregroundStyle(allReady ? .secondary : COSPalette.amber)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
    }

    private var text: String? {
        if let problem = AgentCliText.detail(
            server: [.claude: model.status.claudeCliReady, .codex: model.status.codexCliReady],
            cursorState: model.status.cursorState, local: guide.report) {
            return problem
        }
        var unknown: [String] = []
        if model.status.claudeCliReady == nil { unknown.append("Claude") }
        if model.status.codexCliReady == nil { unknown.append("Codex") }
        if !unknown.isEmpty { return "Unreported by this server: " + unknown.joined(separator: ", ") }
        var versions: [String] = []
        if let v = model.status.claudeCliVersion { versions.append("Claude \(v)") }
        if let v = model.status.codexCliVersion { versions.append("Codex \(v)") }
        if let v = model.status.cursorCliVersion { versions.append("Cursor \(v)") }
        return versions.isEmpty ? nil : versions.joined(separator: " · ")
    }
}

// MARK: - The setup guide (Miles 2026-10-08 10:52)

extension ControllerModel {
    /// What the setup guide's rows read, from the helper, the server's status and the permission guide.
    func setupFacts(provider: ProviderGuide, guide: SetupGuideState) -> SetupFacts {
        var facts = SetupFacts()
        facts.report = provider.report
        facts.providerSkipped = provider.skipped
        facts.serverRunning = status.running
        if var voice = guide.voice {
            voice.whisperReady = status.whisperReady
            voice.degraded = status.transcriptionTierDegraded
            voice.degradedReason = status.transcriptionTierReason
            voice.requestedTier = status.transcriptionRequestedTier
            voice.previewModel = status.livePreviewModel
            voice.commitModel = status.liveCommitModel
            voice.polishModel = status.hqPolishModel
            facts.voice = voice
        }
        facts.voiceTier = guide.voiceTier
        facts.voiceUnavailable = guide.voice == nil && guide.voiceReadFailed
        facts.whisperReady = status.whisperReady && !status.transcriptionTierDegraded
        facts.requestedTier = status.transcriptionRequestedTier
        facts.claudeSessionsEnabled = status.claudeSessionsEnabled
        facts.threadAttachSupported = status.threadAttachSupported
        facts.threadAttachEnabled = status.threadAttachEnabled
        facts.jevConfigured = jevStatus?.configured
        facts.permissionsNeedCount = permissionGuide.needCount
        facts.ollamaPinnedModel = status.ollamaConfiguredModel
        return facts
    }
}

/// One non-provider row: status, what it unlocks, one action, Skip for now.
struct SetupRowView: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var guide: SetupGuideState
    let row: SetupRow

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title).font(COSType.body(12.5, weight: .semibold))
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    if row.id == .voice && guide.voiceRunning { ProgressView().controlSize(.mini) }
                    else { Circle().fill(row.done ? COSPalette.green : row.skipped || row.afterSetup ? COSPalette.muted : COSPalette.amber).frame(width: 7, height: 7) }
                    Text(row.id == .voice && guide.voiceRunning ? "Downloading…" : row.skipped && !row.done ? "Skipped for now" : row.status)
                        .font(COSType.body(11, weight: row.done || row.skipped || row.afterSetup ? .regular : .semibold))
                        .foregroundStyle(row.done ? COSPalette.green : row.skipped || row.afterSetup ? COSPalette.muted : COSPalette.amber)
                }.fixedSize()
            }
            Text(row.unlocks).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let detail = row.detail {
                Text(detail).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
            if row.id == .voice { voiceControls }
            if !row.done && !row.afterSetup {
                HStack(spacing: 12) {
                    if let title = row.actionTitle, row.action != .none {
                        Button(title) { perform(row.action) }
                            .buttonStyle(COSPrimaryButtonStyle())
                            .disabled(row.id == .voice && guide.voiceRunning)
                    }
                    if row.id == .voice && guide.voiceRunning {
                        Button("Cancel") { guide.cancelVoiceSetup() }.buttonStyle(COSTextButtonStyle())
                    } else if !row.skipped {
                        Button("Skip for now") { guide.skip(row.id) }.buttonStyle(COSTextButtonStyle())
                    } else {
                        Button("Set up now") { guide.unskip(row.id) }.buttonStyle(COSTextButtonStyle())
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Balanced or Max in plain words, the exact whisper.cpp command, live progress, and the Terminal fallback.
    @ViewBuilder private var voiceControls: some View {
        if let progress = guide.voiceProgress, guide.voiceRunning {
            Text(progress).font(COSType.mono(10.5)).foregroundStyle(COSPalette.accent)
        }
        if let message = guide.voiceMessage {
            Text(message).font(COSType.body(10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if let recommendation = guide.voice?.recommendedTier {
            Text("Initial recommendation: \(VoiceTier.title(recommendation)). Based on speech processing speed; calibration on smaller Macs is still in progress.")
                .font(COSType.body(10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if row.done && !guide.voiceRunning {
            Button("Test this Mac again") { guide.startVoiceSetup() }.buttonStyle(COSTextButtonStyle())
        }
        if !row.done && !row.afterSetup, !guide.voiceRunning {
            VStack(alignment: .leading, spacing: 6) {
                COSViewSwitch("Voice", selection: $guide.voiceTier,
                              options: [COSViewOption("auto", "Automatic"), COSViewOption("balanced", "Balanced"), COSViewOption("max", "Max")], showsLabel: false)
                Text(guide.voiceTier == "auto" ? "Test this Mac and recommend a tier. An existing voice choice is always kept." : VoiceTier.explanation(guide.voiceTier)).font(COSType.body(10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let command = guide.voice?.terminalCommand[guide.voiceTier == "auto" ? "balanced" : guide.voiceTier] {
                    Button("Or run it in Terminal") {
                        let guideRef = model.providerGuide
                        Task {
                            if !(await guideRef.runInTerminal(ProviderLogin.terminalScript(command))) {
                                guideRef.copy(command)
                                _ = guideRef.openTerminalApp()
                                guide.voiceMessage = "COS could not type into Terminal. The command is on the clipboard: paste it into Terminal."
                            }
                        }
                    }
                    .buttonStyle(COSTextButtonStyle())
                    .disabled(guide.voiceRunning)
                    .help("Runs the same setup in Terminal (COS Control's helper, the installed server's own setup), for when you want to watch it")
                }
            }
        }
    }

    /// Every action a row can carry does something; `.none` rows show no button (QA 2026-10-08 B1: Get Ollama did not).
    private func perform(_ action: SetupAction) {
        switch action {
        case .none: break
        case .provider(let provider), .download(let provider): _ = model.providerGuide.openURL(provider.downloadURL)
        case .openOllama:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else { _ = model.providerGuide.openURL(AIProvider.ollama.downloadURL) }
        case .voiceNeedsWhisper: Task { await guide.refreshVoice() }
        case .voiceDownload: guide.startVoiceSetup()
        case .voiceApply(let tier): model.setTranscriptionTier(tier)
        case .turnOnSessions: model.setClaudeSessionsEnabled(true)
        case .turnOnContinue: model.setThreadAttachEnabled(true)
        case .addJevKey: model.showSettings?()
        case .openPermissions: model.permissionGuide.openInPanel()
        }
    }
}

/// The whole guide: your AI (the Connect your AI rows, with Sign in and Pass to), then local and voice, then the
/// settings that go with them. Every row can be skipped and set up later from here.
struct SetupGuideView: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var provider: ProviderGuide
    @ObservedObject var guide: SetupGuideState
    @ObservedObject var permissions: PermissionGuide

    var body: some View {
        let rows = SetupGuideRules.rows(model.setupFacts(provider: provider, guide: guide), skipped: guide.skipped)
        VStack(alignment: .leading, spacing: 10) {
            section("Your AI") {
                ForEach(Array(AIProvider.agents.enumerated()), id: \.element.id) { index, p in
                    if index > 0 { Divider() }
                    ProviderRowView(guide: provider, provider: p)
                    // Skip for now on every row that is not done and has no Skip of its own (not installed, could not check).
                    if let row = rows.first(where: { $0.id.rawValue == p.rawValue }), !row.done, provider.row(p).action != .signIn {
                        Button(row.skipped ? "Set up now" : "Skip for now") {
                            row.skipped ? provider.unskip(p) : provider.skip(p)
                        }
                        .buttonStyle(COSTextButtonStyle())
                        .padding(.bottom, 6)
                    }
                }
            }
            section("On this Mac") {
                ForEach(Array(rows.filter { [.ollama, .voice].contains($0.id) }.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    SetupRowView(model: model, guide: guide, row: row)
                }
            }
            section("Settings for your AI") {
                ForEach(Array(rows.filter { [.sessions, .continueThreads, .jev, .permissions].contains($0.id) }.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    SetupRowView(model: model, guide: guide, row: row)
                }
            }
            if let notice = provider.notice {
                Text(notice).font(COSType.body(11)).foregroundStyle(COSPalette.accent).fixedSize(horizontal: false, vertical: true)
            }
            GlassesGuideRow(openURL: { _ = provider.openURL($0) })
            HStack(spacing: 14) {
                if guide.hidden {
                    Button("Show Finish setup at the top again") { guide.show() }.buttonStyle(COSTextButtonStyle())
                } else {
                    Button("Hide setup guide") { guide.hide() }.buttonStyle(COSTextButtonStyle())
                        .help("Removes the Finish setup card. The guide stays in the Dock menu, the Help menu, the panel and the pet's menu")
                }
                Spacer(minLength: 0)
            }
        }
        .providerPolling(provider)
        .task {
            guide.adoptServerTier(guide.voice?.explicitTier)
            await guide.refreshVoice()
            if model.jevStatus == nil, model.status.running { await model.loadJevStatus() }
        }
        .onChange(of: guide.voice?.explicitTier) { _, tier in guide.adoptServerTier(tier) }
    }

    @ViewBuilder private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(COSType.body(13, weight: .semibold)).padding(.bottom, 2)
            VStack(alignment: .leading, spacing: 0) { content() }
                .padding(.horizontal, 12)
                .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line, lineWidth: 1))
        }
    }
}

/// "Finish setup · N of M" at the top of the panel and Activity home, until every row is done or skipped, or Hide.
struct FinishSetupCard: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var provider: ProviderGuide
    @ObservedObject var guide: SetupGuideState
    @ObservedObject var permissions: PermissionGuide
    let open: () -> Void

    var body: some View {
        // The facts load even while the card is hidden (it waits for them), so the load sits on a container that is
        // always there, not on the card.
        VStack(alignment: .leading, spacing: 0) { card }
            .task {
                if provider.report == nil { await provider.refresh() }
                if model.status.running, guide.voice == nil { await guide.refreshVoice() }
            }
    }

    @ViewBuilder private var card: some View {
        let facts = model.setupFacts(provider: provider, guide: guide)
        let rows = SetupGuideRules.rows(facts, skipped: guide.skipped)
        if SetupGuideRules.showFinishCard(rows, hidden: guide.hidden, loaded: SetupGuideRules.loaded(facts)) {
            let next = rows.first { !$0.handled && !$0.afterSetup }
            let p = SetupGuideRules.progress(rows)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(SetupGuideRules.finishTitle(rows)).font(COSType.display(13, weight: .semibold))
                    Spacer()
                    Button("Hide") { guide.hide() }.buttonStyle(COSTextButtonStyle())
                        .help("Hide the setup guide. Reopen it from the Dock menu, Help, the panel or the pet")
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(COSPalette.line)
                        Capsule().fill(COSPalette.accent).frame(width: geo.size.width * CGFloat(p.handled) / CGFloat(max(1, p.total)))
                    }
                }
                .frame(height: 4)
                if let next {
                    Text("Next: \(next.title). \(next.unlocks)").font(COSType.body(11)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Button("Continue setup") { open() }.buttonStyle(COSPrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.accent.opacity(0.55), lineWidth: 1))
        }
    }
}

/// The menu-bar icon, as macOS shows it now: Settings… clicks it only when it is really there (QA 2026-10-08 W2:
/// a full menu bar or the notch hides it, and a click on an open panel would close it).
@MainActor enum MenuBarPanelOpener {
    static func statusWindow() -> NSWindow? {
        NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBarWindow") }
    }

    static func statusItemFacts() -> SettingsRoute.StatusItem? {
        guard let window = statusWindow(), firstButton(in: window.contentView) != nil else { return nil }
        let frame = window.frame
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }
        var underNotch = false
        if let screen, screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            underNotch = frame.maxX > left.maxX && frame.minX < right.minX
        }
        return SettingsRoute.StatusItem(visible: window.isVisible && window.occlusionState.contains(.visible),
                                        onScreen: screen != nil && frame.width > 0, underNotch: underNotch)
    }

    static func clickStatusItem() -> Bool {
        guard let button = firstButton(in: statusWindow()?.contentView) else { return false }
        button.performClick(nil)
        return true
    }

    private static func firstButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for sub in view.subviews { if let found = firstButton(in: sub) { return found } }
        return nil
    }
}

/// A real Settings window: the menu-bar panel itself, hosted in an ordinary window and scrolled to its settings, so
/// "Show in menu bar only", the Jev key and every other setting are reachable with the menu-bar icon hidden.
@MainActor
final class SettingsWindowPresenter: ObservableObject {
    private var controller: NSWindowController?

    func show(model: ControllerModel, openActivity: @escaping (ActivitySection?) -> Void) {
        model.panelScrollTarget = "settings"
        if controller == nil {
            let host = NSHostingController(rootView: ControlPanel(model: model, openActivity: openActivity, hostedInWindow: true))
            let window = NSWindow(contentViewController: host)
            window.title = "COS Control Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            controller = NSWindowController(window: window)
        }
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Settings… from the Dock menu, ⌘, and the pet: the open panel scrolls, a visible icon opens the panel, anything
/// else gets the Settings window.
@MainActor enum SettingsOpener {
    static func open(model: ControllerModel, window: SettingsWindowPresenter, openActivity: @escaping (ActivitySection?) -> Void) {
        let target = SettingsRoute.decide(panelOpen: model.panelVisible, item: MenuBarPanelOpener.statusItemFacts())
        onboardingLog.info("settings opened target=\(String(describing: target), privacy: .public)")
        switch target {
        case .scrollOpenPanel: model.panelScrollTarget = "settings"
        case .clickStatusItem:
            model.panelScrollTarget = "settings"
            if !MenuBarPanelOpener.clickStatusItem() { window.show(model: model, openActivity: openActivity) }
        case .window: window.show(model: model, openActivity: openActivity)
        }
    }
}

/// F3 for upgraders: one line, once, saying COS Control is in the Dock now, with Menu bar only one click away.
struct DockNoticeLine: View {
    @ObservedObject var model: ControllerModel
    @State private var seen = UserDefaults.standard.bool(forKey: DockPresence.noticeSeenKey)

    var body: some View {
        if !seen, DockPresence.showUpgradeNotice(stored: UserDefaults.standard.string(forKey: DockPresence.modeKey),
                                                  seen: seen, firstRun: model.status.needsFirstRun || !model.statusReadOnce) {
            HStack(spacing: 10) {
                Text("COS Control is in the Dock now.").font(COSType.body(11.5)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Menu bar only") { model.setShowInDock(false); dismiss() }.buttonStyle(COSTextButtonStyle())
                Button("Keep") { model.setShowInDock(true); dismiss() }.buttonStyle(COSTextButtonStyle())
            }
        }
    }

    private func dismiss() {
        UserDefaults.standard.set(true, forKey: DockPresence.noticeSeenKey)
        seen = true
    }
}

extension COSAppDelegate {
    /// The Dock menu's items, in order. Built here so a check can read the titles without showing a menu.
    static let dockMenuTitles = ["Open Activity", "Setup guide…", "Settings…"]

    static func makeDockMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu()
        let actions: [Selector] = [#selector(COSAppDelegate.dockOpenActivity), #selector(COSAppDelegate.dockSetupGuide), #selector(COSAppDelegate.dockSettings)]
        for (title, action) in zip(dockMenuTitles, actions) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        return menu
    }
}
