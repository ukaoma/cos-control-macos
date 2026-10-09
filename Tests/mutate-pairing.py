#!/usr/bin/env python3
"""Mutation pass for glasses pairing (contract 2026-10-09). Serial, every compile through Tests/compile-guard.sh.

Usage: mutate-pairing.py [<repo root>]. A green baseline of every suite comes first; each mutant must be applied exactly
once, must fail its suite, and is attributed to the check that names the behaviour. Sources are restored after each.
"""
import pathlib, subprocess, sys, os, tempfile
root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1])
helper_out = os.path.join(tempfile.mkdtemp(prefix="cos-mutate-pairing-", dir="/tmp"), "cos-control-helper")
env = dict(os.environ)
env.setdefault("COS_COMPILE_MIN_FREE_GB", "20")
def sh(cmd):
    r = subprocess.run(cmd, cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, shell=True)
    return r.returncode, r.stdout
PURE = "Tests/run-pairing.sh"
APP = "Tests/run-provider-connect.sh"
HELPER = (f'Tests/compile-guard.sh swiftc -target arm64-apple-macosx14.0 -swift-version 6 -strict-concurrency=complete '
          f'HelperSources/main.swift HelperSources/ProviderStatusCore.swift HelperSources/PairingCore.swift -framework Security -framework AppKit '
          f'-o {helper_out} 2>/dev/null && python3 Tests/pairing-helper-checks.py {helper_out}')
C, M, V = "HelperSources/PairingCore.swift", "Sources/ProviderConnectModel.swift", "Sources/ProviderConnectViews.swift"
mutants = [
 ("SHLVL dropped from the child env (pure)", C, '        out["SHLVL"] = "1"\n', '', PURE, "[shlvl]"),
 ("SHLVL dropped from the child env (compiled helper, real Process)", C, '        out["SHLVL"] = "1"\n', '', HELPER, "status running"),
 ("helper env passed through instead of the fixed set", C, '        var out: [String: String] = [:]\n        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] {', '        var out: [String: String] = environment\n        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] {', PURE, "[child env]"),
 ("sameUser always true (helper core)", C, 'sameUser: myUser != nil && theirs == myUser', 'sameUser: true', PURE, "[same user filter]"),
 ("phone ignores sameUser (app)", M, '        peers.first { $0.sameUser && $0.online && $0.os.lowercased() == "ios" }', '        peers.first { $0.online && $0.os.lowercased() == "ios" }', APP, "[phone same user]"),
 ("phone ignores online (app)", M, '        peers.first { $0.sameUser && $0.online && $0.os.lowercased() == "ios" }', '        peers.first { $0.sameUser && $0.os.lowercased() == "ios" }', APP, "[phone online]"),
 ("progress counts the Glasses rows", M, '        let counted = rows.filter { !$0.afterSetup && $0.counted }', '        let counted = rows.filter { !$0.afterSetup }', APP, "[glasses uncounted]"),
 ("Next can be a Glasses row", M, 'rows.first { !$0.handled && !$0.afterSetup && $0.counted }', 'rows.first { !$0.handled && !$0.afterSetup }', APP, "[glasses uncounted]"),
 ("Glasses rows counted", M, '        row.counted = false\n        guard let ts = facts.tailscale else { return row }\n        if !ts.installed {', '        guard let ts = facts.tailscale else { return row }\n        if !ts.installed {', APP, "[glasses uncounted]"),
 ("capability gate removed from the poll", M, '        guard serverRunning, pairingSupported, !serverTooOld else { noteStage(', '        guard serverRunning, !serverTooOld else { noteStage(', APP, "[capability gate]"),
 ("capability gate removed from the rules", M, '        guard facts.pairingSupported else { return .updateServer }\n', '', APP, "[capability gate]"),
 ("server_too_old answer ignored", M, '                if reason == "server_too_old" { serverTooOld = true }\n', '', APP, "[capability gate]"),
 ("health capability always on", C, '        return version.intValue >= 1', '        return true', PURE, "[capability gate]"),
 ("no-host code kept after Tailscale comes up", M, '        if (code.qr == nil || code.hosts.isEmpty) && facts.tailscaleUp && !facts.codeMintedWithTailscale { return .mint }\n', '', APP, "[re-mint when tailscale comes up]"),
 ("no-host code re-made in a loop", M, ' && facts.tailscaleUp && !facts.codeMintedWithTailscale { return .mint }', ' && facts.tailscaleUp { return .mint }', APP, "[re-mint when tailscale comes up]"),
 ("a cancelled QR stays on screen", M, '        if shown != code.display { return .replaced }\n', '', APP, "[stale qr]"),
 ("sameUser nil == nil matches (pinned 2026-10-09)", C, 'sameUser: myUser != nil && theirs == myUser', 'sameUser: theirs == myUser', PURE, "[same user filter]"),
 # QA round 1 (2026-10-09) guards.
 ("polls while hidden", M, '            if g.visible && due && !ticking {', '            if due && !ticking {', APP, "[visibility gate]"),
 ("two copies both poll", M, '            let due = lastTickUptime.map { uptime() - $0 >= pollInterval * 0.8 } ?? true', '            let due = true', APP, "[two pollers]"),
 ("too old never clears", M, '        if let previous = gateKey, previous != key, serverTooOld {\n            serverTooOld = false', '        if let previous = gateKey, previous != key, serverTooOld {\n            _ = 0', APP, "[too old clears]"),
 ("ping-pong never stops", M, '            if replacedOnce {', '            if false {', APP, "[ping-pong]"),
 ("mint before expiry", M, '        if code.expiresAt <= facts.now { return .mint }', '        if code.expiresAt <= facts.now.addingTimeInterval(2) { return .mint }', APP, "[mint at expiry]"),
 ("stale status kept", M, '        guard generation == mintGeneration, !minting else', '        guard !minting else', APP, "[stale status]"),
 ("toggle mint dropped", M, '        if minting { mintQueued = true; return }', '        if minting { return }', APP, "[lan queue]"),
 ("toggle shows the wish, not the server", M, '    var lanToggleOn: Bool { lanChangePending ? lanWanted : lanArmed }', '    var lanToggleOn: Bool { lanWanted }', APP, "[lan toggle]"),
 ("no account warning", M, '        return whois.sameUser ? nil : "Not your Tailscale account"', '        return nil', APP, "[account warning]"),
 ("names keep bidi and zero-width", M, 'where scalar.properties.generalCategory != .format && !CharacterSet', 'where !CharacterSet', APP, "[names]"),
 ("names uncapped", M, '        return text.count > nameLimit ? String(text.prefix(nameLimit - 1)) + "…" : text', '        return text', APP, "[names]"),
 ("whois failure asked every poll", M, '            if let failed = whoisFailedAt[ip], now().timeIntervalSince(failed) < Self.whoisRetry { continue }\n', '', APP, "[whois retry]"),
 ("status errors not backed off", M, '        if let retry = statusRetryAt, retry > now() { return }\n', '', APP, "[status backoff]"),
 ("helper message dropped", M, '            guard answer.ok else { throw PairingStateError.helper(answer.message) }\n            guard let details = PairingJSON.object(answer.details)', '            guard answer.ok else { throw PairingStateError.unreadable(arguments[0]) }\n            guard let details = PairingJSON.object(answer.details)', APP, "[helper message]"),
 ("whois sameUser nil == nil (helper)", C, '            let same = selfUser != nil && theirs != nil && theirs == selfUser', '            let same = theirs == selfUser', PURE, "[whois same user]"),
 ("whois sameUser ignores the account (helper)", C, '            let same = selfUser != nil && theirs != nil && theirs == selfUser', '            let same = theirs != nil', PURE, "[whois same user]"),
 ("Update the server runs the app check", V, '                Button("Update Server") { model.perform("update") }\n                    .buttonStyle(COSPrimaryButtonStyle())', '                Button("Update Server") { Task { await model.checkForAppUpdateManually() } }\n                    .buttonStyle(COSPrimaryButtonStyle())', APP, "[glasses update]"),
 ("the view ignores its window", V, 'visible: windowHolder.onScreen(panelVisible: model.panelVisible))', 'visible: true)', APP, "[glasses visibility]"),
 ("a 404 reads as its own reason", C, '        else if status == 404 { reason = "server_too_old" }', '        else if status == 404 { reason = "unknown_code" }', PURE, "[too old]"),
]
# Green baseline first: every suite the mutants use must pass unmutated.
for name, cmd in (("pure", PURE), ("app", APP), ("helper", HELPER)):
    code, out = sh(cmd)
    if code != 0: print(f"BASELINE RED ({name}):\n{out[-3000:]}"); sys.exit(1)
    print(f"baseline {name}: green ({out.strip().splitlines()[-1][:120]})")
# MUTATE_ONLY="a|b" runs only the mutants whose names contain one of the parts (the baseline still runs first).
only = [part for part in os.environ.get("MUTATE_ONLY", "").split("|") if part]
if only: mutants = [m for m in mutants if any(part in m[0] for part in only)]
results = []
before = {f: (root / f).read_text() for f in (C, M, V)}
for name, path, old, new, cmd, expect in mutants:
    p = root / path; src = p.read_text()
    n = src.count(old)
    if n != 1: results.append((name, f"NOT APPLIED (found {n}x)")); continue
    p.write_text(src.replace(old, new))
    try:
        code, out = sh(cmd)
    finally:
        p.write_text(src)
    killed = code != 0
    by = expect in out
    results.append((name, ("KILLED" if killed else "SURVIVED") + (f" by {expect}" if killed and by else " (other failure)" if killed else "")))
    if killed and not by: print(out[-1500:])
for name, r in results: print(f"{r:40s} {name}")
print("sources restored:", all((root / f).read_text() == text for f, text in before.items()))
