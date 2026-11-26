import CoolapkKit
import SwiftUI

/// 话题（`/t/…`）或数码（`/product/…`）页及其内容分页。
struct TopicView: View {
    enum Target: Hashable {
        case topic(String)
        case product(String)
    }

    let target: Target

    @Environment(AppModel.self) private var app
    @State private var detail: Entity?
    @State private var failure: APIError?
    /// 分页按位置区分：服务端可能返回重复的 `page_name`。
    private struct TabItem {
        let key: String
        let title: String
    }

    @State private var tabs: [TabItem] = []
    @State private var selectedTab = ""
    @State private var lists: [String: PagedList] = [:]
    @State private var isFollowing = false
    @State private var loadedTarget: Target?

    var body: some View {
        Group {
            if let detail {
                if let list = lists[selectedTab] {
                    ZStack {
                        EntityListView(model: list) {
                            TopicHeader(detail: detail, target: target, isFollowing: $isFollowing)
                            if tabs.count > 1 {
                                GlassTabBar(items: tabs.map(\.key), selection: $selectedTab) { key in
                                    tabs.first { $0.key == key }?.title ?? key
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .id(selectedTab)
                        .transition(.opacity)
                    }
                } else {
                    ScrollView {
                        TopicHeader(detail: detail, target: target, isFollowing: $isFollowing).padding(16)
                        ContentUnavailableView("暂无内容", systemImage: "tray")
                    }
                }
            } else if let failure {
                FailureView(error: failure) { interactive in
                    Task { await load(interactive: interactive) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .routeTitle(detail?.title ?? title)
        .task(id: target) {
            // 从帖子返回时保留当前板块分页、已加载列表与滚动位置。
            guard loadedTarget != target || detail == nil else { return }
            await load(interactive: false)
        }
    }

    private var title: String {
        switch target {
        case .topic(let tag): return tag
        case .product: return "数码"
        }
    }

    private func load(interactive: Bool) async {
        failure = nil
        let client = app.client
        do {
            let fetch: () async throws -> Entity = {
                switch target {
                case .topic(let tag): return try await client.topicDetail(tag: tag)
                case .product(let id): return try await client.productDetail(id: id)
                }
            }
            let loaded = interactive ? try await CoolapkClient.interactive(fetch) : try await fetch()
            var created: [String: PagedList] = [:]
            var items: [TabItem] = []
            var preferred: String?
            for (index, tab) in loaded.tabList.enumerated() where !tab.url.isEmpty {
                let key = "\(index)"
                let url = tab.url, tabTitle = tab.title
                created[key] = PagedList { request in
                    try await client.dataList(url: url, title: tabTitle, page: request.page,
                                              firstItem: request.firstItem, lastItem: request.lastItem)
                }
                items.append(TabItem(key: key, title: tabTitle))
                if preferred == nil, tab.pageName == loaded.selectedTab { preferred = key }
            }
            lists = created
            tabs = items
            selectedTab = preferred ?? items.first?.key ?? ""
            isFollowing = loaded.userAction["follow"].int == 1
            detail = loaded
            loadedTarget = target
        } catch {
            failure = APIError.from(error)
        }
    }
}

private struct TopicHeader: View {
    let detail: Entity
    let target: TopicView.Target
    @Binding var isFollowing: Bool

    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RemoteImage(detail.logo, maxPixel: 300)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.title).font(.system(size: 20, weight: .bold)).textSelection(.enabled)
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                let intro = detail.intro.isEmpty ? detail.descriptionText : detail.intro
                if !intro.isEmpty {
                    Text(RichText.plainText(intro))
                        .font(.system(size: app.settings.fontSize - 0.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                if case .topic(let tag) = target {
                    Button(isFollowing ? "已关注" : "关注") {
                        guard app.requireLogin() else { return }
                        let next = !isFollowing
                        Task {
                            do {
                                try await CoolapkClient.interactive {
                                    try await app.client.setTopicFollowed(next, tag: detail.title.isEmpty ? tag : detail.title)
                                }
                                isFollowing = next
                            } catch {
                                app.report(error)
                            }
                        }
                    }
                    .buttonStyle(isFollowing ? AnyButtonStyle(.glass) : AnyButtonStyle(KeyActionButtonStyle()))
                }
                if let url = webURL {
                    ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.glass)
                }
            }
        }
        .card(padding: 16)
        .frame(maxWidth: 1280)
    }

    private var webURL: URL? {
        switch target {
        case .topic(let tag): return LinkRouter.webURL(for: .topic(detail.title.isEmpty ? tag : detail.title))
        case .product(let id): return LinkRouter.webURL(for: .product(id))
        }
    }

    private var summary: String {
        var parts: [String] = []
        if !detail.hotText.isEmpty { parts.append("\(detail.hotText) 热度") }
        if let follow = detail["follownum"].int ?? detail["follow_num"].int { parts.append("\(Formatting.count(follow)) 关注") }
        if !detail.commentText.isEmpty { parts.append("\(detail.commentText) 讨论") }
        return parts.joined(separator: " · ")
    }
}

/// 话题和数码目录：左侧分类，右侧内容。
struct CategoryBrowser: View {
    enum Kind { case topics, products }
    let kind: Kind

    @Environment(AppModel.self) private var app
    @State private var categories: [Entity] = []
    @State private var selection: UUID?
    @State private var lists: [UUID: PagedList] = [:]
    @State private var failure: APIError?

    var body: some View {
        Group {
            if !categories.isEmpty {
                let selectionBinding = Binding<UUID?>(
                    get: { selection },
                    set: { next in withAnimation(RouteMotion.tab) { selection = next } }
                )
                HStack(spacing: 0) {
                    List(categories, selection: selectionBinding) { category in
                        Text(category.title).font(.system(size: 13)).lineLimit(1).tag(category.id)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .frame(width: 148)
                    Divider()
                    ZStack {
                        if let selection, let list = lists[selection] {
                            EntityListView(model: list)
                                .id(selection)
                                .transition(.opacity)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let failure {
                FailureView(error: failure) { interactive in
                    Task { await load(interactive: interactive) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            if categories.isEmpty {
                restoreCachedCategories()
                await load(interactive: false, silent: !categories.isEmpty)
            }
        }
    }

    private var kindKey: String { kind == .topics ? "topics" : "products" }
    private var categoryCacheKey: String { "categories-\(kindKey)" }

    private func restoreCachedCategories() {
        guard let cached = FeedCache.shared.load(key: categoryCacheKey, scope: app.cacheScope) else { return }
        applyCategories(cached.items, preserveExisting: false)
    }

    private func applyCategories(_ rows: [Entity], preserveExisting: Bool) {
        let app = app
        let client = app.client
        var existingByURL: [String: (entity: Entity, list: PagedList)] = [:]
        if preserveExisting {
            for item in categories {
                if let list = lists[item.id] { existingByURL[item.url] = (item, list) }
            }
        }
        let selectedURL = selection.flatMap { id in categories.first { $0.id == id }?.url }

        var created: [UUID: PagedList] = [:]
        var kept: [Entity] = []
        for row in rows {
            guard case .route(.page(let url, _)) = LinkRouter.resolve(row.url, title: row.title) else { continue }
            if let existing = existingByURL[row.url] {
                let updated = Entity(id: existing.entity.id, json: row.json)
                created[updated.id] = existing.list
                kept.append(updated)
            } else {
                let title = row.title
                created[row.id] = PagedList(
                    cacheKey: "cat-\(kindKey)-\(url)",
                    cacheScope: { app.cacheScope }
                ) { request in
                    try await client.dataList(url: url, title: title, page: request.page,
                                              firstItem: request.firstItem, lastItem: request.lastItem)
                }
                kept.append(row)
            }
        }
        guard !kept.isEmpty else { return }
        lists = created
        categories = kept
        if let selectedURL, let matched = kept.first(where: { $0.url == selectedURL }) {
            selection = matched.id
        } else {
            selection = kept.first?.id
        }
    }

    private func load(interactive: Bool, silent: Bool = false) async {
        if !silent { failure = nil }
        let client = app.client
        do {
            let fetch: () async throws -> EntityPage = {
                switch kind {
                case .topics:
                    return try await client.list(path: "/v6/page/dataList", query: [
                        ("url", "V11_VERTICAL_TOPIC"), ("title", "话题"), ("page", "1"),
                    ])
                case .products:
                    return try await client.list(path: "/v6/product/categoryList")
                }
            }
            let page = interactive ? try await CoolapkClient.interactive(fetch) : try await fetch()
            let rows: [Entity]
            switch kind {
            case .topics: rows = page.items.first { $0.entityTemplate == "verticalColumnsFullPageCard" }?.entities ?? []
            case .products: rows = page.items.filter { $0.entityType == "productBrand" }
            }
            if !rows.isEmpty {
                FeedCache.shared.save(EntityPage(items: rows), key: categoryCacheKey, scope: app.cacheScope)
                applyCategories(rows, preserveExisting: silent)
            } else if !silent {
                failure = APIError(.invalidResponse, "没有可用的分类")
            }
        } catch {
            if !silent { failure = APIError.from(error) }
        }
    }
}
