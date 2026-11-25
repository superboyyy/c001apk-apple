import XCTest
@testable import CoolapkKit

/// 对应上游 `service_test.dart` 与 `projection_test.dart` 中不涉及界面和网络的部分。
final class ContentFilterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_972_800)
    private let subscriptionURL = "https://example.com/rules.json"

    private func subscription(_ revision: Int, _ rules: [FilterRule] = []) -> Data {
        FilterRuleSet(revision: revision, publishedAt: now, rules: rules).json.serialized() ?? Data()
    }

    private func personal() -> FilterRule {
        FilterRule(id: "personal.one", reason: "个人", kind: .text, groups: [["个人屏蔽词"]])
    }

    private func enabled() -> ContentFilter {
        var filter = ContentFilter()
        filter.setEnabled(true)
        return filter
    }

    private func restored(_ filter: ContentFilter) throws -> ContentFilter {
        let data = try XCTUnwrap(filter.snapshot.serialized())
        return ContentFilter(snapshot: try XCTUnwrap(JSON.parse(data)))
    }

    private func entity(_ json: String) throws -> Entity { Entity(try XCTUnwrap(JSON.parse(json))) }

    // MARK: 状态

    func testDisabledByDefaultAndNeverDueWithoutSubscription() throws {
        var filter = ContentFilter()
        XCTAssertFalse(filter.isEnabled)
        XCTAssertEqual(filter.subscriptionURL, "")
        XCTAssertNil(filter.evaluate(FilterInput(scope: .feed, authorUID: "1007278")))
        XCTAssertFalse(filter.isUpdateDue(now: now))
        filter.setEnabled(true)
        XCTAssertEqual(filter.level, .standard)
        XCTAssertNotNil(filter.evaluate(FilterInput(scope: .feed, authorUID: "1007278")))
        XCTAssertFalse(filter.isUpdateDue(now: now), "没有订阅地址就不联网")
        filter.setLevel(.strict)
        let copy = try restored(filter)
        XCTAssertTrue(copy.isEnabled)
        XCTAssertEqual(copy.level, .strict)
    }

    func testUpdateIsDueEverySixHoursAfterSuccess() throws {
        var filter = enabled()
        try filter.setSubscriptionURL(subscriptionURL)
        XCTAssertTrue(filter.isUpdateDue(now: now))
        try filter.applySubscription(subscription(2), now: now)
        XCTAssertFalse(filter.isUpdateDue(now: now.addingTimeInterval(6 * 3600 - 1)))
        XCTAssertTrue(filter.isUpdateDue(now: now.addingTimeInterval(6 * 3600)))
        XCTAssertThrowsError(try filter.applySubscription(Data("<html>error</html>".utf8), now: now.addingTimeInterval(9)))
        XCTAssertEqual(filter.lastCheckedAt, now, "失败不记为成功")
        XCTAssertEqual(try restored(filter).lastCheckedAt, now)
        filter.setEnabled(false)
        XCTAssertFalse(filter.isUpdateDue(now: now.addingTimeInterval(86_400)))
    }

    func testSubscriptionReplacesWholeSetAndKeepsPersonalChoices() throws {
        var filter = enabled()
        try filter.setSubscriptionURL(subscriptionURL)
        try filter.applySubscription(subscription(2, [
            FilterRule(id: "author.one", reason: "已审核", kind: .author, values: ["123"]),
        ]), now: now)
        try filter.addPersonalRule(personal())
        try filter.setRuleDisabled("other", true)
        try filter.setAuthorAllowed("456", true)
        try filter.setContentAllowed("feed:7", true)
        XCTAssertNotNil(filter.evaluate(FilterInput(scope: .feed, authorUID: "123")))
        XCTAssertNil(filter.evaluate(FilterInput(scope: .feed, authorUID: "1007278")), "内置规则已被整体替换")
        try filter.applySubscription(subscription(3), now: now)
        XCTAssertNil(filter.evaluate(FilterInput(scope: .feed, authorUID: "123")))
        XCTAssertNotNil(filter.evaluate(FilterInput(scope: .comment, text: "个人屏蔽词")))

        var copy = try restored(filter)
        XCTAssertEqual(copy.ruleSet.revision, 3)
        XCTAssertEqual(copy.subscriptionURL, subscriptionURL)
        XCTAssertEqual(copy.personalRules.count, 1)
        XCTAssertTrue(copy.disabledRuleIDs.contains("other"))
        XCTAssertTrue(copy.allowedAuthorUIDs.contains("456"))
        XCTAssertTrue(copy.allowedContentKeys.contains("feed:7"))
        copy.removePersonalRule("personal.one")
        XCTAssertTrue(copy.personalRules.isEmpty)
        XCTAssertNil(copy.evaluate(FilterInput(scope: .comment, text: "个人屏蔽词")))
    }

    func testDisabledListCoversLaterSubscriptionsAndPersonalRulesStayIndependent() throws {
        func rules(_ uid: String, _ topic: String) -> [FilterRule] {
            [
                FilterRule(id: "author.\(uid)", reason: "用户分类", kind: .author, values: [uid]),
                FilterRule(id: "topic.\(topic)", reason: "话题分类", kind: .topic, values: [topic]),
                FilterRule(id: "text.synthetic", reason: "文本分类", kind: .text, groups: [["合成过滤短语"]]),
            ]
        }
        var filter = enabled()
        try filter.setSubscriptionURL(subscriptionURL)
        try filter.applySubscription(subscription(2, rules("123", "456")), now: now)
        XCTAssertNotNil(filter.evaluate(FilterInput(scope: .feed, authorUID: "123")))
        try filter.setListEnabled(.author, false)
        XCTAssertNil(filter.evaluate(FilterInput(scope: .feed, authorUID: "123")))
        XCTAssertNotNil(filter.evaluate(FilterInput(scope: .feed, topicIDs: ["456"])))
        XCTAssertNotNil(filter.evaluate(FilterInput(scope: .feed, text: "合成过滤短语")))
        try filter.setListEnabled(.topic, false)
        try filter.addPersonalRule(FilterRule(id: "personal.author", reason: "个人用户", kind: .author, values: ["123"]))
        XCTAssertEqual(filter.evaluate(FilterInput(scope: .feed, authorUID: "123"))?.ruleID, "personal.author")
        try filter.applySubscription(subscription(3, rules("789", "987")), now: now)

        var copy = try restored(filter)
        XCTAssertFalse(copy.isListEnabled(.author))
        XCTAssertFalse(copy.isListEnabled(.topic))
        XCTAssertNil(copy.evaluate(FilterInput(scope: .feed, authorUID: "789")))
        XCTAssertNil(copy.evaluate(FilterInput(scope: .feed, topicIDs: ["987"])))
        XCTAssertEqual(copy.evaluate(FilterInput(scope: .feed, authorUID: "123"))?.ruleID, "personal.author")
        try copy.setListEnabled(.author, true)
        XCTAssertEqual(copy.evaluate(FilterInput(scope: .feed, authorUID: "789"))?.ruleID, "author.789")
        XCTAssertNil(copy.evaluate(FilterInput(scope: .feed, topicIDs: ["987"])))
        XCTAssertThrowsError(try copy.setListEnabled(.text, false))
    }

    func testEnablingAListRestoresItsDisabledRulesOnly() throws {
        var filter = enabled()
        try filter.setSubscriptionURL(subscriptionURL)
        try filter.applySubscription(subscription(2, [
            FilterRule(id: "author.one", reason: "用户分类", kind: .author, values: ["123"]),
            FilterRule(id: "topic.one", reason: "话题分类", kind: .topic, values: ["456"]),
        ]), now: now)
        try filter.setRuleDisabled("author.one", true)
        try filter.setRuleDisabled("topic.one", true)
        var copy = try restored(filter)
        XCTAssertTrue(copy.isListEnabled(.author))
        XCTAssertNil(copy.evaluate(FilterInput(scope: .feed, authorUID: "123")))
        try copy.setListEnabled(.author, true)
        XCTAssertEqual(copy.evaluate(FilterInput(scope: .feed, authorUID: "123"))?.ruleID, "author.one")
        XCTAssertTrue(copy.disabledRuleIDs.contains("topic.one"))
    }

    func testRejectsDowngradeTamperingOversizeAndNamespaceAbuse() throws {
        var filter = enabled()
        try filter.setSubscriptionURL(subscriptionURL)
        try filter.applySubscription(subscription(2), now: now)
        try filter.applySubscription(subscription(2), now: now)
        let expected = filter.ruleSet
        let oversized = Data(repeating: 0x20, count: ContentFilter.maxSubscriptionBytes + 1)
        let tampered = subscription(2, [FilterRule(id: "author.x", reason: "同版本改动", kind: .author, values: ["9"])])
        for payload in [subscription(1), tampered, subscription(3, [personal()]),
                        Data("<html>error</html>".utf8), Data("[]".utf8), oversized] {
            XCTAssertThrowsError(try filter.applySubscription(payload, now: now))
            XCTAssertEqual(filter.ruleSet, expected)
        }
    }

    func testDamagedCacheFallsBackToBuiltinAndKeepsValidPersonalRules() throws {
        var filter = enabled()
        try filter.addPersonalRule(personal())
        try filter.setRuleDisabled("personal.one", true)
        var object = try XCTUnwrap(filter.snapshot.object)
        object["ruleSet"] = .object(["schemaVersion": .number(999)])
        object["personalRules"] = .array([
            personal().json, .string("坏条目"), personal().json,
            FilterRule(id: "not-personal", reason: "前缀无效", kind: .text, groups: [["合成词"]]).json,
        ])
        var copy = ContentFilter(snapshot: .object(object))
        XCTAssertTrue(copy.cacheWasDamaged)
        XCTAssertEqual(copy.ruleSet, .builtin)
        XCTAssertEqual(copy.personalRules.map(\.id), ["personal.one"])
        XCTAssertTrue(copy.disabledRuleIDs.contains("personal.one"))

        // 缓存里的订阅同样不能占用个人命名空间。
        object["ruleSet"] = FilterRuleSet(revision: 4, publishedAt: now, rules: [
            FilterRule(id: "personal.cached", reason: "缓存冲突", kind: .author, values: ["123"]),
        ]).json
        copy = ContentFilter(snapshot: .object(object))
        XCTAssertEqual(copy.ruleSet.revision, FilterRuleSet.builtin.revision)
        XCTAssertEqual(ContentFilter(snapshot: .string("完全损坏")).ruleSet, .builtin)
    }

    func testPersonalRulesAreValidatedAndNamespaced() throws {
        var filter = enabled()
        XCTAssertThrowsError(try filter.addPersonalRule(
            FilterRule(id: "personal.bad", reason: "无效", kind: .text, groups: [["ＬＳＰ"]])))
        XCTAssertThrowsError(try filter.addPersonalRule(
            FilterRule(id: "not-personal", reason: "前缀无效", kind: .text, groups: [["合成词"]])))
        XCTAssertThrowsError(try filter.addPersonalRule(kind: .author, value: "abc"))
        XCTAssertThrowsError(try filter.addPersonalRule(kind: .text, value: "  "))
        XCTAssertTrue(filter.personalRules.isEmpty)

        try filter.addPersonalRule(personal())
        XCTAssertThrowsError(try filter.addPersonalRule(personal()), "重复 ID")
        let author = try filter.addPersonalRule(kind: .author, value: " 42 ", now: now)
        let topic = try filter.addPersonalRule(kind: .topic, value: "某个话题", now: now)
        try filter.addPersonalRule(kind: .text, value: "某个短语", now: now)
        XCTAssertNotEqual(author.id, topic.id, "同一时刻新建的规则 ID 不重复")
        XCTAssertEqual(filter.evaluate(FilterInput(scope: .feed, authorUID: "42"))?.ruleID, author.id)
        XCTAssertEqual(filter.evaluate(FilterInput(scope: .feed, topicNames: ["某个话题"]))?.ruleID, topic.id)
        XCTAssertNil(filter.evaluate(FilterInput(scope: .feed, topicNames: ["某个话题2"])))
        XCTAssertNil(filter.evaluate(FilterInput(scope: .comment, text: "这里有某个 短语吗")), "按完整短语匹配")
        XCTAssertNotNil(filter.evaluate(FilterInput(scope: .comment, text: "这里有某个短语")))
        try filter.setRuleDisabled(author.id, true)
        XCTAssertNil(filter.evaluate(FilterInput(scope: .feed, authorUID: "42")))
    }

    func testExceptionsAreBoundedAndReversible() throws {
        var filter = enabled()
        let input = FilterInput(scope: .feed, id: "9", authorUID: "1007278")
        XCTAssertNotNil(filter.evaluate(input))
        try filter.setContentAllowed("feed:9", true)
        XCTAssertNil(filter.evaluate(input))
        try filter.setContentAllowed("feed:9", false)
        try filter.setAuthorAllowed("1007278", true)
        XCTAssertNil(filter.evaluate(input))
        try filter.setAuthorAllowed("1007278", false)
        XCTAssertNotNil(filter.evaluate(input))
        XCTAssertThrowsError(try filter.setAuthorAllowed("", true))
        XCTAssertThrowsError(try filter.setContentAllowed(String(repeating: "x", count: 201), true))
    }

    func testChangingSubscriptionURLDropsOldRules() throws {
        var filter = enabled()
        XCTAssertThrowsError(try filter.setSubscriptionURL("http://example.com/rules.json"))
        XCTAssertThrowsError(try filter.setSubscriptionURL("https://user@example.com/rules.json"))
        XCTAssertThrowsError(try filter.setSubscriptionURL("rules.json"))
        try filter.setSubscriptionURL(subscriptionURL)
        try filter.applySubscription(subscription(5), now: now)
        try filter.setSubscriptionURL(subscriptionURL)
        XCTAssertEqual(filter.ruleSet.revision, 5, "地址没变就不重置")
        try filter.setSubscriptionURL("")
        XCTAssertEqual(filter.ruleSet, .builtin)
        XCTAssertNil(filter.lastCheckedAt)
        XCTAssertFalse(filter.isUpdateDue(now: now))
    }

    // MARK: 列表行

    func testTopicMetadataUsesWholeNamesAndIDs() throws {
        let filter = enabled()
        XCTAssertNotNil(filter.match(try entity(#"{"entityType":"feed","tags":"我在酷安晒女友"}"#)))
        XCTAssertNotNil(filter.match(try entity(##"{"entityType":"feed","tags":"#摄影#,#我在酷安晒女友#"}"##)))
        XCTAssertNil(filter.match(try entity(#"{"entityType":"feed","tags":"我在酷安晒女友的手机"}"#)))
        XCTAssertNotNil(filter.match(try entity(
            #"{"entityType":"feed","relationRows":[{"id":110066,"entityType":"topic"}]}"#)))
        XCTAssertNotNil(filter.match(try entity(
            #"{"entityType":"feed","targetRow":{"id":110066,"entityType":"feedTarget","url":"/t/%E8%AF%9D%E9%A2%98"}}"#)))
        XCTAssertNil(filter.match(try entity(
            #"{"entityType":"feed","targetRow":{"id":110066,"entityType":"product","url":"/product/110066"}}"#)))
        XCTAssertNotNil(filter.match(try entity(#"{"entityType":"feed","ttitle":"我在酷安晒女友"}"#)))
        XCTAssertNotNil(filter.match(try entity(#"{"entityType":"topic","id":110066,"title":"别的名字"}"#)))
    }

    func testTopicLinksInBodyCountButOnlyOnCoolapk() throws {
        let filter = enabled()
        let encoded = "%E6%88%91%E5%9C%A8%E9%85%B7%E5%AE%89%E6%99%92%E5%A5%B3%E5%8F%8B"
        func feed(_ href: String, label: String = "#话题#") throws -> Entity {
            let message = "看看<a class=\"feed-link-tag\" href=\"\(href)\">\(label)</a>"
            let data = try JSONSerialization.data(withJSONObject: ["entityType": "feed", "message": message])
            return Entity(try XCTUnwrap(JSON.parse(data)))
        }
        XCTAssertNotNil(filter.match(try feed("/t/\(encoded)?type=0")))
        XCTAssertNotNil(filter.match(try feed("https://www.coolapk.com/t/\(encoded)")))
        XCTAssertNotNil(filter.match(try feed("/t/123", label: "#我在酷安晒女友#")))
        XCTAssertNil(filter.match(try feed("https://example.com/t/\(encoded)")))
        XCTAssertNil(filter.match(try feed("/u/\(encoded)")))
        XCTAssertEqual(ContentFilterProjection.topicTag(inHref: "//m.coolapk.com/t/abc#x"), "abc")
        XCTAssertNil(ContentFilterProjection.topicTag(inHref: "coolmarket://t/abc"))
    }

    func testRepliesAreJudgedOnTheirOwn() throws {
        let filter = enabled()
        let parent = try entity(#"""
        {"entityType":"feed","id":1,"uid":7,"message":"刷机方法",
         "replyRows":[{"entityType":"feed_reply","id":2,"uid":1007278,"message":"hello"}]}
        """#)
        XCTAssertNil(filter.match(parent))
        XCTAssertNotNil(filter.match(try XCTUnwrap(parent.replyRows.first)))
        XCTAssertNil(filter.match(try entity(
            #"{"entityType":"feed_reply","uid":8,"ruid":1007278,"message":"感谢分享"}"#)))
    }

    func testQuotedTextDoesNotLabelTheReply() throws {
        let filter = enabled()
        for message in ["<blockquote>想操她</blockquote>请不要这样说", "> 想操她\n\n请文明讨论", "> > 想操她\n\n请文明讨论",
                        "[quote=某人]想操她[/quote]请文明讨论", "<div class=\"x feed-quote\">想操她</div>请文明讨论",
                        "<blockquote><a href=\"/t/我在酷安晒女友\">#我在酷安晒女友#</a></blockquote>讨论过滤功能"] {
            let data = try JSONSerialization.data(withJSONObject: ["entityType": "feed_reply", "uid": 8, "message": message])
            XCTAssertNil(filter.match(Entity(try XCTUnwrap(JSON.parse(data)))), message)
        }
        XCTAssertNotNil(filter.match(try entity(#"{"entityType":"feed_reply","uid":8,"message":"想操她"}"#)))
        XCTAssertEqual(ContentFilterProjection.withoutQuotes("a &amp; b<blockquote>引用</blockquote><br>c"),
                       "a &amp; b<br>c")
    }

    func testOnlyFeedsCommentsAndUsersAreInScope() throws {
        let filter = enabled()
        XCTAssertNil(filter.match(try entity(#"{"entityType":"notification","uid":1007278,"message":"想操她"}"#)))
        XCTAssertNil(filter.match(try entity(#"{"entityType":"message","uid":1007278,"message":"想操她"}"#)))
        XCTAssertNotNil(filter.match(try entity(#"{"entityType":"user","uid":1007278}"#)))
        XCTAssertNotNil(filter.match(try entity(#"{"entityType":"contacts","id":1007278}"#)))
        XCTAssertNotNil(filter.match(try entity(#"{"entityType":"notification","uid":1007278}"#), scope: .comment))
        var off = filter
        off.setEnabled(false)
        XCTAssertNil(off.match(try entity(#"{"entityType":"user","uid":1007278}"#)))
    }

    func testArticlePartsAndTitlesParticipate() throws {
        let filter = enabled()
        for part in [#"{"type":"image","description":"想操她"}"#, #"{"type":"shareUrl","title":"想操她"}"#,
                     #"{"type":"text","message":"想操她"}"#] {
            let data = try JSONSerialization.data(withJSONObject: [
                "entityType": "feed", "message": "普通摘要", "message_raw_output": "[\(part)]",
            ])
            XCTAssertNotNil(filter.match(Entity(try XCTUnwrap(JSON.parse(data)))), part)
        }
        XCTAssertNotNil(filter.match(try entity(#"{"entityType":"feed","message_title":"想操她","message":"正文"}"#)))
        XCTAssertNil(filter.match(try entity(
            #"{"entityType":"feed","message":"正文","message_raw_output":"[{\"type\":\"other\",\"message\":\"想操她\"}]"}"#)))
        XCTAssertNil(filter.match(try entity(#"{"entityType":"feed","message":"正文","message_raw_output":"{坏的"}"#)))
    }

    func testContentKeysFollowScopeAndID() throws {
        let reply = try entity(#"{"entityType":"feed_reply","id":5,"uid":1007278}"#)
        XCTAssertEqual(ContentFilterProjection.key(of: reply), "comment:5")
        XCTAssertEqual(ContentFilterProjection.key(of: reply, scope: .feed), "feed:5")
        XCTAssertEqual(ContentFilterProjection.key(of: try entity(#"{"entityType":"user","uid":9}"#)), "user:9")
        var filter = enabled()
        XCTAssertNotNil(filter.match(reply))
        try filter.setContentAllowed(ContentFilterProjection.key(of: reply), true)
        XCTAssertNil(filter.match(reply))
        let user = try entity(#"{"entityType":"user","uid":1007278}"#)
        XCTAssertNotNil(filter.match(user))
        try filter.setContentAllowed(ContentFilterProjection.key(of: user), true)
        XCTAssertNil(filter.match(user), "没有 ID 的用户卡片按 UID 记例外")
        XCTAssertNotNil(filter.match(try entity(#"{"entityType":"feed","id":6,"uid":1007278}"#)))
    }
}
