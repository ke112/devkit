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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("TinyPNG 图片压缩")
                    .font(.largeTitle.bold())
                Text("默认输出到 ~/Desktop/DevKitOutput 时间戳文件夹；开启后压缩成功替换原图")
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
                    .help("开启后压缩成功的图片会替换原文件；关闭后生成同级输出文件夹")
                    .disabled(model.isRunning || model.isScanning)
            }

            ImageCompressionDropArea(isTargeted: $isDropTargeted)
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                return model.select(urls: urls)
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

            if !model.imageItems.isEmpty {
                List(model.imageItems) { item in
                    TinyPNGTaskRow(item: item) {
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
        if !model.selectedURLs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.selectedURLs.map(\.path).joined(separator: "\n"))
                    .lineLimit(3)
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
                        if summary.belowMinimumCount > 0 {
                            Label(
                                "\(summary.belowMinimumCount) 张小于最低大小，将跳过压缩",
                                systemImage: "arrow.down.right.and.arrow.up.left"
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

private struct TinyPNGTaskRow: View {
    let item: TinyPNGImageItem
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
            TinyPNGImagePreview(imageURL: item.id)
        }
    }

    private var sizeSummary: String? {
        if let compressedByteCount = item.compressedByteCount,
           let compressionPercentage = item.compressionPercentage {
            return "原图：\(TinyPNGFormat.bytes(item.byteCount))  压缩后：\(TinyPNGFormat.bytes(compressedByteCount))  减少：\(TinyPNGFormat.percent(compressionPercentage))"
        }
        return "原图：\(TinyPNGFormat.bytes(item.byteCount))"
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
    var elapsedSeconds: Double? = nil
    var destinationPath: String? = nil
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
        summary()
    }

    nonisolated func summary(minimumCompressionBytes: Int64 = TinyPNGInputScanner.defaultMinimumCompressionBytes) -> TinyPNGSelectionSummary {
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
    nonisolated static let maxUploadBytes: Int64 = 5 * 1024 * 1024
    nonisolated static let defaultMinimumCompressionBytes: Int64 = 100 * 1024
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
        scan(url).summary()
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
            updated.status = .uploading
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
                        guard case .uploading = item.status else { return item }
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
            guard case .uploading = item.status else { return item }
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
            case .success, .uploading, .cancelled, .failed:
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
              let event = try? JSONDecoder().decode(TinyPNGProcessEvent.self, from: data) else {
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
    let dst: String?
    let ok: Bool
    let before: Int64
    let after: Int64
    let elapsed: Double?
    let error: String
}

#Preview {
    NavigationStack {
        TinyPNGView()
    }
}
