import SwiftUI

struct LotteryHistoryView: View {
    @State private var model = LotteryHistoryModel()
    @State private var presentation = Presentation.results
    @State private var refreshID = 0

    private enum Presentation: String, CaseIterable {
        case results = "逐期开奖"
        case trend = "号码走势"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("2025001～2026032")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    HStack(spacing: 8) {
                        Text(model.draws.isEmpty ? "历史开奖号码" : "共 \(model.draws.count) 期")
                        Link("数据来源：上海福彩", destination: LotteryHistoryService.sourceURL)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Picker("展示方式", selection: $presentation) {
                    ForEach(Presentation.allCases, id: \.self) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            .padding(24)

            Divider()

            if let message = model.errorMessage, !model.draws.isEmpty {
                Label("刷新失败：\(message)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
            }

            if model.draws.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch presentation {
                case .results:
                    results
                case .trend:
                    LotteryTrendView(draws: model.draws)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("历史开奖")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    refreshID += 1
                } label: {
                    Label(model.isLoading ? "正在读取" : "刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
                .help("重新读取指定范围内的历史开奖")
            }
        }
        .task(id: refreshID) { await model.load() }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isLoading {
            VStack(spacing: 14) {
                ProgressView()
                Text("正在分批读取历史开奖…")
                    .foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView {
                Label("暂时无法载入历史开奖", systemImage: "wifi.exclamationmark")
            } description: {
                Text(model.errorMessage ?? "点击刷新获取历史开奖号码。")
            } actions: {
                Button("重试") { refreshID += 1 }
            }
        }
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack {
                Text("期号 / 开奖日期")
                Spacer()
                Text("开奖号码（最新在前）")
                    .frame(width: 304, alignment: .leading)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 32)
            .padding(.vertical, 14)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.draws.reversed()) { draw in
                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("第 \(draw.issue) 期")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(draw.date)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            LotteryDrawBalls(draw: draw)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .accessibilityElement(children: .combine)
                        Divider()
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

struct LotteryDrawBalls: View {
    let draw: LotteryDraw

    var body: some View {
        HStack(spacing: 8) {
            ForEach(draw.redNumbers, id: \.self) { number in
                ball(number, color: .red)
            }
            Text("+").foregroundStyle(.tertiary)
            ball(draw.blueNumber, color: .blue)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("红球 \(draw.redNumbers.map(LotterySelection.formatted).joined(separator: "、"))，蓝球 \(LotterySelection.formatted(draw.blueNumber))")
    }

    private func ball(_ number: Int, color: Color) -> some View {
        Text(LotterySelection.formatted(number))
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(color.gradient, in: Circle())
    }
}
