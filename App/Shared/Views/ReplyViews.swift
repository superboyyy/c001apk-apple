import CoolapkKit
import SwiftUI

enum ReplyStyle {
    /// 单独展示的回复（搜索结果、用户主页）：点击打开所属动态。
    case standalone
    /// 动态下的一级回复。
    case inFeed
    /// 楼中楼里的回复。
    case thread
}

/// 通过环境传递的回调。它与任何其他实例都判等，这样重建闭包不会让
/// 所有回复失效；闭包只访问引用类型持有的视图状态，所以最先安装的
/// 那个一直有效。
struct EntityAction: Equatable {
    let run: (Entity) -> Void

    init(_ run: @escaping (Entity) -> Void) { self.run = run }

    func callAsFunction(_ entity: Entity) { run(entity) }

    static func == (lhs: EntityAction, rhs: EntityAction) -> Bool { true }
}

extension EnvironmentValues {
    @Entry var replyStyle: ReplyStyle = .standalone
    /// 开始回复指定评论。
    @Entry var replyAction: EntityAction? = nil
    /// 打开指定评论下的完整楼中楼。
    @Entry var showThread: EntityAction? = nil
}

struct ReplyCard: View {
    let entity: Entity

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator
    @Environment(\.replyStyle) private var style
    @Environment(\.replyAction) private var replyAction
    @Environment(\.showThread) private var showThread

    @State private var likedOverride: Bool?
    @State private var likeCountOverride: Int?

    private var liked: Bool { likedOverride ?? entity.isLiked }
    private var likeCount: Int { likeCountOverride ?? entity.likeCount }
    private var isAuthor: Bool { !entity.uid.isEmpty && entity.uid == entity.feedUID }

    var body: some View {
        let avatarZoomID = style == .thread ? nil : "\(entity.id.uuidString)#reply-author"
        HStack(alignment: .top, spacing: 10) {
            Button {
                if !entity.uid.isEmpty { navigator.push(.user(entity.uid), zoomID: avatarZoomID) }
            } label: {
                AvatarView(url: entity.userAvatar, size: 32)
            }
            .buttonStyle(.plain)
            .zoomTransitionSource(id: avatarZoomID, cornerRadius: 16)
            .accessibilityLabel("\(entity.username) 的主页")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(entity.username).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if isAuthor { badge("楼主") }
                    if entity["isFeedAuthor"].int == 1, !isAuthor { badge("楼主") }
                    if entity.json["is_top"].int == 1 || entity.isStickTop { badge("置顶") }
                    Spacer(minLength: 0)
                    Text(Formatting.relative(entity.dateline))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                let pictures = entity.replyPictures
                let html = messageHTML(hidingStandalonePhoto: !pictures.isEmpty)
                let openStandalone: (() -> Void)? = style == .standalone ? {
                    guard let feedID = entity["fid"].text, feedID != "0" else { return }
                    navigator.openCard(.feed(id: feedID), zoomID: entity.id.uuidString)
                } : nil
                if !html.isEmpty {
                    RichTextView(html: html, fontSize: app.settings.fontSize, mediaSource: entity,
                                 fallbackPictures: pictures, onCardTap: openStandalone)
                }
                if !pictures.isEmpty {
                    FeedImageGrid(pictures: pictures, source: entity).frame(maxWidth: 320, alignment: .leading)
                }
                if style == .inFeed, !entity.replyRows.isEmpty {
                    nestedReplies
                }
                footer
            }
        }
        .padding(style == .standalone ? 0 : 4)
        .modifier(StandaloneCard(enabled: style == .standalone, zoomID: entity.id.uuidString) {
            guard let feedID = entity["fid"].text, feedID != "0" else { return }
            navigator.openCard(.feed(id: feedID), zoomID: entity.id.uuidString)
        })
        .contextMenu {
            Button("拷贝内容") { Platform.copy(RichText.plainText(entity.message)) }
            if !entity.uid.isEmpty {
                Button("查看 \(entity.username) 的主页") { navigator.push(.user(entity.uid)) }
                Button("屏蔽 \(entity.username)（仅本机）") {
                    app.library.block(uid: entity.uid, username: entity.username)
                }
            }
        }
    }

    private func messageHTML(hidingStandalonePhoto: Bool) -> String {
        let trimmed = entity.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = (hidingStandalonePhoto && trimmed == "[图片]") ? "" : entity.message
        if style == .thread, !entity.replyUsername.isEmpty {
            let prefix = "回复 <a href=\"/u/\(entity.replyUID)\">@\(RichText.escape(entity.replyUsername))</a>"
            return body.isEmpty ? prefix : "\(prefix): \(body)"
        }
        return body
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(Color.brand)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.brand.opacity(0.7), lineWidth: 0.8))
    }

    private var nestedReplies: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(entity.replyRows.prefix(3)) { row in
                nestedReplyRow(row)
            }
            let total = max(entity.replyCount, entity.replyRows.count + entity.replyRowsMore)
            if total > min(entity.replyRows.count, 3) {
                Button {
                    showThread?(entity)
                } label: {
                    HStack(spacing: 2) {
                        Text("查看全部 \(total) 条回复")
                        Image(systemName: "chevron.right").imageScale(.small)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.brand)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func nestedReplyRow(_ row: Entity) -> some View {
        let pictures = row.replyPictures
        let target = row.replyUsername.isEmpty || row.replyUID == entity.uid
            ? "" : " 回复 <a href=\"/u/\(row.replyUID)\">\(RichText.escape(row.replyUsername))</a>"
        let prefix = "<a href=\"/u/\(row.uid)\">\(RichText.escape(row.username))</a>\(target)"
        let trimmed = row.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let messageOnlyPhoto = !pictures.isEmpty && (trimmed.isEmpty || trimmed == "[图片]")

        return VStack(alignment: .leading, spacing: 4) {
            RichTextView(
                html: messageOnlyPhoto ? "\(prefix):" : "\(prefix): \(row.message)",
                fontSize: app.settings.fontSize - 1,
                lineLimit: 3,
                mediaSource: row,
                fallbackPictures: pictures
            )
            if !pictures.isEmpty {
                ReplyImageButton(pictures: pictures, source: row)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: toggleLike) {
                GlassCounterLabel(text: likeCount > 0 ? Formatting.count(likeCount) : "赞",
                                  systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup",
                                  isActive: liked, compact: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(liked ? "取消点赞" : "点赞")
            if style != .standalone {
                Button {
                    replyAction?(entity)
                } label: {
                    GlassCounterLabel(text: "回复", systemImage: "bubble.left", compact: true)
                }
                .buttonStyle(.plain)
            }
            if style == .inFeed, entity.replyRows.isEmpty, entity.replyCount > 0 {
                Button {
                    showThread?(entity)
                } label: {
                    GlassCounterLabel(text: "\(entity.replyCount) 条回复", systemImage: "text.bubble", compact: true)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if !entity.ipLocation.isEmpty {
                Text(entity.ipLocation).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }

    private func toggleLike() {
        guard app.requireLogin() else { return }
        let target = !liked
        Task {
            do {
                let count = try await CoolapkClient.interactive {
                    try await app.client.setFeedLiked(target, id: entity.entityID, isReply: true)
                }
                likedOverride = target
                likeCountOverride = count ?? max(likeCount + (target ? 1 : -1), 0)
            } catch {
                app.report(error)
            }
        }
    }
}

/// 楼中楼 / 热评预览里的“查看图片”按钮：直接打开查看器（支持多图与实况元数据）。
struct ReplyImageButton: View {
    let pictures: [String]
    var source: Entity?
    var fontSize: CGFloat = 12

    @Environment(Navigator.self) private var navigator: Navigator?

    var body: some View {
        Button {
            navigator?.noteLinkActivated()
            if let source {
                ImageViewer.show(media: source.mediaItems(for: pictures), index: 0)
            } else {
                ImageViewer.show(urls: pictures, index: 0)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "photo")
                    .font(.system(size: fontSize - 0.5, weight: .medium))
                Text(pictures.count > 1 ? "查看图片 (\(pictures.count))" : "查看图片")
                    .font(.system(size: fontSize, weight: .medium))
            }
            .foregroundStyle(Color.brand)
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(Color.brand.opacity(0.10), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pictures.count > 1 ? "查看 \(pictures.count) 张图片" : "查看图片")
    }
}

private struct StandaloneCard: ViewModifier {
    let enabled: Bool
    let zoomID: String
    let onTap: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .card(padding: 12, interactive: true)
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .onTapGesture(perform: onTap)
                .zoomTransitionSource(id: zoomID)
        } else {
            content
        }
    }
}

/// 一条评论下的完整对话。
struct ReplyThreadSheet: View {
    let root: Entity
    let onReply: (Entity) -> Void

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator
    @Environment(\.dismiss) private var dismiss
    @State private var model: PagedList?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("回复详情").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            if let model {
                EntityListView(model: model, layout: .single(maxWidth: 640), showsRefreshButton: false) {
                    ReplyCard(entity: root)
                        .environment(\.replyStyle, .thread)
                    Divider()
                }
                .environment(\.replyStyle, .thread)
                .environment(\.replyAction, EntityAction { reply in
                    dismiss()
                    onReply(reply)
                })
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let href = RichText.href(from: url) else { return .systemAction }
            navigator.noteLinkActivated()
            navigator.open(href, app: app)
            return .handled
        })
        .frame(width: 600, height: 620)
        .task {
            guard model == nil else { return }
            let client = app.client
            let id = root.entityID
            model = PagedList { request in
                try await client.replyThread(id: id, page: request.page, firstItem: request.firstItem, lastItem: request.lastItem)
            }
        }
    }
}
