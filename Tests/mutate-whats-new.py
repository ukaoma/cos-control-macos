#!/usr/bin/env python3
"""Mutation lane for the What's New window (2026-10-09). Run by hand, never by a gate. SERIAL: one mutant at a time,
and every compile goes through Tests/compile-guard.sh (two kernel panics on 2026-10-07 came from parallel compiles).

    python3 Tests/mutate-whats-new.py <worktree> <scratch dir> [name ...]

It copies the worktree once to <scratch dir>/copy, proves each UNMUTATED lane it will use green first (a red baseline
makes every mutant look killed), then applies one mutant at a time: the target text must appear exactly once, the
mutant must make a check fail, and the failure must name the behaviour the mutant breaks ("check failed [<behaviour>]"
or "pin failed [<behaviour>]"). A mutant that lands and survives is a finding; so is one the compiler refuses.
Lanes are Tests/run-whats-new.sh's (COS_WHATS_NEW_LANE): pins (Python), models (Models.swift + WhatsNewChecks),
helper (the compiled helper against fixtures), wiring (the whole app against a stand-in helper).
"""
import os, pathlib, shutil, subprocess, sys, time

M = "Sources/Models.swift"
C = "Sources/ControllerModel.swift"
V = "Sources/Views.swift"
A = "Sources/COSControlApp.swift"
H = "HelperSources/main.swift"
R = "Tests/run.sh"
# (name, file, original, mutant, words the killing failure must contain, lane)
MUTANTS = [
    # The app's reading of whatsNew.
    ("summary cap raised", M, "    static let summaryLimit = 1200\n", "    static let summaryLimit = 2000\n", "[whatsNew oversize]", "models"),
    ("no section cap", M, "            guard sections.count < Self.sectionLimit else { break }\n", "", "[whatsNew oversize]", "models"),
    ("no item cap", M, "                guard items.count < Self.itemLimit else { break }\n", "", "[whatsNew oversize]", "models"),
    ("item length uncapped", M, "Self.clean(text, limit: Self.itemLength, keepNewlines: false)", "Self.clean(text, limit: 100_000, keepNewlines: false)", "[whatsNew oversize]", "models"),
    ("control characters kept", M, "            } else if scalar.properties.generalCategory == .control {\n                scalars.append(\" \")\n            } else if !bidiControls",
     "            } else if false {\n                scalars.append(\" \")\n            } else if !bidiControls", "[whatsNew control chars]", "models"),
    ("bidi controls kept", M, "            } else if !bidiControls.contains(scalar.value) {", "            } else if true {", "[whatsNew bidi]", "models"),
    ("line breaks in items", M, "                scalars.append(keepNewlines ? \"\\n\" : \" \")\n            } else if scalar.properties.generalCategory == .control {\n                scalars.append(\" \")\n            } else if !bidiControls",
     "                scalars.append(\"\\n\")\n            } else if scalar.properties.generalCategory == .control {\n                scalars.append(\" \")\n            } else if !bidiControls", "[whatsNew control chars]", "models"),
    ("empty section kept", M, "            if !items.isEmpty { sections.append(Section(title: title, items: items)) }", "            sections.append(Section(title: title, items: items))", "[whatsNew wrong types]", "models"),
    ("empty whatsNew accepted", M, "        guard summary != nil || !sections.isEmpty else { return nil }\n        self.summary = summary\n", "        self.summary = summary\n", "[whatsNew wrong types]", "models"),
    ("no notes fallback", M, "        summary = info.whatsNew?.summary ?? notes\n", "        summary = info.whatsNew?.summary\n", "[content notes fallback]", "models"),
    ("whatsNew not read", M, "        whatsNew = AppUpdateWhatsNew(details[\"whatsNew\"])\n", "", "[whatsNew valid]", "models"),
    # The footer.
    ("install enabled while staging", M, "        case .staging(let line):\n            primary = .install; primaryEnabled = false\n            cancelTitle = \"Cancel\"; cancelEnabled = false",
     "        case .staging(let line):\n            primary = .install; primaryEnabled = true\n            cancelTitle = \"Cancel\"; cancelEnabled = false", "[footer staging]", "models"),
    ("cancel enabled while applying", M, "        case .applying:\n            primary = .install; primaryEnabled = false\n            cancelTitle = \"Cancel\"; cancelEnabled = false",
     "        case .applying:\n            primary = .install; primaryEnabled = false\n            cancelTitle = \"Cancel\"; cancelEnabled = true", "[footer applying]", "models"),
    ("busy ignored", M, "            primary = .install; primaryEnabled = !busy\n", "            primary = .install; primaryEnabled = true\n", "[footer busy]", "models"),
    ("no Try again", M, "            primary = .tryAgain; primaryEnabled = !busy\n", "            primary = .install; primaryEnabled = !busy\n", "[footer failed]", "models"),
    ("no Checking word", M, "        if line.contains(\"SHA-256\") || line.hasPrefix(\"Checking\") { return \"Checking…\" }\n", "", "[footer staging]", "models"),
    ("release line drops the build", M, "        return build.map { \"\\(version) (build \\($0))\" } ?? version\n", "        return version\n", "[release line]", "models"),
    # The helper.
    ("helper passes whatsNew raw", H, "if let whatsNew = Self.sanitizedWhatsNew(stable[\"whatsNew\"]) { details[\"whatsNew\"] = whatsNew }",
     "if let whatsNew = stable[\"whatsNew\"] { details[\"whatsNew\"] = whatsNew }", "[whatsNew", "helper"),
    ("helper drops whatsNew", H, "if let whatsNew = Self.sanitizedWhatsNew(stable[\"whatsNew\"]) { details[\"whatsNew\"] = whatsNew }", "", "[whatsNew valid]", "helper"),
    ("helper summary cap raised", H, "    static let whatsNewSummaryLimit = 1200,", "    static let whatsNewSummaryLimit = 2000,", "[whatsNew oversize]", "helper"),
    ("helper no section cap", H, "            guard sections.count < whatsNewSectionLimit else { break }\n", "", "[whatsNew oversize]", "helper"),
    ("helper no item cap", H, "                guard items.count < whatsNewItemLimit else { break }\n", "", "[whatsNew oversize]", "helper"),
    ("helper control characters kept", H, "            } else if scalar.properties.generalCategory == .control {\n                scalars.append(\" \")\n            } else if !whatsNewBidi",
     "            } else if false {\n                scalars.append(\" \")\n            } else if !whatsNewBidi", "[whatsNew control chars]", "helper"),
    ("helper bidi kept", H, "            } else if !whatsNewBidiControls.contains(scalar.value) {", "            } else if true {", "[whatsNew control chars]", "helper"),
    ("helper empty section kept", H, "            if !items.isEmpty { sections.append([\"title\": title, \"items\": items]) }", "            sections.append([\"title\": title, \"items\": items])", "[whatsNew wrong types]", "helper"),
    ("helper summary loses lines", H, "cleanWhatsNewText($0, limit: whatsNewSummaryLimit, keepNewlines: true)", "cleanWhatsNewText($0, limit: whatsNewSummaryLimit, keepNewlines: false)", "[whatsNew control chars]", "helper"),
    # The window and who opens it, executed.
    ("Check for updates does not open", C, "                if appUpdateFlow.phase == .ready { presentWhatsNew() }\n", "", "[check for updates opens]", "wiring"),
    ("background check opens", C, "            appUpdate = AppUpdateInfo.merging(previous: appUpdate, incoming: AppUpdateInfo(response.details))\n",
     "            appUpdate = AppUpdateInfo.merging(previous: appUpdate, incoming: AppUpdateInfo(response.details))\n            presentWhatsNew()\n", "[background check]", "wiring"),
    ("a new window each open", V, "        if let window = controller?.window { return window }\n", "", "[single window]", "wiring"),
    ("presentWhatsNew does nothing", C, "        showWhatsNew?()\n", "", "[check for updates opens]", "wiring"),
    # Wiring the gate cannot execute (a person clicks it), pinned.
    ("banner installs without the window", V, "                model.presentWhatsNew()\n", "                model.installAppUpdate()\n", "[banner opens]", "pins"),
    ("Download and install does nothing", V, "onInstall: { model.installAppUpdate() }", "onInstall: {}", "[install path]", "pins"),
    ("app never wires the window", A, "        model.showWhatsNew = { whatsNewWindow.show(model: model) }\n", "", "[app wires window]", "pins"),
    ("eyebrow heading", V, "                .font(COSType.body(16, weight: .semibold))\n", "                .font(COSType.body(16, weight: .semibold)).textCase(.uppercase).tracking(1.2)\n", "[no eyebrow kickers]", "pins"),
    ("Cancel never disabled", V, "                    .disabled(!footer.cancelEnabled)\n", "", "[footer buttons]", "pins"),
    ("gate not run", R, "\"$ROOT/Tests/run-whats-new.sh\"\n", "", "[gate]", "pins"),
]


def run(lane, copy):
    env = dict(os.environ, COS_WHATS_NEW_LANE=lane, COS_COMPILE_MIN_FREE_GB=os.environ.get("COS_COMPILE_MIN_FREE_GB", "20"))
    while True:
        p = subprocess.run(["/bin/zsh", str(copy / "Tests/run-whats-new.sh")], capture_output=True, text=True, timeout=2400, env=env)
        if p.returncode != 75:  # 75: compile-guard found too little free memory; wait and try again
            return p.returncode, p.stdout + p.stderr
        time.sleep(30)


def main():
    src, scratch = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    only = set(sys.argv[3:])
    chosen = [m for m in MUTANTS if not only or m[0] in only]
    copy = scratch / "copy"
    if copy.exists():
        shutil.rmtree(copy)
    shutil.copytree(src, copy, ignore=shutil.ignore_patterns(".git", "dist", "*.zip"))
    for lane in ("pins", "models", "helper", "wiring"):
        if not any(m[5] == lane for m in chosen):
            continue
        code, out = run(lane, copy)
        if code != 0:
            sys.exit(f"baseline {lane} lane is RED; no mutant can be judged:\n{out[-3000:]}")
        print(f"baseline {lane}: green ({out.strip().splitlines()[-1] if out.strip() else ''})", flush=True)
    survived, results = [], []
    for name, rel, original, mutant, words, lane in chosen:
        path = copy / rel
        text = path.read_text(encoding="utf-8")
        if text.count(original) != 1:
            results.append(f"MISSED TARGET ({text.count(original)}x) {name}")
            survived.append(name)
            print(results[-1], flush=True)
            continue
        path.write_text(text.replace(original, mutant), encoding="utf-8")
        started = time.time()
        try:
            code, out = run(lane, copy)
        finally:
            path.write_text(text, encoding="utf-8")
        took = time.time() - started
        if code == 137:
            sys.exit(f"compile guard stopped the run at mutant {name}; stopping the lane")
        if code == 0:
            results.append(f"SURVIVED {name}")
            survived.append(name)
        elif words in out:
            line = next((l for l in out.splitlines() if "failed [" in l), "")
            results.append(f"killed  {name}  ({took:.0f}s) {line[:150]}")
        elif "error:" in out:
            results.append(f"WEAK (compile error) {name}")
            survived.append(name)
        else:
            results.append(f"WEAK (another check) {name}: {out.strip().splitlines()[-1][:160] if out.strip() else ''}")
            survived.append(name)
        print(results[-1], flush=True)
    print(f"{len(results) - len(survived)} of {len(results)} killed")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
