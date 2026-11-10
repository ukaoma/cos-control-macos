import Foundation

/// Production hardening for 0.5.387 (lane D1, 2026-11-09): is this Mac a NEW COS Control install?
///
/// Miles, 2026-11-09: first-run defaults (Today home, the Settings Basic view) change for NEW installs only; an
/// existing user's home never changes. So the answer is decided ONCE, the first time a build with this code launches,
/// and kept in UserDefaults under `cos.install.cohort` ("new" or "existing"). When anything is unclear the answer is
/// existing.
///
/// Why these signals (each checked against the source, 0.5.385 acc5246):
/// - `cos.whatsNew.lastSeenBuild` (WhatsNewAfterUpdate.defaultsKey) is written by every build since 0.5.274 on its first
///   launch. A value for ANOTHER build means an earlier Control ran here. The same build's value proves nothing: this
///   launch writes it in ControllerModel's init, before the decision runs.
/// - The SetupGuideState keys (KeyLanes.priorSetupKeys): only finishing, hiding or passing the glasses step writes them.
/// - `cos.keyLanes.install`: written on a status read, which is async and after the launch decision.
/// - `~/Library/Application Support/COS Control/runtime`: the managed server, made only by an install from Control.
/// - `.../COS Control/updates/success.json`: the updater's record of a swap, so an update, never a first install.
/// NOT signals, on purpose: the preferences plist's dates (macOS rewrites it atomically on every write, so its creation
/// date is the last write; measured 2026-11-09) and the `COS Control` folder itself (ControlInstance makes it at launch).
enum InstallCohort {
    enum Cohort: String, Equatable, Sendable { case new, existing }

    static let key = "cos.install.cohort"
    /// Mirrors WhatsNewAfterUpdate.defaultsKey (Models.swift) and KeyLanes.priorSetupKeys / installKey (KeyLanes.swift).
    /// Spelled here so this file compiles alone; Tests/install-cohort-pins.py keeps them equal.
    static let lastSeenBuildKey = "cos.whatsNew.lastSeenBuild"
    static let priorSetupKeys = ["cos.setupGuide.journeyFinished", "cos.setupGuide.glassesHandled", "cos.setupGuide.hidden"]
    static let keyLanesInstallKey = "cos.keyLanes.install"

    /// What the Mac shows at the moment of the decision. Pure input: Tests/InstallCohortChecks.swift walks the table.
    struct Evidence: Equatable, Sendable {
        /// The value already stored under `cos.install.cohort`, if any.
        var stored: String? = nil
        /// This build's CFBundleVersion as a whole number. nil or 0: unreadable, so unsure.
        var runningBuild: Int? = nil
        var lastSeenBuild: Int? = nil
        var priorSetupKey = false
        var keyLanesInstall: String? = nil
        var runtimeFolder = false
        var updaterRecord = false
    }

    /// The decision table. A stored answer always wins, so a decision is made once and kept.
    static func decide(_ evidence: Evidence) -> Cohort {
        if let stored = evidence.stored, let cohort = Cohort(rawValue: stored) { return cohort }
        guard let running = evidence.runningBuild, running > 0 else { return .existing }
        if let seen = evidence.lastSeenBuild, seen != running { return .existing }
        if evidence.priorSetupKey || evidence.keyLanesInstall != nil || evidence.runtimeFolder || evidence.updaterRecord {
            return .existing
        }
        return .new
    }

    /// True only for a Mac decided "new". D2 (Settings Basic view) and the Today home default read this.
    static var isNewInstall: Bool { current() == .new }

    /// The kept answer, deciding and storing it first if no answer is kept yet. Outside the shipped app (render lanes,
    /// native tests, previews with COS_CONTROL_TEST_HOME) it answers existing and writes nothing.
    static func current(defaults: UserDefaults = .standard) -> Cohort {
        guard isShippedApp else { return .existing }
        if let stored = defaults.string(forKey: key), let cohort = Cohort(rawValue: stored) { return cohort }
        let cohort = decide(liveEvidence(defaults: defaults))
        defaults.set(cohort.rawValue, forKey: key)
        return cohort
    }

    /// Called once at launch (ControlSetup.swift, SetupWindowPresenter's init, before any window or status read).
    @discardableResult
    static func decideAtLaunch(defaults: UserDefaults = .standard) -> Cohort { current(defaults: defaults) }

    // MARK: Live probes (read only; nothing here prompts or writes)

    static var isShippedApp: Bool {
        ProcessInfo.processInfo.environment["COS_CONTROL_TEST_HOME"] == nil && Bundle.main.bundleIdentifier == "com.gotcos.control"
    }

    static func liveEvidence(defaults: UserDefaults, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Evidence {
        let support = home.appendingPathComponent("Library/Application Support/COS Control", isDirectory: true)
        let raw = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "").trimmingCharacters(in: .whitespaces)
        return Evidence(
            stored: defaults.string(forKey: key),
            runningBuild: Int(raw.prefix(while: \.isNumber)),
            lastSeenBuild: defaults.object(forKey: lastSeenBuildKey) as? Int,
            priorSetupKey: priorSetupKeys.contains { defaults.object(forKey: $0) != nil },
            keyLanesInstall: defaults.string(forKey: keyLanesInstallKey),
            runtimeFolder: FileManager.default.fileExists(atPath: support.appendingPathComponent("runtime").path),
            updaterRecord: FileManager.default.fileExists(atPath: support.appendingPathComponent("updates/success.json").path))
    }
}
