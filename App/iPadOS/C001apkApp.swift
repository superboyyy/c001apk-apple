import SwiftUI

/// iPadOS 应用入口。
@main
struct C001apkApp: App {
    @State private var app = AppModel()
    @State private var navigator = Navigator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(navigator)
        }
        .commands { AppCommands(navigator: navigator) }
    }
}
