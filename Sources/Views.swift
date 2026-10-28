import SwiftUI
import AppKit
import Carbon.HIToolbox

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
    // 0.5.221 — the Memories theme's accent, danger, muted and raised values
    // (memories-theme.css light, memories.html dark), so a native pane reads
    // the same as the web one in both appearances. Gold (#c9a86e) is too faint
    // to read as text on a white card; the light accent is the theme's #89662d.
    static let accentNS = adaptiveNSColor(
        light: NSColor(red: 0.537, green: 0.400, blue: 0.176, alpha: 1),  // #89662d
        dark:  NSColor(red: 0.788, green: 0.659, blue: 0.431, alpha: 1))  // #c9a86e
    static let dangerNS = adaptiveNSColor(
        light: NSColor(red: 0.647, green: 0.278, blue: 0.196, alpha: 1),  // #a54732
        dark:  NSColor(red: 0.910, green: 0.643, blue: 0.580, alpha: 1))  // #e8a494
    static let mutedNS = adaptiveNSColor(
        light: NSColor(red: 0.455, green: 0.447, blue: 0.427, alpha: 1),  // #74726d
        dark:  NSColor(red: 0.733, green: 0.682, blue: 0.604, alpha: 1))  // #bbae9a
    static let raisedNS = adaptiveNSColor(
        light: NSColor(red: 0.933, green: 0.910, blue: 0.867, alpha: 1),  // #eee8dd
        dark:  NSColor(red: 0.188, green: 0.153, blue: 0.122, alpha: 1))  // #30271f
    // 0.5.283 (What's New in COS styling). Muted (#74726d) is 4.2:1 on the cream panel, under 4.5, so secondary words
    // set on the panel itself use this darker warm grey (5.3:1 on cream, 4.9:1 on raised); dark keeps muted's value.
    static let subtleNS = adaptiveNSColor(
        light: NSColor(red: 0.400, green: 0.388, blue: 0.369, alpha: 1),  // #66635e
        dark:  NSColor(red: 0.733, green: 0.682, blue: 0.604, alpha: 1))  // #bbae9a
    // A secondary button's hairline, visible on the panel in both appearances.
    static let borderNS = adaptiveNSColor(
        light: NSColor(red: 0.847, green: 0.800, blue: 0.714, alpha: 1),  // #d8ccb6
        dark:  NSColor(red: 0.290, green: 0.231, blue: 0.169, alpha: 1))  // #4a3b2b
    // Words on an accent fill: white on #89662d (5.3:1), ink on #c9a86e (7.8:1).
    static let onAccentNS = adaptiveNSColor(
        light: NSColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        dark:  NSColor(red: 0.12, green: 0.09, blue: 0.07, alpha: 1))
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

enum COSPalette {
    static let ink = Color(red: 0.12, green: 0.09, blue: 0.07)   // dark brand tile (both modes)
    static let panel = Color(nsColor: COSInk.panelNS)            // adaptive
    static let card = Color(nsColor: COSInk.cardNS)              // adaptive
    static let line = Color(nsColor: COSInk.lineNS)              // adaptive
    static let cream = Color(red: 0.96, green: 0.94, blue: 0.90) // COS mark on the ink tile
    static let gold = Color(red: 0.79, green: 0.66, blue: 0.43)  // gotcos.com gold
    static let amber = Color(red: 0.79, green: 0.50, blue: 0.27)
    static let green = Color(red: 0.20, green: 0.58, blue: 0.34)
    static let accent = Color(nsColor: COSInk.accentNS)          // adaptive: text-weight gold
    static let danger = Color(nsColor: COSInk.dangerNS)          // adaptive: destructive ink
    static let muted = Color(nsColor: COSInk.mutedNS)            // adaptive: warm secondary text
    static let raised = Color(nsColor: COSInk.raisedNS)          // adaptive: inset strip on a card
    static let live = Color(red: 0.86, green: 0.27, blue: 0.22)  // 0.5.278: the recording dot (live transcript)
    static let subtle = Color(nsColor: COSInk.subtleNS)          // 0.5.283 adaptive: secondary words on the panel
    static let border = Color(nsColor: COSInk.borderNS)          // 0.5.283 adaptive: a secondary button's hairline
    static let onAccent = Color(nsColor: COSInk.onAccentNS)      // 0.5.283 adaptive: words on an accent fill
}

private enum CharacterGallery {
    static let height: CGFloat = 220
}

/// The update banner at the top of the menu-bar panel (Miles, 2026-10-09 08:14, with screenshots of Vorssant: a full
/// width banner, a circled down arrow, "Update available", the version under it, an Update button on the right). A card
/// in the panel's own layout, never a sheet or a window. Gold with ink words while an update is ready or installing;
/// the panel's card with a danger edge when the install failed, with the helper's own words and Try again.
struct AppUpdateBanner: View {
    let flow: AppUpdateFlow
    var disabled = false
    let onUpdate: () -> Void

    private var failed: String? {
        if case .failed(let message) = flow.phase { return message }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            icon.frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(COSType.body(13, weight: .bold))
                Text(detail)
                    .font(COSType.body(11))
                    .opacity(failed == nil ? 0.78 : 1)
                    .foregroundStyle(failed == nil ? AnyShapeStyle(COSPalette.ink) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            }
            Spacer(minLength: 8)
            action.layoutPriority(1)
        }
        .foregroundStyle(failed == nil ? COSPalette.ink : Color.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(failed == nil ? COSPalette.gold : COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(failed == nil ? Color.clear : COSPalette.danger.opacity(0.55), lineWidth: 1))
    }

    /// 0.5.322: the words are AppUpdateBannerWords (Models.swift), so Tests/AppUpdateBadgeChecks.swift reads them.
    private var words: AppUpdateBannerWords { AppUpdateBannerWords(flow) }
    private var title: String { words.title }
    private var detail: String { words.detail }

    @ViewBuilder private var icon: some View {
        switch flow.phase {
        case .staging, .applying:
            COSSpinner(size: 18, ink: COSPalette.ink, track: COSPalette.ink.opacity(0.18))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(COSPalette.danger)
        case .none, .ready:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(COSPalette.gold, COSPalette.ink)
        }
    }

    @ViewBuilder private var action: some View {
        switch flow.phase {
        case .ready where flow.finishesStaged:
            // One click: the build is already downloaded and checked (ControllerModel.finishStagedAppUpdate).
            Button(words.action ?? "Install", action: onUpdate)
                .buttonStyle(AppUpdateBannerButtonStyle())
                .disabled(disabled)
                .help("Install the update that is already downloaded and checked. COS Control closes and reopens.")
        case .none, .ready:
            Button("Update", action: onUpdate)
                .buttonStyle(AppUpdateBannerButtonStyle())
                .disabled(disabled)
                .help("See what is new in this update, then download and install it.")
        case .failed:
            Button("Try again", action: onUpdate)
                .buttonStyle(COSPrimaryButtonStyle())
                .disabled(disabled)
        case .staging, .applying:
            EmptyView()
        }
    }
}

/// The banner's Update: an ink pill on the gold, as the reference's white pill on its blue.
private struct AppUpdateBannerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(COSType.body(12, weight: .semibold))
            .foregroundStyle(COSPalette.cream)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(COSPalette.ink.opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// 2026-10-09 (Miles, 13:09, with screenshots of Vorssant): "show a proper What's New window" when Update is clicked.
/// A real window, never a sheet on the panel or an alert: the panel is a MenuBarExtra that closes as soon as focus
/// moves, and an install that is running must stay visible. One window at a time: opening it again brings the same
/// window forward. Closing it stops nothing; an install already running carries on and Control reopens by itself.
@MainActor
final class WhatsNewWindowPresenter {
    private(set) var controller: NSWindowController?
    /// How many windows this presenter has made. One for the life of the app (Tests/WhatsNewRender.swift).
    private(set) var windowsMade = 0
    /// 0.5.337 (performance audit W6): the kept window's content observes the model only while the window is open. A
    /// closed What's New window was still redrawn on every model change (WhatsNewView.body in the idle sample).
    let slot = WhatsNewSlot()
    private var closeObserver: NSObjectProtocol?

    /// The window, made once and kept (`isReleasedWhenClosed` is false); never ordered in here. `show` orders it in.
    @discardableResult
    func prepare(model: ControllerModel) -> NSWindow {
        if let window = controller?.window { return window }
        slot.live = true
        let host = NSHostingController(rootView: WhatsNewWindowRoot(model: model, slot: slot) { [weak self] in self?.close() })
        let window = NSWindow(contentViewController: host)
        window.title = "What's New in COS Control"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = COSInk.panelNS
        window.setContentSize(NSSize(width: WhatsNewView.width, height: WhatsNewView.height))
        window.isReleasedWhenClosed = false
        window.center()
        controller = NSWindowController(window: window)
        windowsMade += 1
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.slot.live = false }
        }
        return window
    }

    func show(model: ControllerModel) {
        let window = prepare(model: model)
        if !slot.live { slot.live = true }
        // Centered again whenever it is not already on screen, so a reopen never lands where it was last dragged off to.
        if !window.isVisible { window.center() }
        controller?.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Cancel, Close, and the window's close button. The install flow is the model's, so this never touches it.
    func close() {
        controller?.window?.close()
    }
}

/// The window's root: the model's mode, offer, flow and frozen words, with Download and install wired to
/// installAppUpdate.
@MainActor final class WhatsNewSlot: ObservableObject {
    @Published var live = true
}

struct WhatsNewWindowRoot: View {
    let model: ControllerModel
    @ObservedObject var slot: WhatsNewSlot
    let close: () -> Void
    init(model: ControllerModel, slot: WhatsNewSlot = WhatsNewSlot(), close: @escaping () -> Void) {
        self.model = model; self.slot = slot; self.close = close
    }

    var body: some View {
        if slot.live { WhatsNewWindowContent(model: model, close: close) } else { Color.clear.frame(width: WhatsNewView.width, height: WhatsNewView.height) }
    }
}

/// The open window's content: the only part that observes the model.
struct WhatsNewWindowContent: View {
    @ObservedObject var model: ControllerModel
    let close: () -> Void

    var body: some View {
        WhatsNewView(presentation: WhatsNewPresentation.present(model.whatsNewMode, info: model.appUpdate, flow: model.appUpdateFlow,
                                                                frozen: model.whatsNewFrozen, busy: model.busy),
                     onInstall: { model.installAppUpdate() }, onCancel: close)
    }
}

/// The What's New layout, as the reference: a large title naming the release, the build as a small byline, a scrolling
/// body (the summary, then each section as a sentence-case heading with dotted rows), and a footer pinned to the bottom
/// with Cancel on the left and Download and install on the right (Done alone after an update). 0.5.283 (Miles,
/// 2026-10-11, the polish round's Mac What's New board): COS styling instead of a white slab. The window is the cream
/// panel, the summary and each section sit on their own card (white, or raised espresso in dark), headings are
/// Fraunces, words DM Sans, the build line JetBrains Mono, and the primary button is the accent gold. Every color is an
/// adaptive palette token, so the window follows light and dark live. Every string is drawn verbatim (no Markdown, no
/// links).
struct WhatsNewView: View {
    static let width: CGFloat = 620
    static let height: CGFloat = 620

    let presentation: WhatsNewPresentation
    let onInstall: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let footer = presentation.footer
        let content = presentation.content
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: presentation.title)
                    .font(COSType.display(28, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                if let byline = presentation.byline {
                    Text(verbatim: byline)
                        .font(COSType.mono(12.5))
                        .foregroundStyle(COSPalette.subtle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 38)
            .padding(.bottom, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    WhatsNewSection(title: "Summary") {
                        Text(verbatim: content.summaryText)
                            .font(COSType.body(13.5))
                            .lineSpacing(3)
                            .foregroundStyle(Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    ForEach(Array(content.sections.enumerated()), id: \.offset) { _, section in
                        WhatsNewSection(title: section.title) {
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                    WhatsNewBullet(text: item)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.top, 4)
                .padding(.bottom, 18)
            }
            Rectangle().fill(COSPalette.line).frame(height: 1)
            footerBar(footer)
        }
        .frame(width: Self.width, height: Self.height)
        .background(COSPalette.panel)
        .cosControlTheme()
    }

    private func footerBar(_ footer: WhatsNewFooter) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let status = footer.status {
                HStack(alignment: .top, spacing: 8) {
                    if footer.working {
                        COSSpinner(size: 13)
                    } else if footer.failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(COSPalette.danger)
                    }
                    Text(verbatim: status)
                        .font(COSType.body(12.5, weight: footer.working ? .medium : .regular))
                        .foregroundStyle(footer.failed ? COSPalette.danger : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(4)
                }
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 12) {
                // Alone (Done after an update, Close with nothing to install) it takes the primary's place on the right.
                if footer.primaryTitle == nil { Spacer(minLength: 12) }
                Button(footer.cancelTitle, action: onCancel)
                    .buttonStyle(WhatsNewButtonStyle(prominent: footer.primaryTitle == nil))
                    .disabled(!footer.cancelEnabled)
                    .keyboardShortcut(.cancelAction)
                if footer.primaryTitle != nil { Spacer(minLength: 12) }
                if let title = footer.primaryTitle {
                    // Never the default action: Return must not install. The click is the confirmation.
                    Button(title, action: onInstall)
                        .buttonStyle(WhatsNewButtonStyle(prominent: true))
                        .disabled(!footer.primaryEnabled)
                }
            }
            if footer.showsReassurance {
                Text(verbatim: footer.working ? "\(WhatsNewFooter.reassurance) \(WhatsNewFooter.closeNote)" : WhatsNewFooter.reassurance)
                    .font(COSType.body(11.5))
                    .foregroundStyle(COSPalette.subtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .background(COSPalette.panel)
    }
}

/// A card on the panel: a sentence-case Fraunces heading (never tracked caps: no eyebrow kickers) over its content.
private struct WhatsNewSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(COSType.display(18, weight: .semibold))
                .foregroundStyle(Color.primary)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
    }
}

/// One row: a small accent dot on the first line, then the words.
private struct WhatsNewBullet: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Circle()
                .fill(COSPalette.accent)
                .frame(width: 6, height: 6)
                .padding(.top, 7)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(COSType.body(13.5))
                .lineSpacing(2)
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

/// The footer's two buttons, a size up from the panel's chips for a 620 pt window. Primary: the accent gold with
/// onAccent words (white on #89662d light, ink on #c9a86e dark). Secondary: no fill, a border hairline, primary words
/// that turn accent on hover.
private struct WhatsNewButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, prominent: prominent)
    }

    private struct ButtonBody: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let hot = (hovered || configuration.isPressed) && isEnabled
            configuration.label
                .font(COSType.body(13.5, weight: .semibold))
                .foregroundStyle(prominent ? COSPalette.onAccent : (hot ? COSPalette.accent : Color.primary))
                .padding(.horizontal, 18)
                .frame(minHeight: 36)
                .background(prominent ? COSPalette.accent.opacity(configuration.isPressed ? 0.85 : 1) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(prominent ? Color.clear : (hot ? COSPalette.accent : COSPalette.border), lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovered = $0 }
        }
    }
}

struct ControlPanel: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject private var voiceGuide: SetupGuideState

    init(model: ControllerModel, openActivity: @escaping (ActivitySection?) -> Void,
         hostedInWindow: Bool = false, hostedInActivity: Bool = false, hub: SettingsHubHost? = nil) {
        self.model = model
        self.voiceGuide = model.setupGuide
        self.openActivity = openActivity
        self.hostedInWindow = hostedInWindow
        self.hostedInActivity = hostedInActivity
        self.hub = hub
    }
    /// 0.5.278: Settings, "Show live meeting transcript". Off: no Live now row, no live dots, no live-transcript helper.
    @AppStorage(LiveTranscript.enabledKey) private var showLiveTranscript = true
    /// Activity Today home (plan v2): the opt-in candidate switch, quiet hours and Work runs from Today.
    @AppStorage(TodayHome.enabledKey) private var todayHomeEnabled = false
    @AppStorage(TodayHome.quietHoursKey) private var todayQuietHours = true
    @AppStorage(TodayHome.workRunsKey) private var todayWorkRuns = true
    /// 0.5.312: Work chat's Plan and send as the primary button. Off by default (review stays normal).
    @AppStorage(WorkChatPolicy.autoSendKey) private var workChatSendWithoutReview = WorkChatPolicy.autoSendDefault
    /// 0.5.317: Settings › Work › When earlier work is still open. Queue it by default.
    @AppStorage(WorkChatHold.settingKey) private var workChatWhenHeld = WorkChatHold.settingDefault
    let openActivity: (ActivitySection?) -> Void
    /// Onboarding P1: the same panel hosted in the Settings window (SettingsWindowPresenter), which must not claim
    /// to be the menu-bar panel being open.
    var hostedInWindow = false
    /// Activity supplies its own size; settings and actions still use this shared panel.
    var hostedInActivity = false
    /// Settings hub (Miles, 2026-10-27): only Activity's Settings route passes a host, and then the hub draws in place of
    /// mainPanel. The menu-bar panel and the standalone Settings window pass none and keep the one-page panel. Both
    /// layouts are this one view, so every draft, confirmation, seed and observation below serves both.
    var hub: SettingsHubHost?
    /// General, Advanced: Use classic Settings. On, Activity draws mainPanel again (the rollback without a reinstall).
    @AppStorage(SettingsHub.classicKey) private var useClassicSettings = false
    @State private var hubCategory: SettingsHubCategory = SettingsHub.lastCategory()
    @State private var hubQuery = ""
    @FocusState private var hubSearchFocused: Bool
    /// The groups whose Advanced disclosure is open.
    @State private var hubAdvanced: Set<String> = []
    /// On this page: the group in view, from the scroll-spy.
    @State private var confirmHubRollback = false
    /// The scroll-spy, held but not observed (only the rail observes it), so scrolling never redraws this view.
    @State private var hubSpy = SettingsHubSpyModel()
    /// Work chat's per-Mac planner and effort defaults (OUT-05, OUT-06), the same keys as its footer.
    @AppStorage(WorkChatPolicy.plannerKey) private var workChatPlanner = "opus"
    @AppStorage(WorkChatPolicy.effortKey) private var workChatEffort = "high"
    /// True only while the hub draws (a host, and the classic switch off).
    private var hubOn: Bool { hub != nil && !useClassicSettings }
    @State private var confirmLegacyRestart = false
    @State private var confirmInstallManaged = false
    @State private var showGuidedSetupTier = false
    @State private var selectedTranscriptionTier = "balanced"
    @State private var selectedBackgroundJobs = true
    @State private var selectedMeetingPreview = false
    /// Morning brief card: a local editable copy of the server's settings. Synced
    /// from `model.morningBrief` whenever the server's `updatedAt` changes, so a
    /// half-edited card is never overwritten by a background refresh.
    @State private var briefDraft: MorningBriefSettings?
    @State private var jevExpanded = false
    @State private var jevKeyDraft = ""
    @State private var subQKeyDraft = ""
    @State private var briefDraftStamp = ""
    @State private var briefSourcesExpanded = false
    @State private var selectedClaudeSessions = false
    @State private var selectedVideoUploadV2 = false
    @State private var confirmClearStrandedVideoUploads = false
    /// 0.5.321: the glasses meeting the inline Stop and save confirmation is for.
    @State private var glassesStopTarget: String?
    @State private var confirmResetMessageCount = false
    @State private var confirmRecoverAllOrphans = false
    @State private var confirmSaveAllStranded = false
    @State private var selectedIdleMetalHq = false
    @State private var selectedAdaptiveAudioCleanup = false
    @State private var selectedThreadAttach = false
    @State private var selectedOllamaModel = ""
    @State private var openPetsQuery = ""
    @State private var petSettingsExpanded = false
    @State private var domainsDraft: [String] = []
    @State private var domainsBusy = false
    @State private var domainsError = ""
    @State private var petStateSpritesExpanded = false
    @State private var petCharactersExpanded = false
    @State private var confirmOpenPetsSprite = false
    @State private var confirmBundledCharacter = false
    @State private var pendingOpenPetsRow: OpenPetsCatalogRow?
    @State private var pendingBundledCharacter: BundledPetCharacter?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The menu-bar panel stays the server console. Browsing activity lives in a
    /// real, persistent AppKit window: unlike a sheet, that
    /// window does not need the transient MenuBarExtra to remain key.
    /// Split out of `body` deliberately. The full chain of state sync plus every
    /// alert and confirmation dialog exceeds what the SwiftUI type-checker will
    /// solve in one expression, and it fails as "unable to type-check in
    /// reasonable time" rather than as anything naming the real cause.
    ///
    /// Each toggle stays on its OWN observation on purpose. Syncing them all
    /// from one shared handler would let an unrelated status change overwrite a
    /// selection the user had flipped but not yet applied.
    /// Built while the confirmation is on screen, so the record is captured HERE
    /// rather than read inside the button action.
    ///
    /// Dismissing runs the `isPresented` setter, which calls `cancelReleaseFence()`
    /// and nils `fencePendingRelease`. `cosConfirm` dismisses BEFORE it runs the
    /// action, so an action that read `model.fencePendingRelease` would find nil
    /// and return silently -- no request, no error, the fence simply stays. That is
    /// what the old comment here claimed to prevent while doing the opposite.
    private var fenceConfirmActions: [COSConfirmAction] {
        let pending = model.fencePendingRelease
        return [
            .destructive("Release") {
                guard let pending else { return }
                Task { await model.releaseFence(pending, confirm: true) }
            },
            .cancel { model.cancelReleaseFence() },
        ]
    }

    private var syncedPanel: some View {
        panelContent
        .frame(width: hostedInActivity ? nil : 390, height: hostedInActivity ? nil : 640)
        .font(COSType.body(13))
        .background(COSPalette.panel)
        .background(WindowOpaquer())
        // 0.5.251: GOTCOS progress, disclosure and tint for every control in the panel. 0.5.252: a dropdown here
        // opens its list as a borderless child panel under the face, as in the Activity window. Tests/dropdown-canary
        // drove a real MenuBarExtra(.window) with posted clicks and keys (2026-09-30): the list opened, a row click,
        // Down then Return, a click on the face, Escape and a click outside all did what they should, and this panel
        // stayed open and key throughout. The same harness reproduced the 2026-08-23 finding for .confirmationDialog
        // (Release never ran, the panel closed), so it observes this panel's failure mode. If the child panel ever
        // dismisses this one, `.environment(\.cosDropdownInline, true)` here drops every list inline instead.
        .cosControlTheme()
        .onDisappear { if !hostedInWindow { model.panelVisible = false } }
        .onAppear { if !hostedInWindow { model.panelVisible = true } }
        // The appcast again when the last check is older than 15 minutes (AppUpdateCheckSchedule).
        .onAppear { model.panelOpenedForUpdates() }
        .task { if model.backgroundWorkEnabled { await voiceGuide.refreshVoice() } }
        .onAppear {
            // Fences are rare and urgent, and the card only renders when there is
            // one — so something has to look. Opening the panel is the right
            // cadence: it is one request, and it is the moment the user is here.
            Task { await model.loadFences() }
            if let tier = model.status.transcriptionRequestedTier,
               tier == "max" || tier == "balanced" {
                selectedTranscriptionTier = tier
            }
            if let enabled = model.status.backgroundJobsEnabled { selectedBackgroundJobs = enabled }
            if let enabled = model.status.meetingPreviewEnabled { selectedMeetingPreview = enabled }
            if let enabled = model.status.videoUploadV2Enabled { selectedVideoUploadV2 = enabled }
            if let enabled = model.status.idleMetalHqEnabled { selectedIdleMetalHq = enabled }
            if let enabled = model.status.adaptiveAudioCleanupEnabled { selectedAdaptiveAudioCleanup = enabled }
            if let enabled = model.status.threadAttachEnabled { selectedThreadAttach = enabled }
            selectedOllamaModel = model.status.ollamaConfiguredModel ?? ""
            model.loadOllamaTags()
            // 0.5.64: STATUS FIRST. This used to seed from `model.claudeSessionsEnabled`,
            // which is populated only by loadClaudeSessions() -- and every caller of that
            // lives in ActivityWindow, never here. Open the panel without visiting the
            // Activity window's Claude tab and this rendered false against a setting that
            // was true. Miles enabled it four times against a control that could not
            // show him anything else.
            //
            // `if let` matters: an older server omits the field, and absent must leave the
            // toggle alone rather than assert off.
            // ONE SOURCE. No `else` reaching for model.claudeSessionsEnabled: a second
            // source is how this broke, and it also defeated the guard below -- the
            // fallback mentioned model.status in a `== nil` check, which satisfied a
            // window search while assigning from somewhere else entirely.
            //
            // Against a server too old to report the field this shows false, which is
            // exactly today's behaviour and no worse. 0.5.64 pairs with 6.36.22.
            if let enabled = model.status.claudeSessionsEnabled { selectedClaudeSessions = enabled }
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
        .onChange(of: model.status.claudeSessionsEnabled) { _, enabled in
            if let enabled { selectedClaudeSessions = enabled }
        }
        .onChange(of: model.status.videoUploadV2Enabled) { _, enabled in
            if let enabled { selectedVideoUploadV2 = enabled }
        }
        .onChange(of: model.status.idleMetalHqEnabled) { _, enabled in
            if let enabled { selectedIdleMetalHq = enabled }
        }
        .onChange(of: model.status.adaptiveAudioCleanupEnabled) { _, enabled in
            if let enabled { selectedAdaptiveAudioCleanup = enabled }
        }
        .onChange(of: model.status.threadAttachEnabled) { _, enabled in
            if let enabled { selectedThreadAttach = enabled }
        }
        .onChange(of: model.status.ollamaConfiguredModel) { _, pinned in
            selectedOllamaModel = pinned ?? ""
        }
    }

    /// The hub when Activity hosts it with the classic switch off; the one-page panel everywhere else.
    @ViewBuilder private var panelContent: some View {
        if let hub, !useClassicSettings { settingsHub(hub) } else { mainPanel }
    }

    /// Split in three ON PURPOSE. Ten confirmations plus the error alert in one
    /// chained expression exceeds what the SwiftUI type-checker will solve.
    /// Adding an eleventh on panelWithPrimaryConfirms or panelWithSecondaryConfirms
    /// reproduces "unable to type-check this expression in reasonable time".
    private var panelWithPrimaryConfirms: some View {
        syncedPanel
        .alert("COS Control", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        // Converted with the nine dialogs. NOT proven broken -- the canary's `.alert`
        // variant was never run -- but it is the same presentation class in the same
        // MenuBarExtra(.window) panel, and leaving one untested modal behind a fix
        // that claims the panel works would be the same bet that lost here already.
        .cosConfirm(
            "Meetings folder",
            isPresented: Binding(
                get: { model.meetingLibraryGuidance != nil },
                set: { if !$0 { model.meetingLibraryGuidance = nil } }
            ),
            message: model.meetingLibraryGuidance ?? "",
            actions: [
                .normal("Choose again") {
                    model.meetingLibraryGuidance = nil
                    model.selectOperationsFolder()
                },
                .normal("View examples") {
                    model.meetingLibraryGuidance = nil
                    model.openSetupGuide()
                },
                .cancel("Skip for now") { model.meetingLibraryGuidance = nil },
            ]
        )
        // INLINE, never .confirmationDialog. A destructive button's action does
        // not run inside MenuBarExtra(.window) -- see Sources/COSConfirm.swift.
        .cosConfirm(
            "Release this thread?",
            isPresented: Binding(
                get: { model.fencePendingRelease != nil },
                set: { if !$0 { model.cancelReleaseFence() } }
            ),
            message: model.fencePendingRelease?.explanation ?? "",
            actions: fenceConfirmActions
        )
        .cosConfirm(
            "Restart this self-managed server?",
            isPresented: $confirmLegacyRestart,
            message: "This older server cannot show whether meetings and jobs are idle. Restart only when no work is running. Restarting also applies a folder you chose.",
            actions: [
                .destructive("Restart now") { model.perform("restart") },
                .cancel(),
            ]
        )
        .cosConfirm(
            "Replace the older server?",
            isPresented: $confirmInstallManaged,
            message: "Stops your older server, then installs the latest COS server. Finish glasses work first. To keep it, use Manage in place.",
            actions: [
                .destructive("Stop and replace") { model.installLatestManagedFromLegacy() },
                .cancel(),
            ]
        )
    }

    private var panelWithSecondaryConfirms: some View {
        panelWithPrimaryConfirms
        .cosConfirm(
            "Choose transcription setup",
            isPresented: $showGuidedSetupTier,
            message: "Balanced uses fast Small.en previews, Turbo commits, and Large-v3 polish. Max uses Large-v3 for live preview and commit too; choose it only on a powerful Mac.",
            actions: [
                .normal("Balanced (recommended)") {
                    selectedTranscriptionTier = "balanced"
                    model.runGuidedSetup(tier: "balanced")
                },
                .normal("Max") {
                    selectedTranscriptionTier = "max"
                    model.runGuidedSetup(tier: "max")
                },
                .cancel(),
            ]
        )
        .cosConfirm(
            "Clear stuck video uploads?",
            isPresented: $confirmClearStrandedVideoUploads,
            message: "Cancels uploads that received nothing for 60 seconds. Uploads still sending or compressing stay. Stuck uploads block Repair.",
            actions: [
                .destructive("Clear stuck uploads") { model.clearStrandedVideoUploads() },
                .cancel(),
            ]
        )
        .cosConfirm(
            "Reset live message count?",
            isPresented: $confirmResetMessageCount,
            message: "The next message is #1. Older cards keep their numbers and history stays in Archive. On a glasses app older than 6.8.423, this clears the phone's chat list.",
            actions: [
                .destructive("Reset count") { model.resetMessageEra() },
                .cancel(),
            ]
        )
        .cosConfirm(
            "Recover all unsaved recordings?",
            isPresented: $confirmRecoverAllOrphans,
            message: "Turns each unsaved recording into a meeting, one at a time. The files are kept.",
            actions: [
                .normal("Recover all") { model.recoverAllOrphans() },
                .cancel(),
            ]
        )
        .cosConfirm(
            "Save live recordings as meetings?",
            isPresented: $confirmSaveAllStranded,
            message: "Ends each live glasses recording and saves it, like Stop on the phone. The files are kept.",
            actions: [
                .normal("Save all") { model.saveAllStranded() },
                .cancel(),
            ]
        )
        .cosConfirm(
            G2MeetingStop.confirmTitle,
            isPresented: Binding(get: { glassesStopTarget != nil }, set: { if !$0 { glassesStopTarget = nil } }),
            message: G2MeetingStop.confirmMessage,
            actions: [
                .destructive(G2MeetingStop.confirmAction) {
                    if let id = glassesStopTarget { model.stopGlassesMeeting(id) }
                    glassesStopTarget = nil
                },
                .cancel { glassesStopTarget = nil },
            ]
        )
    }

    var body: some View {
        panelWithSecondaryConfirms
        .cosConfirm(
            pendingOpenPetsRow.map { "Use \($0.displayName) as the session pet figure?" }
                ?? "Use this figure as the session pet figure?",
            isPresented: $confirmOpenPetsSprite,
            message: "Replaces the current session pet sprite with this gallery thumbnail. Use Cloud Puff restores the default; Characters offers animated pets.",
            actions: [
                .normal("Use") {
                    if let row = pendingOpenPetsRow {
                        Task { await model.installOpenPetsThumb(id: row.id, preview: row.preview) }
                    }
                    pendingOpenPetsRow = nil
                },
                .cancel() { pendingOpenPetsRow = nil },
            ]
        )
        .cosConfirm(
            pendingBundledCharacter.map { "Use \($0.displayName)?" }
                ?? "Use this shipped character?",
            isPresented: $confirmBundledCharacter,
            message: "Replaces the sprites currently installed — every pose, the "
                + "stitched strip and the state map — with this character pack. "
                + "A pack you installed yourself would have to be installed again.",
            actions: [
                // 0.5.325 (Miles's V14 reverted to the shipped pack twice on 2026-10-18, the map copied out of the
                // bundle): this is the only path that copies a shipped map over the person's pack, so only a click
                // runs it, never Return, and a confirm still pending when the panel goes away is withdrawn.
                .clickOnly("Use") {
                    if let character = pendingBundledCharacter {
                        model.useBundledCharacter(character)
                    }
                    pendingBundledCharacter = nil
                },
                .cancel() { pendingBundledCharacter = nil },
            ]
        )
        .onDisappear {
            confirmBundledCharacter = false
            pendingBundledCharacter = nil
        }
    }

    private var visibleBundledCharacters: [BundledPetCharacter] {
        let q = openPetsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return PetSpriteStore.bundledCharacters }
        return PetSpriteStore.bundledCharacters.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
                || $0.id.localizedCaseInsensitiveContains(q)
                || $0.summary.localizedCaseInsensitiveContains(q)
                || $0.searchTerms.localizedCaseInsensitiveContains(q)
        }
    }

    private var visibleOpenPetsRows: [OpenPetsCatalogRow] {
        let q = openPetsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return model.openPetsRows }
        return model.openPetsRows.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
                || $0.id.localizedCaseInsensitiveContains(q)
                || $0.category.localizedCaseInsensitiveContains(q)
        }
    }

    private var availableCharacterCount: Int {
        PetSpriteStore.bundledCharacters.count + model.openPetsRows.count
    }

    private var advancedCharacterCount: Int {
        PetSpriteStore.bundledCharacters.filter(\.isAdvanced).count
    }

    /// COS packs and community stills deliberately share one visual catalog.
    /// Capability, not provenance, is the distinction a person needs while
    /// choosing: Advanced packs carry states; a community figure is one still.
    private func bundledCharacterTile(_ character: BundledPetCharacter) -> some View {
        Button {
            pendingBundledCharacter = character
            confirmBundledCharacter = true
        } label: {
            VStack(spacing: 4) {
                if let thumb = model.bundledCharacterThumb(for: character) {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 44, height: 44)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(COSPalette.line.opacity(0.35))
                        .frame(width: 44, height: 44)
                }
                Text(character.displayName)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if character.isAdvanced {
                    Text("ADVANCED")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(COSPalette.gold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(COSPalette.gold.opacity(0.16)))
                        .accessibilityLabel("Advanced character")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .top)
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(COSPalette.gold.opacity(0.07))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(COSPalette.gold.opacity(0.28), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(character.summary)
    }

    private func openPetsCharacterTile(_ row: OpenPetsCatalogRow) -> some View {
        Button {
            pendingOpenPetsRow = row
            confirmOpenPetsSprite = true
        } label: {
            VStack(spacing: 4) {
                if let image = model.openPetsThumbs[row.preview] {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 44, height: 44)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(COSPalette.line.opacity(0.35))
                        .frame(width: 44, height: 44)
                        .onAppear {
                            model.prefetchOpenPetsThumb(id: row.id, preview: row.preview)
                        }
                }
                Text(row.displayName)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .top)
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(COSPalette.line.opacity(0.10))
            )
        }
        .buttonStyle(.plain)
    }

    private var petGalleryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("\(advancedCharacterCount) advanced", systemImage: "sparkles")
                    .foregroundStyle(COSPalette.gold)
                Spacer(minLength: 0)
                Text("\(model.openPetsRows.count) community")
            }
            .font(.caption2.weight(.medium))
            Text("Advanced characters include state-aware packs; some add multi-frame animations. Community characters use one still across states.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Search characters", text: $openPetsQuery)
                .textFieldStyle(.plain)
                .cosField()
            if model.openPetsLoading && model.openPetsRows.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading community characters")
                }
                .foregroundStyle(.secondary)
            } else if model.openPetsUnavailable {
                HStack {
                    Text("Community characters unavailable right now.")
                        .foregroundStyle(.secondary)
                    Button("Try again") {
                        Task { await model.loadOpenPetsCatalog() }
                    }
                    .buttonStyle(COSTextButtonStyle())
                }
            } else if model.openPetsStale {
                Text("Showing the saved OpenPets list.")
                    .foregroundStyle(.secondary)
            }
            if visibleOpenPetsRows.isEmpty && visibleBundledCharacters.isEmpty && !model.openPetsLoading {
                Text("No characters match.")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                        ForEach(visibleBundledCharacters) { character in
                            bundledCharacterTile(character)
                        }
                        ForEach(visibleOpenPetsRows) { row in
                            openPetsCharacterTile(row)
                        }
                    }
                }
                .frame(height: CharacterGallery.height)
            }
            Text("Community art from openpets.dev. No license metadata is published. Personal use.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            // The hub's root reads the catalog once for every page (hubLoaders), so its Characters card does not.
            if !hubOn { Task { await model.loadOpenPetsCatalog() } }
        }
        // The user grants this in System Settings, so the app is not frontmost
        // when it changes. Re-read on return or the row would keep nagging
        // someone who has already granted it.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPetJumpTrust()
        }
    }

    /// Jev (TypeSafe) powers Work's session suggestions and meeting intake. The key is validated by the server
    /// and stored there (0600); Control never keeps or shows it. Without a key, Work falls back to word matching.
    /// Work intake expiry (server Work loop). Shown only once the server answers its settings read: an older server or
    /// a failed read shows nothing here, and a shared Work error is never rendered in Settings.
    private var workExpirySettings: some View {
        Group {
            if model.workExpiryAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Work intake").font(COSType.body(13, weight: .semibold))
                    Toggle("Expire old asks", isOn: Binding(get: { model.workExpiryEnabled }, set: { enabled in Task { await model.setWorkExpiry(enabled) } }))
                        .toggleStyle(COSSwitchStyle())
                    Text("Expires other people's old asks; yours stay. Restore them from Sort for 30 days.").font(COSType.body(11)).foregroundStyle(.secondary)
                }
            }
        }.task { await model.loadWorkExpiry() }
    }

    private var jevSettings: some View {
        DisclosureGroup(isExpanded: $jevExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                decisionProviderControls
                Divider()
                jevKeyControls
            }.padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Label("Decision models", systemImage: "sparkle")
                Spacer(minLength: 0)
                Text(model.decisionSettings?.provider.title ?? "")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { subQKeyDraft = ""; jevKeyDraft = "" }
        .onChange(of: jevExpanded) { _, open in
            if open { Task { await model.loadDecisionSettings(); await model.loadJevStatus(); await model.loadSubQKeyStatus() } }
            else { subQKeyDraft = ""; jevKeyDraft = "" }
        }
    }

    /// The Jev key: its status, any pause after errors, Save and Remove (JV-10 to JV-12).
    @ViewBuilder private var jevKeyControls: some View {
        Text("Jev key").font(.caption.weight(.semibold))
        Text("Key status is separate from the provider choices above.").font(.caption2).foregroundStyle(.secondary)
        // Without an answer from the server, say so instead of "Checking…" forever (the error is below).
        Text(model.jevStatus?.summary ?? (model.jevMessage == nil ? "Checking…" : "Status unavailable."))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let problem = model.jevStatus?.problem {
            Text(problem).font(.caption2).foregroundStyle(COSPalette.danger).fixedSize(horizontal: false, vertical: true)
        }
        if let until = model.jevStatus?.breakerOpenUntil {
            Text("Paused after repeated errors until \(until.prefix(16).replacingOccurrences(of: "T", with: " ")) UTC.")
                .font(.caption2).foregroundStyle(COSPalette.danger)
        }
        if model.jevStatus?.available != false {
            HStack {
                SecureField(model.jevStatus?.configured == true ? "Replace Jev key" : "TypeSafe API key", text: $jevKeyDraft)
                    .textFieldStyle(.plain).cosField().disabled(model.jevBusy)
                Button(model.jevBusy ? "Checking…" : "Save key") {
                    let key = jevKeyDraft
                    Task { if await model.saveJevKey(key) { jevKeyDraft = "" } }
                }.disabled(model.jevBusy || jevKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).count < 16)
            }
            if model.jevStatus?.source == "config" {
                Button("Remove Jev key", role: .destructive) { Task { await model.removeJevKey() } }
                    .buttonStyle(COSTextButtonStyle(tone: .destructive)).disabled(model.jevBusy)
            }
        }
        if let message = model.jevMessage { Text(message).font(.caption2).foregroundStyle(.secondary) }
        Text("Get a key at typesafe.ai. Meeting intake always uses Jev, whatever you pick above.")
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// The provider controls, then the SubQ key, in the panel's order. The hub places the Default and both keys in the
    /// card and the per-workflow choices, Refresh and SubQ's retention note under Advanced.
    @ViewBuilder private var decisionProviderControls: some View {
        decisionDefaultControls
        decisionWorkflowControls
        decisionMessageLine
        decisionRefreshButton
        subQRetentionNote
        subQKeyControls
    }

    /// JV-02, or why it is not offered.
    @ViewBuilder private var decisionDefaultControls: some View {
        if let settings = model.decisionSettings {
            Text("Session suggestions, completion checks and Work search. Errors never switch the provider.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            decisionProviderPicker("Default provider", workflow: nil, selection: settings.savedProvider?.rawValue ?? "inherit")
        } else if model.decisionSettingsAvailable == false {
            Text("Picking a provider needs a newer COS server. Your Jev key still works.").font(.caption2).foregroundStyle(.secondary)
        } else {
            Text(model.decisionMessage == nil ? "Checking decision settings…" : "Decision settings unavailable.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// JV-03 to JV-05: one picker per workflow, its effective line and a missing key.
    @ViewBuilder private var decisionWorkflowControls: some View {
        if let settings = model.decisionSettings {
            ForEach(DecisionProviderSettings.workflows, id: \.self) { workflow in
                VStack(alignment: .leading, spacing: 2) {
                    decisionProviderPicker(workflow == "session" ? "Session suggestions" : workflow == "completion" ? "Completion checks" : "Work search",
                                           workflow: workflow, selection: settings.overrides[workflow]?.rawValue ?? "inherit")
                    Text(settings.effectiveText(workflow)).font(.caption2).foregroundStyle(.secondary)
                    if let provider = settings.effective[workflow], settings.configured[provider.rawValue] != true {
                        Text("\(provider.title) needs a key. This stays off until you add one.")
                            .font(.caption2).foregroundStyle(COSPalette.danger)
                    }
                }
            }
        }
    }

    @ViewBuilder private var decisionMessageLine: some View {
        if let message = model.decisionMessage { Text(message).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }

    /// JV-06.
    private var decisionRefreshButton: some View {
        Button("Refresh providers") { Task { await model.loadDecisionSettings(); await model.loadSubQKeyStatus() } }.disabled(model.decisionBusy)
    }

    /// JV-07: SubQ is a public preview; what it keeps.
    @ViewBuilder private var subQRetentionNote: some View {
        Text("SubQ is a public preview. Steps on SubQ send it their context, kept forever by default.")
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Link("SubQ data retention", destination: URL(string: "https://docs.subq.ai/using-the-api/data-retention/")!).font(.caption2)
    }

    /// The SubQ key: status, Save and Remove (JV-08, JV-09).
    @ViewBuilder private var subQKeyControls: some View {
        Text("SubQ key").font(.caption.weight(.semibold))
        Text(model.subQKeyStatus?.summary ?? "SubQ key status unavailable.").font(.caption2).foregroundStyle(.secondary)
        if model.decisionSettingsAvailable == true {
            HStack {
                SecureField(model.subQKeyStatus?.configured == true ? "Replace SubQ key" : "SubQ API key", text: $subQKeyDraft)
                    .textFieldStyle(.plain).cosField().disabled(model.subQKeyBusy)
                Button(model.subQKeyBusy ? "Checking…" : "Save key") {
                    let key = subQKeyDraft
                    Task { if await model.saveSubQKey(key) { subQKeyDraft = "" } }
                }.disabled(model.subQKeyBusy || subQKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("COS checks the key with SubQ, then saves it on the server. Saving does not turn SubQ on.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.subQKeyStatus?.source == "config" {
                Button("Remove SubQ key", role: .destructive) { Task { await model.removeSubQKey() } }
                    .buttonStyle(COSTextButtonStyle(tone: .destructive)).disabled(model.subQKeyBusy)
            }
        }
        if let message = model.subQKeyMessage { Text(message).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    }

    private func decisionProviderPicker(_ title: String, workflow: String?, selection: String) -> some View {
        COSDropdown(title, selection: Binding(get: { selection }, set: { value in
            Task { await model.setDecisionProvider(workflow: workflow, selection: value) }
        }), options: [COSDropdownOption("inherit", workflow == nil ? "Server default" : "Use default")]
            + DecisionProvider.allCases.map { COSDropdownOption($0.rawValue, $0.title) })
            .disabled(model.decisionBusy || model.subQKeyBusy)
    }

    private var sessionPetSettings: some View {
        DisclosureGroup(isExpanded: $petSettingsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                petSwitch
                if model.petEnabled {
                    petJumpWarning
                    PetSizeControls(model: model)
                    Divider()
                    DisclosureGroup(isExpanded: $petStateSpritesExpanded) {
                        PetSpriteStateControls(model: model)
                            .padding(.top, 6)
                    } label: {
                        HStack(spacing: 8) {
                            Label("State sprites", systemImage: "film.stack")
                            Spacer(minLength: 0)
                            Text("\(PetSpritePose.allCases.count) states")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    DisclosureGroup(isExpanded: $petCharactersExpanded) {
                        petGalleryCard
                            .padding(.top, 6)
                    } label: {
                        HStack(spacing: 8) {
                            Label("Characters", systemImage: "person.3")
                            Spacer(minLength: 0)
                            Text("\(availableCharacterCount)")
                                .foregroundStyle(.secondary)
                            Text("\(advancedCharacterCount) ADVANCED")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.35)
                                .foregroundStyle(COSPalette.gold)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(COSPalette.gold.opacity(0.16)))
                        }
                    }
                    .font(.caption)
                    Divider()
                    petCloudPuffButton
                    petSpriteButtons
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "pawprint.fill")
                    .foregroundStyle(COSPalette.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Session pet")
                        .font(.body.weight(.medium))
                    Text(model.petEnabled
                         ? "On · \(model.petSize.preset.title) · \(model.petCharacterPercent)% size · \(model.petAnimationSpeedPercent)% speed"
                            + (model.petMotion == .full ? "" : " · \(model.petMotion.title)")
                         : "Off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .onAppear {
            Task { await model.loadOpenPetsCatalog() }
        }
    }

    /// PT-01.
    private var petSwitch: some View {
        Toggle("Session pet", isOn: Binding(
            get: { model.petEnabled },
            set: { model.setPetEnabled($0) }
        ))
        .toggleStyle(COSSwitchStyle())
    }

    /// PT-02: jump to a session needs Accessibility, with Grant and Reset and add again.
    @ViewBuilder private var petJumpWarning: some View {
        // State the permission BEFORE a jump fails. Without this the
        // only way to learn the grant is missing was to click the pet
        // and read an error, which is what happened on Queen's Mac.
        if !model.petJumpTrusted {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(COSPalette.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jump to session needs Accessibility")
                        .font(.caption.weight(.semibold))
                    Text("Everything else about the pet works without it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    // 0.5.267: a grant that reads ON in System Settings but no longer matches this build.
                    Text("Already on? Reset and add again removes the old entry and asks macOS again.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Reset and add again") { model.resetAccessibilityAndAddAgain() }
                        .buttonStyle(COSTextButtonStyle())
                }
                Spacer(minLength: 0)
                Button("Allow") { model.requestPetJumpAccessibility() }
                    .buttonStyle(COSTextButtonStyle())
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(COSPalette.card))
        }
    }

    /// PT-10.
    private var petCloudPuffButton: some View {
        Button("Use Cloud Puff") { model.restoreDefaultCharacter() }
            .help("Restore the bundled default pet. Artwork from OpenPets.")
    }

    /// PT-11 to PT-13: a sprite pack, one sprite, back to the COS figure.
    private var petSpriteButtons: some View {
        HStack {
            Button("Install sprite pack") {
                model.choosePetSpritePack()
            }
            .help("V2 Windu boards or a folder of per-state strips.")
            Button(model.petCustomSprite == nil ? "Choose sprite" : "Replace sprite") {
                model.choosePetSprite()
            }
            .help("One PNG for every state that has no strip. A small square pixel figure stays sharp.")
            if model.petSpriteKit.hasAnyCustom {
                Button("Use COS figure") { model.resetPetSprite() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            COSLockupView(height: 17)
                // Adaptive. This is the menu-bar panel header, not the brand tile, so the
                // fixed dark rendered black on the dark panel.
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 2) {
                // 2026-10-09 (Miles, 22:55, "Lets go with B"): the version, small, inline after the title on its
                // baseline, so it is known without scrolling to the footer. The title line keeps its height.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // The title never truncates; a narrow header gives way in the stamp first.
                    Text("Control").font(COSType.display(18, weight: .semibold)).fixedSize()
                    versionStamp.layoutPriority(-1)
                }
                updateStatusLine(idle: "Your COS server on this Mac").lineLimit(1)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            Button { confirmResetMessageCount = true } label: { Image(systemName: "archivebox") }
                .buttonStyle(COSIconButtonStyle(size: 24))
                .disabled(model.busy)
                .help("Reset message count")
            refreshAndCheckButton
        }
    }

    /// The running build, read live from ControllerModel.currentVersion (Info.plist), never a literal.
    private var versionStamp: some View {
        Text("v\(ControllerModel.currentVersion)")
            .font(COSType.mono(9))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .help("COS Control \(ControllerModel.currentVersion)")
            .accessibilityLabel("COS Control version \(ControllerModel.currentVersion)")
    }

    /// 2026-10-09 (Miles): the manual update check lives in the header's refresh button now (the version card is
    /// gone). One click refreshes the server status and checks for updates; the subtitle line says how the check went.
    private var refreshAndCheckButton: some View {
        Button {
            Task { await model.refreshAndCheckForUpdates() }
        } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(COSIconButtonStyle(size: 24))
            .help("Refresh status and check for updates")
            .accessibilityLabel("Refresh status and check for updates")
    }

    /// The subtitle line: its own words, or the header check's (Checking for updates…, Up to date, Couldn't check for
    /// updates) while one runs or for a few seconds after. No new row, and no motion under Reduce Motion.
    private func updateStatusLine(idle: String, size: CGFloat = 11) -> some View {
        let shown = HeaderUpdateStatus.shown(inFlight: model.updateCheckInFlight, status: model.headerUpdateStatus)
        return Text(shown.text(idle: idle))
            .font(COSType.body(size))
            .foregroundStyle(shown == .upToDate ? AnyShapeStyle(COSPalette.green)
                             : shown == .failed ? AnyShapeStyle(COSPalette.danger) : AnyShapeStyle(.secondary))
            // The failure in its own words, on hover, while the line says Couldn't check (QA 2026-10-09, W5).
            .help(shown == .failed ? (model.headerUpdateFailureDetail ?? "") : "")
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: shown)
    }

    /// The server status card: the pieces below in the panel's order. The hub places each in its category.
    private var statusCard: some View {
        VStack(spacing: 9) {
            statusServerRows
            statusVoiceRows
            statusContextRows
            statusBackgroundRow
            statusMeetingPreviewRow
            statusContinueRow
            statusVideoRows(clearButton: true)
            statusIdleMetalRow
            statusAudioCleanupRow
            statusWhisperErrorLine
            statusTranscriptionModelRows
            statusMeetingAudioRows
            statusMeetingAlertsRow
            statusMeetingSyncRows
            statusEarlySyncRows
            statusHqPrefillRows
            statusFinalizationRows
            statusRetainedCaptureRows
            statusAgentRows
            statusCursorRow
            statusOllamaRow
            statusVersionRow
            Divider()
            statusWorkFolderRows
            statusLibraryRows
            statusActiveWorkLine
            statusTransactionLine
        }
        .padding(13)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
    }

    /// Server, ownership and recovery (ST-01 to ST-03).
    @ViewBuilder private var statusServerRows: some View {
        statusRow("Server", value: runtimeLabel, good: model.status.runtimeState == "managedHealthy")
        statusRow("Ownership", value: ownershipLabel, good: model.status.ownershipVerified)
        statusRow("Recovery", value: model.status.recoveryLoaded ? "Scheduled" : "Needs repair", good: model.status.recoveryInstalled && model.status.recoveryLoaded)
    }

    /// Local transcription: Parakeet's readiness and selected engines, or Whisper (ST-04, ST-05).
    @ViewBuilder private var statusVoiceRows: some View {
        if let voice = voiceGuide.voice, voice.usesParakeet {
            statusRow("Local transcription", value: voice.parakeetReady ? "Ready · Parakeet Ultra" : "Parakeet needs attention", good: voice.parakeetReady)
            statusRow("Selected live preview", value: selectedEngineLabel(voice.selectedPreview, effective: voice.effectivePreview), good: voice.selectedPreview == voice.effectivePreview)
            statusRow("Selected saved meetings", value: selectedEngineLabel(voice.selectedHQ, effective: voice.effectiveHQ), good: voice.selectedHQ == voice.effectiveHQ)
            if !voice.parakeetReady {
                Text("Your selected engines are kept. Check Transcription settings before recording.")
                    .font(.caption2).foregroundStyle(COSPalette.amber)
            }
        } else {
            statusRow("Local Whisper", value: whisperLabel, good: model.status.whisperReady)
        }
    }

    /// Memory and threads, with what to do when either is missing (ST-06).
    @ViewBuilder private var statusContextRows: some View {
        if model.status.contextBrowserSupported {
            let memoryReady = model.status.memoryAvailable == true
            let threadsReady = model.status.threadsAvailable == true
            statusRow("Memory and threads", value: contextBrowserLabel, good: memoryReady && threadsReady)
            if !memoryReady || !threadsReady {
                // The ONLY in-app guidance for this feature, so it has to say
                // what to actually do. It used to read "Choose COS Data below.
                // Empty stores are healthy" — true, and useless to someone
                // who has no COS workspace, which was everyone but the author.
                Text(contextBrowserHint)
                    .font(.caption2).foregroundStyle(COSPalette.amber)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
            contextDetail
        }
    }

    /// Background jobs (ST-07).
    @ViewBuilder private var statusBackgroundRow: some View {
        if model.status.backgroundJobsSupported, let enabled = model.status.backgroundJobsEnabled {
            statusRow("Background jobs", value: enabled ? "Allowed" : "Off", good: enabled)
        }
    }

    /// Meeting preview (ST-08).
    @ViewBuilder private var statusMeetingPreviewRow: some View {
        if model.status.meetingPreviewSupported, let enabled = model.status.meetingPreviewEnabled {
            statusRow("Fast preview", value: enabled ? "\(voiceGuide.voice?.activePreviewTitle ?? "Status unavailable") · On" : "Off", good: enabled)
        }
    }

    /// Continue threads (ST-09).
    @ViewBuilder private var statusContinueRow: some View {
        if model.status.threadAttachSupported, let enabled = model.status.threadAttachEnabled {
            let providers = model.status.threadAttachProviders
            let detail = enabled
                ? (providers.isEmpty ? "On" : providers.joined(separator: " · "))
                : "Off"
            statusRow("Continue sessions", value: detail, good: enabled)
        }
    }

    /// Video uploads (ST-10). The hub draws Clear stranded once, on the Reliable video uploads row (D-14).
    @ViewBuilder private func statusVideoRows(clearButton: Bool) -> some View {
        if model.status.videoUploadV2Supported, let enabled = model.status.videoUploadV2Enabled {
            let receiving = model.status.videoUploadV2Receiving
            let finalizing = model.status.videoUploadV2Finalizing
            let active = receiving + finalizing
            let detail = active > 0 ? "\(active) active" : (enabled ? "Resumable · On" : "Off")
            statusRow("Video uploads", value: detail, good: enabled && active == 0)
            if receiving > 0, clearButton {
                HStack {
                    Text("A stopped upload can wait here for 4 hours and block Repair.")
                        .font(.caption2).foregroundStyle(COSPalette.amber)
                    Spacer()
                    Button("Clear stuck uploads") { confirmClearStrandedVideoUploads = true }
                        .disabled(model.busy)
                }
            }
            if model.status.videoUploadV2Unacknowledged > 0 {
                Text("\(model.status.videoUploadV2Unacknowledged) finished upload(s) waiting for the phone to confirm.")
                    .font(.caption2).foregroundStyle(COSPalette.amber)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Idle Metal HQ (ST-11).
    @ViewBuilder private var statusIdleMetalRow: some View {
        if model.status.idleMetalHqSupported, let enabled = model.status.idleMetalHqEnabled {
            let label = enabled ? "On · pauses for live work" : (model.status.idleMetalHqForceCpu == true ? "Force CPU" : "Off · CPU")
            statusRow("GPU when idle", value: label, good: enabled)
        }
    }

    /// Audio cleanup (ST-12).
    @ViewBuilder private var statusAudioCleanupRow: some View {
        if model.status.adaptiveAudioCleanupSupported, let enabled = model.status.adaptiveAudioCleanupEnabled {
            // Raw replay is the safe default/rollback, not a degraded state.
            statusRow("Playback cleanup", value: enabled ? "Cleaned" : "Original", good: true)
        }
    }

    /// Whisper's own error while it is not ready (ST-05).
    @ViewBuilder private var statusWhisperErrorLine: some View {
        if voiceGuide.voice?.usesParakeet != true, !model.status.whisperReady, let error = model.status.whisperError, !error.isEmpty {
            Text(error)
                .font(.caption2)
                .foregroundStyle(COSPalette.amber)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .textSelection(.enabled)
        }
    }

    /// The tier and the models for preview, live commit and save (ST-13).
    @ViewBuilder private var statusTranscriptionModelRows: some View {
        if voiceGuide.voice?.usesParakeet != true, model.status.livePreviewModel != nil || model.status.liveCommitModel != nil || model.status.hqPolishModel != nil {
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
                Text("Add names and terms in the setup wizard for better accuracy.")
                    .font(.caption2)
                    .foregroundStyle(COSPalette.amber)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Each live meeting's audio (ST-14).
    @ViewBuilder private var statusMeetingAudioRows: some View {
        ForEach(model.meetingAudio) { watch in
            statusRow(watch.rowLabel(amongLive: model.meetingAudio.count), value: watch.rowValue, good: watch.state == "reaching")
            if watch.alert {
                Text(watch.panelCaption)
                    .font(.caption2)
                    .foregroundStyle(COSPalette.amber)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Meeting alerts off for COS Control (ST-15).
    @ViewBuilder private var statusMeetingAlertsRow: some View {
        if model.meetingAlertsOff && !model.meetingAudio.isEmpty {
            statusRow("Meeting alerts", value: "Off for COS Control", good: false)
            HStack {
                Spacer()
                Button("Notification settings") { model.openNotificationSettings() }
                    .controlSize(.small)
            }
        }
    }

    /// Meeting sync, its meetings and Run sync now (ST-16, ST-17).
    @ViewBuilder private var statusMeetingSyncRows: some View {
        statusRow("Meeting sync", value: model.status.displayedMeetingSync.label, good: !model.status.meetingWorkBlockingRestart)
        // 0.5.237: which meetings, and where each one is, as the server reports it.
        ForEach(model.status.meetingSyncMeetings.prefix(4)) { row in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(row.stage)
                    .monospacedDigit()
                    .foregroundStyle(row.isWaiting ? Color.secondary : Color.primary)
                    .lineLimit(1)
            }
            .font(.caption)
        }
        if model.status.meetingSyncMeetings.count > 4 {
            Text("+\(model.status.meetingSyncMeetings.count - 4) more")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        HStack {
            Spacer()
            Button("Sync now") { model.perform("meeting-sync-now") }
                .controlSize(.small)
                .disabled(model.busy || model.status.meetingWorkBlockingRestart)
        }
        if model.status.meetingWorkBlockingRestart {
            Text(meetingWorkBlockCaption)
                .font(.caption2)
                .foregroundStyle(COSPalette.amber)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Early meeting sync (ST-18).
    @ViewBuilder private var statusEarlySyncRows: some View {
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
                "Early sync",
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
    }

    /// HQ prefill (ST-19).
    @ViewBuilder private var statusHqPrefillRows: some View {
        if let progressive = model.status.progressiveHqEnabled, let prefillValue = model.status.progressiveHqValue {
            let tier = model.status.progressiveHqTier == "max" ? "Max" : "Balanced"
            let threadLabel = model.status.progressiveHqThreads.map { " · \($0)t" } ?? ""
            let unavailable = model.status.progressiveHqRequested == true && !progressive
            statusRow(
                "HQ prefill",
                value: prefillValue,
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
    }

    /// Finalization recovery or library save (ST-20).
    @ViewBuilder private var statusFinalizationRows: some View {
        if model.status.meetingFinalizationPending > 0 || model.status.meetingFinalizationMalformed > 0 {
            let recovering = model.status.meetingFinalizationFailed > 0
                || model.status.meetingFinalizationMalformed > 0
            statusRow(
                recovering ? "Save retries" : "Saving meetings",
                value: model.status.meetingFinalizationMalformed > 0
                    ? "Repair required"
                    : model.status.meetingFinalizationFailed > 0
                    ? "\(model.status.meetingFinalizationFailed) retrying"
                    : "\(model.status.meetingFinalizationPending) pending",
                good: !recovering
            )
            if let error = model.status.meetingFinalizationLastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(COSPalette.amber)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Retained captures, Recover and Save (ST-21 to ST-23).
    @ViewBuilder private var statusRetainedCaptureRows: some View {
        // Server 6.19.0+: meeting audio whose save never landed is
        // quarantined instead of deleted. Surface it — a hidden lost
        // meeting is the failure this exists to end. Row hides at zero.
        if model.status.unsavedCaptures > 0 || !model.recoverableOrphans.isEmpty || !model.strandedCaptures.isEmpty {
            statusRow(
                "Unsaved recordings",
                value: unsavedCapturesLabel,
                good: false
            )
            Text("Recordings that never became meetings. Save or recover them before they expire.")
                .font(.caption2)
                .foregroundStyle(COSPalette.amber)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if !model.recoverableOrphans.isEmpty {
                VStack(alignment: .trailing, spacing: 6) {
                    // ONLY when there is more than one. With exactly one
                    // capture this rendered a second button reading
                    // "Recover", identical to the per-row button below and
                    // firing the same recovery on the same session (the
                    // branch below falls through to .first). The user saw two
                    // identical buttons, one greyed, and could not tell which
                    // was authoritative. The per-row button already covers the
                    // single case AND carries the label and chunk count that
                    // say WHAT is being recovered.
                    if model.recoverableOrphans.count > 1 {
                        // The single-capture fallback that used to live here
                        // is gone with the single-capture button: unreachable
                        // once the guard above exists.
                        Button("Recover all") { confirmRecoverAllOrphans = true }
                            .controlSize(.small)
                            .disabled(model.busy || model.orphanBusy)
                    }
                    ForEach(model.recoverableOrphans) { capture in
                        HStack(spacing: 8) {
                            Text(capture.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Button("Recover") { model.recoverOrphan(capture.sessionId) }
                                .controlSize(.mini)
                                .disabled(model.busy || model.orphanBusy || capture.recovering)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if !model.strandedCaptures.isEmpty {
                Text("These do not mean the phone has a meeting waiting. Save needs a transcript.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                VStack(alignment: .trailing, spacing: 6) {
                    if model.strandedCaptures.filter({ $0.canSave }).count > 1 {
                        Button("Save all") { confirmSaveAllStranded = true }
                            .controlSize(.small)
                            .disabled(model.busy || model.orphanBusy)
                    }
                    ForEach(model.strandedCaptures) { capture in
                        HStack(spacing: 8) {
                            Text(capture.label)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            if capture.canSave {
                                Button("Save") { model.saveStranded(capture.sessionId) }
                                    .controlSize(.mini)
                                    .disabled(model.busy || model.orphanBusy)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Agent CLIs (ST-24).
    @ViewBuilder private var statusAgentRows: some View {
        // One quick-glance row for all three agent backends. Cursor keeps
        // its own detailed row below because the helper probes it locally
        // (sign-in state, not just presence) — richer than health's flag.
        statusRow("AI apps", value: agentCliSummary, good: agentCliAllReady)
        // Onboarding P1: "Not found" vs "Not signed in" comes from the helper's provider-status (a failed server
        // `--version` was labelled "Not signed in" before); the server's flags are the fallback.
        AgentCliDetailLine(guide: model.providerGuide, model: model, allReady: agentCliAllReady)
    }

    /// Cursor CLI (ST-25).
    @ViewBuilder private var statusCursorRow: some View {
        statusRow("Cursor Agent", value: cursorLabel, good: model.status.cursorReady)
    }

    /// Ollama (ST-26).
    @ViewBuilder private var statusOllamaRow: some View {
        // Hide-unless-ready, and never `good: ollamaReady ?? false` -- that
        // would paint a red mark on every pre-6.39.0 server and on this Mac
        // today. No row is the correct render for "no local daemon".
        if model.status.ollamaReady == true, let ollamaName = model.status.ollamaModel, !ollamaName.isEmpty {
            statusRow("Ollama", value: ollamaName, good: true)
        }
    }

    /// The server version (ST-27).
    @ViewBuilder private var statusVersionRow: some View {
        statusRow("Version", value: model.status.runtimeState == "managedInPlace" ? "Self-managed" : (model.status.version ?? model.status.installedVersion ?? "Not installed"), good: model.status.installed || model.status.runtimeState == "managedInPlace")
    }

    /// The work folder and a restart it waits for (ST-28).
    @ViewBuilder private var statusWorkFolderRows: some View {
        if hubOn {
            hubPathRow(model.status.workDirectory ?? "Default COS context", line: nil)
        } else {
        HStack(alignment: .top) {
            Text("Work folder").foregroundStyle(.secondary)
            Spacer()
            Text(model.status.workDirectory ?? "Default COS context")
                .lineLimit(2).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.caption)
        }
        if model.status.workDirectoryPending {
            Label("Saved. Restart the server when no work is running to use it.", systemImage: "clock.badge.exclamationmark")
                .font(.caption).foregroundStyle(COSPalette.amber)
        }
    }

    /// The meetings library (ST-29).
    @ViewBuilder private var statusLibraryRows: some View {
        if hubOn {
            hubPathRow(model.status.operationsDirectory ?? "Not set (standalone recordings)", line: model.status.operationsDirectory == nil ? nil
                       : (model.status.meetingLibraryLayout == "direct" ? "One folder" : "Multiple folders") + " · \(model.status.meetingLibraryCount) meeting(s)")
        } else {
        HStack(alignment: .top) {
            Text("Meetings folder").foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.status.operationsDirectory ?? "Not set (standalone recordings)")
                    .lineLimit(2).multilineTextAlignment(.trailing).textSelection(.enabled)
                if model.status.operationsDirectory != nil {
                    Text(model.status.meetingLibraryLayout == "direct"
                        ? "One folder · \(model.status.meetingLibraryCount) meeting(s)"
                        : "Multiple folders · \(model.status.meetingLibraryCount) meeting(s)")
                        .foregroundStyle(.secondary)
                }
            }
        }.font(.caption)
        }
        if let warning = model.status.meetingLibraryWarning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(COSPalette.amber)
        }
    }

    /// Active jobs and recordings lock restart (ST-30).
    @ViewBuilder private var statusActiveWorkLine: some View {
        if let jobs = model.status.activeJobs, let recordings = model.status.activeTranscriptionSessions, jobs + recordings > 0 {
            Label("\(jobs) job(s), \(recordings) recording(s) active. Restart is off until they finish.", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(COSPalette.amber)
        }
    }

    /// A pending server change (ST-31).
    @ViewBuilder private var statusTransactionLine: some View {
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

    private var contextBrowserLabel: String {
        let memoryReady = model.status.memoryAvailable == true
        let threadsReady = model.status.threadsAvailable == true
        if memoryReady && threadsReady {
            return "\(model.status.memoryCount) memories · \(model.status.threadCount) threads"
        }
        if memoryReady { return "Memory ready · Threads unavailable" }
        if threadsReady { return "Threads ready · Memory unavailable" }
        if model.status.contextState == "bridge_outdated" { return "Workspace update required" }
        if model.status.contextState == "bridge_error" { return "Temporarily unavailable" }
        return "Setup needed"
    }

    /// What to do next, stated concretely enough to act on.
    ///
    /// Branches on WHY it is unavailable. Telling someone whose bridge is mid-error
    /// to go create a folder is noise, and telling someone with no workspace that
    /// "empty stores are healthy" is not a next step.
    ///
    /// Queen, 2026-08-09, on the version of this that pointed at the picker: "That
    /// message sent me to the COS Data picker, which is the wrong place... choosing
    /// COS Data is not what fixes it. What fixes it is creating two directories."
    /// There is now a button for that, so the hint names the button.
    private var contextBrowserHint: String {
        switch model.status.contextState {
        case "bridge_outdated": return "Update your COS workspace, then choose the notes folder again."
        case "bridge_error": return "The workspace bridge failed. Open logs, then choose the notes folder again."
        default:
            if model.status.contextResolvedRoot != nil {
                return "The store resolved but holds no notes yet. Drop markdown files into memory/ or threads/."
            }
            if let suggested = model.status.contextSuggestedRoot {
                return "No memory/ or threads/ folder yet. Create Folders makes them in \(shortPath(suggested))."
            }
            return "Choose a work folder or meetings folder first, then Create Folders."
        }
    }

    /// Trailing path components only. The full path goes on its own selectable line.
    private func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count <= 2 ? path : "…/" + parts.suffix(2).joined(separator: "/")
    }

    /// Where the notes actually are, and which tier is reading them.
    ///
    /// The whole diagnosis Queen had to do by reading source — which root won, which
    /// were tried, and whether the Python tier is even reachable — is data Control
    /// already had and simply never showed.
    @ViewBuilder private var contextDetail: some View {
        if let root = model.status.contextResolvedRoot {
            Text("Root: \(root)").font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else if !model.status.contextCandidateRoots.isEmpty {
            Text("Looked in: " + model.status.contextCandidateRoots.map(shortPath).joined(separator: ", "))
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        if let scripts = model.status.dormantBridgeScripts {
            // Reported, never applied on our own initiative: switching tiers stops the
            // file tier being consulted at all, so notes being browsed today would
            // silently stop appearing.
            Text("A Python bridge is installed but unused at \(shortPath(scripts)). Choose it as the notes folder to use it instead of plain files.")
                .font(.caption2).foregroundStyle(COSPalette.amber)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
    }

    /// Restart, Stop, Start, Update Server and Install Server, then the legacy paths and the server's messages (C-01 to C-09).
    private var controls: some View {
        VStack(spacing: 9) {
            serverControlButtons
            serverForegroundWarning
            serverLegacyControls
            serverMessages
        }
    }

    /// C-01 to C-05, disabled while busy.
    private var serverControlButtons: some View {
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
                              || model.status.transactionPending
                              || model.status.meetingWorkBlockingRestart)
                Button("Stop", systemImage: "stop.fill", role: .destructive) { model.perform("stop") }
                    .buttonStyle(COSQuietButtonStyle(tone: .destructive))
                    .disabled(model.status.runtimeState == "managedInPlace" && !model.status.safeToRestart)
            } else if model.status.runtimeState == "stopped" {
                Button("Start", systemImage: "play.fill") { model.perform("start") }.buttonStyle(COSPrimaryButtonStyle())
            }
            Spacer()
            if model.status.installed && model.status.managedContract && model.status.ownershipVerified {
                Button("Update Server") { model.perform("update") }
                    .disabled(model.status.meetingWorkBlockingRestart)
            } else if !model.status.installed && model.status.runtimeState == "notInstalled" {
                Button("Install server") { model.installCurrentRelease() }.buttonStyle(COSPrimaryButtonStyle())
            }
        }
        .disabled(model.busy)
    }

    /// A foreground server owns the ports (C-09).
    @ViewBuilder private var serverForegroundWarning: some View {
        if model.status.runtimeState == "legacyForeground" {
            Label("A foreground server owns the ports. Finish active work and stop it in Terminal before installing.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(COSPalette.amber)
        }
    }

    /// Adopt Safely, Manage in place and Install managed server, each only for its legacy state (C-06 to C-08).
    @ViewBuilder private var serverLegacyControls: some View {
        if model.status.runtimeState == "legacyStopped" {
            HStack {
                Label("COS Control can replace this stopped older server with the latest COS server.", systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                Button("Adopt server") { model.installLatestManagedFromLegacy() }
            }.font(.caption).foregroundStyle(COSPalette.amber)
        }
        if model.status.runtimeState == "legacyService" {
            VStack(alignment: .leading, spacing: 8) {
                Label("Your server is running. COS Control can restart and recover it without replacing it.", systemImage: "checkmark.seal")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Manage in place") { model.perform("adopt-in-place") }
                        .buttonStyle(COSPrimaryButtonStyle())
                    Button("Replace server") {
                        confirmInstallManaged = true
                    }
                    .controlSize(.small)
                    .disabled((model.status.activeJobs ?? 0) + (model.status.activeTranscriptionSessions ?? 0) > 0)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// An ownership conflict, operation progress and the green notice (C-09).
    @ViewBuilder private var serverMessages: some View {
        serverProgressMessages
        serverNoticeLine
    }

    /// The ownership conflict and an operation's progress: in the hub, on every page (top strip).
    @ViewBuilder private var serverProgressMessages: some View {
        if model.status.ownerConflict {
            Label("Ownership conflict detected. COS Control will not stop or replace the unknown listener.", systemImage: "exclamationmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
        }
        if let progress = model.operationProgress {
            Text(progress).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The green notice: in the hub, on System only, since other actions ("Copied") write it too (QA delta N1).
    @ViewBuilder private var serverNoticeLine: some View {
        if let notice = model.notice {
            Text(notice).font(.caption).foregroundStyle(COSPalette.green).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Saved meetings whose speakers can be reviewed. Deliberately its own card
    /// rather than a row inside Recent Glasses: that list is turns (messages and
    /// photos), and a meeting is a different kind of thing with a different action.
    private var mainPanel: some View {
        ScrollViewReader { reader in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 2026-10-09 (Miles, like Vorssant): an update that is ready is the first thing in the panel, above the
                // header. Nothing renders here without one. The standing version card is gone (2026-10-09, after
                // 0.5.276): the header's version stamp and its refresh button, which also checks, answer instead.
                updateBanner
                if hostedInActivity {
                    // Settings in Activity has no panel header, and it carried the version card too: the same
                    // refresh-and-check button and status line here keep its manual check (2026-10-09).
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Settings").font(COSType.body(28, weight: .semibold))
                            updateStatusLine(idle: "Manage your Mac companion, voice, connected AI and preferences.", size: 13)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if model.busy { ProgressView().controlSize(.small) }
                        refreshAndCheckButton
                    }
                } else { header }
                // Activity's classic Settings: the way back to the hub, since its switch (General, Advanced) is not on
                // this page (QA 2026-10-28). The menu-bar panel and the Settings window have no host and never show it.
                if hub != nil {
                    HStack(spacing: 8) {
                        Text("You are using classic Settings.").font(COSType.body(12)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Use new Settings") { useClassicSettings = false }
                            .buttonStyle(COSQuietButtonStyle())
                            .accessibilityIdentifier("settings-use-new")
                    }
                }
                if model.recordingCount > 0 { recordingCard }
                // Upgraders, once: COS Control is in the Dock now (Menu bar only / Keep).
                DockNoticeLine(model: model)
                // Early users: Finish setup at the top until every row is done or skipped, or Hide setup guide.
                FinishSetupCard(model: model, provider: model.providerGuide, guide: model.setupGuide, permissions: model.permissionGuide) {
                    model.providerGuide.openInPanel()
                    withAnimation(Motion.gated(.default, reduceMotion: reduceMotion)) { reader.scrollTo("setup-guide", anchor: .top) }
                }
                noticeBanner
                if model.status.needsFirstRun {
                    Button("Get started with COS") { model.openSetup?() }
                        .buttonStyle(COSPrimaryButtonStyle())
                }
                if !hostedInActivity { activityLauncher }
                if model.workYourMoveAvailable && !model.workYourMove.isEmpty {
                    Button { openActivity(.work) } label: {
                        HStack {
                            Label("Your move · \(model.workYourMove.count)", systemImage: "hand.point.up.left")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.font(COSType.body(12, weight: .medium))
                    }.buttonStyle(.plain)
                }
                statusCard
                controls
                // F4: the session pet introduced once, with Keep, Calm and Hide.
                PetIntroLine(model: model)
                // The setup guide: one line ("Setup guide · 3 of 9") that opens the whole guide in place.
                PanelConnectAIRow(guide: model.providerGuide, model: model)
                    .id("setup-guide")
                // Permissions: one line ("All set", "1 needs you") that opens the guide card in place.
                PanelPermissionsRow(guide: model.permissionGuide)
                // 0.5.317: Install Parakeet from the menu bar while dictation is on and Parakeet is not installed.
                PanelParakeetRow(model: model, store: model.transcriptionSettings, dictationOn: model.dictation.enabled)
                if model.status.morningBriefSupported { morningBriefCard }
                if model.status.tasksGate != nil { domainsCard }
                if !model.fenceRecords.isEmpty { fencesCard }
                if !model.doctorChecks.isEmpty { doctorCard }
                MeetingAskSettings(store: model.meetingAsk, model: model)
                    .id("settings")
                    .task { await model.transcriptionSettings.load(TranscriptionSettingsCard.run(model)) }
                // Transcription (server 6.72.0): hidden on an older server (404) and until the server has answered,
                // so it is loaded from here, a view that is always drawn.
                TranscriptionSettingsCard(store: model.transcriptionSettings, model: model)
                    .id("transcription")
                // Key lanes (K1, server 6.80.0): drawn only for a server that can turn them on (Sources/KeyLanesViews.swift).
                KeyLanesSettingsRow(model: model)
                utilities
                footer
            }
            .padding(16)
        }
        // The pet's and the Dock's Settings… open this panel scrolled to its settings.
        .onAppear { scrollToTarget(reader) }
        .onChange(of: model.panelScrollTarget) { _, _ in scrollToTarget(reader) }
        }
    }

    /// H-10: a live recording, with View live transcript and, for one live glasses meeting, Stop and save. Above every
    /// page in both layouts.
    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.recordingLabel, systemImage: "record.circle.fill")
                .font(COSType.body(13, weight: .semibold))
                .foregroundStyle(Color.red)
            // 0.5.313: the quiet, non-blocking reminder while this Mac records.
            if model.macRecordingActive {
                Text(MacRecordingNotice.reminder).font(COSType.body(11)).foregroundStyle(.secondary)
            }
            if model.liveTranscriptEnabled {
                HStack(spacing: 8) {
                    Button("View live transcript") { model.showRecordingTranscript() }
                        .buttonStyle(COSQuietButtonStyle())
                    // 0.5.321: the one live glasses meeting stops from here too, after the inline confirmation.
                    if let id = model.soleLiveGlassesMeetingID {
                        Button(G2MeetingStop.buttonLabel) { glassesStopTarget = id }
                            .buttonStyle(COSQuietButtonStyle())
                            .disabled(model.glassesMeetingStopping(id))
                    }
                }
                if let line = model.glassesMeetingStopLine(model.glassesMeetingStop?.sessionId) {
                    Text(line).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Turn on Live transcript in Settings to view this recording.")
                    .font(COSType.body(12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func scrollToTarget(_ reader: ScrollViewProxy) {
        guard let target = model.panelScrollTarget else { return }
        // 0.5.322: Live cues' "Add a Jev or SubQ key" lands on Decision models, opened, where both key fields are.
        if target == LiveCues.decisionKeysAnchor { jevExpanded = true }
        DispatchQueue.main.async {
            reader.scrollTo(target, anchor: .top)
            model.panelScrollTarget = nil
        }
    }

    /// One doorway instead of five nested browsers in a 390pt transient panel.
    /// The destination is a durable window with peer tabs and a real back stack.
    /// Chips come from ActivitySection.allCases so a new view cannot ship invisible.
    /// Each chip opens that tab. The title/Open row opens the window without
    /// resetting a place the user already had.
    private var activityLauncher: some View {
        VStack(alignment: .leading, spacing: 11) {
            Button {
                openActivity(nil)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activity")
                            .font(COSType.display(13, weight: .semibold))
                        Text("Browse without losing your place")
                            .font(COSType.body(10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("Open", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 10.5, weight: .medium))
                }
            }
            .buttonStyle(.plain)
            .help("Open Messages, Speakers, Meetings, Memories, Threads, Sessions, and Tasks in a separate window")
            VStack(alignment: .leading, spacing: 7) {
                // Chips WRAP: a fixed 4 + 3 split broke mid-word at 332 pt the
                // moment one chip carried a three-digit number (QA 2026-09-06).
                ChipFlowLayout(spacing: 7) {
                    ForEach(ActivitySection.allCases) { item in
                        activityChip(item)
                    }
                }
                // Two marks only (Miles, 2026-09-06): a number means needs you, a
                // dot means new since that section was last opened. The legend
                // ships with the signals so the chips never explain themselves.
                if let legend = model.activitySignals?.legend, !legend.isEmpty {
                    Text(legend)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                if let error = model.activitySignalsError {
                    // A failed signals call must not look like "nothing needs you".
                    Text("Marks unavailable: \(error)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(COSPalette.amber)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
    }

    private func activityChip(_ item: ActivitySection) -> some View {
        // Re-render on a moved cursor comes from the @Published bump in
        // markActivityOpened (activityCursorVersion), not from reading it here.
        let number = model.activityNumber(item)
        let dot = number == nil && model.activityDot(item)
        return Button {
            openActivity(item)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: item.icon)
                Text(item.title)
                    .lineLimit(1)
                    .fixedSize()
                // 0.5.278: a meeting is recording now (the server's count), unless the live transcript is off.
                if item == .meetings, showLiveTranscript, model.liveTranscriptDot {
                    LiveDot(size: 5).accessibilityLabel("Meeting recording now")
                }
                if let number {
                    Text(number > 99 ? "99+" : "\(number)")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(item.tint.opacity(0.22), in: Capsule())
                        .accessibilityLabel("\(number) need you")
                } else if dot {
                    Circle()
                        .fill(item.tint)
                        .frame(width: 5, height: 5)
                        .accessibilityLabel("New since you last opened it")
                }
            }
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(item.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(item.tint.opacity(0.10), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open \(item.title)")
        .accessibilityLabel("Open \(item.title)")
    }

    /// Threads COS has shut because an earlier turn may already have landed.
    ///
    /// CONDITIONAL, like `doctorCard`: normally there are none, and a permanently
    /// empty card teaches the reader to skim past it. It appears only when there is
    /// something to act on — which is also the only time it can be found, since a
    /// fence was previously discoverable only by being refused on the glasses.
    private var fencesCard: some View {
        fencesContent
        .padding(13)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
    }

    /// FN-01 and FN-02.
    private var fencesContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // The hub's card already says Paused threads.
                if !hubOn {
                Text("Paused threads · \(model.fenceRecords.count)")
                    .font(.caption2.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if model.fenceRecordsLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Refresh") { Task { await model.loadFences() } }
                        .font(.system(size: 10))
                        .controlSize(.small)
                }
            }

            Text("COS stopped writing here after a message it sent went unconfirmed. Check the thread first.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.fenceDegraded {
                // The server said its last durable write failed. A memory-only fence
                // behaves identically until the process restarts, so saying nothing
                // would be indistinguishable from working.
                Label("These clear on a server restart. The server could not save them.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.fenceRecords) { fence in
                    Button { model.askReleaseFence(fence) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(fence.provider.isEmpty ? "thread" : fence.provider)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1)
                                Text("paused \(fence.fencedAtLabel)")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 4)
                            Text("Release")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Let COS write to this thread again")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let note = model.fenceReleaseNote {
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = model.fenceReleaseError {
                Text(err).font(.system(size: 10)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// O-01: named speakers are off, or the voiceprint model failed to load, with Run Guided Setup. Held by the unmounted
    /// Review speakers card; the hub shows it at the top of Transcription and voice.
    @ViewBuilder private var speakerModelWarning: some View {
        // Named diarization depends on a 26 MB voiceprint model that NO install
        // or update path fetches: COS Control stages the server with
        // `npm install --ignore-scripts` and never executes bin/cli.cjs, and the
        // package ships no install hook. Guided Setup is the only route to it.
        //
        // Without this the failure was invisible in the one place it matters:
        // the panel listed two voices for a five-person meeting, called them Me
        // and Ext, and said nothing. /api/health has reported the state all
        // along and Control had never read it.
        if model.status.speakerIdNeedsSetup {
            VStack(alignment: .leading, spacing: 6) {
                Label(model.status.speakerId == "error"
                        ? "Voiceprint model failed to load"
                        : "Named speakers are off",
                      systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(COSPalette.amber)
                Text(model.status.speakerId == "error"
                     ? "The voiceprint model is present but did not load. Every voice shows as Me or Ext until it does."
                     : "Every voice shows as Me or Ext until guided setup installs the voiceprint model (26 MB).")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Run guided setup", systemImage: "terminal") {
                    showGuidedSetupTier = true
                }
                .font(.system(size: 11))
                .controlSize(.small)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 8))
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

            speakerModelWarning

            if model.reviewableMeetings.isEmpty {
                Text(model.reviewError ?? "Name the voices in a saved meeting.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let shown = Array(model.rankedReviewableMeetings.prefix(MEETING_LIST_VISIBLE))
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
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
    }

    @ViewBuilder
    // ── Morning brief (server 6.43.0) ────────────────────────────────────────
    //
    // Split into small views on purpose: one `body` holding the schedule row,
    // the weekday buttons, and the per-source option editors exceeded what the
    // SwiftUI type-checker will solve in one expression (see `mainPanel`).
    // The card edits a DRAFT and saves in one Apply, because every field is
    // one PUT and a stepper that saved on each tick would restart the schedule
    // math on every click. Lists cap and scroll: 11 sources with options would
    // otherwise push the footer off the 390pt panel (2026-08-26 rule).

    /// Domains card. The place a user sets their own domains, so nobody has to
    /// hand-edit ~/.cos-glasses/.cos-profile.json — and so a COS that is not this
    /// one is not stuck with this one's business units.
    ///
    /// The list shown is the RESOLVED list: configured names plus any folder on
    /// disk holding a tasks.md. Removing a name only removes it from config, so a
    /// folder that still holds tasks keeps appearing. Saying that in the card is
    /// the point: a delete that looks like it failed is worse than no delete.
    private var domainsCard: some View {
        domainsContent
        .padding(13)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
        .task {
            await model.loadDomains()
            syncDomainsDraft(force: false)
        }
    }

    /// DM-01 to DM-03. The panel's card adds the chrome and its loader; the hub loads from its root.
    private var domainsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                // The hub's card already says Domains.
                if !hubOn { Text("Domains").font(.headline) }
                Spacer()
                if domainsBusy { ProgressView().controlSize(.small) }
            }
            if model.domainOptions.isEmpty {
                Text("No domains yet. COS uses the folders under operations/ that hold a tasks.md.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(domainsDraft.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 6) {
                    TextField("domain", text: Binding(
                        get: { index < domainsDraft.count ? domainsDraft[index] : "" },
                        set: { if index < domainsDraft.count { domainsDraft[index] = $0 } }
                    ))
                    .textFieldStyle(.plain)
                    .cosField()
                    Button {
                        if index > 0 { domainsDraft.swapAt(index, index - 1) }
                    } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .buttonStyle(COSIconButtonStyle(size: 22))
                    .accessibilityLabel("Move up")
                    Button {
                        if index < domainsDraft.count { domainsDraft.remove(at: index) }
                    } label: { Image(systemName: "minus") }
                    .buttonStyle(COSIconButtonStyle(size: 22))
                    .accessibilityLabel("Remove")
                }
            }
            HStack(spacing: 8) {
                Button("Add") { domainsDraft.append("") }
                Button("Save") { saveDomainsDraft() }
                    .disabled(domainsBusy || domainsDraft.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                Button("Reset") { syncDomainsDraft(force: true) }
                    .disabled(domainsBusy)
                Spacer()
            }
            if !domainsError.isEmpty {
                Text(domainsError).font(.caption2).foregroundStyle(.red)
            }
            Text("Any folder in operations/ with a tasks.md shows here. Remove unlists it; its tasks stay.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func syncDomainsDraft(force: Bool) {
        if force || domainsDraft.isEmpty {
            domainsDraft = model.domainOptions.map(\.name)
            domainsError = ""
        }
    }

    private func saveDomainsDraft() {
        let names = domainsDraft
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        domainsBusy = true
        domainsError = ""
        Task {
            defer { domainsBusy = false }
            do {
                try await model.saveDomains(names)
                syncDomainsDraft(force: true)
            } catch {
                domainsError = error.localizedDescription
            }
        }
    }

    private var morningBriefCard: some View {
        morningBriefContent
        .padding(13)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
        .task { await model.loadMorningBrief(quiet: true) }
        .onChange(of: model.morningBrief?.updatedAt) { _, stamp in
            syncMorningBriefDraft(force: stamp != briefDraftStamp)
        }
        .onAppear { syncMorningBriefDraft(force: briefDraft == nil) }
    }

    /// MB-01 to MB-09. The panel's card adds the chrome and its loaders; the hub loads from its root.
    private var morningBriefContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            morningBriefHeader
            if let draft = briefDraft {
                morningBriefSchedule(draft)
                morningBriefSources(draft)
                morningBriefActions
            } else {
                morningBriefPlaceholder
            }
        }
    }

    private func syncMorningBriefDraft(force: Bool) {
        guard force, let settings = model.morningBrief else { return }
        briefDraft = settings
        briefDraftStamp = settings.updatedAt
    }

    private var morningBriefHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            // The hub's card already says Morning brief.
            if !hubOn { Text("MORNING BRIEF").font(.caption2.weight(.bold)).tracking(1.3).foregroundStyle(.secondary) }
            // The hub's row label for the status line (MB-01), so it never sits alone on the right.
            if hubOn { Text(hubLabel("MB-01")).font(COSType.body(14.5, weight: .semibold)).foregroundStyle(TodayInk.ink) }
            Spacer()
            Text(morningBriefStatusLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// One line the wearer can trust: when the next brief fires, or why it will not.
    private var morningBriefStatusLine: String {
        switch model.status.morningBriefGate {
        case "durable_jobs_off": return "Off while Background jobs are off"
        case "admissions_closed": return "Paused for maintenance"
        default: break
        }
        if let draft = briefDraft, !draft.enabled { return "Off" }
        if let next = (briefDraft ?? model.morningBrief)?.nextRunLabel { return "Next \(next)" }
        if let time = model.status.morningBriefTime { return "Daily at \(time)" }
        return ""
    }

    private var morningBriefPlaceholder: some View {
        Group {
            if model.morningBriefState.hasPrefix("error:") {
                Text(String(model.morningBriefState.dropFirst("error:".count)))
                    .font(.caption2).foregroundStyle(COSPalette.amber)
                Button("Retry") { Task { await model.loadMorningBrief() } }
            } else {
                Text("Loading the schedule…").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func morningBriefSchedule(_ draft: MorningBriefSettings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle("Brief every", isOn: Binding(
                    get: { briefDraft?.enabled ?? draft.enabled },
                    set: { briefDraft?.enabled = $0 }
                ))
                .toggleStyle(COSSwitchStyle())
                .fixedSize()
                TextField("07:00", text: Binding(
                    get: { briefDraft?.time ?? draft.time },
                    set: { briefDraft?.time = $0 }
                ))
                .textFieldStyle(.plain)
                .cosField()
                .frame(width: 58)
                .multilineTextAlignment(.center)
                Text(draft.timezone).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            morningBriefWeekdays
            Text("Lands in your inbox once a day. If the Mac is asleep, it runs within 3 hours.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private static let morningBriefWeekdayOrder: [(day: Int, label: String)] = [
        (1, "M"), (2, "T"), (3, "W"), (4, "T"), (5, "F"), (6, "S"), (0, "S"),
    ]

    private var morningBriefWeekdays: some View {
        HStack(spacing: 4) {
            ForEach(Self.morningBriefWeekdayOrder, id: \.day) { entry in
                Toggle(entry.label, isOn: Binding(
                    get: { briefDraft?.days.contains(entry.day) ?? false },
                    set: { on in
                        guard var draft = briefDraft else { return }
                        var days = Set(draft.days)
                        if on { days.insert(entry.day) } else { days.remove(entry.day) }
                        draft.days = days.sorted()
                        briefDraft = draft
                    }
                ))
                .toggleStyle(COSChipToggleStyle())
                .frame(width: 26)
            }
            Spacer(minLength: 0)
        }
    }

    private func morningBriefSources(_ draft: MorningBriefSettings) -> some View {
        DisclosureGroup(isExpanded: $briefSourcesExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(draft.sources) { source in
                        morningBriefSourceRow(source, spec: draft.spec(for: source.id))
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 230)
        } label: {
            let count = draft.sources.filter(\.enabled).count
            Text("Sources · \(count) on").font(.caption)
        }
        .font(.caption)
    }

    private func morningBriefSourceRow(_ source: MorningBriefSettings.Source, spec: MorningBriefSettings.SourceSpec?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { briefDraft?.sources.first { $0.id == source.id }?.enabled ?? source.enabled },
                set: { on in updateBriefSource(source.id) { $0.enabled = on } }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(spec?.label ?? source.id).font(.caption.weight(.semibold))
                    if let description = spec?.description, !description.isEmpty {
                        Text(description).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    // Server 6.43.1: the depth behind the source, from the same
                    // wells the Activity tiles read. Amber only when a probe that
                    // should answer did not; "runtime" is a fact, not a warning.
                    if let coverage = model.morningBrief?.coverage[source.id] {
                        Text(coverage.summary)
                            .font(.caption2)
                            .foregroundStyle(coverage.state == "unavailable" ? COSPalette.amber : coverage.state == "ready" ? COSPalette.green : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .toggleStyle(COSCheckStyle())
            if source.enabled, let options = spec?.options, !options.isEmpty {
                ForEach(options) { option in
                    morningBriefOption(sourceID: source.id, option: option, value: source.options[option.key])
                }
                .padding(.leading, 22)
            }
        }
    }

    private func updateBriefSource(_ id: String, _ mutate: (inout MorningBriefSettings.Source) -> Void) {
        guard var draft = briefDraft, let index = draft.sources.firstIndex(where: { $0.id == id }) else { return }
        mutate(&draft.sources[index])
        briefDraft = draft
    }

    @ViewBuilder
    private func morningBriefOption(sourceID: String, option: MorningBriefSettings.OptionSpec, value: JSONValue?) -> some View {
        switch option.type {
        case "boolean":
            Toggle(option.label, isOn: Binding(
                get: { value?.bool ?? option.defaultValue.bool ?? false },
                set: { on in updateBriefSource(sourceID) { $0.options[option.key] = .bool(on) } }
            ))
            .toggleStyle(COSCheckStyle())
            .font(.caption2)
        case "integer":
            let current = value?.int ?? option.defaultValue.int ?? 0
            COSStepper(option.label, value: Binding(
                get: { current },
                set: { new in updateBriefSource(sourceID) { $0.options[option.key] = .number(Double(new)) } }
            ), in: (option.min ?? 0)...(option.max ?? 365),
                valueText: "\(current) \(option.unit ?? "")".trimmingCharacters(in: .whitespaces))
            .font(.caption2)
        default:
            TextField(option.placeholder ?? option.label, text: Binding(
                get: { value?.string ?? "" },
                set: { text in updateBriefSource(sourceID) { $0.options[option.key] = .string(text) } }
            ))
            .textFieldStyle(.plain)
            .cosField()
        }
    }

    @ViewBuilder private var morningBriefActions: some View {
        HStack(spacing: 8) {
            Button("Apply", systemImage: "checkmark") {
                if let draft = briefDraft { model.saveMorningBrief(draft) }
            }
            .disabled(model.busy || briefDraft == nil)
            Button("Run now", systemImage: "sunrise") { model.runMorningBriefNow() }
                .disabled(model.busy || model.status.morningBriefGate == "durable_jobs_off" || model.status.runtimeState != "managedHealthy")
                .help("Runs the brief right away and drops it in the inbox. Five a day.")
            Spacer()
        }
        .buttonStyle(COSQuietButtonStyle())
        if let last = model.morningBrief?.runs.first {
            // 0.5.185 — its own wrapping line, so a refusal reason is readable on
            // the 390pt card instead of truncated behind two buttons.
            Text(morningBriefRunLabel(last))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(morningBriefRunLabel(last))
        }
    }

    private func morningBriefRunLabel(_ run: MorningBriefSettings.Run) -> String {
        let number = run.globalMsgNum.map { " #\($0)" } ?? ""
        switch run.status {
        case "completed":
            if let sections = run.sectionsLabel { return "Delivered\(number) · \(sections)" }
            return "Last brief delivered\(number)"
        case "failed", "submit_failed":
            // 0.5.185 — the reason travels with the verdict. A 6.43.4 server
            // that refuses the submission (a strict-origin 400, a closed
            // admission) is visible here, on the card, before any inbox exists.
            // Server-authored text on a card line: collapse newlines and drop
            // control characters before it reaches a Text, the way boundedToken
            // does for identifiers; then cap it.
            let reason = (run.errorMessage ?? "")
                .components(separatedBy: .newlines).joined(separator: " ")
                .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
                .reduce(into: "") { $0.unicodeScalars.append($1) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !reason.isEmpty { return "Last brief failed · \(reason.prefix(160))" }
            return "Last brief failed"
        case "canceled", "interrupted": return "Last brief \(run.status)"
        default: return "Brief running\(number)"
        }
    }

    private var doctorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHECKS").font(.caption2.weight(.bold)).tracking(1.3).foregroundStyle(.secondary)
            doctorResults
        }
        .padding(13)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
    }

    /// DR-01: the last Run Doctor's checks.
    private var doctorResults: some View {
        ForEach(model.doctorChecks) { check in
            HStack(alignment: .center, spacing: 8) {
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

    /// Local model rows: Automatic, each pulled tag, then a configured pin gone from the daemon. The pin must
    /// still show, or the dropdown would lie about the server's actual configuration.
    private var ollamaModelOptions: [COSDropdownOption<String>] {
        var rows = [COSDropdownOption("", "Newest pulled model")] + model.ollamaTags.map { COSDropdownOption($0, $0) }
        if let pinned = model.status.ollamaConfiguredModel, !model.ollamaTags.contains(pinned) {
            rows.append(COSDropdownOption(pinned, pinned, note: "not pulled", muted: true))
        }
        return rows
    }

    private var utilities: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TOOLS").font(.caption2.weight(.bold)).tracking(1.3).foregroundStyle(.secondary)
            HStack {
                Button("Run checks", systemImage: "stethoscope") { model.perform("doctor") }
                Button("Guided setup", systemImage: "terminal") { showGuidedSetupTier = true }
            }
            toolTranscriptionTier(hub: false)
            toolBackgroundJobs(hub: false)
            toolMeetingPreview(hub: false)
            toolClaudeSessions(hub: false)
            toolThreadAttach(hub: false)
            toolOllamaModel(hub: false)
            toolVideoUploads(hub: false)
            toolIdleMetal(hub: false)
            toolAudioCleanup(hub: false)
            HStack {
                Button("Repair server", systemImage: "wrench.and.screwdriver") { model.perform("repair") }
                    .disabled(repairRuntimeBlocked)
                if repairWhisperOffered {
                    Button("Repair Whisper", systemImage: "waveform.badge.exclamationmark") { model.perform("restart-whisper") }
                }
            }
            // Own row so labels don't truncate into ambiguous "Choose…" / "Meeting…"
            HStack {
                Button("Work folder", systemImage: "folder") { model.selectWorkFolder() }
                    .disabled(folderPickBlocked)
                    .help(folderHelp(workFolderHelp))
                Button("Meetings folder", systemImage: "calendar") { model.selectOperationsFolder() }
                    .disabled(folderPickBlocked)
                    .help(folderHelp(Self.meetingsLibraryHelp))
            }
            HStack {
                Button("Notes folder", systemImage: "externaldrive.badge.icloud") { model.selectContextFolder() }
                    .disabled(folderPickBlocked)
                    .help(folderHelp(Self.cosDataHelp))
                // Names the TIER, not just the path. "Notes" is browse and
                // reference; "Bridge" adds semantic recall and type statistics.
                // Showing a bare path let a files install look like a pipeline.
                // One tap replaces the two directories Queen had to create by hand.
                // Offered whenever no store has resolved, including when the picker
                // has never been touched, because that is exactly the new-install case.
                if model.status.contextResolvedRoot == nil {
                    Button("Create Folders", systemImage: "folder.badge.plus") { model.perform("create-context-folders") }
                        .disabled(serverNotInstalled)
                        .help(createFoldersHelp)
                }
                notesSourceLine
            }
            HStack {
                Button("Open Cursor", systemImage: "chevron.left.forwardslash.chevron.right") { model.openCursor() }
                Button("Copy pairing token", systemImage: "key") { model.perform("token") }
                    .disabled(pairingTokenBlocked)
            }
            HStack {
                Button("Copy report", systemImage: "doc.on.doc") { model.perform("report") }
                Button("Open logs", systemImage: "doc.text.magnifyingglass") { model.openLogs() }
                Button("Health page", systemImage: "heart.text.square") { model.openHealth() }
            }
            Divider()
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(COSSwitchStyle())
            // F3: in the Dock by default; the menu-bar icon stays either way, so menu bar only never strands anyone.
            Toggle("Menu bar only", isOn: Binding(get: { !model.showInDock }, set: { model.setShowInDock(!$0) }))
                .toggleStyle(COSSwitchStyle())
                .help("Hides the Dock icon. The menu bar icon stays; opening the app shows Activity.")
            HotKeyRecorderRow(model: model)
            MacDictationSettings(store: model.dictation, activityShortcut: model.activityHotKey)
            Divider()
            sessionPetSettings
            jevSettings
                .id(LiveCues.decisionKeysAnchor)
            workExpirySettings
            // 0.5.247: Work tracking notifications (a session received a task, finished it, or needs you).
            Toggle("Work notifications", isOn: Binding(get: { model.workNotificationsEnabled }, set: { model.workNotificationsEnabled = $0 }))
                .toggleStyle(COSSwitchStyle())
                .help("Alerts when a session gets Work, finishes it, or needs you.")
            // 0.5.249: a New session starts in the background, then opens in its app once its first reply is done.
            Toggle("Open new sessions", isOn: Binding(get: { model.workOpensTabs }, set: { model.workOpensTabs = $0 }))
                .toggleStyle(COSSwitchStyle())
                .help("Claude and Codex sessions open in their app after the first reply. Off: background only. Cursor always opens its own window with the handoff filled in, for you to send")
            // 0.5.312 (Miles 2026-10-15): Work chat plans and sends in one step. The first use still asks once.
            Toggle("Send plans without review", isOn: $workChatSendWithoutReview)
                .toggleStyle(COSSwitchStyle())
                .help("Work chat plans and sends in one step, each with a Stop. Each card can override it.")
            // 0.5.317 (Miles 2026-10-16): a send that earlier work on the card would hold queues by default. Plan and send
            // always queues; it never skips the check.
            COSDropdown("When work is open", selection: $workChatWhenHeld,
                        options: WorkChatHold.settingOptions.map { COSDropdownOption($0.0, $0.1) })
                .help(WorkChatHold.settingHelp)
                .accessibilityIdentifier("settings-work-chat-when-held")
            // 0.5.278: the live meeting transcript in Meetings. Stored in AppStorage, read by the model before any poll.
            Toggle("Live transcript", isOn: $showLiveTranscript)
                .toggleStyle(COSSwitchStyle())
                .help("Shows a glasses meeting at the top of Meetings while it records. Off reads nothing.")
                .onChange(of: showLiveTranscript) { _, _ in model.liveTranscriptSettingChanged() }
            // Activity Today home (plan v2, an opt-in candidate): the rail on every Activity tab and the Today home.
            Toggle("Today home", isOn: $todayHomeEnabled)
                .toggleStyle(COSSwitchStyle())
                .help("Activity opens on Today: what needs you, what is running and what is next.")
            if todayHomeEnabled {
                Toggle("Quiet hours", isOn: $todayQuietHours)
                    .toggleStyle(COSSwitchStyle())
                    .help("From 6 PM to 6 AM and on weekends, Today folds what can wait under For tomorrow.")
                Toggle("Work runs from Today", isOn: $todayWorkRuns)
                    .toggleStyle(COSSwitchStyle())
                    .help("Prep me and Ask start Work runs, up to 20 a day. Off: Ask files to the Work inbox.")
            }
            MeetingSuggestSettings(store: MeetingDetectorStore.shared, recording: model.macRecording)
            DisclosureGroup("Advanced") {
                // 0.5.234: the Meetings clock. The server sends 24-hour times and
                // the tab used to print them raw; twelve-hour is the default here
                // and the 24-hour reading is one pick away.
                COSDropdown("Time format", selection: Binding(
                    get: { model.clockStyle },
                    set: { model.setClockStyle($0) }
                ), options: ClockStyle.allCases.map { COSDropdownOption($0, $0.label) })
                .padding(.top, 6)
                Text("How times show in Meetings and Speakers.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Roll back server") { model.perform("rollback") }
                    Button("Finish server change") { model.perform("reconcile") }
                    Button("Online help") { model.openSetupGuide() }
                }.padding(.top, 6)
            }.font(.caption)
        }
        .buttonStyle(COSQuietButtonStyle())
        .disabled(model.busy)
    }

    // MARK: Gates and words shared by the one-page panel's Tools and the hub (UT-13 to UT-21)

    /// No managed or self-managed server yet: the folder pickers and Create Folders wait for one.
    private var serverNotInstalled: Bool { !model.status.installed && model.status.runtimeState != "managedInPlace" }
    /// set-workdir, set-operations-dir and set-context-dir restart the server through the drain lease, which closes
    /// admissions and waits up to 90 s; during a live meeting it times out and leaves the gate for Repair (QA delta
    /// 2026-10-28). So the folder pickers wait for running work, as the Apply rows do.
    private var folderPickBlocked: Bool { serverNotInstalled || serverWorkActive }
    private func folderHelp(_ help: String) -> String { serverWorkActive ? help + " " + SettingsHubCopy.chooseWaitsForWork : help }
    private var repairRuntimeBlocked: Bool {
        !model.status.installed || model.status.ownerConflict || model.status.runtimeState == "legacyForeground"
    }
    /// Repair Whisper is offered only for a managed, owned server whose Whisper is down or tripped.
    private var repairWhisperOffered: Bool {
        model.status.managedContract && model.status.ownershipVerified && (!model.status.whisperReady || model.status.whisperCircuitOpen)
    }
    private var pairingTokenBlocked: Bool { model.status.runtimeState != "managedHealthy" }
    private var workFolderHelp: String {
        model.status.installed || model.status.runtimeState == "managedInPlace"
            ? "The folder Claude, Codex and Cursor work in. Changing it restarts the server when no work is running."
            : "Install the server or choose Manage in place first"
    }
    private static let meetingsLibraryHelp = "Choose your meetings folder, or one that holds several. Changing it restarts the server when no work is running."
    private static let cosDataHelp = "Notes in memory/ or threads/, or a COS workspace. Changing it restarts the server when no work is running."
    private var createFoldersHelp: String {
        model.status.contextSuggestedRoot.map { "Creates memory/ and threads/ in \($0)" }
            ?? "Choose a work folder or meetings folder first"
    }
    /// UT-19: which tier reads the notes, and where.
    @ViewBuilder private var notesSourceLine: some View {
        if let path = model.status.contextScriptsDirectory {
            Text("Bridge: \(path)").font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        } else if let path = model.status.contextFilesDirectory {
            Text("Notes: \(path)").font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    // MARK: Server settings with Apply, shared by the one-page panel and the hub (UT-03 to UT-12)
    //
    // Each piece is one setting: its gate, its draft, its Apply and what blocks it are written once. `hub` picks only the
    // frame: the panel's switch with its words and the caption under it, or a hub row with the catalog's label and
    // description. Every one of these restarts the server when applied.

    /// Apply waits for an installed (or self-managed) server and for the panel not to be busy.
    private var serverSettingsLocked: Bool {
        model.busy || serverNotInstalled
    }
    /// Active jobs or recordings: machine-wide server settings wait for them.
    private var serverWorkActive: Bool {
        (model.status.activeJobs ?? 0) + (model.status.activeTranscriptionSessions ?? 0) > 0
    }

    /// A draft switch and its Apply. Panel: the switch with its own words, then the caption. Hub: the catalog row for
    /// `id`, its description ending with the restart line.
    @ViewBuilder private func applySwitch(_ hub: Bool, id: String, panel: String, caption: String, isOn: Binding<Bool>,
                                          applyBlocked: Bool, waitsForWork: Bool = false, apply: @escaping () -> Void) -> some View {
        if hub {
            // HUB-08: while running work holds Apply, the row says so.
            hubRow(id, detail: hubDetail(id) + " " + SettingsHubCopy.appliesRestart
                   + (waitsForWork && serverWorkActive ? " " + SettingsHubCopy.waitsForWork : "")) {
                HStack(spacing: 10) {
                    Toggle(isOn: isOn) { EmptyView() }
                        .toggleStyle(COSSwitchStyle())
                        .accessibilityLabel(hubLabel(id))
                    Button("Apply", action: apply).buttonStyle(TodayButtonStyle(small: true)).disabled(applyBlocked)
                }
            }
        } else {
            HStack(spacing: 8) {
                Toggle(panel, isOn: isOn)
                    .toggleStyle(COSSwitchStyle())
                Button("Apply", action: apply)
                    .disabled(applyBlocked)
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// UT-03: Balanced or Max, then Apply. Before server 6.21.0, the line that says to update the server.
    @ViewBuilder private func toolTranscriptionTier(hub: Bool) -> some View {
        if model.status.transcriptionRequestedTier != nil {
            let options = [COSViewOption("balanced", "Balanced"), COSViewOption("max", "Max")]
            let apply = { model.setTranscriptionTier(selectedTranscriptionTier) }
            if hub {
                hubRow("UT-03", detail: hubDetail("UT-03") + " " + SettingsHubCopy.appliesRestart) {
                    HStack(spacing: 10) {
                        COSViewSwitch(hubLabel("UT-03"), selection: $selectedTranscriptionTier, options: options, showsLabel: false)
                        Button("Apply", action: apply).buttonStyle(TodayButtonStyle(small: true)).disabled(serverSettingsLocked)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    COSViewSwitch("Quality tier", selection: $selectedTranscriptionTier,
                                  options: options, showsLabel: true)
                    Spacer(minLength: 0)
                    Button("Apply", action: apply)
                        .disabled(serverSettingsLocked)
                }
                Text("Balanced suits most Macs. Max uses much more memory. Applying restarts the server.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if model.status.installed || model.status.runtimeState == "managedInPlace" {
            let line = Label("Update the server to 6.21.0 or newer to change the tier.", systemImage: "arrow.down.circle")
                .font(.caption2)
                .foregroundStyle(COSPalette.amber)
            if hub { hubRow("UT-03") { line } } else { line }
        }
    }

    /// UT-04, machine-wide: waits for active work.
    @ViewBuilder private func toolBackgroundJobs(hub: Bool) -> some View {
        if model.status.backgroundJobsSupported {
            applySwitch(hub, id: "UT-04", panel: "Background jobs",
                        caption: "Replies keep running when the phone app closes. Applying restarts the server.",
                        isOn: $selectedBackgroundJobs, applyBlocked: serverSettingsLocked || serverWorkActive, waitsForWork: true) {
                model.setBackgroundJobsEnabled(selectedBackgroundJobs)
            }
        }
    }

    /// UT-05.
    @ViewBuilder private func toolMeetingPreview(hub: Bool) -> some View {
        if model.status.meetingPreviewSupported {
            applySwitch(hub, id: "UT-05", panel: "Fast preview",
                        caption: "Quick meeting text first, then the final transcript. Applying restarts the server.",
                        isOn: $selectedMeetingPreview, applyBlocked: serverSettingsLocked || serverWorkActive, waitsForWork: true) {
                model.setMeetingPreviewEnabled(selectedMeetingPreview)
            }
        }
    }

    /// UT-06. Privacy: it serves session names, workspaces and times over the local network.
    @ViewBuilder private func toolClaudeSessions(hub: Bool) -> some View {
        applySwitch(hub, id: "UT-06", panel: "Show AI sessions",
                    caption: "Shares session names, folders and times on your local network. Off on untrusted Wi-Fi. Applying restarts the server.",
                    isOn: $selectedClaudeSessions, applyBlocked: serverSettingsLocked) {
            model.setClaudeSessionsEnabled(selectedClaudeSessions)
        }
    }

    /// UT-07 (server 6.37).
    @ViewBuilder private func toolThreadAttach(hub: Bool) -> some View {
        if model.status.threadAttachSupported {
            applySwitch(hub, id: "UT-07", panel: "Continue sessions",
                        caption: "Replies go into your real Claude or Codex session. Applying restarts the server.",
                        isOn: $selectedThreadAttach, applyBlocked: serverSettingsLocked || serverWorkActive, waitsForWork: true) {
                model.setThreadAttachEnabled(selectedThreadAttach)
            }
        }
    }

    /// UT-08: Automatic or a pinned Ollama tag, then Apply.
    @ViewBuilder private func toolOllamaModel(hub: Bool) -> some View {
        if model.status.ollamaReady == true || model.status.ollamaConfiguredModel != nil || !model.ollamaTags.isEmpty {
            let blocked = serverSettingsLocked || selectedOllamaModel == (model.status.ollamaConfiguredModel ?? "")
            let apply = { model.setOllamaModel(selectedOllamaModel.isEmpty ? nil : selectedOllamaModel) }
            let note = model.ollamaTagsState == "daemon_down"
                 ? "Ollama is not running, so this list is out of date. A chosen model applies when it starts."
                 : "Newest changes when you pull a model. Pick one to keep it. Applying restarts the server."
            if hub {
                hubRow("UT-08", detail: (model.ollamaTagsState == "daemon_down" ? note : hubDetail("UT-08")) + " " + SettingsHubCopy.appliesRestart) {
                    HStack(spacing: 10) {
                        COSDropdown("Local model", selection: $selectedOllamaModel, options: ollamaModelOptions, showsLabel: false)
                            .frame(maxWidth: 240)
                        Button("Apply", action: apply).buttonStyle(TodayButtonStyle(small: true)).disabled(blocked)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    COSDropdown("Local model", selection: $selectedOllamaModel, options: ollamaModelOptions)
                    Button("Apply", action: apply)
                        .disabled(blocked)
                }
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// UT-09 and UT-10: Apply waits while an upload is in flight; Clear stranded appears while a draft is receiving.
    @ViewBuilder private func toolVideoUploads(hub: Bool) -> some View {
        if model.status.videoUploadV2Supported {
            let blocked = serverSettingsLocked || model.status.videoUploadV2Receiving + model.status.videoUploadV2Finalizing > 0
            let apply = { model.setVideoUploadV2Enabled(selectedVideoUploadV2) }
            if hub {
                hubRow("UT-09", detail: hubDetail("UT-09") + " " + SettingsHubCopy.appliesRestart) {
                    HStack(spacing: 10) {
                        Toggle(isOn: $selectedVideoUploadV2) { EmptyView() }
                            .toggleStyle(COSSwitchStyle())
                            .accessibilityLabel(hubLabel("UT-09"))
                        Button("Apply", action: apply).buttonStyle(TodayButtonStyle(small: true)).disabled(blocked)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Toggle("Reliable video uploads", isOn: $selectedVideoUploadV2)
                        .toggleStyle(COSSwitchStyle())
                    Button("Apply", action: apply)
                        .disabled(blocked)
                    if model.status.videoUploadV2Receiving > 0 {
                        Button("Clear stuck uploads") { confirmClearStrandedVideoUploads = true }
                            .disabled(model.busy)
                    }
                }
                Text("Beta. Sends videos in chunks that resume after a restart. Applying restarts the server.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// UT-11.
    @ViewBuilder private func toolIdleMetal(hub: Bool) -> some View {
        if model.status.idleMetalHqSupported {
            applySwitch(hub, id: "UT-11", panel: "GPU when idle",
                        caption: "Powerful Macs only. Final transcripts use the GPU when idle. Applying restarts the server.",
                        isOn: $selectedIdleMetalHq, applyBlocked: serverSettingsLocked || serverWorkActive, waitsForWork: true) {
                model.setIdleMetalHqEnabled(selectedIdleMetalHq)
            }
        }
    }

    /// UT-12.
    @ViewBuilder private func toolAudioCleanup(hub: Bool) -> some View {
        if model.status.adaptiveAudioCleanupSupported {
            applySwitch(hub, id: "UT-12", panel: "Playback cleanup",
                        caption: "Cleans audio when you press Play. The original stays as is. Applying restarts the server.",
                        isOn: $selectedAdaptiveAudioCleanup, applyBlocked: serverSettingsLocked || serverWorkActive, waitsForWork: true) {
                model.setAdaptiveAudioCleanupEnabled(selectedAdaptiveAudioCleanup)
            }
        }
    }

    /// Renders ONLY when the appcast advertises a genuinely newer build; offline,
    /// up-to-date, killSwitch and malformed all render nothing at all. Install
    /// downloads, SHA-checks, and swaps this app. The glasses server is not touched.
    /// A publisher notice from the appcast. Sits with the update banner at the top
    /// of the panel because that is where release-time news already lives, but it
    /// is NOT gated on an update being available: the person who most needs to
    /// read "you can now do X" is the one who just finished updating.
    ///
    /// Dismissal is per notice id, so a later notice still appears and this one
    /// never comes back.
    @ViewBuilder private var noticeBanner: some View {
        if let notice = model.visibleNotice, let id = notice.noticeId {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(COSPalette.gold)
                VStack(alignment: .leading, spacing: 3) {
                    Text(notice.noticeTitle ?? "")
                        .font(.caption.weight(.semibold))
                    Text(notice.noticeBody ?? "")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    model.dismissNotice(id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
                .help("Dismiss")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.gold.opacity(0.45), lineWidth: 1))
        }
    }

    /// Renders ONLY while appUpdateFlow has something to say: ready, staging, applying, failed. Update (and Try again)
    /// open the What's New window (2026-10-09; it replaced the small "Install COS Control X?" alert). Its Download and
    /// install is the confirmation, and runs installAppUpdate, the existing stage then apply path.
    @ViewBuilder private var updateBanner: some View {
        if model.appUpdateFlow.showsBanner {
            AppUpdateBanner(flow: model.appUpdateFlow, disabled: model.busy) {
                // 0.5.322: a build already downloaded and checked installs in one click; any other offer opens What's New.
                if model.appUpdateFlow.finishesStaged { model.finishStagedAppUpdate() } else { model.presentWhatsNew() }
            }
        }
    }

    private var footer: some View {
        // CHIPS, NOT LINKS. These were `.buttonStyle(.link)` at mono(10) with a
        // secondary foreground and no spacing, in a panel where every other
        // action is a bordered chip with an SF Symbol. The two read as one
        // run-on string -- "Check for updates Quit" -- with no affordance and
        // nothing separating a harmless action from one that kills the app.
        //
        // The label keeps its own line. The panel is a fixed 390pt (see :143)
        // and footerLabel already wraps to two lines, so chips on the same row
        // would squeeze it further; a VStack gives both their full width.
        VStack(alignment: .leading, spacing: 8) {
            Text(footerLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Spacer()
                // ASK FOR AN UPDATE with the header's refresh button (2026-10-09;
                // the version card is gone). The automatic check runs at launch
                // and every 6 hours, so a long-running Control can sit two builds
                // behind with no banner and no way to ask (2026-08-24): the ask
                // still exists, at the top of the panel, not here.
                Button("Quit", systemImage: "power") { AppQuit.request() }
                    .buttonStyle(COSQuietButtonStyle())
            }
        }.font(COSType.mono(10)).foregroundStyle(.secondary)
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

    private var cursorLabel: String {
        switch model.status.cursorState {
        case "connected": "Connected"
        case "signInRequired": "Sign-in required"
        case "notInstalled": "Not installed"
        default: "Unavailable"
        }
    }

    private func selectedEngineLabel(_ selected: String?, effective: String?) -> String {
        let title = VoiceFacts.engineTitle(selected)
        return selected != nil && selected == effective ? title : "\(title) · unavailable"
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
        case "large_v3_model_missing": return "Large-v3 is missing; live commit safely fell back to Turbo. Run guided setup, then Apply Max again."
        case "turbo_model_missing": return "Turbo fallback weights are missing. Run guided setup before changing tiers."
        default: return "The requested tier could not be activated; the safe fallback remains in use."
        }
    }

    private var meetingWorkBlockCaption: String {
        if model.status.meetingFinalizationPending > 0 {
            return "Blocks Update / Restart until the meeting is in the library."
        }
        if (model.status.activeTranscriptionSessions ?? 0) > 0, !model.status.meetingSyncActive {
            return "Blocks Update / Restart until this recording is saved."
        }
        if model.status.meetingSyncBlocksRestart {
            return "Blocks Update / Restart until meeting work finishes."
        }
        return "Meeting work in progress."
    }

    private var unsavedCapturesLabel: String {
        let recoverable = model.recoverableOrphans.count
        if recoverable > 0 { return "\(recoverable) recoverable" }
        if model.status.unsavedCaptures > 0 { return "\(model.status.unsavedCaptures) recoverable" }
        if !model.strandedCaptures.isEmpty { return "\(model.strandedCaptures.count) retained" }
        return "None"
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

    /// The hub's line for a folder in use: its path on the right, in mono, with a count under it.
    private func hubPathRow(_ path: String, line: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("In use").font(COSType.body(14.5, weight: .semibold)).foregroundStyle(TodayInk.ink)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(path).font(COSType.mono(12)).foregroundStyle(TodayInk.sub)
                    .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.trailing).textSelection(.enabled)
                if let line { Text(line).font(COSType.body(12.5)).foregroundStyle(TodayInk.grey) }
            }
        }
    }

    /// Status lines the hub draws right under the switch of the same name.
    private static let hubStatusUnderSwitch: Set<String> = ["Background jobs", "Fast preview", "Continue sessions", "GPU when idle", "Playback cleanup"]

    /// One status line. In the hub the same line in the hub's type: the label as a row label, the value and its dot on
    /// the right.
    @ViewBuilder private func statusRow(_ label: String, value: String, good: Bool) -> some View {
        if hubOn {
            HStack(alignment: .center, spacing: 16) {
                // A status line under its own switch reads "Status": the switch row above already says what it is.
                Text(Self.hubStatusUnderSwitch.contains(label) ? "Status" : label)
                    .font(COSType.body(14.5, weight: .semibold)).foregroundStyle(TodayInk.ink)
                Spacer(minLength: 8)
                SettingsHubValue(text: value, good: good)
            }
        } else {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Circle().fill(good ? COSPalette.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
                Text(value).fontWeight(.medium)
            }.font(COSType.body(13))
        }
    }
}

// MARK: - Settings hub: the composition (Miles, 2026-10-27, design/settings-hub)
//
// Every card below is built from ControlPanel's own pieces (the status card's rows, the server controls, the Tools
// settings, the cards and the shared views), each mounted once, in the place docs/settings-hub/SETTINGS_INVENTORY.md
// section 3 gives it. Drafts, confirmations, seeds and observations stay at ControlPanel's root for both layouts; the
// loaders mainPanel's always-drawn views ran sit at the hub's root (hubLoaders), so they run whichever category is open.

private extension ControlPanel {
    static let hubSpace = "settings-hub-page"

    var hubSearching: Bool { !hubQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func settingsHub(_ host: SettingsHubHost) -> some View {
        hubLoaders(
            GeometryReader { geometry in
                let mode = SettingsHubLayout.mode(width: geometry.size.width)
                HStack(spacing: 0) {
                    SettingsHubFactsReader(model: model, permissions: model.permissionGuide, dictation: model.dictation,
                                           cues: model.meetingAsk.liveCues, stt: model.transcriptionSettings, setup: model.setupGuide) { facts in
                        SettingsHubSidebar(mode: mode, backTitle: host.backTitle, back: host.back, backShortcut: host.backShortcut, query: $hubQuery,
                                           searchFocused: $hubSearchFocused, selected: hubSearching ? nil : hubCategory,
                                           status: { SettingsHubStatus.line($0, facts) }, select: hubSelect)
                    }
                    hubPage(mode: mode)
                }
            }
            .background(TodayInk.page)
            .background {
                // ⌘F: the search field, from anywhere in Settings.
                Button("") { hubSearchFocused = true }
                    .keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
        )
    }

    func hubSelect(_ category: SettingsHubCategory) {
        hubQuery = ""
        hubSearchFocused = false
        hubCategory = category
    }

    // MARK: Loaders

    /// What mainPanel's always-drawn views loaded on their own, hoisted so it runs whichever category is open.
    func hubLoaders<Content: View>(_ content: Content) -> some View {
        content
            // workExpirySettings (WK-01).
            .task { await model.loadWorkExpiry() }
            // sessionPetSettings (PT-09's catalogue).
            .task { await model.loadOpenPetsCatalog() }
            // MeetingAskSettings (MA-01 to MA-05).
            .task { await model.meetingAsk.refreshConfig(model: model); await model.meetingAsk.homeArea.load(HomeCitySettings.run(model)) }
            // mainPanel's mount of MeetingAskSettings loads Transcription, which is hidden until the server answers.
            .task { await model.transcriptionSettings.load(TranscriptionSettingsCard.run(model)) }
            // Your own key's state, read once for every page: it feeds Continue and Fork's guard (keyedSessionIds).
            .settingsHubOwnKeyReader(model)
            // LiveCuesSettingsRow (MA-06), and Meetings' status line.
            .task(id: "\(model.status.running) \(model.status.version ?? "")") { await model.meetingAsk.liveCues.load(LiveCuesSettingsRow.run(model)) }
            // morningBriefCard (MB-01 to MB-09).
            .task(id: model.status.morningBriefSupported) { if model.status.morningBriefSupported { await model.loadMorningBrief(quiet: true) } }
            .onChange(of: model.morningBrief?.updatedAt) { _, stamp in syncMorningBriefDraft(force: stamp != briefDraftStamp) }
            .onAppear { syncMorningBriefDraft(force: briefDraft == nil) }
            // domainsCard (DM-01 to DM-03).
            .task(id: model.status.tasksGate != nil) {
                guard model.status.tasksGate != nil else { return }
                await model.loadDomains()
                syncDomainsDraft(force: false)
            }
            // PanelConnectAIRow's one read for its summary.
            .task { if model.providerGuide.report == nil { await model.providerGuide.refresh() } }
            // PanelPermissionsRow's read and its re-read on return from System Settings.
            .task { await model.permissionGuide.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.permissionGuide.refresh() }
            }
            // The Show live meeting transcript switch's observation (MT-01).
            .onChange(of: showLiveTranscript) { _, _ in model.liveTranscriptSettingChanged() }
            // SetupGuideView's, for the Voice row drawn on its own (SG-05).
            .onAppear { voiceGuide.adoptServerTier(voiceGuide.voice?.explicitTier) }
            .onChange(of: voiceGuide.voice?.explicitTier) { _, tier in voiceGuide.adoptServerTier(tier) }
            // Opening a category loads what its views read on opening in the panel (Decision models' disclosure).
            .task(id: hubCategory) { await hubCategoryOpened(hubCategory) }
            .onDisappear { subQKeyDraft = ""; jevKeyDraft = ""; model.settingsHubEscape = nil }
            .onAppear { model.settingsHubEscape = { hubEscape() } }
    }

    /// Escape in the hub: a search is cleared first, then an open inline confirm closes; only then does Activity leave
    /// Settings (ActivityWindow.handleActivityEscape asks here first).
    func hubEscape() -> Bool {
        // A query of spaces is no search (hubSearching trims), so Escape clears it on the way and goes on.
        if hubSearching { hubQuery = ""; hubSearchFocused = false; return true }
        hubQuery = ""
        if confirmHubRollback { confirmHubRollback = false; return true }
        return false
    }

    func hubCategoryOpened(_ category: SettingsHubCategory) async {
        // An inline confirm belongs to the page it was opened on (QA 2026-10-28): leaving the page cancels it.
        confirmHubRollback = false
        // A plain Settings… opens here next time (the fixture's renders never write it).
        if model.backgroundWorkEnabled { UserDefaults.standard.set(category.rawValue, forKey: SettingsHub.lastCategoryKey) }
        // Leaving AI and accounts, for any page, drops a typed key, as closing Decision models does (QA N2: Meetings
        // used to keep it).
        if category != .ai { subQKeyDraft = ""; jevKeyDraft = "" }
        switch category {
        case .ai:
            // As opening Decision models in the panel does.
            await model.loadDecisionSettings(); await model.loadJevStatus(); await model.loadSubQKeyStatus()
        case .meetings:
            // Fireflies' key line (OUT-01), read as the Import pane reads it.
            await model.loadFirefliesKey()
        default:
            break
        }
    }

    // MARK: The page

    func hubPage(mode: SettingsHubLayout.Mode) -> some View {
        let pad = SettingsHubLayout.pagePadding(mode)
        return ScrollViewReader { reader in
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                // Narrow: the search field sits above the page, outside the ScrollView whose identity changes when a search
                // starts, so the first keystroke keeps its focus (QA 2026-10-28).
                if mode == .narrow {
                    SettingsHubSearchField(query: $hubQuery, focused: $hubSearchFocused)
                        .frame(maxWidth: SettingsHubLayout.pageMaxWidth)
                        .padding(EdgeInsets(top: 24, leading: pad, bottom: 0, trailing: pad))
                }
                GeometryReader { viewport in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 26) {
                            hubTopStrip(reader)
                            if hubSearching {
                                SettingsHubSearchResults(query: hubQuery, sections: SettingsHubSearch.results(hubQuery, shown: hubGroupShown)) { hubOpen($0, reader) }
                            } else {
                                SettingsHubPageHeader(title: hubCategory.title, line: hubCategory.blurb, busy: model.busy)
                                hubCategoryContent(hubCategory)
                            }
                        }
                        .padding(EdgeInsets(top: 40, leading: pad, bottom: 72, trailing: pad))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Hosted sub-views drop their own cards and titles and use the hub's row grammar.
                        .environment(\.settingsHubHosted, true)
                        .background(GeometryReader { content in
                            Color.clear.onChange(of: content.frame(in: .named(Self.hubSpace)), initial: true) { _, frame in
                                hubSpy.content(top: frame.minY, bottom: frame.maxY)
                            }
                        })
                    }
                    .coordinateSpace(name: Self.hubSpace)
                    // A new category or search starts at its top.
                    .id(hubSearching ? "search" : hubCategory.rawValue)
                    .onChange(of: viewport.size.height, initial: true) { _, height in hubSpy.viewport(height) }
                }
                }
                if SettingsHubLayout.showsRail(mode) && !hubSearching {
                    SettingsHubObserving(model.transcriptionSettings) { _ in
                      SettingsHubObserving(model.dictation) { _ in
                        SettingsHubOwnKeyObserving {
                            let groups = hubVisibleGroups(hubCategory)
                            SettingsHubSpyRail(spy: hubSpy, groups: groups) { group in hubScroll(reader, to: group.anchor) }
                                .onAppear { hubSpy.page(groups.map(\.id)) }
                                .onChange(of: groups.map(\.id)) { _, ids in hubSpy.page(ids) }
                        }
                      }
                    }
                    .padding(EdgeInsets(top: 112, leading: 0, bottom: 0, trailing: 20))
                    .frame(width: SettingsHubLayout.railWidth, alignment: .leading)
                }
            }
            // The openers (model.settingsHubTarget from SettingsOpener, model.panelScrollTarget from in-page buttons) land
            // on their category and group, Advanced opened if inside.
            .onAppear { hubFollowTarget(reader) }
            .onChange(of: model.panelScrollTarget) { _, _ in hubFollowTarget(reader) }
            .onChange(of: model.settingsHubTarget) { _, _ in hubFollowTarget(reader) }
        }
    }

    func hubScroll(_ reader: ScrollViewProxy, to anchor: String) {
        withAnimation(Motion.gated(.easeInOut(duration: 0.25), reduceMotion: reduceMotion)) { reader.scrollTo(anchor, anchor: .top) }
    }

    func hubFollowTarget(_ reader: ScrollViewProxy) {
        guard let target = model.settingsHubTarget ?? model.panelScrollTarget else { return }
        let fromOpener = model.settingsHubTarget != nil
        let destination = SettingsHubRoute.destination(target)
        if let destination {
            hubQuery = ""
            hubCategory = destination.category
            if destination.opensAdvanced { hubAdvanced.insert(destination.group) }
        }
        // After the page for the new category has drawn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if let destination { reader.scrollTo(destination.anchor, anchor: .top) }
            if fromOpener { model.settingsHubTarget = nil } else { model.panelScrollTarget = nil }
        }
    }

    /// A search result: its category, its group, and Advanced when the row sits there.
    func hubOpen(_ item: SettingsHubItem, _ reader: ScrollViewProxy) {
        guard let destination = SettingsHubRoute.destination(item.id) else { return }
        hubQuery = ""
        hubSearchFocused = false
        hubCategory = destination.category
        if destination.opensAdvanced { hubAdvanced.insert(destination.group) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            reader.scrollTo(destination.anchor, anchor: .top)
            reader.scrollTo("item." + item.id, anchor: .center)
        }
    }

    /// Above every category: an update that is ready first (2026-10-09), then the recording, the Dock notice, Finish
    /// setup, the publisher's notice and Get started, as at the top of the panel.
    func hubTopStrip(_ reader: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            updateBanner
            // C-09's progress and ownership conflict (QA 2026-10-28 S5): an Apply anywhere restarts the server, so what
            // it is doing shows on every page. The green notice stays on System (other actions write it too).
            if model.status.ownerConflict || model.operationProgress != nil {
                VStack(alignment: .leading, spacing: 6) { serverProgressMessages }
                    .font(COSType.body(13))
                    .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(TodayInk.panel))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(TodayInk.panelBorder, lineWidth: 1))
            }
            if model.recordingCount > 0 { recordingCard }
            DockNoticeLine(model: model)
            FinishSetupCard(model: model, provider: model.providerGuide, guide: model.setupGuide, permissions: model.permissionGuide) {
                model.providerGuide.openInPanel()
                hubSelect(.general)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { reader.scrollTo(SettingsHub.anchor("general.guide"), anchor: .top) }
            }
            noticeBanner
            if model.status.needsFirstRun {
                Button("Get started with COS") { model.openSetup?() }
                    .buttonStyle(COSPrimaryButtonStyle())
            }
        }
        .frame(maxWidth: SettingsHubLayout.pageMaxWidth, alignment: .leading)
    }

    // MARK: Building blocks

    func hubLabel(_ id: String) -> String { SettingsHubCatalog.item(id)?.label ?? id }
    func hubDetail(_ id: String) -> String { SettingsHubCatalog.item(id)?.detail ?? "" }
    /// A folder picker's row: what it is, that changing it restarts the server, and why Choose is off while work runs.
    func hubFolderDetail(_ id: String) -> String {
        hubDetail(id) + " " + SettingsHubCopy.chooseRestarts + (serverWorkActive ? " " + SettingsHubCopy.chooseWaitsForWork : "")
    }

    /// A row in the catalog's words for `id`.
    func hubRow<Control: View>(_ id: String, label: String? = nil, detail: String? = nil, @ViewBuilder _ control: () -> Control) -> some View {
        let item = SettingsHubCatalog.item(id)
        return SettingsHubRow(label: label ?? item?.label ?? id, detail: detail ?? item?.detail ?? "",
                              advanced: item?.advanced ?? false, anchor: "item." + id, control: control)
    }

    func hubSwitch(_ id: String, isOn: Binding<Bool>, detail: String? = nil) -> some View {
        hubRow(id, detail: detail) {
            Toggle(isOn: isOn) { EmptyView() }
                .toggleStyle(COSSwitchStyle())
                .accessibilityLabel(hubLabel(id))
        }
    }

    func hubButton(_ id: String, _ title: String, detail: String? = nil, action: @escaping () -> Void) -> some View {
        hubRow(id, detail: detail) { Button(title, action: action).buttonStyle(TodayButtonStyle(small: true)) }
    }

    func hubCard<Content: View, Advanced: View>(_ id: String, advanced count: Int, forceOpen: Bool = false,
                                                 @ViewBuilder _ content: () -> Content,
                                                 @ViewBuilder advanced: () -> Advanced) -> some View {
        SettingsHubCard(group: SettingsHubCatalog.group(id) ?? SettingsHubGroup(id: id, category: hubCategory, title: id), advancedCount: count,
                        advancedOpen: Binding(get: { forceOpen || hubAdvanced.contains(id) },
                                              set: { open in if open { hubAdvanced.insert(id) } else { hubAdvanced.remove(id) } }),
                        content: content, advanced: advanced)
            .settingsHubSpyTop(id, space: Self.hubSpace, spy: hubSpy)
    }

    func hubAdvancedBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { hubAdvanced.contains(id) }, set: { open in if open { hubAdvanced.insert(id) } else { hubAdvanced.remove(id) } })
    }

    func hubCard<Content: View>(_ id: String, @ViewBuilder _ content: () -> Content) -> some View {
        hubCard(id, advanced: 0, content, advanced: { EmptyView() })
    }

    /// The groups a category draws now (a card on an older server, or with nothing to show, is left out), for On this
    /// page. The same tests gate each card in hubCategoryContent.
    func hubVisibleGroups(_ category: SettingsHubCategory) -> [SettingsHubGroup] {
        SettingsHubCatalog.groups(in: category).filter { hubGroupShown($0.id) }
    }

    func hubGroupShown(_ id: String) -> Bool {
        switch id {
        case "ai.keys": return SettingsHubOwnKeyCard.shown(model)
        case "glasses.video": return model.status.videoUploadV2Supported
        case "dictation.engine": return voiceGuide.voice?.dictationSelected != nil
        case "dictation.microphone", "dictation.shortcuts", "dictation.sounds", "dictation.text", "dictation.polish": return model.dictation.enabled
        case "voice.models": return model.transcriptionSettings.visible
        case "voice.performance":
            return model.status.idleMetalHqSupported || model.status.adaptiveAudioCleanupSupported || model.status.progressiveHqEnabled != nil
        case "work.background": return model.status.backgroundJobsSupported
        case "work.brief": return model.status.morningBriefSupported
        case "work.domains": return model.status.tasksGate != nil
        case "work.fences": return !model.fenceRecords.isEmpty
        case "pet.characters": return model.petEnabled
        default: return true
        }
    }

    @ViewBuilder func hubCategoryContent(_ category: SettingsHubCategory) -> some View {
        switch category {
        case .general: hubGeneral
        case .ai: hubAI
        case .glasses: hubGlasses
        case .meetings: hubMeetings
        case .dictation: hubDictation
        case .voice: hubVoice
        case .work: hubWork
        case .privacy: hubPrivacy
        case .pet: hubPet
        case .system: hubSystem
        }
    }

    // MARK: General

    @ViewBuilder var hubGeneral: some View {
        hubCard("general.app", advanced: hubAdvancedCount("general.app")) {
            // Launch at login, menu bar only, the shortcut and the clock came from Tools, which is off while busy.
            Group {
                hubSwitch("G-01", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                hubSwitch("G-02", isOn: Binding(get: { !model.showInDock }, set: { model.setShowInDock(!$0) }))
                hubRow("G-03") { HotKeyRecorderRow(model: model, showsLabel: false).buttonStyle(TodayButtonStyle(small: true)) }
                hubRow("UT-25") {
                    COSDropdown(hubLabel("UT-25"), selection: Binding(get: { model.clockStyle }, set: { model.setClockStyle($0) }),
                                options: ClockStyle.allCases.map { COSDropdownOption($0, $0.label) }, showsLabel: false)
                        .frame(width: 200)
                }
            }
            .disabled(model.busy)
        } advanced: {
            // The rollback: Activity draws the one-page Settings again. Never locked while busy.
            hubSwitch("HUB-CL", isOn: $useClassicSettings)
        }
        hubCard("general.home") {
            Group {
                hubSwitch("WK-06", isOn: $todayHomeEnabled)
                // O-11: shown while Today is off, locked, with the reason (the panel hides them).
                hubSwitch("WK-07", isOn: $todayQuietHours, detail: todayHomeEnabled ? nil : hubDetail("WK-07") + " " + SettingsHubCopy.todayFirst)
                    .disabled(!todayHomeEnabled)
                hubSwitch("WK-08", isOn: $todayWorkRuns, detail: todayHomeEnabled ? nil : hubDetail("WK-08") + " " + SettingsHubCopy.todayFirst)
                    .disabled(!todayHomeEnabled)
            }
            .disabled(model.busy)
        }
        hubCard("general.guide") {
            // SG-01, which opens the whole guide in place (SG-02 to SG-14 inside it).
            SettingsHubBlock { PanelConnectAIRow(guide: model.providerGuide, model: model) }
        }
    }

    // MARK: AI and accounts

    @ViewBuilder var hubAI: some View {
        hubCard("ai.apps") {
            // SG-03: the same rows as the guide's Your AI, polling only while this card is on screen.
            SettingsHubBlock { ProviderConnectList(guide: model.providerGuide, includeOllama: false).providerPolling(model.providerGuide) }
            SettingsHubBlock { statusAgentRows; statusCursorRow }
            hubButton("UT-20", "Open Cursor") { model.openCursor() }.disabled(model.busy)
        }
        hubCard("ai.local") {
            SettingsHubBlock { SettingsHubSetupRow(model: model, provider: model.providerGuide, guide: model.setupGuide, id: .ollama) }
            if model.status.ollamaReady == true, let name = model.status.ollamaModel, !name.isEmpty {
                SettingsHubBlock { statusOllamaRow }
            }
            toolOllamaModel(hub: true).disabled(model.busy)
        }
        hubCard("ai.decision", advanced: hubAdvancedCount("ai.decision")) {
            // Decision models came from Tools, which is off while busy.
            Group {
                hubRow("JV-01", label: "Provider in use") { SettingsHubValue(text: model.decisionSettings?.provider.title ?? "Checking…") }
                SettingsHubBlock { decisionDefaultControls }
                SettingsHubBlock { jevKeyControls }
                SettingsHubBlock { subQKeyControls; decisionMessageLine }
            }
            .disabled(model.busy)
        } advanced: {
            Group {
                if model.decisionSettings != nil { SettingsHubBlock(advanced: true) { decisionWorkflowControls } }
                SettingsHubBlock(advanced: true) { decisionRefreshButton }
                SettingsHubBlock(advanced: true) { subQRetentionNote }
            }
            .disabled(model.busy)
        }
        // Your own key and Search are cards of their own (SettingsHubViews.swift), so the panel's file keeps its one
        // own-key hook and no token-spending search switch.
        SettingsHubOwnKeyCard(model: model, spy: hubSpy, space: Self.hubSpace, advancedOpen: hubAdvancedBinding("ai.keys"))
        hubCard("ai.search") { SettingsHubSemanticSearchRow(model: model) }
    }

    // MARK: Glasses and iPhone

    @ViewBuilder var hubGlasses: some View {
        hubCard("glasses.devices", advanced: hubAdvancedCount("glasses.devices")) {
            SettingsHubBlock { SetupDeviceChoice(guide: model.setupGuide) }
            if voiceGuide.devicePath == .glasses {
                SettingsHubBlock {
                    GlassesSetupRows(model: model, pairing: model.glassesPairing, openURL: { _ = model.providerGuide.openURL($0) })
                }
                hubButton("SG-13", "Get the app") { _ = model.providerGuide.openURL(GuideExtras.glassesWizardURL) }
            }
        } advanced: {
            hubRow("UT-21") {
                Button("Copy token") { model.perform("token") }.buttonStyle(TodayButtonStyle(small: true)).disabled(pairingTokenBlocked)
            }
            .disabled(model.busy)
            // O-10: Reset live message count, which the panel keeps in its header, reachable in every host.
            hubRow("H-04") {
                Button("Reset count…") { confirmResetMessageCount = true }.buttonStyle(TodayButtonStyle(small: true)).disabled(model.busy)
            }
        }
        if hubGroupShown("glasses.video") {
            hubCard("glasses.video", advanced: hubAdvancedCount("glasses.video")) {
                if model.status.videoUploadV2Enabled != nil { SettingsHubBlock { statusVideoRows(clearButton: false) } }
                // A stuck upload blocks Repair, so its warning and Clear stay on the card, not under Advanced (QA S6).
                if model.status.videoUploadV2Receiving > 0 {
                    hubRow("UT-10", detail: "A stopped upload can wait here for 4 hours and block Repair.") {
                        Button("Clear stuck uploads") { confirmClearStrandedVideoUploads = true }
                            .buttonStyle(TodayButtonStyle(small: true))
                            .disabled(model.busy)
                    }
                }
            } advanced: {
                toolVideoUploads(hub: true).disabled(model.busy)
            }
        }
    }

    // MARK: Meetings

    @ViewBuilder var hubMeetings: some View {
        hubCard("meetings.recording") {
            Group {
                hubSwitch("MT-01", isOn: $showLiveTranscript)
                MeetingSuggestSettings(store: MeetingDetectorStore.shared, recording: model.macRecording)
            }
            .disabled(model.busy)
            if !model.meetingAudio.isEmpty {
                SettingsHubBlock { statusMeetingAudioRows; statusMeetingAlertsRow }
            }
        }
        hubCard("meetings.assistant") {
            MeetingAskSettings(store: model.meetingAsk, model: model, part: .assistant)
        }
        hubCard("meetings.cues") {
            MeetingAskSettings(store: model.meetingAsk, model: model, part: .liveCues)
        }
        hubCard("meetings.library", advanced: hubAdvancedCount("meetings.library")) {
            hubRow("UT-16", detail: hubFolderDetail("UT-16")) {
                Button("Choose…") { model.selectOperationsFolder() }
                    .buttonStyle(TodayButtonStyle(small: true))
                    .disabled(folderPickBlocked)
                    .help(folderHelp(Self.meetingsLibraryHelp))
            }
            .disabled(model.busy)
            SettingsHubBlock { statusLibraryRows }
            SettingsHubBlock { statusMeetingSyncRows }
            if model.status.meetingFinalizationPending > 0 || model.status.meetingFinalizationMalformed > 0 {
                SettingsHubBlock { statusFinalizationRows }
            }
            if model.status.unsavedCaptures > 0 || !model.recoverableOrphans.isEmpty || !model.strandedCaptures.isEmpty {
                SettingsHubBlock { statusRetainedCaptureRows }
            }
        } advanced: {
            if model.status.earlyMeetingSyncEnabled != nil {
                SettingsHubBlock(advanced: true) { statusEarlySyncRows }
            } else {
                hubRow("ST-18") { SettingsHubValue(text: "Not reported") }
            }
            toolMeetingPreview(hub: true).disabled(model.busy)
            if model.status.meetingPreviewSupported, model.status.meetingPreviewEnabled != nil {
                SettingsHubBlock(advanced: true) { statusMeetingPreviewRow }
            }
        }
        hubCard("meetings.fireflies") {
            // OUT-01 to OUT-03 live in Activity › Meetings › Import; these rows open it.
            hubRow("OUT-01") {
                HStack(spacing: 12) {
                    SettingsHubValue(text: model.firefliesKey.summary, good: model.firefliesKey.configured ? !model.firefliesKey.needsNewKey : nil)
                    Button("Manage") { hubOpenImport() }.buttonStyle(TodayButtonStyle(small: true))
                }
            }
            hubButton("OUT-02", "Import…") { hubOpenImport() }
            hubButton("OUT-03", "Open") { hubOpenImport() }
        }
    }

    func hubOpenImport() {
        openActivity(.meetings)
        model.openMeetingImport()
    }

    // MARK: Dictation

    @ViewBuilder var hubDictation: some View {
        // D-05: one category for every dictation setting. Each group draws one section of MacDictationSettings (each
        // control still written once there), and it came from Tools, which is off while busy.
        hubCard("dictation.dictation") {
            dictationSection(.dictation)
            if hubGroupShown("dictation.engine") {
                SettingsHubBlock { DictationEngineControls(model: model, guide: model.setupGuide, store: model.transcriptionSettings) }
            }
        }
        SettingsHubObserving(model.dictation) { dictation in
            if dictation.enabled {
                ForEach([DictationSettingsSection.microphone, .shortcuts, .sounds, .text, .polish], id: \.self) { section in
                    hubCard("dictation." + section.rawValue) { dictationSection(section) }
                }
            }
        }
        hubCard("dictation.history") {
            dictationSection(.history)
            // DI-35: the Dictation tab keeps the dictionary and the history (and these settings, behind its Settings).
            HStack(spacing: 6) {
                Text(hubDetail("DI-35")).font(COSType.body(13)).foregroundStyle(TodayInk.sub)
                Button("Open Dictation") { openActivity(.dictation) }.buttonStyle(TodayLinkStyle(size: 13))
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 12, leading: 20, bottom: 14, trailing: 20))
            .overlay(alignment: .top) { SettingsHubHairline() }
            .id("item.DI-35")
        }
    }

    func dictationSection(_ section: DictationSettingsSection) -> some View {
        MacDictationSettings(store: model.dictation, activityShortcut: model.activityHotKey, section: section)
            .disabled(model.busy)
    }

    // MARK: Transcription and voice

    @ViewBuilder var hubVoice: some View {
        if model.status.speakerIdNeedsSetup {
            // O-01, from the Review speakers card no view mounts.
            speakerModelWarning.frame(maxWidth: SettingsHubLayout.pageMaxWidth, alignment: .leading)
        }
        let modelRows = hubModelRowsShown
        hubCard("voice.setup", advanced: hubAdvancedCount("voice.setup")) {
            SettingsHubBlock { SettingsHubSetupRow(model: model, provider: model.providerGuide, guide: model.setupGuide, id: .voice) }
            toolTranscriptionTier(hub: true).disabled(model.busy)
            SettingsHubBlock { statusVoiceRows; statusWhisperErrorLine }
            if repairWhisperOffered {
                hubButton("UT-14", "Repair Whisper") { model.perform("restart-whisper") }.disabled(model.busy)
            }
        } advanced: {
            hubButton("UT-02", "Guided setup…") { showGuidedSetupTier = true }.disabled(model.busy)
            if modelRows { SettingsHubBlock(advanced: true) { statusTranscriptionModelRows } }
        }
        SettingsHubObserving(model.transcriptionSettings) { store in
            if store.visible {
                // Its own Advanced (Front end, Quiet detection), opened when a deep link or search lands inside it.
                let open = hubAdvanced.contains("voice.models")
                hubCard("voice.models") {
                    TranscriptionSettingsCard(store: store, model: model, advancedOpen: open).id(open)
                }
            }
        }
        if hubGroupShown("voice.performance") {
            // The two switches and their status lines are the card; only the server-set HQ prefill line is Advanced,
            // so the card never opens on an empty body with everything folded away.
            hubCard("voice.performance", advanced: hubAdvancedCount("voice.performance")) {
                Group {
                    toolIdleMetal(hub: true)
                    if model.status.idleMetalHqSupported, model.status.idleMetalHqEnabled != nil {
                        SettingsHubBlock { statusIdleMetalRow }
                    }
                    toolAudioCleanup(hub: true)
                    if model.status.adaptiveAudioCleanupSupported, model.status.adaptiveAudioCleanupEnabled != nil {
                        SettingsHubBlock { statusAudioCleanupRow }
                    }
                }
                .disabled(model.busy)
            } advanced: {
                if model.status.progressiveHqEnabled != nil, model.status.progressiveHqValue != nil {
                    SettingsHubBlock(advanced: true) { statusHqPrefillRows }
                }
            }
        }
    }

    /// The count beside a card's Advanced: the catalog's Advanced rows in that group the page draws now (QA 2026-10-28
    /// N3), never a typed number. hubAdvancedShown answers for the rows drawn only sometimes, by the same tests the
    /// cards use; every other Advanced row always draws.
    func hubAdvancedCount(_ group: String) -> Int {
        SettingsHubCatalog.items(inGroup: group).filter { $0.advanced && hubAdvancedShown($0.id) }.count
    }

    func hubAdvancedShown(_ id: String) -> Bool {
        switch id {
        case "JV-03", "JV-04", "JV-05": return model.decisionSettings != nil
        case "UT-05": return model.status.meetingPreviewSupported
        case "ST-08": return model.status.meetingPreviewSupported && model.status.meetingPreviewEnabled != nil
        case "ST-13": return hubModelRowsShown
        case "ST-19": return model.status.progressiveHqEnabled != nil && model.status.progressiveHqValue != nil
        // The pet's Advanced is its sprites, which wait for the pet; Use COS figure only with sprites of your own.
        case "PT-08", "PT-11", "PT-12": return model.petEnabled
        case "PT-13": return model.petEnabled && model.petSpriteKit.hasAnyCustom
        // The older server's row (C-06: Adopt, or "Not needed"), or Manage in place and Replace for a running one.
        case "C-06": return model.status.runtimeState != "legacyService"
        case "C-07", "C-08": return model.status.runtimeState == "legacyService"
        default: return true
        }
    }

    /// The tier's model rows (ST-13): not for Parakeet, and only once the server names a model.
    var hubModelRowsShown: Bool {
        voiceGuide.voice?.usesParakeet != true
            && (model.status.livePreviewModel != nil || model.status.liveCommitModel != nil || model.status.hqPolishModel != nil)
    }

    // MARK: Work and agents

    @ViewBuilder var hubWork: some View {
        hubCard("work.sessions") {
            Group {
                toolClaudeSessions(hub: true)
                toolThreadAttach(hub: true)
            }
            .disabled(model.busy)
            if model.status.threadAttachSupported, model.status.threadAttachEnabled != nil {
                SettingsHubBlock { statusContinueRow }
            }
            Group {
                hubSwitch("WK-03", isOn: Binding(get: { model.workOpensTabs }, set: { model.workOpensTabs = $0 }))
                hubSwitch("WK-02", isOn: Binding(get: { model.workNotificationsEnabled }, set: { model.workNotificationsEnabled = $0 }))
            }
            .disabled(model.busy)
            hubRow("OUT-04") { SettingsHubUsageSwitch(store: model.sessionUsage, label: hubLabel("OUT-04")) }
        }
        hubCard("work.chat", advanced: hubAdvancedCount("work.chat")) {
            Group {
                hubSwitch("WK-04", isOn: $workChatSendWithoutReview)
                hubRow("WK-05") {
                    COSDropdown(hubLabel("WK-05"), selection: $workChatWhenHeld,
                                options: WorkChatHold.settingOptions.map { COSDropdownOption($0.0, $0.1) }, showsLabel: false)
                        .frame(width: 200)
                }
                if model.workExpiryAvailable {
                    hubSwitch("WK-01", isOn: Binding(get: { model.workExpiryEnabled }, set: { enabled in Task { await model.setWorkExpiry(enabled) } }))
                }
            }
            .disabled(model.busy)
        } advanced: {
            // Per-Mac defaults that Work chat's footer also offers (OUT-05, OUT-06).
            hubRow("OUT-05", detail: hubDetail("OUT-05") + " " + SettingsHubCopy.plannerNote) {
                COSDropdown("Plan with", selection: $workChatPlanner,
                            options: WorkChatPolicy.planners.map { COSDropdownOption($0, WorkChatPolicy.plannerName($0)) }, showsLabel: false)
                    .frame(width: 160)
            }
            hubRow("OUT-06", detail: hubDetail("OUT-06") + " " + SettingsHubCopy.plannerNote) {
                COSDropdown("Effort", selection: $workChatEffort,
                            options: WorkChatPolicy.efforts.map { COSDropdownOption($0, WorkChatPolicy.effortName($0)) }, showsLabel: false)
                    .frame(width: 160)
            }
        }
        if hubGroupShown("work.background") {
            hubCard("work.background") {
                toolBackgroundJobs(hub: true).disabled(model.busy)
                if model.status.backgroundJobsEnabled != nil { SettingsHubBlock { statusBackgroundRow } }
            }
        }
        hubCard("work.folders", advanced: hubAdvancedCount("work.folders")) {
            Group {
                hubRow("UT-15", detail: hubFolderDetail("UT-15")) {
                    Button("Choose…") { model.selectWorkFolder() }
                        .buttonStyle(TodayButtonStyle(small: true)).disabled(folderPickBlocked).help(folderHelp(workFolderHelp))
                }
                SettingsHubBlock { statusWorkFolderRows }
                hubRow("UT-17", detail: hubFolderDetail("UT-17")) {
                    Button("Choose…") { model.selectContextFolder() }
                        .buttonStyle(TodayButtonStyle(small: true)).disabled(folderPickBlocked).help(folderHelp(Self.cosDataHelp))
                }
                if model.status.contextResolvedRoot == nil {
                    hubRow("UT-18") {
                        Button("Create Folders") { model.perform("create-context-folders") }
                            .buttonStyle(TodayButtonStyle(small: true)).disabled(serverNotInstalled).help(createFoldersHelp)
                    }
                }
            }
            .disabled(model.busy)
            if model.status.contextBrowserSupported { SettingsHubBlock { statusContextRows } }
        } advanced: {
            if model.status.contextScriptsDirectory != nil || model.status.contextFilesDirectory != nil {
                SettingsHubBlock(advanced: true) { notesSourceLine }
            } else {
                hubRow("UT-19") { SettingsHubValue(text: "Not set") }
            }
        }
        if hubGroupShown("work.brief") {
            hubCard("work.brief") { SettingsHubBlock { morningBriefContent } }
        }
        if hubGroupShown("work.domains") {
            hubCard("work.domains") { SettingsHubBlock { domainsContent } }
        }
        if hubGroupShown("work.fences") {
            // Only while a thread is paused, and then it needs you: not under Advanced.
            hubCard("work.fences") { SettingsHubBlock { fencesContent } }
        }
    }

    // MARK: Privacy and permissions

    @ViewBuilder var hubPrivacy: some View {
        hubCard("privacy.permissions", advanced: hubAdvancedCount("privacy.permissions")) {
            hubRow("PM-01", label: "Status") { SettingsHubPermissionsSummary(guide: model.permissionGuide) }
            SettingsHubBlock { PermissionGuideList(guide: model.permissionGuide) }
        } advanced: {
            SettingsHubBlock(advanced: true) { StaleBuildsSection(guide: model.permissionGuide) }
        }
    }

    // MARK: Pet and appearance

    @ViewBuilder var hubPet: some View {
        // The pet's settings came from Tools, which is off while busy.
        hubCard("pet.pet", advanced: hubAdvancedCount("pet.pet")) {
            hubSwitch("PT-01", isOn: Binding(get: { model.petEnabled }, set: { model.setPetEnabled($0) }))
            if model.petIntroVisible { SettingsHubBlock { PetIntroLine(model: model) } }
            if model.petEnabled {
                if !model.petJumpTrusted { SettingsHubBlock { petJumpWarning } }
                SettingsHubBlock { PetSizeControls(model: model) }
                hubRow("PT-10") { petCloudPuffButton.buttonStyle(TodayButtonStyle(small: true)) }
            }
        } advanced: {
            SettingsHubBlock(advanced: true) { PetSpriteStateControls(model: model) }
            SettingsHubBlock(advanced: true) { petSpriteButtons }
        }
        .disabled(model.busy)
        if hubGroupShown("pet.characters") {
            hubCard("pet.characters") { SettingsHubBlock { petGalleryCard } }
                .disabled(model.busy)
        }
    }

    // MARK: System and updates

    @ViewBuilder var hubSystem: some View {
        let legacy = ["legacyStopped", "legacyService"].contains(model.status.runtimeState)
        // A legacy server's next step is under Advanced, so Advanced opens on its own then.
        hubCard("system.server", advanced: hubAdvancedCount("system.server"), forceOpen: legacy) {
            SettingsHubBlock { statusServerRows; statusVersionRow }
            if (model.status.activeJobs ?? 0) + (model.status.activeTranscriptionSessions ?? 0) > 0 || model.status.transactionPending {
                SettingsHubBlock { statusActiveWorkLine; statusTransactionLine }
            }
            hubRow("C-01", label: "Restart and update", detail: "Restart, stop or start the server, or install the newest one. Restart is off while work is running.") {
                serverControlButtons
            }
            if model.status.runtimeState == "legacyForeground" || model.notice != nil {
                SettingsHubBlock { serverForegroundWarning; serverNoticeLine }
            }
        } advanced: {
            if legacy {
                SettingsHubBlock(advanced: true) { serverLegacyControls }
            } else {
                hubRow("C-06", label: "Older server", detail: "Adopt, manage in place, or replace a server COS Control did not install.") {
                    SettingsHubValue(text: "Not needed")
                }
            }
            Group {
                hubButton("UT-24", "Open") { model.openHealth() }
                // UT-26 gets the confirmation the inventory asks for; the panel's button rolls back on one click.
                hubButton("UT-26", "Roll back…") { confirmHubRollback = true }
                if confirmHubRollback { hubRollbackConfirm }
                hubButton("UT-27", "Finish change") { model.perform("reconcile") }
            }
            .disabled(model.busy)
        }
        hubCard("system.updates") {
            // H-01 to H-03: the version, Check now (the header's refresh and check) and how the last check went.
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("COS Control").font(COSType.body(14.5, weight: .semibold)).foregroundStyle(TodayInk.ink)
                    updateStatusLine(idle: "Checks at launch and every six hours.", size: 13).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    Text(ControllerModel.currentVersion).font(COSType.mono(12)).foregroundStyle(TodayInk.grey)
                        .accessibilityLabel("COS Control version \(ControllerModel.currentVersion)")
                    Button("Check now") { Task { await model.refreshAndCheckForUpdates() } }
                        .buttonStyle(TodayButtonStyle(small: true))
                        .help("Refresh status and check for updates")
                }
                .fixedSize()
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .overlay(alignment: .top) { SettingsHubHairline() }
            .id("item.H-02")
            hubRow("H-06") {
                if model.appUpdateFlow.showsBanner {
                    Button("Read") { model.presentWhatsNew() }.buttonStyle(TodayButtonStyle(small: true))
                } else {
                    SettingsHubValue(text: "Opens with the next update")
                }
            }
            hubRow("G-05") { SettingsHubValue(text: footerLabel, mono: true) }
        }
        hubCard("system.troubleshooting") {
            Group {
                hubButton("UT-01", "Run checks") { model.perform("doctor") }
                if !model.doctorChecks.isEmpty { SettingsHubBlock { doctorResults } }
                hubRow("UT-13") {
                    Button("Repair") { model.perform("repair") }.buttonStyle(TodayButtonStyle(small: true)).disabled(repairRuntimeBlocked)
                }
                hubRow("UT-22") {
                    HStack(spacing: 8) {
                        Button("Copy report") { model.perform("report") }.buttonStyle(TodayButtonStyle(small: true))
                        Button("Open logs") { model.openLogs() }.buttonStyle(TodayButtonStyle(small: true))
                    }
                }
                hubButton("UT-28", "Open") { model.openSetupGuide() }
            }
            .disabled(model.busy)
            hubButton("G-04", "Quit") { AppQuit.request() }
        }
    }

    /// The board's inline confirmation for Roll back server (A-system-light).
    var hubRollbackConfirm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Roll back the server?").font(COSType.body(14, weight: .semibold)).foregroundStyle(TodayInk.ink)
            Text("COS Control stops \(model.status.version.map { "server " + $0 } ?? "this server") and starts the version it kept. You can update again from this page.")
                .font(COSType.body(13)).foregroundStyle(TodayInk.sub).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Roll back") { confirmHubRollback = false; model.perform("rollback") }
                    .buttonStyle(TodayButtonStyle(primary: true, small: true))
                Button("Cancel") { confirmHubRollback = false }.buttonStyle(TodayButtonStyle(small: true))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(TodayInk.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(TodayInk.btnBorder, lineWidth: 1))
        .padding(EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))
        .background(TodayInk.hubAdvancedBg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Confirm roll back")
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
        // 0.5.351 QA: a Mac recording has no wearer microphone, so the wearer's own profile is never offered as the person for a Mac voice.
        let mac = model.openReview?.isMacRecording == true
        return model.voiceProfiles
            .filter { $0.name.lowercased().contains(q) && $0.name != voice.label && !(mac && $0.isOwner) }
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
                    // Rounded, matching the server's `mmss`. Truncating here
                    // put the panel 1 second below the clipboard on 456 real
                    // voice rows, and showed "0m 20s" against its "21s".
                    Text("· \(Int((Double(ms) / 1000).rounded()) / 60)m \(Int((Double(ms) / 1000).rounded()) % 60)s")
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
                        HStack(alignment: .center, spacing: 8) {
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
            if let note = model.playbackNote,
               note.voice == voice.label,
               model.playingVoice == nil {
                Text(note.text).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.openReview?.mutable == false {
                Label("Read-only library · new COS meetings remain editable", systemImage: "lock")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else if voice.canRename {
                if model.namingVoice == voice.label {
                    TextField("Type a name", text: $typed)
                        .textFieldStyle(.plain)
                        .cosField()

                    // Scope, chosen BEFORE the name. Until 0.5.0 every rename was
                    // global, so this is the control that makes a correction mean
                    // "in this meeting" — Miles: "it should just be this call."
                    // 0.5.340: a Mac recording has no scope to choose. Its rename is
                    // this meeting's text, and nothing reaches voice profiles.
                    if model.openReview?.isMacRecording == true {
                        Text(MacVoiceCopy.renameNote(forLabel: voice.label))
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        COSViewSwitch("Correction scope", selection: $model.correctionScope,
                                      options: CorrectionScope.allCases.map { COSViewOption($0, $0.label) })
                        Text(model.correctionScope.detail)
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(matches) { option in
                        Button {
                            model.previewRename(from: voice.label, to: option.name,
                                               scope: model.correctionScope,
                                               isNameAssignment: voice.isNameAssignment,
                                               assignVoiceProfile: model.openReview?.isMacRecording == true && MacVoiceLabel.isVoice(voice.label))
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
                                Text(model.openReview?.isMacRecording == true ? "text only" : "new name")
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
    var showsBackButton = true
    var onNextUnnamed: (() -> Void)? = nil
    var nextUnnamedAvailable = false
    /// 0.5.259: the meeting this review belongs to, in Meetings.
    var onOpenMeeting: (() -> Void)? = nil
    var onLinkTask: (() -> Void)? = nil
    var onOpenWork: ((String) -> Void)? = nil
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
                        if let note = model.openMeetingNote {
                            Text(note)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(COSPalette.amber)
                        }
                        if review.unnamedVoiceCount > 0 {
                            Text(review.unnamedVoiceCount == 1
                                 ? "1 voice still needs a name"
                                 : "\(review.unnamedVoiceCount) voices still need names")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(COSPalette.amber)
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
                if onOpenMeeting != nil, model.openReview?.recordId.isEmpty == false {
                    Button {
                        onOpenMeeting?()
                    } label: {
                        Label("Open meeting", systemImage: "calendar").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Open this meeting's transcript, summary and files")
                }
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
                if onNextUnnamed != nil {
                    Button {
                        onNextUnnamed?()
                    } label: {
                        Label("Next to name", systemImage: "chevron.right").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .disabled(!nextUnnamedAvailable)
                    .keyboardShortcut("]", modifiers: .command)
                    .help(nextUnnamedAvailable
                          ? "Open the next meeting that still needs names (⌘])"
                          : "No other meetings still need names")
                }
                if showsBackButton {
                    Button {
                        model.closeSpeakerReview()
                    } label: {
                        Label("Back", systemImage: "chevron.left").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            if let review = model.openReview, review.mutable {
                MeetingSpeakerPolicyView(model: model, sessionId: review.sessionId,
                    recordId: review.recordId, sourceRevision: review.sourceRevision)
                    .id(review.sessionId).padding(.horizontal, 16).padding(.bottom, 10)
            }
            if let onLinkTask, model.openReview?.recordId.isEmpty == false {
                HStack {
                    Button("Link to existing task", action: onLinkTask).buttonStyle(COSQuietButtonStyle())
                    Spacer()
                }.padding(.horizontal, 16).padding(.bottom, 12)
                if let review = model.openReview {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.workTasksLoading { ProgressView("Loading linked tasks…").controlSize(.small) }
                        if let error = model.workTasksError { Text(error).foregroundStyle(COSPalette.danger) }
                        if !model.workTasksLoading && !model.workTasksComplete {
                            Text("The task inventory is incomplete. Refresh to check all links.").foregroundStyle(COSPalette.muted)
                        }
                        let tasks = MeetingWorkConnections.tasks(recordIds: [review.recordId, review.blendedRecordId ?? ""], from: model.workTasks)
                        ScrollView {
                        ForEach(tasks, id: \.workSourceID) { task in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(task.text.isEmpty ? task.title : task.text).font(COSType.body(12, weight: .medium)).lineLimit(2)
                                    Text("Linked · " + task.domain + " · " + (task.checked ? "Complete" : task.workStage.capitalized))
                                        .font(COSType.body(10.5)).foregroundStyle(COSPalette.muted)
                                }
                                Spacer()
                                if let onOpenWork { Button("Open task") { onOpenWork(task.workSourceID) }.buttonStyle(COSQuietButtonStyle()) }
                            }
                        }
                        }.frame(maxHeight: tasks.isEmpty ? 0 : 110)
                        if !model.workTasksLoading && model.workTasksComplete && model.workTasksError == nil && tasks.isEmpty {
                            Text("No linked tasks yet.").foregroundStyle(COSPalette.muted)
                        }
                        Button("Refresh links") { Task { await model.loadWorkTasks(force: true) } }.disabled(model.workTasksLoading)
                    }.font(COSType.body(11)).padding(.horizontal, 16).padding(.bottom, 10)
                }
            }

            Divider()

            // 0.5.343: the transcript builds in place on first open (COSBuildUp); the chain is today's.
            COSBuildUp(.turns(6), loading: model.reviewLoading, landed: model.openReview != nil && !model.reviewLoading,
                       failed: model.reviewError != nil, label: "Reading the transcript", key: model.reviewRequest.map { AnyHashable($0) }) {
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
                                // 0.5.340: a Mac recording never names anyone on purpose; its voices are told apart, not lost.
                                Text(review.isMacRecording ? MacVoiceCopy.unattributedNote
                                     : "The audio was recovered after the session ended, so no voice matching ran while it played. The lines below are all that is left to go on.")
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 16).padding(.bottom, 10)
                        }

                        Divider()
                        ForEach(Array(review.voicesForReview.enumerated()), id: \.element.id) { index, voice in
                            VoiceRow(model: model, voice: voice)
                                .padding(.horizontal, 16)
                            if index < review.voicesForReview.count - 1 { Divider() }
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
                                // A person the user REMOVED can still be named in
                                // the prose below, because de-attribution does not
                                // rewrite written sentences. Say so before they read
                                // it, not after.
                                if let warning = MeetingContent.removalWarning(content.removedNames) {
                                    Text(warning)
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                // Keyed by POSITION, not heading. `sections` now
                                // includes recovered extras, and one real scribe
                                // repeats three of its own `##` headings — keying
                                // on the string gives SwiftUI duplicate ids.
                                ForEach(Array(content.sections.enumerated()), id: \.offset) { item in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.element.0.uppercased())
                                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                        Text(MeetingContent.panelPreview(item.element.1))
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
                    Button("Try again") { model.retryOpenReview() }.font(.system(size: 10))
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
                    if model.openReview?.isMacRecording == true && !correction.refused && correction.to != nil {
                        // 0.5.351: a picked profile shows the voice samples the server would add; a typed name stays text only.
                        ForEach(correction.assignLines, id: \.self) { line in
                            Text(line)
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if correction.assignLines.isEmpty {
                            Text(MacVoiceCopy.typedNote)
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if correction.createsProfile && !correction.refused {
                        Text("This name is not in voice profiles yet. Saving adds it so other segments in this meeting can use it.")
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

                    // 0.5.351 QA: a flagged Mac voice is not saved by a plain Save. Rename only is the default; "Add anyway" is a separate
                    // choice that asks once more before anything is forced.
                    if correction.needsForceToAddSamples, let person = correction.macAssignment?.person {
                        Text(model.forceAssignArmed
                             ? MacVoiceCopy.addAnywayConfirmNote(person: person, samples: correction.macAssignment?.samples ?? 0)
                             : MacVoiceCopy.holdNote(person: person))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 8) {
                        if !correction.refused {
                            if correction.needsForceToAddSamples {
                                Button(MacVoiceCopy.renameOnlyTitle) { model.confirmCorrection(correction, renameOnly: true) }
                                    .keyboardShortcut(.defaultAction)
                                    .buttonStyle(COSPrimaryButtonStyle())
                                    .disabled(model.mergeInFlight)
                                if model.forceAssignArmed {
                                    Button(MacVoiceCopy.addAnywayConfirmTitle) { model.confirmCorrection(correction, addAnyway: true) }
                                        .disabled(model.mergeInFlight)
                                    Button(MacVoiceCopy.backTitle) { model.forceAssignArmed = false }
                                } else {
                                    Button(MacVoiceCopy.addAnywayTitle) { model.armAddAnyway() }
                                        .disabled(model.mergeInFlight)
                                }
                            } else {
                                Button("Save") { model.confirmCorrection(correction) }
                                    .keyboardShortcut(.defaultAction)
                                    .buttonStyle(COSPrimaryButtonStyle())
                                    .disabled(model.mergeInFlight)
                                if correction.savesWithSamples {
                                    Button(MacVoiceCopy.renameOnlyTitle) { model.confirmCorrection(correction, renameOnly: true) }
                                        .disabled(model.mergeInFlight)
                                }
                            }
                        } else if correction.forceable {
                            // A stalled EARLIER correction is the one refusal a
                            // user can override. Without this the 409 was a dead
                            // end whose own message told them to re-open the
                            // meeting, which changes nothing on the server.
                            Button("Apply anyway") { model.forceCorrection(correction) }
                                .keyboardShortcut(.defaultAction)
                                .buttonStyle(COSPrimaryButtonStyle())
                                .disabled(model.mergeInFlight)
                        }
                        Button(correction.refused ? "OK" : "Cancel") { model.cancelCorrection() }
                        if correction.refused && !correction.forceable {
                            Button("Reopen review") { model.cancelCorrection(); model.retryOpenReview() }
                        }
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


extension ControlPanel {
    /// A Memory or Threads list card, mirroring `reviewableMeetingsCard`.
    ///
    /// Miles asked for "something more similar to what we see with review speakers",
    /// and that shape is: a titled card with its own Refresh, rows with a chevron,
    /// and a click that routes the whole panel to a detail view. Loading on Refresh
    /// rather than on appear matches the speakers card and keeps a panel open from
    /// firing store reads nobody asked for.
    @ViewBuilder func contextListCard(kind: String) -> some View {
        let isThread = kind == "thread"
        let records = isThread ? model.threadRecords : model.memoryRecords
        let loading = isThread ? model.threadRecordsLoading : model.memoryRecordsLoading
        let failure = isThread ? model.threadRecordsError : model.memoryRecordsError
        let headline = isThread ? model.threadHeadline : model.memoryHeadline
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(headline.isEmpty
                     ? (isThread ? "Review threads" : "Review memories")
                     : "\(isThread ? "Review threads" : "Review memories") · \(headline)")
                    .font(.caption2.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(.secondary)
                Spacer()
                if loading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button("Refresh") { Task { await model.loadContextRecords(kind: kind) } }
                        .font(.system(size: 10))
                        .controlSize(.small)
                }
            }
            if records.isEmpty {
                Text(failure ?? (isThread
                    ? "Refresh to browse your threads."
                    : "Refresh to browse your stored memory."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let shown = Array(records.prefix(MEETING_LIST_VISIBLE))
                let capped = shown.count > MEETING_LIST_SCROLL_AFTER
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(shown) { record in
                            Button { model.openContextRecord(record, kind: kind) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(record.title)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        if !record.subtitle.isEmpty {
                                            Text(record.subtitle)
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(.tertiary)
                                                // fixedSize because a wrapping Text inside
                                                // the panel's outer ScrollView does not
                                                // reserve its height and paints over the
                                                // next row.
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: capped ? 190 : .infinity)
                .fixedSize(horizontal: false, vertical: !capped)
            }
        }
        .padding(12)
        .background(COSPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// One Memory or Thread, full panel, read-only.
///
/// The same records the glasses browse, with the two things a desktop can add:
/// selectable text at length, and revealing the actual file on the file tier.
struct ContextDetailPane: View {
    @ObservedObject var model: ControllerModel
    var showsBackButton = true

    private var isThread: Bool { model.contextDetailKind == "thread" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if showsBackButton {
                    Button { model.closeContextDetail() } label: {
                        Label(isThread ? "Threads" : "Memories", systemImage: "chevron.left")
                    }
                    .buttonStyle(COSTextButtonStyle())
                }
                Spacer()
                if model.contextDetailLoading { ProgressView().controlSize(.small) }
            }
            if let record = model.contextDetail {
                Text(record.title)
                    .font(COSType.display(18, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if !record.subtitle.isEmpty {
                    Text(record.subtitle).font(COSType.body(11)).foregroundStyle(.secondary)
                }
                // The id is the addressable handle the glasses use, and a copied
                // excerpt is worth little without knowing which record it came from.
                Text(record.id)
                    .font(COSType.mono(9.5))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                ScrollView {
                    // 0.5.232: the note is Markdown (a thread's sections, a memory's
                    // content) and renders as one, with the title already above it.
                    if record.body.isEmpty {
                        Text("(no stored body)")
                            .font(COSType.body(12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        COSMarkdownView(text: record.body, dropLeadingTitle: true, bodySize: 12)
                            .frame(maxWidth: 760, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: .infinity)
                // Actions by weight (0.5.232): Copy as Context is what this pane is for.
                HStack(spacing: 8) {
                    Button("Copy as Context") { model.copyContextRecord(record) }
                        .buttonStyle(COSPrimaryButtonStyle())
                        .keyboardShortcut("c", modifiers: .command)
                    if record.filePath != nil {
                        Button("Reveal in Finder") { model.revealContextRecord(record) }
                    }
                }
                .buttonStyle(COSQuietButtonStyle())
                .controlSize(.small)
                if let note = model.copyNote {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
                if let path = record.filePath {
                    Text(path)
                        .font(COSType.mono(9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            if let error = model.contextDetailError {
                // Annotates rather than replacing: the list row is already readable,
                // so a detail failure must not blank what the user clicked.
                Text(error).font(.caption2).foregroundStyle(COSPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }
}


/// One lesson: what happened, before/after/rule where the store has them, the
/// expected effect by rung, evidence, and the two verbs that carry it onward.
/// Read-only in 0.5.190: there is no Dismiss here, because nothing in Phases
/// 0-2 can move the To review number; that ships with the ledger route later.
struct LearningDetailPane: View {
    @ObservedObject var model: ControllerModel
    var showsBackButton = true
    var onOpenSource: ((LearningEvent) -> Void)? = nil
    var onExploreInGraph: ((String) -> Void)? = nil
    @State private var includeGraph = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if showsBackButton {
                    Button { model.closeLearningDetail() } label: {
                        Label("Learning", systemImage: "chevron.left")
                    }
                    .buttonStyle(COSTextButtonStyle())
                }
                Spacer()
                if model.learningDetailLoading { ProgressView().controlSize(.small) }
            }
            if let event = model.learningDetail {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(event.title)
                            .font(.system(size: 13, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(event.kindLabel) · \(event.rowSubtitle) · \(event.storeLabel)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(event.id)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                        if let excerpt = event.sourceRefs.first?.excerpt, !excerpt.isEmpty {
                            block("Source") {
                                Text(excerpt)
                                    .font(.system(size: 11.5))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                if event.store == "bot_memory", !event.lessonID.isEmpty, let onOpenSource {
                                    Button("Open source record", systemImage: "arrow.up.right.square") { onOpenSource(event) }
                                        .controlSize(.small)
                                }
                            }
                        }
                        if let detail = event.detail {
                            if event.isTaskProposal {
                                block("Proposal") {
                                    if let entry = detail.entry ?? detail.content, !entry.isEmpty {
                                        Text(entry).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    }
                                    ForEach(Array(detail.bodies.enumerated()), id: \.offset) { _, body in
                                        Text(body).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    }
                                    if let task = detail.task, !task.isEmpty { labelled("Producing task", task) }
                                    if let layer = detail.layer, !layer.isEmpty { labelled("Layer", layer) }
                                    if let date = detail.date, !date.isEmpty { labelled("Date", date) }
                                    if let future = detail.future { labelled("Timing", future ? "Dated after today" : "Dated on or before today") }
                                    if let times = detail.loggedTimes { labelled("Logged", "\(times) time\(times == 1 ? "" : "s")") }
                                }
                            } else {
                                if let before = detail.before, !before.isEmpty { block("Before") { Text(before).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
                                if let after = detail.after, !after.isEmpty { block("After") { Text(after).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
                                if let rule = detail.rule, !rule.isEmpty { block("Rule") { Text(rule).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) } }
                                if let content = detail.content, !content.isEmpty, detail.before == nil, detail.rule == nil {
                                    block("Record") { Text(content).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                                }
                                ForEach(Array(detail.bodies.enumerated()), id: \.offset) { _, body in
                                    Text(body).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                                if let status = detail.status, !status.isEmpty { labelled("Status", status) }
                                if let kind = detail.kind, !kind.isEmpty { labelled("Kind", kind) }
                                if let memoryType = detail.memoryType, !memoryType.isEmpty { labelled("Memory type", memoryType) }
                            }
                        }
                        if let version = event.targetVersion, !version.isEmpty { labelled("Version", version) }
                        if event.detail?.truncated == true {
                            Text("Record truncated to fit; the store holds more than shown here.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                        expectedEffect(event)
                        evidence(event)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                HStack(spacing: 10) {
                    Button("Copy context", systemImage: "doc.on.doc") { model.copyLearningContext(event, includeGraph: includeGraph) }
                    Toggle("Include related knowledge", isOn: $includeGraph)
                        .toggleStyle(COSCheckStyle())
                        .font(.system(size: 10.5))
                        .disabled(model.graphEntity == nil)
                        .help(model.graphEntity == nil ? "Open an entity in Knowledge first" : "Append the open entity's description and relationships")
                    if let onExploreInGraph {
                        Button("Explore in graph", systemImage: "point.3.connected.trianglepath.dotted") {
                            onExploreInGraph(Self.exploreTerm(event))
                        }
                    }
                }
                .controlSize(.small)
                if let note = model.copyNote {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let error = model.learningDetailError {
                Text(error).font(.caption2).foregroundStyle(COSPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    /// The graph lookup a lesson opens: the category (a task name, a topic)
    /// when there is one, else the first words of the title.
    static func exploreTerm(_ event: LearningEvent) -> String {
        if !event.category.isEmpty, event.category != event.scope { return event.category }
        let words = event.title.split(separator: " ").prefix(4).joined(separator: " ")
        return words.isEmpty ? event.title : words
    }

    @ViewBuilder
    private func expectedEffect(_ event: LearningEvent) -> some View {
        block("Expected effect") {
            labelled("Applies to", event.appliesTo.isEmpty ? "Scope not resolved" : event.appliesTo.joined(separator: ", "))
            labelled("Preview", "Preview not available until 3.5")
            labelled("Checks", event.outcome.map { result in event.outcomeName.map { "\(result) · \($0)" } ?? result }
                ?? event.detail?.status ?? "No check recorded")
            if let detail = event.detail, let occurrences = detail.occurrences {
                labelled("Repeat rate", "\(occurrences) occurrence\(occurrences == 1 ? "" : "s")"
                    + (detail.threshold.map { " (threshold \($0))" } ?? ""))
            } else if let times = event.detail?.loggedTimes {
                labelled("Repeat rate", "logged \(times) time\(times == 1 ? "" : "s")")
            } else {
                labelled("Repeat rate", "No repeat data")
            }
        }
    }

    @ViewBuilder
    private func evidence(_ event: LearningEvent) -> some View {
        if !event.sourceRefs.isEmpty || event.priorEventID != nil {
            block("Evidence") {
                ForEach(Array(event.sourceRefs.prefix(6).enumerated()), id: \.offset) { _, ref in
                    Text("\(ref.kind) · \(ref.id)\(ref.excerpt.isEmpty ? "" : " · \(ref.excerpt)")")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if let prior = event.priorEventID { labelled("Prior event", prior) }
                labelled("Provenance", event.provenance.isEmpty ? "unknown" : event.provenance)
            }
        }
    }

    private func block<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
            Text(value)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// One graph entity as a native list neighborhood: descriptions (at most six),
/// relationships ranked by weight, neighbor chips that re-select, the memories
/// that mention it, and the source-record status. No canvas and no web view
/// in 0.5.190; the explorer embed and the Manage verbs are later gates.
struct GraphEntityPane: View {
    @ObservedObject var model: ControllerModel
    var showsBackButton = true
    var onOpenMemory: ((ContextRecord) -> Void)? = nil

    /// Everything below sits inside the pane's own ScrollView. The lists are
    /// still capped by COUNT so a 30-edge entity does not push Neighbors,
    /// Mentions and Passages three screens down: the first rows show inline
    /// and a Show all button reveals the rest in place (no nested scrolls).
    private static let graphRelInlineRowLimit = 8
    private static let graphMentionInlineRowLimit = 5
    private static let descriptionLineLimit = 4
    @State private var showAllRelationships = false
    @State private var showAllMentions = false
    @State private var showAllDescriptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if showsBackButton {
                    Button { model.closeGraphEntity() } label: {
                        Label("Knowledge", systemImage: "chevron.left")
                    }
                    .buttonStyle(COSTextButtonStyle())
                }
                Spacer()
                if model.graphEntityLoading { ProgressView().controlSize(.small) }
            }
            if let entity = model.graphEntity {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(entity.id)
                            .font(.system(size: 13, weight: .semibold))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text([entity.type.isEmpty ? nil : entity.type,
                              entity.degree.map { "\($0) relationships" },
                              entity.createdAt.map { "since \($0)" }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if !entity.description.isEmpty || !entity.descriptions.isEmpty {
                            section("Descriptions") {
                                // Length-capped too: the busiest entities carry 10-18 K
                                // characters of merged description (QA 2026-09-06).
                                ForEach(Array((entity.descriptions.isEmpty ? [entity.description] : entity.descriptions).prefix(6).enumerated()), id: \.offset) { _, text in
                                    Text(text)
                                        .font(.system(size: 11.5))
                                        .lineLimit(showAllDescriptions ? nil : Self.descriptionLineLimit)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Button(showAllDescriptions ? "Show less" : "Show all") { showAllDescriptions.toggle() }
                                    .buttonStyle(COSTextButtonStyle())
                            }
                        }
                        if !entity.edges.isEmpty {
                            section("Relationships" + (entity.totalRelationships.map { " · \($0)" } ?? "")) {
                                ForEach(showAllRelationships ? entity.edges : Array(entity.edges.prefix(Self.graphRelInlineRowLimit))) { edge in
                                    relationshipRow(edge, entity: entity)
                                }
                                if entity.edges.count > Self.graphRelInlineRowLimit {
                                    Button(showAllRelationships ? "Show fewer" : "Show all \(entity.edges.count)") { showAllRelationships.toggle() }
                                        .buttonStyle(COSTextButtonStyle())
                                }
                            }
                        }
                        if !entity.neighbors.isEmpty {
                            section("Neighbors") {
                                FlowChips(items: entity.neighbors.prefix(24).map { ($0.id, $0.type) }) { id in
                                    model.openGraphEntity(id: id)
                                }
                            }
                        }
                        section("Memories mentioning this") {
                            if model.graphMentionsLoading {
                                ProgressView().controlSize(.mini)
                            } else if model.graphMentions.isEmpty {
                                Text("No stored memory mentions this name.")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(showAllMentions ? model.graphMentions : Array(model.graphMentions.prefix(Self.graphMentionInlineRowLimit))) { hit in
                                    mentionRow(hit)
                                }
                                if model.graphMentions.count > Self.graphMentionInlineRowLimit {
                                    Button(showAllMentions ? "Show fewer" : "Show all \(model.graphMentions.count)") { showAllMentions.toggle() }
                                        .buttonStyle(COSTextButtonStyle())
                                }
                            }
                        }
                        if !model.graphPassages.isEmpty {
                            section("Passages") {
                                ForEach(model.graphPassages) { passage in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(passage.excerpt)
                                            .font(.system(size: 11))
                                            .lineLimit(4)
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Text([passage.sourceTitle, passage.sourceDate, passage.sourceStatus == "resolved" ? nil : passage.sourceStatus]
                                            .compactMap { $0 }.joined(separator: " · "))
                                            .font(.system(size: 9.5))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        if let line = entity.sourceLine {
                            Text(line).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                HStack {
                    Button("Copy context", systemImage: "doc.on.doc") { model.copyGraphEntity(entity) }
                }
                .controlSize(.small)
                if let note = model.copyNote {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let error = model.graphEntityError {
                Text(error).font(.caption2).foregroundStyle(COSPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func relationshipRow(_ edge: GraphRelationship, entity: GraphEntity) -> some View {
        Button {
            model.openGraphEntity(id: edge.other(than: entity.id))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(edge.other(than: entity.id))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                if let weight = edge.weight {
                    Text(weight.rounded() == weight ? "\(Int(weight))" : String(format: "%.1f", weight))
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text(edge.description)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func mentionRow(_ hit: ContextSearchHit) -> some View {
        Button {
            onOpenMemory?(hit.record)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(hit.record.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Text(hit.matchLabel)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onOpenMemory == nil)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A wrapping row of chips for the 390 pt menu panel: each chip keeps its
/// intrinsic size and the row breaks wherever the width runs out.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: width == .infinity ? maxX : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// ── Activity hotkey (0.5.190, Miles 2026-09-06) ─────────────────────
//
// A GLOBAL shortcut that opens the Activity window from any app. Carbon's
// RegisterEventHotKey needs no Accessibility grant (an NSEvent global monitor
// would), fires only for the exact chord, and delivers on the main run loop.
// One registration at a time; re-registered whenever the combo changes.

private let activityHotKeySignature: OSType = 0x434F_5348  // 'COSH'

private let activityHotKeyHandler: EventHandlerUPP = { _, _, _ in
    Task { @MainActor in HotKeyCenter.shared.fire() }
    return noErr
}

@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    var onFire: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var registered: HotKeyCombo?

    private init() {}

    func register(_ combo: HotKeyCombo?) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registered = nil
        guard let combo else { return }
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), activityHotKeyHandler, 1, &spec, nil, &handlerRef)
        }
        let id = EventHotKeyID(signature: activityHotKeySignature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRef = ref
            registered = combo
        } else {
            NSLog("[COS Control] hotkey registration failed for %@ (OSStatus %d)", combo.display, status)
        }
    }

    func fire() { onFire?() }
}

/// "Open Activity with ⌃⌥⌘A · Record · Off". Record listens for the next
/// chord in this panel; Escape cancels; a chord without Command, Control or
/// Option is refused with the reason.
struct HotKeyRecorderRow: View {
    @ObservedObject var model: ControllerModel
    /// Settings hub: the row's label is the hub row's ("Activity shortcut"), so the recorder draws without its own.
    var showsLabel = true
    @State private var recording = false
    @State private var monitor: Any?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                if showsLabel {
                    Text("Activity shortcut")
                        .font(.caption)
                }
                Text(recording ? "Press keys…" : (model.activityHotKey?.display ?? "Off"))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(recording ? 0.12 : 0.06)))
                    .accessibilityLabel("Activity hotkey \(model.activityHotKey?.display ?? "off")")
                Button(recording ? "Cancel" : "Record") { recording ? stop() : start() }
                    .controlSize(.mini)
                if model.activityHotKey != nil, !recording {
                    Button("Off") { model.setActivityHotKey(nil); note = nil }
                        .controlSize(.mini)
                }
                if showsLabel { Spacer(minLength: 0) }
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(COSPalette.amber)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        note = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Escape cancels
                Task { @MainActor in stop() }
                return nil
            }
            let combo = HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: HotKeyCombo.carbonModifiers(from: event.modifierFlags))
            Task { @MainActor in
                if let combo {
                    model.setActivityHotKey(combo)
                    stop()
                } else {
                    note = "Add Command, Control or Option to the key."
                }
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Neighbor chips that wrap. Each re-selects its entity in place.
private struct FlowChips: View {
    let items: [(String, String)]
    let action: (String) -> Void

    var body: some View {
        // A simple wrapping layout: rows of chips sized by their text.
        var rows: [[(String, String)]] = [[]]
        var width: CGFloat = 0
        for item in items {
            let estimate = CGFloat(item.0.count) * 6.4 + 22
            if width + estimate > 560, !rows[rows.count - 1].isEmpty {
                rows.append([])
                width = 0
            }
            rows[rows.count - 1].append(item)
            width += estimate + 6
        }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                        Button { action(item.0) } label: {
                            Text(item.0)
                                .font(.system(size: 10.5, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                                .overlay(Capsule().stroke(COSPalette.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(item.1.isEmpty ? item.0 : "\(item.0) · \(item.1)")
                    }
                }
            }
        }
    }
}

private struct PetSpriteStateControls: View {
    @ObservedObject var model: ControllerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(PetSpriteStore.defaultCharacterName) is the simple default. Running, Done and Waiting stay in the ledger. Animated characters are optional in Characters.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(PetSpritePose.liveCases, id: \.self) { pose in
                poseRow(pose)
            }
            DisclosureGroup("More states") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(PetSpritePose.catalogCases, id: \.self) { pose in
                        poseRow(pose)
                    }
                }
            }
            .font(.caption)
        }
    }

    private func poseRow(_ pose: PetSpritePose) -> some View {
        HStack(spacing: 8) {
            poseThumb(pose)
            VStack(alignment: .leading, spacing: 1) {
                Text(pose.title)
                    .font(.caption)
                Text(pose.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Gating on frames > 1 hid the only control that can RAISE the
            // count, so a board-installed cell recorded at 1 could never be
            // told it is a strip.
            if model.petSpriteKit.preview(for: pose) != nil {
                COSStepper(
                    "\(pose.title) frames",
                    value: Binding(
                        get: { model.petSpriteFrameCount(pose) },
                        set: { model.setPetSpriteFrames(pose, frames: $0) }
                    ),
                    in: PetSpriteStrip.minFrames...PetSpriteStrip.maxFrames,
                    valueText: "\(model.petSpriteFrameCount(pose))",
                    showsLabel: false
                )
                .fixedSize()
            }
            Button("Choose") { model.choosePetSprite(for: pose) }
        }
    }

    @ViewBuilder
    private func poseThumb(_ pose: PetSpritePose) -> some View {
        if let image = model.petSpriteKit.preview(for: pose) {
            Image(nsImage: image)
                .interpolation(.medium)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(COSPalette.line, lineWidth: 1)
                .frame(width: 28, height: 28)
        }
    }
}

private struct PetSizeControls: View {
    @ObservedObject var model: ControllerModel
    @State private var pixelDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pet size")
                .font(.caption)
                .foregroundStyle(.secondary)
            COSViewSwitch("Pet size", selection: Binding(
                get: { model.petSize.preset },
                set: { model.setPetSizePreset($0) }
            ), options: PetSizePreset.allCases.map { COSViewOption($0, $0.title) })
            if model.petSize.preset == .custom {
                HStack(spacing: 8) {
                    TextField("64", text: $pixelDraft)
                        .textFieldStyle(.plain)
                        .cosField()
                        .frame(width: 56)
                        .onSubmit { commitPixels() }
                    Text("px")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    COSStepper("Pet size in pixels", value: Binding(
                        get: { model.petSize.pixels },
                        set: { model.setPetCustomPixels($0) }
                    ), in: PetSize.minPixels...PetSize.maxPixels, valueText: nil, showsLabel: false)
                }
                Text("Sprite size. Medium is \(PetSize.mediumPixels) px.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(model.petSize.pixels) px. Custom sets the card and the base sprite.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Divider()
                .padding(.vertical, 2)
            Text("Character size")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { Double(model.petCharacterPercent) },
                        set: { model.setPetCharacterPercent(Int($0.rounded())) }
                    ),
                    in: Double(PetCharacterScale.minPercent)...Double(PetCharacterScale.maxPercent),
                    step: 10
                )
                .controlSize(.small)
                Text("\(model.petCharacterPercent)%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
            Text("Scales the figure only. Buttons, text, and the card keep their size.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Divider()
                .padding(.vertical, 2)
            Text("Character speed")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { Double(model.petAnimationSpeedPercent) },
                        set: { model.setPetAnimationSpeedPercent(Int($0.rounded())) }
                    ),
                    in: Double(PetAnimationSpeed.minPercent)...Double(PetAnimationSpeed.maxPercent),
                    step: 5
                )
                .controlSize(.small)
                Text("\(model.petAnimationSpeedPercent)%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
            Text("Controls animation playback only. 25% is slow motion; 100% matches the pack.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Divider()
                .padding(.vertical, 2)
            COSViewSwitch("Motion", selection: Binding(
                get: { model.petMotion },
                set: { model.setPetMotion($0) }
            ), options: PetMotion.allCases.map { COSViewOption($0, $0.shortTitle) }, showsLabel: true)
            .font(.caption)
            Text("Full plays every state, Calm stays idle, None holds still. Also on the pet's menu.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .onAppear { pixelDraft = "\(model.petSize.pixels)" }
        .onChange(of: model.petSize.pixels) { _, value in
            pixelDraft = "\(value)"
        }
    }

    private func commitPixels() {
        let trimmed = pixelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Int(trimmed) {
            model.setPetCustomPixels(value)
        }
        pixelDraft = "\(model.petSize.pixels)"
    }
}

extension ControlPanel {
    /// Settings hub offscreen fixture (Tests/SettingsHubRender.swift): Activity's hub opened on a category, or on a search.
    static func hubFixture(model: ControllerModel, category: SettingsHubCategory, query: String = "",
                           advanced: Set<String> = []) -> ControlPanel {
        precondition(!model.backgroundWorkEnabled)
        var panel = ControlPanel(model: model, openActivity: { _ in }, hostedInWindow: true, hostedInActivity: true,
                                 hub: SettingsHubHost(backTitle: "Today", back: {}))
        panel._hubCategory = State(initialValue: category)
        panel._hubQuery = State(initialValue: query)
        panel._hubAdvanced = State(initialValue: advanced)
        return panel
    }
}
