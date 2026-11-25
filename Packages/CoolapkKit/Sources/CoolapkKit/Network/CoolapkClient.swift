import CryptoKit
import Foundation

/// 酷安 Android 接口客户端。移植自 Flutter 端的 `Request`、`ApiInterceptor`、
/// `ApiSessionStore`，只保留桌面阅读器需要的部分。账号凭证与会话值不会写入日志。
public final class CoolapkClient: @unchecked Sendable {
    public static let apiHost = "https://api.coolapk.com"
    public static let api2Host = "https://api2.coolapk.com"
    public static let accountHost = "https://account.coolapk.com"
    public static let webHost = "https://www.coolapk.com"

    public struct Response: Sendable {
        /// 完整的响应信封。
        public let body: JSON
        public var data: JSON { body["data"] }
        public var message: String { body["message"].string ?? "" }
    }

    /// 匿名接口会话，以及与之绑定、已被服务端接受的验证凭证。
    public struct SessionCookie: Codable, Sendable, Equatable {
        public var value: String
        public var identity: String
        public var expiresAt: Date
        public var validation: String?
        public var validationExpiresAt: Date?
    }

    /// 只有调用方为当前任务显式开启（用户主动发起的操作）时，请求才会弹出人机验证；
    /// 后台加载永远不弹。
    @TaskLocal public static var allowsVerificationPrompt = false

    /// 在允许弹出人机验证的前提下执行 `operation`。
    nonisolated(nonsending) public static func interactive<T>(
        _ operation: nonisolated(nonsending) () async throws -> T
    ) async rethrows -> T {
        try await $allowsVerificationPrompt.withValue(true, operation: operation)
    }

    /// 请求界面展示人机验证；返回凭证，取消则返回 `nil`。
    public typealias CaptchaHandler = @Sendable (CaptchaChallenge) async -> String?

    private let session: URLSession
    /// 直传图片用的会话：不带酷安请求头，超时更长。
    private let uploadSession: URLSession
    private let lock = NSLock()
    private var _identity: ClientIdentity
    private var _account: Account?
    private var _sessionCookie: SessionCookie?
    private var _generation = 0
    private var _captchaHandler: CaptchaHandler?
    private var _onSessionCookieChange: (@Sendable (SessionCookie?) -> Void)?
    private let verifier = CaptchaGate()

    public convenience init(identity: ClientIdentity, account: Account? = nil, sessionCookie: SessionCookie? = nil) {
        self.init(identity: identity, account: account, sessionCookie: sessionCookie, protocolClasses: nil)
    }

    /// 测试用入口：`protocolClasses` 可换成拦截请求的 `URLProtocol`，不触网。
    init(identity: ClientIdentity, account: Account?, sessionCookie: SessionCookie?, protocolClasses: [AnyClass]?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["Accept-Language": "zh-CN,zh;q=0.9"]
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration)
        let uploadConfiguration = URLSessionConfiguration.ephemeral
        uploadConfiguration.httpCookieStorage = nil
        uploadConfiguration.httpShouldSetCookies = false
        uploadConfiguration.httpCookieAcceptPolicy = .never
        uploadConfiguration.urlCache = nil
        uploadConfiguration.timeoutIntervalForRequest = 60
        uploadConfiguration.timeoutIntervalForResource = 300
        if let protocolClasses { uploadConfiguration.protocolClasses = protocolClasses }
        uploadSession = URLSession(configuration: uploadConfiguration)
        _identity = identity
        _account = account
        _sessionCookie = sessionCookie
    }

    // MARK: 状态

    public var identity: ClientIdentity {
        get { lock.withLock { _identity } }
        set {
            lock.withLock {
                guard _identity != newValue else { return }
                _identity = newValue
                _generation += 1
            }
        }
    }

    public var account: Account? {
        get { lock.withLock { _account } }
        set {
            lock.withLock {
                guard _account != newValue else { return }
                _account = newValue
                _generation += 1
            }
        }
    }

    public var isLoggedIn: Bool { account != nil }

    public var captchaHandler: CaptchaHandler? {
        get { lock.withLock { _captchaHandler } }
        set { lock.withLock { _captchaHandler = newValue } }
    }

    public var onSessionCookieChange: (@Sendable (SessionCookie?) -> Void)? {
        get { lock.withLock { _onSessionCookieChange } }
        set { lock.withLock { _onSessionCookieChange = newValue } }
    }

    /// 设备与账号的哈希；保存的会话 Cookie 只在收到它的那个身份下复用。
    private func identityHashLocked() -> String {
        let parts = [_identity.deviceCode, _account?.uid ?? "", _account?.token ?? ""]
        return SHA256.hash(data: Data(parts.joined(separator: "\u{1f}").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: 请求

    public func get(
        _ path: String,
        query: [(String, String?)] = [],
        host: String = CoolapkClient.apiHost,
        skipCaptcha: Bool = false,
        allowSuccessWithoutData: Bool = false
    ) async throws -> Response {
        try await send(method: "GET", path: path, query: query, form: nil, host: host,
                       skipCaptcha: skipCaptcha, allowSuccessWithoutData: allowSuccessWithoutData)
    }

    public func post(
        _ path: String,
        query: [(String, String?)] = [],
        form: [(String, String)] = [],
        host: String = CoolapkClient.apiHost,
        skipCaptcha: Bool = false,
        allowSuccessWithoutData: Bool = false
    ) async throws -> Response {
        try await send(method: "POST", path: path, query: query, form: form, host: host,
                       skipCaptcha: skipCaptcha, allowSuccessWithoutData: allowSuccessWithoutData)
    }

    /// 以 multipart/form-data 提交文本字段的 POST；签名头、Cookie、验证重试与 `post` 相同。
    public func postMultipart(
        _ path: String,
        query: [(String, String?)] = [],
        fields: [(String, String)] = [],
        host: String = CoolapkClient.apiHost,
        skipCaptcha: Bool = false,
        allowSuccessWithoutData: Bool = false
    ) async throws -> Response {
        try await send(method: "POST", path: path, query: query, form: fields, encoding: .multipart, host: host,
                       skipCaptcha: skipCaptcha, allowSuccessWithoutData: allowSuccessWithoutData)
    }

    /// POST 表单的编码方式。
    enum FormEncoding: Sendable {
        case urlEncoded, multipart
    }

    private struct Snapshot {
        let identity: ClientIdentity
        let account: Account?
        let generation: Int
        let cookie: String
        let validation: String?
    }

    private func snapshot() -> Snapshot {
        lock.withLock {
            let identityHash = identityHashLocked()
            var parts: [String] = []
            if let account = _account {
                parts.append("uid=\(account.uid)")
                parts.append("username=\(account.username)")
                parts.append("token=\(account.token)")
            }
            if let cookie = _sessionCookie, cookie.identity == identityHash, cookie.expiresAt > Date(),
               !cookie.value.isEmpty {
                parts.append("SESSID=\(cookie.value)")
            }
            var validation: String?
            if let cookie = _sessionCookie, cookie.identity == identityHash, cookie.expiresAt > Date(),
               let stored = cookie.validation, (cookie.validationExpiresAt ?? .distantPast) > Date() {
                validation = stored
                parts.append("validate=\(stored)")
            }
            return Snapshot(identity: _identity, account: _account, generation: _generation,
                            cookie: parts.joined(separator: "; "), validation: validation)
        }
    }

    private func send(
        method: String, path: String, query: [(String, String?)], form: [(String, String)]?,
        encoding: FormEncoding = .urlEncoded,
        host: String, skipCaptcha: Bool, allowSuccessWithoutData: Bool
    ) async throws -> Response {
        let state = snapshot()
        let (status, body, cleanPath) = try await perform(
            method: method, path: path, query: query, form: form, encoding: encoding, host: host, state: state)

        if let challenge = CaptchaChallenge.from(body: body), !skipCaptcha, CoolapkClient.allowsVerificationPrompt,
           let handler = captchaHandler {
            // 别的请求可能已经拿到更新的凭证：复用一次。
            let current = snapshot()
            if challenge.field.isEmpty, let proof = current.validation, proof != state.validation,
               current.generation == state.generation {
                let retried = try await perform(method: method, path: path, query: query, form: form,
                                                encoding: encoding, host: host, state: current)
                return Response(body: try APIError.validate(
                    status: retried.0, body: retried.1, path: retried.2,
                    allowSuccessWithoutData: allowSuccessWithoutData))
            }
            switch await verifier.verify(challenge: challenge, handler: handler) {
            case .proof(let proof):
                guard challenge.accepts(proof: proof), snapshot().generation == state.generation else { break }
                var retryQuery = query
                var retryForm = form
                if challenge.field.isEmpty {
                    setValidation(proof)
                } else if retryForm != nil {
                    retryForm?.removeAll { $0.0 == challenge.field }
                    retryForm?.append((challenge.field, proof))
                } else {
                    retryQuery.removeAll { $0.0 == challenge.field }
                    retryQuery.append((challenge.field, proof))
                }
                let retried = try await perform(method: method, path: path, query: retryQuery,
                                                form: retryForm, encoding: encoding, host: host, state: snapshot())
                if challenge.field.isEmpty, CaptchaChallenge.from(body: retried.1) != nil {
                    clearValidation()
                }
                return Response(body: try APIError.validate(
                    status: retried.0, body: retried.1, path: retried.2,
                    allowSuccessWithoutData: allowSuccessWithoutData))
            case .settledElsewhere:
                // 另一个请求刚完成验证：复用它的凭证一次。
                let latest = snapshot()
                guard challenge.field.isEmpty, let proof = latest.validation, proof != state.validation,
                      latest.generation == state.generation else { break }
                let retried = try await perform(method: method, path: path, query: query, form: form,
                                                encoding: encoding, host: host, state: latest)
                return Response(body: try APIError.validate(
                    status: retried.0, body: retried.1, path: retried.2,
                    allowSuccessWithoutData: allowSuccessWithoutData))
            case .cancelled:
                break
            }
        }
        return Response(body: try APIError.validate(
            status: status, body: body, path: cleanPath, allowSuccessWithoutData: allowSuccessWithoutData))
    }

    /// 帖子的官方公开页（`www.coolapk.com/feed/<id>`）。需要签名请求头，但不带账号
    /// 和会话 Cookie，因此不会发送任何身份信息。网站返回“请用 App 查看”的落地页
    /// 而不是 JSON 时返回 `nil`。
    func publicFeedPayload(id: String) async throws -> JSON? {
        let current = snapshot()
        let anonymous = Snapshot(identity: current.identity, account: nil, generation: current.generation,
                                 cookie: "", validation: nil)
        let (status, body, _) = try await perform(
            method: "GET", path: "/feed/\(id)", query: [], form: nil, host: CoolapkClient.webHost,
            state: anonymous, storesSession: false)
        guard (200..<300).contains(status), let body else { return nil }
        let data = body["responseData"]["data"].object != nil ? body["responseData"]["data"] : body["data"]
        return data.object == nil ? nil : data
    }

    private func perform(
        method: String, path: String, query: [(String, String?)], form: [(String, String)]?,
        encoding: FormEncoding = .urlEncoded,
        host: String, state: Snapshot, storesSession: Bool = true
    ) async throws -> (Int, JSON?, String) {
        let (request, url, cleanPath) = try makeRequest(
            method: method, path: path, query: query, form: form, encoding: encoding, host: host, state: state)
        let (data, http) = try await execute(request, url: url, state: state, storesSession: storesSession)
        return (http.statusCode, JSON.parse(data), cleanPath)
    }

    /// 组装带签名头和 Cookie 的请求，不发送。
    private func makeRequest(
        method: String, path: String, query: [(String, String?)], form: [(String, String)]?,
        encoding: FormEncoding, host: String, state: Snapshot
    ) throws -> (URLRequest, URL, String) {
        guard let (url, cleanPath) = CoolapkClient.makeURL(host: host, path: path, query: query) else {
            throw APIError(.business, "请求参数异常，请检查客户端协议设置和系统时间")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        let identity = state.identity
        let token: String
        do {
            token = try RequestToken.v3(device: identity.deviceCode, appCode: Int(identity.versionCode) ?? 2_604_201)
        } catch {
            throw APIError(.business, "请求参数异常，请检查客户端协议设置和系统时间")
        }
        let headers: [String: String] = [
            "User-Agent": identity.userAgent,
            "X-Requested-With": "XMLHttpRequest",
            "X-Sdk-Int": identity.sdkInt,
            "X-Sdk-Locale": "zh-CN",
            "X-App-Id": RequestToken.appID,
            "X-App-Token": token,
            "X-App-Version": identity.versionName,
            "X-App-Code": identity.versionCode,
            "X-Api-Version": identity.apiVersion,
            "X-App-Device": identity.deviceCode,
            "X-Dark-Mode": "0",
            "X-App-Channel": "coolapk",
            "X-App-Mode": "universal",
            "X-App-Supported": identity.versionCode,
        ]
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if !state.cookie.isEmpty { request.setValue(state.cookie, forHTTPHeaderField: "Cookie") }
        if let form {
            switch encoding {
            case .urlEncoded:
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(CoolapkClient.encode(form.map { ($0.0, Optional($0.1)) }).utf8)
            case .multipart:
                let multipart = MultipartForm(fields: form)
                request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
                request.httpBody = multipart.encoded()
            }
        }
        return (request, url, cleanPath)
    }

    /// 发送请求并做账号切换检查、会话 Cookie 保存。
    private func execute(
        _ request: URLRequest, url: URL, state: Snapshot, storesSession: Bool = true,
        delegate: URLSessionTaskDelegate? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: delegate)
        } catch {
            throw APIError.from(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError(.invalidResponse, "服务器响应格式异常，请稍后重试")
        }
        guard snapshot().generation == state.generation else {
            throw APIError(.cancelled, "账号已切换，已忽略旧请求")
        }
        if storesSession { storeSessionCookie(from: http, url: url) }
        return (data, http)
    }

    /// 带签名头的 GET，返回原始字节（验证码图片等非 JSON 响应）。
    func getData(_ path: String, query: [(String, String?)] = []) async throws -> Data {
        let state = snapshot()
        let (request, url, _) = try makeRequest(
            method: "GET", path: path, query: query, form: nil, encoding: .urlEncoded,
            host: CoolapkClient.apiHost, state: state)
        let (data, http) = try await execute(request, url: url, state: state)
        guard (200..<300).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
        return data
    }

    /// 带签名头的 GET，不跟随重定向；返回 302 响应里的 `Location`。
    func redirectLocation(_ path: String, query: [(String, String?)] = []) async throws -> URL? {
        let state = snapshot()
        let (request, url, _) = try makeRequest(
            method: "GET", path: path, query: query, form: nil, encoding: .urlEncoded,
            host: CoolapkClient.apiHost, state: state)
        let (_, http) = try await execute(request, url: url, state: state, delegate: RedirectBlocker())
        guard http.statusCode == 302, let location = http.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: url)?.absoluteURL,
              ["http", "https"].contains(target.scheme ?? ""), !(target.host ?? "").isEmpty
        else { return nil }
        return target
    }

    /// 发送不带酷安请求头的外部请求（图片直传 OSS），可回报已发送的比例。
    func sendExternal(
        _ request: URLRequest, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let generation = snapshot().generation
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await uploadSession.data(
                for: request, delegate: progress.map(UploadProgressReporter.init))
        } catch {
            throw APIError.from(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError(.invalidResponse, "服务器响应格式异常，请稍后重试")
        }
        guard snapshot().generation == generation else {
            throw APIError(.cancelled, "账号已切换，已忽略旧请求")
        }
        return (data, http)
    }

    private func storeSessionCookie(from response: HTTPURLResponse, url: URL) {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard let cookie = cookies.first(where: { $0.name == "SESSID" }) else { return }
        var changed: SessionCookie??
        lock.withLock {
            let valid = cookie.value.range(of: "^[A-Za-z0-9,._~%+/-]{1,512}$", options: .regularExpression) != nil
            if cookie.value.isEmpty || (cookie.expiresDate.map { $0 <= Date() } ?? false) {
                if _sessionCookie != nil {
                    _sessionCookie = nil
                    changed = .some(nil)
                }
            } else if valid {
                let limit = Date().addingTimeInterval(7 * 86_400)
                let stored = SessionCookie(
                    value: cookie.value, identity: identityHashLocked(),
                    expiresAt: min(cookie.expiresDate ?? limit, limit))
                if _sessionCookie?.value != stored.value || _sessionCookie?.identity != stored.identity {
                    _sessionCookie = stored
                    changed = .some(stored)
                }
            }
        }
        if let changed { onSessionCookieChange?(changed) }
    }

    private func setValidation(_ proof: String?) {
        let changed: SessionCookie? = lock.withLock {
            let identityHash = identityHashLocked()
            if _sessionCookie?.identity != identityHash {
                guard proof != nil else { return nil }
                // 还没有服务端会话：先用一个短期占位记录保存凭证。
                _sessionCookie = SessionCookie(value: "", identity: identityHash,
                                               expiresAt: Date().addingTimeInterval(86_400))
            }
            _sessionCookie?.validation = proof.map(CoolapkClient.percentEncode)
            _sessionCookie?.validationExpiresAt = proof == nil ? nil : Date().addingTimeInterval(86_400)
            return _sessionCookie
        }
        if let changed { onSessionCookieChange?(changed) }
    }

    private func clearValidation() { setValidation(nil) }

    /// 丢弃匿名接口会话和验证凭证。
    public func resetSession() {
        lock.withLock {
            _sessionCookie = nil
            _generation += 1
        }
        onSessionCookieChange?(nil)
    }

    // MARK: 构造 URL

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func encode(_ items: [(String, String?)]) -> String {
        items.compactMap { name, value in
            guard let value else { return nil }
            return "\(percentEncode(name))=\(percentEncode(value))"
        }.joined(separator: "&")
    }

    /// 路径本身可以带查询串（`/v6/x?a=b`）：与额外参数合并后统一重新编码。
    static func makeURL(host: String, path: String, query: [(String, String?)]) -> (URL, String)? {
        var items: [(String, String?)] = []
        var cleanPath = path
        if let mark = path.firstIndex(of: "?") {
            cleanPath = String(path[..<mark])
            let embedded = path[path.index(after: mark)...]
            for pair in embedded.split(separator: "&", omittingEmptySubsequences: true) {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = String(parts[0]).removingPercentEncoding ?? String(parts[0])
                let raw = parts.count > 1 ? String(parts[1]) : ""
                items.append((name, raw.removingPercentEncoding ?? raw))
            }
        }
        items.append(contentsOf: query)
        let encodedPath = cleanPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanPath
        let queryString = encode(items)
        guard let url = URL(string: host + encodedPath + (queryString.isEmpty ? "" : "?" + queryString)) else {
            return nil
        }
        return (url, cleanPath)
    }
}

/// 把人机验证串行化：并发的多个请求同时被要求验证时只弹一次。
private actor CaptchaGate {
    enum Outcome: Sendable {
        case proof(String)
        case cancelled
        case settledElsewhere
    }

    private var running: Task<String?, Never>?

    func verify(challenge: CaptchaChallenge, handler: @escaping CoolapkClient.CaptchaHandler) async -> Outcome {
        if let running {
            // 已经有验证窗口在显示：等它结束，不再叠一个。
            return await running.value == nil ? .cancelled : .settledElsewhere
        }
        let task = Task { await handler(challenge) }
        running = task
        let proof = await task.value
        running = nil
        return proof.map(Outcome.proof) ?? .cancelled
    }
}

/// 拒绝跟随重定向，让调用方读到 302 本身。
private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// 把请求体的发送进度转成 0...1 的比例。
private final class UploadProgressReporter: NSObject, URLSessionTaskDelegate {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}
