import SwiftUI

/// 菜单栏与键盘快捷键：返回、搜索、切换侧边栏页面。
struct AppCommands: Commands {
    let navigator: Navigator

    private static let shortcuts: [SidebarItem] = [
        .home, .hot, .following, .topics, .products, .coolpic, .notifications, .messages, .favorites,
    ]

    var body: some Commands {
        SidebarCommands()
        CommandMenu("导航") {
            Button("返回") { navigator.pop() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(navigator.currentPath.isEmpty)
            Button("回到列表") { navigator.popToRoot() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(navigator.currentPath.isEmpty)
            Divider()
            Button("搜索") { navigator.select(.search) }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            ForEach(Array(Self.shortcuts.enumerated()), id: \.element) { index, item in
                Button(item.title) { navigator.select(item) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }
}
