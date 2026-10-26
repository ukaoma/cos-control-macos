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
    @State private var month = Self.monthKey(Date())
    @State private var provider = "All providers"
    @State private var model = "All models"
    @State private var monthly = false
    @State private var costChart = false
    @State private var selectedDate: Date?
    init(store: SessionUsageStore, initialPeriod: String? = nil) {
        self.store = store
        _month = State(initialValue: initialPeriod ?? Self.monthKey(Date()))
        _monthly = State(initialValue: initialPeriod == "All history")
    }
    private static func monthKey(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.dateFormat = "yyyy-MM"; return f.string(from:date)
    }
    private var buckets: [SessionUsageBucket] { store.report?.buckets ?? [] }
    private var providers: [String] { Array(Set(buckets.map(\.provider))).sorted() }
    private var models: [String] { Array(Set(buckets.filter { provider == "All providers" || $0.provider == provider }.map(\.model))).sorted() }
    private var months: [String] { Array(Set(buckets.map { String($0.day.prefix(7)) } + [Self.monthKey(Date())])).sorted(by: >) }
    private var filtered: [SessionUsageBucket] {
        buckets.filter { (provider == "All providers" || $0.provider == provider) && (model == "All models" || $0.model == model) }
    }
    private var selected: [SessionUsageBucket] { filtered.filter { month == "All history" || $0.day.hasPrefix(month) } }
    private var counts: SessionUsageCounts { selected.reduce(SessionUsageCounts()) { $0+$1.counts } }
    private var unpriced: Int { selected.reduce(0) { $0+$1.events-$1.pricedEvents } }
    private var priced: Int { selected.reduce(0) { $0+$1.pricedEvents } }
    private var cost: Double { selected.reduce(0) { $0+$1.estimatedUSD } }
    private var dateFormatter: DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier:"en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier:store.report?.timeZone ?? "") ?? .current
        return f
    }
    private var ranking: [SessionUsageBucket] {
        Dictionary(grouping:selected, by: { $0.provider+"|"+$0.model }).values.compactMap { group in
            guard let first = group.first else { return nil }
            return SessionUsageBucket(day:month,provider:first.provider,model:first.model,counts:group.reduce(SessionUsageCounts()){$0+$1.counts},events:group.reduce(0){$0+$1.events},pricedEvents:group.reduce(0){$0+$1.pricedEvents},estimatedUSD:group.reduce(0){$0+$1.estimatedUSD})
        }.sorted { $0.counts.total == $1.counts.total ? $0.id < $1.id : $0.counts.total > $1.counts.total }
    }
    struct Point: Identifiable {
        var date: Date; var series: String; var tokens: Int64; var usd: Double
        var id: String { String(date.timeIntervalSince1970)+series }
    }
    private var points: [Point] {
        let rows: [SessionUsageBucket] = monthly ? filtered : selected
        var modelTotals: [String: Int64] = [:]
        for row in rows { modelTotals[row.model, default: 0] += row.counts.total }
        let orderedModels = modelTotals.keys.sorted { a, b in
            let left = modelTotals[a, default: 0], right = modelTotals[b, default: 0]
            if left == right { return a < b }
            return left > right
        }
        let top = Set(orderedModels.prefix(6))
        var grouped: [String: [SessionUsageBucket]] = [:]
        for row in rows {
            let day = monthly ? String(row.day.prefix(7)) + "-01" : row.day
            let series = top.contains(row.model) ? row.model : "Other models"
            grouped[day + "|" + series, default: []].append(row)
        }
        var result: [Point] = []
        let formatter = dateFormatter
        for (key, group) in grouped {
            let parts = key.split(separator:"|",maxSplits:1)
            guard parts.count == 2, let date = formatter.date(from: String(parts[0])) else { continue }
            let tokens = group.reduce(Int64(0)) { $0 + $1.counts.total }
            let usd = group.reduce(0.0) { $0 + $1.estimatedUSD }
            result.append(Point(date: date, series: String(parts[1]), tokens: tokens, usd: usd))
        }
        return result.sorted { a, b in
            if a.date == b.date { return a.series < b.series }
            return a.date < b.date
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                HStack {
                    Picker("Period",selection:$month) { Text("All history").tag("All history"); ForEach(months,id:\.self) { Text($0).tag($0) } }.frame(width:180)
                    Picker("Provider",selection:$provider) { Text("All providers").tag("All providers"); ForEach(providers,id:\.self){ Text($0).tag($0) } }.frame(maxWidth:230)
                    Picker("Model",selection:$model) { Text("All models").tag("All models"); ForEach(models,id:\.self){ Text($0).tag($0) } }.frame(maxWidth:290)
                    Spacer()
                    Button { Task { await store.refresh() } } label: { Label("Refresh",systemImage:"arrow.clockwise") }.disabled(store.loading)
                }
                .onChange(of:provider) { _,_ in model = "All models" }
                .onChange(of:month) { _, value in if value == "All history" { monthly = true } }
                if let earliest = buckets.map(\.day).min(), let latest = buckets.map(\.day).max() {
                    Text("Recorded history: \(earliest) – \(latest). Select All history for lifetime totals, or a month to compare models.")
                        .font(COSType.body(12)).foregroundStyle(.secondary)
                }
                HStack(alignment:.top,spacing:28) {
                    metric("Tokens processed",SessionUsagePricing.tokens(counts.total))
                    metric("Input / output",SessionUsagePricing.tokens(counts.input)+" / "+SessionUsagePricing.tokens(counts.output))
                    metric("Cache read / write",SessionUsagePricing.tokens(counts.cacheRead)+" / "+SessionUsagePricing.tokens(counts.cacheWrite))
                    metric("Estimated API value",priced == 0 ? "Unavailable" : cost.formatted(.currency(code:"USD")) + (unpriced > 0 ? " + unknown" : ""))
                }
                Text("Standard API-equivalent estimate, not your subscription bill. Rates checked October 25, 2026 and applied to all dates. Discounts, speed tiers, tools and taxes are excluded.")
                    .font(COSType.body(12)).foregroundStyle(.secondary)
                if store.loading { ProgressView(store.report == nil ? "Reading local usage…" : "Updating usage history…").controlSize(.small) }
                if let error = store.error { Text(error).foregroundStyle(.red) }
                if let report = store.report, report.pendingFiles > 0 {
                    Text("Backfilling history: \(report.pendingFiles) files remaining. Totals are partial and update as the import continues.").foregroundStyle(.secondary)
                }
                HStack {
                    Text(monthly ? "Usage over time" : "Daily usage · \(month)").font(COSType.body(16,weight:.semibold))
                    Spacer()
                    Picker("Time scale",selection:$monthly) { Text("Daily").tag(false); Text("Monthly history").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width:240)
                    Picker("Measure",selection:$costChart) { Text("Tokens").tag(false); Text("Est. USD").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width:160)
                }
                if costChart && (monthly ? filtered : selected).allSatisfy({ $0.pricedEvents == 0 }) {
                    Text("Cost unavailable: no verified prices for this selection.").frame(maxWidth:.infinity,minHeight:220).foregroundStyle(.secondary)
                } else if points.isEmpty {
                    Text("No recorded usage for this selection. A missing provider is not zero usage.").frame(maxWidth:.infinity,minHeight:220).foregroundStyle(.secondary)
                } else {
                    Chart(points) { point in
                        BarMark(x:.value("Date",point.date,unit:monthly ? .month : .day), y:.value(costChart ? "Estimated USD" : "Million tokens",costChart ? point.usd : Double(point.tokens)/1e6))
                            .foregroundStyle(by:.value("Model",point.series))
                            .accessibilityLabel("\(dateFormatter.string(from:point.date)), \(point.series)")
                            .accessibilityValue(costChart ? point.usd.formatted(.currency(code:"USD")) : SessionUsagePricing.tokens(point.tokens)+" tokens")
                    }
                    .chartXSelection(value:$selectedDate)
                    .chartYAxisLabel(costChart ? "Estimated USD (priced usage only)" : "Million tokens")
                    .frame(height:245)
                    if let date = selectedDate {
                        let key = String(dateFormatter.string(from:date).prefix(monthly ? 7 : 10))
                        let values = (monthly ? filtered : selected).filter { $0.day.hasPrefix(key) }
                        Text("\(key): \(SessionUsagePricing.tokens(values.reduce(0){$0+$1.counts.total})) tokens · \(values.reduce(0){$0+$1.estimatedUSD}.formatted(.currency(code:"USD"))) priced API value").font(COSType.body(12))
                    }
                }
                Text("Models · \(month)").font(COSType.body(16,weight:.semibold))
                Grid(alignment:.leading,horizontalSpacing:24,verticalSpacing:12) {
                    GridRow { Text("Provider / model"); Text("Tokens"); Text("Share"); Text("Estimated API value") }.font(COSType.body(12,weight:.semibold)).foregroundStyle(.secondary)
                    ForEach(ranking) { row in
                        GridRow {
                            VStack(alignment:.leading,spacing:3) { Text(row.model); Text(row.provider).font(COSType.body(11)).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,alignment:.leading)
                            Text(SessionUsagePricing.tokens(row.counts.total)).monospacedDigit()
                            Text(counts.total > 0 ? String(format:"%.1f%%",100*Double(row.counts.total)/Double(counts.total)) : "0%").monospacedDigit()
                            Text(row.pricedEvents == 0 ? "Unavailable" : row.estimatedUSD.formatted(.currency(code:"USD")) + (row.pricedEvents < row.events ? " + unknown" : "")).monospacedDigit()
                        }
                        Divider()
                    }
                }.font(COSType.body(13))
                Divider()
                Toggle("Track session usage on this Mac",isOn:$store.enabled)
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
    private func metric(_ label: String,_ value: String) -> some View {
        VStack(alignment:.leading,spacing:6) { Text(value).font(COSType.body(22,weight:.semibold)).monospacedDigit(); Text(label).font(COSType.body(12)).foregroundStyle(.secondary) }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
