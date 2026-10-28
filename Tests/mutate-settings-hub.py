#!/usr/bin/env python3
"""Settings hub mutation lane. Run by hand, never by a gate.

    python3 Tests/mutate-settings-hub.py <worktree> <scratch dir> [name ...]

Copies the worktree to <scratch dir>/copy, proves the UNMUTATED lane green first (Tests/run-settings-hub.sh, the
catalog's compiled checks, then Tests/settings-hub-pins.py), then applies one mutant at a time: the target must appear
exactly once, the mutant must make the lane fail, and the failure must name the behaviour it breaks. The copy is restored
and compared byte for byte after every mutant. A mutant that lands and survives is a finding. Every compile goes through
the guard (the checks compile the catalog alone), and a run that hangs is killed after LIMIT seconds.
"""
import filecmp, pathlib, shutil, sys, time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import mutate_bounded as bounded

LIMIT = 600
C = "Sources/SettingsHubCatalog.swift"
V = "Sources/Views.swift"
A = "Sources/ActivityWindow.swift"
M = "Sources/MeetingAsk.swift"
R = "scripts/build-release.sh"
S = "Tests/run.sh"
MUTANTS = [
    # Catalog: parity
    ("parity: a row dropped", C, '        .init("UT-21", ', '        .init("UT-2X", ', "the catalog holds every inventory row once"),
    ("parity: a row in the wrong category", C, 'group: "work.background", advanced: false, mount: .group),\n', 'group: "system.server", advanced: false, mount: .group),\n',
     "sits in work"),
    ("parity: a row moved outside", C, '"Opens Cursor on your work folder.", old: "Open Cursor", group: "ai.apps", advanced: false, mount: .group',
     '"Opens Cursor on your work folder.", old: "Open Cursor", group: nil, advanced: false, mount: .outside', "UT-20"),
    ("parity: a group with no category of its own", C, '        .init(id: "pet.characters", category: .pet, title: "Characters",',
     '        .init(id: "pet.characters", category: .system, title: "Characters",', "is named for its category"),
    ("parity: the classic switch leaves Advanced", C, 'old: "", group: "general.app", advanced: true, mount: .group,', 'old: "", group: "general.app", advanced: false, mount: .group,',
     "Use classic Settings"),
    ("parity: the top strip loses Finish setup", C, 'group: "general.guide", advanced: false, mount: .topStrip),', 'group: "general.guide", advanced: false, mount: .group),',
     "the top strip holds"),
    # Catalog: routes
    ("routes: an opener's anchor unrouted", C, '        "key-lanes": "ai.keys",\n', "", "key-lanes"),
    ("routes: settings lands elsewhere", C, '        "settings": "meetings.assistant",\n', '        "settings": "general.app",\n', "settings lands on"),
    ("routes: Advanced never opens", C, "            return destination(group: group, advanced: item.advanced)\n", "            return destination(group: group, advanced: false)\n",
     "opens Advanced exactly when"),
    ("routes: hub anchors unread", C, '        let bare = target.hasPrefix("hub.") ? String(target.dropFirst(4)) : target\n', "        let bare = target\n", "resolves"),
    # Catalog: search
    ("search: the old label ignored", C, '        let haystack = [label, old, detail, keys, group].joined(separator: " ")\n',
     '        let haystack = [label, detail, keys, group].joined(separator: " ")\n', "old label"),
    ("search: keywords ignored", C, '        let haystack = [label, old, detail, keys, group].joined(separator: " ")\n',
     '        let haystack = [label, old, detail, group].joined(separator: " ")\n', "keyword"),
    ("search: any word is enough", C, "        guard terms.allSatisfy({ haystack.contains($0) }) else { return nil }\n",
     "        guard terms.contains(where: { haystack.contains($0) }) else { return nil }\n", "every word must match"),
    ("search: menus searchable", C, "    static var searchable: [SettingsHubItem] { all.filter { $0.mount != .outside } }\n",
     "    static var searchable: [SettingsHubItem] { all }\n", "outside Settings never show in search"),
    ("search: case kept", C, "        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)\n",
     "        let folded = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)\n", "ignores case"),
    ("search: categories out of order", C, "        return SettingsHubCategory.allCases.compactMap { category in\n",
     "        return SettingsHubCategory.allCases.reversed().compactMap { category in\n", "sidebar's order"),
    ("search: no ranking", C, "                .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }.map(\\.0)\n", "                .sorted { $0.2 < $1.2 }.map(\\.0)\n",
     "first"),
    # Catalog: layout
    ("layout: wide too early", C, "    static let wideMinimum: CGFloat = 1100\n", "    static let wideMinimum: CGFloat = 1000\n", "1,099 is medium"),
    ("layout: medium too late", C, "    static let mediumMinimum: CGFloat = 900\n", "    static let mediumMinimum: CGFloat = 960\n", "900 is medium"),
    ("layout: the rail on a medium window", C, "    static func showsRail(_ mode: Mode) -> Bool { mode == .wide }\n",
     "    static func showsRail(_ mode: Mode) -> Bool { mode != .narrow }\n", "On this page shows only when wide"),
    ("layout: a full sidebar at the minimum", C, "    static func sidebar(_ mode: Mode) -> CGFloat { mode == .narrow ? compactSidebarWidth : sidebarWidth }\n",
     "    static func sidebar(_ mode: Mode) -> CGFloat { sidebarWidth }\n", "narrow keeps a compact sidebar"),
    ("layout: the page squeezed", C, "    static let railWidth: CGFloat = 200\n", "    static let railWidth: CGFloat = 320\n", "keeps 480 pt"),
    # Catalog: spy
    ("spy: never the last group at the end", C, "        if atEnd { return tops.last?.id }\n", "", "at the end of the page"),
    ("spy: the first group past the line", C, "        return tops.last(where: { $0.minY <= line })?.id ?? first.id\n",
     "        return tops.first(where: { $0.minY <= line })?.id ?? first.id\n", "the last group past the line"),
    # Catalog: status lines
    ("status: unknown AI readiness invented", C, '        guard f.aiKnown > 0 else { return ("Claude, Codex, Cursor", .plain) }\n',
     '        guard f.aiKnown > 0 else { return ("3 AI apps ready", .plain) }\n', "unknown readiness is the static line"),
    ("status: an unknown engine named", C, '            if let engine = f.dictationEngine, let name = engineName[engine] { return ("On · " + name, .plain) }\n',
     '            if let engine = f.dictationEngine { return ("On · " + (engineName[engine] ?? engine), .plain) }\n', "never named"),
    ("status: unread permissions read as granted", C, '        guard let need = f.permissionsNeed else { return ("Permissions", .plain) }\n',
     '        let need = f.permissionsNeed ?? 0\n', "Privacy: unknown is static"),
    ("status: a server not yet checked reads as down", C, '        guard f.serverChecked else { return ("Server and updates", .plain) }\n', "",
     "System: not checked yet is static"),
    ("status: a recording hidden", C, '        if f.recording { return ("Recording now", .hot) }\n', "", "a recording wins"),
    # Wiring (Views.swift and Activity)
    ("wiring: a loader left on its card", V, "            .task { await model.transcriptionSettings.load(TranscriptionSettingsCard.run(model)) }\n            // LiveCuesSettingsRow",
     "            // LiveCuesSettingsRow", "transcriptionSettings.load"),
    ("wiring: the morning brief never loads in the hub", V,
     "            .task(id: model.status.morningBriefSupported) { if model.status.morningBriefSupported { await model.loadMorningBrief(quiet: true) } }\n", "",
     "loadMorningBrief"),
    ("wiring: Decision models never loads", V, "            await model.loadDecisionSettings(); await model.loadJevStatus(); await model.loadSubQKeyStatus()\n",
     "            break\n", "loads what opening Decision models loads"),
    ("wiring: a piece mounted twice", V, "            SettingsHubBlock { statusServerRows; statusVersionRow }\n",
     "            SettingsHubBlock { statusServerRows; statusServerRows; statusVersionRow }\n", "statusServerRows mounts once"),
    ("wiring: a piece left out", V, "            if model.status.contextBrowserSupported { SettingsHubBlock { statusContextRows } }\n", "", "statusContextRows mounts once"),
    ("wiring: Live cues drawn inside Meeting assistant", V, "MeetingAskSettings(store: model.meetingAsk, model: model, part: .assistant)",
     "MeetingAskSettings(store: model.meetingAsk, model: model)", "one part each"),
    ("wiring: the hub ignores the classic switch", V, "        if let hub, !useClassicSettings { settingsHub(hub) } else { mainPanel }\n",
     "        if let hub { settingsHub(hub) } else { mainPanel }\n", "classic switch off"),
    ("wiring: the classic switch is not a switch", V, '            hubSwitch("HUB-CL", isOn: $useClassicSettings)\n', "", "Use classic Settings is the switch"),
    ("wiring: the Today rail stays beside the hub", A, "                    if !settingsHubShowing { todayRail(mode: mode, frame: frame, now: timeline.date) }\n",
     "                    todayRail(mode: mode, frame: frame, now: timeline.date)\n", "takes the Today rail's place"),
    ("wiring: the hub ignores openers", V, "            .onChange(of: model.panelScrollTarget) { _, _ in hubFollowTarget(reader) }\n", "", "follows the panel's scroll target"),
    ("wiring: an opener's target never consumed", V,
     "            if let destination { reader.scrollTo(destination.anchor, anchor: .top) }\n            model.panelScrollTarget = nil\n",
     "            if let destination { reader.scrollTo(destination.anchor, anchor: .top) }\n", "is consumed"),
    ("wiring: the window passes a host", "Sources/ProviderConnectViews.swift",
     "ControlPanel(model: model, openActivity: openActivity, hostedInWindow: true))",
     "ControlPanel(model: model, openActivity: openActivity, hostedInWindow: true, hub: SettingsHubHost(backTitle: \"Today\", back: {})))",
     "the only host outside the fixture"),
    ("wiring: MeetingAsk always draws Live cues", M, "        if part != .assistant { LiveCuesSettingsRow(store: store.liveCues, model: model) }\n",
     "        LiveCuesSettingsRow(store: store.liveCues, model: model)\n", "unless the hub asks for one"),
    ("copy: an em dash in the hub's words", C, '        case .glasses: "Pair your glasses and phone, and how videos reach this Mac."\n',
     '        case .glasses: "Pair your glasses and phone — and how videos reach this Mac."\n', "em dash"),
    # Lists and the suite
    ("pins: the release build leaves the hub out", R, '"$ROOT/Sources/SettingsHubCatalog.swift" "$ROOT/Sources/SettingsHubViews.swift" ', "",
     "leaves out the hub"),
    ("pins: the suite skips the checks", S, 'zsh "$ROOT/Tests/run-settings-hub.sh"\n', "", "runs the hub's checks"),
]


def suite(copy):
    started = time.time()
    for _ in range(20):
        result = bounded.run(["zsh", "-c", 'zsh Tests/run-settings-hub.sh && /usr/bin/python3 Tests/settings-hub-pins.py .'], LIMIT, cwd=copy)
        out = result.stdout + result.stderr
        # The shared compile lock was busy (another lane compiling): that is no verdict, so run the mutant again.
        if "infrastructure-error" not in out:
            break
        time.sleep(15)
    if "compile-guard: STOPPED" in out:
        sys.exit("compile-guard stopped a compile (memory); ending the mutation lane. " + out[-400:])
    return result.returncode, out, time.time() - started, result.timed_out


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    for part in ("Sources", "Tests", "HelperSources", "scripts", "docs"):
        shutil.copytree(src / part, copy / part)
    code, out, seconds, _ = suite(copy)
    passed = [l for l in out.splitlines() if l.startswith("settings hub checks:") or l.startswith("settings hub pins:")]
    print(f"BASELINE (unmutated): exit {code} in {seconds:.0f}s: {' / '.join(passed) or '(no PASS line)'}", flush=True)
    if code != 0 or len(passed) != 2 or "FAILED" in " ".join(passed):
        print(out[-3000:])
        sys.exit("baseline is not green; no mutant may be judged against a red suite")
    killed = survived = 0
    for name, rel, old, new, words in MUTANTS:
        if only and name not in only:
            continue
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            print(f"MISS  {name}: the target appears {text.count(old)} times", flush=True); survived += 1; continue
        path.write_text(text.replace(old, new), encoding="utf-8")
        try:
            code, out, seconds, timed_out = suite(copy)
        finally:
            path.write_text(text, encoding="utf-8")
        if path.read_text(encoding="utf-8") != text:
            sys.exit(f"RESTORE FAILED for {name}: {rel} differs from its unmutated text")
        lines = [l for l in out.splitlines() if l.startswith("FAIL: ") or "settings hub pin FAILED" in l or ": error:" in l]
        reason = " | ".join(l.strip() for l in lines[:6]) if lines else (out.strip().splitlines()[-1] if out.strip() else "")
        if timed_out:
            killed += 1; print(f"killed  {name}: TIMEOUT after {LIMIT} s (no named check)", flush=True)
        elif code == 0:
            survived += 1; print(f"SURVIVED  {name}", flush=True)
        elif words.lower() in reason.lower():
            killed += 1; print(f"killed  {name} ({seconds:.0f}s): {reason[:220]}", flush=True)
        else:
            survived += 1; print(f"MISATTRIBUTED  {name}: {reason[:300]}", flush=True)
    print(f"RESULT: {killed}/{killed + survived} killed by a check that names the behaviour; every restore compared equal", flush=True)
    sys.exit(0 if survived == 0 else 1)


if __name__ == "__main__":
    main()
