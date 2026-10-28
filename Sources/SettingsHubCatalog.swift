import CoreGraphics
import Foundation

// Settings hub (Miles, 2026-10-27 23:40: "I like the A treatment with B siderail. Can you please build a hybrid.").
// The catalog every part of the hub reads: ten categories, their groups, every row of
// docs/settings-hub/SETTINGS_INVENTORY.md with its new label, its old label and the group it renders in, the deep-link
// anchors, search, the breakpoints, the scroll-spy and the category status lines. Pure: no SwiftUI, no model, so
// Tests/SettingsHubChecks.swift runs it on its own (Tests/run-settings-hub.sh).

enum SettingsHub {
    /// General, Advanced: "Use classic Settings". On, Activity's Settings renders the old one-page panel again. The
    /// rollback path without a reinstall. Off by default.
    static let classicKey = "cos.settings.classic"
    /// Each scroll target the hub draws: "hub.<group id>".
    static func anchor(_ group: String) -> String { "hub." + group }
}

enum SettingsHubCategory: String, CaseIterable, Identifiable, Sendable {
    case general, ai, glasses, meetings, dictation, voice, work, privacy, pet, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .ai: "AI and accounts"
        case .glasses: "Glasses and iPhone"
        case .meetings: "Meetings"
        case .dictation: "Dictation"
        case .voice: "Transcription and voice"
        case .work: "Work and agents"
        case .privacy: "Privacy and permissions"
        case .pet: "Pet and appearance"
        case .system: "System and updates"
        }
    }
    /// SF Symbols, all in macOS 14.
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .ai: "sparkles"
        case .glasses: "eyeglasses"
        case .meetings: "calendar"
        case .dictation: "mic"
        case .voice: "waveform"
        case .work: "briefcase"
        case .privacy: "lock"
        case .pet: "face.smiling"
        case .system: "arrow.triangle.2.circlepath"
        }
    }
    /// The line under the category title.
    var blurb: String {
        switch self {
        case .general: "How COS Control opens, its shortcut and the setup guide."
        case .ai: "The AI apps COS works through, local models and your keys."
        case .glasses: "Pair your glasses and phone, and how videos reach this Mac."
        case .meetings: "Recording, the meeting assistant, live cues and your meeting library."
        case .dictation: "Type by voice into any app. The engine, microphone, shortcuts, sounds and polish."
        case .voice: "Transcription on this Mac. Voice setup, models and performance."
        case .work: "Sessions, Work chat, background jobs, folders, the morning brief and domains."
        case .privacy: "What COS can use on this Mac. COS works without any of them."
        case .pet: "The session pet. On or off, its size, motion and character."
        case .system: "The COS server on this Mac, app updates, and checks when something is off."
        }
    }
}

struct SettingsHubGroup: Identifiable, Equatable, Sendable {
    let id: String
    let category: SettingsHubCategory
    let title: String
    var anchor: String { SettingsHub.anchor(id) }
}

struct SettingsHubItem: Identifiable, Equatable, Sendable {
    /// Where a row renders. `group`: in its group's card. `topStrip`: above every category (the update banner, the
    /// recording card, notices, the Dock notice, Finish setup, Get started), listed under the group it belongs to.
    /// `outside`: a menu, the pet's menu or a live-work surface (inventory 3.11), never drawn in the hub.
    enum Mount: Sendable { case group, topStrip, outside }
    let id: String
    let label: String
    let detail: String
    /// The inventory's verbatim label, so a renamed setting is still found by its old name.
    let old: String
    let group: String?
    let advanced: Bool
    let mount: Mount
    let keywords: [String]
    init(_ id: String, _ label: String, _ detail: String, old: String, group: String?, advanced: Bool, mount: Mount, keywords: [String] = []) {
        self.id = id; self.label = label; self.detail = detail; self.old = old
        self.group = group; self.advanced = advanced; self.mount = mount; self.keywords = keywords
    }
}

enum SettingsHubCatalog {
    static let groups: [SettingsHubGroup] = [
        .init(id: "general.app", category: .general, title: "App"),
        .init(id: "general.home", category: .general, title: "Activity home"),
        .init(id: "general.guide", category: .general, title: "Setup guide"),
        .init(id: "ai.apps", category: .ai, title: "Your AI apps"),
        .init(id: "ai.local", category: .ai, title: "Local model"),
        .init(id: "ai.decision", category: .ai, title: "Decision models"),
        .init(id: "ai.keys", category: .ai, title: "Your own key"),
        .init(id: "ai.search", category: .ai, title: "Search"),
        .init(id: "glasses.devices", category: .glasses, title: "Devices"),
        .init(id: "glasses.video", category: .glasses, title: "Video uploads"),
        .init(id: "meetings.recording", category: .meetings, title: "Recording"),
        .init(id: "meetings.assistant", category: .meetings, title: "Meeting assistant"),
        .init(id: "meetings.cues", category: .meetings, title: "Live cues"),
        .init(id: "meetings.library", category: .meetings, title: "Library and sync"),
        .init(id: "meetings.fireflies", category: .meetings, title: "Fireflies import"),
        .init(id: "dictation.engine", category: .dictation, title: "Engine"),
        .init(id: "dictation.dictation", category: .dictation, title: "Dictation"),
        .init(id: "voice.setup", category: .voice, title: "Voice setup"),
        .init(id: "voice.models", category: .voice, title: "Models"),
        .init(id: "voice.performance", category: .voice, title: "Performance"),
        .init(id: "work.sessions", category: .work, title: "Sessions"),
        .init(id: "work.chat", category: .work, title: "Work chat"),
        .init(id: "work.background", category: .work, title: "Background"),
        .init(id: "work.folders", category: .work, title: "Folders and notes"),
        .init(id: "work.brief", category: .work, title: "Morning brief"),
        .init(id: "work.domains", category: .work, title: "Domains"),
        .init(id: "work.fences", category: .work, title: "Paused threads"),
        .init(id: "privacy.permissions", category: .privacy, title: "Permissions"),
        .init(id: "pet.pet", category: .pet, title: "Session pet"),
        .init(id: "pet.characters", category: .pet, title: "Characters"),
        .init(id: "system.server", category: .system, title: "Server"),
        .init(id: "system.updates", category: .system, title: "App updates"),
        .init(id: "system.troubleshooting", category: .system, title: "Troubleshooting"),
    ]

    /// Rows the hub adds that the inventory does not list (it is the hub's own rollback).
    static let extras: [SettingsHubItem] = [
        .init("HUB-01", "Use classic Settings", "Show the earlier one-page Settings in Activity.", old: "", group: "general.app", advanced: true, mount: .group,
              keywords: ["classic", "old settings", "rollback", "one page"]),
    ]

    /// Every inventory row, in the inventory's order (section 3). Labels and descriptions are the inventory's new copy.
    static let items: [SettingsHubItem] = [
        .init("G-01", "Open at login", "Start COS Control when you log in.", old: "Launch COS Control at login", group: "general.app", advanced: false, mount: .group, keywords: ["login", "startup", "launch"]),
        .init("G-02", "Menu bar only", "Hide COS Control from the Dock. The menu bar icon stays.", old: "Show in menu bar only", group: "general.app", advanced: false, mount: .group, keywords: ["dock", "menu bar", "hide"]),
        .init("H-08", "Dock notice", "One-time note after an upgrade: keep the Dock icon or go menu bar only.", old: "\"COS Control is in the Dock now.\" Menu bar only / Keep", group: "general.app", advanced: false, mount: .topStrip),
        .init("G-03", "Activity shortcut", "A key combination that opens Activity from any app.", old: "Open Activity with {chord} · Record / Cancel · Off", group: "general.app", advanced: false, mount: .group, keywords: ["hotkey", "keyboard shortcut", "chord"]),
        .init("UT-25", "Time format", "Show meeting times in 12-hour or 24-hour format.", old: "Advanced · Clock (12-hour / 24-hour)", group: "general.app", advanced: false, mount: .group, keywords: ["clock", "12-hour", "24-hour"]),
        .init("H-09", "Get started", "Opens first-time setup. Shows until COS is set up.", old: "Get started with COS", group: "general.app", advanced: false, mount: .topStrip),
        .init("WK-06", "Today home", "Activity opens on Today: what needs you, what is running, what is next.", old: "New Today home", group: "general.home", advanced: false, mount: .group, keywords: ["today home"]),
        .init("WK-07", "Quiet hours", "Evenings and weekends, Today folds items that can wait.", old: "Quiet hours on Today", group: "general.home", advanced: false, mount: .group),
        .init("WK-08", "Work runs from Today", "Prep me and the Ask box start Work runs, up to 20 a day.", old: "Start Work runs from Today", group: "general.home", advanced: false, mount: .group),
        .init("SG-01", "Setup guide", "Step-by-step setup for your AI, voice, glasses and permissions.", old: "Setup guide · {summary} row; card header \"Setup guide\" + Done", group: "general.guide", advanced: false, mount: .group, keywords: ["onboarding", "wizard", "welcome"]),
        .init("SG-15", "Finish setup card", "A progress card at the top until every step is done or skipped.", old: "Finish setup · N of M, progress bar, Next line, Continue setup, Hide", group: "general.guide", advanced: false, mount: .topStrip),
        .init("SG-14", "Show setup card", "Show or hide the Finish setup card.", old: "Hide setup guide / Show Finish setup at the top again", group: "general.guide", advanced: false, mount: .group),
        .init("SG-07", "Sessions step", "The guide step that turns on Show AI sessions.", old: "Show your AI sessions row (Turn on)", group: "general.guide", advanced: false, mount: .group),
        .init("SG-08", "Continue step", "The guide step that turns on Continue threads.", old: "Continue agent threads row (Turn on)", group: "general.guide", advanced: false, mount: .group),
        .init("SG-09", "Work suggestions step", "The guide step that checks your Jev or SubQ key.", old: "Work suggestions row (opens Decision models, Check)", group: "general.guide", advanced: false, mount: .group),
        .init("SG-10", "Permissions step", "The guide step that opens Permissions.", old: "Permissions row (opens Permissions)", group: "general.guide", advanced: false, mount: .group),
        .init("SG-03", "Claude, Codex, Cursor", "Install and sign in to the AI apps COS works through.", old: "Your AI rows (Claude Code, Codex, Cursor Agent): Get X, Copy, Sign in, Open Terminal again, Stop waiting, Check again, Skip for now / Set up now, Pass to X", group: "ai.apps", advanced: false, mount: .group, keywords: ["claude code", "codex", "cursor", "sign in"]),
        .init("ST-24", "AI app status", "Shows whether Claude, Codex and Cursor are ready.", old: "Agent CLIs (Claude ✓ · Codex ✓ · Cursor ✓) + detail line", group: "ai.apps", advanced: false, mount: .group),
        .init("ST-25", "Cursor status", "Shows whether Cursor is installed and signed in.", old: "Cursor CLI", group: "ai.apps", advanced: false, mount: .group),
        .init("UT-20", "Open Cursor", "Opens Cursor on your work folder.", old: "Open Cursor", group: "ai.apps", advanced: false, mount: .group),
        .init("SG-04", "Ollama", "Get or open Ollama to run a model on this Mac.", old: "Ollama row: Get Ollama / open Ollama, Skip for now", group: "ai.local", advanced: false, mount: .group, keywords: ["ollama", "local llm"]),
        .init("ST-26", "Ollama status", "Shows the local model in use.", old: "Ollama {model}", group: "ai.local", advanced: false, mount: .group),
        .init("UT-08", "Local model", "Pick the Ollama model, or follow the newest one.", old: "Local model + Apply (Automatic (newest pull) / pulled tags / pin \"not pulled\")", group: "ai.local", advanced: false, mount: .group, keywords: ["ollama", "pin model"]),
        .init("JV-01", "Decision models", "The service behind Work suggestions, done checks and Work search.", old: "Decision models (provider summary)", group: "ai.decision", advanced: false, mount: .group),
        .init("JV-02", "Default provider", "The provider every Work decision uses unless you pick another.", old: "Default (Server default / Jev / SubQ)", group: "ai.decision", advanced: false, mount: .group),
        .init("JV-08", "SubQ key", "Save a SubQ key on the server. Saving it does not select SubQ.", old: "SubQ key status, field (SubQ API key / Replace SubQ key), Save key, note", group: "ai.decision", advanced: false, mount: .group, keywords: ["subq", "api key"]),
        .init("JV-09", "Remove SubQ key", "Delete the saved SubQ key from the server.", old: "Remove saved SubQ key", group: "ai.decision", advanced: false, mount: .group),
        .init("JV-10", "Jev key status", "Shows whether the Jev key works, and any pause after errors.", old: "Jev key status, problem, \"Paused after repeated errors until …\"", group: "ai.decision", advanced: false, mount: .group),
        .init("JV-11", "Jev key", "Save a TypeSafe key for Jev. Get one at typesafe.ai.", old: "Jev key field (TypeSafe API key / Replace key) + Save, typesafe.ai note", group: "ai.decision", advanced: false, mount: .group, keywords: ["typesafe", "api key", "jev"]),
        .init("JV-12", "Remove Jev key", "Delete the saved Jev key from the server.", old: "Remove saved key", group: "ai.decision", advanced: false, mount: .group),
        .init("JV-03", "Session suggestions", "The provider that suggests Continue, Fork or New.", old: "Session suggestions (Use default / Jev / SubQ) + effective line + needs-key line", group: "ai.decision", advanced: true, mount: .group),
        .init("JV-04", "Done checks", "The provider that checks whether a reply finished the task.", old: "Completion checks", group: "ai.decision", advanced: true, mount: .group),
        .init("JV-05", "Work search", "The provider that searches Work by meaning.", old: "Work search", group: "ai.decision", advanced: true, mount: .group),
        .init("JV-06", "Refresh providers", "Read the provider settings from the server again.", old: "Refresh decision settings", group: "ai.decision", advanced: true, mount: .group),
        .init("JV-07", "SubQ data retention", "SubQ is a public preview. Read how long it keeps your data.", old: "SubQ preview and retention text + SubQ data retention link", group: "ai.decision", advanced: true, mount: .group),
        .init("KL-01", "Use your own key", "Answer with your own API key under a daily cap. Off uses your AI plan.", old: "Answer with your own key, plus on/off line", group: "ai.keys", advanced: false, mount: .group, keywords: ["byok", "api key", "openrouter", "anthropic", "openai", "spend cap"]),
        .init("KL-04", "Key details", "Each key's cap, spend and limits.", old: "Per key: key line, cap line, no-provider-limit line, local-first line, glasses hint", group: "ai.keys", advanced: false, mount: .group),
        .init("KL-06", "Key model", "The model this key answers with.", old: "Model (per key)", group: "ai.keys", advanced: false, mount: .group),
        .init("KL-07", "Use for answers", "Send your answers to this key.", old: "Use for answers", group: "ai.keys", advanced: false, mount: .group),
        .init("KL-08", "Daily cap", "The most this key can spend in a day, from $0.01 to $1000.", old: "Daily cap (USD) + Set cap", group: "ai.keys", advanced: false, mount: .group),
        .init("KL-05", "Resume key", "Clear the pause after repeated errors.", old: "Reset pause", group: "ai.keys", advanced: false, mount: .group),
        .init("KL-09", "Remove key", "Delete this key and its profile from this Mac.", old: "Remove (per key); confirm \"Remove this key?\"", group: "ai.keys", advanced: false, mount: .group),
        .init("KL-10", "Key provider", "Where the new key comes from: OpenRouter, Anthropic or OpenAI.", old: "Key from", group: "ai.keys", advanced: false, mount: .group),
        .init("KL-11", "Paste key", "Paste a key from the clipboard. COS clears the clipboard.", old: "Paste key", group: "ai.keys", advanced: false, mount: .group),
        .init("KL-12", "New key cap", "The daily cap for the key you are adding.", old: "Cap $ field", group: "ai.keys", advanced: false, mount: .group),
        .init("KL-13", "Save key", "Check and save the pasted key.", old: "Save key", group: "ai.keys", advanced: false, mount: .group),
        .init("KL-14", "Remove all keys", "Delete every saved key from this Mac.", old: "Remove all keys (confirm)", group: "ai.keys", advanced: false, mount: .group),
        .init("KL-15", "Save spend ledger", "Save the spend ledger to Downloads before keys are removed.", old: "Save the spend ledger to Downloads first", group: "ai.keys", advanced: false, mount: .group),
        .init("KL-03", "Remove saved keys", "Delete keys left on this Mac while your own key is off.", old: "Saved keys line + Remove saved keys (confirm)", group: "ai.keys", advanced: false, mount: .group),
        .init("KL-02", "Remove keys to downgrade", "An older server cannot use saved keys. Remove them to install it.", old: "Downgrade line + Remove saved keys and continue (confirm)", group: "ai.keys", advanced: false, mount: .group),
        .init("OUT-07", "Search by meaning", "Find messages by meaning. Each search uses model tokens.", old: "Meaning (search messages by meaning; also \"Turn it on\")", group: "ai.search", advanced: false, mount: .group, keywords: ["semantic", "meaning"]),
        .init("SG-02", "Your devices", "Choose Just my Mac, or My Mac and glasses.", old: "Your devices: Just my Mac / My Mac and glasses", group: "glasses.devices", advanced: false, mount: .group),
        .init("SG-11", "Connect glasses", "Set up Tailscale on both devices, then pair with a code.", old: "Glasses: Tailscale on this Mac (Get Tailscale / Open Tailscale), Tailscale on your iPhone (QR), Connect your glasses (pairing QR, code, Show a new code, Try…", group: "glasses.devices", advanced: false, mount: .group, keywords: ["tailscale", "pair", "qr code", "iphone"]),
        .init("SG-12", "Pair on home Wi-Fi", "Let a phone on this Wi-Fi pair for 10 minutes. Use it at home only.", old: "Allow pairing on this Wi-Fi (home only)", group: "glasses.devices", advanced: false, mount: .group),
        .init("SG-13", "Glasses app", "Get the COS app for your glasses.", old: "The COS app for your glasses", group: "glasses.devices", advanced: false, mount: .group),
        .init("UT-21", "Copy pairing token", "Copy the pairing token to the clipboard. Keep it private.", old: "Copy Pairing Token", group: "glasses.devices", advanced: true, mount: .group, keywords: ["token", "pairing token", "clipboard"]),
        .init("H-04", "Reset message count", "Start live messages again at #1. History stays in Archive.", old: "\"Archive live messages and start numbering at #1\" (archivebox icon), confirm \"Reset live message count?\" / \"Reset count\"", group: "glasses.devices", advanced: true, mount: .group, keywords: ["archive", "message number", "era"]),
        .init("UT-09", "Reliable video uploads", "Send videos in chunks that pick up again after a restart. Beta.", old: "Reliable video uploads (beta) + Apply", group: "glasses.video", advanced: true, mount: .group),
        .init("ST-10", "Upload status", "Uploads in progress and receipts waiting on the phone.", old: "Video uploads; \"Sideload or a killed upload can sit here for 4 hours and block Repair.\"; completed receipts await acknowledgment", group: "glasses.video", advanced: true, mount: .group),
        .init("UT-10", "Clear stuck uploads", "Cancel uploads that stopped sending. Uploads in progress stay.", old: "Clear stranded; confirm \"Clear stranded video uploads?\"", group: "glasses.video", advanced: true, mount: .group),
        .init("MT-01", "Live transcript", "Show a recording meeting at the top of Meetings as it happens.", old: "Show live meeting transcript", group: "meetings.recording", advanced: false, mount: .group, keywords: ["live transcript"]),
        .init("MT-03", "Suggest recording", "Offer to record when Zoom, Teams or Meet uses the microphone.", old: "Suggest recording when a meeting starts", group: "meetings.recording", advanced: false, mount: .group),
        .init("MT-04", "Apps to watch", "Choose which meeting apps get the suggestion.", old: "Zoom / Microsoft Teams / Google Meet", group: "meetings.recording", advanced: false, mount: .group),
        .init("MT-05", "Google Meet access", "Google Meet in a browser needs Accessibility to be noticed.", old: "Google Meet needs Accessibility note", group: "meetings.recording", advanced: false, mount: .group),
        .init("MT-06", "Never suggest for", "Apps you told COS to stop suggesting. Remove one to undo.", old: "Never for {app} + Remove", group: "meetings.recording", advanced: false, mount: .group),
        .init("MT-02", "Recording notice", "Show the notice about what COS records before the next recording.", old: "Show the recording notice again", group: "meetings.recording", advanced: false, mount: .group),
        .init("ST-14", "Live meeting audio", "Shows whether each live meeting's audio is reaching COS.", old: "Per live meeting audio row and caption", group: "meetings.recording", advanced: false, mount: .group),
        .init("ST-15", "Meeting alerts", "Alerts are off for COS Control. Open Notification settings to fix.", old: "Meeting alerts \"Off for COS Control\" + Notification settings", group: "meetings.recording", advanced: false, mount: .group),
        .init("MA-01", "Assistant model", "The model that answers when you ask during a meeting.", old: "Meeting assistant · Model", group: "meetings.assistant", advanced: false, mount: .group),
        .init("MA-02", "Web lookup", "Shows whether the assistant can search the public web.", old: "\"Public web lookup uses …\" / \"Public web lookup unavailable: …\"", group: "meetings.assistant", advanced: false, mount: .group),
        .init("MA-05", "Home city", "Where fact checks start. City and state, no street.", old: "Home city field (Austin, TX) + Save; effective line; refusal", group: "meetings.assistant", advanced: false, mount: .group),
        .init("MA-03", "Unavailable models", "Models you cannot pick right now, and why.", old: "Unavailable models (N)", group: "meetings.assistant", advanced: false, mount: .group),
        .init("MA-04", "Refresh models", "Check again which models are connected.", old: "Refresh connected models", group: "meetings.assistant", advanced: false, mount: .group),
        .init("MA-06", "Live cues", "Short prompts during a meeting. Needs a Jev or SubQ key.", old: "Live cues switch, state line, note", group: "meetings.cues", advanced: false, mount: .group, keywords: ["cues", "jev", "subq"]),
        .init("MA-07", "Add cue key", "Go to the Jev and SubQ keys, or check again.", old: "Add a Jev or SubQ key / Check again", group: "meetings.cues", advanced: false, mount: .group),
        .init("MA-13", "Glasses switch", "Cues also need Live Cues on in the glasses app.", old: "\"Cues also need Live Cues on in the glasses app.\"", group: "meetings.cues", advanced: false, mount: .group),
        .init("MA-08", "Cue bar", "Lower gives more cues. Higher gives fewer.", old: "Bar slider (More cues / Fewer cues)", group: "meetings.cues", advanced: false, mount: .group),
        .init("MA-09", "Cues per meeting", "The most cues one meeting can get.", old: "Max cues per meeting", group: "meetings.cues", advanced: false, mount: .group),
        .init("MA-10", "Gap between cues", "The shortest time between two cues.", old: "Minimum gap between cues", group: "meetings.cues", advanced: false, mount: .group),
        .init("MA-11", "Daily cue limit", "The most cue writer calls in one day.", old: "Daily writer limit", group: "meetings.cues", advanced: false, mount: .group),
        .init("MA-12", "Cue usage", "Today's cue use and save progress.", old: "Saving… line, limits note, today's usage line", group: "meetings.cues", advanced: false, mount: .group),
        .init("UT-16", "Meetings folder", "The folder that holds your meetings.", old: "Meetings Library; guidance confirm \"Meetings Library\" Choose Again / View Examples / Skip for Now", group: "meetings.library", advanced: false, mount: .group, keywords: ["meetings library", "operations folder"]),
        .init("ST-29", "Library status", "Where your meetings are and how many COS found.", old: "Meetings library path, layout and count; library warning", group: "meetings.library", advanced: false, mount: .group),
        .init("ST-16", "Meeting sync", "Where each meeting is in sync right now.", old: "Meeting sync, up to 4 meeting rows, \"+N more\", meeting-work caption", group: "meetings.library", advanced: false, mount: .group),
        .init("ST-17", "Sync now", "Run meeting sync now.", old: "Run sync now", group: "meetings.library", advanced: false, mount: .group),
        .init("ST-20", "Save status", "Meetings waiting to save, or retrying.", old: "Finalization recovery / Library save (Repair required, N retrying, N pending)", group: "meetings.library", advanced: false, mount: .group),
        .init("ST-21", "Kept captures", "Captures on this Mac that never became meetings.", old: "Retained captures, caption, \"A retained server session does not mean...\"", group: "meetings.library", advanced: false, mount: .group),
        .init("ST-22", "Recover captures", "Turn kept audio into meetings. The files stay.", old: "Recover all (confirm \"Recover all unsaved captures?\") and Recover per capture", group: "meetings.library", advanced: false, mount: .group),
        .init("ST-23", "Save captures", "Save live captures that already have a transcript.", old: "Save all (confirm \"Save still-live captures as meetings?\") and Save per capture", group: "meetings.library", advanced: false, mount: .group),
        .init("ST-18", "Early sync status", "Early sync state. This is set on the server.", old: "Early meeting sync (Off / Ready / Claiming / Final sync pending / verified / Workspace update required)", group: "meetings.library", advanced: true, mount: .group),
        .init("UT-05", "Fast preview", "Show quick meeting text first, then the final transcript.", old: "Meeting Turbo preview + Apply", group: "meetings.library", advanced: true, mount: .group),
        .init("ST-08", "Fast preview status", "Shows whether fast preview is on.", old: "Meeting preview", group: "meetings.library", advanced: true, mount: .group),
        .init("OUT-01", "Fireflies key", "Save, check or remove your Fireflies API key.", old: "FIREFLIES: key summary, \"Paste your Fireflies API key\" + Save, Check, Remove key (confirm \"Remove the Fireflies key?\")", group: "meetings.fireflies", advanced: false, mount: .group, keywords: ["fireflies", "api key"]),
        .init("OUT-02", "Import meetings", "Bring in past Fireflies meetings by date range and plan.", old: "BRING THEM IN: How far back, Plan, Import now, plan line", group: "meetings.fireflies", advanced: false, mount: .group),
        .init("OUT-03", "Keep importing", "Bring in new Fireflies meetings as they arrive.", old: "Keep bringing in new meetings + budget line", group: "meetings.fireflies", advanced: false, mount: .group),
        .init("DI-01", "Dictate into apps", "Type by voice into any Mac app.", old: "Dictate into Mac apps, plus explainer", group: "dictation.dictation", advanced: false, mount: .group, keywords: ["dictation", "voice typing", "speech to text"]),
        .init("TR-01", "Dictation engine", "Parakeet Ultra, Whisper or Automatic. Saved on the server.", old: "Dictation engine, plus its line", group: "dictation.engine", advanced: false, mount: .group, keywords: ["parakeet", "whisper", "engine"]),
        .init("SG-06", "Test engines", "Dictate a 30-second sample with each engine and compare.", old: "Dictation engine row: Dictation engine (Automatic / Parakeet Ultra / Whisper), Test on this Mac / Test again / Test, Parakeet progress and Cancel", group: "dictation.engine", advanced: false, mount: .group),
        .init("DI-35", "Dictation tab link", "Open these settings from the Dictation tab.", old: "Dictation settings pane: title + Close; openers \"Settings\" and \"Turn it on in Dictation settings\" in the Dictation tab", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-02", "Microphone", "The microphone dictation uses.", old: "Microphone (System default / devices / \"Selected microphone disconnected\")", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-03", "Refresh microphones", "Look for newly connected microphones.", old: "Refresh microphones", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-04", "Microphone fallback", "If the microphone fails, use one that worked before.", old: "If the microphone fails, try another one; note; \"Last time …\"", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-05", "Push to talk", "Hold the shortcut to dictate.", old: "Push to talk · Change / Cancel · Off", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-06", "Start and stop", "Press once to start and again to stop.", old: "Start / stop · Change / Cancel · Off", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-07", "Fix last dictation", "Correct a word in your last dictation.", old: "Fix last dictation · Change / Cancel · Off", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-08", "Typing permission", "Let COS type into other apps.", old: "Allow insertion into other apps…", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-34", "How shortcuts work", "Which keys work and how COS pastes your text.", old: "Shortcut and paste explainer; amber message line", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-09", "Start sound", "The sound when dictation starts.", old: "Sound · Start (Pet's sound / library / Your file / Your own file…) + Preview", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-10", "Stop sound", "The sound when dictation stops.", old: "Sound · Stop + Preview", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-11", "Your own sound", "Import a sound file, preview it, then save it.", old: "Import panel: Preview, Save, Cancel; Use the end of this file", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-12", "Volume", "Sound volume. Zero turns sounds off.", old: "Volume (Off at 0)", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-13", "Pitch", "Raise or lower the sounds.", old: "Pitch (semitones)", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-14", "Resume sounds", "Turn sounds back on after an audio error.", old: "\"Sounds paused after an audio error.\" + Play sounds again", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-15", "Other audio", "Mute or lower other apps while you dictate.", old: "While dictating (Mute other apps / Lower other audio / Off)", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-16", "System audio access", "Muting other apps needs System Audio Recording.", old: "Allow System Audio Recording… / Check System Audio Recording… / Mute again; muting notes", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-17", "Restore clipboard", "Put back what you had copied after COS pastes.", old: "Restore my clipboard after pasting", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-18", "Learn from edits", "Save or suggest the corrections you make.", old: "Learn from my edits (Save automatically / Suggest only / Off) + note", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-19", "Match nearby spelling", "Spell names the way the text box already has them.", old: "Spell words the way the text box has them + note", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-20", "Spoken lists", "Turn spoken list items into numbered or bulleted lists.", old: "Format spoken lists", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-21", "Remove fillers", "Drop um and uh before COS types.", old: "Remove filler sounds (um, uh) before typing + note", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-22", "Capitalize sentences", "Start each sentence with a capital letter.", old: "Capitalize the start of a sentence + note", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-23", "AI polish", "Clean up dictation with Claude Haiku or Sonnet. Uses model calls.", old: "AI polish (Off / Claude Haiku / Claude Sonnet), model line, note, pause line", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-24", "Paste then polish", "Paste right away, then swap in the polished text.", old: "Paste right away, then polish in place + note", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-27", "Learn my style", "Learn how you write from the edits you make.", old: "Your style · Learn my style from edits, status lines", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-25", "Wait for keys", "Wait until you release ⌘ or ⌃ before swapping.", old: "Wait for ⌘ or ⌃ to be released before swapping in polish + note", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-26", "Polish instructions", "Your own rules for polish, added after the built-in rules.", old: "Your polish instructions: editor, counter, Clear, Save, \"See the built-in rules\", Try again", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-28", "Style rules", "Rules COS learned or you added. Keep or remove each one.", old: "Style rules: Active (Remove), Suggested (Add, Dismiss), Pending", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-29", "Add a style rule", "Add a rule from a short list.", old: "Add a rule (Choose a rule) + Add", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-30", "Reset style", "Delete every style rule on this Mac and on the server.", old: "Reset learned style (confirm)", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-31", "Previous polish", "Use the earlier polish prompt, version 3.", old: "Previous polish (v3) + note / set on server", group: "dictation.dictation", advanced: false, mount: .group),
        .init("DI-32", "Keep dictations", "How long dictations stay on this Mac.", old: "Keep dictations for (7 days / 30 days / 90 days / Forever / Don't keep); confirm \"Stop keeping dictations?\"", group: "dictation.dictation", advanced: false, mount: .group, keywords: ["history", "retention"]),
        .init("DI-33", "Clear history", "Delete every dictation kept on this Mac.", old: "Clear dictation history (confirm)", group: "dictation.dictation", advanced: false, mount: .group),
        .init("SG-05", "Voice setup", "Download local transcription and test this Mac.", old: "Voice (local transcription) row: tier action, Voice switch Automatic / Balanced / Max, Or run it in Terminal, Test this Mac again, Transcription settings,…", group: "voice.setup", advanced: false, mount: .group, keywords: ["whisper", "download", "tier"]),
        .init("UT-03", "Quality tier", "Balanced suits most Macs. Max needs a powerful Mac.", old: "Transcription Balanced / Max + Apply; \"Update Server to 6.21.0 or newer…\"", group: "voice.setup", advanced: false, mount: .group, keywords: ["balanced", "max", "whisper"]),
        .init("TR-07", "Parakeet engine", "Install the Parakeet Ultra engine, a 654 MB download.", old: "Parakeet row: Install Parakeet (654 MB), Cancel, Check again, Use Whisper; Licenses", group: "voice.models", advanced: false, mount: .group, keywords: ["parakeet", "install"]),
        .init("ST-04", "Engine status", "Parakeet readiness and the engines in use.", old: "Local transcription; Selected live preview; Selected saved meetings; \"Your selected engines are kept. Check Transcription settings before recording.\"", group: "voice.setup", advanced: false, mount: .group),
        .init("ST-05", "Whisper status", "Whisper readiness and any error.", old: "Local Whisper, plus Whisper error line", group: "voice.setup", advanced: false, mount: .group),
        .init("UT-14", "Repair Whisper", "Restart Whisper when it stops working.", old: "Repair Whisper", group: "voice.setup", advanced: false, mount: .group, keywords: ["whisper", "restart"]),
        .init("UT-02", "Guided setup", "Run voice setup in Terminal, Balanced or Max.", old: "Guided Setup; confirm \"Choose transcription setup\" Balanced (Recommended) / Max", group: "voice.setup", advanced: true, mount: .group),
        .init("ST-13", "Model status", "The tier and the models for preview, live and save.", old: "Transcription tier; Preview, while dictating; Commit, live meeting; Polish, on save; degraded reason; \"Add names and specialist terms in the setup wizard to…", group: "voice.setup", advanced: true, mount: .group),
        .init("TR-02", "Preview model", "The model for the fast live preview.", old: "Preview model, plus its line", group: "voice.models", advanced: false, mount: .group),
        .init("TR-03", "Final model", "The model for the saved meeting transcript.", old: "HQ model, plus its line", group: "voice.models", advanced: false, mount: .group),
        .init("TR-04", "Second opinion", "A second model that checks the first.", old: "Second opinion, plus its line", group: "voice.models", advanced: false, mount: .group),
        .init("TR-06", "Refine with second", "Let the second opinion correct the transcript.", old: "Refine with second opinion, plus inactive line", group: "voice.models", advanced: false, mount: .group),
        .init("TR-05", "When changes apply", "When a model change takes effect.", old: "When-it-applies line; server refusal", group: "voice.models", advanced: false, mount: .group),
        .init("TR-08", "Front end", "How audio is prepared before transcription.", old: "Advanced · Front end", group: "voice.models", advanced: true, mount: .group),
        .init("TR-09", "Quiet detection", "How COS skips silence.", old: "Advanced · Quiet detection", group: "voice.models", advanced: true, mount: .group),
        .init("UT-11", "Idle Metal HQ", "Use the GPU for final transcripts while the Mac is idle.", old: "Idle Metal HQ + Apply", group: "voice.performance", advanced: true, mount: .group),
        .init("ST-11", "GPU status", "Shows whether the GPU path is on.", old: "Idle Metal HQ (On · preemptible / Force CPU / Off · CPU)", group: "voice.performance", advanced: true, mount: .group),
        .init("UT-12", "Audio cleanup", "Clean saved audio when you play it. The original stays.", old: "Adaptive audio cleanup + Apply", group: "voice.performance", advanced: true, mount: .group),
        .init("ST-12", "Cleanup status", "Adaptive or raw playback.", old: "Audio cleanup (Adaptive replay / Raw replay)", group: "voice.performance", advanced: true, mount: .group),
        .init("ST-19", "HQ prefill status", "Early final-quality text. This is set on the server.", old: "HQ prefill, CPU guardrail line, unavailable line", group: "voice.performance", advanced: true, mount: .group),
        .init("UT-06", "Show AI sessions", "List Claude, Codex and Cursor sessions in Activity.", old: "Show Claude sessions + Apply", group: "work.sessions", advanced: false, mount: .group, keywords: ["claude sessions", "privacy"]),
        .init("UT-07", "Continue threads", "Let a reply continue a real Claude or Codex session.", old: "Continue agent threads + Apply", group: "work.sessions", advanced: false, mount: .group, keywords: ["continue", "attach", "threads"]),
        .init("ST-09", "Continue status", "Shows which apps can be continued.", old: "Continue threads", group: "work.sessions", advanced: false, mount: .group),
        .init("WK-03", "Open in app", "Open a new session in its app after the first reply.", old: "Open new sessions in the app", group: "work.sessions", advanced: false, mount: .group),
        .init("WK-02", "Work notifications", "Tell me when a session gets Work, finishes, or needs me.", old: "Work notifications", group: "work.sessions", advanced: false, mount: .group),
        .init("OUT-04", "Track usage", "Count session tokens on this Mac. Nothing is uploaded.", old: "Track session usage on this Mac", group: "work.sessions", advanced: false, mount: .group, keywords: ["usage", "tokens"]),
        .init("WK-04", "Send without review", "Plan and send in one step. Each card can override it.", old: "Send plans without review", group: "work.chat", advanced: false, mount: .group),
        .init("WK-05", "When work is open", "Queue a new send behind open work, or ask each time.", old: "When earlier work is still open (Queue it / Ask each time)", group: "work.chat", advanced: false, mount: .group),
        .init("WK-01", "Expire old asks", "Drop old asks from other people. Restore them for 30 days.", old: "Work intake · Expire old asks from other people + note", group: "work.chat", advanced: false, mount: .group),
        .init("OUT-05", "Default planner", "The model that plans Work.", old: "Plan with (per-Mac default planner)", group: "work.chat", advanced: true, mount: .group),
        .init("OUT-06", "Planning effort", "How hard the planner thinks. Higher costs more.", old: "Effort (per-Mac default)", group: "work.chat", advanced: true, mount: .group),
        .init("UT-04", "Background jobs", "Keep replies running after the phone app closes.", old: "Background jobs + Apply", group: "work.background", advanced: false, mount: .group, keywords: ["background jobs"]),
        .init("ST-07", "Background status", "Shows whether background jobs are allowed.", old: "Background jobs (Allowed / Off)", group: "work.background", advanced: false, mount: .group),
        .init("UT-15", "Work folder", "The folder your AI apps work in.", old: "Work Folder", group: "work.folders", advanced: false, mount: .group, keywords: ["work folder", "workspace"]),
        .init("ST-28", "Work folder status", "The current work folder, and any restart it waits for.", old: "Work folder path; \"Saved to LaunchAgent · pending a safe server restart\"", group: "work.folders", advanced: false, mount: .group),
        .init("UT-17", "Notes folder", "The folder of memory and thread notes.", old: "COS Data", group: "work.folders", advanced: false, mount: .group, keywords: ["cos data", "memory", "threads", "notes"]),
        .init("UT-18", "Create folders", "Make the memory and threads folders for you.", old: "Create Folders", group: "work.folders", advanced: false, mount: .group),
        .init("ST-06", "Memory and threads", "How many memories and threads COS can read.", old: "Memory & Threads; hint; Root / Looked in; dormant Python bridge note", group: "work.folders", advanced: false, mount: .group),
        .init("UT-19", "Notes source", "Where notes are read from: plain files or the bridge.", old: "Bridge: / Notes: path", group: "work.folders", advanced: true, mount: .group),
        .init("MB-02", "Morning brief", "A daily brief that lands in your inbox.", old: "Brief every", group: "work.brief", advanced: false, mount: .group, keywords: ["morning brief", "schedule"]),
        .init("MB-01", "Brief status", "When the next brief arrives, or why it will not.", old: "MORNING BRIEF status line (Next …, Off while Background jobs are off, Paused for maintenance, Daily at …, Off)", group: "work.brief", advanced: false, mount: .group),
        .init("MB-03", "Brief time", "The time the brief arrives.", old: "Time field (07:00) + time zone", group: "work.brief", advanced: false, mount: .group),
        .init("MB-04", "Brief days", "The days the brief runs.", old: "Weekday chips M T W T F S S", group: "work.brief", advanced: false, mount: .group),
        .init("MB-05", "Brief sources", "What the brief includes.", old: "Sources · N on; one checkbox per source with description and coverage", group: "work.brief", advanced: false, mount: .group),
        .init("MB-07", "Save brief", "Save the schedule and the sources.", old: "Apply", group: "work.brief", advanced: false, mount: .group),
        .init("MB-08", "Brief now", "Send a brief now. Up to five a day.", old: "Run Now", group: "work.brief", advanced: false, mount: .group),
        .init("MB-09", "Last brief", "How the last brief went.", old: "Last brief line; Retry; Loading the schedule…", group: "work.brief", advanced: false, mount: .group),
        .init("MB-06", "Source options", "Settings for each source.", old: "Per-source options (boolean checkbox, integer stepper, text field)", group: "work.brief", advanced: false, mount: .group),
        .init("DM-01", "Domains", "The areas your tasks are grouped by.", old: "Domains: one \"domain\" field per name; empty-state line", group: "work.domains", advanced: false, mount: .group),
        .init("DM-02", "Order and remove", "Reorder or unlist a domain. Its folder stays.", old: "Move up, Remove (per row)", group: "work.domains", advanced: false, mount: .group),
        .init("DM-03", "Save domains", "Add, save or reset the list.", old: "Add, Save, Reset", group: "work.domains", advanced: false, mount: .group),
        .init("FN-01", "Paused threads", "Threads COS stopped writing to after a reply went missing.", old: "Fenced threads · N, explanation, degraded warning, Refresh", group: "work.fences", advanced: false, mount: .group),
        .init("FN-02", "Release thread", "Let COS write to the thread again. Check it first.", old: "Release (per fence); confirm \"Release this fence?\" / Release", group: "work.fences", advanced: false, mount: .group),
        .init("PM-01", "Permissions", "What COS can use on this Mac, with one click to allow each.", old: "Permissions · {summary}; card \"Each one switches on a feature. COS works without any of them.\" + Done", group: "privacy.permissions", advanced: false, mount: .group),
        .init("PM-02", "Accessibility", "Lets COS type for you, jump to sessions and see Meet tabs.", old: "Accessibility (action, \"Already on? Reset and add again\")", group: "privacy.permissions", advanced: false, mount: .group, keywords: ["accessibility", "tcc"]),
        .init("PM-03", "Notifications", "Lets COS send meeting and Work alerts.", old: "Notifications (Allow)", group: "privacy.permissions", advanced: false, mount: .group, keywords: ["notifications", "alerts"]),
        .init("PM-04", "Open at login", "Login item status. The switch lives in General.", old: "Open at login (Turn on / open Login Items)", group: "privacy.permissions", advanced: false, mount: .group),
        .init("PM-05", "Background items", "Lets the COS server keep running in the background.", old: "Background jobs (name) / Glasses server (name)", group: "privacy.permissions", advanced: false, mount: .group),
        .init("PM-06", "Automation", "Lets COS control Claude, Cursor and Terminal.", old: "Automation: Claude / Cursor / Terminal (Test)", group: "privacy.permissions", advanced: false, mount: .group),
        .init("PM-07", "Calendar", "Lets COS read your calendar.", old: "Calendar (CalendarFetch) (Fix)", group: "privacy.permissions", advanced: false, mount: .group),
        .init("PM-08", "Old test builds", "Remove permission entries left by old COS builds.", old: "Clean up old COS test builds; per build Reset", group: "privacy.permissions", advanced: true, mount: .group),
        .init("PT-01", "Session pet", "A small character that shows what your AI sessions are doing.", old: "Session pet disclosure (On · size · % size · % speed · motion / Off) + Session pet switch", group: "pet.pet", advanced: false, mount: .group, keywords: ["session pet", "sprite", "character"]),
        .init("PT-02", "Jump access", "Clicking the pet to jump to a session needs Accessibility.", old: "Jump to session needs Accessibility; Grant; Reset and add again", group: "pet.pet", advanced: false, mount: .group),
        .init("PT-03", "Pet size", "Small, medium, large or a custom size.", old: "Pet size (presets incl. Custom)", group: "pet.pet", advanced: false, mount: .group),
        .init("PT-04", "Custom size", "The pet's size in pixels.", old: "Custom pixels field + stepper (px)", group: "pet.pet", advanced: false, mount: .group),
        .init("PT-05", "Figure size", "Scale the character only. Buttons and text keep their size.", old: "Character size slider", group: "pet.pet", advanced: false, mount: .group),
        .init("PT-06", "Animation speed", "How fast the character moves.", old: "Character speed slider", group: "pet.pet", advanced: false, mount: .group),
        .init("PT-07", "Motion", "Full, calm or no motion.", old: "Motion (Full / Calm / None)", group: "pet.pet", advanced: false, mount: .group),
        .init("PT-09", "Characters", "Pick a character from COS or the community gallery.", old: "Characters (N, N ADVANCED): search, Try again, bundled tiles (confirm \"Use X?\", click only) and community tiles (confirm \"Use X as the session pet figure?\")", group: "pet.characters", advanced: false, mount: .group),
        .init("PT-10", "Default character", "Go back to Cloud Puff.", old: "Use Cloud Puff", group: "pet.pet", advanced: false, mount: .group),
        .init("PT-14", "Pet intro", "One-time intro: keep, calm or hide the pet.", old: "Pet intro: Keep / Calm / Hide", group: "pet.pet", advanced: false, mount: .group),
        .init("PT-08", "State sprites", "Set the image and frame count for each state.", old: "State sprites (N states): per state frames stepper + Choose; More states", group: "pet.pet", advanced: true, mount: .group),
        .init("PT-11", "Install sprite pack", "Install a folder of character sprites.", old: "Install sprite pack", group: "pet.pet", advanced: true, mount: .group),
        .init("PT-12", "Choose sprite", "Use one image for every state.", old: "Choose sprite / Replace sprite", group: "pet.pet", advanced: true, mount: .group),
        .init("PT-13", "Use COS figure", "Remove your own sprites.", old: "Use COS figure", group: "pet.pet", advanced: true, mount: .group),
        .init("ST-01", "Server status", "Whether the COS server is running and healthy.", old: "Server", group: "system.server", advanced: false, mount: .group),
        .init("ST-02", "Ownership", "Whether COS Control manages this server.", old: "Ownership", group: "system.server", advanced: false, mount: .group),
        .init("ST-03", "Recovery", "Whether automatic recovery is set up.", old: "Recovery (Scheduled / Needs repair)", group: "system.server", advanced: false, mount: .group),
        .init("ST-27", "Server version", "The COS server version.", old: "Version (server)", group: "system.server", advanced: false, mount: .group),
        .init("ST-30", "Work in progress", "Active jobs and recordings. Restart waits for them.", old: "\"{n} job(s), {m} recording(s) active. Restart is locked.\"", group: "system.server", advanced: false, mount: .group),
        .init("ST-31", "Pending change", "A server change in progress, or one that needs Repair.", old: "\"Server change in progress · recovery is armed\" / \"An interrupted server change needs Repair.\"", group: "system.server", advanced: false, mount: .group),
        .init("C-09", "Server messages", "Warnings and progress for server changes.", old: "Foreground-server warning, ownership conflict, operation progress, green notice", group: "system.server", advanced: false, mount: .group),
        .init("C-01", "Restart", "Restart the server. Waits until no work is running.", old: "Restart; confirm \"Restart this self-managed server?\" / Restart now", group: "system.server", advanced: false, mount: .group),
        .init("C-02", "Stop", "Stop the server.", old: "Stop", group: "system.server", advanced: false, mount: .group),
        .init("C-03", "Start", "Start the server.", old: "Start", group: "system.server", advanced: false, mount: .group),
        .init("C-04", "Update server", "Install the newest server and restart it.", old: "Update Server", group: "system.server", advanced: false, mount: .group, keywords: ["update server", "npm"]),
        .init("C-05", "Install server", "Install the COS server.", old: "Install Server", group: "system.server", advanced: false, mount: .group),
        .init("C-06", "Adopt server", "Take over a stopped older server safely.", old: "Adopt Safely", group: "system.server", advanced: true, mount: .group),
        .init("C-07", "Manage in place", "Manage your running server without replacing it.", old: "Manage in place", group: "system.server", advanced: true, mount: .group),
        .init("C-08", "Replace server", "Stop the older server and install the managed one.", old: "Install managed server; confirm \"Install the latest managed server?\" / Stop legacy and install", group: "system.server", advanced: true, mount: .group),
        .init("H-01", "App version", "The COS Control version.", old: "v{version} stamp", group: "system.updates", advanced: false, mount: .group),
        .init("H-02", "Check for updates", "Refresh status and look for a new version.", old: "Refresh status and check for updates (arrow icon, help text)", group: "system.updates", advanced: false, mount: .group, keywords: ["check for updates", "refresh"]),
        .init("H-03", "Update status", "Whether the last check found an update.", old: "\"Your local glasses server\" / Checking for updates… / Up to date / Couldn't check for updates", group: "system.updates", advanced: false, mount: .group),
        .init("H-05", "Update banner", "Download and install a new version.", old: "Update banner: \"Update available\" / Update; \"Finish installing X\" / Install; \"Downloading update\"; \"Installing update\"; \"Update did not install\" / Try…", group: "system.updates", advanced: false, mount: .topStrip),
        .init("H-06", "What's new", "Notes for the new version, then install.", old: "What's New window: Download and install, Cancel, Done", group: "system.updates", advanced: false, mount: .group),
        .init("H-07", "Announcements", "News from the COS team. Dismiss to hide.", old: "Publisher notice (title, body, dismiss x)", group: "system.updates", advanced: false, mount: .topStrip),
        .init("G-05", "Versions", "App and server versions side by side.", old: "Controller X • Server Y (npm latest) / self-managed / not installed", group: "system.updates", advanced: false, mount: .group),
        .init("UT-01", "Run checks", "Check the setup and list any problems.", old: "Run Doctor", group: "system.troubleshooting", advanced: false, mount: .group, keywords: ["doctor", "diagnostics"]),
        .init("DR-01", "Check results", "Results of the last check.", old: "DOCTOR results (name, detail, state per check)", group: "system.troubleshooting", advanced: false, mount: .group),
        .init("UT-13", "Repair", "Fix the managed server setup.", old: "Repair Managed Runtime", group: "system.troubleshooting", advanced: false, mount: .group),
        .init("UT-22", "Copy report", "Copy a support report to the clipboard.", old: "Copy Report", group: "system.troubleshooting", advanced: false, mount: .group, keywords: ["report", "support"]),
        .init("UT-23", "Open logs", "Open the log folder.", old: "Open Logs", group: "system.troubleshooting", advanced: false, mount: .group, keywords: ["logs", "console"]),
        .init("UT-28", "Online help", "Open COS Control help on gotcos.com.", old: "Advanced · Setup Guide", group: "system.troubleshooting", advanced: false, mount: .group, keywords: ["help", "gotcos", "setup guide"]),
        .init("G-04", "Quit", "Quit COS Control.", old: "Quit", group: "system.troubleshooting", advanced: false, mount: .group, keywords: ["quit", "exit"]),
        .init("UT-24", "Health page", "Open the server health page in your browser.", old: "Health", group: "system.server", advanced: true, mount: .group),
        .init("UT-26", "Roll back server", "Go back to the previous server version.", old: "Advanced · Rollback Server", group: "system.server", advanced: true, mount: .group, keywords: ["rollback", "downgrade"]),
        .init("UT-27", "Finish server change", "Finish or undo an interrupted server change.", old: "Advanced · Reconcile Change", group: "system.server", advanced: true, mount: .group),
        .init("H-10", "Recording card", "A live recording, with View live transcript and Stop and save, above every page while it records.", old: "Recording card: {n} recording, reminder, View live transcript, Stop and save (confirm \"Stop and save this glasses meeting?\"), \"Enable live transcripts in…", group: "meetings.recording", advanced: false, mount: .topStrip),
        .init("H-11", "Activity launcher", "Navigation for the menu-bar panel", old: "Activity · \"Browse without losing your place\" · Open, plus section chips", group: nil, advanced: false, mount: .outside),
        .init("H-12", "Your move", "Navigation to Work", old: "Your move · {n}", group: nil, advanced: false, mount: .outside),
        .init("TR-10", "Panel Parakeet line", "A just-in-time prompt in the menu-bar panel; TR-07 is the setting", old: "Panel line \"Dictation\" with the Parakeet row", group: nil, advanced: false, mount: .outside),
        .init("PT-15", "Pet right-click menu", "In-place shortcuts on the pet", old: "Pet right-click: Full motion / Calm motion / No motion, Hide pet, Settings…, Setup guide…", group: nil, advanced: false, mount: .outside),
        .init("MN-01", "App menu Setup guide…", "Entry point", old: "App menu · Setup guide…", group: nil, advanced: false, mount: .outside),
        .init("MN-02", "App menu Settings…", "Entry point; must open the new view", old: "App menu · Settings… (⌘,)", group: nil, advanced: false, mount: .outside),
        .init("MN-03", "Meetings menu", "Live recording commands", old: "Meetings · Record on Mac…, Stop Mac recording and save (⇧⌘R), View live transcript (⇧⌘L)", group: nil, advanced: false, mount: .outside),
        .init("MN-04", "Dictation menu", "Live dictation commands; Settings… must open 3.5", old: "Dictation · Stop dictation, Cancel dictation, Dictionary…, History…, Settings…", group: nil, advanced: false, mount: .outside),
        .init("MN-05", "Help menu", "Entry point", old: "Help · Setup guide…, COS Control help", group: nil, advanced: false, mount: .outside),
        .init("MN-06", "Dock menu", "Entry point", old: "Dock menu · View live transcript, Open Activity, Setup guide…, Settings…", group: nil, advanced: false, mount: .outside),
        .init("MN-07", "Menu-bar icon", "Status", old: "Menu-bar icon (eyeglasses / eyeglasses.slash, red dot, gold update)", group: nil, advanced: false, mount: .outside),
        .init("MN-08", "Menu-bar recording strip", "Live work", old: "Menu-bar Mac recording strip: View live transcript, Stop and save", group: nil, advanced: false, mount: .outside),
        .init("MN-09", "Activity and Welcome Settings buttons", "Entry points; must open the new view", old: "Activity: Settings (rail and toolbar), Setup guide, Settings…; Welcome window \"Open settings\"", group: nil, advanced: false, mount: .outside)
    ]

    static var all: [SettingsHubItem] { items + extras }
    static func group(_ id: String) -> SettingsHubGroup? { groups.first { $0.id == id } }
    static func groups(in category: SettingsHubCategory) -> [SettingsHubGroup] { groups.filter { $0.category == category } }
    static func item(_ id: String) -> SettingsHubItem? { all.first { $0.id == id } }
    /// The rows of one group, as drawn: in the card, not the top strip.
    static func items(inGroup id: String) -> [SettingsHubItem] { all.filter { $0.group == id && $0.mount == .group } }
    /// The count beside a group's Advanced disclosure.
    static func advancedCount(_ group: String) -> Int { items(inGroup: group).filter(\.advanced).count }
    /// What search covers: every row the hub draws, in a card or in the top strip.
    static var searchable: [SettingsHubItem] { all.filter { $0.mount != .outside } }
    static func category(of item: SettingsHubItem) -> SettingsHubCategory? { item.group.flatMap { group($0)?.category } }
}

/// Where a deep link lands. `model.panelScrollTarget` carries the classic panel's anchors; the hub routes each one to
/// its category and group, and opens Advanced when the target sits inside it (as `jevExpanded` does for Decision models).
enum SettingsHubRoute {
    struct Destination: Equatable, Sendable {
        let category: SettingsHubCategory
        let group: String
        let opensAdvanced: Bool
        /// The scroll target inside the page: the group's own anchor.
        var anchor: String { SettingsHub.anchor(group) }
    }
    /// The classic panel's anchors (Views.swift mainPanel `.id(...)`, KeyLanesViews.swift `.id("key-lanes")`,
    /// LiveCues.decisionKeysAnchor) and the group each is in.
    static let panelAnchors: [String: String] = [
        "settings": "meetings.assistant",
        "transcription": "voice.models",
        "decision-models": "ai.decision",
        "setup-guide": "general.guide",
        "key-lanes": "ai.keys",
    ]
    /// A panel anchor, a hub anchor ("hub.<group>"), a group id or an inventory row id.
    static func destination(_ target: String) -> Destination? {
        if let group = panelAnchors[target] { return destination(group: group, advanced: false) }
        let bare = target.hasPrefix("hub.") ? String(target.dropFirst(4)) : target
        if SettingsHubCatalog.group(bare) != nil { return destination(group: bare, advanced: false) }
        if let item = SettingsHubCatalog.item(target), item.mount != .outside, let group = item.group {
            return destination(group: group, advanced: item.advanced)
        }
        return nil
    }
    private static func destination(group: String, advanced: Bool) -> Destination? {
        guard let spec = SettingsHubCatalog.group(group) else { return nil }
        return Destination(category: spec.category, group: group, opensAdvanced: advanced)
    }
}

/// Search covers the whole catalogue, not only the open category: the new label, the description, the OLD label (so a
/// renamed setting is found by the name people remember) and keywords. Every word typed must match somewhere.
enum SettingsHubSearch {
    struct Section: Equatable, Sendable {
        let category: SettingsHubCategory
        let items: [SettingsHubItem]
    }
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
    }
    static func words(_ text: String) -> [String] { normalized(text).split(separator: " ").map(String.init) }
    /// 0 is the best: the label starts with the query; then the label holds it; then the old label; then a keyword or
    /// the group; then only the description. Nil: no match.
    static func rank(_ item: SettingsHubItem, query: String) -> Int? {
        let terms = words(query)
        guard !terms.isEmpty else { return nil }
        let label = normalized(item.label), old = normalized(item.old), detail = normalized(item.detail)
        let group = item.group.flatMap { SettingsHubCatalog.group($0) }.map { normalized($0.title) } ?? ""
        let keys = normalized(item.keywords.joined(separator: " "))
        let haystack = [label, old, detail, keys, group].joined(separator: " ")
        guard terms.allSatisfy({ haystack.contains($0) }) else { return nil }
        if words(item.label).joined(separator: " ").hasPrefix(terms.joined(separator: " ")) { return 0 }
        if terms.allSatisfy({ label.contains($0) }) { return 1 }
        if terms.allSatisfy({ old.contains($0) }) { return 2 }
        if terms.allSatisfy({ (keys + " " + group).contains($0) }) { return 3 }
        return 4
    }
    /// Grouped by category in the sidebar's order; best match first inside each, catalogue order on a tie.
    static func results(_ query: String) -> [Section] {
        let ranked = SettingsHubCatalog.searchable.enumerated().compactMap { index, item -> (SettingsHubItem, Int, Int)? in
            rank(item, query: query).map { (item, $0, index) }
        }
        return SettingsHubCategory.allCases.compactMap { category in
            let rows = ranked.filter { SettingsHubCatalog.category(of: $0.0) == category }
                .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }.map(\.0)
            return rows.isEmpty ? nil : Section(category: category, items: rows)
        }
    }
}

/// The breakpoints, by the width the hub is given (the window's width in both Activity frames: the hub takes the rail's
/// place in Today and the content region under the toolbar in the classic frame). The window's minimum is 760 x 560.
enum SettingsHubLayout {
    enum Mode: Equatable, Sendable { case wide, medium, narrow }
    /// Three columns from here (the sidebar, the page and On this page).
    static let wideMinimum: CGFloat = 1100
    /// The full sidebar from here; below it the sidebar is icons only.
    static let mediumMinimum: CGFloat = 900
    static let sidebarWidth: CGFloat = 264
    static let compactSidebarWidth: CGFloat = 64
    static let railWidth: CGFloat = 200
    /// The cards' reading width (the boards' 820).
    static let pageMaxWidth: CGFloat = 820
    static func mode(width: CGFloat) -> Mode {
        width >= wideMinimum ? .wide : width >= mediumMinimum ? .medium : .narrow
    }
    static func sidebar(_ mode: Mode) -> CGFloat { mode == .narrow ? compactSidebarWidth : sidebarWidth }
    static func showsRail(_ mode: Mode) -> Bool { mode == .wide }
    static func pagePadding(_ mode: Mode) -> CGFloat { mode == .narrow ? 28 : 48 }
    /// The page column's width once the sidebar, the rail and the padding are taken.
    static func pageWidth(total: CGFloat) -> CGFloat {
        let m = mode(width: total)
        return max(0, total - sidebar(m) - (showsRail(m) ? railWidth : 0) - 2 * pagePadding(m))
    }
}

/// On this page: the group in view is the last one whose top has passed `line` (measured from the top of the scroll
/// view), or the last group when the page is scrolled to its end, or the first when none has.
enum SettingsHubSpy {
    static func active(tops: [(id: String, minY: CGFloat)], line: CGFloat, atEnd: Bool) -> String? {
        guard let first = tops.first else { return nil }
        if atEnd { return tops.last?.id }
        return tops.last(where: { $0.minY <= line })?.id ?? first.id
    }
}

/// The one-line status under each category in the sidebar. Only live values the model already holds, and only when
/// they are known; anything else is the category's short static description. Never invented.
struct SettingsHubFacts: Equatable, Sendable {
    var todayHome = false
    /// Claude, Codex and Cursor: how many are ready, of how many the server reported.
    var aiReady = 0
    var aiKnown = 0
    var glassesPath: Bool?
    var liveCuesOn: Bool?
    var recording = false
    var dictationOn = false
    /// "auto", "parakeet-ultra" or "whisper", from the server's transcription settings.
    var dictationEngine: String?
    var usesParakeet: Bool?
    var whisperReady = false
    var briefEnabled: Bool?
    var briefTime: String?
    var permissionsNeed: Int?
    var petOn = false
    var serverRunning = false
    var serverChecked = false
    var updateReady = false
}

enum SettingsHubStatus {
    enum Tone: Equatable, Sendable { case plain, good, hot }
    static func line(_ category: SettingsHubCategory, _ f: SettingsHubFacts) -> (text: String, tone: Tone) {
        switch category {
        case .general:
            return (f.todayHome ? "Opens on Today" : "Opens on the classic home", .plain)
        case .ai:
            guard f.aiKnown > 0 else { return ("Claude, Codex, Cursor", .plain) }
            if f.aiReady == f.aiKnown { return (f.aiKnown == 1 ? "1 AI app ready" : "\(f.aiKnown) AI apps ready", .plain) }
            return ("\(f.aiReady) of \(f.aiKnown) AI apps ready", .hot)
        case .glasses:
            guard let glasses = f.glassesPath else { return ("Pairing and video", .plain) }
            return (glasses ? "Mac and glasses" : "Just this Mac", .plain)
        case .meetings:
            if f.recording { return ("Recording now", .hot) }
            guard let cues = f.liveCuesOn else { return ("Recording and assistant", .plain) }
            return (cues ? "Live cues on" : "Live cues off", cues ? .hot : .plain)
        case .dictation:
            guard f.dictationOn else { return ("Off", .plain) }
            if let engine = f.dictationEngine, let name = engineName[engine] { return ("On · " + name, .plain) }
            return ("On", .plain)
        case .voice:
            guard let parakeet = f.usesParakeet else { return ("Models and voice setup", .plain) }
            if parakeet { return ("Parakeet", .plain) }
            return (f.whisperReady ? "Whisper" : "Whisper not ready", f.whisperReady ? .plain : .hot)
        case .work:
            guard let enabled = f.briefEnabled else { return ("Sessions and Work chat", .plain) }
            if enabled, let time = f.briefTime, !time.isEmpty { return ("Morning brief at " + time, .plain) }
            return (enabled ? "Morning brief on" : "Morning brief off", .plain)
        case .privacy:
            guard let need = f.permissionsNeed else { return ("Permissions", .plain) }
            return need == 0 ? ("All granted", .plain) : (need == 1 ? "1 needs you" : "\(need) need you", .hot)
        case .pet:
            return (f.petOn ? "Pet on" : "Pet off", .plain)
        case .system:
            if f.updateReady { return ("Update ready", .hot) }
            guard f.serverChecked else { return ("Server and updates", .plain) }
            return f.serverRunning ? ("Server connected", .good) : ("Server not answering", .hot)
        }
    }
    static let engineName = ["auto": "Automatic", "parakeet-ultra": "Parakeet", "whisper": "Whisper"]
}
