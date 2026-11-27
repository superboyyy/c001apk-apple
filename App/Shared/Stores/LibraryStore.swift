import CoolapkKit
import Foundation
import Observation

/// 保存在本机的一条动态（收藏或浏览历史）。
struct SavedFeed: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var username: String
    var uid: String
    var avatar: String
    var excerpt: String
    var cover: String
    var savedAt: Date

    init(entity: Entity) {
        id = entity.entityID
        title = entity.messageTitle
        username = entity.username
        uid = entity.uid
        avatar = entity.userAvatar
        excerpt = String(RichText.plainText(entity.message).prefix(160))
        cover = entity.messageCover.isEmpty ? (entity.pictures.first ?? "") : entity.messageCover
        savedAt = Date()
    }
}

struct BlockedUser: Codable, Identifiable, Hashable {
    var uid: String
    var username: String
    var id: String { uid }
}

/// 仅保存在本机的收藏、浏览历史、搜索历史和屏蔽列表，
/// 不会同步到酷安账号。
@MainActor
@Observable
final class LibraryStore {
    private struct Snapshot: Codable {
        var favorites: [SavedFeed] = []
        var history: [SavedFeed] = []
        var searches: [String] = []
        var blocked: [BlockedUser] = []
    }

    private(set) var favorites: [SavedFeed] = []
    private(set) var history: [SavedFeed] = []
    private(set) var searches: [String] = []
    private(set) var blocked: [BlockedUser] = [] {
        didSet { blockedUIDs = Set(blocked.map(\.uid)) }
    }

    @ObservationIgnored private var blockedUIDs: Set<String> = []
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("c001apk", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: fileURL),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            favorites = snapshot.favorites
            history = snapshot.history
            searches = snapshot.searches
            blocked = snapshot.blocked
            blockedUIDs = Set(snapshot.blocked.map(\.uid))
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = Snapshot(favorites: favorites, history: history, searches: searches, blocked: blocked)
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: 收藏

    func isFavorite(_ id: String) -> Bool { favorites.contains { $0.id == id } }

    func toggleFavorite(_ entity: Entity) {
        let id = entity.entityID
        guard !id.isEmpty else { return }
        if let index = favorites.firstIndex(where: { $0.id == id }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(SavedFeed(entity: entity), at: 0)
        }
        scheduleSave()
    }

    func removeFavorite(_ id: String) {
        favorites.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: 浏览历史

    func recordHistory(_ entity: Entity) {
        let id = entity.entityID
        guard !id.isEmpty else { return }
        history.removeAll { $0.id == id }
        history.insert(SavedFeed(entity: entity), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        scheduleSave()
    }

    func removeHistory(_ id: String) {
        history.removeAll { $0.id == id }
        scheduleSave()
    }

    func clearHistory() {
        history.removeAll()
        scheduleSave()
    }

    // MARK: 搜索历史

    func recordSearch(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searches.removeAll { $0 == trimmed }
        searches.insert(trimmed, at: 0)
        if searches.count > 30 { searches.removeLast(searches.count - 30) }
        scheduleSave()
    }

    func removeSearch(_ keyword: String) {
        searches.removeAll { $0 == keyword }
        scheduleSave()
    }

    func clearSearches() {
        searches.removeAll()
        scheduleSave()
    }

    // MARK: 屏蔽列表

    func isBlocked(uid: String) -> Bool {
        // 读取 `blocked.isEmpty` 以保留对屏蔽列表变更的观察依赖，同时用集合做到 O(1) 查找。
        guard !blocked.isEmpty, !uid.isEmpty else { return false }
        return blockedUIDs.contains(uid)
    }

    func block(uid: String, username: String) {
        guard !uid.isEmpty, !isBlocked(uid: uid) else { return }
        blocked.insert(BlockedUser(uid: uid, username: username), at: 0)
        scheduleSave()
    }

    func unblock(uid: String) {
        blocked.removeAll { $0.uid == uid }
        scheduleSave()
    }
}
