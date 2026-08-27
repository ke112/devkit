import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct WebPConversionView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var model = WebPConversionModel()
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    @State private var isStatusPresented = false
    @State private var isLeaveConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("WebP 图片转换")
                    .font(.largeTitle.bold())
                Text("默认自动替换原图，关闭开关后写入同级时间戳文件夹；仅当 WebP 更小时才替换")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                HStack(spacing: 8) {
                    Text("转换质量")
                    TextField("80", value: $model.quality, format: .number)
                        .frame(width: 56)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text("（建议 75-85）")
                        .foregroundStyle(.secondary)
                }
                .disabled(model.isRunning || model.isScanning)
                .help("WebP 有损质量，75-85 在画质与体积之间性价比最高")

                HStack(spacing: 8) {
                    Text("最低转换大小")
                    TextField("100", value: $model.minimumCompressionSizeKB, format: .number)
                        .frame(width: 64)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text("KB 以上才转换")
                        .foregroundStyle(.secondary)
                }
                .disabled(model.isRunning || model.isScanning)
                .help("小于此大小的图片会跳过转换")

                HStack(spacing: 8) {
                    Text("最长边")
                    TextField("0", value: $model.maximumSideLength, format: .number)
                        .frame(width: 56)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                    Text("px，0 不缩放")
                        .foregroundStyle(.secondary)
                }
                .disabled(model.isRunning || model.isScanning)
                .help("最长边超过该像素时按比例缩小，适合网络加载图片进一步减小体积")
            }

            WebPDropArea(isTargeted: $isDropTargeted)
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                return model.select(urls: urls)
            } isTargeted: { targeted in
                isDropTargeted = targeted
            }

            selectionSummary

            if !model.selectedURLs.isEmpty {
                HStack(spacing: 12) {
                    Label("已选择 \(model.imageItems.count) 张图片", systemImage: "photo.stack")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Toggle("自动替换原图", isOn: $model.replaceOriginals)
                        .toggleStyle(.switch)
                        .help("开启后转换成功的图片会替换原文件；关闭后生成同级输出文件夹")
                        .disabled(model.isRunning || model.isScanning)
                    Button {
                        isStatusPresented = true
                    } label: {
                        Label("转换状态", systemImage: "list.bullet.rectangle")
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
                        if let stats = model.conversionStats {
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
                            model.isStopping ? "正在停止" : "停止转换",
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
                    Label("开始转换", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRun)
            }

            Spacer(minLength: 0)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .sheet(isPresented: $isStatusPresented) {
            WebPStatusSheet(model: model)
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
            Button("继续转换", role: .cancel) {}
        } message: {
            Text("当前任务尚未完成，离开后会停止转换。")
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
                ForEach(model.selectedURLs, id: \.self) { url in
                    Label(url.path, systemImage: WebPInputScanner.isDirectory(url) ? "folder" : "photo")
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                if let summary = model.selectionSummary {
                    HStack(spacing: 16) {
                        Text("图片 \(summary.imageCount) 张")
                        if summary.alreadyWebPCount > 0 {
                            Label("\(summary.alreadyWebPCount) 张已是 WebP，将跳过", systemImage: "checkmark.seal")
                                .foregroundStyle(.orange)
                        }
                        if summary.belowMinimumCount > 0 {
                            Label(
                                "\(summary.belowMinimumCount) 张小于最低大小，将跳过转换",
                                systemImage: "arrow.down.right.and.arrow.up.left"
                            )
                            .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 16) {
                        Text("转换前：\(TinyPNGFormat.bytes(model.totalOriginalByteCount))")
                        if let stats = model.conversionStats {
                            Text("转换后：\(TinyPNGFormat.bytes(stats.afterBytes))")
                            Text("减少：\(TinyPNGFormat.percent(stats.savedPercentage))")
                                .foregroundStyle(.green)
                        } else if model.isRunning {
                            Text("转换后：计算中")
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

private struct WebPDropArea: View {
    @Binding var isTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("拖入图片或文件夹，可一次拖入多个")
                .font(.title3.weight(.semibold))
            Text("PNG、JPG、JPEG、TIFF、BMP、GIF、HEIC，再次拖入可追加")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
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

private struct WebPStatusSheet: View {
    @Environment(\.dismiss) private var dismiss

    let model: WebPConversionModel
    @State private var isLogExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("转换状态")
                        .font(.title2.bold())
                    Text(model.selectedURLs.map(\.path).joined(separator: "\n"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Spacer()

                if model.outputDirectoryURL != nil {
                    Button {
                        model.revealOutputDirectory()
                    } label: {
                        Label("查看输出目录", systemImage: "folder")
                    }
                    .help("在 Finder 中显示转换结果")
                }

                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            List(model.imageItems) { item in
                WebPImageStatusRow(item: item) {
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

private struct WebPImageStatusRow: View {
    let item: WebPImageItem
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
                    if let convertedByteCount = item.convertedByteCount,
                       let conversionPercentage = item.conversionPercentage {
                        Text(
                            "原图：\(TinyPNGFormat.bytes(item.byteCount))  "
                                + "转换后：\(TinyPNGFormat.bytes(convertedByteCount))  "
                                + "减少：\(TinyPNGFormat.percent(conversionPercentage))"
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
            WebPImagePreview(imageURL: item.id)
        }
    }
}

private struct WebPImagePreview: View {
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

struct WebPSelectionSummary: Equatable, Sendable {
    let imageCount: Int
    let alreadyWebPCount: Int
    let belowMinimumCount: Int
}

enum WebPImageConversionStatus: Equatable {
    case waiting
    case converting
    case success
    case skipped
    case cancelled
    case failed(String)

    var title: String {
        switch self {
        case .waiting:
            "等待转换"
        case .converting:
            "转换中"
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
        case .converting:
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
        case .converting:
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

struct WebPImageItem: Identifiable, Equatable {
    let id: URL
    let relativePath: String
    let byteCount: Int64
    var status: WebPImageConversionStatus
    var convertedByteCount: Int64? = nil
    var conversionPercentage: Double? = nil
}

struct WebPConversionStats: Equatable {
    let beforeBytes: Int64
    let afterBytes: Int64

    var savedPercentage: Double {
        guard beforeBytes > 0 else { return 0 }
        return Double(beforeBytes - afterBytes) / Double(beforeBytes) * 100
    }
}

struct WebPScannedImage: Sendable {
    let url: URL
    let byteCount: Int64
    let isWebP: Bool
}

struct WebPScanResult: Sendable {
    let images: [WebPScannedImage]
}

enum WebPInputScanner {
    nonisolated static let defaultMinimumCompressionBytes: Int64 = 100 * 1024
    nonisolated static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff", "bmp", "gif", "heic", "heif", "webp",
    ]

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

    nonisolated static func scan(_ url: URL) -> WebPScanResult {
        if !isDirectory(url) {
            guard isSupportedImage(url),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = values.fileSize else {
                return WebPScanResult(images: [])
            }
            return WebPScanResult(images: [
                WebPScannedImage(
                    url: url,
                    byteCount: Int64(fileSize),
                    isWebP: isWebPImage(url)
                )
            ])
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return WebPScanResult(images: [])
        }

        var images: [WebPScannedImage] = []
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
                WebPScannedImage(
                    url: imageURL,
                    byteCount: Int64(fileSize),
                    isWebP: isWebPImage(imageURL)
                )
            )
        }

        images.sort {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        return WebPScanResult(images: images)
    }

    nonisolated private static func isSupportedImage(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated private static func isWebPImage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "webp"
    }
}

@MainActor
@Observable
final class WebPConversionModel {
    static let defaultQuality = 80
    static let defaultMinimumCompressionSizeKB = 100
    static let defaultMaximumSideLength = 0
    static let maximumMinimumCompressionSizeKB = Int(Int64.max / 1024)
    private static let qualityKey = "webp.quality"
    private static let minimumCompressionSizeKey = "webp.minimumCompressionSizeKB"
    private static let maximumSideLengthKey = "webp.maximumSideLength"

    var selectedURLs: [URL] = []
    var selectionSummary: WebPSelectionSummary?
    var imageItems: [WebPImageItem] = []
    var replaceOriginals = true
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

    private var scanWorker: Task<[WebPScanResult], Never>?
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
            case .waiting, .converting, .cancelled, .failed:
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

    var conversionStats: WebPConversionStats? {
        guard !imageItems.isEmpty,
              imageItems.allSatisfy({ $0.convertedByteCount != nil }) else {
            return nil
        }
        return WebPConversionStats(
            beforeBytes: totalOriginalByteCount,
            afterBytes: imageItems.reduce(0) { $0 + ($1.convertedByteCount ?? 0) }
        )
    }

    @discardableResult
    func select(urls: [URL]) -> Bool {
        guard !isRunning else { return false }
        let standardizedURLs = urls.map(\.standardizedFileURL)
        let existingPaths = Set(selectedURLs.map(\.path))
        let newURLs = standardizedURLs.filter { !existingPaths.contains($0.path) }
        let acceptedURLs = newURLs.filter(WebPInputScanner.accepts(_:))
        guard !acceptedURLs.isEmpty else {
            showError("请选择文件夹，或选择 PNG、JPG、HEIC 等图片。")
            return false
        }

        scanWorker?.cancel()
        scanWorker = nil
        isScanning = false
        activeSelectionToken = UUID()
        selectedURLs.append(contentsOf: acceptedURLs)
        isScanning = true
        operationStatus = "正在扫描图片"
        operationStatusSystemImage = "arrow.triangle.2.circlepath"
        alertMessage = nil

        let selectionToken = UUID()
        activeSelectionToken = selectionToken
        let scannedURLs = acceptedURLs
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
            isScanning = false

            var knownPaths = Set(imageItems.map(\.id.path))
            var appendedItems: [WebPImageItem] = []
            for (index, result) in results.enumerated() {
                let inputURL = scannedURLs[index]
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
            }

            guard !appendedItems.isEmpty else {
                selectedURLs.removeSubrange((selectedURLs.count - scannedURLs.count)...)
                operationStatus = selectedURLs.isEmpty ? "请选择图片或文件夹" : "已选择，等待开始"
                operationStatusSystemImage = selectedURLs.isEmpty ? "photo.on.rectangle" : "checkmark.circle"
                alertMessage = "新添加的路径中没有可转换的图片。"
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
            updated.status = .converting
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

        Task { [weak self, inputURLs, scriptURL, hasSecurityScopes, shouldReplaceOriginals, cancellation] in
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
                        guard case .converting = item.status else { return item }
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
                        guard case .converting = item.status else { return item }
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
                    guard case .converting = item.status else { return item }
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
            guard case .converting = item.status else { return item }
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

    func revealSource(for item: WebPImageItem) {
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
            return imageURL.path.replacingOccurrences(
                of: inputURL.path + "/",
                with: ""
            )
        }
        return imageURL.lastPathComponent
    }

    private func shouldSkipAtScan(_ image: WebPScannedImage) -> Bool {
        image.isWebP || image.byteCount < minimumCompressionSizeBytes
    }

    private func applyProcessEvents(from output: String) {
        for line in output.split(whereSeparator: \.isNewline) {
            applyProcessEventLine(String(line))
        }
    }

    private func finalizeSkippedItems() {
        imageItems = imageItems.map { item in
            guard case .skipped = item.status, item.convertedByteCount == nil else {
                return item
            }
            var updated = item
            updated.convertedByteCount = item.byteCount
            updated.conversionPercentage = 0
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
            case .success, .converting, .cancelled, .failed:
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
              let event = try? JSONDecoder().decode(WebPProcessEvent.self, from: data) else {
            return
        }

        let sourceURL = URL(fileURLWithPath: event.src).standardizedFileURL
        guard let index = imageItems.firstIndex(where: { $0.id.path == sourceURL.path }) else {
            return
        }

        var item = imageItems[index]
        if event.ok {
            item.status = .success
            item.convertedByteCount = event.after
            item.conversionPercentage = WebPConversionStats(
                beforeBytes: event.before,
                afterBytes: event.after
            ).savedPercentage
        } else if event.skipped {
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

private struct WebPProcessEvent: Decodable {
    let src: String
    let ok: Bool
    let before: Int64
    let after: Int64
    let skipped: Bool
    let error: String
}

#Preview {
    NavigationStack {
        WebPConversionView()
    }
}
