import Foundation

/// 客户端向接口出示的 Android 兼容参数。
/// 桌面端统一用一组固定参数走 Android 协议，这些值并不描述用户的 Mac。
public struct ClientIdentity: Codable, Sendable, Equatable {
    public var versionName: String
    public var versionCode: String
    public var apiVersion: String
    public var manufacturer: String
    public var brand: String
    public var model: String
    public var buildNumber: String
    public var sdkInt: String
    public var androidVersion: String
    /// 编码后的 `X-App-Device` 值。
    public var deviceCode: String
    /// 已保存的数字联盟设备标识（`ShuzlmID` / DUID），为空表示尚未使用数盟标识。
    public var szlmID: String

    public var hasSzlmID: Bool { !szlmID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public static let defaultVersionName = "16.2.0"
    public static let defaultVersionCode = "2604201"
    public static let defaultAPIVersion = "16"

    private enum CodingKeys: String, CodingKey {
        case versionName, versionCode, apiVersion
        case manufacturer, brand, model, buildNumber, sdkInt, androidVersion
        case deviceCode, szlmID
    }

    public init(
        versionName: String = ClientIdentity.defaultVersionName,
        versionCode: String = ClientIdentity.defaultVersionCode,
        apiVersion: String = ClientIdentity.defaultAPIVersion,
        manufacturer: String = "Google",
        brand: String = "google",
        model: String = "Pixel 7",
        buildNumber: String = "TQ3A.230805.001",
        sdkInt: String = "33",
        androidVersion: String = "13",
        deviceCode: String = "",
        szlmID: String = ""
    ) {
        self.versionName = versionName
        self.versionCode = versionCode
        self.apiVersion = apiVersion
        self.manufacturer = manufacturer
        self.brand = brand
        self.model = model
        self.buildNumber = buildNumber
        self.sdkInt = sdkInt
        self.androidVersion = androidVersion
        self.deviceCode = deviceCode
        self.szlmID = szlmID
        if deviceCode.isEmpty { regenerateDeviceCode(preservingSzlmID: !szlmID.isEmpty) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        versionName = try container.decode(String.self, forKey: .versionName)
        versionCode = try container.decode(String.self, forKey: .versionCode)
        apiVersion = try container.decode(String.self, forKey: .apiVersion)
        manufacturer = try container.decode(String.self, forKey: .manufacturer)
        brand = try container.decode(String.self, forKey: .brand)
        model = try container.decode(String.self, forKey: .model)
        buildNumber = try container.decode(String.self, forKey: .buildNumber)
        sdkInt = try container.decode(String.self, forKey: .sdkInt)
        androidVersion = try container.decode(String.self, forKey: .androidVersion)
        deviceCode = try container.decode(String.self, forKey: .deviceCode)
        szlmID = try container.decodeIfPresent(String.self, forKey: .szlmID) ?? ""
    }

    public var userAgent: String {
        "Dalvik/2.1.0 (Linux; U; Android \(androidVersion); \(model) \(buildNumber)) "
            + "(#Build; \(brand); \(model); \(buildNumber); \(androidVersion)) "
            + "+CoolMarket/\(versionName)-\(versionCode)-universal"
    }

    /// 生成新的随机安装标识，并重新编码设备码。
    /// `preservingSzlmID` 为 `false`（默认）时会同时清除已保存的数盟 ID。
    public mutating func regenerateDeviceCode(preservingSzlmID: Bool = false) {
        let firstField: String
        if preservingSzlmID, let valid = OfficialDeviceIdentity.validate(szlmID) {
            firstField = valid
            szlmID = valid
        } else {
            firstField = "ca_" + ClientIdentity.randomHex(32)
            szlmID = ""
        }
        let fields = [
            firstField,
            " ", " ", " ",
            " \(manufacturer)", " \(brand)", " \(model)", " \(buildNumber)",
            " null",
        ]
        deviceCode = ClientIdentity.encodeDevice(fields.joined(separator: ";"))
    }

    /// 修改参数后重新编码设备码，安装标识与已保存的数盟 ID 保持不变。
    public mutating func refreshDeviceCode() {
        guard var fields = ClientIdentity.decodeDevice(deviceCode) else {
            regenerateDeviceCode(preservingSzlmID: hasSzlmID)
            return
        }
        if let valid = OfficialDeviceIdentity.validate(szlmID) {
            fields[0] = valid
        }
        fields[4] = " \(manufacturer)"
        fields[5] = " \(brand)"
        fields[6] = " \(model)"
        fields[7] = " \(buildNumber)"
        deviceCode = ClientIdentity.encodeDevice(fields.joined(separator: ";"))
    }

    /// 写入已校验的数盟设备标识；仅替换 `X-App-Device` 首字段，其余 8 个字段保持不变。
    public mutating func applySzlmID(_ value: String) throws {
        guard let id = OfficialDeviceIdentity.validate(value) else {
            throw OfficialDeviceIdentityError("设备标识为空或格式不正确，未修改设备标识")
        }
        guard var fields = ClientIdentity.decodeDevice(deviceCode) else {
            throw OfficialDeviceIdentityError("现有设备参数无法读取，未修改设备标识")
        }
        fields[0] = id
        deviceCode = ClientIdentity.encodeDevice(fields.joined(separator: ";"))
        szlmID = id
    }

    /// 解析官方酷安复制的文本并写入其中的数盟设备标识。
    @discardableResult
    public mutating func importOfficialDeviceIdentity(_ text: String) throws -> String {
        let id = try OfficialDeviceIdentity.parse(text)
        try applySzlmID(id)
        return id
    }

    static func randomHex(_ length: Int) -> String {
        let digits = Array("0123456789ABCDEF")
        return String((0..<length).map { _ in digits[Int.random(in: 0..<16)] })
    }

    /// base64 → 反转 → 去掉填充（对应 `TokenUtils.encodeDevice`）。
    static func encodeDevice(_ plain: String) -> String {
        String(Data(plain.utf8).base64EncodedString().reversed())
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    static func decodeDevice(_ code: String) -> [String]? {
        var base64 = String(code.reversed())
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64), let plain = String(data: data, encoding: .utf8) else {
            return nil
        }
        let fields = plain.components(separatedBy: ";")
        guard fields.count == 9, !fields[0].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return fields
    }
}

public struct Account: Codable, Sendable, Equatable, Identifiable {
    public var uid: String
    /// 保持账号 Cookie 给出的原样（URL 编码）。
    public var username: String
    public var token: String
    public var avatar: String

    public var id: String { uid }
    public var displayName: String { username.removingPercentEncoding ?? username }

    public init(uid: String, username: String, token: String, avatar: String = "") {
        self.uid = uid
        self.username = username
        self.token = token
        self.avatar = avatar
    }
}
