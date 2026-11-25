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
    var paths: [SidebarItem: [Route]] = [:]
    /// 由工具栏搜索框或菜单命令设置。
    var pendingSearch: String?

    var currentPath: [Route] {
        get { paths[selection] ?? [] }
        set { paths[selection] = newValue }
    }

    func push(_ route: Route) {
        if currentPath.last == route { return }
        currentPath.append(route)
    }

    /// 文字链接位于可点击的卡片内。点链接不能同时打开卡片，
    /// 所以卡片点击会推迟一拍，紧跟在链接点击之后的则忽略。
    @ObservationIgnored private var lastLinkActivation = Date.distantPast

    func noteLinkActivated() { lastLinkActivation = Date() }

    func openCard(_ route: Route) {
        DispatchQueue.main.async { [self] in
            guard Date().timeIntervalSince(lastLinkActivation) > 0.35 else { return }
            push(route)
        }
    }

    func openCardLink(_ link: String, title: String? = nil, app: AppModel) {
        DispatchQueue.main.async { [self] in
            guard Date().timeIntervalSince(lastLinkActivation) > 0.35 else { return }
            open(link, title: title, app: app)
        }
    }

    func pop() {
        if !currentPath.isEmpty { currentPath.removeLast() }
    }

    func popToRoot() { currentPath.removeAll() }

    /// 按链接类型打开酷安链接：应用内页面、图片查看器或浏览器。
    func open(_ link: String, title: String? = nil, app: AppModel) {
        switch LinkRouter.resolve(link, title: title) {
        case .route(let route):
            push(route)
        case .image(let url):
            ImageViewer.show(urls: [url], index: 0)
        case .external(let url):
            Platform.open(url)
        case .unsupported:
            app.showToast("暂不支持此链接")
        }
    }

    func search(_ keyword: String) {
        selection = .search
        popToRoot()
        pendingSearch = keyword
    }
}
