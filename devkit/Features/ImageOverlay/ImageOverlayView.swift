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
                    PreviewWindowConfigurator()
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

private enum PreviewWindowMetrics {
    static let minimumSize = CGSize(width: 720, height: 560)
    static let initialSize = CGSize(width: 840, height: 1100)
}

private enum PreviewGestureTarget {
    case topImage
    case viewport
}

enum PreviewViewportBoundary {
    static func clampedCanvasCenterOffset(
        _ offset: CGSize,
        canvasSize: CGSize
    ) -> CGSize {
        let maximumOffset = CGSize(
            width: max(0, canvasSize.width / 2),
            height: max(0, canvasSize.height / 2)
        )
        return CGSize(
            width: min(max(offset.width, -maximumOffset.width), maximumOffset.width),
            height: min(max(offset.height, -maximumOffset.height), maximumOffset.height)
        )
    }
}

private struct CompositePreview: View {
    private static let minimumTopScale: CGFloat = 0.1
    private static let maximumTopScale: CGFloat = 5
    private static let topScaleStep: CGFloat = 0.1
    private static let minimumViewZoom: CGFloat = 1
    private static let maximumViewZoom: CGFloat = 5
    private static let viewZoomStep: CGFloat = 0.5

    let bottomImage: ImportedImage
    let topImage: ImportedImage

    private let bottomPixelSize: ImagePixelSize
    private let topPixelSize: ImagePixelSize
    private let detectedBottomBackingScale: ImageBackingScale
    private let detectedTopBackingScale: ImageBackingScale

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isCanvasFocused: Bool
    @State private var topImageOpacity = 50.0
    @State private var topTransform = TopImageTransform()
    @State private var bottomBackingScale: ImageBackingScale
    @State private var topBackingScale: ImageBackingScale
    @State private var previewSize = CGSize.zero
    @State private var fittedViewScale: CGFloat = 1
    @State private var viewZoom: CGFloat = 1
    @State private var viewOffset = CGSize.zero
    @State private var magnificationStartTopTransform = TopImageTransform()
    @State private var magnificationStartViewZoom: CGFloat = 1
    @State private var magnificationStartViewOffset = CGSize.zero
    @State private var magnificationTarget: PreviewGestureTarget?
    @State private var dragStartTopOffset = CGSize.zero
    @State private var dragStartViewOffset = CGSize.zero
    @State private var dragTarget: PreviewGestureTarget?
    @State private var isSpacePressed = false
    @State private var exportDocument: PNGFileDocument?
    @State private var exportFilename = ""
    @State private var isExporterPresented = false
    @State private var exportAlertTitle = ""
    @State private var exportAlertMessage: String?

    init(bottomImage: ImportedImage, topImage: ImportedImage) {
        self.bottomImage = bottomImage
        self.topImage = topImage
        bottomPixelSize = (try? CompositeImageRenderer.pixelSize(for: bottomImage.image))
            ?? ImagePixelSize(
                width: max(1, Int(bottomImage.image.size.width)),
                height: max(1, Int(bottomImage.image.size.height))
            )
        topPixelSize = (try? CompositeImageRenderer.pixelSize(for: topImage.image))
            ?? ImagePixelSize(
                width: max(1, Int(topImage.image.size.width)),
                height: max(1, Int(topImage.image.size.height))
            )
        let detectedBottomBackingScale = CompositeImageRenderer.suggestedBackingScale(
            for: bottomImage.image,
            named: bottomImage.name
        )
        let detectedTopBackingScale = CompositeImageRenderer.suggestedBackingScale(
            for: topImage.image,
            named: topImage.name
        )
        self.detectedBottomBackingScale = detectedBottomBackingScale
        self.detectedTopBackingScale = detectedTopBackingScale
        _bottomBackingScale = State(initialValue: detectedBottomBackingScale)
        _topBackingScale = State(initialValue: detectedTopBackingScale)
    }

    private var compositeLayout: CompositeImageLayout {
        CompositeImageRenderer.layout(
            bottomSize: bottomPixelSize,
            bottomBackingScale: bottomBackingScale.value,
            topSize: topPixelSize,
            topBackingScale: topBackingScale.value,
            transform: topTransform
        )
    }

    private var displayScale: CGFloat {
        fittedViewScale * viewZoom
    }

    private var outputValidationMessage: String? {
        CompositeImageOutputLimits.validationMessage(for: compositeLayout.pixelSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("叠加预览")
                        .font(.title2.bold())
                    Text("\(bottomImage.name) + \(topImage.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                backingScaleMenu

                topTransformControls

                Divider()
                    .frame(height: 20)

                viewTransformControls

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background {
                            Circle()
                                .fill(Color.primary.opacity(0.08))
                        }
                        .overlay {
                            Circle()
                                .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .help("关闭")
                .accessibilityLabel("关闭")
            }
            .padding(20)
            .background {
                WindowGroupDragArea()
                    .accessibilityHidden(true)
            }

            Divider()

            GeometryReader { geometry in
                previewCanvas(in: geometry.size)
            }
            .padding(24)

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    opacityControls
                    Spacer(minLength: 16)
                    exportControls
                }

                VStack(spacing: 12) {
                    HStack(spacing: 14) {
                        opacityControls
                    }
                    HStack(spacing: 14) {
                        Spacer()
                        exportControls
                    }
                }
            }
            .padding(20)
        }
        .frame(
            minWidth: PreviewWindowMetrics.minimumSize.width,
            idealWidth: PreviewWindowMetrics.initialSize.width,
            maxWidth: .infinity,
            minHeight: PreviewWindowMetrics.minimumSize.height,
            idealHeight: PreviewWindowMetrics.initialSize.height,
            maxHeight: .infinity
        )
        .onChange(of: bottomBackingScale) { _, _ in
            fitOutput(in: previewSize)
        }
        .onChange(of: topBackingScale) { _, _ in
            fitOutput(in: previewSize)
        }
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

    private var backingScaleMenu: some View {
        Menu {
            Section("底图") {
                backingScaleButtons(
                    selection: $bottomBackingScale,
                    detectedScale: detectedBottomBackingScale
                )
            }
            Section("上层图片") {
                backingScaleButtons(
                    selection: $topBackingScale,
                    detectedScale: detectedTopBackingScale
                )
            }
        } label: {
            Image(systemName: "ruler")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("屏幕倍率：底图 \(bottomBackingScale.label)，上层 \(topBackingScale.label)")
        .accessibilityLabel("屏幕倍率")
    }

    @ViewBuilder
    private func backingScaleButtons(
        selection: Binding<ImageBackingScale>,
        detectedScale: ImageBackingScale
    ) -> some View {
        ForEach(ImageBackingScale.allCases) { scale in
            let title = scale == detectedScale ? "\(scale.label)  (Auto)" : scale.label
            Button {
                selection.wrappedValue = scale
            } label: {
                if selection.wrappedValue == scale {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
        }
    }

    @ViewBuilder
    private var topTransformControls: some View {
        HStack(spacing: 6) {
            Text("叠图")
                .foregroundStyle(.secondary)

            Button {
                changeTopScale(by: -Self.topScaleStep)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(topTransform.scale <= Self.minimumTopScale)
            .help("缩小上层图片")

            Text("\(Int((topTransform.scale * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)

            Button {
                changeTopScale(by: Self.topScaleStep)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(topTransform.scale >= Self.maximumTopScale)
            .help("放大上层图片")

            Button {
                resetTopTransform()
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("重置上层图片")
        }
    }

    @ViewBuilder
    private var viewTransformControls: some View {
        HStack(spacing: 6) {
            Text("画布")
                .foregroundStyle(.secondary)

            Button {
                changeViewZoom(by: -Self.viewZoomStep)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(viewZoom <= Self.minimumViewZoom)
            .help("缩小画布")

            Text(viewZoom, format: .number.precision(.fractionLength(1)))
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)
            Text("x")
                .foregroundStyle(.secondary)

            Button {
                changeViewZoom(by: Self.viewZoomStep)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .disabled(viewZoom >= Self.maximumViewZoom)
            .help("放大画布")

            Button {
                fitOutput(in: previewSize)
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("重置画布")
        }
    }

    @ViewBuilder
    private var opacityControls: some View {
        Image(systemName: "circle.lefthalf.filled")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

        Text("上层透明度")

        Slider(value: $topImageOpacity, in: 0...100, step: 1)
            .frame(minWidth: 140, maxWidth: 320)

        Text("\(Int(topImageOpacity))%")
            .monospacedDigit()
            .frame(width: 42, alignment: .trailing)
    }

    @ViewBuilder
    private var exportControls: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(
                "画布 \(pointDimension(compositeLayout.logicalBounds.width)) × "
                    + "\(pointDimension(compositeLayout.logicalBounds.height)) pt"
            )
                .font(.caption)
                .monospacedDigit()
            Text("导出 \(compositeLayout.pixelSize.width) × \(compositeLayout.pixelSize.height) px")
                .font(.caption)
                .monospacedDigit()
            if let outputValidationMessage {
                Text(outputValidationMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }

        Button {
            prepareExport()
        } label: {
            Label("导出图片", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .disabled(outputValidationMessage != nil)
    }

    private func previewCanvas(in size: CGSize) -> some View {
        let bottomCenter = CGPoint(
            x: size.width / 2 + viewOffset.width,
            y: size.height / 2 + viewOffset.height
        )
        let outputCenterOffset = compositeLayout.outputCenterFromBottomCenter
        let outputCenter = CGPoint(
            x: bottomCenter.x + outputCenterOffset.width * displayScale,
            y: bottomCenter.y + outputCenterOffset.height * displayScale
        )
        let topCenterOffset = compositeLayout.topCenterFromBottomCenter
        let topCenter = CGPoint(
            x: bottomCenter.x + topCenterOffset.width * displayScale,
            y: bottomCenter.y + topCenterOffset.height * displayScale
        )

        return ZStack {
            Color(nsColor: .windowBackgroundColor)

            Rectangle()
                .fill(.clear)
                .overlay {
                    Rectangle()
                        .stroke(Color.primary.opacity(0.35), lineWidth: 1)
                }
                .frame(
                    width: compositeLayout.logicalBounds.width * displayScale,
                    height: compositeLayout.logicalBounds.height * displayScale
                )
                .position(outputCenter)

            Image(nsImage: bottomImage.image)
                .resizable()
                .frame(
                    width: compositeLayout.bottomRect.width * displayScale,
                    height: compositeLayout.bottomRect.height * displayScale
                )
                .position(bottomCenter)
                .accessibilityLabel("底图")

            Image(nsImage: topImage.image)
                .resizable()
                .frame(
                    width: compositeLayout.topRect.width * displayScale,
                    height: compositeLayout.topRect.height * displayScale
                )
                .position(topCenter)
                .opacity(topImageOpacity / 100)
                .accessibilityLabel("上层图片")
        }
        .contentShape(Rectangle())
        .clipped()
        .focusable()
        .focusEffectDisabled()
        .focused($isCanvasFocused)
        .onTapGesture {
            isCanvasFocused = true
        }
        .onKeyPress(phases: [.down, .repeat, .up]) { keyPress in
            handleKeyPress(keyPress)
        }
        .simultaneousGesture(doubleClickGesture(in: size))
        .simultaneousGesture(magnificationGesture(in: size))
        .simultaneousGesture(dragGesture(in: size))
        .onAppear {
            updatePreviewSize(size)
            isCanvasFocused = true
        }
        .onChange(of: size) { _, newSize in
            updatePreviewSize(newSize)
        }
        .onChange(of: isCanvasFocused) { _, isFocused in
            if !isFocused {
                isSpacePressed = false
            }
        }
    }

    private func doubleClickGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                if gestureTarget(at: value.location, in: size) == .topImage {
                    resetTopTransform()
                } else {
                    fitOutput(in: size)
                }
            }
    }

    private func magnificationGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let anchor = CGPoint(
                    x: size.width * value.startAnchor.x,
                    y: size.height * value.startAnchor.y
                )
                if magnificationTarget == nil {
                    magnificationTarget = gestureTarget(at: anchor, in: size)
                    magnificationStartTopTransform = topTransform
                    magnificationStartViewZoom = viewZoom
                    magnificationStartViewOffset = viewOffset
                }

                if magnificationTarget == .topImage {
                    magnifyTopImage(by: value.magnification, around: anchor, in: size)
                } else {
                    magnifyView(by: value.magnification, around: anchor, in: size)
                }
            }
            .onEnded { _ in
                magnificationTarget = nil
            }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragTarget == nil {
                    dragTarget = isSpacePressed
                        ? .viewport
                        : gestureTarget(at: value.startLocation, in: size)
                    dragStartTopOffset = topTransform.offset
                    dragStartViewOffset = viewOffset
                }

                if dragTarget == .topImage {
                    topTransform.offset = CGSize(
                        width: dragStartTopOffset.width + value.translation.width / displayScale,
                        height: dragStartTopOffset.height + value.translation.height / displayScale
                    )
                } else {
                    let proposedOffset = CGSize(
                        width: dragStartViewOffset.width + value.translation.width,
                        height: dragStartViewOffset.height + value.translation.height
                    )
                    viewOffset = clampedViewOffset(proposedOffset, at: viewZoom, in: size)
                }
            }
            .onEnded { _ in
                dragTarget = nil
            }
    }

    private func gestureTarget(at location: CGPoint, in size: CGSize) -> PreviewGestureTarget {
        topImageFrame(in: size).contains(location) ? .topImage : .viewport
    }

    private func topImageFrame(in size: CGSize) -> CGRect {
        let bottomCenter = CGPoint(
            x: size.width / 2 + viewOffset.width,
            y: size.height / 2 + viewOffset.height
        )
        let layout = compositeLayout
        let topSize = CGSize(
            width: layout.topRect.width * displayScale,
            height: layout.topRect.height * displayScale
        )
        let topCenterOffset = layout.topCenterFromBottomCenter
        return CGRect(
            x: bottomCenter.x + topCenterOffset.width * displayScale - topSize.width / 2,
            y: bottomCenter.y + topCenterOffset.height * displayScale - topSize.height / 2,
            width: topSize.width,
            height: topSize.height
        )
    }

    private func magnifyTopImage(
        by magnification: CGFloat,
        around anchor: CGPoint,
        in size: CGSize
    ) {
        let startTransform = magnificationStartTopTransform
        let targetScale = clampedTopScale(startTransform.scale * magnification)
        let scaleRatio = targetScale / startTransform.scale
        let bottomCenter = CGPoint(
            x: size.width / 2 + viewOffset.width,
            y: size.height / 2 + viewOffset.height
        )
        let startTopCenter = CGPoint(
            x: bottomCenter.x + startTransform.offset.width * displayScale,
            y: bottomCenter.y + startTransform.offset.height * displayScale
        )
        let targetTopCenter = CGPoint(
            x: anchor.x + (startTopCenter.x - anchor.x) * scaleRatio,
            y: anchor.y + (startTopCenter.y - anchor.y) * scaleRatio
        )

        topTransform = TopImageTransform(
            scale: targetScale,
            offset: CGSize(
                width: (targetTopCenter.x - bottomCenter.x) / displayScale,
                height: (targetTopCenter.y - bottomCenter.y) / displayScale
            )
        )
    }

    private func magnifyView(
        by magnification: CGFloat,
        around anchor: CGPoint,
        in size: CGSize
    ) {
        let targetZoom = clampedViewZoom(magnificationStartViewZoom * magnification)
        let scaleRatio = targetZoom / magnificationStartViewZoom
        let anchorFromCenter = CGSize(
            width: anchor.x - size.width / 2,
            height: anchor.y - size.height / 2
        )
        viewZoom = targetZoom
        let proposedOffset = CGSize(
            width: scaleRatio * magnificationStartViewOffset.width
                + (1 - scaleRatio) * anchorFromCenter.width,
            height: scaleRatio * magnificationStartViewOffset.height
                + (1 - scaleRatio) * anchorFromCenter.height
        )
        viewOffset = clampedViewOffset(proposedOffset, at: targetZoom, in: size)
    }

    private func changeTopScale(by delta: CGFloat) {
        withAnimation(.easeInOut(duration: 0.2)) {
            topTransform.scale = clampedTopScale(topTransform.scale + delta)
        }
    }

    private func changeViewZoom(by delta: CGFloat) {
        let targetZoom = clampedViewZoom(viewZoom + delta)
        withAnimation(.easeInOut(duration: 0.2)) {
            viewZoom = targetZoom
            viewOffset = clampedViewOffset(viewOffset, at: targetZoom, in: previewSize)
        }
    }

    private func resetTopTransform() {
        withAnimation(.easeInOut(duration: 0.2)) {
            topTransform = TopImageTransform()
        }
    }

    private func updatePreviewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != previewSize else { return }
        previewSize = size
        fitOutput(in: size)
    }

    private func fitOutput(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }

        let layout = compositeLayout
        fittedViewScale = min(
            size.width / layout.logicalBounds.width,
            size.height / layout.logicalBounds.height
        ) * 0.96
        viewZoom = Self.minimumViewZoom
        viewOffset = CGSize(
            width: -layout.outputCenterFromBottomCenter.width * fittedViewScale,
            height: -layout.outputCenterFromBottomCenter.height * fittedViewScale
        )
    }

    private func clampedViewOffset(
        _ offset: CGSize,
        at zoom: CGFloat,
        in size: CGSize
    ) -> CGSize {
        guard size.width > 0, size.height > 0 else { return offset }

        let layout = compositeLayout
        let scale = fittedViewScale * zoom
        let outputCenter = layout.outputCenterFromBottomCenter
        let canvasCenterOffset = CGSize(
            width: offset.width + outputCenter.width * scale,
            height: offset.height + outputCenter.height * scale
        )
        let clampedCanvasCenterOffset = PreviewViewportBoundary.clampedCanvasCenterOffset(
            canvasCenterOffset,
            canvasSize: CGSize(
                width: layout.logicalBounds.width * scale,
                height: layout.logicalBounds.height * scale
            )
        )
        return CGSize(
            width: clampedCanvasCenterOffset.width - outputCenter.width * scale,
            height: clampedCanvasCenterOffset.height - outputCenter.height * scale
        )
    }

    private func clampedTopScale(_ scale: CGFloat) -> CGFloat {
        min(max(scale, Self.minimumTopScale), Self.maximumTopScale)
    }

    private func clampedViewZoom(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, Self.minimumViewZoom), Self.maximumViewZoom)
    }

    private func pointDimension(_ value: CGFloat) -> String {
        Double(value).formatted(
            .number.precision(.fractionLength(value == value.rounded() ? 0 : 1))
        )
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        if keyPress.key == .space {
            isSpacePressed = keyPress.phase != .up
            return .handled
        }

        guard keyPress.phase != .up else { return .ignored }

        let distance: CGFloat = keyPress.modifiers.contains(.shift) ? 10 : 1
        let movement: CGSize
        switch keyPress.key {
        case .leftArrow:
            movement = CGSize(width: -distance, height: 0)
        case .rightArrow:
            movement = CGSize(width: distance, height: 0)
        case .upArrow:
            movement = CGSize(width: 0, height: -distance)
        case .downArrow:
            movement = CGSize(width: 0, height: distance)
        default:
            return .ignored
        }

        topTransform.offset = CGSize(
            width: topTransform.offset.width + movement.width,
            height: topTransform.offset.height + movement.height
        )
        return .handled
    }

    private func prepareExport() {
        do {
            let data = try CompositeImageRenderer.pngData(
                bottomImage: bottomImage.image,
                topImage: topImage.image,
                topOpacity: topImageOpacity / 100,
                bottomBackingScale: bottomBackingScale.value,
                topBackingScale: topBackingScale.value,
                transform: topTransform
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

private struct PreviewWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ResizableSheetHostView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ResizableSheetHostView: NSView {
    private var hasConfiguredWindow = false

    override func layout() {
        super.layout()
        guard !hasConfiguredWindow, let window else { return }

        hasConfiguredWindow = true
        window.setContentSize(PreviewWindowMetrics.initialSize)
        window.styleMask.insert(.resizable)
        window.contentMinSize = PreviewWindowMetrics.minimumSize
    }
}

private struct WindowGroupDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowGroupDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
private final class WindowGroupDragView: NSView {
    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1, let window else { return }

        var rootWindow = window
        while let parentWindow = rootWindow.sheetParent {
            rootWindow = parentWindow
        }

        // performDrag expects the initiating event in the window being moved.
        let location = rootWindow.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard let dragEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: rootWindow.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        ) else {
            return
        }

        rootWindow.performDrag(with: dragEvent)
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
