import Foundation
import XCTest
@testable import CoolapkKit

/// 拦截测试客户端发出的全部请求：记录下来并返回预设响应，任何请求都不会真正发到网络。
final class RequestStub: URLProtocol {
    struct Recorded {
        let request: URLRequest
        let body: Data

        var url: URL { request.url! }
        var path: String { url.path }
        var bodyText: String { String(decoding: body, as: UTF8.self) }

        /// 按出现顺序解码查询参数。
        var query: [String: String] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        }

        func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }

        /// 解析 multipart 请求体，返回按顺序排列的文本字段。
        func multipartFields(file: StaticString = #filePath, line: UInt = #line) -> [(String, String)] {
            let contentType = header("Content-Type") ?? ""
            guard let range = contentType.range(of: "multipart/form-data; boundary=") else {
                XCTFail("不是 multipart 请求：\(contentType)", file: file, line: line)
                return []
            }
            let boundary = String(contentType[range.upperBound...])
            let text = bodyText
            guard text.hasSuffix("--\(boundary)--\r\n") else {
                XCTFail("请求体没有以结束分隔符收尾", file: file, line: line)
                return []
            }
            return text.components(separatedBy: "--\(boundary)\r\n").dropFirst().compactMap { segment in
                let pieces = segment.components(separatedBy: "\r\n\r\n")
                guard pieces.count >= 2,
                      let name = pieces[0].range(of: #"(?<=name=")[^"]*"#, options: .regularExpression)
                else { return nil }
                var value = pieces.dropFirst().joined(separator: "\r\n\r\n")
                if let end = value.range(of: "\r\n--\(boundary)--\r\n", options: .backwards) {
                    value.removeSubrange(end.lowerBound...)
                } else if value.hasSuffix("\r\n") {
                    // "\r\n" 在 Swift 里是一个字符，按标量去掉两个。
                    value = String(String.UnicodeScalarView(value.unicodeScalars.dropLast(2)))
                }
                return (String(pieces[0][name]), value)
            }
        }
    }

    typealias Reply = (status: Int, headers: [String: String], body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _recorded: [Recorded] = []
    nonisolated(unsafe) private static var _responder: (@Sendable (Recorded) -> Reply)?

    static var recorded: [Recorded] { lock.withLock { _recorded } }

    /// 清空记录并设置响应；默认对所有请求返回 `{"data":{}}`。
    static func reset(_ responder: (@Sendable (Recorded) -> Reply)? = nil) {
        lock.withLock {
            _recorded = []
            _responder = responder
        }
    }

    static func json(_ text: String, status: Int = 200) -> Reply {
        (status, ["Content-Type": "application/json"], Data(text.utf8))
    }

    /// 一个已登录的测试客户端，账号和设备都是合成数据。
    static func client(loggedIn: Bool = true) -> CoolapkClient {
        CoolapkClient(
            identity: ClientIdentity(),
            account: loggedIn ? Account(uid: "1001", username: "tester", token: "synthetic-token") : nil,
            sessionCookie: nil, protocolClasses: [RequestStub.self])
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let recorded = Recorded(request: request, body: body)
        let responder = RequestStub.lock.withLock { () -> (@Sendable (Recorded) -> Reply)? in
            RequestStub._recorded.append(recorded)
            return RequestStub._responder
        }
        let reply = responder?(recorded) ?? RequestStub.json(#"{"data":{}}"#)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
