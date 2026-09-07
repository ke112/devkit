import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IDPhotoView: View {
    @State private var original: NSImage?
    @State private var sourceData: Data?
    @State private var filename = ""
    @State private var photos: [IDPhotoBackground: Data] = [:]
    @State private var previews: [IDPhotoBackground: NSImage] = [:]
    @State private var background: IDPhotoBackground = .red
    @State private var showsOriginal = false
    @State private var isImporterPresented = false
    @State private var isExporterPresented = false
    @State private var isDropTargeted = false
    @State private var isProcessing = false
    @State private var processingTask: Task<Void, Never>?
    @State private var processingID = UUID()
    @State private var errorMessage: String?
    @State private var exportDocument: PNGFileDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("制作证件照").font(.largeTitle.bold())
            if let original {
                HStack(alignment: .top, spacing: 24) {
                    IDPhotoPreview(
                        image: showsOriginal ? original : (previews[background] ?? original),
                        originalSize: original.size,
                        showsTransparency: background == .transparent && !showsOriginal
                            && previews[background] != nil)
                    controls.frame(width: 210)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "person.crop.rectangle.badge.plus").font(
                        .system(size: 42, weight: .light)
                    ).foregroundStyle(.secondary)
                    Text("拖入人像照片").font(.title3.weight(.semibold))
                    Button {
                        isImporterPresented = true
                    } label: {
                        Label("选择照片", systemImage: "folder")
                    }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor)).clipShape(
                        RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if isDropTargeted {
                Rectangle().stroke(Color.accentColor, lineWidth: 3).allowsHitTesting(false)
            }
        }
        .navigationTitle("制作证件照")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            loadImage(at: url)
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): loadImage(at: url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $isExporterPresented, document: exportDocument, contentType: .png,
            defaultFilename:
                "证件照-\(background.title)-\(URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent)"
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .alert(
            "无法制作证件照",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "请重试。")
        }
        .onDisappear { cancelProcessing() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(filename, systemImage: "photo").lineLimit(2).truncationMode(.middle)
            Text("背景颜色").font(.headline)
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(42), spacing: 18), count: 3), alignment: .leading, spacing: 12
            ) {
                ForEach(IDPhotoBackground.allCases, id: \.self) { option in
                    Button {
                        background = option
                        showsOriginal = false
                    } label: {
                        let c = option.components
                        ZStack {
                            if option == .transparent {
                                Circle().fill(Color.white)
                                IDPhotoTransparencyGrid(tileSize: 7)
                                    .allowsHitTesting(false)
                            } else {
                                Color(red: c.red, green: c.green, blue: c.blue)
                            }
                        }
                        .frame(width: 42, height: 42)
                        .clipShape(Circle())
                        .contentShape(Circle())
                        .overlay(Circle().stroke(Color.gray.opacity(0.5), lineWidth: 1).allowsHitTesting(false))
                        .overlay {
                            if option == background {
                                Image(systemName: "checkmark").font(.body.bold()).foregroundStyle(
                                    option == .white || option == .gray || option == .transparent ? .black : .white
                                )
                                .allowsHitTesting(false)
                            }
                        }
                    }.buttonStyle(.plain).help(option.title).accessibilityLabel(option.title)
                        .accessibilityAddTraits(option == background ? .isSelected : [])
                }
            }
            if !photos.isEmpty {
                Picker("预览", selection: $showsOriginal) {
                    Text("原图").tag(true)
                    Text("证件照").tag(false)
                }.pickerStyle(.segmented)
            }
            if isProcessing {
                ProgressView("正在分离人物…").controlSize(.small)
                Button("取消", role: .cancel) { cancelProcessing() }
            } else if photos.isEmpty {
                Button {
                    process()
                } label: {
                    Label("制作证件照", systemImage: "person.crop.rectangle")
                }.buttonStyle(.borderedProminent)
            }
            Button {
                guard let data = photos[background] else { return }
                exportDocument = PNGFileDocument(data: data)
                isExporterPresented = true
            } label: {
                Label("导出 PNG", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
            }.disabled(photos.isEmpty || isProcessing)
            Button {
                isImporterPresented = true
            } label: {
                Label("更换照片", systemImage: "photo.badge.plus").frame(maxWidth: .infinity)
            }
        }
    }

    private func loadImage(at url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let image = NSImage(data: data) else { throw IDPhotoError.invalidImage }
            cancelProcessing()
            sourceData = data
            original = image
            filename = url.lastPathComponent
            background = .red
            showsOriginal = false
            photos = [:]
            previews = [:]
            errorMessage = nil
            process()
        } catch { errorMessage = error.localizedDescription }
    }

    private func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        processingID = UUID()
        isProcessing = false
    }

    private func process() {
        guard let sourceData else { return }
        cancelProcessing()
        let jobID = processingID
        isProcessing = true
        let worker = Task.detached(priority: .userInitiated) {
            try IDPhotoProcessor.makePhotos(from: sourceData)
        }
        processingTask = Task { @MainActor in
            defer {
                if processingID == jobID {
                    processingTask = nil
                    isProcessing = false
                }
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, processingID == jobID else { return }
                photos = result
                previews = result.compactMapValues { NSImage(data: $0) }
                showsOriginal = false
            } catch is CancellationError { return } catch {
                if !Task.isCancelled, processingID == jobID { errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct IDPhotoTransparencyGrid: View {
    var tileSize: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.95)))
            for row in 0..<Int(ceil(size.height / tileSize)) {
                for column in 0..<Int(ceil(size.width / tileSize)) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(column) * tileSize, y: CGFloat(row) * tileSize,
                        width: tileSize, height: tileSize)
                    context.fill(Path(rect), with: .color(Color(white: 0.78)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct IDPhotoPreview: View {
    let image: NSImage
    let originalSize: CGSize
    let showsTransparency: Bool

    var body: some View {
        GeometryReader { geometry in
            let fittedSize = IDPhotoPreviewLayout.fittedSize(
                imageSize: originalSize, containerSize: geometry.size)
            ZStack {
                if showsTransparency {
                    IDPhotoTransparencyGrid(tileSize: 10)
                        .allowsHitTesting(false)
                } else {
                    Color(nsColor: .underPageBackgroundColor)
                }
                Image(nsImage: image)
                    .resizable()
                    .frame(width: fittedSize.width, height: fittedSize.height)
            }
            .frame(width: fittedSize.width, height: fittedSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
    }
}

nonisolated enum IDPhotoPreviewLayout {
    static func fittedSize(imageSize: CGSize, containerSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
            containerSize.width > 0, containerSize.height > 0
        else { return .zero }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
