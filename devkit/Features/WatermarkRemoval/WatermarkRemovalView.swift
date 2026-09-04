import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WatermarkRemovalView: View {
    @State private var importedImage: WatermarkImportedImage?
    @State private var processedImage: NSImage?
    @State private var selection = CGRect.zero
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
            Text("自动识别全图重复数字指纹水印，也可手动框选修复")
                .font(.title3)
                .foregroundStyle(.secondary)
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
                WatermarkImageCanvas(
                    image: processedImage ?? importedImage.image,
                    selection: $selection,
                    isDisabled: isProcessing || processedImage != nil
                )
                .frame(minWidth: 480, minHeight: 360)
                .background(Color(nsColor: .underPageBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 12) {
                    Label(importedImage.name, systemImage: "photo")
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(processedImage == nil ? "在左侧图片上拖出水印区域" : "修复结果已生成，可导出 PNG")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Button {
                        process()
                    } label: {
                        Label(isProcessing ? "正在修复" : "去除水印", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(selection.isEmpty || isProcessing || processedImage != nil)

                    Button {
                        autoProcess()
                    } label: {
                        Label(isProcessing ? "正在自动修复" : "自动修复整图", systemImage: "sparkles")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing || processedImage != nil)

                    if detectedRegionCount > 0 {
                        Text("已修复 \(detectedRegionCount) 个重复水印区域")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        selection = .zero
                        processedImage = nil
                        detectedRegionCount = 0
                    } label: {
                        Label("重新选择区域", systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(isProcessing || (selection.isEmpty && processedImage == nil))

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
                        selection = .zero
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
            selection = .zero
            detectedRegionCount = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func process() {
        guard let importedImage, !selection.isEmpty else {
            errorMessage = WatermarkRemovalError.invalidSelection.localizedDescription
            return
        }
        let pixelWidth = importedImage.image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width ?? 0
        let pixelHeight = importedImage.image.cgImage(forProposedRect: nil, context: nil, hints: nil)?.height ?? 0
        guard pixelWidth > 0, pixelHeight > 0 else {
            errorMessage = WatermarkRemovalError.invalidImage.localizedDescription
            return
        }

        processingTask?.cancel()
        let jobID = UUID()
        processingID = jobID
        isProcessing = true
        let pixelSelection = CGRect(
            x: selection.minX * CGFloat(pixelWidth),
            y: selection.minY * CGFloat(pixelHeight),
            width: selection.width * CGFloat(pixelWidth),
            height: selection.height * CGFloat(pixelHeight)
        )
        let sourceData = importedImage.data
        let worker = Task.detached(priority: .userInitiated) {
            guard let image = NSImage(data: sourceData) else {
                throw WatermarkRemovalError.invalidImage
            }
            let result = try WatermarkRemovalProcessor.removeWatermark(
                from: image,
                selection: pixelSelection
            )
            return try WatermarkRemovalProcessor.pngData(for: result)
        }
        processingTask = Task { @MainActor in
            defer {
                if processingID == jobID { processingTask = nil }
            }
            do {
                let data = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, processingID == jobID,
                      let image = NSImage(data: data) else { return }
                processedImage = image
            } catch is CancellationError {
                if processingID == jobID { isProcessing = false }
                return
            } catch {
                guard !Task.isCancelled, processingID == jobID else { return }
                errorMessage = error.localizedDescription
            }
            guard processingID == jobID else { return }
            isProcessing = false
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
                if processingID == jobID { processingTask = nil }
            }
            do {
                let (data, regionCount) = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, processingID == jobID,
                      let image = NSImage(data: data) else { return }
                processedImage = image
                detectedRegionCount = regionCount
            } catch is CancellationError {
                if processingID == jobID { isProcessing = false }
                return
            } catch {
                guard !Task.isCancelled, processingID == jobID else { return }
                errorMessage = error.localizedDescription
            }
            guard processingID == jobID else { return }
            isProcessing = false
        }
    }
}

private struct WatermarkImportedImage {
    let name: String
    let image: NSImage
    let data: Data
}

private struct WatermarkImageCanvas: View {
    let image: NSImage
    @Binding var selection: CGRect
    let isDisabled: Bool
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let imageRect = aspectFitRect(imageSize: image.size, in: proxy.size)
            ZStack {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)

                if !selection.isEmpty {
                    let rect = displayRect(selection, in: imageRect)
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: rect.width, height: rect.height)
                        .overlay { Rectangle().stroke(Color.accentColor, lineWidth: 2) }
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard !isDisabled, imageRect.width > 0, imageRect.height > 0 else { return }
                        let start = dragStart ?? clamp(value.startLocation, to: imageRect)
                        dragStart = start
                        let current = clamp(value.location, to: imageRect)
                        selection = normalizedRect(from: start, to: current, in: imageRect)
                    }
                    .onEnded { _ in dragStart = nil }
            )
        }
        .overlay {
            if selection.isEmpty && !isDisabled {
                Text("拖出水印区域")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
        }
    }

    private func aspectFitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, rect.minX), rect.maxX), y: min(max(point.y, rect.minY), rect.maxY))
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint, in imageRect: CGRect) -> CGRect {
        let rect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
        return CGRect(
            x: (rect.minX - imageRect.minX) / imageRect.width,
            y: (rect.minY - imageRect.minY) / imageRect.height,
            width: rect.width / imageRect.width,
            height: rect.height / imageRect.height
        )
    }

    private func displayRect(_ normalized: CGRect, in imageRect: CGRect) -> CGRect {
        CGRect(
            x: imageRect.minX + normalized.minX * imageRect.width,
            y: imageRect.minY + normalized.minY * imageRect.height,
            width: normalized.width * imageRect.width,
            height: normalized.height * imageRect.height
        )
    }
}
