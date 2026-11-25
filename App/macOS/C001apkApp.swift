import SwiftUI

@main
struct C001apkApp: App {
    @State private var app = AppModel()
    @State private var navigator = Navigator()

    var body: some Scene {
        Window("酷果", id: "main") {
            RootView()
                .environment(app)
                .environment(navigator)
        }
        .defaultSize(width: 1180, height: 780)
        .commands { AppCommands(navigator: navigator) }

        Settings {
            SettingsView()
                .environment(app)
                .environment(navigator)
                .preferredColorScheme(app.settings.appearance.colorScheme)
        }
    }
}
