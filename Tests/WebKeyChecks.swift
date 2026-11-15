import CryptoKit
import Foundation
import Security

// Phone approvals (Sources/WebKeyCore.swift and HelperSources/PairingCore.swift's WebKeyHelperCore), compiled on their own
// (Tests/run-web-key.sh). Vectors come from the SERVER's code (Tests/fixtures/web-key/golden.json, made by
// gen_control_golden.mts from the cos-glasses-server 6.99.31 worktree): the anchor statement registerAnchor accepted, a
// real pendingView, the SAS, the revocation digest and JCS texts. Every effect is a stand-in: no keychain, no Secure
// Enclave, no Touch ID, no helper, no server. State files go to a temporary folder.

nonisolated(unsafe) var failures = 0
nonisolated(unsafe) var passes = 0

func check(_ condition: Bool, _ behaviour: String, _ detail: @autoclosure () -> String = "") {
    if condition { passes += 1; return }
    failures += 1
    FileHandle.standardError.write(Data("check failed [\(behaviour)]: \(detail())\n".utf8))
}

func obj(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }

/// What the app receives after the helper: every number becomes a Double (Models.swift's JSONValue) and is encoded again.
func viaJSONValue(_ value: Any) -> Any {
    if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return NSNumber(value: n.doubleValue) }
    if let a = value as? [Any] { return a.map(viaJSONValue) }
    if let o = value as? [String: Any] { return o.mapValues(viaJSONValue) }
    return value
}

/// A control for the signer TLS checks only: what this Mac's keychain trust (system, admin and user domains, no custom
/// anchors) says about a chain, which is how Apple's curl decides. Reads trust settings, never a keychain item or a key.
func keychainTrusts(_ chain: [Data], host: String) -> Bool {
    let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    var made: SecTrust?
    guard !certificates.isEmpty, certificates.count == chain.count,
          SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &made) == errSecSuccess,
          let trust = made, SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
    return SecTrustEvaluateWithError(trust, nil)
}

final class MemoryStore: WebKeySecureStore, @unchecked Sendable {
    var items: [String: Data] = [:]
    var failRead = false
    var failWrite = false
    var failedWriteAccounts: Set<String> = []
    var reads = 0
    var writes = 0
    func read(_ account: String) -> WebKeySecureRead {
        reads += 1
        if failRead { return .failed(-25293) }
        return items[account].map { .found($0) } ?? .missing
    }
    func write(_ account: String, _ data: Data) -> Bool {
        writes += 1
        if failWrite || failedWriteAccounts.contains(account) { return false }
        items[account] = data
        return true
    }
}

final class Reasons: @unchecked Sendable {
    var list: [String] = []
    var refuse = false
    var cancellations = 0
    var onSign: (@MainActor @Sendable () async -> Void)?
}
func audited(_ details: [String: Any]) -> [String: Any] {
    var details = details
    details["assets"] = ["verified": true, "webControlManifestSha256": String(repeating: "a", count: 64), "webSignerManifestSha256": String(repeating: "b", count: 64)]
    return details
}

struct SoftAnchor: WebKeyAnchorSigner {
    let raw: Data
    let reasons: Reasons
    var publicKeyDER: Data { (try! P256.Signing.PrivateKey(rawRepresentation: raw)).publicKey.derRepresentation }
    func sign(_ message: Data, reason: String) async throws -> Data {
        reasons.list.append(reason)
        await reasons.onSign?()
        if reasons.refuse { throw WebKeyAnchorError.cancelled }
        return try P256.Signing.PrivateKey(rawRepresentation: raw).signature(for: message).rawRepresentation
    }
}

func verifies(_ spki: Data, _ message: Data, _ signature: Data) -> Bool {
    guard let key = try? P256.Signing.PublicKey(derRepresentation: spki),
          let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
    return key.isValidSignature(sig, for: message)
}

func scratchDir(_ name: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cos-web-key-\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A stand-in server behind the helper: one answer per op, every call recorded.
@MainActor final class FakeServer {
    var answers: [String: (Int, [String: Any])] = [:]
    var listeners: [String: Any] = [:]
    var anchorListeners: [String: Any] = [:]
    var calls: [(op: String, body: [String: Any])] = []
    var onCall: ((String, [String: Any]) -> Void)?
    var pauseOp: String?
    var paused = false
    var continuation: CheckedContinuation<Void, Never>?
    func release() {
        pauseOp = nil; paused = false
        let next = continuation; continuation = nil; next?.resume()
    }
    func count(_ op: String) -> Int { calls.filter { $0.op == op }.count }
    func run(_ args: [String], _ body: Data?) async -> WebKeyHelperAnswer {
        let op = args.count >= 3 && args[0] == "web-key" && args[1] == "--op" ? args[2] : "?"
        if pauseOp == op {
            await withCheckedContinuation { next in paused = true; continuation = next }
        }
        let parsed = body.map(obj) ?? [:]
        calls.append((op, parsed))
        onCall?(op, parsed)
        if op == "listeners" { return WebKeyHelperAnswer(ok: true, message: "", details: json(viaJSONValue(listeners))) }
        if op == "anchor-listeners" { return WebKeyHelperAnswer(ok: true, message: "", details: json(viaJSONValue(anchorListeners))) }
        guard let (status, b) = answers[op] else { return WebKeyHelperAnswer(ok: true, message: "", details: json(["transport": "unavailable"])) }
        return WebKeyHelperAnswer(ok: true, message: "", details: json(viaJSONValue(WebKeyHelperCore.answer(status: status, body: b))))
    }
}

@main
struct WebKeyChecks {
    @MainActor
    static func main() async {
        let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Tests/fixtures/web-key/golden.json"
        guard let goldenData = FileManager.default.contents(atPath: path) else { print("no golden at \(path)"); exit(2) }
        let g = obj(goldenData)
        let anchorG = g["anchor"] as! [String: Any]
        let expect = g["expect"] as! [String: Any]
        let selfDns = g["selfDns"] as! String
        let anchorRaw = WebKeyB64.decode(anchorG["d"] as! String)!
        let anchorDER = WebKeySPKI.parse(b64: anchorG["spki"] as! String)!
        let pending = obj(Data((g["pendingJson"] as! String).utf8))

        encodings(g, anchorG: anchorG, anchorDER: anchorDER, selfDns: selfDns)
        anchorAndPin(anchorG: anchorG, anchorDER: anchorDER, anchorRaw: anchorRaw)
        card(pending: pending, expect: expect, anchorDER: anchorDER, anchorRaw: anchorRaw)
        codeAndGate(pending: pending, anchorDER: anchorDER)
        audit()
        stateFile(g)
        store()
        reconcile()
        helperCore()
        assets()
        signerTLSTrust(fixtures: URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("tls", isDirectory: true))
        signerTLSLine()
        reasonParity(g)
        phoneApprovalsSwitch()
        phoneApprovalsOnGate()
        await phoneApprovalsReadinessFlow()
        await phoneApprovalsOff()
        await cancellation()
        await flow(pending: pending, anchorG: anchorG, anchorDER: anchorDER, anchorRaw: anchorRaw, selfDns: selfDns)
        await recoveryFlow(anchorRaw: anchorRaw, selfDns: selfDns)
        bootstrapRules(selfDns: selfDns)
        await bootstrapFlow(anchorG: anchorG, anchorDER: anchorDER, anchorRaw: anchorRaw, selfDns: selfDns)

        print("web key checks: \(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func encodings(_ g: [String: Any], anchorG: [String: Any], anchorDER: Data, selfDns: String) {
        for case let row as [String: Any] in g["jcs"] as! [Any] {
            check(WebKeyJCS.encode(row["value"]!) == row["text"] as? String, "jcs", "\(WebKeyJCS.encode(row["value"]!) ?? "nil") vs \(row["text"]!)")
        }
        check(WebKeyJCS.encode(NSNumber(value: 1.5)) == nil && WebKeyJCS.encode(NSNumber(value: 9_007_199_254_740_992 as Int64)) == nil, "jcs", "floats and unsafe integers are not signable")
        // Numerical equality also rejects 1.5; integral floats exercise the distinct type guard.
        let integralFloats = try! JSONSerialization.jsonObject(with: Data("[1.0,-0.0,1e3,9007199254740990.0]".utf8)) as! [NSNumber]
        check(integralFloats.allSatisfy { ["d", "f"].contains(String(cString: $0.objCType)) }, "jcs", "JSON fixtures retain floating NSNumber types")
        check(integralFloats.allSatisfy { WebKeyJCS.encode($0) == nil }, "jcs", "integral-valued floating numbers are not signable")
        check(WebKeyJCS.encode(["a": Date()]) == nil, "jcs", "other types are not signable")
        check(WebKeyB64.decode("AQ") == Data([1]) && WebKeyB64.decode("AR") == nil && WebKeyB64.decode("AQ==") == nil && WebKeyB64.decode("A") == nil
              && WebKeyB64.decode("a+b/") == nil && WebKeyB64.decode("") == nil, "b64", "strict base64url")
        check(WebKeyHash.sha256Hex(anchorDER) == anchorG["spkiSha256"] as? String && WebKeySPKI.fingerprint(anchorDER) == anchorG["fingerprint"] as? String
              && WebKeySPKI.kid(anchorDER) == anchorG["kid"] as? String, "spki", "sha, fingerprint and kid as the server computes them")
        check(WebKeySPKI.parse(der: anchorDER + Data([0])) == nil && WebKeySPKI.parse(der: Data(anchorDER.dropLast())) == nil, "spki", "trailing or missing bytes refused")
        check(WebKeyProtocol.aud(anchorDER: anchorDER, rpId: selfDns) == anchorG["aud"] as? String
              && WebKeyProtocol.aud(anchorDER: anchorDER, rpId: " " + selfDns.uppercased() + " ") == anchorG["aud"] as? String, "aud", "aud from the anchor and the lower-case host")
        let v = g["sasVector"] as! [String: String]
        check(WebKeyProtocol.sas(challenge: WebKeyB64.decode(v["challenge"]!)!, spki: WebKeyB64.decode(v["spki"]!)!, phoneNonce: WebKeyB64.decode(v["r"]!)!) == v["sas"],
              "sas", "the SAS as the server's sasOf")
        check(WebKeyProtocol.signerHost("https://\(selfDns):3144") == selfDns && WebKeyProtocol.signerHost("https://\(selfDns):3143") == nil
              && WebKeyProtocol.signerHost("http://\(selfDns):3144") == nil && WebKeyProtocol.signerHost("https://\(selfDns):3144/x") == nil
              && WebKeyProtocol.signerHost("https://100.64.0.1:3144") == nil && WebKeyProtocol.signerHost("https://evil.example.com:3144") == nil,
              "origin", "only https://<ts.net name>:3144")
    }

    static func anchorAndPin(anchorG: [String: Any], anchorDER: Data, anchorRaw: Data) {
        let statement = WebKeyProtocol.anchorStatement(spki: anchorDER, createdAtMs: anchorG["createdAt"] as! Int64)
        check(anchorG["registered"] as? Bool == true && statement == WebKeyB64.decode(anchorG["statement"] as! String),
              "anchor statement", "the exact bytes the server's registerAnchor accepted")
        let sig = try! P256.Signing.PrivateKey(rawRepresentation: anchorRaw).signature(for: statement).rawRepresentation
        let body = obj(WebKeyProtocol.anchorBody(spki: anchorDER, statement: statement, signature: sig))
        check(Set(body.keys) == ["anchorPub", "statement", "signature"] && body["anchorPub"] as? String == anchorG["spki"] as? String
              && verifies(anchorDER, statement, WebKeyB64.decode(body["signature"] as! String)!), "anchor statement", "the body names the key and self-verifies")
        check(WebKeyHelperCore.body(op: "anchor", stdin: WebKeyProtocol.anchorBody(spki: anchorDER, statement: statement, signature: sig)) != nil,
              "anchor statement", "the helper accepts the body")
        let pin = obj(Data(WebKeyProtocol.anchorPin(spki: anchorDER, pinnedAtMs: 1_786_000_000_123).utf8))
        check(Set(pin.keys) == ["v", "anchorPub", "spkiSha256", "fingerprint", "pinnedAt"] && (pin["v"] as? NSNumber)?.intValue == 1
              && pin["anchorPub"] as? String == anchorG["spki"] as? String && pin["spkiSha256"] as? String == anchorG["spkiSha256"] as? String
              && pin["fingerprint"] as? String == anchorG["fingerprint"] as? String && (pin["pinnedAt"] as? NSNumber)?.int64Value == 1_786_000_000_123,
              "pin", "the verifier's PIN_KEYS, from this anchor")
        check(WebKeyProtocol.approveReason(fingerprint: "AAAA-BBBB-CCCC-DDDD", sas: "382914") == "Enroll phone key AAAA-BBBB-CCCC-DDDD code 382 914 for COS web approvals",
              "touch id reason", "the fingerprint and code in the system sheet")
        check(!WebKeyProtocol.approveReason(fingerprint: "A", sas: "123456").contains("\u{2014}") && !WebKeyProtocol.anchorReason(fingerprint: "A").contains("\u{2014}"),
              "touch id reason", "no em dash")
    }

    static func tampered(_ pending: [String: Any], _ change: (inout [String: Any]) -> Void) -> [String: Any] {
        var approval = obj(WebKeyB64.decode(pending["approvalJcs"] as! String)!)
        change(&approval)
        var out = pending
        out["approval"] = nil
        out["approvalJcs"] = WebKeyB64.encode(WebKeyJCS.bytes(approval)!)
        return out
    }

    static func card(pending: [String: Any], expect: [String: Any], anchorDER: Data, anchorRaw: Data) {
        let now = (pending["startedAt"] as! NSNumber).int64Value + 1000
        let result = WebKeyApprovalCheck.card(pending: pending, anchorDER: anchorDER, controlEpoch: 0, nowMs: now)
        guard case .success(let c) = result else { check(false, "card golden", "\(result)"); return }
        check(c.sas == expect["sas"] as? String && c.fingerprint == expect["fingerprint"] as? String && c.kid == expect["kid"] as? String
              && c.label == expect["label"] as? String && c.userAgent == expect["userAgent"] as? String && c.remote == expect["remote"] as? String
              && c.enrollId == pending["enrollId"] as? String && c.rotates == nil, "card golden", "every value as the server froze it")
        check(c.approvalBytes == WebKeyB64.decode(pending["approvalJcs"] as! String), "card golden", "the bytes to sign are approvalJcs exactly")
        check(verifies(anchorDER, c.approvalBytes, WebKeyB64.decode(expect["nodeAnchorSig"] as! String)!) && expect["approveAccepted"] as? Bool == true,
              "card signature", "node's P1363 signature over the same bytes verifies in CryptoKit")
        let ours = try! P256.Signing.PrivateKey(rawRepresentation: anchorRaw).signature(for: c.approvalBytes).rawRepresentation
        check(ours.count == 64 && verifies(anchorDER, c.approvalBytes, ours), "card signature", "CryptoKit's raw signature is 64-byte P1363")
        // The round trip through the helper (numbers become Doubles) still matches the bytes.
        let roundTrip = obj(json(viaJSONValue(pending)))
        if case .success = WebKeyApprovalCheck.card(pending: roundTrip, anchorDER: anchorDER, controlEpoch: 0, nowMs: now) { check(true, "card golden") }
        else { check(false, "card golden", "the helper's round trip refused") }
        func refused(_ p: [String: Any], _ why: WebKeyApprovalRefusal, _ tag: String, epoch: Int64? = 0, at: Int64? = nil, anchor: Data? = nil) {
            let r = WebKeyApprovalCheck.card(pending: p, anchorDER: anchor ?? anchorDER, controlEpoch: epoch, nowMs: at ?? now)
            if case .failure(let got) = r { check(got == why, tag, "\(got) instead of \(why)") } else { check(false, tag, "accepted, expected \(why)") }
        }
        for bad in ["", "short", (pending["enrollId"] as! String) + "="] {
            var p = tampered(pending) { $0["enrollId"] = bad }
            p["enrollId"] = bad
            refused(p, .pendingMalformed, "W4 enrollment id bytes")
        }
        // Review W4: server display fields outside approvalJcs are refused, never shown.
        for key in ["sas", "fingerprint", "label", "userAgent", "remote", "kid"] {
            var p = pending; p[key] = key == "sas" ? "000000" : "spoof"
            refused(p, .extraDisplayFields, "W4 extra display fields")
        }
        var lie = pending; var copy = pending["approval"] as! [String: Any]; copy["label"] = "Miles's iPhone"; lie["approval"] = copy
        refused(lie, .approvalMismatch, "W4 approval copy")
        var lie2 = pending; var copy2 = pending["approval"] as! [String: Any]; copy2["sas"] = "000000"; lie2["approval"] = copy2
        refused(lie2, .approvalMismatch, "W4 approval copy")
        // The bytes themselves must hold together.
        refused(tampered(pending) { $0["sas"] = "000000" }, .sasMismatch, "W4 sas from bytes")
        refused(tampered(pending) { $0["fingerprint"] = "0000-0000-0000-0000" }, .fingerprintMismatch, "W4 fingerprint from bytes")
        refused(tampered(pending) { $0["spki_sha256"] = String(repeating: "0", count: 64) }, .fingerprintMismatch, "W4 fingerprint from bytes")
        refused(tampered(pending) { $0["kid"] = "AAAAAAAAAAAAAAAAAAAAAA" }, .kidMismatch, "W4 kid from bytes")
        refused(tampered(pending) { $0["sasCommit"] = String(repeating: "a", count: 64) }, .commitMismatch, "W4 commit")
        refused(tampered(pending) { $0["origin"] = ($0["origin"] as! String).replacingOccurrences(of: ":3144", with: ":3143") }, .originInvalid, "W4 origin")
        refused(tampered(pending) { $0["enrollId"] = "AAAAAAAAAAAAAAAAAAAAAA" }, .enrollIdMismatch, "W4 enroll id")
        refused(tampered(pending) { $0["v"] = "cos-web-enroll-approve/1" }, .versionUnknown, "W4 version")
        refused(tampered(pending) { $0["extra"] = "x" }, .approvalKeys, "W4 exact keys")
        refused(tampered(pending) { $0["kver"] = true }, .fieldInvalid, "W4 integers are not booleans")
        refused(tampered(pending) { $0["label"] = "" }, .fieldInvalid, "W4 label")
        refused(tampered(pending) { $0["rotates"] = $0["kid"] }, .fieldInvalid, "W4 rotates")
        refused(pending, .epochMismatch, "W5 epoch", epoch: 1)
        refused(pending, .expired, "card expiry", at: (pending["exp"] as! NSNumber).int64Value + 1)
        let other = P256.Signing.PrivateKey().publicKey.derRepresentation
        refused(pending, .audMismatch, "card aud", anchor: other)
        var spaced = pending
        spaced["approval"] = nil
        spaced["approvalJcs"] = WebKeyB64.encode(Data((String(decoding: WebKeyB64.decode(pending["approvalJcs"] as! String)!, as: UTF8.self)).replacingOccurrences(of: ",\"v\":", with: ", \"v\":").utf8))
        refused(spaced, .approvalNotCanonical, "W4 canonical bytes")
        var bad = pending; bad["approvalJcs"] = "not base64!"; refused(bad, .approvalNotBase64, "W4 canonical bytes")
        if case .success = WebKeyApprovalCheck.card(pending: pending, anchorDER: anchorDER, controlEpoch: nil, nowMs: now) { check(true, "W5 epoch") }
        else { check(false, "W5 epoch", "no Control epoch yet still checks every other field and passes") }
    }

    static func codeAndGate(pending: [String: Any], anchorDER: Data) {
        let now = (pending["startedAt"] as! NSNumber).int64Value + 1000
        guard case .success(let c) = WebKeyApprovalCheck.card(pending: pending, anchorDER: anchorDER, controlEpoch: 0, nowMs: now) else { check(false, "W6 typed code"); return }
        let sas = c.sas
        check(WebKeyCodeEntry.matches(typed: sas, card: c) && WebKeyCodeEntry.matches(typed: "\(sas.prefix(3)) \(sas.suffix(3))", card: c)
              && WebKeyCodeEntry.matches(typed: " \(sas.prefix(3))-\(sas.suffix(3)) ", card: c), "W6 typed code", "the code as the phone shows it")
        let wrong = String(sas.dropLast()) + (sas.last == "9" ? "0" : "9")
        check(!WebKeyCodeEntry.matches(typed: wrong, card: c) && !WebKeyCodeEntry.matches(typed: String(sas.dropLast()), card: c)
              && !WebKeyCodeEntry.matches(typed: "", card: c) && !WebKeyCodeEntry.matches(typed: sas + "1", card: c)
              && !WebKeyCodeEntry.matches(typed: "\u{FF16}\u{FF12}\u{FF15}\u{FF19}\u{FF15}\u{FF15}", card: c), "W6 typed code", "anything else is not the code")
        let at = Date(timeIntervalSince1970: Double(now) / 1000)
        let good = WebKeyListenerAudit(genuine: true, reason: "ok", checkedAt: at)
        check(WebKeyApproveGate.allowed(card: c, typed: sas, audit: good, anchor: true, now: at), "approve gate", "all of it holds")
        check(!WebKeyApproveGate.allowed(card: c, typed: wrong, audit: good, anchor: true, now: at), "W6 approve needs the code", "a wrong code")
        check(!WebKeyApproveGate.allowed(card: c, typed: "", audit: good, anchor: true, now: at), "W6 approve needs the code", "no code")
        check(!WebKeyApproveGate.allowed(card: c, typed: sas, audit: good, anchor: true, now: at.addingTimeInterval(61)), "W9 approve needs a fresh audit", "61 s old")
        check(!WebKeyApproveGate.allowed(card: c, typed: sas, audit: WebKeyListenerAudit(genuine: false, reason: "x", checkedAt: at), anchor: true, now: at), "W9 approve needs a fresh audit", "not genuine")
        check(!WebKeyApproveGate.allowed(card: c, typed: sas, audit: nil, anchor: true, now: at), "W9 approve needs a fresh audit", "never audited")
        check(!WebKeyApproveGate.allowed(card: c, typed: sas, audit: good, anchor: false, now: at), "approve gate", "no anchor")
        check(!WebKeyApproveGate.allowed(card: nil, typed: sas, audit: good, anchor: true, now: at), "approve gate", "no card")
        let late = Date(timeIntervalSince1970: Double(c.expiresAtMs + 1) / 1000)
        check(!WebKeyApproveGate.allowed(card: c, typed: sas, audit: WebKeyListenerAudit(genuine: true, reason: "ok", checkedAt: late), anchor: true, now: late), "approve gate", "expired")
    }

    static func audit() {
        let at = Date(timeIntervalSince1970: 1_786_000_000)
        func ports(_ p: [String: [[String: Any]]]) -> [String: Any] { audited(["servicePID": 4242, "ports": p]) }
        let mine: [[String: Any]] = [["pid": 4243, "underService": true]]
        let ok = ports(["3141": mine, "3143": mine, "3144": mine])
        check(WebKeyListenerAudit.judge(ok, at: at).genuine, "W9 listener audit", "one PID under the LaunchAgent on all three ports")
        check(!WebKeyListenerAudit.judge(ports(["3141": mine, "3143": mine]), at: at).genuine, "W9 listener audit", "nothing on 3144")
        check(!WebKeyListenerAudit.judge(ports(["3141": mine, "3143": mine, "3144": []]), at: at).genuine, "W9 listener audit", "3144 empty")
        check(!WebKeyListenerAudit.judge(ports(["3141": mine, "3143": mine, "3144": mine + [["pid": 999, "underService": false]]]), at: at).genuine,
              "W9 listener audit", "a second listener on 3144, outside the LaunchAgent")
        check(!WebKeyListenerAudit.judge(ports(["3141": mine, "3143": mine, "3144": [["pid": 5000, "underService": true]]]), at: at).genuine,
              "W9 listener audit", "two PIDs, even both under the LaunchAgent")
        check(!WebKeyListenerAudit.judge(ports(["3141": mine, "3143": [["pid": 4243]], "3144": mine]), at: at).genuine, "W9 listener audit", "no underService flag")
        var noService = ok; noService["servicePID"] = 0
        check(!WebKeyListenerAudit.judge(noService, at: at).genuine, "W9 listener audit", "no LaunchAgent PID")
        var missingAssets = ok; missingAssets["assets"] = nil
        check(!WebKeyListenerAudit.judge(missingAssets, at: at).genuine, "immutable asset gate", "listener ownership alone grants nothing")
        var rejectedAssets = ok; rejectedAssets["assets"] = ["verified": false]
        check(!WebKeyListenerAudit.judge(rejectedAssets, at: at).genuine, "immutable asset gate", "an explicit failed asset audit grants nothing")
        let a = WebKeyListenerAudit.judge(ok, at: at)
        check(a.fresh(now: at.addingTimeInterval(59)) && !a.fresh(now: at.addingTimeInterval(61)) && !a.fresh(now: at.addingTimeInterval(-10)),
              "W9 audit freshness", "60 s, and a clock gone backwards is not fresh")
        check(WebKeyListenerAudit.notGenuineLine == "Cannot confirm the signer page is genuine", "W9 audit copy")
        let helper = WebKeyHelperCore.listeners(servicePID: 4242, owners: [3141: [7, 4243], 3143: [4243], 3144: []], underService: { $0 == 4243 })
        let p = helper["ports"] as! [String: Any]
        check((helper["servicePID"] as? Int) == 4242 && Set(p.keys) == ["3141", "3143", "3144"] && ((p["3141"] as! [[String: Any]]).map { $0["pid"] as! Int }) == [7, 4243]
              && ((p["3141"] as! [[String: Any]]).first?["underService"] as? Bool) == false && (p["3144"] as! [Any]).isEmpty, "W9 helper answer", "every PID on every audited port")
        check(!WebKeyListenerAudit.judge(obj(json(viaJSONValue(helper))), at: at).genuine, "W9 listener audit", "the helper's answer for a split owner")
        let whole = WebKeyHelperCore.listeners(servicePID: 4242, owners: [3141: [4243], 3143: [4243], 3144: [4243]], underService: { $0 == 4243 })
        check(WebKeyListenerAudit.judge(obj(json(viaJSONValue(audited(whole)))), at: at).genuine, "W9 listener audit", "the helper's answer for one owner, through the round trip")
    }

    static func stateFile(_ g: [String: Any]) {
        let rev = g["revocation"] as! [String: Any]
        let server = WebKeyServerKeys.parse(["epoch": rev["epoch"]!, "keys": rev["list"]!])
        check(server != nil && server!.revoked.count == 2, "W5 server keys", "two revoked of three")
        guard let server else { return }
        let state = WebKeyControlState(epoch: server.epoch, revoked: server.revoked, anchorSpkiSha256: String(repeating: "a", count: 64), updatedAt: 1)
        let rows: [Any] = state.revoked.map { ["kid": $0.kid, "revokedAt": NSNumber(value: $0.revokedAt)] as [String: Any] }
        check(WebKeyHash.sha256Hex(WebKeyJCS.bytes(rows)!) == rev["digest"] as? String, "W5 revocation digest", "Control's list digests to the server's revocationDigest")
        let fileObject = obj(state.fileData())
        check(Set(fileObject.keys) == ["v", "epoch", "revoked", "anchorSpkiSha256", "updatedAt"] && (fileObject["v"] as? NSNumber)?.intValue == 1,
              "W5 state file", "the verifier's CONTROL_STATE_KEYS")
        check(WebKeyControlState.parse(state.fileData()) == state, "W5 state file", "round trip")
        let kids = state.revoked.map(\.kid)
        check(kids == kids.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }, "W5 state file", "sorted by kid")
        func parses(_ text: String) -> Bool { WebKeyControlState.parse(Data(text.utf8)) != nil }
        let sha = String(repeating: "b", count: 64)
        check(parses(#"{"v":1,"epoch":2,"revoked":[{"kid":"abc","revokedAt":5}],"anchorSpkiSha256":"\#(sha)","updatedAt":9}"#), "W5 state file", "a valid file")
        check(!parses(#"{"v":1,"epoch":true,"revoked":[],"anchorSpkiSha256":"\#(sha)","updatedAt":9}"#)
              && !parses(#"{"v":1,"epoch":1.5,"revoked":[],"anchorSpkiSha256":"\#(sha)","updatedAt":9}"#)
              && !parses(#"{"v":1,"epoch":-1,"revoked":[],"anchorSpkiSha256":"\#(sha)","updatedAt":9}"#)
              && !parses(#"{"v":2,"epoch":1,"revoked":[],"anchorSpkiSha256":"\#(sha)","updatedAt":9}"#)
              && !parses(#"{"v":1,"epoch":1,"revoked":[],"anchorSpkiSha256":"\#(sha)","updatedAt":9,"x":1}"#)
              && !parses(#"{"v":1,"epoch":1,"revoked":[{"kid":"a","revokedAt":1},{"kid":"a","revokedAt":2}],"anchorSpkiSha256":"\#(sha)","updatedAt":9}"#)
              && !parses(#"{"v":1,"epoch":1,"revoked":[{"kid":"a b","revokedAt":1}],"anchorSpkiSha256":"\#(sha)","updatedAt":9}"#)
              && !parses(#"{"v":1,"epoch":1,"revoked":[],"anchorSpkiSha256":"XYZ","updatedAt":9}"#), "W5 state file", "strict as the verifier")
    }

    static func store() {
        let sha = String(repeating: "c", count: 64)
        let s1 = WebKeyControlState(epoch: 3, revoked: [WebKeyRevocation(kid: "k2", revokedAt: 20), WebKeyRevocation(kid: "k1", revokedAt: 10)], anchorSpkiSha256: sha, updatedAt: 100)
        let mem = MemoryStore()
        let dir = scratchDir("store")
        let st = WebKeyStateStore(directory: dir, secure: mem)
        check(st.load() == .none, "W5 store", "nothing yet")
        check(st.save(s1), "W5 store", "saved")
        check(mem.items[WebKeyStateStore.mirrorAccount] == s1.fileData() && FileManager.default.contents(atPath: st.fileURL.path) == s1.fileData(), "W5 store", "keychain and file hold the same bytes")
        check(st.load() == .ok(s1), "W5 store", "loads clean")
        // A rolled-back file: an older epoch.
        let older = WebKeyControlState(epoch: 2, revoked: s1.revoked, anchorSpkiSha256: sha, updatedAt: 90)
        try? older.fileData().write(to: st.fileURL)
        check(st.load() == .repaired(s1, rewrote: true), "W5 rollback caught", "older epoch")
        check(FileManager.default.contents(atPath: st.fileURL.path) == s1.fileData(), "W5 rewritten from keychain", "older epoch")
        // A revocation removed from the file.
        let dropped = WebKeyControlState(epoch: 3, revoked: [WebKeyRevocation(kid: "k1", revokedAt: 10)], anchorSpkiSha256: sha, updatedAt: 100)
        try? dropped.fileData().write(to: st.fileURL)
        check(st.load() == .repaired(s1, rewrote: true) && FileManager.default.contents(atPath: st.fileURL.path) == s1.fileData(), "W5 rollback caught", "a revocation removed")
        // Another anchor in the file.
        let swapped = WebKeyControlState(epoch: 3, revoked: s1.revoked, anchorSpkiSha256: String(repeating: "d", count: 64), updatedAt: 100)
        try? swapped.fileData().write(to: st.fileURL)
        check(st.load() == .repaired(s1, rewrote: true), "W5 rollback caught", "another anchor")
        // Deleted, garbage, a symlink.
        try? FileManager.default.removeItem(at: st.fileURL)
        check(st.load() == .repaired(s1, rewrote: true) && FileManager.default.contents(atPath: st.fileURL.path) == s1.fileData(), "W5 rewritten from keychain", "deleted")
        try? Data("garbage".utf8).write(to: st.fileURL)
        check(st.load() == .repaired(s1, rewrote: true), "W5 rewritten from keychain", "garbage")
        let elsewhere = dir.appendingPathComponent("elsewhere.json")
        try? older.fileData().write(to: elsewhere)
        try? FileManager.default.removeItem(at: st.fileURL)
        try? FileManager.default.createSymbolicLink(at: st.fileURL, withDestinationURL: elsewhere)
        let symlinkLoad = st.load()
        let isLink = ((try? FileManager.default.attributesOfItem(atPath: st.fileURL.path))?[.type] as? FileAttributeType) == .typeSymbolicLink
        check(symlinkLoad == .repaired(s1, rewrote: true) && !isLink && FileManager.default.contents(atPath: elsewhere.path) == older.fileData(),
              "W5 rewritten from keychain", "a symlink is replaced by a file, its target untouched")
        // The keychain cannot be read: nothing trusted, nothing written.
        try? older.fileData().write(to: st.fileURL)
        mem.failRead = true
        check(st.load() == .mirrorUnavailable && FileManager.default.contents(atPath: st.fileURL.path) == older.fileData(), "W5 keychain unreadable", "nothing trusted or written")
        mem.failRead = false
        // A file with no keychain record is not trusted on its own.
        let lone = MemoryStore()
        check(WebKeyStateStore(directory: dir, secure: lone).load() == .mirrorMissing(older), "W5 keychain missing", "a lone file is reported, not loaded")
        // A keychain write that fails writes no file.
        let failing = MemoryStore(); failing.failWrite = true
        let dir2 = scratchDir("store2")
        check(!WebKeyStateStore(directory: dir2, secure: failing).save(s1) && !FileManager.default.fileExists(atPath: dir2.appendingPathComponent(WebKeyStateStore.fileName).path),
              "W5 keychain first", "no file without the keychain record")
        let blockedDir = dir.appendingPathComponent("blocked")
        try? Data("not a directory".utf8).write(to: blockedDir)
        let blockedStore = WebKeyStateStore(directory: blockedDir, secure: mem)
        check(!blockedStore.save(s1), "protected file failure", "a failed file write is reported even after the mirror saved")
        let linkDir = dir.appendingPathComponent("link")
        try? FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: dir2)
        check(!WebKeyStateStore(directory: linkDir, secure: mem).save(s1), "protected directory symlink", "a symlinked state directory is refused")
        let permissions = (try? FileManager.default.attributesOfItem(atPath: st.fileURL.path))?[.posixPermissions] as? NSNumber
        check(permissions?.intValue == 0o600, "protected state permissions", "only the current user can read the state file")
        try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: dir2)
    }

    static func reconcile() {
        let sha = String(repeating: "e", count: 64)
        let kid1 = "AAAAAAAAAAAAAAAAAAAAA1", kid2 = "AAAAAAAAAAAAAAAAAAAAA2"
        func server(_ epoch: Int64, _ revoked: [(String, Int64)], active: [String] = []) -> WebKeyServerKeys {
            WebKeyServerKeys(epoch: epoch, rows: revoked.map { WebKeyKeyRow(kid: $0.0, label: "p", fingerprint: "f", active: false, state: "key_revoked", revokedAt: $0.1) }
                             + active.map { WebKeyKeyRow(kid: $0, label: "p", fingerprint: "f", active: true, state: "active", revokedAt: nil) })
        }
        if case .adopt(let s) = WebKeyReconcile.plan(control: nil, server: server(2, [(kid1, 5)]), anchorSpkiSha256: sha, nowMs: 9) {
            check(s.epoch == 2 && s.revoked == [WebKeyRevocation(kid: kid1, revokedAt: 5)] && s.anchorSpkiSha256 == sha, "W5 reconcile", "first record is the server's")
        } else { check(false, "W5 reconcile", "first record") }
        let control = WebKeyControlState(epoch: 2, revoked: [WebKeyRevocation(kid: kid1, revokedAt: 4)], anchorSpkiSha256: sha, updatedAt: 1)
        if case .adopt(let s) = WebKeyReconcile.plan(control: control, server: server(3, [(kid1, 5), (kid2, 6)]), anchorSpkiSha256: sha, nowMs: 9) {
            check(s.epoch == 3 && s.revoked.count == 2 && s.revoked.first?.revokedAt == 5, "W5 reconcile", "more revocations and a higher epoch are taken, with the server's times")
        } else { check(false, "W5 reconcile", "adopt") }
        check(WebKeyReconcile.plan(control: control, server: server(2, []), anchorSpkiSha256: sha, nowMs: 9) == .repair(missing: [kid1], epochAtLeast: 2),
              "W5 server rollback", "a revocation missing on the server")
        check(WebKeyReconcile.plan(control: control, server: server(1, [(kid1, 4)]), anchorSpkiSha256: sha, nowMs: 9) == .repair(missing: [], epochAtLeast: 2),
              "W5 server rollback", "a lower epoch on the server")
        check(WebKeyReconcile.afterRepair(control: control, server: server(2, [(kid1, 7)]), unknown: [], anchorSpkiSha256: sha, nowMs: 9)?.revoked.first?.revokedAt == 7,
              "W5 repair", "revoked again: take the server's time")
        check(WebKeyReconcile.afterRepair(control: control, server: server(2, []), unknown: [kid1], anchorSpkiSha256: sha, nowMs: 9) == nil,
              "W5 repair", "a removed entry is not dropped at the same epoch")
        check(WebKeyReconcile.afterRepair(control: control, server: server(3, []), unknown: [kid1], anchorSpkiSha256: sha, nowMs: 9)?.epoch == 3,
              "W5 repair", "a removed entry is dropped once the epoch moved past Control's")
        check(WebKeyReconcile.afterRepair(control: control, server: server(3, []), unknown: [], anchorSpkiSha256: sha, nowMs: 9) == nil,
              "W5 repair", "a known key still missing is never dropped")
        check(WebKeyReconcile.afterRepair(control: control, server: server(1, [(kid1, 4)]), unknown: [], anchorSpkiSha256: sha, nowMs: 9) == nil,
              "W5 repair", "an epoch still behind is not taken")
    }

    static func helperCore() {
        func body(_ op: String, _ text: String) -> String? { WebKeyHelperCore.body(op: op, stdin: Data(text.utf8)) }
        check(body("approve", #"{"enrollId":"abc_-1","anchorSig":"Zm9v"}"#) == #"{"anchorSig":"Zm9v","enrollId":"abc_-1"}"#, "helper body", "approve")
        check(body("approve", #"{"enrollId":"abc","anchorSig":"Zm9v","extra":"x"}"#) == nil && body("approve", #"{"enrollId":"abc"}"#) == nil
              && body("approve", #"{"enrollId":"abc","anchorSig":7}"#) == nil && body("approve", #"{"enrollId":"a b","anchorSig":"x"}"#) == nil
              && body("approve", #"{"enrollId":"","anchorSig":"x"}"#) == nil && body("approve", "[]") == nil
              && body("approve", #"{"enrollId":"\#(String(repeating: "a", count: 4100))","anchorSig":"x"}"#) == nil, "helper body", "exact shape only")
        check(body("revoke", #"{"kid":"abc","reason":"revoked_in_control"}"#) != nil && body("revoke", #"{"kid":"abc","reason":"Lost Phone"}"#) == nil, "helper body", "revoke reason")
        check(body("revoke-all", "{}") == "{}" && body("revoke-all", "") == "{}" && body("revoke-all", #"{"epoch":"1"}"#) == nil, "helper body", "revoke-all takes nothing")
        check(body("status", "{}") == nil && body("nope", "{}") == nil, "helper body", "reads take no body")
        check(WebKeyHelperCore.ops == ["status", "pending", "keys", "anchor", "approve", "revoke", "revoke-all", "listeners", "anchor-listeners"], "helper ops")
        check(WebKeyHelperCore.calls["anchor"] == .init(method: "POST", path: "/api/web-key/anchor", bodyKeys: ["anchorPub", "statement", "signature"])
              && WebKeyHelperCore.calls["pending"]?.path == "/api/web-key/enroll/pending" && WebKeyHelperCore.calls["approve"]?.path == "/api/web-key/enroll/approve",
              "helper ops", "the server's routes")
        let a = WebKeyHelperCore.answer(status: 404, body: nil)
        check(a["transport"] as? String == "answered" && a["httpStatus"] as? Int == 404, "helper answer")
    }

    static func assets() {
        let control = String(repeating: "a", count: 64), signer = String(repeating: "b", count: 64)
        let row: [String: Any] = ["webControlManifestSha256": control, "webSignerManifestSha256": signer]
        let good = json(["v": 1, "releases": ["7.0.0": row]])
        let pins = WebKeyAssetsCore.Pins(webControlManifestSha256: control, webSignerManifestSha256: signer)
        check(WebKeyAssetsCore.pins(good, version: "7.0.0") == pins, "immutable release pins", "exact matched version and both SHA values")
        check(WebKeyAssetsCore.pins(good, version: "7.0.1") == nil && WebKeyAssetsCore.pins(json(["v": 1, "releases": [:]]), version: "7.0.0") == nil,
              "immutable release pins", "missing or unsupported release never learns trust")
        check(WebKeyAssetsCore.pins(json(["v": true, "releases": ["7.0.0": row]]), version: "7.0.0") == nil,
              "immutable release pins", "a boolean is not the schema version")
        var extra = row; extra["other"] = signer
        check(WebKeyAssetsCore.pins(json(["v": 1, "releases": ["7.0.0": extra]]), version: "7.0.0") == nil,
              "immutable release pins", "unexpected pin keys are refused")
        var files = Dictionary(uniqueKeysWithValues: WebKeyAssetsCore.signerPaths.map { ($0, control) })
        let manifest = json(["v": 1, "algorithm": "sha256", "files": files])
        check(WebKeyAssetsCore.manifest(manifest, sha: WebKeyAssetsCore.hash(manifest), signer: true) == files,
              "immutable manifest", "all and only the five signer paths")
        check(WebKeyAssetsCore.manifest(manifest, sha: signer, signer: true) == nil, "immutable manifest", "changing bytes cannot borrow the signed pin")
        files["/extra.js"] = control
        let unexpected = json(["v": 1, "algorithm": "sha256", "files": files])
        check(WebKeyAssetsCore.manifest(unexpected, sha: WebKeyAssetsCore.hash(unexpected), signer: true) == nil,
              "immutable signer allowlist", "a pinned manifest still cannot widen signer routes")
        for path in ["../app.js", "/../app.js", "/.hidden", "//host/a", "/a//b", "/a/./b", "/a/../b", "/a%2fb", "/a?b", "/a#b", "/a\\b"] {
            check(!WebKeyAssetsCore.safePath(path), "immutable manifest paths", "no parent, hidden, encoded, empty or URL components")
        }
        let bytes = Data("synthetic signer".utf8), hash = WebKeyAssetsCore.hash(Data("synthetic signer".utf8))
        check(WebKeyAssetsCore.verified(bytes, sha: hash) && !WebKeyAssetsCore.verified(bytes + Data("changed".utf8), sha: hash),
              "served asset hashes", "served bytes must be exact")
        let status: [String: Any] = ["enabled": true, "integrity": ["enabled": true, "ok": true, "manifestSha256": control,
            "signer": ["enabled": true, "ok": true, "manifestSha256": signer]]]
        check(WebKeyAssetsCore.statusMatches(status, pins: pins), "reported immutable hashes", "both trees match signed Control pins")
        var disabled = status; disabled["enabled"] = false
        check(!WebKeyAssetsCore.statusMatches(disabled, pins: pins) && !WebKeyAssetsCore.statusMatches(["enabled": true], pins: pins),
              "reported immutable hashes", "disabled or missing integrity grants nothing")
        check(!WebKeyAssetsCore.statusMatches(status, pins: .init(webControlManifestSha256: signer, webSignerManifestSha256: control)),
              "reported immutable hashes", "HTTP cannot replace the pinned expected values")
        let dir = scratchDir("bundle")
        let executable = dir.appendingPathComponent("Control.app/Contents/Resources/cos-control-helper")
        try? FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        check(WebKeyAssetsCore.bundleResource(executable: executable)?.resource.lastPathComponent == "web-key-assets.json",
              "own bundle resource", "resource stays beside the actual helper")
        check(WebKeyAssetsCore.bundleResource(executable: dir.appendingPathComponent("cos-control-helper")) == nil,
              "own bundle resource", "a standalone or copied helper supplies no authority")
        let resource = executable.deletingLastPathComponent().appendingPathComponent("web-key-assets.json")
        let elsewhere = dir.appendingPathComponent("elsewhere")
        try? good.write(to: elsewhere)
        try? FileManager.default.createSymbolicLink(at: resource, withDestinationURL: elsewhere)
        check(WebKeyAssetsCore.bundleResource(executable: executable) == nil, "own bundle resource", "a resource symlink cannot escape the sealed bundle")
        try? FileManager.default.removeItem(at: dir)
    }

    /// Option A (lead 2026-11-11 21:31): the phone approvals switch, Settings PK-02. The helper's rules (PhoneApprovalsCore,
    /// HelperSources/PairingCore.swift) and the app's (PhoneApprovalsSwitch, Sources/WebKeyCore.swift).
    static func phoneApprovalsSwitch() {
        let phone = "100.101.102.103"
        // The helper's arguments: on with a tailnet IPv4, or off, and nothing else.
        check(PhoneApprovalsCore.change(["on", phone]) == .on(device: phone) && PhoneApprovalsCore.change(["off"]) == .off,
              "phone switch args", "on with this phone's tailnet address, or off")
        for bad in [["on"], ["on", "192.168.1.20"], ["on", "100.128.0.1"], ["on", "100.64.0.1,100.64.0.2"], ["on", phone, "x"], ["off", phone], ["yes"], []] {
            check(PhoneApprovalsCore.change(bad) == nil, "phone switch args", "refused: \(bad)")
        }
        // Off WRITES COS_WEB_KEY_AUTHORITY=0 (a removed key would let a .env line turn it back on); on sets both keys.
        let on = PhoneApprovalsCore.environment(.on(device: phone)), off = PhoneApprovalsCore.environment(.off)
        check(on.set == ["COS_WEB_KEY_AUTHORITY": "1", "COS_WEB_KEY_DEVICES": phone] && on.remove.isEmpty, "phone switch on", "on sets the flag and the one phone")
        check(off.set == ["COS_WEB_KEY_AUTHORITY": "0"] && off.remove == ["COS_WEB_KEY_DEVICES"] && !off.remove.contains("COS_WEB_KEY_AUTHORITY"),
              "phone switch off writes 0", "off writes the flag as 0 and removes only the phone list")
        check(PhoneApprovalsCore.change(fromEnvironment: on.set) == .on(device: phone) && PhoneApprovalsCore.change(fromEnvironment: off.set) == .off
              && PhoneApprovalsCore.change(fromEnvironment: ["COS_VIDEO_UPLOAD_V2": "1"]) == nil, "phone switch proof",
              "both apply paths prove a phone approvals write, and only that")
        // The restarted server's own status proves the change. PA-C: on also needs the SR-15 fix and a tailnet-only bind.
        let fixedBind: [String: Any] = ["signerBindFixVersion": 1, "signerBind": ["scope": "tailnet", "addresses": ["100.64.0.10"], "reason": NSNull(), "listening": true]]
        var proofOn: [String: Any] = ["enabled": true]
        proofOn.merge(fixedBind) { a, _ in a }
        var proofAuthority = proofOn
        proofAuthority["mode"] = "authority"
        check(PhoneApprovalsCore.proven(.on(device: phone), status: 200, body: viaJSONValue(proofOn) as? [String: Any])
              && PhoneApprovalsCore.proven(.on(device: phone), status: 200, body: viaJSONValue(proofAuthority) as? [String: Any]),
              "phone switch proof", "on: 200, enabled and the tailnet-only bind")
        check(!PhoneApprovalsCore.proven(.on(device: phone), status: 200, body: ["enabled": true])
              && !PhoneApprovalsCore.proven(.on(device: phone), status: 200, body: viaJSONValue(["enabled": true, "signerBindFixVersion": 1,
                                                                                                  "signerBind": ["scope": "none", "addresses": [Any](), "reason": "no_tailnet_address"]]) as? [String: Any])
              && !PhoneApprovalsCore.proven(.on(device: phone), status: 200, body: viaJSONValue(["enabled": true, "signerBindFixVersion": true,
                                                                                                  "signerBind": ["scope": "tailnet"]]) as? [String: Any]),
              "phone on proof needs the bind", "a restarted server without the fix, with no tailnet bind, or with a boolean version does not prove on")
        var notListening = proofOn
        notListening["signerBind"] = ["scope": "tailnet", "addresses": ["100.64.0.10"], "reason": NSNull(), "listening": false]
        var listeningMissing = proofOn
        listeningMissing["signerBind"] = ["scope": "tailnet", "addresses": ["100.64.0.10"], "reason": NSNull()]
        check(!PhoneApprovalsCore.proven(.on(device: phone), status: 200, body: viaJSONValue(notListening) as? [String: Any])
              && !PhoneApprovalsCore.proven(.on(device: phone), status: 200, body: viaJSONValue(listeningMissing) as? [String: Any])
              && PhoneApprovalsCore.proofStep(.on(device: phone), status: 200, body: viaJSONValue(notListening) as? [String: Any]) == .fail,
              "phone on proof needs listening", "a tailnet scope proves on only with 3144 actually bound (listening true)")
        var bootstrapFixed = fixedBind
        bootstrapFixed["enabled"] = false; bootstrapFixed["mode"] = "bootstrap"
        var contradictionFixed = fixedBind
        contradictionFixed["enabled"] = true; contradictionFixed["mode"] = "bootstrap"
        check(!PhoneApprovalsCore.proven(.on(device: phone), status: 200, body: viaJSONValue(bootstrapFixed) as? [String: Any])
              && !PhoneApprovalsCore.proven(.on(device: phone), status: 200, body: viaJSONValue(contradictionFixed) as? [String: Any])
              && !PhoneApprovalsCore.proven(.on(device: phone), status: 503, body: viaJSONValue(proofOn) as? [String: Any]),
              "phone switch proof", "a tailnet bind alone never proves on: the server must also be on, in authority mode, with a 200")
        // Review C4: the restarted server must report the same public name the helper checked before the restart.
        let checkedName = "example-mac.tail00000a.ts.net"
        var named = proofOn
        named["certDisclosure"] = ["issued": false, "publicName": checkedName]
        var renamed = proofOn
        renamed["certDisclosure"] = ["issued": false, "publicName": "other-mac.tail00000a.ts.net"]
        var unnamed = proofOn
        unnamed["certDisclosure"] = ["issued": false, "publicName": NSNull()]
        let namedBody = viaJSONValue(named) as? [String: Any], renamedBody = viaJSONValue(renamed) as? [String: Any], unnamedBody = viaJSONValue(unnamed) as? [String: Any]
        check(PhoneApprovalsCore.proven(.on(device: phone), status: 200, body: namedBody, expectedName: checkedName)
              && !PhoneApprovalsCore.proven(.on(device: phone), status: 200, body: renamedBody, expectedName: checkedName)
              && !PhoneApprovalsCore.proven(.on(device: phone), status: 200, body: unnamedBody, expectedName: checkedName)
              && PhoneApprovalsCore.proofStep(.on(device: phone), status: 200, body: renamedBody, expectedName: checkedName) == .fail
              && PhoneApprovalsCore.proofStep(.on(device: phone), status: 200, body: namedBody, expectedName: checkedName) == .proven
              && PhoneApprovalsCore.publicName(namedBody) == checkedName && PhoneApprovalsCore.publicName(unnamedBody) == nil
              && PhoneApprovalsCore.publicName(viaJSONValue(["certDisclosure": ["publicName": "Example-Mac.tail00000a.ts.net"]]) as? [String: Any]) == nil,
              "phone on proof keeps the checked name", "a restarted server with another public name, or none, fails the proof and rolls back")
        // Review C5: a failed rollback of any phone approvals change says approvals may still be on, and how to turn them off.
        check(PhoneApprovalsCore.warnsOnFailedRollback(PhoneApprovalsCore.environment(.on(device: phone)).set)
              && PhoneApprovalsCore.warnsOnFailedRollback(PhoneApprovalsCore.environment(.off).set)
              && !PhoneApprovalsCore.warnsOnFailedRollback(["COS_VIDEO_UPLOAD_V2": "1"])
              && PhoneApprovalsCore.rollbackFailed.contains("may still be on") && PhoneApprovalsCore.rollbackFailed.contains("set-phone-approvals off")
              && PhoneApprovalsCore.rollbackFailed.contains("Remove phones and turn off") && !PhoneApprovalsCore.rollbackFailed.contains("—"),
              "phone rollback failure says so", "only phone approvals changes get the warning; it names the state and both ways off")
        // PA-S's timing note: right after an On restart, "no_tailnet_address" means wait (bounded); other reasons fail at once.
        func bindAnswer(_ reason: String) -> [String: Any]? {
            viaJSONValue(["enabled": true, "mode": "authority", "signerBindFixVersion": 1,
                          "signerBind": ["scope": "none", "addresses": [Any](), "reason": reason, "listening": false]]) as? [String: Any]
        }
        check(PhoneApprovalsCore.proofStep(.on(device: phone), status: 200, body: bindAnswer("no_tailnet_address")) == .wait
              && PhoneApprovalsCore.proofStep(.on(device: phone), status: 200, body: bindAnswer("address_lost")) == .wait
              && PhoneApprovalsCore.proofStep(.on(device: phone), status: 200, body: bindAnswer("listen_failed")) == .wait
              && PhoneApprovalsCore.proofWaitReasons == ["no_tailnet_address", "address_lost", "listen_failed"]
              && PhoneApprovalsCore.proofStep(.on(device: phone), status: 200, body: viaJSONValue(proofOn) as? [String: Any]) == .proven
              && PhoneApprovalsCore.proofStep(.off, status: 404, body: nil) == .proven,
              "phone on proof waits for the tailnet", "a server still waiting for its tailnet address is polled; a proven answer ends it")
        var bootstrapWaiting = bindAnswer("no_tailnet_address") ?? [:]
        bootstrapWaiting["enabled"] = false; bootstrapWaiting["mode"] = "bootstrap"
        var unfixedWaiting = bindAnswer("no_tailnet_address") ?? [:]
        unfixedWaiting["signerBindFixVersion"] = 0
        check(PhoneApprovalsCore.proofStep(.on(device: phone), status: 200, body: bindAnswer("bind_host_not_tailnet")) == .fail
              && PhoneApprovalsCore.proofStep(.on(device: phone), status: 200, body: bindAnswer("made_up_reason")) == .fail
              && PhoneApprovalsCore.proofStep(.on(device: phone), status: 200, body: bindAnswer("https_unavailable")) == .fail
              && PhoneApprovalsCore.proofStep(.on(device: phone), status: 200, body: bootstrapWaiting) == .fail
              && PhoneApprovalsCore.proofStep(.on(device: phone), status: 200, body: unfixedWaiting) == .fail
              && PhoneApprovalsCore.proofStep(.on(device: phone), status: nil, body: nil) == .fail
              && PhoneApprovalsCore.proofStep(.off, status: 200, body: bindAnswer("no_tailnet_address")) == .fail
              && PhoneApprovalsCore.proofWaitSeconds <= 60 && PhoneApprovalsCore.proofPollSeconds >= 1,
              "phone on proof waits for the tailnet", "every other reason, an off or old server, no answer, and Off itself fail at once; the wait is bounded")
        check(!PhoneApprovalsCore.proven(.on(device: phone), status: 200, body: ["enabled": false, "mode": "bootstrap"])
              && !PhoneApprovalsCore.proven(.on(device: phone), status: 404, body: nil)
              && !PhoneApprovalsCore.proven(.on(device: phone), status: nil, body: nil)
              && !PhoneApprovalsCore.proven(.on(device: phone), status: 200, body: ["enabled": true, "mode": "bootstrap"]), "phone switch proof",
              "on is not proven by bootstrap, a 404, no answer, or a contradiction")
        check(PhoneApprovalsCore.proven(.off, status: 404, body: nil) && PhoneApprovalsCore.proven(.off, status: 200, body: ["enabled": false, "mode": "bootstrap"])
              && !PhoneApprovalsCore.proven(.off, status: 200, body: ["enabled": true]), "phone switch proof", "off: anything but an enabled server")
        // The app: only this account's iPhones with a tailnet address, by name.
        let peers: [PhoneApprovalsSwitch.Peer] = [
            .init(os: "iOS", dns: "zed-iphone.tail00000a.ts.net", ipv4: "100.64.0.12", sameUser: true),
            .init(os: "iOS", dns: "amy-iphone.tail00000a.ts.net", ipv4: "100.64.0.11", sameUser: true),
            .init(os: "iOS", dns: "guest-iphone.tail00000a.ts.net", ipv4: "100.64.0.13", sameUser: false),
            .init(os: "macOS", dns: "example-mac.tail00000a.ts.net", ipv4: "100.64.0.10", sameUser: true),
            .init(os: "iOS", dns: "no-v4.tail00000a.ts.net", ipv4: nil, sameUser: true),
            .init(os: "iOS", dns: "odd.tail00000a.ts.net", ipv4: "192.168.1.9", sameUser: true),
        ]
        check(PhoneApprovalsSwitch.phones(peers) == [.init(name: "amy-iphone", ipv4: "100.64.0.11"), .init(name: "zed-iphone", ipv4: "100.64.0.12")],
              "phone switch phones", "this account's iPhones with a tailnet IPv4, by name; never a guest's phone, a Mac or an odd address")
        // Shown only for a server with the reopened phone approvals; the app and the helper agree on that server.
        check(PhoneApprovalsSwitch.minimumServer == PhoneApprovalsCore.minimumServer, "phone switch server floor", "the app and the helper name the same server")
        check(PhoneApprovalsSwitch.serverSupports(PhoneApprovalsSwitch.minimumServer) && PhoneApprovalsSwitch.serverSupports("8.0.0")
              && !PhoneApprovalsSwitch.serverSupports("7.0.28") && !PhoneApprovalsSwitch.serverSupports("7.0.29") && !PhoneApprovalsSwitch.serverSupports(nil)
              && !PhoneApprovalsSwitch.serverSupports("7.0") && !PhoneApprovalsSwitch.serverSupports("7.0.30-rc1"),
              "phone switch server floor", "at or above the floor only; unknown or malformed versions hide the row")
        // On is the server's own answer; bootstrap (registration only) and off read as off.
        check(PhoneApprovalsSwitch.isOn(.authority) && !PhoneApprovalsSwitch.isOn(.bootstrap) && !PhoneApprovalsSwitch.isOn(.off),
              "phone switch on reads the server", "only authority mode is on")
        let amy = PhoneApprovalsSwitch.Phone(name: "amy-iphone", ipv4: "100.64.0.11")
        check(PhoneApprovalsSwitch.arguments(on: true, phone: amy) == ["on", "100.64.0.11"] && PhoneApprovalsSwitch.arguments(on: false, phone: amy) == ["off"]
              && PhoneApprovalsSwitch.arguments(on: true, phone: nil) == nil
              && PhoneApprovalsSwitch.arguments(on: true, phone: .init(name: "x", ipv4: "192.168.1.9")) == nil,
              "phone switch args", "on needs a phone on the tailnet; off takes nothing")
        // The confirmation names the phone; before a first certificate it says plainly that the Mac's name becomes public.
        let message = PhoneApprovalsSwitch.confirmOnMessage(amy, publicName: "example-mac.tail00000a.ts.net")
        let issuedMessage = PhoneApprovalsSwitch.confirmOnMessage(amy, publicName: nil)
        check(PhoneApprovalsSwitch.confirmOnTitle(amy).contains("amy-iphone") && message.contains("amy-iphone")
              && message.contains("example-mac.tail00000a.ts.net") && message.contains("becomes public in certificate logs")
              && message.contains("restarts the server") && issuedMessage.contains("amy-iphone") && issuedMessage.contains("restarts the server")
              && !issuedMessage.contains("certificate"), "phone switch confirm", "the phone, the Mac's name, public certificate logs, the restart")
        // PA-C: the disclosure names the exact name, says public certificate logs and permanently, and that Off does not undo it.
        let name = "example-mac.tail00000a.ts.net"
        let disclosure = [PhoneApprovalsSwitch.disclosureTitle(name), PhoneApprovalsSwitch.disclosureMessage(name), PhoneApprovalsSwitch.disclosureAgree(name)]
        check(disclosure.allSatisfy { $0.contains(name) } && disclosure[1].contains("public certificate logs") && disclosure[1].contains("permanently")
              && disclosure[1].contains("off later does not remove it") && disclosure[1].contains("asks for a certificate")
              && disclosure[2].contains("permanently") && disclosure[1].hasSuffix("This COS server has no certificate stored for this name yet.")
              && !disclosure[1].contains("has not asked"), "phone on disclosure copy", "the exact name, public certificate logs, permanently, and Off does not remove it")
        let copy = [PhoneApprovalsSwitch.confirmOnTitle(amy), message, issuedMessage, PhoneApprovalsSwitch.confirmOffTitle,
                    PhoneApprovalsSwitch.confirmOffMessage, PhoneApprovalsSwitch.label, PhoneApprovalsSwitch.labelOn, PhoneApprovalsSwitch.detail, PhoneApprovalsSwitch.noPhone]
                    + disclosure + [PhoneApprovalsCore.notReady, PhoneApprovalsCore.needsFix, PhoneApprovalsCore.needsTailnetBind,
                                    PhoneApprovalsCore.disclosureMissing, PhoneApprovalsCore.disclosureStale]
        check(copy.allSatisfy { !$0.isEmpty && !$0.contains("—") && !$0.contains("COS_") }, "phone switch confirm", "plain copy: no em dash, no variable names")
        check(PhoneApprovalsSwitch.detail.hasPrefix("Off unless you turn it on."), "phone switch off by default", "the row says it is off by default")
        check(PhoneApprovalsSwitch.title(on: false) == "Turn on phone approvals" && PhoneApprovalsSwitch.title(on: true) == "Phone approvals are on",
              "phone switch title follows the switch", "the title asks only while it is off, and says it is on once it is")
        // Like the nine restart rows: never live while work runs or another change is in progress.
        check(PhoneApprovalsSwitch.applyAllowed(locked: false, workActive: false) && !PhoneApprovalsSwitch.applyAllowed(locked: true, workActive: false)
              && !PhoneApprovalsSwitch.applyAllowed(locked: false, workActive: true) && !PhoneApprovalsSwitch.applyAllowed(locked: true, workActive: true),
              "phone switch waits for work", "an apply is live only with nothing in progress and no running work")
    }

    /// PA-C (2026-11-15): the reviewed return of On. Executes every gate the app and the helper go through, against status
    /// bodies parsed from JSON as the helper hands them over: the server's proof (PhoneApprovalsReadiness), what the app sends
    /// (request, the only argument source of ControllerModel.setPhoneApprovals), what the helper applies (change, then onRefusal
    /// on its own status read), and where Settings mounts the row (shown, mounted). Off keeps working whatever the server says.
    static func phoneApprovalsOnGate() {
        let amy = PhoneApprovalsSwitch.Phone(name: "amy-iphone", ipv4: "100.64.0.11")
        let name = "example-mac.tail00000a.ts.net"
        func body(_ text: String) -> [String: Any] { obj(Data(text.utf8)) }
        func ready(_ text: String) -> PhoneApprovalsReadiness? { PhoneApprovalsReadiness.read(status: 200, body: body(text)) }
        let bind = #""signerBind":{"scope":"tailnet","addresses":["100.64.0.10"],"reason":null,"listening":false}"#
        let firstText = #"{"ok":true,"enabled":false,"mode":"off","signerBindFixVersion":1,\#(bind),"certDisclosure":{"issued":false,"publicName":"\#(name)"}}"#
        let issuedText = #"{"ok":true,"enabled":false,"mode":"off","signerBindFixVersion":1,\#(bind),"certDisclosure":{"issued":true,"publicName":"\#(name)"}}"#
        let issuedNoNameText = #"{"ok":true,"enabled":false,"mode":"off","signerBindFixVersion":1,\#(bind),"certDisclosure":{"issued":true,"publicName":null}}"#
        let first = ready(firstText), issued = ready(issuedText)
        // The server's proof: the fix and a tailnet-only bind.
        check(first?.bindFixed == true && first?.canTurnOn == true && first?.needsDisclosure == true && first?.publicName == name
              && issued?.canTurnOn == true && issued?.needsDisclosure == false, "phone on needs the server fix",
              "a server with the fix and a tailnet-only bind can turn on; a first certificate needs the disclosure")
        let unfixed: [String] = [
            #"{"enabled":false,"mode":"off"}"#,                                                                       // an older server
            #"{"signerBindFixVersion":0,\#(bind),"certDisclosure":{"issued":true,"publicName":"\#(name)"}}"#,                                // below the fix
            #"{"signerBindFixVersion":true,\#(bind),"certDisclosure":{"issued":true,"publicName":"\#(name)"}}"#,                             // a boolean
            #"{"signerBindFixVersion":1.5,\#(bind),"certDisclosure":{"issued":true,"publicName":"\#(name)"}}"#,                              // a fraction
            #"{"signerBindFixVersion":"1",\#(bind),"certDisclosure":{"issued":true,"publicName":"\#(name)"}}"#,                              // a string
            #"{"signerBindFixVersion":1,"signerBind":{"scope":"all","addresses":[]},"certDisclosure":{"issued":true,"publicName":"\#(name)"}}"#,   // every interface
            #"{"signerBindFixVersion":1,"signerBind":{"scope":"none","addresses":[],"reason":"no_tailnet_address"},"certDisclosure":{"issued":true,"publicName":"\#(name)"}}"#,
            #"{"signerBindFixVersion":1,"signerBind":{"scope":"Tailnet"},"certDisclosure":{"issued":true,"publicName":"\#(name)"}}"#,      // not the exact word
            #"{"signerBindFixVersion":1,"certDisclosure":{"issued":true,"publicName":"\#(name)"}}"#,                                       // no bind
        ]
        check(unfixed.allSatisfy { ready($0)?.canTurnOn == false } && unfixed.allSatisfy { !PhoneApprovalsSwitch.canStart(ready($0)) }
              && ready(#"{"signerBindFixVersion":2,\#(bind),"certDisclosure":{"issued":true,"publicName":"\#(name)"}}"#)?.canTurnOn == true
              && PhoneApprovalsReadiness.read(status: 404, body: [:]) == nil && !PhoneApprovalsSwitch.canStart(nil),
              "phone on needs the server fix", "no fix, a malformed version, any bind but tailnet, or no answer cannot turn on")
        // The disclosure: needed unless the server says plainly it already asked; it must name a real ts.net name.
        let noName = [#"{"signerBindFixVersion":1,\#(bind),"certDisclosure":{"issued":false,"publicName":null}}"#,
                      #"{"signerBindFixVersion":1,\#(bind),"certDisclosure":{"issued":false,"publicName":"Example-Mac.tail00000a.ts.net"}}"#,
                      #"{"signerBindFixVersion":1,\#(bind),"certDisclosure":{"issued":false,"publicName":"example-mac.ts.net"}}"#,
                      #"{"signerBindFixVersion":1,\#(bind),"certDisclosure":{"issued":false,"publicName":"example mac.tail00000a.ts.net"}}"#,
                      #"{"signerBindFixVersion":1,\#(bind),"certDisclosure":{"issued":false,"publicName":"example-mac.evil.example.com"}}"#,
                      #"{"signerBindFixVersion":1,\#(bind),"certDisclosure":{"issued":"true","publicName":null}}"#,
                      #"{"signerBindFixVersion":1,\#(bind)}"#]
        check(noName.allSatisfy { ready($0)?.canTurnOn == false && ready($0)?.needsDisclosure == true }, "phone on disclosure",
              "before a first certificate, on is offered only when the exact public name is known and well formed")
        // The lead (2026-11-15): a null public name refuses On in every case, even when a certificate was already asked for.
        check(ready(issuedNoNameText)?.canTurnOn == false
              && PhoneApprovalsSwitch.request(on: true, phone: amy, readiness: ready(issuedNoNameText), disclosedName: nil) == nil
              && PhoneApprovalsCore.onRefusal(status: 200, body: body(issuedNoNameText), disclosedName: nil) == PhoneApprovalsCore.nameUnknown
              && PhoneApprovalsCore.onRefusal(status: 200, body: body(issuedNoNameText), disclosedName: name) == PhoneApprovalsCore.nameUnknown,
              "phone on needs the public name", "no public name, no On: the app does not offer it and the helper refuses it")
        check(first?.disclosed(nil) == false && first?.disclosed("other-mac.tail00000a.ts.net") == false && first?.disclosed(name) == true
              && issued?.disclosed(nil) == true, "phone on disclosure", "agreed only for the server's exact name, or not needed at all")
        // What the app sends.
        check(PhoneApprovalsSwitch.request(on: true, phone: amy, readiness: first, disclosedName: nil) == nil
              && PhoneApprovalsSwitch.request(on: true, phone: amy, readiness: first, disclosedName: "other-mac.tail00000a.ts.net") == nil
              && PhoneApprovalsSwitch.request(on: true, phone: amy, readiness: first, disclosedName: name) == ["on", amy.ipv4, "--disclosed-name", name]
              && PhoneApprovalsSwitch.request(on: true, phone: amy, readiness: issued, disclosedName: nil) == ["on", amy.ipv4]
              && PhoneApprovalsSwitch.request(on: true, phone: nil, readiness: issued, disclosedName: nil) == nil,
              "phone on disclosure", "on carries the agreed name before a first certificate, and is not sent without it")
        check(unfixed.allSatisfy { PhoneApprovalsSwitch.request(on: true, phone: amy, readiness: ready($0), disclosedName: name) == nil }
              && PhoneApprovalsSwitch.request(on: true, phone: amy, readiness: nil, disclosedName: name) == nil,
              "phone on needs the server fix", "the app never sends on without the server's proof")
        // What the helper applies, from its own read of the same status.
        check(PhoneApprovalsCore.onRefusal(status: 200, body: body(firstText), disclosedName: name) == nil
              && PhoneApprovalsCore.onRefusal(status: 200, body: body(issuedText), disclosedName: nil) == nil
              && PhoneApprovalsCore.onRefusal(status: 200, body: body(firstText), disclosedName: nil) == PhoneApprovalsCore.disclosureMissing
              && PhoneApprovalsCore.onRefusal(status: 200, body: body(firstText), disclosedName: "other-mac.tail00000a.ts.net") == PhoneApprovalsCore.disclosureStale
              && PhoneApprovalsCore.onRefusal(status: 200, body: body(issuedText), disclosedName: name) == PhoneApprovalsCore.disclosureStale,
              "phone on helper gate", "the helper refuses on before a first certificate without the disclosure for the exact name")
        check(PhoneApprovalsCore.onRefusal(status: 404, body: [:], disclosedName: name) == PhoneApprovalsCore.needsFix
              && PhoneApprovalsCore.onRefusal(status: nil, body: nil, disclosedName: name) == PhoneApprovalsCore.notReady
              && PhoneApprovalsCore.onRefusal(status: 401, body: [:], disclosedName: name) == PhoneApprovalsCore.notReady
              && unfixed.prefix(5).allSatisfy { PhoneApprovalsCore.onRefusal(status: 200, body: body($0), disclosedName: nil) == PhoneApprovalsCore.needsFix }
              && unfixed.suffix(4).allSatisfy { PhoneApprovalsCore.onRefusal(status: 200, body: body($0), disclosedName: nil) == PhoneApprovalsCore.needsTailnetBind },
              "phone on helper gate", "the helper refuses on for no answer, an old server, a malformed version, or any bind but tailnet")
        // The helper's arguments with the disclosure.
        check(PhoneApprovalsCore.change(["on", amy.ipv4, "--disclosed-name", name]) == .on(device: amy.ipv4)
              && PhoneApprovalsCore.disclosedName(["on", amy.ipv4, "--disclosed-name", name]) == name
              && PhoneApprovalsCore.disclosedName(["on", amy.ipv4]) == nil
              && PhoneApprovalsCore.change(["on", amy.ipv4, "--disclosed-name", "Example.tail00000a.ts.net"]) == nil
              && PhoneApprovalsCore.change(["on", amy.ipv4, "--other", name]) == nil
              && PhoneApprovalsCore.change(["on", "192.168.1.9", "--disclosed-name", name]) == nil
              && PhoneApprovalsCore.change(["off", "--disclosed-name", name]) == nil
              && PhoneApprovalsCore.disclosedName(["on", "192.168.1.9", "--disclosed-name", name]) == nil,
              "phone switch args", "on may carry one well-formed disclosed name and nothing else")
        // The app and the helper agree: the same constants, the same names, and the app sends on exactly when the helper takes it.
        let names = [name, "a.b.ts.net", "Example.tail00000a.ts.net", "example.ts.net", "x..ts.net", "-x.tail00000a.ts.net", "x.tail00000a.ts.net.", "", "evil.com", "example-mac.evil.example.com"]
        check(PhoneApprovalsReadiness.requiredFixVersion == PhoneApprovalsCore.requiredFixVersion && PhoneApprovalsReadiness.tailnetScope == PhoneApprovalsCore.tailnetScope
              && PhoneApprovalsSwitch.disclosedFlag == PhoneApprovalsCore.disclosedFlag
              && names.allSatisfy { PhoneApprovalsReadiness.validName($0) == PhoneApprovalsCore.validName($0) }
              && PhoneApprovalsReadiness.validName(name) == name && PhoneApprovalsReadiness.validName("Example.tail00000a.ts.net") == nil,
              "phone on app and helper agree", "one fix version, one scope word, one flag, one name rule")
        var agree = true
        for text in [firstText, issuedText, issuedNoNameText] + unfixed + noName {
            for agreed in [nil, name, "other-mac.tail00000a.ts.net"] as [String?] {
                let sent = PhoneApprovalsSwitch.request(on: true, phone: amy, readiness: ready(text), disclosedName: agreed)
                let taken = sent.map { args in PhoneApprovalsCore.change(args) != nil && PhoneApprovalsCore.onRefusal(status: 200, body: body(text), disclosedName: PhoneApprovalsCore.disclosedName(args)) == nil }
                if sent != nil && taken != true { agree = false }
            }
        }
        check(agree, "phone on app and helper agree", "whatever the app sends for on, the helper takes against the same status")
        // Where Settings mounts the row.
        let versions: [String?] = [PhoneApprovalsSwitch.minimumServer, "7.0.31", "8.0.0"]
        check(versions.allSatisfy { PhoneApprovalsSwitch.mounted(serverVersion: $0, rowDrawn: true, on: false, pendingOff: false, readiness: first) }
              && versions.allSatisfy { !PhoneApprovalsSwitch.mounted(serverVersion: $0, rowDrawn: false, on: false, pendingOff: false, readiness: first) }
              && !PhoneApprovalsSwitch.mounted(serverVersion: "7.0.29", rowDrawn: true, on: false, pendingOff: false, readiness: first)
              && !PhoneApprovalsSwitch.mounted(serverVersion: nil, rowDrawn: true, on: false, pendingOff: false, readiness: first)
              && unfixed.allSatisfy { t in versions.allSatisfy { !PhoneApprovalsSwitch.mounted(serverVersion: $0, rowDrawn: true, on: false, pendingOff: false, readiness: ready(t)) } }
              && !PhoneApprovalsSwitch.mounted(serverVersion: "8.0.0", rowDrawn: true, on: false, pendingOff: false, readiness: nil)
              && PhoneApprovalsSwitch.shown(serverVersion: "7.0.31", readiness: first) && !PhoneApprovalsSwitch.shown(serverVersion: "7.0.31", readiness: nil),
              "phone on needs the server fix", "the turn-on row mounts in All only, for a server at the floor that proves the fix")
        check(PhoneApprovalsSwitch.anchorID(on: false, pendingOff: false) == "PK-02" && PhoneApprovalsSwitch.anchorID(on: true, pendingOff: false) == "PK-02-off"
              && PhoneApprovalsSwitch.anchorID(on: false, pendingOff: true) == "PK-02-off",
              "phone switch full settings only", "the turn-on row takes PK-02 (All only); the Off row an id Basic never hides")
        // A Mac whose server already reports it on (or whose Off still waits) keeps the Off row, in every view, whatever the
        // server says about its bind, and Off goes through.
        check(PhoneApprovalsSwitch.mounted(serverVersion: "7.0.31", rowDrawn: false, on: true, pendingOff: false, readiness: nil)
              && PhoneApprovalsSwitch.mounted(serverVersion: "7.0.31", rowDrawn: true, on: true, pendingOff: false, readiness: ready(unfixed[6]))
              && PhoneApprovalsSwitch.mounted(serverVersion: "7.0.31", rowDrawn: false, on: false, pendingOff: true, readiness: nil)
              && !PhoneApprovalsSwitch.mounted(serverVersion: "7.0.29", rowDrawn: true, on: true, pendingOff: true, readiness: nil),
              "phone switch off stays reachable", "a Mac already on keeps the Off row in Basic and All, and so does a waiting Off")
        check(PhoneApprovalsSwitch.request(on: false, phone: nil, readiness: nil, disclosedName: nil) == ["off"]
              && PhoneApprovalsSwitch.request(on: false, phone: amy, readiness: ready(unfixed[0]), disclosedName: name) == ["off"]
              && PhoneApprovalsCore.change(["off"]) == .off
              && PhoneApprovalsCore.environment(.off).set == ["COS_WEB_KEY_AUTHORITY": "0"],
              "phone switch off stays reachable", "Off is sent and applied whatever the server says, and writes the flag as 0")
    }

    /// PA-C: Control reads the readiness from every status answer, the off mode's included (servers with the fix answer it to
    /// the token; no origin, so the Phone approvals block stays hidden), and forgets it when the server stops answering.
    @MainActor
    static func phoneApprovalsReadinessFlow() async {
        let fake = FakeServer()
        let state = WebKeyState()
        state.runHelper = { args, body in await fake.run(args, body) }
        state.secure = MemoryStore(); state.stateDirectory = scratchDir("readiness")
        let name = "example-mac.tail00000a.ts.net"
        fake.answers["status"] = (200, ["ok": true, "enabled": false, "mode": "off", "signerBindFixVersion": 1,
                                        "signerBind": ["scope": "tailnet", "addresses": ["100.64.0.10"], "reason": NSNull(), "listening": false],
                                        "certDisclosure": ["issued": false, "publicName": name]])
        await state.refresh()
        check(!state.visible && state.mode == .off && state.onReadiness?.canTurnOn == true && state.onReadiness?.publicName == name
              && fake.calls.map(\.op) == ["status"], "phone on readiness read", "an off server with the fix: block hidden, readiness kept, nothing else asked")
        fake.answers["status"] = (404, ["ok": false])
        await state.refresh()
        check(!state.visible && state.onReadiness == nil, "phone on readiness read", "an older server (404) leaves no readiness")
        fake.answers["status"] = (200, ["ok": true, "enabled": false, "mode": "off", "signerBindFixVersion": 1,
                                        "signerBind": ["scope": "none", "addresses": [Any](), "reason": "no_tailnet_address", "listening": false],
                                        "certDisclosure": ["issued": true, "publicName": NSNull()]])
        await state.refresh()
        check(state.onReadiness != nil && state.onReadiness?.canTurnOn == false, "phone on readiness read", "a server with no tailnet bind reads as not ready")
        fake.answers["status"] = nil
        await state.refresh()
        check(state.onReadiness == nil, "phone on readiness read", "no answer forgets the readiness")
    }

    /// Option A (lead ruling 2026-11-12 10:32): Off revokes every phone at once, whatever work runs; only its =0 restart waits.
    @MainActor
    static func phoneApprovalsOff() async {
        final class Mem: PhoneApprovalsPendingStore {
            var value: PhoneApprovalsPendingOff?
            func load() -> PhoneApprovalsPendingOff? { value }
            func save(_ pending: PhoneApprovalsPendingOff) { value = pending }
            func clear() { value = nil }
        }
        // With a meeting running: the revoke runs now, the =0 restart does not, and the wait is saved.
        let mem = Mem()
        var revokes = 0, applies = 0
        var savedBeforeRevoke = false
        let busy = await PhoneApprovalsOff.run(store: mem, now: 7, revokeAll: { savedBeforeRevoke = mem.load() != nil; revokes += 1; return true },
                                               locked: { false }, workActive: { true }, apply: { applies += 1 })
        check(revokes == 1 && busy.revokedAll, "phone off revokes at once", "Off's Revoke all runs while work runs")
        check(applies == 0 && mem.load() == PhoneApprovalsPendingOff(revokedAll: true, savedAt: 7),
              "phone off restart waits", "the =0 restart waits for running work, and the wait is saved")
        check(savedBeforeRevoke, "phone off saved first", "the wait is saved before the revoke, so a quit during it keeps the =0")
        // The work ends: the saved =0 applies; another change in progress still waits.
        check(!PhoneApprovalsOff.resume(store: mem, locked: true, workActive: false, apply: { applies += 1 }) && applies == 0
              && PhoneApprovalsOff.resume(store: mem, locked: false, workActive: false, apply: { applies += 1 }) && applies == 1,
              "phone off restart waits", "the saved =0 applies once nothing is in progress and no work runs")
        // A failed restart keeps the wait; a proved one clears it.
        PhoneApprovalsOff.finished(store: mem, helperSucceeded: false)
        check(mem.load() != nil, "phone off failed restart keeps the wait", "only a proved restart clears it")
        PhoneApprovalsOff.finished(store: mem, helperSucceeded: true)
        check(mem.load() == nil && !PhoneApprovalsOff.resume(store: mem, locked: false, workActive: false, apply: { applies += 1 }) && applies == 1,
              "phone off failed restart keeps the wait", "a proved restart clears it, and nothing applies again")
        // Nothing running: the revoke and the restart both run now.
        let idle = Mem()
        var order: [String] = []
        _ = await PhoneApprovalsOff.run(store: idle, now: 8, revokeAll: { order.append("revoke"); return true },
                                        locked: { false }, workActive: { false }, apply: { order.append("apply") })
        check(order == ["revoke", "apply"], "phone off revokes at once", "with nothing running, the revoke and then the restart")
        // A Revoke all that did not reach the server never reads as stopped.
        let failed = await PhoneApprovalsOff.run(store: Mem(), now: 9, revokeAll: { false }, locked: { false }, workActive: { true }, apply: {})
        let failedLine = PhoneApprovalsOff.line(failed, waiting: true)
        check(!failed.revokedAll && !failedLine.contains("are stopped") && failedLine.contains("may still approve"),
              "phone off failed revoke is not stopped", "the row says a phone may still approve")
        check(PhoneApprovalsOff.line(.init(revokedAll: true, savedAt: 1), waiting: false) == PhoneApprovalsOff.stopped
              && PhoneApprovalsOff.line(.init(revokedAll: true, savedAt: 1), waiting: true).hasSuffix(PhoneApprovalsOff.waits),
              "phone off line", "stopped, and the wait only while it waits")
        // The confirm says it before he confirms: every phone is removed and must be enrolled again.
        let off = PhoneApprovalsSwitch.confirmOffMessage
        check(off.contains("Every enrolled phone is removed") && off.contains("enroll each phone again"), "phone off confirm",
              "the Off confirm says every phone is removed and must be enrolled again")
        check([PhoneApprovalsOff.stopped, PhoneApprovalsOff.notStopped, PhoneApprovalsOff.waits, off, PhoneApprovalsSwitch.confirmOff]
                .allSatisfy { !$0.isEmpty && !$0.contains("—") && !$0.contains("COS_") }, "phone off confirm", "plain copy")
        // The app's store survives a new store object (UserDefaults), and clears.
        let suite = "cos.web-key-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        DefaultsPhoneApprovalsPendingStore(defaults: defaults).save(.init(revokedAll: false, savedAt: 42))
        let reread = DefaultsPhoneApprovalsPendingStore(defaults: defaults)
        check(reread.load() == PhoneApprovalsPendingOff(revokedAll: false, savedAt: 42), "phone off wait is saved", "a new store reads the saved wait")
        reread.clear()
        check(DefaultsPhoneApprovalsPendingStore(defaults: defaults).load() == nil, "phone off wait is saved", "clear removes it")
        defaults.removePersistentDomain(forName: suite)
    }

    /// SR-11 (2026-11-11): golden.json's signerTlsReasons, written by gen_control_golden.mts from the SERVER's own
    /// SIGNER_TLS_REASONS, equal Control's sentence keys plus "ok" (which never gets a sentence: it means trusted).
    static func reasonParity(_ g: [String: Any]) {
        let server = g["signerTlsReasons"] as? [String] ?? []
        let control = Set(WebKeySignerTLS.sentences.keys).union(["ok"])
        check(!server.isEmpty && server.count == Set(server).count && Set(server) == control, "signer reasons match the server",
              "the server's list \(server.sorted()) equals Control's sentences plus ok \(control.sorted())")
    }

    /// 0.5.390: the server's `signerTls` (server 7.0.20, web-key-signer-tls.ts SignerTlsStatus) drives one plain line.
    static func signerTLSLine() {
        let origin = "https://example-mac.tail00000a.ts.net:3144", now = Date(timeIntervalSince1970: 1_794_300_000)
        func body(_ tls: [String: Any]?) -> [String: Any] {
            var b: [String: Any] = ["enabled": true, "origin": origin]
            if let tls { b["signerTls"] = tls }
            return b
        }
        func tls(trusted: Bool, reason: String, host: Any = "example-mac.tail00000a.ts.net", notAfter: Any = "2027-02-08T17:38:32.000Z",
                 lastError: Any = NSNull(), storedRefused: Any = NSNull()) -> [String: Any] {
            ["trusted": trusted, "reason": reason, "host": host, "notAfter": notAfter, "lastError": lastError, "checkedAt": NSNull(), "nextCheckAt": NSNull(),
             "storedRefused": storedRefused]
        }
        // Server reopen: signerTls.storedRefused, why a hand-placed pair was refused, from the same one list.
        let stillOff = tls(trusted: false, reason: "tailnet_https_certs_off", host: NSNull(), notAfter: NSNull(), storedRefused: "stored_owner")
        check(WebKeySignerTLS.storedRefused(body: body(stillOff), now: now) == WebKeySignerTLS.sentences["stored_owner"]
              && WebKeySignerTLS.problem(body: body(stillOff), now: now) == WebKeySignerTLS.certsOff, "signer stored refusal",
              "a refused hand-placed pair gets its own sentence beside the main line")
        check(WebKeySignerTLS.storedRefused(body: body(tls(trusted: true, reason: "ok", storedRefused: "cert_untrusted")), now: now)
              == WebKeySignerTLS.sentences["cert_untrusted"], "signer stored refusal", "shown even while another pair serves trusted")
        check(WebKeySignerTLS.storedRefused(body: body(tls(trusted: false, reason: "pending")), now: now) == nil
              && WebKeySignerTLS.storedRefused(body: body(nil), now: now) == nil
              && WebKeySignerTLS.storedRefused(body: body(tls(trusted: false, reason: "pending", storedRefused: "")), now: now) == nil,
              "signer stored refusal", "null, missing or empty: no second line")
        check(WebKeySignerTLS.storedRefused(body: body(tls(trusted: false, reason: "stored_writable", host: NSNull(), notAfter: NSNull(), storedRefused: "stored_writable")), now: now) == nil,
              "signer stored refusal", "never the same sentence twice: the main line already says it")
        check(WebKeySignerTLS.storedRefused(body: body(tls(trusted: false, reason: "pending", storedRefused: "made_up_reason_7020")), now: now) == WebKeySignerTLS.fallback,
              "signer stored refusal", "an unknown code gets the plain fallback, never the code")
        check(WebKeySignerTLS.problem(body: body(nil), now: now) == nil, "signer cert line", "a server without signerTls gets no line")
        check(WebKeySignerTLS.problem(body: body(tls(trusted: true, reason: "ok")), now: now) == nil, "signer cert line", "trusted for the origin's host: no line")
        check(WebKeySignerTLS.problem(body: body(tls(trusted: true, reason: "ok", lastError: "tailscale_cert_failed")), now: now) == nil,
              "signer cert line", "a renewal error behind a serving pair is not shown (lastError is not read)")
        check(WebKeySignerTLS.problem(body: body(tls(trusted: false, reason: "tailnet_https_certs_off", host: NSNull(), notAfter: NSNull())), now: now)
              == "Turn on HTTPS Certificates in your Tailscale admin console.", "signer cert line", "the tailnet toggle off says exactly what to do")
        check(WebKeySignerTLS.problem(body: body(tls(trusted: false, reason: "tailscale_cli_gui_unavailable", host: NSNull(), notAfter: NSNull())), now: now)
              == WebKeySignerTLS.line("tailscale_cli_gui_unavailable") && WebKeySignerTLS.line("tailscale_cli_gui_unavailable").contains("Tailscale app"),
              "signer cert line", "the CLI that cannot run gets its own sentence")
        check(WebKeySignerTLS.problem(body: body(tls(trusted: true, reason: "ok", host: "other-mac.tail00000a.ts.net")), now: now) != nil,
              "signer cert line", "trusted for another host is not trusted for this origin")
        check(WebKeySignerTLS.problem(body: body(tls(trusted: true, reason: "ok", notAfter: "2026-11-01T00:00:00.000Z")), now: now) != nil,
              "signer cert line", "trusted but past notAfter is not trusted")
        check(WebKeySignerTLS.problem(body: body(tls(trusted: true, reason: "ok", notAfter: NSNull())), now: now) != nil,
              "signer cert line", "trusted with no notAfter is not trusted")
        check(WebKeySignerTLS.date("2027-02-08T17:38:32.000Z") != nil && WebKeySignerTLS.date("2027-02-08T17:38:32Z") != nil && WebKeySignerTLS.date("soon") == nil,
              "signer cert line", "the server's ISO times parse, with or without milliseconds")
        // The codes come from the ONE list in Sources/WebKeyCore.swift, never a copy here (Tests/web-key-pins.py).
        let reasons = Array(WebKeySignerTLS.sentences.keys)
        check(!reasons.isEmpty && reasons.allSatisfy { WebKeySignerTLS.line($0) == WebKeySignerTLS.sentences[$0] && WebKeySignerTLS.line($0) != WebKeySignerTLS.fallback },
              "signer cert line", "every listed reason gets its own sentence, not the fallback")
        check(WebKeySignerTLS.line("made_up_reason_7020") == WebKeySignerTLS.fallback && WebKeySignerTLS.line(nil) == WebKeySignerTLS.fallback
              && WebKeySignerTLS.problem(body: body(tls(trusted: false, reason: "made_up_reason_7020", host: NSNull(), notAfter: NSNull())), now: now)
              == WebKeySignerTLS.fallback, "signer cert line", "a code the server adds later, or none, gets the plain fallback, never the code")
        check((Array(WebKeySignerTLS.sentences.values) + [WebKeySignerTLS.fallback]).allSatisfy { !$0.isEmpty && !$0.contains("—") && !$0.contains("_") },
              "signer cert line", "plain sentences: no codes, no em dashes")
    }

    /// 0.5.390 (QA 2026-11-09 open question 2): the signer audit's TLS trust (HelperSources/PairingCore.swift, SignerTLSCore).
    /// Real Let's Encrypt chains (public certificates from LE's own test sites, Tests/fixtures/web-key/tls) at a pinned date
    /// inside both leaves' validity, and a throwaway root, a second root and a ts.net leaf that Tests/run-web-key.sh mints
    /// for this run (COS_WEB_KEY_TLS_DIR; no key is committed). No network: the evaluator never fetches.
    static func signerTLSTrust(fixtures: URL) {
        func chain(_ url: URL) -> [Data] { SignerTLSCore.certificates((try? String(contentsOf: url, encoding: .utf8)) ?? "") }
        func cert(_ der: Data) -> SecCertificate? { SecCertificateCreateWithData(nil, der as CFData) }
        func pem(_ der: Data) -> String {
            "-----BEGIN CERTIFICATE-----\n" + der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) + "\n-----END CERTIFICATE-----"
        }
        let tsHost = "example-mac.tail00000a.ts.net"

        // The split: the ts.net signer host is judged by the system roots; localhost and IP literals keep the managed cert.
        check(SignerTLSCore.trust(host: tsHost) == .systemRoots, "audit trust split", "the ts.net signer host is judged by the system roots")
        for host in ["localhost", "127.0.0.1", "100.112.156.116", "::1", "[::1]"] {
            check(SignerTLSCore.trust(host: host) == .managedCert, "audit trust split", "\(host) keeps the managed certificate")
        }
        for host in ["", "tail00000a.ts.net", "Example-Mac.tail00000a.ts.net", "mac.tail00000a.ts.net.", "mac.ts.net.example.com",
                     "api.gotcos.com", "example.com", "999.1.1.1", "mac_studio.tail00000a.ts.net"] {
            check(SignerTLSCore.trust(host: host) == nil, "audit trust split", "\(host.isEmpty ? "(empty)" : host) gets no trust at all")
        }

        // curl's arguments: no CA file for the ts.net host (Apple's curl would only ADD it to the keychain's trust), and the
        // chain it received is written out; never --insecure for either.
        let system = SignerTLSCore.curlTrustArguments(.systemRoots, managedCert: "/m/cert.pem")
        let managed = SignerTLSCore.curlTrustArguments(.managedCert, managedCert: "/m/cert.pem")
        check(!system.contains("--cacert") && !system.contains("/m/cert.pem") && !system.contains("--capath"),
              "audit curl trust args", "the ts.net fetch passes no CA file")
        check(system == ["--write-out", "%{http_code}\n%{num_certs}\n%{certs}"], "audit curl trust args",
              "the ts.net fetch writes out curl's own chain count, then the chain it received")
        check(managed == ["--cacert", "/m/cert.pem", "--write-out", "%{http_code}"], "audit curl trust args",
              "localhost and IP fetches keep --cacert with the managed certificate")
        for arguments in [system, managed] {
            check(!arguments.contains("--insecure") && !arguments.contains("-k"), "audit curl trust args", "never --insecure: curl keeps its own checks")
        }

        // curl's answer: the status is the first line; the chain is every certificate block after it, leaf first.
        let x1 = chain(fixtures.appendingPathComponent("valid-isrgrootx1.letsencrypt.org.pem"))
        let x2 = chain(fixtures.appendingPathComponent("valid-isrgrootx2.letsencrypt.org.pem"))
        check(x1.count == 3 && x2.count == 3, "audit fixtures", "both committed Let's Encrypt chains parse: leaf, intermediate, cross-signed root")
        guard x2.count == 3, x1.count == 3 else { return }
        let written = "200\n2\nSubject:CN = valid-isrgrootx2.letsencrypt.org\nIssuer:CN = YE1\nCert:" + pem(x2[0]) + "\nSubject:CN = YE1\nCert:" + pem(x2[1]) + "\n"
        let answer = SignerTLSCore.curlAnswer(written)
        check(answer.code == "200" && answer.chain == [x2[0], x2[1]], "audit curl answer", "status first, then the received chain, leaf first")
        check(SignerTLSCore.curlAnswer("200").code == "200" && SignerTLSCore.curlAnswer("200").chain.isEmpty, "audit curl answer", "a bare status has no chain")
        check(SignerTLSCore.curlAnswer("404\n1\n" + pem(x2[0])).code == "404", "audit curl answer", "the code is the first line, never a later one")
        let garbled = "200\n1\nCert:-----BEGIN CERTIFICATE-----\nAAA\n-----END CERTIFICATE-----\nCert:" + pem(x2[0])
        check(SignerTLSCore.curlAnswer(garbled).chain == [x2[0]], "audit curl answer", "a block that is not base64 is dropped, never half read")

        // SR-02: a PEM block inside a certificate extension. The fixture is Apple curl 8.7.1's real write-out for a throwaway
        // ts.net leaf whose extension 1.3.6.1.4.1.55555.1 holds the public LE X2 leaf (num_certs 2, three PEM blocks, the
        // injected one FIRST). The count must refuse it, or the injected public leaf would be judged as this connection's.
        let injected = (try? String(contentsOf: fixtures.appendingPathComponent("curl-certinfo-injected.txt"), encoding: .utf8)) ?? ""
        check(SignerTLSCore.certificates(injected).count == 3 && SignerTLSCore.certificates(injected).first == x2[0]
              && injected.split(separator: "\n", maxSplits: 2).dropFirst().first == "2",
              "audit refuses injected blocks", "control: the real curl output carries 3 PEM blocks, the injected LE leaf first, for curl's count of 2")
        check(SignerTLSCore.curlAnswer(injected).code == "200" && SignerTLSCore.curlAnswer(injected).chain.isEmpty, "audit refuses injected blocks",
              "more PEM blocks than curl's own %{num_certs}: no chain at all, so the audit refuses signer_tls")
        check(!SignerTLSCore.trusted(chain: SignerTLSCore.curlAnswer(injected).chain, host: "valid-isrgrootx2.letsencrypt.org",
                                     at: ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")!, anchors: SignerTLSCore.systemRoots()),
              "audit refuses injected blocks", "even for the injected leaf's own name and date, the empty chain is not trusted")
        check(SignerTLSCore.curlAnswer("200\nSubject:CN = x\nCert:" + pem(x2[0])).chain.isEmpty
              && SignerTLSCore.curlAnswer("200\n0\nCert:" + pem(x2[0])).chain.isEmpty
              && SignerTLSCore.curlAnswer("200\n1\nCert:" + pem(x2[0]) + "\nCert:" + pem(x2[1])).chain.isEmpty,
              "audit refuses injected blocks", "no count line, a zero count, or fewer counted than found: no chain")

        // SR-07: curl's own TLS failures are a TLS problem.
        check([35, 51, 58, 60].allSatisfy { SignerTLSCore.curlFailureReason(exit: $0) == "signer_tls" }, "audit curl tls exits",
              "curl exits 35, 51, 58 and 60 say signer_tls")
        check([1, 6, 7, 22, 28, 63].allSatisfy { SignerTLSCore.curlFailureReason(exit: $0) == "served_signer_assets" }, "audit curl tls exits",
              "any other failure (HTTP error 22, timeout 28, connect 7, too big 63) stays served_signer_assets")

        // The system trust domain: both ISRG roots, and never a locally added root (this Mac's admin domain trusts mkcert's).
        let roots = SignerTLSCore.systemRoots()
        let names = roots.compactMap { SecCertificateCopySubjectSummary($0) as String? }
        check(roots.count >= 50 && names.contains("ISRG Root X1") && names.contains("ISRG Root X2"), "audit system roots",
              "the roots macOS ships, with Let's Encrypt's X1 and X2 (\(roots.count) roots)")
        check(!names.contains(where: { $0.lowercased().contains("mkcert") }), "audit system roots", "no locally added root, mkcert's included")

        // The threat itself, on this Mac: an mkcert-issued chain this Mac's keychain TRUSTS is refused by the system roots
        // alone. Public certificates only: the managed leaf (~/.cos-glasses/certs/cert.pem, issued for localhost among its
        // names) and the mkcert root as the admin trust domain lists it. Never the private key beside either. The host is a
        // name the leaf really carries, so the anchor is the only reason left to refuse it; a ts.net-named mkcert leaf has
        // the same anchor. Skipped, and said so, on a Mac without mkcert.
        var adminList: CFArray?
        let admin = SecTrustSettingsCopyCertificates(.admin, &adminList) == errSecSuccess ? (adminList as? [SecCertificate] ?? []) : []
        let mkcertRoot = admin.first { (SecCertificateCopySubjectSummary($0) as String?)?.hasPrefix("mkcert ") == true }
        let managedLeaf = chain(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cos-glasses/certs/cert.pem")).first
        if let mkcertRoot, let managedLeaf {
            let mk = [managedLeaf, SecCertificateCopyData(mkcertRoot) as Data]
            check(keychainTrusts(mk, host: "localhost"), "audit refuses mkcert", "control: this Mac's keychain trusts the managed mkcert chain for localhost")
            check(!SignerTLSCore.trusted(chain: mk, host: "localhost", at: Date(), anchors: roots), "audit refuses mkcert",
                  "the keychain-trusted mkcert chain is refused by the system roots alone")
            check(SignerTLSCore.trusted(chain: mk, host: "localhost", at: Date(), anchors: [mkcertRoot]), "audit refuses mkcert",
                  "control: the same chain verifies when its own root is the anchor, so the anchor is the only reason")
            check(!SignerTLSCore.trusted(chain: mk, host: tsHost, at: Date(), anchors: roots), "audit refuses mkcert",
                  "the mkcert chain judged for the ts.net signer name is refused")
            print("RAN [audit refuses mkcert]: this Mac's managed mkcert chain, read at run time and never stored")
        } else {
            // Never silent: Tests/run-web-key.sh counts SKIP lines and reports them.
            print("SKIP [audit refuses mkcert]: no admin-trusted mkcert root or no managed certificate on this Mac")
        }

        // Real chains at a date inside both leaves' validity: the system roots ALONE accept them, for their own names only.
        let pinned = ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")!
        check(SignerTLSCore.trusted(chain: x1, host: "valid-isrgrootx1.letsencrypt.org", at: pinned, anchors: roots), "audit public chain",
              "an ISRG Root X1 chain verifies against the system roots alone")
        check(SignerTLSCore.trusted(chain: x2, host: "valid-isrgrootx2.letsencrypt.org", at: pinned, anchors: roots), "audit public chain",
              "an ISRG Root X2 chain (ECDSA P-256, like Tailscale's) verifies against the system roots alone")
        check(!SignerTLSCore.trusted(chain: x2, host: tsHost, at: pinned, anchors: roots), "audit hostname", "a valid public chain for another name is refused")
        check(!SignerTLSCore.trusted(chain: x2, host: "valid-isrgrootx2.letsencrypt.org", at: ISO8601DateFormatter().date(from: "2027-03-01T00:00:00Z")!, anchors: roots),
              "audit expiry", "a public leaf is refused after its notAfter")

        // A throwaway root and leaf: the evaluator passes a good chain, and refuses every other anchor, name and date.
        let tls = ProcessInfo.processInfo.environment["COS_WEB_KEY_TLS_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let root = tls.flatMap { chain($0.appendingPathComponent("root.pem")).first }.flatMap(cert)
        let other = tls.flatMap { chain($0.appendingPathComponent("other.pem")).first }.flatMap(cert)
        let minted = tls.map { chain($0.appendingPathComponent("leaf-chain.pem")) } ?? []
        check(root != nil && other != nil && minted.count == 2, "audit fixtures", "Tests/run-web-key.sh minted a throwaway root, a second root and a ts.net leaf")
        guard let root, let other, minted.count == 2 else { return }
        let leafHost = tsHost, now = Date()
        // The machine-independent twin of the mkcert check, always run: a root the caller holds (what the old --cacert
        // added) vouches for a leaf with the EXACT ts.net signer name; under the system roots alone the chain is refused.
        check(SignerTLSCore.trusted(chain: minted, host: tsHost, at: now, anchors: [root]), "audit refuses an extra root",
              "control: with the caller's root as the anchor the ts.net chain verifies, so the anchor is the only reason")
        check(!SignerTLSCore.trusted(chain: minted, host: tsHost, at: now, anchors: roots), "audit refuses an extra root",
              "the same ts.net chain is refused under the system roots alone")
        check(!SignerTLSCore.trusted(chain: x2, host: "valid-isrgrootx2.letsencrypt.org", at: pinned, anchors: [root]), "audit anchors only",
              "a publicly trusted chain is refused when its root is not among the anchors (the keychain's trust never counts)")
        check(SignerTLSCore.trusted(chain: minted, host: leafHost, at: now, anchors: [root]), "audit evaluator", "a good chain for its host, under its own root, verifies")
        check(!SignerTLSCore.trusted(chain: minted, host: "other-mac.tail00000a.ts.net", at: now, anchors: [root]), "audit hostname",
              "the same chain for another ts.net name is refused")
        check(!SignerTLSCore.trusted(chain: minted, host: leafHost, at: now, anchors: roots), "audit anchors only", "a root this Mac made is never a system root")
        check(!SignerTLSCore.trusted(chain: minted, host: leafHost, at: now, anchors: [other]), "audit anchors only", "another root does not vouch for this chain")
        check(!SignerTLSCore.trusted(chain: minted, host: leafHost, at: now.addingTimeInterval(40 * 86_400), anchors: [root]), "audit expiry",
              "the leaf is refused after its notAfter")
        check(!SignerTLSCore.trusted(chain: Array(repeating: minted[0], count: 9), host: leafHost, at: now, anchors: [root]),
              "audit chain bounds", "more than 8 certificates: refused, though SecTrust takes the padded chain")

        // The three empty inputs, each on an input that is otherwise VALID (the controls above pass these same chains,
        // dates and anchors), so the empty value is the only reason left to refuse. Each prints why: "input" is the
        // guard; anything else is SecTrust refusing on its own (Q1 and the lead, 14:27).
        func refusedWithEvidence(_ tag: String, _ result: (trusted: Bool, why: String)) -> Bool {
            print("EVIDENCE [\(tag)]: trusted=\(result.trusted) why=\(result.why)")
            return !result.trusted
        }
        check(refusedWithEvidence("audit empty host", SignerTLSCore.evaluate(chain: minted, host: "", at: now, anchors: [root])), "audit empty host",
              "a valid chain under its own root, with host \"\": refused")
        check(refusedWithEvidence("audit empty host", SignerTLSCore.evaluate(chain: x2, host: "", at: pinned, anchors: roots)), "audit empty host",
              "the public LE X2 chain inside its validity, system roots, host \"\": refused")
        check(refusedWithEvidence("audit empty anchors", SignerTLSCore.evaluate(chain: x2, host: "valid-isrgrootx2.letsencrypt.org", at: pinned, anchors: [])),
              "audit empty anchors", "the public LE X2 chain (ISRG Root X2 is a system root) with an EMPTY anchor list: refused, never the system roots")
        check(refusedWithEvidence("audit empty anchors", SignerTLSCore.evaluate(chain: x1, host: "valid-isrgrootx1.letsencrypt.org", at: pinned, anchors: [])),
              "audit empty anchors", "the public LE X1 chain with an EMPTY anchor list: refused")
        check(refusedWithEvidence("audit empty chain", SignerTLSCore.evaluate(chain: [], host: "valid-isrgrootx2.letsencrypt.org", at: pinned, anchors: roots)),
              "audit empty chain", "no certificates at all: refused")
        let control = SignerTLSCore.evaluate(chain: x2, host: "valid-isrgrootx2.letsencrypt.org", at: pinned, anchors: roots)
        check(control.trusted && control.why == "ok", "audit empty anchors", "control: the same X2 chain, date and host with the system roots is trusted (why ok)")
    }

    static func cancellation() async {
        let before = WebKeyBiometryAttempt(), first = Reasons()
        before.cancel()
        do {
            try await withCheckedThrowingContinuation { (next: CheckedContinuation<Void, Error>) in
                check(!before.begin(next, cancel: { first.cancellations += 1 }), "biometry cancellation", "cancellation before context setup refuses begin")
            }
            check(false, "biometry cancellation", "early cancellation unexpectedly succeeded")
        } catch { check(first.cancellations == 1, "biometry cancellation", "early context invalidation runs once") }
        let during = WebKeyBiometryAttempt(), second = Reasons()
        do {
            try await withCheckedThrowingContinuation { (next: CheckedContinuation<Void, Error>) in
                check(during.begin(next, cancel: { second.cancellations += 1 }), "biometry cancellation", "context begins")
                during.cancel()
                during.finish(.success(()))
                during.cancel()
            }
            check(false, "biometry cancellation", "cancelled context unexpectedly succeeded")
        } catch { check(second.cancellations == 1, "biometry cancellation", "late success cannot double resume or revive cancellation") }
        let success = WebKeyBiometryAttempt(), third = Reasons()
        do {
            try await withCheckedThrowingContinuation { (next: CheckedContinuation<Void, Error>) in
                _ = success.begin(next, cancel: { third.cancellations += 1 })
                success.finish(.success(()))
                success.finish(.failure(WebKeyAnchorError.signFailed))
                success.cancel()
            }
            check(third.cancellations == 0, "biometry cancellation", "completion is consumed exactly once")
        } catch { check(false, "biometry cancellation", "successful completion changed") }
    }

    @MainActor
    static func recoveryFlow(anchorRaw: Data, selfDns: String) async {
        let fake = FakeServer(), mem = MemoryStore(), reasons = Reasons()
        let dir = scratchDir("reset")
        let origin = "https://" + selfDns + ":3144"
        fake.listeners = audited(["servicePID": 4242, "ports": ["3141": [["pid": 4243, "underService": true]], "3143": [["pid": 4243, "underService": true]], "3144": [["pid": 4243, "underService": true]]]])
        fake.answers["status"] = (200, ["enabled": true, "anchorRegistered": false, "origin": origin])
        fake.answers["keys"] = (200, ["epoch": 0, "keys": [Any]()])
        fake.answers["pending"] = (200, ["pending": NSNull()])
        var epoch = -1
        fake.onCall = { op, body in
            guard op == "anchor", let der = (body["anchorPub"] as? String).flatMap(WebKeyB64.decode),
                  let statement = (body["statement"] as? String).flatMap(WebKeyB64.decode),
                  let signature = (body["signature"] as? String).flatMap(WebKeyB64.decode), verifies(der, statement, signature) else { return }
            epoch += 1
            fake.answers["anchor"] = (201, ["ok": true])
            fake.answers["status"] = (200, ["enabled": true, "anchorRegistered": true, "anchorMature": false, "origin": origin,
                "aud": WebKeyProtocol.aud(anchorDER: der, rpId: selfDns)])
            fake.answers["keys"] = (200, ["epoch": epoch, "keys": [Any]()])
        }
        func make(_ raw: Data) -> WebKeyState {
            let state = WebKeyState()
            state.runHelper = { args, body in await fake.run(args, body) }
            state.secure = mem; state.stateDirectory = dir
            state.makeAnchor = { SoftAnchor(raw: raw, reasons: reasons) }
            state.loadAnchor = { SoftAnchor(raw: $0, reasons: reasons) }
            state.anchorBlob = { ($0 as? SoftAnchor)?.raw }
            return state
        }
        let initial = make(anchorRaw)
        await initial.refresh()
        mem.failedWriteAccounts = [WebKeyStateStore.mirrorAccount]
        await initial.createOrRegisterAnchor()
        check(initial.anchorRegisteredHere && !initial.protectionReady && mem.items[SecureEnclaveWebKeyAnchor.blobAccount] == anchorRaw,
              "bootstrap crash recovery", "anchor registration can finish while protected-state initialization fails closed")
        let beforeSame = fake.count("anchor")
        await initial.createOrRegisterAnchor(recovery: true)
        check(fake.count("anchor") == beforeSame, "reset requires distinct anchor", "a reset can never reuse the old key to forget its history")
        mem.failedWriteAccounts = []
        let nextRaw = P256.Signing.PrivateKey().rawRepresentation
        let resumed = make(nextRaw)
        await resumed.refresh()
        check(resumed.anchorRegisteredHere && resumed.recoveryRequired && !resumed.protectionReady,
              "bootstrap crash recovery", "restart exposes explicit recovery instead of silently accepting a server snapshot")
        let anchorPosts = fake.count("anchor")
        reasons.refuse = true
        await resumed.createOrRegisterAnchor(recovery: true)
        check(fake.count("anchor") == anchorPosts && mem.items[SecureEnclaveWebKeyAnchor.blobAccount] == anchorRaw,
              "reset requires Touch ID", "cancelled reset preserves the old anchor and posts nothing")
        reasons.refuse = false
        await resumed.createOrRegisterAnchor(recovery: true)
        let newDER = try! P256.Signing.PrivateKey(rawRepresentation: nextRaw).publicKey.derRepresentation
        check(resumed.protectionReady && !resumed.recoveryRequired && resumed.controlState?.epoch == 1 &&
              resumed.controlState?.anchorSpkiSha256 == WebKeyHash.sha256Hex(newDER) && mem.items[SecureEnclaveWebKeyAnchor.blobAccount] == nextRaw,
              "reset rotates anchor", "a different Touch ID anchor rebinds protected state after server confirmation")
        check(!resumed.anchorMature && resumed.pinJSON().map { obj(Data($0.utf8))["spkiSha256"] as? String } == WebKeyHash.sha256Hex(newDER),
              "reset requires new pin and maturity", "the old committed pin cannot authorize the new anchor")
        // A damaged mirror has the same explicit exit, but a locked/denied Keychain is never overwritten.
        mem.items[WebKeyStateStore.mirrorAccount] = Data("damaged mirror".utf8)
        let thirdRaw = P256.Signing.PrivateKey().rawRepresentation
        let damaged = make(thirdRaw)
        await damaged.refresh()
        check(damaged.recoveryRequired && !damaged.protectionReady, "damaged mirror recovery", "a corrupt protected mirror grants nothing")
        mem.failRead = true
        let beforeLocked = fake.count("anchor")
        await damaged.createOrRegisterAnchor(recovery: true)
        check(fake.count("anchor") == beforeLocked && mem.items[SecureEnclaveWebKeyAnchor.blobAccount] == nextRaw,
              "locked mirror cannot reset", "unreadable Keychain is not absence")
        mem.failRead = false
        await damaged.createOrRegisterAnchor(recovery: true)
        let thirdDER = try! P256.Signing.PrivateKey(rawRepresentation: thirdRaw).publicKey.derRepresentation
        check(damaged.protectionReady && damaged.controlState?.epoch == 2 && damaged.controlState?.anchorSpkiSha256 == WebKeyHash.sha256Hex(thirdDER),
              "damaged mirror recovery", "only a newly signed anchor registration replaces the damaged record")
        try? FileManager.default.removeItem(at: dir)
    }

    /// 0.5.383 (server 7.0.9, COS_WEB_KEY_ANCHOR_BOOTSTRAP): the mode reader, the audit scopes and the helper's anchor audit.
    static func bootstrapRules(selfDns: String) {
        let origin = "https://\(selfDns):3144"
        func mode(_ status: Int, _ body: [String: Any]) -> WebKeyServerMode { WebKeyServerMode.read(status: status, body: obj(json(viaJSONValue(body)))) }
        check(mode(200, ["enabled": true, "origin": origin]) == .authority, "bootstrap mode reader", "today's authority reply is authority")
        check(mode(200, ["enabled": true, "mode": "authority", "origin": origin]) == .authority, "bootstrap mode reader", "an explicit authority mode")
        check(mode(200, ["enabled": false, "mode": "bootstrap", "origin": origin]) == .bootstrap, "bootstrap mode reader", "enabled false plus mode bootstrap")
        check(mode(200, ["enabled": true, "mode": "bootstrap", "origin": origin]) == .off, "bootstrap mode reader", "a contradiction hides the section")
        check(mode(200, ["enabled": false, "origin": origin]) == .off && mode(200, ["enabled": false, "mode": "Bootstrap", "origin": origin]) == .off
              && mode(200, ["mode": "bootstrap", "origin": origin]) == .off, "bootstrap mode reader", "both off, an older server, or a misspelt mode: off")
        check(mode(200, ["enabled": false, "mode": "bootstrap"]) == .off && mode(200, ["enabled": false, "mode": "bootstrap", "origin": "https://\(selfDns):3143"]) == .off
              && mode(404, ["enabled": false, "mode": "bootstrap", "origin": origin]) == .off, "bootstrap mode reader", "no signer origin or no 200: off")
        let at = Date(timeIntervalSince1970: 1_786_000_000)
        let mine: [[String: Any]] = [["pid": 4243, "underService": true]]
        func anchorAudit(_ ports: [String: Any], stable: Bool = true, scope: String? = "anchor") -> WebKeyListenerAudit {
            var d: [String: Any] = ["servicePID": 4242, "ports": ports, "stable": stable]
            if let scope { d["scope"] = scope }
            return WebKeyListenerAudit.judgeAnchor(obj(json(viaJSONValue(d))), at: at)
        }
        let good = anchorAudit(["3141": mine, "3143": mine])
        check(good.genuine && good.scope == .anchor && good.freshForAnchorRegistration(now: at.addingTimeInterval(59)), "bootstrap anchor audit", "one service PID on 3141 and 3143")
        check(!good.fresh(now: at), "bootstrap anchor audit never approves", "an anchor-scope audit is never a fresh signer audit")
        check(!good.freshForAnchorRegistration(now: at.addingTimeInterval(61)), "bootstrap anchor audit", "61 s old")
        check(!anchorAudit(["3141": mine]).genuine && !anchorAudit(["3141": mine, "3143": mine + [["pid": 9, "underService": false]]]).genuine
              && !anchorAudit(["3141": mine, "3143": [["pid": 5000, "underService": true]]]).genuine, "bootstrap anchor audit", "missing, foreign or split listeners refuse")
        let outsider: [[String: Any]] = [["pid": 4243, "underService": false]]
        check(!anchorAudit(["3141": outsider, "3143": outsider]).genuine, "bootstrap anchor audit", "one PID that is not under the COS LaunchAgent refuses")
        check(!anchorAudit(["3141": mine, "3143": mine], stable: false).genuine && !anchorAudit(["3141": mine, "3143": mine], scope: nil).genuine,
              "bootstrap anchor audit", "a listener that changed, or a full-audit answer, refuses")
        let signer = WebKeyListenerAudit(genuine: true, reason: "ok", checkedAt: at)
        check(signer.fresh(now: at) && !signer.freshForAnchorRegistration(now: at), "bootstrap anchor audit", "the signer audit stays the signer audit")
        check(good.line == WebKeyListenerAudit.anchorNotGenuineLine && signer.line == WebKeyListenerAudit.notGenuineLine, "bootstrap anchor audit", "each scope says its own line")
        let helper = WebKeyHelperCore.anchorListeners(servicePID: 4242, owners: [3141: [4243], 3143: [4243], 3144: [66]], underService: { $0 == 4243 }, stable: true)
        let ports = helper["ports"] as? [String: Any] ?? [:]
        check(Set(helper.keys) == ["servicePID", "ports", "scope", "stable"] && Set(ports.keys) == ["3141", "3143"] && helper["assets"] == nil
              && WebKeyHelperCore.ops.contains("anchor-listeners") && WebKeyHelperCore.calls["anchor-listeners"] == nil,
              "bootstrap helper audit", "3141 and 3143 only, no signer assets, a local op")
        check(WebKeyListenerAudit.judgeAnchor(obj(json(viaJSONValue(helper))), at: at).genuine, "bootstrap helper audit", "the helper's answer round trips")
        check(!WebKeyListenerAudit.judge(obj(json(viaJSONValue(helper))), at: at).genuine, "bootstrap anchor audit never approves", "the full judge refuses the anchor answer")
    }

    /// 0.5.383 bootstrap: the Mac anchor alone, then authority on later with no reset.
    @MainActor
    static func bootstrapFlow(anchorG: [String: Any], anchorDER: Data, anchorRaw: Data, selfDns: String) async {
        let origin = "https://\(selfDns):3144"
        let aud = anchorG["aud"] as! String
        let sha = anchorG["spkiSha256"] as! String
        let reasons = Reasons()
        let fake = FakeServer()
        let mem = MemoryStore()
        let dir = scratchDir("bootstrap")
        func make() -> WebKeyState {
            let s = WebKeyState()
            s.runHelper = { args, body in await fake.run(args, body) }
            s.secure = mem; s.stateDirectory = dir
            s.makeAnchor = { SoftAnchor(raw: anchorRaw, reasons: reasons) }
            s.loadAnchor = { SoftAnchor(raw: $0, reasons: reasons) }
            s.anchorBlob = { ($0 as? SoftAnchor)?.raw }
            return s
        }
        let mine: [[String: Any]] = [["pid": 4243, "underService": true]]
        fake.anchorListeners = ["servicePID": 4242, "ports": ["3141": mine, "3143": mine], "scope": "anchor", "stable": true]
        fake.listeners = audited(["servicePID": 4242, "ports": ["3141": mine, "3143": mine, "3144": mine]])
        fake.answers["status"] = (200, ["ok": true, "enabled": false, "mode": "bootstrap", "anchorRegistered": false, "anchorMature": false, "aud": NSNull(), "origin": origin, "epoch": 3])
        fake.answers["keys"] = (200, ["ok": true, "epoch": 3, "keys": [Any]()])
        fake.answers["pending"] = (200, ["ok": true, "pending": NSNull()])
        let state = make()
        await state.refresh()
        check(state.visible && state.bootstrapOnly && !state.authority && !state.anchorRegisteredHere && fake.calls.map(\.op) == ["status"]
              && mem.writes == 0, "bootstrap shows the anchor only", "visible, nothing asked but status, nothing written")
        // Cancel or deny Touch ID: nothing registered, no key kept, no record.
        reasons.refuse = true
        await state.createOrRegisterAnchor()
        check(fake.count("anchor") == 0 && mem.items[SecureEnclaveWebKeyAnchor.blobAccount] == nil && mem.items[WebKeyStateStore.mirrorAccount] == nil
              && !state.anchorRegisteredHere, "bootstrap cancel creates nothing", "a cancelled sheet posts nothing and keeps nothing")
        reasons.refuse = false
        check(fake.count("listeners") == 0 && fake.count("anchor-listeners") == 1, "bootstrap anchor audit", "registration ran the anchor audit, never the signer audit")
        // A foreign listener on 3143 stops registration before Touch ID.
        fake.anchorListeners = ["servicePID": 4242, "ports": ["3141": mine, "3143": mine + [["pid": 77, "underService": false]]], "scope": "anchor", "stable": true]
        reasons.list = []
        await state.createOrRegisterAnchor()
        check(fake.count("anchor") == 0 && reasons.list.isEmpty && state.message == WebKeyListenerAudit.anchorNotGenuineLine,
              "bootstrap anchor audit", "a foreign listener refuses before Touch ID")
        fake.anchorListeners = ["servicePID": 4242, "ports": ["3141": mine, "3143": mine], "scope": "anchor", "stable": true]
        // Register: the 201 carries setAt; this status reply does not report anchorSetAt.
        fake.onCall = { op, body in
            guard op == "anchor" else { return }
            let st = WebKeyB64.decode(body["statement"] as? String ?? ""), sig = WebKeyB64.decode(body["signature"] as? String ?? "")
            let okSig = st.flatMap { s in sig.map { verifies(anchorDER, s, $0) } } ?? false
            fake.answers["anchor"] = okSig ? (201, ["ok": true, "setAt": 1_786_000_123_000, "spkiSha256": sha]) : (403, ["ok": false])
            fake.answers["status"] = (200, ["ok": true, "enabled": false, "mode": "bootstrap", "anchorRegistered": true, "anchorMature": false, "aud": aud, "origin": origin, "epoch": 4])
        }
        await state.createOrRegisterAnchor()
        fake.onCall = nil
        check(fake.count("anchor") == 1 && state.anchorRegisteredHere && state.anchorSpkiSha256 == sha && state.anchorFingerprint == anchorG["fingerprint"] as? String
              && reasons.list.last == WebKeyProtocol.anchorReason(fingerprint: anchorG["fingerprint"] as! String), "bootstrap registers with Touch ID", "registered here, full key hash shown")
        check(state.anchorSetAt == 1_786_000_123_000, "bootstrap shows setAt", "the registration answer's setAt when status has none")
        check(state.controlState == WebKeyControlState.parse(mem.items[WebKeyStateStore.mirrorAccount] ?? Data()) && state.controlState?.epoch == 4
              && state.controlState?.anchorSpkiSha256 == sha && state.controlState?.revoked.isEmpty == true, "bootstrap starts the protected record", "epoch from status, this anchor, no revocations")
        check(["keys", "pending", "listeners", "approve", "revoke", "revoke-all"].allSatisfy { fake.count($0) == 0 }, "bootstrap hides enrollment and approval",
              "no key list, pending request, signer audit, approval or revocation call")
        check(state.pinJSON().map { obj(Data($0.utf8))["spkiSha256"] as? String } == sha, "bootstrap pin", "Copy pin names this anchor")
        // A pending request exists on the server: bootstrap never reads it, never shows a card, never approves.
        fake.answers["status"] = (200, ["ok": true, "enabled": false, "mode": "bootstrap", "anchorRegistered": true, "anchorMature": false, "aud": aud, "origin": origin, "epoch": 4, "anchorSetAt": 1_786_000_124_000])
        await state.refresh()
        check(state.anchorSetAt == 1_786_000_124_000, "bootstrap shows setAt", "the server's anchorSetAt wins")
        state.typedCode = "123456"
        await state.approve()
        await state.revoke("AAAAAAAAAAAAAAAAAAAAAA")
        await state.revokeAll()
        await state.createOrRegisterAnchor(recovery: true)
        check(state.card == nil && !state.approveAllowed && !state.protectionReady && state.keys.isEmpty
              && ["keys", "pending", "listeners", "approve", "revoke", "revoke-all"].allSatisfy { fake.count($0) == 0 } && fake.count("anchor") == 1
              && state.controlState?.revoked.isEmpty == true && state.controlState?.epoch == 4, "bootstrap hides enrollment and approval",
              "approve, revoke, revoke all and reset called directly do nothing")
        // Relaunch in bootstrap: the same anchor, nothing rewritten.
        let writes = mem.writes
        let relaunched = make()
        await relaunched.refresh()
        check(relaunched.anchorRegisteredHere && relaunched.bootstrapOnly && mem.writes == writes, "bootstrap relaunch", "the anchor is found, the record left alone")
        // Authority turns on later: today's lane, with this anchor's record and no reset.
        fake.answers["status"] = (200, ["ok": true, "enabled": true, "anchorRegistered": true, "anchorMature": true, "aud": aud, "origin": origin, "epoch": 4])
        fake.answers["keys"] = (200, ["ok": true, "epoch": 4, "keys": [Any]()])
        let later = make()
        await later.refresh()
        check(later.authority && !later.bootstrapOnly && later.protectionReady && !later.recoveryRequired && later.controlState?.anchorSpkiSha256 == sha
              && fake.count("keys") == 1, "bootstrap then authority needs no reset", "authority adopts the server's list for the bootstrap anchor")
        check(later.signerTLSLine == nil, "signer cert line", "a server that reports no signerTls shows no line")
        // 0.5.390: the server's signerTls drives one plain line, in authority mode only.
        let certsOff: [String: Any] = ["trusted": false, "reason": "tailnet_https_certs_off", "host": NSNull(), "notAfter": NSNull(),
                                       "lastError": "tailnet_https_certs_off", "checkedAt": NSNull(), "nextCheckAt": NSNull(), "storedRefused": "stored_symlink"]
        fake.answers["status"] = (200, ["ok": true, "enabled": true, "anchorRegistered": true, "anchorMature": true, "aud": aud, "origin": origin, "epoch": 4,
                                        "signerTls": certsOff])
        await later.refresh()
        check(later.authority && later.signerTLSLine == WebKeySignerTLS.certsOff, "signer cert line", "authority with the tailnet toggle off says so")
        check(later.signerTLSStoredLine == WebKeySignerTLS.sentences["stored_symlink"], "signer stored refusal",
              "authority shows why the hand-placed pair was refused")
        fake.answers["status"] = (200, ["ok": true, "enabled": false, "mode": "bootstrap", "anchorRegistered": true, "anchorMature": true, "aud": aud, "origin": origin,
                                        "epoch": 4, "signerTls": certsOff])
        await later.refresh()
        check(later.bootstrapOnly && later.signerTLSLine == nil, "signer cert line", "bootstrap never shows it")
        check(later.bootstrapOnly && later.signerTLSStoredLine == nil, "signer stored refusal", "bootstrap never shows the stored refusal")
        // A server that says enabled true with mode bootstrap is a contradiction: hidden, as with both off.
        fake.answers["status"] = (200, ["ok": true, "enabled": true, "mode": "bootstrap", "anchorRegistered": true, "aud": aud, "origin": origin, "epoch": 4])
        await later.refresh()
        check(!later.visible && later.mode == .off && later.anchorSetAt == nil, "bootstrap mode reader", "a contradictory reply hides the section")
        // The server resets setAt on a same-key registration: a plain Register never runs over a registered anchor.
        fake.answers["status"] = (200, ["ok": true, "enabled": false, "mode": "bootstrap", "anchorRegistered": false, "anchorMature": false, "aud": NSNull(), "origin": origin, "epoch": 4])
        let stale = make()
        await stale.refresh()
        fake.answers["status"] = (200, ["ok": true, "enabled": false, "mode": "bootstrap", "anchorRegistered": true, "anchorMature": false, "aud": aud, "origin": origin, "epoch": 4])
        let postsBefore = fake.count("anchor")
        reasons.list = []
        await stale.createOrRegisterAnchor()
        check(fake.count("anchor") == postsBefore && reasons.list.isEmpty, "never registers twice", "an anchor registered since the last read is not registered over, and Touch ID is not asked")
        await stale.refresh()
        await stale.createOrRegisterAnchor()
        check(stale.anchorRegisteredHere && fake.count("anchor") == postsBefore, "never registers twice", "registered here: Register does nothing")
        fake.answers["status"] = (200, ["ok": true, "enabled": false, "mode": "bootstrap", "anchorRegistered": true, "anchorMature": true, "aud": String(repeating: "f", count: 64), "origin": origin, "epoch": 4])
        await stale.refresh()
        stale.startRegistration()
        await stale.createOrRegisterAnchor()
        check(stale.foreignAnchor && fake.count("anchor") == postsBefore, "never registers twice", "another key on the server: plain Register refuses")
        fake.onCall = { op, _ in
            if op == "anchor" { fake.answers["status"] = (200, ["ok": true, "enabled": false, "mode": "bootstrap", "anchorRegistered": true, "anchorMature": false, "aud": aud, "origin": origin, "epoch": 5]) }
        }
        await stale.createOrRegisterAnchor(replace: true)
        fake.onCall = nil
        check(fake.count("anchor") == postsBefore + 1 && stale.anchorRegisteredHere, "confirmed replace", "only the confirmed replace registers over another key")
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    static func flow(pending: [String: Any], anchorG: [String: Any], anchorDER: Data, anchorRaw: Data, selfDns: String) async {
        let origin = "https://\(selfDns):3144"
        let aud = anchorG["aud"] as! String
        let startedAt = (pending["startedAt"] as! NSNumber).int64Value
        var clock = Date(timeIntervalSince1970: Double(startedAt + 1000) / 1000)
        let reasons = Reasons()
        let fake = FakeServer()
        let mem = MemoryStore()
        let dir = scratchDir("flow")
        func make() -> WebKeyState {
            let s = WebKeyState()
            s.runHelper = { args, body in await fake.run(args, body) }
            s.secure = mem
            s.stateDirectory = dir
            s.makeAnchor = { SoftAnchor(raw: anchorRaw, reasons: reasons) }
            s.loadAnchor = { blob in SoftAnchor(raw: blob, reasons: reasons) }
            s.anchorBlob = { ($0 as? SoftAnchor)?.raw }
            s.now = { clock }
            return s
        }
        let state = make()
        // Flag off (the route falls through): hidden, nothing else asked.
        fake.answers["status"] = (404, [:])
        await state.refresh()
        check(!state.visible && fake.calls.map(\.op) == ["status"], "hidden unless the flag", "a 404 hides the section and asks nothing more")
        fake.answers["status"] = (200, ["ok": true, "enabled": false, "origin": origin])
        await state.refresh()
        check(!state.visible, "hidden unless the flag", "enabled false")
        fake.calls = []
        fake.answers["status"] = nil
        await state.refresh()
        check(!state.visible, "hidden unless the flag", "no answer")
        check(mem.reads == 0 && mem.writes == 0 && fake.count("listeners") == 0,
              "flag off is inert", "older, disabled and unreachable status never touch the protected store or audit listeners")
        // Flag on, no anchor anywhere.
        fake.answers["status"] = (200, ["ok": true, "enabled": true, "anchorRegistered": false, "anchorMature": false, "aud": NSNull(), "origin": origin, "epoch": 0])
        await state.refresh()
        check(state.visible && state.anchorFingerprint == nil && !state.anchorRegisteredHere && !state.foreignAnchor, "anchor bootstrap", "visible, nothing yet")
        // Create and register: Touch ID (the stand-in) signs the statement, the helper posts it.
        var postedStatement: Data?
        fake.onCall = { op, body in
            guard op == "anchor" else { return }
            let st = WebKeyB64.decode(body["statement"] as? String ?? "")
            let sig = WebKeyB64.decode(body["signature"] as? String ?? "")
            postedStatement = st
            let okSig = st.flatMap { s in sig.map { verifies(anchorDER, s, $0) } } ?? false
            fake.answers["anchor"] = okSig && body["anchorPub"] as? String == anchorG["spki"] as? String ? (201, ["ok": true]) : (403, ["ok": false, "error": "anchor_signature_invalid"])
            fake.answers["status"] = (200, ["ok": true, "enabled": true, "anchorRegistered": true, "anchorMature": false, "aud": aud, "origin": origin, "epoch": 0])
        }
        fake.answers["keys"] = (200, ["ok": true, "epoch": 0, "keys": [Any]()])
        fake.answers["pending"] = (200, ["ok": true, "pending": NSNull()])
        fake.listeners = audited(["servicePID": 4242, "ports": ["3141": [["pid": 4243, "underService": true]], "3143": [["pid": 4243, "underService": true]], "3144": [["pid": 4243, "underService": true]]]])
        await state.createOrRegisterAnchor()
        check(mem.items[SecureEnclaveWebKeyAnchor.blobAccount] == anchorRaw, "anchor bootstrap", "the key's blob is kept in the keychain")
        check(postedStatement == WebKeyProtocol.anchorStatement(spki: anchorDER, createdAtMs: startedAt + 1000), "anchor bootstrap", "the statement as registerAnchor takes it")
        check(reasons.list.last == WebKeyProtocol.anchorReason(fingerprint: anchorG["fingerprint"] as! String), "anchor bootstrap", "Touch ID names the fingerprint")
        check(state.anchorRegisteredHere && state.anchorFingerprint == anchorG["fingerprint"] as? String && !state.foreignAnchor, "anchor bootstrap", "registered here, fingerprint shown")
        check(state.controlState?.epoch == 0 && state.controlState?.anchorSpkiSha256 == anchorG["spkiSha256"] as? String
              && WebKeyControlState.parse(FileManager.default.contents(atPath: dir.appendingPathComponent(WebKeyStateStore.fileName).path) ?? Data()) == state.controlState,
              "W5 state written", "Control's record exists once the anchor is registered")
        check(state.pinJSON().map { obj(Data($0.utf8))["spkiSha256"] as? String } == anchorG["spkiSha256"] as? String, "pin", "Copy pin names this anchor")
        // A server whose anchor is not ours.
        fake.answers["status"] = (200, ["ok": true, "enabled": true, "anchorRegistered": true, "anchorMature": true, "aud": String(repeating: "f", count: 64), "origin": origin, "epoch": 0])
        await state.refresh()
        check(!state.anchorRegisteredHere && state.foreignAnchor && state.card == nil, "foreign anchor", "the server's anchor is not this Mac's: no card")
        fake.answers["status"] = (200, ["ok": true, "enabled": true, "anchorRegistered": true, "anchorMature": true, "aud": aud, "origin": origin, "epoch": 0])
        // A pending request, the audit not genuine: no card.
        fake.answers["pending"] = (200, ["ok": true, "pending": pending])
        fake.listeners = ["servicePID": 4242, "ports": ["3141": [["pid": 4243, "underService": true]], "3143": [["pid": 4243, "underService": true]], "3144": [["pid": 66, "underService": false]]]]
        fake.listeners = audited(fake.listeners)
        // Registration's genuine audit is still fresh at this fixed clock. Observe the new listener before testing
        // the negative-audit card gate; changing the adapter alone does not invalidate the 60-second cached proof.
        let listenerCallsBeforeForeignAudit = fake.count("listeners")
        await state.runAudit()
        check(fake.count("listeners") == listenerCallsBeforeForeignAudit + 1
              && state.audit?.genuine == false && state.audit?.reason == "port_3144_foreign_listener",
              "W9 observed foreign listener", "an explicit audit observes the changed listener and fails closed")
        await state.refresh()
        check(state.pendingWithoutAudit && state.card == nil && state.cardRefusal == nil, "W9 no card without the audit", "a foreign listener on 3144")
        // The audit passes: the card, from the bytes.
        fake.listeners = ["servicePID": 4242, "ports": ["3141": [["pid": 4243, "underService": true]], "3143": [["pid": 4243, "underService": true]], "3144": [["pid": 4243, "underService": true]]]]
        fake.listeners = audited(fake.listeners)
        await state.runAudit()
        await state.refresh()
        guard let card = state.card else { check(false, "card shown", "no card"); return }
        check(!state.pendingWithoutAudit && card.approvalBytes == WebKeyB64.decode(pending["approvalJcs"] as! String), "card shown", "from approvalJcs")
        // An in-flight authoritative read cannot certify the old cached card.
        state.typedCode = card.sas
        fake.pauseOp = "status"
        let reading = Task { await state.refresh() }
        for _ in 0..<10000 { if fake.paused { break }; await Task.yield() }
        check(fake.paused && !state.approveAllowed, "protected persistence gate", "fresh read in flight invalidates the retained card until its state agrees")
        fake.release()
        await reading.value
        state.typedCode = ""
        // The protected state must remain usable, not merely present in memory.
        let keptMirror = mem.items[WebKeyStateStore.mirrorAccount]!
        mem.failRead = true
        await state.refresh()
        state.typedCode = card.sas
        await state.approve()
        check(!state.protectionReady && !state.approveAllowed && state.card == nil && fake.count("approve") == 0,
              "protected persistence gate", "an unreadable keychain cannot leave an old card actionable")
        mem.failRead = false
        mem.items[WebKeyStateStore.mirrorAccount] = nil
        let keysBeforeMissing = fake.count("keys")
        await state.refresh()
        check(!state.protectionReady && state.card == nil && fake.count("keys") == keysBeforeMissing,
              "protected mirror missing", "a lone file is never rebuilt from a server snapshot")
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(WebKeyStateStore.fileName))
        await state.refresh()
        check(!state.protectionReady && state.card == nil && mem.items[WebKeyStateStore.mirrorAccount] == nil,
              "protected mirror missing", "deleting both records after registration never starts a new bootstrap")
        mem.items[WebKeyStateStore.mirrorAccount] = keptMirror
        let blocked = dir.appendingPathComponent("blocked")
        try? Data("not a directory".utf8).write(to: blocked)
        state.stateDirectory = blocked
        await state.refresh()
        check(!state.protectionReady && state.card == nil && mem.items[WebKeyStateStore.mirrorAccount] == keptMirror,
              "protected file failure", "failed rollback rewrite does not leave enrollment open")
        state.stateDirectory = dir
        mem.failWrite = true
        fake.answers["keys"] = (200, ["ok": true, "epoch": 1, "keys": [Any]()])
        await state.refresh()
        check(!state.protectionReady && state.card == nil && mem.items[WebKeyStateStore.mirrorAccount] == keptMirror,
              "protected persistence gate", "a failed save cannot publish the server's new epoch as protected")
        mem.failWrite = false
        fake.answers["keys"] = (200, ["ok": true, "epoch": 0, "keys": [Any]()])
        await state.refresh()
        check(state.protectionReady && state.card != nil, "protected persistence recovery", "the original intact record remains usable after transient failures")
        // Approve: never without the typed code, even called directly.
        reasons.list = []
        await state.approve()
        check(fake.count("approve") == 0 && reasons.list.isEmpty, "W6 approve needs the code", "approve() with no code signs and sends nothing")
        state.typedCode = "000000" == card.sas ? "111111" : "000000"
        await state.approve()
        check(fake.count("approve") == 0 && reasons.list.isEmpty, "W6 approve needs the code", "a wrong code signs and sends nothing")
        // A stale audit is run again inside approve(); a foreign listener now stops it.
        state.typedCode = card.sas
        clock = clock.addingTimeInterval(61)
        fake.listeners = ["servicePID": 4242, "ports": ["3141": [["pid": 4243, "underService": true]], "3143": [["pid": 4243, "underService": true]], "3144": [["pid": 4243, "underService": true], ["pid": 77, "underService": false]]]]
        fake.listeners = audited(fake.listeners)
        await state.approve()
        check(fake.count("approve") == 0 && reasons.list.isEmpty, "W9 approve needs a fresh audit", "approve() audits again and refuses")
        fake.listeners = ["servicePID": 4242, "ports": ["3141": [["pid": 4243, "underService": true]], "3143": [["pid": 4243, "underService": true]], "3144": [["pid": 4243, "underService": true]]]]
        fake.listeners = audited(fake.listeners)
        // A completed signature cannot outlive the Settings context that requested it.
        reasons.onSign = { state.cancelActions() }
        await state.approve()
        check(fake.count("approve") == 0 && !state.protectionReady, "cancelled approval cannot post", "closing Settings during the biometric await invalidates the exact request")
        reasons.onSign = nil
        await state.refresh()
        state.typedCode = card.sas
        // Touch ID refused: nothing sent.
        reasons.refuse = true
        await state.approve()
        check(fake.count("approve") == 0, "approve needs Touch ID", "a cancelled sheet sends nothing")
        reasons.refuse = false
        var sentSig: Data?
        fake.onCall = { op, body in
            guard op == "approve" else { return }
            sentSig = WebKeyB64.decode(body["anchorSig"] as? String ?? "")
            fake.answers["approve"] = body["enrollId"] as? String == card.enrollId ? (200, ["ok": true, "kid": card.kid]) : (404, ["ok": false])
            fake.answers["pending"] = (200, ["ok": true, "pending": NSNull()])
        }
        await state.approve()
        check(fake.count("approve") == 1 && sentSig.map { verifies(anchorDER, card.approvalBytes, $0) } == true, "approve signs the bytes", "one post, the anchor's signature over approvalJcs")
        check(reasons.list.last == WebKeyProtocol.approveReason(fingerprint: card.fingerprint, sas: card.sas), "touch id reason", "the fingerprint and code in the sheet")
        check(state.card == nil && state.typedCode.isEmpty, "approve signs the bytes", "the card closes")
        // Revoke the server does not confirm: Control records it and stays closed; the next refresh revokes again.
        fake.onCall = nil
        fake.answers["keys"] = (200, ["ok": true, "epoch": 0, "keys": [["kid": card.kid, "label": card.label, "fingerprint": card.fingerprint, "active": true, "state": "active"]]])
        await state.refresh()
        check(state.keys.count == 1 && state.keys.first?.active == true, "keys list")
        fake.answers["revoke"] = (500, ["ok": false])
        fake.calls = []
        var revokedBeforeHTTP = false
        fake.onCall = { op, _ in
            if op == "revoke" { revokedBeforeHTTP = mem.items[WebKeyStateStore.mirrorAccount].flatMap(WebKeyControlState.parse)?.revokedKids.contains(card.kid) == true }
        }
        await state.revoke(card.kid)
        check(revokedBeforeHTTP, "revocation intent before HTTP", "protected intent exists before any server response")
        fake.onCall = nil
        check(state.controlState?.revokedKids.contains(card.kid) == true && fake.count("revoke") >= 2, "W5 revoke fails closed", "recorded in Control, revoked again on refresh")
        // The server confirms on the next try: its time is taken.
        fake.answers["revoke"] = (200, ["ok": true])
        fake.answers["keys"] = (200, ["ok": true, "epoch": 0, "keys": [["kid": card.kid, "label": card.label, "fingerprint": card.fingerprint, "active": false, "state": "key_revoked", "revokedAt": 1_786_000_009_000]]])
        await state.refresh()
        check(state.controlState?.revoked == [WebKeyRevocation(kid: card.kid, revokedAt: 1_786_000_009_000)], "W5 repair", "the server's revokedAt, so the digests agree")
        // A server rollback: the revocation vanished from web-keys.json and the key reads active again.
        fake.answers["keys"] = (200, ["ok": true, "epoch": 0, "keys": [["kid": card.kid, "label": card.label, "fingerprint": card.fingerprint, "active": true, "state": "active"]]])
        fake.answers["revoke"] = (404, ["ok": false, "error": "key_unknown"])
        fake.calls = []
        await state.refresh()
        check(state.controlState?.revokedKids.contains(card.kid) == true && state.rollbackNote?.contains("could not be repaired") == true,
              "W5 server rollback", "Control keeps the revocation and says approvals stay off")
        check(!state.protectionReady && state.card == nil && !state.approveAllowed,
              "unrepaired rollback blocks enrollment", "keeping the old record alone never authorizes a new phone")
        // Revoke all the server does not confirm: Control's epoch moves first.
        fake.answers["revoke-all"] = (500, ["ok": false])
        fake.answers["keys"] = (200, ["ok": true, "epoch": 0, "keys": [["kid": card.kid, "label": card.label, "fingerprint": card.fingerprint, "active": false, "state": "key_revoked", "revokedAt": 1_786_000_009_000]]])
        var epochBeforeHTTP: Int64?
        fake.onCall = { op, _ in
            if op == "revoke-all" { epochBeforeHTTP = mem.items[WebKeyStateStore.mirrorAccount].flatMap(WebKeyControlState.parse)?.epoch }
        }
        let revokedAllConfirmed = await state.revokeAll()
        check(epochBeforeHTTP == 1, "epoch intent before HTTP", "the protected epoch advances before the first revoke-all POST")
        check(!revokedAllConfirmed, "phone off failed revoke is not stopped", "Revoke all reports false when the server does not answer 200")
        fake.onCall = nil
        check(state.controlState?.epoch == 1, "W5 revoke all fails closed", "Control's epoch is ahead of the server's")
        // A rolled-back state FILE is rewritten from the keychain on the next refresh.
        let fileURL = dir.appendingPathComponent(WebKeyStateStore.fileName)
        let kept = state.controlState!
        try? WebKeyControlState(epoch: 0, revoked: [], anchorSpkiSha256: kept.anchorSpkiSha256, updatedAt: 1).fileData().write(to: fileURL)
        let fresh = make()
        fake.answers["revoke-all"] = (500, ["ok": false])
        await fresh.refresh()
        check(fresh.controlState?.epoch == 1 && fresh.controlState?.revokedKids.contains(card.kid) == true
              && WebKeyControlState.parse(FileManager.default.contents(atPath: fileURL.path) ?? Data())?.sameRecord(as: kept) == true,
              "W5 rewritten from keychain", "a rolled-back file is rewritten from the keychain")
        // Security review 2026-11-12, blocker 2: a store that cannot save never stops the server call, and nothing claims off.
        mem.failWrite = true
        fake.calls = []
        fake.answers["revoke-all"] = (500, ["ok": false])
        let noSaveNoServer = await state.revokeAll()
        // At least once: the refresh after it sends revoke-all again when Control's epoch is ahead (W5). A revoke-all that
        // skipped the server (RV-2) never reaches its refresh either, so it sends none.
        check(fake.count("revoke-all") >= 1, "revoke all reaches the server", "a failing store still sends revoke-all")
        check(!noSaveNoServer && state.message?.contains("stay off") == false && state.message?.contains("may still approve") == true,
              "revoke says what failed", "neither saved nor confirmed: the message says a phone may still approve")
        fake.answers["revoke-all"] = (200, ["ok": true])
        let serverOnly = await state.revokeAll()
        check(serverOnly && state.message == "The server revoked it. Control could not record the revocation.",
              "revoke says what failed", "confirmed by the server, not saved by Control: says both")
        fake.calls = []
        fake.answers["revoke"] = (500, ["ok": false])
        let revokedOne = await state.revoke(card.kid)
        check(fake.count("revoke") == 1, "revoke reaches the server", "a failing store still sends revoke")
        check(!revokedOne && state.message?.contains("may still approve") == true, "revoke says what failed", "a revoke nobody recorded says so")
        mem.failWrite = false
        fake.answers["revoke"] = (200, ["ok": true])
        fake.answers["revoke-all"] = (500, ["ok": false])
        check(WebKeyRevokeOutcome.message(serverConfirmed: true, localSaved: true, localProblem: nil) == nil
              && WebKeyRevokeOutcome.message(serverConfirmed: false, localSaved: true, localProblem: nil)?.contains("stay off") == true
              && WebKeyRevokeOutcome.message(serverConfirmed: false, localSaved: false, localProblem: WebKeyRevokeOutcome.noAnchor)?.hasPrefix(WebKeyRevokeOutcome.noAnchor) == true,
              "revoke says what failed", "off is claimed only when the server confirmed or Control saved; the no-anchor case names itself")
        try? FileManager.default.removeItem(at: dir)
    }
}
