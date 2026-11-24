import AppKit
import SwiftUI

struct LotterySimulationView: View {
    private enum Mode: String, CaseIterable {
        case comparison = "同预算对照"
        case replay = "逐期复盘"
        case sample = "随机抽样"
    }

    let draws: [LotteryDraw]
    @Environment(\.dismiss) private var dismiss
    @State private var endIssue: String
    @State private var strategy: LotteryBacktest.Strategy
    @State private var ticketCountText = String(LotterySimulation.defaultTicketCount)
    @State private var runID = 0
    @State private var mode = Mode.comparison
    @State private var completed = 0
    @State private var total = 0
    @State private var running = true
    @State private var simulation: LotterySimulation?
    @State private var comparison: LotteryComparison?
    @State private var failure: String?
    @State private var copied = false
    @State private var expandedIssues = Set<String>()
    @State private var isPrizeRulesPresented = false
    @State private var notices: [String: (LotteryDraw, LotteryPrizeAnnouncement)] = [:]

    init(draws: [LotteryDraw], strategy: LotteryBacktest.Strategy) {
        self.draws = draws
        _endIssue = State(initialValue: draws.last?.issue ?? "")
        _strategy = State(initialValue: strategy)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("双色球策略回测").font(.title2.bold())
                Spacer()
                Picker("回测方式", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: mode) { runID += 1 }
                Button("中奖规则") { isPrizeRulesPresented = true }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 10) {
                Text("截止期")
                TextField("最新已开奖期", text: $endIssue)
                    .frame(width: 130)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runID += 1 }
                if mode == .comparison {
                    Text("每种策略每期 10 注 · 20 元").foregroundStyle(.secondary)
                } else {
                    Picker("策略", selection: $strategy) {
                        ForEach(LotteryBacktest.Strategy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: strategy) { runID += 1 }
                    Text("每期注数")
                    TextField("注数", text: $ticketCountText)
                        .accessibilityLabel("每期注数")
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 48)
                        .onSubmit { runID += 1 }
                }
                Button(mode == .sample ? "重新抽样" : "运行回测") { runID += 1 }
                Spacer()
                Button(copied ? "已复制" : "复制回测报告") {
                    guard let report = comparison?.report ?? simulation?.report else { return }
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(report, forType: .string)
                }
                .disabled((simulation == nil && comparison == nil) || running)
            }
            if let comparison {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        benchmarkTable(comparison.benchmark)
                        DisclosureGroup("更多历史统计") {
                            VStack(alignment: .leading, spacing: 20) {
                                comparisonTable(comparison.all, title: "全部可复盘历史")
                                comparisonTable(comparison.recent, title: "最近 \(comparison.recent.periods) 期")
                                if let validation = comparison.validation, let summary = comparison.validationSummary {
                                    comparisonTable(validation, title: "2020 年起逐期验证")
                                    Text(summary).font(.caption).foregroundStyle(.secondary)
                                }
                                Text("一至六等列为常规奖中奖注数。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.top, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let simulation {
                Text("\(simulation.strategy) · \(simulation.rangeText) · 每期 \(simulation.ticketsPerPeriod) 注，共 \(simulation.ticketCount) 注")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 22) {
                    metric("四等奖及以上", "\(simulation.highPrizePeriods) / \(simulation.rounds.count) 期")
                    metric("回本率", simulation.breakEvenText)
                        .help("当期奖金达到或超过当期投入的期数占比")
                    metric("总投入", LotterySimulation.money(simulation.cost))
                    metric("总奖金", LotterySimulation.money(simulation.payout), highlight: (simulation.payout ?? 0) > 0)
                    metric("净收益", LotterySimulation.money(simulation.net), highlight: simulation.net != nil)
                }
                let winningCount = Text("已确认中奖 \(simulation.winningTickets) 注")
                    .foregroundStyle(simulation.winningTickets > 0 ? Color.red : .secondary)
                Text("已确认任意奖命中率 \(simulation.hitText)，\(winningCount)。奖金含已核验派奖。")
                    .font(.caption).foregroundStyle(.secondary)
                if simulation.pendingCount > 0 {
                    Label("\(simulation.pendingCount) 期奖金待核对，可重新运行回测。", systemImage: "exclamationmark.triangle")
                }
                List(simulation.rounds.reversed()) { round in
                    let expanded = expandedIssues.contains(round.id)
                    VStack(alignment: .leading, spacing: 0) {
                        Button {
                            if expanded {
                                expandedIssues.remove(round.id)
                            } else {
                                expandedIssues.insert(round.id)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 12)
                                    .accessibilityHidden(true)
                                Text(round.id).font(.body.monospacedDigit())
                                Text(round.ranks)
                                    .foregroundStyle(round.noticeError == nil && round.summary.winnerCount > 0 ? Color.red : .secondary)
                                Spacer()
                                Text("奖金 \(LotterySimulation.money(round.awarded))")
                                    .foregroundStyle((round.awarded ?? 0) > 0 ? Color.red : .primary)
                                Text("盈亏 \(LotterySimulation.money(round.awarded.map { $0 - round.cost }))")
                                    .foregroundStyle((round.awarded ?? 0) > 0 ? Color.red : .secondary)
                                    .frame(minWidth: 85, alignment: .trailing)
                            }
                            .monospacedDigit()
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(expanded ? "已展开" : "已收起")
                        if expanded {
                            roundDetail(round)
                        }
                    }
                }
                .listStyle(.inset)
            } else if let failure {
                ContentUnavailableView("无法完成回测", systemImage: "exclamationmark.circle", description: Text(failure))
            } else {
                Spacer()
                ProgressView(value: Double(completed), total: Double(max(1, total))) {
                    if mode == .comparison && completed == 0 {
                        Text("正在准备历史数据并核对福运奖公告…")
                    } else {
                        Text("正在\(mode == .comparison ? "比较策略" : "复盘并核奖") · \(completed) / \(total) 期")
                    }
                }
                .padding(.horizontal, 80)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 760, height: 550, alignment: .topLeading)
        .task(id: runID) { await run() }
        .sheet(isPresented: $isPrizeRulesPresented) {
            LotteryPrizeRulesView()
        }
    }

    private func benchmarkTable(_ window: LotteryComparison.Window) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近 \(window.periods) 期中奖率").font(.headline)
            Text("\(window.firstIssue)～\(window.lastIssue) · 每期至少一注中奖计为命中一期，任意奖含当期开设的福运奖。")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: 24, verticalSpacing: 6) {
                GridRow {
                    Text("策略").gridColumnAlignment(.leading)
                    Text("任意奖")
                    Text("四等奖及以上")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(LotteryComparison.Method.allCases, id: \.self) { method in
                    let totals = window.totals[method, default: .init()]
                    GridRow {
                        Text(method.title)
                        Text(window.anyPrizeText(totals))
                        Text("\(totals.highPrizePeriods) 期 · \(window.rate(totals.highPrizePeriods))")
                    }
                }
            }
            .font(.callout).monospacedDigit()
            Text(window.leaders).font(.callout.weight(.medium))
            Text("有开奖前原票就用原票，其余逐期用此前历史选号；机选使用同一组可复现的随机样本。")
                .font(.caption).foregroundStyle(.secondary)
            if window.totals.values.contains(where: { $0.uncertainWinningPeriods > 0 }) {
                Text("部分福运奖公告待核对。区间下限为已确认中奖的期数，上限包含可能只中福运奖的期数。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func comparisonTable(_ window: LotteryComparison.Window, title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text("\(window.firstIssue)～\(window.lastIssue) · 共 \(window.periods) 期")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    Text("策略").gridColumnAlignment(.leading)
                    Text("四等奖及以上")
                    Text("理论概率")
                    Text("原票期数")
                    ForEach(LotteryComparison.regularPrizes, id: \.self) { Text($0.rawValue) }
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(LotteryComparison.Method.allCases, id: \.self) { method in
                    let totals = window.totals[method, default: .init()]
                    GridRow {
                        Text(method.title)
                        Text("\(totals.highPrizePeriods) / \(window.periods)").fontWeight(.semibold)
                        Text(LotteryPortfolio.highPrizeTheory(count: LotteryComparison.ticketCount, random: method == .quickPick))
                        Text(method == .quickPick ? "—" : String(totals.archivedPeriods))
                        ForEach(LotteryComparison.regularPrizes, id: \.self) { prize in
                            Text(String(totals.ticketsByPrize[prize, default: 0]))
                        }
                    }
                }
            }
            .font(.callout).monospacedDigit()
        }
    }

    private func metric(_ title: String, _ value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(highlight ? Color.red : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func roundDetail(_ round: LotterySimulation.Round) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let actual = LotterySelection(redNumbers: round.draw.redNumbers, blueNumber: round.draw.blueNumber)
            Text("\(round.ticketSource) · 实际开奖 \(actual.formattedNumbers) · 选号使用此前 \(round.historyCount) 期")
                .font(.caption).foregroundStyle(.secondary)
            if let error = round.noticeError {
                Text("公告读取失败 · \(error)").font(.caption)
            }
            ForEach(round.selections.indices, id: \.self) { index in
                let selection = round.selections[index]
                let result = round.results[index]
                HStack {
                    Text("第 \(index + 1) 注").frame(width: 48, alignment: .leading)
                    if result.prize != nil {
                        highlightedNumbers(selection, draw: round.draw)
                    } else {
                        Text(selection.formattedNumbers)
                    }
                    Spacer()
                    Text("\(result.redHits) 红 \(result.blueHit ? 1 : 0) 蓝")
                    if round.noticeError != nil {
                        Text(result.prize.map { "\($0.rawValue) · 奖金待核对" } ?? "活动奖待核对")
                    } else if let prize = result.prize {
                        Text("\(prize.rawValue) \(LotterySimulation.money(result.amount.map { $0 + (result.promotion ?? 0) }))")
                            .foregroundStyle(.red)
                    } else {
                        Text("未中奖")
                    }
                }
                .font(.callout.monospacedDigit())
            }
        }
        .padding(.vertical, 6)
    }

    private func highlightedNumbers(_ selection: LotterySelection, draw: LotteryDraw) -> Text {
        func ball(_ number: Int, matched: Bool) -> AttributedString {
            var text = AttributedString(LotterySelection.formatted(number))
            if matched { text.foregroundColor = .red }
            return text
        }

        var numbers = AttributedString()
        for red in selection.redNumbers {
            numbers += ball(red, matched: draw.redNumbers.contains(red))
            numbers += AttributedString(" ")
        }
        numbers += AttributedString("+ ")
        numbers += ball(selection.blueNumber, matched: selection.blueNumber == draw.blueNumber)
        return Text(numbers)
    }

    private func run() async {
        running = true
        completed = 0
        simulation = nil
        comparison = nil
        failure = nil
        copied = false
        expandedIssues.removeAll()
        defer { if !Task.isCancelled { running = false } }
        let input = endIssue.trimmingCharacters(in: .whitespacesAndNewlines)
        let issue = input.isEmpty ? draws.last?.issue ?? "" : input
        let available = draws.firstIndex(where: { $0.issue == issue }) ?? 0
        total = mode == .comparison ? available : min(available, LotterySimulation.periodCount)
        do {
            if mode == .comparison {
                let result = try await LotteryComparison.run(draws: draws, through: issue, archive: LotteryRecommendationArchive.load(), progress: { done, _ in
                    await MainActor.run { if !Task.isCancelled { completed = done } }
                })
                try Task.checkCancellation()
                comparison = result
                return
            }
            guard let count = Int(ticketCountText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw LotterySimulation.RunError.invalidTicketCount
            }
            let seed: UInt64? = mode == .sample ? .random(in: .min ... .max) : nil
            let archive = mode == .replay && count == LotterySimulation.defaultTicketCount ? try LotteryRecommendationArchive.load() : nil
            let finished = try await LotterySimulation.run(draws: draws, through: issue, ticketsPerPeriod: count, strategy: strategy,
                                                           sampleSeed: seed, archive: archive, notice: { draw in
                if let (cachedDraw, notice) = notices[draw.issue], cachedDraw == draw { return notice }
                let notice = try await LotteryPrizeAnnouncement.fetch(for: draw)
                try Task.checkCancellation()
                notices[draw.issue] = (draw, notice)
                return notice
            }, progress: { completed = $0 })
            try Task.checkCancellation()
            simulation = finished
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}
