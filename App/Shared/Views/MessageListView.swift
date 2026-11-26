import CoolapkKit
import Observation
import SwiftUI

/// 私信的对方：打开聊天页所需的全部信息。
struct ChatPeer: Identifiable, Hashable {
    /// 会话标识，由双方 uid 组成。
    let ukey: String
    let uid: String
    let username: String
    var avatar = ""

    var id: String { ukey }

    init(ukey: String, uid: String, username: String, avatar: String = "") {
        self.ukey = ukey
        self.uid = uid
        self.username = username
        self.avatar = avatar
    }

    /// 从用户主页等入口发起私信：会话标识由自己和对方的 uid 推出。
    init?(uid: String, username: String, avatar: String = "", myUID: String) {
        guard uid != myUID, let ukey = CoolapkClient.chatKey(uid: myUID, with: uid) else { return nil }
        self.init(ukey: ukey, uid: uid, username: username, avatar: avatar)
    }
}

/// 会话列表里的一行：与某个用户的最近一条消息。
struct Conversation: Identifiable {
    let peer: ChatPeer
    /// 最近一条消息的纯文本。
    let preview: String
    let dateline: Int?
    var isPinned: Bool
    var unread: Int

    var id: String { peer.ukey }

    init?(_ entity: Entity, myUID: String) {
        guard entity.entityType == "message", let uid = entity["messageUid"].text else { return nil }
        guard let ukey = entity["ukey"].text ?? CoolapkClient.chatKey(uid: myUID, with: uid) else { return nil }
        peer = ChatPeer(
            ukey: ukey, uid: uid, username: entity["messageUsername"].string ?? "",
            avatar: entity["messageUserAvatar"].string ?? "")
        preview = RichText.plainText(entity.message).replacingOccurrences(of: "\n", with: " ")
        dateline = entity.dateline
        isPinned = (entity["is_top"].int ?? entity["isTop"].int) == 1
        unread = entity["unreadNum"].int ?? 0
    }
}

/// 分页加载私信会话，并处理置顶、删除。移植自上游的 `NotificationController`（私信部分）。
@MainActor
@Observable
final class ConversationList {
    enum Phase: Equatable {
        case idle, loading, loaded, empty
        case failed(APIError)
    }

    private(set) var items: [Conversation] = []
    private(set) var phase = Phase.idle
    private(set) var isLoadingMore = false
    private(set) var reachedEnd = false
    private(set) var moreError: APIError?
    /// 正在置顶或删除的会话。
    private(set) var busy = Set<String>()

    let myUID: String

    @ObservationIgnored private let client: CoolapkClient
    @ObservationIgnored private var page = 1
    @ObservationIgnored private var firstItem: String?
    @ObservationIgnored private var lastItem: String?
    @ObservationIgnored private var generation = 0

    init(client: CoolapkClient, myUID: String) {
        self.client = client
        self.myUID = myUID
    }

    func loadIfNeeded() {
        guard phase == .idle else { return }
        phase = .loading
        Task { await refresh() }
    }

    /// - Parameter interactive: 用户主动刷新时允许弹出人机验证。
    func refresh(interactive: Bool = false) async {
        generation += 1
        let current = generation
        isLoadingMore = false
        if items.isEmpty { phase = .loading }
        moreError = nil
        do {
            let result = try await fetch(page: 1, firstItem: nil, lastItem: nil, interactive: interactive)
            guard current == generation else { return }
            page = 1
            firstItem = result.firstItem
            lastItem = result.lastItem
            reachedEnd = result.items.contains { $0.entityTemplate == "noMoreDataCard" }
            items = sorted(result.items.compactMap { Conversation($0, myUID: myUID) })
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
                if items.isEmpty { phase = .idle }
                return
            }
            if items.isEmpty { phase = .failed(failure) } else { moreError = failure }
        }
    }

    func requestMore() {
        guard phase == .loaded, !isLoadingMore, !reachedEnd, moreError == nil else { return }
        Task { await loadMore() }
    }

    func loadMore(interactive: Bool = false) async {
        guard phase == .loaded, !isLoadingMore, !reachedEnd else { return }
        isLoadingMore = true
        moreError = nil
        let current = generation
        defer { if current == generation { isLoadingMore = false } }
        do {
            let result = try await fetch(page: page + 1, firstItem: firstItem, lastItem: lastItem, interactive: interactive)
            guard current == generation else { return }
            page += 1
            if let last = result.lastItem { lastItem = last }
            let fresh = result.items.compactMap { Conversation($0, myUID: myUID) }
            if fresh.isEmpty || result.items.contains(where: { $0.entityTemplate == "noMoreDataCard" }) {
                reachedEnd = true
            }
            items = sorted(items + fresh)
        } catch {
            guard current == generation else { return }
            let failure = APIError.from(error)
            if failure.kind != .cancelled { moreError = failure }
        }
    }

    private func fetch(page: Int, firstItem: String?, lastItem: String?, interactive: Bool) async throws -> EntityPage {
        if interactive {
            return try await CoolapkClient.interactive {
                try await client.messageList(page: page, firstItem: firstItem, lastItem: lastItem)
            }
        }
        return try await client.messageList(page: page, firstItem: firstItem, lastItem: lastItem)
    }

    /// 去重，置顶的排在前面，其余按最近消息时间倒序。
    private func sorted(_ list: [Conversation]) -> [Conversation] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.isPinned != rhs.element.isPinned { return lhs.element.isPinned }
                let left = lhs.element.dateline ?? 0, right = rhs.element.dateline ?? 0
                return left != right ? left > right : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 打开会话后，本地把未读数清零。
    func markRead(_ ukey: String) {
        guard let index = items.firstIndex(where: { $0.id == ukey }) else { return }
        items[index].unread = 0
    }

    /// 置顶或取消置顶；成功返回提示文字，失败抛出错误。
    func togglePin(_ conversation: Conversation) async throws -> String {
        let key = conversation.id
        guard busy.insert(key).inserted else { throw APIError(.cancelled, "操作进行中") }
        defer { busy.remove(key) }
        let shouldPin = !conversation.isPinned
        try await CoolapkClient.interactive { try await client.setConversationPinned(shouldPin, ukey: key) }
        if let index = items.firstIndex(where: { $0.id == key }) {
            items[index].isPinned = shouldPin
            items = sorted(items)
        }
        return shouldPin ? "已置顶会话" : "已取消置顶"
    }

    /// 从列表删除会话。
    func delete(_ conversation: Conversation) async throws {
        let key = conversation.id
        guard busy.insert(key).inserted else { throw APIError(.cancelled, "操作进行中") }
        defer { busy.remove(key) }
        try await CoolapkClient.interactive { try await client.deleteConversation(ukey: key) }
        items.removeAll { $0.id == key }
        if items.isEmpty, phase == .loaded { phase = .empty }
    }
}

/// 私信会话列表。点开一行进入 `ChatView`。
struct MessageListView: View {
    /// 打开会话的方式。不传时由本视图在所在的导航栈里自行推入 `ChatView`。
    var onOpenChat: ((ChatPeer) -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator
    @Environment(\.isActiveRoute) private var isActiveRoute
    @State private var model: ConversationList?
    @State private var openedChat = false
    @State private var pendingDelete: Conversation?

    var body: some View {
        Group {
            if !app.isLoggedIn {
                LoginRequiredView(message: "登录后可以查看和发送私信。")
            } else if let model {
                content(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .routeTitle("私信")
        .onChange(of: navigator.currentEntries.isEmpty) { _, isEmpty in
            // 从聊天页返回后悄悄刷新一次，更新最近消息和未读数。
            if isEmpty, navigator.selection == .messages, openedChat, let model {
                openedChat = false
                Task { await model.refresh() }
            }
        }
        .toolbar {
            if isActiveRoute, let model, app.isLoggedIn {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.refresh(interactive: true) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("刷新（⌘R）")
                }
            }
        }
        .task(id: app.account?.uid) {
            guard let uid = app.account?.uid else {
                model = nil
                return
            }
            // 从聊天页返回时沿用原来的列表；换了账号才重建。
            if model?.myUID != uid { model = ConversationList(client: app.client, myUID: uid) }
            model?.loadIfNeeded()
        }
        .confirmationDialog(
            "删除此会话？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { conversation in
            Button("删除", role: .destructive) { delete(conversation) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("会话将从私信列表中删除，此操作无法撤销。")
        }
    }

    @ViewBuilder
    private func content(_ model: ConversationList) -> some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView("还没有私信", systemImage: "bubble.left.and.bubble.right",
                                   description: Text("在用户主页可以发起私信。"))
        case .failed(let failure):
            ContentUnavailableView {
                Label("无法加载私信", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.message)
            } actions: {
                Button(failure.kind == .captcha ? "完成验证" : "重试") {
                    Task { await model.refresh(interactive: true) }
                }
                .buttonStyle(.glass)
            }
        case .loaded:
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.items) { conversation in
                        row(conversation, model: model)
                    }
                    footer(model)
                }
                .frame(maxWidth: 720)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    private func row(_ conversation: Conversation, model: ConversationList) -> some View {
        let isBusy = model.busy.contains(conversation.id)
        let zoomID = "chat-row-\(conversation.id)"
        return Button {
            open(conversation, model: model, zoomID: zoomID)
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: conversation.peer.avatar, size: 42)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(conversation.peer.username)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)
                        if conversation.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.brand)
                                .accessibilityLabel("置顶会话")
                        }
                        if isBusy { ProgressView().controlSize(.mini) }
                        Spacer(minLength: 8)
                        Text(Formatting.relative(conversation.dateline))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text(conversation.preview.isEmpty ? " " : conversation.preview)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if conversation.unread > 0 {
                            Text(conversation.unread > 99 ? "99+" : String(conversation.unread))
                                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.brandFill, in: Capsule())
                                .accessibilityLabel("\(conversation.unread) 条未读")
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(padding: 12, interactive: true)
        .zoomTransitionSource(id: zoomID)
        .disabled(isBusy)
        .contextMenu {
            Button(conversation.isPinned ? "取消置顶" : "置顶会话", systemImage: conversation.isPinned ? "pin.slash" : "pin") {
                togglePin(conversation, model: model)
            }
            Button("查看 \(conversation.peer.username) 的主页", systemImage: "person") {
                navigator.push(.user(conversation.peer.uid))
            }
            Divider()
            Button("删除会话", systemImage: "trash", role: .destructive) { pendingDelete = conversation }
        }
    }

    @ViewBuilder
    private func footer(_ model: ConversationList) -> some View {
        if let error = model.moreError {
            HStack(spacing: 10) {
                Text(error.message).font(.system(size: 12)).foregroundStyle(.secondary)
                Button("重试") { Task { await model.loadMore(interactive: true) } }.buttonStyle(.glass)
            }
            .padding(.vertical, 8)
        } else if model.isLoadingMore {
            ProgressView().controlSize(.small).padding(.vertical, 8)
        } else if !model.reachedEnd {
            // 滚到这里时自动加载下一页。
            Color.clear.frame(height: 1).onAppear { model.requestMore() }
        }
    }

    private func open(_ conversation: Conversation, model: ConversationList, zoomID: String) {
        model.markRead(conversation.id)
        if let onOpenChat {
            onOpenChat(conversation.peer)
        } else {
            openedChat = true
            navigator.push(.chat(conversation.peer), zoomID: zoomID)
        }
    }

    private func togglePin(_ conversation: Conversation, model: ConversationList) {
        Task {
            do {
                app.showToast(try await model.togglePin(conversation))
            } catch {
                app.report(error)
            }
        }
    }

    private func delete(_ conversation: Conversation) {
        guard let model else { return }
        Task {
            do {
                try await model.delete(conversation)
                app.showToast("已删除会话")
            } catch {
                app.report(error)
            }
        }
    }
}
