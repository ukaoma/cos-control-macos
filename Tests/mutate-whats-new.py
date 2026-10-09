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
B = "scripts/build-release.sh"
# (name, file, original, mutant, words the killing failure must contain, lane)
MUTANTS = [
    # The app's reading of whatsNew.
    ("summary cap raised", M, "    static let summaryLimit = 1200\n", "    static let summaryLimit = 2000\n", "[whatsNew oversize]", "models"),
    ("title cap raised", M, "    static let titleLength = 80\n", "    static let titleLength = 120\n", "[whatsNew oversize]", "models"),
    ("no section cap", M, "            guard sections.count < Self.sectionLimit else { break }\n", "", "[whatsNew oversize]", "models"),
    ("no item cap", M, "                guard items.count < Self.itemLimit else { break }\n", "", "[whatsNew oversize]", "models"),
    ("item length uncapped", M, "Self.clean(text, limit: Self.itemLength, keepNewlines: false)", "Self.clean(text, limit: 100_000, keepNewlines: false)", "[whatsNew oversize]", "models"),
    ("control characters kept", M, "            } else if scalar.properties.generalCategory == .control {\n                scalars.append(\" \")\n            } else if scalar.properties.generalCategory != .format {",
     "            } else if false {\n                scalars.append(\" \")\n            } else if scalar.properties.generalCategory != .format {", "[whatsNew control chars]", "models"),
    ("format characters kept", M, "            } else if scalar.properties.generalCategory != .format {", "            } else if true {", "[whatsNew bidi]", "models"),
    ("scalar cap removed", M, "        if result.unicodeScalars.count > scalarLimit {", "        if false {", "[whatsNew scalar cap]", "models"),
    ("line breaks in items", M, "                scalars.append(keepNewlines ? \"\\n\" : \" \")\n            } else if scalar.properties.generalCategory == .control {\n                scalars.append(\" \")\n            } else if scalar.properties.generalCategory != .format {",
     "                scalars.append(\"\\n\")\n            } else if scalar.properties.generalCategory == .control {\n                scalars.append(\" \")\n            } else if scalar.properties.generalCategory != .format {", "[whatsNew control chars]", "models"),
    ("empty section kept", M, "            if !items.isEmpty { sections.append(Section(title: title, items: items)) }", "            sections.append(Section(title: title, items: items))", "[whatsNew wrong types]", "models"),
    ("empty whatsNew accepted", M, "        guard summary != nil || !sections.isEmpty else { return nil }\n        self.summary = summary\n", "        self.summary = summary\n", "[whatsNew wrong types]", "models"),
    ("no notes fallback", M, "        summary = info.whatsNew?.summary ?? notes\n", "        summary = info.whatsNew?.summary\n", "[content notes fallback]", "models"),
    ("whatsNew not read", M, "        whatsNew = AppUpdateWhatsNew(details[\"whatsNew\"])\n", "", "[whatsNew valid]", "models"),
    # The footer and the presentation.
    ("install enabled while staging", M, "            self.init(primary: .install, primaryEnabled: false, cancelTitle: \"Close\", cancelEnabled: true,\n                      status: Self.progressWord(line)",
     "            self.init(primary: .install, primaryEnabled: true, cancelTitle: \"Close\", cancelEnabled: true,\n                      status: Self.progressWord(line)", "[footer staging]", "models"),
    ("Close disabled while staging", M, "            self.init(primary: .install, primaryEnabled: false, cancelTitle: \"Close\", cancelEnabled: true,\n                      status: Self.progressWord(line)",
     "            self.init(primary: .install, primaryEnabled: false, cancelTitle: \"Cancel\", cancelEnabled: false,\n                      status: Self.progressWord(line)", "[footer staging]", "models"),
    ("busy ignored", M, "            self.init(primary: .install, primaryEnabled: !busy, cancelTitle: \"Cancel\"", "            self.init(primary: .install, primaryEnabled: true, cancelTitle: \"Cancel\"", "[footer busy]", "models"),
    ("no Try again", M, "            self.init(primary: .tryAgain, primaryEnabled: !busy,", "            self.init(primary: .install, primaryEnabled: !busy,", "[footer failed]", "models"),
    ("no Checking word", M, "        if line.contains(\"SHA-256\") || line.hasPrefix(\"Checking\") { return \"Checking…\" }\n", "", "[footer staging]", "models"),
    ("meeting refusal raw", M, "        guard message.hasPrefix(prefix) else { return message }\n", "        if !message.isEmpty { return message }\n", "[footer words]", "models"),
    ("paused feed says up to date", M, "        case \"killSwitch\": return \"Updates are paused by the publisher right now.\"\n", "", "[footer no offer words]", "models"),
    ("no byline", M, "byline: flow.build.map { \"Build \\($0)\" }", "byline: nil", "[presentation title]", "models"),
    ("words not frozen", M, "        let content = flow.installing ? (frozen ?? WhatsNewContent(info)) : WhatsNewContent(info)\n", "        let content = WhatsNewContent(info)\n", "[presentation frozen]", "models"),
    # QA item 1: only a proven stage of the offered build is applied.
    ("stage reason ignored", M, "        let reason = details[\"reason\"]?.string\n        switch reason {", "        let reason = details[\"reason\"]?.string\n        switch Optional<String>.none {", "[stage check]", "models"),
    ("staged path not required", M, "        guard let path = details[\"stagedAppPath\"]?.string, !path.trimmingCharacters(in: .whitespaces).isEmpty else {\n            return \"The update was not staged. Nothing was installed.\"\n        }\n", "", "[stage check]", "models"),
    ("staged build not compared", M, "            if staged != offeredBuild {", "            if false {", "[stage check build]", "models"),
    ("app skips the stage check", C, "                if let refusal = AppUpdateStageCheck.refusal(staged.details, offeredBuild: offeredBuild) {",
     "                if let refusal = Optional<String>.none, !staged.message.isEmpty {", "[stage check]", "wiring"),
    ("apply without the expected build", C, "                if let stagedBuild = staged.details[\"latestBuild\"]?.int { apply += [\"--expected-build\", String(stagedBuild)] }\n", "", "[stage check build]", "wiring"),
    ("helper: unreachable stage says ok", H, "            throw HelperError.message(\"COS Control could not reach the update feed. Nothing was installed.\")",
     "            details[\"reason\"] = \"unreachable\"; emit(ok: true, message: \"Update check unavailable\", details: details); return", "[stage refuses]", "helper"),
    ("helper: up-to-date stage says ok", H, "            throw HelperError.message(\"COS Control is already up to date. Nothing was installed.\")",
     "            details[\"reason\"] = \"upToDate\"; emit(ok: true, message: \"COS Control is up to date\", details: details); return", "[stage refuses]", "helper"),
    ("helper: detach skips the stage proof", H, "        _ = try requireStagedUpdate(expectedBuild: expectedBuild)\n", "", "[apply needs a stage]", "helper"),
    ("helper: expected build not compared", H, "        if let expectedBuild, build != expectedBuild {", "        if let expectedBuild, build != expectedBuild, false {", "[apply expected build]", "helper"),
    # QA item 2: the after-update window.
    ("first run shows", M, "        guard let lastSeen else { return installedByUpdater == running ? .updated : .firstRun }", "        guard let lastSeen else { return .updated }", "[after update", "models"),
    # QA round 2: an update from 0.5.274 (nothing remembered) is recognised by the updater's success record.
    ("updater record ignored", M, "        guard let lastSeen else { return installedByUpdater == running ? .updated : .firstRun }", "        guard let lastSeen else { return .firstRun }", "[after update updater]", "models"),
    ("any updater record counts", M, "        guard let lastSeen else { return installedByUpdater == running ? .updated : .firstRun }", "        guard let lastSeen else { return installedByUpdater != nil ? .updated : .firstRun }", "[after update updater]", "models"),
    ("model never reads the record", C, "        let updater = WhatsNewAfterUpdate.updaterBuild(try? Data(contentsOf: updateSuccessRecord))\n", "        let updater: Int? = nil\n", "[after update updater]", "wiring"),
    ("swap reopens before Control quits", H, "            ])\n            waitForLiveToQuit(live)\n            if ProcessInfo.processInfo.environment[\"COS_CONTROL_TEST_HOME\"] == nil {\n                _ = try? execute(\"/usr/bin/open\", [live.path], timeout: 10)\n            }\n            throw error",
     "            ])\n            if ProcessInfo.processInfo.environment[\"COS_CONTROL_TEST_HOME\"] == nil {\n                _ = try? execute(\"/usr/bin/open\", [live.path], timeout: 10)\n            }\n            throw error", "[swap waits]", "pins"),
    ("rollback shows", M, "        return lastSeen < running ? .updated : .seen", "        return lastSeen != running ? .updated : .seen", "[after update launch]", "models"),
    ("meeting ignored", M, "        launch == .updated && checkReached && !meetingActive", "        launch == .updated && checkReached", "[after update meeting]", "models"),
    ("stale bundled copy shown", M, "              object[\"version\"]?.string == version else { return nil }", "              object[\"version\"]?.string != nil else { return nil }", "[after update content]", "models"),
    ("another build's appcast words", M, "        if info.latestBuild == build, info.latestVersion == version,", "        if info.latestVersion == version,", "[after update content]", "models"),
    ("build never remembered", C, "        postUpdateLaunch = .seen\n        whatsNewSeen.lastSeenBuild = Self.currentBuild\n", "        whatsNewSeen.lastSeenBuild = Self.currentBuild - 1\n", "[after update", "wiring"),
    ("first run not remembered", C, "        if postUpdateLaunch == .firstRun { whatsNewSeen.lastSeenBuild = Self.currentBuild }\n", "", "[after update first run]", "wiring"),
    ("shows before the feed answers", C, "        guard incoming.reason != \"unreachable\", incoming.reason != \"malformed\", incoming.reason != \"idle\" else { return }\n", "", "[after update show]", "wiring"),
    ("refresh never asks again", C, "            // A What's New held back by a recording meeting shows once the meeting ends (cheap when nothing waits).\n            considerPostUpdateWhatsNew()\n", "", "[after update meeting]", "pins"),
    ("release ships no notes", B, "cp \"$ROOT/Resources/WhatsNew.json\" \"$APP/Contents/Resources/\"\n", "", "[bundled notes]", "pins"),
    # The helper copy of the sanitizer.
    ("helper passes whatsNew raw", H, "if let whatsNew = Self.sanitizedWhatsNew(stable[\"whatsNew\"]) { details[\"whatsNew\"] = whatsNew }",
     "if let whatsNew = stable[\"whatsNew\"] { details[\"whatsNew\"] = whatsNew }", "[whatsNew", "helper"),
    ("helper drops whatsNew", H, "if let whatsNew = Self.sanitizedWhatsNew(stable[\"whatsNew\"]) { details[\"whatsNew\"] = whatsNew }", "", "[whatsNew valid]", "helper"),
    ("helper summary cap raised", H, "    static let whatsNewSummaryLimit = 1200,", "    static let whatsNewSummaryLimit = 2000,", "[whatsNew oversize]", "helper"),
    ("helper no section cap", H, "            guard sections.count < whatsNewSectionLimit else { break }\n", "", "[whatsNew oversize]", "helper"),
    ("helper no item cap", H, "                guard items.count < whatsNewItemLimit else { break }\n", "", "[whatsNew oversize]", "helper"),
    ("helper control characters kept", H, "            } else if scalar.properties.generalCategory == .control {\n                scalars.append(\" \")\n            } else if scalar.properties.generalCategory != .format {\n                scalars.append(scalar)\n            }\n        }\n        var lines: [String] = []\n        for line in String(scalars).split(separator: \"\\n\", omittingEmptySubsequences: false) {\n            let words = line.split(separator: \" \", omittingEmptySubsequences: true).joined(separator: \" \")\n            if words.isEmpty && (lines.last?.isEmpty ?? true) { continue }\n            lines.append(words)\n        }\n        while lines.last?.isEmpty == true { lines.removeLast() }\n        var result = lines.joined(separator: \"\\n\")\n        guard !result.isEmpty else { return nil }\n        if result.count > limit {\n            result = String(result.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespacesAndNewlines) + \"…\"\n        }\n        let scalarLimit = limit * whatsNewScalarsPerCharacter",
     "            } else if false {\n                scalars.append(\" \")\n            } else if scalar.properties.generalCategory != .format {\n                scalars.append(scalar)\n            }\n        }\n        var lines: [String] = []\n        for line in String(scalars).split(separator: \"\\n\", omittingEmptySubsequences: false) {\n            let words = line.split(separator: \" \", omittingEmptySubsequences: true).joined(separator: \" \")\n            if words.isEmpty && (lines.last?.isEmpty ?? true) { continue }\n            lines.append(words)\n        }\n        while lines.last?.isEmpty == true { lines.removeLast() }\n        var result = lines.joined(separator: \"\\n\")\n        guard !result.isEmpty else { return nil }\n        if result.count > limit {\n            result = String(result.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespacesAndNewlines) + \"…\"\n        }\n        let scalarLimit = limit * whatsNewScalarsPerCharacter", "[whatsNew control chars]", "helper"),
    ("helper format characters kept", H, "                scalars.append(\" \")\n            } else if scalar.properties.generalCategory != .format {\n                scalars.append(scalar)\n            }\n        }\n        var lines: [String] = []\n        for line in String(scalars).split(separator: \"\\n\", omittingEmptySubsequences: false) {\n            let words = line.split(separator: \" \", omittingEmptySubsequences: true).joined(separator: \" \")\n            if words.isEmpty && (lines.last?.isEmpty ?? true) { continue }\n            lines.append(words)\n        }\n        while lines.last?.isEmpty == true { lines.removeLast() }\n        var result = lines.joined(separator: \"\\n\")\n        guard !result.isEmpty else { return nil }\n        if result.count > limit {\n            result = String(result.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespacesAndNewlines) + \"…\"\n        }\n        let scalarLimit = limit * whatsNewScalarsPerCharacter",
     "                scalars.append(\" \")\n            } else if true {\n                scalars.append(scalar)\n            }\n        }\n        var lines: [String] = []\n        for line in String(scalars).split(separator: \"\\n\", omittingEmptySubsequences: false) {\n            let words = line.split(separator: \" \", omittingEmptySubsequences: true).joined(separator: \" \")\n            if words.isEmpty && (lines.last?.isEmpty ?? true) { continue }\n            lines.append(words)\n        }\n        while lines.last?.isEmpty == true { lines.removeLast() }\n        var result = lines.joined(separator: \"\\n\")\n        guard !result.isEmpty else { return nil }\n        if result.count > limit {\n            result = String(result.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespacesAndNewlines) + \"…\"\n        }\n        let scalarLimit = limit * whatsNewScalarsPerCharacter", "[whatsNew control chars]", "helper"),
    ("helper scalar cap removed", H, "        let scalarLimit = limit * whatsNewScalarsPerCharacter\n        if result.unicodeScalars.count > scalarLimit {", "        let scalarLimit = limit * whatsNewScalarsPerCharacter\n        if false, result.unicodeScalars.count > scalarLimit {", "[whatsNew scalar cap]", "helper"),
    ("helper empty section kept", H, "            if !items.isEmpty { sections.append([\"title\": title, \"items\": items]) }", "            sections.append([\"title\": title, \"items\": items])", "[whatsNew wrong types]", "helper"),
    ("helper summary loses lines", H, "cleanWhatsNewText($0, limit: whatsNewSummaryLimit, keepNewlines: true)", "cleanWhatsNewText($0, limit: whatsNewSummaryLimit, keepNewlines: false)", "[whatsNew valid]", "helper"),  # the valid summary has a line break
    # The window and who opens it, executed.
    ("Check for updates does not open", C, "                if appUpdateFlow.phase == .ready { presentWhatsNew() }\n", "", "[check for updates opens]", "wiring"),
    ("background check opens", C, "            appUpdate = AppUpdateInfo.merging(previous: appUpdate, incoming: incoming)\n            noteCheckReached(incoming)\n",
     "            appUpdate = AppUpdateInfo.merging(previous: appUpdate, incoming: incoming)\n            noteCheckReached(incoming)\n            presentWhatsNew()\n", "[background check]", "wiring"),
    ("a new window each open", V, "        if let window = controller?.window { return window }\n", "", "[single window]", "wiring"),
    ("presentWhatsNew does nothing", C, "        whatsNewMode = .offer\n        showWhatsNew?()\n", "        whatsNewMode = .offer\n", "[check for updates opens]", "wiring"),
    # Wiring the gate cannot execute (a person clicks it), pinned.
    ("banner installs without the window", V, "                model.presentWhatsNew()\n", "                model.installAppUpdate()\n", "[banner opens]", "pins"),
    ("Download and install does nothing", V, "onInstall: { model.installAppUpdate() }", "onInstall: {}", "[install path]", "pins"),
    ("app never wires the window", A, "        model.showWhatsNew = { whatsNewWindow.show(model: model) }\n", "", "[app wires window]", "pins"),
    ("eyebrow heading", V, "                .font(COSType.body(16, weight: .semibold))\n", "                .font(COSType.body(16, weight: .semibold)).textCase(.uppercase).tracking(1.2)\n", "[no eyebrow kickers]", "pins"),
    ("Cancel never disabled", V, "                    .disabled(!footer.cancelEnabled)\n", "", "[footer buttons]", "pins"),
    ("Return installs", V, "                        .disabled(!footer.primaryEnabled)\n", "                        .disabled(!footer.primaryEnabled)\n                        .keyboardShortcut(.defaultAction)\n", "[return never installs]", "pins"),
    ("summary as Markdown", V, "Text(verbatim: content.summaryText)", "Text(LocalizedStringKey(content.summaryText))", "[verbatim text]", "pins"),
    ("no recenter", V, "        if !window.isVisible { window.center() }\n", "", "[recenter]", "pins"),
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
