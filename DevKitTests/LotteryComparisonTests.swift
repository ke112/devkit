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
        #expect(comparison.validation == nil)
        #expect(comparison.benchmark.periods == cutoff)
        for method in LotteryComparison.Method.allCases where method != .quickPick {
            let strategy = try #require(method.strategy)
            var allPrizes: [LotteryPrize: Int] = [:]
            var recentPrizes: [LotteryPrize: Int] = [:]
            var highPrizeIssues: [String] = []
            var winningPeriods = 0
            for draw in draws[1...cutoff] {
                let page = try #require(LotteryBacktest(issue: draw.issue, draws: draws, strategy: strategy))
                let ranks = page.portfolio.selections.compactMap {
                    LotteryTicketResult(selection: $0, draw: draw, announcement: nil, ticketStake: 20).prize
                }
                if !ranks.isEmpty { winningPeriods += 1 }
                if ranks.contains(where: \.isFourthOrBetter) { highPrizeIssues.append(draw.issue) }
                for rank in ranks {
                    allPrizes[rank, default: 0] += 1
                    if draw.issue >= comparison.recent.firstIssue { recentPrizes[rank, default: 0] += 1 }
                }
            }
            #expect(comparison.all.totals[method]?.ticketsByPrize == allPrizes)
            #expect(comparison.benchmark.totals[method]?.winningPeriods == winningPeriods)
            #expect(comparison.recent.totals[method]?.ticketsByPrize == recentPrizes)
            #expect(comparison.all.totals[method]?.highPrizePeriods == highPrizeIssues.count)
            #expect(comparison.recent.totals[method]?.highPrizePeriods == highPrizeIssues.filter { $0 >= draws[8].issue }.count)
        }
        let replay = try await LotteryComparison.run(draws: Array(draws[...cutoff]), through: draws[cutoff].issue)
        #expect(replay.report == comparison.report)
    }

    @Test func validationBeginsWithTheFirst2020DrawAndUsesOnlyEarlierNumbers() async throws {
        let draws = (2003...2020).map { year in
            LotteryDraw(issue: "\(year)001", date: "\(year)-01-02", redNumbers: [1, 3, 6, 14, 21, 33], blueNumber: 7)
        }
        let issue = "2020001"
        let comparison = try await LotteryComparison.run(draws: draws, through: issue)
        let validation = try #require(comparison.validation)
        #expect(validation.firstIssue == issue)
        #expect(validation.periods == 1)
        let prior = try #require(LotteryBacktest(issue: issue, draws: Array(draws.dropLast()), strategy: .frequency))
        let settled = try #require(LotteryBacktest(issue: issue, draws: draws, strategy: .frequency))
        #expect(prior.portfolio.selections == settled.portfolio.selections)
        let draw = try #require(draws.last)
        let winners = prior.portfolio.selections.compactMap {
            LotteryTicketResult(selection: $0, draw: draw, announcement: nil, ticketStake: 20).prize
        }
        #expect(validation.totals[.version(.frequency)]?.ticketsByPrize == Dictionary(grouping: winners, by: { $0 }).mapValues(\.count))
    }

    @Test func comparesExactlyOneThousandDrawsEndingAtTheChosenIssue() async throws {
        let draws = Array(try LotteryDrawArchive.bundled.get().draws.prefix(1_005))
        let cutoff = 1_002
        let report = try await LotteryComparison.run(draws: draws, through: draws[cutoff].issue)
        #expect(report.benchmark.firstIssue == draws[3].issue)
        #expect(report.benchmark.lastIssue == draws[cutoff].issue)
        #expect(report.benchmark.periods == 1_000)
        #expect(Set(report.benchmark.totals.keys) == Set(LotteryComparison.Method.allCases))
    }

    @Test func onlyAnUnconfirmedBonusOnlyWinMakesThePeriodUncertain() {
        var totals = LotteryComparison.Totals()
        totals.record([.sixth, .sixth], archived: false, fortuneOnly: nil)
        totals.record([], archived: false, fortuneOnly: true)
        totals.record([], archived: false, fortuneOnly: false)
        totals.record([], archived: false, fortuneOnly: nil)
        #expect(totals.winningPeriods == 2)
        #expect(totals.uncertainWinningPeriods == 1)
        #expect(totals.highPrizePeriods == 0)
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
