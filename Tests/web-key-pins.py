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
# 0.5.387 (lane D2): Phone and web, beside Open COS on your phone, never under Advanced.
phone = body_of(main_views, main_views.index('hubCard("glasses.phone"'))
need("WebKeySettingsBlock(state: model.webKey)" in phone and '.settingsHubAnchor("PK-01")' in phone and "advanced:" not in phone[:phone.index("WebKeySettingsBlock")],
     "hidden unless the flag", "in Glasses, phone and web, Phone and web, beside the phone sign-in, with its search anchor")
block = body_of(views, views.index("struct WebKeySettingsBlock: View"))
need(re.search(r"VStack\(alignment: \.leading, spacing: 0\) \{\s*if state\.visible \{", block) is not None, "hidden unless the flag",
     "nothing is drawn unless the server says the flag is on")
refresh_fn = body_of(core, core.index("    func refresh() async"))
need("let served = WebKeyServerMode.read(status: status.status, body: status.body)" in refresh_fn
     and "guard served != .off, let suppliedOrigin" in refresh_fn and 'else { clear(); onReadiness = readiness; return }' in refresh_fn, "hidden unless the flag",
     "visible only when the server reports authority or bootstrap")
mode_fn = body_of(core, core.index("static func read(status: Int, body: [String: Any]) -> WebKeyServerMode"))
need('guard status == 200, let origin = body["origin"] as? String, WebKeyProtocol.signerHost(origin) != nil else { return .off }' in mode_fn
     and 'case true?: return mode == nil || mode as? String == "authority" ? .authority : .off' in mode_fn
     and 'case false?: return mode as? String == "bootstrap" ? .bootstrap : .off' in mode_fn and "case nil: return .off" in mode_fn,
     "mode reader", "authority is enabled true; bootstrap is enabled false plus mode bootstrap; anything else is off")

# 6b. 0.5.383 bootstrap (server 7.0.9, COS_WEB_KEY_ANCHOR_BOOTSTRAP): the Mac anchor alone.
need(re.search(r"SettingsHubBlock \{ WebKeyAnchorSection\(state: state\) \}\s*if state\.authority && state\.anchorRegisteredHere \{\s*"
               r"SettingsHubBlock \{ WebKeyEnrollmentSection\(state: state\) \}\s*if !state\.keys\.isEmpty \{ SettingsHubBlock \{ WebKeyKeysSection\(state: state\) \} \}", block) is not None
     and block.count("WebKeyEnrollmentSection(") == 1 and block.count("WebKeyKeysSection(") == 1,
     "bootstrap shows the anchor only", "enrollment and the key list draw only with authority on")
boot_at = refresh_fn.find("if served == .bootstrap {")
boot_branch = body_of(refresh_fn, boot_at) if boot_at >= 0 else ""
need(0 <= boot_at < refresh_fn.find("syncState(") and boot_at < refresh_fn.find("loadPending(") and boot_branch.rstrip("}").rstrip().endswith("return")
     and "card = nil; cardRefusal = nil; pendingWithoutAudit = false; keys = []; typedCode = \"\"" in boot_branch
     and not re.search(r"ask\(|runAudit|syncState|loadPending", boot_branch), "bootstrap hides enrollment and approval",
     "bootstrap returns before the key list and the pending request, and asks nothing more")
approve_allowed = body_of(core, core.index("    var approveAllowed: Bool"))
need("mode == .authority && visible && anchorRegisteredHere" in approve_allowed, "bootstrap hides enrollment and approval", "approval needs authority")
for fn in ("    func revoke(_ kid: String) async", "    func revokeAll() async"):
    need("guard mode == .authority, visible, !busy" in body_of(core, core.index(fn)), "bootstrap hides enrollment and approval", f"{fn.strip()} needs authority")
need("guard !busy, actionTask == nil, recoveryRequired, mode == .authority else { return }" in core
     and "guard registering != .off, !recovery || registering == .authority else { return }" in core,
     "bootstrap hides enrollment and approval", "reset is authority's alone")
audit_struct = body_of(core, core.index("struct WebKeyListenerAudit: Equatable, Sendable"))
need("scope == .signer && genuine && young(now: now)" in body_of(audit_struct, audit_struct.index("func fresh(now: Date) -> Bool"))
     and "scope == .anchor && genuine && young(now: now)" in audit_struct and "static let anchorPorts = [3141, 3143]" in audit_struct,
     "bootstrap anchor audit never approves", "an anchor-scope audit never passes the signer gate")
run_audit = body_of(core, core.index("    func runAudit() async"))
need('let scope: WebKeyListenerAudit.Scope = mode == .bootstrap ? .anchor : .signer' in run_audit
     and '"--op", scope == .anchor ? "anchor-listeners" : "listeners"' in run_audit, "bootstrap anchor audit", "bootstrap asks the anchor audit, authority the signer audit")
reg_audit = body_of(core, core.index("private func registrationAuditFresh(_ registering: WebKeyServerMode) -> Bool"))
need("case .authority: return audit?.fresh(now: now()) == true" in reg_audit and "case .bootstrap: return audit?.freshForAnchorRegistration(now: now()) == true" in reg_audit
     and "case .off: return false" in reg_audit and "guard mode == registering else { return false }" in reg_audit, "bootstrap anchor audit", "registration's audit follows the mode")
anchor_helper = helper[helper.index('if op == "anchor-listeners" {'):helper.index('if op == "listeners" {')]
need("WebKeyHelperCore.anchorAuditPorts" in anchor_helper and "webKeyAssetAudit" not in anchor_helper and "3144" not in anchor_helper
     and "anchorAuditPorts = [3141, 3143]" in pairing, "bootstrap helper audit", "the anchor audit lists 3141 and 3143, never 3144 or the signer files")
anchor_view = body_of(views, views.index("private struct WebKeyAnchorSection: View"))
need("if state.bootstrapOnly, let sha = state.anchorSpkiSha256" in anchor_view and "WebKeyLine(label: WebKeyCopy.keyHash, value: sha, mono: true, lines: 3)" in anchor_view
     and "state.anchorSetAt" in anchor_view and "state.bootstrapOnly ? WebKeyCopy.bootstrapPinNote : WebKeyCopy.pinNote" in anchor_view
     and "state.authority && state.anchorRegisteredHere && state.recoveryRequired" in anchor_view, "bootstrap shows the anchor only",
     "the full key hash, setAt and the commit-by-hand line; no reset")
need(re.search(r'bootstrapPinNote = "[^"]*committ?\w* it by hand[^"]*Control never writes or commits it\."', views) is not None,
     "bootstrap pin by hand", "the pin is committed by hand, never by Control")
bind_fn = body_of(core, core.index("private func bindBootstrapRecord(anchorSpki: Data, statusEpoch: Int64?)"))
need("guard registeredAnchorNeedsStateRebind else { return }" in bind_fn and "case .mirrorUnavailable:" in bind_fn and "case .mirrorMissing:" in bind_fn
     and "revoked: []" in bind_fn, "bootstrap starts the protected record", "only right after this run registered, never over an unreadable record")

# 6c. The server resets setAt on a same-key registration (coordinator, 2026-11-08): a plain Register never runs over a
# registered anchor; replacing another key needs its confirmation.
create_fn = body_of(core, core.index("    func createOrRegisterAnchor(recovery: Bool = false, replace: Bool = false) async"))
need("guard recovery || replace || (!anchorRegisteredHere && !foreignAnchor) else {" in create_fn
     and create_fn.find('fresh.body["anchorRegistered"] as? Bool == false') < create_fn.find("candidate.sign(statement")
     and 'guard let fresh = await ask("status")' in create_fn, "never registers twice", "Register re-reads status and refuses a registered anchor before Touch ID")
need("guard !busy, actionTask == nil, !anchorRegisteredHere, !foreignAnchor else { return }" in core
     and "await createOrRegisterAnchor(replace: true)" in body_of(core, core.index("    func startReplace()")), "never registers twice", "Register and Replace start only in their own state")
need("if !state.anchorRegisteredHere && !state.foreignAnchor {" in anchor_view and "Button(WebKeyCopy.replace) { confirmReplace = true }" in anchor_view
     and '.destructive("Replace with Touch ID") { state.startReplace() }' in anchor_view and views.count("state.startReplace()") == 1,
     "confirmed replace", "replacing another key runs only from its confirmation")

# 7. GOTCOS theme: no stock toggles; a field is plain plus cosField.
toggle_styles = re.findall(r"\.toggleStyle\(([^()]*(?:\(\))?)\)", views)
need(views.count("Toggle(") == len(toggle_styles) and all(s in ("COSCheckStyle()", "COSSwitchStyle()") for s in toggle_styles), "theme",
     f"every toggle here uses a COS style (COSCheckStyle or COSSwitchStyle), never a stock one: {toggle_styles}")
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
need(re.search(r'\.init\("PK-01", "Phone approvals", [^\n]*group: "glasses\.phone",\s*advanced: false, mount: \.group', catalog) is not None
     and catalog.index('.init("PK-01"') > catalog.index("static let extras: [SettingsHubItem] = [")
     and catalog.index('.init("PK-01"') < catalog.index("static let items: [SettingsHubItem] = ["), "catalog row", "a Phone and web hub row, outside the inventory, not Advanced")
# 0.5.387 (lane D2): Phone approvals and Open COS on your phone are in Basic, so the Phone and web card draws there too.
basic_block = catalog[catalog.index("static let basicIDs: Set<String> = ["):catalog.index("static let basicRange")]
need('"UT-29"' in basic_block and '"PK-01"' in basic_block, "basic", "Open COS on your phone and Phone approvals are in the Basic set")
need('"$ROOT/Tests/run-web-key.sh"' in suite, "suite lane", "Tests/run.sh runs this lane")

# Immutable audit and lifetime wiring complement the behavioral fixtures; neither a writable manifest nor HTTP can pin trust.
audit_fn = body_of(helper, helper.index("private func webKeyAssetAudit()"))
need("WebKeyAssetsCore.bundleResource" in audit_fn and '"--verify", "--deep", "--strict", "-R"' in audit_fn
     and "WebKeyAssetsCore.pins(pinData, version: installed.version)" in audit_fn
     and "WebKeyAssetsCore.manifest" in audit_fn and "WebKeyAssetsCore.verified(served, sha: sha)" in audit_fn,
     "immutable asset wiring", "a sealed own-bundle pin governs installed and served bytes")
need('"--resolve", host + ":3144:127.0.0.1"' in audit_fn
     and '"--noproxy", "*"' in audit_fn and '"--max-redirs", "0"' in audit_fn and '"--insecure"' not in audit_fn and '"-k"' not in audit_fn,
     "signer TLS wiring", "normal TLS to the owned loopback signer, without proxy or redirects")

# 0.5.390 (QA 2026-11-09 open question 2): the ts.net signer host is trusted the way the phone trusts it, by the system roots
# ALONE over the chain each fetch received; never Apple curl's --cacert-plus-keychain. Counted, so a deleted line fails.
need(audit_fn.count("SignerTLSCore.trust(host: host) == .systemRoots") == 1 and ".ts\\.net\\z" not in audit_fn
     and audit_fn.find("SignerTLSCore.trust(host: host) == .systemRoots") < audit_fn.find('return refused("reported_integrity")'),
     "audit gate is the split", "the origin guard asks SignerTLSCore.trust, with no second copy of the host pattern")
need(audit_fn.count("SignerTLSCore.curlTrustArguments(.systemRoots, managedCert: managedCert.path)") == 1 and '"--cacert"' not in audit_fn
     and '"--write-out"' not in audit_fn,
     "audit curl trust args wiring", "the fetch takes its trust and write-out from SignerTLSCore, and the audit passes no CA file")
anchors_at = audit_fn.find("let anchors = SignerTLSCore.systemRoots()")
answer_at = audit_fn.find("let answer = SignerTLSCore.curlAnswer(result.output)")
judged = 'guard SignerTLSCore.trusted(chain: answer.chain, host: host, at: Date(), anchors: anchors) else { return refused("signer_tls") }'
judged_at = audit_fn.find(judged)
bytes_at = audit_fn.find("WebKeyAssetsCore.verified(served, sha: sha)")
need(audit_fn.count(judged) == 1 and 0 <= anchors_at < audit_fn.find("for (path, sha) in signerFiles") < answer_at < judged_at < bytes_at,
     "audit judges each chain", "system roots before the loop; every fetch's own chain is judged before its bytes count")
trusted_fn = body_of(pairing, pairing.index("static func trusted(chain: [Data], host: String, at date: Date, anchors: [SecCertificate]) -> Bool"))
evaluate_fn = body_of(pairing, pairing.index("static func evaluate(chain: [Data], host: String, at date: Date, anchors: [SecCertificate]) -> (trusted: Bool, why: String)"))
need(trusted_fn.strip("{} \n") == "evaluate(chain: chain, host: host, at: date, anchors: anchors).trusted",
     "audit evaluator wiring", "trusted() is exactly evaluate()'s answer, so the evidence lines describe what the audit runs")
need(evaluate_fn.count("SecPolicyCreateSSL(true, host as CFString)") == 1 and evaluate_fn.count("SecTrustSetAnchorCertificates(trust, anchors as CFArray)") == 1
     and evaluate_fn.count("SecTrustSetAnchorCertificatesOnly(trust, true)") == 1 and evaluate_fn.count("SecTrustSetNetworkFetchAllowed(trust, false)") == 1
     and evaluate_fn.count("SecTrustSetVerifyDate(trust, date as CFDate)") == 1 and evaluate_fn.count("SecTrustEvaluateWithError(trust, &error)") == 1,
     "audit evaluator wiring", "SSL policy with the host name, the given anchors ONLY, no network fetch, the given date")
roots_fn = body_of(pairing, pairing.index("static func systemRoots() -> [SecCertificate]"))
need(roots_fn.count("SecTrustSettingsCopyCertificates(.system, &list)") == 1 and ".admin" not in pairing and ".user" not in roots_fn,
     "audit system roots wiring", "the system trust domain only, never admin or user")
args_fn = body_of(pairing, pairing.index("static func curlTrustArguments(_ trust: Trust, managedCert: String) -> [String]"))
system_case = args_fn[args_fn.find("case .systemRoots:"):args_fn.find("case .managedCert:")]
need(args_fn.find("case .systemRoots:") >= 0 and "--cacert" not in system_case and "%{certs}" in system_case and "%{num_certs}" in system_case
     and "--insecure" not in args_fn,
     "audit curl trust args", "the ts.net case has no CA file and writes out curl's chain count and the chain")
# SR-02 and SR-07 (reopen, 2026-11-11): the count gate lives in curlAnswer, and the audit maps curl's exit through one table.
answer_fn = body_of(pairing, pairing.index("static func curlAnswer(_ output: String) -> (code: String, chain: [Data])"))
need(answer_fn.count("declared == blocks.count else { return (code, []) }") == 1, "audit refuses injected blocks",
     "curlAnswer returns no chain unless the PEM blocks number curl's own %{num_certs}")
need(audit_fn.count("guard result.code == 0 else { return refused(SignerTLSCore.curlFailureReason(exit: result.code)) }") == 1
     and 'result.code == 0 else { return refused("served_signer_assets") }' not in audit_fn,
     "audit curl tls exits wiring", "a curl failure is named by SignerTLSCore.curlFailureReason, never a fixed served_signer_assets")
# SR-06: the audit approximates the phone, it does not equal it; release notes must not say otherwise.
notes = ((root / "Resources/WhatsNew.json").read_text(encoding="utf-8") + (root / "CHANGELOG.md").read_text(encoding="utf-8")).lower()
need("way your iphone does" not in notes and "the way the iphone does" not in notes, "audit copy",
     "notes say 'checked against the certificate authorities macOS ships', never 'the way your iPhone does'")
# 0.5.390: one plain line from the server's signerTls, authority only, inside the existing anchor section.
anchor_view = body_of(views, views.index("private struct WebKeyAnchorSection: View"))
need(views.count("state.signerTLSLine") == 1 and anchor_view.count("if state.authority, let line = state.signerTLSLine {") == 1,
     "signer cert line wiring", "drawn once, in the anchor section, only with authority on")
line_set = "signerTLSLine = served == .authority ? WebKeySignerTLS.problem(body: status.body, now: now()) : nil"
need(refresh_fn.count(line_set) == 1 and 0 <= refresh_fn.find(line_set) < refresh_fn.find("if served == .bootstrap {"),
     "signer cert line wiring", "set on every read before the bootstrap return, nil unless authority")
clear_fn = body_of(core, core.index("    private func clear()"))
need(clear_fn.count("signerTLSLine = nil") == 1, "signer cert line wiring", "cleared with the rest when the server stops serving")
# Server reopen: the stored-pair refusal (signerTls.storedRefused), same gate, same block, same reset.
stored_set = "signerTLSStoredLine = served == .authority ? WebKeySignerTLS.storedRefused(body: status.body, now: now()) : nil"
need(views.count("state.signerTLSStoredLine") == 1 and anchor_view.count("if state.authority, let stored = state.signerTLSStoredLine {") == 1
     and refresh_fn.count(stored_set) == 1 and 0 <= refresh_fn.find(stored_set) < refresh_fn.find("if served == .bootstrap {")
     and clear_fn.count("signerTLSStoredLine = nil") == 1,
     "signer stored refusal wiring", "drawn once in the anchor section with authority on, set before the bootstrap return, cleared with the rest")

# Option A (lead 2026-11-11 21:31): the phone approvals switch, Settings PK-02.
# Full Settings only: never a basic row, and the mount asks hubRowDrawn (false in Basic) and the server floor.
basic_block = catalog[catalog.index("static let basicIDs: Set<String> = ["):catalog.index("static let basicRange")]
pk02_at = catalog.find('.init("PK-02"')
need('"PK-02"' not in basic_block and catalog.index("static let extras: [SettingsHubItem] = [") < pk02_at < catalog.index("static let items: [SettingsHubItem] = [")
     and re.search(r'\.init\("PK-02", "Turn on phone approvals", [^\n]*group: "glasses\.phone",\s*advanced: false, mount: \.group', catalog) is not None
     and phone.count('PhoneApprovalsSwitchMount(state: model.webKey, serverVersion: model.status.version, rowDrawn: hubRowDrawn("PK-02")) {') == 1
     and phone.count('.settingsHubAnchor(PhoneApprovalsSwitch.anchorID(on: PhoneApprovalsSwitch.isOn(model.webKey.mode),') == 1
     and main_views.count("PhoneApprovalsSwitchRow(") == 1
     and 'static func anchorID(on: Bool, pendingOff: Bool) -> String { on || pendingOff ? "PK-02-off" : "PK-02" }' in core and '.init("PK-02-off"' not in catalog
     and main_views.count("PhoneApprovalsSwitchMount(") == 1,
     "phone switch full settings only", "PK-02 is an extras row in Phone and web, not in Basic, mounted only through PhoneApprovalsSwitch.mounted")
# PA-C (2026-11-15), the reviewed return of On after the lead ruling of 2026-11-12 19:50 (review finding 9, SR-15). No
# compile-time "available" constant, defaults key or environment value decides it: On needs the server's own proof
# (signerBindFixVersion, signerBind.scope "tailnet") read from its token-authenticated status. The app's mount, toggle and
# one sender ask PhoneApprovalsReadiness; the helper reads the status itself before writing anything for On (onRefusal) and is
# the real gate. Off never asks any of it. Search still leaves out PK-01 and PK-02.
mount_view = body_of(views, views.index("struct PhoneApprovalsSwitchMount<Content: View>: View"))
mounted_fn = body_of(core, core.index("static func mounted(serverVersion: String?, rowDrawn: Bool, on: Bool, pendingOff: Bool, readiness: PhoneApprovalsReadiness?) -> Bool"))
shown_fn = body_of(core, core.index("static func shown(serverVersion: String?, readiness: PhoneApprovalsReadiness?) -> Bool"))
request_fn = body_of(core, core.index("static func request(on: Bool, phone: Phone?, readiness: PhoneApprovalsReadiness?, disclosedName: String?) -> [String]?"))
readiness_src = body_of(core, core.index("struct PhoneApprovalsReadiness: Equatable, Sendable {"))
model = code("Sources/ControllerModel.swift")
sender = body_of(model, model.index("func setPhoneApprovals(on: Bool, phone: PhoneApprovalsSwitch.Phone?, disclosedName: String? = nil, run: ((String, [String]) -> Void)? = nil)"))
set_fn0 = body_of(helper, helper.index("private func setPhoneApprovals(_ arguments: [String]) throws"))
switch_src = body_of(core, core.index("enum PhoneApprovalsSwitch {"))
core_pa = body_of(pairing, pairing.index("enum PhoneApprovalsCore {"))
sources = "\n".join(code(str(f.relative_to(root))) for f in sorted((root / "Sources").glob("*.swift")))
helpers_all = "\n".join(code(str(f.relative_to(root))) for f in sorted((root / "HelperSources").glob("*.swift")))
# No build constant decides On any more, in either target.
no_constant = all(t not in src for src in (core, pairing, views, main_views, model, helper)
                  for t in ("static let available", "PhoneApprovalsSwitch.available", "PhoneApprovalsCore.available", "permits("))
need(no_constant and "UserDefaults" not in switch_src and "UserDefaults" not in readiness_src and "defaults" not in (mounted_fn + request_fn + shown_fn).lower()
     and "ProcessInfo" not in switch_src + readiness_src + core_pa and "environment[" not in readiness_src,
     "phone on needs the server fix", "no compile constant, defaults key or environment value decides On; only the server's proof does")
# The readiness: the fix version and the exact scope word, read from the status body.
need('static let requiredFixVersion: Int64 = 1' in readiness_src and 'static let tailnetScope = "tailnet"' in readiness_src
     and 'WebKeyServerMode.int(body["signerBindFixVersion"])' in readiness_src
     and 'var bindFixed: Bool { (fixVersion ?? 0) >= Self.requiredFixVersion && bindScope == Self.tailnetScope }' in readiness_src
     and 'var canTurnOn: Bool { bindFixed && publicName != nil }' in readiness_src
     and 'certIssued: cert?["issued"] as? Bool == true' in readiness_src,
     "phone on needs the server fix", "the readiness reads the fix version strictly, the exact scope word, and needs the public name")
need('var canTurnOn: Bool { bindFixed && publicName != nil }' in readiness_src, "phone on needs the public name", "the app never offers On without the exact public name")
# The app's gates: mount (turn-on only with shown, Off whatever the server says), toggle, the one sender.
need("if serverSupports(serverVersion) && (on || pendingOff) { return true }" in mounted_fn
     and "return rowDrawn && shown(serverVersion: serverVersion, readiness: readiness)" in mounted_fn
     and "serverSupports(serverVersion) && readiness?.canTurnOn == true" in shown_fn
     and "pendingOff: DefaultsPhoneApprovalsPendingStore().load() != nil, readiness: state.onReadiness) {" in mount_view
     and "guard !on || (readiness?.canTurnOn == true && readiness?.disclosed(disclosedName) == true) else { return nil }" in request_fn
     and sender.count("PhoneApprovalsSwitch.request(on: on, phone: phone, readiness: webKey.onReadiness, disclosedName: disclosedName)") == 1
     and "PhoneApprovalsSwitch.arguments(" not in sender
     and sources.count('"set-phone-approvals"') == 2 and sender.count('"set-phone-approvals"') == 2
     and re.search(r"if wanted, !on \{\s*guard PhoneApprovalsSwitch\.canStart\(state\.onReadiness\) else \{ return \}\s*choosing = true", views) is not None,
     "phone on needs the server fix", "the mount, the toggle and the app's one sender all ask the server's proof; Off is mounted and sent regardless")
# WebKeyState keeps the readiness from every status answer (the off mode's too), and clears it with the rest.
refresh_body = body_of(core, core.index("    func refresh() async {"))
clear_body = body_of(core, core.index("    private func clear() {"))
need(refresh_body.count("let readiness = PhoneApprovalsReadiness.read(status: status.status, body: status.body)") == 1
     and "else { clear(); onReadiness = readiness; return }" in refresh_body and refresh_body.count("onReadiness = readiness") == 2
     and clear_body.count("onReadiness = nil") == 1 and core.count("onReadiness =") == 3,
     "phone on readiness read", "the readiness is read from every status answer, the off mode's included, and cleared with the rest")
# The helper is the real gate: On reads the server's status itself, before the server floor and before anything is written.
need(set_fn0.find("if change != .off {") > set_fn0.find("PhoneApprovalsCore.change(arguments)") >= 0
     and set_fn0.count('request("/api/web-key/status", token: token, timeout: 10, refuseRedirects: true)') == 1
     and set_fn0.count("PhoneApprovalsCore.onRefusal(status: status?.status, body: status?.body,") == 1
     and set_fn0.count("disclosedName: PhoneApprovalsCore.disclosedName(arguments))") == 1
     and 0 <= set_fn0.find("PhoneApprovalsCore.onRefusal(") < set_fn0.find("PhoneApprovalsCore.environment(change)")
     and 0 <= set_fn0.find("throw HelperError.message(refusal)") < set_fn0.find("ProviderEnvironment(")
     and helpers_all.count("PhoneApprovalsCore.onRefusal(") == 1,
     "phone on helper gate", "set-phone-approvals on reads the server's status and refuses before anything is written; off skips it")
refusal_fn = body_of(core_pa, core_pa.index("static func onRefusal(status: Int?, body: [String: Any]?, disclosedName: String?) -> String?"))
need("guard let fix = integer(body[\"signerBindFixVersion\"]), fix >= requiredFixVersion else { return needsFix }" in refusal_fn
     and "guard (body[\"signerBind\"] as? [String: Any])?[\"scope\"] as? String == tailnetScope else { return needsTailnetBind }" in refusal_fn
     and "if let disclosedName { return disclosedName == name ? nil : disclosureStale }" in refusal_fn
     and 0 <= refusal_fn.find("if let disclosedName")
     and "return issued ? nil : disclosureMissing" in refusal_fn
     and "case .on: return authority && bindFixed" in core_pa,
     "phone on helper gate", "the helper needs the fix, the tailnet bind and the disclosure for the exact name, and proves the bind after the restart")
need('guard let name = (cert?["publicName"] as? String).flatMap(validName) else { return nameUnknown }' in refusal_fn
     and refusal_fn.find("else { return nameUnknown }") < refusal_fn.find("if let disclosedName"),
     "phone on needs the public name", "the helper refuses On when the server's public name is null or malformed, whatever else it says")
proven_fn = body_of(core_pa, core_pa.index("static func proven(_ change: Change, status: Int?, body: [String: Any]?, expectedName: String? = nil) -> Bool"))
need('bind?["scope"] as? String == tailnetScope && bind?["listening"] as? Bool == true' in proven_fn and "case .on: return authority && bindFixed" in proven_fn,
     "phone on proof needs listening", "the post-restart proof needs scope tailnet AND listening true")
step_fn = body_of(core_pa, core_pa.index("static func proofStep(_ change: Change, status: Int?, body: [String: Any]?, expectedName: String? = nil) -> ProofStep"))
need('if bind["scope"] as? String == "none", (bind["reason"] as? String).map(proofWaitReasons.contains) == true { return .wait }' in step_fn
     and 'if bind["scope"] as? String == tailnetScope, bind["listening"] as? Bool == false, bind["reason"] == nil || bind["reason"] is NSNull { return .wait }' in step_fn
     and step_fn.rstrip().endswith("return .fail\n    }")
     and 'static let proofWaitReasons: Set<String> = ["no_tailnet_address", "address_lost", "listen_failed"]' in core_pa
     and "guard change != .off, status == 200" in step_fn and step_fn.count("return .wait") == 2
     and "static let proofWaitSeconds: Double = 45" in core_pa,
     "phone on proof waits for the tailnet", "only no_tailnet_address waits; every other reason fails at once; Off never waits; the wait is 45 s")
# Review C4: the helper keeps the checked public name and the post-restart proof compares it, waiting included.
need(helper.count("phoneApprovalsExpectedName = ") == 1 and set_fn0.count("phoneApprovalsExpectedName = PhoneApprovalsCore.publicName(status?.body)") == 1
     and set_fn0.find("throw HelperError.message(refusal)") < set_fn0.find("phoneApprovalsExpectedName = ") < set_fn0.find("PhoneApprovalsCore.environment(change)")
     and "let sameName = expectedName == nil || publicName(body) == expectedName" in proven_fn
     and "case .on: return authority && bindFixed && sameName" in proven_fn
     and "guard change != .off, status == 200, let body, expectedName == nil || publicName(body) == expectedName," in step_fn
     and "if proven(change, status: status, body: body, expectedName: expectedName) { return .proven }" in step_fn,
     "phone on proof keeps the checked name", "the restarted server must report the public name checked before the restart, or the change rolls back")
# Review C3: the disclosure says only what the server can know.
need("This COS server has no certificate stored for this name yet." in core and "has not asked for a certificate" not in core,
     "phone on disclosure copy", "the disclosure's last sentence says no certificate is stored for this name, nothing more")
# Review C5: all three provider-environment rollbacks go through the phone approvals warning.
warn_fn = body_of(helper, helper.index("private func restoreOrWarnPhoneApprovals(_ values: [String: String], _ restore: () throws -> String) throws -> String"))
need(helper.count("try restoreOrWarnPhoneApprovals(values) {") == 3
     and helper.count("try restoreOrWarnPhoneApprovals(values) { try restoreAfterFailedSwitch(transaction) }") == 1
     and helper.count("try restoreOrWarnPhoneApprovals(values) { try restoreInPlaceConfiguration(transaction) }") == 2
     and "guard PhoneApprovalsCore.warnsOnFailedRollback(values) else { throw error }" in warn_fn
     and 'throw HelperError.message("\\(PhoneApprovalsCore.rollbackFailed) Rollback error: \\(error)")' in warn_fn
     and "static func warnsOnFailedRollback(_ values: [String: String]) -> Bool { change(fromEnvironment: values) != nil }" in core_pa,
     "phone rollback failure says so", "a phone approvals change whose rollback fails says approvals may still be on and how to turn them off")
proof_fn = body_of(helper, helper.index("private func requirePhoneApprovals(_ change: PhoneApprovalsCore.Change) throws"))
need(proof_fn.count("expectedName: change == .off ? nil : phoneApprovalsExpectedName)") == 1
     and proof_fn.count("let deadline = Date().addingTimeInterval(PhoneApprovalsCore.proofWaitSeconds)") == 1
     and proof_fn.count("PhoneApprovalsCore.proofStep(change, status: response?.status, body: response?.body,") == 1
     and "case .wait where Date() < deadline: Thread.sleep(forTimeInterval: PhoneApprovalsCore.proofPollSeconds)" in proof_fn
     and "case .wait, .fail:" in proof_fn and "PhoneApprovalsCore.proven(" not in proof_fn,
     "phone on proof waits for the tailnet", "the post-restart proof polls only while the server waits for its tailnet address, up to the bound, then fails")
unavailable_rows = 'static let unavailableRows: Set<String> = ["PK-01", "PK-02"]'
need(catalog.count(unavailable_rows) == 1 and "!unavailableRows.contains($0.id)" in catalog,
     "phone switch unavailable", "search leaves out PK-01 and PK-02: whether they draw depends on the server, which a static index cannot know")
# The disclosure step: inline in the row (never a sheet), only while choosing before a first certificate, naming the exact
# name; Turn on is disabled until it is agreed, and the confirm carries the agreed name to the one sender.
need(re.search(r"if choosing && !on, let readiness = state\.onReadiness, readiness\.needsDisclosure, let name = readiness\.publicName \{", switch_view_src := body_of(views, views.index("struct PhoneApprovalsSwitchRow: View"))) is not None
     and switch_view_src.count("Text(PhoneApprovalsSwitch.disclosureMessage(name))") == 1
     and switch_view_src.count("Toggle(PhoneApprovalsSwitch.disclosureAgree(name), isOn: Binding(get: { disclosedName == name }, set: { disclosedName = $0 ? name : nil }))") == 1
     and ".toggleStyle(COSCheckStyle())" in switch_view_src
     and "private var disclosureAgreed: Bool { state.onReadiness?.disclosed(disclosedName) == true }" in switch_view_src
     and "if let picked, disclosureAgreed { confirm.shown = onRequest(picked) }" in switch_view_src
     and ".disabled(picked == nil || !disclosureAgreed || !PhoneApprovalsSwitch.applyAllowed(locked: locked, workActive: work.active))" in switch_view_src
     and "model.setPhoneApprovals(on: true, phone: picked, disclosedName: disclosedName)" in switch_view_src
     and ".sheet(" not in views and ".popover(" not in switch_view_src,
     "phone on disclosure", "the disclosure is inline, names the exact name, and Turn on stays disabled until it is agreed")
# Off by default: the toggle never applies anything; only the two confirmations call setPhoneApprovals, and nothing else in
# the helper writes the flag (one allowlist entry, then PhoneApprovalsCore's own constants).
switch_view = body_of(views, views.index("struct PhoneApprovalsSwitchRow: View"))
toggle_at = switch_view.find("Toggle(isOn: Binding(get: { (on && pendingOff == nil) || choosing }")
toggle_end = switch_view.find(".accessibilityLabel(PhoneApprovalsSwitch.label)", toggle_at)
# The row's title follows the switch, off while Off's restart waits (lead 11:40).
need("Text(PhoneApprovalsSwitch.title(on: on && pendingOff == nil))" in switch_view and "Text(PhoneApprovalsSwitch.label)" not in switch_view,
     "phone switch title follows the switch", "the row's title says on only while the server is on and no Off waits")
# The switch draws no second label (COSSwitchStyle ignores .labelsHidden()); VoiceOver keeps the name.
need(0 <= toggle_at and switch_view.count("Toggle(") == 2 and switch_view.count("Toggle(isOn:") == 1 and "})) { EmptyView() }\n                .accessibilityLabel(PhoneApprovalsSwitch.label)" in switch_view,
     "phone switch label once", "the switch has no visible label of its own; the row's title says it, and VoiceOver keeps the name")
need(views.count("model.setPhoneApprovals(") == 2 and switch_view.count("PhoneApprovalsConfirm.Request(") == 2 and 0 <= toggle_at < toggle_end
     and "setPhoneApprovals" not in switch_view[toggle_at:toggle_end]
     and helper.count('"COS_WEB_KEY_AUTHORITY"') == 1 and helper.count('"COS_WEB_KEY_DEVICES"') == 1
     and pairing.count('static let authorityKey = "COS_WEB_KEY_AUTHORITY"') == 1,
     "phone switch off by default", "the switch only opens a step; the confirmations apply it; no default writes the flag")
# Off WRITES COS_WEB_KEY_AUTHORITY=0, and the helper applies exactly what PhoneApprovalsCore.environment says, on both paths.
set_fn = body_of(helper, helper.index("private func setPhoneApprovals(_ arguments: [String]) throws"))
need(pairing.count('case .off: return ([authorityKey: "0"], [devicesKey])') == 1
     and set_fn.count("environment.set, removingKeys: environment.remove") == 2,
     "phone switch off writes 0", "off sets the flag to 0 and removes only the phone list, through both apply paths")
# The helper wiring: one verb under the mutation lock, the server floor, the proof after every apply path.
need(helper.count('case "set-phone-approvals": try withMutationLock { try setPhoneApprovals(Array(args.dropFirst())) }') == 1
     and set_fn.count("versionAtLeast($0, PhoneApprovalsCore.minimumServer)") == 1
     and set_fn.count("versionAtLeast($0.version, PhoneApprovalsCore.minimumServer)") == 1 and set_fn.count("PhoneApprovalsCore.change(arguments)") == 1
     and helper.count("PhoneApprovalsCore.change(fromEnvironment: values)") == 3 and helper.count("try requirePhoneApprovals(phoneApprovals)") == 3,
     "phone switch wiring", "set-phone-approvals parses with PhoneApprovalsCore, checks the server floor, and proves the change on every apply path")
# Like the nine restart rows (Settings Release A): turning ON (the Turn on button and its confirm) asks applyAllowed with the
# panel's own restartWork and serverSettingsLocked, so it never starts while work runs. The third use only draws Off's
# waiting line; it applies nothing.
guard = "PhoneApprovalsSwitch.applyAllowed(locked: locked, workActive: work.active)"
on_lines = [l for l in switch_view.splitlines() if "model.setPhoneApprovals(on: true" in l]
need(switch_view.count(guard) == 3 and len(on_lines) == 1 and on_lines[0].strip().startswith("if " + guard + " { model.setPhoneApprovals(on: true")
     and ".accessibilityLabel(PhoneApprovalsSwitch.label).toggleStyle(COSSwitchStyle()).disabled(locked || pendingOff != nil)" in switch_view
     and phone.count("work: restartWork, locked: serverSettingsLocked, confirm: phoneConfirm) }") == 1,
     "phone switch waits for work", "turning on waits for running work, with the panel's restartWork")
# Option A (lead ruling 2026-11-12 10:32): Off never asks applyAllowed. The toggle opens the confirm, the confirm runs
# PhoneApprovalsOff.run, and its Revoke all comes before the only applyAllowed in the Off code, the =0 restart's (resume).
off_section = body_of(core, core.index("enum PhoneApprovalsOff {"))
run_fn = body_of(off_section, off_section.index("@MainActor static func run("))
need("applyAllowed" not in switch_view[toggle_at:toggle_end] and ".destructive(PhoneApprovalsSwitch.confirmOff) { turnOff() }" in switch_view
     and "applyAllowed" not in body_of(switch_view, switch_view.index("private func turnOff()"))
     and "applyAllowed" not in run_fn and 0 <= run_fn.find("await revokeAll()") < run_fn.find("resume(")
     and off_section.count("PhoneApprovalsSwitch.applyAllowed(") == 1,
     "phone off revokes at once", "the Off toggle, its confirm and Off's Revoke all never ask applyAllowed; only the =0 restart waits")
# Devices: a phone's Revoke and Revoke all are live calls, never behind the running-work guard.
revoke_fn = body_of(core, core.index("    func revoke(_ kid: String) async -> Bool {"))
revoke_all_fn = body_of(core, core.index("    func revokeAll() async -> Bool {"))
need(views.count("Button(WebKeyCopy.revoke) { Task { await state.revoke(row.kid) } }.buttonStyle(COSTextButtonStyle()).disabled(state.busy)") == 1
     and views.count('.destructive("Revoke all") { Task { await state.revokeAll() } }') == 1
     and not any(w in revoke_fn + revoke_all_fn for w in ("applyAllowed", "workActive", "restartWork")),
     "devices revoke is live", "a phone's Revoke and Revoke all are live calls, never behind the running-work guard")
# Security review 2026-11-12, blocker 2: neither revoke returns before the server call for want of an anchor or a saved
# record. The only early return is the authority/visible/busy guard; the server call is unconditional after it.
need(all(fn.count("return false") == 1 and "if let anchor {" in fn and "guard let anchor" not in fn and "local.saved else" not in fn
         for fn in (revoke_fn, revoke_all_fn)) and "stay off" not in body_of(core, core.index("enum WebKeyRevokeOutcome {")).replace(
         'case (false, true): return "Revoked in Control. The server did not confirm, so phone approvals stay off until it does."', ""),
     "revoke needs no anchor", "revoke and revoke-all call the server in every case, and only a saved record may say approvals stay off")
# PK-02's two confirms are drawn by the page (lead 10:47), like the server confirms: the row draws none, the panel one.
phone_stage = body_of(main_views, main_views.index("private var panelWithPhoneConfirm: some View {"))
need(".cosConfirm(" not in switch_view and "phoneConfirm.shown?.actions ?? [.cancel()]" in phone_stage and "panelWithServerConfirm" in phone_stage
     and main_views.count("    var body: some View {\n        panelWithPhoneConfirm\n") == 1
     and main_views.count("@StateObject private var phoneConfirm = PhoneApprovalsConfirm()") == 1,
     "phone confirm at the page", "PK-02's confirms are drawn at the page, never inside the row")
# Condition 4: Off touches nothing that enrolls or approves a phone, so enrolling keeps today's Touch ID and code.
need(not any(t in off_section for t in ("approve(", "startApproval", "typedCode", ".card", "WebKeyApproveGate")),
     "phone off keeps enrollment gated", "Off never touches enrollment or approval; enrolling keeps its Touch ID and code")
# The render seed (Tests/PhoneApprovalsRender.swift) is fixture-only: background work off, and nothing in Sources calls it.
seed_fn = body_of(views, views.index("    static func renderFixture(model: ControllerModel, state: WebKeyState"))
sources_all = "".join(p.read_text(encoding="utf-8") for p in sorted((root / "Sources").glob("*.swift")))
need(seed_fn.count("precondition(!model.backgroundWorkEnabled)") == 1 and sources_all.count("renderFixture(model: ControllerModel, state: WebKeyState") == 1
     and sources_all.count("PhoneApprovalsSwitchRow.renderFixture(") == 0 and "setPhoneApprovals" not in seed_fn,
     "phone switch render seed", "the render seed needs background work off, applies nothing, and nothing in the app calls it")
# The renders Miles reviews draw the Phone and web card in the app's order: UT-29, PK-02, PK-01, WB-01.
render_card = body_of(code("Tests/PhoneApprovalsRender.swift"), code("Tests/PhoneApprovalsRender.swift").index("struct PhoneCard: View {"))
render_order = [render_card.find(s) for s in ("PhoneSignInBlock(", "SettingsHubBlock { row }", "WebKeySettingsBlock(", "SettingsHubWebRevokeRow(")]
app_order = [phone.find(s) for s in ('.settingsHubAnchor("UT-29")', '.settingsHubAnchor(PhoneApprovalsSwitch.anchorID(', '.settingsHubAnchor("PK-01")', "SettingsHubWebRevokeRow(")]
need(all(i >= 0 for i in render_order + app_order) and render_order == sorted(render_order) and app_order == sorted(app_order),
     "phone switch render order", "the render's Phone and web card and the app's both run UT-29, PK-02, PK-01, WB-01")
# 0.5.390: the server's not-trusted reason codes live in ONE Swift list, WebKeySignerTLS.sentences (copied from the server's
# SignerTlsReason; file and line in PK-C_report.md). No second table, the checks read the list, unknown codes fall back.
sent_at = core.find("static let sentences: [String: String] = [")
sent_open = core.find("= [", sent_at) + 3 if sent_at >= 0 else -1
sent_end = core.find("\n    ]\n", sent_open) if sent_open > 2 else -1
sent_src = core[sent_open:sent_end] if sent_end > sent_open else ""
codes = re.findall(r'^\s*"([a-z_]+)":', sent_src, flags=re.M)
# Outside the list a code may appear only in uses that are not a reason: "pending" is also a helper op and a body key.
outside = (core[:sent_open] + core[sent_end:] + views) if sent_src else ""
not_reasons = {"pending": ['ask("pending")', 'answer.body["pending"]']}
stray = [c for c in codes if outside.count(f'"{c}"') != sum(outside.count(u) for u in not_reasons.get(c, []))]
need(len(codes) >= 13 and len(set(codes)) == len(codes) and all((core + views).count(f'"{c}":') == 1 for c in codes) and not stray,
     "signer reasons one list", f"each of the {len(codes)} codes is written once, as a key of WebKeySignerTLS.sentences, and nowhere else (stray: {stray})")
line_fn = body_of(core, core.index("static func line(_ reason: String?) -> String"))
need("sentences[$0]" in line_fn and line_fn.count("?? fallback") == 1 and "switch" not in line_fn and "case " not in line_fn,
     "signer reasons one list", "line() looks the code up in the list and otherwise falls back")
checks_src = code("Tests/WebKeyChecks.swift")
need(checks_src.count("let reasons = Array(WebKeySignerTLS.sentences.keys)") == 1 and 'line("made_up_reason_7020") == WebKeySignerTLS.fallback' in checks_src,
     "signer reasons one list", "the checks read the codes from the list, never a copy, and try a made-up code")
# SR-11 (2026-11-11): golden.json carries the SERVER's reason list, written by the generator from the server module.
gen = (root / "Tests/fixtures/web-key/gen_control_golden.mts").read_text(encoding="utf-8")
need(checks_src.count("        reasonParity(g)\n") == 1 and "signerTlsReasons: [...signerTls.SIGNER_TLS_REASONS]," in gen
     and "server/lib/web-key-signer-tls.ts" in gen,
     "signer reasons match the server", "the generator writes the server's SIGNER_TLS_REASONS into golden.json and the checks compare it")
# Any tailnet name other than the neutral tail00000a is treated as real; the pin never spells a real one out.
private_name = re.compile(r"\btail(?!00000a\b)[0-9a-z]{6}\b|ukaoma", re.I)
need(private_name.search(checks_src) is None,
     "no private names in tests", "this repo is public: no real tailnet or Mac name in the checks")
# SR-12 (reopen): the same for every text fixture of this lane, golden.json included.
fixture_files = sorted(p for p in (root / "Tests/fixtures/web-key").rglob("*") if p.is_file() and p.suffix in {".json", ".txt", ".pem", ".mts", ".md"})
named = [str(p.relative_to(root)) for p in fixture_files if private_name.search(p.read_text(encoding="utf-8", errors="replace"))]
need(fixture_files and not named, "no private names in tests", f"no real tailnet or Mac name in Tests/fixtures/web-key (found in: {named})")
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
