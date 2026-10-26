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
        n >= 1_000_000 ? String(format: "%.2fM", Double(n)/1e6) : n >= 1000 ? String(format: "%.1fK", Double(n)/1000) : String(n)
    }
}
import CoreFoundation
