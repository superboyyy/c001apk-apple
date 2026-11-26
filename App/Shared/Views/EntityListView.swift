import CoolapkKit
import SwiftUI

enum EntityListLayout: Equatable {
    /// 动态按窗口宽度排成一到四列。
    case masonry
    /// 居中的单列阅读栏。
    case single(maxWidth: CGFloat)
}

/// 以滚动分页的方式展示 `PagedList`，可带头部。
struct EntityListView<Header: View>: View {
    let model: PagedList
    var layout: EntityListLayout = .masonry
    var showsRefreshButton = true
    /// 头部接管整个页面（自带加载 / 失败状态）。
    var hidesContent = false
    @ViewBuilder var header: () -> Header

    @Environment(AppModel.self) private var app
    @Environment(\.isActiveRoute) private var isActiveRoute
    @State private var showsTopButton = false
    /// 排版实际采用的内容宽度。瀑布流下只在容器宽度稳定后才更新，见 `widthChanged`。
    @State private var layoutWidth: CGFloat?
    @State private var pendingWidth: Task<Void, Never>?
    @State private var reflowEnd: Task<Void, Never>?
    @State private var position = ScrollPosition(edge: .top)
    /// 滚动状态；放在引用类型里，更新它不会触发界面重算。
    @State private var scroll = ScrollOffsetBox()
    /// 瀑布流分列的缓存，同样不参与界面重算。
    @State private var lanes = MasonryLanes()
    /// 距离底部不远了，该加载下一页。
    @State private var isNearBottom = false

    private static var gutter: CGFloat { 12 }
    private static var horizontalPadding: CGFloat { 16 }
    /// 卡片的最小舒适宽度；窗口能放几列就放几列。
    private static var minimumColumnWidth: CGFloat { 280 }
    /// 距底部多远时开始加载下一页。
    private static var preloadDistance: CGFloat { 600 }

    private var columns: Int {
        switch layout {
        case .single: return 1
        case .masonry:
            let mode = app.settings.columnMode
            if mode != .automatic { return mode.rawValue }
            let contentWidth = max((layoutWidth ?? 900) - Self.horizontalPadding * 2, 200)
            let fit = Int((contentWidth + Self.gutter) / (Self.minimumColumnWidth + Self.gutter))
            return min(max(fit, 1), 6)
        }
    }

    /// 容器宽度变化。边栏展开 / 收起的动画和拖动窗口时宽度每帧都在变：
    /// 瀑布流若逐帧重排，既卡顿又会丢失滚动位置，所以先冻结排版，等宽度
    /// 稳定后一次性重排，再由锚点卡片把阅读位置校正回来。
    private func widthChanged(_ width: CGFloat) {
        guard width >= 200 else { return }
        pendingWidth?.cancel()
        guard layoutWidth != nil, layout == .masonry else {
            layoutWidth = width
            return
        }
        pendingWidth = Task {
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled, width != layoutWidth else { return }
            applyWidth(width)
        }
    }

    private func applyWidth(_ width: CGFloat) {
        let previousColumns = columns
        let offset = scroll.offset
        beginReflow()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { layoutWidth = width }
        // 列数变了会重建各列，锚点卡片可能暂时不在屏幕上：先按比例折算到大致位置。
        if columns != previousColumns, offset > 0, !scroll.reflowStartedNearTop {
            scrollWithoutAnimation(to: offset * CGFloat(previousColumns) / CGFloat(columns))
        }
    }

    /// 进入“重排中”状态，期间由锚点卡片校正滚动位置；片刻后自动结束。
    private func beginReflow() {
        // 停在顶部附近时不做任何校正：重排后仍应留在顶部。
        if !scroll.isReflowing { scroll.reflowStartedNearTop = scroll.offset <= -scroll.topInset + 60 }
        scroll.isReflowing = true
        reflowEnd?.cancel()
        reflowEnd = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            scroll.isReflowing = false
            scroll.pickAnchor()
        }
    }

    /// 无动画地滚到指定的内容偏移。
    private func scrollWithoutAnimation(to offset: CGFloat) {
        scroll.offset = offset
        var transaction = Transaction()
        transaction.disablesAnimations = true
        // scrollTo(y:) 以“内容顶端贴着安全区”为 0，要补上顶部留白。
        withTransaction(transaction) { position.scrollTo(y: offset + scroll.topInset) }
    }

    /// 包一层位置上报：记录卡片位置，重排中由锚点卡片校正滚动位置。
    private func tracked(_ entity: Entity) -> some View {
        EntityCard(entity: entity)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(Self.contentSpace)).minY.rounded()
            } action: { minY in
                scroll.frames[entity.id] = minY
                if let target = scroll.correctedOffset(for: entity.id, minY: minY) {
                    scrollWithoutAnimation(to: target)
                }
            }
            .onDisappear { scroll.frames[entity.id] = nil }
    }

    private static var contentSpace: String { "entity-list-content" }

    private var contentMaxWidth: CGFloat {
        switch layout {
        case .single(let maxWidth): return maxWidth
        case .masonry: return columns == 1 ? 720 : .infinity
        }
    }

    private var visibleItems: [Entity] {
        let library = app.library
        let filter = app.contentFilter
        return model.items.filter { !library.isBlocked(uid: $0.uid) && !filter.shouldHide($0) }
    }

    /// 多列时开头的推广卡片（横幅、快捷入口）横跨整页，其余条目（包括后面的卡片）
    /// 都进入瀑布流，避免整宽卡片在短列下方留出空白。
    private func leadingCardCount(in items: [Entity]) -> Int {
        items.prefix { $0.entityType == "card" || $0.entityTemplate == "time" }.count
    }

    var body: some View {
        ScrollView {
            // 外层不用懒加载：懒加载栈套懒加载栈时，两层互相依赖对方估算的高度，
            // 滚到底部附近会陷入无休止的重排，把主线程卡死。
            VStack(spacing: 12) {
                header()
                if !hidesContent { content }
            }
            .frame(maxWidth: contentMaxWidth)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            // 排版宽度固定为 layoutWidth；容器暂时更宽或更窄时内容靠左、不重排。
            .frame(width: layoutWidth)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .coordinateSpace(.named(Self.contentSpace))
        }
        // 可用宽度 = 容器宽度减去两侧安全区留白。
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            (geometry.containerSize.width - geometry.contentInsets.leading - geometry.contentInsets.trailing).rounded()
        } action: { _, width in
            widthChanged(width)
        }
        .scrollPosition($position)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .modifier(OptionalRefreshable(enabled: showsRefreshButton) {
            let failure = await Task { @MainActor in
                await model.refresh(interactive: true)
            }.value
            if let failure, !model.items.isEmpty {
                app.report(failure)
            }
        })
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, value in
            scroll.offset = value
            if !scroll.isReflowing { scroll.pickAnchor() }
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentInsets.top } action: { _, value in
            scroll.topInset = value
        }
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, value in
            scroll.viewportHeight = value
        }
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 900 } action: { _, value in
            withAnimation(.smooth(duration: 0.2)) { showsTopButton = value }
        }
        // 离底部还有一段距离就开始加载下一页，连续滚动时不必等到见底。
        .onScrollGeometryChange(for: Bool.self) { geometry in
            guard geometry.contentSize.height > 1, geometry.containerSize.height > 1 else { return false }
            return geometry.contentOffset.y + geometry.containerSize.height > geometry.contentSize.height - Self.preloadDistance
        } action: { _, value in
            isNearBottom = value
        }
        .task(id: MoreTrigger(
            isNearBottom: isNearBottom,
            isLoaded: model.phase == .loaded,
            hidesContent: hidesContent,
            count: model.items.count,
            isLoading: model.isLoadingMore,
            isRefreshing: model.isRefreshing,
            hasError: model.moreError != nil,
            autoLoadPaused: model.autoLoadPaused
        )) {
            if isNearBottom, !hidesContent { model.requestMore() }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsTopButton {
                Button {
                    withAnimation(.smooth) { position.scrollTo(edge: .top) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 22, height: 26)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("回到顶部")
                .padding(20)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .task(id: LoadTrigger(isIdle: model.phase == .idle,
                              needsSilentRefresh: model.needsSilentRefresh,
                              resetCount: model.resetCount)) {
            model.loadIfNeeded()
        }
        .toolbar {
            if showsRefreshButton, isActiveRoute {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            if let failure = await model.refresh(interactive: true), !model.items.isEmpty {
                                app.report(failure)
                            }
                        }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("刷新（⌘R）")
                    .disabled(model.phase == .loading || (model.isRefreshing && !model.isSilentRefreshing))
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 240)
        case .empty:
            ContentUnavailableView("这里还没有内容", systemImage: "tray")
                .frame(minHeight: 240)
        case .failed(let error):
            FailureView(error: error) { interactive in
                Task { await model.refresh(interactive: interactive) }
            }
            .frame(minHeight: 240)
        case .loaded:
            let items = visibleItems
            if columns <= 1 {
                LazyVStack(spacing: 12) {
                    ForEach(items) { tracked($0) }
                }
            } else {
                let leading = leadingCardCount(in: items)
                if leading > 0 {
                    // 顶部推广卡片（横幅、图标入口、横滑标签）数量极少，直接常驻避免回收导致缩放过渡锚点丢失。
                    VStack(spacing: 12) {
                        ForEach(items.prefix(leading)) { tracked($0) }
                    }
                }
                if leading < items.count { flow(Array(items.dropFirst(leading))) }
            }
            footer
        }
    }

    /// 瀑布流：每列一个懒加载栈，卡片的归属见 `MasonryLanes`。
    private func flow(_ entities: [Entity]) -> some View {
        // 估高用固定的名义宽度，卡片归属只随列数变化，不随实时宽度抖动。
        let width = MasonryMetrics.nominalColumnWidth
        let style = MasonryLanes.Style(columns: columns, columnWidth: width, spacing: Self.gutter,
                                       fontSize: app.settings.fontSize,
                                       showsReplyPreview: app.settings.showReplyPreview)
        let columns = lanes.distribute(entities, style: style)
        return HStack(alignment: .top, spacing: Self.gutter) {
            ForEach(columns.indices, id: \.self) { lane in
                LazyVStack(spacing: Self.gutter) {
                    ForEach(columns[lane]) { tracked($0) }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .environment(\.masonryColumnWidth, width)
    }

    @ViewBuilder
    private var footer: some View {
        Group {
            if let error = model.moreError {
                VStack(spacing: 8) {
                    Text(error.message).font(.callout).foregroundStyle(.secondary)
                    Button(error.kind == .captcha ? "完成验证后继续" : "重试") {
                        Task { await model.loadMore(interactive: true) }
                    }
                    .buttonStyle(.glass)
                }
            } else if model.reachedEnd {
                Text("没有更多了").font(.callout).foregroundStyle(.tertiary)
            } else if model.isLoadingMore || model.isRefreshing {
                ProgressView().controlSize(.small)
            } else if model.autoLoadPaused {
                Button("继续加载") {
                    Task { await model.loadMore(interactive: true) }
                }
                .buttonStyle(.glass)
            } else {
                // 外层是非懒加载 VStack，footer 始终处于挂载状态：切勿在此加 `.onAppear` 触发翻页，
                // 否则每次刷新或翻页结束切换回按钮分支时都会立刻再次触发 `requestMore()`，造成无限连拉。
                Button("加载更多") {
                    Task { await model.loadMore(interactive: true) }
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 56)
    }
}

extension EntityListView where Header == EmptyView {
    init(model: PagedList, layout: EntityListLayout = .masonry, showsRefreshButton: Bool = true) {
        self.init(model: model, layout: layout, showsRefreshButton: showsRefreshButton, hidesContent: false) { EmptyView() }
    }
}

/// 滚动状态的引用类型容器：更新它不会触发界面重算。
/// 同时记录可见卡片的位置，用来在重排时把阅读位置钉住。
final class ScrollOffsetBox {
    var offset: CGFloat = 0
    /// 滚动视图顶部的安全区留白（导航栏 / 工具栏高度）。
    var topInset: CGFloat = 0
    var viewportHeight: CGFloat = 0
    /// 已渲染卡片在内容坐标系里的顶部位置。
    var frames: [UUID: CGFloat] = [:]
    /// 锚点：重排前最靠近可视区顶部的卡片，及它相对顶部的距离。
    private(set) var anchorID: UUID?
    private(set) var anchorDelta: CGFloat = 0
    var isReflowing = false
    /// 本次重排开始时是否停在列表顶部附近。
    var reflowStartedNearTop = false

    /// 选出当前最靠近可视区顶部的卡片作为锚点。
    func pickAnchor() {
        guard offset > -topInset + 1 else { anchorID = nil; return }
        // 选顶部最接近可视区三分之一处的卡片：重排时内容上下漂移，它也不容易滚出屏幕。
        let focus = offset + viewportHeight * 0.33
        var best: (id: UUID, distance: CGFloat, delta: CGFloat)?
        for (id, minY) in frames {
            let distance = abs(minY - focus)
            if best == nil || distance < best!.distance { best = (id, distance, minY - offset) }
        }
        anchorID = best?.id
        anchorDelta = best?.delta ?? 0
    }

    /// 重排中锚点卡片移动后，应滚动到的位置。
    func correctedOffset(for id: UUID, minY: CGFloat) -> CGFloat? {
        guard isReflowing, !reflowStartedNearTop, id == anchorID else { return nil }
        let target = minY - anchorDelta
        return abs(target - offset) > 0.5 ? target : nil
    }
}

/// iPadOS 支持顶部下拉刷新，macOS 保持原生滚动条行为。
private struct OptionalRefreshable: ViewModifier {
    let enabled: Bool
    let action: @MainActor @Sendable () async -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content
        #else
        if enabled {
            content.refreshable {
                await action()
            }
        } else {
            content
        }
        #endif
    }
}

/// 触发加载下一页的条件；任何一项变化都重新判断一次。
private struct MoreTrigger: Equatable {
    var isNearBottom: Bool
    var isLoaded: Bool
    var hidesContent: Bool
    var count: Int
    var isLoading: Bool
    var isRefreshing: Bool
    var hasError: Bool
    var autoLoadPaused: Bool
}

/// 触发首屏加载或缓存无感刷新的条件。
private struct LoadTrigger: Equatable {
    var isIdle: Bool
    var needsSilentRefresh: Bool
    var resetCount: Int
}

/// 瀑布流的分列结果：按估算高度把每张卡片放进当前最短的一列。
/// 追加数据不会移动已有卡片，所以只需为新增的卡片估高。
final class MasonryLanes {
    struct Style: Equatable {
        var columns: Int
        var columnWidth: CGFloat
        var spacing: CGFloat
        var fontSize: CGFloat
        var showsReplyPreview: Bool
    }

    private var style: Style?
    private var ids: [UUID] = []
    /// 各列里卡片在列表中的下标。
    private var lanes: [[Int]] = []
    private var heights: [CGFloat] = []

    func distribute(_ entities: [Entity], style: Style) -> [[Entity]] {
        let isAppend = style == self.style && entities.count >= ids.count
            && zip(entities, ids).allSatisfy { $0.id == $1 }
        if !isAppend {
            self.style = style
            ids = []
            lanes = Array(repeating: [], count: style.columns)
            heights = Array(repeating: 0, count: style.columns)
        }
        for index in ids.count..<entities.count {
            let entity = entities[index]
            var target = 0
            for lane in 1..<style.columns where heights[lane] < heights[target] - 0.5 { target = lane }
            lanes[target].append(index)
            heights[target] += MasonryMetrics.estimatedHeight(
                of: entity, columnWidth: style.columnWidth, fontSize: style.fontSize,
                showsReplyPreview: style.showsReplyPreview) + style.spacing
            ids.append(entity.id)
        }
        return lanes.map { $0.map { entities[$0] } }
    }
}

extension EnvironmentValues {
    /// 瀑布流单列的宽度；不在多列信息流中时为 `nil`。
    @Entry var masonryColumnWidth: CGFloat? = nil
}

/// 共用的尺寸规则，让瀑布流的高度估算与卡片的实际绘制一致。
enum MasonryMetrics {
    /// 估算卡片高度时采用的列宽。
    static let nominalColumnWidth: CGFloat = 320
    static let cardPadding: CGFloat = 14
    static let textLineLimit = 7
    static let articleLineLimit = 3
    static let maxGridPictures = 6

    /// 瀑布流卡片中单张图片的宽高比。
    static func singlePictureRatio(_ picture: String) -> CGFloat {
        let size = ImageURL.pixelSize(picture) ?? CGSize(width: 4, height: 3)
        return min(max(size.width / size.height, 0.68), 2.4)
    }

    static func coverRatio(_ cover: String) -> CGFloat {
        let size = ImageURL.pixelSize(cover) ?? CGSize(width: 16, height: 9)
        return min(max(size.width / size.height, 1.2), 2.6)
    }

    static func gridColumns(_ count: Int) -> Int { count == 2 || count == 4 ? 2 : 3 }

    private static func lines(_ text: String, perLine: CGFloat, limit: Int) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        var total: CGFloat = 0
        for paragraph in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(limit) {
            // 标签会让字数略微偏多；中日韩字符约占一个 em 宽。
            total += max((CGFloat(min(paragraph.count, 400)) / perLine).rounded(.up), 1)
            if total >= CGFloat(limit) { return CGFloat(limit) }
        }
        return min(total, CGFloat(limit))
    }

    static func estimatedHeight(of entity: Entity, columnWidth: CGFloat, fontSize: CGFloat,
                                showsReplyPreview: Bool) -> CGFloat {
        let inner = columnWidth - cardPadding * 2
        guard entity.entityType == "feed" else {
            let count = CGFloat(max(entity.json["entities"].array?.count ?? 0, 1))
            let titled: CGFloat = entity.title.isEmpty ? 0 : 28
            switch entity.entityTemplate {
            case "imageCarouselCard_1": return columnWidth / 4.5
            case "imageTextScrollCard": return cardPadding * 2 + titled + 146
            case "imageSquareScrollCard": return cardPadding * 2 + titled + 104
            case "iconMiniScrollCard", "iconMiniGridCard", "iconScrollCard": return titled + 52
            case "iconLinkGridCard", "iconTabLinkGridCard":
                let perRow = max(((inner + 8) / 92).rounded(.down), 1)
                return cardPadding * 2 + titled + (count / perRow).rounded(.up) * 72
            case "titleCard": return 30
            default: return 72
            }
        }
        let perLine = max(inner / fontSize, 8)
        let lineHeight = fontSize * 1.48
        var height = cardPadding * 2 + 36
        let isArticle = entity.isArticle
        if isArticle, !entity.messageCover.isEmpty {
            height += inner / coverRatio(entity.messageCover) + 10
        }
        if !entity.messageTitle.isEmpty {
            height += lines(entity.messageTitle, perLine: perLine * 0.88, limit: 3) * (fontSize + 2) * 1.3 + 10
        }
        if !entity.message.isEmpty {
            height += lines(entity.message, perLine: perLine, limit: isArticle ? articleLineLimit : textLineLimit)
                * lineHeight + 10
        }
        let pictures = entity.pictures
        if !isArticle, !pictures.isEmpty {
            if pictures.count == 1 {
                height += inner / singlePictureRatio(pictures[0]) + 10
            } else {
                let columns = CGFloat(gridColumns(pictures.count))
                let rows = (CGFloat(min(pictures.count, maxGridPictures)) / columns).rounded(.up)
                height += rows * ((inner - 5 * (columns - 1)) / columns) + (rows - 1) * 5 + 10
            }
        }
        if entity.forwardSource != nil { height += 70 }
        if !entity.extraTitle.isEmpty, !entity.extraURL.isEmpty { height += 66 }
        if entity.targetRow != nil || !entity.relationRows.isEmpty || !entity.topicTitle.isEmpty { height += 34 }
        if showsReplyPreview, let reply = entity.replyRows.first,
           !reply.message.isEmpty || !reply.replyPictures.isEmpty {
            height += reply.replyPictures.isEmpty ? 48 : 74
        }
        return height + 40
    }
}

/// 说明加载失败的原因，并给出对应的下一步操作。
struct FailureView: View {
    let error: APIError
    /// 参数为 `true` 表示重试时可以弹出人机验证。
    let retry: (Bool) -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(error.message)
        } actions: {
            switch error.kind {
            case .captcha:
                Button("完成验证") { retry(true) }.keyActionButtonStyle()
                if !app.isLoggedIn {
                    Button("登录") { app.isShowingLogin = true }.buttonStyle(.glass)
                }
            case .authentication:
                Button("登录") { app.isShowingLogin = true }.keyActionButtonStyle()
                Button("重试") { retry(true) }.buttonStyle(.glass)
            default:
                Button("重试") { retry(true) }.keyActionButtonStyle()
            }
        }
    }

    private var title: String {
        switch error.kind {
        case .captcha: return "需要人机验证"
        case .authentication: return "需要登录"
        case .transport: return "网络连接异常"
        default: return "加载失败"
        }
    }

    private var symbol: String {
        switch error.kind {
        case .captcha: return "checkmark.shield"
        case .authentication: return "person.crop.circle.badge.exclamationmark"
        case .transport: return "wifi.exclamationmark"
        default: return "exclamationmark.triangle"
        }
    }
}
