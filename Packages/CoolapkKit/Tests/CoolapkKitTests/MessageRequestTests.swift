import XCTest
@testable import CoolapkKit

/// 私信接口的请求构造与响应解析。全部经 `RequestStub` 拦截，不触网。
final class MessageRequestTests: XCTestCase {
    override func setUp() { RequestStub.reset() }
    override func tearDown() { RequestStub.reset() }

    func testChatKeyOrdersUserIDsNumerically() {
        XCTAssertEqual(CoolapkClient.chatKey(uid: "1001", with: "2"), "2_1001")
        XCTAssertEqual(CoolapkClient.chatKey(uid: "2", with: "1001"), "2_1001")
        XCTAssertEqual(CoolapkClient.chatKey(uid: "999", with: "1000"), "999_1000")
        XCTAssertNil(CoolapkClient.chatKey(uid: "", with: "2"))
        XCTAssertNil(CoolapkClient.chatKey(uid: "abc", with: "2"))
    }

    func testMessageListRequestAndCursor() async throws {
        RequestStub.reset { _ in
            RequestStub.json(#"{"data":[{"id":10,"entityType":"message","ukey":"2_1001","messageUid":2,"messageUsername":"联系人甲","is_top":1,"unreadNum":3},{"id":11,"entityType":"card","entityTemplate":"unknownCard"}]}"#)
        }
        let client = RequestStub.client()
        let first = try await client.messageList(page: 1)
        XCTAssertEqual(first.items.count, 1)
        XCTAssertEqual(first.items[0]["ukey"].string, "2_1001")
        XCTAssertEqual(first.firstItem, "10")
        XCTAssertEqual(first.lastItem, "11")
        _ = try await client.messageList(page: 2, firstItem: first.firstItem, lastItem: first.lastItem)
        let requests = RequestStub.recorded
        XCTAssertEqual(requests.map { $0.request.httpMethod }, ["GET", "GET"])
        XCTAssertEqual(requests[0].url.absoluteString, "https://api.coolapk.com/v6/message/list?page=1")
        XCTAssertEqual(requests[1].url.absoluteString, "https://api.coolapk.com/v6/message/list?page=2&firstItem=10&lastItem=11")
        XCTAssertEqual(requests[0].header("Cookie"), "uid=1001; username=tester; token=synthetic-token")
    }

    func testChatHistoryRequestKeepsTimeSeparators() async throws {
        RequestStub.reset { _ in
            RequestStub.json(#"{"data":[{"entityType":"messageExtra","title":"昨天 20:00"},{"id":5,"entityType":"message","fromuid":2,"message":"早"},{"id":6,"entityType":"message","fromuid":1001,"message":"好"},{"entityType":"card","entityTemplate":"unknownCard"},{"entityType":"card","entityTemplate":"noMoreDataCard"}]}"#)
        }
        let page = try await RequestStub.client().chatHistory(ukey: "2_1001", page: 3, firstItem: "9", lastItem: "7")
        XCTAssertEqual(page.items.map(\.entityType), ["messageExtra", "message", "message", "card"])
        XCTAssertEqual(page.items.last?.entityTemplate, "noMoreDataCard")
        XCTAssertEqual(page.firstItem, "5")
        XCTAssertEqual(page.lastItem, "6")
        let request = try XCTUnwrap(RequestStub.recorded.first)
        XCTAssertEqual(request.request.httpMethod, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://api.coolapk.com/v6/message/chat?ukey=2_1001&page=3&firstItem=9&lastItem=7")
    }

    func testSendMessageRequestAndAcknowledgement() async throws {
        RequestStub.reset { _ in
            RequestStub.json(#"{"data":[{"id":100,"entityId":100,"entityType":"message","fromuid":1001,"message":"第一条","dateline":1760000000}]}"#)
        }
        let client = RequestStub.client()
        let sent = try await client.sendMessage(uid: "2", message: "第一条")
        XCTAssertEqual(sent.entityID, "100")
        let request = try XCTUnwrap(RequestStub.recorded.first)
        XCTAssertEqual(request.request.httpMethod, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.coolapk.com/v6/message/send?uid=2")
        let fields = request.multipartFields()
        XCTAssertEqual(fields.map(\.0), ["message", "message_pic"])
        XCTAssertEqual(fields.map(\.1), ["第一条", ""])

        // 图片消息：文字留空，图片引用放在 message_pic；单个对象形式的回执同样接受。
        RequestStub.reset { _ in RequestStub.json(#"{"data":{"id":101,"entityType":"message"}}"#) }
        let picture = try await client.sendMessage(uid: "2", message: "", pic: "/message/2026/1125/a@96x96.png")
        XCTAssertEqual(picture.entityID, "101")
        XCTAssertEqual(RequestStub.recorded[0].multipartFields().map(\.1), ["", "/message/2026/1125/a@96x96.png"])
    }

    func testSendMessageWithoutRecordIsUnconfirmed() async {
        RequestStub.reset { _ in RequestStub.json(#"{"data":[]}"#) }
        do {
            _ = try await RequestStub.client().sendMessage(uid: "2", message: "a")
            XCTFail("应当抛出错误")
        } catch {
            XCTAssertEqual(APIError.from(error).kind, .invalidResponse)
        }
        XCTAssertEqual(RequestStub.recorded.count, 1, "结果未确认时不自动重发")
    }

    func testMessageImageURLReadsRedirectTarget() async throws {
        RequestStub.reset { _ in (302, ["Location": "https://img.example/message/a.png?sign=synthetic"], Data()) }
        let client = RequestStub.client()
        let url = try await client.messageImageURL(id: "100")
        XCTAssertEqual(url?.absoluteString, "https://img.example/message/a.png?sign=synthetic")
        let request = try XCTUnwrap(RequestStub.recorded.first)
        XCTAssertEqual(request.request.httpMethod, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://api.coolapk.com/v6/message/showImage?id=100&type=s")

        RequestStub.reset { _ in RequestStub.json(#"{"data":{}}"#) }
        let missing = try await client.messageImageURL(id: "100")
        XCTAssertNil(missing)
        RequestStub.reset { _ in (302, ["Location": "javascript:alert(1)"], Data()) }
        let unsafe = try await client.messageImageURL(id: "100")
        XCTAssertNil(unsafe)
    }

    func testConversationMutationsUseGetWithKey() async throws {
        RequestStub.reset { _ in RequestStub.json(#"{"data":{"count":"操作成功"}}"#) }
        let client = RequestStub.client()
        try await client.setConversationPinned(true, ukey: "2_1001")
        try await client.setConversationPinned(false, ukey: "2_1001")
        try await client.deleteConversation(ukey: "2_1001")
        try await client.deleteMessage(ukey: "2_1001", id: "100")
        let requests = RequestStub.recorded
        XCTAssertEqual(requests.map { $0.request.httpMethod }, ["GET", "GET", "GET", "GET"])
        XCTAssertEqual(requests.map(\.url.absoluteString), [
            "https://api.coolapk.com/v6/message/addTop?ukey=2_1001",
            "https://api.coolapk.com/v6/message/removeTop?ukey=2_1001",
            "https://api.coolapk.com/v6/message/deleteChat?ukey=2_1001",
            "https://api.coolapk.com/v6/message/delete?ukey=2_1001&id=100",
        ])
    }

    func testMutationNeedsServerConfirmation() async {
        XCTAssertTrue(CoolapkClient.confirmsMessageMutation(JSON.parse(#"{"count":"操作成功"}"#)!))
        XCTAssertTrue(CoolapkClient.confirmsMessageMutation(.number(1)))
        XCTAssertTrue(CoolapkClient.confirmsMessageMutation(.string("ok")))
        XCTAssertFalse(CoolapkClient.confirmsMessageMutation(.null))
        XCTAssertFalse(CoolapkClient.confirmsMessageMutation(.bool(false)))
        XCTAssertFalse(CoolapkClient.confirmsMessageMutation(.string("  ")))
        XCTAssertFalse(CoolapkClient.confirmsMessageMutation(JSON.parse(#"{"other":1}"#)!))

        RequestStub.reset { _ in RequestStub.json(#"{"data":false}"#) }
        do {
            try await RequestStub.client().deleteConversation(ukey: "2_1001")
            XCTFail("应当抛出错误")
        } catch {
            XCTAssertEqual(APIError.from(error).kind, .invalidResponse)
        }
    }
}
