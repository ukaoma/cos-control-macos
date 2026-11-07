import Foundation

/// Focused real-store entry point. All transport is LensFixture; no providers, GUI, keychain or live server.
@main struct WorkWebMediaChecks {
    @MainActor static func main() async throws {
        // The existing store explicitly requires /tmp/ (not Foundation's /private/tmp/ alias) for fixture routing.
        let root = URL(fileURLWithPath: "/tmp/cos-work-web-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await runWorkLensPlansStoreChecks(root: root)
        print("PASS web Work media: retained before history, partial retry/reopen, immutable replay, selection preserved, removed copy refused")
    }
}
