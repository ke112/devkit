import Foundation
import Testing
@testable import devkit

struct LotteryRecommendationArchiveTests {
    private let rule = #"<span class="lottery-service-intro">每周二、四、日 21:15开奖</span>"#
    private let latest = LotteryDraw(issue: "2026133", date: "2026-11-19",
                                     redNumbers: [7, 10, 11, 14, 21, 26], blueNumber: 13)

    @Test func firstTicketSurvivesReopenAndBackgroundLookup() async throws {
        let window = try await window(after: latest)
        let beforeDraw = window.schedule.date.addingTimeInterval(-1)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let empty = try LotteryRecommendationArchive.load(from: url)
        #expect(empty.selections(for: window.issue, strategy: .coverage) == nil)

        let first = tickets(start: 1)
        let changed = tickets(start: 2)
        func record(_ selections: [LotterySelection], _ strategy: LotteryBacktest.Strategy) throws -> [LotterySelection]? {
            try LotteryRecommendationArchive.record(selections, for: window.issue, strategy: strategy,
                                                    window: window, at: url, now: { beforeDraw })
        }
        #expect(try record(first, .coverage) == first)
        let snapshot = try LotteryRecommendationArchive.load(from: url)
        #expect(try record(changed, .coverage) == first)
        #expect(try record(changed, .spread) == changed)

        let issue = window.issue
        let original = await Task.detached {
            snapshot.selections(for: issue, strategy: .coverage)
        }.value
        #expect(original == first)
        #expect(snapshot.selections(for: issue, strategy: .spread) == nil)
        let reopened = try LotteryRecommendationArchive.load(from: url)
        #expect(reopened.selections(for: issue, strategy: .coverage) == first)
        #expect(reopened.selections(for: issue, strategy: .spread) == changed)
        #expect(reopened.selections(for: latest.issue, strategy: .coverage) == nil)
    }

    @Test func missedDrawIsNeverArchivedAgainstALaterSchedule() async throws {
        let window = try await window(after: latest)
        let deadline = date("2026-11-22T21:15:00+08:00")
        #expect(window.issue == "2026134")
        #expect(window.schedule.date == deadline)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for moment in [deadline, deadline.addingTimeInterval(1), date("2026-11-24T20:00:00+08:00")] {
            #expect(try LotteryRecommendationArchive.record(tickets(start: 1), for: window.issue, strategy: .coverage,
                                                            window: window, at: url, now: { moment }) == nil)
        }
        let beforeDraw = deadline.addingTimeInterval(-1)
        #expect(try LotteryRecommendationArchive.record(tickets(start: 1), for: "2026135", strategy: .coverage,
                                                        window: window, at: url, now: { beforeDraw }) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func requiresTenValidSelectionsAndPreservesUnreadableArchive() async throws {
        let window = try await window(after: latest)
        let beforeDraw = window.schedule.date.addingTimeInterval(-1)
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let valid = tickets(start: 1)
        for invalid in [Array(valid.dropLast()), valid + [valid[0]],
                        Array(repeating: LotterySelection(redNumbers: [1, 1, 2, 3, 4, 5], blueNumber: 17), count: 10)] {
            #expect(throws: LotteryRecommendationArchive.ArchiveError.self) {
                try LotteryRecommendationArchive.record(invalid, for: window.issue, strategy: .coverage,
                                                        window: window, at: url, now: { beforeDraw })
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("broken".utf8)
        try corrupt.write(to: url)
        #expect(throws: DecodingError.self) { try LotteryRecommendationArchive.load(from: url) }
        #expect(throws: DecodingError.self) {
            try LotteryRecommendationArchive.record(valid, for: window.issue, strategy: .coverage,
                                                    window: window, at: url, now: { beforeDraw })
        }
        #expect(try Data(contentsOf: url) == corrupt)
    }

    @Test func bindsFirstIssueOfNewYearToBeijingDrawDate() async throws {
        let december = LotteryDraw(issue: "2026152", date: "2026-12-31",
                                   redNumbers: latest.redNumbers, blueNumber: latest.blueNumber)
        let window = try await window(after: december)
        #expect(window.issue == "2027001")
        #expect(window.schedule.date == date("2027-01-03T21:15:00+08:00"))
    }

    private func window(after latest: LotteryDraw) async throws -> LotteryRecommendationArchive.DrawWindow {
        let result = try await LotteryRecommendationArchive.DrawWindow.following(latest, now: date("2027-01-01T00:00:00+08:00")) { anchor in
            try await LotteryDrawScheduleService.fetch(now: anchor) { _ in Data(rule.utf8) }
        }
        return try #require(result)
    }

    private func tickets(start: Int) -> [LotterySelection] {
        (start..<(start + 10)).map { LotterySelection(redNumbers: [1, 2, 3, 4, 5, 6], blueNumber: $0) }
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "recommendations.json")
    }
}
