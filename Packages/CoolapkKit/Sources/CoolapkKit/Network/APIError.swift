import Foundation

/// 只有安全的本地文案会到达界面，绝不包含响应体、请求 URL 或请求头。
/// 移植自 Flutter 端的 `ApiFailure`。
public struct APIError: Error, LocalizedError, Sendable, Equatable {
    public enum Kind: Sendable {
        case transport, http, business, authentication, captcha, rateLimit
        case riskControl, clientUpgrade, invalidResponse, parsing, cancelled
    }

    public let kind: Kind
    public let message: String
    public var httpStatus: Int?
    /// 服务端的 `messageStatus`（仅验证码类失败时填写），用来区分图形验证码与滑块验证。
    public var serverStatus: String?

    public init(_ kind: Kind, _ message: String, httpStatus: Int? = nil) {
        self.kind = kind
        self.message = message
        self.httpStatus = httpStatus
    }

    public var errorDescription: String? { message }

    public static func http(_ status: Int?) -> APIError {
        APIError(.http, "请求失败（HTTP \(status.map(String.init) ?? "未知")），请稍后重试", httpStatus: status)
    }

    public static func from(_ error: Error) -> APIError {
        if let error = error as? APIError { return error }
        if error is CancellationError { return APIError(.cancelled, "请求已取消") }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return APIError(.transport, "请求超时，请稍后重试")
            case .cancelled: return APIError(.cancelled, "请求已取消")
            case .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .secureConnectionFailed:
                return APIError(.transport, "服务器证书验证失败")
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .dnsLookupFailed:
                return APIError(.transport, "连接失败，请检查网络设置")
            default: return APIError(.transport, "请求失败，请检查网络后重试")
            }
        }
        return APIError(.parsing, "数据解析失败，请更新客户端或稍后重试")
    }

    /// 在读取模型前先校验响应外层。HTTP 200 本身说明不了登录状态、风控
    /// 或数据结构是否正常。
    static func validate(status: Int, body: JSON?, path: String, allowSuccessWithoutData: Bool) throws -> JSON {
        guard (200..<300).contains(status) else { throw APIError.http(status) }
        guard let body, let object = body.object else {
            throw APIError(.invalidResponse, "服务器响应格式异常，请稍后重试")
        }
        let marker = (body["messageStatus"].string ?? "").lowercased()
        let message = body["message"].string ?? ""
        let errorText = body["error"].string ?? ""
        let clues = "\(marker) \(message) \(errorText)".lowercased()
        let code = body["code"].int
        let businessStatus = body["status"].int
        let failed = (code != nil && ![0, 1, 200].contains(code!))
            || (businessStatus != nil && ![0, 1].contains(businessStatus!))
            || marker.hasPrefix("err_")
            || (!body["error"].isNull && !["", "0", "false"].contains(errorText))
            || (body["data"].isNull && !message.isEmpty && code == nil && businessStatus == nil)
        if failed {
            if businessStatus == -10 || clues.contains("网络环境") {
                throw APIError(.riskControl, "服务端检测到网络环境异常，请检查代理、DNS 或网络过滤设置后重试")
            }
            if marker == "err_request_need_upgrade_new_version" {
                throw APIError(.clientUpgrade, "当前客户端协议未被服务端接受，请更新客户端后重试")
            }
            if clues.contains("captcha") || clues.contains("验证码") {
                var failure = APIError(.captcha, "请求需要验证码验证，请完成验证后重试")
                failure.serverStatus = marker.isEmpty ? nil : marker
                throw failure
            }
            if clues.contains("login") || clues.contains("auth") || clues.contains("登录") || code == 401 {
                throw APIError(.authentication, "登录状态已失效或需要登录，请重新登录")
            }
            if clues.contains("rate_limit") || clues.contains("频繁") || code == 429 {
                throw APIError(.rateLimit, "请求过于频繁，请稍后重试")
            }
            if path == "/v6/apk/detail", businessStatus == -2,
               message.contains("应用不存在") || message.contains("未上架") {
                throw APIError(.business, "该应用未在酷安上架")
            }
            // 服务端给出的业务提示是面向用户的短文本。
            if !message.isEmpty, message.count <= 80, !message.contains("<") {
                throw APIError(.business, message)
            }
            throw APIError(.business, "服务器未能完成请求，请稍后重试")
        }
        if object["data"] == nil, !(allowSuccessWithoutData && businessStatus == 1) {
            throw APIError(.invalidResponse, "服务器响应缺少数据字段，请稍后重试")
        }
        return body
    }
}
