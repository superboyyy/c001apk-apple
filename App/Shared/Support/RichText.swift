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

    private static let hrefPattern = try! NSRegularExpression(pattern: #"href\s*=\s*(["'])(.*?)\1"#, options: [.caseInsensitive])
    private static let emojiPattern = try! NSRegularExpression(pattern: #"\[[^\[\]\s]{1,12}\]"#)
    private static let boldPattern = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)

    static func parse(_ html: String, emoji: Bool = true, markdown: Bool = false) -> [Node] {
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
                appendText(text, bold: bold, emoji: emoji, markdown: markdown, to: &nodes)
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
                    let tagString = String(tag)
                    let whole = NSRange(location: 0, length: (tagString as NSString).length)
                    if let match = hrefPattern.firstMatch(in: tagString, range: whole),
                       let hrefRange = Range(match.range(at: 2), in: tagString) {
                        linkHref = decodeEntities(String(tagString[hrefRange]))
                    } else {
                        linkHref = ""
                    }
                    linkText = ""
                } else if lower.hasPrefix("/a") {
                    flush()
                    if let href = linkHref {
                        if href.isEmpty {
                            appendText(linkText, bold: bold, emoji: emoji, markdown: false, to: &nodes)
                        } else if !linkText.isEmpty {
                            nodes.append(.link(linkText, href: href))
                        }
                    }
                    linkHref = nil
                    linkText = ""
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
        if let href = linkHref, !linkText.isEmpty { nodes.append(.link(linkText, href: href)) }
        return nodes
    }

    private static func isTagName(_ lower: String) -> Bool {
        guard let first = lower.unicodeScalars.first else { return false }
        return first == "/" || (first.isASCII && CharacterSet.letters.contains(first))
    }

    private static func appendText(_ text: String, bold: Bool, emoji: Bool, markdown: Bool, to nodes: inout [Node]) {
        guard !text.isEmpty else { return }
        if markdown, !bold {
            let ns = text as NSString
            var cursor = 0
            for match in boldPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if match.range.location > cursor {
                    appendEmojiText(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                                    bold: false, emoji: emoji, to: &nodes)
                }
                appendEmojiText(ns.substring(with: match.range(at: 1)), bold: true, emoji: emoji, to: &nodes)
                cursor = match.range.location + match.range.length
            }
            if cursor < ns.length {
                appendEmojiText(ns.substring(from: cursor), bold: false, emoji: emoji, to: &nodes)
            }
        } else {
            appendEmojiText(text, bold: bold, emoji: emoji, to: &nodes)
        }
    }

    private static func appendEmojiText(_ text: String, bold: Bool, emoji: Bool, to nodes: inout [Node]) {
        guard emoji, text.contains("[") else {
            nodes.append(.text(text, bold: bold))
            return
        }
        let ns = text as NSString
        var cursor = 0
        for match in emojiPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            guard let file = EmojiMap.map[token] else { continue }
            if match.range.location > cursor {
                nodes.append(.text(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), bold: bold))
            }
            if file.hasSuffix(".png") {
                nodes.append(.emoji(file))
            } else if file.hasSuffix(".icon") {
                nodes.append(.photoIcon)
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
                append(Text(Image(systemName: "photo")).font(.system(size: fontSize)).foregroundColor(tint))
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

    @Environment(AppModel.self) private var app

    var body: some View {
        let size = fontSize ?? app.settings.fontSize
        RichText.text(RichText.parse(html, emoji: app.settings.showEmoji, markdown: markdown), fontSize: size, weight: weight)
            .lineSpacing(size * 0.32)
            .lineLimit(lineLimit)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
