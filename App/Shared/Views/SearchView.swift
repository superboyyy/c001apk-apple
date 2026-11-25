import CoolapkKit
import SwiftUI

struct SearchView: View {
    var initialKeyword: String?

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    @State private var text = ""
    @State private var keyword = ""
    @State private var kind: CoolapkClient.SearchKind = .feed
    @State private var feedType: CoolapkClient.SearchFeedType = .all
    @State private var sort: CoolapkClient.SearchSort = .default
    @State private var model: PagedList?

    private struct Query: Hashable {
        let keyword: String
        let kind: CoolapkClient.SearchKind
        let feedType: CoolapkClient.SearchFeedType
        let sort: CoolapkClient.SearchSort
    }

    private var query: Query { Query(keyword: keyword, kind: kind, feedType: feedType, sort: sort) }

    var body: some View {
        Group {
            if keyword.isEmpty {
                suggestions
            } else if let model {
                EntityListView(model: model) {
                    GlassTabBar(items: CoolapkClient.SearchKind.allCases, selection: $kind) { $0.title }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(query)
            }
        }
        .navigationTitle(keyword.isEmpty ? "搜索" : "“\(keyword)”")
        .searchable(text: $text, placement: .toolbar, prompt: "搜索动态、应用、用户、话题")
        .onSubmit(of: .search) { submit(text) }
        .toolbar {
            if !keyword.isEmpty, kind == .feed {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("类型", selection: $feedType) {
                            ForEach(CoolapkClient.SearchFeedType.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        Picker("排序", selection: $sort) {
                            ForEach(CoolapkClient.SearchSort.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("筛选", systemImage: "line.3.horizontal.decrease")
                    }
                    .help("筛选与排序")
                }
            }
        }
        .task(id: query) { rebuild() }
        .onChange(of: navigator.pendingSearch, initial: true) { _, pending in
            guard let pending else { return }
            navigator.pendingSearch = nil
            text = pending
            submit(pending)
        }
        .onChange(of: text) { _, value in
            if value.isEmpty { keyword = "" }
        }
        .task {
            if let initialKeyword, keyword.isEmpty {
                text = initialKeyword
                submit(initialKeyword)
            }
        }
    }

    private func submit(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 粘贴的酷安链接直接打开。
        if trimmed.hasPrefix("http") || trimmed.hasPrefix("coolmarket://"),
           case .route(let route) = LinkRouter.resolve(trimmed) {
            navigator.push(route)
            return
        }
        app.library.recordSearch(trimmed)
        keyword = trimmed
    }

    private func rebuild() {
        guard !keyword.isEmpty else {
            model = nil
            return
        }
        let client = app.client
        let current = query
        model = PagedList { request in
            try await client.search(keyword: current.keyword, kind: current.kind, feedType: current.feedType,
                                    sort: current.sort, page: request.page,
                                    firstItem: request.firstItem, lastItem: request.lastItem)
        }
    }

    private var suggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if app.library.searches.isEmpty {
                    ContentUnavailableView("搜索酷安", systemImage: "magnifyingglass",
                                           description: Text("在上方输入关键词，或粘贴酷安链接直接打开。"))
                        .frame(minHeight: 320)
                } else {
                    HStack {
                        Text("搜索历史").font(.headline)
                        Spacer()
                        Button("清空") { app.library.clearSearches() }.buttonStyle(.glass)
                    }
                    FlowLayout(spacing: 8) {
                        ForEach(app.library.searches, id: \.self) { item in
                            Button(item) {
                                text = item
                                submit(item)
                            }
                            .buttonStyle(.glass)
                            .contextMenu {
                                Button("删除") { app.library.removeSearch(item) }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }
}

/// 标签用的自动换行布局。
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
