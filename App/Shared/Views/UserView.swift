import CoolapkKit
import SwiftUI

/// 用户主页及其动态。
struct UserView: View {
    /// 数字 uid 或用户名，即 `/u/…` 链接里的那一段。
    let key: String

    @Environment(AppModel.self) private var app
    @State private var user: Entity?
    @State private var failure: APIError?
    @State private var feeds: PagedList?

    var body: some View {
        Group {
            if let user, let feeds {
                EntityListView(model: feeds) {
                    UserHeader(user: user)
                }
            } else if let failure {
                FailureView(error: failure) { interactive in
                    Task { await load(interactive: interactive) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(user?.username ?? "用户")
        .task(id: key) { await load(interactive: false) }
    }

    private func load(interactive: Bool) async {
        failure = nil
        do {
            let client = app.client
            let loaded: Entity
            if interactive {
                loaded = try await CoolapkClient.interactive { try await client.userSpace(uid: key) }
            } else {
                loaded = try await client.userSpace(uid: key)
            }
            let uid = loaded.uid
            user = loaded
            feeds = PagedList { request in
                try await client.userFeed(uid: uid, page: request.page, firstItem: request.firstItem, lastItem: request.lastItem)
            }
        } catch {
            failure = APIError.from(error)
        }
    }
}

private struct UserHeader: View {
    let user: Entity

    @Environment(AppModel.self) private var app
    @Environment(Navigator.self) private var navigator

    var body: some View {
        VStack(spacing: 0) {
            // 封面图，上面浮着 Liquid Glass 的身份信息面板。
            ZStack(alignment: .bottom) {
                Group {
                    if user.cover.isEmpty {
                        LinearGradient(colors: [Color.brand.opacity(0.7), Color.brand.opacity(0.3)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    } else {
                        RemoteImage(user.cover, maxPixel: 1800)
                    }
                }
                .frame(height: 210)
                .frame(maxWidth: .infinity)
                .clipped()

                HStack(spacing: 14) {
                    Button {
                        ImageViewer.show(urls: [user["userBigAvatar"].text ?? user.userAvatar], index: 0)
                    } label: {
                        AvatarView(url: user.userAvatar, size: 64)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看头像")
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(user.username).font(.system(size: 18, weight: .bold)).lineLimit(1)
                            if user.level > 0 {
                                Text("Lv.\(user.level)")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.brand.opacity(0.2), in: Capsule())
                            }
                        }
                        if let verify = user["verify_title"].text {
                            Label(verify, systemImage: "checkmark.seal.fill")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text("UID \(user.uid)").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    FollowButton(uid: user.uid, initiallyFollowing: user.isFollowed)
                    Menu {
                        if let url = LinkRouter.webURL(for: .user(user.uid)) {
                            Button("在浏览器中打开") { Platform.open(url) }
                            Button("拷贝主页链接") { Platform.copy(url.absoluteString) }
                        }
                        // 直接写成按钮：系统菜单不会展开自定义视图类型。
                        let quietTitle = LocalFollowStore.title(isLoggedIn: app.isLoggedIn)
                        Button(app.localFollow.isFollowing(uid: user.uid) ? "取消\(quietTitle)" : "\(quietTitle)（仅本机）") {
                            let wasFollowing = app.localFollow.isFollowing(uid: user.uid)
                            if app.localFollow.toggle(user: user) {
                                app.showToast("已\(quietTitle)，仅保存在本机")
                            } else if wasFollowing {
                                app.showToast("已取消\(quietTitle)")
                            } else {
                                app.showToast("无法\(quietTitle)这位用户")
                            }
                        }
                        if let myUID = app.account?.uid,
                           let peer = ChatPeer(uid: user.uid, username: user.username, avatar: user.userAvatar, myUID: myUID) {
                            Button("发私信") { navigator.push(.chat(peer)) }
                        }
                        Divider()
                        if app.library.isBlocked(uid: user.uid) {
                            Button("取消屏蔽") { app.library.unblock(uid: user.uid) }
                        } else {
                            Button("屏蔽（仅本机）") { app.library.block(uid: user.uid, username: user.username) }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("更多操作")
                }
                .padding(14)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .padding(12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 12) {
                if !user.bio.isEmpty {
                    Text(user.bio)
                        .font(.system(size: app.settings.fontSize))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 0) {
                    stat("动态", user.feedCount)
                    stat("关注", user.followCount)
                    stat("粉丝", user.fansCount)
                    stat("获赞", user.beLikedCount)
                }
                HStack(spacing: 14) {
                    if let registered = user.registerDate {
                        Label("\(Formatting.absolute(registered).prefix(10)) 加入", systemImage: "calendar")
                    }
                    if let login = user.loginTime {
                        Label("\(Formatting.relative(login))活跃", systemImage: "clock")
                    }
                    Spacer()
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.top, 14)
            .padding(.bottom, 4)
        }
        .frame(maxWidth: 1280)
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text(Formatting.count(value)).font(.system(size: 16, weight: .semibold).monospacedDigit())
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}
