import Foundation

nonisolated struct LotteryComparison {
    enum Method: Hashable, CaseIterable {
        case version(LotteryBacktest.Strategy), quickPick

        static var allCases: [Self] { LotteryBacktest.Strategy.allCases.map(Self.version) + [.quickPick] }

        var strategy: LotteryBacktest.Strategy? {
            switch self {
            case .version(let strategy): strategy
            case .quickPick: nil
            }
        }

        var title: String { strategy?.rawValue ?? "均匀机选" }
    }

    struct Totals {
        var highPrizePeriods = 0
        var winningPeriods = 0
        var uncertainWinningPeriods = 0
        var archivedPeriods = 0
        var ticketsByPrize: [LotteryPrize: Int] = [:]

        mutating func record(_ prizes: [LotteryPrize], archived: Bool, fortuneOnly: Bool? = false) {
            if prizes.contains(where: \.isFourthOrBetter) { highPrizePeriods += 1 }
            if !prizes.isEmpty || fortuneOnly == true {
                winningPeriods += 1
            } else if fortuneOnly == nil {
                uncertainWinningPeriods += 1
            }
            if archived { archivedPeriods += 1 }
            for prize in prizes { ticketsByPrize[prize, default: 0] += 1 }
        }
    }

    struct Window {
        let firstIssue: String
        let lastIssue: String
        let periods: Int
        var totals: [Method: Totals] = [:]

        func rate(_ count: Int) -> String {
            (Double(count) / Double(periods)).formatted(.percent.precision(.fractionLength(1...2)))
        }

        func anyPrizeText(_ totals: Totals) -> String {
            let confirmed = totals.winningPeriods
            return totals.uncertainWinningPeriods == 0
                ? "\(confirmed) 期 · \(rate(confirmed))"
                : "\(confirmed)～\(confirmed + totals.uncertainWinningPeriods) 期"
        }

        var leaders: String {
            let entries = Method.allCases.compactMap { method in totals[method].map { (method, $0) } }
            func names(for count: (Totals) -> Int) -> String {
                guard let best = entries.map({ count($0.1) }).max(), best > 0 else { return "均未命中" }
                return entries.filter { count($0.1) == best }.map { $0.0.title }.joined(separator: "、")
            }
            let anyLeader = entries.contains { $0.1.uncertainWinningPeriods > 0 }
                ? "福运奖待核对" : names(for: \.winningPeriods)
            return "任意奖最高：\(anyLeader)　四等奖及以上最高：\(names(for: \.highPrizePeriods))"
        }
    }

    static let ticketCount = 10
    static let benchmarkPeriods = 1_000
    static let regularPrizes = LotteryPrize.allCases.filter { $0 != .goodFortune }
    var all: Window
    var recent: Window
    var benchmark: Window
    var validation: Window?
    private var redScoreGain = 0.0
    private var blueScoreGain = 0.0

    private static let validationStart = "2020001"

    var validationSummary: String? {
        guard let validation, let weighted = validation.totals[.version(.frequency)] else { return nil }
        let count = Double(validation.periods)
        let rate = Double(weighted.highPrizePeriods) / count
        let zScore = 1.95996398454
        let adjustment = zScore * zScore / count
        let center = (rate + adjustment / 2) / (1 + adjustment)
        let radius = zScore * sqrt(rate * (1 - rate) / count + adjustment / (4 * count)) / (1 + adjustment)
        let interval = [max(0, center - radius), min(1, center + radius)]
            .map { $0.formatted(.percent.precision(.fractionLength(2))) }.joined(separator: "～")
        let gains = [redScoreGain, blueScoreGain].map { ($0 / count).formatted(.number.precision(.fractionLength(7))) }
        return "v3 四等奖及以上历史命中率的 95% 区间为 \(interval)。相对均匀预测，逐号 Brier 评分改善：红球 \(gains[0])，蓝球 \(gains[1])。正值表示预测误差较小。"
    }

    var report: String {
        var lines = ["双色球同预算对照 · 每种策略每期 \(Self.ticketCount) 注",
                     "最近 \(benchmark.periods) 期 · \(benchmark.firstIssue)～\(benchmark.lastIssue)",
                     benchmark.leaders,
                     "策略\t任意奖（含当期开设的福运奖）\t四等奖及以上"]
        for method in Method.allCases {
            let totals = benchmark.totals[method, default: Totals()]
            lines.append("\(method.title)\t\(benchmark.anyPrizeText(totals))\t\(totals.highPrizePeriods) 期 · \(benchmark.rate(totals.highPrizePeriods))")
        }
        lines.append("以下为常规一至六等奖；机选为按期固定的一组独立均匀抽样。")
        for (title, section) in [("全历史", all), ("最近期数", recent), ("2020 年起逐期验证", validation)] {
            guard let window = section else { continue }
            lines.append("\(title) · \(window.firstIssue)～\(window.lastIssue) · \(window.periods) 期")
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
        if let validationSummary { lines.append(validationSummary) }
        return lines.joined(separator: "\n")
    }

    @concurrent
    static func run(draws: [LotteryDraw], through issue: String, archive: LotteryRecommendationArchive? = nil,
                    fortuneStatuses: @Sendable ([LotteryDraw]) async throws -> [String: Bool] = {
                        try await LotteryPrizeAnnouncement.fortuneStatuses(for: $0)
                    },
                    progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> Self {
        guard let end = draws.firstIndex(where: { $0.issue == issue }), end >= 1,
              let endIssue = Int(issue) else { throw LotterySimulation.RunError.insufficientHistory }
        try LotteryHistoryService.validate(Array(draws[...end]), start: LotteryDrawArchive.firstIssue, end: endIssue)
        let recentStart = max(1, end - LotterySimulation.periodCount + 1)
        let benchmarkStart = max(1, end - benchmarkPeriods + 1)
        let eligible = draws[benchmarkStart...end].filter { $0.issue >= LotteryPrizeAnnouncement.firstFortuneIssue }
        let fortune = eligible.isEmpty ? [:] : try await fortuneStatuses(eligible)
        var report = Self(all: Window(firstIssue: draws[1].issue, lastIssue: issue, periods: end),
                          recent: Window(firstIssue: draws[recentStart].issue, lastIssue: issue, periods: end - recentStart + 1),
                          benchmark: Window(firstIssue: draws[benchmarkStart].issue, lastIssue: issue, periods: end - benchmarkStart + 1))
        if let start = draws[1...end].firstIndex(where: { $0.issue >= validationStart }) {
            report.validation = Window(firstIssue: draws[start].issue, lastIssue: issue, periods: end - start + 1)
        }
        var words: [UInt64] = []
        var frequencies = LotteryFrequencyModel()
        let methods = Method.allCases
        words.reserveCapacity(end * 8)
        for index in 1...end {
            try Task.checkCancellation()
            let previous = draws[index - 1]
            LotteryHistoryGenerator.append(previous, to: &words)
            frequencies.observe(previous)
            let draw = draws[index]
            let validating = draw.issue >= validationStart
            if validating {
                let gain = frequencies.brierImprovement(for: draw)
                report.redScoreGain += gain.red
                report.blueScoreGain += gain.blue
            }
            var generator = LotteryHistoryGenerator(issue: draw.issue, historyWords: words)
            let portfolio = LotteryPortfolio(count: ticketCount, using: &generator)
            var machine = LotteryHistoryGenerator(issue: draw.issue, historyWords: [], sampleSeed: 0x535351)
            let drawnReds = Set(draw.redNumbers)
            for method in methods {
                let saved = method.strategy.flatMap { archive?.selections(for: draw.issue, strategy: $0) }
                let tickets: [LotterySelection]
                if let saved {
                    tickets = saved
                } else if let strategy = method.strategy {
                    var strategyGenerator = generator
                    tickets = portfolio.selections(for: strategy, frequencies: frequencies, using: &strategyGenerator)
                } else {
                    tickets = (0..<ticketCount).map { _ in .random(using: &machine) }
                }
                var fortuneCandidate = false
                let prizes = tickets.compactMap { ticket in
                    let reds = ticket.redNumbers.count(where: drawnReds.contains)
                    let blue = ticket.blueNumber == draw.blueNumber
                    if reds == 3 && !blue { fortuneCandidate = true }
                    return LotteryPrize.matching(red: reds, blue: blue, goodFortune: false)
                }
                report.all.totals[method, default: Totals()].record(prizes, archived: saved != nil)
                if index >= benchmarkStart {
                    let bonus = fortuneCandidate && draw.issue >= LotteryPrizeAnnouncement.firstFortuneIssue ? fortune[draw.issue] : false
                    report.benchmark.totals[method, default: Totals()].record(prizes, archived: saved != nil, fortuneOnly: bonus)
                }
                if index >= recentStart {
                    report.recent.totals[method, default: Totals()].record(prizes, archived: saved != nil)
                }
                if validating {
                    report.validation?.totals[method, default: Totals()].record(prizes, archived: saved != nil)
                }
            }
            if index.isMultiple(of: 50) || index == end { await progress(index, end) }
        }
        return report
    }
}
