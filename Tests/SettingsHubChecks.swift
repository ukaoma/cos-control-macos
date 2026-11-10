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
        basicView()
        honestSearch()
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
        check(SettingsHubCatalog.advancedCount("system.server") == 8, "Server's Advanced: ownership, recovery (0.5.387), adopt, manage in place, replace, health, roll back, finish change")
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
            // 0.5.387: the mode and Grounded cues stay on the card; the general limits and their usage are Live cues' Advanced.
            let advanced = !["HUB-CM", "HUB-CG"].contains(id)
            check(row?.group == "meetings.cues" && row?.advanced == advanced && row?.mount == .group, "\(id) is in Live cues, \(advanced ? "Advanced" : "not Advanced")")
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
        // 0.5.387 (audit F2): a row the page is not drawing is still a result; honestSearch() checks the line beside it.
        check(SettingsHubSearch.results("find sessions by meaning").flatMap(\.items).map(\.id).contains("JV-13"), "JV-13 is found")
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
        // 0.5.367 (server 6.99.3): Open COS on your phone is the hub's own row, not Advanced, found by what someone locked out would
        // type. 0.5.387: its group is Phone and web, out from under Devices, with Phone approvals beside it.
        let phone = SettingsHubCatalog.item("UT-29")
        check(phone?.label == "Open COS on your phone" && phone?.group == "glasses.phone" && phone?.advanced == false && phone?.mount == .group
              && SettingsHubCatalog.extras.contains { $0.id == "UT-29" } && !SettingsHubCatalog.items.contains { $0.id == "UT-29" }, "Open COS on your phone is a Phone and web row, not Advanced")
        check(SettingsHubRoute.destination("UT-29")?.group == "glasses.phone" && SettingsHubRoute.destination("UT-29")?.opensAdvanced == false,
              "Open COS on your phone routes to Phone and web")
        check(SettingsHubCatalog.item("PK-01")?.group == "glasses.phone" && SettingsHubCatalog.item("PK-01")?.advanced == false
              && SettingsHubCatalog.isBasic("PK-01"), "Phone approvals sits beside it, never Advanced, in Basic too")
        check(SettingsHubCatalog.groups(in: .glasses).map(\.id) == ["glasses.phone", "glasses.devices", "glasses.video"],
              "Phone and web comes first, so the Camera's QR is the first on the page")
        check(SettingsHubCategory.glasses.title == "Glasses, phone and web", "the page is Glasses, phone and web")
        for query in ["phone", "browser", "sign in", "web", "QR", "Control Web", "open cos on your phone", "safari"] {
            check(ids(query).contains("UT-29"), "search finds Open COS on your phone by \(query)")
        }
        // 0.5.387 (recovery rows, lead 2026-11-09): Copy pairing token is on the card on the glasses path only; the Mac-only path keeps
        // 0.5.385's place, Devices' Advanced, beside Reset message count.
        check(SettingsHubCatalog.advancedCount("glasses.devices") == 2 && SettingsHubCatalog.item("UT-21")?.advanced == true,
              "Devices' Advanced in the catalog is still Copy token and Reset message count")
        check(!SettingsHubCatalog.placedAdvanced("UT-21", glassesPath: true) && SettingsHubCatalog.placedAdvanced("UT-21", glassesPath: false)
              && SettingsHubCatalog.drawn("UT-21", view: .basic, glassesPath: true) && !SettingsHubCatalog.drawn("UT-21", view: .basic, glassesPath: false)
              && SettingsHubCatalog.drawn("UT-21", view: .all, glassesPath: false), "Copy pairing token: on the card in Basic on the glasses path; Advanced, All only, on the Mac-only path")
        check(SettingsHubCatalog.placedAdvanced("H-04", glassesPath: true) && !SettingsHubCatalog.placedAdvanced("G-01", glassesPath: false),
              "the device path moves only the rows it names")
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

    // 0.5.387 (Miles, 2026-11-09, "Basic view plus refile").
    static func basicView() {
        // Every basic id is a catalog row the hub draws, and none is Advanced.
        for id in SettingsHubCatalog.basicIDs.sorted() {
            let row = SettingsHubCatalog.item(id)
            check(row != nil, "basic id \(id) is a catalog row")
            check(row?.mount == .group && row?.group != nil, "basic id \(id) is drawn in a card")
            check(row?.advanced == false, "basic id \(id) is not also Advanced")
        }
        // The page counts stay inside their stated ranges.
        var total = 0
        for category in SettingsHubCategory.allCases {
            let n = SettingsHubCatalog.basicCount(category)
            total += n
            let range = SettingsHubCatalog.basicRange[category]
            check(range?.contains(n) == true, "\(category.title) has \(n) basic rows, inside \(range.map { "\($0)" } ?? "no range")")
            check(SettingsHubCatalog.groups(in: category).contains { SettingsHubCatalog.hasBasicRows($0.id) }, "\(category.title) draws a card in Basic")
        }
        // About 45 drawn rows in Miles's preview; 63 catalog rows once the recovery rows and the buttons inside C-01 count (lead 2026-11-09).
        check((45...66).contains(total), "the basic rows across the ten pages stay between 45 and 66, \(total)")
        // A group with no basic row is left out of Basic; one with a basic row is drawn.
        check(!SettingsHubCatalog.hasBasicRows("dictation.sounds") && !SettingsHubCatalog.hasBasicRows("ai.decision")
              && !SettingsHubCatalog.hasBasicRows("meetings.cues") && SettingsHubCatalog.hasBasicRows("work.reach"),
              "Sounds, Decision models and Live cues are not in Basic; COS reaching out is")
        // The view: Basic for a new install, All otherwise, and a choice always wins.
        check(SettingsHubView.key == "cos.settings.view", "the view's key")
        check(SettingsHubView.resolved(stored: nil, newInstall: true) == .basic, "a new install opens Basic")
        check(SettingsHubView.resolved(stored: nil, newInstall: false) == .all, "an existing install keeps every setting")
        check(SettingsHubView.resolved(stored: "all", newInstall: true) == .all, "a new install that chose All gets All")
        check(SettingsHubView.resolved(stored: "basic", newInstall: false) == .basic, "an existing install that chose Basic gets Basic")
        check(SettingsHubView.resolved(stored: "nonsense", newInstall: false) == .all && SettingsHubView.resolved(stored: "nonsense", newInstall: true) == .basic,
              "an unknown stored value falls back to the cohort")
        // Lead, 2026-11-09: the cohort table behind the default (D1's InstallCohort). Undecided or existing gives All; new gives
        // Basic; an explicit choice wins in all three. A Mac carrying cos.keyLanes.install = new from an older build is existing.
        // The page reads `hubCohort == "new"` (InstallCohort.key), as InstallCohort.current does: undecided reads as existing.
        let launchClean = InstallCohort.decideAtLaunch(InstallCohort.Evidence(runningBuild: 441))
        let launchOld = InstallCohort.decideAtLaunch(InstallCohort.Evidence(runningBuild: 441, keyLanesInstall: "new"))
        let adopted = InstallCohort.adopt(stored: nil, keyLanes: "new")
        check(launchClean == nil && launchOld == .existing && adopted == .new,
              "the cohort table: a clean Mac waits for KeyLanes, a Mac with cos.keyLanes.install already set is existing, then KeyLanes' new is kept")
        let undecided = launchClean?.rawValue == InstallCohort.Cohort.new.rawValue
        let existing = launchOld?.rawValue == InstallCohort.Cohort.new.rawValue
        let fresh = adopted?.rawValue == InstallCohort.Cohort.new.rawValue
        check(SettingsHubView.resolved(stored: nil, newInstall: undecided) == .all, "undecided cohort gives All")
        check(SettingsHubView.resolved(stored: nil, newInstall: existing) == .all, "existing cohort gives All")
        check(SettingsHubView.resolved(stored: nil, newInstall: fresh) == .basic, "new cohort with no stored choice gives Basic")
        for cohort in [undecided, existing, fresh] {
            check(SettingsHubView.resolved(stored: "all", newInstall: cohort) == .all && SettingsHubView.resolved(stored: "basic", newInstall: cohort) == .basic,
                  "an explicit choice wins for every cohort")
        }
        // Recovery rows (lead, 2026-11-09): every control another surface tells a person to press is Basic, not Advanced, and
        // found by search under the name that surface uses.
        check(SettingsHubCatalog.recoveryRows.count == 13, "thirteen recovery rows (Clear stuck uploads after Q1's review, Pair on home Wi-Fi after the final review)")
        check(ids("allow pairing on this wi-fi").contains("SG-12") && ids("pair on home wi-fi").contains("SG-12"),
              "search finds Pair on home Wi-Fi by the glasses app's words and by its name")
        // Q1 review M2: only an explicit "Just my Mac" is the Mac-only path; no stored choice counts as possibly glasses.
        check(SettingsHubCatalog.choseMacOnly(storedDevicePath: "mac") && !SettingsHubCatalog.choseMacOnly(storedDevicePath: "glasses")
              && !SettingsHubCatalog.choseMacOnly(storedDevicePath: nil) && !SettingsHubCatalog.choseMacOnly(storedDevicePath: ""),
              "only a stored Just my Mac hides the glasses rows; a Mac with no stored choice keeps them")
        for (name, id) in SettingsHubCatalog.recoveryRows {
            let row = SettingsHubCatalog.item(id)
            // On the glasses path every recovery row is in Basic and not under Advanced; on the Mac-only path every one but the
            // glasses-path rows is.
            check(row?.mount == .group && !SettingsHubCatalog.placedAdvanced(id, glassesPath: true) && SettingsHubCatalog.drawn(id, view: .basic, glassesPath: true),
                  "recovery row \(name) (\(id)) is in Basic, not Advanced, on the glasses path")
            if !SettingsHubCatalog.glassesPathBasic.contains(id) {
                check(SettingsHubCatalog.isBasic(id) && row?.advanced == false, "recovery row \(name) (\(id)) is in Basic on every path")
            }
            check(ids(name).contains(id), "search for \(name) finds \(id)")
        }
        // Sign out every browser (Miles 2026-11-09): under Open COS on your phone, Basic and All, never Advanced.
        let revoke = SettingsHubCatalog.item("WB-01")
        check(revoke?.label == "Sign out every browser" && revoke?.group == "glasses.phone" && revoke?.advanced == false && revoke?.mount == .group
              && SettingsHubCatalog.isBasic("WB-01"), "Sign out every browser is a Phone and web row, in Basic, not Advanced")
        for query in ["sign out", "browser", "revoke", "sign out every browser"] {
            check(ids(query).contains("WB-01"), "search finds Sign out every browser by \(query)")
        }
        check(SettingsHubWebRevoke.shown(phoneSignInTooOld: false) && !SettingsHubWebRevoke.shown(phoneSignInTooOld: true),
              "Sign out every browser shows where the phone sign-in does, and hides on a server without it")
        // Q1 review M3: a timeout cannot know whether the server acted, so it never says nothing changed.
        let timedOut = SettingsHubWebRevoke.result(transport: "unavailable", httpStatus: nil).line
        check(!timedOut.contains("Nothing") && timedOut.contains("could not confirm"), "a timeout says COS could not confirm, never that nothing was signed out")
        let done = SettingsHubWebRevoke.result(transport: "answered", httpStatus: 200)
        check(done.ok && done.line.hasPrefix("Done."), "the server's yes says Done")
        for (transport, status) in [("unsupported", 404), ("not_ready", nil), ("unavailable", nil), ("no_token", nil), ("failed", 500), (nil, nil)] as [(String?, Int?)] {
            let r = SettingsHubWebRevoke.result(transport: transport, httpStatus: status)
            check(!r.ok && !r.line.contains("Done") && !r.line.isEmpty, "\(transport ?? "nil") is an honest failure line, never Done")
        }
        check(SettingsHubWebRevoke.result(transport: "unsupported", httpStatus: 404).line.contains("Update the server")
              && SettingsHubWebRevoke.result(transport: "failed", httpStatus: 500).line.contains("(500)"), "too old says update; a refusal names its status")
        for line in [SettingsHubWebRevoke.button, SettingsHubWebRevoke.confirmLine, SettingsHubWebRevoke.confirmButton, done.line] {
            check(!line.contains("—") && !line.contains("→"), "\(line) is plain")
        }
        check(SettingsHubCatalog.isBasic("UT-29") && SettingsHubCatalog.isBasic("PK-01") && SettingsHubCatalog.hasBasicRows("glasses.phone"),
              "Open COS on your phone and Phone approvals are in Basic, so the Phone and web card draws there")
        // drawn: every row in All, the basic ones in Basic, and a line the catalog does not know never hidden.
        check(SettingsHubCatalog.drawn("UT-25", view: .all) && !SettingsHubCatalog.drawn("UT-25", view: .basic) && SettingsHubCatalog.drawn("G-01", view: .basic)
              && SettingsHubCatalog.drawn("", view: .basic) && SettingsHubCatalog.drawn("not-a-row", view: .basic), "Basic hides only catalog rows outside the basic set")
        check(SettingsHubCatalog.rowID(anchor: "item.REACH-12.when") == "REACH-12" && SettingsHubCatalog.rowID(anchor: "item.G-01") == "G-01"
              && SettingsHubCatalog.rowID(anchor: "hub.general.app") == nil && SettingsHubCatalog.rowID(anchor: nil) == nil && SettingsHubCatalog.rowID(anchor: "item.") == nil,
              "a row anchor names its row, and only a row anchor does")
        // COS reaching out: Pings and Quiet hours on the card, the other 15 in place behind Advanced.
        let reach = SettingsHubCatalog.items(inGroup: "work.reach")
        check(reach.count == 17 && reach.filter(\.advanced).count == 15 && reach.filter { SettingsHubCatalog.isBasic($0.id) }.map(\.id).sorted() == ["REACH-01", "REACH-05"],
              "COS reaching out: 2 basic, 15 Advanced")
        check(SettingsHubCatalog.inlineShown("REACH-02", open: false) == false && SettingsHubCatalog.inlineShown("REACH-02", open: true)
              && SettingsHubCatalog.inlineShown("REACH-01", open: false) && SettingsHubCatalog.inlineShown("REACH-02", open: nil)
              && SettingsHubCatalog.inlineShown("not-a-row", open: false), "an inline Advanced row draws only while that Advanced is open")
        // Behind Advanced now: the Jev and SubQ keys, the cue limits, the model pickers, server internals, Use classic Settings.
        for id in ["JV-08", "JV-09", "JV-10", "JV-11", "JV-12", "MA-08", "MA-09", "MA-10", "MA-11", "TR-02", "TR-03", "TR-04", "TR-06", "ST-02", "ST-03", "HUB-CL"] {
            check(SettingsHubCatalog.item(id)?.advanced == true, "\(id) is Advanced")
        }
        check(SettingsHubRoute.destination("decision-models")?.opensAdvanced == true, "the anchor that asks for a Jev or SubQ key opens Decision models' Advanced")
        // 0.5.388 final review E7: Open Transcription settings lands on the model pickers, under Models' Advanced.
        check(SettingsHubRoute.destination("transcription")?.opensAdvanced == true, "the Transcription anchor opens Models' Advanced, where the pickers are")
        check(SettingsHubRoute.destination("setup-guide")?.opensAdvanced == false && SettingsHubRoute.destination("key-lanes")?.opensAdvanced == false,
              "the other panel anchors open no Advanced")
        // The two Quiet hours: the one the person sets hours for keeps the name; Today's fixed fold says what it does.
        check(SettingsHubCatalog.item("REACH-05")?.label == "Quiet hours" && SettingsHubCatalog.item("WK-07")?.label == "Fold evenings and weekends",
              "one Quiet hours")
        check(SettingsHubCatalog.all.filter { $0.mount != .outside }.filter { $0.label == "Quiet hours" }.count == 1, "no two drawn rows share the Quiet hours name")
        check(ids("quiet hours").contains("WK-07") && SettingsHubSearch.results("quiet hours").first(where: { $0.category == .work })?.items.first?.id == "REACH-05",
              "search still finds both, and Quiet hours by its name first in Work")
        // E4: the catalog says what the page draws.
        check(SettingsHubCatalog.item("JV-01")?.label == "Provider in use" && SettingsHubCatalog.item("PM-01")?.label == "Permission status"
              && SettingsHubCatalog.item("C-01")?.label == "Restart and update" && SettingsHubCatalog.item("C-06")?.label == "Older server",
              "the four rows search shows by the label the page draws")
        check(ids("decision models").contains("JV-01") && ids("adopt safely").contains("C-06"), "and by their old names")
        // The Dictation menu: the hub's Dictation page, or the classic route.
        check(SettingsHub.dictationMenuTarget(classic: false) == "hub.dictation.dictation" && SettingsHub.dictationMenuTarget(classic: true) == nil,
              "the Dictation menu lands on the hub's Dictation page unless classic Settings is on")
        check(SettingsHubRoute.destination(SettingsHub.dictationMenuAnchor)?.category == .dictation, "that anchor routes to Dictation")
        for line in [SettingsHubView.switchLabel, SettingsHubView.basicLine, SettingsHubView.allLine, SettingsHubView.hiddenByBasic] {
            check(!line.contains("—") && !line.contains("→"), "\(line) is plain")
        }
    }

    // 0.5.387 (audit F1, F2): search never says a row is missing when it is only hidden, and the page says why.
    static func honestSearch() {
        let states: [SettingsHubConditions] = [true, false].flatMap { server in [true, false].flatMap { drop in [true, false].map { today in
            SettingsHubConditions(serverRunning: server, dropItOn: drop, todayHome: today)
        } } }
        for item in SettingsHubCatalog.searchable {
            // Found by its own label, whatever the page draws.
            check(SettingsHubSearch.results(item.label).flatMap(\.items).contains { $0.id == item.id }, "\(item.id) is a result for \(item.label)")
            for c in states {
                for view in SettingsHubView.allCases {
                    // Its group hidden: a reason, never nothing.
                    let groupNote = SettingsHubSearch.note(item, groupShown: false, rowShown: true, conditions: c, gateLine: nil, view: view)
                    check(groupNote?.isEmpty == false, "\(item.id) with its group hidden says why")
                    let rowNote = SettingsHubSearch.note(item, groupShown: true, rowShown: false, conditions: c, gateLine: nil, view: view)
                    check(rowNote?.isEmpty == false, "\(item.id) hidden inside a drawn group says why")
                    let drawnNote = SettingsHubSearch.note(item, groupShown: true, rowShown: true, conditions: c, gateLine: nil, view: view)
                    check((drawnNote == nil) == SettingsHubCatalog.drawn(item.id, view: view), "\(item.id) drawn has no line; hidden by Basic says so")
                }
            }
        }
        let down = SettingsHubConditions(serverRunning: false)
        check(SettingsHubSearch.hiddenLine(group: "work.brief", down) == "Shows when the server is running.", "server down: the server line")
        check(SettingsHubSearch.hiddenLine(group: "work.brief", SettingsHubConditions()) == "Needs a newer COS server.", "server up, feature missing: a newer server")
        check(SettingsHubSearch.hiddenLine(group: "dictation.shortcuts", SettingsHubConditions()) == "Shows when dictation is on.", "dictation off")
        check(SettingsHubSearch.hiddenLine(group: "work.reach", SettingsHubConditions(dropItOn: false)) == "Shows when Drop it is on.", "Drop it off")
        check(SettingsHubSearch.hiddenLine(group: "work.reach", down) == "Shows when the server is running.", "Drop it with the server down")
        check(SettingsHubSearch.hiddenRowLine("JV-13", SettingsHubConditions(todayHome: false)) == "Shows with Today home on.", "meaning search needs Today home")
        if let push = SettingsHubCatalog.item("DI-05"), let wait = SettingsHubCatalog.item("DI-25"), let format = SettingsHubCatalog.item("UT-25") {
            check(SettingsHubSearch.note(push, groupShown: false, rowShown: true, conditions: SettingsHubConditions(), gateLine: nil, view: .all) == "Shows when dictation is on.",
                  "push to talk with dictation off says to turn dictation on")
            check(SettingsHubSearch.note(wait, groupShown: true, rowShown: true, conditions: SettingsHubConditions(), gateLine: "Turn on Paste then polish to change this.", view: .basic)
                  == "Turn on Paste then polish to change this.", "a switch above it comes before Basic")
            check(SettingsHubSearch.note(format, groupShown: true, rowShown: true, conditions: SettingsHubConditions(), gateLine: nil, view: .basic) == "In All settings",
                  "a row Basic leaves out is in All settings")
        } else { check(false, "DI-05, DI-25 and UT-25 are in the catalog") }
        check(SettingsHubSearch.conditionLanding(group: "dictation.polish") == "DI-01" && SettingsHubSearch.conditionLanding(group: "pet.characters") == "PT-01"
              && SettingsHubSearch.conditionLanding(group: "work.reach") == "DROP-01" && SettingsHubSearch.conditionLanding(group: "work.brief") == nil,
              "a result in a hidden group opens the switch that shows it, or the page top")
        // The server notice: only once checked and not answering, and the action that brings it back.
        check(SettingsHubServerNotice.line(checked: false, running: false, needsFirstRun: false) == nil
              && SettingsHubServerNotice.line(checked: true, running: true, needsFirstRun: false) == nil
              && SettingsHubServerNotice.line(checked: true, running: false, needsFirstRun: false) == SettingsHubServerNotice.notAnsweringLine,
              "the notice shows only while a checked server is not answering")
        check(SettingsHubServerNotice.action(runtimeState: "notInstalled", installed: false, needsFirstRun: false) == .install
              && SettingsHubServerNotice.action(runtimeState: "stopped", installed: true, needsFirstRun: false) == .start
              && SettingsHubServerNotice.action(runtimeState: "managedDegraded", installed: true, needsFirstRun: false) == .repair, "install, start or repair")
        // 0.5.388 final review C2: a Mac never set up hears that COS is not set up, never "not answering", and gets no button.
        let firstRunLine = SettingsHubServerNotice.line(checked: true, running: false, needsFirstRun: true)
        check(firstRunLine == SettingsHubServerNotice.notSetUpLine && firstRunLine?.contains("not answering") == false,
              "before first run the notice says COS is not set up, not that the server is not answering")
        check(SettingsHubServerNotice.action(runtimeState: "notInstalled", installed: false, needsFirstRun: true) == .none
              && SettingsHubServerNotice.title(.none) == nil, "before first run the notice offers no Install server: Get started is the one way in")
        // E2: Repair only where the helper's repair works (a managed install); every other server goes to System and updates.
        for state in ["legacyStopped", "legacyService", "legacyForeground", "ownerConflict", "managedInPlace", "unknown"] {
            check(SettingsHubServerNotice.action(runtimeState: state, installed: true, needsFirstRun: false) == .openSystem,
                  "\(state) never offers Repair the helper refuses; it opens System and updates")
        }
        check(SettingsHubServerNotice.title(.openSystem) == "Open System and updates", "the button names where it goes")
        // Q1 02:40: a managed state with no manifest (installed false) is never offered Repair; the helper refuses it.
        check(SettingsHubServerNotice.action(runtimeState: "managedDegraded", installed: false, needsFirstRun: false) == .openSystem
              && SettingsHubServerNotice.action(runtimeState: "managedHealthy", installed: false, needsFirstRun: false) == .openSystem,
              "a managed state with no manifest never offers Repair")
        let lines = [SettingsHubServerNotice.notAnsweringLine, SettingsHubServerNotice.notSetUpLine, SettingsHubSearch.serverLine, SettingsHubSearch.newerServerLine]
            + [SettingsHubServerNotice.Action.start, .install, .repair, .openSystem].compactMap(SettingsHubServerNotice.title)
        for line in lines { check(!line.contains("—") && !line.contains("→") && !line.isEmpty, "\(line) is plain") }
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
