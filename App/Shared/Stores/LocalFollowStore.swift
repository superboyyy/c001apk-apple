import CoolapkKit
import Foundation
import Observation

/// 悄悄关注名单里的一位用户。
struct LocalFollowUser: Codable, Identifiable, Hashable {
    var uid: String
    var name: String
    var avatar: String
    var id: String { uid }

    /// 没有昵称时显示 UID。
    var displayName: String { name.isEmpty ? "用户 \(uid)" : name }
}

/// 悄悄关注（本地关注）：只存在本机的关注名单，以及由名单汇总出的动态时间线。
/// 与登录账号无关，不调用任何关注接口；保存在 Application Support/c001apk/local-follow.json。
@MainActor
@Observable
final class LocalFollowStore {
    /// 新关注的排在最前。
    private(set) var users: [LocalFollowUser] = []
    /// 时间线的非致命提示（例如个别用户加载失败），界面可据此提供重试。
    private(set) var warning: String?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var timelineModel: PagedList?
    @ObservationIgnored private var pager: LocalFollowPager?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let directory = base.appendingPathComponent("c001apk", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("local-follow.json")
        }
        if let data = try? Data(contentsOf: self.fileURL),
           let stored = try? JSONDecoder().decode([LocalFollowUser].self, from: data) {
            var seen = Set<String>()
            users = stored.filter { Self.isValid(uid: $0.uid) && seen.insert($0.uid).inserted }
        }
    }

    /// 登录后叫“悄悄关注”，游客叫“本地关注”。
    static func title(isLoggedIn: Bool) -> String { isLoggedIn ? "悄悄关注" : "本地关注" }

    static func isValid(uid: String) -> Bool { ContentFilter.isValidUID(uid) }

    // MARK: 名单

    func isFollowing(uid: String) -> Bool { users.contains { $0.uid == uid } }

    /// 加入名单；已在名单中则更新昵称头像并移到最前。UID 无效时返回 false。
    @discardableResult
    func follow(uid: String, name: String, avatar: String) -> Bool {
        guard Self.isValid(uid: uid) else { return false }
        users.removeAll { $0.uid == uid }
        users.insert(LocalFollowUser(uid: uid, name: name, avatar: avatar), at: 0)
        didChange()
        return true
    }

    func unfollow(uid: String) {
        guard isFollowing(uid: uid) else { return }
        users.removeAll { $0.uid == uid }
        didChange()
    }

    /// 给用户主页用：切换关注状态，返回切换后是否已关注。`user` 是用户资料或任何带作者信息的行。
    @discardableResult
    func toggle(user: Entity) -> Bool {
        if isFollowing(uid: user.uid) {
            unfollow(uid: user.uid)
            return false
        }
        return follow(uid: user.uid, name: user.username, avatar: user.userAvatar)
    }

    private func didChange() {
        timelineModel?.reset()
        pager = nil
        warning = nil
        saveTask?.cancel()
        let snapshot = users
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: 时间线

    /// 汇总名单内用户动态的分页模型，可直接交给 `EntityListView`。同一个 store 只创建一次；
    /// 名单变化后自动重置。`library` 里屏蔽的用户不会被读取。
    func timeline(client: CoolapkClient, library: LibraryStore? = nil) -> PagedList {
        if let timelineModel { return timelineModel }
        let model = PagedList { [weak self] request in
            guard let self else { return EntityPage() }
            return try await self.loadTimeline(request, client: client, library: library)
        }
        timelineModel = model
        return model
    }

    private func loadTimeline(_ request: PagedList.Request, client: CoolapkClient,
                              library: LibraryStore?) async throws -> EntityPage {
        if request.page == 1 || pager == nil {
            let uids = users.map(\.uid).filter { !(library?.isBlocked(uid: $0) ?? false) }
            pager = LocalFollowPager(uids: uids) { uid, page, firstItem, lastItem in
                // 与用户主页同一个接口，但不带置顶动态，保证按时间合并。
                try await client.list(
                    path: "/v6/user/feedList",
                    query: [("uid", uid), ("showAnonymous", "0"), ("isIncludeTop", "0"), ("showDoing", "0")],
                    page: page, firstItem: firstItem, lastItem: lastItem)
            }
            warning = nil
        }
        guard let current = pager else { return EntityPage() }
        let batch = await current.next()
        // 等待期间又刷新过：这次结果作废。
        guard pager === current else { throw CancellationError() }
        warning = batch.warning
        if batch.items.isEmpty, !batch.isEnd {
            if let failure = batch.failure { throw failure }
            throw APIError(.business, "暂时没有读到新动态，请重试")
        }
        var items = batch.items
        if batch.isEnd {
            items.append(Entity(.object(["entityType": .string("card"), "entityTemplate": .string("noMoreDataCard")])))
        }
        return EntityPage(items: items)
    }
}
