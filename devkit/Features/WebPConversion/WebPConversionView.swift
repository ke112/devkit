import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct WebPConversionView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var model = WebPConversionModel()
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    @State private var isLeaveConfirmationPresented = false

    var body: some View {
        ImageCompressionPageLayout(
            title: "WebP 图片转换",
            subtitle: "默认输出到 ~/Desktop/DevKitOutput 时间戳文件夹，仅当 WebP 更小时才替换；开启后替换原图",
            minimumLabel: "最低转换大小",
            minimumSuffix: "KB 以上才转换",
            replaceHelp: "开启后转换成功的图片会替换原文件；关闭后生成输出时间戳文件夹",
            dropSubtitle: "PNG、JPG、JPEG，转换为 WebP 格式",
            stopLabel: "停止转换",
            startLabel: "开始转换",
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
            hasProgress: model.hasProgress,
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
                return model.select(urls: urls)
            },
            onClear: { model.clearSelection() },
            onStop: { model.stop() },
            onChooseFiles: { isImporterPresented = true },
            onStart: { model.run() },
            extras: {
                HStack(spacing: 8) {
                    Text("转换质量")
                    TextField("80", value: $model.quality, format: .number)
                        .frame(width: 56)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text("（建议 75-85）")
                        .foregroundStyle(.secondary)
                }
                .help("WebP 有损质量，75-85 在画质与体积之间性价比最高")

                HStack(spacing: 8) {
                    Text("最长边")
                    TextField("0", value: $model.maximumSideLength, format: .number)
                        .frame(width: 56)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text("px，0 不缩放")
                        .foregroundStyle(.secondary)
                }
                .help("最长边超过该像素时按比例缩小，适合网络加载图片进一步减小体积")
            }
        )
        .navigationTitle("WebP 图片转换")
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
                    _ = model.select(urls: urls)
                }
            case .failure(let error):
                model.showError(error.localizedDescription)
            }
        }
        .alert(
            "WebP 图片转换",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "请选择图片文件或文件夹。")
        }
        .alert("正在转换", isPresented: $isLeaveConfirmationPresented) {
            Button("停止并离开", role: .destructive) {
                model.stop()
                dismiss()
            }
            Button("继续压缩", role: .cancel) {}
        } message: {
            Text("当前任务尚未完成，离开后会停止转换。")
        }
    }

    private var statsText: String? {
        guard let stats = model.conversionStats else { return nil }
        return "总计：\(CompressionBytesFormatter.bytes(stats.beforeBytes)) → "
            + "\(CompressionBytesFormatter.bytes(stats.afterBytes)) "
            + "（减少 \(CompressionBytesFormatter.percent(stats.savedPercentage))）"
    }

    private var taskDisplayModels: [ImageTaskDisplayModel] {
        model.imageItems.map { ImageTaskDisplayModel(item: $0, resultLabel: "转换后", verb: "转换") }
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

struct WebPSelectionSummary: Equatable, Sendable {
    let imageCount: Int
    let alreadyWebPCount: Int
    let belowMinimumCount: Int
}

struct WebPImageItem: Identifiable, Equatable {
    let id: URL
    let relativePath: String
    let byteCount: Int64
    var status: ImageCompressionTaskStatus
    var convertedByteCount: Int64? = nil
    var conversionPercentage: Double? = nil
    var elapsedSeconds: Double? = nil
    var destinationPath: String? = nil
    var previewOriginalURL: URL? = nil
    var compressionOverride: Bool? = nil
    var manualSkipOrder: Int? = nil
    var resultReplacedOriginal = false
}

extension WebPImageItem: SelectableImageCompressionTaskItem {
    var resultByteCount: Int64? {
        get { convertedByteCount }
        set { convertedByteCount = newValue }
    }
    var resultPercentage: Double? {
        get { conversionPercentage }
        set { conversionPercentage = newValue }
    }
}

enum WebPInputScanner {
    nonisolated static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "bmp", "gif", "heic", "heif", "webp",
    ]

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

@MainActor
@Observable
final class WebPConversionModel: ImageCompressionSelectionModel {
    static let defaultQuality = 80
    static let defaultMinimumCompressionSizeKB = 0
    static let defaultMaximumSideLength = 0
    static let maximumMinimumCompressionSizeKB = Int(Int64.max / 1024)
    private static let qualityKey = "webp.quality"
    private static let minimumCompressionSizeKey = "webp.minimumCompressionSizeKB.v2"
    private static let maximumSideLengthKey = "webp.maximumSideLength"

    var selectedURLs: [URL] = []
    var selectionSummary: WebPSelectionSummary?
    var imageItems: [WebPImageItem] = []
    private var gitOptions = ImageCompressionGitOptions()
    var isGitFilterAvailable: Bool { gitOptions.isAvailable }
    var onlyGitChangedImages: Bool {
        get { gitOptions.isEnabled }
        set {
            let previous = gitOptions.isEnabled
            gitOptions.setEnabled(newValue)
            if previous != gitOptions.isEnabled, !selectedURLs.isEmpty {
                select(urls: selectedURLs, refreshing: true)
            }
        }
    }
    var replaceOriginals: Bool {
        get { gitOptions.replaceOriginals }
        set { gitOptions.replaceOriginals = newValue }
    }

    var quality: Int {
        didSet {
            let normalized = Self.normalizedQuality(quality)
            if quality != normalized {
                quality = normalized
                return
            }
            preferencesDefaults.set(normalized, forKey: Self.qualityKey)
        }
    }
    var minimumCompressionSizeKB: Int {
        didSet {
            let normalized = Self.normalizedMinimumCompressionSizeKB(minimumCompressionSizeKB)
            if minimumCompressionSizeKB != normalized {
                minimumCompressionSizeKB = normalized
                return
            }
            preferencesDefaults.set(normalized, forKey: Self.minimumCompressionSizeKey)
            refreshSkippedItems()
        }
    }
    var maximumSideLength: Int {
        didSet {
            let normalized = max(0, maximumSideLength)
            if maximumSideLength != normalized {
                maximumSideLength = normalized
                return
            }
            preferencesDefaults.set(normalized, forKey: Self.maximumSideLengthKey)
        }
    }
    var isScanning = false
    var isRunning = false
    var isStopping = false
    var isRestoring = false
    var nextManualSkipOrder = 0
    var output = ""
    var operationStatus = "请选择图片或文件夹"
    var operationStatusSystemImage = "photo.on.rectangle"
    var alertMessage: String?
    var outputDirectoryURL: URL?

    private var scanWorker: Task<ImageCompressionScanResult, Error>?
    private var pendingScanURLs: [URL] = []
    private var retainedSelectionItems: [WebPImageItem] = []
    private var isRefreshingSelection = false
    private var activeSelectionToken = UUID()
    private var outputEventBuffer = ""
    private var processCancellation: StreamingProcessCancellation?
    private let preferencesDefaults: UserDefaults
    private var previewOriginals = ImageCompressionOriginals()

    init(preferencesDefaults: UserDefaults = .standard) {
        self.preferencesDefaults = preferencesDefaults
        let storedQuality = preferencesDefaults.object(forKey: Self.qualityKey) as? Int
        self.quality = Self.normalizedQuality(storedQuality ?? Self.defaultQuality)
        let storedMinimum = preferencesDefaults.object(forKey: Self.minimumCompressionSizeKey) as? Int
        self.minimumCompressionSizeKB = Self.normalizedMinimumCompressionSizeKB(
            storedMinimum ?? Self.defaultMinimumCompressionSizeKB
        )
        let storedMaximumSide = preferencesDefaults.object(forKey: Self.maximumSideLengthKey) as? Int
        self.maximumSideLength = max(0, storedMaximumSide ?? Self.defaultMaximumSideLength)
    }

    var canRun: Bool {
        !selectedURLs.isEmpty
            && imageItems.contains(where: { isCompressionEnabled(for: $0) && $0.status != .success })
            && !isScanning
            && !isRunning
            && !isRestoring
    }

    var operationVerb: String { "转换" }

    func supportsProcessing(_ item: WebPImageItem) -> Bool { !item.isWebPSource }

    func inputURLsForPendingItems() -> [URL] {
        let pendingPaths = imageItems.filter { $0.status != .success }.map {
            $0.id.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        }
        return selectedURLs.filter { root in
            let components = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return pendingPaths.contains { $0.starts(with: components) }
        }
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
            case .waiting, .working, .cancelled, .failed:
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

    var conversionStats: ImageCompressionSizeStats? {
        guard !imageItems.isEmpty,
              imageItems.allSatisfy({ $0.status == .skipped || $0.convertedByteCount != nil }) else {
            return nil
        }
        return ImageCompressionSizeStats(
            beforeBytes: totalOriginalByteCount,
            afterBytes: imageItems.reduce(0) { $0 + ($1.status == .skipped ? $1.byteCount : ($1.convertedByteCount ?? 0)) }
        )
    }

    @discardableResult
    func select(urls: [URL], refreshing: Bool = false, startAfterScan: Bool = false) -> Bool {
        guard !isRunning, !isRestoring, !isRefreshingSelection else { return false }
        let previousItems = selectionHistory(merging: imageItems, into: retainedSelectionItems)
        // Revalidate the ordinary queue without adding newly discovered files or prior outputs.
        let queuedURLs = startAfterScan && !onlyGitChangedImages
            ? Set(imageItems.map { $0.id.resolvingSymlinksInPath() }) : nil
        let standardizedURLs = urls.map(\.standardizedFileURL)
        let effectiveURLs = effectiveScanRoots(standardizedURLs, history: previousItems)
        // Existing inputs must all reach eligibility validation, including paths that disappeared.
        let validURLs = refreshing ? standardizedURLs : zip(standardizedURLs, effectiveURLs)
            .filter { WebPInputScanner.accepts($0.1) }.map(\.0)
        guard !validURLs.isEmpty else {
            showError("请选择文件夹，或选择 PNG、JPG、HEIC 等图片。")
            return false
        }
        var knownRoots = Set((refreshing ? [] : selectedURLs + pendingScanURLs).map(\.path))
        let initiallyAcceptedURLs = validURLs.filter { knownRoots.insert($0.path).inserted }
        let acceptedURLs = initiallyAcceptedURLs.filter { url in
            refreshing || !initiallyAcceptedURLs.contains { root in
                root.path != url.path && url.path.hasPrefix(root.path + "/")
            }
        }

        scanWorker?.cancel()
        scanWorker = nil
        isScanning = false
        activeSelectionToken = UUID()
        isRefreshingSelection = refreshing
        let inputRoots = refreshing ? acceptedURLs : selectedURLs + pendingScanURLs + acceptedURLs
        var seenRoots = Set<String>()
        pendingScanURLs = inputRoots.filter { seenRoots.insert($0.path).inserted }
        isScanning = true
        operationStatus = "正在扫描图片"
        operationStatusSystemImage = "arrow.triangle.2.circlepath"
        alertMessage = nil

        let selectionToken = UUID()
        activeSelectionToken = selectionToken
        // Include the previous pending batch when replacing an in-flight scan.
        let scannedURLs = pendingScanURLs
        let effectiveRoots = effectiveScanRoots(scannedURLs, history: previousItems)
        let gitOnly = onlyGitChangedImages
        let worker = Task.detached(priority: .userInitiated) {
            try GitChangedImageScanner.scanSelection(
                effectiveRoots, onlyGitChangedImages: gitOnly,
                supportedExtensions: WebPInputScanner.supportedExtensions, scanImage: WebPInputScanner.scan
            )
        }
        scanWorker = worker

        Task { @MainActor [weak self, selectionToken, worker] in
            let outcome = await worker.result
            guard let self,
                  self.activeSelectionToken == selectionToken,
                  !worker.isCancelled else {
                return
            }

            scanWorker = nil
            pendingScanURLs = []
            isScanning = false
            isRefreshingSelection = false
            retainedSelectionItems = previousItems
            guard case .success(let batch) = outcome else {
                if case .failure(let error) = outcome {
                    imageItems = []
                    selectionSummary = nil
                    selectedURLs = scannedURLs
                    gitOptions.updateAvailability(false)
                    reportGitScanFailure(error)
                }
                return
            }

            gitOptions.updateAvailability(batch.gitFilterAvailable)
            let results = batch.scans
            selectedURLs = scannedURLs
            imageItems = []
            selectionSummary = nil
            var knownPaths = Set<String>()
            var appendedItems: [WebPImageItem] = []
            for (index, result) in results.enumerated() {
                let inputURL = scannedURLs[index]
                let inputPath = ImageCompressionInputPath(root: inputURL)
                for image in result.images where knownPaths.insert(image.url.path).inserted {
                    if let queuedURLs, !queuedURLs.contains(image.url.resolvingSymlinksInPath()) { continue }
                    appendedItems.append(
                        WebPImageItem(
                            id: image.url,
                            relativePath: inputPath.relativePath(for: image.url),
                            byteCount: image.byteCount,
                            status: shouldSkipAtScan(image) ? .skipped : .waiting
                        )
                    )
                }
            }

            imageItems = retainingSelectionState(in: appendedItems, from: previousItems)
            retainedSelectionItems = selectionHistory(merging: imageItems, into: previousItems)
            guard !imageItems.isEmpty else {
                operationStatus = selectedURLs.isEmpty ? "请选择图片或文件夹" : "已选择，等待开始"
                operationStatusSystemImage = selectedURLs.isEmpty ? "photo.on.rectangle" : "checkmark.circle"
                if batch.usesGitFilter && imageItems.isEmpty {
                    reportEmptyGitSelection()
                } else if !batch.usesGitFilter && results.allSatisfy({ $0.images.isEmpty }) {
                    alertMessage = "新添加的路径中没有可转换的图片。"
                }
                return
            }

            selectionSummary = Self.summary(for: imageItems, minimumCompressionBytes: minimumCompressionSizeBytes)
            operationStatus = "已选择，等待开始"
            operationStatusSystemImage = "checkmark.circle"
            if startAfterScan, !gitOnly || batch.usesGitFilter { startRun() }
        }
        return true
    }

    func run() {
        guard canRun else { return }
        select(urls: selectedURLs, refreshing: true, startAfterScan: true)
    }

    private func startRun() {
        guard canRun else { return }
        guard let scriptURL = Bundle.main.url(forResource: "webp_convert", withExtension: "py") else {
            showError("App 内缺少 WebP 转换脚本：webp_convert.py")
            return
        }

        let selection = Dictionary(uniqueKeysWithValues: imageItems.filter { $0.status != .success }.map {
            ($0.id.path, isCompressionEnabled(for: $0))
        })
        // A completed single-file input may have been deleted in replacement mode.
        let inputURLs = inputURLsForPendingItems()
        guard let firstInputURL = inputURLs.first else {
            showError("无法匹配待转换图片的输入路径，请重新选择图片。")
            return
        }
        let hasSecurityScopes = inputURLs.map { $0.startAccessingSecurityScopedResource() }
        isRunning = true
        isStopping = false
        let cancellation = StreamingProcessCancellation()
        processCancellation = cancellation
        imageItems = imageItems.map { item in
            guard isCompressionEnabled(for: item), item.status != .success else { return item }
            var updated = item
            updated.status = .working
            updated.clearResultMetrics()
            return updated
        }
        output = ""
        outputEventBuffer = ""
        outputDirectoryURL = nil
        operationStatus = "正在转换"
        operationStatusSystemImage = "arrow.triangle.2.circlepath"
        alertMessage = nil
        let shouldReplaceOriginals = replaceOriginals
        let selectedQuality = quality
        let maximumSideLength = maximumSideLength
        // 非替换模式统一输出到 ~/Desktop/DevKitOutput/<功能名>_<时间戳>/
        let unifiedOutputBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/DevKitOutput", isDirectory: true)

        Task { [weak self, inputURLs, scriptURL, hasSecurityScopes, shouldReplaceOriginals, cancellation, unifiedOutputBase] in
            let manifestURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("WebP-selection-\(UUID().uuidString).json")
            defer {
                try? FileManager.default.removeItem(at: manifestURL)
                for (index, url) in inputURLs.enumerated()
                where index < hasSecurityScopes.count && hasSecurityScopes[index] {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                try JSONEncoder().encode(selection).write(to: manifestURL, options: .atomic)
                if shouldReplaceOriginals, let self {
                    for item in self.imageItems where item.status == .working && item.previewOriginalURL == nil {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        let originalURL = try await self.previewOriginals.capture(at: item.id)
                        guard let index = self.imageItems.firstIndex(where: { $0.id == item.id }) else { continue }
                        self.imageItems[index].previewOriginalURL = originalURL
                    }
                }
                guard !cancellation.isCancelled else { throw CancellationError() }
                var arguments: [String] = [
                    "-l",
                    "-c",
                    "exec python3 -u \"$@\"",
                    "devkit",
                    scriptURL.path,
                ]
                arguments.append(contentsOf: inputURLs.map(\.path))
                arguments.append(contentsOf: ["--quality", String(selectedQuality)])
                arguments.append(contentsOf: ["--selection-file", manifestURL.path])
                if maximumSideLength > 0 {
                    arguments.append(contentsOf: ["--max-side", String(maximumSideLength)])
                }
                if shouldReplaceOriginals {
                    arguments.append("--replace")
                } else {
                    arguments.append(contentsOf: ["--output-dir", unifiedOutputBase.path])
                }

                let result = try await StreamingProcess.run(
                    executableURL: URL(fileURLWithPath: "/bin/zsh"),
                    arguments: arguments,
                    currentDirectoryURL: firstInputURL.deletingLastPathComponent(),
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
                outputDirectoryURL = shouldReplaceOriginals ? nil : Self.outputDirectory(from: result.output)
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
                    imageItems = imageItems.map { item in
                        guard case .working = item.status else { return item }
                        var updated = item
                        updated.status = .failed("脚本未返回该图片的转换结果")
                        return updated
                    }
                    let skippedCount = imageItems.filter {
                        if case .skipped = $0.status { return true }
                        return false
                    }.count
                    let hasFailures = imageItems.contains {
                        if case .failed = $0.status { return true }
                        return false
                    }
                    operationStatus = hasFailures ? "转换结束（部分图片失败）" : (skippedCount > 0
                        ? "转换完成（跳过 \(skippedCount) 张图片）" : "转换完成")
                    operationStatusSystemImage = hasFailures ? "xmark.circle" : "checkmark.circle"
                } else {
                    imageItems = imageItems.map { item in
                        guard case .working = item.status else { return item }
                        var updated = item
                        updated.status = .failed("脚本退出码 \(result.terminationStatus)")
                        return updated
                    }
                    operationStatus = "转换失败（退出码 \(result.terminationStatus)）"
                    operationStatusSystemImage = "xmark.circle"
                    alertMessage = "脚本执行失败，请查看转换状态中的日志。"
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
                    guard case .working = item.status else { return item }
                    var updated = item
                    updated.status = .failed(error.localizedDescription)
                    return updated
                }
                operationStatus = "转换失败"
                operationStatusSystemImage = "xmark.circle"
                alertMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        if isScanning {
            gitOptions.cancelPendingChange()
            scanWorker?.cancel()
            scanWorker = nil
            pendingScanURLs = []
            isRefreshingSelection = false
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
            guard case .working = item.status else { return item }
            var updated = item
            updated.status = .cancelled
            return updated
        }
        processCancellation?.cancel()
    }

    func clearSelection() {
        guard !isRunning, !isScanning, !isRestoring else { return }
        scanWorker?.cancel()
        scanWorker = nil
        pendingScanURLs = []
        activeSelectionToken = UUID()
        selectedURLs = []
        retainedSelectionItems = []
        gitOptions.updateAvailability(false)
        selectionSummary = nil
        imageItems = []
        previewOriginals = ImageCompressionOriginals()
        nextManualSkipOrder = 0
        output = ""
        outputEventBuffer = ""
        outputDirectoryURL = nil
        operationStatus = "请选择图片或文件夹"
        operationStatusSystemImage = "photo.on.rectangle"
        alertMessage = nil
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

    private static func summary(
        for items: [WebPImageItem],
        minimumCompressionBytes: Int64
    ) -> WebPSelectionSummary {
        WebPSelectionSummary(
            imageCount: items.count,
            alreadyWebPCount: items.filter(\.isWebPSource).count,
            belowMinimumCount: items.filter {
                !$0.isWebPSource && $0.byteCount < minimumCompressionBytes
            }.count
        )
    }


    private func shouldSkipAtScan(_ image: ImageScannedImage) -> Bool {
        image.isWebP || image.byteCount < minimumCompressionSizeBytes
    }

    private func applyProcessEvents(from output: String) {
        for line in output.split(whereSeparator: \.isNewline) {
            applyProcessEventLine(String(line))
        }
    }

    private var minimumCompressionSizeBytes: Int64 {
        Int64(minimumCompressionSizeKB) * 1024
    }

    private static func normalizedQuality(_ value: Int) -> Int {
        min(max(1, value), 100)
    }

    private static func normalizedMinimumCompressionSizeKB(_ value: Int) -> Int {
        min(max(0, value), Self.maximumMinimumCompressionSizeKB)
    }

    private func refreshSkippedItems() {
        guard !imageItems.isEmpty, !isRunning, !isScanning, !isRestoring else { return }
        let minimumBytes = minimumCompressionSizeBytes
        imageItems = imageItems.map { item in
            switch item.status {
            case .waiting, .skipped, .cancelled, .failed:
                break
            case .success, .working:
                return item
            }
            var updated = item
            updated.status = isCompressionEnabled(for: item) ? .waiting : .skipped
            updated.clearResultMetrics()
            return updated
        }
        selectionSummary = Self.summary(for: imageItems, minimumCompressionBytes: minimumBytes)
    }

    private func appendProcessOutput(_ chunk: String) {
        guard isRunning else { return }
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
              let event = try? JSONDecoder().decode(ImageCompressionProcessEvent.self, from: data) else {
            return
        }
        applyProcessEvent(event)
    }

    func applyProcessEvent(_ event: ImageCompressionProcessEvent) {
        let sourceURL = URL(fileURLWithPath: event.src).resolvingSymlinksInPath()
        guard let index = imageItems.firstIndex(where: { $0.id.resolvingSymlinksInPath() == sourceURL }) else {
            return
        }

        var item = imageItems[index]
        if let dst = event.dst {
            item.destinationPath = dst
        }
        item.elapsedSeconds = event.elapsed
        if event.ok {
            item.status = .success
            item.resultReplacedOriginal = replaceOriginals
            item.convertedByteCount = event.after
            item.conversionPercentage = ImageCompressionSizeStats(
                beforeBytes: event.before,
                afterBytes: event.after
            ).savedPercentage
        } else if event.skipped == true {
            item.status = .skipped
            // Only attempted conversions become explicit exclusions; size-based skips still follow the threshold.
            if isCompressionEnabled(for: item) {
                item.compressionOverride = false
            }
            item.convertedByteCount = event.before
            item.conversionPercentage = 0
        } else {
            item.status = .failed(event.error)
        }
        imageItems[index] = item
    }
}

extension WebPImageItem {
    var isWebPSource: Bool {
        id.pathExtension.lowercased() == "webp"
    }
}

#Preview {
    NavigationStack {
        WebPConversionView()
    }
}
