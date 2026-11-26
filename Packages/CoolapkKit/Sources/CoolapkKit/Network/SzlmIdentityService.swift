import Foundation

/// 数盟设备标识获取记录与安装种子的持久化抽象，便于测试注入故障。
public protocol SzlmIdentityStorage: AnyObject, Sendable {
    func readSeed() throws -> String?
    func writeSeed(_ seed: String) throws
    func readLastSuccessMs() -> Int64?
    func writeLastSuccessMs(_ timestampMs: Int64) throws
    func readAttemptTimestampsMs() -> [Int64]
    func writeAttemptTimestampsMs(_ timestampsMs: [Int64]) throws
}

/// 基于 `UserDefaults` 的默认存储实现。
public final class UserDefaultsSzlmStorage: SzlmIdentityStorage, @unchecked Sendable {
    private let defaults: UserDefaults
    private let seedKey: String
    private let successKey: String
    private let attemptsKey: String

    public init(
        defaults: UserDefaults = .standard,
        seedKey: String = "szlmReportSeed",
        successKey: String = "szlmLastAcquiredAt",
        attemptsKey: String = "szlmAcquisitionAttempts"
    ) {
        self.defaults = defaults
        self.seedKey = seedKey
        self.successKey = successKey
        self.attemptsKey = attemptsKey
    }

    public func readSeed() throws -> String? {
        guard let raw = defaults.object(forKey: seedKey) else { return nil }
        guard let seed = raw as? String, SzlmDuidClient.isValidSeed(seed) else {
            throw SzlmDuidError("本机设备报文配置无法读取，请使用手动导入")
        }
        return seed
    }

    public func writeSeed(_ seed: String) throws {
        defaults.set(seed, forKey: seedKey)
    }

    public func readLastSuccessMs() -> Int64? {
        guard let value = defaults.object(forKey: successKey) as? NSNumber else { return nil }
        return value.int64Value
    }

    public func writeLastSuccessMs(_ timestampMs: Int64) throws {
        defaults.set(NSNumber(value: timestampMs), forKey: successKey)
    }

    public func readAttemptTimestampsMs() -> [Int64] {
        guard let values = defaults.array(forKey: attemptsKey) else { return [] }
        return values.compactMap { ($0 as? NSNumber)?.int64Value }
    }

    public func writeAttemptTimestampsMs(_ timestampsMs: [Int64]) throws {
        defaults.set(timestampsMs.map { NSNumber(value: $0) }, forKey: attemptsKey)
    }
}

/// 数盟设备标识获取服务：仅在用户主动点击时触发，附带单飞、冷却与次数上限控制。
/// 移植自上游 `TG-Twilight/c001apk` 的 `szlm_identity_service.dart`。
public final class SzlmIdentityService: @unchecked Sendable {
    public static let cooldown: TimeInterval = 5 * 60
    public static let successInterval: TimeInterval = 7 * 86_400
    public static let attemptWindow: TimeInterval = 86_400
    public static let maxAttempts = 3

    private let lock = NSLock()
    private let storage: SzlmIdentityStorage
    private let clock: @Sendable () -> Date
    private let fetchOverride: (@Sendable () async throws -> String)?
    private let registerOverride: (@Sendable (String) async throws -> String)?
    private let readIdentity: @Sendable () -> ClientIdentity
    private let applyID: @Sendable (String) async throws -> Void
    private var _onStateChange: (@Sendable () -> Void)?

    private var runningTask: Task<String, Error>?
    private var successInMemory: Int64?
    private var attemptsInMemory: [Int64]?

    public init(
        storage: SzlmIdentityStorage = UserDefaultsSzlmStorage(),
        clock: @escaping @Sendable () -> Date = { Date() },
        fetch: (@Sendable () async throws -> String)? = nil,
        register: (@Sendable (String) async throws -> String)? = nil,
        readIdentity: @escaping @Sendable () -> ClientIdentity,
        apply: @escaping @Sendable (String) async throws -> Void
    ) {
        self.storage = storage
        self.clock = clock
        self.fetchOverride = fetch
        self.registerOverride = register
        self.readIdentity = readIdentity
        self.applyID = apply
    }

    public var onStateChange: (@Sendable () -> Void)? {
        get { lock.withLock { _onStateChange } }
        set { lock.withLock { _onStateChange = newValue } }
    }

    public var isFetching: Bool {
        lock.withLock { runningTask != nil }
    }

    public var nextAllowedAt: Date? {
        lock.withLock { nextAllowedAtLocked(now: clock()) }
    }

    public var unavailableReason: String? {
        guard let next = nextAllowedAt else { return nil }
        return "可再次获取时间：\(Self.formatLocalDateTime(next))"
    }

    /// 主动发起一次数盟标识获取；并发点击共享同一请求。
    @discardableResult
    public func renewNow() async throws -> String {
        let (task, started): (Task<String, Error>, Bool) = lock.withLock {
            if let existing = runningTask {
                return (existing, false)
            }
            let created = Task<String, Error> { [self] in
                try await self.run()
            }
            runningTask = created
            return (created, true)
        }
        if started { notifyStateChange() }
        defer {
            if started {
                lock.withLock {
                    if runningTask == task { runningTask = nil }
                }
                notifyStateChange()
            }
        }
        return try await task.value
    }

    public static func formatLocalDateTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d",
            comps.year ?? 0, comps.month ?? 0, comps.day ?? 0, comps.hour ?? 0, comps.minute ?? 0
        )
    }

    // MARK: - 内部流程

    private func run() async throws -> String {
        let now = clock()
        let attemptsToSave: [Int64] = try lock.withLock {
            if let next = nextAllowedAtLocked(now: now) {
                throw SzlmDuidError("可再次获取时间：\(Self.formatLocalDateTime(next))")
            }
            let updated = recentAttemptsLocked(now: now) + [Self.milliseconds(now)]
            attemptsInMemory = updated
            return updated
        }
        let snapshot = readIdentity()

        // 先落盘尝试记录再联网：保存失败绝不发请求。
        try storage.writeAttemptTimestampsMs(attemptsToSave)

        let rawID = try await acquire(profile: snapshot)
        let id: String
        do {
            id = try OfficialDeviceIdentity.parse("ShuzlmID: \(rawID)")
        } catch let error as OfficialDeviceIdentityError {
            throw SzlmDuidError(error.message)
        }

        // 即使随后被手动导入覆盖，本次注册已消耗服务端配额，先记成功时间。
        let successMs = Self.milliseconds(clock())
        lock.withLock { successInMemory = successMs }
        try storage.writeLastSuccessMs(successMs)

        let latest = readIdentity()
        if latest.szlmID != snapshot.szlmID || latest.deviceCode != snapshot.deviceCode {
            throw SzlmDuidError("设备标识已被更新，已保留当前值；本次获取已计入间隔")
        }
        try await applyID(id)
        return id
    }

    private func acquire(profile: ClientIdentity) async throws -> String {
        if let fetchOverride { return try await fetchOverride() }
        let stored = try storage.readSeed()
        let seed = stored ?? SzlmDuidClient.createSeed()
        if stored == nil {
            try storage.writeSeed(seed)
        }
        if let registerOverride { return try await registerOverride(seed) }
        return try await SzlmDuidClient.fetch(
            seed: seed,
            manufacturer: profile.manufacturer,
            model: profile.model,
            androidVersion: profile.androidVersion,
            sdkInt: Int(profile.sdkInt) ?? 33
        )
    }

    private func recentAttemptsLocked(now: Date) -> [Int64] {
        let values = attemptsInMemory ?? storage.readAttemptTimestampsMs()
        let threshold = Self.milliseconds(now.addingTimeInterval(-Self.attemptWindow))
        return values.filter { $0 > threshold }.sorted()
    }

    private func nextAllowedAtLocked(now: Date) -> Date? {
        var next: Date?
        func include(_ milliseconds: Int64, interval: TimeInterval) {
            let candidate = Date(timeIntervalSince1970: Double(milliseconds) / 1000.0).addingTimeInterval(interval)
            if candidate > now, next == nil || candidate > next! {
                next = candidate
            }
        }

        if let success = successInMemory ?? storage.readLastSuccessMs() {
            include(success, interval: Self.successInterval)
        }
        let attempts = recentAttemptsLocked(now: now)
        if let last = attempts.last {
            include(last, interval: Self.cooldown)
        }
        if attempts.count >= Self.maxAttempts {
            include(attempts[attempts.count - Self.maxAttempts], interval: Self.attemptWindow)
        }
        return next
    }

    private func notifyStateChange() {
        onStateChange?()
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 * 1000.0))
    }
}
