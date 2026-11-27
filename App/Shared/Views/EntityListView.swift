import CoolapkKit
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#endif

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
    @Environment(Navigator.self) private var navigator: Navigator?
    /// 排版实际采用的内容宽度。瀑布流下只在容器宽度稳定后才更新，见 `widthChanged`。
    @State private var layoutWidth: CGFloat?
    @State private var pendingWidth: Task<Void, Never>?
    /// 滚动状态；放在引用类型里，更新它不会触发界面重算。
    @State private var scroll = ScrollOffsetBox()
    /// 浮窗按钮与触底状态隔离在独立可观察对象里，滚动越过阈值或加载分页时不会触发整棵列表重算。
    @State private var chrome = ScrollChromeState()
    /// 瀑布流分列的缓存，同样不参与界面重算。
    @State private var lanes = MasonryLanes()

    private static var gutter: CGFloat { 12 }
    private static var horizontalPadding: CGFloat { 16 }
    /// 卡片的最小舒适宽度；窗口能放几列就放几列。
    private static var minimumColumnWidth: CGFloat { 280 }
    /// 距底部多远时开始加载下一页。
    private static var preloadDistance: CGFloat { 600 }
    private static var topAnchorID: String { "entity-list-top-anchor" }

    private var effectiveWidth: CGFloat {
        if let layoutWidth { return layoutWidth }
        if let detail = navigator?.detailFrame.width, detail > 200 { return detail.rounded() }
        return 900
    }

    private var columns: Int {
        switch layout {
        case .single: return 1
        case .masonry:
            let mode = app.settings.columnMode
            if mode != .automatic { return mode.rawValue }
            let contentWidth = max(effectiveWidth - Self.horizontalPadding * 2, 200)
            let fit = Int((contentWidth + Self.gutter) / (Self.minimumColumnWidth + Self.gutter))
            return min(max(fit, 1), 6)
        }
    }

    /// 容器宽度变化。边栏展开 / 收起的动画和拖动窗口时宽度每帧都在变：
    /// 瀑布流若逐帧重排，既卡顿又会丢失滚动位置，所以先冻结排版，等宽度
    /// 稳定后一次性重排，并按列数比例维持阅读位置。
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
        let offset = scroll.currentOffset()
        let startedNearTop = offset <= 60
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { layoutWidth = width }
        // 列数变化后按比例折算大致阅读位置，避免拖动窗口时跳到完全陌生的位置。
        if columns != previousColumns, offset > 0, !startedNearTop {
            let ratio = CGFloat(previousColumns) / CGFloat(columns)
            let targetOffset = offset * ratio
            Task { @MainActor in
                scroll.scrollWithoutAnimation(to: targetOffset)
            }
        }
    }

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
        ScrollViewReader { scrollProxy in
            ScrollView {
                // 外层不用懒加载：懒加载栈套懒加载栈时，两层互相依赖对方估算的高度，
                // 滚到底部附近会陷入无休止的重排，把主线程卡死。
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 0)
                        .id(Self.topAnchorID)
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
                }
                #if os(macOS)
                .background { MacScrollViewFinder(box: scroll) }
                #endif
            }
            // 所有滚动期指标合并为单个离散状态监听：日常滚动绝大多数帧完全相等，零回调、零主线程事务。
            .onScrollGeometryChange(for: ScrollObservedMetrics.self) { geometry in
                let offsetY = geometry.contentOffset.y
                let nearBottom: Bool
                if geometry.contentSize.height > 1, geometry.containerSize.height > 1 {
                    nearBottom = offsetY + geometry.containerSize.height > geometry.contentSize.height - Self.preloadDistance
                } else {
                    nearBottom = false
                }
                return ScrollObservedMetrics(
                    availableWidth: (geometry.containerSize.width - geometry.contentInsets.leading - geometry.contentInsets.trailing).rounded(),
                    topInset: geometry.contentInsets.top.rounded(),
                    viewportHeight: geometry.containerSize.height.rounded(),
                    showsTopButton: offsetY > 900,
                    isNearBottom: nearBottom
                )
            } action: { old, metrics in
                if old.topInset != metrics.topInset || old.viewportHeight != metrics.viewportHeight
                    || old.availableWidth != metrics.availableWidth {
                    scroll.topInset = metrics.topInset
                    scroll.viewportHeight = metrics.viewportHeight
                    widthChanged(metrics.availableWidth)
                }
                if chrome.showsTopButton != metrics.showsTopButton {
                    withAnimation(.smooth(duration: 0.2)) {
                        chrome.showsTopButton = metrics.showsTopButton
                    }
                }
                if chrome.isNearBottom != metrics.isNearBottom {
                    chrome.isNearBottom = metrics.isNearBottom
                }
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .modifier(OptionalRefreshable(enabled: showsRefreshButton) {
                let failure = await Task { @MainActor in
                    await model.refresh(interactive: true)
                }.value
                if let failure, !model.items.isEmpty {
                    app.report(failure)
                }
            })
            .overlay(alignment: .bottomTrailing) {
                ScrollTopButtonOverlay(chrome: chrome) {
                    withAnimation(.smooth) {
                        scrollProxy.scrollTo(Self.topAnchorID, anchor: .top)
                    }
                }
            }
        }
        .background {
            EntityListLoadDriver(model: model)
            EntityListLoadMoreDriver(model: model, chrome: chrome, hidesContent: hidesContent)
        }
        .modifier(EntityListRefreshToolbar(model: model, enabled: showsRefreshButton))
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
            let revision = model.contentRevision
            if columns <= 1 {
                LazyVStack(spacing: 12) {
                    ForEach(items) { entity in
                        EquatableEntityCard(entity: entity, revision: revision).equatable()
                    }
                }
            } else {
                let leading = leadingCardCount(in: items)
                if leading > 0 {
                    // 顶部推广卡片（横幅、图标入口、横滑标签）数量极少，直接常驻避免回收导致缩放过渡锚点丢失。
                    VStack(spacing: 12) {
                        ForEach(items.prefix(leading)) { entity in
                            EquatableEntityCard(entity: entity, revision: revision).equatable()
                        }
                    }
                }
                if leading < items.count { flow(Array(items.dropFirst(leading)), revision: revision) }
            }
            EntityListFooter(model: model)
        }
    }

    /// 瀑布流：每列一个懒加载栈，卡片的归属见 `MasonryLanes`。
    private func flow(_ entities: [Entity], revision: Int) -> some View {
        // 估高用固定的名义宽度，卡片归属只随列数变化，不随实时宽度抖动。
        let width = MasonryMetrics.nominalColumnWidth
        let style = MasonryLanes.Style(columns: columns, columnWidth: width, spacing: Self.gutter,
                                       fontSize: app.settings.fontSize,
                                       showsReplyPreview: app.settings.showReplyPreview)
        let columns = lanes.distribute(entities, style: style, revision: revision)
        return HStack(alignment: .top, spacing: Self.gutter) {
            ForEach(columns.indices, id: \.self) { lane in
                LazyVStack(spacing: Self.gutter) {
                    ForEach(columns[lane]) { entity in
                        EquatableEntityCard(entity: entity, revision: revision).equatable()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .environment(\.masonryColumnWidth, width)
    }
}

extension EntityListView where Header == EmptyView {
    init(model: PagedList, layout: EntityListLayout = .masonry, showsRefreshButton: Bool = true) {
        self.init(model: model, layout: layout, showsRefreshButton: showsRefreshButton, hidesContent: false) { EmptyView() }
    }
}

/// 卡片判等包装：翻页追加时已有卡片 `id` 与 `revision` 不变，O(1) 跳过整张卡片重算。
private struct EquatableEntityCard: View, Equatable {
    let entity: Entity
    let revision: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entity.id == rhs.entity.id && lhs.revision == rhs.revision
    }

    var body: some View {
        EntityCard(entity: entity)
    }
}

/// 独立持有的滚动浮窗与触底状态，避免状态切换牵连整棵信息流列表重算。
@MainActor
@Observable
private final class ScrollChromeState {
    var showsTopButton = false
    var isNearBottom = false
}

/// 回到顶部悬浮按钮：只订阅 `chrome.showsTopButton`，不影响列表主体。
private struct ScrollTopButtonOverlay: View {
    let chrome: ScrollChromeState
    let action: () -> Void

    var body: some View {
        if chrome.showsTopButton {
            Button(action: action) {
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
}

/// 独立处理首屏加载与缓存静默刷新触发，避免 `needsSilentRefresh` 变化触发整页重算。
private struct EntityListLoadDriver: View {
    let model: PagedList

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: LoadTrigger(isIdle: model.phase == .idle,
                                  needsSilentRefresh: model.needsSilentRefresh,
                                  resetCount: model.resetCount)) {
                model.loadIfNeeded()
            }
    }
}

/// 独立处理触底分页加载，避免 `isNearBottom / isLoadingMore / isRefreshing` 翻转引发整页瀑布流重算。
private struct EntityListLoadMoreDriver: View {
    let model: PagedList
    let chrome: ScrollChromeState
    let hidesContent: Bool

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .task(id: MoreTrigger(
                isNearBottom: chrome.isNearBottom,
                isLoaded: model.phase == .loaded,
                hidesContent: hidesContent,
                count: model.items.count,
                isLoading: model.isLoadingMore,
                isRefreshing: model.isRefreshing,
                hasError: model.moreError != nil,
                autoLoadPaused: model.autoLoadPaused
            )) {
                if chrome.isNearBottom, !hidesContent { model.requestMore() }
            }
    }
}

/// 独立分页页脚：只重算底部 56pt 状态区域，不触发上方卡片重算。
private struct EntityListFooter: View {
    let model: PagedList

    var body: some View {
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

/// 独立刷新工具栏：隔离 `isActiveRoute` 环境读取，导航推入/返回时不会让列表主体失效重算。
private struct EntityListRefreshToolbar: ViewModifier {
    let model: PagedList
    let enabled: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.isActiveRoute) private var isActiveRoute

    func body(content: Content) -> some View {
        content.toolbar {
            if enabled, isActiveRoute {
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
}

/// 滚动状态的引用类型容器：更新它不会触发界面重算。
/// 仅在窗口宽度变动引起瀑布流列数重排时按需读取滚动偏移，日常滚动零开销。
@MainActor
final class ScrollOffsetBox {
    /// 滚动视图顶部的安全区留白（导航栏 / 工具栏高度）。
    var topInset: CGFloat = 0
    var viewportHeight: CGFloat = 0
    #if os(macOS)
    weak var scrollView: NSScrollView?
    #endif

    func currentOffset() -> CGFloat {
        #if os(macOS)
        guard let scrollView else { return 0 }
        return max(scrollView.contentView.bounds.origin.y + topInset, 0)
        #else
        return 0
        #endif
    }

    func scrollWithoutAnimation(to offset: CGFloat) {
        #if os(macOS)
        guard let scrollView, let document = scrollView.documentView else { return }
        let maxY = max(document.bounds.height - scrollView.contentView.bounds.height, 0)
        let targetY = min(max(offset - topInset, -topInset), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #endif
    }
}

#if os(macOS)
/// 挂载后一次性查找所在 `NSScrollView` 并弱引用保存，完全不拦截事件，日常滚动零开销。
private struct MacScrollViewFinder: NSViewRepresentable {
    let box: ScrollOffsetBox

    func makeNSView(context: Context) -> FinderView {
        let view = FinderView()
        view.box = box
        return view
    }

    func updateNSView(_ nsView: FinderView, context: Context) {
        nsView.box = box
        nsView.attachIfNeeded()
    }

    final class FinderView: NSView {
        weak var box: ScrollOffsetBox?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            guard box?.scrollView == nil else { return }
            var cursor: NSView? = superview
            while let view = cursor {
                if let scrollView = view as? NSScrollView {
                    box?.scrollView = scrollView
                    return
                }
                cursor = view.superview
            }
        }
    }
}
#endif

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

/// 合并滚动容器的离散状态参数：日常滚动时各字段恒定，完全不触发 action 回调。
private struct ScrollObservedMetrics: Equatable {
    var availableWidth: CGFloat
    var topInset: CGFloat
    var viewportHeight: CGFloat
    var showsTopButton: Bool
    var isNearBottom: Bool
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
    private var cachedRevision: Int = -1
    private var cachedResult: [[Entity]] = []

    func distribute(_ entities: [Entity], style: Style, revision: Int) -> [[Entity]] {
        let isAppend = style == self.style && entities.count >= ids.count
            && zip(entities, ids).allSatisfy { $0.id == $1 }
        if isAppend, entities.count == ids.count, revision == cachedRevision, !cachedResult.isEmpty {
            return cachedResult
        }
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
        let result = lanes.map { $0.map { entities[$0] } }
        cachedRevision = revision
        cachedResult = result
        return result
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
