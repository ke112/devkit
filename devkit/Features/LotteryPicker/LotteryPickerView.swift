import AppKit
import SwiftUI

struct LotteryPickerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var model = LotteryHistoryModel()
    @State private var forecast: LotteryForecast?
    @State private var tickets: [LotterySelection] = []
    @State private var copiedIndex: Int?
    @State private var refreshID = 0
    @State private var schedule: LotteryDrawSchedule?
    @State private var scheduleUnavailable = false
    @State private var isPrizeRulesPresented = false

    private let red = Color(red: 0.82, green: 0.12, blue: 0.25)
    private let blue = Color(red: 0.13, green: 0.34, blue: 0.79)

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Text("下期参考号码")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    scheduleHeader
                }

                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                if let forecast {
                    HStack {
                        Text("推算结果").font(.headline)
                        Spacer()
                        Button {
                            if tickets.count > 1 {
                                if copiedIndex == tickets.count - 1 { copiedIndex = nil }
                                tickets.removeLast()
                            }
                        } label: { Image(systemName: "minus") }
                        .disabled(tickets.count <= 1)
                        .accessibilityLabel("减少一注")
                        Text("\(tickets.count) 注").monospacedDigit()
                        Button { tickets.append(forecast.next()) } label: { Image(systemName: "plus") }
                            .accessibilityLabel("增加一注")
                    }
                    ticket(forecast: forecast)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("每注至少 4 个红球与上期不同，各注独立生成。").font(.callout)
                        Text(forecast.summary).font(.callout)
                        Text("推算使用全部 \(model.draws.count) 期历史数据 · 预热 \(model.draws.count - forecast.evaluated) 期 · 逐期回测 \(forecast.evaluated) 期")
                        if forecast.evaluated > 0 {
                            Text("新号规则覆盖 \(forecast.covered)/\(forecast.evaluated) 期（\(String(format: "%.2f%%", 100 * Double(forecast.covered) / Double(forecast.evaluated)))）")
                            if forecast.covered > 0 {
                                Text("在规则覆盖的期次内，相对同规则随机选号的平均对数得分差 \(String(format: "%+.4f", forecast.logGain / Double(forecast.covered)))（正值更好）")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if model.isLoading {
                    ProgressView("正在读取历史开奖…")
                } else if model.errorMessage != nil {
                    Button("重试") { refreshID += 1 }
                }

                rules
            }
            .frame(maxWidth: 720)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("双色球选号")
        .task(id: refreshID) { await model.load() }
        .task(id: refreshID) { await updateSchedule() }
        .onChange(of: model.draws, initial: true) {
            guard !model.draws.isEmpty else { return }
            let updated = LotteryForecast(draws: model.draws)
            forecast = updated
            copiedIndex = nil
            tickets = (0..<max(1, tickets.count)).map { updated.next(mode: $0 == 0 ? .highestScore : .sample) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { refreshID += 1 } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(model.isLoading)
                    .help("检查新增开奖期数并更新下次开奖时间")
            }
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    LotteryHistoryView(model: model)
                } label: {
                    Label("历史开奖", systemImage: "chart.xyaxis.line")
                }
                .help("查看历史开奖号码与走势")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isPrizeRulesPresented = true
                } label: {
                    Label("中奖规则", systemImage: "list.bullet.rectangle")
                }
                .help("查看奖级、中奖条件和单注奖金")
            }
        }
        .sheet(isPresented: $isPrizeRulesPresented) {
            LotteryPrizeRulesView()
        }
    }

    private var scheduleHeader: some View {
        Label {
            Text("下次开奖 · \(schedule?.displayText ?? (scheduleUnavailable ? "暂时无法获取，可点击刷新重试" : "正在获取…"))")
        } icon: {
            Image(systemName: "calendar.badge.clock")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func updateSchedule() async {
        while !Task.isCancelled {
            scheduleUnavailable = false
            if let schedule, schedule.date <= Date() { self.schedule = nil }
            do {
                let updated = try await LotteryDrawScheduleService.fetch()
                try Task.checkCancellation()
                schedule = updated
                try await Task.sleep(for: .seconds(max(0, updated.nextRefreshDate.timeIntervalSinceNow)))
            } catch {
                guard !Task.isCancelled else { return }
                schedule = nil
                scheduleUnavailable = true
                return
            }
        }
    }

    private func ticket(forecast: LotteryForecast) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("双色球", systemImage: "circle.hexagongrid.fill")
                .font(.system(size: 15, weight: .semibold))
            LazyVStack(spacing: 0) {
                ForEach(tickets.indices, id: \.self) { index in
                    let selection = tickets[index]
                    HStack(spacing: 12) {
                        Text("第 \(index + 1) 注")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        LotteryDrawBalls(redNumbers: selection.redNumbers, blueNumber: selection.blueNumber)
                        Spacer()
                        Button {
                            withAnimation(reduceMotion ? nil : .default) {
                                tickets[index] = forecast.next(mode: index == 0 ? .highestScore : .sample)
                                if copiedIndex == index { copiedIndex = nil }
                            }
                        } label: { Image(systemName: "shuffle") }
                        .accessibilityLabel("重新推算第 \(index + 1) 注")
                        .help("重新推算这一注")
                        Button {
                            NSPasteboard.general.clearContents()
                            copiedIndex = NSPasteboard.general.setString(selection.formattedNumbers, forType: .string) ? index : nil
                        } label: { Image(systemName: copiedIndex == index ? "checkmark" : "doc.on.doc") }
                        .accessibilityLabel("复制第 \(index + 1) 注号码")
                        .help(copiedIndex == index ? "已复制" : "复制这一注")
                    }
                    .padding(.vertical, 10)
                    if index < tickets.count - 1 { Divider() }
                }
            }
            Rectangle()
                .fill(.clear)
                .frame(height: 1)
                .overlay {
                    Rectangle()
                        .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                }
                .overlay(alignment: .leading) { ticketNotch.offset(x: -37) }
                .overlay(alignment: .trailing) { ticketNotch.offset(x: 37) }

            HStack(alignment: .firstTextBaseline) {
                Text("每注 ¥2").foregroundStyle(.secondary)
                Spacer()
                Text("合计 ¥\(tickets.count * 2)").font(.headline)
            }
        }
        .padding(28)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(.primary.opacity(0.07), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.12 : 0.04), radius: 18, y: 8)
    }

    private var ticketNotch: some View {
        Circle()
            .fill(Color(nsColor: .windowBackgroundColor))
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
    }

    private var rules: some View {
        HStack(alignment: .top, spacing: 32) {
            rule(title: "红球怎么选", detail: "01～33 中选 6 个，不重复", color: red)
            Divider()
            rule(title: "蓝球怎么选", detail: "01～16 中选 1 个", color: blue)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }

    private func rule(title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(color).frame(width: 7, height: 7).padding(.top, 5)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

}

#Preview {
    LotteryPickerView()
}
