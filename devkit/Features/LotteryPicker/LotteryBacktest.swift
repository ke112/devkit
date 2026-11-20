import Foundation

enum LotteryTargetIssue: Equatable {
    case waitingForHistory
    case invalidFormat
    case outOfRange(last: String?)
    case issue(String)

    static let first = String(LotteryHistoryService.startIssue + 1)

    static func resolve(_ input: String, latest: LotteryDraw?, nextDrawDate: Date?) -> Self {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            guard value.utf8.count == 7, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  !value.hasSuffix("000") else { return .invalidFormat }
            guard value >= first else { return .outOfRange(last: nil) }
        }
        guard let latest, let latestIssue = Int(latest.issue) else { return .waitingForHistory }
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
    let issue: String
    let historyCount: Int
    let lastHistoryIssue: String
    let portfolio: LotteryPortfolio
    let draw: LotteryDraw?

    init?(issue: String, draws: [LotteryDraw]) {
        let history = draws.prefix { $0.issue < issue }
        let targetDraw = draws.dropFirst(history.count).first
        guard history.first?.issue == String(LotteryHistoryService.startIssue),
              let last = history.last,
              let issueNumber = Int(issue),
              issueNumber.isMultiple(of: 1_000) == false,
              issueNumber % 1_000 == 1 || Int(last.issue) == issueNumber - 1,
              targetDraw == nil || targetDraw?.issue == issue else { return nil }

        var generator = LotteryHistoryGenerator(issue: issue, history: history)
        portfolio = LotteryPortfolio(using: &generator)
        self.issue = issue
        historyCount = history.count
        lastHistoryIssue = last.issue
        draw = targetDraw
    }
}

private struct LotteryHistoryGenerator: RandomNumberGenerator {
    private var state: UInt64 = 14_695_981_039_346_656_037

    init(issue: String, history: ArraySlice<LotteryDraw>) {
        mix(UInt64(issue) ?? 0)
        for draw in history {
            mix(UInt64(draw.issue) ?? 0)
            for red in draw.redNumbers { mix(UInt64(red)) }
            mix(UInt64(draw.blueNumber))
        }
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
