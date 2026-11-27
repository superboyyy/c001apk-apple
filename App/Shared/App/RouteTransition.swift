import Observation
import SwiftUI

/// 导航栈里的一层页面，携带唯一身份与 iPadOS 原生缩放源标识。
struct NavigationEntry: Identifiable, Hashable {
    let id: UUID
    let route: Route
    /// iPadOS 原生 `.navigationTransition(.zoom)` 对应的来源标识。
    let zoomID: String?

    init(id: UUID = UUID(), route: Route, zoomID: String? = nil) {
        self.id = id
        self.route = route
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

/// 页面页签切换使用的统一动画曲线。
enum RouteMotion {
    static let tab: Animation = .smooth(duration: 0.22)
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
    /// 设置页面标题：iPadOS 直接走系统 `.navigationTitle`，macOS 上报给导航栈统一显示。
    @ViewBuilder
    func routeTitle(_ title: String) -> some View {
        #if os(macOS)
        preference(key: RouteTitlePreferenceKey.self, value: title)
        #else
        navigationTitle(title)
        #endif
    }

    /// 标记卡片 / 头像 / 标签为 iPadOS 原生缩放过渡源；macOS 无缩放过渡，零开销直通。
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

#if os(macOS)
/// 隔离窗口标题存储：各页面上报标题时只更新标题栏，不触发整个导航栈视图树重算。
@MainActor
@Observable
private final class RouteTitleStore {
    private(set) var titles: [AnyHashable: String] = [:]

    func set(_ title: String?, for key: AnyHashable) {
        guard let title, titles[key] != title else { return }
        titles[key] = title
    }

    func prune(keeping keys: Set<AnyHashable>) {
        guard titles.count > 48 else { return }
        titles = titles.filter { keys.contains($0.key) }
    }
}

/// 独立绑定窗口标题与返回按钮，避免标题更新牵连导航栈主体。
private struct RouteNavigationChrome: ViewModifier {
    let tab: SidebarItem
    let navigator: Navigator
    let titleStore: RouteTitleStore

    private var activeEntries: [NavigationEntry] { navigator.entries(for: tab) }

    private var activeTitle: String {
        if let top = activeEntries.last {
            return titleStore.titles[AnyHashable(top.id)] ?? tab.title
        }
        return titleStore.titles[AnyHashable(tab)] ?? tab.title
    }

    func body(content: Content) -> some View {
        content
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
    }
}

/// macOS 导航栈：
/// - 无卡片缩放或位移动画，绝不触发 `NSScrollView` 安全区塌缩跳动，也不干扰侧边栏；
/// - 下层页面保持挂载并保留滚动位置与 `@State`，返回瞬间无闪烁、不重建瀑布流；
/// - 顶层页面上报的标题统一应用到窗口标题栏。
struct AnimatedNavigationStack<Root: View, Destination: View>: View {
    let tab: SidebarItem
    let navigator: Navigator
    @ViewBuilder let root: (SidebarItem) -> Root
    @ViewBuilder let destination: (NavigationEntry) -> Destination

    @State private var titleStore = RouteTitleStore()

    private var activeEntries: [NavigationEntry] { navigator.entries(for: tab) }

    var body: some View {
        ZStack {
            tabLayer(for: tab)
                .id(tab)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            navigator.detailFrame = frame
        }
        .modifier(RouteNavigationChrome(tab: tab, navigator: navigator, titleStore: titleStore))
        .onChange(of: activeEntries.map(\.id)) { _, newIDs in
            let kept = Set(newIDs.map { AnyHashable($0) } + [AnyHashable(tab)])
            titleStore.prune(keeping: kept)
        }
    }

    private func tabLayer(for currentTab: SidebarItem) -> some View {
        let entries = navigator.entries(for: currentTab)
        let isTabSelected = currentTab == tab
        let rootIsTop = entries.isEmpty
        let rootActive = isTabSelected && rootIsTop

        return ZStack {
            root(currentTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onPreferenceChange(RouteTitlePreferenceKey.self) { value in
                    titleStore.set(value, for: AnyHashable(currentTab))
                }
                .environment(\.isActiveRoute, rootActive)
                .opacity(rootIsTop ? 1 : 0)
                .allowsHitTesting(rootActive)
                .accessibilityHidden(!rootActive)
                .zIndex(0)

            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let isTop = index == entries.count - 1
                let active = isTabSelected && isTop
                destination(entry)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onPreferenceChange(RouteTitlePreferenceKey.self) { value in
                        titleStore.set(value, for: AnyHashable(entry.id))
                    }
                    .environment(\.isActiveRoute, active)
                    .opacity(isTop ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                    .zIndex(Double(index + 1))
            }
        }
    }
}
#endif
