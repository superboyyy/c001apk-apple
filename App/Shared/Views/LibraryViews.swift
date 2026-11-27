import CoolapkKit
import SwiftUI

/// 保存在本机的收藏或浏览历史。
struct SavedFeedList: View {
    enum Kind { case favorites, history }
    let kind: Kind

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator
    @State private var confirmsClear = false

    private var items: [SavedFeed] { kind == .favorites ? app.library.favorites : app.library.history }

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    kind == .favorites ? "还没有收藏" : "还没有浏览记录",
                    systemImage: kind == .favorites ? "star" : "clock.arrow.circlepath",
                    description: Text(kind == .favorites ? "在帖子上点“收藏”，会保存在这台 Mac 上。" : "读过的帖子会出现在这里，仅保存在本机。"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .modifier(SavedFeedHistoryToolbar(enabled: kind == .history && !items.isEmpty) {
            confirmsClear = true
        })
        .confirmationDialog("清空全部浏览历史？", isPresented: $confirmsClear) {
            Button("清空", role: .destructive) { app.library.clearHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作只影响本机记录，无法撤销。")
        }
    }

    private func row(_ item: SavedFeed) -> some View {
        let zoomID = "saved-\(kind == .favorites ? "fav" : "hist")-\(item.id)"
        return Button {
            navigator.push(.feed(id: item.id), zoomID: zoomID)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                AvatarView(url: item.avatar, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.username).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Text(Formatting.relative(item.savedAt)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if !item.title.isEmpty {
                        Text(item.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
                    }
                    if !item.excerpt.isEmpty {
                        Text(item.excerpt).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                if !item.cover.isEmpty {
                    RemoteImage(item.cover, variant: .square, maxPixel: 240)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .card(padding: 12, interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .zoomTransitionSource(id: zoomID)
        .contextMenu {
            Button("拷贝链接") { Platform.copy("https://www.coolapk.com/feed/\(item.id)") }
            Button(kind == .favorites ? "取消收藏" : "从历史中移除", role: .destructive) {
                if kind == .favorites { app.library.removeFavorite(item.id) } else { app.library.removeHistory(item.id) }
            }
        }
    }
}

private struct SavedFeedHistoryToolbar: ViewModifier {
    let enabled: Bool
    let onClear: () -> Void

    @Environment(\.isActiveRoute) private var isActiveRoute

    func body(content: Content) -> some View {
        content.toolbar {
            if isActiveRoute, enabled {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onClear) {
                        Label("清空历史", systemImage: "trash")
                    }
                    .help("清空浏览历史")
                }
            }
        }
    }
}

/// 账号通知（需要登录）。
struct NotificationsView: View {
    enum Kind: String, CaseIterable, Hashable {
        case mentions, comments, likes, follows, system

        var title: String {
            switch self {
            case .mentions: return "@我的"
            case .comments: return "评论"
            case .likes: return "赞"
            case .follows: return "新粉丝"
            case .system: return "通知"
            }
        }

        var path: String {
            switch self {
            case .mentions: return "/v6/notification/atMeList"
            case .comments: return "/v6/notification/atCommentMeList"
            case .likes: return "/v6/notification/feedLikeList"
            case .follows: return "/v6/notification/contactsFollowList"
            case .system: return "/v6/notification/list"
            }
        }
    }

    @Environment(AppModel.self) private var app
    @State private var kind: Kind = .mentions

    var body: some View {
        if app.isLoggedIn {
            let app = app
            let client = app.client
            let current = kind
            let model = app.list("notifications-\(current.rawValue)") {
                PagedList(cacheKey: "notifications-\(current.rawValue)", cacheScope: { app.cacheScope }) { request in
                    try await client.list(path: current.path, page: request.page,
                                          firstItem: request.firstItem, lastItem: request.lastItem)
                }
            }
            ZStack {
                EntityListView(model: model, layout: .single(maxWidth: 720)) {
                    GlassTabBar(items: Kind.allCases, selection: $kind) { $0.title }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(current)
                .transition(.opacity)
            }
        } else {
            LoginRequiredView(message: "登录后可以查看 @我、评论、赞和系统通知。")
        }
    }
}

struct LoginRequiredView: View {
    let message: String
    @Environment(AppModel.self) private var app

    var body: some View {
        ContentUnavailableView {
            Label("需要登录", systemImage: "person.crop.circle")
        } description: {
            Text(message)
        } actions: {
            Button("登录酷安") { app.isShowingLogin = true }.keyActionButtonStyle()
        }
    }
}
