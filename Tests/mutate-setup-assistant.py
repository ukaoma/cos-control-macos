#!/usr/bin/env python3
"""Ask COS setup assistant mutation lane. Run by hand, never by a gate.

    python3 Tests/mutate-setup-assistant.py <worktree> <scratch dir> [name ...]
    python3 Tests/mutate-setup-assistant.py <worktree> <scratch dir> --center     the command center's mutants, most dangerous first
    COS_MUTATE_MINUTES=25 ...                                                     stop starting mutants after this long, baseline included

Copies the worktree to <scratch dir>/copy, proves the UNMUTATED lane green first (Tests/run-setup-assistant.sh: the pins,
then the compiled checks), then applies one mutant at a time: the target must appear exactly once, the mutant must make
the lane fail, and the failure must name the behaviour it breaks. The copy is restored and compared byte for byte after
every mutant. A mutant that lands and survives is a finding. One lane run at a time; every compile goes through the guard,
and a run that hangs is killed after LIMIT seconds (Tests/mutate_bounded.py) and counted as a kill by timeout.
"""
import filecmp, os, pathlib, shutil, sys, time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import mutate_bounded as bounded

LIMIT = 900
C = "Sources/SetupAssistant.swift"
W = "Sources/ActivityWindow.swift"
HP = "HelperSources/main.swift"
R = "scripts/build-release.sh"
S = "Tests/run.sh"
MUTANTS = [
    # Gates
    ("gate: a change that does not apply is offered", C, "        guard applies(action, s) else { return .notApplicable }\n", "", "[unverified ownership]"),
    ("gate: busy ignored", C, "        if s.helperBusy, action.helperCommand != nil || action == .retryAppUpdate { return .held(Held.busy) }\n", "", "[busy]"),
    ("gate: an ownership conflict ignored", C, "        if action.touchesServer, s.ownerConflict { return .held(Held.ownerConflict) }\n", "", "[ownership conflict offers nothing]"),
    ("gate: a G2 recording ignored", C, "if s.activeTranscriptionSessions > 0 || s.macRecordingActive { return .held(Held.recording) }",
     "if s.macRecordingActive { return .held(Held.recording) }", "[no restart while a recording runs]"),
    ("gate: a Mac recording ignored", C, "if s.activeTranscriptionSessions > 0 || s.macRecordingActive { return .held(Held.recording) }",
     "if s.activeTranscriptionSessions > 0 { return .held(Held.recording) }", "[a Mac recording holds]"),
    ("gate: a meeting still saving ignored", C, "            if s.meetingWorkBlockingRestart { return .held(s.meetingSyncUnconfirmed ? Held.unconfirmed : Held.saving) }\n", "", "[a meeting still saving holds]"),
    ("gate: a silent server reads as saving", C, "return .held(s.meetingSyncUnconfirmed ? Held.unconfirmed : Held.saving)", "return .held(Held.saving)", "[a server that does not answer holds in its own words]"),
    ("gate: running jobs ignored", C, "            if s.activeJobs > 0 { return .held(Held.jobs(s.activeJobs)) }\n", "", "[no restart while a job runs]"),
    ("gate: Restart ignores an interrupted update", C, "        case .restartServer:\n            if s.transactionPending { return .held(Held.interruptedUpdate) }\n",
     "        case .restartServer:\n", "[interrupted update]"),
    ("gate: Update Server ignores an interrupted update", C,
     "            // install() refuses while a transaction is pending (\"A previous update needs repair before another install\").\n            if s.transactionPending { return .held(Held.interruptedUpdate) }\n",
     "            break\n", "[interrupted update]"),
    ("gate: an in-place restart with one tap", C, '            if s.runtimeState == "managedInPlace", !s.safeToRestart { return .held(Held.unprovenIdle) }\n', "", "[in-place restart asks first]"),
    ("gate: the app update twice", C, "            if s.appUpdate.installing { return .held(Held.installing) }\n", "", "[installing]"),
    ("gate: the app update closes a recording", C, "            if s.macRecordingActive || s.activeTranscriptionSessions > 0 { return .held(Held.recording) }\n", "", "[the update waits for a recording]"),
    ("gate: Repair Whisper is not a restart", C, "            case .restartServer, .repairRuntime, .repairWhisper, .updateServer: return true",
     "            case .restartServer, .repairRuntime, .updateServer: return true", "[no restart while a job runs]"),
    # What applies
    ("applies: setup without an AI app", C, "            return s.needsFirstRun && s.setupProviderInstalled\n", "            return s.needsFirstRun\n", "[first run]"),
    ("applies: Start for a running server", C, '            return s.runtimeState == "stopped"\n', "            return true\n", "[server down: local repairs]"),
    ("applies: Restart for a stopped server", C, '            return s.runtimeState == "managedHealthy" || s.runtimeState == "managedInPlace"\n', "            return true\n",
     "[server down: local repairs]"),
    ("applies: Repair against a Terminal server", C, '            guard s.installed, s.runtimeState != "legacyForeground" else { return false }\n',
     "            guard s.installed else { return false }\n", "[repair only when it fixes something]"),
    ("applies: Repair whenever installed", C, "            return s.transactionPending || failing(CheckName.updateRecovery, s) || failing(CheckName.recovery, s)\n",
     "            return true || failing(CheckName.recovery, s)\n", "[repair only when it fixes something]"),
    ("applies: Repair Whisper while Whisper is fine", C,
     "            return s.serverReachable && s.managedContract && s.ownershipVerified && (!s.whisperReady || s.whisperCircuitOpen)\n",
     "            return s.serverReachable && s.managedContract && s.ownershipVerified\n", "[answers offer only what applies]"),
    ("applies: Repair Whisper on an unverified server", C,
     "            return s.serverReachable && s.managedContract && s.ownershipVerified && (!s.whisperReady || s.whisperCircuitOpen)\n",
     "            return s.serverReachable && (!s.whisperReady || s.whisperCircuitOpen)\n", "[unverified ownership]"),
    ("applies: Update Server on an unverified server", C, "            return s.installed && s.managedContract && s.ownershipVerified\n",
     "            return s.installed\n", "[unverified ownership]"),
    ("applies: troubleshoot with the server down", C, "            return s.serverReachable && s.workRunsOn\n", "            return s.workRunsOn\n", "[troubleshoot needs the server]"),
    ("applies: troubleshoot with Work runs off", C, "            return s.serverReachable && s.workRunsOn\n", "            return s.serverReachable\n", "[troubleshoot needs Work runs]"),
    ("applies: an app update with none offered", C, "            return s.appUpdate.available || s.appUpdate.downloadFailed\n", "            return true\n", "[installing]"),
    # The board
    ("board: the conflict offers more", C, "        if s.ownerConflict {\n            let only", "        if false {\n            let only", "[ownership conflict offers nothing]"),
    ("board: a server row on first run", C, "        if !s.serverReachable && !s.needsFirstRun {\n            switch s.runtimeState {\n", "        if !s.serverReachable {\n            switch s.runtimeState {\n", "[first run]"),
    ("board: a stopped server is repaired", C, '"It is not running, so Work, meetings and the glasses cannot reach it.", .startServer)',
     '"It is not running, so Work, meetings and the glasses cannot reach it.", .repairRuntime)', "[ranking]"),
    ("board: a Terminal server is updated", C, '"Finish active work, then stop it in Terminal with Control-C. COS Control can then run the server for you.", nil)',
     '"Finish active work, then stop it in Terminal with Control-C. COS Control can then run the server for you.", .updateServer)', "[server down: local repairs]"),
    ("board: a running self-managed server is not offered", C, '        if s.runtimeState == "legacyService" {\n', "        if false {\n", "[a server you run yourself]"),
    ("board: a stopped self-managed server is not offered", C, 'Adopt Safely in Settings installs the managed server.", .openSettings)', 'Adopt Safely in Settings installs the managed server.", nil)', "[a server you run yourself]"),
    ("board: a degraded server is not repaired", C, "                if s.installed {\n", "                if false {\n", "[interrupted update]"),
    ("board: a failed download offered twice", C, "        if s.appUpdate.available && !s.appUpdate.downloadFailed && !s.appUpdate.installing {\n",
     "        if s.appUpdate.available && !s.appUpdate.installing {\n", "[the anchor case]"),
    ("board: no Try again beside the steps", C, "                .openUnstuck, secondary: .retryAppUpdate)\n", "                .openUnstuck)\n", "[the anchor case]"),
    ("board: the second button skips its gate", C, "            if let secondary, gate(secondary, s) == .ready { item.secondary = secondary }\n",
     "            if let secondary { item.secondary = secondary }\n", "[the update waits for a recording]"),
    ("board: a held change still offered", C, "                case .held(let reason): item.held = reason\n",
     "                case .held(let reason): item.held = reason; item.action = action\n", "[no restart while a job runs]"),
    ("board: a held change says nothing", C, "                case .held(let reason): item.held = reason\n", "                case .held: break\n", "[no restart while a job runs]"),
    ("board: Whisper only from Doctor", C,
     "        if (s.serverReachable && s.managedContract && s.ownershipVerified && (!s.whisperReady || s.whisperCircuitOpen)) || failing(CheckName.whisperServer, s) {\n",
     "        if failing(CheckName.whisperServer, s) {\n", "[whisper]"),
    ("board: an interrupted update is not first", C, '        add("interrupted-update", .repair, 10,', '        add("interrupted-update", .repair, 99,', "[interrupted update]"),
    ("board: the microphone with dictation off", C, "        if s.dictationEnabled && s.microphoneAllowed == false {\n", "        if s.microphoneAllowed == false {\n", "[dictation permissions]"),
    ("board: an unread microphone is a problem", C, "        if s.dictationEnabled && s.microphoneAllowed == false {\n", "        if s.dictationEnabled && s.microphoneAllowed != true {\n",
     "[dictation permissions]"),
    ("board: unread Accessibility is a problem", C, "        if s.dictationEnabled && s.accessibilityTrusted == false {\n", "        if s.dictationEnabled && s.accessibilityTrusted != true {\n",
     "[dictation permissions]"),
    ("board: integrity offers Repair", C, '"Doctor says the installed server failed its integrity check. Update Server installs a fresh, verified copy.", .updateServer)',
     '"Doctor says the installed server failed its integrity check. Update Server installs a fresh, verified copy.", .repairRuntime)', "[doctor rows]"),
    ("board: done rows offered", C, "where !item.done && !item.skipped && !item.afterSetup && !item.awaitsServer {", "where !item.skipped && !item.afterSetup && !item.awaitsServer {", "[all clear]"),
    ("board: skipped rows offered", C, "where !item.done && !item.skipped && !item.afterSetup && !item.awaitsServer {", "where !item.done && !item.afterSetup && !item.awaitsServer {", "[setup rows]"),
    ("board: rows before setup offered", C, "where !item.done && !item.skipped && !item.afterSetup && !item.awaitsServer {", "where !item.done && !item.skipped && !item.awaitsServer {", "[setup rows]"),
    ("board: rows still checking offered", C, "where !item.done && !item.skipped && !item.afterSetup && !item.awaitsServer {", "where !item.done && !item.skipped && !item.afterSetup {", "[setup rows]"),
    ("board: optional rows counted as setup", C, "item.counted ? .setup : .extra", ".setup", "[all clear]"),
    ("board: a checkup after Doctor", C, "        if s.checks.isEmpty && !s.needsFirstRun {\n", "        if !s.needsFirstRun {\n", "[all clear]"),
    ("board: a checkup on first run", C, "        if s.checks.isEmpty && !s.needsFirstRun {\n", "        if s.checks.isEmpty {\n", "[first run]"),
    ("board: five shown", C, "    static let shown = 4\n", "    static let shown = 5\n", "[ranking]"),
    ("board: more never counted", C, "more: max(0, ranked.count - shown))", "more: 0)", "[at most four]"),
    ("board: an extra breaks all clear", C, "        let clear = !ranked.contains { $0.tier != .extra }\n", "        let clear = ranked.isEmpty\n", "[checkup offered before Doctor]"),
    ("board: ranked backwards", C, "found.sorted { ($0.tier, $0.rank) < ($1.tier, $1.rank) }", "found.sorted { ($0.tier, $0.rank) > ($1.tier, $1.rank) }", "[ranking]"),
    # The knowledge base
    ("match: phrases ignored", C, "            if entry.phrases.contains(where: has) {\n", "            if false {\n", "[the anchor case]"),
    # Killed first by the server-down answer: "server not connected" is taken for the glasses entry.
    ("match: one group is enough", C, "entry.groups.allSatisfy({ $0.contains(where: has) })", "entry.groups.contains(where: { $0.contains(where: has) })", "[server down: local repairs]"),
    ("match: phrases of whisper ignored", C, 'phrases: ["restart whisper", "repair whisper"],', "phrases: [],", "[knowledge base: whisper-stalled]"),
    ("answer: Restart offered for a stopped server", C, "              actions: [.restartServer],\n", "              actions: [.restartServer, .startServer],\n", "[answers offer only what applies]"),
    ("match: the first entry wins", C, "            if score > (best?.score ?? 0) { best = (entry, score) }\n", "            if best == nil { best = (entry, score) }\n", "[knowledge base"),
    ("match: boosts ignored", C, "            score += entry.boosts.filter(has).count\n", "", "[knowledge base"),
    ("match: part of a word matches", C, "        func has(_ term: String) -> Bool { words.contains(normalized(term)) }\n",
     "        func has(_ term: String) -> Bool { words.contains(term) }\n", "[knowledge base"),
    ("match: apostrophes kept", C, "            if scalar == \"'\" || scalar == \"\\u{2019}\" { continue }\n", "", "[knowledge base"),
    ("match: the whole question read", C, "        let words = normalized(String(text.prefix(maxQuestion)))\n", "        let words = normalized(text)\n", "[knowledge base reads a bounded question]"),
    ("answer: three offers", C, "        for action in entry.actions where offers.count < 2 {\n", "        for action in entry.actions where offers.count < 3 {\n", "[an answer offers two at most]"),
    ("answer: a change that does not apply is offered", C, "            case .notApplicable: continue\n",
     "            case .notApplicable: offers.append(Offer(action: action, title: action.title, held: nil))\n", "[ownership conflict offers nothing]"),
    ("answer: a held change offered as ready", C, "            case .held(let reason): offers.append(Offer(action: action, title: action.title, held: reason))\n",
     "            case .held: offers.append(Offer(action: action, title: action.title, held: nil))\n", "[ownership conflict offers nothing]"),
    ("answer: the hold not named", C, '        if entry.namesRestartHold, case .held(let reason) = gate(.restartServer, s) { text += " Right now: " + reason }\n', "",
     "[the greyed-out answer names the hold]"),
    # Confirmations
    ("confirm: Repair Whisper hides the restart", C, '"This restarts the whole COS server, then waits for Whisper to answer."', '"COS restarts local Whisper."',
     "[Repair Whisper says it restarts the server]"),
    ("confirm: Reset and add again is not a change", C, "                 .retryAppUpdate, .resetAccessibility, .troubleshoot: return true", "                 .retryAppUpdate, .troubleshoot: return true",
     "[every change confirms]"),
    ("confirm: a pending update reads as a plain repair", C, "            if s.transactionPending {\n                return Confirmation(question: \"Finish the interrupted server update?\",",
     "            if false {\n                return Confirmation(question: \"Finish the interrupted server update?\",", "[repair says what it does]"),
    ("confirm: a stopped server is restarted", C, "            if s.desiredState == \"stopped\" {\n", "            if false {\n", "[repair says what it does]"),
    ("confirm: the cap misquoted", C, "    static let dailyRuns = 20\n", "    static let dailyRuns = 25\n", "dailyRuns equals"),
    # Troubleshoot
    ("troubleshoot: no gate", C, "        guard gate(.troubleshoot, s) == .ready else { return nil }\n", "", "[troubleshoot needs the server]"),
    ("troubleshoot: no ask-first rule", C, "    - Ask before you run anything that changes this Mac: installs, restarts, deleting files, System Settings.\n", "", "[troubleshoot asks first]"),
    ("troubleshoot: the packet not redacted", C, "report.map { scrubbed(String($0.prefix(maxPacket))) }", "report.map { String($0.prefix(maxPacket)) }", "[troubleshoot redacts]"),
    ("troubleshoot: the packet unbounded", C, "report.map { scrubbed(String($0.prefix(maxPacket))) }", "report.map { scrubbed($0) }", "[troubleshoot is bounded]"),
    ("troubleshoot: the question unbounded", C, "        let words = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuestion))\n",
     "        let words = question.trimmingCharacters(in: .whitespacesAndNewlines)\n", "[troubleshoot is bounded]"),
    ("troubleshoot: outside Today's in-flight check", C, '    static let targetPrefix = "today:troubleshoot:"\n', '    static let targetPrefix = "setup:troubleshoot:"\n', "[troubleshoot prompt]"),
    # Copy
    ("copy: an em dash in a held line", C, '"A meeting is still saving. This comes back when it is done."', '"A meeting is still saving \u2014 this comes back when it is done."', "[copy rules]"),
    ("copy: a hedge word in an answer", C, '"Repair Whisper restarts the COS server and local Whisper together,', '"Repair Whisper might restart the COS server and local Whisper together,', "[copy rules]"),
    # The command center: auto-highlight
    ("center: Stop highlights itself", C, "                case .stopRecording, .runDoctor: return false\n", "                case .runDoctor: return false\n", "[auto-highlight never Stop]"),
    ("center: Doctor highlights itself", C, "                case .stopRecording, .runDoctor: return false\n", "                case .stopRecording: return false\n", "[auto-highlight never Doctor]"),
    ("center: part of a phrase highlights", C, "if rank == 0, command.autoHighlights, row.selectable, result.autoHighlight == nil", "if command.autoHighlights, row.selectable, result.autoHighlight == nil",
     "[longer text never auto-highlights]"),
    ("center: a held row highlights", C, "if rank == 0, command.autoHighlights, row.selectable, result.autoHighlight == nil", "if rank == 0, command.autoHighlights, result.autoHighlight == nil",
     "[a held row never highlights]"),
    ("center: an exact command still shows the answer", C, "            let saved = result.autoHighlight == nil ? answer(words, s) : nil\n", "            let saved = answer(words, s)\n", "[an exact command skips the answer]"),
    # The command center: the closed list
    ("center: a command's title changes", C, '                case .openSessions: return "Open Sessions"\n', '                case .openSessions: return "Sessions"\n', "[command list]"),
    ("center: a phrase is not exact", C, "            if phrases.contains(typed) { return words.contains(\"?\") ? 2 : 0 }\n", "", "[a command's phrase is exact]"),
    # The command center: Return
    ("center: a saved answer starts a run", C, "            let cautious = listing.hasAnswer || listing.nearCommand\n", "            let cautious = listing.nearCommand\n", "[Start Work off: an answer moves to File]"),
    ("center: a near-command starts a run", C, "            let cautious = listing.hasAnswer || listing.nearCommand\n", "            let cautious = listing.hasAnswer\n", "[Start Work off: a near-command moves to File]"),
    ("center: Option-Return stops filing", C, "            if option { return listing.words.isEmpty ? .nothing : .file }\n", "", "[Option-Return always files]"),
    ("center: Option-Return files nothing", C, "            if option { return listing.words.isEmpty ? .nothing : .file }\n", "            if option { return .file }\n", "[Option-Return with no words]"),
    ("center: Return ignores the highlight", C, "            if let id = effective(chosen, listing) { return .activate(id) }\n", "", "[Return runs the highlight]"),
    ("center: Return ignores the confirm", C, "            if confirming { return .confirm }\n", "", "[Return confirms]"),
    ("center: Return accepts the notice", C, "            if noticeShowing { return .nothing }\n", "", "[Return never accepts the notice]"),
    ("center: Start Work off stops filing", C, "            if !s.workRunsOn, !cautious { return .file }\n", "", "[Start Work off files]"),
    ("center: Return runs a held Ask", C, "            let askable = listing.rows.first { $0.kind == .ask && $0.selectable }\n", "            let askable = listing.rows.first { $0.kind == .ask }\n", "[Start Work off: an answer moves to File]"),
    ("center: a stale highlight still runs", C, "            if let chosen, listing.rows.contains(where: { $0.id == chosen && $0.selectable }) { return chosen }\n", "            if let chosen { return chosen }\n",
     "[a stale highlight is none]"),
    ("center: near-command at any length", C, "            if parts.count <= 4, parts.contains(where: commandWords.contains) { return true }\n", "            if parts.contains(where: commandWords.contains) { return true }\n", "[a long sentence is a run]"),
    ("center: a phrase in a sentence is no near-command", C, "            return Command.allCases.contains { $0.phrases.contains { $0.contains(\" \") && padded.contains(\" \" + plain($0) + \" \") } }\n", "            return false\n",
     "[a near-command moves to Ask]"),
    ("center: the hint lies", C, 'tail: ". Return again " + (confirmation(row, s) != nil ? "asks first." : "runs it.")', 'tail: ". Return runs it."', "[the hint says what Return does]"),
    # The command center: keys
    ("center: Down wraps", C, "            return next < 0 ? nil : ids[min(next, ids.count - 1)]\n", "            return ids[(next + ids.count) % ids.count]\n", "[Up from the first clears]"),
    ("center: Esc closes at once", C, "            return hasWords ? .clearWords : .close\n", "            return .close\n", "[Esc clears, then closes]"),
    ("center: Esc leaves a confirm open", C, "            if confirming { return .cancelConfirm }\n", "", "[Esc order]"),
    ("center: keys stop on words", C, "                case .savedAnswer, .info: return false\n                default: return held == nil\n", "                default: return held == nil\n", "[keys skip words]"),
    ("center: keys stop on a held row", C, "                case .savedAnswer, .info: return false\n                default: return held == nil\n", "                case .savedAnswer, .info: return false\n                default: return true\n",
     "[a held row never highlights]"),
    # The command center: the list
    ("center: waiting caps at four", C, "        static let waitingCap = 3\n", "        static let waitingCap = 4\n", "[waiting caps at three]"),
    ("center: running caps at four", C, "        static let runningCap = 3\n", "        static let runningCap = 4\n", "[running caps at three]"),
    ("center: fix caps at three", C, "        static let fixCap = 2\n", "        static let fixCap = 3\n", "[fix caps at two]"),
    ("center: waiting not by tier", C, "            items.enumerated().sorted { ($0.element.tier, $0.offset) < ($1.element.tier, $1.offset) }.map(\\.element)\n", "            items\n", "[tier 1 first]"),
    ("center: not loaded says nothing waits", C, '                if !inputs.waitingKnown {\n                    rows.append(info("waiting-unknown"', '                if false {\n                    rows.append(info("waiting-unknown"', "[overview not loaded]"),
    ("center: running not loaded says nothing runs", C, 'rows.append(inputs.runningKnown ? info("no-running"', 'rows.append(true ? info("no-running"', "[overview not loaded]"),
    ("center: sessions off ignored", C, "                if inputs.sessionsOff {\n                    rows.append(Row(id: \"command:openSettings\"", "                if false {\n                    rows.append(Row(id: \"command:openSettings\"", "[sessions off]"),
    ("center: sessions off says nothing waits", C, 'inputs.sessionsOff ? "Nothing else urgent right now." : "Nothing urgent right now."', '"Nothing urgent right now."', "[sessions off never says nothing waits]"),
    ("center: extras listed as fixes", C, "board(s).suggestions.filter({ $0.tier == .repair }).prefix(fixCap)", "board(s).suggestions.prefix(fixCap)", "[fix only when broken]"),
    ("center: two fixes share an id", C, 'fixes.append(Row(id: "fix:" + suggestion.id, kind: .action(action),', 'fixes.append(Row(id: "action:" + action.rawValue, kind: .action(action),', "[row ids are unique]"),
    ("center: the server fix comes last", C, "            return live + (s.serverReachable ? rows + fixes : fixes + rows)\n", "            return live + rows + fixes\n", "[server down lists the fix first]"),
    ("center: Doctor listed twice", C, "if !fixes.contains(where: { $0.kind == .action(.runDoctor) }), let doctor", "if let doctor", "[Doctor listed once]"),
    ("center: the started run is not first", C, "            let running = startedFirst(inputs.running, inputs.startedRunID)\n", "            let running = inputs.running\n", "[a row opens the started run]"),
    ("center: a miss says nothing", C, '                rows.append(info("no-answer", .answer, "No saved answer for this."))\n', "                _ = ranked\n", "[a miss says so]"),
    ("center: a saved answer is not labelled", C, 'detail: saved.text, state: "Saved answer"))', "detail: saved.text))", "[saved answers are labelled]"),
    ('center: an offer says only Start', C, 'group: .answer, title: rowTitle(offer.action), held: offer.held,', 'group: .answer, title: offer.title, held: offer.held,', '[a row says what it starts]'),
    ("center: Ask listed before the answer", C, '            rows.append(Row(id: "file", kind: .file, group: .asking, title: "File to Work", detail: "Saves your words to the Work inbox. No run.", trailing: "Option-Return"))\n', "", "[ask and file are last]"),
    ("center: troubleshoot offered with the gate shut", C, "            if gate(.troubleshoot, s) == .ready, !rows.contains(where: { $0.kind == .action(.troubleshoot) }) {\n", "            if !rows.contains(where: { $0.kind == .action(.troubleshoot) }) {\n", "[Start Work off]"),
    ("center: Ask never holds for Start Work off", C, '            if !s.workRunsOn { return "Work runs from Today is off in Settings." }\n', "", "[Start Work off]"),
    ("center: Ask never holds for the server", C, '            return s.serverReachable ? nil : "Asking needs the COS server."\n', "            return nil\n", "[server down]"),
    # The command center: recording
    ("center: Stop keys on any recording", C, "                guard r.stoppable else { return nil }\n", "                guard r.stoppable || r.glassesLive > 0 else { return nil }\n", "[Stop never keys on a G2 recording]"),
    ("center: Start stays while recording", C, "                if r.stoppable { return nil }\n", "", "[Stop while recording]"),
    ("center: a glasses meeting is captured twice", C, "            if r.busy {\n", "            if r.busy, r.glassesLive == 0 {\n", "[G2 recording holds Start]"),
    ("center: an old Mac is not told", C, "            if !r.osSupported { return RecordingHeld.os }\n", "", "[macOS under 14.2]"),
    ("center: two starts at once", C, "            if r.inFlight { return RecordingHeld.starting }\n", "", "[a held row never highlights]"),
    ("center: server down still offers Start", C, "            return s.serverReachable ? nil : RecordingHeld.server\n", "            return nil\n", "[server down holds Start]"),
    ("center: saving says nothing", C, 'if !macListed, !r.stoppable, let line = r.saveLine { rows.append(info("saving", .doing, line, state: "Saving")) }', "if false, let line = r.saveLine { _ = line }", "[saving shows a line]"),
    # The command center: session titles
    ("center: a title keeps its newline", C, "                if CharacterSet.whitespacesAndNewlines.contains(scalar) {\n", '                if scalar == " " {\n', "[titles are cleaned on the row]"),
    ("center: a title keeps its direction marks", C, "                } else if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.illegalCharacters.contains(scalar) {\n", "                } else if false {\n", "[titles are cleaned on the row]"),
    ("center: a title is unbounded", C, "            return String(String(out).trimmingCharacters(in: .whitespaces).prefix(titleCap))\n", "            return String(out).trimmingCharacters(in: .whitespaces)\n", "[titles are bounded]"),
    ('center: a waiting title is not cleaned', C, 'Row(id: "waiting:" + item.id, kind: .waiting(item.id), group: .waiting, title: hitTitle(item.title),', 'Row(id: "waiting:" + item.id, kind: .waiting(item.id), group: .waiting, title: item.title,', '[titles are cleaned on the row]'),
    ("center: a title match highlights itself", C, "row.group = .sessions\n                    sessions.append(row)\n", "row.group = .sessions\n                    sessions.append(row); result.autoHighlight = result.autoHighlight ?? row.id\n", "never outranks a matching session"),
    ("center: a session lists twice", C, "plain(item.title).contains(typed), !listed(item.sessionID) else { return }", "plain(item.title).contains(typed) else { return }", "[a session lists once]"),
    ("center: the search is uncapped", C, "                guard sessions.count < sessionCap, typed.count >= 2,", "                guard typed.count >= 2,", "[the search is capped]"),
    # The command center: confirms
    ("center: Doctor runs at once", C, "            case .command(.runDoctor), .action(.runDoctor): return doctorConfirm\n", "", "[Doctor always confirms]"),
    ("center: Stop runs at once", C, "            case .command(.stopRecording): return stopConfirm\n", "", "[the hint says what Return does]"),
    ("center: the report spends a question unasked", C, "            case .action(.copyReport): return reportConfirm\n", "", "[the report spends the same question]"),
    ("center: a change runs at once", C, "            case .action(let action): return SetupAssistant.confirmation(action, s)\n", "", "[every change confirms]"),
    ("center: the confirm skips the gate", C, '                case .held(let reason): return reason\n                case .notApplicable: return "This does not apply any more."\n', "                case .held, .notApplicable: return nil\n", "[confirm re-checks the gate]"),
    ("center: Doctor's confirm skips the gate", C, "                if case .held(let reason) = gate(.runDoctor, s) { return reason }\n                return nil\n", "                return nil\n", "[confirm re-checks Doctor]"),
    ("center: Stop skips its check", C, '                return r.stoppable ? nil : "Nothing is recording on this Mac now."\n', "                return nil\n", "[Stop re-checks]"),
    # The command center: Ask COS and the result line
    ("center: Ask without its gate", C, "            guard askHeld(s) == nil else { return nil }\n", "", "[Ask needs Work runs]"),
    ("center: Ask without its words", C, "            guard !words.isEmpty else { return nil }\n", "", "[Ask needs words]"),
    ("center: Ask drops the saved answer", C, "            \\(saved)\n\n", "", "[Ask carries the saved answer]"),
    ("center: Ask drops the rules", C, "            \\(runRules)\n            - If you cannot tell", "            - If you cannot tell", "[Ask carries the rules]"),
    ("center: Ask drops the snapshot", C, '            \\(seen(s).map { "- " + $0 }.joined(separator: "\\n"))\n            """\n            return Troubleshoot(target: "today:ask:"', '            """\n            return Troubleshoot(target: "today:ask:"', "[Ask carries a short snapshot]"),
    ("center: Ask outside the in-flight check", C, 'return Troubleshoot(target: "today:ask:" + id,', 'return Troubleshoot(target: "ask:" + id,', "[Ask stays under Today's in-flight check]"),
    ("center: Ask spends Doctor", C, '            What COS Control sees now:\n            \\(seen(s)', '            Doctor packet: none.\n            What COS Control sees now:\n            \\(seen(s)', "[Ask spends no Doctor]"),
    ("center: a failure hides", C, "            if let line = text(r.error) ?? text(r.recordingError) { return ResultLine(text: line, tone: .problem) }\n", "", "[a failure comes first]"),
    ("center: old news beats a run", C, '            if let line = text(r.helperProgress) { return ResultLine(text: line, tone: .progress) }\n', "", "[what runs now comes next]"),
    # Saved answers beat parakeet-install on their own words
    ("knowledge: set up parakeet loses to will not install", C, 'phrases: ["set up parakeet", "setup parakeet", "parakeet setup", "install parakeet",', 'phrases: ["setup parakeet",', "[knowledge base: parakeet-setup]"),
    ("knowledge: a failure reads as setup", C, '              phrases: ["cant install parakeet", "wont install parakeet", "cant download parakeet", "parakeet install failed", "parakeet setup failed"],\n', "", "[knowledge base: parakeet-install]"),
    ("knowledge: start recording misses", C, 'phrases: ["start recording", "start a recording", "stop recording",', 'phrases: ["start a recording", "stop recording",', "[knowledge base: mac-recording]"),
    ("knowledge: a transcript that never finished misses", C, 'phrases: ["transcript never finished", "transcript never finishes",', 'phrases: ["transcript never finishes",', "[knowledge base: transcript-unfinished]"),
    ("knowledge: how to use dictation misses", C, 'phrases: ["how do i use dictation", "how does dictation work", "how to use dictation", "how do i dictate", "how to dictate", "use dictation", "start dictation",', 'phrases: ["start dictation",', "[knowledge base: dictation-use]"),
    ("knowledge: rename a voice misses", C, 'phrases: ["rename a voice", "rename voice",', 'phrases: ["rename voice",', "[knowledge base: voice-rename]"),
    ("knowledge: speaker names wrong misses", C, '"speaker names wrong", "speaker name wrong",', '"speaker name wrong",', "[knowledge base: voice-rename]"),
    # The command center's view half (Sources/ActivityWindow.swift), held by the pins
    ("view: ⌘K goes Home", W, 'Button("") { toggleCommandCenter() }', 'Button("") { goHome(); toggleCommandCenter() }', "⌘K never navigates"),
    ('view: opening it navigates', W, '        commandKeys.meaningCompressed = []\n        commandKeys.generation += 1\n        commandOpen = true\n', '        commandKeys.meaningCompressed = []\n        commandKeys.generation += 1\n        goHome()\n        commandOpen = true\n', '⌘K never navigates'),
    ("view: Esc goes back past the panel", W, "        if commandOpen {\n            if commandKeys.escape?() != true { closeCommandCenter() }\n            return true\n        }\n", "", "Esc reaches the panel"),
    ("view: the panel gives up its Esc", W, "        keys.escape = { pressEscape() }\n", "", "owns its Esc"),
    ("view: the field is disabled", W, ".onSubmit { pressReturn() }\n", ".onSubmit { pressReturn() }\n                    .disabled(base.snapshot.helperBusy)\n", "never disabled"),
    ("view: the box takes words again", W, "            Button { openCommandCenter() } label: {\n", "            Button { openCommandCenter() } label: {\n                TextField(\"\", text: .constant(\"\"))\n", "the Today box is a button"),
    ("view: the panel moves", W, ".onSubmit { pressReturn() }\n", ".onSubmit { pressReturn() }\n                    .animation(.default, value: words)\n", "nothing moves"),
    ("view: Option-Return left to the field", W, "            if event.keyCode == 36 || event.keyCode == 76, flags == .option {\n                return coordinator.optionReturn?() == true ? nil : event\n            }\n", "", "Option-Return goes through the monitor"),
    ("center: a long paste is cut", C, "            let words = raw.trimmingCharacters(in: .whitespacesAndNewlines)\n            var result = Listing()\n", "            let words = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuestion))\n            var result = Listing()\n", "[a long text stays whole]"),
    ("view: a stale frame", W, "if commandOpen { commandCenter(frame: frame, now: timeline.date,", "if commandOpen { commandCenter(frame: todayFrame(now: Date()), now: timeline.date,", "reads that tick's frame"),
    ("view: a dispatch default", W, "        case .openMemories: select(.memories)\n", "        default: break\n", "no default"),
    ("view: an action not dispatched", W, "        case .openSpeakers:\n            select(.speakers)\n", "        default:\n            select(.speakers)\n", "no default"),
    ("view: typed words as a helper argument", W, 'model.runHelper(["report", "--current-version",', 'model.runHelper(["report", words, "--current-version",', "fixed arguments"),
    ("view: troubleshoot spends Doctor before the guard", W, "        if let refusal = today.runRefusal(target: SetupAssistant.targetPrefix + id, handoff: handoffStore) {\n", "        if let refusal = Optional<String>.none {\n", "guard first"),
    ("view: troubleshoot twice", W, "        guard !today.gatheringReport, !today.runBusy, SetupAssistant.gate", "        guard SetupAssistant.gate", "one at a time"),
    ("view: Ask spends Doctor", W, "        guard let run = SetupAssistant.Center.askRun(question: listing.words,", '        Task { _ = try? await model.runHelper(["report"], timeout: 90) }\n        guard let run = SetupAssistant.Center.askRun(question: listing.words,', "the one helper call"),
    # The recording section under the Today header, and its rows in ⌘K
    ("section: above the header", W, "                todayHeader(now: now)\n                // Miles, 2026-10-31: above everything but the header, and nothing at all when nothing records.\n                if !frame.recordings.isEmpty {\n                    TodayRecordingSection(rows: frame.recordings, now: now, store: model.macRecording, initialConfirm: commandFixture?.todayStopConfirm,\n                                          recording: { commandRecording() }, open: { todayOpen($0) }, stop: { commandStopRecording() })\n                }\n",
     "                if !frame.recordings.isEmpty {\n                    TodayRecordingSection(rows: frame.recordings, now: now, store: model.macRecording, initialConfirm: commandFixture?.todayStopConfirm,\n                                          recording: { commandRecording() }, open: { todayOpen($0) }, stop: { commandStopRecording() })\n                }\n                todayHeader(now: now)\n", "sits under the header"),
    ("section: drawn with nothing recording", W, "                if !frame.recordings.isEmpty {\n                    TodayRecordingSection(", "                if true {\n                    TodayRecordingSection(", "no recording, no section"),
    ("section: Stop with no confirm", W, "Button(SetupAssistant.Center.stopConfirm.confirm) { confirming = row.id }", "Button(SetupAssistant.Center.stopConfirm.confirm) { stop() }", "opens its confirm"),
    ("section: the confirm skips the store", W, "                    if recording().stoppable { stop() }\n", "                    stop()\n", "after checking the store again"),
    ("section: Stop on a glasses row", W, "        row.recording?.canStop == true && live.stoppable\n", "        live.stoppable\n", "only for this Mac's own capture"),
    ("section: Stop keys on the count", W, "        let stoppable = store.isRecording || starting\n", "        let stoppable = model.recordingCount > 0\n", "never recordingCount"),
    ("section: glasses do not say where they stop", W, "            } else if !saving, let note = row.recording.flatMap({ TodayHome.recordingStopNote($0) }) {\n                Text(verbatim: note).font(COSType.body(12.5)).foregroundStyle(TodayInk.sub).lineLimit(1)\n            }\n", "            }\n", "says where it stops"),
    ("section: it pulses", W, "            LiveDot(live: !saving, size: 11)\n", "            LiveDot(live: !saving, size: 11).animation(.default, value: saving)\n", "no pulse"),
    ("section: ⌘K reads its own list", W, "        inputs.live = frame.recordings.compactMap { row in\n", "        inputs.live = frame.running.compactMap { row in\n", "same recordings"),
    ("section: a row opens something else", W, "        case .recording(let id):\n            todayOpen(.liveView(id))\n", "        case .recording(let id):\n            todayOpen(.inSessions(id))\n", "opens its live view"),
    ("center: recordings below the rest", C, "            return live + (s.serverReachable ? rows + fixes : fixes + rows)\n", "            return (s.serverReachable ? rows + fixes : fixes + rows) + live\n", "[recordings are the first rows]"),
    ("center: Stop on a glasses recording", C, "                if item.canStop, let stop = commandRow(.stopRecording, inputs, group: .recording) { live.append(stop) }\n", "                if let stop = commandRow(.stopRecording, inputs, group: .recording) { live.append(stop) }\n", "[Stop lists once]"),
    ("center: Stop listed twice", C, "            if !inputs.live.contains(where: \\.canStop), let stop = commandRow(.stopRecording, inputs, group: .doing) { rows.append(stop) }\n", "            if let stop = commandRow(.stopRecording, inputs, group: .doing) { rows.append(stop) }\n", "[Stop lists once]"),
    ("center: a second glasses line", C, "            if !glassesListed, r.glassesLive > 0 {", "            if r.glassesLive > 0 {", "[no second glasses line]"),
    ("center: saving says recording", C, '                                state: saving ? "Saving" : nil, trailing: "Live view"))\n', '                                state: nil, trailing: "Live view"))\n', "[a stopped recording says it is saving]"),
    ("center: a recording's title is not cleaned", C, 'group: .recording, title: clean(item.title),', 'group: .recording, title: item.title,', "[titles are cleaned on the row]"),
    ("view: Stop keys on the count", W, "        r.stoppable = store.isRecording || r.starting\n", "        r.stoppable = model.recordingCount > 0\n", "Stop keys on the Mac capture"),
    ("view: the card's busy rule skipped", W, "        r.busy = MeetingDetectedCard.recordingBusy(macOccupied: store.occupied, macCanStart: store.canStart, liveRecordings: model.recordingCount)\n", "        r.busy = !store.canStart\n", "one busy rule"),
    ("view: the notice skipped", W, "        guard MacRecordingNotice.step(acknowledged: model.macRecording.noticeAcknowledged) == .start else { return .notice }\n", "", "the notice comes first"),
    ("view: no in-flight flag", W, "        today.recordInFlight = true\n", "", "in-flight flag"),
    ("view: a confirm with stale state", W, "        if let held = C.recheck(row, snapshot(), recording()) {\n", "        if let held = Optional<String>.none {\n", "re-checks fresh state"),
    ("view: a change without its confirm", W, "        if C.confirmation(row, snapshot()) != nil { confirming = id; return }\n", "", "opens its confirm"),
    ("view: a held row runs", W, "        guard let row = listing.rows.first(where: { $0.id == id }), row.selectable else { return }\n", "        guard let row = listing.rows.first(where: { $0.id == id }) else { return }\n", "a held row never runs"),
    ("view: a title parsed as markdown", W, "Text(verbatim: row.title).font(COSType.body(13.5, weight: .semibold)).foregroundStyle(row.held == nil ? TodayInk.ink : TodayInk.sub)", "Text(row.title).font(COSType.body(13.5, weight: .semibold)).foregroundStyle(row.held == nil ? TodayInk.ink : TodayInk.sub)", "drawn verbatim"),
    ("view: a breadcrumb with the title", W, 'todayLog.info("command center: \\(row.logName, privacy: .public)")', 'todayLog.info("command center: \\(row.title, privacy: .public)")', "a breadcrumb names a kind"),
    ("view: quiet hours skipped", W, "        let folded = TodayHome.fold(frame.needs, quiet: TodayHome.isQuiet(now: now, enabled: TodayHome.quietHoursOn(.standard)))\n        // A question's own words", "        let folded = TodayHome.fold(frame.needs, quiet: false)\n        // A question's own words", "quiet-hours fold"),
    ("view: a question's words reach the panel", W, "inputs.waiting = folded.now.map { Item(id: $0.id, title: $0.title,", "inputs.waiting = folded.now.map { Item(id: $0.id, title: $0.quote ?? $0.title,", "a question's words never reach"),
    ("view: a stale session opens", W, "        guard let row = todayFrame(now: Date()).needs.first(where: { $0.id == id }) else {\n", "        guard let row = frameNeeds.first(where: { $0.id == id }) else {\n", "looked up again at open"),
    ("view: an error covers the panel", W, "get: { model.error != nil && !commandOpen },", "get: { model.error != nil },", "shows in place"),
    ("view: the result line loses progress", W, "        r.helperProgress = model.busy ? model.operationProgress : nil\n", "", "operationProgress"),
    ("view: VoiceOver hears nothing", W, "AccessibilityNotification.Announcement(C.announcement(", "_ = (C.announcement(", "VoiceOver hears the highlight"),
    # 0.5.360: Return goes to the command or the session the words point at, and a row that ran leaves nothing armed
    ("center: Return skips the command row", C, "            if let top = listing.rows.first, isOrder(top), top.selectable, !listing.returnSkips.contains(top.id) { return .move(top.id) }\n", "", "[the start of a Start phrase moves to its row]"),
    ("center: Return skips Stop", C, "isOrder(top), top.selectable, !listing.returnSkips.contains(top.id) {", "isOrder(top), top.id != \"command:stopRecording\", top.selectable, !listing.returnSkips.contains(top.id) {", "[Stop inside a sentence still moves to its row, which confirms]"),
    ("center: Return skips Doctor", C, "isOrder(top), top.selectable, !listing.returnSkips.contains(top.id) {", "isOrder(top), top.id != \"command:runDoctor\", top.selectable, !listing.returnSkips.contains(top.id) {", "[Return moves to the command row]"),
    ("center: Return moves to a held command", C, "isOrder(top), top.selectable, !listing.returnSkips.contains(top.id) {", "isOrder(top), !listing.returnSkips.contains(top.id) {", "[a held command moves to Ask]"),
    ("center: a session row comes before the command row", C, "isOrder(top), top.selectable, !listing.returnSkips.contains(top.id) {", "isOrder(top), top.selectable, !listing.returnSkips.contains(top.id), !listing.rows.contains(where: { $0.group == .sessions }) {", "[a command row comes before a session row]"),
    ("center: a session match starts a run", C, "            if let session = listing.rows.first(where: { $0.group == .sessions && $0.selectable }) { return .move(session.id) }\n", "", "[a session match moves to the session]"),
    ("center: a session match moves to Ask", C, "{ return .move(session.id) }", '{ _ = session; return .move("ask") }', "[a session match moves to the session]"),
    ("center: a session match moves past the first", C, "listing.rows.first(where: { $0.group == .sessions && $0.selectable }) { return .move(session.id) }", "listing.rows.last(where: { $0.group == .sessions && $0.selectable }) { return .move(session.id) }", "[a session match moves to the first session row]"),
    ("center: the hint says a session runs", C, 'return Footer(lead: "Return moves to " + sessionWord(row.title), title: row.title, tail: ". Return again opens it.")', 'return Footer(lead: "Return moves to " + sessionWord(row.title), title: row.title, tail: ". Return again runs it.")', "[the hint says what Return does]"),
    ("center: the hint says Stop runs", C, '(confirmation(row, s) != nil ? "asks first." : "runs it.")', '"runs it."', "[the hint says what Return does]"),
    ("center: a ran row keeps its draft", C, "            sendsWords(row) ? draft : \"\"\n", "            draft\n", "[a row that ran leaves no draft]"),
    ("center: every row sends its words", C, "            case .ask, .file, .action(.troubleshoot): return true\n            default: return false\n", "            case .ask, .file, .action(.troubleshoot): return true\n            default: return true\n", "[a row that ran leaves no draft]"),
    ("center: Ask loses its words", C, "            case .ask, .file, .action(.troubleshoot): return true\n", "            case .file, .action(.troubleshoot): return true\n", "[Ask, File and troubleshoot keep the words]"),
    ("center: File loses its words", C, "            case .ask, .file, .action(.troubleshoot): return true\n", "            case .ask, .action(.troubleshoot): return true\n", "[Ask, File and troubleshoot keep the words]"),
    ("center: troubleshoot loses its words", C, "            case .ask, .file, .action(.troubleshoot): return true\n", "            case .ask, .file: return true\n", "[Ask, File and troubleshoot keep the words]"),
    ("view: a ran row keeps its draft", W, "                words = C.draftAfterRun(row, words)\n                keys.draft = words\n", "                words = C.draftAfterRun(row, words)\n", "a row that ran empties its highlight"),
    ("view: a ran row keeps its highlight", W, "            chosen = nil\n            if !(effect == .stay && C.keepsWordsWhileStaying(row)) {\n", "            if !(effect == .stay && C.keepsWordsWhileStaying(row)) {\n", "a row that ran empties its highlight"),
    ("view: the notice counts as a run", W, "        if effect != .notice, !C.sendsWords(row) {\n", "        if !C.sendsWords(row) {\n", "a row that ran empties its highlight"),
    ("view: Ask empties its words", W, "        if effect != .notice, !C.sendsWords(row) {\n", "        if effect != .notice {\n", "a row that ran empties its highlight"),
    ("view: a run leaves the draft behind", W, "            commandKeys.clearDraft(afterSend: sent, accepted: accepted)\n        }\n    }\n}", "            _ = accepted\n        }\n    }\n}", "a run the guard accepted empties the draft"),
    ("view: a filing leaves the draft behind", W, "                try await model.captureTask(domain: taskDomain, text: text)\n                commandKeys.clearDraft(afterSend: text, accepted: true)\n", "                try await model.captureTask(domain: taskDomain, text: text)\n                commandKeys.clearWords?()\n", "a filing that succeeded empties the draft"),
    ("view: a recording leaves the draft behind", W, "        // The start is under way: \"record\" must not come back armed once it has saved.\n        commandKeys.clearDraft()\n", "", "a recording under way empties the draft"),
    ("view: clearing the draft forgets the draft", W, "    func clearDraft() {\n        draft = \"\"\n        clearWords?()\n    }", "    func clearDraft() {\n        clearWords?()\n    }", "clearDraft empties the draft directly"),
    ("view: the unnamed recording counts a Mac row", W, "TodayHome.nonMacLive(serverLive: model.liveTranscriptServerLive, liveSessionIDs: model.liveTranscriptRows.filter { $0.phase == .live }.map(\\.sessionId),\n                                           macHeld: store.occupied, captureID: captureID)", "(model.liveTranscriptServerLive ?? 0) - (store.occupied ? 1 : 0)", "the unnamed recording leaves out every Mac capture"),
    ("view: a saved Mac capture is a glasses meeting", W, "TodayHome.nonMacLive(serverLive: model.recordingCount, liveSessionIDs: model.liveTranscriptRows.filter { $0.phase == .live }.map(\\.sessionId),\n                                             macHeld: store.occupied, captureID: store.manifest?.captureId)", "max(0, model.recordingCount - (store.occupied ? 1 : 0))", "a Mac capture is never a glasses meeting"),
    # 0.5.360 fix pass: a Start phrase inside a sentence, neutral words for a recording that is not known to be on the glasses, and a send that
    # finishes later empties the box only when it was accepted and the box still holds what was sent.
    ("center: Return moves onto a Start phrase in a sentence", C, "top.selectable, !listing.returnSkips.contains(top.id) { return .move(top.id) }", "top.selectable { return .move(top.id) }", "[a Start phrase inside a sentence moves to Ask]"),
    ("center: a Start phrase in a sentence is not marked", C, "                    if command == .startRecording, rank != 0, !(rank == 1 && startsAPhrase(command, words)) { result.returnSkips.insert(row.id) }\n", "", "[a Start phrase inside a sentence stays listed, and Return skips it]"),
    ("center: every command in a sentence is skipped", C, "if command == .startRecording, rank != 0, !(rank == 1 && startsAPhrase(command, words)) {", "if rank != 0, !(rank == 1 && startsAPhrase(command, words)) {", "[Return moves to the command row]"),
    ("center: the start of a Start phrase is skipped too", C, "if command == .startRecording, rank != 0, !(rank == 1 && startsAPhrase(command, words)) {", "if command == .startRecording, rank != 0 {", "[the start of a Start phrase moves to its row]"),
    ("center: a word inside a Start phrase is an order", C, "if command == .startRecording, rank != 0, !(rank == 1 && startsAPhrase(command, words)) {", "if command == .startRecording, rank == 2 {", "[Start recording is reached only by an order, never by a word inside it or a question]"),
    ("center: a phrase start counts any word of the phrase", C, "command.phrases.map(plain).contains { $0.hasPrefix(typed) }", "command.phrases.map(plain).contains { $0.hasPrefix(typed) || $0.split(separator: \" \").contains { $0.hasPrefix(typed) } }", "[Start recording is reached only by an order, never by a word inside it or a question]"),
    ("center: a question mark is the whole phrase", C, "return words.contains(\"?\") ? 2 : 0", "return 0", "[Start recording is reached only by an order, never by a word inside it or a question]"),
    ("center: a question mark demotes only Start", C, "return words.contains(\"?\") ? 2 : 0", "return words.contains(\"?\") && command == .startRecording ? 2 : 0", "[a question mark is never an exact phrase]"),
    ("center: another recording is called a glasses meeting", C, "return r.glassesLive > 0 ? (r.knownGlasses ? RecordingHeld.glasses : RecordingHeld.other) : RecordingHeld.unsaved", "return r.glassesLive > 0 ? RecordingHeld.glasses : RecordingHeld.unsaved", "[another recording holds Start, in neutral words]"),
    ("center: the neutral line says glasses", C, "            if r.knownGlasses { return alone ? \"Stop it on the glasses.\" : glassesLine }\n            return alone ? \"Stop it where it started.\" : otherLine", "            return alone ? \"Stop it on the glasses.\" : glassesLine", "[another recording says where to stop it, in neutral words]"),
    ("center: the Stop confirm names a glasses meeting", C, "A recording on your glasses or iPhone keeps running.", "A glasses meeting keeps running.", "[neutral words name no glasses meeting]"),
    ("center: a refused send uses its words up", C, "accepted && draft.trimmingCharacters", "draft.trimmingCharacters", "[a refused send keeps its words]"),
    ("center: words typed after a send are used up", C, "draft.trimmingCharacters(in: .whitespacesAndNewlines) == sent.trimmingCharacters(in: .whitespacesAndNewlines)", "true", "[words typed after the send stay]"),
    ("center: padding counts as typing", C, "accepted && draft.trimmingCharacters(in: .whitespacesAndNewlines) == sent.trimmingCharacters(in: .whitespacesAndNewlines)", "accepted && draft == sent.trimmingCharacters(in: .whitespacesAndNewlines)", "[padding around the words is not typing]"),
    ("view: Record on the card leaves Start armed", W, "                                chosen = nil\n                                recordAfterNotice()", "                                recordAfterNotice()", "the card's Record uses the Start row up"),
    ("view: an accepted run clears whatever is typed", W, "commandKeys.clearDraft(afterSend: sent, accepted: accepted)", "commandKeys.clearDraft()", "a run the guard accepted empties the draft"),
    ("view: a refused run empties the draft", W, "commandKeys.clearDraft(afterSend: sent, accepted: accepted)", "commandKeys.clearDraft(afterSend: sent, accepted: true)", "a run the guard accepted empties the draft"),
    ("view: the note decides whether a run started", W, "commandKeys.clearDraft(afterSend: sent, accepted: accepted)", "commandKeys.clearDraft(afterSend: sent, accepted: today.runNote == TodayHomeStore.startedNote)", "a run the guard accepted empties the draft"),
    ("view: a finished send ignores what is typed", W, "guard SetupAssistant.Center.sentWordsAreUsedUp(sent: sent, draft: draft, accepted: accepted) else { return }\n        clearDraft()", "clearDraft()", "a finished send empties the draft only when"),
    ("view: every other recording is glasses", W, "r.knownGlasses = r.glassesLive > 0 && others.count >= r.glassesLive && others.allSatisfy { !$0.isPhone && !$0.isUnknown }", "r.knownGlasses = r.glassesLive > 0", "the words say glasses only when"),
    # Pins (the files the compiled checks cannot see)
    ("pins: the release build leaves the file out", R, ' "$ROOT/Sources/SetupAssistant.swift" \\\n', " \\\n", "leaves out SetupAssistant.swift"),
    ("pins: an action names a missing command", C, '            case .repairWhisper: return "restart-whisper"\n', '            case .repairWhisper: return "repair-whisper"\n', "command switch has a case"),
    ("pins: a Doctor row renamed", C, '        static let recovery = "Recovery controller"\n', '        static let recovery = "Recovery agent"\n', "doctorDetails writes"),
    ("pins: the engine opens a link", C, "    static let maxPacket = 12_000\n", '    static let maxPacket = 12_000\n    static let site = URL(string: "https://www.gotcos.com")\n', "never uses URL("),
    ("pins: the suite skips the lane", S, 'zsh "$ROOT/Tests/run-setup-assistant.sh"\n', "", "runs the setup assistant lane once"),
    # 0.5.361: free text moves to Ask first, hits never take Return, places, the noun list, the local word search, match text, the footer
    ("center: the first Return starts a run", C, "            if let target = askable ?? listing.rows.first(where: { $0.kind == .file }) { return .move(target.id) }\n", "            if let target = askable ?? listing.rows.first(where: { $0.kind == .file }) { return .activate(target.id) }\n", "never to a run"),
    ("center: a gone highlight acts on another row", C, "            if let chosen, !listing.rows.contains(where: { $0.id == chosen && $0.selectable }) { return .nothing }\n", "", "that is gone returns nothing"),
    ("center: Return moves onto a hit", C, "            case .command, .place, .settingsGroup: return row.group != .sessions\n", "            case .command, .place, .settingsGroup, .hit: return row.group != .sessions\n", "never a hit"),
    ("center: a session list line takes Return", C, "            case .command, .place, .settingsGroup: return row.group != .sessions\n", "            case .command, .place, .settingsGroup: return true\n", "a session list line"),
    ("center: a hit is a session row for Return", C, "listing.rows.first(where: { $0.group == .sessions && $0.selectable })", "listing.rows.first(where: { ($0.group == .sessions || $0.group == .found) && $0.selectable })", "hit group is never read by Return"),
    ("center: a hit sits with the sessions", C, 'rows.append(Row(id: "hit:" + item.id, kind: .hit(item.id), group: .found,', 'rows.append(Row(id: "hit:" + item.id, kind: .hit(item.id), group: .sessions,', "[hits are their own group]"),
    ("center: a session list waits for nothing", C, "            if listing.listOnly { return .nothing }\n", "", "[a noun list wins its name and highlights nothing]"),
    ("center: an exact place name highlights nothing", C, "                if found.rank == 0, span == nil, result.autoHighlight == nil { result.autoHighlight = row.id }\n", "", "[an exact place name highlights its row]"),
    ("center: a noun list highlights its place", C, "if found.rank == 0, span == nil, result.autoHighlight == nil {", "if found.rank == 0, result.autoHighlight == nil {", "[a noun list wins its name and highlights nothing]"),
    ("center: a place in a sentence is moved to", C, "                if found.rank == 2 || span != nil { result.returnSkips.insert(row.id) }\n", "                if span != nil { result.returnSkips.insert(row.id) }\n", "[a first-word match in a sentence is listed only]"),
    ("center: a noun list moves to its place", C, "                if found.rank == 2 || span != nil { result.returnSkips.insert(row.id) }\n", "                if found.rank == 2 { result.returnSkips.insert(row.id) }\n", "[a noun list wins its name and highlights nothing]"),
    ("center: two letters reach a place", C, "            guard core.count >= 3 else { return nil }\n", "            guard core.count >= 2 else { return nil }\n", "[us skips Usage and goes to a session]"),
    ("center: a place sentence is not listed", C, '            if names.contains(where: { core.hasPrefix($0 + " ") }) { return 2 }\n', "", "[a first-word match in a sentence is listed only]"),
    ("center: a question names a place outright", C, "            if names.contains(core) { return question ? 2 : 0 }\n", "            if names.contains(core) { return 0 }\n", "[a first-word match in a sentence is listed only]"),
    ("center: places are no near-command", C, "!ranked.isEmpty || !placed.isEmpty || !groups.isEmpty || nearCommand(words)", "!ranked.isEmpty || !groups.isEmpty || nearCommand(words)", "[a place counts as a near-command]"),
    ("center: the place list is uncapped", C, "return found.prefix(cap).map { (place: $0.place, rank: $0.rank) }", "return found.map { (place: $0.place, rank: $0.rank) }", "[the place list is capped]"),
    ("center: a place with an unsent message does not ask", C, "            if s.unsentSessionDraft, leavesSession(row) { return draftConfirm }\n", "", "[a place with an unsent message asks first]"),
    ("center: a place always asks", C, "            if s.unsentSessionDraft, leavesSession(row) { return draftConfirm }\n", "            if leavesSession(row) { return draftConfirm }\n", "[the hint says what Return does]"),
    ("center: tasks is not Work", C, 'case .openWork: return opener("work") + opener("tasks")', 'case .openWork: return opener("work")', "[tasks is one row, Work]"),
    ("center: a question is a list", C, "static func nounSpan(_ typed: String, question: Bool) -> Span? { question ? nil : nounForms[typed] }", "static func nounSpan(_ typed: String, question: Bool) -> Span? { nounForms[typed] }", "[a sentence is not a list]"),
    ("center: the noun list is uncapped", C, "for item in inside.prefix(nounCap) {", "for item in inside {", "[the noun list shows eight]"),
    ("center: no more-in-Sessions row", C, "                    if inside.count > nounCap {\n", "                    if false {\n", "[then N more in Sessions]"),
    ("center: an undated session is in today", C, "case .today: return date.map { calendar.isDate($0, inSameDayAs: now) } ?? false", "case .today: return date.map { calendar.isDate($0, inSameDayAs: now) } ?? true", "[an undated session is in all, never in a day]"),
    ("center: a warm-up is listed", C, "for item in live + listed where !item.keepWarm {", "for item in live + listed {", "one session lists once, newest first"),
    ("center: a session merges twice", C, "if let at = byKey[key]?.first(where: { out[$0].sessionID.map { sameListed($0, id) } ?? false }) {", "if let at = Optional<Int>.none {", "[one session lists once, newest first]"),
    ("center: oldest first", C, "case let (x?, y?): return x != y ? x > y : a.offset < b.offset", "case let (x?, y?): return x != y ? x < y : a.offset < b.offset", "[newest first]"),
    ("center: a short id matches at four characters", C, "return short.count >= 8 && long.hasPrefix(short)", "return short.count >= 4 && long.hasPrefix(short)", "Center.sameSession equals ClaudeSession.sameSession"),
    ("center: a session matches across providers", C, "guard x.count == 2, y.count == 2, x[0] == y[0], !x[1].isEmpty", "guard x.count == 2, y.count == 2, !x[1].isEmpty", "Center.sameSession equals ClaudeSession.sameSession"),
    ("center: the live row loses the list's date", C, "                        if out[at].date == nil { out[at].date = item.date }\n", "", "[the live row wins and takes the list's date]"),
    ("center: not loaded says no sessions", C, "                } else if !inputs.sessionsLoaded {\n", "                } else if false {\n", "[sessions not loaded says so]"),
    ("center: two characters search", C, "if typed.count >= 3, span == nil, !exact, !inputs.sessionsOff {", "if typed.count >= 2, span == nil, !exact, !inputs.sessionsOff {", "[under three characters, no search]"),
    ("center: an exact command searches", C, "if typed.count >= 3, span == nil, !exact, !inputs.sessionsOff {", "if typed.count >= 3, span == nil, !inputs.sessionsOff {", "[an exact command, place or noun list runs no search]"),
    ("center: a noun list searches", C, "if typed.count >= 3, span == nil, !exact, !inputs.sessionsOff {", "if typed.count >= 3, !exact, !inputs.sessionsOff {", "a noun list is for choosing"),
    ("center: Sessions off searches", C, "if typed.count >= 3, span == nil, !exact, !inputs.sessionsOff {", "if typed.count >= 3, span == nil, !exact {", "[Sessions off runs no search]"),
    ("center: the search words are uncapped", C, "                let search = String(typed.prefix(200))\n", "                let search = typed\n", "[the words are capped at 200 characters]"),
    ("center: hits are uncapped", C, "for item in found.hits where shown < hitCap && !item.keepWarm && !listed(item.sessionID) {", "for item in found.hits where !item.keepWarm && !listed(item.sessionID) {", "[hits are capped at five]"),
    ("center: a hit lists twice", C, "for item in found.hits where shown < hitCap && !item.keepWarm && !listed(item.sessionID) {", "for item in found.hits where shown < hitCap && !item.keepWarm {", "[a session lists once, by sameSession]"),
    ("center: hits for other words show", C, "                if found.words == search {\n", "                if true {\n", "[hits for other words never show]"),
    ("center: Search all sessions is missing", C, '                rows.append(Row(id: "search-all", kind: .searchAll, group: .found,', '                _ = (Row(id: "search-all", kind: .searchAll, group: .found,', "[Search all sessions is offered]"),
    ("center: a refresh drops the chosen hit", C, "            if old.words == words, let chosen, let gone = old.hits.first(where: { \"hit:\" + $0.id == chosen }), !kept.contains(where: { $0.id == gone.id }) {\n", "            if false, let chosen, let gone = old.hits.first(where: { \"hit:\" + $0.id == chosen }), !kept.contains(where: { $0.id == gone.id }) {\n", "[a refresh keeps a chosen hit]"),
    ("center: new words keep an old hit", C, "if old.words == words, let chosen, let gone", "if let chosen, let gone", "[new words start clean]"),
    ("center: match text is not masked", C, "            var text = mask(clean(snippet))\n", "            var text = clean(snippet)\n", "[key-shaped text is masked in match text]"),
    ("center: a hit title is not masked", C, "        static func hitTitle(_ title: String) -> String { mask(clean(title)) }\n", "        static func hitTitle(_ title: String) -> String { clean(title) }\n", "[key-shaped text is masked in a hit title]"),
    ('center: sk- keys are not masked', C, '            #"(?<![A-Za-z0-9])(?:sk|sess)-[A-Za-z0-9_\\-]{16,}"#,\n', '', '[key-shaped text is masked'),
    ("center: GitHub tokens are not masked", C, '            #"(?<![A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{16,}|(?<![A-Za-z0-9])github_pat_[A-Za-z0-9_]{16,}"#,\n', "", "[key-shaped text is masked"),
    ("center: Slack tokens are not masked", C, '            #"(?<![A-Za-z0-9])xox[abprs]-[A-Za-z0-9\\-]{10,}"#,\n', "", "[key-shaped text is masked"),
    ("center: AWS keys are not masked", C, '            #"(?<![A-Za-z0-9])(?:AKIA|ASIA)[0-9A-Z]{12,}"#,\n', "", "[key-shaped text is masked"),
    ("center: bearer tokens are not masked", C, '            #"(?i)(?<![A-Za-z0-9])bearer\\s+[A-Za-z0-9._~+/\\-]{16,}=*"#,\n', "", "[key-shaped text is masked"),
    ('center: key=value secrets are not masked', C, '            if let keys = try? NSRegularExpression(pattern: pairKeyShape), let values = try? NSRegularExpression(pattern: pairValueShape) {\n', '            if false, let keys = try? NSRegularExpression(pattern: pairKeyShape), let values = try? NSRegularExpression(pattern: pairValueShape) {\n', '[key-shaped text is masked'),
    ("center: long mixed tokens are not masked", C, "            if let runs = try? NSRegularExpression(pattern: longRunShape) {\n", "            if false, let runs = try? NSRegularExpression(pattern: longRunShape) {\n", "[key-shaped text is masked"),
    ("center: a title echo shows", C, "if said.count < 4 || said == named || named.contains(said) { return nil }", "if said.count < 4 { return nil }", "[a title echo shows no match line]"),
    ("center: match text is unbounded", C, "return String(text.prefix(matchCap))", "return text", "[match text is bounded]"),
    ("center: a leading title is kept", C, "if !own.isEmpty, let range = text.range(of: own, options: [.caseInsensitive, .anchored]) {", "if false, let range = text.range(of: own, options: [.caseInsensitive, .anchored]) {", "[a window that starts with the title keeps the rest]"),
    ("center: the footer cuts its tail", C, 'return Footer(lead: "Return moves to " + sessionWord(row.title), title: row.title, tail: ". Return again opens it.")', 'return Footer(lead: "Return moves to " + sessionWord(row.title), title: row.title + ". Return again opens it.")', "[Return again opens it stays whole]"),
    ("center: a place says it runs", C, 'return Footer(lead: confirmation(row, s) != nil ? "Return asks first: " : "Return opens: ", title: row.title)', 'return Footer(lead: confirmation(row, s) != nil ? "Return asks first: " : "Return runs: ", title: row.title)', "the hint says what Return does"),
    ("center: a session titled like a command is not called a session", C, "        static func sessionWord(_ title: String) -> String { orderWords.contains(plain(title)) ? \"the session \" : \"\" }\n", "        static func sessionWord(_ title: String) -> String { \"\" }\n", "[a session titled like a command is called a session]"),
    ("center: every session is called a session", C, "        static func sessionWord(_ title: String) -> String { orderWords.contains(plain(title)) ? \"the session \" : \"\" }\n", "        static func sessionWord(_ title: String) -> String { \"the session \" }\n", "the hint says what Return does"),
    ("center: the fold line changes words", C, 'count == 1 ? "1 thing can wait until tomorrow" : "\\(count) things can wait until tomorrow"', 'count == 1 ? "1 thing can wait until tomorrow" : "\\(count) more for tomorrow"', "[the fold reads the same in both]"),
    ("center: no fold count when something waits", C, '            } else if inputs.foldedCount > 0 {\n                rows.append(info("folded"', '            } else if false {\n                rows.append(info("folded"', "[the fold count shows when something waits]"),
    ("center: nothing waiting reads waiting", C, 'inputs.sessionsOff ? "Nothing else urgent right now." : "Nothing urgent right now."', 'inputs.sessionsOff ? "Nothing else urgent right now." : "Nothing is waiting on you."', "[no sessions]"),
    ("view: Open Sessions keeps Usage", W, "            select(.sessions)\n            sessionsPane = .sessions\n            // Search all put its words", "            select(.sessions)\n            // Search all put its words", "SessionsPane.sessions has no row"),
    ("view: Archive loads nothing", W, "            if model.archiveDays.isEmpty { Task { await model.loadArchiveDays() } }\n        case .speakersMeetings:", "        case .speakersMeetings:", "Archive loads its days"),
    ("view: Usage opens Sessions only", W, "            select(.sessions)\n            sessionsPane = .usage\n", "            select(.sessions)\n", "SessionsPane.usage has no row"),
    ("view: COS cost opens Sessions only", W, "            select(.sessions)\n            sessionsPane = .cost\n", "            select(.sessions)\n", "SessionsPane.cost has no row"),
    ("view: Archive opens Messages only", W, "            messagesSubview = .archive\n", "", "MessagesSubview.archive has no row"),
    ("view: Voices opens Speakers only", W, "            speakerSubview = .voices\n", "", "SpeakerSubview.voices has no row"),
    ("view: Completed opens Work only", W, "        case .workCompleted: commandOpenWork(scope: .completed)\n", "        case .workCompleted: select(.work)\n", "WorkWorkspaceScope.completed has no row"),
    ("view: Threads goes nowhere", W, "        case .threads: select(.threads)\n", "        case .threads: break\n", "ActivitySection.threads has no row"),
    ("view: a place is not dispatched", W, "        case .dictationDictionary:\n            select(.dictation)\n            model.openDictionary()\n", "        default:\n            select(.dictation)\n", "no default"),
    ("view: a hit opens from the list", W, "guard let session = held else {", "guard let session = model.petSession(id: id) else {", "a hit opens its own session object"),
    ("view: a hit opens by the platform only", W, "        default:\n            select(.sessions)\n            sessionsPane = .sessions\n            selectedSessionID = session.id\n            model.openClaudeSession(session)\n", "        default:\n            break\n", "a hit opens the way a list row does"),
    ("view: the search is not debounced", W, "        try? await Task.sleep(nanoseconds: 500_000_000)\n        guard !Task.isCancelled else { return }\n        if found.words != words", "        if found.words != words", "500 ms of quiet first"),
    ("view: the search runs under a fixture", W, "        guard fixture == nil else { return }\n        guard let words else {", "        guard let words else {", "nothing runs under a fixture"),
    # 0.5.362: meaning search. Return reads no meaning row, nothing is asked without the person's yes for the model that decides, a changed model is
    # forgotten, and a row opens only through the guard the list's rows have.
    ("center: Return reads meaning rows", C, "listing.rows.first(where: { $0.group == .sessions && $0.selectable })", "listing.rows.first(where: { ($0.group == .sessions || $0.group == .meaning) && $0.selectable })", "never read by Return"),
    ("center: a search is asked without the person's yes", C, "guard m.offered, m.settled == nil, let provider = m.provider, m.choice == .on else { return nil }", "guard m.offered, m.settled == nil, let provider = m.provider else { return nil }", "one gate"),
    ("center: a search is asked without a saved key", C, "guard m.offered, m.settled == nil, let provider = m.provider, m.choice == .on else { return nil }", "guard m.capable, m.settled == nil, let provider = m.provider, m.choice == .on else { return nil }", "one gate"),
    ("center: a remembered refusal is asked again", C, "guard m.offered, m.settled == nil, let provider = m.provider, m.choice == .on else { return nil }", "guard m.offered, let provider = m.provider, m.choice == .on else { return nil }", "one gate"),
    ("center: a yes for one model counts for all", C, "var choice: MeaningChoice { provider.flatMap { choices[$0.rawValue] } ?? .ask }", "var choice: MeaningChoice { choices.values.contains(.on) ? .on : (provider.flatMap { choices[$0.rawValue] } ?? .ask) }", "never any model"),
    ("center: a changed model is not forgotten", C, "            next.provider = nil\n            next.keyed = false\n", "            next.keyed = false\n", "forgotten"),
    ("center: the question is asked for a model with no key", C, "var offered: Bool { capable && keyed && provider != nil }", "var offered: Bool { capable && provider != nil }", "says yes for the model"),
    ("center: the question is asked of a server that cannot", C, "var offered: Bool { capable && keyed && provider != nil }", "var offered: Bool { keyed && provider != nil }", "says yes for the model"),
    ("center: never asks again", C, "            case .never: return ([], nil, [])\n            case .ask: return (consentRows(provider), nil, [])", "            case .never: return (consentRows(provider), nil, [])\n            case .ask: return (consentRows(provider), nil, [])", "shown only for a server that can"),
    ("center: the question sends the words", C, "            case .ask: return (consentRows(provider), nil, [])", "            case .ask: return (consentRows(provider), MeaningAsk(words: plain(raw), provider: provider), [])", "nothing is sent"),
    ("center: nothing close forgets the files it could not read", C, '            if skipped > 0 { detail = (skipped == 1 ? "1 compressed Codex session could not be read. " : "\\(skipped) compressed Codex sessions could not be read. ") + detail }\n', "", "could not read is said"),
    ("center: a failed search says nothing is close", C, '                return MeaningLine(title: "Meaning search did not answer.", detail: "Word matches above still work. Search all sessions looks further.")', '                return MeaningLine(title: "Nothing close by meaning.", detail: "Search all sessions looks further.")', "never says nothing is close"),
    ("center: an unknown strength reads as strong", C, "init(wire: String?) { self = wire.flatMap(Strength.init(rawValue:)) ?? .possible }", "init(wire: String?) { self = wire.flatMap(Strength.init(rawValue:)) ?? .strong }", "unknown strength"),
    ("center: the hits are not capped at five", C, "                next.hits = keepChosen(Array(items.filter { !$0.keepWarm }.prefix(meaningCap)))", "                next.hits = keepChosen(Array(items.filter { !$0.keepWarm }))", "capped at five"),
    ("center: the id on screen loses", C, "                next.id = same.id\n", "", "id on screen wins"),
    ("center: a session found both ways shows twice", C, "            for item in found.hits where rows.count < meaningCap && !item.keepWarm && !already(item.sessionID) {", "            for item in found.hits where rows.count < meaningCap && !item.keepWarm {", "lists once"),
    ("center: the key shapes in the words are sent", C, "let sent = String(plain(mask(String(raw.prefix(maxQuestion)))).prefix(200))", "let sent = String(plain(String(raw.prefix(maxQuestion))).prefix(200))", "key-shaped words are hidden"),
    ("center: the question says less than what leaves", C, "plus the title and first 150 characters of the first prompt from up to 508 recent sessions, to \\(provider.title).", "plus the title and first 15 characters of the first prompt from up to 508 recent sessions, to \\(provider.title).", "what the notes say"),
    ("center: SubQ is not said to keep what it is sent", C, 'var keeps: String? { self == .subq ? "SubQ keeps what it is sent." : nil }', "var keeps: String? { nil }", "what the notes say"),
    ("center: the answer restarts the search", C, "            let ask = consentedProvider(m).map { MeaningAsk(words: sent, provider: $0) }", "            let ask = consentedProvider(m).map { MeaningAsk(words: sent + (inputs.meaningFound.hits.isEmpty ? \"\" : \" \"), provider: $0) }", "does not restart the search"),
    ("center: a stale running session is running", C, "            return now.timeIntervalSince(updated) > runningFreshness\n", "            return false\n", "not moved in hours"),
    ("center: a wait goes stale", C, '            guard state == "running", let updated else { return false }', '            guard state == "running" || state == "waiting", let updated else { return false }', "a wait can last days"),
    ("view: a quiet session is listed as running", W, "SetupAssistant.Center.staleRunning(state: session.state, updated: session.updatedDate, now: now) ? \"recent\" : session.state", "session.state", "gone quiet for hours"),
    ("center: a Settings group highlights itself", C, "                if found.rank != 0 || span != nil { result.returnSkips.insert(row.id) }\n", "                if found.rank == 0, result.autoHighlight == nil { result.autoHighlight = row.id }\n                if found.rank != 0 || span != nil { result.returnSkips.insert(row.id) }\n", "never highlight themselves"),
    ("center: a word that starts a Settings name takes Return", C, "                if found.rank != 0 || span != nil { result.returnSkips.insert(row.id) }\n", "                if span != nil { result.returnSkips.insert(row.id) }\n", "a near-command moves to Ask"),
    ("center: Settings groups show under the classic Settings", C, "            guard !classic else { return [] }\n", "", "classic Settings"),
    ("center: a hidden Settings group is listed", C, "guard !hidden.contains(group.id), let names = settingsNames[group.id]", "guard let names = settingsNames[group.id]", "capped at three"),
    ("center: the Settings list is uncapped", C, "            return found.prefix(settingsCap).map { (group: $0.group, rank: $0.rank) }", "            return found.map { (group: $0.group, rank: $0.rank) }", "capped at three"),
    ("center: a Settings name is another row's name", C, "                    [\"open \", \"go to \", \"show \"].allSatisfy { !taken.contains($0 + name) } && !taken.contains(name)\n", "                    true\n", "two rows answer to is declared"),
    ("center: a Settings group does not ask about an unsent message", C, "            case .place, .settingsGroup, .searchAll, .recording, .continueIn: return true", "            case .place, .searchAll, .recording, .continueIn: return true\n            case .settingsGroup: return false", "unsent message asks first"),
    ("center: Work layouts hold the word work", C, 'case .workLayoutBoard: return ["board", "board layout"]', 'case .workLayoutBoard: return ["board", "work board"]', "place list is capped"),
    ("view: a Settings group opens under the classic Settings", W, "        guard !classicSettings, SettingsHubCatalog.group(id) != nil else { return .stay }\n", "        guard SettingsHubCatalog.group(id) != nil else { return .stay }\n", "nothing under the classic Settings"),
    ("view: the Memories page is not told again", W, "        if request != context.coordinator.request, let script = Self.openScript(initialView) { view.evaluateJavaScript(script) }\n", "", "told again"),
    ("view: a Memories place is set before select clears it", W, "        select(.memories)\n        memoriesSubview = native\n        memoriesOpenView = view\n", "        memoriesOpenView = view\n        select(.memories)\n        memoriesSubview = native\n", "after select clears it"),
    ("view: a Work layout is not chosen", W, "        select(.work)\n        WorkLayout.choose(layout)\n", "        select(.work)\n", "sets the layout"),
    ("center: Continue in is offered for SubQ", C, "            guard let decides = m.provider, enabledFor.contains(decides), let top = found.hits.first,", "            guard m.provider != nil, let top = found.hits.first,", "Jev only"),
    ("center: Continue in is on for SubQ", C, "static let continueProviders: Set<MeaningProvider> = [.jev]", "static let continueProviders: Set<MeaningProvider> = [.jev, .subq]", "Jev only"),
    ("center: Continue in needs no gap", C, "                guard let second = found.hits[1].probability, p - second >= continueGap else { return nil }", "                guard let second = found.hits[1].probability, p - second >= 0 else { return nil }", "clear gap"),
    ("center: Continue in for a likely match", C, "top.strength == .strong, top.canContinue", "top.strength != nil, top.canContinue", "Jev only, Strong only"),
    ("center: Continue in for a session with no composer", C, "top.strength == .strong, top.canContinue, !top.keepWarm,", "top.strength == .strong, !top.keepWarm,", "Jev only, Strong only"),
    ("center: Continue in takes Return", C, "listing.rows.first(where: { $0.group == .sessions && $0.selectable })", "listing.rows.first(where: { ($0.group == .sessions || $0.id.hasPrefix(\"continue:\")) && $0.selectable })", "never read by Return"),
    ("center: an edited prefill still blocks", C, "                if let text, draft != text { self.text = nil }", "                _ = text", "an edit ends the block"),
    ("center: a placed prefill does not block", C, "            var blocksReturn: Bool { text != nil }", "            var blocksReturn: Bool { false }", "block Return in the composer"),
    ("center: Continue in does not ask before it overwrites", C, "            case .place, .settingsGroup, .searchAll, .recording, .continueIn: return true", "            case .place, .settingsGroup, .searchAll, .recording: return true\n            case .continueIn: return false", "asks before it overwrites"),
    ("view: Return in the composer sends placed words", W, "                    .onSubmit { model.submitChatFromReturn() }", "                    .onSubmit { model.sendChatMessage() }", "prefill block"),
    ("view: the words are placed before the open", W, "        model.openClaudeSession(session)\n        model.prefillChat(words)\n", "        model.prefillChat(words)\n        model.openClaudeSession(session)\n", "only then places the words"),
    ("view: Continue in skips the click-time check", W, "        guard commandCanContinue(session) else {\n            today.flash(\"That session cannot take a message from here now. Open it instead.\")\n            return .stay\n        }\n", "", "checks the session again at the click"),
    ("view: Continue in sends", W, "        model.prefillChat(words)\n        return .close", "        model.prefillChat(words)\n        model.sendChatMessage()\n        return .close", "sends nothing"),
    ("view: a meaning row opens without the server-hold guard", W, "ClaudeSession.listed(hit: hit, loaded: loaded, workSessionIDs: workIDs, runningWorkSessionIDs: runningIDs)", "hit", "server-hold guard"),
    ("view: a meaning row opens from the word hits only", W, "        let held = commandKeys.hitSessions[id] ?? commandKeys.meaningSessions[id]\n            ?? commandKeys.meaningSessions.first(where: { SetupAssistant.Center.sameListed($0.key, id) })?.value\n", "        let held = commandKeys.hitSessions[id]\n", "word hits first"),
    ("view: a compressed Codex row opens in the reader", W, "            guard case .platform = way else {\n                today.flash(\"That session is compressed, so only the Codex app can open it.\")\n                return .stay\n            }\n", "", "Codex app only"),
    ("view: the search asks without the engine's request", W, "        .task(id: listing.meaningAsk) { await runMeaning(listing.meaningAsk) }\n", "        .task(id: listing.searchWords) { await runMeaning(listing.meaningAsk) }\n", "only on the engine's request"),
    ("view: meaning search runs under a fixture", W, "        guard fixture == nil else { return }\n        guard let ask else {", "        guard let ask else {", "not under a fixture"),
    ("view: a changed model is kept while the settings are read", W, "            forgetting = true\n            await reread()\n            forgetting = false\n", "            await reread()\n", "forgets it"),
    ("view: a refusal that stays true is asked again", W, "        if let reason = result.reason, reason.settles { settled = reason }\n", "", "remembered"),
    ("view: the first stage is not delayed", W, "        try? await Task.sleep(nanoseconds: 800_000_000)\n        guard !Task.isCancelled else { return }\n        if meaning.words != ask.words", "        if meaning.words != ask.words", "first stage after 800 ms"),
    ("view: the highlight is not followed when rows arrive", W, "            .onChange(of: listing.rows.map(\\.id)) { _, _ in if let highlight { proxy.scrollTo(highlight) } }\n", "", "highlight is followed"),
    ("view: the question draws two lines", W, "lineLimit(isConsent(row) ? nil : 2)", "lineLimit(2)", "every line of what leaves"),
    ("view: the settings are read on every tick", W, "        if commandFixture == nil { Task { await model.loadDecisionSettings(quiet: true) } }\n        todayLog.info(\"command center opened\")", "        if commandFixture == nil { Task { await model.loadDecisionSettings() } }\n        todayLog.info(\"command center opened\")", "quiet settings read"),
    ("view: the answer is stored for any model", W, "TodayHome.setMeaningChoice(choice.rawValue, provider: provider.rawValue, .standard)", "TodayHome.setMeaningChoice(choice.rawValue, provider: \"jev\", .standard)", "stored for the model the row named"),
    ("view: the model's log carries the words", W, 'todayLog.info("command meaning \\(stage.rawValue, privacy: .public) \\(result.reason?.rawValue ?? "answered", privacy: .public) ms=', 'todayLog.info("command meaning \\(ask.words) \\(result.reason?.rawValue ?? "answered", privacy: .public) ms=', "names a kind"),
    ("view: the search is not keyed", W, ".task(id: listing.searchWords) { await runSearch(listing.searchWords) }", ".task { await runSearch(listing.searchWords) }", "one search at a time"),
    ("view: the search is the server's", W, '["claude-sessions-search", "--local", "--limit", "8"]', '["claude-sessions-search", "--limit", "8"]', "the word search is one fixed verb, local"),
    ("view: the words are an argument", W, '["claude-sessions-search", "--local", "--limit", "8"]', '["claude-sessions-search", "--local", "--limit", "8", "--query", words]', "the word search is one fixed verb"),
    ("view: the words skip stdin", W, "stdinData: Data(String(words.prefix(200)).utf8))", "stdinData: nil)", "the one stated exception to hard rule 2"),
    ("view: the search reads the Sessions tab's hits", W, '        var seen: [String] = []\n        let workIDs = model.workSessionIDs, runningIDs = model.runningWorkSessionIDs, loaded = model.claudeSessions\n        return (response', '        _ = model.sessionSearchHits\n        var seen: [String] = []\n        let workIDs = model.workSessionIDs, runningIDs = model.runningWorkSessionIDs, loaded = model.claudeSessions\n        return (response', "never reads the Sessions tab"),
    ("view: the list refresh is forced", W, "if commandFixture == nil { Task { await model.loadClaudeSessions() } }", "if commandFixture == nil { Task { await model.loadClaudeSessions(force: true) } }", "not forced"),
    ("view: the footer cuts its words", W, "Text(verbatim: footer.lead).lineLimit(1).fixedSize(horizontal: footer.title != nil, vertical: false)\n            if let title = footer.title { Text(verbatim: title).lineLimit(1).truncationMode(.tail) }", "Text(verbatim: footer.lead).lineLimit(1).truncationMode(.tail)\n            if let title = footer.title { Text(verbatim: title).lineLimit(1).truncationMode(.tail) }", "only the title is cut"),
    ("view: Today's headline ignores the fold", W, "Text(TodayHome.brief(todayBriefCounts(frame, now: now)))", "Text(TodayHome.brief(frame.counts))", "the recording section sits under the header"),
    ("view: ⌘K counts the fold differently", W, "inputs.foldedCount = commandFixture?.foldedCount ?? folded.tomorrow.count", "inputs.foldedCount = commandFixture?.foldedCount ?? 0", "⌘K counts what the same fold moved to tomorrow"),
    ("view: the panel's sessions are unbounded", W, "static let commandSessionLimit = 80", "static let commandSessionLimit = 8000", "the panel's sessions are the live rows and the loaded list, merged and bounded"),
    ("center: the opener words are part of a name", C, "            for verb in openerVerbs where typed.hasPrefix(verb) && typed.count > verb.count {\n                core = String(typed.dropFirst(verb.count))\n                break\n            }\n            guard let names = placeNames[place]", "            for verb in [String]() where typed.hasPrefix(verb) && typed.count > verb.count {\n                core = String(typed.dropFirst(verb.count))\n                break\n            }\n            guard let names = placeNames[place]", "an exact place name highlights its row"),
    ("view: VoiceOver reads a hit's words", W, "if shown > 0 { AccessibilityNotification.Announcement(C.foundAnnouncement(shown)).post() }", "if shown > 0 { AccessibilityNotification.Announcement(hits.first?.item.title ?? \"\").post() }", "on arrival VoiceOver hears only the fixed count"),
    ("view: a hit skips the server-hold guard", W, "let session = ClaudeSession.listed(hit: hit.session, loaded: loaded, workSessionIDs: workIDs, runningWorkSessionIDs: runningIDs)", "let session = hit.session", "a hit passes the server-hold guard"),
    ("center: a second hit of one session shows", C, "                            // A second hit for the same session (a Desktop record's id and its transcript's) is not shown either.\n                            if let id = item.sessionID { seen.append(id) }\n", "", "[two hits for one session show once]"),
    ("helper: a Desktop row keeps its record id", HP, "        let sessionId = UUID(uuidString: head.cliSessionId) != nil ? head.cliSessionId : id\n", "        let sessionId = id\n", "carries the cliSessionId its transcript carries"),
    ("helper: the Sessions scan lists the records again", HP, "            newest: transcriptNewest,\n            desktopOnlyRows: false\n", "            newest: transcriptNewest\n", "the Desktop record rows are listed once"),
    ("center: Search all sessions does not say where it goes", C, "Sessions' search asks the COS server and can use your OpenAI key.", "It reaches older ones.", "[Search all sessions says where it searches]"),
    ("center: common words search", C, "!inputs.sessionsOff, searchTokens(typed).isEmpty {", "!inputs.sessionsOff, false {", "[common words run no search]"),
    ("center: a miss says none", C, '"No match near the start of your newest sessions."', '"No session mentions these words."', "[no hit says what was read]"),
    ("center: a miss does not offer the rest", C, '                                             detail: "Search all sessions looks further."))', '                                             detail: nil))', "[no hit offers Search all]"),
    ("center: a stopword is a word", C, '["the", "a", "an", "and", "or", "of", "to",', '["a", "an", "and", "or", "of", "to",', "the engine, the helper and the Sessions tab skip the same words"),
    ("helper: the body read is strict again", HP, "        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {\n            guard let obj = try? JSONSerialization.jsonObject(with: Data(line))", "        guard let text = String(data: data, encoding: .utf8) else { return \"\" }\n        for line in text.split(whereSeparator: \\.isNewline) {\n            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8))", "the body read splits the bytes at newlines"),
    ("view: Work keeps an open card", W, "        workWorkspaceState.domain = nil\n        workWorkspaceState.selectedID = nil\n        handoffStore.selectedWorkID = nil\n        workWorkspaceState.meetingPicker = false\n        workWorkspaceState.linkTarget = nil\n", "        workWorkspaceState.domain = nil\n        workWorkspaceState.meetingPicker = false\n        workWorkspaceState.linkTarget = nil\n", "a Work place lands on a clean list"),
    ("view: Work keeps its domain", W, "        workWorkspaceState.query = \"\"\n        workWorkspaceState.domain = nil\n        workWorkspaceState.selectedID = nil\n        handoffStore.selectedWorkID = nil\n", "        workWorkspaceState.query = \"\"\n        workWorkspaceState.selectedID = nil\n        handoffStore.selectedWorkID = nil\n", "a Work place lands on a clean list"),
    ("view: Work keeps its search", W, "        select(.work)\n        workWorkspaceState.query = \"\"\n        workWorkspaceState.domain = nil\n        workWorkspaceState.selectedID", "        select(.work)\n        workWorkspaceState.domain = nil\n        workWorkspaceState.selectedID", "a Work place lands on a clean list"),
    ("view: Work sets the scope first", W, "        // Last: its observer closes Intake, Waiting on and a Start work overlay.\n        workWorkspaceState.scope = scope\n    }", "    }", "a Work place lands on a clean list"),
    ("view: Dictation settings stay open", W, "        model.closeDictationSettings()\n        model.closeCueReview()", "        model.closeCueReview()", "leaving Dictation closes its settings"),
    ("center: an exact opener never asks", C, "                case .openSessions, .openMeetings, .openWork, .openSpeakers, .openDictation, .openMemories: return true\n", "                case .openSessions, .openMeetings, .openWork, .openSpeakers, .openDictation, .openMemories: return false\n", "an exact opener asks first"),
    ("center: Settings asks", C, "                case .startRecording, .stopRecording, .openSettings, .runDoctor: return false\n", "                case .startRecording, .stopRecording, .runDoctor: return false\n                case .openSettings: return true\n", "Settings does not clear a reply"),
    ("center: a live view never asks", C, "            case .place, .settingsGroup, .searchAll, .recording, .continueIn: return true\n", "            case .place, .settingsGroup, .searchAll, .continueIn: return true\n            case .recording: return false\n", "a live view asks first"),
    ("center: a platform-routed session asks", C, "            case .waiting, .running, .session, .hit: return row.leavesSession\n", "            case .waiting, .running, .session, .hit: return true\n", "a listed session asks only when it opens inside Sessions"),
    ("center: an in-Sessions row never asks", C, "            case .waiting, .running, .session, .hit: return row.leavesSession\n", "            case .waiting, .running, .session, .hit: return false\n", "[a hit and Search all sessions ask first with an unsent message]"),
    ("center: the draft is ignored", C, "            if s.unsentSessionDraft, leavesSession(row) { return draftConfirm }\n", "            if leavesSession(row) { return draftConfirm }\n", "[the hint says what Return does]"),
    ("view: a hit never says it leaves", W, "keepWarm: session.isKeepWarm, match: hit.snippet, leavesSession: commandLeaves(session))", "keepWarm: session.isKeepWarm, match: hit.snippet)", "every waiting, running, listed and hit row"),
    ("view: a platform open is said to clear", W, "        case .platform: return session.heldByServer\n", "        case .platform: return true\n", "a platform open clears no reply"),
    ("helper: the local search reads the token", HP, '        guard query.count >= 3 else { throw HelperError.message("The words must be at least 3 characters.") }\n', '        _ = try? speakerReviewToken()\n        guard query.count >= 3 else { throw HelperError.message("The words must be at least 3 characters.") }\n', "the local search never uses speakerReviewToken"),
    ("helper: the local search words are uncapped", HP, "trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))\n        guard query.count >= 3", "trimmingCharacters(in: .whitespacesAndNewlines))\n        guard query.count >= 3", "bounded stdin"),
    ("helper: the --local flag is not checked", HP, '        if let at = args.firstIndex(of: "--local"), !(at > 0 && args[at - 1] == "--query") { try emitLocalSessionsSearch(args: args); return }\n', "", "the verb's --local flag"),
    ("helper: the local scan reads every transcript", HP, "static let sessionSearchBodyFileLimit = 80", "static let sessionSearchBodyFileLimit = 800", "at most 80 transcripts"),
    ("helper: the local scan reads every Desktop record", HP, "desktopNewest: Self.localSearchDesktopNewest, transcriptNewest: Self.localSearchTranscriptNewest, readCursorPins: false,", "desktopNewest: nil, transcriptNewest: nil, readCursorPins: false,", "the local search bounds its title reads"),
    ("helper: a short Claude id stays short on reveal", HP, "                sessionId: fullId,\n                records: Self.claudeDesktopRecords(for: fullId, sessionsRoot: desktopRoot),", "                sessionId: sessionId,\n                records: Self.claudeDesktopRecords(for: fullId, sessionsRoot: desktopRoot),", "a short Claude id"),
    ('center: a key that is not a credential swallows its value', C, '        private static let pairKeyShape = #"(?<![A-Za-z0-9])(["\']?)([A-Za-z_][A-Za-z0-9_.\\-]*)\\1[ \\t]*[:=][ \\t]*"#\n', '        private static let pairKeyShape = #"(?<![A-Za-z0-9])(["\']?)([A-Za-z_][A-Za-z0-9_.\\-]*)\\1[ \\t]*[:=][ \\t]*\\S*"#\n', '[key-shaped text is masked in match text]'),
    ('center: a bare pass hides any value', C, '                    if key.lowercased() == "pass", !out[value].contains(where: \\.isNumber) { continue }\n', '', '[a name or a plain word is not hidden]'),
    ('center: pk_ words are hidden', C, '            #"(?<![A-Za-z0-9])(?:sk|pk|rk)_(?:live|test)_[A-Za-z0-9]{8,}"#,\n', '            #"(?<![A-Za-z0-9])(?:sk|pk|rk)_[A-Za-z0-9_\\-]{8,}"#,\n', '[a name or a plain word is not hidden]'),
    ('center: Basic matches a path', C, '            #"(?i)(?<![A-Za-z0-9])basic\\s+[A-Za-z0-9+/]{16,}={1,2}"#,\n', '            #"(?i)(?<![A-Za-z0-9])basic\\s+[A-Za-z0-9+/]{16,}={0,2}"#,\n', '[a name or a plain word is not hidden]'),
    ('center: padded Basic is not masked', C, '            #"(?i)(?<![A-Za-z0-9])basic\\s+[A-Za-z0-9+/]{16,}={1,2}"#,\n', '', '[key-shaped text is masked in match text]'),
    ("center: a key's case flips read as words", C, '$0.allSatisfy(\\.isLetter) && humps($0) <= 1 }', '$0.allSatisfy(\\.isLetter) }', '[key-shaped text is masked in match text]'),
    ('center: a waiting title is not masked', C, '            Row(id: "waiting:" + item.id, kind: .waiting(item.id), group: .waiting, title: hitTitle(item.title), detail: item.detail.map(clean),', '            Row(id: "waiting:" + item.id, kind: .waiting(item.id), group: .waiting, title: clean(item.title), detail: item.detail.map(clean),', '[a waiting or running row draws no key]'),
    ('center: a running title is not masked', C, '            Row(id: "running:" + item.id, kind: .running(item.id), group: .running, title: hitTitle(item.title), detail: item.detail.map(clean),', '            Row(id: "running:" + item.id, kind: .running(item.id), group: .running, title: clean(item.title), detail: item.detail.map(clean),', '[a waiting or running row draws no key]'),
    ('center: the classic Dictation settings row never asks', C, 'return action == .openMeetings || action == .openSpeakers || row.leavesSession\n', 'return action == .openMeetings || action == .openSpeakers\n', '[the classic Dictation settings row asks first with an unsent reply]'),
    ('center: the classic Dictation settings row is not marked', C, 'leavesSession: offer.action == .openDictationSettings && s.classicSettings))', 'leavesSession: false))', '[the classic Dictation settings row says it leaves the session]'),
    ('view: the window never says the settings are classic', W, '        s.classicSettings = classicSettings\n', '', 'the window passes the classic Settings flag'),
    ('view: a Sessions row opens the hit as found', W, '                let opened = ClaudeSession.listed(hit: session, loaded: model.claudeSessions, workSessionIDs: model.workSessionIDs, runningWorkSessionIDs: model.runningWorkSessionIDs)\n                selectedSessionID = opened.id\n                model.openClaudeSession(opened)\n', '                selectedSessionID = session.id\n                model.openClaudeSession(session)\n', "a Sessions tab row opens the list's row or the hit marked as Work"),
    ('view: a clean hit open keeps the words', W, '                commandKeys.draft = ""\n', '', "a hit's failed open keeps the panel open until its notice lands"),
    ('view: a reopened panel is closed by the old wait', W, 'guard !model.platformOpenFailed, commandKeys.generation == generation else { return }', 'guard !model.platformOpenFailed else { return }', "a hit's failed open keeps the panel open until its notice lands"),
    ('view: the dead held branch comes back', W, '            guard model.platformOpening else { return .stay }\n', '            if session.heldByServer { return .close }\n            guard model.platformOpening else { return .stay }\n', "a hit's failed open keeps the panel open until its notice lands"),
    ('view: a good Codex note counts as a failure', "Sources/ControllerModel.swift", 'platformOpenFailed = petNotice != nil && !petRevealSucceeded', 'platformOpenFailed = petNotice != nil', 'a platform open is a failure by its flag'),
    ('view: a keyed list row closes the panel', W, '        todayOpen(TodayHome.openFor(session, host: today.hosts[session.id], cursorTrusted: model.petJumpTrusted).action)\n        return commandOpenedEffect()\n', '        todayOpen(TodayHome.openFor(session, host: today.hosts[session.id], cursorTrusted: model.petJumpTrusted).action)\n        return .close\n', 'says whether the panel stays after a refusal'),
    ('view: a refusal closes the panel', W, '!model.platformOpening && model.platformOpenFailed && model.platformOpenNotice != nil ? .stay : .close', '.close', 'a refusal that answers at once keeps the panel open'),
    ('view: the search merge is not one row per session', "Sources/ControllerModel.swift", '        SessionSearchHit.merged(instant, remote)\n', '        instant + remote\n', "a Sessions tab row opens the list's row or the hit marked as Work"),
    # QA 0.5.361 item 9: "voices" is the Voices tab, not a second Speakers opener
    ("center: voices opens Speakers again", C, '                case .openSpeakers: return opener("speakers")\n', '                case .openSpeakers: return opener("speakers") + opener("voices")\n', "[a name two rows answer to is declared]"),
    ("center: voices is declared a shared name", C, '["sessions": "command:openSessions", "recent": "noun"]', '["voices": "command:openSpeakers", "sessions": "command:openSessions", "recent": "noun"]', "[no stale declared name]"),
    # "voices" is no longer in commandWords (it is not a command any more). Adding it back changes nothing anyone can see: an exact place name
    # runs before a near-command is considered, so there is no mutant for it.
    ("view: every Codex rollout is titled", HP, "        for row in recentCodexConversations(sessionsRoot: codexRoot, newest: codexNewest, namesTailBytes: codexNamesTailBytes) { add(row) }\n", "        for row in recentCodexConversations(sessionsRoot: codexRoot, namesTailBytes: codexNamesTailBytes) { add(row) }\n", "the local scan passes the newest bound to the Codex and Cursor scans"),
    ("view: every Cursor transcript is titled", HP, "            pinnedIds: cursorPinned,\n            newest: cursorNewest\n", "            pinnedIds: cursorPinned\n", "the local scan passes the newest bound to the Codex and Cursor scans"),
    # Small things from the QA list: C11, G10, G12, U-minor, S10
    ("center: a failed search always names a list", C, 'detail: sessions.isEmpty ? nil : "The sessions listed here still open."', 'detail: "The sessions listed here still open."', "[a failed search names no list when none is listed]"),
    ("center: a warm-up is a hit", C, "where shown < hitCap && !item.keepWarm && !listed(item.sessionID) {", "where shown < hitCap && !listed(item.sessionID) {", "[a warm-up session is no hit]"),
    ("center: a capped day reads plainly", C, '(capped ? " in your newest \\(inputs.sessionsLimit)." : ".")', '"."', "[a day with none in a full list says how far it reaches]"),
    ("view: a kept hit loses its session", W, "keys.hitSessions.filter { old in refreshed.hits.contains { $0.id == old.key } }", "keys.hitSessions.filter { _ in false }", "a hit kept for the person who chose it keeps its session"),
    ("view: Search all's words stay in Sessions' box", W, '            if let said = commandKeys.searchAllWords, model.sessionQuery == said { model.sessionQuery = ""; model.scheduleSessionSearch() }\n', "", "opening Sessions on its own takes out the words Search all left in its box"),
    ("view: a query of --local is the flag", HP, '        if let at = args.firstIndex(of: "--local"), !(at > 0 && args[at - 1] == "--query") { try emitLocalSessionsSearch(args: args); return }\n', '        if args.contains("--local") { try emitLocalSessionsSearch(args: args); return }\n', "the verb's --local flag is the first thing it checks"),
    # QA 0.5.361 item 16: pins that can fail (each tab write in its own case, the scan's callees, a new tab enum)
    ("view: Usage and COS cost swapped", W, "        case .sessionsUsage:\n            select(.sessions)\n            sessionsPane = .usage\n", "        case .sessionsUsage:\n            select(.sessions)\n            sessionsPane = .cost\n", "SessionsPane.usage has no row"),
    ("view: Archive written under Today", W, "        case .today: goHome()\n", "        case .today: goHome(); messagesSubview = .archive\n", "commandGo .today reaches exactly"),
    ("view: Dictation settings goes nowhere", W, "            select(.dictation)\n            model.openDictationSettings()\n", "            select(.dictation)\n", "commandGo .dictationSettings reaches exactly"),
    ("view: an opener switches a second tab", W, "        case .openMemories: select(.memories)\n", "        case .openMemories: select(.memories); select(.work)\n", "the opener .openMemories reaches exactly"),
    ("view: Search all starts no search", W, "        model.scheduleSessionSearch()\n        return .close\n", "        return .close\n", "Search all sessions is the one place the Sessions tab's box is filled"),
    ("view: a new tab enum nobody lists", W, "private enum SpeakerSubview: String, CaseIterable, Identifiable {", "private enum ThreadsSubview: String { case recent }\nprivate enum SpeakerSubview: String, CaseIterable, Identifiable {", "every Subview enum has its cases checked"),
    ("view: the scan reaches the network", HP, "        (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true\n", "        _ = URLSession.shared\n        return (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true\n", "never uses URLSession"),
    ("view: the scan starts a process", HP, "        guard isRegularTranscript(file), let handle = try? FileHandle(forReadingFrom: file) else { return \"\" }\n", "        _ = Process()\n        guard isRegularTranscript(file), let handle = try? FileHandle(forReadingFrom: file) else { return \"\" }\n", "never uses Process()"),
    ("view: the Cursor pin read is not behind its switch", HP, "readCursorPins ? loadCursorPinnedIds(", "true ? loadCursorPinnedIds(", "the one process the scan can reach"),
    # QA 0.5.361 item 15: a timeout is its own line, and the log names the kind and the time
    ("center: a timeout says did not run", C, 'info("search-timeout", .found, "The search took too long.", detail: "Try fewer words, or Search all sessions.")', 'info("search-timeout", .found, "The search did not run.", detail: "Try fewer words, or Search all sessions.")', "[a timed out search says so]"),
    ("view: a timeout is a failure", W, 'case .timedOut: return ("timed out", .timedOut)', 'case .timedOut: return ("timed out", .failed)', "a timed out search is its own phase"),
    ("view: the search log names the words", W, 'todayLog.error("command search \\(outcome.kind, privacy: .public) ms=', 'todayLog.error("command search \\(words, privacy: .public) ms=', "a breadcrumb names a kind, never words"),
    ("view: the search log drops the time", W, 'command search \\(outcome.kind, privacy: .public) ms=\\(Int(Date().timeIntervalSince(started) * 1000))")', 'command search \\(outcome.kind, privacy: .public)")', "a breadcrumb names a kind, never words"),
    # QA 0.5.361 item 13: masking by credential key, no \\b, names and UUIDs stay, listed rows are masked
    ('center: a word boundary starts a key', C, '            #"(?<![A-Za-z0-9])(?:sk|sess)-[A-Za-z0-9_\\-]{16,}"#,\n', '            #"\\b(?:sk|sess)-[A-Za-z0-9_\\-]{16,}"#,\n', '[key-shaped text is masked'),
    ('center: every key name is a credential', C, '                    guard credentialKey(key) else { continue }\n', '                    _ = key\n', '[a name or a plain word is not hidden]'),
    ("center: a credential key must be the whole name", C, 'return words.contains { upper == $0 || upper.hasSuffix("_" + $0) }', "return words.contains { upper == $0 }", "the credential key rule equals WorkCardFiles.credentialKey"),
    ("center: a plan name is hidden", C, "            return words.count >= 2\n", "            return false\n", "[a name or a plain word is not hidden]"),
    ('center: a UUID is hidden', C, '            if rest.count < run.count, segments.allSatisfy({ $0.allSatisfy(\\.isLetter) }) { return true }\n', '', '[a name or a plain word is not hidden]'),
    ("center: a run with no digit is hidden", C, "return run.contains(where: \\.isLetter) && run.contains(where: \\.isNumber) && !readsAsName(run)", "return run.contains(where: \\.isLetter) && !readsAsName(run)", "[a name or a plain word is not hidden]"),
    ("center: GitLab tokens are not masked", C, '            #"(?<![A-Za-z0-9])glpat-[A-Za-z0-9_\\-]{16,}"#,\n', "", "[key-shaped text is masked"),
    ("center: Slack webhooks are not masked", C, '            #"hooks\\.slack\\.com/services/[A-Za-z0-9/_\\-]+"#,\n', "", "[key-shaped text is masked"),
    ('center: Basic credentials are not masked', C, '            #"(?i)authorization["\']?\\s*[:=]\\s*["\']?basic\\s+[A-Za-z0-9+/]{8,}={0,2}"#,\n', '', '[key-shaped text is masked'),
    ("center: a URL password is not masked", C, "            #\"[A-Za-z][A-Za-z0-9+.\\-]*://[^/\\s:@'\"]+:[^/\\s@'\"]+@\"#,\n", "", "[key-shaped text is masked"),
    ("center: a password flag is not masked", C, '            #"(?i)(?<![A-Za-z0-9])--(?:password|passwd|token|secret|api[_-]?key)(?:=|\\s+)\\S{4,}"#,\n', "", "[key-shaped text is masked"),
    ("center: a listed row is not masked", C, "kind: .session(item.id), group: .sessions, title: hitTitle(item.title),", "kind: .session(item.id), group: .sessions, title: clean(item.title),", "[a listed row draws no key]"),
    ("center: a title match row is not masked", C, 'kind: .session($0.id), group: .sessions, title: hitTitle($0.title), detail:', 'kind: .session($0.id), group: .sessions, title: clean($0.title), detail:', "[a listed row draws no key]"),
    # QA 0.5.361 item 12: a hit's open keeps the panel until it answers
    ("view: a refused hit closes the panel", W, "            guard model.platformOpening else { return .stay }\n", "", "a hit's failed open keeps the panel open until its notice lands"),
    ('view: a clean hit open never closes the panel', W, '                commandKeys.draft = ""\n                closeCommandCenter()\n', '                commandKeys.draft = ""\n', "a hit's failed open keeps the panel open until its notice lands"),
    ("center: a staying hit loses its words", C, "            case .hit, .consent: return true\n            default: return false\n", "            case .consent: return true\n            default: return false\n", "[a hit keeps its words only while the panel stays]"),
    # QA 0.5.361 item 11: off is claimed only once the list answered, and names the switch
    ("center: off before the list answered", C, "var sessionsOff: Bool { sessionsSettingOff && sessionsLoaded }", "var sessionsOff: Bool { sessionsSettingOff }", "the window passes the Show AI sessions setting"),
    ("center: the off row names Sessions", C, 'static let sessionsOffDetail = "Turn on Show AI sessions in Settings, Work and agents."', 'static let sessionsOffDetail = "Turn it on in Sessions to list sessions here."', "[the off row names the switch and opens Settings]"),
    ("center: the off line opens Sessions", C, 'kind: .command(.openSettings), group: .sessions, title: "AI sessions are off",', 'kind: .command(.openSessions), group: .sessions, title: "AI sessions are off",', "[sessions off shows the off row and no search]"),
    ("view: the setting is never passed", W, "        inputs.sessionsSettingOff = !model.claudeSessionsEnabled\n", "        inputs.sessionsSettingOff = false\n", "the window passes the Show AI sessions setting"),
    # QA 0.5.361 item 10: "running" lists what runs and what waits
    ("center: running lists the whole list", C, "                } else if isRunningList(typed) {\n", "                } else if false && isRunningList(typed) {\n", "[running with nothing running says so]"),
    ("center: running skips the runs", C, "                    var items = startedFirst(inputs.running, inputs.startedRunID)\n", "                    var items: [Item] = []\n", "[running lists what runs and what waits]"),
    ("center: running skips the waiting", C, 'for item in inputs.sessions where item.state == "Running" || item.state == "Waiting" {', 'for item in inputs.sessions where item.state == "Running" {', "[running lists what runs and what waits]"),
    ("center: running lists a session twice", C, "                        guard !items.contains(where: { held in held.sessionID.flatMap { id in item.sessionID.map { sameListed(id, $0) } } ?? false }) else { continue }\n", "", "[running lists what runs and what waits]"),
    ("center: running says nothing for nothing", C, 'inputs.runningKnown ? info("running-none", .sessions, "Nothing is running.") : info("running-unknown", .sessions, "Running: not loaded yet.")', 'info("running-none", .sessions, "No sessions yet.")', "[running with nothing running says so]"),
    ("center: running says none before it loaded", C, 'inputs.runningKnown ? info("running-none", .sessions, "Nothing is running.") : info("running-unknown", .sessions, "Running: not loaded yet.")', 'info("running-none", .sessions, "Nothing is running.")', "[running not loaded says so]"),
    ("center: running is uncapped", C, "                    for item in items.prefix(nounCap) {\n", "                    for item in items {\n", "[running is capped at eight]"),
    ("center: running has no more row", C, "                    if items.count > nounCap {\n", "                    if false {\n", "[running is capped at eight]"),
    ("center: running has day words", C, '            for noun in ["running", "running sessions"] { out[noun] = .all }\n', '            for noun in ["running", "running sessions"] { out[noun] = .all; for (suffix, span) in days { out[noun + " " + suffix] = span } }\n', "[running has no day words]"),
]

# Most dangerous first: what would spend a run, record, or change something unasked, then the keys and the saved answers. The
# view mutants come first of all, because a pin kills each before any compile. Whatever is not named here runs after these.
CENTER_FIRST = [
    # 0.5.362 first: Return reads no meaning row, nothing is asked without a yes, a changed model is forgotten, a row opens through the list's guard.
    "center: Return reads meaning rows", "center: a search is asked without the person's yes", "center: a yes for one model counts for all", "center: a changed model is not forgotten",
    "view: a meaning row opens without the server-hold guard", "view: the search asks without the engine's request",
    # 0.5.361 first: a run must never start from a first Return, a hit must never take Return, nothing typed may leave the Mac or reach an argument.
    "view: the search is the server's", "view: the words are an argument", "view: the words skip stdin", "helper: the local search reads the token", "helper: the --local flag is not checked",
    "center: the first Return starts a run", "center: Return moves onto a hit", "center: a session list line takes Return", "center: a hit is a session row for Return", "center: a hit sits with the sessions",
    "center: a gone highlight acts on another row", "view: the search reads the Sessions tab's hits", "view: a hit opens from the list", "view: a hit opens by the platform only",
    "view: the search is not keyed", "view: the search is not debounced", "view: the search runs under a fixture", "view: the list refresh is forced",
    "helper: the local scan reads every transcript", "helper: the local scan reads every Desktop record", "helper: the local search words are uncapped", "helper: a short Claude id stays short on reveal",
    "center: a place with an unsent message does not ask", "center: a place always asks", "center: a place in a sentence is moved to", "center: a question names a place outright",
    "center: an exact place name highlights nothing", "center: a noun list highlights its place", "center: a noun list moves to its place", "center: a session list waits for nothing",
    "center: two letters reach a place", "center: a place sentence is not listed", "center: places are no near-command", "center: the place list is uncapped", "center: tasks is not Work",
    "view: Open Sessions keeps Usage", "view: Archive loads nothing", "view: Usage opens Sessions only", "view: COS cost opens Sessions only", "view: Archive opens Messages only",
    "view: Voices opens Speakers only", "view: Completed opens Work only", "view: Threads goes nowhere", "view: a place is not dispatched",
    "center: a question is a list", "center: the noun list is uncapped", "center: no more-in-Sessions row", "center: an undated session is in today", "center: a warm-up is listed",
    "center: a session merges twice", "center: oldest first", "center: a short id matches at four characters", "center: a session matches across providers",
    "center: the live row loses the list's date", "center: not loaded says no sessions",
    "center: two characters search", "center: an exact command searches", "center: a noun list searches", "center: Sessions off searches", "center: the search words are uncapped",
    "center: hits are uncapped", "center: a hit lists twice", "center: hits for other words show", "center: Search all sessions is missing", "center: a refresh drops the chosen hit", "center: new words keep an old hit",
    "center: match text is not masked", "center: a hit title is not masked", "center: sk- keys are not masked", "center: GitHub tokens are not masked", "center: Slack tokens are not masked",
    "center: AWS keys are not masked", "center: bearer tokens are not masked", "center: key=value secrets are not masked", "center: long mixed tokens are not masked",
    "center: a title echo shows", "center: match text is unbounded", "center: a leading title is kept",
    "center: the footer cuts its tail", "center: a place says it runs", "center: a session titled like a command is not called a session", "center: every session is called a session", "view: the footer cuts its words", "view: VoiceOver reads a hit's words", "center: the opener words are part of a name",
    "center: the fold line changes words", "center: no fold count when something waits", "center: nothing waiting reads waiting", "view: Today's headline ignores the fold",
    "view: ⌘K counts the fold differently", "view: the panel's sessions are unbounded",
    # Miles's ask of 2026-10-31 first.
    "section: above the header", "section: drawn with nothing recording", "section: Stop with no confirm", "section: the confirm skips the store", "section: Stop on a glasses row",
    "section: Stop keys on the count", "section: glasses do not say where they stop", "section: it pulses", "section: ⌘K reads its own list", "section: a row opens something else",
    "view: a change without its confirm", "view: a confirm with stale state", "view: a held row runs", "view: the notice skipped", "view: the card's busy rule skipped",
    "view: Stop keys on the count", "view: no in-flight flag", "view: typed words as a helper argument", "view: troubleshoot spends Doctor before the guard", "view: troubleshoot twice",
    "view: Ask spends Doctor", "view: ⌘K goes Home", "view: opening it navigates", "view: Esc goes back past the panel", "view: the panel gives up its Esc",
    "view: Option-Return left to the field", "view: a dispatch default", "view: an action not dispatched", "view: the field is disabled", "view: the box takes words again",
    "center: recordings below the rest", "center: Stop on a glasses recording", "center: Stop listed twice", "center: a second glasses line", "center: saving says recording",
    "view: a ran row keeps its draft", "view: a ran row keeps its highlight", "view: the notice counts as a run", "view: Ask empties its words",
    "view: a run leaves the draft behind", "view: a filing leaves the draft behind", "view: a recording leaves the draft behind", "view: clearing the draft forgets the draft",
    "view: the unnamed recording counts a Mac row", "view: a saved Mac capture is a glasses meeting",
    "center: Return skips the command row", "center: Return skips Stop", "center: Return skips Doctor", "center: Return moves to a held command",
    "center: a session row comes before the command row", "center: a session match starts a run", "center: a session match moves to Ask", "center: a session match moves past the first",
    "center: a ran row keeps its draft", "center: every row sends its words", "center: Ask loses its words", "center: File loses its words", "center: troubleshoot loses its words",
    "center: the hint says a session runs", "center: the hint says Stop runs",
    "center: a saved answer starts a run", "center: a near-command starts a run", "center: Return runs a held Ask",
    "center: a phrase in a sentence is no near-command", "center: near-command at any length",
    "center: Stop highlights itself", "center: Doctor highlights itself", "center: part of a phrase highlights", "center: a held row highlights",
    "center: Return accepts the notice", "center: a glasses meeting is captured twice", "center: Stop keys on any recording", "center: two starts at once",
    "center: an old Mac is not told", "center: server down still offers Start", "center: Start stays while recording", "center: saving says nothing",
    "center: Doctor runs at once", "center: Stop runs at once", "center: a change runs at once", "center: the report spends a question unasked",
    "center: the confirm skips the gate", "center: Doctor's confirm skips the gate", "center: Stop skips its check",
    "center: Option-Return stops filing", "center: Return ignores the highlight", "center: Return ignores the confirm", "center: a stale highlight still runs",
    "center: Start Work off stops filing", "center: a long paste is cut",
    "center: Esc closes at once", "center: Esc leaves a confirm open",
    "center: a command's title changes", "center: a phrase is not exact",
    "knowledge: set up parakeet loses to will not install", "knowledge: a failure reads as setup", "knowledge: start recording misses", "knowledge: a transcript that never finished misses",
    "knowledge: how to use dictation misses", "knowledge: rename a voice misses", "knowledge: speaker names wrong misses",
    "center: a saved answer is not labelled", "center: a miss says nothing", "center: an exact command still shows the answer",
    "center: a title match highlights itself", "center: a title keeps its newline", "center: a title keeps its direction marks", "center: a waiting title is not cleaned",
    "center: Ask drops the rules", "center: Ask spends Doctor", "center: Ask without its gate", "troubleshoot: no ask-first rule", "board: a server row on first run",
]


def center_mutants():
    """CENTER_FIRST in its order, then every other command center mutant in file order."""
    by_name = {m[0]: m for m in MUTANTS}
    missing = [name for name in CENTER_FIRST if name not in by_name]
    if missing:
        sys.exit(f"CENTER_FIRST names mutants that do not exist: {missing}")
    rest = [m for m in MUTANTS if m[0].split(":")[0] in ("section", "center", "view", "knowledge") and m[0] not in CENTER_FIRST]
    return [by_name[name] for name in CENTER_FIRST] + rest


def today_pins(copy):
    """Tests/activity-today-pins.py on the copy: pure Python, a second or two."""
    result = bounded.run(["python3", "Tests/activity-today-pins.py", "."], 120, cwd=copy)
    return result.returncode, result.stdout + result.stderr


def suite(copy, deadline=None):
    outcome = suite_lane(copy, deadline)
    if outcome is None or outcome[0] != 0:
        return outcome
    code, text = today_pins(copy)
    return (code, outcome[1] + text, outcome[2], outcome[3])


def suite_lane(copy, deadline=None):
    started = time.time()
    # The compile lock is shared with whoever else is building: waiting for it is not a kill.
    for _ in range(60):
        result = bounded.run(["zsh", "Tests/run-setup-assistant.sh"], LIMIT, cwd=copy)
        out = result.stdout + result.stderr
        if "shared compile lock busy" not in out:
            break
        if deadline and time.time() > deadline:
            return None
        time.sleep(30)
    if "compile-guard: STOPPED" in out:
        sys.exit("compile-guard stopped a compile (memory); ending the mutation lane. " + out[-400:])
    return result.returncode, out, time.time() - started, result.timed_out


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    names = sys.argv[3:]
    unknown = [n for n in names if n != "--center" and n not in {m[0] for m in MUTANTS}]
    if unknown:
        sys.exit(f"no such mutant: {unknown}")
    # Each target lands exactly once, or nothing is judged: found now, not an hour in.
    for name, rel, old, _, _ in MUTANTS:
        count = (src / rel).read_text(encoding="utf-8").count(old)
        if count != 1:
            print(f"MISS  {name}: the target appears {count} times", flush=True)
    chosen = center_mutants() if "--center" in names else [m for m in MUTANTS if not names or m[0] in names]
    minutes = float(os.environ.get("COS_MUTATE_MINUTES", "0"))
    deadline = time.time() + minutes * 60 if minutes else None
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    for part in ("Sources", "Tests", "HelperSources", "scripts"):
        shutil.copytree(src / part, copy / part)
    # The notes pins read What's New and the CHANGELOG (the privacy words are pinned there).
    (copy / "Resources").mkdir(exist_ok=True)
    shutil.copy2(src / "Resources/WhatsNew.json", copy / "Resources/WhatsNew.json")
    shutil.copy2(src / "CHANGELOG.md", copy / "CHANGELOG.md")
    code, out, seconds, _ = suite(copy)
    passed = [l for l in out.splitlines() if l.startswith("PASS: setup assistant") or "Activity Today wiring pinned" in l]
    print(f"BASELINE (unmutated): exit {code} in {seconds:.0f}s: {' / '.join(x[:60] for x in passed) or '(no PASS line)'}", flush=True)
    if code != 0 or len(passed) != 3:
        print(out[-3000:])
        sys.exit("baseline is not green; no mutant may be judged against a red suite")
    killed = survived = 0
    not_run = []
    for name, rel, old, new, words in chosen:
        if deadline and time.time() > deadline:
            not_run.append(name); continue
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            print(f"MISS  {name}: the target appears {text.count(old)} times", flush=True); survived += 1; continue
        path.write_text(text.replace(old, new), encoding="utf-8")
        try:
            outcome = suite(copy, deadline)
        finally:
            path.write_text(text, encoding="utf-8")
        if outcome is None:
            not_run.append(name); continue
        code, out, seconds, timed_out = outcome
        if not filecmp.cmp(path, src / rel, shallow=False):
            sys.exit(f"RESTORE FAILED for {name}: {rel} differs from the worktree")
        lines = [l for l in out.splitlines() if "check failed [" in l or "Setup assistant pin:" in l or "Activity Today pin:" in l or ": error:" in l]
        reason = lines[0].strip() if lines else (out.strip().splitlines()[-1] if out.strip() else "")
        if timed_out:
            killed += 1; print(f"killed  {name}: TIMEOUT after {LIMIT} s (no named check)", flush=True)
        elif code == 0:
            survived += 1; print(f"SURVIVED  {name}", flush=True)
        elif words.lower() in reason.lower():
            killed += 1; print(f"killed  {name} ({seconds:.0f}s): {reason[:220]}", flush=True)
        else:
            survived += 1; print(f"MISATTRIBUTED  {name}: {reason[:260]}", flush=True)
    for name in not_run:
        print(f"NOT RUN  {name}", flush=True)
    print(f"RESULT: {killed}/{killed + survived} killed by a check that names the behaviour; {len(not_run)} not run; every restore compared equal", flush=True)
    sys.exit(0 if survived == 0 and not not_run else 1)


if __name__ == "__main__":
    main()
