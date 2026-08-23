import SwiftUI

/// Inline confirmation for the menu-bar panel.
///
/// `.confirmationDialog` MUST NOT be used inside `MenuBarExtra(.window)`.
///
/// Proven on-device 2026-08-23 with `Tests/fence-canary`, which put three
/// presentations side by side in a real `MenuBarExtra(.window)` popover and
/// logged a breadcrumb at every step:
///
///   A  `.confirmationDialog` bound to `@State`   Release action NEVER ran
///   B  `.confirmationDialog` bound to model      Release action NEVER ran;
///                                                the `isPresented` setter ran
///                                                TWICE instead
///   C  inline overlay                            action ran, every time
///
/// A `role: .cancel` button DOES run, which is exactly why this shipped and
/// survived review: the dialog appeared, Cancel dismissed it, and the panel
/// looked healthy. Nine dialogs were wired that way and every destructive
/// action among them was inert -- Release fence, Reset live message count,
/// Clear stranded video uploads, Restart self-managed server, and Stop legacy
/// and install all did nothing when confirmed. The failure is invisible from
/// the outside: the sheet closes either way.
///
/// `Tests/run.sh` could not catch it. Its assertions are `grep` over source,
/// and a grep cannot observe whether a closure is ever entered. The canary is
/// the coverage; it compiles THIS file rather than a copy, so a regression here
/// fails there.
///
/// Do not "simplify" this back to `.confirmationDialog`.
struct COSConfirmAction: Identifiable {
    enum Kind { case normal, destructive, cancel }

    let id = UUID()
    let label: String
    let kind: Kind
    let run: @MainActor () -> Void

    static func normal(_ label: String, _ run: @escaping @MainActor () -> Void) -> COSConfirmAction {
        COSConfirmAction(label: label, kind: .normal, run: run)
    }

    static func destructive(_ label: String, _ run: @escaping @MainActor () -> Void) -> COSConfirmAction {
        COSConfirmAction(label: label, kind: .destructive, run: run)
    }

    static func cancel(_ label: String = "Cancel", _ run: @escaping @MainActor () -> Void = {}) -> COSConfirmAction {
        COSConfirmAction(label: label, kind: .cancel, run: run)
    }
}

private struct COSConfirmModifier: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let message: String
    let actions: [COSConfirmAction]

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack {
                    // Swallows clicks on the panel behind, so the confirmation is
                    // modal in the only sense that matters here. Clicking the scrim
                    // dismisses without running anything, matching Esc.
                    COSPalette.ink.opacity(0.55)
                        .onTapGesture { isPresented = false }

                    VStack(alignment: .leading, spacing: 9) {
                        Text(title)
                            .font(COSType.body(13).weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)

                        if !message.isEmpty {
                            Text(message)
                                .font(COSType.body(11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // Trailing-aligned and wrapping: the panel is 390pt wide and
                        // several of these carry three actions with long labels
                        // ("Stop legacy and install"), which would clip in an HStack.
                        HStack(spacing: 8) {
                            Spacer(minLength: 0)
                            ForEach(actions) { action in
                                Button(action.label) {
                                    // Dismiss FIRST, then run. Every call site captures
                                    // what it needs when the actions array is built, so
                                    // nothing here reads state the dismissal clears --
                                    // the fence release depends on that ordering.
                                    isPresented = false
                                    action.run()
                                }
                                .buttonStyle(.bordered)
                                .tint(action.kind == .destructive ? COSPalette.amber : nil)
                                .keyboardShortcut(action.kind == .cancel ? .cancelAction : nil)
                            }
                        }
                        .padding(.top, 2)
                    }
                    .padding(14)
                    .frame(maxWidth: 330, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(COSPalette.card))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(COSPalette.line, lineWidth: 1))
                    .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
                    .padding(.horizontal, 18)
                }
            }
        }
    }
}

extension View {
    /// Drop-in replacement for `.confirmationDialog` that actually runs its
    /// actions inside a `MenuBarExtra(.window)` panel. See `COSConfirmAction`.
    func cosConfirm(
        _ title: String,
        isPresented: Binding<Bool>,
        message: String,
        actions: [COSConfirmAction]
    ) -> some View {
        modifier(COSConfirmModifier(
            title: title,
            isPresented: isPresented,
            message: message,
            actions: actions
        ))
    }
}
