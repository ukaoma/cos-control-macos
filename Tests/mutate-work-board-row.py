#!/usr/bin/env python3
"""0.5.317 mutation gate for the Work board session row (WorkBoardSessionsProjection.cards).

    python3 Tests/mutate-work-board-row.py <control worktree> [name ...]   (run by hand, never by a gate)

Serial, on a scratch copy of Sources/, Tests/ and HelperSources/, through Tests/compile-guard.sh. A GREEN baseline of
Tests/run-control2-foundation-contract.sh is required before the first mutant; each mutant must land exactly once and
make that lane FAIL.
"""
import os, pathlib, shutil, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1]).resolve(); only = set(sys.argv[2:])
W = "Sources/WorkWorkspaceView.swift"
MUTANTS = [
 ("fallback drops the resolved session", W, 'session: WorkHandoffStore.listedSession(for: receipt, in: sessions) ?? own)', 'session: WorkHandoffStore.listedSession(for: receipt, in: sessions))'),
 ("fallback takes another receipt's session", W, 'let own = receipt.id == item.activity?.receipt.id ? item.activity?.session : nil', 'let own = item.activity?.session'),
]

def run(work: pathlib.Path):
    r = subprocess.run(["/bin/zsh", str(work / "Tests/run-control2-foundation-contract.sh")], cwd=work, capture_output=True, text=True)
    out = r.stdout + r.stderr
    why = next((l.strip() for l in out.splitlines() if "Precondition failed" in l or "Fatal error" in l), "")
    if not why and "error:" in out: why = "COMPILE: " + next(l.strip() for l in out.splitlines() if "error:" in l)
    return r.returncode, why, out

work = pathlib.Path(tempfile.mkdtemp(prefix="cos-work-row-mutants-", dir="/private/tmp"))
os.environ.setdefault("COS_TEST_KIT_DIR", str(work / ".kits"))
try:
    for folder in ("Sources", "Tests", "HelperSources", "Resources"):
        if (root / folder).exists(): shutil.copytree(root / folder, work / folder, ignore=shutil.ignore_patterns("__pycache__"))
    code, why, out = run(work)
    if code != 0: sys.exit("baseline is not green; refusing to mutate:\n" + out[-3000:])
    print("baseline green")
    missing, survivors = [], []
    for name, f, a, b in MUTANTS:
        if only and name not in only: continue
        p = work / f; src = p.read_text()
        if src.count(a) != 1: print(f"MISSING  {name}: target appears {src.count(a)} times"); missing.append(name); continue
        p.write_text(src.replace(a, b))
        try: code, why, _ = run(work)
        finally: p.write_text(src)
        print(("KILLED   " if code != 0 else "SURVIVED ") + name + (f"  [{why}]" if why else ""))
        if code == 0: survivors.append(name)
    if missing or survivors: sys.exit(f"gate failed: missing={missing} survivors={survivors}")
    print("PASS Work board row mutation gate: every mutant killed")
finally:
    shutil.rmtree(work, ignore_errors=True)
