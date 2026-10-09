#!/usr/bin/env python3
"""The appcast's whatsNew through the COMPILED helper's check-app-update (2026-10-09), never the live appcast.

Usage: whats-new-helper-checks.py <compiled cos-control-helper>

Each case writes an appcast to a /tmp folder and runs `check-app-update --appcast-url file://...` with a scratch home.
Every failure names its behaviour as "check failed [<behaviour>]" for Tests/mutate-whats-new.py.
"""
import json, pathlib, shutil, subprocess, sys, tempfile

helper = sys.argv[1]
root = pathlib.Path(tempfile.mkdtemp(prefix="cos-whats-new-helper-", dir="/tmp"))
env = {"PATH": "/usr/bin:/bin", "HOME": str(root), "CFFIXED_USER_HOME": str(root), "COS_CONTROL_TEST_HOME": str(root)}
passed = 0


def fail(behaviour, detail):
    print(f"check failed [{behaviour}]: {detail}")
    shutil.rmtree(root, ignore_errors=True)
    sys.exit(1)


def check(ok, behaviour, detail=""):
    global passed
    if not ok:
        fail(behaviour, detail)
    passed += 1


def appcast(stable_extra=None, raw_whats_new=None, has_whats_new=True):
    stable = {"version": "0.5.275", "build": 328, "url": "https://example.invalid/COS-Control.zip",
              "sha256": "0" * 64, "minMacOS": "14.0", "notes": "Old notes for 0.5.275."}
    if has_whats_new:
        stable["whatsNew"] = raw_whats_new
    stable.update(stable_extra or {})
    return {"schemaVersion": 1, "channels": {"stable": stable}, "killSwitch": {"disableAutoUpdate": False, "reason": ""}}


def run(document, name):
    path = root / f"{name}.json"
    path.write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
    out = subprocess.run([helper, "check-app-update", "--current-version", "0.5.274", "--current-build", "327",
                          "--appcast-url", path.as_uri()], capture_output=True, text=True, env=env, timeout=60)
    try:
        value = json.loads(out.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        fail("helper output", f"{name}: no JSON (exit {out.returncode}): {out.stdout[-400:]} {out.stderr[-400:]}")
    check(value.get("ok") is True, "helper output", f"{name}: {value}")
    return value["details"]


VALID = {
    "summary": "Update now opens a What's New window.\nIt lists what changed.",
    "sections": [{"title": "Added", "items": ["One", "Two"]}, {"title": "Fixed", "items": ["Three"]}],
}

# Valid: passed through as is, alongside the offer and the old notes.
d = run(appcast(raw_whats_new=VALID), "valid")
check(d.get("updateAvailable") is True and d.get("reason") == "newer", "whatsNew valid", f"the offer still stands: {d}")
check(d.get("notes") == "Old notes for 0.5.275.", "whatsNew valid", "notes still passed for older apps")
check(d.get("whatsNew") == VALID, "whatsNew valid", f"passed through unchanged: {d.get('whatsNew')}")

# Absent: no whatsNew key at all, and notes as before (the app shows notes as the summary).
d = run(appcast(has_whats_new=False), "absent")
check("whatsNew" not in d and d.get("notes") == "Old notes for 0.5.275." and d.get("updateAvailable") is True,
      "whatsNew absent", f"no key and the notes: {d}")
d = run(appcast(raw_whats_new=None), "null")
check("whatsNew" not in d, "whatsNew absent", "null is absent")

# Wrong types.
for name, raw in (("string", "Added things"), ("number", 3), ("list", [VALID]), ("empty", {}),
                  ("all-wrong", {"summary": 5, "sections": "Added"})):
    d = run(appcast(raw_whats_new=raw), f"wrong-{name}")
    check("whatsNew" not in d, "whatsNew wrong types", f"{name}: {d.get('whatsNew')}")
    check(d.get("updateAvailable") is True, "whatsNew wrong types", f"{name}: a bad whatsNew never breaks the offer")
d = run(appcast(raw_whats_new={"summary": ["x"], "sections": [
    "not a section", {"title": 4, "items": ["no title"]}, {"items": ["missing title"]},
    {"title": "Kept", "items": [1, "kept item", None, {}, "   "]}, {"title": "Empty", "items": [False]},
    {"title": "Items not a list", "items": "one"}]}), "wrong-mixed")
check(d.get("whatsNew") == {"sections": [{"title": "Kept", "items": ["kept item"]}]}, "whatsNew wrong types",
      f"dropped one by one: {d.get('whatsNew')}")

# Oversize.
long = "a" * 5000
d = run(appcast(raw_whats_new={"summary": long, "sections": [
    {"title": f"Section {i} " + "t" * 200, "items": [f"item {j} " + long for j in range(30)]} for i in range(20)]}), "oversize")
w = d.get("whatsNew") or fail("whatsNew oversize", "oversize content must still pass")
check(len(w["summary"]) == 1200 and w["summary"].endswith("…"), "whatsNew oversize", f"summary {len(w['summary'])}")
check(len(w["sections"]) == 8, "whatsNew oversize", f"sections {len(w['sections'])}")
check(all(len(s["items"]) == 12 for s in w["sections"]), "whatsNew oversize", "12 items each")
check(all(len(i) == 400 for s in w["sections"] for i in s["items"]), "whatsNew oversize", "items 400 characters")
check(all(len(s["title"]) == 80 for s in w["sections"]), "whatsNew oversize", "titles 80 characters")
check(w["sections"][0]["title"].startswith("Section 0 ") and w["sections"][7]["title"].startswith("Section 7 ")
      and w["sections"][0]["items"][11].startswith("item 11 "), "whatsNew oversize", "the first ones, in order")
exact = "b" * 400
d = run(appcast(raw_whats_new={"sections": [{"title": "Exact", "items": [exact]}]}), "exact")
check(d["whatsNew"]["sections"][0]["items"][0] == exact, "whatsNew oversize", "400 characters stay whole")

# Control characters and bidi controls.
d = run(appcast(raw_whats_new={
    "summary": "line one\r\nline two\n\n\n\nline \u0007three‮",
    "sections": [{"title": "Ti\u0000tle", "items": ["esc\u001b[31mred", "tab\there", "abc‮gnp.exe", "⁦iso⁩ ‏mark",
                                                    "next\u0085line", "one\ntwo", "Café 日本"]}]}), "control")
w = d.get("whatsNew") or fail("whatsNew control chars", "must pass")
check(w["summary"] == "line one\nline two\n\nline three", "whatsNew control chars", f"summary {w['summary']!r}")
check(w["sections"][0]["title"] == "Ti tle", "whatsNew control chars", f"title {w['sections'][0]['title']!r}")
check(w["sections"][0]["items"] == ["esc [31mred", "tab here", "abcgnp.exe", "iso mark", "next line", "one two", "Café 日本"],
      "whatsNew control chars", f"items {w['sections'][0]['items']!r}")
d = run(appcast(raw_whats_new={"summary": "\u0007 ‮"}), "control-empty")
check("whatsNew" not in d, "whatsNew control chars", "nothing left after cleaning is absent")

# Only the stable channel's whatsNew counts (a top-level one is not read).
doc = appcast(has_whats_new=False)
doc["whatsNew"] = VALID
d = run(doc, "top-level")
check("whatsNew" not in d, "whatsNew stable only", "a top-level whatsNew is not the release's")

# Up to date: still passed (the window can show what this build brought), and the offer says not newer.
doc = appcast(raw_whats_new=VALID, stable_extra={"build": 327, "version": "0.5.274"})
d = run(doc, "up-to-date")
check(d.get("updateAvailable") is False and d.get("reason") == "upToDate", "whatsNew valid", f"up to date: {d}")

shutil.rmtree(root, ignore_errors=True)
print(f"whatsNew helper checks: {passed} passed (valid, absent, wrong types, oversize, control characters, stable only)")
