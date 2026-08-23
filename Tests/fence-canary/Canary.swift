import SwiftUI
import AppKit

// Fence-dialog canary. Run: Tests/fence-canary/run.sh
//
// Puts every confirmation presentation COS Control uses side by side in a real
// MenuBarExtra(.window) popover and logs a breadcrumb at each step. This exists
// because Tests/run.sh is grep-over-source and CANNOT observe whether a button
// action is ever entered -- which is how nine dead destructive buttons shipped.
//
// Result 2026-08-23 (Miles, on-device):
//   A  .confirmationDialog + @State   Release NEVER fired; only Cancel dismissed
//   B  .confirmationDialog + model    Release NEVER fired; setter ran TWICE
//   C  hand-rolled inline overlay     fired every time
//   D  .alert + plain button          <- still in Views.swift:178, untested
//   E  the SHIPPED cosConfirm         must fire, or the fix is not a fix

let logURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cos-canary", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("fence-canary.log")
}()

nonisolated func canaryLog(_ line: String) {
    let row = "\(ISO8601DateFormatter().string(from: Date()))  \(line)\n"
    guard let data = row.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else {
        try? data.write(to: logURL)
    }
}

@MainActor
final class CanaryModel: ObservableObject {
    @Published var pending: String?
    func ask(_ t: String) { pending = t; canaryLog("B  ask() -> pending=\(t)") }
    func cancelFromSetter() {
        canaryLog("B  isPresented SETTER fired (pending was \(pending ?? "nil"))")
        pending = nil
    }
    func release(_ t: String) { canaryLog("B  release() RAN target=\(t)") }
}

struct CanaryPanel: View {
    @ObservedObject var model: CanaryModel
    @State private var confirmA = false
    @State private var inlineC: String?
    @State private var alertD = false
    @State private var confirmE = false
    @State private var eTarget = "target-E"

    private var eActions: [COSConfirmAction] {
        let captured = eTarget
        return [
            .destructive("Release") { canaryLog("E  ACTION FIRED captured=\(captured)") },
            .cancel { canaryLog("E  cancel tapped") },
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fence dialog canary").font(.system(size: 15, weight: .semibold))
            Text("Click each, then its Release / primary button.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            Button("A · confirmationDialog + @State") { canaryLog("A  button tapped"); confirmA = true }
            Button("B · confirmationDialog + model") { canaryLog("B  button tapped"); model.ask("target-B") }
            Button("C · hand-rolled inline overlay") { canaryLog("C  button tapped"); inlineC = "target-C" }
            Button("D · .alert + plain button") { canaryLog("D  button tapped"); alertD = true }
            Button("E · SHIPPED cosConfirm  ← the fix") { canaryLog("E  button tapped"); confirmE = true }

            Divider()
            Text("~/.cos-canary/fence-canary.log")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 390, height: 360)
        .confirmationDialog("Release A?", isPresented: $confirmA, titleVisibility: .visible) {
            Button("Release", role: .destructive) { canaryLog("A  ACTION FIRED") }
            Button("Cancel", role: .cancel) { canaryLog("A  cancel tapped") }
        } message: { Text("@State-bound dialog") }
        .confirmationDialog(
            "Release B?",
            isPresented: Binding(get: { model.pending != nil },
                                 set: { if !$0 { model.cancelFromSetter() } }),
            titleVisibility: .visible
        ) {
            Button("Release", role: .destructive) {
                canaryLog("B  ACTION FIRED (entered)")
                guard let p = model.pending else { canaryLog("B  GUARD FAILED"); return }
                model.release(p)
            }
            Button("Cancel", role: .cancel) { model.cancelFromSetter() }
        } message: { Text("model-bound dialog") }
        .alert("Alert D?", isPresented: $alertD) {
            Button("Primary") { canaryLog("D  ACTION FIRED") }
            Button("Cancel", role: .cancel) { canaryLog("D  cancel tapped") }
        } message: { Text(".alert with a plain button — still used at Views.swift:178") }
        .cosConfirm("Release E?", isPresented: $confirmE,
                    message: "the shipped component", actions: eActions)
        .overlay {
            if let target = inlineC {
                ZStack {
                    Color.black.opacity(0.45)
                    VStack(spacing: 12) {
                        Text("Release C?").font(.system(size: 14, weight: .semibold))
                        HStack {
                            Button("Cancel") { canaryLog("C  cancel tapped"); inlineC = nil }
                            Button("Release") {
                                canaryLog("C  ACTION FIRED captured=\(target)"); inlineC = nil
                            }
                        }
                    }
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
                }
            }
        }
    }
}

@main
struct CanaryApp: App {
    @StateObject private var model = CanaryModel()
    var body: some Scene {
        MenuBarExtra("Canary", systemImage: "testtube.2") { CanaryPanel(model: model) }
            .menuBarExtraStyle(.window)
    }
}
