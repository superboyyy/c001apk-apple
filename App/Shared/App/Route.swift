import CoolapkKit
import Foundation

/// 应用导航栈中的一个目的地。
enum Route: Hashable {
    case feed(id: String)
    case user(String)
    case topic(String)
    case product(String)
    case app(String)
    /// 按 `url` 参数访问的 `/v6/page/dataList` 内容。
    case page(url: String, title: String)
    /// 直接按接口路径访问的列表。
    case list(path: String, title: String)
    case search(String)
    /// 与某位用户的私信。
    case chat(ChatPeer)
}

enum LinkTarget: Equatable {
    case route(Route)
    case image(String)
    case external(URL)
    case unsupported
}

/// 把酷安链接（`/feed/1`、`coolmarket://…`、`https://www.coolapk.com/…`）
/// 解析为应用内目的地。移植自 Flutter 端的 `Utils.onOpenLink`。
enum LinkRouter {
    static let hosts: Set<String> = [
        "coolapk.com", "www.coolapk.com", "m.coolapk.com", "coolapk1s.com", "www.coolapk1s.com",
    ]

    static func resolve(_ raw: String, title: String? = nil) -> LinkTarget {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unsupported }
        // 酷安网页版或部分评论里的图片链接不带协议头（`//image.coolapk.com/…`），先补全再解析。
        let link = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed

        var path = link
        var externalURL: URL?
        let parsedComponents: URLComponents? = if !link.hasPrefix("/") && !link.hasPrefix("#") {
            URLComponents(string: link)
                ?? link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URLComponents.init(string:))
        } else {
            nil
        }
        if let components = parsedComponents, let scheme = components.scheme?.lowercased() {
            let host = components.host?.lowercased() ?? ""
            let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
            if scheme == "coolmarket" {
                let base = hosts.contains(host) || host == "com.coolapk.market"
                    ? components.percentEncodedPath
                    : "/" + host + components.percentEncodedPath
                path = base + query
            } else if scheme == "http" || scheme == "https" {
                if isCoolapkImageHost(host) { return .image(link) }
                if hosts.contains(host) {
                    path = components.percentEncodedPath + query
                    if let fragment = components.percentEncodedFragment, components.percentEncodedPath.count <= 1,
                       fragment.hasPrefix("/") {
                        path = "#" + fragment
                    }
                } else {
                    externalURL = components.url ?? URL(string: link)
                }
            } else {
                return .unsupported
            }
        }
        if let externalURL { return .external(externalURL) }

        if path.hasPrefix("#/") {
            return .route(.page(url: String(path.dropFirst()), title: title ?? ""))
        }
        if path.hasPrefix("/page?url=") {
            var inner = String(path.dropFirst("/page?url=".count))
            if inner.hasPrefix("%2F") || inner.hasPrefix("%23") || inner.hasPrefix("%2f") {
                inner = inner.removingPercentEncoding ?? inner
            }
            if inner.hasPrefix("#") { inner.removeFirst() }
            return .route(.page(url: inner, title: title ?? ""))
        }

        let pathOnly = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let segments = pathOnly.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        guard let first = segments.first else {
            return fallback(link)
        }
        let rest = segments.dropFirst().joined(separator: "/")
        switch first {
        case "feed", "picture", "question", "article":
            guard segments.count >= 2, segments[1].allSatisfy(\.isNumber) else { return fallback(link) }
            return .route(.feed(id: segments[1]))
        case "u":
            guard !rest.isEmpty else { return .unsupported }
            return .route(.user(rest))
        case "apk", "game":
            guard segments.count >= 2 else { return .unsupported }
            return .route(.app(segments[1]))
        case "t":
            guard !rest.isEmpty else { return .unsupported }
            return .route(.topic(rest))
        case "product":
            guard segments.count >= 2, segments[1].allSatisfy(\.isNumber) else { return fallback(link) }
            return .route(.product(segments[1]))
        case "dyh":
            guard segments.count >= 2 else { return .unsupported }
            return .route(.list(path: "/v6/dyhArticle/list?dyhId=\(segments[1])&type=all", title: title ?? "看看号"))
        default:
            return fallback(link)
        }
    }

    private static func isCoolapkImageHost(_ host: String) -> Bool {
        host == "image.coolapk.com" || host.hasSuffix(".image.coolapk.com")
            || host == "pic.coolapk.com" || host.hasSuffix(".pic.coolapk.com")
    }

    /// 酷安域名下无法识别的链接仍交给网站打开。
    private static func fallback(_ link: String) -> LinkTarget {
        if link.hasPrefix("http"), let url = URL(string: link) { return .external(url) }
        if link.hasPrefix("/"), let url = URL(string: "https://www.coolapk.com" + link) { return .external(url) }
        return .unsupported
    }

    static func webURL(for route: Route) -> URL? {
        func encoded(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
        }
        switch route {
        case .feed(let id): return URL(string: "https://www.coolapk.com/feed/\(id)")
        case .user(let uid): return URL(string: "https://www.coolapk.com/u/\(encoded(uid))")
        case .topic(let tag): return URL(string: "https://www.coolapk.com/t/\(encoded(tag))")
        case .product(let id): return URL(string: "https://www.coolapk.com/product/\(id)")
        case .app(let id): return URL(string: "https://www.coolapk.com/apk/\(encoded(id))")
        case .page, .list, .search, .chat: return nil
        }
    }
}
