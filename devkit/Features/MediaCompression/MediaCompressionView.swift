import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MediaCompressionView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var mode: MediaCompressionMode = .image
    @State private var imageTasks: [MediaImageTask] = []
    @State private var videoTasks: [MediaVideoTask] = []
    @State private var targetSizeKB = "200"
    @State private var outputFormat: MediaOutputFormat = .auto
    @State private var videoPreset: MediaVideoPreset = .medium
    @State private var outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    @State private var isRunning = false
    @State private var isDropTargeted = false
    @State private var progress = 0.0
    @State private var message = "拖入图片、视频或文件夹，或点击下方按钮选择。"
    @State private var previewItem: MediaImageTask?
    @State private var showFileNotFound = false
    @State private var showLeaveConfirmation = false
    @State private var worker: Task<Void, Never>?

    private let imageCompressor = MediaImageCompressor()
    private let videoCompressor = MediaVideoCompressor()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            Picker("媒体类型", selection: $mode) {
                ForEach(MediaCompressionMode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .disabled(isRunning)

            dropArea
            settings
            selectionSummary
            actionBar
            progressPanel
            resultList
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("媒体压缩")
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
            if isRunning { worker?.cancel() }
        }
        .sheet(item: $previewItem) { item in
            MediaCompressionPreview(item: item)
        }
        .alert("文件不存在", isPresented: $showFileNotFound) {
            Button("好", role: .cancel) {}
        } message: {
            Text("目标文件可能已被手动删除或移动。")
        }
        .alert("正在压缩", isPresented: $showLeaveConfirmation) {
            Button("停止并离开", role: .destructive) {
                stop()
                dismiss()
            }
            Button("继续压缩", role: .cancel) {}
        } message: {
            Text("当前任务尚未完成，离开后会停止压缩。")
        }
        .fileImporter(
            isPresented: fileImporterPresented,
            allowedContentTypes: [.item, .folder, .image, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): append(urls)
            case .failure(let error): message = error.localizedDescription
            }
        }
        .onChange(of: mode) { _, _ in
            progress = 0
            message = mode == .image ? "拖入图片或文件夹，或点击下方按钮选择。" : "拖入视频或文件夹，或点击下方按钮选择。"
        }
    }

    @State private var isImporterPresented = false

    private var fileImporterPresented: Binding<Bool> {
        $isImporterPresented
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("媒体压缩")
                .font(.largeTitle.bold())
            Text("本地处理图片目标体积和视频质量，输出到 DevKit 文件夹")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var dropArea: some View {
        VStack(spacing: 12) {
            Image(systemName: mode == .image ? "photo.on.rectangle.angled" : "film")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            Text(mode == .image ? "拖入图片或文件夹" : "拖入视频或文件夹")
                .font(.title3.weight(.semibold))
            Text(mode == .image ? "支持 PNG、JPG、HEIC、WebP、TIFF、BMP、GIF、TGA、PSD" : "支持 MP4、MOV、M4V")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
        .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [8])
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            append(urls)
            return !urls.isEmpty
        } isTargeted: { isDropTargeted = $0 }
    }

    @ViewBuilder
    private var settings: some View {
        HStack(spacing: 24) {
            if mode == .image {
                settingField(title: "目标大小", suffix: "KB", value: $targetSizeKB, placeholder: "200")
                VStack(alignment: .leading, spacing: 6) {
                    Text("输出格式").font(.caption.weight(.semibold))
                    Picker("输出格式", selection: $outputFormat) {
                        ForEach(MediaOutputFormat.allCases) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("压缩质量").font(.caption.weight(.semibold))
                    Picker("压缩质量", selection: $videoPreset) {
                        ForEach(MediaVideoPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("输出目录").font(.caption.weight(.semibold))
                HStack(spacing: 8) {
                    Text(outputDirectory?.lastPathComponent ?? "下载")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 180, alignment: .leading)
                    Button("选择") { chooseOutputDirectory() }
                }
            }

            Spacer()

            Button("重置设置") {
                targetSizeKB = "200"
                outputFormat = .auto
                videoPreset = .medium
                outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                message = "已重置为默认设置。"
            }
            .disabled(isRunning)
        }
        .disabled(isRunning)
    }

    private func settingField(title: String, suffix: String, value: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            HStack(spacing: 6) {
                TextField(placeholder, text: value)
                    .frame(width: 72)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                Text(suffix).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var selectionSummary: some View {
        let count = mode == .image ? imageTasks.count : videoTasks.count
        if count > 0 {
            HStack(spacing: 16) {
                Label("已选择 \(count) 个文件", systemImage: mode == .image ? "photo.stack" : "film.stack")
                    .foregroundStyle(.secondary)
                Text("输出：DevKit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    clearCurrentTasks()
                } label: {
                    Label("清空列表", systemImage: "trash")
                }
                .disabled(isRunning)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                isImporterPresented = true
            } label: {
                Label("选择文件或文件夹", systemImage: "folder")
            }
            .disabled(isRunning)

            Button {
                start()
            } label: {
                Label(mode == .image ? "开始压缩" : "开始压缩", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(currentTaskCount == 0 || isRunning)

            if isRunning {
                Button {
                    stop()
                } label: {
                    Label("停止", systemImage: "stop.circle")
                }
                .tint(.red)
            }
            Spacer()
        }
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var resultList: some View {
        if mode == .image {
            List(imageTasks) { item in imageRow(item) }
                .frame(minHeight: 220)
        } else {
            List(videoTasks) { item in videoRow(item) }
                .frame(minHeight: 220)
        }
    }

    private func imageRow(_ item: MediaImageTask) -> some View {
        HStack(spacing: 12) {
            if let image = NSImage(contentsOf: item.sourceURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "photo")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.sourceURL.lastPathComponent).font(.headline).lineLimit(1)
                HStack(spacing: 10) {
                    Text("原始：\(mediaFormatBytes(item.originalBytes))")
                    Text("结果：\(mediaFormatBytes(item.compressedBytes))")
                    if let format = item.usedFormat { Text(format).foregroundStyle(.tint) }
                    if let size = item.originalSize, let compressed = item.compressedSize, size != compressed {
                        Text("\(mediaFormatDimensions(size)) → \(mediaFormatDimensions(compressed))")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                stateLabel(item.state)
                    .font(.caption)
            }
            Spacer()
            if item.state == .success, let destination = item.destinationURL {
                Button {
                    guard FileManager.default.fileExists(atPath: destination.path) else { showFileNotFound = true; return }
                    previewItem = item
                } label: { Image(systemName: "eye") }
                    .help("压缩前后对比预览")
            }
            if let destination = item.destinationURL, item.state != .processing {
                revealButton(for: destination)
            }
        }
        .padding(.vertical, 4)
    }

    private func videoRow(_ item: MediaVideoTask) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.sourceURL.lastPathComponent).font(.headline).lineLimit(1)
                HStack(spacing: 10) {
                    Text("原始：\(mediaFormatBytes(item.originalBytes))")
                    Text("结果：\(mediaFormatBytes(item.compressedBytes))")
                    if let duration = item.duration { Text("时长：\(String(format: "%.1fs", duration))") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                stateLabel(item.state)
                    .font(.caption)
            }
            Spacer()
            if let destination = item.destinationURL, item.state != .processing { revealButton(for: destination) }
        }
        .padding(.vertical, 4)
    }

    private func revealButton(for url: URL) -> some View {
        Button {
            guard FileManager.default.fileExists(atPath: url.path) else { showFileNotFound = true; return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: { Image(systemName: "folder") }
            .help("在 Finder 中显示")
    }

    @ViewBuilder
    private func stateLabel(_ state: MediaCompressionState) -> some View {
        switch state {
        case .pending: Text("待处理").foregroundStyle(.secondary)
        case .processing: Text("处理中...").foregroundStyle(.orange)
        case .success: Text("已完成").foregroundStyle(.green)
        case .skipped: Text("已复制原文件（无需压缩）").foregroundStyle(.blue)
        case .copiedFallback: Text("压缩后更大，已保留原文件").foregroundStyle(.orange)
        case .failed(let reason): Text(reason).foregroundStyle(.red).lineLimit(1)
        }
    }

    private var currentTaskCount: Int { mode == .image ? imageTasks.count : videoTasks.count }

    private func append(_ urls: [URL]) {
        if mode == .image {
            let existing = Set(imageTasks.map { $0.sourceURL.standardizedFileURL.path })
            let items = imageCompressor.collectImages(from: urls)
                .filter { !existing.contains($0.url.standardizedFileURL.path) }
                .map { MediaImageTask(sourceURL: $0.url, relativeDir: $0.relativeDir) }
            imageTasks.append(contentsOf: items)
            message = items.isEmpty ? "未发现可压缩的图片文件。" : "已加入 \(items.count) 张图片。"
        } else {
            let existing = Set(videoTasks.map { $0.sourceURL.standardizedFileURL.path })
            let items = videoCompressor.collectVideos(from: urls)
                .filter { !existing.contains($0.url.standardizedFileURL.path) }
                .map { MediaVideoTask(sourceURL: $0.url, relativeDir: $0.relativeDir) }
            videoTasks.append(contentsOf: items)
            message = items.isEmpty ? "未发现可压缩的视频文件。" : "已加入 \(items.count) 个视频。"
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { outputDirectory = panel.url }
    }

    private func clearCurrentTasks() {
        if mode == .image { imageTasks.removeAll() } else { videoTasks.removeAll() }
        progress = 0
        message = "已清空。"
    }

    private func start() {
        let baseDirectory = outputDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        if mode == .image {
            guard let targetKB = Int64(targetSizeKB), targetKB > 0 else {
                message = "目标大小请输入正整数（KB）。"
                return
            }
            guard targetKB <= Int64.max / 1_000 else {
                message = "目标大小过大。"
                return
            }
            let config = MediaImageCompressionConfig(
                targetBytes: targetKB * 1_000,
                outputFormat: outputFormat,
                batchDirectory: MediaImageCompressor.makeBatchDirectory(under: baseDirectory)
            )
            runImages(config: config)
        } else {
            let config = MediaVideoCompressionConfig(
                preset: videoPreset,
                batchDirectory: MediaVideoCompressor.makeBatchDirectory(under: baseDirectory)
            )
            runVideos(config: config)
        }
    }

    private func runImages(config: MediaImageCompressionConfig) {
        let inputs = imageTasks
        isRunning = true
        progress = 0
        message = "输出目录：\(config.batchDirectory.path)"
        resetImageResults()
        worker = Task { [imageCompressor] in
            for (index, item) in inputs.enumerated() {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    imageTasks[index].state = .processing
                    message = "正在处理 \(index + 1)/\(inputs.count)：\(item.sourceURL.lastPathComponent)"
                }
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try imageCompressor.compressImage(at: item.sourceURL, relativeDir: item.relativeDir, config: config)
                    }.value
                    guard !Task.isCancelled else { return }
                    await MainActor.run { apply(result, to: index) }
                } catch {
                    await MainActor.run {
                        imageTasks[index].state = .failed(error.localizedDescription)
                    }
                }
                await MainActor.run { progress = Double(index + 1) / Double(inputs.count) }
            }
            await finish(kind: .image)
        }
    }

    private func runVideos(config: MediaVideoCompressionConfig) {
        let inputs = videoTasks
        isRunning = true
        progress = 0
        message = "输出目录：\(config.batchDirectory.path)"
        resetVideoResults()
        worker = Task { [videoCompressor] in
            for (index, item) in inputs.enumerated() {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    videoTasks[index].state = .processing
                    message = "正在处理 \(index + 1)/\(inputs.count)：\(item.sourceURL.lastPathComponent)"
                }
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try await videoCompressor.compressVideo(
                            at: item.sourceURL, relativeDir: item.relativeDir, config: config, progressHandler: { _ in }
                        )
                    }.value
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        videoTasks[index].destinationURL = result.destination
                        videoTasks[index].originalBytes = result.originalBytes
                        videoTasks[index].compressedBytes = result.compressedBytes
                        videoTasks[index].duration = result.duration
                        videoTasks[index].state = result.isCopiedFallback ? .copiedFallback : .success
                    }
                } catch {
                    await MainActor.run { videoTasks[index].state = .failed(error.localizedDescription) }
                }
                await MainActor.run { progress = Double(index + 1) / Double(inputs.count) }
            }
            await finish(kind: .video)
        }
    }

    private enum FinishKind { case image, video }

    private func finish(kind: FinishKind) async {
        await MainActor.run {
            guard !Task.isCancelled else { return }
            isRunning = false
            worker = nil
            let states = kind == .image ? imageTasks.map(\.state) : videoTasks.map(\.state)
            let success = states.filter { $0 == .success }.count
            let fallback = states.filter { $0 == .copiedFallback }.count
            let skipped = states.filter { $0 == .skipped }.count
            let failed = states.filter {
                if case .failed = $0 { return true }
                return false
            }.count
            var parts = ["全部完成"]
            if success > 0 { parts.append("压缩 \(success)") }
            if skipped > 0 { parts.append("直接复制 \(skipped)") }
            if fallback > 0 { parts.append("保留原文件 \(fallback)") }
            if failed > 0 { parts.append("失败 \(failed)") }
            message = parts.joined(separator: "，")
        }
    }

    private func resetImageResults() {
        for index in imageTasks.indices {
            imageTasks[index].destinationURL = nil
            imageTasks[index].originalBytes = nil
            imageTasks[index].compressedBytes = nil
            imageTasks[index].originalSize = nil
            imageTasks[index].compressedSize = nil
            imageTasks[index].usedFormat = nil
            imageTasks[index].state = .pending
        }
    }

    private func resetVideoResults() {
        for index in videoTasks.indices {
            videoTasks[index].destinationURL = nil
            videoTasks[index].originalBytes = nil
            videoTasks[index].compressedBytes = nil
            videoTasks[index].duration = nil
            videoTasks[index].state = .pending
        }
    }

    private func apply(_ result: MediaImageCompressor.Result, to index: Int) {
        imageTasks[index].destinationURL = result.destination
        imageTasks[index].originalBytes = result.originalBytes
        imageTasks[index].compressedBytes = result.compressedBytes
        imageTasks[index].originalSize = result.originalSize
        imageTasks[index].compressedSize = result.compressedSize
        imageTasks[index].usedFormat = result.usedFormat
        imageTasks[index].state = switch result.kind {
        case .compressed: .success
        case .copiedUnderSize: .skipped
        case .copiedFallback: .copiedFallback
        }
    }

    private func requestLeave() {
        guard isRunning else { dismiss(); return }
        showLeaveConfirmation = true
    }

    private func stop() {
        worker?.cancel()
        worker = nil
        isRunning = false
        imageTasks = imageTasks.map { item in
            var item = item
            if case .processing = item.state { item.state = .pending }
            return item
        }
        videoTasks = videoTasks.map { item in
            var item = item
            if case .processing = item.state { item.state = .pending }
            return item
        }
        message = "已停止。"
    }
}

#Preview {
    NavigationStack { MediaCompressionView() }
}
