import Foundation

/// 图片所属内容的类型。
public enum MediaContentType: String, Sendable {
    case feed, reply, article
}

/// 帖子里一张图片的元数据：原图、缩略图、是否 HDR、是否实况及其视频地址。
/// 对应上游 Flutter 端的 `feed_media.dart`。
public struct FeedMedia: Sendable, Equatable {
    /// 接口给出的图片地址，保持原样。
    public var sourceURL: String
    public var previewURL: String?
    /// 实况视频地址；公开接口目前不返回，为 nil 时查看器会尝试原图里内嵌的视频。
    public var videoURL: String?
    public var isLivePhoto: Bool
    public var isHDR: Bool
    /// 所属帖子或评论的编号。
    public var contentID: String?
    public var contentType: MediaContentType

    public init(sourceURL: String, previewURL: String? = nil, videoURL: String? = nil,
                isLivePhoto: Bool = false, isHDR: Bool = false,
                contentID: String? = nil, contentType: MediaContentType = .feed) {
        self.sourceURL = sourceURL
        self.previewURL = previewURL
        self.videoURL = videoURL
        self.isLivePhoto = isLivePhoto
        self.isHDR = isHDR
        self.contentID = contentID
        self.contentType = contentType
    }

    /// 只有地址时，按酷安图片文件名里的标记判断实况与 HDR。
    public init(url: String, contentID: String? = nil, contentType: MediaContentType = .feed) {
        let marks = FeedMedia.fileNameMarks(url)
        self.init(sourceURL: url, isLivePhoto: marks.contains("livepic"),
                  isHDR: marks.contains("uhdr") || marks.contains("xhdr"),
                  contentID: contentID, contentType: contentType)
    }

    /// 用于显示的地址：酷安图床的 http 链接升级为 https，无协议头链接补全 https。
    public var displayURL: String {
        if sourceURL.hasPrefix("//") { return "https:" + sourceURL }
        guard let components = URLComponents(string: sourceURL), components.scheme?.lowercased() == "http",
              components.host?.lowercased() == "image.coolapk.com"
        else { return sourceURL }
        return "https" + sourceURL.dropFirst("http".count)
    }

    /// 原图地址，保存原件时使用。
    public var originalURL: String { displayURL }
    public var thumbnailURL: String { previewURL ?? displayURL }

    // MARK: 解析

    /// 酷安图床在文件名的尺寸标记前追加素材类型，例如
    /// `…_667-livepic-uhdr@2494x3325.jpg`：`livepic` 为实况，`uhdr`、`xhdr` 为带增益图的 HDR。
    static func fileNameMarks(_ url: String) -> Set<String> {
        let path = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? url
        guard let name = path.split(separator: "/").last else { return [] }
        let stem = name.split(separator: "@", maxSplits: 1).first ?? name
        guard stem.count < name.count else { return [] }
        return Set(stem.split(separator: "-").dropFirst().map { $0.lowercased() })
    }

    /// 由图片地址列表和可选的逐图元数据生成素材列表，顺序与 `urls` 一致。
    /// `urls` 为空时改用元数据里出现的地址。
    public static func items(metadata: JSON = .null, urls: [String] = [], contentID: String? = nil,
                             contentType: MediaContentType = .feed) -> [FeedMedia] {
        let described = objects(in: metadata).compactMap { item(from: $0, contentID: contentID, contentType: contentType) }
        let values = urls.isEmpty ? (described.isEmpty ? Entity.mediaURLs(metadata) : described.map(\.sourceURL)) : urls
        return values.filter { !$0.isEmpty }.map { url in
            let fallback = FeedMedia(url: url, contentID: contentID, contentType: contentType)
            guard let match = described.first(where: { $0.matches(url) }) else { return fallback }
            var merged = match
            merged.sourceURL = url
            merged.isLivePhoto = match.isLivePhoto || fallback.isLivePhoto
            merged.isHDR = match.isHDR || fallback.isHDR
            return merged
        }
    }

    /// 把要显示的地址列表对应到已有的元数据；找不到的地址单独生成，不借用别的图片的归属。
    /// 对应上游的 `mediaGalleryArguments`。
    public static func gallery(urls: [String], items: [FeedMedia] = [], contentID: String? = nil,
                               contentType: MediaContentType = .feed) -> [FeedMedia] {
        guard !urls.isEmpty else { return items }
        return urls.map { url in
            let fallback = FeedMedia(url: url, contentID: contentID, contentType: contentType)
            guard var match = items.first(where: { $0.matches(url) }) else { return fallback }
            if (match.contentID ?? "").trimmingCharacters(in: .whitespaces).isEmpty, let contentID {
                match.contentID = contentID
                match.contentType = contentType
            }
            return match
        }
    }

    private func matches(_ url: String) -> Bool {
        sourceURL == url || previewURL == url || originalURL == FeedMedia(sourceURL: url).originalURL
    }

    /// 元数据里的对象条目；字符串条目只含地址，由调用方按地址处理。
    private static func objects(in value: JSON, depth: Int = 0) -> [[String: JSON]] {
        guard depth < 6 else { return [] }
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("[") || trimmed.hasPrefix("{"), let parsed = JSON.parse(trimmed) else { return [] }
            return objects(in: parsed, depth: depth + 1)
        case .array(let items):
            return items.flatMap { objects(in: $0, depth: depth + 1) }
        case .object(let object):
            if urlKeys.contains(where: { object[$0]?.text != nil }) { return [object] }
            for key in ["imageUriList", "image_uri_list", "pics", "picArr", "data"] {
                let nested = objects(in: object[key] ?? .null, depth: depth + 1)
                if !nested.isEmpty { return nested }
            }
            return []
        default:
            return []
        }
    }

    private static let urlKeys = ["url", "uri", "pic", "imageUrl", "image_url", "sourceUrl"]
    // 下面几组字段名按上游 `FeedMedia` 的属性名宽松匹配；公开接口目前只返回地址字符串。
    private static let videoKeys = ["videoUrl", "video_url", "liveVideoUrl", "live_video_url", "livePhotoUrl", "live_photo_url"]
    private static let previewKeys = ["previewUrl", "preview_url", "thumbnailUrl", "thumbnail_url", "thumbnail"]
    private static let liveKeys = ["isLivePhoto", "is_live_photo", "isLive", "is_live", "livePhoto", "live_photo"]
    private static let hdrKeys = ["isHdr", "is_hdr", "isHDR", "hdr"]

    /// 字段名对不上时，把对象里指向视频文件的地址当作实况视频。
    private static func videoValue(in object: [String: JSON]) -> String? {
        for key in object.keys.sorted() {
            guard let text = object[key]?.text, let url = Entity.mediaURLs(.string(text)).first,
                  let path = URLComponents(string: url)?.path.lowercased()
            else { continue }
            if path.hasSuffix(".mp4") || path.hasSuffix(".mov") || path.hasSuffix(".m4v") { return url }
        }
        return nil
    }

    private static func item(from object: [String: JSON], contentID: String?, contentType: MediaContentType) -> FeedMedia? {
        func url(_ keys: [String]) -> String? {
            keys.lazy.compactMap { Entity.mediaURLs(object[$0] ?? .null).first }.first
        }
        func flag(_ keys: [String]) -> Bool {
            keys.contains { object[$0]?.bool == true }
        }
        guard let source = url(urlKeys) else { return nil }
        var media = FeedMedia(url: source, contentID: contentID, contentType: contentType)
        media.previewURL = url(previewKeys)
        media.videoURL = url(videoKeys) ?? videoValue(in: object)
        media.isLivePhoto = media.isLivePhoto || media.videoURL != nil || flag(liveKeys)
        media.isHDR = media.isHDR || flag(hdrKeys)
        return media
    }
}

extension Entity {
    /// 逐图元数据所在的字段，没有时为 null。
    private var mediaMetadata: JSON {
        for key in ["imageUriList", "image_uri_list", "pics"] where !json[key].isNull { return json[key] }
        return .null
    }

    private var mediaContentType: MediaContentType { entityType == "feed_reply" ? .reply : .feed }

    /// 这条帖子或评论的图片素材，顺序与 `pictures`（评论回退 `pic`）一致。
    public var mediaItems: [FeedMedia] {
        let urls = entityType == "feed_reply" ? replyPictures : pictures
        return FeedMedia.items(metadata: mediaMetadata, urls: urls, contentID: entityID.isEmpty ? nil : entityID,
                               contentType: mediaContentType)
    }

    /// 给定要显示的图片地址（如图文正文里的图片），返回带元数据的素材列表。
    public func mediaItems(for urls: [String]) -> [FeedMedia] {
        let contentType: MediaContentType = entityType == "feed_reply" ? .reply : (isArticle ? .article : .feed)
        return FeedMedia.gallery(urls: urls, items: mediaItems, contentID: entityID.isEmpty ? nil : entityID,
                                 contentType: contentType)
    }
}
