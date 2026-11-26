import Foundation

/// 设备标识解析或校验失败（文案安全，不包含任何原始粘贴或响应内容）。
public struct OfficialDeviceIdentityError: Error, LocalizedError, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/// 官方酷安“复制 OAID”文本中的 `ShuzlmID`（数盟 ID）解析与校验。
/// 移植自上游 `official_device_identity.dart`：故意不接受 OAID、AndroidID、UUID 等替代字段。
public enum OfficialDeviceIdentity {
    public static let guideURL = URL(
        string: "https://github.com/TG-Twilight/c001apk/blob/main/docs/DEVICE_ID_IMPORT.md"
    )!

    private static let valueRegex = try! NSRegularExpression(pattern: #"^[A-Za-z0-9_+/.=-]{8,4096}$"#)
    private static let lineRegex = try! NSRegularExpression(
        pattern: #"^\s*ShuzlmID\s*[:：]\s*([^\r\n]*)$"#,
        options: [.anchorsMatchLines, .caseInsensitive]
    )

    /// 仅接受格式合法的数盟标识；全 0 是服务端拒绝应答，同样不予接受。
    public static func validate(_ value: String?) -> String? {
        guard let value else { return nil }
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsRange = NSRange(id.startIndex..<id.endIndex, in: id)
        guard valueRegex.firstMatch(in: id, range: nsRange) != nil else { return nil }
        guard !id.utf8.allSatisfy({ $0 == 0x30 }) else { return nil }
        return id
    }

    /// 从官方酷安复制的完整文本里提取唯一的 `ShuzlmID`。
    public static func parse(_ text: String) throws -> String {
        if text.utf16.count > 32_768 {
            throw OfficialDeviceIdentityError("复制内容过长，请重新从官方酷安复制")
        }
        let normalized = text
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let fullRange = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        let matches = lineRegex.matches(in: normalized, range: fullRange)
        guard matches.count == 1,
              let groupRange = Range(matches[0].range(at: 1), in: normalized)
        else {
            throw OfficialDeviceIdentityError(
                "未识别到唯一的 ShuzlmID。请在官方同一页面累计点击“复制 OAID”5次，再粘贴完整内容"
            )
        }
        let raw = String(normalized[groupRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = raw.lowercased()
        guard lowered != "null", lowered != "undefined", let valid = validate(raw) else {
            throw OfficialDeviceIdentityError("数盟 ID 为空或格式不正确，请打开官方酷安稍等后重新复制")
        }
        return valid
    }
}
