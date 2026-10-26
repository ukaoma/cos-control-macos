import Foundation

/// Counts only. No prompts, responses or credentials are persisted by Usage.
struct SessionUsageCounts: Codable, Equatable, Sendable {
    var input: Int64 = 0 // uncached input; disjoint from cache categories
    var output: Int64 = 0 // reasoning is already included
    var cacheRead: Int64 = 0
    var cacheWrite: Int64 = 0
    var total: Int64 { input + output + cacheRead + cacheWrite }
    static func + (a: Self, b: Self) -> Self {
        Self(input: a.input+b.input, output: a.output+b.output, cacheRead: a.cacheRead+b.cacheRead, cacheWrite: a.cacheWrite+b.cacheWrite)
    }
    static func number(_ value: Any?) -> Int64 {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue < 1e14 else { return 0 }
        return n.int64Value
    }
}

struct SessionUsageBucket: Codable, Identifiable, Sendable {
    var day: String
    var provider: String
    var model: String
    var counts: SessionUsageCounts
    var events: Int
    var pricedEvents: Int
    var estimatedUSD: Double
    var id: String { day + "|" + provider + "|" + model }
}

struct SessionUsageReport: Codable, Sendable {
    var buckets: [SessionUsageBucket]
    var updatedAt: String
    var timeZone: String
    var filesIndexed: Int
    var pendingFiles: Int
    var unreadableFiles: Int
    var malformedRows: Int
    var missingBaselineEvents: Int
    var coverage: [String]
    var pricingVersion: String
}

/// API-equivalent standard/global rates, verified 2026-10-25. NOT subscription invoices.
/// Historical usage is valued at this snapshot; unknown ids remain unpriced (never zero-cost).
enum SessionUsagePricing {
    static let version = "2026-10-25-standard-v1"
    static let sources = ["https://platform.claude.com/docs/en/about-claude/pricing", "https://developers.openai.com/api/docs/pricing"]
    struct Rate { let input: Double; let output: Double; let read: Double; let write5: Double; let write1h: Double }
    static func rate(provider: String, model: String, prompt: Int64) -> Rate? {
        // Only documented aliases and dated snapshots. No fuzzy family fallback.
        let name = model.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        if provider == "Anthropic" {
            let tuple: (Double, Double, Double)?
            switch name {
            case "claude-opus-5-5": tuple = (4,20,0.2)
            case "claude-sonnet-5-5": tuple = (2,10,0.1)
            case "claude-haiku-5-5": tuple = prompt > 100_000 ? (0.5,2.5,0.05) : (0.1,0.5,0.01)
            case "claude-fable-5-1", "claude-mythos-5-1": tuple = (10,50,0.25)
            case "claude-fable-5", "claude-mythos-5": tuple = (10,50,1)
            case "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5": tuple = (5,25,0.5)
            case "claude-opus-4-1", "claude-opus-4": tuple = (15,75,1.5)
            case "claude-sonnet-5": tuple = (2,10,0.2)
            case "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4": tuple = (3,15,0.3)
            case "claude-haiku-4-5": tuple = (1,5,0.1)
            case "claude-3-5-haiku": tuple = (0.8,4,0.08)
            default: tuple = nil
            }
            guard let t = tuple else { return nil }
            return Rate(input: t.0, output: t.1, read: t.2, write5: t.0*1.25, write1h: t.0*2)
        }
        guard provider == "OpenAI" else { return nil }
        switch name {
        case "gpt-6.1-sol": return Rate(input: 2, output: 10, read: 0.1, write5: 2.5, write1h: 5)
        case "gpt-6-astra": return Rate(input: 10, output: 50, read: 1, write5: 12.5, write1h: 25)
        case "gpt-6-luna": return Rate(input: 0.1, output: 0.5, read: 0.01, write5: 0.125, write1h: 0.25)
        case "gpt-5.3-codex": return Rate(input: 1.75, output: 14, read: 0.175, write5: 0, write1h: 0)
        default: return nil
        }
    }
    static func estimate(provider: String, model: String, counts: SessionUsageCounts, oneHour: Int64 = 0) -> Double? {
        // Codex write retention and long-context tier are not reliably present in rollouts.
        guard !(provider == "OpenAI" && (counts.cacheWrite > 0 || counts.input+counts.cacheRead > 272_000)),
              let r = rate(provider: provider, model: model, prompt: counts.input+counts.cacheRead+counts.cacheWrite) else { return nil }
        let long = min(max(0, oneHour), counts.cacheWrite)
        return (Double(counts.input)*r.input + Double(counts.output)*r.output + Double(counts.cacheRead)*r.read + Double(counts.cacheWrite-long)*r.write5 + Double(long)*r.write1h) / 1_000_000
    }
    static func tokens(_ n: Int64) -> String {
        n >= 1_000_000_000 ? String(format: "%.2fB", Double(n)/1e9) : n >= 1_000_000 ? String(format: "%.2fM", Double(n)/1e6) : n >= 1000 ? String(format: "%.1fK", Double(n)/1000) : String(n)
    }
}
import CoreFoundation

/// Presentation math shares the ledger's reporting timezone. Never interprets tokens as plan quota.
enum SessionUsagePresentation {
    static let allowanceNote = "Token share is not your plan allowance. It compares recorded tokens in this selection; providers calculate subscription limits separately."
    static func tokenCount(_ counts: SessionUsageCounts, excludingCacheReads: Bool) -> Int64 {
        excludingCacheReads ? counts.input + counts.output + counts.cacheWrite : counts.total
    }
    static func share(_ numerator: Int64, of denominator: Int64) -> String {
        guard denominator > 0 else { return "Unavailable" }
        let percent = 100 * Double(numerator) / Double(denominator)
        return percent > 0 && percent < 0.1 ? "<0.1%" : String(format: "%.1f%%", percent)
    }
    static func aggregate(_ rows: [SessionUsageBucket], excludingCacheReads: Bool = false) -> [SessionUsageBucket] {
        Dictionary(grouping: rows, by: { $0.provider + "|" + $0.model }).values.compactMap { group in
            guard let first = group.first else { return nil }
            return SessionUsageBucket(day: first.day, provider: first.provider, model: first.model,
                counts: group.reduce(SessionUsageCounts()) { $0 + $1.counts }, events: group.reduce(0) { $0 + $1.events },
                pricedEvents: group.reduce(0) { $0 + $1.pricedEvents }, estimatedUSD: group.reduce(0) { $0 + $1.estimatedUSD })
        }.sorted {
            let a = tokenCount($0.counts, excludingCacheReads: excludingCacheReads)
            let b = tokenCount($1.counts, excludingCacheReads: excludingCacheReads)
            return a == b ? $0.id < $1.id : a > b
        }
    }
    static func costLabel(_ rows: [SessionUsageBucket]) -> String {
        let priced = rows.reduce(0) { $0 + $1.pricedEvents }, events = rows.reduce(0) { $0 + $1.events }
        guard priced > 0 else { return "Unavailable" }
        return rows.reduce(0) { $0 + $1.estimatedUSD }.formatted(.currency(code: "USD")) + (priced < events ? " + unknown" : "")
    }
    static func selectPeriod(_ rows: [SessionUsageBucket], period: String, now: Date, timeZone: TimeZone, customStart: Date? = nil, customEnd: Date? = nil) -> [SessionUsageBucket] {
        if period == "Custom dates" {
            guard let start = customStart, let end = customEnd else { return [] }
            let f = dayFormatter(timeZone: timeZone)
            let first = f.string(from: start), last = f.string(from: end)
            guard first <= last else { return [] }
            let bounds = first...last
            return rows.filter { bounds.contains($0.day) }
        }
        if period == "All history" { return rows }
        guard let bounds = dayBounds(period: period, now: now, timeZone: timeZone) else {
            return rows.filter { $0.day.hasPrefix(period) }
        }
        // ISO day keys sort chronologically. Compute the boundaries once, not a formatter per row.
        return rows.filter { bounds.contains($0.day) }
    }
    static func includes(day: String, period: String, now: Date, timeZone: TimeZone) -> Bool {
        if period == "All history" { return true }
        return dayBounds(period: period, now: now, timeZone: timeZone)?.contains(day) ?? day.hasPrefix(period)
    }
    static func dayFormatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        f.calendar = calendar; f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        return f
    }
    struct Summary: Identifiable {
        let id: String
        let counts: SessionUsageCounts
        let events: Int
        let pricedEvents: Int
        let estimatedUSD: Double
        var costLabel: String {
            guard pricedEvents > 0 else { return "Unavailable" }
            return estimatedUSD.formatted(.currency(code: "USD")) + (pricedEvents < events ? " + unknown" : "")
        }
    }
    static func summarize(_ rows: [SessionUsageBucket], by key: KeyPath<SessionUsageBucket, String>, excludingCacheReads: Bool = false) -> [Summary] {
        Dictionary(grouping: rows, by: { $0[keyPath: key] }).map { name, group in
            Summary(id: name, counts: group.reduce(SessionUsageCounts()) { $0 + $1.counts },
                events: group.reduce(0) { $0 + $1.events }, pricedEvents: group.reduce(0) { $0 + $1.pricedEvents },
                estimatedUSD: group.reduce(0) { $0 + $1.estimatedUSD })
        }.sorted {
            let a = tokenCount($0.counts, excludingCacheReads: excludingCacheReads)
            let b = tokenCount($1.counts, excludingCacheReads: excludingCacheReads)
            return a == b ? $0.id < $1.id : a > b
        }
    }
    struct TokenCategory: Identifiable {
        let id: String
        let count: Int64
    }
    static func tokenMix(_ counts: SessionUsageCounts, excludingCacheReads: Bool) -> [TokenCategory] {
        var categories = [TokenCategory(id: "Uncached input", count: counts.input), TokenCategory(id: "Output", count: counts.output)]
        if !excludingCacheReads { categories.append(TokenCategory(id: "Cache read", count: counts.cacheRead)) }
        categories.append(TokenCategory(id: "Cache write", count: counts.cacheWrite))
        return categories
    }
    private static func dayBounds(period: String, now: Date, timeZone: TimeZone) -> ClosedRange<String>? {
        let days = ["Last 7 days": 7, "Last 30 days": 30, "Last 90 days": 90]
        guard days[period] != nil || period == "Last weekend" else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        let today = calendar.startOfDay(for: now)
        if let count = days[period] {
            return f.string(from: calendar.date(byAdding: .day, value: 1-count, to: today)!)...f.string(from: today)
        }
        // Most recent completed Saturday/Sunday pair; on a weekend use the previous one.
        let daysSinceMonday = (calendar.component(.weekday, from: today) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: today)!
        return f.string(from: calendar.date(byAdding: .day, value: -2, to: monday)!)...f.string(from: calendar.date(byAdding: .day, value: -1, to: monday)!)
    }
}
