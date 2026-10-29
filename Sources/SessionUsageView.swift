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
    @ObservedObject var store: SessionUsageStore
    @State private var month = "Last 30 days"
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -29, to: Date())!
    @State private var customEnd = Date()
    @State private var timeScale: SessionUsageTimeScale = .daily
    @State private var measure: SessionUsageMeasure = .tokens
    @State private var seriesMode: SessionUsageSeries = .providers
    @State private var lineChart = true
    @State private var provider = "All providers"
    @State private var model = "All models"
    @State private var excludeCacheReads = false
    @State private var inspectedPeriod: String?
    @State private var dayBreakdownExpanded = false
    @State private var modelSort: SessionUsageModelSort = .tokens
    @State private var modelSortAscending = false
    @State private var daySort: SessionUsageDaySort = .date
    @State private var daySortAscending = false
    @State private var exportStatus: String?

    init(store: SessionUsageStore, initialPeriod: String? = nil, initialInspection: String? = nil,
         initialDates: (Date, Date)? = nil, initialCostChart: Bool = false,
         initialExcludeCacheReads: Bool = false, initialDayBreakdownExpanded: Bool = false,
         initialTimeScale: SessionUsageTimeScale? = nil, initialMeasure: SessionUsageMeasure? = nil,
         initialSeries: SessionUsageSeries = .providers, initialLineChart: Bool = true,
         initialProvider: String = "All providers", initialModel: String = "All models",
         initialModelSort: SessionUsageModelSort = .tokens, initialDaySort: SessionUsageDaySort = .date) {
        self.store = store
        let period = initialPeriod ?? "Last 30 days"
        _month = State(initialValue: period)
        _timeScale = State(initialValue: initialTimeScale ?? (period == "All history" ? .monthly : .daily))
        _measure = State(initialValue: initialMeasure ?? (initialCostChart ? .cost : .tokens))
        _seriesMode = State(initialValue: initialSeries)
        _lineChart = State(initialValue: initialLineChart)
        _provider = State(initialValue: initialProvider)
        _model = State(initialValue: initialModel)
        _inspectedPeriod = State(initialValue: initialInspection)
        if let initialDates {
            _customStart = State(initialValue: initialDates.0)
            _customEnd = State(initialValue: initialDates.1)
        }
        _excludeCacheReads = State(initialValue: initialExcludeCacheReads)
        _dayBreakdownExpanded = State(initialValue: initialDayBreakdownExpanded)
        _modelSort = State(initialValue: initialModelSort)
        _daySort = State(initialValue: initialDaySort)
    }

    private static func monthKey(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"; return f.string(from: date)
    }
    private var buckets: [SessionUsageBucket] { store.report?.buckets ?? [] }
    private var providers: [String] { Array(Set(buckets.map(\.provider))).sorted() }
    private var models: [String] { Array(Set(buckets.filter { provider == "All providers" || $0.provider == provider }.map(\.model))).sorted() }
    private var months: [String] { Array(Set(buckets.map { String($0.day.prefix(7)) } + [Self.monthKey(Date())])).sorted(by: >) }
    private var reportingZone: TimeZone { TimeZone(identifier: store.report?.timeZone ?? "") ?? .current }
    private var periodRows: [SessionUsageBucket] {
        SessionUsagePresentation.selectPeriod(buckets, period: month, now: Date(), timeZone: reportingZone, customStart: customStart, customEnd: customEnd)
    }
    private var selected: [SessionUsageBucket] {
        periodRows.filter { (provider == "All providers" || $0.provider == provider) && (model == "All models" || $0.model == model) }
    }
    private var chartRows: [SessionUsageBucket] { selected }
    private var periodKeys: [String] {
        Array(Set(chartRows.map { SessionUsagePresentation.periodKey(for: $0.day, scale: timeScale, timeZone: reportingZone) })).sorted()
    }
    private func measured(_ counts: SessionUsageCounts) -> Int64 { SessionUsagePresentation.tokenCount(counts, excludingCacheReads: excludeCacheReads) }
    private func periodValues(_ key: String) -> [SessionUsageBucket] {
        chartRows.filter { SessionUsagePresentation.periodKey(for: $0.day, scale: timeScale, timeZone: reportingZone) == key }
    }
    private func periodTitle(_ key: String) -> String {
        SessionUsagePresentation.periodTitle(for: key, scale: timeScale, timeZone: reportingZone)
    }
    private var counts: SessionUsageCounts { selected.reduce(SessionUsageCounts()) { $0 + $1.counts } }
    private var unpriced: Int { selected.reduce(0) { $0 + $1.events - $1.pricedEvents } }
    private var priced: Int { selected.reduce(0) { $0 + $1.pricedEvents } }
    private var cost: Double { selected.reduce(0) { $0 + $1.estimatedUSD } }
    private var dateFormatter: DateFormatter { SessionUsagePresentation.dayFormatter(timeZone: reportingZone) }
    private var ranking: [SessionUsageBucket] {
        SessionUsagePresentation.sortModels(selected, by: modelSort, ascending: modelSortAscending, excludingCacheReads: excludeCacheReads)
    }
    private var sortedDays: [SessionUsagePresentation.Summary] {
        SessionUsagePresentation.sortDays(selected, by: daySort, ascending: daySortAscending, excludingCacheReads: excludeCacheReads)
    }
    private var comparison: SessionUsagePresentation.PeriodComparison {
        SessionUsagePresentation.comparePeriod(allRows: buckets, selectedRows: selected, period: month, provider: provider, model: model,
            excludingCacheReads: excludeCacheReads, now: Date(), timeZone: reportingZone, customStart: customStart, customEnd: customEnd)
    }
    private var hasActiveSlice: Bool {
        provider != "All providers" || model != "All models" || excludeCacheReads || inspectedPeriod != nil
    }

    struct Point: Identifiable {
        var date: Date; var series: String; var tokens: Int64; var usd: Double
        var pricedEvents: Int = 1
        var events: Int = 1
        var id: String { String(date.timeIntervalSince1970) + series }
    }

    private var points: [Point] {
        let rows = chartRows
        let formatter = dateFormatter
        if seriesMode == .categories && measure != .records {
            let byPeriod = Dictionary(grouping: rows) {
                SessionUsagePresentation.periodKey(for: $0.day, scale: timeScale, timeZone: reportingZone)
            }
            var result: [Point] = []
            for (pKey, group) in byPeriod {
                let dateStr = pKey.count == 7 ? pKey + "-01" : pKey
                guard let date = formatter.date(from: dateStr) else { continue }
                let groupCounts = group.reduce(SessionUsageCounts()) { $0 + $1.counts }
                let groupEvents = group.reduce(0) { $0 + $1.events }
                let groupPriced = group.reduce(0) { $0 + $1.pricedEvents }
                let categories = SessionUsagePresentation.tokenMix(groupCounts, excludingCacheReads: measure == .cost ? false : excludeCacheReads, rows: group)
                for cat in categories {
                    result.append(Point(date: date, series: cat.id, tokens: cat.count, usd: cat.estimatedUSD, pricedEvents: groupPriced, events: groupEvents))
                }
            }
            return result.sorted { a, b in
                if a.date == b.date { return a.series < b.series }
                return a.date < b.date
            }
        }
        var modelTotals: [String: Int64] = [:]
        for row in rows { modelTotals[row.model, default: 0] += measured(row.counts) }
        let orderedModels = modelTotals.keys.sorted { a, b in
            let left = modelTotals[a, default: 0], right = modelTotals[b, default: 0]
            if left == right { return a < b }
            return left > right
        }
        let top = Set(orderedModels.prefix(6))
        var grouped: [String: [SessionUsageBucket]] = [:]
        let useProviders = seriesMode == .providers || (seriesMode == .categories && measure == .records)
        for row in rows {
            let pKey = SessionUsagePresentation.periodKey(for: row.day, scale: timeScale, timeZone: reportingZone)
            let day = pKey.count == 7 ? pKey + "-01" : pKey
            let series = useProviders ? row.provider : top.contains(row.model) ? row.model : "Other models"
            grouped[day + "|" + series, default: []].append(row)
        }
        var result: [Point] = []
        for (key, group) in grouped {
            let parts = key.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let date = formatter.date(from: String(parts[0])) else { continue }
            let tokens = group.reduce(Int64(0)) { $0 + measured($1.counts) }
            let usd = group.reduce(0.0) { $0 + $1.estimatedUSD }
            result.append(Point(date: date, series: String(parts[1]), tokens: tokens, usd: usd,
                pricedEvents: group.reduce(0) { $0 + $1.pricedEvents }, events: group.reduce(0) { $0 + $1.events }))
        }
        return result.sorted { a, b in
            if a.date == b.date { return a.series < b.series }
            return a.date < b.date
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 12) {
                    filter("Period", selection: $month, values: ["Last 7 days", "Last 30 days", "Last 90 days", "Last weekend", "Custom dates", "All history"] + months).frame(width: 150)
                    filter("Provider", selection: $provider, values: ["All providers"] + providers).frame(maxWidth: 190)
                    filter("Model", selection: $model, values: ["All models"] + models).frame(maxWidth: 290)
                    Spacer()
                    exportButtons
                    Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(store.loading)
                }
                .onChange(of: provider) { _, _ in
                    if model != "All models" && !models.contains(model) { model = "All models" }
                    clearInspection()
                }
                .onChange(of: month) { _, value in
                    timeScale = value == "All history" ? .monthly : .daily
                    clearInspection()
                }
                .onChange(of: model) { _, _ in clearInspection() }
                .onChange(of: timeScale) { _, _ in clearInspection() }
                .onChange(of: periodKeys) { _, keys in
                    if let inspectedPeriod, !keys.contains(inspectedPeriod) { clearInspection() }
                }
                .onChange(of: customStart) { _, _ in clearInspection() }
                .onChange(of: customEnd) { _, _ in clearInspection() }
                if month == "Custom dates" { customDates }
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
                HStack(alignment: .top, spacing: 28) {
                    metric("All recorded tokens", SessionUsagePricing.tokens(counts.total))
                    metric("Usage records", selected.reduce(0) { $0 + $1.events }.formatted())
                    metric("Recorded days", Set(selected.map(\.day)).count.formatted())
                    metric("Estimated API value", priced == 0 ? "Unavailable" : cost.formatted(.currency(code: "USD")) + (unpriced > 0 ? " + unknown" : ""))
                }
                if !selected.isEmpty {
                    comparisonStrip
                }
                Label(SessionUsagePresentation.allowanceNote, systemImage: "info.circle")
                    .font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Standard API-equivalent estimate, not your subscription bill. Rates checked October 25, 2026 and applied to all dates. Discounts, speed tiers, tools and taxes are excluded.")
                    .font(COSType.body(12)).foregroundStyle(.secondary)
                if store.loading { ProgressView(store.report == nil ? "Reading local usage…" : "Updating usage history…").controlSize(.small) }
                if let error = store.error { Text(error).foregroundStyle(.red) }
                if let report = store.report, report.pendingFiles > 0 {
                    Text("Backfilling history: \(report.pendingFiles) files remaining. Totals are partial and update as the import continues.").foregroundStyle(.secondary)
                }
                limitsNote
                chartSection.zIndex(1)
                providerBreakdown
                tokenMix
                modelsSection
                dayBreakdown
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
            }.padding(22)
        }
        .task { if store.report == nil { await store.refresh(importNew: store.enabled) } }
    }

    private func clearInspection() { inspectedPeriod = nil }

    private var exportButtons: some View {
        HStack(spacing: 8) {
            Button { copySliceCSV() } label: { Label("Copy CSV", systemImage: "doc.on.doc") }
                .disabled(selected.isEmpty)
                .help("Copy the current filtered buckets as CSV.")
            Button { copySliceJSON() } label: { Text("Copy JSON") }
                .disabled(selected.isEmpty)
                .help("Copy the current filtered report slice as JSON.")
        }.font(COSType.body(12))
    }

    private func copySliceCSV() {
        let csv = SessionUsagePresentation.exportCSV(selected, excludingCacheReads: excludeCacheReads)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(csv, forType: .string)
        exportStatus = "Copied \(selected.count) daily provider/model rows as CSV (\(month), \(provider), \(model))."
    }

    private func copySliceJSON() {
        let json = SessionUsagePresentation.exportJSON(selected, period: month, provider: provider, model: model,
            excludingCacheReads: excludeCacheReads, timeZone: reportingZone.identifier,
            pricingVersion: store.report?.pricingVersion ?? SessionUsagePricing.version)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        exportStatus = "Copied \(selected.count) daily provider/model rows as JSON (\(month), \(provider), \(model))."
    }

    private var activeSliceBar: some View {
        HStack(spacing: 10) {
            Text("Active slice:").font(COSType.body(12, weight: .semibold)).foregroundStyle(COSPalette.subtle)
            if provider != "All providers" {
                Button { provider = "All providers"; model = "All models" } label: {
                    Label("Provider: \(provider) ×", systemImage: "line.3.horizontal.decrease.circle")
                }.buttonStyle(.plain).font(COSType.body(12, weight: .medium))
            }
            if model != "All models" {
                Button { model = "All models" } label: {
                    Label("Model: \(model) ×", systemImage: "cpu")
                }.buttonStyle(.plain).font(COSType.body(12, weight: .medium))
            }
            if excludeCacheReads {
                Button { excludeCacheReads = false } label: {
                    Label("Cache reads excluded ×", systemImage: "eye.slash")
                }.buttonStyle(.plain).font(COSType.body(12, weight: .medium))
            }
            if let key = inspectedPeriod {
                Button { inspectedPeriod = nil } label: {
                    Label("Inspecting \(key) ×", systemImage: "calendar")
                }.buttonStyle(.plain).font(COSType.body(12, weight: .medium))
            }
            Spacer()
            Button("Reset slice") {
                provider = "All providers"
                model = "All models"
                excludeCacheReads = false
                inspectedPeriod = nil
            }.font(COSType.body(12))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 7))
    }

    private var comparisonStrip: some View {
        let cmp = comparison
        let avgCostText = priced == 0 ? "Unavailable" : cmp.dailyAvgUSD.formatted(.currency(code: "USD")) + (unpriced > 0 ? " + unknown" : "")
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    comparisonItems(cmp: cmp, avgCostText: avgCostText)
                }
                VStack(alignment: .leading, spacing: 6) {
                    comparisonItems(cmp: cmp, avgCostText: avgCostText)
                }
            }
            if let priorRange = cmp.priorRangeLabel {
                if cmp.hasPriorBaseline {
                    HStack(spacing: 14) {
                        Text("vs. prior window (\(priorRange)):").foregroundStyle(COSPalette.subtle)
                        Text("Tokens \(cmp.tokenDeltaLabel) (\(SessionUsagePricing.tokens(cmp.priorTokens)))").monospacedDigit()
                        Text("Records \(cmp.recordsDeltaLabel) (\(cmp.priorRecords.formatted()))").monospacedDigit()
                        Text("API value \(cmp.costDeltaLabel)").monospacedDigit()
                        if cmp.partialPriorHistory {
                            Text("· prior window starts before earliest local log").foregroundStyle(COSPalette.subtle)
                        }
                    }.font(COSType.body(12))
                } else {
                    Text("vs. prior window (\(priorRange)): No recorded local usage in the preceding window.")
                        .font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
                }
            }
        }
        .padding(12)
        .background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func comparisonItems(cmp: SessionUsagePresentation.PeriodComparison, avgCostText: String) -> some View {
        HStack(spacing: 6) {
            Text("Avg / recorded day:").font(COSType.body(12, weight: .semibold)).foregroundStyle(COSPalette.subtle)
            Text("\(SessionUsagePricing.tokens(cmp.dailyAvgTokens)) tokens · \(cmp.dailyAvgRecords.formatted()) records · \(avgCostText)")
                .font(COSType.body(12)).monospacedDigit()
        }
        if let peak = cmp.peakDay {
            HStack(spacing: 6) {
                Text("Peak day:").font(COSType.body(12, weight: .semibold)).foregroundStyle(COSPalette.subtle)
                Button {
                    timeScale = .daily
                    inspectedPeriod = peak.id
                } label: {
                    Text("\(peak.id) (\(SessionUsagePricing.tokens(measured(peak.counts))) tokens · \(peak.costLabel))")
                        .font(COSType.body(12, weight: .medium)).monospacedDigit().underline()
                }
                .buttonStyle(.plain)
                .help("Inspect \(peak.id) in the period breakdown.")
            }
        }
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
            HStack {
                Toggle("Exclude cache reads", isOn: $excludeCacheReads).toggleStyle(COSCheckStyle())
                    .help("Compare input, output and cache writes without repeated cache reads. Changes chart tokens, token mix and table shares, not API value.")
                Spacer()
                Text("Hover or inspect a period for its breakdown").font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
            }
            if measure == .cost && !chartRows.isEmpty && chartRows.allSatisfy({ $0.pricedEvents == 0 }) {
                Text("Cost unavailable: no verified prices for this selection.").frame(maxWidth: .infinity, minHeight: 220).foregroundStyle(.secondary)
            } else if points.isEmpty {
                Text("No recorded usage for this selection. A missing provider is not zero usage.").frame(maxWidth: .infinity, minHeight: 220).foregroundStyle(.secondary)
            } else {
                SessionUsageChart(points: points, rows: chartRows, scale: timeScale, measure: measure,
                    excludeCacheReads: excludeCacheReads, timeZone: reportingZone, inspectedPeriod: $inspectedPeriod, lineChart: lineChart).zIndex(2)
                if timeScale == .monthly {
                    Text("Monthly buckets include only selected dates; boundary months may be partial.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                } else if timeScale == .weekly {
                    Text("Weekly buckets group recorded dates by Monday–Sunday in \(reportingZone.identifier); boundary weeks may be partial.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                }
                if seriesMode == .models {
                    Text("The six largest models by selected tokens are shown separately; remaining models are combined.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                } else if seriesMode == .categories && measure == .records {
                    Text("Usage records apply to whole turns rather than single token categories; showing provider records.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                } else if seriesMode == .categories && measure == .cost {
                    Text("Category API value allocates each priced model's rate across uncached input, output, cache read and cache write.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                }
                Text(lineChart ? "Lines connect recorded dates only; missing dates are not zero usage." : "Stacked bars show recorded dates only; missing dates are not zero usage.")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                if measure == .cost && chartRows.contains(where: { $0.pricedEvents < $0.events }) {
                    Text("API values include priced records only. Unpriced provider/model periods are omitted; partial values exclude unknown costs.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                }
                periodInspector.zIndex(1)
            }
        }
    }

    private var chartControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                COSViewSwitch("Time scale", selection: $timeScale, options: [
                    COSViewOption(.daily, "Daily"),
                    COSViewOption(.weekly, "Weekly"),
                    COSViewOption(.monthly, "Monthly")
                ])
                COSViewSwitch("Measure", selection: $measure, options: [
                    COSViewOption(.tokens, "Tokens"),
                    COSViewOption(.cost, "API value"),
                    COSViewOption(.records, "Records")
                ])
            }
            HStack {
                COSViewSwitch("Series", selection: $seriesMode, options: [
                    COSViewOption(.providers, "Providers"),
                    COSViewOption(.models, "Models"),
                    COSViewOption(.categories, "Categories")
                ])
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
                ForEach(SessionUsagePresentation.summarize(selected, by: \.provider, excludingCacheReads: excludeCacheReads)) { row in
                    let isSelected = provider == row.id
                    let denom = measured(counts)
                    let num = measured(row.counts)
                    GridRow {
                        Button {
                            if provider == row.id {
                                provider = "All providers"
                                model = "All models"
                            } else {
                                provider = row.id
                                model = "All models"
                            }
                        } label: {
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
                            Text(SessionUsagePresentation.share(num, of: denom)).frame(width: 48, alignment: .leading)
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
        let categories = SessionUsagePresentation.tokenMix(counts, excludingCacheReads: excludeCacheReads, rows: selected)
        let costCategories = SessionUsagePresentation.costMix(selected, counts: counts)
        let denom = measured(counts)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(excludeCacheReads ? "Token mix · cache reads excluded" : "Token mix · all recorded tokens")
                    .font(COSType.body(16, weight: .semibold))
                Spacer()
                Button {
                    seriesMode = seriesMode == .categories ? .providers : .categories
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
                        Text(SessionUsagePresentation.share(category.count, of: denom) + " of tokens")
                            .font(COSType.body(12)).foregroundStyle(COSPalette.subtle).monospacedDigit()
                        if priced > 0 {
                            Text(category.estimatedUSD.formatted(.currency(code: "USD")) + " (" + SessionUsagePresentation.costShare(category.estimatedUSD, of: cost) + " of API value)")
                                .font(COSType.body(11)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if denom > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text("Tokens").font(COSType.body(11, weight: .medium)).foregroundStyle(COSPalette.subtle).frame(width: 68, alignment: .leading)
                        stackedMixBar(items: categories.map { ($0.id, denom > 0 ? Double($0.count) / Double(denom) : 0) })
                    }
                    if priced > 0 && cost > 0 {
                        HStack(spacing: 10) {
                            Text("API value").font(COSType.body(11, weight: .medium)).foregroundStyle(COSPalette.subtle).frame(width: 68, alignment: .leading)
                            stackedMixBar(items: costCategories.map { ($0.id, cost > 0 ? $0.estimatedUSD / cost : 0) })
                        }
                    }
                }.padding(.top, 2)
            }
            Text("Disjoint categories; reasoning is included in output. Shares use the displayed token total. Cache reads are repeated context, not cache savings.")
                .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
        }
    }

    private func stackedMixBar(items: [(String, Double)]) -> some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(items.filter { $0.1 > 0 }, id: \.0) { item in
                    Rectangle()
                        .fill(SessionUsageChart.seriesColor(item.0))
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, max(0, item.1)))))
                        .help("\(item.0): \(String(format: "%.1f%%", item.1 * 100))")
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

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Models · \(month)").font(COSType.body(16, weight: .semibold))
                    Spacer()
                    modelSortControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Models · \(month)").font(COSType.body(16, weight: .semibold))
                    modelSortControls
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow {
                    Text("Provider / model")
                    Text(excludeCacheReads ? "Without cache reads" : "All tokens")
                    Text("Selection share").help("Share of tokens across the selected period, provider and model. Never your subscription allowance.")
                    Text("Within provider").help("Share of this provider's tokens across all its models in the selected period.")
                    Text("Usage records")
                    Text("Cache read %").help("Share of this model's all recorded tokens that were cache reads.")
                    Text("Estimated API value")
                }.font(COSType.body(12, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(ranking) { row in
                    let isFiltered = model == row.model && (provider == "All providers" || provider == row.provider)
                    let rowTokens = measured(row.counts)
                    let totalTokens = measured(counts)
                    GridRow {
                        Button {
                            if model == row.model {
                                model = "All models"
                            } else {
                                provider = row.provider
                                model = row.model
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(row.model).fontWeight(isFiltered ? .semibold : .regular)
                                    if isFiltered {
                                        Text("Filtered").font(COSType.body(10, weight: .semibold)).foregroundStyle(COSPalette.gold)
                                    }
                                }
                                Text(row.provider).font(COSType.body(11)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isFiltered ? "Clear \(row.model) filter" : "Filter Usage by \(row.provider) · \(row.model)")
                        Text(SessionUsagePricing.tokens(rowTokens)).monospacedDigit()
                        Text(SessionUsagePresentation.share(rowTokens, of: totalTokens)).monospacedDigit()
                        Text(SessionUsagePresentation.share(rowTokens, of: periodRows.filter { $0.provider == row.provider }.reduce(0) { $0 + measured($1.counts) })).monospacedDigit()
                            .help("Share of recorded \(row.provider) tokens; all models in \(month).")
                        Text(row.events.formatted()).monospacedDigit()
                        Text(SessionUsagePresentation.share(row.counts.cacheRead, of: row.counts.total)).monospacedDigit()
                        Text(row.pricedEvents == 0 ? "Unavailable" : row.estimatedUSD.formatted(.currency(code: "USD")) + (row.pricedEvents < row.events ? " + unknown" : "")).monospacedDigit()
                    }
                    Divider()
                }
            }.font(COSType.body(13))
        }
    }

    private var modelSortControls: some View {
        HStack(spacing: 12) {
            COSViewSwitch("Sort models", selection: $modelSort, options: SessionUsageModelSort.allCases.map { COSViewOption($0, $0.rawValue) })
            Button {
                modelSortAscending.toggle()
            } label: {
                Label(modelSortAscending ? "Ascending" : "Descending", systemImage: modelSortAscending ? "arrow.up" : "arrow.down")
                    .font(COSType.body(11))
            }.buttonStyle(.plain).foregroundStyle(COSPalette.subtle)
        }
    }

    private var dayBreakdown: some View {
        DisclosureGroup("Daily breakdown · \(Set(selected.map(\.day)).count) recorded days", isExpanded: $dayBreakdownExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    COSViewSwitch("Sort days", selection: $daySort, options: SessionUsageDaySort.allCases.map { COSViewOption($0, $0.rawValue) })
                    Button {
                        daySortAscending.toggle()
                    } label: {
                        Label(daySortAscending ? "Ascending" : "Descending", systemImage: daySortAscending ? "arrow.up" : "arrow.down")
                            .font(COSType.body(11))
                    }.buttonStyle(.plain).foregroundStyle(COSPalette.subtle)
                    Spacer()
                    Text("Click a day to inspect its breakdown").font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                }.padding(.bottom, 4)
                ForEach(sortedDays) { row in
                    let isInspected = timeScale == .daily && inspectedPeriod == row.id
                    let rowTokens = measured(row.counts)
                    let totalTokens = measured(counts)
                    Button {
                        if timeScale == .daily && inspectedPeriod == row.id {
                            inspectedPeriod = nil
                        } else {
                            timeScale = .daily
                            inspectedPeriod = row.id
                        }
                    } label: {
                        HStack {
                            Text(row.id).fontWeight(isInspected ? .semibold : .regular)
                            if isInspected {
                                Text("Inspecting").font(COSType.body(10, weight: .semibold)).foregroundStyle(COSPalette.gold)
                            }
                            Spacer()
                            Text(SessionUsagePricing.tokens(rowTokens) + " tokens")
                            Text(SessionUsagePresentation.share(rowTokens, of: totalTokens))
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
                COSDropdown("Inspect period", selection: Binding(get: { inspectedPeriod ?? "" }, set: { inspectedPeriod = $0.isEmpty ? nil : $0 }),
                    options: [COSDropdownOption("", "Choose a period")] + periodKeys.map { COSDropdownOption($0, periodTitle($0)) })
                    .frame(maxWidth: 410)
                if inspectedPeriod != nil {
                    Button("Previous", systemImage: "chevron.left") { moveInspection(-1) }
                        .disabled(inspectedPeriod == periodKeys.first)
                    Button("Next", systemImage: "chevron.right") { moveInspection(1) }
                        .disabled(inspectedPeriod == periodKeys.last)
                    Button("Close", systemImage: "xmark") { inspectedPeriod = nil }
                }
            }
            if let key = inspectedPeriod, periodKeys.contains(key) {
                SessionUsagePeriodDetail(title: periodTitle(key), rows: periodValues(key), excludingCacheReads: excludeCacheReads, compact: false)
                    .padding(16).background(COSPalette.raised, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func moveInspection(_ delta: Int) {
        guard let key = inspectedPeriod, let index = periodKeys.firstIndex(of: key) else { return }
        let next = index + delta
        if periodKeys.indices.contains(next) { inspectedPeriod = periodKeys[next] }
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
    let points: [SessionUsageView.Point]
    let rows: [SessionUsageBucket]
    let scale: SessionUsageTimeScale
    let measure: SessionUsageMeasure
    let excludeCacheReads: Bool
    let timeZone: TimeZone
    let lineChart: Bool
    @Binding var inspectedPeriod: String?
    @State private var hoveredPeriod: String?
    @State private var hoverX: CGFloat = 0

    init(points: [SessionUsageView.Point], rows: [SessionUsageBucket], scale: SessionUsageTimeScale, measure: SessionUsageMeasure,
         excludeCacheReads: Bool, timeZone: TimeZone, inspectedPeriod: Binding<String?>, initialHover: String? = nil, lineChart: Bool = false) {
        self.points = points; self.rows = rows; self.scale = scale; self.measure = measure
        self.excludeCacheReads = excludeCacheReads; self.timeZone = timeZone; self._inspectedPeriod = inspectedPeriod
        self._hoveredPeriod = State(initialValue: initialHover)
        self.lineChart = lineChart
    }

    init(points: [SessionUsageView.Point], rows: [SessionUsageBucket], monthly: Bool, costChart: Bool,
         excludeCacheReads: Bool, timeZone: TimeZone, inspectedPeriod: Binding<String?>, initialHover: String? = nil, lineChart: Bool = false) {
        self.init(points: points, rows: rows, scale: monthly ? .monthly : .daily, measure: costChart ? .cost : .tokens,
            excludeCacheReads: excludeCacheReads, timeZone: timeZone, inspectedPeriod: inspectedPeriod, initialHover: initialHover, lineChart: lineChart)
    }

    private var reportingCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = 2
        return c
    }
    private var dateFormatter: DateFormatter { SessionUsagePresentation.dayFormatter(timeZone: timeZone) }
    private var periodKeys: [String] {
        Array(Set(rows.map { SessionUsagePresentation.periodKey(for: $0.day, scale: scale, timeZone: timeZone) })).sorted()
    }
    private func periodValues(_ key: String) -> [SessionUsageBucket] {
        rows.filter { SessionUsagePresentation.periodKey(for: $0.day, scale: scale, timeZone: timeZone) == key }
    }
    private func periodTitle(_ key: String) -> String {
        SessionUsagePresentation.periodTitle(for: key, scale: scale, timeZone: timeZone)
    }

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
                        .accessibilityLabel("\(dateFormatter.string(from: point.date)), \(point.series)")
                        .accessibilityValue(accessibleValue(point))
                } else {
                    BarMark(x: .value("Date", point.date, unit: calendarUnit),
                        y: .value(yValueLabel, value(point)))
                        .foregroundStyle(by: .value("Series", point.series))
                        .accessibilityLabel("\(dateFormatter.string(from: point.date)), \(point.series)")
                        .accessibilityValue(accessibleValue(point))
                }
            }
            if let key = hoveredPeriod ?? inspectedPeriod,
               let date = dateFormatter.date(from: key.count == 7 ? key + "-01" : key) {
                RuleMark(x: .value("Inspect", date, unit: calendarUnit))
                    .foregroundStyle(COSPalette.subtle.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: periodKeys) { _, _ in hoveredPeriod = nil }
        .environment(\.calendar, reportingCalendar)
        .environment(\.timeZone, timeZone)
        .chartForegroundStyleScale(domain: seriesNames, range: seriesNames.map { Self.seriesColor($0) })
        .chartYAxisLabel(yAxisLabel)
        .frame(height: 270)
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
                                    let day = dateFormatter.string(from: date)
                                    let key = SessionUsagePresentation.periodKey(for: day, scale: scale, timeZone: timeZone)
                                    hoveredPeriod = periodKeys.contains(key) ? key : nil
                                    hoverX = location.x
                                case .ended: hoveredPeriod = nil
                                }
                            }
                            .onTapGesture { if let key = hoveredPeriod { inspectedPeriod = key } }
                            .accessibilityHidden(true)
                        if let key = hoveredPeriod {
                            let width = min(CGFloat(390), geometry.size.width - 16)
                            let placeLeft = hoverX > plot.midX && (hoverX - width - 18) >= 8
                            let cardX = placeLeft
                                ? max(8, hoverX - width - 18)
                                : max(8, min(hoverX + 18, geometry.size.width - width - 16))
                            SessionUsagePeriodDetail(title: periodTitle(key), rows: periodValues(key), excludingCacheReads: excludeCacheReads, compact: true)
                                .frame(width: width).fixedSize(horizontal: false, vertical: true)
                                .padding(14).background(COSPalette.card, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.border))
                                .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
                                .offset(x: cardX, y: 8)
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
    let compact: Bool
    private var counts: SessionUsageCounts { rows.reduce(SessionUsageCounts()) { $0 + $1.counts } }
    private var models: [SessionUsageBucket] { SessionUsagePresentation.aggregate(rows, excludingCacheReads: excludingCacheReads) }
    private var categories: [SessionUsagePresentation.TokenCategory] {
        SessionUsagePresentation.tokenMix(counts, excludingCacheReads: false, rows: rows)
    }
    private func tokens(_ counts: SessionUsageCounts) -> String { SessionUsagePricing.tokens(SessionUsagePresentation.tokenCount(counts, excludingCacheReads: excludingCacheReads)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(COSType.body(14, weight: .semibold))
            HStack {
                Text(tokens(counts) + " tokens").font(COSType.body(18, weight: .semibold)).monospacedDigit()
                    .help(SessionUsagePresentation.tokenCount(counts, excludingCacheReads: excludingCacheReads).formatted() + " tokens")
                Spacer()
                Text(SessionUsagePresentation.costLabel(rows)).font(COSType.body(13, weight: .semibold)).monospacedDigit()
            }
            Text(excludingCacheReads ? "Cache reads excluded from token totals. API value includes all priced tokens." : "All token categories included. Estimated API value, not your bill.")
                .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
            Text("\(rows.reduce(0) { $0 + $1.events }.formatted()) usage records · \(rows.reduce(0) { $0 + $1.pricedEvents }.formatted()) priced").foregroundStyle(COSPalette.subtle)
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
            ForEach(compact ? Array(models.prefix(6)) : models) { row in
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
            if compact && models.count > 6 {
                Text("\(models.count - 6) more models included. Click the chart for all models.").font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
            }
            Divider()
            Text("Input \(SessionUsagePricing.tokens(counts.input))  ·  Output \(SessionUsagePricing.tokens(counts.output))")
            Text("Cache read \(SessionUsagePricing.tokens(counts.cacheRead))  ·  Cache write \(SessionUsagePricing.tokens(counts.cacheWrite))")
            if !compact, rows.contains(where: { $0.pricedEvents > 0 }) {
                HStack(spacing: 12) {
                    ForEach(categories) { cat in
                        Text("\(cat.id): \(cat.estimatedUSD.formatted(.currency(code: "USD")))")
                            .font(COSType.body(11)).foregroundStyle(COSPalette.subtle).monospacedDigit()
                    }
                }
            }
            if compact { Text("Click to keep this breakdown open").foregroundStyle(COSPalette.subtle) }
        }.font(COSType.body(11)).foregroundStyle(.primary)
    }
}
