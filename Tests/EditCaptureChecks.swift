import Foundation

// 0.5.344 Capture every correction (plan r2, PLAN_dictation_voice_style_2026-10-24.md section 1; QA
// QA_edit_learning_followup_2026-10-24.md fixes #1 to #5 and W2 to W4), executed against fictional fixtures. The watch
// loop itself (DictationEditWatch.watch, moved into MacDictationCore.swift) runs against a fake field and a fake clock:
// every scripted sequence the plan names, the cadence and its idle stop, the staleness guard, the final reads and the
// learning baseline. Then the trigger, the pure rules, the trigger signal, the skipped-watch line and the polish
// "unchanged" mapping. Compiled with Sources/MacDictationCore.swift alone (Tests/run-edit-capture.sh). Nothing is drawn,
// clicked, shown, posted or played; no app is activated. Every check names its behaviour, so
// Tests/mutate-edit-capture.py attributes each kill.

@main struct EditCaptureChecks {
    nonisolated(unsafe) static var ran = 0

    static func check(_ condition: Bool, _ behavior: String, _ detail: @autoclosure () -> String = "", line: UInt = #line) {
        ran += 1
        if !condition { fatalError("check failed [\(behavior)] at line \(line): \(detail())") }
    }
    typealias L = DictationEditLearning
    typealias W = DictationEditWatch

    static func main() async {
        triggerChecks()
        ruleChecks()
        polishChecks()
        promptChecks()
        canaryChecks()
        await signalChecks()
        await startChecks()
        await sequenceChecks()
        await cadenceChecks()
        await baselineChecks()
        countChecks()
        await gapChecks()
        print("PASS edit capture: \(ran) checks; the trigger, the rules, the polish mapping, the canary, the signal, the start, the six sequences, the cadence, the learning baseline, the counts, the gap")
    }

    // MARK: A fake field and a fake clock

    /// One scripted text box. Every field call reads the state at its own start, then takes `cost` seconds. Single task:
    /// the watch awaits each call in turn, so no lock is needed.
    final class World: @unchecked Sendable {
        var time: TimeInterval = 0
        var states: [(at: TimeInterval, text: String, caret: Int)]
        var triggers: [(at: TimeInterval, trigger: L.Trigger)] = []
        var focusLeftAt = TimeInterval.infinity
        var secureFrom = TimeInterval.infinity
        var textNilFrom = TimeInterval.infinity
        var measureNil = false
        /// The field changes right after the first text read from this time on (the app editing it during a read).
        var changeAfterText: (from: TimeInterval, text: String)?
        var cost: TimeInterval = 0.001
        var slowMeasureFrom = TimeInterval.infinity
        var slowCost: TimeInterval = 0.06
        var pauses: [(at: TimeInterval, ms: Int)] = []
        var textReads: [TimeInterval] = []
        var considered = 0
        var logs: [String] = []
        var sunk: [DictationLearnCanary] = []
        /// 0.5.344 part 2: key-downs other than Return (typedKey) and every key-down or click (input), by time.
        var keyTimes: [TimeInterval] = []
        var inputTimes: [TimeInterval] = []
        func typedKey(_ t: TimeInterval) { keyTimes.append(t); inputTimes.append(t) }
        init(_ text: String) { states = [(0, text, text.utf16.count)] }
        func at(_ t: TimeInterval, _ text: String, caret: Int? = nil) { states.append((t, text, caret ?? text.utf16.count)); states.sort { $0.at < $1.at } }
        func tap(_ t: TimeInterval, _ trigger: L.Trigger = .key) { triggers.append((t, trigger)) }
        var state: (text: String, caret: Int) { let s = states.last(where: { $0.at <= time }) ?? states[0]; return (s.text, s.caret) }
        func field() -> W.Field {
            W.Field(measure: { [self] in
                        let s = state, slow = time >= slowMeasureFrom
                        time += slow ? slowCost : cost
                        return measureNil ? DictationFieldSnapshot() : DictationFieldSnapshot(characters: s.text.utf16.count, location: s.caret, length: 0)
                    },
                    text: { [self] location, length in
                        let s = state, gone = time >= textNilFrom
                        textReads.append(time); time += cost
                        if let change = changeAfterText, time >= change.from { states.append((time, change.text, change.text.utf16.count)); changeAfterText = nil }
                        return gone ? nil : DictationOwnField.read(s.text, location: location, length: length)
                    },
                    secure: { [self] in let on = time >= secureFrom; time += cost; return on },
                    focus: { [self] _ in let left = time >= focusLeftAt; time += cost; return (left ? .left("app") : .same, nil) },
                    running: { [self] in time += cost; return true })
        }
        func clock() -> W.Clock {
            W.Clock(now: { [self] in time }, wall: { Date(timeIntervalSince1970: 1_792_900_000.25) },
                    pause: { [self] ms in
                        pauses.append((time, ms))
                        let limit = time + Double(ms) / 1000
                        if let i = triggers.indices.min(by: { triggers[$0].at < triggers[$1].at }), triggers[i].at <= limit {
                            let next = triggers.remove(at: i)
                            time = max(time, next.at)
                            return next.trigger
                        }
                        time = limit
                        return nil
                    },
                    inputs: { [self] in inputTimes.filter { $0 <= time }.count }, keys: { [self] in keyTimes.filter { $0 <= time }.count })
        }
        func run(_ typed: String, learning: Bool = true, monitor: Bool = true) async -> W.Ending {
            await W.run(field(), span: DictationInsertedSpan(pid: 1, location: 0, length: typed.utf16.count), typed: typed, facts: "bundle=test",
                        bundle: "test.fixture", learning: learning, monitor: monitor, clock: clock(),
                        log: { [self] line in logs.append(line) },
                        consider: { [self] _, _, _, _ in considered += 1; return nil },
                        found: { _ in }, sink: { [self] canary in sunk.append(canary) })
        }
    }

    // Fictional dictation and edits only.
    static let typed = "send the deck to jordin by friday"
    static let edited = "send the deck to Jordan Lee by friday"
    static let twice = "send the deck to Jordan Lee by Thursday"
    static let other = "send the slides to Jordan Lee by friday"
    static let sent = "\n"

    // MARK: The trigger

    static func triggerChecks() {
        check(L.sendKeyCodes == [36, 76], "trigger keys", "Return and the keypad's Enter")
        check(L.trigger(keyDown: true, keyCode: 36, isRepeat: false, pointer: false, watching: true, learning: true) == .key
              && L.trigger(keyDown: true, keyCode: 76, isRepeat: false, pointer: false, watching: true, learning: true) == .key,
              "trigger keys", "Return and Enter ask for a read")
        check(L.trigger(keyDown: false, keyCode: 0, isRepeat: false, pointer: true, watching: true, learning: true) == .mouse,
              "trigger click", "any click asks for a read")
        check(L.trigger(keyDown: true, keyCode: 36, isRepeat: false, pointer: false, watching: false, learning: true) == nil
              && L.trigger(keyDown: false, keyCode: 0, isRepeat: false, pointer: true, watching: false, learning: true) == nil,
              "trigger needs a watch", "nothing reaches a watch that is not running")
        check(L.trigger(keyDown: true, keyCode: 36, isRepeat: false, pointer: false, watching: true, learning: false) == nil
              && L.trigger(keyDown: false, keyCode: 0, isRepeat: false, pointer: true, watching: true, learning: false) == nil,
              "trigger needs learning", "learning off hears nothing")
        check(L.trigger(keyDown: true, keyCode: 36, isRepeat: true, pointer: false, watching: true, learning: true) == nil,
              "trigger repeat", "a held Return's auto-repeat is not a new read")
        for key: UInt16 in [0, 9, 48, 51, 53, 123] {
            check(L.trigger(keyDown: true, keyCode: key, isRepeat: false, pointer: false, watching: true, learning: true) == nil,
                  "trigger other keys", "key \(key) is typing, not a read")
        }
        check(L.trigger(keyDown: false, keyCode: 36, isRepeat: false, pointer: false, watching: true, learning: true) == nil,
              "trigger modifiers", "a modifier change (keyDown false) is never a trigger")
        check(L.Trigger.key.rawValue == "key" && L.Trigger.mouse.rawValue == "mouse", "trigger names", "the canary's words")
    }

    // MARK: The pure rules

    static func ruleChecks() {
        check(L.fastTickMilliseconds >= 150 && L.fastTickMilliseconds <= 200, "fast tick range", "\(L.fastTickMilliseconds) ms")
        check(L.quietSeconds == 0.4, "fast quiet", "about 0.4 s of quiet")
        check(L.fastMode(unread: 1, tried: false, fastSeconds: 0, backedOff: false), "fast mode", "a change unread")
        check(!L.fastMode(unread: 0, tried: false, fastSeconds: 0, backedOff: false), "fast mode idle", "nothing unread: no fast ticks")
        check(!L.fastMode(unread: 2, tried: true, fastSeconds: 0, backedOff: false), "fast mode tried", "its read was tried")
        check(!L.fastMode(unread: 1, tried: false, fastSeconds: 0, backedOff: true), "fast mode backoff", "a slow tick")
        check(!L.fastMode(unread: 1, tried: false, fastSeconds: 10, backedOff: false) && L.fastMode(unread: 1, tried: false, fastSeconds: 9.9, backedOff: false),
              "fast mode cap", "10 s of fast ticking a watch")
        check(L.wait(fastMode: false, sinceFullPoll: 0) == 500 && L.wait(fastMode: false, sinceFullPoll: 0.2) == 300
              && L.wait(fastMode: true, sinceFullPoll: 0) == L.fastTickMilliseconds && L.wait(fastMode: true, sinceFullPoll: 0.4) == 100
              && L.wait(fastMode: false, sinceFullPoll: 0.7) == 0, "wait", "until the 500 ms poll, or one fast tick if sooner")
        check(L.fullPollDue(sinceFullPoll: 0.5) && L.fullPollDue(sinceFullPoll: 0.496) && !L.fullPollDue(sinceFullPoll: 0.4), "full poll due", "500 ms, 5 ms slack")
        check(L.trackerReadDue(unread: 1, tried: false, quietFor: 0.4) && !L.trackerReadDue(unread: 1, tried: false, quietFor: 0.39)
              && !L.trackerReadDue(unread: 0, tried: false, quietFor: 3) && !L.trackerReadDue(unread: 1, tried: true, quietFor: 3),
              "tracker read due", "one read per change, after 0.4 s of quiet")
        check(L.looksSent(fieldCharacters: 1, dictationLength: 30) && L.looksSent(fieldCharacters: 0, dictationLength: 30)
              && !L.looksSent(fieldCharacters: 2, dictationLength: 30) && !L.looksSent(fieldCharacters: 1, dictationLength: 1),
              "looks sent", "an empty newline under a longer dictation")
        check(!L.changeCounts(at: .cleared) && !L.changeCounts(at: .emptied) && L.changeCounts(at: .focusLeft) && L.changeCounts(at: .cap),
              "change at stop", "the send is not an unread edit; anything else is")
        check(L.readsAtStop(.focusLeft, unread: 1, fieldCharacters: 30) && L.readsAtStop(.cap, unread: 1, fieldCharacters: 30)
              && L.readsAtStop(.reads, unread: 1, fieldCharacters: 30), "final read at stop", "focus left or a cap with a change unread")
        check(!L.readsAtStop(.focusLeft, unread: 0, fieldCharacters: 30) && !L.readsAtStop(.focusLeft, unread: 1, fieldCharacters: 1)
              && !L.readsAtStop(.cleared, unread: 1, fieldCharacters: 30) && !L.readsAtStop(.secure, unread: 1, fieldCharacters: 30)
              && !L.readsAtStop(.focusLeft, unread: 1, fieldCharacters: nil), "final read at stop limits", "nothing unread, sent, secure or unreadable")
        check(L.finalTrigger(at: .focusLeft) == "focus" && L.finalTrigger(at: .cap) == "cap" && L.finalTrigger(at: .reads) == "cap", "final trigger names", "focus, cap")
        check(L.finalReadAllowed(sinceLast: nil, finalReads: 0) && L.finalReadAllowed(sinceLast: 0.3, finalReads: 1) && !L.finalReadAllowed(sinceLast: 0.29, finalReads: 1),
              "final read spacing", "one per 300 ms")
        check(L.maximumFinalReads == 20 && !L.finalReadAllowed(sinceLast: 5, finalReads: L.maximumFinalReads), "final read cap", "a cap of their own")
        let inserted = DictationDeliveryOutcome.inserted(app: "Fixture", viaPaste: true)
        check(L.unwatched(learnOff: false, outcome: inserted, hasTarget: true) == nil
              && L.unwatched(learnOff: false, outcome: inserted, hasTarget: false) == "noTarget"
              && L.unwatched(learnOff: false, outcome: inserted, hasTarget: true, newer: true) == "superseded"
              && L.unwatched(learnOff: false, outcome: inserted, hasTarget: true, swapWatches: false) == "mismatch"
              && L.unwatched(learnOff: false, outcome: .unconfirmed(app: "Fixture", viaPaste: true), hasTarget: true) == "unconfirmed"
              && L.unwatched(learnOff: false, outcome: .refused(.noTextBox), hasTarget: false) == nil
              && L.unwatched(learnOff: true, outcome: inserted, hasTarget: false) == nil,
              "unwatched", "why a typed dictation got no watch; nothing for a copy or with learning off")
        check(DictationEditConfirm.captured(typed: typed, window: edited, start: 0, length: edited.utf16.count, inside: 1, readable: true, learning: true,
                                            stop: "cleared", unread: 0) == edited
              && DictationEditConfirm.captured(typed: typed, window: edited, start: 0, length: edited.utf16.count, inside: 1, readable: true, learning: true,
                                               stop: "cleared", unread: 1) == nil, "captured stale", "a change unread keeps nothing (W2)")
    }

    // MARK: The polish "unchanged" mapping (plan r2 contract)

    static func polishChecks() {
        typealias P = DictationPolish
        let heard = "um so the plan is ready"
        check(P.serverOutcomes == ["polished", "unchanged", "guarded"], "polish outcomes", "the three words read")
        check(P.choose(heard: heard, ok: true, text: heard, polished: false, reason: nil) == .unchanged
              && P.choose(heard: heard, ok: true, text: heard, polished: false, reason: nil).logName == "unchanged",
              "polish unchanged", "an older server's same words back are unchanged, not failed:not_polished")
        check(P.choose(heard: heard + " ", ok: true, text: heard, polished: false, reason: nil) == .unchanged, "polish unchanged trimmed",
              "the server trims before it compares")
        check(P.choose(heard: heard, ok: true, text: "So the plan is ready.", polished: false, reason: nil) == .failed("not_polished"),
              "polish not polished", "other words with polished false are still not Claude's")
        check(P.choose(heard: heard, ok: true, text: heard, polished: false, reason: nil, skipped: "quota; rm") == .failed("not_polished"),
              "polish unknown skip", "an unknown skip word is not called unchanged")
        check(P.choose(heard: heard, ok: true, text: heard, polished: false, reason: nil, polishOutcome: "unchanged") == .unchanged,
              "polish outcome unchanged", "the server says unchanged and the words are what was heard")
        let cleaned = "so the plan is ready"
        let fillers = P.choose(heard: heard, ok: true, text: cleaned, polished: true, reason: nil, polishOutcome: "unchanged")
        check(fillers == .fillersOnly("unchanged", text: cleaned) && fillers.text(heard: heard) == cleaned && fillers.logName == "fillers_only:unchanged",
              "polish fillers removed, model unchanged", "the cleaned text goes out, never the um back, never called polished")
        check(P.choose(heard: heard, ok: true, text: heard, polished: true, reason: nil, polishOutcome: "unchanged") == .unchanged,
              "polish outcome unchanged same", "unchanged and the same words")
        check(P.choose(heard: heard, ok: true, text: heard, polished: false, reason: nil, polishOutcome: "polished") == .failed("not_polished"),
              "polish outcome contradiction", "polished false is trusted over the word")
        check(P.choose(heard: heard, ok: true, text: "So the plan is ready.", polished: true, reason: nil, polishOutcome: "polished") == .applied("So the plan is ready."),
              "polish outcome polished", "a polished answer is applied")
        check(P.choose(heard: heard, ok: true, text: heard, polished: false, reason: nil, polishOutcome: "guarded") == .skipped("guarded")
              && P.choose(heard: heard, ok: true, text: cleaned, polished: true, reason: nil, polishOutcome: "guarded") == .fillersOnly("guarded", text: cleaned),
              "polish guarded", "a guarded answer is never Claude's polish")
        check(P.choose(heard: heard, ok: true, text: heard, polished: false, reason: nil, skipped: "failed", polishOutcome: "guarded") == .skipped("failed"),
              "polish guarded skip wins", "6.91.0's polishSkipped failed is what an old Control also reads")
        check(P.choose(heard: heard, ok: true, text: "So the plan is ready.", polished: true, reason: nil, polishOutcome: "weird") == .applied("So the plan is ready.")
              && P.choose(heard: heard, ok: true, text: heard, polished: false, reason: nil, skipped: "daily_cap", polishOutcome: "unchanged") == .skipped("daily_cap"),
              "polish outcome closed", "an unknown word is ignored; a known skip still wins")
    }

    // MARK: The polish prompt (contract addition: polishPrompt v3 or v4, the card labels only v4)

    static func promptChecks() {
        typealias P = DictationPolish
        check(P.promptVersions == ["v3", "v4"] && P.promptVersion("v4") == "v4" && P.promptVersion("v3") == "v3",
              "polish prompt versions", "v3 and v4 read")
        check(P.promptVersion("v5") == nil && P.promptVersion("V4") == nil && P.promptVersion("") == nil && P.promptVersion(nil) == nil,
              "polish prompt closed", "anything else reads as none")
        let at = Date(timeIntervalSince1970: 1_792_900_000)
        func record(_ prompt: String?, model: String? = "sonnet", heard: String? = "um hi") -> DictationRecord {
            DictationRecord(id: UUID(), text: "Hi.", createdAt: at, delivery: .inserted(app: "Fixture"), heard: heard, polishModel: model, polishPrompt: prompt)
        }
        check(record("v4").polishLabel == "Polished · Sonnet · v4", "card label v4", "\(String(describing: record("v4").polishLabel))")
        check(record("v3").polishLabel == "Polished · Sonnet" && record(nil).polishLabel == "Polished · Sonnet"
              && record("v4", model: "haiku").polishLabel == "Polished · Haiku · v4", "card label v3 unlabelled", "v3 and an older server read as before")
        check(record("v4", heard: nil).polishLabel == nil, "card label v4", "no polish, no label")
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let round = (try? encoder.encode(record("v4"))).flatMap { try? decoder.decode(DictationRecord.self, from: $0) }
        check(round?.polishPrompt == "v4" && round?.polishLabel == "Polished · Sonnet · v4", "record prompt", "the prompt survives the history file")
        let old = #"{"id":"0A1B2C3D-0000-4000-8000-000000000001","text":"Hi.","createdAt":0,"kind":"inserted","app":"Fixture","heard":"um hi","polishModel":"sonnet"}"#
        let odd = #"{"id":"0A1B2C3D-0000-4000-8000-000000000002","text":"Hi.","createdAt":0,"kind":"inserted","app":"Fixture","heard":"um hi","polishModel":"sonnet","polishPrompt":"v9"}"#
        let oldRecord = try? decoder.decode(DictationRecord.self, from: Data(old.utf8)), oddRecord = try? decoder.decode(DictationRecord.self, from: Data(odd.utf8))
        check(oldRecord != nil && oldRecord?.polishPrompt == nil && oddRecord != nil && oddRecord?.polishPrompt == nil, "record prompt",
              "an older file reads, and an unknown prompt reads as none")
        let base = record(nil, heard: nil)
        let polished = DictationHistory.polishing(base.id, to: "Hi there.", heard: "um hi there", model: "sonnet", prompt: "v4", in: [base])
        let corrected = DictationHistory.correcting(base.id, to: "Hi there!", in: polished)
        let edited = DictationHistory.editing(base.id, edit: DictationUserEdit(text: "Hi there!!", app: "Fixture", at: at, edits: 1), in: polished)
        check(polished.first?.polishPrompt == "v4" && corrected.first?.polishPrompt == "v4" && edited.first?.polishPrompt == "v4",
              "history keeps the prompt", "the swap writes it; Fix a word and an edit keep it")
        check(DictationHistory.polishing(base.id, to: "x", heard: "y", model: "sonnet", prompt: "v9", in: [base]).first?.polishPrompt == nil,
              "polish prompt closed", "the swap writes only v3 or v4")
        var timing = DictationTiming.measure(pcm: Data(count: 64_000), releaseBytes: 60_000, tailMs: 300, releaseToClosedMs: 330, at: at)
        var run = DictationPolishRun(outcome: .applied("Hi."), model: .sonnet, ms: 900)
        run.prompt = "v4"
        timing.includePolish(run)
        let line = DictationTimingLog.line(timing).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        check(timing.polishPrompt == "v4" && line.contains("\"polishPrompt\":\"v4\""), "timing prompt", "the timing line carries polishPrompt")
        run.prompt = "v9"
        timing.includePolish(run)
        check(timing.polishPrompt == nil, "timing prompt", "only v3 or v4 reaches the line")
    }

    // MARK: The canary

    static func canaryChecks() {
        let at = DictationLearnCanary.stamp(Date(timeIntervalSince1970: 1_792_900_000.25))
        check(at.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$", options: .regularExpression) != nil && at.hasSuffix(".250Z"),
              "canary ms stamp", at)
        let row = DictationLearnCanary.skipped("mismatch", bundle: "test.fixture", at: Date(timeIntervalSince1970: 1_792_900_000))
        let line = DictationLearnCanaryLog.line(row).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let keys = Set((try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?.keys.map { $0 } ?? [])
        check(row.stop == "skipped" && row.eligibility == "skip" && row.skip == "mismatch" && row.reads == 0 && !row.readable,
              "skip row", "a typed dictation that got no watch says why")
        check(keys == ["at", "bundle", "eligibility", "readable", "reads", "stop", "rebinds", "reanchors", "inside", "candidates", "learned", "skip"],
              "skip row fields", "\(keys.sorted())")
        check(!DictationLearnCanary.recordsSkip("off") && DictationLearnCanary.recordsSkip("secure") && DictationLearnCanary.recordsSkip("mismatch"),
              "skip row off", "learning off writes nothing")
    }

    // MARK: The trigger signal (real time, a few milliseconds)

    static func signalChecks() async {
        let early = DictationWatchSignal()
        early.fire(.mouse)
        let kept = await early.pause(5_000)
        check(kept == .mouse, "signal kept", "a trigger between pauses wakes the next one at once")
        let quiet = DictationWatchSignal()
        let t0 = Date()
        let none = await quiet.pause(30)
        check(none == nil && Date().timeIntervalSince(t0) >= 0.025, "signal timeout", "no trigger: the pause runs out")
        let waking = DictationWatchSignal()
        let t1 = Date()
        Task.detached { try? await Task.sleep(for: .milliseconds(20)); waking.fire(.key) }
        let woke = await waking.pause(5_000)
        check(woke == .key && Date().timeIntervalSince(t1) < 2, "signal wakes", "a trigger cuts the pause short: \(Date().timeIntervalSince(t1)) s")
        let closed = DictationWatchSignal()
        closed.close(); closed.fire(.key)
        let t2 = Date()
        let after = await closed.pause(5_000)
        check(after == nil && Date().timeIntervalSince(t2) < 1, "signal closed", "an ended watch hears nothing and never waits")
    }

    // MARK: The start

    static func startChecks() async {
        let gone = World(sent)
        let a = await gone.run(typed)
        check(a.canary.stop == "sentBeforeWatch" && a.canary.step == "count" && gone.textReads.isEmpty && a.final == nil,
              "sent before watch", "\(a.canary.stop) \(String(describing: a.canary.step)) reads \(gone.textReads.count)")
        let blind = World(typed); blind.measureNil = true
        let b = await blind.run(typed)
        check(b.canary.stop == "unreadable" && b.canary.step == "count", "start steps", "the count failed")
        let noText = World(typed); noText.textNilFrom = 0
        let c = await noText.run(typed)
        check(c.canary.stop == "unreadable" && c.canary.step == "text", "start steps", "the window failed")
        let moved = World("a different note entirely about lunch plans")
        let d = await moved.run(typed)
        check(d.canary.stop == "unreadable" && d.canary.step == "anchor", "start steps", "the dictation is not in the window")
        check(a.canary.monitor == "present" && d.canary.ms != nil && d.canary.axCalls == 2, "canary start fields", "monitor, ms, two field calls")
        let absent = World(typed); absent.focusLeftAt = 0.4
        let e = await absent.run(typed, monitor: false)
        check(e.canary.monitor == "absent" && e.canary.finalRead == "none" && e.canary.partial == 0 && e.canary.stop == "focusLeft"
              && absent.sunk.count == 1 && absent.sunk[0] == e.canary, "canary sink", "every watch hands its one line to the sink")
    }

    // MARK: The six sequences (plan r2)

    static func sequenceChecks() async {
        // 1. Edit, then Return in under 0.4 s (before any poll saw the edit). The read at the key keeps it.
        let quick = World(typed)
        quick.at(1.05, edited); quick.tap(1.25); quick.at(1.30, sent)
        let one = await quick.run(typed)
        check(one.final == edited && one.canary.finalRead == "held" && one.canary.finalTrigger == "key" && one.canary.stop == "cleared"
              && one.canary.partial == 0 && one.canary.edited == true, "edit then Return under 0.4 s",
              "final \(String(describing: one.final)) \(String(describing: one.canary.finalRead)) \(one.canary.stop)")
        check(one.canary.reads == 1 && one.canary.inside == 0, "a final read is never learned from", "reads \(one.canary.reads) inside \(one.canary.inside)")

        // 2. Edit, then Return after 1 s: the tracker read about 0.4 s after the change already holds it.
        let later = World(typed)
        later.at(1.05, edited); later.tap(2.1); later.at(2.15, sent)
        let two = await later.run(typed)
        check(two.final == edited && two.canary.trackerReads == 1 && two.canary.finalRead == "held" && two.canary.partial == 0,
              "edit then Return after 1 s", "final \(String(describing: two.final)) trackerReads \(String(describing: two.canary.trackerReads))")

        // 3. Shift+Return is "read now", never "sent": the watch goes on and keeps the edit made after it.
        let shift = World(typed)
        shift.at(1.05, edited); shift.tap(1.2); shift.at(1.205, edited + "\n"); shift.at(1.6, twice + "\n"); shift.tap(2.5); shift.at(2.55, sent)
        let three = await shift.run(typed)
        // The newline Shift+Return added rides at the span's end when one read sees it and the next edit together (the
        // word diff's rule since 0.5.338); the words are what was sent.
        check(three.final?.trimmingCharacters(in: .whitespacesAndNewlines) == twice && three.canary.finalReads == 2 && three.canary.stop == "cleared",
              "Shift+Return", "final \(String(describing: three.final)) finalReads \(String(describing: three.canary.finalReads)) \(three.canary.stop)")

        // 4. Edit, then clear: the second edit was seen and never read, so nothing is kept, never the first (W2).
        let clear = World(typed)
        clear.at(0.8, edited); clear.at(1.9, other); clear.at(2.1, sent)
        let four = await clear.run(typed)
        check(four.final == nil && four.canary.partial == 1 && (four.canary.unreadChanges ?? 0) > 0 && four.canary.edited == false,
              "a change unread at the end keeps nothing", "final \(String(describing: four.final)) partial \(String(describing: four.canary.partial))")
        // And an edit read before the field was emptied is kept (emptied, nothing unread).
        let wiped = World(typed)
        wiped.at(1.05, edited); wiped.at(2.6, "")
        let wipedEnd = await wiped.run(typed)
        check(wipedEnd.final == edited && wipedEnd.canary.stop == "emptied" && wipedEnd.canary.partial == 0, "edit then clear after a read",
              "final \(String(describing: wipedEnd.final)) \(wipedEnd.canary.stop)")

        // 5. Focus left with the edit seen but not yet read: one last read keeps it.
        let away = World(typed)
        away.at(1.05, edited); away.focusLeftAt = 1.6
        let five = await away.run(typed)
        check(five.final == edited && five.canary.stop == "focusLeft" && five.canary.finalTrigger == "focus" && five.canary.finalRead == "held",
              "focus left: one last read keeps the edit", "final \(String(describing: five.final)) trigger \(String(describing: five.canary.finalTrigger))")
        // Focus left after the message went: no read (the text is gone).
        let gone = World(typed)
        gone.at(1.05, edited); gone.at(1.3, sent); gone.focusLeftAt = 1.4
        let goneEnd = await gone.run(typed)
        check(goneEnd.canary.finalRead == "none" && goneEnd.final == nil, "focus left after a send reads nothing",
              "\(String(describing: goneEnd.canary.finalRead))")

        // 6. An inconsistent read: the field changed between the two counts (right after the text read), so the read is
        // discarded, whatever else the read does first.
        let shaky = World(typed)
        shaky.at(1.05, edited); shaky.tap(1.25); shaky.changeAfterText = (1.2, sent)
        let six = await shaky.run(typed)
        check(six.canary.finalRead == "inconsistent" && six.final == nil, "an inconsistent read is discarded",
              "\(String(describing: six.canary.finalRead)) final \(String(describing: six.final))")

        // A final read leaves nothing unread: ⌘Return the app ignores reads the edit, then the app sends a moment later.
        let marker = World(typed)
        marker.at(1.05, edited); marker.tap(1.25); marker.at(1.55, sent)
        let nine = await marker.run(typed)
        check(nine.final == edited && nine.canary.partial == 0, "a final read leaves nothing unread",
              "final \(String(describing: nine.final)) partial \(String(describing: nine.canary.partial))")

        // Secure input at the key: nothing is read.
        let locked = World(typed)
        locked.at(1.05, edited); locked.secureFrom = 1.2; locked.tap(1.25)
        let seven = await locked.run(typed)
        check(seven.canary.secureInput == "on" && seven.canary.finalRead == "none" && seven.canary.stop == "secure" && seven.final == nil,
              "secure input is never read", "\(String(describing: seven.canary.secureInput)) \(String(describing: seven.canary.finalRead)) \(seven.canary.stop)")

        // Final reads are spaced: four clicks, two reads.
        let clicks = World(typed)
        clicks.tap(1.10, .mouse); clicks.tap(1.20, .mouse); clicks.tap(1.35, .mouse); clicks.tap(1.70, .mouse); clicks.focusLeftAt = 2.2
        let eight = await clicks.run(typed)
        check(eight.canary.finalReads == 2 && eight.canary.finalTrigger == "mouse", "final reads: at most one per 300 ms",
              "finalReads \(String(describing: eight.canary.finalReads))")
    }

    // MARK: The cadence and its idle stop

    static func cadenceChecks() async {
        // Nothing changes for ten seconds: 500 ms polls only, no fast tick, no read after the first.
        let idle = World(typed); idle.focusLeftAt = 10
        let a = await idle.run(typed)
        check(idle.pauses.allSatisfy { $0.ms >= 490 } && a.canary.fastTicks == 0 && idle.textReads.count == 1 && (a.canary.polls ?? 0) >= 19,
              "idle: no fast ticks while nothing changes", "pauses \(idle.pauses.map(\.ms).sorted().prefix(3)) fastTicks \(String(describing: a.canary.fastTicks))")
        check(a.canary.axCalls == 2 + 4 * (a.canary.polls ?? 0), "idle: four field calls a poll", "axCalls \(String(describing: a.canary.axCalls))")

        // A change: ticks every 175 ms (measure only) until the tracker read about 0.4 s later, then 500 ms again.
        let busy = World(typed); busy.at(1.05, edited); busy.focusLeftAt = 4
        let b = await busy.run(typed)
        let seenAt = busy.pauses.first { $0.at > 1.5 }?.at ?? 0
        let fast = busy.pauses.filter { $0.at > 1.5 && $0.at < 1.95 }.map(\.ms)
        check(fast.count >= 2 && fast.prefix(2).allSatisfy { $0 == L.fastTickMilliseconds }, "fast: ticks every 175 ms while a change is unread", "\(fast)")
        let read = busy.textReads.first { $0 > 1.5 } ?? 0
        check(read - seenAt >= L.quietSeconds - 0.01 && read - seenAt <= L.quietSeconds + 0.2, "fast: the tracker read lands about 0.4 s after the change",
              "seen \(seenAt) read \(read)")
        check(busy.pauses.filter { $0.at > read + 0.01 && $0.at < 3.4 }.allSatisfy { $0.ms >= 300 }, "fast: back to 500 ms once read",
              "\(busy.pauses.filter { $0.at > read }.map(\.ms))")
        check((b.canary.fastTicks ?? 0) >= 2 && (b.canary.fastTicks ?? 0) <= 3 && b.canary.focusWhy == "app", "fast ticks measure only",
              "fastTicks \(String(describing: b.canary.fastTicks))")

        // A tracker read that fails is not retried at speed: one read, then 500 ms polls until the learning read.
        let flaky = World(typed); flaky.at(1.05, edited); flaky.textNilFrom = 1.9
        let c = await flaky.run(typed)
        let firstFail = flaky.textReads.first { $0 > 1.9 } ?? 0
        check(c.canary.stop == "unreadable" && c.canary.step == "read"
              && flaky.pauses.filter { $0.at > firstFail + 0.01 }.allSatisfy { $0.ms >= 300 }
              && flaky.textReads.filter { $0 > 1.9 && $0 < 3.2 }.count == 1, "fast ticking stops once its read was tried",
              "pauses after \(flaky.pauses.filter { $0.at > firstFail }.map(\.ms)) reads \(flaky.textReads)")

        // A slow tick (60 ms) ends fast ticking for the watch; the read still comes at the next quiet poll.
        let slow = World(typed); slow.at(1.05, edited); slow.slowMeasureFrom = 1.6; slow.focusLeftAt = 3
        let d = await slow.run(typed)
        check(d.canary.fastTicks == 1 && d.canary.fastBackoff == true && d.final == edited, "fast: a slow tick ends fast ticking",
              "fastTicks \(String(describing: d.canary.fastTicks)) backoff \(String(describing: d.canary.fastBackoff))")

        // Changes that never stop: at most 10 s of fast ticking.
        let typing = World(typed)
        var t = 1.0, flip = false
        while t < 25 { typing.at(t, edited, caret: flip ? 5 : 6); flip.toggle(); t += 0.3 }
        typing.focusLeftAt = 26
        let e = await typing.run(typed)
        let ticks = e.canary.fastTicks ?? 0
        check(ticks >= 30 && ticks <= 45 && typing.pauses.filter { $0.at > 14 && $0.at < 25 }.allSatisfy { $0.ms >= 300 },
              "fast: at most 10 s of fast ticking a watch", "fastTicks \(ticks)")
    }

    // MARK: Two states: the learning baseline moves only on the 1.5 s read

    static func baselineChecks() async {
        // The tracker read (a full poll's) already holds the edit; the learning read 1.5 s after it still sees the edit.
        let poll = World(typed); poll.at(1.05, edited); poll.focusLeftAt = 4
        let a = await poll.run(typed)
        check(a.canary.trackerReads == 1 && a.canary.reads == 2 && a.canary.inside == 1 && poll.considered == 1 && a.final == edited,
              "learning baseline moves only on the 1.5 s read", "reads \(a.canary.reads) inside \(a.canary.inside) considered \(poll.considered)")
        // The same with the tracker read on a fast tick (a second change seen by a tick).
        let tick = World(typed); tick.at(1.05, edited); tick.at(1.6, twice); tick.focusLeftAt = 4.2
        let b = await tick.run(typed)
        check(b.canary.trackerReads == 1 && b.canary.reads == 2 && b.canary.inside == 1 && tick.considered == 1 && b.final == twice,
              "learning baseline moves only on the 1.5 s read (tick)", "reads \(b.canary.reads) inside \(b.canary.inside) considered \(tick.considered)")
        // The log carries counts and codes, never the words.
        for line in poll.logs + tick.logs {
            check(!line.contains("jordin") && !line.contains("Jordan") && !line.contains("deck"), "privacy", line)
        }
    }

    // MARK: The counts and the gap (0.5.344 part 2)

    static func countChecks() {
        check(L.countsAsInput(keyDown: true, pointer: false, watching: true, learning: true, inApp: true)
              && L.countsAsInput(keyDown: false, pointer: true, watching: true, learning: true, inApp: true), "counts input", "a key-down or a click")
        check(!L.countsAsInput(keyDown: false, pointer: false, watching: true, learning: true, inApp: true), "counts input", "a modifier change is no input")
        check(!L.countsAsInput(keyDown: true, pointer: true, watching: true, learning: true, inApp: false), "counts in the app", "another app's keys never count")
        check(!L.countsAsInput(keyDown: true, pointer: true, watching: false, learning: true, inApp: true)
              && !L.countsAsInput(keyDown: true, pointer: true, watching: true, learning: false, inApp: true), "counts while watching", "only during a watch, learning on")
        check(L.countsAsTypedKey(keyDown: true, keyCode: 0, watching: true, learning: true, inApp: true)
              && L.countsAsTypedKey(keyDown: true, keyCode: 51, watching: true, learning: true, inApp: true), "counts typed keys", "letters and Delete")
        check(!L.countsAsTypedKey(keyDown: true, keyCode: 36, watching: true, learning: true, inApp: true)
              && !L.countsAsTypedKey(keyDown: true, keyCode: 76, watching: true, learning: true, inApp: true), "counts typed keys", "Return and Enter are not typing")
        check(!L.countsAsTypedKey(keyDown: false, keyCode: 0, watching: true, learning: true, inApp: true)
              && !L.countsAsTypedKey(keyDown: true, keyCode: 0, watching: true, learning: true, inApp: false), "counts typed keys", "key-downs in the app only")
        check(L.goneAfterTyping(.gone, keysSinceRead: 1) && !L.goneAfterTyping(.gone, keysSinceRead: 0) && !L.goneAfterTyping(.held, keysSinceRead: 3)
              && !L.goneAfterTyping(.inconsistent, keysSinceRead: 3), "gap rule", "gone, after a key typed since the last read")
        let signal = DictationWatchSignal()
        signal.count(input: true, typedKey: true); signal.count(input: true, typedKey: false); signal.count(input: false, typedKey: false)
        check(signal.inputs == 2 && signal.keys == 1, "signal counts", "inputs \(signal.inputs) keys \(signal.keys)")
        signal.close(); signal.count(input: true, typedKey: true)
        check(signal.inputs == 2 && signal.keys == 1, "signal counts", "an ended watch counts nothing")
    }

    static func gapChecks() async {
        // Keys typed after the last read that placed the dictation (the tracker read about 0.4 s after the poll saw the
        // edit, near 1.9 s), then Return finds the message already sent: that typing may hold an edit no read saw, so
        // nothing is kept (partial).
        let typedOn = World(typed)
        typedOn.at(1.05, edited); typedOn.typedKey(2.3); typedOn.typedKey(2.35); typedOn.at(2.6, sent); typedOn.tap(2.6)
        let gap = await typedOn.run(typed)
        check(gap.canary.trackerReads == 1 && gap.canary.finalRead == "gone" && gap.final == nil && gap.canary.partial == 1 && gap.canary.keysAfterRead == 2,
              "gone after typing keeps nothing", "\(String(describing: gap.canary.finalRead)) final \(String(describing: gap.final)) partial \(String(describing: gap.canary.partial)) keys \(String(describing: gap.canary.keysAfterRead))")
        check(gap.canary.inputEvents == 2, "watch counts inputs", "inputs \(String(describing: gap.canary.inputEvents))")
        // The same ending with no typing after the read keeps the edit the read saw.
        let still = World(typed)
        still.at(1.05, edited); still.at(2.6, sent); still.tap(2.6)
        let kept = await still.run(typed)
        check(kept.canary.trackerReads == 1 && kept.canary.finalRead == "gone" && kept.final == edited && kept.canary.partial == 0 && kept.canary.keysAfterRead == 0,
              "gone with no typing keeps the read edit", "\(String(describing: kept.canary.finalRead)) final \(String(describing: kept.final)) partial \(String(describing: kept.canary.partial)) stop \(kept.canary.stop) tracker \(String(describing: kept.canary.trackerReads)) unread \(String(describing: kept.canary.unreadChanges)) finals \(String(describing: kept.canary.finalReads)) age \(String(describing: kept.canary.lastReadAgeMs))")
        // Typing before the read that placed the dictation is already in that read.
        let early = World(typed)
        early.typedKey(1.0); early.at(1.05, edited); early.at(2.6, sent); early.tap(2.6)
        let before = await early.run(typed)
        check(before.final == edited && before.canary.partial == 0 && before.canary.keysAfterRead == 0, "typing before the read counts nothing",
              "final \(String(describing: before.final)) keys \(String(describing: before.canary.keysAfterRead))")
        check(before.canary.inputEvents == 1, "watch counts inputs", "inputs \(String(describing: before.canary.inputEvents))")
        // A read that holds after typing: the read saw it, so nothing is unread.
        let heldAfter = World(typed)
        heldAfter.at(1.05, edited); heldAfter.typedKey(2.3); heldAfter.tap(2.35); heldAfter.at(2.5, sent)
        let held = await heldAfter.run(typed)
        check(held.canary.finalRead == "held" && held.final == edited && held.canary.partial == 0, "held after typing keeps the edit",
              "\(String(describing: held.canary.finalRead)) final \(String(describing: held.final))")
        // An edit found by re-anchoring at the start (made while polish ran) is marked, so it is never style evidence.
        let polished = World("send the deck over to jordin by friday"); polished.focusLeftAt = 1.0
        let re = await polished.run(typed)
        check(re.canary.reanchors == 1 && re.tail.startReanchor, "start reanchor marked", "reanchors \(re.canary.reanchors) mark \(re.tail.startReanchor)")
        check(!kept.tail.startReanchor, "start reanchor marked", "a dictation found where it was typed is not marked")
    }
}
