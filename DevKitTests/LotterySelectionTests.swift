import Foundation
import Testing
@testable import devkit

struct LotterySelectionTests {
    @Test func generatedSelectionsRespectNumberPoolsAndReachTheirBoundaries() {
        var generator = SeededGenerator()
        var seenReds = Set<Int>()
        var seenBlues = Set<Int>()

        for _ in 0..<1_000 {
            let selection = LotterySelection.random(using: &generator)
            #expect(selection.redNumbers.count == 6)
            #expect(Set(selection.redNumbers).count == 6)
            #expect(selection.redNumbers.allSatisfy { (1...33).contains($0) })
            #expect((1...16).contains(selection.blueNumber))
            #expect(selection.redNumbers == selection.redNumbers.sorted())
            seenReds.formUnion(selection.redNumbers)
            seenBlues.insert(selection.blueNumber)
        }

        #expect(seenReds == Set(1...33))
        #expect(seenBlues == Set(1...16))
    }

    @Test func copiedNumbersKeepLeadingZerosAndSeparateTheBlueBall() {
        var generator = SeededGenerator()
        let selection = LotterySelection.random(using: &generator)
        let groups = selection.formattedNumbers.components(separatedBy: " + ")
        #expect(groups.count == 2)
        #expect(groups[0].split(separator: " ").map { Int($0) } == selection.redNumbers.map(Optional.some))
        #expect(Int(groups[1]) == selection.blueNumber)
        #expect(LotterySelection.formatted(1) == "01")
        #expect(LotterySelection.formatted(9) == "09")
        #expect(LotterySelection.formatted(33) == "33")
    }

    @Test func learnsSequentialPatternsEvenWhenEveryBlueNumberIsEquallyFrequent() {
        let favoredReds = Set([1, 2, 3, 4, 5, 33])
        let history = (0..<96).map {
            LotteryDraw(issue: String(2026001 + $0), date: "2026-01-01", redNumbers: favoredReds.sorted(), blueNumber: $0 % 16 + 1)
        }
        let forecast = LotteryForecast(draws: history.reversed())
        var biasedGenerator = SeededGenerator()
        var blueHits = 0
        for _ in 0..<200 {
            let selection = forecast.next(using: &biasedGenerator)
            #expect(selection.redNumbers.count == 6)
            #expect(selection.redNumbers == Set(selection.redNumbers).sorted())
            #expect(favoredReds.intersection(selection.redNumbers).count <= 2)
            if selection.blueNumber == 1 { blueHits += 1 }
        }
        #expect(forecast.covered == 0)
        #expect(blueHits > 120)
        #expect(forecast.evaluated == 66)
        #expect(forecast.logGain == 0)
        let firstScored = LotteryForecast(draws: Array(history.prefix(31)))
        #expect(firstScored.evaluated == 1)
        #expect(firstScored.logGain == 0)
    }

    @Test func firstPickHonorsNewNumberRuleEvenWhenSixRepeatsScoreHighly() {
        let pools = [Array(1...6), Array(7...12), Array(13...18), Array(19...24)]
        let history = (0..<100).map { index in
            LotteryDraw(issue: String(2026001 + index), date: "2026-01-01",
                        redNumbers: index >= 96 ? pools[0] : pools[index % 4],
                        blueNumber: index % 16 + 1)
        }
        let forecast = LotteryForecast(draws: history)
        var generator = SeededGenerator()
        for _ in 0..<20 {
            let first = forecast.next(mode: .highestScore, using: &generator)
            #expect(Set(first.redNumbers).intersection(pools[0]).count <= 2)
            #expect(first.blueNumber == 5)
        }
    }

    @Test func learnsOddCompositionAndBlueHalfFromPriorDraws() {
        var generator = SeededGenerator()
        let history = (0..<160).map { index in
            let oddNumbers = Array(stride(from: 1, through: 33, by: 2))
            return LotteryDraw(issue: String(2025001 + index), date: "2025-01-01",
                               redNumbers: oddNumbers.shuffled(using: &generator).prefix(6).sorted(),
                               blueNumber: Int.random(in: index.isMultiple(of: 2) ? 1...8 : 9...16, using: &generator))
        }
        let forecast = LotteryForecast(draws: history)
        let lastReds = Set(history[159].redNumbers)
        for _ in 0..<20 {
            let first = forecast.next(mode: .highestScore, using: &generator)
            #expect(first.redNumbers.allSatisfy { !$0.isMultiple(of: 2) })
            #expect(lastReds.intersection(first.redNumbers).count <= 2)
            #expect((1...8).contains(first.blueNumber))
        }
        let expected = (30..<history.count).filter { index in
            Set(history[index].redNumbers).intersection(history[index - 1].redNumbers).count <= 2
        }
        #expect(forecast.covered == expected.count)
    }

    @Test func firstPickUsesUniformSamplerWithoutEvidence() {
        let forecast = LotteryForecast(draws: [])
        var firstGenerator = SeededGenerator()
        var sampleGenerator = SeededGenerator()
        for _ in 0..<16 {
            #expect(forecast.next(mode: .highestScore, using: &firstGenerator) == forecast.next(using: &sampleGenerator))
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
