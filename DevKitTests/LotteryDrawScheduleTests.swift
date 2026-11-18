import Foundation
import Testing
@testable import devkit

struct LotteryDrawScheduleTests {
    private let intro = #"<span class="lottery-service-intro"><i>每周二、四、日 21:15开奖</i><i>发布渠道：中国教育电视台一套</i></span>"#

    @Test func readsOfficialRuleAndDisplaysBeijingTime() async throws {
        let result = try await fetch("2026-11-18T12:00:00+08:00", html: intro)
        #expect(result.date == date("2026-11-19T21:15:00+08:00"))
        #expect(result.nextRefreshDate == result.date)
        #expect(result.displayText.contains("21:15"))
        #expect(result.displayText.contains("北京时间"))
        #expect(result.displayText.contains("预计"))
        #expect(result.displayText.contains("休市"))
    }

    @Test(arguments: [
        ("2026-11-19T21:14:59+08:00", "2026-11-19T21:15:00+08:00"),
        ("2026-11-19T21:15:00+08:00", "2026-11-22T21:15:00+08:00"),
        ("2026-11-19T23:59:59+08:00", "2026-11-22T21:15:00+08:00"),
        ("2026-11-20T00:00:00+08:00", "2026-11-22T21:15:00+08:00"),
        ("2026-12-31T21:15:00+08:00", "2027-01-03T21:15:00+08:00")
    ])
    func selectsStrictlyFutureDraw(now: String, expected: String) async throws {
        let result = try await fetch(now, html: intro)
        #expect(result.date == date(expected))
        #expect(result.nextRefreshDate == result.date)
    }

    @Test func usesChangedOnlineWeekdayAndTime() async throws {
        let html = #"<span class="lottery-service-intro"><i>每周一、三 20:05开奖</i></span>"#
        let result = try await fetch("2026-11-18T19:00:00+08:00", html: html)
        #expect(result.date == date("2026-11-18T20:05:00+08:00"))
    }

    @Test(arguments: [
        "<html>每周二、四、日 21:15开奖</html>",
        #"<span class="lottery-service-intro">暂停开奖</span>"#,
        #"<span class="lottery-service-intro">每周二 25:15开奖</span>"#,
        #"<span class="lottery-service-intro">每周二 21:60开奖</span>"#
    ])
    func rejectsMissingOrInvalidRules(_ html: String) async {
        await #expect(throws: LotteryDrawScheduleError.self) {
            try await fetch("2026-11-18T12:00:00+08:00", html: html)
        }
    }

    @Test func propagatesNetworkFailure() async {
        await #expect(throws: URLError.self) {
            try await LotteryDrawScheduleService.fetch(now: date("2026-11-18T12:00:00+08:00")) { _ in
                throw URLError(.notConnectedToInternet)
            }
        }
    }

    private func fetch(_ now: String, html: String) async throws -> LotteryDrawSchedule {
        try await LotteryDrawScheduleService.fetch(now: date(now)) { url in
            #expect(url == LotteryHistoryService.sourceURL)
            return Data(html.utf8)
        }
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
