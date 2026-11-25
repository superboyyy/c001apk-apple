import Foundation

/// 应用所用接口的类型化封装，参数与 Flutter 端的 `NetworkRepo` 保持一致。
extension CoolapkClient {
    static let acceptedEntityTypes: Set<String> = [
        "feed", "apk", "product", "user", "topic", "notification", "productBrand",
        "contacts", "recentHistory", "feed_reply", "message", "collection",
    ]

    static let acceptedTemplates: Set<String> = [
        "imageCarouselCard_1", "iconLinkGridCard", "iconMiniScrollCard", "iconMiniGridCard",
        "imageSquareScrollCard", "titleCard", "iconScrollCard", "imageTextScrollCard",
        "iconTabLinkGridCard", "verticalColumnsFullPageCard", "noMoreDataCard", "time", "messageCard",
    ]

    /// 搜索结果会把普通条目包在 `listCard` 容器里，这里展开。
    static func expandListCards(_ items: [JSON], depth: Int = 0) -> [JSON] {
        guard depth <= 20 else { return [] }
        return items.flatMap { item -> [JSON] in
            if item["entityType"].string == "card", item["entityTemplate"].string == "listCard",
               let children = item["entities"].array {
                return expandListCards(children, depth: depth + 1)
            }
            return [item]
        }
    }

    static func page(from response: Response, keepAll: Bool = false) -> EntityPage {
        guard let raw = response.data.array else { return EntityPage() }
        let expanded = expandListCards(raw)
        let cursorRows = expanded.filter { $0["id"].text != nil }
        let accepted = expanded.filter { item in
            if keepAll { return true }
            let type = item["entityType"].string ?? ""
            let template = item["entityTemplate"].string ?? ""
            if template == "refreshCard", (item["title"].string ?? "").contains("没有") { return true }
            return acceptedEntityTypes.contains(type) || acceptedTemplates.contains(template)
        }
        return EntityPage(
            items: accepted.map(Entity.init),
            firstItem: cursorRows.first?["id"].string,
            lastItem: cursorRows.last?["id"].string)
    }

    private func cursor(_ page: Int, _ firstItem: String?, _ lastItem: String?) -> [(String, String?)] {
        var items: [(String, String?)] = [("page", String(page))]
        if let firstItem, !firstItem.isEmpty { items.append(("firstItem", firstItem)) }
        if let lastItem, !lastItem.isEmpty { items.append(("lastItem", lastItem)) }
        return items
    }

    // MARK: 列表

    public func homeFeed(page: Int, firstLaunch: Bool, installTime: String,
                         firstItem: String?, lastItem: String?) async throws -> EntityPage {
        let response = try await get(
            "/v6/main/indexV8",
            query: cursor(page, firstItem, lastItem) + [
                ("firstLaunch", firstLaunch ? "1" : "0"),
                ("installTime", installTime),
                ("ids", ""),
            ],
            host: CoolapkClient.api2Host)
        return CoolapkClient.page(from: response)
    }

    /// `/v6/page/dataList`：热榜、酷图、话题分页、轮播页等。
    public func dataList(url: String, title: String, subTitle: String = "", page: Int,
                         firstItem: String?, lastItem: String?) async throws -> EntityPage {
        let response = try await get(
            "/v6/page/dataList",
            query: [("url", url), ("title", title), ("subTitle", subTitle)] + cursor(page, firstItem, lastItem))
        return CoolapkClient.page(from: response)
    }

    /// 按路径访问任意列表接口（路径可自带查询参数）。
    public func list(path: String, query: [(String, String?)] = [], page: Int? = nil,
                     firstItem: String? = nil, lastItem: String? = nil) async throws -> EntityPage {
        let response = try await get(path, query: query + (page.map { cursor($0, firstItem, lastItem) } ?? []))
        return CoolapkClient.page(from: response)
    }

    public func detail(path: String, query: [(String, String?)] = [], skipCaptcha: Bool = false) async throws -> Entity {
        let response = try await get(path, query: query, skipCaptcha: skipCaptcha)
        guard response.data.object != nil else {
            throw APIError(.business, response.message.isEmpty ? "没有找到内容" : response.message)
        }
        return Entity(response.data)
    }

    // MARK: 动态

    /// 加载一条动态。游客被接口要求验证或登录时，改用官方公开网页；
    /// 这类结果的 `isPublicCopy` 为 true，且不带账号状态。
    public func feedDetail(id: String) async throws -> Entity {
        guard id.range(of: "^[0-9]+$", options: .regularExpression) != nil else {
            throw APIError(.business, "动态编号无效")
        }
        do {
            return try await detail(path: "/v6/feed/detail", query: [("id", id)])
        } catch let failure as APIError where failure.kind == .captcha || failure.kind == .authentication {
            guard case .object(var object)? = try? await publicFeedPayload(id: id) else { throw failure }
            // 公开网页的响应无法反映当前账号是否点过赞。
            object["userAction"] = nil
            object[Entity.publicCopyKey] = .bool(true)
            return Entity(.object(object))
        }
    }

    public enum ReplySort: String, CaseIterable, Sendable, Identifiable {
        case latestActivity = "lastupdate_desc"
        case newest = "dateline_desc"
        case popular
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .latestActivity: return "默认"
            case .newest: return "最新"
            case .popular: return "热门"
            }
        }
    }

    public func feedReplies(id: String, sort: ReplySort, fromAuthor: Bool = false, page: Int,
                            firstItem: String?, lastItem: String?) async throws -> EntityPage {
        let response = try await get(
            "/v6/feed/replyList",
            query: [("id", id), ("listType", sort.rawValue)] + cursor(page, firstItem, lastItem) + [
                ("discussMode", "1"),
                ("feedType", "feed"),
                ("blockStatus", "0"),
                ("fromFeedAuthor", fromAuthor ? "1" : "0"),
            ],
            host: CoolapkClient.api2Host)
        return CoolapkClient.page(from: response)
    }

    public func replyThread(id: String, page: Int, firstItem: String?, lastItem: String?) async throws -> EntityPage {
        let response = try await get(
            "/v6/feed/replyList",
            query: [("id", id)] + cursor(page, firstItem, lastItem) + [
                ("listType", ""),
                ("discussMode", "0"),
                ("feedType", "feed_reply"),
                ("blockStatus", "0"),
                ("fromFeedAuthor", "0"),
            ])
        return CoolapkClient.page(from: response)
    }

    // MARK: 用户

    public func userSpace(uid: String) async throws -> Entity {
        try await detail(path: "/v6/user/space", query: [("uid", uid)])
    }

    public func userProfile(uid: String) async throws -> Entity {
        try await detail(path: "/v6/user/profile", query: [("uid", uid)], skipCaptcha: true)
    }

    public func userFeed(uid: String, page: Int, firstItem: String?, lastItem: String?) async throws -> EntityPage {
        let response = try await get(
            "/v6/user/feedList",
            query: [("uid", uid)] + cursor(page, firstItem, lastItem) + [
                ("showAnonymous", "0"), ("isIncludeTop", "1"), ("showDoing", "0"),
            ])
        return CoolapkClient.page(from: response)
    }

    // MARK: 话题 / 数码 / 应用

    public func topicDetail(tag: String) async throws -> Entity {
        try await detail(path: "/v6/topic/newTagDetail", query: [("tag", tag)])
    }

    public func productDetail(id: String) async throws -> Entity {
        try await detail(path: "/v6/product/detail", query: [("id", id)])
    }

    public func appDetail(id: String) async throws -> Entity {
        try await detail(path: "/v6/apk/detail", query: [("id", id), ("installed", "1")])
    }

    // MARK: 搜索

    public enum SearchKind: String, CaseIterable, Sendable, Identifiable {
        case feed, apk, game, product, user, feedTopic
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .feed: return "动态"
            case .apk: return "应用"
            case .game: return "游戏"
            case .product: return "数码"
            case .user: return "用户"
            case .feedTopic: return "话题"
            }
        }
    }

    public enum SearchFeedType: String, CaseIterable, Sendable, Identifiable {
        case all, feed, feedArticle, picture, comment
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .all: return "全部"
            case .feed: return "动态"
            case .feedArticle: return "图文"
            case .picture: return "酷图"
            case .comment: return "回复"
            }
        }
    }

    public enum SearchSort: String, CaseIterable, Sendable, Identifiable {
        case `default`, hot, reply
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .default: return "实时"
            case .hot: return "热度"
            case .reply: return "回复"
            }
        }
    }

    public func search(keyword: String, kind: SearchKind, feedType: SearchFeedType = .all,
                       sort: SearchSort = .default, pageType: String? = nil, pageParam: String? = nil,
                       page: Int, firstItem: String?, lastItem: String?) async throws -> EntityPage {
        var query: [(String, String?)] = [
            ("type", kind.rawValue),
            ("feedType", feedType.rawValue),
            ("sort", sort.rawValue),
            ("searchValue", keyword),
            ("isStrict", "0"),
        ]
        if let pageType, !pageType.isEmpty { query.append(("pageType", pageType)) }
        if let pageParam, !pageParam.isEmpty { query.append(("pageParam", pageParam)) }
        query += cursor(page, firstItem, lastItem)
        query.append(("showAnonymous", "-1"))
        let response = try await get("/v6/search", query: query)
        return CoolapkClient.page(from: response)
    }

    // MARK: 账号

    /// 向接口确认已保存的账号 Cookie，并返回账号数据。
    public func checkLogin() async throws -> JSON {
        try await get("/v6/account/checkLoginInfo", skipCaptcha: true).data
    }

    public func notificationCounts() async throws -> JSON {
        try await get("/v6/notification/checkCount", skipCaptcha: true).data
    }

    // MARK: 操作（需要登录）

    /// 服务端返回新的点赞数时一并返回。
    @discardableResult
    public func setFeedLiked(_ liked: Bool, id: String, isReply: Bool = false) async throws -> Int? {
        let path: String
        switch (isReply, liked) {
        case (false, true): path = "/v6/feed/like"
        case (false, false): path = "/v6/feed/unlike"
        case (true, true): path = "/v6/feed/likeReply"
        case (true, false): path = "/v6/feed/unLikeReply"
        }
        let response = try await post(path, query: [("id", id), ("detail", "0")], form: [("trace", "")],
                                      allowSuccessWithoutData: true)
        return response.data["count"].int ?? response.data.int
    }

    public func setUserFollowed(_ followed: Bool, uid: String) async throws {
        _ = try await post(followed ? "/v6/user/follow" : "/v6/user/unfollow", query: [("uid", uid)],
                           allowSuccessWithoutData: true)
    }

    public func setTopicFollowed(_ followed: Bool, tag: String) async throws {
        _ = try await get(followed ? "/v6/feed/followTag" : "/v6/feed/unFollowTag", query: [("tag", tag)],
                          allowSuccessWithoutData: true)
    }

    /// `type` 为 `feed` 表示回复动态，为 `reply` 表示回复评论。
    public func postReply(id: String, type: String, message: String) async throws -> Entity {
        let response = try await post(
            "/v6/feed/reply", query: [("id", id), ("type", type)],
            form: [("message", message), ("replyAndForward", "0")])
        return Entity(response.data)
    }
}
