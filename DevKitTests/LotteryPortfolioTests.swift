import Testing
@testable import devkit

struct LotteryPortfolioTests {
    @Test func tenTicketsReachTheFairDrawCoverageBound() {
        var generator = SeededGenerator()
        let portfolio = LotteryPortfolio(using: &generator)

        #expect(portfolio.selections.count == 10)
        expectDistinctCoverage(portfolio.selections)
        #expect(abs(portfolio.anyPrizeProbability - 11_401_360.0 / 17_721_088.0) < 0.000_000_001)
    }

    @Test func addingRemovingAndRegeneratingPreserveCoverage() throws {
        var generator = SeededGenerator()
        var portfolio = LotteryPortfolio(using: &generator)
        let original = portfolio.selections
        portfolio.add()
        #expect(Array(portfolio.selections.prefix(10)) == original)
        expectDistinctCoverage(portfolio.selections)
        #expect(abs(portfolio.anyPrizeProbability - 12_481_788.0 / 17_721_088.0) < 0.000_000_001)
        portfolio.removeLast()
        #expect(portfolio.selections == original)

        for _ in 0..<7 { portfolio.add() }
        #expect(portfolio.anyPrizeProbability == 1)
        #expect(Set(portfolio.selections).count == 17)
        let beforeRegeneration = portfolio.selections
        let first = try #require(portfolio.selections.first)
        let last = try #require(portfolio.selections.last)
        portfolio.regenerate(at: 0)
        portfolio.regenerate(at: 16)
        #expect(portfolio.selections[0] != first)
        #expect(portfolio.selections[16] != last)
        #expect(Set(portfolio.selections).count == 17)
        #expect(portfolio.selections[1..<16] == beforeRegeneration[1..<16])
        expectDistinctCoverage(Array(portfolio.selections.prefix(16)))
        #expect(portfolio.anyPrizeProbability == 1)

        for _ in 0..<17 { portfolio.removeLast() }
        #expect(portfolio.selections.count == 1)
        #expect(abs(portfolio.anyPrizeProbability - 1_188_988.0 / 17_721_088.0) < 0.000_000_001)
    }

    @Test func generatedNumbersReachAllPoolBoundaries() {
        var generator = SeededGenerator()
        var seenReds = Set<Int>()
        var seenBlues = Set<Int>()
        for _ in 0..<30 {
            let portfolio = LotteryPortfolio(using: &generator)
            for selection in portfolio.selections {
                seenReds.formUnion(selection.redNumbers)
                seenBlues.insert(selection.blueNumber)
            }
        }
        #expect(seenReds == Set(1...33))
        #expect(seenBlues == Set(1...16))
    }

    @Test func spreadingRedsUsesAllAvailableNumbersWithoutNewOverlaps() {
        var generator = SeededGenerator()
        for count in [1, 5, 10, 15, 16, 20] {
            let portfolio = LotteryPortfolio(count: count, using: &generator)
            let spread = portfolio.spreadRedNumbers(using: &generator)
            #expect(spread.map(\.blueNumber) == portfolio.selections.map(\.blueNumber))
            if count >= 16 {
                #expect(spread == portfolio.selections)
                continue
            }
            #expect(Set(spread.flatMap(\.redNumbers)).count == min(count * 6, 33))
            expectDistinctCoverage(spread)
            for index in spread.indices {
                for other in spread.indices where other > index {
                    let previous = Set(portfolio.selections[index].redNumbers).intersection(portfolio.selections[other].redNumbers)
                    let current = Set(spread[index].redNumbers).intersection(spread[other].redNumbers)
                    #expect(current.count <= previous.count)
                }
            }
        }
    }

    @Test func copiedNumbersKeepLeadingZerosAndSeparateTheBlueBall() {
        let selection = LotterySelection(redNumbers: [1, 9, 10, 20, 31, 33], blueNumber: 2)
        #expect(selection.formattedNumbers == "01 09 10 20 31 33 + 02")
    }

    @Test(arguments: [1, 9, 10, 11, 15, 16, 17, 1_000])
    func frequencyWeightingPreservesCoverageAndTheRequestedBudget(count: Int) {
        var generator = SeededGenerator()
        let portfolio = LotteryPortfolio(count: count, using: &generator)
        let tickets = portfolio.selections(for: .frequency, frequencies: LotteryFrequencyModel(), using: &generator)
        #expect(tickets.count == count)
        #expect(Set(tickets).count == count)
        expectDistinctCoverage(Array(tickets.prefix(16)))
        if count == 10 {
            #expect(Set(tickets.flatMap(\.redNumbers)).count == 33)
        }
    }

    private func expectDistinctCoverage(_ selections: [LotterySelection]) {
        let blues = Set(selections.map(\.blueNumber))
        #expect(blues.count == selections.count)
        #expect(blues.isSubset(of: 1...16))
        for (index, selection) in selections.enumerated() {
            let red = Set(selection.redNumbers)
            #expect(red.count == 6)
            #expect(red.isSubset(of: 1...33))
            #expect(selection.redNumbers == red.sorted())
            for other in selections.dropFirst(index + 1) {
                #expect(red.intersection(other.redNumbers).count <= 1)
            }
        }
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64 = 42

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
