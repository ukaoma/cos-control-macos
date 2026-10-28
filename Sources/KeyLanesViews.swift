import AppKit
import SwiftUI

// Key lanes in COS Control (K1 P10): the Settings row, the key setup it opens, and the optional setup step. The words
// and every decision are in Sources/KeyLanes.swift. None of these views draws anything for a server before 6.80.0 that
// has not said lanes are on, on a Mac that never saved a key (plan 3, the K0 golden replay).

private func keyLanesRun(_ model: ControllerModel) -> KeyLanesStore.Run {
    { arguments, input in try await model.runHelper(arguments, timeout: 40, stdinData: input) }
}

/// The CLIs a key profile runs in (QA U10): Connect your AI's report, or the server's own readiness.
@MainActor private func installed(_ model: ControllerModel) -> (claude: Bool, codex: Bool) {
    let report = model.providerGuide.report
    return (report?.status(.claude)?.installed == true || model.status.claudeCliReady == true,
            report?.status(.codex)?.installed == true || model.status.codexCliReady == true)
}

/// Settings: "Answer with your own key". Off by default; turning it on calls the server's enable door, then the key
/// setup opens in place. Mounted once in the panel's settings (Sources/Views.swift).
struct KeyLanesSettingsRow: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var store: KeyLanesStore = .shared
    /// Settings hub: the card's rows (`.main`) or its Advanced rows (`.advanced`: KL-02, KL-03, KL-14, KL-15). Panel: `.all`.
    var part: KeyLanesSettingsPart = .all
    @Environment(\.settingsHubHosted) private var hosted
    @State private var removingSaved = false

    var body: some View {
        if KeyLanes.rowVisible(serverVersion: model.status.version, enabled: store.enabled, savedKeys: store.savedKeys) || store.blockedInstall != nil {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            if part != .advanced, hosted {
                // Settings hub: the switch as a row, its line as the description.
                SettingsHubRow(label: KeyLanes.rowTitle, detail: store.enabled ? KeyLanes.onLine : KeyLanes.offLine) {
                    if store.enabled || KeyLanes.serverSupports(model.status.version) {
                        SettingsHubSwitch(label: KeyLanes.rowTitle, isOn: Binding(
                            get: { store.enabled },
                            set: { on in Task { if on { await store.enable(run: keyLanesRun(model)) } else { await store.disable(run: keyLanesRun(model)) } } }))
                            .disabled(store.busy)
                    }
                }
            } else if part != .advanced, store.enabled || KeyLanes.serverSupports(model.status.version) {
                Toggle(KeyLanes.rowTitle, isOn: Binding(
                    get: { store.enabled },
                    set: { on in Task { if on { await store.enable(run: keyLanesRun(model)) } else { await store.disable(run: keyLanesRun(model)) } } }))
                    .toggleStyle(COSSwitchStyle())
                    .font(COSType.body(13, weight: .semibold))
                    .disabled(store.busy)
                    .accessibilityIdentifier("settings-key-lanes")
                Text(store.enabled ? KeyLanes.onLine : KeyLanes.offLine).font(COSType.body(11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if part != .advanced {
                Text(KeyLanes.rowTitle).font(COSType.body(13, weight: .semibold))
            }
            if part != .main, store.blockedInstall != nil {
                // The server downgrade journey: an install below 6.80.0 waits for the keys to go.
                Text(KeyLanes.downgradeLine).font(COSType.body(11, weight: .medium))
                    .foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
                Button(KeyLanes.removeAndContinueLabel) { removingSaved = true }
                    .buttonStyle(COSQuietButtonStyle(tone: .destructive)).disabled(store.busy || model.busy)
            }
            if store.enabled {
                KeyLanesSetupPanel(model: model, store: store, part: part)
                    .padding(.horizontal, hosted ? 20 : 0).padding(.vertical, hosted ? 12 : 0)
            } else {
                if part != .main, KeyLanes.savedKeysRowVisible(enabled: store.enabled, savedKeys: store.savedKeys) && store.blockedInstall == nil {
                    Text(KeyLanes.savedKeysLine(serverVersion: model.status.version)).font(COSType.body(11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(KeyLanes.removeSavedLabel) { removingSaved = true }
                        .buttonStyle(COSQuietButtonStyle(tone: .destructive)).disabled(store.busy)
                }
                if part != .advanced, let line = store.line {
                    Text(line).font(COSType.body(11)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // Settings hub: Advanced's own lines sit at the rows' inset.
        .padding(.horizontal, hosted && part == .advanced ? 20 : 0).padding(.vertical, hosted && part == .advanced ? 12 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsPanelCard()
        .cosConfirm("\(KeyLanes.removeSavedLabel)?", isPresented: $removingSaved, message: KeyLanes.removeSavedMessage, actions: [
            .destructive(KeyLanes.removeSavedLabel) {
                Task {
                    await store.removeSavedKeys(run: keyLanesRun(model))
                    if let install = store.takeBlockedInstall() { model.perform(install[0], arguments: Array(install.dropFirst())) }
                }
            },
            .cancel(),
        ])
        .id("key-lanes")
        .task(id: "\(model.status.running) \(model.status.version ?? "")") {
            // Fixtures and previews read nothing; an older server has no key-lane routes to read. The hub's Advanced part
            // reads nothing either: its main part already does, once.
            guard part != .advanced, model.backgroundWorkEnabled, store.enabled || KeyLanes.serverSupports(model.status.version) else { return }
            store.observe(model.status)
            await store.refresh(run: keyLanesRun(model))
            if store.enabled, store.catalog.isEmpty { await store.loadCatalog(run: keyLanesRun(model)) }
        }
    }
}

/// Keys, the model, the cap, Reset pause, Use for answers, Remove and Remove all keys. Every recovery is a button
/// (plan 10.1): no terminal.
struct KeyLanesSetupPanel: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var store: KeyLanesStore
    /// Settings hub: `.main` leaves out Remove all keys and the ledger switch, `.advanced` shows only them. Panel: `.all`.
    var part: KeyLanesSettingsPart = .all
    @State private var chosenKind: String?
    /// The pasted key, held only until Save key; never drawn (KeyLanes.pendingLine shows kind and last four).
    @State private var pending: String?
    @State private var capText = KeyLanes.capArgument(KeyLanes.defaultCapUsd)
    @State private var removing: String?
    @State private var removingAll = false
    @State private var exportLedger = true
    @State private var capEdits: [String: String] = [:]

    private var kinds: [String] {
        let cli = installed(model)
        return KeyLanes.offeredKinds(store.catalog, claudeInstalled: cli.claude, codexInstalled: cli.codex)
    }
    private var kind: String { chosenKind.flatMap { kinds.contains($0) ? $0 : nil } ?? kinds.first ?? "openrouter" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if part != .advanced { mainRows }
            if part != .main, store.hasKey { removeAllRows }
        }
    }

    @ViewBuilder private var mainRows: some View {
            if let local = KeyLanes.localFirstLine(claudeReady: model.status.claudeCliReady, codexReady: model.status.codexCliReady,
                                                   ollamaReady: model.status.ollamaReady == true) {
                Text(local).font(COSType.body(11)).foregroundStyle(.secondary)
            }
            ForEach(store.state?.keys ?? []) { key in keyRow(key) }
            if let label = store.justSaved {
                Text(KeyLanes.glassesHint(label)).font(COSType.body(11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }
            if !store.catalog.isEmpty && kinds.isEmpty {
                Text(KeyLanes.noEngineLine).font(COSType.body(11)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            } else if !kinds.isEmpty {
                addKey
            }
            if let line = store.line {
                Text(line).font(COSType.body(11)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            }
    }

    /// KL-14 and KL-15: Remove all keys, after the downgrade note, and whether to save the spend ledger first.
    @ViewBuilder private var removeAllRows: some View {
                VStack(alignment: .leading, spacing: 2) {
                    Text(KeyLanes.downgradeHeading).font(COSType.body(11, weight: .medium))
                    Text(KeyLanes.downgradeLine).font(COSType.body(11)).foregroundStyle(.secondary)
                }
                Button(KeyLanes.removeAllLabel) { removingAll = true }
                    .buttonStyle(COSQuietButtonStyle(tone: .destructive))
                    .disabled(store.busy)
                    .cosConfirm("\(KeyLanes.removeAllLabel)?", isPresented: $removingAll, message: KeyLanes.removeAllMessage, actions: [
                        .destructive(KeyLanes.removeAllLabel) { Task { await store.removeAll(exportLedger: exportLedger, run: keyLanesRun(model)) } },
                        .cancel(),
                    ])
                Toggle(KeyLanes.exportLedgerLabel, isOn: $exportLedger).toggleStyle(COSSwitchStyle()).font(COSType.body(11))
    }

    private func keyRow(_ key: KeyLanesKey) -> some View {
        let profile = store.state?.profiles.first { $0.id == KeyLanes.profileID(forKey: key.ref) }
        let cli = installed(model)
        let usable = KeyLanes.usableModels(store.catalog, kind: key.kind, claudeInstalled: cli.claude, codexInstalled: cli.codex)
        return VStack(alignment: .leading, spacing: 6) {
            Text(KeyLanes.keyLine(kind: key.kind, last4: key.last4)).font(COSType.body(12, weight: .semibold))
            Text(KeyLanes.capLine(key)).font(COSType.body(11)).foregroundStyle(.secondary)
            if KeyLanes.providerLimitApplies(key.kind) {
                Text(KeyLanes.noProviderLimitLine).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if key.breakerOpen {
                HStack(spacing: 8) {
                    Text(KeyLanes.breakerLine).font(COSType.body(11)).foregroundStyle(COSPalette.amber)
                    Button(KeyLanes.resetBreakerLabel) { Task { await store.resetBreaker(key.ref, run: keyLanesRun(model)) } }
                        .buttonStyle(COSQuietButtonStyle()).disabled(store.busy)
                }
            }
            if !usable.isEmpty {
                COSDropdown(KeyLanes.modelLabelTitle, selection: Binding(
                    get: { usable.first { KeyLanes.profileModel(slug: $0.id, kind: key.kind) == profile?.model }?.id ?? "" },
                    set: { slug in Task { await store.chooseModel(slug, keyRef: key.ref, kind: key.kind, run: keyLanesRun(model)) } }),
                    options: [COSDropdownOption("", "Choose a model", placeholder: true)] + usable.map { COSDropdownOption($0.id, KeyLanes.priceLine($0)) })
            } else {
                Text(store.catalog.isEmpty ? KeyLanes.noModelsLine : KeyLanes.noEngineLine).font(COSType.body(11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let profile {
                Toggle(KeyLanes.profileToggleLabel, isOn: Binding(get: { profile.enabled },
                                                                  set: { on in Task { await store.setProfileEnabled(profile, on, run: keyLanesRun(model)) } }))
                    .toggleStyle(COSSwitchStyle()).font(COSType.body(11)).disabled(store.busy)
            }
            HStack(spacing: 8) {
                TextField(KeyLanes.capLabel, text: Binding(get: { capEdits[key.ref] ?? KeyLanes.capArgument(key.capUsd) },
                                                         set: { capEdits[key.ref] = $0 }))
                    .textFieldStyle(.plain).cosField()
                    .frame(width: 80)
                Button("Set cap") {
                    guard let cap = KeyLanes.parseCap(capEdits[key.ref] ?? "") else { store.line = "A daily cap is between $0.01 and $1000."; return }
                    Task { await store.setCap(cap, keyRef: key.ref, run: keyLanesRun(model)); capEdits[key.ref] = nil }
                }
                .buttonStyle(COSQuietButtonStyle()).disabled(store.busy || capEdits[key.ref] == nil)
                Spacer(minLength: 8)
                Button(KeyLanes.removeLabel) { removing = key.ref }
                    .buttonStyle(COSQuietButtonStyle(tone: .destructive)).disabled(store.busy)
            }
            .cosConfirm("Remove this key?", isPresented: Binding(get: { removing == key.ref }, set: { if !$0 { removing = nil } }),
                        message: "\(KeyLanes.keyLine(kind: key.kind, last4: key.last4)) and its key profile are deleted from this Mac.",
                        actions: [
                            .destructive(KeyLanes.removeLabel) { Task { await store.removeKey(key.ref, run: keyLanesRun(model)) } },
                            .cancel(),
                        ])
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line, lineWidth: 1))
    }

    private var addKey: some View {
        VStack(alignment: .leading, spacing: 6) {
            COSDropdown("Key from", selection: Binding(get: { kind }, set: { chosenKind = $0 }),
                        options: kinds.map { COSDropdownOption($0, KeyLanes.kindTitles[$0] ?? $0) })
            HStack(spacing: 8) {
                Button(KeyLanes.pasteLabel) {
                    let board = NSPasteboard.general
                    let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if text.isEmpty { pending = nil; store.line = KeyLanes.emptyPaste; return }
                    pending = text; store.line = nil
                    // QA N9: the clipboard keeps no copy, unless something else replaced it meanwhile.
                    if board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == text { board.clearContents() }
                }
                .buttonStyle(COSQuietButtonStyle())
                Text("Cap $").font(COSType.body(11)).foregroundStyle(.secondary)
                TextField(KeyLanes.capLabel, text: $capText).textFieldStyle(.plain).cosField().frame(width: 64)
                Button(KeyLanes.saveLabel) {
                    guard let secret = pending else { return }
                    guard let cap = KeyLanes.parseCap(capText) else { store.line = "A daily cap is between $0.01 and $1000."; return }
                    pending = nil
                    let cli = installed(model), chosen = kind
                    Task { await store.saveKey(kind: chosen, secret: secret, capUsd: cap, claudeInstalled: cli.claude, codexInstalled: cli.codex, run: keyLanesRun(model)) }
                }
                .buttonStyle(COSPrimaryButtonStyle()).disabled(pending == nil || store.busy)
            }
            Text(pending.map { KeyLanes.pendingLine(kind: kind, secret: $0) } ?? KeyLanes.pasteHint)
                .font(COSType.body(11)).foregroundStyle(.secondary)
            Text(KeyLanes.sameMacLine).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if KeyLanes.providerLimitApplies(kind) {
                Text(KeyLanes.noProviderLimitLine).font(COSType.body(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Setup's optional step (plan 10.1, D12): after local setup, on a NEW install or once lanes are on. Skip is the
/// default and sends nothing to the server.
struct KeyLanesSetupStep: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var store: KeyLanesStore = .shared
    @State private var adding = false

    var body: some View {
        if KeyLanes.setupStepVisible(install: store.install, serverVersion: model.status.version, enabled: store.enabled,
                                     skipped: store.setupSkipped, hasKey: store.hasKey) || adding {
            VStack(alignment: .leading, spacing: 10) {
                Text(KeyLanes.setupTitle).font(COSType.body(15, weight: .semibold))
                Text(KeyLanes.setupDetail(kinds: offered)).font(COSType.body(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let local = KeyLanes.localFirstLine(claudeReady: model.status.claudeCliReady, codexReady: model.status.codexCliReady,
                                                       ollamaReady: model.status.ollamaReady == true) {
                    Text(local).font(COSType.body(13)).foregroundStyle(.secondary)
                }
                if adding && store.enabled {
                    KeyLanesSetupPanel(model: model, store: store)
                } else {
                    if let line = store.line { Text(line).font(COSType.body(12)).foregroundStyle(COSPalette.amber) }
                    HStack(spacing: 14) {
                        Button(KeyLanes.skipLabel) { adding = false; store.skipSetup() }.buttonStyle(COSQuietButtonStyle())
                        Button(KeyLanes.addLabel) { adding = true; Task { await store.enable(run: keyLanesRun(model)) } }
                            .buttonStyle(COSTextButtonStyle()).disabled(store.busy)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Before lanes are on the catalog is unknown: the curated K1 models are Claude models (OpenRouter or Anthropic).
    private var offered: [String] {
        let cli = installed(model)
        let kinds = KeyLanes.offeredKinds(store.catalog, claudeInstalled: cli.claude, codexInstalled: cli.codex)
        return store.catalog.isEmpty ? ["openrouter", "anthropic"] : kinds
    }
}

/// Decides new or existing install on the first known status (KeyLanes.classifyInstall). Draws nothing; it sits in
/// the setup window's background so it never takes a place in a layout.
struct KeyLanesInstallLatch: View {
    @ObservedObject var model: ControllerModel
    var body: some View {
        Color.clear
            .task(id: "\(model.status.runtimeState) \(model.status.needsFirstRun)") { KeyLanesStore.shared.observe(model.status) }
    }
}
