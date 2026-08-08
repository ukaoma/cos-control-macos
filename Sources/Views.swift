import SwiftUI
import AppKit

/// An NSColor that resolves differently in light vs dark appearance.
private func adaptiveNSColor(light: NSColor, dark: NSColor) -> NSColor {
    NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }
}

/// Inline photo view. Was a sheet; see ControlPanel.body for why sheets cannot
/// be used from a MenuBarExtra panel.
private struct MediaPreviewPane: View {
    let preview: SelectedMediaPreview
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    onBack()
                } label: {
                    Label("Back", systemImage: "chevron.left").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(preview.attachment.displayLabel).font(.system(size: 11, weight: .medium))
                    Text("\(preview.attachment.width) × \(preview.attachment.height)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Image(nsImage: preview.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(14)
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
    @State private var confirmLegacyRestart = false
    @State private var confirmInstallManaged = false
    @State private var showGuidedSetupTier = false
    @State private var selectedTranscriptionTier = "balanced"
    @State private var selectedBackgroundJobs = true
    @State private var selectedMeetingPreview = false
    @State private var selectedIdleMetalHq = false

    /// Overlays are rendered INLINE, never as sheets.
    ///
    /// MenuBarExtra(.window) is a transient panel: it closes the moment it stops
    /// being the key window. Presenting a sheet makes a new window key, so the
    /// panel dismissed itself mid-interaction and took the sheet's parent with
    /// it — which is why controls stopped responding as they were clicked. There
    /// is no arrangement of sheet modifiers that avoids this; the fix is to not
    /// leave the panel's own window at all.
    var body: some View {
        Group {
            if model.reviewRouteActive {
                SpeakerReviewPane(model: model)
            } else if let preview = model.selectedMediaPreview {
                MediaPreviewPane(preview: preview) { model.selectedMediaPreview = nil }
            } else {
                mainPanel
            }
        }
        .frame(width: 390, height: 640)
        .background(COSPalette.panel)
        .background(WindowOpaquer())
        .onAppear {
            if let tier = model.status.transcriptionRequestedTier,
               tier == "max" || tier == "balanced" {
                selectedTranscriptionTier = tier
            }
            if let enabled = model.status.backgroundJobsEnabled { selectedBackgroundJobs = enabled }
            if let enabled = model.status.meetingPreviewEnabled { selectedMeetingPreview = enabled }
            if let enabled = model.status.idleMetalHqEnabled { selectedIdleMetalHq = enabled }
        }
        .onChange(of: model.status.transcriptionRequestedTier) { _, tier in
            if let tier, tier == "max" || tier == "balanced" { selectedTranscriptionTier = tier }
        }
        .onChange(of: model.status.backgroundJobsEnabled) { _, enabled in
            if let enabled { selectedBackgroundJobs = enabled }
        }
        .onChange(of: model.status.meetingPreviewEnabled) { _, enabled in
            if let enabled { selectedMeetingPreview = enabled }
        }
        .onChange(of: model.status.idleMetalHqEnabled) { _, enabled in
            if let enabled { selectedIdleMetalHq = enabled }
        }
        .alert("COS Control", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog(
            "Restart this self-managed server?",
            isPresented: $confirmLegacyRestart,
            titleVisibility: .visible
        ) {
            Button("Restart now", role: .destructive) { model.perform("restart") }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This older server cannot prove that meetings and agent jobs are idle. Continue only when no work is active. COS Control will reload the LaunchAgent so the selected folder becomes active.")
        }
        .confirmationDialog(
            "Install the latest managed server?",
            isPresented: $confirmInstallManaged,
            titleVisibility: .visible
        ) {
            Button("Stop legacy and install", role: .destructive) {
                model.installLatestManagedFromLegacy()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This stops your checkout LaunchAgent, then installs the current npm latest (@gotcos/glasses-server@latest). Finish active glasses work first. Prefer Manage in place if you only want status/restart without replacing the server.")
        }
        .confirmationDialog(
            "Choose transcription setup",
            isPresented: $showGuidedSetupTier,
            titleVisibility: .visible
        ) {
            Button("Balanced (Recommended)") {
                selectedTranscriptionTier = "balanced"
                model.runGuidedSetup(tier: "balanced")
            }
            Button("Max") {
                selectedTranscriptionTier = "max"
                model.runGuidedSetup(tier: "max")
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Balanced uses fast Small.en previews, Turbo commits, and Large-v3 polish. Max uses Large-v3 for live preview and commit too; choose it only on a powerful Mac.")
        }
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
            statusRow("Local Whisper", value: whisperLabel, good: model.status.whisperReady)
            if model.status.backgroundJobsSupported, let enabled = model.status.backgroundJobsEnabled {
                statusRow("Background jobs", value: enabled ? "Allowed" : "Off", good: enabled)
            }
            if model.status.meetingPreviewSupported, let enabled = model.status.meetingPreviewEnabled {
                statusRow("Meeting preview", value: enabled ? "Turbo · On" : "Off", good: enabled)
            }
            if model.status.idleMetalHqSupported, let enabled = model.status.idleMetalHqEnabled {
                let label = enabled ? "On · preemptible" : (model.status.idleMetalHqForceCpu == true ? "Force CPU" : "Off · CPU")
                statusRow("Idle Metal HQ", value: label, good: enabled)
            }
            if !model.status.whisperReady, let error = model.status.whisperError, !error.isEmpty {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(COSPalette.amber)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .textSelection(.enabled)
            }
            if model.status.livePreviewModel != nil || model.status.liveCommitModel != nil || model.status.hqPolishModel != nil {
                if let tier = model.status.transcriptionEffectiveTier {
                    statusRow(
                        "Transcription tier",
                        value: transcriptionTierLabel(
                            requested: model.status.transcriptionRequestedTier,
                            effective: tier,
                            degraded: model.status.transcriptionTierDegraded
                        ),
                        good: !model.status.transcriptionTierDegraded && model.status.whisperReady
                    )
                    if model.status.transcriptionTierDegraded {
                        Text(transcriptionTierReason)
                            .font(.caption2)
                            .foregroundStyle(COSPalette.amber)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                if model.status.livePreviewModel != nil {
                statusRow(
                    "Preview, while dictating",
                    value: transcriptionModelLabel(model.status.livePreviewModel, degraded: model.status.livePreviewDegraded),
                    good: model.status.livePreviewReady == true
                )
                }
                if model.status.liveCommitModel != nil {
                statusRow(
                    "Commit, live meeting",
                    value: transcriptionModelLabel(model.status.liveCommitModel),
                    good: model.status.whisperReady
                )
                }
                if model.status.hqPolishModel != nil {
                statusRow(
                    "Polish, on save",
                    value: transcriptionModelLabel(model.status.hqPolishModel),
                    good: model.status.hqPolishReady == true
                )
                }
                if let vocabularyTerms = model.status.transcriptionVocabularyTerms, vocabularyTerms == 0 {
                    Text("Add names and specialist terms in the setup wizard to improve accuracy.")
                        .font(.caption2)
                        .foregroundStyle(COSPalette.amber)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            statusRow("Meeting sync", value: meetingSyncLabel, good: !model.status.meetingSyncActive)
            if model.status.meetingSyncActive {
                Text(model.status.meetingSyncBlocksRestart
                     ? "Blocks Update / Restart until HQ polish finishes."
                     : "Meeting polish in progress.")
                    .font(.caption2)
                    .foregroundStyle(COSPalette.amber)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let earlySync = model.status.earlyMeetingSyncEnabled {
                let failed = model.status.earlyMeetingSyncLastOutcome == "failed"
                let unavailable = model.status.earlyMeetingSyncRequested == true
                    && model.status.earlyMeetingSyncAvailable == false
                let earlyValue = unavailable
                    ? model.status.earlyMeetingSyncReason == "sync_script_upgrade_required"
                        ? "Workspace update required"
                        : "Unavailable"
                    : !earlySync
                    ? "Off"
                    : model.status.earlyMeetingSyncInFlight || model.status.earlyMeetingSyncPendingCount > 0
                        ? "Claiming · \(model.status.earlyMeetingSyncPendingCount) pending"
                        : failed
                            ? "Final sync pending"
                            : model.status.earlyMeetingSyncLastOutcome == "finalized"
                                ? "Final sync verified"
                            : model.status.earlyMeetingSyncLastOutcome == "claimed"
                                ? "Claim verified"
                                : "Ready"
                statusRow(
                    "Early meeting sync",
                    value: earlyValue,
                    good: earlySync && !failed && !unavailable
                )
                if failed, let error = model.status.earlyMeetingSyncLastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(COSPalette.amber)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if let progressive = model.status.progressiveHqEnabled {
                let total = model.status.progressiveHqSealedTotal
                let done = model.status.progressiveHqSealedDone
                let tier = model.status.progressiveHqTier == "max" ? "Max" : "Balanced"
                let threadLabel = model.status.progressiveHqThreads.map { " · \($0)t" } ?? ""
                let unavailable = model.status.progressiveHqRequested == true && !progressive
                statusRow(
                    "HQ prefill",
                    value: progressive
                        ? "\(done)/\(total) sealed · \(tier)\(threadLabel)"
                        : unavailable ? "Unavailable" : "Off",
                    good: progressive
                )
                if model.status.progressiveHqActive {
                    Text("\(tier) CPU guardrail\(threadLabel) · canonical meeting text is unchanged.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else if unavailable {
                    Text(model.status.progressiveHqReason == "hq_unavailable"
                        ? "Large-v3 HQ is unavailable; live transcription remains unchanged."
                        : "Progressive HQ was not admitted on this server.")
                        .font(.caption2)
                        .foregroundStyle(COSPalette.amber)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if model.status.meetingFinalizationPending > 0 || model.status.meetingFinalizationMalformed > 0 {
                statusRow(
                    "Finalization recovery",
                    value: model.status.meetingFinalizationMalformed > 0
                        ? "Repair required"
                        : model.status.meetingFinalizationFailed > 0
                        ? "\(model.status.meetingFinalizationFailed) retrying"
                        : "\(model.status.meetingFinalizationPending) pending",
                    good: model.status.meetingFinalizationFailed == 0
                        && model.status.meetingFinalizationMalformed == 0
                )
                if let error = model.status.meetingFinalizationLastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(COSPalette.amber)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            // Server 6.19.0+: meeting audio whose save never landed is
            // quarantined instead of deleted. Surface it — a hidden lost
            // meeting is the failure this exists to end. Row hides at zero.
            if model.status.unsavedCaptures > 0 {
                statusRow(
                    "Unsaved captures",
                    value: "\(model.status.unsavedCaptures) recoverable",
                    good: false
                )
                Text("Meeting audio was captured but never saved. Open COS on the phone to let a deferred save land, or recover via the server's /api/meeting/orphans route before retention expires.")
                    .font(.caption2)
                    .foregroundStyle(COSPalette.amber)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .textSelection(.enabled)
            }
            // One quick-glance row for all three agent backends. Cursor keeps
            // its own detailed row below because the helper probes it locally
            // (sign-in state, not just presence) — richer than health's flag.
            statusRow("Agent CLIs", value: agentCliSummary, good: agentCliAllReady)
            if let detail = agentCliDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(agentCliAllReady ? .secondary : COSPalette.amber)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .textSelection(.enabled)
            }
            statusRow("Cursor CLI", value: cursorLabel, good: model.status.cursorReady)
            statusRow("Version", value: model.status.runtimeState == "managedInPlace" ? "Self-managed" : (model.status.version ?? model.status.installedVersion ?? "Not installed"), good: model.status.installed || model.status.runtimeState == "managedInPlace")
            Divider()
            HStack(alignment: .top) {
                Text("Work folder").foregroundStyle(.secondary)
                Spacer()
                Text(model.status.workDirectory ?? "Default COS context")
                    .lineLimit(2).multilineTextAlignment(.trailing).textSelection(.enabled)
            }.font(.caption)
            if model.status.workDirectoryPending {
                Label("Saved to LaunchAgent · pending a safe server restart", systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(COSPalette.amber)
            }
            HStack(alignment: .top) {
                Text("Meetings library").foregroundStyle(.secondary)
                Spacer()
                Text(model.status.operationsDirectory ?? "Not set (standalone recordings)")
                    .lineLimit(2).multilineTextAlignment(.trailing).textSelection(.enabled)
            }.font(.caption)
            if let jobs = model.status.activeJobs, let recordings = model.status.activeTranscriptionSessions, jobs + recordings > 0 {
                Label("\(jobs) job(s), \(recordings) recording(s) active. Restart is locked.", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(COSPalette.amber)
            }
            if model.status.transactionPending {
                if model.busy {
                    Label("Server change in progress · recovery is armed", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.caption).foregroundStyle(COSPalette.amber)
                } else {
                    Label("An interrupted server change needs Repair.", systemImage: "wrench.and.screwdriver.fill")
                        .font(.caption).foregroundStyle(.red)
                }
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
                    Button("Restart", systemImage: "arrow.clockwise") {
                        if model.status.runtimeState == "managedInPlace" && !model.status.safeToRestart {
                            confirmLegacyRestart = true
                        } else {
                            model.perform("restart")
                        }
                    }
                        .disabled((model.status.activeJobs ?? 0) + (model.status.activeTranscriptionSessions ?? 0) > 0
                                  || model.status.transactionPending)
                    Button("Stop", systemImage: "stop.fill", role: .destructive) { model.perform("stop") }
                        .disabled(model.status.runtimeState == "managedInPlace" && !model.status.safeToRestart)
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
                    Button("Adopt Safely") { model.installLatestManagedFromLegacy() }
                }.font(.caption).foregroundStyle(COSPalette.amber)
            }
            if model.status.runtimeState == "legacyService" {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Your server is running. COS Control can manage it in place — status, restart, and recovery — without replacing it.", systemImage: "checkmark.seal")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("Manage in place") { model.perform("adopt-in-place") }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button("Install managed server") {
                            confirmInstallManaged = true
                        }
                        .controlSize(.small)
                        .disabled((model.status.activeJobs ?? 0) + (model.status.activeTranscriptionSessions ?? 0) > 0)
                    }
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

    /// Saved meetings whose speakers can be reviewed. Deliberately its own card
    /// rather than a row inside Recent Glasses: that list is turns (messages and
    /// photos), and a meeting is a different kind of thing with a different action.
    private var mainPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                updateBanner
                statusCard
                controls
                recentGlassesCard
                reviewableMeetingsCard
                if !model.doctorChecks.isEmpty { doctorCard }
                utilities
                footer
            }
            .padding(16)
        }
    }

    private var reviewableMeetingsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.reviewableMeetings.isEmpty
                     ? "Review speakers"
                     : "Review speakers · \(min(model.reviewableMeetings.count, MEETING_LIST_VISIBLE))")
                    .font(.caption2.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.meetingsLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Refresh") { Task { await model.loadReviewableMeetings() } }
                        .font(.system(size: 10))
                        .controlSize(.small)
                }
            }

            if model.reviewableMeetings.isEmpty {
                Text(model.reviewError ?? "Name the voices in a saved meeting.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let shown = Array(model.reviewableMeetings.prefix(MEETING_LIST_VISIBLE))
                // Height follows CONTENT up to the cap, so a light day reserves no
                // dead space. A flat maxHeight on a ScrollView is greedy in the
                // scroll axis and would hold ~300pt open for three rows.
                let capped = shown.count > MEETING_LIST_SCROLL_AFTER
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(shown) { meeting in
                            Button { model.openSpeakerReview(meeting) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(meeting.title)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .lineLimit(1)
                                        Text("\(meeting.date) · \(meeting.duration)")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                        // Counts the server already sends. Own line, and
                                        // fixedSize because a wrapping Text inside the
                                        // panel's outer ScrollView does not reserve its
                                        // true height and paints over the next row.
                                        Text(meeting.countsSummary)
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.tertiary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Review who spoke in \(meeting.title)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: capped ? MEETING_LIST_MAX_HEIGHT : nil)
                .scrollIndicators(capped ? .visible : .hidden)
            }
        }
        .padding(13)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(COSPalette.line, lineWidth: 1))
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
                        // Turns render in FULL inside a bounded, scrollable viewport.
                        // Two rules keep this honest:
                        //  1. `.fixedSize(horizontal: false, vertical: true)` — inside the
                        //     panel's outer ScrollView a wrapping Text is offered unbounded
                        //     height and does NOT reserve its true laid-out height, so it
                        //     painted over the Divider and the next row (clipped/overlapping
                        //     bodies). fixedSize makes each Text claim exactly the height it
                        //     needs, so rows push each other down instead of colliding.
                        //  2. The list gets its own maxHeight + ScrollView so a long day of
                        //     turns cannot push the rest of the panel off-screen.
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(model.recentMessages.prefix(30)) { turn in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(turnRowTitle(turn))
                                                .font(.caption.weight(.semibold))
                                                .fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 8)
                                            Button("Copy turn") { model.copyTurn(turn) }
                                                .controlSize(.mini)
                                                .layoutPriority(1)
                                            if !turn.attachments.isEmpty {
                                                if model.mediaExportingTurnIDs.contains(turn.id) {
                                                    ProgressView()
                                                        .controlSize(.mini)
                                                        .help("Preparing a private local image handoff")
                                                } else {
                                                    Button("Copy + images") { model.copyTurnWithImages(turn) }
                                                        .controlSize(.mini)
                                                        .layoutPriority(1)
                                                }
                                            }
                                        }
                                        Text("User: \(turn.query)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                        attachmentStrip(
                                            title: "Your image",
                                            attachments: turn.attachments.filter(\.isUserPhoto)
                                        )
                                        Text("COS: \(turn.text)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                        attachmentStrip(
                                            title: "Answer image",
                                            attachments: turn.attachments.filter { !$0.isUserPhoto }
                                        )
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                                    if turn.id != model.recentMessages.prefix(30).last?.id {
                                        Divider()
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 300)
                        .scrollIndicatorsFlash(onAppear: true)
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

    @ViewBuilder
    private func attachmentStrip(title: String, attachments: [GlassesAttachmentRef]) -> some View {
        if !attachments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            Button {
                                model.openMediaPreview(attachment)
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(COSPalette.panel)
                                    switch model.mediaPreviewStates[attachment.id] {
                                    case .ready(let image):
                                        Image(nsImage: image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                    case .unavailable(let reason):
                                        Image(systemName: "photo.badge.exclamationmark")
                                            .foregroundStyle(.secondary)
                                            .help(reason)
                                    case .loading, nil:
                                        ProgressView().controlSize(.mini)
                                    }
                                    if model.previewingMediaID == attachment.id {
                                        Color.black.opacity(0.18)
                                        ProgressView().controlSize(.mini)
                                    }
                                }
                                .frame(width: 72, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(COSPalette.line, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .disabled(model.previewingMediaID != nil)
                            .help("Open \(attachment.displayLabel.lowercased())")
                            .onAppear { model.loadThumbnail(attachment) }
                            .onDisappear { model.cancelThumbnail(attachment) }
                        }
                    }
                }
                .scrollIndicators(.hidden)
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
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(COSPalette.line, lineWidth: 1))
    }

    private var utilities: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TOOLS").font(.caption2.weight(.bold)).tracking(1.3).foregroundStyle(.secondary)
            HStack {
                Button("Run Doctor", systemImage: "stethoscope") { model.perform("doctor") }
                Button("Guided Setup", systemImage: "terminal") { showGuidedSetupTier = true }
            }
            if model.status.transcriptionRequestedTier != nil {
                HStack(spacing: 8) {
                    Picker("Transcription", selection: $selectedTranscriptionTier) {
                        Text("Balanced").tag("balanced")
                        Text("Max").tag("max")
                    }
                    .pickerStyle(.segmented)
                    Button("Apply") { model.setTranscriptionTier(selectedTranscriptionTier) }
                        .disabled(model.busy
                            || (!model.status.installed && model.status.runtimeState != "managedInPlace"))
                }
                Text("Balanced is recommended. Max keeps Large-v3 resident for live commit and may use substantially more memory.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if model.status.installed || model.status.runtimeState == "managedInPlace" {
                Label("Update Server to 6.21.0 or newer to enable transcription tier controls.", systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(COSPalette.amber)
            }
            if model.status.backgroundJobsSupported {
                HStack(spacing: 8) {
                    Toggle("Background jobs", isOn: $selectedBackgroundJobs)
                    Button("Apply") { model.setBackgroundJobsEnabled(selectedBackgroundJobs) }
                        .disabled(model.busy
                            || (!model.status.installed && model.status.runtimeState != "managedInPlace")
                            || (model.status.activeJobs ?? 0) + (model.status.activeTranscriptionSessions ?? 0) > 0)
                }
                Text("On by default. Replies keep running when the companion closes or you browse elsewhere. Existing work must finish before this machine-wide setting changes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if model.status.meetingPreviewSupported {
                HStack(spacing: 8) {
                    Toggle("Meeting Turbo preview", isOn: $selectedMeetingPreview)
                    Button("Apply") { model.setMeetingPreviewEnabled(selectedMeetingPreview) }
                        .disabled(model.busy
                            || (!model.status.installed && model.status.runtimeState != "managedInPlace")
                            || (model.status.activeJobs ?? 0) + (model.status.activeTranscriptionSessions ?? 0) > 0)
                }
                Text("Shows fast provisional meeting text, then replaces it with the canonical speaker-attributed transcript. Disable for immediate rollback.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if model.status.idleMetalHqSupported {
                HStack(spacing: 8) {
                    Toggle("Idle Metal HQ", isOn: $selectedIdleMetalHq)
                    Button("Apply") { model.setIdleMetalHqEnabled(selectedIdleMetalHq) }
                        .disabled(model.busy
                            || (!model.status.installed && model.status.runtimeState != "managedInPlace")
                            || (model.status.activeJobs ?? 0) + (model.status.activeTranscriptionSessions ?? 0) > 0)
                }
                Text("Powerful Macs only. Uses Metal for sealed post-meeting HQ when idle. Live and progressive transcription stay protected; Off forces CPU rollback.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Repair Managed Runtime", systemImage: "wrench.and.screwdriver") { model.perform("repair") }
                    .disabled(!model.status.installed || model.status.ownerConflict || model.status.runtimeState == "legacyForeground")
                if model.status.managedContract && model.status.ownershipVerified && (!model.status.whisperReady || model.status.whisperCircuitOpen) {
                    Button("Repair Whisper", systemImage: "waveform.badge.exclamationmark") { model.perform("restart-whisper") }
                }
            }
            // Own row so labels don't truncate into ambiguous "Choose…" / "Meeting…"
            HStack {
                Button("Work Folder", systemImage: "folder") { model.selectWorkFolder() }
                    .disabled(!model.status.installed && model.status.runtimeState != "managedInPlace")
                    .help(model.status.installed || model.status.runtimeState == "managedInPlace"
                          ? "COS workspace for Claude, Codex, and Cursor (Work folder above)"
                          : "Install the managed server or choose Manage in place first")
                Button("Meetings Library", systemImage: "calendar") { model.selectOperationsFolder() }
                    .disabled(!model.status.installed && model.status.runtimeState != "managedInPlace")
                    .help("COS operations/ tree for G2 Review Meetings (Meetings library above) — quilt/personal/…/meetings")
            }
            HStack {
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

    /// P1 check-only banner. Renders ONLY when the appcast advertises a genuinely newer
    /// build; offline, up-to-date, killSwitch and malformed all render nothing at all.
    /// The button opens the download page. This build cannot download or swap anything.
    @ViewBuilder private var updateBanner: some View {
        if model.appUpdate.shouldSurface {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(COSPalette.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Update available: \(model.appUpdate.latestVersion ?? "")")
                        .font(.caption.weight(.semibold))
                    if let notes = model.appUpdate.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Button("Get it") { model.openUpdatePage() }
                    .controlSize(.small)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(COSPalette.amber.opacity(0.45), lineWidth: 1))
        }
    }

    private var footer: some View {
        HStack {
            Text(footerLabel)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.link)
        }.font(.caption2).foregroundStyle(.secondary)
    }

    /// Controller build from Info.plist; server version from live status (never a
    /// compile-time "verified" pin that drifts behind npm / Update Server).
    private var footerLabel: String {
        let controller = ControllerModel.currentVersion
        let live = model.status.version ?? model.status.installedVersion
        if let live, !live.isEmpty {
            return "Controller \(controller)  •  Server \(live) (npm latest)"
        }
        if model.status.runtimeState == "managedInPlace" {
            return "Controller \(controller)  •  Server self-managed"
        }
        return "Controller \(controller)  •  Server not installed"
    }

    /// Compact per-CLI state: "Claude ✓ · Codex ✓ · Cursor ✓". A CLI whose
    /// readiness is unknown (server too old to publish `features`, or
    /// unreachable) shows "?" — never a confident cross on missing data.
    private var agentCliSummary: String {
        func mark(_ ready: Bool?) -> String {
            guard let ready else { return "?" }
            return ready ? "✓" : "✕"
        }
        return "Claude \(mark(model.status.claudeCliReady))"
            + " · Codex \(mark(model.status.codexCliReady))"
            + " · Cursor \(mark(model.status.cursorReady))"
    }

    private var agentCliAllReady: Bool {
        (model.status.claudeCliReady ?? false)
            && (model.status.codexCliReady ?? false)
            && model.status.cursorReady
    }

    /// When everything is ready, show versions (the "which build am I on"
    /// glance). When something is not, name what to fix instead — the
    /// actionable line beats a version list.
    private var agentCliDetail: String? {
        var missing: [String] = []
        if model.status.claudeCliReady == false { missing.append("claude (run: claude auth login)") }
        if model.status.codexCliReady == false { missing.append("codex (run: codex login)") }
        if !model.status.cursorReady { missing.append("cursor (run: agent login)") }
        if !missing.isEmpty { return "Not signed in: " + missing.joined(separator: ", ") }

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

    private var cursorLabel: String {
        switch model.status.cursorState {
        case "connected": "Connected"
        case "signInRequired": "Sign-in required"
        case "notInstalled": "Not installed"
        default: "Unavailable"
        }
    }

    private var whisperLabel: String {
        if model.status.whisperReady { return "Ready" }
        switch model.status.whisperStartupState {
        case "preflight": return "Checking"
        case "loading": return "Loading"
        case "failed": return "Failed"
        case "unavailable": return "Not installed"
        case "stopped": return "Stopped"
        default: return "Unavailable"
        }
    }

    private func transcriptionModelLabel(_ raw: String?, degraded: Bool = false) -> String {
        let label: String
        switch raw {
        case "small.en": label = "Small.en"
        case "large-v3-turbo": label = "Large-v3-Turbo"
        case "large-v3": label = "Large-v3"
        case .some(let value): label = value
        case nil: label = "Unreported"
        }
        return degraded ? "\(label) fallback" : label
    }

    private func transcriptionTierLabel(requested: String?, effective: String, degraded: Bool) -> String {
        let effectiveLabel = effective == "max" ? "Max" : "Balanced"
        guard degraded, let requested else { return effectiveLabel }
        let requestedLabel = requested == "max" ? "Max" : "Balanced"
        return "\(requestedLabel) → \(effectiveLabel)"
    }

    private var transcriptionTierReason: String {
        switch model.status.transcriptionTierReason {
        case "large_v3_model_missing": return "Large-v3 is missing; live commit safely fell back to Turbo. Run Guided Setup, then Apply Max again."
        case "turbo_model_missing": return "Turbo fallback weights are missing. Run Guided Setup before changing tiers."
        default: return "The requested tier could not be activated; the safe fallback remains in use."
        }
    }

    private var meetingSyncLabel: String {
        let raw = model.status.meetingSyncLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        return model.status.meetingSyncActive ? "Syncing…" : "Idle"
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
        case .unauthorized: "Use Copy Pairing Token and paste the complete value (existing tokens need at least 16 characters)"
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

// MARK: - Speaker review sheet (0.4.0)
//
// Read the ribbon before the names. Long blocks are people taking turns; fine
// stripes are one voice split across two labels, which is the failure this panel
// exists to make visible.
//
// Confidence is a ramp, "you" is a tag, and unreliable is TEXTURE rather than a
// red badge — an untrustworthy row should look like noise, which is honest about
// what is wrong with it.

/// Who spoke, in order — an actual timeline.
///
/// WHAT THIS REPLACES. The previous ribbon iterated the aggregated `voices` and
/// drew one rectangle per voice sized by its share of segments. It carried the
/// label "who spoke, in order" while containing no ordering at all, so a voice
/// that spoke at the start and again at the end appeared once, in the middle, and
/// hovering it could not have reported anything true. Miles asked for hover and a
/// legend; the honest fix was a time axis first.
///
/// Widths are proportional to DURATION, not segment count, so a long quiet turn
/// reads as long. Colour is assigned per distinct speaker in first-appearance
/// order and shared with the legend, which is what makes the bar readable.
private struct TurnRibbon: View {
    let review: SpeakerReview
    /// Lifted to the pane so the legend can highlight the same span the pointer
    /// is over.
    @Binding var hovered: SpeakerTimelineSpan?
    /// Which aggregated column the pointer is in, so the bar can dim the rest.
    @State private var hoveredColumn: Int?

    /// Distinct speakers in the order they first speak. Stable, so a colour does
    /// not move between renders of the same meeting.
    private var speakerOrder: [String] {
        var seen = Set<String>()
        var order: [String] = []
        for span in review.timeline where !seen.contains(span.speaker) {
            seen.insert(span.speaker)
            order.append(span.speaker)
        }
        return order
    }

    private var spanMs: Int {
        max(review.timeline.last?.endMs ?? 0, review.durationMs, 1)
    }

    static func tint(for speaker: String, order: [String], review: SpeakerReview) -> Color {
        // An unnamed voice is deliberately neutral: colouring it like a person
        // would imply an identity the system does not have.
        if !review.assertsName(speaker) { return COSPalette.line }
        let palette: [Color] = [COSPalette.green, COSPalette.amber, COSPalette.ink.opacity(0.55),
                                COSPalette.green.opacity(0.55), COSPalette.amber.opacity(0.55)]
        guard let at = order.firstIndex(of: speaker) else { return COSPalette.line }
        return palette[at % palette.count]
    }

    /// The bar is aggregated into fixed-width COLUMNS, each coloured by the
    /// speaker holding most of that slice of time.
    ///
    /// A span-per-rectangle bar cannot fit. Measured on real sidecars: 509 spans
    /// with a 1.5pt minimum width need 1,079pt inside a 358pt panel — 3x over —
    /// and 237 of 238 meetings over 200 segments overflow. The excess was simply
    /// clipped by the window, so the later half of every long meeting was
    /// invisible on a bar whose entire purpose is showing the whole meeting in
    /// order. Columns keep every minute on screen at honest proportions.
    private struct Column: Identifiable {
        let id: Int
        let speaker: String
        let startMs: Int
        let endMs: Int
    }

    private func columns(width: CGFloat, order: [String]) -> [Column] {
        guard !review.timeline.isEmpty, spanMs > 0 else { return [] }
        // ~2.5pt per column: fine enough to read as a timeline, wide enough that
        // a pointer can land on one.
        let count = max(1, min(Int(width / 2.5), 200))
        let slice = Double(spanMs) / Double(count)
        var out: [Column] = []
        var cursor = 0
        for i in 0..<count {
            let from = Int(Double(i) * slice)
            let to = Int(Double(i + 1) * slice)
            // Whoever holds the most milliseconds of this slice wins it.
            var best = ""
            var bestMs = 0
            var j = cursor
            while j < review.timeline.count, review.timeline[j].startMs < to {
                let s = review.timeline[j]
                let overlap = min(s.endMs, to) - max(s.startMs, from)
                if overlap > bestMs { bestMs = overlap; best = s.speaker }
                if s.endMs <= to { j += 1 } else { break }
            }
            cursor = max(cursor, j - 1)
            if best.isEmpty, let carried = out.last?.speaker { best = carried }
            out.append(Column(id: i, speaker: best, startMs: from, endMs: to))
        }
        return out
    }

    var body: some View {
        let order = speakerOrder
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                let cols = columns(width: geo.size.width, order: order)
                HStack(spacing: 0) {
                    ForEach(cols) { col in
                        Rectangle()
                            .fill(Self.tint(for: col.speaker, order: order, review: review))
                            .opacity(hoveredColumn == nil || hoveredColumn == col.id ? 1 : 0.4)
                            .frame(width: geo.size.width / CGFloat(max(cols.count, 1)))
                            .onHover { inside in
                                if inside {
                                    hoveredColumn = col.id
                                    hovered = review.timeline.last(where: { $0.startMs <= col.startMs })
                                        ?? review.timeline.first
                                } else if hoveredColumn == col.id {
                                    hoveredColumn = nil
                                    hovered = nil
                                }
                            }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 34)

            // What the pointer is over, in words. A colour bar without this is
            // exactly the state Miles found: no way to map a stripe to a person.
            if let span = hovered {
                HStack(spacing: 6) {
                    Text(span.stamp).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
                    Text(review.displayName(for: span.speaker)).font(.system(size: 11, weight: .medium))
                    Text("\(span.segments) seg · \(max(1, span.durationMs / 1000))s")
                        .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary)
                }
            } else {
                Text("Hover the bar to see who is speaking")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            // The legend. Reads the same tint function as the bar, so the two can
            // never drift apart.
            if !order.isEmpty {
                let gridColumns = [GridItem(.adaptive(minimum: 108), spacing: 8)]
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 3) {
                    ForEach(order, id: \.self) { speaker in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Self.tint(for: speaker, order: order, review: review))
                                .frame(width: 9, height: 9)
                            Text(review.displayName(for: speaker))
                                .font(.system(size: 10))
                                .foregroundStyle(review.assertsName(speaker) ? .secondary : .tertiary)
                                .lineLimit(1)
                        }
                        // Hovering a legend entry finds that speaker's FIRST span,
                        // which is how you locate someone on a long bar.
                        .onHover { inside in
                            hovered = inside ? review.timeline.first(where: { $0.speaker == speaker }) : nil
                        }
                    }
                }
            }
        }
    }
}

private struct ConfidenceRamp: View {
    let value: Double?
    let unreliable: Bool

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 1.5) {
                ForEach(0..<10, id: \.self) { i in
                    let lit = Double(i) < (value ?? 0) * 10
                    RoundedRectangle(cornerRadius: 1)
                        .fill(lit && !unreliable ? COSPalette.amber : COSPalette.line)
                        .frame(width: 6, height: 7)
                }
            }
            Text(unreliable ? "unreliable" : value.map { String(format: "%.2f", $0) } ?? "—")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

private struct VoiceRow: View {
    @ObservedObject var model: ControllerModel
    let voice: ReviewVoice
    @State private var typed = ""

    private var matches: [VoiceProfileOption] {
        let q = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return model.voiceProfiles
            .filter { $0.name.lowercased().contains(q) && $0.name != voice.label }
            .prefix(4).map { $0 }
    }

    /// The typed name, when it matches no existing profile.
    ///
    /// Without this a voice could only ever be named after someone ALREADY
    /// enrolled — type a new person's name and nothing appears to click, which
    /// is indistinguishable from the UI being broken. Offered as an explicit
    /// row rather than an implicit Return, because it creates a new label in
    /// the meeting and a typo becomes a phantom attendee.
    private var typedNewName: String? {
        let name = typed.trimmingCharacters(in: .whitespaces)
        guard name.count >= 2, name != voice.label else { return nil }
        let exists = model.voiceProfiles.contains { $0.name.lowercased() == name.lowercased() }
        return exists ? nil : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(voice.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(voice.nameAsserted ? .primary : .secondary)
                if voice.isOwner {
                    Text("you")
                        .font(.system(size: 9, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(COSPalette.green.opacity(0.18), in: Capsule())
                }
                Spacer()
                Text("\(voice.segments) seg")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                // Talk time, ONLY for a voice the panel actually names. Minutes
                // beside an unnamed row would assert by the back door exactly
                // what the display floor refuses to assert.
                if voice.nameAsserted, let ms = voice.speakingMs, ms > 0 {
                    Text("· \(ms / 60_000)m \(ms / 1000 % 60)s")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if let share = model.openReview?.shareOfIdentified(voice) {
                        Text("· \(Int((share * 100).rounded()))%")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                }
                ConfidenceRamp(value: voice.meanSimilarity, unreliable: voice.reliability == .unreliable)
            }

            // The evidence. A score cannot tell you who someone is; these can.
            if voice.phrases.isEmpty {
                Text("No line from this voice was distinctive enough to quote.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(voice.phrases) { phrase in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // Play THIS line. Miles: playback is for the stored
                            // audio of the chunk being trained on — hearing the
                            // actual segment is what settles who spoke. Shown only
                            // when the server still holds that chunk, so a button
                            // never appears where the click would fail.
                            if model.canPlay(phrase) {
                                Button {
                                    model.playPhrase(phrase, voice: voice.label)
                                } label: {
                                    Image(systemName: model.playingVoice == "\(voice.label)#\(phrase.chunkIndex ?? -1)"
                                          ? "stop.fill" : "play.fill")
                                        .font(.system(size: 8.5))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Hear this line")
                            }
                            Text("“\(phrase.text)”").font(.system(size: 11.5))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Text(phrase.stamp)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.leading, 9)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(COSPalette.line)
                        .frame(width: 2)
                        // Dashed rule when the lines may not be one person.
                        .opacity(voice.reliability == .unreliable ? 0.45 : 1)
                }
            }

            if let thrash = voice.thrashesWith.first {
                Text("Swaps with \(thrash.speaker) every \(String(format: "%.0f", thrash.meanRun)) segments. "
                     + "Real turn-taking holds far longer, so a name here would be a guess.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The name the system GUESSED, kept visible even when it was not
            // earned — it is often the clue that identifies the voice — but stated
            // as a candidate, with the reason it did not qualify.
            if !voice.nameAsserted && voice.reliability != .unattributed {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Closest match: \(voice.label)\(voice.meanSimilarity.map { String(format: " (%.2f)", $0) } ?? "")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(voice.assertionBlockers, id: \.self) { blocker in
                        Text("· \(blocker)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
            }

            // Keyed to this row: a single shared string printed the same failure
            // under all eleven voices at once.
            if let note = model.playbackNote, note.key.hasPrefix(voice.label), model.playingVoice == nil {
                Text(note.text).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if voice.canRename {
                if model.namingVoice == voice.label {
                    TextField("Type a name", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    // Scope, chosen BEFORE the name. Until 0.5.0 every rename was
                    // global, so this is the control that makes a correction mean
                    // "in this meeting" — Miles: "it should just be this call."
                    Picker("", selection: $model.correctionScope) {
                        ForEach(CorrectionScope.allCases) { scope in
                            Text(scope.label).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(model.correctionScope.detail)
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(matches) { option in
                        Button {
                            model.previewRename(from: voice.label, to: option.name,
                                               scope: model.correctionScope,
                                               isNameAssignment: voice.isNameAssignment)
                        } label: {
                            HStack {
                                Text(option.name).font(.system(size: 12))
                                Spacer()
                                // A click starts a server round-trip. Without this the
                                // row looked inert and the click seemed ignored.
                                if model.mergeInFlight {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Text("\(option.embeddings) samples")
                                        .font(.system(size: 9.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(model.mergeInFlight)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 5))
                    }
                    if let newName = typedNewName {
                        Button {
                            model.previewRename(from: voice.label, to: newName,
                                                scope: model.correctionScope,
                                                isNameAssignment: voice.isNameAssignment)
                        } label: {
                            HStack {
                                Text("Use \u{201C}\(newName)\u{201D}").font(.system(size: 12))
                                Spacer()
                                Text("new name")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(model.mergeInFlight)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 5))
                    }
                    Button("Cancel") { model.namingVoice = nil; typed = "" }
                        .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    // An unattributed row is being GIVEN a name, not corrected,
                    // and until 0.5.2 it had no control at all — only copy telling
                    // the user to do the thing the panel would not let them do.
                    if voice.isNameAssignment {
                        Text("This voice was never named. Name it, or leave it unidentified.")
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 10) {
                        Button(voice.isNameAssignment
                                ? "Name this voice"
                                : (voice.reliability == .unreliable ? "This is someone else" : "Actually someone else")) {
                            model.namingVoice = voice.label
                        }
                        .font(.system(size: 11))
                        .controlSize(.small)

                        // The row's own name, when the floor withheld it. Miles
                        // typed "Queen Ukaoma" into a list that excluded Queen
                        // Ukaoma — the candidate IS the row's label, so a rename
                        // could never express "yes, that really is her".
                        if voice.canConfirmCandidate {
                            Button("Yes, this is \(voice.label)") {
                                model.confirmVoice(voice.label)
                            }
                            .font(.system(size: 11))
                            .controlSize(.small)
                            .disabled(model.mergeInFlight)
                        }

                        // The inverse of naming an unknown voice, which the panel
                        // had no way to express. Miles: none of the attributed
                        // voices were in that room, and there was no option to
                        // de-attribute.
                        if voice.canDeattribute {
                            Button("Not in this meeting") {
                                model.previewDeattribution(from: voice.label)
                            }
                            .font(.system(size: 11))
                            .controlSize(.small)
                            .disabled(model.mergeInFlight)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 9)
    }
}

/// Rows shown in the review card. The helper over-requests so this many
/// actually render — asking the server for exactly this count returned fewer,
/// because rows without a G2 sessionId are filtered out.
let MEETING_LIST_VISIBLE = 15
/// Past this many rows the list scrolls instead of growing. Measured pitch is
/// ~47pt per row with the counts line, so this shows about seven.
let MEETING_LIST_SCROLL_AFTER = 7
let MEETING_LIST_MAX_HEIGHT: CGFloat = 330

struct SpeakerReviewPane: View {
    @ObservedObject var model: ControllerModel
    /// Which span the pointer is over. Held here so the bar and the legend
    /// highlight the same thing.
    @State private var hoveredSpan: SpeakerTimelineSpan?

    private func correctionTitle(_ c: PendingCorrection) -> String {
        if c.refused { return "Not applied" }
        if c.isDeattribution { return "Remove \(c.from) from this meeting?" }
        let to = c.to ?? ""
        return c.scope == .thisMeeting
            ? "Rename \(c.from) to \(to) in this meeting?"
            : "Rename \(c.from) to \(to) everywhere?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.openReview?.title ?? "Speaker review").font(.headline)
                    if let review = model.openReview {
                        Text("\(review.segments) segments · \(review.voices.count) voices")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                        // How much of the meeting carries a name the rows below
                        // will actually show. Three gates, all deliberate: nil
                        // means an older server that does not report this (never
                        // render it as 0); `segments > 0` avoids a meaningless
                        // "0 of 0"; and `attributed` false is skipped because the
                        // block further down already says it at length.
                        if let asserted = review.assertedSegments, review.segments > 0, review.attributed {
                            Text("\(asserted) of \(review.segments) segments named")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(asserted * 2 < review.segments ? .orange : .secondary)
                        }
                        // Talk shares are a ratio over NAMED speech, so they only
                        // mean something when most of the voice was named.
                        // Corpus-wide 44.8% of speaking time is unattributed and
                        // 17% of meetings name nobody — below the bar, a
                        // percentage invites reading the missing majority as a
                        // person. Say the coverage instead of drawing shares.
                        if let note = model.copyNote {
                            Text(note)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(COSPalette.green)
                        }
                        if let coverage = review.speakingCoverage, review.attributed {
                            Text(coverage < 0.6
                                 ? "only \(Int((coverage * 100).rounded()))% of the voice identified — shares unreliable"
                                 : "talk time from \(review.speakingTimeSource == "words" ? "word timings" : "chunk estimates")")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(coverage < 0.6 ? .orange : .secondary)
                        }
                    }
                }
                Spacer()
                // Two forms because they serve different jobs: the summary is
                // pasteable into Slack or email, the full one carries the
                // transcript for an LLM. Both are built server-side with the
                // display floor applied to the attendee block.
                if let content = model.openContent, !content.clipboardSummary.isEmpty {
                    Button { model.copyMeeting(full: false) } label: {
                        Label("Summary", systemImage: "doc.on.doc").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Copy the meeting without the transcript")
                    Button { model.copyMeeting(full: true) } label: {
                        Label("Full (\(max(1, content.fullChars / 1024)) KB)",
                              systemImage: "doc.on.doc.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Copy the meeting including the full transcript")
                }
                Button {
                    model.closeSpeakerReview()
                } label: {
                    Label("Back", systemImage: "chevron.left").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            if model.reviewLoading {
                ProgressView("Reading the transcript…")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let review = model.openReview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // The whole block is gated on there BEING a timeline.
                        // A server older than 6.21.18 returns no spans, and the
                        // unguarded version drew a 34pt blank strip under a
                        // heading, with "Hover the bar to see who is speaking"
                        // beneath a bar that was not there. QA flagged exactly
                        // this and the release notes claimed the panel would
                        // "behave as 0.4.2 did" — 0.4.2 drew a share bar, this
                        // drew nothing.
                        if !review.timeline.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("WHO SPOKE, IN ORDER")
                                    .font(.system(size: 9, design: .monospaced))
                                    .tracking(1.4)
                                    .foregroundStyle(.tertiary)
                                TurnRibbon(review: review, hovered: $hoveredSpan)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12)
                        } else if review.attributed {
                            // Say WHY it is missing, and what to do. Silence here
                            // reads as a broken panel.
                            HStack(spacing: 7) {
                                Image(systemName: "arrow.up.circle").font(.system(size: 11))
                                Text("The speaking timeline needs glasses-server 6.21.18 or newer. Use Update Server in Settings.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        }

                        if !review.attributed {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("No one was identified in this recording").font(.system(size: 13, weight: .semibold))
                                Text("The audio was recovered after the session ended, so no voice matching ran while it played. The lines below are all that is left to go on.")
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 16).padding(.bottom, 10)
                        }

                        Divider()
                        ForEach(Array(review.voices.enumerated()), id: \.element.id) { index, voice in
                            VoiceRow(model: model, voice: voice)
                                .padding(.horizontal, 16)
                            if index < review.voices.count - 1 { Divider() }
                        }

                        // The write-up, BELOW the voice rows. Measured with
                        // AppKit at the real 358pt content width, placing it
                        // above pushed the rows this sheet exists for one to two
                        // full screens down on 7 of 8 of one day's meetings
                        // (worst case 2,565pt). Markdown markers are softened
                        // for the popover; the clipboard keeps the real markup.
                        if let content = model.openContent, !content.sections.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(content.sections, id: \.0) { section in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(section.0.uppercased())
                                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Text(MeetingContent.panelText(section.1))
                                            .font(.system(size: 11.5))
                                            .fixedSize(horizontal: false, vertical: true)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                        } else if let reason = model.contentUnavailable {
                            // Never silence. A 404 means the server predates the
                            // route; anything else is a real failure worth naming.
                            Divider()
                            Text(MeetingContent.unavailableMessage(reason) ?? "")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                        } else if let content = model.openContent, !content.scribeAvailable {
                            Divider()
                            Text("No write-up saved for this meeting yet.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                        }

                    }
                }
            } else if let error = model.reviewError {
                VStack(spacing: 8) {
                    Text(error).font(.system(size: 12)).multilineTextAlignment(.center)
                    Button("Try again") { model.retryOpenReview() }
                    .font(.system(size: 11))
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Reachable even with a review loaded. As an `else if` on the branch
            // above, an error raised WHILE reviewing (a refused name check) was
            // rendered nowhere, so clicking a suggestion appeared to do nothing.
            if model.openReview != nil, let error = model.reviewError {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                    Text(error).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") { model.reviewError = nil }.font(.system(size: 10))
                }
                .padding(10)
                .background(COSPalette.amber.opacity(0.14))
            }

            if let correction = model.pendingCorrection {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    // The title states the SCOPE, because that is the thing the
                    // 0.4.x panel got wrong: it always said "across every
                    // meeting" and always meant it.
                    Text(correctionTitle(correction))
                        .font(.system(size: 12, weight: .semibold))
                    Text(correction.message).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // What will actually change, so a claim of success can be
                    // checked rather than trusted.
                    if !correction.refused && correction.surfaces.sidecar > 0 {
                        Text("\(correction.surfaces.sidecar) segment(s)"
                             + (correction.surfaces.transcript > 0 ? " · \(correction.surfaces.transcript) transcript line(s)" : "")
                             + (correction.surfaces.attendees > 0 ? " · attendee list" : ""))
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    // Naming an unattributed row is the one correction that can
                    // quietly go very wrong: the identifier never matched this
                    // cluster to anyone, so nothing established it is ONE person.
                    // On a G2 mic a large cluster is frequently several. Say the
                    // count before the click, not after.
                    if correction.isNameAssignment && !correction.refused && correction.surfaces.sidecar > 0 {
                        Text("This voice was never matched to anyone, so nothing has established it is one person. "
                             + "Saving labels all \(correction.surfaces.sidecar) of its segments \(correction.to ?? "").")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if correction.wouldRetract > 0 {
                        Text("Also removes \(correction.wouldRetract) training sample(s) this meeting gave that profile, so the mistake stops reinforcing itself.")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if correction.untraceable > 0 {
                        Text("\(correction.untraceable) older sample(s) carry no meeting provenance and cannot be removed.")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if correction.proseStale {
                        Text("The summary still names the old speaker. It refers to people by first name, so it is left alone rather than risk rewriting a sentence about someone else.")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let similarity = correction.similarity {
                        Text("Voice similarity \(String(format: "%.2f", similarity))")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }

                    HStack(spacing: 8) {
                        if !correction.refused {
                            Button("Save") { model.confirmCorrection(correction) }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.mergeInFlight)
                        } else if correction.forceable {
                            // A stalled EARLIER correction is the one refusal a
                            // user can override. Without this the 409 was a dead
                            // end whose own message told them to re-open the
                            // meeting, which changes nothing on the server.
                            Button("Apply anyway") { model.forceCorrection(correction) }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.mergeInFlight)
                        }
                        Button(correction.refused ? "OK" : "Cancel") { model.cancelCorrection() }
                        if model.mergeInFlight { ProgressView().controlSize(.mini) }
                        Spacer()
                    }
                    .font(.system(size: 11))
                }
                .padding(14)
                .background(COSPalette.card)
            }
        }
    }
}
