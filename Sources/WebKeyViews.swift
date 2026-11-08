import AppKit
import SwiftUI

// Phone approvals in Settings (Glasses and iPhone, Devices, under Open COS on your phone). Drawn only while the server says
// COS_WEB_KEY_AUTHORITY is on (WebKeyState.visible); with the flag off this view is zero height and asks the server one
// status question when it appears. Rules and state live in Sources/WebKeyCore.swift.
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
                if state.anchorRegisteredHere {
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
    static let copyPin = "Copy pin"
    static let enrollTitle = "Enroll a phone"
    static let nothingPending = "Start enrollment on your phone. The request shows here."
    static let typeCode = "Type the 6-digit code your phone shows. Check the key below matches your phone too."
    static let approve = "Approve with Touch ID"
    static let checkAgain = "Check again"
    static let keysTitle = "Enrolled phones"
    static let revoke = "Revoke"
    static let revokeAll = "Revoke all…"
}

private struct WebKeyLine: View {
    let label: String
    let value: String
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(COSType.body(12)).foregroundStyle(TodayInk.sub).frame(width: 74, alignment: .leading)
            Text(value).font(mono ? COSType.mono(12) : COSType.body(12.5)).foregroundStyle(TodayInk.ink)
                .lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

private struct WebKeyAnchorSection: View {
    @ObservedObject var state: WebKeyState
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(WebKeyCopy.title).font(COSType.body(14.5, weight: .semibold)).foregroundStyle(TodayInk.ink)
                Text(WebKeyCopy.subtitle).font(COSType.body(13)).foregroundStyle(TodayInk.sub).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            if let fingerprint = state.anchorFingerprint {
                WebKeyLine(label: "This Mac", value: fingerprint, mono: true)
            }
            if state.foreignAnchor {
                Text(WebKeyCopy.foreign).font(COSType.body(12)).foregroundStyle(COSPalette.amber).fixedSize(horizontal: false, vertical: true)
            }
            if state.anchorRegisteredHere && !state.anchorMature {
                Text(WebKeyCopy.young).font(COSType.body(12)).foregroundStyle(TodayInk.sub)
            }
            HStack(spacing: 14) {
                if !state.anchorRegisteredHere {
                    Button(state.anchorFingerprint == nil ? WebKeyCopy.create : WebKeyCopy.register) { state.startRegistration() }
                        .buttonStyle(TodayButtonStyle(small: true))
                        .disabled(state.busy)
                }
                if state.anchorRegisteredHere && state.recoveryRequired {
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
                Text(WebKeyCopy.pinNote).font(COSType.body(10.5)).foregroundStyle(COSPalette.muted).fixedSize(horizontal: false, vertical: true)
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
