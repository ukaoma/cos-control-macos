import SwiftUI

private enum COSPalette {
    static let ink = Color(red: 0.12, green: 0.09, blue: 0.07)
    static let cream = Color(red: 0.96, green: 0.94, blue: 0.90)
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
                if !model.doctorChecks.isEmpty { doctorCard }
                utilities
                footer
            }
            .padding(16)
        }
        .frame(width: 390, height: 610)
        .background(COSPalette.cream.opacity(0.42))
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
            statusRow("Version", value: model.status.version ?? model.status.installedVersion ?? "Not installed", good: model.status.installed)
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
        .background(.background, in: RoundedRectangle(cornerRadius: 13))
    }

    private var controls: some View {
        VStack(spacing: 9) {
            HStack {
                if model.status.runtimeState == "managedHealthy" {
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
                Label("Running legacy adoption is unsupported. Stop the legacy service first; COS Control will not risk in-flight work without an exact rollback generation.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(COSPalette.amber)
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
        .background(.background, in: RoundedRectangle(cornerRadius: 13))
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
            Text("Controller 0.1.0  •  Server target \(ControllerModel.releaseServerVersion)")
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.link)
        }.font(.caption2).foregroundStyle(.secondary)
    }

    private var runtimeLabel: String {
        switch model.status.runtimeState {
        case "managedHealthy": "Running · managed"
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
