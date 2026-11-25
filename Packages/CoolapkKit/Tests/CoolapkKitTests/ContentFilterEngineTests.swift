import XCTest
@testable import CoolapkKit

/// 对应上游 `test/content_filter/engine_test.dart`。
final class ContentFilterEngineTests: XCTestCase {
    static let date = Date(timeIntervalSince1970: 1_792_972_800)

    private func textRule(groups: [[String]] = [["想"], ["约炮"]], exceptions: [String] = []) -> FilterRule {
        FilterRule(id: "text.test", reason: "测试组合", kind: .text, groups: groups, maxDistance: 12,
                   exceptions: exceptions)
    }

    private func rules(_ rules: [FilterRule], revision: Int = 1) -> FilterRuleSet {
        FilterRuleSet(revision: revision, publishedAt: Self.date, rules: rules)
    }

    private func feed(_ text: String, uid: String? = nil, ids: Set<String> = [],
                      names: Set<String> = []) -> FilterInput {
        FilterInput(scope: .feed, id: "1", authorUID: uid, text: text, topicIDs: ids, topicNames: names)
    }

    private func builtin() throws -> ContentFilterEngine { try ContentFilterEngine(.builtin) }

    func testExcludedTermsNeitherMatchNorExempt() throws {
        let engine = try builtin()
        for text in ["LSP", "lsp", "ＬＳＰ", "手冲", "后入", "性压抑", "本人女，想选手机", "我是女生，健身装机"] {
            XCTAssertNil(engine.evaluate(feed(text), level: .strict), text)
        }
        XCTAssertNotNil(engine.evaluate(feed("LSP 想约炮")))
    }

    func testStrictLevelIncludesStandard() throws {
        let engine = try builtin()
        XCTAssertNotNil(engine.evaluate(feed("想约炮")))
        XCTAssertNil(engine.evaluate(feed("求 女菩萨 发福利")))
        XCTAssertNotNil(engine.evaluate(feed("求 女菩萨 发福利"), level: .strict))
        XCTAssertNotNil(engine.evaluate(feed("想约炮"), level: .strict))
        XCTAssertNil(engine.evaluate(feed("给女友选机，恋爱，女性健身")))
    }

    func testOrdinaryContextsDoNotMatch() throws {
        let engine = try builtin()
        for text in ["求烧鸡做法", "想干掉她的游戏角色", "我想操作她的电脑安装系统", "收到约炮骚扰，该怎么举报",
                     "拒绝别人约炮要求", "我老公用的这款手机"] {
            XCTAssertNil(engine.evaluate(feed(text), level: .strict), text)
        }
    }

    func testExcludedTermsCannotBeAssembledFromGroups() throws {
        let examples: [String: [[String]]] = [
            "手冲": [["手"], ["冲"]],
            "ＬＳＰ": [["l"], ["s"], ["p"]],
            "后入": [["后"], ["入"]],
            "性压抑": [["性"], ["压抑"]],
        ]
        for (text, groups) in examples {
            let engine = try ContentFilterEngine(rules([textRule(groups: groups)]))
            XCTAssertNil(engine.evaluate(feed(text)), text)
        }
        let engine = try builtin()
        XCTAssertNotNil(engine.evaluate(feed("手冲，我想约炮")))
        XCTAssertNotNil(engine.evaluate(feed("反对别人约炮骚扰。想操她")))
        XCTAssertNotNil(engine.evaluate(feed("想操作她的电脑。想艹她")))
    }

    func testStrictCommentPhrasesOnlyApplyToComments() throws {
        let engine = try builtin()
        for phrase in ["叫我老公", "叫声老公", "现在得叫老公"] {
            let comment = FilterInput(scope: .comment, text: phrase)
            XCTAssertNil(engine.evaluate(comment))
            XCTAssertNotNil(engine.evaluate(comment, level: .strict))
            XCTAssertNil(engine.evaluate(feed(phrase), level: .strict))
        }
        XCTAssertNil(engine.evaluate(FilterInput(scope: .comment, text: "我老公刚买的手机"), level: .strict))
    }

    func testDenseOverlappingGroupsKeepProximitySemantics() throws {
        let engine = try ContentFilterEngine(rules([
            textRule(groups: [["a"], ["aa"], ["aaa"], ["aaaa"], ["aaaaa"], ["aaaaaa"], ["aaaaaaa"], ["z"]]),
        ]))
        let run = String(repeating: "a", count: 4800)
        XCTAssertNil(engine.evaluate(feed(run)))
        XCTAssertNotNil(engine.evaluate(feed(run + "z")))
    }

    func testTopicsMatchWholeNamesAndAuthorsMatchActualUID() throws {
        let engine = try ContentFilterEngine(rules([
            FilterRule(id: "topic", reason: "话题", kind: .topic, values: ["110066", "我在酷安晒女友"]),
            FilterRule(id: "author", reason: "作者", kind: .author, values: ["123"]),
        ]))
        XCTAssertEqual(engine.evaluate(feed("", ids: ["110066"]))?.ruleID, "topic")
        XCTAssertEqual(engine.evaluate(feed("", names: ["我在酷安晒女友"]))?.ruleID, "topic")
        XCTAssertNil(engine.evaluate(feed("我在酷安晒女友", names: ["我在酷安晒女友讨论"])))
        XCTAssertNil(engine.evaluate(feed("回复 @123", uid: "1234")))
        XCTAssertEqual(engine.evaluate(feed("", uid: "123"))?.ruleID, "author")
        XCTAssertEqual(engine.evaluate(FilterInput(scope: .comment, authorUID: "123"))?.ruleID, "author")
    }

    func testOnlyVisibleHTMLTextIsMatched() throws {
        let engine = try ContentFilterEngine(rules([textRule(groups: [["约炮"]])]))
        XCTAssertNil(engine.evaluate(feed(#"<a href="https://x/约炮">正常技术</a><img alt="约炮" src="约炮">"#)))
        XCTAssertNil(engine.evaluate(feed("<script>约炮</script><style>约炮</style>正常")))
        XCTAssertNil(engine.evaluate(feed(#"<span hidden>约炮</span><i aria-hidden="true">约炮</i>正常<!-- 约炮 -->"#)))
        XCTAssertNotNil(engine.evaluate(feed("<b>约</b>&#x70ae;")))
        XCTAssertNotNil(engine.evaluate(feed("约\u{200B}炮")))
        XCTAssertNil(engine.evaluate(feed("约<br>炮")), "块级换行是句子边界")
        XCTAssertNotNil(engine.evaluate(feed("1 < 2 约炮 & 其他")))
    }

    func testProximityWindowAndSentenceScopedExceptions() throws {
        let engine = try ContentFilterEngine(rules([textRule(exceptions: ["反对约炮"])]))
        XCTAssertNotNil(engine.evaluate(feed("想 约炮")))
        XCTAssertNil(engine.evaluate(feed("想" + String(repeating: "普通技术", count: 10) + "约炮")))
        XCTAssertNil(engine.evaluate(feed("想反对约炮")))
        XCTAssertNotNil(engine.evaluate(feed("反对约炮。想约炮")))
    }

    func testDisabledRulesAndExceptionsStayInTheirLane() throws {
        let engine = try ContentFilterEngine(rules([textRule()]))
        let input = feed("想约炮", uid: "123")
        XCTAssertNotNil(engine.evaluate(input))
        XCTAssertNil(engine.evaluate(input, disabledRuleIDs: ["text.test"]))
        XCTAssertNil(engine.evaluate(input, allowedAuthorUIDs: ["123"]))
        XCTAssertNil(engine.evaluate(input, allowedContentKeys: ["feed:1"]))
        XCTAssertNotNil(engine.evaluate(input, allowedContentKeys: ["comment:1"]))
    }

    func testStrictJSONRoundTripAndRejections() throws {
        let json = rules([textRule()]).json
        XCTAssertEqual(try FilterRuleSet(json: json).json, json)
        XCTAssertEqual(try FilterRuleSet(json: FilterRuleSet.builtin.json), .builtin)
        XCTAssertEqual(FilterRuleSet.builtin.json["publishedAt"].string, "2026-10-26T00:00:00.000Z")

        func rule(_ change: (inout [String: JSON]) -> Void) -> JSON {
            var object = textRule().json.object ?? [:]
            change(&object)
            return .object(object)
        }
        func set(_ change: (inout [String: JSON]) -> Void) -> JSON {
            var object = json.object ?? [:]
            change(&object)
            return .object(object)
        }
        for excluded in ["LSP", "ｌｓｐ", "手冲", "后入", "性压抑"] {
            XCTAssertThrowsError(try FilterRule(json: rule { $0["groups"] = .array([.array([.string(excluded)])]) }))
        }
        XCTAssertThrowsError(try FilterRuleSet(json: set { $0["revision"] = .number(0) }))
        XCTAssertThrowsError(try FilterRuleSet(json: set { $0["revision"] = .number(1.5) }))
        XCTAssertThrowsError(try FilterRuleSet(json: set { $0["schemaVersion"] = .number(2) }))
        XCTAssertThrowsError(try FilterRuleSet(json: set { $0["extra"] = .bool(true) }))
        XCTAssertThrowsError(try FilterRuleSet(json: set { $0["publishedAt"] = .string("2026-02-31T00:00:00Z") }))
        XCTAssertThrowsError(try FilterRuleSet(json: set { $0["rules"] = .array([textRule().json, textRule().json]) }))
        XCTAssertThrowsError(try FilterRule(json: rule { $0["maxDistance"] = .number(100_000) }))
        XCTAssertThrowsError(try FilterRule(json: rule {
            $0["groups"] = .array([.array([.string(String(repeating: "a", count: 257))])])
        }))
        XCTAssertThrowsError(try FilterRule(json: rule { $0["id"] = .string("含 空格") }))
        XCTAssertThrowsError(try FilterRule(json: rule { $0["reason"] = .string(" 首尾空白 ") }))
        XCTAssertThrowsError(try FilterRule(json: rule { $0["values"] = .array([.string("1")]) }), "文本规则不能带名单")
        XCTAssertThrowsError(try FilterRule(json: rule { $0["sources"] = .array([.string("http://example.com")]) }))
        XCTAssertThrowsError(try FilterRule(json: rule { $0["scopes"] = .array([.string("feed"), .string("feed")]) }))

        let author = FilterRule(id: "a", reason: "作者", kind: .author, values: ["0123"])
        XCTAssertThrowsError(try author.validated(), "UID 不能以 0 开头")
        let strictList = FilterRule(id: "t", reason: "话题", kind: .topic, level: .strict, values: ["x"])
        XCTAssertThrowsError(try strictList.validated(), "名单规则没有严格档")
        XCTAssertThrowsError(try ContentFilterEngine(rules([author])))
    }

    func testDatesAcceptOffsetsAndFractions() throws {
        let base = try FilterDate.parse(.string("2026-10-26T00:00:00Z"))
        XCTAssertEqual(base, Self.date)
        XCTAssertEqual(try FilterDate.parse(.string("2026-10-26T08:00:00+08:00")), base)
        XCTAssertEqual(try FilterDate.parse(.string("2026-10-26T00:00:00.500Z")), base.addingTimeInterval(0.5))
        XCTAssertEqual(FilterDate.format(base.addingTimeInterval(0.5)), "2026-10-26T00:00:00.500Z")
        for bad in ["2026-10-26", "2026-10-26T24:00:00Z", "2026-13-01T00:00:00Z", "2026-10-26T00:00:00",
                    "2026-10-26T00:00:00.Z", "2026-10-26 00:00:00Z"] {
            XCTAssertThrowsError(try FilterDate.parse(.string(bad)), bad)
        }
    }

    func testNormalization() {
        XCTAssertEqual(FilterText.normalize("  ＡＢＣ　ｄ\u{200B}e\n\tF  "), "abc de f")
        XCTAssertEqual(FilterText.normalize("\u{FEFF}"), "")
    }
}
