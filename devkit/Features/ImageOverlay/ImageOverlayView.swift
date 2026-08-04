//
//  ImageOverlayView.swift
//  DevKit
//
//  Created by kl on 2026/8/3.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageOverlayView: View {
    @State private var bottomImage: ImportedImage?
    @State private var topImage: ImportedImage?
    @State private var importTarget: ImageLayer = .bottom
    @State private var isImporterPresented = false
    @State private var isPreviewPresented = false
    @State private var isBottomDropTargeted = false
    @State private var isTopDropTargeted = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text("图片叠加")
                    .font(.largeTitle.bold())
                Text("导入底图和上层图片，预览透明叠加效果")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                ImageImportArea(
                    title: "底图",
                    subtitle: "第一张图片",
                    image: bottomImage,
                    isTargeted: $isBottomDropTargeted,
                    onImport: { presentImporter(for: .bottom) },
                    onDrop: { providers in importDroppedImage(from: providers, into: .bottom) }
                )

                Image(systemName: "plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)

                ImageImportArea(
                    title: "上层图片",
                    subtitle: "第二张图片",
                    image: topImage,
                    isTargeted: $isTopDropTargeted,
                    onImport: { presentImporter(for: .top) },
                    onDrop: { providers in importDroppedImage(from: providers, into: .top) }
                )
            }
            .frame(maxHeight: .infinity)

            Button {
                isPreviewPresented = true
            } label: {
                Label("查看叠加效果", systemImage: "square.stack.3d.up")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(bottomImage == nil || topImage == nil)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("图片叠加")
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result, for: importTarget)
        }
        .sheet(isPresented: $isPreviewPresented) {
            if let bottomImage, let topImage {
                CompositePreview(
                    bottomImage: bottomImage,
                    topImage: topImage
                )
                .background {
                    ParentWindowClickDismissal {
                        isPreviewPresented = false
                    }
                }
            }
        }
        .alert(
            "无法导入图片",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "请选择有效的图片文件。")
        }
    }

    private func presentImporter(for layer: ImageLayer) {
        importTarget = layer
        isImporterPresented = true
    }

    private func handleImportResult(
        _ result: Result<[URL], Error>,
        for layer: ImageLayer
    ) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            loadImage(at: url, into: layer)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func importDroppedImage(
        from providers: [NSItemProvider],
        into layer: ImageLayer
    ) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.registeredTypeIdentifiers.contains(where: {
                    UTType($0)?.conforms(to: .image) == true
                })
        }) else {
            return false
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, error in
                if let error {
                    showImportError(error.localizedDescription)
                    return
                }

                let url: URL?
                if let item = item as? URL {
                    url = item
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = nil
                }

                guard let url else {
                    showImportError("拖入的内容不是有效的图片文件。")
                    return
                }

                Task { @MainActor in
                    loadImage(at: url, into: layer)
                }
            }
            return true
        }

        guard let imageType = provider.registeredTypeIdentifiers.first(where: {
            UTType($0)?.conforms(to: .image) == true
        }) else {
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, error in
            if let error {
                showImportError(error.localizedDescription)
                return
            }

            guard let data, let image = NSImage(data: data) else {
                showImportError("拖入的内容无法读取为图片。")
                return
            }

            Task { @MainActor in
                setImage(
                    ImportedImage(name: "拖入的图片", image: image),
                    for: layer
                )
            }
        }
        return true
    }

    private func loadImage(at url: URL, into layer: ImageLayer) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let data = try Data(contentsOf: url)
            guard let image = NSImage(data: data) else {
                errorMessage = "“\(url.lastPathComponent)”不是可读取的图片。"
                return
            }
            setImage(ImportedImage(name: url.lastPathComponent, image: image), for: layer)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setImage(_ image: ImportedImage, for layer: ImageLayer) {
        switch layer {
        case .bottom:
            bottomImage = image
        case .top:
            topImage = image
        }
    }

    private func showImportError(_ message: String) {
        Task { @MainActor in
            errorMessage = message
        }
    }
}

private struct ImageImportArea: View {
    let title: String
    let subtitle: String
    let image: ImportedImage?
    @Binding var isTargeted: Bool
    let onImport: () -> Void
    let onDrop: ([NSItemProvider]) -> Bool

    var body: some View {
        VStack(spacing: 14) {
            if let image {
                Image(nsImage: image.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(title)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text("拖拽图片到这里")
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            }

            VStack(spacing: 8) {
                if let image {
                    Text(image.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Button(action: onImport) {
                    Label(image == nil ? "选择图片" : "更换图片", systemImage: "folder")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: image == nil ? [7] : [])
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if image == nil {
                onImport()
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isTargeted, perform: onDrop)
    }
}

private struct CompositePreview: View {
    let bottomImage: ImportedImage
    let topImage: ImportedImage

    @Environment(\.dismiss) private var dismiss
    @State private var topImageOpacity = 50.0
    @State private var exportDocument: PNGFileDocument?
    @State private var exportFilename = ""
    @State private var isExporterPresented = false
    @State private var exportAlertTitle = ""
    @State private var exportAlertMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("叠加预览")
                        .font(.title2.bold())
                    Text("\(bottomImage.name) + \(topImage.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭")
            }
            .padding(20)

            Divider()

            ZStack {
                Color(nsColor: .windowBackgroundColor)

                Image(nsImage: bottomImage.image)
                    .resizable()
                    .scaledToFit()

                Image(nsImage: topImage.image)
                    .resizable()
                    .scaledToFit()
                    .opacity(topImageOpacity / 100)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

            Divider()

            HStack(spacing: 14) {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text("上层透明度")

                Slider(value: $topImageOpacity, in: 0...100, step: 1)
                    .frame(minWidth: 160, maxWidth: 360)

                Text("\(Int(topImageOpacity))%")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)

                Spacer(minLength: 20)

                Button {
                    prepareExport()
                } label: {
                    Label("导出图片", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(minWidth: 720, minHeight: 560)
        .fileExporter(
            isPresented: $isExporterPresented,
            document: exportDocument,
            contentType: .png,
            defaultFilename: exportFilename
        ) { result in
            handleExportResult(result)
        }
        .alert(
            exportAlertTitle,
            isPresented: Binding(
                get: { exportAlertMessage != nil },
                set: { if !$0 { exportAlertMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportAlertMessage ?? "")
        }
    }

    private func prepareExport() {
        do {
            let data = try CompositeImageRenderer.pngData(
                bottomImage: bottomImage.image,
                topImage: topImage.image,
                topOpacity: topImageOpacity / 100
            )
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"

            let name = (bottomImage.name as NSString).deletingPathExtension
            exportFilename = "\(name)-叠加-\(formatter.string(from: Date()))"
            exportDocument = PNGFileDocument(data: data)
            isExporterPresented = true
        } catch {
            exportAlertTitle = "导出失败"
            exportAlertMessage = error.localizedDescription
        }
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            return
        case .failure(let error):
            if (error as NSError).code == NSUserCancelledError {
                return
            }
            exportAlertTitle = "导出失败"
            exportAlertMessage = error.localizedDescription
        }
    }
}

private struct ParentWindowClickDismissal: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.hostView = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDismiss = onDismiss
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        var onDismiss: () -> Void

        private var eventMonitor: Any?

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func startMonitoring() {
            guard eventMonitor == nil else { return }

            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
                [weak self] event in
                guard let self,
                      let sheetWindow = hostView?.window,
                      event.window === sheetWindow.sheetParent
                else {
                    return event
                }

                onDismiss()
                return nil
            }
        }

        func stopMonitoring() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        }
    }
}

private struct ImportedImage {
    let name: String
    let image: NSImage
}

private enum ImageLayer {
    case bottom
    case top
}

#Preview {
    ImageOverlayView()
}
