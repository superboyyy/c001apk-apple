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

    public static let defaultVersionName = "16.2.0"
    public static let defaultVersionCode = "2604201"
    public static let defaultAPIVersion = "16"

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
        deviceCode: String = ""
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
        if deviceCode.isEmpty { regenerateDeviceCode() }
    }

    public var userAgent: String {
        "Dalvik/2.1.0 (Linux; U; Android \(androidVersion); \(model) \(buildNumber)) "
            + "(#Build; \(brand); \(model); \(buildNumber); \(androidVersion)) "
            + "+CoolMarket/\(versionName)-\(versionCode)-universal"
    }

    /// 生成新的随机安装标识，并重新编码设备码。
    public mutating func regenerateDeviceCode() {
        let fields = [
            "ca_" + ClientIdentity.randomHex(32),
            " ", " ", " ",
            " \(manufacturer)", " \(brand)", " \(model)", " \(buildNumber)",
            " null",
        ]
        deviceCode = ClientIdentity.encodeDevice(fields.joined(separator: ";"))
    }

    /// 修改参数后重新编码设备码，安装标识不变。
    public mutating func refreshDeviceCode() {
        guard var fields = ClientIdentity.decodeDevice(deviceCode) else {
            regenerateDeviceCode()
            return
        }
        fields[4] = " \(manufacturer)"
        fields[5] = " \(brand)"
        fields[6] = " \(model)"
        fields[7] = " \(buildNumber)"
        deviceCode = ClientIdentity.encodeDevice(fields.joined(separator: ";"))
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
