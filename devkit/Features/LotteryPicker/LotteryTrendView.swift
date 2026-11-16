import Charts
import SwiftUI

struct LotteryTrendView: View {
    let draws: [LotteryDraw]
    @State private var ballKind = BallKind.red
    @State private var selectedIssue: String?

    private enum BallKind: String, CaseIterable {
        case red = "红球"
        case blue = "蓝球"

        var count: Int { self == .red ? 33 : 16 }
        var color: Color { self == .red ? .red : .blue }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(ballKind.rawValue)号码走势")
                            .font(.system(size: 18, weight: .semibold))
                        Text("横轴为期号，纵轴为号码；左右滚动查看全部 \(draws.count) 期。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("球种", selection: $ballKind) {
                        ForEach(BallKind.allCases, id: \.self) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
                }

                chart
                    .frame(height: 530)

                if let draw = draws.first(where: { $0.issue == selectedIssue }) {
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("第 \(draw.issue) 期").fontWeight(.semibold)
                            Text(draw.date).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                        Spacer()
                        LotteryDrawBalls(draw: draw)
                    }
                    .padding(14)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    Text("点击图中某一期查看完整号码。红球每期 6 个标记，蓝球按开奖顺序连线。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(draws) { draw in
                if ballKind == .blue {
                    LineMark(x: .value("期号", draw.issue), y: .value("号码", draw.blueNumber))
                        .foregroundStyle(ballKind.color.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                ForEach(ballKind == .red ? draw.redNumbers : [draw.blueNumber], id: \.self) { number in
                    PointMark(x: .value("期号", draw.issue), y: .value("号码", number))
                        .foregroundStyle(ballKind.color)
                        .symbolSize(190)
                        .annotation(position: .overlay) {
                            Text(LotterySelection.formatted(number))
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .fixedSize()
                        }
                        .accessibilityLabel("第 \(draw.issue) 期，\(ballKind.rawValue)")
                        .accessibilityValue(LotterySelection.formatted(number))
                }
            }
            if let selectedIssue {
                RuleMark(x: .value("期号", selectedIssue))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartXScale(domain: draws.map(\.issue))
        .chartYScale(domain: 0.5...(Double(ballKind.count) + 0.5))
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: 20)
        .chartScrollPosition(initialX: draws[max(0, draws.count - 20)].issue)
        .chartXSelection(value: $selectedIssue)
        .chartGesture { proxy in
            SpatialTapGesture().onEnded { event in
                proxy.selectXValue(at: event.location.x)
            }
        }
        .chartXAxis {
            AxisMarks(values: draws.map(\.issue)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisTick()
                AxisValueLabel().font(.system(size: 9, design: .monospaced))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: Array(1...ballKind.count)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let number = value.as(Int.self) {
                        Text(LotterySelection.formatted(number))
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
            }
        }
        .chartXAxisLabel("期号（由旧到新）", alignment: .trailing)
        .chartYAxisLabel("开奖号码")
        .accessibilityLabel("\(ballKind.rawValue)历史走势图，共 \(draws.count) 期")
    }
}
