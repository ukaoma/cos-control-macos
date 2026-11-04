#!/usr/bin/env python3
"""0.5.367 Open COS on your phone: the mutation pass. Serial, every compile through Tests/compile-guard.sh, never run by
Tests/run.sh (one helper compile per helper mutant).

Usage: mutate-phone-signin.py [<repo root>]. A green baseline of every suite comes first and the run stops on a red one. Each
mutant must be applied exactly once, must fail its suite, and is attributed to the check or pin that names the behaviour
("check failed [<behaviour>]", "phone pin FAILED [<behaviour>]"). Sources are restored after each, and the run says so.
MUTATE_ONLY="a|b" runs only the mutants whose names contain one of the parts (the baseline still runs first).
"""
import os, pathlib, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1])
scratch = tempfile.mkdtemp(prefix="cos-mutate-phone-", dir="/tmp")
helper_out = os.path.join(scratch, "cos-control-helper")
os.environ.setdefault("COS_TEST_KIT_DIR", os.path.join(scratch, "kits"))
env = dict(os.environ)
def sh(cmd):
    r = subprocess.run(cmd, cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, shell=True)
    return r.returncode, r.stdout
PURE = "zsh Tests/run-pairing.sh"
APP = "zsh Tests/run-provider-connect.sh"
HUB = "zsh Tests/run-settings-hub.sh"
PINS = "python3 Tests/phone-signin-pins.py ."
HELPER = (f'/usr/bin/python3 Tests/kit-compile.py Tests/compile-guard.sh swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete '
          f'HelperSources/main.swift HelperSources/ProviderStatusCore.swift HelperSources/PairingCore.swift HelperSources/SessionUsageCollector.swift '
          f'Sources/SessionUsageCore.swift Sources/WorkSessionLinks.swift -framework Security -framework AppKit -o {helper_out} >/dev/null 2>&1 '
          f'&& python3 Tests/web-signin-helper-checks.py {helper_out}')
C, H, M, V, P, K = ("HelperSources/PairingCore.swift", "HelperSources/main.swift", "Sources/ProviderConnectModel.swift",
                    "Sources/ProviderConnectViews.swift", "Sources/Views.swift", "Sources/SettingsHubCatalog.swift")
GATE = 'guard runtimeState(snapshot: ownershipSnapshot(), maintenance: maintenanceStatus(), health: request("/api/health", timeout: 12)?.body) == .managedHealthy else {\n            emit(ok: true, message: "The COS server is not verified yet"'
mutants = [
 # The helper's answers (pure).
 ("C1 a 404 reads as an answer", C, 'static func transport(status: Int) -> String { status == 404 ? "unsupported" : "answered" }', 'static func transport(status: Int) -> String { "answered" }', PURE, "[web 404]"),
 ("C2 any host goes in the QR", C, "let host = parts.host, TailscaleCore.isTailnet(host) || tailnetName(host),", "let host = parts.host, !host.isEmpty,", PURE, "[web handoff link shape]"),
 ("C3 any page goes in the QR", C, '              parts.path == "/control",\n', "", PURE, "[web handoff link shape]"),
 ("C4 extra query items go in the QR", C, 'let items = parts.queryItems, items.count == 1, items[0].name == "handoff",', 'let items = parts.queryItems, items[0].name == "handoff",', PURE, "[web handoff link shape]"),
 ("C5 another ticket's link goes in the QR", C, "        return ticket.map { $0 == value } ?? true\n", "        return true\n", PURE, "[web handoff ticket match]"),
 ("C6 an old server reads as no tailnet", C, 'guard body.keys.contains("phoneUrl") else { out["phone"] = "needs_update"; return out }', 'guard body.keys.contains("phoneUrl") else { out["phone"] = "no_tailnet"; return out }', PURE, "[web handoff old server]"),
 ("C7 the loopback url crosses", C, '        out["phoneUrl"] = link\n', '        out["phoneUrl"] = link\n        out["url"] = body["url"]\n', PURE, "[web handoff only the link]"),
 ("C8 any code shape crosses", C, r'code.range(of: #"\A[0-9A-Z]{4}-[0-9A-Z]{4}\z"#, options: .regularExpression) != nil,', "!code.isEmpty,", PURE, "[web code shape]"),
 ("C9 server text crosses as a code", C, r'if let text = body?[key] as? String, text.range(of: #"\A[a-z_]{1,64}\z"#, options: .regularExpression) != nil { return text }', "if let text = body?[key] as? String { return text }", PURE, "[web refusal]"),
 # The helper verb (pins, and the compiled helper against a fixture).
 ("H1 no managed-server check (pins)", H, GATE, GATE.replace("guard runtimeState(", "guard true || runtimeState("), PINS, "[copy token gate]"),
 ("H2 no managed-server check (compiled helper)", H, GATE, GATE.replace("guard runtimeState(", "guard true || runtimeState("), HELPER, "nothing reaches /api/web-session/*"),
 # The app's rules and state.
 ("A1 a new link only after 120 s", M, "    static let refreshAfter: TimeInterval = 90\n", "    static let refreshAfter: TimeInterval = 120\n", APP, "[phone refresh 90]"),
 ("A2 no margin before the end", M, " || handoff.expiresAt.timeIntervalSince(now) <= expiryMargin", "", APP, "[phone expiry margin]"),
 ("A3 a failure retries at once", M, "        if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryAfter { return false }\n", "", APP, "[phone retry]"),
 ("A4 a failed refresh leaves the old QR up", M, "        case .line(let text, let retry):\n            handoff = nil\n            line = text", "        case .line(let text, let retry):\n            line = text", APP, "[phone failure clears]"),
 ("A5 an expired QR stays up", M, "        if let current = handoff, current.expiresAt <= t { handoff = nil }\n", "", APP, "[phone expired]"),
 ("A6 a link answered after hide shows", M, "        let result = await ask(\"web-handoff\", code: false)\n        guard started == generation else { droppedReplies += 1; return }\n", "        let result = await ask(\"web-handoff\", code: false)\n", APP, "[phone in flight]"),
 ("A7 hide keeps the code", M, "        line = nil\n        code = nil\n        codeLine = nil\n        lastAttempt = nil", "        line = nil\n        codeLine = nil\n        lastAttempt = nil", APP, "[phone hide]"),
 ("A8 asks while hidden", M, "            if visible() { await tick() } else if holdsAnything { hide() }", "            if true { await tick() } else if holdsAnything { hide() }", APP, "[phone visibility]"),
 ("A9 the task's end keeps the link", M, "        defer { hide() }\n        while !Task.isCancelled {\n            if visible()", "        while !Task.isCancelled {\n            if visible()", APP, "[phone task end]"),
 ("A10 an expired code stays up", M, "        if let current = code, current.expiresAt <= t { code = nil }\n", "", APP, "[phone code expiry]"),
 ("A11 an old server is asked every 10 s", M, '        case "needs_update": return .line(needsUpdate, retry: updateRetryAfter)', '        case "needs_update": return .line(needsUpdate, retry: retryAfter)', APP, "[phone old server]"),
 ("A12 an expired link answer is shown", M, '            guard let link = PairingJSON.string(details["phoneUrl"]), let at = PairingJSON.date(details["expiresAt"]), at > now else {',
  '            guard let link = PairingJSON.string(details["phoneUrl"]), let at = PairingJSON.date(details["expiresAt"]) else {', APP, "[phone expired answer]"),
 ("A13 the log carries the link (app)", M, "        if stage != lastStage { log(stage); lastStage = stage }", "        if stage != lastStage { log(stage + \" \" + (handoff?.url ?? \"\")); lastStage = stage }", APP, "[phone log]"),
 ("A14 the log carries the link (pins)", M, "        if stage != lastStage { log(stage); lastStage = stage }", "        if stage != lastStage { log(stage + \" \" + (handoff?.url ?? \"\")); lastStage = stage }", PINS, "[log stages only]"),
 ("A15 a no-tailnet answer reads unreadable", M, '        case "no_tailnet": return .line(noTailnet, retry: retryAfter)\n', "", APP, "[phone no tailnet]"),
 # The row, the QR image and the hub (pins and the hub's checks).
 ("V1 the phone QR is cached", V, 'label: "Sign-in QR for Safari on your iPhone", cached: false)', 'label: "Sign-in QR for Safari on your iPhone", cached: true)', PINS, "[qr not cached]"),
 ("V2 the image cache ignores its switch", V, "        if cached, let hit = cache[text] { return hit }\n", "        if let hit = cache[text] { return hit }\n", PINS, "[qr not cached]"),
 ("V3 the image is stored when uncached", V, "        guard cached else { return result }\n", "", PINS, "[qr not cached]"),
 ("V4 the row asks while its window is hidden", V, "windowHolder.onScreen(panelVisible: model.panelVisible) })", "true })", PINS, "[visible only]"),
 ("V5 search lands on the card, not the row", P, '            .settingsHubAnchor("UT-29")\n', "", PINS, "[search lands]"),
 ("V6 the row only on the glasses path", P,
  '            SettingsHubBlock { SetupDeviceChoice(guide: model.setupGuide) }\n            // UT-29',
  '            SettingsHubBlock { SetupDeviceChoice(guide: model.setupGuide) }\n            if voiceGuide.devicePath == .glasses {\n            // UT-29', PINS, "[every path]"),
 ("V7 the row under Advanced (pins)", K, 'group: "glasses.devices",\n              advanced: false, mount: .group, keywords: ["phone"', 'group: "glasses.devices",\n              advanced: true, mount: .group, keywords: ["phone"', PINS, "[catalog row]"),
 ("V8 the row under Advanced (hub checks)", K, 'group: "glasses.devices",\n              advanced: false, mount: .group, keywords: ["phone"', 'group: "glasses.devices",\n              advanced: true, mount: .group, keywords: ["phone"', HUB, "Open COS on your phone is a Devices row, not Advanced"),
 ("V9 search misses Control Web", K, '"qr", "control web", "safari"', '"qr", "safari"', HUB, "search finds Open COS on your phone by Control Web"),
# 0.5.368: the Camera's QR first, and both QRs say where they work (Miles 2026-11-04, 09:05).
 ("Q1 the glasses rows come before the phone row", P,
  '            SettingsHubBlock {\n                PhoneSignInRow(model: model, state: model.phoneSignIn, besideGlasses: voiceGuide.devicePath == .glasses)\n            }\n            .settingsHubAnchor("UT-29")\n            if voiceGuide.devicePath == .glasses {\n                SettingsHubBlock {\n                    GlassesSetupRows(model: model, pairing: model.glassesPairing, openURL: { _ = model.providerGuide.openURL($0) })\n                }\n                hubButton("SG-13", "Get the app") { _ = model.providerGuide.openURL(GuideExtras.glassesWizardURL) }\n            }\n',
  '            if voiceGuide.devicePath == .glasses {\n                SettingsHubBlock {\n                    GlassesSetupRows(model: model, pairing: model.glassesPairing, openURL: { _ = model.providerGuide.openURL($0) })\n                }\n                hubButton("SG-13", "Get the app") { _ = model.providerGuide.openURL(GuideExtras.glassesWizardURL) }\n            }\n            SettingsHubBlock {\n                PhoneSignInRow(model: model, state: model.phoneSignIn, besideGlasses: voiceGuide.devicePath == .glasses)\n            }\n            .settingsHubAnchor("UT-29")\n',
  PINS, "[qr order]"),
 ("Q2 the render draws the old order", "Tests/PhoneSignInRender.swift",
  '                SettingsHubBlock { PhoneSignInRow(model: model, state: model.phoneSignIn, besideGlasses: true, polls: false) }\n                SettingsHubBlock { GlassesSetupRows(model: model, pairing: model.glassesPairing, openURL: { _ in }, polls: false) }\n',
  '                SettingsHubBlock { GlassesSetupRows(model: model, pairing: model.glassesPairing, openURL: { _ in }, polls: false) }\n                SettingsHubBlock { PhoneSignInRow(model: model, state: model.phoneSignIn, besideGlasses: true, polls: false) }\n',
  PINS, "[qr order]"),
 ("Q3 the phone subtitle says scan again (pins)", M, '"Point your iPhone Camera here. Safari opens COS already signed in."', '"Scan with your iPhone camera. Safari opens COS already signed in."', PINS, "[copy]"),
 ("Q4 the phone subtitle says scan again (checks)", M, '"Point your iPhone Camera here. Safari opens COS already signed in."', '"Scan with your iPhone camera. Safari opens COS already signed in."', APP, "[phone copy]"),
 ("Q5 the note still says the glasses QR is above", M, '"The QR below is for the COS Glasses app, not the Camera."', '"This QR is for Safari. The one in Connect your glasses is for the COS app."', PINS, "[copy]"),
 ("Q6 the pairing caption loses the app (pins)", M, 'static let pairCaption = "Open the COS Glasses app, then hold your phone so the code fills the screen."', 'static let pairCaption = "Hold your phone so the code fills the screen"', PINS, "[glasses QR labeled]"),
 ("Q7 the pairing caption loses the app (checks)", M, 'static let pairCaption = "Open the COS Glasses app, then hold your phone so the code fills the screen."', 'static let pairCaption = "Hold your phone so the code fills the screen"', APP, "[glasses qr copy]"),
 ("Q8 the pairing row says COS app again", M, 'unlocks: GlassesRules.pairSubtitle,', 'unlocks: "Scan the code with the COS app on your phone. Nothing to type.",', APP, "[glasses qr copy]"),
 ("Q9 the caption is a literal again", V, '            Text(GlassesRules.pairCaption)\n', '            Text("Hold your phone so the code fills the screen")\n', PINS, "[glasses QR labeled]"),
 ("Q10 the pairing QR loses Show a new code", V, '''            HStack(spacing: 12) {
                Button("Show a new code") { Task { await pairing.showNewCode() } }.buttonStyle(COSTextButtonStyle())
                Spacer(minLength: 0)
            }
            lanToggle
''', "            lanToggle\n", PINS, "[glasses QR labeled]"),
 ("Q11 the catalog keeps the old subtitle", K, '"Point your iPhone Camera here. Safari opens COS already signed in.", old: ""', '"Scan with your iPhone camera. Safari opens COS already signed in.", old: ""', PINS, "[catalog row]"),
]
# V6 (0.5.368 order: the row above the glasses block) opens the glasses block before the row and drops its own opening line, so
# the block encloses the row and still compiles.
fixed = []
for m in mutants:
    if m[0].startswith("V6"):
        name, path, old, new, cmd, expect = m
        src = (root / path).read_text()
        tail_old = '            .settingsHubAnchor("UT-29")\n            if voiceGuide.devicePath == .glasses {\n'
        mid = src.split(old, 1)[1].split(tail_old, 1)[0] if src.count(old) == 1 and tail_old in src else None
        fixed.append((name, path, old + mid + tail_old, new + mid + '            .settingsHubAnchor("UT-29")\n', cmd, expect) if mid is not None else m)
    else:
        fixed.append(m)
mutants = fixed
only = [part for part in os.environ.get("MUTATE_ONLY", "").split("|") if part]
if only: mutants = [m for m in mutants if any(part in m[0] for part in only)]
needed = {m[4] for m in mutants}
for name, cmd in (("pure", PURE), ("app", APP), ("hub", HUB), ("pins", PINS), ("helper", HELPER)):
    if cmd not in needed: continue
    code, out = sh(cmd)
    if code != 0: print(f"BASELINE RED ({name}):\n{out[-3000:]}"); sys.exit(1)
    print(f"baseline {name}: green ({out.strip().splitlines()[-1][:120]})", flush=True)
results = []
files = (C, H, M, V, P, K, "Tests/PhoneSignInRender.swift")
before = {f: (root / f).read_text() for f in files}
for name, path, old, new, cmd, expect in mutants:
    p = root / path; src = p.read_text()
    n = src.count(old)
    if n != 1: results.append((name, f"NOT APPLIED (found {n}x)")); print(results[-1], flush=True); continue
    mutated = src.replace(old, new)
    p.write_text(mutated)
    landed = p.read_text() == mutated and mutated != src
    try:
        code, out = sh(cmd)
    finally:
        p.write_text(src)
    killed = code != 0
    by = expect in out
    verdict = ("KILLED" if killed else "SURVIVED") + (f" by {expect}" if killed and by else " (other failure)" if killed else "") + ("" if landed else " (MUTATION DID NOT LAND)")
    results.append((name, verdict))
    print(f"{verdict:70s} {name}", flush=True)
    if killed and not by: print(out[-1500:])
print("\nsummary:")
for name, r in results: print(f"{r:70s} {name}")
print("sources restored:", all((root / f).read_text() == text for f, text in before.items()))
sys.exit(0 if all(r.startswith("KILLED by") and "DID NOT LAND" not in r for _, r in results) else 1)
