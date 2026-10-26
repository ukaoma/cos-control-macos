import Foundation

// 0.5.345 (plan r3): writes a dictation history with every new optional field set (typed, rawHeard, the edit's
// matchedPolish and styleKeys), compiled with today's MacDictationCore.swift. HistoryRead.swift, compiled with
// ce9b71c's (0.5.344), must read it back whole: history decoding is all-or-nothing, so a rollback would otherwise
// move the file aside. Fictional text only.
@main struct HistoryWrite {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let at = Date(timeIntervalSince1970: 1_792_900_000)
        let edit = DictationUserEdit(text: "We need the slides.", app: "Notes", at: at, edits: 1, matchedPolish: true, styleKeys: ["contractions-use"])
        let records = [
            DictationRecord(id: UUID(), text: "We need the deck.", createdAt: at, delivery: .inserted(app: "Notes"), engine: "parakeet-ultra",
                            heard: "we need uh the deck", polishModel: "sonnet", polishPrompt: "v4", typed: "We need the deck"),
            DictationRecord(id: UUID(), text: "We need the deck", createdAt: at.addingTimeInterval(1), delivery: .unconfirmed(app: "Slack", viaPaste: true),
                            rawHeard: "we need um the deck"),
            DictationRecord(id: UUID(), text: "We need the deck.", createdAt: at.addingTimeInterval(2), delivery: .copied(.secureField),
                            heard: "we need the deck", polishModel: "haiku", edit: edit, typed: "we need the deck"),
        ]
        try DictationHistory.save(records, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        guard text.contains("\"typed\"") && text.contains("\"rawHeard\"") && text.contains("\"matchedPolish\"") && text.contains("\"styleKeys\"") else {
            FileHandle.standardError.write(Data("FAIL: the 0.5.345 history did not carry the new fields\n".utf8)); exit(1)
        }
        print("wrote 3 dictations with typed, rawHeard, matchedPolish and styleKeys")
    }
}
