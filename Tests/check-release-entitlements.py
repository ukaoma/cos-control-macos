#!/usr/bin/env python3
"""check-release-entitlements.py <COS Control.app> | --selftest <scratch-dir> <any-signable-binary>

0.5.267: the notarized 0.5.266 shipped with hardened runtime and ZERO entitlements, so every Apple Event the app sent
(the jump-to-session reopen through NSAppleScript, Guided Setup's Terminal script through an osascript child) was
refused without a prompt. A signed build passes only when:
  - the bundle and its main executable carry exactly com.apple.security.automation.apple-events = true;
  - Info.plist names why (NSAppleEventsUsageDescription, non-empty);
  - the helper carries no entitlements at all;
  - bundled node, when present, carries exactly allow-jit and disable-library-validation. 0.5.266's node had only
    allow-jit, so library validation refused every npm native addon (sherpa-onnx.node, fsevents.node: ad-hoc signed,
    no team): measured 2026-10-07, the shipped node failed to dlopen both and a re-signed copy with
    disable-library-validation loaded both.
--selftest builds throwaway bundles from a copy of a binary (ad-hoc signed) and proves each rule can fail.
"""
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

APPLE_EVENTS = "com.apple.security.automation.apple-events"
APP_WANT = {APPLE_EVENTS: True}
NODE_WANT = {"com.apple.security.cs.allow-jit": True, "com.apple.security.cs.disable-library-validation": True}


def entitlements(path: Path) -> dict:
    out = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", str(path)],
                         capture_output=True)
    if out.returncode != 0:
        raise SystemExit(f"codesign could not read {path}: {out.stderr.decode(errors='replace').strip()}")
    data = out.stdout.strip()
    return plistlib.loads(data) if data else {}


def problems(app: Path) -> list:
    found = []
    main = app / "Contents/MacOS/COS Control"
    helper = app / "Contents/Resources/cos-control-helper"
    node = app / "Contents/Resources/BundledNode/bin/node"
    for label, path in (("the app bundle", app), ("the main executable", main)):
        got = entitlements(path)
        if got != APP_WANT:
            found.append(f"{label} entitlements are {got!r}, want exactly {APP_WANT!r}")
    for label, path in (("the app bundle", app), ("the main executable", main), ("the helper", helper)):
        if "com.apple.security.cs.disable-library-validation" in entitlements(path):
            found.append(f"{label} must not disable library validation (only bundled node may)")
    got = entitlements(helper)
    if got:
        found.append(f"the helper carries entitlements it does not need: {got!r}")
    if node.exists():
        got = entitlements(node)
        if got != NODE_WANT:
            found.append(f"bundled node entitlements are {got!r}, want exactly {NODE_WANT!r}")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if not str(info.get("NSAppleEventsUsageDescription", "")).strip():
        found.append("Info.plist has no NSAppleEventsUsageDescription")
    return found


def check(app: Path) -> int:
    found = problems(app)
    for line in found:
        print("FAIL: release entitlements:", line, file=sys.stderr)
    if not found:
        print(f"PASS: release entitlements ({app.name}: Apple Events on the app and main executable, usage string, "
              "helper has none)")
    return 1 if found else 0


def selftest(scratch: Path, binary: Path) -> int:
    repo = Path(__file__).resolve().parent.parent
    ents = repo / "Resources/COSControl.entitlements"
    source_info = plistlib.loads((repo / "Resources/Info.plist").read_bytes())

    dlv = scratch / "app-with-dlv.entitlements"
    dlv.write_bytes(plistlib.dumps({APPLE_EVENTS: True, "com.apple.security.cs.disable-library-validation": True}))

    def make(name, app_ents=True, exe_ents=True, helper_ents=False, usage=True, app_dlv=False) -> Path:
        app = scratch / name / "COS Control.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Resources").mkdir(parents=True)
        info = dict(source_info)
        if not usage:
            info.pop("NSAppleEventsUsageDescription", None)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        main = app / "Contents/MacOS/COS Control"
        helper = app / "Contents/Resources/cos-control-helper"
        shutil.copy(binary, main)
        shutil.copy(binary, helper)

        def sign(path, with_ents):
            cmd = ["/usr/bin/codesign", "--force", "--sign", "-"]
            if with_ents:
                cmd += ["--entitlements", str(ents)]
            subprocess.run(cmd + [str(path)], check=True, capture_output=True)

        sign(helper, helper_ents)
        sign(main, exe_ents)
        if app_dlv:
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", str(dlv), str(app)],
                           check=True, capture_output=True)
        else:
            sign(app, app_ents)
        return app

    cases = [
        ("good", {}, 0),
        # Signing the bundle rewrites the main executable's signature (they are one signature), so a bundle signed
        # last without entitlements strips the executable's too: that is the 0.5.266 failure.
        ("bundle-missing", {"app_ents": False}, 1),
        ("exe-only", {"app_ents": False, "exe_ents": True}, 1),
        ("helper-has-some", {"helper_ents": True}, 1),
        ("no-usage-string", {"usage": False}, 1),
        ("app-disables-library-validation", {"app_dlv": True}, 1),
    ]
    bad = []
    for name, kwargs, want in cases:
        got = 1 if problems(make(name, **kwargs)) else 0
        if got != want:
            bad.append(f"{name}: expected {'a failure' if want else 'a pass'}")
    if not ents.exists() or plistlib.loads(ents.read_bytes()) != APP_WANT:
        bad.append("Resources/COSControl.entitlements is not exactly the Apple Events entitlement")
    if plistlib.loads((repo / "Resources/Node.entitlements").read_bytes()) != NODE_WANT:
        bad.append("Resources/Node.entitlements is not exactly allow-jit + disable-library-validation")
    for line in bad:
        print("FAIL: release entitlements self-test:", line, file=sys.stderr)
    if not bad:
        print(f"PASS: release entitlements self-test ({len(cases)} bundles; each rule fails when broken)")
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--selftest":
        sys.exit(selftest(Path(sys.argv[2]), Path(sys.argv[3])))
    if len(sys.argv) == 2:
        sys.exit(check(Path(sys.argv[1])))
    print(__doc__, file=sys.stderr)
    sys.exit(2)
