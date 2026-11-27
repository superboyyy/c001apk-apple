import CoolapkKit
import Foundation
import Security

/// 已登录账号的持久化：全部账号与当前账号保存在系统钥匙串里。
enum AccountStore {
    /// 钥匙串中保存的内容。
    struct Snapshot: Codable {
        var accounts: [Account] = []
        var currentUID: String?
    }

    private static let service = "com.superboyyy.c001apk.account"
    private static let itemName = "accounts"
    /// 旧版本只保存一个账号时使用的条目名。
    private static let legacyItemName = "current"
    /// 游客 / 人机验证后的服务端会话 Cookie 条目名。
    private static let sessionItemName = "apiSession"
    private static let sessionLock = NSLock()

    private static func query(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
    }

    private static func read(_ name: String) -> Data? {
        var request = query(name)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func load() -> Snapshot {
        if let data = read(itemName), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            return snapshot
        }
        // 迁移旧的单账号存储。
        if let data = read(legacyItemName), let account = try? JSONDecoder().decode(Account.self, from: data) {
            let snapshot = Snapshot(accounts: [account], currentUID: account.uid)
            if save(snapshot) { SecItemDelete(query(legacyItemName) as CFDictionary) }
            return snapshot
        }
        return Snapshot()
    }

    @discardableResult
    static func save(_ snapshot: Snapshot) -> Bool {
        SecItemDelete(query(itemName) as CFDictionary)
        guard !snapshot.accounts.isEmpty else { return true }
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        var request = query(itemName)
        request[kSecValueData as String] = data
        request[kSecAttrLabel as String] = "酷果账号"
        return SecItemAdd(request as CFDictionary, nil) == errSecSuccess
    }

    /// 读取服务端会话 Cookie；若仅存在于旧版 `UserDefaults`，会自动迁移至系统钥匙串并清除明文旧键。
    static func loadSession(legacyDefaultsKey: String) -> CoolapkClient.SessionCookie? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        let defaults = UserDefaults.standard
        if let data = read(sessionItemName),
           let cookie = try? JSONDecoder().decode(CoolapkClient.SessionCookie.self, from: data) {
            if defaults.object(forKey: legacyDefaultsKey) != nil {
                defaults.removeObject(forKey: legacyDefaultsKey)
            }
            return cookie
        }
        if let legacyData = defaults.data(forKey: legacyDefaultsKey),
           let cookie = try? JSONDecoder().decode(CoolapkClient.SessionCookie.self, from: legacyData) {
            if writeSessionLocked(cookie) {
                defaults.removeObject(forKey: legacyDefaultsKey)
            }
            return cookie
        }
        return nil
    }

    /// 将服务端会话 Cookie 写入系统钥匙串，传入 `nil` 时清除钥匙串及旧版 `UserDefaults` 残留。
    @discardableResult
    static func saveSession(_ cookie: CoolapkClient.SessionCookie?, legacyDefaultsKey: String) -> Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        let defaults = UserDefaults.standard
        if defaults.object(forKey: legacyDefaultsKey) != nil {
            defaults.removeObject(forKey: legacyDefaultsKey)
        }
        return writeSessionLocked(cookie)
    }

    private static func writeSessionLocked(_ cookie: CoolapkClient.SessionCookie?) -> Bool {
        SecItemDelete(query(sessionItemName) as CFDictionary)
        guard let cookie else { return true }
        guard let data = try? JSONEncoder().encode(cookie) else { return false }
        var request = query(sessionItemName)
        request[kSecValueData as String] = data
        request[kSecAttrLabel as String] = "酷果会话"
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(request as CFDictionary, nil) == errSecSuccess
    }
}
