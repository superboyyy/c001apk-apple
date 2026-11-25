import Foundation

/// 酷安列表或详情响应里的一行（动态、用户、话题、卡片……）。
/// 对应 Flutter 端的 `Datum`，但保留原始数据，按需读取具体类型的值。
public struct Entity: Identifiable, Sendable, Equatable {
    /// 在该值的生命周期内不变，用作 SwiftUI 标识。
    public let id: UUID
    public let json: JSON

    public init(_ json: JSON) {
        self.id = UUID()
        self.json = json
    }

    public static func == (lhs: Entity, rhs: Entity) -> Bool { lhs.id == rhs.id }

    public subscript(key: String) -> JSON { json[key] }

    // MARK: 标识

    public var entityType: String { json["entityType"].string ?? "" }
    public var entityTemplate: String { json["entityTemplate"].string ?? "" }
    /// 服务端标识（`id`，没有则取 `entityId`）。
    public var entityID: String { json["id"].text ?? json["entityId"].text ?? "" }
    /// 用于跨页去重。
    public var dedupeKey: String? {
        let identifier = entityID
        guard !identifier.isEmpty, identifier != "0" else { return nil }
        return "\(entityType)#\(entityTemplate)#\(identifier)"
    }

    // MARK: 通用

    public var title: String { json["title"].string ?? "" }
    public var subTitle: String { json["subTitle"].string ?? "" }
    public var url: String { json["url"].string ?? "" }
    public var pic: String { json["pic"].string ?? "" }
    public var logo: String { json["logo"].string ?? "" }
    public var cover: String { json["cover"].string ?? "" }
    public var descriptionText: String { json["description"].string ?? "" }
    public var entities: [Entity] { (json["entities"].array ?? []).map(Entity.init) }

    // MARK: 动态

    public var uid: String { json["uid"].string ?? "" }
    public var username: String { json["username"].string ?? json["userInfo"]["username"].string ?? "" }
    public var userAvatar: String { json["userAvatar"].text ?? json["userInfo"]["userAvatar"].string ?? "" }
    public var message: String { json["message"].string ?? "" }
    public var messageTitle: String { json["message_title"].string ?? "" }
    public var messageCover: String { json["message_cover"].string ?? "" }
    public var messageRawOutput: String { json["message_raw_output"].string ?? "" }
    public var feedType: String { json["feedType"].string ?? "" }
    public var feedTypeName: String { json["feedTypeName"].string ?? "" }
    public var deviceTitle: String { json["device_title"].string ?? "" }
    public var ipLocation: String { json["ip_location"].string ?? "" }
    public var infoHTML: String { json["infoHtml"].string ?? "" }
    /// Unix 时间。公开网页版的 `dateline` 是相对时间文本，所以回退到 `create_time`。
    public var dateline: Int? { json["dateline"].int ?? json["create_time"].int }
    public var lastUpdate: Int? { json["lastupdate"].int }
    public var likeCount: Int { json["likenum"].int ?? 0 }
    public var replyCount: Int { json["replynum"].int ?? 0 }
    public var commentCount: Int { json["commentnum"].int ?? 0 }
    public var forwardCount: Int { json["forwardnum"].int ?? 0 }
    public var favoriteCount: Int { json["favnum"].int ?? 0 }
    public var shareCount: Int { json["share_num"].int ?? 0 }
    /// 是否为图文长文（带封面，正文为 Markdown 风格）。
    public var isArticle: Bool {
        feedType == "feedArticle" || entityTemplate == "feedCover" || !messageCover.isEmpty
    }
    public var isStickTop: Bool { json["isStickTop"].int == 1 }
    public var tags: String { json["tags"].string ?? "" }
    public var topicTitle: String { json["ttitle"].string ?? "" }
    public var shareURL: String { json["shareUrl"].string ?? "" }

    public var extraTitle: String { json["extra_title"].string ?? "" }
    public var extraURL: String { json["extra_url"].string ?? "" }
    public var extraPic: String { json["extra_pic"].string ?? "" }

    public var pictures: [String] {
        let raw = json["picArr"].isNull
            ? (json["imageUriList"].isNull
                ? (json["image_uri_list"].isNull ? json["pics"] : json["image_uri_list"])
                : json["imageUriList"])
            : json["picArr"]
        return Entity.mediaURLs(raw)
    }

    public var userAction: JSON { json["userAction"] }
    public var isLiked: Bool { json["userAction"]["like"].int == 1 }
    public var isFollowingAuthor: Bool { json["userAction"]["followAuthor"].int == 1 }

    public var userInfo: Entity? {
        json["userInfo"].object == nil ? nil : Entity(json["userInfo"])
    }

    public var forwardSource: Entity? {
        json["forwardSourceFeed"].object == nil ? nil : Entity(json["forwardSourceFeed"])
    }

    public var relationRows: [Entity] { (json["relationRows"].array ?? []).map(Entity.init) }
    public var targetRow: Entity? {
        json["targetRow"].object == nil ? nil : Entity(json["targetRow"])
    }

    static let publicCopyKey = "_c001apkPublicCopy"
    /// 为 true 表示这条动态来自公开网页而非接口。
    public var isPublicCopy: Bool { json[Entity.publicCopyKey].bool == true }
    public var hotReplyRows: [Entity] { (json["hotReplyRows"].array ?? []).map(Entity.init) }

    // MARK: 回复

    public var replyRows: [Entity] { (json["replyRows"].array ?? []).map(Entity.init) }
    public var topReplyRows: [Entity] { (json["topReplyRows"].array ?? []).map(Entity.init) }
    public var replyRowsMore: Int { json["replyRowsMore"].int ?? 0 }
    public var replyUID: String { json["ruid"].string ?? "" }
    public var replyUsername: String { json["rusername"].string ?? "" }
    public var feedUID: String { json["feedUid"].string ?? "" }

    // MARK: 用户

    public var level: Int { json["level"].int ?? 0 }
    public var bio: String { json["bio"].string ?? "" }
    public var followCount: Int { json["follow"].int ?? 0 }
    public var fansCount: Int { json["fans"].int ?? 0 }
    public var feedCount: Int { json["feed"].int ?? 0 }
    public var beLikedCount: Int { json["be_like_num"].int ?? 0 }
    public var loginTime: Int? { json["logintime"].int }
    public var registerDate: Int? { json["regdate"].int }
    public var isFollowed: Bool { json["isFollow"].int == 1 }

    // MARK: 话题 / 数码 / 应用

    public var tabList: [Entity] { (json["tabList"].array ?? []).map(Entity.init) }
    public var selectedTab: String { json["selectedTab"].string ?? "" }
    public var pageName: String { json["page_name"].string ?? "" }
    public var hotText: String { json["hot_num_txt"].string ?? "" }
    public var followText: String { json["follow_num_txt"].string ?? json["follow_num"].string ?? "" }
    public var commentText: String { json["commentnum_txt"].string ?? json["feed_comment_num_txt"].string ?? "" }
    public var intro: String { json["intro"].string ?? "" }

    // MARK: 辅助方法

    /// 移植自 Flutter 端 `feed_media.dart` 的 `_urls`：支持字符串、逗号分隔列表、数组和嵌套对象。
    static func mediaURLs(_ value: JSON, depth: Int = 0) -> [String] {
        guard depth < 6 else { return [] }
        switch value {
        case .string(let text):
            var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            // 公开网页版的图片链接不带协议头。
            if trimmed.hasPrefix("//") { trimmed = "https:" + trimmed }
            if trimmed.hasPrefix("[") || trimmed.hasPrefix("{"), let parsed = JSON.parse(trimmed) {
                return mediaURLs(parsed, depth: depth + 1)
            }
            if trimmed.contains(","), !trimmed.contains("?") {
                let parts = trimmed.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                if parts.allSatisfy({ $0.hasPrefix("http") }) { return parts }
            }
            guard let url = URL(string: trimmed), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
                return []
            }
            return [trimmed]
        case .array(let items):
            return items.flatMap { mediaURLs($0, depth: depth + 1) }
        case .object(let object):
            for key in ["url", "uri", "pic", "imageUrl", "image_url", "sourceUrl"] {
                let result = mediaURLs(object[key] ?? .null, depth: depth + 1)
                if !result.isEmpty { return result }
            }
            for key in ["imageUriList", "image_uri_list", "pics", "picArr", "data"] {
                let result = mediaURLs(object[key] ?? .null, depth: depth + 1)
                if !result.isEmpty { return result }
            }
            return []
        default:
            return []
        }
    }
}

/// 一页列表数据，以及请求下一页所需的游标。
public struct EntityPage: Sendable {
    public var items: [Entity]
    public var firstItem: String?
    public var lastItem: String?

    public init(items: [Entity] = [], firstItem: String? = nil, lastItem: String? = nil) {
        self.items = items
        self.firstItem = firstItem
        self.lastItem = lastItem
    }
}
