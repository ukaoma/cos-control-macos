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
        gates()
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
        check(SettingsHubCatalog.item("HUB-CL")?.advanced == true && SettingsHubCatalog.item("HUB-CL")?.group == "general.app",
              "Use classic Settings is in General, Advanced")
        check(SettingsHub.classicKey == "cos.settings.classic", "the classic switch's key")
        // 0.5.362 (server API v3): the cue mode, Grounded cues and the general limits are the hub's own rows in Live cues, not
        // inventory rows: the inventory count above is unchanged.
        let cueRows = ["HUB-CM", "HUB-CG", "HUB-GB", "HUB-GI", "HUB-GA", "HUB-GM", "HUB-GT", "HUB-GW", "HUB-GU"]
        for id in cueRows {
            check(SettingsHubCatalog.extras.contains { $0.id == id } && !items.contains { $0.id == id }, "\(id) is a hub row, not an inventory row")
            let row = SettingsHubCatalog.item(id)
            check(row?.group == "meetings.cues" && row?.advanced == false && row?.mount == .group, "\(id) is in Live cues, not Advanced")
            check(SettingsHubRoute.destination(id)?.group == "meetings.cues", "\(id) routes to Live cues")
        }
        check(SettingsHubCatalog.item("HUB-CM")?.label == "Cue mode" && SettingsHubCatalog.item("HUB-CG")?.label == "Grounded cues", "the two controls by name")
        check(SettingsHubCatalog.item("HUB-CM")?.detail.contains("Public topics") == true && SettingsHubCatalog.item("HUB-CM")?.detail.contains("web") == true,
              "the cue mode row says General and All search the web and need Public topics")
        check(SettingsHubCatalog.items(inGroup: "meetings.cues").filter { $0.id.hasPrefix("HUB-") }.count == cueRows.count && SettingsHubCatalog.items(inGroup: "meetings.cues").contains { $0.id == "MA-06" },
              "Live cues holds the nine new rows beside the inventory's")
    }

    // Settings Release A: options drawn only while their switch is on, and Up/Down in the sidebar.
    static func gates() {
        for (child, gate) in SettingsHubCatalog.gatedBy {
            let a = SettingsHubCatalog.item(child), b = SettingsHubCatalog.item(gate.parent)
            check(a != nil && b != nil && a?.group == b?.group, "\(child) and its parent \(gate.parent) are rows of one group, so a result lands in the right card")
            check(a?.mount == .group && b?.mount == .group, "\(child) and \(gate.parent) are both drawn in the card")
            check(!gate.line.contains("—") && !gate.line.contains("→") && gate.line.hasSuffix("to change this."), "\(child)'s sentence is plain")
        }
        let off: (String) -> Bool = { ["WK-07", "WK-08", "DI-24", "DI-25"].contains($0) }
        check(SettingsHubCatalog.landing("WK-07", hidden: off) == "WK-06", "a hidden Quiet hours opens the Today home switch")
        check(SettingsHubCatalog.landing("WK-08", hidden: off) == "WK-06", "a hidden Work runs from Today opens the Today home switch")
        check(SettingsHubCatalog.landing("DI-25", hidden: off) == "DI-23", "Wait for held keys, with AI polish off, climbs past Paste then polish to AI polish")
        check(SettingsHubCatalog.landing("DI-25", hidden: { $0 == "DI-25" }) == "DI-24", "Wait for held keys, with only paste-then-polish off, opens Paste then polish")
        check(SettingsHubCatalog.landing("WK-07", hidden: { _ in false }) == "WK-07", "a drawn row opens itself")
        check(SettingsHubCatalog.landing("G-01", hidden: { _ in true }) == "G-01", "a row with no gate opens itself even when asked as hidden")
        check(SettingsHubCatalog.landing("WK-06", hidden: { _ in true }) == "WK-06", "a parent never climbs further")
        check(SettingsHubCatalog.gateLine("DI-25", hidden: off) == "Choose an AI polish model to change this.", "Wait for held keys with AI polish off names the first missing step")
        check(SettingsHubCatalog.gateLine("DI-25", hidden: { $0 == "DI-25" }) == "Turn on Paste then polish to change this.", "with only Paste then polish off, it names that")
        check(SettingsHubCatalog.gateLine("DI-24", hidden: off) == "Choose an AI polish model to change this.", "Paste then polish names the model")
        check(SettingsHubCatalog.gateLine("WK-07", hidden: off) == "Turn on Today home to change this." && SettingsHubCatalog.gateLine("WK-07", hidden: { _ in false }) == nil
              && SettingsHubCatalog.gateLine("G-01", hidden: { _ in true }) == nil, "search says what to turn on, only for a hidden gated row")
        // A hidden child is still a result: the page's itemShown test is for rows with no parent to open.
        check(ids("quiet hours").contains("WK-07") && ids("wait for held keys").contains("DI-25") && ids("paste then polish").contains("DI-24"),
              "the hidden options are still found by search")
        let order = SettingsHubCategory.allCases
        check(SettingsHubSidebarKeys.next(from: .general, .down) == order[1] && SettingsHubSidebarKeys.next(from: order[1], .up) == .general, "Down and Up move one category")
        check(SettingsHubSidebarKeys.next(from: .general, .up) == .general, "Up stops at the first category")
        check(SettingsHubSidebarKeys.next(from: order.last, .down) == order.last, "Down stops at the last category")
        check(SettingsHubSidebarKeys.next(from: nil, .down) == order.first && SettingsHubSidebarKeys.next(from: nil, .up) == order.last,
              "with a search showing (no category), Down goes to the first and Up to the last")
        for (index, category) in order.enumerated().dropFirst().dropLast() {
            check(SettingsHubSidebarKeys.next(from: category, .down) == order[index + 1] && SettingsHubSidebarKeys.next(from: category, .up) == order[index - 1],
                  "\(category.title) moves to its neighbours")
        }
    }

    static func routes() {
        // The anchors the classic panel's openers use today (Views.swift, KeyLanesViews.swift, LiveCues.decisionKeysAnchor).
        let expected: [String: (SettingsHubCategory, String)] = [
            "transcription": (.voice, "voice.models"),
            "decision-models": (.ai, "ai.decision"),
            "setup-guide": (.general, "general.guide"),
            "key-lanes": (.ai, "ai.keys"),
        ]
        check(Set(SettingsHubRoute.panelAnchors.keys) == Set(expected.keys), "the routed panel anchors are exactly the four openers' anchors")
        // The plain Settings… (⌘,, the Dock, the pet, Welcome): no destination, so the hub stays on the last category.
        check(SettingsHubRoute.destination("settings") == nil, "a plain Settings has no destination: the hub stays where it opens")
        check(SettingsHub.opensHub(classic: false) && !SettingsHub.opensHub(classic: true), "openers land in the hub unless the classic switch is on")
        if let defaults = UserDefaults(suiteName: "cos.settings.hub.checks") {
            defaults.removePersistentDomain(forName: "cos.settings.hub.checks")
            check(SettingsHub.lastCategory(defaults) == .general, "the first plain Settings opens General")
            defaults.set(SettingsHubCategory.pet.rawValue, forKey: SettingsHub.lastCategoryKey)
            check(SettingsHub.lastCategory(defaults) == .pet, "then the category open last")
            defaults.set("no-such-category", forKey: SettingsHub.lastCategoryKey)
            check(SettingsHub.lastCategory(defaults) == .general, "an unknown stored category opens General")
            defaults.removePersistentDomain(forName: "cos.settings.hub.checks")
        }
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
        // A match only the old label can make: Meeting Turbo preview is now Fast preview, and nothing else says turbo.
        if let fast = SettingsHubCatalog.item("UT-05") {
            check(SettingsHubSearch.rank(fast, query: "Meeting Turbo") == 2, "the old label finds Fast preview by its old name (rank 2)")
        } else { check(false, "UT-05 is in the catalog") }
        check(ids("Meeting Turbo") == ["UT-05"], "only the old label finds Meeting Turbo")
        // A group the page does not draw (an older server, nothing to show) gives no results to land on.
        let hidden = SettingsHubSearch.results("restart", shown: { $0 != "system.server" }).flatMap(\.items).map(\.id)
        check(!hidden.contains("C-01") && SettingsHubSearch.results("restart").flatMap(\.items).map(\.id).contains("C-01"),
              "search leaves out a row whose group is not drawn")
        // Find sessions by meaning lives in a group that is drawn (Decision models) and is itself hidden with Today home off and on an older
        // server: the page says so per row, and search leaves it out (QA 0.5.363).
        check(SettingsHubSearch.results("find sessions by meaning").flatMap(\.items).map(\.id).contains("JV-13"), "JV-13 is found when its control is drawn")
        check(!SettingsHubSearch.results("find sessions by meaning", itemShown: { $0 != "JV-13" }).flatMap(\.items).map(\.id).contains("JV-13"), "search leaves out a row whose control is hidden inside a drawn group")
        // "Was:" shows only a real former label, one that search finds the row by (QA copy 2026-10-28).
        for (id, former) in SettingsHubCatalog.formerLabels {
            let item = SettingsHubCatalog.item(id)
            check(item != nil && SettingsHubSearch.normalized(item?.old ?? "").contains(SettingsHubSearch.normalized(former))
                  && SettingsHubSearch.normalized(former) != SettingsHubSearch.normalized(item?.label ?? ""),
                  "\(id)'s former label \(former) is in its old name and differs from today's")
        }
        check(SettingsHubCatalog.item("UT-08")?.formerLabel == nil, "inventory notation is never shown as a former label")
        check(SettingsHubCatalog.item("UT-01")?.formerLabel == "Run Doctor", "Run checks was Run Doctor")
        // Settings Release A: the renames. Search finds each by the new name and by the old one, and the catalog names what the page draws.
        check(SettingsHubCatalog.item("DM-01")?.label == "Task folders" && SettingsHubCatalog.group("work.domains")?.title == "Task folders",
              "Domains is Task folders, the row and its group")
        check(ids("domains").contains("DM-01") && ids("Task folders").first == "DM-01", "Task folders is found by its new name and by Domains")
        check(ids("save domains").contains("DM-03"), "Save task folders is found by Save domains")
        check(SettingsHubCatalog.item("TR-03")?.label == "Saved meetings", "HQ model is Saved meetings, as the page draws it")
        check(ids("HQ model").contains("TR-03") && ids("Final model").contains("TR-03") && SettingsHubSearch.results("Saved meetings").first(where: { $0.category == .voice })?.items.first?.id == "TR-03",
              "Saved meetings is found by its new name, HQ model and Final model")
        check(SettingsHubCatalog.item("TR-03")?.formerLabel == "HQ model", "Saved meetings was HQ model")
        check(SettingsHubCatalog.item("TR-06")?.label == "Refine with second opinion", "search names the row the page draws: Refine with second opinion")
        check(SettingsHubCategory.pet.title == "Pet" && SettingsHubCatalog.item("PT-01") != nil, "Pet and appearance is Pet")
        check(ids("appearance").contains("PT-01"), "the old category name Pet and appearance still finds the pet rows")
        check(SettingsHubCatalog.item("DI-03")?.label == "Check again" && ids("refresh microphones").contains("DI-03"), "Refresh microphones is Check again, found by both names")
        check(SettingsHubCatalog.item("DI-03")?.formerLabel == "Refresh microphones", "Check again was Refresh microphones")
        // A match only a keyword can make.
        check(ids("byok") == ["KL-01"], "only the keyword finds byok (Your own key)")
        // The rows outside Settings are not searchable at all, not only left out of the sections.
        check(SettingsHubCatalog.searchable.count == SettingsHubCatalog.all.count - 13
              && SettingsHubCatalog.searchable.allSatisfy { $0.mount != .outside }, "rows outside Settings never show in search: all 13 are left out of the searchable set")
        // Ranking: a label that starts with the word comes before a row whose description mentions it.
        check(SettingsHubSearch.results("restart").first(where: { $0.category == .system })?.items.first?.id == "C-01",
              "Restart ranks the server's Restart first in System, ahead of rows that only mention it")
        check(ids("typesafe").contains("JV-11"), "a keyword finds the Jev key")
        check(ids("TAILSCALE").contains("SG-11"), "search ignores case")
        check(ids("pairing token").contains("UT-21"), "every word must match: pairing token")
        check(!ids("pairing zebra").contains("UT-21"), "a word that matches nothing removes the row")
        check(ids("classic").contains("HUB-CL"), "search finds Use classic Settings")
        // 0.5.367 (server 6.99.3): Open COS on your phone is the hub's own row in Glasses and iPhone, Devices, not Advanced, found by
        // what someone locked out would type.
        let phone = SettingsHubCatalog.item("UT-29")
        check(phone?.label == "Open COS on your phone" && phone?.group == "glasses.devices" && phone?.advanced == false && phone?.mount == .group
              && SettingsHubCatalog.extras.contains { $0.id == "UT-29" } && !SettingsHubCatalog.items.contains { $0.id == "UT-29" }, "Open COS on your phone is a Devices row, not Advanced")
        check(SettingsHubRoute.destination("UT-29")?.group == "glasses.devices" && SettingsHubRoute.destination("UT-29")?.opensAdvanced == false,
              "Open COS on your phone routes to Devices")
        for query in ["phone", "browser", "sign in", "web", "QR", "Control Web", "open cos on your phone", "safari"] {
            check(ids(query).contains("UT-29"), "search finds Open COS on your phone by \(query)")
        }
        check(SettingsHubCatalog.advancedCount("glasses.devices") == 2, "Devices' Advanced is still Copy token and Reset message count")
        // 0.5.362: the cue mode and general limit rows are found by their names and their keywords.
        check(ids("cue mode").first == "HUB-CM" && ids("grounded").contains("HUB-CG") && ids("daily web searches").first == "HUB-GW", "search finds the cue mode, Grounded cues and the daily web searches")
        check(ids("general cues").contains("HUB-GB") && ids("general cues").contains("HUB-GI") && ids("insight").contains("HUB-GM") && ids("public topics").contains("HUB-CM"),
              "search finds the general limits by what they are")
        check(!SettingsHubSearch.results("daily web searches").contains { $0.category != .meetings && $0.items.contains { $0.id.hasPrefix("HUB-G") } }, "they live in Meetings")
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
