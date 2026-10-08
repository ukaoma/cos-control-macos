#!/usr/bin/env python3
"""0.5.259 mutation lane for the Work search and order guards. Run by hand, never by a gate (each mutant compiles).

    python3 Tests/mutate-work-search.py <worktree> <scratch dir> [--workers N] [name ...]

0.5.267: one worker by default and never more than 2. One Control test compile can peak above 30 GB; three lanes at
once (the old default) asked for most of a 96 GB Mac. Every compile runs through Tests/compile-guard.sh, which also
serializes them machine-wide, and a guard stop ends the lane.

It copies the worktree once per worker to <scratch dir>/copy-<n>, proves each UNMUTATED copy green first (the Swift checks
Tests/run-work-search.sh, the pins Tests/work-search-pins.py, and the compiled helper's Tests/work-search-helper-checks.py),
then applies one mutant at a time: the target text must appear exactly once, the mutant must make a check fail, and the
failure must name the behaviour the mutant breaks ("check failed [<behaviour>]" from the Swift checks, the pin's own
words, or the failing assertion of the helper check). A mutant that lands and survives is a finding; one killed by
another check, or by the compiler, is reported as such. Each mutant runs only the lane that owns its file.
"""
import pathlib, shutil, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

V = "Sources/WorkWorkspaceView.swift"
C = "Sources/ControllerModel.swift"
A = "Sources/ActivityWindow.swift"
M = "Sources/Models.swift"
H = "HelperSources/main.swift"
# (name, file, original, mutant, words the killing failure must contain, lane: swift | pins | helper)
MUTANTS = [
    # Words and matches.
    ("stopwords kept", V, "$0.count >= 2 && !stopwords.contains($0) && seen.insert($0).inserted", "$0.count >= 2 && seen.insert($0).inserted", "[stopwords]", "swift"),
    ("single letters kept", V, "$0.count >= 2 && !stopwords.contains($0) && seen.insert($0).inserted", "$0.count >= 1 && !stopwords.contains($0) && seen.insert($0).inserted", "[stopwords]", "swift"),
    ("word start: inside a word", V, "tokens.contains { $0.hasPrefix(word) }", "tokens.contains { $0.contains(word) }", "[word start]", "swift"),
    ("title match: one word is enough", V, "if words.allSatisfy({ WorkSearch.found($0, in: title) })", "if words.contains(where: { WorkSearch.found($0, in: title) })", "match]", "swift"),
    ("words match: title only", V, "words.filter { WorkSearch.found($0, in: title) || WorkSearch.found($0, in: other) }", "words.filter { WorkSearch.found($0, in: title) }", "[words match]", "swift"),
    ("words match: file names left out", V, "other: [task.text, task.title, task.source] + task.meetingRefs.map(\\.title) + files)", "other: [task.text, task.title, task.source] + task.meetingRefs.map(\\.title))", "[words match]", "swift"),
    # Thresholds and the merge.
    ("band threshold: 0.15 excluded", V, "else if p >= bandThreshold {", "else if p > bandThreshold {", "[band threshold]", "swift"),
    ("band threshold: 0.10", V, "nonisolated static let bandThreshold = 0.15", "nonisolated static let bandThreshold = 0.10", "[band threshold]", "swift"),
    ("one threshold: a column-only tier", V, "        result.shown = Set(result.hits.keys)\n",
     "        result.shown = Set(result.hits.keys).union((meaning?.scores ?? [:]).filter { $0.value >= 0.05 && Set(board.map(\\.id)).contains($0.key) }.map(\\.key))\n",
     "[count invariant]", "swift"),
    ("one threshold: columns ignore the search", V, "result.active ? cards.filter { result.shown.contains($0.id) } : cards", "cards", "[count invariant]", "swift"),
    ("one threshold: a meaning match at 0.05", V, "nonisolated static let bandThreshold = 0.15", "nonisolated static let bandThreshold = 0.05", "threshold]", "swift"),
    ("meaning merge: a word match turns into meaning", V, "if var hit = result.hits[id] { hit.p = p; result.hits[id] = hit }", "if var hit = result.hits[id] { hit.p = p; hit.kind = .meaning; result.hits[id] = hit }", "[meaning merge]", "swift"),
    ("meaning merge: other boards' cards", V, "for (id, p) in meaning.scores where onBoard.contains(id) {", "for (id, p) in meaning.scores where !id.isEmpty || onBoard.contains(id) {", "[meaning merge]", "swift"),
    ("empty answer invents a meaning row", V, "                    else if p >= bandThreshold { result.hits[id] = WorkSearchHit(kind: .meaning, words: [], p: p) }\n                }",
     "                    else if p >= bandThreshold { result.hits[id] = WorkSearchHit(kind: .meaning, words: [], p: p) }\n                }\n                if meaning.scores.isEmpty, let first = board.first, result.hits[first.id] == nil { result.hits[first.id] = WorkSearchHit(kind: .meaning, words: []) }",
     "[empty answer]", "swift"),
    # The late answer, the pause, the minimum.
    ("stale drop: an old answer kept", V, "guard !Task.isCancelled, request.key == currentSearchKey else { staleMeaningDrops += 1; return }", "guard !Task.isCancelled else { staleMeaningDrops += 1; return }", "[stale drop]", "swift"),
    ("stale drop: any answer shown", V, "func meaning(for key: WorkSearchKey) -> WorkSearchMeaning? { meaning?.key == key ? meaning : nil }", "func meaning(for key: WorkSearchKey) -> WorkSearchMeaning? { meaning }", "[stale drop]", "swift"),
    ("same search asked twice", V, "        if let kept = meaning, kept.key == request.key, WorkSearch.settled(kept) { return }\n", "", "[same search once]", "swift"),
    ("no pause", V, "do { try await Task.sleep(for: searchPause) } catch { return }", "do { try await Task.sleep(for: .zero) } catch { return }", "[pause]", "swift"),
    ("meaning minimum: two characters", V, "fits && trimmed.unicodeScalars.count >= meaningMinimum && !words(trimmed).isEmpty", "fits && trimmed.unicodeScalars.count >= 2 && !words(trimmed).isEmpty", "[meaning minimum]", "swift"),
    ("meaning minimum: stopwords ask", V, "fits && trimmed.unicodeScalars.count >= meaningMinimum && !words(trimmed).isEmpty", "fits && trimmed.unicodeScalars.count >= meaningMinimum", "[meaning minimum]", "swift"),
    ("the preview asks the server", V, "let transport = isolated ? previewSearchTransport : searchTransport else { return }", "let transport = isolated ? (previewSearchTransport ?? Optional(searchTransport)) : searchTransport else { return }", "[meaning minimum]", "swift"),
    # Best matches, counts, other domains, lines.
    ("band: Jev not first", V, "if let p = hit.p, p >= bandThreshold { return 0 }", "if let p = hit.p, p >= 2 { return 0 }", "[band order]", "swift"),
    ("band: Jev order ignored", V, "if l == 0, left.value.p != right.value.p { return (left.value.p ?? 0) > (right.value.p ?? 0) }", "if l == 0, left.value.p != right.value.p { return (left.value.p ?? 0) < (right.value.p ?? 0) }", "[band order]", "swift"),
    ("band: word count ignored", V, "if l == 2, left.value.words.count != right.value.words.count {", "if l == 9, left.value.words.count != right.value.words.count {", "[band order]", "swift"),
    ("band: four rows", V, "nonisolated static let bandLimit = 3", "nonisolated static let bandLimit = 4", "[band order]", "swift"),
    ("why: every word", V, 'hit.words.prefix(2).map { "\\u{201C}" + $0 + "\\u{201D}" }', 'hit.words.map { "\\u{201C}" + $0 + "\\u{201D}" }', "[why labels]", "swift"),
    ("why: meaning says Title", V, 'case .meaning: "Similar meaning"', 'case .meaning: "Title"', "[why labels]", "swift"),
    ("n of m: whole column", V, 'active ? "\\(kept) of \\(all)" : "\\(all)"', '"\\(all)"', "[count invariant]", "swift"),
    ("no matches line lost", V, 'hits.isEmpty ? (pending ? "Searching by meaning\\u{2026}" : "No matches on this board") : countText', "countText", "[no matches]", "swift"),
    ("other domains: this domain counted", V, ".filter { $0.task != nil && $0.domain != domain }", ".filter { $0.task != nil }", "[other domains]", "swift"),
    ("other domains: several named as one", V, 'elsewhere.count == 1 ? "\\(total) more in " + first.domain : "\\(total) more in other domains"', '"\\(total) more in " + first.domain', "[other domains]", "swift"),
    ("degrade: the breaker read as the day's budget", V, 'case "jev_breaker_open": "Meaning search is paused for an hour"', 'case "jev_breaker_open": "Meaning search has used today\\u{2019}s budget"', "[degrade line]", "swift"),
    ("degrade: too many cards say nothing", V, '        case "too_many_candidates": "Meaning search covers up to \\(maxCandidates) cards. Pick a domain."\n', "", "[degrade line]", "swift"),
    ("degrade: no key says nothing", V, '        case "jev_not_configured": "Meaning search needs a TypeSafe key in Settings"\n', "", "[degrade line]", "swift"),
    ("degrade: older server says nothing", V, 'case "server_too_old": "Meaning search needs COS server 6.65"', 'case "server_too_old_x": "Meaning search needs COS server 6.65"', "line]", "swift"),
    ("degrade: search_off says something", V, "        default: nil\n        }\n    }\n    /// Reasons that cannot change by asking again",
     '        default: reason == "search_off" ? "Meaning search is off" : nil\n        }\n    }\n    /// Reasons that cannot change by asking again', "[degrade line]", "swift"),
    ("keys: down past the band", V, ".highlight(min(max(highlighted, 0) + 1, bandCount - 1))", ".highlight(max(highlighted, 0) + 1)", "[keys]", "swift"),
    ("keys: up past the top", V, ".highlight(max(min(highlighted, bandCount - 1) - 1, 0))", ".highlight(min(highlighted, bandCount - 1) - 1)", "[keys]", "swift"),
    ("keys: Escape with nothing typed", V, "case .clear: return query.isEmpty ? .pass : .clear", "case .clear: return .clear", "[keys]", "swift"),
    ("keys: Return past the band", V, "case .open: return bandCount == 0 ? .pass : .open(min(max(highlighted, 0), bandCount - 1))", "case .open: return bandCount == 0 ? .pass : .open(highlighted)", "[keys]", "swift"),
    ("escape: clears over an open card", V, "guard !query.isEmpty, selectedID == nil, !meetingPicker,", "guard !query.isEmpty, !meetingPicker,", "[escape clears]", "swift"),
    ("escape: clears over Start work", V, "!meetingPicker, startItemID == nil, !intakeOpen,", "!meetingPicker, !intakeOpen,", "[escape clears]", "swift"),
    # Order and its memory.
    ("order: undated first", V, "            case (nil, .some): return false\n            case (.some, nil): return true",
     "            case (nil, .some): return true\n            case (.some, nil): return false", "order]", "swift"),
    ("order: oldest is newest", V, "return order == .oldest ? l < r : l > r", "return l > r", "[oldest order]", "swift"),
    ("order: ties not in board order", V, "            default: return left.offset < right.offset\n            }\n        }.map(\\.card)", "            default: return left.offset > right.offset\n            }\n        }.map(\\.card)", "[recent order]", "swift"),
    ("memory: the preview writes", V, "        if !isolated { orderStore.write(key, order.rawValue) }", "        orderStore.write(key, order.rawValue)", "[order memory]", "swift"),
    ("memory: one key for every board", V, '"cos.workOrder." + (domain.map { "domain:" + $0 } ?? "all") + "|" + scope.rawValue', '"cos.workOrder." + scope.rawValue', "[order memory]", "swift"),
    ("memory: nothing read", V, "return isolated ? .board : (orderStore.read(key).flatMap(WorkBoardOrder.init(rawValue:)) ?? .board)", "return .board", "[order memory]", "swift"),
    # Dates.
    ("created: the server's day ignored", V, '        if let server = task.createdOn, let date = day(server, calendar: calendar) { return (date, task.createdFrom == "git") }\n', "", "[created day]", "swift"),
    ("created: a day that is not real", V, "calendar.component(.day, from: date) == parts[2], calendar.component(.month, from: date) == parts[1] else { return nil }", "true else { return nil }", "[created day]", "swift"),
    ("created: only the first date", V, "            rest = rest[range.upperBound...]\n", "            return nil\n", "[created day]", "swift"),
    ("created: link targets read as dates", V, '        let label = source.replacingOccurrences(of: #"\\[([^\\]]*)\\]\\([^)]*\\)"#, with: "$1", options: .regularExpression)', '        let label = source', "[source date parity]", "swift"),
    ("created: any century", V, '#"20[0-9]{2}-[0-9]{2}-[0-9]{2}"#', '#"[0-9]{4}-[0-9]{2}-[0-9]{2}"#', "[source date parity]", "swift"),
    ("activity: line change ignored", V, "[instant(task.lineChangedAt), moved, session, file]", "[moved, session, file]", "[activity source: line change]", "swift"),
    ("activity: stage move ignored", V, "[instant(task.lineChangedAt), moved, session, file]", "[instant(task.lineChangedAt), session, file]", "[activity source: stage move]", "swift"),
    ("activity: session ignored", V, "[instant(task.lineChangedAt), moved, session, file]", "[instant(task.lineChangedAt), moved, file]", "[activity source: session]", "swift"),
    ("activity: file ignored", V, "[instant(task.lineChangedAt), moved, session, file]", "[instant(task.lineChangedAt), moved, session]", "[activity source: file]", "swift"),
    ("activity: a refused send counts", V, 'where receipt.createdAt > 0 && !["refused", "failed", "canceled"].contains(receipt.status)', "where receipt.createdAt > 0", "[activity source: session]", "swift"),
    ("activity: the created day as a moment", V, "return WorkCardDates(created: created, firstSeen: firstSeen, active: created, activeIsDay: created != nil)", "return WorkCardDates(created: created, firstSeen: firstSeen, active: created, activeIsDay: false)", "[activity source: created]", "swift"),
    ("date line: a day in hours", V, "if !isDay && seconds < 86_400 {", "if seconds < 86_400 {", "[date line]", "swift"),
    ("date line: no year", V, 'return parts.year == calendar.component(.year, from: now) ? text : text + ", \\(parts.year ?? 0)"', "return text", "[date line]", "swift"),
    ("journal: the same stage noted", V, "guard let next = WorkBoardStage(rawValue: stage), next != WorkBoardStage.stage(for: task) else { return }", "guard WorkBoardStage(rawValue: stage) != nil else { return }", "[journal stage change]", "swift"),
    ("journal: unbounded", V, "moves = Self.bounded(next, limit: Self.limit)", "moves = next", "[journal bound]", "swift"),
    ("journal: the oldest kept", V, "$0.value == $1.value ? $0.key < $1.key : $0.value > $1.value", "$0.value == $1.value ? $0.key < $1.key : $0.value < $1.value", "[journal bound]", "swift"),
    ("journal: not written", V, "do { try Self.encode(moves).write(to: url, options: .atomic) }", "do { _ = url }", "[journal", "swift"),
    ("journal: a bad entry fails the file", V, "            if let date = WorkCardDating.instant(value as? String) { moves[id] = date }", "            guard let date = WorkCardDating.instant(value as? String) else { return [:] }; moves[id] = date", "[journal write]", "swift"),
    ("journal: a board move not noted", C, "            self?.workActivity.recordStageChange(task, to: stage)\n", "            _ = self\n", "[journal stage change]", "swift"),
    ("journal: noted before the write is accepted", C, "        guard response.ok else { throw HelperClientError.commandFailed(response.message) }\n        saved?()\n",
     "        saved?()\n        guard response.ok else { throw HelperClientError.commandFailed(response.message) }\n", "noted only once the write is accepted", "pins"),
    ("journal: Intake and Waiting on not noted", C, '                if let stage = fields["workStage"] { workActivity.recordStageChange(current, to: stage) }\n', "", "[journal stage change]", "swift"),
    ("journal: checks write the real file", V, '        if let home = environment["COS_CONTROL_TEST_HOME"] { return URL(fileURLWithPath: home).appendingPathComponent("work-activity.json") }\n', "", "[journal write]", "swift"),
    # Rows, request and answer.
    ("rows: createdOn dropped", M, '        createdOn = o["createdOn"]?.string.flatMap { $0.isEmpty ? nil : $0 }', "        createdOn = nil", "created day]", "swift"),
    ("rows: lineChangedAt dropped", M, '        lineChangedAt = o["lineChangedAt"]?.string.flatMap { $0.isEmpty ? nil : $0 }', "        lineChangedAt = nil", "activity source: line change]", "swift"),
    ("request: a list sends its view", V, '            body["ids"] = .array(ids.map(JSONValue.string))\n', '            body["scope"] = .string(key.scope.rawValue)\n', "[search request]", "swift"),
    ("request: the domain left out", V, '            if let domain = key.domain { body["domain"] = .string(domain) }\n', "", "[search request]", "swift"),
    ("request: past a Choice", V, "fits = !ids.isEmpty && ids.count <= maxCandidates", "fits = !ids.isEmpty", "[search request]", "swift"),
    ("request: preview ids sent", V, 'guard let task = item.task, task.id.range(of: "^[a-f0-9]{12}$", options: .regularExpression) != nil else { continue }', "guard let task = item.task else { continue }", "[search request]", "swift"),
    ("answer: p over 1 kept", V, "p.isFinite, p >= 0, p <= 1 else { continue }", "p.isFinite else { continue }", "[work-search answer]", "swift"),
    ("answer: a failed helper is an answer", V, "        guard response.ok else { return WorkSearchMeaning(key: request.key, available: false, reason: \"unreachable\") }\n", "", "[work-search answer]", "swift"),
    # Wiring (pins).
    ("view: columns keep every card", V, "let kept = WorkSearch.kept(all, pass.search)", "let kept = all", "keeps only what the search shows", "pins"),
    ("view: the board line counts its own way", V, "let shownCount = WorkSearch.kept(cards.filter { $0.task != nil }, search).count",
     "let shownCount = cards.filter { $0.task != nil && search.hits[$0.id] != nil }.count", "same rule as the columns", "pins"),
    ("view: Jev asked on every keystroke", V, ".task(id: state.currentSearchKey) {", ".task(id: state.query) {", "a new search cancels the wait", "pins"),
    ("view: the late answer is read", V, "meaning: state.meaning(for: state.currentSearchKey),", "meaning: state.meaning,", "only the current search's answer", "pins"),
    ("view: no ⌘F", V, 'Button("Search the board") { state.searchFocusRequest &+= 1 }.keyboardShortcut("f", modifiers: .command)', 'Button("Search the board") { state.searchFocusRequest &+= 1 }.keyboardShortcut("g", modifiers: .command)', "⌘F", "pins"),
    ("view: arrows not wired", V, ".onKeyPress(keys: [.downArrow, .upArrow, .return, .escape])", ".onKeyPress(keys: [.return, .escape])", "Return and Escape reach", "pins"),
    ("view: matched card not bordered", V, "matched: hit != nil", "matched: false", "gold border", "pins"),
    ("view: Order as a row of buttons", V, 'COSDropdown("Order", selection:', 'COSViewSwitch("Order", selection:', "Order is the house dropdown", "pins"),
    ("view: an em dash in the copy", V, '"No matches on this board"', '"No matches — on this board"', "em dash", "pins"),
    ("window: Escape goes back first", A, "        if section == .work, workWorkspaceState.escapeClearsSearch() { return true }\n", "", "Escape on Work clears", "pins"),
    ("view: files read by the wrong id", V, "let file = cardFiles.lastAdded(item.sourceID).flatMap", "let file = cardFiles.lastAdded(item.id).flatMap", "each by the card's work id", "pins"),
    ("files: the first file, not the last", "Sources/WorkCardFiles.swift", "manifests[workID]?.files.map(\\.addedAt).max()", "manifests[workID]?.files.map(\\.addedAt).min()", "newest addedAt", "pins"),
    ("files: no epoch for the search", "Sources/WorkCardFiles.swift", "= [:] { didSet { manifestsEpoch &+= 1 } }", "= [:]", "reaches the search", "pins"),
    ("tracker: moves around setWorkStage", C, "try await self.setWorkStage(task, stage: stage)", "try await self.mutateWorkStageQuietly(task, stage: stage)", "tracker moves cards", "pins"),
    # QA round 1.
    ("order names claim creation", V, '        case .newest: "Newest"\n', '        case .newest: "Newest created"\n', "[order names]", "swift"),
    ("pending never told", V, "        meaningPending = request.key\n", "", "[pending line]", "swift"),
    ("pending never cleared", V, "        defer { if meaningPending == request.key { meaningPending = nil } }\n", "", "[pending line]", "swift"),
    ("pending ignored by the line", V, '(pending ? "Searching by meaning\\u{2026}" : "No matches on this board")', '"No matches on this board"', "[pending line]", "swift"),
    ("temporary failure line hidden", V, 'case "jev_unavailable": "Meaning search is temporarily unavailable. Showing word matches."', 'case "jev_unavailable": nil', "[degrade line]", "swift"),
    ("any answer settles", V, '{ meaning.available || definitiveReasons.contains(meaning.reason ?? "") }', "{ _ = meaning; return true }", "[transient answers]", "swift"),
    ("search_off asked again", V, 'definitiveReasons: Set<String> = ["search_off", "jev_not_configured"', 'definitiveReasons: Set<String> = ["jev_not_configured"', "[definitive answers]", "swift"),
    ("a refused request asked again", V, '"too_many_candidates", "jev_request_rejected"]', '"too_many_candidates"]', "[definitive answers]", "swift"),
    ("a refused key says nothing", V, '        case "jev_key_rejected": "TypeSafe did not accept the saved key. Check it in Settings."\n', "", "[degrade line]", "swift"),
    ("a refused request says nothing", V, '        case "jev_request_rejected": "Meaning search could not take this search"\n', "", "[degrade line]", "swift"),
    ("first seen labelled dated", V, '(dates?.firstSeen == true ? "first seen " : "dated ")', '"dated "', "[honest dates]", "swift"),
    ("a git day read as the card's date", V, 'return (date, task.createdFrom == "git")', "return (date, false)", "[honest dates]", "swift"),
    ("Complete claims meaning on All work", V, "        !(key.scope == .all && key.domain == nil && stage == .complete)\n", "        true\n", "[empty columns]", "swift"),
    ("an empty column claims while pending", V, '        if pending { return "Searching\\u{2026}" }\n', "", "[empty columns]", "swift"),
    ("dates worked out every redraw", V, "        if next != datesKey {\n            dates = build(items); datesKey = next", "        if true {\n            dates = build(items); datesKey = next", "[dates memo]", "swift"),
    ("a formatter per date line", V, "        let parts = calendar.dateComponents([.year, .month, .day], from: date)\n",
     '        let slow = DateFormatter(); slow.locale = Locale(identifier: "en_US_POSIX"); slow.dateFormat = "MMM d, yyyy"; _ = slow.string(from: date)\n        let parts = calendar.dateComponents([.year, .month, .day], from: date)\n', "[dates cost]", "pins"),
    ("Focus by substring again", V, "            if !words.isEmpty && WorkSearch.fields(item, files: fileNames(item.sourceID)).match(words) == nil { return false }",
     "            if !query.isEmpty && !(item.title + \" \" + item.searchText).localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespacesAndNewlines)) { return false }", "[focus parity]", "swift"),
    ("Focus without file names", V, "WorkSearch.fields(item, files: fileNames(item.sourceID)).match(words) == nil", "WorkSearch.fields(item, files: []).match(words) == nil", "[focus parity]", "swift"),
    ("code points counted as characters", V, "        let trimmed = String(String.UnicodeScalarView(whole.unicodeScalars.prefix(maxQuery)))", "        let trimmed = String(whole.prefix(maxQuery))", "[code points]", "swift"),
    ("degrade left untraced", V, '            NSLog("COS Work search: meaning search unavailable (%@), %ld-character search", (answer.reason ?? "unknown") as NSString, request.length)\n', "", "[degrade log]", "swift"),
    ("degrade log carries the query", V, '(answer.reason ?? "unknown") as NSString, request.length)\n', '(answer.reason ?? "unknown") as NSString, request.length); NSLog("COS Work search: %@", request.key.query as NSString)\n', "[degrade log]", "swift"),
    ("app waits less than the helper", V, "try await helper.run(args, timeout: 30, stdinData: data)", "try await helper.run(args, timeout: 15, stdinData: data)", "app waits longer", "pins"),
    ("journal save failure silent", V, 'catch { NSLog("COS Work: the stage-move journal could not be saved: %@", error.localizedDescription as NSString) }', "catch {}", "failed save is logged", "pins"),
    ("comment says no text leaves", V, "sends their text on to Jev (TypeSafe) with URLs, emails and secrets removed.", "no task text leaves the app.", "where task text goes", "pins"),
    ("the old box back in Focus", V, 'WorkBoardSearchField(prompt: "Search work", query: $state.query, focusRequest: state.searchFocusRequest, onKey: { _ in false })',
     'WorkBoardSearchField(prompt: "Search work", query: $state.query, focusRequest: 0, onKey: { _ in false })', "Focus has the board's box and ⌘F", "pins"),
    ("helper waits 12 s", H, "timeout: 25, reviewCandidatePort: candidate?.port) else {", "timeout: 12, reviewCandidatePort: candidate?.port) else {", "helper waits longer", "pins"),
    ("search switch lost on Update Server", H, '        "COS_JEV_SEARCH",\n', "", "survive Update Server", "pins"),
    ("search cap lost on Update Server", H, '        "COS_JEV_SEARCH_DAILY_TOKENS",\n', "", "survive Update Server", "pins"),
    ("helper: code points counted as characters", H, "guard (2...200).contains(trimmed.unicodeScalars.count) else { return false }", "guard (2...200).contains(trimmed.count) else { return false }", "201 code points", "helper"),
    # The helper.
    ("helper: work-search not routed", H, '        case "work-search": try emitWorkSearch()\n', "", "/api/work/search", "helper"),
    ("helper: one-character query sent", H, "guard (2...200).contains(trimmed.unicodeScalars.count) else { return false }", "guard (1...200).contains(trimmed.unicodeScalars.count) else { return false }", "assert not r['ok'], bad", "helper"),
    ("helper: any scope sent", H, '["all", "attention", "progress", "completed"].contains(scope) else { return false }', "!scope.isEmpty else { return false }", "assert not r['ok'], bad", "helper"),
    ("helper: 255 ids sent", H, "guard let ids = raw as? [Any], ids.count <= 254,", "guard let ids = raw as? [Any], ids.count <= 1000,", "assert not r['ok'], bad", "helper"),
    ("helper: p outside 0 to 1 kept", H, "case let p = number.doubleValue, p.isFinite, p >= 0, p <= 1 else { return nil }", "case let p = number.doubleValue, p.isFinite else { return nil }", "kept", "helper"),
    ("helper: a boolean p kept", H, "let number = row[\"p\"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),", "let number = row[\"p\"] as? NSNumber,", "kept", "helper"),
    ("helper: any reason text passes", H, '(body["reason"] as? String).flatMap { $0.range(of: "^[a-z_]{3,48}$", options: .regularExpression) != nil ? $0 : nil }',
     '(body["reason"] as? String)', "jev_unavailable", "helper"),
    ("helper: K7 older server not named", H, '            emit(ok: true, message: "Meaning search unavailable", details: ["available": false,\n                 "reason": Self.sessionRecommendFailureReason(status: response.status, body: response.body)])',
     '            emit(ok: true, message: "Meaning search unavailable", details: ["available": false,\n                 "reason": "http_\\(response.status)"])', "reason", "helper"),
    ("helper: an unreachable server is an error", H, '            emit(ok: true, message: "Meaning search unavailable", details: ["available": false, "reason": "unreachable"]); return',
     '            throw HelperError.message("unreachable")', "unreachable", "helper"),
    ("helper: K8 dates dropped", H, "                if let value = row[key] as? String, valid(value) { projected[key] = value } else { projected[key] = NSNull() }",
     "                projected[key] = NSNull(); _ = valid", "2026-10-06", "helper"),
    ("helper: K8 any createdFrom", H, '("createdFrom", { ["source", "git"].contains($0) }),', '("createdFrom", { !$0.isEmpty }),', "rows[old]", "helper"),
    ("helper: K8 any lineChangedAt", H, '("lineChangedAt", { $0.count <= 40 && $0.range(of:', '("lineChangedAt", { $0.count <= 40 || $0.range(of:', "rows[old]", "helper"),
]

def run(cmd, cwd, timeout=1800):
    started = time.time()
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    # 0.5.267: every compile in the lane runs through Tests/compile-guard.sh; a guard stop ends the lane (it is not a kill).
    if "compile-guard: STOPPED" in proc.stdout + proc.stderr:
        sys.exit("compile-guard stopped a compile (memory); ending the mutation lane. " + (proc.stderr or "")[-400:])
    return proc.returncode, proc.stdout + proc.stderr, time.time() - started

def helper_lane(copy):
    out = copy / "helper-bin"
    code, text, s1 = run(["zsh", "Tests/compile-guard.sh", "swiftc", "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete",
                          "HelperSources/main.swift", "HelperSources/ProviderStatusCore.swift", "-framework", "Security", "-framework", "AppKit", "-o", str(out)], copy)
    if code != 0:
        return code, text, s1
    code, text2, s2 = run(["python3", "Tests/work-search-helper-checks.py", str(out)], copy)
    return code, text + text2, s1 + s2

def lane(copy, which):
    if which == "pins":
        return run(["/usr/bin/python3", "Tests/work-search-pins.py", "."], copy)
    if which == "helper":
        return helper_lane(copy)
    code, out, seconds = run(["zsh", "Tests/run-work-search.sh"], copy)
    if code != 0:
        return code, out, seconds
    code2, out2, seconds2 = run(["/usr/bin/python3", "Tests/work-search-pins.py", "."], copy)
    return code2, out + out2, seconds + seconds2

def reason_of(out):
    lines = out.splitlines()
    for i, l in enumerate(lines):
        if "check failed [" in l or "0.5.259 pin:" in l or " error:" in l:
            return l.strip()
        if l.startswith("AssertionError"):
            return " | ".join(x.strip() for x in lines[max(0, i - 2):i + 1])
    return lines[-1].strip() if lines else ""

def worker(n, src, scratch, mutants):
    copy = scratch / f"copy-{n}"
    if copy.exists():
        shutil.rmtree(copy)
    for part in ("Sources", "Tests", "Resources", "HelperSources", "scripts"):
        shutil.copytree(src / part, copy / part)
    rows = []
    lanes = sorted({m[5] for m in mutants})
    for which in lanes:
        code, out, seconds = lane(copy, which)
        print(f"[w{n}] BASELINE {which} (unmutated): exit {code} in {seconds:.0f}s", flush=True)
        if code != 0:
            print(out[-3000:], flush=True)
            return [(m[0], "NO BASELINE", "") for m in mutants]
    for name, rel, old, new, words, which in mutants:
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            print(f"[w{n}] MISS  {name}: the target appears {text.count(old)} times", flush=True); rows.append((name, "MISSED", "")); continue
        path.write_text(text.replace(old, new), encoding="utf-8")
        try:
            code, out, seconds = lane(copy, which)
        finally:
            path.write_text(text, encoding="utf-8")
        assert path.read_text(encoding="utf-8") == text, "restore failed"
        reason = reason_of(out)
        if code == 0:
            rows.append((name, "SURVIVED", "")); print(f"[w{n}] SURVIVED  {name}", flush=True)
        elif words.lower() in reason.lower():
            rows.append((name, "killed", reason)); print(f"[w{n}] killed  {name} ({seconds:.0f}s): {reason[:200]}", flush=True)
        else:
            rows.append((name, "KILLED BY ANOTHER CHECK", reason)); print(f"[w{n}] MISATTRIBUTED  {name}: {reason[:240]}", flush=True)
    return rows

def main():
    args = sys.argv[1:]
    workers = 1
    if "--workers" in args:
        i = args.index("--workers"); workers = int(args[i + 1]); del args[i:i + 2]
    if not 1 <= workers <= 2:
        sys.exit("--workers must be 1 or 2: each worker compiles the whole app (see the note at the top)")
    src, scratch = pathlib.Path(args[0]).resolve(), pathlib.Path(args[1]).resolve()
    only = set(args[2:])
    chosen = [m for m in MUTANTS if not only or m[0] in only]
    scratch.mkdir(parents=True, exist_ok=True)
    # Group by lane so each worker proves only the lanes it runs; spread the slow Swift lane across every worker.
    groups = [[] for _ in range(workers)]
    for index, m in enumerate(sorted(chosen, key=lambda m: m[5] != "swift")):
        groups[index % workers].append(m)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(lambda pair: worker(pair[0], src, scratch, pair[1]), enumerate(groups)))
    rows = [r for group in results for r in group]
    killed = sum(1 for r in rows if r[1] == "killed")
    print(f"RESULT: {killed}/{len(rows)} killed by a check that names the behaviour", flush=True)
    for name, status, reason in rows:
        if status != "killed":
            print(f"  {status}: {name} {reason[:200]}", flush=True)
    sys.exit(0 if killed == len(rows) else 1)

if __name__ == "__main__":
    main()
