import CoolapkKit
import SwiftUI

/// 动态 / 图文的完整内容及其评论。
struct FeedDetailView: View {
    let id: String

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    @State private var entity: Entity?
    @State private var failure: APIError?
    @State private var isLoading = false
    @State private var isComplete = false
    @State private var sort: CoolapkClient.ReplySort = .latestActivity
    @State private var authorOnly = false
    @State private var replies: PagedList?
    @State private var loadedReplyKey: ReplyKey?
    @State private var loadedID: String?
    @State private var thread: Entity?
    @State private var replyTarget: Entity?
    @State private var draft = ""
    @State private var isSending = false
    @State private var isShowingDeviceIdentity = false
    @FocusState private var composerFocused: Bool
    @State private var width: CGFloat

    init(
        id: String,
        initialEntity: Entity? = nil,
        initialWidth: CGFloat = 0,
        client: CoolapkClient? = nil
    ) {
        self.id = id
        // 第 0 帧直接带入列表摘要、评论模型与当前容器宽度，避免闪现空白转圈或首帧分栏跳变。
        _entity = State(initialValue: initialEntity)
        _width = State(initialValue: initialWidth > 100 ? initialWidth.rounded() : 900)
        if let client {
            let defaultSort = CoolapkClient.ReplySort.latestActivity
            _replies = State(initialValue: PagedList { request in
                try await client.feedReplies(id: id, sort: defaultSort, fromAuthor: false, page: request.page,
                                             firstItem: request.firstItem, lastItem: request.lastItem)
            })
            _loadedReplyKey = State(initialValue: ReplyKey(sort: defaultSort, authorOnly: false))
        }
    }

    /// 宽窗口左边看正文、右边看评论；窄窗口则叠成一列。
    private var isSplit: Bool { width >= 900 && entity != nil }

    /// 拖动分隔条设定的评论栏宽度；0 表示自动。
    @AppStorage("commentsPaneWidth") private var storedCommentsWidth = 0.0
    @State private var dragStartWidth: CGFloat?
    @State private var isHoveringDivider = false

    private func clampedCommentsWidth(_ proposed: CGFloat) -> CGFloat {
        min(max(proposed, 300), max(width - 420, 300))
    }

    private var commentsWidth: CGFloat {
        clampedCommentsWidth(storedCommentsWidth > 0 ? storedCommentsWidth : min(max(width * 0.38, 360), 480))
    }

    /// 拖动调整两栏宽度，双击恢复自动分栏。
    private var paneDivider: some View {
        ZStack {
            Rectangle().fill(.separator).frame(width: 1)
            Capsule()
                .fill(.clear)
                .frame(width: 6, height: 44)
                .glassEffect(.regular.interactive(), in: .capsule)
                .opacity(isHoveringDivider || dragStartWidth != nil ? 1 : 0.55)
        }
        .frame(width: 13)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .columnResizePointer()
        .onHover { isHoveringDivider = $0 }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? commentsWidth
                    dragStartWidth = start
                    storedCommentsWidth = clampedCommentsWidth(start - value.translation.width)
                }
                .onEnded { _ in dragStartWidth = nil }
        )
        .onTapGesture(count: 2) { storedCommentsWidth = 0 }
        .help("拖动调整正文与评论的宽度，双击恢复默认")
        .accessibilityElement()
        .accessibilityLabel("分栏宽度")
        .accessibilityValue("评论栏 \(Int(commentsWidth)) 点")
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = direction == .increment ? 40 : -40
            storedCommentsWidth = clampedCommentsWidth(commentsWidth + step)
        }
    }

    private struct ReplyKey: Hashable {
        let sort: CoolapkClient.ReplySort
        let authorOnly: Bool
    }

    var body: some View {
        Group {
            if let replies {
                if isSplit, let entity {
                    HStack(spacing: 0) {
                        ScrollView {
                            postCard(entity)
                                .frame(maxWidth: 820)
                                .padding(16)
                                .frame(maxWidth: .infinity)
                        }
                        .scrollEdgeEffectStyle(.soft, for: .top)
                        paneDivider
                        commentList(replies, maxWidth: .infinity) {
                            repliesHeader(entity)
                            if let error = repliesNeedAccess { lockedReplies(entity, error) }
                        }
                        .safeAreaBar(edge: .bottom) { composer }
                        .frame(width: commentsWidth)
                    }
                } else {
                    commentList(replies, maxWidth: 760) { header }
                        .safeAreaBar(edge: .bottom) { composer }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { newWidth in
            if abs(newWidth - width) >= 1 { width = newWidth }
        }
        .routeTitle(entity.map { $0.messageTitle.isEmpty ? "\($0.username) 的动态" : $0.messageTitle } ?? "动态")
        .modifier(FeedDetailToolbar(id: id, entity: entity) {
            Task {
                await load(interactive: true)
                await replies?.refresh(interactive: true)
            }
        })
        .sheet(item: $thread) { root in
            ReplyThreadSheet(root: root) { startReply(to: $0) }
        }
        .sheet(isPresented: $isShowingDeviceIdentity) {
            DeviceIdentitySheet {
                Task {
                    await load(interactive: false)
                    await replies?.refresh(interactive: false)
                }
            }
        }
        .task(id: ReplyKey(sort: sort, authorOnly: authorOnly)) {
            let key = ReplyKey(sort: sort, authorOnly: authorOnly)
            // 从评论者主页或引用帖返回时，保留当前评论列表与滚动位置。
            guard loadedReplyKey != key || replies == nil else { return }
            loadedReplyKey = key
            let client = app.client
            let feedID = id
            let sort = sort
            let authorOnly = authorOnly
            replies = PagedList { request in
                try await client.feedReplies(id: feedID, sort: sort, fromAuthor: authorOnly, page: request.page,
                                             firstItem: request.firstItem, lastItem: request.lastItem)
            }
        }
        .task(id: id) {
            if entity == nil { entity = app.preview(feed: id) }
            guard loadedID != id || entity == nil else { return }
            await load(interactive: false)
        }
        .onChange(of: replies?.phase) { _, phase in
            // 验证后评论能加载，说明动态本身也能加载了。
            if phase == .loaded, !isComplete, !isLoading { Task { await load(interactive: false) } }
        }
    }

    private func commentList<Header: View>(
        _ replies: PagedList, maxWidth: CGFloat, @ViewBuilder header: @escaping () -> Header
    ) -> some View {
        EntityListView(model: replies, layout: .single(maxWidth: maxWidth), showsRefreshButton: false,
                       hidesContent: entity == nil || repliesNeedAccess != nil, header: header)
            .id(ReplyKey(sort: sort, authorOnly: authorOnly))
            .environment(\.replyStyle, .inFeed)
            .environment(\.replyAction, EntityAction { startReply(to: $0) })
            .environment(\.showThread, EntityAction { thread = $0 })
    }

    /// 评论列表要等游客验证或登录后才能查看时有值。
    private var repliesNeedAccess: APIError? {
        guard case .failed(let error)? = replies?.phase,
              error.kind == .captcha || error.kind == .authentication else { return nil }
        return error
    }

    // MARK: 加载

    private func load(interactive: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded: Entity
            if interactive {
                loaded = try await CoolapkClient.interactive { try await app.client.feedDetail(id: id) }
            } else {
                loaded = try await app.client.feedDetail(id: id)
            }
            entity = loaded
            loadedID = id
            failure = nil
            isComplete = !loaded.isPublicCopy
            if app.settings.recordHistory { app.library.recordHistory(loaded) }
            if interactive, replies?.phase != .loaded { await replies?.refresh() }
        } catch {
            let apiError = APIError.from(error)
            if apiError.kind != .cancelled { failure = apiError }
        }
    }

    // MARK: 头部

    private func postCard(_ entity: Entity) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let failure { partialNotice(failure) }
            FeedBodyView(entity: entity, isComplete: isComplete)
            actionRow(entity)
        }
        .card(padding: 20)
    }

    /// 单栏布局：先是正文，然后是评论控件。
    @ViewBuilder
    private var header: some View {
        if let entity {
            postCard(entity)
            repliesHeader(entity)
            if let error = repliesNeedAccess { lockedReplies(entity, error) }
        } else if let failure {
            FailureView(error: failure) { interactive in
                Task { await load(interactive: interactive) }
            }
            .frame(minHeight: 280)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    /// 游客能看到公开网页附带的热门评论，以及解锁完整列表的入口。
    @ViewBuilder
    private func lockedReplies(_ entity: Entity, _ error: APIError) -> some View {
        let hot = entity.hotReplyRows.isEmpty ? entity.replyRows : entity.hotReplyRows
        VStack(alignment: .leading, spacing: 8) {
            Label(hot.isEmpty ? "查看评论需要完成人机验证或登录" : "以下是公开的热门评论，查看全部评论需要完成人机验证或登录",
                  systemImage: "checkmark.shield")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("完成验证") {
                    Task { await replies?.refresh(interactive: true) }
                }
                .keyActionButtonStyle()
                if error.kind == .captcha {
                    Button("设备标识") { isShowingDeviceIdentity = true }.buttonStyle(.glass)
                }
                if !app.isLoggedIn {
                    Button("登录") { app.isShowingLogin = true }.buttonStyle(.glass)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        ForEach(hot) { reply in
            ReplyCard(entity: reply)
        }
    }

    private func partialNotice(_ failure: APIError) -> some View {
        HStack(spacing: 10) {
            Image(systemName: failure.kind == .captcha ? "checkmark.shield" : "exclamationmark.triangle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("当前显示的是列表中的摘要").font(.system(size: 12, weight: .semibold))
                Text(failure.message).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if failure.kind == .authentication, !app.isLoggedIn {
                Button("登录") { app.isShowingLogin = true }.buttonStyle(.glass)
            }
            if failure.kind == .captcha {
                Button("设备标识") { isShowingDeviceIdentity = true }.buttonStyle(.glass)
            }
            Button(failure.kind == .captcha ? "完成验证" : "重试") {
                Task { await load(interactive: true) }
            }
            .buttonStyle(.glass)
            .disabled(isLoading)
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func actionRow(_ entity: Entity) -> some View {
        HStack(spacing: 10) {
            LikeButton(entity: entity)
            Button {
                composerFocused = true
            } label: {
                Label(Formatting.count(entity.replyCount), systemImage: "bubble.left")
            }
            .buttonStyle(.glass)
            Button {
                app.library.toggleFavorite(entity)
            } label: {
                let saved = app.library.isFavorite(id)
                Label(saved ? "已收藏" : "收藏", systemImage: saved ? "star.fill" : "star")
            }
            .buttonStyle(.glass)
            Spacer()
            if let url = URL(string: "https://www.coolapk.com/feed/\(id)") {
                ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.glass)
            }
        }
        .controlSize(.large)
    }

    private func repliesHeader(_ entity: Entity) -> some View {
        HStack(spacing: 10) {
            Text("评论 \(Formatting.count(entity.replyCount))")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Toggle("只看楼主", isOn: $authorOnly)
                .toggleStyle(.button)
                .buttonStyle(.glass)
                .controlSize(.small)
            Picker("排序", selection: $sort) {
                ForEach(CoolapkClient.ReplySort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }

    // MARK: 输入框

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let replyTarget {
                HStack(spacing: 6) {
                    Text("回复 @\(replyTarget.username)")
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                    Button {
                        self.replyTarget = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("取消回复对象")
                }
                .padding(.leading, 14)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    openFullComposer()
                } label: {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .padding(.bottom, 3)
                .help("带图片或表情回复")
                .accessibilityLabel("带图片或表情回复")
                TextField(app.isLoggedIn ? "写评论…" : "登录后可以评论", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 9)
                    .onSubmit(send)
                Button(action: send) {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .keyActionButtonStyle()
                .buttonBorderShape(.circle)
                .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.trailing, 5)
                .padding(.bottom, 4)
                .help("发送")
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 6)
    }

    /// 打开完整编辑器（图片、表情）；对象与快捷输入栏一致。
    private func openFullComposer() {
        let target = replyTarget
        let composeTarget: ComposeTarget = target.map {
            .reply(id: $0.entityID, type: .reply, username: $0.username)
        } ?? .reply(id: id, type: .feed, username: entity?.username ?? "")
        app.compose(composeTarget) { created in
            replyTarget = nil
            if target == nil, created.entityType == "feed_reply" {
                replies?.insertAtTop(created)
            } else {
                Task { await replies?.refresh() }
            }
        }
    }

    private func startReply(to reply: Entity) {
        replyTarget = reply
        composerFocused = true
    }

    private func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isSending, app.requireLogin() else { return }
        let target = replyTarget
        isSending = true
        Task {
            defer { isSending = false }
            do {
                let created = try await CoolapkClient.interactive {
                    try await app.client.postReply(
                        id: target?.entityID ?? id, type: target == nil ? "feed" : "reply", message: message)
                }
                draft = ""
                replyTarget = nil
                app.showToast("已发送")
                if target == nil, created.entityType == "feed_reply" {
                    replies?.insertAtTop(created)
                } else {
                    await replies?.refresh()
                }
            } catch {
                app.report(error)
            }
        }
    }
}

/// 详情页工具栏独立隔离 `isActiveRoute`，避免进出下级页面时触发整页正文与评论重算。
private struct FeedDetailToolbar: ViewModifier {
    let id: String
    let entity: Entity?
    let onRefresh: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.isActiveRoute) private var isActiveRoute

    func body(content: Content) -> some View {
        content.toolbar {
            if isActiveRoute {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onRefresh) {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("刷新（⌘R）")
                }
                if let entity {
                    ToolbarItem(placement: .primaryAction) {
                        FeedExportButton(feed: entity)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("在浏览器中打开") {
                            if let url = URL(string: "https://www.coolapk.com/feed/\(id)") { Platform.open(url) }
                        }
                        Button("拷贝链接") { Platform.copy("https://www.coolapk.com/feed/\(id)") }
                        if let entity {
                            Button("拷贝正文") { Platform.copy(FeedBodyView.plainText(of: entity)) }
                            Divider()
                            Button("屏蔽 \(entity.username)（仅本机）") {
                                app.library.block(uid: entity.uid, username: entity.username)
                                app.showToast("已在本机屏蔽 \(entity.username)")
                            }
                        }
                    } label: {
                        Label("更多", systemImage: "ellipsis")
                    }
                }
            }
        }
    }
}

private struct LikeButton: View {
    let entity: Entity

    @Environment(AppModel.self) private var app
    @State private var likedOverride: Bool?
    @State private var countOverride: Int?

    var body: some View {
        let liked = likedOverride ?? entity.isLiked
        let count = countOverride ?? entity.likeCount
        Button {
            guard app.requireLogin() else { return }
            Task {
                do {
                    let result = try await CoolapkClient.interactive {
                        try await app.client.setFeedLiked(!liked, id: entity.entityID)
                    }
                    likedOverride = !liked
                    countOverride = result ?? max(count + (liked ? -1 : 1), 0)
                } catch {
                    app.report(error)
                }
            }
        } label: {
            Label(Formatting.count(count), systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
        }
        .buttonStyle(.glass)
        .tint(liked ? Color.brand : nil)
        .help(liked ? "取消点赞" : "点赞")
    }
}

/// 一条动态的作者、标题、正文或图文段落、图片和关联信息。
struct FeedBodyView: View {
    let entity: Entity
    let isComplete: Bool

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    struct Part: Identifiable {
        enum Kind { case text, image, link }
        let id: Int
        let kind: Kind
        let text: String
        let url: String
        let caption: String
    }

    static func parts(of entity: Entity) -> [Part] {
        guard let raw = JSON.parse(entity.messageRawOutput)?.array else { return [] }
        var result: [Part] = []
        for item in raw {
            let type = item["type"].string ?? ""
            switch type {
            case "text":
                let text = item["message"].string ?? ""
                if !text.isEmpty { result.append(Part(id: result.count, kind: .text, text: text, url: "", caption: "")) }
            case "image":
                let url = item["url"].string ?? ""
                if !url.isEmpty {
                    result.append(Part(id: result.count, kind: .image, text: "", url: url,
                                       caption: item["description"].string ?? ""))
                }
            default:
                let url = item["url"].string ?? ""
                let title = item["title"].text ?? item["message"].text ?? url
                if !url.isEmpty {
                    result.append(Part(id: result.count, kind: .link, text: title, url: url,
                                       caption: item["subTitle"].string ?? ""))
                }
            }
        }
        return result
    }

    static func plainText(of entity: Entity) -> String {
        let parts = parts(of: entity)
        let body = parts.isEmpty
            ? RichText.plainText(entity.message)
            : parts.filter { $0.kind == .text }.map { RichText.plainText($0.text) }.joined(separator: "\n\n")
        return entity.messageTitle.isEmpty ? body : entity.messageTitle + "\n\n" + body
    }

    var body: some View {
        let parts = FeedBodyView.parts(of: entity)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                FeedAuthorHeader(entity: entity, avatarSize: 42, zoomPrefix: "detail-")
                FollowButton(uid: entity.uid, initiallyFollowing: entity.isFollowingAuthor)
            }
            if !entity.messageCover.isEmpty {
                CoverImage(url: entity.messageCover)
            }
            if !entity.messageTitle.isEmpty {
                Text(entity.messageTitle)
                    .font(.system(size: app.settings.fontSize + 8, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if parts.isEmpty {
                if entity.isArticle {
                    MarkdownTextView(text: entity.message, fontSize: app.settings.fontSize + 1)
                } else {
                    RichTextView(html: entity.message, fontSize: app.settings.fontSize + 1,
                                 mediaSource: entity, fallbackPictures: entity.pictures)
                        .textSelection(.enabled)
                }
                if !entity.pictures.isEmpty {
                    FeedImageGrid(pictures: entity.pictures, maxCount: 30, source: entity)
                }
            } else {
                ArticleBody(parts: parts, entity: entity)
            }
            if let source = entity.forwardSource {
                ForwardedFeedView(entity: source, zoomSourceID: "detail-\(entity.id.uuidString)#forward")
            }
            if !entity.extraTitle.isEmpty, !entity.extraURL.isEmpty {
                ExtraLinkView(title: entity.extraTitle, url: entity.extraURL, picture: entity.extraPic,
                              zoomSourceID: "detail-\(entity.id.uuidString)#extra")
            }
            FeedTagRow(entity: entity, zoomPrefix: "detail-")
            HStack(spacing: 6) {
                Text(Formatting.absolute(entity.dateline))
                if entity.isPublicCopy { Text("· 公开页内容") }
                if !entity.ipLocation.isEmpty { Text("· 发布于 \(entity.ipLocation)") }
                if !entity.deviceTitle.isEmpty { Text("· \(entity.deviceTitle)") }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
    }
}

/// 带简单 Markdown 结构的文本：标题、引用、分隔线和段落。
struct MarkdownTextView: View {
    let text: String
    let fontSize: CGFloat

    private enum Block: Identifiable {
        case paragraph(Int, String)
        case heading(Int, String, level: Int)
        case quote(Int, String)
        case rule(Int)
        var id: Int {
            switch self {
            case .paragraph(let id, _), .heading(let id, _, _), .quote(let id, _), .rule(let id): return id
            }
        }
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(.paragraph(result.count, joined)) }
            paragraph = []
        }
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#"), let space = trimmed.firstIndex(of: " "),
               trimmed[..<space].allSatisfy({ $0 == "#" }), trimmed[..<space].count <= 4 {
                flush()
                result.append(.heading(result.count, String(trimmed[trimmed.index(after: space)...]),
                                       level: trimmed[..<space].count))
            } else if trimmed.hasPrefix("> ") {
                flush()
                result.append(.quote(result.count, String(trimmed.dropFirst(2))))
            } else if trimmed == "---" || trimmed == "***" {
                flush()
                result.append(.rule(result.count))
            } else if trimmed.isEmpty {
                flush()
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                switch block {
                case .paragraph(_, let text):
                    RichTextView(html: text, fontSize: fontSize, markdown: true).textSelection(.enabled)
                case .heading(_, let text, let level):
                    RichTextView(html: text, fontSize: fontSize + CGFloat(max(7 - level * 2, 1)), weight: .bold, markdown: true)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                case .quote(_, let text):
                    RichTextView(html: text, fontSize: fontSize, markdown: true)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3)
                        }
                case .rule:
                    Divider()
                }
            }
        }
    }
}

/// 图文段落：文字、图片和链接卡片。
private struct ArticleBody: View {
    let parts: [FeedBodyView.Part]
    let entity: Entity

    @Environment(AppModel.self) private var app

    var body: some View {
        let images = parts.filter { $0.kind == .image }.map(\.url)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(parts) { part in
                switch part.kind {
                case .text:
                    MarkdownTextView(text: part.text, fontSize: app.settings.fontSize + 1)
                case .image:
                    articleImage(part, all: images)
                case .link:
                    ExtraLinkView(title: part.text, url: part.url, picture: "",
                                  zoomSourceID: "article-\(entity.id.uuidString)#part-\(part.id)")
                }
            }
        }
    }

    private func articleImage(_ part: FeedBodyView.Part, all: [String]) -> some View {
        let pixel = ImageURL.pixelSize(part.url) ?? CGSize(width: 16, height: 10)
        let ratio = max(pixel.width / pixel.height, 0.3)
        return VStack(spacing: 6) {
            Button {
                ImageViewer.show(media: entity.mediaItems(for: all), index: all.firstIndex(of: part.url) ?? 0)
            } label: {
                Color.clear
                    .aspectRatio(ratio, contentMode: .fit)
                    .overlay { RemoteImage(part.url, variant: ImageURL.isGIF(part.url) ? nil : .medium, maxPixel: 2000) }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: min(pixel.width, 720))
            .accessibilityLabel(part.caption.isEmpty ? "查看图片" : part.caption)
            if !part.caption.isEmpty {
                Text(part.caption).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 关注 / 取消关注用户（需要登录）。
struct FollowButton: View {
    let uid: String
    let initiallyFollowing: Bool

    @Environment(AppModel.self) private var app
    @State private var override: Bool?
    @State private var isWorking = false

    var body: some View {
        let following = override ?? initiallyFollowing
        if !uid.isEmpty, uid != app.account?.uid {
            Button(following ? "已关注" : "关注") {
                guard app.requireLogin() else { return }
                isWorking = true
                Task {
                    defer { isWorking = false }
                    do {
                        try await CoolapkClient.interactive {
                            try await app.client.setUserFollowed(!following, uid: uid)
                        }
                        override = !following
                    } catch {
                        app.report(error)
                    }
                }
            }
            .buttonStyle(following ? AnyButtonStyle(.glass) : AnyButtonStyle(KeyActionButtonStyle()))
            .disabled(isWorking)
        }
    }
}

/// 让视图在运行时从两种具体按钮样式中选择。
struct AnyButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
