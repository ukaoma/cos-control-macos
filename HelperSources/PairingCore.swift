import Foundation
import CryptoKit
import Security

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

/// Phone approvals (server 6.99.31, flag COS_WEB_KEY_AUTHORITY, default off). `cos-control-helper web-key --op <op>` carries
/// COS Control's calls to /api/web-key/* over loopback with the pairing token (the helper reads it; the app never does).
/// Pure: the op table, the stdin bodies it accepts and the answer it emits. Tests/WebKeyChecks.swift drives it.
enum WebKeyHelperCore {
    struct Call: Equatable {
        let method: String
        let path: String
        /// The exact keys a stdin body must have (every value a short string), or nil for no body.
        let bodyKeys: Set<String>?
    }

    static let calls: [String: Call] = [
        "status": Call(method: "GET", path: "/api/web-key/status", bodyKeys: nil),
        "pending": Call(method: "GET", path: "/api/web-key/enroll/pending", bodyKeys: nil),
        "keys": Call(method: "GET", path: "/api/web-key/keys", bodyKeys: nil),
        // Review B1: the anchor's self-signed statement. The route takes loopback, no proxy headers, and the token.
        "anchor": Call(method: "POST", path: "/api/web-key/anchor", bodyKeys: ["anchorPub", "statement", "signature"]),
        "approve": Call(method: "POST", path: "/api/web-key/enroll/approve", bodyKeys: ["enrollId", "anchorSig"]),
        "revoke": Call(method: "POST", path: "/api/web-key/revoke", bodyKeys: ["kid", "reason"]),
        "revoke-all": Call(method: "POST", path: "/api/web-key/revoke-all", bodyKeys: []),
    ]
    /// The listener audit (review W9) is local, not a server call. `anchor-listeners` (0.5.383) is bootstrap's narrower
    /// audit for anchor registration alone: 3141 and 3143, no 3144 and no signer files (authority off serves no signer).
    static let ops: Set<String> = Set(calls.keys).union(["listeners", "anchor-listeners"])
    static let auditPorts = [3141, 3143, 3144]
    static let anchorAuditPorts = [3141, 3143]
    static let bodyMax = 4_096

    /// The JSON body to send, or nil when stdin is not exactly the op's shape: an object with the op's keys only, each value
    /// a string of 1 to 2048 characters from the base64url alphabet (plus `_` and lower case for `reason`).
    static func body(op: String, stdin: Data) -> String? {
        guard let call = calls[op], let keys = call.bodyKeys, stdin.count <= bodyMax,
              let object = (try? JSONSerialization.jsonObject(with: stdin.isEmpty ? Data("{}".utf8) : stdin)) as? [String: Any],
              Set(object.keys) == keys else { return nil }
        for (key, value) in object {
            guard let text = value as? String, !text.isEmpty, text.count <= 2048 else { return nil }
            let pattern = key == "reason" ? #"\A[a-z_]{1,64}\z"# : #"\A[A-Za-z0-9_-]+\z"#
            guard text.range(of: pattern, options: .regularExpression) != nil else { return nil }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// What the app reads: the HTTP status and the server's JSON body as it came.
    static func answer(status: Int, body: [String: Any]?) -> [String: Any] {
        ["transport": "answered", "httpStatus": status, "body": body ?? [:]]
    }

    /// The listener audit's answer: the COS LaunchAgent's PID, and for each audited port every PID listening on it on any
    /// address, each with whether it runs under that LaunchAgent.
    static func listeners(servicePID: Int?, owners: [Int: [Int]], underService: (Int) -> Bool, ports audited: [Int] = auditPorts) -> [String: Any] {
        var ports: [String: Any] = [:]
        for port in audited {
            ports[String(port)] = (owners[port] ?? []).sorted().map { pid -> [String: Any] in ["pid": pid, "underService": underService(pid)] }
        }
        return ["servicePID": servicePID ?? 0, "ports": ports]
    }

    /// Bootstrap's anchor-scope answer: the same rows for 3141 and 3143 only, marked `scope: anchor`, with `stable` false
    /// when the service PID or any listener changed between the two lsof passes. It never carries signer `assets`.
    static func anchorListeners(servicePID: Int?, owners: [Int: [Int]], underService: (Int) -> Bool, stable: Bool) -> [String: Any] {
        var details = listeners(servicePID: servicePID, owners: owners, underService: underService, ports: anchorAuditPorts)
        details["scope"] = "anchor"
        details["stable"] = stable
        return details
    }
}

/// Trust comes from a resource sealed inside the signed Control bundle, never from the running server or active.json.
/// This module only parses and compares bytes. The helper owns signature validation, safe file reads and HTTPS.
enum WebKeyAssetsCore {
    struct Pins: Equatable, Sendable {
        let webControlManifestSha256: String
        let webSignerManifestSha256: String
    }
    static let resourceName = "web-key-assets.json"
    static let signerPaths: Set<String> = ["/index.html", "/signer-proof.js", "/signer-store.js", "/signer.js", "/signer.css"]
    static let maximumFileBytes = 8 * 1024 * 1024
    static let maximumTreeBytes = 64 * 1024 * 1024
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hex(_ value: Any?) -> String? {
        guard let text = value as? String, text.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil else { return nil }
        return text
    }
    static func pins(_ data: Data, version: String) -> Pins? {
        guard data.count <= 64 * 1024,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(body.keys) == ["v", "releases"], let v = body["v"] as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID(), v == 1,
              let releases = body["releases"] as? [String: Any], releases.count <= 32,
              version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil,
              let row = releases[version] as? [String: Any],
              Set(row.keys) == ["webControlManifestSha256", "webSignerManifestSha256"],
              let control = hex(row["webControlManifestSha256"]), let signer = hex(row["webSignerManifestSha256"]) else { return nil }
        return Pins(webControlManifestSha256: control, webSignerManifestSha256: signer)
    }
    static func safePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count <= 512,
              path.range(of: #"\A/[A-Za-z0-9_./-]+\z"#, options: .regularExpression) != nil else { return false }
        return !path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix(".") }
    }
    static func manifest(_ data: Data, sha: String, signer: Bool) -> [String: String]? {
        guard data.count <= 256 * 1024, hash(data) == sha,
              let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(body.keys) == ["v", "algorithm", "files"], let v = body["v"] as? NSNumber,
              CFGetTypeID(v) != CFBooleanGetTypeID(), v == 1, body["algorithm"] as? String == "sha256",
              let rows = body["files"] as? [String: Any], !rows.isEmpty, rows.count <= 2048 else { return nil }
        var result: [String: String] = [:]
        for (path, value) in rows { guard safePath(path), let sha = hex(value) else { return nil }; result[path] = sha }
        if signer, Set(result.keys) != signerPaths { return nil }
        return result
    }
    static func statusMatches(_ status: [String: Any], pins: Pins) -> Bool {
        guard status["enabled"] as? Bool == true, let control = status["integrity"] as? [String: Any],
              control["enabled"] as? Bool == true, control["ok"] as? Bool == true,
              control["manifestSha256"] as? String == pins.webControlManifestSha256,
              let signer = control["signer"] as? [String: Any], signer["enabled"] as? Bool == true,
              signer["ok"] as? Bool == true, signer["manifestSha256"] as? String == pins.webSignerManifestSha256 else { return false }
        return true
    }
    static func verified(_ bytes: Data, sha: String) -> Bool { bytes.count <= maximumFileBytes && hash(bytes) == sha }
    static func bundleResource(executable: URL) -> (app: URL, resource: URL)? {
        let executable = executable.standardizedFileURL
        guard executable.path == executable.resolvingSymlinksInPath().path,
              executable.lastPathComponent == "cos-control-helper",
              executable.deletingLastPathComponent().lastPathComponent == "Resources",
              executable.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" else { return nil }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app" else { return nil }
        let resource = executable.deletingLastPathComponent().appendingPathComponent(resourceName)
        guard resource.path == resource.resolvingSymlinksInPath().path else { return nil }
        return (app, resource)
    }
}

// MARK: - The signer audit's TLS trust (0.5.390; QA 2026-11-09 open question 2)

/// How Control's signer-file audit (HelperSources/main.swift, webKeyAssetAudit) trusts the HTTPS origin it fetches from.
///
/// The ts.net signer host must be trusted the way the phone trusts it: by the public roots macOS ships, for that host
/// name. curl alone cannot say that here. Apple's /usr/bin/curl adds any --cacert to the keychain's trust instead of
/// replacing it (the B2 builder's probe, 2026-11-09), and the keychain also trusts the admin-domain mkcert root for SSL,
/// whose private key is a user-readable file. So for the ts.net host curl writes out the chain it received, and
/// `trusted` judges that chain against the system trust domain ALONE, with the SSL policy for the host name. localhost
/// and IP targets keep Control's managed certificate. Pure: no process, file or network.
enum SignerTLSCore {
    /// The signer host shape the audit has always required: two or more labels, then ts.net, lower case.
    static let tsNetPattern = #"\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\.ts\.net\z"#
    static func isTSNetHost(_ host: String) -> Bool {
        host.utf8.count <= 253 && host.range(of: tsNetPattern, options: .regularExpression) != nil
    }

    enum Trust: Equatable, Sendable {
        /// The ts.net signer host: the system trust domain alone, over the chain curl received (`trusted`).
        case systemRoots
        /// localhost and IP literals: Control's managed (mkcert) certificate, as before.
        case managedCert
    }

    static func trust(host: String) -> Trust? {
        if isTSNetHost(host) { return .systemRoots }
        if host == "localhost" || TailscaleCore.isIPv4(host) || isIPv6Literal(host) { return .managedCert }
        return nil
    }

    static func isIPv6Literal(_ host: String) -> Bool {
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        var address = in6_addr()
        return bare.contains(":") && inet_pton(AF_INET6, bare, &address) == 1
    }

    /// curl's trust and write-out arguments for one fetch. Never --insecure: curl keeps its own chain and hostname checks
    /// either way. For the ts.net host there is no --cacert (it would only add to the keychain's trust), and curl writes
    /// the chain it received after the status code, so the audit judges THAT connection's chain.
    static func curlTrustArguments(_ trust: Trust, managedCert: String) -> [String] {
        switch trust {
        case .systemRoots: return ["--write-out", "%{http_code}\n%{certs}"]
        case .managedCert: return ["--cacert", managedCert, "--write-out", "%{http_code}"]
        }
    }

    /// curl's --write-out answer: the status code (its first line) and, for the ts.net host, the chain, leaf first.
    static func curlAnswer(_ output: String) -> (code: String, chain: [Data]) {
        let code = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return (code, certificates(output))
    }

    /// The DER of every well-formed CERTIFICATE PEM block, in order. curl's certinfo text around them is ignored.
    static func certificates(_ text: String) -> [Data] {
        guard text.utf8.count <= 256 * 1024,
              let expression = try? NSRegularExpression(pattern: #"-----BEGIN CERTIFICATE-----\r?\n([A-Za-z0-9+/=\r\n]+?)-----END CERTIFICATE-----"#) else { return [] }
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let body = source.substring(with: match.range(at: 1)).filter { $0 != "\r" && $0 != "\n" }
            guard let der = Data(base64Encoded: body), !der.isEmpty else { return nil }
            return der
        }
    }

    /// The trust anchors macOS ships: the system trust domain only. Never the admin or user domains, where the mkcert root
    /// (SSL) and any other locally added root live.
    static func systemRoots() -> [SecCertificate] {
        var list: CFArray?
        guard SecTrustSettingsCopyCertificates(.system, &list) == errSecSuccess, let roots = list as? [SecCertificate] else { return [] }
        return roots
    }

    /// Whether `chain` (leaf first) verifies for `host` at `date` against `anchors` ALONE: the SSL policy with the host
    /// name, anchors only, no network fetch. The audit passes systemRoots() and its ts.net host; the checks also pass a
    /// throwaway root, and real Let's Encrypt chains at a pinned date.
    static func trusted(chain: [Data], host: String, at date: Date, anchors: [SecCertificate]) -> Bool {
        evaluate(chain: chain, host: host, at: date, anchors: anchors).trusted
    }

    /// trusted(), with why it said no: "input" (the guard), "certificate" (a block that is not DER), "create" or "setup"
    /// (SecTrust would not take the inputs), or SecTrust's own error. The checks print it as evidence; the audit reads only
    /// the Bool.
    static func evaluate(chain: [Data], host: String, at date: Date, anchors: [SecCertificate]) -> (trusted: Bool, why: String) {
        // chain.count <= 8 is load-bearing: SecTrust accepts a padded chain (mutant TLS-14). The empty-input checks are
        // proven per input by "audit empty host", "audit empty anchors" and "audit empty chain" (mutants TLS-15 to 17).
        guard !chain.isEmpty, chain.count <= 8, !anchors.isEmpty, !host.isEmpty else { return (false, "input") }
        var certificates: [SecCertificate] = []
        for der in chain {
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else { return (false, "certificate") }
            certificates.append(certificate)
        }
        var made: SecTrust?
        let created = SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &made)
        guard created == errSecSuccess, let trust = made else { return (false, "create \(created)") }
        guard SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustSetVerifyDate(trust, date as CFDate) == errSecSuccess else { return (false, "setup") }
        var error: CFError?
        let accepted = SecTrustEvaluateWithError(trust, &error)
        return (accepted, accepted ? "ok" : "SecTrust: " + (error.map { CFErrorCopyDescription($0) as String } ?? "no error"))
    }
}
