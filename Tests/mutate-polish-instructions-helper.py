#!/usr/bin/env python3
"""0.5.335 mutation gate for the helper's polish instructions (HelperSources/ProviderStatusCore.swift
DictationPolishInstructionsBridge, the finalize flag in DictationPolishBridge.answer, and emitDictationPolishInstructions
in HelperSources/main.swift), executed by Tests/dictation-polish-instructions-helper-checks.py against the compiled
helper and a loopback fixture. SERIAL helper compiles through Tests/compile-guard.sh on a scratch copy; a green
baseline first; a kill is the checks failing on a named assertion ("AssertionError: <why>").

Usage: python3 Tests/mutate-polish-instructions-helper.py <repo root>
"""
import os, pathlib, re, shutil, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1]).resolve()
P, M = "HelperSources/ProviderStatusCore.swift", "HelperSources/main.swift"
MUTANTS = [
    ("capability not required", P, "              let cap = block[\"maxChars\"] as? NSNumber, cap.intValue > 0 else { return false }",
     "              let cap = (block[\"maxChars\"] as? NSNumber) ?? Optional(NSNumber(value: 1)), cap.intValue > 0 else { return false }"),
    ("protocol 0 accepted", P, "let proto = block[\"protocol\"] as? NSNumber, proto.intValue >= 1,", "let proto = block[\"protocol\"] as? NSNumber, proto.intValue >= 0,"),
    ("set takes extra keys", P, "            guard Set(object.keys) == [\"operation\", \"customInstructions\"], let text",
     "            guard Set(object.keys).isSuperset(of: [\"operation\", \"customInstructions\"]), let text"),
    ("blank set sent", P, "                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }\n            return .set(text)",
     "                  true else { return nil }\n            return .set(text)"),
    ("over-cap answer shown", P, "            guard let body, let text = body[\"customInstructions\"] as? String, text.utf16.count <= maximumCharacters else {",
     "            guard let body, let text = body[\"customInstructions\"] as? String else {"),
    ("413 not named", P, "        case 413: return refused(\"too_long\", \"Too long: polish instructions", "        case 418: return refused(\"too_long\", \"Too long: polish instructions"),
    ("404 shows the box", P, "        case 404: return unavailable()\n        case 413", "        case 404: return refused(\"http_404\", \"x\", status: 404)\n        case 413"),
    ("rules version unchecked", P, "        guard let body, let version = body[\"version\"] as? String, version.range(of: \"^v[0-9]{1,2}$\", options: .regularExpression) != nil,",
     "        guard let body, let version = body[\"version\"] as? String,"),
    ("finalize flag any number", P, "            if let flag = body[\"customInstructions\"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue {",
     "            if let flag = body[\"customInstructions\"] as? NSNumber, flag.boolValue {"),
    ("finalize hash unchecked", P, "                if let hash = body[\"instructionsHash\"] as? String, DictationPolishInstructionsBridge.isHash(hash) { details[\"instructionsHash\"] = hash }",
     "                if let hash = body[\"instructionsHash\"] as? String { details[\"instructionsHash\"] = hash }"),
    ("get skips the capability", M,
     "            guard DictationPolishInstructionsBridge.advertised(health.body) else { answer = DictationPolishInstructionsBridge.unavailable(); break }\n", ""),
    ("clear is a PUT", M, "            let response = request(route, method: \"DELETE\", token: token, timeout: 10)",
     "            let response = request(route, method: \"PUT\", token: token, body: DictationPolishInstructionsBridge.body(\"\"), timeout: 10)"),
]
FILES = ("HelperSources/main.swift", "HelperSources/ProviderStatusCore.swift", "HelperSources/PairingCore.swift", "Sources/WorkSessionLinks.swift")


def run(work):
    out = work / "helper"
    if out.exists(): out.unlink()
    b = subprocess.run(["/usr/bin/python3", str(root / "Tests/kit-compile.py"), "/bin/zsh", str(root / "Tests/compile-guard.sh"), "swiftc", "-target", "arm64-apple-macosx14.0",
                        "-swift-version", "6", "-strict-concurrency=complete", *[str(work / f) for f in FILES], "-framework", "Security", "-framework", "AppKit", "-o", str(out)],
                       capture_output=True, text=True)
    if b.returncode: return 2, "compile: " + b.stderr[-300:]
    r = subprocess.run(["/usr/bin/python3", str(root / "Tests/dictation-polish-instructions-helper-checks.py"), str(out)], capture_output=True, text=True, timeout=600)
    if r.returncode == 0: return 0, r.stdout.strip()[-120:]
    named = re.search(r"AssertionError: (.+)", r.stderr)
    return (1, named.group(1)) if named else (3, "no named assertion: " + r.stderr[-200:])


work = pathlib.Path(tempfile.mkdtemp(prefix="cos-polish-instr-mutants-", dir="/private/tmp"))
os.environ.setdefault("COS_TEST_KIT_DIR", str(work / ".kits"))
try:
    (work / "HelperSources").mkdir(); (work / "Sources").mkdir()
    for f in FILES: shutil.copy(root / f, work / f)
    code, msg = run(work)
    if code: sys.exit(f"baseline not green: {msg}")
    print("baseline GREEN: " + msg, flush=True)
    bad = []
    for name, f, a, b in MUTANTS:
        original = (work / f).read_text()
        if original.count(a) != 1: sys.exit(f"{name}: {original.count(a)} sites in {f}")
        (work / f).write_text(original.replace(a, b)); code, msg = run(work); (work / f).write_text(original)
        word = {0: "SURVIVED", 1: "KILLED", 2: "NO-COMPILE", 3: "CRASHED"}[code]
        print(f"{word:10} {name} :: {msg}", flush=True)
        if code != 1: bad.append(name)
    if bad: sys.exit(f"FAIL: {bad}")
    print(f"PASS polish instructions helper mutation gate: {len(MUTANTS)} of {len(MUTANTS)} killed by a named check, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
