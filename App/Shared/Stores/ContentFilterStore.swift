import CoolapkKit
import Foundation
import Observation

/// 内容过滤的本机状态：开关、档位、规则与例外，保存在 Application Support/c001apk/content-filter.json。
/// 默认关闭；没有填写订阅地址时不会联网。
@MainActor
@Observable
final class ContentFilterStore {
    /// 上游项目发布规则的地址，仅作为可选的订阅源提供，不会自动使用。
    static let upstreamRulesURL = "https://raw.githubusercontent.com/TG-Twilight/c001apk/filters/rules.json"

    private struct CacheKey: Hashable {
        let id: UUID
        let scope: FilterScope?
    }

    private(set) var filter: ContentFilter
    private(set) var isUpdating = false
    /// 最近一次检查更新的结果，给设置页显示。
    private(set) var updateMessage: String?

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var cache: [CacheKey: FilterMatch?] = [:]

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let directory = base.appendingPathComponent("c001apk", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.fileURL = directory.appendingPathComponent("content-filter.json")
        }
        if let data = try? Data(contentsOf: self.fileURL), let snapshot = JSON.parse(data) {
            filter = ContentFilter(snapshot: snapshot)
        } else {
            filter = ContentFilter()
        }
        if filter.cacheWasDamaged { updateMessage = "规则缓存损坏，已使用内置规则" }
    }

    // MARK: 判断

    /// 列表入口：这一行是否应当隐藏。未开启过滤时恒为 false。
    func shouldHide(_ entity: Entity) -> Bool { match(entity) != nil }

    /// 命中的规则；`scope` 留空时按行类型推断（动态、回复、用户）。
    func match(_ entity: Entity, scope: FilterScope? = nil) -> FilterMatch? {
        guard filter.isEnabled else { return nil }
        let key = CacheKey(id: entity.id, scope: scope)
        if let cached = cache[key] { return cached }
        let result = filter.match(entity, scope: scope)
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }

    // MARK: 设置

    /// 开启时顺便检查一次订阅（没有订阅地址或未到间隔时什么也不做）。
    var isEnabled: Bool {
        get { filter.isEnabled }
        set {
            update { $0.setEnabled(newValue) }
            if newValue { Task { await checkForUpdates() } }
        }
    }

    var level: FilterLevel {
        get { filter.level }
        set { update { $0.setLevel(newValue) } }
    }

    func isListEnabled(_ kind: FilterRuleKind) -> Bool { filter.isListEnabled(kind) }

    func setListEnabled(_ kind: FilterRuleKind, _ enabled: Bool) {
        update { try? $0.setListEnabled(kind, enabled) }
    }

    func isRuleDisabled(_ id: String) -> Bool { filter.disabledRuleIDs.contains(id) }

    func setRuleDisabled(_ id: String, _ disabled: Bool) {
        update { try? $0.setRuleDisabled(id, disabled) }
    }

    func setAuthorAllowed(_ uid: String, _ allowed: Bool) throws {
        try updateThrowing { try $0.setAuthorAllowed(uid, allowed) }
    }

    func setContentAllowed(_ key: String, _ allowed: Bool) throws {
        try updateThrowing { try $0.setContentAllowed(key, allowed) }
    }

    /// 把这一条内容加入长期例外。
    func allowContent(_ entity: Entity, scope: FilterScope? = nil) {
        try? setContentAllowed(ContentFilterProjection.key(of: entity, scope: scope), true)
    }

    func addPersonalRule(kind: FilterRuleKind, value: String) throws {
        try updateThrowing { try $0.addPersonalRule(kind: kind, value: value) }
    }

    func removePersonalRule(_ id: String) {
        update { $0.removePersonalRule(id) }
    }

    // MARK: 订阅

    /// 保存订阅地址（https，留空表示不订阅）。地址变化时回到内置规则。
    func setSubscriptionURL(_ value: String) throws {
        try updateThrowing { try $0.setSubscriptionURL(value) }
        updateMessage = nil
    }

    func resetToBuiltinRules() {
        update { $0.resetToBuiltinRules() }
        updateMessage = "已恢复内置规则"
    }

    /// 检查订阅更新。非强制时只在已开启、已配置订阅且距上次成功超过六小时才会请求。
    func checkForUpdates(force: Bool = false) async {
        guard !isUpdating else { return }
        guard let url = URL(string: filter.subscriptionURL), !filter.subscriptionURL.isEmpty else {
            if force { updateMessage = "尚未设置订阅地址" }
            return
        }
        guard force || filter.isUpdateDue() else { return }
        isUpdating = true
        updateMessage = "正在检查规则更新"
        defer { isUpdating = false }
        do {
            let data = try await Self.download(url)
            guard url.absoluteString == filter.subscriptionURL else { return }
            try updateThrowing { try $0.applySubscription(data) }
            updateMessage = "规则已是最新（版本 \(filter.ruleSet.revision)）"
        } catch {
            updateMessage = "规则更新失败，继续使用已有规则"
        }
    }

    /// 不跟随重定向，避免订阅被引到别处。
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// 独立的一次性会话：不带账号 Cookie、设备头或缓存，响应最多读取 1 MiB。
    private nonisolated static func download(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("c001apk-content-filter/1", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectBlocker())
        let type = (response.mimeType ?? "").lowercased()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              type == "application/json" || type == "text/plain",
              response.expectedContentLength <= Int64(ContentFilter.maxSubscriptionBytes) else {
            throw FilterFormatError("订阅响应无效")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < ContentFilter.maxSubscriptionBytes else { throw FilterFormatError("订阅内容过大") }
            data.append(byte)
        }
        return data
    }

    // MARK: 存档

    private func update(_ change: (inout ContentFilter) -> Void) {
        var next = filter
        change(&next)
        commit(next)
    }

    private func updateThrowing(_ change: (inout ContentFilter) throws -> Void) throws {
        var next = filter
        try change(&next)
        commit(next)
    }

    private func commit(_ next: ContentFilter) {
        filter = next
        cache.removeAll(keepingCapacity: true)
        saveTask?.cancel()
        let snapshot = next.snapshot
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let data = snapshot.serialized(pretty: true) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
