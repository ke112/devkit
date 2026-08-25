import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct TinyPNGView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var model = TinyPNGModel()
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    @State private var isStatusPresented = false
    @State private var isLeaveConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TinyPNG 图片压缩")
                    .font(.largeTitle.bold())
                Text("默认自动替换原图，关闭开关后写入同级时间戳文件夹")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            TinyPNGDropArea(isTargeted: $isDropTargeted)
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                return model.select(url: url)
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }

            selectionSummary

            if model.selectedURL != nil {
                HStack(spacing: 12) {
                    Label("已选择 \(model.imageItems.count) 张图片", systemImage: "photo.stack")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("自动替换原图", isOn: $model.replaceOriginals)
                        .toggleStyle(.switch)
                        .help("开启后压缩成功的图片会替换原文件；关闭后生成同级输出文件夹")
                        .disabled(model.isRunning || model.isScanning)
                    Button {
                        isStatusPresented = true
                    } label: {
                        Label("上传状态", systemImage: "list.bullet.rectangle")
                    }
                    .disabled(model.imageItems.isEmpty)
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: model.operationStatusSystemImage)
                        .rotationEffect(.degrees(model.isRunning || model.isScanning ? 360 : 0))
                        .animation(
                            model.isRunning || model.isScanning
                                ? .linear(duration: 1).repeatForever(autoreverses: false)
                                : .default,
                            value: model.isRunning || model.isScanning
                        )
                    Text(model.operationStatus)
                }
                .foregroundStyle(model.isError ? .red : .secondary)

                if model.hasProgress {
                    HStack(spacing: 8) {
                        ProgressView(value: model.progressFraction)
                            .frame(width: 110)
                        Text("已完成 \(model.completedImageCount)/\(model.imageItems.count)（\(model.completionPercentage)%）")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let stats = model.compressionStats {
                            Text(
                                "总计：\(TinyPNGFormat.bytes(stats.beforeBytes)) → "
                                    + "\(TinyPNGFormat.bytes(stats.afterBytes)) "
                                    + "（减少 \(TinyPNGFormat.percent(stats.savedPercentage))）"
                            )
                            .font(.caption)
                            .foregroundStyle(.green)
                        }
                    }
                }

                Spacer()

                if model.isRunning || model.isScanning {
                    Button {
                        model.stop()
                    } label: {
                        Label(
                            model.isStopping ? "正在停止" : "停止压缩",
                            systemImage: "stop.circle"
                        )
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(model.isStopping)
                }

                Button {
                    isImporterPresented = true
                } label: {
                    Label("选择文件或文件夹", systemImage: "folder")
                }
                .disabled(model.isRunning || model.isScanning)

                Button {
                    model.run()
                } label: {
                    Label("开始压缩", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRun)
            }

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("TinyPNG 图片压缩")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    requestLeave()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("返回")
                .accessibilityLabel("返回")
            }
        }
        .onDisappear {
            if (model.isRunning && !model.isStopping) || model.isScanning {
                model.stop()
            }
        }
        .sheet(isPresented: $isStatusPresented) {
            TinyPNGStatusSheet(model: model)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.item, .folder, .image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    _ = model.select(url: url)
                }
            case .failure(let error):
                model.showError(error.localizedDescription)
            }
        }
        .alert(
            "无法选择输入",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "请选择图片文件或文件夹。")
        }
        .alert("正在压缩", isPresented: $isLeaveConfirmationPresented) {
            Button("停止并离开", role: .destructive) {
                model.stop()
                dismiss()
            }
            Button("继续压缩", role: .cancel) {}
        } message: {
            Text("当前任务尚未完成，离开后会停止压缩。")
        }
    }

    private func requestLeave() {
        guard model.isRunning || model.isScanning else {
            dismiss()
            return
        }
        if model.isStopping {
            dismiss()
        } else {
            isLeaveConfirmationPresented = true
        }
    }

    @ViewBuilder
    private var selectionSummary: some View {
        if let selectedURL = model.selectedURL {
            VStack(alignment: .leading, spacing: 8) {
                Label(selectedURL.path, systemImage: model.selectionIsDirectory ? "folder" : "photo")
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if let summary = model.selectionSummary {
                    HStack(spacing: 16) {
                        Text("图片 \(summary.imageCount) 张")
                        if summary.oversizedCount > 0 {
                            Label(
                                "\(summary.oversizedCount) 张超过 5 MB，将跳过上传",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 16) {
                        Text("压缩前：\(TinyPNGFormat.bytes(model.totalOriginalByteCount))")
                        if let stats = model.compressionStats {
                            Text("压缩后：\(TinyPNGFormat.bytes(stats.afterBytes))")
                            Text("减少：\(TinyPNGFormat.percent(stats.savedPercentage))")
                                .foregroundStyle(.green)
                        } else if model.isRunning {
                            Text("压缩后：计算中")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct TinyPNGDropArea: View {
    @Binding var isTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("拖入图片或文件夹")
                .font(.title3.weight(.semibold))
            Text("PNG、JPG、JPEG、WebP，单张上限 5 MB")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
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

private struct TinyPNGStatusSheet: View {
    @Environment(\.dismiss) private var dismiss

    let model: TinyPNGModel
    @State private var isLogExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("上传状态")
                        .font(.title2.bold())
                    Text(model.selectedURL?.path ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if model.outputDirectoryURL != nil {
                    Button {
                        model.revealOutputDirectory()
                    } label: {
                        Label("查看输出目录", systemImage: "folder")
                    }
                    .help("在 Finder 中显示压缩结果")
                }

                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            List(model.imageItems) { item in
                TinyPNGImageStatusRow(item: item) {
                    model.revealSource(for: item)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 260)

            DisclosureGroup("执行日志", isExpanded: $isLogExpanded) {
                ScrollView([.vertical, .horizontal]) {
                    Text(model.output.isEmpty ? "尚未执行" : model.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(10)
                }
                .frame(minHeight: 140, maxHeight: 240)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 520)
    }
}

private struct TinyPNGImageStatusRow: View {
    let item: TinyPNGImageItem
    let onRevealSource: () -> Void
    @State private var isPreviewPresented = false

    private var thumbnail: NSImage? {
        NSImage(contentsOf: item.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.relativePath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Group {
                    if let compressedByteCount = item.compressedByteCount,
                       let compressionPercentage = item.compressionPercentage {
                        Text(
                            "原图：\(TinyPNGFormat.bytes(item.byteCount))  "
                                + "压缩后：\(TinyPNGFormat.bytes(compressedByteCount))  "
                                + "减少：\(TinyPNGFormat.percent(compressionPercentage))"
                        )
                    } else {
                        Text("原图：\(TinyPNGFormat.bytes(item.byteCount))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Label(item.status.title, systemImage: item.status.systemImage)
                .foregroundStyle(item.status.color)
                .font(.caption)

            Button {
                isPreviewPresented = true
            } label: {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 38, height: 38)
                .clipped()
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("放大查看图片")

            Button(action: onRevealSource) {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示原图")
        }
        .padding(.vertical, 3)
        .sheet(isPresented: $isPreviewPresented) {
            TinyPNGImagePreview(imageURL: item.id)
        }
    }
}

private struct TinyPNGImagePreview: View {
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
                Button("完成") {
                    dismiss()
                }
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

struct TinyPNGSelectionSummary: Equatable, Sendable {
    let imageCount: Int
    let oversizedCount: Int
}

enum TinyPNGImageUploadStatus: Equatable {
    case waiting
    case uploading
    case success
    case skipped
    case cancelled
    case failed(String)

    var title: String {
        switch self {
        case .waiting:
            "等待上传"
        case .uploading:
            "上传中"
        case .success:
            "已完成"
        case .skipped:
            "已跳过"
        case .cancelled:
            "已停止"
        case .failed:
            "失败"
        }
    }

    var systemImage: String {
        switch self {
        case .waiting:
            "clock"
        case .uploading:
            "arrow.triangle.2.circlepath"
        case .success:
            "checkmark.circle"
        case .skipped:
            "exclamationmark.triangle"
        case .cancelled:
            "stop.circle"
        case .failed:
            "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .waiting:
            .secondary
        case .uploading:
            .accentColor
        case .success:
            .green
        case .skipped:
            .orange
        case .cancelled:
            .secondary
        case .failed:
            .red
        }
    }
}

struct TinyPNGImageItem: Identifiable, Equatable {
    let id: URL
    let relativePath: String
    let byteCount: Int64
    var status: TinyPNGImageUploadStatus
    var compressedByteCount: Int64? = nil
    var compressionPercentage: Double? = nil
}

struct TinyPNGCompressionStats: Equatable {
    let beforeBytes: Int64
    let afterBytes: Int64

    var savedPercentage: Double {
        guard beforeBytes > 0 else { return 0 }
        return Double(beforeBytes - afterBytes) / Double(beforeBytes) * 100
    }
}

enum TinyPNGFormat {
    static func bytes(_ value: Int64) -> String {
        if value < 1024 {
            return "\(value) B"
        }
        if value < 1024 * 1024 {
            return String(format: "%.1f KB", Double(value) / 1024)
        }
        return String(format: "%.2f MB", Double(value) / (1024 * 1024))
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

struct TinyPNGScannedImage: Sendable {
    let url: URL
    let byteCount: Int64
}

struct TinyPNGScanResult: Sendable {
    let images: [TinyPNGScannedImage]

    nonisolated var summary: TinyPNGSelectionSummary {
        TinyPNGSelectionSummary(
            imageCount: images.count,
            oversizedCount: images.reduce(into: 0) { count, image in
                if image.byteCount > TinyPNGInputScanner.maxUploadBytes {
                    count += 1
                }
            }
        )
    }
}

enum TinyPNGInputScanner {
    nonisolated static let maxUploadBytes: Int64 = 5 * 1024 * 1024
    nonisolated static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    nonisolated static func accepts(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue || isSupportedImage(url)
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        return directory.boolValue
    }

    nonisolated static func scan(_ url: URL) -> TinyPNGScanResult {
        if !isDirectory(url) {
            guard isSupportedImage(url),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = values.fileSize else {
                return TinyPNGScanResult(images: [])
            }
            return TinyPNGScanResult(images: [
                TinyPNGScannedImage(url: url, byteCount: Int64(fileSize))
            ])
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return TinyPNGScanResult(images: [])
        }

        var images: [TinyPNGScannedImage] = []
        for item in enumerator {
            if Task.isCancelled {
                break
            }
            guard let imageURL = item as? URL,
                  isSupportedImage(imageURL),
                  let values = try? imageURL.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                  ),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else {
                continue
            }
            images.append(
                TinyPNGScannedImage(url: imageURL, byteCount: Int64(fileSize))
            )
        }

        images.sort {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        return TinyPNGScanResult(images: images)
    }

    nonisolated static func summary(for url: URL) -> TinyPNGSelectionSummary {
        scan(url).summary
    }

    nonisolated static func imageURLs(at url: URL) -> [URL] {
        scan(url).images.map(\.url)
    }

    nonisolated private static func isSupportedImage(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }
}

@MainActor
@Observable
final class TinyPNGModel {
    var selectedURL: URL?
    var selectionSummary: TinyPNGSelectionSummary?
    var imageItems: [TinyPNGImageItem] = []
    var replaceOriginals = true
    var isScanning = false
    var isRunning = false
    var isStopping = false
    var output = ""
    var operationStatus = "请选择图片或文件夹"
    var operationStatusSystemImage = "photo.on.rectangle"
    var alertMessage: String?
    var outputDirectoryURL: URL?

    private var scanWorker: Task<TinyPNGScanResult, Never>?
    private var activeSelectionToken = UUID()
    private var outputEventBuffer = ""
    private var processCancellation: StreamingProcessCancellation?

    var canRun: Bool {
        selectedURL != nil
            && (selectionSummary?.imageCount ?? 0) > 0
            && !isScanning
            && !isRunning
    }

    var isError: Bool {
        operationStatusSystemImage == "xmark.circle"
    }

    var hasProgress: Bool {
        selectionSummary != nil && !imageItems.isEmpty
    }

    var completedImageCount: Int {
        imageItems.reduce(into: 0) { count, item in
            switch item.status {
            case .success, .skipped:
                count += 1
            case .waiting, .uploading, .cancelled, .failed:
                break
            }
        }
    }

    var progressFraction: Double {
        guard !imageItems.isEmpty else { return 0 }
        return Double(completedImageCount) / Double(imageItems.count)
    }

    var completionPercentage: Int {
        Int((progressFraction * 100).rounded())
    }

    var totalOriginalByteCount: Int64 {
        imageItems.reduce(0) { $0 + $1.byteCount }
    }

    var compressionStats: TinyPNGCompressionStats? {
        guard !imageItems.isEmpty,
              imageItems.allSatisfy({ $0.compressedByteCount != nil }) else {
            return nil
        }
        return TinyPNGCompressionStats(
            beforeBytes: totalOriginalByteCount,
            afterBytes: imageItems.reduce(0) { $0 + ($1.compressedByteCount ?? 0) }
        )
    }

    var selectionIsDirectory: Bool {
        guard let selectedURL else { return false }
        return TinyPNGInputScanner.isDirectory(selectedURL)
    }

    @discardableResult
    func select(url: URL) -> Bool {
        guard !isRunning else { return false }
        scanWorker?.cancel()
        scanWorker = nil
        isScanning = false
        activeSelectionToken = UUID()
        let standardizedURL = url.standardizedFileURL
        guard TinyPNGInputScanner.accepts(standardizedURL) else {
            showError("请选择文件夹，或选择 PNG、JPG、JPEG、WebP 图片。")
            return false
        }

        selectedURL = standardizedURL
        selectionSummary = nil
        imageItems = []
        isScanning = true
        output = ""
        outputEventBuffer = ""
        outputDirectoryURL = nil
        operationStatus = "正在扫描图片"
        operationStatusSystemImage = "arrow.triangle.2.circlepath"
        alertMessage = nil

        let selectionToken = UUID()
        activeSelectionToken = selectionToken
        let hasSecurityScope = standardizedURL.startAccessingSecurityScopedResource()
        let worker = Task.detached(priority: .userInitiated) {
            TinyPNGInputScanner.scan(standardizedURL)
        }
        scanWorker = worker

        Task { @MainActor [weak self, standardizedURL, selectionToken, hasSecurityScope, worker] in
            defer {
                if hasSecurityScope {
                    standardizedURL.stopAccessingSecurityScopedResource()
                }
            }

            let result = await worker.value
            guard let self,
                  self.activeSelectionToken == selectionToken,
                  !worker.isCancelled else {
                return
            }

            scanWorker = nil
            isScanning = false
            guard !result.images.isEmpty else {
                selectedURL = nil
                selectionSummary = nil
                imageItems = []
                operationStatus = "未找到可压缩图片"
                operationStatusSystemImage = "exclamationmark.triangle"
                alertMessage = "所选路径中没有可压缩的 PNG、JPG、JPEG 或 WebP 图片。"
                return
            }

            selectionSummary = result.summary
            imageItems = result.images.map { image in
                TinyPNGImageItem(
                    id: image.url,
                    relativePath: self.relativePath(for: image.url, inputURL: standardizedURL),
                    byteCount: image.byteCount,
                    status: image.byteCount > TinyPNGInputScanner.maxUploadBytes
                        ? .skipped
                        : .waiting
                )
            }
            operationStatus = "已选择，等待开始"
            operationStatusSystemImage = "checkmark.circle"
        }
        return true
    }

    func run() {
        guard let selectedURL, canRun else { return }
        guard let scriptURL = Bundle.main.url(forResource: "tinypng", withExtension: "py") else {
            showError("App 内缺少 TinyPNG 脚本：tinypng.py")
            return
        }

        let hasSecurityScope = selectedURL.startAccessingSecurityScopedResource()
        isRunning = true
        isStopping = false
        let cancellation = StreamingProcessCancellation()
        processCancellation = cancellation
        imageItems = imageItems.map { item in
            guard case .waiting = item.status else { return item }
            var updated = item
            updated.status = .uploading
            return updated
        }
        output = ""
        outputDirectoryURL = nil
        operationStatus = "正在压缩"
        operationStatusSystemImage = "arrow.triangle.2.circlepath"
        alertMessage = nil
        let shouldReplaceOriginals = replaceOriginals

        Task { [weak self, selectedURL, scriptURL, hasSecurityScope, shouldReplaceOriginals, cancellation] in
            defer {
                if hasSecurityScope {
                    selectedURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let result = try await StreamingProcess.run(
                    executableURL: URL(fileURLWithPath: "/bin/zsh"),
                    arguments: [
                        "-l",
                        "-c",
                        "exec python3 -u \"$@\"",
                        "devkit",
                        scriptURL.path,
                        selectedURL.path,
                    ] + (shouldReplaceOriginals ? ["--replace"] : []),
                    currentDirectoryURL: selectedURL.deletingLastPathComponent(),
                    cancellation: cancellation,
                    environment: [
                        "DEVKIT_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier)
                    ]
                ) { chunk in
                    Task { @MainActor [weak self] in
                        self?.appendProcessOutput(chunk)
                    }
                }

                guard let self else { return }
                applyProcessEvents(from: result.output)
                outputDirectoryURL = Self.outputDirectory(from: result.output)
                isRunning = false
                processCancellation = nil
                let wasStopping = isStopping
                isStopping = false
                if wasStopping {
                    operationStatus = "已停止"
                    operationStatusSystemImage = "stop.circle"
                    return
                }
                if result.terminationStatus == 0 {
                    finalizeSkippedItems()
                    imageItems = imageItems.map { item in
                        guard case .uploading = item.status else { return item }
                        var updated = item
                        updated.status = .success
                        return updated
                    }
                    let skippedCount = selectionSummary?.oversizedCount ?? 0
                    operationStatus = skippedCount > 0
                        ? "压缩完成（跳过 \(skippedCount) 张超限图片）"
                        : "压缩完成"
                    operationStatusSystemImage = "checkmark.circle"
                } else {
                    imageItems = imageItems.map { item in
                        guard case .uploading = item.status else { return item }
                        var updated = item
                        updated.status = .failed("脚本退出码 \(result.terminationStatus)")
                        return updated
                    }
                    operationStatus = "压缩失败（退出码 \(result.terminationStatus)）"
                    operationStatusSystemImage = "xmark.circle"
                    alertMessage = "脚本执行失败，请查看下方日志。"
                }
            } catch {
                guard let self else { return }
                isRunning = false
                processCancellation = nil
                let wasStopping = isStopping
                isStopping = false
                if wasStopping {
                    operationStatus = "已停止"
                    operationStatusSystemImage = "stop.circle"
                    return
                }
                imageItems = imageItems.map { item in
                    guard case .uploading = item.status else { return item }
                    var updated = item
                    updated.status = .failed(error.localizedDescription)
                    return updated
                }
                operationStatus = "压缩失败"
                operationStatusSystemImage = "xmark.circle"
                alertMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        if isScanning {
            scanWorker?.cancel()
            scanWorker = nil
            activeSelectionToken = UUID()
            isScanning = false
            operationStatus = "已停止"
            operationStatusSystemImage = "stop.circle"
            return
        }

        guard isRunning, !isStopping else { return }
        isStopping = true
        operationStatus = "正在停止"
        operationStatusSystemImage = "stop.circle"
        imageItems = imageItems.map { item in
            guard case .uploading = item.status else { return item }
            var updated = item
            updated.status = .cancelled
            return updated
        }
        processCancellation?.cancel()
    }

    func revealOutputDirectory() {
        guard let outputDirectoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputDirectoryURL])
    }

    func revealSource(for item: TinyPNGImageItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.id])
    }

    func showError(_ message: String) {
        alertMessage = message
    }

    private static func outputDirectory(from output: String) -> URL? {
        let marker = "  输出: "
        for line in output.split(whereSeparator: \.isNewline) {
            let value = String(line)
            if value.hasPrefix(marker) {
                return URL(fileURLWithPath: String(value.dropFirst(marker.count)))
            }
        }
        return nil
    }

    private func relativePath(for imageURL: URL, inputURL: URL) -> String {
        if TinyPNGInputScanner.isDirectory(inputURL) {
            return imageURL.path.replacingOccurrences(
                of: inputURL.path + "/",
                with: ""
            )
        }
        return imageURL.lastPathComponent
    }

    private func applyProcessEvents(from output: String) {
        for line in output.split(whereSeparator: \.isNewline) {
            applyProcessEventLine(String(line))
        }
    }

    private func finalizeSkippedItems() {
        imageItems = imageItems.map { item in
            guard case .skipped = item.status, item.compressedByteCount == nil else {
                return item
            }
            var updated = item
            updated.compressedByteCount = item.byteCount
            updated.compressionPercentage = 0
            return updated
        }
    }

    private func appendProcessOutput(_ chunk: String) {
        output.append(chunk)
        outputEventBuffer.append(chunk)

        let lines = outputEventBuffer.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        if outputEventBuffer.hasSuffix("\n") {
            outputEventBuffer = ""
            for line in lines {
                applyProcessEventLine(String(line))
            }
        } else if let last = lines.last {
            outputEventBuffer = String(last)
            for line in lines.dropLast() {
                applyProcessEventLine(String(line))
            }
        }
    }

    private func applyProcessEventLine(_ line: String) {
        let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("EVENT "),
              let data = value.dropFirst("EVENT ".count).data(using: .utf8),
              let event = try? JSONDecoder().decode(TinyPNGProcessEvent.self, from: data) else {
            return
        }

        let sourceURL = URL(fileURLWithPath: event.src).standardizedFileURL
        guard let index = imageItems.firstIndex(where: { $0.id.path == sourceURL.path }) else {
            return
        }

        var item = imageItems[index]
        item.status = event.ok ? .success : .failed(event.error)
        if event.ok {
            item.compressedByteCount = event.after
            item.compressionPercentage = TinyPNGCompressionStats(
                beforeBytes: event.before,
                afterBytes: event.after
            ).savedPercentage
        }
        imageItems[index] = item
    }
}

private struct TinyPNGProcessEvent: Decodable {
    let src: String
    let ok: Bool
    let before: Int64
    let after: Int64
    let error: String
}

#Preview {
    NavigationStack {
        TinyPNGView()
    }
}
