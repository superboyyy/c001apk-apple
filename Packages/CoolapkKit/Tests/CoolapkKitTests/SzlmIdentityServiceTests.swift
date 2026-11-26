import XCTest
@testable import CoolapkKit

final class SzlmIdentityServiceTests: XCTestCase {
    private struct SyntheticStorageError: Error {}

    private final class MemoryStorage: SzlmIdentityStorage, @unchecked Sendable {
        private let lock = NSLock()
        var seed: String?
        var lastSuccessMs: Int64?
        var attempts: [Int64] = []
        var failKey: String?

        func readSeed() throws -> String? {
            lock.withLock { seed }
        }

        func writeSeed(_ value: String) throws {
            try lock.withLock {
                if failKey == "seed" { throw SyntheticStorageError() }
                seed = value
            }
        }

        func readLastSuccessMs() -> Int64? {
            lock.withLock { lastSuccessMs }
        }

        func writeLastSuccessMs(_ timestampMs: Int64) throws {
            try lock.withLock {
                if failKey == "success" { throw SyntheticStorageError() }
                lastSuccessMs = timestampMs
            }
        }

        func readAttemptTimestampsMs() -> [Int64] {
            lock.withLock { attempts }
        }

        func writeAttemptTimestampsMs(_ timestampsMs: [Int64]) throws {
            try lock.withLock {
                if failKey == "attempts" { throw SyntheticStorageError() }
                attempts = timestampsMs
            }
        }
    }

    private final class Harness: @unchecked Sendable {
        let storage = MemoryStorage()
        let lock = NSLock()
        var now = Date(timeIntervalSince1970: 1_793_059_200) // 2026-10-27 UTC
        var identity: ClientIdentity
        var calls = 0
        var fetchImpl: @Sendable () async throws -> String = { "DUsyntheticNEW1234567890123" }

        init() {
            var initial = ClientIdentity()
            try! initial.applySzlmID("DUsyntheticEXISTING123456789")
            identity = initial
        }

        private func runFetch() async throws -> String {
            let impl: @Sendable () async throws -> String = lock.withLock {
                calls += 1
                return fetchImpl
            }
            return try await impl()
        }

        func makeService(
            useFetchOverride: Bool = true,
            register: (@Sendable (String) async throws -> String)? = nil
        ) -> SzlmIdentityService {
            var fetchClosure: (@Sendable () async throws -> String)?
            if useFetchOverride {
                fetchClosure = { try await self.runFetch() }
            }
            return SzlmIdentityService(
                storage: storage,
                clock: { self.lock.withLock { self.now } },
                fetch: fetchClosure,
                register: register,
                readIdentity: { self.lock.withLock { self.identity } },
                apply: { value in
                    try self.lock.withLock {
                        try self.identity.applySzlmID(value)
                    }
                }
            )
        }
    }

    private final class SendableBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func withLock<R>(_ body: (inout Value) -> R) -> R {
            lock.withLock { body(&value) }
        }
    }

    func testProtocolSeedPersistsAcrossFailedAttemptsAndRestart() async throws {
        let harness = Harness()
        let seedsBox = SendableBox<[String]>([])
        let register: @Sendable (String) async throws -> String = { seed in
            seedsBox.withLock { $0.append(seed) }
            throw SzlmDuidError("合成断网")
        }

        do {
            _ = try await harness.makeService(useFetchOverride: false, register: register).renewNow()
            XCTFail("应抛出断网错误")
        } catch is SzlmDuidError {}

        harness.lock.withLock { harness.now = harness.now.addingTimeInterval(5 * 60) }
        do {
            _ = try await harness.makeService(useFetchOverride: false, register: register).renewNow()
            XCTFail("应抛出断网错误")
        } catch is SzlmDuidError {}

        let seeds = seedsBox.withLock { $0 }
        XCTAssertEqual(seeds.count, 2)
        XCTAssertTrue(SzlmDuidClient.isValidSeed(seeds[0]))
        XCTAssertEqual(seeds[0], seeds[1])
        XCTAssertEqual(harness.lock.withLock { harness.identity.szlmID }, "DUsyntheticEXISTING123456789")
    }

    func testSeedPersistenceFailurePreventsRegistration() async {
        let harness = Harness()
        harness.storage.failKey = "seed"
        let regBox = SendableBox(0)
        let service = harness.makeService(useFetchOverride: false, register: { _ in
            regBox.withLock { $0 += 1 }
            return "DUsyntheticNEW1234567890123"
        })

        do {
            _ = try await service.renewNow()
            XCTFail("种子落盘失败应阻止请求")
        } catch is SyntheticStorageError {
            XCTAssertEqual(regBox.withLock { $0 }, 0)
            XCTAssertEqual(harness.lock.withLock { harness.identity.szlmID }, "DUsyntheticEXISTING123456789")
        } catch {
            XCTFail("意外错误：\(error)")
        }
    }

    func testSuccessfulAcquisitionPersistsSevenDayBoundaryAcrossRestart() async throws {
        let harness = Harness()
        _ = try await harness.makeService().renewNow()
        XCTAssertEqual(harness.lock.withLock { harness.identity.szlmID }, "DUsyntheticNEW1234567890123")

        harness.lock.withLock {
            harness.now = harness.now.addingTimeInterval(7 * 86_400 - 0.001)
        }
        do {
            _ = try await harness.makeService().renewNow()
            XCTFail("未满 7 天应被拒绝")
        } catch is SzlmDuidError {}
        XCTAssertEqual(harness.lock.withLock { harness.calls }, 1)

        harness.lock.withLock {
            harness.now = harness.now.addingTimeInterval(0.002)
        }
        _ = try await harness.makeService().renewNow()
        XCTAssertEqual(harness.lock.withLock { harness.calls }, 2)
    }

    func testFailuresRetainFiveMinuteCooldownAndThreeAttemptsInRollingDay() async throws {
        let harness = Harness()
        harness.lock.withLock {
            harness.fetchImpl = { throw SzlmDuidError("合成断网") }
        }

        for i in 0..<3 {
            do {
                _ = try await harness.makeService().renewNow()
                XCTFail("应失败")
            } catch is SzlmDuidError {}
            do {
                _ = try await harness.makeService().renewNow()
                XCTFail("冷却期内应被拒绝")
            } catch is SzlmDuidError {}
            XCTAssertEqual(harness.lock.withLock { harness.calls }, i + 1)
            harness.lock.withLock { harness.now = harness.now.addingTimeInterval(5 * 60) }
        }

        // 第 4 次在 24 小时滚动窗口内应被拦截。
        do {
            _ = try await harness.makeService().renewNow()
            XCTFail("24 小时内超过 3 次应被拒绝")
        } catch is SzlmDuidError {}
        XCTAssertEqual(harness.lock.withLock { harness.calls }, 3)

        // 越过 24 小时滚动窗口后允许再次尝试。
        harness.lock.withLock { harness.now = Date(timeIntervalSince1970: 1_793_059_200 + 86_400) }
        do {
            _ = try await harness.makeService().renewNow()
            XCTFail("合成断网应抛出错误")
        } catch is SzlmDuidError {}
        XCTAssertEqual(harness.lock.withLock { harness.calls }, 4)
    }

    func testConcurrentRenewalsShareOneRequestAndManualImportWinsRace() async throws {
        let harness = Harness()
        let gate = AsyncGate()
        harness.lock.withLock {
            harness.fetchImpl = {
                await gate.signalStartedAndWait()
                return "DUsyntheticNEW1234567890123"
            }
        }
        let service = harness.makeService()

        let first = Task { try await service.renewNow() }
        let second = Task { try await service.renewNow() }
        await gate.waitUntilStarted()

        // 模拟请求进行期间用户完成了手动导入。
        harness.lock.withLock {
            try! harness.identity.applySzlmID("DUsyntheticMANUAL123456789")
        }
        await gate.release()

        do {
            _ = try await first.value
            XCTFail("手动导入应胜出")
        } catch is SzlmDuidError {}
        do {
            _ = try await second.value
            XCTFail("并发等待方也应收到同样结果")
        } catch is SzlmDuidError {}

        XCTAssertEqual(harness.lock.withLock { harness.identity.szlmID }, "DUsyntheticMANUAL123456789")
        XCTAssertEqual(harness.lock.withLock { harness.calls }, 1)

        // 本次注册已计入 7 天间隔。
        do {
            _ = try await harness.makeService().renewNow()
            XCTFail("应已进入 7 天间隔")
        } catch is SzlmDuidError {}
        XCTAssertEqual(harness.lock.withLock { harness.calls }, 1)
    }

    func testClockRollbackDoesNotBypassExistingCooldown() async throws {
        let harness = Harness()
        _ = try await harness.makeService().renewNow()
        harness.lock.withLock {
            harness.now = harness.now.addingTimeInterval(-30 * 86_400)
        }
        do {
            _ = try await harness.makeService().renewNow()
            XCTFail("回拨系统时间不能绕过冷却")
        } catch is SzlmDuidError {}
        XCTAssertEqual(harness.lock.withLock { harness.calls }, 1)
    }

    func testAttemptRecordSaveFailurePreventsRegistration() async {
        let harness = Harness()
        harness.storage.failKey = "attempts"
        do {
            _ = try await harness.makeService().renewNow()
            XCTFail("尝试记录保存失败应阻止发请求")
        } catch is SyntheticStorageError {
            XCTAssertEqual(harness.lock.withLock { harness.calls }, 0)
            XCTAssertEqual(harness.lock.withLock { harness.identity.szlmID }, "DUsyntheticEXISTING123456789")
        } catch {
            XCTFail("意外错误：\(error)")
        }
    }

    func testSuccessRecordSaveFailurePreservesOldIDAndBlocksRepeatInMemory() async {
        let harness = Harness()
        harness.storage.failKey = "success"
        let service = harness.makeService()
        do {
            _ = try await service.renewNow()
            XCTFail("成功记录保存失败应抛出异常")
        } catch is SyntheticStorageError {
            XCTAssertEqual(harness.lock.withLock { harness.calls }, 1)
            XCTAssertEqual(harness.lock.withLock { harness.identity.szlmID }, "DUsyntheticEXISTING123456789")
        } catch {
            XCTFail("意外错误：\(error)")
        }
        do {
            _ = try await service.renewNow()
            XCTFail("内存中的成功记录应阻止重复调用")
        } catch is SzlmDuidError {
            XCTAssertEqual(harness.lock.withLock { harness.calls }, 1)
        } catch {
            XCTFail("意外错误：\(error)")
        }
    }
}

private actor AsyncGate {
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func signalStartedAndWait() async {
        started = true
        for waiter in startedWaiters { waiter.resume() }
        startedWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
    }

    func waitUntilStarted() async {
        if !started {
            await withCheckedContinuation { startedWaiters.append($0) }
        }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}
