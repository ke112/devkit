import SwiftUI

@main
struct DevKitApp: App {
    var body: some Scene {
        Window("DevKit", id: "main") {
            ContentView()
        }
        .defaultSize(width: 960, height: 680)
        .windowResizability(.contentMinSize)
    }
}
