import SwiftUI

struct LotteryTrendView: View {
    let draws: [LotteryDraw]
    @State private var ballKind = BallKind.red
    @State private var selectedIssue: String?

    private let plotHeight: CGFloat = 472
    private let issueLabelHeight: CGFloat = 18

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
        VStack(alignment: .leading, spacing: 0) {
            Text("开奖号码")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(height: 18, alignment: .top)

            GeometryReader { geometry in
                let columnWidth = max(40, (geometry.size.width - 32) / 20)
                HStack(alignment: .top, spacing: 0) {
                    ZStack(alignment: .topTrailing) {
                        ForEach(1...ballKind.count, id: \.self) { number in
                            Text(LotterySelection.formatted(number))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .position(x: 16, y: yPosition(number, height: plotHeight))
                        }
                    }
                    .frame(width: 32, height: plotHeight)
                    .accessibilityHidden(true)

                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 0) {
                                ForEach(draws.indices, id: \.self) { index in
                                    trendColumn(at: index, width: columnWidth, height: plotHeight)
                                        .id(draws[index].issue)
                                }
                            }
                        }
                        .onAppear {
                            if let lastIssue = draws.last?.issue {
                                proxy.scrollTo(lastIssue, anchor: .trailing)
                            }
                        }
                    }
                }
            }
            .frame(height: plotHeight + issueLabelHeight + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))

            Text("期号（由旧到新）")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityLabel("\(ballKind.rawValue)历史走势图，共 \(draws.count) 期")
    }

    private func trendColumn(at index: Int, width: CGFloat, height: CGFloat) -> some View {
        let draw = draws[index]
        let numbers = ballKind == .red ? draw.redNumbers : [draw.blueNumber]

        return Button {
            selectedIssue = draw.issue
        } label: {
            VStack(spacing: 0) {
                Canvas { context, size in
                    let middle = size.width / 2
                    var grid = Path()
                    for number in 1...ballKind.count {
                        let y = yPosition(number, height: size.height)
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    grid.move(to: CGPoint(x: middle, y: 0))
                    grid.addLine(to: CGPoint(x: middle, y: size.height))
                    context.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)

                    if ballKind == .blue {
                        let currentY = yPosition(draw.blueNumber, height: size.height)
                        var line = Path()
                        if index > draws.startIndex {
                            let previousY = yPosition(draws[index - 1].blueNumber, height: size.height)
                            line.move(to: CGPoint(x: 0, y: (previousY + currentY) / 2))
                            line.addLine(to: CGPoint(x: middle, y: currentY))
                        }
                        if index + 1 < draws.endIndex {
                            let nextY = yPosition(draws[index + 1].blueNumber, height: size.height)
                            line.move(to: CGPoint(x: middle, y: currentY))
                            line.addLine(to: CGPoint(x: size.width, y: (currentY + nextY) / 2))
                        }
                        context.stroke(line, with: .color(ballKind.color.opacity(0.5)), lineWidth: 1.5)
                    }

                    if selectedIssue == draw.issue {
                        var selection = Path()
                        selection.move(to: CGPoint(x: middle, y: 0))
                        selection.addLine(to: CGPoint(x: middle, y: size.height))
                        context.stroke(selection, with: .color(.secondary.opacity(0.4)),
                                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }

                    for number in numbers {
                        let center = CGPoint(x: middle, y: yPosition(number, height: size.height))
                        let circle = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
                        context.fill(Path(ellipseIn: circle), with: .color(ballKind.color))
                        context.draw(
                            Text(LotterySelection.formatted(number))
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(.white),
                            at: center
                        )
                    }
                }
                .frame(width: width, height: height)
                Text(draw.issue)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: width, height: issueLabelHeight)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("第 \(draw.issue) 期，\(ballKind.rawValue)")
        .accessibilityValue(numbers.map(LotterySelection.formatted).joined(separator: "、"))
    }

    private func yPosition(_ number: Int, height: CGFloat) -> CGFloat {
        height * (1 - (CGFloat(number) - 0.5) / CGFloat(ballKind.count))
    }
}
