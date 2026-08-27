import AppKit
import Combine
import SwiftUI

/// Always-on-top pet for live Claude / Cursor / Codex sessions.
///
/// Independent of Activity: closing that window must not hide the pet. The
/// panel is nonactivating so a poll cannot steal focus from the running agent.
@MainActor
final class SessionPetPresenter: NSObject, ObservableObject, NSWindowDelegate {
    private var panel: NSPanel?
    private weak var model: ControllerModel?
    private var showActivity: ((ActivitySection?) -> Void)?
    private var pollTask: Task<Void, Never>?
    private var observers: [AnyCancellable] = []
    private var outsideClickMonitor: Any?
    private var bound = false

    func bindIfNeeded(model: ControllerModel, showActivity: @escaping (ActivitySection?) -> Void) {
        if bound { return }
        bound = true
        self.model = model
        self.showActivity = showActivity
        observers.append(model.$petSessions.sink { [weak self] _ in
            Task { @MainActor in self?.syncPanel() }
        })
        observers.append(model.$petEnabled.sink { [weak self] _ in
            Task { @MainActor in self?.syncPanel() }
        })
        observers.append(model.$petExpanded.sink { [weak self] expanded in
            Task { @MainActor in
                self?.syncOutsideClickMonitor(expanded)
                self?.syncPanel()
            }
        })
        pollTask = Task { [weak self] in
            await self?.model?.loadPetSessions()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await self?.model?.loadPetSessions()
            }
        }
        syncPanel()
    }

    func openInControl(_ session: ClaudeSession) {
        model?.openPetSessionInControl(session)
        showActivity?(.sessions)
    }

    private func syncPanel() {
        guard let model else { return }
        let sessions = model.petSessions
        let show = model.petEnabled && !sessions.isEmpty
        if !show {
            panel?.orderOut(nil)
            // Assigning false when it is already false still fires @Published
            // and this sink, which would spin syncPanel on the main actor.
            if model.petExpanded { model.petExpanded = false }
            return
        }
        let panel = existingPanel()
        if let host = panel.contentViewController as? NSHostingController<SessionPetRoot> {
            host.rootView = SessionPetRoot(model: model, presenter: self)
            let fitting = host.sizeThatFits(in: NSSize(width: 260, height: 900))
            var frame = panel.frame
            frame.size = NSSize(width: 260, height: max(fitting.height, 120))
            panel.setFrame(frame, display: true)
        }
        panel.orderFrontRegardless()
    }

    private func existingPanel() -> NSPanel {
        if let panel { return panel }
        guard let model else {
            return NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        }
        let root = SessionPetRoot(model: model, presenter: self)
        let host = NSHostingController(rootView: root)
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 240),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setFrameAutosaveName("COSSessionPet")
        panel.contentViewController = host
        if panel.frame.origin == .zero, let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 280, y: screen.minY + 28))
        }
        self.panel = panel
        return panel
    }

    private func syncOutsideClickMonitor(_ expanded: Bool) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        guard expanded else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.model?.petExpanded = false
            }
        }
    }
}

private struct SessionPetRoot: View {
    @ObservedObject var model: ControllerModel
    var presenter: SessionPetPresenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sessions: [ClaudeSession] { model.petSessions }
    private var focus: ClaudeSession? { model.petFocusSession }

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Button {
                    handleSpriteClick()
                } label: {
                    SessionPetSprite(working: focus?.state == "running", reduceMotion: reduceMotion)
                }
                .buttonStyle(.plain)
                .help(focus.map { "Open \($0.providerLabel)" } ?? "Live session")
                if sessions.count > 1 {
                    Text("\(sessions.count)")
                        .font(COSType.mono(9, weight: .bold))
                        .foregroundStyle(COSPalette.cream)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(COSPalette.gold))
                        .offset(x: 6, y: -4)
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: 8) {
                petButton("waveform", help: "Open in COS Control") {
                    if let focus { presenter.openInControl(focus) }
                }
                if sessions.count > 1 {
                    petButton(model.petExpanded ? "chevron.down" : "chevron.up", help: "Live sessions") {
                        model.petExpanded.toggle()
                    }
                }
            }
            if let notice = model.petNotice, !notice.isEmpty {
                Text(notice)
                    .font(COSType.body(10))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Capsule().fill(COSPalette.card))
                    .overlay(Capsule().stroke(COSPalette.line, lineWidth: 1))
            } else if let focus {
                statusBubble(focus)
            }
            if model.petExpanded, sessions.count > 1 {
                sessionList
            }
        }
        .padding(10)
        .frame(width: 248)
    }

    private var sessionList: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(sessions) { session in
                Button {
                    model.petFocusID = session.id
                    model.petExpanded = false
                    model.focusPetSession(session)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Text(session.providerLabel.uppercased())
                            .font(COSType.mono(8, weight: .bold))
                            .foregroundStyle(providerTint(session.provider))
                            .frame(width: 44, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title)
                                .font(COSType.body(11, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(session.relativeAgeLabel() ?? session.workspace)
                                .font(COSType.body(10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if session.id != sessions.last?.id {
                    Divider()
                }
            }
        }
        return Group {
            if sessions.count > 5 {
                ScrollView {
                    content
                }
                .frame(height: 200)
            } else {
                content
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(COSPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(COSPalette.line, lineWidth: 1)
        )
    }

    private func statusBubble(_ session: ClaudeSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title)
                .font(COSType.body(11, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(session.petSubtitle)
                .font(COSType.body(10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Capsule().fill(COSPalette.card)
        )
        .overlay(Capsule().stroke(COSPalette.line, lineWidth: 1))
    }

    private func petButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(COSPalette.ink)
                .frame(width: 22, height: 22)
                .background(Circle().fill(COSPalette.card))
                .overlay(Circle().stroke(COSPalette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func handleSpriteClick() {
        if sessions.count > 1 {
            model.petExpanded.toggle()
            return
        }
        if let focus { model.focusPetSession(focus) }
    }

    private func providerTint(_ provider: String) -> Color {
        switch provider {
        case "codex": Color(red: 0.10, green: 0.55, blue: 0.48)
        case "cursor": Color(red: 0.42, green: 0.38, blue: 0.86)
        default: Color(red: 0.78, green: 0.45, blue: 0.22)
        }
    }
}
