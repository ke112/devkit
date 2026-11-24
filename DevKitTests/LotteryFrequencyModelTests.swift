import Testing
@testable import devkit

nonisolated struct LotteryFrequencyModelTests {
    private let first = LotteryDraw(issue: "1", date: "", redNumbers: [1, 2, 3, 4, 5, 33], blueNumber: 16)
    private let second = LotteryDraw(issue: "2", date: "", redNumbers: [6, 7, 8, 9, 10, 11], blueNumber: 1)
    private let tolerance = 1e-12

    @Test func startsWithUniformPrior() {
        let model = LotteryFrequencyModel()
        #expect(model.redProbabilities.count == 33)
        #expect(model.blueProbabilities.count == 16)
        #expect(model.redProbabilities.allSatisfy { abs($0 - 6.0 / 33) < tolerance })
        #expect(model.blueProbabilities.allSatisfy { abs($0 - 1.0 / 16) < tolerance })
        let improvement = model.brierImprovement(for: first)
        #expect(abs(improvement.red) < tolerance)
        #expect(abs(improvement.blue) < tolerance)
    }

    @Test func accumulatesEveryDrawAgainstOneHundredUniformDraws() {
        var model = LotteryFrequencyModel()
        model.observe(first)
        model.observe(second)
        let reds = model.redProbabilities
        let blues = model.blueProbabilities
        for (index, probability) in reds.enumerated() {
            let hits = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 33].contains(index + 1) ? 1.0 : 0.0
            #expect(abs(probability - (600.0 / 33 + hits) / 102) < tolerance)
        }
        for (index, probability) in blues.enumerated() {
            let hits = index == 0 || index == 15 ? 1.0 : 0.0
            #expect(abs(probability - (100.0 / 16 + hits) / 102) < tolerance)
        }
        #expect(abs(reds.reduce(0, +) - 6) < tolerance)
        #expect(abs(blues.reduce(0, +) - 1) < tolerance)
    }

    @Test func scoresHeldOutDrawsWithoutUpdatingHistory() {
        var model = LotteryFrequencyModel()
        for _ in 0..<100 { model.observe(first) }
        let matching = model.brierImprovement(for: first)
        let disjoint = model.brierImprovement(for: second)
        let redRate = 6.0 / 33
        let blueRate = 1.0 / 16
        let matchingRed = 0.75 * redRate * (1 - redRate)
        let matchingBlue = 0.75 * blueRate * (1 - blueRate)
        #expect(abs(matching.red - matchingRed) < tolerance)
        #expect(abs(matching.blue - matchingBlue) < tolerance)
        #expect(abs(disjoint.red - (matchingRed - redRate)) < tolerance)
        #expect(abs(disjoint.blue - (matchingBlue - blueRate)) < tolerance)
        let repeated = model.brierImprovement(for: first)
        #expect(repeated.red == matching.red)
        #expect(repeated.blue == matching.blue)
    }

    @Test func ranksEveryLabelOnceAndReplaysTheSeed() {
        var model = LotteryFrequencyModel()
        for _ in 0..<100 { model.observe(first) }
        var generator = LotteryHistoryGenerator(issue: "3", historyWords: [], sampleSeed: 42)
        var replay = generator
        var redHits = 0
        var blueHits = 0
        for _ in 0..<512 {
            let ranking = model.rankedLabels(using: &generator)
            let replayed = model.rankedLabels(using: &replay)
            #expect(ranking.reds == replayed.reds)
            #expect(ranking.blues == replayed.blues)
            #expect(ranking.reds.sorted() == Array(1...33))
            #expect(ranking.blues.sorted() == Array(1...16))
            if first.redNumbers.contains(ranking.reds[0]) { redHits += 1 }
            if first.blueNumber == ranking.blues[0] { blueHits += 1 }
        }
        #expect(abs(Double(redHits) / 512 - (1 + 6.0 / 33) / 2) < 0.1)
        #expect(abs(Double(blueHits) / 512 - (1 + 1.0 / 16) / 2) < 0.1)
    }
}
