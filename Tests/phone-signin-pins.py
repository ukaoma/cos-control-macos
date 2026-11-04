#!/usr/bin/env python3
"""0.5.367 (server 6.99.3) Open COS on your phone: the wiring pins. python3 Tests/phone-signin-pins.py [root]

What these pin that the executed checks (Tests/PairingCoreChecks.swift for WebSignInCore, Tests/ProviderConnectChecks.swift for
PhoneSignInRules and PhoneSignInState, Tests/web-signin-helper-checks.py for the compiled verbs) cannot see: the helper verbs
dispatched, behind Copy token's exact managed-server check, posting over loopback with the token and passing only
WebSignInCore's answer; no link, ticket or code in a progress line, log or message; the app reaching them through the model's
inert-in-checks helper (never model.perform, never the pasteboard); the QR image never cached; the row on screen only while its
window is (the GlassesWindowHolder gate) and mounted once, for every device path, in Devices with its search anchor; the
glasses pairing QR unchanged; the catalog row; the copy; the version touchpoints; the lanes wired. Comments are stripped first,
so an explanatory comment can never satisfy a pin. Each failure names its behaviour as "phone pin FAILED [<behaviour>]" for the
mutation pass. Prints "phone sign-in pins: N passed".
"""
import json, pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent)
passed = 0


def need(condition, behaviour, what):
    global passed
    if not condition:
        print(f"phone pin FAILED [{behaviour}]: {what}")
        sys.exit(1)
    passed += 1


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.split("\n"))


def code(rel):
    return strip_comments((root / rel).read_text(encoding="utf-8"))


def body(text, signature):
    need(signature in text, "source shape", f"cannot find {signature!r}")
    i = text.index(signature)
    depth, j, started = 0, i, False
    while j < len(text):
        if text[j] == "{":
            depth += 1; started = True
        elif text[j] == "}":
            depth -= 1
            if started and depth == 0:
                return text[i:j + 1]
        j += 1
    return text[i:]


helper = code("HelperSources/main.swift")
core = code("HelperSources/PairingCore.swift")
model_file = code("Sources/ProviderConnectModel.swift")
views_file = code("Sources/ProviderConnectViews.swift")
controller = code("Sources/ControllerModel.swift")
panel = code("Sources/Views.swift")
catalog = code("Sources/SettingsHubCatalog.swift")
run_sh = (root / "Tests/run.sh").read_text(encoding="utf-8")

# ── The helper verbs.
need('case "web-handoff": try emitWebSignIn(handoff: true)' in helper and 'case "web-device-code": try emitWebSignIn(handoff: false)' in helper,
     "verbs dispatched", "web-handoff and web-device-code are dispatched")
verb = body(helper, "private func emitWebSignIn(handoff: Bool) throws {")
gate = "runtimeState(snapshot: ownershipSnapshot(), maintenance: maintenanceStatus(), health: request(\"/api/health\", timeout: 12)?.body) == .managedHealthy"
copy_token = body(helper, "private func copyPairingToken() throws {")
need("guard " + gate + " else {" in copy_token and "guard " + gate + " else {" in verb, "copy token gate", "the verbs run Copy token's own managed-server check, as the whole guard")
need(verb.index(gate) < verb.index("readToken()") < verb.index("request(handoff ?"), "copy token gate", "the check comes before the token and the request")
need('emit(ok: true, message: "The COS server is not verified yet", details: ["transport": "not_ready"])' in verb, "not ready",
     "an unverified server is an answer the app words")
need('request(handoff ? WebSignInCore.handoffPath : WebSignInCore.deviceCodePath, method: "POST", token: token, timeout: 8)' in verb,
     "loopback post", "a POST with the token and no body to the route WebSignInCore names")
need("body:" not in verb.split("request(handoff ?", 1)[1].split("\n", 1)[0], "loopback post", "no body")
need("WebSignInCore.handoffAnswer(status: response.status, body: response.body)" in verb
     and "WebSignInCore.deviceCodeAnswer(status: response.status, body: response.body)" in verb, "only the core's answer",
     "the details are WebSignInCore's, nothing of the body directly")
need(verb.count("emit(") == 4 and "response.body ?? " not in verb and "\"body\":" not in verb, "only the core's answer", "four answers, none passing the body through")
need("progress(" not in verb and "writePasteboard" not in verb and "print(" not in verb and "FileHandle" not in verb, "no secret out",
     "no progress line, pasteboard or other output")
need('"transport": "no_token"' in verb and '"transport": "unavailable"' in verb, "transports", "no token and no answer are answers")
need('static let handoffPath = "/api/web-session/handoff"' in core and 'static let deviceCodePath = "/api/web-session/device-code"' in core,
     "routes", "the two routes")
handoff_answer = body(core, "static func handoffAnswer(status: Int, body: [String: Any]?) -> [String: Any] {")
need('out["phoneUrl"] = link' in handoff_answer and '"url"' not in handoff_answer and '"tailnet"' not in handoff_answer
     and 'out["ticket"]' not in handoff_answer, "one link", "only phoneUrl crosses, never url, tailnet or the ticket")
need('guard body.keys.contains("phoneUrl") else { out["phone"] = "needs_update"; return out }' in handoff_answer
     and 'if body["phoneUrl"] is NSNull { out["phone"] = "no_tailnet"; return out }' in handoff_answer, "old server",
     "a missing phoneUrl is an old server, a null one is no tailnet")
need('static func transport(status: Int) -> String { status == 404 ? "unsupported" : "answered" }' in core, "404", "a 404 needs a newer server")

# ── The app: the model's helper, the state, the row.
factory = body(controller, "private func makePhoneSignIn() -> PhoneSignInState {")
pairing_factory = body(controller, "private func makeGlassesPairing() -> GlassesPairingState {")
guard = 'guard bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier != nil, backgroundWorkEnabled else { return state }'
need(guard in factory and guard.replace("state }", "pairing }") in pairing_factory, "inert in checks", "the same guard as the glasses pairing")
need("try await helper.run(arguments, timeout: 40)" in factory and "perform(" not in factory, "helper path",
     "the helper runs directly, not through model.perform (no notice, no busy)")
need("lazy var phoneSignIn: PhoneSignInState = makePhoneSignIn()" in controller, "helper path", "one state on the model")
need('model.perform("web-' not in panel + views_file + controller and "web-handoff" not in panel, "helper path", "never through perform")
state = body(model_file, "final class PhoneSignInState: ObservableObject {")
need(re.findall(r"\blog\(([^)]*)\)", state) == ["stage"], "log stages only", f"the one log call passes the stage name: {re.findall(r'log[(]([^)]*)[)]', state)}")
need('let stage = "\\(verb) \\(PhoneSignInRules.stage(result))"' in state, "log stages only", "a stage is the verb and the stage name")
need("UserDefaults" not in state and "write(" not in state and "FileManager" not in state, "never saved", "nothing is saved")
need('await ask("web-handoff", code: false)' in state and 'await ask("web-device-code", code: true)' in state, "helper path", "each verb once")
row = body(views_file, "struct PhoneSignInRow: View {")
need('QRCodeView(text: handoff.url, side: 228, label: "Sign-in QR for Safari on your iPhone", cached: false)' in row, "qr not cached",
     "the phone QR skips the image cache, at the glasses QR's size")
make = body(views_file, "static func make(_ text: String, cached: Bool = true) -> NSImage? {")
need("if cached, let hit = cache[text] { return hit }" in make and "guard cached else { return result }" in make
     and make.index("guard cached else { return result }") < make.index("cache[text] = result"), "qr not cached", "an uncached QR is never read from or put in the cache")
need("QRImage.make(text, cached: cached)" in views_file, "qr not cached", "QRCodeView passes its switch")
need('QRCodeView(text: qr, side: 228, label: "Pairing code \\(code.display)").frame(maxWidth: .infinity)' in views_file
     and 'Text("Hold your phone so the code fills the screen")' in views_file, "glasses unchanged", "the glasses pairing QR and its words")
need("await state.run(visible: { [model, windowHolder] in windowHolder.onScreen(panelVisible: model.panelVisible) })" in row
     and ".background(WindowProbe(holder: windowHolder))" in row and "guard polls else { return }" in row, "visible only",
     "the row asks only while its window is on screen")
need("sheet" not in row and "popover" not in row and "alert(" not in row, "inline", "no sheet, popover or alert")
need(".disabled(state.codeBusy)" in row and ".disabled(state.minting)" in row, "buttons", "each button waits for its own call")
need("PhoneSignInRules.left(code.expiresAt.timeIntervalSince(state.clock))" in row and "COSType.mono(24, weight: .bold)" in row,
     "code big", "the code big in mono with its countdown")
for banned in (".tracking(", ".kerning(", ".textCase(", "uppercased()"):
    need(banned not in row, "no eyebrow", f"no {banned} in the row")

# ── Mounted once, in Devices, for every device path, with its search anchor.
glasses = body(panel, "@ViewBuilder var hubGlasses: some View {")
need(panel.count("PhoneSignInRow(") == 1 and glasses.count("PhoneSignInRow(") == 1, "mounted once", "the row is drawn once, on Glasses and iPhone")
devices = glasses.split("} advanced: {", 1)[0]
need("PhoneSignInRow(model: model, state: model.phoneSignIn, besideGlasses: voiceGuide.devicePath == .glasses)" in devices, "mounted once",
     "in Devices, not Advanced, and told when the glasses rows show")
cond = body(devices, "if voiceGuide.devicePath == .glasses {")
need("PhoneSignInRow(" not in cond, "every path", "the row is outside the glasses-only block")
need('.settingsHubAnchor("UT-29")' in devices, "search lands", "search lands on the row")
item = re.search(r'\.init\("UT-29", "Open COS on your phone", "Scan with your iPhone camera\. Safari opens COS already signed in\.", old: "", group: "glasses\.devices",\s*advanced: false, mount: \.group, keywords: \[([^\]]*)\]\)', catalog)
need(item is not None, "catalog row", "UT-29 in Devices, not Advanced, with the row's words")
keywords = set(re.findall(r'"([^"]+)"', item.group(1))) if item else set()
need({"phone", "browser", "sign in", "web", "qr", "control web"} <= keywords, "catalog row", f"the keywords {sorted(keywords)}")
need(catalog.index('.init("UT-29"') > catalog.index("static let extras: [SettingsHubItem] = [")
     and catalog.index('.init("UT-29"') < catalog.index("static let items: [SettingsHubItem] = ["), "catalog row", "a hub row, outside the 253 the inventory lists")

# ── The copy.
rules = body(model_file, "enum PhoneSignInRules {")
words = dict(re.findall(r'static let (\w+) = "([^"]*)"', rules))
need(words.get("title") == "Open COS on your phone", "copy", "the title the web page names")
need(words.get("subtitle") == "Scan with your iPhone camera. Safari opens COS already signed in.", "copy", "the subtitle")
need(words.get("qrNote") == "Works once, for 2 minutes. Only on your tailnet.", "copy", "under the QR")
need(words.get("codeNote") == "Type this on the sign-in page. Works once, for 5 minutes.", "copy", "under the code")
need(words.get("showCode") == "Show a sign-in code" and words.get("newQR") == "Show a new QR", "copy", "the buttons")
need(words.get("noTailnet") == "Turn on Tailscale on this Mac." and words.get("needsUpdate") == "Update the server to use this.", "copy", "the two lines instead of a QR")
for name, text in words.items():
    need(not re.search("[—–→]|->", text), "copy", f"no em dash, en dash or arrow: {name}")
need("static let refreshAfter: TimeInterval = 90" in rules, "refresh 90", "a new link about every 90 seconds")

# ── Version touchpoints and the lanes.
plist = (root / "Resources/Info.plist").read_text()
short = re.search(r"<key>CFBundleShortVersionString</key>\s*<string>([0-9.]+)</string>", plist)
build = re.search(r"<key>CFBundleVersion</key>\s*<string>(\d+)</string>", plist)
need(short is not None and build is not None and tuple(map(int, short.group(1).split("."))) >= (0, 5, 367) and int(build.group(1)) >= 421,
     "version", "Info.plist is 0.5.367 (build 421) or later")
whats = json.loads((root / "Resources/WhatsNew.json").read_text())
sec = [s for s in whats["whatsNew"]["sections"] if s["title"] == "0.5.367"]
need(len(sec) == 1 and any("Open COS on your phone" in i for i in sec[0]["items"]), "version", "What's New keeps one 0.5.367 section naming the row")
need("\n## 0.5.367 (build 421)" in "\n" + (root / "CHANGELOG.md").read_text(), "version", "the changelog keeps its 0.5.367 (build 421) entry")
need('python3 "$ROOT/Tests/web-signin-helper-checks.py" "$TMP/cos-control-helper"' in run_sh and 'python3 "$ROOT/Tests/phone-signin-pins.py" "$ROOT"' in run_sh,
     "lanes wired", "Tests/run.sh runs the helper checks and these pins")

print("phone sign-in pins: %d passed" % passed)
