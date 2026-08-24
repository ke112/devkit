import Foundation

struct AppStoreVersion: Codable, Equatable, Identifiable {
    let id: String
    let versionString: String
    let platform: String
    let appStoreState: String
    let createdDate: String?
    let releaseType: String?
    let earliestReleaseDate: String?

    var stateDisplayName: String {
        switch appStoreState {
        case "READY_FOR_SALE": return "可供销售"
        case "READY_FOR_DISTRIBUTION": return "可供分发"
        case "PREPARE_FOR_SUBMISSION": return "准备提交"
        case "READY_FOR_REVIEW": return "可提交审核"
        case "WAITING_FOR_REVIEW": return "等待审核"
        case "IN_REVIEW": return "审核中"
        case "PENDING_DEVELOPER_RELEASE": return "等待开发者发布"
        case "PENDING_APPLE_RELEASE": return "等待 Apple 发布"
        case "PROCESSING_FOR_APP_STORE": return "处理中"
        case "DEVELOPER_REJECTED": return "开发者拒绝"
        case "REJECTED": return "被拒绝"
        case "METADATA_REJECTED": return "元数据被拒绝"
        case "INVALID_BINARY": return "构建版本无效"
        case "WAITING_FOR_EXPORT_COMPLIANCE": return "等待出口合规"
        case "PENDING_CONTRACT": return "协议待处理"
        case "DEVELOPER_REMOVED_FROM_SALE": return "开发者已下架"
        case "REMOVED_FROM_SALE": return "已下架"
        case "REPLACED_WITH_NEW_VERSION": return "已被新版本替代"
        case "NOT_APPLICABLE": return "不适用"
        default: return appStoreState.isEmpty ? "未知状态" : appStoreState
        }
    }

    var releaseTypeDisplayName: String {
        switch releaseType {
        case "MANUAL": return "手动发布"
        case "AFTER_APPROVAL": return "审核通过后"
        case "SCHEDULED": return "定时发布"
        default: return releaseType ?? "未设置"
        }
    }

    var createdDateDisplayName: String {
        guard let createdDate else { return "未知" }
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: createdDate) else { return createdDate }
        return date.formatted(date: .numeric, time: .omitted)
    }

    static func isValidVersionString(_ value: String) -> Bool {
        value.count <= 18
            && value.range(
                of: #"^[0-9]+(?:\.[0-9]+){0,2}$"#,
                options: .regularExpression
            ) != nil
    }

    static func missingVersion(in output: String, expectedVersion: String) -> String? {
        let version = expectedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, output.contains("找不到 version_string=\(version)") else {
            return nil
        }
        return version
    }
}

struct AppStoreVersionsResponse: Codable, Equatable {
    let versions: [AppStoreVersion]
}
