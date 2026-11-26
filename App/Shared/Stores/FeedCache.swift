import CoolapkKit
import CryptoKit
import Foundation

/// 首页、热榜、关注、酷图、板块等主列表的本地磁盘缓存。
/// 冷启动时同步读取首屏数据秒开展示，随后后台静默刷新并异步回写最新一页。
final class FeedCache: @unchecked Sendable {
    static let shared = FeedCache()

    /// 缓存最长保留 7 天，避免展示过久之前的失效内容。
    private static let maxAge: TimeInterval = 7 * 86_400
    /// 单个列表只缓存首屏最多 40 条，保证冷启动同步读取在毫秒级完成。
    private static let maxItems = 40

    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("c001apk-feeds", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// 同步读取首屏缓存（仅供冷启动 / 列表初始化快速填充使用）。
    func load(key: String, scope: String) -> EntityPage? {
        let url = fileURL(key: key, scope: scope)
        guard let data = try? Data(contentsOf: url),
              let root = JSON.parse(data),
              let savedAt = root["savedAt"].int
        else { return nil }
        let age = Date().timeIntervalSince1970 - Double(savedAt)
        guard age >= -3600, age <= Self.maxAge else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard let rawItems = root["items"].array, !rawItems.isEmpty else { return nil }
        let items = rawItems.map(Entity.init)
        return EntityPage(
            items: items,
            firstItem: root["firstItem"].text,
            lastItem: root["lastItem"].text
        )
    }

    /// 异步写入最新一页到磁盘，不阻塞主线程。
    func save(_ page: EntityPage, key: String, scope: String) {
        let trimmed = Array(page.items.prefix(Self.maxItems))
        guard !trimmed.isEmpty else { return }
        let payload = JSON.object([
            "savedAt": .number(floor(Date().timeIntervalSince1970)),
            "firstItem": page.firstItem.map(JSON.string) ?? .null,
            "lastItem": page.lastItem.map(JSON.string) ?? .null,
            "items": .array(trimmed.map(\.json)),
        ])
        let url = fileURL(key: key, scope: scope)
        let dir = directory
        Task.detached(priority: .utility) {
            guard let data = payload.serialized() else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 清除指定账号作用域下的所有列表缓存（例如移除账号时）。
    func clear(scope: String) {
        let prefix = "\(Self.safeToken(scope))_"
        let dir = directory
        Task.detached(priority: .utility) {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                return
            }
            for file in files where file.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func fileURL(key: String, scope: String) -> URL {
        let name = "\(Self.safeToken(scope))_\(Self.hash(key)).json"
        return directory.appendingPathComponent(name)
    }

    private static func safeToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return cleaned.isEmpty ? "guest" : String(cleaned)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
