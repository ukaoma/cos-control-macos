#!/usr/bin/env python3
"""0.5.317 Work chat mutation scope: which mutants of the two Work chat gates must run for this release, and the proof
that each skipped one targets code byte-identical to the last release where it ran.

    python3 Tests/work-mutation-scope.py <control worktree> [--write]

The run set:
  * every mutant of Tests/mutate-work-chat-queue.py (all new in 0.5.317);
  * every mutant of Tests/mutate-work-chat-review.py that is new or retargeted since BASELINE (0.5.315), which covers
    the 0.5.317 retargets and control-mute's 0.5.316 discovery and gate mutants;
  * every mutant whose target lies inside dispatch() or sendContext() in HEAD's WorkTaskChat.swift (0.5.317
    restructured dispatch(), and a queued assignment gets sendContext()'s re-checks again when it sends);
  * every mutant whose target lies inside WorkChatPreflight.holds() or blockers() (they now also decide queued and
    parallel sends);
  * every remaining mutant whose target lines are not byte-identical between BASELINE and HEAD.
Everything else is skipped, with its proof: the whole lines holding the target, read from `git show BASELINE:<file>`
and from HEAD, are the same bytes, and the target occurs exactly once in each.
--write saves Tests/work-mutation-317.names (for `--only`) and Tests/work-mutation-317-SKIPPED.md. Reads git, never
compiles.
"""
import hashlib, pathlib, subprocess, sys

BASELINE = "07c4060"   # COS Control 0.5.315 (build 368), the last published release before 0.5.316 and 0.5.317
root = pathlib.Path(sys.argv[1]).resolve(); write = "--write" in sys.argv[2:]


def gate(path):
    src = (root / path).read_text()
    code = src.split("\ndef idle")[0] if "\ndef idle" in src else src.split("\ndef run(work")[0]
    head = code.split("\nMUTANTS = [", 1)
    ns = {}
    exec("import pathlib\nC='Sources/WorkTaskChat.swift'; S='Sources/WorkHandoffStore.swift'; M='Sources/WorkContextMeter.swift'; "
         "F='Sources/WorkCardFiles.swift'; Q='Sources/WorkChatQueue.swift'; H='HelperSources/main.swift'; V='Sources/Views.swift'\n"
         "MUTANTS = [" + head[1], ns)
    return ns["MUTANTS"]


def baseline_gate(path):
    src = subprocess.run(["git", "-C", str(root), "show", f"{BASELINE}:{path}"], capture_output=True, text=True).stdout
    if not src: return {}
    code = src.split("\ndef idle")[0] if "\ndef idle" in src else src.split("\ndef run(work")[0]
    ns = {}
    exec("import pathlib\nC='Sources/WorkTaskChat.swift'; S='Sources/WorkHandoffStore.swift'; M='Sources/WorkContextMeter.swift'; "
         "F='Sources/WorkCardFiles.swift'\nMUTANTS = [" + code.split("\nMUTANTS = [", 1)[1], ns)
    return {m[0]: m for m in ns["MUTANTS"]}


def lines_around(text, target):
    """The whole lines holding `target` (from the start of its first line to the end of its last), or None."""
    if text.count(target) != 1: return None
    i = text.index(target); start = text.rfind("\n", 0, i) + 1; end = text.find("\n", i + len(target))
    return text[start:len(text) if end < 0 else end]


queue = gate("Tests/mutate-work-chat-queue.py")
review = gate("Tests/mutate-work-chat-review.py")
old = baseline_gate("Tests/mutate-work-chat-review.py")
chat = (root / "Sources/WorkTaskChat.swift").read_text()
d0 = chat.index("    private func dispatch("); d1 = chat.index("    /// 0.5.317: what holds this assignment now.")
# dispatch() and sendContext(), the re-checks a queued assignment gets again at the moment it sends.
s0 = chat.index("    private func sendContext("); s1 = chat.index("\n    /// Replaces one waiting assignment's prompt", s0)
dispatch_body = chat[d0:d1] + "\n" + chat[s0:s1]
# WorkChatPreflight.holds() and blockers(): unchanged since 0.5.315, but in 0.5.317 they also decide queued and parallel
# sends and what a queued assignment waits on.
h0 = chat.index("    static func holds(_ row: WorkHandoffReceipt"); h1 = chat.index("    /// 0.5.317: the handoffs that write into this exact session", h0)
fence_body = chat[h0:h1]
shown = {}

run, skipped, reasons = [], [], {}
for name, *_ in queue:
    run.append(name); reasons[name] = "queue gate (new in 0.5.317)"
for name, path, target, _ in review:
    if name not in old or old[name][2] != target or old[name][1] != path:
        run.append(name); reasons[name] = "new or retargeted since 0.5.315"; continue
    if path == "Sources/WorkTaskChat.swift" and target in dispatch_body:
        run.append(name); reasons[name] = "targets dispatch() or its sendContext() re-checks"; continue
    if path == "Sources/WorkTaskChat.swift" and target in fence_body:
        run.append(name); reasons[name] = "targets the fence (holds, blockers), which now decides queued and parallel sends"; continue
    if path not in shown:
        shown[path] = subprocess.run(["git", "-C", str(root), "show", f"{BASELINE}:{path}"], capture_output=True, text=True).stdout
    before, after = lines_around(shown[path], target), lines_around((root / path).read_text(), target)
    if before is None or after is None or before != after:
        run.append(name); reasons[name] = "target lines changed since 0.5.315"; continue
    skipped.append((name, path, hashlib.sha256(after.encode()).hexdigest(), after))

names = [m[0] for m in queue] + [m[0] for m in review]
assert len(names) == len(set(names)), "a mutant name appears in both gates"
assert set(run).isdisjoint(n for n, *_ in skipped) and len(run) + len(skipped) == len(names)
counts = {}
for n in run: counts[reasons[n]] = counts.get(reasons[n], 0) + 1
print(f"run {len(run)}: " + ", ".join(f"{v} {k}" for k, v in counts.items()))
print(f"skipped {len(skipped)}: target lines byte-identical in {BASELINE} and HEAD")
if write:
    (root / "Tests/work-mutation-317.names").write_text(
        f"# 0.5.317 Work chat mutation run set ({len(run)}), from Tests/work-mutation-scope.py. Use with --only.\n"
        + "".join(f"{n}\n" for n in run))
    rows = "\n".join(f"| {n} | `{p}` | `{h[:16]}` |" for n, p, h, _ in skipped)
    (root / "Tests/work-mutation-317-SKIPPED.md").write_text(
        f"# 0.5.317 Work chat mutants not rerun ({len(skipped)})\n\n"
        f"Generated by `python3 Tests/work-mutation-scope.py <worktree> --write`. Each mutant below is in "
        f"Tests/mutate-work-chat-review.py with the same name, file and target as at {BASELINE} (COS Control 0.5.315), "
        f"its target occurs exactly once in both versions, it is outside dispatch(), sendContext() and WorkChatPreflight.holds() and blockers(), and the whole lines holding its target "
        f"are byte-identical in `git show {BASELINE}:<file>` and in HEAD. The SHA-256 is of those lines (first 16 hex shown); "
        f"rerun the script to recompute it. Any mutant that fails a check moves to the run set automatically.\n\n"
        f"Evidence gap, said plainly: no CHANGELOG entry records a full run of this gate at {BASELINE}. These mutants were "
        f"added in 0.5.308 to 0.5.312, and this proof shows only that their target code has not changed since 0.5.315 shipped.\n\n"
        f"| Mutant | File | Target lines SHA-256 |\n| --- | --- | --- |\n{rows}\n")
    print("wrote Tests/work-mutation-317.names and Tests/work-mutation-317-SKIPPED.md")
