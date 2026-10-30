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
    private let helper = HelperClient()
    private var loop: Task<Void, Never>?
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                if self?.enabled == true { await self?.refresh() }
                else if self?.report == nil { await self?.refresh(importNew: false) }
                let pending = self?.enabled == true && (self?.report?.pendingFiles ?? 0) > 0 && self?.error == nil
                try? await Task.sleep(for: .seconds(pending ? 15 : 300))
            }
        }
    }
    func refresh(importNew: Bool = true) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await helper.run(importNew ? ["session-usage"] : ["session-usage", "--read-only"], timeout: 45)
            guard result.ok else { throw HelperClientError.commandFailed(result.message) }
            report = try JSONDecoder().decode(SessionUsageReport.self, from: JSONEncoder().encode(result.details))
            error = nil
        } catch { self.error = "Usage could not refresh: \(error.localizedDescription)" }
    }
}

struct SessionUsageView: View {
    private typealias P = SessionUsagePresentation
    private static let inspectorID = "usage-period-inspector"
    @ObservedObject var store: SessionUsageStore
    @State private var month = "Last 30 days"
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -29, to: Date())!
    @State private var customEnd = Date()
    @State private var timeScale: SessionUsageTimeScale = .daily
    /// The scale in use before All history switched to Monthly, restored on leaving it.
    @State private var scaleBeforeHistory: SessionUsageTimeScale?
    @State private var measure: SessionUsageMeasure = .tokens
    @State private var seriesMode: SessionUsageSeries = .providers
    @State private var seriesNote: String?
    @State private var lineChart = true
    @State private var slice = SessionUsageSlice()
    @State private var excludeCacheReads = false
    @State private var inspection: SessionUsageInspection?
    @State private var dayBreakdownExpanded = false
    @State private var modelSort: SessionUsageModelSort = .tokens
    @State private var modelSortAscending = false
    @State private var daySort: SessionUsageDaySort = .date
    @State private var daySortAscending = false
    @State private var exportStatus: String?
    @State private var scrollRequest = 0

    init(store: SessionUsageStore, initialPeriod: String? = nil, initialInspection: String? = nil,
         initialDates: (Date, Date)? = nil, initialCostChart: Bool = false,
         initialExcludeCacheReads: Bool = false, initialDayBreakdownExpanded: Bool = false,
         initialTimeScale: SessionUsageTimeScale? = nil, initialMeasure: SessionUsageMeasure? = nil,
         initialSeries: SessionUsageSeries = .providers, initialLineChart: Bool = true,
         initialProvider: String = SessionUsagePresentation.allProviders, initialModel: String = SessionUsagePresentation.allModels,
         initialModelSort: SessionUsageModelSort = .tokens, initialDaySort: SessionUsageDaySort = .date) {
        self.store = store
        let period = initialPeriod ?? "Last 30 days"
        let history = period == P.allHistory
        let scale = initialTimeScale ?? (history ? .monthly : .daily)
        let chartMeasure = initialMeasure ?? (initialCostChart ? .cost : .tokens)
        _month = State(initialValue: period)
        _timeScale = State(initialValue: scale)
        _scaleBeforeHistory = State(initialValue: history && initialTimeScale == nil ? .daily : nil)
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
        Binding(get: { inspectedPeriod }, set: { key in inspection = key.map { SessionUsageInspection(key: $0, scale: timeScale) } })
    }
    private func measured(_ counts: SessionUsageCounts) -> Int64 { P.tokenCount(counts, excludingCacheReads: excludeCacheReads) }
    private func periodValues(_ key: String) -> [SessionUsageBucket] {
        selected.filter { P.periodKey(for: $0.day, scale: timeScale) == key }
    }
    private func periodTitle(_ key: String) -> String { P.periodTitle(for: key, scale: timeScale, within: selectionBounds) }
    private var counts: SessionUsageCounts { selected.reduce(SessionUsageCounts()) { $0 + $1.counts } }
    private var unpriced: Int { selected.reduce(0) { $0 + $1.events - $1.pricedEvents } }
    private var priced: Int { selected.reduce(0) { $0 + $1.pricedEvents } }
    private var cost: Double { selected.reduce(0) { $0 + $1.estimatedUSD } }
    private var dateFormatter: DateFormatter { P.dayFormatter(timeZone: reportingZone) }
    private var ranking: [SessionUsageBucket] {
        P.sortModels(selected, by: modelSort, ascending: modelSortAscending, excludingCacheReads: excludeCacheReads)
    }
    private var sortedDays: [P.Summary] {
        P.sortDays(selected, by: daySort, ascending: daySortAscending, excludingCacheReads: excludeCacheReads)
    }
    private var comparison: P.PeriodComparison {
        P.comparePeriod(allRows: buckets, selectedRows: selected, period: month, provider: provider, model: model, measure: measure,
            excludingCacheReads: excludeCacheReads, now: Date(), timeZone: reportingZone, customStart: customStart, customEnd: customEnd)
    }
    private var hasActiveSlice: Bool {
        provider != P.allProviders || model != P.allModels || excludeCacheReads || inspectedPeriod != nil
    }
    /// Everything an export describes. Any change makes an earlier "Copied" line stale.
    private var exportScope: String {
        [month, dateFormatter.string(from: customStart), dateFormatter.string(from: customEnd), provider, model,
         String(excludeCacheReads), timeScale.rawValue, inspectedPeriod ?? ""].joined(separator: "|")
    }

    struct Point: Identifiable {
        var date: Date; var series: String; var tokens: Int64; var usd: Double
        var pricedEvents: Int = 1
        var events: Int = 1
        var id: String { String(date.timeIntervalSince1970) + series }
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
                    result.append(Point(date: date, series: category.id, tokens: category.count, usd: category.estimatedUSD, pricedEvents: pricedEvents, events: events))
                }
            }
        } else {
            var modelTotals: [String: Int64] = [:]
            for row in rows { modelTotals[row.model, default: 0] += measured(row.counts) }
            let top = Set(modelTotals.keys.sorted { a, b in
                let left = modelTotals[a, default: 0], right = modelTotals[b, default: 0]
                return left == right ? a < b : left > right
            }.prefix(6))
            for (key, group) in byPeriod {
                guard let date = P.noon(of: P.periodStart(key), calendar: calendar) else { continue }
                let bySeries = Dictionary(grouping: group) { row in
                    seriesMode == .providers ? row.provider : top.contains(row.model) ? row.model : "Other models"
                }
                for (series, members) in bySeries {
                    result.append(Point(date: date, series: series, tokens: members.reduce(Int64(0)) { $0 + measured($1.counts) },
                        usd: members.reduce(0.0) { $0 + $1.estimatedUSD },
                        pricedEvents: members.reduce(0) { $0 + $1.pricedEvents }, events: members.reduce(0) { $0 + $1.events }))
                }
            }
        }
        return result.sorted { a, b in a.date == b.date ? a.series < b.series : a.date < b.date }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    filterRow
                    if store.report == nil || buckets.isEmpty {
                        emptyHistory
                    } else {
                        if month == P.customDates { customDates }
                        if hasActiveSlice { activeSliceBar }
                        if let exportStatus {
                            Text(exportStatus).font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                        }
                        Text("Calendar dates in \(reportingZone.identifier). Includes today for Last 7/30/90 days. Daily records cannot resolve a rolling 24-hour window.")
                            .font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
                        if let earliest = buckets.map(\.day).min(), let latest = buckets.map(\.day).max() {
                            Text("Recorded history: \(earliest) – \(latest). All totals, charts and breakdowns follow the selected period and filters.")
                                .font(COSType.body(12)).foregroundStyle(.secondary)
                        }
                        statusLines
                        if selected.isEmpty {
                            Text("No recorded usage for this selection. A missing provider is not zero usage.")
                                .frame(maxWidth: .infinity, minHeight: 160).foregroundStyle(.secondary)
                        } else {
                            HStack(alignment: .top, spacing: 28) {
                                metric("All recorded tokens", SessionUsagePricing.tokens(counts.total))
                                metric("Usage records", selected.reduce(0) { $0 + $1.events }.formatted())
                                metric("Recorded days", Set(selected.map(\.day)).count.formatted())
                                metric("Estimated API value", priced == 0 ? "Unavailable" : cost.formatted(.currency(code: "USD")) + (unpriced > 0 ? " + unknown" : ""))
                            }
                            comparisonStrip
                            Label(P.allowanceNote, systemImage: "info.circle")
                                .font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Standard API-equivalent estimate, not your subscription bill. Rates checked October 25, 2026 and applied to all dates. Discounts, speed tiers, tools and taxes are excluded.")
                                .font(COSType.body(12)).foregroundStyle(.secondary)
                            limitsNote
                            chartSection.zIndex(1)
                            providerBreakdown
                            tokenMix
                            modelsSection
                            dayBreakdown
                        }
                    }
                    footer
                }.padding(22)
            }
            .onChange(of: scrollRequest) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(Self.inspectorID, anchor: .top) }
            }
        }
        .onChange(of: slice) { _, _ in inspection = nil }
        .onChange(of: month) { _, value in
            let next = P.timeScale(afterChangingTo: value, current: timeScale, remembered: scaleBeforeHistory)
            scaleBeforeHistory = next.remembered
            timeScale = next.scale
            inspection = nil
        }
        // A click that sets the scale and the inspection together keeps it; a day carries into its week or month.
        .onChange(of: timeScale) { _, scale in inspection = P.reconcile(inspection, to: scale, keys: periodKeys) }
        .onChange(of: periodKeys) { _, keys in
            if let key = inspectedPeriod, !keys.contains(key) { inspection = nil }
        }
        .onChange(of: measure) { _, value in
            let series = P.series(seriesMode, for: value)
            seriesNote = series == seriesMode ? nil : "Records count whole observations, not token categories, so the chart shows providers."
            seriesMode = series
        }
        .onChange(of: customStart) { _, _ in inspection = nil }
        .onChange(of: customEnd) { _, _ in inspection = nil }
        .onChange(of: exportScope) { _, _ in exportStatus = nil }
        .task { if store.report == nil { await store.refresh(importNew: store.enabled) } }
    }

    private func inspectDay(_ day: String) {
        inspection = SessionUsageInspection(key: day, scale: .daily)
        timeScale = .daily
        scrollRequest += 1
    }

    private var filterRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 12) {
                filters
                Spacer(minLength: 12)
                actions
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .bottom, spacing: 12) { filters }
                actions
            }
        }
    }

    @ViewBuilder private var filters: some View {
        filter("Period", selection: $month, values: P.periods + months).frame(width: 150)
        filter("Provider", selection: Binding(get: { slice.provider }, set: { value in
            slice.choose(provider: value)
            if slice.model != P.allModels && !models.contains(slice.model) { slice.choose(model: P.allModels) }
        }), values: [P.allProviders] + providers).frame(minWidth: 150, maxWidth: 190)
        filter("Model", selection: Binding(get: { slice.model }, set: { slice.choose(model: $0) }),
               values: [P.allModels] + models).frame(minWidth: 180, maxWidth: 290)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { copySlice(json: false) } label: { Label("Copy CSV", systemImage: "doc.on.doc") }
                .disabled(selected.isEmpty)
                .help("Copy the active slice as CSV: the selected period and filters, narrowed to the inspected period when one is open.")
            Button { copySlice(json: true) } label: { Label("Copy JSON", systemImage: "curlybraces") }
                .disabled(selected.isEmpty)
                .help("Copy the active slice as JSON, with its period, filters, time scale and inspected period.")
            Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(store.loading)
        }
        .font(COSType.body(12))
        .fixedSize()
    }

    @ViewBuilder private var statusLines: some View {
        if store.loading { ProgressView("Updating usage history…").controlSize(.small) }
        if let error = store.error { Text(error).foregroundStyle(.red) }
        if let report = store.report, report.pendingFiles > 0 {
            Text("Backfilling history: \(report.pendingFiles) files remaining. Totals are partial and update as the import continues.").foregroundStyle(.secondary)
        }
    }

    /// First load, or no history at all: one state instead of a chart, zero tiles and empty tables.
    private var emptyHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.report == nil && store.loading {
                ProgressView("Reading local usage…").controlSize(.small)
            } else if let error = store.error {
                Text(error).foregroundStyle(.red)
            } else if store.report == nil {
                Text("Usage has not been read yet. Refresh reads local Claude Code and Codex logs on this Mac.").foregroundStyle(.secondary)
            } else {
                Text("No local usage recorded yet. Claude Code and Codex sessions on this Mac appear here once their logs are read. A missing provider is not zero usage.")
                    .foregroundStyle(.secondary)
            }
            if let report = store.report, report.pendingFiles > 0 {
                Text("Backfilling history: \(report.pendingFiles) files remaining. Totals are partial and update as the import continues.").foregroundStyle(.secondary)
            }
        }
        .font(COSType.body(13))
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
        .padding(16)
        .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()
            Toggle("Track session usage on this Mac", isOn: $store.enabled).toggleStyle(COSCheckStyle())
            Text("While COS Control is running, it refreshes local history every five minutes. Pausing keeps existing history. Manual Refresh imports available records. Only counts, dates, model names and local file checkpoints are stored; nothing is uploaded.").font(COSType.body(12)).foregroundStyle(.secondary)
            if let report = store.report {
                Text("\(report.filesIndexed) files indexed · Time zone: \(report.timeZone) · Updated \(report.updatedAt)").font(COSType.mono(10)).foregroundStyle(.secondary)
                ForEach(report.coverage, id: \.self) { Text($0).font(COSType.body(12)).foregroundStyle(.secondary) }
                if report.unreadableFiles + report.malformedRows + report.missingBaselineEvents > 0 {
                    Text("Coverage gaps: \(report.unreadableFiles) unreadable files / oversized rows, \(report.malformedRows) malformed rows, \(report.missingBaselineEvents) missing usage baselines. Totals reflect available evidence.").font(COSType.body(12)).foregroundStyle(.orange)
                }
                if unpriced > 0 { Text("\(unpriced) usage records have no verified price. Their tokens are included; their cost is unknown.").font(COSType.body(12)).foregroundStyle(.secondary) }
            }
            HStack { Link("Anthropic pricing", destination: URL(string: SessionUsagePricing.sources[0])!); Link("OpenAI pricing", destination: URL(string: SessionUsagePricing.sources[1])!) }.font(COSType.body(12))
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
        let scope = [month, provider, model] + (excludeCacheReads ? ["cache reads excluded"] : []) + (active.map { [periodTitle($0.key)] } ?? [])
        exportStatus = "Copied \(rows.count) daily provider/model rows as \(json ? "JSON" : "CSV"): \(scope.joined(separator: " · "))."
    }

    private func sliceChip(_ title: String, systemImage: String, help: String, clear: @escaping () -> Void) -> some View {
        Button(action: clear) { Label(title + " ×", systemImage: systemImage) }
            .buttonStyle(.plain).font(COSType.body(12, weight: .medium)).help(help)
    }

    private var activeSliceBar: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Active slice:").font(COSType.body(12, weight: .semibold)).foregroundStyle(COSPalette.subtle)
            ChipFlowLayout(spacing: 12) {
                if provider != P.allProviders {
                    sliceChip("Provider: \(provider)", systemImage: "line.3.horizontal.decrease.circle", help: "Clear the provider and model filters") { slice.toggleProvider(provider) }
                }
                if model != P.allModels {
                    sliceChip("Model: \(model)", systemImage: "cpu", help: "Clear the model filter") { slice.toggleModel(provider: provider, model: model) }
                }
                if excludeCacheReads {
                    sliceChip("Cache reads excluded", systemImage: "eye.slash", help: "Include cache reads again") { excludeCacheReads = false }
                }
                if let key = inspectedPeriod {
                    sliceChip("Inspecting \(periodTitle(key))", systemImage: "calendar", help: "Close the period breakdown") { inspection = nil }
                }
                Button("Reset slice") {
                    slice.reset()
                    excludeCacheReads = false
                    inspection = nil
                }.font(COSType.body(12))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 7))
    }

    private var measureName: String {
        switch measure {
        case .tokens: return "tokens"
        case .cost: return "API value"
        case .records: return "records"
        }
    }

    private func peakValue(_ peak: P.Summary) -> String {
        switch measure {
        case .tokens: return SessionUsagePricing.tokens(measured(peak.counts)) + " tokens"
        case .records: return peak.events.formatted() + " records"
        case .cost: return peak.costLabel
        }
    }

    private var comparisonStrip: some View {
        let cmp = comparison
        let avgCostText = priced == 0 ? "Unavailable" : cmp.dailyAvgUSD.formatted(.currency(code: "USD")) + (unpriced > 0 ? " + unknown" : "")
        return VStack(alignment: .leading, spacing: 6) {
            ChipFlowLayout(spacing: 6) {
                Text("Avg / recorded day:").font(COSType.body(12, weight: .semibold)).foregroundStyle(COSPalette.subtle)
                Text("\(SessionUsagePricing.tokens(cmp.dailyAvgTokens)) tokens · \(cmp.dailyAvgRecords.formatted()) records · \(avgCostText)")
                    .font(COSType.body(12)).monospacedDigit()
            }
            ChipFlowLayout(spacing: 6) {
                Text("Peak day by \(measureName):").font(COSType.body(12, weight: .semibold)).foregroundStyle(COSPalette.subtle)
                if let peak = cmp.peakDay {
                    Button { inspectDay(peak.id) } label: {
                        Text("\(P.periodTitle(for: peak.id, scale: .daily)) (\(peakValue(peak)))")
                            .font(COSType.body(12, weight: .medium)).monospacedDigit().underline()
                    }
                    .buttonStyle(.plain)
                    .help("Inspect \(peak.id) in the period breakdown.")
                } else {
                    Text("Unavailable: no priced records in this selection.").font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
                }
            }
            if let current = cmp.currentRange, let prior = cmp.priorRange {
                Text("This window \(P.dateRangeTitle(current))\(cmp.includesToday ? ", including today so far," : "") vs. prior window \(P.dateRangeTitle(prior)):")
                    .font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                if cmp.hasPriorBaseline {
                    ChipFlowLayout(spacing: 14) {
                        Text("Tokens \(cmp.tokenDeltaLabel) (prior \(SessionUsagePricing.tokens(cmp.priorTokens)))").monospacedDigit()
                        Text("Records \(cmp.recordsDeltaLabel) (prior \(cmp.priorRecords.formatted()))").monospacedDigit()
                        Text("API value \(cmp.costDeltaLabel) (prior \(cmp.priorPriced ? cmp.priorUSD.formatted(.currency(code: "USD")) : "Unavailable")\(cmp.costDeltaPartial ? ", priced records only" : ""))").monospacedDigit()
                    }.font(COSType.body(12))
                    if cmp.partialPriorHistory {
                        Text("The prior window starts before the earliest local log, so its totals may be partial.")
                            .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                    }
                } else {
                    Text("No recorded local usage in the prior window.").font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    private var chartTitle: String {
        switch timeScale {
        case .daily: return "Daily usage"
        case .weekly: return "Weekly usage"
        case .monthly: return "Monthly usage"
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(chartTitle).font(COSType.body(16, weight: .semibold))
                    Spacer()
                    chartControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(chartTitle).font(COSType.body(16, weight: .semibold))
                    chartControls
                }
            }
            if let seriesNote {
                Text(seriesNote).font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
            }
            HStack {
                Toggle("Exclude cache reads", isOn: $excludeCacheReads).toggleStyle(COSCheckStyle())
                    .help("Compare input, output and cache writes without repeated cache reads. Changes chart tokens, token mix and table shares, not API value.")
                Spacer()
                Text("Hover or inspect a period for its breakdown").font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
            }
            if measure == .cost && selected.allSatisfy({ $0.pricedEvents == 0 }) {
                Text("Cost unavailable: no verified prices for this selection.").frame(maxWidth: .infinity, minHeight: 220).foregroundStyle(.secondary)
            } else {
                SessionUsageChart(points: points, rows: selected, scale: timeScale, measure: measure,
                    excludeCacheReads: excludeCacheReads, timeZone: reportingZone, inspectedPeriod: inspectedBinding,
                    lineChart: lineChart, bounds: selectionBounds).zIndex(2)
                if timeScale == .monthly {
                    Text("Monthly buckets include only selected dates; boundary months may be partial.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                } else if timeScale == .weekly {
                    Text("Weekly buckets group recorded dates by Monday to Sunday in \(reportingZone.identifier); boundary weeks may be partial.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                }
                if seriesMode == .models {
                    Text("The six largest models by selected tokens are shown separately; remaining models are combined.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                } else if seriesMode == .categories && measure == .cost {
                    Text("Category API value splits fully priced records only; partially priced records stay out of the split.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                } else if seriesMode == .categories && excludeCacheReads {
                    Text("Cache reads are excluded, so the chart plots uncached input, output and cache write.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                }
                Text(lineChart ? "Lines connect recorded dates only; missing dates are not zero usage." : "Stacked bars show recorded dates only; missing dates are not zero usage.")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                if measure == .cost && selected.contains(where: { $0.pricedEvents < $0.events }) {
                    Text("API values include priced records only. Unpriced provider/model periods are omitted; partial values exclude unknown costs.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                }
                periodInspector.id(Self.inspectorID).zIndex(1)
            }
        }
    }

    private var chartControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                COSViewSwitch("Time scale", selection: Binding(get: { timeScale }, set: { timeScale = $0; scaleBeforeHistory = nil }),
                              options: SessionUsageTimeScale.allCases.map { COSViewOption($0, $0.rawValue) })
                COSViewSwitch("Measure", selection: $measure, options: SessionUsageMeasure.allCases.map { COSViewOption($0, $0.rawValue) })
            }
            HStack {
                COSViewSwitch("Series", selection: Binding(get: { seriesMode }, set: { seriesMode = $0; seriesNote = nil }),
                              options: P.seriesOptions(for: measure).map { COSViewOption($0, $0.rawValue) })
                COSViewSwitch("Chart style", selection: $lineChart, options: [
                    COSViewOption(true, "Lines"),
                    COSViewOption(false, "Stacked bars")
                ])
            }
        }
    }

    private var customDates: some View {
        HStack(spacing: 16) {
            DatePicker("From", selection: $customStart, displayedComponents: .date)
            DatePicker("Through", selection: $customEnd, displayedComponents: .date)
            if dateFormatter.string(from: customStart) > dateFormatter.string(from: customEnd) {
                Text("Choose an end date on or after the start.").foregroundStyle(.red)
            }
        }.environment(\.timeZone, reportingZone).font(COSType.body(12))
    }

    private var limitsNote: some View {
        DisclosureGroup("Subscription limits and coverage") {
            Text("Plan balances and reset times are unavailable here. Token totals and API value do not measure subscription utilization. Records are deduplicated usage observations, not sessions or messages. Environment is not recorded; these totals cover supported logs on this Mac.")
                .font(COSType.body(12)).foregroundStyle(COSPalette.subtle).padding(.top, 6)
        }.font(COSType.body(12))
    }

    private var providerBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Providers · \(month)").font(COSType.body(16, weight: .semibold))
                Spacer()
                Text("Click a provider to filter").font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Text("Provider"); Text(excludeCacheReads ? "Without cache reads" : "All tokens")
                    Text("Selection share"); Text("Usage records"); Text("Estimated API value")
                }.font(COSType.body(12, weight: .semibold)).foregroundStyle(COSPalette.subtle)
                ForEach(P.summarize(selected, by: \.provider, excludingCacheReads: excludeCacheReads)) { row in
                    let isSelected = provider == row.id
                    let denom = measured(counts)
                    let num = measured(row.counts)
                    GridRow {
                        Button { slice.toggleProvider(row.id) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(SessionUsageChart.seriesColor(row.id)).frame(width: 8, height: 8)
                                Text(row.id).fontWeight(isSelected ? .semibold : .regular)
                                if isSelected {
                                    Text("Filtered").font(COSType.body(10, weight: .semibold)).foregroundStyle(COSPalette.gold)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isSelected ? "Clear \(row.id) provider filter" : "Filter Usage by \(row.id)")
                        Text(SessionUsagePricing.tokens(num))
                        HStack(spacing: 8) {
                            Text(P.share(num, of: denom)).frame(width: 48, alignment: .leading)
                            proportionBar(fraction: denom > 0 ? Double(num) / Double(denom) : 0, color: SessionUsageChart.seriesColor(row.id))
                                .frame(width: 56, height: 6)
                        }
                        Text(row.events.formatted()).help("Deduplicated usage observations, not sessions or messages.")
                        Text(row.costLabel)
                    }
                    Divider()
                }
            }.font(COSType.body(13)).monospacedDigit()
        }
    }

    private var tokenMix: some View {
        let categories = P.tokenMix(counts, excludingCacheReads: excludeCacheReads, rows: selected)
        let split = P.costSplit(selected)
        let denom = measured(counts)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(excludeCacheReads ? "Token mix · cache reads excluded" : "Token mix · all recorded tokens")
                    .font(COSType.body(16, weight: .semibold))
                Spacer()
                Button {
                    if seriesMode == .categories { seriesMode = .providers } else {
                        if measure == .records { measure = .tokens }
                        seriesMode = .categories
                    }
                    seriesNote = nil
                } label: {
                    Text(seriesMode == .categories ? "Showing categories on chart" : "Plot categories on chart")
                        .font(COSType.body(12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(COSPalette.gold)
            }
            HStack(alignment: .top, spacing: 20) {
                ForEach(categories) { category in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Circle().fill(SessionUsageChart.seriesColor(category.id)).frame(width: 8, height: 8)
                            Text(category.id).font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
                        }
                        Text(SessionUsagePricing.tokens(category.count)).font(COSType.body(18, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(category.excludedFromTokens ? COSPalette.subtle : .primary)
                        Text(category.excludedFromTokens ? "Excluded from token share" : P.share(category.count, of: denom) + " of tokens")
                            .font(COSType.body(12)).foregroundStyle(COSPalette.subtle).monospacedDigit()
                        if split.splitUSD > 0 {
                            Text(category.estimatedUSD.formatted(.currency(code: "USD")) + " · " + P.costShare(category.estimatedUSD, of: split.splitUSD) + " of API value")
                                .font(COSType.body(11)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if denom > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(excludeCacheReads ? "Tokens, no reads" : "Tokens").font(COSType.body(11, weight: .medium)).foregroundStyle(COSPalette.subtle).frame(width: 96, alignment: .leading)
                        stackedMixBar(items: categories.filter { !$0.excludedFromTokens }.map { ($0.id, Double($0.count) / Double(denom)) })
                    }
                    if split.splitUSD > 0 {
                        HStack(spacing: 10) {
                            Text("API value").font(COSType.body(11, weight: .medium)).foregroundStyle(COSPalette.subtle).frame(width: 96, alignment: .leading)
                            stackedMixBar(items: categories.map { ($0.id, $0.estimatedUSD / split.splitUSD) })
                        }
                    }
                }.padding(.top, 2)
            }
            Text("Disjoint categories; reasoning is included in output. Token shares use the displayed token total. Cache reads are repeated context, not cache savings."
                 + (excludeCacheReads ? " API value still includes cache reads." : ""))
                .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
            if !split.isComplete && split.pricedUSD > 0 {
                Text("The API value split covers fully priced records only: \(split.splitUSD.formatted(.currency(code: "USD"))) of \(split.pricedUSD.formatted(.currency(code: "USD"))) priced. \(split.unsplitRecords.formatted()) records in partially priced model days stay out of it.")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
            }
        }
    }

    private func stackedMixBar(items: [(String, Double)]) -> some View {
        GeometryReader { geo in
            let widths = P.segmentWidths(items.map(\.1), total: geo.size.width, spacing: 1, minimum: 2)
            HStack(spacing: 1) {
                ForEach(Array(items.enumerated()).filter { widths[$0.offset] > 0 }, id: \.element.0) { pair in
                    Rectangle()
                        .fill(SessionUsageChart.seriesColor(pair.element.0))
                        .frame(width: widths[pair.offset])
                        .help("\(pair.element.0): \(String(format: "%.1f%%", pair.element.1 * 100))")
                }
            }
        }
        .frame(height: 8)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func proportionBar(fraction: Double, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(COSPalette.border.opacity(0.45))
                RoundedRectangle(cornerRadius: 3).fill(color)
                    .frame(width: max(fraction > 0 ? 2 : 0, geo.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
    }

    private func arrow(_ active: Bool, ascending: Bool) -> String { active ? (ascending ? " ↑" : " ↓") : "" }

    private func modelHeader(_ title: String, _ sort: SessionUsageModelSort, help: String? = nil) -> some View {
        Button {
            if modelSort == sort { modelSortAscending.toggle() } else { modelSort = sort; modelSortAscending = P.defaultAscending(sort) }
        } label: {
            Text(title + arrow(modelSort == sort, ascending: modelSortAscending)).foregroundStyle(modelSort == sort ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help ?? "Sort models by \(title)")
    }

    private func modelButton(_ row: SessionUsageBucket, detail: String? = nil) -> some View {
        let isFiltered = model == row.model && (provider == P.allProviders || provider == row.provider)
        return Button { slice.toggleModel(provider: row.provider, model: row.model) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.model).fontWeight(isFiltered ? .semibold : .regular)
                    if isFiltered {
                        Text("Filtered").font(COSType.body(10, weight: .semibold)).foregroundStyle(COSPalette.gold)
                    }
                }
                Text(detail.map { row.provider + " · " + $0 } ?? row.provider).font(COSType.body(11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFiltered ? "Clear \(row.model) filter" : "Filter Usage by \(row.provider) · \(row.model)")
    }

    private func modelCost(_ row: SessionUsageBucket) -> some View {
        let partial = row.pricedEvents > 0 && row.pricedEvents < row.events
        return Text(row.pricedEvents == 0 ? "Unavailable" : row.estimatedUSD.formatted(.currency(code: "USD")) + (partial ? " + unknown" : "")).monospacedDigit()
            .help(row.pricedEvents == 0 ? "No verified price; sorts last on API value." : partial ? "Partially priced: \(row.pricedEvents) of \(row.events) records have a verified price." : "All \(row.events) records priced.")
    }

    private func withinProvider(_ row: SessionUsageBucket) -> String {
        P.share(measured(row.counts), of: periodRows.filter { $0.provider == row.provider }.reduce(0) { $0 + measured($1.counts) })
    }

    private var modelsSection: some View {
        let rows = ranking
        let totalTokens = measured(counts)
        let tokensTitle = excludeCacheReads ? "Without cache reads" : "All tokens"
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Models · \(month)").font(COSType.body(16, weight: .semibold))
                Spacer()
                Text("Click a model to filter").font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
            }
            HStack(spacing: 12) {
                COSViewSwitch("Sort models", selection: Binding(get: { modelSort }, set: { modelSort = $0; modelSortAscending = P.defaultAscending($0) }),
                              options: SessionUsageModelSort.allCases.map { COSViewOption($0, $0.rawValue) })
                directionButton(P.directionLabel(modelSort, ascending: modelSortAscending), ascending: modelSortAscending) { modelSortAscending.toggle() }
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    GridRow {
                        modelHeader("Provider / model", .model)
                        modelHeader(tokensTitle, .tokens)
                        Text("Selection share").help("Share of tokens across the selected period, provider and model. Never your subscription allowance.")
                        Text("Within provider").help("Share of this provider's tokens across all its models in the selected period.")
                        modelHeader("Usage records", .records)
                        modelHeader("Cache read %", .cacheShare, help: "Sort by the share of each model's recorded tokens that were cache reads")
                        modelHeader("Estimated API value", .cost, help: "Sort by API value; unpriced models stay last")
                    }.font(COSType.body(12, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        GridRow {
                            modelButton(row)
                            Text(SessionUsagePricing.tokens(measured(row.counts))).monospacedDigit()
                            Text(P.share(measured(row.counts), of: totalTokens)).monospacedDigit()
                            Text(withinProvider(row)).monospacedDigit().help("Share of recorded \(row.provider) tokens; all models in \(month).")
                            Text(row.events.formatted()).monospacedDigit()
                            Text(P.share(row.counts.cacheRead, of: row.counts.total)).monospacedDigit()
                            modelCost(row)
                        }
                        Divider()
                    }
                }
                // Narrow windows: within-provider and cache-read shares move under the model name.
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow {
                        modelHeader("Provider / model", .model)
                        modelHeader(tokensTitle, .tokens)
                        Text("Share")
                        modelHeader("Records", .records)
                        modelHeader("API value", .cost, help: "Sort by API value; unpriced models stay last")
                    }.font(COSType.body(12, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(rows) { row in
                        GridRow {
                            modelButton(row, detail: "\(withinProvider(row)) of provider · \(P.share(row.counts.cacheRead, of: row.counts.total)) cache read")
                            Text(SessionUsagePricing.tokens(measured(row.counts))).monospacedDigit()
                            Text(P.share(measured(row.counts), of: totalTokens)).monospacedDigit()
                            Text(row.events.formatted()).monospacedDigit()
                            modelCost(row)
                        }
                        Divider()
                    }
                }
            }
            .font(COSType.body(13))
        }
    }

    private func directionButton(_ title: String, ascending: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Label(title, systemImage: ascending ? "arrow.up" : "arrow.down").font(COSType.body(11))
        }
        .buttonStyle(.plain).foregroundStyle(COSPalette.subtle)
        .help("Reverse the sort order")
        .fixedSize()
    }

    private func dayHeader(_ title: String, _ sort: SessionUsageDaySort) -> some View {
        Button {
            if daySort == sort { daySortAscending.toggle() } else { daySort = sort; daySortAscending = false }
        } label: {
            Text(title + arrow(daySort == sort, ascending: daySortAscending)).foregroundStyle(daySort == sort ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .help("Sort days by \(title)")
    }

    private var dayBreakdown: some View {
        DisclosureGroup("Daily breakdown · \(Set(selected.map(\.day)).count) recorded days", isExpanded: $dayBreakdownExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    COSViewSwitch("Sort days", selection: Binding(get: { daySort }, set: { daySort = $0; daySortAscending = false }),
                                  options: SessionUsageDaySort.allCases.map { COSViewOption($0, $0.rawValue) })
                    directionButton(P.directionLabel(daySort, ascending: daySortAscending), ascending: daySortAscending) { daySortAscending.toggle() }
                    Spacer()
                    Text("Click a day to inspect its breakdown").font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                }.padding(.bottom, 4)
                HStack {
                    dayHeader("Date", .date)
                    Spacer()
                    dayHeader("Tokens", .tokens)
                    Text("Share").frame(width: 52, alignment: .trailing).foregroundStyle(.secondary)
                    dayHeader("Records", .records).frame(minWidth: 92, alignment: .trailing)
                    dayHeader("API value", .cost).frame(minWidth: 110, alignment: .trailing)
                }.font(COSType.body(12, weight: .semibold))
                ForEach(sortedDays) { row in
                    let isInspected = timeScale == .daily && inspectedPeriod == row.id
                    let rowTokens = measured(row.counts)
                    Button {
                        if isInspected { inspection = nil } else { inspectDay(row.id) }
                    } label: {
                        HStack {
                            Text(row.id).fontWeight(isInspected ? .semibold : .regular)
                            if isInspected {
                                Text("Inspecting").font(COSType.body(10, weight: .semibold)).foregroundStyle(COSPalette.gold)
                            }
                            Spacer()
                            Text(SessionUsagePricing.tokens(rowTokens) + " tokens")
                            Text(P.share(rowTokens, of: measured(counts)))
                                .foregroundStyle(COSPalette.subtle).frame(width: 52, alignment: .trailing)
                            Text("\(row.events.formatted()) records").foregroundStyle(COSPalette.subtle)
                                .frame(minWidth: 92, alignment: .trailing)
                            Text(row.costLabel).frame(minWidth: 110, alignment: .trailing)
                        }.font(COSType.body(12)).monospacedDigit().contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }.padding(.top, 10)
        }.font(COSType.body(14, weight: .semibold))
    }

    private var periodInspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                COSDropdown("Inspect period", selection: Binding(get: { inspectedPeriod ?? "" }, set: { inspectedBinding.wrappedValue = $0.isEmpty ? nil : $0 }),
                    options: [COSDropdownOption("", "Choose a period")] + periodKeys.map { COSDropdownOption($0, periodTitle($0)) })
                    .frame(maxWidth: 410)
                if inspectedPeriod != nil {
                    Button("Previous", systemImage: "chevron.left") { moveInspection(-1) }
                        .disabled(inspectedPeriod == periodKeys.first)
                    Button("Next", systemImage: "chevron.right") { moveInspection(1) }
                        .disabled(inspectedPeriod == periodKeys.last)
                    Button("Close", systemImage: "xmark") { inspection = nil }
                }
            }
            if let key = inspectedPeriod, periodKeys.contains(key) {
                SessionUsagePeriodDetail(title: periodTitle(key), rows: periodValues(key), excludingCacheReads: excludeCacheReads, measure: measure, compact: false)
                    .padding(16).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func moveInspection(_ delta: Int) {
        let keys = periodKeys
        guard let key = inspectedPeriod, let index = keys.firstIndex(of: key), keys.indices.contains(index + delta) else { return }
        inspection = SessionUsageInspection(key: keys[index + delta], scale: timeScale)
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(COSType.body(22, weight: .semibold)).monospacedDigit()
            Text(label).font(COSType.body(12)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filter(_ title: String, selection: Binding<String>, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(COSType.body(12)).foregroundStyle(.secondary)
            COSDropdown(title, selection: selection, options: values.map { COSDropdownOption($0, $0) }, showsLabel: false)
        }
    }
}

/// Hover updates stay here; moving the pointer never recomputes the report table or imports files.
struct SessionUsageChart: View {
    private typealias P = SessionUsagePresentation
    static let height: CGFloat = 270
    let points: [SessionUsageView.Point]
    let rows: [SessionUsageBucket]
    let scale: SessionUsageTimeScale
    let measure: SessionUsageMeasure
    let excludeCacheReads: Bool
    let timeZone: TimeZone
    let lineChart: Bool
    let bounds: ClosedRange<String>?
    @Binding var inspectedPeriod: String?
    @State private var hoveredPeriod: String?
    @State private var hoverX: CGFloat = 0
    /// Built once per parent render, never per pointer move.
    private let calendar: Calendar
    private let keyByDay: [String: String]
    private let periodKeys: [String]
    private let periodKeySet: Set<String>

    init(points: [SessionUsageView.Point], rows: [SessionUsageBucket], scale: SessionUsageTimeScale, measure: SessionUsageMeasure,
         excludeCacheReads: Bool, timeZone: TimeZone, inspectedPeriod: Binding<String?>, initialHover: String? = nil, lineChart: Bool = false,
         bounds: ClosedRange<String>? = nil, initialHoverX: CGFloat = 0) {
        self.points = points; self.rows = rows; self.scale = scale; self.measure = measure
        self.excludeCacheReads = excludeCacheReads; self.timeZone = timeZone; self._inspectedPeriod = inspectedPeriod
        self._hoveredPeriod = State(initialValue: initialHover)
        self._hoverX = State(initialValue: initialHoverX)
        self.lineChart = lineChart
        self.bounds = bounds
        calendar = SessionUsagePresentation.reportingCalendar(timeZone)
        keyByDay = SessionUsagePresentation.periodKeyMap(rows, scale: scale)
        periodKeySet = Set(keyByDay.values)
        periodKeys = periodKeySet.sorted()
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
        case "Anthropic": return COSPalette.gold
        case "OpenAI": return Color(red: 0.02, green: 0.59, blue: 0.62)
        case "Ollama": return Color(red: 0.53, green: 0.40, blue: 0.77)
        case "Uncached input": return Color(red: 0.20, green: 0.49, blue: 0.78)
        case "Output": return Color(red: 0.86, green: 0.43, blue: 0.16)
        case "Cache read": return COSPalette.gold
        case "Cache write": return Color(red: 0.53, green: 0.40, blue: 0.77)
        case "Other models": return .gray
        default:
            let colors: [Color] = [.blue, .green, .pink, .indigo, .brown]
            let index = name.utf8.reduce(0) { ($0 * 31 + Int($1)) % colors.count }
            return colors[index]
        }
    }

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

    private var yAxisLabel: String {
        switch measure {
        case .cost: return "USD (priced records only)"
        case .records: return "Usage records"
        case .tokens: return excludeCacheReads ? "Million tokens, excluding cache reads" : "Million tokens, including cache reads"
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

    private var seriesNames: [String] { Array(Set(points.map(\.series))).sorted() }

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
                        .accessibilityLabel("\(P.dayKey(for: point.date, calendar: calendar)), \(point.series)")
                        .accessibilityValue(accessibleValue(point))
                }
            }
            if let key = hoveredPeriod ?? inspectedPeriod, let date = P.noon(of: P.periodStart(key), calendar: calendar) {
                RuleMark(x: .value("Inspect", date, unit: calendarUnit))
                    .foregroundStyle(COSPalette.subtle.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: periodKeys) { _, _ in hoveredPeriod = nil }
        .environment(\.calendar, calendar)
        .environment(\.timeZone, timeZone)
        .chartForegroundStyleScale(domain: seriesNames, range: seriesNames.map { Self.seriesColor($0) })
        .chartYAxisLabel(yAxisLabel)
        .frame(height: Self.height)
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
                            .onTapGesture { if let key = hoveredPeriod { inspectedPeriod = key } }
                            .accessibilityHidden(true)
                        if let key = hoveredPeriod {
                            // The card's padding is part of its width and height: place and cap the padded card.
                            let padding: CGFloat = 14
                            let contentWidth = max(160, min(CGFloat(360), geometry.size.width - 16 - 2 * padding))
                            let cardWidth = contentWidth + 2 * padding
                            let maxContentHeight = max(80, geometry.size.height - 16 - 2 * padding)
                            let x = P.tooltipX(pointer: Double(hoverX), cardWidth: Double(cardWidth), containerWidth: Double(geometry.size.width))
                            SessionUsagePeriodDetail(title: periodTitle(key), rows: periodValues(key), excludingCacheReads: excludeCacheReads, measure: measure, compact: true)
                                .frame(width: contentWidth).fixedSize(horizontal: false, vertical: true)
                                // A max-only frame grows to its proposal; fixing it vertically keeps the card at its content height.
                                .frame(maxHeight: maxContentHeight, alignment: .top).clipped().fixedSize(horizontal: false, vertical: true)
                                .padding(padding).background(COSPalette.card, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.border))
                                .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
                                .offset(x: CGFloat(x), y: 8)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
    }
}

/// The same period summary serves pointer hover and the keyboard-accessible inspector.
struct SessionUsagePeriodDetail: View {
    let title: String
    let rows: [SessionUsageBucket]
    let excludingCacheReads: Bool
    var measure: SessionUsageMeasure = .tokens
    let compact: Bool
    /// The hover card must fit inside the 270 pt chart, so it lists three models and one category line.
    private var compactModelLimit: Int { 3 }
    private var counts: SessionUsageCounts { rows.reduce(SessionUsageCounts()) { $0 + $1.counts } }
    private var models: [SessionUsageBucket] { SessionUsagePresentation.aggregate(rows, excludingCacheReads: excludingCacheReads) }
    private var categories: [SessionUsagePresentation.TokenCategory] {
        SessionUsagePresentation.tokenMix(counts, excludingCacheReads: false, rows: rows)
    }
    private func tokens(_ counts: SessionUsageCounts) -> String { SessionUsagePricing.tokens(SessionUsagePresentation.tokenCount(counts, excludingCacheReads: excludingCacheReads)) }
    private var records: Int { rows.reduce(0) { $0 + $1.events } }
    private var recordsLine: String { "\(records.formatted()) usage records · \(rows.reduce(0) { $0 + $1.pricedEvents }.formatted()) priced" }
    /// The headline follows the chart's measure; the other two figures stay beside it.
    private var headline: (String, String) {
        switch measure {
        case .tokens: return (tokens(counts) + " tokens", SessionUsagePresentation.costLabel(rows))
        case .cost: return (SessionUsagePresentation.costLabel(rows), tokens(counts) + " tokens")
        case .records: return ("\(records.formatted()) records", tokens(counts) + " tokens")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(COSType.body(14, weight: .semibold))
                if compact {
                    Spacer(minLength: 8)
                    Text(recordsLine).foregroundStyle(COSPalette.subtle)
                }
            }
            HStack {
                Text(headline.0).font(COSType.body(18, weight: .semibold)).monospacedDigit()
                    .help(SessionUsagePresentation.tokenCount(counts, excludingCacheReads: excludingCacheReads).formatted() + " tokens")
                Spacer()
                Text(headline.1).font(COSType.body(13, weight: .semibold)).monospacedDigit()
            }
            if !compact {
                Text(excludingCacheReads ? "Cache reads excluded from token totals. API value includes all priced tokens." : "All token categories included. Estimated API value, not your bill.")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
            }
            if !compact { Text(recordsLine).foregroundStyle(COSPalette.subtle) }
            ForEach(SessionUsagePresentation.summarize(rows, by: \.provider, excludingCacheReads: excludingCacheReads)) { provider in
                HStack {
                    Text(provider.id).fontWeight(.semibold)
                    Spacer()
                    Text(tokens(provider.counts)).monospacedDigit()
                    Text(SessionUsagePresentation.share(SessionUsagePresentation.tokenCount(provider.counts, excludingCacheReads: excludingCacheReads), of: SessionUsagePresentation.tokenCount(counts, excludingCacheReads: excludingCacheReads)))
                    Text(provider.costLabel).foregroundStyle(COSPalette.subtle)
                }.font(COSType.body(11))
            }
            Divider()
            ForEach(compact ? Array(models.prefix(compactModelLimit)) : models) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.model).lineLimit(1).truncationMode(.middle)
                        if !compact { Text(row.provider).foregroundStyle(COSPalette.subtle).font(COSType.body(11)) }
                    }
                    Spacer(minLength: 8)
                    Text(tokens(row.counts)).monospacedDigit()
                    Text(SessionUsagePresentation.costLabel([row])).monospacedDigit().foregroundStyle(COSPalette.subtle)
                }.font(COSType.body(12))
            }
            if compact {
                Text("Input \(SessionUsagePricing.tokens(counts.input)) · Output \(SessionUsagePricing.tokens(counts.output)) · Cache read \(SessionUsagePricing.tokens(counts.cacheRead)) · Cache write \(SessionUsagePricing.tokens(counts.cacheWrite))")
                    .foregroundStyle(COSPalette.subtle)
                Text(models.count > compactModelLimit ? "\(models.count - compactModelLimit) more \(models.count - compactModelLimit == 1 ? "model" : "models"). Click to keep the full breakdown open." : "Click to keep this breakdown open")
                    .foregroundStyle(COSPalette.subtle)
            } else {
                Divider()
                Text("Input \(SessionUsagePricing.tokens(counts.input))  ·  Output \(SessionUsagePricing.tokens(counts.output))")
                Text("Cache read \(SessionUsagePricing.tokens(counts.cacheRead))  ·  Cache write \(SessionUsagePricing.tokens(counts.cacheWrite))")
            }
            if !compact, rows.contains(where: { $0.pricedEvents > 0 }) {
                ChipFlowLayout(spacing: 12) {
                    ForEach(categories) { cat in
                        Text("\(cat.id): \(cat.estimatedUSD.formatted(.currency(code: "USD")))")
                            .font(COSType.body(11)).foregroundStyle(COSPalette.subtle).monospacedDigit()
                    }
                }
                if !SessionUsagePresentation.costSplit(rows).isComplete {
                    Text("Category values cover fully priced records only.").font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                }
            }
        }.font(COSType.body(11)).foregroundStyle(.primary)
    }
}
