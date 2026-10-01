#!/usr/bin/env python3
"""No test may touch the desktop of whoever is using the Mac, and no test drives the UI.

0.5.252 (Miles, 2026-09-30: focus jumped and his clicks landed in the wrong window while test gates ran). 0.5.253 (Miles,
2026-09-30 19:06: "We don't want the testing 'computer use' where we jump and click. It doesn't work and it now causes
random missed clicked error sound."): no opt-in and no off-screen placement makes any of these allowed any more. This
fails when any Swift file under Tests/:
  - activates an app (NSApp.activate, app.activate, activate(ignoringOtherApps:)), or asks for a regular or accessory
    activation policy (an app that can show windows and take the focus);
  - orders a window in (orderFrontRegardless, orderFront, makeKeyAndOrderFront, orderWindow, addChildWindow, makeKey,
    makeMain), even far off screen: a check draws a window that is never ordered in;
  - makes or sends a synthetic event: sendEvent or postEvent, NSEvent.mouseEvent, keyEvent, otherEvent or NSEvent(cgEvent:),
    any CGEvent, posting one (post(tap:), postToPid, CGEventPost), moving the pointer, or calling a view's own mouse, key or
    scroll handler with an event;
  - plays a sound (NSSound, NSBeep, AudioServicesPlay...);
  - adds a MenuBarExtra or a status item outside the hand-run fence canary, or a WindowGroup outside the lab app a person
    runs by hand;
and when a gate script sets a desktop opt-in variable or runs a hand-run canary.

    python3 Tests/desktop-safety-check.py [root]              the check
    python3 Tests/desktop-safety-check.py [root] --selftest   proves each rule fails on a scratch copy
"""
import pathlib, re, shutil, sys, tempfile

CANARIES = ("fence-canary",)
# Apps a person builds and opens by hand (scripts/build-foundation-lab.sh); no gate launches them.
HAND_RUN_APPS = ("Control2FoundationLabApp.swift",)

RULES = (
    (r"(?<![A-Za-z0-9_])activate\s*\(", "activates an app"),
    (r"setActivationPolicy\s*\(\s*\.(regular|accessory)\s*\)", "asks for an activation policy that can show windows and take the focus"),
    (r"\.\s*(orderFrontRegardless|makeKeyAndOrderFront|orderFront|orderWindow|addChildWindow|makeKey|makeMain)\s*\(",
     "orders a window in (no test does, even off screen)"),
    (r"(?<![A-Za-z0-9_])(sendEvent|postEvent)\s*\(", "sends an event into an app"),
    (r"NSEvent\s*\.\s*(mouseEvent|keyEvent|otherEvent|enterExitEvent)\s*\(|NSEvent\s*\(\s*cgEvent\s*:", "makes a synthetic event"),
    (r"(?<![A-Za-z0-9_])CGEvent\s*\(|CGEventCreate|CGEventPost|\.\s*postToPid\s*\(|\.\s*post\s*\(\s*tap\s*:", "makes or posts a system event"),
    (r"CGWarpMouseCursorPosition|CGDisplayMoveCursorToPoint|CGAssociateMouseAndMouseCursorPosition", "moves the pointer"),
    (r"\.\s*(mouseDown|mouseUp|mouseMoved|mouseDragged|rightMouseDown|keyDown|keyUp|scrollWheel|flagsChanged)\s*\(\s*with\s*:",
     "calls a view's own event handler with an event"),
    (r"(?<![A-Za-z0-9_])(NSSound|NSBeep|AudioServicesPlaySystemSound|AudioServicesPlayAlertSound)(?![A-Za-z0-9_])", "plays a sound"),
)

def code_lines(text):
    """(line number, code) with line comments and block comments blanked."""
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    for number, line in enumerate(text.split("\n"), 1):
        yield number, re.sub(r"(^|\s)//.*$", r"\1", line)

def shell_lines(text):
    for number, line in enumerate(text.split("\n"), 1):
        if not line.lstrip().startswith("#"):
            yield number, line

def check(root):
    tests = root / "Tests"
    hits = []
    for path in sorted(tests.rglob("*.swift")):
        rel = path.relative_to(root)
        canary = any(part in CANARIES for part in rel.parts)
        for number, line in code_lines(path.read_text(encoding="utf-8")):
            for pattern, why in RULES:
                if re.search(pattern, line):
                    hits.append(f"  {rel}:{number}: {why}")
            if not canary and re.search(r"(?<![A-Za-z0-9_])MenuBarExtra\s*\(|NSStatusBar\s*\.\s*system\s*\.\s*statusItem", line):
                hits.append(f"  {rel}:{number}: adds a status item outside the hand-run canary")
            if not canary and path.name not in HAND_RUN_APPS and re.search(r"(?<![A-Za-z0-9_])WindowGroup\s*[({]", line):
                hits.append(f"  {rel}:{number}: opens an app window outside the hand-run canary and lab")
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
    S = "Tests/ZZDesk.swift"
    cases = {
        "an activate": (S, "import AppKit\n@MainActor func z() { NSApp.activate(ignoringOtherApps: true) }\n"),
        "an app.activate": (S, "import AppKit\n@MainActor func z(app: NSApplication) { app.activate() }\n"),
        "an opt-in activate (no longer allowed)": (S,
            'import AppKit\n@MainActor func z() { if ProcessInfo.processInfo.environment["COS_DESKTOP_CANARY"] == "1" { NSApp.activate(ignoringOtherApps: true) } }\n'),
        "a regular policy": (S, "import AppKit\n@MainActor func z() { NSApp.setActivationPolicy(.regular) }\n"),
        "an accessory policy": (S, "import AppKit\n@MainActor func z() { NSApp.setActivationPolicy(.accessory) }\n"),
        "a window ordered in far off screen (no longer allowed)": (S,
            "import AppKit\n@MainActor func z(w: NSWindow) { NSApp.setActivationPolicy(.prohibited); w.setFrameOrigin(NSPoint(x: -8000, y: -8000)); w.orderFrontRegardless() }\n"),
        "a makeKeyAndOrderFront": (S, "import AppKit\n@MainActor func z(w: NSWindow) { w.makeKeyAndOrderFront(nil) }\n"),
        "an orderFront": (S, "import AppKit\n@MainActor func z(w: NSWindow) { w.orderFront(nil) }\n"),
        "an orderWindow": (S, "import AppKit\n@MainActor func z(w: NSWindow) { w.orderWindow(.above, relativeTo: 0) }\n"),
        "a child window": (S, "import AppKit\n@MainActor func z(a: NSWindow, b: NSWindow) { a.addChildWindow(b, ordered: .above) }\n"),
        "an opt-in makeKeyAndOrderFront (no longer allowed)": (S,
            'import AppKit\n@MainActor func z(w: NSWindow) { if ProcessInfo.processInfo.environment["COS_DESKTOP_CANARY"] == "1" { w.makeKeyAndOrderFront(nil) } }\n'),
        "a mouse event sent through the app": (S,
            "import AppKit\n@MainActor func z(w: NSWindow) {\n    let e = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,\n"
            "        windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!\n    NSApp.sendEvent(e)\n}\n"),
        "a key event sent to a window": (S, "import AppKit\n@MainActor func z(w: NSWindow, e: NSEvent) { w.sendEvent(e) }\n"),
        "a key event made": (S,
            "import AppKit\nfunc z() { _ = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,\n"
            "    context: nil, characters: \"a\", charactersIgnoringModifiers: \"a\", isARepeat: false, keyCode: 0) }\n"),
        "a scroll made from a CGEvent": (S,
            "import AppKit\nfunc z() { let w = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!\n"
            "    _ = NSEvent(cgEvent: w) }\n"),
        "a posted system event": (S, "import AppKit\nfunc z(e: CGEvent) { e.post(tap: .cghidEventTap) }\n"),
        "an event posted to a process": (S, "import AppKit\nfunc z(e: CGEvent) { e.postToPid(1) }\n"),
        "a pointer warp": (S, "import AppKit\nfunc z() { CGWarpMouseCursorPosition(.zero) }\n"),
        "a view's handler called with an event": (S, "import AppKit\n@MainActor func z(v: NSView, e: NSEvent) { v.mouseMoved(with: e) }\n"),
        "a sound": (S, "import AppKit\nfunc z() { NSSound.beep() }\n"),
        "a status item": (S, "import AppKit\n@MainActor func z() { _ = NSStatusBar.system.statusItem(withLength: 20) }\n"),
        "an app window": (S, "import SwiftUI\nstruct Z: App { var body: some Scene { WindowGroup { Text(\"x\") } } }\n"),
        "a gate that sets the opt-in": ("Tests/zz-gate.sh", "#!/bin/zsh\nCOS_DESKTOP_CANARY=1 ./x\n"),
        "a gate that runs the canary": ("Tests/zz-gate.sh", "#!/bin/zsh\n\"$ROOT/Tests/fence-canary/run.sh\"\n"),
    }
    allowed = {
        "prose about activate and events": (S, "// NSApp.activate(ignoringOtherApps: true) and NSApp.sendEvent(e) took the focus\n/* w.orderFrontRegardless() */\nlet z = 1\n"),
        "a window made and never ordered in": (S,
            "import AppKit\n@MainActor func z() -> NSWindow {\n    NSApp.setActivationPolicy(.prohibited)\n    let window = NSWindow(\n"
            "        contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: .zero),\n"
            "        styleMask: [.borderless], backing: .buffered, defer: false)\n    window.contentView?.layoutSubtreeIfNeeded()\n    return window\n}\n"),
        "a window taken off screen": (S, "import AppKit\n@MainActor func z(w: NSWindow) { w.orderOut(nil); w.close() }\n"),
        "a view drawn to a bitmap": (S,
            "import AppKit\n@MainActor func z(v: NSView) { let r = v.bitmapImageRepForCachingDisplay(in: v.bounds)!; v.cacheDisplay(in: v.bounds, to: r) }\n"),
        "a deactivate and a sendEvents name": (S, "import AppKit\n@MainActor func z(x: NSObject) { _ = x.responds(to: Selector((\"deactivate\"))); let sendEvents = 1; _ = sendEvents }\n"),
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
    print(f"PASS: the desktop-safety check fails on {len(cases)} desktop-touching or UI-driving forms and passes {len(allowed)} allowed ones (0.5.253)")

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = pathlib.Path(args[0]) if args else pathlib.Path(__file__).resolve().parents[1]
    if "--selftest" in sys.argv:
        selftest(root)
    else:
        hits = check(root)
        if hits:
            sys.exit("a test can touch the desktop of whoever is using the Mac, or drive its UI:\n" + "\n".join(hits))
        print("COS Control: no test activates an app, puts a window on screen, sends or posts an event, plays a sound or adds a status item (0.5.253)")
