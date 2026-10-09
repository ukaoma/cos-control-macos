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
        # split("\n"), never splitlines(): that also splits on U+0085 and U+2028, which a leaking helper would emit raw.
        value = json.loads([l for l in out.stdout.split("\n") if l.strip()][-1])
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
check(len(w["summary"]) == 1200 and w["summary"].endswith("\u2026"), "whatsNew oversize", f"summary {len(w['summary'])}")
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
    "summary": "line one\r\nline two\n\n\n\nline \u0007three\u202e",
    "sections": [{"title": "Ti\u0000tle", "items": ["esc\u001b[31mred", "tab\there", "abc\u202egnp.exe", "\u2066iso\u2069 \u200fmark",
                                                    "next\u0085line", "one\ntwo", "Café 日本"]}]}), "control")
w = d.get("whatsNew") or fail("whatsNew control chars", "must pass")
check(w["summary"] == "line one\nline two\n\nline three", "whatsNew control chars", f"summary {w['summary']!r}")
check(w["sections"][0]["title"] == "Ti tle", "whatsNew control chars", f"title {w['sections'][0]['title']!r}")
check(w["sections"][0]["items"] == ["esc [31mred", "tab here", "abcgnp.exe", "iso mark", "next line", "one two", "Café 日本"],
      "whatsNew control chars", f"items {w['sections'][0]['items']!r}")
d = run(appcast(raw_whats_new={"summary": "\u0007 \u202e"}), "control-empty")
check("whatsNew" not in d, "whatsNew control chars", "nothing left after cleaning is absent")

# Format characters (Cf) and a combining-mark bomb (QA 2026-10-09).
d = run(appcast(raw_whats_new={"summary": "\u200b\u200b\ufeff", "sections": [
    {"title": "\u200bAdded\u2060", "items": ["zero\u200bwidth\u200cnon\u200djoiner", "tag\U000e0001\U000e0041\U000e007fs",
                                            "\u2061\u2064\u206a\u206fx", "a" + "\u0301" * 5000]},
    {"title": "\u200b", "items": ["dropped: the title is invisible"]}]}), "format")
w = d.get("whatsNew") or fail("whatsNew format chars", "must pass")
check("summary" not in w, "whatsNew format chars", f"a zero-width summary is absent (so the app shows notes): {w.get('summary')!r}")
check(len(w["sections"]) == 1 and w["sections"][0]["title"] == "Added", "whatsNew format chars", f"titles: {[s['title'] for s in w['sections']]!r}")
items = w["sections"][0]["items"]
check(items[:3] == ["zerowidthnonjoiner", "tags", "x"], "whatsNew format chars", f"items {items[:3]!r}")
check(len(items[3]) == 1600 and items[3].endswith("\u2026"), "whatsNew scalar cap", f"a combining-mark bomb is capped at 1600 scalars, got {len(items[3])}")
d = run(appcast(raw_whats_new={"sections": [{"title": "Accents", "items": ["e\u0301" * 300]}]}), "accents")
check(d["whatsNew"]["sections"][0]["items"][0] == "e\u0301" * 300, "whatsNew scalar cap", "ordinary accents are untouched")

# Only the stable channel's whatsNew counts (a top-level one is not read).
doc = appcast(has_whats_new=False)
doc["whatsNew"] = VALID
d = run(doc, "top-level")
check("whatsNew" not in d, "whatsNew stable only", "a top-level whatsNew is not the release's")

# Up to date: whatsNew still passed. The after-update window (WhatsNewAfterUpdate) shows the appcast's words when its
# stable entry is the build that is running, which is exactly this answer.
doc = appcast(raw_whats_new=VALID, stable_extra={"build": 327, "version": "0.5.274"})
d = run(doc, "up-to-date")
check(d.get("updateAvailable") is False and d.get("reason") == "upToDate", "whatsNew valid", f"up to date: {d}")

# --- QA 2026-10-09 (live in 0.5.274): stage-app-update never says ok without staging, and apply checks the stage. ---
def verb(args, name):
    out = subprocess.run([helper, *args], capture_output=True, text=True, env=env, timeout=60)
    try:
        value = json.loads([l for l in out.stdout.split("\n") if l.strip()][-1])
    except (ValueError, IndexError):
        fail("helper output", f"{name}: no JSON (exit {out.returncode}): {out.stdout[-400:]} {out.stderr[-400:]}")
    return out.returncode, value

updates = root / "Library/Application Support/COS Control/updates"
live = root / "live/COS Control.app"
stage_args = ["stage-app-update", "--current-version", "0.5.274", "--current-build", "327", "--live-bundle", str(live)]
for name, doc, words in (
    ("unreachable", None, "could not reach the update feed"),
    ("killSwitch", dict(appcast(has_whats_new=False), killSwitch={"disableAutoUpdate": True}), "paused by the publisher"),
    ("malformed", appcast(has_whats_new=False, stable_extra={"sha256": "nope"}), "missing a SHA-256"),
    ("upToDate", appcast(has_whats_new=False, stable_extra={"build": 327, "version": "0.5.274"}), "already up to date"),
):
    path = root / f"stage-{name}.json"
    if doc is not None:
        path.write_text(json.dumps(doc), encoding="utf-8")
    code, value = verb(stage_args + ["--appcast-url", path.as_uri()], f"stage-{name}")
    check(code != 0 and value.get("ok") is False, "stage refuses", f"{name}: a stage that staged nothing must not say ok: {value}")
    check(words in value.get("message", "") and "Nothing was installed." in value.get("message", ""), "stage refuses",
          f"{name}: in words: {value.get('message')}")
    check(not (updates / "pending.json").exists(), "stage refuses", f"{name}: no pending stage")

apply_detach = ["apply-app-update", "--detach", "--live-bundle", str(live), "--current-version", "0.5.274", "--current-build", "327"]
code, value = verb(apply_detach + ["--expected-build", "328"], "apply-nothing-staged")
check(code != 0 and value.get("ok") is False and value.get("message") == "No staged update to apply.", "apply needs a stage",
      f"nothing staged: refused before Control quits: {value}")
staged_app = root / "staged/COS Control.app"
staged_app.mkdir(parents=True)
updates.mkdir(parents=True, exist_ok=True)
(updates / "pending.json").write_text(json.dumps({"version": "0.5.200", "build": 100, "stagedAppPath": str(staged_app)}), encoding="utf-8")
code, value = verb(apply_detach + ["--expected-build", "328"], "apply-stale-stage")
check(code != 0 and value.get("message") == "The staged update is build 100, not build 328. Nothing was installed.", "apply expected build",
      f"a stale pending stage of another build is refused: {value}")
code, value = verb(["apply-app-update", "--swap", "--live-bundle", str(live), "--expected-build", "328"], "swap-stale-stage")
check(code != 0 and "build 100, not build 328" in value.get("message", ""), "apply expected build", f"the swap refuses it too: {value}")
failure = json.loads((updates / "last-failure.json").read_text(encoding="utf-8"))
check(failure.get("reason") == "notStaged", "apply expected build", f"the swap records why: {failure}")
(updates / "pending.json").write_text(json.dumps({"version": "0.5.275", "build": 328, "stagedAppPath": str(root / "gone/COS Control.app")}), encoding="utf-8")
code, value = verb(apply_detach + ["--expected-build", "328"], "apply-missing-app")
check(code != 0 and value.get("message") == "The staged update is missing.", "apply needs a stage", f"a staged app that is gone: {value}")

shutil.rmtree(root, ignore_errors=True)
print(f"whatsNew helper checks: {passed} passed (valid, absent, wrong types, oversize, control and format characters, stable only, stage refusals, apply checks)")
