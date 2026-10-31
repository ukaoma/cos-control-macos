import Foundation
/// Hand-run only, never in the suite. Runs the real `cos-usage` reader over a real home against a scratch copy of the
/// usage history, so real data is read and only the scratch copy is written. Prints the report (counts only) and how long
/// each pass took. The scripts folder is passed in, so `.env` is never opened.
@main struct CosCostCanary {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4, args[2].hasPrefix("/private/tmp/") || args[2].hasPrefix("/tmp/") else {
            fatalError("Usage: cos-cost-canary <source-home> <scratch-database-under-tmp> <scripts-folder>")
        }
        let collector = try SessionUsageCollector(home: URL(fileURLWithPath: args[1]), database: URL(fileURLWithPath: args[2]))
        var pass = 0
        var opened = Set<String>()
        while true {
            pass += 1
            let started = Date()
            let report = try collector.cosUsage(plistScripts: args[3], dataDirectory: nil, importSessions: true, opened: { opened.insert($0) })
            let seconds = Date().timeIntervalSince(started)
            FileHandle.standardError.write(Data("pass \(pass): \(String(format: "%.1f", seconds)) s, still reading \(report.sessions.stillReading) of \(report.sessions.tracked)\n".utf8))
            if report.sessions.stillReading == 0 || pass >= 40 {
                FileHandle.standardError.write(Data("opened: \(opened.sorted().joined(separator: ", "))\n".utf8))
                FileHandle.standardOutput.write(try JSONEncoder().encode(report))
                try rateCheck(home: args[1])
                return
            }
        }
    }
    /// The rate card against what the command line itself reported, on every real gist row. inputTokens is all cache
    /// writes and reads together, and these runs write a one-hour cache, so that is what the card is asked to price.
    static func rateCheck(home: String) throws {
        let file = URL(fileURLWithPath: home).appendingPathComponent(".cos-glasses/data/lens-gist-runs.jsonl")
        var rows = 0, unresolved = 0
        var card = 0.0, reported = 0.0
        var gaps: [Double] = []
        for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let usage = row["usage"] as? [String: Any],
                  let cost = (usage["costUsd"] as? NSNumber)?.doubleValue, cost > 0 else { continue }
            let input = SessionUsageCounts.number(usage["inputTokens"]), output = SessionUsageCounts.number(usage["outputTokens"])
            guard let resolved = CosCostRates.resolve(row["model"] as? String ?? ""),
                  let usd = CosCostRates.usd(provider: resolved.provider, model: resolved.model, counts: SessionUsageCounts(output: output, cacheWrite: input), oneHour: input) else { unresolved += 1; continue }
            rows += 1
            card += usd
            reported += cost
            gaps.append(abs(usd - cost) / cost)
        }
        gaps.sort()
        let median = gaps.isEmpty ? 0 : gaps[gaps.count / 2], worst = gaps.last ?? 0
        FileHandle.standardError.write(Data(String(format: "rate check: %d real gist rows, %d no rate, card $%.4f, reported $%.4f, total gap %.3f%%, median row gap %.3f%%, worst row gap %.2f%%\n", rows, unresolved, card, reported, abs(card - reported) / max(reported, 1e-9) * 100, median * 100, worst * 100).utf8))
    }
}
