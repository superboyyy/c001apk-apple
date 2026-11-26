import SwiftUI

#if os(macOS)
import AppKit
/// 平台图片类型：macOS 为 NSImage，iPadOS 为 UIImage。
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension Image {
    /// 用平台图片创建 SwiftUI 图片。
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// 跨平台的系统能力封装，界面代码统一走这里，不直接调用 AppKit / UIKit。
enum Platform {
    /// 用系统默认浏览器打开链接。
    @MainActor
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// 把文本写入剪贴板。
    static func copy(_ text: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// 仅在用户主动点击粘贴操作时读取剪贴板纯文本。
    static func pasteText() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }
}

extension Color {
    /// 窗口底色。
    static var windowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

extension View {
    /// iPadOS：隐藏导航栏自带的底色，让玻璃控件直接浮在内容上。
    /// macOS 保持系统默认：内容滚到工具栏后面时由系统做渐隐模糊。
    func hidesBarBackground() -> some View {
        #if os(macOS)
        self
        #else
        toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        #endif
    }

    /// 给整个窗口铺一层背景（延伸到标题栏和侧边栏之下）。
    /// 不用 `containerBackground(for: .window)`：它会让 macOS 工具栏在滚动时
    /// 换成不透明的旧式底色，系统的渐隐模糊就没有了。
    func windowBackdrop<Background: View>(@ViewBuilder _ content: () -> Background) -> some View {
        background { content().ignoresSafeArea() }
    }

    /// iPadOS 上把导航标题收进导航栏（不使用大标题）。
    func inlineNavigationTitle() -> some View {
        #if os(macOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// 悬停时显示左右调整宽度的指针（仅 macOS）。
    func columnResizePointer() -> some View {
        #if os(macOS)
        pointerStyle(.columnResize)
        #else
        self
        #endif
    }
}
