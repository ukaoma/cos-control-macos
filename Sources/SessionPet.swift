import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

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
        observers.append(model.$petCustomSprite.sink { [weak self] _ in
            Task { @MainActor in self?.syncPanel() }
        })
        observers.append(model.$petSpriteKit.sink { [weak self] _ in
            Task { @MainActor in self?.syncPanel() }
        })
        observers.append(model.$petCompleting.sink { [weak self] _ in
            Task { @MainActor in self?.syncPanel() }
        })
        observers.append(model.$petSize.sink { [weak self] _ in
            Task { @MainActor in self?.syncPanel() }
        })
        observers.append(model.$petCharacterPercent.sink { [weak self] _ in
            Task { @MainActor in self?.syncPanel() }
        })
        observers.append(model.$petExpanded.sink { [weak self] expanded in
            Task { @MainActor in
                self?.syncOutsideClickMonitor(expanded)
                self?.syncPanel()
            }
        })
        observers.append(model.$petNotice.sink { [weak self] _ in
            Task { @MainActor in self?.syncPanel() }
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

    func openTarget(_ session: ClaudeSession) {
        if session.petTargetOpensAgentWindow {
            model?.openSessionInPlatform(session)
            return
        }
        openInControl(session)
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
            let spriteWidth = max(
                model.petSpritePose.renderSize(
                    model.petSize.pixels,
                    scale: model.petCharacterFactor,
                    aspect: model.petSpriteKit.aspect(for: model.petSpritePose)
                ).width,
                CGFloat(model.petSize.pixels)
            )
            let width = max(
                model.petSize.length(260),
                spriteWidth + model.petSize.length(36)
            )
            let fitting = host.sizeThatFits(in: NSSize(width: width, height: 900))
            var frame = panel.frame
            frame.size = NSSize(width: width, height: max(fitting.height, model.petSize.length(120)))
            let screens = NSScreen.screens.map(\.visibleFrame)
            panel.setFrame(PetPanelFrame.clamped(frame, screens: screens), display: true)
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
        let screens = NSScreen.screens.map(\.visibleFrame)
        var frame = panel.frame
        if frame.origin == .zero, let screen = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(x: screen.maxX - 280, y: screen.minY + 28)
        }
        panel.setFrame(PetPanelFrame.clamped(frame, screens: screens), display: false)
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
    private var size: PetSize { model.petSize }
    private var pose: PetSpritePose { model.petSpritePose }

    var body: some View {
        VStack(spacing: size.length(8)) {
            ZStack(alignment: .topTrailing) {
                Button {
                    handleSpriteClick()
                } label: {
                    ZStack(alignment: .bottomLeading) {
                        SessionPetSprite(
                            working: pose.animates,
                            reduceMotion: reduceMotion,
                            customImage: model.petCustomSprite,
                            frames: model.petSpriteKit.frames(for: pose),
                            pose: pose,
                            size: CGFloat(size.pixels),
                            characterScale: model.petCharacterFactor,
                            restClips: model.petRestClips(for: pose)
                        )
                        if let focus {
                            Circle()
                                .fill(petStateColor(focus))
                                .frame(width: size.length(8), height: size.length(8))
                                .offset(x: size.length(4), y: -size.length(2))
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(focus.map { "\(pose.title) · \($0.petStateCaption) · \($0.providerLabel)" } ?? pose.title)
                if sessions.count > 1 {
                    Text("\(sessions.count)")
                        .font(COSType.mono(size.typeSize(9), weight: .bold))
                        .foregroundStyle(COSPalette.cream)
                        .padding(.horizontal, size.length(5))
                        .padding(.vertical, size.length(2))
                        .background(Capsule().fill(COSPalette.gold))
                        .offset(x: size.length(6), y: -size.length(4))
                        .allowsHitTesting(false)
                }
            }
            HStack(spacing: size.length(8)) {
                petButton("scope", help: targetHelp) {
                    if let focus { presenter.openTarget(focus) }
                }
                petButton("arrow.up.forward.app", help: "Open in platform") {
                    if let focus { model.openSessionInPlatform(focus) }
                }
                if sessions.count > 1 {
                    petButton(model.petExpanded ? "chevron.down" : "chevron.up", help: "Live sessions") {
                        model.petExpanded.toggle()
                    }
                }
            }
            if let focus {
                statusBubble(focus)
            }
            if let notice = model.petNotice, !notice.isEmpty {
                Text(notice)
                    .font(COSType.body(size.typeSize(10)))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .padding(.horizontal, size.length(12))
                    .padding(.vertical, size.length(6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Capsule().fill(COSPalette.card))
                    .overlay(Capsule().stroke(COSPalette.line, lineWidth: 1))
            }
            if model.petExpanded, sessions.count > 1 {
                sessionList
            }
        }
        .padding(size.length(10))
        .frame(width: max(
            size.length(248),
            pose.renderSize(
                size.pixels,
                scale: model.petCharacterFactor,
                aspect: model.petSpriteKit.aspect(for: pose)
            ).width + size.length(36)
        ))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleSpriteDrop(providers)
        }
    }

    private var sessionList: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(sessions) { session in
                Button {
                    model.petFocusID = session.id
                    model.openSessionInPlatform(session)
                } label: {
                    HStack(alignment: .top, spacing: size.length(8)) {
                        Text(session.providerLabel.uppercased())
                            .font(COSType.mono(size.typeSize(8), weight: .bold))
                            .foregroundStyle(providerTint(session.provider))
                            .frame(width: size.length(44), alignment: .leading)
                        VStack(alignment: .leading, spacing: size.length(2)) {
                            Text(session.title)
                                .font(COSType.body(size.typeSize(11), weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(listSubtitle(session))
                                .font(COSType.body(size.typeSize(10)))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: size.typeSize(11), weight: .semibold))
                            .foregroundStyle(COSPalette.plateInk)
                    }
                    .padding(.vertical, size.length(7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in platform")
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
                .frame(height: size.length(200))
            } else {
                content
            }
        }
        .padding(.horizontal, size.length(10))
        .padding(.vertical, size.length(4))
        .background(
            RoundedRectangle(cornerRadius: size.length(12), style: .continuous)
                .fill(COSPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: size.length(12), style: .continuous)
                .stroke(COSPalette.line, lineWidth: 1)
        )
    }

    private func statusBubble(_ session: ClaudeSession) -> some View {
        Button {
            model.openSessionInPlatform(session)
        } label: {
            VStack(alignment: .leading, spacing: size.length(2)) {
                Text(session.title)
                    .font(COSType.body(size.typeSize(11), weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(session.petStateCaption)
                    .font(COSType.mono(size.typeSize(9), weight: .bold))
                    .foregroundStyle(petStateColor(session))
                Text(session.petSubtitle)
                    .font(COSType.body(size.typeSize(10)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, size.length(12))
            .padding(.vertical, size.length(8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Capsule().fill(COSPalette.card)
            )
            .overlay(Capsule().stroke(COSPalette.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open in platform")
    }

    private var targetHelp: String {
        focus?.petTargetOpensAgentWindow == true ? "Open Agents Window" : "Open in Activity"
    }

    private func petButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size.typeSize(11), weight: .semibold))
                // Fixed ink on the adaptive card disc is invisible in dark mode;
                // plateInk flips to gold there. The documented black-on-black fix.
                .foregroundStyle(COSPalette.plateInk)
                .frame(width: size.length(22), height: size.length(22))
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
        if let focus { model.openSessionInPlatform(focus) }
    }

    private func handleSpriteDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL? = {
                if let url = item as? URL { return url }
                if let data = item as? Data {
                    return URL(dataRepresentation: data, relativeTo: nil)
                }
                return nil
            }()
            guard let url else { return }
            Task { @MainActor in
                model.installPetSprite(from: url)
            }
        }
        return true
    }

    private func listSubtitle(_ session: ClaudeSession) -> String {
        if let age = session.relativeAgeLabel() {
            return "\(session.petStateCaption) · \(age)"
        }
        return session.petStateCaption
    }

    private func petStateColor(_ session: ClaudeSession) -> Color {
        switch session.state {
        case "running": COSPalette.green
        case "waiting": COSPalette.amber
        default: Color.secondary
        }
    }

    private func providerTint(_ provider: String) -> Color {
        switch provider {
        case "codex": Color(red: 0.10, green: 0.55, blue: 0.48)
        case "cursor": Color(red: 0.42, green: 0.38, blue: 0.86)
        default: Color(red: 0.78, green: 0.45, blue: 0.22)
        }
    }
}
