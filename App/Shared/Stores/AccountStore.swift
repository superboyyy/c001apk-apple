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
}
