import Foundation
import Testing
@testable import devkit

struct LotteryBacktestTests {
    private let first = LotteryDraw(issue: "2020001", date: "2020-01-02",
                                    redNumbers: [1, 2, 3, 4, 5, 6], blueNumber: 7)
    private let second = LotteryDraw(issue: "2020002", date: "2020-01-05",
                                     redNumbers: [4, 9, 14, 15, 16, 29], blueNumber: 11)

    @Test func targetAndLaterDrawsCannotChangeTheTickets() throws {
        let changedDraw = LotteryDraw(issue: second.issue, date: second.date,
                                      redNumbers: [3, 5, 6, 11, 18, 27], blueNumber: 2)
        let later = LotteryDraw(issue: "2020003", date: "2020-01-07",
                                redNumbers: [1, 4, 10, 12, 23, 30], blueNumber: 8)
        let pending = try #require(LotteryBacktest(issue: second.issue, draws: [first]))
        let published = try #require(LotteryBacktest(issue: second.issue, draws: [first, second, later]))
        let replaced = try #require(LotteryBacktest(issue: second.issue, draws: [first, changedDraw, later]))

        #expect(pending.draw == nil)
        #expect(published.draw == second)
        #expect(replaced.draw == changedDraw)
        #expect(published.historyCount == 1)
        #expect(published.lastHistoryIssue == first.issue)
        #expect(published.portfolio.selections.count == 10)
        #expect(pending.portfolio.selections == published.portfolio.selections)
        #expect(replaced.portfolio.selections == published.portfolio.selections)

        let changedHistory = LotteryDraw(issue: first.issue, date: first.date,
                                         redNumbers: first.redNumbers, blueNumber: 14)
        let withDifferentHistory = try #require(LotteryBacktest(issue: second.issue, draws: [changedHistory, second]))
        #expect(withDifferentHistory.portfolio.selections != published.portfolio.selections)
        #expect(LotteryBacktest(issue: later.issue, draws: [first, later]) == nil)
    }

    @Test func resolvesUpcomingExplicitAndYearRolloverIssues() throws {
        #expect(LotteryTargetIssue.resolve("", latest: second, nextDrawDate: nil) == .issue("2020003"))
        #expect(LotteryTargetIssue.resolve(" 2020002 ", latest: second, nextDrawDate: nil) == .issue("2020002"))
        #expect(LotteryTargetIssue.resolve("2020001", latest: second, nextDrawDate: nil) == .outOfRange(last: nil))
        #expect(LotteryTargetIssue.resolve("2020004", latest: second, nextDrawDate: nil) == .outOfRange(last: "2020003"))
        #expect(LotteryTargetIssue.resolve("2020000", latest: second, nextDrawDate: nil) == .invalidFormat)
        #expect(LotteryTargetIssue.resolve("", latest: nil, nextDrawDate: nil) == .waitingForHistory)

        let last = LotteryDraw(issue: "2026152", date: "2026-12-31", redNumbers: first.redNumbers, blueNumber: 1)
        let next = try #require(ISO8601DateFormatter().date(from: "2027-01-03T21:15:00+08:00"))
        #expect(LotteryTargetIssue.resolve("", latest: last, nextDrawDate: next) == .issue("2027001"))
    }

    @Test func readsAnnouncedAmountsAndRejectsMismatchedDraws() throws {
        let draw = LotteryDraw(issue: "2026133", date: "2026-11-19",
                               redNumbers: [7, 10, 11, 14, 21, 26], blueNumber: 13)
        let html = """
        <h1>“双色球” 第2026133期开奖公告</h1>
        <p>开奖日期：<time datetime="2026-11-19">2026-11-19</time></p>
        <div class="balls balls-ssq">
          <span class="ball red">7</span><span class="ball red">10</span><span class="ball red">11</span>
          <span class="ball red">14</span><span class="ball red">21</span><span class="ball red">26</span>
          <span class="ball blue">13</span>
        </div>
        <table class="lottery-table">
        <tr><td>一等奖</td><td>17</td><td>5,882,352.00</td></tr>
        <tr><td>二等奖</td><td>140</td><td>152892.00</td></tr>
        <tr><td>三等奖</td><td>1841</td><td>3000</td></tr>
        <tr><td>四等奖</td><td>96282</td><td>200</td></tr>
        <tr><td>五等奖</td><td>1744620</td><td>10</td></tr>
        <tr><td>六等奖</td><td>14045153</td><td>5</td></tr>
        <tr><td>六等奖翻番奖</td><td>9354556</td><td>5</td></tr>
        </table>
        """
        let notice = try LotteryPrizeAnnouncement.parse(html, for: draw)
        let floating = LotteryTicketResult(selection: .init(redNumbers: draw.redNumbers, blueNumber: 13),
                                           draw: draw, announcement: notice)
        let sixth = LotteryTicketResult(selection: .init(redNumbers: first.redNumbers, blueNumber: 13),
                                        draw: draw, announcement: notice)
        let notWon = LotteryTicketResult(selection: .init(redNumbers: [1, 2, 3, 7, 10, 11], blueNumber: 1),
                                         draw: draw, announcement: notice)
        #expect(floating.prize == .first)
        #expect(floating.amount == 5_882_352)
        #expect(sixth.prize == .sixth)
        #expect(sixth.amount == 5)
        #expect(sixth.promotion == 5)
        #expect(notWon.prize == nil)
        #expect(LotteryPrize.matching(red: 3, blue: false, goodFortune: true) == .goodFortune)
        #expect(LotteryPrize.matching(red: 3, blue: true, goodFortune: true) == .fifth)
        #expect(throws: URLError.self) { try LotteryPrizeAnnouncement.parse(html, for: second) }
        #expect(throws: URLError.self) {
            try LotteryPrizeAnnouncement.parse(html.replacingOccurrences(of: ">13</span>", with: ">12</span>"), for: draw)
        }
    }
}
