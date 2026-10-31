import AppKit
import SwiftUI
import Charts

@MainActor
final class SessionUsageStore: ObservableObject {
    @Published var report: SessionUsageReport?
    @Published var loading = false
    @Published var error: String?
    @Published var enabled = !UserDefaults.standard.bool(forKey: "sessionUsagePaused") {
        didSet { UserDefaults.standard.set(!enabled, forKey: "sessionUsagePaused") }
    }
    /// Off until the person turns it on: it reads Cursor's sign-in from Keychain and asks Cursor for usage.
    @Published var cursorEnabled = UserDefaults.standard.bool(forKey: "sessionUsageCursorFeed") {
        didSet { UserDefaults.standard.set(cursorEnabled, forKey: "sessionUsageCursorFeed") }
    }
    /// Someone who has never run Cursor has nothing to count, so the page does not offer it.
    let cursorOnThisMac = FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor").path)
    var offersCursor: Bool { cursorEnabled || cursorOnThisMac }
    private let helper = HelperClient()
    private var loop: Task<Void, Never>?
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                if self?.enabled == true { await self?.refresh() }
                else if self?.report == nil { await self?.refresh(importNew: false) }
                let pending = self?.enabled == true && ((self?.report?.pendingFiles ?? 0) > 0 || self?.report?.cursorFeed?.pending == true) && self?.error == nil
                try? await Task.sleep(for: .seconds(pending ? 15 : 300))
            }
        }
    }
    func refresh(importNew: Bool = true, cursorNow: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        var arguments = importNew ? ["session-usage"] : ["session-usage", "--read-only"]
        if cursorEnabled { arguments.append("--cursor") }
        if cursorEnabled && cursorNow { arguments.append("--cursor-now") }
        do {
            let result = try await helper.run(arguments, timeout: 45)
            guard result.ok else { throw HelperClientError.commandFailed(result.message) }
            report = try JSONDecoder().decode(SessionUsageReport.self, from: JSONEncoder().encode(result.details))
            error = nil
        } catch { self.error = "Usage could not refresh: \(error.localizedDescription)" }
    }
    /// The one place the feed turns on. A refresh already running must not swallow the first sync.
    func countCursorTokens() {
        cursorEnabled = true
        Task {
            while loading { try? await Task.sleep(for: .milliseconds(200)) }
            // The first read takes a few passes. Keep the person who just asked in the loop, without waiting on the
            // five-minute timer, and bounded in case something stays pending.
            for _ in 0..<12 {
                await refresh(cursorNow: true)
                guard report?.cursorFeed?.pending == true, error == nil else { break }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }
}

/// Chart beside inspector when both fit, stacked when they do not. Chosen from the real width, never from a guess
/// at what a flexible chart would like.
struct SessionUsageSplitLayout: Layout {
    var inspectorWidth: CGFloat = 320
    var minimumChart: CGFloat = 480
    var gap: CGFloat = 28
    /// The chart section's height when the inspector does not ask for more.
    var chartHeight: CGFloat = 440
    private func sideBySide(_ width: CGFloat) -> Bool { width >= minimumChart + inspectorWidth + gap }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? 1000
        if sideBySide(width) {
            let side = subviews[1].sizeThatFits(ProposedViewSize(width: inspectorWidth, height: nil))
            return CGSize(width: width, height: max(chartHeight, side.height))
        }
        let side = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: chartHeight + gap + side.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if sideBySide(bounds.width) {
            // The chart takes the inspector's height, so the two columns end together.
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width - inspectorWidth - gap, height: bounds.height))
            subviews[1].place(at: CGPoint(x: bounds.maxX - inspectorWidth, y: bounds.minY), proposal: ProposedViewSize(width: inspectorWidth, height: bounds.height))
        } else {
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: chartHeight))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + chartHeight + gap), proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

struct SessionUsageView: View {
    private typealias P = SessionUsagePresentation
    /// What the chart sentence offers. New tokens is the ledger's cache-reads-excluded count.
    private enum SentenceMeasure: String, CaseIterable { case all = "All tokens", new = "New tokens", value = "API value" }
    @ObservedObject var store: SessionUsageStore
    @State private var month = "Last 30 days"
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -29, to: Date())!
    @State private var customEnd = Date()
    @State private var timeScale: SessionUsageTimeScale = .daily
    /// Someone chose a scale, so a period change stops choosing one for them.
    @State private var scalePicked = false
    /// The scale in use before All history switched to Monthly, restored on leaving it.
    @State private var scaleBeforeHistory: SessionUsageTimeScale?
    @State private var measure: SessionUsageMeasure = .tokens
    @State private var seriesMode: SessionUsageSeries = .providers
    @State private var lineChart = false
    @State private var slice = SessionUsageSlice()
    @State private var excludeCacheReads = false
    @State private var inspection: SessionUsageInspection?
    @State private var dayBreakdownExpanded = false
    @State private var modelSort: SessionUsageModelSort = .tokens
    @State private var modelSortAscending = false
    @State private var daySort: SessionUsageDaySort = .date
    @State private var daySortAscending = false
    @State private var expandedTools: Set<String> = []
    @State private var showNotes = false
    /// The scale in use before Busiest day or a daily row jumped to Daily, restored by Show the whole period.
    @State private var scaleBeforeDayJump: SessionUsageTimeScale?
    @State private var exportStatus: String?
    /// Which optional table columns show. Remembered, because someone who wants them wants them every time.
    @State private var extraColumns: [TableColumn] = TableColumn.remembered
    @State private var narrow = false

    /// Table detail beyond the core four. Records and Last used start on, because they differ most from row to row.
    enum TableColumn: String, CaseIterable, Identifiable {
        case records = "Records", cacheReads = "Cache reads", perMillion = "Per 1M new", lastUsed = "Last used"
        var id: String { rawValue }
        var help: String {
            switch self {
            case .records: return "Usage records, about one for each model response."
            case .cacheReads: return "How much of all tokens was context read again from cache."
            case .perMillion: return "API value for each million new tokens, priced records only."
            case .lastUsed: return "The last day with a record in this selection."
            }
        }
        static let storageKey = "sessionUsageTableColumns"
        static var remembered: [TableColumn] {
            guard let names = UserDefaults.standard.stringArray(forKey: storageKey) else { return [.records, .lastUsed] }
            return allCases.filter { names.contains($0.rawValue) }
        }
    }

    init(store: SessionUsageStore, initialPeriod: String? = nil, initialInspection: String? = nil,
         initialDates: (Date, Date)? = nil, initialCostChart: Bool = false,
         initialExcludeCacheReads: Bool = false, initialDayBreakdownExpanded: Bool = false,
         initialTimeScale: SessionUsageTimeScale? = nil, initialMeasure: SessionUsageMeasure? = nil,
         initialSeries: SessionUsageSeries = .providers, initialLineChart: Bool = false,
         initialProvider: String = SessionUsagePresentation.allProviders, initialModel: String = SessionUsagePresentation.allModels,
         initialModelSort: SessionUsageModelSort = .tokens, initialDaySort: SessionUsageDaySort = .date, initialShowNotes: Bool = false,
         initialColumns: [TableColumn]? = nil) {
        self.store = store
        if let initialColumns { _extraColumns = State(initialValue: initialColumns) }
        let period = initialPeriod ?? "Last 30 days"
        let scale = initialTimeScale ?? P.defaultScale(for: period)
        let chartMeasure = initialMeasure ?? (initialCostChart ? .cost : .tokens)
        _month = State(initialValue: period)
        _timeScale = State(initialValue: scale)
        _scalePicked = State(initialValue: initialTimeScale != nil)
        _measure = State(initialValue: chartMeasure)
        _seriesMode = State(initialValue: P.series(initialSeries, for: chartMeasure))
        _lineChart = State(initialValue: initialLineChart)
        _slice = State(initialValue: SessionUsageSlice(provider: initialProvider, model: initialModel))
        _inspection = State(initialValue: initialInspection.map { SessionUsageInspection(key: $0, scale: scale) })
        if let initialDates {
            _customStart = State(initialValue: initialDates.0)
            _customEnd = State(initialValue: initialDates.1)
        }
        _excludeCacheReads = State(initialValue: initialExcludeCacheReads)
        _dayBreakdownExpanded = State(initialValue: initialDayBreakdownExpanded)
        _modelSort = State(initialValue: initialModelSort)
        _modelSortAscending = State(initialValue: P.defaultAscending(initialModelSort))
        _daySort = State(initialValue: initialDaySort)
        _showNotes = State(initialValue: initialShowNotes)
    }

    private static func monthKey(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"; return f.string(from: date)
    }
    private var provider: String { slice.provider }
    private var model: String { slice.model }
    private var buckets: [SessionUsageBucket] { store.report?.buckets ?? [] }
    private var providers: [String] { Array(Set(buckets.map(\.provider))).sorted() }
    private var models: [String] { Array(Set(buckets.filter { provider == P.allProviders || $0.provider == provider }.map(\.model))).sorted() }
    private var months: [String] { Array(Set(buckets.map { String($0.day.prefix(7)) } + [Self.monthKey(Date())])).sorted(by: >) }
    private var reportingZone: TimeZone { TimeZone(identifier: store.report?.timeZone ?? "") ?? .current }
    private var periodRows: [SessionUsageBucket] {
        P.selectPeriod(buckets, period: month, now: Date(), timeZone: reportingZone, customStart: customStart, customEnd: customEnd)
    }
    private var selected: [SessionUsageBucket] {
        periodRows.filter { (provider == P.allProviders || $0.provider == provider) && (model == P.allModels || $0.model == model) }
    }
    private var selectionBounds: ClosedRange<String>? {
        P.selectionBounds(period: month, now: Date(), timeZone: reportingZone, customStart: customStart, customEnd: customEnd)
    }
    private var periodKeys: [String] {
        Array(Set(P.periodKeyMap(selected, scale: timeScale).values)).sorted()
    }
    /// The inspection shown now: only one chosen on the current scale.
    private var inspectedPeriod: String? { inspection?.scale == timeScale ? inspection?.key : nil }
    private var inspectedBinding: Binding<String?> {
        Binding(get: { inspectedPeriod }, set: { key in
            if let key { inspection = SessionUsageInspection(key: key, scale: timeScale) } else { showWholePeriod() }
        })
    }
    private func measured(_ counts: SessionUsageCounts) -> Int64 { P.tokenCount(counts, excludingCacheReads: excludeCacheReads) }
    private func periodValues(_ key: String) -> [SessionUsageBucket] {
        selected.filter { P.periodKey(for: $0.day, scale: timeScale) == key }
    }
    private func periodTitle(_ key: String) -> String { P.periodTitle(for: key, scale: timeScale, within: selectionBounds) }
    private var counts: SessionUsageCounts { selected.reduce(SessionUsageCounts()) { $0 + $1.counts } }
    private var unpriced: Int { selected.reduce(0) { $0 + $1.events - $1.pricedEvents } }
    private var dateFormatter: DateFormatter { P.dayFormatter(timeZone: reportingZone) }
    private var sortedDays: [P.Summary] {
        P.sortDays(selected, by: daySort, ascending: daySortAscending, excludingCacheReads: excludeCacheReads)
    }
    private var comparison: P.PeriodComparison {
        P.comparePeriod(allRows: buckets, selectedRows: selected, period: month, provider: provider, model: model, measure: measure,
            excludingCacheReads: excludeCacheReads, now: Date(), timeZone: reportingZone, customStart: customStart, customEnd: customEnd)
    }
    private var hasFilter: Bool { provider != P.allProviders || model != P.allModels }
    /// Everything an export describes. Any change makes an earlier "Copied" line stale.
    private var exportScope: String {
        [month, dateFormatter.string(from: customStart), dateFormatter.string(from: customEnd), provider, model,
         String(excludeCacheReads), timeScale.rawValue, inspectedPeriod ?? ""].joined(separator: "|")
    }
    private var sentenceMeasure: SentenceMeasure {
        measure == .cost ? .value : excludeCacheReads ? .new : .all
    }
    private func choose(_ value: SentenceMeasure) {
        switch value {
        case .all: measure = .tokens; excludeCacheReads = false
        case .new: measure = .tokens; excludeCacheReads = true
        case .value: measure = .cost; excludeCacheReads = false
        }
    }

    struct Point: Identifiable {
        var date: Date; var series: String; var tokens: Int64; var usd: Double
        var pricedEvents: Int = 1
        var events: Int = 1
        var key: String = ""
        var id: String { String(date.timeIntervalSince1970) + series }
    }

    /// The six largest models by the selected tokens. The chart and the inspector name the same six.
    private var topModels: [String] {
        var totals: [String: Int64] = [:]
        for row in selected { totals[row.model, default: 0] += measured(row.counts) }
        return Array(totals.keys.sorted { a, b in
            let left = totals[a, default: 0], right = totals[b, default: 0]
            return left == right ? a < b : left > right
        }.prefix(6))
    }
    /// Stable hues by rank, so two models never share a colour in one chart.
    private var modelColors: [String: Color] {
        var map: [String: Color] = [:]
        for (index, id) in topModels.enumerated() {
            map[P.modelName(id)] = SessionUsageChart.rankedColors[index % SessionUsageChart.rankedColors.count]
        }
        map["Other models"] = .gray
        return map
    }

    private var points: [Point] {
        let rows = selected
        let calendar = P.reportingCalendar(reportingZone)
        let keyByDay = P.periodKeyMap(rows, scale: timeScale)
        let byPeriod = Dictionary(grouping: rows) { keyByDay[$0.day] ?? $0.day }
        var result: [Point] = []
        if seriesMode == .categories {
            for (key, group) in byPeriod {
                guard let date = P.noon(of: P.periodStart(key), calendar: calendar) else { continue }
                let groupCounts = group.reduce(SessionUsageCounts()) { $0 + $1.counts }
                let events = group.reduce(0) { $0 + $1.events }, pricedEvents = group.reduce(0) { $0 + $1.pricedEvents }
                for category in P.tokenMix(groupCounts, excludingCacheReads: excludeCacheReads, rows: group)
                where measure == .cost || !category.excludedFromTokens {
                    result.append(Point(date: date, series: P.categoryTitle(category.id), tokens: category.count, usd: category.estimatedUSD, pricedEvents: pricedEvents, events: events, key: key))
                }
            }
        } else {
            let top = Set(topModels)
            for (key, group) in byPeriod {
                guard let date = P.noon(of: P.periodStart(key), calendar: calendar) else { continue }
                let bySeries = Dictionary(grouping: group) { row in
                    seriesMode == .providers ? P.toolName(row.provider) : top.contains(row.model) ? P.modelName(row.model) : "Other models"
                }
                for (series, members) in bySeries {
                    result.append(Point(date: date, series: series, tokens: members.reduce(Int64(0)) { $0 + measured($1.counts) },
                        usd: members.reduce(0.0) { $0 + $1.estimatedUSD },
                        pricedEvents: members.reduce(0) { $0 + $1.pricedEvents }, events: members.reduce(0) { $0 + $1.events }, key: key))
                }
            }
        }
        // The largest series sits at the bottom of every stack.
        var totals: [String: Double] = [:]
        for point in result { totals[point.series, default: 0] += measure == .cost ? point.usd : Double(point.tokens) }
        return result.sorted { a, b in
            if a.date != b.date { return a.date < b.date }
            let left = totals[a.series, default: 0], right = totals[b.series, default: 0]
            return left == right ? a.series < b.series : left > right
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                filterRow
                if let exportStatus {
                    Text(exportStatus).font(COSType.body(11)).foregroundStyle(COSPalette.subtle).padding(.top, 8)
                }
                if store.report == nil || buckets.isEmpty {
                    emptyHistory.padding(.top, 16)
                } else {
                    if month == P.customDates { customDates.padding(.top, 12) }
                    statusLines
                    if !selected.isEmpty { figures.padding(.top, 22) }
                    if selected.isEmpty {
                        Text("No recorded usage for this selection. A missing tool is not zero usage.")
                            .frame(maxWidth: .infinity, minHeight: 160).foregroundStyle(COSPalette.subtle)
                    } else {
                        SessionUsageSplitLayout {
                            chartSection
                            inspector
                        }.padding(.top, 26)
                        dayByDay.padding(.top, 34)
                        usageTable.padding(.top, 34)
                        dayBreakdown.padding(.top, 20)
                    }
                }
                footer.padding(.top, 20)
            }
            .padding(22)
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < 944 } action: { narrow = $0 }
        .onChange(of: slice) { _, _ in showWholePeriod() }
        .onChange(of: month) { _, value in
            if scalePicked {
                let next = P.timeScale(afterChangingTo: value, current: timeScale, remembered: scaleBeforeHistory)
                scaleBeforeHistory = next.remembered
                timeScale = next.scale
            } else {
                timeScale = P.defaultScale(for: value)
            }
            inspection = nil
            scaleBeforeDayJump = nil
        }
        // A click that sets the scale and the inspection together keeps it; a day carries into its week or month.
        .onChange(of: timeScale) { _, scale in inspection = P.reconcile(inspection, to: scale, keys: periodKeys) }
        .onChange(of: periodKeys) { _, keys in
            if let key = inspectedPeriod, !keys.contains(key) { inspection = nil }
        }
        .onChange(of: customStart) { _, _ in inspection = nil }
        .onChange(of: customEnd) { _, _ in inspection = nil }
        .onChange(of: exportScope) { _, _ in exportStatus = nil }
        .task { if store.report == nil { await store.refresh(importNew: store.enabled) } }
    }

    private func inspectDay(_ day: String) {
        if timeScale != .daily { scaleBeforeDayJump = timeScale }
        inspection = SessionUsageInspection(key: day, scale: .daily)
        timeScale = .daily
    }
    private func pickScale(_ scale: SessionUsageTimeScale) {
        timeScale = scale
        scalePicked = true
        scaleBeforeDayJump = nil
    }
    private func showWholePeriod() {
        inspection = nil
        if let scale = scaleBeforeDayJump { timeScale = scale; scaleBeforeDayJump = nil }
    }

    private var filterRow: some View {
        HStack(alignment: .center, spacing: 8) {
            COSDropdown("Period", selection: $month, options: (P.periods + months).map { COSDropdownOption($0, $0) }, showsLabel: false)
                .frame(width: narrow ? 142 : 150)
            COSDropdown("Tool", selection: Binding(get: { slice.provider }, set: { value in
                slice.choose(provider: value)
                if slice.model != P.allModels && !models.contains(slice.model) { slice.choose(model: P.allModels) }
            }), options: [COSDropdownOption(P.allProviders, P.allProviders)] + providers.map { COSDropdownOption($0, P.toolName($0)) }, showsLabel: false)
                .frame(width: narrow ? 108 : 150)
            COSDropdown("Model", selection: Binding(get: { slice.model }, set: { slice.choose(model: $0) }),
                        options: [COSDropdownOption(P.allModels, P.allModels)] + models.map { COSDropdownOption($0, P.modelName($0)) }, showsLabel: false)
                .frame(width: narrow ? 132 : 190)
            if hasFilter {
                Button("Clear filters") { slice.reset(); showWholePeriod() }
                    .buttonStyle(.plain).font(COSType.body(12)).foregroundStyle(COSPalette.accent)
            }
            Spacer(minLength: 8)
            if let updatedTime, !(narrow && hasFilter) {
                Text("Updated \(updatedTime)").font(COSType.body(12)).foregroundStyle(COSPalette.subtle).monospacedDigit().lineLimit(1).fixedSize()
            }
            if store.loading { ProgressView().controlSize(.mini).accessibilityLabel("Refreshing usage") }
            Menu {
                Toggle("Track session usage on this Mac", isOn: $store.enabled)
                if store.offersCursor {
                    // Turning this on reads Keychain at once, so the item says so.
                    Toggle("Count Cursor tokens (reads your sign-in from Keychain)", isOn: Binding(get: { store.cursorEnabled }, set: { on in
                        if on { store.countCursorTokens() } else { store.cursorEnabled = false }
                    }))
                }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12, weight: .medium))
            }
            .cosMenu().fixedSize()
            .help("Usage settings").accessibilityLabel("Usage settings")
            Menu {
                Button("Copy as CSV") { copySlice(json: false) }
                Button("Copy as JSON") { copySlice(json: true) }
            } label: {
                HStack(spacing: 5) {
                    Text("Copy data").font(COSType.body(12, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(COSPalette.accent)
                }
            }
            .cosMenu()
            .disabled(selected.isEmpty)
            .fixedSize()
            .help("Copy the selected period and filters, narrowed to the inspected period when one is open.")
        }
    }

    @ViewBuilder private var statusLines: some View {
        if let error = store.error {
            Text(error).font(COSType.body(12)).foregroundStyle(COSPalette.danger).padding(.top, 10)
        }
        if let report = store.report, report.pendingFiles > 0 {
            Text("Reading older history: \(report.pendingFiles) files remaining. Totals will grow until it finishes.")
                .font(COSType.body(12)).foregroundStyle(COSPalette.subtle).padding(.top, 10)
        }
        if let feed = store.report?.cursorFeed, feed.pending, let message = feed.message {
            Text(message + " Totals will grow until it finishes.")
                .font(COSType.body(12)).foregroundStyle(COSPalette.subtle).padding(.top, 10)
        }
    }

    /// First load, or no history at all: one state instead of a chart, zero tiles and empty tables.
    private var emptyHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.report == nil && store.loading {
                ProgressView("Reading local usage…").controlSize(.small)
            } else if let error = store.error {
                Text(error).foregroundStyle(COSPalette.danger)
            } else if store.report == nil {
                Text("Usage has not been read yet. Refresh reads Claude Code and Codex logs on this Mac.").foregroundStyle(COSPalette.subtle)
            } else {
                Text("No usage recorded yet. Claude Code and Codex sessions on this Mac appear here once their logs are read. A missing tool is not zero usage.")
                    .foregroundStyle(COSPalette.subtle)
            }
            if let report = store.report, report.pendingFiles > 0 {
                Text("Reading older history: \(report.pendingFiles) files remaining. Totals will grow until it finishes.").foregroundStyle(COSPalette.subtle)
            }
            if store.offersCursor && !store.cursorEnabled {
                Button("Count Cursor tokens") { store.countCursorTokens() }.font(COSType.body(12)).fixedSize()
            }
        }
        .font(COSType.body(13))
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
        .padding(16)
        .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    private var updatedTime: String? {
        guard let stamp = store.report?.updatedAt, let date = ISO8601DateFormatter().date(from: stamp) else { return nil }
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: date)
    }

    private var cursorRowVisible: Bool {
        !buckets.isEmpty && !selected.isEmpty && provider == P.allProviders && !providers.contains("Cursor") && store.offersCursor
    }

    /// Names what the + is leaving out, instead of only counting it.
    private var unpricedNote: String? {
        guard unpriced > 0 else { return nil }
        var missing: [String: Int] = [:]
        for row in selected where row.pricedEvents < row.events { missing[P.modelName(row.model), default: 0] += row.events - row.pricedEvents }
        let names = missing.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        let listed = names.prefix(2).joined(separator: " and ") + (names.count > 2 ? " and \(names.count - 2) more" : "")
        return "A + means a figure leaves out \(unpriced.formatted()) records with no verified price: \(listed)."
    }

    private var cursorCheckedTime: String? {
        guard store.cursorEnabled, let stamp = store.report?.cursorFeed?.lastSuccessAt, let date = ISO8601DateFormatter().date(from: stamp) else { return nil }
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        return f.string(from: date)
    }

    private var copySignInButton: some View {
        Button("Copy sign-in command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("cursor-agent login", forType: .string)
        }.font(COSType.body(12)).fixedSize()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            if let report = store.report {
                ChipFlowLayout(spacing: 14) {
                    Text("Read from \(report.filesIndexed.formatted()) log files on this Mac.")
                    if report.unreadableFiles > 0 { Text("\(report.unreadableFiles.formatted()) could not be read.") }
                    if let unpricedNote { Text(unpricedNote) }
                    if let checked = cursorCheckedTime { Text("Cursor checked \(checked).") }
                    // While the table's Cursor row is showing, it already says this.
                    if let feed = report.cursorFeed, feed.isProblem, !cursorRowVisible, let message = feed.message {
                        Text(message).foregroundStyle(COSPalette.amber)
                        if feed.state == .signIn || feed.state == .expired { copySignInButton }
                    }
                }
                .font(COSType.body(12)).foregroundStyle(COSPalette.subtle).monospacedDigit()
            }
            DisclosureGroup("How this is counted", isExpanded: $showNotes) {
                VStack(alignment: .leading, spacing: 10) {
                    if store.offersCursor {
                        Text("Counting Cursor reads your Cursor sign-in from this Mac's Keychain and asks Cursor for your usage. Only counts, dates, model names and each request's reported cost are stored. Turning it off keeps what was already counted.")
                    }
                    Text("While COS Control is running it refreshes every five minutes. Pausing keeps existing history. Only counts, dates, model names and file checkpoints are stored. Local logs are never uploaded.")
                    if let report = store.report {
                        ForEach(report.coverage, id: \.self) { Text($0) }
                        if report.unreadableFiles + report.malformedRows + report.missingBaselineEvents > 0 {
                            Text("Gaps: \(report.unreadableFiles) unreadable files or oversized rows, \(report.malformedRows) malformed rows, \(report.missingBaselineEvents) missing usage baselines. Totals reflect what could be read.")
                        }
                        Text("Calendar dates in \(reportingZone.identifier). Days without logs are missing, not zero. Weeks run Monday to Sunday, and the first and last week or month of a period can be partial.")
                    }
                    Text("New tokens are input, output and cache writes. Output includes reasoning. Cache reads are repeated context, not cache savings.")
                    Text("API value is the standard API rate, checked October 25, 2026 and applied to all dates. It leaves out discounts, speed tiers, tools and taxes, and it is not your subscription bill. Cursor's value is the per-request cost Cursor reports.")
                    Text(P.allowanceNote)
                    HStack(spacing: 14) {
                        Link("Anthropic pricing", destination: URL(string: SessionUsagePricing.sources[0])!)
                        Link("OpenAI pricing", destination: URL(string: SessionUsagePricing.sources[1])!)
                    }
                }
                .font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 680, alignment: .leading)
                .padding(.top, 8)
            }
            .font(COSType.body(12)).tint(COSPalette.accent)
        }
    }

    private func copySlice(json: Bool) {
        let active = inspectedPeriod.map { SessionUsageInspection(key: $0, scale: timeScale) }
        let rows = P.exportRows(selected, inspection: active)
        let custom = month == P.customDates
        let context = P.ExportContext(period: month,
            customStart: custom ? dateFormatter.string(from: customStart) : nil, customEnd: custom ? dateFormatter.string(from: customEnd) : nil,
            provider: provider, model: model, excludingCacheReads: excludeCacheReads, timeScale: timeScale,
            inspection: active, inspectedTitle: active.map { periodTitle($0.key) }, timeZone: reportingZone.identifier,
            pricingVersion: store.report?.pricingVersion ?? SessionUsagePricing.version)
        let text = json ? P.exportJSON(rows, context: context) : P.exportCSV(rows, excludingCacheReads: excludeCacheReads)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        var scope = [month]
        if provider != P.allProviders { scope.append(P.toolName(provider)) }
        if model != P.allModels { scope.append(P.modelName(model)) }
        if excludeCacheReads { scope.append("new tokens only") }
        if let active { scope.append(periodTitle(active.key)) }
        exportStatus = "Copied \(rows.count) daily rows as \(json ? "JSON" : "CSV"): \(scope.joined(separator: ", "))."
    }

    // MARK: Chart

    /// One word of the chart sentence, opening its own menu.
    private func sentenceWord(_ title: String, label: String, options: [(String, () -> Void)]) -> some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.0, action: option.1)
            }
        } label: {
            HStack(spacing: 3) {
                Text(title).font(COSType.body(15, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }.foregroundStyle(COSPalette.accent)
        }
        .cosWordMenu().fixedSize()
        .accessibilityLabel(label)
        .accessibilityValue(title)
    }

    private var scaleWord: String {
        switch timeScale {
        case .daily: return "day"
        case .weekly: return "week"
        case .monthly: return "month"
        }
    }
    private var stackWord: String {
        switch seriesMode {
        case .providers: return "tool"
        case .models: return "model"
        case .categories: return "token type"
        }
    }

    private var chartSentence: some View {
        HStack(alignment: .center, spacing: 6) {
            sentenceWord(sentenceMeasure.rawValue, label: "Measure", options: SentenceMeasure.allCases.map { value in (value.rawValue, { choose(value) }) })
            Text("by").font(COSType.body(15, weight: .medium))
            sentenceWord(stackWord, label: "Stack by", options: [
                ("tool", { seriesMode = .providers }), ("model", { seriesMode = .models }), ("token type", { seriesMode = .categories })
            ])
            Text("per").font(COSType.body(15, weight: .medium))
            sentenceWord(scaleWord, label: "Time scale", options: [
                ("day", { pickScale(.daily) }), ("week", { pickScale(.weekly) }), ("month", { pickScale(.monthly) })
            ])
            Spacer(minLength: 8)
            chartStyleButton(lines: false, symbol: "chart.bar.fill", help: "Stacked bars")
            chartStyleButton(lines: true, symbol: "chart.line.uptrend.xyaxis", help: "Lines")
        }
    }

    private func chartStyleButton(lines: Bool, symbol: String, help: String) -> some View {
        Button { lineChart = lines } label: {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(lineChart == lines ? COSPalette.accent : COSPalette.subtle.opacity(0.7))
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(lineChart == lines ? .isSelected : [])
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            chartSentence
            if measure == .cost && selected.allSatisfy({ $0.pricedEvents == 0 }) {
                Text("No verified prices for this selection.").frame(maxWidth: .infinity, minHeight: SessionUsageChart.height).foregroundStyle(COSPalette.subtle)
            } else if measure == .cost && seriesMode == .categories && P.costSplit(selected).splitUSD == 0 {
                Text("This cost cannot be split by token type. Cursor reports one cost per request.").frame(maxWidth: .infinity, minHeight: SessionUsageChart.height).foregroundStyle(COSPalette.subtle)
            } else {
                SessionUsageChart(points: points, rows: selected, scale: timeScale, measure: measure,
                    excludeCacheReads: excludeCacheReads, timeZone: reportingZone, inspectedPeriod: inspectedBinding,
                    lineChart: lineChart, bounds: selectionBounds, seriesColors: seriesMode == .models ? modelColors : [:],
                    partialPeriods: partialPeriods)
            }
            legend
        }
    }

    private var partialPeriods: Set<String> {
        let today = dateFormatter.string(from: Date())
        let firstRecord = selected.map(\.day).min()
        return P.partialPeriods(periodKeys, scale: timeScale, firstDay: [selectionBounds?.lowerBound, firstRecord].compactMap { $0 }.max(),
                                lastDay: min(selectionBounds?.upperBound ?? today, today))
    }

    // MARK: Figures

    private struct Figure: Identifiable {
        let title: String
        let value: String
        var note: String? = nil
        let help: String
        var id: String { title }
    }

    private func priorNote(_ delta: String, _ current: P.PeriodComparison, pricedOnly: Bool = false) -> String? {
        guard current.hasPriorBaseline, !current.partialPriorHistory, delta != "Unavailable" else { return nil }
        return delta + " on the period before" + (pricedOnly ? ", priced records" : "")
    }

    /// The answers people open this page for, before any chart. Tool and model filters apply; a clicked bar does not
    /// change them, the panel beside the chart covers that bar.
    private var figures: some View {
        let compare = { (excluding: Bool) in
            P.comparePeriod(allRows: buckets, selectedRows: selected, period: month, provider: provider, model: model, measure: .tokens,
                excludingCacheReads: excluding, now: Date(), timeZone: reportingZone, customStart: customStart, customEnd: customEnd)
        }
        let all = compare(false), new = compare(true)
        let days = Set(selected.map(\.day)).count
        let matching = buckets.filter { (provider == P.allProviders || $0.provider == provider) && (model == P.allModels || $0.model == model) }
        let pace = P.monthPace(matching, now: Date(), timeZone: reportingZone)
        var list = [
            Figure(title: "API value", value: P.costCell(selected), note: priorNote(all.costDeltaLabel, all, pricedOnly: all.costDeltaPartial),
                   help: "What these tokens would cost at standard API rates. Not your subscription bill."),
            Figure(title: "New tokens", value: P.shortTokens(P.tokenCount(counts, excludingCacheReads: true)), note: priorNote(new.tokenDeltaLabel, new),
                   help: "Input, output and cache writes."),
            Figure(title: "All tokens", value: P.shortTokens(counts.total), note: P.share(counts.cacheRead, of: counts.total) + " read again from cache",
                   help: "New tokens plus context read again from cache."),
            Figure(title: "API value a day", value: P.dailyValueLabel(selected), note: "\(days.formatted()) \(days == 1 ? "day" : "days") with usage",
                   help: "Average across days with a price. Days without logs or a price are left out, not counted as zero.")
        ]
        if let pace, pace.hasPrice {
            list.append(Figure(title: "\(pace.month) so far", value: P.dollars(pace.usd) + (pace.complete ? "" : "+"),
                note: pace.projectedUSD.map { "About \(P.dollars($0)) by \(pace.lastDay)" },
                help: "This calendar month for the tool and model in view, whatever period is selected. The estimate is a straight line from the days so far."))
        }
        return HStack(alignment: .top, spacing: 16) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, figure in
                VStack(alignment: .leading, spacing: 3) {
                    Text(figure.value).font(COSType.display(index == 0 ? 32 : 24)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(height: 40, alignment: .bottomLeading)
                    Text(figure.title).font(COSType.body(12, weight: .medium))
                    if let note = figure.note {
                        Text(note).font(COSType.body(11)).foregroundStyle(COSPalette.subtle).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(figure.help)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Day by day

    private func dayValue(_ summary: P.Summary) -> Double {
        measure == .cost ? summary.estimatedUSD : Double(measured(summary.counts))
    }
    private func dayFigure(_ value: Double) -> String {
        measure == .cost ? P.dollars(value) : P.shortTokens(Int64(value))
    }
    /// Measuring value, a day with no price has no figure to show or average.
    private func dayCounted(_ summary: P.Summary) -> Bool { measure != .cost || summary.pricedEvents > 0 }
    private var thisYear: Int { Int(dateFormatter.string(from: Date()).prefix(4)) ?? 0 }

    @ViewBuilder private var dayByDay: some View {
        let today = dateFormatter.string(from: Date())
        let weeks = P.calendarWeeks(selected, bounds: selectionBounds, today: today)
        // Under three columns the bars above already say all of this.
        if weeks.count >= 3 {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(sentenceMeasure.rawValue) day by day").font(COSType.body(15, weight: .medium))
                SessionUsageCalendar(weeks: weeks, averages: P.weekdayAverages(selected, counted: dayCounted, value: dayValue), inspectedDay: timeScale == .daily ? inspectedPeriod : nil,
                    counted: dayCounted, value: dayValue, figure: dayFigure,
                    cellFigure: { summary in dayFigure(dayValue(summary)) + (measure == .cost && summary.pricedEvents < summary.events ? "+" : "") },
                    emptyWords: hasFilter ? "no records for this selection" : "no logs",
                    detail: { summary in
                        "\(P.periodTitle(for: summary.id, scale: .daily)): \(summary.costLabel), \(P.shortTokens(summary.counts.total)) tokens, \(P.shortTokens(P.tokenCount(summary.counts, excludingCacheReads: true))) new, \(summary.events.formatted()) records"
                    },
                    onPick: { day in
                        if timeScale == .daily && inspectedPeriod == day { showWholePeriod() } else { inspectDay(day) }
                    })
            }
        }
    }

    private var legend: some View {
        var totals: [String: Double] = [:]
        for point in points { totals[point.series, default: 0] += measure == .cost ? point.usd : Double(point.tokens) }
        let names = P.seriesOrder(totals)
        return ChipFlowLayout(spacing: 14) {
            ForEach(names, id: \.self) { name in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(seriesMode == .models ? (modelColors[name] ?? .gray) : SessionUsageChart.seriesColor(name)).frame(width: 9, height: 9)
                    Text(name)
                }
            }
            if seriesMode == .providers && provider == P.allProviders && !providers.contains("Cursor") && !store.cursorEnabled && store.offersCursor {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(COSPalette.subtle, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 9, height: 9)
                    Text("Cursor not counted yet")
                }
            }
            if !lineChart && !partialPeriods.isEmpty {
                // The chart draws an average only from four full periods.
                Text("Lighter bars cover part of a \(scaleWord)" + (periodKeys.count - partialPeriods.count >= 4 ? " and are left out of the average." : "."))
            }
        }
        .font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
    }

    private var customDates: some View {
        HStack(spacing: 16) {
            DatePicker("From", selection: $customStart, displayedComponents: .date)
            DatePicker("Through", selection: $customEnd, displayedComponents: .date)
            if dateFormatter.string(from: customStart) > dateFormatter.string(from: customEnd) {
                Text("Choose an end date on or after the start.").foregroundStyle(COSPalette.danger)
            }
        }.environment(\.timeZone, reportingZone).font(COSType.body(12))
    }

    // MARK: Inspector

    private func moveInspection(_ delta: Int) {
        let keys = periodKeys
        guard !keys.isEmpty else { return }
        guard let key = inspectedPeriod, let index = keys.firstIndex(of: key) else {
            inspection = SessionUsageInspection(key: delta < 0 ? keys[keys.count - 1] : keys[0], scale: timeScale)
            return
        }
        guard keys.indices.contains(index + delta) else { return }
        inspection = SessionUsageInspection(key: keys[index + delta], scale: timeScale)
    }

    private var wholePeriodTitle: String {
        var parts = [month == P.customDates ? (selectionBounds.map(P.dateRangeTitle) ?? month) : month]
        if provider != P.allProviders { parts.append(P.toolName(provider)) }
        if model != P.allModels { parts.append(P.modelName(model)) }
        return parts.joined(separator: ", ")
    }

    private var inspector: some View {
        let key = inspectedPeriod.flatMap { periodKeys.contains($0) ? $0 : nil }
        return SessionUsageInspector(
            title: key.map(periodTitle) ?? wholePeriodTitle,
            rows: key.map(periodValues) ?? selected,
            excludingCacheReads: excludeCacheReads,
            measure: measure,
            isPeriod: key != nil,
            canGoEarlier: key == nil ? !periodKeys.isEmpty : key != periodKeys.first,
            canGoLater: key == nil ? !periodKeys.isEmpty : key != periodKeys.last,
            comparison: key == nil ? comparison : nil,
            modelColors: seriesMode == .models ? modelColors : [:],
            onStep: moveInspection,
            onClear: showWholePeriod,
            onInspectDay: inspectDay
        )
    }

    // MARK: Table

    private func sortHeader(_ title: String, _ sort: SessionUsageModelSort, help: String) -> some View {
        Button {
            if modelSort == sort { modelSortAscending.toggle() } else { modelSort = sort; modelSortAscending = P.defaultAscending(sort) }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if modelSort == sort { Image(systemName: modelSortAscending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold)) }
            }
            .foregroundStyle(modelSort == sort ? Color.primary : COSPalette.subtle)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func modelCost(_ row: SessionUsageBucket) -> some View {
        let partial = row.pricedEvents > 0 && row.pricedEvents < row.events
        return Text(P.costCell([row]))
            .help(row.pricedEvents == 0 ? "No verified price; sorts last on API value." : partial ? "Partially priced: \(row.pricedEvents) of \(row.events) records have a verified price." : "All \(row.events) records priced.")
    }

    /// The Share column follows the chart: a share of value beside value, a share of tokens beside tokens.
    private func shareCell(_ rows: [SessionUsageBucket]) -> String {
        if measure == .cost { return P.valueShare(rows, of: selected.reduce(0) { $0 + $1.estimatedUSD }) }
        return P.share(measured(rows.reduce(SessionUsageCounts()) { $0 + $1.counts }), of: measured(counts))
    }
    private func newTokens(_ counts: SessionUsageCounts) -> String { P.shortTokens(P.tokenCount(counts, excludingCacheReads: true)) }
    /// The same share as a length, so the table scans without reading every number.
    private func shareBar(_ rows: [SessionUsageBucket], color: Color) -> some View {
        let fraction: Double
        if measure == .cost {
            let whole = selected.reduce(0.0) { $0 + $1.estimatedUSD }
            fraction = whole > 0 ? rows.reduce(0.0) { $0 + $1.estimatedUSD } / whole : 0
        } else {
            let whole = measured(counts)
            fraction = whole > 0 ? Double(measured(rows.reduce(SessionUsageCounts()) { $0 + $1.counts })) / Double(whole) : 0
        }
        let cell = shareCell(rows)
        return HStack(spacing: 8) {
            // A narrow window with every column on keeps the numbers and gives up the bars.
            if !(narrow && extraColumns.count > 2) {
                // An unpriced row has no share of value, and an empty track would read as zero.
                Capsule().fill(cell == "Unavailable" ? Color.clear : COSPalette.line).frame(width: 56, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule().fill(color).frame(width: fraction > 0 ? max(2, 56 * fraction) : 0, height: 5)
                    }
            }
            // The API value column beside it already says No price.
            Text(cell == "Unavailable" ? "" : cell).lineLimit(1).fixedSize().frame(minWidth: 40, alignment: .trailing)
        }
    }

    private func toggleColumn(_ column: TableColumn) {
        if extraColumns.contains(column) { extraColumns.removeAll { $0 == column } }
        else { extraColumns = TableColumn.allCases.filter { extraColumns.contains($0) || $0 == column } }
        UserDefaults.standard.set(extraColumns.map(\.rawValue), forKey: TableColumn.storageKey)
    }

    @ViewBuilder private func extraCells(_ rows: [SessionUsageBucket], lastUsed: [String: String]) -> some View {
        ForEach(extraColumns) { column in
            switch column {
            case .records: Text(rows.reduce(0) { $0 + $1.events }.formatted())
            case .cacheReads:
                let total = rows.reduce(SessionUsageCounts()) { $0 + $1.counts }
                Text(P.share(total.cacheRead, of: total.total))
            case .perMillion: Text(P.valuePerMillionNew(rows))
            case .lastUsed:
                Text(rows.compactMap { lastUsed[P.lastUsedKey($0)] }.max().map { P.shortDay($0, thisYear: thisYear) } ?? "")
            }
        }
    }

    private var usageTable: some View {
        // The columns name their own counts, so All tokens sorts by all tokens whatever the chart is showing.
        let groups = P.toolGroups(selected, by: modelSort, ascending: modelSortAscending)
        let lastUsed = P.lastUsed(selected)
        return VStack(alignment: .leading, spacing: 12) {
          HStack {
            // The inspector can show one bar. The table always covers the whole selection, so it says which.
            Text(inspectedPeriod == nil ? "Tool and model" : "Tool and model, \(wholePeriodTitle)").font(COSType.body(15, weight: .medium))
            Spacer()
            Menu {
                ForEach(TableColumn.allCases) { column in
                    Toggle(column.rawValue, isOn: Binding(get: { extraColumns.contains(column) }, set: { _ in toggleColumn(column) }))
                }
            } label: {
                HStack(spacing: 5) {
                    Text("Columns").font(COSType.body(12, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(COSPalette.accent)
                }
            }
            .cosMenu().fixedSize()
            .help("Choose which details the table shows")
          }
          Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 0) {
            GridRow {
                sortHeader("Name", .model, help: "Sort models by name").gridColumnAlignment(.leading)
                sortHeader("All tokens", .tokens, help: "Sort by all tokens")
                sortHeader("New tokens", .newTokens, help: "Sort by input, output and cache writes")
                ForEach(extraColumns) { column in
                    Text(column.rawValue).foregroundStyle(COSPalette.subtle).help(column.help)
                }
                Text("Share").foregroundStyle(COSPalette.subtle).help("Share of the selected \(measure == .cost ? "API value" : "tokens"). Never your subscription allowance.")
                sortHeader("API value", .cost, help: "Sort by API value; unpriced models stay last")
            }
            .font(COSType.body(11, weight: .medium)).padding(.bottom, 8)
            Divider()
            ForEach(groups) { group in
                toolRow(group, lastUsed: lastUsed)
                Divider()
                let open = expandedTools.contains(group.id) || model != P.allModels
                let shown = open ? group.models : Array(group.models.prefix(5))
                ForEach(shown) { row in
                    modelRow(row, lastUsed: lastUsed)
                    Divider()
                }
                if group.models.count > shown.count {
                    moreRow(group, hidden: Array(group.models.dropFirst(shown.count)), lastUsed: lastUsed)
                    Divider()
                } else if group.models.count > 5 && model == P.allModels {
                    GridRow {
                        Button("Show fewer") { expandedTools.remove(group.id) }
                            .buttonStyle(.plain).foregroundStyle(COSPalette.accent).padding(.leading, 17).gridColumnAlignment(.leading)
                        Color.clear.gridCellColumns(4 + extraColumns.count).frame(height: 1)
                    }.padding(.vertical, 8)
                    Divider()
                }
            }
            if provider == P.allProviders && !providers.contains("Cursor") && store.offersCursor { cursorRow; Divider() }
          }
          .font(COSType.body(13)).monospacedDigit()
        }
    }

    private func toolRow(_ group: P.ToolGroup, lastUsed: [String: String]) -> some View {
        let isFiltered = provider == group.id
        return GridRow {
            Button { slice.toggleProvider(group.id) } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(SessionUsageChart.seriesColor(group.tool)).frame(width: 9, height: 9)
                    Text(group.tool)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFiltered ? "Show all tools" : "Show only \(group.tool)")
            .gridColumnAlignment(.leading)
            Text(P.shortTokens(group.summary.counts.total))
            Text(newTokens(group.summary.counts))
            extraCells(group.models, lastUsed: lastUsed)
            shareBar(group.models, color: SessionUsageChart.seriesColor(group.tool))
            Text(P.costCell(group.models))
        }
        .font(COSType.body(14, weight: .semibold)).padding(.top, 13).padding(.bottom, 9)
    }

    private func modelRow(_ row: SessionUsageBucket, lastUsed: [String: String]) -> some View {
        let isFiltered = model == row.model && provider == row.provider
        return GridRow {
            Button { slice.toggleModel(provider: row.provider, model: row.model) } label: {
                Text(P.modelName(row.model)).fontWeight(isFiltered ? .semibold : .regular)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 17)
            .help(row.model)
            .gridColumnAlignment(.leading)
            Text(P.shortTokens(row.counts.total))
            Text(newTokens(row.counts))
            extraCells([row], lastUsed: lastUsed)
            shareBar([row], color: SessionUsageChart.seriesColor(P.toolName(row.provider)))
            modelCost(row)
        }
        .foregroundStyle(COSPalette.subtle).padding(.vertical, 8)
    }

    private func moreRow(_ group: P.ToolGroup, hidden: [SessionUsageBucket], lastUsed: [String: String]) -> some View {
        let total = hidden.reduce(SessionUsageCounts()) { $0 + $1.counts }
        return GridRow {
            Button("\(hidden.count) more \(hidden.count == 1 ? "model" : "models")") { expandedTools.insert(group.id) }
                .buttonStyle(.plain).foregroundStyle(COSPalette.accent).padding(.leading, 17)
                .gridColumnAlignment(.leading)
            Text(P.shortTokens(total.total))
            Text(newTokens(total))
            extraCells(hidden, lastUsed: lastUsed)
            shareBar(hidden, color: COSPalette.subtle)
            Text(P.costCell(hidden))
        }
        .foregroundStyle(COSPalette.subtle).padding(.vertical, 8)
    }

    private var cursorRow: some View {
        let feed = store.report?.cursorFeed
        let on = store.cursorEnabled
        let words = on ? (feed?.state == .ready ? "Cursor reports no token usage for this account." : feed?.message ?? "Reading your Cursor usage.") : "Cursor keeps its token counts on its servers. Counting them reads your Cursor sign-in from this Mac's Keychain and asks Cursor for your usage."
        return GridRow {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).strokeBorder(COSPalette.subtle, style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 9, height: 9)
                Text("Cursor").font(COSType.body(14, weight: .semibold))
            }.gridColumnAlignment(.leading)
            Text(words)
                .font(COSType.body(12)).foregroundStyle(feed?.isProblem == true ? COSPalette.amber : COSPalette.subtle)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .gridCellColumns(3 + extraColumns.count)
            if on {
                if feed?.state == .signIn || feed?.state == .expired {
                    copySignInButton
                } else { Color.clear.frame(width: 1, height: 1) }
            } else {
                Button("Count Cursor tokens") { store.countCursorTokens() }.font(COSType.body(12)).fixedSize()
            }
        }
        .padding(.top, 13).padding(.bottom, 9)
    }

    private func dayHeader(_ title: String, _ sort: SessionUsageDaySort) -> some View {
        Button {
            if daySort == sort { daySortAscending.toggle() } else { daySort = sort; daySortAscending = false }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if daySort == sort { Image(systemName: daySortAscending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold)) }
            }.foregroundStyle(daySort == sort ? Color.primary : COSPalette.subtle)
        }
        .buttonStyle(.plain)
        .help("Sort days by \(title)")
    }

    private var dayBreakdown: some View {
        DisclosureGroup("Daily breakdown, \(Set(selected.map(\.day)).count) recorded days", isExpanded: $dayBreakdownExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    dayHeader("Date", .date)
                    Spacer()
                    dayHeader("Tokens", .tokens)
                    Text("Share").frame(width: 52, alignment: .trailing).foregroundStyle(COSPalette.subtle)
                    dayHeader("Records", .records).frame(minWidth: 92, alignment: .trailing)
                    dayHeader("API value", .cost).frame(minWidth: 110, alignment: .trailing)
                }.font(COSType.body(11, weight: .medium))
                ForEach(sortedDays) { row in
                    let isInspected = timeScale == .daily && inspectedPeriod == row.id
                    let rowTokens = measured(row.counts)
                    Button {
                        if isInspected { showWholePeriod() } else { inspectDay(row.id) }
                    } label: {
                        HStack {
                            Text(P.weekdayDay(row.id, thisYear: thisYear)).fontWeight(isInspected ? .semibold : .regular).help(row.id)
                            Spacer()
                            Text(P.shortTokens(rowTokens))
                            Text(P.share(rowTokens, of: measured(counts)))
                                .foregroundStyle(COSPalette.subtle).frame(width: 52, alignment: .trailing)
                            Text(row.events.formatted()).foregroundStyle(COSPalette.subtle)
                                .frame(minWidth: 92, alignment: .trailing)
                            Text(row.costLabel).frame(minWidth: 110, alignment: .trailing)
                        }.font(COSType.body(12)).monospacedDigit().contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }.padding(.top, 10)
        }
        .font(COSType.body(13, weight: .medium)).tint(COSPalette.accent)
    }
}

/// Hover updates stay here; moving the pointer never recomputes the report table or imports files.
struct SessionUsageChart: View {
    private typealias P = SessionUsagePresentation
    static let height: CGFloat = 340
    /// Marks stack in this order, so the largest series always sits at the bottom.
    private var orderedSeries: [String] {
        var totals: [String: Double] = [:]
        for point in points { totals[point.series, default: 0] += value(point) }
        return P.seriesOrder(totals)
    }
    /// Hue-separated, in the order the largest models take them.
    static let rankedColors: [Color] = [
        COSPalette.gold, Color(red: 0.02, green: 0.59, blue: 0.62), Color(red: 0.86, green: 0.43, blue: 0.16),
        Color(red: 0.20, green: 0.49, blue: 0.78), Color(red: 0.53, green: 0.40, blue: 0.77), Color(red: 0.55, green: 0.42, blue: 0.20)
    ]
    let points: [SessionUsageView.Point]
    let rows: [SessionUsageBucket]
    let scale: SessionUsageTimeScale
    let measure: SessionUsageMeasure
    let excludeCacheReads: Bool
    let timeZone: TimeZone
    let lineChart: Bool
    let bounds: ClosedRange<String>?
    let seriesColors: [String: Color]
    let partialPeriods: Set<String>
    @Binding var inspectedPeriod: String?
    @State private var hoveredPeriod: String?
    @State private var hoverX: CGFloat = 0
    /// Built once per parent render, never per pointer move.
    private let calendar: Calendar
    private let keyByDay: [String: String]
    private let periodKeys: [String]
    private let periodKeySet: Set<String>
    private let axisTop: Double
    private let average: Double?

    init(points: [SessionUsageView.Point], rows: [SessionUsageBucket], scale: SessionUsageTimeScale, measure: SessionUsageMeasure,
         excludeCacheReads: Bool, timeZone: TimeZone, inspectedPeriod: Binding<String?>, initialHover: String? = nil, lineChart: Bool = false,
         bounds: ClosedRange<String>? = nil, initialHoverX: CGFloat = 0, seriesColors: [String: Color] = [:], partialPeriods: Set<String> = []) {
        self.points = points; self.rows = rows; self.scale = scale; self.measure = measure
        self.excludeCacheReads = excludeCacheReads; self.timeZone = timeZone; self._inspectedPeriod = inspectedPeriod
        self._hoveredPeriod = State(initialValue: initialHover)
        self._hoverX = State(initialValue: initialHoverX)
        self.lineChart = lineChart
        self.bounds = bounds
        self.seriesColors = seriesColors
        self.partialPeriods = partialPeriods
        calendar = SessionUsagePresentation.reportingCalendar(timeZone)
        keyByDay = SessionUsagePresentation.periodKeyMap(rows, scale: scale)
        periodKeySet = Set(keyByDay.values)
        periodKeys = periodKeySet.sorted()
        func plotted(_ point: SessionUsageView.Point) -> Double {
            switch measure {
            case .cost: return point.usd
            case .records: return Double(point.events)
            case .tokens: return Double(point.tokens) / 1e6
            }
        }
        // Lines read each point on its own; stacks read their total.
        var peak = 0.0
        if lineChart {
            peak = points.map(plotted).max() ?? 0
        } else {
            var totals: [Date: Double] = [:]
            for point in points { totals[point.date, default: 0] += plotted(point) }
            peak = totals.values.max() ?? 0
        }
        axisTop = SessionUsagePresentation.niceAxisTop(peak)
        var periodTotals: [String: Double] = [:]
        // A period with no price is not a $0 period.
        for point in points where !point.key.isEmpty && (measure != .cost || point.pricedEvents > 0) { periodTotals[point.key, default: 0] += plotted(point) }
        average = lineChart ? nil : SessionUsagePresentation.periodAverage(periodTotals, partial: partialPeriods)
    }

    init(points: [SessionUsageView.Point], rows: [SessionUsageBucket], monthly: Bool, costChart: Bool,
         excludeCacheReads: Bool, timeZone: TimeZone, inspectedPeriod: Binding<String?>, initialHover: String? = nil, lineChart: Bool = false,
         initialHoverX: CGFloat = 0) {
        self.init(points: points, rows: rows, scale: monthly ? .monthly : .daily, measure: costChart ? .cost : .tokens,
            excludeCacheReads: excludeCacheReads, timeZone: timeZone, inspectedPeriod: inspectedPeriod, initialHover: initialHover, lineChart: lineChart,
            initialHoverX: initialHoverX)
    }

    private func periodValues(_ key: String) -> [SessionUsageBucket] { rows.filter { keyByDay[$0.day] == key } }
    private func periodTitle(_ key: String) -> String { P.periodTitle(for: key, scale: scale, within: bounds) }

    static func seriesColor(_ name: String) -> Color {
        switch name {
        case "claude-opus-5-5": return Color(red: 0.86, green: 0.43, blue: 0.16)
        case "gpt-6-astra": return Color(red: 0.02, green: 0.59, blue: 0.62)
        case "gpt-6.1-sol": return Color(red: 0.53, green: 0.40, blue: 0.77)
        case "Anthropic", "Claude Code": return COSPalette.gold
        case "OpenAI", "Codex": return Color(red: 0.02, green: 0.59, blue: 0.62)
        case "Cursor": return Color.primary.opacity(0.72)
        case "Ollama", "Codex (Ollama)": return Color(red: 0.53, green: 0.40, blue: 0.77)
        case "Uncached input", "Input": return Color(red: 0.20, green: 0.49, blue: 0.78)
        case "Output": return Color(red: 0.86, green: 0.43, blue: 0.16)
        // Repeated context, so it recedes, and it no longer shares a colour with Claude Code.
        case "Cache read", "Read from cache": return Color(red: 0.61, green: 0.58, blue: 0.53)
        case "Cache write", "Written to cache": return Color(red: 0.53, green: 0.40, blue: 0.77)
        case "Other models": return .gray
        default:
            let colors: [Color] = [.blue, .green, .pink, .indigo, .brown]
            let index = name.utf8.reduce(0) { ($0 * 31 + Int($1)) % colors.count }
            return colors[index]
        }
    }

    private func color(_ name: String) -> Color { seriesColors[name] ?? Self.seriesColor(name) }

    private func value(_ point: SessionUsageView.Point) -> Double {
        switch measure {
        case .cost: return point.usd
        case .records: return Double(point.events)
        case .tokens: return Double(point.tokens) / 1e6
        }
    }

    private var yValueLabel: String {
        switch measure {
        case .cost: return "Estimated USD"
        case .records: return "Usage records"
        case .tokens: return "Million tokens"
        }
    }

    private func axisLabel(_ value: Double) -> String {
        guard value > 0 else { return "0" }
        switch measure {
        case .cost: return value.formatted(.currency(code: "USD").precision(.fractionLength(axisTop < 10 ? 2 : 0)))
        case .records: return value.formatted(.number.notation(.compactName))
        case .tokens:
            if value >= 1000 { return String(format: "%gB", (value / 100).rounded() / 10) }
            if value >= 1 { return String(format: "%gM", (value * 10).rounded() / 10) }
            return String(format: "%gK", (value * 10_000).rounded() / 10)
        }
    }

    private var calendarUnit: Calendar.Component {
        switch scale {
        case .daily: return .day
        case .weekly: return .weekOfYear
        case .monthly: return .month
        }
    }

    private func accessibleValue(_ point: SessionUsageView.Point) -> String {
        switch measure {
        case .cost:
            return point.usd.formatted(.currency(code: "USD")) + (point.pricedEvents < point.events ? " plus unknown cost" : " API value") + ", \(point.events) usage records"
        case .records:
            return "\(point.events) usage records, " + SessionUsagePricing.tokens(point.tokens) + " tokens"
        case .tokens:
            return SessionUsagePricing.tokens(point.tokens) + " tokens, \(point.events) usage records"
        }
    }

    private func dimmed(_ point: SessionUsageView.Point) -> Double {
        let partial = partialPeriods.contains(point.key) ? 0.42 : 1
        guard let inspectedPeriod, !point.key.isEmpty else { return partial }
        // The chosen bar stands out even when it is a partial one.
        return point.key == inspectedPeriod ? 1 : 0.32 * partial
    }

    private var axisDates: [Date] {
        P.axisKeys(periodKeys).compactMap { P.noon(of: P.periodStart($0), calendar: calendar) }
    }

    /// One line beside the pointer: the inspector holds the breakdown.
    private func hoverLine(_ key: String) -> String {
        let group = periodValues(key)
        let counts = group.reduce(SessionUsageCounts()) { $0 + $1.counts }
        let figure: String
        switch measure {
        case .cost: figure = P.costLabel(group)
        case .records: figure = group.reduce(0) { $0 + $1.events }.formatted() + " records"
        case .tokens: figure = SessionUsagePricing.tokens(P.tokenCount(counts, excludingCacheReads: excludeCacheReads)) + " tokens"
        }
        return periodTitle(key) + (partialPeriods.contains(key) ? " (part of a \(scale == .weekly ? "week" : "month"))" : "") + ": " + figure
    }
    /// Each series in the hovered bar, largest first, so a bar answers without a click.
    private func hoverRows(_ key: String) -> [(name: String, figure: String)] {
        let members = points.filter { $0.key == key }
        guard members.count > 1 else { return [] }
        return orderedSeries.compactMap { name in
            guard let point = members.first(where: { $0.series == name }) else { return nil }
            switch measure {
            case .cost: return (name, point.pricedEvents > 0 ? P.dollars(point.usd) : "No price")
            case .records: return (name, point.events.formatted())
            case .tokens: return (name, P.shortTokens(point.tokens))
            }
        }
    }

    var body: some View {
        Chart {
            ForEach(points.filter { measure != .cost || $0.pricedEvents > 0 }) { point in
                if lineChart {
                    LineMark(x: .value("Date", point.date, unit: calendarUnit),
                        y: .value(yValueLabel, value(point)))
                        .foregroundStyle(by: .value("Series", point.series))
                        .symbol(.circle)
                        .accessibilityLabel("\(P.dayKey(for: point.date, calendar: calendar)), \(point.series)")
                        .accessibilityValue(accessibleValue(point))
                } else {
                    BarMark(x: .value("Date", point.date, unit: calendarUnit),
                        y: .value(yValueLabel, value(point)))
                        .foregroundStyle(by: .value("Series", point.series))
                        .opacity(dimmed(point))
                        .accessibilityLabel("\(P.dayKey(for: point.date, calendar: calendar)), \(point.series)")
                        .accessibilityValue(accessibleValue(point))
                }
            }
            if let average {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(COSPalette.subtle.opacity(0.75)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("Average \(axisLabel(average))").font(COSType.body(11)).monospacedDigit().foregroundStyle(COSPalette.subtle)
                            .padding(.horizontal, 4).background(COSPalette.panel.opacity(0.88), in: RoundedRectangle(cornerRadius: 3))
                    }
                    .accessibilityLabel("Average")
                    .accessibilityValue(axisLabel(average))
            }
            if lineChart || hoveredPeriod != nil, let key = hoveredPeriod ?? inspectedPeriod, let date = P.noon(of: P.periodStart(key), calendar: calendar) {
                RuleMark(x: .value("Inspect", date, unit: calendarUnit))
                    .foregroundStyle(COSPalette.subtle.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: periodKeys) { _, _ in hoveredPeriod = nil }
        .environment(\.calendar, calendar)
        .environment(\.timeZone, timeZone)
        .chartForegroundStyleScale(domain: orderedSeries, range: orderedSeries.map { color($0) })
        .chartLegend(.hidden)
        .chartYScale(domain: 0...axisTop)
        .chartXAxis {
            AxisMarks(values: axisDates) { mark in
                AxisTick().foregroundStyle(COSPalette.line)
                // The first label starts at the plot's edge, so it never centres over it and clips.
                AxisValueLabel(anchor: scale == .daily && mark.index > 0 ? .top : .topLeading) {
                    if let date = mark.as(Date.self) {
                        Text(P.axisLabel(for: P.periodKey(for: P.dayKey(for: date, calendar: calendar), scale: scale)))
                            .font(COSType.body(11)).monospacedDigit().foregroundStyle(COSPalette.subtle)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, axisTop / 4, axisTop / 2, axisTop * 3 / 4, axisTop]) { mark in
                AxisGridLine().foregroundStyle(COSPalette.line)
                AxisValueLabel {
                    if let number = mark.as(Double.self) { Text(axisLabel(number)).font(COSType.body(11)).monospacedDigit().foregroundStyle(COSPalette.subtle) }
                }
            }
        }
        .frame(minHeight: Self.height, maxHeight: .infinity)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor = proxy.plotFrame {
                    let plot = geometry[anchor]
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard plot.contains(location), let date: Date = proxy.value(atX: location.x - plot.minX) else { hoveredPeriod = nil; return }
                                    let day = P.dayKey(for: date, calendar: calendar)
                                    let key = keyByDay[day] ?? P.periodKey(for: day, scale: scale)
                                    hoveredPeriod = periodKeySet.contains(key) ? key : nil
                                    hoverX = location.x
                                case .ended: hoveredPeriod = nil
                                }
                            }
                            // A second click on the same bar goes back to the whole period.
                            .onTapGesture { if let key = hoveredPeriod { inspectedPeriod = inspectedPeriod == key ? nil : key } }
                            .accessibilityHidden(true)
                        if let key = hoveredPeriod {
                            let cardWidth = min(CGFloat(320), geometry.size.width - 16)
                            let x = P.tooltipX(pointer: Double(hoverX), cardWidth: Double(cardWidth), containerWidth: Double(geometry.size.width))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(hoverLine(key)).font(COSType.body(12, weight: .medium))
                                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                ForEach(hoverRows(key), id: \.name) { row in
                                    HStack(spacing: 6) {
                                        RoundedRectangle(cornerRadius: 2).fill(color(row.name)).frame(width: 8, height: 8)
                                        Text(row.name).lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(row.figure)
                                    }
                                    .font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
                                }
                            }
                                .monospacedDigit()
                                .frame(width: cardWidth - 20, alignment: .leading)
                                .padding(10).background(COSPalette.card, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(COSPalette.border))
                                .offset(x: CGFloat(x), y: 6)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
    }
}

/// The whole period until a bar is chosen, then that bar. Replaces the hover card, the period dropdown, the provider
/// table and the token mix section, and stays usable from the keyboard through its step buttons.
struct SessionUsageInspector: View {
    private typealias P = SessionUsagePresentation
    let title: String
    let rows: [SessionUsageBucket]
    let excludingCacheReads: Bool
    let measure: SessionUsageMeasure
    let isPeriod: Bool
    let canGoEarlier: Bool
    let canGoLater: Bool
    let comparison: SessionUsagePresentation.PeriodComparison?
    var modelColors: [String: Color] = [:]
    let onStep: (Int) -> Void
    let onClear: () -> Void
    let onInspectDay: (String) -> Void
    private let modelLimit = 5

    private var counts: SessionUsageCounts { rows.reduce(SessionUsageCounts()) { $0 + $1.counts } }
    private var measuredTotal: Int64 { P.tokenCount(counts, excludingCacheReads: excludingCacheReads) }
    private func measured(_ c: SessionUsageCounts) -> Int64 { P.tokenCount(c, excludingCacheReads: excludingCacheReads) }
    private var headline: String {
        if measure == .cost { return P.costCell(rows) }
        return P.spokenTokens(measuredTotal) + (excludingCacheReads ? " new tokens" : " tokens")
    }
    private var subline: String {
        if measure == .cost { return P.spokenTokens(counts.total) + " tokens" }
        let priced = rows.reduce(0) { $0 + $1.pricedEvents }, events = rows.reduce(0) { $0 + $1.events }
        guard priced > 0 else { return "No verified price" }
        return P.dollars(rows.reduce(0) { $0 + $1.estimatedUSD }) + " at API rates" + (priced < events ? ", plus unpriced records" : "")
    }
    private var newTokenNote: String {
        let new = P.tokenCount(counts, excludingCacheReads: true)
        return "\(P.spokenTokens(new)) were new. \(P.share(counts.cacheRead, of: counts.total)) was context read again from cache."
    }
    /// A trailing + marks a figure that leaves out unpriced records.
    private func cost(_ summary: P.Summary) -> String {
        summary.pricedEvents == 0 ? "No price" : P.dollars(summary.estimatedUSD) + (summary.pricedEvents < summary.events ? "+" : "")
    }
    private func dollars(_ value: Double) -> String { P.dollars(value) }
    /// The figure beside the busiest day, in the chart's measure.
    private func peakFigure(_ peak: P.Summary) -> String {
        switch measure {
        case .cost: return P.dollars(peak.estimatedUSD)
        case .records: return peak.events.formatted() + " records"
        case .tokens: return P.shortTokens(P.tokenCount(peak.counts, excludingCacheReads: excludingCacheReads))
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(COSType.body(12, weight: .semibold)).padding(.top, 16).padding(.bottom, 3)
    }
    private func row(_ color: Color?, _ name: String, _ first: String, _ second: String, help: String? = nil) -> some View {
        HStack(spacing: 6) {
            if let color { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9) }
            Text(name).lineLimit(1).truncationMode(.middle).help(help ?? name)
            Spacer(minLength: 6)
            Text(first)
            Text(second).foregroundStyle(COSPalette.subtle).frame(minWidth: 52, alignment: .trailing)
        }
        .font(COSType.body(12)).monospacedDigit().padding(.vertical, 3)
    }
    /// Where the tokens went against where the value went. Reading the two together is the point: most tokens are
    /// cheap repeats and a small share of writes and output carries much of the value.
    private func mixStrip(_ title: String, _ parts: [(id: String, amount: Double)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
            GeometryReader { geometry in
                let spacing = 2.0
                let widths = P.segmentWidths(parts.map(\.amount), total: Double(geometry.size.width), spacing: spacing, minimum: 3)
                HStack(spacing: spacing) {
                    ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                        if widths[index] > 0 {
                            RoundedRectangle(cornerRadius: 2).fill(SessionUsageChart.seriesColor(part.id)).frame(width: widths[index])
                        }
                    }
                }
            }.frame(height: 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
    private func stepButton(_ symbol: String, _ label: String, enabled: Bool, delta: Int) -> some View {
        Button { onStep(delta) } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                .frame(width: 24, height: 24).contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(COSPalette.border))
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .help(label).accessibilityLabel(label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(title).font(COSType.body(12)).foregroundStyle(COSPalette.subtle).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                stepButton("chevron.left", "Earlier period", enabled: canGoEarlier, delta: -1)
                stepButton("chevron.right", "Later period", enabled: canGoLater, delta: 1)
            }
            // The figures above the chart already give the whole period's totals.
            if isPeriod {
                Text(headline).font(COSType.display(28)).monospacedDigit().padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subline).font(COSType.body(13)).foregroundStyle(COSPalette.subtle).monospacedDigit().padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let mix = P.tokenMix(counts, excludingCacheReads: false, rows: rows).sorted { $0.count > $1.count }
            VStack(alignment: .leading, spacing: 9) {
                mixStrip("Share of tokens", mix.map { ($0.id, Double($0.count)) })
                if P.costSplit(rows).splitUSD > 0 { mixStrip("Share of API value", mix.map { ($0.id, $0.estimatedUSD) }) }
            }.padding(.top, 14)

            let tools = P.summarize(rows, by: \.provider, excludingCacheReads: excludingCacheReads)
            if tools.count > 1 {
                heading("Tools")
                ForEach(tools) { tool in
                    row(SessionUsageChart.seriesColor(P.toolName(tool.id)), P.toolName(tool.id), P.shortTokens(measured(tool.counts)), cost(tool))
                }
            }

            let models = P.aggregate(rows, excludingCacheReads: excludingCacheReads)
            // The table below names every model for the whole period, so only a chosen bar needs its own list.
            if isPeriod {
                heading("Models")
                ForEach(Array(models.prefix(modelLimit))) { model in
                    row(modelColors[P.modelName(model.model)], P.modelName(model.model),
                        P.shortTokens(measured(model.counts)), model.pricedEvents == 0 ? "No price" : dollars(model.estimatedUSD) + (model.pricedEvents < model.events ? "+" : ""), help: model.model)
                }
                if models.count > modelLimit {
                    Text("\(models.count - modelLimit) more not listed here").font(COSType.body(11)).foregroundStyle(COSPalette.subtle).padding(.top, 3)
                }
            }

            let split = P.costSplit(rows)
            heading("Token types")
            ForEach(P.tokenMix(counts, excludingCacheReads: excludingCacheReads, rows: rows).sorted { $0.count > $1.count }) { category in
                row(SessionUsageChart.seriesColor(category.id), P.categoryTitle(category.id),
                    category.excludedFromTokens ? "Not counted" : P.shortTokens(category.count),
                    split.splitUSD > 0 ? dollars(category.estimatedUSD) : "")
            }
            if !split.isComplete && split.splitUSD > 0 {
                Text("Values by type cover \(dollars(split.splitUSD)) of \(dollars(split.pricedUSD)). \(rows.contains { $0.provider == "Cursor" } ? "Cursor and partly priced records are" : "Partly priced records are") not split.")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.subtle).padding(.top, 3).fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.top, 14).padding(.bottom, 10)
            if isPeriod {
                Text(newTokenNote).font(COSType.body(12)).foregroundStyle(COSPalette.subtle).monospacedDigit().fixedSize(horizontal: false, vertical: true)
            }
            if let comparison {
                if let peak = comparison.peakDay {
                    Button { onInspectDay(peak.id) } label: {
                        Text("Busiest day: \(P.periodTitle(for: peak.id, scale: .daily)), \(peakFigure(peak))").underline()
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    .buttonStyle(.plain).font(COSType.body(12)).foregroundStyle(COSPalette.accent)
                    .help("Show this day")
                }
                // A window that starts before the logs do would compare against almost nothing, so it says so instead.
                if comparison.priorRange != nil, !comparison.hasPriorBaseline || comparison.partialPriorHistory {
                    Text(comparison.partialPriorHistory ? "History does not reach back a full period, so there is no comparison." : "No usage in the period before.")
                        .font(COSType.body(12)).foregroundStyle(COSPalette.subtle).padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if comparison.hasPriorBaseline, !comparison.partialPriorHistory, let prior = comparison.priorRange {
                    Text("Compared with \(P.dateRangeTitle(prior)): tokens \(comparison.tokenDeltaLabel), API value \(comparison.costDeltaLabel)\(comparison.costDeltaPartial ? " (priced records only)" : "").")
                        .font(COSType.body(12)).foregroundStyle(COSPalette.subtle).monospacedDigit().padding(.top, 8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if isPeriod {
                Button("Show the whole period", action: onClear)
                    .buttonStyle(.plain).font(COSType.body(12)).foregroundStyle(COSPalette.accent).padding(.top, 10)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(COSPalette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.line))
    }
}

/// A calendar and its margin read as one figure: each weekday row runs left to right through the weeks and ends in
/// that weekday's average. Wide enough, a square carries its own number and reads like a ledger; narrow, it is a heat
/// map and the number moves to the tooltip. Days with no logs stay hollow, because no record is not zero.
struct SessionUsageCalendar: View {
    private typealias P = SessionUsagePresentation
    let weeks: [SessionUsagePresentation.CalendarWeek]
    let averages: [Double]
    let inspectedDay: String?
    let counted: (SessionUsagePresentation.Summary) -> Bool
    let value: (SessionUsagePresentation.Summary) -> Double
    let figure: (Double) -> String
    let cellFigure: (SessionUsagePresentation.Summary) -> String
    let emptyWords: String
    let detail: (SessionUsagePresentation.Summary) -> String
    let onPick: (String) -> Void
    @State private var carriesNumbers = false
    @Environment(\.colorScheme) private var colorScheme
    private static let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private static let spacing: CGFloat = 3
    private static let marginWidth: CGFloat = 150

    /// Too many squares to tab through or read aloud. The Daily breakdown list reaches every day instead.
    private var long: Bool { weeks.count > 26 }
    private var rowHeight: CGFloat { carriesNumbers ? 26 : 16 }
    private var peak: Double {
        weeks.flatMap(\.days).compactMap { $0.summary }.filter(counted).map(value).max() ?? 0
    }

    var body: some View {
        let top = peak
        let topAverage = averages.max() ?? 0
        VStack(alignment: .leading, spacing: Self.spacing) {
            HStack(alignment: .bottom, spacing: 8) {
                Color.clear.frame(width: 26, height: 14)
                HStack(spacing: Self.spacing) {
                    ForEach(weeks) { week in
                        Color.clear.frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
                            .overlay(alignment: .leading) {
                                if let label = week.monthLabel { Text(label).fixedSize() }
                            }
                    }
                }
                .onGeometryChange(for: Bool.self) { $0.size.width / CGFloat(max(1, weeks.count)) - Self.spacing >= 44 } action: { carriesNumbers = $0 }
                Text("Daily average").frame(width: Self.marginWidth, alignment: .leading)
            }
            .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
            ForEach(0..<7, id: \.self) { weekday in
                HStack(spacing: 8) {
                    Text(Self.names[weekday]).font(COSType.body(11)).foregroundStyle(COSPalette.subtle).frame(width: 26, alignment: .leading)
                    HStack(spacing: Self.spacing) {
                        ForEach(weeks) { week in cell(week.days[weekday], top: top) }
                    }
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(COSPalette.gold)
                            .frame(width: topAverage > 0 ? max(averages[weekday] > 0 ? 2 : 0, 88 * averages[weekday] / topAverage) : 0, height: min(rowHeight, 14))
                            .frame(width: 88, alignment: .leading)
                        Text(averages[weekday] > 0 ? figure(averages[weekday]) : "").font(COSType.body(11)).monospacedDigit().foregroundStyle(COSPalette.subtle)
                            .lineLimit(1).fixedSize()
                    }
                    .frame(width: Self.marginWidth, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Self.names[weekday]) average")
                    .accessibilityValue(averages[weekday] > 0 ? figure(averages[weekday]) : "No records")
                }
                .frame(height: rowHeight)
            }
        }
        .accessibilityElement(children: long ? .ignore : .contain)
        .accessibilityLabel(long ? "Calendar of \(weeks.count) weeks. Daily breakdown lists each day." : "")
    }

    @ViewBuilder private func cell(_ day: SessionUsagePresentation.CalendarDay, top: Double) -> some View {
        if !day.inRange {
            Color.clear.frame(maxWidth: .infinity)
        } else if let summary = day.summary, counted(summary) {
            // Square root, so one huge day does not wash out every ordinary one.
            let level = top > 0 ? (value(summary) / top).squareRoot() : 0
            Button { onPick(day.id) } label: {
                RoundedRectangle(cornerRadius: 3).fill(COSPalette.gold.opacity(0.12 + 0.82 * level))
                    .overlay {
                        if carriesNumbers {
                            Text(cellFigure(summary)).font(COSType.body(11)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
                                .foregroundStyle(colorScheme == .light || level > 0.65 ? COSPalette.ink : Color.primary)
                        }
                    }
                    .overlay {
                        if inspectedDay == day.id { RoundedRectangle(cornerRadius: 3).stroke(Color.primary, lineWidth: 1.5) }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(!long)
            .frame(maxWidth: .infinity)
            .help(detail(summary))
            .accessibilityLabel(detail(summary))
            .accessibilityAddTraits(inspectedDay == day.id ? .isSelected : [])
        } else {
            Group {
                if long { RoundedRectangle(cornerRadius: 2).fill(COSPalette.line.opacity(0.45)) }
                else { RoundedRectangle(cornerRadius: 3).strokeBorder(COSPalette.line) }
            }
                .frame(maxWidth: .infinity)
                .help("\(P.periodTitle(for: day.id, scale: .daily)): \(day.summary == nil ? emptyWords : "no price")")
                .accessibilityLabel("\(P.periodTitle(for: day.id, scale: .daily)): \(day.summary == nil ? emptyWords : "no price")")
        }
    }
}
