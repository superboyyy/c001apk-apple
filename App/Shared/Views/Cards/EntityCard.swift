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
            UserRow(entity: entity.userInfo ?? Entity(entity["fUserInfo"]), zoomSourceID: entity.id.uuidString)
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
    var zoomID: String? = nil
    var cornerRadius: CGFloat = 14
    var appliesZoomSource = true
    var onBeforeOpen: (() -> Void)? = nil
    @ViewBuilder var label: () -> Label

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        Button {
            onBeforeOpen?()
            navigator.open(url, title: title, app: app, zoomID: zoomID)
        } label: {
            label()
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .zoomTransitionSource(id: appliesZoomSource ? zoomID : nil, cornerRadius: cornerRadius)
        .accessibilityLabel(title)
    }
}

private struct CardTitle: View {
    let entity: Entity

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        if !entity.title.isEmpty {
            let moreZoomID = "\(entity.id.uuidString)#more"
            HStack {
                Text(entity.title).font(.system(size: 14, weight: .semibold))
                Spacer()
                if !entity.url.isEmpty {
                    Button {
                        navigator.open(entity.url, title: entity.title, app: app, zoomID: moreZoomID)
                    } label: {
                        HStack(spacing: 2) {
                            Text(entity.subTitle.isEmpty ? "更多" : entity.subTitle)
                            Image(systemName: "chevron.right").imageScale(.small)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .zoomTransitionSource(id: moreZoomID, cornerRadius: 8)
                }
            }
        }
    }
}

/// 非懒加载自适应等宽网格：避免嵌套在懒加载容器里回收子项，导致 iPadOS 缩放过渡锚点丢失。
private struct AdaptiveGridLayout: Layout {
    var minItemWidth: CGFloat = 84
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let plan = layout(width: width, subviews: subviews)
        return CGSize(width: width, height: plan.totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = layout(width: bounds.width, subviews: subviews)
        for (index, frame) in plan.frames.enumerated() where index < subviews.count {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }

    private func layout(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], totalHeight: CGFloat) {
        guard !subviews.isEmpty, width > 0 else { return ([], 0) }
        let fitColumns = max(1, Int((width + horizontalSpacing) / (minItemWidth + horizontalSpacing)))
        let columns = min(fitColumns, subviews.count)
        let itemWidth = (width - horizontalSpacing * CGFloat(columns - 1)) / CGFloat(columns)
        var frames: [CGRect] = []
        frames.reserveCapacity(subviews.count)
        var y: CGFloat = 0
        var rowStart = 0
        while rowStart < subviews.count {
            let rowEnd = min(rowStart + columns, subviews.count)
            var rowHeight: CGFloat = 0
            for idx in rowStart..<rowEnd {
                let size = subviews[idx].sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
                rowHeight = max(rowHeight, size.height)
            }
            for idx in rowStart..<rowEnd {
                let col = idx - rowStart
                let x = CGFloat(col) * (itemWidth + horizontalSpacing)
                frames.append(CGRect(x: x, y: y, width: itemWidth, height: rowHeight))
            }
            y += rowHeight
            if rowEnd < subviews.count { y += verticalSpacing }
            rowStart = rowEnd
        }
        return (frames, y)
    }
}

// MARK: - 卡片

/// 横幅轮播，带 Liquid Glass 翻页控件。
struct CarouselCard: View {
    let entity: Entity

    @Environment(\.isActiveRoute) private var isActiveRoute
    @State private var index = 0
    @State private var hovering = false
    /// 手动翻页后重置自动轮播计时，避免刚切完立刻跳走。
    @State private var manualTick = 0

    private struct AutoAdvanceKey: Equatable {
        let count: Int
        let tick: Int
        let active: Bool
    }

    var body: some View {
        let items = entity.entities.filter { !$0.pic.isEmpty }
        if !items.isEmpty {
            let safeIndex = min(index, items.count - 1)
            let current = items[safeIndex]
            let pixel = ImageURL.pixelSize(current.pic) ?? CGSize(width: 1080, height: 240)
            let ratio = min(max(pixel.width / pixel.height, 2.4), 5)
            // 使用不随自动轮播下标变化的稳定 ID，防止返回时轮播已切页导致收起动画找不到锚点。
            let carouselZoomID = "\(entity.id.uuidString)#carousel"
            // 用 ZStack 把横幅链接与翻页控件拆成同级兄弟视图，避免翻页按钮挂在 Button 的 overlay 内导致点击穿透打开横幅。
            ZStack(alignment: .bottomTrailing) {
                CardLink(url: current.url, title: current.title,
                         zoomID: carouselZoomID, cornerRadius: 16, appliesZoomSource: false) {
                    Color.clear
                        .aspectRatio(ratio, contentMode: .fit)
                        .overlay { RemoteImage(current.pic, maxPixel: 1800).id(current.pic) }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if items.count > 1 {
                    pagerBar(count: items.count, currentIndex: safeIndex)
                }
            }
            // 避免横幅占满页面：最高 190pt。
            .frame(maxWidth: min(1280, 190 * ratio))
            .zoomTransitionSource(id: carouselZoomID, cornerRadius: 16)
            .onHover { hovering = $0 }
            .task(id: AutoAdvanceKey(count: items.count, tick: manualTick, active: isActiveRoute)) {
                // 仅当前可见页自动轮播，被详情页遮挡或指针停在横幅上时暂停，避免后台无意义刷新。
                guard isActiveRoute else { return }
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

    private func step(by delta: Int, count: Int) {
        guard count > 1 else { return }
        manualTick &+= 1
        withAnimation(.smooth) {
            index = (index + delta + count) % count
        }
    }

    private func pagerBar(count: Int, currentIndex: Int) -> some View {
        #if os(macOS)
        let buttonSize: CGFloat = 28
        let iconSize: CGFloat = 12
        let counterFontSize: CGFloat = 12
        let spacing: CGFloat = 6
        let outerPadding: CGFloat = 10
        #else
        let buttonSize: CGFloat = 38
        let iconSize: CGFloat = 15
        let counterFontSize: CGFloat = 13
        let spacing: CGFloat = 8
        let outerPadding: CGFloat = 12
        #endif

        return GlassEffectContainer(spacing: spacing) {
            HStack(spacing: spacing) {
                pager("chevron.left", "上一张", size: buttonSize, iconSize: iconSize) {
                    step(by: -1, count: count)
                }
                Text("\(currentIndex + 1)/\(count)")
                    .font(.system(size: counterFontSize, weight: .medium).monospacedDigit())
                    .padding(.horizontal, buttonSize * 0.3)
                    .frame(minHeight: buttonSize)
                    .contentShape(Capsule())
                    .glassEffect(.regular, in: .capsule)
                    .onTapGesture {}
                pager("chevron.right", "下一张", size: buttonSize, iconSize: iconSize) {
                    step(by: 1, count: count)
                }
            }
        }
        .padding(4)
        .background {
            // 吸收按钮间隙与边缘的误触，避免穿透打开底层轮播链接。
            Color.clear
                .contentShape(Capsule())
                .onTapGesture {}
        }
        .padding(outerPadding - 4)
    }

    private func pager(_ symbol: String, _ label: String, size: CGFloat, iconSize: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: size, height: size)
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
                AdaptiveGridLayout(minItemWidth: 84, horizontalSpacing: 8, verticalSpacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                        CardLink(url: item.url, title: item.title,
                                 zoomID: "\(entity.id.uuidString)#grid-\(offset)", cornerRadius: 14) {
                            VStack(spacing: 6) {
                                RemoteImage(item.pic.isEmpty ? item.logo : item.pic, maxPixel: 160, contentMode: .fit)
                                    .frame(width: 40, height: 40)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Text(item.title).font(.system(size: 11.5)).lineLimit(1)
                            }
                            .padding(.vertical, 4)
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
                    #if os(macOS)
                    // macOS 不走 matchedTransitionSource，用 GlassEffectContainer 将整排标签合并成单个玻璃合成层，
                    // 保留 Liquid Glass 质感的同时大幅降低 WindowServer 开销。
                    GlassEffectContainer(spacing: 8) {
                        chipRow(items)
                    }
                    #else
                    // iPadOS 不包在 GlassEffectContainer 内：容器会把子项的 `.glassEffect` 合并进统一 SDFLayer，
                    // 吞掉子项上的 `.matchedTransitionSource`，导致缩放过渡退化为从屏幕中央打开。
                    chipRow(items)
                    #endif
                }
                .scrollClipDisabled()
            }
            .padding(.horizontal, 4)
        }
    }

    private func chipRow(_ items: [Entity]) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                let title = item.title.isEmpty ? item.username : item.title
                let picture = [item.logo, item.pic, item.userAvatar].first { !$0.isEmpty } ?? ""
                let url = item.url.isEmpty && item.entityType == "user" ? "/u/\(item.uid)" : item.url
                let chipZoomID = "\(entity.id.uuidString)#chip-\(offset)"
                CardLink(url: url, title: title,
                         zoomID: chipZoomID, cornerRadius: 20, appliesZoomSource: false) {
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
                .zoomTransitionSource(id: chipZoomID, cornerRadius: 20)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
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
                        ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                            CardLink(url: item.url, title: item.title,
                                     zoomID: "\(entity.id.uuidString)#square-\(offset)", cornerRadius: 12) {
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
                        ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                            let title = item.messageTitle.isEmpty ? item.title : item.messageTitle
                            CardLink(url: item.url, title: title,
                                     zoomID: "\(entity.id.uuidString)#imgtext-\(offset)", cornerRadius: 10,
                                     onBeforeOpen: { app.remember(item) }) {
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
    var zoomSourceID: String? = nil

    @Environment(Navigator.self) private var navigator

    private var resolvedZoomID: String { zoomSourceID ?? entity.id.uuidString }

    var body: some View {
        Button {
            if !entity.uid.isEmpty { navigator.push(.user(entity.uid), zoomID: resolvedZoomID) }
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
        .zoomTransitionSource(id: resolvedZoomID)
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
            navigator.open(entity.url, title: entity.title, app: app, zoomID: entity.id.uuidString)
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
        .zoomTransitionSource(id: entity.id.uuidString)
    }
}

struct AppRow: View {
    let entity: Entity

    @Environment(Navigator.self) private var navigator

    var body: some View {
        Button {
            let key = entity["apkname"].text ?? entity.entityID
            if !key.isEmpty { navigator.push(.app(key), zoomID: entity.id.uuidString) }
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
        .zoomTransitionSource(id: entity.id.uuidString)
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
        let openNotification: () -> Void = {
            guard !entity.url.isEmpty else { return }
            navigator.openCardLink(entity.url, title: entity.title, app: app, zoomID: entity.id.uuidString)
        }
        HStack(alignment: .top, spacing: 12) {
            AvatarView(url: avatar, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(Formatting.relative(time)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if !body.isEmpty {
                    RichTextView(html: body, fontSize: app.settings.fontSize - 0.5, lineLimit: 4,
                                 onCardTap: entity.url.isEmpty ? nil : openNotification)
                }
            }
        }
        .card(padding: 12, interactive: !entity.url.isEmpty)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { openNotification() }
        .zoomTransitionSource(id: entity.id.uuidString)
    }
}
