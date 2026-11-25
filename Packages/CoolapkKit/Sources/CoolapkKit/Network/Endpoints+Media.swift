import Foundation

extension CoolapkClient {
    /// 解析一张实况图对应的视频地址。做法与 coolapk-desktop 的 `resolve_live_photo_video`
    /// 一致：请求 `/v6/livePhoto/showVideo`，服务端以 302 跳转（或 JSON）给出地址。
    /// 没有内容编号、图片不在酷安域名下或服务端未给出地址时返回 `nil`。
    public func livePhotoVideoURL(for media: FeedMedia) async throws -> URL? {
        guard let contentID = media.contentID?.trimmingCharacters(in: .whitespaces), !contentID.isEmpty,
              contentID.count <= 128,
              var components = URLComponents(string: media.sourceURL.trimmingCharacters(in: .whitespaces)),
              let host = components.host?.lowercased(), host == "coolapk.com" || host.hasSuffix(".coolapk.com"),
              ["http", "https"].contains(components.scheme ?? "")
        else { return nil }
        // 接口按原始的 http 图片地址校验；界面上为了加载已改成 https，这里只把协议改回去。
        if host == "image.coolapk.com" { components.scheme = "http" }
        guard let pictureURL = components.string else { return nil }

        let query: [(String, String?)] = [
            ("picUrl", pictureURL),
            ("id", "\(media.contentType.rawValue)_\(contentID)"),
        ]
        if let location = try await redirectLocation("/v6/livePhoto/showVideo", query: query) {
            return location
        }
        // 少数情况下不跳转，而是在 JSON 里给出地址。
        guard let body = JSON.parse(try await getData("/v6/livePhoto/showVideo", query: query)) else { return nil }
        return CoolapkClient.firstVideoURL(in: body)
    }

    /// 在响应里按常见字段名找出第一个 http(s) 地址。
    static func firstVideoURL(in value: JSON, depth: Int = 0) -> URL? {
        guard depth < 6 else { return nil }
        switch value {
        case .string(let text):
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
                return nil
            }
            return url
        case .array(let items):
            for item in items { if let url = firstVideoURL(in: item, depth: depth + 1) { return url } }
            return nil
        case .object(let object):
            for key in ["url", "videoUrl", "video_url", "finalUrl", "final_url", "urlList", "url_list", "data"] {
                if let child = object[key], let url = firstVideoURL(in: child, depth: depth + 1) { return url }
            }
            return nil
        default:
            return nil
        }
    }
}
