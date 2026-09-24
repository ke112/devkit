import Luban
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 数据结构

struct LubanImageItem: Identifiable, Equatable {
    let id: URL
    let relativePath: String
    let byteCount: Int64
    var status: ImageCompressionTaskStatus
    var compressedByteCount: Int64?
    var compressionPercentage: Double?
    var elapsedSeconds: Double?
    var destinationPath: String?
}

extension LubanImageItem: ImageCompressionTaskItem {
    var resultByteCount: Int64? { compressedByteCount }
    var resultPercentage: Double? { compressionPercentage }
}

// MARK: - 扫描

enum LubanInputScanner {
    /// Luban 输出 JPEG，本地压缩无上传大小限制，仅按最小压缩大小过滤
    nonisolated static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "tiff", "bmp"]

    nonisolated static func accepts(_ url: URL) -> Bool {
        ImageTaskScanner.accepts(url, supportedExtensions: supportedExtensions)
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        ImageTaskScanner.isDirectory(url)
    }

    nonisolated static func scan(_ url: URL) -> ImageScanResult {
        ImageTaskScanner.scan(url, supportedExtensions: supportedExtensions)
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

    private var scanTask: Task<[ImageScanResult], Never>?
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
            case .waiting, .working, .cancelled, .failed: break
            }
        }
    }

    var progressFraction: Double {
        guard !imageItems.isEmpty else { return 0 }
        return Double(completedImageCount) / Double(imageItems.count)
    }

    var completionPercentage: Int { Int((progressFraction * 100).rounded()) }

    var compressionStats: ImageCompressionSizeStats? {
        guard !imageItems.isEmpty,
              imageItems.allSatisfy({ $0.compressedByteCount != nil }) else { return nil }
        return ImageCompressionSizeStats(
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
        // 先取待压缩快照，再把状态切到 .working；循环内以 imageItems 的当前状态为准（中途停止后跳过）
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
            updated.status = .working
            return updated
        }

        let minimumCompressionBytes = Int64(minimumCompressionSizeKB) * 1024
        compressionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for item in pendingItems {
                guard !Task.isCancelled else { break }
                guard let current = self.imageItems.first(where: { $0.id == item.id }),
                      case .working = current.status else { continue }

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
            guard case .working = item.status else { return item }
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

    func showError(_ message: String) {
        alertMessage = message
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
        ImageCompressionPageLayout(
            title: "Luban 图片压缩",
            subtitle: "本地压缩，复刻微信朋友圈策略：短边 1440、非长图固定质量 60",
            replaceHelp: "开启后压缩成功的图片会替换原文件；关闭后生成输出时间戳文件夹",
            dropSubtitle: "PNG、JPG、JPEG、WebP、HEIC 等，本地压缩无大小限制",
            stopLabel: "停止压缩",
            minimumCompressionSizeKB: $model.minimumCompressionSizeKB,
            replaceOriginals: $model.replaceOriginals,
            isDropTargeted: $isDropTargeted,
            isBusy: model.isRunning || model.isScanning,
            isStopping: model.isStopping,
            canRun: model.canRun,
            selectedCount: model.imageItems.count,
            showsSelectionRow: !model.selectedURLs.isEmpty,
            operationStatus: model.operationStatus,
            operationStatusSystemImage: model.operationStatusSystemImage,
            isError: model.isError,
            hasProgress: !model.imageItems.isEmpty,
            progressFraction: model.progressFraction,
            completedCount: model.completedImageCount,
            totalCount: model.imageItems.count,
            completionPercentage: model.completionPercentage,
            statsText: statsText,
            tasks: taskDisplayModels,
            onDrop: { urls in
                guard !urls.isEmpty else { return false }
                model.select(urls: urls)
                return true
            },
            onClear: { model.clearSelection() },
            onStop: { model.stop() },
            onChooseFiles: { isImporterPresented = true },
            onStart: { model.run() },
            extras: { EmptyView() }
        )
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
                .accessibilityLabel("返回")
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

    private var statsText: String? {
        guard let stats = model.compressionStats else { return nil }
        return "总计：\(CompressionBytesFormatter.bytes(stats.beforeBytes)) → "
            + "\(CompressionBytesFormatter.bytes(stats.afterBytes)) "
            + "（减少 \(CompressionBytesFormatter.percent(stats.savedPercentage))）"
    }

    private var taskDisplayModels: [ImageTaskDisplayModel] {
        model.imageItems.map { ImageTaskDisplayModel(item: $0, resultLabel: "压缩后", verb: "压缩") }
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

#Preview {
    NavigationStack {
        LubanCompressionView()
    }
}
