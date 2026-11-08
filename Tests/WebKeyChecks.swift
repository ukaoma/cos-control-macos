import CryptoKit
import Foundation

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
        await cancellation()
        await flow(pending: pending, anchorG: anchorG, anchorDER: anchorDER, anchorRaw: anchorRaw, selfDns: selfDns)
        await recoveryFlow(anchorRaw: anchorRaw, selfDns: selfDns)

        print("web key checks: \(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func encodings(_ g: [String: Any], anchorG: [String: Any], anchorDER: Data, selfDns: String) {
        for case let row as [String: Any] in g["jcs"] as! [Any] {
            check(WebKeyJCS.encode(row["value"]!) == row["text"] as? String, "jcs", "\(WebKeyJCS.encode(row["value"]!) ?? "nil") vs \(row["text"]!)")
        }
        check(WebKeyJCS.encode(NSNumber(value: 1.5)) == nil && WebKeyJCS.encode(NSNumber(value: 9_007_199_254_740_992 as Int64)) == nil, "jcs", "floats and unsafe integers are not signable")
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
        check(WebKeyHelperCore.ops == ["status", "pending", "keys", "anchor", "approve", "revoke", "revoke-all", "listeners"], "helper ops")
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
        await state.revokeAll()
        check(epochBeforeHTTP == 1, "epoch intent before HTTP", "the protected epoch advances before the first revoke-all POST")
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
        try? FileManager.default.removeItem(at: dir)
    }
}
