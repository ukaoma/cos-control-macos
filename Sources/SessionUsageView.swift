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
    @State private var providerSeries = true
    @State private var lineChart = true
    @State private var provider = "All providers"
    @State private var model = "All models"
    @State private var monthly = false
    @State private var costChart = false
    @State private var excludeCacheReads = false
    @State private var inspectedPeriod: String?
    @State private var dayBreakdownExpanded = false
    init(store: SessionUsageStore, initialPeriod: String? = nil, initialInspection: String? = nil,
         initialDates: (Date, Date)? = nil, initialCostChart: Bool = false,
         initialExcludeCacheReads: Bool = false, initialDayBreakdownExpanded: Bool = false) {
        self.store = store
        _month = State(initialValue: initialPeriod ?? "Last 30 days")
        _monthly = State(initialValue: initialPeriod == "All history")
        _inspectedPeriod = State(initialValue: initialInspection)
        if let initialDates {
            _customStart = State(initialValue: initialDates.0)
            _customEnd = State(initialValue: initialDates.1)
        }
        _costChart = State(initialValue: initialCostChart)
        _excludeCacheReads = State(initialValue: initialExcludeCacheReads)
        _dayBreakdownExpanded = State(initialValue: initialDayBreakdownExpanded)
    }
    private static func monthKey(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.dateFormat = "yyyy-MM"; return f.string(from:date)
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
    private var periodKeys: [String] { Array(Set(chartRows.map { String($0.day.prefix(monthly ? 7 : 10)) })).sorted() }
    private func measured(_ counts: SessionUsageCounts) -> Int64 { SessionUsagePresentation.tokenCount(counts, excludingCacheReads: excludeCacheReads) }
    private func periodValues(_ key: String) -> [SessionUsageBucket] { chartRows.filter { $0.day.hasPrefix(key) } }
    private func periodTitle(_ key: String) -> String {
        guard let date = dateFormatter.date(from: key.count == 7 ? key + "-01" : key) else { return key }
        let f = DateFormatter(); f.timeZone = reportingZone; f.dateFormat = monthly ? "MMMM yyyy" : "EEEE, MMM d, yyyy"
        return f.string(from: date)
    }
    private var counts: SessionUsageCounts { selected.reduce(SessionUsageCounts()) { $0+$1.counts } }
    private var unpriced: Int { selected.reduce(0) { $0+$1.events-$1.pricedEvents } }
    private var priced: Int { selected.reduce(0) { $0+$1.pricedEvents } }
    private var cost: Double { selected.reduce(0) { $0+$1.estimatedUSD } }
    private var dateFormatter: DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = reportingZone
        return f
    }
    private var ranking: [SessionUsageBucket] { SessionUsagePresentation.aggregate(selected, excludingCacheReads: excludeCacheReads) }
    struct Point: Identifiable {
        var date: Date; var series: String; var tokens: Int64; var usd: Double
        var pricedEvents: Int = 1
        var events: Int = 1
        var id: String { String(date.timeIntervalSince1970)+series }
    }
    private var points: [Point] {
        let rows = chartRows
        var modelTotals: [String: Int64] = [:]
        for row in rows { modelTotals[row.model, default: 0] += measured(row.counts) }
        let orderedModels = modelTotals.keys.sorted { a, b in
            let left = modelTotals[a, default: 0], right = modelTotals[b, default: 0]
            if left == right { return a < b }
            return left > right
        }
        let top = Set(orderedModels.prefix(6))
        var grouped: [String: [SessionUsageBucket]] = [:]
        for row in rows {
            let day = monthly ? String(row.day.prefix(7)) + "-01" : row.day
            let series = providerSeries ? row.provider : top.contains(row.model) ? row.model : "Other models"
            grouped[day + "|" + series, default: []].append(row)
        }
        var result: [Point] = []
        let formatter = dateFormatter
        for (key, group) in grouped {
            let parts = key.split(separator:"|",maxSplits:1)
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
            VStack(alignment:.leading,spacing:18) {
                HStack(alignment:.bottom,spacing:12) {
                    filter("Period",selection:$month,values:["Last 7 days", "Last 30 days", "Last 90 days", "Last weekend", "Custom dates", "All history"]+months).frame(width:150)
                    filter("Provider",selection:$provider,values:["All providers"]+providers).frame(maxWidth:190)
                    filter("Model",selection:$model,values:["All models"]+models).frame(maxWidth:290)
                    Spacer()
                    Button { Task { await store.refresh() } } label: { Label("Refresh",systemImage:"arrow.clockwise") }.disabled(store.loading)
                }
                .onChange(of:provider) { _,_ in model = "All models" }
                .onChange(of:month) { _, value in monthly = value == "All history"; clearInspection() }
                .onChange(of:provider) { _, _ in clearInspection() }
                .onChange(of:model) { _, _ in clearInspection() }
                .onChange(of:monthly) { _, _ in clearInspection() }
                .onChange(of:periodKeys) { _, keys in
                    if let inspectedPeriod, !keys.contains(inspectedPeriod) { clearInspection() }
                }
                .onChange(of:customStart) { _, _ in clearInspection() }
                .onChange(of:customEnd) { _, _ in clearInspection() }
                if month == "Custom dates" { customDates }
                Text("Calendar dates in \(reportingZone.identifier). Includes today for Last 7/30/90 days. Daily records cannot resolve a rolling 24-hour window.")
                    .font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
                if let earliest = buckets.map(\.day).min(), let latest = buckets.map(\.day).max() {
                    Text("Recorded history: \(earliest) – \(latest). All totals, charts and breakdowns follow the selected period and filters.")
                        .font(COSType.body(12)).foregroundStyle(.secondary)
                }
                HStack(alignment:.top,spacing:28) {
                    metric("All recorded tokens",SessionUsagePricing.tokens(counts.total))
                    metric("Usage records",selected.reduce(0) { $0 + $1.events }.formatted())
                    metric("Recorded days",Set(selected.map(\.day)).count.formatted())
                    metric("Estimated API value",priced == 0 ? "Unavailable" : cost.formatted(.currency(code:"USD")) + (unpriced > 0 ? " + unknown" : ""))
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
                Text("Models · \(month)").font(COSType.body(16,weight:.semibold))
                Grid(alignment:.leading,horizontalSpacing:24,verticalSpacing:12) {
                    GridRow {
                        Text("Provider / model")
                        Text(excludeCacheReads ? "Without cache reads" : "All tokens")
                        Text("Selection share").help("Share of tokens across the selected period, provider and model. Never your subscription allowance.")
                        Text("Within provider").help("Share of this provider's tokens across all its models in the selected period.")
                        Text("Estimated API value")
                    }.font(COSType.body(12,weight:.semibold)).foregroundStyle(.secondary)
                    ForEach(ranking) { row in
                        GridRow {
                            VStack(alignment:.leading,spacing:3) { Text(row.model); Text(row.provider).font(COSType.body(11)).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,alignment:.leading)
                            Text(SessionUsagePricing.tokens(measured(row.counts))).monospacedDigit()
                            Text(SessionUsagePresentation.share(measured(row.counts), of: measured(counts))).monospacedDigit()
                            Text(SessionUsagePresentation.share(measured(row.counts), of: periodRows.filter { $0.provider == row.provider }.reduce(0) { $0 + measured($1.counts) })).monospacedDigit()
                                .help("Share of recorded \(row.provider) tokens; all models in \(month).")
                            Text(row.pricedEvents == 0 ? "Unavailable" : row.estimatedUSD.formatted(.currency(code:"USD")) + (row.pricedEvents < row.events ? " + unknown" : "")).monospacedDigit()
                        }
                        Divider()
                    }
                }.font(COSType.body(13))
                dayBreakdown
                Divider()
                Toggle("Track session usage on this Mac",isOn:$store.enabled).toggleStyle(COSCheckStyle())
                Text("While COS Control is running, it refreshes local history every five minutes. Pausing keeps existing history. Manual Refresh imports available records. Only counts, dates, model names and local file checkpoints are stored; nothing is uploaded.").font(COSType.body(12)).foregroundStyle(.secondary)
                if let report = store.report {
                    Text("\(report.filesIndexed) files indexed · Time zone: \(report.timeZone) · Updated \(report.updatedAt)").font(COSType.mono(10)).foregroundStyle(.secondary)
                    ForEach(report.coverage,id:\.self) { Text($0).font(COSType.body(12)).foregroundStyle(.secondary) }
                    if report.unreadableFiles+report.malformedRows+report.missingBaselineEvents > 0 {
                        Text("Coverage gaps: \(report.unreadableFiles) unreadable files / oversized rows, \(report.malformedRows) malformed rows, \(report.missingBaselineEvents) missing usage baselines. Totals reflect available evidence.").font(COSType.body(12)).foregroundStyle(.orange)
                    }
                    if unpriced > 0 { Text("\(unpriced) usage records have no verified price. Their tokens are included; their cost is unknown.").font(COSType.body(12)).foregroundStyle(.secondary) }
                }
                HStack { Link("Anthropic pricing",destination:URL(string:SessionUsagePricing.sources[0])!); Link("OpenAI pricing",destination:URL(string:SessionUsagePricing.sources[1])!) }.font(COSType.body(12))
            }.padding(22)
        }
        .task { if store.report == nil { await store.refresh(importNew: store.enabled) } }
    }
    private func clearInspection() { inspectedPeriod = nil }
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(monthly ? "Monthly usage" : "Daily usage").font(COSType.body(16, weight: .semibold))
                    Spacer()
                    chartControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(monthly ? "Monthly usage" : "Daily usage").font(COSType.body(16, weight: .semibold))
                    chartControls
                }
            }
            HStack {
                Toggle("Exclude cache reads", isOn: $excludeCacheReads).toggleStyle(COSCheckStyle())
                    .help("Compare input, output and cache writes without repeated cache reads. Changes chart tokens, token mix and table shares, not API value.")
                Spacer()
                Text("Hover or inspect a period for its breakdown").font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
            }
            if costChart && !chartRows.isEmpty && chartRows.allSatisfy({ $0.pricedEvents == 0 }) {
                Text("Cost unavailable: no verified prices for this selection.").frame(maxWidth: .infinity, minHeight: 220).foregroundStyle(.secondary)
            } else if points.isEmpty {
                Text("No recorded usage for this selection. A missing provider is not zero usage.").frame(maxWidth: .infinity, minHeight: 220).foregroundStyle(.secondary)
            } else {
                SessionUsageChart(points: points, rows: chartRows, monthly: monthly, costChart: costChart,
                    excludeCacheReads: excludeCacheReads, timeZone: reportingZone, inspectedPeriod: $inspectedPeriod, lineChart: lineChart).zIndex(2)
                if monthly {
                    Text("Monthly buckets include only selected dates; boundary months may be partial.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                }
                if !providerSeries {
                    Text("The six largest models by selected tokens are shown separately; remaining models are combined.")
                        .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                }
                Text(lineChart ? "Lines connect recorded dates only; missing dates are not zero usage." : "Stacked bars show recorded dates only; missing dates are not zero usage.")
                    .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
                if costChart && chartRows.contains(where: { $0.pricedEvents < $0.events }) {
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
                COSViewSwitch("Time scale", selection: $monthly, options: [COSViewOption(false,"Daily"), COSViewOption(true,"Monthly")])
                COSViewSwitch("Measure", selection: $costChart, options: [COSViewOption(false,"Tokens"), COSViewOption(true,"API value")])
            }
            HStack {
                COSViewSwitch("Series", selection: $providerSeries, options: [COSViewOption(true,"Providers"), COSViewOption(false,"Models")])
                COSViewSwitch("Chart style", selection: $lineChart, options: [COSViewOption(true,"Lines"), COSViewOption(false,"Stacked bars")])
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
            Text("Providers · \(month)").font(COSType.body(16, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Text("Provider"); Text(excludeCacheReads ? "Without cache reads" : "All tokens")
                    Text("Selection share"); Text("Usage records"); Text("Estimated API value")
                }.font(COSType.body(12, weight: .semibold)).foregroundStyle(COSPalette.subtle)
                ForEach(SessionUsagePresentation.summarize(selected, by: \.provider, excludingCacheReads: excludeCacheReads)) { row in
                    GridRow {
                        Text(row.id).frame(maxWidth: .infinity, alignment: .leading)
                        Text(SessionUsagePricing.tokens(measured(row.counts)))
                        Text(SessionUsagePresentation.share(measured(row.counts), of: measured(counts)))
                        Text(row.events.formatted()).help("Deduplicated usage observations, not sessions or messages.")
                        Text(row.costLabel)
                    }
                    Divider()
                }
            }.font(COSType.body(13)).monospacedDigit()
        }
    }
    private var tokenMix: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(excludeCacheReads ? "Token mix · cache reads excluded" : "Token mix · all recorded tokens")
                .font(COSType.body(16, weight: .semibold))
            HStack(alignment: .top, spacing: 20) {
                ForEach(SessionUsagePresentation.tokenMix(counts, excludingCacheReads: excludeCacheReads)) { category in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(category.id).font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
                        Text(SessionUsagePricing.tokens(category.count)).font(COSType.body(18, weight: .semibold)).monospacedDigit()
                        Text(SessionUsagePresentation.share(category.count, of: measured(counts))).font(COSType.body(12)).foregroundStyle(COSPalette.subtle)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Disjoint categories; reasoning is included in output. Shares use the displayed token total. Cache reads are repeated context, not cache savings.")
                .font(COSType.body(11)).foregroundStyle(COSPalette.subtle)
        }
    }
    private var dayBreakdown: some View {
        DisclosureGroup("Daily breakdown · \(Set(selected.map(\.day)).count) recorded days", isExpanded: $dayBreakdownExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SessionUsagePresentation.summarize(selected, by: \.day).sorted { $0.id > $1.id }) { row in
                    HStack {
                        Text(row.id)
                        Spacer()
                        Text(SessionUsagePricing.tokens(measured(row.counts)) + " tokens")
                        Text("\(row.events.formatted()) records").foregroundStyle(COSPalette.subtle)
                        Text(row.costLabel).frame(minWidth: 110, alignment: .trailing)
                    }.font(COSType.body(12)).monospacedDigit()
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
    private func metric(_ label: String,_ value: String) -> some View {
        VStack(alignment:.leading,spacing:6) { Text(value).font(COSType.body(22,weight:.semibold)).monospacedDigit(); Text(label).font(COSType.body(12)).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,alignment:.leading)
    }
    private func filter(_ title: String,selection: Binding<String>,values: [String]) -> some View {
        VStack(alignment:.leading,spacing:5) {
            Text(title).font(COSType.body(12)).foregroundStyle(.secondary)
            COSDropdown(title,selection:selection,options:values.map { COSDropdownOption($0,$0) },showsLabel:false)
        }
    }
}


/// Hover updates stay here; moving the pointer never recomputes the report table or imports files.
struct SessionUsageChart: View {
    let points: [SessionUsageView.Point]
    let rows: [SessionUsageBucket]
    let monthly: Bool
    let costChart: Bool
    let excludeCacheReads: Bool
    let timeZone: TimeZone
    let lineChart: Bool
    @Binding var inspectedPeriod: String?
    @State private var hoveredPeriod: String?
    @State private var hoverX: CGFloat = 0
    init(points: [SessionUsageView.Point], rows: [SessionUsageBucket], monthly: Bool, costChart: Bool,
         excludeCacheReads: Bool, timeZone: TimeZone, inspectedPeriod: Binding<String?>, initialHover: String? = nil, lineChart: Bool = false) {
        self.points = points; self.rows = rows; self.monthly = monthly; self.costChart = costChart
        self.excludeCacheReads = excludeCacheReads; self.timeZone = timeZone; self._inspectedPeriod = inspectedPeriod
        self._hoveredPeriod = State(initialValue: initialHover)
        self.lineChart = lineChart
    }
    private var reportingCalendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = timeZone; return c }
    private var dateFormatter: DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = reportingCalendar
        f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd"; return f
    }
    private var periodKeys: [String] { Array(Set(rows.map { String($0.day.prefix(monthly ? 7 : 10)) })).sorted() }
    private func periodValues(_ key: String) -> [SessionUsageBucket] { rows.filter { $0.day.hasPrefix(key) } }
    private func periodTitle(_ key: String) -> String {
        guard let date = dateFormatter.date(from: key.count == 7 ? key + "-01" : key) else { return key }
        let f = DateFormatter(); f.timeZone = timeZone; f.calendar = reportingCalendar; f.dateFormat = monthly ? "MMMM yyyy" : "EEEE, MMM d, yyyy"
        return f.string(from: date)
    }
    private func color(_ name: String) -> Color {
        switch name {
        case "claude-opus-5-5": return Color(red: 0.86, green: 0.43, blue: 0.16)
        case "gpt-6-astra": return Color(red: 0.02, green: 0.59, blue: 0.62)
        case "gpt-6.1-sol": return Color(red: 0.53, green: 0.40, blue: 0.77)
        case "Anthropic": return COSPalette.gold
        case "OpenAI": return Color(red: 0.02, green: 0.59, blue: 0.62)
        case "Ollama": return Color(red: 0.53, green: 0.40, blue: 0.77)
        case "Other models": return .gray
        default:
            let colors: [Color] = [.blue, .green, .pink, .indigo, .brown]
            let index = name.utf8.reduce(0) { ($0 * 31 + Int($1)) % colors.count }
            return colors[index]
        }
    }
    private func value(_ point: SessionUsageView.Point) -> Double { costChart ? point.usd : Double(point.tokens)/1e6 }
    private func accessibleValue(_ point: SessionUsageView.Point) -> String {
        let label = costChart ? point.usd.formatted(.currency(code: "USD")) + (point.pricedEvents < point.events ? " plus unknown cost" : " API value") : SessionUsagePricing.tokens(point.tokens) + " tokens"
        return label + ", \(point.events) usage records"
    }
    private var seriesNames: [String] { Array(Set(points.map(\.series))).sorted() }
    var body: some View {
        Chart {
            ForEach(points.filter { !costChart || $0.pricedEvents > 0 }) { point in
                if lineChart {
                    LineMark(x: .value("Date", point.date, unit: monthly ? .month : .day),
                        y: .value(costChart ? "Estimated USD" : "Million tokens", value(point)))
                        .foregroundStyle(by: .value("Series", point.series))
                        .symbol(.circle)
                        .accessibilityLabel("\(dateFormatter.string(from: point.date)), \(point.series)")
                        .accessibilityValue(accessibleValue(point))
                } else {
                    BarMark(x: .value("Date", point.date, unit: monthly ? .month : .day),
                        y: .value(costChart ? "Estimated USD" : "Million tokens", value(point)))
                        .foregroundStyle(by: .value("Series", point.series))
                        .accessibilityLabel("\(dateFormatter.string(from: point.date)), \(point.series)")
                        .accessibilityValue(accessibleValue(point))
                }
            }
            if let key = hoveredPeriod ?? inspectedPeriod,
               let date = dateFormatter.date(from: key.count == 7 ? key + "-01" : key) {
                RuleMark(x: .value("Inspect", date, unit: monthly ? .month : .day))
                    .foregroundStyle(COSPalette.subtle.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: periodKeys) { _, _ in hoveredPeriod = nil }
        .environment(\.calendar, reportingCalendar)
        .environment(\.timeZone, timeZone)
        .chartForegroundStyleScale(domain: seriesNames, range: seriesNames.map { color($0) })
        .chartYAxisLabel(costChart ? "USD (priced records only)" : excludeCacheReads ? "Million tokens, excluding cache reads" : "Million tokens, including cache reads")
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
                                    let key = String(dateFormatter.string(from: date).prefix(monthly ? 7 : 10))
                                    hoveredPeriod = periodKeys.contains(key) ? key : nil
                                    hoverX = location.x
                                case .ended: hoveredPeriod = nil
                                }
                            }
                            .onTapGesture { if let key = hoveredPeriod { inspectedPeriod = key } }
                            .accessibilityHidden(true)
                        if let key = hoveredPeriod {
                            let width = min(CGFloat(390), geometry.size.width - 16)
                            SessionUsagePeriodDetail(title: periodTitle(key), rows: periodValues(key), excludingCacheReads: excludeCacheReads, compact: true)
                                .frame(width: width).fixedSize(horizontal: false, vertical: true)
                                .padding(14).background(COSPalette.card, in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(COSPalette.border))
                                .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
                                .offset(x: max(8, min(hoverX + 18, geometry.size.width - width - 36)), y: 8)
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
            if compact { Text("Click to keep this breakdown open").foregroundStyle(COSPalette.subtle) }
        }.font(COSType.body(11)).foregroundStyle(.primary)
    }
}
