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
    @State private var showsTopButton = false
    /// 排版实际采用的内容宽度。瀑布流下只在容器宽度稳定后才更新，见 `widthChanged`。
    @State private var layoutWidth: CGFloat?
    @State private var pendingWidth: Task<Void, Never>?
    @State private var reflowEnd: Task<Void, Never>?
    @State private var position = ScrollPosition(edge: .top)
    /// 滚动状态；放在引用类型里，更新它不会触发界面重算。
    @State private var scroll = ScrollOffsetBox()

    private static var gutter: CGFloat { 12 }
    private static var horizontalPadding: CGFloat { 16 }
    /// 卡片的最小舒适宽度；窗口能放几列就放几列。
    private static var minimumColumnWidth: CGFloat { 280 }

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

    private enum Segment: Identifiable {
        case full(Entity)
        case flow([Entity])
        var id: UUID {
            switch self {
            case .full(let entity): return entity.id
            case .flow(let entities): return entities[0].id
            }
        }
    }

    private var visibleItems: [Entity] {
        let library = app.library
        let filter = app.contentFilter
        return model.items.filter { !library.isBlocked(uid: $0.uid) && !filter.shouldHide($0) }
    }

    /// 开头的推广卡片（横幅、快捷入口）横跨整页。第一条普通内容之后的所有
    /// 条目（包括后面的卡片）都进入瀑布流，避免整宽卡片在短列下方留出空白。
    private var segments: [Segment] {
        var result: [Segment] = []
        var run: [Entity] = []
        let waterfall = columns > 1
        for entity in visibleItems {
            let isCard = entity.entityType == "card" || entity.entityTemplate == "time"
            if isCard, !(waterfall && !run.isEmpty) {
                if !run.isEmpty { result.append(.flow(run)); run = [] }
                result.append(.full(entity))
            } else {
                run.append(entity)
            }
        }
        if !run.isEmpty { result.append(.flow(run)) }
        return result
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
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
        .task(id: model.phase == .idle) { model.loadIfNeeded() }
        .toolbar {
            if showsRefreshButton {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await model.refresh(interactive: true) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("刷新（⌘R）")
                    .disabled(model.phase == .loading)
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
            ForEach(segments) { segment in
                switch segment {
                case .full(let entity):
                    tracked(entity)
                case .flow(let entities):
                    flow(entities)
                }
            }
            footer
        }
    }

    /// 瀑布流：按估算高度把每张卡片放进当前最短的一列。
    /// 追加数据不会移动已有卡片。
    private func distribute(_ entities: [Entity], into count: Int, width: CGFloat) -> [[Entity]] {
        var result = Array(repeating: [Entity](), count: count)
        var heights = Array(repeating: CGFloat(0), count: count)
        let fontSize = app.settings.fontSize
        let showsReply = app.settings.showReplyPreview
        for entity in entities {
            var target = 0
            for index in 1..<count where heights[index] < heights[target] - 0.5 { target = index }
            result[target].append(entity)
            heights[target] += MasonryMetrics.estimatedHeight(
                of: entity, columnWidth: width, fontSize: fontSize, showsReplyPreview: showsReply) + Self.gutter
        }
        return result
    }

    @ViewBuilder
    private func flow(_ entities: [Entity]) -> some View {
        let count = columns
        if count <= 1 {
            ForEach(entities) { tracked($0) }
        } else {
            // 估高用固定的名义宽度，卡片归属只随列数变化，不随实时宽度抖动。
            let width = MasonryMetrics.nominalColumnWidth
            let lanes = distribute(entities, into: count, width: width)
            HStack(alignment: .top, spacing: Self.gutter) {
                ForEach(0..<count, id: \.self) { lane in
                    LazyVStack(spacing: Self.gutter) {
                        ForEach(lanes[lane]) { tracked($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .environment(\.masonryColumnWidth, width)
        }
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
            } else {
                ProgressView()
                    .controlSize(.small)
                    .task(id: model.items.count) { model.requestMore() }
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
        if showsReplyPreview, let reply = entity.replyRows.first, !reply.message.isEmpty { height += 48 }
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
