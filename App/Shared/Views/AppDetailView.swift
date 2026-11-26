import CoolapkKit
import SwiftUI

/// 应用页：信息、截图和社区评论。
struct AppDetailView: View {
    /// 包名或数字应用 id。
    let key: String

    @Environment(AppModel.self) private var app
    @State private var detail: Entity?
    @State private var failure: APIError?
    @State private var comments: PagedList?
    @State private var loadedKey: String?

    var body: some View {
        Group {
            if let detail, let comments {
                EntityListView(model: comments) {
                    AppHeader(detail: detail)
                    HStack {
                        Text("评论").font(.system(size: 15, weight: .semibold))
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .frame(maxWidth: 1280)
                }
            } else if let failure {
                FailureView(error: failure) { interactive in
                    Task { await load(interactive: interactive) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .routeTitle(detail?.title ?? "应用")
        .task(id: key) {
            // 从下级页面返回时保留应用详情与评论滚动位置。
            guard loadedKey != key || detail == nil || comments == nil else { return }
            await load(interactive: false)
        }
    }

    private func load(interactive: Bool) async {
        failure = nil
        let client = app.client
        do {
            let loaded = interactive
                ? try await CoolapkClient.interactive { try await client.appDetail(id: key) }
                : try await client.appDetail(id: key)
            let id = loaded.entityID
            detail = loaded
            loadedKey = key
            comments = PagedList { request in
                try await client.dataList(url: "/page?url=/feed/apkCommentList?id=\(id)", title: "", page: request.page,
                                          firstItem: request.firstItem, lastItem: request.lastItem)
            }
        } catch {
            failure = APIError.from(error)
        }
    }
}

private struct AppHeader: View {
    let detail: Entity

    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                RemoteImage(detail.logo, maxPixel: 300, contentMode: .fit)
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 5) {
                    Text(detail.title).font(.system(size: 20, weight: .bold)).textSelection(.enabled)
                    Text([detail["apkversionname"].string, detail["apksize"].string, detail["catName"].string]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text([detail["downCount"].string.map { "\($0) 下载" }, detail["followCount"].string.map { "\($0) 关注" },
                          detail["commentCount"].string.map { "\($0) 评论" }, detail["score"].text.map { "评分 \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if let package = detail["apkname"].text {
                        Text(package).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 8)
                if let package = detail["apkname"].text, let url = LinkRouter.webURL(for: .app(package)) {
                    VStack(spacing: 8) {
                        Button {
                            Platform.open(url)
                        } label: {
                            Label("在酷安网页查看", systemImage: "safari")
                        }
                        .buttonStyle(.glass)
                        ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                            .buttonStyle(.glass)
                    }
                }
            }
            let screenshots = Entity.pictureList(detail["screenList"])
            let thumbnails = Entity.pictureList(detail["thumbList"])
            if !screenshots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(screenshots.enumerated()), id: \.offset) { index, shot in
                            Button {
                                ImageViewer.show(urls: screenshots, index: index)
                            } label: {
                                let size = ImageURL.pixelSize(shot) ?? CGSize(width: 9, height: 16)
                                RemoteImage(thumbnails.indices.contains(index) ? thumbnails[index] : shot,
                                            maxPixel: 700, contentMode: .fit)
                                    .frame(width: 200 * size.width / size.height, height: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看第 \(index + 1) 张截图")
                        }
                    }
                }
                .frame(height: 200)
            }
            if let introduce = detail["introduce"].text ?? detail["description"].text {
                section("简介", RichText.plainText(introduce).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let changelog = detail["changelog"].text {
                section("更新日志", changelog)
            }
            Text("macOS 版仅用于浏览应用信息与讨论，不提供 APK 下载。")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .card(padding: 18)
        .frame(maxWidth: 1280)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.system(size: app.settings.fontSize - 0.5))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension Entity {
    /// 纯 `[String]` 的 URL 数组，如 `screenList`。
    static func pictureList(_ value: JSON) -> [String] {
        (value.array ?? []).compactMap(\.text)
    }
}
