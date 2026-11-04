import Foundation

// Glasses pairing (contract 2026-10-09, server 6.67.0). Pure: no process is spawned, no file is read and nothing is
// fetched here. `cos-control-helper tailscale-status | tailscale-whois | pairing-code | pairing-status |
// pairing-decision` wire the real calls in (HelperSources/main.swift), and Tests/PairingCoreChecks.swift drives this
// file alone with fixtures from a real `tailscale status --json`. Never a pairing code, nonce or token in a log line.

enum TailscaleCore {
    /// The standalone build (io.tailscale.ipn.macsys) and the App Store build (io.tailscale.ipn.macos) both install
    /// here, and both bundle binaries act as the CLI. `/usr/local/bin/tailscale` is an optional shim: never relied on.
    static let appPath = "/Applications/Tailscale.app"
    static let binaryRelative = "Contents/MacOS/Tailscale"
    static let bundles = ["io.tailscale.ipn.macsys": "standalone", "io.tailscale.ipn.macos": "appStore"]
    static let timeout: TimeInterval = 6

    /// The app folder to use. Only an isolated /tmp test home may point at a stand-in app.
    static func app(environment: [String: String]) -> String {
        if let home = environment["COS_CONTROL_TEST_HOME"], home.hasPrefix("/tmp/"),
           let fake = environment["COS_CONTROL_TEST_TAILSCALE_APP"], fake.hasPrefix("/tmp/") { return fake }
        return appPath
    }

    static func binary(app: String) -> String { (app as NSString).appendingPathComponent(binaryRelative) }

    /// The child's environment. PROVEN 2026-10-08 (bisected over all 68 variables) and re-checked 2026-10-09: without
    /// SHLVL the bundle binary tries to start the GUI, prints "The Tailscale GUI failed to start ... CLIError error 3"
    /// and still exits 0. With SHLVL=1 it acts as the CLI. The helper is started by the app with no SHLVL, so it is
    /// always set here. The rest is a small fixed set: nothing of the helper's own environment leaks through.
    static func childEnvironment(from environment: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] {
            if let value = environment[key], !value.isEmpty { out[key] = value }
        }
        out["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        out["SHLVL"] = "1"
        return out
    }

    struct Peer: Equatable, Sendable {
        var os: String
        var dns: String
        var ipv4: String?
        var online: Bool
        var sameUser: Bool
        var json: [String: Any] {
            ["os": os, "dns": dns, "ipv4": ipv4 ?? NSNull(), "online": online, "sameUser": sameUser]
        }
    }

    struct Status: Equatable, Sendable {
        var installed = false
        var running = false
        var backendState: String?
        var selfIPv4: String?
        var selfDNS: String?
        var peers: [Peer] = []
        var bundle: String?
        var error: String?
        var json: [String: Any] {
            ["installed": installed, "running": running, "backendState": backendState ?? NSNull(),
             "selfIPv4": selfIPv4 ?? NSNull(), "selfDNS": selfDNS ?? NSNull(), "peers": peers.map(\.json),
             "bundle": bundle ?? NSNull(), "error": error ?? NSNull()]
        }
    }

    static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255
                && !(part.count > 1 && part.first == "0")
        }
    }

    /// 100.64.0.0/10, the Tailscale range.
    static func isTailnet(_ value: String) -> Bool {
        guard isIPv4(value) else { return false }
        let octets = value.split(separator: ".").compactMap { Int($0) }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    static func firstIPv4(_ value: Any?) -> String? { (value as? [Any])?.compactMap { $0 as? String }.first(where: isIPv4) }

    /// MagicDNS names end in a dot in the JSON.
    static func cleanDNS(_ value: Any?) -> String? {
        guard var name = value as? String, !name.isEmpty else { return nil }
        while name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? nil : name
    }

    /// The node's own label ("example-iphone" of "example-iphone.tail00000a.ts.net").
    static func shortName(_ dns: String) -> String { String(dns.split(separator: ".").first ?? Substring(dns)) }

    /// The JSON object in the output, which can carry a warning line around it.
    static func jsonObject(_ output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [String: Any]
    }

    /// Self.UserID from `status --json`, for whois's sameUser.
    static func selfUserID(statusOutput: String?) -> String? {
        guard let output = statusOutput, let object = jsonObject(output) else { return nil }
        return userID((object["Self"] as? [String: Any])?["UserID"])
    }

    private static func userID(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        if let text = value as? String, !text.isEmpty { return text }
        return nil
    }

    /// `status --json`. Read: Self.TailscaleIPs (first IPv4), Self.DNSName, BackendState, and per peer OS, DNSName,
    /// TailscaleIPs, Online and UserID == Self.UserID. Never HostName: iOS reports "localhost".
    static func parseStatus(installed: Bool, bundle: String?, output: String?) -> Status {
        var status = Status(installed: installed, bundle: bundle)
        guard installed else { return status }
        guard let output else { status.error = "Tailscale did not answer in time."; return status }
        guard let object = jsonObject(output) else {
            let line = output.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            status.error = line.contains("GUI failed to start") || line.contains("CLIError")
                ? "Tailscale could not be read. Open the Tailscale app once, then check again."
                : line.isEmpty ? "Tailscale gave no status." : String(line.prefix(200))
            return status
        }
        status.backendState = object["BackendState"] as? String
        status.running = status.backendState == "Running"
        let me = object["Self"] as? [String: Any] ?? [:]
        status.selfIPv4 = firstIPv4(me["TailscaleIPs"]) ?? firstIPv4(object["TailscaleIPs"])
        status.selfDNS = cleanDNS(me["DNSName"])
        let myUser = userID(me["UserID"])
        var peers: [Peer] = []
        for case let peer as [String: Any] in (object["Peer"] as? [String: Any] ?? [:]).values {
            guard let dns = cleanDNS(peer["DNSName"]) else { continue }
            let theirs = userID(peer["UserID"])
            peers.append(Peer(os: peer["OS"] as? String ?? "", dns: dns, ipv4: firstIPv4(peer["TailscaleIPs"]),
                              online: peer["Online"] as? Bool == true, sameUser: myUser != nil && theirs == myUser))
        }
        status.peers = peers.sorted { $0.dns < $1.dns }
        return status
    }

    /// `whois --json <ip>` as {found, node, os, user, sameUser}. sameUser: the device's account (UserProfile.ID) is
    /// this Mac's own (status Self.UserID); false when either is unknown. "peer not found" (exit 1) is an answer.
    static func parseWhois(code: Int32?, output: String?, selfUser: String? = nil) -> [String: Any] {
        guard let output else { return ["found": false, "sameUser": false, "error": "Tailscale did not answer in time."] }
        if let object = jsonObject(output), let node = object["Node"] as? [String: Any] {
            let name = cleanDNS(node["Name"]).map(shortName) ?? (node["ComputedName"] as? String) ?? ""
            let os = (node["Hostinfo"] as? [String: Any])?["OS"] as? String
            let profile = object["UserProfile"] as? [String: Any]
            let user = profile?["DisplayName"] as? String
            let theirs = userID(profile?["ID"]) ?? userID(node["User"])
            let same = selfUser != nil && theirs != nil && theirs == selfUser
            return ["found": !name.isEmpty, "node": name, "os": os ?? NSNull(), "user": user ?? NSNull(), "sameUser": same]
        }
        if output.contains("peer not found") { return ["found": false, "sameUser": false] }
        let line = output.split(separator: "\n").first.map(String.init) ?? ""
        return ["found": false, "sameUser": false, "error": String(line.prefix(200))]
    }
}

enum PairingCore {
    /// The server's failure reasons: `PairingReason` in cos-glasses-server server/lib/glasses-pairing.ts (6.67.0), the
    /// one list both sides follow. The helper adds its own three: server_too_old, token_rejected, unreachable.
    static let serverReasons: Set<String> = ["expired", "used", "locked", "rate_limited", "not_loopback", "not_allowed_network",
                                             "unknown_code", "denied", "draining", "bad_request"]

    /// `capabilities.pairing = { version: 1 }` in /api/health. Missing means a server older than 6.67.0.
    static func supported(health: [String: Any]?) -> Bool {
        guard let pairing = (health?["capabilities"] as? [String: Any])?["pairing"] as? [String: Any],
              let version = pairing["version"] as? NSNumber else { return false }
        return version.intValue >= 1
    }

    /// Made by the phone: 16 to 64 characters from [A-Za-z0-9_-].
    static func validNonce(_ value: String) -> Bool {
        (16...64).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 45 || byte == 95
        }
    }

    static func decision(_ word: String) -> Bool? { word == "allow" ? true : word == "deny" ? false : nil }

    static func codeBody(allowLan: Bool) -> String { allowLan ? #"{"allowLan":true}"# : #"{"allowLan":false}"# }

    static func decisionBody(nonce: String, allow: Bool) -> String? {
        guard validNonce(nonce) else { return nil }
        return #"{"nonce":"\#(nonce)","allow":\#(allow)}"#
    }

    /// The server's answer as the helper's details: the body as it came on success, else `reason` (the server's own when
    /// it is one of the contract's, `server_too_old` for a bare 404, `token_rejected` for 401, `http_<n>` otherwise) and
    /// its message. Every answer has `reason` (null on success) and `httpStatus`, so the app never reads an error as data.
    static func answer(status: Int?, body: [String: Any]?) -> [String: Any] {
        guard let status else {
            return ["reason": "unreachable", "httpStatus": NSNull(), "message": "The COS server did not answer. Check that it is running."]
        }
        if (200...299).contains(status) {
            var details = body ?? [:]
            details["reason"] = NSNull()
            details["httpStatus"] = status
            return details
        }
        let given = body?["reason"] as? String
        let reason: String
        if let given, serverReasons.contains(given) { reason = given }
        else if status == 404 { reason = "server_too_old" }
        else if status == 401 { reason = "token_rejected" }
        else { reason = "http_\(status)" }
        let message = (body?["message"] as? String).map { String($0.prefix(300)) } ?? message(reason)
        return ["reason": reason, "httpStatus": status, "message": message]
    }

    static func message(_ reason: String) -> String {
        switch reason {
        case "server_too_old": "Pairing needs server 6.67 or newer. Update the server."
        case "token_rejected": "The server refused this Mac's pairing token."
        case "draining": "The server is restarting. Try again in a moment."
        case "rate_limited": "Too many tries. Wait a minute."
        case "expired": "That request expired."
        case "used": "That was already decided."
        case "unknown_code": "That request is no longer waiting."
        default: "Pairing was refused (\(reason))."
        }
    }
}

// MARK: - Open COS on your phone (0.5.367, server 6.99.3)
//
// `cos-control-helper web-handoff` and `web-device-code` (HelperSources/main.swift) POST these two loopback routes with the
// pairing token, behind the same managed-server check as Copy token, and pass only what this maps. Pure, so
// Tests/PairingCoreChecks.swift drives it alone. SECRET BOUNDARY: the phone link carries a one-use sign-in ticket and the code
// signs a browser in. Both go to stdout for the app and nowhere else: never a progress line, a log or a message. The token never
// leaves the helper.
enum WebSignInCore {
    /// One ticket, single use, 2 minutes. `phoneUrl` (6.99.3) is the tailnet link for the QR; older servers send only `url`.
    static let handoffPath = "/api/web-session/handoff"
    /// "XXXX-XXXX", single use, 5 minutes (6.99.1).
    static let deviceCodePath = "/api/web-session/device-code"

    /// A 404 is a server without the route, so it needs a newer server. Any other status is the server's answer.
    static func transport(status: Int) -> String { status == 404 ? "unsupported" : "answered" }

    /// The server's refusal code (`error` or `reason`), never its text.
    static func errorCode(_ body: [String: Any]?) -> String? {
        for key in ["error", "reason"] {
            if let text = body?[key] as? String, text.range(of: #"\A[a-z_]{1,64}\z"#, options: .regularExpression) != nil { return text }
        }
        return nil
    }

    /// An ISO 8601 time the app can read, as the server sent it.
    static func expiry(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty, text.count <= 40 else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) != nil || ISO8601DateFormatter().date(from: text) != nil ? text : nil
    }

    /// A MagicDNS name, as the server keeps it (normalizeTailscaleDnsName): lower case labels under .ts.net.
    static func tailnetName(_ host: String) -> Bool {
        host.count <= 253
            && host.range(of: #"\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\.ts\.net\z"#,
                          options: .regularExpression) != nil
    }

    /// The link the QR may carry: http or https, a tailnet host (100.64.0.0/10 or a name under .ts.net, so the QR only works on
    /// the person's tailnet), the /control page, and exactly one query item, `handoff`, in the server's ticket grammar. When the
    /// answer names its ticket, the link must carry that one. No user, password or fragment.
    static func phoneURLValid(_ text: String, ticket: String?) -> Bool {
        guard text.utf8.count <= 512, let parts = URLComponents(string: text),
              let scheme = parts.scheme, scheme == "http" || scheme == "https",
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let host = parts.host, TailscaleCore.isTailnet(host) || tailnetName(host),
              parts.path == "/control",
              let items = parts.queryItems, items.count == 1, items[0].name == "handoff",
              let value = items[0].value, value.range(of: #"\A[A-Za-z0-9_-]{24,64}\z"#, options: .regularExpression) != nil else { return false }
        return ticket.map { $0 == value } ?? true
    }

    /// `web-handoff`'s details. Always `transport` and `httpStatus`. A 200 adds `phone`: `ready` with `phoneUrl` and `expiresAt`;
    /// `no_tailnet` (phoneUrl null: this Mac has no tailnet address); `needs_update` (no phoneUrl at all: a server before 6.99.3);
    /// `unreadable` for anything else. Never the loopback `url`, the `tailnet` pair or the bare ticket: the QR shows one link only,
    /// since the sign-in cookie belongs to the origin it was opened on. Another status adds the server's `error` code.
    static func handoffAnswer(status: Int, body: [String: Any]?) -> [String: Any] {
        var out: [String: Any] = ["transport": transport(status: status), "httpStatus": status]
        guard status == 200 else {
            if let code = errorCode(body) { out["error"] = code }
            return out
        }
        guard let body, body["ok"] as? Bool != false else { out["phone"] = "unreadable"; return out }
        guard body.keys.contains("phoneUrl") else { out["phone"] = "needs_update"; return out }
        if body["phoneUrl"] is NSNull { out["phone"] = "no_tailnet"; return out }
        guard let link = body["phoneUrl"] as? String, phoneURLValid(link, ticket: body["ticket"] as? String),
              let expiresAt = expiry(body["expiresAt"]) else { out["phone"] = "unreadable"; return out }
        out["phone"] = "ready"
        out["phoneUrl"] = link
        out["expiresAt"] = expiresAt
        return out
    }

    /// `web-device-code`'s details. Always `transport` and `httpStatus`. A 200 adds `code` ("XXXX-XXXX", Crockford letters and
    /// digits) and `expiresAt`, or `unreadable: true`. Another status adds the server's `error` code.
    static func deviceCodeAnswer(status: Int, body: [String: Any]?) -> [String: Any] {
        var out: [String: Any] = ["transport": transport(status: status), "httpStatus": status]
        guard status == 200 else {
            if let code = errorCode(body) { out["error"] = code }
            return out
        }
        guard let body, body["ok"] as? Bool != false, let code = body["code"] as? String,
              code.range(of: #"\A[0-9A-Z]{4}-[0-9A-Z]{4}\z"#, options: .regularExpression) != nil,
              let expiresAt = expiry(body["expiresAt"]) else { out["unreadable"] = true; return out }
        out["code"] = code
        out["expiresAt"] = expiresAt
        return out
    }
}
