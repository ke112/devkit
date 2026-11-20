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
                    metric("总奖金", LotterySimulation.money(simulation.payout))
                    metric("净收益", LotterySimulation.money(simulation.net))
                }
                Text("至少中一注的期数 / 总期数：\(simulation.winningPeriods) / \(simulation.rounds.count)，已确认中奖 \(simulation.winningTickets) 注。奖金含已核验派奖。")
                    .font(.caption).foregroundStyle(.secondary)
                if simulation.pendingCount > 0 {
                    Label("\(simulation.pendingCount) 期奖金待核对，可重新运行回测。", systemImage: "exclamationmark.triangle")
                }
                List(simulation.rounds.reversed()) { round in
                    DisclosureGroup {
                        roundDetail(round)
                    } label: {
                        HStack(spacing: 12) {
                            Text(round.id).font(.body.monospacedDigit())
                            Text(round.ranks).foregroundStyle(.secondary)
                            Spacer()
                            Text("奖金 \(LotterySimulation.money(round.awarded))")
                            Text("盈亏 \(LotterySimulation.money(round.awarded.map { $0 - round.cost }))")
                                .frame(minWidth: 85, alignment: .trailing)
                        }
                        .monospacedDigit()
                        .padding(.vertical, 4)
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
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
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
        defer { if !Task.isCancelled { running = false } }
        let input = endIssue.trimmingCharacters(in: .whitespacesAndNewlines)
        let issue = input.isEmpty ? draws.last?.issue ?? "" : input
        do {
            guard let count = Int(ticketCountText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw LotterySimulation.RunError.invalidTicketCount
            }
            let selectionStrategy = strategy
            let finished = try await LotterySimulation.run(draws: draws, through: issue, ticketsPerPeriod: count, strategy: selectionStrategy.rawValue, select: {
                LotteryBacktest.makePortfolio(issue: $0, history: $1, count: $2, strategy: selectionStrategy)?.selections
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
