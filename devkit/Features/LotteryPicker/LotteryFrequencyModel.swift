import Foundation

nonisolated struct LotteryFrequencyModel {
    private static let priorDraws = 100.0
    private static let uniformRed = 6.0 / 33.0
    private static let uniformBlue = 1.0 / 16.0

    private var drawCount = 0
    private var redCounts = Array(repeating: 0, count: 33)
    private var blueCounts = Array(repeating: 0, count: 16)

    init() {}

    mutating func observe(_ draw: LotteryDraw) {
        for red in draw.redNumbers { redCounts[red - 1] += 1 }
        blueCounts[draw.blueNumber - 1] += 1
        drawCount += 1
    }

    var redProbabilities: [Double] {
        probabilities(counts: redCounts, uniform: Self.uniformRed)
    }

    var blueProbabilities: [Double] {
        probabilities(counts: blueCounts, uniform: Self.uniformBlue)
    }

    private func probabilities(counts: [Int], uniform: Double) -> [Double] {
        let priorHits = Self.priorDraws * uniform
        let totalDraws = Self.priorDraws + Double(drawCount)
        return counts.map { (Double($0) + priorHits) / totalDraws }
    }

    func rankedLabels(using generator: inout some RandomNumberGenerator) -> (reds: [Int], blues: [Int]) {
        let reds = Self.weightedRanking(redProbabilities, using: &generator)
        let blues = Self.weightedRanking(blueProbabilities, using: &generator)
        return (reds, blues)
    }

    private static func weightedRanking(
        _ probabilities: [Double], using generator: inout some RandomNumberGenerator
    ) -> [Int] {
        let arrivals = probabilities.enumerated().map { index, probability in
            let uniform = Double.random(in: 0..<1, using: &generator)
            return (time: -log1p(-uniform) / probability, label: index + 1)
        }
        return arrivals.sorted { ($0.time, $0.label) < ($1.time, $1.label) }.map(\.label)
    }

    func brierImprovement(for draw: LotteryDraw) -> (red: Double, blue: Double) {
        let red = Self.meanImprovement(redProbabilities, uniform: Self.uniformRed) { draw.redNumbers.contains($0) }
        let blue = Self.meanImprovement(blueProbabilities, uniform: Self.uniformBlue) { draw.blueNumber == $0 }
        return (red, blue)
    }

    private static func meanImprovement(
        _ probabilities: [Double], uniform: Double, isDrawn: (Int) -> Bool
    ) -> Double {
        var improvement = 0.0
        for (index, probability) in probabilities.enumerated() {
            let outcome = isDrawn(index + 1) ? 1.0 : 0.0
            let baselineError = uniform - outcome
            let modelError = probability - outcome
            improvement += baselineError * baselineError - modelError * modelError
        }
        return improvement / Double(probabilities.count)
    }
}
