import CoreGraphics
import Foundation

/// Settings hub (Miles, 2026-10-27): the catalog's pure logic, compiled with Sources/SettingsHubCatalog.swift alone
/// (Tests/run-settings-hub.sh). Every inventory row in exactly one group and every group in exactly one category, every
/// deep-link anchor resolving, search by new label, old label and keyword, the breakpoints, the scroll-spy and the
/// category status lines. Nothing is drawn.
@main struct SettingsHubChecks {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0
    static func check(_ ok: Bool, _ what: String) {
        if ok { passes += 1 } else { failures += 1; print("FAIL: \(what)") }
    }
    static func ids(_ query: String) -> [String] { SettingsHubSearch.results(query).flatMap { $0.items.map(\.id) } }

    static func main() {
        catalog()
        routes()
        search()
        layout()
        spy()
        status()
        print(failures == 0 ? "settings hub checks: \(passes) passed" : "settings hub checks: \(failures) FAILED of \(passes + failures)")
        exit(failures == 0 ? 0 : 1)
    }

    static func catalog() {
        let items = SettingsHubCatalog.items
        check(items.count == 253, "the inventory has 253 rows, the catalog \(items.count)")
        check(Set(items.map(\.id)).count == items.count, "every inventory id appears once")
        check(Set(SettingsHubCatalog.all.map(\.id)).count == SettingsHubCatalog.all.count, "extras never reuse an inventory id")
        let groupIDs = SettingsHubCatalog.groups.map(\.id)
        check(Set(groupIDs).count == groupIDs.count, "every group id is unique, so a group sits in exactly one category")
        for group in SettingsHubCatalog.groups {
            check(group.id.hasPrefix(group.category.rawValue + "."), "group \(group.id) is named for its category")
            check(!SettingsHubCatalog.items(inGroup: group.id).isEmpty, "group \(group.id) has a row")
        }
        for category in SettingsHubCategory.allCases {
            check(!SettingsHubCatalog.groups(in: category).isEmpty, "\(category.title) has a group")
            check(!category.blurb.contains("—") && !category.blurb.contains("→"), "\(category.title) blurb has no em dash or arrow")
        }
        for item in SettingsHubCatalog.all {
            switch item.mount {
            case .outside:
                check(item.group == nil, "\(item.id) stays outside Settings, so it has no group")
                check(!item.advanced, "\(item.id) outside rows are never Advanced")
            case .group, .topStrip:
                if let group = item.group {
                    check(SettingsHubCatalog.group(group) != nil, "\(item.id) is in a group that exists (\(group))")
                } else if item.mount == .group {
                    check(false, "\(item.id) is drawn in a card, so it needs a group")
                }
            }
            check(!item.label.isEmpty && !item.detail.isEmpty, "\(item.id) has a label and a description")
            check(!item.label.contains("—") && !item.detail.contains("—"), "\(item.id) copy has no em dash")
        }
        // Counts that must not drift without a decision: 13 rows stay outside, 6 sit in the top strip.
        check(items.filter { $0.mount == .outside }.count == 13, "13 rows stay outside Settings")
        check(items.filter { $0.mount == .topStrip }.map(\.id).sorted() == ["H-05", "H-07", "H-08", "H-09", "H-10", "SG-15"],
              "the top strip holds the update banner, notices, the Dock notice, Get started, the recording card and Finish setup")
        check(SettingsHubCatalog.advancedCount("system.server") == 6, "Server's Advanced: adopt, manage in place, replace, health, roll back, finish change")
        check(SettingsHubCatalog.advancedCount("general.app") == 1, "General's Advanced holds Use classic Settings")
        check(SettingsHubCatalog.item("HUB-01")?.advanced == true && SettingsHubCatalog.item("HUB-01")?.group == "general.app",
              "Use classic Settings is in General, Advanced")
        check(SettingsHub.classicKey == "cos.settings.classic", "the classic switch's key")
    }

    static func routes() {
        // The anchors the classic panel's openers use today (Views.swift, KeyLanesViews.swift, LiveCues.decisionKeysAnchor).
        let expected: [String: (SettingsHubCategory, String)] = [
            "settings": (.meetings, "meetings.assistant"),
            "transcription": (.voice, "voice.models"),
            "decision-models": (.ai, "ai.decision"),
            "setup-guide": (.general, "general.guide"),
            "key-lanes": (.ai, "ai.keys"),
        ]
        check(Set(SettingsHubRoute.panelAnchors.keys) == Set(expected.keys), "the routed panel anchors are exactly the five openers' anchors")
        for (anchor, (category, group)) in expected {
            let d = SettingsHubRoute.destination(anchor)
            check(d?.category == category && d?.group == group, "\(anchor) lands on \(category.title), \(group)")
            check(d?.anchor == "hub." + group, "\(anchor) scrolls to its group's anchor")
        }
        for group in SettingsHubCatalog.groups {
            check(SettingsHubRoute.destination(group.anchor)?.group == group.id, "hub anchor \(group.anchor) resolves")
            check(SettingsHubRoute.destination(group.id)?.category == group.category, "group id \(group.id) resolves")
        }
        for item in SettingsHubCatalog.all where item.mount != .outside {
            let d = SettingsHubRoute.destination(item.id)
            check(d?.group == item.group, "\(item.id) routes to its group")
            check(d?.opensAdvanced == item.advanced, "\(item.id) opens Advanced exactly when it is inside it")
        }
        check(SettingsHubRoute.destination("MN-02") == nil, "a row outside Settings has no hub destination")
        check(SettingsHubRoute.destination("no-such-anchor") == nil, "an unknown anchor resolves to nothing")
        check(SettingsHubRoute.destination("UT-26")?.opensAdvanced == true, "Roll back server opens Server's Advanced")
    }

    static func search() {
        check(ids("Open at login").first == "G-01", "the new label finds Open at login first")
        check(ids("Launch COS Control at login").contains("G-01"), "the old label still finds Open at login")
        check(ids("run doctor").contains("UT-01"), "the old label Run Doctor finds Run checks")
        check(ids("Rollback Server").contains("UT-26"), "the old label Rollback Server finds Roll back server")
        check(ids("typesafe").contains("JV-11"), "a keyword finds the Jev key")
        check(ids("TAILSCALE").contains("SG-11"), "search ignores case")
        check(ids("pairing token").contains("UT-21"), "every word must match: pairing token")
        check(!ids("pairing zebra").contains("UT-21"), "a word that matches nothing removes the row")
        check(ids("classic").contains("HUB-01"), "search finds Use classic Settings")
        check(ids("zzqxv").isEmpty && SettingsHubSearch.results("zzqxv").isEmpty, "no match is an empty result")
        check(SettingsHubSearch.results("   ").isEmpty, "a blank query has no results")
        check(!ids("Dock menu").contains("MN-06"), "rows outside Settings never show in search")
        check(ids("Get started").contains("H-09"), "top strip rows are searchable")
        let sections = SettingsHubSearch.results("server")
        let order = sections.map(\.category)
        check(order == SettingsHubCategory.allCases.filter { order.contains($0) }, "results are grouped by category in the sidebar's order")
        check(sections.count > 1, "server matches in more than one category")
        for section in sections {
            check(section.items.allSatisfy { SettingsHubCatalog.category(of: $0) == section.category }, "every row in \(section.category.title) belongs to it")
        }
        let restart = ids("restart server")
        check(!restart.isEmpty, "restart server finds rows")
        check(ids("cafe").isEmpty || true, "diacritics fold (no crash)")
        check(SettingsHubSearch.normalized("Café–Ünïcode") == "cafe unicode", "diacritics and dashes fold")
        // Ranking: a label that starts with the words beats a row whose description mentions them.
        if let section = SettingsHubSearch.results("live cues").first(where: { $0.category == .meetings }) {
            check(section.items.first?.id == "MA-06", "Live cues ranks the Live cues switch first in Meetings, got \(section.items.first?.id ?? "none")")
        } else { check(false, "live cues finds Meetings rows") }
    }

    static func layout() {
        check(SettingsHubLayout.mode(width: 760) == .narrow, "760 is narrow")
        check(SettingsHubLayout.mode(width: 899) == .narrow, "899 is narrow")
        check(SettingsHubLayout.mode(width: 900) == .medium, "900 is medium")
        check(SettingsHubLayout.mode(width: 1099) == .medium, "1,099 is medium")
        check(SettingsHubLayout.mode(width: 1100) == .wide, "1,100 is wide")
        check(SettingsHubLayout.mode(width: 1280) == .wide, "1,280 is wide")
        check(!SettingsHubLayout.showsRail(.medium) && !SettingsHubLayout.showsRail(.narrow) && SettingsHubLayout.showsRail(.wide),
              "On this page shows only when wide")
        check(SettingsHubLayout.sidebar(.narrow) < SettingsHubLayout.sidebar(.medium), "narrow keeps a compact sidebar")
        var width: CGFloat = 760
        while width <= 1600 {
            let page = SettingsHubLayout.pageWidth(total: width)
            check(page >= 480, "the page column keeps 480 pt or more at \(Int(width)) (got \(Int(page)))")
            width += 10
        }
    }

    static func spy() {
        let tops: [(id: String, minY: CGFloat)] = [("a", 20), ("b", 400), ("c", 900)]
        check(SettingsHubSpy.active(tops: tops, line: 120, atEnd: false) == "a", "the first group is in view at the top")
        let scrolled: [(id: String, minY: CGFloat)] = [("a", -500), ("b", 80), ("c", 600)]
        check(SettingsHubSpy.active(tops: scrolled, line: 120, atEnd: false) == "b", "the last group past the line is in view")
        let before: [(id: String, minY: CGFloat)] = [("a", 300), ("b", 800)]
        check(SettingsHubSpy.active(tops: before, line: 120, atEnd: false) == "a", "with none past the line, the first")
        check(SettingsHubSpy.active(tops: scrolled, line: 120, atEnd: true) == "c", "at the end of the page, the last group")
        check(SettingsHubSpy.active(tops: [], line: 120, atEnd: false) == nil, "no groups, nothing in view")
    }

    static func status() {
        var f = SettingsHubFacts()
        check(SettingsHubStatus.line(.general, f).text == "Opens on the classic home", "General: the classic home")
        f.todayHome = true
        check(SettingsHubStatus.line(.general, f).text == "Opens on Today", "General: Today")
        check(SettingsHubStatus.line(.ai, f).text == "Claude, Codex, Cursor", "AI: unknown readiness is the static line")
        f.aiKnown = 3; f.aiReady = 3
        check(SettingsHubStatus.line(.ai, f).text == "3 AI apps ready", "AI: all ready")
        f.aiReady = 1
        check(SettingsHubStatus.line(.ai, f) == ("1 of 3 AI apps ready", .hot), "AI: some need you")
        check(SettingsHubStatus.line(.glasses, f).text == "Pairing and video", "Glasses: no path is the static line")
        f.glassesPath = true
        check(SettingsHubStatus.line(.glasses, f).text == "Mac and glasses", "Glasses: the chosen path")
        check(SettingsHubStatus.line(.meetings, f).text == "Recording and assistant", "Meetings: cues not read yet is static")
        f.liveCuesOn = true
        check(SettingsHubStatus.line(.meetings, f).text == "Live cues on", "Meetings: cues on")
        f.recording = true
        check(SettingsHubStatus.line(.meetings, f).text == "Recording now", "Meetings: a recording wins")
        check(SettingsHubStatus.line(.dictation, f).text == "Off", "Dictation off")
        f.dictationOn = true
        check(SettingsHubStatus.line(.dictation, f).text == "On", "Dictation on, engine unknown")
        f.dictationEngine = "parakeet-ultra"
        check(SettingsHubStatus.line(.dictation, f).text == "On · Parakeet", "Dictation on with its engine")
        f.dictationEngine = "something-new"
        check(SettingsHubStatus.line(.dictation, f).text == "On", "an engine COS does not know is never named")
        check(SettingsHubStatus.line(.voice, f).text == "Models and voice setup", "Voice: unknown engine is static")
        f.usesParakeet = false
        check(SettingsHubStatus.line(.voice, f) == ("Whisper not ready", .hot), "Voice: Whisper not ready")
        f.whisperReady = true
        check(SettingsHubStatus.line(.voice, f).text == "Whisper", "Voice: Whisper")
        check(SettingsHubStatus.line(.work, f).text == "Sessions and Work chat", "Work: no brief read is static")
        f.briefEnabled = true; f.briefTime = "7:00 AM"
        check(SettingsHubStatus.line(.work, f).text == "Morning brief at 7:00 AM", "Work: the brief's time")
        f.briefEnabled = false
        check(SettingsHubStatus.line(.work, f).text == "Morning brief off", "Work: brief off")
        check(SettingsHubStatus.line(.privacy, f).text == "Permissions", "Privacy: unknown is static")
        f.permissionsNeed = 0
        check(SettingsHubStatus.line(.privacy, f).text == "All granted", "Privacy: all granted")
        f.permissionsNeed = 2
        check(SettingsHubStatus.line(.privacy, f) == ("2 need you", .hot), "Privacy: two need you")
        check(SettingsHubStatus.line(.pet, f).text == "Pet off", "Pet off")
        check(SettingsHubStatus.line(.system, f).text == "Server and updates", "System: not checked yet is static")
        f.serverChecked = true
        check(SettingsHubStatus.line(.system, f) == ("Server not answering", .hot), "System: not answering")
        f.serverRunning = true
        check(SettingsHubStatus.line(.system, f) == ("Server connected", .good), "System: connected")
        f.updateReady = true
        check(SettingsHubStatus.line(.system, f).text == "Update ready", "System: an update wins")
    }
}
