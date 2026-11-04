import SwiftUI

/// Settings Release A (Miles, 2026-11-03): Return never confirms a destructive action. Compiled with the shipped
/// Sources/COSConfirm.swift and COSBrand.swift and the fence canary's palette stand-in (Tests/run-settings-a.sh).
/// Nothing is drawn.
@main struct ConfirmReturnChecks {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var passes = 0
    static func check(_ ok: Bool, _ what: String) {
        if ok { passes += 1 } else { failures += 1; print("FAIL: \(what)") }
    }

    @MainActor static func main() {
        let destroy = COSConfirmAction.destructive("Delete") {}
        let cancel = COSConfirmAction.cancel()
        let save = COSConfirmAction.normal("Save") {}
        let click = COSConfirmAction.clickOnly("Use") {}

        check(!destroy.takesReturn, "a destructive action does not take Return")
        check(COSConfirmAction.returnDefault(in: [destroy, cancel]) == nil, "Delete and Cancel: Return runs nothing")
        check(COSConfirmAction.returnDefault(in: [cancel, destroy]) == nil, "Cancel then Delete: Return runs nothing")
        check(COSConfirmAction.returnDefault(in: [destroy]) == nil, "Delete alone: Return runs nothing")
        check(COSConfirmAction.returnDefault(in: [save, destroy, cancel])?.id == save.id, "Save, Discard, Keep editing: Return saves")
        check(COSConfirmAction.returnDefault(in: [destroy, save])?.id == save.id, "a normal action still takes Return after a destructive one")
        check(COSConfirmAction.returnDefault(in: [click, cancel]) == nil, "a click-only action never takes Return")
        // Whatever the flag says, a destructive action is never the Return default.
        let flagged = COSConfirmAction(label: "Delete", kind: .destructive, takesReturn: true, run: {})
        check(COSConfirmAction.returnDefault(in: [flagged, cancel]) == nil, "a destructive action with the flag set is still not the Return default")
        check(COSConfirmAction.returnDefault(in: []) == nil, "no actions, no default")

        print(failures == 0 ? "confirm return checks: \(passes) passed" : "confirm return checks: \(failures) FAILED of \(passes + failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

// COSBrand.swift reads the hub's hosted flag, which lives with the hub's views; the checks only need the key.
private struct HubHostedStandIn: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var settingsHubHosted: Bool {
        get { self[HubHostedStandIn.self] }
        set { self[HubHostedStandIn.self] = newValue }
    }
}
