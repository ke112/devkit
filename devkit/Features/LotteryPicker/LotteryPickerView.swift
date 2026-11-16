import AppKit
import SwiftUI

struct LotteryPickerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: LotterySelection?
    @State private var hasCopied = false

    private let red = Color(red: 0.82, green: 0.12, blue: 0.25)
    private let blue = Color(red: 0.13, green: 0.34, blue: 0.79)

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Text("把选择交给随机")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("6 个红球，1 个蓝球，组成你的一注号码。")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                ticket

                VStack(spacing: 12) {
                    Button(action: generate) {
                        Label(selection == nil ? "随机生成一注" : "再来一注", systemImage: "shuffle")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 216, height: 48)
                            .contentShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(LotteryGenerateButtonStyle(color: red))

                    Text("每次独立随机，号码顺序不影响结果")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                rules
            }
            .frame(maxWidth: 720)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("双色球随机选号")
    }

    private var ticket: some View {
        VStack(spacing: 0) {
            HStack {
                Label("双色球", systemImage: "circle.hexagongrid.fill")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(selection == nil ? "等待选号" : "本次号码")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 30)

            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 14) {
                    HStack(spacing: 12) {
                        ForEach(0..<6) { index in
                            ball(selection?.redNumbers[index], color: red)
                        }
                    }
                    Text("红球 · 6 个")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Text("+")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(.tertiary)
                    .frame(height: 60)

                VStack(spacing: 14) {
                    ball(selection?.blueNumber, color: blue)
                    Text("蓝球 · 1 个")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(selection.map {
                "红球 \($0.redNumbers.map(LotterySelection.formatted).joined(separator: "、"))，蓝球 \(LotterySelection.formatted($0.blueNumber))"
            } ?? "尚未生成号码，点击随机生成一注开始选号")
            .padding(.bottom, 30)

            Rectangle()
                .fill(.clear)
                .frame(height: 1)
                .overlay {
                    Rectangle()
                        .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                }
                .overlay(alignment: .leading) { ticketNotch.offset(x: -37) }
                .overlay(alignment: .trailing) { ticketNotch.offset(x: 37) }

            HStack(alignment: .center) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("单注金额")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text("¥ 2")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                }
                Spacer()
                Button {
                    guard let selection else { return }
                    NSPasteboard.general.clearContents()
                    hasCopied = NSPasteboard.general.setString(selection.formattedNumbers, forType: .string)
                } label: {
                    Label(hasCopied ? "已复制" : "复制号码", systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
            }
            .padding(.top, 22)
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

    private func ball(_ number: Int?, color: Color) -> some View {
        Text(number.map(LotterySelection.formatted) ?? "–")
            .font(.system(size: 24, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(number == nil ? color.opacity(0.6) : .white)
            .frame(width: 60, height: 60)
            .background {
                if number == nil {
                    Circle().fill(color.opacity(0.07))
                    Circle().strokeBorder(color.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                } else {
                    Circle()
                        .fill(.radialGradient(colors: [color.opacity(0.72), color], center: .topLeading, startRadius: 0, endRadius: 62))
                    Circle()
                        .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                }
            }
            .shadow(color: number == nil ? .clear : color.opacity(0.18), radius: 7, y: 4)
            .contentTransition(.numericText())
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

    private func generate() {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.15)) {
            selection = .random()
            hasCopied = false
        }
    }
}

private struct LotteryGenerateButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.15), lineWidth: 1)
            }
    }
}

#Preview {
    LotteryPickerView()
}
