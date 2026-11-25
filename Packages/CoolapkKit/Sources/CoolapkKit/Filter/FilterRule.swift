import Foundation

/// 过滤档位：严格档包含标准档的全部规则。
public enum FilterLevel: String, Sendable, CaseIterable {
    case standard, strict

    var rank: Int { self == .strict ? 1 : 0 }
}

/// 规则适用的内容范围。
public enum FilterScope: String, Sendable, CaseIterable {
    case feed, comment, user
}

/// 规则类型：作者名单、话题名单、文本短语。
public enum FilterRuleKind: String, Sendable, CaseIterable {
    case author, topic, text
}

/// 规则、订阅或例外不符合格式要求。
public struct FilterFormatError: Error, LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String = "内容过滤规则格式无效") {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// 待判断的一条内容：只包含它自己的作者、话题和可见文本。
public struct FilterInput: Sendable, Equatable {
    public var scope: FilterScope
    public var id: String?
    public var authorUID: String?
    /// 正文，可以带 HTML；匹配时只看可见文字。
    public var text: String
    public var topicIDs: Set<String>
    public var topicNames: Set<String>

    public init(scope: FilterScope, id: String? = nil, authorUID: String? = nil, text: String = "",
                topicIDs: Set<String> = [], topicNames: Set<String> = []) {
        self.scope = scope
        self.id = id
        self.authorUID = authorUID
        self.text = text
        self.topicIDs = topicIDs
        self.topicNames = topicNames
    }

    /// 内容例外使用的键，形如 `feed:123`。
    public var contentKey: String? { id.map { "\(scope.rawValue):\($0)" } }
}

/// 一次命中：哪条规则、为什么。
public struct FilterMatch: Sendable, Equatable {
    public let ruleID: String
    public let reason: String
    public let kind: FilterRuleKind

    public init(ruleID: String, reason: String, kind: FilterRuleKind) {
        self.ruleID = ruleID
        self.reason = reason
        self.kind = kind
    }
}

/// 一条过滤规则。只做字面匹配，订阅里不允许出现正则。
public struct FilterRule: Sendable, Equatable, Identifiable {
    public var id: String
    public var reason: String
    public var kind: FilterRuleKind
    public var level: FilterLevel
    public var scopes: Set<FilterScope>
    /// 作者 UID，或话题 ID／完整话题名。
    public var values: [String]
    /// 文本规则：每组任选一词，所有组都要在同一句内出现。
    public var groups: [[String]]
    /// 所有命中词（含自身）允许跨越的最大长度，按归一化后的 UTF-16 单元计。
    public var maxDistance: Int
    /// 同一句内出现这些词时不算命中。
    public var exceptions: [String]
    public var reviewedAt: Date?
    public var sources: [String]

    public init(id: String, reason: String, kind: FilterRuleKind, level: FilterLevel = .standard,
                scopes: Set<FilterScope> = [.feed, .comment, .user], values: [String] = [],
                groups: [[String]] = [], maxDistance: Int = 80, exceptions: [String] = [],
                reviewedAt: Date? = nil, sources: [String] = []) {
        self.id = id
        self.reason = reason
        self.kind = kind
        self.level = level
        self.scopes = scopes
        self.values = values
        self.groups = groups
        self.maxDistance = maxDistance
        self.exceptions = exceptions
        self.reviewedAt = reviewedAt
        self.sources = sources
    }

    public var json: JSON {
        var object: [String: JSON] = [
            "id": .string(id),
            "reason": .string(reason),
            "kind": .string(kind.rawValue),
            "level": .string(level.rawValue),
            "scopes": .array(FilterScope.allCases.filter(scopes.contains).map { .string($0.rawValue) }),
            "values": .array(values.map(JSON.string)),
            "groups": .array(groups.map { .array($0.map(JSON.string)) }),
            "maxDistance": .number(Double(maxDistance)),
            "exceptions": .array(exceptions.map(JSON.string)),
            "sources": .array(sources.map(JSON.string)),
        ]
        if let reviewedAt { object["reviewedAt"] = .string(FilterDate.format(reviewedAt)) }
        return .object(object)
    }

    /// 严格解析：未知字段、超限、重复项和排除词一律拒绝。
    public init(json: JSON) throws {
        let object = try FilterParse.object(json, allowed: [
            "id", "reason", "kind", "level", "scopes", "values", "groups", "maxDistance",
            "exceptions", "reviewedAt", "sources",
        ])
        let id = try FilterParse.string(json["id"], max: 100)
        guard id.unicodeScalars.allSatisfy(FilterParse.isIdentifierScalar) else { throw FilterFormatError() }
        let kind: FilterRuleKind = try FilterParse.enumeration(json["kind"])
        let level: FilterLevel = object["level"].isNilOrNull ? .standard : try FilterParse.enumeration(json["level"])

        var scopes = Set(FilterScope.allCases)
        if !object["scopes"].isNilOrNull {
            guard let raw = json["scopes"].array, !raw.isEmpty, raw.count <= 3 else { throw FilterFormatError() }
            scopes = Set(try raw.map { try FilterParse.enumeration($0) as FilterScope })
            guard scopes.count == raw.count else { throw FilterFormatError() }
        }
        let values = try FilterParse.strings(json["values"], maxCount: 200, maxLength: 256)
        let exceptions = try FilterParse.strings(json["exceptions"], maxCount: 16, maxLength: 128)
        var groups: [[String]] = []
        if !object["groups"].isNilOrNull {
            guard let raw = json["groups"].array, raw.count <= 8 else { throw FilterFormatError() }
            groups = try raw.map {
                guard !$0.isNull else { throw FilterFormatError() }
                return try FilterParse.strings($0, maxCount: 16, maxLength: 256)
            }
        }
        var distance = 80
        if !object["maxDistance"].isNilOrNull {
            distance = try FilterParse.integer(json["maxDistance"], in: 1...240)
        }

        if kind == .text {
            guard !groups.isEmpty, !groups.contains(where: \.isEmpty), values.isEmpty else { throw FilterFormatError() }
            for term in groups.joined() {
                let normalized = FilterText.normalize(term)
                guard !normalized.isEmpty, !FilterText.excludedTerms.contains(where: normalized.contains) else {
                    throw FilterFormatError()
                }
            }
        } else {
            guard !values.isEmpty, groups.isEmpty, exceptions.isEmpty, level == .standard else {
                throw FilterFormatError()
            }
            if kind == .author, !values.allSatisfy(FilterParse.isUID) { throw FilterFormatError() }
        }
        let sources = try FilterParse.strings(json["sources"], maxCount: 8, maxLength: 2048)
        guard sources.allSatisfy(FilterParse.isHTTPSURL) else { throw FilterFormatError() }

        self.init(id: id, reason: try FilterParse.string(json["reason"], max: 200), kind: kind, level: level,
                  scopes: scopes, values: values, groups: groups, maxDistance: distance, exceptions: exceptions,
                  reviewedAt: object["reviewedAt"].isNilOrNull ? nil : try FilterDate.parse(json["reviewedAt"]),
                  sources: sources)
    }

    /// 经过一次严格往返校验后的副本。
    public func validated() throws -> FilterRule { try FilterRule(json: json) }
}

/// 一整份规则（内置或订阅），更新时整体替换。
public struct FilterRuleSet: Sendable, Equatable {
    public static let schemaVersion = 1

    public var revision: Int
    public var publishedAt: Date
    public var rules: [FilterRule]

    public init(revision: Int, publishedAt: Date, rules: [FilterRule]) {
        self.revision = revision
        self.publishedAt = publishedAt
        self.rules = rules
    }

    public var json: JSON {
        .object([
            "schemaVersion": .number(Double(Self.schemaVersion)),
            "revision": .number(Double(revision)),
            "publishedAt": .string(FilterDate.format(publishedAt)),
            "rules": .array(rules.map(\.json)),
        ])
    }

    public init(json: JSON) throws {
        _ = try FilterParse.object(json, allowed: ["schemaVersion", "revision", "publishedAt", "rules"])
        guard try FilterParse.integer(json["schemaVersion"], in: 1...1) == Self.schemaVersion else {
            throw FilterFormatError()
        }
        let revision = try FilterParse.integer(json["revision"], in: 1...2_147_483_647)
        guard let raw = json["rules"].array, raw.count <= 2000 else { throw FilterFormatError() }
        var ids = Set<String>()
        let rules = try raw.map { entry -> FilterRule in
            let rule = try FilterRule(json: entry)
            guard ids.insert(rule.id).inserted else { throw FilterFormatError() }
            return rule
        }
        self.init(revision: revision, publishedAt: try FilterDate.parse(json["publishedAt"]), rules: rules)
    }

    public func validated() throws -> FilterRuleSet { try FilterRuleSet(json: json) }
}

/// 文本归一化与排除词。
public enum FilterText {
    /// 这些词本身不算低俗，既不能作为规则，也不参与命中。
    public static let excludedTerms = ["lsp", "手冲", "后入", "性压抑"]

    private static let invisible: Set<UInt32> = [0x2060, 0xFEFF]

    /// 全角转半角、转小写、去掉零宽字符、合并空白。
    public static func normalize(_ value: String) -> String {
        var folded = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E: folded.append(Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar)
            case 0x3000: folded.append(" ")
            default: folded.append(scalar)
            }
        }
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in String(folded).lowercased().unicodeScalars {
            let code = scalar.value
            if (0x200B...0x200F).contains(code) || (0x202A...0x202E).contains(code) || invisible.contains(code) {
                continue
            }
            if scalar.properties.isWhitespace {
                pendingSpace = !result.isEmpty
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(scalar)
        }
        return String(result)
    }
}

/// 规则里的时间：带时区的 ISO 8601，输出统一为 UTC 毫秒精度。
enum FilterDate {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()

    static func format(_ date: Date) -> String {
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = Int64((Double(milliseconds) / 1000).rounded(.down))
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", parts.year ?? 0, parts.month ?? 0,
                      parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0,
                      Int(milliseconds - seconds * 1000))
    }

    /// 接受 `2026-10-26T00:00:00(.fff)(Z|±hh:mm)`，拒绝不存在的日期。
    static func parse(_ json: JSON) throws -> Date {
        guard case .string(let value) = json, value.utf8.count <= 40 else { throw FilterFormatError() }
        let bytes = Array(value.utf8)
        func digits(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= bytes.count else { return nil }
            var number = 0
            for byte in bytes[range] {
                guard (48...57).contains(byte) else { return nil }
                number = number * 10 + Int(byte - 48)
            }
            return number
        }
        func byte(_ index: Int) -> UInt8? { index < bytes.count ? bytes[index] : nil }
        guard let year = digits(0..<4), byte(4) == 45, let month = digits(5..<7), byte(7) == 45,
              let day = digits(8..<10), byte(10) == 84, let hour = digits(11..<13), byte(13) == 58,
              let minute = digits(14..<16), byte(16) == 58, let second = digits(17..<19),
              hour <= 23, minute <= 59, second <= 59 else { throw FilterFormatError() }
        var index = 19
        var fraction = 0.0
        if byte(index) == 46 {
            var scale = 0.1
            var count = 0
            index += 1
            while let digit = byte(index), (48...57).contains(digit) {
                fraction += Double(digit - 48) * scale
                scale /= 10
                count += 1
                index += 1
            }
            guard (1...6).contains(count) else { throw FilterFormatError() }
        }
        var offset = 0
        if byte(index) == 90 {
            index += 1
        } else if let sign = byte(index), sign == 43 || sign == 45, let hours = digits(index + 1..<index + 3),
                  byte(index + 3) == 58, let minutes = digits(index + 4..<index + 6) {
            offset = (hours * 3600 + minutes * 60) * (sign == 45 ? -1 : 1)
            index += 6
        } else {
            throw FilterFormatError()
        }
        guard index == bytes.count else { throw FilterFormatError() }
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components) else { throw FilterFormatError() }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { throw FilterFormatError() }
        return date.addingTimeInterval(fraction - TimeInterval(offset))
    }
}

/// 严格 JSON 读取的小工具。
enum FilterParse {
    static func object(_ json: JSON, allowed: Set<String>) throws -> [String: JSON] {
        guard let object = json.object, object.keys.allSatisfy(allowed.contains) else { throw FilterFormatError() }
        return object
    }

    /// 非空、不超长、首尾无空白、不含控制字符。
    static func string(_ json: JSON, max: Int) throws -> String {
        guard case .string(let value) = json, !value.isEmpty, value.utf16.count <= max,
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw FilterFormatError()
        }
        return value
    }

    /// 缺省视为空列表；条目不得重复。
    static func strings(_ json: JSON, maxCount: Int, maxLength: Int) throws -> [String] {
        if json.isNull { return [] }
        guard let raw = json.array, raw.count <= maxCount else { throw FilterFormatError() }
        let result = try raw.map { try string($0, max: maxLength) }
        guard Set(result).count == result.count else { throw FilterFormatError() }
        return result
    }

    static func integer(_ json: JSON, in range: ClosedRange<Int>) throws -> Int {
        guard case .number(let value) = json, value.isFinite, value == value.rounded(),
              value >= Double(range.lowerBound), value <= Double(range.upperBound) else {
            throw FilterFormatError()
        }
        return Int(value)
    }

    static func enumeration<T: RawRepresentable>(_ json: JSON) throws -> T where T.RawValue == String {
        guard case .string(let value) = json, let result = T(rawValue: value) else { throw FilterFormatError() }
        return result
    }

    static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "_", ".", ":", "-": return true
        default: return false
        }
    }

    /// 不以 0 开头、最多 20 位的数字 UID。
    static func isUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...20).contains(bytes.count), bytes[0] != 48 else { return false }
        return bytes.allSatisfy { (48...57).contains($0) }
    }

    /// 只接受带主机名、不带用户信息的 https 地址。
    static func isHTTPSURL(_ value: String) -> Bool {
        let prefix = "https://"
        guard value.lowercased().hasPrefix(prefix) else { return false }
        let authority = value.dropFirst(prefix.count).prefix { !"/?#".contains($0) }
        guard !authority.contains("@"), !authority.contains(where: \.isWhitespace) else { return false }
        let host = authority.hasPrefix("[") ? authority[...] : authority.prefix { $0 != ":" }
        return !host.isEmpty
    }
}

private extension Optional where Wrapped == JSON {
    var isNilOrNull: Bool { self?.isNull ?? true }
}
