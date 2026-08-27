import SwiftUI

@main
struct DevKitApp: App {
    var body: some Scene {
        Window("DevKit", id: "main") {
            ContentView()
                .task { DependencyBootstrap.start() }
        }
        .defaultSize(width: 960, height: 900)
        .windowResizability(.contentMinSize)
    }
}
