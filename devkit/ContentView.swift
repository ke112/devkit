import Foundation
import SwiftUI

struct ContentView: View {
    private let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20),
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
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(visibleFeatureSettings) { setting in
                            FeatureLink(feature: setting.feature)
                        }
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                case .webPConversion:
                    WebPConversionView()
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
    case webPConversion

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
        case .webPConversion:
            "WebP 图片转换"
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
        case .webPConversion:
            "photo.badge.arrow.down"
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
            HomeFeatureSetting(feature: $0, isVisible: true)
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
            normalizedSettings.append(HomeFeatureSetting(feature: feature, isVisible: true))
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

private struct FeatureLink: View {
    let feature: DevKitFeature

    var body: some View {
        NavigationLink(value: feature) {
            VStack(spacing: 18) {
                Image(systemName: feature.systemImage)
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 64, height: 64)

                Text(feature.title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
}
