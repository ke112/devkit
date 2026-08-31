import Foundation

enum MediaCompressionMode: String, CaseIterable, Identifiable, Sendable {
    case image
    case video

    var id: Self { self }

    var title: String {
        switch self {
        case .image: "图片"
        case .video: "视频"
        }
    }
}

enum MediaCompressionState: Equatable {
    case pending
    case processing
    case success
    case skipped
    case copiedFallback
    case failed(String)
}

struct MediaImageTask: Identifiable, Equatable {
    let id = UUID()
    let sourceURL: URL
    var relativeDir: String?
    var destinationURL: URL?
    var originalBytes: Int64?
    var compressedBytes: Int64?
    var originalSize: CGSize?
    var compressedSize: CGSize?
    var usedFormat: String?
    var state: MediaCompressionState = .pending
}

struct MediaVideoTask: Identifiable, Equatable {
    let id = UUID()
    let sourceURL: URL
    var relativeDir: String?
    var destinationURL: URL?
    var originalBytes: Int64?
    var compressedBytes: Int64?
    var duration: Double?
    var state: MediaCompressionState = .pending
}

enum MediaOutputFormat: String, CaseIterable, Identifiable, Sendable {
    case auto = "保留原格式"
    case jpeg = "JPEG"
    case png = "PNG"
    case heic = "HEIC"

    var id: Self { self }
}

enum MediaVideoPreset: String, CaseIterable, Identifiable, Sendable {
    case high = "高质量"
    case medium = "中等质量"
    case low = "较小体积"

    var id: Self { self }
}

enum MediaCompressorError: LocalizedError {
    case unsupportedFile
    case cannotReadImage
    case cannotCreateDestination
    case cannotWriteDetail(String)
    case videoExportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile: "不支持的文件类型。"
        case .cannotReadImage: "无法读取图片数据。"
        case .cannotCreateDestination: "无法创建输出图片。"
        case .cannotWriteDetail(let detail): detail
        case .videoExportFailed(let detail): "视频导出失败：\(detail)"
        }
    }
}

struct MediaImageCompressionConfig: Sendable {
    let targetBytes: Int64
    let outputFormat: MediaOutputFormat
    let batchDirectory: URL
}

struct MediaVideoCompressionConfig: Sendable {
    let preset: MediaVideoPreset
    let batchDirectory: URL
}

func mediaFormatBytes(_ value: Int64?) -> String {
    guard let value else { return "-" }
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: value)
}

func mediaFormatDimensions(_ size: CGSize?) -> String {
    guard let size else { return "-" }
    return "\(Int(size.width))×\(Int(size.height))"
}
