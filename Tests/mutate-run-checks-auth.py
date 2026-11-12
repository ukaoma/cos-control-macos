#!/usr/bin/env python3
"""Anand fixes d and c (D4, 2026-11-12): Run checks reads `claude auth status`, and Update Server says what happened where it was
pressed. Mutation gate for the helper's claudeAuthLabel, authExpiry, authWarns and signInRefusal (against its `self-test`), the
app's ServerUpdateWords (against Tests/run-provider-connect.sh) and the wiring (against Tests/provider-connect-pins.py).

    python3 -u Tests/mutate-run-checks-auth.py [--targets] [mutant-name ...]

Runs each kind unmutated first and refuses unless it passes; then for each mutant asserts the target appears EXACTLY ONCE, applies
it, reruns its kind, and requires a failure carrying the named message. The file is restored in `finally`.
Compiles run one at a time through Tests/compile-guard.sh, under the swift-slot lease.
"""
import json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT, "Tests/compile-guard.sh")
HS, PM, MODEL = "HelperSources/main.swift", "Sources/ProviderConnectModel.swift", "Sources/ControllerModel.swift"
HELPER_SOURCES = ["HelperSources/main.swift", "HelperSources/ProviderStatusCore.swift", "HelperSources/PairingCore.swift",
                  "HelperSources/SessionUsageCollector.swift", "Sources/SessionUsageCore.swift", "Sources/WorkSessionLinks.swift"]
MUTANTS = [
    # (name, target, replacement, expected message[, file, kind]); file defaults to the helper, kind to "helper".
    ("exit-one-ignored", "            if output.lowercased().contains(\"not logged in\") { return authSignedOut }\n", "", "claude auth: exit 1 that says so is signed out"),
    ("exit-one-trusted", "            return \"sign-in check required\"\n        }\n        guard code == 0,", "            return authSignedOut\n        }\n        guard code == 0,",
     "claude auth: exit 1 from an older CLI with no auth status stays a quiet check"),
    ("logged-out-ignored", "        guard loggedIn else { return authSignedOut }\n", "", "claude auth: loggedIn false is signed out"),
    ("expiry-ignored", "        if let expires = authExpiry(status[\"loginExpiresAt\"]), expires <= now { return authExpired }\n", "",
     "claude auth: a loginExpiresAt already past is expired"),
    ("expiry-always", "expires <= now { return authExpired }", "expires <= now.addingTimeInterval(10 * 365 * 86_400) { return authExpired }",
     "claude auth: a loginExpiresAt still ahead is signed in"),
    ("millis-as-seconds", "raw > 100_000_000_000 ? raw / 1000 : raw", "raw", "claude auth: a loginExpiresAt already past is expired"),
    ("no-json-cut", "open < close,\n              let data = String(output[open...close]).data(using: .utf8)", "open < close,\n              let data = output.data(using: .utf8)",
     "claude auth: an older CLI with no loginExpiresAt reads signed in"),
    ("unreadable-warns", "static func authWarns(_ label: String) -> Bool { label == authSignedOut || label == authExpired }",
     "static func authWarns(_ label: String) -> Bool { label != \"signed in\" }", "claude auth: unreadable output or another exit stays a quiet check"),
    ("expired-quiet", "static func authWarns(_ label: String) -> Bool { label == authSignedOut || label == authExpired }",
     "static func authWarns(_ label: String) -> Bool { label == authSignedOut }", "claude auth: a loginExpiresAt already past is expired"),
    # Fix c, helper: the sign-in stop before the switch.
    ("refuse-on-any", "labels.values.allSatisfy(authWarns)", "labels.values.contains(where: authWarns)",
     "update sign-in: one AI signed in, or one that did not answer, warns nothing"),
    ("cursor-ignored", "guard !otherProvider, !labels.isEmpty,", "guard !labels.isEmpty,", "update sign-in: Cursor, or no Claude or Codex at all, warns nothing"),
    ("refuse-unnamed", "+ \"so sign in to \\(who) if the update stops.\"", "+ \"so sign in if the update stops.\"",
     "update sign-in: every installed AI signed out or expired is warned about"),
    # Fix c, app: the words and the wiring.
    ("update-proof-raw", "        if let verdict = SetupFailureWords.verdict(error) {", "        if false, let verdict = SetupFailureWords.verdict(error) {",
     "check failed [update words]", PM, "app"),
    ("update-detail-dropped", "return ServerUpdateResult(caller: caller, line: didNotFinish, detail: error, failed: true)",
     "return ServerUpdateResult(caller: caller, line: didNotFinish, detail: nil, failed: true)", "check failed [update words]", PM, "app"),
    ("update-alert-raw", "                    self.error = serverUpdateResult?.line\n", "                    self.error = error.localizedDescription\n",
     "pin failed [update plain failure]", MODEL, "pins"),
    ("update-not-announced", "        serverUpdateResult = result\n        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,",
     "        serverUpdateResult = result\n        _ = (NSApp as Any, NSAccessibility.Notification.layoutChanged,", "pin failed [update announced]", MODEL, "pins"),
    ("update-reinstalls-latest", "            emit(ok: true, message: Self.upToDateMessage(current), details: details)\n            return\n",
     "            emit(ok: true, message: Self.upToDateMessage(current), details: details)\n", "pin failed [update up to date]", HS, "pins"),
    ("update-checks-late", "        if update {\n            progress(\"Checking that an AI is signed in…\")\n", "        if false {\n            progress(\"Checking that an AI is signed in…\")\n",
     "pin failed [update sign-in first]", HS, "pins"),
    ("settings-caller-lost", "                Button(\"Update Server\") { model.updateServer(from: ServerUpdateCaller.settings) }",
     "                Button(\"Update Server\") { model.perform(\"update\") }", "pin failed [update from its caller]", "Sources/Views.swift", "pins"),
]


def run_kind(kind, tmp):
    if kind == "helper":
        return build_and_test(tmp)
    cmd = ["zsh", "Tests/run-provider-connect.sh"] if kind == "app" else ["python3", "Tests/provider-connect-pins.py", "."]
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr)[-4000:]


def build_and_test(tmp):
    out = os.path.join(tmp, "cos-control-helper")
    cmd = ["zsh", GUARD, "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete",
           *[os.path.join(ROOT, s) for s in HELPER_SOURCES], "-framework", "Security", "-framework", "AppKit", "-o", out]
    built = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if built.returncode != 0:
        return False, "compile failed: " + (built.stderr or built.stdout)[-400:]
    home = os.path.join(tmp, "home"); os.makedirs(home, exist_ok=True)
    run = subprocess.run([out, "self-test"], cwd=ROOT, capture_output=True, text=True, env={**os.environ, "COS_CONTROL_TEST_HOME": home})
    try:
        v = json.loads(run.stdout)
    except Exception:
        return False, "unreadable self-test output: " + run.stdout[-300:]
    return bool(v.get("ok")), str(v.get("message"))


def main():
    want = set(sys.argv[1:]); targets_only = "--targets" in want; want.discard("--targets")
    chosen = [(m + (HS, "helper"))[:6] if len(m) == 4 else m for m in MUTANTS if not want or m[0] in want]
    bad = [m[0] for m in chosen if open(os.path.join(ROOT, m[4])).read().count(m[1]) != 1]
    if bad:
        print("targets not found exactly once:", ", ".join(bad)); sys.exit(2)
    if targets_only:
        print(f"targets: {len(chosen)} found exactly once"); return
    # /tmp, as Tests/mutate-phone-signin.py and the helper build use: the helper's self-test refused its baseline under the
    # system temp folder (11:37, "No COS Python bridge in that folder") while the same build passed from /tmp.
    with tempfile.TemporaryDirectory(prefix="cos-mutate-auth-", dir="/tmp") as tmp:
        for kind in sorted({m[5] for m in chosen}):
            ok, message = run_kind(kind, tmp)
            if not ok:
                print(f"REFUSED: baseline {kind} is not green:", message[-300:]); sys.exit(2)
            print(f"baseline {kind}: pass")
        killed = survived = 0
        for name, target, replacement, expect, rel, kind in chosen:
            path = os.path.join(ROOT, rel); source = open(path).read()
            try:
                open(path, "w").write(source.replace(target, replacement, 1))
                ok, message = run_kind(kind, tmp)
            finally:
                open(path, "w").write(source)
            assert open(path).read() == source, "source not restored"
            if not ok and expect in message:
                killed += 1; print(f"KILLED   {name}: failed with '{expect}'")
            else:
                survived += 1; print(f"SURVIVED {name}: {'passed' if ok else 'failed for another reason: ' + message[-200:]}")
        print(f"mutants: {killed} killed, {survived} survived")
        sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
