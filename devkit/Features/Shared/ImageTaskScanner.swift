import Darwin
import Dispatch
import Foundation

/// 三个压缩转换页共用的扫描结果单元；`isWebP` 由扩展名推导，仅 WebP 转换页使用。
struct ImageScannedImage: Sendable {
    let url: URL
    let byteCount: Int64

    var isWebP: Bool {
        url.pathExtension.lowercased() == "webp"
    }
}

struct ImageScanResult: Sendable {
    let images: [ImageScannedImage]
}

/// TinyPNG / WebP / Luban 共用的图片与目录扫描逻辑；支持的扩展名集合由各页传入。
enum ImageTaskScanner {
    nonisolated static func accepts(_ url: URL, supportedExtensions: Set<String>) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue || isSupportedImage(url, supportedExtensions: supportedExtensions)
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var directory = ObjCBool(false)
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        return directory.boolValue
    }

    nonisolated static func isSupportedImage(_ url: URL, supportedExtensions: Set<String>) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated static func scan(_ url: URL, supportedExtensions: Set<String>) -> ImageScanResult {
        scan(url, supportedExtensions: supportedExtensions, onDirectoryScan: nil)
    }

    /// Internal observation point for deterministic traversal/cancellation tests; production callers omit it.
    nonisolated static func scan(
        _ url: URL, supportedExtensions: Set<String>, onDirectoryScan: (@Sendable (String) -> Void)?
    ) -> ImageScanResult {
        var rootMetadata = stat()
        guard lstat(url.path, &rootMetadata) == 0,
              !ImageCompressionInputRules.excludes(url) else {
            return ImageScanResult(images: [])
        }
        let rootType = rootMetadata.st_mode & mode_t(S_IFMT)
        if rootType != mode_t(S_IFDIR) {
            guard rootType == mode_t(S_IFREG),
                  isSupportedImage(url, supportedExtensions: supportedExtensions) else {
                return ImageScanResult(images: [])
            }
            return ImageScanResult(images: [
                ImageScannedImage(url: url, byteCount: Int64(rootMetadata.st_size))
            ])
        }

        var images = withUnsafeCurrentTask { task in
            // concurrentPerform joins every worker before this borrowed task handle can leave scope.
            let cancellation = ImageScanCancellation(task)
            return scanDirectoryTree(url.path, supportedExtensions: supportedExtensions,
                                     cancellation: cancellation, onDirectoryScan: onDirectoryScan)
        }

        images.sort {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        return ImageScanResult(images: images)
    }

    nonisolated private static func scanDirectoryTree(
        _ root: String, supportedExtensions: Set<String>, cancellation: ImageScanCancellation,
        onDirectoryScan: (@Sendable (String) -> Void)?
    ) -> [ImageScannedImage] {
        var images: [ImageScannedImage] = []
        var frontier = [root]
        // Expose independent subdirectories before distributing a large subtree across workers.
        for _ in 0..<2 {
            var next: [String] = []
            for path in frontier {
                guard !cancellation.isCancelled else { return images }
                scanDirectory(path, supportedExtensions: supportedExtensions,
                              cancellation: cancellation, onDirectoryScan: nil,
                              directories: &next, images: &images)
            }
            frontier = next
        }
        guard !frontier.isEmpty, !cancellation.isCancelled else { return images }

        let count = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount), frontier.count)
        var buckets = Array(repeating: [String](), count: count)
        for (index, directory) in frontier.enumerated() { buckets[index % count].append(directory) }
        let inputs = buckets
        let results = ImageScanResults(count: count)
        DispatchQueue.concurrentPerform(iterations: count) { index in
            var directories = inputs[index]
            var localImages: [ImageScannedImage] = []
            while !cancellation.isCancelled, let directory = directories.popLast() {
                scanDirectory(directory, supportedExtensions: supportedExtensions,
                              cancellation: cancellation, onDirectoryScan: onDirectoryScan,
                              directories: &directories, images: &localImages)
            }
            results.store(localImages, at: index)
        }
        images.append(contentsOf: results.merged())
        return images
    }

    nonisolated private static func scanDirectory(
        _ path: String, supportedExtensions: Set<String>,
        cancellation: ImageScanCancellation,
        onDirectoryScan: (@Sendable (String) -> Void)?,
        directories: inout [String], images: inout [ImageScannedImage]
    ) {
        guard !cancellation.isCancelled, let directory = opendir(path) else { return }
        defer { closedir(directory) }
        let descriptor = dirfd(directory)
        if !cancellation.isCancelled { onDirectoryScan?(path) }
        while !cancellation.isCancelled, let entry = readdir(directory) {
            let count = Int(entry.pointee.d_namlen)
            withUnsafePointer(to: &entry.pointee.d_name) { storage in
                let name = UnsafeRawPointer(storage).assumingMemoryBound(to: CChar.self)
                guard !(count == 1 && name[0] == 46),
                      !(count == 2 && name[0] == 46 && name[1] == 46) else { return }

                var metadata = stat()
                var hasMetadata = false
                var type = Int32(entry.pointee.d_type)
                // Some filesystems omit d_type. Resolve it without following symbolic links.
                if type == DT_UNKNOWN {
                    guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { return }
                    hasMetadata = true
                    let mode = metadata.st_mode & mode_t(S_IFMT)
                    if mode == mode_t(S_IFDIR) { type = DT_DIR }
                    else if mode == mode_t(S_IFREG) { type = DT_REG }
                    else { return }
                }

                if type == DT_DIR {
                    let component = String(cString: name)
                    guard !ImageCompressionInputRules.excludesDirectory(named: component) else { return }
                    directories.append(childPath(component, in: path))
                    return
                }
                // Reject non-images before constructing their URL or requesting metadata.
                guard type == DT_REG, supportsName(name, count: count, extensions: supportedExtensions) else { return }
                if !hasMetadata {
                    guard fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
                          metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return }
                }
                let imageURL = URL(fileURLWithPath: childPath(String(cString: name), in: path))
                images.append(ImageScannedImage(url: imageURL, byteCount: Int64(metadata.st_size)))
            }
        }
    }

    nonisolated private static func supportsName(
        _ name: UnsafePointer<CChar>, count: Int, extensions: Set<String>
    ) -> Bool {
        guard count > 2 else { return false }
        var index = count - 1
        while index > 0 {
            if name[index] == 46 {
                guard index < count - 1 else { return false }
                let bytes = UnsafeRawPointer(name.advanced(by: index + 1)).assumingMemoryBound(to: UInt8.self)
                let suffix = String(decoding: UnsafeBufferPointer(start: bytes, count: count - index - 1), as: UTF8.self)
                return extensions.contains(suffix.lowercased())
            }
            index -= 1
        }
        return false
    }

    nonisolated private static func childPath(_ name: String, in directory: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    /// The handle is borrowed only within withUnsafeCurrentTask and its synchronous worker join.
    private final class ImageScanCancellation: @unchecked Sendable {
        nonisolated(unsafe) private let task: UnsafeCurrentTask?

        nonisolated init(_ task: UnsafeCurrentTask?) { self.task = task }

        nonisolated var isCancelled: Bool { task?.isCancelled ?? false }
    }

    private final class ImageScanResults: @unchecked Sendable {
        private let lock = NSLock()
        nonisolated(unsafe) private var batches: [[ImageScannedImage]]

        nonisolated init(count: Int) { batches = Array(repeating: [], count: count) }

        nonisolated func store(_ images: [ImageScannedImage], at index: Int) {
            lock.withLock { batches[index] = images }
        }

        nonisolated func merged() -> [ImageScannedImage] {
            lock.withLock { batches.flatMap { $0 } }
        }
    }
}
