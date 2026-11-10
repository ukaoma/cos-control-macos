import Foundation
import SwiftUI

/// Production hardening for 0.5.387 (lane D1, 2026-11-09): is this Mac a NEW COS Control install?
///
/// Miles, 2026-11-09: first-run defaults (Today home, the Settings Basic view) change for NEW installs only; an
/// existing user's home never changes. The answer is kept once in UserDefaults under `cos.install.cohort` ("new" or
/// "existing"). Until it is kept, it reads as existing. Defaults are never written from it: a reader takes the person's
/// own stored value when the key was ever written, else the cohort's default (CohortDefault, TodayHome.enabled).
///
/// How it is decided (the lead's rule, COORD 2026-11-09 19:12: derive from KeyLanes.Install, cos.keyLanes.install):
/// 1. At launch (SetupWindowPresenter's init, before any window or status read), a Mac that shows ANY sign of an earlier
///    Control is kept as existing at once. The signs, each checked against the 0.5.385 source:
///    - `cos.keyLanes.install` already stored. Every build since 0.5.329 classifies on its first status read, so a
///      Mac that ran one holds it, "new" included (a fresh install from last month is an existing user now).
///    - `cos.whatsNew.lastSeenBuild` for ANOTHER build (every build since 0.5.274 writes it on its first launch).
///    - a SetupGuideState key (KeyLanes.priorSetupKeys): only finishing, hiding or passing the glasses step writes one.
///    - `~/Library/Application Support/COS Control/runtime` (the managed server) or `.../updates/success.json` (an update).
///    - an unreadable build number (unsure).
/// 2. Otherwise it waits: KeyLanes classifies on this launch's first known status (needsFirstRun and no prior setup is
///    new, anything else existing), and adoptKeyLanes copies that answer the moment it lands (ControlSetup.swift).
/// NOT signals, on purpose: the preferences plist's dates (macOS rewrites the plist atomically on every write, so its
/// creation date is the last write; measured 2026-11-09) and the `COS Control` folder itself (ControlInstance makes it).
enum InstallCohort {
    enum Cohort: String, Equatable, Sendable { case new, existing }

    static let key = "cos.install.cohort"
    /// Mirrors WhatsNewAfterUpdate.defaultsKey (Models.swift) and KeyLanes.priorSetupKeys / installKey (KeyLanes.swift),
    /// spelled here so the rule compiles alone; Tests/install-cohort-pins.py keeps them equal.
    static let lastSeenBuildKey = "cos.whatsNew.lastSeenBuild"
    static let priorSetupKeys = ["cos.setupGuide.journeyFinished", "cos.setupGuide.glassesHandled", "cos.setupGuide.hidden"]
    static let keyLanesInstallKey = "cos.keyLanes.install"

    /// What the Mac shows at launch. Pure input: Tests/InstallCohortChecks.swift walks the table.
    struct Evidence: Equatable, Sendable {
        /// The value already kept under `cos.install.cohort`, if any.
        var stored: String? = nil
        /// This build's CFBundleVersion as a whole number. nil or 0: unreadable, so unsure.
        var runningBuild: Int? = nil
        var lastSeenBuild: Int? = nil
        var priorSetupKey = false
        /// `cos.keyLanes.install` as it stood at launch, before this launch's status read.
        var keyLanesInstall: String? = nil
        var runtimeFolder = false
        var updaterRecord = false
    }

    /// Step 1, at launch. A kept answer always wins. nil: no sign of an earlier Control, so wait for KeyLanes.
    static func decideAtLaunch(_ evidence: Evidence) -> Cohort? {
        if let stored = evidence.stored, let cohort = Cohort(rawValue: stored) { return cohort }
        guard let running = evidence.runningBuild, running > 0 else { return .existing }
        if evidence.keyLanesInstall != nil { return .existing }
        if let seen = evidence.lastSeenBuild, seen != running { return .existing }
        if evidence.priorSetupKey || evidence.runtimeFolder || evidence.updaterRecord { return .existing }
        return nil
    }

    /// Step 2, when KeyLanes decides on this launch. Returns the answer to keep, or nil to keep nothing (one is kept
    /// already, or KeyLanes has not decided, or it said something this build cannot read).
    static func adopt(stored: String?, keyLanes: String?) -> Cohort? {
        if let stored, Cohort(rawValue: stored) != nil { return nil }
        guard let keyLanes else { return nil }
        return Cohort(rawValue: keyLanes)
    }

    /// The kept answer. Undecided reads as existing, so nothing changes for anyone until the Mac is known to be new.
    static func current(_ defaults: UserDefaults = .standard) -> Cohort {
        defaults.string(forKey: key).flatMap(Cohort.init(rawValue:)) ?? .existing
    }
    /// True only for a Mac kept as "new". D2 (Settings Basic view) and the Today home default read this.
    static var isNewInstall: Bool { current() == .new }

    // MARK: Writers (the shipped app only)

    /// Called once at launch (ControlSetup.swift, SetupWindowPresenter's init). Keeps "existing" at once on any sign of
    /// an earlier Control; otherwise keeps nothing yet.
    @discardableResult
    static func decideAtLaunch(defaults: UserDefaults = .standard) -> Cohort? {
        guard isShippedApp else { return nil }
        guard let cohort = decideAtLaunch(liveEvidence(defaults: defaults)) else { return nil }
        if defaults.string(forKey: key) != cohort.rawValue { defaults.set(cohort.rawValue, forKey: key) }
        return cohort
    }

    /// Called when KeyLanes' answer changes (ControlSetup.swift observes KeyLanesStore.shared.$install).
    static func adoptKeyLanes(_ keyLanes: String?, defaults: UserDefaults = .standard) {
        guard isShippedApp, let cohort = adopt(stored: defaults.string(forKey: key), keyLanes: keyLanes) else { return }
        defaults.set(cohort.rawValue, forKey: key)
    }

    // MARK: Live probes (read only; nothing here prompts)

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

/// A Bool setting whose default depends on the install cohort, read lazily: the person's own value when the key was ever
/// written, else `newInstall` on a Mac kept as new and `existing` everywhere else (undecided included). Nothing is
/// written until the person changes it. Re-reads when either key changes, so a cohort kept mid-launch shows at once.
///
///     @CohortDefault(TodayHome.enabledKey, newInstall: true) private var todayEnabled
@propertyWrapper
struct CohortDefault: DynamicProperty {
    @AppStorage private var stored: Bool?
    @AppStorage(InstallCohort.key) private var cohort: String?
    private let newInstall: Bool
    private let existing: Bool

    init(_ key: String, newInstall: Bool, existing: Bool = false) {
        _stored = AppStorage(key)
        self.newInstall = newInstall
        self.existing = existing
    }

    /// The rule, pure (Tests/InstallCohortChecks.swift).
    nonisolated static func value(stored: Bool?, cohort: String?, newInstall: Bool, existing: Bool) -> Bool {
        stored ?? (cohort == InstallCohort.Cohort.new.rawValue ? newInstall : existing)
    }

    var wrappedValue: Bool {
        get { Self.value(stored: stored, cohort: cohort, newInstall: newInstall, existing: existing) }
        nonmutating set { stored = newValue }
    }
    var projectedValue: Binding<Bool> { Binding(get: { wrappedValue }, set: { wrappedValue = $0 }) }
}
