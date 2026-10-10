#!/usr/bin/env python3
"""2026-10-09 mutation lane for the Messages Markdown guards. Run by hand, never by a gate (UI mutants compile the app).

    python3 Tests/mutate-messages-markdown.py <worktree> <scratch dir> [name ...]

It copies the worktree to <scratch dir>/copy, proves the UNMUTATED suite is green first, then applies one mutant at a
time: the target text must appear exactly once, the mutant must make a check fail, and the failure must name the
behaviour the mutant breaks. A mutant that lands and survives is a finding. One compile at a time (compile-guard).

Suite, cheapest first, stopping at the first failure: the two run.sh pin blocks that cover Markdown and Messages
search (extracted from the copy's own run.sh), the executed parser contract, then the offscreen Markdown UI renders.
"""
import pathlib, re, shutil, subprocess, sys, time

P = "Sources/COSMarkdownParser.swift"
M = "Sources/COSMarkdown.swift"
A = "Sources/ActivityWindow.swift"
C = "Sources/ControllerModel.swift"
# (name, file, original, mutant, words the killing failure must contain)
MUTANTS = [
    ("web only: refused links kept", P, "if !opensAsWebLink(url) { refused.append(run.range) }", "if false { refused.append(run.range) }", "web-only policy"),
    # Behaviour twins of the two above that leave the pins' text in place, so the executed checks must kill them.
    ("web only (executed): refused links kept", P, "if !opensAsWebLink(url) { refused.append(run.range) }",
     'if !opensAsWebLink(url) && url.scheme == "never" { refused.append(run.range) }', "[web links only]"),
    ("web only: any scheme but javascript", P, 'guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }',
     'guard let scheme = url.scheme?.lowercased(), scheme != "javascript" else { return false }', "[web links only]"),
    ("web only: no host check", P, "guard let host = url.host, !host.isEmpty else { return false }\n", "", "[web links only]"),
    ("web only: the parser skips the policy", P, "        for range in refused { string[range].link = nil }\n", "", "[web links only]"),
    ("row preview: headings kept", P, "if let level = headingLevel(line) { line = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces) }", "", "[row preview]"),
    ("parse once: a hit never checks the text", M, "hit.dropLeadingTitle == dropLeadingTitle, hit.text == text {", "hit.dropLeadingTitle == dropLeadingTitle {", "verifies the text on a hit"),
    ("parse once (executed): a hit never checks the text", M, "hit.dropLeadingTitle == dropLeadingTitle, hit.text == text {",
     "hit.dropLeadingTitle == dropLeadingTitle, (hit.text == text || true) {", "[streaming]"),  # the streamed turn draws its stale text
    ("parse once: nothing is stored", M, "        entries[key] = Entry(text: text, dropLeadingTitle: dropLeadingTitle, blocks: blocks)\n", "", "[parse once]"),
    ("parse once: the inline cache never hits", M, "        if let hit = runs[key] { return hit }\n", "", "[parse once]"),
    ("italic: DM Sans emphasis left upright", M,
     "                string[run.range].font = .system(size: italicSize, weight: intent.contains(.stronglyEmphasized) ? .bold : .regular).italic()\n", "", "[italic]"),
    ("search mark: the Markdown side never marks", M, "        guard needle.count >= 2 else { return base }", "        return base", "[search mark]"),
    ("search mark: the card drops the term", A, "                    .environment(\\.cosMarkdownHighlight, highlight)\n", "", "search term"),
    ("messages: the COS card renders as typed", A, "            } else if let markdownID {\n", "            } else if let markdownID, markdownID.isEmpty {\n", "[messages]"),
    ("messages: Recent passes no id", A, 'highlight: recentQuery, markdownID: "turn:" + turn.id)', "highlight: recentQuery)", "[messages]"),
    ("messages: the archive passes no id", A, 'highlight: chatQuery, markdownID: "archive:\\(date)/\\(index)/\\(message.id)")', "highlight: chatQuery)", "[messages]"),
    ("messages: the row preview shows markers", A, "Text(COSMarkdownInlineCache.plain(turn.text))", "Text(turn.text)", "[messages]"),
    ("messages: a session chat reply as typed", A, 'COSMarkdownView(text: message.text, cacheID: "chat:\\(message.id)")', "Text(verbatim: message.text)", "[messages]"),
    ("copy raw: Copy turn copies the rendered words", C, "NSPasteboard.general.setString(turn.turnClipboardText, forType: .string)",
     "NSPasteboard.general.setString(COSMarkdownParser.plainText(turn.turnClipboardText), forType: .string)", "must copy the stored text"),
]


def run(cmd, cwd):
    started = time.time()
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if "compile-guard: STOPPED" in proc.stdout + proc.stderr:
        sys.exit("compile-guard stopped a compile (memory); ending the mutation lane. " + (proc.stderr or "")[-400:])
    return proc.returncode, proc.stdout + proc.stderr, time.time() - started


def heredoc(run_sh, tag):
    m = re.search(r"<<'" + tag + r"'\n(.*?)\n" + tag + r"\n", run_sh, re.S)
    if not m:
        sys.exit(f"run.sh lost its {tag} pin block")
    return m.group(1)


def suite(copy, scratch):
    run_sh = (copy / "Tests/run.sh").read_text()
    out_all, total = "", 0.0
    for tag in ("MARKDOWN", "LEDGCHK"):
        script = scratch / f"pins-{tag}.py"
        script.write_text(heredoc(run_sh, tag))
        code, out, seconds = run(["/usr/bin/python3", str(script), str(copy)], copy)
        out_all += out; total += seconds
        if code != 0:
            return code, out_all, total
    binary = scratch / "markdown-contract"
    code, out, seconds = run(["zsh", "Tests/compile-guard.sh", "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6",
                              "-strict-concurrency=complete", "-parse-as-library", "Sources/COSMarkdownParser.swift",
                              "Tests/MarkdownContract.swift", "-o", str(binary)], copy)
    out_all += out; total += seconds
    if code != 0:
        return code, out_all, total
    code, out, seconds = run([str(binary)], copy)
    out_all += out; total += seconds
    if code != 0:
        return code, out_all, total
    code, out, seconds = run(["zsh", "Tests/run-markdown-ui.sh", str(scratch / "renders")], copy)
    return code, out_all + out, total + seconds


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    shutil.copytree(src, copy, ignore=shutil.ignore_patterns(".git", ".build", "build", "dist"))
    code, out, seconds = suite(copy, scratch)
    passed = [l for l in out.splitlines() if l.startswith("PASS") or "pinned" in l]
    print(f"BASELINE (unmutated): exit {code} in {seconds:.0f}s: {' / '.join(p[:90] for p in passed) or '(no PASS line)'}", flush=True)
    if code != 0:
        print(out[-2000:])
        sys.exit("baseline is not green; no mutant may be judged against a red suite")
    killed, survived = 0, 0
    for name, rel, old, new, words in MUTANTS:
        if only and name not in only:
            continue
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        hits = text.count(old)
        if hits != 1:
            print(f"MISSED  {name}: target appears {hits} times in {rel}", flush=True)
            survived += 1
            continue
        path.write_text(text.replace(old, new), encoding="utf-8")
        try:
            code, out, seconds = suite(copy, scratch)
        finally:
            path.write_text(text, encoding="utf-8")
        named = words in out
        if code != 0 and named:
            killed += 1
            line = next((l for l in out.splitlines() if words in l), "")
            print(f"KILLED  {name} ({seconds:.0f}s): {line.strip()[:160]}", flush=True)
        else:
            survived += 1
            print(f"SURVIVED {name}: exit {code}, failure named it: {named}\n{out[-800:]}", flush=True)
    print(f"{killed} killed, {survived} survived or missed")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
