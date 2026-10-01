#!/usr/bin/env python3
"""0.5.254 mutation lane for the card-files guards. Run by hand, never by a gate (each mutant compiles the app).

    python3 Tests/mutate-card-files.py <worktree> <scratch dir> [name ...]

It copies the worktree to <scratch dir>/copy, proves the UNMUTATED suite is green first (Tests/run-work-card-files.sh
and Tests/work-card-files-pins.py), then applies one mutant at a time: the target text must appear exactly once, the
mutant must make a check fail, and the failure must name the behaviour the mutant breaks ("check failed [<behaviour>]"
from the Swift checks, or the pin's own words). A mutant that lands and survives is a finding. One suite at a time.
"""
import pathlib, shutil, subprocess, sys, time

# (name, file, original, mutant, words the killing failure must contain)
MUTANTS = [
    ("secret refusal: .env by name", "Sources/WorkCardFiles.swift",
     'if n.hasPrefix(".env") || n.hasPrefix(".cos-profile.json") { return true }', 'if n.hasPrefix(".cos-profile.json") { return true }', "[secret refusal]"),
    ("secret refusal: a private key by its bytes", "Sources/WorkCardFiles.swift",
     'if ["privateKey", "keychain"].contains(sniff.kind) { return true }', 'if ["keychain"].contains(sniff.kind) { return true }', "[secret refusal]"),
    ("cap: the 21st file", "Sources/WorkCardFiles.swift",
     "if shown.count >= maxFiles { return .cap }", "if shown.count > maxFiles { return .cap }", "[cap]"),
    ("cap: 2 GB", "Sources/WorkCardFiles.swift",
     ".reduce(Int64(0), { $0 + $1.bytes }) + bytes > maxBytes { return .cap }", ".reduce(Int64(0), { $0 + $1.bytes }) + bytes > maxBytes * 2 { return .cap }", "[cap]"),
    ("duplicate", "Sources/WorkCardFiles.swift",
     "if let same = shown.first(where: { $0.sha256 == sha256 }) { return .duplicate(same.display) }",
     "if let same = shown.first(where: { $0.sha256 == sha256 && sha256.isEmpty }) { return .duplicate(same.display) }", "[duplicate]"),
    ("block placement: block first", "Sources/WorkCardFiles.swift",
     'block.isEmpty ? text + instruction : text + "\\n\\n" + block + instruction', 'block.isEmpty ? text + instruction : block + "\\n\\n" + text + instruction', "[block placement]"),
    ("block placement: block after the instruction", "Sources/WorkCardFiles.swift",
     'block.isEmpty ? text + instruction : text + "\\n\\n" + block + instruction', 'block.isEmpty ? text + instruction : text + instruction + "\\n\\n" + block', "[block placement]"),
    ("block placement: the send leaves the files out", "Sources/WorkHandoffStore.swift",
     "let sent = WorkCardFiles.compose(text: text, block: files.block, instruction: instruction)", "let sent = text + instruction", "block"),
    ("Cursor protection: the cut drops the block", "Sources/WorkHandoffStore.swift",
     'let tail = "\\n\\n" + cursorCutMarker + block + instruction', 'let tail = "\\n\\n" + cursorCutMarker + instruction', "[Cursor protection]"),
    ("Cursor protection: a list too long for the link is sent anyway", "Sources/WorkHandoffStore.swift",
     'return (header + "\\n\\n" + cursorCutMarker + block + instruction).utf16.count <= cursorPrefillLimit', "return true", "[Cursor protection]"),
    ("delta: Continue resends everything", "Sources/WorkCardFiles.swift",
     "let carried = mode == .newSession || resendAll || sessionID == nil ? [] : Self.carried(", "let carried = mode == .newSession || true || sessionID == nil ? [] : Self.carried(", "[delta]"),
    ("delta: a refused send counts as carried", "Sources/WorkCardFiles.swift",
     'receipt.workID == workID && !["refused", "failed", "canceled"].contains(receipt.status) && !receipt.clearedUnconfirmed',
     "receipt.workID == workID && !receipt.clearedUnconfirmed", "[delta]"),
    ("delta: Send all again is ignored", "Sources/WorkCardFiles.swift",
     "let carried = mode == .newSession || resendAll || sessionID == nil ? [] : Self.carried(", "let carried = mode == .newSession || sessionID == nil ? [] : Self.carried(", "[delta]"),
    ("cleanup refcount: a folder in use is deleted", "Sources/WorkCardFiles.swift",
     "if due && live.isEmpty { plan.deleteFolder = true; return plan }", "if due { plan.deleteFolder = true; return plan }", "[cleanup refcount]"),
    ("cleanup refcount: a removed file in use is deleted", "Sources/WorkCardFiles.swift",
     "if live.contains(fileID) { manifest.files[index].hiddenAt = Date().timeIntervalSince1970; return }",
     "if live.contains(fileID) && fileID.isEmpty { manifest.files[index].hiddenAt = Date().timeIntervalSince1970; return }", "[cleanup refcount]"),
    ("cleanup refcount: queued does not hold files", "Sources/WorkCardFiles.swift",
     'nonisolated static let liveStatuses: Set<String> = ["preparing", "sending", "queued", "running", "unknown"]',
     'nonisolated static let liveStatuses: Set<String> = ["preparing", "sending", "running", "unknown"]', "[cleanup refcount]"),
    ("private type: cards take the card type", "Sources/WorkCardFiles.swift",
     "nonisolated static let fileDropTypes: [UTType] = [.fileURL,", "nonisolated static let fileDropTypes: [UTType] = [.workCard, .fileURL,", "files only"),
    ("private type: a card takes a card", "Sources/WorkCardFiles.swift",
     "case .card, .filesBox: return offersCard ? .ignore : (offersFiles ? .addFiles : .ignore)", "case .card, .filesBox: return offersFiles || offersCard ? .addFiles : .ignore", "never takes a card"),
    ("private type: cards drag as text again", "Sources/WorkWorkspaceView.swift",
     ".draggable(WorkCardDrag(id: item.id)) {", ".draggable(item.id) {", "private type"),
    ("private type: a file on a column is taken", "Sources/WorkCardFiles.swift",
     "case .column: return offersCard ? .moveCard : (offersFiles ? .refuseFiles : .ignore)", "case .column: return offersCard || offersFiles ? .moveCard : .ignore", "[private type]"),
    ("countdown wait: the rule counts down while copies are made", "Sources/WorkCardFiles.swift",
     "case .wait: return .wait", "case .wait: return secondsLeft <= 1 ? .send : .tick(secondsLeft - 1)", "[countdown wait]"),
    ("countdown wait: the sheet ignores the wait", "Sources/WorkHandoffView.swift",
     "                case .wait: continue\n", "                case .wait: secondsLeft -= 1\n", "countdown"),
    ("countdown wait: a local model with files starts by itself", "Sources/WorkCardFiles.swift",
     "if !files.sending.isEmpty && localProviders.contains(provider) { calls.append(localModelWarning) }", "if files.sending.isEmpty && localProviders.contains(provider) { calls.append(localModelWarning) }", "[countdown wait]"),
    ("iCloud timeout: the gate lets a late read start", "Sources/WorkCardFiles.swift",
     "func begin() -> Bool { lock.withLock { guard state == 0 else { return false }; state = 1; return true } }",
     "func begin() -> Bool { lock.withLock { guard state != 1 else { return false }; state = 1; return true } }", "[iCloud timeout]"),
    ("iCloud timeout: the coordinated read copies after its deadline", "Sources/WorkCardFiles.swift",
     "                guard gate.begin() else { return }\n", "                _ = gate.begin()\n", "[iCloud timeout]"),
    ("nothing half-added: a refused copy stays", "Sources/WorkCardFiles.swift",
     "defer { if movedTo == nil { try? FileManager.default.removeItem(at: staged) } }", "defer { if movedTo == nil && staged.path.isEmpty { try? FileManager.default.removeItem(at: staged) } }", "[nothing half-added]"),
    ("sanitizer: control characters kept", "Sources/WorkCardFiles.swift",
     'scalars.append(invisible ? " " : scalar)', "scalars.append(scalar)", "[sanitizer]"),
    ("companion resume: an interrupted copy restarts forever", "Sources/WorkCardFiles.swift",
     "let tooMany = (companion.attempts ?? 0) >= WorkCardFiles.maxCompanionAttempts", "let tooMany = (companion.attempts ?? 0) > WorkCardFiles.maxCompanionAttempts", "[companion resume]"),
]

def run(cmd, cwd):
    started = time.time()
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return proc.returncode, proc.stdout + proc.stderr, time.time() - started

def suite(copy):
    code, out, seconds = run(["/usr/bin/python3", "Tests/work-card-files-pins.py", "."], copy)
    if code != 0:
        return code, out, seconds
    code2, out2, seconds2 = run(["zsh", "Tests/run-work-card-files.sh"], copy)
    return code2, out + out2, seconds + seconds2

def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    for part in ("Sources", "Tests", "Resources", "scripts"):
        shutil.copytree(src / part, copy / part)
    shutil.copy(src / "CHANGELOG.md", copy / "CHANGELOG.md")
    code, out, seconds = suite(copy)
    passed = [l for l in out.splitlines() if l.startswith("PASS:") or "wiring pinned" in l]
    print(f"BASELINE (unmutated): exit {code} in {seconds:.0f}s: {' / '.join(p[:120] for p in passed) or '(no PASS line)'}", flush=True)
    if code != 0:
        sys.exit("baseline is not green; no mutant may be judged against a red suite")
    killed, survived, rows = 0, 0, []
    for name, rel, old, new, words in MUTANTS:
        if only and name not in only:
            continue
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            print(f"MISS  {name}: the target appears {text.count(old)} times", flush=True); survived += 1; rows.append((name, "MISSED", "")); continue
        path.write_text(text.replace(old, new), encoding="utf-8")
        try:
            code, out, seconds = suite(copy)
        finally:
            path.write_text(text, encoding="utf-8")
        lines = [l for l in out.splitlines() if "check failed [" in l or "0.5.254 pin:" in l or "error:" in l]
        reason = lines[0].strip() if lines else (out.strip().splitlines()[-1] if out.strip() else "")
        if code == 0:
            survived += 1; rows.append((name, "SURVIVED", "")); print(f"SURVIVED  {name}", flush=True)
        elif words.lower() in reason.lower():
            killed += 1; rows.append((name, "killed", reason)); print(f"killed  {name} ({seconds:.0f}s): {reason[:220]}", flush=True)
        else:
            survived += 1; rows.append((name, "KILLED BY ANOTHER CHECK", reason)); print(f"MISATTRIBUTED  {name}: {reason[:220]}", flush=True)
    print(f"RESULT: {killed}/{killed + survived} killed by a check that names the behaviour", flush=True)
    sys.exit(0 if survived == 0 else 1)

if __name__ == "__main__":
    main()
