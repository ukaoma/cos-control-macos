import Foundation

// Glasses pairing (HelperSources/PairingCore.swift) compiled on its own against fixtures cut from a real
// `tailscale status --json` and `whois --json` (1.102.2 on a test Mac, 2026-10-09): Self, the iOS peer whose
// HostName is "localhost", an offline macOS peer, the SHLVL child environment, whois incl. "peer not found", and the
// pairing answer mapping for every contract reason. Nothing runs Tailscale or reaches a server.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ condition: Bool, _ behaviour: String, _ detail: @autoclosure () -> String = "") {
    if condition { passes += 1; return }
    failures += 1
    FileHandle.standardError.write(Data("check failed [\(behaviour)]: \(detail())\n".utf8))
}

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
func fixture(_ name: String) -> String { (try? String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)) ?? "" }

@main
enum PairingCoreChecks {
    static func main() {
        statusParsing()
        environment()
        whois()
        addresses()
        answers()
        if failures > 0 {
            FileHandle.standardError.write(Data("Pairing core checks: \(failures) failed, \(passes) passed\n".utf8))
            exit(1)
        }
        print("Pairing core checks: \(passes) passed")
    }

    static func statusParsing() {
        let real = fixture("tailscale-status-running.json")
        check(!real.isEmpty, "fixture", "tailscale-status-running.json is readable")
        let s = TailscaleCore.parseStatus(installed: true, bundle: "standalone", output: real)
        check(s.running && s.backendState == "Running", "status running", "\(s)")
        check(s.selfIPv4 == "100.64.0.10", "self ipv4", "the first IPv4, never the IPv6: \(s.selfIPv4 ?? "nil")")
        check(s.selfDNS == "example-mac.tail00000a.ts.net", "self dns", "trailing dot removed: \(s.selfDNS ?? "nil")")
        let phone = s.peers.first { $0.os == "iOS" }
        check(phone?.dns == "example-iphone.tail00000a.ts.net" && phone?.ipv4 == "100.64.0.11" && phone?.online == true && phone?.sameUser == true,
              "ios peer", "named by DNSName, same user: \(String(describing: phone))")
        check(!s.peers.contains { $0.dns.contains("localhost") }, "never HostName", "iOS HostName is localhost")
        let air = s.peers.first { $0.dns.hasPrefix("example-laptop") }
        check(air?.online == false && air?.os == "macOS" && air?.sameUser == true, "offline peer", "\(String(describing: air))")
        check(TailscaleCore.shortName(phone?.dns ?? "") == "example-iphone", "short name", "first label")
        // sameUser: a peer from another account on a shared tailnet is not this person's phone.
        var object = (try? JSONSerialization.jsonObject(with: Data(real.utf8))) as? [String: Any] ?? [:]
        var peers = object["Peer"] as? [String: Any] ?? [:]
        peers["nodekey:ff"] = ["DNSName": "guest-iphone.tail00000a.ts.net.", "OS": "iOS", "UserID": 2002, "Online": true,
                               "TailscaleIPs": ["100.90.1.2"], "HostName": "localhost"]
        object["Peer"] = peers
        let shared = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let t = TailscaleCore.parseStatus(installed: true, bundle: nil, output: shared)
        check(t.peers.first { $0.dns.hasPrefix("guest-iphone") }?.sameUser == false, "same user filter", "another account's phone is not sameUser")
        check(t.peers.filter(\.sameUser).count == 2, "same user filter", "\(t.peers.map { "\($0.dns)=\($0.sameUser)" })")
        // Self with no UserID: nothing is "same user".
        var anonymous = object
        var me = anonymous["Self"] as? [String: Any] ?? [:]; me["UserID"] = nil; anonymous["Self"] = me
        let anon = TailscaleCore.parseStatus(installed: true, bundle: nil,
                                             output: String(decoding: try! JSONSerialization.data(withJSONObject: anonymous), as: UTF8.self))
        check(!anon.peers.contains { $0.sameUser }, "same user filter", "no Self.UserID: nobody matches (nil == nil is not a match)")
        // Neither side has a UserID (an old or odd tailscaled): still not the same user (mutation 2026-10-09 found this unpinned).
        let bothMissing = #"{"BackendState":"Running","Self":{"DNSName":"mac.ts.net.","TailscaleIPs":["100.100.1.1"]},"Peer":{"k":{"DNSName":"phone.ts.net.","OS":"iOS","Online":true,"TailscaleIPs":["100.100.1.2"]}}}"#
        let neither = TailscaleCore.parseStatus(installed: true, bundle: nil, output: bothMissing)
        check(neither.peers.count == 1 && neither.peers[0].sameUser == false, "same user filter", "no UserID on either side is never a match: \(neither.peers)")
        // Signed out, not installed, the GUI failure that exits 0, a timeout, a warning line before the JSON.
        let needsLogin = TailscaleCore.parseStatus(installed: true, bundle: nil, output: #"{"BackendState":"NeedsLogin","Self":{},"Peer":null}"#)
        check(!needsLogin.running && needsLogin.backendState == "NeedsLogin" && needsLogin.peers.isEmpty && needsLogin.error == nil, "signed out", "\(needsLogin)")
        let missing = TailscaleCore.parseStatus(installed: false, bundle: nil, output: nil)
        check(!missing.installed && !missing.running && missing.error == nil, "not installed", "\(missing)")
        let gui = TailscaleCore.parseStatus(installed: true, bundle: "standalone",
                                            output: "The Tailscale GUI failed to start: The operation couldn’t be completed. (Tailscale.CLIError error 3.)\n")
        check(!gui.running && gui.error?.contains("Open the Tailscale app") == true, "gui failure", "exit 0 but no JSON: \(gui.error ?? "nil")")
        let late = TailscaleCore.parseStatus(installed: true, bundle: nil, output: nil)
        check(late.error == "Tailscale did not answer in time." && !late.running, "timeout", "\(late)")
        let warned = TailscaleCore.parseStatus(installed: true, bundle: nil, output: "Warning: client version \"1.1\" != tailscaled server version \"1.2\"\n" + real)
        check(warned.running && warned.selfIPv4 == "100.64.0.10", "warning line", "JSON found after a warning")
        let json = s.json
        check(Set(json.keys) == ["installed", "running", "backendState", "selfIPv4", "selfDNS", "peers", "bundle", "error"], "status json keys", "\(json.keys.sorted())")
        let peerKeys = Set(((json["peers"] as? [[String: Any]])?.first ?? [:]).keys)
        check(peerKeys == ["os", "dns", "ipv4", "online", "sameUser"], "peer json keys", "\(peerKeys.sorted())")
        check(JSONSerialization.isValidJSONObject(json), "status json", "serializable")
        check(TailscaleCore.bundles["io.tailscale.ipn.macos"] == "appStore" && TailscaleCore.bundles["io.tailscale.ipn.macsys"] == "standalone",
              "bundles", "App Store and standalone builds")
        check(TailscaleCore.binary(app: TailscaleCore.appPath) == "/Applications/Tailscale.app/Contents/MacOS/Tailscale", "binary", "the bundle binary, not /usr/local/bin")
    }

    static func environment() {
        let bare = TailscaleCore.childEnvironment(from: ["HOME": "/Users/x", "PATH": "/opt/evil/bin", "COS_API_TOKEN": "secret", "DYLD_INSERT_LIBRARIES": "/x.dylib"])
        check(bare["SHLVL"] == "1", "shlvl", "set even when the helper has none: \(bare)")
        check(bare["COS_API_TOKEN"] == nil && bare["DYLD_INSERT_LIBRARIES"] == nil, "child env", "nothing else leaks: \(bare.keys.sorted())")
        check(bare["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin" && bare["HOME"] == "/Users/x", "child env", "fixed PATH, HOME kept")
        check(TailscaleCore.childEnvironment(from: ["SHLVL": "7"])["SHLVL"] == "1", "shlvl", "always 1")
        check(TailscaleCore.app(environment: ["COS_CONTROL_TEST_TAILSCALE_APP": "/tmp/fake.app"]) == TailscaleCore.appPath, "test override", "needs a /tmp test home")
        check(TailscaleCore.app(environment: ["COS_CONTROL_TEST_HOME": "/Users/x", "COS_CONTROL_TEST_TAILSCALE_APP": "/tmp/fake.app"]) == TailscaleCore.appPath, "test override", "home outside /tmp")
        check(TailscaleCore.app(environment: ["COS_CONTROL_TEST_HOME": "/tmp/h", "COS_CONTROL_TEST_TAILSCALE_APP": "/tmp/fake.app"]) == "/tmp/fake.app", "test override", "isolated")
        check(TailscaleCore.app(environment: ["COS_CONTROL_TEST_HOME": "/tmp/h", "COS_CONTROL_TEST_TAILSCALE_APP": "/Applications/Other.app"]) == TailscaleCore.appPath, "test override", "stand-in under /tmp only")
    }

    static func whois() {
        let me = TailscaleCore.selfUserID(statusOutput: fixture("tailscale-status-running.json"))
        check(me == "1001", "self user", "\(me ?? "nil")")
        check(TailscaleCore.parseWhois(code: 0, output: fixture("tailscale-whois-iphone.json"), selfUser: "1001")["sameUser"] as? Bool == true, "whois same user", "your own account")
        check(TailscaleCore.parseWhois(code: 0, output: fixture("tailscale-whois-iphone.json"), selfUser: "2002")["sameUser"] as? Bool == false, "whois same user", "another account")
        check(TailscaleCore.parseWhois(code: 0, output: fixture("tailscale-whois-iphone.json"), selfUser: nil)["sameUser"] as? Bool == false, "whois same user", "Self unknown: never yours")
        check(TailscaleCore.parseWhois(code: 0, output: #"{"Node":{"Name":"x.ts.net."},"UserProfile":{}}"#, selfUser: "1001")["sameUser"] as? Bool == false, "whois same user", "device account unknown: never yours")
        check(TailscaleCore.selfUserID(statusOutput: "The Tailscale GUI failed to start") == nil, "self user", "no JSON")
        check(TailscaleCore.parseWhois(code: 0, output: #"{"Node":{"Name":"x.ts.net."},"UserProfile":{}}"#, selfUser: nil)["sameUser"] as? Bool == false, "whois same user", "neither account known: never yours (nil == nil is not a match)")
        let found = TailscaleCore.parseWhois(code: 0, output: fixture("tailscale-whois-iphone.json"))
        check(found["found"] as? Bool == true && found["node"] as? String == "example-iphone" && found["os"] as? String == "iOS"
              && found["user"] as? String == "Alex Example", "whois", "\(found)")
        check(found["login"] == nil && !String(describing: found).contains("example.com") && !String(describing: found).contains("localhost"),
              "whois privacy", "no login email, no HostName")
        let none = TailscaleCore.parseWhois(code: 1, output: "2026/10/09 07:31:15 peer not found\n")
        check(none["found"] as? Bool == false && none["error"] == nil, "peer not found", "an answer, not an error: \(none)")
        check(none["sameUser"] as? Bool == false, "peer not found", "never yours")
        let late = TailscaleCore.parseWhois(code: nil, output: nil)
        check(late["found"] as? Bool == false && late["error"] != nil, "whois timeout", "\(late)")
        let computed = TailscaleCore.parseWhois(code: 0, output: #"{"Node":{"ComputedName":"pixel-9","Hostinfo":{"OS":"android"}},"UserProfile":{}}"#)
        check(computed["node"] as? String == "pixel-9" && computed["user"] is NSNull, "whois fallback", "\(computed)")
    }

    static func addresses() {
        for good in ["100.64.0.1", "100.127.255.254", "100.64.0.10"] { check(TailscaleCore.isTailnet(good), "tailnet", good) }
        for bad in ["100.63.255.255", "100.128.0.1", "192.168.1.20", "10.0.0.1", "100.64.0", "100.064.0.1", "١٠٠.64.0.1", "100.64.0.1 "] {
            check(!TailscaleCore.isTailnet(bad), "tailnet", bad)
        }
        for bad in ["1.2.3", "256.1.1.1", "a.b.c.d", "1.2.3.4.5", "", "01.2.3.4", "1..2.3", "fd7a::1"] { check(!TailscaleCore.isIPv4(bad), "ipv4", bad) }
        check(TailscaleCore.isIPv4("192.168.1.204") && TailscaleCore.isIPv4("0.0.0.0"), "ipv4", "dotted quads")
        check(TailscaleCore.firstIPv4(["fd7a:115c:a1e0::a", "100.64.0.10"]) == "100.64.0.10", "first ipv4", "skips IPv6")
        check(TailscaleCore.cleanDNS("a.b.ts.net.") == "a.b.ts.net" && TailscaleCore.cleanDNS("") == nil && TailscaleCore.cleanDNS(".") == nil, "dns", "")
    }

    static func answers() {
        check(PairingCore.supported(health: ["capabilities": ["pairing": ["version": 1]]]), "capability", "version 1")
        check(!PairingCore.supported(health: ["capabilities": ["transcription": [:]]]) && !PairingCore.supported(health: nil)
              && !PairingCore.supported(health: ["capabilities": ["pairing": ["version": 0]]])
              && !PairingCore.supported(health: ["capabilities": ["pairing": true]]), "capability gate", "missing, nil, 0 and malformed are unsupported")
        check(PairingCore.validNonce(String(repeating: "a", count: 16)) && PairingCore.validNonce("Ab_-" + String(repeating: "9", count: 60)), "nonce", "16 to 64")
        for bad in [String(repeating: "a", count: 15), String(repeating: "a", count: 65), "aaaaaaaaaaaaaaa\"", "aaaaaaaaaaaaaaaa,\"allow\":true", "ąaaaaaaaaaaaaaaa", "aaaaaaaa aaaaaaaa"] {
            check(!PairingCore.validNonce(bad), "nonce", bad)
            check(PairingCore.decisionBody(nonce: bad, allow: true) == nil, "decision body", "refused before the server: \(bad)")
        }
        let body = PairingCore.decisionBody(nonce: String(repeating: "n", count: 20), allow: false)
        let decoded = body.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        check(decoded?["nonce"] as? String == String(repeating: "n", count: 20) && decoded?["allow"] as? Bool == false, "decision body", body ?? "nil")
        check(PairingCore.decision("allow") == true && PairingCore.decision("deny") == false && PairingCore.decision("yes") == nil, "decision words", "")
        check(PairingCore.codeBody(allowLan: true) == #"{"allowLan":true}"# && PairingCore.codeBody(allowLan: false) == #"{"allowLan":false}"#, "code body", "")
        // Success: the body as it came, with reason null.
        let code: [String: Any] = ["code": "K7Q2M9XD", "display": "K7Q2-M9XD", "qr": "COS1/MAC/K7Q2M9XD/100.64.0.10:3141/T3ABCD",
                                   "expiresAt": "2026-10-09T12:40:00.000Z", "bootId": "b1", "hosts": [["host": "100.64.0.10", "port": 3141, "kind": "tailscale"]],
                                   "lanArmedUntil": NSNull()]
        let ok = PairingCore.answer(status: 200, body: code)
        check(ok["reason"] is NSNull && ok["httpStatus"] as? Int == 200 && ok["display"] as? String == "K7Q2-M9XD" && ok["qr"] as? String != nil, "answer ok", "\(ok)")
        check(PairingCore.answer(status: 202, body: ["pending": true])["reason"] is NSNull, "answer 202", "")
        // Every contract reason passes through; an unknown reason string is never trusted.
        let table: [(Int, String)] = [(410, "expired"), (409, "used"), (409, "locked"), (429, "rate_limited"), (403, "not_loopback"),
                                      (403, "not_allowed_network"), (404, "unknown_code"), (403, "denied"), (503, "draining"), (400, "bad_request")]
        for (status, reason) in table {
            let a = PairingCore.answer(status: status, body: ["reason": reason, "message": "m"])
            check(a["reason"] as? String == reason && a["httpStatus"] as? Int == status && a["message"] as? String == "m", "answer \(reason)", "\(a)")
        }
        check(PairingCore.answer(status: 404, body: nil)["reason"] as? String == "server_too_old", "too old", "a bare 404 is an old server")
        check(PairingCore.answer(status: 404, body: ["error": "Not found"])["reason"] as? String == "server_too_old", "too old", "a 404 without a reason")
        check(PairingCore.answer(status: 404, body: ["reason": "rm -rf"])["reason"] as? String == "server_too_old", "unknown reason", "never trusted")
        check(PairingCore.answer(status: 401, body: ["reason": "pairing_token_rejected"])["reason"] as? String == "token_rejected", "401", "")
        check(PairingCore.answer(status: 500, body: nil)["reason"] as? String == "http_500", "500", "")
        let none = PairingCore.answer(status: nil, body: nil)
        check(none["reason"] as? String == "unreachable" && none["httpStatus"] is NSNull, "unreachable", "\(none)")
        check(PairingCore.answer(status: 409, body: ["reason": "used"])["code"] == nil, "failure body", "a refusal never carries data fields")
        for reason in PairingCore.serverReasons.sorted() + ["server_too_old", "token_rejected", "unreachable"] {
            check(!PairingCore.message(reason).isEmpty && !PairingCore.message(reason).contains("—"), "messages", reason)
        }
    }
}
