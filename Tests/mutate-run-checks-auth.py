#!/usr/bin/env python3
"""Anand fix d (D4, 2026-11-12): Run checks reads `claude auth status`. Mutation gate for HelperSources/main.swift's
claudeAuthLabel, authExpiry and authWarns, against the helper's `self-test`.

    python3 -u Tests/mutate-run-checks-auth.py [--targets] [mutant-name ...]

Builds the helper unmutated and refuses unless its self-test passes; then for each mutant asserts the target appears EXACTLY
ONCE, applies it, rebuilds, and requires the self-test to fail with the named message. The file is restored in `finally`.
Compiles run one at a time through Tests/compile-guard.sh, under the swift-slot lease.
"""
import json, os, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT, "Tests/compile-guard.sh")
HS = "HelperSources/main.swift"
HELPER_SOURCES = ["HelperSources/main.swift", "HelperSources/ProviderStatusCore.swift", "HelperSources/PairingCore.swift",
                  "HelperSources/SessionUsageCollector.swift", "Sources/SessionUsageCore.swift", "Sources/WorkSessionLinks.swift"]
MUTANTS = [
    ("exit-one-ignored", "        if code == 1 { return authSignedOut }\n", "", "claude auth: exit 1 is signed out"),
    ("logged-out-ignored", "        guard loggedIn else { return authSignedOut }\n", "", "claude auth: loggedIn false is signed out"),
    ("expiry-ignored", "        if let expires = authExpiry(status[\"loginExpiresAt\"]), expires <= now { return authExpired }\n", "",
     "claude auth: a loginExpiresAt already past is expired"),
    ("expiry-always", "expires <= now { return authExpired }", "expires <= now.addingTimeInterval(10 * 365 * 86_400) { return authExpired }",
     "claude auth: a loginExpiresAt still ahead is signed in"),
    ("millis-as-seconds", "raw > 100_000_000_000 ? raw / 1000 : raw", "raw", "claude auth: a loginExpiresAt already past is expired"),
    ("no-json-cut", "let data = String(output[open...close]).data(using: .utf8)", "let data = output.data(using: .utf8)",
     "claude auth: an older CLI with no loginExpiresAt reads signed in"),
    ("unreadable-warns", "static func authWarns(_ label: String) -> Bool { label == authSignedOut || label == authExpired }",
     "static func authWarns(_ label: String) -> Bool { label != \"signed in\" }", "claude auth: unreadable output or another exit stays a quiet check"),
    ("expired-quiet", "static func authWarns(_ label: String) -> Bool { label == authSignedOut || label == authExpired }",
     "static func authWarns(_ label: String) -> Bool { label == authSignedOut }", "claude auth: a loginExpiresAt already past is expired"),
]


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
    chosen = [m for m in MUTANTS if not want or m[0] in want]
    path = os.path.join(ROOT, HS); source = open(path).read()
    bad = [m[0] for m in chosen if source.count(m[1]) != 1]
    if bad:
        print("targets not found exactly once:", ", ".join(bad)); sys.exit(2)
    if targets_only:
        print(f"targets: {len(chosen)} found exactly once"); return
    with tempfile.TemporaryDirectory(prefix="cos-mutate-auth-") as tmp:
        ok, message = build_and_test(tmp)
        if not ok:
            print("REFUSED: baseline helper self-test is not green:", message[:300]); sys.exit(2)
        print("baseline helper: pass")
        killed = survived = 0
        for name, target, replacement, expect in chosen:
            try:
                open(path, "w").write(source.replace(target, replacement, 1))
                ok, message = build_and_test(tmp)
            finally:
                open(path, "w").write(source)
            if not ok and expect in message:
                killed += 1; print(f"KILLED   {name}: failed with '{expect}'")
            else:
                survived += 1; print(f"SURVIVED {name}: {'passed' if ok else 'failed for another reason: ' + message[:200]}")
        assert open(path).read() == source, "source not restored"
        print(f"mutants: {killed} killed, {survived} survived")
        sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
