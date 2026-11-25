import Foundation

/// 过滤用的极简 HTML 节点：只区分文字和元素。
indirect enum FilterHTMLNode: Equatable {
    case text(String)
    case element(name: String, attributes: [String: String], children: [FilterHTMLNode])
}

/// 宽松的 HTML 片段解析，够用来取可见文字、话题链接和剔除引用。
enum FilterHTML {
    private static let voidElements: Set<String> = ["br", "img", "hr", "input", "meta", "link", "wbr", "source"]
    private static let rawTextElements: Set<String> = ["script", "style"]
    private static let hiddenElements: Set<String> = ["script", "style", "template", "noscript"]
    private static let blockElements: Set<String> = ["p", "div", "br", "li", "blockquote", "section", "h1", "h2", "h3"]
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}",
        "hellip": "…", "mdash": "—", "ndash": "–", "middot": "·", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”",
    ]

    private struct OpenElement {
        var name: String
        var attributes: [String: String]
        var children: [FilterHTMLNode] = []
    }

    static func parse(_ source: String) -> [FilterHTMLNode] {
        let scalars = Array(source.unicodeScalars)
        let count = scalars.count
        var stack = [OpenElement(name: "", attributes: [:])]
        var text = String.UnicodeScalarView()
        var index = 0

        func flushText() {
            guard !text.isEmpty else { return }
            stack[stack.count - 1].children.append(.text(decodeEntities(String(text))))
            text = String.UnicodeScalarView()
        }
        func closeTop() {
            let closed = stack.removeLast()
            stack[stack.count - 1].children.append(
                .element(name: closed.name, attributes: closed.attributes, children: closed.children))
        }
        func find(_ needle: String, from start: Int) -> Int? {
            let target = Array(needle.unicodeScalars)
            guard !target.isEmpty, count >= target.count, start <= count - target.count else { return nil }
            for position in start...(count - target.count)
            where zip(target, scalars[position...]).allSatisfy({ lowered($1) == $0 }) {
                return position
            }
            return nil
        }

        while index < count {
            let scalar = scalars[index]
            guard scalar == "<", index + 1 < count else {
                text.append(scalar)
                index += 1
                continue
            }
            let next = scalars[index + 1]
            if next == "!" || next == "?" {
                flushText()
                let isComment = index + 3 < count && scalars[index + 2] == "-" && scalars[index + 3] == "-"
                let end = find(isComment ? "-->" : ">", from: index + 2)
                index = end.map { $0 + (isComment ? 3 : 1) } ?? count
            } else if next == "/", index + 2 < count, isLetter(scalars[index + 2]) {
                flushText()
                var cursor = index + 2
                let name = readName(scalars, &cursor)
                index = (find(">", from: cursor) ?? count - 1) + 1
                if let position = stack.lastIndex(where: { $0.name == name }), position > 0 {
                    while stack.count > position { closeTop() }
                }
            } else if isLetter(next) {
                flushText()
                var cursor = index + 1
                let name = readName(scalars, &cursor)
                let (attributes, selfClosing) = readAttributes(scalars, &cursor)
                index = cursor
                if rawTextElements.contains(name) {
                    let end = find("</\(name)", from: index)
                    let raw = String(String.UnicodeScalarView(scalars[index..<(end ?? count)]))
                    stack[stack.count - 1].children.append(
                        .element(name: name, attributes: attributes, children: raw.isEmpty ? [] : [.text(raw)]))
                    index = end.map { (find(">", from: $0) ?? count - 1) + 1 } ?? count
                } else if selfClosing || voidElements.contains(name) {
                    stack[stack.count - 1].children.append(.element(name: name, attributes: attributes, children: []))
                } else {
                    stack.append(OpenElement(name: name, attributes: attributes))
                }
            } else {
                text.append(scalar)
                index += 1
            }
        }
        flushText()
        while stack.count > 1 { closeTop() }
        return stack[0].children
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func lowered(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32) ?? scalar : scalar
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\n" || scalar == "\t" || scalar == "\r" || scalar == "\u{0C}"
    }

    private static func readName(_ scalars: [Unicode.Scalar], _ cursor: inout Int) -> String {
        var name = String.UnicodeScalarView()
        while cursor < scalars.count, !isSpace(scalars[cursor]), scalars[cursor] != ">", scalars[cursor] != "/" {
            name.append(lowered(scalars[cursor]))
            cursor += 1
        }
        return String(name)
    }

    /// 读到标签结束的 `>` 之后；返回属性和是否自闭合。
    private static func readAttributes(_ scalars: [Unicode.Scalar], _ cursor: inout Int) -> ([String: String], Bool) {
        var attributes: [String: String] = [:]
        var selfClosing = false
        let count = scalars.count
        while cursor < count {
            while cursor < count, isSpace(scalars[cursor]) { cursor += 1 }
            guard cursor < count else { break }
            if scalars[cursor] == ">" {
                cursor += 1
                break
            }
            if scalars[cursor] == "/" {
                selfClosing = true
                cursor += 1
                continue
            }
            selfClosing = false
            var name = String.UnicodeScalarView()
            while cursor < count, !isSpace(scalars[cursor]), !"=>/".unicodeScalars.contains(scalars[cursor]) {
                name.append(lowered(scalars[cursor]))
                cursor += 1
            }
            while cursor < count, isSpace(scalars[cursor]) { cursor += 1 }
            var value = String.UnicodeScalarView()
            if cursor < count, scalars[cursor] == "=" {
                cursor += 1
                while cursor < count, isSpace(scalars[cursor]) { cursor += 1 }
                if cursor < count, scalars[cursor] == "\"" || scalars[cursor] == "'" {
                    let quote = scalars[cursor]
                    cursor += 1
                    while cursor < count, scalars[cursor] != quote {
                        value.append(scalars[cursor])
                        cursor += 1
                    }
                    cursor += 1
                } else {
                    while cursor < count, !isSpace(scalars[cursor]), scalars[cursor] != ">" {
                        value.append(scalars[cursor])
                        cursor += 1
                    }
                }
            }
            if !name.isEmpty, attributes[String(name)] == nil {
                attributes[String(name)] = decodeEntities(String(value))
            }
        }
        return (attributes, selfClosing)
    }

    /// 解码数字实体和常见命名实体，其余原样保留。
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "&" else {
                result.append(scalars[index])
                index += 1
                continue
            }
            var cursor = index + 1
            var decoded: String?
            if cursor < scalars.count, scalars[cursor] == "#" {
                cursor += 1
                let isHex = cursor < scalars.count && (scalars[cursor] == "x" || scalars[cursor] == "X")
                if isHex { cursor += 1 }
                var digits = ""
                while cursor < scalars.count, digits.count < 8,
                      isHex ? scalars[cursor].properties.isASCIIHexDigit : ("0"..."9").contains(scalars[cursor]) {
                    digits.unicodeScalars.append(scalars[cursor])
                    cursor += 1
                }
                if let code = UInt32(digits, radix: isHex ? 16 : 10), code != 0, let scalar = Unicode.Scalar(code) {
                    decoded = String(scalar)
                    if cursor < scalars.count, scalars[cursor] == ";" { cursor += 1 }
                }
            } else {
                var name = ""
                while cursor < scalars.count, name.count < 10, isLetter(scalars[cursor]) {
                    name.unicodeScalars.append(scalars[cursor])
                    cursor += 1
                }
                if cursor < scalars.count, scalars[cursor] == ";", let value = namedEntities[name] {
                    decoded = value
                    cursor += 1
                }
            }
            if let decoded {
                result.append(contentsOf: decoded.unicodeScalars)
                index = cursor
            } else {
                result.append("&")
                index += 1
            }
        }
        return String(result)
    }

    private static func escape(_ text: String, attribute: Bool) -> String {
        var result = text.replacingOccurrences(of: "&", with: "&amp;")
        if attribute {
            result = result.replacingOccurrences(of: "\"", with: "&quot;")
        } else {
            result = result.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return result
    }

    static func serialize(_ nodes: [FilterHTMLNode]) -> String {
        var output = ""
        func write(_ node: FilterHTMLNode, raw: Bool) {
            switch node {
            case .text(let text):
                output += raw ? text : escape(text, attribute: false)
            case .element(let name, let attributes, let children):
                output += "<" + name
                for key in attributes.keys.sorted() {
                    output += " \(key)=\"\(escape(attributes[key] ?? "", attribute: true))\""
                }
                output += ">"
                guard !voidElements.contains(name) else { return }
                for child in children { write(child, raw: rawTextElements.contains(name)) }
                output += "</\(name)>"
            }
        }
        for node in nodes { write(node, raw: false) }
        return output
    }

    /// 去掉满足条件的元素（连同其内容）。
    static func removing(_ nodes: [FilterHTMLNode],
                         where shouldRemove: (String, [String: String]) -> Bool) -> [FilterHTMLNode] {
        nodes.compactMap { node in
            guard case .element(let name, let attributes, let children) = node else { return node }
            if shouldRemove(name, attributes) { return nil }
            return .element(name: name, attributes: attributes, children: removing(children, where: shouldRemove))
        }
    }

    /// 每个元素调用一次，深度优先。
    static func forEachElement(_ nodes: [FilterHTMLNode],
                               _ body: (String, [String: String], [FilterHTMLNode]) -> Void) {
        for case .element(let name, let attributes, let children) in nodes {
            body(name, attributes, children)
            forEachElement(children, body)
        }
    }

    /// 节点内全部文字，不做可见性判断。
    static func textContent(_ nodes: [FilterHTMLNode]) -> String {
        nodes.map { node -> String in
            switch node {
            case .text(let text): return text
            case .element(_, _, let children): return textContent(children)
            }
        }.joined()
    }

    /// 用户实际看得到的文字：不含属性、脚本样式和隐藏元素；块级元素处换行。
    static func visibleText(_ source: String) -> String {
        var buffer = ""
        func visit(_ node: FilterHTMLNode) {
            switch node {
            case .text(let text):
                buffer += text
            case .element(let name, let attributes, let children):
                if hiddenElements.contains(name) || attributes["hidden"] != nil
                    || attributes["aria-hidden"] == "true" { return }
                let isBlock = blockElements.contains(name)
                if isBlock { buffer += "\n" }
                children.forEach(visit)
                if isBlock { buffer += "\n" }
            }
        }
        parse(source).forEach(visit)
        return buffer
    }
}
