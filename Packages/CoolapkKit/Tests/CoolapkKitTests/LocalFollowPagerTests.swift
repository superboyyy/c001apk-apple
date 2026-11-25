import XCTest
@testable import CoolapkKit

/// 对应上游 `test/local_follow/local_follow_test.dart` 中的合并分页用例。
final class LocalFollowPagerTests: XCTestCase {
    /// 测试里记录请求的线程安全小本子。
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        private var active = 0
        private(set) var peak = 0
        var shouldFail = true

        func note(_ entry: String) { lock.withLock { storage.append(entry) } }
        var entries: [String] { lock.withLock { storage } }
        func enter() { lock.withLock { active += 1; peak = max(peak, active) } }
        func leave() { lock.withLock { active -= 1 } }
        var failing: Bool {
            get { lock.withLock { shouldFail } }
            set { lock.withLock { shouldFail = newValue } }
        }
    }

    private func ids(_ batch: LocalFollowPager.Batch) -> [String] { batch.items.map(\.entityID) }

    func testMergesByTimeDeduplicatesAndExhaustsIndependently() async {
        let recorder = Recorder()
        let pager = LocalFollowPager(uids: ["1", "2", "1"]) { uid, page, _, last in
            recorder.note("\(uid):\(page):\(last ?? "nil")")
            switch (uid, page) {
            case ("1", 1): return EntityPage(items: [feed(11, 1, 100), feed(12, 1, 70)])
            case ("1", 2): return EntityPage(items: [feed(12, 1, 70), feed(13, 1, 40)])
            case ("2", 1): return EntityPage(items: [feed(21, 2, 90), feed(22, 2, 80)])
            default: return EntityPage()
            }
        }
        let first = await pager.next(limit: 3)
        XCTAssertEqual(ids(first), ["11", "21", "22"])
        XCTAssertFalse(first.isEnd)
        let second = await pager.next(limit: 3)
        XCTAssertEqual(ids(second), ["12", "13"])
        XCTAssertTrue(second.isEnd)
        XCTAssertNil(second.warning)
        XCTAssertTrue(recorder.entries.contains("1:2:12"))
        XCTAssertEqual(recorder.entries.filter { $0.hasPrefix("2:2") }.count, 1)
        XCTAssertEqual(recorder.entries.filter { $0.hasPrefix("1:1") }.count, 1, "重复的 UID 只读一次")
    }

    func testFailedUserKeepsOthersAndRetriesSamePage() async {
        let recorder = Recorder()
        let pager = LocalFollowPager(uids: ["1", "2"]) { uid, page, _, _ in
            if uid == "2" {
                recorder.note("\(page)")
                if recorder.failing { throw APIError(.captcha, "需要验证") }
                if page == 1 { return EntityPage(items: [feed(21, 2, 90)]) }
            }
            if uid == "1", page == 1 { return EntityPage(items: [feed(11, 1, 100)]) }
            return EntityPage()
        }
        let first = await pager.next()
        XCTAssertEqual(ids(first), ["11"])
        XCTAssertEqual(first.failedCount, 1)
        XCTAssertEqual(first.failure?.kind, .captcha)
        XCTAssertTrue(first.warning?.contains("需要验证") == true)
        XCTAssertFalse(first.isEnd)
        recorder.failing = false
        let second = await pager.next()
        XCTAssertEqual(ids(second), ["21"])
        XCTAssertNil(second.failure)
        XCTAssertTrue(second.isEnd)
        XCTAssertEqual(Array(recorder.entries.prefix(2)), ["1", "1"])
    }

    func testReadsAreBoundedAndNoUsersMeansNoRequests() async {
        let recorder = Recorder()
        let fetch: LocalFollowPager.Fetch = { uid, _, _, _ in
            recorder.note(uid)
            recorder.enter()
            try? await Task.sleep(nanoseconds: 2_000_000)
            recorder.leave()
            return EntityPage()
        }
        let empty = await LocalFollowPager(uids: [], fetch: fetch).next()
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertTrue(empty.isEnd)
        XCTAssertTrue(recorder.entries.isEmpty)
        let batch = await LocalFollowPager(uids: (0..<15).map(String.init), fetch: fetch).next()
        XCTAssertTrue(batch.isEnd)
        XCTAssertEqual(recorder.entries.count, 15)
        XCTAssertLessThanOrEqual(recorder.peak, 4)
    }

    func testUsesServerCursorsAndIgnoresForeignRows() async {
        let recorder = Recorder()
        let pager = LocalFollowPager(uids: ["7"]) { _, page, first, last in
            recorder.note("\(first ?? "nil"):\(last ?? "nil")")
            guard page == 1 else { return EntityPage() }
            let card = Entity(.object(["entityType": .string("card"), "entityTemplate": .string("titleCard")]))
            return EntityPage(items: [feed(3, 7, 10), feed(4, 8, 20), card], firstItem: "1", lastItem: "4")
        }
        let batch = await pager.next()
        XCTAssertEqual(ids(batch), ["3"])
        XCTAssertEqual(recorder.entries, ["nil:nil", "1:4"])
    }

    func testStopsAfterThreeUnproductivePagesAndResumes() async {
        let recorder = Recorder()
        let pager = LocalFollowPager(uids: ["1"]) { _, page, _, _ in
            recorder.note("\(page)")
            // 第一页之后连续几页都是同一条旧动态。
            return page <= 5 ? EntityPage(items: [feed(11, 1, 100)]) : EntityPage(items: [feed(12, 1, 50)])
        }
        let first = await pager.next()
        XCTAssertEqual(ids(first), ["11"])
        XCTAssertTrue(first.isDeferred)
        XCTAssertFalse(first.isEnd)
        XCTAssertNotNil(first.warning)
        XCTAssertEqual(recorder.entries, ["1", "2", "3", "4"])
        let second = await pager.next()
        XCTAssertEqual(ids(second), ["12"])
        XCTAssertEqual(recorder.entries.count, 9, "读到新动态后又翻了三页，都没有新内容")
    }

    func testEndCardFinishesAUser() async {
        let pager = LocalFollowPager(uids: ["1"]) { _, _, _, _ in
            let end = Entity(.object(["entityType": .string("card"), "entityTemplate": .string("noMoreDataCard")]))
            return EntityPage(items: [feed(11, 1, 100), end])
        }
        let batch = await pager.next()
        XCTAssertEqual(ids(batch), ["11"])
        XCTAssertTrue(batch.isEnd)
    }
}

private func feed(_ id: Int, _ uid: Int, _ time: Int) -> Entity {
    Entity(.object([
        "id": .number(Double(id)), "entityId": .number(Double(id)), "entityType": .string("feed"),
        "uid": .number(Double(uid)), "dateline": .number(Double(time)),
    ]))
}
