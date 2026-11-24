import AppKit
import SwiftUI

struct LotteryPickerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var model = LotteryHistoryModel()
    @State private var issueText = ""
    @State private var historicalStrategy = LotteryBacktest.Strategy.latest
    @State private var recommendation: Recommendation?
    @State private var archiveError: String?
    @State private var copiedIndex: Int?
    @State private var refreshID = 0
    @State private var schedule: LotteryDrawSchedule?
    @State private var drawWindow: LotteryRecommendationArchive.DrawWindow?
    @State private var scheduleUnavailable = false
    @State private var prizeState: PrizeState?
    @State private var isPrizeRulesPresented = false
    @State private var isSimulationPresented = false

    private let red = Color(red: 0.82, green: 0.12, blue: 0.25)
    private let blue = Color(red: 0.13, green: 0.34, blue: 0.79)
    private let unitPrice = LotterySelection.unitPrice

    private struct BacktestInput: Equatable {
        let target: LotteryTargetIssue
        let explicitIssue: String
        let draws: [LotteryDraw]
        let strategy: LotteryBacktest.Strategy
        let window: LotteryRecommendationArchive.DrawWindow?
        let refreshID: Int

        var issue: String? {
            if case .issue(let issue) = target { return issue }
            return explicitIssue.isEmpty ? nil : explicitIssue
        }
    }

    private struct Recommendation {
        let issue: String
        let strategy: LotteryBacktest.Strategy
        let selections: [LotterySelection]
        let draw: LotteryDraw?
        let source: String
        let backtest: LotteryBacktest?
    }

    private struct ScheduleRequest: Equatable {
        let latest: LotteryDraw?
        let refreshID: Int
    }

    private struct PrizeRequest: Equatable {
        let draw: LotteryDraw?
        let refreshID: Int
    }

    private enum PrizeState {
        case loaded(LotteryDraw, LotteryPrizeAnnouncement)
        case unavailable(LotteryDraw)
    }

    private var isHistoricalIssue: Bool {
        let issue = issueText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !issue.isEmpty && model.draws.contains { $0.issue == issue }
    }

    private var strategy: LotteryBacktest.Strategy { isHistoricalIssue ? historicalStrategy : .latest }

    private var input: BacktestInput {
        BacktestInput(
            target: LotteryTargetIssue.resolve(issueText, latest: model.draws.last, nextDrawDate: schedule?.date),
            explicitIssue: issueText.trimmingCharacters(in: .whitespacesAndNewlines),
            draws: model.draws, strategy: strategy,
            window: !model.isLoading && model.errorMessage == nil && drawWindow?.latest == model.draws.last ? drawWindow : nil,
            refreshID: refreshID
        )
    }

    private var currentRecommendation: Recommendation? {
        guard let recommendation, recommendation.strategy == strategy,
              recommendation.issue == input.issue else { return nil }
        return recommendation
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Text("按期选号与核奖")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    scheduleHeader
                }

                if let message = model.errorMessage {
                    HStack {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Button("重试") { refreshID += 1 }
                    }
                }

                issueField
                if let archiveError {
                    Label("推荐留档失败 · \(archiveError)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if let recommendation = currentRecommendation {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("第 \(recommendation.issue) 期 · \(recommendation.source) · \(recommendation.selections.count) 注")
                            .font(.headline)
                        if let backtest = recommendation.backtest {
                            Text("选号使用 \(String(LotteryDrawArchive.firstIssue))～\(backtest.lastHistoryIssue) 共 \(backtest.historyCount) 期")
                            if strategy == .frequency {
                                Text("实验策略依据以往开奖频率分配号码。若当期开设福运奖，这 10 注至少中一注的理论概率为 \(LotteryPortfolio.frequencyTenTicketFortuneProbability.formatted(.percent.precision(.fractionLength(2))))。")
                            }
                            Text("公平开奖、常规奖级下，至少中一注的概率为 \(backtest.portfolio.anyPrizeProbability.formatted(.percent.precision(.fractionLength(2))))。")
                        }
                        Text("公平开奖、常规奖级下，至少中一注四等奖及以上的理论概率为 \(LotteryPortfolio.highPrizeTheory(count: recommendation.selections.count, random: false))。")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    let announcement = currentAnnouncement(for: recommendation.draw)
                    let results = recommendation.draw.map { draw in
                        recommendation.selections.map {
                            LotteryTicketResult(selection: $0, draw: draw, announcement: announcement,
                                                ticketStake: recommendation.selections.count * unitPrice)
                        }
                    }
                    let summary = results.map { LotteryPrizeSummary(results: $0) }
                    let settledPayout = announcement != nil && summary?.hasPendingAmount == false ? summary?.total : nil
                    drawSummary(recommendation: recommendation, summary: summary, announcement: announcement)
                    ticket(recommendation.selections, results: results, settledPayout: settledPayout)
                } else {
                    issueStatus
                }
                rules
            }
            .frame(maxWidth: 720)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("双色球选号")
        .task(id: refreshID) { await model.load() }
        .task(id: ScheduleRequest(latest: model.draws.last, refreshID: refreshID)) {
            await updateSchedule(latest: model.draws.last)
        }
        .onChange(of: input, initial: true) { _, newInput in
            updateRecommendation(newInput)
        }
        .task(id: PrizeRequest(draw: currentRecommendation?.draw, refreshID: refreshID)) {
            await updatePrizes(for: currentRecommendation?.draw)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isSimulationPresented = true } label: { Label("策略测试", systemImage: "testtube.2") }
                    .disabled(model.draws.count < 2)
                    .help("用已载入的开奖历史测试当前策略；至少需要两期，可使用内置档案")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { refreshID += 1 } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(model.isLoading)
                    .help("检查新增开奖期数并更新下次开奖时间")
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    LotteryHistoryView(model: model)
                } label: {
                    Label("历史开奖", systemImage: "chart.xyaxis.line")
                }
                .help("查看历史开奖号码与走势")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isPrizeRulesPresented = true
                } label: {
                    Label("中奖规则", systemImage: "list.bullet.rectangle")
                }
                .help("查看奖级、中奖条件和单注奖金")
            }
        }
        .sheet(isPresented: $isPrizeRulesPresented) {
            LotteryPrizeRulesView()
        }
        .sheet(isPresented: $isSimulationPresented) {
            LotterySimulationView(draws: model.draws, strategy: strategy)
        }
    }

    private var issueField: some View {
        HStack(spacing: 12) {
            Text("开奖期号")
                .font(.headline)
            TextField("留空使用下一期", text: $issueText)
                .accessibilityLabel("开奖期号")
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 180)
            Button("使用下一期") { issueText = "" }
                .disabled(issueText.isEmpty)
            Spacer(minLength: 0)
            if isHistoricalIssue {
                Picker("历史策略", selection: $historicalStrategy) {
                    ForEach(LotteryBacktest.Strategy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
            } else {
                Text("当前策略 · \(strategy.rawValue)").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var issueStatus: some View {
        switch input.target {
        case .waitingForHistory:
            if model.isLoading {
                ProgressView("正在同步历史开奖…")
            } else if model.errorMessage == nil {
                Text("等待历史开奖数据。").foregroundStyle(.secondary)
            }
        case .invalidFormat:
            Text("请输入 7 位有效期号，例如 2026134。").foregroundStyle(.secondary)
        case .outOfRange(let last):
            Text(last.map { "可查询 \(LotteryTargetIssue.first)～\($0) 期。" }
                 ?? "最早可查询 \(LotteryTargetIssue.first) 期。")
                .foregroundStyle(.secondary)
        case .issue:
            Text("未找到该期，或此前的历史开奖尚未同步完整。").foregroundStyle(.secondary)
        }
    }

    private var scheduleHeader: some View {
        Label {
            Text("下次开奖 · \(schedule?.displayText ?? (scheduleUnavailable ? "暂时无法获取，可点击刷新重试" : "正在获取…"))")
        } icon: {
            Image(systemName: "calendar.badge.clock")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func updateRecommendation(_ input: BacktestInput) {
        copiedIndex = nil
        archiveError = nil
        recommendation = nil
        guard let issue = input.issue else { return }
        let backtest: LotteryBacktest?
        if case .issue = input.target {
            backtest = LotteryBacktest(issue: issue, draws: input.draws, strategy: input.strategy)
        } else {
            backtest = nil
        }
        var original: [LotterySelection]?
        do {
            original = try LotteryRecommendationArchive.load().selections(for: issue, strategy: input.strategy)
            if original == nil, let backtest, backtest.draw == nil,
               let window = input.window, window.latest.issue == backtest.lastHistoryIssue {
                original = try LotteryRecommendationArchive.record(backtest.portfolio.selections, for: issue,
                                                                   strategy: input.strategy, window: window)
            }
        } catch {
            archiveError = error.localizedDescription
        }
        guard let selections = original ?? backtest?.portfolio.selections else { return }
        let draw = backtest?.draw ?? input.draws.first { $0.issue == issue }
        let source = original != nil ? "开奖前留档原票" : (draw == nil ? "推荐预览（未留档）" : "按历史重建")
        recommendation = Recommendation(issue: issue, strategy: input.strategy, selections: selections, draw: draw,
                                        source: source, backtest: selections == backtest?.portfolio.selections ? backtest : nil)
    }

    private func updateSchedule(latest: LotteryDraw?) async {
        drawWindow = nil
        while !Task.isCancelled {
            scheduleUnavailable = false
            if let schedule, schedule.date <= Date() { self.schedule = nil }
            do {
                var window: LotteryRecommendationArchive.DrawWindow?
                if let latest, latest.issue != String(LotteryDrawArchive.lastIssue) {
                    window = try await LotteryRecommendationArchive.DrawWindow.following(latest)
                }
                let updated: LotteryDrawSchedule
                if let window, window.schedule.date > Date() {
                    updated = window.schedule
                } else {
                    window = nil
                    updated = try await LotteryDrawScheduleService.fetch()
                }
                try Task.checkCancellation()
                drawWindow = window
                schedule = updated
                try await Task.sleep(for: .seconds(max(0, updated.nextRefreshDate.timeIntervalSinceNow)))
                try await syncDrawAfterScheduledTime()
            } catch {
                guard !Task.isCancelled else { return }
                schedule = nil
                drawWindow = nil
                scheduleUnavailable = true
                return
            }
        }
    }

    private func syncDrawAfterScheduledTime() async throws {
        let latest = model.draws.last?.issue
        for attempt in 0..<15 {
            try Task.checkCancellation()
            await model.load()
            try Task.checkCancellation()
            if model.draws.last?.issue != latest { return }
            if attempt < 14 { try await Task.sleep(for: .seconds(60)) }
        }
    }

    private func updatePrizes(for draw: LotteryDraw?) async {
        guard !Task.isCancelled else { return }
        prizeState = nil
        guard let draw else { return }
        do {
            let announcement = try await LotteryPrizeAnnouncement.fetch(for: draw)
            try Task.checkCancellation()
            guard currentRecommendation?.draw == draw else { return }
            prizeState = .loaded(draw, announcement)
        } catch {
            guard !Task.isCancelled, currentRecommendation?.draw == draw else { return }
            prizeState = .unavailable(draw)
        }
    }

    private func currentAnnouncement(for draw: LotteryDraw?) -> LotteryPrizeAnnouncement? {
        guard let draw, case .loaded(let announcedDraw, let announcement) = prizeState,
              draw == announcedDraw else { return nil }
        return announcement
    }

    @ViewBuilder
    private func drawSummary(recommendation: Recommendation, summary: LotteryPrizeSummary?, announcement: LotteryPrizeAnnouncement?) -> some View {
        if let draw = recommendation.draw, let summary {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("实际开奖 · \(draw.date)").font(.headline)
                    Spacer(minLength: 10)
                    LotteryDrawBalls(draw: draw)
                }
                HStack {
                    Group {
                        if announcement == nil {
                            Text("常规奖级中奖 \(summary.winnerCount) 注 · 已核算 \(money(summary.total))")
                        } else if summary.hasPendingAmount {
                            Text("中奖 \(summary.winnerCount) 注 · 已公布奖金 \(money(summary.total))")
                        } else {
                            Text("中奖 \(summary.winnerCount) 注 · 奖金合计 \(money(summary.total))")
                        }
                    }
                    .foregroundStyle(summary.winnerCount > 0 ? Color.red : .primary)
                    Spacer()
                    if announcement?.fromArchive == true {
                        Link("历史奖金档案", destination: LotteryDrawArchive.sourceURL)
                    } else {
                        Link("开奖公告", destination: LotteryPrizeAnnouncement.sourceURL(for: draw.issue))
                    }
                }
                .font(.callout)
                if summary.promotions > 0 {
                    Text("含 \(money(summary.promotions)) 派奖，按 10 注同打一张 20 元票计算。")
                        .foregroundStyle(.red)
                }
                if announcement?.fromArchive == true {
                    Text("按历史档案核算常规奖金，活动派奖以当期公告为准。").foregroundStyle(.secondary)
                } else if announcement?.hasOtherPromotions == true {
                    Text("该期其他活动派奖以开奖公告和购票条件为准。")
                        .foregroundStyle(.secondary)
                }
                if case .unavailable(let failedDraw) = prizeState, failedDraw == draw {
                    Text("未能核对公告中的浮动奖及派奖。").foregroundStyle(.secondary)
                } else if announcement == nil {
                    Text("正在核对开奖公告…").foregroundStyle(.secondary)
                } else if summary.hasPendingAmount {
                    Text("其中有奖级未公布单注奖金。").foregroundStyle(.secondary)
                }
            }
        } else {
            Label("等待第 \(recommendation.issue) 期开奖数据", systemImage: "clock")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func money(_ amount: Decimal) -> String {
        amount.formatted(.currency(code: "CNY").precision(.fractionLength(0...2)).locale(Locale(identifier: "zh_CN")))
    }

    private func ticket(_ tickets: [LotterySelection], results: [LotteryTicketResult]?, settledPayout: Decimal?) -> some View {
        let cost = Decimal(tickets.count * unitPrice)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Label("双色球", systemImage: "circle.hexagongrid.fill")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("总成本 \(money(cost))")
                if let settledPayout {
                    let profit = settledPayout - cost
                    Text("盈亏 \(profit > 0 ? "+" : "")\(money(profit))")
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                } else {
                    Text("盈亏 \(results == nil ? "待开奖" : "待核对")")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .monospacedDigit()
            LazyVStack(spacing: 0) {
                ForEach(tickets.indices, id: \.self) { index in
                    let selection = tickets[index]
                    HStack(spacing: 12) {
                        Text("第 \(index + 1) 注")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        LotteryDrawBalls(redNumbers: selection.redNumbers, blueNumber: selection.blueNumber)
                        Spacer()
                        if let result = results?[index] {
                            ticketResult(result)
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            copiedIndex = NSPasteboard.general.setString(selection.formattedNumbers, forType: .string) ? index : nil
                        } label: { Image(systemName: copiedIndex == index ? "checkmark" : "doc.on.doc") }
                        .accessibilityLabel("复制第 \(index + 1) 注号码")
                        .help(copiedIndex == index ? "已复制" : "复制这一注")
                    }
                    .padding(.vertical, 10)
                    if index < tickets.count - 1 { Divider() }
                }
            }
            Rectangle()
                .fill(.clear)
                .frame(height: 1)
                .overlay {
                    Rectangle()
                        .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                }
                .overlay(alignment: .leading) { ticketNotch.offset(x: -37) }
                .overlay(alignment: .trailing) { ticketNotch.offset(x: 37) }

            Text("\(tickets.count) 注 × 每注 \(money(Decimal(unitPrice)))").foregroundStyle(.secondary)
        }
        .padding(28)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.primary.opacity(0.07), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.04), radius: 18, y: 8)
    }

    private func ticketResult(_ result: LotteryTicketResult) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("\(result.redHits) 红 · \(result.blueHit ? 1 : 0) 蓝")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let prize = result.prize {
                Text("\(prize.rawValue) · \(result.amount.map { money($0 + (result.promotion ?? 0)) } ?? "奖金待核对")")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            } else {
                Text("未中奖")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 112, alignment: .trailing)
    }

    private var ticketNotch: some View {
        Circle()
            .fill(Color(nsColor: .windowBackgroundColor))
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }

    private var rules: some View {
        HStack(alignment: .top, spacing: 32) {
            rule(title: "红球怎么选", detail: "01～33 中选 6 个，不重复", color: red)
            Divider()
            rule(title: "蓝球怎么选", detail: "01～16 中选 1 个", color: blue)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }

    private func rule(title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

}

#Preview {
    LotteryPickerView()
}
