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
        let report = try await LotterySimulation.run(draws: draws, through: "2003101", ticketsPerPeriod: count, strategy: "fixture",
            select: { issue, history, requestedCount, _ in
                #expect(history.first == draws.first)
                #expect(history.last?.issue == String(Int(issue)! - 1))
                return (0..<requestedCount).map { offset in
                    LotterySelection(redNumbers: Array((7 + offset)...(12 + offset)), blueNumber: offset < 2 ? 1 : 2)
                }
            }, notice: { _ in notice })
        #expect(report.rounds.first?.id == "2003002")
        #expect(report.rounds.last?.id == "2003101")
        #expect(report.ticketCount == count * 100)
        #expect(report.winningPeriods == 50)
        #expect(report.winningTickets == 100)
        #expect(report.hitRate == 0.5)
        let expectedCost = Decimal(count * 200)
        let expectedPrize = Decimal(count >= 10 ? 1_000 : 500)
        #expect(report.cost == expectedCost)
        #expect(report.payout == expectedPrize)
        #expect(report.net == expectedPrize - expectedCost)
    }

    @Test func samplesEachRunAndKeepsMissingNoticeUnsettled() async throws {
        let draws = Array(try LotteryDrawArchive.bundled.get().draws.prefix(120))
        let end = draws[110].issue
        let report = try await LotterySimulation.run(draws: draws, through: end, notice: { draw in
            if draw.issue == end { throw URLError(.notConnectedToInternet) }
            return notice
        })
        let round = try #require(report.rounds.last)
        let single = try #require(LotteryBacktest(issue: end, draws: draws))
        let replay = LotteryBacktest.makePortfolio(issue: end, history: draws[..<110], sampleSeed: report.sampleSeed)
        #expect(round.selections == replay?.selections)
        let another = try await LotterySimulation.run(draws: draws, through: end, notice: { _ in notice })
        #expect(report.rounds.map(\.selections) != another.rounds.map(\.selections))
        #expect(round.draw == another.rounds.last?.draw)
        #expect(round.historyCount == single.historyCount)
        #expect(report.pendingCount == 1)
        #expect(report.payout == nil)
        #expect(report.net == nil)
        #expect(report.hitRate == nil)
        #expect(report.cost == 2_000)
        await #expect(throws: LotterySimulation.RunError.self) {
            try await LotterySimulation.run(draws: draws, through: draws[99].issue)
        }
    }
}
