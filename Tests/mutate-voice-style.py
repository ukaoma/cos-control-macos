#!/usr/bin/env python3
"""0.5.344 part 2, Your style (plan r2 section 2): the mutation gate for the ledger, the classifier and its evidence
filters, promotion, retirement, tombstones, ranking, the pill once per rule ever, the card's lines and the push to the
server (Sources/MacDictationCore.swift: DictationStyle, DictationStyleCopy, DictationStyleClassifier, and the record's
polishLine and guard) against Tests/VoiceStyleChecks.swift, which runs them against fictional fixtures and a fake server.

SERIAL by design: one small two-file compile at a time, each through Tests/compile-guard.sh (never parallel; see the
2026-10-07 kernel panics). Works on a scratch copy, so the checkout is never mutated. A GREEN baseline is required
before the first mutant (a red suite would "kill" every mutant). Each mutant must replace its target exactly once.

A KILL counts only when the mutant compiles, runs, and the check that fails first is the one the mutant names, so every
kill is attributed to the behaviour it breaks. Everything else fails this gate on its own line: SURVIVED, MISATTRIBUTED,
INVALID (did not compile, or timed out), CRASHED (a trap outside the checks).

Not mutated, on purpose (equivalent today): the tombstone term in activeIDs (a removed rule leaves the ledger, so no rule
is both present and tombstoned), the contradiction de-duplication by dictation (the per-dictation class guard reaches it
first), the longest-phrase-first sort (a phrase splices only when the word counts match exactly, so two phrases can never
both splice one region), remember's replace-by-hash (ruleCount reads the last entry), and a later region's contraction
direction (the first wins; no fixture mixes them). 0.5.344 QA: the controller's refused-evidence guard (learn() leaves
its copy untouched when it refuses, so assigning it back changes nothing), and Reset's DELETE on a server without the
setting (Reset there is local only and the checks reset only where the setting exists).

Usage: python3 Tests/mutate-voice-style.py <repo root> [--only <name prefix>[|<prefix>...]]
"""
import os
import pathlib, re, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1]).resolve()
only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""
CORE = "Sources/MacDictationCore.swift"
CHECKS = "Tests/VoiceStyleChecks.swift"

# (name, old, new, the behaviour whose check must fail first)
MUTANTS = [
    ('key: spaces dropped from ids', '            return "drop-" + String(param.lowercased().replacingOccurrences(of: " ", with: "-")', '            return "drop-" + String(param.lowercased().replacingOccurrences(of: " ", with: "")', 'key ids'),
    ('key: any phrase valid', '    func valid(allowlist: [String]) -> Bool { kind == .dropPhrase ? allowlist.contains(param) : ["use", "avoid"].contains(param) }', '    func valid(allowlist: [String]) -> Bool { kind == .dropPhrase ? true : ["use", "avoid"].contains(param) }', 'key valid'),
    ('key: avoid titled wrong', ': param == "use" ? "Use contractions" : "Write contractions out"', ': param == "use" ? "Use contractions" : "Avoid contractions"', 'key titles'),
    ('promote: after one', '    static let promoteAfter = 2', '    static let promoteAfter = 1', 'promote after two'),
    ('state: retired stays active', '        if rule.retired { return .retired }\n', '', 'retire outnumbered'),
    ('state: suggest activates', '        return suggestOnly ? .suggested : .active', '        return .active', 'suggest only'),
    ('support: an added rule counts zero', '    var support: Int { confirmations.count + (explicit ? 1 : 0) }', '    var support: Int { confirmations.count }', 'add a rule'),
    ('retired: one contradiction', '    var retired: Bool { contradictions.count >= 2 && contradictions.count > support }', '    var retired: Bool { contradictions.count > support }', 'retire at least two'),
    ('retired: a tie retires', '    var retired: Bool { contradictions.count >= 2 && contradictions.count > support }', '    var retired: Bool { contradictions.count >= 2 && contradictions.count >= support }', 'retire outnumbered'),
    ('tombstone: never expires', 'ledger.tombstones.contains { $0.id == id && $0.until > now }', 'ledger.tombstones.contains { $0.id == id }', 'tombstone expires'),
    ('tombstone: a day', '    static let tombstoneSeconds: TimeInterval = 30 * 24 * 3600', '    static let tombstoneSeconds: TimeInterval = 1 * 24 * 3600', 'tombstone'),
    ('tombstone: expired kept', '        next.tombstones = ledger.tombstones.filter { $0.until > now }', '        next.tombstones = ledger.tombstones', 'tombstone expires'),
    ('tombstone: removed rule seen again', '        guard !tombstoned(key.id, in: ledger, now: now) else { return }\n', '', 'add replaces opposite'),
    ('tombstone: Remove leaves none', '        ledger.tombstones.append(Tombstone(id: id, until: now.addingTimeInterval(tombstoneSeconds)))\n', '', 'add replaces opposite'),
    ('tombstone: Add keeps it', '        ledger.tombstones.removeAll { $0.id == key.id }\n', '', 'tombstone add'),
    ('observe: two of a class', '        for observation in observations where !kinds.contains(observation.key.kind) {', '        for observation in observations {', 'one per class'),
    ("observe: a dictation's classes forgotten", '        var kinds = ledger.seen.first { $0.dictation == dictation }?.kinds ?? []', '        var kinds: [Kind] = []', 'one per class'),
    ('observe: a dictation counted twice', '            if !ledger.rules[i].confirmations.contains(dictation) {', '            if true {', 'promote distinct dictations'),
    ('observe: opposite never contradicted', '                if let opposite = observation.key.opposite { contradict(&ledger, opposite, dictation: dictation, applied: applied) }\n', '', 'retire outnumbered'),
    ('observe: put back confirms', '            if observation.added {\n', '            if false {\n', 'retire at least two'),
    ('contradict: where not applied', '        guard applied.contains(key.id), let i = ledger.rules.firstIndex(where: { $0.key == key }),', '        guard let i = ledger.rules.firstIndex(where: { $0.key == key }),', 'contradiction needs applied'),
    ('add: any phrase', '        guard key.valid(allowlist: allowlist) else { return }\n', '', 'add closed'),
    ('accept: does nothing', '        if let i = ledger.rules.firstIndex(where: { $0.id == id }) { ledger.rules[i].accepted = true }', '        if let i = ledger.rules.firstIndex(where: { $0.id == id }) { _ = i }', 'suggest accept'),
    ('reset: rules kept', '        ledger.rules = []; ledger.tombstones = []; ledger.seen = []', '        ledger.tombstones = []; ledger.seen = []', 'reset'),
    ('reset: pills forgotten', '        ledger.rules = []; ledger.tombstones = []; ledger.seen = []', '        ledger.announced = []; ledger.rules = []; ledger.tombstones = []; ledger.seen = []', 'pill once ever'),
    ('clear history: evidence kept', '        ledger.seen = []\n    }\n    /// The rule a pill names', '    }\n    /// The rule a pill names', 'clear history'),
    ('pill: every time', '        guard let id = newlyActive.first(where: { !ledger.announced.contains($0) }) else { return nil }', '        guard let id = newlyActive.first else { return nil }', 'pill once'),
    ('pill: not remembered', '        ledger.announced.append(id)\n', '', 'pill once'),
    ('record: any guard', '    static func guardCode(_ raw: String?) -> String? { raw.flatMap { guardCodes.contains($0) ? $0 : nil } }', '    static func guardCode(_ raw: String?) -> String? { raw }', 'record codes'),
    ('record: any hash', '    static func styleHash(_ raw: String?) -> String? { raw.flatMap { $0.range(of: "^[0-9a-f]{8}$", options: .regularExpression) != nil ? $0 : nil } }', '    static func styleHash(_ raw: String?) -> String? { raw }', 'record codes'),
    ('rule count: any hash', '        return ledger.applied.last { $0.hash == hash }?.ids.count ?? 0', '        return ledger.applied.last?.ids.count ?? 0', 'rule count'),
    ('kept: number unnamed', '        case "number": "a number"\n', '', 'card kept'),
    ('card: count hidden', '            guard styleRules > 0 else { return label }', '            guard styleRules > 100 else { return label }', 'card style rules'),
    ('editing: guard lost', 'fallbackReason: one.fallbackReason, heard: one.heard, polishModel: one.polishModel, polishPrompt: one.polishPrompt,\n                                                         polishGuard: one.polishGuard,', 'fallbackReason: one.fallbackReason, heard: one.heard, polishModel: one.polishModel, polishPrompt: one.polishPrompt,\n                                                         polishGuard: nil,', 'record guarding'),
    ('templates: avoid missing', ', DictationStyle.Key(kind: .contractions, param: "avoid")]', ']', 'copy templates'),
    ('copy: pending counts support', '"seen \\(rule.confirmations.count) of \\(DictationStyle.promoteAfter)"', '"seen \\(rule.support + 1) of \\(DictationStyle.promoteAfter)"', 'copy pending'),
    ('filter: switch ignored', '        guard settings.enabled else { return "off" }\n', '', 'filter switch'),
    ('filter: learn off counts', '        guard settings.learnMode != .off else { return "learnOff" }\n', '', 'filter learn mode'),
    ('filter: partial counts', '        guard evidence.complete else { return "partial" }\n', '', 'filter partial'),
    ('filter: unpolished counts', '        guard evidence.baselinePolished else { return "notPolished" }\n', '', 'filter polished'),
    ('filter: no input counts', '        guard evidence.inputEvents >= 1 else', '        guard evidence.inputEvents >= 0 else', 'filter input'),
    ('filter: reanchor counts', '        guard !evidence.startReanchor else { return "reanchor" }\n', '', 'filter reanchor'),
    ('filter: literal counts', '        if settings.registersEnabled, literal(app: evidence.app, registers: settings.registers) { return "literal" }\n', '', 'filter literal'),
    ('filter: literal while registers off', '        if settings.registersEnabled, literal(app: evidence.app', '        if literal(app: evidence.app', 'filter literal off'),
    ('filter: any language', '        guard mostlyEnglish(evidence.typed), mostlyEnglish(evidence.final) else { return "language" }\n', '', 'filter language'),
    ('literal: exact app name', '        let name = app.trimmingCharacters(in: .whitespaces).lowercased()\n', '        let name = app\n', 'filter literal'),
    ('english: two letters', '        guard letters.count >= 4 else { return false }', '        guard letters.count >= 1 else { return false }', 'mostly english'),
    ('english: any share', '        return Double(letters.filter(\\.isASCII).count) / Double(letters.count) >= 0.9', '        return Double(letters.filter(\\.isASCII).count) / Double(letters.count) >= 0.0', 'filter language'),
    ('learn: filters skipped', '        if let reason = excluded(evidence, settings) { return ([], reason) }\n', '', 'learn respects filters'),
    ('learn: suggest ignored', '                                           suggestOnly: settings.learnMode == .suggest, now: now)', '                                           suggestOnly: false, now: now)', 'learn suggest only'),
    ('normalize: case kept', '        let plain = word.lowercased().replacingOccurrences(', '        let plain = word.replacingOccurrences(', 'drop phrase'),
    ('normalize: punctuation kept', '        return plain.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols))', '        return plain', 'drop phrase'),
    ('normalize: curly apostrophe', '.replacingOccurrences(of: "\\u{2019}", with: "\'")', '', 'contractions apostrophe'),
    ('contractions: cannot missing', '"cannot": "can\'t", ', '', 'contractions use'),
    ('contractions: two-word forms missing', '            if i + 1 < words.count, let one = contractions[words[i] + " " + words[i + 1]] { out.append(one); i += 2; continue }\n', '', 'contractions use'),
    ('direction: never avoid', '        if contracted(added) == removed { return "avoid" }\n', '', 'contractions avoid'),
    ('direction: no change is a change', '        guard !removed.isEmpty, !added.isEmpty, removed != added else { return nil }', '        guard !removed.isEmpty, !added.isEmpty else { return nil }', 'contractions direction'),
    ('spliced: anything around it', '            if Array(longer[..<k]) == Array(shorter[..<k]), Array(longer[(k + phrase.count)...]) == Array(shorter[k...]) { return true }', '            if true { return true }', 'drop phrase only change'),
    ('edge: writing on counted', '        if let last = parts.last, last.kind != .same, let edge = regions.last, edge.addedWords > edge.removedWords { regions.removeLast() }\n', '', 'edge writing on'),
    ('edge: an even swap dropped', 'let edge = regions.last, edge.addedWords > edge.removedWords { regions.removeLast() }', 'let edge = regions.last, edge.addedWords >= edge.removedWords { regions.removeLast() }', 'edge contraction'),
    ('edge: not only at the end', '        if let last = parts.last, last.kind != .same, let edge = regions.last,', '        if let edge = regions.last,', 'drop phrase put back'),
    ('instructions: ignored', '                    if !DictationEditConfirm.holds(param, in: instructions) {', '                    if true {', 'drop phrase instructions'),
    ('put back: ignored', '                    drop = DictationStyle.Observation(key: DictationStyle.Key(kind: .dropPhrase, param: phrase.joined(separator: " ")), added: true)', '                    drop = nil', 'drop phrase put back'),
    ('push: register wrong', 'ServerRule(id: $0.id, kind: $0.kind.rawValue, register: "all", param: $0.param, count: $0.support,', 'ServerRule(id: $0.id, kind: $0.kind.rawValue, register: "literal", param: $0.param, count: $0.support,', 'sync codes only'),
    ('push: count zero', 'register: "all", param: $0.param, count: $0.support,', 'register: "all", param: $0.param, count: 0,', 'sync codes only'),
    ('merge: tombstone ignored', '            guard key.valid(allowlist: allowlist), !tombstoned(key.id, in: ledger, now: now), !ledger.rules.contains(where: { $0.key == key }) else { continue }', '            guard key.valid(allowlist: allowlist), !ledger.rules.contains(where: { $0.key == key }) else { continue }', 'tombstone merge'),
    ('merge: closed set ignored', '            guard key.valid(allowlist: allowlist), !tombstoned(key.id, in: ledger, now: now), !ledger', '            guard !tombstoned(key.id, in: ledger, now: now), !ledger', 'merge opposite'),
    ('merge: opposite joins', '            if let opposite = key.opposite, ledger.rules.contains(where: { $0.key == opposite }) { continue }\n', '', 'merge opposite'),
    ('merge: nothing joins', '            ledger.rules.append(Rule(kind: kind, param: rule.param, explicit: true, firstSeen: now, lastSeen: now))\n', '', 'sync 409 merge'),
    ('file: readable by others', '        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {\n            throw NSError(domain: "COSDictation", code: 4, userInfo: [NSLocalizedDescriptionKey: "Your style', '        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o644]) else {\n            throw NSError(domain: "COSDictation", code: 4, userInfo: [NSLocalizedDescriptionKey: "Your style', 'ledger private'),
    ('file: never renamed', '        guard rename(temp.path, url.path) == 0 else {\n            try? FileManager.default.removeItem(at: temp)\n            throw NSError(domain: "COSDictation", code: 4, userInfo: [NSLocalizedDescriptionKey: "Your style', '        guard true else {\n            try? FileManager.default.removeItem(at: temp)\n            throw NSError(domain: "COSDictation", code: 4, userInfo: [NSLocalizedDescriptionKey: "Your style', 'ledger round trip'),
    # 0.5.344 QA: replaced and new.
    ("state: an added rule waits", "        if rule.chosen { return .active }", "        if rule.accepted { return .active }", "add a rule"),
    ("rank: chosen not first", "        if a.chosen != b.chosen { return a.chosen }\n", "", "rank chosen first"),
    ("rank: least support first", "        if a.net != b.net { return a.net > b.net }", "        if a.net != b.net { return a.net < b.net }", "rank net support"),
    ("rank: last seen ignored", "        if a.lastSeen != b.lastSeen { return a.lastSeen > b.lastSeen }\n", "", "rank last seen"),
    ("rank: no cap", "        return Array(kept.sorted(by: precedes).prefix(maximumRules))", "        return kept.sorted(by: precedes)", "rank top 20"),
    ("rank: both contractions active", "        for loser in live.filter({ $0.kind == .contractions }).sorted(by: precedes).dropFirst() { ids.remove(loser.id) }\n", "",
     "rank one contractions"),
    ("rank: allowlist ignored", "active.contains(rule.id) && (allowlist.map { rule.key.valid(allowlist: $0) } ?? true) }", "active.contains(rule.id) && true }",
     "rank allowlist"),
    ("replaced reads active", "        return .replaced\n", "        return alone\n", "never both active"),
    ("add: opposite kept", "        if let opposite = key.opposite { remove(&ledger, opposite.id, now: now) }\n", "", "add replaces opposite"),
    ("add: only an added opposite goes", "        if let opposite = key.opposite { remove(&ledger, opposite.id, now: now) }\n",
     "        if let opposite = key.opposite { ledger.rules.removeAll { $0.key == opposite && $0.explicit } }\n", "add replaces opposite"),
    ("clear history: added rules go", "        ledger.rules = ledger.rules.filter(\\.chosen).map { rule in", "        ledger.rules = ledger.rules.filter { _ in false }.map { rule in",
     "clear history"),
    ("clear history: learned rules stay", "        ledger.rules = ledger.rules.filter(\\.chosen).map { rule in", "        ledger.rules = ledger.rules.filter { _ in true }.map { rule in",
     "clear history"),
    ("reset: switch back on", "        ledger.rules = []; ledger.tombstones = []; ledger.seen = []; ledger.applied = []\n",
     "        ledger.rules = []; ledger.tombstones = []; ledger.seen = []; ledger.applied = []; ledger.enabled = true\n", "reset"),
    ("pill: label capitalised", "        return pillPrefix + title.prefix(1).lowercased() + String(title.dropFirst())", "        return pillPrefix + title", "pill label"),
    ("display: lowercase i", '.map { $0 == "i" ? "I" : String($0) }', ".map { String($0) }", "key titles"),
    ("pill label: any flash", "    static func isPillLabel(_ label: String) -> Bool { label.hasPrefix(pillPrefix) }", "    static func isPillLabel(_ label: String) -> Bool { true }",
     "pill undo label"),
    ("kept: negation unnamed", '        case "negation": "a negation"\n', "", "card kept"),
    ("card: guard hidden", '        if let polishGuard { return DictationStyle.keptLine(guard: polishGuard == "guarded" ? nil : polishGuard) }\n', "", "card kept"),
    ("card: cleaned called polished", "        if polishCleaned != nil { return DictationPolish.cleanedLabel }\n", "", "card cleaned"),
    ("claude baseline: any polish", '    var polishedByClaude: Bool { heard != nil && polishModel != nil && polishGuard == nil && (polishCleaned == nil || polishCleaned == "unchanged") }',
     "    var polishedByClaude: Bool { heard != nil && polishModel != nil }", "card cleaned"),
    ("claude baseline: model's answer excluded", '(polishCleaned == nil || polishCleaned == "unchanged") }', "polishCleaned == nil }", "card cleaned"),
    ("guarding: kind lost", 'polishGuard: kind ?? "guarded", polishStyleHash: styleHash ?? r.polishStyleHash, polishCleaned: r.polishCleaned,',
     'polishGuard: "guarded", polishStyleHash: styleHash ?? r.polishStyleHash, polishCleaned: r.polishCleaned,', "record guarding"),
    ("polishing: guard lost on cleaned text", "polishGuard: cleaned == nil ? nil : r.polishGuard,", "polishGuard: nil,", "card cleaned"),
    ("polishing: prompt kept on cleaned text", "polishPrompt: cleaned == nil ? DictationPolish.promptVersion(prompt) : nil,", "polishPrompt: DictationPolish.promptVersion(prompt),",
     "card cleaned"),
    ("record: cleaned not kept", "        self.polishCleaned = DictationPolish.cleanedCode(polishCleaned)\n", "        self.polishCleaned = nil\n", "card cleaned"),
    ("record: cleaned not saved", "        try c.encodeIfPresent(polishCleaned, forKey: .polishCleaned)\n", "", "record cleaned"),
    ("cleaned: any code", 'raw.flatMap { $0 == "unchanged" || $0 == "guarded" || skipReasons.contains($0) ? $0 : nil }', "raw", "record cleaned"),
    ("swap: cleaned never swaps", "        case .fillersOnly(_, let text)?: text\n", "", "swap cleaned parity"),
    ("cleaned: never named", "        guard case .fillersOnly(let code, _)? = outcome else { return nil }\n        return cleanedCode(code)", "        return nil", "swap cleaned parity"),
    ("status: shortcut line missing", "        return enabled && notUsed == nil && !monitor ? [needsShortcut] : []", "        return []", "copy status"),
    ("status: learn off silent", "        if learnMode == .off { return [needsLearn] }\n", "", "copy status"),
    ("status: shortcut line where not used", "        return enabled && notUsed == nil && !monitor ? [needsShortcut] : []",
     "        return enabled && !monitor ? [needsShortcut] : []", "copy status"),
    ("heading: paused reads active", "        if !enabled { return (pausedHeading, paused) }\n", "", "copy headings"),
    ("heading: not used reads active", "        if let notUsed { return (notUsedHeading, notUsedLine(notUsed)) }\n", "", "copy headings"),
    ("detail: added says seen", '        return rule.confirmations.isEmpty ? "added" : "added, seen \\(rule.confirmations.count)"', '        return "seen \\(rule.support)"',
     "copy detail"),
    ("copy: pending says seen once", '    static let pending = "Not active yet"', '    static let pending = "Seen once"', "copy pending"),
    ("copy: G2 always", '"Your COS server adds your style rules (never your text) to each Sonnet polish, on the glasses too when it polishes with Sonnet."',
     '"Your COS server adds your style rules (never your text) to each Sonnet polish, on the glasses too."', "copy disclosure"),
    ("copy: an em dash", '    static let paused = "Learning is off, so these rules are not used here or on the glasses."',
     '    static let paused = "Learning is off — these rules are not used here or on the glasses."', "copy plain"),
    ("not used: polish off", "        guard model != .off else { return .polishOff }\n", "", "not used"),
    ("not used: Haiku", "        guard model == .sonnet else { return .notSonnet }\n", "", "not used"),
    ("not used: never read", "        guard checked else { return .unreachable }\n", "", "not used"),
    ("not used: older server", "        guard available else { return .oldServer }\n", "", "not used"),
    ("not used: server switch", "        guard serverEnabled else { return .serverOff }\n", "", "not used"),
    ("not used: previous polish", '        if let sonnetPrompt, sonnetPrompt != "v4" { return envOverride ? .serverPrompt : .previousPolish }\n', "", "not used"),
    ("not used: environment named previous", "envOverride ? .serverPrompt : .previousPolish }", ".previousPolish }", "not used"),
    ("filter: not used counts", "        if let notUsed = settings.notUsed { return notUsed.rawValue }\n", "", "filter not used"),
    ("controller: learning ungated", "learnMode: learnMode, notUsed: notUsed(model: model), registers: registers,", "learnMode: learnMode, notUsed: nil, registers: registers,",
     "gate learning"),
    ("controller: pill ungated", "        guard notUsed(model: model) == nil, let key = key(id),", "        guard let key = key(id),", "gate pill"),
    ("sync: stale ledger written back", "            let reply = await transport?(.put(rules: rulesDiffer ? desired : nil, enabled: switchDiffers || !rulesDiffer ? enabled : nil, baseRevision: current.revision))\n",
     "            let stale = ledger\n            let reply = await transport?(.put(rules: rulesDiffer ? desired : nil, enabled: switchDiffers || !rulesDiffer ? enabled : nil, baseRevision: current.revision))\n            ledger = stale\n",
     "race remove during put"),
    ("sync: no rerun", "        repeat { rerun = false; await syncOnce() } while rerun", "        rerun = false; await syncOnce()", "race remove during put"),
    ("sync: overlapping syncs", "        if syncing { rerun = true; return }\n", "", "race remove during put"),
    ("sync: base never the revision", "baseRevision: current.revision))", "baseRevision: nil))", "sync base"),
    ("sync: the switch carries the rules", "put(rules: rulesDiffer ? desired : nil, enabled: switchDiffers || !rulesDiffer ? enabled : nil", "put(rules: desired, enabled: enabled",
     "switch sends only enabled"),
    ("sync: switch ignored", "switchDiffers = DictationStyle.switchDiffers(enabled, server: current)", "switchDiffers = false", "switch sends only enabled"),
    ("sync: always push", "            guard rulesDiffer || switchDiffers else {", "            guard true else {", "sync unchanged"),
    ("sync: 409 not merged", "                DictationStyle.merge(&ledger, server: state.rules ?? [], allowlist: allowlist, now: now()); save()\n", "", "sync 409 merge"),
    ("sync: 409 loops", "                guard !merged, let fresh = await transport?(.get)", "                guard let fresh = await transport?(.get)", "sync 409 once"),
    ("sync: stale base after 409", "                current = state\n", "", "sync 409 merge"),
    ("sync: 413 gives up", "                dropped += 1\n            case 404?:", '                message = DictationStyleCopy.notSaved("too_long"); changed(); return\n            case 404?:',
     "sync 413 drop"),
    ("sync: 413 drops the best", ".prefix(limit)).dropLast(dropped).map { $0 })", ".prefix(limit)).dropFirst(dropped).map { $0 })", "sync 413 drop"),
    ("sync: server cap ignored", "            let limit = min(current.maxRules ?? DictationStyle.maximumRules, DictationStyle.maximumRules)",
     "            let limit = DictationStyle.maximumRules", "sync server cap"),
    ("sync: rules under the hash forgotten", "                DictationStyle.remember(&ledger, hash: state.hash, ids: (state.rules ?? desired).map(\\.id)); save()", "                save()",
     "sync remembers"),
    ("sync: unchanged learns no hash", "                DictationStyle.remember(&ledger, hash: current.hash, ids: (current.rules ?? []).map(\\.id)); save()\n                if !merged",
     "                save()\n                if !merged", "sync unchanged remembers"),
    ("sync: success keeps the message", "                message = dropped > 0 ? DictationStyleCopy.dropped(dropped) : nil; changed()",
     "                message = dropped > 0 ? DictationStyleCopy.dropped(dropped) : message; changed()", "sync failure message"),
    ("sync: failure silent", '                message = DictationStyleCopy.notSaved(why); changed(); log?("style sync failed reason=\\(why)"); return',
     "                changed(); return", "sync failure message"),
    ("sync: a 404 is ok", "                available = false; server = nil\n", "", "sync rollback 404"),
    ("sync: unreachable not marked", '                unreachable = why == "unreachable"\n                message = DictationStyleCopy.notSaved(why)', "                message = DictationStyleCopy.notSaved(why)",
     "pending off"),
    ("take: older server available", "        available = state.available != false\n", "        available = true\n", "older server local"),
    ("take: registers from the map", "        registersEnabled = state.registersEnabled ?? false\n", "        registersEnabled = !(state.registers ?? [:]).isEmpty\n", "registers flag only"),
    ("adopt: never", "        adopting = loaded != .read\n", "        adopting = false\n", "adopt after a failed load"),
    ("adopt: switch not taken", "            ledger.enabled = current.enabled ?? ledger.enabled\n", "", "adopt after a failed load"),
    ("adopt: rules not taken", "            DictationStyle.merge(&ledger, server: current.rules ?? [], allowlist: allowlist, now: now())\n            ledger.enabled",
     "            ledger.enabled", "adopt after a failed load"),
    ("read only: written over", "        guard !readOnly else { return }\n", "", "read only ledger"),
    ("read only: never", "        if case .corrupt(nil) = loaded { readOnly = true } else { readOnly = false }", "        readOnly = false", "read only ledger"),
    ("reset: failure claims done", "        if let failure { message = DictationStyleCopy.resetNotSaved(failure) } else if message == nil { message = DictationStyleCopy.resetDone }",
     "        message = DictationStyleCopy.resetDone", "reset failure"),
    ("ledger: strict rules", "        rules = (try? c.decodeIfPresent([DictationStyle.Lossy<DictationStyle.Rule>].self, forKey: .rules))??.compactMap(\\.value) ?? []",
     "        rules = (try? c.decodeIfPresent([DictationStyle.Rule].self, forKey: .rules)) ?? nil ?? []", "ledger lossy"),
    ("ledger: a rule needs its dates", "        lastSeen = (try? c.decodeIfPresent(Date.self, forKey: .lastSeen)) ?? Date(timeIntervalSince1970: 0)",
     "        lastSeen = try c.decode(Date.self, forKey: .lastSeen)", "ledger lossy"),
    ("ledger: corrupt overwritten", "        guard rename(url.path, aside.path) == 0 else { return (Ledger(), .corrupt(movedTo: nil)) }",
     "        guard false else { return (Ledger(), .corrupt(movedTo: nil)) }", "ledger corrupt"),
    ("ledger: missing reads as read", "        guard FileManager.default.fileExists(atPath: url.path) else { return (Ledger(), .missing) }",
     "        guard FileManager.default.fileExists(atPath: url.path) else { return (Ledger(), .read) }", "ledger missing"),
]

CHECK_FAILURE = re.compile(r"VoiceStyleChecks\.swift:\d+: Fatal error: check failed \[([^\]]+)\]")


def failed_check(output: str) -> "str | None":
    found = CHECK_FAILURE.search(output)
    return found.group(1).strip() if found else None


def classifier_self_test() -> None:
    cases = [
        ("/w/Tests/VoiceStyleChecks.swift:17: Fatal error: check failed [pill once] at line 45: x", "pill once"),
        ("VoiceStyleChecks.swift:17: Fatal error: check failed [sync 409 merge] at line 9: ", "sync 409 merge"),
        ("checks/MacDictationCore.swift:88: Fatal error: a trap in the core", None),
    ]
    for text, want in cases:
        if failed_check(text) != want:
            sys.exit(f"classifier self-test failed: {text!r} read as {failed_check(text)!r}, expected {want!r}")
    print(f"classifier self-test: {len(cases)} cases")


def compile_once(work: pathlib.Path) -> tuple[bool, str, str]:
    out = work / "checks"
    if out.exists():
        out.unlink()
    build = subprocess.run(["/usr/bin/python3", str(root / "Tests/kit-compile.py"), "/bin/zsh", str(root / "Tests/compile-guard.sh"), "swiftc",
                            "-target", "arm64-apple-macosx14.0", "-swift-version", "6", "-strict-concurrency=complete", "-parse-as-library",
                            str(work / CORE), str(work / CHECKS), "-o", str(out)], capture_output=True, text=True)
    output = build.stderr + build.stdout
    lines = output.splitlines()
    first_error = next((line for line in lines if "error:" in line), "")
    if build.returncode != 0 and not first_error:
        first_error = next((line for line in reversed(lines) if line.strip()), f"exit {build.returncode}")
    return build.returncode == 0, first_error.strip(), output


def compile_checks(work: pathlib.Path) -> tuple[bool, str]:
    for attempt in range(4):
        built, error, output = compile_once(work)
        if built or "shared compile lock busy" not in output:
            return built, error
        print(f"  compile lock busy, attempt {attempt + 1} of 4", flush=True)
    return built, error


def classify(work: pathlib.Path, expected: "str | None") -> tuple[str, str]:
    built, error = compile_checks(work)
    if not built:
        return "INVALID", "did not compile: " + error
    try:
        run = subprocess.run([str(work / "checks")], capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired:
        return "INVALID", "timed out"
    if run.returncode == 0:
        return "SURVIVED", ""
    message = failed_check(run.stderr + run.stdout)
    if message is None:
        tail = (run.stderr + run.stdout).strip().splitlines()
        return "CRASHED", tail[-1] if tail else f"exit {run.returncode}"
    if expected is not None and message != expected:
        return "MISATTRIBUTED", f"[{message}] failed first, expected [{expected}]"
    return "KILLED", message


classifier_self_test()
work = pathlib.Path(tempfile.mkdtemp(prefix="cos-voice-style-mutants-", dir="/private/tmp"))
os.environ.setdefault("COS_TEST_KIT_DIR", str(work / ".kits"))
try:
    (work / "Sources").mkdir(); (work / "Tests").mkdir()
    shutil.copy(root / CORE, work / CORE)
    shutil.copy(root / CHECKS, work / CHECKS)
    original = (work / CORE).read_text()
    for name, old, _, _ in MUTANTS:
        if original.count(old) != 1:
            sys.exit(f"mutant '{name}' targets {original.count(old)} sites; it must land exactly once")
    verdict, detail = classify(work, None)
    if verdict != "SURVIVED":
        sys.exit(f"baseline is not green ({verdict}: {detail}): fix the checks before reading any mutant")
    print("baseline green", flush=True)
    selected = [m for m in MUTANTS if any(m[0].startswith(prefix) for prefix in only.split("|"))]
    if not selected:
        sys.exit(f"no mutant name starts with {only!r}")
    results: dict[str, list[str]] = {"KILLED": [], "SURVIVED": [], "MISATTRIBUTED": [], "INVALID": [], "CRASHED": []}
    for name, old, new, expected in selected:
        (work / CORE).write_text(original.replace(old, new))
        verdict, detail = classify(work, expected)
        results[verdict].append(name)
        print(f"{verdict:13} {name}" + (f"  <- {detail}" if detail else ""), flush=True)
        (work / CORE).write_text(original)
    print(f"{len(results['KILLED'])} killed by their named check, {len(results['SURVIVED'])} survived, {len(results['MISATTRIBUTED'])} misattributed, "
          f"{len(results['INVALID'])} invalid, {len(results['CRASHED'])} crashed outside the checks")
    failing = {k: v for k, v in results.items() if k != "KILLED" and v}
    if failing:
        sys.exit("mutation gate FAILED: " + "; ".join(f"{k.lower()}: {v}" for k, v in failing.items()))
    print(f"PASS voice style mutation gate: {len(selected)} mutants" + (f" (of {len(MUTANTS)}, named {only!r})" if only else "")
          + ", each killed by its named check, green baseline")
finally:
    shutil.rmtree(work, ignore_errors=True)
