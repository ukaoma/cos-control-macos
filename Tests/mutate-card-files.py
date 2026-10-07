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
F = "Sources/WorkCardFiles.swift"
MUTANTS = [
    # Refusals (0.5.254).
    ("secret refusal: .env by name", F, 'if n.hasPrefix(".env"), !envTemplates.contains(n) { return true }', 'if n.isEmpty { return true }', "[secret refusal]"),
    ("secret refusal: a private key by its bytes", F, 'if ["privateKey", "keychain", "secretText"].contains(sniff.kind) { return true }',
     'if ["keychain", "secretText"].contains(sniff.kind) { return true }', "[secret refusal]"),
    ("cap: the 21st file", F, "if shown.count >= maxFiles { return .cap }", "if shown.count > maxFiles { return .cap }", "[cap]"),
    ("cap: 2 GB", F, ".reduce(Int64(0), { $0 + $1.bytes }) + bytes > maxBytes { return .cap }", ".reduce(Int64(0), { $0 + $1.bytes }) + bytes > maxBytes * 2 { return .cap }", "[cap]"),
    ("duplicate", F, "if let same = shown.first(where: { $0.sha256 == sha256 }) { return .duplicate(same.display) }",
     "if let same = shown.first(where: { $0.sha256 == sha256 && sha256.isEmpty }) { return .duplicate(same.display) }", "[duplicate]"),
    # The block (0.5.254).
    ("block placement: block first", F, 'block.isEmpty ? text + instruction : text + "\\n\\n" + block + instruction', 'block.isEmpty ? text + instruction : block + "\\n\\n" + text + instruction', "[block placement]"),
    ("block placement: block after the instruction", F, 'block.isEmpty ? text + instruction : text + "\\n\\n" + block + instruction', 'block.isEmpty ? text + instruction : text + instruction + "\\n\\n" + block', "[block placement]"),
    ("block placement: the send leaves the files out", "Sources/WorkHandoffStore.swift",
     "let sent = WorkCardFiles.compose(text: text, block: files.block, instruction: instruction)", "let sent = text + instruction", "block"),
    ("Cursor protection: the cut drops the block", "Sources/WorkHandoffStore.swift",
     'let tail = "\\n\\n" + cursorCutMarker + block + instruction', 'let tail = "\\n\\n" + cursorCutMarker + instruction', "[Cursor protection]"),
    ("Cursor protection: a list too long for the link is sent anyway", "Sources/WorkHandoffStore.swift",
     'return (header + "\\n\\n" + cursorCutMarker + block + instruction).utf16.count <= cursorPrefillLimit', "return true", "[Cursor protection]"),
    ("delta: Continue resends everything", F, "let carried = mode == .newSession || resendAll || sessionID == nil ? [] : Self.carried(",
     "let carried = mode == .newSession || true || sessionID == nil ? [] : Self.carried(", "[delta]"),
    ("delta: a refused send counts as carried", F, 'receipt.workID == workID && !["refused", "failed", "canceled"].contains(receipt.status) && !receipt.clearedUnconfirmed',
     "receipt.workID == workID && !receipt.clearedUnconfirmed", "[delta]"),
    ("delta: Send all again is ignored", F, "let carried = mode == .newSession || resendAll || sessionID == nil ? [] : Self.carried(",
     "let carried = mode == .newSession || sessionID == nil ? [] : Self.carried(", "[delta]"),
    # Board (0.5.254).
    ("private type: cards take the card type", F, "nonisolated static let fileDropTypes: [UTType] = [.fileURL,", "nonisolated static let fileDropTypes: [UTType] = [.workCard, .fileURL,", "files only"),
    ("private type: a card takes a card", F, "case .card, .filesBox: return offersCard ? .ignore : (offersFiles ? .addFiles : .ignore)",
     "case .card, .filesBox: return offersFiles || offersCard ? .addFiles : .ignore", "never takes a card"),
    ("private type: cards drag as text again", "Sources/WorkWorkspaceView.swift", ".draggable(WorkCardDrag(id: item.id)) {", ".draggable(item.id) {", "private type"),
    ("private type: a file on a column is taken", F, "case .column: return offersCard ? .moveCard : (offersFiles ? .refuseFiles : .ignore)",
     "case .column: return offersCard || offersFiles ? .moveCard : .ignore", "[private type]"),
    ("countdown wait: the rule counts down while copies are made", F, "case .wait: return .wait", "case .wait: return secondsLeft <= 1 ? .send : .tick(secondsLeft - 1)", "[countdown wait]"),
    ("countdown wait: the sheet ignores the wait", "Sources/WorkHandoffView.swift", "                case .wait: continue\n", "                case .wait: secondsLeft -= 1\n", "countdown"),
    ("countdown wait: a local model with files starts by itself", F, "if !files.sending.isEmpty && localProviders.contains(provider) { calls.append(localModelWarning) }",
     "if files.sending.isEmpty && localProviders.contains(provider) { calls.append(localModelWarning) }", "[countdown wait]"),
    ("iCloud timeout: the gate lets a late read start", F, "func begin() -> Bool { lock.withLock { guard state == 0 else { return false }; state = 1; return true } }",
     "func begin() -> Bool { lock.withLock { guard state != 1 else { return false }; state = 1; return true } }", "[iCloud timeout]"),
    ("iCloud timeout: the coordinated read copies after its deadline", F, "                guard gate.begin() else { return }\n", "                _ = gate.begin()\n", "[iCloud timeout]"),
    ("nothing half-added: a refused copy stays", F, "defer { if movedTo == nil { try? FileManager.default.removeItem(at: staged) } }",
     "defer { if movedTo == nil && staged.path.isEmpty { try? FileManager.default.removeItem(at: staged) } }", "[nothing half-added]"),
    ("sanitizer: control characters kept", F, 'scalars.append(invisible ? " " : scalar)', "scalars.append(scalar)", "[sanitizer]"),
    ("companion resume: an interrupted copy restarts forever", F, "let tooMany = (companion.attempts ?? 0) >= WorkCardFiles.maxCompanionAttempts",
     "let tooMany = (companion.attempts ?? 0) > WorkCardFiles.maxCompanionAttempts", "[companion resume]"),
    # Fix pass 1, B1: containment.
    ("B1 grammar: an entry's names are not checked", F, "        if file.isLink { return file.stored.isEmpty && file.companions.isEmpty }\n        return validStored(file.stored) && file.companions.allSatisfy { validCompanion($0, of: file) }",
     "        return true", "[name grammar]"),
    ("B1 grammar: guardTarget takes any name", F, "        guard validStored(name) || validCompanionName(name) || validStaging(name) else {", "        guard !name.isEmpty || name.isEmpty else {", "[name grammar]"),
    ("B1 containment: contained() accepts any path", F, "        return (path as NSString).deletingLastPathComponent == folder && !name.isEmpty && name != \".\" && name != \"..\"",
     "        return !name.isEmpty || name.isEmpty", "[containment]"),
    ("B1 symlink: a linked card folder is used", F, "        guard fileType(folder) == S_IFDIR else {", "        guard fileType(folder) != nil else {", "[symlink refusal]"),
    ("B1 symlink: a linked copy is used", F, "        guard fileType(target) != S_IFLNK else {", "        guard fileType(target) != S_IFLNK || name.isEmpty || !name.isEmpty else {", "[symlink refusal]"),
    ("B1 restart: a companion with bad names restarts", F, "        guard let root, WorkCardFiles.validEntry(file) else { return }", "        guard let root else { return }", "restarted"),
    # Fix pass 1, B2: credentials.
    ("B2 userinfo: a link with a password is kept", F, "        if linkHasCredentials(text) { return .failure(.linkCredentials) }\n", "", "password"),
    ("B2 userinfo: a user alone is not credentials", F, "        return parts.user != nil || parts.password != nil", "        return parts.password != nil", "[link credentials]"),
    ("B2 userinfo: a planted link reaches the block", F, ', !(file.kind == "link" && linkHasCredentials(file.original ?? ""))', "", "[link credentials]"),
    # Fix pass 1, W4: secrets.
    ("W4 name: *.env is not a secret", F, 'if n.hasSuffix(".env") || n.hasPrefix(".cos-profile.json") { return true }', 'if n.hasPrefix(".cos-profile.json") { return true }', "[secret names]"),
    ("W4 name: credentials files", F, 'if ["credentials", ".npmrc", ".netrc", ".pypirc", ".pgpass", ".git-credentials"].contains(n) { return true }', "", "[secret names]"),
    ("W4 content: credential keys pass", F, "        return words.contains { upper == $0 || upper.hasSuffix(\"_\" + $0) }", "        return false", "[secret content]"),
    ("W4 content: an alias's real name is not checked", F, "looksSecret(path: raw.path) || looksSecret(path: url.path), !keynote", "looksSecret(path: raw.path), !keynote", "[secret content]"),
    # Fix pass 1, W5: folders.
    ("W5 roots: the home folder and system folders pass", F, "        if exact.contains(path) { return true }\n", "", "[folder roots]"),
    ("W5 roots: a link to .ssh passes", F, "url.pathComponents.contains(where: { secretFolders.contains($0.lowercased()) })", "url.pathComponents.isEmpty", "[folder roots]"),
    ("W5 scan: only the top level is read", F, "                    if depth < folderScanDepth { queue.append((item, depth + 1, shown + \"/\")) }", "                    if depth < 1 { queue.append((item, depth + 1, shown + \"/\")) }", "[folder scan]"),
    # Fix pass 1, W1/W2/W3/N1: cleanup and Remove.
    ("W1 orphan: leaving the board deletes", F, "        let due = plan.completedSeenAt.map { now - cleanupClock(manifest, completedSeenAt: $0, newestReceipt: newestReceipt) >= cleanupDays * 86_400 } ?? false",
     "        let due = (plan.completedSeenAt.map { now - cleanupClock(manifest, completedSeenAt: $0, newestReceipt: newestReceipt) >= cleanupDays * 86_400 } ?? false) || (plan.orphanedSeenAt.map { now - $0 >= cleanupDays * 86_400 } ?? false)",
     "[orphan keep]"),
    ("W1 stamp: the first file is saved without the identity", F, "        guard let stampIdentity, !isolated else { return { true } }", "        guard let stampIdentity, !isolated, workID.isEmpty else { return { true } }", "[identity stamp]"),
    ("W3 clock: the newest file does not count", F, "        max(completedSeenAt, manifest.files.map(\\.addedAt).max() ?? 0, newestReceipt ?? 0)", "        max(completedSeenAt, newestReceipt ?? 0)", "[cleanup clock]"),
    ("W3 clock: the newest handoff does not count", F, "        max(completedSeenAt, manifest.files.map(\\.addedAt).max() ?? 0, newestReceipt ?? 0)", "        max(completedSeenAt, manifest.files.map(\\.addedAt).max() ?? 0)", "[cleanup clock]"),
    ("W2 in use: a card in flight is deleted", F, "        if due && !inUse { plan.deleteFolder = true; return plan }", "        if due { plan.deleteFolder = true; return plan }", "[cleanup refcount]"),
    ("N1 in use: unknown does not hold", F, 'nonisolated static let inUseStatuses: Set<String> = ["sending", "queued", "running", "unknown"]', 'nonisolated static let inUseStatuses: Set<String> = ["sending", "queued", "running"]', "[in use: unknown]"),
    ("N1 in use: sending does not hold", F, 'nonisolated static let inUseStatuses: Set<String> = ["sending", "queued", "running", "unknown"]', 'nonisolated static let inUseStatuses: Set<String> = ["queued", "running", "unknown"]', "[in use: sending]"),
    ("N1 in use: queued does not hold", F, 'nonisolated static let inUseStatuses: Set<String> = ["sending", "queued", "running", "unknown"]', 'nonisolated static let inUseStatuses: Set<String> = ["sending", "running", "unknown"]', "[in use: queued]"),
    ("Q4 remove: Remove deletes at once", F, "        setHidden(fileID, workID: workID, at: Date().timeIntervalSince1970)\n    }",
     "        setHidden(fileID, workID: workID, at: Date().timeIntervalSince1970)\n        if let root, let folder = folder(for: workID), let file = manifests[workID]?.files.first(where: { $0.id == fileID }) { Self.deleteCopies(file, root: root, folder: folder) }\n    }", "remove"),
    ("Q4 remove: a carried file is purged", F, "            return !carried.contains(file.id) && now - hidden >= removeGrace", "            return now - hidden >= removeGrace", "[remove hides]"),
    ("Q4 remove: no Undo grace", F, "            return !carried.contains(file.id) && now - hidden >= removeGrace", "            return !carried.contains(file.id) && hidden > 0", "[remove hides]"),
    # Fix pass 1, W6/W7/N3.
    ("W6 hover: the board line on hover", F, "        case .refuseFiles: onFileHover(true)\n        default: break", "        case .refuseFiles: onFileHover(true); onRefusedFiles()\n        default: break", "drop only"),
    ("W7 companion: a failed companion stops the start", F, "        if file.companions.contains(where: { $0.state == \"preparing\" }) { return (\"preparing\", nil) }\n        return (\"ready\", nil)",
     "        if file.companions.contains(where: { $0.state == \"preparing\" }) { return (\"preparing\", nil) }\n        if file.companions.contains(where: { $0.state == \"failed\" }) { return (\"failed\", \"x\") }\n        return (\"ready\", nil)", "[companion failure]"),
    ("N3 collision: the second folder is lost", F, "        if readManifest(second)?.workSourceID == workID { return second }\n", "", "[folder collision]"),
    # QA round 2: false refusals.
    ("R2 placeholder: env references count", F, "        for reference in [\"os.environ\", \"os.getenv\", \"getenv(\", \"process.env\", \"env[\", \"env.fetch\", \"import.meta.env\", \"secrets.\"] where lowerRaw.contains(reference) { return true }\n", "", "[secret placeholders]"),
    ("R2 placeholder: $1 and ${X} count", F, "        if value.hasPrefix(\"$\") || value.hasPrefix(\"{{\") || (value.hasPrefix(\"%\") && value.hasSuffix(\"%\")) { return true }", "        if value.hasPrefix(\"{{\") || (value.hasPrefix(\"%\") && value.hasSuffix(\"%\")) { return true }", "[secret placeholders]"),
    ("R2 placeholder: <your key> counts", F, "        if value.hasPrefix(\"<\") && value.hasSuffix(\">\") { return true }", "        if value.isEmpty { return true }", "[secret placeholders]"),
    ("R2 placeholder: YOUR_API_KEY and xxx count", F, "        for word in [\"your\", \"changeme\",", "        for word in [\"changeme\",", "[secret placeholders]"),
    ("R2 name: .env.example is a secret", F, 'if n.hasPrefix(".env"), !envTemplates.contains(n) { return true }', 'if n.hasPrefix(".env") { return true }', "secret"),
    # QA round 2: real values caught.
    ("R2 shape: sk- keys pass", F, '        #"\\b(sk-(?:proj-|live-|test-)?[A-Za-z0-9_-]{20,})"#,\n', "", "[secret content]"),
    ("R2 shape: AKIA ids pass", F, '        #"\\b(AKIA[0-9A-Z]{16})\\b"#,\n', "", "[secret content]"),
    ("R2 shape: user:pass@ in a URL passes", F, '        #"[A-Za-z][A-Za-z0-9+.-]*://[^/\\s:@\'"]+:([^/\\s@\'"]+)@"#,\n', "", "[secret content]"),
    ("R2 JSON: credential pairs pass", F, "                if credentialKey(String(text[key])), !placeholderValue(\"\\\"\" + text[value] + \"\\\"\") { return true }", "                _ = (key, value)", "[secret content]"),
    ("R2 YAML: key: value lines pass", F, '(?:=|:(?=\\s))', '(?:=)', "[secret content]"),
    ("R2 UTF-16: read as audio again", F, "        if b.count >= 2, (b[0] == 0xFF && b[1] == 0xFE) || (b[0] == 0xFE && b[1] == 0xFF) {", "        if b.count >= 2, b.isEmpty {", "[utf16 sniff]"),
    # QA round 2: the folder scan.
    ("R2 scan: fails open past the cap", F, "                if seen > folderScanLimit { return .tooBig }", "                if seen > folderScanLimit { return .clean }", "[folder fail closed]"),
    ("R2 scan: three levels", F, "    nonisolated static let folderScanDepth = 4", "    nonisolated static let folderScanDepth = 3", "[folder scan]"),
    ("R2 roots: Documents is not too wide", F, '                                  homePath + "/Documents", homePath + "/Desktop", homePath + "/Downloads"]', '                                  homePath + "/Desktop", homePath + "/Downloads"]', "[folder roots]"),
    # QA round 2: the stamp and Undo.
    ("R2 stamp: copies wait for the stamp", F, "        let identity = identityGate(workID)\n        begin(workID, urls.count)", "        let identity = identityGate(workID)\n        _ = await identity()\n        begin(workID, urls.count)", "[identity in parallel]"),
    ("R2 stamp: a failed stamp refuses the file", F, "        let stamped = await identity()\n        do {", "        let stamped = await identity()\n        if !stamped { return .failure(.noFile) }\n        do {", "[identity stamp]"),
    ("R2 undo: a duplicate is restored", F, "                    manifest.files[index].hiddenAt = Date().timeIntervalSince1970 - WorkCardFiles.removeGrace\n                    refusal = .duplicate(name)", "                    manifest.files[index].hiddenAt = nil; _ = name", "[undo duplicate]"),
    ("R2 undo: past the cap", F, "                case let other?: refusal = other", "                case .some: manifest.files[index].hiddenAt = nil", "[undo cap]"),
    # 0.5.258: files on a meeting.
    ("M key: the key grammar loosened", F, 'key.range(of: "^(g2|ff):[A-Za-z0-9:_-]{3,96}$", options: .regularExpression) != nil', 'key.range(of: "^(g2|ff):.{3,96}$", options: .regularExpression) != nil', "context-key rules are the same"),
    ("M policy: the meeting store takes any meeting id", F, "        case .meeting: return WorkCardFiles.meetingKey(of: id) != nil", '        case .meeting: return id.hasPrefix("meeting")', "[store policy]"),
    ("M policy: the card store takes a meeting id", F, '        case .work: return WorkProgress.boardTask(id) != nil || id.hasPrefix("task:")', '        case .work: return WorkProgress.boardTask(id) != nil || id.hasPrefix("task:") || id.hasPrefix("meetingctx:")', "[store policy]"),
    ("M heading: a status line as a meeting title", F, '        if folded.contains("cos-work") || folded.contains("cos work handoff") || !WorkProgress.reports(in: clean).isEmpty', '        if folded.contains("cos work handoff")', "[heading]"),
    ("M dedupe: the same contents twice", F, "                guard !seen.contains(file.sha256) else { continue }", "                guard !seen.contains(file.sha256) || true else { continue }", "[meeting dedupe]"),
    ("M delta: Continue resends meeting files", F, '                if inSession.contains(file.id + "|" + file.sha256) { out.meetingAlready.append(file); continue }', '                if inSession.isEmpty && false { out.meetingAlready.append(file); continue }', "[meeting delta]"),
    ("M secret: a flagged screenshot is sent", F, "                if secretFlagged(file) {", "                if secretFlagged(file) && false {", "[meeting omissions]"),
    ("M cap: meeting files ignore the 20", F, "        let room = max(0, maxFiles - card.sending.count)", "        let room = maxFiles", "[meeting cap]"),
    ("M trim: nothing is dropped to fit", F, "        while !entries.isEmpty && !fits(composed) {", "        while !entries.isEmpty && !fits(composed) && false {", "[meeting trim]"),
    ("M trim: the card's own block is replaced by nothing", F, "        out.block = entries.isEmpty ? card.block : composed", "        out.block = composed", "[meeting trim]"),
    ("M OCR: a meeting image gets no text copy", F, '        let words = ocr ? ["text"] : []', "        let words: [String] = []", "[companion plan]"),
    ("M OCR: a card image gets a text copy", F, '        let words = ocr ? ["text"] : []', '        let words = ["text"]', "[companion plan]"),
    ("M OCR secret: a credential screenshot is not flagged", F, "            if image && ocrLooksSecret(text) { return fail(ocrSecretFailure) }\n", "", "[meeting OCR secret]"),
    ("M retention: a sent file is purged", F, "            return !carried.contains(file.id) && now - hidden >= meetingPurgeDays * 86_400", "            return now - hidden >= meetingPurgeDays * 86_400", "[meeting retention]"),
    ("M retention: no 14 days", F, "            return !carried.contains(file.id) && now - hidden >= meetingPurgeDays * 86_400", "            return !carried.contains(file.id) && hidden > 0", "[meeting retention]"),
    ("M join: the folder's aliases are not read", F, "where manifest.aliases.contains(ref.recordId) && !ids.contains(id)", "where false && !ids.contains(id)", "[meeting into card]"),
    ("M join: a card's send leaves its meetings out", F, "        guard policy == .work, let groups = meetingGroups?(workID), !groups.isEmpty else { return card }", "        return card", "[meeting into card]"),
    ("M receipt: meeting-only files are not recorded", "Sources/WorkHandoffStore.swift", "            if files.sending.isEmpty && !files.meetingSending.isEmpty { row.context = files.refs }\n", "", "[meeting into card]"),
    ("M receipt: the meeting omissions are not on the timeline", "Sources/WorkHandoffStore.swift",
     '            if !files.meetingOmitted.isEmpty { progress.record(.note, "Meeting files left out: " + files.meetingOmitted.joined(separator: " "), at: row.createdAt) }\n', "", "[meeting omissions]"),
    ("M alias: viewing records no alias", F, "                    manifest.aliases.append(info.recordId)\n", "", "[meeting aliases]"),
    ("M alias: no cap", F, "                    if manifest.aliases.count > WorkCardFiles.maxAliases { manifest.aliases.removeFirst(manifest.aliases.count - WorkCardFiles.maxAliases) }\n", "", "[meeting aliases]"),
    ("M OCR hold: a screenshot still being read is sent", F, '        case "preparing": return "its words are still being read, so it goes with a later send"', '        case "preparing": return nil', "[meeting OCR hold]"),
    ("M OCR hold: an unchecked screenshot is sent", F, '        default: return text.failure == noWordsFailure ? nil : "its words could not be checked, so it is not sent"', "        default: return nil", "[meeting OCR hold]"),
    ("M OCR hold: the composer ignores the hold", F, "                if let reason = ocrHold(file) {", "                if let reason = ocrHold(file), false {", "[meeting OCR hold]"),
    ("M OCR secret: line numbers hide KEY=value", F, "        if ungutter != lines, secretContent(ungutter.joined(separator: \"\\n\")) { return true }\n", "", "[meeting OCR secret]"),
    ("M OCR secret: no screenshot shapes", F, "        if ocrSecretShapes.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) { return true }\n", "", "[meeting OCR secret]"),
    ("M ambiguity: an ambiguous meeting's keys are kept", F, "            guard answer.supported == true, !valid.isEmpty, recordKeyMap[answer.recordId] != valid else { continue }",
     "            guard !valid.isEmpty, recordKeyMap[answer.recordId] != valid else { continue }", "[meeting ambiguity]"),
    ("M ambiguity: a meeting that became ambiguous keeps its keys", F, "            if answer.supported == false, recordKeyMap.removeValue(forKey: answer.recordId) != nil { changed = true; continue }\n", "", "[meeting ambiguity]"),
    ("M OCR secret: labels with spaces pass", F, "                if parts.count == 2, label(parts[0]) != nil, plausible(parts[1]) { return true }", "                _ = parts", "[meeting OCR secret]"),
    ("M OCR secret: a label and value on two lines pass", F, "               !ungutter[index + 1].contains(\" \"), plausible(ungutter[index + 1]) { return true }", "               false { return true }", "[meeting OCR secret]"),
    ("M OCR secret: any value counts", F, "            return value.count >= 8 && !value.contains(\" \") && !placeholderValue(value)", "            return !value.isEmpty", "[meeting OCR secret]"),
    ("M OCR secret: only the first 8,000 characters", F, "recognizeText(at: original, limit: 400_000)", "recognizeText(at: original)", "OCR secret check reads all"),
    ("M resolve: the map is not kept on disk", F, "            try data.write(to: url, options: .atomic)\n", "", "[meeting resolve]"),
    ("M resolve: the send does not ask first", "Sources/WorkHandoffStore.swift", "        if let prepare = cardFiles.prepareMeetingGroups { await prepare(source.id) }\n", "", "[meeting resolve]"),
    ("M trim: the send's own limit is not applied", "Sources/WorkHandoffStore.swift", "                                                  && (!cutsForCursor || Self.cursorPrefillFits(candidate, tag: tag, instruction: instruction))", "", "[meeting trim]"),
    ("M wording: the meeting store says card", F, "    func flash(_ notes: [WorkCardRefusal], on workID: String) { flashes[workID] = WorkCardFlash(notes, meeting: policy == .meeting) }", "    func flash(_ notes: [WorkCardRefusal], on workID: String) { flashes[workID] = WorkCardFlash(notes) }", "[meeting paste]"),
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
