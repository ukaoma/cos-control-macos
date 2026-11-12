import AppKit
import SwiftUI

// Phone approvals in Settings (Glasses and iPhone, Devices, under Open COS on your phone). Drawn only while the server says
// COS_WEB_KEY_AUTHORITY is on, or (0.5.383, server 7.0.9) COS_WEB_KEY_ANCHOR_BOOTSTRAP is on with authority off
// (WebKeyState.visible). Bootstrap draws the Mac anchor alone: no enrollment, no code, no approval, no key list. With both
// off this view is zero height and asks the server one status question when it appears. Rules and state live in
// Sources/WebKeyCore.swift.
//
// The enrollment card draws ONLY a WebKeyApprovalCard, which WebKeyApprovalCheck builds from the approvalJcs bytes the
// anchor signs (review W4). It never draws the 6-digit code: Miles types the code his phone shows (review W6), and Touch
// ID names it in the system sheet. Tests/web-key-pins.py holds this file to that.

struct WebKeySettingsBlock: View {
    @ObservedObject var state: WebKeyState
    /// Off in offscreen renders.
    var refreshes = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state.visible {
                SettingsHubBlock { WebKeyAnchorSection(state: state) }
                if state.authority && state.anchorRegisteredHere {
                    SettingsHubBlock { WebKeyEnrollmentSection(state: state) }
                    if !state.keys.isEmpty { SettingsHubBlock { WebKeyKeysSection(state: state) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: refreshes) { if refreshes { await state.refresh() } }
        .onDisappear { state.cancelActions() }
    }
}

enum WebKeyCopy {
    static let title = "Phone approvals"
    static let subtitle = "Approve agent actions from your iPhone with its passkey and Face ID. Touch ID on this Mac enrolls the phone."
    static let create = "Create key with Touch ID"
    static let register = "Register with Touch ID"
    static let foreign = "The server holds an approval key this Mac did not make. Registering this Mac's key replaces it and revokes every phone key."
    static let young = "A new key approves nothing for 24 hours."
    static let pinNote = "Commit the pin yourself as operations/scripts/web_key_anchor.json. Control never writes the repo."
    // 0.5.383 bootstrap (registration only).
    static let bootstrapSubtitle = "Registration only. Register this Mac's Touch ID key now so its 24 hour clock starts. Phone enrollment and approvals stay off on the COS server."
    static let bootstrapPinNote = "Copy the pin and commit it by hand as operations/scripts/web_key_anchor.json in the receiver's checkout. Control never writes or commits it."
    static let keyHash = "Key hash"
    static let replace = "Replace with Touch ID…"
    static let replaceMessage = "The server holds an approval key this Mac did not make. Replacing it registers this Mac's key, revokes every phone key and starts a new 24 hour clock. Commit the new pin by hand."
    static let registeredAt = "Registered"
    static let copyPin = "Copy pin"
    static let enrollTitle = "Enroll a phone"
    static let nothingPending = "Start enrollment on your phone. The request shows here."
    static let typeCode = "Type the 6-digit code your phone shows. Check the key below matches your phone too."
    static let approve = "Approve with Touch ID"
    static let checkAgain = "Check again"
    static let keysTitle = "Enrolled phones"
    static let revoke = "Revoke"
    static let revokeAll = "Revoke all…"

    /// The server's setAt as a local date and time, then the raw milliseconds as the server's record holds them.
    static func setAtLine(_ ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return date.formatted(date: .abbreviated, time: .standard) + ", setAt \(ms)"
    }
}

private struct WebKeyLine: View {
    let label: String
    let value: String
    var mono = false
    var lines = 2
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(COSType.body(12)).foregroundStyle(TodayInk.sub).frame(width: 74, alignment: .leading)
            Text(value).font(mono ? COSType.mono(12) : COSType.body(12.5)).foregroundStyle(TodayInk.ink)
                .lineLimit(lines).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

/// Option A (lead 2026-11-11 21:31): Settings PK-02, "Turn on phone approvals", in full Settings only (never Basic; the
/// mount checks hubRowDrawn and PK-02 is not a basic row). Off by default: the toggle itself never applies anything.
/// Turning it on shows this account's iPhones (Tailscale) and a confirmation that names the phone and says the Mac's name
/// becomes public in certificate logs; turning it off asks too. Either way the helper restarts the server through the
/// managed path, and the Phone approvals block below shows the amber certificate line until the certificate is ready.
/// Like the nine restart rows (RestartApply, Settings Release A), nothing applies while work runs or another change is in
/// progress: the row says it waits instead (PhoneApprovalsSwitch.applyAllowed).
struct PhoneApprovalsSwitchRow: View {
    @ObservedObject var model: ControllerModel
    @ObservedObject var state: WebKeyState
    @ObservedObject var pairing: GlassesPairingState
    /// The panel's restartWork and serverSettingsLocked, the same two the nine restart rows read.
    let work: RestartApply.Work
    let locked: Bool
    @State private var choosing = false
    @State private var picked: PhoneApprovalsSwitch.Phone?
    @State private var confirmOn = false
    @State private var confirmOff = false
    /// A turn-on found running work: the row says it waits.
    @State private var held = false
    /// Option A: Off's saved wait (PhoneApprovalsOff), read from UserDefaults when the row appears.
    @State private var pendingOff: PhoneApprovalsPendingOff?
    /// The helper is running Off's =0 restart; when it finishes, a proved restart clears the wait.
    @State private var applyingOff = false
    private var pendingStore: DefaultsPhoneApprovalsPendingStore { DefaultsPhoneApprovalsPendingStore() }

    private var on: Bool { PhoneApprovalsSwitch.isOn(state.mode) }
    private var phones: [PhoneApprovalsSwitch.Phone] {
        PhoneApprovalsSwitch.phones((pairing.tailscale?.peers ?? []).map {
            PhoneApprovalsSwitch.Peer(os: $0.os, dns: $0.dns, ipv4: $0.ipv4, sameUser: $0.sameUser)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(PhoneApprovalsSwitch.label).font(COSType.body(13.5, weight: .semibold)).foregroundStyle(TodayInk.ink)
                    Text(PhoneApprovalsSwitch.detail).font(COSType.body(12)).foregroundStyle(TodayInk.sub).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // The switch only opens a step: on asks for a phone, off asks to confirm. It never applies by itself.
                // Off never waits for running work (option A): its confirm removes every phone at once, and only the =0
                // restart after it waits. While that restart waits, the switch reads off and stays put.
                Toggle(PhoneApprovalsSwitch.label, isOn: Binding(get: { (on && pendingOff == nil) || choosing }, set: { wanted in
                    if wanted, !on {
                        choosing = true
                        Task { await pairing.refreshTailscale() }
                    } else if !wanted, on, pendingOff == nil {
                        confirmOff = true
                    } else if !wanted {
                        choosing = false; picked = nil; held = false
                    }
                }))
                .labelsHidden().toggleStyle(COSSwitchStyle()).disabled(locked || pendingOff != nil)
            }
            if choosing && !on {
                if phones.isEmpty {
                    Text(PhoneApprovalsSwitch.noPhone).font(COSType.body(12)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Phone", selection: $picked) {
                        Text("Choose a phone").tag(PhoneApprovalsSwitch.Phone?.none)
                        ForEach(phones, id: \.self) { phone in Text(phone.name).tag(Optional(phone)) }
                    }
                    .frame(maxWidth: 280, alignment: .leading)
                    Button(PhoneApprovalsSwitch.confirmOn) { confirmOn = true }
                        .buttonStyle(TodayButtonStyle(small: true))
                        .disabled(picked == nil || !PhoneApprovalsSwitch.applyAllowed(locked: locked, workActive: work.active))
                }
            }
            if let pendingOff {
                Text(PhoneApprovalsOff.line(pendingOff, waiting: !model.busy && !PhoneApprovalsSwitch.applyAllowed(locked: locked, workActive: work.active)))
                    .font(COSType.body(12)).foregroundStyle(pendingOff.revokedAll ? TodayInk.sub : COSPalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if work.active && (choosing || held) {
                Text(RestartApply.waitsForWork + (work.uploads > 0 ? " " + RestartApply.uploadOpen : ""))
                    .font(COSType.body(12)).foregroundStyle(TodayInk.sub).fixedSize(horizontal: false, vertical: true)
            }
            if model.busy, let progress = model.operationProgress {
                Text(progress).font(COSType.body(12)).foregroundStyle(TodayInk.sub).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cosConfirm(picked.map(PhoneApprovalsSwitch.confirmOnTitle) ?? PhoneApprovalsSwitch.label, isPresented: $confirmOn,
            message: picked.map { PhoneApprovalsSwitch.confirmOnMessage($0, macName: pairing.tailscale?.selfDNS) } ?? "",
            actions: [.normal(PhoneApprovalsSwitch.confirmOn) {
                if PhoneApprovalsSwitch.applyAllowed(locked: locked, workActive: work.active) { model.setPhoneApprovals(on: true, phone: picked) } else { held = true }
            }, .cancel()])
        .cosConfirm(PhoneApprovalsSwitch.confirmOffTitle, isPresented: $confirmOff, message: PhoneApprovalsSwitch.confirmOffMessage,
            actions: [.destructive(PhoneApprovalsSwitch.confirmOff) { turnOff() }, .cancel()])
        // After the helper's restart (or any other operation): read the server again, so On and the amber line follow it.
        .onChange(of: model.busy) { _, busy in
            guard !busy else { return }
            choosing = false; picked = nil
            if applyingOff {
                applyingOff = false
                PhoneApprovalsOff.finished(store: pendingStore, helperSucceeded: model.error == nil)
                pendingOff = pendingStore.load()
            }
            Task { await state.refresh() }
        }
        .onChange(of: work.active) { _, active in if !active { held = false; resumeOff() } }
        .onAppear { pendingOff = pendingStore.load(); resumeOff() }
    }

    /// Option A: Revoke all now, whatever work runs, then the =0 restart, which waits for running work.
    private func turnOff() {
        Task {
            pendingOff = await PhoneApprovalsOff.run(store: pendingStore, now: Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)),
                                                     revokeAll: { await state.revokeAll() }, locked: { locked }, workActive: { work.active },
                                                     apply: applyOff)
        }
    }

    private func resumeOff() {
        guard pendingOff != nil, !applyingOff else { return }
        PhoneApprovalsOff.resume(store: pendingStore, locked: locked, workActive: work.active, apply: applyOff)
    }

    private func applyOff() {
        applyingOff = true
        model.setPhoneApprovals(on: false, phone: nil)
    }

    /// Offscreen renders only (Tests/PhoneApprovalsRender.swift): the row opened on one step, as a click would leave it, with
    /// the model's background work off. Nothing here applies anything; the confirm's buttons are drawn, never pressed.
    enum FixtureStep { case choosing(PhoneApprovalsSwitch.Phone?), confirmOn(PhoneApprovalsSwitch.Phone), confirmOff }
    static func renderFixture(model: ControllerModel, state: WebKeyState, pairing: GlassesPairingState, work: RestartApply.Work = .init(),
                              step: FixtureStep) -> PhoneApprovalsSwitchRow {
        precondition(!model.backgroundWorkEnabled)
        var row = PhoneApprovalsSwitchRow(model: model, state: state, pairing: pairing, work: work, locked: false)
        switch step {
        case .choosing(let phone):
            row._choosing = State(initialValue: true); row._picked = State(initialValue: phone)
        case .confirmOn(let phone):
            row._choosing = State(initialValue: true); row._picked = State(initialValue: phone); row._confirmOn = State(initialValue: true)
        case .confirmOff:
            row._confirmOff = State(initialValue: true)
        }
        return row
    }
}

private struct WebKeyAnchorSection: View {
    @ObservedObject var state: WebKeyState
    @State private var confirmReset = false
    @State private var confirmReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(WebKeyCopy.title).font(COSType.body(14.5, weight: .semibold)).foregroundStyle(TodayInk.ink)
                Text(state.bootstrapOnly ? WebKeyCopy.bootstrapSubtitle : WebKeyCopy.subtitle).font(COSType.body(13)).foregroundStyle(TodayInk.sub).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            // 0.5.390: the server says the phone's HTTPS origin is not trusted yet (WebKeySignerTLS). Authority only.
            if state.authority, let line = state.signerTLSLine {
                Text(line).font(COSType.body(12)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            }
            // Server reopen: why a certificate pair placed by hand in the server's folder was refused. Authority only.
            if state.authority, let stored = state.signerTLSStoredLine {
                Text(stored).font(COSType.body(12)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            }
            if let fingerprint = state.anchorFingerprint {
                WebKeyLine(label: "This Mac", value: fingerprint, mono: true)
            }
            if state.bootstrapOnly, let sha = state.anchorSpkiSha256 {
                // The pin's spkiSha256 in full, to check against the pin and the server by another view.
                WebKeyLine(label: WebKeyCopy.keyHash, value: sha, mono: true, lines: 3)
            }
            if state.bootstrapOnly, state.anchorRegisteredHere, let at = state.anchorSetAt {
                WebKeyLine(label: WebKeyCopy.registeredAt, value: WebKeyCopy.setAtLine(at))
            }
            if state.foreignAnchor {
                Text(WebKeyCopy.foreign).font(COSType.body(12)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            }
            if state.anchorRegisteredHere && !state.anchorMature {
                Text(WebKeyCopy.young).font(COSType.body(12)).foregroundStyle(TodayInk.sub)
            }
            HStack(spacing: 14) {
                if !state.anchorRegisteredHere && !state.foreignAnchor {
                    Button(state.anchorFingerprint == nil ? WebKeyCopy.create : WebKeyCopy.register) { state.startRegistration() }
                        .buttonStyle(TodayButtonStyle(small: true))
                        .disabled(state.busy)
                }
                if state.foreignAnchor {
                    Button(WebKeyCopy.replace) { confirmReplace = true }
                        .buttonStyle(TodayButtonStyle(small: true))
                        .disabled(state.busy)
                }
                if state.authority && state.anchorRegisteredHere && state.recoveryRequired {
                    Button("Reset phone approvals…") { confirmReset = true }
                        .buttonStyle(COSTextButtonStyle()).disabled(state.busy)
                }
                if state.anchorRegisteredHere {
                    Button(WebKeyCopy.copyPin) {
                        guard let pin = state.pinJSON() else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pin, forType: .string)
                    }
                    .buttonStyle(COSTextButtonStyle())
                }
                Spacer(minLength: 0)
            }
            if state.anchorRegisteredHere {
                Text(state.bootstrapOnly ? WebKeyCopy.bootstrapPinNote : WebKeyCopy.pinNote).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
            }
            if let note = state.rollbackNote {
                Text(note).font(COSType.body(12)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            }
            if let message = state.message {
                Text(message).font(COSType.body(12)).foregroundStyle(TodayInk.sub).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cosConfirm("Reset phone approvals?", isPresented: $confirmReset,
            message: "Create a new Mac key with Touch ID and revoke every enrolled phone. Commit the new pin and wait 24 hours before phone approvals can work again.",
            actions: [.destructive("Reset with Touch ID") { state.startReset() }, .cancel()])
        .cosConfirm("Replace the approval key?", isPresented: $confirmReplace,
            message: WebKeyCopy.replaceMessage,
            actions: [.destructive("Replace with Touch ID") { state.startReplace() }, .cancel()])
    }
}

private struct WebKeyEnrollmentSection: View {
    @ObservedObject var state: WebKeyState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(WebKeyCopy.enrollTitle).font(COSType.body(13.5, weight: .semibold)).foregroundStyle(TodayInk.ink)
            if state.pendingWithoutAudit {
                // Review W9: no card at all unless the server's one PID owns the signer ports.
                Text(state.audit?.line ?? WebKeyListenerAudit.notGenuineLine).font(COSType.body(12)).foregroundStyle(COSPalette.amber)
                Button(WebKeyCopy.checkAgain) { Task { await state.runAudit(); await state.refresh() } }
                    .buttonStyle(COSTextButtonStyle()).disabled(state.busy)
            } else if let refusal = state.cardRefusal {
                Text(refusal.line).font(COSType.body(12)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            } else if let card = state.card {
                WebKeyEnrollmentCardView(state: state, card: card)
            } else {
                Text(WebKeyCopy.nothingPending).font(COSType.body(12)).foregroundStyle(TodayInk.sub)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The enrollment card: every value here is a WebKeyApprovalCard field, decoded from the bytes Touch ID signs.
private struct WebKeyEnrollmentCardView: View {
    @ObservedObject var state: WebKeyState
    let card: WebKeyApprovalCard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            WebKeyLine(label: "Device", value: card.label)
            WebKeyLine(label: "Address", value: card.remote, mono: true)
            if !card.userAgent.isEmpty { WebKeyLine(label: "Browser", value: card.userAgent) }
            WebKeyLine(label: "Key", value: card.fingerprint, mono: true)
            if card.rotates != nil { WebKeyLine(label: "Replaces", value: "the phone key it rotates") }
            Text(WebKeyCopy.typeCode).font(COSType.body(12)).foregroundStyle(TodayInk.sub).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                TextField("000 000", text: $state.typedCode)
                    .textFieldStyle(.plain)
                    .cosField()
                    .font(COSType.mono(14))
                    .frame(width: 110)
                    .accessibilityLabel("The code your phone shows")
                Button(WebKeyCopy.approve) { state.startApproval() }
                    .buttonStyle(COSPrimaryButtonStyle())
                    .disabled(!state.approveAllowed || state.busy)
                Spacer(minLength: 0)
            }
        }
    }
}

private struct WebKeyKeysSection: View {
    @ObservedObject var state: WebKeyState
    @State private var confirmRevokeAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(WebKeyCopy.keysTitle).font(COSType.body(13.5, weight: .semibold)).foregroundStyle(TodayInk.ink)
            ForEach(state.keys) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label).font(COSType.body(12.5)).foregroundStyle(TodayInk.ink).lineLimit(1)
                        Text(row.fingerprint).font(COSType.mono(11)).foregroundStyle(TodayInk.sub)
                    }
                    Spacer(minLength: 0)
                    if row.active {
                        Button(WebKeyCopy.revoke) { Task { await state.revoke(row.kid) } }.buttonStyle(COSTextButtonStyle()).disabled(state.busy)
                    } else {
                        Text(row.revokedAt == nil ? "Inactive" : "Revoked").font(COSType.body(11.5)).foregroundStyle(COSPalette.muted)
                    }
                }
            }
            Button(WebKeyCopy.revokeAll) { confirmRevokeAll = true }.buttonStyle(COSTextButtonStyle()).disabled(state.busy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cosConfirm(
            "Revoke every phone key?",
            isPresented: $confirmRevokeAll,
            message: "Every enrolled phone stops approving at once, and anything it signed and not yet used is void. Enroll a phone again with Touch ID.",
            actions: [
                .destructive("Revoke all") { Task { await state.revokeAll() } },
                .cancel(),
            ]
        )
    }
}
