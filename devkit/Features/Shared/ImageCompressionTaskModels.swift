import SwiftUI

// MARK: - 任务状态

/// TinyPNG / WebP / Luban 三个压缩转换页共用的任务状态。
/// 等待与进行中的标题按各页动词拼接（压缩/转换/上传），其余文案与颜色完全一致。
enum ImageCompressionTaskStatus: Equatable {
    case waiting
    case working
    case success
    case skipped
    case cancelled
    case failed(String)

    func title(verb: String) -> String {
        switch self {
        case .waiting: "等待\(verb)"
        case .working: "\(verb)中"
        case .success: "已完成"
        case .skipped: "已跳过"
        case .cancelled: "已停止"
        case .failed: "失败"
        }
    }

    var color: Color {
        switch self {
        case .waiting: .secondary
        case .working: .accentColor
        case .success: .green
        case .skipped: .orange
        case .cancelled: .secondary
        case .failed: .red
        }
    }
}

// MARK: - 大小统计

/// 压缩/转换前后总字节数与整体节省比例，三个页面共用。
struct ImageCompressionSizeStats: Equatable {
    let beforeBytes: Int64
    let afterBytes: Int64

    var savedPercentage: Double {
        guard beforeBytes > 0 else { return 0 }
        return Double(beforeBytes - afterBytes) / Double(beforeBytes) * 100
    }
}

// MARK: - 脚本事件

/// TinyPNG / WebP 脚本 `EVENT ` 行的共用解码模型；`skipped` 仅 WebP 脚本输出。
struct ImageCompressionProcessEvent: Decodable {
    let src: String
    let dst: String?
    let ok: Bool
    let before: Int64
    let after: Int64
    let skipped: Bool?
    let elapsed: Double?
    let error: String
}
