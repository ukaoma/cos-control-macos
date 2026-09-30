#!/usr/bin/env python3
"""0.5.252: no test a gate runs may touch the desktop of whoever is using the Mac.

Miles, 2026-09-30: focus jumped and his clicks landed in the wrong window while test gates ran. A test binary that
activates itself, puts a window on screen, adds a status item or posts events to the system takes his Mac from him.
This fails when any file under Tests/:
  - activates an app (NSApp.activate, app.activate, activate(ignoringOtherApps:)) on a line that does not itself check an
    opt-in variable a person sets by hand (COS_DESKTOP_CANARY=1 or COS_JEDI_CANARY_OUTPUT);
  - moves the pointer or posts an event to the system (CGWarpMouseCursorPosition, CGDisplayMoveCursorToPoint,
    CGEvent post, CGEventPost), or asks for a regular, Dock-visible activation policy;
  - orders a window in (orderFrontRegardless, orderFront or makeKeyAndOrderFront) on a line with no opt-in check,
    without making its process unable to activate (.prohibited), or without placing THAT window far off every screen
    (-8000 or -20000) earlier in the same function: set in its contentRect when it is made, or by setFrameOrigin,
    setFrame or setFrameTopLeftPoint. Each window is checked on its own (QA round 2: a window off screen no longer
    covers another in the same file, or one of the same name in another function);
  - adds a MenuBarExtra, a status item or a WindowGroup outside the two canaries and the lab app a person runs by hand;
and when a gate script sets an opt-in variable or runs either canary.

    python3 Tests/desktop-safety-check.py [root]              the check
    python3 Tests/desktop-safety-check.py [root] --selftest   proves each rule fails on a scratch copy
"""
import pathlib, re, shutil, subprocess, sys, tempfile

OPT_IN = ('environment["COS_DESKTOP_CANARY"] == "1"', 'environment["COS_JEDI_CANARY_OUTPUT"] != nil')
CANARIES = ("dropdown-canary", "fence-canary")
# Apps a person builds and opens by hand (scripts/build-foundation-lab.sh); no gate launches them.
HAND_RUN_APPS = ("Control2FoundationLabApp.swift",)

def code_lines(text):
    """(line number, code) with line comments and block comments blanked."""
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    for number, line in enumerate(text.split("\n"), 1):
        yield number, re.sub(r"(^|\s)//.*$", r"\1", line)

ORDERS = re.compile(r"([A-Za-z_][A-Za-z0-9_]*(?:\s*[?!]?\s*\.\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*[?!]?\s*\.\s*"
                    r"(orderFrontRegardless|makeKeyAndOrderFront|orderFront)\s*\(")
OFF_SCREEN = re.compile(r"-\s*(8000|20000)\b")

def call_args(code, open_index):
    """The text inside the parentheses that open at `open_index`, across lines."""
    depth = 0
    for index in range(open_index, len(code)):
        if code[index] == "(":
            depth += 1
        elif code[index] == ")":
            depth -= 1
            if depth == 0:
                return code[open_index + 1:index]
    return code[open_index + 1:]

def off_screen(args, code):
    """True when a placement's arguments put the window far off every screen, directly or through one named constant."""
    if OFF_SCREEN.search(args):
        return True
    name = args.strip()
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
        found = re.search(r"\b(?:let|var)\s+" + name + r"\b[^=\n]*=([^\n]*)", code)
        return bool(found and OFF_SCREEN.search(found.group(1)))
    return False

def placed_off_screen(receiver, code, before):
    """Whether this window (by its receiver) is placed far off every screen in the function that shows it, before
    offset `before`."""
    starts = [found.start() for found in re.finditer(r"\bfunc\s+[A-Za-z_][A-Za-z0-9_]*|(?<![A-Za-z0-9_.])init\s*[(<]", code) if found.start() < before]
    start = starts[-1] if starts else 0
    name = re.escape(receiver)
    for found in re.finditer(r"(?<![A-Za-z0-9_.])" + name + r"\s*[?!]?\s*\.\s*setFrame(?:Origin|TopLeftPoint)?\s*\(", code):
        if start <= found.start() < before and off_screen(call_args(code, found.end() - 1), code):
            return True
    for found in re.finditer(r"\b(?:let|var)\s+" + name + r"\b[^=\n]*=\s*[A-Za-z_][A-Za-z0-9_.]*\s*\(", code):
        if start <= found.start() < before and "contentRect" in (args := call_args(code, found.end() - 1)) and off_screen(args, code):
            return True
    return False

def shell_lines(text):
    for number, line in enumerate(text.split("\n"), 1):
        stripped = line.lstrip()
        if not stripped.startswith("#"):
            yield number, line

def check(root):
    tests = root / "Tests"
    hits = []
    for path in sorted(tests.rglob("*.swift")):
        rel = path.relative_to(root)
        text = path.read_text(encoding="utf-8")
        lines = list(code_lines(text))
        code = "\n".join(line for _, line in lines)
        canary = any(part in CANARIES for part in rel.parts)
        for number, line in lines:
            if re.search(r"(?<![A-Za-z0-9_])activate\s*\(", line) and not any(flag in line for flag in OPT_IN):
                hits.append(f"  {rel}:{number}: activates an app without an opt-in check on the same line")
            if re.search(r"CGWarpMouseCursorPosition|CGDisplayMoveCursorToPoint|CGEventPost\b|\.post\s*\(\s*tap\s*:", line):
                hits.append(f"  {rel}:{number}: moves the pointer or posts an event to the system")
            if re.search(r"setActivationPolicy\s*\(\s*\.regular\s*\)", line):
                hits.append(f"  {rel}:{number}: asks for a regular (Dock) activation policy")
            if not canary and re.search(r"(?<![A-Za-z0-9_])MenuBarExtra\s*\(|NSStatusBar\s*\.\s*system\s*\.\s*statusItem", line):
                hits.append(f"  {rel}:{number}: adds a status item outside the hand-run canaries")
            if not canary and path.name not in HAND_RUN_APPS and re.search(r"(?<![A-Za-z0-9_])WindowGroup\s*[({]", line):
                hits.append(f"  {rel}:{number}: opens an app window outside the hand-run canaries and lab")
        offsets = [0]
        for _, line in lines:
            offsets.append(offsets[-1] + len(line) + 1)
        for number, line in lines:
            if any(flag in line for flag in OPT_IN):
                continue
            for order in ORDERS.finditer(line):
                receiver = re.sub(r"[\s?!]", "", order.group(1))
                where = f"  {rel}:{number}: {receiver}.{order.group(2)}"
                if "setActivationPolicy(.prohibited)" not in code:
                    hits.append(f"{where} orders a window in, but its process is not .prohibited (it could become active)")
                if not placed_off_screen(receiver, code, offsets[number - 1] + order.start()):
                    hits.append(f"{where} orders a window in that was not placed far off every screen first")
    for path in sorted(list(tests.glob("*.sh")) + list(tests.glob("*.py"))):
        rel = path.relative_to(root)
        if path.name == "desktop-safety-check.py":
            continue
        for number, line in shell_lines(path.read_text(encoding="utf-8")):
            if re.search(r"COS_DESKTOP_CANARY\s*=|COS_JEDI_CANARY_OUTPUT\s*=|export\s+COS_DESKTOP_CANARY|export\s+COS_JEDI_CANARY_OUTPUT", line):
                hits.append(f"  {rel}:{number}: a gate script sets a desktop opt-in variable")
            if re.search(r"(dropdown|fence)-canary/run\.sh\"?\s*($|[;&|])", line) and "open(" not in line and "read_text" not in line:
                hits.append(f"  {rel}:{number}: a gate script runs a hand-run canary")
    return hits

def selftest(root):
    cases = {
        "an unguarded activate": ("Tests/ZZDesk.swift", "import AppKit\n@MainActor func z() { NSApp.activate(ignoringOtherApps: true) }\n"),
        "an unguarded app.activate": ("Tests/ZZDesk.swift", "import AppKit\n@MainActor func z(app: NSApplication) { app.activate() }\n"),
        "a pointer warp": ("Tests/ZZDesk.swift", "import AppKit\nfunc z() { CGWarpMouseCursorPosition(.zero) }\n"),
        "a posted system event": ("Tests/ZZDesk.swift", "import AppKit\nfunc z(e: CGEvent) { e.post(tap: .cghidEventTap) }\n"),
        "a regular policy": ("Tests/ZZDesk.swift", "import AppKit\n@MainActor func z() { NSApp.setActivationPolicy(.regular) }\n"),
        "a window of an app that can activate": ("Tests/ZZDesk.swift",
            "import AppKit\n@MainActor func z(w: NSWindow) { w.setFrameOrigin(NSPoint(x: -8000, y: -8000)); w.orderFrontRegardless() }\n"),
        "a window on screen": ("Tests/ZZDesk.swift",
            "import AppKit\n@MainActor func z(w: NSWindow) { NSApp.setActivationPolicy(.prohibited); w.orderFrontRegardless() }\n"),
        "a status item": ("Tests/ZZDesk.swift", "import AppKit\n@MainActor func z() { _ = NSStatusBar.system.statusItem(withLength: 20) }\n"),
        "a makeKeyAndOrderFront on screen": ("Tests/ZZDesk.swift",
            "import AppKit\n@MainActor func z(w: NSWindow) { NSApp.setActivationPolicy(.prohibited); w.makeKeyAndOrderFront(nil) }\n"),
        "an orderFront on screen": ("Tests/ZZDesk.swift",
            "import AppKit\n@MainActor func z(w: NSWindow) { NSApp.setActivationPolicy(.prohibited); w.orderFront(nil) }\n"),
        "a second window on screen beside one off screen": ("Tests/ZZDesk.swift",
            "import AppKit\n@MainActor func z(a: NSWindow, b: NSWindow) {\n    NSApp.setActivationPolicy(.prohibited)\n"
            "    a.setFrameOrigin(NSPoint(x: -8000, y: -8000)); a.orderFrontRegardless()\n    b.makeKeyAndOrderFront(nil)\n}\n"),
        "a window placed off screen only after it is shown": ("Tests/ZZDesk.swift",
            "import AppKit\n@MainActor func z(w: NSWindow) {\n    NSApp.setActivationPolicy(.prohibited)\n    w.orderFront(nil)\n"
            "    w.setFrameOrigin(NSPoint(x: -8000, y: -8000))\n}\n"),
        "a window placed off screen in another function": ("Tests/ZZDesk.swift",
            "import AppKit\n@MainActor func a(window: NSWindow) {\n    NSApp.setActivationPolicy(.prohibited)\n"
            "    window.setFrameOrigin(NSPoint(x: -8000, y: -8000)); window.orderFrontRegardless()\n}\n"
            "@MainActor func b(window: NSWindow) {\n    window.makeKeyAndOrderFront(nil)\n}\n"),
        "a window made on screen": ("Tests/ZZDesk.swift",
            "import AppKit\n@MainActor func z() {\n    NSApp.setActivationPolicy(.prohibited)\n"
            "    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: false)\n"
            "    w.makeKeyAndOrderFront(nil)\n    _ = NSPoint(x: -8000, y: -8000)\n}\n"),
        "an app window": ("Tests/ZZDesk.swift", "import SwiftUI\nstruct Z: App { var body: some Scene { WindowGroup { Text(\"x\") } } }\n"),
        "a gate that sets the opt-in": ("Tests/zz-gate.sh", "#!/bin/zsh\nCOS_DESKTOP_CANARY=1 ./x\n"),
        "a gate that runs the canary": ("Tests/zz-gate.sh", "#!/bin/zsh\n\"$ROOT/Tests/dropdown-canary/run.sh\"\n"),
    }
    allowed = {
        "an opt-in activate": ("Tests/ZZDesk.swift",
            'import AppKit\n@MainActor func z() { if ProcessInfo.processInfo.environment["COS_DESKTOP_CANARY"] == "1" { NSApp.activate(ignoringOtherApps: true) } }\n'),
        "prose about activate": ("Tests/ZZDesk.swift", "// NSApp.activate(ignoringOtherApps: true) steals the focus\n/* app.activate() */\nlet z = 1\n"),
        "an off-screen window of a prohibited app": ("Tests/ZZDesk.swift",
            "import AppKit\n@MainActor func z(w: NSWindow) { NSApp.setActivationPolicy(.prohibited); w.setFrameOrigin(NSPoint(x: -8000, y: -8000)); w.orderFrontRegardless() }\n"),
        "a window made off screen, then made key, in a prohibited app": ("Tests/ZZDesk.swift",
            "import AppKit\n@MainActor func z() {\n    NSApp.setActivationPolicy(.prohibited)\n    let window = NSWindow(\n"
            "        contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: .zero),\n"
            "        styleMask: [.borderless], backing: .buffered, defer: false)\n    window.makeKeyAndOrderFront(nil)\n}\n"),
        "an opt-in makeKeyAndOrderFront": ("Tests/ZZDesk.swift",
            'import AppKit\n@MainActor func z(w: NSWindow) { if ProcessInfo.processInfo.environment["COS_DESKTOP_CANARY"] == "1" { w.makeKeyAndOrderFront(nil) } }\n'),
    }
    failures = []
    for group, expect_hits in ((cases, True), (allowed, False)):
        for name, (rel, body) in group.items():
            with tempfile.TemporaryDirectory(prefix="cos-desk-") as scratch:
                copy = pathlib.Path(scratch)
                shutil.copytree(root / "Tests", copy / "Tests")
                (copy / rel).write_text(body, encoding="utf-8")
                hits = [h for h in check(copy) if "ZZDesk" in h or "zz-gate" in h]
                if expect_hits and not hits:
                    failures.append(f"the desktop check let {name} through")
                if not expect_hits and hits:
                    failures.append(f"the desktop check failed on {name}: {hits}")
    if failures:
        sys.exit("\n".join(failures))
    print(f"PASS: the desktop-safety check fails on {len(cases)} desktop-touching forms and passes {len(allowed)} allowed ones (0.5.252)")

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = pathlib.Path(args[0]) if args else pathlib.Path(__file__).resolve().parents[1]
    if "--selftest" in sys.argv:
        selftest(root)
    else:
        hits = check(root)
        if hits:
            sys.exit("a test can touch the desktop of whoever is using the Mac:\n" + "\n".join(hits))
        print("COS Control: no gate test activates an app, shows a window on screen, adds a status item or posts a system event (0.5.252)")
