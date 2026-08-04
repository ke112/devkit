import SwiftUI

struct ContentView: View {
    private let columns = [
        GridItem(.flexible(), spacing: 20),
        GridItem(.flexible(), spacing: 20),
    ]

    var body: some View {
        NavigationStack {
            LazyVGrid(columns: columns, spacing: 20) {
                FeatureLink(
                    feature: .simulatorManagement,
                    title: "iOS 模拟器管理",
                    systemImage: "iphone.gen3"
                )

                FeatureLink(
                    feature: .imageOverlay,
                    title: "图片叠加",
                    systemImage: "square.stack.3d.up"
                )
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .navigationTitle("DevKit")
            .toolbar {
                // Keep the root toolbar expanded to match pushed destinations.
                ToolbarItem {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
            }
            .navigationDestination(for: DevKitFeature.self) { feature in
                switch feature {
                case .simulatorManagement:
                    SimulatorManagementView()
                case .imageOverlay:
                    ImageOverlayView()
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

private enum DevKitFeature: Hashable {
    case simulatorManagement
    case imageOverlay
}

private struct FeatureLink: View {
    let feature: DevKitFeature
    let title: String
    let systemImage: String

    var body: some View {
        NavigationLink(value: feature) {
            VStack(spacing: 18) {
                Image(systemName: systemImage)
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 64, height: 64)

                Text(title)
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
