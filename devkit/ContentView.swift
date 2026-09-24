import Foundation
import SwiftUI


struct ContentView: View {
    private let featureColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]
    private let preferencesDefaults: UserDefaults

    @State private var featureSettings: [HomeFeatureSetting]

    init(preferencesDefaults: UserDefaults = .standard) {
        self.preferencesDefaults = preferencesDefaults
        _featureSettings = State(
            initialValue: HomeFeaturePreferences.load(from: preferencesDefaults)
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if visibleFeatureSettings.isEmpty {
                    ContentUnavailableView(
                        "暂无显示的功能",
                        systemImage: "square.grid.2x2"
                    )
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView(.vertical) {
                            LazyVGrid(columns: featureColumns, spacing: 14) {
                                ForEach(visibleFeatureSettings) { setting in
                                    FeatureLink(feature: setting.feature)
                                }
                            }
                            .padding(.top, 24)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 28)
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                        .scrollIndicators(.visible)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        HomeDisplaySection()
                            .frame(width: 250)
                            .padding(.trailing, 24)
                            .padding(.vertical, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("DevKit")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        HomeFeatureSettingsView(featureSettings: $featureSettings)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("首页设置")
                    .accessibilityLabel("首页设置")
                }
            }
            .navigationDestination(for: DevKitFeature.self) { feature in
                switch feature {
                case .simulatorManagement:
                    SimulatorManagementView()
                case .imageOverlay:
                    ImageOverlayView()
                case .appStoreRelease:
                    AppStoreReleaseView()
                case .tinyPNG:
                    TinyPNGView()
                case .lubanCompression:
                    LubanCompressionView()
                case .webPConversion:
                    WebPConversionView()
                case .mediaCompression:
                    MediaCompressionView()
                case .watermarkRemoval:
                    WatermarkRemovalView()
                case .idPhoto:
                    IDPhotoView()
                }
            }
        }
        .onChange(of: featureSettings) { _, newSettings in
            HomeFeaturePreferences.save(newSettings, to: preferencesDefaults)
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var visibleFeatureSettings: [HomeFeatureSetting] {
        featureSettings.filter(\.isVisible)
    }
}

enum DevKitFeature: String, CaseIterable, Codable, Hashable, Identifiable {
    case simulatorManagement
    case imageOverlay
    case appStoreRelease
    case tinyPNG
    case lubanCompression
    case webPConversion
    case mediaCompression
    case watermarkRemoval
    case idPhoto

    var id: Self { self }

    var title: String {
        switch self {
        case .simulatorManagement:
            "iOS 模拟器管理"
        case .imageOverlay:
            "图片叠加"
        case .appStoreRelease:
            "iOS App 发版"
        case .tinyPNG:
            "TinyPNG 图片压缩"
        case .lubanCompression:
            "Luban 图片压缩"
        case .webPConversion:
            "WebP 图片转换"
        case .mediaCompression:
            "媒体压缩"
        case .watermarkRemoval:
            "去除图片水印"
        case .idPhoto:
            "制作证件照"
        }
    }

    var caption: String {
        switch self {
        case .simulatorManagement:
            "启动、管理与清理模拟器"
        case .imageOverlay:
            "叠加对比两张截图"
        case .appStoreRelease:
            "上传构建并提交审核"
        case .tinyPNG:
            "压缩 PNG 与 JPEG"
        case .lubanCompression:
            "微信策略本地压缩"
        case .webPConversion:
            "图片转为 WebP 格式"
        case .mediaCompression:
            "压缩视频与动图"
        case .watermarkRemoval:
            "智能识别并去除水印"
        case .idPhoto:
            "换底色生成证件照"
        }
    }

    var systemImage: String {
        switch self {
        case .simulatorManagement:
            "iphone.gen3"
        case .imageOverlay:
            "square.stack.3d.up"
        case .appStoreRelease:
            "shippingbox.and.arrow.backward"
        case .tinyPNG:
            "arrow.down.circle"
        case .lubanCompression:
            "wand.and.rays"
        case .webPConversion:
            "photo.badge.arrow.down"
        case .mediaCompression:
            "rectangle.compress.vertical"
        case .watermarkRemoval:
            "eraser"
        case .idPhoto:
            "person.crop.rectangle"
        }
    }
}

struct HomeFeatureSetting: Codable, Equatable, Identifiable {
    let feature: DevKitFeature
    var isVisible: Bool

    var id: DevKitFeature { feature }
}

enum HomeFeaturePreferences {
    static let storageKey = "homeFeatureSettings.v1"

    static var defaultSettings: [HomeFeatureSetting] {
        DevKitFeature.allCases.map {
            HomeFeatureSetting(feature: $0, isVisible: $0 != .watermarkRemoval)
        }
    }

    static func load(from defaults: UserDefaults) -> [HomeFeatureSetting] {
        guard let data = defaults.data(forKey: storageKey),
              let savedSettings = try? JSONDecoder().decode(
                  [HomeFeatureSetting].self,
                  from: data
              ) else {
            return defaultSettings
        }
        return normalized(savedSettings)
    }

    static func save(_ settings: [HomeFeatureSetting], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(normalized(settings)) else { return }
        defaults.set(data, forKey: storageKey)
    }

    static func normalized(_ settings: [HomeFeatureSetting]) -> [HomeFeatureSetting] {
        var normalizedSettings: [HomeFeatureSetting] = []
        var includedFeatures = Set<DevKitFeature>()

        for setting in settings where includedFeatures.insert(setting.feature).inserted {
            normalizedSettings.append(setting)
        }
        for feature in DevKitFeature.allCases where includedFeatures.insert(feature).inserted {
            normalizedSettings.append(
                HomeFeatureSetting(
                    feature: feature,
                    isVisible: feature != .watermarkRemoval
                )
            )
        }
        return normalizedSettings
    }

    static func moving(
        _ source: DevKitFeature,
        to target: DevKitFeature,
        in settings: [HomeFeatureSetting]
    ) -> [HomeFeatureSetting] {
        guard source != target,
              let sourceIndex = settings.firstIndex(where: { $0.feature == source }),
              let targetIndex = settings.firstIndex(where: { $0.feature == target }) else {
            return settings
        }

        var reorderedSettings = settings
        let movedSetting = reorderedSettings.remove(at: sourceIndex)
        reorderedSettings.insert(movedSetting, at: targetIndex)
        return reorderedSettings
    }
}

private struct HomeFeatureSettingsView: View {
    @Binding var featureSettings: [HomeFeatureSetting]

    var body: some View {
        List {
            ForEach($featureSettings) { $setting in
                HStack(spacing: 12) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)

                    Label(setting.feature.title, systemImage: setting.feature.systemImage)

                    Spacer()

                    Toggle("在首页显示", isOn: $setting.isVisible)
                        .labelsHidden()
                        .help(setting.isVisible ? "从首页隐藏" : "在首页显示")
                }
                .padding(.vertical, 4)
                .draggable(setting.feature.rawValue)
                .dropDestination(for: String.self) { sources, _ in
                    guard let rawSource = sources.first,
                          let source = DevKitFeature(rawValue: rawSource) else {
                        return false
                    }
                    withAnimation {
                        featureSettings = HomeFeaturePreferences.moving(
                            source,
                            to: setting.feature,
                            in: featureSettings
                        )
                    }
                    return true
                }
            }
        }
        .navigationTitle("首页设置")
    }
}

private struct HomeDisplaySection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.85))

                VStack(alignment: .leading, spacing: 4) {
                    Text("DevKit")
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text("开发者工具箱")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 28)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text("展示区")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("预留固定位置，用于展示与功能无关的内容")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct FeatureLink: View {
    let feature: DevKitFeature

    var body: some View {
        NavigationLink(value: feature) {
            HStack(spacing: 14) {
                Image(systemName: feature.systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(feature.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(feature.caption)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
}
