import AppKit
import SwiftUI

// Offscreen renders of the setup guide's Glasses section (contract 2026-10-09), light and dark, at the panel's width
// (390 pt): Tailscale not installed, the phone missing, the QR shown, a claim waiting for Allow, paired, and a server
// too old for pairing. The state comes from fixture helper answers, never the helper; no window is ordered in, nothing
// is opened, and the section's own poll is off (polls: false).

let base = Date(timeIntervalSince1970: 1_791_000_000)
func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date)
}
func tailscale(installed: Bool = true, running: Bool = true, phone: Bool = true) -> String {
    let peers = installed ? #"[{"os":"iOS","dns":"example-iphone.tail00000a.ts.net","ipv4":"100.64.0.11","online":\#(phone),"sameUser":true},{"os":"macOS","dns":"example-laptop.tail00000a.ts.net","ipv4":"100.64.0.12","online":false,"sameUser":true}]"# : "[]"
    return #"{"installed":\#(installed),"running":\#(running),"backendState":\#(installed ? (running ? "\"Running\"" : "\"NeedsLogin\"") : "null"),"selfIPv4":\#(running ? "\"100.64.0.10\"" : "null"),"selfDNS":\#(running ? "\"example-mac.tail00000a.ts.net\"" : "null"),"peers":\#(peers),"bundle":"standalone","error":null}"#
}
func code(qr: Bool = true) -> String {
    #"{"code":"K7Q2M9XD","display":"K7Q2-M9XD","qr":\#(qr ? "\"COS1/MAC/K7Q2M9XD/100.64.0.10:3141/T3LQ5K\"" : "null"),"expiresAt":"\#(iso(base.addingTimeInterval(300)))","bootId":"boot-1","hosts":\#(qr ? #"[{"host":"100.64.0.10","port":3141,"kind":"tailscale"}]"# : "[]"),"lanArmedUntil":null,"reason":null,"httpStatus":200}"#
}
func status(pending: String? = nil, claim: Bool = false, firstAuth: Bool = false) -> String {
    let p = pending.map { #"{"nonce":"nonce-abcdefghijklmnop","ip":"\#($0)","at":"\#(iso(base))"}"# } ?? "null"
    let c = claim ? #"{"ip":"100.64.0.11","at":"\#(iso(base.addingTimeInterval(-60)))","allowed":true}"# : "null"
    let f = firstAuth ? "\"\(iso(base.addingTimeInterval(-55)))\"" : "null"
    return #"{"code":{"display":"K7Q2-M9XD","expiresAt":"\#(iso(base.addingTimeInterval(300)))","state":"active"},"pending":\#(p),"lastClaim":\#(c),"firstAuthAfterClaimAt":\#(f),"lanArmedUntil":null,"bootId":"boot-1","reason":null,"httpStatus":200}"#
}
let whois = #"{"found":true,"node":"example-iphone","os":"iOS","user":"Alex Example","sameUser":true}"#
let whoisOther = #"{"found":true,"node":"guest-iphone","os":"iOS","user":"Someone Else","sameUser":false}"#

@MainActor func seeded(_ answers: [String: String], running: Bool = true, supported: Bool = true) async -> ControllerModel {
    let model = ControllerModel(startBackgroundWork: false)
    model.status = ServerStatus(["installed": .bool(true), "running": .bool(running), "pairingSupported": .bool(supported)])
    model.status.running = running; model.status.pairingSupported = supported
    model.status.installed = true; model.status.managedContract = true; model.status.ownershipVerified = true; model.status.version = "6.66.0"
    let pairing = GlassesPairingState()
    pairing.now = { base }
    pairing.runHelper = { args in
        let key = args[0] == "tailscale-whois" ? "whois" : args[0]
        return PairingHelperAnswer(ok: true, message: "", details: Data((answers[key] ?? "{}").utf8))
    }
    await pairing.tick(index: 0, serverRunning: running, pairingSupported: supported)
    model.glassesPairing = pairing
    return model
}

struct GlassesCard: View {
    @ObservedObject var model: ControllerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Glasses").font(COSType.body(13, weight: .semibold)).padding(.bottom, 2)
            VStack(alignment: .leading, spacing: 0) {
                GlassesSetupRows(model: model, pairing: model.glassesPairing, openURL: { _ in }, polls: false)
            }
            .padding(.horizontal, 12)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line, lineWidth: 1))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(COSPalette.panel)
    }
}

@main @MainActor struct GlassesPairingRender {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard NSHomeDirectory().contains("cos-home-render") else { exit(2) }
        let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let cases: [(String, [String: String], Bool, Bool, CGFloat)] = [
            ("glasses-1-tailscale-not-installed", ["tailscale-status": tailscale(installed: false, running: false), "pairing-status": status(), "pairing-code": code(qr: false)], true, true, 600),
            ("glasses-2-phone-missing", ["tailscale-status": tailscale(phone: false), "pairing-status": status(), "pairing-code": code()], true, true, 1000),
            ("glasses-3-qr-shown", ["tailscale-status": tailscale(), "pairing-status": status(), "pairing-code": code()], true, true, 680),
            ("glasses-4-pending-allow", ["tailscale-status": tailscale(), "pairing-status": status(pending: "100.64.0.11"), "pairing-code": code(), "whois": whois], true, true, 380),
            ("glasses-5-paired", ["tailscale-status": tailscale(), "pairing-status": status(claim: true, firstAuth: true), "pairing-code": code(), "whois": whois], true, true, 300),
            ("glasses-7-pending-other-account", ["tailscale-status": tailscale(), "pairing-status": status(pending: "100.64.0.13"), "pairing-code": code(), "whois": whoisOther], true, true, 420),
            ("glasses-6-server-too-old", ["tailscale-status": tailscale(), "pairing-status": status(), "pairing-code": code()], true, false, 340),
        ]
        for (name, answers, running, supported, height) in cases {
            let model = await seeded(answers, running: running, supported: supported)
            if name.contains("paired") || name.contains("pending") {
                // The paired and pending states fetch their status after the code: one more poll, as on screen.
                await model.glassesPairing.tick(index: 1, serverRunning: running, pairingSupported: supported)
            }
            try render(GlassesCard(model: model), width: 390, height: height, name: name, out: out)
        }
        // The QR's own size: version 3 or 4 for the contract grammar, drawn at least 220 pt.
        let modules = QRImage.modules("COS1/MAC/K7Q2M9XD/100.64.0.10:3141/T3LQ5K") ?? 0
        print("pairing QR modules per side (with margin): \(modules)")
        print("GlassesPairingRender wrote \(cases.count * 2) PNGs")
    }

    static func render<V: View>(_ view: V, width: CGFloat, height: CGFloat, name: String, out: URL) throws {
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
    }
}
