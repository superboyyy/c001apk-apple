import SwiftUI

#if os(macOS)
import AppKit
#endif

/// 导航栈里的一层页面，携带唯一身份与动画起点信息。
struct NavigationEntry: Identifiable, Hashable {
    let id: UUID
    let route: Route
    /// macOS 卡片点击在详情容器内的归一化锚点；为空时走横向滑入缩放过渡。
    let origin: UnitPoint?
    /// iPadOS 原生 zoom 过渡对应的卡片标识；为空时走系统默认推入过渡。
    let zoomID: String?

    init(id: UUID = UUID(), route: Route, origin: UnitPoint? = nil, zoomID: String? = nil) {
        self.id = id
        self.route = route
        self.origin = origin
        self.zoomID = zoomID
    }
}

#if !os(macOS)
/// iPadOS 带原生缩放过渡的导航目的地：单独注册 `.navigationDestination`，
/// 避免在同一个目标闭包内用 `if/else` 切换 `.navigationTransition` 导致缩放过渡失效。
struct ZoomedNavigationEntry: Identifiable, Hashable {
    let id: UUID
    let route: Route
    let zoomID: String
}

/// iPadOS 普通推入过渡的导航目的地（文字链接、菜单项等无来源卡片的跳转）。
struct PlainNavigationEntry: Identifiable, Hashable {
    let id: UUID
    let route: Route
}
#endif

/// 页面打开 / 关闭与切换使用的统一动画曲线。
enum RouteMotion {
    static let open: Animation = .spring(response: 0.34, dampingFraction: 0.88)
    static let close: Animation = .spring(response: 0.30, dampingFraction: 0.90)
    static let tab: Animation = .smooth(duration: 0.22)
    static let reduced: Animation = .easeInOut(duration: 0.16)
}

/// 标记页面当前是否处于导航栈最顶层（非顶层页面保留状态但不贡献工具栏项）。
extension EnvironmentValues {
    @Entry var isActiveRoute: Bool = true
    @Entry var zoomNamespace: Namespace.ID? = nil
}

/// macOS 导航栈内部由各页面上报标题，避免多层页面同时调用 `.navigationTitle` 冲突。
struct RouteTitlePreferenceKey: PreferenceKey {
    static var defaultValue: String? = nil

    static func reduce(value: inout String?, nextValue: () -> String?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    /// 设置页面标题：iPadOS 直接走系统 `.navigationTitle`，macOS 上报给自定义动画栈统一显示。
    @ViewBuilder
    func routeTitle(_ title: String) -> some View {
        #if os(macOS)
        preference(key: RouteTitlePreferenceKey.self, value: title)
        #else
        navigationTitle(title)
        #endif
    }

    /// 标记卡片为 iPadOS 原生缩放过渡源；macOS 或无标识时无开销直通。
    @ViewBuilder
    func zoomTransitionSource(id: String?, cornerRadius: CGFloat = 18) -> some View {
        #if os(macOS)
        self
        #else
        if let id, !id.isEmpty {
            modifier(ZoomSourceModifier(id: id, cornerRadius: cornerRadius))
        } else {
            self
        }
        #endif
    }
}

#if !os(macOS)
private struct ZoomSourceModifier: ViewModifier {
    let id: String
    let cornerRadius: CGFloat
    @Environment(\.zoomNamespace) private var namespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace) { config in
                config.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        } else {
            content
        }
    }
}
#endif

/// 在点击瞬间捕获指针在详情区域里的归一化坐标，零滚动开销。
enum ClickOrigin {
    @MainActor
    static func current(in detailFrame: CGRect) -> UnitPoint? {
        #if os(macOS)
        guard detailFrame.width > 1, detailFrame.height > 1,
              let event = NSApp.currentEvent,
              [.leftMouseDown, .leftMouseUp].contains(event.type),
              let window = event.window ?? NSApp.keyWindow,
              let contentView = window.contentView
        else { return nil }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = contentView.convert(pointInWindow, from: nil)
        let x = local.x
        let y = contentView.isFlipped ? local.y : (contentView.bounds.height - local.y)
        // NavigationSplitView 在 macOS 下可能为详情栏分配独立托管视图，此时 `detailFrame.minX` 为 0；
        // 详情栏始终贴着窗口右侧与底部，用窗口尺寸反推其真实起点可同时兼容两种坐标基准。
        let minX = detailFrame.minX > 1 ? detailFrame.minX : max(contentView.bounds.width - detailFrame.width, 0)
        let minY = detailFrame.minY > 1 ? detailFrame.minY : max(contentView.bounds.height - detailFrame.height, 0)
        let resolvedDetail = CGRect(x: minX, y: minY, width: detailFrame.width, height: detailFrame.height)
        guard resolvedDetail.contains(CGPoint(x: x, y: y)) else { return nil }
        let nx = min(max((x - resolvedDetail.minX) / resolvedDetail.width, 0.14), 0.86)
        let ny = min(max((y - resolvedDetail.minY) / resolvedDetail.height, 0.14), 0.86)
        return UnitPoint(x: nx, y: ny)
        #else
        return nil
        #endif
    }
}

#if os(macOS)
/// 帖子 / 板块打开与关闭的 GPU 合成过渡：有点击锚点时从卡片区域绽放/收起，否则柔和滑入/滑出。
private struct PageRevealTransition: Transition {
    let origin: UnitPoint?
    let reduceMotion: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        if reduceMotion {
            content.opacity(phase.isIdentity ? 1 : 0)
        } else if let origin {
            let hidden = !phase.isIdentity
            content
                .scaleEffect(hidden ? 0.93 : 1, anchor: origin)
                .offset(y: hidden ? 10 : 0)
                .opacity(hidden ? 0 : 1)
        } else {
            let offsetX: CGFloat = switch phase {
            case .willAppear: 38
            case .identity: 0
            case .didDisappear: 44
            }
            content
                .scaleEffect(phase.isIdentity ? 1 : 0.985, anchor: .center)
                .offset(x: offsetX)
                .opacity(phase.isIdentity ? 1 : 0)
        }
    }
}

/// macOS 专用带丝滑打开/关闭过渡的导航栈：
/// - 下层页面保持挂载并保留滚动位置与 `@State`，只用 GPU 合成属性退隐，不触发瀑布流重排；
/// - 非顶层页面关闭交互与工具栏项，避免按钮重复或快捷键误触；
/// - 顶层页面上报的标题统一应用到窗口标题栏。
struct AnimatedNavigationStack<Root: View, Destination: View>: View {
    let tab: SidebarItem
    let navigator: Navigator
    @ViewBuilder let root: (SidebarItem) -> Root
    @ViewBuilder let destination: (NavigationEntry) -> Destination

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var titles: [AnyHashable: String] = [:]

    private var activeEntries: [NavigationEntry] { navigator.entries(for: tab) }

    private var activeTitle: String {
        if let top = activeEntries.last {
            return titles[AnyHashable(top.id)] ?? tab.title
        }
        return titles[AnyHashable(tab)] ?? tab.title
    }

    var body: some View {
        ZStack {
            tabLayer(for: tab)
                .id(tab)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            navigator.detailFrame = frame
        }
        .navigationTitle(activeTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    navigator.pop()
                } label: {
                    Label("返回", systemImage: "chevron.backward")
                }
                .disabled(activeEntries.isEmpty)
                .help("返回（⌘[）")
            }
        }
        .onChange(of: activeEntries.count) { _, _ in
            if titles.count > 48 {
                let kept = Set(activeEntries.map { AnyHashable($0.id) } + [AnyHashable(tab)])
                titles = titles.filter { kept.contains($0.key) }
            }
        }
    }

    private func tabLayer(for currentTab: SidebarItem) -> some View {
        let entries = navigator.entries(for: currentTab)
        let isTabSelected = currentTab == tab
        let topOrigin = entries.last?.origin
        return ZStack {
            let rootVisualTop = entries.isEmpty
            let rootActive = isTabSelected && rootVisualTop
            root(currentTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onPreferenceChange(RouteTitlePreferenceKey.self) { value in
                    if let value { titles[AnyHashable(currentTab)] = value }
                }
                .environment(\.isActiveRoute, rootActive)
                .modifier(StackLayerDepth(isTop: rootVisualTop, isInteractive: rootActive,
                                          topOrigin: topOrigin, reduceMotion: reduceMotion))
                .zIndex(0)

            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let visualTop = index == entries.count - 1
                let active = isTabSelected && visualTop
                destination(entry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onPreferenceChange(RouteTitlePreferenceKey.self) { value in
                        if let value { titles[AnyHashable(entry.id)] = value }
                    }
                    .environment(\.isActiveRoute, active)
                    .modifier(StackLayerDepth(isTop: visualTop, isInteractive: active,
                                              topOrigin: topOrigin, reduceMotion: reduceMotion))
                    .transition(PageRevealTransition(origin: entry.origin, reduceMotion: reduceMotion))
                    .zIndex(Double(index + 1))
            }
        }
        .clipped()
    }
}

/// 导航栈中非顶层页面的退隐效果（纯 GPU 缩放 / 平移 / 透明，不触发布局变化）。
private struct StackLayerDepth: ViewModifier {
    let isTop: Bool
    let isInteractive: Bool
    let topOrigin: UnitPoint?
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let scale: CGFloat = isTop || reduceMotion ? 1 : (topOrigin != nil ? 0.965 : 0.98)
        let offsetX: CGFloat = isTop || reduceMotion || topOrigin != nil ? 0 : -24
        return content
            .scaleEffect(scale, anchor: .center)
            .offset(x: offsetX)
            .opacity(isTop ? 1 : 0)
            .allowsHitTesting(isInteractive)
            .accessibilityHidden(!isInteractive)
    }
}
#endif
