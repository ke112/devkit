import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct TinyPNGView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var model = TinyPNGModel()
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    @State private var isLeaveConfirmationPresented = false

    var body: some View {
        ImageCompressionPageLayout(
            title: "TinyPNG 图片压缩",
            subtitle: "默认输出到 ~/Desktop/DevKitOutput 时间戳文件夹；开启后压缩成功替换原图",
            replaceHelp: "开启后压缩成功的图片会替换原文件；关闭后生成输出时间戳文件夹",
            dropSubtitle: "PNG、JPG、JPEG、WebP",
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
            hasProgress: model.hasProgress,
            progressFraction: model.progressFraction,
            completedCount: model.completedImageCount,
            totalCount: model.imageItems.count,
            completionPercentage: model.completionPercentage,
            statsText: statsText,
            tasks: taskDisplayModels,
            onDrop: { urls in
                guard !urls.isEmpty else { return false }
                return model.select(urls: urls)
            },
            onClear: { model.clearSelection() },
            onStop: { model.stop() },
            onChooseFiles: { isImporterPresented = true },
            onStart: { model.run() },
            extras: { EmptyView() }
        )
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
        model.imageItems.map { ImageTaskDisplayModel(item: $0, resultLabel: "压缩后", verb: "上传") }
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

struct TinyPNGSelectionSummary: Equatable, Sendable {
    let imageCount: Int
    let oversizedCount: Int
    let belowMinimumCount: Int

    nonisolated init(imageCount: Int, oversizedCount: Int, belowMinimumCount: Int = 0) {
        self.imageCount = imageCount
        self.oversizedCount = oversizedCount
        self.belowMinimumCount = belowMinimumCount
    }
}

struct TinyPNGImageItem: Identifiable, Equatable {
    let id: URL
    let relativePath: String
    let byteCount: Int64
    var status: ImageCompressionTaskStatus
    var compressedByteCount: Int64? = nil
    var compressionPercentage: Double? = nil
    var elapsedSeconds: Double? = nil
    var destinationPath: String? = nil
}

extension TinyPNGImageItem: ImageCompressionTaskItem {
    var resultByteCount: Int64? { compressedByteCount }
    var resultPercentage: Double? { compressionPercentage }
}

typealias TinyPNGScannedImage = ImageScannedImage
typealias TinyPNGScanResult = ImageScanResult

extension ImageScanResult {
    /// TinyPNG 专用汇总：超过上传上限计入 oversized，低于最小压缩大小计入 belowMinimum。
    nonisolated var summary: TinyPNGSelectionSummary { summary() }

    nonisolated func summary(
        minimumCompressionBytes: Int64 = TinyPNGInputScanner.defaultMinimumCompressionBytes
    ) -> TinyPNGSelectionSummary {
        TinyPNGSelectionSummary(
            imageCount: images.count,
            oversizedCount: images.reduce(into: 0) { count, image in
                if image.byteCount > TinyPNGInputScanner.maxUploadBytes {
                    count += 1
                }
            },
            belowMinimumCount: images.reduce(into: 0) { count, image in
                if image.byteCount < minimumCompressionBytes {
                    count += 1
                }
            }
        )
    }
}

enum TinyPNGInputScanner {
    /// TinyPNG 服务端限制单张 5 MB，超限跳过上传
    nonisolated static let maxUploadBytes: Int64 = 5 * 1024 * 1024
    nonisolated static let defaultMinimumCompressionBytes: Int64 = 100 * 1024
    nonisolated static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    nonisolated static func accepts(_ url: URL) -> Bool {
        ImageTaskScanner.accepts(url, supportedExtensions: supportedExtensions)
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        ImageTaskScanner.isDirectory(url)
    }

    nonisolated static func scan(_ url: URL) -> ImageScanResult {
        ImageTaskScanner.scan(url, supportedExtensions: supportedExtensions)
    }

    nonisolated static func summary(for url: URL) -> TinyPNGSelectionSummary {
        scan(url).summary()
    }
}

@MainActor
@Observable
final class TinyPNGModel {
    static let defaultMinimumCompressionSizeKB = 0
    static let maximumMinimumCompressionSizeKB = Int(Int64.max / 1024)
    private static let minimumCompressionSizeKey = "tinypng.minimumCompressionSizeKB.v2"

    var selectedURLs: [URL] = []
    var selectionSummary: TinyPNGSelectionSummary?
    var imageItems: [TinyPNGImageItem] = []
    var replaceOriginals = false
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
    var isScanning = false
    var isRunning = false
    var isStopping = false
    var output = ""
    var operationStatus = "请选择图片或文件夹"
    var operationStatusSystemImage = "photo.on.rectangle"
    var alertMessage: String?
    var outputDirectoryURL: URL?

    private var scanWorker: Task<[TinyPNGScanResult], Never>?
    private var pendingScanURLs: [URL] = []
    private var activeSelectionToken = UUID()
    private var outputEventBuffer = ""
    private var processCancellation: StreamingProcessCancellation?
    private let preferencesDefaults: UserDefaults

    init(preferencesDefaults: UserDefaults = .standard) {
        self.preferencesDefaults = preferencesDefaults
        let storedValue = preferencesDefaults.object(forKey: Self.minimumCompressionSizeKey) as? Int
        self.minimumCompressionSizeKB = Self.normalizedMinimumCompressionSizeKB(
            storedValue ?? Self.defaultMinimumCompressionSizeKB
        )
    }

    var canRun: Bool {
        !selectedURLs.isEmpty
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

    var compressionStats: ImageCompressionSizeStats? {
        guard !imageItems.isEmpty,
              imageItems.allSatisfy({ $0.compressedByteCount != nil }) else {
            return nil
        }
        return ImageCompressionSizeStats(
            beforeBytes: totalOriginalByteCount,
            afterBytes: imageItems.reduce(0) { $0 + ($1.compressedByteCount ?? 0) }
        )
    }

    @discardableResult
    func select(urls: [URL]) -> Bool {
        guard !isRunning else { return false }
        let standardizedURLs = urls.map(\.standardizedFileURL)
        let validURLs = standardizedURLs.filter(TinyPNGInputScanner.accepts(_:))
        guard !validURLs.isEmpty else {
            showError("请选择文件夹，或选择 PNG、JPG、JPEG、WebP 图片。")
            return false
        }
        var knownRoots = Set((selectedURLs + pendingScanURLs).map(\.path))
        let initiallyAcceptedURLs = validURLs.filter { knownRoots.insert($0.path).inserted }
        let acceptedURLs = initiallyAcceptedURLs.filter { url in
            !initiallyAcceptedURLs.contains { root in
                root.path != url.path && url.path.hasPrefix(root.path + "/")
            }
        }
        guard !acceptedURLs.isEmpty else {
            return true
        }

        scanWorker?.cancel()
        scanWorker = nil
        isScanning = false
        activeSelectionToken = UUID()
        pendingScanURLs.append(contentsOf: acceptedURLs)
        isScanning = true
        output = ""
        outputEventBuffer = ""
        outputDirectoryURL = nil
        operationStatus = "正在扫描图片"
        operationStatusSystemImage = "arrow.triangle.2.circlepath"
        alertMessage = nil

        let selectionToken = UUID()
        activeSelectionToken = selectionToken
        let minimumCompressionBytes = minimumCompressionSizeBytes
        // Include the previous pending batch when replacing an in-flight scan.
        let scannedURLs = pendingScanURLs
        let worker = Task.detached(priority: .userInitiated) {
            scannedURLs.map { TinyPNGInputScanner.scan($0) }
        }
        scanWorker = worker

        Task { @MainActor [weak self, selectionToken, worker] in
            let results = await worker.value
            guard let self,
                  self.activeSelectionToken == selectionToken,
                  !worker.isCancelled else {
                return
            }

            scanWorker = nil
            pendingScanURLs = []
            isScanning = false
            var knownPaths = Set(imageItems.map(\.id.path))
            var appendedItems: [TinyPNGImageItem] = []
            for (index, result) in results.enumerated() {
                let inputURL = scannedURLs[index]
                let previousCount = appendedItems.count
                for image in result.images where knownPaths.insert(image.url.path).inserted {
                    appendedItems.append(
                        TinyPNGImageItem(
                            id: image.url,
                            relativePath: self.relativePath(for: image.url, inputURL: inputURL),
                            byteCount: image.byteCount,
                            status: self.shouldSkip(image.byteCount, minimumCompressionBytes: minimumCompressionBytes)
                                ? .skipped
                                : .waiting
                        )
                    )
                }
                if appendedItems.count > previousCount {
                    selectedURLs.append(inputURL)
                }
            }

            guard !appendedItems.isEmpty else {
                operationStatus = selectedURLs.isEmpty ? "请选择图片或文件夹" : "已选择，等待开始"
                operationStatusSystemImage = selectedURLs.isEmpty ? "photo.on.rectangle" : "checkmark.circle"
                if results.allSatisfy({ $0.images.isEmpty }) {
                    alertMessage = "新添加的路径中没有可压缩的 PNG、JPG、JPEG 或 WebP 图片。"
                }
                return
            }

            imageItems.append(contentsOf: appendedItems)
            selectionSummary = TinyPNGSelectionSummary(
                imageCount: imageItems.count,
                oversizedCount: imageItems.filter { $0.byteCount > TinyPNGInputScanner.maxUploadBytes }.count,
                belowMinimumCount: imageItems.filter { $0.byteCount < minimumCompressionBytes }.count
            )
            operationStatus = "已选择，等待开始"
            operationStatusSystemImage = "checkmark.circle"
        }
        return true
    }

    func run() {
        guard canRun, !selectedURLs.isEmpty else { return }
        guard let scriptURL = Bundle.main.url(forResource: "tinypng", withExtension: "py") else {
            showError("App 内缺少 TinyPNG 脚本：tinypng.py")
            return
        }

        let inputURLs = selectedURLs
        let hasSecurityScopes = inputURLs.map { $0.startAccessingSecurityScopedResource() }
        isRunning = true
        isStopping = false
        let cancellation = StreamingProcessCancellation()
        processCancellation = cancellation
        imageItems = imageItems.map { item in
            guard case .waiting = item.status else { return item }
            var updated = item
            updated.status = .working
            return updated
        }
        output = ""
        outputDirectoryURL = nil
        operationStatus = "正在压缩"
        operationStatusSystemImage = "arrow.triangle.2.circlepath"
        alertMessage = nil
        let shouldReplaceOriginals = replaceOriginals
        let minimumCompressionSizeKB = minimumCompressionSizeKB
        // 非替换模式统一输出到 ~/Desktop/DevKit/<功能名>_<时间戳>/
        let unifiedOutputBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/DevKitOutput", isDirectory: true)

        Task { [weak self, inputURLs, scriptURL, hasSecurityScopes, shouldReplaceOriginals, cancellation, unifiedOutputBase] in
            defer {
                for (index, url) in inputURLs.enumerated()
                where index < hasSecurityScopes.count && hasSecurityScopes[index] {
                    url.stopAccessingSecurityScopedResource()
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
                    ] + inputURLs.map(\.path)
                        + (shouldReplaceOriginals ? ["--replace"] : [])
                        + ["--min-size-kb", String(minimumCompressionSizeKB)]
                        + (shouldReplaceOriginals ? [] : ["--output-dir", unifiedOutputBase.path]),
                    currentDirectoryURL: inputURLs[0].deletingLastPathComponent(),
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
                        guard case .working = item.status else { return item }
                        var updated = item
                        updated.status = .success
                        return updated
                    }
                    let skippedCount = imageItems.filter {
                        if case .skipped = $0.status { return true }
                        return false
                    }.count
                    operationStatus = skippedCount > 0
                        ? "压缩完成（跳过 \(skippedCount) 张图片）"
                        : "压缩完成"
                    operationStatusSystemImage = "checkmark.circle"
                } else {
                    imageItems = imageItems.map { item in
                        guard case .working = item.status else { return item }
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
                    guard case .working = item.status else { return item }
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
            pendingScanURLs = []
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
        guard !isRunning, !isScanning else { return }
        scanWorker?.cancel()
        scanWorker = nil
        pendingScanURLs = []
        activeSelectionToken = UUID()
        selectedURLs = []
        selectionSummary = nil
        imageItems = []
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

    private func relativePath(for imageURL: URL, inputURL: URL) -> String {
        if TinyPNGInputScanner.isDirectory(inputURL) {
            let privateRelative = imageURL.path.replacingOccurrences(
                of: "/private" + inputURL.path + "/",
                with: ""
            )
            if privateRelative != imageURL.path {
                return privateRelative
            }
            let standardizedRelative = imageURL.path.replacingOccurrences(
                of: inputURL.standardizedFileURL.path + "/",
                with: ""
            )
            if standardizedRelative != imageURL.path {
                return standardizedRelative
            }
            let relative = imageURL.path.replacingOccurrences(
                of: inputURL.path + "/",
                with: ""
            )
            if relative != imageURL.path {
                return relative
            }
            return imageURL.path.replacingOccurrences(
                of: inputURL.standardizedFileURL.path + "/",
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
        // 跳过项补输出路径：替换模式 = 原文件；非替换单根输入 = 输出目录内同相对路径（多根结构由脚本分组，无法可靠推导则不显示）
        let outputBase = outputDirectoryURL
        let isSingleRoot = selectedURLs.count == 1
        imageItems = imageItems.map { item in
            guard case .skipped = item.status, item.compressedByteCount == nil else {
                return item
            }
            var updated = item
            updated.compressedByteCount = item.byteCount
            updated.compressionPercentage = 0
            if outputBase == nil {
                updated.destinationPath = item.id.path
            } else if isSingleRoot {
                updated.destinationPath = outputBase?
                    .appendingPathComponent(item.relativePath).path
            }
            return updated
        }
    }

    private var minimumCompressionSizeBytes: Int64 {
        Int64(minimumCompressionSizeKB) * 1024
    }

    private static func normalizedMinimumCompressionSizeKB(_ value: Int) -> Int {
        min(max(0, value), Self.maximumMinimumCompressionSizeKB)
    }

    private func shouldSkip(_ byteCount: Int64, minimumCompressionBytes: Int64) -> Bool {
        byteCount > TinyPNGInputScanner.maxUploadBytes || byteCount < minimumCompressionBytes
    }

    private func refreshSkippedItems() {
        guard !imageItems.isEmpty, !isRunning, !isScanning else { return }
        let minimumBytes = minimumCompressionSizeBytes
        imageItems = imageItems.map { item in
            switch item.status {
            case .waiting, .skipped:
                break
            case .success, .working, .cancelled, .failed:
                return item
            }
            var updated = item
            updated.status = shouldSkip(item.byteCount, minimumCompressionBytes: minimumBytes) ? .skipped : .waiting
            updated.compressedByteCount = nil
            updated.compressionPercentage = nil
            return updated
        }
        selectionSummary = TinyPNGSelectionSummary(
            imageCount: imageItems.count,
            oversizedCount: imageItems.filter { $0.byteCount > TinyPNGInputScanner.maxUploadBytes }.count,
            belowMinimumCount: imageItems.filter { $0.byteCount < minimumBytes }.count
        )
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
              let event = try? JSONDecoder().decode(ImageCompressionProcessEvent.self, from: data) else {
            return
        }

        let sourceURL = URL(fileURLWithPath: event.src).standardizedFileURL
        guard let index = imageItems.firstIndex(where: { $0.id.path == sourceURL.path }) else {
            return
        }

        var item = imageItems[index]
        item.status = event.ok ? .success : .failed(event.error)
        if let dst = event.dst {
            item.destinationPath = dst
        }
        item.elapsedSeconds = event.elapsed
        if event.ok {
            item.compressedByteCount = event.after
            item.compressionPercentage = ImageCompressionSizeStats(
                beforeBytes: event.before,
                afterBytes: event.after
            ).savedPercentage
        }
        imageItems[index] = item
    }
}

#Preview {
    NavigationStack {
        TinyPNGView()
    }
}
