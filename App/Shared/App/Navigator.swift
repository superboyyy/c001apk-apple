import CoolapkKit
import Observation
import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case home, hot, following, topics, products, coolpic, search, notifications, messages, localFollow, favorites, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "头条"
        case .hot: return "热榜"
        case .following: return "关注"
        case .topics: return "话题"
        case .products: return "数码"
        case .coolpic: return "酷图"
        case .search: return "搜索"
        case .notifications: return "通知"
        case .messages: return "私信"
        case .localFollow: return "悄悄关注"
        case .favorites: return "收藏"
        case .history: return "浏览历史"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "newspaper"
        case .hot: return "flame"
        case .following: return "person.2"
        case .topics: return "number"
        case .products: return "iphone"
        case .coolpic: return "photo.on.rectangle.angled"
        case .search: return "magnifyingglass"
        case .notifications: return "bell"
        case .messages: return "envelope"
        case .localFollow: return "eye"
        case .favorites: return "star"
        case .history: return "clock.arrow.circlepath"
        }
    }

    var requiresLogin: Bool { self == .following || self == .notifications || self == .messages }
}

/// 管理侧边栏选中项，并为每个侧边栏项维护一个导航栈。
@MainActor
@Observable
final class Navigator {
    var selection: SidebarItem = .home
    var paths: [SidebarItem: [NavigationEntry]] = [:]
    #if !os(macOS)
    /// iPadOS 每个侧边栏页签各自维护一个 `NavigationPath`，支持区分缩放与普通目的地类型。
    var navigationPaths: [SidebarItem: NavigationPath] = [:]

    var currentNavigationPath: NavigationPath {
        get { navigationPaths[selection] ?? NavigationPath() }
        set {
            navigationPaths[selection] = newValue
            // 用户侧滑或点返回按钮弹栈时，同步裁剪 `paths[selection]` 保持一致。
            var list = paths[selection] ?? []
            if newValue.count < list.count {
                list.removeLast(list.count - newValue.count)
                paths[selection] = list
            }
        }
    }
    #endif
    /// 由工具栏搜索框或菜单命令设置。
    var pendingSearch: String?
    /// 详情区域在窗口坐标系里的矩形，供详情页与瀑布流首帧初始化布局宽度。
    @ObservationIgnored var detailFrame: CGRect = .zero

    var currentEntries: [NavigationEntry] {
        get { paths[selection] ?? [] }
        set { paths[selection] = newValue }
    }

    /// 兼容调用方读取当前路由列表。
    var currentPath: [Route] {
        currentEntries.map(\.route)
    }

    func entries(for item: SidebarItem) -> [NavigationEntry] {
        paths[item] ?? []
    }

    func select(_ item: SidebarItem) {
        guard selection != item else { return }
        selection = item
    }

    func push(_ route: Route, zoomID: String? = nil) {
        #if !os(macOS)
        // 若系统弹栈与镜像数组短暂不同步，先按真实 NavigationPath 长度对齐，避免误判“已在栈顶”而点不开。
        let activeCount = navigationPaths[selection]?.count ?? 0
        if var list = paths[selection], list.count > activeCount {
            list.removeLast(list.count - activeCount)
            paths[selection] = list
        }
        #endif
        if currentEntries.last?.route == route { return }
        let normalizedZoomID = zoomID.flatMap { $0.isEmpty ? nil : $0 }
        let entry = NavigationEntry(route: route, zoomID: normalizedZoomID)
        currentEntries.append(entry)
        #if !os(macOS)
        var path = navigationPaths[selection] ?? NavigationPath()
        if let normalizedZoomID {
            path.append(ZoomedNavigationEntry(id: entry.id, route: route, zoomID: normalizedZoomID))
        } else {
            path.append(PlainNavigationEntry(id: entry.id, route: route))
        }
        navigationPaths[selection] = path
        #endif
    }

    /// 文字链接位于可点击的卡片内。点链接不能同时打开卡片，
    /// 所以卡片点击会推迟一拍，紧跟在链接点击之后的则忽略。
    @ObservationIgnored private var lastLinkActivation = Date.distantPast
    /// 同一轮点击同时命中正文并发手势与外层卡片（或嵌套引用卡片）时，只响应最内层的一次。
    @ObservationIgnored private var lastCardActivation = Date.distantPast

    func noteLinkActivated() { lastLinkActivation = Date() }

    private static var cardActivationDelay: TimeInterval {
        #if os(macOS)
        // macOS 上链接点击会在同一轮或下一拍立刻触发 openURL，16ms 既可可靠避让又无拖滞感。
        0.016
        #else
        0.04
        #endif
    }

    func openCard(_ route: Route, zoomID: String? = nil) {
        let now = Date()
        guard now.timeIntervalSince(lastCardActivation) > 0.08 else { return }
        lastCardActivation = now
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cardActivationDelay) { [self] in
            guard Date().timeIntervalSince(lastLinkActivation) > 0.35 else { return }
            push(route, zoomID: zoomID)
        }
    }

    func openCardLink(_ link: String, title: String? = nil, app: AppModel, zoomID: String? = nil) {
        let now = Date()
        guard now.timeIntervalSince(lastCardActivation) > 0.08 else { return }
        lastCardActivation = now
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cardActivationDelay) { [self] in
            guard Date().timeIntervalSince(lastLinkActivation) > 0.35 else { return }
            open(link, title: title, app: app, zoomID: zoomID)
        }
    }

    func pop() {
        guard !currentEntries.isEmpty else { return }
        currentEntries.removeLast()
        #if !os(macOS)
        if var path = navigationPaths[selection], !path.isEmpty {
            path.removeLast()
            navigationPaths[selection] = path
        }
        #endif
    }

    func popToRoot() {
        guard !currentEntries.isEmpty else { return }
        currentEntries.removeAll()
        #if !os(macOS)
        navigationPaths[selection] = NavigationPath()
        #endif
    }

    /// 按链接类型打开酷安链接：应用内页面、图片查看器或浏览器。
    func open(_ link: String, title: String? = nil, app: AppModel, zoomID: String? = nil) {
        switch LinkRouter.resolve(link, title: title) {
        case .route(let route):
            push(route, zoomID: zoomID)
        case .image(let url):
            ImageViewer.show(urls: [url], index: 0)
        case .external(let url):
            Platform.open(url)
        case .unsupported:
            app.showToast("暂不支持此链接")
        }
    }

    func search(_ keyword: String) {
        select(.search)
        popToRoot()
        pendingSearch = keyword
    }
}
