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
        // The $petExpanded sink used to pass only its own value, which tore the
        // monitor down when the finished-chip opened (it sets petExpanded false).
        observers.append(model.$petExpanded.sink { [weak self] _ in
            Task { @MainActor in self?.syncLists() }
        })
        observers.append(model.$petCompletions.sink { [weak self] _ in
            Task { @MainActor in self?.syncPanel() }
        })
        observers.append(model.$petCompletionsExpanded.sink { [weak self] _ in
            Task { @MainActor in self?.syncLists() }
        })
        observers.append(model.$petNotice.sink { [weak self] _ in
            Task { @MainActor in self?.syncPanel() }
        })
        // Hover no longer changes the fitted height (the pills cross-fade in
        // the bar's own slot), but the sink stays: allowsHitTesting and the
        // crossfade key off the flag, and a future revealed row costs nothing.
        observers.append(model.$petHoverRevealed.sink { [weak self] _ in
            Task { @MainActor in self?.syncPanel() }
        })
        observers.append(model.$petTerminalHint.sink { [weak self] _ in
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
                current: model.petSpritePose,
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
            current: model.petSpritePose,
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

    private func syncLists() {
        syncOutsideClickMonitor((model?.petExpanded ?? false) || (model?.petCompletionsExpanded ?? false))
        syncPanel()
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
                self?.model?.petCompletionsExpanded = false
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

    /// Reveal = hover intent OR a pinned list. A pin survives mouse-out, so a
    /// click-opened list never collapses under the cursor.
    private var pinnedList: Bool { model.petExpanded || model.petCompletionsExpanded }
    private var revealActive: Bool { model.petHoverRevealed || pinnedList }

    var body: some View {
        // Row order is load-bearing (0.5.142 ledger design): the panel keeps
        // its BOTTOM-LEFT origin on every resize, so content unfolds UPWARD.
        // Sprite and ledger sit at the bottom and never move on screen; hover
        // reveals (bubble, actions, pinned lists) grow above the ledger. The
        // character holding still is the entire point — the prototype's hover
        // was rebuilt once already because the pills pushed the sprite.
        VStack(spacing: size.length(8)) {
            if model.petExpanded, !sessions.isEmpty {
                sessionList
                    .modifier(PetReveal(reduceMotion: reduceMotion))
            }
            if model.petCompletionsExpanded, !model.petCompletions.isEmpty {
                completionsList
                    .modifier(PetReveal(reduceMotion: reduceMotion))
            }
            // No hover bubble or action buttons (Miles, 2026-08-30, on-device):
            // the pills open whatever is active, so a title card and a second
            // set of openers were pure redundancy. Hover changes NOTHING in
            // layout now — the bar cross-fades into the pills in its own slot,
            // and only a pill CLICK adds the list above the figure.
            if let hint = model.petTerminalHint, !hint.isEmpty {
                petFloatingText(hint, style: .secondary, lines: 2)
            }
            if let notice = model.petNotice, !notice.isEmpty {
                petFloatingText(notice, style: .primary, lines: 4)
            }
            // Sprite ABOVE the ledger (Miles, 2026-08-30): the bar reads as a
            // nameplate under the figure's feet. Both rows sit at the panel's
            // fixed bottom edge, so neither moves when reveals unfold above.
            // No focus dot: it floated at the figure's feet repeating what
            // the ledger's colored segments already say (Miles, 2026-08-30).
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
            .contentShape(Rectangle())
            // Declared before the single tap so SwiftUI resolves the double
            // FIRST — otherwise the opening click of a double-tap would jump
            // to the platform and the menu would open behind the raised app.
            .onTapGesture(count: 2) { toggleSessionMenu() }
            .onTapGesture { handleSpriteClick() }
            .accessibilityAddTraits(.isButton)
            .help(spriteHelp)
            .frame(width: viewportSize.width, height: viewportSize.height, alignment: .bottom)
            ledgerSlot
        }
        .padding(size.length(10))
        .frame(width: max(
            size.length(248),
            viewportSize.width + size.length(36)
        ))
        // NOT .onHover: SwiftUI's tracking area is tied to app activation, and
        // the pet lives on a nonactivating panel of an app that is almost
        // never active. The sensor registers .activeAlways itself.
        .background(HoverSensor { model.setPetHover($0) })
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleSpriteDrop(providers)
        }
    }

    // MARK: - Ledger (0.5.142)

    /// FIXED-height slot above the sprite. At rest the segmented bar and its
    /// caption; on hover the state pills CROSS-FADE into the same space.
    /// Nothing above the sprite may ever change size — that was the jumpy
    /// hover the prototype was rebuilt to kill.
    private var ledgerSlot: some View {
        let ledger = model.petLedger
        // A fully quiet pet (no sessions alive, nothing finished) has nothing
        // a pill could open — hovering would trade the meaningful IDLE capsule
        // for three dimmed, dead buttons. The reveal only arms when at least
        // one pill has a job.
        let revealArmed = !(sessions.isEmpty && model.petCompletions.isEmpty)
        let showPills = revealActive && revealArmed
        return ZStack {
            ledgerBar(ledger)
                .opacity(showPills ? 0 : 1)
            pillsRow(ledger)
                .opacity(showPills ? 1 : 0)
                .allowsHitTesting(showPills)
        }
        .frame(height: size.length(42))
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.26), value: revealActive)
    }

    private func ledgerBar(_ ledger: PetLedger) -> some View {
        let barWidth = size.length(150)
        let total = max(ledger.running + ledger.waiting + ledger.done, 1)
        return VStack(spacing: size.length(4)) {
            HStack(spacing: ledger.segments.count > 1 ? size.length(1) : 0) {
                ForEach(Array(ledger.segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle()
                        .fill(segmentColor(segment.kind))
                        .frame(width: barWidth * CGFloat(segment.count) / CGFloat(total))
                        .modifier(LedgerBreathing(
                            active: segment.kind == .running && !reduceMotion
                        ))
                }
            }
            .frame(width: barWidth, height: size.length(7), alignment: .leading)
            .background(Capsule().fill(COSPalette.line.opacity(0.35)))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(COSPalette.line, lineWidth: 1))
            Text(ledger.caption)
                .font(COSType.mono(size.typeSize(8), weight: .bold))
                .kerning(0.8)
                .foregroundStyle(ledger.isQuiet ? Color.secondary : COSPalette.plateInk)
        }
        // The pet floats over ARBITRARY wallpaper, and mono caps on a busy
        // pattern were unreadable (Miles, on-device, orange checkerboard). A
        // blur material pulls the ledger onto its own surface; the stroke
        // keeps an edge when Reduce Transparency turns the blur into a flat
        // fill. Same treatment as the pills' solid capsules, one layer softer.
        .padding(.horizontal, size.length(14))
        // Optically balanced, not numerically: with equal 6pt padding the
        // capsule measured ~20px of air above the bar against ~14px under the
        // caption on Miles's screenshot (caps have no descenders, so the text
        // box carries invisible bottom slack). Two points move top to bottom.
        .padding(.top, size.length(4))
        .padding(.bottom, size.length(6))
        .background(.thinMaterial, in: Capsule())
        .overlay(Capsule().stroke(COSPalette.line.opacity(0.7), lineWidth: 1))
    }

    private func pillsRow(_ ledger: PetLedger) -> some View {
        HStack(spacing: size.length(6)) {
            ledgerPill(
                dot: COSPalette.green, label: "RUNNING", count: ledger.running,
                enabled: !sessions.isEmpty, open: model.petExpanded, index: 0
            ) {
                model.petExpanded.toggle()
                if model.petExpanded { model.petCompletionsExpanded = false }
            }
            ledgerPill(
                dot: COSPalette.gold, label: "DONE", count: ledger.done,
                enabled: ledger.done > 0, open: model.petCompletionsExpanded, index: 1
            ) {
                model.petCompletionsExpanded.toggle()
                if model.petCompletionsExpanded { model.petExpanded = false }
            }
            ledgerPill(
                dot: COSPalette.amber, label: "WAITING", count: ledger.waiting,
                enabled: ledger.waiting > 0, open: false, index: 2
            ) {
                if let waitingSession = sessions.first(where: { $0.state == "waiting" }) {
                    model.openSessionInPlatform(waitingSession)
                }
            }
        }
    }

    private func ledgerPill(
        dot: Color, label: String, count: Int, enabled: Bool, open: Bool,
        index: Int, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: size.length(4)) {
                Circle()
                    .fill(enabled ? dot : Color.secondary.opacity(0.4))
                    .frame(width: size.length(6), height: size.length(6))
                Text("\(label) \(count)")
                    .font(COSType.mono(size.typeSize(8), weight: .bold))
                    .kerning(0.5)
            }
            .foregroundStyle(open ? COSPalette.cream : COSPalette.plateInk)
            .padding(.horizontal, size.length(8))
            .padding(.vertical, size.length(5))
            .background(Capsule().fill(open ? COSPalette.ink : COSPalette.card))
            .overlay(Capsule().stroke(open ? Color.clear : COSPalette.line, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        // The prototype's 4px settle with a per-pill stagger — deliberately a
        // gentle ease-out, not a spring; the overshoot read as jumpy.
        .offset(y: reduceMotion || revealActive ? 0 : size.length(4))
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.3).delay(Double(index) * 0.04),
            value: revealActive
        )
        .help(pillHelp(label))
    }

    private func pillHelp(_ label: String) -> String {
        switch label {
        case "RUNNING": "Live sessions"
        case "DONE": "Finished sessions"
        default: "Jump to the session waiting on you"
        }
    }

    private func segmentColor(_ kind: PetLedger.SegmentKind) -> Color {
        switch kind {
        case .waiting: COSPalette.amber
        case .running: COSPalette.green
        case .done: COSPalette.gold
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
                    // Inset from the overlay scroll indicator, which paints on
                    // the same right edge the drop x lives on.
                    content.padding(.trailing, size.length(10))
                }
                .frame(height: size.length(200))
            } else {
                content.padding(.trailing, size.length(10))
            }
        }
        .padding(.horizontal, size.length(10))
        .padding(.vertical, size.length(4))
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: size.length(12), style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: size.length(12), style: .continuous)
                .stroke(COSPalette.line, lineWidth: 1)
        )
    }

    /// Finished sessions. Lives on the ~310pt pet, so the list is capped and
    /// scrolls in a fixed frame — an unbounded ForEach outside a scroll frame
    /// is the Add-a-voice 34-row failure again.
    private var completionsList: some View {
        // FIXED height when overflowing, mirroring sessionList above. The first
        // build capped the ScrollView with a maximum-height frame — but the
        // panel sizes itself with sizeThatFits, under which a ScrollView's
        // ideal height collapses, so six chips rendered as an empty white
        // capsule with every row unreachable (Miles, 2026-08-30).
        let content = VStack(alignment: .leading, spacing: 0) {
                ForEach(model.petCompletions) { row in
                    HStack(spacing: 0) {
                    Button {
                        if let session = ClaudeSession.fromCompletion(row) {
                            presenter.openInControl(session)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: size.length(8)) {
                            Text(row.provider.uppercased())
                                .font(COSType.mono(size.typeSize(8), weight: .bold))
                                .foregroundStyle(providerTint(row.provider))
                                .frame(width: size.length(44), alignment: .leading)
                            VStack(alignment: .leading, spacing: size.length(2)) {
                                Text(row.name)
                                    .font(COSType.body(size.typeSize(11), weight: row.seen ? .regular : .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("Finished")
                                    .font(COSType.body(size.typeSize(10)))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, size.length(7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open in COS Control")
                    // Clear control is a SIBLING of the row button, never nested
                    // in its label — a Button inside another Button's label
                    // never receives the click. Mirrors the live list's drop x.
                    Button {
                        model.clearPetCompletion(row)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: size.typeSize(9), weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(size.length(5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear this finished entry.")
                    }
                    if row.id != model.petCompletions.last?.id {
                        Divider()
                    }
                }
            }
        return Group {
            if model.petCompletions.count > 3 {
                ScrollView {
                    // Inset from the overlay scroll indicator, which paints on
                    // the same right edge the clear x lives on.
                    content.padding(.trailing, size.length(10))
                }
                .frame(height: size.length(160))
            } else {
                content.padding(.trailing, size.length(10))
            }
        }
        .padding(.horizontal, size.length(10))
        .padding(.vertical, size.length(4))
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: size.length(12), style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: size.length(12), style: .continuous)
                .stroke(COSPalette.line, lineWidth: 1)
        )
    }

    /// One surface language for text floating over wallpaper: the ledger's
    /// blur material on the lists' 12pt rounded rect. The old Capsule grew
    /// fat semicircular flanks around multi-line notices.
    private func petFloatingText(_ text: String, style: HierarchicalShapeStyle, lines: Int) -> some View {
        Text(text)
            .font(COSType.body(size.typeSize(10)))
            .foregroundStyle(style)
            .lineLimit(lines)
            .padding(.horizontal, size.length(12))
            .padding(.vertical, size.length(6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: size.length(12), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size.length(12), style: .continuous)
                    .stroke(COSPalette.line, lineWidth: 1)
            )
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
        if model.petExpanded { model.petCompletionsExpanded = false }
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

    private func providerTint(_ provider: String) -> Color {
        switch provider {
        case "codex": Color(red: 0.10, green: 0.55, blue: 0.48)
        case "cursor": Color(red: 0.42, green: 0.38, blue: 0.86)
        default: Color(red: 0.78, green: 0.45, blue: 0.22)
        }
    }
}

/// Fade-in with a 4pt rise for content that just entered the layout. Appear
/// only — disappear is handled by the model's settle phase, which fades the
/// content BEFORE the frame shrinks (a removal transition would be clipped by
/// the already-shrunk panel).
private struct PetReveal: ViewModifier {
    var reduceMotion: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: reduceMotion || shown ? 0 : 4)
            .onAppear {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { shown = true }
            }
            .onDisappear { shown = false }
    }
}

/// Subtle life on the running segment: a slow opacity breathe, well inside the
/// "just a little bit" band (the 11px-oscillation correction applies to any
/// at-rest motion). Never runs under reduced motion or on non-running kinds.
private struct LedgerBreathing: ViewModifier {
    var active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.62 : 1)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

/// AppKit tracking area with `.activeAlways`. SwiftUI's `.onHover` arms only
/// while the app is active, and the pet is a nonactivating panel of a menu-bar
/// app — its hover would effectively never fire. `hitTest` returns nil so the
/// sensor can never swallow a click meant for the sprite or a pill.
private struct HoverSensor: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverSensorView {
        HoverSensorView(onChange: onChange)
    }

    func updateNSView(_ view: HoverSensorView, context: Context) {
        view.onChange = onChange
    }
}

final class HoverSensorView: NSView {
    var onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) { onChange(true) }
    override func mouseExited(with event: NSEvent) { onChange(false) }
}
