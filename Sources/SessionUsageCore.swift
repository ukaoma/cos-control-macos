import Foundation
import CoreFoundation

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

enum SessionUsageTimeScale: String, CaseIterable, Sendable {
    case daily = "Daily"
    case weekly = "Weekly"
    case monthly = "Monthly"
}

enum SessionUsageMeasure: String, CaseIterable, Sendable {
    case tokens = "Tokens"
    case cost = "API value"
    case records = "Records"
}

enum SessionUsageSeries: String, CaseIterable, Sendable {
    case providers = "Providers"
    case models = "Models"
    case categories = "Categories"
}

enum SessionUsageModelSort: String, CaseIterable, Sendable {
    case tokens = "Tokens"
    case cost = "API value"
    case records = "Records"
    case cacheShare = "Cache read %"
    case model = "Model"
}

enum SessionUsageDaySort: String, CaseIterable, Sendable {
    case date = "Date"
    case tokens = "Tokens"
    case cost = "API value"
    case records = "Records"
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
    /// Decomposes a bucket's stored estimatedUSD across disjoint token categories while reconciling to row.estimatedUSD.
    static func categoryUSD(for row: SessionUsageBucket) -> (input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        guard row.pricedEvents > 0, row.estimatedUSD > 0,
              let r = rate(provider: row.provider, model: row.model, prompt: 0) else { return (0, 0, 0, 0) }
        let inUSD = Double(row.counts.input) * r.input / 1_000_000
        let outUSD = Double(row.counts.output) * r.output / 1_000_000
        let readUSD = Double(row.counts.cacheRead) * r.read / 1_000_000
        let write5USD = Double(row.counts.cacheWrite) * r.write5 / 1_000_000
        let nonWrite = inUSD + outUSD + readUSD
        // Anthropic 1-hour cache writes increase only cacheWrite above the 5-minute baseline.
        if row.provider == "Anthropic", row.counts.cacheWrite > 0, row.estimatedUSD >= nonWrite + write5USD * 0.999,
           !row.model.hasPrefix("claude-haiku-5-5") {
            return (inUSD, outUSD, readUSD, max(0, row.estimatedUSD - nonWrite))
        }
        let baseTotal = nonWrite + write5USD
        guard baseTotal > 0 else { return (0, 0, 0, 0) }
        let scale = row.estimatedUSD / baseTotal
        let scaledIn = inUSD * scale, scaledOut = outUSD * scale, scaledRead = readUSD * scale
        return (scaledIn, scaledOut, scaledRead, max(0, row.estimatedUSD - scaledIn - scaledOut - scaledRead))
    }
    static func tokens(_ n: Int64) -> String {
        n >= 1_000_000_000 ? String(format: "%.2fB", Double(n)/1e9) : n >= 1_000_000 ? String(format: "%.2fM", Double(n)/1e6) : n >= 1000 ? String(format: "%.1fK", Double(n)/1000) : String(n)
    }
}

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
    static func costShare(_ numerator: Double, of denominator: Double) -> String {
        guard denominator > 0 else { return "Unavailable" }
        let percent = 100 * numerator / denominator
        return percent > 0 && percent < 0.1 ? "<0.1%" : String(format: "%.1f%%", percent)
    }
    static func deltaPercent(current: Double, prior: Double) -> String {
        guard prior > 0 else { return "Unavailable" }
        let pct = 100 * (current - prior) / prior
        if abs(pct) < 0.05 { return "0.0%" }
        return String(format: "%+.1f%%", pct)
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
    static func sortModels(_ rows: [SessionUsageBucket], by sort: SessionUsageModelSort, ascending: Bool = false, excludingCacheReads: Bool = false) -> [SessionUsageBucket] {
        let aggregated = aggregate(rows, excludingCacheReads: excludingCacheReads)
        return aggregated.sorted { left, right in
            if sort == .model {
                let cmp = left.model.localizedCaseInsensitiveCompare(right.model)
                if cmp != .orderedSame { return ascending ? cmp == .orderedAscending : cmp == .orderedDescending }
                return left.provider < right.provider
            }
            let a: Double, b: Double
            switch sort {
            case .tokens:
                a = Double(tokenCount(left.counts, excludingCacheReads: excludingCacheReads))
                b = Double(tokenCount(right.counts, excludingCacheReads: excludingCacheReads))
            case .cost:
                a = left.pricedEvents > 0 ? left.estimatedUSD : -1
                b = right.pricedEvents > 0 ? right.estimatedUSD : -1
            case .records:
                a = Double(left.events); b = Double(right.events)
            case .cacheShare:
                a = left.counts.total > 0 ? Double(left.counts.cacheRead) / Double(left.counts.total) : 0
                b = right.counts.total > 0 ? Double(right.counts.cacheRead) / Double(right.counts.total) : 0
            case .model:
                a = 0; b = 0
            }
            if a == b { return left.id < right.id }
            return ascending ? a < b : a > b
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
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone; calendar.firstWeekday = 2
        f.calendar = calendar; f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        return f
    }
    static func periodKey(for day: String, scale: SessionUsageTimeScale, timeZone: TimeZone) -> String {
        switch scale {
        case .daily: return String(day.prefix(10))
        case .monthly: return String(day.prefix(7))
        case .weekly:
            let f = dayFormatter(timeZone: timeZone)
            guard let date = f.date(from: String(day.prefix(10))) else { return String(day.prefix(10)) }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone; calendar.firstWeekday = 2
            let daysSinceMonday = (calendar.component(.weekday, from: date) + 5) % 7
            let monday = calendar.date(byAdding: .day, value: -daysSinceMonday, to: date) ?? date
            return f.string(from: monday)
        }
    }
    static func periodTitle(for key: String, scale: SessionUsageTimeScale, timeZone: TimeZone) -> String {
        let f = dayFormatter(timeZone: timeZone)
        guard let date = f.date(from: key.count == 7 ? key + "-01" : key) else { return key }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone; calendar.firstWeekday = 2
        let out = DateFormatter(); out.locale = Locale(identifier: "en_US_POSIX"); out.timeZone = timeZone; out.calendar = calendar
        switch scale {
        case .daily:
            out.dateFormat = "EEEE, MMM d, yyyy"
            return out.string(from: date)
        case .monthly:
            out.dateFormat = "MMMM yyyy"
            return out.string(from: date)
        case .weekly:
            let sunday = calendar.date(byAdding: .day, value: 6, to: date) ?? date
            let startFmt = DateFormatter(); startFmt.locale = Locale(identifier: "en_US_POSIX"); startFmt.timeZone = timeZone; startFmt.calendar = calendar
            startFmt.dateFormat = "MMM d"
            out.dateFormat = "MMM d, yyyy"
            return "Week of \(startFmt.string(from: date)) – \(out.string(from: sunday))"
        }
    }
    struct Summary: Identifiable, Sendable {
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
    static func sortDays(_ rows: [SessionUsageBucket], by sort: SessionUsageDaySort, ascending: Bool = false, excludingCacheReads: Bool = false) -> [Summary] {
        let summaries = summarize(rows, by: \.day, excludingCacheReads: excludingCacheReads)
        return summaries.sorted { left, right in
            if sort == .date {
                return ascending ? left.id < right.id : left.id > right.id
            }
            let a: Double, b: Double
            switch sort {
            case .tokens:
                a = Double(tokenCount(left.counts, excludingCacheReads: excludingCacheReads))
                b = Double(tokenCount(right.counts, excludingCacheReads: excludingCacheReads))
            case .cost:
                a = left.pricedEvents > 0 ? left.estimatedUSD : -1
                b = right.pricedEvents > 0 ? right.estimatedUSD : -1
            case .records:
                a = Double(left.events); b = Double(right.events)
            case .date:
                a = 0; b = 0
            }
            if a == b { return left.id > right.id }
            return ascending ? a < b : a > b
        }
    }
    struct TokenCategory: Identifiable, Sendable {
        let id: String
        let count: Int64
        var estimatedUSD: Double = 0
    }
    static func tokenMix(_ counts: SessionUsageCounts, excludingCacheReads: Bool, rows: [SessionUsageBucket] = []) -> [TokenCategory] {
        var inUSD = 0.0, outUSD = 0.0, readUSD = 0.0, writeUSD = 0.0
        for row in rows {
            let c = SessionUsagePricing.categoryUSD(for: row)
            inUSD += c.input; outUSD += c.output; readUSD += c.cacheRead; writeUSD += c.cacheWrite
        }
        var categories = [
            TokenCategory(id: "Uncached input", count: counts.input, estimatedUSD: inUSD),
            TokenCategory(id: "Output", count: counts.output, estimatedUSD: outUSD)
        ]
        if !excludingCacheReads {
            categories.append(TokenCategory(id: "Cache read", count: counts.cacheRead, estimatedUSD: readUSD))
        }
        categories.append(TokenCategory(id: "Cache write", count: counts.cacheWrite, estimatedUSD: writeUSD))
        return categories
    }
    /// Full 4-category cost breakdown (API value always retains every priced category even when cache reads are excluded from token counts).
    static func costMix(_ rows: [SessionUsageBucket], counts: SessionUsageCounts? = nil) -> [TokenCategory] {
        let totals = counts ?? rows.reduce(SessionUsageCounts()) { $0 + $1.counts }
        return tokenMix(totals, excludingCacheReads: false, rows: rows)
    }

    struct PeriodComparison: Sendable {
        let recordedDays: Int
        let dailyAvgTokens: Int64
        let dailyAvgRecords: Int
        let dailyAvgUSD: Double
        let peakDay: Summary?
        let priorRangeLabel: String?
        let priorTokens: Int64
        let priorRecords: Int
        let priorUSD: Double
        let priorPricedEvents: Int
        let priorRecordedDays: Int
        let hasPriorBaseline: Bool
        let partialPriorHistory: Bool
        let tokenDeltaLabel: String
        let recordsDeltaLabel: String
        let costDeltaLabel: String
    }

    static func comparePeriod(allRows: [SessionUsageBucket], selectedRows: [SessionUsageBucket], period: String, provider: String = "All providers", model: String = "All models", excludingCacheReads: Bool = false, now: Date, timeZone: TimeZone, customStart: Date? = nil, customEnd: Date? = nil) -> PeriodComparison {
        let days = Set(selectedRows.map(\.day)).count
        let curCounts = selectedRows.reduce(SessionUsageCounts()) { $0 + $1.counts }
        let curTokens = tokenCount(curCounts, excludingCacheReads: excludingCacheReads)
        let curEvents = selectedRows.reduce(0) { $0 + $1.events }
        let curPriced = selectedRows.reduce(0) { $0 + $1.pricedEvents }
        let curUSD = selectedRows.reduce(0.0) { $0 + $1.estimatedUSD }
        let avgTokens: Int64 = days > 0 ? curTokens / Int64(days) : 0
        let avgRecords: Int = days > 0 ? Int((Double(curEvents) / Double(days)).rounded()) : 0
        let avgUSD: Double = days > 0 ? curUSD / Double(days) : 0
        let peak = summarize(selectedRows, by: \.day, excludingCacheReads: excludingCacheReads).first

        guard let prior = priorBounds(period: period, now: now, timeZone: timeZone, customStart: customStart, customEnd: customEnd) else {
            return PeriodComparison(recordedDays: days, dailyAvgTokens: avgTokens, dailyAvgRecords: avgRecords, dailyAvgUSD: avgUSD, peakDay: peak, priorRangeLabel: nil, priorTokens: 0, priorRecords: 0, priorUSD: 0, priorPricedEvents: 0, priorRecordedDays: 0, hasPriorBaseline: false, partialPriorHistory: false, tokenDeltaLabel: "Unavailable", recordsDeltaLabel: "Unavailable", costDeltaLabel: "Unavailable")
        }
        let priorRows = allRows.filter {
            prior.contains($0.day) && (provider == "All providers" || $0.provider == provider) && (model == "All models" || $0.model == model)
        }
        let earliestAll = allRows.map(\.day).min()
        let partialPrior = earliestAll.map { $0 > prior.lowerBound } ?? true
        let priorDays = Set(priorRows.map(\.day)).count
        let priorCounts = priorRows.reduce(SessionUsageCounts()) { $0 + $1.counts }
        let pTokens = tokenCount(priorCounts, excludingCacheReads: excludingCacheReads)
        let pEvents = priorRows.reduce(0) { $0 + $1.events }
        let pPriced = priorRows.reduce(0) { $0 + $1.pricedEvents }
        let pUSD = priorRows.reduce(0.0) { $0 + $1.estimatedUSD }
        let hasBaseline = !priorRows.isEmpty
        let tokDelta = hasBaseline ? deltaPercent(current: Double(curTokens), prior: Double(pTokens)) : "Unavailable"
        let recDelta = hasBaseline ? deltaPercent(current: Double(curEvents), prior: Double(pEvents)) : "Unavailable"
        let usdDelta = (hasBaseline && curPriced > 0 && pPriced > 0) ? deltaPercent(current: curUSD, prior: pUSD) : "Unavailable"
        return PeriodComparison(recordedDays: days, dailyAvgTokens: avgTokens, dailyAvgRecords: avgRecords, dailyAvgUSD: avgUSD, peakDay: peak, priorRangeLabel: "\(prior.lowerBound) – \(prior.upperBound)", priorTokens: pTokens, priorRecords: pEvents, priorUSD: pUSD, priorPricedEvents: pPriced, priorRecordedDays: priorDays, hasPriorBaseline: hasBaseline, partialPriorHistory: partialPrior, tokenDeltaLabel: tokDelta, recordsDeltaLabel: recDelta, costDeltaLabel: usdDelta)
    }

    static func priorBounds(period: String, now: Date, timeZone: TimeZone, customStart: Date? = nil, customEnd: Date? = nil) -> ClosedRange<String>? {
        if period == "All history" { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone; calendar.firstWeekday = 2
        let f = dayFormatter(timeZone: timeZone)
        if period == "Last weekend", let current = dayBounds(period: period, now: now, timeZone: timeZone),
           let s = f.date(from: current.lowerBound), let e = f.date(from: current.upperBound) {
            return f.string(from: calendar.date(byAdding: .day, value: -7, to: s)!)...f.string(from: calendar.date(byAdding: .day, value: -7, to: e)!)
        }
        if period == "Custom dates" {
            guard let start = customStart, let end = customEnd else { return nil }
            let first = f.string(from: start), last = f.string(from: end)
            guard first <= last, let s = f.date(from: first), let e = f.date(from: last) else { return nil }
            let span = (calendar.dateComponents([.day], from: s, to: e).day ?? 0) + 1
            return f.string(from: calendar.date(byAdding: .day, value: -span, to: s)!)...f.string(from: calendar.date(byAdding: .day, value: -1, to: s)!)
        }
        if let current = dayBounds(period: period, now: now, timeZone: timeZone),
           let s = f.date(from: current.lowerBound), let e = f.date(from: current.upperBound) {
            let span = (calendar.dateComponents([.day], from: s, to: e).day ?? 0) + 1
            return f.string(from: calendar.date(byAdding: .day, value: -span, to: s)!)...f.string(from: calendar.date(byAdding: .day, value: -1, to: s)!)
        }
        if period.count == 7, let monthStart = f.date(from: period + "-01"),
           let prevMonth = calendar.date(byAdding: .month, value: -1, to: monthStart),
           let prevEnd = calendar.date(byAdding: .day, value: -1, to: monthStart) {
            return f.string(from: prevMonth)...f.string(from: prevEnd)
        }
        return nil
    }

    static func exportCSV(_ rows: [SessionUsageBucket], excludingCacheReads: Bool) -> String {
        func esc(_ s: String) -> String {
            s.contains(",") || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var lines = ["day,provider,model,displayed_tokens,all_tokens,uncached_input,output,cache_read,cache_write,usage_records,priced_records,estimated_usd,pricing_status"]
        let sorted = rows.sorted { $0.id < $1.id }
        for r in sorted {
            let displayed = tokenCount(r.counts, excludingCacheReads: excludingCacheReads)
            let usd = r.pricedEvents == 0 ? "" : String(format: "%.6f", r.estimatedUSD)
            let status = r.pricedEvents == 0 ? "unpriced" : (r.pricedEvents < r.events ? "partial" : "priced")
            lines.append([
                esc(r.day), esc(r.provider), esc(r.model),
                String(displayed), String(r.counts.total),
                String(r.counts.input), String(r.counts.output), String(r.counts.cacheRead), String(r.counts.cacheWrite),
                String(r.events), String(r.pricedEvents), usd, status
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func exportJSON(_ rows: [SessionUsageBucket], period: String, provider: String, model: String, excludingCacheReads: Bool, timeZone: String, pricingVersion: String) -> String {
        let counts = rows.reduce(SessionUsageCounts()) { $0 + $1.counts }
        let events = rows.reduce(0) { $0 + $1.events }
        let priced = rows.reduce(0) { $0 + $1.pricedEvents }
        let usd = rows.reduce(0.0) { $0 + $1.estimatedUSD }
        let payload: [String: Any] = [
            "period": period,
            "providerFilter": provider,
            "modelFilter": model,
            "excludeCacheReads": excludingCacheReads,
            "timeZone": timeZone,
            "pricingVersion": pricingVersion,
            "displayedTokens": tokenCount(counts, excludingCacheReads: excludingCacheReads),
            "allTokens": counts.total,
            "uncachedInput": counts.input,
            "output": counts.output,
            "cacheRead": counts.cacheRead,
            "cacheWrite": counts.cacheWrite,
            "usageRecords": events,
            "pricedRecords": priced,
            "estimatedUSD": priced > 0 ? usd : NSNull(),
            "hasUnpricedRecords": priced < events,
            "buckets": rows.sorted { $0.id < $1.id }.map { r -> [String: Any] in
                [
                    "day": r.day,
                    "provider": r.provider,
                    "model": r.model,
                    "displayedTokens": tokenCount(r.counts, excludingCacheReads: excludingCacheReads),
                    "allTokens": r.counts.total,
                    "input": r.counts.input,
                    "output": r.counts.output,
                    "cacheRead": r.counts.cacheRead,
                    "cacheWrite": r.counts.cacheWrite,
                    "events": r.events,
                    "pricedEvents": r.pricedEvents,
                    "estimatedUSD": r.pricedEvents > 0 ? r.estimatedUSD : NSNull()
                ]
            }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
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
