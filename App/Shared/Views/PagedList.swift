import CoolapkKit
import Observation
import SwiftUI

/// 加载按游标分页的酷安列表。移植自 Flutter 端的 `CommonController`。
/// 支持可选的本地磁盘首屏缓存：冷启动立即展示缓存，随后在后台无感刷新。
@MainActor
@Observable
final class PagedList {
    enum Phase: Equatable {
        case idle, loading, loaded, empty
        case failed(APIError)
    }

    struct Request {
        let page: Int
        let firstItem: String?
        let lastItem: String?
    }

    typealias Fetch = (Request) async throws -> EntityPage

    private(set) var items: [Entity] = []
    private(set) var phase: Phase = .idle
    private(set) var isRefreshing = false
    private(set) var isSilentRefreshing = false
    private(set) var isLoadingMore = false
    private(set) var reachedEnd = false
    private(set) var autoLoadPaused = false
    private(set) var moreError: APIError?
    private(set) var needsSilentRefresh = false
    private(set) var resetCount = 0
    /// 仅在刷新、重置或顶部插入时递增（翻页追加不变），供列表卡片做 O(1) 判等跳过已有卡片重算。
    private(set) var contentRevision = 0

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let cacheKey: String?
    @ObservationIgnored private let cacheScope: () -> String
    @ObservationIgnored private var page = 1
    @ObservationIgnored private var firstItem: String?
    @ObservationIgnored private var lastItem: String?
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var emptyPageStreak = 0

    init(
        cacheKey: String? = nil,
        cacheScope: @escaping () -> String = { "guest" },
        fetch: @escaping Fetch
    ) {
        self.cacheKey = cacheKey
        self.cacheScope = cacheScope
        self.fetch = fetch
        restoreFromCache()
    }

    /// 开始首次加载；若已从缓存恢复首屏，则改为后台静默刷新。
    /// 任务归模型所有，而不是调用方视图的 task，所以视图重建不会取消它。
    func loadIfNeeded() {
        if phase == .idle {
            phase = .loading
            Task { await refresh() }
        } else if needsSilentRefresh {
            needsSilentRefresh = false
            Task { await refresh(silent: true) }
        }
    }

    func requestMore() {
        guard phase == .loaded, !isRefreshing, !isLoadingMore, !reachedEnd, !autoLoadPaused, moreError == nil else { return }
        Task { await loadMore() }
    }

    /// 清空全部数据（例如切换账号后）；若新作用域下有缓存会立即恢复并标记静默刷新。
    func reset() {
        generation += 1
        items = []
        phase = .idle
        isRefreshing = false
        isSilentRefreshing = false
        isLoadingMore = false
        reachedEnd = false
        autoLoadPaused = false
        emptyPageStreak = 0
        moreError = nil
        seen.removeAll()
        page = 1
        firstItem = nil
        lastItem = nil
        needsSilentRefresh = false
        restoreFromCache()
        resetCount &+= 1
        contentRevision &+= 1
    }

    /// - Parameters:
    ///   - interactive: 用户主动刷新时可以弹出人机验证，自动加载则不会。
    ///   - silent: 后台无感刷新——保留已显示的缓存内容，失败时不报错、不清空界面。
    @discardableResult
    func refresh(interactive: Bool = false, silent: Bool = false) async -> APIError? {
        generation += 1
        let current = generation
        needsSilentRefresh = false
        isRefreshing = true
        isSilentRefreshing = silent
        // 本轮刷新已使之前的 loadMore 失效；立即复位避免旧 loadMore 的 defer 跳过复位导致后续无法再加载。
        isLoadingMore = false
        emptyPageStreak = 0
        autoLoadPaused = false
        if !silent, items.isEmpty { phase = .loading }
        if !silent { moreError = nil }
        defer {
            if current == generation {
                isRefreshing = false
                isSilentRefreshing = false
            }
        }
        do {
            let request = Request(page: 1, firstItem: nil, lastItem: nil)
            let result = try await run(request, interactive: interactive)
            guard current == generation else { return nil }
            persistCache(result)
            // 静默刷新期间如果用户已经翻到了第 2 页以后，不打断当前阅读位置。
            if silent, page > 1 { return nil }

            let existingIDs = Dictionary(
                items.compactMap { entity in entity.dedupeKey.map { ($0, entity.id) } },
                uniquingKeysWith: { first, _ in first }
            )
            var nextSeen = Set<String>()
            var nextReachedEnd = false
            let incoming = accept(result.items, seen: &nextSeen, reachedEnd: &nextReachedEnd).map { entity -> Entity in
                // 同一条帖子沿用旧 UUID，无感刷新时界面不闪烁、瀑布流不重建已有卡片。
                if let key = entity.dedupeKey, let reusedID = existingIDs[key] {
                    return Entity(id: reusedID, json: entity.json)
                }
                return entity
            }

            if silent {
                guard !incoming.isEmpty else { return nil }
                seen = nextSeen
                page = 1
                firstItem = result.firstItem ?? incoming.first(where: { !$0.entityID.isEmpty })?.entityID
                lastItem = result.lastItem ?? incoming.last(where: { !$0.entityID.isEmpty })?.entityID
                reachedEnd = nextReachedEnd
                let changed = incoming.count != items.count
                    || zip(incoming, items).contains { $0.id != $1.id || $0.json != $1.json }
                if changed {
                    withAnimation(.smooth(duration: 0.25)) {
                        items = incoming
                        phase = .loaded
                        contentRevision &+= 1
                    }
                }
            } else {
                seen = nextSeen
                page = 1
                firstItem = result.firstItem ?? incoming.first(where: { !$0.entityID.isEmpty })?.entityID
                lastItem = result.lastItem ?? incoming.last(where: { !$0.entityID.isEmpty })?.entityID
                reachedEnd = nextReachedEnd
                items = incoming
                contentRevision &+= 1
                if items.isEmpty {
                    phase = .empty
                    reachedEnd = true
                } else {
                    phase = .loaded
                }
            }
            return nil
        } catch {
            guard current == generation else { return nil }
            let failure = APIError.from(error)
            if failure.kind == .cancelled {
                if items.isEmpty { phase = .idle }
                return nil
            }
            if silent, !items.isEmpty {
                // 静默刷新失败（如离线或需验证）：安静保留缓存，不影响阅读。
                return nil
            }
            if items.isEmpty { phase = .failed(failure) } else { moreError = failure }
            return failure
        }
    }

    func loadMore(interactive: Bool = false) async {
        guard phase == .loaded, !isRefreshing, !isLoadingMore, !reachedEnd else { return }
        isLoadingMore = true
        moreError = nil
        autoLoadPaused = false
        let current = generation
        defer { if current == generation { isLoadingMore = false } }
        do {
            let request = Request(page: page + 1, firstItem: firstItem, lastItem: lastItem)
            let result = try await run(request, interactive: interactive)
            guard current == generation else { return }
            page += 1
            let previousLastItem = lastItem
            let nextLastItem = result.lastItem ?? result.items.last(where: { !$0.entityID.isEmpty })?.entityID
            if let nextLastItem { lastItem = nextLastItem }
            let fresh = accept(result.items)
            if result.items.isEmpty {
                reachedEnd = true
            } else if fresh.isEmpty {
                // 接口返回的全是已去重的旧条目或占位卡：游标未前进直接收尾，否则最多自动尝试两页后交由用户点击继续。
                if reachedEnd || nextLastItem == nil || nextLastItem == previousLastItem {
                    reachedEnd = true
                } else {
                    emptyPageStreak += 1
                    if emptyPageStreak >= 2 {
                        autoLoadPaused = true
                    }
                }
            } else {
                emptyPageStreak = 0
                items.append(contentsOf: fresh)
            }
        } catch {
            guard current == generation else { return }
            let failure = APIError.from(error)
            if failure.kind != .cancelled { moreError = failure }
        }
    }

    private func restoreFromCache() {
        guard let cacheKey, let cached = FeedCache.shared.load(key: cacheKey, scope: cacheScope()) else { return }
        seen.removeAll()
        let restored = accept(cached.items)
        guard !restored.isEmpty else { return }
        items = restored
        firstItem = cached.firstItem ?? restored.first(where: { !$0.entityID.isEmpty })?.entityID
        lastItem = cached.lastItem ?? restored.last(where: { !$0.entityID.isEmpty })?.entityID
        page = 1
        reachedEnd = false
        phase = .loaded
        needsSilentRefresh = true
    }

    private func persistCache(_ result: EntityPage) {
        guard let cacheKey else { return }
        // 过滤掉不可持久化的占位卡片后再落盘。
        let storable = result.items.filter { entity in
            entity.entityTemplate != "noMoreDataCard"
                && entity.entityTemplate != "refreshCard"
                && entity.entityTemplate != "configCard"
        }
        guard !storable.isEmpty else { return }
        FeedCache.shared.save(
            EntityPage(items: storable, firstItem: result.firstItem, lastItem: result.lastItem),
            key: cacheKey,
            scope: cacheScope()
        )
    }

    private func run(_ request: Request, interactive: Bool) async throws -> EntityPage {
        if interactive {
            return try await CoolapkClient.interactive { try await fetch(request) }
        }
        return try await fetch(request)
    }

    private func accept(_ incoming: [Entity]) -> [Entity] {
        accept(incoming, seen: &seen, reachedEnd: &reachedEnd)
    }

    private func accept(_ incoming: [Entity], seen: inout Set<String>, reachedEnd: inout Bool) -> [Entity] {
        incoming.filter { entity in
            if entity.entityTemplate == "noMoreDataCard"
                || (entity.entityTemplate == "refreshCard" && entity.title.contains("没有")) {
                reachedEnd = true
                return false
            }
            if entity.entityTemplate == "refreshCard" || entity.entityTemplate == "configCard" { return false }
            guard let key = entity.dedupeKey else { return true }
            return seen.insert(key).inserted
        }
    }

    func insertAtTop(_ entity: Entity) {
        items.insert(entity, at: 0)
        contentRevision &+= 1
        if phase == .empty { phase = .loaded }
    }
}
