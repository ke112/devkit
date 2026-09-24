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
}

extension WebPImageItem: ImageCompressionTaskItem {
    var resultByteCount: Int64? { convertedByteCount }
    var resultPercentage: Double? { conversionPercentage }
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
final class WebPConversionModel {
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
    var replaceOriginals = false
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
    var output = ""
    var operationStatus = "请选择图片或文件夹"
    var operationStatusSystemImage = "photo.on.rectangle"
    var alertMessage: String?
    var outputDirectoryURL: URL?

    private var scanWorker: Task<[ImageScanResult], Never>?
    private var pendingScanURLs: [URL] = []
    private var activeSelectionToken = UUID()
    private var outputEventBuffer = ""
    private var processCancellation: StreamingProcessCancellation?
    private let preferencesDefaults: UserDefaults

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

    var conversionStats: ImageCompressionSizeStats? {
        guard !imageItems.isEmpty,
              imageItems.allSatisfy({ $0.convertedByteCount != nil }) else {
            return nil
        }
        return ImageCompressionSizeStats(
            beforeBytes: totalOriginalByteCount,
            afterBytes: imageItems.reduce(0) { $0 + ($1.convertedByteCount ?? 0) }
        )
    }

    @discardableResult
    func select(urls: [URL]) -> Bool {
        guard !isRunning else { return false }
        let standardizedURLs = urls.map(\.standardizedFileURL)
        let validURLs = standardizedURLs.filter(WebPInputScanner.accepts(_:))
        guard !validURLs.isEmpty else {
            showError("请选择文件夹，或选择 PNG、JPG、HEIC 等图片。")
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
        operationStatus = "正在扫描图片"
        operationStatusSystemImage = "arrow.triangle.2.circlepath"
        alertMessage = nil

        let selectionToken = UUID()
        activeSelectionToken = selectionToken
        // Include the previous pending batch when replacing an in-flight scan.
        let scannedURLs = pendingScanURLs
        let worker = Task.detached(priority: .userInitiated) {
            scannedURLs.map { WebPInputScanner.scan($0) }
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
            var appendedItems: [WebPImageItem] = []
            for (index, result) in results.enumerated() {
                let inputURL = scannedURLs[index]
                let previousCount = appendedItems.count
                for image in result.images where knownPaths.insert(image.url.path).inserted {
                    appendedItems.append(
                        WebPImageItem(
                            id: image.url,
                            relativePath: relativePath(for: image.url, inputURL: inputURL),
                            byteCount: image.byteCount,
                            status: shouldSkipAtScan(image) ? .skipped : .waiting
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
                    alertMessage = "新添加的路径中没有可转换的图片。"
                }
                return
            }

            imageItems.append(contentsOf: appendedItems)
            selectionSummary = Self.summary(for: imageItems, minimumCompressionBytes: minimumCompressionSizeBytes)
            operationStatus = "已选择，等待开始"
            operationStatusSystemImage = "checkmark.circle"
        }
        return true
    }

    func run() {
        guard canRun else { return }
        guard let scriptURL = Bundle.main.url(forResource: "webp_convert", withExtension: "py") else {
            showError("App 内缺少 WebP 转换脚本：webp_convert.py")
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
        operationStatus = "正在转换"
        operationStatusSystemImage = "arrow.triangle.2.circlepath"
        alertMessage = nil
        let shouldReplaceOriginals = replaceOriginals
        let selectedQuality = quality
        let minimumCompressionSizeKB = minimumCompressionSizeKB
        let maximumSideLength = maximumSideLength
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
                var arguments: [String] = [
                    "-l",
                    "-c",
                    "exec python3 -u \"$@\"",
                    "devkit",
                    scriptURL.path,
                ]
                arguments.append(contentsOf: inputURLs.map(\.path))
                arguments.append(contentsOf: ["--quality", String(selectedQuality)])
                arguments.append(contentsOf: ["--min-size-kb", String(minimumCompressionSizeKB)])
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
                        ? "转换完成（跳过 \(skippedCount) 张图片）"
                        : "转换完成"
                    operationStatusSystemImage = "checkmark.circle"
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

    private func relativePath(for imageURL: URL, inputURL: URL) -> String {
        if WebPInputScanner.isDirectory(inputURL) {
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
            return imageURL.lastPathComponent
        }
        return imageURL.lastPathComponent
    }

    private func shouldSkipAtScan(_ image: ImageScannedImage) -> Bool {
        image.isWebP || image.byteCount < minimumCompressionSizeBytes
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
            guard case .skipped = item.status, item.convertedByteCount == nil else {
                return item
            }
            var updated = item
            updated.convertedByteCount = item.byteCount
            updated.conversionPercentage = 0
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

    private static func normalizedQuality(_ value: Int) -> Int {
        min(max(1, value), 100)
    }

    private static func normalizedMinimumCompressionSizeKB(_ value: Int) -> Int {
        min(max(0, value), Self.maximumMinimumCompressionSizeKB)
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
            let shouldSkip = item.isWebPSource || item.byteCount < minimumBytes
            updated.status = shouldSkip ? .skipped : .waiting
            updated.convertedByteCount = nil
            updated.conversionPercentage = nil
            return updated
        }
        selectionSummary = Self.summary(for: imageItems, minimumCompressionBytes: minimumBytes)
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
        if let dst = event.dst {
            item.destinationPath = dst
        }
        item.elapsedSeconds = event.elapsed
        if event.ok {
            item.status = .success
            item.convertedByteCount = event.after
            item.conversionPercentage = ImageCompressionSizeStats(
                beforeBytes: event.before,
                afterBytes: event.after
            ).savedPercentage
        } else if event.skipped == true {
            item.status = .skipped
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
