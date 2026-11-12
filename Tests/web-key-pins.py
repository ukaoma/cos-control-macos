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
     and "guard served != .off, let suppliedOrigin" in refresh_fn and 'else { clear(); return }' in refresh_fn, "hidden unless the flag",
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
need("tail38457f" not in checks_src and "ukaoma" not in checks_src.lower(),
     "no private names in tests", "this repo is public: no real tailnet or Mac name in the checks")
# SR-12 (reopen): the same for every text fixture of this lane, golden.json included.
fixture_files = sorted(p for p in (root / "Tests/fixtures/web-key").rglob("*") if p.is_file() and p.suffix in {".json", ".txt", ".pem", ".mts", ".md"})
named = [str(p.relative_to(root)) for p in fixture_files if re.search(r"tail38457f|ukaoma", p.read_text(encoding="utf-8", errors="replace"), re.I)]
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
