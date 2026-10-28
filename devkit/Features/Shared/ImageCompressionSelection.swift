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
    var resultReplacedOriginal: Bool { get set }
}

struct ImageCompressionScanConfiguration: Sendable {
    let supportedExtensions: Set<String>
    let scan: @Sendable (URL) -> ImageScanResult
    let invalidInputMessage: String
    var emptyInputMessage: String? = nil
}

@MainActor
@Observable
final class ImageCompressionSelectionState<Item: SelectableImageCompressionTaskItem> {
    var selectedURLs: [URL] = []
    var imageItems: [Item] = []
    fileprivate(set) var isScanning = false
    fileprivate let gitOptions = ImageCompressionGitOptions()
    fileprivate var worker: Task<ImageCompressionScanResult, Error>?
    fileprivate var pendingURLs: [URL] = []
    fileprivate var history: [Item] = []
    fileprivate var isRefreshing = false
    fileprivate var token = UUID()

    fileprivate func cancel() {
        worker?.cancel()
        worker = nil
        token = UUID()
        pendingURLs = []
        isScanning = false
        isRefreshing = false
    }

    fileprivate func clear() {
        cancel()
        selectedURLs = []
        imageItems = []
        history = []
        gitOptions.updateAvailability(false)
    }
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
    var selectionState: ImageCompressionSelectionState<ImageItem> { get }
    var scanConfiguration: ImageCompressionScanConfiguration { get }
    var minimumCompressionSizeKB: Int { get }
    var canRun: Bool { get }
    var isRunning: Bool { get }
    var isScanning: Bool { get }
    var isRestoring: Bool { get set }
    var operationStatus: String { get set }
    var operationStatusSystemImage: String { get set }
    var alertMessage: String? { get set }
    var operationVerb: String { get }
    func supportsProcessing(_ item: ImageItem) -> Bool
    func makeSelectionItem(_ image: ImageScannedImage, relativePath: String) -> ImageItem
    func prepareForSelectionScan()
    func selectionDidChange()
    func startSelectionProcessing() -> Task<Void, Never>?
}

extension ImageCompressionSelectionModel {
    var imageItems: [ImageItem] {
        get { selectionState.imageItems }
        set { selectionState.imageItems = newValue }
    }
    var selectedURLs: [URL] {
        get { selectionState.selectedURLs }
        set { selectionState.selectedURLs = newValue }
    }
    var isScanning: Bool { selectionState.isScanning }
    var canRun: Bool {
        !selectedURLs.isEmpty && !isRunning && !isScanning && !isRestoring
            && imageItems.contains { $0.status != .success && isCompressionEnabled(for: $0) }
    }
    var isGitFilterAvailable: Bool { selectionState.gitOptions.isAvailable }
    var onlyGitChangedImages: Bool {
        get { selectionState.gitOptions.isEnabled }
        set {
            let previous = onlyGitChangedImages
            selectionState.gitOptions.setEnabled(newValue)
            if previous != onlyGitChangedImages, !selectedURLs.isEmpty {
                selectImages(urls: selectedURLs, refreshing: true)
            }
        }
    }
    var replaceOriginals: Bool {
        get { selectionState.gitOptions.replaceOriginals }
        set { selectionState.gitOptions.replaceOriginals = newValue }
    }

    func prepareForSelectionScan() {}
    func selectionDidChange() {}

    /// One selection transaction for all tools: validate, scan off-main, restore choices, publish, then run.
    @discardableResult
    func selectImages(
        urls: [URL], refreshing: Bool = false, startAfterScan: Bool = false
    ) -> (accepted: Bool, completion: Task<Void, Never>?) {
        let state = selectionState
        guard !isRunning, !isRestoring, !state.isRefreshing else { return (false, nil) }
        let configuration = scanConfiguration
        let previous = selectionHistory(merging: imageItems, into: state.history)
        let queuedURLs = startAfterScan && !onlyGitChangedImages
            ? Set(imageItems.map { $0.id.resolvingSymlinksInPath() }) : nil
        let standardized = urls.map(\.standardizedFileURL)
        let effective = effectiveScanRoots(standardized, history: previous)
        // Revalidation must include missing original roots so it cannot silently run a surviving subset.
        let valid = refreshing ? standardized : zip(standardized, effective).filter {
            ImageTaskScanner.accepts($0.1, supportedExtensions: configuration.supportedExtensions)
        }.map(\.0)
        guard !valid.isEmpty else {
            alertMessage = configuration.invalidInputMessage
            return (false, nil)
        }
        var knownRoots = Set((refreshing ? [] : selectedURLs + state.pendingURLs).map(\.path))
        let accepted = valid.filter { knownRoots.insert($0.path).inserted }
        let newRoots = accepted.filter { input in
            refreshing || !accepted.contains { $0.path != input.path && input.path.hasPrefix($0.path + "/") }
        }
        state.worker?.cancel()
        var seenRoots = Set<String>()
        state.pendingURLs = (refreshing ? newRoots : selectedURLs + state.pendingURLs + newRoots)
            .filter { seenRoots.insert($0.path).inserted }
        state.token = UUID()
        let token = state.token
        state.isRefreshing = refreshing
        state.isScanning = true
        prepareForSelectionScan()
        operationStatus = "正在扫描图片"
        operationStatusSystemImage = "arrow.triangle.2.circlepath"
        alertMessage = nil
        let roots = state.pendingURLs
        let scanRoots = effectiveScanRoots(roots, history: previous)
        let gitOnly = onlyGitChangedImages
        let worker = Task.detached(priority: .userInitiated) {
            try GitChangedImageScanner.scanSelection(
                scanRoots, onlyGitChangedImages: gitOnly,
                supportedExtensions: configuration.supportedExtensions, scanImage: configuration.scan
            )
        }
        state.worker = worker
        let completion = Task { @MainActor [weak self, state, worker] in
            let outcome = await worker.result
            guard let self, state.token == token, !worker.isCancelled else { return }
            state.worker = nil
            state.pendingURLs = []
            state.isScanning = false
            state.isRefreshing = false
            state.history = previous
            state.selectedURLs = roots
            guard case .success(let batch) = outcome else {
                state.imageItems = []
                state.gitOptions.updateAvailability(false)
                self.selectionDidChange()
                if case .failure(let error) = outcome { self.reportGitScanFailure(error) }
                return
            }
            state.gitOptions.updateAvailability(batch.gitFilterAvailable)
            var knownImages = Set<URL>()
            var scanned: [ImageItem] = []
            for (root, result) in zip(roots, batch.scans) {
                let inputPath = ImageCompressionInputPath(root: root)
                for image in result.images {
                    let canonical = image.url.resolvingSymlinksInPath()
                    guard knownImages.insert(canonical).inserted,
                          queuedURLs?.contains(canonical) != false else { continue }
                    var item = self.makeSelectionItem(image, relativePath: inputPath.relativePath(for: image.url))
                    item.status = self.isCompressionEnabled(for: item) ? .waiting : .skipped
                    scanned.append(item)
                }
            }
            state.imageItems = self.retainingSelectionState(in: scanned, from: previous)
            state.history = self.selectionHistory(merging: state.imageItems, into: previous)
            self.selectionDidChange()
            guard !state.imageItems.isEmpty else {
                if batch.usesGitFilter {
                    self.reportEmptyGitSelection()
                } else {
                    self.operationStatus = "已选择，等待开始"
                    self.operationStatusSystemImage = "checkmark.circle"
                    self.alertMessage = configuration.emptyInputMessage
                }
                return
            }
            self.operationStatus = "已选择，等待开始"
            self.operationStatusSystemImage = "checkmark.circle"
            if startAfterScan, !gitOnly || batch.usesGitFilter {
                await self.startSelectionProcessing()?.value
            }
        }
        return (true, completion)
    }

    func stopSelectionScan() -> Bool {
        guard isScanning else { return false }
        selectionState.gitOptions.cancelPendingChange()
        selectionState.cancel()
        operationStatus = "已停止"
        operationStatusSystemImage = "stop.circle"
        return true
    }

    func clearSelectionState() {
        selectionState.clear()
        selectionDidChange()
        operationStatus = "请选择图片或文件夹"
        operationStatusSystemImage = "photo.on.rectangle"
        alertMessage = nil
    }

    func refreshSelectionEligibility() {
        guard !isRunning, !isScanning, !isRestoring else { return }
        imageItems = imageItems.map { item in
            guard item.status != .success, item.status != .working else { return item }
            var updated = item
            updated.status = isCompressionEnabled(for: item) ? .waiting : .skipped
            updated.clearResultMetrics()
            return updated
        }
        selectionDidChange()
    }

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
        let ordered = imageItems.sorted {
            if $0.byteCount != $1.byteCount { return $0.byteCount > $1.byteCount }
            let nameOrder = $0.relativePath.localizedStandardCompare($1.relativePath)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return $0.id.path < $1.id.path
        }
        let included = ordered.filter { $0.status != .skipped }
        let skipped = ordered.filter { $0.status == .skipped }
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
