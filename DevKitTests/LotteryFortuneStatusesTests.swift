import Foundation
import Testing
@testable import devkit

struct LotteryFortuneStatusesTests {
    private nonisolated static func draw(_ issue: String) -> LotteryDraw {
        LotteryDraw(issue: issue, date: "2026-02-01", redNumbers: [7, 13, 19, 22, 26, 32], blueNumber: 1)
    }

    private nonisolated static func row(_ issue: String, fields: String) -> String {
        #"{"code":"\#(issue)","date":"2026-02-01(日)","red":"07,13,19,22,26,32","blue":"01",\#(fields)}"#
    }

    private nonisolated static func page(_ rows: [String]) -> Data {
        Data(#"{"state":0,"result":[\#(rows.joined(separator: ","))]}"#.utf8)
    }

    @Test func matchesDrawsAndKeepsUnverifiedIssuesMissing() async throws {
        let active = #""fyjMoney":"5","fyjCount":"123""#
        let rows = [
            Self.row("2026014", fields: active),
            Self.row("2026015", fields: #""fyjMoney":"","fyjCount":"""#),
            Self.row("2026016", fields: #""fyjMoney":5,"fyjCount":0"#),
            Self.row("2026017", fields: #""fyjMoney":0,"fyjCount":"0""#),
            Self.row("2026018", fields: active).replacingOccurrences(of: "02-01", with: "02-02"),
            Self.row("2026019", fields: active).replacingOccurrences(of: "07,13", with: "08,13"),
            Self.row("2026020", fields: active).replacingOccurrences(of: #""01""#, with: #""02""#),
            Self.row("2026021", fields: #""fyjMoney":5"#),
            Self.row("2026022", fields: #""fyjMoney":0,"fyjCount":12"#),
            Self.row("2026023", fields: #""fyjMoney":null,"fyjCount":null"#),
            Self.row("2026024", fields: active), Self.row("2026024", fields: active),
            Self.row("2026100", fields: active), "null"
        ]
        let draws = (2026013...2026025).reversed().map { Self.draw(String($0)) }
        let statuses = try await LotteryPrizeAnnouncement.fortuneStatuses(for: draws + [Self.draw("2026014")]) {
            first, last, limit in
            #expect(first == "2026014" && last == "2026025" && limit == 100)
            return Self.page(rows)
        }
        #expect(statuses == ["2026013": false, "2026014": true, "2026015": false, "2026016": true, "2026017": false])
    }

    @Test func batchesByIssueSpanAndContinuesAfterFailedPage() async throws {
        let oldDraws = (2020001...2020100).map { Self.draw(String($0)) }
        let eligible = (2026014...2026134).map { Self.draw(String($0)) }
        let statuses = try await LotteryPrizeAnnouncement.fortuneStatuses(for: oldDraws + eligible) { first, last, limit in
            #expect(limit == 100)
            if first == "2026014" {
                #expect(last == "2026113")
                throw URLError(.timedOut)
            }
            #expect(first == "2026114" && last == "2026134")
            return Self.page([Self.row("2026134", fields: #""fyjMoney":"","fyjCount":"""#)])
        }
        #expect(statuses.count == oldDraws.count + 1)
        #expect(statuses["2026134"] == false)
        #expect(statuses["2026014"] == nil)
    }

    @Test func noRequestBeforeFirstFortuneIssue() async throws {
        let draw = Self.draw("2026013")
        let statuses = try await LotteryPrizeAnnouncement.fortuneStatuses(for: [draw]) { _, _, _ in
            Issue.record("首期前不应请求开奖公告")
            return Self.page([])
        }
        #expect(statuses == [draw.issue: false])
    }

    @Test func cancellationPropagatesEvenWhenLoaderReturnsData() async {
        let task = Task {
            try await LotteryPrizeAnnouncement.fortuneStatuses(for: [Self.draw("2026014")]) { _, _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return Self.page([])
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
