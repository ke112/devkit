import AppKit
import SwiftUI

struct LotterySimulationView: View {
    let draws: [LotteryDraw]
    @Environment(\.dismiss) private var dismiss
    @State private var endIssue: String
    @State private var strategy: LotteryBacktest.Strategy
    @State private var ticketCountText = String(LotterySimulation.defaultTicketCount)
    @State private var runID = 0
    @State private var completed = 0
    @State private var running = true
    @State private var simulation: LotterySimulation?
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
                Text("最近 100 期策略回测").font(.title2.bold())
                Spacer()
                Picker("策略", selection: $strategy) {
                    ForEach(LotteryBacktest.Strategy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: strategy) { runID += 1 }
                Button("中奖规则") { isPrizeRulesPresented = true }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 10) {
                Text("截止期")
                TextField("最新已开奖期", text: $endIssue)
                    .frame(width: 130)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runID += 1 }
                Text("每期注数")
                TextField("注数", text: $ticketCountText)
                    .accessibilityLabel("每期注数")
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .onSubmit { runID += 1 }
                Button("运行回测") { runID += 1 }
                    .help("按当前策略重新抽取各期号码并核奖")
                Spacer()
                Button(copied ? "已复制" : "复制回测报告") {
                    guard let simulation else { return }
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(simulation.report, forType: .string)
                }
                .disabled(simulation == nil || running)
            }
            if let simulation {
                Text("\(simulation.strategy) · \(simulation.rangeText) · 每期 \(simulation.ticketsPerPeriod) 注，共 \(simulation.ticketCount) 注")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 22) {
                    metric("历史中奖率", simulation.hitText)
                    metric("回本率", simulation.breakEvenText)
                        .help("当期奖金达到或超过当期投入的期数占比")
                    metric("总投入", LotterySimulation.money(simulation.cost))
                    metric("总奖金", LotterySimulation.money(simulation.payout), highlight: (simulation.payout ?? 0) > 0)
                    metric("净收益", LotterySimulation.money(simulation.net), highlight: simulation.net != nil)
                }
                let winningCount = Text("已确认中奖 \(simulation.winningTickets) 注")
                    .foregroundStyle(simulation.winningTickets > 0 ? Color.red : .secondary)
                Text("至少中一注的期数 / 总期数：\(simulation.winningPeriods) / \(simulation.rounds.count)，\(winningCount)。奖金含已核验派奖。")
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
                                    .foregroundStyle(round.awarded != nil ? Color.red : .secondary)
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
                ProgressView(value: Double(completed), total: Double(LotterySimulation.periodCount)) {
                    Text("正在选号并核奖 · \(completed) / \(LotterySimulation.periodCount) 期")
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
            Text("实际开奖 \(actual.formattedNumbers) · 选号使用此前 \(round.historyCount) 期")
                .font(.caption).foregroundStyle(.secondary)
            if let error = round.noticeError {
                Text("公告读取失败 · \(error)").font(.caption)
            }
            ForEach(round.selections.indices, id: \.self) { index in
                HStack {
                    Text("第 \(index + 1) 注").frame(width: 48, alignment: .leading)
                    Text(round.selections[index].formattedNumbers)
                    Spacer()
                    let result = round.results[index]
                    Text("\(result.redHits) 红 \(result.blueHit ? 1 : 0) 蓝")
                    if round.noticeError != nil {
                        Text("待核对")
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

    private func run() async {
        running = true
        completed = 0
        simulation = nil
        failure = nil
        copied = false
        expandedIssues.removeAll()
        defer { if !Task.isCancelled { running = false } }
        let input = endIssue.trimmingCharacters(in: .whitespacesAndNewlines)
        let issue = input.isEmpty ? draws.last?.issue ?? "" : input
        do {
            guard let count = Int(ticketCountText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw LotterySimulation.RunError.invalidTicketCount
            }
            let selectionStrategy = strategy
            let finished = try await LotterySimulation.run(draws: draws, through: issue, ticketsPerPeriod: count, strategy: selectionStrategy.rawValue, select: {
                LotteryBacktest.makePortfolio(issue: $0, history: $1, count: $2, strategy: selectionStrategy, sampleSeed: $3)?.selections
            }, notice: { draw in
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
