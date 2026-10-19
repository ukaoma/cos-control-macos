import AppKit
import SwiftUI

// Key lanes in COS Control (K1 P10): the Settings row, the key setup it opens, and the optional setup step. The words
// and every decision are in Sources/KeyLanes.swift. None of these views draws anything for a server before 6.80.0 that
// has not said lanes are on (plan 3, the K0 golden replay).

private func keyLanesRun(_ model: ControllerModel) -> KeyLanesStore.Run {
    { arguments, input in try await model.runHelper(arguments, timeout: 40, stdinData: input) }
}

/// Settings: "Answer with your own key". Off by default; turning it on calls the server's enable door, then the key
/// setup opens in place. Mounted once in the panel's settings (Sources/Views.swift).
struct KeyLanesSettingsRow: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var store: KeyLanesStore = .shared

    var body: some View {
        if KeyLanes.rowVisible(serverVersion: model.status.version, enabled: store.enabled) {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(KeyLanes.rowTitle, isOn: Binding(
                get: { store.enabled },
                set: { on in Task { if on { await store.enable(run: keyLanesRun(model)) } else { await store.disable(run: keyLanesRun(model)) } } }))
                .toggleStyle(COSSwitchStyle())
                .font(COSType.body(13, weight: .semibold))
                .disabled(store.busy)
                .accessibilityIdentifier("settings-key-lanes")
            Text(store.enabled ? KeyLanes.onLine : KeyLanes.offLine).font(COSType.body(11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if store.enabled {
                KeyLanesSetupPanel(model: model, store: store)
            } else if let line = store.line {
                Text(line).font(COSType.body(11)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .id("key-lanes")
        .task(id: "\(model.status.running) \(model.status.version ?? "")") {
            store.observe(model.status)
            await store.refresh(run: keyLanesRun(model))
            if store.enabled, store.catalog.isEmpty { await store.loadCatalog(run: keyLanesRun(model)) }
        }
    }
}

/// Keys, the model, the cap, Remove and Remove all keys. Every recovery is a button (plan 10.1): no terminal.
struct KeyLanesSetupPanel: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var store: KeyLanesStore
    @State private var kind = "openrouter"
    /// The pasted key, held only until Save key; never drawn (KeyLanes.pendingLine shows kind and last four).
    @State private var pending: String?
    @State private var capText = KeyLanes.capArgument(KeyLanes.defaultCapUsd)
    @State private var baseURL = ""
    @State private var removing: String?
    @State private var removingAll = false
    @State private var exportLedger = true
    @State private var capEdits: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let local = KeyLanes.localFirstLine(claudeReady: model.status.claudeCliReady, codexReady: model.status.codexCliReady,
                                                   ollamaReady: model.status.ollamaReady == true) {
                Text(local).font(COSType.body(11)).foregroundStyle(.secondary)
            }
            ForEach(store.state?.keys ?? []) { key in keyRow(key) }
            addKey
            if let line = store.line {
                Text(line).font(COSType.body(11)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            }
            if store.hasKey {
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
        }
    }

    private func keyRow(_ key: KeyLanesKey) -> some View {
        let profile = store.state?.profiles.first { $0.id == KeyLanes.profileID(forKey: key.ref) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(KeyLanes.keyLine(kind: key.kind, last4: key.last4)).font(COSType.body(12, weight: .semibold))
            Text(KeyLanes.capLine(key)).font(COSType.body(11)).foregroundStyle(.secondary)
            if key.breakerOpen { Text(KeyLanes.breakerLine).font(COSType.body(11)).foregroundStyle(COSPalette.amber) }
            if !store.catalog.isEmpty, KeyLanes.profileModel(slug: store.catalog[0].id, kind: key.kind) != nil {
                COSDropdown(KeyLanes.modelLabelTitle, selection: Binding(
                    get: { store.catalog.first { KeyLanes.profileModel(slug: $0.id, kind: key.kind) == profile?.model }?.id ?? "" },
                    set: { slug in Task { await store.chooseModel(slug, keyRef: key.ref, kind: key.kind, run: keyLanesRun(model)) } }),
                    options: [COSDropdownOption("", "Choose a model", placeholder: true)]
                        + store.catalog.map { COSDropdownOption($0.id, KeyLanes.priceLine($0)) })
            } else if store.catalog.isEmpty || profile == nil {
                Text(KeyLanes.noModelsLine).font(COSType.body(11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                TextField(KeyLanes.capLabel, text: Binding(get: { capEdits[key.ref] ?? KeyLanes.capArgument(key.capUsd) },
                                                         set: { capEdits[key.ref] = $0 }))
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
            COSDropdown("Key from", selection: $kind, options: KeyLanes.kindOrder.map { COSDropdownOption($0, KeyLanes.kindTitles[$0] ?? $0) })
            if kind == "openai-compatible" {
                TextField(KeyLanes.customURLLabel, text: $baseURL)
            }
            HStack(spacing: 8) {
                Button(KeyLanes.pasteLabel) {
                    let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if text.isEmpty { pending = nil; store.line = KeyLanes.emptyPaste } else { pending = text; store.line = nil }
                }
                .buttonStyle(COSQuietButtonStyle())
                Text("Cap $").font(COSType.body(11)).foregroundStyle(.secondary)
                TextField(KeyLanes.capLabel, text: $capText).frame(width: 64)
                Button(KeyLanes.saveLabel) {
                    guard let secret = pending else { return }
                    guard let cap = KeyLanes.parseCap(capText) else { store.line = "A daily cap is between $0.01 and $1000."; return }
                    pending = nil
                    Task { await store.saveKey(kind: kind, secret: secret, capUsd: cap, baseURL: kind == "openai-compatible" ? baseURL : nil, run: keyLanesRun(model)) }
                }
                .buttonStyle(COSPrimaryButtonStyle()).disabled(pending == nil || store.busy)
            }
            Text(pending.map { KeyLanes.pendingLine(kind: kind, secret: $0) } ?? KeyLanes.pasteHint)
                .font(COSType.body(11)).foregroundStyle(.secondary)
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
                Text(KeyLanes.setupDetail).font(COSType.body(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
