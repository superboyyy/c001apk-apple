import CoolapkKit
import SwiftUI

/// 列表中的一条动态：作者、正文、图片、关联信息和计数。
struct FeedCard: View {
    let entity: Entity

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator
    @Environment(\.masonryColumnWidth) private var masonryColumnWidth

    private var isArticle: Bool { entity.isArticle }
    private var textLineLimit: Int {
        if isArticle { return MasonryMetrics.articleLineLimit }
        return masonryColumnWidth == nil ? 8 : MasonryMetrics.textLineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeedAuthorHeader(entity: entity)

            if isArticle, !entity.messageCover.isEmpty {
                CoverImage(url: entity.messageCover)
            }
            if !entity.messageTitle.isEmpty {
                Text(entity.messageTitle)
                    .font(.system(size: app.settings.fontSize + 2, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !entity.message.isEmpty {
                RichTextView(html: entity.message, lineLimit: textLineLimit, markdown: isArticle)
                    .foregroundStyle(isArticle ? .secondary : .primary)
            }
            if !isArticle, !entity.pictures.isEmpty {
                FeedImageGrid(pictures: entity.pictures)
            }
            if let source = entity.forwardSource {
                ForwardedFeedView(entity: source)
            }
            if !entity.extraTitle.isEmpty, !entity.extraURL.isEmpty {
                ExtraLinkView(title: entity.extraTitle, url: entity.extraURL, picture: entity.extraPic)
            }
            FeedTagRow(entity: entity)
            if app.settings.showReplyPreview, let reply = entity.replyRows.first, !reply.message.isEmpty {
                HotReplyPreview(reply: reply)
            }
            FeedCounters(entity: entity)
        }
        .card(interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { open() }
        .contextMenu { FeedContextMenu(entity: entity) }
        // 整张卡片作为一个无障碍元素，默认操作是打开动态（而不是
        // 卡片里的第一个控件），其余作为具名操作。
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .accessibilityAction(named: "查看 \(entity.username) 的主页") {
            if !entity.uid.isEmpty { navigator.push(.user(entity.uid)) }
        }
    }

    private func open() {
        let id = entity.entityID
        guard !id.isEmpty else { return }
        app.remember(entity)
        navigator.openCard(.feed(id: id))
    }
}

struct FeedAuthorHeader: View {
    let entity: Entity
    var avatarSize: CGFloat = 36

    @Environment(Navigator.self) private var navigator

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                if !entity.uid.isEmpty { navigator.push(.user(entity.uid)) }
            } label: {
                AvatarView(url: entity.userAvatar, size: avatarSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(entity.username) 的主页")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entity.username)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if entity.isStickTop {
                        Text("置顶")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.brand)
                    }
                }
                HStack(spacing: 4) {
                    Text(Formatting.relative(entity.dateline))
                    if !entity.deviceTitle.isEmpty {
                        Image(systemName: "iphone").imageScale(.small)
                        Text(entity.deviceTitle).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !entity.feedTypeName.isEmpty, entity.feedTypeName != "动态" {
                Text(entity.feedTypeName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
    }
}

struct CoverImage: View {
    let url: String

    var body: some View {
        let ratio = MasonryMetrics.coverRatio(url)
        Color.clear
            .aspectRatio(ratio, contentMode: .fit)
            .overlay { RemoteImage(url, maxPixel: 1400) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 单图显示大图，多图排成方形网格。
struct FeedImageGrid: View {
    let pictures: [String]
    var maxCount = 9

    @Environment(AppModel.self) private var app
    @Environment(\.masonryColumnWidth) private var masonryColumnWidth

    /// 瀑布流中图片撑满卡片宽度，其他地方保持适合阅读的尺寸。
    private var fillsWidth: Bool { masonryColumnWidth != nil }

    var body: some View {
        if pictures.count == 1 {
            single(pictures[0])
        } else {
            let shown = Array(pictures.prefix(fillsWidth ? min(maxCount, MasonryMetrics.maxGridPictures) : maxCount))
            let columnCount = MasonryMetrics.gridColumns(pictures.count)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: columnCount)
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, picture in
                    cell(picture, index: index, extra: index == shown.count - 1 ? pictures.count - shown.count : 0)
                }
            }
            .frame(maxWidth: fillsWidth ? .infinity : (columnCount == 2 ? 420 : 520), alignment: .leading)
        }
    }

    private func single(_ picture: String) -> some View {
        let size = ImageURL.pixelSize(picture) ?? CGSize(width: 4, height: 3)
        let ratio = fillsWidth
            ? MasonryMetrics.singlePictureRatio(picture)
            : min(max(size.width / size.height, 0.56), 2.4)
        let isLong = size.height / size.width > 2.4
        return Button {
            ImageViewer.show(urls: pictures, index: 0)
        } label: {
            Color.clear
                .aspectRatio(ratio, contentMode: .fit)
                .overlay {
                    RemoteImage(picture, variant: app.settings.highQualityThumbnails ? .medium : .small, maxPixel: 1400)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .bottomTrailing) { marks(picture, isLong: isLong) }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: fillsWidth ? .infinity : (ratio < 1 ? 260 : 460),
               maxHeight: fillsWidth ? .infinity : 360, alignment: .leading)
        .accessibilityLabel("查看图片")
    }

    private func cell(_ picture: String, index: Int, extra: Int) -> some View {
        let size = ImageURL.pixelSize(picture)
        let isLong = size.map { $0.height / $0.width > 2.4 } ?? false
        return Button {
            ImageViewer.show(urls: pictures, index: index)
        } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    RemoteImage(picture, variant: app.settings.highQualityThumbnails ? .small : .square, maxPixel: 600)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if extra > 0 {
                        GlassBadge(text: "+\(extra)").padding(5)
                    } else {
                        marks(picture, isLong: isLong)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看第 \(index + 1) 张图片")
    }

    @ViewBuilder
    private func marks(_ picture: String, isLong: Bool) -> some View {
        if ImageURL.isGIF(picture) {
            GlassBadge(text: "GIF").padding(5)
        } else if isLong {
            GlassBadge(text: "长图").padding(5)
        } else {
            // 实况 / HDR 角标（按文件名里的标记判断）。
            MediaBadges(url: picture).padding(5)
        }
    }
}

struct ForwardedFeedView: View {
    let entity: Entity

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let name = RichText.escape(entity.username)
            RichTextView(
                html: "<a href=\"/u/\(entity.uid)\">@\(name)</a>: " + (entity.messageTitle.isEmpty ? entity.message : entity.messageTitle),
                fontSize: app.settings.fontSize - 1, lineLimit: 6)
            if !entity.pictures.isEmpty {
                FeedImageGrid(pictures: entity.pictures, maxCount: 3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
            guard !entity.entityID.isEmpty else { return }
            app.remember(entity)
            navigator.openCard(.feed(id: entity.entityID))
        }
    }
}

struct ExtraLinkView: View {
    let title: String
    let url: String
    let picture: String

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        Button {
            navigator.open(url, title: title, app: app)
        } label: {
            HStack(spacing: 10) {
                if picture.isEmpty {
                    Image(systemName: "link")
                        .frame(width: 40, height: 40)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RemoteImage(picture, maxPixel: 160)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(URL(string: url)?.host ?? url)
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 动态附带的话题 / 数码 / 频道标签。
struct FeedTagRow: View {
    let entity: Entity

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    private var chips: [(title: String, url: String, logo: String)] {
        var result: [(String, String, String)] = []
        var seen = Set<String>()
        if let target = entity.targetRow, !target.title.isEmpty {
            result.append((target.title, target.url, target.logo))
            seen.insert(target.title)
        }
        for row in entity.relationRows where !row.title.isEmpty && !seen.contains(row.title) {
            result.append((row.title, row.url, row.logo))
            seen.insert(row.title)
        }
        if result.isEmpty, !entity.topicTitle.isEmpty {
            result.append((entity.topicTitle, entity["turl"].string ?? "/t/\(entity.topicTitle)", entity["tpic"].string ?? ""))
        }
        return result
    }

    var body: some View {
        let items = chips
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, chip in
                        Button {
                            navigator.open(chip.url, title: chip.title, app: app)
                        } label: {
                            HStack(spacing: 4) {
                                if !chip.logo.isEmpty {
                                    RemoteImage(chip.logo, maxPixel: 64)
                                        .frame(width: 16, height: 16)
                                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                }
                                Text(chip.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .foregroundStyle(.primary.opacity(0.8))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassChip()
                    }
                }
            }
        }
    }
}

struct HotReplyPreview: View {
    let reply: Entity
    @Environment(AppModel.self) private var app

    var body: some View {
        RichTextView(
            html: "<b>\(RichText.escape(reply.username))</b>: \(reply.message)"
                + (reply.pictures.isEmpty && reply.pic.isEmpty ? "" : " [图片]"),
            fontSize: app.settings.fontSize - 1.5, lineLimit: 2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct FeedCounters: View {
    let entity: Entity

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator
    @State private var likedOverride: Bool?
    @State private var likeCountOverride: Int?
    @State private var isWorking = false

    private var liked: Bool { likedOverride ?? entity.isLiked }
    private var likeCount: Int { likeCountOverride ?? entity.likeCount }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                Button(action: toggleLike) {
                    GlassCounterLabel(text: Formatting.count(likeCount),
                                      systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup", isActive: liked)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .help(liked ? "取消点赞" : "点赞")
                .accessibilityLabel(liked ? "取消点赞，\(likeCount)" : "点赞，\(likeCount)")
                Button {
                    app.remember(entity)
                    navigator.openCard(.feed(id: entity.entityID))
                } label: {
                    GlassCounterLabel(text: Formatting.count(entity.replyCount), systemImage: "bubble.left")
                }
                .buttonStyle(.plain)
                .help("查看评论")
                .accessibilityLabel("评论，\(entity.replyCount)")
                if entity.forwardCount > 0 {
                    ShareLink(item: URL(string: "https://www.coolapk.com/feed/\(entity.entityID)") ?? URL(fileURLWithPath: "/")) {
                        GlassCounterLabel(text: Formatting.count(entity.forwardCount), systemImage: "arrowshape.turn.up.right")
                    }
                    .buttonStyle(.plain)
                    .help("分享")
                }
                Spacer(minLength: 0)
                if !entity.infoHTML.isEmpty {
                    // 放不下就整段不显示，避免被截成半截。
                    ViewThatFits(in: .horizontal) {
                        Text(RichText.plainText(entity.infoHTML))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
            }
        }
    }

    private func toggleLike() {
        guard app.requireLogin() else { return }
        let target = !liked
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let count = try await CoolapkClient.interactive {
                    try await app.client.setFeedLiked(target, id: entity.entityID)
                }
                likedOverride = target
                likeCountOverride = count ?? max(likeCount + (target ? 1 : -1), 0)
            } catch {
                app.report(error)
            }
        }
    }
}

struct FeedContextMenu: View {
    let entity: Entity

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        let id = entity.entityID
        let link = "https://www.coolapk.com/feed/\(id)"
        Button("打开") {
            app.remember(entity)
            navigator.push(.feed(id: id))
        }
        Button("在浏览器中打开") {
            if let url = URL(string: link) { Platform.open(url) }
        }
        Divider()
        Button("拷贝链接") { Platform.copy(link) }
        Button("拷贝正文") { Platform.copy(RichText.plainText(entity.message)) }
        Divider()
        Button(app.library.isFavorite(id) ? "取消收藏" : "收藏到本机") { app.library.toggleFavorite(entity) }
        if !entity.uid.isEmpty {
            Button("查看 \(entity.username) 的主页") { navigator.push(.user(entity.uid)) }
            Button("屏蔽 \(entity.username)（仅本机）") {
                app.library.block(uid: entity.uid, username: entity.username)
                app.showToast("已在本机屏蔽 \(entity.username)")
            }
        }
    }
}
