import AppKit
import ApplicationServices
import SwiftUI

/// The Granola-style drag flow: opens the exact Privacy & Security pane, pins a floating bar under System Settings
/// holding the real file to drag, and watches for the grant.
///
/// Accessibility: AXIsProcessTrusted() once a second, the com.apple.accessibility.api distributed notification as a
/// hint to look sooner, and a real cross-process AX read before anything says Allowed (the API can report trusted
/// while calls still fail). Full Disk Access for a background interpreter cannot be read for another binary, so the bar
/// offers Check now, which starts one stopped job and reads its fresh exit code.
@MainActor
final class PermissionDragFlow: ObservableObject {
    @Published private(set) var request: PermissionDragRequest?
    @Published private(set) var phase: HelperBarStep.Phase = .closed
    @Published private(set) var isDragging = false
    @Published private(set) var checking = false
    @Published private(set) var checkMessage: String?
    /// The file on the bar. For COS Control, the running bundle; for a job, its resolved interpreter.
    @Published private(set) var sourceURL: URL?

    weak var guide: PermissionGuide?
    /// Brings COS back to the front after a grant.
    var returnToCOS: @MainActor () -> Void = { NSApp.activate() }

    private var step: HelperBarStep?
    private var panel: COSFloatingHelperPanel?
    private let tracker = SettingsWindowTracker()
    private var poll: Timer?
    private var hint: NSObjectProtocol?
    private var grantedByCheck = false

    static let settingsBundleID = "com.apple.systempreferences"

    func start(_ request: PermissionDragRequest) {
        stop()
        self.request = request
        grantedByCheck = false
        checkMessage = nil
        let path = request.pane == .fullDiskAccess ? PermissionSystem.resolvedInterpreter(request.source.path) : request.source.path
        sourceURL = URL(fileURLWithPath: path)
        step = HelperBarStep(startedAt: Date().timeIntervalSince1970)
        phase = .waiting
        NSWorkspace.shared.open(request.pane.settingsURL())

        let panel = COSFloatingHelperPanel(content: AnyView(PermissionHelperBar(flow: self).cosControlTheme()))
        panel.onKeepSettingsVisible = { Self.activateSettings() }
        panel.showUnplaced()
        self.panel = panel
        tracker.onFrameChange = { [weak self] frame in self?.panel?.snap(to: frame) }
        tracker.onTrackingEnded = { [weak self] in self?.tick(settingsOpen: false) }
        tracker.startTracking()

        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        if request.pane == .accessibility {
            hint = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
            ) { [weak self] _ in
                // A hint only: it misses some changes and can arrive before the grant is readable.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    self?.tick()
                }
            }
        }
    }

    func tick(settingsOpen: Bool? = nil) {
        guard var step, let request else { return }
        let open = settingsOpen ?? !NSRunningApplication.runningApplications(withBundleIdentifier: Self.settingsBundleID).isEmpty
        let granted = request.pane == .accessibility ? (AXIsProcessTrusted() && Self.accessibilityReadWorks()) : grantedByCheck
        let effects = step.observe(granted: granted, settingsOpen: open, now: Date().timeIntervalSince1970)
        self.step = step
        phase = step.phase
        handle(effects)
    }

    private func handle(_ effects: [HelperBarStep.Effect]) {
        for effect in effects {
            switch effect {
            case .showAllowed:
                panel?.update(content: AnyView(PermissionHelperBar(flow: self).cosControlTheme()))
            case .resume:
                if let id = request?.rowID { guide?.granted(rowID: id) }
            case .offerTrouble:
                break
            case .close(let back):
                stop()
                if back { returnToCOS() }
            }
        }
    }

    func dismiss() {
        guard var step else { stop(); return }
        let effects = step.dismiss()
        self.step = step
        phase = step.phase
        handle(effects)
    }

    /// "Having trouble?": for COS Control, Reset and add again (the list may hold an entry for an old signature);
    /// for a job's interpreter, show it in Finder so the + button can find it.
    func trouble() {
        guard let request else { return }
        if request.pane == .accessibility {
            let feature = request.feature
            stop()
            guide?.resetAndAddAgain(feature: feature)
        } else {
            revealInFinder()
        }
    }

    func revealInFinder() {
        guard let url = sourceURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Background jobs: start one stopped job and read its fresh exit code.
    func checkNow() {
        guard let request, let guide, !checking else { return }
        checking = true
        checkMessage = nil
        Task {
            let worked = await guide.checkBackgroundJobs(rowID: request.rowID)
            checking = false
            if worked {
                grantedByCheck = true
                tick()
            } else {
                checkMessage = "Still stopped. Make sure the switch beside it is on, then check again."
            }
        }
    }

    func setDragging(_ dragging: Bool) {
        isDragging = dragging
        panel?.setDraggingPassthrough(dragging)
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        if let hint { DistributedNotificationCenter.default().removeObserver(hint) }
        hint = nil
        tracker.stopTracking()
        panel?.close()
        panel = nil
        step = nil
        phase = .closed
        isDragging = false
    }

    /// A real read across processes: the Dock's role. A read of COS Control's own process can work without the grant,
    /// so it would prove nothing.
    static func accessibilityReadWorks() -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return AXIsProcessTrusted()
        }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(AXUIElementCreateApplication(dock.processIdentifier), kAXRoleAttribute as CFString, &value) == .success
    }

    static func activateSettings() {
        NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first?.activate()
    }
}
