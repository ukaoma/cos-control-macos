#!/usr/bin/env python3
"""0.5.322: mutation gate for the Live cues switch in Settings.

Runs the unmutated lanes first and refuses on any failure (a red baseline would "kill" every mutant). Then each mutant
must match its target EXACTLY ONCE, and is killed only when its lane fails with a named check ("... FAILED: ..." or a
failed precondition); a compile failure or any other exit is an infrastructure error, not a kill. Compiles go through
the lane, so through Tests/compile-guard.sh, one at a time. Usage: python3 Tests/mutate-live-cues.py [--lane pins|models|helper]
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
     '        state = LiveCues.state(try? await run(["live-cues-settings"], nil).details)\n',
     '        let next = LiveCues.state(try? await run(["live-cues-settings"], nil).details)\n        if case .loaded = next { state = next }\n'),
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
     "            await load(run)\n            return\n        }\n        state = LiveCues.state(answer?.details)\n    }\n",
     "            await load(run)\n            return\n        }\n        if case .loaded = LiveCues.state(answer?.details) { state = LiveCues.state(answer?.details) }\n    }\n"),
    # 0.5.329: the spend limits (Tests/LiveCuesChecks.swift).
    ("L1 a locked limit moves", "models", CORE,
     "        guard let limit = settings?.limits?.values[key], !limit.locked else { return }\n",
     "        guard let limit = settings?.limits?.values[key] else { return }\n"),
    ("L2 moves are not debounced", "models", CORE, "        limitsFlush?.cancel()\n", ""),
    ("L3 the controls show the change optimistically", "models", CORE,
     "        state = LiveCues.state(answer?.details)\n    }\n\n    func set(", "    }\n\n    func set("),
    ("L4 a move during a call is dropped", "models", CORE,
     "        for (key, value) in asked where pendingLimits[key] == value { pendingLimits[key] = nil }\n", "        pendingLimits = [:]\n"),
    ("L5 a limits change crosses a read", "models", CORE,
     "        while busy { try? await Task.sleep(for: .milliseconds(50)) }\n", ""),
    ("L6 an echo without limits counts as saved", "models", CORE,
     '        case 200: return settings(details)?.limits == nil ? "The server did not confirm the limit. Check again." : nil\n', "        case 200: return nil\n"),
    ("L12 an out-of-bounds refusal loses its bounds", "models", CORE,
     '            case "out_of_bounds":\n                guard let low', '            case "out_of_bounds_x":\n                guard let low'),
    ("L13 an older server's answer carries limits", "models", CORE, '        guard details["v"]?.int == 2 else { return nil }\n', ""),
    ("L7 the bar is sent with three decimals", "models", CORE,
     "            arguments += [key.flag, key == .gate ? gateText(value) : String(Int(value.rounded()))]",
     '            arguments += [key.flag, key == .gate ? String(format: "%.3f", value) : String(Int(value.rounded()))]'),
    ("L8 the ladder loses the server's value", "models", CORE,
     "        if (low...high).contains(current), !out.contains(current) { out.append(current) }\n", ""),
    ("L9 env without a locked flag is not locked", "models", CORE, '?? (limit["source"]?.string == "env")', "?? false"),
    ("L10 usage counts Jev as writer tokens", "models", CORE,
     "        let tokens = usage.writerTokensIn + usage.writerTokensOut\n", "        let tokens = usage.writerTokensIn + usage.writerTokensOut + usage.jevTokens\n"),
    ("P9 the limits draw on an older server", "pins", ASK, "            if let limits = store.settings?.limits {\n", "            if let limits = Optional(store.settings?.limits ?? LiveCuesLimits()) {\n"),
    ("P10 a locked limit is drawn as a control", "pins", ASK, "        if limit.locked {\n            locked(LiveCues.barTitle", "        if false {\n            locked(LiveCues.barTitle"),
    ("P11 no Saving line", "pins", ASK, "            if !store.pendingLimits.isEmpty {\n", "            if false {\n"),
    # The view, the panel, the release (Tests/live-cues-pins.py).
    ("P1 the switch moves while held", "pins", ASK, "                    .disabled(!store.switchEnabled)\n", "                    .disabled(false)\n"),
    ("P2 the switch calls the helper itself", "pins", ASK,
     "set: { on in Task { await store.set(on, run: Self.run(model)) } }",
     'set: { on in Task { _ = try? await model.runHelper(["live-cues-settings", "--set", on ? "on" : "off"], timeout: 20) } }'),
    ("P3 the jump does not open Decision models", "pins", VIEWS,
     "        if target == LiveCues.decisionKeysAnchor { jevExpanded = true }\n", ""),
    ("P4 Decision models loses its anchor", "pins", VIEWS, "                .id(LiveCues.decisionKeysAnchor)\n", ""),
    ("P5 no read when the server starts, stops or changes version", "pins", ASK,
     '        .task(id: "\\(model.status.running) \\(model.status.version ?? "")") { await store.load(Self.run(model)) }',
     "        .task(id: model.status.running) { await store.load(Self.run(model)) }"),
    ("P6 the row opens a sheet", "pins", ASK,
     "        .padding(.top, 4)\n        .task(id:",
     "        .padding(.top, 4)\n        .sheet(isPresented: .constant(false)) { EmptyView() }\n        .task(id:"),
    ("P7 the row leaves the Meeting assistant card", "pins", ASK,
     "            LiveCuesSettingsRow(store: store.liveCues, model: model)\n", ""),
    ("P8 the key button goes nowhere", "pins", ASK,
     "Button(LiveCues.addKeyLabel) { model.panelScrollTarget = LiveCues.decisionKeysAnchor }",
     "Button(LiveCues.addKeyLabel) { model.showSettings?() }"),
    # The helper (its self-test and Tests/live-cues-helper-checks.py).
    ("H1 --set takes anything", "helper", HELPER,
     '        case "off": return ("POST", #"{"v":2,"enabled":false}"#)\n        default: return nil\n',
     '        case "off": return ("POST", #"{"v":2,"enabled":false}"#)\n        default: return ("POST", #"{"v":2,"enabled":true}"#)\n'),
    ("H2 any decision provider crosses", "helper", HELPER,
     '["jev", "subq"].contains(provider) { capability["decisionProvider"] = provider }',
     '!provider.isEmpty { capability["decisionProvider"] = provider }'),
    ("H3 a number crosses as a bool", "helper", HELPER,
     "            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }\n            return number.boolValue\n",
     "            guard let number = value as? NSNumber else { return nil }\n            return number.boolValue\n"),
    ("H5 a limit takes any number", "helper", HELPER,
     '            let pattern = key == "gate" ? "\\\\A(0(\\\\.[0-9]{1,3})?|1(\\\\.0{1,3})?)\\\\z" : "\\\\A(0|[1-9][0-9]{0,5})\\\\z"',
     '            let pattern = "\\\\A[0-9.eE+-]+\\\\z"'),
    ("H6 --set and a limit go together", "helper", HELPER, "            guard !args.contains(\"--set\"), let body = Self.liveCuesLimitsBody(limits) else {",
     "            guard let body = Self.liveCuesLimitsBody(limits) else {"),
    ("H7 a limit's extra keys cross", "helper", HELPER, '                var kept: [String: Any] = ["value": value]\n                if let source = limit["source"]', '                var kept: [String: Any] = limit\n                if let source = limit["source"]'),
    ("H9 a read does not ask for v 2", "helper", HELPER, '(plan.method == "GET" ? "?v=2" : "")', '""'),
    ("H10 the limits post without v 2", "helper", HELPER, '        var pairs = [#""v":2"#]\n', '        var pairs: [String] = []\n'),
    ("H11 env_locked passes any field name", "helper", HELPER,
     '            out["fields"] = fields.compactMap { $0 as? String }.filter { Self.liveCuesLimitKeys.contains($0) }\n', '            out["fields"] = fields\n'),
    ("H8 any usage key crosses", "helper", HELPER,
     '            for key in ["writerCalls", "writerTokensIn", "writerTokensOut", "cues", "jevTokens"] {\n                if let n = Self.liveCueCount(raw[key]) { today[key] = n }\n            }\n',
     "            today = raw\n"),
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
