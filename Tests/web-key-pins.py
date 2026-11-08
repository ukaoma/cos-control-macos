#!/usr/bin/env python3
"""Phone approvals (server 6.99.31, COS_WEB_KEY_AUTHORITY, default off): the wiring pins. Run by Tests/run-web-key.sh.

Each pin prints "web key pin FAILED [<behaviour>]" and the run exits 1 if any failed. Comments are stripped before
matching, so an explanation in prose never satisfies a pin. Tests/mutate-web-key.py proves each pin can fail.

    python3 Tests/web-key-pins.py [<repo root>]
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1])
failed = []


def need(ok, tag, why):
    if not ok:
        failed.append(tag)
        print(f"web key pin FAILED [{tag}]: {why}")


def code(rel):
    """The file with line and block comments blanked (string contents kept)."""
    text = (root / rel).read_text(encoding="utf-8")
    text = "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.split("\n"))
    return re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)


def body_of(text, start):
    """The brace-balanced body that opens at the first `{` after `start`."""
    i = text.index("{", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
    return text[i:]


core = code("Sources/WebKeyCore.swift")
views = code("Sources/WebKeyViews.swift")
main_views = code("Sources/Views.swift")
helper = code("HelperSources/main.swift")
pairing = code("HelperSources/PairingCore.swift")
catalog = code("Sources/SettingsHubCatalog.swift")
release = (root / "scripts/build-release.sh").read_text(encoding="utf-8")
suite = (root / "Tests/run.sh").read_text(encoding="utf-8")

# 1. Review W4: the card draws only a WebKeyApprovalCard, and never the code.
card_view = body_of(views, views.index("private struct WebKeyEnrollmentCardView: View"))
fields = set(re.findall(r"\bcard\.([A-Za-z]+)", card_view))
need(fields and fields <= {"label", "remote", "userAgent", "fingerprint", "rotates"}, "W4 card fields",
     f"the card view reads only WebKeyApprovalCard display fields, never the code (read: {sorted(fields)})")
need(re.search(r"\.sas\b", views) is None, "W4 card never shows the code", "no .sas anywhere in WebKeyViews.swift")
need(re.search(r"\bpending\b|\[String:\s*Any\]|approval\[|approvalJcs", views) is None, "W4 card fields",
     "the views never touch the server's pending answer, a raw dictionary or the approval object")
need("let card: WebKeyApprovalCard" in card_view, "W4 card fields", "the card view takes a WebKeyApprovalCard")

# 2. Review W4: one builder, from the bytes.
constructions = [m.start() for m in re.finditer(r"WebKeyApprovalCard\(", core)]
check_start = core.index("enum WebKeyApprovalCheck")
check_body = body_of(core, check_start)
need(len(constructions) == 1 and check_start < constructions[0] < check_start + len(check_body), "W4 one builder",
     f"WebKeyApprovalCard is built once, inside WebKeyApprovalCheck (found {len(constructions)})")
card_fn = body_of(core, core.index("static func card(pending:"))
pending_keys = set(re.findall(r'pending\["([A-Za-z_]+)"\]', card_fn))
need(pending_keys <= {"enrollId", "approvalJcs", "approval"}, "W4 one builder",
     f"the card reads only enrollId, approvalJcs and the copy from the pending answer (read: {sorted(pending_keys)})")
need("Set(pending.keys).isSubset(of: WebKeyProtocol.pendingKeys)" in card_fn and "guard WebKeyJCS.bytes(approval) == bytes" in card_fn,
     "W4 one builder", "extra display fields and non-canonical bytes are refused")
published = re.findall(r"@Published[^\n]*", core)
need(not any("[String: Any]" in p or "pending" in p.lower() and "pendingWithoutAudit" not in p for p in published), "W4 one builder",
     "WebKeyState publishes the card, never the raw pending answer")

# 3. Review W6, W9: approve() checks the gate itself, after a fresh audit, before Touch ID.
approve_fn = body_of(core, core.index("    func approve() async"))
gate_at = approve_fn.find("guard current(expectedRead), approveAllowed")
sign_at = approve_fn.find("anchor.sign(card.approvalBytes")
audit_at = approve_fn.find("if !(audit?.fresh(now: now()) ?? false) { await runAudit() }")
need(0 <= audit_at < gate_at < sign_at, "W6 approve rechecks", "approve() audits again, then the gate, then Touch ID")
gate_fn = body_of(core, core.index("static func allowed(card:"))
need("audit.fresh(now: now)" in gate_fn and "WebKeyCodeEntry.matches(typed: typed, card: card)" in gate_fn, "W6 approve rechecks",
     "the gate needs a fresh audit and the typed code")
need(".disabled(!state.approveAllowed || state.busy)" in card_view, "W6 approve rechecks", "the button follows the same gate")

# 4. Review W9: no card without the audit.
pending_fn = body_of(core, core.index("private func loadPending(anchorDER: Data, id: UUID)"))
need(pending_fn.find("audit?.fresh(now: now()) == true") < pending_fn.find("WebKeyApprovalCheck.card("), "W9 no card without the audit",
     "the audit gate comes before the card is built")
need("WebKeyListenerAudit.notGenuineLine" in views and '"Cannot confirm the signer page is genuine"' in core, "W9 no card without the audit",
     "the refusal line is drawn")
need("for port in WebKeyHelperCore.auditPorts" in helper and '"-iTCP:\\(port)", "-sTCP:LISTEN", "-t"' in helper
     and "auditPorts = [3141, 3143, 3144]" in pairing, "W9 helper audit", "lsof on 3141, 3143 and 3144, every address")

# 5. Review W5: class C, atomic, keychain first.
write_fn = body_of(core, core.index("private func writeFile(_ state: WebKeyControlState)"))
need("[.atomic, .completeFileProtectionUntilFirstUserAuthentication]" in write_fn, "W5 class C", "atomic, class C")
need(re.search(r"completeFileProtectionUnlessOpen|completeUnlessOpen|\.completeFileProtection\s*[\],]|\.complete\b", core) is None,
     "W5 class C", "never class A or B")
save_fn = body_of(core, core.index("    func save(_ state: WebKeyControlState) -> Bool"))
need(save_fn.find("secure.write(Self.mirrorAccount") < save_fn.find("return writeFile(state)"), "W5 keychain first", "the keychain before the file")
need(len(re.findall(r"\.write\(to:", core)) == 1, "never writes the repo", "the state file is the only file Control writes here")

# 6. Hidden unless the flag; mounted once, in Devices.
need(main_views.count("WebKeySettingsBlock(state: model.webKey)") == 1, "hidden unless the flag", "mounted once")
devices = body_of(main_views, main_views.index('hubCard("glasses.devices"'))
need("WebKeySettingsBlock(state: model.webKey)" in devices and '.settingsHubAnchor("PK-01")' in devices, "hidden unless the flag",
     "in Glasses and iPhone, Devices, with its search anchor")
block = body_of(views, views.index("struct WebKeySettingsBlock: View"))
need(re.search(r"VStack\(alignment: \.leading, spacing: 0\) \{\s*if state\.visible \{", block) is not None, "hidden unless the flag",
     "nothing is drawn unless the server says the flag is on")
refresh_fn = body_of(core, core.index("    func refresh() async"))
need('status.status == 200, status.body["enabled"] as? Bool == true,' in refresh_fn and 'else { clear(); return }' in refresh_fn, "hidden unless the flag",
     "visible only on a 200 with enabled true")

# 7. GOTCOS theme: no stock toggles; a field is plain plus cosField.
need("Toggle(" not in views or "COSCheckStyle()" in views, "theme", "a toggle here uses COSCheckStyle")
need(".textFieldStyle(.plain)" in views and ".cosField()" in views, "theme", "the code field is the COS field")

# 8. Secrets: the app never reads the token or .env; the helper does.
need(re.search(r"\.env\b|COS_API_TOKEN|readToken|X-Cos-Token|X-COS-Token", core + views) is None, "no token in the app",
     "the app never reads .env or the token")
emit_fn = body_of(helper, helper.index("private func emitWebKey(args: [String])"))
need("try? readToken()" in emit_fn and "request(call.path, method: call.method, token: token, body: payload" in emit_fn
     and "WebKeyHelperCore.body(op: op, stdin: try readBoundedStdin(WebKeyHelperCore.bodyMax))" in emit_fn, "helper verb",
     "the helper reads the token, validates stdin and calls the table's route")
need('case "web-key": try emitWebKey(args: args)' in helper, "helper verb", "dispatched")

# 9. Review B1: the anchor is a Secure Enclave key behind current biometry, and Control never writes the repo pin.
create_fn = body_of(core, core.index("static func create() throws -> SecureEnclaveWebKeyAnchor"))
need("[.privateKeyUsage, .biometryCurrentSet]" in create_fn and "SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: access)" in create_fn,
     "B1 anchor key", "Secure Enclave, .privateKeyUsage and .biometryCurrentSet")
sign_fn = body_of(core, core.index("    func sign(_ message: Data, reason: String) async throws -> Data {", core.index("struct SecureEnclaveWebKeyAnchor")))
need(sign_fn.find("evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)") < sign_fn.find("signature(for: message)") and "withTaskCancellationHandler" in sign_fn and "attempt.cancel()" in sign_fn and "Task.checkCancellation()" in sign_fn,
     "B1 anchor key", "Touch ID with our reason before the Secure Enclave signs")
need('"web_key_anchor.json"' not in core.replace("operations/scripts/web_key_anchor.json", ""), "never writes the repo", "the pin is only copied")

# 10. Release and catalog.
need('"$ROOT/Sources/WebKeyCore.swift" "$ROOT/Sources/WebKeyViews.swift"' in release, "source lists", "the release build has both files")
need(re.search(r'\.init\("PK-01", "Phone approvals", [^\n]*group: "glasses\.devices"', catalog) is not None
     and catalog.index('.init("PK-01"') > catalog.index("static let extras: [SettingsHubItem] = [")
     and catalog.index('.init("PK-01"') < catalog.index("static let items: [SettingsHubItem] = ["), "catalog row", "a Devices hub row, outside the inventory")
need('"$ROOT/Tests/run-web-key.sh"' in suite, "suite lane", "Tests/run.sh runs this lane")

# Immutable audit and lifetime wiring complement the behavioral fixtures; neither a writable manifest nor HTTP can pin trust.
audit_fn = body_of(helper, helper.index("private func webKeyAssetAudit()"))
need("WebKeyAssetsCore.bundleResource" in audit_fn and '"--verify", "--deep", "--strict", "-R"' in audit_fn
     and "WebKeyAssetsCore.pins(pinData, version: installed.version)" in audit_fn
     and "WebKeyAssetsCore.manifest" in audit_fn and "WebKeyAssetsCore.verified(served, sha: sha)" in audit_fn,
     "immutable asset wiring", "a sealed own-bundle pin governs installed and served bytes")
need('"--cacert", managedCert.path' in audit_fn and '"--resolve", host + ":3144:127.0.0.1"' in audit_fn
     and '"--noproxy", "*"' in audit_fn and '"--max-redirs", "0"' in audit_fn and '"--insecure"' not in audit_fn,
     "signer TLS wiring", "normal TLS to the owned loopback signer, without proxy or redirects")
need('.onDisappear { state.cancelActions() }' in block and 'state.startApproval()' in card_view,
     "approval lifetime wiring", "disappearing Settings cancels the tracked action")
need('visible && anchorRegisteredHere && protectionReady && controlState != nil' in core,
     "protected persistence wiring", "a retained card alone never grants approval")
need('cp "$ROOT/Resources/web-key-assets.json" "$APP/Contents/Resources/"' in release,
     "immutable resource packaging", "exact immutable pin file ships inside the signature")

# 11. Copy: no em dashes in what Control shows.
copy = re.findall(r'"(?:[^"\\]|\\.)*"', views + core)
need(not any("—" in c for c in copy), "copy", "no em dash in any string")

if failed:
    sys.exit(f"web key pins: {len(failed)} failed")
print("web key pins: all passed")
