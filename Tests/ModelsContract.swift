import AppKit
import Foundation

@main
struct ModelsContract {
    private static func attachment(_ idDigit: Character, timestamp: String, width: Double = 640) -> [String: JSONValue] {
        [
            "id": .string("m_" + String(repeating: String(idDigit), count: 24)),
            "kind": .string("user_photo"),
            "mime": .string("image/png"),
            "width": .number(width),
            "height": .number(480),
            "createdAt": .string(timestamp),
        ]
    }

    /// A speaker row, built from the shape the server actually sends.
    private static func voice(
        label: String, reliability: String, isOwner: Bool = false, segments: Int = 12
    ) -> ReviewVoice? {
        ReviewVoice(.object([
            "label": .string(label),
            "segments": .number(Double(segments)),
            "isOwner": .bool(isOwner),
            "reliability": .string(reliability),
            "nameAsserted": .bool(reliability == "confident"),
            "assertionBlockers": .array([]),
            "thrashesWith": .array([]),
            "phrases": .array([]),
        ]))
    }

    /// Who may be renamed, and who may never be.
    ///
    /// Regression: `canRename` excluded `.unattributed` while the row's copy read
    /// "Give it one from the list above" — the panel instructed an action it then
    /// refused to offer. Naming an unheard voice is the entire point of reviewing
    /// one, and the server always supported it.
    private static func checkRenameEligibility() {
        // The fix, stated as behaviour.
        precondition(voice(label: "Ext", reliability: "unattributed")?.canRename == true,
                     "an unattributed voice must be nameable")
        precondition(voice(label: "Unidentified 2", reliability: "unattributed")?.canRename == true,
                     "a numbered unattributed voice must be nameable")

        // Unchanged, and the reason the guard exists at all: the wearer is
        // established by the device, not by cosine, and absorbing them into
        // another profile would break identification for every later chunk.
        precondition(voice(label: "MU", reliability: "confident", isOwner: true)?.canRename == false,
                     "the owner must never be renameable")
        precondition(voice(label: "MU", reliability: "unattributed", isOwner: true)?.canRename == false,
                     "the owner must never be renameable, even unattributed")

        // Still true for ordinary rows.
        precondition(voice(label: "Queen Ukaoma", reliability: "confident")?.canRename == true)
        precondition(voice(label: "Luke Henry", reliability: "weak")?.canRename == true)

        // Naming an unattributed row is an ASSIGNMENT, and the confirm card says
        // so — a large unmatched cluster is frequently several people.
        precondition(voice(label: "Ext", reliability: "unattributed")?.isNameAssignment == true)
        precondition(voice(label: "Queen Ukaoma", reliability: "confident")?.isNameAssignment == false)

        // De-attribution stays scoped to rows that actually carry a name: there
        // is nothing to take back from a voice nobody was ever called.
        precondition(voice(label: "Ext", reliability: "unattributed")?.canDeattribute == false)
        precondition(voice(label: "Queen Ukaoma", reliability: "confident")?.canDeattribute == true)
    }

    static func main() throws {
        checkRenameEligibility()

        precondition(GlassesAttachmentRef(object: attachment("a", timestamp: "2026-08-03T12:00:00.000Z")) != nil)
        precondition(GlassesAttachmentRef(object: attachment("b", timestamp: "2026-08-03T12:00:00.123Z")) != nil)
        precondition(GlassesAttachmentRef(object: attachment("c", timestamp: "2026-08-03T12:00:00Z")) != nil)
        precondition(GlassesAttachmentRef(object: attachment("d", timestamp: "not-a-date")) == nil)
        precondition(GlassesAttachmentRef(object: attachment("e", timestamp: "2026-08-03T12:00:00Z", width: .infinity)) == nil)
        precondition(GlassesAttachmentRef(object: attachment("f", timestamp: "2026-08-03T12:00:00Z", width: 1e100)) == nil)

        let refs = (0..<6).map { index -> JSONValue in
            let digit = Character(String(index))
            return .object(attachment(digit, timestamp: "2026-08-03T12:00:00.000Z"))
        }
        let turn = GlassesTurn([
            "query": .string("photo"),
            "text": .string("answer"),
            "sessionId": .string("session"),
            "source": .string("live"),
            "attachments": .array(refs),
        ])
        precondition(turn?.attachments.count == 5)

        let status = ServerStatus([
            "meetingPreviewSupported": .bool(true),
            "meetingPreviewEnabled": .bool(true),
            "idleMetalHqSupported": .bool(true),
            "idleMetalHqEnabled": .bool(true),
            "idleMetalHqForceCpu": .bool(false),
        ])
        precondition(status.meetingPreviewSupported && status.meetingPreviewEnabled == true)
        precondition(status.idleMetalHqSupported && status.idleMetalHqEnabled == true && status.idleMetalHqForceCpu == false)

        // Decode into an owned in-memory image before deleting the source.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try png.write(to: source, options: .atomic)
        let decoded = RecentMediaImageDecoder.decode(url: source, expectedBytes: png.count)
        try FileManager.default.removeItem(at: source)
        precondition(decoded?.tiffRepresentation != nil)

        print("COS Control: Swift attachment parsing and owned-image decoding passed")
    }
}
