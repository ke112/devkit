import Foundation

nonisolated struct LotteryComparison {
    enum Method: CaseIterable {
        case coverage, spread, quickPick

        var strategy: LotteryBacktest.Strategy? {
            switch self {
            case .coverage: .coverage
            case .spread: .spread
            case .quickPick: nil
            }
        }

        var title: String { strategy?.rawValue ?? "均匀机选" }
    }

    struct Totals {
        var highPrizePeriods = 0
        var archivedPeriods = 0
        var ticketsByPrize: [LotteryPrize: Int] = [:]

        mutating func record(_ prizes: [LotteryPrize], archived: Bool) {
            if prizes.contains(where: \.isFourthOrBetter) { highPrizePeriods += 1 }
            if archived { archivedPeriods += 1 }
            for prize in prizes { ticketsByPrize[prize, default: 0] += 1 }
        }
    }

    struct Window {
        let firstIssue: String
        let lastIssue: String
        let periods: Int
        var totals: [Method: Totals] = [:]
    }

    static let ticketCount = 10
    static let regularPrizes = LotteryPrize.allCases.filter { $0 != .goodFortune }
    var all: Window
    var recent: Window

    var report: String {
        var lines = ["双色球同预算对照 · 每种策略每期 \(Self.ticketCount) 注",
                     "常规一至六等奖；机选为按期固定的一组独立均匀抽样。"]
        for window in [all, recent] {
            lines.append("\(window.firstIssue)～\(window.lastIssue) · \(window.periods) 期")
            lines.append("策略\t四等奖及以上期数/总期数\t理论概率\t一至六等奖注数\t开奖前原票期数")
            for method in Method.allCases {
                let totals = window.totals[method, default: Totals()]
                let ranks = Self.regularPrizes.map { String(totals.ticketsByPrize[$0, default: 0]) }
                let probability = LotteryPortfolio.highPrizeTheory(count: Self.ticketCount, random: method == .quickPick)
                lines.append([method.title, "\(totals.highPrizePeriods)/\(window.periods)", probability,
                              ranks.joined(separator: " / "), method == .quickPick ? "—" : String(totals.archivedPeriods)]
                    .joined(separator: "\t"))
            }
        }
        return lines.joined(separator: "\n")
    }

    @concurrent
    static func run(draws: [LotteryDraw], through issue: String, archive: LotteryRecommendationArchive? = nil,
                    progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> Self {
        guard let end = draws.firstIndex(where: { $0.issue == issue }), end >= 1,
              let endIssue = Int(issue) else { throw LotterySimulation.RunError.insufficientHistory }
        try LotteryHistoryService.validate(Array(draws[...end]), start: LotteryDrawArchive.firstIssue, end: endIssue)
        let recentStart = max(1, end - LotterySimulation.periodCount + 1)
        var report = Self(all: Window(firstIssue: draws[1].issue, lastIssue: issue, periods: end),
                          recent: Window(firstIssue: draws[recentStart].issue, lastIssue: issue, periods: end - recentStart + 1))
        var words: [UInt64] = []
        words.reserveCapacity(end * 8)
        for index in 1...end {
            try Task.checkCancellation()
            LotteryHistoryGenerator.append(draws[index - 1], to: &words)
            let draw = draws[index]
            var generator = LotteryHistoryGenerator(issue: draw.issue, historyWords: words)
            let portfolio = LotteryPortfolio(count: ticketCount, using: &generator)
            var machine = LotteryHistoryGenerator(issue: draw.issue, historyWords: [], sampleSeed: 0x535351)
            let drawnReds = Set(draw.redNumbers)
            for method in Method.allCases {
                let saved = method.strategy.flatMap { archive?.selections(for: draw.issue, strategy: $0) }
                let tickets: [LotterySelection]
                if let saved {
                    tickets = saved
                } else if let strategy = method.strategy {
                    var strategyGenerator = generator
                    tickets = portfolio.selections(for: strategy, using: &strategyGenerator)
                } else {
                    tickets = (0..<ticketCount).map { _ in .random(using: &machine) }
                }
                let prizes = tickets.compactMap { ticket in
                    LotteryPrize.matching(red: ticket.redNumbers.count(where: drawnReds.contains),
                                          blue: ticket.blueNumber == draw.blueNumber, goodFortune: false)
                }
                report.all.totals[method, default: Totals()].record(prizes, archived: saved != nil)
                if index >= recentStart {
                    report.recent.totals[method, default: Totals()].record(prizes, archived: saved != nil)
                }
            }
            if index.isMultiple(of: 50) || index == end { await progress(index, end) }
        }
        return report
    }
}
