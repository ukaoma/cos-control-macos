import AppKit
import SwiftUI

// The permission guide's views: the rows, the card the menu-bar panel shows inline, the Welcome window's Permissions
// step and the floating bar under System Settings. House rules: a 390pt-safe layout, no eyebrow labels above headings,
// no pill rows; a status is a dot and a word.

private func statusColor(_ status: PermissionStatus) -> Color {
    switch status {
    case .allowed: COSPalette.green
    case .needsYou: COSPalette.amber
    case .notNeededYet: COSPalette.muted
    }
}

struct PermissionStatusMark: View {
    let status: PermissionStatus
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(statusColor(status)).frame(width: 7, height: 7)
            Text(status.label)
                .font(COSType.body(11, weight: status == .needsYou ? .semibold : .regular))
                .foregroundStyle(status == .notNeededYet ? COSPalette.muted : statusColor(status))
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// One row: what it unlocks, its live status and its one action.
struct PermissionRowView: View {
    @ObservedObject var guide: PermissionGuide
    let row: PermissionRow
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title).font(COSType.body(12.5, weight: .semibold))
                Spacer(minLength: 6)
                PermissionStatusMark(status: row.status)
            }
            Text(row.unlocks)
                .font(COSType.body(11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let feature = guide.waitingFeature[row.id] {
                Text("Needed for: \(feature)")
                    .font(COSType.body(11, weight: .medium))
                    .foregroundStyle(COSPalette.accent)
            }
            if let detail = row.detail {
                Text(detail)
                    .font(COSType.body(10.5))
                    .foregroundStyle(row.status == .needsYou ? COSPalette.amber : COSPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if row.action != .none || alreadyOnRepair {
                HStack(spacing: 10) {
                    if row.action != .none {
                        if prominent || row.status == .needsYou {
                            Button(row.action.title) { guide.perform(row) }.buttonStyle(COSPrimaryButtonStyle())
                        } else {
                            Button(row.action.title) { guide.perform(row) }.buttonStyle(COSQuietButtonStyle())
                        }
                    }
                    if alreadyOnRepair {
                        Button("Already on? Reset and add again") { guide.resetAndAddAgain() }
                            .buttonStyle(COSTextButtonStyle())
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "It's already on": the switch shows on in Settings while this build is not trusted.
    private var alreadyOnRepair: Bool {
        row.kind == .accessibility && row.status == .needsYou && row.action != .resetAndAddAgain
    }
}

/// The list itself, shared by the panel card and the Welcome step.
struct PermissionGuideList: View {
    @ObservedObject var guide: PermissionGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(guide.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider() }
                PermissionRowView(guide: guide, row: row, prominent: row.id == guide.focusedRowID)
            }
        }
    }
}

/// Old COS builds' rows in Privacy & Security, found only when asked and reset one at a time.
struct StaleBuildsSection: View {
    @ObservedObject var guide: PermissionGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(guide.staleSearching ? "Looking for old COS test builds…" : "Clean up old COS test builds") {
                Task { await guide.findStaleBuilds() }
            }
            .buttonStyle(COSTextButtonStyle())
            .disabled(guide.staleSearching)
            if let builds = guide.staleBuilds {
                if builds.isEmpty {
                    Text("No old COS test builds on this Mac.")
                        .font(COSType.body(11)).foregroundStyle(.secondary)
                } else {
                    Text("Each one can leave its own row under Accessibility. Reset removes that build's row; COS Control stays.")
                        .font(COSType.body(11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(builds) { build in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(build.bundleID).font(COSType.mono(10.5)).lineLimit(1).truncationMode(.middle)
                                Text(build.copies == 1 ? "1 copy on disk" : "\(build.copies) copies on disk")
                                    .font(COSType.body(10)).foregroundStyle(COSPalette.muted)
                            }
                            Spacer(minLength: 6)
                            if let result = guide.staleResults[build.bundleID] {
                                Text(result).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                            } else {
                                Button("Reset") { Task { await guide.resetStaleBuild(build.bundleID) } }
                                    .buttonStyle(COSQuietButtonStyle())
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The card the menu-bar panel shows in place when Permissions is opened (its own route flag,
/// `guide.panelRouteActive`, written only by its openers).
struct PermissionGuideCard: View {
    @ObservedObject var guide: PermissionGuide

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Permissions").font(COSType.display(13, weight: .semibold))
                Text(guide.summary).font(COSType.body(11)).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { guide.closePanelRoute() }.buttonStyle(COSTextButtonStyle())
            }
            Text("Each one switches on a feature. COS works without any of them.")
                .font(COSType.body(11)).foregroundStyle(.secondary)
            PermissionGuideList(guide: guide)
            Divider()
            StaleBuildsSection(guide: guide)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
    }
}

/// The Permissions row in the panel's controls: one line until opened, then the card in place.
struct PanelPermissionsRow: View {
    @ObservedObject var guide: PermissionGuide

    var body: some View {
        Group {
            if guide.panelRouteActive {
                PermissionGuideCard(guide: guide)
            } else {
                Button { guide.openInPanel() } label: {
                    HStack(spacing: 8) {
                        Label("Permissions", systemImage: "lock.shield")
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
                .help("What COS can use on this Mac, and one click to allow each")
            }
        }
        .task { await guide.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await guide.refresh() }
        }
    }
}

/// The Welcome window's Permissions step, after Connect your AI. Lists only what this Mac needs; skippable.
struct OnboardingPermissionsStep: View {
    @ObservedObject var guide: PermissionGuide
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Allow what you want COS to do").font(COSType.body(18, weight: .semibold))
            Text("Each permission switches on one feature, and macOS asks you before anything changes. Skip any of them: COS starts without them, and Permissions in the menu bar brings this list back.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PermissionGuideList(guide: guide)
                .padding(.horizontal, 14)
                .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
            HStack(spacing: 14) {
                Button("Continue") { guide.onboardingDone = true; onContinue() }
                    .buttonStyle(COSPrimaryButtonStyle())
                Button("Not now") { guide.onboardingDone = true; onContinue() }
                    .buttonStyle(COSTextButtonStyle())
            }
        }
        .task { await guide.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await guide.refresh() }
        }
    }
}

// MARK: - The floating bar

/// What the bar shows, separate from the flow so it renders offscreen with no System Settings.
struct PermissionHelperBarState: Equatable {
    var request: PermissionDragRequest
    var phase: HelperBarStep.Phase
    var sourceURL: URL
    var isDragging = false
    var checking = false
    var checkMessage: String?
}

struct PermissionHelperBar: View {
    @ObservedObject var flow: PermissionDragFlow

    var body: some View {
        if let request = flow.request, let url = flow.sourceURL {
            PermissionHelperBarContent(
                state: PermissionHelperBarState(request: request, phase: flow.phase, sourceURL: url,
                                                isDragging: flow.isDragging, checking: flow.checking,
                                                checkMessage: flow.checkMessage),
                onDragging: { flow.setDragging($0) }, onClose: { flow.dismiss() }, onTrouble: { flow.trouble() },
                onReveal: { flow.revealInFinder() }, onCheck: { flow.checkNow() })
        }
    }
}

struct PermissionHelperBarContent: View {
    let state: PermissionHelperBarState
    var onDragging: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}
    var onTrouble: () -> Void = {}
    var onReveal: () -> Void = {}
    var onCheck: () -> Void = {}

    private var pane: PermissionPane { state.request.pane }
    private var name: String { state.request.source.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if state.phase == .allowed {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(COSPalette.green)
                    Text("Allowed").font(COSType.body(14, weight: .semibold))
                    Text(state.request.feature.map { "\($0) can go ahead." } ?? "Taking you back to COS.")
                        .font(COSType.body(12)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(COSPalette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PermissionHelperCopy.instruction(name: name, pane: pane))
                            .font(COSType.body(13.5))
                            .fixedSize(horizontal: false, vertical: true)
                        if let feature = state.request.feature {
                            Text("Needed for: \(feature)").font(COSType.body(11.5)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(COSIconButtonStyle(size: 22))
                        .help("Close")
                }
                COSAppDragItemView(url: state.sourceURL, card: AnyView(dragCard), onDragStateChange: onDragging)
                    .frame(height: 52)
                Text(PermissionHelperCopy.fallback(name: name, pane: pane))
                    .font(COSType.body(11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if pane == .fullDiskAccess || state.phase == .trouble || state.checkMessage != nil {
                    HStack(spacing: 12) {
                        if pane == .fullDiskAccess {
                            Button(state.checking ? "Checking…" : "Check now", action: onCheck)
                                .buttonStyle(COSQuietButtonStyle()).disabled(state.checking)
                            Button("Reveal in Finder", action: onReveal).buttonStyle(COSTextButtonStyle())
                        }
                        Spacer(minLength: 0)
                    }
                    if let message = state.checkMessage {
                        Text(message).font(COSType.body(11)).foregroundStyle(COSPalette.amber)
                    }
                    if state.phase == .trouble {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Having trouble?").font(COSType.body(12, weight: .semibold))
                            Text(PermissionHelperCopy.trouble(pane: pane))
                                .font(COSType.body(11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if pane == .accessibility {
                                Button("Reset and add again", action: onTrouble).buttonStyle(COSQuietButtonStyle())
                                    .padding(.top, 2)
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(COSPalette.panel))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(COSPalette.line, lineWidth: 1))
    }

    private var dragCard: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: state.sourceURL.path))
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(COSType.body(13, weight: .semibold))
                Text(pane == .fullDiskAccess ? state.sourceURL.path : "This copy of COS Control")
                    .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            VStack(spacing: 1) {
                Image(systemName: "hand.draw").font(.system(size: 13))
                Text("Drag").font(COSType.body(9.5))
            }
            .foregroundStyle(COSPalette.muted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(state.isDragging ? COSPalette.accent : COSPalette.line, lineWidth: 1))
    }
}

/// The bar's words, in one place so the checks read the same strings the person does.
enum PermissionHelperCopy {
    static func instruction(name: String, pane: PermissionPane) -> String {
        "Drag \(name) to the list above to allow \(pane.title)"
    }

    static func fallback(name: String, pane: PermissionPane) -> String {
        pane == .fullDiskAccess
            ? "or click +, press Command-Shift-G, and paste the path shown on the card"
            : "or click + and choose \(name)"
    }

    static func trouble(pane: PermissionPane) -> String {
        pane == .fullDiskAccess
            ? "Reveal in Finder shows the file to add. After adding it, Check now runs one stopped job to confirm."
            : "If COS Control is already in the list and switched on, that entry may belong to an older build. Reset and add again removes it so you can add this one."
    }
}
