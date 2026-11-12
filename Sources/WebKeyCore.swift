import Combine
import CryptoKit
import Foundation
import LocalAuthentication
import Security

// Phone approvals (server 6.99.31, flag COS_WEB_KEY_AUTHORITY, default off): COS Control's half of the enrolled phone key.
// Contract: cos-glasses-server docs/web-key-verifier-contract.md. Review: MU wk45_2026/qa_6.99.30_plan_review.md
// (B1, W4, W5, W6, W7, W9 live here).
//
// What this file holds, all of it Foundation and CryptoKit so Tests/WebKeyChecks.swift runs it on its own
// (Tests/run-web-key.sh):
//   - the encodings (base64url, RFC 8785 JCS for the shapes this protocol signs, SPKI, fingerprint, kid, SAS, aud);
//   - the anchor: COS Control's Secure Enclave P-256 key behind Touch ID (.biometryCurrentSet), its self-signed
//     `cos-web-anchor/1` statement, and the pin JSON Miles commits himself (review B1). Control never writes the repo;
//   - the enrollment card (W4, W6): every value it shows comes from the approvalJcs bytes the anchor signs, and the
//     card refuses on any difference. Approve needs the 6-digit code typed from the phone, a fresh listener audit and
//     a verified card (WebKeyApproveGate), checked again inside approve(), not only by a disabled button;
//   - Control's own epoch and revocation list (W5): web-key-state.json, written atomically with class C protection, and
//     the same record in the keychain, so a rolled-back file is caught and rewritten from the keychain;
//   - the listener audit (W9): the server's one PID owns 3141, 3143 and 3144 on every address, checked by lsof in the
//     helper at most 60 s before a card is shown. Signed Control resources pin both manifests; the helper compares installed and served signer bytes with those pins.
//
// Nothing here runs unless the server says the flag is on (WebKeyState.refresh hides everything otherwise), and nothing
// vouches for a turn until Miles registers the anchor, pins it and 24 hours pass (the verifier's rule).

// MARK: - Encodings

enum WebKeyB64 {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strict: the base64url alphabet, no padding, never length mod 4 == 1, and the bytes encode back to the same text.
    static func decode(_ text: String) -> Data? {
        guard !text.isEmpty, text.count % 4 != 1, text.utf8.allSatisfy({ byte in
            (byte >= 0x41 && byte <= 0x5a) || (byte >= 0x61 && byte <= 0x7a) || (byte >= 0x30 && byte <= 0x39) || byte == 0x2d || byte == 0x5f
        }) else { return nil }
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        guard let data = Data(base64Encoded: base), encode(data) == text else { return nil }
        return data
    }
}

enum WebKeyHash {
    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func sha256Hex(_ data: Data) -> String { hex(sha256(data)) }
}

/// RFC 8785 for the values this protocol signs: objects, arrays, strings, safe integers, booleans and null. Strings are
/// escaped as ES JSON.stringify does. Keys sort by UTF-16 code unit. A float, a non-safe integer or any other type is
/// not signable (nil). Input is what JSONSerialization returns, or Swift String, Int, Int64, Bool, arrays and dictionaries.
enum WebKeyJCS {
    static let maxSafe: Int64 = 9_007_199_254_740_991

    static func encode(_ value: Any) -> String? {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let type = String(cString: number.objCType)
            guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) else { return nil }
            let int = number.int64Value
            guard int >= -maxSafe, int <= maxSafe, number == NSNumber(value: int) else { return nil }
            return String(int)
        }
        if let text = value as? String { return string(text) }
        if let array = value as? [Any] {
            var parts: [String] = []
            for item in array { guard let part = encode(item) else { return nil }; parts.append(part) }
            return "[" + parts.joined(separator: ",") + "]"
        }
        if let object = value as? [String: Any] {
            let keys = object.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            var parts: [String] = []
            for key in keys {
                guard let inner = object[key], let part = encode(inner) else { return nil }
                parts.append(string(key) + ":" + part)
            }
            return "{" + parts.joined(separator: ",") + "}"
        }
        return nil
    }

    static func bytes(_ value: Any) -> Data? { encode(value).map { Data($0.utf8) } }

    static func string(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

enum WebKeySPKI {
    /// A P-256 SubjectPublicKeyInfo that re-exports to the identical bytes (no trailing data, no compressed point).
    static func parse(der: Data) -> Data? {
        guard let key = try? P256.Signing.PublicKey(derRepresentation: der), key.derRepresentation == der else { return nil }
        return der
    }

    static func parse(b64: String) -> Data? { WebKeyB64.decode(b64).flatMap { parse(der: $0) } }

    /// First 16 hex of sha256(SPKI DER), upper case, as XXXX-XXXX-XXXX-XXXX.
    static func fingerprint(_ der: Data) -> String {
        let h = Array(WebKeyHash.sha256Hex(der).prefix(16).uppercased())
        return [h[0..<4], h[4..<8], h[8..<12], h[12..<16]].map { String($0) }.joined(separator: "-")
    }

    static func kid(_ der: Data) -> String { String(WebKeyB64.encode(WebKeyHash.sha256(der)).prefix(22)) }
}

// MARK: - The protocol's fixed values

enum WebKeyProtocol {
    static let signerPort = 3144
    static let anchorStatementVersion = "cos-web-anchor/1"
    static let approvalVersion = "cos-web-enroll-approve/2"
    /// The approval object's exact keys (contract section 3).
    static let approvalKeys: Set<String> = [
        "v", "enrollId", "kid", "spki", "spki_sha256", "fingerprint", "label", "userAgent", "remote", "challenge", "sasCommit",
        "phoneNonce", "sas", "aud", "origin", "kver", "epoch", "rotates", "passkey_credential_id", "passkey_spki_sha256",
        "enrolledAt", "exp",
    ]
    /// GET /api/web-key/enroll/pending answers only these (contract section 3). Any other key is a display field the card
    /// would have to ignore, so the card refuses it instead.
    static let pendingKeys: Set<String> = ["enrollId", "startedAt", "exp", "approval", "approvalJcs"]
    /// Where Control keeps its anchor blob and its mirror of the state file (the login keychain, this app's items).
    static let keychainService = "com.gotcos.control.web-key"

    /// sas = uint32_be(sha256(challenge || spkiDer || phoneNonce)[0:4]) mod 1_000_000, zero-padded to 6 (review W3).
    static func sas(challenge: Data, spki: Data, phoneNonce: Data) -> String {
        let digest = Array(WebKeyHash.sha256(challenge + spki + phoneNonce))
        let value = (UInt32(digest[0]) << 24) | (UInt32(digest[1]) << 16) | (UInt32(digest[2]) << 8) | UInt32(digest[3])
        let text = String(value % 1_000_000)
        return String(repeating: "0", count: 6 - text.count) + text
    }

    /// hex(sha256(anchor SPKI DER || utf8(lower(rpId)))).
    static func aud(anchorDER: Data, rpId: String) -> String {
        WebKeyHash.sha256Hex(anchorDER + Data(rpId.trimmingCharacters(in: .whitespaces).lowercased().utf8))
    }

    /// The host of `https://<MagicDNS name>:3144`, or nil for any other origin (another port, http, a path, an IP).
    static func signerHost(_ origin: String) -> String? {
        let prefix = "https://", suffix = ":\(signerPort)"
        guard origin.hasPrefix(prefix), origin.hasSuffix(suffix) else { return nil }
        let host = String(origin.dropFirst(prefix.count).dropLast(suffix.count))
        guard host.count <= 253,
              host.range(of: #"\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\.ts\.net\z"#,
                         options: .regularExpression) != nil else { return nil }
        return host
    }

    /// The JCS bytes of the anchor's self-signed statement: {v, spkiSha256, fingerprint, createdAt}.
    static func anchorStatement(spki: Data, createdAtMs: Int64) -> Data {
        let object: [String: Any] = [
            "v": anchorStatementVersion, "spkiSha256": WebKeyHash.sha256Hex(spki), "fingerprint": WebKeySPKI.fingerprint(spki),
            "createdAt": NSNumber(value: createdAtMs),
        ]
        return WebKeyJCS.bytes(object)!
    }

    /// The POST /api/web-key/anchor body: {anchorPub, statement, signature}, every value base64url.
    static func anchorBody(spki: Data, statement: Data, signature: Data) -> Data {
        let object: [String: Any] = ["anchorPub": WebKeyB64.encode(spki), "statement": WebKeyB64.encode(statement), "signature": WebKeyB64.encode(signature)]
        return WebKeyJCS.bytes(object)!
    }

    /// The pin Miles commits at operations/scripts/web_key_anchor.json (verify_g2_turn.py PIN_KEYS:
    /// v, anchorPub, spkiSha256, fingerprint, pinnedAt). Control puts it on the clipboard; it never writes the repo.
    static func anchorPin(spki: Data, pinnedAtMs: Int64) -> String {
        """
        {
          "v": 1,
          "anchorPub": "\(WebKeyB64.encode(spki))",
          "spkiSha256": "\(WebKeyHash.sha256Hex(spki))",
          "fingerprint": "\(WebKeySPKI.fingerprint(spki))",
          "pinnedAt": \(pinnedAtMs)
        }

        """
    }

    /// The system Touch ID sheet's reason when enrolling one phone key (plan section 4.3 step 4). No em dashes.
    static func approveReason(fingerprint: String, sas: String) -> String {
        "Enroll phone key \(fingerprint) code \(sas.prefix(3)) \(sas.suffix(3)) for COS web approvals"
    }

    static func anchorReason(fingerprint: String) -> String {
        "Register approval key \(fingerprint) with the COS server on this Mac"
    }
}

// MARK: - The enrollment card (review W4, W6)

/// What the card shows. Built ONLY by WebKeyApprovalCheck.card, from the approvalJcs bytes the anchor signs.
struct WebKeyApprovalCard: Equatable, Sendable {
    let enrollId: String
    let kid: String
    let fingerprint: String
    /// Never drawn on the card: Miles types the code his phone shows, and the card compares (WebKeyCodeEntry).
    let sas: String
    let label: String
    let userAgent: String
    let remote: String
    let rotates: String?
    let expiresAtMs: Int64
    /// The exact bytes the anchor signs.
    let approvalBytes: Data
}

enum WebKeyApprovalRefusal: String, Error, Sendable {
    case pendingMalformed = "pending_malformed"
    case extraDisplayFields = "extra_display_fields"
    case approvalNotBase64 = "approval_not_base64url"
    case approvalTooLarge = "approval_too_large"
    case approvalNotJSON = "approval_not_json"
    case approvalKeys = "approval_keys"
    case approvalNotCanonical = "approval_not_canonical"
    case approvalMismatch = "approval_field_mismatch"
    case versionUnknown = "version_unknown"
    case enrollIdMismatch = "enroll_id_mismatch"
    case keyInvalid = "key_invalid"
    case fingerprintMismatch = "fingerprint_mismatch"
    case kidMismatch = "kid_mismatch"
    case commitMismatch = "commit_mismatch"
    case sasMismatch = "sas_mismatch"
    case originInvalid = "origin_invalid"
    case audMismatch = "aud_mismatch"
    case epochMismatch = "epoch_mismatch"
    case fieldInvalid = "field_invalid"
    case expired = "expired"

    /// One line for the card. The code is shown too, for a support report.
    var line: String { "This request does not check out (\(rawValue)). Do not approve it." }
}

enum WebKeyApprovalCheck {
    static let maxApprovalBytes = 8 * 1024

    private static func int(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let type = String(cString: number.objCType)
        guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) else { return nil }
        let v = number.int64Value
        return v >= 0 && v <= WebKeyJCS.maxSafe ? v : nil
    }

    private static func text(_ value: Any?, min: Int = 1, max: Int) -> String? {
        guard let s = value as? String, s.count >= min, s.count <= max,
              !s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        return s
    }

    private static func hex64(_ value: Any?) -> String? {
        guard let s = value as? String, s.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil else { return nil }
        return s
    }

    /// The card for `pending` (GET /api/web-key/enroll/pending's `pending`), or why not. `anchorDER` is Control's own anchor
    /// (aud is computed from it, never taken from the server); `controlEpoch` is Control's own epoch when it has one.
    static func card(pending: [String: Any], anchorDER: Data, controlEpoch: Int64?, nowMs: Int64) -> Result<WebKeyApprovalCard, WebKeyApprovalRefusal> {
        guard Set(pending.keys).isSubset(of: WebKeyProtocol.pendingKeys) else { return .failure(.extraDisplayFields) }
        guard let enrollId = pending["enrollId"] as? String, WebKeyB64.decode(enrollId)?.count == 16,
              let jcs = pending["approvalJcs"] as? String else { return .failure(.pendingMalformed) }
        guard let bytes = WebKeyB64.decode(jcs) else { return .failure(.approvalNotBase64) }
        guard bytes.count <= maxApprovalBytes else { return .failure(.approvalTooLarge) }
        guard let parsed = try? JSONSerialization.jsonObject(with: bytes), let approval = parsed as? [String: Any] else { return .failure(.approvalNotJSON) }
        guard Set(approval.keys) == WebKeyProtocol.approvalKeys else { return .failure(.approvalKeys) }
        // One message, one signable form: the bytes must already be canonical (a duplicate key, a float or a reordering
        // re-encodes differently).
        guard WebKeyJCS.bytes(approval) == bytes else { return .failure(.approvalNotCanonical) }
        // The server's decoded copy, when it sends one, must say exactly what the bytes say.
        if let copy = pending["approval"] {
            guard let object = copy as? [String: Any], WebKeyJCS.bytes(object) == bytes else { return .failure(.approvalMismatch) }
        }
        guard approval["v"] as? String == WebKeyProtocol.approvalVersion else { return .failure(.versionUnknown) }
        guard approval["enrollId"] as? String == enrollId else { return .failure(.enrollIdMismatch) }
        guard let spkiText = approval["spki"] as? String, let spki = WebKeySPKI.parse(b64: spkiText) else { return .failure(.keyInvalid) }
        guard approval["spki_sha256"] as? String == WebKeyHash.sha256Hex(spki),
              approval["fingerprint"] as? String == WebKeySPKI.fingerprint(spki) else { return .failure(.fingerprintMismatch) }
        guard let kid = approval["kid"] as? String, kid == WebKeySPKI.kid(spki) else { return .failure(.kidMismatch) }
        guard let challenge = (approval["challenge"] as? String).flatMap(WebKeyB64.decode), challenge.count == 32,
              let nonce = (approval["phoneNonce"] as? String).flatMap(WebKeyB64.decode), nonce.count == 32 else { return .failure(.fieldInvalid) }
        guard approval["sasCommit"] as? String == WebKeyHash.sha256Hex(nonce) else { return .failure(.commitMismatch) }
        guard let sas = approval["sas"] as? String, sas.range(of: #"\A[0-9]{6}\z"#, options: .regularExpression) != nil,
              sas == WebKeyProtocol.sas(challenge: challenge, spki: spki, phoneNonce: nonce) else { return .failure(.sasMismatch) }
        guard let origin = approval["origin"] as? String, let host = WebKeyProtocol.signerHost(origin) else { return .failure(.originInvalid) }
        guard approval["aud"] as? String == WebKeyProtocol.aud(anchorDER: anchorDER, rpId: host) else { return .failure(.audMismatch) }
        guard int(approval["kver"]) == 1, let epoch = int(approval["epoch"]), let enrolledAt = int(approval["enrolledAt"]),
              let exp = int(approval["exp"]), enrolledAt <= exp,
              let label = text(approval["label"], max: 64), let userAgent = text(approval["userAgent"], min: 0, max: 200),
              let remote = text(approval["remote"], max: 64),
              let credential = approval["passkey_credential_id"] as? String,
              credential.range(of: #"\A[A-Za-z0-9_-]{1,1024}\z"#, options: .regularExpression) != nil,
              hex64(approval["passkey_spki_sha256"]) != nil else { return .failure(.fieldInvalid) }
        let rotatesValue = approval["rotates"]
        let rotates: String?
        if rotatesValue is NSNull { rotates = nil } else if let r = rotatesValue as? String, r.range(of: #"\A[A-Za-z0-9_-]{22}\z"#, options: .regularExpression) != nil, r != kid { rotates = r } else { return .failure(.fieldInvalid) }
        if let controlEpoch { guard epoch == controlEpoch else { return .failure(.epochMismatch) } }
        guard nowMs <= exp else { return .failure(.expired) }
        return .success(WebKeyApprovalCard(enrollId: enrollId, kid: kid, fingerprint: WebKeySPKI.fingerprint(spki), sas: sas, label: label,
                                           userAgent: userAgent, remote: remote, rotates: rotates, expiresAtMs: exp, approvalBytes: bytes))
    }
}

/// The code Miles types from his phone (review W6). Spaces and a dash are allowed between digits; anything else is not a code.
enum WebKeyCodeEntry {
    static func normalized(_ typed: String) -> String? {
        let digits = typed.filter { $0 != " " && $0 != "-" }
        guard digits.count == 6, digits.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) else { return nil }
        return digits
    }

    /// Constant time over the six digits.
    static func matches(typed: String, card: WebKeyApprovalCard) -> Bool {
        guard let digits = normalized(typed) else { return false }
        let a = Array(digits.utf8), b = Array(card.sas.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

// MARK: - The server's mode (0.5.383, server 7.0.9)

/// What the server's GET /api/web-key/status says it serves. Authority (COS_WEB_KEY_AUTHORITY on) is today's full lane.
/// Bootstrap (COS_WEB_KEY_ANCHOR_BOOTSTRAP on, authority off) serves only anchor status and anchor registration, so Control
/// shows only the Mac anchor: register it with Touch ID and start its 24 hour clock, with no phone enrollment, no code, no
/// approval, no key list and no signer audit. Anything else, an older server or a contradiction, is off: hidden, as before.
/// Bootstrap keeps `enabled` false, so a phone-lane Control older than 0.5.383 reads it as off and hides everything.
enum WebKeyServerMode: String, Equatable, Sendable {
    case off
    case bootstrap
    case authority

    static func read(status: Int, body: [String: Any]) -> WebKeyServerMode {
        guard status == 200, let origin = body["origin"] as? String, WebKeyProtocol.signerHost(origin) != nil else { return .off }
        let mode = body["mode"]
        switch body["enabled"] as? Bool {
        case true?: return mode == nil || mode as? String == "authority" ? .authority : .off
        case false?: return mode as? String == "bootstrap" ? .bootstrap : .off
        case nil: return .off
        }
    }

    /// A non-negative safe integer from a server answer (ms times, the epoch), never a boolean or a fraction.
    static func int(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        guard d >= 0, d <= Double(WebKeyJCS.maxSafe), d == d.rounded() else { return nil }
        return Int64(d)
    }
}

// MARK: - The signer origin's certificate (0.5.390, server 7.0.20 `signerTls`)

/// The server's `signerTls` in authority mode (server/lib/web-key-signer-tls.ts): whether 3144 presents a publicly trusted,
/// unexpired certificate for this Mac's tailnet name. Control reads it ONLY for one plain line in Phone approvals; trust in
/// the served chain is the signer audit's own check (HelperSources/PairingCore.swift, SignerTLSCore). A server that does
/// not report it gets no line.
enum WebKeySignerTLS {
    static let certsOff = "Turn on HTTPS Certificates in your Tailscale admin console."

    /// nil when the server reports a trusted certificate for the origin's own host that has not expired, or reports
    /// nothing; otherwise one sentence for its reason. The server's lastError is not read: it can outlive a working pair.
    static func problem(body: [String: Any], now: Date) -> String? {
        guard let tls = body["signerTls"] as? [String: Any] else { return nil }
        let host = (body["origin"] as? String).flatMap(WebKeyProtocol.signerHost)
        if tls["trusted"] as? Bool == true, let host, tls["host"] as? String == host,
           let end = (tls["notAfter"] as? String).flatMap(date), end > now { return nil }
        return line(tls["reason"] as? String)
    }

    /// Server reopen (2026-11-11): `signerTls.storedRefused`, why the server refused the last certificate pair placed by
    /// hand in its folder (a stored_* code, cert_untrusted and so on), so the refusal is visible at acceptance. One sentence
    /// from the same list; nil when the server reports none, or when it would repeat the line `problem` already shows.
    static func storedRefused(body: [String: Any], now: Date) -> String? {
        guard let tls = body["signerTls"] as? [String: Any], let code = tls["storedRefused"] as? String, !code.isEmpty else { return nil }
        let sentence = line(code)
        return sentence == problem(body: body, now: now) ? nil : sentence
    }

    /// THE one list of the server's not-trusted reason codes (the server's SIGNER_TLS_REASONS minus "ok",
    /// server/lib/web-key-signer-tls.ts; golden.json carries the server's list and the reasonParity check compares them)
    /// and one plain sentence each. These codes are written nowhere else in Control (Tests/web-key-pins.py). A code the
    /// server adds later gets `fallback`, never a code on screen.
    static let sentences: [String: String] = [
        "pending": "COS is getting this Mac's Tailscale certificate for your phone.",
        "tailnet_name_unknown": "COS does not know this Mac's Tailscale name yet. Check that Tailscale is connected.",
        "tailnet_https_certs_off": certsOff,
        "cert_domain_mismatch": "Tailscale lists no certificate name for this Mac. Check HTTPS Certificates in your Tailscale admin console.",
        "tailscale_not_running": "Tailscale is not running on this Mac, so your phone cannot reach approvals.",
        "tailscale_cli_missing": "Tailscale is not installed on this Mac, so your phone cannot reach approvals.",
        "tailscale_cli_timeout": "Tailscale did not answer the COS server. COS tries again later.",
        "tailscale_cli_gui_unavailable": "The COS server could not reach Tailscale on this Mac. Open the Tailscale app once; COS tries again later.",
        "tailscale_status_failed": "Tailscale did not answer the COS server. COS tries again later.",
        "tailscale_cert_failed": "Tailscale could not get this Mac's certificate. COS tries again later.",
        "cert_invalid": "Tailscale's certificate did not check out, so COS is not using it.",
        "cert_expired": "This Mac's Tailscale certificate expired. COS is getting a new one.",
        "cert_store_failed": "COS could not save this Mac's Tailscale certificate.",
        // Server reopen (2026-11-11): SR-03, SR-01, SR-05 and the stored-pair checks of SR-08.
        "tailscale_output_too_large": "Tailscale's answer was too large for the COS server to read. COS tries again later.",
        "cert_not_yet_valid": "This Mac's Tailscale certificate is not valid yet. Check the Mac's date and time.",
        "cert_untrusted": "The certificate COS found is not publicly trusted, so COS is not using it.",
        "cert_daily_cap": "COS asked Tailscale for a certificate too often today. It tries again tomorrow.",
        "stored_symlink": "COS did not use the certificate files in its folder: one of them is a link.",
        "stored_not_file": "COS did not use the certificate files in its folder: one of them is not a regular file.",
        "stored_owner": "COS did not use the certificate files in its folder: they belong to another user.",
        "stored_writable": "COS did not use the certificate files in its folder: other users can change them.",
        "stored_too_large": "COS did not use the certificate files in its folder: one of them is too large.",
    ]
    static let fallback = "Your phone's secure connection to this Mac is not ready yet."

    static func line(_ reason: String?) -> String { reason.flatMap { sentences[$0] } ?? fallback }

    /// The server's ISO 8601 time (JavaScript's toISOString has milliseconds).
    static func date(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - The phone approvals switch (option A, lead 2026-11-11 21:31)

/// Settings PK-02, in full Settings only (never Basic): off by default; turning it on picks one of this account's iPhones
/// from Tailscale and asks for a confirmation that names the phone and says the Mac's name becomes public in certificate
/// logs. The helper verb `set-phone-approvals` applies it through the managed provider environment (PhoneApprovalsCore,
/// HelperSources/PairingCore.swift). Whether it is on is read from the server's own status (WebKeyServerMode).
enum PhoneApprovalsSwitch {
    /// The first server with the reopened phone approvals; PhoneApprovalsCore.minimumServer must equal it (a check).
    static let minimumServer = "7.0.29"

    struct Peer: Equatable, Sendable {
        var os: String
        var dns: String
        var ipv4: String?
        var sameUser: Bool
    }

    struct Phone: Hashable, Sendable {
        let name: String
        let ipv4: String
    }

    /// This account's iOS devices with a Tailscale IPv4, by name. Another account's device or a Mac is never offered. Tailscale
    /// reports an iPad as iOS too, so an iPad on this account is listed by its name; the person picks the phone.
    static func phones(_ peers: [Peer]) -> [Phone] {
        peers.compactMap { peer -> Phone? in
            guard peer.os == "iOS", peer.sameUser, let ipv4 = peer.ipv4, isTailnetIPv4(ipv4) else { return nil }
            let name = String(peer.dns.split(separator: ".").first ?? Substring(peer.dns))
            return name.isEmpty ? nil : Phone(name: name, ipv4: ipv4)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 100.64.0.0/10, written plainly (the app does not compile the helper's TailscaleCore).
    static func isTailnetIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isASCII && $0.isNumber }), !(part.count > 1 && part.first == "0") else { return nil }
            return Int(part).flatMap { $0 <= 255 ? $0 : nil }
        }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// The row draws only for a server new enough to have the reopened phone approvals.
    static func shown(serverVersion: String?) -> Bool {
        guard let version = serverVersion.flatMap(numbers), let floor = numbers(minimumServer) else { return false }
        return version.lexicographicallyPrecedes(floor) == false
    }

    private static func numbers(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".").map { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }
    }

    /// Like the nine restart rows (RestartApply.applyEnabled, Settings Release A): turning ON, and Off's =0 restart, are live
    /// only with no other change in progress and no running work, so neither interrupts a meeting or leaves the drain gate
    /// closed. Off's Revoke all, and the Devices card's Revoke and Revoke all, never ask this (PhoneApprovalsOff).
    static func applyAllowed(locked: Bool, workActive: Bool) -> Bool { !locked && !workActive }

    /// On means the server serves phone approvals now. Bootstrap (registration only) and off read as off.
    static func isOn(_ mode: WebKeyServerMode) -> Bool { mode == .authority }

    /// The helper's arguments: on needs a phone; off takes none.
    static func arguments(on: Bool, phone: Phone?) -> [String]? {
        if !on { return ["off"] }
        guard let phone, isTailnetIPv4(phone.ipv4) else { return nil }
        return ["on", phone.ipv4]
    }

    // Copy. Plain sentences, no em dashes (Tests/web-key-pins.py).
    static func confirmOnTitle(_ phone: Phone) -> String { "Turn on phone approvals for \(phone.name)?" }
    static func confirmOnMessage(_ phone: Phone, macName: String?) -> String {
        let mac = macName.map { "Your Mac's Tailscale name, \($0)," } ?? "Your Mac's Tailscale name"
        return "\(phone.name) can then approve agent actions with its passkey and user verification on one of your Apple devices, after you enroll it here with Touch ID. "
            + "\(mac) becomes public in certificate logs when its first certificate is issued, and stays public. "
            + "COS restarts the server to turn this on."
    }
    static let confirmOn = "Turn on and restart"
    static let confirmOffTitle = "Turn off phone approvals?"
    static let confirmOffMessage = "Every enrolled phone is removed now and stops approving at once. If you turn this on again, enroll each phone again with Touch ID. COS then restarts the server with phone approvals off, after any running work."
    static let confirmOff = "Remove phones and turn off"
    static let label = "Turn on phone approvals"
    static let detail = "Off unless you turn it on. Lets one of your iPhones approve agent actions. Restarts the server."
    static let noPhone = "No iPhone on your Tailscale account yet. Sign in to Tailscale on the phone, then check again."
}

// MARK: - Turning phone approvals off (option A, lead ruling 2026-11-12 10:32)

/// Off must stop approvals at once, and the server reads COS_WEB_KEY_AUTHORITY only when it starts. So Off runs the live
/// Revoke all first: every enrolled phone stops approving now and must be enrolled again with Touch ID and the code. Then it
/// writes =0 through the managed restart. Only that restart waits for running work (PhoneApprovalsSwitch.applyAllowed); the
/// revoke never does, and neither do the Devices card's Revoke and Revoke all. The wait is saved in UserDefaults, so it
/// survives a quit or a Mac restart, and the row shows it until the helper proves the server restarted with approvals off.
struct PhoneApprovalsPendingOff: Equatable, Sendable {
    /// The live Revoke all reached the server and it answered 200. When false, the row never says approvals are stopped.
    var revokedAll: Bool
    var savedAt: Int64
}

@MainActor protocol PhoneApprovalsPendingStore: AnyObject {
    func load() -> PhoneApprovalsPendingOff?
    func save(_ pending: PhoneApprovalsPendingOff)
    func clear()
}

/// The app's store: UserDefaults, which survives a quit or a Mac restart.
@MainActor final class DefaultsPhoneApprovalsPendingStore: PhoneApprovalsPendingStore {
    static let key = "cos.phoneApprovals.pendingOff"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func load() -> PhoneApprovalsPendingOff? {
        guard let row = defaults.dictionary(forKey: Self.key), let revoked = row["revokedAll"] as? Bool,
              let at = (row["savedAt"] as? NSNumber)?.int64Value else { return nil }
        return PhoneApprovalsPendingOff(revokedAll: revoked, savedAt: at)
    }
    func save(_ pending: PhoneApprovalsPendingOff) {
        defaults.set(["revokedAll": pending.revokedAll, "savedAt": NSNumber(value: pending.savedAt)] as [String: Any], forKey: Self.key)
    }
    func clear() { defaults.removeObject(forKey: Self.key) }
}

enum PhoneApprovalsOff {
    /// Off, after its confirm. The intent is saved before the revoke, so a quit during it still leaves the =0 waiting. The
    /// revoke runs whatever work is running; only the =0 restart asks applyAllowed, after the revoke, with the work as it is then.
    @MainActor static func run(store: any PhoneApprovalsPendingStore, now: Int64, revokeAll: () async -> Bool,
                               locked: () -> Bool, workActive: () -> Bool, apply: () -> Void) async -> PhoneApprovalsPendingOff {
        store.save(PhoneApprovalsPendingOff(revokedAll: false, savedAt: now))
        let pending = PhoneApprovalsPendingOff(revokedAll: await revokeAll(), savedAt: now)
        store.save(pending)
        resume(store: store, locked: locked(), workActive: workActive(), apply: apply)
        return pending
    }

    /// The saved =0 applies once nothing is in progress and no work runs: right after the revoke, when the row appears, and
    /// when running work ends. Returns whether it applied now.
    @MainActor @discardableResult
    static func resume(store: any PhoneApprovalsPendingStore, locked: Bool, workActive: Bool, apply: () -> Void) -> Bool {
        guard store.load() != nil, PhoneApprovalsSwitch.applyAllowed(locked: locked, workActive: workActive) else { return false }
        apply()
        return true
    }

    /// The helper finished the =0 restart. Only a proved restart (no error) clears the wait; a failed one keeps it.
    @MainActor static func finished(store: any PhoneApprovalsPendingStore, helperSucceeded: Bool) {
        if helperSucceeded { store.clear() }
    }

    /// The row's line while Off waits or runs. A failed Revoke all never reads as stopped.
    static func line(_ pending: PhoneApprovalsPendingOff, waiting: Bool) -> String {
        (pending.revokedAll ? stopped : notStopped) + (waiting ? " " + waits : "")
    }
    static let stopped = "Phone approvals are stopped. Every phone was removed."
    static let notStopped = "Revoke all did not reach the server, so a phone may still approve until the server restarts with approvals off."
    static let waits = "The restart waits for running work."
}

// MARK: - What a revoke says (security review 2026-11-12, blocker 2)

/// Nothing claims phone approvals are off unless the server confirmed the revoke or Control's protected record was saved.
/// Every other case names what failed.
enum WebKeyRevokeOutcome {
    static let noAnchor = "This Mac has no approval key, so Control kept no record of it"
    static let unreadable = "Control could not read its protected phone record"
    static let otherKey = "The protected phone record belongs to another key"
    static let epochFull = "Control could not advance the protected phone record"
    static let notRecorded = "Control could not record the revocation"

    static func message(serverConfirmed: Bool, localSaved: Bool, localProblem: String?) -> String? {
        let problem = localProblem ?? notRecorded
        switch (serverConfirmed, localSaved) {
        case (true, true): return nil
        case (true, false): return "The server revoked it. \(problem)."
        case (false, true): return "Revoked in Control. The server did not confirm, so phone approvals stay off until it does."
        case (false, false): return "\(problem), and the server did not confirm. A phone may still approve. Try again."
        }
    }
}

// MARK: - The listener audit (review W9)

/// Whether the server Control talks to also owns the signer ports, on every address: one PID, under the COS LaunchAgent,
/// listening on 3141, 3143 and 3144, and nobody else listening on any of them. From the helper's `web-key --op listeners`.
struct WebKeyListenerAudit: Equatable, Sendable {
    static let ports = [3141, 3143, 3144]
    /// 0.5.383 bootstrap: the anchor registration's narrower audit (the helper's `anchor-listeners`). Port 3144 does not
    /// listen with authority off, and no signer page is served, so there are no signer files to check.
    static let anchorPorts = [3141, 3143]
    static let maxAge: TimeInterval = 60
    enum Scope: String, Equatable, Sendable {
        /// The full audit: 3141, 3143 and 3144 and the pinned signer files. The only scope that opens a card or approves.
        case signer
        /// Bootstrap anchor registration only: 3141 and 3143 under one service PID. Never opens a card or approves.
        case anchor
    }
    let genuine: Bool
    let reason: String
    let checkedAt: Date
    var scope: Scope = .signer

    private func young(now: Date) -> Bool {
        let age = now.timeIntervalSince(checkedAt)
        return age <= Self.maxAge && age >= -5
    }

    /// A genuine full (signer) audit checked within the last 60 s (a clock that went backwards more than 5 s is not fresh
    /// either). An anchor-scope audit is never fresh here, so it can never show a card or approve a phone.
    func fresh(now: Date) -> Bool {
        scope == .signer && genuine && young(now: now)
    }

    /// Bootstrap registration only: a genuine anchor-scope audit checked within the last 60 s.
    func freshForAnchorRegistration(now: Date) -> Bool {
        scope == .anchor && genuine && young(now: now)
    }

    /// The anchor-scope judgment: one PID under the COS LaunchAgent listens on 3141 and 3143 on every address, nobody else.
    static func judgeAnchor(_ details: [String: Any], at: Date) -> WebKeyListenerAudit {
        func refuse(_ reason: String) -> WebKeyListenerAudit { WebKeyListenerAudit(genuine: false, reason: reason, checkedAt: at, scope: .anchor) }
        guard details["scope"] as? String == "anchor" else { return refuse("no_answer") }
        guard let service = (details["servicePID"] as? NSNumber)?.intValue, service > 1 else { return refuse("no_service") }
        guard let ports = details["ports"] as? [String: Any] else { return refuse("no_ports") }
        var owners = Set<Int>()
        for port in Self.anchorPorts {
            guard let rows = ports[String(port)] as? [Any], !rows.isEmpty else { return refuse("port_\(port)_not_listening") }
            for row in rows {
                guard let object = row as? [String: Any], let pid = (object["pid"] as? NSNumber)?.intValue, pid > 1,
                      (object["underService"] as? Bool) == true else { return refuse("port_\(port)_foreign_listener") }
                owners.insert(pid)
            }
        }
        guard owners.count == 1 else { return refuse("listeners_split") } // one service PID
        guard details["stable"] as? Bool == true else { return refuse("listener_changed") }
        return WebKeyListenerAudit(genuine: true, reason: "ok", checkedAt: at, scope: .anchor)
    }

    static func judge(_ details: [String: Any], at: Date) -> WebKeyListenerAudit {
        func refuse(_ reason: String) -> WebKeyListenerAudit { WebKeyListenerAudit(genuine: false, reason: reason, checkedAt: at) }
        guard let service = (details["servicePID"] as? NSNumber)?.intValue, service > 1 else { return refuse("no_service") }
        guard let ports = details["ports"] as? [String: Any] else { return refuse("no_ports") }
        var owners = Set<Int>()
        for port in Self.ports {
            guard let rows = ports[String(port)] as? [Any], !rows.isEmpty else { return refuse("port_\(port)_not_listening") }
            for row in rows {
                guard let object = row as? [String: Any], let pid = (object["pid"] as? NSNumber)?.intValue, pid > 1,
                      object["underService"] as? Bool == true else { return refuse("port_\(port)_foreign_listener") }
                owners.insert(pid)
            }
        }
        guard owners.count == 1 else { return refuse("listeners_split") }
        guard let assets = details["assets"] as? [String: Any] else { return refuse("signer_assets_unverified") }
        if assets["verified"] as? Bool != true {
            let reason = assets["reason"] as? String ?? ""
            let known: Set<String> = ["release_not_pinned", "unsigned_bundle", "signer_tls", "served_signer_assets", "reported_integrity", "installed_manifest", "installed_assets", "managed_identity", "audit_storage", "generation_changed", "listener_changed"]
            return refuse(known.contains(reason) ? reason : "signer_assets_unverified")
        }
        guard
              let controlSha = assets["webControlManifestSha256"] as? String,
              let signerSha = assets["webSignerManifestSha256"] as? String,
              [controlSha, signerSha].allSatisfy({ $0.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil }) else { return refuse("signer_assets_unverified") }
        return WebKeyListenerAudit(genuine: true, reason: "ok", checkedAt: at)
    }

    static let notGenuineLine = "Cannot confirm the signer page is genuine"
    static let anchorNotGenuineLine = "Cannot confirm the COS server on this Mac is the real one. Nothing was registered."
    var line: String {
        if scope == .anchor { return Self.anchorNotGenuineLine }
        switch reason {
        case "release_not_pinned": return "This Control release has not approved the installed server's signer files. Update the matched Control and server pair."
        case "unsigned_bundle": return "Phone enrollment requires the signed COS Control app."
        case "signer_tls", "served_signer_assets": return "Control could not verify the signer's HTTPS files. Phone enrollment stays off."
        default: return Self.notGenuineLine
        }
    }
}

/// Approve is offered, and runs, only when all of this holds (review W4, W6, W7, W9).
enum WebKeyApproveGate {
    static func allowed(card: WebKeyApprovalCard?, typed: String, audit: WebKeyListenerAudit?, anchor: Bool, now: Date) -> Bool {
        guard anchor, let card, let audit, audit.fresh(now: now) else { return false }
        guard Int64(now.timeIntervalSince1970 * 1000) <= card.expiresAtMs else { return false }
        return WebKeyCodeEntry.matches(typed: typed, card: card)
    }
}

// MARK: - Control's own epoch and revocation list (review W5)

struct WebKeyRevocation: Equatable, Sendable, Hashable {
    let kid: String
    let revokedAt: Int64
}

/// verify_g2_turn.py's CONTROL_WEB_KEY_STATE: {v:1, epoch, revoked:[{kid,revokedAt}], anchorSpkiSha256, updatedAt}.
struct WebKeyControlState: Equatable, Sendable {
    var epoch: Int64
    var revoked: [WebKeyRevocation]
    var anchorSpkiSha256: String
    var updatedAt: Int64

    init(epoch: Int64, revoked: [WebKeyRevocation], anchorSpkiSha256: String, updatedAt: Int64) {
        self.epoch = epoch
        self.revoked = revoked.sorted { Array($0.kid.utf16).lexicographicallyPrecedes(Array($1.kid.utf16)) }
        self.anchorSpkiSha256 = anchorSpkiSha256
        self.updatedAt = updatedAt
    }

    var revokedKids: Set<String> { Set(revoked.map(\.kid)) }

    /// The file's bytes: JCS (sorted keys) plus a newline. The verifier reads any valid JSON with exactly these keys.
    func fileData() -> Data {
        let rows: [Any] = revoked.map { ["kid": $0.kid, "revokedAt": NSNumber(value: $0.revokedAt)] as [String: Any] }
        let object: [String: Any] = ["v": 1, "epoch": NSNumber(value: epoch), "revoked": rows, "anchorSpkiSha256": anchorSpkiSha256,
                                     "updatedAt": NSNumber(value: updatedAt)]
        return WebKeyJCS.bytes(object)! + Data("\n".utf8)
    }

    /// Strict, as the verifier reads it: exact keys, v == 1, non-negative integers (never booleans), hex64, kids base64url.
    static func parse(_ data: Data) -> WebKeyControlState? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys) == ["v", "epoch", "revoked", "anchorSpkiSha256", "updatedAt"] else { return nil }
        func int(_ v: Any?) -> Int64? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: n.objCType)) else { return nil }
            let x = n.int64Value
            return x >= 0 && x <= WebKeyJCS.maxSafe ? x : nil
        }
        guard int(object["v"]) == 1, let epoch = int(object["epoch"]), let updatedAt = int(object["updatedAt"]),
              let anchor = object["anchorSpkiSha256"] as? String, anchor.range(of: #"\A[0-9a-f]{64}\z"#, options: .regularExpression) != nil,
              let rows = object["revoked"] as? [Any] else { return nil }
        var revoked: [WebKeyRevocation] = []
        for row in rows {
            guard let r = row as? [String: Any], Set(r.keys) == ["kid", "revokedAt"], let kid = r["kid"] as? String,
                  kid.range(of: #"\A[A-Za-z0-9_-]+\z"#, options: .regularExpression) != nil, let at = int(r["revokedAt"]) else { return nil }
            revoked.append(WebKeyRevocation(kid: kid, revokedAt: at))
        }
        guard Set(revoked.map(\.kid)).count == revoked.count else { return nil }
        return WebKeyControlState(epoch: epoch, revoked: revoked, anchorSpkiSha256: anchor, updatedAt: updatedAt)
    }

    /// Equal for the verifier's purposes (updatedAt aside).
    func sameRecord(as other: WebKeyControlState) -> Bool {
        epoch == other.epoch && revoked == other.revoked && anchorSpkiSha256 == other.anchorSpkiSha256
    }
}

/// Where Control keeps secrets that must outlive a file rollback: the anchor blob and the state mirror.
enum WebKeySecureRead: Equatable, Sendable {
    case found(Data)
    case missing
    /// The keychain answered with an error (locked, denied): never read as "no record".
    case failed(Int32)
}

protocol WebKeySecureStore: Sendable {
    func read(_ account: String) -> WebKeySecureRead
    func write(_ account: String, _ data: Data) -> Bool
}

/// The login keychain, items of service com.gotcos.control.web-key, readable after first unlock, this device only.
/// Whether another same-user process can read or delete them without a prompt is canary 5 (needs Miles at the Mac).
struct KeychainWebKeyStore: WebKeySecureStore {
    var service = WebKeyProtocol.keychainService

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func read(_ account: String) -> WebKeySecureRead {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = out as? Data else { return .failed(status) }
        return .found(data)
    }

    func write(_ account: String, _ data: Data) -> Bool {
        let update = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// web-key-state.json and its keychain mirror. The keychain copy is authoritative: a file that differs from it (an older
/// epoch, a revocation missing, another anchor, missing, unreadable) is rewritten from it.
struct WebKeyStateStore: Sendable {
    static let fileName = "web-key-state.json"
    static let mirrorAccount = "state"
    let directory: URL
    let secure: any WebKeySecureStore

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// ~/Library/Application Support/COS Control, from the passwd home as the verifier reads it.
    static func defaultDirectory() -> URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/COS Control", isDirectory: true)
    }

    enum Load: Equatable, Sendable {
        case none
        case ok(WebKeyControlState)
        /// The file differed from the keychain and was rewritten from it (review W5: a rollback, caught).
        case repaired(WebKeyControlState, rewrote: Bool)
        /// The keychain could not be read: nothing is trusted, nothing is written.
        case mirrorUnavailable
        /// A file and no keychain record. Not trusted on its own; the caller rebuilds both from the server.
        case mirrorMissing(WebKeyControlState?)
    }

    func load() -> Load {
        // Never read through a link, even if a later check would replace it.
        let fileState = isSymlink() ? nil : (try? Data(contentsOf: fileURL)).flatMap(WebKeyControlState.parse)
        switch secure.read(Self.mirrorAccount) {
        case .failed: return .mirrorUnavailable
        case .missing:
            if FileManager.default.fileExists(atPath: fileURL.path) { return .mirrorMissing(fileState) }
            return .none
        case .found(let data):
            guard let mirror = WebKeyControlState.parse(data) else { return .mirrorMissing(fileState) }
            if let fileState, fileState.sameRecord(as: mirror), !isSymlink() { return .ok(mirror) }
            return .repaired(mirror, rewrote: writeFile(mirror))
        }
    }

    /// The keychain first, then the file. A keychain write that fails writes nothing.
    @discardableResult
    func save(_ state: WebKeyControlState) -> Bool {
        guard WebKeyControlState.parse(state.fileData()) == state, secure.write(Self.mirrorAccount, state.fileData()) else { return false }
        return writeFile(state)
    }

    private func isSymlink() -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Atomic, class C (until first user authentication). Never class B: the keybag locks about 5 minutes after the screen
    /// does, and a class B file then cannot be reopened (gotchas, COS Control, 2026-10-10).
    private func writeFile(_ state: WebKeyControlState) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let directoryValues = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard directoryValues.isSymbolicLink != true, directoryValues.isDirectory == true else { return false }
            if isSymlink() { try FileManager.default.removeItem(at: fileURL) }
            try state.fileData().write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }
}

/// The server's key list (GET /api/web-key/keys): its epoch, its revocations, and the rows Control lists.
struct WebKeyKeyRow: Equatable, Sendable, Identifiable {
    let kid: String
    let label: String
    let fingerprint: String
    let active: Bool
    let state: String
    let revokedAt: Int64?
    var id: String { kid }
}

struct WebKeyServerKeys: Equatable, Sendable {
    let epoch: Int64
    let rows: [WebKeyKeyRow]
    var revoked: [WebKeyRevocation] { rows.compactMap { row in row.revokedAt.map { WebKeyRevocation(kid: row.kid, revokedAt: $0) } } }

    static func parse(_ body: [String: Any]) -> WebKeyServerKeys? {
        func int(_ v: Any?) -> Int64? {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            guard d >= 0, d <= Double(WebKeyJCS.maxSafe), d == d.rounded() else { return nil }
            return Int64(d)
        }
        guard let epoch = int(body["epoch"]), let keys = body["keys"] as? [Any] else { return nil }
        var rows: [WebKeyKeyRow] = []
        for item in keys {
            guard let k = item as? [String: Any], let kid = k["kid"] as? String,
                  kid.range(of: #"\A[A-Za-z0-9_-]{22}\z"#, options: .regularExpression) != nil else { return nil }
            var revokedAt: Int64?
            if k["revokedAt"] != nil, !(k["revokedAt"] is NSNull) { guard let at = int(k["revokedAt"]) else { return nil }; revokedAt = at }
            rows.append(WebKeyKeyRow(kid: kid, label: String((k["label"] as? String ?? "").prefix(64)), fingerprint: k["fingerprint"] as? String ?? "",
                                     active: k["active"] as? Bool == true, state: k["state"] as? String ?? "", revokedAt: revokedAt))
        }
        guard Set(rows.map(\.kid)).count == rows.count else { return nil }
        return WebKeyServerKeys(epoch: epoch, rows: rows)
    }
}

/// Control's record against the server's (review W5, W9).
enum WebKeyReconcile {
    enum Plan: Equatable, Sendable {
        /// Take this record (more revocations or a higher epoch from the server, never fewer).
        case adopt(WebKeyControlState)
        /// The server is behind Control: revocations Control holds are missing there, or its epoch is lower (a rolled-back
        /// web-keys.json, or a revoke the server never confirmed). Revoke `missing` again, then revoke all until the
        /// server's epoch is at least `epochAtLeast`, then take the server's list.
        case repair(missing: [String], epochAtLeast: Int64)
    }

    static func plan(control: WebKeyControlState?, server: WebKeyServerKeys, anchorSpkiSha256: String, nowMs: Int64) -> Plan {
        guard let control else {
            return .adopt(WebKeyControlState(epoch: server.epoch, revoked: server.revoked, anchorSpkiSha256: anchorSpkiSha256, updatedAt: nowMs))
        }
        let serverKids = Set(server.revoked.map(\.kid))
        let missing = control.revoked.map(\.kid).filter { !serverKids.contains($0) }
        if server.epoch < control.epoch || !missing.isEmpty {
            return .repair(missing: missing, epochAtLeast: control.epoch)
        }
        // The server holds every revocation Control holds: take its values (revokedAt is the server's, so the verifier's
        // digest of Control's list equals the server's revocationDigest).
        let next = WebKeyControlState(epoch: server.epoch, revoked: server.revoked, anchorSpkiSha256: anchorSpkiSha256, updatedAt: control.updatedAt)
        return .adopt(next.sameRecord(as: control) ? control : WebKeyControlState(epoch: next.epoch, revoked: next.revoked,
                                                                                    anchorSpkiSha256: anchorSpkiSha256, updatedAt: nowMs))
    }

    /// After a repair: the record to keep, or nil when the server still lacks what Control holds. A kid the server does not
    /// know at all (its entry deleted) can be dropped only once the epoch moved PAST Control's: every approval signed
    /// before is then refused by the server and by the verifier, whatever key it names.
    static func afterRepair(control: WebKeyControlState, server: WebKeyServerKeys, unknown: Set<String>, anchorSpkiSha256: String,
                            nowMs: Int64) -> WebKeyControlState? {
        let serverKids = Set(server.revoked.map(\.kid))
        let stillMissing = control.revokedKids.subtracting(serverKids)
        guard server.epoch >= control.epoch else { return nil }
        if !stillMissing.isEmpty {
            guard stillMissing.isSubset(of: unknown), server.epoch > control.epoch else { return nil }
        }
        return WebKeyControlState(epoch: server.epoch, revoked: server.revoked, anchorSpkiSha256: anchorSpkiSha256, updatedAt: nowMs)
    }

    /// The most revoke-all calls one repair makes.
    static let maxRevokeAllCalls = 8
}

// MARK: - The anchor (review B1)

enum WebKeyAnchorError: Error, Equatable, Sendable {
    case secureEnclaveUnavailable
    case accessControl
    case biometryUnavailable
    case cancelled
    case signFailed
}

protocol WebKeyAnchorSigner: Sendable {
    var publicKeyDER: Data { get }
    /// A P1363 (r||s, 64 bytes) signature over `message`, after Touch ID with `reason` on the system sheet.
    func sign(_ message: Data, reason: String) async throws -> Data
}

/// Owns exactly one completion. Cancellation before begin, during Face ID/Touch ID, or after completion is safe.
/// The closure is the real LAContext.invalidate in production and a counter in tests.
final class WebKeyBiometryAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var invalidate: (@Sendable () -> Void)?
    private var cancelled = false
    private var completed = false

    func begin(_ next: CheckedContinuation<Void, Error>, cancel: @escaping @Sendable () -> Void) -> Bool {
        lock.lock()
        if cancelled || completed || continuation != nil {
            lock.unlock(); cancel(); next.resume(throwing: WebKeyAnchorError.cancelled); return false
        }
        continuation = next; invalidate = cancel
        lock.unlock()
        return true
    }
    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let next = continuation; continuation = nil; invalidate = nil
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { next?.resume(throwing: WebKeyAnchorError.cancelled) } else { next?.resume(with: result) }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let cancel = invalidate; invalidate = nil
        let next = continuation; continuation = nil
        completed = next != nil || completed
        lock.unlock()
        cancel?()
        next?.resume(throwing: WebKeyAnchorError.cancelled)
    }
}

private final class WebKeyAuthenticationContext: @unchecked Sendable {
    let value = LAContext()
}

/// COS Control's Secure Enclave P-256 key: .privateKeyUsage + .biometryCurrentSet (a fingerprint change voids it, which
/// forces a new anchor and new phone enrollments, by design). Its opaque blob lives in the keychain, never in a file.
struct SecureEnclaveWebKeyAnchor: WebKeyAnchorSigner {
    static let blobAccount = "anchor"
    let blob: Data
    let publicKeyDER: Data

    static func create() throws -> SecureEnclaveWebKeyAnchor {
        guard SecureEnclave.isAvailable else { throw WebKeyAnchorError.secureEnclaveUnavailable }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .biometryCurrentSet], &error) else {
            throw WebKeyAnchorError.accessControl
        }
        let key = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: access)
        return SecureEnclaveWebKeyAnchor(blob: key.dataRepresentation, publicKeyDER: key.publicKey.derRepresentation)
    }

    static func load(blob: Data) throws -> SecureEnclaveWebKeyAnchor {
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        return SecureEnclaveWebKeyAnchor(blob: blob, publicKeyDER: key.publicKey.derRepresentation)
    }

    func sign(_ message: Data, reason: String) async throws -> Data {
        let attempt = WebKeyBiometryAttempt()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let authentication = WebKeyAuthenticationContext()
            let context = authentication.value
            defer { context.invalidate() }
            context.localizedReason = reason
            var canError: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &canError) else { throw WebKeyAnchorError.biometryUnavailable }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard attempt.begin(continuation, cancel: { authentication.value.invalidate() }) else { return }
                context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, error in
                    let code = (error as? LAError)?.code
                    attempt.finish(ok ? .success(()) : .failure(code == .userCancel || code == .appCancel ? WebKeyAnchorError.cancelled : WebKeyAnchorError.signFailed))
                }
            }
            try Task.checkCancellation()
            let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob, authenticationContext: context)
            let signature = try key.signature(for: message).rawRepresentation
            try Task.checkCancellation()
            guard signature.count == 64 else { throw WebKeyAnchorError.signFailed }
            return signature
        } onCancel: { attempt.cancel() }
    }

}

// MARK: - The state Settings draws

struct WebKeyHelperAnswer: Sendable {
    var ok: Bool
    var message: String
    var details: Data
}

@MainActor
final class WebKeyState: ObservableObject {
    @Published private(set) var visible = false
    /// 0.5.383: what the server serves (WebKeyServerMode.read). `visible` is mode != .off.
    @Published private(set) var mode: WebKeyServerMode = .off
    /// The server's anchorSetAt (ms), or this session's registration answer's setAt when the server does not report it.
    @Published private(set) var anchorSetAt: Int64?
    @Published private(set) var anchorFingerprint: String?
    @Published private(set) var anchorRegisteredHere = false
    @Published private(set) var foreignAnchor = false
    @Published private(set) var anchorMature = false
    @Published private(set) var card: WebKeyApprovalCard?
    @Published private(set) var cardRefusal: WebKeyApprovalRefusal?
    @Published private(set) var pendingWithoutAudit = false
    @Published private(set) var audit: WebKeyListenerAudit?
    @Published var typedCode = ""
    @Published private(set) var keys: [WebKeyKeyRow] = []
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var rollbackNote: String?
    @Published private(set) var controlState: WebKeyControlState?
    @Published private(set) var protectionReady = false
    @Published private(set) var recoveryRequired = false
    /// 0.5.390: why the phone's HTTPS origin is not trusted yet (WebKeySignerTLS), authority only; nil when it is.
    @Published private(set) var signerTLSLine: String?
    /// Server reopen: why a hand-placed certificate pair was refused (WebKeySignerTLS.storedRefused), authority only.
    @Published private(set) var signerTLSStoredLine: String?
    private(set) var anchor: (any WebKeyAnchorSigner)?
    private var origin: String?
    private var readID: UUID?
    private var actionTask: Task<Void, Never>?
    private var registeredAnchorNeedsStateRebind = false
    private var recoveryRegistration = false

    var runHelper: @MainActor ([String], Data?) async throws -> WebKeyHelperAnswer = { _, _ in throw WebKeyAnchorError.signFailed }
    var secure: any WebKeySecureStore = KeychainWebKeyStore()
    var stateDirectory: URL = WebKeyStateStore.defaultDirectory()
    var store: WebKeyStateStore { WebKeyStateStore(directory: stateDirectory, secure: secure) }
    var makeAnchor: @Sendable () throws -> any WebKeyAnchorSigner = { try SecureEnclaveWebKeyAnchor.create() }
    var loadAnchor: @Sendable (Data) throws -> any WebKeyAnchorSigner = { try SecureEnclaveWebKeyAnchor.load(blob: $0) }
    var anchorBlob: @Sendable (any WebKeyAnchorSigner) -> Data? = { ($0 as? SecureEnclaveWebKeyAnchor)?.blob }
    var now: @MainActor () -> Date = Date.init
    var log: @MainActor (String) -> Void = { _ in }

    init() {}
    /// Bootstrap: the server serves only anchor status and registration.
    var bootstrapOnly: Bool { mode == .bootstrap }
    /// Authority: today's full lane (enrollment, codes, approvals, the key list, the signer audit).
    var authority: Bool { mode == .authority }
    /// The full SHA-256 of this Mac anchor's SPKI DER, the pin's spkiSha256.
    var anchorSpkiSha256: String? { anchor.map { WebKeyHash.sha256Hex($0.publicKeyDER) } }
    private func nowMs() -> Int64 { Int64((now().timeIntervalSince1970 * 1000).rounded(.down)) }
    private func current(_ id: UUID) -> Bool { readID == id && !Task.isCancelled }

    private func ask(_ op: String, body: Data? = nil) async -> (status: Int, body: [String: Any])? {
        guard !Task.isCancelled else { return nil }
        do {
            let answer = try await runHelper(["web-key", "--op", op], body)
            guard !Task.isCancelled, answer.ok,
                  let details = (try? JSONSerialization.jsonObject(with: answer.details)) as? [String: Any],
                  details["transport"] as? String == "answered",
                  let status = (details["httpStatus"] as? NSNumber)?.intValue else { return nil }
            return (status, details["body"] as? [String: Any] ?? [:])
        } catch { return nil }
    }

    /// A new read invalidates approval until both protected records and the server agree.
    func refresh() async {
        let id = UUID()
        readID = id
        protectionReady = false
        recoveryRequired = false
        guard let status = await ask("status"), current(id) else { if current(id) { clear() }; return }
        let served = WebKeyServerMode.read(status: status.status, body: status.body)
        guard served != .off, let suppliedOrigin = status.body["origin"] as? String else { clear(); return }
        visible = true
        if origin != suppliedOrigin || mode != served { card = nil; typedCode = ""; audit = nil }
        origin = suppliedOrigin
        mode = served
        // 0.5.390: one plain line when the server says 3144's certificate is not trusted. Authority only.
        signerTLSLine = served == .authority ? WebKeySignerTLS.problem(body: status.body, now: now()) : nil
        signerTLSStoredLine = served == .authority ? WebKeySignerTLS.storedRefused(body: status.body, now: now()) : nil
        anchorMature = status.body["anchorMature"] as? Bool == true
        loadLocalAnchor()
        let serverAud = status.body["aud"] as? String
        let ourAud = anchor.flatMap { a in WebKeyProtocol.signerHost(suppliedOrigin).map { WebKeyProtocol.aud(anchorDER: a.publicKeyDER, rpId: $0) } }
        anchorRegisteredHere = ourAud != nil && serverAud == ourAud
        foreignAnchor = status.body["anchorRegistered"] as? Bool == true && !anchorRegisteredHere
        if let at = WebKeyServerMode.int(status.body["anchorSetAt"]) { anchorSetAt = at } else if !anchorRegisteredHere { anchorSetAt = nil }
        if served == .bootstrap {
            // Bootstrap: the anchor only. No key list, no pending request, no audit, no card; nothing here can approve.
            card = nil; cardRefusal = nil; pendingWithoutAudit = false; keys = []; typedCode = ""
            if let anchor, anchorRegisteredHere { bindBootstrapRecord(anchorSpki: anchor.publicKeyDER, statusEpoch: WebKeyServerMode.int(status.body["epoch"])) }
            return
        }
        guard let anchor, anchorRegisteredHere else {
            card = nil; cardRefusal = nil; pendingWithoutAudit = false; keys = []; typedCode = ""
            return
        }
        guard await syncState(anchorSpki: anchor.publicKeyDER, id: id), current(id) else {
            if current(id) { card = nil; typedCode = "" }
            return
        }
        protectionReady = true
        await loadPending(anchorDER: anchor.publicKeyDER, id: id)
    }

    private func clear() {
        readID = nil
        mode = .off; anchorSetAt = nil
        visible = false; card = nil; cardRefusal = nil; pendingWithoutAudit = false; keys = []; typedCode = ""
        anchorRegisteredHere = false; foreignAnchor = false; protectionReady = false
        controlState = nil; audit = nil; origin = nil; anchorMature = false; recoveryRequired = false
        signerTLSLine = nil
        signerTLSStoredLine = nil
    }

    /// Bootstrap, right after THIS run registered the anchor (the same condition as authority's rebind): start Control's
    /// protected record for it, so turning authority on later finds a record for this anchor instead of asking for a reset.
    /// The epoch is the status reply's (0 when it has none) and the revocation list is empty: both are at or below an honest
    /// server's, so authority's first read adopts the server's list exactly as a fresh registration would. A record that
    /// already belongs to this anchor is kept as it is. An unreadable or damaged keychain record is never overwritten.
    private func bindBootstrapRecord(anchorSpki: Data, statusEpoch: Int64?) {
        guard registeredAnchorNeedsStateRebind else { return }
        let sha = WebKeyHash.sha256Hex(anchorSpki)
        switch store.load() {
        case .mirrorUnavailable:
            message = "Control cannot read its keychain record, so it could not start its phone record."; return
        case .mirrorMissing:
            message = "Control's protected phone record is damaged. Once phone approvals are on, reset them to enroll."; return
        case .ok(let saved), .repaired(let saved, _):
            if saved.anchorSpkiSha256 == sha { controlState = saved; registeredAnchorNeedsStateRebind = false; return }
        case .none:
            break
        }
        let seed = WebKeyControlState(epoch: statusEpoch ?? 0, revoked: [], anchorSpkiSha256: sha, updatedAt: nowMs())
        guard store.save(seed) else { message = "Control could not save its protected phone record."; return }
        controlState = seed
        registeredAnchorNeedsStateRebind = false
        log("web-key bootstrap record started")
    }

    private func loadLocalAnchor() {
        guard anchor == nil else { return }
        if case .found(let blob) = secure.read(SecureEnclaveWebKeyAnchor.blobAccount), let loaded = try? loadAnchor(blob) { anchor = loaded }
        anchorFingerprint = anchor.map { WebKeySPKI.fingerprint($0.publicKeyDER) }
    }

    /// Missing or unreadable protected mirrors are never reconstructed from an untrusted server snapshot.
    private func syncState(anchorSpki: Data, id: UUID) async -> Bool {
        let anchorSha = WebKeyHash.sha256Hex(anchorSpki)
        var saved: WebKeyControlState?
        switch store.load() {
        case .none:
            guard registeredAnchorNeedsStateRebind else { controlState = nil; recoveryRequired = true; message = "Control's protected phone record is missing. Reset phone approvals to enroll again."; return false }
            saved = nil
        case .ok(let s): saved = s
        case .repaired(let s, let rewrote):
            saved = s
            guard rewrote else { controlState = s; message = "Control could not restore its protected phone record. Phone approvals stay off."; return false }
            rollbackNote = "Control's approval record on disk was older than its keychain copy. It was rewritten from the keychain."
            log("web-key state file repaired from keychain")
        case .mirrorUnavailable:
            controlState = nil
            message = "Control cannot read its keychain record, so phone approvals stay off."
            return false
        case .mirrorMissing:
            guard recoveryRegistration else {
                controlState = nil; recoveryRequired = true
                message = "Control's protected phone record is missing or damaged. Reset phone approvals to enroll again."
                return false
            }
            saved = nil
        }
        if let saved, saved.anchorSpkiSha256 != anchorSha, !registeredAnchorNeedsStateRebind {
            controlState = saved; recoveryRequired = true
            message = "The protected phone record belongs to a different Mac key. Reset phone approvals to enroll again."
            return false
        }
        if saved?.anchorSpkiSha256 != anchorSha { saved = nil }
        guard let answer = await ask("keys"), current(id), answer.status == 200,
              var server = WebKeyServerKeys.parse(answer.body) else {
            if current(id) { controlState = saved; message = "The COS server did not confirm its phone key list. Phone approvals stay off." }
            return false
        }
        switch WebKeyReconcile.plan(control: saved, server: server, anchorSpkiSha256: anchorSha, nowMs: nowMs()) {
        case .adopt(let next):
            if next != saved, !store.save(next) {
                controlState = saved
                message = "Control could not save its protected phone record. Phone approvals stay off."
                return false
            }
            controlState = next
        case .repair(let missing, let atLeast):
            guard let control = saved else { return false }
            var unknown = Set<String>()
            for kid in missing {
                let r = await ask("revoke", body: WebKeyJCS.bytes(["kid": kid, "reason": "control_record"] as [String: Any]))
                guard current(id) else { return false }
                if r?.status == 404 { unknown.insert(kid) }
            }
            guard control.epoch < WebKeyJCS.maxSafe else { controlState = control; return false }
            let need = unknown.isEmpty ? atLeast : max(atLeast, control.epoch + 1)
            var calls = 0
            guard let again = await ask("keys"), current(id), again.status == 200, let parsed = WebKeyServerKeys.parse(again.body) else { return false }
            server = parsed
            while server.epoch < need, calls < WebKeyReconcile.maxRevokeAllCalls {
                calls += 1
                guard let r = await ask("revoke-all", body: Data("{}".utf8)), current(id), r.status == 200 else { break }
                guard let again = await ask("keys"), current(id), again.status == 200, let parsed = WebKeyServerKeys.parse(again.body) else { break }
                server = parsed
            }
            guard current(id) else { return false }
            guard let next = WebKeyReconcile.afterRepair(control: control, server: server, unknown: unknown, anchorSpkiSha256: anchorSha, nowMs: nowMs()) else {
                controlState = control; keys = server.rows
                rollbackNote = "The server's key list is behind Control's and could not be repaired. Phone approvals stay off."
                return false
            }
            guard store.save(next) else { controlState = control; message = "Control could not save its protected phone record. Phone approvals stay off."; return false }
            controlState = next
            rollbackNote = calls > 0
                ? "The server's key list was behind Control's. Control revoked every phone key to match. Enroll your phone again."
                : "The server's key list was missing a revocation. Control revoked that key again."
            log("web-key server behind control: revokes=\(missing.count) unknown=\(unknown.count) revokeAll=\(calls)")
        }
        keys = server.rows
        registeredAnchorNeedsStateRebind = false; recoveryRegistration = false; recoveryRequired = false
        return true
    }

    private func loadPending(anchorDER: Data, id: UUID) async {
        guard let answer = await ask("pending"), current(id) else { return }
        guard answer.status == 200, let pending = answer.body["pending"] as? [String: Any] else {
            card = nil; cardRefusal = nil; pendingWithoutAudit = false; typedCode = ""
            return
        }
        if !(audit?.fresh(now: now()) ?? false) { await runAudit() }
        guard current(id), protectionReady, audit?.fresh(now: now()) == true else {
            if current(id) { card = nil; typedCode = ""; cardRefusal = nil; pendingWithoutAudit = true }
            return
        }
        pendingWithoutAudit = false
        switch WebKeyApprovalCheck.card(pending: pending, anchorDER: anchorDER, controlEpoch: controlState?.epoch, nowMs: nowMs()) {
        case .success(let verified):
            if card?.approvalBytes != verified.approvalBytes { typedCode = "" }
            card = verified; cardRefusal = nil
        case .failure(let refusal):
            card = nil; typedCode = ""; cardRefusal = refusal
            log("web-key enrollment card refused \(refusal.rawValue)")
        }
    }

    func runAudit() async {
        let expectedRead = readID
        // Bootstrap asks only for the anchor-scope audit, whose answer can never pass the signer gate (fresh(now:)).
        let scope: WebKeyListenerAudit.Scope = mode == .bootstrap ? .anchor : .signer
        do {
            let answer = try await runHelper(["web-key", "--op", scope == .anchor ? "anchor-listeners" : "listeners"], nil)
            guard !Task.isCancelled, expectedRead == readID else { return }
            guard answer.ok, let details = (try? JSONSerialization.jsonObject(with: answer.details)) as? [String: Any] else {
                audit = WebKeyListenerAudit(genuine: false, reason: "no_answer", checkedAt: now(), scope: scope); return
            }
            audit = scope == .anchor ? WebKeyListenerAudit.judgeAnchor(details, at: now()) : WebKeyListenerAudit.judge(details, at: now())
        } catch {
            guard !Task.isCancelled, expectedRead == readID else { return }
            audit = WebKeyListenerAudit(genuine: false, reason: "no_answer", checkedAt: now(), scope: scope)
        }
        if audit?.genuine != true { log("web-key signer audit refused \(audit?.reason ?? "")") }
    }

    var approveAllowed: Bool {
        mode == .authority && visible && anchorRegisteredHere && protectionReady && controlState != nil &&
        WebKeyApproveGate.allowed(card: card, typed: typedCode, audit: audit, anchor: anchor != nil, now: now())
    }

    func startRegistration() {
        guard !busy, actionTask == nil, !anchorRegisteredHere, !foreignAnchor else { return }
        actionTask = Task { await createOrRegisterAnchor(); actionTask = nil }
    }
    /// Replacing the server's anchor (it is not this Mac's) revokes every phone key and restarts the 24 hour clock, so it
    /// runs only from its confirmation (WebKeyAnchorSection's "Replace the approval key?").
    func startReplace() {
        guard !busy, actionTask == nil, foreignAnchor else { return }
        actionTask = Task { await createOrRegisterAnchor(replace: true); actionTask = nil }
    }
    func startReset() {
        guard !busy, actionTask == nil, recoveryRequired, mode == .authority else { return }
        actionTask = Task { await createOrRegisterAnchor(recovery: true); actionTask = nil }
    }
    func startApproval() {
        guard !busy, actionTask == nil else { return }
        actionTask = Task { await approve(); actionTask = nil }
    }
    func cancelActions() {
        actionTask?.cancel(); actionTask = nil
        readID = nil; card = nil; typedCode = ""; protectionReady = false; audit = nil
    }

    /// Registration's audit by mode: the full signer audit with authority on (today's), the anchor-scope audit in bootstrap.
    private func registrationAuditFresh(_ registering: WebKeyServerMode) -> Bool {
        guard mode == registering else { return false }
        switch registering {
        case .authority: return audit?.fresh(now: now()) == true
        case .bootstrap: return audit?.freshForAnchorRegistration(now: now()) == true
        case .off: return false
        }
    }

    func createOrRegisterAnchor(recovery: Bool = false, replace: Bool = false) async {
        guard visible, !busy, let expectedRead = readID else { return }
        // The server resets setAt even when the SAME key registers again (and a replacement revokes every phone), so a
        // plain Register never runs over an anchor the server already holds: only a confirmed replace or reset does.
        guard recovery || replace || (!anchorRegisteredHere && !foreignAnchor) else {
            message = "The server already holds an approval key. Nothing was registered."; return
        }
        // Reset is authority's recovery; bootstrap never offers it.
        let registering = mode
        guard registering != .off, !recovery || registering == .authority else { return }
        busy = true; defer { busy = false }
        message = nil
        await runAudit()
        guard current(expectedRead), registrationAuditFresh(registering) else { message = audit?.line ?? WebKeyListenerAudit.notGenuineLine; return }
        if !(recovery || replace) {
            // Read the server again: an anchor registered since the last read (another press, another Control) is never
            // registered over. Only a reply that says no anchor goes on.
            guard let fresh = await ask("status"), current(expectedRead), fresh.status == 200,
                  WebKeyServerMode.read(status: fresh.status, body: fresh.body) == registering,
                  fresh.body["anchorRegistered"] as? Bool == false else {
                message = "The server already holds an approval key, or did not say. Nothing was registered."; return
            }
        }
        loadLocalAnchor()
        var candidate = anchor
        var newBlob: Data?
        if recovery || candidate == nil {
            switch secure.read(SecureEnclaveWebKeyAnchor.blobAccount) {
            case .failed: message = "Control could not read its existing Touch ID key."; return
            case .found where !recovery: message = "Control could not load its existing Touch ID key."; return
            default: break
            }
            // Recovery rotates the anchor. Reusing the old anchor would silently forget its revocation history.
            do {
                let made = try makeAnchor()
                guard let blob = anchorBlob(made) else { message = "Control could not keep the new key."; return }
                candidate = made; newBlob = blob
            } catch { message = "This Mac could not make a Touch ID key."; return }
        }
        guard let candidate else { return }
        if recovery, candidate.publicKeyDER == anchor?.publicKeyDER { message = "Reset requires a new Mac key. Nothing was changed."; return }
        let spki = candidate.publicKeyDER
        let statement = WebKeyProtocol.anchorStatement(spki: spki, createdAtMs: nowMs())
        let reason = recovery ? "Reset phone approvals, revoke every enrolled phone and register Mac key " + WebKeySPKI.fingerprint(spki) + "." : WebKeyProtocol.anchorReason(fingerprint: WebKeySPKI.fingerprint(spki))
        let signature: Data
        do { signature = try await candidate.sign(statement, reason: reason) }
        catch { message = "Touch ID did not sign. Nothing was registered."; return }
        guard current(expectedRead), registrationAuditFresh(registering) else { message = "The approval check expired or was cancelled. Nothing was registered."; return }
        if let newBlob {
            guard secure.write(SecureEnclaveWebKeyAnchor.blobAccount, newBlob) else { message = "Control could not keep the new key in its keychain."; return }
            anchor = candidate; anchorFingerprint = WebKeySPKI.fingerprint(spki)
        }
        guard let answer = await ask("anchor", body: WebKeyProtocol.anchorBody(spki: spki, statement: statement, signature: signature)) else {
            message = "The COS server did not answer."; return
        }
        guard answer.status == 201 else { message = "The server refused the Mac key. Nothing was registered."; return }
        registeredAnchorNeedsStateRebind = true; recoveryRegistration = recovery
        if let at = WebKeyServerMode.int(answer.body["setAt"]) { anchorSetAt = at }
        log("web-key anchor registered")
        message = registering == .bootstrap
            ? "Registered. Its 24 hour clock started. Copy the pin and commit it yourself."
            : "Registered. Copy the pin and commit it yourself. New keys approve nothing for 24 hours."
        await refresh()
    }

    func pinJSON() -> String? { anchor.map { WebKeyProtocol.anchorPin(spki: $0.publicKeyDER, pinnedAtMs: nowMs()) } }

    func approve() async {
        guard !busy, visible, let expectedRead = readID else { return }
        busy = true; defer { busy = false }
        if !(audit?.fresh(now: now()) ?? false) { await runAudit() }
        guard current(expectedRead), approveAllowed, let card, let anchor else { message = "Type the code your phone shows after the approval checks pass."; return }
        let signedState = controlState
        let signature: Data
        do { signature = try await anchor.sign(card.approvalBytes, reason: WebKeyProtocol.approveReason(fingerprint: card.fingerprint, sas: card.sas)) }
        catch { message = "Touch ID did not approve. Nothing was enrolled."; return }
        guard current(expectedRead) else { message = "Approval was cancelled. Nothing was enrolled."; return }
        // Touch ID can take longer than the request or the audit. Re-read the exact pending bytes and epoch before POST.
        await refresh()
        guard !Task.isCancelled, approveAllowed, self.card?.approvalBytes == card.approvalBytes,
              let signedState, controlState?.sameRecord(as: signedState) == true else {
            message = "The phone request or approval checks changed. Nothing was enrolled."; return
        }
        let body = WebKeyJCS.bytes(["enrollId": card.enrollId, "anchorSig": WebKeyB64.encode(signature)] as [String: Any])!
        guard let answer = await ask("approve", body: body) else { message = "The COS server did not answer."; return }
        guard answer.status == 200 else { message = "The server refused the phone approval. Nothing was enrolled."; return }
        log("web-key enrollment approved")
        typedCode = ""; message = "Your phone is enrolled."
        await refresh()
    }

    /// Control's protected record to revoke on top of, or why there is none (said as it is, never "approvals stay off").
    private func protectedRevocationBase(anchorSha: String) -> (state: WebKeyControlState?, problem: String?) {
        let saved: WebKeyControlState
        switch store.load() {
        case .ok(let state): saved = state
        case .repaired(let state, let rewrote) where rewrote: saved = state
        default: return (nil, WebKeyRevokeOutcome.unreadable)
        }
        guard saved.anchorSpkiSha256 == anchorSha else { return (nil, WebKeyRevokeOutcome.otherKey) }
        return (saved, nil)
    }

    /// Security review 2026-11-12, blocker 2: the server's revoke is called in every case; it needs no anchor. Control's
    /// protected record is still written first when it can be, so a crash or cancellation cannot erase the intent, and each
    /// failure is said as what it is (WebKeyRevokeOutcome). True only when the server answered 200.
    @discardableResult
    func revoke(_ kid: String) async -> Bool {
        guard mode == .authority, visible, !busy,
              kid.range(of: #"\A[A-Za-z0-9_-]{22}\z"#, options: .regularExpression) != nil else { return false }
        busy = true; defer { busy = false }
        protectionReady = false; card = nil; typedCode = ""
        var local: (saved: Bool, problem: String?) = (false, WebKeyRevokeOutcome.noAnchor)
        if let anchor {
            let sha = WebKeyHash.sha256Hex(anchor.publicKeyDER)
            let base = protectedRevocationBase(anchorSha: sha)
            if var s = base.state {
                if !s.revokedKids.contains(kid) { s = WebKeyControlState(epoch: s.epoch, revoked: s.revoked + [WebKeyRevocation(kid: kid, revokedAt: nowMs())], anchorSpkiSha256: sha, updatedAt: nowMs()) }
                if store.save(s) { controlState = s; local = (true, nil) } else { local = (false, WebKeyRevokeOutcome.notRecorded) }
            } else {
                local = (false, base.problem)
            }
        }
        let answer = await ask("revoke", body: WebKeyJCS.bytes(["kid": kid, "reason": "revoked_in_control"] as [String: Any]))
        let confirmed = answer?.status == 200
        let outcome = WebKeyRevokeOutcome.message(serverConfirmed: confirmed, localSaved: local.saved, localProblem: local.problem)
        if !Task.isCancelled { await refresh() }
        // Said after the read, so the refresh's own line cannot hide what this revoke did.
        if let outcome { message = outcome }
        return confirmed
    }

    /// Like revoke: the server's revoke-all is called in every case, after Control's epoch moves when it can. True only when
    /// the server answered 200 (option A's Off reads it: a false never reads as stopped).
    @discardableResult
    func revokeAll() async -> Bool {
        guard mode == .authority, visible, !busy else { return false }
        busy = true; defer { busy = false }
        protectionReady = false; card = nil; typedCode = ""
        var local: (saved: Bool, problem: String?) = (false, WebKeyRevokeOutcome.noAnchor)
        if let anchor {
            let sha = WebKeyHash.sha256Hex(anchor.publicKeyDER)
            let base = protectedRevocationBase(anchorSha: sha)
            if let saved = base.state, saved.epoch < WebKeyJCS.maxSafe {
                let s = WebKeyControlState(epoch: saved.epoch + 1, revoked: saved.revoked, anchorSpkiSha256: sha, updatedAt: nowMs())
                if store.save(s) { controlState = s; local = (true, nil) } else { local = (false, WebKeyRevokeOutcome.notRecorded) }
            } else {
                local = (false, base.problem ?? WebKeyRevokeOutcome.epochFull)
            }
        }
        let answer = await ask("revoke-all", body: Data("{}".utf8))
        let confirmed = answer?.status == 200
        let outcome = WebKeyRevokeOutcome.message(serverConfirmed: confirmed, localSaved: local.saved, localProblem: local.problem)
        if !Task.isCancelled { await refresh() }
        // Said after the read, so the refresh's own line cannot hide what this revoke did.
        if let outcome { message = outcome }
        return confirmed
    }
}
