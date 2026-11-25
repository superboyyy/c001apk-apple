import XCTest
@testable import CoolapkKit

final class ModelTests: XCTestCase {
    func testJSONReadsMixedTypesLeniently() {
        let json = JSON.parse(#"{"id": 75230358, "uid": "2377629", "flag": true, "ratio": 1.5, "none": null}"#)!
        XCTAssertEqual(json["id"].string, "75230358")
        XCTAssertEqual(json["id"].int, 75_230_358)
        XCTAssertEqual(json["uid"].int, 2_377_629)
        XCTAssertEqual(json["flag"].bool, true)
        XCTAssertEqual(json["ratio"].string, "1.5")
        XCTAssertTrue(json["none"].isNull)
        XCTAssertTrue(json["missing"]["deeper"].isNull)
        XCTAssertNil(json["none"].text)
    }

    func testEntityPicturesAcceptEveryPayloadShape() {
        let list = Entity(JSON.parse(#"{"picArr": ["http://image.coolapk.com/a@1x2.jpg", ""]}"#)!)
        XCTAssertEqual(list.pictures, ["http://image.coolapk.com/a@1x2.jpg"])
        // 公开网页版的图片链接不带协议头。
        let web = Entity(JSON.parse(#"{"picArr": ["//image.coolapk.com/a@1x2.jpg"]}"#)!)
        XCTAssertEqual(web.pictures, ["https://image.coolapk.com/a@1x2.jpg"])
        let nested = Entity(JSON.parse(#"{"imageUriList": [{"url": "https://image.coolapk.com/b.png"}]}"#)!)
        XCTAssertEqual(nested.pictures, ["https://image.coolapk.com/b.png"])
        XCTAssertTrue(Entity(JSON.parse(#"{"picArr": [""]}"#)!).pictures.isEmpty)
    }

    func testDatelineFallsBackToCreateTime() {
        let web = Entity(JSON.parse(#"{"dateline": "3天前", "create_time": 1795340885}"#)!)
        XCTAssertEqual(web.dateline, 1_795_340_885)
    }

    func testDeviceCodeRoundTrip() throws {
        var identity = ClientIdentity()
        let fields = try XCTUnwrap(ClientIdentity.decodeDevice(identity.deviceCode))
        XCTAssertEqual(fields.count, 9)
        XCTAssertTrue(fields[0].hasPrefix("ca_"))
        XCTAssertEqual(fields[6], " Pixel 7")
        XCTAssertFalse(identity.deviceCode.contains("="))

        let install = fields[0]
        identity.model = "Pixel 8"
        identity.refreshDeviceCode()
        let updated = try XCTUnwrap(ClientIdentity.decodeDevice(identity.deviceCode))
        XCTAssertEqual(updated[0], install, "editing the profile keeps the install id")
        XCTAssertEqual(updated[6], " Pixel 8")

        identity.regenerateDeviceCode()
        XCTAssertNotEqual(ClientIdentity.decodeDevice(identity.deviceCode)?[0], install)
        XCTAssertTrue(identity.userAgent.hasSuffix("+CoolMarket/16.2.0-2604201-universal"))
    }

    func testCaptchaChallengeParsing() throws {
        let body = JSON.parse(#"{"message":"当前访问需要验证码","messageStatus":"err_request_captcha_v2","messageExtra":"{\"captchaType\":\"NEC\",\"captchaId\":\"5fc4c10eccd64d178982bc560da43a91\",\"captchaField\":\"\"}","code":403}"#)
        let challenge = try XCTUnwrap(CaptchaChallenge.from(body: body))
        XCTAssertEqual(challenge.captchaID, "5fc4c10eccd64d178982bc560da43a91")
        XCTAssertEqual(challenge.field, "", "a blank field selects the validate cookie protocol")
        let proof = try XCTUnwrap(challenge.proof(validate: "abc_DEF"))
        XCTAssertEqual(proof, "NEC:5fc4c10e:abc_DEF")
        XCTAssertTrue(challenge.accepts(proof: proof))
        XCTAssertNil(challenge.proof(validate: "has space"))
        XCTAssertNil(CaptchaChallenge.from(body: JSON.parse(#"{"data": []}"#)))

        let legacy = try XCTUnwrap(CaptchaChallenge.from(body: JSON.parse(#"{"messageStatus":"err_request_captcha_v2"}"#)))
        XCTAssertEqual(legacy.field, "_v2_post_token")
    }

    func testEnvelopeValidation() throws {
        func validate(_ text: String, status: Int = 200, path: String = "/v6/x") throws -> JSON {
            try APIError.validate(status: status, body: JSON.parse(text), path: path, allowSuccessWithoutData: false)
        }
        XCTAssertNoThrow(try validate(#"{"data": []}"#))
        XCTAssertThrowsError(try validate(#"{"message":"当前访问需要验证码","messageStatus":"err_request_captcha_v2","code":403}"#)) {
            XCTAssertEqual(($0 as? APIError)?.kind, .captcha)
        }
        XCTAssertThrowsError(try validate(#"{"status":-10,"message":"x"}"#)) {
            XCTAssertEqual(($0 as? APIError)?.kind, .riskControl)
        }
        XCTAssertThrowsError(try validate(#"{"messageStatus":"err_request_need_upgrade_new_version"}"#)) {
            XCTAssertEqual(($0 as? APIError)?.kind, .clientUpgrade)
        }
        XCTAssertThrowsError(try validate(#"{"message":"请先登录","status":-1}"#)) {
            XCTAssertEqual(($0 as? APIError)?.kind, .authentication)
        }
        XCTAssertThrowsError(try validate(#"{"data": []}"#, status: 502)) {
            XCTAssertEqual(($0 as? APIError)?.kind, .http)
        }
        XCTAssertThrowsError(try validate(#"{"status": 1}"#)) {
            XCTAssertEqual(($0 as? APIError)?.kind, .invalidResponse)
        }
        XCTAssertNoThrow(try APIError.validate(status: 200, body: JSON.parse(#"{"status": 1, "message": "ok"}"#),
                                               path: "/v6/x", allowSuccessWithoutData: true))
    }

    func testURLBuildingMergesAndEncodesQueries() throws {
        let (url, path) = try XCTUnwrap(CoolapkClient.makeURL(
            host: CoolapkClient.apiHost, path: "/v6/page/dataList?url=V11_VERTICAL_TOPIC&title=话题",
            query: [("page", "1"), ("skip", nil), ("url2", "/page?url=A&b=c")]))
        XCTAssertEqual(path, "/v6/page/dataList")
        XCTAssertEqual(
            url.absoluteString,
            "https://api.coolapk.com/v6/page/dataList?url=V11_VERTICAL_TOPIC&title=%E8%AF%9D%E9%A2%98&page=1&url2=%2Fpage%3Furl%3DA%26b%3Dc")
    }

    func testListPagesExpandCardsAndKeepCursors() {
        let body = JSON.parse(#"""
        {"data": [
          {"entityType": "card", "entityTemplate": "listCard", "entities": [
            {"entityType": "feed", "entityTemplate": "feed", "id": 11},
            {"entityType": "user", "uid": 5}
          ]},
          {"entityType": "card", "entityTemplate": "unknownAdCard", "id": 12},
          {"entityType": "feed", "entityTemplate": "feed", "id": 13}
        ]}
        """#)!
        let page = CoolapkClient.page(from: CoolapkClient.Response(body: body))
        XCTAssertEqual(page.items.map(\.entityType), ["feed", "user", "feed"])
        XCTAssertEqual(page.firstItem, "11")
        XCTAssertEqual(page.lastItem, "13")
    }
}
