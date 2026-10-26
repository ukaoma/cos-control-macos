import Foundation

// Compiled with ce9b71c's (0.5.344) MacDictationCore.swift: the 0.5.345 file reads whole, nothing moved aside.
@main struct HistoryRead {
    static func main() {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let loaded = DictationHistory.loadOrQuarantine(from: url, now: Date())
        guard loaded.movedTo == nil, loaded.writable, loaded.records.count == 3 else {
            FileHandle.standardError.write(Data("FAIL: 0.5.344 could not read a 0.5.345 history (moved=\(loaded.movedTo != nil) count=\(loaded.records.count))\n".utf8)); exit(1)
        }
        guard loaded.records.contains(where: { $0.edit?.text == "We need the slides." }), loaded.records.allSatisfy({ !$0.text.isEmpty }) else {
            FileHandle.standardError.write(Data("FAIL: 0.5.344 lost a field it knows (the edit or the text)\n".utf8)); exit(1)
        }
        print("PASS history back-compat: 0.5.344 (ce9b71c) reads a 0.5.345 history whole: 3 dictations, nothing moved aside, its edit kept")
    }
}
