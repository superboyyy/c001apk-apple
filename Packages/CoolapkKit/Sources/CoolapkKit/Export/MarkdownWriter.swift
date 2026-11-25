import Foundation

/// 把净化后的 HTML 节点写成 Markdown。
enum MarkdownWriter {
    static func render(_ nodes: [HTMLNode]) -> String {
        let raw = nodes.map { markdown($0) }.joined()
        return collapseBlankLines(raw).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// 转义会被 Markdown 当作语法的字符。
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            if "\\`*_[]<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// 链接地址里的括号会提前结束 Markdown 链接。
    static func escapeURL(_ url: String) -> String {
        url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func block(_ text: String) -> String { "\n\n\(trimmed(text))\n\n" }

    private static func markdown(_ node: HTMLNode) -> String {
        guard case .element(let element) = node else {
            if case .text(let text) = node { return escape(text) }
            return ""
        }
        func children() -> String { element.children.map { markdown($0) }.joined() }
        switch element.tag {
        case "br":
            return "  \n"
        case "hr":
            return "\n\n---\n\n"
        case "p", "div", "section", "figure", "figcaption":
            return block(children())
        case "strong", "b":
            return "**\(children())**"
        case "em", "i":
            return "*\(children())*"
        case "del", "s":
            return "~~\(children())~~"
        case "a":
            guard let href = element.attributes["href"] else { return children() }
            return "[\(children())](\(escapeURL(href)))"
        case "img":
            let caption = (element.attributes["alt"] ?? "")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            return "![\(escape(caption))](\(escapeURL(element.attributes["src"] ?? "")))"
        case "input":
            return element.attributes["checked"] != nil ? "[x] " : "[ ] "
        case "pre":
            let code = HTMLFragment.elements(named: "code", in: element.children).first
            var text = HTMLFragment.text(of: code?.children ?? element.children)
            if text.hasSuffix("\n") { text.removeLast() }
            var fence = "```"
            while text.contains(fence) { fence += "`" }
            let language = (code?.attributes["class"] ?? "").replacingOccurrences(of: "language-", with: "")
            return "\n\n\(fence)\(language)\n\(text)\n\(fence)\n\n"
        case "code":
            let text = HTMLFragment.text(of: element.children)
            var ticks = "`"
            while text.contains(ticks) { ticks += "`" }
            return "\(ticks) \(text) \(ticks)"
        case "blockquote":
            let lines = trimmed(children()).components(separatedBy: "\n")
            return "\n\n" + lines.map { "> \($0)" }.joined(separator: "\n") + "\n\n"
        case "ul", "ol":
            var number = Int(element.attributes["start"] ?? "") ?? 1
            var lines: [String] = []
            for child in element.children {
                guard case .element(let item) = child, item.tag == "li" else { continue }
                let marker = element.tag == "ol" ? "\(number). " : "- "
                if element.tag == "ol" { number += 1 }
                // 嵌套列表紧跟在条目文字下一行，不另起段落。
                let content = collapseBlankLines(trimmed(item.children.map { child -> String in
                    if case .element(let nested) = child, nested.tag == "ul" || nested.tag == "ol" {
                        return "\n" + trimmed(markdown(child)) + "\n"
                    }
                    return markdown(child)
                }.joined()))
                let parts = content.components(separatedBy: "\n")
                lines.append(marker + (parts.first ?? ""))
                let indent = String(repeating: " ", count: marker.count)
                lines.append(contentsOf: parts.dropFirst().map { $0.isEmpty ? "" : indent + $0 })
            }
            return "\n\n" + lines.joined(separator: "\n") + "\n\n"
        case "table":
            let rows = HTMLFragment.elements(named: "tr", in: element.children).map { row in
                row.children.compactMap { cell -> String? in
                    guard case .element(let cell) = cell, cell.tag == "th" || cell.tag == "td" else { return nil }
                    return trimmed(cell.children.map { markdown($0) }.joined()
                        .replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "\n", with: " "))
                }
            }
            guard let header = rows.first else { return "" }
            let columns = rows.map(\.count).max() ?? 0
            func line(_ cells: [String]) -> String {
                "| " + (cells + Array(repeating: "", count: columns - cells.count)).joined(separator: " | ") + " |"
            }
            let body = rows.dropFirst().map(line).joined(separator: "\n")
            return "\n\n\(line(header))\n\(line(Array(repeating: "---", count: columns)))\n\(body)\n\n"
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(element.tag.dropFirst()) ?? 1
            return "\n\n\(String(repeating: "#", count: level)) \(trimmed(children()))\n\n"
        default:
            return children()
        }
    }

    /// 块之间只留一个空行；围栏代码里的空行原样保留。
    private static func collapseBlankLines(_ text: String) -> String {
        var output: [String] = []
        var fence: String?
        var previousBlank = false
        for line in text.components(separatedBy: "\n") {
            // 引用和列表里的围栏带有前缀，比较时先去掉。
            let stripped = line.drop { $0 == " " || $0 == ">" }
            if let open = fence {
                output.append(line)
                if stripped == Substring(open) { fence = nil }
                continue
            }
            if stripped.hasPrefix("```") {
                fence = String(stripped.prefix { $0 == "`" })
                output.append(line)
                previousBlank = false
                continue
            }
            let blank = line.isEmpty
            if blank, previousBlank { continue }
            output.append(line)
            previousBlank = blank
        }
        return output.joined(separator: "\n")
    }
}
