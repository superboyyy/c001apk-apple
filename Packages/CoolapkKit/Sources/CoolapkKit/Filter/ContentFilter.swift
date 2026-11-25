import Foundation

/// 内容过滤的全部状态：开关、档位、当前规则、个人规则和例外。
/// 纯值类型，不读写磁盘也不联网；持久化用 `snapshot`，订阅内容由调用方下载后交给 `applySubscription`。
public struct ContentFilter: Sendable {
    public static let maxSubscriptionBytes = 1024 * 1024
    public static let updateInterval: TimeInterval = 6 * 60 * 60
    public static let personalPrefix = "personal."
    private static let maxPersonalRules = 200
    private static let maxChoices = 10_000

    public private(set) var isEnabled = false
    public private(set) var level = FilterLevel.standard
    /// 当前生效的内置或订阅规则。
    public private(set) var ruleSet = FilterRuleSet.builtin
    public private(set) var personalRules: [FilterRule] = []
    public private(set) var disabledRuleIDs: Set<String> = []
    public private(set) var allowedAuthorUIDs: Set<String> = []
    public private(set) var allowedContentKeys: Set<String> = []
    /// 订阅地址；留空表示不订阅，也就不会联网。
    public private(set) var subscriptionURL = ""
    public private(set) var lastCheckedAt: Date?
    /// 读取存档时订阅缓存已损坏，已退回内置规则。
    public private(set) var cacheWasDamaged = false

    private var disabledListKinds: Set<FilterRuleKind> = []
    private var engine = ContentFilterEngine(validated: FilterRuleSet.builtin.rules)
    private var personalEngine = ContentFilterEngine(validated: [])

    public init() {}

    /// 是否是合法的数字 UID（不以 0 开头，最多 20 位）。
    public static func isValidUID(_ value: String) -> Bool { FilterParse.isUID(value) }

    // MARK: 判断

    public func evaluate(_ input: FilterInput) -> FilterMatch? {
        guard isEnabled else { return nil }
        func run(_ engine: ContentFilterEngine) -> FilterMatch? {
            engine.evaluate(input, level: level, disabledRuleIDs: disabledRuleIDs,
                            allowedAuthorUIDs: allowedAuthorUIDs, allowedContentKeys: allowedContentKeys)
        }
        return run(personalEngine) ?? run(engine)
    }

    /// 判断一条列表行；不在过滤范围内的类型返回 nil。
    public func match(_ entity: Entity, scope: FilterScope? = nil) -> FilterMatch? {
        guard isEnabled, let actual = scope ?? ContentFilterProjection.scope(of: entity) else { return nil }
        return evaluate(ContentFilterProjection.input(for: entity, scope: actual))
    }

    // MARK: 设置

    public mutating func setEnabled(_ value: Bool) { isEnabled = value }

    public mutating func setLevel(_ value: FilterLevel) { level = value }

    /// 作者名单或话题名单这一类是否启用（与单条规则的停用互相独立）。
    public func isListEnabled(_ kind: FilterRuleKind) -> Bool { !disabledListKinds.contains(kind) }

    /// 关闭后，订阅以后新增的同类规则也不生效；重新开启会恢复该类全部订阅规则。
    public mutating func setListEnabled(_ kind: FilterRuleKind, _ enabled: Bool) throws {
        guard kind != .text else { throw FilterFormatError("仅支持用户或话题名单") }
        if enabled {
            disabledListKinds.remove(kind)
            disabledRuleIDs.subtract(ruleSet.rules.filter { $0.kind == kind }.map(\.id))
        } else {
            disabledListKinds.insert(kind)
        }
        rebuildEngines()
    }

    public mutating func setRuleDisabled(_ id: String, _ disabled: Bool) throws {
        try Self.setChoice(&disabledRuleIDs, id, disabled)
    }

    public mutating func setAuthorAllowed(_ uid: String, _ allowed: Bool) throws {
        try Self.setChoice(&allowedAuthorUIDs, uid, allowed)
    }

    public mutating func setContentAllowed(_ key: String, _ allowed: Bool) throws {
        try Self.setChoice(&allowedContentKeys, key, allowed)
    }

    private static func setChoice(_ choices: inout Set<String>, _ value: String, _ add: Bool) throws {
        guard !value.isEmpty, value.utf16.count <= 200 else { throw FilterFormatError("例外内容无效") }
        if add {
            guard choices.count < maxChoices || choices.contains(value) else { throw FilterFormatError("例外数量过多") }
            choices.insert(value)
        } else {
            choices.remove(value)
        }
    }

    // MARK: 个人规则

    public mutating func addPersonalRule(_ rule: FilterRule) throws {
        let validated = try rule.validated()
        guard validated.id.hasPrefix(Self.personalPrefix), personalRules.count < Self.maxPersonalRules,
              !personalRules.contains(where: { $0.id == validated.id }),
              !ruleSet.rules.contains(where: { $0.id == validated.id }) else {
            throw FilterFormatError("个人规则重复或数量过多")
        }
        personalRules.append(validated)
        rebuildEngines()
    }

    /// 用一个短语、作者 UID 或完整话题名（或话题 ID）新建个人规则。
    @discardableResult
    public mutating func addPersonalRule(kind: FilterRuleKind, value: String, now: Date = Date()) throws -> FilterRule {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var stamp = Int64(now.timeIntervalSince1970 * 1_000_000)
        while personalRules.contains(where: { $0.id == "\(Self.personalPrefix)\(stamp)" }) { stamp += 1 }
        let title: String
        switch kind {
        case .author: title = "个人作者 UID"
        case .topic: title = "个人话题"
        case .text: title = "个人文本短语"
        }
        let rule = FilterRule(
            id: "\(Self.personalPrefix)\(stamp)", reason: title, kind: kind,
            values: kind == .text ? [] : [trimmed], groups: kind == .text ? [[trimmed]] : [], maxDistance: 240)
        try addPersonalRule(rule)
        return rule
    }

    public mutating func removePersonalRule(_ id: String) {
        personalRules.removeAll { $0.id == id }
        rebuildEngines()
    }

    // MARK: 订阅

    /// 换订阅地址会丢弃旧订阅的规则，回到内置规则。只接受 https，空字符串表示取消订阅。
    public mutating func setSubscriptionURL(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || (trimmed.utf16.count <= 2048 && FilterParse.isHTTPSURL(trimmed)
            && URL(string: trimmed) != nil) else {
            throw FilterFormatError("订阅地址必须是 https 链接")
        }
        guard trimmed != subscriptionURL else { return }
        subscriptionURL = trimmed
        resetToBuiltinRules()
    }

    /// 丢弃订阅缓存，恢复随应用发布的规则；个人规则和例外不受影响。
    public mutating func resetToBuiltinRules() {
        ruleSet = .builtin
        lastCheckedAt = nil
        cacheWasDamaged = false
        rebuildEngines()
    }

    /// 已开启、已配置订阅，且距上次成功检查超过六小时。
    public func isUpdateDue(now: Date = Date()) -> Bool {
        guard isEnabled, !subscriptionURL.isEmpty else { return false }
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= Self.updateInterval
    }

    /// 校验下载到的订阅并整体替换当前规则。拒绝超大、降级、同版本被改动以及占用个人命名空间的内容。
    public mutating func applySubscription(_ data: Data, now: Date = Date()) throws {
        guard data.count <= Self.maxSubscriptionBytes, let json = JSON.parse(data), json.object != nil else {
            throw FilterFormatError("订阅内容格式无效")
        }
        let candidate = try Self.subscription(json)
        guard candidate.revision > ruleSet.revision
            || (candidate.revision == ruleSet.revision && candidate.json == ruleSet.json) else {
            throw FilterFormatError("订阅版本低于当前规则")
        }
        ruleSet = candidate
        lastCheckedAt = now
        cacheWasDamaged = false
        rebuildEngines()
    }

    private static func subscription(_ json: JSON) throws -> FilterRuleSet {
        let rules = try FilterRuleSet(json: json)
        guard !rules.rules.contains(where: { $0.id.hasPrefix(personalPrefix) }) else {
            throw FilterFormatError("订阅不能使用个人规则命名空间")
        }
        return rules
    }

    private mutating func rebuildEngines() {
        engine = ContentFilterEngine(validated: ruleSet.rules.filter { !disabledListKinds.contains($0.kind) })
        personalEngine = ContentFilterEngine(validated: personalRules)
    }

    // MARK: 存档

    /// 可写入磁盘的完整状态。
    public var snapshot: JSON {
        var object: [String: JSON] = [
            "enabled": .bool(isEnabled),
            "level": .string(level.rawValue),
            "disabledRuleIds": .array(disabledRuleIDs.sorted().map(JSON.string)),
            "disabledListKinds": .array(disabledListKinds.map(\.rawValue).sorted().map(JSON.string)),
            "allowedAuthorUids": .array(allowedAuthorUIDs.sorted().map(JSON.string)),
            "allowedContentKeys": .array(allowedContentKeys.sorted().map(JSON.string)),
            "personalRules": .array(personalRules.map(\.json)),
            "subscriptionUrl": .string(subscriptionURL),
        ]
        if ruleSet != .builtin { object["ruleSet"] = ruleSet.json }
        if let lastCheckedAt { object["lastCheckedAt"] = .string(FilterDate.format(lastCheckedAt)) }
        return .object(object)
    }

    /// 从存档恢复。损坏的部分各自回退到默认值，互不牵连。
    public init(snapshot: JSON) {
        func strings(_ key: String) -> Set<String> {
            guard let raw = snapshot[key].array, raw.count <= Self.maxChoices else { return [] }
            return Set(raw.compactMap { entry -> String? in
                guard case .string(let value) = entry, !value.isEmpty, value.utf16.count <= 200 else { return nil }
                return value
            })
        }
        isEnabled = snapshot["enabled"] == .bool(true)
        level = snapshot["level"] == .string(FilterLevel.strict.rawValue) ? .strict : .standard
        disabledRuleIDs = strings("disabledRuleIds")
        disabledListKinds = Set(strings("disabledListKinds").compactMap(FilterRuleKind.init(rawValue:)))
            .intersection([.author, .topic])
        allowedAuthorUIDs = strings("allowedAuthorUids")
        allowedContentKeys = strings("allowedContentKeys")
        if case .string(let url) = snapshot["subscriptionUrl"], FilterParse.isHTTPSURL(url), URL(string: url) != nil {
            subscriptionURL = url
        }
        lastCheckedAt = try? FilterDate.parse(snapshot["lastCheckedAt"])
        if snapshot["ruleSet"].object != nil {
            if let cached = try? Self.subscription(snapshot["ruleSet"]) {
                if cached.revision >= ruleSet.revision { ruleSet = cached }
            } else {
                cacheWasDamaged = true
            }
        }
        if let raw = snapshot["personalRules"].array, raw.count <= Self.maxPersonalRules {
            var ids = Set<String>()
            for entry in raw {
                guard let rule = try? FilterRule(json: entry), rule.id.hasPrefix(Self.personalPrefix),
                      ids.insert(rule.id).inserted else { continue }
                personalRules.append(rule)
            }
        }
        rebuildEngines()
    }
}
