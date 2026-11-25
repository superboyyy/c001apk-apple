import Foundation

/// 把多位用户的公开动态按时间合并成一条时间线，每位用户各自翻页。
/// 同时最多读取四位用户；失败的用户保留原页码，下次调用 `next` 时重试。
/// 不支持并发调用 `next`：刷新时请新建一个实例。
public actor LocalFollowPager {
    public typealias Fetch = @Sendable (_ uid: String, _ page: Int, _ firstItem: String?, _ lastItem: String?)
        async throws -> EntityPage

    /// 一次 `next` 的结果。
    public struct Batch: Sendable {
        public var items: [Entity] = []
        /// 本次读取失败的用户数，以及其中第一个错误。
        public var failedCount = 0
        public var failure: APIError?
        /// 有用户连续几页都没有新动态，暂时跳过；再次调用会继续读。
        public var isDeferred = false
        public var isEnd = false

        /// 给界面看的提示；一切正常时为 nil。
        public var warning: String? {
            if let failure { return "\(failedCount) 位用户的动态加载失败：\(failure.message)" }
            return isDeferred ? "部分用户暂时没有读到新动态，请继续加载" : nil
        }
    }

    private struct Cursor: Sendable {
        let uid: String
        var page = 1
        var first: String?
        var last: String?
        var isEnd = false
        var buffer: [Entity] = []
        var seen = Set<String>()
    }

    private enum Outcome: Sendable {
        case loaded, deferred
        case failed(APIError)
    }

    private static let concurrency = 4
    private static let attemptsPerUser = 3

    private let fetch: Fetch
    private var cursors: [Cursor]
    private var seen = Set<String>()

    public init(uids: [String], fetch: @escaping Fetch) {
        var unique = Set<String>()
        cursors = uids.filter { unique.insert($0).inserted }.map { Cursor(uid: $0) }
        self.fetch = fetch
    }

    public var isEnd: Bool { cursors.allSatisfy { $0.isEnd && $0.buffer.isEmpty } }

    public func next(limit: Int = 20) async -> Batch {
        var batch = Batch()
        var failed = Set<Int>()
        var deferred = Set<Int>()
        while batch.items.count < limit {
            let pending = cursors.indices.filter {
                !cursors[$0].isEnd && cursors[$0].buffer.isEmpty && !failed.contains($0) && !deferred.contains($0)
            }
            for start in stride(from: 0, to: pending.count, by: Self.concurrency) {
                let group = pending[start..<min(start + Self.concurrency, pending.count)]
                let fetch = self.fetch
                let results = await withTaskGroup(of: (Int, Cursor, Outcome).self) { tasks in
                    for index in group {
                        let cursor = cursors[index]
                        tasks.addTask {
                            var cursor = cursor
                            let outcome = await Self.advance(&cursor, fetch: fetch)
                            return (index, cursor, outcome)
                        }
                    }
                    var collected: [(Int, Cursor, Outcome)] = []
                    for await result in tasks { collected.append(result) }
                    return collected
                }
                for (index, cursor, outcome) in results.sorted(by: { $0.0 < $1.0 }) {
                    cursors[index] = cursor
                    switch outcome {
                    case .loaded: break
                    case .deferred: deferred.insert(index)
                    case .failed(let error):
                        failed.insert(index)
                        if batch.failure == nil { batch.failure = error }
                    }
                }
            }
            // 取各用户缓冲区里最新的一条。
            var newest: Int?
            for index in cursors.indices where !cursors[index].buffer.isEmpty {
                if let current = newest, Self.time(cursors[current].buffer[0]) >= Self.time(cursors[index].buffer[0]) {
                    continue
                }
                newest = index
            }
            guard let newest else { break }
            let item = cursors[newest].buffer.removeFirst()
            if seen.insert(item.entityID).inserted { batch.items.append(item) }
        }
        batch.failedCount = failed.count
        batch.isDeferred = !deferred.isEmpty
        batch.isEnd = isEnd
        return batch
    }

    /// 为一位用户读到有新动态为止，最多读三页，避免整页都是重复内容时无限翻页。
    private static func advance(_ cursor: inout Cursor, fetch: Fetch) async -> Outcome {
        for _ in 0..<attemptsPerUser {
            let page: EntityPage
            do {
                page = try await fetch(cursor.uid, cursor.page, cursor.first, cursor.last)
            } catch {
                return .failed(APIError.from(error))
            }
            if page.items.isEmpty {
                cursor.isEnd = true
                return .loaded
            }
            cursor.isEnd = page.items.contains { $0.entityTemplate == "noMoreDataCard" }
            let uid = cursor.uid
            let feeds = page.items.filter { $0.entityType == "feed" && !$0.entityID.isEmpty && $0.uid == uid }
            if cursor.first == nil { cursor.first = page.firstItem ?? feeds.first?.entityID }
            cursor.last = page.lastItem ?? feeds.last?.entityID ?? cursor.last
            cursor.page += 1
            for feed in feeds where cursor.seen.insert(feed.entityID).inserted { cursor.buffer.append(feed) }
            cursor.buffer.sort { time($0) > time($1) }
            if !cursor.buffer.isEmpty || cursor.isEnd { return .loaded }
        }
        return .deferred
    }

    private static func time(_ entity: Entity) -> Int { entity.dateline ?? 0 }
}
