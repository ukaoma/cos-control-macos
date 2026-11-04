import AppKit
import SwiftUI

// Offscreen renders of 0.5.367's Open COS on your phone row (UT-29, PhoneSignInRow), light and dark, at the panel's width
// (390 pt): the QR ready, a sign-in code with its countdown, Tailscale off, a server too old and a server not ready, then the
// whole Devices card with the glasses rows above it, so the two QRs are seen together (also at 720 pt, the card's width in a
// 1280 pt Settings window). The state comes from fixture helper answers (the shapes WebSignInCore.handoffAnswer and
// deviceCodeAnswer map, HelperSources/PairingCore.swift), never the helper; no window is ordered in, nothing is opened, and
// both rows' polls are off (polls: false). Fixture hosts only (100.64.0.x, example-mac); the ticket is not a real one.

let base = Date(timeIntervalSince1970: 1_791_000_000)
func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date)
}

// MARK: The phone row's helper answers (web-handoff, web-device-code)

/// 43 characters, as long as a real ticket, so the QR is as dense as the one on screen.
let fixtureTicket = "fixtureTicketNotReal_0000000000000000000000"
let phoneURL = "http://example-mac.tail00000a.ts.net:3141/control?handoff=\(fixtureTicket)"
/// phoneUrl present: `ready`.
let handoffReady = #"{"transport":"answered","httpStatus":200,"phone":"ready","phoneUrl":"\#(phoneURL)","expiresAt":"\#(iso(base.addingTimeInterval(120)))"}"#
/// phoneUrl null (this Mac has no tailnet address): `no_tailnet`.
let handoffNoTailnet = #"{"transport":"answered","httpStatus":200,"phone":"no_tailnet"}"#
/// No phoneUrl key at all (a server before 6.99.3): `needs_update`.
let handoffTooOld = #"{"transport":"answered","httpStatus":200,"phone":"needs_update"}"#
/// The managed server is not running or not verified: the helper never asks it.
let notReady = #"{"transport":"not_ready","httpStatus":0}"#
let deviceCode = #"{"transport":"answered","httpStatus":200,"code":"K7Q2-M9XD","expiresAt":"\#(iso(base.addingTimeInterval(300)))"}"#

// MARK: The glasses rows' helper answers (from Tests/GlassesPairingRender.swift, the QR shown)

func tailscale() -> String {
    let peers = #"[{"os":"iOS","dns":"example-iphone.tail00000a.ts.net","ipv4":"100.64.0.11","online":true,"sameUser":true},{"os":"macOS","dns":"example-laptop.tail00000a.ts.net","ipv4":"100.64.0.12","online":false,"sameUser":true}]"#
    return #"{"installed":true,"running":true,"backendState":"Running","selfIPv4":"100.64.0.10","selfDNS":"example-mac.tail00000a.ts.net","peers":\#(peers),"bundle":"standalone","error":null}"#
}
let glassesQR = "COS1/MAC/K7Q2M9XD/100.64.0.10:3141/T3LQ5K"
let pairingCode = #"{"code":"K7Q2M9XD","display":"K7Q2-M9XD","qr":"\#(glassesQR)","expiresAt":"\#(iso(base.addingTimeInterval(300)))","bootId":"boot-1","hosts":[{"host":"100.64.0.10","port":3141,"kind":"tailscale"}],"lanArmedUntil":null,"reason":null,"httpStatus":200}"#
let pairingStatus = #"{"code":{"display":"K7Q2-M9XD","expiresAt":"\#(iso(base.addingTimeInterval(300)))","state":"active"},"pending":null,"lastClaim":null,"firstAuthAfterClaimAt":null,"lanArmedUntil":null,"bootId":"boot-1","reason":null,"httpStatus":200}"#

/// The row's clock, moved by hand.
@MainActor final class FixtureClock { var now = base }

@MainActor func phoneState(handoff: String, code: String? = nil, codeAge: TimeInterval = 0) async -> PhoneSignInState {
    let state = PhoneSignInState()
    let clock = FixtureClock()
    state.now = { clock.now }
    state.runHelper = { args in
        let details = args[0] == "web-device-code" ? (code ?? "{}") : handoff
        return PairingHelperAnswer(ok: true, message: "", details: Data(details.utf8))
    }
    await state.mint()
    if code != nil {
        await state.showCode()
        // The countdown a few seconds in, as on screen: one tick moves its clock (no new link is due before 90 s).
        clock.now = base.addingTimeInterval(codeAge)
        await state.tick()
    }
    return state
}

@MainActor func seeded(phone: PhoneSignInState, running: Bool = true, glasses: Bool = false) async -> ControllerModel {
    let model = ControllerModel(startBackgroundWork: false)
    model.status = ServerStatus(["installed": .bool(true), "running": .bool(running), "pairingSupported": .bool(true)])
    model.status.running = running; model.status.pairingSupported = true
    model.status.installed = true; model.status.managedContract = true; model.status.ownershipVerified = true; model.status.version = "6.99.3"
    model.phoneSignIn = phone
    model.setupGuide.chooseDevicePath(glasses ? .glasses : .mac)
    if glasses {
        let answers = ["tailscale-status": tailscale(), "pairing-status": pairingStatus, "pairing-code": pairingCode]
        let pairing = GlassesPairingState()
        pairing.now = { base }
        pairing.runHelper = { args in PairingHelperAnswer(ok: true, message: "", details: Data((answers[args[0]] ?? "{}").utf8)) }
        await pairing.tick(index: 0, serverRunning: running, pairingSupported: true)
        model.glassesPairing = pairing
    }
    return model
}

/// The hub's Devices card around one row, on the hub page's background, with the hub's environment.
struct HubPage<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .environment(\.settingsHubHosted, true)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TodayInk.page)
    }
}

/// The Devices card holding only the phone row (Just my Mac, so no glasses note).
struct PhoneOnlyCard: View {
    @ObservedObject var model: ControllerModel
    var body: some View {
        HubPage {
            SettingsHubCard(group: SettingsHubCatalog.group("glasses.devices")!, advancedCount: 0, advancedOpen: .constant(false)) {
                SettingsHubBlock { PhoneSignInRow(model: model, state: model.phoneSignIn, besideGlasses: false, polls: false) }
            } advanced: { EmptyView() }
        }
    }
}

/// The Devices card as ControlPanel.hubGlasses draws it on the glasses path: the device choice, the glasses rows, Get the app
/// (SG-13), the phone row (UT-29), and Advanced closed.
struct DevicesCard: View {
    @ObservedObject var model: ControllerModel
    var body: some View {
        let app = SettingsHubCatalog.item("SG-13")!
        let advanced = SettingsHubCatalog.items(inGroup: "glasses.devices").filter(\.advanced).count
        HubPage {
            SettingsHubCard(group: SettingsHubCatalog.group("glasses.devices")!, advancedCount: advanced, advancedOpen: .constant(false)) {
                SettingsHubBlock { SetupDeviceChoice(guide: model.setupGuide) }
                SettingsHubBlock { GlassesSetupRows(model: model, pairing: model.glassesPairing, openURL: { _ in }, polls: false) }
                SettingsHubRow(label: app.label, detail: app.detail) { Button("Get the app") {}.buttonStyle(TodayButtonStyle(small: true)) }
                SettingsHubBlock { PhoneSignInRow(model: model, state: model.phoneSignIn, besideGlasses: true, polls: false) }
            } advanced: { EmptyView() }
        }
    }
}

@main @MainActor struct PhoneSignInRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-home-render") else { exit(2) }
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var count = 0

        let cases: [(String, String, String?, Bool)] = [
            ("phone-1-qr-ready", handoffReady, nil, true),
            ("phone-2-sign-in-code", handoffReady, deviceCode, true),
            ("phone-3-tailscale-off", handoffNoTailnet, nil, true),
            ("phone-4-server-too-old", handoffTooOld, nil, true),
            ("phone-5-server-not-ready", notReady, nil, false),
        ]
        for (name, handoff, code, running) in cases {
            let phone = await phoneState(handoff: handoff, code: code, codeAge: 23)
            let model = await seeded(phone: phone, running: running)
            count += try render(PhoneOnlyCard(model: model), width: 390, name: name, out: out)
        }

        let phone = await phoneState(handoff: handoffReady)
        let model = await seeded(phone: phone, glasses: true)
        count += try render(DevicesCard(model: model), width: 390, name: "phone-6-devices-card-390", out: out)
        count += try render(DevicesCard(model: model), width: 720 + 32, name: "phone-6-devices-card-720", out: out)

        print("glasses pairing QR modules per side (with margin): \(QRImage.modules(glassesQR) ?? 0)")
        print("phone sign-in QR modules per side (with margin): \(QRImage.modules(phoneURL) ?? 0)")
        print("PhoneSignInRender wrote \(count) PNGs")
    }

    /// The view at `width`, as tall as it wants (its fitting height), in dark then light.
    static func render<V: View>(_ view: V, width: CGFloat, name: String, out: URL) throws -> Int {
        let sizer = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true).cosControlTheme())
        sizer.layoutSubtreeIfNeeded()
        let height = max(120, ceil(sizer.fittingSize.height))
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingView(rootView: view.frame(width: width, height: height, alignment: .top).cosControlTheme())
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance); host.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
            for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.12)); host.layoutSubtreeIfNeeded() }
            host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let word = appearance == .darkAqua ? "dark" : "light"
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name)-\(word).png"))
            window.close()
        }
        return 2
    }
}
