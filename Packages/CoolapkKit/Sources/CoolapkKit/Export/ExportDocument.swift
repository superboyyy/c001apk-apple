import Foundation

/// 随帖子一起导出的一条一级评论。
public struct ExportComment: Sendable {
    public let entity: Entity
    /// 置顶评论在导出文件里带“【置顶】”标记。
    public let isPinned: Bool

    public init(entity: Entity, isPinned: Bool) {
        self.entity = entity
        self.isPinned = isPinned
    }
}

/// 一条帖子（可带最多三条一级评论）的导出文档，可生成 Markdown 和离线 HTML。
/// 对应上游 Flutter 端的 `content_export.dart`。
public struct ExportDocument: Sendable {
    public let title: String
    /// 帖子编号。
    public let feedID: String
    /// 净化后的正文节点；所有输出格式都从它生成。
    let body: [HTMLNode]

    public static let maxComments = 3

    /// - Parameters:
    ///   - notices: 写进文件末尾的“保存说明”，例如评论未能取得。
    ///   - timeZone: 发布时间使用的时区，默认取系统时区。
    public init(feed: Entity, comments: [ExportComment] = [], notices: [String] = [], timeZone: TimeZone = .current) {
        let id = feed.entityID
        let author = ExportDocument.author(feed)
        let messageTitle = ExportDocument.plainText(feed.messageTitle)
        let feedTitle = ExportDocument.plainText(feed.title)
        let title = !messageTitle.isEmpty ? messageTitle : (!feedTitle.isEmpty ? feedTitle : "\(author)的动态")
        let escape = HTMLEntities.escapeText

        var html = "<h1>\(escape(title))</h1>" + ExportDocument.metadata(feed, timeZone: timeZone)
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        let links = ["https://www.coolapk.com/feed/\(encodedID)", "https://www.coolapk1s.com/feed/\(encodedID)"]
        html += "<p>" + links.map { "<a href=\"\($0)\">\($0)</a>" }.joined(separator: "<br>") + "</p>"
        html += ExportDocument.feedBody(feed)
        if !comments.isEmpty {
            html += "<hr><h2>精选评论（置顶优先，其余按热门排序）</h2>"
            for comment in comments.prefix(ExportDocument.maxComments) {
                let reply = comment.entity
                html += "<section><h3>\(comment.isPinned ? "【置顶】" : "")\(escape(ExportDocument.author(reply)))</h3>"
                html += ExportDocument.metadata(reply, timeZone: timeZone)
                html += "<p>赞：\(reply.likeCount)</p>\(ExportDocument.feedBody(reply))</section>"
            }
        }
        for notice in notices {
            html += "<p>保存说明：\(escape(notice))</p>"
        }
        self.title = title
        self.feedID = id
        self.body = HTMLSanitizer.sanitize(HTMLFragment.parse(html))
    }

    // MARK: 评论挑选

    /// 置顶评论在前，其余保持服务端的热门顺序；去重、跳过本机屏蔽的用户，最多三条。
    public static func selectComments(pinned: [Entity], popular: [Entity],
                                      blockedUIDs: Set<String> = []) -> [ExportComment] {
        let candidates = pinned.map { ExportComment(entity: $0, isPinned: true) }
            + popular.filter(isTop).map { ExportComment(entity: $0, isPinned: true) }
            + popular.map { ExportComment(entity: $0, isPinned: isTop($0)) }
        var seen = Set<String>()
        var result: [ExportComment] = []
        for candidate in candidates {
            let id = candidate.entity.entityID
            guard !id.isEmpty, !blockedUIDs.contains(candidate.entity.uid), seen.insert(id).inserted else { continue }
            result.append(candidate)
            if result.count == maxComments { break }
        }
        return result
    }

    private static func isTop(_ reply: Entity) -> Bool {
        (reply["is_top"].int ?? reply["isTop"].int ?? 0) > 0
    }

    // MARK: 输出

    /// 文档引用的图片地址，按出现顺序去重。
    public var imageURLs: [String] {
        var seen = Set<String>()
        return HTMLFragment.elements(named: "img", in: body)
            .compactMap { $0.attributes["src"] }
            .filter { seen.insert($0).inserted }
    }

    /// 建议的文件名（不含扩展名），已去掉各系统不允许的字符。
    public var fileName: String {
        var safe = title.replacingOccurrences(of: #"[<>:"/\\|?*\x00-\x1f]"#, with: "_", options: .regularExpression)
            .replacingOccurrences(of: #"[.\s]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        safe = String(safe.prefix(70))
        let reserved = #"^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)"#
        if safe.isEmpty || safe.range(of: reserved, options: [.regularExpression, .caseInsensitive]) != nil {
            safe = "动态"
        }
        let suffix = feedID.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        return "\(safe)-\(suffix)"
    }

    /// Markdown 文本，图片保留在线链接。
    public var markdown: String { MarkdownWriter.render(body) }

    /// 图片仍指向在线地址的 HTML。页面的内容安全策略只允许内嵌图片，离线阅读请用 `offlineHTML`。
    var html: String { page(HTMLFragment.serialize(body)) }

    /// 单文件离线 HTML。`images` 把图片地址映射到 data URI；缺失或格式不被接受的图片改为“图片未保存”来源链接。
    public func offlineHTML(images: [String: String]) -> String {
        let embedded = HTMLFragment.mapElements(body) { element -> [HTMLNode] in
            guard element.tag == "img", let url = element.attributes["src"] else { return [.element(element)] }
            if let data = images[url], ExportDocument.isImageDataURI(data) {
                var image = element
                image.attributes["src"] = data
                return [.element(image)]
            }
            let caption = element.attributes["alt"].flatMap { $0.isEmpty ? nil : $0 } ?? "查看来源"
            return [.element(HTMLElement(tag: "a", attributes: ["href": url], children: [.text("图片未保存：\(caption)")]))]
        }
        return page(HTMLFragment.serialize(embedded))
    }

    /// 单文件离线 HTML，图片字节由调用方按地址提供；返回 nil 或不是受支持的位图时按缺失处理。
    public func offlineHTML(imageData: (String) -> Data?) -> String {
        var images: [String: String] = [:]
        for url in imageURLs {
            if let data = imageData(url), let uri = ExportDocument.dataURI(for: data) { images[url] = uri }
        }
        return offlineHTML(images: images)
    }

    /// 按文件头识别 PNG、JPEG、GIF、WebP，其余格式不内嵌。
    public static func imageMIME(of data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        func starts(_ signature: [UInt8]) -> Bool { bytes.count >= signature.count && Array(bytes.prefix(signature.count)) == signature }
        if starts([137, 80, 78, 71, 13, 10, 26, 10]) { return "image/png" }
        if starts([255, 216, 255]) { return "image/jpeg" }
        if starts(Array("GIF87a".utf8)) || starts(Array("GIF89a".utf8)) { return "image/gif" }
        if bytes.count >= 12, Array(bytes[0..<4]) == Array("RIFF".utf8), Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return "image/webp"
        }
        return nil
    }

    /// 把图片字节编码成 data URI；不是受支持的位图时返回 nil。
    public static func dataURI(for data: Data) -> String? {
        imageMIME(of: data).map { "data:\($0);base64,\(data.base64EncodedString())" }
    }

    private static func isImageDataURI(_ value: String) -> Bool {
        value.range(of: "^data:image/(png|jpeg|gif|webp);base64,", options: .regularExpression) != nil
    }

    private func page(_ body: String) -> String {
        "<!doctype html><html lang=\"zh-CN\"><head>"
            + "<meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src &#39;none&#39;; "
            + "img-src data:; style-src &#39;unsafe-inline&#39;; base-uri &#39;none&#39;; form-action &#39;none&#39;\">"
            + "<title>\(HTMLEntities.escapeText(title))</title><style>"
            + "body{max-width:840px;margin:32px auto;padding:0 20px;color:#202124;background:#fff;"
            + "font:16px/1.7 system-ui,sans-serif;overflow-wrap:anywhere}"
            + "img{max-width:100%;height:auto}a{color:#1756a9}pre{overflow:auto;padding:16px;"
            + "background:#f2f3f5;white-space:pre}code{font-family:monospace}"
            + "table{border-collapse:collapse;display:block;overflow:auto}td,th{border:1px solid #bbb;padding:6px 12px}"
            + "blockquote{border-left:4px solid #bbb;padding-left:16px;margin-left:0;color:#555}"
            + "figcaption{color:#555}section{border-bottom:1px solid #ddd;padding-bottom:16px}"
            + "@media print{body{margin:0;max-width:none}pre{white-space:pre-wrap}img{break-inside:avoid}}"
            + "</style></head><body>\(body)</body></html>"
    }

    // MARK: 正文拼装

    private static func plainText(_ html: String) -> String {
        HTMLFragment.text(of: HTMLFragment.parse(html)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func author(_ entity: Entity) -> String {
        entity["userInfo"]["username"].text ?? entity["username"].text ?? "未知作者"
    }

    private static func metadata(_ entity: Entity, timeZone: TimeZone) -> String {
        var date = ""
        if let seconds = entity.dateline, seconds > 0, seconds < 8_640_000_000_000 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        }
        return "<p>作者：\(HTMLEntities.escapeText(author(entity)))\(date.isEmpty ? "" : "<br>发布时间：\(date)")</p>"
    }

    /// 图文帖的一个分段。
    private struct Part {
        var type: String
        var message = ""
        var url = ""
        var title = ""
        var description = ""
    }

    private static func feedBody(_ entity: Entity, depth: Int = 0) -> String {
        var html = ""
        var parts: [Part] = []
        let raw = entity.messageRawOutput
        if !raw.isEmpty, raw != "null" {
            if let items = JSON.parse(raw)?.array, items.allSatisfy({ $0.object != nil }) {
                parts = items.compactMap { item -> Part? in
                    guard let type = item["type"].string, ["text", "image", "shareUrl"].contains(type) else { return nil }
                    return Part(type: type, message: item["message"].string ?? "", url: item["url"].string ?? "",
                                title: item["title"].text ?? item["url"].string ?? "",
                                description: item["description"].string ?? "")
                }
                if !parts.isEmpty, !entity.messageCover.isEmpty {
                    parts.insert(Part(type: "image", url: entity.messageCover), at: 0)
                }
            } else {
                html += "<p>图文结构未能解析，以下仅保存已取得的摘要。</p>"
            }
        }
        if parts.isEmpty {
            html += content(entity.message)
            for url in entity.pictures { html += image(url, caption: "") }
        } else {
            for part in parts {
                switch part.type {
                case "text":
                    html += content(part.message)
                case "image":
                    html += image(part.url, caption: part.description)
                default:
                    html += "<p><a href=\"\(HTMLEntities.escapeAttribute(part.url))\">\(HTMLEntities.escapeText(part.title))</a></p>"
                }
            }
        }
        if let forward = entity.forwardSource, depth < 3 {
            html += "<blockquote><p>转发自：\(HTMLEntities.escapeText(author(forward)))</p>"
            let forwardTitle = plainText(forward.messageTitle)
            if !forwardTitle.isEmpty { html += "<h2>\(HTMLEntities.escapeText(forwardTitle))</h2>" }
            html += feedBody(forward, depth: depth + 1) + "</blockquote>"
        } else if entity.forwardSource == nil, !(entity["forwardSourceType"].string ?? "").isEmpty {
            html += "<p>转发内容已不可用</p>"
        }
        return html
    }

    private static func image(_ url: String, caption: String) -> String {
        "<figure><img src=\"\(HTMLEntities.escapeAttribute(url))\" alt=\"\(HTMLEntities.escapeAttribute(caption))\">"
            + (caption.isEmpty ? "" : "<figcaption>\(HTMLEntities.escapeText(caption))</figcaption>") + "</figure>"
    }

    /// 一段正文：识别出 Markdown 时按 Markdown 转换，否则当作酷安的 HTML 片段，换行转成 `<br>`。
    private static func content(_ value: String) -> String {
        if let html = MarkdownSource.html(from: value) { return html }
        let nodes = lineBreaks(HTMLFragment.parse(value.replacingOccurrences(of: "<!--break-->", with: "")))
        return "<div>\(HTMLFragment.serialize(nodes))</div>"
    }

    /// 正文里的换行是硬换行；`pre`、`code` 内保持原样。
    private static func lineBreaks(_ nodes: [HTMLNode]) -> [HTMLNode] {
        nodes.flatMap { node -> [HTMLNode] in
            switch node {
            case .text(let text):
                guard text.contains("\n") else { return [node] }
                var result: [HTMLNode] = []
                for (index, part) in text.components(separatedBy: "\n").enumerated() {
                    if index > 0 { result.append(.element(HTMLElement(tag: "br"))) }
                    if !part.isEmpty { result.append(.text(part)) }
                }
                return result
            case .element(var element):
                guard element.tag != "pre", element.tag != "code" else { return [node] }
                element.children = lineBreaks(element.children)
                return [.element(element)]
            }
        }
    }
}
