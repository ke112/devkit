import AppKit
import SwiftUI

/// 三个图片压缩/转换功能页共用的任务行样式：缩略图 + 名称 + 大小/耗时 + 输出路径 + 状态 + 操作按钮。
struct ImageCompressionTaskRowStyle {
    var stateTitle: String
    var stateColor: Color

    static func label(_ title: String, _ color: Color) -> Self {
        .init(stateTitle: title, stateColor: color)
    }
}

struct ImageCompressionTaskRow: View {
    let thumbnailURL: URL?
    let title: String
    let sizeSummary: String?
    let elapsedText: String?
    let destinationPath: String?
    let state: ImageCompressionTaskRowStyle
    var showsPreviewButton: Bool = false
    var onPreview: (() -> Void)? = nil
    let onRevealSource: () -> Void
    var onRevealDestination: ((URL) -> Void)? = nil

    @State private var showMissingFile = false

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                HStack(spacing: 10) {
                    if let sizeSummary {
                        Text(sizeSummary)
                    }
                    if let elapsedText {
                        Label(elapsedText, systemImage: "clock")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let destinationPath {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption2)
                        Text(destinationPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                Text(state.stateTitle)
                    .font(.caption)
                    .foregroundStyle(state.stateColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if showsPreviewButton, let onPreview {
                Button(action: onPreview) {
                    Image(systemName: "eye")
                }
                .buttonStyle(.borderless)
                .help("压缩前后对比预览")
            }

            if let destinationPath {
                Button {
                    let url = URL(fileURLWithPath: destinationPath)
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        showMissingFile = true
                        return
                    }
                    onRevealDestination?(url)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示结果")
            }

            Button(action: onRevealSource) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示原图")
        }
        .padding(.vertical, 4)
        .alert("文件不存在", isPresented: $showMissingFile) {
            Button("好", role: .cancel) {}
        } message: {
            Text("目标文件可能已被手动删除或移动。")
        }
    }

    @ViewBuilder private var thumbnailView: some View {
        if let thumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
        }
    }
}

/// 统一的拖拽区域与耗时格式化，三个页面共用。
struct ImageCompressionDropArea: View {
    @Binding var isTargeted: Bool
    var title: String = "拖入图片或文件夹，可一次拖入多个"
    var subtitle: String = "PNG、JPG、JPEG、WebP"

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: [8])
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

enum CompressionElapsedFormatter {
    static func seconds(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        if value < 1 { return String(format: "%.0fms", value * 1000) }
        if value < 60 { return String(format: "%.1fs", value) }
        let minutes = Int(value) / 60
        let seconds = value - Double(minutes * 60)
        return String(format: "%dm%.0fs", minutes, seconds)
    }
}
