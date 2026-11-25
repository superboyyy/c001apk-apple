import Foundation

/// 把列表行转换成过滤输入。只取这一条自己的内容：回复、转发原文和引用另行判断。
public enum ContentFilterProjection {
    private static let coolapkHosts: Set<String> = ["coolapk.com", "www.coolapk.com", "m.coolapk.com"]
    private static let articlePartTypes: Set<String> = ["text", "title", "image", "shareUrl"]

    private static let markdownQuote = try? NSRegularExpression(
        pattern: #"^(?: {0,3}>[^\r\n]*(?:\r?\n|$))+"#, options: [.anchorsMatchLines])
    private static let bbcodeQuote = try? NSRegularExpression(
        pattern: #"\[quote(?:=[^\]]*)?\][\s\S]*?\[/quote\]"#, options: [.caseInsensitive])

    /// 动态与话题按动态处理，回复按评论处理，用户卡片按用户处理；通知、私信等不过滤。
    public static func scope(of entity: Entity) -> FilterScope? {
        switch entity.entityType {
        case "feed", "topic": return .feed
        case "feed_reply": return .comment
        case "user", "contacts": return .user
        default: return nil
        }
    }

    /// 内容例外使用的键；没有服务端 ID 时退回到本地标识（这样的例外无法长期生效）。
    public static func key(of entity: Entity, scope: FilterScope? = nil) -> String {
        let actual = scope ?? self.scope(of: entity) ?? .feed
        return "\(actual.rawValue):\(identifier(of: entity, scope: actual) ?? entity.id.uuidString)"
    }

    /// 服务端 ID；用户卡片没有 ID 时用 UID。
    private static func identifier(of entity: Entity, scope: FilterScope) -> String? {
        if !entity.entityID.isEmpty { return entity.entityID }
        return scope == .user && !entity.uid.isEmpty ? entity.uid : nil
    }

    public static func input(for entity: Entity, scope: FilterScope? = nil) -> FilterInput {
        var ids = Set<String>()
        var names = Set<String>()
        func addTopic(_ row: Entity, force: Bool = false) {
            guard force || row.entityType == "topic" || row.url.contains("/t/") else { return }
            if !row.entityID.isEmpty { ids.insert(row.entityID) }
            if !row.title.isEmpty { names.insert(row.title) }
        }
        entity.relationRows.forEach { addTopic($0) }
        if let target = entity.targetRow { addTopic(target) }
        if entity.entityType == "topic" { addTopic(entity, force: true) }
        for tag in entity.tags.split(whereSeparator: { ",，#".contains($0) }) {
            let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { names.insert(name) }
        }
        if !entity.topicTitle.isEmpty { names.insert(entity.topicTitle) }

        let own = withoutQuotes(entity.message)
        // 只认正文里明确的话题链接，不做子串匹配，也不看 @用户。
        FilterHTML.forEachElement(FilterHTML.parse(own)) { name, attributes, children in
            guard name == "a", let href = attributes["href"], let tag = topicTag(inHref: href) else { return }
            let label = FilterHTML.textContent(children).replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for value in [tag, label] where !value.isEmpty { names.insert(value) }
        }

        var article = ""
        if !entity.messageRawOutput.isEmpty, let parts = JSON.parse(entity.messageRawOutput)?.array {
            article = parts
                .filter { $0.object != nil && articlePartTypes.contains($0["type"].string ?? "") }
                .map { part in
                    withoutQuotes(["message", "title", "description"].map { part[$0].string ?? "" }
                        .joined(separator: "\n"))
                }
                .joined(separator: "\n")
        }

        let actual = scope ?? self.scope(of: entity) ?? .feed
        let author = entity.uid.isEmpty && actual == .user ? entity.entityID : entity.uid
        return FilterInput(
            scope: actual,
            id: identifier(of: entity, scope: actual),
            authorUID: author.isEmpty ? nil : author,
            text: [entity.messageTitle, entity.title, own, article].joined(separator: "\n"),
            topicIDs: ids, topicNames: names)
    }

    /// 去掉引用的内容（Markdown `>`、`<blockquote>`、`.feed-quote`、`[quote]`），只留作者自己写的。
    static func withoutQuotes(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = replace(markdownQuote, in: text, with: "\n")
        if result.contains("<") {
            let nodes = FilterHTML.removing(FilterHTML.parse(result)) { name, attributes in
                name == "blockquote"
                    || (attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).contains("feed-quote")
            }
            result = FilterHTML.serialize(nodes)
        }
        return replace(bbcodeQuote, in: result, with: "")
    }

    private static func replace(_ regex: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let regex else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    /// 站内 `/t/<话题>` 链接里的话题名；外站链接返回 nil。
    static func topicTag(inHref href: String) -> String? {
        var rest = Substring(href.trimmingCharacters(in: .whitespacesAndNewlines))
        if let separator = rest.range(of: "://") ?? (rest.hasPrefix("//") ? rest.range(of: "//") : nil),
           !rest[..<separator.lowerBound].contains("/") {
            let afterScheme = rest[separator.upperBound...]
            var host = afterScheme.prefix { !"/?#".contains($0) }
            rest = afterScheme[host.endIndex...]
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            host = host.prefix { $0 != ":" }
            guard host.isEmpty || coolapkHosts.contains(host.lowercased()) else { return nil }
        }
        let path = rest.prefix { $0 != "?" && $0 != "#" }
        guard path.hasPrefix("/t/") else { return nil }
        let segments = path.split(separator: "/")
        guard segments.count > 1 else { return "" }
        return segments[1].removingPercentEncoding ?? String(segments[1])
    }
}
