import Foundation

struct ImageCompressionScanResult: Sendable {
    let scans: [ImageScanResult]
    let gitFilterAvailable: Bool
    let usesGitFilter: Bool
}

/// 检查输入的工作树资格；实际 Git status 筛选失败时不会回退到普通扫描。
enum GitChangedImageScanner {
    nonisolated static func scanSelection(
        _ roots: [URL], onlyGitChangedImages: Bool, supportedExtensions: Set<String>,
        scanImage: @Sendable (URL) -> ImageScanResult
    ) throws -> ImageCompressionScanResult {
        try withAccess(to: roots) {
            let available = try canFilter(roots)
            let usesGitFilter = onlyGitChangedImages && available
            let scans: [ImageScanResult]
            if usesGitFilter {
                // Eligibility may fall back to normal selection, but a status failure must surface.
                scans = try scan(roots, supportedExtensions: supportedExtensions)
            } else {
                scans = try roots.map { root in
                    try Task.checkCancellation()
                    return scanImage(root)
                }
            }
            try Task.checkCancellation()
            return ImageCompressionScanResult(
                scans: scans, gitFilterAvailable: available, usesGitFilter: usesGitFilter
            )
        }
    }

    nonisolated static func canFilter(_ roots: [URL]) throws -> Bool {
        try withAccess(to: roots) {
            guard !roots.isEmpty else { return false }
            var checkedDirectories = Set<URL>()
            for root in roots {
                try Task.checkCancellation()
                guard let values = try? root.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey
                ]), values.isSymbolicLink != true,
                      values.isDirectory == true || values.isRegularFile == true else { return false }
                let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
                let directory = values.isDirectory == true ? canonicalRoot : canonicalRoot.deletingLastPathComponent()
                guard checkedDirectories.insert(directory).inserted else { continue }
                do {
                    let output = try git(["rev-parse", "--is-inside-work-tree"], in: directory)
                    guard output == Data("true\n".utf8) else { return false }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Unavailable/non-repository selections keep the optional filter disabled.
                    return false
                }
            }
            return true
        }
    }

    nonisolated static func scan(
        _ roots: [URL], supportedExtensions: Set<String>
    ) throws -> [ImageScanResult] {
        try withAccess(to: roots) {
            let changed = try changedFiles(in: roots)
            return roots.map { root in
                // Another root may contribute this link's target to the shared changed set.
                let rootValues = try? root.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard rootValues?.isSymbolicLink != true else { return ImageScanResult(images: []) }
                let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
                let isDirectory = ImageTaskScanner.isDirectory(root)
                let images = changed.compactMap { file -> ImageScannedImage? in
                    guard contains(file, root: canonicalRoot, isDirectory: isDirectory),
                          supportedExtensions.contains(file.pathExtension.lowercased()),
                          let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                          let size = values.fileSize else { return nil }
                    // Keep importer path aliases and relative paths consistent with normal scans.
                    let url = isDirectory
                        ? root.appendingPathComponent(String(file.path.dropFirst(canonicalRoot.path.count + 1)))
                        : root
                    return ImageScannedImage(url: url, byteCount: Int64(size))
                }.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
                return ImageScanResult(images: images)
            }
        }
    }

    nonisolated private static func changedFiles(in roots: [URL]) throws -> Set<URL> {
        var repositoryFiles: [URL: Set<URL>] = [:]
        var result = Set<URL>()
        for root in roots {
            try Task.checkCancellation()
            // A directly selected symbolic link is not a writable image source.
            let rootValues = try? root.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard rootValues?.isSymbolicLink != true else { continue }
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
            let isDirectory = ImageTaskScanner.isDirectory(root)
            let directory = isDirectory ? canonicalRoot : canonicalRoot.deletingLastPathComponent()
            let topLevel: Data
            do {
                topLevel = try git(["rev-parse", "--show-toplevel"], in: directory)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ScanError(message: "无法读取 Git 仓库（\(root.path)）：\(error.localizedDescription)")
            }
            // rev-parse appends one newline; the repository name itself may contain newlines.
            var rootBytes = topLevel
            if rootBytes.last == 10 { rootBytes.removeLast() }
            guard let repositoryPath = String(data: rootBytes, encoding: .utf8), !repositoryPath.isEmpty else {
                throw ScanError(message: "Git 返回了无法识别的仓库路径。")
            }
            let repository = URL(fileURLWithPath: repositoryPath, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
            let files: Set<URL>
            if let cached = repositoryFiles[repository] {
                files = cached
            } else {
                let status = try git(
                    ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=all"],
                    in: repository
                )
                files = try statusFiles(status, repository: repository)
                repositoryFiles[repository] = files
            }
            result.formUnion(files.filter { contains($0, root: canonicalRoot, isDirectory: isDirectory) })
        }
        return result
    }

    nonisolated private static func statusFiles(_ data: Data, repository: URL) throws -> Set<URL> {
        let records = data.split(separator: 0, omittingEmptySubsequences: false)
        var result = Set<URL>()
        var index = 0
        while index < records.count {
            try Task.checkCancellation()
            let record = Array(records[index])
            index += 1
            if record.isEmpty { continue }
            guard record.count >= 4, record[2] == 32,
                  let path = String(bytes: record.dropFirst(3), encoding: .utf8) else {
                throw ScanError(message: "Git 返回了无法识别的文件状态。")
            }
            // In -z output a rename/copy records destination first, then the old path.
            if record[0] == 82 || record[1] == 82 || record[0] == 67 || record[1] == 67 {
                guard index < records.count, !records[index].isEmpty else {
                    throw ScanError(message: "Git 返回了不完整的重命名状态。")
                }
                index += 1
            }
            // A staged removal can leave an ignored working-tree file at the same path.
            // A separate untracked record for a recreated file is still considered below.
            guard record[0] != 68, record[1] != 68 else { continue }
            let file = repository.appendingPathComponent(path).standardizedFileURL
            guard file.path.hasPrefix(repository.path + "/"),
                  file.resolvingSymlinksInPath().standardizedFileURL == file,
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            result.insert(file)
        }
        return result
    }

    nonisolated private static func contains(_ file: URL, root: URL, isDirectory: Bool) -> Bool {
        isDirectory ? file.path.hasPrefix(root.path + "/") : file == root
    }

    nonisolated private static func withAccess<T>(to roots: [URL], _ work: () throws -> T) rethrows -> T {
        let access = roots.map { $0.startAccessingSecurityScopedResource() }
        defer {
            for (root, granted) in zip(roots, access) where granted {
                root.stopAccessingSecurityScopedResource()
            }
        }
        return try work()
    }

    nonisolated private static func git(_ arguments: [String], in directory: URL) throws -> Data {
        try Task.checkCancellation()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevKit-Git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let outputURL = temporaryDirectory.appendingPathComponent("stdout")
        let errorURL = temporaryDirectory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        defer {
            try? output.close()
            try? error.close()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-C", directory.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ScanError(message: message.isEmpty ? "Git 命令执行失败。" : message)
        }
        return try Data(contentsOf: outputURL)
    }

    private struct ScanError: LocalizedError, Sendable {
        let message: String
        nonisolated var errorDescription: String? { message }
    }
}
