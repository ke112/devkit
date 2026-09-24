import AppKit
import Luban
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 数据结构

struct LubanImageItem: Identifiable, Equatable {
    let id: URL
    let relativePath: String
    let byteCount: Int64
    var status: LubanCompressionStatus
    var compressedByteCount: Int64?
    var compressionPercentage: Double?
    var elapsedSeconds: Double?
    var destinationPath: String?
}

enum LubanCompressionStatus: Equatable {
    case waiting
    case compressing
    case success
    case skipped
    case cancelled
    case failed(String)

    var title: String {
        switch self {
        case .waiting: "等待压缩"
        case .compressing: "压缩中"
        case .success: "已完成"
        case .skipped: "已跳过"
        case .cancelled: "已停止"
        case .failed: "失败"
        }
    }

    var systemImage: String {
        switch self {
        case .waiting: "clock"
        case .compressing: "arrow.triangle.2.circlepath"
        case .success: "checkmark.circle"
        case .skipped: "exclamationmark.triangle"
        case .cancelled: "stop.circle"
        case .failed: "xmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .waiting: .secondary
        case .compressing: .accentColor
        case .success: .green
        case .skipped: .orange
        case .cancelled: .secondary
        case .failed: .red
        }
    }
}

struct LubanCompressionStats: Equatable {
    let beforeBytes: Int64
    let afterBytes: Int64

    var savedPercentage: Double {
        guard beforeBytes > 0 else { return 0 }
        return Double(beforeBytes - afterBytes) / Double(beforeBytes) * 100
    }
}

struct LubanFormat {
    static func bytes(_ value: Int64) -> String {
        if value < 1024 { return "\(value) B" }
        if value < 1024 * 1024 { return String(format: "%.1f KB", Double(value) / 1024) }
        return String(format: "%.2f MB", Double(value) / (1024 * 1024))
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}

// MARK: - 扫描

struct LubanScannedImage: Sendable {
    let url: URL
    let byteCount: Int64
}

struct LubanScanResult: Sendable {
    let images: [LubanScannedImage]
}

enum LubanInputScanner {
    /// Luban 输出 JPEG，本地压缩无上传大小限制，仅按最小压缩大小过滤
    nonisolated static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "tiff", "bmp"]

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

    nonisolated static func isSupportedImage(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func scan(_ url: URL) -> LubanScanResult {
        if !isDirectory(url) {
            guard isSupportedImage(url),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = values.fileSize else {
                return LubanScanResult(images: [])
            }
            return LubanScanResult(images: [LubanScannedImage(url: url, byteCount: Int64(fileSize))])
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return LubanScanResult(images: [])
        }

        var images: [LubanScannedImage] = []
        for item in enumerator {
            if Task.isCancelled { break }
            guard let imageURL = item as? URL,
                  isSupportedImage(imageURL),
                  let values = try? imageURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else {
                continue
            }
            images.append(LubanScannedImage(url: imageURL, byteCount: Int64(fileSize)))
        }
        images.sort {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        return LubanScanResult(images: images)
    }
}

// MARK: - 压缩执行

@MainActor
@Observable
final class LubanCompressionModel {
    static let defaultMinimumCompressionSizeKB = 0
    static let maximumMinimumCompressionSizeKB = Int(Int64.max / 1024)
    private static let minimumCompressionSizeKey = "luban.minimumCompressionSizeKB"

    var selectedURLs: [URL] = []
    var imageItems: [LubanImageItem] = []
    var replaceOriginals = false
    var minimumCompressionSizeKB: Int {
        didSet {
            let normalized = Self.normalizedMinimumCompressionSizeKB(minimumCompressionSizeKB)
            if minimumCompressionSizeKB != normalized {
                minimumCompressionSizeKB = normalized
                return
            }
            preferencesDefaults.set(normalized, forKey: Self.minimumCompressionSizeKey)
        }
    }
    var isScanning = false
    var isRunning = false
    var isStopping = false
    var operationStatus = "请选择图片或文件夹"
    var operationStatusSystemImage = "photo.on.rectangle"
    var alertMessage: String?
    var outputDirectoryURL: URL?

    private var scanTask: Task<[LubanScanResult], Never>?
    private var activeSelectionToken = UUID()
    private var compressionTask: Task<Void, Never>?
    private let preferencesDefaults: UserDefaults

    init(preferencesDefaults: UserDefaults = .standard) {
        self.preferencesDefaults = preferencesDefaults
        let storedValue = preferencesDefaults.object(forKey: Self.minimumCompressionSizeKey) as? Int
        self.minimumCompressionSizeKB = Self.normalizedMinimumCompressionSizeKB(
            storedValue ?? Self.defaultMinimumCompressionSizeKB
        )
    }

    private static func normalizedMinimumCompressionSizeKB(_ value: Int) -> Int {
        min(max(0, value), Self.maximumMinimumCompressionSizeKB)
    }

    var canRun: Bool {
        !selectedURLs.isEmpty
            && imageItems.contains { if case .waiting = $0.status { return true }; return false }
            && !isScanning
            && !isRunning
    }

    var isError: Bool { operationStatusSystemImage == "xmark.circle" }

    var completedImageCount: Int {
        imageItems.reduce(into: 0) { count, item in
            switch item.status {
            case .success, .skipped: count += 1
            case .waiting, .compressing, .cancelled, .failed: break
            }
        }
    }

    var progressFraction: Double {
        guard !imageItems.isEmpty else { return 0 }
        return Double(completedImageCount) / Double(imageItems.count)
    }

    var completionPercentage: Int { Int((progressFraction * 100).rounded()) }

    var compressionStats: LubanCompressionStats? {
        guard !imageItems.isEmpty,
              imageItems.allSatisfy({ $0.compressedByteCount != nil }) else { return nil }
        return LubanCompressionStats(
            beforeBytes: imageItems.reduce(0) { $0 + $1.byteCount },
            afterBytes: imageItems.reduce(0) { $0 + ($1.compressedByteCount ?? 0) }
        )
    }

    func select(urls: [URL]) {
        guard !isRunning else { return }
        let standardizedURLs = urls.map(\.standardizedFileURL)
        let validURLs = standardizedURLs.filter(LubanInputScanner.accepts)
        guard !validURLs.isEmpty else {
            alertMessage = "请选择文件夹，或选择 PNG、JPG、JPEG、WebP、HEIC 等图片。"
            return
        }

        var knownRoots = Set(selectedURLs.map(\.path))
        let acceptedURLs = validURLs.filter { knownRoots.insert($0.path).inserted }
        guard !acceptedURLs.isEmpty else { return }

        scanTask?.cancel()
        isScanning = true
        activeSelectionToken = UUID()
        operationStatus = "正在扫描图片"
        operationStatusSystemImage = "arrow.triangle.2.circlepath"
        alertMessage = nil

        let selectionToken = activeSelectionToken
        let roots = acceptedURLs
        scanTask = Task.detached(priority: .userInitiated) {
            roots.map { LubanInputScanner.scan($0) }
        }

        guard let scanTask = scanTask else { return }
        Task { @MainActor [weak self, selectionToken, scanTask] in
            guard let self, self.activeSelectionToken == selectionToken, !scanTask.isCancelled else { return }
            let results = await scanTask.value
            self.scanTask = nil
            self.isScanning = false

            var knownPaths = Set(self.imageItems.map(\.id.path))
            var appended: [LubanImageItem] = []
            for (index, result) in results.enumerated() {
                let inputURL = roots[index]
                for image in result.images where knownPaths.insert(image.url.path).inserted {
                    appended.append(LubanImageItem(
                        id: image.url,
                        relativePath: self.relativePath(for: image.url, inputURL: inputURL),
                        byteCount: image.byteCount,
                        status: .waiting,
                        compressedByteCount: nil,
                        compressionPercentage: nil
                    ))
                }
                if !result.images.isEmpty {
                    self.selectedURLs.append(inputURL)
                }
            }

            guard !appended.isEmpty else {
                if self.selectedURLs.isEmpty {
                    self.operationStatus = "请选择图片或文件夹"
                    self.operationStatusSystemImage = "photo.on.rectangle"
                } else {
                    self.operationStatus = "已选择，等待开始"
                    self.operationStatusSystemImage = "checkmark.circle"
                }
                return
            }
            self.imageItems.append(contentsOf: appended)
            self.operationStatus = "已选择，等待开始"
            self.operationStatusSystemImage = "checkmark.circle"
        }
    }

    func run() {
        guard canRun else { return }
        // 先取待压缩快照，再把状态切到 .compressing；循环内以 imageItems 的当前状态为准（中途停止后跳过）
        let pendingItems = imageItems.filter {
            if case .waiting = $0.status { return true }
            return false
        }
        let shouldReplace = replaceOriginals

        // 准备输出目录
        let timestamp = Self.fileTimestamp()
        let outputDir: URL?
        if shouldReplace {
            outputDir = nil
            outputDirectoryURL = nil
        } else {
            // 非替换模式统一输出到 ~/Desktop/DevKit/<功能名>_<时间戳>/
            outputDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/DevKitOutput", isDirectory: true)
                .appendingPathComponent("Luban_\(timestamp)", isDirectory: true)
            outputDirectoryURL = outputDir
        }

        isRunning = true
        isStopping = false
        operationStatus = "正在压缩"
        operationStatusSystemImage = "arrow.triangle.2.circlepath"
        imageItems = imageItems.map { item in
            guard case .waiting = item.status else { return item }
            var updated = item
            updated.status = .compressing
            return updated
        }

        let minimumCompressionBytes = Int64(minimumCompressionSizeKB) * 1024
        compressionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for item in pendingItems {
                guard !Task.isCancelled else { break }
                guard let current = self.imageItems.first(where: { $0.id == item.id }),
                      case .compressing = current.status else { continue }

                // 最低压缩大小：低于阈值直接跳过
                if item.byteCount < minimumCompressionBytes {
                    let skippedDestination: String?
                    if shouldReplace {
                        skippedDestination = item.id.path
                    } else if let outputDir {
                        let target = outputDir.appendingPathComponent(item.relativePath)
                            .deletingPathExtension().appendingPathExtension("jpg")
                        skippedDestination = target.path
                    } else {
                        skippedDestination = nil
                    }
                    self.updateItem(item.id) { updated in
                        updated.status = .skipped
                        updated.compressedByteCount = item.byteCount
                        updated.compressionPercentage = 0
                        updated.destinationPath = skippedDestination
                    }
                    continue
                }

                do {
                    let startedAt = Date()
                    let outputURL: URL
                    if shouldReplace {
                        // 替换原图时先压缩到临时文件，成功后再覆盖
                        let temp = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension("jpg")
                        let compressed = try await Luban.compress(item.id, to: temp)
                        _ = try FileManager.default.replaceItemAt(item.id, withItemAt: compressed)
                        outputURL = item.id
                    } else {
                        guard let outputDir else { break }
                        let relative = item.relativePath
                        let target = outputDir.appendingPathComponent(relative)
                            .deletingPathExtension().appendingPathExtension("jpg")
                        outputURL = try await Luban.compress(item.id, to: target)
                    }

                    guard !Task.isCancelled else { break }
                    let elapsed = Date().timeIntervalSince(startedAt)
                    let afterBytes = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    self.updateItem(item.id) { updated in
                        updated.status = .success
                        updated.compressedByteCount = Int64(afterBytes)
                        updated.compressionPercentage = item.byteCount > 0
                            ? Double(item.byteCount - Int64(afterBytes)) / Double(item.byteCount) * 100
                            : 0
                        updated.elapsedSeconds = elapsed
                        updated.destinationPath = outputURL.path
                    }
                } catch {
                    guard !Task.isCancelled else { break }
                    self.updateItem(item.id) { updated in
                        updated.status = .failed(error.localizedDescription)
                    }
                }
            }

            self.isRunning = false
            let wasStopping = self.isStopping
            self.isStopping = false
            if wasStopping {
                self.operationStatus = "已停止"
                self.operationStatusSystemImage = "stop.circle"
                return
            }
            self.finalizeSkippedItems()
            let failedCount = self.imageItems.filter {
                if case .failed = $0.status { return true }
                return false
            }.count
            if failedCount > 0 {
                self.operationStatus = "压缩完成（\(failedCount) 张失败）"
                self.operationStatusSystemImage = "xmark.circle"
            } else {
                self.operationStatus = "压缩完成"
                self.operationStatusSystemImage = "checkmark.circle"
            }
        }
    }

    func stop() {
        if isScanning {
            scanTask?.cancel()
            scanTask = nil
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
            guard case .compressing = item.status else { return item }
            var updated = item
            updated.status = .cancelled
            return updated
        }
        compressionTask?.cancel()
    }

    func clearSelection() {
        guard !isRunning, !isScanning else { return }
        scanTask?.cancel()
        scanTask = nil
        selectedURLs = []
        imageItems = []
        outputDirectoryURL = nil
        operationStatus = "请选择图片或文件夹"
        operationStatusSystemImage = "photo.on.rectangle"
        alertMessage = nil
    }

    func revealOutputDirectory() {
        guard let outputDirectoryURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputDirectoryURL])
    }

    func revealSource(for item: LubanImageItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.id])
    }

    private func updateItem(_ id: URL, transform: (inout LubanImageItem) -> Void) {
        imageItems = imageItems.map { item in
            guard item.id == id else { return item }
            var updated = item
            transform(&updated)
            return updated
        }
    }

    private func finalizeSkippedItems() {
        imageItems = imageItems.map { item in
            guard case .skipped = item.status, item.compressedByteCount == nil else { return item }
            var updated = item
            updated.compressedByteCount = item.byteCount
            updated.compressionPercentage = 0
            return updated
        }
    }

    private func relativePath(for imageURL: URL, inputURL: URL) -> String {
        if LubanInputScanner.isDirectory(inputURL) {
            let relative = imageURL.path.replacingOccurrences(
                of: inputURL.standardizedFileURL.path + "/",
                with: ""
            )
            return relative == imageURL.path ? imageURL.lastPathComponent : relative
        }
        return imageURL.lastPathComponent
    }

    private static func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - 视图

struct LubanCompressionView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var model = LubanCompressionModel()
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    @State private var isLeaveConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Luban 图片压缩")
                    .font(.largeTitle.bold())
                Text("本地压缩，复刻微信朋友圈策略：短边 1440、非长图固定质量 60")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                HStack(spacing: 8) {
                    Text("最低压缩大小")
                    TextField("0", value: $model.minimumCompressionSizeKB, format: .number)
                        .frame(width: 72)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text("KB 以上才压缩")
                        .foregroundStyle(.secondary)
                }
                .disabled(model.isRunning || model.isScanning)
                .help("小于此大小的图片会跳过压缩，0 表示全部压缩")

                Spacer()

                Toggle("自动替换原图路径", isOn: $model.replaceOriginals)
                    .toggleStyle(.switch)
                    .disabled(model.isRunning || model.isScanning)
            }

            ImageCompressionDropArea(isTargeted: $isDropTargeted, subtitle: "PNG、JPG、JPEG、WebP、HEIC 等，本地压缩无大小限制")
                .dropDestination(for: URL.self) { urls, _ in
                    guard !urls.isEmpty else { return false }
                    model.select(urls: urls)
                    return true
                } isTargeted: { targeted in
                    isDropTargeted = targeted
                }

            if !model.selectedURLs.isEmpty {
                HStack(spacing: 12) {
                    Label("已选择 \(model.imageItems.count) 张图片", systemImage: "photo.stack")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.clearSelection()
                    } label: {
                        Label("清空列表", systemImage: "trash")
                    }
                    .disabled(model.isRunning || model.isScanning)
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: model.operationStatusSystemImage)
                    Text(model.operationStatus)
                }
                .foregroundStyle(model.isError ? .red : .secondary)

                if !model.imageItems.isEmpty {
                    ProgressView(value: model.progressFraction)
                        .frame(width: 110)
                    Text("已完成 \(model.completedImageCount)/\(model.imageItems.count)（\(model.completionPercentage)%）")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let stats = model.compressionStats {
                        Text("总计：\(LubanFormat.bytes(stats.beforeBytes)) → \(LubanFormat.bytes(stats.afterBytes))（减少 \(LubanFormat.percent(stats.savedPercentage))）")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                Spacer()

                if model.isRunning || model.isScanning {
                    Button {
                        model.stop()
                    } label: {
                        Label(model.isStopping ? "正在停止" : "停止压缩", systemImage: "stop.circle")
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

            if !model.imageItems.isEmpty {
                List(model.imageItems) { item in
                    LubanTaskRow(item: item) {
                        model.revealSource(for: item)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 200)
            }

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Luban 图片压缩")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    requestLeave()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("返回")
            }
        }
        .onDisappear {
            if (model.isRunning && !model.isStopping) || model.isScanning {
                model.stop()
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.item, .folder, .image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                if !urls.isEmpty {
                    model.select(urls: urls)
                }
            case .failure(let error):
                model.alertMessage = error.localizedDescription
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
}

private struct LubanDropArea: View {
    @Binding var isTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("拖入图片或文件夹，可一次拖入多个")
                .font(.title3.weight(.semibold))
            Text("PNG、JPG、JPEG、WebP、HEIC 等，本地压缩无大小限制")
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

private struct LubanTaskRow: View {
    let item: LubanImageItem
    let onRevealSource: () -> Void
    @State private var isPreviewPresented = false

    var body: some View {
        ImageCompressionTaskRow(
            thumbnailURL: item.id,
            title: item.relativePath,
            sizeSummary: sizeSummary,
            elapsedText: CompressionElapsedFormatter.seconds(item.elapsedSeconds),
            destinationPath: item.destinationPath,
            state: .label(item.status.title, item.status.color),
            showsPreviewButton: item.status == .success,
            onPreview: { isPreviewPresented = true },
            onRevealSource: onRevealSource,
            onRevealDestination: { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        )
        .sheet(isPresented: $isPreviewPresented) {
            LubanImagePreview(imageURL: item.id)
        }
    }

    private var sizeSummary: String? {
        if let compressedByteCount = item.compressedByteCount,
           let compressionPercentage = item.compressionPercentage {
            return "原图：\(LubanFormat.bytes(item.byteCount))  压缩后：\(LubanFormat.bytes(compressedByteCount))  减少：\(LubanFormat.percent(compressionPercentage))"
        }
        return "原图：\(LubanFormat.bytes(item.byteCount))"
    }
}

private struct LubanImagePreview: View {
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
