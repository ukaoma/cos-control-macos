#!/usr/bin/env python3
"""0.5.325 AI polish: where the pure rules (DictationPolish, DictationPolishBridge) are wired. Each failure names its
behaviour as "pin failed [<behaviour>]". Code only: comments never satisfy a pin. The rules themselves run in
MacDictationChecks and DictationEveryoneChecks, the helper round trip in dictation-polish-helper-checks.py.

    python3 Tests/dictation-polish-pins.py <root>
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
read = lambda p: (root / p).read_text(encoding="utf-8")


def code(text):
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//"))


def pin(ok, behaviour, why):
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")


def between(text, start, end):
    pin(text.count(start) == 1 and end in text.split(start, 1)[1], "source shape", f"cannot find {start!r} .. {end!r} exactly once")
    return text.split(start, 1)[1].split(end, 1)[0]


dictation = code(read("Sources/MacDictation.swift"))
dcore = code(read("Sources/MacDictationCore.swift"))
helper = code(read("HelperSources/main.swift"))
pcore = code(read("HelperSources/ProviderStatusCore.swift"))
app = code(read("Sources/COSControlApp.swift"))

# 1. Polish runs after the engine guard and before lists and delivery, and the dictation re-checks it is still current.
transcribe = between(dictation, "private func transcribe(_ wav: Data, attempt: UUID) {", "private func polish(_ heard: String)")
call = "let polished = await polish(heard)\n                guard generation == attempt, !Task.isCancelled else { return }"
pin(transcribe.count(call) == 1, "current after polish", "the await on polish is followed at once by the generation and cancellation check")
order = [transcribe.find(s) for s in ["DictationEngineName.title(engine) != nil", "let polished = await polish(heard)",
                                      "DictationListFormat.format(said)", "DictationInsertion.deliver(text"]]
pin(-1 not in order and order == sorted(order), "before paste", "engine guard, then polish, then lists, then delivery")
pin("let said = polished?.outcome.text(heard: heard) ?? heard" in transcribe, "heard on failure", "every outcome but applied pastes what was heard")

# 2. The polish step: its own pill, a bounded helper call, a timeout outcome, a log line without text, and never a card.
step = between(dictation, "private func polish(_ heard: String) async -> (outcome: DictationPolish.Outcome, model: DictationPolishModel)? {",
               "private func finish(_ text: String")
pin("DictationPolish.shouldPolish(text: heard, model: model), let budget = DictationPolish.budget(for: model)" in step, "gate", "polish only when the rule says so, with its budget")
pin("try await polishBridge(request, budget)" in step, "budget", "the helper call carries the model's budget")
pin("pill = .polishing" in step and "case .transcribing, .polishing, .finishing:" in dictation, "pill", "the pill shows POLISHING with the working bars")
pin("catch HelperClientError.timedOut {\n            outcome = .timeout" in step, "timeout", "a killed helper reads as a timeout")
pin(not re.search(r"\b(fail|showCard)\(", step) and "throw" not in step.replace("throws", ""), "never a failure", "polish never fails the dictation or shows a card")
logs = [l for l in step.split("\n") if "dictationLog" in l]
pin(len(logs) == 1 and "model.rawValue" in logs[0] and "outcome.logName" in logs[0] and "elapsed" in logs[0]
    and not re.search(r"\\\((heard|text|request|response)\b", logs[0]), "no text logged", "one polish log line: model, outcome and time")

# 3. The record keeps what was heard only when polish applied, and the setting is the dropdown with its honest line.
pin("if case .applied? = polished?.outcome, let model = polished?.model { lastPolish = (heard, model) } else { lastPolish = nil }" in transcribe,
    "heard only when applied", "what was heard is kept only when polish changed the text")
pin("heard: lastPolish?.heard, polishModel: lastPolish?.model.rawValue)" in dictation and "lastEngine = nil; lastPolish = nil" in dictation,
    "record", "finish() stores what was heard and the model, then forgets them")
pin(dictation.count('COSDropdown("AI polish", selection: $store.polishModel,') == 1 and "DictationPolish.settingNote(store.polishModel)" in dictation,
    "setting", "Settings, Dictation: AI polish with its one line")
pin("DictationPolishModel.stored(UserDefaults.standard.string(forKey: DictationPolishModel.defaultsKey))" in dictation
    and "UserDefaults.standard.set(polishModel.rawValue, forKey: DictationPolishModel.defaultsKey)" in dictation, "setting", "the model persists under its key")
pin(dictation.count('"What was heard: " + heard') == 2 and "store.copy(heard)" in dictation, "what was heard", "the detail and the history row offer what was heard")
pin(dictation.count('record.polishLabel.map { " · " + $0 }') == 1, "history label", "the Activity history row says Polished and the model")

# 4. The bridge: the helper verb, stdin only, the budget as the process timeout.
pin(app.count('runHelper(["dictation-polish"], timeout: budget, stdinData: request, answers: true)') == 1, "bridge",
    "Control runs dictation-polish with the budget, and reads its refusals whole (0.5.328)")
pin('skipped: response.details["polishSkipped"]?.string)' in dictation, "skip reason",
    "the server's polishSkipped reaches DictationPolish.choose (0.5.328, server 6.79.1)")
pin(helper.count('case "dictation-polish": try emitDictationPolish()') == 1, "helper verb", "the helper dispatches dictation-polish")
emit = between(helper, "private func emitDictationPolish() throws {", "private func dictate(")
pin("FileHandle.standardInput" in emit and "args" not in emit, "stdin only", "the text arrives on stdin, never argv")
pin("readToken()" in emit and "speakerReviewToken" not in emit, "budget", "no health probe before the request spends the budget")
pin("request(DictationPolishBridge.route," in emit and "deadlineUptime: deadline" in emit and '"/api/' not in emit, "one route", "the fixed finalize route, ending at the deadline")
pin(not re.search(r"\b(progress|print|atomicWrite\w*|write)\(", emit) and "standardError" not in emit, "no text kept", "the helper never logs or writes the text")
pin(emit.count("emit(") == 3, "one answer", "exactly one emit per outcome path (invalid, no token, the answer)")

# 5. Control's budget and the helper's deadline agree: the helper ends half a second inside it.
budget = between(dcore, "static func budget(for model: DictationPolishModel) -> TimeInterval? {", "\n    }")
deadline = between(pcore, "static func requestSeconds(_ model: String) -> TimeInterval? {", "\n    }")
b = dict(re.findall(r"case \.(haiku|sonnet): ([0-9.]+)", budget))
d = dict(re.findall(r'case "(haiku|sonnet)": ([0-9.]+)', deadline))
pin(set(b) == {"haiku", "sonnet"} and set(d) == set(b) and all(abs(float(d[m]) - (float(b[m]) - 0.5)) < 1e-9 for m in b),
    "deadline inside budget", f"helper deadline must be Control's budget less 0.5 s: budget {b}, deadline {d}")
pin(re.search(r"static let maximumCharacters = 8_000", dcore) and re.search(r"static let maximumCharacters = 8_000", pcore), "limit", "both halves use the server's 8,000")

print("PASS dictation polish pins: before the paste, current after the await, bounded, never a failure, no text logged, record and setting, budget agrees")
