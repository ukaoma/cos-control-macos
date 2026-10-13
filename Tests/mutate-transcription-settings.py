#!/usr/bin/env python3
"""Mutation lane for the Transcription switcher (server 6.72.0). Run by hand, never by a gate. SERIAL: one mutant at a
time, every compile through Tests/compile-guard.sh (two kernel panics on 2026-10-07 came from parallel compiles).

    python3 Tests/mutate-transcription-settings.py <worktree> <scratch dir> [name ...]

Copies the worktree once to <scratch dir>/copy, proves each UNMUTATED lane green first (a red baseline makes every
mutant look killed), then applies one mutant at a time: the target must appear exactly once, the mutant must make a
check fail, and the failure must name the behaviour the mutant breaks. A mutant that lands and survives is a finding.
Lanes: "store" Tests/run-transcription-settings.sh (MeetingAskCore.swift against a stand-in helper); "helper" the
compiled helper against Tests/transcription-settings-helper-checks.py and the contract fixture.
"""
import pathlib, shutil, subprocess, sys

CORE = "Sources/MeetingAskCore.swift"
H = "HelperSources/main.swift"
MUTANTS = [
    ("404 shows the card", CORE, "        case 404:\n            availability = .unsupported\n            settings = nil",
     "        case 404:\n            availability = .supported\n            settings = nil", "404 hides the card", "store"),
    ("hidden card still sends", CORE, "        guard visible, pending == nil else { return }", "        guard pending == nil else { return }",
     "a hidden card never sends a change", "store"),
    ("install offered while recording", CORE, "        guard visible, !installing, !recording, let parakeet",
     "        guard visible, !installing, let parakeet", "never offered while a recording is live", "store"),
    ("unavailable note dropped", CORE, ': (said ?? "Not available")', ': nil', "shows its note", "store"),
    ("400 sentence dropped", CORE, "        case 400, 409:\n            availability = .supported\n            error = response.details[\"error\"]?.string ?? response.message",
     "        case 400, 409:\n            availability = .supported\n            error = nil", "400 shows the server's message", "store"),
    ("refused install still polls", CORE, "                error = started.details[\"error\"]?.string ?? started.message; return",
     "                error = started.details[\"error\"]?.string ?? started.message", "a refused install shows the server sentence", "store"),
    ("unbounded poll", CORE, "        if let parakeet = settings?.parakeet, !parakeet.done, !parakeet.failed { error = Transcription.installTimedOut }", "", "the poll is bounded", "store"),
    # 6.72.0 additions.
    ("failed install keeps polling", CORE, "            if let parakeet = settings?.parakeet, parakeet.done || parakeet.failed { return }",
     "            if let parakeet = settings?.parakeet, parakeet.done { return }", "a failed install stops polling", "store"),
    ("started false still polls", CORE, "                if started.details[\"started\"]?.bool == false { return }\n", "", "started false: no polling", "store"),
    ("load never follows a server install", CORE, "        guard visible, !installing, settings?.parakeet.serverInstalling == true else { return }",
     "        guard visible, !installing, settings?.parakeet.serverInstalling == true, false else { return }", "a load during a server install polls", "store"),
    ("second install offered while the server installs", CORE, "        return !parakeet.installed && parakeet.installable && !parakeet.serverInstalling",
     "        return !parakeet.installed && parakeet.installable", "no second install while the server installs", "store"),
    ("progress shows bytes only", CORE, '            if progress.bytesTotal > 0 { return "Installing Parakeet. \\(megabytes(progress.bytesDone)) of \\(megabytes(progress.bytesTotal)) MB." }\n',
     "", "progress line X of Y", "store"),
    ("verifying not said", CORE, '            if progress.state == "verifying" { return "Verifying the Parakeet download." }\n', "", "verifying line", "store"),
    ("failure reason dropped", CORE, '        return parakeet.progress?.error ?? "The Parakeet install did not finish. Try again."',
     '        return "The Parakeet install did not finish. Try again."', "a failed install shows the server's reason", "store"),
    ("effective line when it matches", CORE, "        guard let effective = choice.effective, !effective.isEmpty, effective != choice.selected else { return nil }",
     "        guard let effective = choice.effective, !effective.isEmpty else { return nil }", "no effective line when effective matches", "store"),
    ("note shown for any preview", CORE, '        if settings.preview.selected == "parakeet" {\n            let warm',
     '        if true {\n            let warm', "the Parakeet note only shows while Parakeet is the preview", "store"),
    ("resolver reason ignores effective", CORE, "        guard settings.resolverEnabled, settings.resolverEffective == false else { return nil }",
     "        guard settings.resolverEnabled else { return nil }", "no resolver line when it is refining or off", "store"),
    ("helper drops effective", H, '            out[key] = ["selected": selected, "options": rows, "effective": sttOptionID(choice["effective"]) ?? NSNull()]',
     '            out[key] = ["selected": selected, "options": rows, "effective": NSNull()]', "effective passes through", "helper"),
    ("helper passes any progress state", H, '            parakeetOut["progress"] = ["state": oneOf(progress["state"], ["idle", "downloading", "verifying", "installed", "failed"]),',
     '            parakeetOut["progress"] = ["state": progress["state"] ?? NSNull(),', "unknown progress and warm states", "helper"),
    ("helper drops started", H, '            if call == .installParakeet, let started = response.body?["started"] as? Bool { details["started"] = started }\n', "",
     "202 started with the GET shape", "helper"),
    ("helper forwards every key", H, "            body = try jsonObject(change)", "            body = String(decoding: input, as: UTF8.self)",
     "PUT carries contract keys only", "helper"),
    ("helper takes a number for resolver", H, "                guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {",
     "                guard let value = raw as? NSNumber else {", "malformed changes never reach the server", "helper"),
    ("helper 404 is a failure", H, '            emit(ok: true, message: "Needs server 6.72.0", details: ["httpStatus": 404])',
     '            emit(ok: false, message: "Needs server 6.72.0", details: ["httpStatus": 404])', "404 is an answer", "helper"),
    ("helper drops the 400 sentence", H, '            emit(ok: true, message: message, details: ["httpStatus": response.status, "error": message])\n        case 404:\n            emit(ok: true, message: "Needs server 6.72.0"',
     '            emit(ok: true, message: message, details: ["httpStatus": response.status])\n        case 404:\n            emit(ok: true, message: "Needs server 6.72.0"', "400 is an answer with the server sentence", "helper"),
]

def lane(copy, name):
    if name == "store":
        return subprocess.run(["zsh", str(copy / "Tests/run-transcription-settings.sh")], capture_output=True, text=True)
    out = copy / "build"; out.mkdir(exist_ok=True)
    build = subprocess.run([str(copy / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6",
                            "-strict-concurrency=complete", str(copy / H), str(copy / "HelperSources/ProviderStatusCore.swift"),
                            str(copy / "HelperSources/PairingCore.swift"), "-framework", "Security", "-framework", "AppKit",
                            "-o", str(out / "cos-control-helper")], capture_output=True, text=True)
    if build.returncode != 0:
        return build
    return subprocess.run(["python3", str(copy / "Tests/transcription-settings-helper-checks.py"), str(out / "cos-control-helper"),
                           str(copy / "Tests/fixtures/stt-settings-6.72.0.json")], capture_output=True, text=True)

def main():
    root, scratch = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    wanted = set(sys.argv[3:])
    copy = scratch / "copy"
    shutil.rmtree(copy, ignore_errors=True)
    shutil.copytree(root, copy, ignore=shutil.ignore_patterns(".git"))
    chosen = [m for m in MUTANTS if not wanted or m[0] in wanted]
    for name in sorted({m[5] for m in chosen}):
        result = lane(copy, name)
        if result.returncode != 0:
            print(f"BASELINE RED [{name}]\n{result.stdout[-2000:]}\n{result.stderr[-2000:]}"); sys.exit(1)
        print(f"baseline green [{name}]: {result.stdout.strip().splitlines()[-1]}")
    findings = 0
    for name, path, original, mutant, words, lane_name in chosen:
        target = copy / path
        text = target.read_text()
        if text.count(original) != 1:
            print(f"NOT APPLIED [{name}]: target appears {text.count(original)} times"); findings += 1; continue
        target.write_text(text.replace(original, mutant))
        try:
            result = lane(copy, lane_name)
        finally:
            target.write_text(text)
        output = result.stdout + result.stderr
        if result.returncode == 0:
            print(f"SURVIVED [{name}]"); findings += 1
        elif "error:" in output and ("compile-bounded: failed" in output or "compile-guard" in output) and words not in output:
            print(f"DID NOT COMPILE [{name}]"); findings += 1
        elif words not in output:
            print(f"KILLED BY THE WRONG CHECK [{name}]: expected '{words}'\n{output[-800:]}"); findings += 1
        else:
            line = next((l for l in output.splitlines() if words in l), words)
            print(f"killed [{name}]: {line.strip()[:200]}")
    print(f"{len(chosen) - findings} of {len(chosen)} mutants killed by the named check")
    sys.exit(1 if findings else 0)

main()
