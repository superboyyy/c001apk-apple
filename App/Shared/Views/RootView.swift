import CoolapkKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #else
    @Namespace private var zoomNamespace
    #endif

    private func showSettings() {
        #if os(macOS)
        openSettings()
        #else
        app.isShowingSettings = true
        #endif
    }
    /// 侧边栏上次是否收起，下次启动时沿用。
    @AppStorage(Self.sidebarCollapsedKey) private var sidebarCollapsed = false
    @State private var columnVisibility: NavigationSplitViewVisibility =
        UserDefaults.standard.bool(forKey: RootView.sidebarCollapsedKey) ? .detailOnly : .all

    private static let sidebarCollapsedKey = "sidebarCollapsed"

    private var isRailVisible: Bool { columnVisibility == .detailOnly }
    private var railInset: CGFloat { isRailVisible ? SidebarRail.width : 0 }

    /// 深链接：
    /// - `coolmarket://…`：酷安内容链接
    /// - `c001apk://hot`、`c001apk://topics` 等：侧边栏页面
    /// - `c001apk://search?q=…`、`c001apk://open?u=<link>`、`c001apk://login`、`c001apk://settings`
    private func handle(_ url: URL) {
        guard url.scheme == "c001apk" else {
            navigator.open(url.absoluteString, app: app)
            return
        }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        switch url.host ?? "" {
        case "search":
            if let query = value("q"), !query.isEmpty { navigator.search(query) } else { navigator.select(.search) }
        case "open":
            if let link = value("u"), !link.isEmpty {
                navigator.noteLinkActivated()
                navigator.open(link, app: app)
            }
        case "login":
            app.isShowingLogin = true
        case "settings":
            showSettings()
        default:
            // URL 的主机名会被转成小写，按不区分大小写匹配。
            let host = (url.host ?? "").lowercased()
            if let item = SidebarItem.allCases.first(where: { $0.rawValue.lowercased() == host }) {
                navigator.select(item)
            }
        }
    }

    var body: some View {
        @Bindable var app = app
        @Bindable var navigator = navigator
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            #if os(macOS)
            AnimatedNavigationStack(tab: navigator.selection, navigator: navigator) { item in
                SidebarRootView(item: item)
                    .safeAreaPadding(.leading, railInset)
                    .hidesBarBackground()
                    .inlineNavigationTitle()
            } destination: { entry in
                RouteView(route: entry.route)
                    .safeAreaPadding(.leading, railInset)
                    .inlineNavigationTitle()
                    .hidesBarBackground()
            }
            #else
            NavigationStack(path: $navigator.currentNavigationPath) {
                SidebarRootView(item: navigator.selection)
                    .navigationTitle(navigator.selection.title)
                    .safeAreaPadding(.leading, railInset)
                    .hidesBarBackground()
                    .inlineNavigationTitle()
                    .navigationDestination(for: ZoomedNavigationEntry.self) { entry in
                        RouteView(route: entry.route)
                            .safeAreaPadding(.leading, railInset)
                            .inlineNavigationTitle()
                            .hidesBarBackground()
                            .environment(\.zoomNamespace, zoomNamespace)
                            .navigationTransition(.zoom(sourceID: entry.zoomID, in: zoomNamespace))
                    }
                    .navigationDestination(for: PlainNavigationEntry.self) { entry in
                        RouteView(route: entry.route)
                            .safeAreaPadding(.leading, railInset)
                            .inlineNavigationTitle()
                            .hidesBarBackground()
                            .environment(\.zoomNamespace, zoomNamespace)
                    }
            }
            .environment(\.zoomNamespace, zoomNamespace)
            #endif
        }
        // 整个窗口共用一层背景，作为窗口自身的背景绘制，
        // 这样总能延伸到标题栏和每个页面之下。
        .windowBackdrop { AppBackdrop() }
        .onChange(of: columnVisibility) { _, visibility in
            sidebarCollapsed = visibility == .detailOnly
        }
        // 侧边栏隐藏时，用悬浮的图标栏保证每个页面仍一键可达。
        // 它位于分栏视图之上，推入的页面也能看到；页面通过左侧安全区给它让位。
        .overlay(alignment: .topLeading) {
            // 动画只加在图标栏上：加在整个分栏视图上会让所有页面跟着逐帧重排。
            ZStack(alignment: .topLeading) {
                if isRailVisible {
                    SidebarRail()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.smooth(duration: 0.25), value: isRailVisible)
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                ToastView(toast: toast).id(toast.id)
            }
        }
        .animation(.smooth(duration: 0.25), value: app.toast)
        // 发布 / 回复编辑器浮在整个窗口之上（不能用 sheet，否则会挡住登录和人机验证）。
        .composer($app.composeTarget) { _, created in
            app.composeCompletion?(created)
            app.composeCompletion = nil
        }
        .task { await app.contentFilter.checkForUpdates() }
        .sheet(item: $app.captcha) { request in
            CaptchaSheet(request: request)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $app.isShowingLogin) {
            LoginSheet()
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let href = RichText.href(from: url) else { return .systemAction }
            navigator.noteLinkActivated()
            navigator.open(href, app: app)
            return .handled
        })
        .onOpenURL { url in handle(url) }
        .preferredColorScheme(app.settings.appearance.colorScheme)
        #if os(macOS)
        .frame(minWidth: 760, minHeight: 520)
        #else
        .sheet(isPresented: $app.isShowingSettings) {
            SettingsView()
        }
        #endif
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        let selection = Binding<SidebarItem?>(
            get: { navigator.selection },
            set: { if let value = $0 { navigator.select(value) } })
        List(selection: selection) {
            Section("浏览") {
                row(.home)
                row(.hot)
                row(.following)
                row(.topics)
                row(.products)
                row(.coolpic)
            }
            Section("发现") {
                row(.search)
                row(.notifications)
                row(.messages)
            }
            Section("本机") {
                row(.localFollow)
                row(.favorites)
                row(.history)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { AccountBar() }
        .navigationTitle("酷果")
        #if !os(macOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    app.isShowingSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
            }
        }
        #endif
    }

    private func row(_ item: SidebarItem) -> some View {
        Label(item.title, systemImage: item.symbol)
            .tag(item)
            .opacity(item.requiresLogin && !app.isLoggedIn ? 0.55 : 1)
    }
}

/// 侧边栏收起时显示的纯图标导航。
private struct SidebarRail: View {
    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    /// 图标栏显示时，页面在左侧预留的空间。
    static let width: CGFloat = 60

    /// 顶部留白：iPadOS 的导航栏在内容区内，要让出“展开边栏”等按钮的位置。
    private static var topInset: CGFloat {
        #if os(macOS)
        10
        #else
        62
        #endif
    }

    private static let groups: [[SidebarItem]] = [
        [.home, .hot, .following, .topics, .products, .coolpic],
        [.search, .notifications, .messages],
        [.localFollow, .favorites, .history],
    ]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Divider().frame(width: 22).padding(.vertical, 3)
                }
                ForEach(group) { item in
                    button(item)
                }
            }
            Spacer(minLength: 8)
            Button {
                if let account = app.account {
                    navigator.push(.user(account.uid))
                } else {
                    app.isShowingLogin = true
                }
            } label: {
                Group {
                    if let account = app.account {
                        AvatarView(url: account.avatar, size: 26)
                    } else {
                        Image(systemName: "person.crop.circle").font(.system(size: 17))
                    }
                }
                .frame(width: 38, height: 38)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(app.account.map { "\($0.displayName) 的主页" } ?? "登录酷安")
            .accessibilityLabel(app.account.map { "\($0.displayName) 的主页" } ?? "登录酷安")
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: 25, style: .continuous))
        .padding(.leading, 10)
        .padding(.trailing, 0)
        .padding(.top, Self.topInset)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func button(_ item: SidebarItem) -> some View {
        let isSelected = navigator.selection == item
        return Button {
            if isSelected { navigator.popToRoot() } else { navigator.select(item) }
        } label: {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 38, height: 38)
                .background {
                    if isSelected { Circle().fill(Color.brandFill) }
                }
                .contentShape(Circle())
                .opacity(item.requiresLogin && !app.isLoggedIn && !isSelected ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .help(item.title)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 菜单里的“设置”入口：macOS 打开设置窗口，iPadOS 弹出设置页。
private struct SettingsEntry: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        #if os(macOS)
        SettingsLink { Text("设置…") }
        #else
        Button("设置…") { app.isShowingSettings = true }
        #endif
    }
}

private struct AccountBar: View {
    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator
    @State private var confirmsSignOut = false

    var body: some View {
        Group {
            if let account = app.account {
                Menu {
                    Button("我的主页") { navigator.push(.user(account.uid)) }
                    Divider()
                    // 多账号：点选即切换。
                    ForEach(app.accounts) { item in
                        Button {
                            app.switchAccount(to: item.uid)
                        } label: {
                            if item.uid == account.uid {
                                Label(item.displayName, systemImage: "checkmark")
                            } else {
                                Text(item.displayName)
                            }
                        }
                    }
                    Button("添加账号…") { app.isShowingLogin = true }
                    Divider()
                    SettingsEntry()
                    Button("退出当前账号…", role: .destructive) { confirmsSignOut = true }
                } label: {
                    HStack(spacing: 8) {
                        AvatarView(url: account.avatar, size: 24)
                        Text(account.displayName).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
            } else {
                Button {
                    app.isShowingLogin = true
                } label: {
                    Label("登录酷安", systemImage: "person.crop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .confirmationDialog("退出当前账号？", isPresented: $confirmsSignOut) {
            Button("退出登录", role: .destructive) { app.signOut() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("本机收藏、历史和设置会保留。")
        }
    }
}

/// 每个侧边栏项的首页。
private struct SidebarRootView: View {
    let item: SidebarItem

    @Environment(AppModel.self) private var app
    @Environment(\.isActiveRoute) private var isActiveRoute

    var body: some View {
        switch item {
        case .home:
            EntityListView(model: homeModel)
                .toolbar {
                    if isActiveRoute {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                app.compose(.feed()) { _ in app.showToast("已发布") }
                            } label: {
                                Label("发布动态", systemImage: "square.and.pencil")
                            }
                            .keyboardShortcut("n", modifiers: .command)
                            .help("发布动态（⌘N）")
                        }
                    }
                }
        case .hot:
            EntityListView(model: page("hot", url: "/page?url=V9_HOME_TAB_RANKING", title: "热榜"))
        case .following:
            if app.isLoggedIn {
                EntityListView(model: page("following", url: "/page?url=V9_HOME_TAB_FOLLOW", title: "全部关注"))
            } else {
                LoginRequiredView(message: "登录后可以查看你关注的人和话题的动态。")
            }
        case .topics:
            CategoryBrowser(kind: .topics)
        case .products:
            CategoryBrowser(kind: .products)
        case .coolpic:
            EntityListView(model: page("coolpic", url: "/page?url=V11_FIND_COOLPIC", title: "酷图"))
        case .search:
            SearchView()
        case .notifications:
            NotificationsView()
        case .messages:
            MessageListView()
        case .localFollow:
            LocalFollowView(store: app.localFollow)
        case .favorites:
            SavedFeedList(kind: .favorites)
        case .history:
            SavedFeedList(kind: .history)
        }
    }

    private var homeModel: PagedList {
        app.list("home") {
            let app = app
            let client = app.client
            let installTime = app.installTime
            var isFirstRequest = true
            return PagedList(cacheKey: "home", cacheScope: { app.cacheScope }) { request in
                let firstLaunch = isFirstRequest
                isFirstRequest = false
                return try await client.homeFeed(page: request.page, firstLaunch: firstLaunch, installTime: installTime,
                                                 firstItem: request.firstItem, lastItem: request.lastItem)
            }
        }
    }

    private func page(_ key: String, url: String, title: String) -> PagedList {
        app.list(key) {
            let app = app
            let client = app.client
            return PagedList(cacheKey: key, cacheScope: { app.cacheScope }) { request in
                try await client.dataList(url: url, title: title, page: request.page,
                                          firstItem: request.firstItem, lastItem: request.lastItem)
            }
        }
    }
}

/// 导航栈推入的目的地。
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .feed(let id):
            FeedDetailView(id: id)
        case .user(let key):
            UserView(key: key)
        case .topic(let tag):
            TopicView(target: .topic(tag))
        case .product(let id):
            TopicView(target: .product(id))
        case .app(let key):
            AppDetailView(key: key)
        case .page(let url, let title):
            RemoteListView(source: .page(url: url), title: title)
        case .list(let path, let title):
            RemoteListView(source: .path(path), title: title)
        case .search(let keyword):
            SearchView(initialKeyword: keyword)
        case .chat(let peer):
            ChatView(peer: peer)
        }
    }
}

/// 按 `dataList` 的 url 或接口路径访问的列表页。
private struct RemoteListView: View {
    enum Source: Hashable {
        case page(url: String)
        case path(String)
    }

    let source: Source
    let title: String

    @Environment(AppModel.self) private var app
    @State private var model: PagedList?
    @State private var loadedSource: Source?

    var body: some View {
        Group {
            if let model {
                EntityListView(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .routeTitle(title.isEmpty ? "酷安" : title)
        .task(id: source) {
            // 从列表点进帖子再返回时，保留原列表数据与滚动位置。
            guard loadedSource != source || model == nil else { return }
            loadedSource = source
            let client = app.client
            let title = title
            switch source {
            case .page(let url):
                model = PagedList { request in
                    try await client.dataList(url: url, title: title, page: request.page,
                                              firstItem: request.firstItem, lastItem: request.lastItem)
                }
            case .path(let path):
                model = PagedList { request in
                    try await client.list(path: path, page: request.page,
                                          firstItem: request.firstItem, lastItem: request.lastItem)
                }
            }
        }
    }
}
