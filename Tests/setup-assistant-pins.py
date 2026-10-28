#!/usr/bin/env python3
"""Ask COS setup assistant (Sources/SetupAssistant.swift): the pins its compiled checks cannot see.

    python3 Tests/setup-assistant-pins.py <root>

  - The engine imports Foundation only, declares one top-level name (enum SetupAssistant) that no other Sources file
    uses, and has no way to run, open or send anything (no Process, NSWorkspace, URLSession, URL, defaults or files).
  - Every helper command an action names is a case in the helper's command switch, every Doctor row it reads is one the
    helper writes, and every runtime state it compares against is a RuntimeState case.
  - Its run cap is TodayRunGuard.dailyCap, and every code path a knowledge-base entry cites exists.
  - Every explicit full-app compile list names SetupAssistant.swift (Tests/kit-compile.py builds the shared kit from every
    Sources file, so a list without it would silently stop matching its kit).
  - The full suite runs this lane.
Comments are stripped before a code pin, so a comment can never satisfy one.
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
failures, passed = [], 0


def read(rel):
    return (root / rel).read_text(encoding="utf-8")


def code(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.splitlines())


def pin(condition, what):
    global passed
    if condition:
        passed += 1
    else:
        failures.append(what)


def block(text, start, end):
    i = text.index(start)
    return text[i:text.index(end, i + len(start))]


core_raw = read("Sources/SetupAssistant.swift")
core = code(core_raw)
helper = code(read("HelperSources/main.swift"))
models = code(read("Sources/Models.swift"))

# 1. Local first: Foundation only, one namespace, nothing that runs, opens or sends.
imports = re.findall(r"^import\s+(\w+)", core, re.M)
pin(imports == ["Foundation"], f"SetupAssistant.swift imports Foundation only: {imports}")
top = re.findall(r"^(?:enum|struct|class|actor|extension|func|let|var|typealias|protocol)\s+(\w+)", core, re.M)
pin(top == ["SetupAssistant"], f"one top-level declaration, enum SetupAssistant: {top}")
for banned in ("Process(", "Process.", "NSWorkspace", "URLSession", "URL(", "NSTask", "posix_spawn", "popen", "system(", "UserDefaults",
               "FileManager", "NSPasteboard", "Data(contentsOf", "write(to"):
    pin(banned not in core, f"the engine never uses {banned}")
others = [p.name for p in (root / "Sources").glob("*.swift")
          if p.name != "SetupAssistant.swift" and re.search(r"\b(enum|struct|class|typealias|actor)\s+SetupAssistant\b", p.read_text(encoding="utf-8"))]
pin(not others, f"no other Sources file declares SetupAssistant: {others}")

# 2. The helper commands exist, in the helper's command switch.
commands = re.findall(r'case \.(\w+): return "([a-z-]+)"', block(core, "var helperCommand: String? {", "default: return nil"))
pin(len(commands) == 8, f"eight actions are helper commands: {commands}")
switch = block(helper, "        switch command {", '        default: throw HelperError.message("unknown command')
for action, command in commands:
    pin(f'case "{command}":' in switch, f"{action}: the helper's command switch has a case \"{command}\"")

# 3. The Doctor rows it reads are rows the helper writes.
names = re.findall(r'static let \w+ = "([^"]+)"', block(core, "enum CheckName {", "}"))
pin(len(names) == 6, f"six Doctor rows are read: {names}")
doctor = block(helper, "private func doctorDetails(redacted: Bool)", "private func manifestConfiguredWorkDirectory")
for name in names:
    pin(f'add("{name}"' in doctor, f'doctorDetails writes the "{name}" row')

# 4. The runtime states it compares against are RuntimeState cases.
states = set(re.findall(r'runtimeState [!=]= "(\w+)"', core))
states |= set(re.findall(r'case "(\w+)":', block(core, "switch s.runtimeState {", "default:")))
cases = set(re.findall(r"case (\w+)", block(helper, "enum RuntimeState: String {", "}")))
pin(states and states <= cases, f"runtime states {sorted(states - cases)} are not RuntimeState cases")

# 5. The cap it quotes is the Today cap.
cap = re.search(r"static let dailyCap = (\d+)", models)
runs = re.search(r"static let dailyRuns = (\d+)", core)
pin(cap and runs and cap.group(1) == runs.group(1), "dailyRuns equals TodayRunGuard.dailyCap")

# 6. Every code path a knowledge-base entry cites exists.
sources = re.findall(r'source: "([^"]+)"', core_raw)
pin(len(sources) == core_raw.count("Entry(id:"), "every knowledge-base entry has a source")
for cited in sorted({p for s in sources for p in re.findall(r"\b((?:Sources|HelperSources)/\w+\.swift)", s)}):
    pin((root / cited).is_file(), f"cited file {cited} exists")

# 7. Every explicit full-app compile list names the file (they all end a line with SessionUsageView.swift).
lists = 0
for path in sorted(list(root.glob("scripts/*.sh")) + list(root.glob("Tests/*.sh"))):
    text = path.read_text(encoding="utf-8")
    lists += text.count('"$ROOT/Sources/SessionUsageView.swift" "$ROOT/Sources/SetupAssistant.swift" \\\n')
    pin('"$ROOT/Sources/SessionUsageView.swift" \\\n' not in text, f"{path.relative_to(root)}: a full-app compile list leaves out SetupAssistant.swift")
pin(lists >= 10, f"SetupAssistant.swift is in the explicit full-app compile lists ({lists} found, 10 expected)")
release = read("scripts/build-release.sh")
pin(release.count('"$ROOT/Sources/SetupAssistant.swift"') == 1, "the release build compiles SetupAssistant.swift once")

# 8. The suite runs the lane.
pin(read("Tests/run.sh").count('zsh "$ROOT/Tests/run-setup-assistant.sh"') == 1, "Tests/run.sh runs the setup assistant lane once")

if failures:
    for failure in failures:
        print("Setup assistant pin: " + failure, file=sys.stderr)
    sys.exit(1)
print(f"PASS: setup assistant pins, {passed} passed")
