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

    func applicationWillFinishLaunching(_ notification: Notification) {
        DockPresence.apply(DockPresence.mode(stored: UserDefaults.standard.string(forKey: DockPresence.modeKey)))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.onReopen?()
        return false
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
                Text(provider == .claude ? "Sign in so Sessions and Continue work. In Terminal, run this, then type /login:"
                     : "Sign in so Sessions and Continue work. In Terminal, run:")
                    .font(COSType.body(11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ProviderCommandLine(command: command) { guide.copy(command) }
        }
        HStack(spacing: 12) {
            if row.waiting {
                Button("Open Terminal again") { guide.signIn(provider) }.buttonStyle(COSQuietButtonStyle())
                Button("Stop waiting") { guide.stopWaiting(provider) }.buttonStyle(COSTextButtonStyle())
            } else {
                Button("Sign in") { guide.signIn(provider) }.buttonStyle(COSPrimaryButtonStyle())
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
        .onChange(of: guide.report) { _, report in
            let anyInstalled = AIProvider.agents.contains { report?.status($0)?.installed == true }
            if anyInstalled && !setupProviderInstalled { recheckGate() }
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
                Text("Connect your AI").font(COSType.display(13, weight: .semibold))
                Text(guide.summary).font(COSType.body(11)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { guide.closePanelRoute() }.buttonStyle(COSTextButtonStyle())
            }
            Text("Each AI you sign in to can run your sessions. COS checks again on its own while this is open.")
                .font(COSType.body(11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ProviderConnectList(guide: guide)
            if let notice = guide.notice {
                Text(notice).font(COSType.body(11)).foregroundStyle(COSPalette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = guide.error {
                Text(error).font(COSType.body(11)).foregroundStyle(COSPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            JevGuideRow(model: model)
            Divider()
            GlassesGuideRow(openURL: { _ = guide.openURL($0) })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
        .providerPolling(guide)
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
                        Label("AI apps", systemImage: "sparkles")
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
                .help("Which AI apps COS can use, and one click to sign in to each")
                // One read for the summary; no polling until the card is open.
                .task { if guide.report == nil { await guide.refresh() } }
            }
        }
    }
}

/// F6: whether Work's Jev key is set (the key itself is never read), where to get one and what it unlocks.
struct JevGuideRow: View {
    @ObservedObject var model: ControllerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Jev (TypeSafe)").font(COSType.body(12.5, weight: .semibold))
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    Circle().fill(model.jevStatus?.configured == true ? COSPalette.green : COSPalette.muted).frame(width: 7, height: 7)
                    Text(GuideExtras.jevStatus(configured: model.jevStatus?.configured, available: model.jevStatus?.available,
                                               serverRunning: model.status.running))
                        .font(COSType.body(11)).foregroundStyle(model.jevStatus?.configured == true ? COSPalette.green : COSPalette.muted)
                }.fixedSize()
            }
            Text("Optional. Unlocks Work's suggestions: Continue, Fork or New for a task, and sorting meetings into Intake. Paste a key in Settings, under Jev (TypeSafe).")
                .font(COSType.body(11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.jevStatus?.configured != true {
                Button("Get a key at typesafe.ai") { NSWorkspace.shared.open(GuideExtras.typesafeURL) }
                    .buttonStyle(COSTextButtonStyle())
            }
        }
        .padding(.vertical, 7)
        .task { if model.jevStatus == nil, model.status.running { await model.loadJevStatus() } }
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
