import XCTest
@testable import CoolapkKit

/// 发布相关接口的请求构造。全部经 `RequestStub` 拦截，不触网。
final class PublishRequestTests: XCTestCase {
    override func setUp() { RequestStub.reset() }
    override func tearDown() { RequestStub.reset() }

    private func assertSigned(_ request: RequestStub.Recorded, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(request.header("X-Requested-With"), "XMLHttpRequest", file: file, line: line)
        XCTAssertEqual(request.header("X-App-Id"), RequestToken.appID, file: file, line: line)
        XCTAssertFalse((request.header("X-App-Token") ?? "").isEmpty, file: file, line: line)
        XCTAssertFalse((request.header("X-App-Device") ?? "").isEmpty, file: file, line: line)
        XCTAssertEqual(request.header("Cookie"), "uid=1001; username=tester; token=synthetic-token", file: file, line: line)
    }

    func testMultipartPostKeepsSignedHeadersAndCookie() async throws {
        let client = RequestStub.client()
        _ = try await client.postMultipart(
            "/v6/synthetic/path", query: [("uid", "2")], fields: [("message", "你好 & 再见"), ("message_pic", "")])
        let request = try XCTUnwrap(RequestStub.recorded.first)
        XCTAssertEqual(RequestStub.recorded.count, 1)
        XCTAssertEqual(request.request.httpMethod, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.coolapk.com/v6/synthetic/path?uid=2")
        assertSigned(request)
        let contentType = try XCTUnwrap(request.header("Content-Type"))
        XCTAssertNotNil(contentType.range(
            of: "^multipart/form-data; boundary=--dio-boundary-[0-9]{10}$", options: .regularExpression), contentType)
        let fields = request.multipartFields()
        XCTAssertEqual(fields.map(\.0), ["message", "message_pic"])
        XCTAssertEqual(fields.map(\.1), ["你好 & 再见", ""])
    }

    func testCreateFeedSendsUpstreamFormFields() async throws {
        RequestStub.reset { _ in RequestStub.json(#"{"data":{"id":123,"entityType":"feed"}}"#) }
        let client = RequestStub.client()
        let created = try await client.createFeed(message: "第一条 动态")
        XCTAssertEqual(created.entityID, "123")
        let request = try XCTUnwrap(RequestStub.recorded.first)
        XCTAssertEqual(request.request.httpMethod, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.coolapk.com/v6/feed/createFeed")
        XCTAssertEqual(request.header("Content-Type"), "application/x-www-form-urlencoded")
        assertSigned(request)
        XCTAssertEqual(
            request.bodyText,
            "type=feed&message=%E7%AC%AC%E4%B8%80%E6%9D%A1%20%E5%8A%A8%E6%80%81&status=1&pic=&publish_status=0")
    }

    func testCreateFeedWithTargetPicturesAndPrivateFlag() {
        let topic = CoolapkClient.createFeedForm(
            message: "#数码# 你好", pics: ["https://img.example/feed/a.png", "https://img.example/feed/b.jpeg"],
            targetType: "tag", targetID: "42", onlySelf: true)
        XCTAssertEqual(topic.map(\.0), ["type", "targetType", "targetId", "message", "status", "pic", "publish_status"])
        XCTAssertEqual(topic.map(\.1), [
            "feed", "tag", "42", "#数码# 你好", "1",
            "https://img.example/feed/a.png,https://img.example/feed/b.jpeg", "1",
        ])
        // 应用页下发的是点评。
        let app = CoolapkClient.createFeedForm(message: "好用", pics: [], targetType: "apk", targetID: "7", onlySelf: false)
        XCTAssertEqual(app.first?.1, "comment")
        XCTAssertEqual(app.last?.1, "0")
    }

    func testReplyWithPicturesAndForward() async throws {
        RequestStub.reset { _ in RequestStub.json(#"{"data":{"id":9,"entityType":"feed_reply"}}"#) }
        let client = RequestStub.client()
        let reply = try await client.postReply(
            id: "555", type: .reply, message: "收到", pics: ["https://img.example/feed/a.png", "https://img.example/feed/b.png"],
            forward: true)
        XCTAssertEqual(reply.entityType, "feed_reply")
        let request = try XCTUnwrap(RequestStub.recorded.first)
        XCTAssertEqual(request.request.httpMethod, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.coolapk.com/v6/feed/reply?id=555&type=reply")
        XCTAssertEqual(request.header("Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertEqual(
            request.bodyText,
            "message=%E6%94%B6%E5%88%B0&replyAndForward=1&pic=https%3A%2F%2Fimg.example%2Ffeed%2Fa.png%2Chttps%3A%2F%2Fimg.example%2Ffeed%2Fb.png")
    }

    func testReplyWithoutPicturesSendsEmptyPicField() async throws {
        let client = RequestStub.client()
        _ = try await client.postReply(id: "1", type: .feed, message: "a", pics: [])
        let request = try XCTUnwrap(RequestStub.recorded.first)
        XCTAssertEqual(request.url.query, "id=1&type=feed")
        XCTAssertEqual(request.bodyText, "message=a&replyAndForward=0&pic=")
    }

    /// 原有的纯文本回复接口保持不变。
    func testPlainTextReplyIsUnchanged() async throws {
        let client = RequestStub.client()
        _ = try await client.postReply(id: "1", type: "feed", message: "a b")
        let request = try XCTUnwrap(RequestStub.recorded.first)
        XCTAssertEqual(request.url.query, "id=1&type=feed")
        XCTAssertEqual(request.bodyText, "message=a%20b&replyAndForward=0")
    }

    func testBusinessFailureSurfacesServerMessage() async {
        RequestStub.reset { _ in RequestStub.json(#"{"status":-1,"message":"动态内容不能为空"}"#) }
        do {
            _ = try await RequestStub.client().createFeed(message: "")
            XCTFail("应当抛出错误")
        } catch {
            XCTAssertEqual(APIError.from(error), APIError(.business, "动态内容不能为空"))
        }
    }

    // MARK: 验证码

    func testLegacyCaptchaFailureIsMarked() async {
        RequestStub.reset { _ in
            RequestStub.json(#"{"status":-1,"message":"请输入验证码","messageStatus":"err_request_captcha"}"#)
        }
        do {
            _ = try await RequestStub.client().createFeed(message: "a")
            XCTFail("应当抛出错误")
        } catch {
            let failure = APIError.from(error)
            XCTAssertEqual(failure.kind, .captcha)
            XCTAssertEqual(failure.serverStatus, "err_request_captcha")
        }
    }

    func testCaptchaImageRequest() async throws {
        RequestStub.reset { _ in (200, ["Content-Type": "image/png"], Data([0x89, 0x50, 0x4E, 0x47])) }
        let data = try await RequestStub.client().captchaImage()
        XCTAssertEqual(data, Data([0x89, 0x50, 0x4E, 0x47]))
        let request = try XCTUnwrap(RequestStub.recorded.first)
        XCTAssertEqual(request.request.httpMethod, "GET")
        XCTAssertEqual(request.path, "/v6/account/captchaImage")
        XCTAssertEqual(request.query["w"], "270")
        XCTAssertEqual(request.query["h"], "113")
        XCTAssertNotNil(request.query["_"].flatMap(Int.init))
        assertSigned(request)
    }

    func testSubmitCaptchaRequestAndResult() async throws {
        RequestStub.reset { _ in RequestStub.json(#"{"data":"验证通过"}"#) }
        let client = RequestStub.client()
        try await client.submitCaptcha(code: "ab12")
        let request = try XCTUnwrap(RequestStub.recorded.first)
        XCTAssertEqual(request.request.httpMethod, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://api.coolapk.com/v6/account/requestValidate")
        let fields = request.multipartFields()
        XCTAssertEqual(fields.map(\.0), ["type", "code"])
        XCTAssertEqual(fields.map(\.1), ["err_request_captcha", "ab12"])

        RequestStub.reset { _ in RequestStub.json(#"{"data":"其他结果"}"#) }
        do {
            try await client.submitCaptcha(code: "ab12")
            XCTFail("应当抛出错误")
        } catch {
            XCTAssertEqual(APIError.from(error).kind, .business)
        }
    }

    /// 滑块验证通过后，multipart 请求带着证明字段原样重发一次。
    func testMultipartRetriesOnceWithVerificationProof() async throws {
        RequestStub.reset { request in
            if request.bodyText.contains("_v2_post_token") {
                return RequestStub.json(#"{"data":[{"id":7,"entityType":"message"}]}"#)
            }
            return RequestStub.json(#"{"message":"当前访问需要验证码","messageStatus":"err_request_captcha_v2","messageExtra":"{\"captchaType\":\"NEC\",\"captchaId\":\"5fc4c10eccd64d178982bc560da43a91\",\"captchaField\":\"_v2_post_token\"}","code":403}"#)
        }
        let client = RequestStub.client()
        client.captchaHandler = { challenge in challenge.proof(validate: "synthetic_validate") }
        let response = try await CoolapkClient.interactive {
            try await client.postMultipart("/v6/synthetic/path", fields: [("message", "hi")])
        }
        XCTAssertEqual(response.data[0]["id"].int, 7)
        XCTAssertEqual(RequestStub.recorded.count, 2)
        XCTAssertEqual(RequestStub.recorded[0].multipartFields().map(\.0), ["message"])
        let retried = RequestStub.recorded[1].multipartFields()
        XCTAssertEqual(retried.map(\.0), ["message", "_v2_post_token"])
        XCTAssertEqual(retried.last?.1, "NEC:5fc4c10e:synthetic_validate")
    }

    /// 没有交互许可时不弹验证，也不重发。
    func testChallengeWithoutPromptIsNotRetried() async {
        RequestStub.reset { _ in
            RequestStub.json(#"{"message":"当前访问需要验证码","messageStatus":"err_request_captcha_v2","code":403}"#)
        }
        let client = RequestStub.client()
        client.captchaHandler = { _ in
            XCTFail("不应请求验证")
            return nil
        }
        do {
            _ = try await client.postMultipart("/v6/synthetic/path", fields: [("message", "hi")])
            XCTFail("应当抛出错误")
        } catch {
            XCTAssertEqual(APIError.from(error).kind, .captcha)
        }
        XCTAssertEqual(RequestStub.recorded.count, 1)
    }
}
