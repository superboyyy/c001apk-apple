import CoolapkKit
import SwiftUI

/// 为任意列表行选择合适的展示形式。
struct EntityCard: View {
    let entity: Entity

    var body: some View {
        switch entity.entityType {
        case "feed":
            FeedCard(entity: entity)
        case "feed_reply":
            ReplyCard(entity: entity)
        case "user":
            UserRow(entity: entity)
        case "contacts":
            UserRow(entity: entity.userInfo ?? Entity(entity["fUserInfo"]))
        case "topic", "product", "productBrand", "collection", "feedRelation":
            TopicRow(entity: entity)
        case "apk":
            AppRow(entity: entity)
        case "notification", "message", "recentHistory":
            NotificationRow(entity: entity)
        case "card":
            templateCard
        default:
            if entity.entityTemplate.isEmpty {
                EmptyView()
            } else {
                templateCard
            }
        }
    }

    @ViewBuilder
    private var templateCard: some View {
        switch entity.entityTemplate {
        case "imageCarouselCard_1":
            CarouselCard(entity: entity)
        case "iconLinkGridCard", "iconTabLinkGridCard":
            IconLinkGridCard(entity: entity)
        case "iconMiniScrollCard", "iconMiniGridCard", "iconScrollCard":
            IconScrollCard(entity: entity)
        case "imageSquareScrollCard":
            ImageSquareScrollCard(entity: entity)
        case "imageTextScrollCard":
            ImageTextScrollCard(entity: entity)
        case "titleCard":
            TitleCard(entity: entity)
        case "messageCard":
            if !entity.title.isEmpty || !entity.descriptionText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !entity.title.isEmpty { Text(entity.title).font(.headline) }
                    if !entity.descriptionText.isEmpty {
                        Text(RichText.plainText(entity.descriptionText)).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .card()
            }
        case "time":
            Text(entity.title.isEmpty ? Formatting.absolute(entity.dateline) : entity.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        default:
            EmptyView()
        }
    }
}

// MARK: - 公共部件

private struct CardLink<Label: View>: View {
    let url: String
    let title: String
    @ViewBuilder var label: () -> Label

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        Button {
            navigator.open(url, title: title, app: app)
        } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct CardTitle: View {
    let entity: Entity

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        if !entity.title.isEmpty {
            HStack {
                Text(entity.title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if !entity.url.isEmpty {
                    Button {
                        navigator.open(entity.url, title: entity.title, app: app)
                    } label: {
                        HStack(spacing: 2) {
                            Text(entity.subTitle.isEmpty ? "更多" : entity.subTitle)
                            Image(systemName: "chevron.right").imageScale(.small)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 卡片

/// 横幅轮播，带 Liquid Glass 翻页控件。
struct CarouselCard: View {
    let entity: Entity

    @State private var index = 0
    @State private var hovering = false

    var body: some View {
        let items = entity.entities.filter { !$0.pic.isEmpty }
        if !items.isEmpty {
            let current = items[min(index, items.count - 1)]
            let pixel = ImageURL.pixelSize(current.pic) ?? CGSize(width: 1080, height: 240)
            CardLink(url: current.url, title: current.title) {
                Color.clear
                    .aspectRatio(min(max(pixel.width / pixel.height, 2.4), 5), contentMode: .fit)
                    .overlay { RemoteImage(current.pic, maxPixel: 1800).id(current.pic) }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .overlay(alignment: .bottomTrailing) {
                if items.count > 1 {
                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            pager("chevron.left", "上一张") { index = (index - 1 + items.count) % items.count }
                            Text("\(min(index, items.count - 1) + 1)/\(items.count)")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .glassEffect(.regular, in: .capsule)
                            pager("chevron.right", "下一张") { index = (index + 1) % items.count }
                        }
                    }
                    .padding(10)
                }
            }
            // 避免横幅占满页面：最高 190pt。
            .frame(maxWidth: min(1280, 190 * min(max(pixel.width / pixel.height, 2.4), 5)))
            .onHover { hovering = $0 }
            .task(id: items.count) {
                // 自动轮播，指针停在横幅上时暂停。
                while !Task.isCancelled, items.count > 1 {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if !hovering, !Task.isCancelled {
                        withAnimation(.smooth) { index = (index + 1) % items.count }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func pager(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth) { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

struct IconLinkGridCard: View {
    let entity: Entity

    var body: some View {
        let items = entity.entities
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(entity: entity)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 130), spacing: 8)], spacing: 12) {
                    ForEach(items) { item in
                        CardLink(url: item.url, title: item.title) {
                            VStack(spacing: 6) {
                                RemoteImage(item.pic.isEmpty ? item.logo : item.pic, maxPixel: 160, contentMode: .fit)
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Text(item.title).font(.system(size: 11.5)).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .card()
        }
    }
}

/// 横向滚动的话题、设备、用户或应用。
struct IconScrollCard: View {
    let entity: Entity

    var body: some View {
        let items = entity.entities
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(entity: entity)
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            ForEach(items) { item in
                                let title = item.title.isEmpty ? item.username : item.title
                                let picture = [item.logo, item.pic, item.userAvatar].first { !$0.isEmpty } ?? ""
                                let url = item.url.isEmpty && item.entityType == "user" ? "/u/\(item.uid)" : item.url
                                CardLink(url: url, title: title) {
                                    HStack(spacing: 8) {
                                        RemoteImage(picture, maxPixel: 120)
                                            .frame(width: 28, height: 28)
                                            .clipShape(RoundedRectangle(cornerRadius: item.entityType == "user" ? 14 : 7, style: .continuous))
                                        Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    }
                                    .padding(.leading, 7)
                                    .padding(.trailing, 13)
                                    .padding(.vertical, 6)
                                    .contentShape(Capsule())
                                }
                                .glassChip()
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                    }
                }
                .scrollClipDisabled()
            }
            .padding(.horizontal, 4)
        }
    }
}

struct ImageSquareScrollCard: View {
    let entity: Entity

    var body: some View {
        let items = entity.entities.filter { !$0.pic.isEmpty }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(entity: entity)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items) { item in
                            CardLink(url: item.url, title: item.title) {
                                RemoteImage(item.pic, maxPixel: 400)
                                    .frame(width: 104, height: 104)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(alignment: .bottomLeading) {
                                        if !item.title.isEmpty {
                                            ImageBadge(text: item.title).padding(5)
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .card()
        }
    }
}

/// 横向滚动的精选图文。
struct ImageTextScrollCard: View {
    let entity: Entity

    @Environment(AppModel.self) private var app

    var body: some View {
        let items = entity.entities
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(entity: entity)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(items) { item in
                            let title = item.messageTitle.isEmpty ? item.title : item.messageTitle
                            CardLink(url: item.url, title: title) {
                                VStack(alignment: .leading, spacing: 6) {
                                    RemoteImage(item.messageCover.isEmpty ? item.pic : item.messageCover, maxPixel: 700)
                                        .frame(width: 210, height: 104)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    Text(title)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .frame(width: 210, alignment: .leading)
                                }
                            }
                            .simultaneousGesture(TapGesture().onEnded { app.remember(item) })
                        }
                    }
                }
            }
            .card()
        }
    }
}

struct TitleCard: View {
    let entity: Entity

    var body: some View {
        CardTitle(entity: entity)
            .padding(.horizontal, 4)
            .padding(.top, 6)
    }
}

// MARK: - 列表行

struct UserRow: View {
    let entity: Entity

    @Environment(Navigator.self) private var navigator

    var body: some View {
        Button {
            if !entity.uid.isEmpty { navigator.push(.user(entity.uid)) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(url: entity.userAvatar, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entity.username).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        if entity.level > 0 {
                            Text("Lv.\(entity.level)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.brand)
                        }
                    }
                    Text("\(Formatting.count(entity.followCount)) 关注 · \(Formatting.count(entity.fansCount)) 粉丝"
                        + (entity.loginTime == nil ? "" : " · \(Formatting.relative(entity.loginTime))活跃"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    if !entity.bio.isEmpty {
                        Text(entity.bio).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
            }
            .card(padding: 12, interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct TopicRow: View {
    let entity: Entity

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    private var detail: String {
        var parts: [String] = []
        if !entity.hotText.isEmpty { parts.append("\(entity.hotText) 热度") }
        if !entity.commentText.isEmpty { parts.append("\(entity.commentText) 讨论") }
        if parts.isEmpty, !entity.followText.isEmpty { parts.append("\(entity.followText) 关注") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button {
            navigator.open(entity.url, title: entity.title, app: app)
        } label: {
            HStack(spacing: 12) {
                RemoteImage(entity.logo.isEmpty ? entity.pic : entity.logo, maxPixel: 200)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(entity.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    let summary = entity.intro.isEmpty ? entity.descriptionText : entity.intro
                    if !summary.isEmpty {
                        Text(RichText.plainText(summary)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
            }
            .card(padding: 12, interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct AppRow: View {
    let entity: Entity

    @Environment(Navigator.self) private var navigator

    var body: some View {
        Button {
            let key = entity["apkname"].text ?? entity.entityID
            if !key.isEmpty { navigator.push(.app(key)) }
        } label: {
            HStack(spacing: 12) {
                RemoteImage(entity.logo, maxPixel: 200, contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(entity.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text([entity["apkversionname"].string, entity["apksize"].string, entity["downCount"].string.map { "\($0) 下载" }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    let summary = entity["subtitle"].text ?? entity.descriptionText
                    if !summary.isEmpty {
                        Text(RichText.plainText(summary)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
            }
            .card(padding: 12, interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 通知样式的行：谁、做了什么、什么时候。
struct NotificationRow: View {
    let entity: Entity

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        let name = entity["fromusername"].text ?? entity["messageUsername"].text ?? entity["likeUsername"].text ?? entity.username
        let avatar = entity["fromUserAvatar"].text ?? entity["messageUserAvatar"].text ?? entity["likeAvatar"].text ?? entity.userAvatar
        let body = entity["note"].text ?? entity.message
        let time = entity.dateline ?? entity["likeTime"].int
        HStack(alignment: .top, spacing: 12) {
            AvatarView(url: avatar, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(Formatting.relative(time)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !body.isEmpty {
                    RichTextView(html: body, fontSize: app.settings.fontSize - 0.5, lineLimit: 4)
                }
            }
        }
        .card(padding: 12, interactive: !entity.url.isEmpty)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            guard !entity.url.isEmpty else { return }
            navigator.openCardLink(entity.url, title: entity.title, app: app)
        }
    }
}
