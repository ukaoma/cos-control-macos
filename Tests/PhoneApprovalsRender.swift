import AppKit
import CryptoKit
import SwiftUI

// Offscreen renders of option A (lead 2026-11-11 21:31), Settings PK-02 "Turn on phone approvals", for Miles before
// signing, light and dark:
//   page-*  the whole Settings window on Glasses and iPhone at 1280 pt (and the 760 pt minimum): Basic (no PK-02), All with
//           the switch off, and All with it on and the amber certificate line in Phone approvals below it.
//   card-*  the Phone and web card at its width in a 1280 pt window (720 pt): the phone picker empty and with a phone, the
//           turn-on confirm, the turn-off confirm, no phone on this account, waiting for running work, on with HTTPS
//           Certificates off, and on with the certificate ready (no amber line).
// Every state comes from fixture helper answers (web-key status, keys, pending; tailscale-status; the phone sign-in link)
// and a software anchor; the helper never runs, no certificate is requested, nothing is clicked or opened, no window is
// ordered in, and the confirm buttons are drawn, never pressed (PhoneApprovalsSwitchRow.renderFixture). Fixture names only
// (example-mac.tail00000a.ts.net, 100.64.0.x); the anchor key and the ticket are made up for this file.

let base = Date(timeIntervalSince1970: 1_794_400_000)
let baseMs = Int64(base.timeIntervalSince1970 * 1000)
let host = "example-mac.tail00000a.ts.net"
let origin = "https://\(host):3144"

func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date)
}

// MARK: The anchor and its keychain stand-in (never the login keychain, never the Secure Enclave)

struct RenderAnchor: WebKeyAnchorSigner {
    let raw = Data(SHA256.hash(data: Data("phone approvals render anchor, not a real key".utf8)))
    var publicKeyDER: Data { (try! P256.Signing.PrivateKey(rawRepresentation: raw)).publicKey.derRepresentation }
    func sign(_ message: Data, reason: String) async throws -> Data { throw WebKeyAnchorError.signFailed }
}

final class RenderSecure: WebKeySecureStore, @unchecked Sendable {
    var items: [String: Data] = [:]
    func read(_ account: String) -> WebKeySecureRead { items[account].map { .found($0) } ?? .missing }
    func write(_ account: String, _ data: Data) -> Bool { items[account] = data; return true }
}

// MARK: The server's web-key answers

/// What the COS server says about phone approvals.
enum Served {
    case off
    case on(signerTls: [String: Any])
}
@MainActor let tlsPending: [String: Any] = ["trusted": false, "reason": "pending", "host": NSNull(), "notAfter": NSNull()]
@MainActor let tlsCertsOff: [String: Any] = ["trusted": false, "reason": "tailnet_https_certs_off", "host": NSNull(), "notAfter": NSNull()]
@MainActor let tlsReady: [String: Any] = ["trusted": true, "reason": "ok", "host": host, "notAfter": "2027-02-08T17:38:32.000Z"]

@MainActor func webKey(_ served: Served) async -> WebKeyState {
    let state = WebKeyState()
    let anchor = RenderAnchor()
    let secure = RenderSecure()
    secure.items[SecureEnclaveWebKeyAnchor.blobAccount] = Data("render-anchor-blob".utf8)
    let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("web-key-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    state.secure = secure
    state.stateDirectory = dir
    state.loadAnchor = { _ in anchor }
    state.makeAnchor = { anchor }
    state.now = { base }
    // Control's protected record for this anchor, as a Mac that registered it a day ago holds it.
    precondition(state.store.save(WebKeyControlState(epoch: 4, revoked: [], anchorSpkiSha256: WebKeyHash.sha256Hex(anchor.publicKeyDER), updatedAt: baseMs)))
    let aud = WebKeyProtocol.aud(anchorDER: anchor.publicKeyDER, rpId: host)
    let status: [String: Any]
    switch served {
    case .off: status = ["enabled": false, "origin": origin]
    case .on(let tls):
        status = ["enabled": true, "mode": "authority", "origin": origin, "aud": aud, "anchorRegistered": true, "anchorMature": true,
                  "anchorSetAt": baseMs - 86_400_000, "epoch": 4, "signerTls": tls]
    }
    let bodies: [String: [String: Any]] = ["status": status, "keys": ["epoch": 4, "keys": [Any]()], "pending": ["pending": NSNull()]]
    state.runHelper = { args, _ in
        guard args.count == 3, args[0] == "web-key", args[1] == "--op", let body = bodies[args[2]] else {
            return WebKeyHelperAnswer(ok: true, message: "", details: json(["transport": "not_ready", "httpStatus": 0]))
        }
        return WebKeyHelperAnswer(ok: true, message: "", details: json(["transport": "answered", "httpStatus": 200, "body": body]))
    }
    await state.refresh()
    return state
}

// MARK: Tailscale and the glasses rows (the picker reads this account's iPhones from tailscale-status)

let peersAll = #"[{"os":"iOS","dns":"example-iphone.tail00000a.ts.net","ipv4":"100.64.0.11","online":true,"sameUser":true},{"os":"iOS","dns":"example-ipad.tail00000a.ts.net","ipv4":"100.64.0.13","online":false,"sameUser":true},{"os":"iOS","dns":"friend-iphone.tail00000a.ts.net","ipv4":"100.64.0.14","online":true,"sameUser":false},{"os":"macOS","dns":"example-laptop.tail00000a.ts.net","ipv4":"100.64.0.12","online":false,"sameUser":true}]"#
/// No iPhone on this account: another account's phone and this account's Mac only.
let peersNoPhone = #"[{"os":"iOS","dns":"friend-iphone.tail00000a.ts.net","ipv4":"100.64.0.14","online":true,"sameUser":false},{"os":"macOS","dns":"example-laptop.tail00000a.ts.net","ipv4":"100.64.0.12","online":false,"sameUser":true}]"#
func tailscale(_ peers: String) -> String {
    #"{"installed":true,"running":true,"backendState":"Running","selfIPv4":"100.64.0.10","selfDNS":"\#(host)","peers":\#(peers),"bundle":"standalone","error":null}"#
}
let glassesQR = "COS1/MAC/K7Q2M9XD/100.64.0.10:3141/T3LQ5K"
let pairingCode = #"{"code":"K7Q2M9XD","display":"K7Q2-M9XD","qr":"\#(glassesQR)","expiresAt":"\#(iso(base.addingTimeInterval(300)))","bootId":"boot-1","hosts":[{"host":"100.64.0.10","port":3141,"kind":"tailscale"}],"lanArmedUntil":null,"reason":null,"httpStatus":200}"#
let pairingStatus = #"{"code":{"display":"K7Q2-M9XD","expiresAt":"\#(iso(base.addingTimeInterval(300)))","state":"active"},"pending":null,"lastClaim":null,"firstAuthAfterClaimAt":null,"lanArmedUntil":null,"bootId":"boot-1","reason":null,"httpStatus":200}"#

@MainActor func pairing(_ peers: String) async -> GlassesPairingState {
    let answers = ["tailscale-status": tailscale(peers), "pairing-status": pairingStatus, "pairing-code": pairingCode]
    let state = GlassesPairingState()
    state.now = { base }
    state.runHelper = { args in PairingHelperAnswer(ok: true, message: "", details: Data((answers[args[0]] ?? "{}").utf8)) }
    await state.refreshTailscale()
    return state
}

// MARK: The phone sign-in row above it (UT-29), its QR ready, as in Tests/PhoneSignInRender.swift

let fixtureTicket = "fixtureTicketNotReal_0000000000000000000000"
let handoffReady = #"{"transport":"answered","httpStatus":200,"phone":"ready","phoneUrl":"http://\#(host):3141/control?handoff=\#(fixtureTicket)","expiresAt":"\#(iso(base.addingTimeInterval(120)))"}"#

@MainActor func phoneSignIn() async -> PhoneSignInState {
    let state = PhoneSignInState()
    state.now = { base }
    state.runHelper = { _ in PairingHelperAnswer(ok: true, message: "", details: Data(handoffReady.utf8)) }
    await state.mint()
    return state
}

// MARK: The model (Settings hub fixture values, the server floor's version, nothing loads from a server)

@MainActor func seeded(_ served: Served, peers: String = peersAll) async -> ControllerModel {
    let model = ControllerModel(startBackgroundWork: false)
    var s = model.status
    s.installed = true; s.running = true; s.managedContract = true; s.ownershipVerified = true
    s.runtimeState = "managedHealthy"; s.recoveryInstalled = true; s.recoveryLoaded = true; s.safeToRestart = true
    s.version = PhoneApprovalsSwitch.minimumServer; s.installedVersion = PhoneApprovalsSwitch.minimumServer
    s.activeJobs = 0; s.activeTranscriptionSessions = 0
    s.pairingSupported = true; s.whisperReady = true
    model.status = s
    model.setupGuide.chooseDevicePath(.mac)
    model.webKey = await webKey(served)
    model.glassesPairing = await pairing(peers)
    model.phoneSignIn = await phoneSignIn()
    return model
}

let iphone = PhoneApprovalsSwitch.Phone(name: "example-iphone", ipv4: "100.64.0.11")

/// The hub page's background and environment around one card.
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

/// The Phone and web card in ControlPanel.hubGlasses order (UT-29, PK-02, PK-01, WB-01), with the switch row on one step.
struct PhoneCard: View {
    @ObservedObject var model: ControllerModel
    let row: PhoneApprovalsSwitchRow
    /// The page's confirm, drawn over the whole card as ControlPanel.panelWithPhoneConfirm draws it over the page.
    @ObservedObject var confirm: PhoneApprovalsConfirm
    var body: some View {
        HubPage {
            SettingsHubCard(group: SettingsHubCatalog.group("glasses.phone")!, advancedCount: 0, advancedOpen: .constant(false)) {
                PhoneSignInBlock(model: model, state: model.phoneSignIn, polls: false)
                SettingsHubBlock { row }
                WebKeySettingsBlock(state: model.webKey, refreshes: false)
                SettingsHubWebRevokeRow(model: model, phone: model.phoneSignIn)
            } advanced: { EmptyView() }
        }
        .cosConfirm(
            confirm.shown?.title ?? "Are you sure?",
            isPresented: Binding(get: { confirm.shown != nil }, set: { if !$0 { confirm.shown = nil } }),
            message: confirm.shown?.message ?? "",
            actions: confirm.shown?.actions ?? [.cancel()]
        )
    }
}

@main @MainActor struct PhoneApprovalsRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-home-render") else { fputs("run through Tests/run-phone-approvals-render.sh (a scratch home)\n", stderr); exit(2) }
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var count = 0

        // The renders check their own fixtures first, so a picture can never show a state it does not claim.
        precondition(!SettingsHubCatalog.drawn("PK-02", view: .basic) && SettingsHubCatalog.drawn("PK-02", view: .all), "PK-02 is All only")
        let off = await seeded(.off)
        let pending = await seeded(.on(signerTls: tlsPending))
        let certsOff = await seeded(.on(signerTls: tlsCertsOff))
        let ready = await seeded(.on(signerTls: tlsReady))
        let noPhone = await seeded(.off, peers: peersNoPhone)
        precondition(!off.webKey.visible && !PhoneApprovalsSwitch.isOn(off.webKey.mode), "off fixture")
        precondition(pending.webKey.authority && pending.webKey.anchorRegisteredHere && pending.webKey.signerTLSLine == WebKeySignerTLS.line("pending"), "pending fixture")
        precondition(certsOff.webKey.signerTLSLine == WebKeySignerTLS.certsOff, "certs-off fixture")
        precondition(ready.webKey.authority && ready.webKey.signerTLSLine == nil, "ready fixture")
        let listed = PhoneApprovalsSwitch.phones((off.glassesPairing.tailscale?.peers ?? []).map {
            PhoneApprovalsSwitch.Peer(os: $0.os, dns: $0.dns, ipv4: $0.ipv4, sameUser: $0.sameUser)
        })
        precondition(listed.map(\.name) == ["example-ipad", "example-iphone"], "the picker lists this account's iOS devices only")

        // 0.5.392 (lead ruling 2026-11-12 19:50): phone approvals cannot be turned on from this build. Executes the app's one
        // sender of set-phone-approvals, ControllerModel.setPhoneApprovals, with a recorder in place of the helper (`run`), so
        // nothing here can reach a helper even if the gate breaks. On sends nothing for any phone; Off is sent as before.
        var sent: [[String]] = []
        let record: (String, [String]) -> Void = { command, arguments in sent.append([command] + arguments) }
        for phone in [iphone, PhoneApprovalsSwitch.Phone(name: "example-ipad", ipv4: "100.64.0.21")] {
            off.setPhoneApprovals(on: true, phone: phone, run: record)
            pending.setPhoneApprovals(on: true, phone: phone, run: record)
        }
        off.setPhoneApprovals(on: true, phone: nil, run: record)
        precondition(sent.isEmpty && !off.busy && !pending.busy, "phone approvals unavailable: setPhoneApprovals never sends on, for any phone")
        pending.setPhoneApprovals(on: false, phone: nil, run: record)
        precondition(sent == [["set-phone-approvals", "off"]] && !pending.busy, "phone approvals off stays reachable: setPhoneApprovals sends off")
        print("PASS phone approvals unavailable: setPhoneApprovals sent nothing for on (5 calls) and [set-phone-approvals off] for off")
        // The mount: an off server shows no row in either view; a server that is on shows the Off row in both.
        precondition(!PhoneApprovalsSwitch.mounted(serverVersion: off.status.version, rowDrawn: true, on: PhoneApprovalsSwitch.isOn(off.webKey.mode), pendingOff: false)
                     && PhoneApprovalsSwitch.mounted(serverVersion: pending.status.version, rowDrawn: false, on: PhoneApprovalsSwitch.isOn(pending.webKey.mode), pendingOff: false),
                     "phone approvals mount: none while off, the Off row in Basic and All while on")
        // The Off row's anchor is one Basic never hides (an id the catalog does not know); PK-02 itself is All only.
        precondition(SettingsHubCatalog.drawn(PhoneApprovalsSwitch.anchorID, view: .basic) && SettingsHubCatalog.drawn(PhoneApprovalsSwitch.anchorID, view: .all)
                     && SettingsHubCatalog.item(PhoneApprovalsSwitch.anchorID) == nil, "phone approvals Off row: its anchor draws in Basic and All")
        precondition(PhoneApprovalsSwitch.phones((noPhone.glassesPairing.tailscale?.peers ?? []).map {
            PhoneApprovalsSwitch.Peer(os: $0.os, dns: $0.dns, ipv4: $0.ipv4, sameUser: $0.sameUser)
        }).isEmpty, "no-phone fixture")

        // The whole window, Glasses and iPhone. 0.5.392: no switch for a Mac that is off, in Basic or All; a Mac that is on
        // gets the Off row in both.
        UserDefaults.standard.set(SettingsHubView.basic.rawValue, forKey: SettingsHubView.key)
        count += try page(ControlPanel.hubFixture(model: off, category: .glasses), width: 1280, height: 1100, name: "page-1-basic-no-switch-1280", out: out)
        count += try page(ControlPanel.hubFixture(model: pending, category: .glasses), width: 1280, height: 1400, name: "page-5-basic-on-off-row-1280", out: out)
        UserDefaults.standard.set(SettingsHubView.all.rawValue, forKey: SettingsHubView.key)
        count += try page(ControlPanel.hubFixture(model: off, category: .glasses), width: 1280, height: 1100, name: "page-2-all-no-switch-1280", out: out)
        count += try page(ControlPanel.hubFixture(model: pending, category: .glasses), width: 1280, height: 1400, name: "page-3-all-on-certificate-pending-1280", out: out)
        count += try page(ControlPanel.hubFixture(model: pending, category: .glasses), width: 760, height: 1500, name: "page-4-all-on-certificate-pending-760", out: out)

        // The card, one step each.
        let cardWidth: CGFloat = 720 + 32
        // 0.5.392: the turn-on steps (cards 1 to 5 in 0.5.391) cannot be reached in this build, so they are not drawn.
        let steps: [(String, ControllerModel, PhoneApprovalsSwitchRow.FixtureStep, RestartApply.Work)] = [
            ("card-6-confirm-turn-off", pending, .confirmOff, .init()),
        ]
        for (name, model, step, work) in steps {
            let confirm = PhoneApprovalsConfirm()
            let row = PhoneApprovalsSwitchRow.renderFixture(model: model, state: model.webKey, pairing: model.glassesPairing, work: work,
                                                            confirm: confirm, step: step)
            count += try card(PhoneCard(model: model, row: row, confirm: confirm), width: cardWidth, name: name, out: out)
        }
        for (name, model) in [("card-7-on-https-certificates-off", certsOff), ("card-8-on-certificate-ready", ready)] {
            let confirm = PhoneApprovalsConfirm()
            let row = PhoneApprovalsSwitchRow(model: model, state: model.webKey, pairing: model.glassesPairing, work: .init(), locked: false, confirm: confirm)
            count += try card(PhoneCard(model: model, row: row, confirm: confirm), width: cardWidth, name: name, out: out)
        }

        // The picker's menu is a system menu, which an offscreen render cannot open; this is what it lists.
        print("picker lists: \(listed.map(\.name).joined(separator: ", ")) (not friend-iphone, another account; not example-laptop, a Mac)")
        print("confirm on: \(PhoneApprovalsSwitch.confirmOnTitle(iphone)) | \(PhoneApprovalsSwitch.confirmOnMessage(iphone, macName: off.glassesPairing.tailscale?.selfDNS))")
        print("confirm off: \(PhoneApprovalsSwitch.confirmOffTitle) | \(PhoneApprovalsSwitch.confirmOffMessage)")
        print("amber lines: pending \"\(WebKeySignerTLS.line("pending"))\"; certs off \"\(WebKeySignerTLS.certsOff)\"")
        print("PhoneApprovalsRender wrote \(count) PNGs")
    }

    /// A Settings window at a fixed size, dark then light.
    static func page<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, out: URL) throws -> Int {
        try draw(view.frame(width: width, height: height), width: width, height: height, name: name, out: out)
    }

    /// One card at `width`, as tall as it wants (its fitting height), dark then light.
    static func card<V: View>(_ view: V, width: CGFloat, name: String, out: URL) throws -> Int {
        let sizer = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true).cosControlTheme())
        sizer.layoutSubtreeIfNeeded()
        let height = max(160, ceil(sizer.fittingSize.height))
        return try draw(view.frame(width: width, height: height, alignment: .top), width: width, height: height, name: name, out: out)
    }

    static func draw<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, out: URL) throws -> Int {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            let host = NSHostingView(rootView: view.cosControlTheme())
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
