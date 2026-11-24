import Foundation

nonisolated struct LotteryRecommendationArchive: Codable, Sendable {
    private struct Ticket: Codable, Sendable {
        let recordedAt: Date
        let drawDate: Date
        let selections: [LotterySelection]
    }

    private var issues: [String: [String: Ticket]] = [:]
    private static let localURL = URL.applicationSupportDirectory
        .appending(path: "DevKit/lottery-recommendations-ssq.json")

    static func load() throws -> Self {
        try load(from: localURL)
    }

    static func load(from url: URL) throws -> Self {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return Self()
        }
        let archive = try JSONDecoder().decode(Self.self, from: data)
        for tickets in archive.issues.values {
            for ticket in tickets.values {
                guard ticket.recordedAt < ticket.drawDate, valid(ticket.selections) else {
                    throw ArchiveError.invalidTicket
                }
            }
        }
        return archive
    }

    func selections(for issue: String, strategy: LotteryBacktest.Strategy) -> [LotterySelection]? {
        issues[issue]?[strategy.rawValue]?.selections
    }

    private static func valid(_ selections: [LotterySelection]) -> Bool {
        selections.count == 10 && selections.allSatisfy { selection in
            selection.redNumbers.count == 6 && Set(selection.redNumbers).count == 6
                && selection.redNumbers.allSatisfy { (1...33).contains($0) }
                && (1...16).contains(selection.blueNumber)
        }
    }

    enum ArchiveError: LocalizedError {
        case invalidTicket
        case unavailable

        var errorDescription: String? {
            switch self {
            case .invalidTicket: "推荐档案中的原票须为开奖前记录的 10 注有效号码。"
            case .unavailable: "未能访问本地推荐档案。"
            }
        }
    }

    struct DrawWindow: Equatable {
        let latest: LotteryDraw
        let issue: String
        let schedule: LotteryDrawSchedule

        private init(latest: LotteryDraw, issue: String, schedule: LotteryDrawSchedule) {
            self.latest = latest
            self.issue = issue
            self.schedule = schedule
        }

        @MainActor
        static func following(_ latest: LotteryDraw, now: Date = Date(),
                              fetch: (Date) async throws -> LotteryDrawSchedule = { try await LotteryDrawScheduleService.fetch(now: $0) }
        ) async throws -> Self? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = LotteryDrawScheduleService.beijingTimeZone
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            guard let day = formatter.date(from: latest.date), formatter.string(from: day) == latest.date,
                  day <= now, let tomorrow = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let schedule = try await fetch(tomorrow.addingTimeInterval(-1))
            guard case .issue(let issue) = LotteryTargetIssue.resolve("", latest: latest, nextDrawDate: schedule.date)
            else { return nil }
            return Self(latest: latest, issue: issue, schedule: schedule)
        }
    }

    @MainActor
    static func record(_ selections: [LotterySelection], for issue: String, strategy: LotteryBacktest.Strategy,
                       window: DrawWindow, at url: URL = localURL, now: @escaping () -> Date = Date.init) throws -> [LotterySelection]? {
        guard issue == window.issue, now() < window.schedule.date else { return nil }
        guard valid(selections) else { throw ArchiveError.invalidTicket }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var result: Result<[LotterySelection]?, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { destination in
            result = Result {
                var archive = try load(from: destination)
                if let original = archive.selections(for: issue, strategy: strategy) { return original }
                let recordedAt = now()
                guard recordedAt < window.schedule.date else { return nil }
                let ticket = Ticket(recordedAt: recordedAt, drawDate: window.schedule.date, selections: selections)
                archive.issues[issue, default: [:]][strategy.rawValue] = ticket
                let data = try JSONEncoder().encode(archive)
                guard now() < window.schedule.date else { return nil }
                try data.write(to: destination, options: .atomic)
                return selections
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ArchiveError.unavailable }
        return try result.get()
    }
}
