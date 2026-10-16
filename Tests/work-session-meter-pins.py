#!/usr/bin/env python3
"""0.5.312 Work → Connections meter: wiring pins the compiled-only views hide. Text only; comments stripped first."""
import re, sys
from pathlib import Path

root = Path(sys.argv[1])
checks = 0


def code(name: str) -> str:
    text = (root / name).read_text(encoding="utf-8")
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return "\n".join(re.sub(r'(^|[^:"])//.*$', r"\1", line) for line in text.split("\n"))


def need(ok: bool, why: str) -> None:
    global checks
    if not ok:
        sys.exit("work-session-meter: " + why)
    checks += 1


def body(src: str, opener: str) -> str:
    start = src.index(opener)
    depth, seen = 0, False
    for i in range(start, len(src)):
        if src[i] == "{":
            depth += 1; seen = True
        elif src[i] == "}":
            depth -= 1
            if seen and depth == 0:
                return src[start:i + 1]
    return src[start:]


core = code("Sources/WorkSessionLinks.swift")
views = code("Sources/WorkTrackingViews.swift")
workspace = code("Sources/WorkWorkspaceView.swift")
helper = code("HelperSources/main.swift")

# The card: every non-historical linked session shows the meter, scoped to its handoff.
hub = body(workspace, "private func contributorHub(")
need("WorkSessionMeterSections(store: WorkSessionMeterStore.shared, sessionID: contributor.id," in hub
     and "since: contributor.receipt?.createdAt ?? contributor.link?.at)" in hub and "if !contributor.historical {" in hub,
     "each linked session card mounts the meter, scoped to its handoff time")
need(".sheet(" not in workspace and ".sheet(" not in views, "Work overlays are inline, never sheets")

# Hide when unknown: the view draws Context only from a parsed context, and there is no 0% fallback.
sections = body(views, "struct WorkSessionMeterSections: View {")
need("if let context = snapshot?.context { contextSection(context) }" in sections, "Context shows only when it is known")
need('"0%' not in sections and "?? 0" not in sections and "percent ?? " not in sections, "an unknown context never draws as 0%")
parse = body(views, "static func parse(_ details: [String: JSONValue]) -> Self? {")
need('guard details["known"]?.bool == true else { return nil }' in parse and "used > 0, window > 0" in parse,
     "known:false and a zero usage or window parse to nothing")
need("if let snapshot, !snapshot.outputs.isEmpty { outputsSection(snapshot) }" in sections
     and "if let snapshot, since != nil, snapshot.cwd != nil, snapshot.changesKnown { changesSection(snapshot) }" in sections,
     "Outputs and Changes show only when known")

# The 85% line.
need(re.search(r"static let compactingFraction = 0\.85\b", core) is not None
     and "var nearlyFull: Bool { fraction >= WorkSessionMeter.compactingFraction }" in core, "orange from 85%")
context = body(views, "private func contextSection(_ context: WorkSessionMeter.Context) -> some View {")
need("context.nearlyFull ? WorkSessionMeterColors.warn : WorkSessionMeterColors.used" in context
     and "if context.nearlyFull {" in context and "Text(WorkSessionMeter.compactingNote)" in context,
     "at 85% the bar turns orange and says it is close to compacting")
need('static let compactingNote = "Close to compacting. A fresh session keeps this send intact."' in core, "the mock's sentence")
need("context.label" in context and "estimate" in context, "the label, and the estimate is said")

# Refresh while visible, short TTL, the shared API.
need(".task(id: WorkSessionMeterStore.key(sessionID, since: since)) {" in sections and "while !Task.isCancelled {" in sections
     and "try? await Task.sleep(for: .seconds(WorkSessionMeterStore.ttl))" in sections, "refreshes while the card is on screen")
need(re.search(r"static let ttl: TimeInterval = (\d+)", views) is not None and int(re.search(r"static let ttl: TimeInterval = (\d+)", views).group(1)) <= 60,
     "a short cache")
need("func sessionContextWindow(_ sessionID: String) -> (used: Int, window: Int)? {" in views, "the shared API for the assignment meters")
need('["work-session-meter", "--session", id]' in views, "Control reads through the helper verb")

# Outputs open on click and preview with Quick Look; paths only.
outputs = body(views, "private func outputsSection(_ snapshot: WorkSessionMeterSnapshot) -> some View {")
need("NSWorkspace.shared.open(URL(fileURLWithPath: output.path))" in outputs and ".onKeyPress(.space)" in outputs
     and "preview = URL(fileURLWithPath: output.path)" in outputs and ".quickLookPreview($preview)" in sections,
     "click opens, Space and the menu preview with Quick Look")
need("Array(snapshot.outputs.prefix(3))" in outputs and 'Button(showAllOutputs ? "Show fewer" : "Show \\(snapshot.outputs.count - 3) more")' in outputs,
     "top three, then Show N more")

# The helper verb: bounded tail, numbers and paths, read-only git.
verb = body(helper, "private func emitWorkSessionMeter(args: [String]) throws {")
tail = body(helper, "static func workSessionTail(_ file: URL, maxBytes: Int) -> (lines: [String], fromStart: Bool) {")
need("handle.read(upToCount: maxBytes)" in tail and "handle.seek(toOffset: start)" in tail and "readDataToEndOfFile" not in tail,
     "the tail reads at most maxBytes from the end")
need("Data(contentsOf" not in verb and "readDataToEndOfFile" not in verb and "String(contentsOf" not in verb
     and verb.count("Self.workSessionTail(") == 3, "the verb reads transcripts only through the bounded tail")
need(re.search(r"contextTailMaxBytes = 4 \* 1024 \* 1024", core) is not None and re.search(r"outputsTailBytes = 4 \* 1024 \* 1024", core) is not None,
     "the windows stay bounded at 4 MB")
keys = set(re.findall(r'details\["(\w+)"\]', verb)) | set(re.findall(r'"(\w+)": ', verb.split("var details")[1].split("\n")[0]))
need(keys <= {"known", "provider", "context", "cwd", "outputs", "outputsTotal", "outputsPartial", "changes"},
     f"the verb returns numbers and paths only, got {sorted(keys)}")
git = body(helper, "private func workSessionChanges(cwd: String, since: Date) -> [String: Any] {")
need('"--no-optional-locks", "-C", cwd, "-c", "core.pager=cat"' in git and "timeout: 5" in git and 'environment["GIT_TERMINAL_PROMPT"] = "0"' in git,
     "git runs without a pager, lock or prompt, with a timeout")
subcommands = set(re.findall(r'git\(\["([\w-]+)"', git))
need(subcommands == {"rev-parse", "rev-list", "diff"}, f"git is read-only, got {sorted(subcommands)}")
need("guard let gitPath = Self.workSessionGit(fm)" in git, "never the developer-tools install stub")
need('case "work-session-meter": try emitWorkSessionMeter(args: args)' in helper, "the verb is dispatched")

print(f"PASS work session meter pins: {checks} checks; card wiring, hide when unknown, 85% line, refresh, shared API, bounded tail, read-only git")
