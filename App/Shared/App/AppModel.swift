import CoolapkKit
import Observation
import SwiftUI

/// 等待界面呈现的一次人机验证。
struct CaptchaRequest: Identifiable {
    let id: UUID
    let challenge: CaptchaChallenge
    let userAgent: String
    let finish: @MainActor (String?) -> Void
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

/// 全局状态：接口客户端、当前登录账号和偏好设置。
@MainActor
@Observable
final class AppModel {
    let settings = AppSettings()
    let library = LibraryStore()
    let contentFilter = ContentFilterStore()
    let localFollow = LocalFollowStore()
    @ObservationIgnored let client: CoolapkClient
    @ObservationIgnored private var szlmService: SzlmIdentityService!
    /// 首页信息流请求携带的毫秒时间戳，每次安装固定不变。
    @ObservationIgnored let installTime: String

    /// 当前账号；为空表示游客。
    private(set) var account: Account?
    /// 本机登录过的全部账号。
    private(set) var accounts: [Account] = []
    private(set) var identity: ClientIdentity
    private(set) var isFetchingSzlmID = false
    /// 数盟获取状态或冷却时间更新时递增，用来驱动界面刷新。
    private(set) var szlmStateRevision = 0
    var captcha: CaptchaRequest?
    var isShowingLogin = false
    /// 非空时在窗口上方浮出发布 / 回复编辑器。
    var composeTarget: ComposeTarget?
    /// 编辑器发布成功后的回调，由发起页面提供。
    @ObservationIgnored var composeCompletion: ((Entity) -> Void)?
    /// iPadOS 上设置页以弹出层呈现（macOS 用系统的设置窗口）。
    var isShowingSettings = false
    var toast: Toast?

    /// 列表行数据暂存给详情页，请求返回前就能先渲染。
    @ObservationIgnored private var previews: [String: Entity] = [:]
    @ObservationIgnored private var listModels: [String: PagedList] = [:]
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    private nonisolated static let identityKey = "clientIdentity"
    private nonisolated static let sessionKey = "apiSession"
    private nonisolated static let installTimeKey = "installTime"

    init() {
        let defaults = UserDefaults.standard
        var identity: ClientIdentity
        if let data = defaults.data(forKey: Self.identityKey),
           let stored = try? JSONDecoder().decode(ClientIdentity.self, from: data), !stored.deviceCode.isEmpty {
            identity = stored
        } else {
            identity = ClientIdentity()
            defaults.set(try? JSONEncoder().encode(identity), forKey: Self.identityKey)
        }
        self.identity = identity

        if let stored = defaults.string(forKey: Self.installTimeKey) {
            installTime = stored
        } else {
            installTime = String(Int(Date().timeIntervalSince1970 * 1000))
            defaults.set(installTime, forKey: Self.installTimeKey)
        }

        let stored = AccountStore.load()
        let account = stored.accounts.first { $0.uid == stored.currentUID } ?? stored.accounts.first
        self.accounts = stored.accounts
        self.account = account
        let session = defaults.data(forKey: Self.sessionKey)
            .flatMap { try? JSONDecoder().decode(CoolapkClient.SessionCookie.self, from: $0) }
        let apiClient = CoolapkClient(identity: identity, account: account, sessionCookie: session)
        client = apiClient
        let service = SzlmIdentityService(
            readIdentity: { apiClient.identity },
            apply: { [weak self] id in
                guard let model = self else { return }
                try await MainActor.run {
                    try model.applySzlmID(id)
                }
            }
        )
        szlmService = service
        service.onStateChange = { [weak self, weak service] in
            guard let model = self, let service else { return }
            Task { @MainActor in
                model.isFetchingSzlmID = service.isFetching
                model.szlmStateRevision &+= 1
            }
        }

        LivePhotoLoader.resolver = { [client] media in
            try? await client.livePhotoVideoURL(for: media)
        }
        client.onSessionCookieChange = { cookie in
            if let cookie, let data = try? JSONEncoder().encode(cookie) {
                UserDefaults.standard.set(data, forKey: Self.sessionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.sessionKey)
            }
        }
        client.captchaHandler = { [weak self] challenge in
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume(returning: nil)
                        return
                    }
                    self.captcha?.finish(nil)
                    let requestID = UUID()
                    var resumed = false
                    self.captcha = CaptchaRequest(id: requestID, challenge: challenge, userAgent: self.identity.userAgent) { [weak self] proof in
                        guard !resumed else { return }
                        resumed = true
                        if self?.captcha?.id == requestID { self?.captcha = nil }
                        continuation.resume(returning: proof)
                    }
                }
            }
        }
    }

    var isLoggedIn: Bool { account != nil }

    /// 打开发布 / 回复编辑器（需要登录）。
    func compose(_ target: ComposeTarget, onFinish: ((Entity) -> Void)? = nil) {
        guard requireLogin() else { return }
        composeCompletion = onFinish
        composeTarget = target
    }

    // MARK: 账号

    /// 接收登录网页捕获的 Cookie，再向接口确认。
    func signIn(_ candidate: Account) async {
        client.account = candidate
        var confirmed = candidate
        do {
            let info = try await client.checkLogin()
            if let uid = info["uid"].text, uid != candidate.uid {
                throw APIError(.authentication, "登录信息不一致，请重试")
            }
            confirmed.avatar = info["userAvatar"].string ?? ""
        } catch let error as APIError where error.kind == .authentication {
            client.account = account
            showToast("登录失败：\(error.message)")
            return
        } catch {
            // 网络波动：保留网页登录结果，稍后再确认。
        }
        client.account = confirmed
        if candidate.uid != account?.uid { client.resetSession() }
        account = confirmed
        accounts.removeAll { $0.uid == confirmed.uid }
        accounts.insert(confirmed, at: 0)
        if persistAccounts() {
            showToast("已登录：\(confirmed.displayName)")
        } else {
            showToast("已登录，但无法写入钥匙串，下次启动需重新登录")
        }
        resetLists()
    }

    /// 切换到另一个已登录的账号。
    func switchAccount(to uid: String) {
        guard uid != account?.uid, let target = accounts.first(where: { $0.uid == uid }) else { return }
        account = target
        client.account = target
        client.resetSession()
        persistAccounts()
        resetLists()
        showToast("已切换到 \(target.displayName)")
    }

    /// 移除一个账号；移除的是当前账号时切到下一个，没有则回到游客。
    func removeAccount(uid: String) {
        accounts.removeAll { $0.uid == uid }
        if account?.uid == uid {
            account = accounts.first
            client.account = account
            client.resetSession()
            resetLists()
        }
        persistAccounts()
    }

    /// 退出当前账号。
    func signOut() {
        guard let current = account else { return }
        removeAccount(uid: current.uid)
        showToast(account.map { "已退出，当前账号：\($0.displayName)" } ?? "已退出登录")
    }

    @discardableResult
    private func persistAccounts() -> Bool {
        AccountStore.save(AccountStore.Snapshot(accounts: accounts, currentUID: account?.uid))
    }

    /// 已登录返回 true，否则弹出登录页。
    func requireLogin() -> Bool {
        if isLoggedIn { return true }
        isShowingLogin = true
        return false
    }

    // MARK: 设备参数与数盟标识

    var hasSzlmID: Bool { identity.hasSzlmID }

    var szlmNextAllowedAt: Date? {
        _ = szlmStateRevision
        return szlmService.nextAllowedAt
    }

    var szlmUnavailableReason: String? {
        _ = szlmStateRevision
        return szlmService.unavailableReason
    }

    func acquireSzlmID() async throws {
        _ = try await szlmService.renewNow()
        szlmStateRevision &+= 1
    }

    func importOfficialDeviceIdentity(_ text: String) throws {
        var next = identity
        try next.importOfficialDeviceIdentity(text)
        apply(next)
        client.resetSession()
        szlmStateRevision &+= 1
    }

    private func applySzlmID(_ id: String) throws {
        var next = identity
        try next.applySzlmID(id)
        apply(next)
        client.resetSession()
    }

    func regenerateDevice() {
        var next = identity
        next.regenerateDeviceCode()
        apply(next)
        client.resetSession()
        szlmStateRevision &+= 1
        showToast("已重新生成设备参数")
    }

    func updateIdentity(_ change: (inout ClientIdentity) -> Void) {
        var next = identity
        change(&next)
        next.refreshDeviceCode()
        apply(next)
    }

    private func apply(_ next: ClientIdentity) {
        identity = next
        client.identity = next
        UserDefaults.standard.set(try? JSONEncoder().encode(next), forKey: Self.identityKey)
    }

    // MARK: 共享状态

    func remember(_ entity: Entity) {
        let id = entity.entityID
        guard !id.isEmpty else { return }
        if previews.count > 400 { previews.removeAll() }
        previews[id] = entity
    }

    func preview(feed id: String) -> Entity? { previews[id] }

    /// 根列表在切换侧边栏时保留，按固定名称存取。
    func list(_ key: String, make: () -> PagedList) -> PagedList {
        if let existing = listModels[key] { return existing }
        let created = make()
        listModels[key] = created
        return created
    }

    func resetLists() {
        for model in listModels.values { model.reset() }
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        let toast = Toast(message: message)
        self.toast = toast
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled, self?.toast == toast else { return }
            self?.toast = nil
        }
    }

    func report(_ error: Error) {
        let failure = APIError.from(error)
        guard failure.kind != .cancelled else { return }
        if failure.kind == .authentication, !isLoggedIn {
            isShowingLogin = true
        }
        showToast(failure.message)
    }
}
