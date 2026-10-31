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
    /// Optional so a report from an older helper still decodes.
    var cursorFeed: SessionUsageCursorFeedStatus? = nil
}

/// The Cursor account feed, as the helper last left it. Never carries the sign-in.
struct SessionUsageCursorFeedStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case off, ready, backfilling, signIn, expired, blocked, failed, changed }
    var state: State
    /// Plain words for anything other than off or ready.
    var message: String? = nil
    var lastSuccessAt: String? = nil
    /// More history is waiting, so the store refreshes again soon.
    var pending: Bool { state == .backfilling }
    var isProblem: Bool { [.signIn, .expired, .blocked, .failed, .changed].contains(state) }
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
    case newTokens = "New tokens"
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
    /// One bucket's stored estimatedUSD split across the disjoint token categories, reconciling to it.
    struct CategoryUSD: Equatable, Sendable {
        var input = 0.0, output = 0.0, cacheRead = 0.0, cacheWrite = 0.0
        var total: Double { input + output + cacheRead + cacheWrite }
    }
    /// Nil when the bucket cannot be split honestly: a partially priced bucket's dollars cover only some of its
    /// records (Codex cache writes and >272K prompts stay unpriced), so valuing all of its tokens would put dollars
    /// on categories that were never charged. Unpriced buckets and unknown rates are nil too.
    static func categoryUSD(for row: SessionUsageBucket) -> CategoryUSD? {
        guard row.events > 0, row.pricedEvents == row.events, row.estimatedUSD > 0,
              let r = rate(provider: row.provider, model: row.model, prompt: 0) else { return nil }
        let inUSD = Double(row.counts.input) * r.input / 1_000_000
        let outUSD = Double(row.counts.output) * r.output / 1_000_000
        let readUSD = Double(row.counts.cacheRead) * r.read / 1_000_000
        let write5USD = Double(row.counts.cacheWrite) * r.write5 / 1_000_000
        let nonWrite = inUSD + outUSD + readUSD
        // Anthropic 1-hour cache writes raise only cacheWrite above the 5-minute baseline, and never past every
        // write at the 1-hour rate. A remainder above that cap means the stored value used other rates (or the
        // Haiku 5.5 long-prompt tier, which also moves input and output), so the split falls back to scaling.
        if row.provider == "Anthropic", row.counts.cacheWrite > 0, !row.model.hasPrefix("claude-haiku-5-5") {
            let remainder = row.estimatedUSD - nonWrite
            let cap = Double(row.counts.cacheWrite) * r.write1h / 1_000_000
            if remainder >= write5USD * 0.999, remainder <= cap * 1.001 {
                return CategoryUSD(input: inUSD, output: outUSD, cacheRead: readUSD, cacheWrite: max(0, remainder))
            }
        }
        let baseTotal = nonWrite + write5USD
        guard baseTotal > 0 else { return nil }
        let scale = row.estimatedUSD / baseTotal
        let scaledIn = inUSD * scale, scaledOut = outUSD * scale, scaledRead = readUSD * scale
        return CategoryUSD(input: scaledIn, output: scaledOut, cacheRead: scaledRead, cacheWrite: max(0, row.estimatedUSD - scaledIn - scaledOut - scaledRead))
    }
    static func tokens(_ n: Int64) -> String {
        n >= 1_000_000_000 ? String(format: "%.2fB", Double(n)/1e9) : n >= 1_000_000 ? String(format: "%.2fM", Double(n)/1e6) : n >= 1000 ? String(format: "%.1fK", Double(n)/1000) : String(n)
    }
}

/// A ledger date key (yyyy-MM-dd) as a proleptic Gregorian civil date. A calendar date's weekday and month do
/// not depend on a time zone or DST, so week and month keys never build a formatter or touch local midnight.
struct SessionUsageDay: Comparable, Hashable, Sendable {
    let year: Int, month: Int, day: Int
    init?(_ key: String) {
        let parts = key.prefix(10).split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let normalized = SessionUsageDay(serial: Self.serial(y, m, d))
        guard normalized.year == y, normalized.month == m, normalized.day == d else { return nil }
        self = normalized
    }
    /// Days since 1970-01-01 (H. Hinnant's days_from_civil).
    init(serial: Int) {
        let z = serial + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        day = doy - (153 * mp + 2) / 5 + 1
        month = mp < 10 ? mp + 3 : mp - 9
        year = yoe + era * 400 + (month <= 2 ? 1 : 0)
    }
    private static func serial(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
    var serial: Int { Self.serial(year, month, day) }
    /// 0 is Monday. 1970-01-01 was a Thursday.
    var weekdayFromMonday: Int { ((serial + 3) % 7 + 7) % 7 }
    var monday: SessionUsageDay { adding(-weekdayFromMonday) }
    var monthStart: SessionUsageDay { SessionUsageDay(serial: Self.serial(year, month, 1)) }
    var monthEnd: SessionUsageDay {
        SessionUsageDay(serial: (month == 12 ? Self.serial(year + 1, 1, 1) : Self.serial(year, month + 1, 1)) - 1)
    }
    func adding(_ days: Int) -> SessionUsageDay { SessionUsageDay(serial: serial + days) }
    var key: String { String(format: "%04d-%02d-%02d", year, month, day) }
    var monthKey: String { String(format: "%04d-%02d", year, month) }
    static func < (a: Self, b: Self) -> Bool { a.serial < b.serial }
}

/// The provider/model filter. A model row click narrows the provider too; clearing that model restores the
/// provider filter that was in force before, so the provider never stays stranded.
struct SessionUsageSlice: Equatable, Sendable {
    var provider = SessionUsagePresentation.allProviders
    var model = SessionUsagePresentation.allModels
    var providerBeforeModel: String?
    mutating func toggleProvider(_ name: String) {
        provider = provider == name ? SessionUsagePresentation.allProviders : name
        model = SessionUsagePresentation.allModels
        providerBeforeModel = nil
    }
    mutating func toggleModel(provider rowProvider: String, model rowModel: String) {
        if model == rowModel && provider == rowProvider {
            model = SessionUsagePresentation.allModels
            provider = providerBeforeModel ?? provider
            providerBeforeModel = nil
        } else {
            if providerBeforeModel == nil { providerBeforeModel = provider }
            provider = rowProvider
            model = rowModel
        }
    }
    /// Dropdown choices are explicit: nothing is remembered for restoration.
    mutating func choose(provider name: String) { provider = name; providerBeforeModel = nil }
    mutating func choose(model name: String) { model = name; providerBeforeModel = nil }
    mutating func reset() { self = SessionUsageSlice() }
}

/// An inspected chart period, tied to the scale it was chosen on.
struct SessionUsageInspection: Equatable, Sendable {
    var key: String
    var scale: SessionUsageTimeScale
}

/// Presentation math shares the ledger's reporting timezone. Never interprets tokens as plan quota.
enum SessionUsagePresentation {
    static let allProviders = "All tools"
    static let allModels = "All models"
    static let allHistory = "All history"
    static let customDates = "Custom dates"
    static let lastWeekend = "Last weekend"
    static let periods = ["Last 7 days", "Last 30 days", "Last 90 days", lastWeekend, customDates, allHistory]
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
    static func pricingStatus(_ row: SessionUsageBucket) -> String {
        row.pricedEvents == 0 ? "unpriced" : row.pricedEvents < row.events ? "partial" : "priced"
    }
    private static func name(_ row: SessionUsageBucket) -> String { row.provider + "|" + row.model }
    /// One row per provider/model. The day is cleared: an aggregate spans days, and a stable id keeps table rows put.
    static func aggregate(_ rows: [SessionUsageBucket], excludingCacheReads: Bool = false) -> [SessionUsageBucket] {
        Dictionary(grouping: rows, by: name).values.compactMap { group in
            guard let first = group.first else { return nil }
            return SessionUsageBucket(day: "", provider: first.provider, model: first.model,
                counts: group.reduce(SessionUsageCounts()) { $0 + $1.counts }, events: group.reduce(0) { $0 + $1.events },
                pricedEvents: group.reduce(0) { $0 + $1.pricedEvents }, estimatedUSD: group.reduce(0) { $0 + $1.estimatedUSD })
        }.sorted {
            let a = tokenCount($0.counts, excludingCacheReads: excludingCacheReads)
            let b = tokenCount($1.counts, excludingCacheReads: excludingCacheReads)
            return a == b ? name($0) < name($1) : a > b
        }
    }
    /// The natural first direction for a column: names A to Z, numbers largest first.
    static func defaultAscending(_ sort: SessionUsageModelSort) -> Bool { sort == .model }
    static func directionLabel(_ sort: SessionUsageModelSort, ascending: Bool) -> String {
        sort == .model ? (ascending ? "A to Z" : "Z to A") : (ascending ? "Lowest first" : "Highest first")
    }
    static func directionLabel(_ sort: SessionUsageDaySort, ascending: Bool) -> String {
        sort == .date ? (ascending ? "Oldest first" : "Newest first") : (ascending ? "Lowest first" : "Highest first")
    }
    /// Unpriced rows have no API value to rank, so they sort last in both directions. Ties break on provider|model.
    static func sortModels(_ rows: [SessionUsageBucket], by sort: SessionUsageModelSort, ascending: Bool = false, excludingCacheReads: Bool = false) -> [SessionUsageBucket] {
        aggregate(rows, excludingCacheReads: excludingCacheReads).sorted { left, right in
            if sort == .cost, (left.pricedEvents > 0) != (right.pricedEvents > 0) { return left.pricedEvents > 0 }
            if sort == .model {
                let cmp = left.model.localizedCaseInsensitiveCompare(right.model)
                if cmp != .orderedSame { return ascending ? cmp == .orderedAscending : cmp == .orderedDescending }
                return name(left) < name(right)
            }
            let a: Double, b: Double
            switch sort {
            case .tokens:
                a = Double(tokenCount(left.counts, excludingCacheReads: excludingCacheReads))
                b = Double(tokenCount(right.counts, excludingCacheReads: excludingCacheReads))
            case .newTokens:
                a = Double(tokenCount(left.counts, excludingCacheReads: true))
                b = Double(tokenCount(right.counts, excludingCacheReads: true))
            case .cost: a = left.estimatedUSD; b = right.estimatedUSD
            case .records: a = Double(left.events); b = Double(right.events)
            case .cacheShare:
                a = left.counts.total > 0 ? Double(left.counts.cacheRead) / Double(left.counts.total) : 0
                b = right.counts.total > 0 ? Double(right.counts.cacheRead) / Double(right.counts.total) : 0
            case .model: a = 0; b = 0
            }
            if a == b { return name(left) < name(right) }
            return ascending ? a < b : a > b
        }
    }
    static func costLabel(_ rows: [SessionUsageBucket]) -> String {
        let priced = rows.reduce(0) { $0 + $1.pricedEvents }, events = rows.reduce(0) { $0 + $1.events }
        guard priced > 0 else { return "No price" }
        return rows.reduce(0) { $0 + $1.estimatedUSD }.formatted(.currency(code: "USD")) + (priced < events ? "+" : "")
    }
    static func selectPeriod(_ rows: [SessionUsageBucket], period: String, now: Date, timeZone: TimeZone, customStart: Date? = nil, customEnd: Date? = nil) -> [SessionUsageBucket] {
        if period == allHistory { return rows }
        if period == customDates {
            guard let bounds = customBounds(customStart, customEnd, timeZone: timeZone) else { return [] }
            return rows.filter { bounds.contains($0.day) }
        }
        guard let bounds = dayBounds(period: period, now: now, timeZone: timeZone) else {
            return rows.filter { $0.day.hasPrefix(period) }
        }
        // ISO day keys sort chronologically. Compute the boundaries once, not a formatter per row.
        return rows.filter { bounds.contains($0.day) }
    }
    static func includes(day: String, period: String, now: Date, timeZone: TimeZone) -> Bool {
        if period == allHistory { return true }
        return dayBounds(period: period, now: now, timeZone: timeZone)?.contains(day) ?? day.hasPrefix(period)
    }
    static func dayFormatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        f.calendar = calendar; f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"
        return f
    }
    static func reportingCalendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone; calendar.firstWeekday = 2
        return calendar
    }
    /// Noon on a reporting-zone date. Midnight does not exist on some DST transition days (Havana, Santiago).
    static func noon(of key: String, calendar: Calendar) -> Date? {
        guard let d = SessionUsageDay(key) else { return nil }
        return calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: 12))
    }
    /// The reporting-zone date key for an instant (a chart position).
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
    /// The chart date for a period key: its first day (weeks start on their Monday, months on the 1st).
    static func periodStart(_ key: String) -> String { key.count == 7 ? key + "-01" : key }
    static func periodKey(for day: String, scale: SessionUsageTimeScale) -> String {
        switch scale {
        case .daily: return String(day.prefix(10))
        case .monthly: return String(day.prefix(7))
        case .weekly: return SessionUsageDay(day)?.monday.key ?? String(day.prefix(10))
        }
    }
    /// Day to period key, computed once per distinct day for a render or hover pass.
    static func periodKeyMap(_ rows: [SessionUsageBucket], scale: SessionUsageTimeScale) -> [String: String] {
        var map: [String: String] = [:]
        for row in rows where map[row.day] == nil { map[row.day] = periodKey(for: row.day, scale: scale) }
        return map
    }
    private static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    private static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static func short(_ d: SessionUsageDay) -> String { String(monthNames[d.month - 1].prefix(3)) + " \(d.day)" }
    private static func range(_ a: SessionUsageDay, _ b: SessionUsageDay) -> String {
        a.year == b.year ? "\(short(a)) – \(short(b)), \(b.year)" : "\(short(a)), \(a.year) – \(short(b)), \(b.year)"
    }
    static func dateRangeTitle(_ bounds: ClosedRange<String>) -> String {
        guard let a = SessionUsageDay(bounds.lowerBound), let b = SessionUsageDay(bounds.upperBound) else { return "\(bounds.lowerBound) – \(bounds.upperBound)" }
        return a == b ? "\(short(a)), \(a.year)" : range(a, b)
    }
    /// Titles clamp to the selected dates: a boundary week or month says which of its dates are in the selection.
    static func periodTitle(for key: String, scale: SessionUsageTimeScale, within bounds: ClosedRange<String>? = nil) -> String {
        guard let first = SessionUsageDay(periodStart(key)) else { return key }
        let lower = bounds.flatMap { SessionUsageDay($0.lowerBound) }, upper = bounds.flatMap { SessionUsageDay($0.upperBound) }
        func clamp(_ start: SessionUsageDay, _ end: SessionUsageDay) -> (SessionUsageDay, SessionUsageDay) {
            (lower.map { max($0, start) } ?? start, upper.map { min($0, end) } ?? end)
        }
        switch scale {
        case .daily:
            return "\(weekdayNames[first.weekdayFromMonday]), \(short(first)), \(first.year)"
        case .monthly:
            let name = "\(monthNames[first.month - 1]) \(first.year)"
            let (start, end) = clamp(first.monthStart, first.monthEnd)
            return start == first.monthStart && end == first.monthEnd || start > end ? name : "\(name) (\(short(start)) – \(short(end)))"
        case .weekly:
            let sunday = first.adding(6)
            let (start, end) = clamp(first, sunday)
            return start == first && end == sunday || start > end ? "Week of \(range(first, sunday))" : "\(range(start, end)) (partial week)"
        }
    }
    /// The selected period as dates, for clamping titles. Nil for All history.
    static func selectionBounds(period: String, now: Date, timeZone: TimeZone, customStart: Date? = nil, customEnd: Date? = nil) -> ClosedRange<String>? {
        if period == allHistory { return nil }
        if period == customDates { return customBounds(customStart, customEnd, timeZone: timeZone) }
        if let bounds = dayBounds(period: period, now: now, timeZone: timeZone) { return bounds }
        guard let first = SessionUsageDay(period + "-01") else { return nil }
        return first.key...first.monthEnd.key
    }
    /// Keeps an inspection across a scale change only when it still names a period: the same key on its own
    /// scale, or a day carried into the week or month that contains it. Anything else would mislabel the period.
    static func reconcile(_ inspection: SessionUsageInspection?, to scale: SessionUsageTimeScale, keys: [String]) -> SessionUsageInspection? {
        guard let inspection else { return nil }
        if inspection.scale == scale { return keys.contains(inspection.key) ? inspection : nil }
        guard inspection.scale == .daily else { return nil }
        let carried = periodKey(for: inspection.key, scale: scale)
        return keys.contains(carried) ? SessionUsageInspection(key: carried, scale: scale) : nil
    }
    /// All history opens on Monthly. Leaving it restores the scale in use before, unless one was picked there.
    static func timeScale(afterChangingTo period: String, current: SessionUsageTimeScale, remembered: SessionUsageTimeScale?) -> (scale: SessionUsageTimeScale, remembered: SessionUsageTimeScale?) {
        if period == allHistory { return current == .monthly ? (current, remembered) : (.monthly, current) }
        return (remembered ?? current, nil)
    }
    /// Usage records belong to whole observations, not single token categories, so Records never offers Categories.
    static func seriesOptions(for measure: SessionUsageMeasure) -> [SessionUsageSeries] {
        measure == .records ? SessionUsageSeries.allCases.filter { $0 != .categories } : SessionUsageSeries.allCases
    }
    static func series(_ series: SessionUsageSeries, for measure: SessionUsageMeasure) -> SessionUsageSeries {
        seriesOptions(for: measure).contains(series) ? series : .providers
    }
    struct Summary: Identifiable, Sendable {
        let id: String
        let counts: SessionUsageCounts
        let events: Int
        let pricedEvents: Int
        let estimatedUSD: Double
        var costLabel: String {
            guard pricedEvents > 0 else { return "No price" }
            return estimatedUSD.formatted(.currency(code: "USD")) + (pricedEvents < events ? "+" : "")
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
    /// What a person calls the source of a usage row. The ledger's provider stays the stored key and the export
    /// value. Only Claude Code logs say Anthropic, only the account feed says Cursor, and every other provider
    /// comes from a Codex log.
    static func toolName(_ provider: String) -> String {
        switch provider {
        case "Anthropic": return "Claude Code"
        case "OpenAI": return "Codex"
        case "Cursor": return "Cursor"
        default: return "Codex (\(provider))"
        }
    }
    /// "claude-opus-5-5" reads "Opus 5.5". The raw id stays in help text and exports. Unknown ids stay recognizable.
    static func modelName(_ id: String) -> String {
        var name = id.replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        if name.hasPrefix("cursor-") { name.removeFirst(7) }
        var parts = name.split(separator: "-").map(String.init)
        guard parts.count > 1 else { return name }
        func isVersion(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isNumber || $0 == "." } }
        if parts[0] == "claude" {
            parts.removeFirst()
            // Older ids put the version first: claude-4.5-opus-high-thinking.
            if parts.count > 1, isVersion(parts[0]) { parts.swapAt(0, 1) }
            guard let family = parts.first else { return name }
            var version: [String] = []
            var rest = Array(parts.dropFirst())
            while let next = rest.first, isVersion(next) { version.append(next); rest.removeFirst() }
            let head = ([family.capitalized] + (version.isEmpty ? [] : [version.joined(separator: ".")]))
            return (head + rest).joined(separator: " ")
        }
        if parts[0] == "gpt", parts.count > 1 {
            let tail = parts.dropFirst(2).enumerated().map { $0.offset == 0 ? $0.element.capitalized : $0.element }
            return (["GPT-" + parts[1]] + tail).joined(separator: " ")
        }
        return ([parts[0].capitalized] + parts.dropFirst()).joined(separator: " ")
    }
    /// Words for the inspector headline: "78.0 billion".
    static func spokenTokens(_ n: Int64) -> String {
        let v = Double(n)
        if n >= 1_000_000_000 { return String(format: "%.1f billion", v / 1e9) }
        if n >= 1_000_000 { return String(format: v >= 1e8 ? "%.0f million" : "%.1f million", v / 1e6) }
        if n >= 1000 { return String(format: "%.1f thousand", v / 1e3) }
        return n.formatted()
    }
    /// Three significant figures where a table or list has to scan: 74.02B, 602M, 50.4M.
    static func shortTokens(_ n: Int64) -> String {
        let v = Double(n)
        if n >= 1_000_000_000 { return String(format: "%.2fB", v / 1e9) }
        if n >= 100_000_000 { return String(format: "%.0fM", v / 1e6) }
        if n >= 1_000_000 { return String(format: "%.1fM", v / 1e6) }
        if n >= 100_000 { return String(format: "%.0fK", v / 1e3) }
        if n >= 1000 { return String(format: "%.1fK", v / 1e3) }
        return String(n)
    }
    /// Whole dollars. A small amount says so rather than rounding to nothing.
    static func dollars(_ value: Double) -> String {
        value > 0 && value < 1 ? "<$1" : value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }
    /// A table cell's value for rows that may be partly or wholly unpriced.
    static func costCell(_ rows: [SessionUsageBucket]) -> String {
        let priced = rows.reduce(0) { $0 + $1.pricedEvents }, events = rows.reduce(0) { $0 + $1.events }
        guard priced > 0 else { return "No price" }
        return dollars(rows.reduce(0) { $0 + $1.estimatedUSD }) + (priced < events ? "+" : "")
    }
    /// "Oct 19" for a chart axis, "Oct" for a month key.
    static func axisLabel(for key: String) -> String {
        guard let day = SessionUsageDay(periodStart(key)) else { return key }
        let month = String(monthNames[day.month - 1].prefix(3))
        return key.count == 7 ? (day.month == 1 ? "\(month) \(day.year)" : month) : "\(month) \(day.day)"
    }
    /// At most about seven labels across a chart, always starting at the first period.
    static func axisKeys(_ keys: [String]) -> [String] {
        guard keys.count > 7 else { return keys }
        let step = Int((Double(keys.count) / 7).rounded(.up))
        // Never the last period: its label would run off the plot's right edge.
        return stride(from: 0, to: keys.count - 1, by: step).map { keys[$0] }
    }
    /// Series names, largest first. The stack, the legend and the colours all read this order.
    static func seriesOrder(_ totals: [String: Double]) -> [String] {
        totals.keys.sorted { a, b in
            let left = totals[a, default: 0], right = totals[b, default: 0]
            return left == right ? a < b : left > right
        }
    }
    /// The scale a period opens on until someone picks one: bars stay few enough to read.
    static func defaultScale(for period: String) -> SessionUsageTimeScale {
        period == allHistory ? .monthly : period == "Last 90 days" ? .weekly : .daily
    }
    /// A clean top for the chart's axis: four even steps that land on round numbers.
    static func niceAxisTop(_ peak: Double) -> Double {
        guard peak > 0, peak.isFinite else { return 1 }
        let target = peak * 1.04
        let magnitude = pow(10, floor(log10(target)))
        for step in [1.0, 1.2, 1.6, 2, 2.4, 3.2, 4, 6, 8, 10] where step * magnitude >= target { return step * magnitude }
        return 10 * magnitude
    }
    /// "Oct 30" for a compact column, with the year when it is not the year named.
    static func shortDay(_ key: String, thisYear: Int) -> String {
        guard let day = SessionUsageDay(key) else { return key }
        return short(day) + (day.year == thisYear ? "" : ", \(day.year)")
    }
    /// "Sat, Oct 24" for a row that has to scan, with the year when it is not the year named.
    static func weekdayDay(_ key: String, thisYear: Int) -> String {
        guard let day = SessionUsageDay(key) else { return key }
        return String(weekdayNames[day.weekdayFromMonday].prefix(3)) + ", " + shortDay(key, thisYear: thisYear)
    }
    /// The typical bar, leaving out partial ones. Under four full periods an average says nothing a glance does not.
    static func periodAverage(_ totals: [String: Double], partial: Set<String>) -> Double? {
        let full = totals.filter { !partial.contains($0.key) }.map(\.value)
        return full.count >= 4 ? full.reduce(0, +) / Double(full.count) : nil
    }
    /// API value for an average day. A day with no price is left out, never counted as $0, and + says some of the
    /// days counted have unpriced records.
    static func dailyValueLabel(_ rows: [SessionUsageBucket]) -> String {
        let days = summarize(rows, by: \.day).filter { $0.pricedEvents > 0 }
        guard !days.isEmpty else { return "No price" }
        return dollars(days.reduce(0.0) { $0 + $1.estimatedUSD } / Double(days.count)) + (days.contains { $0.pricedEvents < $0.events } ? "+" : "")
    }
    /// The last day each model has a record, keyed like `lastUsedKey`. Built once for a table.
    static func lastUsed(_ rows: [SessionUsageBucket]) -> [String: String] {
        var days: [String: String] = [:]
        for row in rows {
            let key = lastUsedKey(row)
            if row.day > days[key, default: ""] { days[key] = row.day }
        }
        return days
    }
    static func lastUsedKey(_ row: SessionUsageBucket) -> String { row.provider + "|" + row.model }
    /// A partial first or last bar is not a drop in use. Weeks and months that the selection or today cuts short.
    static func partialPeriods(_ keys: [String], scale: SessionUsageTimeScale, firstDay: String?, lastDay: String) -> Set<String> {
        guard scale != .daily, let firstDay else { return [] }
        return Set(keys.filter { key in
            let start: SessionUsageDay?, end: SessionUsageDay?
            if scale == .weekly { start = SessionUsageDay(key); end = start?.adding(6) }
            else { start = SessionUsageDay(periodStart(key)); end = start?.monthEnd }
            guard let start, let end else { return false }
            return start.key < firstDay || end.key > lastDay
        })
    }
    /// Value at list rates for each million new tokens. A row counts only when every record has a price: a row holds
    /// one set of counts, so a partly priced row would divide part of its value by all of its tokens.
    static func valuePerMillionNew(_ rows: [SessionUsageBucket]) -> String {
        let priced = rows.filter { $0.events > 0 && $0.pricedEvents == $0.events }
        let new = priced.reduce(Int64(0)) { $0 + tokenCount($1.counts, excludingCacheReads: true) }
        guard new > 0 else { return "No price" }
        return (priced.reduce(0.0) { $0 + $1.estimatedUSD } / Double(new) * 1e6).formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// One calendar column, Monday to Sunday. A day outside the selection stays blank; a day inside it with no
    /// summary has no logs, which is different from zero.
    struct CalendarDay: Identifiable, Sendable {
        let id: String
        let inRange: Bool
        let summary: Summary?
    }
    struct CalendarWeek: Identifiable, Sendable {
        let id: String
        let monthLabel: String?
        let days: [CalendarDay]
    }
    static func calendarWeeks(_ rows: [SessionUsageBucket], bounds: ClosedRange<String>?, today: String) -> [CalendarWeek] {
        guard let lower = SessionUsageDay(bounds?.lowerBound ?? rows.map(\.day).min() ?? ""),
              let upper = SessionUsageDay(min(bounds?.upperBound ?? today, today)), lower <= upper else { return [] }
        let summaries = Dictionary(uniqueKeysWithValues: summarize(rows, by: \.day).map { ($0.id, $0) })
        var weeks: [CalendarWeek] = []
        var monday = lower.monday
        // A calendar over a year long repeats month names, so its first column and each January carry the year.
        let spansYears = upper.serial - lower.serial > 366
        while monday <= upper {
            // A column is labelled by the month of its first day inside the selection.
            let first = monday < lower ? lower : monday
            let label = String(monthNames[first.month - 1].prefix(3)) + (spansYears && (weeks.isEmpty || first.month == 1) ? " \(first.year)" : "")
            let previous = weeks.last.flatMap { $0.days.first { $0.inRange }?.id }.flatMap { SessionUsageDay($0) }
            let days = (0..<7).map { offset -> CalendarDay in
                let day = monday.adding(offset)
                return CalendarDay(id: day.key, inRange: day >= lower && day <= upper, summary: summaries[day.key])
            }
            weeks.append(CalendarWeek(id: monday.key, monthLabel: previous?.month == first.month ? nil : label, days: days))
            monday = monday.adding(7)
        }
        // A stub first column would run its label into the next month's. A column of four days or more has room.
        if weeks.count > 1, weeks[1].monthLabel != nil, weeks[0].days.filter(\.inRange).count < 4 {
            weeks[0] = CalendarWeek(id: weeks[0].id, monthLabel: nil, days: weeks[0].days)
        }
        return weeks
    }
    /// The average for each weekday, Monday first, across the days `counted` accepts. Measuring value, that leaves out
    /// a day with no price, which would otherwise read as a $0 day and pull the average down.
    static func weekdayAverages(_ rows: [SessionUsageBucket], counted: (Summary) -> Bool, value: (Summary) -> Double) -> [Double] {
        var sums = [Double](repeating: 0, count: 7), days = [Int](repeating: 0, count: 7)
        for summary in summarize(rows, by: \.day) where counted(summary) {
            guard let index = SessionUsageDay(summary.id)?.weekdayFromMonday else { continue }
            sums[index] += value(summary)
            days[index] += 1
        }
        return zip(sums, days).map { $1 > 0 ? $0 / Double($1) : 0 }
    }
    struct MonthPace: Sendable {
        let month: String
        let usd: Double
        let hasPrice: Bool
        let complete: Bool
        /// Straight line from the first day with usage this month. Nil until three days have passed since it, and on the
        /// last day, when nothing is left to project.
        let projectedUSD: Double?
        let lastDay: String
    }
    /// This calendar month so far, for the tool and model in view.
    static func monthPace(_ rows: [SessionUsageBucket], now: Date, timeZone: TimeZone) -> MonthPace? {
        guard let today = SessionUsageDay(dayFormatter(timeZone: timeZone).string(from: now)) else { return nil }
        let month = rows.filter { $0.day.hasPrefix(today.monthKey) }
        let usd = month.reduce(0.0) { $0 + $1.estimatedUSD }
        let priced = month.reduce(0) { $0 + $1.pricedEvents }, events = month.reduce(0) { $0 + $1.events }
        let total = today.monthEnd.day
        // A tool or model that started mid-month is projected from its start, not from the 1st.
        let start = month.compactMap { SessionUsageDay($0.day)?.day }.min() ?? today.day
        let elapsed = today.day - start + 1
        let projected = elapsed >= 3 && today.day < total && priced > 0 ? usd + usd / Double(elapsed) * Double(total - today.day) : nil
        return MonthPace(month: monthNames[today.month - 1], usd: usd, hasPrice: priced > 0, complete: priced == events,
            projectedUSD: projected, lastDay: short(today.monthEnd))
    }

    /// A cost table cell's share of the priced total.
    static func valueShare(_ rows: [SessionUsageBucket], of total: Double) -> String {
        rows.reduce(0) { $0 + $1.pricedEvents } == 0 ? "Unavailable" : costShare(rows.reduce(0) { $0 + $1.estimatedUSD }, of: total)
    }
    /// Words for a token category.
    static func categoryTitle(_ id: String) -> String {
        switch id {
        case "Uncached input": return "Input"
        case "Cache read": return "Read from cache"
        case "Cache write": return "Written to cache"
        default: return id
        }
    }
    struct ToolGroup: Identifiable, Sendable {
        let id: String // the provider key
        let tool: String
        let summary: Summary
        let models: [SessionUsageBucket]
    }
    /// One group per tool, largest first, each holding its models in the chosen order.
    static func toolGroups(_ rows: [SessionUsageBucket], by sort: SessionUsageModelSort, ascending: Bool = false, excludingCacheReads: Bool = false) -> [ToolGroup] {
        summarize(rows, by: \.provider, excludingCacheReads: excludingCacheReads).map { summary in
            ToolGroup(id: summary.id, tool: toolName(summary.id), summary: summary,
                models: sortModels(rows.filter { $0.provider == summary.id }, by: sort, ascending: ascending, excludingCacheReads: excludingCacheReads))
        }
    }
    /// Unpriced days sort last in both directions on API value. Ties break on the earlier date.
    static func sortDays(_ rows: [SessionUsageBucket], by sort: SessionUsageDaySort, ascending: Bool = false, excludingCacheReads: Bool = false) -> [Summary] {
        summarize(rows, by: \.day, excludingCacheReads: excludingCacheReads).sorted { left, right in
            if sort == .date { return ascending ? left.id < right.id : left.id > right.id }
            if sort == .cost, (left.pricedEvents > 0) != (right.pricedEvents > 0) { return left.pricedEvents > 0 }
            let a: Double, b: Double
            switch sort {
            case .tokens:
                a = Double(tokenCount(left.counts, excludingCacheReads: excludingCacheReads))
                b = Double(tokenCount(right.counts, excludingCacheReads: excludingCacheReads))
            case .cost: a = left.estimatedUSD; b = right.estimatedUSD
            case .records: a = Double(left.events); b = Double(right.events)
            case .date: a = 0; b = 0
            }
            if a == b { return left.id < right.id }
            return ascending ? a < b : a > b
        }
    }
    struct TokenCategory: Identifiable, Sendable {
        let id: String
        let count: Int64
        var estimatedUSD: Double = 0
        /// Cache read while Exclude cache reads is on: out of token totals and shares, still in API value.
        var excludedFromTokens = false
    }
    /// The API-value split across categories. Only fully priced buckets can be split (see categoryUSD), so
    /// `splitUSD` can be less than `pricedUSD`; the UI says so instead of inventing the difference.
    struct CostSplit: Sendable {
        var categories = SessionUsagePricing.CategoryUSD()
        var pricedUSD = 0.0
        var unsplitRecords = 0
        var splitUSD: Double { categories.total }
        var isComplete: Bool { unsplitRecords == 0 }
    }
    static func costSplit(_ rows: [SessionUsageBucket]) -> CostSplit {
        var split = CostSplit()
        for row in rows where row.pricedEvents > 0 {
            split.pricedUSD += row.estimatedUSD
            guard let c = SessionUsagePricing.categoryUSD(for: row) else { split.unsplitRecords += row.events; continue }
            split.categories.input += c.input; split.categories.output += c.output
            split.categories.cacheRead += c.cacheRead; split.categories.cacheWrite += c.cacheWrite
        }
        return split
    }
    /// Always the four disjoint categories, so token tiles and the API value bar describe the same set.
    static func tokenMix(_ counts: SessionUsageCounts, excludingCacheReads: Bool, rows: [SessionUsageBucket] = []) -> [TokenCategory] {
        let c = costSplit(rows).categories
        return [
            TokenCategory(id: "Uncached input", count: counts.input, estimatedUSD: c.input),
            TokenCategory(id: "Output", count: counts.output, estimatedUSD: c.output),
            TokenCategory(id: "Cache read", count: counts.cacheRead, estimatedUSD: c.cacheRead, excludedFromTokens: excludingCacheReads),
            TokenCategory(id: "Cache write", count: counts.cacheWrite, estimatedUSD: c.cacheWrite)
        ]
    }
    /// Segment widths for a proportion bar that always sum, with gaps, to exactly `total`. Every positive
    /// fraction gets at least `minimum` so a sliver stays visible; the larger segments give up that room.
    static func segmentWidths(_ fractions: [Double], total: Double, spacing: Double, minimum: Double) -> [Double] {
        let positive = fractions.map { $0.isFinite ? max(0, $0) : 0 }
        let shown = positive.filter { $0 > 0 }.count
        let sum = positive.reduce(0, +)
        guard shown > 0, sum > 0 else { return positive.map { _ in 0 } }
        let available = max(0, total - spacing * Double(shown - 1))
        let floor = min(minimum, available / Double(shown))
        var widths = positive.map { $0 / sum * available }
        let small = widths.indices.filter { positive[$0] > 0 && widths[$0] < floor }
        let largeShare = widths.indices.filter { positive[$0] > 0 && widths[$0] >= floor }.reduce(0.0) { $0 + positive[$1] }
        let remaining = available - floor * Double(small.count)
        for i in widths.indices where positive[i] > 0 {
            widths[i] = small.contains(i) ? floor : (largeShare > 0 ? remaining * positive[i] / largeShare : floor)
        }
        return widths
    }
    /// Hover card x: beside the pointer, on the side with room, never past either edge. `cardWidth` is the
    /// card's full rendered width including its padding.
    static func tooltipX(pointer: Double, cardWidth: Double, containerWidth: Double, gap: Double = 18, margin: Double = 8) -> Double {
        let right = pointer + gap, left = pointer - gap - cardWidth
        let rightFits = right + cardWidth <= containerWidth - margin, leftFits = left >= margin
        if rightFits && (!leftFits || pointer <= containerWidth / 2) { return right }
        if leftFits { return left }
        // Neither side fits: keep the card inside the plot on the side with more room.
        let room = containerWidth - margin - cardWidth
        return pointer > containerWidth / 2 ? margin : max(margin, room)
    }

    struct PeriodComparison: Sendable {
        let dailyAvgTokens: Int64
        let dailyAvgRecords: Int
        let dailyAvgUSD: Double
        let peakDay: Summary?
        let currentRange: ClosedRange<String>?
        let priorRange: ClosedRange<String>?
        /// The current window ends today, so its last date is still collecting usage.
        let includesToday: Bool
        let priorTokens: Int64
        let priorRecords: Int
        let priorUSD: Double
        let priorPriced: Bool
        let hasPriorBaseline: Bool
        let partialPriorHistory: Bool
        /// Either window has records without a verified price, so the API value delta compares priced records only.
        let costDeltaPartial: Bool
        let tokenDeltaLabel: String
        let recordsDeltaLabel: String
        let costDeltaLabel: String
    }

    /// The highest day by the active measure. API value ranks only days with a priced record. Ties go to the earlier date.
    static func peakDay(_ rows: [SessionUsageBucket], measure: SessionUsageMeasure, excludingCacheReads: Bool = false) -> Summary? {
        func value(_ s: Summary) -> Double {
            switch measure {
            case .tokens: return Double(tokenCount(s.counts, excludingCacheReads: excludingCacheReads))
            case .records: return Double(s.events)
            case .cost: return s.estimatedUSD
            }
        }
        let days = summarize(rows, by: \.day, excludingCacheReads: excludingCacheReads)
        return days.filter { measure != .cost || $0.pricedEvents > 0 }.max { a, b in
            value(a) == value(b) ? a.id > b.id : value(a) < value(b)
        }
    }

    static func comparePeriod(allRows: [SessionUsageBucket], selectedRows: [SessionUsageBucket], period: String, provider: String = allProviders, model: String = allModels, measure: SessionUsageMeasure = .tokens, excludingCacheReads: Bool = false, now: Date, timeZone: TimeZone, customStart: Date? = nil, customEnd: Date? = nil) -> PeriodComparison {
        let days = Set(selectedRows.map(\.day)).count
        let curTokens = tokenCount(selectedRows.reduce(SessionUsageCounts()) { $0 + $1.counts }, excludingCacheReads: excludingCacheReads)
        let curEvents = selectedRows.reduce(0) { $0 + $1.events }
        let curPriced = selectedRows.reduce(0) { $0 + $1.pricedEvents }
        let curUSD = selectedRows.reduce(0.0) { $0 + $1.estimatedUSD }
        let avgTokens: Int64 = days > 0 ? curTokens / Int64(days) : 0
        let avgRecords: Int = days > 0 ? Int((Double(curEvents) / Double(days)).rounded()) : 0
        let avgUSD: Double = days > 0 ? curUSD / Double(days) : 0
        let peak = peakDay(selectedRows, measure: measure, excludingCacheReads: excludingCacheReads)
        let today = dayFormatter(timeZone: timeZone).string(from: now)
        guard let windows = comparisonWindows(period: period, now: now, timeZone: timeZone, customStart: customStart, customEnd: customEnd) else {
            return PeriodComparison(dailyAvgTokens: avgTokens, dailyAvgRecords: avgRecords, dailyAvgUSD: avgUSD, peakDay: peak,
                currentRange: nil, priorRange: nil, includesToday: false, priorTokens: 0, priorRecords: 0, priorUSD: 0, priorPriced: false,
                hasPriorBaseline: false, partialPriorHistory: false, costDeltaPartial: false,
                tokenDeltaLabel: "Unavailable", recordsDeltaLabel: "Unavailable", costDeltaLabel: "Unavailable")
        }
        let prior = windows.prior
        let priorRows = allRows.filter {
            prior.contains($0.day) && (provider == allProviders || $0.provider == provider) && (model == allModels || $0.model == model)
        }
        // Each tool in the selection must reach back that far. Cursor's account history starts long before local
        // logs do, so one earliest date across all tools would call a mostly empty prior window complete.
        let selectedProviders = Set(selectedRows.map(\.provider))
        let partialPrior = selectedProviders.isEmpty || selectedProviders.contains { name in
            allRows.filter { $0.provider == name }.map(\.day).min().map { $0 > prior.lowerBound } ?? true
        }
        let pTokens = tokenCount(priorRows.reduce(SessionUsageCounts()) { $0 + $1.counts }, excludingCacheReads: excludingCacheReads)
        let pEvents = priorRows.reduce(0) { $0 + $1.events }
        let pPriced = priorRows.reduce(0) { $0 + $1.pricedEvents }
        let pUSD = priorRows.reduce(0.0) { $0 + $1.estimatedUSD }
        let hasBaseline = !priorRows.isEmpty
        let tokDelta = hasBaseline ? deltaPercent(current: Double(curTokens), prior: Double(pTokens)) : "Unavailable"
        let recDelta = hasBaseline ? deltaPercent(current: Double(curEvents), prior: Double(pEvents)) : "Unavailable"
        let usdDelta = (hasBaseline && curPriced > 0 && pPriced > 0) ? deltaPercent(current: curUSD, prior: pUSD) : "Unavailable"
        return PeriodComparison(dailyAvgTokens: avgTokens, dailyAvgRecords: avgRecords, dailyAvgUSD: avgUSD, peakDay: peak,
            currentRange: windows.current, priorRange: prior, includesToday: windows.current.contains(today),
            priorTokens: pTokens, priorRecords: pEvents, priorUSD: pUSD, priorPriced: pPriced > 0,
            hasPriorBaseline: hasBaseline, partialPriorHistory: partialPrior,
            costDeltaPartial: curPriced < curEvents || pPriced < pEvents,
            tokenDeltaLabel: tokDelta, recordsDeltaLabel: recDelta, costDeltaLabel: usdDelta)
    }

    /// Like-for-like windows. A month in progress compares its elapsed dates with the same dates of the previous
    /// month (clamped to that month's length); a completed month compares with the whole previous month; every
    /// other period compares with the same number of dates immediately before it.
    static func comparisonWindows(period: String, now: Date, timeZone: TimeZone, customStart: Date? = nil, customEnd: Date? = nil) -> (current: ClosedRange<String>, prior: ClosedRange<String>)? {
        if period == allHistory { return nil }
        func shifted(_ bounds: ClosedRange<String>, by span: Int? = nil) -> (ClosedRange<String>, ClosedRange<String>)? {
            guard let s = SessionUsageDay(bounds.lowerBound), let e = SessionUsageDay(bounds.upperBound) else { return nil }
            let days = span ?? (e.serial - s.serial + 1)
            return (bounds, s.adding(-days).key...e.adding(-days).key)
        }
        if period == lastWeekend, let bounds = dayBounds(period: period, now: now, timeZone: timeZone) { return shifted(bounds, by: 7) }
        if period == customDates {
            // A range running past today compares only the dates that have happened, or the prior window would be longer.
            guard let bounds = customBounds(customStart, customEnd, timeZone: timeZone) else { return nil }
            let today = dayFormatter(timeZone: timeZone).string(from: now)
            guard bounds.lowerBound <= today else { return nil }
            return shifted(bounds.lowerBound...min(bounds.upperBound, today))
        }
        if let bounds = dayBounds(period: period, now: now, timeZone: timeZone) { return shifted(bounds) }
        guard let first = SessionUsageDay(period + "-01"), let today = SessionUsageDay(dayFormatter(timeZone: timeZone).string(from: now)) else { return nil }
        let previous = first.adding(-1).monthStart
        if today.monthKey == first.monthKey {
            let elapsed = today.serial - first.serial
            return (first.key...today.key, previous.key...min(previous.adding(elapsed), previous.monthEnd).key)
        }
        return (first.key...first.monthEnd.key, previous.key...previous.monthEnd.key)
    }

    /// Neutralizes spreadsheet formulas (a leading = + - @ tab or carriage return) and quotes per RFC 4180.
    static func csvField(_ value: String) -> String {
        var s = value
        if let c = s.first, "=+-@\t\r".contains(c) { s = "'" + s }
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func exportCSV(_ rows: [SessionUsageBucket], excludingCacheReads: Bool) -> String {
        var lines = ["day,provider,model,displayed_tokens,all_tokens,uncached_input,output,cache_read,cache_write,usage_records,priced_records,estimated_usd,pricing_status"]
        for r in rows.sorted(by: { $0.id < $1.id }) {
            let usd = r.pricedEvents == 0 ? "" : String(format: "%.6f", r.estimatedUSD)
            lines.append([
                csvField(r.day), csvField(r.provider), csvField(r.model),
                String(tokenCount(r.counts, excludingCacheReads: excludingCacheReads)), String(r.counts.total),
                String(r.counts.input), String(r.counts.output), String(r.counts.cacheRead), String(r.counts.cacheWrite),
                String(r.events), String(r.pricedEvents), usd, pricingStatus(r)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// What the Active slice bar describes, so an export carries the same scope.
    struct ExportContext: Sendable {
        var period: String
        var customStart: String?
        var customEnd: String?
        var provider: String
        var model: String
        var excludingCacheReads: Bool
        var timeScale: SessionUsageTimeScale
        var inspection: SessionUsageInspection?
        var inspectedTitle: String?
        var timeZone: String
        var pricingVersion: String
    }

    /// The rows an export copies: the filtered selection, narrowed to the inspected period when there is one.
    static func exportRows(_ selected: [SessionUsageBucket], inspection: SessionUsageInspection?) -> [SessionUsageBucket] {
        guard let inspection else { return selected }
        return selected.filter { periodKey(for: $0.day, scale: inspection.scale) == inspection.key }
    }

    static func exportJSON(_ rows: [SessionUsageBucket], context: ExportContext) -> String {
        let counts = rows.reduce(SessionUsageCounts()) { $0 + $1.counts }
        let events = rows.reduce(0) { $0 + $1.events }
        let priced = rows.reduce(0) { $0 + $1.pricedEvents }
        let usd = rows.reduce(0.0) { $0 + $1.estimatedUSD }
        let excluding = context.excludingCacheReads
        let payload: [String: Any] = [
            "period": context.period,
            "customStart": context.customStart ?? NSNull(),
            "customEnd": context.customEnd ?? NSNull(),
            "providerFilter": context.provider,
            "modelFilter": context.model,
            "excludeCacheReads": excluding,
            "timeScale": context.timeScale.rawValue,
            "inspectedPeriod": context.inspection?.key ?? NSNull(),
            "inspectedPeriodScale": context.inspection?.scale.rawValue ?? NSNull(),
            "inspectedPeriodTitle": context.inspectedTitle ?? NSNull(),
            "timeZone": context.timeZone,
            "pricingVersion": context.pricingVersion,
            "displayedTokens": tokenCount(counts, excludingCacheReads: excluding),
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
                    "displayedTokens": tokenCount(r.counts, excludingCacheReads: excluding),
                    "allTokens": r.counts.total,
                    "input": r.counts.input,
                    "output": r.counts.output,
                    "cacheRead": r.counts.cacheRead,
                    "cacheWrite": r.counts.cacheWrite,
                    "events": r.events,
                    "pricedEvents": r.pricedEvents,
                    "pricingStatus": pricingStatus(r),
                    "estimatedUSD": r.pricedEvents > 0 ? r.estimatedUSD : NSNull()
                ]
            }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func customBounds(_ start: Date?, _ end: Date?, timeZone: TimeZone) -> ClosedRange<String>? {
        guard let start, let end else { return nil }
        let f = dayFormatter(timeZone: timeZone)
        let first = f.string(from: start), last = f.string(from: end)
        return first <= last ? first...last : nil
    }

    private static func dayBounds(period: String, now: Date, timeZone: TimeZone) -> ClosedRange<String>? {
        let counts = ["Last 7 days": 7, "Last 30 days": 30, "Last 90 days": 90]
        guard counts[period] != nil || period == lastWeekend,
              let today = SessionUsageDay(dayFormatter(timeZone: timeZone).string(from: now)) else { return nil }
        if let count = counts[period] { return today.adding(1 - count).key...today.key }
        // Most recent completed Saturday/Sunday pair; on a weekend use the previous one.
        let monday = today.monday
        return monday.adding(-2).key...monday.adding(-1).key
    }
}
