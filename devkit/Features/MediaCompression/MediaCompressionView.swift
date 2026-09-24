import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct MediaCompressionView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var videoTasks: [MediaVideoTask] = []
    @State private var videoPreset: MediaVideoPreset = .medium
    @State private var outputDirectory: URL? = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/DevKitOutput", isDirectory: true)
    @State private var isRunning = false
    @State private var isScanning = false
    @State private var isDropTargeted = false
    @State private var isImporterPresented = false
    @State private var progress = 0.0
    @State private var message = "拖入视频或文件夹，或点击下方按钮选择。"
    @State private var showFileNotFound = false
    @State private var showLeaveConfirmation = false
    @State private var worker: Task<Void, Never>?
    @State private var scanWorker: Task<Void, Never>?

    private let videoCompressor = MediaVideoCompressor()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("媒体压缩")
                    .font(.largeTitle.bold())
                Text("本地压缩视频质量，输出到 DevKit 文件夹")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
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
                    videoPreset = .medium
                    outputDirectory = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Desktop/DevKitOutput", isDirectory: true)
                    message = "已重置为默认设置。"
                }
                .disabled(isRunning || isScanning)
            }
            .disabled(isRunning || isScanning)

            dropArea

            if !videoTasks.isEmpty {
                HStack(spacing: 16) {
                    Label("已选择 \(videoTasks.count) 个视频", systemImage: "film.stack")
                        .foregroundStyle(.secondary)
                    Text("输出：\(outputDirectory?.lastPathComponent ?? "下载")/DevKit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        clearTasks()
                    } label: {
                        Label("清空列表", systemImage: "trash")
                    }
                    .disabled(isRunning || isScanning)
                }
            }

            actionBar
            progressPanel

            if !videoTasks.isEmpty {
                List(videoTasks) { item in
                    videoRow(item)
                }
                .listStyle(.inset)
                .frame(minHeight: 220)
            }
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
            scanWorker?.cancel()
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
            isPresented: $isImporterPresented,
            allowedContentTypes: [.item, .folder, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): append(urls)
            case .failure(let error): message = error.localizedDescription
            }
        }
    }

    private var dropArea: some View {
        VStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            Text("拖入视频或文件夹")
                .font(.title3.weight(.semibold))
            Text("支持 MP4、MOV、M4V")
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

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                isImporterPresented = true
            } label: {
                Label("选择文件或文件夹", systemImage: "folder")
            }
            .disabled(isRunning || isScanning)

            Button {
                start()
            } label: {
                Label("开始压缩", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(videoTasks.isEmpty || isRunning || isScanning)

            if isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("正在扫描文件...")
                    .foregroundStyle(.secondary)
            }

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

    private func append(_ urls: [URL]) {
        guard !urls.isEmpty, !isRunning, !isScanning else { return }
        isScanning = true
        message = "正在扫描文件..."
        let existingPaths = Set(videoTasks.map { $0.sourceURL.standardizedFileURL.path })
        let collector = Task.detached(priority: .userInitiated) {
            videoCompressor.collectVideos(from: urls)
        }
        scanWorker = Task { @MainActor in
            let collected = await withTaskCancellationHandler {
                await collector.value
            } onCancel: {
                collector.cancel()
            }
            guard !Task.isCancelled else { return }
            let items = collected
                .filter { !existingPaths.contains($0.url.standardizedFileURL.path) }
                .map { MediaVideoTask(sourceURL: $0.url, relativeDir: $0.relativeDir) }
            videoTasks.append(contentsOf: items)
            message = items.isEmpty ? "未发现可压缩的视频文件。" : "已加入 \(items.count) 个视频。"
            isScanning = false
            scanWorker = nil
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { outputDirectory = panel.url }
    }

    private func clearTasks() {
        videoTasks.removeAll()
        progress = 0
        message = "已清空。"
    }

    private func start() {
        let baseDirectory = outputDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let timestamp = fileTimestamp()
        let config = MediaVideoCompressionConfig(
            preset: videoPreset,
            batchDirectory: MediaVideoCompressor.makeBatchDirectory(under: baseDirectory)
                .appendingPathComponent(timestamp, isDirectory: true)
        )
        runVideos(config: config)
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
            await finish()
        }
    }

    private func finish() async {
        await MainActor.run {
            guard !Task.isCancelled else { return }
            isRunning = false
            worker = nil
            let states = videoTasks.map(\.state)
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

    private func fileTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.string(from: Date())
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

    private func requestLeave() {
        guard isRunning else { dismiss(); return }
        showLeaveConfirmation = true
    }

    private func stop() {
        worker?.cancel()
        worker = nil
        isRunning = false
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
