#!/usr/bin/env python3
"""0.5.380 (preview engine phase 1, plan item 6): mutation lane for the Sessions pane's file and image cards. By hand, while
holding the machine-wide swift-slot lease: one compile at a time, mutants strictly serial, never two at once.

Each lane's unmutated run must pass first (a red baseline kills every mutant and proves nothing). Then each mutant is applied
to the working tree (its target must occur EXACTLY once), its lane is run, and the file is restored byte for byte. A mutant
that applies and still passes is a finding: the guard is unreached.

Lanes:
  checks  Tests/SessionPreviewsChecks.swift compiled with Models.swift and SessionPreviews.swift (the store, executed)
  helper  the helper compiled alone, then Tests/session-previews-helper-checks.py
  capchecks  Tests/TodayCapChecks.swift compiled with Models.swift (Summaries per day and the reconnect ask, 0.5.380)
  pins    Tests/session-previews-pins.py and Tests/today-cap-pins.py (the wiring the checks cannot reach)

    python3 Tests/mutate-session-previews.py [lane ...]
"""
import os, pathlib, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
STORE = "Sources/SessionPreviews.swift"
HELPER = "HelperSources/main.swift"
MODEL = "Sources/ControllerModel.swift"
WINDOW = "Sources/ActivityWindow.swift"
MODELS = "Sources/Models.swift"

MUTANTS = [
    # Previews off: no cards and no fetch.
    ("checks", "off: open fetches", STORE, "guard !previewsOff, item.opens, opening == nil", "guard item.opens, opening == nil"),
    ("checks", "off: thumbnail fetches", STORE, "guard !previewsOff, item.hasThumbnail,", "guard item.hasThumbnail,"),
    ("checks", "off: a mixed answer keeps cards", STORE,
     "turns = previewsOff ? parsed.map { SessionPreviewTurn(id: $0.id, role: $0.role, at: $0.at, items: [], previewsOff: true) } : parsed", "turns = parsed"),
    ("checks", "off: an off message keeps its cards", STORE, "self.items = previewsOff ? [] : items", "self.items = items"),
    # The temp copy is gone after close.
    ("checks", "close keeps the copy", STORE, "didSet { if let old = oldValue, old != quickLookURL { discard(old) } }", "didSet { }"),
    ("checks", "discard deletes nothing", STORE, "        try? FileManager.default.removeItem(at: folder)\n", ""),
    ("checks", "an unbelieved copy stays", STORE, "            discard(URL(fileURLWithPath: path))\n", ""),
    ("checks", "launch sweep deletes nothing", STORE, "for entry in entries { try? fm.removeItem(at: entry) }", "for _ in entries { }"),
    ("checks", "launch sweep follows a symlinked root", STORE, "values.isDirectory == true, values.isSymbolicLink != true,\n", ""),
    ("checks", "a copy of the wrong size is believed", STORE, "values.fileSize == bytes,", ""),
    ("checks", "a symlinked copy is believed", STORE, "values.isSymbolicLink != true, values.isRegularFile == true, values.fileSize", "values.fileSize"),
    ("checks", "a copy two folders down is believed", STORE, "guard folder.deletingLastPathComponent().path == root.path, url.path.hasPrefix(root.path + \"/\"),",
     "guard url.path.hasPrefix(root.path + \"/\"),"),
    # Route absent (an older server): quiet.
    ("checks", "route absent shows cards", STORE, 'guard details["state"]?.string == "ready" else { turns = []', 'guard details["state"]?.string != nil else { turns = []'),
    # Secret refusal.
    ("checks", "app: a secret name opens", STORE,
     'available = (o["available"]?.bool ?? false) && !Self.secretReasons.contains(reason ?? "")', 'available = (o["available"]?.bool ?? false)'),
    ("checks", "thumbnail cap gone", STORE, "thumbnailsAsked.count < Self.thumbnailsPerSession,", ""),

    ("helper", "helper: a secret name is available", HELPER, 'let available = state == "available" && !secret', 'let available = state == "available"'),
    ("helper", "helper: an off message carries its files", HELPER,
     'out.append(["role": role, "at": at, "items": [], "more": 0, "previewsOff": true])\n                continue\n',
     'out.append(["role": role, "at": at, "items": [], "more": 0, "previewsOff": true])\n'),
    ("helper", "helper: 403 secret reads unauthorized", HELPER, '            if code == "secret_file_denied" || code == "blocked_name" { return "secret" }\n', ""),
    ("helper", "helper: 403 previews_off reads unauthorized", HELPER, '            if code == "previews_off" { return "off" }\n', ""),
    ("helper", "helper: a route-absent 404 reads missing", HELPER, 'case 404: return body == nil ? "absent" : "missing"', 'case 404: return "missing"'),
    ("helper", "helper: no recent turns reads ready", HELPER,
     'guard let turns = body?["recent_turns"] as? [Any] else { return ["state": "absent", "turns": [], "previewsOff": false] }',
     'let turns = (body?["recent_turns"] as? [Any]) ?? []'),
    ("helper", "helper: a non-picture on a picture route is written", HELPER,
     "guard let ext = sessionPreviewImageExtension(data) else { return nil }", 'let ext = sessionPreviewImageExtension(data) ?? "jpg"'),
    ("helper", "helper: names keep their directories", HELPER,
     'let last = text.split(whereSeparator: { $0 == "/" || $0 == "\\\\" }).last.map(String.init) ?? ""', "let last = text"),
    ("helper", "helper: the copy is world-readable", HELPER,
     "do { try atomicWriteData(data, to: destination, permissions: 0o600) }", "do { try atomicWriteData(data, to: destination, permissions: 0o644) }"),

    # 0.5.380 Summaries per day and the reconnect ask (server 7.0.5).
    ("capchecks", "reconnect armed by every good read", MODELS,
     "if now { failed = true } else if failed { failed = false; pending = true }", "if now { failed = true } else { failed = false; pending = true }"),
    ("capchecks", "reconnect while switched off", MODELS, "return pending && !switchedOff", "return pending"),
    ("capchecks", "reconnect never spent", MODELS, "            defer { pending = false }\n", ""),
    ("capchecks", "cap not clamped", MODELS, "dailyCap = Swift.min(high, Swift.max(low, cap))", "dailyCap = cap"),
    ("capchecks", "cap line ignores the setting", MODELS, "let n = statusCap ?? statusCount ?? Cap.defaultCap", "let n = statusCount ?? Cap.defaultCap"),
    ("capchecks", "reason changes the key", MODELS, '        o["force"] = nil\n        o["reason"] = nil\n', '        o["force"] = nil\n'),
    ("helper", "helper: reason never falls back", HELPER, 'for key in ["reason", "force"] where', 'for key in ["force"] where'),
    ("helper", "helper: any cap value is sent", HELPER,
     "guard let raw, raw.count <= 3, let n = Int(raw), (1...100).contains(n) else { return nil }", "guard let raw, let n = Int(raw) else { return nil }"),
    ("helper", "helper: the cap answer passes through whole", HELPER,
     'var details: [String: Any] = ["available": true, "dailyCap": cap]', 'var details: [String: Any] = body; details["available"] = true; _ = cap'),
    ("pins", "pins: no reconnect observed", WINDOW,
     "        today.reconnects.observe(failed: model.claudeSessionsError != nil || today.reachable == false || today.tickFailed)\n", ""),
    ("pins", "pins: open loads no cards", MODEL, "        sessionPreviews.load(provider: session.provider, sessionID: session.sessionId)\n", ""),
    ("pins", "pins: no launch sweep", MODEL, "        SessionPreviewStore.sweep()\n", ""),
    ("pins", "pins: leaving the pane keeps Quick Look", WINDOW, "            .onDisappear { store.quickLookURL = nil }\n", ""),
    ("pins", "pins: close keeps the cards", MODEL, "        stopSessionStream()\n        sessionPreviews.clear()\n", "        stopSessionStream()\n"),
]


def lane_command(lane, scratch):
    if lane == "checks":
        out = scratch / "checks"
        home = scratch / "home"; home.mkdir(exist_ok=True)
        compile_ = ["/usr/bin/python3", str(ROOT / "Tests/kit-compile.py"), str(ROOT / "Tests/compile-guard.sh"), "swiftc",
                    "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
                    str(ROOT / "Sources/Models.swift"), str(ROOT / STORE), str(ROOT / "Tests/SessionPreviewsChecks.swift"),
                    "-framework", "AppKit", "-o", str(out)]
        env = dict(os.environ, CFFIXED_USER_HOME=str(home), COS_CONTROL_TEST_HOME=str(home))
        return [(compile_, dict(os.environ, COS_COMPILE_PROFILE="bounded")), ([str(out)], env)]
    if lane == "capchecks":
        out = scratch / "checks"
        compile_ = ["/usr/bin/python3", str(ROOT / "Tests/kit-compile.py"), str(ROOT / "Tests/compile-guard.sh"), "swiftc",
                    "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
                    str(ROOT / MODELS), str(ROOT / "Tests/TodayCapChecks.swift"), "-framework", "AppKit", "-o", str(out)]
        return [(compile_, dict(os.environ, COS_COMPILE_PROFILE="bounded")), ([str(out)], dict(os.environ))]
    if lane == "helper":
        out = scratch / "cos-control-helper"
        compile_ = ["/usr/bin/python3", str(ROOT / "Tests/kit-compile.py"), str(ROOT / "Tests/compile-guard.sh"), "swiftc",
                    "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete",
                    str(ROOT / HELPER), str(ROOT / "HelperSources/ProviderStatusCore.swift"), str(ROOT / "HelperSources/PairingCore.swift"),
                    str(ROOT / "HelperSources/SessionUsageCollector.swift"), str(ROOT / "Sources/SessionUsageCore.swift"),
                    str(ROOT / "Sources/WorkSessionLinks.swift"), "-framework", "Security", "-framework", "AppKit", "-o", str(out)]
        return [(compile_, dict(os.environ, COS_COMPILE_PROFILE="bounded")),
                (["/usr/bin/python3", str(ROOT / "Tests/session-previews-helper-checks.py"), str(out)], dict(os.environ)),
                (["/usr/bin/python3", str(ROOT / "Tests/today-cap-helper-checks.py"), str(out)], dict(os.environ))]
    return [(["/usr/bin/python3", str(ROOT / "Tests/session-previews-pins.py"), str(ROOT)], dict(os.environ)),
            (["/usr/bin/python3", str(ROOT / "Tests/today-cap-pins.py"), str(ROOT)], dict(os.environ))]


def run_lane(lane):
    with tempfile.TemporaryDirectory(prefix="cos-mutate-previews.", dir="/tmp") as tmp:
        for cmd, env in lane_command(lane, pathlib.Path(tmp)):
            result = subprocess.run(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=3600)
            if result.returncode != 0:
                return False, result.stdout.decode(errors="replace")[-400:]
    return True, ""


def main():
    lanes = sys.argv[1:] or ["pins", "checks", "capchecks", "helper"]
    survivors = []
    for lane in lanes:
        ok, why = run_lane(lane)
        if not ok:
            sys.exit(f"baseline FAILED for lane {lane} (no mutant runs on a red baseline):\n{why}")
        print(f"baseline green: {lane}", flush=True)
        for mlane, name, rel, old, new in MUTANTS:
            if mlane != lane:
                continue
            path = ROOT / rel
            original = path.read_bytes()
            text = original.decode()
            count = text.count(old)
            if count != 1:
                sys.exit(f"mutant '{name}' target occurs {count} times in {rel}")
            path.write_text(text.replace(old, new))
            try:
                ok, why = run_lane(lane)
            finally:
                path.write_bytes(original)
            assert path.read_bytes() == original
            last = why.strip().splitlines()[-1] if why.strip() else ""
            print(f"{'KILLED ' if not ok else 'SURVIVED'} [{lane}] {name}  {last[:160]}", flush=True)
            if ok:
                survivors.append(name)
    if survivors:
        sys.exit(f"{len(survivors)} mutant(s) survived: " + "; ".join(survivors))
    print(f"session previews mutants: all {sum(1 for m in MUTANTS if m[0] in lanes)} killed")


if __name__ == "__main__":
    main()
