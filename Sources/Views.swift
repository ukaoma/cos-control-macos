import SwiftUI
import AppKit

/// An NSColor that resolves differently in light vs dark appearance.
private func adaptiveNSColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
}

/// Appearance-adaptive backgrounds. Bg flips with the Mac's light/dark setting;
/// accents stay put (they read on both). Used by both SwiftUI (Color) and the
/// window backing (NSColor).
private enum COSInk {
    static let panelNS = adaptiveNSColor(
        light: NSColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1),   // cream
        dark:  NSColor(red: 0.09, green: 0.07, blue: 0.05, alpha: 1))   // espresso
    static let cardNS = adaptiveNSColor(
        light: NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),   // white
        dark:  NSColor(red: 0.15, green: 0.115, blue: 0.085, alpha: 1)) // dark card
    static let lineNS = adaptiveNSColor(
        light: NSColor(red: 0.45, green: 0.34, blue: 0.16, alpha: 0.20),
        dark:  NSColor(red: 0.79, green: 0.66, blue: 0.43, alpha: 0.16))
}

/// MenuBarExtra(.window) is a translucent vibrancy window by default, so the
/// desktop bleeds through. Make it opaque with an appearance-adaptive backing —
/// we do NOT force an appearance, so it follows the Mac's light/dark setting and
/// stays legible in both modes.
private struct WindowOpaquer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        window.isOpaque = true
        window.backgroundColor = COSInk.panelNS
        window.hasShadow = true
        opaquify(window.contentView)
    }
    private func opaquify(_ view: NSView?) {
        guard let view else { return }
        if let effect = view as? NSVisualEffectView { effect.alphaValue = 0 }
        for sub in view.subviews { opaquify(sub) }
    }
}

private enum COSPalette {
    static let ink = Color(red: 0.12, green: 0.09, blue: 0.07)   // dark brand tile (both modes)
    static let panel = Color(nsColor: COSInk.panelNS)            // adaptive
    static let card = Color(nsColor: COSInk.cardNS)              // adaptive
    static let line = Color(nsColor: COSInk.lineNS)              // adaptive
    static let cream = Color(red: 0.96, green: 0.94, blue: 0.90) // glasses mark on the ink tile
    static let amber = Color(red: 0.79, green: 0.50, blue: 0.27)
    static let green = Color(red: 0.20, green: 0.58, blue: 0.34)
}

struct ControlPanel: View {
    @ObservedObject var model: ControllerModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                statusCard
                controls
                recentGlassesCard
                if !model.doctorChecks.isEmpty { doctorCard }
                utilities
                footer
            }
            .padding(16)
        }
        .frame(width: 390, height: 640)
        .background(COSPalette.panel)
        .background(WindowOpaquer())
        .alert("COS Control", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(COSPalette.ink)
                Image(systemName: "eyeglasses").font(.title2).foregroundStyle(COSPalette.cream)
            }.frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("COS Control").font(.title3.weight(.semibold))
                Text("Your local glasses server").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh status")
        }
    }

    private var statusCard: some View {
        VStack(spacing: 9) {
            statusRow("Server", value: runtimeLabel, good: model.status.runtimeState == "managedHealthy")
            statusRow("Ownership", value: ownershipLabel, good: model.status.ownershipVerified)
            statusRow("Recovery", value: model.status.recoveryLoaded ? "Scheduled" : "Needs repair", good: model.status.recoveryInstalled && model.status.recoveryLoaded)
            statusRow("Local Whisper", value: model.status.whisperReady ? "Ready" : "Unavailable", good: model.status.whisperReady)
            statusRow("Cursor CLI", value: cursorLabel, good: model.status.cursorReady)
            statusRow("Version", value: model.status.runtimeState == "managedInPlace" ? "Self-managed" : (model.status.version ?? model.status.installedVersion ?? "Not installed"), good: model.status.installed || model.status.runtimeState == "managedInPlace")
            Divider()
            HStack(alignment: .top) {
                Text("Work folder").foregroundStyle(.secondary)
                Spacer()
                Text(model.status.workDirectory ?? "Default COS context")
                    .lineLimit(2).multilineTextAlignment(.trailing).textSelection(.enabled)
            }.font(.caption)
            if let jobs = model.status.activeJobs, let recordings = model.status.activeTranscriptionSessions, jobs + recordings > 0 {
                Label("\(jobs) job(s), \(recordings) recording(s) active. Restart is locked.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(COSPalette.amber)
            }
            if model.status.transactionPending {
                Label("An interrupted server change needs Repair.", systemImage: "wrench.and.screwdriver.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(13)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(COSPalette.line, lineWidth: 1))
    }

    private var controls: some View {
        VStack(spacing: 9) {
            HStack {
                if model.status.runtimeState == "managedHealthy" || model.status.runtimeState == "managedInPlace" {
                    Button("Restart", systemImage: "arrow.clockwise") { model.perform("restart") }
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { model.perform("stop") }
                } else if model.status.runtimeState == "stopped" {
                    Button("Start", systemImage: "play.fill") { model.perform("start") }.buttonStyle(.borderedProminent)
                }
                Spacer()
                if model.status.installed && model.status.managedContract && model.status.ownershipVerified {
                    Button("Update Server") { model.perform("update") }
                } else if !model.status.installed && model.status.runtimeState == "notInstalled" {
                    Button("Install Server") { model.installCurrentRelease() }.buttonStyle(.borderedProminent)
                }
            }
            .disabled(model.busy)
            if model.status.runtimeState == "legacyForeground" {
                Label("A foreground server owns the ports. Finish active work and stop it in Terminal before installing.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(COSPalette.amber)
            }
            if model.status.runtimeState == "legacyStopped" {
                HStack {
                    Label("A recognized stopped legacy LaunchAgent can be adopted exactly.", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Button("Adopt Safely") { model.perform("adopt", arguments: ["--version", ControllerModel.releaseServerVersion]) }
                }.font(.caption).foregroundStyle(COSPalette.amber)
            }
            if model.status.runtimeState == "legacyService" {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Your server is running. COS Control can manage it in place — status, restart, and recovery — without replacing it.", systemImage: "checkmark.seal")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Manage in place") { model.perform("adopt-in-place") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.status.ownerConflict {
                Label("Ownership conflict detected. COS Control will not stop or replace the unknown listener.", systemImage: "exclamationmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            if let progress = model.operationProgress {
                Text(progress).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let notice = model.notice {
                Text(notice).font(.caption).foregroundStyle(COSPalette.green).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var recentGlassesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { model.recentGlassesExpanded },
                    set: { model.setRecentGlassesExpanded($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(recentGlassesStatusLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Refresh") { Task { await model.refreshRecentMessages() } }
                            .controlSize(.mini)
                        Button("Copy handoff") { model.copyHandoff() }
                            .controlSize(.mini)
                            .disabled(model.recentMessages.isEmpty)
                    }
                    if model.recentGlassesStatus == .loading {
                        ProgressView().controlSize(.small)
                    } else if model.recentMessages.isEmpty {
                        Text(recentGlassesEmptyCopy)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.recentMessages.prefix(30)) { turn in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(turnRowTitle(turn))
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Button("Copy turn") { model.copyTurn(turn) }
                                        .controlSize(.mini)
                                }
                                Text("User: \(turn.query)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                                Text("COS: \(turn.text)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 4)
                            if turn.id != model.recentMessages.prefix(30).last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Recent Glasses")
                    .font(.caption2.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(COSPalette.line, lineWidth: 1))
        .buttonStyle(.bordered)
    }

    private var doctorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DOCTOR").font(.caption2.weight(.bold)).tracking(1.3).foregroundStyle(.secondary)
            ForEach(model.doctorChecks) { check in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: check.state == "ok" ? "checkmark.circle.fill" : check.state == "error" ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(check.state == "ok" ? COSPalette.green : check.state == "error" ? .red : COSPalette.amber)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(check.name).font(.caption.weight(.semibold))
                        Text(check.detail).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                }
            }
        }
        .padding(13)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(COSPalette.line, lineWidth: 1))
    }

    private var utilities: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TOOLS").font(.caption2.weight(.bold)).tracking(1.3).foregroundStyle(.secondary)
            HStack {
                Button("Run Doctor", systemImage: "stethoscope") { model.perform("doctor") }
                Button("Guided Setup", systemImage: "terminal") { model.runGuidedSetup() }
            }
            HStack {
                Button("Repair Managed Runtime", systemImage: "wrench.and.screwdriver") { model.perform("repair") }
                    .disabled(!model.status.installed || model.status.ownerConflict || model.status.runtimeState == "legacyForeground")
                if model.status.managedContract && model.status.ownershipVerified && (!model.status.whisperReady || model.status.whisperCircuitOpen) {
                    Button("Repair Whisper", systemImage: "waveform.badge.exclamationmark") { model.perform("restart-whisper") }
                }
            }
            HStack {
                Button("Choose Folder", systemImage: "folder") { model.selectWorkFolder() }
                Button("Open Cursor", systemImage: "chevron.left.forwardslash.chevron.right") { model.openCursor() }
                Button("Copy Pairing Token", systemImage: "key") { model.perform("token") }
                    .disabled(model.status.runtimeState != "managedHealthy")
            }
            HStack {
                Button("Copy Report", systemImage: "doc.on.doc") { model.perform("report") }
                Button("Open Logs", systemImage: "doc.text.magnifyingglass") { model.openLogs() }
                Button("Health", systemImage: "heart.text.square") { model.openHealth() }
            }
            Divider()
            Toggle("Launch COS Control at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            DisclosureGroup("Advanced") {
                HStack {
                    Button("Rollback Server") { model.perform("rollback") }
                    Button("Reconcile Change") { model.perform("reconcile") }
                    Button("Setup Guide") { model.openSetupGuide() }
                }.padding(.top, 6)
            }.font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.busy)
    }

    private var footer: some View {
        HStack {
            Text("Controller 0.1.8  •  Server target \(ControllerModel.releaseServerVersion)")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.link)
        }.font(.caption2).foregroundStyle(.secondary)
    }

    private var cursorLabel: String {
        switch model.status.cursorState {
        case "connected": "Connected"
        case "signInRequired": "Sign-in required"
        case "notInstalled": "Not installed"
        default: "Unavailable"
        }
    }

    private var recentGlassesStatusLabel: String {
        switch model.recentGlassesStatus {
        case .idle: "Expand to load today’s last 30 turns"
        case .loading: "Loading…"
        case .ready: "Newest first · \(model.recentMessages.count) turn(s)"
        case .empty: "Empty today"
        case .serverStopped: "Server stopped"
        case .unauthorized: "Unauthorized"
        case .error: "Could not load messages"
        }
    }

    private var recentGlassesEmptyCopy: String {
        switch model.recentGlassesStatus {
        case .serverStopped: "Server stopped"
        case .unauthorized: "Pairing token missing or unauthorized"
        case .empty: "No glasses turns yet today"
        case .error: "Could not load recent glasses messages"
        default: "No messages"
        }
    }

    private func turnRowTitle(_ turn: GlassesTurn) -> String {
        let number = turn.no.map { "#\($0)" } ?? "#"
        return "\(number) · \(turn.timeLabel) · \(turn.previewQuery)"
    }

    private var runtimeLabel: String {
        switch model.status.runtimeState {
        case "managedHealthy": "Running · managed"
        case "managedInPlace": "Running · your server"
        case "managedDegraded": "Managed · degraded"
        case "legacyService": "Legacy LaunchAgent"
        case "legacyStopped": "Legacy LaunchAgent · stopped"
        case "legacyForeground": "Foreground process"
        case "ownerConflict": "Ownership conflict"
        case "stopped": "Stopped"
        case "notInstalled": "Not installed"
        default: "Unknown"
        }
    }

    private var ownershipLabel: String {
        if model.status.ownerConflict { return "Conflict" }
        if model.status.ownershipVerified { return "Verified direct PID" }
        switch model.status.launchAgentKind {
        case "knownLegacy": return "Recognized legacy"
        case "cosControl": return "Managed · unverified"
        case "absent": return "No LaunchAgent"
        default: return "Unknown"
        }
    }

    private func statusRow(_ label: String, value: String, good: Bool) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Circle().fill(good ? COSPalette.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(value).fontWeight(.medium)
        }.font(.callout)
    }
}
