import Foundation

/// 应用启动时静默准备图片功能依赖：cwebp（WebP 转换）与 python3 requests/urllib3（TinyPNG）。
/// 依赖已就绪时脚本只做检测、不触发网络；安装失败保持静默，由功能页在运行时给出提示。
enum DependencyBootstrap {
    static let scriptResourceName = "ensure_image_dependencies"

    private static var hasStarted = false

    static func start(bundle: Bundle = .main) {
        guard !hasStarted else { return }
        hasStarted = true
        guard let scriptURL = bundle.url(
            forResource: scriptResourceName,
            withExtension: "sh"
        ) else {
            return
        }

        Task.detached(priority: .utility) {
            _ = try? await StreamingProcess.run(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [scriptURL.path],
                currentDirectoryURL: FileManager.default.temporaryDirectory,
                environment: [
                    "DEVKIT_PARENT_PID": String(ProcessInfo.processInfo.processIdentifier)
                ]
            ) { _ in }
        }
    }
}
