import CoolapkKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 酷安的消息是一小段 HTML：链接、换行和 `[表情]` 短代码。
/// 这里把它转成 SwiftUI 的 `Text`。
enum RichText {
    enum Node: Equatable {
        case text(String, bold: Bool)
        case link(String, href: String)
        case emoji(String)
        case badge(String)
        case photoIcon
    }

    /// 链接使用应用自己注册的 URL scheme（`c001apk://open?u=…`）。
    /// SwiftUI 通常交给 `openURL` 环境动作处理，但可选中文本和辅助功能
    /// 可能让点击改走系统；两种情况应用都能收到。
    static let linkScheme = "c001apk"
    static let linkHost = "open"

    // MARK: 解析

    /// 同时匹配带引号与不带引号的 `href` / `src` 属性（酷安部分 HTML 会省略引号）。
    private static let hrefPattern = try! NSRegularExpression(
        pattern: #"href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#, options: [.caseInsensitive])
    private static let srcPattern = try! NSRegularExpression(
        pattern: #"src\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#, options: [.caseInsensitive])
    private static let emojiPattern = try! NSRegularExpression(pattern: #"\[[^\[\]\s]{1,12}\]"#)
    private static let boldPattern = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)

    private static func extractAttribute(_ pattern: NSRegularExpression, in tag: String) -> String {
        let whole = NSRange(location: 0, length: (tag as NSString).length)
        guard let match = pattern.firstMatch(in: tag, range: whole) else { return "" }
        for group in 1...3 {
            let nsRange = match.range(at: group)
            if nsRange.location != NSNotFound, let range = Range(nsRange, in: tag) {
                return decodeEntities(String(tag[range]))
            }
        }
        return ""
    }

    /// 清理 `<a>` 内的 `[图片]` 短码，并保证指向图片地址的空标签仍有可点文字。
    private static func cleanedLinkText(_ raw: String, href: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if case .image = LinkRouter.resolve(href) { return "查看图片" }
            return ""
        }
        guard raw.contains("[图片]") else { return raw }
        let stripped = raw.replacingOccurrences(of: "[图片]", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? "查看图片" : stripped
    }

    private final class ParsedNodesBox: NSObject {
        let nodes: [Node]
        init(_ nodes: [Node]) { self.nodes = nodes }
    }

    /// 缓存常用短 HTML 的解析结果，避免列表滚动复用与父视图重算时重复在主线程跑多条正则。
    private static let parseCache: NSCache<NSString, ParsedNodesBox> = {
        let cache = NSCache<NSString, ParsedNodesBox>()
        cache.countLimit = 800
        return cache
    }()

    static func parse(_ html: String, emoji: Bool = true, markdown: Bool = false, photoLinkHref: String? = nil) -> [Node] {
        let cacheKey: NSString? = html.utf8.count <= 4096
            ? "\(emoji ? "1" : "0")|\(markdown ? "1" : "0")|\(photoLinkHref ?? "")|\(html)" as NSString
            : nil
        if let cacheKey, let cached = parseCache.object(forKey: cacheKey) {
            return cached.nodes
        }
        var nodes: [Node] = []
        var bold = false
        var linkHref: String?
        var linkText = ""
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            let text = decodeEntities(buffer)
            buffer = ""
            if linkHref != nil {
                linkText += text
            } else {
                appendText(text, bold: bold, emoji: emoji, markdown: markdown, photoLinkHref: photoLinkHref, to: &nodes)
            }
        }

        var index = html.startIndex
        while index < html.endIndex {
            let char = html[index]
            if char == "<", let close = html[index...].firstIndex(of: ">") {
                let tag = html[html.index(after: index)..<close]
                let lower = tag.lowercased()
                if lower.hasPrefix("!--") {
                    flush()
                } else if lower.hasPrefix("br") {
                    buffer += "\n"
                } else if lower.hasPrefix("a ") || lower == "a" {
                    flush()
                    linkHref = extractAttribute(hrefPattern, in: String(tag))
                    linkText = ""
                } else if lower.hasPrefix("/a") {
                    flush()
                    if let href = linkHref {
                        if href.isEmpty {
                            appendText(linkText, bold: bold, emoji: emoji, markdown: false, photoLinkHref: photoLinkHref, to: &nodes)
                        } else {
                            let label = cleanedLinkText(linkText, href: href)
                            if !label.isEmpty {
                                nodes.append(.link(label, href: href))
                            }
                        }
                    }
                    linkHref = nil
                    linkText = ""
                } else if lower.hasPrefix("img ") {
                    flush()
                    if linkHref == nil {
                        let src = extractAttribute(srcPattern, in: String(tag))
                        if case .image(let imageURL) = LinkRouter.resolve(src) {
                            nodes.append(.link("查看图片", href: imageURL))
                        }
                    }
                } else if lower == "b" || lower == "strong" || lower.hasPrefix("b ") || lower.hasPrefix("strong ") {
                    flush(); bold = true
                } else if lower == "/b" || lower == "/strong" {
                    flush(); bold = false
                } else if lower.hasPrefix("/p") || lower.hasPrefix("/div") || lower.hasPrefix("/li") || lower.hasPrefix("/h") {
                    buffer += "\n"
                } else if !isTagName(lower) {
                    // 不是标签（如 "a < b"）：保留该字符。
                    buffer.append(char)
                    index = html.index(after: index)
                    continue
                }
                index = html.index(after: close)
            } else {
                buffer.append(char)
                index = html.index(after: index)
            }
        }
        flush()
        if let href = linkHref, !href.isEmpty {
            let label = cleanedLinkText(linkText, href: href)
            if !label.isEmpty { nodes.append(.link(label, href: href)) }
        }
        if let cacheKey {
            parseCache.setObject(ParsedNodesBox(nodes), forKey: cacheKey)
        }
        return nodes
    }

    private static func isTagName(_ lower: String) -> Bool {
        guard let first = lower.unicodeScalars.first else { return false }
        return first == "/" || (first.isASCII && CharacterSet.letters.contains(first))
    }

    private static func appendText(
        _ text: String, bold: Bool, emoji: Bool, markdown: Bool, photoLinkHref: String?, to nodes: inout [Node]
    ) {
        guard !text.isEmpty else { return }
        if markdown, !bold {
            let ns = text as NSString
            var cursor = 0
            for match in boldPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if match.range.location > cursor {
                    appendEmojiText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                                    bold: false, emoji: emoji, photoLinkHref: photoLinkHref, to: &nodes)
                }
                appendEmojiText(ns.substring(with: match.range(at: 1)), bold: true, emoji: emoji, photoLinkHref: photoLinkHref, to: &nodes)
                cursor = match.range.location + match.range.length
            }
            if cursor < ns.length {
                appendEmojiText(ns.substring(from: cursor), bold: false, emoji: emoji, photoLinkHref: photoLinkHref, to: &nodes)
            }
        } else {
            appendEmojiText(text, bold: bold, emoji: emoji, photoLinkHref: photoLinkHref, to: &nodes)
        }
    }

    private static func appendEmojiText(
        _ text: String, bold: Bool, emoji: Bool, photoLinkHref: String?, to nodes: inout [Node]
    ) {
        let hasPhotoLink = photoLinkHref.map { !$0.isEmpty } ?? false
        guard (emoji || hasPhotoLink), text.contains("[") else {
            nodes.append(.text(text, bold: bold))
            return
        }
        let ns = text as NSString
        var cursor = 0
        for match in emojiPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            guard let file = EmojiMap.map[token] else { continue }
            if !emoji, !file.hasSuffix(".icon") { continue }
            if match.range.location > cursor {
                nodes.append(.text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), bold: bold))
            }
            if file.hasSuffix(".png") {
                nodes.append(.emoji(file))
            } else if file.hasSuffix(".icon") {
                if let photoLinkHref, !photoLinkHref.isEmpty {
                    nodes.append(.link("查看图片", href: photoLinkHref))
                } else {
                    nodes.append(.photoIcon)
                }
            } else {
                nodes.append(.badge(file))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length { nodes.append(.text(ns.substring(from: cursor), bold: bold)) }
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "hellip": "…", "mdash": "—", "ndash": "–", "middot": "·", "ldquo": "“", "rdquo": "”",
        "lsquo": "‘", "rsquo": "’", "yen": "¥", "copy": "©", "reg": "®", "times": "×",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            if char == "&", let end = text[index...].prefix(12).firstIndex(of: ";") {
                let name = text[text.index(after: index)..<end]
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    if let code = UInt32(name.dropFirst(2), radix: 16), let scalar = UnicodeScalar(code) {
                        replacement = String(scalar)
                    }
                } else if name.hasPrefix("#") {
                    if let code = UInt32(name.dropFirst()), let scalar = UnicodeScalar(code) {
                        replacement = String(scalar)
                    }
                } else {
                    replacement = namedEntities[String(name)]
                }
                if let replacement {
                    result += replacement
                    index = text.index(after: end)
                    continue
                }
            }
            result.append(char)
            index = text.index(after: index)
        }
        return result
    }

    /// 转义任意文本（如用户名），使其可以安全嵌入 HTML 片段。
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 去掉标签和表情短代码，用于摘要、拷贝和分享。
    static func plainText(_ html: String) -> String {
        parse(html, emoji: false).map { node -> String in
            switch node {
            case .text(let text, _): return text
            case .link(let text, _): return text
            default: return ""
            }
        }.joined()
    }

    // MARK: 渲染

    static func linkURL(for href: String) -> URL? {
        var components = URLComponents()
        components.scheme = linkScheme
        components.host = linkHost
        components.queryItems = [URLQueryItem(name: "u", value: href)]
        return components.url
    }

    static func href(from url: URL) -> String? {
        guard url.scheme == linkScheme, url.host == linkHost else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "u" }?.value
    }

    @MainActor private static var emojiCache: [String: PlatformImage] = [:]
    @MainActor private static var renderedTextCache: [RenderedTextKey: Text] = [:]

    private struct RenderedTextKey: Hashable {
        let html: String
        let fontSize: Int
        let weight: Font.Weight
        let emoji: Bool
        let markdown: Bool
        let photoLinkHref: String
    }

    /// 缓存构建完成的 `Text`（含属性字符串与表情插图），避免滚动复用或卡片刷新时重复组装 `AttributedString` 与 `URLComponents`。
    @MainActor
    static func renderedText(
        html: String,
        fontSize: CGFloat,
        weight: Font.Weight = .regular,
        emoji: Bool,
        markdown: Bool,
        photoLinkHref: String?
    ) -> Text {
        let canCache = html.utf8.count <= 4096
        let key = canCache ? RenderedTextKey(
            html: html,
            fontSize: Int((fontSize * 10).rounded()),
            weight: weight,
            emoji: emoji,
            markdown: markdown,
            photoLinkHref: photoLinkHref ?? ""
        ) : nil
        if let key, let cached = renderedTextCache[key] {
            return cached
        }
        let nodes = parse(html, emoji: emoji, markdown: markdown, photoLinkHref: photoLinkHref)
        let built = text(nodes, fontSize: fontSize, weight: weight)
        if let key {
            if renderedTextCache.count >= 600 {
                renderedTextCache.removeAll(keepingCapacity: true)
            }
            renderedTextCache[key] = built
        }
        return built
    }

    /// 取指定边长的表情图片（带缓存）。
    @MainActor
    static func emojiImage(_ file: String, size: CGFloat) -> PlatformImage? {
        let key = "\(file)@\(Int(size.rounded()))"
        if let cached = emojiCache[key] { return cached }
        guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "emojis") else { return nil }
        #if os(macOS)
        guard let source = NSImage(contentsOf: url), let copy = source.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: size, height: size)
        let scaled = copy
        #else
        guard let source = UIImage(contentsOfFile: url.path) else { return nil }
        let target = CGSize(width: size, height: size)
        let scaled = UIGraphicsImageRenderer(size: target).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
        #endif
        emojiCache[key] = scaled
        return scaled
    }

    /// 生成一个 `Text`。连续的文字和链接合并成一个属性字符串，
    /// 只有行内图片需要单独成段。
    @MainActor
    static func text(_ nodes: [Node], fontSize: CGFloat, weight: Font.Weight = .regular, tint: Color = .brand) -> Text {
        var result: Text?
        var pending = AttributedString()
        let emojiSize = (fontSize * 1.35).rounded()

        func append(_ segment: Text) {
            result = result.map { Text("\($0)\(segment)") } ?? segment
        }
        func flush() {
            guard !pending.characters.isEmpty else { return }
            append(Text(pending))
            pending = AttributedString()
        }

        for node in nodes {
            switch node {
            case .text(let string, let bold):
                var run = AttributedString(string)
                run.font = .system(size: fontSize, weight: bold ? .semibold : weight)
                pending.append(run)
            case .link(let string, let href):
                var run = AttributedString(string)
                run.font = .system(size: fontSize, weight: weight)
                run.foregroundColor = tint
                run.link = linkURL(for: href)
                pending.append(run)
            case .badge(let label):
                var run = AttributedString(" \(label) ")
                run.font = .system(size: max(fontSize - 3, 9), weight: .bold)
                run.foregroundColor = tint
                pending.append(run)
            case .emoji(let file):
                if let image = emojiImage(file, size: emojiSize) {
                    flush()
                    append(Text(Image(platformImage: image)).baselineOffset(-emojiSize * 0.22))
                }
            case .photoIcon:
                flush()
                append(Text(Image(systemName: "photo")).font(.system(size: fontSize)).foregroundColor(.secondary))
            }
        }
        flush()
        return result ?? Text(verbatim: "")
    }
}

/// 渲染一段酷安 HTML。点击链接走 `openURL`，由根视图路由到应用内页面。
struct RichTextView: View {
    let html: String
    var fontSize: CGFloat?
    var weight: Font.Weight = .regular
    var lineLimit: Int?
    var markdown = false
    /// 所属帖子或评论：点开正文里的图片链接时，一并带出多图与实况元数据。
    var mediaSource: Entity?
    /// 所属评论附带的图片：把正文里裸露的 `[图片]` 占位变为可点击链接。
    var fallbackPictures: [String] = []
    /// 卡片内正文的点击兜底：iPadOS 上包含 `.link` 属性的 `Text` 会拦截整个文本框的点击手势，
    /// 导致点在普通文字上时外层卡片的 `.onTapGesture` 收不到事件。这里用并发点击手势透传给卡片，
    /// 真正点到链接时由 `openURL` 里的 `noteLinkActivated()` 抑制卡片打开。
    var onCardTap: (() -> Void)? = nil

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator: Navigator?

    var body: some View {
        let size = fontSize ?? app.settings.fontSize
        let text = RichText.renderedText(
            html: html,
            fontSize: size,
            weight: weight,
            emoji: app.settings.showEmoji,
            markdown: markdown,
            photoLinkHref: fallbackPictures.first
        )
        .lineSpacing(size * 0.32)
        .lineLimit(lineLimit)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CardTapPassthrough(action: onCardTap))

        if mediaSource != nil || !fallbackPictures.isEmpty {
            text.environment(\.openURL, OpenURLAction { url in
                guard let href = RichText.href(from: url) else { return .systemAction }
                navigator?.noteLinkActivated()
                if case .image(let imageURL) = LinkRouter.resolve(href) {
                    openImage(imageURL)
                    return .handled
                }
                navigator?.open(href, app: app)
                return .handled
            })
        } else {
            text
        }
    }

    private func openImage(_ tappedURL: String) {
        let normalizedTapped = ImageURL.normalized(tappedURL)?.absoluteString
        var gallery = fallbackPictures
        if gallery.isEmpty, let mediaSource {
            gallery = mediaSource.entityType == "feed_reply" ? mediaSource.replyPictures : mediaSource.pictures
        }
        let index: Int
        if let existing = gallery.firstIndex(where: {
            $0 == tappedURL || (normalizedTapped != nil && ImageURL.normalized($0)?.absoluteString == normalizedTapped)
        }) {
            index = existing
        } else {
            gallery.insert(tappedURL, at: 0)
            index = 0
        }
        if let mediaSource {
            ImageViewer.show(media: mediaSource.mediaItems(for: gallery), index: index)
        } else {
            ImageViewer.show(urls: gallery, index: index)
        }
    }
}

private struct CardTapPassthrough: ViewModifier {
    let action: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let action {
            content.simultaneousGesture(TapGesture().onEnded(action))
        } else {
            content
        }
    }
}
