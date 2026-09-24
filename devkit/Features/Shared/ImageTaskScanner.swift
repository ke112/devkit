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
        if !isDirectory(url) {
            guard isSupportedImage(url, supportedExtensions: supportedExtensions),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = values.fileSize else {
                return ImageScanResult(images: [])
            }
            return ImageScanResult(images: [
                ImageScannedImage(url: url, byteCount: Int64(fileSize))
            ])
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return ImageScanResult(images: [])
        }

        var images: [ImageScannedImage] = []
        for item in enumerator {
            if Task.isCancelled {
                break
            }
            guard let imageURL = item as? URL,
                  isSupportedImage(imageURL, supportedExtensions: supportedExtensions),
                  let values = try? imageURL.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                  ),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else {
                continue
            }
            images.append(
                ImageScannedImage(url: imageURL, byteCount: Int64(fileSize))
            )
        }

        images.sort {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
        return ImageScanResult(images: images)
    }
}
