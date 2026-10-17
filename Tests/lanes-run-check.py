#!/usr/bin/env python3
"""0.5.318 (2026-10-16: run-control2-foundation-contract.sh had not run in any full suite, and two of its checks had
gone stale unseen since 10/07 and 10/14): every Tests/run-*.sh lane is run by Tests/run.sh, directly or through a
lane run.sh runs, or is listed in Tests/lanes-outside-run.txt with a reason. A new lane can no longer skip silently.

    python3 Tests/lanes-run-check.py <control worktree> [--selftest]
"""
import pathlib, re, sys
root = pathlib.Path(sys.argv[1]); selftest = "--selftest" in sys.argv[2:]

def check(lanes: set[str], text_of, listed: dict[str, str]) -> list[str]:
    reached, todo = set(), ["run.sh"]
    while todo:
        name = todo.pop()
        for lane in lanes:
            if lane not in reached and lane != name and f"Tests/{lane}" in text_of(name):
                reached.add(lane); todo.append(lane)
    problems = [f"{lane}: not run by Tests/run.sh and not listed in Tests/lanes-outside-run.txt" for lane in sorted(lanes - reached - listed.keys())]
    problems += [f"{lane}: listed as outside the suite but run.sh runs it now; remove it from the list" for lane in sorted(reached & listed.keys())]
    problems += [f"{lane}: listed with no reason" for lane, why in sorted(listed.items()) if not why.strip()]
    problems += [f"{lane}: listed but there is no such lane" for lane in sorted(listed.keys() - lanes)]
    return problems

def listed_lanes(text: str) -> dict[str, str]:
    out = {}
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"): continue
        lane, _, why = line.partition(":")
        out[lane.strip()] = why.strip()
    return out

if selftest:
    texts = {"run.sh": 'zsh "$ROOT/Tests/run-a.sh"', "run-a.sh": 'zsh "$ROOT/Tests/run-b.sh"', "run-b.sh": "", "run-c.sh": ""}
    assert check({"run-a.sh", "run-b.sh", "run-c.sh"}, texts.get, {}) == ["run-c.sh: not run by Tests/run.sh and not listed in Tests/lanes-outside-run.txt"], "an unrun lane fails"
    assert check({"run-a.sh", "run-b.sh", "run-c.sh"}, texts.get, {"run-c.sh": "manual render"}) == [], "a listed lane with a reason passes; one reached through another lane counts"
    assert check({"run-a.sh", "run-b.sh"}, texts.get, {"run-b.sh": "x"})[0].startswith("run-b.sh: listed as outside"), "a stale listing fails"
    assert check({"run-a.sh", "run-b.sh", "run-c.sh"}, texts.get, {"run-c.sh": " "})[0] == "run-c.sh: listed with no reason"
    print("PASS lanes run check self-test: unrun lane, listed lane, reached through a lane, stale listing, missing reason")
    sys.exit(0)

lanes = {p.name for p in (root / "Tests").glob("run-*.sh")}
text_of = lambda name: (root / "Tests" / name).read_text() if (root / "Tests" / name).exists() else ""
problems = check(lanes, text_of, listed_lanes((root / "Tests/lanes-outside-run.txt").read_text()))
if problems: sys.exit("lanes run check failed:\n  " + "\n  ".join(problems))
print(f"PASS lanes run check: {len(lanes)} lanes, each run by the suite or listed with a reason")
