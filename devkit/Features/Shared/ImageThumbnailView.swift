import AppKit
import SwiftUI

// MARK: - 任务行缩略图

/// 任务行缩略图:后台用 ImageIO 按 maxPixelSize 降采样加载,
/// 避免超大图(如 2 亿像素级照片)在主线程整图解码造成卡顿。
struct ImageThumbnailView: View {
    static let defaultMaxPixelSize = 132

    var url: URL?
    var maxPixelSize: Int = ImageThumbnailView.defaultMaxPixelSize

    @State private var thumbnail: CGImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(thumbnail, scale: 1, orientation: .up, label: Text(url?.lastPathComponent ?? ""))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
            }
        }
        .task(id: url) {
            guard let url else { return }
            thumbnail = await ImageThumbnailLoader.thumbnail(at: url, maxPixelSize: maxPixelSize)
        }
    }
}

// MARK: - 共享缩略图加载器

/// 缩略图加载器:主线程负责缓存与文件信息读取,解码放到专用队列降采样,
/// 结果按文件路径 + 修改时间 + 大小 + 目标尺寸缓存,文件被覆盖后自动失效。
enum ImageThumbnailLoader {
    private static let decodeQueue = DispatchQueue(
        label: "devkit.image-thumbnail-decode",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let cache = NSCache<NSString, CGImage>()
    private static let cacheCountLimit = 200

    /// 预览弹窗按窗口大小取 2880(约 1440pt @2x),行内缩略图见 ImageThumbnailView。
    static let previewMaxPixelSize = 2880

    static func thumbnail(at url: URL, maxPixelSize: Int) async -> CGImage? {
        let key = cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        let image: CGImage? = await withCheckedContinuation { continuation in
            decodeQueue.async {
                continuation.resume(returning: downsampledImage(at: url, maxPixelSize: maxPixelSize))
            }
        }
        if let image {
            cache.countLimit = cacheCountLimit
            cache.setObject(image, forKey: key as NSString)
        }
        return image
    }

    private static func cacheKey(for url: URL, maxPixelSize: Int) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? Int64) ?? 0
        return "\(maxPixelSize)|\(url.path)|\(modified)|\(size)"
    }

    /// 在调用线程解码降采样图,EXIF 方向已应用;只应通过 decodeQueue 调用。
    nonisolated static func downsampledImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }
}
