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
        observers.append(model.$petRenderScales.sink { [weak self] _ in
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
        observers.append(model.$petAnimationSpeedPercent.sink { [weak self] _ in
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
        // An enabled pet is a persistent companion, not only a live-session
        // indicator. With no sessions, PetSpritePose.resolve selects `.idle`.
        let show = model.petEnabled
        if !show {
            panel?.orderOut(nil)
            // Assigning false when it is already false still fires @Published
            // and this sink, which would spin syncPanel on the main actor.
            if model.petExpanded { model.petExpanded = false }
            return
        }
        let panel = existingPanel()
        if let host = panel.contentViewController as? NSHostingController<SessionPetRoot> {
            let characterScale = fittedCharacterScale(for: panel, model: model)
            let viewportSize = model.petSpriteKit.viewportSize(
                pixels: model.petSize.pixels,
                scale: characterScale,
                poseScales: model.petRenderScales
            )
            host.rootView = SessionPetRoot(
                model: model,
                presenter: self,
                characterScale: characterScale,
                viewportSize: viewportSize
            )
            let width = max(
                model.petSize.length(260),
                viewportSize.width + model.petSize.length(36)
            )
            let fitting = host.sizeThatFits(in: NSSize(width: width, height: 900))
            var frame = panel.frame
            frame.size = NSSize(width: width, height: max(fitting.height, model.petSize.length(120)))
            let screens = NSScreen.screens.map(\.visibleFrame)
            panel.setFrame(PetPanelFrame.clamped(frame, screens: screens), display: true)
        }
        panel.orderFrontRegardless()
    }

    private func fittedCharacterScale(for panel: NSPanel, model: ControllerModel) -> CGFloat {
        let screens = NSScreen.screens
        let visible = screens.first(where: { $0.visibleFrame.intersects(panel.frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return model.petSpriteKit.fittedViewportScale(
            model.petCharacterFactor,
            pixels: model.petSize.pixels,
            available: visible.size,
            reservedChrome: CGSize(
                width: model.petSize.length(36),
                height: model.petSize.length(180)
            ),
            poseScales: model.petRenderScales
        )
    }

    private func existingPanel() -> NSPanel {
        if let panel { return panel }
        guard let model else {
            return NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        }
        let viewportSize = model.petSpriteKit.viewportSize(
            pixels: model.petSize.pixels,
            scale: model.petCharacterFactor,
            poseScales: model.petRenderScales
        )
        let root = SessionPetRoot(
            model: model,
            presenter: self,
            characterScale: model.petCharacterFactor,
            viewportSize: viewportSize
        )
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
    var characterScale: CGFloat
    var viewportSize: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sessions: [ClaudeSession] { model.petSessions }
    private var focus: ClaudeSession? { model.petFocusSession }
    private var size: PetSize { model.petSize }
    private var pose: PetSpritePose { model.petSpritePose }

    var body: some View {
        VStack(spacing: size.length(8)) {
            ZStack(alignment: .topTrailing) {
                Group {
                    ZStack(alignment: .bottomLeading) {
                        SessionPetSprite(
                            working: pose.animates,
                            reduceMotion: reduceMotion,
                            customImage: model.petCustomSprite,
                            frames: model.petSpriteKit.frames(for: pose),
                            pose: pose,
                            frameInterval: model.petFrameInterval(for: pose),
                            size: CGFloat(size.pixels),
                            characterScale: characterScale * model.petRenderScale(for: pose),
                            animationSpeed: model.petAnimationSpeedFactor,
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
                .contentShape(Rectangle())
                // Declared before the single tap so SwiftUI resolves the double
                // FIRST — otherwise the opening click of a double-tap would jump
                // to the platform and the menu would open behind the raised app.
                .onTapGesture(count: 2) { toggleSessionMenu() }
                .onTapGesture { handleSpriteClick() }
                .accessibilityAddTraits(.isButton)
                .help(spriteHelp)
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
            .frame(width: viewportSize.width, height: viewportSize.height, alignment: .bottom)
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
                } else {
                    petButtonPlaceholder
                }
            }
            if let focus {
                statusBubble(focus)
            } else {
                idleBubble
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
            viewportSize.width + size.length(36)
        ))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleSpriteDrop(providers)
        }
    }

    private var sessionList: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(sessions) { session in
                // The drop control is a SIBLING of the row button, not a child:
                // a Button nested inside another Button's label never receives
                // the click on macOS.
                HStack(spacing: 0) {
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
                if model.canDismissPetSession(session) {
                    Button {
                        model.dismissPetSession(session)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: size.typeSize(9), weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(size.length(5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Drop from the pet list. The session keeps running.")
                }
                }
                if session.id != sessions.last?.id {
                    Divider()
                }
            }
            // Dropping a row must be undoable from the app itself. Without this
            // the only way back was `defaults delete`, and the dismissal
            // survives relaunch, so a mis-click was permanent.
            if !model.petDismissals.stamps.isEmpty {
                Divider()
                Button {
                    model.restorePetDismissals()
                } label: {
                    HStack(spacing: size.length(6)) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: size.typeSize(9), weight: .bold))
                        Text("Show \(model.petDismissals.stamps.count) dropped")
                            .font(COSType.body(size.typeSize(10)))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, size.length(6))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Put dropped sessions back in the list. Nothing was ever stopped.")
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
            .frame(width: size.length(248), alignment: .leading)
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

    private var idleBubble: some View {
        VStack(alignment: .leading, spacing: size.length(2)) {
            Text("Session pet")
                .font(COSType.body(size.typeSize(11), weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text("Idle")
                .font(COSType.mono(size.typeSize(9), weight: .bold))
                .foregroundStyle(COSPalette.green)
            Text("Waiting for the next prompt or session.")
                .font(COSType.body(size.typeSize(10)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, size.length(12))
        .padding(.vertical, size.length(8))
        .frame(width: size.length(248), alignment: .leading)
        .background(Capsule().fill(COSPalette.card))
        .overlay(Capsule().stroke(COSPalette.line, lineWidth: 1))
    }

    private var petButtonPlaceholder: some View {
        Color.clear
            .frame(width: size.length(22), height: size.length(22))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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

    private var spriteHelp: String {
        let base = focus.map { "\(pose.title) · \($0.petStateCaption) · \($0.providerLabel)" } ?? pose.title
        return sessions.count > 1 ? base + " · double-click for the session list" : base
    }

    private func handleSpriteClick() {
        if let focus { model.openSessionInPlatform(focus) }
    }

    /// The chevron was the only way in. A double-click on the figure itself is
    /// the same toggle, and stays a no-op at one session where there is no list.
    private func toggleSessionMenu() {
        guard sessions.count > 1 else { return }
        model.petExpanded.toggle()
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
