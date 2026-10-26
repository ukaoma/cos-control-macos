#!/usr/bin/env python3
"""0.5.317 dictation for everyone: where the pure rules are wired. Each failure names its behaviour as
"pin failed [<behaviour>]" for Tests/mutate-dictation-everyone.py. Code only: comments never satisfy a pin.

    python3 Tests/dictation-everyone-pins.py <root>
"""
import json, pathlib, re, sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
read = lambda p: (root / p).read_text(encoding="utf-8")


def code(text):
    return "\n".join(l for l in text.split("\n") if not l.strip().startswith("//"))


def pin(ok, behaviour, why):
    if not ok:
        sys.exit(f"pin failed [{behaviour}]: {why}")


def between(text, start, end):
    pin(start in text and end in text.split(start, 1)[1], "source shape", f"cannot find {start!r} .. {end!r}")
    return text.split(start, 1)[1].split(end, 1)[0]


dictation = code(read("Sources/MacDictation.swift"))
helper = code(read("HelperSources/main.swift"))
core = code(read("HelperSources/ProviderStatusCore.swift"))
app = code(read("Sources/COSControlApp.swift"))
model = code(read("Sources/ControllerModel.swift"))
views = code(read("Sources/Views.swift"))
ask = code(read("Sources/MeetingAsk.swift"))
askcore = code(read("Sources/MeetingAskCore.swift"))
connect = code(read("Sources/ProviderConnectModel.swift"))
connectviews = code(read("Sources/ProviderConnectViews.swift"))
release = read("scripts/build-release.sh")

# 1. Dictation accepts any local engine the helper let through; the hard Parakeet check is gone from the app.
transcribe = between(dictation, "private func transcribe(_ wav: Data, attempt: UUID) {", "private func finish(_ text: String")
pin('== "parakeet-ultra"' not in transcribe and "DictationEngineName.title(engine) != nil" in transcribe, "any local engine",
    "the app accepts the helper's engine (Parakeet Ultra or Whisper), not only parakeet-ultra")
pin("engine: lastEngine?.engine, fallbackReason: lastEngine?.fallback" in dictation, "engine recorded", "each dictation stores which engine ran")
pin("DictationProof.record(engine: engine" in transcribe, "proof recorded", "a transcribed dictation is the Voice row's proof")

# 2. The helper routes through the one gate, for both the dictation and its check.
# 0.5.345 (A-W0d): the capabilities answer is optional now (no answer is "Server stopped", DictationBridge.capabilityRefusal).
pin(helper.count("DictationBridge.route(capabilities?.body)") == 1 and helper.count("DictationBridge.capabilityRefusal(status: capabilities?.status, body: capabilities?.body)") == 1
    and "requiredEngine=parakeet-ultra" not in helper and "requiredEngine=local" not in helper,
    "one gate", "mac-dictation and dictation-check share dictate(); the routes live only in DictationBridge")
pin(between(helper, "private func emitMacDictation() throws {", "private func dictate(").count("try dictate(audio)") == 1, "one gate", "mac-dictation uses dictate()")
pin("let answer = try dictate(utterance)" in helper and "DictationCheckSample.singleUtterance(try Data(contentsOf: sample))" in helper, "check is real", "dictation-check posts one utterance of the pinned sample through the same round trip")
pin('"desktopDictationVersions"' in core and 'capabilities["desktopDictationVersion"] as? Int == 1' in core, "gate compat",
    "version 1 is still required and 2 is read from desktopDictationVersions")

# 3. The failure card's one action, and Retry only while it can work.
card = between(dictation, "case .failed(_, let action):", ".frame(width: size.length(300)")
pin("action != .retry || store.canRetry" in card and "store.performFailureAction(action)" in card, "one action", "the card shows the action's button; Retry only with held audio")
pin("Privacy_Microphone" in dictation and dictation.count("Privacy_Microphone") == 1
    and "Privacy_Microphone" in between(dictation, "func openMicrophoneSettings() {", "}"), "settings not privacy",
    "only the microphone failure opens macOS Privacy")
act = between(dictation, "func performFailureAction(_ action: DictationFailureAction) {", "func cancel() {")
pin("openTranscriptionSettings?()" in act and "installParakeet?()" in act and "useWhisper?()" in act, "actions wired", "each action does what it says")
pin("model.dictation.openTranscriptionSettings = { [weak model] in model?.showTranscriptionSettings?() }" in app
    and 'scroll: "transcription"' in app and '.id("transcription")' in views, "settings not privacy",
    "Open Transcription settings lands on COS's Transcription card")
pin("model.dictation.installParakeet = { [weak model] in model?.installParakeet() }" in app, "actions wired", "Install Parakeet from the card")

# 4. Install Parakeet everywhere, from one store.
pin("PanelParakeetRow(model: model, store: model.transcriptionSettings" in views, "menu bar install", "the menu bar panel offers Install Parakeet")
pin("store.rowState(recording:" in ask and "ParakeetRowView(state: state" in ask, "row never dead", "Settings draws the row from parakeetState")
pin("[.ollama, .voice, .dictationEngine]" in connectviews and "DictationEngineControls(" in connectviews, "engine step", "the setup guide shows the engine step after Voice")
pin('let request = try JSONSerialization.data(withJSONObject: cliPath().map { ["cliPath": $0] }' in askcore, "cli path passed", "the install passes the bundled tool")
pin("if let free = freeBytes(), free < Transcription.requiredFreeBytes" in askcore, "disk precheck", "free disk is checked before the install POST")
pin('"cancel-parakeet-install"' in helper and 'case .cancelInstall: "DELETE"' in helper, "cancel", "Cancel is a DELETE of the install route")

# 5. The Voice row is green only with proof.
voice = between(connect, "static func voice(_ facts: SetupFacts, skipped: Bool) -> SetupRow {", "static func voiceEngines(")
pin("DictationTruth.of(facts)" in voice and "row.done = false" in voice, "voice truth", "the Voice row waits for a real round trip")
pin("guide.backgroundCheckIfNeeded(" in model and "recording: self.recordingCount > 0 || self.macRecordingActive" in model, "check once",
    "the one background check never runs during a recording")

# 6. Packaging: the tool is pinned, signed hardened with its identifier before the app, and refused missing on Developer ID.
pin(re.search(r'codesign --force --options runtime --timestamp --identifier com\.gotcos\.control\.fluidaudiocli --sign "\$SIGN_ID" "\$APP/Contents/Helpers/fluidaudiocli"', release) is not None,
    "cli signed", "Developer ID, hardened runtime, timestamp, the pinned identifier")
cli_sign = release.find('--identifier com.gotcos.control.fluidaudiocli --sign "$SIGN_ID"')
pin(0 < cli_sign < release.find('--entitlements "$APP_ENTITLEMENTS" --sign "$SIGN_ID" "$APP/Contents/MacOS/COS Control"') < release.find('--entitlements "$APP_ENTITLEMENTS" --sign "$SIGN_ID" "$APP"\n'),
    "cli signed", "the tool is signed before the main executable and the bundle")
pin("Refusing to ship a Developer ID release without the pinned fluidaudiocli" in release and "does not match the pinned fluidaudiocli build" in release,
    "cli pinned", "a Developer ID release needs the pinned bytes")
pin('/bin/cp "$VERIFY_DIR/COS Control.app/Contents/Helpers/fluidaudiocli" "$CLI_COPY/fluidaudiocli"' in release
    and 'check-fluidaudio-cli.py" "$FLUIDAUDIO_PIN" "$CLI_COPY/fluidaudiocli" --signed --team NV3X46LLCR' in release,
    "plist survives", "a copy outside the extracted app still verifies strictly with its Info.plist and the team (the server re-verifies a copy)")
pin('cp "$ROOT/Resources/Credits.html" "$APP/Contents/Resources/Credits.html"' in release, "credits", "About shows the FluidAudio and Parakeet credits")
pin((root / "Resources/ThirdParty/FluidAudio/LICENSE").read_text().lstrip().startswith("Apache License"), "licenses", "FluidAudio's LICENSE ships")
notices = read("THIRD_PARTY_NOTICES.md")
pin("CC BY 4.0" in notices and "FluidInference/parakeet-ultra-coreml" in notices and "FluidAudio" in notices, "licenses", "notices credit FluidAudio and the model")
pin_json = json.loads(read("Resources/fluidaudio-cli.json"))
pin(pin_json["sourceCommit"] == "21493f8dac5a97e65742e6ff26f42f164c2fda0f" and pin_json["identifier"] == "com.gotcos.control.fluidaudiocli" and pin_json["version"] == "0.17.4",
    "cli pinned", "tag v0.17.4's commit and the identifier the server checks")

# 7. Copy: no em dash, arrow or eyebrow kicker in what 0.5.317 adds.
new_copy = [code(between(read("Sources/MeetingAskCore.swift"), "// MARK: Dictation engine and the Parakeet row (0.5.317, server 6.74.0)", "@MainActor")),
            code(read("Sources/ProviderConnectModel.swift").split("// MARK: - Dictation for everyone (0.5.317, server 6.74.0)", 1)[1]),
            code(read("HelperSources/ProviderStatusCore.swift").split("// MARK: - Mac dictation for every engine (0.5.317, server 6.74.0)", 1)[1]),
            code(read("Sources/MacDictationCore.swift").split("// MARK: - Dictation for everyone (0.5.317, server 6.74.0)", 1)[1])]
whatsnew = json.loads(read("Resources/WhatsNew.json"))
# 0.5.318: sections are found by title; a newer release section goes first.
everyone = next(s for s in whatsnew["whatsNew"]["sections"] if s["title"] == "Dictation for everyone")
new_copy += everyone["items"][:6] + whatsnew["whatsNew"]["sections"][0]["items"]
for text in new_copy:
    for literal in re.findall(r'"((?:[^"\\]|\\.)*)"', text) if text in new_copy[:4] else [text]:
        pin("—" not in literal and "→" not in literal and " -> " not in literal, "copy", f"no em dash or arrow: {literal[:80]!r}")
        words = re.findall(r"[A-Za-z]{3,}", literal)
        pin(not (len(words) >= 2 and all(w.isupper() for w in words)), "copy", f"no all-caps kicker: {literal[:80]!r}")
pin(any("not a full accuracy test" in item for item in everyone["items"]), "honest scope", "What's New says the 30 s test is a quick check")
pin("not a full accuracy test" in connect, "honest scope", "the engine step says the test is a quick check")

print("PASS dictation-everyone pins: one gate, any local engine, one action per failure, install everywhere, Voice truth, pinned signed tool, credits, copy")
