#!/usr/bin/env python3
"""Settings hub (Miles, 2026-10-27, design/settings-hub): the wiring pins its compiled checks cannot see.

    python3 Tests/settings-hub-pins.py <root>

  - Parity: the catalog holds every row of docs/settings-hub/SETTINGS_INVENTORY.md section 1 once, in the category
    section 3 gives it (the few rows that render elsewhere are named below with the reason).
  - Each ControlPanel piece mounts exactly once in the hub's composition, and the one-page panel still mounts it too.
  - The loaders mainPanel's always-drawn views ran sit at the hub's root, and the classic views keep their own.
  - Only Activity's Settings route passes a hub host: the menu-bar panel and the standalone window keep mainPanel.
  - The classic switch: one key, read by ControlPanel and by Activity, drawing mainPanel and the Today rail again.
  - Deep links: every opener's anchor is routed, and the hub follows model.panelScrollTarget.
  - The hub files are in every explicit full-app compile list, the release build once, and the suite runs both lanes.
  - The hub's own words carry no em dash or arrow.
Prints "settings hub pins: N passed". Exits 1 on the first failure, naming it.
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
passed = 0


def pin(ok, what):
    global passed
    if not ok:
        print(f"settings hub pin FAILED: {what}")
        sys.exit(1)
    passed += 1


def read(rel):
    return (root / rel).read_text(encoding="utf-8")


def code(text):
    """The text without // comments: a comment may name a piece, code must mount it."""
    return "\n".join(re.sub(r"(^|\s)//.*$", r"\1", line) for line in text.split("\n"))


def body(src, start, end):
    i = src.index(start)
    return src[i:src.index(end, i + len(start))]


views_raw = read("Sources/Views.swift")
views = code(views_raw)
activity = code(read("Sources/ActivityWindow.swift"))
catalog = read("Sources/SettingsHubCatalog.swift")
shell = code(read("Sources/SettingsHubViews.swift"))
inventory = read("docs/settings-hub/SETTINGS_INVENTORY.md")
ask = code(read("Sources/MeetingAsk.swift"))
sources = {p.name: code(p.read_text(encoding="utf-8")) for p in (root / "Sources").glob("*.swift")}

# 1. Parity with the inventory: every row once, in its category.
section1 = inventory[:inventory.index("## 2.")]
inv_ids = re.findall(r"^\| ([A-Z]{1,3}-\d\d) \|", section1, re.M)
pin(len(inv_ids) == 253 and len(set(inv_ids)) == 253, f"the inventory lists 253 rows ({len(inv_ids)})")
items = re.findall(r'^\s*\.init\("([A-Z]{1,3}-\d\d)", "[^"]*", "[^"]*", old: "(?:[^"\\]|\\.)*", group: (nil|"[a-z.]+"), advanced: (true|false), mount: \.(\w+)',
                   body(catalog, "static let items: [SettingsHubItem] = [", "\n    ]\n"), re.M)
cat_ids = [i[0] for i in items]
pin(sorted(cat_ids) == sorted(inv_ids), f"the catalog holds every inventory row once (missing {sorted(set(inv_ids) - set(cat_ids))}, extra {sorted(set(cat_ids) - set(inv_ids))})")
section3 = inventory[inventory.index("## 3. Proposed layout"):inventory.index("## 4. Parity checklist")]
names = {"General": "general", "AI and accounts": "ai", "Glasses and iPhone": "glasses", "Meetings": "meetings", "Dictation": "dictation",
         "Transcription and voice": "voice", "Work and agents": "work", "Privacy and permissions": "privacy", "Pet and appearance": "pet",
         "System and updates": "system", "Stays outside Settings": None}
want, current = {}, None
for line in section3.split("\n"):
    m = re.match(r"### 3\.\d+ (.*)", line)
    if m:
        current = names[m.group(1)]
        continue
    m = re.match(r"\| ([A-Z]{1,3}-\d\d) \|", line)
    if m:
        want[m.group(1)] = current
# Rows that render in another category than section 3 proposes, each for a reason.
moved = {
    "H-10": "meetings",  # the recording card renders in the top strip; search lists it under Meetings, Recording
}
for item_id, group, _advanced, mount in items:
    cat = None if group == "nil" else group.strip('"').split(".")[0]
    expected = moved.get(item_id, want[item_id])
    if mount == "outside":
        pin(want[item_id] is None and group == "nil", f"{item_id} stays outside Settings, as section 3.11 says")
    else:
        pin(cat == expected, f"{item_id} sits in {expected} (section 3), not {cat}")

# 2. Each piece mounts exactly once in the hub, and the panel keeps it.
hub = code(body(views_raw, "private extension ControlPanel {", "\n// MARK: - Speaker review sheet"))
status_card = body(views, "    private var statusCard: some View {", "\n    }\n")
pieces_status = ["statusServerRows", "statusVoiceRows", "statusContextRows", "statusBackgroundRow", "statusMeetingPreviewRow",
                 "statusContinueRow", "statusIdleMetalRow", "statusAudioCleanupRow", "statusWhisperErrorLine",
                 "statusTranscriptionModelRows", "statusMeetingAudioRows", "statusMeetingAlertsRow", "statusMeetingSyncRows",
                 "statusEarlySyncRows", "statusHqPrefillRows", "statusFinalizationRows", "statusRetainedCaptureRows", "statusAgentRows",
                 "statusCursorRow", "statusOllamaRow", "statusVersionRow", "statusWorkFolderRows", "statusLibraryRows",
                 "statusActiveWorkLine", "statusTransactionLine"]
for name in pieces_status:
    pin(len(re.findall(rf"\b{name}\b", hub)) == 1, f"{name} mounts once in the hub")
    pin(len(re.findall(rf"\b{name}\b", status_card)) == 1, f"{name} is still in the panel's status card")
pin(hub.count("statusVideoRows(clearButton: false)") == 1 and status_card.count("statusVideoRows(clearButton: true)") == 1,
    "video uploads' status: once in each, Clear stranded drawn once in the hub (on Reliable video uploads)")
controls = body(views, "    private var controls: some View {", "\n    }\n")
for name in ["serverControlButtons", "serverForegroundWarning", "serverLegacyControls"]:
    pin(len(re.findall(rf"\b{name}\b", hub)) == 1 and len(re.findall(rf"\b{name}\b", controls)) == 1, f"{name} mounts once in the hub and once in the panel")
# The hub mounts serverMessages' two halves apart (progress in the top strip, the notice on System); the panel keeps both.
pin(len(re.findall(r"\bserverMessages\b", controls)) == 1 and not re.search(r"\bserverMessages\b", hub),
    "serverMessages mounts once in the panel; the hub mounts its two halves")
utilities = body(views, "    private var utilities: some View {", "\n    }\n")
for name in ["toolTranscriptionTier", "toolBackgroundJobs", "toolMeetingPreview", "toolClaudeSessions", "toolThreadAttach",
             "toolOllamaModel", "toolVideoUploads", "toolIdleMetal", "toolAudioCleanup"]:
    pin(hub.count(f"{name}(hub: true)") == 1 and utilities.count(f"{name}(hub: false)") == 1, f"{name} draws once in each layout")
for name in ["decisionDefaultControls", "decisionWorkflowControls", "decisionMessageLine", "decisionRefreshButton", "subQRetentionNote",
             "subQKeyControls", "jevKeyControls", "petJumpWarning", "petCloudPuffButton", "petSpriteButtons", "petGalleryCard",
             "morningBriefContent", "domainsContent", "fencesContent", "doctorResults", "speakerModelWarning", "notesSourceLine",
             "recordingCard", "updateBanner", "noticeBanner"]:
    pin(len(re.findall(rf"\b{name}\b", hub)) == 1, f"{name} mounts once in the hub")
for view in ["DockNoticeLine(", "FinishSetupCard(", "PanelConnectAIRow(", "TranscriptionSettingsCard(", "MacDictationSettings(",
             "MeetingSuggestSettings(", "HotKeyRecorderRow(", "PetSizeControls(", "PetSpriteStateControls(", "PetIntroLine(",
             "PermissionGuideList(", "StaleBuildsSection(", "ProviderConnectList(", "SetupDeviceChoice(", "GlassesSetupRows(",
             "DictationEngineControls(", "SettingsHubOwnKeyCard(", "SettingsHubSemanticSearchRow("]:
    pin(hub.count(view) == 1, f"{view[:-1]} mounts once in the hub")
pin(hub.count("MeetingAskSettings(store: model.meetingAsk, model: model, part: .assistant)") == 1
    and hub.count("MeetingAskSettings(store: model.meetingAsk, model: model, part: .liveCues)") == 1 and hub.count("MeetingAskSettings(") == 2,
    "Meeting assistant and Live cues: one part each")
pin(hub.count("SettingsHubSetupRow(") == 2 and "id: .ollama)" in hub and "id: .voice)" in hub, "the guide's Ollama and Voice rows, once each")
card = body(ask, "struct MeetingAskSettings: View {", "struct HomeCitySettings: View {")
pin("var part: MeetingAskSettingsPart = .all" in card and "if part != .liveCues {" in card and "if part != .assistant { LiveCuesSettingsRow(" in card,
    "MeetingAskSettings draws both parts unless the hub asks for one")
panel = body(views, "    private var mainPanel: some View {", "\n    }\n\n")
pin("MeetingAskSettings(store: model.meetingAsk, model: model)\n" in panel, "the panel draws the whole Meeting assistant card")

# 3. Loaders at the hub root; the classic views keep theirs.
loaders = body(views, "    func hubLoaders<Content: View>(_ content: Content) -> some View {", "\n    }\n")
for needle in ["model.loadWorkExpiry()", "model.loadOpenPetsCatalog()", "model.meetingAsk.refreshConfig(model: model)",
               "model.meetingAsk.homeArea.load(HomeCitySettings.run(model))", "model.transcriptionSettings.load(TranscriptionSettingsCard.run(model))",
               "model.meetingAsk.liveCues.load(LiveCuesSettingsRow.run(model))", "model.loadMorningBrief(quiet: true)",
               "syncMorningBriefDraft(force: stamp != briefDraftStamp)", "syncMorningBriefDraft(force: briefDraft == nil)",
               "model.loadDomains()", "syncDomainsDraft(force: false)", "model.providerGuide.refresh()", "model.permissionGuide.refresh()",
               "NSApplication.didBecomeActiveNotification", "model.liveTranscriptSettingChanged()",
               "voiceGuide.adoptServerTier(", "hubCategoryOpened(hubCategory)"]:
    pin(needle in loaders, f"the hub's root runs {needle}")
pin("hubLoaders(" in body(views, "    func settingsHub(_ host: SettingsHubHost) -> some View {", "\n    }\n"), "the hub's root view is wrapped in its loaders")
opened = body(views, "    func hubCategoryOpened(_ category: SettingsHubCategory) async {", "\n    }\n")
pin("model.loadDecisionSettings()" in opened and "model.loadJevStatus()" in opened and "model.loadSubQKeyStatus()" in opened,
    "opening AI and accounts loads what opening Decision models loads")
# Before the switch and for every page but AI, so no case can skip it (QA N2: Meetings kept the key).
pin('if category != .ai { subQKeyDraft = ""; jevKeyDraft = "" }\n        switch category {' in opened
    and opened.count('jevKeyDraft = ""') == 1, "leaving AI and accounts for any page drops a typed key, as closing Decision models does")
pin(not re.search(r'hubCard\("[a-z.]+", advanced: [0-9]', views) and views.count("advanced: hubAdvancedCount(") == 12,
    "every Advanced count is the catalog's rows the page draws, never a typed number")
shown_adv = body(views, "    func hubAdvancedShown(_ id: String) -> Bool {", "\n    }\n")
for rid in ("JV-03", "JV-04", "JV-05", "UT-05", "ST-08", "ST-13", "ST-19", "PT-08", "PT-11", "PT-12", "PT-13", "C-06", "C-07", "C-08"):
    pin(f'"{rid}"' in shown_adv, f"Advanced counts: {rid}, drawn only sometimes, is counted only when drawn")
pin(".task { await model.loadMorningBrief(quiet: true) }" in body(views, "    private var morningBriefCard: some View {", "\n    }\n"),
    "the panel's morning brief card still loads itself")
pin("await model.loadDomains()" in body(views, "    private var domainsCard: some View {", "\n    }\n"), "the panel's domains card still loads itself")
pin(".task { await model.transcriptionSettings.load(TranscriptionSettingsCard.run(model)) }" in panel, "the panel still loads Transcription from an always-drawn view")
pin(".onChange(of: showLiveTranscript) { _, _ in model.liveTranscriptSettingChanged() }" in utilities, "the panel's live transcript switch keeps its observation")

# 3b. Hosted sub-views (the hub presentation mode): one environment value, set by the hub's page, read by each hosted
# view; and every loader those views run happens once on its page (two MeetingAskSettings parts, seven dictation groups).
shell_raw = read("Sources/SettingsHubViews.swift")
pin("var settingsHubHosted: Bool" in shell_raw and "static let defaultValue = false" in shell_raw, "hosted mode is off unless the hub sets it")
pin(hub.count(".environment(\\.settingsHubHosted, true)") == 1, "the hub's page sets hosted mode once")
dictation = code(read("Sources/MacDictation.swift"))
settings_view = body(dictation, "struct MacDictationSettings: View {", "private struct DictationQuietSettings")
for section in ("dictation", "microphone", "shortcuts", "sounds", "text", "polish", "history"):
    pin(f"if shows(.{section}) {{" in settings_view, f"MacDictationSettings draws its {section} group on its own")
    pin(f'"dictation.{section}"' in catalog, f"the catalog has the dictation.{section} group")
pin('.onAppear { if shows(.microphone) { store.refreshMicrophones() } }' in settings_view, "microphones are read once per page: by the Microphone group")
pin("refreshMicrophones" not in loaders, "the hub's root does not read microphones a second time")
pin(hub.count("MacDictationSettings(store: model.dictation, activityShortcut: model.activityHotKey, section: section)") == 1, "the hub draws each group as a section")
ask_card = body(ask, "struct MeetingAskSettings: View {", "struct HomeCitySettings: View {")
ask_hub = body(ask_card, "@ViewBuilder private var hubBody: some View {", "\n    }\n")
pin(ask_card.count(".task {") == 1 and ".task" not in ask_hub, "MeetingAskSettings loads only in the panel; in the hub its two parts load nothing")
cues = body(ask, "struct LiveCuesSettingsRow: View {", "struct LiveCuesLimitsRows: View {")
pin(cues.count(".task(id:") == 1 and "{ if !hosted { await store.load(Self.run(model)) } }" in cues,
    "Live cues loads only in the panel; the hub's root reads it once")
pin("model.meetingAsk.refreshConfig(model: model)" in loaders and "model.meetingAsk.liveCues.load(LiveCuesSettingsRow.run(model))" in loaders,
    "the hub's root loads the assistant's models and the cue state, once")
engine = body(code(read("Sources/ProviderConnectViews.swift")), "struct DictationEngineControls: View {", "struct EngineCellsLayout")
pin(".task { if !hosted { await store.load(TranscriptionSettingsCard.run(model)) } }" in engine, "the engine step does not load Transcription again in the hub")
lanes = code(read("Sources/KeyLanesViews.swift"))
pin("guard !hosted, part != .advanced else { return }" in lanes and lanes.count("await Self.load(model, store: store)") == 1,
    "Your own key's Advanced part reads nothing, and in the hub neither part does")
pin(".settingsHubOwnKeyReader(model)" in loaders and views.count("settingsHubOwnKeyReader(") == 1
    and shell_raw.count("await KeyLanesSettingsRow.load(model)") == 1,
    "the hub's root reads Your own key once for every page")
pin("KeyLanesSettingsRow(model: model, part: .main)" in shell_raw and "KeyLanesSettingsRow(model: model, part: .advanced)" in shell_raw,
    "Your own key: the card's rows and its Advanced rows")
for item_id in ("KL-02", "KL-03", "KL-14", "KL-15"):
    pin(re.search(r'\.init\("' + item_id + r'", .*?advanced: true', catalog) is not None, f"{item_id} sits under Your own key's Advanced")

# 4. Only Activity's Settings route passes a host; everything else draws mainPanel.
pin("if let hub, !useClassicSettings { settingsHub(hub) } else { mainPanel }" in views, "ControlPanel draws the hub only with a host and the classic switch off")
hosts = sum(len(re.findall(r"\bhub: (?!SettingsHubHost\?)", src)) for name, src in sources.items() if name != "Views.swift")
pin(hosts == 1 and "hub: settingsHubHost)" in activity, f"Activity's Settings route is the only host outside the fixture ({hosts})")
pin(views.count("hub: SettingsHubHost(") == 1 and "static func hubFixture(" in views, "Views.swift passes a host only in its offscreen fixture")
connect = code(read("Sources/ProviderConnectViews.swift"))
pin("ControlPanel(model: model, openActivity: openActivity, hostedInWindow: true))" in connect, "the standalone Settings window keeps the one-page panel")
app = code(read("Sources/COSControlApp.swift"))
pin(all("hub:" not in line for line in app.split("\n") if "ControlPanel(" in line) and "ControlPanel(" in app, "the menu-bar panel keeps the one-page panel")

# 5. The classic switch.
pin('static let classicKey = "cos.settings.classic"' in catalog, "one key")
pin("@AppStorage(SettingsHub.classicKey) private var useClassicSettings = false" in views, "ControlPanel reads it, off by default")
pin("@AppStorage(SettingsHub.classicKey) private var classicSettings = false" in activity, "Activity reads it, off by default")
pin('hubSwitch("HUB-CL", isOn: $useClassicSettings)' in hub, "General, Advanced: Use classic Settings is the switch")
pin("private var settingsHubShowing: Bool { showingSettings && !classicSettings }" in activity, "the hub shows only with the switch off")
frame = body(activity, "    var todayFrameView: some View {", "\n    func todayResetExpansions()")
pin("if !settingsHubShowing { todayRail(mode: mode, frame: frame, now: timeline.date) }" in frame, "the hub's sidebar takes the Today rail's place")
pin("if (canGoBack || connectedWorkTest) && !settingsHubShowing { navigationBar; Divider() }" in frame, "the hub's back control replaces the toolbar in Today")
pin(".frame(maxWidth: classicSettings ? 780 : .infinity, maxHeight: .infinity)" in activity, "the classic panel keeps its 780 pt column")

# 6. Deep links.
anchors = set(re.findall(r'\.id\("([a-z-]+)"\)', panel)) | set(re.findall(r'\.id\("([a-z-]+)"\)', code(read("Sources/KeyLanesViews.swift"))))
anchors.add(re.search(r'static let decisionKeysAnchor = "([a-z-]+)"', read("Sources/MeetingAskCore.swift")).group(1))
routed = set(re.findall(r'^\s+"([a-z-]+)": "[a-z.]+",$', body(catalog, "static let panelAnchors", "\n    ]"), re.M))
pin(anchors - {"settings"} == routed, f"every opener anchor but the plain one is routed (anchors {sorted(anchors)}, routed {sorted(routed)})")
pin('"settings"' not in body(catalog, "static let panelAnchors", "\n    ]"), "the plain Settings anchor has no route: the hub stays on the category it opens on")

# 6b. Every Settings opener lands in the hub while the classic switch is off (2026-10-28); with it on, the old route runs.
connect_views = code(read("Sources/ProviderConnectViews.swift"))
opener = body(connect_views, "    static func open(model: ControllerModel, window: SettingsWindowPresenter,", "\n    }\n}")
hub_branch = opener.split("let target = SettingsRoute.decide(")[0]
pin("if SettingsHub.opensHub(classic: UserDefaults.standard.bool(forKey: SettingsHub.classicKey)) {" in hub_branch
    and "model.settingsHubTarget = scroll" in hub_branch and "model.activityOpenSettings = true" in hub_branch
    and "openActivity(nil)" in hub_branch and "return" in hub_branch,
    "SettingsOpener: the hub first (target, Activity on Settings), before the panel-or-window route")
pin("static func opensHub(classic: Bool) -> Bool { !classic }" in catalog, "the classic switch is the routing rollback too")
app_src = code(read("Sources/COSControlApp.swift"))
pin("model.showSettings = {\n            SettingsOpener.open(model: model, window: settingsWindow) {" in app_src
    and "SettingsOpener.open(model: model, window: settingsWindow, scroll: LiveCues.decisionKeysAnchor)" in app_src
    and 'SettingsOpener.open(model: model, window: settingsWindow, scroll: "transcription")' in app_src
    and 'Button("Settings…") { model.showSettings?() }.keyboardShortcut(",")' in app_src
    and "COSAppDelegate.onSettings = { model.showSettings?() }" in app_src
    and "model.dictation.openTranscriptionSettings = { [weak model] in model?.showTranscriptionSettings?() }" in app_src,
    "⌘,, the Dock, the decision-key and transcription openers all go through SettingsOpener")
pin('Button("Settings…") { model.showSettings?() }' in code(read("Sources/SessionPet.swift"))
    and 'Button("Open settings") { model.showSettings?() }' in code(read("Sources/ControlSetup.swift")),
    "the pet's and Welcome's Settings go through SettingsOpener")
launch = body(activity, "    private func applyLaunchSection() {", "\n        if isolatedWorkPreview {")
pin("if model.activityOpenSettings {" in launch and "model.activityOpenSettings = false" in launch and "openActivitySettings()" in launch
    and ".onChange(of: model.activityOpenSettings) { _, _ in applyLaunchSection() }" in activity,
    "Activity opens Settings for an opener, once")
follow = body(hub, "    func hubFollowTarget(_ reader: ScrollViewProxy) {", "\n    }\n")
pin("guard let target = model.settingsHubTarget ?? model.panelScrollTarget else { return }" in follow
    and "if fromOpener { model.settingsHubTarget = nil } else { model.panelScrollTarget = nil }" in follow
    and ".onChange(of: model.settingsHubTarget) { _, _ in hubFollowTarget(reader) }" in hub,
    "the hub lands on an opener's target and consumes it")
pin("@State private var hubCategory: SettingsHubCategory = SettingsHub.lastCategory()" in views
    and "UserDefaults.standard.set(category.rawValue, forKey: SettingsHub.lastCategoryKey)" in hub,
    "a plain Settings opens on the last category")
page = body(views, "    func hubPage(mode: SettingsHubLayout.Mode) -> some View {", "\n    func hubScroll(")
pin(".onChange(of: model.panelScrollTarget) { _, _ in hubFollowTarget(reader) }" in page and ".onAppear { hubFollowTarget(reader) }" in page,
    "the hub follows the panel's scroll target, also when it opens with one")
follow = body(views, "    func hubFollowTarget(_ reader: ScrollViewProxy) {", "\n    }\n")
pin("hubCategory = destination.category" in follow and "hubAdvanced.insert(destination.group)" in follow and "model.panelScrollTarget = nil" in follow,
    "a target opens its category, its Advanced when inside, and is consumed")

# 7. Compile lists and the suite.
lists = 0
for path in sorted(list(root.glob("scripts/*.sh")) + list(root.glob("Tests/*.sh"))):
    text = path.read_text(encoding="utf-8")
    lists += text.count('"$ROOT/Sources/SettingsHubCatalog.swift" "$ROOT/Sources/SettingsHubViews.swift" "$ROOT/Sources/SessionUsageView.swift"')
    pin('"$ROOT/Sources/SessionUsageView.swift" "$ROOT/Sources/SetupAssistant.swift"' not in text
        or '"$ROOT/Sources/SettingsHubViews.swift" "$ROOT/Sources/SessionUsageView.swift" "$ROOT/Sources/SetupAssistant.swift"' in text,
        f"{path.relative_to(root)}: a full-app compile list leaves out the hub")
pin(lists >= 10, f"the hub files are in the explicit full-app compile lists ({lists} found, 10 expected)")
release = read("scripts/build-release.sh")
pin(release.count('"$ROOT/Sources/SettingsHubCatalog.swift"') == 1 and release.count('"$ROOT/Sources/SettingsHubViews.swift"') == 1,
    "the release build compiles each hub file once")
suite = read("Tests/run.sh")
pin(suite.count('zsh "$ROOT/Tests/run-settings-hub.sh"') == 1 and suite.count('/usr/bin/python3 "$ROOT/Tests/settings-hub-pins.py" "$ROOT"') == 1,
    "the full suite runs the hub's checks and these pins once")
pin('"$ROOT/Sources/SettingsHubCatalog.swift" "$ROOT/Tests/SettingsHubChecks.swift"' in read("Tests/run-settings-hub.sh"),
    "the checks compile the catalog alone")

# 7b. QA fixes on b785daa (2026-10-28), each pinned where it lives.
pin('if hub != nil {' in panel and 'Button("Use new Settings") { useClassicSettings = false }' in panel,
    "classic Settings in Activity has its own way back to the hub")
page = body(views, "    func hubPage(mode: SettingsHubLayout.Mode) -> some View {", "\n    func hubScroll(")
pin(page.index("SettingsHubSearchField(query: $hubQuery, focused: $hubSearchFocused)") < page.index("ScrollView(.vertical)"),
    "the narrow search field sits outside the ScrollView whose identity changes, so it keeps focus")
pin("confirmHubRollback = false" in opened.split("switch category")[0], "a new page cancels an open inline confirm")
pin("SettingsHubSearch.results(hubQuery, shown: hubGroupShown)" in hub and "guard let group = item.group, shown(group) else { return nil }" in catalog,
    "search leaves out rows in groups the page does not draw")
pin('static let accessibilityRepairHint = "Already on? Use Reset and add again in Settings, Session pet."' in code(read("Sources/ControllerModel.swift"))
    and '.help("Turn the pet off. Turn it back on in Settings, Session pet.")' in connect_views,
    "the Accessibility repair hint names the Session pet card, right in both layouts")
pin(".keyboardShortcut(backShortcut ? KeyboardShortcut(.leftArrow, modifiers: .command) : nil)" in shell
    and "backShortcut: todayEnabled && !isolatedWorkPreview)" in activity, "⌘← is registered once: the hub's ‹ only where no toolbar Back has it")
pin("if settingsHubShowing { settingsHubTodayKeys }" in activity and 'keyboardShortcut(KeyEquivalent("h"), modifiers: [.command, .shift])' in body(activity, "    @ViewBuilder private var settingsHubTodayKeys: some View {", "\n    }\n")
    and "ActivitySection.allCases.prefix(9)" in activity, "the hub keeps the rail's ⌘0 to ⌘9 and ⌘⇧H in Today")
pin("@State private var hubInView" not in views, "no unused hub state")
pin('static let chooseRestarts = "Changing it restarts the server when no work is running."' in shell
    and "Saved. Restart the server when no work is running to use it." in views,
    "the folder copy says what the helper does: a drained restart, or a pending change on an older server")
# Parity (S3 to S9).
pin("case .addJevKey: model.showDecisionKeySettings?()" in connect_views
    and 'case .openPermissions: if hosted { model.settingsHubTarget = "hub.privacy.permissions" } else { model.permissionGuide.openInPanel() }' in connect_views
    and 'Button("Transcription settings") { model.showTranscriptionSettings?() }' in connect_views,
    "the guide's Add a key, Permissions and Transcription settings land inside the hub")
strip = body(hub, "    func hubTopStrip(_ reader: ScrollViewProxy) -> some View {", "\n    }\n")
pin("serverProgressMessages" in strip and "serverNoticeLine" not in strip and hub.count("serverProgressMessages") == 1
    and "SettingsHubBlock { serverForegroundWarning; serverNoticeLine }" in hub and hub.count("serverNoticeLine") == 1,
    "an Apply's progress shows on every page in the top strip; the green notice stays on System")
# QA delta 2026-10-28: the folder pickers restart through the drain lease, so they wait for running work like Apply.
pin("private var folderPickBlocked: Bool { serverNotInstalled || serverWorkActive }" in views
    and views.count(".disabled(folderPickBlocked)") == 6 and ".disabled(serverNotInstalled).help(workFolderHelp)" not in views,
    "folder pickers wait for running work: all six Choose buttons, hub and classic")
pin(all(f'hubRow("{rid}", detail: hubFolderDetail("{rid}"))' in hub for rid in ("UT-15", "UT-16", "UT-17"))
    and "(serverWorkActive ? \" \" + SettingsHubCopy.chooseWaitsForWork : \"\")" in hub,
    "folder pickers say why Choose is off while work runs")
open_settings = body(activity, "    private func openActivitySettings() {", "\n    }\n")
pin(open_settings.count("model.settingsHubTarget = nil") == 2 and open_settings.index("model.settingsHubTarget = nil; requestCloseTaskDetail()") >= 0,
    "an opener's target is dropped when Settings does not open")
video = body(hub, '            hubCard("glasses.video"', "        } advanced: {")
pin('hubRow("UT-10", detail: "A stopped upload can wait here for 4 hours and block Repair.")' in video,
    "a stuck upload's warning and Clear stay on the card, not under Advanced")
stt_hub = body(ask, "    @ViewBuilder private func hubCard(_ settings: SttSettings) -> some View {", "\n    }\n")
engine_body = body(connect_views, "struct DictationEngineControls: View {", "struct EngineCellsLayout")
pin('"Dictation engine"' not in stt_hub and "if !hosted, let state = store.rowState(" in engine_body and "!hosted, case .offer(" in engine_body,
    "the dictation engine has one home (Dictation) and the Parakeet install one (Transcription and voice)")
escape = body(activity, "    private func handleActivityEscape() -> Bool {", "\n    }\n")
hub_escape = body(hub, "    func hubEscape() -> Bool {", "\n    }\n")
pin("if model.settingsHubEscape?() == true { return true }" in escape and escape.index("settingsHubEscape") < escape.index("showingSettings = false")
    and hub_escape.index("hubQuery") < hub_escape.index("confirmHubRollback") and "if hubSearching {" in hub_escape
    and "model.settingsHubEscape = { hubEscape() }" in hub and "model.settingsHubEscape = nil" in hub,
    "Escape clears a search, then closes an inline confirm, and only then leaves Settings")
pin(views.count("if !hubOn { Task { await model.loadOpenPetsCatalog() } }") == 1, "the Characters card leaves the catalog read to the hub's root")

# 8. Words: no em dash or arrow in what the hub says.
strings = re.findall(r'"((?:[^"\\]|\\.)*)"', code(catalog) + "\n" + shell + "\n" + hub)
bad = [s for s in strings if "—" in s or "→" in s or "->" in s]
pin(not bad, f"no em dash or arrow in the hub's words: {bad[:3]}")

print(f"settings hub pins: {passed} passed")
