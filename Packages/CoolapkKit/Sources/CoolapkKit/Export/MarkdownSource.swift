import Foundation

/// 把含基础 Markdown 写法的酷安正文转成 HTML，供导出使用。
/// 覆盖标题、粗斜体、删除线、引用、列表（含任务项）、围栏代码、表格、链接与图片。
struct MarkdownSource {
    /// 是否出现了足以认定为 Markdown 的结构。
    private var found = false
    private var listItems = 0
    /// 正文里原有的 `<a>` 链接，先整体取出，避免链接文字被当成 Markdown 解析。
    private var anchors: [String] = []
    /// 当前的块级、行内嵌套层数；超过上限的内容按普通文字处理。
    private var blockDepth = 0
    private var inlineDepth = 0
    private static let maxDepth = 16
    /// 行内语法查找闭合符的最大距离（字符数）。
    private static let searchWindow = 4096

    private static let maxLength = 200_000
    private static let anchorOpen: Unicode.Scalar = "\u{E000}"
    private static let anchorClose: Unicode.Scalar = "\u{E001}"

    /// 识别为 Markdown 时返回转换后的 HTML，否则返回 nil（调用方按普通正文处理）。
    static func html(from source: String) -> String? {
        guard source.utf16.count <= maxLength else { return nil }
        var converter = MarkdownSource()
        let lines = converter.normalize(source)
        let html = converter.blocks(lines)
        return converter.found || converter.listItems >= 2 ? html : nil
    }

    // MARK: 预处理

    /// 去掉酷安的显示分隔标记，把 `<br>`、`<p>` 还原成换行并解码实体；围栏代码内保持原样。
    private mutating func normalize(_ source: String) -> [String] {
        let input = source.replacingOccurrences(of: "<!--break-->", with: "").replacingOccurrences(of: "\r\n", with: "\n")
        var output: [String] = []
        var fence: Fence?
        for line in input.components(separatedBy: "\n") {
            if let open = fence {
                output.append(line)
                if Fence.closes(line, open) { fence = nil }
            } else if let open = Fence.opening(line) {
                fence = open
                output.append(line)
            } else {
                output.append(contentsOf: normalizeText(line).components(separatedBy: "\n"))
            }
        }
        return output
    }

    private mutating func normalizeText(_ line: String) -> String {
        var text = line
        if text.range(of: "<a", options: .caseInsensitive) != nil {
            let pattern = ExportPatterns.anchor
            let whole = NSRange(text.startIndex..., in: text)
            var result = ""
            var cursor = text.startIndex
            for match in pattern.matches(in: text, range: whole) {
                guard let range = Range(match.range, in: text) else { continue }
                result += text[cursor..<range.lowerBound]
                result += "\(MarkdownSource.anchorOpen)\(anchors.count)\(MarkdownSource.anchorClose)"
                anchors.append(String(text[range]))
                cursor = range.upperBound
            }
            result += text[cursor...]
            text = result
        }
        text = ExportPatterns.lineBreak.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n")
        text = ExportPatterns.paragraph.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\n\n")
        return HTMLEntities.decode(text)
    }

    // MARK: 块级结构

    private struct Fence {
        var marker: Character
        var length: Int
        var info: String

        static func opening(_ line: String) -> Fence? {
            guard let groups = ExportPatterns.groups(ExportPatterns.fence, line), let run = groups[1], let first = run.first else {
                return nil
            }
            let info = (groups[2] ?? "").trimmingCharacters(in: .whitespaces)
            if first == "`", info.contains("`") { return nil }
            return Fence(marker: first, length: run.count, info: info)
        }

        static func closes(_ line: String, _ open: Fence) -> Bool {
            guard let groups = ExportPatterns.groups(ExportPatterns.fence, line), let run = groups[1] else { return false }
            return run.first == open.marker && run.count >= open.length
                && (groups[2] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private struct ListMarker {
        var indent: Int
        var ordered: Bool
        var number: Int
        /// 条目正文相对行首的缩进，续行按它对齐。
        var contentIndent: Int
        var content: String
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        guard let groups = ExportPatterns.groups(ExportPatterns.listItem, line),
              let indent = groups[1], let marker = groups[2], let gap = groups[3], let content = groups[4],
              !content.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let ordered = marker.first?.isNumber ?? false
        return ListMarker(indent: indent.count, ordered: ordered, number: Int(marker.dropLast()) ?? 1,
                          contentIndent: indent.count + marker.count + min(gap.count, 4), content: content)
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func leadingSpaces(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func tableCells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count, lines[index].contains("|"), lines[index + 1].contains("-"),
              ExportPatterns.matches(ExportPatterns.tableDelimiter, lines[index + 1])
        else { return false }
        return tableCells(lines[index]).count == tableCells(lines[index + 1]).count
    }

    /// 这一行是否会打断正在累积的段落。
    private static func startsBlock(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        if Fence.opening(line) != nil || ExportPatterns.matches(ExportPatterns.heading, line)
            || ExportPatterns.matches(ExportPatterns.rule, line) || ExportPatterns.matches(ExportPatterns.quote, line)
            || isTableStart(lines, at: index) {
            return true
        }
        if let marker = listMarker(line) { return !marker.ordered || marker.number == 1 }
        return false
    }

    private mutating func blocks(_ lines: [String]) -> String {
        blockDepth += 1
        defer { blockDepth -= 1 }
        guard blockDepth <= MarkdownSource.maxDepth else {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "" : "<p>\(HTMLEntities.escapeText(text))</p>"
        }
        var html = ""
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if MarkdownSource.isBlank(line) {
                index += 1
            } else if let open = Fence.opening(line) {
                var code: [String] = []
                index += 1
                while index < lines.count, !Fence.closes(lines[index], open) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                found = true
                let language = open.info.split(separator: " ").first.map(String.init) ?? ""
                let name = language.isEmpty ? "" : " class=\"language-\(HTMLEntities.escapeAttribute(language))\""
                html += "<pre><code\(name)>\(HTMLEntities.escapeText(code.joined(separator: "\n") + "\n"))</code></pre>"
            } else if let groups = ExportPatterns.groups(ExportPatterns.heading, line), let marks = groups[1] {
                found = true
                html += "<h\(marks.count)>\(inline(groups[2] ?? ""))</h\(marks.count)>"
                index += 1
            } else if ExportPatterns.matches(ExportPatterns.rule, line) {
                html += "<hr>"
                index += 1
            } else if ExportPatterns.matches(ExportPatterns.quote, line) {
                var inner: [String] = []
                while index < lines.count, let groups = ExportPatterns.groups(ExportPatterns.quote, lines[index]) {
                    if !(groups[1] ?? "").isEmpty { found = true }
                    inner.append(groups[2] ?? "")
                    index += 1
                }
                html += "<blockquote>\(blocks(inner))</blockquote>"
            } else if MarkdownSource.isTableStart(lines, at: index) {
                found = true
                let header = MarkdownSource.tableCells(line)
                html += "<table><thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead>"
                index += 2
                var rows = ""
                while index < lines.count, !MarkdownSource.isBlank(lines[index]), lines[index].contains("|") {
                    var cells = MarkdownSource.tableCells(lines[index])
                    cells = Array(cells.prefix(header.count)) + Array(repeating: "", count: max(header.count - cells.count, 0))
                    rows += "<tr>" + cells.map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
                    index += 1
                }
                html += (rows.isEmpty ? "" : "<tbody>\(rows)</tbody>") + "</table>"
            } else if let first = MarkdownSource.listMarker(line) {
                html += list(lines, &index, first: first)
            } else {
                var paragraph = [line]
                index += 1
                while index < lines.count, !MarkdownSource.isBlank(lines[index]),
                      !MarkdownSource.startsBlock(lines, at: index) {
                    paragraph.append(lines[index])
                    index += 1
                }
                html += "<p>\(inline(paragraph.joined(separator: "\n")))</p>"
            }
        }
        return html
    }

    private mutating func list(_ lines: [String], _ index: inout Int, first: ListMarker) -> String {
        var items = ""
        while index < lines.count, let marker = MarkdownSource.listMarker(lines[index]),
              marker.ordered == first.ordered, marker.indent <= first.indent + 1 {
            var body: [String] = []
            index += 1
            while index < lines.count {
                let line = lines[index]
                if MarkdownSource.isBlank(line) {
                    // 空行之后仍然缩进的内容才算同一条目。
                    guard let next = lines[(index + 1)...].first(where: { !MarkdownSource.isBlank($0) }),
                          MarkdownSource.leadingSpaces(next) >= marker.contentIndent
                    else { break }
                    body.append("")
                } else if MarkdownSource.leadingSpaces(line) >= marker.contentIndent {
                    body.append(String(line.dropFirst(marker.contentIndent)))
                } else if MarkdownSource.listMarker(line) != nil || MarkdownSource.startsBlock(lines, at: index) {
                    break
                } else {
                    body.append(line.trimmingCharacters(in: .whitespaces))
                }
                index += 1
            }
            var content = marker.content
            var checkbox = ""
            if let groups = ExportPatterns.groups(ExportPatterns.task, content) {
                let checked = (groups[1] ?? " ") != " "
                checkbox = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")>"
                content = groups[2] ?? ""
                found = true
            }
            // 紧跟的普通续行并入首段，其余（嵌套列表、代码等）按块解析。
            var head = [content]
            var rest = body[...]
            while let line = rest.first, !MarkdownSource.isBlank(line),
                  !MarkdownSource.startsBlock(Array(rest), at: 0) {
                head.append(line)
                rest = rest.dropFirst()
            }
            items += "<li>\(checkbox)\(inline(head.joined(separator: "\n")))\(blocks(Array(rest)))</li>"
            listItems += 1
            // 条目之间允许空行。
            var lookahead = index
            while lookahead < lines.count, MarkdownSource.isBlank(lines[lookahead]) { lookahead += 1 }
            if lookahead < lines.count, let next = MarkdownSource.listMarker(lines[lookahead]),
               next.ordered == first.ordered, next.indent <= first.indent + 1 {
                index = lookahead
            }
        }
        if first.ordered {
            return "<ol\(first.number == 1 ? "" : " start=\"\(first.number)\"")>\(items)</ol>"
        }
        return "<ul>\(items)</ul>"
    }

    // MARK: 行内结构

    private mutating func inline(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        return inline(scalars[...])
    }

    private mutating func inline(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        inlineDepth += 1
        defer { inlineDepth -= 1 }
        guard inlineDepth <= MarkdownSource.maxDepth else {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars)
            return HTMLEntities.escapeText(String(view))
        }
        var output = ""
        var index = scalars.startIndex
        let end = scalars.endIndex

        func string(_ range: Range<Int>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[range])
            return String(view)
        }
        func starts(_ needle: [Unicode.Scalar], at start: Int) -> Bool {
            end - start >= needle.count && (0..<needle.count).allSatisfy { scalars[start + $0] == needle[$0] }
        }
        func find(_ needle: [Unicode.Scalar], from start: Int) -> Int? {
            guard !needle.isEmpty else { return nil }
            var position = start
            while position <= end - needle.count {
                if starts(needle, at: position) { return position }
                position += 1
            }
            return nil
        }
        func isWord(_ position: Int) -> Bool {
            position >= scalars.startIndex && position < end && CharacterSet.alphanumerics.contains(scalars[position])
        }
        func isSpace(_ position: Int) -> Bool {
            position < scalars.startIndex || position >= end || scalars[position] == " " || scalars[position] == "\n"
                || scalars[position] == "\t"
        }

        while index < end {
            let scalar = scalars[index]
            switch scalar {
            case "\\" where index + 1 < end && MarkdownSource.punctuation.contains(scalars[index + 1]):
                output += HTMLEntities.escapeText(String(scalars[index + 1]))
                index += 2
            case "\n":
                output += "<br>"
                index += 1
            case MarkdownSource.anchorOpen:
                if let close = find([MarkdownSource.anchorClose], from: index + 1),
                   let number = Int(string(index + 1..<close)), anchors.indices.contains(number) {
                    output += anchors[number]
                    index = close + 1
                } else {
                    index += 1
                }
            case "`":
                var run = index
                while run < end, scalars[run] == "`" { run += 1 }
                let ticks = Array(repeating: Unicode.Scalar("`"), count: run - index)
                var close = find(ticks, from: run)
                // 闭合的反引号串长度必须与开头一致。
                while let candidate = close,
                      (candidate + ticks.count < end && scalars[candidate + ticks.count] == "`")
                        || scalars[candidate - 1] == "`" {
                    var skip = candidate
                    while skip < end, scalars[skip] == "`" { skip += 1 }
                    close = find(ticks, from: skip)
                }
                if let close {
                    var code = string(run..<close).replacingOccurrences(of: "\n", with: " ")
                    if code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    found = true
                    output += "<code>\(HTMLEntities.escapeText(code))</code>"
                    index = close + ticks.count
                } else {
                    output += string(index..<run)
                    index = run
                }
            case "<":
                let rest = string(index..<min(end, index + 2048))
                if let groups = ExportPatterns.groups(ExportPatterns.autolink, rest), let url = groups[1] {
                    output += "<a href=\"\(HTMLEntities.escapeAttribute(url))\">\(HTMLEntities.escapeText(url))</a>"
                    index += groups[0]?.unicodeScalars.count ?? 1
                } else if let groups = ExportPatterns.groups(ExportPatterns.htmlTag, rest), let tag = groups[0] {
                    // 原有的行内 HTML 原样保留，稍后统一净化。
                    output += tag
                    index += tag.unicodeScalars.count
                } else {
                    output += "&lt;"
                    index += 1
                }
            case "!" where index + 1 < end && scalars[index + 1] == "[":
                if let link = linkParts(scalars, from: index + 1) {
                    found = true
                    output += "<img src=\"\(HTMLEntities.escapeAttribute(link.url))\" alt=\"\(HTMLEntities.escapeAttribute(link.text))\">"
                    index = link.end
                } else {
                    output += "!"
                    index += 1
                }
            case "[":
                if let link = linkParts(scalars, from: index) {
                    found = true
                    let label = inline(Array(link.text.unicodeScalars)[...])
                    output += "<a href=\"\(HTMLEntities.escapeAttribute(link.url))\">\(label)</a>"
                    index = link.end
                } else {
                    output += "["
                    index += 1
                }
            case "*", "_":
                var run = index
                while run < end, scalars[run] == scalar { run += 1 }
                let length = run - index
                let width = length >= 2 ? 2 : 1
                var closing: Int?
                // 下划线只在词的边界上才算强调，避免拆开 POCO_X3_GT 这类型号。
                if !isSpace(run), scalar == "*" || !isWord(index - 1) {
                    var position = run
                    // 只在有限范围内找闭合符，长文里落单的星号不会拖慢整篇转换。
                    let limit = min(end, run + MarkdownSource.searchWindow)
                    while position < limit {
                        guard scalars[position] == scalar else {
                            position += 1
                            continue
                        }
                        var runEnd = position
                        while runEnd < end, scalars[runEnd] == scalar { runEnd += 1 }
                        let fits = width == 2 ? runEnd - position >= 2 : runEnd - position != 2
                        if fits, !isSpace(position - 1), scalar == "*" || !isWord(runEnd) {
                            closing = position
                            break
                        }
                        position = runEnd
                    }
                }
                if let closing {
                    let tag = width == 2 ? "strong" : "em"
                    found = true
                    output += string(index..<run - width)
                    output += "<\(tag)>\(inline(scalars[run..<closing]))</\(tag)>"
                    index = closing + width
                } else {
                    output += string(index..<run)
                    index = run
                }
            case "~" where index + 1 < end && scalars[index + 1] == "~":
                if !isSpace(index + 2), let close = find(["~", "~"], from: index + 3), !isSpace(close - 1) {
                    found = true
                    output += "<del>\(inline(scalars[index + 2..<close]))</del>"
                    index = close + 2
                } else {
                    output += "~~"
                    index += 2
                }
            case "h" where !isWord(index - 1) && starts(["h", "t", "t", "p"], at: index):
                let rest = string(index..<min(end, index + 2048))
                if let groups = ExportPatterns.groups(ExportPatterns.bareURL, rest), var url = groups[0] {
                    while let last = url.last, ".,;:!?)'\"".contains(last) { url.removeLast() }
                    output += "<a href=\"\(HTMLEntities.escapeAttribute(url))\">\(HTMLEntities.escapeText(url))</a>"
                    index += url.unicodeScalars.count
                } else {
                    output += "h"
                    index += 1
                }
            default:
                output += HTMLEntities.escapeText(String(scalar))
                index += 1
            }
        }
        return output
    }

    private static let punctuation = CharacterSet(charactersIn: "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    private struct LinkParts {
        var text: String
        var url: String
        var end: Int
    }

    /// 解析 `[文字](地址 "标题")`，`start` 指向左方括号。
    private func linkParts(_ scalars: ArraySlice<Unicode.Scalar>, from start: Int) -> LinkParts? {
        let end = scalars.endIndex
        var depth = 0
        var close: Int?
        var position = start
        let limit = min(end, start + MarkdownSource.searchWindow)
        while position < limit {
            let scalar = scalars[position]
            if scalar == "\\" {
                position += 2
                continue
            }
            if scalar == "[" { depth += 1 }
            if scalar == "]" {
                depth -= 1
                if depth == 0 { close = position; break }
            }
            position += 1
        }
        guard let close, close + 1 < end, scalars[close + 1] == "(" else { return nil }
        var urlEnd = close + 2
        var parentheses = 0
        while urlEnd < min(end, close + MarkdownSource.searchWindow) {
            let scalar = scalars[urlEnd]
            if scalar == "\n" { return nil }
            if scalar == "(" { parentheses += 1 }
            if scalar == ")" {
                if parentheses == 0 { break }
                parentheses -= 1
            }
            urlEnd += 1
        }
        guard urlEnd < end, scalars[urlEnd] == ")" else { return nil }
        func string(_ range: Range<Int>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars[range])
            return String(view)
        }
        var url = string(close + 2..<urlEnd).trimmingCharacters(in: .whitespaces)
        // 去掉可选的标题部分。
        if let space = url.firstIndex(of: " "), url[space...].contains("\"") || url[space...].contains("'") {
            url = String(url[..<space])
        }
        if url.hasPrefix("<"), url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
        guard !url.isEmpty, !url.contains(" ") else { return nil }
        return LinkParts(text: string(start + 1..<close), url: url, end: urlEnd + 1)
    }
}

/// 导出模块用到的正则及匹配辅助。
enum ExportPatterns {
    static let anchor = regex(#"<a\b[^>]*>[\s\S]*?</a>"#, [.caseInsensitive])
    static let lineBreak = regex(#"<br\s*/?>"#, [.caseInsensitive])
    static let paragraph = regex(#"</?p\s*>"#, [.caseInsensitive])
    static let fence = regex(#"^ {0,3}(`{3,}|~{3,})(.*)$"#)
    static let heading = regex(#"^ {0,3}(#{1,6})[ \t]+(.*?)(?:[ \t]+#+)?[ \t]*$"#)
    static let rule = regex(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    static let quote = regex(#"^ {0,3}>([ \t]?)(.*)$"#)
    static let listItem = regex(#"^( {0,8})([-+*]|[0-9]{1,9}[.)])([ \t]+)(.*)$"#)
    static let task = regex(#"^\[([ xX])\][ \t]+(.*)$"#, [.dotMatchesLineSeparators])
    static let tableDelimiter = regex(#"^[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)
    static let autolink = regex(#"^<(https?://[^\s<>]+)>"#)
    static let htmlTag = regex(#"^</?[a-zA-Z][a-zA-Z0-9-]*(?:\s[^<>]*)?/?>"#)
    static let bareURL = regex(#"^https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#)

    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // 模式都是编译期常量，写错属于编程错误。
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 首个匹配的各捕获组；未参与匹配的组为 nil。
    static func groups(_ regex: NSRegularExpression, _ text: String) -> [String?]? {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
