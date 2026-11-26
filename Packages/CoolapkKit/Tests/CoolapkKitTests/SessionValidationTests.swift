import XCTest
@testable import CoolapkKit

/// 人机验证凭证与接口会话 Cookie 的配合。
final class SessionValidationTests: XCTestCase {
    private static let challenge = #"{"message":"当前访问需要验证码","messageStatus":"err_request_captcha_v2","messageExtra":"{\"captchaType\":\"NEC\",\"captchaId\":\"5fc4c10eccd64d178982bc560da43a91\",\"captchaField\":\"\"}","code":403}"#

    /// 验证通过的那次响应换了会话 Cookie 时，凭证要跟到新会话上，
    /// 否则下一个请求又会被要求验证。
    func testProofSurvivesSessionIssuedByAcceptedRetry() async throws {
        RequestStub.reset { request in
            let cookie = request.header("Cookie") ?? ""
            if cookie.contains("validate=") {
                var reply = RequestStub.json(#"{"data":{"ok":1}}"#)
                reply.headers["Set-Cookie"] = "SESSID=second; Path=/"
                return reply
            }
            var reply = RequestStub.json(Self.challenge)
            reply.headers["Set-Cookie"] = "SESSID=first; Path=/"
            return reply
        }
        let client = RequestStub.client()
        let prompts = Counter()
        client.captchaHandler = { challenge in
            prompts.increment()
            return challenge.proof(validate: "synthetic_validate")
        }
        _ = try await CoolapkClient.interactive { try await client.get("/v6/synthetic/first") }
        _ = try await CoolapkClient.interactive { try await client.get("/v6/synthetic/second") }

        XCTAssertEqual(prompts.value, 1, "验证只应进行一次")
        XCTAssertEqual(RequestStub.recorded.count, 3)
        let last = RequestStub.recorded[2].header("Cookie") ?? ""
        XCTAssertTrue(last.contains("SESSID=second"), last)
        XCTAssertTrue(last.contains("validate=NEC%3A5fc4c10e%3Asynthetic_validate"), last)
    }

    /// 与验证无关的请求换了会话时，旧凭证不再沿用。
    func testProofIsDroppedWhenSessionChangesLater() async throws {
        let rotate = Counter()
        RequestStub.reset { request in
            let cookie = request.header("Cookie") ?? ""
            guard cookie.contains("validate=") else { return RequestStub.json(Self.challenge) }
            var reply = RequestStub.json(#"{"data":{"ok":1}}"#)
            if request.path.hasSuffix("/rotate") {
                rotate.increment()
                reply.headers["Set-Cookie"] = "SESSID=rotated; Path=/"
            }
            return reply
        }
        let client = RequestStub.client()
        client.captchaHandler = { $0.proof(validate: "synthetic_validate") }
        _ = try await CoolapkClient.interactive { try await client.get("/v6/synthetic/first") }
        _ = try await client.get("/v6/synthetic/rotate")
        XCTAssertEqual(rotate.value, 1)

        client.captchaHandler = nil
        do {
            _ = try await client.get("/v6/synthetic/after")
            XCTFail("换了会话后应重新要求验证")
        } catch {
            XCTAssertEqual(APIError.from(error).kind, .captcha)
        }
        XCTAssertFalse((RequestStub.recorded.last?.header("Cookie") ?? "").contains("validate="))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
