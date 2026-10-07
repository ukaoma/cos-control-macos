import AppKit
import Foundation

@main @MainActor struct SessionOpenRecovery {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        precondition(NSHomeDirectory().contains("cos-session-open-test"))
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        let model = ControllerModel(startBackgroundWork: false, helper: HelperClient(executableOverride: helper))
        let session = ClaudeSession(.object(["id": .string("11111111-1111-4111-8111-111111111111"),
            "sessionId": .string("11111111-1111-4111-8111-111111111111"),
            "provider": .string("claude"), "name": .string("Synthetic recovery session")]))!
        for (reason, fragment) in [("running", "still running"), ("archived", "Unarchive"),
                                   ("no_transcript", "no transcript"), ("no_desktop", "Install"), ("invalid", "Refresh")] {
            let payload = "{\"ok\":true,\"message\":\"Synthetic\",\"details\":{\"openMode\":\"session\",\"revealReason\":\"\(reason)\"}}"
            try ("#!/bin/sh\n/usr/bin/printf '%s\\n' '" + payload + "'\n").write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            model.openSessionInPlatform(session)
            precondition(model.platformOpening && model.platformOpenSessionID == session.id)
            for _ in 0..<100 where model.platformOpening { try await Task.sleep(for: .milliseconds(20)) }
            precondition(!model.platformOpening)
            precondition(model.platformOpenNotice?.contains(fragment) == true, "missing inline reason: \(reason)")
            model.petNotice = nil // the pet's timer must not erase the pane's recovery message
            precondition(model.platformOpenNotice?.contains(fragment) == true)
            print("PASS: \(reason) stays visible in the session pane")
        }
        try "#!/bin/sh\nexit 1\n".write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        model.openSessionInPlatform(session)
        for _ in 0..<100 where model.platformOpening { try await Task.sleep(for: .milliseconds(20)) }
        precondition(!model.platformOpening && model.platformOpenNotice?.isEmpty == false)
        print("PASS: helper failure restores the button and shows an error")
    }
}
