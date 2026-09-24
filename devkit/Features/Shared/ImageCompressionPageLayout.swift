import AppKit
import SwiftUI

// MARK: - 展示模型

/// 三个图片压缩/转换页共用的任务行展示数据；由各页面从自己的 Item 映射而来。
struct ImageTaskDisplayModel: Identifiable, Equatable {
    let id: URL
    let title: String
    let thumbnailURL: URL
    let sizeSummary: String?
    let elapsedText: String?
    let destinationPath: String?
    let stateTitle: String
    let stateColor: Color
    let canPreview: Bool

    var stateStyle: ImageCompressionTaskRowStyle {
        .label(stateTitle, stateColor)
    }
}

/// 三个页面任务条目的共用读取接口；由各页 Item 结构体实现，供展示行统一映射。
protocol ImageCompressionTaskItem {
    var id: URL { get }
    var relativePath: String { get }
    var byteCount: Int64 { get }
    var status: ImageCompressionTaskStatus { get }
    var resultByteCount: Int64? { get }
    var resultPercentage: Double? { get }
    var elapsedSeconds: Double? { get }
    var destinationPath: String? { get }
}

extension ImageTaskDisplayModel {
    /// 各页 Item 的统一映射；`resultLabel` 为结果大小文案（压缩后/转换后），`verb` 用于等待与进行中的状态标题。
    init(item: some ImageCompressionTaskItem, resultLabel: String, verb: String) {
        self.init(
            id: item.id,
            title: item.relativePath,
            thumbnailURL: item.id,
            sizeSummary: Self.sizeSummary(for: item, resultLabel: resultLabel),
            elapsedText: CompressionElapsedFormatter.seconds(item.elapsedSeconds),
            destinationPath: item.destinationPath,
            stateTitle: item.status.title(verb: verb),
            stateColor: item.status.color,
            canPreview: item.status == .success
        )
    }

    private static func sizeSummary(
        for item: some ImageCompressionTaskItem,
        resultLabel: String
    ) -> String? {
        guard let resultByteCount = item.resultByteCount,
              let resultPercentage = item.resultPercentage else {
            return "原图：\(CompressionBytesFormatter.bytes(item.byteCount))"
        }
        return "原图：\(CompressionBytesFormatter.bytes(item.byteCount))  "
            + "\(resultLabel)：\(CompressionBytesFormatter.bytes(resultByteCount))  "
            + "减少：\(CompressionBytesFormatter.percent(resultPercentage))"
    }
}

// MARK: - 共享格式化

enum CompressionBytesFormatter {
    static func bytes(_ value: Int64) -> String {
        if value < 1024 { return "\(value) B" }
        if value < 1024 * 1024 { return String(format: "%.1f KB", Double(value) / 1024) }
        return String(format: "%.2f MB", Double(value) / (1024 * 1024))
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

// MARK: - 共享预览弹窗

struct ImageCompressionPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let imageURL: URL

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(imageURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if let image = NSImage(contentsOf: imageURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "无法读取图片",
                    systemImage: "photo.slash",
                    description: Text(imageURL.path)
                )
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 560)
    }
}

// MARK: - 统一页面布局

/// TinyPNG / WebP / Luban 三个页面共用的骨架：标题、参数行（最低大小 + 自定义参数 + 替换开关）、
/// 拖拽区、已选择行、操作与进度条、内嵌任务列表与预览弹窗。Model 与运行逻辑保持各页独立。
struct ImageCompressionPageLayout<Extras: View>: View {
    let title: String
    let subtitle: String
    var minimumLabel: String = "最低压缩大小"
    var minimumSuffix: String = "KB 以上才压缩"
    var replaceHelp: String
    var dropSubtitle: String
    var stopLabel: String
    var startLabel: String = "开始压缩"

    @Binding var minimumCompressionSizeKB: Int
    @Binding var replaceOriginals: Bool
    @Binding var isDropTargeted: Bool

    let isBusy: Bool
    let isStopping: Bool
    let canRun: Bool
    let selectedCount: Int
    let showsSelectionRow: Bool
    let operationStatus: String
    let operationStatusSystemImage: String
    let isError: Bool
    let hasProgress: Bool
    let progressFraction: Double
    let completedCount: Int
    let totalCount: Int
    let completionPercentage: Int
    let statsText: String?
    let tasks: [ImageTaskDisplayModel]

    var onDrop: ([URL]) -> Bool
    var onClear: () -> Void
    var onStop: () -> Void
    var onChooseFiles: () -> Void
    var onStart: () -> Void

    @ViewBuilder var extras: Extras

    @State private var previewURL: URL?
    @State private var showMissingFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.largeTitle.bold())
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                HStack(spacing: 8) {
                    Text(minimumLabel)
                    TextField("0", value: $minimumCompressionSizeKB, format: .number)
                        .frame(width: 72)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text(minimumSuffix)
                        .foregroundStyle(.secondary)
                }
                .disabled(isBusy)
                .help("小于此大小的图片会跳过，0 表示全部处理")

                extras

                Spacer()

                Toggle("自动替换原图路径", isOn: $replaceOriginals)
                    .toggleStyle(.switch)
                    .help(replaceHelp)
                    .disabled(isBusy)
            }

            ImageCompressionDropArea(isTargeted: $isDropTargeted, subtitle: dropSubtitle)
                .dropDestination(for: URL.self) { urls, _ in
                    onDrop(urls)
                } isTargeted: { isDropTargeted = $0 }

            if showsSelectionRow {
                HStack(spacing: 12) {
                    Label("已选择 \(selectedCount) 张图片", systemImage: "photo.stack")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        onClear()
                    } label: {
                        Label("清空列表", systemImage: "trash")
                    }
                    .disabled(isBusy)
                }
            }

            actionBar

            if !tasks.isEmpty {
                List(tasks) { task in
                    ImageCompressionTaskRow(
                        thumbnailURL: task.thumbnailURL,
                        title: task.title,
                        sizeSummary: task.sizeSummary,
                        elapsedText: task.elapsedText,
                        destinationPath: task.destinationPath,
                        state: task.stateStyle,
                        showsPreviewButton: task.canPreview,
                        onPreview: { previewURL = task.id },
                        onRevealSource: {
                            NSWorkspace.shared.activateFileViewerSelecting([task.id])
                        },
                        onRevealDestination: { url in
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    )
                }
                .listStyle(.inset)
                .frame(minHeight: 200)
            }

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: Binding(
            get: { previewURL.map(ImagePreviewTarget.init) },
            set: { previewURL = $0?.url }
        )) { target in
            ImageCompressionPreviewSheet(imageURL: target.url)
        }
        .alert("文件不存在", isPresented: $showMissingFile) {
            Button("好", role: .cancel) {}
        } message: {
            Text("目标文件可能已被手动删除或移动。")
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: operationStatusSystemImage)
                    .rotationEffect(.degrees(isBusy ? 360 : 0))
                    .animation(
                        isBusy
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: isBusy
                    )
                Text(operationStatus)
            }
            .foregroundStyle(isError ? .red : .secondary)

            if hasProgress {
                HStack(spacing: 8) {
                    ProgressView(value: progressFraction)
                        .frame(width: 110)
                    Text("已完成 \(completedCount)/\(totalCount)（\(completionPercentage)%）")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let statsText {
                        Text(statsText)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            if isBusy {
                Button {
                    onStop()
                } label: {
                    Label(isStopping ? "正在停止" : stopLabel, systemImage: "stop.circle")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(isStopping)
            }

            Button {
                onChooseFiles()
            } label: {
                Label("选择文件或文件夹", systemImage: "folder")
            }
            .disabled(isBusy)

            Button {
                onStart()
            } label: {
                Label(startLabel, systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canRun)
        }
    }
}

private struct ImagePreviewTarget: Identifiable {
    let url: URL
    var id: URL { url }
}
