#!/usr/bin/env python3
"""K1 P10: mutation gate for key lanes in COS Control.

Runs the unmutated lanes first and refuses on any failure (a red baseline would "kill" every mutant). Each mutant must
match its target EXACTLY ONCE, and is killed only when its lane fails with a named check ("... FAILED: ..."); a compile
failure or any other exit is an infrastructure error, not a kill. Compiles go through the lane, so through
Tests/compile-guard.sh, one at a time, never in parallel.
Usage: python3 Tests/mutate-key-lanes.py [--lane pins|models|core|helper]
"""
import os
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANE = ROOT / "Tests" / "run-key-lanes.sh"
CORE = "Sources/KeyLanes.swift"
VIEWS = "Sources/KeyLanesViews.swift"
PANEL = "Sources/Views.swift"
SETUP = "Sources/ControlSetup.swift"
MODEL = "Sources/ControllerModel.swift"
WORK = "Sources/WorkHandoffStore.swift"
RELEASE = "scripts/build-release.sh"
HCORE = "HelperSources/ProviderStatusCore.swift"
HELPER = "HelperSources/main.swift"

MUTANTS = [
    # The decisions and the store (Tests/KeyLanesChecks.swift).
    ("M1 step shown on existing install", "models", CORE, "        return install == .new || enabled\n", "        return true\n"),
    ("M2 Settings row hidden when on", "models", CORE, "        enabled || serverSupports(serverVersion)\n", "        serverSupports(serverVersion)\n"),
    ("M3 the row shows on 6.79", "models", CORE, "    static let minimumServer = [6, 80, 0]\n", "    static let minimumServer = [6, 79, 0]\n"),
    ("M4 key echoed in UI", "models", CORE,
     '"Ready to save: " + keyLine(kind: kind, last4: last4(secret))', '"Ready to save: " + keyLine(kind: kind, last4: secret)'),
    ("M5 key passed in argv", "models", CORE, 'await call(["save-key"], input, run: run)', 'await call(["save-key", secret], input, run: run)'),
    ("M6 refusal not displayed", "models", CORE, "        return KeyLanes.keyedSessionRefusal\n    }\n", "        return nil\n    }\n"),
    ("M7 keyed sessions forgotten after lanes turn off", "models", CORE,
     "        defaults.set(Array(Array(keyedSessionIds).sorted().suffix(20_000)), forKey: Self.keyedSessionsKey)\n", ""),
    ("M8 install decided before the status is known", "models", CORE, '        guard runtimeState != "unknown" else { return nil }\n', ""),
    ("M9 an earlier setup is ignored", "models", CORE, "        return needsFirstRun && !priorSetup ? .new : .existing\n",
     "        return needsFirstRun ? .new : .existing\n"),
    ("M10 turning on skips the enable door", "models", CORE, 'let details = await call(["enable"], run: run)', 'let details = await call(["status"], run: run)'),
    ("M11 Remove keeps the key's profile", "models", CORE,
     '            line = KeyLanes.problem(await call(["delete-profile", "--id", KeyLanes.profileID(forKey: keyRef)], run: run))\n', ""),
    ("M12 the default cap is not $1", "models", CORE, "    static let defaultCapUsd = 1.0\n", "    static let defaultCapUsd = 5.0\n"),
    ("M13 a lanes-off server writes keyed sessions", "models", CORE, "        guard !fresh.isEmpty else { return }\n", ""),
    # The wiring and the copy (Tests/key-lanes-pins.py).
    ("P1 no Settings row", "pins", PANEL, "                KeyLanesSettingsRow(model: model)\n", ""),
    ("P2 the step leaves the Ready stage", "pins", SETUP, "            KeyLanesSetupStep(model: model)\n            PetIntroLine(model: model)\n            Button(\"Finish setup\")",
     "            PetIntroLine(model: model)\n            Button(\"Finish setup\")"),
    ("P3 refusal not displayed on Continue (chat)", "pins", MODEL,
     "        guard let session = openClaudeRow, !chatSending, !chatPolling else { return }\n        if let line = KeyLanes.refusal(sessionID: session.sessionId) { chatRefusal = line; return }\n",
     "        guard let session = openClaudeRow, !chatSending, !chatPolling else { return }\n"),
    ("P4 refusal not displayed on Fork (chat)", "pins", MODEL,
     "        guard let session = openClaudeRow, !chatForking, !chatSending else { return }\n        if let line = KeyLanes.refusal(sessionID: session.sessionId) { chatRefusal = line; return }\n",
     "        guard let session = openClaudeRow, !chatForking, !chatSending else { return }\n"),
    ("P5 refusal not displayed on Work Continue and Fork", "pins", WORK,
     "        if mode != .newSession, let line = KeyLanes.refusal(sessionID: session?.nativeID) { error = line; return }\n", ""),
    ("P6 refusal not displayed on Fork to another platform", "pins", WORK,
     "        if let line = KeyLanes.refusal(sessionID: session.nativeID) { error = line; return }\n", ""),
    ("P7 the refusal drifts from P8", "pins", CORE, '"This session ran on your key. Continue it from COS."', '"This session ran on your key."'),
    ("P8 the release build leaves the files out", "pins", RELEASE, ' "$ROOT/Sources/KeyLanes.swift" "$ROOT/Sources/KeyLanesViews.swift"', ""),
    ("P9 the pasted key is drawn", "pins", VIEWS, "Text(pending.map { KeyLanes.pendingLine(kind: kind, secret: $0) } ?? KeyLanes.pasteHint)",
     "Text(pending ?? KeyLanes.pasteHint)"),
    ("P10 Remove all keys without a confirmation", "pins", VIEWS, "                Button(KeyLanes.removeAllLabel) { removingAll = true }",
     "                Button(KeyLanes.removeAllLabel) { Task { await store.removeAll(exportLedger: exportLedger, run: keyLanesRun(model)) } }"),
    # The helper's grammar and whitelist (Tests/KeyLanesHelperChecks.swift).
    ("C1 the helper takes a key in argv", "core", HCORE, '        case "save-key": return rest.isEmpty ? p("POST", "/keys", nil, .key, 25) : nil\n',
     '        case "save-key": return p("POST", "/keys", nil, .key, 25)\n'),
    ("C2 a status key crosses whole", "core", HCORE,
     '        var out: [String: Any] = ["ref": ref, "kind": kind, "last4": last4, "capUsd": cap]\n', "        var out: [String: Any] = o\n"),
    ("C3 an answer that repeats the key is kept", "core", HCORE, "              String(decoding: data, as: UTF8.self).contains(secret) else { return out }\n",
     "              String(decoding: data, as: UTF8.self).contains(secret + \"#\") else { return out }\n"),
    ("C4 a 404 page reads as answered", "core", HCORE, '        status == 404 && body == nil ? "unsupported" : "answered"\n', '        "answered"\n'),
    ("C5 a ref with a path passes", "core", HCORE, '    static let refPattern = "\\\\Akey_[0-9a-f]{12}\\\\z"\n', '    static let refPattern = "\\\\Akey_"\n'),
    ("C6 a profile body can carry a key", "core", HCORE,
     '            guard Set(object.keys).isSubset(of: ["id", "label", "keyRef", "engine", "model", "enabled", "timeoutTier"]),\n',
     '            guard Set(object.keys).isSubset(of: ["id", "label", "keyRef", "engine", "model", "enabled", "timeoutTier", "key"]),\n'),
    # The compiled helper (Tests/key-lanes-helper-checks.py); a full helper compile each, so two.
    ("H1 the helper drops the answer check", "helper", HELPER, "            body = parsed.body; secret = parsed.secret\n", "            body = parsed.body; secret = nil\n"),
    ("H2 the helper sends no token", "helper", HELPER, "request(plan.path, method: plan.method, token: token, body: text,",
     "request(plan.path, method: plan.method, token: nil, body: text,"),
]


def run(lane):
    env = dict(os.environ, COS_KEY_LANES_LANE=lane)
    # Exit 70 with "lock busy" is another session's compile holding the machine-wide compile lock (compile-guard): wait
    # and run again, never in parallel. It is not a kill and not a pass.
    for _ in range(30):
        r = subprocess.run(["zsh", str(LANE)], cwd=ROOT, env=env, capture_output=True, text=True)
        if r.returncode != 70 or "lock busy" not in r.stdout + r.stderr:
            return r
        time.sleep(60)
    return r


only = sys.argv[sys.argv.index("--lane") + 1] if "--lane" in sys.argv else None
lanes = [lane for lane in ("pins", "models", "core", "helper") if only in (None, lane)]
mutants = [m for m in MUTANTS if m[1] in lanes]
for lane in lanes:
    base = run(lane)
    if base.returncode != 0:
        print(f"BASELINE RED ({lane}):\n{base.stdout}{base.stderr}")
        sys.exit(2)
print("baseline green: " + ", ".join(lanes), flush=True)

survivors = infra = 0
for name, lane, rel, old, new in mutants:
    path = ROOT / rel
    src = path.read_text()
    count = src.count(old)
    if count != 1:
        print(f"{name}: NOT APPLIED (target found {count} times)", flush=True)
        infra += 1
        continue
    path.write_text(src.replace(old, new))
    try:
        r = run(lane)
        out = r.stdout + r.stderr
        failed_line = next((l for l in out.splitlines() if "FAILED:" in l), None)
        if r.returncode != 0 and failed_line:
            print(f"{name}: killed by {failed_line.strip()[:220]}", flush=True)
        elif r.returncode != 0:
            print(f"{name}: INFRASTRUCTURE (exit {r.returncode}, no named check)\n{out[-600:]}", flush=True)
            infra += 1
        else:
            print(f"{name}: SURVIVED", flush=True)
            survivors += 1
    finally:
        path.write_text(src)
print(f"key lanes mutants: {len(mutants) - survivors - infra} killed, {survivors} survived, {infra} infrastructure")
sys.exit(1 if survivors or infra else 0)
