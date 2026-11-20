import Foundation

struct LotterySelection: Hashable {
    let redNumbers: [Int]
    let blueNumber: Int

    static func random(using generator: inout some RandomNumberGenerator) -> Self {
        let reds = (1...33).shuffled(using: &generator).prefix(6).sorted()
        return Self(redNumbers: reds, blueNumber: Int.random(in: 1...16, using: &generator))
    }

    var formattedNumbers: String {
        redNumbers.map(Self.formatted).joined(separator: " ")
            + " + " + Self.formatted(blueNumber)
    }

    static func formatted(_ number: Int) -> String {
        String(format: "%02d", number)
    }
}

struct LotteryPortfolio {
    private static let blueNumbers = 1...16
    private static let redDrawCount = 1_107_568
    private static let redDrawsWithFourOrMoreHits = 5_428

    private static let redLineIndices: [[Int]] = {
        let grid = 0..<5
        let slopedLines = grid.flatMap { slope in
            grid.map { intercept in
                grid.map { column in column * 5 + (slope * column + intercept) % 5 } + [25 + slope]
            }
        }
        let verticalLines = grid.map { column in
            grid.map { row in column * 5 + row } + [30]
        }
        return slopedLines + verticalLines
    }()

    private let redLines: [[Int]]
    private(set) var selections: [LotterySelection] = []

    init(count: Int = 10) {
        var generator = SystemRandomNumberGenerator()
        self.init(count: count, using: &generator)
    }

    init(count: Int = 10, using generator: inout some RandomNumberGenerator) {
        precondition(count > 0)
        let redLabels = (1...33).shuffled(using: &generator)
        redLines = Self.redLineIndices.map { line in line.map { redLabels[$0] }.sorted() }
        for _ in 0..<count { add(using: &generator) }
    }

    var anyPrizeProbability: Double {
        let coveredBlues = min(selections.count, Self.blueNumbers.count)
        let totalOutcomes = Self.blueNumbers.count * Self.redDrawCount
        let winningOutcomes = coveredBlues * Self.redDrawCount
            + (Self.blueNumbers.count - coveredBlues) * coveredBlues * Self.redDrawsWithFourOrMoreHits
        return Double(winningOutcomes) / Double(totalOutcomes)
    }

    mutating func add() {
        var generator = SystemRandomNumberGenerator()
        add(using: &generator)
    }

    mutating func removeLast() {
        guard selections.count > 1 else { return }
        selections.removeLast()
    }

    mutating func regenerate(at index: Int) {
        var generator = SystemRandomNumberGenerator()
        selections[index] = selection(at: index, using: &generator)
    }

    private mutating func add(using generator: inout some RandomNumberGenerator) {
        let next = selection(at: selections.count, using: &generator)
        selections.append(next)
    }

    private func selection(at index: Int, using generator: inout some RandomNumberGenerator) -> LotterySelection {
        if index < Self.blueNumbers.count {
            let covered = selections.prefix(Self.blueNumbers.count)
            let usedReds = Set(covered.map(\.redNumbers))
            let otherBlues = Set(covered.enumerated().filter { $0.offset != index }.map(\.element.blueNumber))
            let red = redLines.filter { !usedReds.contains($0) }.randomElement(using: &generator)!
            let blue = Self.blueNumbers.filter { !otherBlues.contains($0) }.randomElement(using: &generator)!
            return LotterySelection(redNumbers: red, blueNumber: blue)
        }

        let excluded = Set(selections)
        let reservedRedLines = Set(redLines)
        var next = LotterySelection.random(using: &generator)
        while excluded.contains(next) || reservedRedLines.contains(next.redNumbers) {
            next = LotterySelection.random(using: &generator)
        }
        return next
    }
}
