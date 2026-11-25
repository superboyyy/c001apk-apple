import XCTest
@testable import CoolapkKit

/// 对应上游 `content_export_test.dart` 的用例。
final class ExportDocumentTests: XCTestCase {
    private func entity(_ fields: [String: Any]) -> Entity { Entity(JSON(fields)) }

    private func reply(_ id: Int, top: Int? = nil, uid: String? = nil) -> Entity {
        var fields: [String: Any] = ["id": id, "uid": uid ?? "\(id)", "message": "评论\(id)", "likenum": id]
        if let top { fields["is_top"] = top }
        return entity(fields)
    }

    private func rawOutput(_ parts: [[String: String]]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: parts), as: UTF8.self)
    }

    // MARK: 评论挑选

    func testPinnedCommentsPrecedePopularOrderDeduplicateAndCapAtThree() {
        let result = ExportDocument.selectComments(
            pinned: [reply(1)], popular: [reply(8), reply(1), reply(4, top: 1), reply(100)])
        XCTAssertEqual(result.map(\.entity.entityID), ["1", "4", "8"])
        XCTAssertEqual(result.map(\.isPinned), [true, true, false])
    }

    func testMultiplePinsOutrankPopularAndBlockedAuthorsStayOut() {
        let result = ExportDocument.selectComments(
            pinned: [reply(1), reply(2), reply(3), reply(4)], popular: [reply(50)], blockedUIDs: ["2"])
        XCTAssertEqual(result.map(\.entity.entityID), ["1", "3", "4"])
    }

    // MARK: 正文

    func testPlainHTMLExportsParagraphsLinksAndMetadata() {
        let doc = ExportDocument(
            feed: entity([
                "id": 12, "username": "作者", "message_title": "标题", "dateline": 1_700_000_000,
                "message": "<p>第一段<br>换行</p><p><a href=\"/u/7\">用户</a> &amp; 正文</p>",
            ]),
            timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let markdown = doc.markdown
        XCTAssertTrue(markdown.hasPrefix("# 标题\n"))
        XCTAssertTrue(markdown.contains("第一段  \n换行"))
        XCTAssertTrue(markdown.contains("[用户](https://www.coolapk.com/u/7) & 正文"))
        XCTAssertTrue(markdown.contains("作者：作者  \n发布时间：2023-11-15 06:13:20"))
        XCTAssertTrue(markdown.contains("https://www.coolapk.com/feed/12"))
        XCTAssertTrue(markdown.contains("https://www.coolapk1s.com/feed/12"))
        XCTAssertFalse(markdown.contains("<p>"))
        XCTAssertFalse(markdown.contains("\n\n\n"), "块之间只留一个空行")
    }

    func testPlainNewlinesBecomeHardBreaks() {
        let doc = ExportDocument(feed: entity(["id": 1, "message": "第一行\n第二行 [doge] #话题# POCO_X3_GT"]))
        XCTAssertTrue(doc.markdown.contains("第一行  \n第二行 \\[doge\\] #话题# POCO\\_X3\\_GT"))
        XCTAssertTrue(doc.html.contains("第一行<br>第二行"))
    }

    func testTitleFallsBackToAuthor() {
        XCTAssertEqual(ExportDocument(feed: entity(["id": 1, "userInfo": ["username": "某人"]])).title, "某人的动态")
        XCTAssertEqual(ExportDocument(feed: entity(["id": 1])).title, "未知作者的动态")
        XCTAssertEqual(ExportDocument(feed: entity(["id": 1, "title": "<b>列表</b>标题"])).title, "列表标题")
    }

    func testMarkdownRetainsCodeTaskListsAndTables() {
        let doc = ExportDocument(feed: entity([
            "id": 1,
            "message": "# 正文\n\n```dart\nfinal x = \"<script>\";\n```\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n- [x] 已完成",
        ]))
        XCTAssertTrue(doc.markdown.contains("```dart\nfinal x = \"<script>\";\n```"))
        XCTAssertTrue(doc.markdown.contains("| A | B |\n| --- | --- |\n| 1 | 2 |"))
        XCTAssertTrue(doc.markdown.contains("- [x] 已完成"))
        XCTAssertTrue(doc.markdown.contains("\n# 正文\n"))
        XCTAssertTrue(doc.html.contains("<table>"))
        XCTAssertTrue(doc.html.contains("<code class=\"language-dart\">final x = \"&lt;script&gt;\";"))
    }

    func testMarkdownInlineSyntaxAndNativeLinks() {
        let doc = ExportDocument(feed: entity([
            "id": 1,
            "message": "**粗体**、*斜体*、~~删除~~ 和 `a*b` "
                + "<a class=\"feed-link-uname\" href=\"/u/a_b_\">@a_b_</a> "
                + "[链接](https://example.com/a(1)) ![图](https://img.example/i.png)\n> 引用一行",
        ]))
        let markdown = doc.markdown
        XCTAssertTrue(markdown.contains("**粗体**、*斜体*、~~删除~~ 和 ` a*b `"))
        XCTAssertTrue(markdown.contains("[@a\\_b\\_](https://www.coolapk.com/u/a_b_)"))
        XCTAssertTrue(markdown.contains("[链接](https://example.com/a%281%29)"))
        XCTAssertTrue(markdown.contains("![图](https://img.example/i.png)"))
        XCTAssertTrue(markdown.contains("> 引用一行"))
        XCTAssertEqual(doc.imageURLs, ["https://img.example/i.png"])
    }

    func testOrdinaryTextIsNotMistakenForMarkdown() {
        for text in ["#一加13# 发布", "型号 POCO_X3_GT 到手", "1. 只有一项", "2 * 3 = 6", "a < b 且 b > c"] {
            XCTAssertNil(MarkdownSource.html(from: text), text)
        }
        XCTAssertNotNil(MarkdownSource.html(from: "- 一\n- 二"))
    }

    func testNestedListsKeepStructure() {
        let doc = ExportDocument(feed: entity(["id": 1, "message": "- 外层\n  - 内层一\n  - 内层二\n- 第二项"]))
        XCTAssertTrue(doc.markdown.contains("- 外层\n  - 内层一\n  - 内层二\n- 第二项"))
    }

    func testStructuredArticlesRetainOrderedTextImagesCaptionsAndLinks() {
        let doc = ExportDocument(feed: entity([
            "id": 1, "message": "摘要",
            "message_raw_output": rawOutput([
                ["type": "text", "message": "前段"],
                ["type": "image", "url": "https://img.example/a.png", "description": "图注"],
                ["type": "text", "message": "后段"],
                ["type": "shareUrl", "title": "引用", "url": "https://example.com/a"],
            ]),
        ]))
        let markdown = doc.markdown
        let first = markdown.range(of: "前段")!.lowerBound
        let caption = markdown.range(of: "图注")!.lowerBound
        let last = markdown.range(of: "后段")!.lowerBound
        XCTAssertLessThan(first, caption)
        XCTAssertLessThan(caption, last)
        XCTAssertFalse(markdown.contains("摘要"))
        XCTAssertEqual(doc.imageURLs, ["https://img.example/a.png"])
        XCTAssertTrue(markdown.contains("![图注](https://img.example/a.png)"))
        XCTAssertTrue(markdown.contains("[引用](https://example.com/a)"))
    }

    func testArticleCoverLeadsAndBrokenStructureFallsBack() {
        let article = ExportDocument(feed: entity([
            "id": 1, "message_cover": "https://img.example/cover.jpg",
            "message_raw_output": rawOutput([["type": "text", "message": "正文"]]),
        ]))
        XCTAssertEqual(article.imageURLs, ["https://img.example/cover.jpg"])
        let broken = ExportDocument(feed: entity(["id": 1, "message": "摘要", "message_raw_output": "{oops"]))
        XCTAssertTrue(broken.markdown.contains("图文结构未能解析"))
        XCTAssertTrue(broken.markdown.contains("摘要"))
    }

    func testForwardsGalleriesAndTopCommentsWithoutSubreplies() {
        let feed = entity([
            "id": 1, "message": "转发",
            "forwardSourceFeed": ["id": 2, "username": "原作者", "message": "**原文**",
                                  "picArr": ["https://img.example/f.png"]],
        ])
        let comment = entity([
            "id": 7, "username": "读者", "message": "置顶内容", "likenum": 9,
            "replyRows": [["id": 8, "message": "不要楼中楼"]],
        ])
        let doc = ExportDocument(feed: feed, comments: [ExportComment(entity: comment, isPinned: true)])
        let markdown = doc.markdown
        XCTAssertTrue(markdown.contains("> 转发自：原作者"))
        XCTAssertTrue(markdown.contains("> **原文**"))
        XCTAssertTrue(markdown.contains("### 【置顶】读者"))
        XCTAssertTrue(markdown.contains("赞：9"))
        XCTAssertFalse(markdown.contains("不要楼中楼"))
        XCTAssertTrue(doc.imageURLs.contains("https://img.example/f.png"))
    }

    func testUnavailableForwardAndNotices() {
        let doc = ExportDocument(feed: entity(["id": 1, "message": "转发", "forwardSourceType": "feed"]),
                                 notices: ["未能取得热门评论"])
        XCTAssertTrue(doc.markdown.contains("转发内容已不可用"))
        XCTAssertTrue(doc.markdown.contains("保存说明：未能取得热门评论"))
    }

    func testForwardsRetainStructuredBodyInsteadOfSummary() {
        let doc = ExportDocument(feed: entity([
            "id": 1, "message": "转发",
            "forwardSourceFeed": [
                "id": 2, "message": "不应取摘要",
                "message_raw_output": rawOutput([
                    ["type": "text", "message": "完整首段"],
                    ["type": "image", "url": "https://img.example/full.png", "description": "完整图"],
                    ["type": "text", "message": "完整末段"],
                ]),
            ],
        ]))
        XCTAssertTrue(doc.markdown.contains("完整末段"))
        XCTAssertFalse(doc.markdown.contains("不应取摘要"))
        XCTAssertTrue(doc.imageURLs.contains("https://img.example/full.png"))
    }

    // MARK: 安全

    func testActiveHTMLAndUnsafeURLsAreRemoved() {
        let doc = ExportDocument(feed: entity([
            "id": 1,
            "message": "<p onclick=\"bad()\">正文<script>secret()</script></p>"
                + "<iframe src=\"https://bad.example\"></iframe><img src=\"file:///secret\">"
                + "<a href=\"javascript:bad()\">链接</a><img src=\"https://img.example/a.png\" onerror=\"bad()\">",
        ]))
        let html = doc.html
        for forbidden in ["<script", "<iframe", "onclick", "onerror", "secret()", "javascript:", "file:///"] {
            XCTAssertFalse(html.contains(forbidden), forbidden)
        }
        XCTAssertTrue(html.contains("正文"))
        XCTAssertTrue(html.contains("链接"))
        XCTAssertEqual(doc.imageURLs, ["https://img.example/a.png"])
    }

    func testImageCaptionsCannotInjectRawHTML() {
        let doc = ExportDocument(feed: entity([
            "id": 1,
            "message_raw_output": rawOutput([
                ["type": "image", "url": "https://img.example/a.png",
                 "description": "\n\n<script>alert(1)</script>\n\n[caption]"],
            ]),
        ]))
        XCTAssertFalse(doc.markdown.contains("<script>"))
        XCTAssertTrue(doc.markdown.contains("![\\<script\\>alert(1)\\</script\\> \\[caption\\]](https://img.example/a.png)"))
        XCTAssertFalse(doc.html.contains("<script>"))
        XCTAssertTrue(doc.html.contains("&lt;script&gt;"))
    }

    func testURLSafetyRules() {
        XCTAssertEqual(HTMLSanitizer.safeURL("/feed/1", image: false), "https://www.coolapk.com/feed/1")
        XCTAssertNil(HTMLSanitizer.safeURL("/feed/1", image: true))
        XCTAssertEqual(HTMLSanitizer.safeURL("//image.coolapk.com/a.jpg", image: true), "https://image.coolapk.com/a.jpg")
        for unsafe in ["javascript:alert(1)", "file:///etc/passwd", "https://user:pw@example.com/", "https://exa mple.com",
                       "data:text/html,x", "coolmarket://feed/1", "https://", ""] {
            XCTAssertNil(HTMLSanitizer.safeURL(unsafe, image: false), unsafe)
        }
    }

    // MARK: 离线 HTML

    func testOfflineHTMLEmbedsImagesAndReplacesMissingOnes() {
        let doc = ExportDocument(feed: entity([
            "id": 1, "message": "内容",
            "picArr": ["https://img.example/a.png", "https://img.example/b.png"],
        ]))
        let offline = doc.offlineHTML(images: [
            "https://img.example/a.png": "data:image/png;base64,AAAA",
            "https://img.example/b.png": "data:image/svg+xml;base64,AAAA",
        ])
        XCTAssertTrue(offline.contains("<img alt=\"\" src=\"data:image/png;base64,AAAA\">"))
        XCTAssertTrue(offline.contains("<a href=\"https://img.example/b.png\">图片未保存：查看来源</a>"))
        XCTAssertFalse(offline.contains("src=\"http"))
        XCTAssertFalse(offline.contains("svg"))
        for forbidden in ["<link", "<script", "<iframe"] { XCTAssertFalse(offline.contains(forbidden)) }
        XCTAssertTrue(offline.hasPrefix("<!doctype html><html lang=\"zh-CN\">"))
        XCTAssertTrue(offline.contains("img-src data:"))
    }

    func testOfflineHTMLTakesBytesFromClosureAndRejectsNonBitmaps() {
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0])
        let doc = ExportDocument(feed: entity([
            "id": 1, "picArr": ["https://img.example/a.png", "https://img.example/b.svg", "https://img.example/c.png"],
        ]))
        var requested: [String] = []
        let offline = doc.offlineHTML { url in
            requested.append(url)
            if url.hasSuffix("a.png") { return png }
            return url.hasSuffix(".svg") ? Data("<svg onload=\"bad()\"/>".utf8) : nil
        }
        XCTAssertEqual(requested, doc.imageURLs)
        XCTAssertTrue(offline.contains("src=\"data:image/png;base64,\(png.base64EncodedString())\""))
        XCTAssertEqual(offline.components(separatedBy: "<img").count, 2)
        XCTAssertEqual(offline.components(separatedBy: "图片未保存").count, 3)
        XCTAssertFalse(offline.contains("onload"))
    }

    func testImageSignatures() {
        XCTAssertEqual(ExportDocument.imageMIME(of: Data([255, 216, 255, 224])), "image/jpeg")
        XCTAssertEqual(ExportDocument.imageMIME(of: Data("GIF89a..".utf8)), "image/gif")
        XCTAssertEqual(ExportDocument.imageMIME(of: Data("RIFF....WEBPVP8 ".utf8)), "image/webp")
        XCTAssertNil(ExportDocument.imageMIME(of: Data("<svg".utf8)))
        XCTAssertNil(ExportDocument.dataURI(for: Data()))
    }

    // MARK: 文件名

    func testFileNameCleansReservedCharactersAndNames() {
        let cleaned = ExportDocument(feed: entity(["id": 12, "message_title": "A:/B*?\"<>|"])).fileName
        XCTAssertNil(cleaned.range(of: #"[<>:"/\\|?*]"#, options: .regularExpression))
        XCTAssertTrue(cleaned.hasSuffix("-12"))
        XCTAssertEqual(ExportDocument(feed: entity(["id": 12, "message_title": "CON"])).fileName, "动态-12")
        XCTAssertEqual(ExportDocument(feed: entity(["id": 12, "message_title": "标题. "])).fileName, "标题-12")
        let long = ExportDocument(feed: entity(["id": 1, "message_title": String(repeating: "长", count: 200)])).fileName
        XCTAssertEqual(long.count, 72)
    }

    func testOrderedListStartSurvivesBothFormats() {
        let doc = ExportDocument(feed: entity(["id": 1, "message": "5. 第五步\n6. 第六步"]))
        XCTAssertTrue(doc.html.contains("<ol start=\"5\">"))
        XCTAssertTrue(doc.markdown.contains("5. 第五步\n6. 第六步"))
    }

    /// 用固定种子拼出大量含语法字符的输入，转换不应崩溃，输出里也不应留下脚本。
    func testConverterSurvivesArbitraryInput() {
        let alphabet = Array("*_`~[]()<>!#-|\\ \n\tab1.>h:/&;\"'=中").map(String.init)
            + ["http://a.b/c", "<a href=\"/u/1\">@x</a>", "<script>x</script>", "```", "- ", "1. ", "> ", "| a | b |\n| - | - |\n", "<br>", "&lt;"]
        var seed: UInt64 = 0x2545_F491_4F6C_DD1D
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        for _ in 0..<3000 {
            let message = (0..<next(40)).map { _ in alphabet[next(alphabet.count)] }.joined()
            let doc = ExportDocument(feed: entity(["id": 1, "message": message]))
            XCTAssertFalse(doc.html.contains("<script"), message)
            XCTAssertTrue(doc.markdown.hasSuffix("\n"), message)
        }
    }

    /// 极深的嵌套（未闭合标签、层层引用、层层强调）不能让递归耗尽调用栈。
    func testDeeplyNestedInputIsFlattened() {
        let inputs = [
            String(repeating: "<b>", count: 20_000) + "文字",
            String(repeating: "<div><p>", count: 10_000),
            String(repeating: "> ", count: 20_000) + "引用",
            String(repeating: "*a ", count: 5_000) + String(repeating: "b* ", count: 5_000),
            (0..<400).map { String(repeating: "  ", count: $0) + "- 第 \($0) 层" }.joined(separator: "\n"),
            String(repeating: "[", count: 3_000) + String(repeating: "](x)", count: 3_000),
        ]
        for input in inputs {
            let doc = ExportDocument(feed: entity(["id": 1, "message": input]))
            XCTAssertFalse(doc.markdown.isEmpty)
            XCTAssertTrue(doc.offlineHTML(images: [:]).hasSuffix("</body></html>"))
        }
    }

    // MARK: HTML 解析

    func testFragmentParserToleratesLooseMarkup() {
        let nodes = HTMLFragment.parse("a < b<br>c &amp; d<!-- x --><ul><li>一<li>二</ul><p>段一<p>段二")
        XCTAssertEqual(HTMLFragment.serialize(nodes),
                       "a &lt; b<br>c &amp; d<ul><li>一</li><li>二</li></ul><p>段一</p><p>段二</p>")
        XCTAssertEqual(HTMLFragment.text(of: HTMLFragment.parse("<b>x</b> &#x4e2d;&#25991;")), "x 中文")
    }
}
