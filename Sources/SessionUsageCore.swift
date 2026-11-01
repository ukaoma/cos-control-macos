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
    /// Another command held the history, so this pass read nothing new. Set only on a busy answer from SQLite, never on
    /// a failure. The page keeps what it has, and the store counts these so it can back off.
    var historyBusy: Bool? = nil
}

/// The Cursor account feed, as the helper last left it. Never carries the sign-in.
struct SessionUsageCursorFeedStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case off, ready, backfilling, signIn, expired, blocked, keychainBusy, failed, changed }
    var state: State
    /// Plain words for anything other than off or ready.
    var message: String? = nil
    var lastSuccessAt: String? = nil
    /// More history is waiting, so the store refreshes again soon.
    var pending: Bool { state == .backfilling }
    var isProblem: Bool { [.signIn, .expired, .blocked, .keychainBusy, .failed, .changed].contains(state) }
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
    /// Measuring value, a day or period with no price has no figure. It is left out, never drawn or averaged as $0.
    static func hasFigure(_ measure: SessionUsageMeasure, pricedEvents: Int) -> Bool { measure != .cost || pricedEvents > 0 }
    static func dayCounted(_ summary: Summary, measure: SessionUsageMeasure) -> Bool { hasFigure(measure, pricedEvents: summary.pricedEvents) }
    /// One series' part of one chart period.
    struct PeriodPortion: Sendable {
        let key: String
        let pricedEvents: Int
        let value: Double
    }
    /// The chart's average line, and the one thing that may promise it. Lines draw none.
    static func chartAverage(_ portions: [PeriodPortion], measure: SessionUsageMeasure, partial: Set<String>, lineChart: Bool) -> Double? {
        guard !lineChart else { return nil }
        var totals: [String: Double] = [:]
        for portion in portions where !portion.key.isEmpty && hasFigure(measure, pricedEvents: portion.pricedEvents) {
            totals[portion.key, default: 0] += portion.value
        }
        return periodAverage(totals, partial: partial)
    }
    /// The legend line for lighter bars. It mentions the average only when a line is drawn to be left out of.
    static func partialBarsNote(scaleWord: String, averageDrawn: Bool) -> String {
        "Lighter bars cover part of a \(scaleWord)" + (averageDrawn ? " and are left out of the average." : ".")
    }

    // MARK: Paused and Cursor words. A paused pass reads nothing and stamps the report now, so these cannot imply a read.

    /// The helper call for a refresh. Paused never imports, whoever asks, and the helper ignores --cursor-now on a read-only pass.
    /// The loop's two paces, in seconds: soon, while log files are still pending, and slow otherwise.
    static let pendingSeconds = 15
    static let slowSeconds = 300
    /// Busy passes in a row that still come back at the pending pace: five minutes of them. Past that, something is holding
    /// the history and the slow pace spares it, instead of starting a decoder every 15 seconds for as long as that lasts.
    static let busyRetryLimit = 20
    /// Said on the page once the busy streak reaches the limit and the loop slows to the slow pace.
    static var heldNote: String { "Another COS command is holding the usage history, so Usage waits \(slowSeconds / 60) minutes before it tries again." }
    static func isHeld(busyPasses: Int) -> Bool { busyPasses >= busyRetryLimit }
    /// How long to wait after a pass, and the busy passes in a row so far. A busy pass keeps no progress and is not an error.
    static func wait(pending: Bool, busy: Bool, busyPasses: Int) -> (seconds: Int, busyPasses: Int) {
        let passes = busy ? busyPasses + 1 : 0
        return (pending && passes < busyRetryLimit ? pendingSeconds : slowSeconds, passes)
    }
    static func helperArguments(importNew: Bool, tracking: Bool, cursorEnabled: Bool, cursorNow: Bool) -> [String] {
        let importing = importNew && tracking
        var arguments = importing ? ["session-usage"] : ["session-usage", "--read-only"]
        if cursorEnabled { arguments.append("--cursor") }
        if cursorEnabled && cursorNow && importing { arguments.append("--cursor-now") }
        return arguments
    }
    /// Beside the filters. Nil hides it.
    static func freshnessLabel(tracking: Bool, updatedTime: String?) -> String? {
        tracking ? updatedTime.map { "Updated \($0)" } : "Paused"
    }
    /// The lines that promise the totals will grow. Paused nothing is reading, so there are none.
    static func pendingNotes(tracking: Bool, pendingFiles: Int, feedMessage: String?) -> [String] {
        guard tracking else { return [] }
        var notes: [String] = []
        if pendingFiles > 0 { notes.append("Reading older history: \(pendingFiles) files remaining. Totals will grow until it finishes.") }
        if let feedMessage { notes.append(feedMessage + " Totals will grow until it finishes.") }
        return notes
    }
    static func pausedLine(pendingFiles: Int, hasHistory: Bool = true) -> String {
        (hasHistory ? "Tracking is paused, so no new logs are being read and these numbers stop at the last read." : "Tracking is paused, so no logs are being read.")
            + (pendingFiles > 0 ? " \(pendingFiles.formatted()) log \(pendingFiles == 1 ? "file is" : "files are") still waiting." : "")
    }
    /// The page with no history to show.
    static func emptyWords(tracking: Bool, hasReport: Bool) -> String {
        switch (tracking, hasReport) {
        case (true, false): return "Usage has not been read yet. Refresh reads Claude Code and Codex logs on this Mac."
        case (true, true): return "No usage recorded yet. Claude Code and Codex sessions on this Mac appear here once their logs are read. A missing tool is not zero usage."
        case (false, false): return "Usage has not been read yet. Resume tracking to read Claude Code and Codex logs on this Mac."
        case (false, true): return "Nothing has been read yet. Claude Code and Codex sessions on this Mac appear here after you resume tracking. A missing tool is not zero usage."
        }
    }
    static let cursorWaiting = "Cursor is on. Nothing is read from Keychain or Cursor until tracking resumes."
    /// Cursor's official installer (ProviderConnectModel.installCommand). Tests/session-usage-pins.py holds the two together.
    static let cursorInstallCommand = "curl https://cursor.com/install -fsS | bash"
    /// Cursor's command line, as a real file. Control opened from Finder has no login PATH, and the app alone does not
    /// install it. It answers to two names (ProviderStatusCore.names).
    static func cursorCommandLine(home: String, systemFolders: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) -> String? {
        let names = ["cursor-agent", "agent"]
        let manager = FileManager.default
        for folder in ["\(home)/.local/bin"] + systemFolders {
            for name in names {
                let path = folder + "/" + name
                var isFolder: ObjCBool = false
                if manager.fileExists(atPath: path, isDirectory: &isFolder), !isFolder.boolValue, manager.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }
    /// A full path, so it runs from a Terminal whose PATH does not have it.
    static func cursorSignInCommand(_ path: String) -> String {
        (path.contains(" ") ? "'\(path)'" : path) + " login"
    }
    /// What is wrong with the feed, in words that can be acted on from here, or nil. Sign-in repair needs the command
    /// line, so without it the next step is getting it.
    static func cursorProblem(_ feed: SessionUsageCursorFeedStatus?, commandLine: String?, tracking: Bool) -> String? {
        guard let feed, feed.isProblem else { return nil }
        if commandLine == nil, feed.state == .signIn || feed.state == .expired {
            return "Counting Cursor needs its command line, and the Cursor app does not install it. Run \(cursorInstallCommand) in Terminal, then cursor-agent login, then \(tracking ? "refresh" : "resume tracking")."
        }
        return feed.message
    }
    /// The table's Cursor row, when Cursor has no rows yet.
    static func cursorWords(on: Bool, tracking: Bool, feed: SessionUsageCursorFeedStatus?, commandLine: String?) -> String {
        guard on else {
            return "Cursor keeps its token counts on its servers. Counting them reads your Cursor sign-in from this Mac's Keychain and asks Cursor for your usage."
                + (tracking ? "" : " Turning it on now saves the choice, and it waits until tracking resumes.")
        }
        if let problem = cursorProblem(feed, commandLine: commandLine, tracking: tracking) { return problem }
        guard tracking else { return cursorWaiting }
        return feed?.state == .ready ? "Cursor reports no token usage for this account." : feed?.message ?? "Reading your Cursor usage."
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
    /// What fits across a calendar's width. Past a year the gaps tighten, and no square goes under `calendarMinimumCell`:
    /// the most recent weeks that fit stay and the oldest drop off. Scrolling sideways was the other choice, but it would
    /// split each weekday row from its name and its average and put a second scroller inside a scrolling page.
    struct CalendarFit: Sendable {
        let weeks: [CalendarWeek]
        let spacing: Double
        let carriesNumbers: Bool
        let cell: Double
    }
    static let calendarMinimumCell = 4.0
    /// Over the real width of an 11 pt label, so a thinned row never touches. Checked against rendered pages.
    static func calendarLabelWidth(_ label: String) -> Double { Double(label.count) * 6.5 + 2 }
    static func calendarFit(_ all: [CalendarWeek], width: Double) -> CalendarFit {
        let spacing = all.count > 52 ? 1.0 : 3.0
        // Not measured yet: everything, labels as built. The first layout pass replaces it before anything is drawn.
        guard width > 0, !all.isEmpty else { return CalendarFit(weeks: all, spacing: spacing, carriesNumbers: false, cell: 0) }
        let fits = max(1, Int((width + spacing) / (calendarMinimumCell + spacing)))
        var weeks = Array(all.suffix(fits))
        // A cut calendar starts mid-history, so its first column says where it starts, with the year.
        if weeks.count < all.count, let first = weeks[0].days.first(where: \.inRange), let day = SessionUsageDay(first.id) {
            weeks[0] = CalendarWeek(id: weeks[0].id, monthLabel: String(monthNames[day.month - 1].prefix(3)) + " \(day.year)", days: weeks[0].days)
        }
        let pitch = (width + spacing) / Double(weeks.count)
        // Years first, so a month never pushes a year out. The rest fill the room that is left, in order.
        var kept: [(start: Double, end: Double)] = []
        var labels: [Int: String] = [:]
        let labelled = weeks.indices.compactMap { index in weeks[index].monthLabel.map { (index, $0) } }
        for (index, label) in labelled.filter({ $0.1.contains(" ") }) + labelled.filter({ !$0.1.contains(" ") }) {
            let start = Double(index) * pitch, end = start + calendarLabelWidth(label)
            guard !kept.contains(where: { start < $0.end + 4 && $0.start < end + 4 }), end <= width + 8 else { continue }
            kept.append((start, end))
            labels[index] = label
        }
        let thinned = weeks.indices.map { CalendarWeek(id: weeks[$0].id, monthLabel: labels[$0], days: weeks[$0].days) }
        return CalendarFit(weeks: thinned, spacing: spacing, carriesNumbers: width / Double(weeks.count) - spacing >= 44,
                           cell: (width - spacing * Double(weeks.count - 1)) / Double(weeks.count))
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
        /// Straight line from the first day with usage this month. Nil before its third day, counting that first day as
        /// one, on the last day, when nothing is left to project, and while paused, when the days are not a real pace.
        let projectedUSD: Double?
        let lastDay: String
    }
    /// This calendar month so far, for the tool and model in view.
    static func monthPace(_ rows: [SessionUsageBucket], now: Date, timeZone: TimeZone, tracking: Bool = true) -> MonthPace? {
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
            projectedUSD: tracking ? projected : nil, lastDay: short(today.monthEnd))
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
        let peak = peakDay(selectedRows, measure: measure, excludingCacheReads: excludingCacheReads)
        let today = dayFormatter(timeZone: timeZone).string(from: now)
        guard let windows = comparisonWindows(period: period, now: now, timeZone: timeZone, customStart: customStart, customEnd: customEnd) else {
            return PeriodComparison(dailyAvgTokens: avgTokens, dailyAvgRecords: avgRecords, peakDay: peak,
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
        return PeriodComparison(dailyAvgTokens: avgTokens, dailyAvgRecords: avgRecords, peakDay: peak,
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

// MARK: - COS cost: what COS itself used, on top of the sessions a person runs (0.5.359)
//
// Everything here is pure and Foundation-only, because the helper compiles this file too. The helper does the reading,
// the rules live here, and Tests/SessionUsageChecks.swift pins them on fixtures. Counts only: a report never carries a
// prompt, a reply, an id or a hash.

enum CosCostCategory: String, Codable, CaseIterable, Sendable {
    case dictation, transcription, dictationBeforeSplit, meetingNotes, answers, liveAndUpkeep, memoryIndexing, other, work
    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .transcription: return "Transcription cleanup"
        case .dictationBeforeSplit: return "Dictation and transcripts, before Oct 20"
        case .meetingNotes: return "Meeting notes"
        case .answers: return "Answers"
        case .liveAndUpkeep: return "Live help and upkeep"
        case .memoryIndexing: return "Memory indexing"
        case .other: return "Other"
        case .work: return "Work"
        }
    }
    /// What a person got, in words. Plain counts, so a row reads as work done before it reads as money.
    func count(_ n: Int) -> String {
        let one = n == 1
        let word: String
        switch self {
        case .dictation: word = one ? "dictation" : "dictations"
        case .transcription, .dictationBeforeSplit: word = one ? "cleanup" : "cleanups"
        case .meetingNotes: word = one ? "note or summary" : "notes and summaries"
        case .answers: word = one ? "answer" : "answers"
        case .liveAndUpkeep: word = one ? "check" : "checks"
        case .memoryIndexing: word = one ? "indexing call" : "indexing calls"
        case .other: word = one ? "other call" : "other calls"
        case .work: word = one ? "background call" : "background calls"
        }
        return n.formatted() + " " + word
    }
}

/// One category over the window. Every call is either measured or has only character counts, never both.
struct CosCostRow: Codable, Equatable, Sendable {
    var category: CosCostCategory
    var calls = 0
    var measuredCalls = 0
    /// Priced part of the measured calls. Never includes an estimate.
    var measuredUSD = 0.0
    var measuredTokens: Int64 = 0
    /// Measured, with no verified rate for the model.
    var unpricedMeasuredCalls = 0
    /// Tokens from a day ledger that has no price at all (no call count exists for these). The dollars leave them out.
    var unpricedLedgerTokens: Int64 = 0
    /// Calls with only character counts. Chars over four, so cache reads and system prompts are not in them.
    var estimatedCalls = 0
    /// A floor at verified rates, for the estimated calls that have one. Stays out of every measured figure.
    var estimatedUSD = 0.0
    var estimatedPricedCalls = 0
    var estimatedTokens: Int64 = 0
    /// Measured dollars Usage's own total cannot see, so the total a person ran has to add them.
    var addsToTotalUSD = 0.0
    /// Measured dollars that ran through Cursor. Usage already holds them when the Cursor feed is on.
    var addsUnlessCursorFeedUSD = 0.0
    /// Calls joined to their run by time and model, because the row has no id. Disclosed as approximate.
    var approximateMatches = 0
}

/// How far the bounded read of Work and G2 session logs has got.
struct CosSliceProgress: Codable, Equatable, Sendable {
    var tracked = 0
    /// Sessions with bytes still to read. The page says so, and the next pass carries on.
    var stillReading = 0
    /// Sessions whose log is gone from this Mac.
    var noLogs = 0
    /// Sessions whose only log is compressed and cannot be read: no Node here can open it, or the file cannot be trusted.
    var compressed = 0
    /// The usage history was busy, so this pass read nothing new.
    var busy = false
    /// The usage history could not be read, and not because it was busy: a full disk, a damaged file. Not reading either,
    /// since trying again in seconds would not help; the next try is at the slow pace.
    var failed = false
    /// What is still to read is not known after a busy pass, which keeps no progress, so busy counts as reading: the page says
    /// "so far" and the next pass comes soon.
    var reading: Bool { stillReading > 0 || busy }
}

struct CosWorkSummary: Codable, Equatable, Sendable {
    var handoffsFound = false
    var runs = 0
    /// The Work run itself: from its start until the person next typed in that session, or its last turn ended.
    var measuredUSD = 0.0
    var measuredTokens: Int64 = 0
    var unpricedEvents = 0
    /// The wider figure: everything in those sessions from the first run's start, including what the person did later.
    /// Said on the page, and never in a share.
    var widerUSD = 0.0
    var widerTokens: Int64 = 0
    /// Events in the wider figure with no verified rate. The figure leaves them out, so it ends in a +.
    var widerUnpricedEvents = 0
    /// Runs with usage after they started and neither a typed turn nor a finished turn to end them. Only in the wider figure.
    var unprovenRuns = 0
    /// What Usage cannot price, for the total. Covers everything in those sessions, because Usage's total does.
    var addsToTotalUSD = 0.0
    /// Runs with no log COS can read: a tool that keeps none, such as Cursor, or a session with no rows after the start.
    var runsWithoutLogs = 0
}

struct CosUsageReport: Codable, Equatable, Sendable {
    var windowStart: String
    var windowEnd: String
    var timeZone: String
    var updatedAt: String
    var auditFound = false
    /// The audit file is there and could not be opened. Its calls are missing from every figure, and the page says so.
    var auditUnreadable = false
    var runLedgersFound = false
    var gistLedgerFound = false
    var rows: [CosCostRow] = []
    var work = CosWorkSummary()
    var sessions = CosSliceProgress()
    /// Rows with no readable date. Counted here because no window can hold them. Never dropped silently.
    var undatedCalls = 0
    /// Lines of a ledger that could not be read at all.
    var unreadableRows = 0
    var ratesCheckedOn = CosCostRates.checkedOn
}

/// Verified rates the Usage card does not hold yet. Read at view time only: stored `usd` values never change.
enum CosCostRates {
    static let checkedOn = "2026-10-31"
    /// OpenAI: standard tier, read from the raw page 2026-10-31 (https://developers.openai.com/api/docs/pricing). The page
    /// marks gpt-5.6-sol as a promotional price, at least through 2026-11-21 (`through`: the last day the rate is verified).
    /// Prices over 272K context stay unpriced, and so does a row with cache writes, as they do on the Usage card.
    private static let openAI: [String: (input: Double, read: Double, output: Double, through: String?)] = [
        "gpt-5.6-terra": (2, 0.2, 12, nil),
        "gpt-5.6-sol": (4, 0.4, 20, "2026-11-21"),
        "gpt-5.6-luna": (0.2, 0.02, 1.2, nil),
        "gpt-5.5": (5, 0.5, 30, nil),
        "gpt-6-sol": (2, 0.2, 10, nil),
        "gpt-6.1-terra": (1, 0.05, 5, nil),
    ]
    /// TypeSafe Jev: $42 per billion input tokens (server/lib/jev.ts, glasses-server a921078, read 2026-10-31).
    static let jevPerInputToken = 42.0 / 1_000_000_000

    /// The Usage card first, then the verified additions. Nil means No price, never $0.
    /// `on` is when the usage happened, in epoch seconds, for a rate that ends. Nil means now.
    static func usd(provider: String, model: String, counts: SessionUsageCounts, oneHour: Int64 = 0, on instant: Double? = nil) -> Double? {
        if let known = SessionUsagePricing.estimate(provider: provider, model: model, counts: counts, oneHour: oneHour) { return known }
        return extraUSD(provider: provider, model: model, counts: counts, on: instant)
    }
    /// Priced only by the additions, so Usage's own total does not hold this spend. A promotional rate prices only usage up to its
    /// last verified day: after it the page may say anything, so there is no price rather than an old one.
    static func extraUSD(provider: String, model: String, counts: SessionUsageCounts, on instant: Double? = nil) -> Double? {
        guard provider == "OpenAI", counts.cacheWrite == 0, counts.input + counts.cacheRead <= 272_000,
              let r = openAI[model] else { return nil }
        if let through = r.through, (instant ?? Date().timeIntervalSince1970) > (CosCostRules.epoch(through + "T23:59:59Z") ?? 0) { return nil }
        return (Double(counts.input)*r.input + Double(counts.cacheRead)*r.read + Double(counts.output)*r.output) / 1_000_000
    }
    /// What a ledger's model string names, or nil when it names nothing with a fixed price: a tier, a router, a local
    /// model. A bare alias maps to today's model, which is approximate for old rows. A measured row on a bare alias is priced at that model too, so its dollars are measured tokens at today's rate.
    static func resolve(_ ledgerModel: String) -> (provider: String, model: String)? {
        var name = ledgerModel.trimmingCharacters(in: .whitespaces)
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) } // claude-opus-5-5[1m]
        var harness = ""
        if let colon = name.firstIndex(of: ":") { harness = String(name[..<colon]); name = String(name[name.index(after: colon)...]) }
        switch harness {
        case "", "claude":
            switch name {
            case "opus": return ("Anthropic", "claude-opus-5-5")
            case "sonnet": return ("Anthropic", "claude-sonnet-5-5")
            case "haiku": return ("Anthropic", "claude-haiku-5-5")
            case "fable": return ("Anthropic", "claude-fable-5-1")
            default:
                if name.hasPrefix("claude-") { return ("Anthropic", name) }
                return harness.isEmpty && name.hasPrefix("gpt-") ? ("OpenAI", name) : nil
            }
        case "codex":
            return name.hasPrefix("gpt-") ? ("OpenAI", name) : nil // codex:sonnet names a tier, not a price
        default:
            return nil
        }
    }
    /// A floor for a call with only character counts: its tokens at the plain input and output rates, no cache.
    static func estimateUSD(ledgerModel: String, input: Int64, output: Int64, on instant: Double? = nil) -> Double? {
        if ledgerModel.hasPrefix("jev-") { return Double(input) * jevPerInputToken }
        guard let resolved = resolve(ledgerModel) else { return nil }
        return usd(provider: resolved.provider, model: resolved.model, counts: SessionUsageCounts(input: input, output: output), on: instant)
    }
}

/// The classification and data rules, spelled out once.
enum CosCostRules {
    /// The first day the dictation and meeting rows have callers of their own. Older plain rows are both.
    static let splitDay = "2026-10-20"
    static let windowPeriod = "Last 30 days"

    /// Where a call goes. Caller first, because a source can be shared: Work chat is written with a Meeting Ask source
    /// and a routine with a G2 source. Anything not named here is Other, in plain sight.
    static func category(source: String, caller: String, day: String) -> CosCostCategory {
        let c = caller.lowercased(), s = source.lowercased()
        if c.hasPrefix("work_") || c.hasPrefix("work-") || c == "dispatch_task" || c.hasPrefix("attached_turn") || c.hasPrefix("fork_thread") || s == "g2-attached" || s == "g2-fork" { return .work }
        if c == "dictation_autoclean" { return day < splitDay ? .dictationBeforeSplit : .dictation }
        if c == "dictation_autoclean_meeting" || c.hasPrefix("transcript-cleanup") || c.hasPrefix("transcript_cleanup") || c.hasPrefix("whisper") { return .transcription }
        if c.hasPrefix("dictation_autoclean_") || c == "prompt_edit" { return .dictation }
        if ["chat_summary", "day_summary", "g2_title_gen", "meeting_summary", "summary", "domain_intel_extract", "process_combined",
            "classify_meeting", "extract_actions", "task_status_detect", "task_promote_completions"].contains(c) { return .meetingNotes }
        if c.hasPrefix("live-cues") || c.hasPrefix("routine:") || c == "lens_gist" || c == "prewarm" || c == "proof" { return .liveAndUpkeep }
        if c == "full_query" || c == "voice_query" || c == "direct_query" || c == "live-cos-ask" || c.hasPrefix("meeting_ask") || c.hasPrefix("meeting_fact_check") { return .answers }
        if c.hasPrefix("lightrag") || c.hasPrefix("memory") || c.hasPrefix("embedding") || c.hasPrefix("rerank") || c.hasPrefix("briefing_") { return .memoryIndexing }
        if s == "g2-dictation-autoclean" { return day < splitDay ? .dictationBeforeSplit : .dictation }
        if s == "g2-archive" { return .meetingNotes }
        if s.hasPrefix("live-cues") || s == "g2-lens-gist" || s == "g2-prewarm" { return .liveAndUpkeep }
        if s == "g2-query" || s == "g2-voice" || s == "live-cos-ask" || s.hasPrefix("meeting-ask") { return .answers }
        return .other
    }
    /// Whether a source's spend lands in the session logs Usage reads. These run with a saved session; polish, gist, Ask,
    /// cleanup, cues, Work chat, summaries and `llm_client` run with --no-session-persistence, so Usage cannot see them.
    static func inSessionLogs(source: String, caller: String, model: String = "") -> Bool {
        let c = baseCaller(caller).lowercased(), s = source.lowercased()
        // Dispatch runs with a G2 source but --no-session-persistence, so the caller has to win. A Claude review runs
        // the same restricted way (work-review-runtime.ts); a Codex one keeps its rollout.
        if c == "dispatch_task" { return false }
        if c == "work_review" { return model.lowercased().hasPrefix("codex") || model.lowercased().hasPrefix("gpt-") }
        if ["full_query", "voice_query", "prewarm", "chat_summary", "day_summary", "proof"].contains(c) { return true }
        if c.hasPrefix("attached_turn") || c.hasPrefix("fork_thread") { return true }
        return ["g2-query", "g2-voice", "g2-prewarm", "g2-archive", "g2-attached", "g2-fork"].contains(s)
    }
    /// A steer can yield several results. The extra usage is written as `<caller>:late_result` under the same run: more
    /// usage on a call already counted, never another call.
    static let lateSuffix = ":late_result"
    static func isLate(_ caller: String) -> Bool { caller.hasSuffix(lateSuffix) }
    static func baseCaller(_ caller: String) -> String { isLate(caller) ? String(caller.dropLast(lateSuffix.count)) : caller }
    /// Cursor bills these, including Luna polish, which runs through the Cursor command line. With the Cursor feed on,
    /// the feed already put them in Usage's total, so adding them again would count them twice. With it off, Usage has no
    /// sight of them and the total has to add them. The numerator counts them once either way.
    static func runsThroughCursor(model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("cursor") || m.hasPrefix("luna")
    }
    /// `2026-10-30T12:05:01-0500`, `-05:00`, `.123Z`. Python and Node write different zones into one file. A row with no
    /// zone names no instant, so it reads as undated rather than as a guess at the local time.
    static func epoch(_ stamp: String) -> Double? {
        let u = Array(stamp.utf8)
        guard u.count >= 20, u[10] == 84 || u[10] == 32, u[13] == 58, u[16] == 58,
              let day = SessionUsageDay(String(decoding: u[0..<10], as: UTF8.self)) else { return nil }
        func two(_ at: Int) -> Int? {
            guard at + 1 < u.count, (48...57).contains(u[at]), (48...57).contains(u[at+1]) else { return nil }
            return Int(u[at] - 48) * 10 + Int(u[at+1] - 48)
        }
        guard let hour = two(11), let minute = two(14), let second = two(17), hour < 24, minute < 60, second <= 60 else { return nil }
        var i = 19
        var fraction = 0.0
        if u[i] == 46 {
            i += 1
            var scale = 0.1
            let start = i
            while i < u.count, (48...57).contains(u[i]) { fraction += Double(u[i] - 48) * scale; scale /= 10; i += 1 }
            guard i > start else { return nil }
        }
        guard i < u.count else { return nil }
        var offset = 0
        if u[i] == 90 || u[i] == 122 {
            guard i == u.count - 1 else { return nil }
        } else if u[i] == 43 || u[i] == 45 {
            let sign = u[i] == 45 ? -1 : 1
            i += 1
            guard let h = two(i), h < 24 else { return nil }
            i += 2
            var m = 0
            if i < u.count {
                if u[i] == 58 { i += 1 }
                guard let parsed = two(i), parsed < 60 else { return nil }
                m = parsed
                i += 2
            }
            guard i == u.count else { return nil }
            offset = sign * (h * 3600 + m * 60)
        } else { return nil }
        return Double(day.serial * 86_400 + hour * 3600 + minute * 60 + second - offset) + fraction
    }
    static func dayKey(epoch: Double, timeZone: TimeZone) -> String {
        let local = epoch + Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: epoch)))
        return SessionUsageDay(serial: Int((local / 86_400).rounded(.down))).key
    }
    /// The window as dates, the same one Usage calls Last 30 days.
    static func window(now: Date, timeZone: TimeZone) -> ClosedRange<String> {
        SessionUsagePresentation.selectionBounds(period: windowPeriod, now: now, timeZone: timeZone)
            ?? CosCostRules.dayKey(epoch: now.timeIntervalSince1970, timeZone: timeZone)...CosCostRules.dayKey(epoch: now.timeIntervalSince1970, timeZone: timeZone)
    }
    /// The audit file the running server writes: its plist's scripts folder, then its .env's, then the home fallback.
    static func auditPaths(plistScripts: String?, envScripts: String?, home: String) -> [String] {
        var paths: [String] = []
        for dir in [plistScripts, envScripts] {
            if let dir, !dir.isEmpty { paths.append((dir as NSString).appendingPathComponent(".cos_token_audit.jsonl")) }
        }
        paths.append((home as NSString).appendingPathComponent(".cos-glasses/token-audit.jsonl"))
        return paths
    }
    /// One key out of a dotenv file. The file holds secrets, so nothing else leaves this function.
    static func envValue(_ text: String, key: String) -> String? {
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard line.hasPrefix(key + "=") else { continue }
            var value = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let q = value.first, q == "\"" || q == "'", value.last == q { value = String(value.dropFirst().dropLast()) }
            return value.isEmpty ? nil : value
        }
        return nil
    }
    /// The day-to-input-token ledgers, named one at a time. The same folder holds API key files, so this is never a glob.
    static let dailyLedgers: [(file: String, category: CosCostCategory, priced: Bool)] = [
        ("jev-usage.json", .work, true), ("jev-search-usage.json", .work, true), ("jev-cues-usage.json", .liveAndUpkeep, true),
        ("subq-session-usage.json", .work, false), ("subq-search-usage.json", .work, false), ("subq-decisions-usage.json", .work, false),
        ("subq-cues-usage.json", .liveAndUpkeep, false), ("subq-completion-usage.json", .other, false),
    ]
    /// Every file `cos-usage` may open in the server's data folder. Nothing outside this list is ever read there.
    static let dataFiles = ["claude-runs.jsonl", "codex-runs.jsonl", "lens-gist-runs.jsonl"] + dailyLedgers.map(\.file)
    static func dataFileAllowed(_ name: String, list: [String] = dataFiles) -> Bool {
        list.contains(name) && !name.lowercased().contains("key")
    }
}

/// One audit line, with nothing kept but counts and the fields the rules read.
struct CosAuditRow: Sendable {
    var stamp = ""
    var source = ""
    var caller = ""
    var model = ""
    var estimatedInput: Int64 = 0
    var estimatedOutput: Int64 = 0
    var usageKind = ""
    var runID = ""
    var sessionID = ""
    /// Real usage, when the row carries it.
    var real: SessionUsageCounts?
    var realOneHour: Int64 = 0
    var realUSD: Double?
    var resolvedModel = ""
    init() {}
    init(json: [String: Any]) {
        func text(_ key: String) -> String { json[key] as? String ?? "" }
        let n = SessionUsageCounts.number
        stamp = text("ts"); source = text("source"); caller = text("caller"); model = text("model")
        estimatedInput = n(json["est_input_tokens"]); estimatedOutput = n(json["est_output_tokens"])
        usageKind = text("usage_kind"); runID = text("run_id")
        sessionID = text("cli_session_id").isEmpty ? text("session_id") : text("cli_session_id")
        resolvedModel = text("resolved_model")
        // 6.97 says provider_final only over real numbers, and writes all four. A real zero is still a measurement.
        if usageKind == "provider_final", json["input_tokens"] != nil {
            real = SessionUsageCounts(input: n(json["input_tokens"]), output: n(json["output_tokens"]),
                                      cacheRead: n(json["cache_read_tokens"]), cacheWrite: n(json["cache_write_tokens"]))
            realOneHour = n(json["cache_write_1h_tokens"])
        }
        if let cost = (json["cost_usd"] as? NSNumber ?? json["usd"] as? NSNumber)?.doubleValue, cost.isFinite, cost >= 0 { realUSD = cost }
    }
    /// A keyed row's dollars are real even when its tokens are not there.
    var isMeasured: Bool { real != nil || realUSD != nil }
    /// Attached and fork rows write the provider's name as `model`, so what actually ran is in `resolved_model`.
    var pricedModel: String { resolvedModel.isEmpty ? model : resolvedModel }
}

struct CosGistRun: Equatable, Sendable {
    var engine: String
    var model: String
    var at: Double
    var inputTokens: Int64
    var outputTokens: Int64
    /// What the command line itself reported. The rate card is only for a run without it.
    var costUSD: Double?
    init?(json: [String: Any]) {
        guard let stamp = json["at"] as? String, let at = CosCostRules.epoch(stamp), let usage = json["usage"] as? [String: Any] else { return nil }
        self.engine = json["engine"] as? String ?? ""
        self.model = json["model"] as? String ?? ""
        self.at = at
        // inputTokens already includes cache creation and cache reads (lens-gist-engines.ts).
        inputTokens = SessionUsageCounts.number(usage["inputTokens"])
        outputTokens = SessionUsageCounts.number(usage["outputTokens"])
        costUSD = (usage["costUsd"] as? NSNumber)?.doubleValue
    }
}

/// A G2 run, merged from its ledger's patches.
struct CosRun: Equatable, Sendable {
    var runID: String
    var provider: String // "claude" or "codex"
    var session = ""
    var model = ""
    var start: Double = 0
    var end: Double = 0
    /// Folds one `{runId, ts, patch}` line in. Later lines win, and the end is the last thing the ledger heard.
    mutating func apply(patch: [String: Any]) {
        if let value = patch["cliSessionId"] as? String ?? patch["codexThreadId"] as? String, !value.isEmpty { session = value }
        if let value = patch["model"] as? String, !value.isEmpty { model = value }
        if let stamp = patch["createdAt"] as? String, let at = CosCostRules.epoch(stamp) { start = at }
        if let stamp = patch["updatedAt"] as? String, let at = CosCostRules.epoch(stamp) { end = max(end, at) }
        if let ms = (patch["durationMs"] as? NSNumber)?.doubleValue, start > 0 { end = max(end, start + ms / 1000) }
    }
}

struct CosSliceEvent: Equatable, Sendable {
    /// The message itself. A resume or fork can copy a message into a second session, and it still happened once.
    var id = ""
    var session: String
    var at: Double
    var provider: String
    var model: String
    var counts: SessionUsageCounts
    var oneHour: Int64 = 0
}

/// What a row in a session log says about who moved the session. Row types and block types only: no words are read.
enum CosMarkKind: String, Sendable {
    /// The person typed: a `user` row marked as human, with no tool results in it.
    case typed
    /// A `user` row with no origin: a prompt COS or a script handed in, or an older log's typed turn.
    case handedIn
    /// Another session's message.
    case peer
    /// A turn finished.
    case end
}

struct CosSliceMark: Equatable, Sendable {
    var session: String
    var at: Double
    var kind: CosMarkKind
}

/// One handoff. `openedInApp` means the prompt was placed in the app and the person sent it, so their first typed row is
/// the run's own prompt.
struct CosWorkRun: Equatable, Sendable {
    var session: String
    var start: Double
    var openedInApp = false
}

extension CosCostRules {
    /// A handed-in prompt lands within seconds of its handoff. Anything later is not this run's own prompt. A prompt placed in the
    /// app is sent by the person, whenever they get to it, so it has no limit: a typed row in a Claude log, and the turn that opens a
    /// Codex rollout (which has no typed marker, so its first turn is read as handed in).
    static let deliverySeconds = 120.0

    /// A Claude log row. A tool result is a `user` row the person never wrote, a background task's notice and a compaction
    /// summary are not them either, and a subagent's log has its own prompts. Only types are looked at, never text.
    static func claudeMark(_ row: [String: Any]) -> CosMarkKind? {
        if row["isSidechain"] as? Bool == true { return nil }
        let message = row["message"] as? [String: Any]
        switch row["type"] as? String {
        case "assistant":
            return message?["stop_reason"] as? String == "end_turn" ? .end : nil
        case "user":
            if row["isCompactSummary"] as? Bool == true { return nil }
            let origin = (row["origin"] as? [String: Any])?["kind"] as? String
            if origin == "peer" { return .peer }
            if row["isMeta"] as? Bool == true || origin == "task-notification" { return nil }
            if let blocks = message?["content"] as? [[String: Any]] {
                if blocks.isEmpty || blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            } else if !(message?["content"] is String) {
                return nil
            }
            return origin == nil ? .handedIn : .typed
        default:
            return nil
        }
    }
    /// A Codex rollout has no typed-row marker, but every turn opens with `task_started` and closes with `task_complete`
    /// or `turn_aborted`, so the next turn's start is what ends a run.
    static func codexMark(_ row: [String: Any]) -> CosMarkKind? {
        guard row["type"] as? String == "event_msg", let kind = (row["payload"] as? [String: Any])?["type"] as? String else { return nil }
        switch kind {
        case "task_started": return .handedIn
        case "task_complete", "turn_aborted": return .end
        default: return nil
        }
    }
    /// When a run ended: the next typed turn or message from another session, else its last finished turn. A background
    /// task's notice wakes the same run, so it does not end one. Nil means no ending can be proven, and nothing is guessed.
    static func workRunEnd(_ run: CosWorkRun, marks: [CosSliceMark]) -> Double? {
        let after = marks.filter { $0.at >= run.start - CosCostAccumulator.runLeadSeconds }.sorted { $0.at < $1.at }
        var rest = after[...]
        // The run's own prompt is not the person moving on, so the first row that fits is passed over.
        if let first = after.firstIndex(where: { $0.kind != .end }),
           (after[first].at - run.start <= deliverySeconds && (after[first].kind == .handedIn || after[first].kind == .peer))
            || (run.openedInApp && (after[first].kind == .typed || after[first].kind == .handedIn)) {
            rest = after[after.index(after: first)...]
        }
        if let closer = rest.first(where: { $0.kind != .end }) { return closer.at }
        return rest.last(where: { $0.kind == .end })?.at
    }
}

/// Turns the ledgers into rows. Feed it the runs, Work starts and session slices once, then the audit a row at a time, so
/// the audit never has to sit in memory.
struct CosCostAccumulator {
    static let gistMatchSeconds = 5.0
    /// An event belongs to a run from a little before it starts to a little after the ledger last heard from it.
    static let runLeadSeconds = 5.0
    static let runTailSeconds = 60.0
    /// The audit row is written as the run ends, so its time sits inside the run or just after it.
    static let auditTailSeconds = 120.0

    private let window: ClosedRange<String>
    private let zone: TimeZone
    private var rows: [CosCostCategory: CosCostRow] = [:]
    private(set) var undated = 0
    private var gist: [CosGistRun]
    private var gistUsed: [Bool]
    private var runs: [CosRun]
    private var runUsed: [Bool]
    private var runCategory: [CosCostCategory?]
    private var runOwnedByWork: [Bool]
    private var runUSD: [Double]
    private var runAdds: [Double]
    private var runTokens: [Int64]
    private var runHasEvents: [Bool]
    private var runUnpriced: [Bool]
    /// The run's own audit row is real, so its slice is not counted: audit real wins, slices are for older rows.
    private var runRealAudit: [Bool]
    private let workStarts: [String: Double]
    private var workSessionsWithEvents = Set<String>()
    private var runIndexByID: [String: Int] = [:]
    private var runsBySession: [String: [Int]] = [:]
    private var work = CosWorkSummary()

    /// Work wins from the moment a run started in that session. Before it, an event belongs to a G2 run if one was going.
    /// Anything else in the file is the person's own, which Usage already shows and COS did not start.
    init(window: ClosedRange<String>, timeZone: TimeZone, gistRuns: [CosGistRun], runs: [CosRun], workStarts: [String: Double], events: [CosSliceEvent], workRuns: [CosWorkRun] = [], marks: [CosSliceMark] = []) {
        self.window = window
        self.zone = timeZone
        self.gist = gistRuns.filter { window.contains(CosCostRules.dayKey(epoch: $0.at, timeZone: timeZone)) }.sorted { $0.at < $1.at }
        self.gistUsed = Array(repeating: false, count: gist.count)
        self.runs = runs
        let count = runs.count
        runUsed = Array(repeating: false, count: count)
        runCategory = Array(repeating: nil, count: count)
        runUSD = Array(repeating: 0, count: count)
        runAdds = Array(repeating: 0, count: count)
        runTokens = Array(repeating: 0, count: count)
        runHasEvents = Array(repeating: false, count: count)
        runUnpriced = Array(repeating: false, count: count)
        runRealAudit = Array(repeating: false, count: count)
        self.workStarts = workStarts
        runOwnedByWork = runs.map { run in workStarts[run.session].map { run.start >= $0 - Self.runLeadSeconds } ?? false }
        for (index, run) in runs.enumerated() {
            runIndexByID[run.runID] = index
            if !run.session.isEmpty { runsBySession[run.session, default: []].append(index) }
        }
        // A message copied into a second session counts once, and which session was read first must not decide where.
        // Work goes first because it owns a session from the run's start, then events in file-independent order.
        func workOwns(_ event: CosSliceEvent) -> Bool { workStarts[event.session].map { event.at >= $0 - Self.runLeadSeconds } ?? false }
        let ordered = events.filter { window.contains(CosCostRules.dayKey(epoch: $0.at, timeZone: timeZone)) }.sorted {
            let a = workOwns($0), b = workOwns($1)
            if a != b { return a }
            return $0.session == $1.session ? $0.at < $1.at : $0.session < $1.session
        }
        var counted = Set<String>()
        // Each run's window, from its start to its proven end. A run's end is the next typed turn or message from another session,
        // so windows of one session usually do not overlap. Two runs started close together can, and an event in both is counted once.
        let marksBySession = Dictionary(grouping: marks, by: \.session)
        var windows: [String: [ClosedRange<Double>]] = [:]
        var silentRuns = 0
        let eventsBySession = Dictionary(grouping: ordered, by: \.session)
        for run in workRuns {
            let hasRows = eventsBySession[run.session]?.contains { $0.at >= run.start - Self.runLeadSeconds } ?? false
            guard hasRows else { silentRuns += 1; continue }
            guard let end = CosCostRules.workRunEnd(run, marks: marksBySession[run.session] ?? []) else { work.unprovenRuns += 1; continue }
            let begin = run.start - Self.runLeadSeconds
            if end >= begin { windows[run.session, default: []].append(begin...end) }
        }
        work.runsWithoutLogs = silentRuns
        for event in ordered {
            let usd = CosCostRates.usd(provider: event.provider, model: event.model, counts: event.counts, oneHour: event.oneHour, on: event.at)
            let extra = SessionUsagePricing.estimate(provider: event.provider, model: event.model, counts: event.counts, oneHour: event.oneHour) == nil ? usd ?? 0 : 0
            if let start = workStarts[event.session], event.at >= start - Self.runLeadSeconds {
                if !event.id.isEmpty && !counted.insert(event.id).inserted { continue }
                work.widerUSD += usd ?? 0
                work.widerTokens += event.counts.total
                if usd == nil { work.widerUnpricedEvents += 1 }
                work.addsToTotalUSD += extra
                workSessionsWithEvents.insert(event.session)
                if windows[event.session]?.contains(where: { $0.contains(event.at) }) == true {
                    work.measuredUSD += usd ?? 0
                    work.measuredTokens += event.counts.total
                    if usd == nil { work.unpricedEvents += 1 }
                }
                continue
            }
            guard let index = runsBySession[event.session]?.first(where: {
                event.at >= self.runs[$0].start - Self.runLeadSeconds && event.at <= self.runs[$0].end + Self.runTailSeconds
            }) else { continue }
            if !event.id.isEmpty && !counted.insert(event.id).inserted { continue }
            runHasEvents[index] = true
            runUSD[index] += usd ?? 0
            runAdds[index] += extra
            runTokens[index] += event.counts.total
            if usd == nil { runUnpriced[index] = true }
        }
    }

    private mutating func addEstimate(_ row: CosAuditRow, category: CosCostCategory) {
        var r = rows[category] ?? CosCostRow(category: category)
        r.calls += 1
        r.estimatedCalls += 1
        r.estimatedTokens += row.estimatedInput + row.estimatedOutput
        if let usd = CosCostRates.estimateUSD(ledgerModel: row.pricedModel, input: row.estimatedInput, output: row.estimatedOutput, on: CosCostRules.epoch(row.stamp)) {
            r.estimatedUSD += usd
            r.estimatedPricedCalls += 1
        }
        rows[category] = r
    }
    private mutating func addMeasured(_ row: CosAuditRow, category: CosCostCategory, isCall: Bool = true) {
        var r = rows[category] ?? CosCostRow(category: category)
        if isCall {
            r.calls += 1
            r.measuredCalls += 1
        }
        let counts = row.real ?? SessionUsageCounts()
        r.measuredTokens += counts.total
        let named = row.pricedModel
        var usd = row.realUSD
        if usd == nil, let resolved = CosCostRates.resolve(named) {
            usd = CosCostRates.usd(provider: resolved.provider, model: resolved.model, counts: counts, oneHour: row.realOneHour, on: CosCostRules.epoch(row.stamp))
        }
        if let usd {
            r.measuredUSD += usd
            if !CosCostRules.inSessionLogs(source: row.source, caller: row.caller, model: named) {
                if CosCostRules.runsThroughCursor(model: row.model) || CosCostRules.runsThroughCursor(model: named) { r.addsUnlessCursorFeedUSD += usd }
                else { r.addsToTotalUSD += usd }
            }
        } else if isCall { r.unpricedMeasuredCalls += 1 }
        rows[category] = r
    }
    /// Whether a Work session's log already holds this row, so its dollars are on the Work line. A dispatch keeps no log,
    /// so its session has no events, and its real row is the only record there is.
    private func workSliceHolds(sessionID: String, at: Double) -> Bool {
        guard !sessionID.isEmpty else { return false }
        for key in ["claude:" + sessionID, "codex:" + sessionID] where workSessionsWithEvents.contains(key) {
            if let start = workStarts[key], at >= start - Self.runLeadSeconds { return true }
        }
        return false
    }
    /// The gist run nearest in time with the same engine and model, not already taken.
    private mutating func takeGist(at: Double, ledgerModel: String) -> Bool {
        var engine = "", model = ledgerModel
        if let colon = ledgerModel.firstIndex(of: ":") { engine = String(ledgerModel[..<colon]); model = String(ledgerModel[ledgerModel.index(after: colon)...]) }
        var best: Int?
        var bestGap = Self.gistMatchSeconds
        for (index, run) in gist.enumerated() where !gistUsed[index] && run.model == model && run.engine == engine {
            let gap = abs(run.at - at)
            if gap <= bestGap { best = index; bestGap = gap }
        }
        guard let best else { return false }
        gistUsed[best] = true
        return true
    }
    /// A G2 row's run: its id, then its session if only one run could be it, then time and model, labelled approximate.
    private mutating func takeRun(_ row: CosAuditRow, at: Double) -> (index: Int, approximate: Bool)? {
        if !row.runID.isEmpty, let index = runIndexByID[row.runID], !runUsed[index] { runUsed[index] = true; return (index, false) }
        func fits(_ index: Int) -> Bool { !runUsed[index] && at >= runs[index].start - Self.runLeadSeconds && at <= runs[index].end + Self.auditTailSeconds }
        // A row names its session bare, and the runs are keyed provider:id, the way the collector builds them.
        if !row.sessionID.isEmpty {
            for key in ["claude:" + row.sessionID, "codex:" + row.sessionID] {
                if let candidates = runsBySession[key], let index = candidates.first(where: fits) {
                    runUsed[index] = true
                    return (index, false)
                }
            }
        }
        var best: Int?
        var bestGap = Double.infinity
        for index in runs.indices where runs[index].model == row.model && fits(index) {
            let gap = abs(runs[index].end - at)
            if gap < bestGap { best = index; bestGap = gap }
        }
        guard let best else { return nil }
        runUsed[best] = true
        return (best, true)
    }

    /// One audit line. A row Usage or a measured source already holds is not counted again, and a measured source wins.
    mutating func add(_ row: CosAuditRow) {
        guard let at = CosCostRules.epoch(row.stamp) else { undated += 1; return }
        let day = CosCostRules.dayKey(epoch: at, timeZone: zone)
        guard window.contains(day) else { return }
        var category = CosCostRules.category(source: row.source, caller: CosCostRules.baseCaller(row.caller), day: day)
        if CosCostRules.isLate(row.caller) {
            if let index = runIndexByID[row.runID] {
                if runOwnedByWork[index] && workSessionsWithEvents.contains(runs[index].session) { return }
                // An estimated run measured from its slice already holds this usage. A real one needs it added.
                if runHasEvents[index] && !runRealAudit[index] { return }
                if runOwnedByWork[index] { category = .work }
            }
            if workSliceHolds(sessionID: row.sessionID, at: at) { return }
            if row.isMeasured { addMeasured(row, category: category, isCall: false) }
            return
        }
        if row.caller == "lens_gist" || row.source == "g2-lens-gist", takeGist(at: at, ledgerModel: row.model) { return }
        if row.source == "g2-query" || row.source == "g2-voice", let match = takeRun(row, at: at) {
            if runOwnedByWork[match.index] {
                // The run's dollars are on the Work line. With no log there, the row is all Work has.
                if workSessionsWithEvents.contains(runs[match.index].session) { return }
                category = .work
            } else if row.isMeasured {
                runRealAudit[match.index] = true
            } else if runHasEvents[match.index] {
                var r = rows[category] ?? CosCostRow(category: category)
                r.calls += 1
                r.measuredCalls += 1
                if match.approximate { r.approximateMatches += 1 }
                rows[category] = r
                runCategory[match.index] = category
                return
            }
        }
        if category == .work && workSliceHolds(sessionID: row.sessionID, at: at) { return }
        if row.isMeasured { addMeasured(row, category: category); return }
        addEstimate(row, category: category)
    }

    /// Input tokens from a day ledger. No call count exists for these, so they add tokens and dollars but no calls.
    mutating func addDailyTokens(_ tokens: Int64, category: CosCostCategory, priced: Bool, day: String) {
        guard tokens > 0, window.contains(day) else { return }
        let usd = priced ? Double(tokens) * CosCostRates.jevPerInputToken : 0
        if category == .work {
            // Session matching and search are the run's own machinery, so they are in both figures.
            work.measuredTokens += tokens
            work.measuredUSD += usd
            work.widerTokens += tokens
            work.widerUSD += usd
            work.addsToTotalUSD += usd
            // A day of unpriced tokens is not an event, but it leaves dollars out the way one does, so the Work line ends in +.
            if !priced { work.unpricedEvents += 1; work.widerUnpricedEvents += 1 }
            return
        }
        var r = rows[category] ?? CosCostRow(category: category)
        r.measuredTokens += tokens
        r.measuredUSD += usd
        r.addsToTotalUSD += usd
        if !priced { r.unpricedLedgerTokens += tokens }
        rows[category] = r
    }

    /// Everything counted, with each dollar in one place.
    mutating func finish(handoffsFound: Bool, workRuns: Int, workRunsWithoutLogs: Int) -> (rows: [CosCostRow], work: CosWorkSummary) {
        for run in gist {
            var r = rows[.liveAndUpkeep] ?? CosCostRow(category: .liveAndUpkeep)
            r.calls += 1
            r.measuredCalls += 1
            r.measuredTokens += run.inputTokens + run.outputTokens
            var usd = run.costUSD
            if usd == nil, let resolved = CosCostRates.resolve(run.model) {
                usd = CosCostRates.usd(provider: resolved.provider, model: resolved.model, counts: SessionUsageCounts(input: run.inputTokens, output: run.outputTokens), on: run.at)
            }
            if let usd {
                r.measuredUSD += usd
                // A gist run through the Cursor engine is in Usage's total whenever the Cursor feed is on, so it follows the same rule.
                if CosCostRules.runsThroughCursor(model: run.engine) || CosCostRules.runsThroughCursor(model: run.model) { r.addsUnlessCursorFeedUSD += usd }
                else { r.addsToTotalUSD += usd }
            } else { r.unpricedMeasuredCalls += 1 }
            rows[.liveAndUpkeep] = r
        }
        for index in runs.indices where runHasEvents[index] && !runRealAudit[index] {
            let category = runCategory[index] ?? .answers
            var r = rows[category] ?? CosCostRow(category: category)
            // A run whose audit row is missing, or was written by a server that wrote none, is still a call.
            if runCategory[index] == nil { r.calls += 1; r.measuredCalls += 1 }
            r.measuredUSD += runUSD[index]
            r.measuredTokens += runTokens[index]
            r.addsToTotalUSD += runAdds[index]
            // A run with priced and unpriced events is partial too: its dollars leave the unpriced ones out.
            if runUnpriced[index] { r.unpricedMeasuredCalls += 1 }
            rows[category] = r
        }
        work.handoffsFound = handoffsFound
        work.runs = workRuns
        work.runsWithoutLogs += workRunsWithoutLogs
        return (CosCostCategory.allCases.compactMap { rows[$0] }, work)
    }
}

/// What the page says, as pure functions of the two reports.
enum CosCostPresentation {
    /// Usage's state, for the comparison. Paused and still-importing totals are not a fair thing to divide by.
    enum UsageState: Equatable, Sendable { case ready, paused, importing(files: Int), unavailable }

    /// Cents under ten dollars, so a small row says what it is rather than rounding to nothing.
    static func money(_ value: Double) -> String {
        if value > 0 && value < 0.01 { return "under 1¢" }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(value < 10 ? 2 : 0)))
    }
    /// A floor in words. "At least under 1¢" would contradict itself.
    static func atLeast(_ value: Double) -> String {
        value < 0.01 ? "at least a fraction of 1¢" : "at least " + money(value)
    }
    /// Usage's state, from what it last reported. A Cursor read still under way is a total that will grow, like a log.
    static func usageState(tracking: Bool, report: SessionUsageReport?) -> UsageState {
        guard tracking else { return .paused }
        guard let report else { return .unavailable }
        if report.pendingFiles > 0 { return .importing(files: report.pendingFiles) }
        return report.cursorFeed?.pending == true ? .importing(files: 0) : .ready
    }
    /// Whether Usage's total holds Cursor spend. The switch alone cannot say: it can be on with nothing read yet (saved while
    /// paused, Keychain busy, no sign-in), and Cursor rows already read stay in the history after it is turned off.
    static func usageHoldsCursor(feedOn: Bool, usage: SessionUsageReport?, report: CosUsageReport) -> Bool {
        if feedOn && usage?.cursorFeed?.lastSuccessAt != nil { return true }
        return usage?.buckets.contains { $0.provider == "Cursor" && (report.windowStart...report.windowEnd).contains($0.day) } == true
    }
    /// A person's total at API value: Usage's total for the window, plus the COS spend it cannot see. The Cursor share is
    /// added only while Usage does not hold that spend (usageHoldsCursor).
    static func ranUSD(usageBuckets: [SessionUsageBucket], report: CosUsageReport, cursorFeedOn: Bool) -> Double {
        let bounds = report.windowStart...report.windowEnd
        let usage = usageBuckets.filter { bounds.contains($0.day) }.reduce(0.0) { $0 + $1.estimatedUSD }
        let adds = report.rows.reduce(0.0) { $0 + $1.addsToTotalUSD + (cursorFeedOn ? 0 : $1.addsUnlessCursorFeedUSD) }
        return usage + adds + report.work.addsToTotalUSD
    }
    static func overhead(_ report: CosUsageReport) -> [CosCostRow] { report.rows.filter { $0.category != .work } }
    static func measuredUSD(_ report: CosUsageReport) -> Double { overhead(report).reduce(0) { $0 + $1.measuredUSD } }
    static func measuredCalls(_ report: CosUsageReport) -> Int { overhead(report).reduce(0) { $0 + $1.measuredCalls } }
    static func estimatedCalls(_ report: CosUsageReport) -> Int { overhead(report).reduce(0) { $0 + $1.estimatedCalls } }
    static func calls(_ report: CosUsageReport) -> Int { overhead(report).reduce(0) { $0 + $1.calls } }
    /// Measured dollars over the total. Nil when a share would mislead: no total, a total still being read, or a figure
    /// bigger than what it divides.
    static func share(measured: Double, ran: Double, usage: UsageState, auditUnreadable: Bool = false) -> Double? {
        // An audit that would not open leaves calls out of the numerator, and by an amount nobody can size.
        guard usage == .ready, !auditUnreadable, measured > 0, ran > 0, measured <= ran else { return nil }
        return measured / ran
    }
    /// Which way a share may be off. Usage's total leaves out models with no price, so alone it reads the share high (a ceiling).
    /// COS's measured dollars leave out calls with no price, and the same model usually sits in both figures, so with both
    /// partial the share can be off either way and no word like "up to" is true.
    enum ShareLean: Equatable, Sendable { case plain, ceiling, either }
    static func shareLean(ranPartial: Bool, measuredPartial: Bool) -> ShareLean {
        switch (ranPartial, measuredPartial) {
        case (true, false): return .ceiling
        case (true, true): return .either
        default: return .plain
        }
    }
    /// COS's side of the share leaves something out: dollars without calls that have no price, calls with only character counts,
    /// session logs not yet read or that cannot be read, and sessions whose log is gone. Only when none of that is so can a partial
    /// total make the share a ceiling. The figure and the footer both read this, so they cannot disagree.
    static func measuredShort(_ report: CosUsageReport) -> Bool {
        let s = report.sessions
        return measuredPartial(report) || estimatedCalls(report) > 0 || s.compressed > 0 || s.noLogs > 0 || s.reading
    }
    static func shareLean(_ report: CosUsageReport, ranPartial: Bool) -> ShareLean {
        shareLean(ranPartial: ranPartial, measuredPartial: measuredShort(report))
    }
    static func percent(_ fraction: Double) -> String {
        let p = fraction * 100
        if p > 0 && p < 0.1 { return "under 0.1%" }
        return String(format: p < 10 ? "%.1f%%" : "%.0f%%", p)
    }
    /// A figure whose dollars leave out some measured calls (a model with no verified rate) ends in +, as Usage's figures do.
    static func measuredPartial(_ report: CosUsageReport) -> Bool { overhead(report).contains { $0.unpricedMeasuredCalls > 0 || $0.unpricedLedgerTokens > 0 } }
    /// Whether the total the person ran leaves out usage Usage could not price: any bucket in the window with an event it has no
    /// rate for. COS's own calls on such models are priced by the additions, so the share against that total reads high.
    static func ranPartial(usageBuckets: [SessionUsageBucket], report: CosUsageReport, usage: UsageState) -> Bool {
        // A paused or unread Usage shows no total, so there is nothing for the flag to qualify.
        guard usage != .paused, usage != .unavailable else { return false }
        let bounds = report.windowStart...report.windowEnd
        return usageBuckets.contains { bounds.contains($0.day) && $0.pricedEvents < $0.events }
    }
    /// Usage with no call behind it: the day ledgers and Work. A headline of "no calls" would sit right above it.
    static func hasUsageWithoutCalls(_ report: CosUsageReport) -> Bool {
        overhead(report).contains { $0.measuredTokens > 0 } || workTokens(report) > 0 || report.work.widerTokens > 0
    }
    /// Why nothing is measured. Usually the session logs that hold the cost have not been read, and only otherwise the server.
    static func notMeasuredWhy(report: CosUsageReport, usage: UsageState) -> String {
        if usage == .paused { return " Tracking is paused, so the session logs that could hold their cost are not being read." }
        if report.sessions.reading { return " Still reading the session logs that could hold their cost." }
        if report.sessions.failed { return " COS could not read the usage history, so the session logs that could hold their cost are missing from this pass." }
        return " This server doesn't measure their cost yet."
    }
    /// The answer, then what it leaves out. The two read as one sentence pair, in two tones.
    static func headlineParts(report: CosUsageReport, ran: Double, usage: UsageState, ranPartial: Bool = false) -> (answer: String, caveat: String) {
        let parts = baseHeadline(report: report, ran: ran, usage: usage, ranPartial: ranPartial)
        // The audit is where the calls are written. Present and unreadable, it says nothing about what COS did.
        guard report.auditUnreadable else { return parts }
        if calls(report) == 0 { return ("COS could not read its record of calls, so there is no count to show.", "") }
        return (parts.answer, parts.caveat + " COS could not read its record of calls, so some are missing here.")
    }
    private static func baseHeadline(report: CosUsageReport, ran: Double, usage: UsageState, ranPartial: Bool) -> (answer: String, caveat: String) {
        let total = calls(report), measured = measuredCalls(report), estimated = estimatedCalls(report), usd = measuredUSD(report)
        if !report.auditFound && total == 0 { return ("COS has no record of its calls on this Mac yet.", " The record starts with its first one.") }
        if total == 0 {
            return hasUsageWithoutCalls(report) ? ("COS made no counted calls in the last 30 days.", " Its Work and background usage is below.") : ("COS made no calls in the last 30 days.", "")
        }
        let callWord = total == 1 ? "call" : "calls"
        guard measured > 0 else { return ("COS made \(total.formatted()) \(callWord) in the last 30 days.", notMeasuredWhy(report: report, usage: usage)) }
        let lead = report.sessions.reading || report.sessions.failed ? "Measured so far: COS used " : "Measured: COS used "
        let usdText = money(usd) + (measuredPartial(report) ? "+" : "")
        let ranText = money(ran) + (ranPartial ? "+" : "")
        var sentence: String
        if usd <= 0 {
            sentence = "COS made \(total.formatted()) \(callWord) in the last 30 days. \(measured.formatted()) were measured, on models with no verified price."
        } else if usage == .paused || usage == .unavailable || ran <= 0 || usd > ran {
            sentence = lead + usdText + " in the last 30 days."
        } else if case .importing = usage {
            sentence = lead + usdText + " of the " + ranText + " read so far in the last 30 days."
        } else {
            sentence = lead + usdText + " of the " + ranText + " you ran in the last 30 days."
        }
        var caveat = ""
        if estimated > 0 && usd > 0 {
            caveat = " \(estimated.formatted()) more \(estimated == 1 ? "call has" : "calls have") only character counts, so the real figure is higher."
        }
        return (sentence, caveat)
    }
    static func headline(report: CosUsageReport, ran: Double, usage: UsageState, ranPartial: Bool = false) -> String {
        let parts = headlineParts(report: report, ran: ran, usage: usage, ranPartial: ranPartial)
        return parts.answer + parts.caveat
    }
    /// Dollars appear on the page, so the page says once what kind of dollars they are.
    static func showsDollars(_ report: CosUsageReport) -> Bool {
        report.rows.contains { $0.measuredUSD > 0 || $0.estimatedUSD > 0 } || report.work.widerUSD > 0
    }
    /// Plain words for why there is no comparison, with the way out in the pane.
    static func usageNote(_ usage: UsageState) -> String? {
        switch usage {
        case .ready: return nil
        case .paused: return "Tracking is paused, so no new session logs are being read. These figures stop at the last read, and there is no current total to compare them with."
        case .importing(0): return "Usage is still reading your Cursor usage, so the total will grow and the share will settle."
        case .importing(let files): return "Usage is still reading \(files.formatted()) log \(files == 1 ? "file" : "files"), so the total will grow and the share will settle."
        case .unavailable: return "Usage has not been read yet, so there is no total to compare this with."
        }
    }
    enum Evidence: Equatable, Sendable { case measured, estimated, noPrice, none }
    struct RowLine: Identifiable, Equatable, Sendable {
        let id: CosCostCategory
        let title: String
        let count: String
        let evidence: Evidence
        /// The right column's first line: dollars, or the word for what the row has instead.
        let figure: String
        /// The right column's second line: tokens, or the floor.
        let detail: String
        /// A row with a mix says how many calls were measured.
        let mix: String?
        /// Bar widths, 0 to 1, against the largest row. The floor is a separate part, because it is not a measurement.
        var measuredFraction = 0.0
        var estimatedFraction = 0.0
    }
    static func rowLine(_ row: CosCostRow) -> RowLine {
        let tokens = SessionUsagePresentation.shortTokens(row.measuredTokens + (row.measuredCalls == 0 ? row.estimatedTokens : 0)) + " tokens"
        let count = row.calls > 0 ? row.category.count(row.calls) : row.measuredTokens > 0 ? "Counted by the day" : "None in the last 30 days"
        if row.calls == 0 && row.measuredTokens == 0 {
            return RowLine(id: row.category, title: row.category.title, count: count, evidence: .none, figure: "", detail: "", mix: nil)
        }
        var mixParts: [String] = []
        if row.measuredCalls > 0 && row.estimatedCalls > 0 {
            // "For the rest" is only true when every other call has a rate. Otherwise the floor says how many it holds.
            let rest = row.estimatedPricedCalls > 0 && row.estimatedPricedCalls < row.estimatedCalls ? "\(row.estimatedPricedCalls.formatted()) of the \(row.estimatedCalls.formatted()) others" : "the rest"
            let floor = row.estimatedUSD > 0 ? ", \(atLeast(row.estimatedUSD)) estimated for \(rest)" : ", no verified price for the rest"
            mixParts.append("\(row.measuredCalls.formatted()) measured\(floor).")
        }
        // A call on a model with no verified rate has tokens and no dollars, so the dollars are a floor and end in +, as Usage's do.
        let partial = row.measuredUSD > 0 && (row.unpricedMeasuredCalls > 0 || row.unpricedLedgerTokens > 0)
        if row.measuredUSD > 0 && row.unpricedMeasuredCalls > 0 { mixParts.append("\(row.unpricedMeasuredCalls.formatted()) measured \(row.unpricedMeasuredCalls == 1 ? "call has" : "calls have") no verified price, so the dollars are a floor.") }
        if row.measuredUSD > 0 && row.unpricedLedgerTokens > 0 { mixParts.append("\(SessionUsagePresentation.shortTokens(row.unpricedLedgerTokens)) tokens counted by the day have no verified price, so the dollars are a floor.") }
        let mix = mixParts.isEmpty ? nil : mixParts.joined(separator: " ")
        if row.measuredUSD > 0 {
            return RowLine(id: row.category, title: row.category.title, count: count, evidence: .measured, figure: money(row.measuredUSD) + (partial ? "+" : ""), detail: tokens + ", measured", mix: mix)
        }
        if row.measuredTokens > 0 && row.estimatedCalls == 0 {
            return RowLine(id: row.category, title: row.category.title, count: count, evidence: .noPrice, figure: "No price", detail: tokens, mix: mix)
        }
        if row.estimatedUSD > 0 {
            return RowLine(id: row.category, title: row.category.title, count: count, evidence: .estimated, figure: "Estimated", detail: atLeast(row.estimatedUSD), mix: mix)
        }
        return RowLine(id: row.category, title: row.category.title, count: count, evidence: .noPrice, figure: "No price", detail: tokens, mix: mix)
    }
    /// Measured rows first, largest first. Estimated rows below them, then rows with tokens and no price, then empty rows.
    static func rowLines(_ report: CosUsageReport, keeping: [CosCostCategory] = [.dictation, .transcription]) -> [RowLine] {
        var rows = overhead(report)
        for category in keeping where !rows.contains(where: { $0.category == category }) { rows.append(CosCostRow(category: category)) }
        func rank(_ row: CosCostRow) -> Int {
            if row.measuredUSD > 0 { return 0 }
            if row.estimatedUSD > 0 { return 1 }
            return row.calls > 0 || row.measuredTokens > 0 ? 2 : 3
        }
        let sorted = rows.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            let left = a.measuredUSD > 0 ? a.measuredUSD : a.estimatedUSD > 0 ? a.estimatedUSD : Double(a.calls)
            let right = b.measuredUSD > 0 ? b.measuredUSD : b.estimatedUSD > 0 ? b.estimatedUSD : Double(b.calls)
            return left == right ? a.category.rawValue < b.category.rawValue : left > right
        }
        let peak = sorted.reduce(0.0) { max($0, $1.measuredUSD + $1.estimatedUSD) }
        return sorted.map { row in
            var line = rowLine(row)
            if peak > 0 {
                line.measuredFraction = row.measuredUSD / peak
                line.estimatedFraction = row.estimatedUSD / peak
            }
            return line
        }
    }
    /// The price field: "$200", "200", "1,200.50". Anything that is not a positive amount means no price.
    static func monthlyPrice(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value.isFinite, value > 0, value < 1_000_000 else { return nil }
        return value
    }
    /// Share times price. API value against a subscription price would compare two different things. When some of the person's own
    /// usage has no price, the total is low and the share reads high, so it is said as a ceiling.
    static func compareLine(share: Double?, price: Double?, lean: ShareLean = .plain) -> String? {
        guard let share, let price else { return nil }
        let eitherWay = "Both figures leave something out, so the true share can be higher or lower."
        // A sum under a cent is a bound too, not "roughly under 1¢" or "up to under 1¢".
        let small = share * price > 0 && share * price < 0.01
        let amount = small ? "under 1¢" : "roughly " + money(share * price)
        // Under a tenth of a percent has no "about" or "up to": it is a bound.
        if share < 0.001 {
            let bound = price * 0.001 < 0.01 ? "under 1¢" : "under " + money(price * 0.001)
            return "Under 0.1% of your usage, so \(bound) of your \(money(price))." + (lean == .either ? " " + eitherWay : "")
        }
        switch lean {
        case .ceiling: return small ? "Up to about \(percent(share)) of your usage, so under 1¢ of your \(money(price))." : "Up to about \(percent(share)) of your usage, so up to \(money(share * price)) of your \(money(price))."
        case .either: return "About \(percent(share)) of your usage, \(amount) of your \(money(price)). \(eitherWay)"
        case .plain: return "About \(percent(share)) of your usage, \(amount) of your \(money(price))."
        }
    }
    /// The Work line: each run's own window in its session log, plus real rows for work no log holds.
    static func workUSD(_ report: CosUsageReport) -> Double {
        report.work.measuredUSD + (report.rows.first { $0.category == .work }?.measuredUSD ?? 0)
    }
    static func workTokens(_ report: CosUsageReport) -> Int64 {
        report.work.measuredTokens + (report.rows.first { $0.category == .work }?.measuredTokens ?? 0)
    }
    /// Work events and real rows with tokens and no verified rate: the Work dollars leave them out, so they end in +.
    static func workPartial(_ report: CosUsageReport) -> Bool {
        report.work.unpricedEvents > 0 || (report.rows.first { $0.category == .work }?.unpricedMeasuredCalls ?? 0) > 0
    }
    static func workFigure(_ report: CosUsageReport) -> String {
        if workUSD(report) > 0 { return money(workUSD(report)) + (workPartial(report) ? "+" : "") }
        return workTokens(report) > 0 ? "No price" : ""
    }
    /// What the person did later in those sessions is theirs, so it is said in words and stays out of any share.
    static func workWider(_ report: CosUsageReport) -> String? {
        let row = report.rows.first { $0.category == .work }?.measuredUSD ?? 0
        let wider = report.work.widerUSD + row
        guard wider - workUSD(report) >= 0.01 else { return nil }
        let partial = report.work.widerUnpricedEvents > 0 || (report.rows.first { $0.category == .work }?.unpricedMeasuredCalls ?? 0) > 0
        return money(wider) + (partial ? "+" : "") + " if you count what you did later in those sessions."
    }
    static func workUnproven(_ work: CosWorkSummary) -> String? {
        guard work.unprovenRuns > 0 else { return nil }
        return "\(work.unprovenRuns.formatted()) \(work.unprovenRuns == 1 ? "run has" : "runs have") no provable end, so \(work.unprovenRuns == 1 ? "it is" : "they are") only in the wider figure."
    }
    /// Intake checks and Work chat keep only character counts, so they sit beside the measured figure, not in it.
    static func workBackground(_ report: CosUsageReport) -> String? {
        guard let row = report.rows.first(where: { $0.category == .work }), row.estimatedCalls > 0 else { return nil }
        let floor = row.estimatedUSD > 0 ? ", \(atLeast(row.estimatedUSD)) estimated" : ", no verified price"
        return "Plus " + row.category.count(row.estimatedCalls) + floor + "."
    }
    static func workWithoutLogs(_ work: CosWorkSummary) -> String {
        "\(work.runsWithoutLogs.formatted()) \(work.runsWithoutLogs == 1 ? "run" : "runs") left no log COS can read, so \(work.runsWithoutLogs == 1 ? "it isn't" : "they aren't") counted."
    }
    static func workCount(_ work: CosWorkSummary) -> String {
        guard work.handoffsFound else { return "This Mac has no record of Work runs." }
        return work.runs == 0 ? "No Work runs in the last 30 days" : "\(work.runs.formatted()) \(work.runs == 1 ? "run" : "runs") you started"
    }
    static let workMethod = "From each run's session log, from its start until you next typed in that session or its last turn finished. Not part of the figure above."
    /// How soon the open page reads again while sessions are still being read, or after a pass found the history busy.
    static let readingSeconds = 15
    /// A failed pass tries again at this pace for a few tries, and every pass that reads nothing new at this one afterwards.
    static let failedSeconds = 60
    static let slowSeconds = 300
    /// Passes in a row that read nothing new (busy, or failed) and still come back quickly. Past this, the slow pace.
    static let quickTryLimit = 20
    /// How long the open page waits after a pass, and the passes in a row that read nothing new. Reading is real progress
    /// and is never counted against the limit; a busy history or a failed pass is.
    static func wait(tracking: Bool, report: CosUsageReport?, failedToRefresh: Bool, quickTries: Int) -> (seconds: Int, quickTries: Int) {
        let stalled = failedToRefresh || report == nil || report?.sessions.busy == true
        let tries = stalled ? quickTries + 1 : 0
        let quick = tries < quickTryLimit
        if failedToRefresh { return (quick ? failedSeconds : slowSeconds, tries) }
        // No report yet is the spinner on screen, which a five minute wait would leave there.
        let reading = tracking && (report?.sessions.reading ?? true)
        return (reading && quick ? readingSeconds : slowSeconds, tries)
    }
    static func stillReadingNote(_ report: CosUsageReport) -> String {
        let n = report.sessions.stillReading
        // A busy pass keeps no progress, so there is no count to give.
        guard n > 0 else { return "Still reading. The usage history was busy, so these figures may grow." }
        return "Still reading \(n.formatted()) \(n == 1 ? "session" : "sessions"). These figures will grow until it finishes."
    }
    /// The line under the price field. It says what the field does, or why it cannot yet.
    static func compareHint(share: Double?, price: Double?, measured: Bool = true, measuredCalls: Int = 0) -> String {
        // Measured calls with no price at all: the headline says they were measured, so the hint cannot say there are none.
        if !measured && measuredCalls > 0 { return "COS has measured calls, but none has a verified price, so there is no dollar share yet. Your price stays on this Mac." }
        if !measured { return "There are no measured calls yet. Once COS has some, this shows its share of what you pay. Your price stays on this Mac." }
        if price == nil { return "Add it to see COS's share of what you pay. It stays on this Mac and is never sent." }
        if share == nil { return "The comparison needs a current Usage total and a measured figure. Your price stays on this Mac." }
        return "COS's share of your usage, times what you pay. Your price stays on this Mac and is never sent."
    }
    /// The disclosure's words, written for someone who has never read a ledger.
    static func method(_ report: CosUsageReport) -> [String] {
        var lines = [
            "Measured means the provider reported the tokens, in a session log or a record COS keeps. Estimated means COS only has the length of the text, so it divides characters by four and uses the model's plain rate. Cache reads and system prompts aren't in that, which is why an estimate says at least.",
            "Estimated figures stay out of every measured total. Rates are standard API rates, checked \(ratesCheckedOnWords(report)). A model with no verified rate shows tokens and No price, never $0. A dollar figure that leaves out some calls with no rate ends in a +.",
            "The total you ran is what Usage counted in these 30 days, plus COS calls Usage can't see because they keep no session log.",
            "A Work run counts from its start until you next typed in that session, another session messaged it, or its last turn finished. COS tells a typed turn from a tool result by the row's type and never reads the words. Background work the run started counts as the run. With none of those endings in the log, a run has no provable end and stays in the wider figure only. The wider figure is everything in those sessions from the first run's start, and it stays out of every share.",
        ]
        let approximate = report.rows.reduce(0) { $0 + $1.approximateMatches }
        if approximate > 0 { lines.append("\(approximate.formatted()) \(approximate == 1 ? "call was" : "calls were") matched to \(approximate == 1 ? "its run" : "their runs") by time and model, because older servers write no id. Newer rows carry one.") }
        lines.append("Only counts, dates and model names are read from these logs. Nothing here leaves this Mac.")
        return lines
    }
    private static func ratesCheckedOnWords(_ report: CosUsageReport) -> String {
        guard let day = SessionUsageDay(report.ratesCheckedOn) else { return report.ratesCheckedOn }
        let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
        return "\(months[day.month - 1]) \(day.day), \(day.year)"
    }
    /// Sessions whose numbers are not in yet, in plain words. Still reading sits at the top of the page, so not here.
    static func sessionNotes(_ report: CosUsageReport, ranPartial: Bool = false) -> [String] {
        var notes: [String] = []
        if ranPartial {
            notes.append(shareLean(report, ranPartial: true) == .either
                ? "Some of your own sessions use models with no verified price, and COS's own figure leaves some calls out too. Neither side is complete, so the share can be higher or lower."
                : "Some of your own sessions use models with no verified price. They aren't in the total you ran, so it is higher than shown and COS's share of it is lower.")
        }
        let s = report.sessions
        if s.compressed > 0 { notes.append("\(s.compressed.formatted()) \(s.compressed == 1 ? "session is" : "sessions are") compressed and could not be read, so their cost is not in these figures.") }
        if s.noLogs > 0 { notes.append("\(s.noLogs.formatted()) \(s.noLogs == 1 ? "session has" : "sessions have") no log left on this Mac, so their cost is not in these figures.") }
        if s.busy { notes.append("The usage history was busy, so this pass read nothing new. COS tries again soon.") }
        if s.failed { notes.append("COS could not read the usage history, so this pass read nothing new. It tries again in \(slowSeconds / 60) minutes.") }
        // The line is about the Answers row. Without one, there are no answers for it to blame the server for.
        if !report.runLedgersFound, overhead(report).contains(where: { $0.category == .answers && $0.calls > 0 }) { notes.append("This server has no run records, so answers stay estimated.") }
        if report.undatedCalls > 0 { notes.append("\(report.undatedCalls.formatted()) \(report.undatedCalls == 1 ? "call has" : "calls have") no readable date, so \(report.undatedCalls == 1 ? "it isn't" : "they aren't") in these 30 days.") }
        if report.unreadableRows > 0 { notes.append("\(report.unreadableRows.formatted()) \(report.unreadableRows == 1 ? "line" : "lines") could not be read at all.") }
        return notes
    }
}
