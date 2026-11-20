import Foundation

struct LotterySimulation {
    static let periodCount = 100
    nonisolated static let defaultTicketCount = 10
    static let allowedTicketCounts = 1...1_000
    nonisolated static let strategyName = "组合覆盖 v1"

    struct Round: Identifiable {
        let draw: LotteryDraw
        let historyCount: Int
        let selections: [LotterySelection]
        let results: [LotteryTicketResult]
        let summary: LotteryPrizeSummary
        let noticeError: String?

        var id: String { draw.issue }
        var cost: Decimal { Decimal(selections.count * LotterySelection.unitPrice) }
        var awarded: Decimal? { noticeError == nil && !summary.hasPendingAmount ? summary.total : nil }
        var ranks: String {
            if noticeError != nil { return "奖级待核对" }
            let counts = Dictionary(grouping: results.compactMap(\.prize), by: { $0 })
            let labels = LotteryPrize.allCases.compactMap { prize in
                counts[prize].map { "\(prize.rawValue) × \($0.count)" }
            }
            return labels.isEmpty ? "未中奖" : labels.joined(separator: "、")
        }
    }

    enum RunError: LocalizedError {
        case insufficientHistory
        case invalidTicketCount
        case invalidSelection(String, Int)

        var errorDescription: String? {
            switch self {
            case .insufficientHistory: "请选择一个已开奖、且有足够历史可回测 100 期的截止期。"
            case .invalidTicketCount: "每期注数请输入 \(LotterySimulation.allowedTicketCounts.lowerBound)～\(LotterySimulation.allowedTicketCounts.upperBound) 之间的整数。"
            case .invalidSelection(let issue, let count): "第 \(issue) 期无法根据此前历史生成 \(count) 注有效号码。"
            }
        }
    }

    let strategy: String
    let ticketsPerPeriod: Int
    let rounds: [Round]
    var ticketCount: Int { rounds.reduce(0) { $0 + $1.selections.count } }
    var cost: Decimal { rounds.reduce(0) { $0 + $1.cost } }
    var winningPeriods: Int { rounds.filter { $0.noticeError == nil && $0.summary.winnerCount > 0 }.count }
    var winningTickets: Int { rounds.filter { $0.noticeError == nil }.reduce(0) { $0 + $1.summary.winnerCount } }
    var hitRate: Double? {
        guard !rounds.isEmpty, rounds.allSatisfy({ $0.noticeError == nil }) else { return nil }
        return Double(winningPeriods) / Double(rounds.count)
    }
    var pendingCount: Int { rounds.filter { $0.awarded == nil }.count }
    var payout: Decimal? { pendingCount == 0 ? rounds.reduce(0) { $0 + $1.summary.total } : nil }
    var net: Decimal? { payout.map { $0 - cost } }
    var breakEvenText: String {
        guard pendingCount == 0, !rounds.isEmpty else { return "待核对" }
        let count = rounds.filter { $0.summary.total >= $0.cost }.count
        return (Double(count) / Double(rounds.count)).formatted(.percent.precision(.fractionLength(0...2)))
    }

    var rangeText: String { "\(rounds.first?.id ?? "")～\(rounds.last?.id ?? "")" }

    static func money(_ value: Decimal?) -> String {
        value?.formatted(.currency(code: "CNY").precision(.fractionLength(0...2)).locale(Locale(identifier: "zh_CN"))) ?? "待核对"
    }

    var hitText: String { hitRate?.formatted(.percent.precision(.fractionLength(0...2))) ?? "待核对" }

    var report: String {
        let header = [
            "双色球策略回测 · \(strategy) · \(rangeText)",
            "\(rounds.count) 期 / \(ticketCount) 注，已确认中奖 \(winningPeriods) 期、\(winningTickets) 注，历史中奖率 \(hitText)",
            "总投入 \(Self.money(cost))，总奖金 \(Self.money(payout))，净收益 \(Self.money(net))，待核对 \(pendingCount) 期",
            "回本率 \(breakEvenText)（当期奖金达到或超过当期投入）",
            "每期 \(ticketsPerPeriod) 注同票，金额含已核验派奖。历史中奖率按至少中一注的期数计算。",
            "期号\t历史期数\t奖级与注数\t投入\t奖金\t净收益"
        ]
        return (header + rounds.map { round in
            [round.id, String(round.historyCount), round.ranks, Self.money(round.cost),
             Self.money(round.awarded), Self.money(round.awarded.map { $0 - round.cost })].joined(separator: "\t")
        }).joined(separator: "\n")
    }

    @MainActor
    static func run(
        draws: [LotteryDraw], through issue: String, ticketsPerPeriod: Int = defaultTicketCount, strategy: String = strategyName,
        select: @MainActor (String, ArraySlice<LotteryDraw>, Int) -> [LotterySelection]? = {
            LotteryBacktest.makePortfolio(issue: $0, history: $1, count: $2)?.selections
        },
        notice: @escaping @MainActor (LotteryDraw) async throws -> LotteryPrizeAnnouncement = LotteryPrizeAnnouncement.fetch(for:),
        progress: (Int) -> Void = { _ in }
    ) async throws -> Self {
        guard allowedTicketCounts.contains(ticketsPerPeriod) else { throw RunError.invalidTicketCount }
        guard let end = draws.firstIndex(where: { $0.issue == issue }), end >= periodCount else {
            throw RunError.insufficientHistory
        }
        let first = end - periodCount + 1
        var rounds: [Round] = []
        let batchSize = 4
        for batchStart in stride(from: first, through: end, by: batchSize) {
            try Task.checkCancellation()
            try await withThrowingTaskGroup(of: Round.self) { group in
                for index in batchStart...min(batchStart + batchSize - 1, end) {
                    let draw = draws[index]
                    guard let selections = select(draw.issue, draws[..<index], ticketsPerPeriod), selections.count == ticketsPerPeriod,
                          selections.allSatisfy({ selection in
                              selection.redNumbers.count == 6 && Set(selection.redNumbers).count == 6
                                  && selection.redNumbers.allSatisfy((1...33).contains) && (1...16).contains(selection.blueNumber)
                          }) else { throw RunError.invalidSelection(draw.issue, ticketsPerPeriod) }
                    group.addTask { @MainActor in
                        let announcement: LotteryPrizeAnnouncement?
                        let noticeError: String?
                        do {
                            announcement = try await notice(draw)
                            noticeError = nil
                        } catch {
                            try Task.checkCancellation()
                            announcement = nil
                            noticeError = error.localizedDescription
                        }
                        try Task.checkCancellation()
                        let stake = ticketsPerPeriod * LotterySelection.unitPrice
                        let results = selections.map {
                            LotteryTicketResult(selection: $0, draw: draw, announcement: announcement, ticketStake: stake)
                        }
                        return Round(draw: draw, historyCount: index, selections: selections, results: results,
                                     summary: LotteryPrizeSummary(results: results), noticeError: noticeError)
                    }
                }
                for try await round in group {
                    try Task.checkCancellation()
                    rounds.append(round)
                    progress(rounds.count)
                }
            }
        }
        return Self(strategy: strategy, ticketsPerPeriod: ticketsPerPeriod, rounds: rounds.sorted { $0.id < $1.id })
    }
}
