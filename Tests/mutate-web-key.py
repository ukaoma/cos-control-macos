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
    ("W6-4 approve() does not audit again (pins)", C, "        if !(audit?.fresh(now: now()) ?? false) { await runAudit() }\n        guard current(expectedRead), approveAllowed", "        guard current(expectedRead), approveAllowed", "[W6 approve rechecks]"),
    ("W6-5 the button ignores the gate (pins)", V, ".disabled(!state.approveAllowed || state.busy)", ".disabled(state.busy)", "[W6 approve rechecks]"),
    # Review W9: the listener audit.
    ("W9-1 the gate skips freshness", C, "        guard anchor, let card, let audit, audit.fresh(now: now) else { return false }", "        guard anchor, let card, audit != nil else { return false }", "[W9 approve needs a fresh audit]"),
    ("W9-2 a card without the audit", C, "        guard current(id), protectionReady, audit?.fresh(now: now()) == true else {", "        guard current(id), protectionReady else {", "[W9 no card without the audit]"),
    ("W9-3 split listeners pass", C, '        guard owners.count == 1 else { return refuse("listeners_split") }\n', "", "[W9 listener audit]"),
    ("W9-4 a foreign listener passes", C, 'object["underService"] as? Bool == true else { return refuse("port_\\(port)_foreign_listener") }', 'true else { return refuse("port_\\(port)_foreign_listener") }', "[W9 listener audit]"),
    ("W9-5 3144 not audited", C, "    static let ports = [3141, 3143, 3144]\n", "    static let ports = [3141, 3143]\n", "[W9 listener audit]"),
    ("W9-6 an old audit is fresh", C, "        return genuine && age <= Self.maxAge && age >= -5\n", "        return genuine\n", "[W9 audit freshness]"),
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
     '        guard store.save(s) else { message = "Control could not record the revocation. Phone approvals stay off."; return }\n        controlState = s\n        let answer = await ask("revoke-all",',
     '        controlState = s\n        let answer = await ask("revoke-all",', "[epoch intent before HTTP]"),
    ("W5-11 the state file is not strict", C, '              Set(object.keys) == ["v", "epoch", "revoked", "anchorSpkiSha256", "updatedAt"] else { return nil }', '              object["v"] != nil else { return nil }', "[W5 state file]"),
    # Hidden unless the flag; the bootstrap.
    ("F-1 shown when the flag is off", C, 'status.status == 200, status.body["enabled"] as? Bool == true,', "status.status == 200,", "[hidden unless the flag]"),
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
     'if next != saved, !store.save(next) {', 'if false {', "[protected persistence gate]"),
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

]

only = [part for part in os.environ.get("MUTATE_ONLY", "").split("|") if part]
if only:
    mutants = [m for m in mutants if any(part in m[0] for part in only)]
code, out = sh(LANE)
if code != 0 or "web key pins: all passed" not in out:
    print(f"BASELINE RED:\n{out[-3000:]}")
    sys.exit(1)
print("baseline: green (" + [l for l in out.splitlines() if "web key checks:" in l][-1] + ", pins all passed)", flush=True)
files = (C, V, P)
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
    if killed and not by:
        print(out[-1500:])
print("\nsummary:")
for name, r in results:
    print(f"{r:70s} {name}")
print("sources restored:", all((root / f).read_text() == text for f, text in before.items()))
sys.exit(0 if all(r.startswith("KILLED by") and "DID NOT LAND" not in r for _, r in results) else 1)
