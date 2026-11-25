import Foundation

/// 导出用的 HTML 节点：文本或元素。
indirect enum HTMLNode: Equatable, Sendable {
    case text(String)
    case element(HTMLElement)
}

/// 元素节点，标签名一律小写。
struct HTMLElement: Equatable, Sendable {
    var tag: String
    var attributes: [String: String] = [:]
    var children: [HTMLNode] = []
}

/// 宽松的 HTML 片段解析与序列化，只覆盖酷安正文和导出文档会出现的结构。
enum HTMLFragment {
    static let voidTags: Set<String> = [
        "br", "hr", "img", "input", "meta", "link", "area", "base", "col", "embed", "source", "track", "wbr",
    ]
    private static let rawTextTags: Set<String> = ["script", "style"]
    /// 遇到这些标签时，尚未闭合的段落自动结束。
    private static let paragraphBreakers: Set<String> = [
        "p", "div", "ul", "ol", "pre", "blockquote", "table", "hr", "section", "figure",
        "h1", "h2", "h3", "h4", "h5", "h6",
    ]
    /// 自动闭合向外查找时不会越过的容器。
    private static let scopes: Set<String> = [
        "div", "section", "blockquote", "li", "td", "th", "table", "ul", "ol", "figure",
    ]

    /// 嵌套层数上限；更深的开始标签被忽略，内容并入外层，避免后续递归处理过深。
    private static let maxDepth = 64

    private struct Frame {
        var tag: String
        var attributes: [String: String]
        var children: [HTMLNode] = []
    }

    static func parse(_ html: String) -> [HTMLNode] {
        let scalars = Array(html.unicodeScalars)
        let count = scalars.count
        var stack = [Frame(tag: "", attributes: [:])]
        var buffer = String.UnicodeScalarView()
        var index = 0

        func flushText() {
            guard !buffer.isEmpty else { return }
            stack[stack.count - 1].children.append(.text(HTMLEntities.decode(String(buffer))))
            buffer = String.UnicodeScalarView()
        }
        func closeTop() {
            let frame = stack.removeLast()
            stack[stack.count - 1].children.append(
                .element(HTMLElement(tag: frame.tag, attributes: frame.attributes, children: frame.children)))
        }
        func close(_ tag: String) {
            guard let position = stack.lastIndex(where: { $0.tag == tag }), position > 0 else { return }
            while stack.count > position { closeTop() }
        }
        /// 闭合最近一个未被容器隔开的同类元素（如连续的 `<li>`、`<p>`）。
        func closeImplied(_ tags: Set<String>, boundary: Set<String>) {
            for position in stride(from: stack.count - 1, to: 0, by: -1) {
                let tag = stack[position].tag
                if tags.contains(tag) {
                    while stack.count > position { closeTop() }
                    return
                }
                if boundary.contains(tag) { return }
            }
        }
        func hasPrefix(_ text: String, at start: Int) -> Bool {
            var position = start
            for scalar in text.unicodeScalars {
                guard position < count, scalars[position] == scalar else { return false }
                position += 1
            }
            return true
        }
        func find(_ text: String, from start: Int, caseInsensitive: Bool = false) -> Int? {
            let needle = Array(text.unicodeScalars)
            guard !needle.isEmpty, count >= needle.count else { return nil }
            var position = start
            while position <= count - needle.count {
                var matched = true
                for offset in 0..<needle.count {
                    let scalar = scalars[position + offset]
                    let same = caseInsensitive
                        ? String(scalar).lowercased() == String(needle[offset]).lowercased()
                        : scalar == needle[offset]
                    if !same { matched = false; break }
                }
                if matched { return position }
                position += 1
            }
            return nil
        }

        while index < count {
            let scalar = scalars[index]
            guard scalar == "<", index + 1 < count else {
                buffer.append(scalar)
                index += 1
                continue
            }
            let next = scalars[index + 1]
            if hasPrefix("<!--", at: index) {
                index = find("-->", from: index + 4).map { $0 + 3 } ?? count
                continue
            }
            if next == "!" || next == "?" {
                index = find(">", from: index + 2).map { $0 + 1 } ?? count
                continue
            }
            if next == "/", index + 2 < count, isLetter(scalars[index + 2]) {
                var cursor = index + 2
                let name = readName(scalars, &cursor)
                guard let end = find(">", from: cursor) else {
                    buffer.append(scalar)
                    index += 1
                    continue
                }
                flushText()
                close(name)
                index = end + 1
                continue
            }
            guard isLetter(next), let tag = readTag(scalars, from: index + 1) else {
                buffer.append(scalar)
                index += 1
                continue
            }
            flushText()
            index = tag.end
            if paragraphBreakers.contains(tag.name) { closeImplied(["p"], boundary: scopes) }
            switch tag.name {
            case "li": closeImplied(["li"], boundary: ["ul", "ol"])
            case "tr": closeImplied(["tr"], boundary: ["table"])
            case "td", "th": closeImplied(["td", "th"], boundary: ["tr", "table"])
            default: break
            }
            if voidTags.contains(tag.name) || tag.selfClosing {
                stack[stack.count - 1].children.append(.element(HTMLElement(tag: tag.name, attributes: tag.attributes)))
            } else if rawTextTags.contains(tag.name) {
                let end = find("</" + tag.name, from: index, caseInsensitive: true) ?? count
                var raw = String.UnicodeScalarView()
                raw.append(contentsOf: scalars[index..<end])
                stack[stack.count - 1].children.append(.element(
                    HTMLElement(tag: tag.name, attributes: tag.attributes, children: [.text(String(raw))])))
                index = find(">", from: end).map { $0 + 1 } ?? count
            } else if stack.count <= maxDepth {
                stack.append(Frame(tag: tag.name, attributes: tag.attributes))
            }
        }
        flushText()
        while stack.count > 1 { closeTop() }
        return stack[0].children
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" || scalar == "\u{0C}"
    }

    private static func readName(_ scalars: [Unicode.Scalar], _ cursor: inout Int) -> String {
        var name = String.UnicodeScalarView()
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            guard isLetter(scalar) || (scalar >= "0" && scalar <= "9") || scalar == "-" || scalar == ":" else { break }
            name.append(scalar)
            cursor += 1
        }
        return String(name).lowercased()
    }

    private struct Tag {
        var name: String
        var attributes: [String: String]
        var selfClosing: Bool
        var end: Int
    }

    /// 从标签名开始读到 `>`；读不到闭合符时返回 nil，调用方把 `<` 当作普通文本。
    private static func readTag(_ scalars: [Unicode.Scalar], from start: Int) -> Tag? {
        var cursor = start
        let name = readName(scalars, &cursor)
        guard !name.isEmpty else { return nil }
        var attributes: [String: String] = [:]
        var selfClosing = false
        while cursor < scalars.count {
            let scalar = scalars[cursor]
            if scalar == ">" {
                return Tag(name: name, attributes: attributes, selfClosing: selfClosing, end: cursor + 1)
            }
            if isSpace(scalar) {
                cursor += 1
                continue
            }
            if scalar == "/" {
                selfClosing = true
                cursor += 1
                continue
            }
            selfClosing = false
            var key = String.UnicodeScalarView()
            while cursor < scalars.count, !isSpace(scalars[cursor]),
                  scalars[cursor] != "=", scalars[cursor] != ">", scalars[cursor] != "/" {
                key.append(scalars[cursor])
                cursor += 1
            }
            while cursor < scalars.count, isSpace(scalars[cursor]) { cursor += 1 }
            var value = String.UnicodeScalarView()
            if cursor < scalars.count, scalars[cursor] == "=" {
                cursor += 1
                while cursor < scalars.count, isSpace(scalars[cursor]) { cursor += 1 }
                if cursor < scalars.count, scalars[cursor] == "\"" || scalars[cursor] == "'" {
                    let quote = scalars[cursor]
                    cursor += 1
                    while cursor < scalars.count, scalars[cursor] != quote {
                        value.append(scalars[cursor])
                        cursor += 1
                    }
                    guard cursor < scalars.count else { return nil }
                    cursor += 1
                } else {
                    while cursor < scalars.count, !isSpace(scalars[cursor]), scalars[cursor] != ">" {
                        value.append(scalars[cursor])
                        cursor += 1
                    }
                }
            }
            let attribute = String(key).lowercased()
            if !attribute.isEmpty, attributes[attribute] == nil {
                attributes[attribute] = HTMLEntities.decode(String(value))
            }
        }
        return nil
    }

    // MARK: 序列化

    static func serialize(_ nodes: [HTMLNode]) -> String {
        var output = ""
        for node in nodes { write(node, to: &output) }
        return output
    }

    private static func write(_ node: HTMLNode, to output: inout String) {
        switch node {
        case .text(let text):
            output += HTMLEntities.escapeText(text)
        case .element(let element):
            output += "<" + element.tag
            for key in element.attributes.keys.sorted() {
                output += " \(key)=\"\(HTMLEntities.escapeAttribute(element.attributes[key] ?? ""))\""
            }
            output += ">"
            guard !voidTags.contains(element.tag) else { return }
            for child in element.children { write(child, to: &output) }
            output += "</\(element.tag)>"
        }
    }

    // MARK: 查询

    /// 节点内全部文本，相当于 DOM 的 `textContent`。
    static func text(of nodes: [HTMLNode]) -> String {
        nodes.map { node -> String in
            switch node {
            case .text(let text): return text
            case .element(let element): return text(of: element.children)
            }
        }.joined()
    }

    /// 按文档顺序收集指定标签的元素（含后代）。
    static func elements(named tag: String, in nodes: [HTMLNode]) -> [HTMLElement] {
        nodes.flatMap { node -> [HTMLElement] in
            guard case .element(let element) = node else { return [] }
            return (element.tag == tag ? [element] : []) + elements(named: tag, in: element.children)
        }
    }

    /// 自底向上改写每个元素；闭包返回替换它的节点序列。
    static func mapElements(_ nodes: [HTMLNode], _ transform: (HTMLElement) -> [HTMLNode]) -> [HTMLNode] {
        nodes.flatMap { node -> [HTMLNode] in
            guard case .element(var element) = node else { return [node] }
            element.children = mapElements(element.children, transform)
            return transform(element)
        }
    }
}

/// HTML 实体的解码与转义。
enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "hellip": "…", "mdash": "—", "ndash": "–", "middot": "·", "ldquo": "“", "rdquo": "”",
        "lsquo": "‘", "rsquo": "’", "yen": "¥", "copy": "©", "reg": "®", "times": "×",
        "laquo": "«", "raquo": "»", "bull": "•", "trade": "™", "deg": "°",
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "&", let end = text[index...].prefix(12).firstIndex(of: ";") {
                let name = text[text.index(after: index)..<end]
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(UnicodeScalar.init).map { String($0) }
                } else if name.hasPrefix("#") {
                    replacement = UInt32(name.dropFirst()).flatMap(UnicodeScalar.init).map { String($0) }
                } else {
                    replacement = named[String(name)]
                }
                if let replacement {
                    result += replacement
                    index = text.index(after: end)
                    continue
                }
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    static func escapeText(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func escapeAttribute(_ text: String) -> String {
        escapeText(text)
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// 导出前的净化：只保留排版标签、http(s) 链接和只读复选框，去掉脚本与事件属性。
enum HTMLSanitizer {
    private static let allowed: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "p", "br", "div", "section", "strong", "b", "em", "i",
        "del", "s", "u", "blockquote", "pre", "code", "ul", "ol", "li", "hr", "table", "thead", "tbody",
        "tfoot", "tr", "th", "td", "a", "img", "figure", "figcaption", "input",
    ]
    /// 连同内容一起丢弃的标签。
    private static let removed: Set<String> = [
        "script", "style", "iframe", "object", "embed", "svg", "math", "form", "video", "audio",
    ]

    static func sanitize(_ nodes: [HTMLNode]) -> [HTMLNode] {
        nodes.flatMap { node -> [HTMLNode] in
            guard case .element(let element) = node else { return [node] }
            if removed.contains(element.tag) { return [] }
            let children = sanitize(element.children)
            guard allowed.contains(element.tag) else { return children }
            var attributes: [String: String] = [:]
            switch element.tag {
            case "a":
                if let url = safeURL(element.attributes["href"] ?? "", image: false) { attributes["href"] = url }
            case "img":
                guard let url = safeURL(element.attributes["src"] ?? "", image: true) else { return [] }
                attributes["src"] = url
                attributes["alt"] = element.attributes["alt"] ?? ""
            case "input":
                guard element.attributes["type"]?.lowercased() == "checkbox" else { return [] }
                attributes["type"] = "checkbox"
                attributes["disabled"] = ""
                if element.attributes["checked"] != nil { attributes["checked"] = "" }
            case "ol":
                if let start = Int(element.attributes["start"] ?? "") { attributes["start"] = String(start) }
            case "code":
                if let name = element.attributes["class"],
                   name.range(of: #"^language-[\w+-]+$"#, options: .regularExpression) != nil {
                    attributes["class"] = name
                }
            default:
                break
            }
            return [.element(HTMLElement(tag: element.tag, attributes: attributes, children: children))]
        }
    }

    /// 只放行带主机名的 http(s) 地址；站内相对链接补全为酷安网页地址。
    static func safeURL(_ raw: String, image: Bool) -> String? {
        var value = raw
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("//") {
            value = "https:" + value
        } else if !image, value.hasPrefix("/") {
            value = "https://www.coolapk.com" + value
        }
        guard !value.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F || $0 == "\\" }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        return value
    }
}
