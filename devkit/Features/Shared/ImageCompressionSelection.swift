import Foundation

protocol SelectableImageCompressionTaskItem: ImageCompressionTaskItem {
    var status: ImageCompressionTaskStatus { get set }
    var resultByteCount: Int64? { get set }
    var resultPercentage: Double? { get set }
    var elapsedSeconds: Double? { get set }
    var destinationPath: String? { get set }
    var compressionOverride: Bool? { get set }
    var manualSkipOrder: Int? { get set }
    var resultReplacedOriginal: Bool { get set }
}

extension SelectableImageCompressionTaskItem {
    mutating func clearResultMetrics() {
        resultByteCount = nil
        resultPercentage = nil
        elapsedSeconds = nil
    }
}

@MainActor
protocol ImageCompressionSelectionModel: AnyObject {
    associatedtype ImageItem: SelectableImageCompressionTaskItem
    var imageItems: [ImageItem] { get set }
    var selectedURLs: [URL] { get }
    var minimumCompressionSizeKB: Int { get }
    var isRunning: Bool { get }
    var isScanning: Bool { get }
    var isRestoring: Bool { get set }
    var nextManualSkipOrder: Int { get set }
    var operationStatus: String { get set }
    var operationStatusSystemImage: String { get set }
    var alertMessage: String? { get set }
    var operationVerb: String { get }
    func supportsProcessing(_ item: ImageItem) -> Bool
}

extension ImageCompressionSelectionModel {
    var operationVerb: String { "压缩" }

    func supportsProcessing(_ item: ImageItem) -> Bool { true }

    func isCompressionEnabled(for item: ImageItem) -> Bool {
        guard supportsProcessing(item) else { return false }
        if item.status == .success { return true }
        return item.compressionOverride ?? (item.byteCount >= Int64(minimumCompressionSizeKB) * 1024)
    }

    var displayGroups: [ImageTaskDisplayGroup] {
        let included = imageItems.filter { $0.status != .skipped }
        let skipped = imageItems.filter { $0.status == .skipped }.sorted {
            ($0.manualSkipOrder ?? Int.max) < ($1.manualSkipOrder ?? Int.max)
        }
        let hasPending = included.contains { $0.status != .success }
        let hasResults = included.contains { $0.status == .success }
        let mixedTitle = "待\(operationVerb) / 已\(operationVerb)"
        let title = hasPending ? (hasResults ? mixedTitle : "待\(operationVerb)") : "已\(operationVerb)"
        return [
            ImageTaskDisplayGroup(id: "included", title: included.isEmpty ? mixedTitle : title,
                                  tasks: included.map(displayModel)),
            ImageTaskDisplayGroup(id: "skipped", title: "已跳过\(operationVerb)", tasks: skipped.map(displayModel))
        ]
    }

    private func displayModel(for item: ImageItem) -> ImageTaskDisplayModel {
        var display = ImageTaskDisplayModel(item: item, resultLabel: "\(operationVerb)后", verb: operationVerb)
        display.compressionEnabled = isCompressionEnabled(for: item)
        display.compressionToggleAllowed = supportsProcessing(item)
        display.canReset = item.status == .success && item.destinationPath != nil
        display.operationVerb = operationVerb
        return display
    }

    func setCompressionEnabled(_ enabled: Bool, for id: URL) async {
        guard !isRunning, !isScanning, !isRestoring,
              let index = imageItems.firstIndex(where: { $0.id == id }),
              supportsProcessing(imageItems[index]) else { return }
        if !enabled, imageItems[index].status == .success {
            await resetResult(for: id)
            return
        }
        imageItems[index].compressionOverride = enabled
        imageItems[index].status = enabled ? .waiting : .skipped
        imageItems[index].clearResultMetrics()
        if enabled {
            imageItems[index].manualSkipOrder = nil
        } else {
            imageItems[index].manualSkipOrder = nextManualSkipOrder
            nextManualSkipOrder += 1
        }
        operationStatus = "已选择，等待开始"
        operationStatusSystemImage = "checkmark.circle"
    }

    func resetResult(for id: URL) async {
        guard !isRunning, !isScanning, !isRestoring,
              let index = imageItems.firstIndex(where: { $0.id == id }),
              imageItems[index].status == .success,
              let destination = imageItems[index].destinationPath else { return }
        let item = imageItems[index]
        isRestoring = true
        defer { isRestoring = false }
        do {
            let restored = try await ImageCompressionOriginals.restore(
                originalURL: item.previewOriginalURL ?? item.id,
                sourceURL: item.id,
                destinationURL: URL(fileURLWithPath: destination),
                replacesOriginal: item.resultReplacedOriginal,
                securityScopedRoots: selectedURLs
            )
            imageItems[index].status = .skipped
            imageItems[index].compressionOverride = false
            imageItems[index].manualSkipOrder = nextManualSkipOrder
            nextManualSkipOrder += 1
            imageItems[index].clearResultMetrics()
            imageItems[index].destinationPath = restored.path
            imageItems[index].resultReplacedOriginal = false
            operationStatus = "已恢复原图并跳过\(operationVerb)"
            operationStatusSystemImage = "checkmark.circle"
        } catch {
            alertMessage = "Reset 失败：\(error.localizedDescription)"
        }
    }
}
