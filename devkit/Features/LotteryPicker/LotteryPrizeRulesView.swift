import SwiftUI

struct LotteryPrizeRulesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("中奖规则")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("红球、蓝球数量均指命中个数，号码顺序不限。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("关闭中奖规则")
                .accessibilityLabel("关闭中奖规则")
            }

            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 0) {
                    GridRow {
                        Text("奖级").frame(width: 64, alignment: .leading)
                        Text("中奖条件").frame(maxWidth: .infinity, alignment: .leading)
                        Text("单注奖金").frame(width: 104, alignment: .trailing)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)

                    prizeRow("一等奖", conditions: [("6", "1")], bonus: "浮动", isFloating: true)
                    prizeRow("二等奖", conditions: [("6", "0")], bonus: "浮动", isFloating: true)
                    prizeRow("三等奖", conditions: [("5", "1")], bonus: "3,000 元")
                    prizeRow("四等奖", conditions: [("5", "0"), ("4", "1")], bonus: "200 元")
                    prizeRow("五等奖", conditions: [("4", "0"), ("3", "1")], bonus: "10 元")
                    prizeRow("六等奖", conditions: [("0～2", "1")], bonus: "5 元")
                    prizeRow("福运奖", conditions: [("3", "0")], bonus: "5 元")
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.primary.opacity(0.07), lineWidth: 1)
                }
            }

            HStack(alignment: .center, spacing: 20) {
                Text("福运奖在奖池达到 15 亿元时开设，直至某期开奖后奖池低于 3 亿元。\n一、二等奖为浮动奖金，福运奖与活动派奖以当期开奖公告为准。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("知道了") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 620, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func prizeRow(
        _ title: String,
        conditions: [(red: String, blue: String)],
        bonus: String,
        isFloating: Bool = false
    ) -> some View {
        Divider().gridCellUnsizedAxes(.horizontal)
        GridRow {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(conditions.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        matchBadge("\(conditions[index].red) 红", color: .red)
                        Text("+").foregroundStyle(.tertiary)
                        matchBadge("\(conditions[index].blue) 蓝", color: .blue)
                        if conditions.count > 1 && index == 0 {
                            Text("或")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(conditions.map { "\($0.red) 红球加 \($0.blue) 蓝球" }.joined(separator: "，或 "))

            Text(bonus)
                .font(.system(size: isFloating ? 14 : 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(width: 104, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    private func matchBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.09), in: Capsule())
    }
}

#Preview {
    LotteryPrizeRulesView()
}
