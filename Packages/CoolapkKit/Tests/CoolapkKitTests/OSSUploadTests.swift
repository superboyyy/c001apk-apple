import XCTest
@testable import CoolapkKit

/// 图片上传：准备接口的参数、OSS 签名与请求头。全部离线。
final class OSSUploadTests: XCTestCase {
    override func setUp() { RequestStub.reset() }
    override func tearDown() { RequestStub.reset() }

    private let bytes = Data("synthetic image bytes".utf8)

    private func image(_ name: String = "abc.png") -> UploadImage {
        UploadImage(data: bytes, width: 96, height: 96, contentType: "image/png", name: name)
    }

    private func ticketJSON(paths: [String], endpoint: String = "https://oss-cn-synthetic.example.com") -> JSON {
        let files = paths.map { #"{"name":"x","uploadFileName":"\#($0)"}"# }.joined(separator: ",")
        return JSON.parse(#"{"fileInfo":[\#(files)],"uploadPrepareInfo":{"accessKeyId":"synthetic-key","accessKeySecret":"synthetic-secret","securityToken":"synthetic-sts-token","endPoint":"\#(endpoint)","bucket":"synthetic-bucket","uploadImagePrefix":"https://img.example"}}"#)!
    }

    func testUploadImageDescribesTheFile() {
        let picture = image()
        XCTAssertEqual(picture.md5Hex, "36d6f6fdae38d0b263620fa4d14db342")
        XCTAssertEqual(picture.resolution, "96x96")
        let generated = UploadImage(data: bytes, width: 1, height: 2, contentType: "image/jpeg")
        XCTAssertNotNil(generated.name.range(of: "^[0-9a-f]{32}\\.jpeg$", options: .regularExpression), generated.name)
        XCTAssertEqual(UploadImage.sniffContentType(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(UploadImage.sniffContentType(Data([0x89, 0x50, 0x4E, 0x47, 0x0D])), "image/png")
        XCTAssertEqual(UploadImage.sniffContentType(Data("GIF89a".utf8)), "image/gif")
        XCTAssertEqual(UploadImage.sniffContentType(Data("RIFF\u{1}\u{2}\u{3}\u{4}WEBPVP8 ".utf8)), "image/webp")
        XCTAssertNil(UploadImage.sniffContentType(Data("plain text".utf8)))
    }

    func testPrepareFieldsMatchUpstreamShape() {
        let feed = OSSUpload.prepareFields(images: [image("a.png"), image("b.png")], scope: .feed)
        XCTAssertEqual(feed.map(\.0), ["uploadBucket", "uploadDir", "is_anonymous", "uploadFileList", "toUid"])
        XCTAssertEqual(feed[0].1, "image")
        XCTAssertEqual(feed[1].1, "feed")
        XCTAssertEqual(feed[2].1, "0")
        XCTAssertEqual(
            feed[3].1,
            #"[{"name":"a.png","resolution":"96x96","md5":"36d6f6fdae38d0b263620fa4d14db342"}, {"name":"b.png","resolution":"96x96","md5":"36d6f6fdae38d0b263620fa4d14db342"}]"#)
        XCTAssertEqual(feed[4].1, "")
        XCTAssertNotNil(JSON.parse(feed[3].1)?.array, "字段本身是合法 JSON")

        let message = OSSUpload.prepareFields(images: [image()], scope: .message(toUID: "2"))
        XCTAssertEqual(message.map(\.1), [
            "message", "message", "0",
            #"[{"name":"abc.png","resolution":"96x96","md5":"36d6f6fdae38d0b263620fa4d14db342"}]"#, "2",
        ])
    }

    func testHTTPDateFormat() {
        XCTAssertEqual(OSSUpload.httpDate(Date(timeIntervalSince1970: 1_795_600_000)), "Wed, 25 Nov 2026 09:46:40 GMT")
        XCTAssertEqual(OSSUpload.httpDate(Date(timeIntervalSince1970: 0)), "Thu, 01 Jan 1970 00:00:00 GMT")
    }

    /// 期望值由独立的 Python `hmac`/`hashlib` 实现算出。
    func testSignatureMatchesIndependentVector() {
        XCTAssertEqual(OSSUpload.contentMD5(bytes), "Ntb2/a440LJjYg+k0U2zQg==")
        let canonical = OSSUpload.canonicalString(
            method: "PUT", contentMD5: "Ntb2/a440LJjYg+k0U2zQg==", contentType: "image/png",
            date: "Wed, 25 Nov 2026 09:46:40 GMT",
            headers: [
                "Content-Type": "image/png",
                "X-OSS-Security-Token": " synthetic-sts-token ",
                "x-oss-callback-var": OSSUpload.callbackVar,
                "x-oss-callback": OSSUpload.callback,
            ],
            bucket: "synthetic-bucket", objectPath: "feed/2026/1125/abc@96x96.png")
        XCTAssertEqual(canonical, [
            "PUT", "Ntb2/a440LJjYg+k0U2zQg==", "image/png", "Wed, 25 Nov 2026 09:46:40 GMT",
            "x-oss-callback:\(OSSUpload.callback)",
            "x-oss-callback-var:eyJ4OnZhcjEiOiJmYWxzZSJ9",
            "x-oss-security-token:synthetic-sts-token",
            "/synthetic-bucket/feed/2026/1125/abc@96x96.png",
        ].joined(separator: "\n"))
        XCTAssertEqual(
            OSSUpload.authorization(accessKeyID: "synthetic-key", accessKeySecret: "synthetic-secret", canonicalString: canonical),
            "OSS synthetic-key:VRN5WZ4Duuz/OBICg2T2UL4B6fY=")
    }

    func testCallbackConstantsDecodeToCoolapkCallback() throws {
        let callback = try XCTUnwrap(Data(base64Encoded: OSSUpload.callback).flatMap(JSON.parse))
        XCTAssertEqual(callback["callbackHost"].string, "api.coolapk.com")
        XCTAssertEqual(
            callback["callbackUrl"].string,
            "https://api.coolapk.com/v6/callback/mobileOssUploadSuccessCallback?checkArticleCoverResolution=0&versionCode=2102031")
        XCTAssertEqual(String(decoding: try XCTUnwrap(Data(base64Encoded: OSSUpload.callbackVar)), as: UTF8.self), #"{"x:var1":"false"}"#)
    }

    func testTicketParsingAndReferences() throws {
        let ticket = try OSSUploadTicket(
            data: ticketJSON(paths: ["feed/2026/1125/a@96x96.png", "feed/2026/1125/b@96x96.png"]), scope: .feed, count: 2)
        XCTAssertEqual(ticket.endpoint, "oss-cn-synthetic.example.com", "接入点去掉协议头")
        XCTAssertEqual(ticket.bucket, "synthetic-bucket")
        XCTAssertEqual(ticket.reference(at: 1, scope: .feed), "https://img.example/feed/2026/1125/b@96x96.png")

        let message = try OSSUploadTicket(
            data: ticketJSON(paths: ["message/2026/1125/a@96x96.png"]), scope: .message(toUID: "2"), count: 1)
        XCTAssertEqual(message.reference(at: 0, scope: .message(toUID: "2")), "/message/2026/1125/a@96x96.png")
    }

    func testTicketRejectsIncompleteOrUnexpectedData() {
        func rejects(_ data: JSON, scope: UploadScope = .feed, count: Int = 1, line: UInt = #line) {
            XCTAssertThrowsError(try OSSUploadTicket(data: data, scope: scope, count: count), line: line) {
                XCTAssertEqual(APIError.from($0).kind, .invalidResponse, line: line)
            }
        }
        rejects(.null)
        rejects(JSON.parse(#"{"fileInfo":[{"uploadFileName":"feed/a.png"}]}"#)!)
        rejects(ticketJSON(paths: ["feed/a.png"]), count: 2)
        rejects(ticketJSON(paths: ["message/a.png"]), scope: .feed)
        rejects(ticketJSON(paths: ["feed/a.png"]), scope: .message(toUID: "2"))
        rejects(ticketJSON(paths: ["feed/../a.png"]))
        rejects(ticketJSON(paths: ["feed/a.png"], endpoint: "https://evil.example/path?x="))
        var missingSecret = ticketJSON(paths: ["feed/a.png"])
        if case .object(var root) = missingSecret, case .object(var info)? = root["uploadPrepareInfo"] {
            info["accessKeySecret"] = .string("")
            root["uploadPrepareInfo"] = .object(info)
            missingSecret = .object(root)
        }
        rejects(missingSecret)
    }

    func testUploadRequestHeadersAndBody() throws {
        let ticket = try OSSUploadTicket(data: ticketJSON(paths: ["feed/2026/1125/abc@96x96.png"]), scope: .feed, count: 1)
        let request = try OSSUpload.request(
            ticket: ticket, objectPath: ticket.objectPaths[0], data: bytes, contentType: "image/png",
            date: Date(timeIntervalSince1970: 1_795_600_000))
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://synthetic-bucket.oss-cn-synthetic.example.com/feed/2026/1125/abc@96x96.png")
        XCTAssertEqual(request.httpBody, bytes)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-MD5"), "Ntb2/a440LJjYg+k0U2zQg==")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Date"), "Wed, 25 Nov 2026 09:46:40 GMT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-oss-security-token"), "synthetic-sts-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-oss-callback"), OSSUpload.callback)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-oss-callback-var"), OSSUpload.callbackVar)
        // 与上面独立算出的签名一致：请求头里的取值就是参与签名的取值。
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "OSS synthetic-key:VRN5WZ4Duuz/OBICg2T2UL4B6fY=")
    }

    func testUploadImagesPreparesThenPutsEachFile() async throws {
        let prepared = ticketJSON(paths: ["feed/2026/1125/a@96x96.png", "feed/2026/1125/b@96x96.png"])
        let envelope = String(decoding: JSON.object(["data": prepared]).serialized()!, as: UTF8.self)
        RequestStub.reset { request in
            request.path == "/v6/upload/ossUploadPrepare" ? RequestStub.json(envelope) : (200, [:], Data())
        }
        let events = Events()
        let pics = try await RequestStub.client().uploadImages([image("a.png"), image("b.png")], scope: .feed) {
            events.append($0)
        }
        XCTAssertEqual(pics, [
            "https://img.example/feed/2026/1125/a@96x96.png", "https://img.example/feed/2026/1125/b@96x96.png",
        ])
        let requests = RequestStub.recorded
        XCTAssertEqual(requests.count, 3)

        let prepare = requests[0]
        XCTAssertEqual(prepare.request.httpMethod, "POST")
        XCTAssertEqual(prepare.url.absoluteString, "https://api.coolapk.com/v6/upload/ossUploadPrepare")
        XCTAssertEqual(prepare.header("Cookie"), "uid=1001; username=tester; token=synthetic-token")
        let fields = prepare.multipartFields()
        XCTAssertEqual(fields.map(\.0), ["uploadBucket", "uploadDir", "is_anonymous", "uploadFileList", "toUid"])
        XCTAssertEqual(JSON.parse(fields[3].1)?.array?.map { $0["name"].string }, ["a.png", "b.png"])

        for (index, name) in ["a", "b"].enumerated() {
            let put = requests[index + 1]
            XCTAssertEqual(put.request.httpMethod, "PUT")
            XCTAssertEqual(
                put.url.absoluteString,
                "https://synthetic-bucket.oss-cn-synthetic.example.com/feed/2026/1125/\(name)@96x96.png")
            XCTAssertEqual(put.body, bytes)
            XCTAssertEqual(put.header("Content-MD5"), "Ntb2/a440LJjYg+k0U2zQg==")
            XCTAssertTrue((put.header("Authorization") ?? "").hasPrefix("OSS synthetic-key:"))
            // 账号 Cookie 和酷安签名头只发给酷安，不能带到 OSS。
            XCTAssertNil(put.header("Cookie"))
            XCTAssertNil(put.header("X-App-Token"))
            XCTAssertNil(put.header("X-App-Device"))
        }
        XCTAssertEqual(events.values.filter { $0.fraction == 0 }.map(\.index), [0, 1])
        XCTAssertTrue(events.values.allSatisfy { $0.total == 2 })
    }

    func testUploadFailureStopsBeforeLaterFiles() async {
        let prepared = ticketJSON(paths: ["message/2026/1125/a@96x96.png"])
        let envelope = String(decoding: JSON.object(["data": prepared]).serialized()!, as: UTF8.self)
        RequestStub.reset { request in
            request.path == "/v6/upload/ossUploadPrepare" ? RequestStub.json(envelope) : (403, [:], Data("<Error/>".utf8))
        }
        do {
            _ = try await RequestStub.client().uploadImages([image()], scope: .message(toUID: "2"))
            XCTFail("应当抛出错误")
        } catch {
            XCTAssertEqual(APIError.from(error), APIError(.transport, "图片上传失败，请检查网络后重试"))
        }
        XCTAssertEqual(RequestStub.recorded.count, 2)
        XCTAssertEqual(RequestStub.recorded[0].multipartFields().last?.1, "2", "私信图片带上接收方 uid")
    }

    func testRejectedPreparationUploadsNothing() async {
        RequestStub.reset { _ in RequestStub.json(#"{"status":-1,"message":"图片数量超出限制"}"#) }
        do {
            _ = try await RequestStub.client().uploadImages([image()], scope: .feed)
            XCTFail("应当抛出错误")
        } catch {
            XCTAssertEqual(APIError.from(error), APIError(.business, "图片数量超出限制"))
        }
        XCTAssertEqual(RequestStub.recorded.count, 1)

        RequestStub.reset()
        do {
            _ = try await RequestStub.client().uploadImages(
                [UploadImage(data: Data(), width: 1, height: 1, contentType: "image/png")], scope: .feed)
            XCTFail("应当抛出错误")
        } catch {
            XCTAssertEqual(APIError.from(error).kind, .business)
        }
        XCTAssertTrue(RequestStub.recorded.isEmpty, "无效图片不发任何请求")
    }
}

/// 线程安全地收集进度回调。
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CoolapkClient.UploadProgress] = []

    func append(_ value: CoolapkClient.UploadProgress) { lock.withLock { storage.append(value) } }
    var values: [CoolapkClient.UploadProgress] { lock.withLock { storage } }
}
