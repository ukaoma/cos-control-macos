#!/usr/bin/env python3
"""0.5.322: mutation gate for the Live cues switch in Settings.

Runs the unmutated lanes first and refuses on any failure (a red baseline would "kill" every mutant). Then each mutant
must match its target EXACTLY ONCE, and is killed only when its lane fails with a named check ("... FAILED: ..." or a
failed precondition); a compile failure or any other exit is an infrastructure error, not a kill. Compiles go through
the lane, so through Tests/compile-guard.sh, one at a time. Usage: python3 Tests/mutate-live-cues.py [--lane pins|models|helper] [--only V1,V2,H12]
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANE = ROOT / "Tests" / "run-live-cues.sh"
CORE = "Sources/MeetingAskCore.swift"
ASK = "Sources/MeetingAsk.swift"
VIEWS = "Sources/Views.swift"
HELPER = "HelperSources/main.swift"

MUTANTS = [
    # The words and the store (Tests/LiveCuesChecks.swift).
    ("M1 nothing answering reads as not checked", "models", CORE,
     '    static func state(_ details: [String: JSONValue]?) -> State {\n        guard let details else { return .notChecked }\n        switch details["transport"]?.string {\n        case "unavailable": return .unreachable\n',
     '    static func state(_ details: [String: JSONValue]?) -> State {\n        guard let details else { return .notChecked }\n        switch details["transport"]?.string {\n        case "unavailable": return .notChecked\n'),
    ("M2 a read keeps the last answer when the server is unreachable", "models", CORE,
     '        state = .checking\n        state = LiveCues.state(try? await run(["live-cues-settings"], nil).details)\n',
     '        state = .checking\n        let next = LiveCues.state(try? await run(["live-cues-settings"], nil).details)\n        if case .loaded = next { state = next }\n'),
    ("M3 a read does not start at Checking", "models", CORE,
     "        defer { busy = false }\n        state = .checking\n", "        defer { busy = false }\n"),
    ("M4 a 404 is not an older server", "models", CORE,
     "        case 200: return settings(details).map(State.loaded) ?? .unreadable\n        case 404: return .olderServer\n",
     "        case 200: return settings(details).map(State.loaded) ?? .unreadable\n"),
    ("M5 an env-set switch is not held", "models", CORE, '    var locked: Bool { source == "env" }', "    var locked: Bool { false }"),
    ("M6 a 409 env_forced is not handled", "models", CORE, "        if LiveCues.envForced(answer?.details) {", "        if false {"),
    ("M7 any 409 reads as env_forced", "models", CORE,
     ' && details?["error"]?.string == "env_forced"', ""),
    ("M8 the old jev_not_configured spelling loses its button", "models", CORE,
     '            case "jev_not_configured", "decision_not_configured": return .addDecisionKey',
     '            case "decision_not_configured": return .addDecisionKey'),
    ("M9 the API key words change", "models", CORE,
     '"An Anthropic API key is set in the server\'s environment; live cues stay off while it is there."',
     '"Live cues are unavailable."'),
    ("M10 decision_cap_reached is not read", "models", CORE,
     '        case "jev_cap_reached", "decision_cap_reached":\n', '        case "jev_cap_reached":\n'),
    ("M11 decision_breaker_open is not read", "models", CORE,
     '        case "jev_breaker_open", "decision_breaker_open":\n', '        case "jev_breaker_open":\n'),
    ("M12 the decision provider is never named", "models", CORE,
     "        if let provider = providerName(capability.decisionProvider) { parts.append(provider) }\n", ""),
    ("M13 a change goes out while busy, held or unchanged", "models", CORE,
     "        guard !busy, let current = settings, !current.locked, current.enabled != enabled else { return }",
     "        guard settings != nil else { return }"),
    ("M14 a read crosses a change in flight", "models", CORE,
     "    func load(_ run: Run) async {\n        guard !busy else { return }\n", "    func load(_ run: Run) async {\n"),
    ("M15 off does not say off", "models", CORE,
     '            if !settings.enabled { return settings.locked ? "Turned off in the server\'s environment." : offLine }\n', ""),
    ("M16 a helper failure reads as unreachable", "models", CORE,
     "    static func state(_ details: [String: JSONValue]?) -> State {\n        guard let details else { return .notChecked }",
     "    static func state(_ details: [String: JSONValue]?) -> State {\n        guard let details else { return .unreachable }"),
    ("M17 a source outside the contract reads", "models", CORE,
     '              ["env", "setting", "default"].contains(source),\n', ""),
    ("M18 a change in flight says nothing", "models", CORE,
     '        if let pending { return pending ? "Turning live cues on…" : "Turning live cues off…" }\n', ""),
    ("M19 a change that reached nothing keeps showing on", "models", CORE,
     "            await load(run)\n            return\n        }\n        let before = settings\n        state = LiveCues.state(answer?.details)\n",
     "            await load(run)\n            return\n        }\n        let before = settings\n        if case .loaded = LiveCues.state(answer?.details) { state = LiveCues.state(answer?.details) }\n"),
    # 0.5.329: the spend limits (Tests/LiveCuesChecks.swift).
    ("L1 a locked limit moves", "models", CORE,
     "        guard let limit = settings?.limits?.values[key], !limit.locked else { return }\n",
     "        guard let limit = settings?.limits?.values[key] else { return }\n"),
    ("L2 moves are not debounced", "models", CORE, "        limitsFlush?.cancel()\n", ""),
    ("L3 the controls show the change optimistically", "models", CORE,
     "        state = LiveCues.state(answer?.details)\n        await keepV3(before, run)\n    }\n\n    func set(", "        await keepV3(before, run)\n    }\n\n    func set("),
    ("L4 a move during a call is dropped", "models", CORE,
     "        for (key, value) in asked where pendingLimits[key] == value { pendingLimits[key] = nil }\n", "        pendingLimits = [:]\n"),
    ("L5 a limits change crosses a read", "models", CORE,
     "        while busy { try? await Task.sleep(for: .milliseconds(50)) }\n", ""),
    ("L6 an echo without limits counts as saved", "models", CORE,
     '        case 200: return settings(details)?.limits == nil ? "The server did not confirm the limit. Check again." : nil\n', "        case 200: return nil\n"),
    ("L12 an out-of-bounds refusal loses its bounds", "models", CORE,
     '            case "out_of_bounds":\n                guard let low', '            case "out_of_bounds_x":\n                guard let low'),
    ("L13 an older server's answer carries limits", "models", CORE,
     '        guard let version = details["v"]?.int, version == 2 || version == 3 else { return nil }\n', '        let version = details["v"]?.int ?? 2\n'),
    ("L7 the bar is sent with three decimals", "models", CORE,
     "            arguments += [key.flag, key.isDecimal ? gateText(value) : String(Int(value.rounded()))]",
     '            arguments += [key.flag, key.isDecimal ? String(format: "%.3f", value) : String(Int(value.rounded()))]'),
    ("L8 the ladder loses the server's value", "models", CORE,
     "        if (low...high).contains(current), !out.contains(current) { out.append(current) }\n", ""),
    ("L9 env without a locked flag is not locked", "models", CORE, '?? (limit["source"]?.string == "env")', "?? false"),
    ("L10 usage counts Jev as writer tokens", "models", CORE,
     "        let tokens = usage.writerTokensIn + usage.writerTokensOut\n", "        let tokens = usage.writerTokensIn + usage.writerTokensOut + usage.jevTokens\n"),
    ("P9 the limits draw on an older server", "pins", ASK, "            if let limits = store.settings?.limits {\n", "            if let limits = Optional(store.settings?.limits ?? LiveCuesLimits()) {\n"),
    ("P10 a locked limit is drawn as a control", "pins", ASK, "        if limit.locked {\n            locked(LiveCues.barTitle", "        if false {\n            locked(LiveCues.barTitle"),
    ("P11 no Saving line", "pins", ASK, "            if !store.pendingLimits.isEmpty {\n", "            if false {\n"),
    # 0.5.362 (server API v3): the cue mode, Grounded cues and the general limits (Tests/LiveCuesChecks.swift).
    ("V1 v3 controls draw without apiVersion 3", "models", CORE,
     '        guard details["apiVersion"]?.int == 3, details["v"]?.int == 3,\n', '        guard details["v"]?.int == 3,\n'),
    ("V2 v3 controls draw from a body that does not say v 3", "models", CORE,
     '        guard details["apiVersion"]?.int == 3, details["v"]?.int == 3,\n', '        guard details["apiVersion"]?.int == 3,\n'),
    ("V3 a mode outside the three reads as Focused", "models", CORE,
     "              let mode = choice(details[\"cueMode\"], LiveCueMode.init(rawValue:)),\n", "              let mode = choice(details[\"cueMode\"], { LiveCueMode(rawValue: $0) ?? .focused }),\n"),
    ("V4 Public topics is optional", "models", CORE,
     '              let general = details["general"]?.object, let publicTopics = general["publicTopics"]?.bool else { return nil }\n',
     '              let general = details["general"]?.object else { return nil }\n        let publicTopics = general["publicTopics"]?.bool ?? false\n'),
    ("V5 the general limits read without apiVersion 3", "models", CORE,
     '        let general = details["apiVersion"]?.int == 3 && version == 3 ? details["general"]?.object?["limits"]?.object ?? [:] : [:]\n',
     '        let general = details["general"]?.object?["limits"]?.object ?? [:]\n'),
    ("V6 a mode from the environment without a locked flag is not locked", "models", CORE,
     '        return LiveCuesChoice(value: chosen, source: source, locked: object["locked"]?.bool ?? (source == "env"))\n',
     '        return LiveCuesChoice(value: chosen, source: source, locked: object["locked"]?.bool ?? false)\n'),
    ("V7 a locked mode moves", "models", CORE,
     "        guard !busy, let v3 = settings?.v3, !v3.mode.locked, v3.mode.value != mode else { return }\n",
     "        guard !busy, let v3 = settings?.v3, v3.mode.value != mode else { return }\n"),
    ("V8 the mode the server holds is sent again", "models", CORE,
     "        guard !busy, let v3 = settings?.v3, !v3.mode.locked, v3.mode.value != mode else { return }\n",
     "        guard !busy, let v3 = settings?.v3, !v3.mode.locked else { return }\n"),
    ("V9 a locked grounding moves", "models", CORE,
     "        guard !busy, let v3 = settings?.v3, !v3.grounding.locked, v3.grounding.value != grounding else { return }\n",
     "        guard !busy, let v3 = settings?.v3, v3.grounding.value != grounding else { return }\n"),
    ("V10 a v 2 write on a v 3 server does not read again", "models", CORE,
     "        guard before?.v3 != nil, settings?.v3 == nil, settings != nil, !busy else { return }\n",
     "        guard before?.v3 == nil, settings?.v3 == nil, settings != nil, !busy else { return }\n"),
    ("V11 a refused mode change is not said", "models", CORE,
     "        if let refusal = LiveCues.changeRefusal(answer?.details) { v3Note = refusal; return }\n        state = LiveCues.state(answer?.details)\n    }\n\n    func setGrounding(",
     "        if LiveCues.changeRefusal(answer?.details) != nil { return }\n        state = LiveCues.state(answer?.details)\n    }\n\n    func setGrounding("),
    ("V12 a refused mode change replaces the server's mode", "models", CORE,
     "        if let refusal = LiveCues.changeRefusal(answer?.details) { v3Note = refusal; return }\n        state = LiveCues.state(answer?.details)\n    }\n\n    func setGrounding(",
     "        if let refusal = LiveCues.changeRefusal(answer?.details) { v3Note = refusal }\n        state = LiveCues.state(answer?.details)\n    }\n\n    func setGrounding("),
    ("V13 the first read repeats", "models", CORE, "        guard case .checking = state, !busy else { return }\n", "        guard !busy else { return }\n"),
    ("V14 the web modes do not say they need Public topics", "models", CORE,
     '        case .general: return "Public context from the web, like news and local items, and it needs Public topics on."\n',
     '        case .general: return "Public context from the web, like news and local items."\n'),
    ("V15 Focused warns about Public topics", "models", CORE,
     "    static func searchesWeb(_ mode: LiveCueMode) -> Bool { mode != .focused }\n", "    static func searchesWeb(_ mode: LiveCueMode) -> Bool { true }\n"),
    ("V16 an open breaker is not said", "models", CORE,
     "        guard let until = today?.breakerOpenUntil, until > now else { return nil }\n", "        guard let until = today?.breakerOpenUntil else { return nil }\n"),
    ("V17 the general trigger is sent as a whole number", "models", CORE, "key.isDecimal ? gateText(value)", "key == .gate ? gateText(value)"),
    ("V18 the general bar starts at 0.45", "models", CORE, "        case .generalTrigger: 0.4...0.9\n", "        case .generalTrigger: 0.45...0.9\n"),
    ("V19 a general limit uses the v 2 name", "models", CORE, '            case .generalMaxCuesPerMeeting: return "maxCuesPerMeeting"\n', '            case .generalMaxCuesPerMeeting: return "generalMaxCuesPerMeeting"\n'),
    ("V20 the general limits send no flag of their own", "models", CORE, '            case .generalDailyWebSearches: return "--general-daily-web-searches"\n', '            case .generalDailyWebSearches: return "--daily-writer-calls"\n'),
    ("V21 the home city is shown for Focused", "models", CORE, "        guard searchesWeb(v3.mode.value), let area = v3.homeArea, !area.isEmpty else { return nil }\n", "        guard let area = v3.homeArea, !area.isEmpty else { return nil }\n"),
    ("V22 a 409 on a mode change reads as a bad value", "models", CORE, "        case 409: return modeEnvNote\n", "        case 409: return \"The server did not accept that value.\"\n"),
    # The view, the panel, the release (Tests/live-cues-pins.py).
    ("P1 the switch moves while held", "pins", ASK, "                    .disabled(!store.switchEnabled)\n", "                    .disabled(false)\n"),
    ("P2 the switch calls the helper itself", "pins", ASK,
     "set: { on in Task { await store.set(on, run: Self.run(model)) } }",
     'set: { on in Task { _ = try? await model.runHelper(["live-cues-settings", "--set", on ? "on" : "off"], timeout: 20) } }'),
    ("P3 the jump does not open Decision models", "pins", VIEWS,
     "        if target == LiveCues.decisionKeysAnchor { jevExpanded = true }\n", ""),
    ("P4 Decision models loses its anchor", "pins", VIEWS, "                .id(LiveCues.decisionKeysAnchor)\n", ""),
    ("P5 no read when the server starts, stops or changes version", "pins", ASK,
     '        .task(id: "\\(model.status.running) \\(model.status.version ?? "")") { if !hosted { await store.load(Self.run(model)) } }',
     "        .task(id: model.status.running) { if !hosted { await store.load(Self.run(model)) } }"),
    ("P6 the row opens a sheet", "pins", ASK,
     "        .padding(.top, hosted ? 0 : 4)\n        .task(id:",
     "        .padding(.top, hosted ? 0 : 4)\n        .sheet(isPresented: .constant(false)) { EmptyView() }\n        .task(id:"),
    ("P7 the row leaves the Meeting assistant card", "pins", ASK,
     "        if part != .assistant { LiveCuesSettingsRow(store: store.liveCues, model: model) }\n", ""),
    ("P8 the key button goes nowhere", "pins", ASK,
     "Button(LiveCues.addKeyLabel) { model.panelScrollTarget = LiveCues.decisionKeysAnchor }",
     "Button(LiveCues.addKeyLabel) { model.showSettings?() }"),
    ("P12 the mode rows draw on a v 2 server", "pins", ASK,
     "            if let v3 = store.settings?.v3 {\n                LiveCuesModeRows(store: store, v3: v3, run: Self.run(model))\n            }\n",
     "            if let v3 = store.settings?.v3 ?? nil {\n                LiveCuesModeRows(store: store, v3: v3, run: Self.run(model))\n            }\n            LiveCuesModeRows(store: store, v3: LiveCuesV3(mode: LiveCuesChoice(value: .focused, source: nil, locked: false), grounding: LiveCuesChoice(value: .classic, source: nil, locked: false), publicTopics: false, homeArea: nil, today: nil), run: Self.run(model))\n"),
    ("P13 the general limits draw in Focused", "pins", ASK,
     "            if let v3 = store.settings?.v3, LiveCues.searchesWeb(v3.mode.value), let limits = store.settings?.limits {\n",
     "            if let v3 = store.settings?.v3, let limits = store.settings?.limits {\n"),
    ("P14 the mode is a row of buttons", "pins", ASK,
     "    private func picker(width: CGFloat?) -> some View {\n        COSDropdown(", "    private func picker(width: CGFloat?) -> some View {\n        Button(\"x\") {}\n        COSDropdown("),
    ("P15 the mode moves while the server holds it", "pins", ASK, "            .disabled(v3.mode.locked || store.busy)\n", "            .disabled(store.busy)\n"),
    ("P16 the mode calls the helper itself", "pins", ASK,
     "set: { mode in Task { await store.setMode(mode, run: run) } })",
     "set: { mode in Task { _ = try? await model.runHelper([\"live-cues-settings\", \"--mode\", mode.rawValue], timeout: 20) } })"),
    ("P17 Public topics off is not shown", "pins", ASK,
     "        if let line = LiveCues.publicTopicsLine(v3) { SettingsHubNote(text: line, tone: .warning) }\n", ""),
    ("P18 the grounded switch is a sheet", "pins", ASK,
     "            Text(LiveCues.groundedHelp).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)\n",
     "            Text(LiveCues.groundedHelp).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).sheet(isPresented: .constant(false)) { EmptyView() }\n"),
    # The helper (its self-test and Tests/live-cues-helper-checks.py).
    ("H1 --set takes anything", "helper", HELPER,
     '        case "off": return ("POST", #"{"v":2,"enabled":false}"#)\n        default: return nil\n',
     '        case "off": return ("POST", #"{"v":2,"enabled":false}"#)\n        default: return ("POST", #"{"v":2,"enabled":true}"#)\n'),
    ("H2 any decision provider crosses", "helper", HELPER,
     '["jev", "subq"].contains(provider) { capability["decisionProvider"] = provider }',
     '!provider.isEmpty { capability["decisionProvider"] = provider }'),
    ("H3 a number crosses as a bool", "helper", HELPER,
     "        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }\n        return number.boolValue\n    }\n\n    /// 0.5.362 (server API v3): a choice setting",
     "        guard let number = value as? NSNumber else { return nil }\n        return number.boolValue\n    }\n\n    /// 0.5.362 (server API v3): a choice setting"),
    ("H5 a limit takes any number", "helper", HELPER,
     '            let pattern = key == "gate" ? "\\\\A(0(\\\\.[0-9]{1,3})?|1(\\\\.0{1,3})?)\\\\z" : "\\\\A(0|[1-9][0-9]{0,5})\\\\z"',
     '            let pattern = "\\\\A[0-9.eE+-]+\\\\z"'),
    ("H6 --set and a limit go together", "helper", HELPER, "            guard !args.contains(\"--set\"), let body = Self.liveCuesPostBody(values) else {",
     "            guard let body = Self.liveCuesPostBody(values) else {"),
    ("H7 a limit's extra keys cross", "helper", HELPER, '        var kept: [String: Any] = ["value": number]\n        if let source = limit["source"]', '        var kept: [String: Any] = limit\n        if let source = limit["source"]'),
    ("H9 a read does not ask for v 3", "helper", HELPER, '(reading ? "?v=3" : "")', '""'),
    ("H10 the limits post without v 2", "helper", HELPER, '        var pairs = [#""v":2"#]\n', '        var pairs: [String] = []\n'),
    ("H11 env_locked passes any field name", "helper", HELPER,
     '            out["fields"] = fields.compactMap { $0 as? String }.filter { Self.liveCuesLimitKeys.contains($0) || Self.liveCuesV3Keys.contains($0) }\n', '            out["fields"] = fields\n'),
    ("H8 any usage key crosses", "helper", HELPER,
     '            for key in ["writerCalls", "writerTokensIn", "writerTokensOut", "cues", "jevTokens"] {\n                if let n = Self.liveCueCount(raw[key]) { today[key] = n }\n            }\n',
     "            today = raw\n"),
    ("H12 a write with a v3 field posts v 2", "helper", HELPER, '        var pairs = [#""v":3"#]\n', '        var pairs = [#""v":2"#]\n'),
    ("H13 any mode posts", "helper", HELPER, '                guard (key == "cueMode" ? liveCueModes : liveCueGroundings).contains(text) else { return nil }\n', ""),
    ("H14 the general trigger posts as a whole number", "helper", HELPER, 'key == "gate" || key == "generalTrigger" ? decimal : whole', 'key == "gate" ? decimal : whole'),
    ("H15 the v 2 fallback fires on any 400", "helper", HELPER,
     'if reading, response.status == 400, Self.liveCueErrorCode(response.body) == "unsupported_version" {', 'if reading, response.status == 400 {'),
    ("H16 apiVersion 3 without a v 3 body", "helper", HELPER,
     'details["apiVersion"] = Self.liveCueCount(response.body?["v"]) == 3 ? 3 : 2', 'details["apiVersion"] = 3'),
    ("H17 the v3 block crosses from a v 2 answer", "helper", HELPER, '        if Self.liveCueCount(body["v"]) == 3 {\n            if let mode', '        if true {\n            if let mode'),
    ("H18 a mode outside the three crosses", "helper", HELPER, '        guard let raw = value as? [String: Any], let chosen = raw["value"] as? String, allowed.contains(chosen) else { return nil }\n',
     '        guard let raw = value as? [String: Any], let chosen = raw["value"] as? String else { return nil }\n'),
    ("H19 a home city with digits crosses", "helper", HELPER, r".'\u{2019},-]{1,80}", r"0-9.'\u{2019},-]{1,80}"),
    ("H20 an http source address crosses", "helper", HELPER, 'parts.scheme?.lowercased() == "https",', 'parts.scheme != nil,'),
    ("H21 a locator crosses without its kind", "helper", HELPER,
     '        guard let kind = source["kind"] as? String, Self.liveCueSourceKinds.contains(kind) else { return out }\n',
     '        guard let kind = source["kind"] as? String, Self.liveCueSourceKinds.contains(kind) else { out["recordId"] = source["recordId"]; out["url"] = source["url"]; return out }\n'),
    ("H22 a source keeps every locator", "helper", HELPER, '        case "meeting": if let id = Self.liveCueLocator(source["recordId"]) { out["recordId"] = id }\n',
     '        case "meeting": if let id = Self.liveCueLocator(source["recordId"]) { out["recordId"] = id }; out["url"] = source["url"]\n'),
    ("H23 a general status state outside the six crosses", "helper", HELPER, '        if let raw = session["general"] as? [String: Any], let state = raw["state"] as? String, Self.liveCueGeneralStates.contains(state) {\n',
     '        if let raw = session["general"] as? [String: Any], let state = raw["state"] as? String {\n'),
    ("H24 the status carries the cues", "helper", HELPER, '        if let state = session["state"] as? String, ["active", "paused", "ended", "stopped"].contains(state) { out["state"] = state }\n',
     '        if let state = session["state"] as? String, ["active", "paused", "ended", "stopped"].contains(state) { out["state"] = state }\n        out["cues"] = session["cues"]\n'),
    ("H25 a cue category outside the three crosses", "helper", HELPER, 'Self.liveCueGeneralCategories.contains(category) {\n            out["general"]', 'true {\n            out["general"]'),
    ("H4 no token reads as unreachable", "helper", HELPER,
     '            plan = ("POST", body)\n        }\n        guard let token = try? readToken() else {\n            emit(ok: true, message: "No pairing token", details: ["transport": "no_token"])',
     '            plan = ("POST", body)\n        }\n        guard let token = try? readToken() else {\n            emit(ok: true, message: "No pairing token", details: ["transport": "unavailable"])'),
]


def run(lane):
    env = dict(os.environ, COS_LIVE_CUES_LANE=lane)
    return subprocess.run(["zsh", str(LANE)], cwd=ROOT, env=env, capture_output=True, text=True)


only = sys.argv[sys.argv.index("--lane") + 1] if "--lane" in sys.argv else None
lanes = [lane for lane in ("pins", "models", "helper") if only in (None, lane)]
mutants = [m for m in MUTANTS if m[1] in lanes]
# --only V1,V2,H12: re-run named mutants (an id, or a prefix letter); the lanes they need still get a green baseline.
if "--only" in sys.argv:
    wanted = sys.argv[sys.argv.index("--only") + 1].split(",")
    mutants = [m for m in mutants if any(m[0].split(" ")[0] == w or (len(w) == 1 and m[0].startswith(w)) for w in wanted)]
    lanes = [lane for lane in lanes if any(m[1] == lane for m in mutants)]
for lane in lanes:
    base = run(lane)
    if base.returncode != 0:
        print(f"BASELINE RED ({lane}):\n{base.stdout}{base.stderr}")
        sys.exit(2)
print("baseline green: " + ", ".join(lanes))

survivors = infra = 0
for name, lane, rel, old, new in mutants:
    path = ROOT / rel
    src = path.read_text()
    count = src.count(old)
    if count != 1:
        print(f"{name}: NOT APPLIED (target found {count} times)")
        infra += 1
        continue
    path.write_text(src.replace(old, new))
    try:
        r = run(lane)
        out = r.stdout + r.stderr
        failed_line = next((l for l in out.splitlines() if "FAILED:" in l or "Precondition failed" in l), None)
        if r.returncode != 0 and failed_line:
            print(f"{name}: killed by {failed_line.strip()[:220]}")
        elif r.returncode != 0:
            print(f"{name}: INFRASTRUCTURE (exit {r.returncode}, no named check)\n{out[-600:]}")
            infra += 1
        else:
            print(f"{name}: SURVIVED")
            survivors += 1
    finally:
        path.write_text(src)
print(f"live cues mutants: {len(mutants) - survivors - infra} killed, {survivors} survived, {infra} infrastructure")
sys.exit(1 if survivors or infra else 0)
