import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WatermarkRemovalView: View {
    @State private var importedImage: WatermarkImportedImage?
    @State private var processedImage: NSImage?
    @State private var showsOriginal = false
    @State private var isImporterPresented = false
    @State private var isDropTargeted = false
    @State private var isProcessing = false
    @State private var detectedRegionCount = 0
    @State private var processingTask: Task<Void, Never>?
    @State private var processingID = UUID()
    @State private var errorMessage: String?
    @State private var exportDocument: PNGFileDocument?
    @State private var isExporterPresented = false
    @State private var exportFilename = "去水印"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if let importedImage {
                editor(for: importedImage)
            } else {
                importArea
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("去除图片水印")
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                loadImage(at: url)
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: exportDocument,
            contentType: .png,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                errorMessage = error.localizedDescription
            }
        }
        .alert(
            "无法处理图片",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "请重试。")
        }
        .onDisappear {
            processingTask?.cancel()
            processingTask = nil
            isProcessing = false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("去除图片水印")
                .font(.largeTitle.bold())
        }
    }

    private var importArea: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            Text("拖入图片到这里")
                .font(.title3.weight(.semibold))
            Text("支持 PNG、JPG、JPEG、HEIC、WebP 和 TIFF")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                isImporterPresented = true
            } label: {
                Label("选择图片", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [8])
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            loadImage(at: url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private func editor(for importedImage: WatermarkImportedImage) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                Image(nsImage: showsOriginal ? importedImage.image : (processedImage ?? importedImage.image))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(minWidth: 480, minHeight: 360)
                .background(Color(nsColor: .underPageBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 12) {
                    Label(importedImage.name, systemImage: "photo")
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if processedImage != nil {
                        Picker("预览", selection: $showsOriginal) {
                            Text("原图").tag(true)
                            Text("修复结果").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }

                    Spacer(minLength: 0)

                    Button {
                        autoProcess()
                    } label: {
                        Label(isProcessing ? "正在自动修复" : "自动修复水印", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isProcessing || processedImage != nil)

                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                        Button("取消", role: .cancel) {
                            processingTask?.cancel()
                        }
                    }

                    if detectedRegionCount > 0 {
                        Text("已修复 \(detectedRegionCount) 个重复水印区域")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        processedImage = nil
                        showsOriginal = false
                        detectedRegionCount = 0
                    } label: {
                        Label("还原原图", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(isProcessing || processedImage == nil)

                    Button {
                        guard let processedImage,
                              let data = try? WatermarkRemovalProcessor.pngData(for: processedImage) else {
                            errorMessage = WatermarkRemovalError.cannotEncodePNG.localizedDescription
                            return
                        }
                        exportDocument = PNGFileDocument(data: data)
                        exportFilename = "去水印-\(URL(fileURLWithPath: importedImage.name).deletingPathExtension().lastPathComponent)"
                        isExporterPresented = true
                    } label: {
                        Label("导出 PNG", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(processedImage == nil || isProcessing)

                    Button {
                        self.importedImage = nil
                        processingTask?.cancel()
                        processedImage = nil
                        showsOriginal = false
                        detectedRegionCount = 0
                    } label: {
                        Label("更换图片", systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(isProcessing)
                }
                .frame(width: 210)
            }

        }
    }

    private func loadImage(at url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let image = NSImage(data: data), image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil else {
                errorMessage = "“\(url.lastPathComponent)”不是可读取的图片。"
                return
            }
            importedImage = WatermarkImportedImage(name: url.lastPathComponent, image: image, data: data)
            processingTask?.cancel()
            processingTask = nil
            processingID = UUID()
            isProcessing = false
            processedImage = nil
            showsOriginal = false
            detectedRegionCount = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func autoProcess() {
        guard let importedImage else { return }
        processingTask?.cancel()
        let jobID = UUID()
        processingID = jobID
        isProcessing = true
        let sourceData = importedImage.data
        let worker = Task.detached(priority: .userInitiated) {
            guard let image = NSImage(data: sourceData) else {
                throw WatermarkRemovalError.invalidImage
            }
            let result = try WatermarkRemovalProcessor.removeDetectedWatermarks(from: image)
            return (try WatermarkRemovalProcessor.pngData(for: result.image), result.detectedRegionCount)
        }
        processingTask = Task { @MainActor in
            defer {
                if processingID == jobID {
                    processingTask = nil
                    isProcessing = false
                }
            }
            do {
                let (data, regionCount) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, processingID == jobID else { return }
                guard let image = NSImage(data: data) else { throw WatermarkRemovalError.invalidImage }
                processedImage = image
                showsOriginal = false
                detectedRegionCount = regionCount
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, processingID == jobID else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct WatermarkImportedImage {
    let name: String
    let image: NSImage
    let data: Data
}
