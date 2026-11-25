import Foundation

/// 仅包含协议配置。验证凭据绝不能写入日志。
/// 移植自 Flutter 端的 `CaptchaChallenge`。
public struct CaptchaChallenge: Sendable, Equatable {
    public let captchaID: String
    /// 为空表示走 `validate` Cookie 协议，否则作为表单 / 查询字段名。
    public let field: String

    static let defaultID = "414e5c9b866a03db03f860a1a9101672"

    public init(captchaID: String, field: String) {
        self.captchaID = captchaID
        self.field = field
    }

    static func from(body: JSON?) -> CaptchaChallenge? {
        guard let body, body["messageStatus"].string == "err_request_captcha_v2" else { return nil }
        var extra = body["messageExtra"].isNull ? body["extra"] : body["messageExtra"]
        if case .string(let text) = extra { extra = JSON.parse(text) ?? .null }
        if extra.object == nil { extra = body }
        var identifier = CaptchaChallenge.defaultID
        if let value = extra["captchaId"].string, value.range(of: "^[a-zA-Z0-9]{16,64}$", options: .regularExpression) != nil {
            identifier = value
        }
        var field = "_v2_post_token"
        if case .string(let value) = extra["captchaField"] {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.range(of: "^_[a-zA-Z0-9_]{1,63}$", options: .regularExpression) != nil {
                field = trimmed
            }
        }
        return CaptchaChallenge(captchaID: identifier, field: field)
    }

    /// 把 SDK 返回的 `validate` 字符串包装成接口需要的凭据。
    public func proof(validate: String) -> String? {
        guard !validate.isEmpty, validate.count <= 8192,
              validate.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { return nil }
        return "NEC:\(captchaID.prefix(8)):\(validate)"
    }

    func accepts(proof: String) -> Bool {
        proof.hasPrefix("NEC:\(captchaID.prefix(8)):") && proof.count > 13 && proof.count <= 8205
            && proof.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
    }
}
