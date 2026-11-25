import Foundation

/// 发布动态与回复（需要登录）。参数拼装对照上游 `NetworkRepo.postCreateFeed` / `postReply`。
extension CoolapkClient {
    /// 回复的对象：动态本身，或动态下的某条回复。
    public enum ReplyTarget: String, Sendable, Hashable {
        case feed, reply
    }

    /// `createFeed` 的表单字段，顺序与上游一致。
    static func createFeedForm(
        message: String, pics: [String], targetType: String?, targetID: String?, onlySelf: Bool
    ) -> [(String, String)] {
        // 发在应用页下的内容是“点评”，其余都是普通动态。
        var form: [(String, String)] = [("type", targetType == "apk" ? "comment" : "feed")]
        if let targetType { form.append(("targetType", targetType)) }
        if let targetID { form.append(("targetId", targetID)) }
        form += [
            ("message", message),
            ("status", "1"),
            ("pic", pics.joined(separator: ",")),
            ("publish_status", onlySelf ? "1" : "0"),
        ]
        return form
    }

    /// `reply` 的表单字段。
    static func replyForm(message: String, pics: [String], forward: Bool) -> [(String, String)] {
        [("message", message), ("replyAndForward", forward ? "1" : "0"), ("pic", pics.joined(separator: ","))]
    }

    /// 发布一条动态。`pics` 是 `uploadImages(_:scope: .feed)` 返回的图片引用；
    /// `targetType` / `targetID` 把动态发到话题（`tag`）、数码（`product_phone`）或应用（`apk`）下。
    public func createFeed(
        message: String, pics: [String] = [], targetType: String? = nil, targetID: String? = nil,
        onlySelf: Bool = false
    ) async throws -> Entity {
        let response = try await post(
            "/v6/feed/createFeed",
            form: CoolapkClient.createFeedForm(
                message: message, pics: pics, targetType: targetType, targetID: targetID, onlySelf: onlySelf))
        return Entity(response.data)
    }

    /// 回复动态或回复，可带图、可同时转发。返回服务端生成的回复。
    public func postReply(
        id: String, type: ReplyTarget, message: String, pics: [String], forward: Bool = false
    ) async throws -> Entity {
        let response = try await post(
            "/v6/feed/reply", query: [("id", id), ("type", type.rawValue)],
            form: CoolapkClient.replyForm(message: message, pics: pics, forward: forward))
        return Entity(response.data)
    }

    // MARK: 图形验证码

    /// 发布被要求输入图形验证码（`err_request_captcha`）时取验证码图片。
    public func captchaImage() async throws -> Data {
        try await getData(
            "/v6/account/captchaImage",
            query: [("_", String(Int(Date().timeIntervalSince1970 * 1000))), ("w", "270"), ("h", "113")])
    }

    /// 提交图形验证码；通过后可以重新发布。
    public func submitCaptcha(code: String) async throws {
        let response = try await postMultipart(
            "/v6/account/requestValidate", fields: [("type", "err_request_captcha"), ("code", code)],
            skipCaptcha: true)
        guard response.data.string == "验证通过" else {
            throw APIError(.business, response.message.isEmpty ? "验证未通过，请重试" : response.message)
        }
    }
}
