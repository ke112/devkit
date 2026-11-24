import Foundation
import Testing
@testable import devkit

struct LotteryComparisonTests {
    @Test func comparesTheSamePeriodsAndTicketsAsThePicker() async throws {
        let draws = Array(try LotteryDrawArchive.bundled.get().draws.prefix(115))
        let cutoff = 107
        let comparison = try await LotteryComparison.run(draws: draws, through: draws[cutoff].issue)
        #expect(comparison.all.periods == cutoff)
        #expect(comparison.all.firstIssue == draws[1].issue)
        #expect(comparison.recent.periods == 100)
        #expect(comparison.recent.firstIssue == draws[8].issue)
        for method in [LotteryComparison.Method.coverage, .spread] {
            let strategy = try #require(method.strategy)
            var allPrizes: [LotteryPrize: Int] = [:]
            var recentPrizes: [LotteryPrize: Int] = [:]
            var highPrizeIssues: [String] = []
            for draw in draws[1...cutoff] {
                let page = try #require(LotteryBacktest(issue: draw.issue, draws: draws, strategy: strategy))
                let ranks = page.portfolio.selections.compactMap {
                    LotteryTicketResult(selection: $0, draw: draw, announcement: nil, ticketStake: 20).prize
                }
                if ranks.contains(where: \.isFourthOrBetter) { highPrizeIssues.append(draw.issue) }
                for rank in ranks {
                    allPrizes[rank, default: 0] += 1
                    if draw.issue >= comparison.recent.firstIssue { recentPrizes[rank, default: 0] += 1 }
                }
            }
            #expect(comparison.all.totals[method]?.ticketsByPrize == allPrizes)
            #expect(comparison.recent.totals[method]?.ticketsByPrize == recentPrizes)
            #expect(comparison.all.totals[method]?.highPrizePeriods == highPrizeIssues.count)
            #expect(comparison.recent.totals[method]?.highPrizePeriods == highPrizeIssues.filter { $0 >= draws[8].issue }.count)
        }
        let replay = try await LotteryComparison.run(draws: Array(draws[...cutoff]), through: draws[cutoff].issue)
        #expect(replay.report == comparison.report)
    }

    @Test func twoHighPrizeTicketsInOneDrawCountAsOnePeriod() {
        var totals = LotteryComparison.Totals()
        totals.record([.second, .fourth, .fourth, .sixth], archived: true)
        totals.record([.fifth], archived: false)
        #expect(totals.highPrizePeriods == 1)
        #expect(totals.archivedPeriods == 1)
        #expect(totals.ticketsByPrize[.fourth] == 2)
    }
}
