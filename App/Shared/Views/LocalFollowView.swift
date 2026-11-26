import CoolapkKit
import SwiftUI

/// 悄悄关注：汇总本机名单内用户的动态，并可切换到名单管理。
struct LocalFollowView: View {
    let store: LocalFollowStore

    private enum Mode: Hashable, CaseIterable {
        case feed, users

        var title: String { self == .feed ? "动态" : "名单" }
    }

    @Environment(AppModel.self) private var app
    @State private var mode = Mode.feed

    private var title: String { LocalFollowStore.title(isLoggedIn: app.isLoggedIn) }

    var body: some View {
        let model = store.timeline(client: app.client, library: app.library)
        EntityListView(model: model, hidesContent: mode == .users || store.users.isEmpty) {
            VStack(spacing: 12) {
                summary
                if mode == .users {
                    LocalFollowUserList(store: store, title: title)
                } else if store.users.isEmpty {
                    ContentUnavailableView(
                        "还没有\(title)的用户", systemImage: "person.crop.circle.badge.plus",
                        description: Text("在用户主页选择“\(title)”，就能在这里看到对方的动态。名单只保存在本机。"))
                        .frame(minHeight: 240)
                } else if let warning = store.warning, model.phase == .loaded {
                    // 个别用户失败时其余动态照常显示；完全失败由列表自己的失败页处理。
                    HStack(spacing: 10) {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("重试") {
                            Task { await model.loadMore(interactive: true) }
                        }
                        .buttonStyle(.glass)
                        .disabled(model.isLoadingMore)
                    }
                    .card(padding: 12)
                }
            }
        }
        .routeTitle(title)
    }

    private var summary: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(title)动态").font(.headline)
                Text("读取本机名单中 \(store.users.count) 位用户的公开动态，不会同步到账号关注。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Picker("显示内容", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .card()
    }
}

/// 名单管理：查看主页或从本机名单移除。
struct LocalFollowUserList: View {
    let store: LocalFollowStore
    var title = "悄悄关注"

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        if store.users.isEmpty {
            ContentUnavailableView("名单是空的", systemImage: "person.2.slash",
                                   description: Text("名单只保存在本机，登录、退出账号后仍会保留。"))
                .frame(minHeight: 240)
        } else {
            VStack(spacing: 10) {
                ForEach(store.users) { user in
                    row(user)
                }
                Text("名单只保存在本机，登录、退出账号后仍会保留，不会自动同步到账号。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: 720)
        }
    }

    private func row(_ user: LocalFollowUser) -> some View {
        let zoomID = "local-follow-\(user.uid)"
        return HStack(spacing: 12) {
            Button {
                navigator.push(.user(user.uid), zoomID: zoomID)
            } label: {
                HStack(spacing: 12) {
                    AvatarView(url: user.avatar, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(user.displayName).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        Text("UID \(user.uid)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开用户主页")
            Button {
                store.unfollow(uid: user.uid)
                app.showToast("已取消\(title)，仅修改本机名单")
            } label: {
                Image(systemName: "person.badge.minus")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("取消\(title)")
            .accessibilityLabel("取消\(title)：\(user.displayName)")
        }
        .card(padding: 12)
        .zoomTransitionSource(id: zoomID)
    }
}

/// 放进用户主页菜单的一项：把这位用户加入或移出本机名单。
struct LocalFollowMenuButton: View {
    let store: LocalFollowStore
    let user: Entity

    @Environment(AppModel.self) private var app

    var body: some View {
        let title = LocalFollowStore.title(isLoggedIn: app.isLoggedIn)
        let following = store.isFollowing(uid: user.uid)
        Button(following ? "取消\(title)" : "\(title)（仅本机）") {
            if store.toggle(user: user) {
                app.showToast("已\(title)，仅保存在本机")
            } else if following {
                app.showToast("已取消\(title)")
            } else {
                app.showToast("无法\(title)这位用户")
            }
        }
        .disabled(!LocalFollowStore.isValid(uid: user.uid))
    }
}
