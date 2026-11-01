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
    ("center: a phrase is not exact", C, "            if phrases.contains(typed) { return 0 }\n", "", "[a command's phrase is exact]"),
    # The command center: Return
    ("center: a saved answer starts a run", C, "            let cautious = listing.hasAnswer || listing.nearCommand\n", "            let cautious = listing.nearCommand\n", "[a saved answer moves to Ask]"),
    ("center: a near-command starts a run", C, "            let cautious = listing.hasAnswer || listing.nearCommand\n", "            let cautious = listing.hasAnswer\n", "[a near-command moves to Ask]"),
    ("center: a short text starts a run", C, "if askable != nil, !cautious, longEnough { return .startRun }", "if askable != nil, !cautious { return .startRun }", "[under three words moves to Ask]"),
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
    ("center: the hint lies", C, 'default: return "Return moves to \\(row.title). Return again " + (confirmation(row, s) != nil ? "asks first." : "runs it.")', 'default: return "Return runs it."', "[the hint says what Return does]"),
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
    ("center: not loaded says nothing waits", C, 'rows.append(inputs.waitingKnown ? info("no-waiting"', 'rows.append(true ? info("no-waiting"', "[overview not loaded]"),
    ("center: running not loaded says nothing runs", C, 'rows.append(inputs.runningKnown ? info("no-running"', 'rows.append(true ? info("no-running"', "[overview not loaded]"),
    ("center: sessions off ignored", C, "                if inputs.sessionsOff {\n", "                if false {\n", "[sessions off]"),
    ("center: sessions off says nothing waits", C, 'inputs.sessionsOff ? "Nothing else is waiting on you." : "Nothing is waiting on you."', '"Nothing is waiting on you."', "[sessions off never says nothing waits]"),
    ("center: extras listed as fixes", C, "board(s).suggestions.filter({ $0.tier == .repair }).prefix(fixCap)", "board(s).suggestions.prefix(fixCap)", "[fix only when broken]"),
    ("center: two fixes share an id", C, 'fixes.append(Row(id: "fix:" + suggestion.id, kind: .action(action),', 'fixes.append(Row(id: "action:" + action.rawValue, kind: .action(action),', "[row ids are unique]"),
    ("center: the server fix comes last", C, "            return live + (s.serverReachable ? rows + fixes : fixes + rows)\n", "            return live + rows + fixes\n", "[server down lists the fix first]"),
    ("center: Doctor listed twice", C, "if !fixes.contains(where: { $0.kind == .action(.runDoctor) }), let doctor", "if let doctor", "[Doctor listed once]"),
    ("center: the started run is not first", C, "            let running = startedFirst(inputs.running, inputs.startedRunID)\n", "            let running = inputs.running\n", "[a row opens the started run]"),
    ("center: a miss says nothing", C, '                rows.append(info("no-answer", .answer, "No saved answer for this."))\n', "                _ = ranked\n", "[a miss says so]"),
    ("center: a saved answer is not labelled", C, 'detail: saved.text, state: "Saved answer"))', "detail: saved.text))", "[saved answers are labelled]"),
    ("center: an offer says only Start", C, "group: .answer, title: rowTitle(offer.action), held: offer.held))", "group: .answer, title: offer.title, held: offer.held))", "[a row says what it starts]"),
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
    ("center: a waiting title is not cleaned", C, 'Row(id: "waiting:" + item.id, kind: .waiting(item.id), group: .waiting, title: clean(item.title),', 'Row(id: "waiting:" + item.id, kind: .waiting(item.id), group: .waiting, title: item.title,',
     "[titles are cleaned on the row]"),
    ("center: a title match highlights itself", C, "                sessions.append(row)\n", "                sessions.append(row); result.autoHighlight = result.autoHighlight ?? row.id\n", "[a session match never highlights]"),
    ("center: a session lists twice", C, "                if let session = item.sessionID { guard seen.insert(session).inserted else { return } }\n", "", "[a session lists once]"),
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
    ("view: opening it navigates", W, "        commandKeys.recordFailed = false\n        commandOpen = true\n", "        commandKeys.recordFailed = false\n        goHome()\n        commandOpen = true\n", "⌘K never navigates"),
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
    ("view: quiet hours skipped", W, "TodayHome.fold(frame.needs, quiet: TodayHome.isQuiet(now: now, enabled: TodayHome.quietHoursOn(.standard)))", "TodayHome.fold(frame.needs, quiet: false)", "quiet-hours fold"),
    ("view: a question's words reach the panel", W, "inputs.waiting = folded.now.map { Item(id: $0.id, title: $0.title,", "inputs.waiting = folded.now.map { Item(id: $0.id, title: $0.quote ?? $0.title,", "a question's words never reach"),
    ("view: a stale session opens", W, "        guard let row = todayFrame(now: Date()).needs.first(where: { $0.id == id }) else {\n", "        guard let row = frameNeeds.first(where: { $0.id == id }) else {\n", "looked up again at open"),
    ("view: an error covers the panel", W, "get: { model.error != nil && !commandOpen },", "get: { model.error != nil },", "shows in place"),
    ("view: the result line loses progress", W, "        r.helperProgress = model.busy ? model.operationProgress : nil\n", "", "operationProgress"),
    ("view: VoiceOver hears nothing", W, "AccessibilityNotification.Announcement(C.announcement(", "_ = (C.announcement(", "VoiceOver hears the highlight"),
    # 0.5.360: Return goes to the command or the session the words point at, and a row that ran leaves nothing armed
    ("center: Return skips the command row", C, "            if let top = listing.rows.first, case .command = top.kind, top.selectable { return .move(top.id) }\n", "", "[Return moves to the command row]"),
    ("center: Return skips Stop", C, "case .command = top.kind, top.selectable {", "case .command(let command) = top.kind, command != .stopRecording, top.selectable {", "[Return moves to Stop, not to a Work run]"),
    ("center: Return skips Doctor", C, "case .command = top.kind, top.selectable {", "case .command(let command) = top.kind, command != .runDoctor, top.selectable {", "[Return moves to the command row]"),
    ("center: Return moves to a held command", C, "case .command = top.kind, top.selectable {", "case .command = top.kind {", "[a held command moves to Ask]"),
    ("center: a session row comes before the command row", C, "case .command = top.kind, top.selectable {", "case .command = top.kind, top.selectable, !listing.rows.contains(where: { $0.group == .sessions }) {", "[a command row comes before a session row]"),
    ("center: a session match starts a run", C, "            if let session = listing.rows.first(where: { $0.group == .sessions && $0.selectable }) { return .move(session.id) }\n", "", "[a session match moves to the session]"),
    ("center: a session match moves to Ask", C, "{ return .move(session.id) }", '{ _ = session; return .move("ask") }', "[a session match moves to the session]"),
    ("center: a session match moves past the first", C, "listing.rows.first(where: { $0.group == .sessions && $0.selectable }) { return .move(session.id) }", "listing.rows.last(where: { $0.group == .sessions && $0.selectable }) { return .move(session.id) }", "[a session match moves to the first session row]"),
    ("center: the hint says a session runs", C, '                case .recording, .waiting, .running, .session: return "Return moves to \\(row.title). Return again opens it."\n', '                case .recording, .waiting, .running, .session: return "Return moves to \\(row.title). Return again runs it."\n', "[the hint says what Return does]"),
    ("center: the hint says Stop runs", C, '(confirmation(row, s) != nil ? "asks first." : "runs it.")', '"runs it."', "[the hint says what Return does]"),
    ("center: a ran row keeps its draft", C, "            sendsWords(row) ? draft : \"\"\n", "            draft\n", "[a row that ran leaves no draft]"),
    ("center: every row sends its words", C, "            case .ask, .file, .action(.troubleshoot): return true\n            default: return false\n", "            case .ask, .file, .action(.troubleshoot): return true\n            default: return true\n", "[a row that ran leaves no draft]"),
    ("center: Ask loses its words", C, "            case .ask, .file, .action(.troubleshoot): return true\n", "            case .file, .action(.troubleshoot): return true\n", "[Ask, File and troubleshoot keep the words]"),
    ("center: File loses its words", C, "            case .ask, .file, .action(.troubleshoot): return true\n", "            case .ask, .action(.troubleshoot): return true\n", "[Ask, File and troubleshoot keep the words]"),
    ("center: troubleshoot loses its words", C, "            case .ask, .file, .action(.troubleshoot): return true\n", "            case .ask, .file: return true\n", "[Ask, File and troubleshoot keep the words]"),
    ("view: Return starts a bare run", W, "            if let ask = listing.rows.first(where: { $0.kind == .ask && $0.selectable }) { activate(ask.id, listing) }\n", "            submit(listing.words)\n", "starts its Work run through the Ask row"),
    ("view: a ran row keeps its draft", W, "            words = C.draftAfterRun(row, words)\n            keys.draft = words\n", "            words = C.draftAfterRun(row, words)\n", "a row that ran empties its highlight"),
    ("view: a ran row keeps its highlight", W, "            chosen = nil\n            words = C.draftAfterRun(row, words)\n", "            words = C.draftAfterRun(row, words)\n", "a row that ran empties its highlight"),
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
    ("center: a Start phrase in a sentence is not marked", C, "                    if rank == 2, command == .startRecording { result.returnSkips.insert(row.id) }\n", "", "[a Start phrase inside a sentence stays listed, and Return skips it]"),
    ("center: every command in a sentence is skipped", C, "if rank == 2, command == .startRecording {", "if rank == 2 {", "[Return moves to the command row]"),
    ("center: the start of a Start phrase is skipped too", C, "if rank == 2, command == .startRecording {", "if rank >= 1, command == .startRecording {", "[the start of a Start phrase moves to its row]"),
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
]

# Most dangerous first: what would spend a run, record, or change something unasked, then the keys and the saved answers. The
# view mutants come first of all, because a pin kills each before any compile. Whatever is not named here runs after these.
CENTER_FIRST = [
    # Miles's ask of 2026-10-31 first.
    "section: above the header", "section: drawn with nothing recording", "section: Stop with no confirm", "section: the confirm skips the store", "section: Stop on a glasses row",
    "section: Stop keys on the count", "section: glasses do not say where they stop", "section: it pulses", "section: ⌘K reads its own list", "section: a row opens something else",
    "view: a change without its confirm", "view: a confirm with stale state", "view: a held row runs", "view: the notice skipped", "view: the card's busy rule skipped",
    "view: Stop keys on the count", "view: no in-flight flag", "view: typed words as a helper argument", "view: troubleshoot spends Doctor before the guard", "view: troubleshoot twice",
    "view: Ask spends Doctor", "view: ⌘K goes Home", "view: opening it navigates", "view: Esc goes back past the panel", "view: the panel gives up its Esc",
    "view: Option-Return left to the field", "view: a dispatch default", "view: an action not dispatched", "view: the field is disabled", "view: the box takes words again",
    "center: recordings below the rest", "center: Stop on a glasses recording", "center: Stop listed twice", "center: a second glasses line", "center: saving says recording",
    "view: Return starts a bare run", "view: a ran row keeps its draft", "view: a ran row keeps its highlight", "view: the notice counts as a run", "view: Ask empties its words",
    "view: a run leaves the draft behind", "view: a filing leaves the draft behind", "view: a recording leaves the draft behind", "view: clearing the draft forgets the draft",
    "view: the unnamed recording counts a Mac row", "view: a saved Mac capture is a glasses meeting",
    "center: Return skips the command row", "center: Return skips Stop", "center: Return skips Doctor", "center: Return moves to a held command",
    "center: a session row comes before the command row", "center: a session match starts a run", "center: a session match moves to Ask", "center: a session match moves past the first",
    "center: a ran row keeps its draft", "center: every row sends its words", "center: Ask loses its words", "center: File loses its words", "center: troubleshoot loses its words",
    "center: the hint says a session runs", "center: the hint says Stop runs",
    "center: a saved answer starts a run", "center: a near-command starts a run", "center: a short text starts a run", "center: Return runs a held Ask",
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


def suite(copy, deadline=None):
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
    code, out, seconds, _ = suite(copy)
    passed = [l for l in out.splitlines() if l.startswith("PASS: setup assistant")]
    print(f"BASELINE (unmutated): exit {code} in {seconds:.0f}s: {' / '.join(passed) or '(no PASS line)'}", flush=True)
    if code != 0 or len(passed) != 2:
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
        lines = [l for l in out.splitlines() if "check failed [" in l or "Setup assistant pin:" in l or ": error:" in l]
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
