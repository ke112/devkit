import Foundation
import Testing
@testable import devkit

@MainActor
struct LotterySimulationTests {
    private let notice = LotteryPrizeAnnouncement(amounts: [:], includesGoodFortune: false,
                                                  promotions: [.sixth: 5], hasOtherPromotions: false)

    @Test(arguments: [5, 9, 10, 17])
    func countsWinningPeriodsOnceAndIncludesEligiblePromotions(count: Int) async throws {
        let draws = (1...110).map { index in
            LotteryDraw(issue: String(2003000 + index), date: "2003-02-23",
                        redNumbers: Array(1...6), blueNumber: index.isMultiple(of: 2) ? 1 : 16)
        }
        let report = try await LotterySimulation.run(draws: draws, through: "2003109", ticketsPerPeriod: count,
            select: { issue, history, requestedCount, _ in
                #expect(history.first == draws.first)
                #expect(history.last?.issue == String(Int(issue)! - 1))
                return (0..<requestedCount).map { offset in
                    LotterySelection(redNumbers: Array((7 + offset)...(12 + offset)), blueNumber: offset < 2 ? 1 : 2)
                }
            }, notice: { _ in notice })
        #expect(report.rounds.first?.id == "2003010")
        #expect(report.rounds.last?.id == "2003109")
        #expect(report.ticketCount == count * 100)
        #expect(report.winningPeriods == 50)
        #expect(report.winningTickets == 100)
        #expect(report.highPrizePeriods == 0)
        #expect(report.hitRate == 0.5)
        let expectedCost = Decimal(count * 200)
        let expectedPrize = Decimal(count >= 10 ? 1_000 : 500)
        #expect(report.cost == expectedCost)
        #expect(report.payout == expectedPrize)
        #expect(report.net == expectedPrize - expectedCost)
    }

    private let draws = (1...3).map { index in
        LotteryDraw(issue: String(2003000 + index), date: "2003-02-23", redNumbers: Array(1...6), blueNumber: 1)
    }

    @Test func defaultPickerAndReplayUseTheNewestRegisteredStrategy() async throws {
        let latest = try #require(LotteryBacktest.Strategy.allCases.last)
        let issue = draws[1].issue
        let page = try #require(LotteryBacktest(issue: issue, draws: draws))
        let expected = try #require(LotteryBacktest.makePortfolio(issue: issue, history: draws.prefix(1), strategy: latest))
        let replay = try await LotterySimulation.run(draws: draws, through: issue, notice: { _ in notice })
        #expect(replay.strategy == latest.rawValue)
        #expect(page.portfolio.selections == expected.selections)
        #expect(replay.rounds.last?.selections == page.portfolio.selections)
    }

    @Test(arguments: LotteryBacktest.Strategy.allCases)
    func replaysHomePortfolioWithOnlyOnePriorDraw(strategy: LotteryBacktest.Strategy) async throws {
        let history = Array(draws.prefix(2))
        let issue = history[1].issue
        let report = try await LotterySimulation.run(draws: history, through: issue, strategy: strategy, notice: { _ in notice })
        let home = try #require(LotteryBacktest(issue: issue, draws: history, strategy: strategy))
        let round = try #require(report.rounds.first)
        #expect(report.rounds.count == 1)
        #expect(report.strategy == strategy.rawValue)
        #expect(report.sampleSeed == nil)
        #expect(round.historyCount == 1)
        #expect(round.selections == home.portfolio.selections)
        #expect(round.ticketSource == "策略重建")
        await #expect(throws: LotterySimulation.RunError.self) {
            try await LotterySimulation.run(draws: history, through: history[0].issue, notice: { _ in notice })
        }
    }

    @Test func onlyUnsampledTenTicketReplayUsesMatchingOriginal() async throws {
        let issue = draws[1].issue
        let original = (1...10).map { LotterySelection(redNumbers: Array(1...6), blueNumber: $0) }
        let encoded = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
        let fixture = """
        {"issues":{"\(issue)":{"\(LotteryBacktest.Strategy.spread.rawValue)":{"recordedAt":0,"drawDate":1,"selections":\(encoded)}}}}
        """
        let archive = try JSONDecoder().decode(LotteryRecommendationArchive.self, from: Data(fixture.utf8))
        let report = try await LotterySimulation.run(draws: draws, through: draws[2].issue, strategy: .spread, archive: archive,
            select: { issueToRebuild, history, count, seed in
                #expect(issueToRebuild == draws[2].issue)
                return LotteryBacktest.makePortfolio(issue: issueToRebuild, history: history, count: count, strategy: .spread, sampleSeed: seed)?.selections
            }, notice: { _ in notice })
        #expect(report.rounds.map(\.ticketSource) == ["存档原票", "策略重建"])
        #expect(report.rounds.first?.selections == original)
        #expect(report.report.contains("\(issue)\t1\t存档原票\t"))
        #expect(report.report.contains("\(draws[2].issue)\t2\t策略重建\t"))

        let otherStrategy = try await LotterySimulation.run(draws: draws, through: issue, archive: archive, notice: { _ in notice })
        let home = try #require(LotteryBacktest(issue: issue, draws: draws))
        #expect(otherStrategy.rounds.first?.ticketSource == "策略重建")
        #expect(otherStrategy.rounds.first?.selections == home.portfolio.selections)
        let smaller = try await LotterySimulation.run(draws: draws, through: issue, ticketsPerPeriod: 3, strategy: .spread,
                                                      archive: archive, notice: { _ in notice })
        let expected = try #require(LotteryBacktest.makePortfolio(issue: issue, history: draws.prefix(1), count: 3, strategy: .spread))
        #expect(smaller.rounds.first?.ticketSource == "策略重建")
        #expect(smaller.rounds.first?.selections == expected.selections)

        let sample = try await LotterySimulation.run(draws: draws, through: issue, strategy: .spread, sampleSeed: 0,
                                                     archive: archive, notice: { _ in notice })
        let seeded = try #require(LotteryBacktest.makePortfolio(issue: issue, history: draws.prefix(1), strategy: .spread, sampleSeed: 0))
        #expect(sample.sampleSeed == 0)
        #expect(sample.rounds.first?.selections == seeded.selections)
        #expect(sample.rounds.first?.ticketSource == "随机抽样")
        #expect(sample.report.contains("本轮抽样种子 0"))
    }

    @Test func noticeFailureKeepsRegularRanksAndLeavesMoneyAndPromotionsPending() async throws {
        let fourth = LotterySelection(redNumbers: [1, 2, 3, 4, 7, 8], blueNumber: 1)
        let third = LotterySelection(redNumbers: [1, 2, 3, 4, 5, 8], blueNumber: 1)
        let fifth = LotterySelection(redNumbers: [1, 2, 3, 4, 7, 8], blueNumber: 2)
        let possibleGoodFortune = LotterySelection(redNumbers: [1, 2, 3, 7, 8, 9], blueNumber: 2)
        let report = try await LotterySimulation.run(draws: draws, through: draws[2].issue, ticketsPerPeriod: 2,
            select: { issue, _, _, _ in issue == draws[1].issue ? [fourth, third] : [fifth, possibleGoodFortune] },
            notice: { _ in throw URLError(.notConnectedToInternet) })
        let round = try #require(report.rounds.first)
        #expect(round.noticeError != nil)
        #expect(round.ranks.contains("四等奖 × 1"))
        #expect(round.ranks.contains("三等奖 × 1"))
        #expect(round.ranks.contains("活动待核对"))
        #expect(round.awarded == nil)
        #expect(report.rounds.last?.results.last?.prize == nil)
        #expect(report.winningPeriods == 2)
        #expect(report.highPrizePeriods == 1)
        #expect(report.winningTickets == 3)
        #expect(report.hitRate == 1)
        #expect(report.cost == 8)
        #expect(report.pendingCount == 2)
        #expect(report.payout == nil)
        #expect(report.net == nil)
        #expect(report.breakEvenText == "待核对")
        #expect(report.report.contains("四等奖及以上 1 期"))
    }
}
