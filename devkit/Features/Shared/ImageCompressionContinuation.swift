import Foundation
import Luban

/// Selection, result preservation and publication are shared; only encoding differs by tool.
enum ImageRecompressionMethod {
    case tinyPNG
    case luban
    case webP(quality: Int, maximumSideLength: Int)

    func encode(_ input: URL, in directory: URL, cancellation: StreamingProcessCancellation) async throws -> URL? {
        if case .luban = self {
            return try await Luban.compress(input, to: directory.appendingPathComponent("result.jpg"))
        }
        let scriptName: String
        var options = ["--min-size-kb", "0"]
        switch self {
        case .tinyPNG:
            scriptName = "tinypng"
            options += ["--replace"]
        case .webP(let quality, let maximumSideLength):
            scriptName = "webp_convert"
            options += ["--recompress-webp", "--quality", String(quality),
                        "--max-side", String(maximumSideLength), "--output-dir", directory.path]
        case .luban:
            preconditionFailure("Luban uses the native encoder")
        }
        guard let script = Bundle.main.url(forResource: scriptName, withExtension: "py") else {
            throw ImageRecompressionError(message: "App 内缺少脚本：\(scriptName).py")
        }
        let result = try await StreamingProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-l", "-c", "exec python3 -B -u \"$@\"", "devkit", script.path, input.path] + options,
            currentDirectoryURL: directory,
            cancellation: cancellation,
            environment: ["DEVKIT_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier)],
            onOutput: { _ in }
        )
        guard !cancellation.isCancelled else { throw CancellationError() }
        let events = result.output.split(whereSeparator: \.isNewline).compactMap { line -> ImageCompressionProcessEvent? in
            guard line.hasPrefix("EVENT ") else { return nil }
            return try? JSONDecoder().decode(ImageCompressionProcessEvent.self, from: Data(line.dropFirst(6).utf8))
        }
        guard result.terminationStatus == 0, let event = events.last else {
            throw ImageRecompressionError(message: events.last?.error.nonEmpty
                ?? "压缩脚本执行失败（退出码 \(result.terminationStatus)）")
        }
        if event.skipped == true { return nil }
        guard event.ok, let destination = event.dst else {
            throw ImageRecompressionError(message: event.error.nonEmpty ?? "压缩脚本未返回结果图")
        }
        return URL(fileURLWithPath: destination)
    }
}

private struct ImageRecompressionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension ImageCompressionSelectionModel {
    /// Re-encode the latest destinations without changing row identity or the original Reset contract.
    @discardableResult
    func continueCompression(for id: URL? = nil) -> Task<Void, Never>? {
        guard canRun else { return nil }
        let items = imageItems.filter {
            $0.status == .success && $0.destinationPath != nil && (id == nil || $0.id == id)
        }
        guard !items.isEmpty else { return nil }
        let state = selectionState
        let cancellation = StreamingProcessCancellation()
        state.continuationCancellation = cancellation
        isRunning = true
        isStopping = false
        alertMessage = nil
        operationStatus = "正在继续压缩"
        operationStatusSystemImage = "arrow.triangle.2.circlepath"
        let method = recompressionMethod
        let destinations = items.compactMap { $0.destinationPath }.map { URL(fileURLWithPath: $0) }
        let sources = zip(items, destinations).map { item, destination in
            item.resultReplacedOriginal ? destination : item.id
        }
        let roots = selectedURLs
        let eligibilityRoots = effectiveScanRoots(roots, history: imageItems)
        let gitOnly = onlyGitChangedImages
        let extensions = scanConfiguration.supportedExtensions
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let accessRoots = roots + destinations
            let access = accessRoots.map { $0.startAccessingSecurityScopedResource() }
            defer {
                for (root, granted) in zip(accessRoots, access) where granted {
                    root.stopAccessingSecurityScopedResource()
                }
                state.continuationTask = nil
                state.continuationCancellation = nil
                self.isRunning = false
                self.isStopping = false
            }
            var errors: [String] = []
            var reducedCount = 0
            do {
                // Check the displayed sources and actual results only; never discover new output copies.
                try await Task.detached(priority: .userInitiated) {
                    if gitOnly, try !GitChangedImageScanner.canFilter(eligibilityRoots) {
                        throw ImageRecompressionError(message: "所选路径已不满足 Git 筛选条件，请重新选择。")
                    }
                    for paths in [sources, destinations] {
                        let batch = try GitChangedImageScanner.scanSelection(
                            paths, onlyGitChangedImages: gitOnly, supportedExtensions: extensions,
                            scanImage: { ImageTaskScanner.scan($0, supportedExtensions: extensions) }
                        )
                        let allowed = Set(batch.scans.flatMap(\.images).map { $0.url.resolvingSymlinksInPath() })
                        guard (!gitOnly || batch.usesGitFilter), paths.allSatisfy({
                            allowed.contains($0.resolvingSymlinksInPath())
                        }) else {
                            throw ImageRecompressionError(message: "图片已缺失、被忽略或不满足筛选条件，已保留上一次结果。")
                        }
                    }
                }.value
                for item in items {
                    guard !cancellation.isCancelled else { break }
                    guard let index = self.imageItems.firstIndex(where: { $0.id == item.id }),
                          let path = item.destinationPath else { continue }
                    self.imageItems[index].status = .working
                    let started = Date()
                    do {
                        let outcome = try await recompressResult(
                            at: URL(fileURLWithPath: path), method: method, cancellation: cancellation
                        )
                        self.imageItems[index].status = .success
                        self.imageItems[index].elapsedSeconds = Date().timeIntervalSince(started)
                        self.imageItems[index].resultByteCount = outcome.bytes
                        self.imageItems[index].resultPercentage = ImageCompressionSizeStats(
                            beforeBytes: item.byteCount, afterBytes: outcome.bytes
                        ).savedPercentage
                        if outcome.reduced { reducedCount += 1 }
                    } catch {
                        // A failed or cancelled attempt leaves the previous result and its controls intact.
                        self.imageItems[index] = item
                        if !cancellation.isCancelled {
                            errors.append("\(item.relativePath)：\(error.localizedDescription)")
                        }
                    }
                }
            } catch {
                errors.append(error.localizedDescription)
            }
            if cancellation.isCancelled {
                self.operationStatus = "已停止"
                self.operationStatusSystemImage = "stop.circle"
            } else if !errors.isEmpty {
                self.operationStatus = "继续压缩失败，已保留上一次结果"
                self.operationStatusSystemImage = "xmark.circle"
                self.alertMessage = errors.joined(separator: "\n")
            } else {
                self.operationStatus = reducedCount > 0 ? "继续压缩完成" : "未进一步减小，已保留上一次结果"
                self.operationStatusSystemImage = "checkmark.circle"
            }
        }
        state.continuationTask = task
        return task
    }

    func stopContinuedCompression() -> Bool {
        guard let cancellation = selectionState.continuationCancellation else { return false }
        isStopping = true
        operationStatus = "正在停止"
        operationStatusSystemImage = "stop.circle"
        cancellation.cancel()
        selectionState.continuationTask?.cancel()
        return true
    }
}

private func recompressResult(
    at destination: URL, method: ImageRecompressionMethod, cancellation: StreamingProcessCancellation
) async throws -> (bytes: Int64, reduced: Bool) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DevKitRecompression-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("input").appendingPathExtension(destination.pathExtension)
    let original = try await Task.detached(priority: .userInitiated) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Data(contentsOf: destination)
        try data.write(to: input)
        return data
    }.value
    guard !cancellation.isCancelled else { throw CancellationError() }
    let encoded = try await method.encode(input, in: directory, cancellation: cancellation)
    return try await Task.detached(priority: .userInitiated) {
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard let encoded else { return (Int64(original.count), false) }
        let data = try Data(contentsOf: encoded)
        guard !data.isEmpty else { throw ImageRecompressionError(message: "结果图为空，已保留上一次结果。") }
        guard data.count < original.count else { return (Int64(original.count), false) }
        guard try Data(contentsOf: destination) == original else {
            throw ImageRecompressionError(message: "结果图已被其他程序修改，请重新选择。")
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".devkit-recompression-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        guard !cancellation.isCancelled else { throw CancellationError() }
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        return (Int64(data.count), true)
    }.value
}
