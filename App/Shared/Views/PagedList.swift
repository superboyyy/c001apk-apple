import CoolapkKit
import Observation
import SwiftUI

/// 加载按游标分页的酷安列表。移植自 Flutter 端的 `CommonController`。
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
    private(set) var isLoadingMore = false
    private(set) var reachedEnd = false
    private(set) var moreError: APIError?

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var page = 1
    @ObservationIgnored private var firstItem: String?
    @ObservationIgnored private var lastItem: String?
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var generation = 0

    init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    /// 开始首次加载。任务归模型所有，而不是调用方视图的 task，
    /// 所以视图重建不会取消它。
    func loadIfNeeded() {
        guard phase == .idle else { return }
        phase = .loading
        Task { await refresh() }
    }

    func requestMore() {
        guard phase == .loaded, !isLoadingMore, !reachedEnd, moreError == nil else { return }
        Task { await loadMore() }
    }

    /// 清空全部数据，下次出现时重新加载。
    func reset() {
        generation += 1
        items = []
        phase = .idle
        isLoadingMore = false
        reachedEnd = false
        moreError = nil
        seen.removeAll()
    }

    /// - Parameter interactive: 用户主动刷新时可以弹出人机验证，
    ///   自动加载则不会。
    func refresh(interactive: Bool = false) async {
        generation += 1
        let current = generation
        if items.isEmpty { phase = .loading }
        moreError = nil
        do {
            let request = Request(page: 1, firstItem: nil, lastItem: nil)
            let result = try await run(request, interactive: interactive)
            guard current == generation else { return }
            seen.removeAll()
            page = 1
            firstItem = result.firstItem
            lastItem = result.lastItem
            reachedEnd = false
            items = accept(result.items)
            if items.isEmpty {
                phase = .empty
                reachedEnd = true
            } else {
                phase = .loaded
            }
        } catch {
            guard current == generation else { return }
            let failure = APIError.from(error)
            if failure.kind == .cancelled {
                // 不算结果：允许下次出现时重新加载。
                if items.isEmpty { phase = .idle }
                return
            }
            if items.isEmpty { phase = .failed(failure) } else { moreError = failure }
        }
    }

    func loadMore(interactive: Bool = false) async {
        guard phase == .loaded, !isLoadingMore, !reachedEnd else { return }
        isLoadingMore = true
        moreError = nil
        let current = generation
        defer { if current == generation { isLoadingMore = false } }
        do {
            let request = Request(page: page + 1, firstItem: firstItem, lastItem: lastItem)
            let result = try await run(request, interactive: interactive)
            guard current == generation else { return }
            page += 1
            if let last = result.lastItem { lastItem = last }
            let fresh = accept(result.items)
            if result.items.isEmpty {
                reachedEnd = true
            } else {
                items.append(contentsOf: fresh)
            }
        } catch {
            guard current == generation else { return }
            let failure = APIError.from(error)
            if failure.kind != .cancelled { moreError = failure }
        }
    }

    private func run(_ request: Request, interactive: Bool) async throws -> EntityPage {
        if interactive {
            return try await CoolapkClient.interactive { try await fetch(request) }
        }
        return try await fetch(request)
    }

    private func accept(_ incoming: [Entity]) -> [Entity] {
        incoming.filter { entity in
            if entity.entityTemplate == "noMoreDataCard" {
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
        if phase == .empty { phase = .loaded }
    }
}
