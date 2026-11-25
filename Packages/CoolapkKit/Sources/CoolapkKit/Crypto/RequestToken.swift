import CryptoKit
import Foundation

/// 每个请求的 `X-App-Token` 签名。
/// 移植自 Flutter 端的 `TokenUtils.getTokenV3`，后者兼容 coolapk-desktop 的 `auth.rs`
/// （见 docs/THIRD_PARTY_NOTICES.md）。
public enum RequestToken {
    public enum Failure: Error { case unavailable }

    static let appID = "com.coolapk.market"
    private static let blob: [UInt8] = Array(Data(base64Encoded: TokenV3Data.blob) ?? Data())
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    private static let bcryptCharacters = Set("./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    public static func v3(device: String, timestamp: Int? = nil, appCode: Int = 2_604_201) throws -> String {
        let now = timestamp ?? Int(Date().timeIntervalSince1970)
        for offset in 0...15 {
            let time = now + offset
            let index = ((time + appCode) % 100) * 4 + 0x80
            guard index + 0x80 <= blob.count,
                  let segmentData = Data(base64Encoded: Data(blob[index..<(index + 0x80)])),
                  let segment = String(data: segmentData, encoding: .utf8)
            else { throw Failure.unavailable }

            let plain = "\(appID)&\(segment)&\(md5(device))&\(time)&\(appCode)"
            let password = md5(Data(plain.utf8).base64EncodedString())
            let source = Array(unpaddedBase64("\(String(time, radix: 16))/\(md5(plain))").prefix(22))
            guard source.count == 22, let last = alphabet.firstIndex(of: source[21]) else { continue }
            let salt = String(source[0..<21]) + String(alphabet[((last - 5) % 64 + 64) % 64])
            guard salt.allSatisfy(bcryptCharacters.contains) else { continue }

            let hash = try BCrypt.hash(password: password, salt: "$2a$04$" + salt)
            return "v3" + unpaddedBase64("$2y" + hash.dropFirst(3))
        }
        throw Failure.unavailable
    }

    static func md5(_ input: String) -> String {
        Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func unpaddedBase64(_ input: String) -> String {
        Data(input.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}
