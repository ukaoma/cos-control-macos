#!/usr/bin/env python3
"""Phone approvals (server 6.99.31): the mutation pass. Serial, one compile per mutant through Tests/compile-guard.sh (the
lane compiles Sources/WebKeyCore.swift, HelperSources/PairingCore.swift and the checks only), never run by Tests/run.sh.

Usage: mutate-web-key.py [<repo root>]. The unmutated lane must be green first and the run stops on a red one. Each mutant
must be applied exactly once, must fail the lane, and is attributed to the check or pin that names the behaviour
("check failed [<behaviour>]" or "web key pin FAILED [<behaviour>]"). Sources are restored after each, and the run says so.
MUTATE_ONLY="a|b" runs only the mutants whose names contain one of the parts (the baseline still runs first).
"""
import os, pathlib, subprocess, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1])
env = dict(os.environ)
LANE = "zsh Tests/run-web-key.sh"
C, V, P = "Sources/WebKeyCore.swift", "Sources/WebKeyViews.swift", "HelperSources/PairingCore.swift"
H, T = "HelperSources/main.swift", "Tests/WebKeyChecks.swift"
G = "Tests/fixtures/web-key/golden.json"
K = "Sources/SettingsHubCatalog.swift"
R = "Tests/fixtures/web-key/tls/README.md"
MV = "Sources/Views.swift"
RN = "Tests/PhoneApprovalsRender.swift"


def sh(cmd):
    r = subprocess.run(cmd, cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, shell=True)
    return r.returncode, r.stdout


mutants = [
    # Review W4: the card, from the bytes only.
    ("W4-1 extra display fields shown", C, "        guard Set(pending.keys).isSubset(of: WebKeyProtocol.pendingKeys) else { return .failure(.extraDisplayFields) }\n", "",
     "[W4 extra display fields]"),
    ("W4-2 the server's copy is not compared", C, "guard let object = copy as? [String: Any], WebKeyJCS.bytes(object) == bytes else", "guard copy is [String: Any] else",
     "[W4 approval copy]"),
    ("W4-3 the SAS is not recomputed", C, "sas == WebKeyProtocol.sas(challenge: challenge, spki: spki, phoneNonce: nonce) else", "true else", "[W4 sas from bytes]"),
    ("W4-4 the fingerprint is not recomputed", C, 'guard approval["spki_sha256"] as? String == WebKeyHash.sha256Hex(spki),\n              approval["fingerprint"] as? String == WebKeySPKI.fingerprint(spki) else',
     "guard true else", "[W4 fingerprint from bytes]"),
    ("W4-5 the kid is not recomputed", C, 'guard let kid = approval["kid"] as? String, kid == WebKeySPKI.kid(spki) else', 'guard let kid = approval["kid"] as? String else', "[W4 kid from bytes]"),
    ("W4-6 the commitment is not checked", C, 'guard approval["sasCommit"] as? String == WebKeyHash.sha256Hex(nonce) else { return .failure(.commitMismatch) }\n', "", "[W4 commit]"),
    ("W4-7 non-canonical bytes accepted", C, "        guard WebKeyJCS.bytes(approval) == bytes else { return .failure(.approvalNotCanonical) }\n", "", "[W4 canonical bytes]"),
    ("W4-8 aud not checked", C, 'guard approval["aud"] as? String == WebKeyProtocol.aud(anchorDER: anchorDER, rpId: host) else { return .failure(.audMismatch) }\n', "", "[card aud]"),
    ("W4-9 any port signs", C, "guard origin.hasPrefix(prefix), origin.hasSuffix(suffix) else { return nil }", "guard origin.hasPrefix(prefix) else { return nil }", "[origin]"),
    ("W4-10 exact approval keys not required", C, "guard Set(approval.keys) == WebKeyProtocol.approvalKeys else", "guard Set(approval.keys).isSuperset(of: WebKeyProtocol.approvalKeys) else", "[W4 exact keys]"),
    ("W4-11 the card draws the code (pins)", V, '            WebKeyLine(label: "Key", value: card.fingerprint, mono: true)\n',
     '            WebKeyLine(label: "Key", value: card.fingerprint, mono: true)\n            WebKeyLine(label: "Code", value: card.sas)\n', "[W4 card never shows the code]"),
    ("W4-12 a second card builder (pins)", C, "    var approveAllowed: Bool {", "    func spoofCard() -> WebKeyApprovalCard { WebKeyApprovalCard(enrollId: \"\", kid: \"\", fingerprint: \"\", sas: \"\", label: \"\", userAgent: \"\", remote: \"\", rotates: nil, expiresAtMs: 0, approvalBytes: Data()) }\n    var approveAllowed: Bool {",
     "[W4 one builder]"),
    ("W5-1 the epoch is not compared", C, "        if let controlEpoch { guard epoch == controlEpoch else { return .failure(.epochMismatch) } }\n", "", "[W5 epoch]"),
    ("C-1 expired requests accepted", C, "        guard nowMs <= exp else { return .failure(.expired) }\n", "", "[card expiry]"),
    # Review W6: the typed code.
    ("W6-1 any code matches", C, "        return diff == 0\n", "        return true\n", "[W6 typed code]"),
    ("W6-2 the gate skips the code", C, "        return WebKeyCodeEntry.matches(typed: typed, card: card)\n", "        return true\n", "[W6 approve needs the code]"),
    ("W6-3 approve() trusts the button", C, "        guard current(expectedRead), approveAllowed, let card, let anchor else", "        guard current(expectedRead), let card, let anchor else", "[W6 approve needs the code]"),
    ("W6-4 approve() does not audit again (pins)", C, "        if !(audit?.fresh(now: now()) ?? false) { await runAudit() }\n        guard current(expectedRead), approveAllowed", "        guard current(expectedRead), approveAllowed", "[cancelled approval cannot post]"),
    ("W6-5 the button ignores the gate (pins)", V, ".disabled(!state.approveAllowed || state.busy)", ".disabled(state.busy)", "[W6 approve rechecks]"),
    # Review W9: the listener audit.
    ("W9-1 the gate skips freshness", C, "        guard anchor, let card, let audit, audit.fresh(now: now) else { return false }", "        guard anchor, let card, audit != nil else { return false }", "[W9 approve needs a fresh audit]"),
    ("W9-2 a card without the audit", C, "        guard current(id), protectionReady, audit?.fresh(now: now()) == true else {", "        guard current(id), protectionReady else {", "[W9 no card without the audit]"),
    ("W9-3 split listeners pass", C, '        guard owners.count == 1 else { return refuse("listeners_split") }\n', "", "[W9 listener audit]"),
    ("W9-4 a foreign listener passes", C, 'object["underService"] as? Bool == true else { return refuse("port_\\(port)_foreign_listener") }', 'true else { return refuse("port_\\(port)_foreign_listener") }', "[W9 listener audit]"),
    ("W9-5 3144 not audited", C, "    static let ports = [3141, 3143, 3144]\n", "    static let ports = [3141, 3143]\n", "[W9 listener audit]"),
    ("W9-6 an old audit is fresh", C, "        return age <= Self.maxAge && age >= -5\n", "        return true\n", "[W9 audit freshness]"),
    ("W9-7 the helper skips 3144", P, "    static let auditPorts = [3141, 3143, 3144]\n", "    static let auditPorts = [3141, 3143]\n", "[W9 helper answer]"),
    # Review W5: Control's record.
    ("W5-2 a rolled-back file is kept", C, "            if let fileState, fileState.sameRecord(as: mirror), !isSymlink() { return .ok(mirror) }\n", "            if fileState != nil { return .ok(mirror) }\n", "[W5 rollback caught]"),
    ("W5-3 a lone file is trusted", C, "            if FileManager.default.fileExists(atPath: fileURL.path) { return .mirrorMissing(fileState) }\n", "            if let fileState { return .ok(fileState) }\n", "[W5 keychain missing]"),
    ("W5-4 the file before the keychain", C, "        guard WebKeyControlState.parse(state.fileData()) == state, secure.write(Self.mirrorAccount, state.fileData()) else { return false }\n        return writeFile(state)\n",
     "        let wrote = writeFile(state)\n        guard WebKeyControlState.parse(state.fileData()) == state, secure.write(Self.mirrorAccount, state.fileData()) else { return false }\n        return wrote\n", "[W5 keychain first]"),
    ("W5-5 class B (pins)", C, "[.atomic, .completeFileProtectionUntilFirstUserAuthentication]", "[.atomic, .completeFileProtectionUnlessOpen]", "[W5 class C]"),
    ("W5-6 a missing revocation is not caught", C, "        if server.epoch < control.epoch || !missing.isEmpty {\n", "        if server.epoch < control.epoch {\n", "[W5 server rollback]"),
    ("W5-7 a removed entry dropped at the same epoch", C, "            guard stillMissing.isSubset(of: unknown), server.epoch > control.epoch else { return nil }\n", "            guard stillMissing.isSubset(of: unknown) else { return nil }\n", "[W5 repair]"),
    ("W5-8 Control keeps its own revokedAt", C, "        let next = WebKeyControlState(epoch: server.epoch, revoked: server.revoked, anchorSpkiSha256: anchorSpkiSha256, updatedAt: control.updatedAt)\n",
     "        let next = WebKeyControlState(epoch: server.epoch, revoked: control.revoked, anchorSpkiSha256: anchorSpkiSha256, updatedAt: control.updatedAt)\n", "[W5 reconcile]"),
    ("W5-9 an unconfirmed revoke fails open", C,
     '        guard store.save(s) else { message = "Control could not record the revocation. Phone approvals stay off."; return }\n        controlState = s\n        let answer = await ask("revoke",',
     '        controlState = s\n        let answer = await ask("revoke",', "[revocation intent before HTTP]"),
    ("W5-10 an unconfirmed revoke-all fails open", C,
     '        guard store.save(s) else { message = "Control could not record the revocation. Phone approvals stay off."; return false }\n        controlState = s\n        let answer = await ask("revoke-all",',
     '        controlState = s\n        let answer = await ask("revoke-all",', "[epoch intent before HTTP]"),
    ("W5-11 the state file is not strict", C, '              Set(object.keys) == ["v", "epoch", "revoked", "anchorSpkiSha256", "updatedAt"] else { return nil }', '              object["v"] != nil else { return nil }', "[W5 state file]"),
    # Hidden unless the flag; the bootstrap.
    ("F-1 shown when the flag is off", C, 'case false?: return mode as? String == "bootstrap" ? .bootstrap : .off', "case false?: return .bootstrap", "[hidden unless the flag]"),
    ("B1-1 the statement's time is wrong", C, '"createdAt": NSNumber(value: createdAtMs),', '"createdAt": NSNumber(value: createdAtMs + 1),', "[anchor statement]"),
    ("B1-2 the anchor without current biometry (pins)", C, "[.privateKeyUsage, .biometryCurrentSet]", "[.privateKeyUsage]", "[B1 anchor key]"),
    ("B1-3 the blob not kept", C, "guard secure.write(SecureEnclaveWebKeyAnchor.blobAccount, newBlob) else {", "guard !newBlob.isEmpty else {", "[anchor bootstrap]"),
    ("H-1 the helper takes extra keys", P, "              Set(object.keys) == keys else { return nil }", "              Set(object.keys).isSuperset(of: keys) else { return nil }", "[helper body]"),
    ("J-1 JCS escapes \\b as \\u0008", C, '            case "\\u{08}": out += "\\\\b"\n', "", "[jcs]"),
    ("J-2 JCS signs floats", C, '            guard ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(type) else { return nil }\n            let int = number.int64Value\n            guard int >= -maxSafe',
     "            let int = number.int64Value\n            guard int >= -maxSafe", "[jcs]"),
    ("B64-1 lenient base64url", C, "        guard let data = Data(base64Encoded: base), encode(data) == text else { return nil }", "        guard let data = Data(base64Encoded: base) else { return nil }", "[b64]"),
    ("P-1 persistence readiness omitted", C,
     'visible && anchorRegisteredHere && protectionReady && controlState != nil &&',
     'visible && anchorRegisteredHere && controlState != nil &&', "[protected persistence gate]"),
    ("P-2 failed mirror save adopted", C,
     'if next != saved, !store.save(next) {', 'if false {', "[W5 state written]"),
    ("A-1 listener ownership without asset proof", C,
     '        guard let assets = details["assets"] as? [String: Any] else { return refuse("signer_assets_unverified") }',
     '        let assets = details["assets"] as? [String: Any] ?? ["verified": true, "webControlManifestSha256": String(repeating: "a", count: 64), "webSignerManifestSha256": String(repeating: "b", count: 64)]', "[immutable asset gate]"),
    ("A-2 manifest bytes do not match immutable pin", P,
     'guard data.count <= 256 * 1024, hash(data) == sha,', 'guard data.count <= 256 * 1024,', "[immutable manifest]"),
    ("A-3 served bytes do not match pinned asset", P,
     'bytes.count <= maximumFileBytes && hash(bytes) == sha', 'bytes.count <= maximumFileBytes', "[served asset hashes]"),

    ("R-1 absent protected records silently reseeded", C,
     '            guard registeredAnchorNeedsStateRebind else { controlState = nil; recoveryRequired = true; message = "Control\'s protected phone record is missing. Reset phone approvals to enroll again."; return false }\n',
     '', "[protected mirror missing]"),
    ("R-2 reset reuses the old anchor", C,
     '        if recovery, candidate.publicKeyDER == anchor?.publicKeyDER { message = "Reset requires a new Mac key. Nothing was changed."; return }\n',
     '', "[reset requires distinct anchor]"),
    ("R-3 unreadable Keychain reset", C,
     '            case .failed: message = "Control could not read its existing Touch ID key."; return',
     '            case .failed: break', "[locked mirror cannot reset]"),
    ("C-2 disappearing Settings does not cancel", C,
     '    func cancelActions() {\n        actionTask?.cancel(); actionTask = nil\n        readID = nil; card = nil; typedCode = ""; protectionReady = false; audit = nil\n    }',
     '    func cancelActions() {}', "[cancelled approval cannot post]"),
 
    # 0.5.383 bootstrap (server 7.0.9, COS_WEB_KEY_ANCHOR_BOOTSTRAP): the Mac anchor alone.
    ("BS-1 enrollment drawn in bootstrap (pins)", V, "if state.authority && state.anchorRegisteredHere {", "if state.anchorRegisteredHere {", "[bootstrap shows the anchor only]"),
    ("BS-2 bootstrap reads the key list and pending", C, "        if served == .bootstrap {\n", "        if served == .off {\n", "[bootstrap hides enrollment and approval]"),
    ("BS-3 approval ignores the mode (pins)", C, "mode == .authority && visible && anchorRegisteredHere", "visible && anchorRegisteredHere", "[bootstrap hides enrollment and approval]"),
    ("BS-4 revoke in bootstrap", C, "        guard mode == .authority, visible, !busy, let anchor,\n", "        guard visible, !busy, let anchor,\n", "[bootstrap hides enrollment and approval]"),
    ("BS-5 revoke all in bootstrap", C, "        guard mode == .authority, visible, !busy, let anchor else { return false }", "        guard visible, !busy, let anchor else { return false }", "[bootstrap hides enrollment and approval]"),
    ("BS-6 an anchor audit passes the signer gate", C, "        scope == .signer && genuine && young(now: now)\n", "        genuine && young(now: now)\n", "[bootstrap anchor audit never approves]"),
    ("BS-7 bootstrap runs the signer audit", C, "mode == .bootstrap ? .anchor : .signer", ".signer", "[bootstrap anchor audit]"),
    ("BS-8 anchor audit takes a foreign listener", C, '(object["underService"] as? Bool) == true else', "true else", "[bootstrap anchor audit]"),
    ("BS-9 anchor audit ignores a changed listener", C, '        guard details["stable"] as? Bool == true else { return refuse("listener_changed") }\n', "", "[bootstrap anchor audit]"),
    ("BS-10 helper anchor audit reaches 3144", P, "    static let anchorAuditPorts = [3141, 3143]\n", "    static let anchorAuditPorts = [3141, 3143, 3144]\n", "[bootstrap helper audit]"),
    ("BS-11 no protected record after bootstrap registration", C, "            if let anchor, anchorRegisteredHere { bindBootstrapRecord(", "            if let anchor, anchorRegisteredHere, anchor.publicKeyDER.isEmpty { bindBootstrapRecord(", "[bootstrap starts the protected record]"),
    ("BS-12 record seeded without this run's registration (pins)", C, "        guard registeredAnchorNeedsStateRebind else { return }\n        let sha", "        let sha", "[bootstrap starts the protected record]"),
    ("BS-13 a contradiction reads as authority", C, 'case true?: return mode == nil || mode as? String == "authority" ? .authority : .off', "case true?: return .authority", "[bootstrap mode reader]"),
    ("BS-14 setAt from the registration answer dropped", C, '        if let at = WebKeyServerMode.int(answer.body["setAt"]) { anchorSetAt = at }\n', "", "[bootstrap shows setAt]"),
    ("BS-15 the pin note says Control commits (pins)", V, "Control never writes or commits it.", "Control commits it for you.", "[bootstrap pin by hand]"),
    ("BS-16 reset offered in bootstrap (pins)", C, "        guard registering != .off, !recovery || registering == .authority else { return }\n", "        guard registering != .off else { return }\n", "[bootstrap hides enrollment and approval]"),
    ("BS-17 no full key hash (pins)", V, "WebKeyLine(label: WebKeyCopy.keyHash, value: sha, mono: true, lines: 3)", "EmptyView()", "[bootstrap shows the anchor only]"),
    ("BS-18 bootstrap seed takes the server's epoch away", C, "        let seed = WebKeyControlState(epoch: statusEpoch ?? 0,", "        let seed = WebKeyControlState(epoch: 0,", "[bootstrap starts the protected record]"),
    # The server resets setAt on a same-key registration: never register twice.
    ("RR-1 Register runs over a registered anchor", C, "        guard recovery || replace || (!anchorRegisteredHere && !foreignAnchor) else {", "        guard true else {", "[never registers twice]"),
    ("RR-2 no fresh status before registering", C, '                  fresh.body["anchorRegistered"] as? Bool == false else {', "                  true else {", "[never registers twice]"),
    ("RR-3 replace without confirmation (pins)", V, "Button(WebKeyCopy.replace) { confirmReplace = true }", "Button(WebKeyCopy.replace) { state.startReplace() }", "[confirmed replace]"),
    # 0.5.390 (QA 2026-11-09 open question 2): the signer audit's TLS trust (SignerTLSCore, webKeyAssetAudit). One per guard.
    ("TLS-1 the ts.net host gets the managed cert", P, "        if isTSNetHost(host) { return .systemRoots }", "        if isTSNetHost(host) { return .managedCert }", "[audit trust split]"),
    ("TLS-2 localhost is judged by the system roots", P, 'if host == "localhost" || TailscaleCore.isIPv4(host) || isIPv6Literal(host) { return .managedCert }',
     'if host == "localhost" || TailscaleCore.isIPv4(host) || isIPv6Literal(host) { return .systemRoots }', "[audit trust split]"),
    ("TLS-3 a one-label ts.net name passes", P, r'static let tsNetPattern = #"\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+\.ts\.net\z"#',
     r'static let tsNetPattern = #"\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\.ts\.net\z"#', "[audit trust split]"),
    ("TLS-4 an IPv6 literal is not recognised", P, 'return bare.contains(":") && inet_pton(AF_INET6, bare, &address) == 1', "return false", "[audit trust split]"),
    ("TLS-5 the ts.net fetch passes the managed CA", P, 'case .systemRoots: return ["--write-out", "%{http_code}\\n%{num_certs}\\n%{certs}"]',
     'case .systemRoots: return ["--cacert", managedCert, "--write-out", "%{http_code}\\n%{num_certs}\\n%{certs}"]', "[audit curl trust args]"),
    ("TLS-6 the received chain is not written out", P, 'case .systemRoots: return ["--write-out", "%{http_code}\\n%{num_certs}\\n%{certs}"]',
     'case .systemRoots: return ["--write-out", "%{http_code}\\n%{num_certs}"]', "[audit curl trust args]"),
    ("TLS-7 the status is read from the last line", P, 'let code = lines.first.map(String.init) ?? ""', 'let code = lines.last.map(String.init) ?? ""',
     "[audit curl answer]"),
    ("TLS-8 a block that is not base64 is half read", P, "guard let der = Data(base64Encoded: body), !der.isEmpty else { return nil }",
     "guard let der = Optional(Data(base64Encoded: body) ?? Data(body.utf8)), !der.isEmpty else { return nil }", "[audit curl answer]"),
    ("TLS-9 the admin domain's roots", P, "SecTrustSettingsCopyCertificates(.system, &list)", "SecTrustSettingsCopyCertificates(.admin, &list)", "[audit system roots]"),
    ("TLS-10 no host name in the SSL policy", P, "SecPolicyCreateSSL(true, host as CFString)", "SecPolicyCreateSSL(true, nil)", "[audit hostname]"),
    ("TLS-11 the keychain's trust counts too", P, "SecTrustSetAnchorCertificatesOnly(trust, true)", "SecTrustSetAnchorCertificatesOnly(trust, false)", "[audit anchors only]"),
    ("TLS-12 the date is ignored", P, 'SecTrustSetVerifyDate(trust, date as CFDate) == errSecSuccess else { return (false, "setup") }',
     'true else { return (false, "setup") }', "[audit expiry]"),
    ("TLS-13 the anchors are never set", P, "        guard SecTrustSetAnchorCertificates(trust, anchors as CFArray) == errSecSuccess,\n              SecTrustSetAnchorCertificatesOnly",
     "        guard SecTrustSetAnchorCertificatesOnly", "[audit evaluator]"),
    ("TLS-14 more than 8 certificates", P, 'guard !chain.isEmpty, chain.count <= 8, !anchors.isEmpty, !host.isEmpty else { return (false, "input") }',
     'guard !chain.isEmpty, !anchors.isEmpty, !host.isEmpty else { return (false, "input") }', "[audit chain bounds]"),
    # 14:27 (Q1 and the lead): each empty input on an otherwise-valid input, with an EVIDENCE line saying who refused.
    ("TLS-15 an empty host name", P, 'guard !chain.isEmpty, chain.count <= 8, !anchors.isEmpty, !host.isEmpty else { return (false, "input") }',
     'guard !chain.isEmpty, chain.count <= 8, !anchors.isEmpty else { return (false, "input") }', "[audit empty host]"),
    ("TLS-16 no anchors at all", P, 'guard !chain.isEmpty, chain.count <= 8, !anchors.isEmpty, !host.isEmpty else { return (false, "input") }',
     'guard !chain.isEmpty, chain.count <= 8, !host.isEmpty else { return (false, "input") }', "[audit empty anchors]"),
    ("TLS-17 an empty chain", P, 'guard !chain.isEmpty, chain.count <= 8, !anchors.isEmpty, !host.isEmpty else { return (false, "input") }',
     'guard chain.count <= 8, !anchors.isEmpty, !host.isEmpty else { return (false, "input") }', "[audit empty chain]"),
    ("TLS-18 network fetch allowed (pins)", P, "SecTrustSetNetworkFetchAllowed(trust, false)", "SecTrustSetNetworkFetchAllowed(trust, true)", "[audit evaluator wiring]"),
    ("TLS-19 the audit skips the chain check (pins)", H,
     '            guard SignerTLSCore.trusted(chain: answer.chain, host: host, at: Date(), anchors: anchors) else { return refused("signer_tls") }\n', "",
     "[audit judges each chain]"),
    ("TLS-20 the bytes count before the chain is judged (pins)", H,
     '            guard SignerTLSCore.trusted(chain: answer.chain, host: host, at: Date(), anchors: anchors) else { return refused("signer_tls") }\n'
     '            guard let served = safeBytes(output, limit: WebKeyAssetsCore.maximumFileBytes), WebKeyAssetsCore.verified(served, sha: sha) else { return refused("served_signer_assets") }\n',
     '            guard let served = safeBytes(output, limit: WebKeyAssetsCore.maximumFileBytes), WebKeyAssetsCore.verified(served, sha: sha) else { return refused("served_signer_assets") }\n'
     '            guard SignerTLSCore.trusted(chain: answer.chain, host: host, at: Date(), anchors: anchors) else { return refused("signer_tls") }\n',
     "[audit judges each chain]"),
    ("TLS-21 the audit judges with no roots (pins)", H, "        let anchors = SignerTLSCore.systemRoots()\n", "        let anchors: [SecCertificate] = []\n", "[audit judges each chain]"),
    ("TLS-22 the audit gate copies the host pattern (pins)", H, "let host = components.host, SignerTLSCore.trust(host: host) == .systemRoots,",
     'let host = components.host, host.hasSuffix(".ts.net"),', "[audit gate is the split]"),
    ("TLS-23 the audit passes the managed CA again (pins)", H, "arguments += SignerTLSCore.curlTrustArguments(.systemRoots, managedCert: managedCert.path)",
     'arguments += ["--cacert", managedCert.path, "--write-out", "%{http_code}"]', "[audit curl trust args wiring]"),
    # 0.5.390: the Phone approvals line from the server's signerTls.
    ("TLS-24 the line shows in bootstrap", C, "signerTLSLine = served == .authority ? WebKeySignerTLS.problem(body: status.body, now: now()) : nil",
     "signerTLSLine = WebKeySignerTLS.problem(body: status.body, now: now())", "[signer cert line]"),
    ("TLS-25 trusted for any host", C, 'if tls["trusted"] as? Bool == true, let host, tls["host"] as? String == host,', 'if tls["trusted"] as? Bool == true, host != nil || true,',
     "[signer cert line]"),
    ("TLS-26 notAfter ignored", C, 'let end = (tls["notAfter"] as? String).flatMap(date), end > now { return nil }', "true { return nil }", "[signer cert line]"),
    ("TLS-27 the toggle-off sentence is lost", C, '"tailnet_https_certs_off": certsOff,', '"tailnet_https_certs_off": fallback,', "[signer cert line]"),
    ("TLS-28 lastError read instead of reason", C, 'return line(tls["reason"] as? String)', 'return line(tls["lastError"] as? String)', "[signer cert line]"),
    ("TLS-29 milliseconds not parsed", C, "withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]", "withFraction.formatOptions = [.withInternetDateTime]",
     "[signer cert line]"),
    ("TLS-30 the view draws it without authority (pins)", V, "if state.authority, let line = state.signerTLSLine {", "if let line = state.signerTLSLine {", "[signer cert line wiring]"),
    ("TLS-31 not cleared (pins)", C, "        signerTLSLine = nil\n", "", "[signer cert line wiring]"),
    # The lead's 12:5x conditions: one reason list, and an unknown code falls back.
    ("TLS-32 a listed code is dropped", C,
     '        "tailscale_cli_gui_unavailable": "The COS server could not reach Tailscale on this Mac. Open the Tailscale app once; COS tries again later.",\n', "",
     "[signer cert line]"),
    ("TLS-33 the fallback shows the code", C, "reason.flatMap { sentences[$0] } ?? fallback", "reason.flatMap { sentences[$0] ?? $0 } ?? fallback", "[signer cert line]"),
    # Behaviour-preserving on purpose (the same sentence), so the checks stay green and only the pin can catch the copy.
    ("TLS-34 a second copy of a code (pins)", C, "static func line(_ reason: String?) -> String { reason.flatMap { sentences[$0] } ?? fallback }",
     'static func line(_ reason: String?) -> String { if reason == "cert_expired" { return sentences["cert_expired"] ?? fallback }; return reason.flatMap { sentences[$0] } ?? fallback }',
     "[signer reasons one list]"),
    ("TLS-35 the checks hand-copy the codes (pins)", T, "let reasons = Array(WebKeySignerTLS.sentences.keys)", 'let reasons = ["pending", "cert_invalid"]',
     "[signer reasons one list]"),
    # Reopen 2026-11-11: SR-02 (curl's own chain count) and SR-07 (curl's TLS exits).
    ("TLS-37 the PEM count is not compared", P, "guard lines.count >= 2, let declared = Int(lines[1]), declared > 0, declared == blocks.count else { return (code, []) }",
     "guard lines.count >= 2 else { return (code, []) }", "[audit refuses injected blocks]"),
    ("TLS-38 curl's count is not asked for", P, 'case .systemRoots: return ["--write-out", "%{http_code}\\n%{num_certs}\\n%{certs}"]',
     'case .systemRoots: return ["--write-out", "%{http_code}\\n%{certs}"]', "[audit curl trust args]"),
    ("TLS-39 exit 60 is a byte mismatch again", P, "static let tlsExitCodes: Set<Int32> = [35, 51, 58, 60]", "static let tlsExitCodes: Set<Int32> = [35, 51, 58]",
     "[audit curl tls exits]"),
    ("TLS-40 the audit names every curl failure served_signer_assets (pins)", H,
     "guard result.code == 0 else { return refused(SignerTLSCore.curlFailureReason(exit: result.code)) }",
     'guard result.code == 0 else { return refused("served_signer_assets") }', "[audit curl tls exits wiring]"),
    # SR-11: the server's reason list in golden.json must equal Control's sentences plus "ok".
    ("TLS-41 the server lists a code Control does not know", G, '    "cert_daily_cap",\n', "", "[signer reasons match the server]"),
    # Server reopen: signerTls.storedRefused, the hand-placed pair's refusal.
    ("TLS-42 the stored refusal shows in bootstrap", C, "signerTLSStoredLine = served == .authority ? WebKeySignerTLS.storedRefused(body: status.body, now: now()) : nil",
     "signerTLSStoredLine = WebKeySignerTLS.storedRefused(body: status.body, now: now())", "[signer stored refusal]"),
    ("TLS-43 the stored refusal repeats the main line", C, "return sentence == problem(body: body, now: now) ? nil : sentence", "return sentence",
     "[signer stored refusal]"),
    ("TLS-44 the storedRefused field is never read", C, 'let code = tls["storedRefused"] as? String, !code.isEmpty else { return nil }',
     'let code = tls["storedRefusal"] as? String, !code.isEmpty else { return nil }', "[signer stored refusal]"),
    ("TLS-45 the view draws it without authority (pins)", V, "if state.authority, let stored = state.signerTLSStoredLine {", "if let stored = state.signerTLSStoredLine {",
     "[signer stored refusal wiring]"),
    # SR-12: a real-looking tailnet name in a fixture the checks never read, so only the pin can see it. The name is made up.
    ("TLS-46 a tailnet name in a fixture (pins)", R, "# Signer audit TLS fixtures (0.5.390)\n", "# Signer audit TLS fixtures (0.5.390), from cos-mac.tail1b2c3d.ts.net\n",
     "[no private names in tests]"),
    # Option A (lead 2026-11-11 21:31): the phone approvals switch, Settings PK-02. One per guard.
    ("PA-1 a non-tailnet address turns it on", P, "return TailscaleCore.isTailnet(device) ? .on(device: device) : nil", "return .on(device: device)", "[phone switch args]"),
    ("PA-2 off removes the flag instead of writing 0", P, 'case .off: return ([authorityKey: "0"], [devicesKey])', "case .off: return ([:], [authorityKey, devicesKey])",
     "[phone switch off writes 0]"),
    ("PA-3 on is proven by a server that is not on", P, "        case .on: return authority\n", "        case .on: return true\n", "[phone switch proof]"),
    ("PA-4 off is proven by a server that is still on", P, "        case .off: return !enabled\n", "        case .off: return true\n", "[phone switch proof]"),
    ("PA-5 the app sends on with an address off the tailnet", C, "guard let phone, isTailnetIPv4(phone.ipv4) else { return nil }", "guard let phone else { return nil }",
     "[phone switch args]"),
    ("PA-6 the server floor is ignored", C, "return version.lexicographicallyPrecedes(floor) == false", "return true", "[phone switch server floor]"),
    ("PA-7 another account's phone is offered", C, 'guard peer.os == "iOS", peer.sameUser, let ipv4 = peer.ipv4,', 'guard peer.os == "iOS", let ipv4 = peer.ipv4,',
     "[phone switch phones]"),
    ("PA-8 registration-only reads as on", C, "static func isOn(_ mode: WebKeyServerMode) -> Bool { mode == .authority }",
     "static func isOn(_ mode: WebKeyServerMode) -> Bool { mode != .off }", "[phone switch on reads the server]"),
    ("PA-9 the switch in Basic (pins)", K, '"SG-02", "SG-11", "SG-12", "SG-13", "UT-29", "PK-01", "WB-01", "UT-10",',
     '"SG-02", "SG-11", "SG-12", "SG-13", "UT-29", "PK-01", "PK-02", "WB-01", "UT-10",', "[phone switch full settings only]"),
    ("PA-10 the toggle applies by itself (pins)", V, "                    if wanted, !on {\n                        choosing = true\n",
     "                    if wanted, !on {\n                        model.setPhoneApprovals(on: true, phone: phones.first)\n                        choosing = true\n",
     "[phone switch off by default]"),
    ("PA-11 the helper skips the server floor (pins)", H,
     "guard runningVersion.map({ versionAtLeast($0, PhoneApprovalsCore.minimumServer) }) == true || stoppedCompatibleManagedServer else {",
     "guard true || stoppedCompatibleManagedServer else {", "[phone switch wiring]"),
    ("PA-12 no proof after an in-place restart (pins)", H,
     "            if let phoneApprovals = PhoneApprovalsCore.change(fromEnvironment: values) {\n                try requirePhoneApprovals(phoneApprovals)\n            }\n", "",
     "[phone switch wiring]"),
    ("PA-13 the app and the helper name different servers", C, 'static let minimumServer = "7.0.29"\n\n    struct Peer', 'static let minimumServer = "7.0.28"\n\n    struct Peer',
     "[phone switch server floor]"),
    ("PA-14 the confirm drops the certificate-log sentence", C,
     '+ "\\(mac) becomes public in certificate logs when its first certificate is issued, and stays public. "', '+ ""', "[phone switch confirm]"),
    # Like the nine restart rows: never live while work runs.
    ("PA-15 the switch applies while work runs", C, "static func applyAllowed(locked: Bool, workActive: Bool) -> Bool { !locked && !workActive }",
     "static func applyAllowed(locked: Bool, workActive: Bool) -> Bool { !locked }", "[phone switch waits for work]"),
    ("PA-16 the turn-on confirm skips the work check (pins)", V,
     "if PhoneApprovalsSwitch.applyAllowed(locked: locked, workActive: work.active) { model.setPhoneApprovals(on: true, phone: picked) } else { held = true }",
     "model.setPhoneApprovals(on: true, phone: picked)", "[phone switch waits for work]"),
    ("PA-17 the mount hands the row no work (pins)", MV, "work: restartWork, locked: serverSettingsLocked) }", "work: .init(), locked: false) }",
     "[phone switch waits for work]"),
    ("PA-18 the render seed runs with background work on (pins)", V,
     "        precondition(!model.backgroundWorkEnabled)\n        var row = PhoneApprovalsSwitchRow(", "        var row = PhoneApprovalsSwitchRow(",
     "[phone switch render seed]"),
    ("PA-19 the render draws the switch below the approvals block (pins)", RN,
     "                SettingsHubBlock { row }\n                WebKeySettingsBlock(state: model.webKey, refreshes: false)\n",
     "                WebKeySettingsBlock(state: model.webKey, refreshes: false)\n                SettingsHubBlock { row }\n", "[phone switch render order]"),
    # Option A (lead ruling 2026-11-12 10:32): Off revokes every phone at once; only its =0 restart waits for running work.
    ("PA-20 Off's revoke waits for running work", C, "let pending = PhoneApprovalsPendingOff(revokedAll: await revokeAll(), savedAt: now)",
     "let pending = PhoneApprovalsPendingOff(revokedAll: PhoneApprovalsSwitch.applyAllowed(locked: locked(), workActive: workActive()) ? await revokeAll() : false, savedAt: now)",
     "[phone off revokes at once]"),
    ("PA-21 Off's =0 restart skips the wait", C,
     "guard store.load() != nil, PhoneApprovalsSwitch.applyAllowed(locked: locked, workActive: workActive) else { return false }",
     "guard store.load() != nil else { return false }", "[phone off restart waits]"),
    ("PA-22 Off saves its wait only after the revoke", C, "        store.save(PhoneApprovalsPendingOff(revokedAll: false, savedAt: now))\n", "", "[phone off saved first]"),
    ("PA-23 a failed Revoke all reads as stopped", C, "(pending.revokedAll ? stopped : notStopped)", "stopped", "[phone off failed revoke is not stopped]"),
    ("PA-24 a failed restart clears the wait", C, "if helperSucceeded { store.clear() }", "store.clear()", "[phone off failed restart keeps the wait]"),
    ("PA-25 the Off confirm drops the re-enroll sentence", C, "If you turn this on again, enroll each phone again with Touch ID. ", "", "[phone off confirm]"),
    ("PA-26 Revoke all reports success the server refused", C, "        return answer?.status == 200\n    }", "        return true\n    }",
     "[phone off failed revoke is not stopped]"),
    ("PA-27 the wait is not saved across a quit", C,
     '        defaults.set(["revokedAll": pending.revokedAll, "savedAt": NSNumber(value: pending.savedAt)] as [String: Any], forKey: Self.key)\n', "",
     "[phone off wait is saved]"),
    ("PA-28 the Off confirm waits for work again (pins)", V, ".destructive(PhoneApprovalsSwitch.confirmOff) { turnOff() }",
     ".destructive(PhoneApprovalsSwitch.confirmOff) { if PhoneApprovalsSwitch.applyAllowed(locked: locked, workActive: work.active) { turnOff() } else { held = true } }",
     "[phone off revokes at once]"),
    ("PA-29 a phone's Revoke waits for work (pins)", V, "Button(WebKeyCopy.revoke) { Task { await state.revoke(row.kid) } }",
     "Button(WebKeyCopy.revoke) { if PhoneApprovalsSwitch.applyAllowed(locked: false, workActive: false) { Task { await state.revoke(row.kid) } } }",
     "[devices revoke is live]"),
]

only = [part for part in os.environ.get("MUTATE_ONLY", "").split("|") if part]
if only:
    mutants = [m for m in mutants if any(part in m[0] for part in only)]
log_dir = os.environ.get("MUTATE_LOG_DIR")
if log_dir:
    # Evidence mode (0.5.390): the commit and the worktree state up front, then each mutant's exact substitution and the
    # whole lane output, so a survivor's log shows the guard removed and what the lane printed with it gone.
    log_dir = pathlib.Path(log_dir)
    log_dir.mkdir(parents=True, exist_ok=True)
    head = sh("git rev-parse HEAD")[1].strip()
    porcelain = sh("git status --porcelain")[1]
    state = "clean" if not porcelain.strip() else "DIRTY"
    (log_dir / "stamp.txt").write_text("commit " + head + "\nworktree " + state + "\n" + porcelain)
    print("stamp: commit " + head + ", worktree " + state, flush=True)
code, out = sh(LANE)
if log_dir:
    (log_dir / "baseline.log").write_text(out)
if code != 0 or "web key pins: all passed" not in out:
    print(f"BASELINE RED:\n{out[-3000:]}")
    sys.exit(1)
print("baseline: green (" + [l for l in out.splitlines() if "web key checks:" in l][-1] + ", pins all passed)", flush=True)
files = (C, V, P, H, T, G, K, R, MV, RN)
before = {f: (root / f).read_text() for f in files}
results = []
for name, path, old, new, expect in mutants:
    p = root / path
    src = p.read_text()
    n = src.count(old)
    if n != 1:
        results.append((name, f"NOT APPLIED (found {n}x)"))
        print(results[-1], flush=True)
        continue
    mutated = src.replace(old, new)
    p.write_text(mutated)
    landed = p.read_text() == mutated and mutated != src
    try:
        code, out = sh(LANE)
    finally:
        p.write_text(src)
    by = expect in out and ("check failed " + expect in out or "web key pin FAILED " + expect in out)
    killed = code != 0 and by
    verdict = ("KILLED" if killed else "SURVIVED") + (f" by {expect}" if killed and by else " (other failure)" if killed else "") + ("" if landed else " (MUTATION DID NOT LAND)")
    results.append((name, verdict))
    print(f"{verdict:70s} {name}", flush=True)
    if log_dir:
        slug = name.split(" ")[0]
        (log_dir / f"{slug}.log").write_text(f"mutant {name}\nfile {path}\nlanded {landed}\nexit {code}\nverdict {verdict}\n"
                                             f"--- removed\n{old}\n--- put in its place\n{new}\n--- lane output\n{out}")
    if killed and not by:
        print(out[-1500:])
print("\nsummary:")
for name, r in results:
    print(f"{r:70s} {name}")
print("sources restored:", all((root / f).read_text() == text for f, text in before.items()))
sys.exit(0 if all(r.startswith("KILLED by") and "DID NOT LAND" not in r for _, r in results) else 1)
