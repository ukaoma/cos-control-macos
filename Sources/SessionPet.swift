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
    /// The bottom-left the user parked the pet at. Every frame is rebuilt
    /// from this, so a clamp that slides an expanded panel down to stay on
    /// screen can never become the new resting place.
    private var restingAnchor: CGPoint?
    /// windowDidMove fires for our own setFrame too; only a real drag may
    /// move the anchor.
    private var applyingFrame = false

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
            let size = NSSize(width: width, height: max(fitting.height, model.petSize.length(120)))
            let anchor = restingAnchor ?? CGPoint(x: panel.frame.minX, y: panel.frame.minY)
            restingAnchor = anchor
            let screens = NSScreen.screens.map(\.visibleFrame)
            applyingFrame = true
            panel.setFrame(
                PetPanelFrame.positioned(size: size, anchor: anchor, screens: screens),
                display: true
            )
            applyingFrame = false
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
        let placed = PetPanelFrame.clamped(frame, screens: screens)
        panel.setFrame(placed, display: false)
        restingAnchor = CGPoint(x: placed.minX, y: placed.minY)
        self.panel = panel
        return panel
    }

    /// A drag re-parks the pet. Our own setFrame also posts this, so the
    /// applyingFrame guard is what keeps a clamped slide out of the anchor.
    func windowDidMove(_ notification: Notification) {
        guard !applyingFrame, let panel else { return }
        restingAnchor = CGPoint(x: panel.frame.minX, y: panel.frame.minY)
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
    /// Which row the pointer is on. Direction D reveals a row's three paths
    /// and starts its ticker on hover, and the pointer can only be on one row,
    /// so exactly one line ever moves.
    @State private var hoveredRowID: String?
    private var pinnedList: Bool { model.petExpanded || model.petCompletionsExpanded }
    private var revealActive: Bool { model.petHoverRevealed || pinnedList }
    /// A fully quiet pet — nothing alive, nothing finished, nothing hidden by
    /// a dismissal — has no pill with a job, so hover would only trade the
    /// IDLE capsule for dead buttons. Dismissal stamps count as a job: the
    /// live list is the ONLY home of the restore control, and a pet whose one
    /// running session was dropped must stay recoverable from its own UI.
    private var revealArmed: Bool {
        !(sessions.isEmpty && model.petCompletions.isEmpty
          && model.petDismissals.stamps.isEmpty)
    }
    /// The ONE truth for the ledger crossfade: every pill opacity, hit test,
    /// and animation keys on this so an armed-state flip mid-hover still
    /// animates instead of snapping.
    private var showPills: Bool { revealActive && revealArmed }

    var body: some View {
        // Row order is load-bearing (0.5.142 ledger design): the panel keeps
        // its BOTTOM-LEFT origin on every resize, so content unfolds UPWARD.
        // Sprite and ledger ride the panel's bottom edge and a pill-pinned
        // list grows above them, so opening a list never pushes the figure
        // DOWNWARD. Where the expanded panel would overrun the screen top the
        // clamp slides the whole panel down to fit — measured at -75pt from a
        // y=300 park, -375pt from y=600 — and closing puts it back exactly.
        // That slide is the only thing that moves the figure, and it never
        // accumulates (see PetPanelFrame.positioned).
        // The live list also opens when only dismissal stamps remain: the
        // restore row inside it is the sole route back for a dropped session.
        VStack(spacing: size.length(8)) {
            if model.petExpanded, !sessions.isEmpty || !model.petDismissals.stamps.isEmpty {
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
        // Direction D (0.5.171): the sprite no longer decides how wide the
        // reading surface is. At 248 a finished row left the title 68pt, which
        // is ten characters of DM Sans 11 — measured, and exactly the "You
        // match…" Miles screenshotted.
        .frame(width: max(
            size.length(392),
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
        return ZStack {
            ledgerBar(ledger)
                .opacity(showPills ? 0 : 1)
            pillsRow(ledger)
                .opacity(showPills ? 1 : 0)
                .allowsHitTesting(showPills)
        }
        .frame(height: size.length(42))
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.26), value: showPills)
    }

    private func ledgerBar(_ ledger: PetLedger) -> some View {
        let barWidth = size.length(150)
        let total = max(ledger.running + ledger.waiting + ledger.done, 1)
        return VStack(spacing: size.length(4)) {
            HStack(spacing: ledger.segments.count > 1 ? size.length(1) : 0) {
                ForEach(ledger.segments, id: \.kind) { segment in
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
        .overlay(Capsule().stroke(COSPalette.line, lineWidth: 1))
    }

    private func pillsRow(_ ledger: PetLedger) -> some View {
        HStack(spacing: size.length(6)) {
            ledgerPill(
                dot: COSPalette.green, label: "RUNNING", count: ledger.running,
                enabled: !sessions.isEmpty || !model.petDismissals.stamps.isEmpty,
                open: model.petExpanded, index: 0
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
                // One waiting session jumps; several open the list so the
                // choice is yours instead of arbitrary.
                if let only = ClaudeSession.petWaitingJumpTarget(sessions) {
                    model.petFocusID = only.id
                    model.openSessionInPlatform(only)
                } else {
                    model.petExpanded = true
                    model.petCompletionsExpanded = false
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
        .offset(y: reduceMotion || showPills ? 0 : size.length(4))
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.3).delay(Double(index) * 0.04),
            value: showPills
        )
        .help(pillHelp(label))
    }

    private func pillHelp(_ label: String) -> String {
        switch label {
        case "RUNNING": "Live sessions"
        case "DONE": "Finished sessions"
        default: "Open the session waiting on you"
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
        // Mission rows (0.5.155, Miles-approved design B): one list, three
        // weights. Running rows are heavy and alive — rail, two-line title,
        // the mono LIVE line, workspace. Waiting gets its own amber section.
        // Idle recedes to dim one-liners. Section membership comes from the
        // executable ClaudeSession.petSections, never re-derived here.
        let grouped = ClaudeSession.petSections(sessions)
        let content = VStack(alignment: .leading, spacing: 0) {
            if !grouped.running.isEmpty {
                petSectionHeader("RUNNING", count: grouped.running.count, tint: COSPalette.green)
                ForEach(Array(grouped.running.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider() }
                    missionRow(session, tint: COSPalette.green)
                }
            }
            if !grouped.waiting.isEmpty {
                petSectionHeader("WAITING ON YOU", count: grouped.waiting.count, tint: COSPalette.amber)
                ForEach(Array(grouped.waiting.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider() }
                    missionRow(session, tint: COSPalette.amber)
                }
            }
            if !grouped.idle.isEmpty {
                petSectionHeader("IDLE", count: grouped.idle.count, tint: Color.secondary)
                ForEach(Array(grouped.idle.enumerated()), id: \.element.id) { index, session in
                    if index > 0 { Divider() }
                    idleRow(session)
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
            if sessions.count > 3 {
                ScrollView {
                    content
                }
                .scrollIndicators(.hidden)
                .frame(height: size.length(240))
            } else {
                content
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

    private func petSectionHeader(_ label: String, count: Int, tint: Color) -> some View {
        HStack(spacing: size.length(5)) {
            Circle()
                .fill(tint)
                .frame(width: size.length(6), height: size.length(6))
            Text("\(label) \(count)")
                .font(COSType.mono(size.typeSize(8), weight: .bold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, size.length(7))
        .padding(.bottom, size.length(3))
    }

    /// A live session as a Direction D row. The outcome leads on its own
    /// line; identity is demoted underneath. Actions are SIBLINGS of the row
    /// button, never nested in its label — a nested Button never receives the
    /// click on macOS.
    private func missionRow(_ session: ClaudeSession, tint: Color) -> some View {
        petRowD(
            id: session.id,
            outcome: session.petLiveLine,
            title: session.title,
            mark: session.petProviderMark,
            markTint: providerTint(session.provider),
            tint: tint,
            age: session.compactAgeLabel() ?? "",
            workspace: session.workspace,
            breathing: session.isPetWorking,
            dim: false,
            primary: {
                model.petFocusID = session.id
                model.openSessionInPlatform(session)
            },
            actions: PetRowActions(
                openInPlatform: {
                    model.petFocusID = session.id
                    model.openSessionInPlatform(session)
                },
                openInControl: { presenter.openInControl(session) },
                clear: model.canDismissPetSession(session)
                    ? { model.dismissPetSession(session) } : nil,
                clearLabel: "Drop from the list",
                clearHelp: "Drop from the pet list. The session keeps running."
            )
        )
    }

    /// An idle-alive session: the same row, dimmed. The fleet's periphery
    /// should read as periphery, but it must not read as a DIFFERENT shape.
    private func idleRow(_ session: ClaudeSession) -> some View {
        petRowD(
            id: session.id,
            outcome: session.petLiveLine,
            title: session.title,
            mark: session.petProviderMark,
            markTint: providerTint(session.provider).opacity(0.75),
            tint: Color.secondary,
            age: session.compactAgeLabel() ?? "",
            workspace: session.workspace,
            breathing: false,
            dim: true,
            primary: {
                model.petFocusID = session.id
                model.openSessionInPlatform(session)
            },
            actions: PetRowActions(
                openInPlatform: {
                    model.petFocusID = session.id
                    model.openSessionInPlatform(session)
                },
                openInControl: { presenter.openInControl(session) },
                clear: model.canDismissPetSession(session)
                    ? { model.dismissPetSession(session) } : nil,
                clearLabel: "Drop from the list",
                clearHelp: "Drop from the pet list. The session keeps running."
            )
        )
    }

    /// The three paths off a row. Optional so a row that cannot be dropped
    /// simply does not offer it, rather than offering a dead control.
    private struct PetRowActions {
        var openInPlatform: (() -> Void)?
        var openInControl: (() -> Void)?
        var clear: (() -> Void)?
        var clearLabel: String = "Clear this entry"
        var clearHelp: String = "Clear this finished entry"
    }

    /// ONE row shape for every list (Direction D, Miles 2026-09-01). Line one
    /// is what the session did or is doing, in the body face at 12pt, inside a
    /// ticker window that scrolls ONLY while this row is hovered. Line two is
    /// identity: the platform glyph and the title. The trailing slot is a
    /// FIXED 57pt frame with two occupants that cross-fade, so hover changes
    /// no layout — the same contract ledgerSlot holds one layer up, and the
    /// reason the first hover prototype was rebuilt.
    private func petRowD(
        id: String,
        outcome: String,
        title: String,
        mark: PetProvider.Mark,
        markTint: Color,
        tint: Color,
        age: String,
        workspace: String,
        breathing: Bool,
        dim: Bool,
        primary: @escaping () -> Void,
        actions: PetRowActions
    ) -> some View {
        let hovered = hoveredRowID == id
        return HStack(spacing: 0) {
            Button(action: primary) {
                VStack(alignment: .leading, spacing: size.length(2)) {
                    HStack(spacing: size.length(6)) {
                        if breathing {
                            Circle()
                                .fill(tint)
                                .frame(width: size.length(5), height: size.length(5))
                                .modifier(LedgerBreathing(active: !reduceMotion))
                        }
                        TickerLine(
                            text: outcome,
                            fontSize: size.typeSize(12),
                            tint: dim ? Color.secondary : Color.primary,
                            reduceMotion: reduceMotion,
                            face: .body,
                            weight: .semibold,
                            active: hovered
                        )
                    }
                    HStack(spacing: size.length(5)) {
                        providerGlyph(mark, tint: markTint)
                        Text(title)
                            .font(COSType.body(size.typeSize(9)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.vertical, size.length(7))
                .padding(.leading, size.length(11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in platform")
            petRowSlot(age: age, workspace: workspace, tint: tint,
                       hovered: hovered, actions: actions)
        }
        // The rail is an OVERLAY, never an HStack child: a bare Shape in the
        // row accepts any offered height, and under the panel's sizeThatFits
        // probe one running row absorbed ~800px of blank card (2026-08-31).
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: size.length(2))
                .fill(tint)
                .frame(width: size.length(3))
                .padding(.vertical, size.length(6))
        }
        // Give back most of the list's 10pt inset so the trailing items sit
        // TUCKED toward the card edge without landing on it. Cancelling the
        // full 10pt put the age, the workspace and both glyphs flush against
        // the 1px stroke, which reads as clipped (Miles, 2026-09-01: "the x
        // and the tab target are nested right against the right. no padding").
        // 4pt back leaves a 6pt margin: closer than the default 10pt he
        // objected to earlier the same day, clear of the border he objects to
        // now. The slot's own -4pt glyph overhang is an INK alignment against
        // rowAction's 4pt hit padding and is deliberately left alone.
        .padding(.trailing, -size.length(4))
        // NOT .onHover: SwiftUI's tracking area is tied to app activation and
        // the pet is a nonactivating panel, so it would effectively never fire.
        .background(HoverSensor { inside in
            if inside { hoveredRowID = id } else if hoveredRowID == id { hoveredRowID = nil }
        })
        // The slot's three paths are pointer-only. They must also exist where
        // a pointer is not the input.
        .contextMenu {
            if let open = actions.openInPlatform {
                Button("Open in platform", action: open)
            }
            if let control = actions.openInControl {
                Button("Open the session view", action: control)
            }
            if let clear = actions.clear {
                Button(actions.clearLabel, action: clear)
            }
        }
    }

    /// The trailing slot: one FIXED frame, two occupants. At rest the age over
    /// the workspace; under the pointer the three paths. Only opacity crosses.
    private func petRowSlot(
        age: String, workspace: String, tint: Color,
        hovered: Bool, actions: PetRowActions
    ) -> some View {
        ZStack(alignment: .trailing) {
            VStack(alignment: .trailing, spacing: size.length(2)) {
                Text(age)
                    .font(COSType.mono(size.typeSize(8), weight: .bold))
                    .foregroundStyle(tint)
                Text(workspace.lowercased())
                    .font(COSType.body(size.typeSize(8)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(hovered ? 0 : 1)

            HStack(spacing: 0) {
                if let open = actions.openInPlatform {
                    rowAction("arrow.up.forward.app", help: "Open in platform", action: open)
                }
                if let control = actions.openInControl {
                    rowAction("text.alignleft",
                              help: "Open the session view in COS Control", action: control)
                }
                if let clear = actions.clear {
                    rowAction("xmark", help: actions.clearHelp, action: clear)
                }
            }
            // The trailing symbol carries its own 4pt hit padding. Overhang by
            // exactly that, so the glyph's INK lands on the card edge the age
            // and workspace already sit on. The 57pt frame does not move.
            .padding(.trailing, -size.length(4))
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
        }
        .frame(width: size.length(57), alignment: .trailing)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovered)
    }

    /// One platform mark for every row type, so a provider can never look
    /// different in one list than in another. Direction D puts it on the
    /// identity line beside the title, where the 54pt wordmark block it
    /// replaced was spending width the title needed.
    private func providerGlyph(_ mark: PetProvider.Mark, tint: Color) -> some View {
        Group {
            switch mark {
            case .asset(let name):
                // The real logo, bundled and tinted like every other template
                // mark in the app, so it reads in light and dark alike.
                Image(nsImage: COSBrand.svg(name))
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size.typeSize(11), height: size.typeSize(11))
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: size.typeSize(10), weight: .bold))
            }
        }
        .foregroundStyle(tint)
        .frame(width: size.typeSize(12), alignment: .leading)
    }

    /// One shared control for a row's three paths, so they cannot drift in
    /// size, tint or hit area.
    private func rowAction(
        _ symbol: String, help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size.typeSize(9), weight: .bold))
                .foregroundStyle(.secondary)
                .padding(size.length(4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
                    petRowD(
                        id: row.id,
                        // The row now says what the session DID. Before 0.5.171
                        // every finished row printed the literal "Finished", so
                        // two forked sessions read as the same three tokens.
                        outcome: row.summary.isEmpty ? "Finished" : row.summary,
                        title: row.name,
                        mark: PetProvider.mark(row.provider),
                        markTint: providerTint(row.provider),
                        tint: COSPalette.gold,
                        age: PetCompletion.compactAge(row.finishedAt),
                        workspace: row.workspace,
                        breathing: false,
                        dim: row.seen,
                        primary: {
                            if let session = ClaudeSession.fromCompletion(row) {
                                presenter.openInControl(session)
                            }
                        },
                        actions: PetRowActions(
                            openInPlatform: {
                                if let session = ClaudeSession.fromCompletion(row) {
                                    model.openSessionInPlatform(session)
                                }
                            },
                            openInControl: {
                                if let session = ClaudeSession.fromCompletion(row) {
                                    presenter.openInControl(session)
                                }
                            },
                            clear: { model.clearPetCompletion(row) },
                            clearLabel: "Clear this entry",
                            clearHelp: "Clear this finished entry"
                        )
                    )
                    if row.id != model.petCompletions.last?.id {
                        Divider()
                    }
                }
            }
        return Group {
            if model.petCompletions.count > 3 {
                ScrollView {
                    content
                }
                // The overlay indicator painted on the same right edge the
                // row's controls live on, and the 10pt inset that dodged it
                // is exactly the dead space Miles kept pointing at.
                .scrollIndicators(.hidden)
                .frame(height: size.length(160))
            } else {
                content
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: size.length(12), style: .continuous))
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

    private func providerTint(_ provider: String) -> Color {
        switch provider {
        case "codex": Color(red: 0.10, green: 0.55, blue: 0.48)
        case "cursor": Color(red: 0.42, green: 0.38, blue: 0.86)
        default: Color(red: 0.78, green: 0.45, blue: 0.22)
        }
    }
}

/// The LIVE line's news ticker. A fixed window, hidden overflow, and the
/// text sliding through it — only when it actually overflows. Two copies
/// separated by a gap make the wrap seamless; the width comes from the
/// monospaced advance in PetTicker, so no layout pass is needed to decide.
private struct TickerLine: View {
    let text: String
    let fontSize: CGFloat
    let tint: Color
    var reduceMotion: Bool
    /// The measurement face. The 0.6em fast path is a fact about JetBrains
    /// Mono ONLY; asking it about a proportional face would answer "it fits"
    /// for text that overflows, and the window would clip it with neither
    /// motion nor an ellipsis.
    var face: PetTicker.Face = .mono
    var weight: Font.Weight = .bold
    /// Hover gate (0.5.171). Four stacked rows scrolling at once is noise, and
    /// the pointer is on one row, so exactly one line moves. The 1.4s hold
    /// covers a pointer sweeping down the list without stopping.
    var active: Bool = true
    @State private var rolling = false

    var body: some View {
        GeometryReader { geo in
            let travel = PetTicker.width(text, fontSize: fontSize, face: face) + PetTicker.gap
            let scrolls = !reduceMotion && active
                && PetTicker.scrolls(text, fontSize: fontSize,
                                     container: geo.size.width, face: face)
            Group {
                if scrolls {
                    HStack(spacing: PetTicker.gap) {
                        tickerText
                        // The second copy exists ONLY to cover the wrap;
                        // without it the line blanks out between loops.
                        tickerText
                    }
                    .fixedSize()
                    .offset(x: rolling ? -travel : 0)
                } else {
                    // NOT fixedSize: that forces full width, so lineLimit
                    // never truncates and a too-long line is cut mid-glyph
                    // with no ellipsis — the permanent state of every running
                    // row under Reduce Motion (QA, 2026-08-31).
                    tickerText.truncationMode(.tail)
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
            // Keyed on the text AND the geometry that decides whether it
            // scrolls: keying on text alone left the ticker frozen when the
            // row narrowed under it (the drop x appears at ten minutes).
            .task(id: "\(text)|\(scrolls)|\(fontSize)") {
                rolling = false
                guard scrolls else { return }
                try? await Task.sleep(for: .seconds(PetTicker.startHold))
                guard !Task.isCancelled else { return }
                withAnimation(
                    .linear(duration: PetTicker.loopDuration(text, fontSize: fontSize, face: face))
                        .repeatForever(autoreverses: false)
                ) {
                    rolling = true
                }
            }
        }
        .frame(height: fontSize * 1.7)
    }

    private var tickerText: some View {
        Text(text)
            .font(face == .mono ? COSType.mono(fontSize, weight: weight)
                                : COSType.body(fontSize, weight: weight))
            .foregroundStyle(tint)
            .lineLimit(1)
    }
}

/// Fade-in with a 4pt rise for content that just entered the layout. Appear
/// only, by design: pinned lists close on a click (pill or outside), and an
/// instant close under a deliberate click reads as response, not as motion
/// worth animating.
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
            .onAppear { sync() }
            // Starting only on appear left a recycled segment that BECAME
            // running permanently still (QA, 2026-08-31).
            .onChange(of: active) { _, _ in sync() }
    }

    private func sync() {
        guard active else {
            dim = false
            return
        }
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            dim = true
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
