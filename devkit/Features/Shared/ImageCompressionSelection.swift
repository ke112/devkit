import Foundation
import Observation

@MainActor
@Observable
final class ImageCompressionGitOptions {
    private(set) var isAvailable = false
    private(set) var isEnabled = false
    // A cancelled rescan keeps the displayed list, so its filter mode must be restored too.
    private var committedEnabled = false
    private var manualReplacement = false

    var replaceOriginals: Bool {
        get { isEnabled || manualReplacement }
        set {
            guard !isEnabled else { return }
            manualReplacement = newValue
        }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled && isAvailable
    }

    func updateAvailability(_ available: Bool) {
        isAvailable = available
        if !available { isEnabled = false }
        committedEnabled = isEnabled
    }

    func cancelPendingChange() {
        isEnabled = committedEnabled
    }
}

/// Resolve each input root once before publishing a batch of image rows on the main actor.
struct ImageCompressionInputPath {
    private let prefix: String?
    private let canonicalPrefix: String?

    init(root: URL) {
        if ImageTaskScanner.isDirectory(root) {
            let path = root.standardizedFileURL.path
            let canonical = root.resolvingSymlinksInPath().path
            prefix = path.hasSuffix("/") ? path : path + "/"
            canonicalPrefix = canonical.hasSuffix("/") ? canonical : canonical + "/"
        } else {
            prefix = nil
            canonicalPrefix = nil
        }
    }

    func relativePath(for image: URL) -> String {
        guard let prefix, let canonicalPrefix else { return image.lastPathComponent }
        let path = image.standardizedFileURL.path
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        let canonical = image.resolvingSymlinksInPath().path
        if canonical.hasPrefix(canonicalPrefix) { return String(canonical.dropFirst(canonicalPrefix.count)) }
        return image.lastPathComponent
    }
}

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
    func selectionHistory(merging current: [ImageItem], into previous: [ImageItem]) -> [ImageItem] {
        var history = previous
        var indices = Dictionary(previous.enumerated().map { ($0.element.id.resolvingSymlinksInPath(), $0.offset) },
                                 uniquingKeysWith: { first, _ in first })
        for item in current {
            let url = item.id.resolvingSymlinksInPath()
            if let index = indices[url] {
                history[index] = item
            } else {
                indices[url] = history.count
                history.append(item)
            }
        }
        return history
    }

    // A completed WebP replacement has moved the original single-file input to its result path.
    func effectiveScanRoots(_ roots: [URL], history: [ImageItem]) -> [URL] {
        let replacements = Dictionary(history.filter(hasMovedReplacement).compactMap { item -> (URL, URL)? in
            guard let destination = item.destinationPath else { return nil }
            return (item.id.resolvingSymlinksInPath(), URL(fileURLWithPath: destination))
        }, uniquingKeysWith: { first, _ in first })
        return roots.map { replacements[$0.resolvingSymlinksInPath()] ?? $0 }
    }

    private func hasMovedReplacement(_ item: ImageItem) -> Bool {
        item.status == .success && item.resultReplacedOriginal
            && !ImageCompressionInputRules.excludes(item.id)
            && !FileManager.default.fileExists(atPath: item.id.path)
            && item.destinationPath.map { FileManager.default.fileExists(atPath: $0) } == true
    }

    func retainingSelectionState(in scanned: [ImageItem], from previous: [ImageItem]) -> [ImageItem] {
        guard !previous.isEmpty else { return scanned }
        let previousByURL = Dictionary(previous.map { ($0.id.resolvingSymlinksInPath(), $0) },
                                       uniquingKeysWith: { first, _ in first })
        let movedResults = previous.filter(hasMovedReplacement)
        let resultURLs = Set(movedResults.compactMap { $0.destinationPath }.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath()
        })
        let retained = scanned.filter { !resultURLs.contains($0.id.resolvingSymlinksInPath()) }.map { item in
            guard let old = previousByURL[item.id.resolvingSymlinksInPath()] else { return item }
            if old.status == .success { return old }
            // Hidden images must follow the current threshold when they return to the list.
            var updated = old.byteCount == item.byteCount ? old : item
            updated.compressionOverride = old.compressionOverride
            updated.manualSkipOrder = old.manualSkipOrder
            if !isCompressionEnabled(for: updated) {
                updated.status = .skipped
            } else if updated.status == .waiting || updated.status == .skipped {
                updated.status = .waiting
            }
            return updated
        }
        return retained + movedResults
    }

    func reportGitScanFailure(_ error: Error) {
        operationStatus = "Git 图片筛选失败"
        operationStatusSystemImage = "xmark.circle"
        alertMessage = error.localizedDescription
    }

    func reportEmptyGitSelection() {
        operationStatus = "所选路径中没有 Git 未提交的图片"
        operationStatusSystemImage = "checkmark.circle"
    }

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
