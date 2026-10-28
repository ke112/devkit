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
    var previewOriginalURL: URL? = nil
    var compressionOverride: Bool? = nil
    var resultReplacedOriginal = false
}

extension LubanImageItem: SelectableImageCompressionTaskItem {
    var resultByteCount: Int64? {
        get { compressedByteCount }
        set { compressedByteCount = newValue }
    }
    var resultPercentage: Double? {
        get { compressionPercentage }
        set { compressionPercentage = newValue }
    }
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
final class LubanCompressionModel: ImageCompressionSelectionModel {
    static let defaultMinimumCompressionSizeKB = 0
    static let maximumMinimumCompressionSizeKB = Int(Int64.max / 1024)
    private static let minimumCompressionSizeKey = "luban.minimumCompressionSizeKB"

    let selectionState = ImageCompressionSelectionState<LubanImageItem>()

    var minimumCompressionSizeKB: Int {
        didSet {
            let normalized = Self.normalizedMinimumCompressionSizeKB(minimumCompressionSizeKB)
            if minimumCompressionSizeKB != normalized {
                minimumCompressionSizeKB = normalized
                return
            }
            preferencesDefaults.set(normalized, forKey: Self.minimumCompressionSizeKey)
            refreshSelectionEligibility()
        }
    }
    var isRunning = false
    var isStopping = false
    var isRestoring = false
    var operationStatus = "请选择图片或文件夹"
    var operationStatusSystemImage = "photo.on.rectangle"
    var alertMessage: String?
    var outputDirectoryURL: URL?

    private var compressionTask: Task<Void, Never>?
    private let preferencesDefaults: UserDefaults
    private let scanImage: @Sendable (URL) -> ImageScanResult
    private let outputBaseDirectory: URL
    private var previewOriginals = ImageCompressionOriginals()

    init(
        preferencesDefaults: UserDefaults = .standard,
        scanImage: @escaping @Sendable (URL) -> ImageScanResult = LubanInputScanner.scan,
        outputBaseDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/DevKitOutput", isDirectory: true)
    ) {
        self.preferencesDefaults = preferencesDefaults
        self.scanImage = scanImage
        self.outputBaseDirectory = outputBaseDirectory
        let storedValue = preferencesDefaults.object(forKey: Self.minimumCompressionSizeKey) as? Int
        self.minimumCompressionSizeKB = Self.normalizedMinimumCompressionSizeKB(
            storedValue ?? Self.defaultMinimumCompressionSizeKB
        )
    }

    private static func normalizedMinimumCompressionSizeKB(_ value: Int) -> Int {
        min(max(0, value), Self.maximumMinimumCompressionSizeKB)
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
              imageItems.allSatisfy({ $0.status == .skipped || $0.compressedByteCount != nil }) else { return nil }
        return ImageCompressionSizeStats(
            beforeBytes: imageItems.reduce(0) { $0 + $1.byteCount },
            afterBytes: imageItems.reduce(0) { $0 + ($1.status == .skipped ? $1.byteCount : ($1.compressedByteCount ?? 0)) }
        )
    }

    var scanConfiguration: ImageCompressionScanConfiguration {
        ImageCompressionScanConfiguration(
            supportedExtensions: LubanInputScanner.supportedExtensions, scan: scanImage,
            invalidInputMessage: "请选择文件夹，或选择 PNG、JPG、JPEG、WebP、HEIC 等图片。"
        )
    }

    func makeSelectionItem(_ image: ImageScannedImage, relativePath: String) -> LubanImageItem {
        LubanImageItem(id: image.url, relativePath: relativePath, byteCount: image.byteCount, status: .waiting)
    }

    func startSelectionProcessing() -> Task<Void, Never>? {
        startRun()
    }

    @discardableResult
    func select(urls: [URL], refreshing: Bool = false, startAfterScan: Bool = false) -> Task<Void, Never>? {
        selectImages(urls: urls, refreshing: refreshing, startAfterScan: startAfterScan).completion
    }

    @discardableResult
    func run() -> Task<Void, Never>? {
        guard canRun else { return nil }
        return select(urls: selectedURLs, refreshing: true, startAfterScan: true)
    }

    private func startRun() -> Task<Void, Never>? {
        guard canRun else { return nil }
        // Include skipped originals for output copies, while retaining completed results across runs.
        let pendingItems = imageItems.filter { $0.status != .success }
        let compressibleIDs = Set(pendingItems.filter { isCompressionEnabled(for: $0) }.map(\.id))
        let shouldReplace = replaceOriginals

        // 准备输出目录
        let timestamp = Self.fileTimestamp()
        let outputDir: URL?
        if shouldReplace {
            outputDir = nil
            outputDirectoryURL = nil
        } else {
            // 非替换模式统一输出到 ~/Desktop/DevKitOutput/<功能名>_<时间戳>/
            outputDir = outputBaseDirectory.appendingPathComponent(
                "Luban_\(timestamp)_\(UUID().uuidString.prefix(8))", isDirectory: true
            )
            outputDirectoryURL = outputDir
        }

        isRunning = true
        isStopping = false
        operationStatus = "正在压缩"
        operationStatusSystemImage = "arrow.triangle.2.circlepath"
        imageItems = imageItems.map { item in
            guard item.status != .success else { return item }
            var updated = item
            updated.status = compressibleIDs.contains(item.id) ? .working : .skipped
            updated.clearResultMetrics()
            return updated
        }

        let destinations = outputDir.map {
            Self.outputDestinations(for: pendingItems, in: $0, compressibleIDs: compressibleIDs)
        } ?? [:]
        let roots = selectedURLs
        compressionTask = Task { @MainActor [weak self] in
            let access = roots.map { $0.startAccessingSecurityScopedResource() }
            defer {
                for (root, granted) in zip(roots, access) where granted {
                    root.stopAccessingSecurityScopedResource()
                }
            }
            guard let self else { return }
            for item in pendingItems {
                guard !Task.isCancelled else { break }
                guard let current = self.imageItems.first(where: { $0.id == item.id }),
                      current.status == .working || current.status == .skipped else { continue }

                // 非替换模式也保留跳过图片的原始字节和扩展名。
                if !compressibleIDs.contains(item.id) {
                    do {
                        var destination = item.id
                        if !shouldReplace, let target = destinations[item.id] {
                            destination = try await Task.detached(priority: .userInitiated) {
                                try FileManager.default.createDirectory(
                                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                                )
                                try FileManager.default.copyItem(at: item.id, to: target)
                                return target
                            }.value
                        }
                        guard !Task.isCancelled else { break }
                        self.updateItem(item.id) { updated in
                            updated.status = .skipped
                            updated.compressedByteCount = item.byteCount
                            updated.compressionPercentage = 0
                            updated.destinationPath = destination.path
                        }
                    } catch {
                        guard !Task.isCancelled else { break }
                        self.updateItem(item.id) { $0.status = .failed(error.localizedDescription) }
                    }
                    continue
                }

                do {
                    let startedAt = Date()
                    let outputURL: URL
                    if shouldReplace {
                        if item.previewOriginalURL == nil {
                            let originalURL = try await self.previewOriginals.capture(at: item.id)
                            guard !Task.isCancelled else { break }
                            self.updateItem(item.id) { $0.previewOriginalURL = originalURL }
                        }
                        // 替换原图时先压缩到临时文件，成功后再覆盖
                        let temp = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension("jpg")
                        let compressed = try await Luban.compress(item.id, to: temp)
                        try Task.checkCancellation()
                        _ = try FileManager.default.replaceItemAt(item.id, withItemAt: compressed)
                        outputURL = item.id
                    } else {
                        guard let target = destinations[item.id] else { break }
                        let temporaryDirectory = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString, isDirectory: true)
                        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
                        let compressed = try await Luban.compress(
                            item.id, to: temporaryDirectory.appendingPathComponent("result.jpg")
                        )
                        try Task.checkCancellation()
                        try FileManager.default.createDirectory(
                            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
                        )
                        // Luban may overwrite its target; publish only after encoding to a private file.
                        try FileManager.default.moveItem(at: compressed, to: target)
                        outputURL = target
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
                        updated.resultReplacedOriginal = shouldReplace
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
                let skippedCount = self.imageItems.filter { $0.status == .skipped }.count
                self.operationStatus = skippedCount > 0 ? "压缩完成（跳过 \(skippedCount) 张图片）" : "压缩完成"
                self.operationStatusSystemImage = "checkmark.circle"
            }
        }
        return compressionTask
    }

    func stop() {
        if stopSelectionScan() { return }
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
        guard !isRunning, !isScanning, !isRestoring else { return }
        clearSelectionState()
        previewOriginals = ImageCompressionOriginals()
        outputDirectoryURL = nil
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

    private static func outputDestinations(
        for items: [LubanImageItem], in directory: URL, compressibleIDs: Set<URL>
    ) -> [URL: URL] {
        var destinations: [URL: URL] = [:]
        var usedPaths = Set<String>()
        // Reserve unchanged files first so an encoded JPEG cannot take a skipped JPG's name.
        let ordered = items.filter { !compressibleIDs.contains($0.id) }
            + items.filter { compressibleIDs.contains($0.id) }
        for item in ordered {
            let original = directory.appendingPathComponent(item.relativePath)
            let preferred = compressibleIDs.contains(item.id)
                ? original.deletingPathExtension().appendingPathExtension("jpg") : original
            var candidate = preferred
            var suffix = 2
            while !usedPaths.insert(candidate.path.precomposedStringWithCanonicalMapping.lowercased()).inserted {
                candidate = preferred.deletingLastPathComponent().appendingPathComponent(
                    "\(preferred.deletingPathExtension().lastPathComponent)_\(suffix).\(preferred.pathExtension)"
                )
                suffix += 1
            }
            destinations[item.id] = candidate
        }
        return destinations
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
            onlyGitChangedImages: $model.onlyGitChangedImages,
            replaceOriginals: $model.replaceOriginals,
            isDropTargeted: $isDropTargeted,
            isGitFilterAvailable: model.isGitFilterAvailable,
            isBusy: model.isRunning || model.isScanning || model.isRestoring,
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
            taskGroups: model.displayGroups,
            onSetCompressionEnabled: { id, enabled in
                Task { await model.setCompressionEnabled(enabled, for: id) }
            },
            onResetResult: { id in
                Task { await model.resetResult(for: id) }
            },
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
            "Luban 图片压缩",
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
