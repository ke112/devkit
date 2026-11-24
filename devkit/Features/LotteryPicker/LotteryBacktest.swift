import Foundation

enum LotteryTargetIssue: Equatable {
    case waitingForHistory
    case invalidFormat
    case outOfRange(last: String?)
    case issue(String)

    static let first = String(LotteryDrawArchive.firstIssue + 1)

    static func resolve(_ input: String, latest: LotteryDraw?, nextDrawDate: Date?) -> Self {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            guard value.utf8.count == 7, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  !value.hasSuffix("000") else { return .invalidFormat }
            guard value >= first else { return .outOfRange(last: nil) }
        }
        guard let latest, let latestIssue = Int(latest.issue) else { return .waitingForHistory }
        if latestIssue == LotteryDrawArchive.lastIssue, value.isEmpty || value > latest.issue {
            return .waitingForHistory
        }
        let latestYear = latestIssue / 1_000
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = LotteryDrawScheduleService.beijingTimeZone
        let nextYear = nextDrawDate.map { calendar.component(.year, from: $0) }
        let nextIssue = String(nextYear == latestYear + 1 ? (latestYear + 1) * 1_000 + 1 : latestIssue + 1)
        guard value <= nextIssue else { return .outOfRange(last: nextIssue) }
        return .issue(value.isEmpty ? nextIssue : value)
    }
}

struct LotteryBacktest {
    nonisolated enum Strategy: String, CaseIterable, Sendable {
        case coverage = "组合覆盖 v1"
        case spread = "红球分散 v2"
    }

    struct Prediction {
        let selections: [LotterySelection]
        let anyPrizeProbability: Double
    }

    let issue: String
    let historyCount: Int
    let lastHistoryIssue: String
    let portfolio: Prediction
    let draw: LotteryDraw?

    init?(issue: String, draws: [LotteryDraw], strategy: Strategy = .coverage) {
        let history = draws.prefix { $0.issue < issue }
        let targetDraw = draws.dropFirst(history.count).first
        guard targetDraw == nil || targetDraw?.issue == issue,
              let selected = Self.makePortfolio(issue: issue, history: history, strategy: strategy),
              let last = history.last else { return nil }
        portfolio = selected
        self.issue = issue
        historyCount = history.count
        lastHistoryIssue = last.issue
        draw = targetDraw
    }

    static func makePortfolio(issue: String, history: ArraySlice<LotteryDraw>, count: Int = 10,
                              strategy: Strategy = .coverage, sampleSeed: UInt64? = nil) -> Prediction? {
        guard history.first?.issue == String(LotteryDrawArchive.firstIssue),
              let last = history.last, last.issue < issue,
              let issueNumber = Int(issue),
              issueNumber.isMultiple(of: 1_000) == false,
              issueNumber % 1_000 == 1 || Int(last.issue) == issueNumber - 1 else { return nil }
        if issueNumber > LotteryHistoryService.startIssue,
           !history.contains(where: { $0.issue == String(LotteryHistoryService.startIssue) }) { return nil }

        var words: [UInt64] = []
        words.reserveCapacity(history.count * 8)
        for draw in history { LotteryHistoryGenerator.append(draw, to: &words) }
        var generator = LotteryHistoryGenerator(issue: issue, historyWords: words, sampleSeed: sampleSeed)
        let baseline = LotteryPortfolio(count: count, using: &generator)
        let selections = baseline.selections(for: strategy, using: &generator)
        return Prediction(selections: selections, anyPrizeProbability: baseline.anyPrizeProbability)
    }
}

nonisolated struct LotteryHistoryGenerator: RandomNumberGenerator {
    private var state: UInt64 = 14_695_981_039_346_656_037

    init(issue: String, historyWords: [UInt64], sampleSeed: UInt64? = nil) {
        mix(UInt64(issue) ?? 0)
        historyWords.withUnsafeBufferPointer { buffer in
            for index in buffer.indices { mix(buffer[index]) }
        }
        if let sampleSeed { mix(sampleSeed) }
    }

    static func append(_ draw: LotteryDraw, to words: inout [UInt64]) {
        words.append(UInt64(draw.issue) ?? 0)
        for red in draw.redNumbers { words.append(UInt64(red)) }
        words.append(UInt64(draw.blueNumber))
    }

    private mutating func mix(_ value: UInt64) {
        state = (state ^ value) &* 1_099_511_628_211
    }

    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}
