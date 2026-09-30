#!/usr/bin/env python3
"""0.5.252: proves the GOTCOS stock-control guard in Tests/run.sh can fail, and does not fail on prose.

The guard is the Python heredoc under "0.5.251: the GOTCOS theme on every stock macOS control" in Tests/run.sh. This
copies Sources to a scratch folder, adds one small file holding one form at a time, and runs the guard on the copy:
every banned form (including one split across lines) must make it exit non-zero and name the file; every allowed form
(prose in line and block comments, PlainButtonStyle(), a plain field, a themed Menu) must leave it passing. The real
Sources are never touched.
"""
import pathlib, re, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1]
script = (root / "Tests" / "run.sh").read_text(encoding="utf-8")
header = script.index("# ── 0.5.251: the GOTCOS theme on every stock macOS control")
start = script.index("<<'PY'\n", header) + len("<<'PY'\n")
guard = script[start:script.index("\nPY\n", start)]

BANNED = {
    "a bare Picker": 'let a = Picker("x", selection: .constant(1)) { Text("a") }',
    "borderless button": 'let a = Button("x") {}.buttonStyle(.borderless)',
    "bordered, split across lines": 'let a = Button("x") {}.buttonStyle(\n    .bordered\n)',
    "long-form bordered": 'let a = Button("x") {}.buttonStyle(BorderedButtonStyle())',
    "long-form borderless": 'let a = Button("x") {}.buttonStyle(BorderlessButtonStyle())',
    "circular progress": 'let a = ProgressView().progressViewStyle(.circular)',
    "long-form circular progress": 'let a = ProgressView().progressViewStyle(CircularProgressViewStyle())',
    "a default TextField": 'let a = TextField("x", text: .constant(""))',
    "a rounded TextField": 'let a = TextField("x", text: .constant("")).textFieldStyle(.roundedBorder)',
    "a default SecureField": 'let a = SecureField("x", text: .constant(""))',
    "a bare Menu": 'let a = Menu("x") { Button("a") {} }',
    "long-form switch": 'let a = Toggle("x", isOn: .constant(true)).toggleStyle(SwitchToggleStyle())',
    "button toggle": 'let a = Toggle("x", isOn: .constant(true)).toggleStyle(.button)',
    "long-form segmented": 'let a = EmptyView().pickerStyle(SegmentedPickerStyle())',
    "long-form menu style": 'let a = Menu("x") { EmptyView() }.menuStyle(BorderlessButtonMenuStyle()).cosMenu()',
}
ALLOWED = {
    "prose in a block comment": '/* Button("x") {}.buttonStyle(.borderless)\n   Picker("x", selection: .constant(1)) { } */\nlet a = 1',
    "prose in a line comment": '// .progressViewStyle(.circular) and TextField("x", text: .constant(""))\nlet a = 1',
    "PlainButtonStyle()": 'let a = Button("x") {}.buttonStyle(PlainButtonStyle())',
    "a plain field": 'let a = TextField("x", text: .constant("")).textFieldStyle(.plain).cosField()',
    "a themed Menu": 'let a = Menu("x") { Button("a") {} }.cosMenu()',
}

def run(body):
    with tempfile.TemporaryDirectory(prefix="cos-guard-") as scratch:
        copy = pathlib.Path(scratch)
        shutil.copytree(root / "Sources", copy / "Sources")
        (copy / "Sources" / "ZZGuardProbe.swift").write_text("import SwiftUI\n@MainActor func guardProbe() {\n" + body + "\n}\n", encoding="utf-8")
        done = subprocess.run([sys.executable, "-", str(copy)], input=guard, capture_output=True, text=True)
        return done.returncode, done.stdout + done.stderr

failures = []
for name, body in BANNED.items():
    code, out = run(body)
    if code == 0 or "ZZGuardProbe.swift" not in out:
        failures.append(f"the guard let {name} through: exit {code}\n{out}")
for name, body in ALLOWED.items():
    code, out = run(body)
    if code != 0:
        failures.append(f"the guard failed on {name}: exit {code}\n{out}")
if failures:
    sys.exit("\n".join(failures))
print(f"PASS: the stock-control guard fails on {len(BANNED)} banned forms and passes {len(ALLOWED)} allowed ones (0.5.252)")
