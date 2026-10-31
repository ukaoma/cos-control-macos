import Foundation
/// Hand-run only, never in the suite. Runs the real `cos-usage` reader over a real home against a scratch copy of the
/// usage history, so real data is read and only the scratch copy is written. Prints the report (counts only) and how long
/// each pass took. The scripts folder is passed in, so `.env` is never opened. A fourth argument names a Node for compressed
/// rollouts; with none they stay unread, which is the "before". A fifth, `usage`, also runs Usage's own read on the scratch
/// copy until it has nothing pending, and prints its Codex tokens and API value for the same 30 days to stderr.
@main struct CosCostCanary {
    static func main() throws {
        let args = CommandLine.arguments
        guard (4...6).contains(args.count), args[2].hasPrefix("/private/tmp/") || args[2].hasPrefix("/tmp/") else {
            fatalError("Usage: cos-cost-canary <source-home> <scratch-database-under-tmp> <scripts-folder> [node] [usage]")
        }
        let collector = try SessionUsageCollector(home: URL(fileURLWithPath: args[1]), database: URL(fileURLWithPath: args[2]))
        if args.count >= 5, !args[4].isEmpty { collector.compressedLogNodes = [args[4]] }
        if args.count == 6 { try usagePasses(collector) }
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
    /// Usage's own read on the scratch copy. Its figures are what COS cost's denominator divides by.
    static func usagePasses(_ collector: SessionUsageCollector) throws {
        var pass = 0
        var report = try collector.refresh(maxBytes: 0, readOnly: true)
        while report.pendingFiles > 0 && pass < 200 {
            pass += 1
            report = try collector.refresh()
            if pass % 10 == 0 { FileHandle.standardError.write(Data("usage pass \(pass): \(report.pendingFiles) files pending\n".utf8)) }
        }
        let window = CosCostRules.window(now: Date(), timeZone: .current)
        let codex = report.buckets.filter { window.contains($0.day) && $0.provider == "OpenAI" }
        let tokens = codex.reduce(Int64(0)) { $0 + $1.counts.total }, usd = codex.reduce(0.0) { $0 + $1.estimatedUSD }
        FileHandle.standardError.write(Data(String(format: "usage after %d passes: %d pending, %d unreadable, Codex (OpenAI) %lld tokens, $%.2f over %@...%@\n", pass, report.pendingFiles, report.unreadableFiles, tokens, usd, window.lowerBound, window.upperBound).utf8))
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
