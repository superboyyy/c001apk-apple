import CoolapkKit
import Observation
import SwiftUI

/// 本机发出、尚在发送或发送失败的一条私信。对应上游的 `ChatDelivery`。
struct ChatDelivery: Identifiable {
    enum State {
        case sending, sent, failed
    }

    let id = UUID()
    let text: String
    let image: PickedImage?
    /// 图片已经传完时的引用；重试时不再重复上传。
    var uploadedPicture: String?
    var state = State.sending
    var error: String?
    /// 请求已经发出但没有拿到明确结果：消息可能已经送达，重发会重复。
    var unconfirmed = false
    /// 服务端返回的消息记录。
    var acknowledged: Entity?
}

/// 聊天页里的一行。
struct ChatRow: Identifiable {
    enum Content {
        /// 时间分隔。
        case time(String)
        /// 历史消息。
        case message(Entity)
        /// 本机发出的消息。
        case delivery(ChatDelivery)
        case unsupported
    }

    let id: String
    let content: Content
}

/// 一个会话的聊天记录与发送队列。移植自上游的 `ChatController`。
@MainActor
@Observable
final class ChatModel {
    enum Phase: Equatable {
        case loading, loaded
        case failed(APIError)
    }

    let peer: ChatPeer
    let myUID: String

    /// 历史记录，按时间从旧到新。
    private(set) var history: [Entity] = []
    /// 本次打开后发出的消息，按发送顺序。
    private(set) var deliveries: [ChatDelivery] = []
    private(set) var phase = Phase.loading
    private(set) var isLoadingOlder = false
    private(set) var reachedStart = false
    private(set) var olderError: APIError?
    /// 消息编号 → 已解析出的图片地址。
    private(set) var imageURLs: [String: String] = [:]
    private(set) var failedImages = Set<String>()

    @ObservationIgnored private let client: CoolapkClient
    @ObservationIgnored private var page = 1
    @ObservationIgnored private var firstItem: String?
    @ObservationIgnored private var lastItem: String?
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var resolving = Set<String>()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var started = false

    init(peer: ChatPeer, myUID: String, client: CoolapkClient) {
        self.peer = peer
        self.myUID = myUID
        self.client = client
    }

    /// 开始首次加载。任务归模型所有，页面被别的页面盖住时不会被取消。
    func start() {
        guard !started else { return }
        started = true
        Task { await load() }
    }

    /// 历史在前、本机发出的在后；已被确认的消息不重复显示。
    var rows: [ChatRow] {
        let delivered = Set(deliveries.compactMap { $0.acknowledged?.entityID })
        var rows: [ChatRow] = history.compactMap { entity in
            switch entity.entityType {
            case "messageExtra":
                return ChatRow(id: "x-\(entity.id.uuidString)", content: .time(entity.title))
            case "message":
                guard !delivered.contains(entity.entityID) else { return nil }
                return ChatRow(id: "m-\(entity.entityID)", content: .message(entity))
            default:
                return ChatRow(id: "u-\(entity.id.uuidString)", content: .unsupported)
            }
        }
        rows += deliveries.map { ChatRow(id: "local-\($0.id.uuidString)", content: .delivery($0)) }
        return rows
    }

    // MARK: 历史

    func load(interactive: Bool = false) async {
        generation += 1
        let current = generation
        if history.isEmpty { phase = .loading }
        olderError = nil
        do {
            let result = try await fetch(page: 1, firstItem: nil, lastItem: nil, interactive: interactive)
            guard current == generation else { return }
            seen.removeAll()
            page = 1
            firstItem = result.firstItem
            lastItem = result.lastItem
            reachedStart = false
            history = accept(result.items)
            if result.items.isEmpty { reachedStart = true }
            phase = .loaded
        } catch {
            guard current == generation else { return }
            let failure = APIError.from(error)
            if history.isEmpty { phase = .failed(failure) } else { olderError = failure }
        }
    }

    /// 向上翻：加载更早的一页，接在现有记录之前。
    func loadOlder(interactive: Bool = false) async {
        guard phase == .loaded, !isLoadingOlder, !reachedStart else { return }
        isLoadingOlder = true
        olderError = nil
        let current = generation
        defer { if current == generation { isLoadingOlder = false } }
        do {
            let result = try await fetch(page: page + 1, firstItem: firstItem, lastItem: lastItem, interactive: interactive)
            guard current == generation else { return }
            page += 1
            if let last = result.lastItem { lastItem = last }
            let older = accept(result.items)
            if result.items.isEmpty { reachedStart = true }
            history.insert(contentsOf: older, at: 0)
        } catch {
            guard current == generation else { return }
            let failure = APIError.from(error)
            if failure.kind != .cancelled { olderError = failure }
        }
    }

    private func fetch(page: Int, firstItem: String?, lastItem: String?, interactive: Bool) async throws -> EntityPage {
        let ukey = peer.ukey
        if interactive {
            return try await CoolapkClient.interactive {
                try await client.chatHistory(ukey: ukey, page: page, firstItem: firstItem, lastItem: lastItem)
            }
        }
        return try await client.chatHistory(ukey: ukey, page: page, firstItem: firstItem, lastItem: lastItem)
    }

    /// 去掉结束标记和重复的消息。
    private func accept(_ incoming: [Entity]) -> [Entity] {
        incoming.filter { entity in
            if entity.entityTemplate == "noMoreDataCard" {
                reachedStart = true
                return false
            }
            guard entity.entityType == "message" else { return true }
            return seen.insert(entity.entityID).inserted
        }
    }

    // MARK: 图片

    /// 历史消息里的图片只给出相对路径，真实地址要另外向接口换取。
    func resolveImage(id: String, retry: Bool = false) async {
        if retry {
            resolving.remove(id)
            failedImages.remove(id)
        }
        guard imageURLs[id] == nil, resolving.insert(id).inserted else { return }
        if let url = try? await client.messageImageURL(id: id) {
            imageURLs[id] = url.absoluteString
        } else {
            failedImages.insert(id)
        }
    }

    // MARK: 发送

    func send(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        enqueue(ChatDelivery(text: text, image: nil))
    }

    func send(image: PickedImage) {
        enqueue(ChatDelivery(text: "", image: image))
    }

    private func enqueue(_ delivery: ChatDelivery) {
        deliveries.append(delivery)
        Task { await deliver(delivery.id) }
    }

    func retry(_ id: UUID) {
        guard let index = deliveries.firstIndex(where: { $0.id == id }), deliveries[index].state == .failed else { return }
        deliveries[index].state = .sending
        deliveries[index].error = nil
        Task { await deliver(id) }
    }

    /// 移除一条没有发出去的消息（发送中的不能移除）。
    func discard(_ id: UUID) {
        deliveries.removeAll { $0.id == id && $0.state != .sending }
    }

    private func update(_ id: UUID, _ change: (inout ChatDelivery) -> Void) {
        guard let index = deliveries.firstIndex(where: { $0.id == id }) else { return }
        change(&deliveries[index])
    }

    private func deliver(_ id: UUID) async {
        guard let delivery = deliveries.first(where: { $0.id == id }) else { return }
        let uid = peer.uid
        var requestStarted = false
        do {
            var picture = delivery.uploadedPicture
            if let image = delivery.image, picture == nil {
                picture = try await CoolapkClient.interactive {
                    try await client.uploadImages([image.upload], scope: .message(toUID: uid)).first
                }
                update(id) { $0.uploadedPicture = picture }
            }
            requestStarted = true
            let sent = try await CoolapkClient.interactive {
                try await client.sendMessage(uid: uid, message: delivery.text, pic: picture ?? "")
            }
            update(id) {
                $0.acknowledged = sent
                $0.state = .sent
            }
        } catch {
            let failure = APIError.from(error)
            update(id) {
                $0.error = failure.message
                // 请求发出后才失败的，结果不确定。
                $0.unconfirmed = requestStarted
                    && [.transport, .http, .invalidResponse, .parsing].contains(failure.kind)
                $0.state = .failed
            }
        }
    }

    // MARK: 删除

    func delete(messageID: String) async throws {
        let ukey = peer.ukey
        try await CoolapkClient.interactive { try await client.deleteMessage(ukey: ukey, id: messageID) }
        history.removeAll { $0.entityType == "message" && $0.entityID == messageID }
        deliveries.removeAll { $0.acknowledged?.entityID == messageID }
    }
}

/// 与一个用户的私信聊天页：消息气泡、时间分隔、向上翻历史、发送文字与图片。
struct ChatView: View {
    let peer: ChatPeer

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    @State private var model: ChatModel?
    @State private var draft = ""
    @State private var selection: TextSelection?
    @State private var showsEmoji = false
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var inspected: UUID?
    @State private var pendingDelete: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        Group {
            if !app.isLoggedIn {
                LoginRequiredView(message: "登录后可以查看和发送私信。")
            } else if let model {
                conversation(model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(peer.username.isEmpty ? "私信" : peer.username)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("查看用户", systemImage: "person") { navigator.push(.user(peer.uid)) }
                    Button("重新加载聊天记录", systemImage: "arrow.clockwise") {
                        Task { await model?.load(interactive: true) }
                    }
                    Divider()
                    Button("屏蔽 \(peer.username)（仅本机）", systemImage: "hand.raised") {
                        app.library.block(uid: peer.uid, username: peer.username)
                        app.showToast("已在本机屏蔽 \(peer.username)")
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis")
                }
            }
        }
        .task(id: app.account?.uid) {
            guard let uid = app.account?.uid else {
                model = nil
                return
            }
            // 从别的页面返回时沿用原来的模型，保留发送队列和已加载的记录。
            if model?.myUID != uid { model = ChatModel(peer: peer, myUID: uid, client: app.client) }
            model?.start()
        }
    }

    // MARK: 消息列表

    @ViewBuilder
    private func conversation(_ model: ChatModel) -> some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let failure) where model.deliveries.isEmpty:
                ContentUnavailableView {
                    Label("无法加载聊天记录", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure.message)
                } actions: {
                    Button(failure.kind == .captcha ? "完成验证" : "重新加载聊天记录") {
                        Task { await model.load(interactive: true) }
                    }
                    .buttonStyle(.glass)
                }
            default:
                messageList(model)
            }
        }
        .safeAreaBar(edge: .bottom) { inputBar(model) }
        .alert(
            failureTitle(model), isPresented: Binding(get: { inspected != nil }, set: { if !$0 { inspected = nil } }),
            presenting: inspected.flatMap { id in model.deliveries.first { $0.id == id } }
        ) { delivery in
            Button("重新发送") { model.retry(delivery.id) }
            Button("移除此条", role: .destructive) { model.discard(delivery.id) }
            Button("取消", role: .cancel) {}
        } message: { delivery in
            Text((delivery.error ?? "请稍后重试")
                + (delivery.unconfirmed ? "\n请先检查聊天记录，再次发送可能产生重复消息。" : ""))
        }
        .confirmationDialog(
            "删除消息？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { id in
            Button("删除", role: .destructive) { delete(id, model: model) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("删除后无法恢复。")
        }
    }

    private func failureTitle(_ model: ChatModel) -> String {
        let unconfirmed = inspected.flatMap { id in model.deliveries.first { $0.id == id } }?.unconfirmed ?? false
        return unconfirmed ? "发送结果未确认" : "消息发送失败"
    }

    private func messageList(_ model: ChatModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                olderHeader(model)
                ForEach(model.rows) { row in
                    rowView(row, model: model)
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
        // 以底部为锚点：初次显示停在最新消息；往上接入更早的记录时，眼前的内容不跳动。
        .defaultScrollAnchor(.bottom)
        .scrollPosition($position)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollDismissesKeyboard(.interactively)
        // 滚到接近顶部时自动加载更早的一页；只在“进入顶部区域”的那一刻触发一次。
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top < 80
                && geometry.contentSize.height > geometry.containerSize.height
        } action: { _, nearTop in
            if nearTop { Task { await model.loadOlder() } }
        }
        .onChange(of: model.deliveries.count) { old, new in
            guard new > old else { return }
            withAnimation(.smooth(duration: 0.2)) { position.scrollTo(edge: .bottom) }
        }
    }

    @ViewBuilder
    private func olderHeader(_ model: ChatModel) -> some View {
        if let error = model.olderError {
            HStack(spacing: 10) {
                Text(error.message).font(.system(size: 12)).foregroundStyle(.secondary)
                Button("重试") { Task { await model.loadOlder(interactive: true) } }.buttonStyle(.glass)
            }
        } else if model.isLoadingOlder {
            ProgressView().controlSize(.small)
        } else if model.reachedStart {
            Text(model.rows.isEmpty ? "还没有聊天记录，发一条消息开始吧" : "没有更早的消息了")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
        } else if model.phase == .loaded {
            Button("加载更早的消息") { Task { await model.loadOlder(interactive: true) } }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow, model: ChatModel) -> some View {
        switch row.content {
        case .time(let text):
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .unsupported:
            Text("暂不支持此消息类型")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        case .message(let entity):
            ChatBubble(
                message: .init(entity: entity, myUID: model.myUID, fallbackAvatar: avatar(for: entity, model: model)),
                resolvedPicture: model.imageURLs[entity.entityID],
                pictureFailed: model.failedImages.contains(entity.entityID),
                onResolvePicture: { retry in Task { await model.resolveImage(id: entity.entityID, retry: retry) } },
                onDelete: { pendingDelete = entity.entityID })
        case .delivery(let delivery):
            ChatBubble(
                message: .init(delivery: delivery, myUID: model.myUID, avatar: app.account?.avatar ?? ""),
                resolvedPicture: delivery.acknowledged.flatMap { model.imageURLs[$0.entityID] },
                pictureFailed: delivery.acknowledged.map { model.failedImages.contains($0.entityID) } ?? false,
                onResolvePicture: { retry in
                    guard let id = delivery.acknowledged?.entityID else { return }
                    Task { await model.resolveImage(id: id, retry: retry) }
                },
                onDelete: delivery.acknowledged.map { sent in { pendingDelete = sent.entityID } },
                onInspectFailure: { inspected = delivery.id })
        }
    }

    /// 历史消息没带头像时，按发送方补上已知的头像。
    private func avatar(for entity: Entity, model: ChatModel) -> String {
        entity["fromuid"].string == model.myUID ? (app.account?.avatar ?? "") : peer.avatar
    }

    // MARK: 输入栏

    private func inputBar(_ model: ChatModel) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 6) {
                Toggle(isOn: $showsEmoji) {
                    Image(systemName: "face.smiling")
                }
                .toggleStyle(.button)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("表情")
                .accessibilityLabel("表情")

                ImagePickerMenu(limit: 1) { picked in
                    if let image = picked.first { model.send(image: image) }
                } onFailure: { message in
                    app.showToast(message)
                } label: {
                    Image(systemName: "photo")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("发送图片")
                .accessibilityLabel("发送图片")

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("写私信…", text: $draft, selection: $selection, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused($inputFocused)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .onSubmit { send(model) }
                    Button {
                        send(model)
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .keyActionButtonStyle()
                    .buttonBorderShape(.circle)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .padding(.trailing, 5)
                    .padding(.bottom, 4)
                    .help("发送")
                    .accessibilityLabel("发送")
                }
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
            if showsEmoji {
                EmojiPanel { emoji in
                    TextInsertion.insert(emoji, into: &draft, selection: &selection)
                }
                .frame(height: 220)
                .card(padding: 6)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 6)
        .animation(.smooth(duration: 0.2), value: showsEmoji)
    }

    private func send(_ model: ChatModel) {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.send(text: text)
        draft = ""
        selection = nil
        inputFocused = true
    }

    private func delete(_ id: String, model: ChatModel) {
        Task {
            do {
                try await model.delete(messageID: id)
                app.showToast("已删除消息")
            } catch {
                app.report(error)
            }
        }
    }
}

/// 一条消息的气泡：对方的靠左，自己的靠右。移植自上游的 `ChatCard`。
private struct ChatBubble: View {
    /// 气泡要显示的内容，历史消息和本机发出的消息都归一成这个形状。
    struct Message {
        var html: String
        var picture: String
        var localImage: CGImage?
        var isMine: Bool
        var senderUID: String
        var avatar: String
        var extraTitle: String
        var extraURL: String
        var isSending = false
        var isFailed = false

        init(entity: Entity, myUID: String, fallbackAvatar: String) {
            html = entity.message
            picture = entity["message_pic"].string ?? ""
            senderUID = entity["fromuid"].string ?? ""
            isMine = senderUID == myUID
            avatar = entity["fromUserAvatar"].text ?? fallbackAvatar
            extraTitle = entity.extraTitle
            extraURL = entity.extraURL
        }

        init(delivery: ChatDelivery, myUID: String, avatar: String) {
            let sent = delivery.acknowledged
            html = sent?.message.isEmpty == false ? sent!.message : RichText.escape(delivery.text)
            picture = sent?["message_pic"].text ?? delivery.uploadedPicture ?? ""
            // 确认送达之前显示本地图片。
            localImage = delivery.state == .sent ? nil : delivery.image?.thumbnail
            isMine = true
            senderUID = myUID
            self.avatar = sent?["fromUserAvatar"].text ?? avatar
            extraTitle = sent?.extraTitle ?? ""
            extraURL = sent?.extraURL ?? ""
            isSending = delivery.state == .sending
            isFailed = delivery.state == .failed
        }
    }

    let message: Message
    var resolvedPicture: String?
    var pictureFailed = false
    var onResolvePicture: (_ retry: Bool) -> Void = { _ in }
    var onDelete: (() -> Void)?
    var onInspectFailure: () -> Void = {}

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    private var plainText: String {
        RichText.plainText(message.html).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 整条消息就是一个动态链接时，显示成卡片。
    private var feedID: String? {
        let text = plainText
        guard text.range(of: #"^https://www\.coolapk\.com/feed/[0-9]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return text.split(separator: "/").last.map(String.init)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.isMine {
                Spacer(minLength: 56)
                status
            } else {
                avatarButton
            }
            VStack(alignment: message.isMine ? .trailing : .leading, spacing: 6) {
                if !message.html.isEmpty { textBubble }
                if let local = message.localImage {
                    Image(decorative: local, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 220, maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .opacity(message.isSending ? 0.6 : 1)
                        .accessibilityLabel("待发送的图片")
                } else if !message.picture.isEmpty {
                    pictureView
                }
                if !message.extraURL.isEmpty { extraCard }
            }
            if message.isMine {
                avatarButton
            } else {
                Spacer(minLength: 56)
            }
        }
        .contextMenu {
            if !message.isSending, !message.isFailed {
                if !plainText.isEmpty {
                    Button("拷贝", systemImage: "doc.on.doc") { Platform.copy(plainText) }
                }
                if let onDelete {
                    Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                }
            }
        }
    }

    private var avatarButton: some View {
        Button {
            if !message.senderUID.isEmpty { navigator.push(.user(message.senderUID)) }
        } label: {
            AvatarView(url: message.avatar, size: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(message.isMine ? "我的主页" : "对方的主页")
    }

    @ViewBuilder
    private var status: some View {
        if message.isSending {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 9)
                .accessibilityLabel("消息发送中")
        } else if message.isFailed {
            Button(action: onInspectFailure) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .padding(.top, 9)
            .help("发送失败，点击查看")
            .accessibilityLabel("发送失败，点击查看")
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: message.isMine ? 16 : 5, bottomLeadingRadius: 16,
            bottomTrailingRadius: 16, topTrailingRadius: message.isMine ? 5 : 16, style: .continuous)
    }

    @ViewBuilder
    private var textBubble: some View {
        let size = app.settings.fontSize
        Group {
            if let feedID {
                Button {
                    navigator.push(.feed(id: feedID))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("动态 \(feedID)").font(.system(size: size))
                            Text("点击查看").font(.system(size: size - 2)).opacity(0.7)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                RichText.text(
                    RichText.parse(message.html, emoji: app.settings.showEmoji), fontSize: size,
                    tint: message.isMine ? .white : .brand)
                    .lineSpacing(size * 0.28)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(message.isMine ? Color.white : Color.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(message.isMine ? .regular.tint(.brandFill) : .regular, in: bubbleShape)
    }

    @ViewBuilder
    private var pictureView: some View {
        let address = message.picture.hasPrefix("http") ? message.picture : resolvedPicture
        let pixels = ImageURL.pixelSize(message.picture.split(separator: "?").first.map(String.init) ?? "")
            ?? CGSize(width: 4, height: 3)
        let width: CGFloat = 200
        let height = min(max(width * pixels.height / pixels.width, 60), 320)
        Group {
            if let address {
                Button {
                    openPicture(address)
                } label: {
                    RemoteImage(address, maxPixel: 800, contentMode: .fill)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("图片，点击查看")
            } else {
                // 地址尚未解析：出现时自动换取，失败后点击重试。
                Button {
                    onResolvePicture(true)
                } label: {
                    Rectangle().fill(.quaternary).overlay {
                        if pictureFailed {
                            Label("加载图片", systemImage: "arrow.clockwise").font(.system(size: 12))
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .buttonStyle(.plain)
                .onAppear { onResolvePicture(false) }
                .accessibilityLabel("加载图片")
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }

    private var extraCard: some View {
        Button {
            navigator.open(message.extraURL, title: message.extraTitle, app: app)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "doc.text")
                Text(message.extraTitle.isEmpty ? "分享的内容" : message.extraTitle)
                    .font(.system(size: 12.5))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text("点击查看").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 240, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .card(padding: 10, interactive: true)
        .frame(maxWidth: 260)
    }

    private func openPicture(_ address: String) {
        ImageViewer.show(urls: [address], index: 0)
    }
}
