import Foundation

extension FilterRuleSet {
    /// 2026-10-26T00:00:00Z，默认规则集的基准日期。
    private static let builtinDate = Date(timeIntervalSince1970: 1_792_972_800)

    /// 默认空规则集：应用本身不内置具体名单或短语，由用户自行添加个人规则或配置订阅源。
    public static let builtin = FilterRuleSet(revision: 1, publishedAt: builtinDate, rules: [])
}
