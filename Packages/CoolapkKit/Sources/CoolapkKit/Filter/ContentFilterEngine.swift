import Foundation

/// 按一份规则判断单条内容是否命中。
public struct ContentFilterEngine: Sendable {
    private struct CompiledRule: Sendable {
        let rule: FilterRule
        let groups: [[[UInt16]]]
        let exceptions: [[UInt16]]

        init(_ rule: FilterRule) {
            self.rule = rule
            groups = rule.groups.map { $0.map { Array(FilterText.normalize($0).utf16) } }
            exceptions = rule.exceptions.map { Array(FilterText.normalize($0).utf16) }.filter { !$0.isEmpty }
        }
    }

    private let rules: [CompiledRule]

    /// 规则先经过一次严格校验，不合格直接抛错。
    public init(_ ruleSet: FilterRuleSet) throws {
        self.init(validated: try ruleSet.validated().rules)
    }

    /// 调用方保证规则已校验过。
    init(validated rules: [FilterRule]) {
        self.rules = rules.map(CompiledRule.init)
    }

    public func evaluate(_ input: FilterInput, level: FilterLevel = .standard,
                         disabledRuleIDs: Set<String> = [], allowedAuthorUIDs: Set<String> = [],
                         allowedContentKeys: Set<String> = []) -> FilterMatch? {
        if let uid = input.authorUID, allowedAuthorUIDs.contains(uid) { return nil }
        if let key = input.contentKey, allowedContentKeys.contains(key) { return nil }
        var sentences: [[UInt16]]?
        for compiled in rules {
            let rule = compiled.rule
            if !rule.scopes.contains(input.scope) || disabledRuleIDs.contains(rule.id)
                || (rule.kind == .text && rule.level.rank > level.rank) { continue }
            let matched: Bool
            switch rule.kind {
            case .author:
                matched = input.authorUID.map(rule.values.contains) ?? false
            case .topic:
                matched = rule.values.contains { input.topicIDs.contains($0) || input.topicNames.contains($0) }
            case .text:
                if sentences == nil { sentences = Self.sentences(of: input.text) }
                matched = Self.matches(sentences ?? [], compiled)
            }
            if matched { return FilterMatch(ruleID: rule.id, reason: rule.reason, kind: rule.kind) }
        }
        return nil
    }

    /// 可见文字逐行归一化；换行保留为句子边界，避免例外词豁免到别的句子。
    public static func visibleText(_ source: String) -> String {
        FilterHTML.visibleText(source)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
            .map { FilterText.normalize(String($0)) }
            .joined(separator: "\n")
    }

    private static let sentenceBreaks = Set("。！？!?；;\r\n".utf16)
    private static let excluded = FilterText.excludedTerms.map { Array($0.utf16) }

    /// 归一化、把排除词涂成等长空格（不改变位置，也不会把两侧拼成新词），再切句。
    private static func sentences(of source: String) -> [[UInt16]] {
        var units = Array(visibleText(source).utf16)
        for term in excluded {
            var offset = 0
            while let index = firstIndex(of: term, in: units, from: offset) {
                for position in index..<index + term.count { units[position] = 0x20 }
                offset = index + term.count
            }
        }
        return units.split(whereSeparator: sentenceBreaks.contains).map(Array.init)
    }

    private static func firstIndex(of needle: [UInt16], in haystack: [UInt16], from start: Int) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count, start <= haystack.count - needle.count else {
            return nil
        }
        let first = needle[0]
        var index = start
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first, haystack[index..<index + needle.count].elementsEqual(needle) { return index }
            index += 1
        }
        return nil
    }

    private static func matches(_ sentences: [[UInt16]], _ compiled: CompiledRule) -> Bool {
        let groups = compiled.groups
        guard !groups.isEmpty else { return false }
        let distance = compiled.rule.maxDistance
        for sentence in sentences {
            // 例外只在本句生效，不会豁免整篇内容。
            if compiled.exceptions.contains(where: { firstIndex(of: $0, in: sentence, from: 0) != nil }) { continue }
            if groups.contains(where: { group in
                !group.contains { firstIndex(of: $0, in: sentence, from: 0) != nil }
            }) { continue }
            var occurrences: [(start: Int, end: Int, group: Int)] = []
            for (group, terms) in groups.enumerated() {
                for term in terms {
                    var offset = 0
                    while let index = firstIndex(of: term, in: sentence, from: offset) {
                        occurrences.append((index, index + term.count, group))
                        offset = index + 1
                    }
                }
            }
            occurrences.sort { $0.end < $1.end }
            // 对每个结束位置，取各组最靠后的起点，得到包含所有组的最小窗口。
            var latestStarts = Array(repeating: -1, count: groups.count)
            for hit in occurrences {
                if hit.start > latestStarts[hit.group] { latestStarts[hit.group] = hit.start }
                let earliest = latestStarts.min() ?? -1
                if earliest >= 0, hit.end - earliest <= distance { return true }
            }
        }
        return false
    }
}
