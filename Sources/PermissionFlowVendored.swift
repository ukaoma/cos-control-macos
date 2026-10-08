// VENDORED CODE. Adapted from PermissionFlow by jaywcjlove (小弟调调), MIT License,
// https://github.com/jaywcjlove/PermissionFlow at commit cb96db4b (2026-09-26).
// License and attribution: Resources/ThirdParty/PermissionFlow/LICENSE and ATTRIBUTION.md, THIRD_PARTY_NOTICES.md.
//
// Taken: Sources/PermissionFlow/Tracking/SettingsWindowTracker.swift, UI/FloatingDropPanel.swift and UI/AppDropArea.swift.
// Changed for COS Control (plain swiftc, Swift 6 strict concurrency, COS theme):
//   - SettingsWindowTracker: the AX observer callback re-enters with MainActor.assumeIsolated; polls at 15 Hz, not 30;
//     never prompts for Accessibility itself (the guide decides when to ask).
//   - FloatingDropPanel -> COSFloatingHelperPanel: hosts any SwiftUI view instead of PermissionFlowController; the
//     fly-in launch animation is dropped (the panel appears in place); width is capped for a 390pt-style bar.
//   - AppDropArea -> COSAppDragSourceView: the drag card's look is supplied by the caller (COS styling lives in
//     PermissionGuideViews.swift); the Finder-like pasteboard payload is unchanged.
// Not taken: PermissionFlowController, the panel view, status providers, localization, SystemSettingsKit, the Example.
// No network, no analytics.

import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import SwiftUI

// MARK: - SettingsWindowTracker (vendored)

@MainActor
final class SettingsWindowTracker {
    /// Polling remains enabled even when AX is available because System Settings
    /// can appear before accessibility observers are fully attached.
    private let pollInterval: TimeInterval = 1.0 / 15.0

    /// Temporary lookup misses are common while System Settings opens or swaps
    /// privacy panes. Requiring several misses avoids false "window closed"
    /// detection and keeps the floating panel stable.
    private let missingAppThreshold = 12

    var onFrameChange: ((CGRect) -> Void)?
    var onTrackingEnded: (() -> Void)?
    private(set) var currentFrame: CGRect?

    private let bundleIdentifier = "com.apple.systempreferences"
    private var appObserver: AXObserver?
    private var windowObserver: AXObserver?
    private var observedWindow: AXUIElement?
    private var pollTimer: Timer?
    private var hasActiveTrackingTarget = false
    private var missingAppPollCount = 0

    /// Whether System Settings is running with a window we can follow.
    var isTracking: Bool { hasActiveTrackingTarget }

    func startTracking() {
        stopTracking()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.attachIfNeeded()
            }
        }
        pollTimer?.tolerance = pollInterval * 0.25
        attachIfNeeded()
    }

    /// Tears down polling and all AX observers so a future tracking session
    /// begins from a clean state.
    func stopTracking() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let observer = appObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        if let observer = windowObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        appObserver = nil
        windowObserver = nil
        observedWindow = nil
        currentFrame = nil
        hasActiveTrackingTarget = false
        missingAppPollCount = 0
    }

    /// Resolves the running System Settings app, emits a best-effort frame from the window server immediately, and
    /// if AX is available, attaches observers to the active window for continued updates.
    private func attachIfNeeded() {
        guard let app = runningSettingsApplication() else {
            finishTrackingIfNeededBecauseAppExited()
            return
        }
        hasActiveTrackingTarget = true
        missingAppPollCount = 0

        updateFrameFromWindowServer(for: app.processIdentifier)
        guard AXIsProcessTrusted() else { return }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if appObserver == nil {
            appObserver = makeObserver(for: app.processIdentifier)
            if let appObserver {
                addNotification(kAXMainWindowChangedNotification as CFString, element: appElement, observer: appObserver)
                addNotification(kAXFocusedWindowChangedNotification as CFString, element: appElement, observer: appObserver)
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(appObserver), .commonModes)
            }
        }
        guard let window = mainWindow(for: appElement) else { return }
        guard isSameElement(window, observedWindow) == false else {
            updateCurrentFrame()
            return
        }
        observedWindow = window
        updateWindowObserver(for: app.processIdentifier, window: window)
        updateCurrentFrame()
    }

    /// Window-server geometry needs no permission, so it is the first and fallback source while System Settings opens.
    private func updateFrameFromWindowServer(for pid: pid_t) {
        guard let frame = windowServerFrame(for: pid) else { return }
        guard currentFrame != frame else { return }
        currentFrame = frame
        onFrameChange?(frame)
    }

    private func updateWindowObserver(for pid: pid_t, window: AXUIElement) {
        if let windowObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(windowObserver), .commonModes)
        }
        windowObserver = makeObserver(for: pid)
        if let windowObserver {
            addNotification(kAXMovedNotification as CFString, element: window, observer: windowObserver)
            addNotification(kAXResizedNotification as CFString, element: window, observer: windowObserver)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(windowObserver), .commonModes)
        }
    }

    private func updateCurrentFrame() {
        guard let window = observedWindow else { return }
        guard let position = pointValue(for: kAXPositionAttribute, element: window),
              let size = sizeValue(for: kAXSizeAttribute, element: window) else { return }
        let frame = appKitFrame(fromGlobalTopLeftFrame: CGRect(origin: position, size: size))
        guard currentFrame != frame else { return }
        currentFrame = frame
        onFrameChange?(frame)
    }

    private func mainWindow(for appElement: AXUIElement) -> AXUIElement? {
        if let window = elementValue(for: kAXMainWindowAttribute, element: appElement) { return window }
        if let window = elementValue(for: kAXFocusedWindowAttribute, element: appElement) { return window }
        return arrayValue(for: kAXWindowsAttribute, element: appElement)?.first
    }

    /// All notifications funnel back into attachIfNeeded() on the main thread.
    private func makeObserver(for pid: pid_t) -> AXObserver? {
        var observer: AXObserver?
        let result = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<SettingsWindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { tracker.attachIfNeeded() }
            }
        }, &observer)
        guard result == .success else { return nil }
        return observer
    }

    private func addNotification(_ name: CFString, element: AXUIElement, observer: AXObserver) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        _ = AXObserverAddNotification(observer, element, name, refcon)
    }

    private func elementValue(for key: String, element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func arrayValue(for key: String, element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == CFArrayGetTypeID() else { return nil }
        let nsArray = value as! NSArray
        var elements: [AXUIElement] = []
        for case let item as CFTypeRef in nsArray where CFGetTypeID(item) == AXUIElementGetTypeID() {
            elements.append(item as! AXUIElement)
        }
        return elements.isEmpty ? nil : elements
    }

    private func pointValue(for key: String, element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeValue(for key: String, element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func isSameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else { return false }
        return CFEqual(lhs, rhs)
    }

    /// Prefers a UI-capable System Settings process over prohibited activation-policy helpers.
    private func runningSettingsApplication() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .max(by: { ($0.activationPolicy == .prohibited ? 0 : 1) < ($1.activationPolicy == .prohibited ? 0 : 1) })
    }

    /// The largest visible layer-0 window of the System Settings process, from the window server.
    private func windowServerFrame(for pid: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return windows
            .filter { window in
                guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid else { return false }
                let layer = window[kCGWindowLayer as String] as? Int ?? 0
                let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
                return layer == 0 && alpha > 0
            }
            .compactMap { window -> CGRect? in
                guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                      let cgBounds = CGRect(dictionaryRepresentation: bounds) else { return nil }
                let frame = appKitFrame(fromGlobalTopLeftFrame: cgBounds)
                guard frame.width > 320, frame.height > 240 else { return nil }
                return frame
            }
            .max(by: { $0.width * $0.height < $1.width * $1.height })
    }

    /// Global top-left CG/AX rectangle to AppKit screen coordinates, on the screen that holds most of it.
    private func appKitFrame(fromGlobalTopLeftFrame frame: CGRect) -> CGRect {
        let screens = NSScreen.screens.compactMap { screen -> (frame: CGRect, cgBounds: CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (frame: screen.frame, cgBounds: CGDisplayBounds(CGDirectDisplayID(number.uint32Value)))
        }
        let matched = screens
            .filter { $0.cgBounds.intersects(frame) }
            .max { lhs, rhs in
                lhs.cgBounds.intersection(frame).width * lhs.cgBounds.intersection(frame).height
                    < rhs.cgBounds.intersection(frame).width * rhs.cgBounds.intersection(frame).height
            }
        guard let matched else { return frame }
        let localX = frame.minX - matched.cgBounds.minX
        let localY = frame.minY - matched.cgBounds.minY
        return CGRect(x: matched.frame.minX + localX, y: matched.frame.maxY - localY - frame.height - 3,
                      width: frame.width, height: frame.height)
    }

    /// Stops only after repeated process misses so short-lived lookup failures do not close the panel.
    private func finishTrackingIfNeededBecauseAppExited() {
        guard hasActiveTrackingTarget || currentFrame != nil else { return }
        missingAppPollCount += 1
        guard missingAppPollCount >= missingAppThreshold else { return }
        stopTracking()
        onTrackingEnded?()
    }
}

// MARK: - COSFloatingHelperPanel (vendored from FloatingDropPanel)

/// A non-activating panel at floating level, pinned under the System Settings window. It never becomes key or main,
/// so System Settings keeps the focus while the person drags.
@MainActor
final class COSFloatingHelperPanel: NSPanel {
    private let hostingView: NSHostingView<AnyView>
    private let sizingView: NSHostingView<AnyView>
    private let initialPanelWidth: CGFloat = 440
    private let maximumPanelWidth: CGFloat = 560
    /// System Settings' sidebar; the bar lines up with the pane the person is working in.
    private let sidebarWidth: CGFloat = 230
    private let screenInset: CGFloat = 12
    private let minimumPanelHeight: CGFloat = 96
    private let sizingHeightLimit: CGFloat = 4096

    /// Called when the panel is clicked or the system tries to key it: keep System Settings in front.
    var onKeepSettingsVisible: (() -> Void)?

    init(content: AnyView) {
        hostingView = NSHostingView(rootView: content)
        sizingView = NSHostingView(rootView: content)
        super.init(contentRect: CGRect(origin: .zero, size: CGSize(width: initialPanelWidth, height: minimumPanelHeight)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        // The upstream note: with the default `.intrinsicContentSize`, the host re-advertises the SwiftUI size on every
        // layout pass and reverts each setFrame. The measured height is the one source of truth.
        hostingView.sizingOptions = []
        contentView = hostingView
        setContentSize(CGSize(width: initialPanelWidth, height: measuredPanelHeight(for: initialPanelWidth)))
    }

    func update(content: AnyView) {
        hostingView.rootView = content
        sizingView.rootView = content
        setContentSize(CGSize(width: frame.width, height: measuredPanelHeight(for: frame.width)))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        onKeepSettingsVisible?()
    }

    override func becomeMain() {
        super.becomeMain()
        onKeepSettingsVisible?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { onKeepSettingsVisible?() }
        super.sendEvent(event)
    }

    /// Before System Settings' frame is known: centred on the main screen's lower third.
    func showUnplaced() {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let width = initialPanelWidth
        let height = measuredPanelHeight(for: width)
        setFrame(CGRect(x: screen.midX - width / 2, y: screen.minY + screen.height * 0.22, width: width, height: height), display: false)
        orderFrontRegardless()
    }

    /// Mouse events pass through while the person drags, so System Settings underneath receives the drop.
    func setDraggingPassthrough(_ isDragging: Bool) {
        ignoresMouseEvents = isDragging
        alphaValue = isDragging ? 0.72 : 1.0
        if isDragging { orderBack(nil) } else { orderFrontRegardless() }
    }

    /// Repositions the panel under the latest System Settings frame.
    func snap(to settingsFrame: CGRect) {
        setFrame(targetFrame(for: settingsFrame), display: false)
        orderFrontRegardless()
    }

    /// Under the window, aligned to its content area, clamped to the screen.
    private func targetFrame(for settingsFrame: CGRect) -> CGRect {
        let screenFrame = NSScreen.screens.first(where: { $0.frame.intersects(settingsFrame) })?.visibleFrame ?? settingsFrame
        let contentMinX = settingsFrame.minX + sidebarWidth
        let availableContentWidth = max(240, settingsFrame.width - sidebarWidth)
        let width = min(availableContentWidth, maximumPanelWidth, screenFrame.width - (screenInset * 2))
        let height = measuredPanelHeight(for: width)
        var origin = CGPoint(x: contentMinX + (availableContentWidth - width) / 2, y: settingsFrame.minY - height)
        origin.x = max(screenFrame.minX + screenInset, min(origin.x, screenFrame.maxX - width - screenInset))
        origin.y = max(screenFrame.minY + screenInset, min(origin.y, screenFrame.maxY - height - screenInset))
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    private func measuredPanelHeight(for width: CGFloat) -> CGFloat {
        sizingView.setFrameSize(NSSize(width: width, height: sizingHeightLimit))
        sizingView.layoutSubtreeIfNeeded()
        return max(minimumPanelHeight, sizingView.fittingSize.height)
    }
}

// MARK: - COSAppDragSourceView (vendored from AppDropArea)

/// A native drag source for one file (the running COS Control bundle, or an interpreter binary). The card's look comes
/// from the caller; the pasteboard payload is the upstream Finder-like one System Settings accepts.
struct COSAppDragItemView: NSViewRepresentable {
    let url: URL
    let card: AnyView
    let onDragStateChange: (Bool) -> Void

    func makeNSView(context: Context) -> COSAppDragSourceView {
        let view = COSAppDragSourceView(url: url, card: card)
        view.onDragStateChange = onDragStateChange
        return view
    }

    func updateNSView(_ nsView: COSAppDragSourceView, context: Context) {
        nsView.update(url: url, card: card)
        nsView.onDragStateChange = onDragStateChange
    }
}

final class COSAppDragSourceView: NSView, NSDraggingSource {
    private(set) var url: URL
    private let hostingView: NSHostingView<AnyView>
    private var mouseDownPoint: NSPoint?
    private var hasBegunDragging = false
    var onDragStateChange: ((Bool) -> Void)?

    init(url: URL, card: AnyView) {
        self.url = url
        hostingView = NSHostingView(rootView: AnyView(card.allowsHitTesting(false)))
        super.init(frame: .zero)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(url: URL, card: AnyView) {
        self.url = url
        hostingView.rootView = AnyView(card.allowsHitTesting(false))
        invalidateIntrinsicContentSize()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(52, hostingView.fittingSize.height))
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        hasBegunDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard hasBegunDragging == false, let mouseDownPoint else { return }
        let currentPoint = convert(event.locationInWindow, from: nil)
        guard hypot(currentPoint.x - mouseDownPoint.x, currentPoint.y - mouseDownPoint.y) > 4 else { return }
        hasBegunDragging = true
        beginAppDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        hasBegunDragging = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { onDragStateChange?(true) }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragStateChange?(false)
        mouseDownPoint = nil
        hasBegunDragging = false
    }

    private func beginAppDrag(with event: NSEvent) {
        // System Settings accepts drags more reliably when the payload looks close to a Finder-originated file drag.
        let item = NSDraggingItem(pasteboardWriter: COSFilePasteboardWriter(url: url))
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 56, height: 56)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: point.x - 28, y: point.y - 28, width: 56, height: 56), contents: icon)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }
}

/// The upstream AppBundlePasteboardWriter, unchanged apart from its name: file URL, URL, NSFilenamesPboardType, the
/// promised-file URL and the path as a string.
final class COSFilePasteboardWriter: NSObject, NSPasteboardWriting {
    let url: URL
    init(url: URL) { self.url = url }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType"),
         NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"), .string]
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .fileURL, .URL, NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"): return url.absoluteString
        case NSPasteboard.PasteboardType("NSFilenamesPboardType"): return [url.path]
        case .string: return url.path
        default: return nil
        }
    }
}
