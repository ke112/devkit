import Foundation
import Testing
@testable import devkit

struct LotteryHistoryTests {
    @Test func parsesOfficialTableWithOtherColumnsAndSortedRedNumbers() throws {
        let html = """
        <table><thead><tr><th>期号</th></tr></thead><tbody>
        <tr><td>2026032</td><td>2026-03-24(二)</td>
        <td><span class="lottery-history-balls lottery-history-balls--red"><i>01</i><i>03</i><i>11</i><i>18</i><i>31</i><i>33</i></span></td>
        <td><span class="lottery-history-balls lottery-history-balls--blue"><i>02</i></span></td>
        <td>392,702,390.00</td><td>6</td><td>7,330,318.00</td></tr>
        </tbody></table>
        """
        #expect(try LotteryHistoryService.parse(html) == [
            LotteryDraw(issue: "2026032", date: "2026-03-24", redNumbers: [1, 3, 11, 18, 31, 33], blueNumber: 2)
        ])
    }

    @Test(arguments: [
        ([1, 1, 3, 4, 5, 6], 1, "2025-01-01"),
        ([0, 2, 3, 4, 5, 6], 1, "2025-01-01"),
        ([1, 2, 3, 4, 5, 34], 1, "2025-01-01"),
        ([1, 2, 3, 4, 5], 1, "2025-01-01"),
        ([1, 2, 3, 4, 5, 6], 17, "2025-01-01"),
        ([1, 2, 3, 4, 5, 6], 0, "2025-01-01"),
        ([1, 2, 3, 4, 5, 6], 1, "2025-02-30"),
        ([1, 2, 3, 4, 5, 6], 1, "2026-01-01"),
    ])
    func rejectsInvalidNumbersAndDates(reds: [Int], blue: Int, date: String) {
        let draw = LotteryDraw(issue: "2025001", date: date, redNumbers: reds, blueNumber: blue)
        #expect(throws: LotteryHistoryError.self) {
            try LotteryHistoryService.parse(Self.html([draw]))
        }
    }

    @Test func rejectsChangedOrEmptyWebsiteResponse() {
        #expect(throws: LotteryHistoryError.self) { try LotteryHistoryService.parse("<html>系统维护中</html>") }
        #expect(throws: LotteryHistoryError.self) {
            try LotteryHistoryService.parse("<tr><td>2025001</td><td>2025-01-01</td></tr>")
        }
    }

    @Test func fetchesPastTheHundredRowLimitAcrossTheYearBoundary() async throws {
        let expected = Self.fullHistory
        var requestedUpperIssues: [Int] = []
        let actual = try await LotteryHistoryService.fetch { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.first(where: { $0.name == "start_issue" })?.value == "2025001")
            #expect(items.first(where: { $0.name == "limit" })?.value == "100")
            let upperText = try #require(items.first(where: { $0.name == "end_issue" })?.value)
            let upper = try #require(Int(upperText))
            requestedUpperIssues.append(upper)
            return Self.html(Array(expected.filter { Int($0.issue)! <= upper }.suffix(100).reversed()))
        }
        #expect(actual == expected)
        #expect(actual.count == 183)
        #expect(requestedUpperIssues == [2026032, 2025083])
    }

    @Test func rejectsMissingOrDuplicateIssuesInsteadOfPublishingPartialHistory() async {
        let missing = Self.fullHistory.filter { $0.issue != "2025050" }
        await #expect(throws: LotteryHistoryError.self) {
            try await LotteryHistoryService.fetch { url in
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let upperText = try #require(items.first(where: { $0.name == "end_issue" })?.value)
                let upper = try #require(Int(upperText))
                return Self.html(Array(missing.filter { Int($0.issue)! <= upper }.suffix(100)))
            }
        }
        await #expect(throws: LotteryHistoryError.self) {
            try await LotteryHistoryService.fetch { _ in
                Self.html([Self.fullHistory[0], Self.fullHistory[0]])
            }
        }
    }

    @Test func refreshFailureKeepsTheLastCompleteResult() async {
        let model = LotteryHistoryModel()
        await model.load { Self.fullHistory }
        await model.load { throw URLError(.notConnectedToInternet) }
        #expect(model.draws == Self.fullHistory)
        #expect(model.errorMessage != nil)
        #expect(!model.isLoading)
    }

    private static var fullHistory: [LotteryDraw] {
        (1...151).map { draw(year: 2025, index: $0) }
            + (1...32).map { draw(year: 2026, index: $0) }
    }

    private static func draw(year: Int, index: Int) -> LotteryDraw {
        LotteryDraw(issue: String(year * 1000 + index), date: "\(year)-01-01", redNumbers: [1, 3, 11, 18, 31, 33], blueNumber: 2)
    }

    private static func html(_ draws: [LotteryDraw]) -> String {
        "<table><tbody>" + draws.map { draw in
            """
            <tr><td>\(draw.issue)</td><td>\(draw.date)(二)</td>
            <td><span class='lottery-history-balls--red lottery-history-balls'>\(draw.redNumbers.map { "<i>\($0)</i>" }.joined())</span></td>
            <td><span class='lottery-history-balls--blue'><i>\(draw.blueNumber)</i></span></td></tr>
            """
        }.joined() + "</tbody></table>"
    }
}
