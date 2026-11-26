import CoolapkKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape") { GeneralSettings() }
            Tab("账号与设备", systemImage: "person.badge.key") { AccountSettings() }
            Tab("内容过滤", systemImage: "line.3.horizontal.decrease.circle") { FilterSettings() }
            Tab("屏蔽", systemImage: "hand.raised") { BlockSettings() }
            Tab("关于", systemImage: "info.circle") { AboutSettings() }
        }
        #if os(macOS)
        .frame(width: 600, height: 500)
        #endif
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @State private var cacheSize = 0

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section("外观") {
                Picker("主题", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("信息流列数", selection: $settings.columnMode) {
                    ForEach(ColumnMode.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("正文字号") {
                    HStack {
                        Slider(value: $settings.fontSize, in: 12...20, step: 1)
                            .frame(width: 200)
                        Text("\(Int(settings.fontSize))").monospacedDigit().frame(width: 24)
                    }
                }
            }
            Section("内容") {
                Toggle("显示酷安表情", isOn: $settings.showEmoji)
                Toggle("在信息流中显示热门评论", isOn: $settings.showReplyPreview)
                Toggle("信息流使用更清晰的缩略图", isOn: $settings.highQualityThumbnails)
                Toggle("记录浏览历史（仅本机）", isOn: $settings.recordHistory)
                Toggle("我不想看 HDR（大图始终用 SDR）", isOn: $settings.disableHDR)
                Toggle("自动播放实况图片", isOn: $settings.autoPlayLivePhotos)
            }
            Section("存储") {
                LabeledContent("图片缓存") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file))
                            .foregroundStyle(.secondary)
                        Button("清除") {
                            ImagePipeline.shared.clearCaches()
                            cacheSize = 0
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { cacheSize = ImagePipeline.shared.diskUsage }
    }
}

private struct AccountSettings: View {
    @Environment(AppModel.self) private var app
    @State private var versionName = ""
    @State private var versionCode = ""
    @State private var apiVersion = ""
    @State private var confirmsRegenerate = false
    @State private var isShowingDeviceIdentity = false

    var body: some View {
        Form {
            Section("账号") {
                if app.accounts.isEmpty {
                    LabeledContent("当前账号", value: "游客")
                }
                ForEach(app.accounts) { account in
                    HStack(spacing: 8) {
                        AvatarView(url: account.avatar, size: 22)
                        Text(account.displayName)
                        Text("UID \(account.uid)").foregroundStyle(.secondary)
                        Spacer()
                        if account.uid == app.account?.uid {
                            Text("当前").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("切换") { app.switchAccount(to: account.uid) }
                        }
                        Button("移除", role: .destructive) { app.removeAccount(uid: account.uid) }
                    }
                }
                Button(app.accounts.isEmpty ? "登录酷安…" : "添加账号…") { app.isShowingLogin = true }
                Text("登录在酷安官方页面完成，登录凭证保存在系统钥匙串中。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("协议参数") {
                TextField("版本名", text: $versionName)
                TextField("版本号", text: $versionCode)
                TextField("API 版本", text: $apiVersion)
                HStack {
                    Button("应用") {
                        let name = versionName.trimmingCharacters(in: .whitespaces)
                        let code = versionCode.trimmingCharacters(in: .whitespaces)
                        let api = apiVersion.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, Int(code) != nil, !api.isEmpty else {
                            app.showToast("参数格式不正确")
                            return
                        }
                        app.updateIdentity {
                            $0.versionName = name
                            $0.versionCode = code
                            $0.apiVersion = api
                        }
                        app.showToast("已更新协议参数")
                    }
                    Button("恢复默认") {
                        app.updateIdentity {
                            $0.versionName = ClientIdentity.defaultVersionName
                            $0.versionCode = ClientIdentity.defaultVersionCode
                            $0.apiVersion = ClientIdentity.defaultAPIVersion
                        }
                        sync()
                    }
                }
                Text("仅当服务端提示“客户端协议未被接受”时才需要调整。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("数盟设备标识") {
                SzlmAcquisitionView(
                    trailingActionTitle: "手动导入…",
                    onTrailingAction: { isShowingDeviceIdentity = true }
                )
            }
            Section("设备") {
                LabeledContent("兼容设备", value: "\(app.identity.manufacturer) \(app.identity.model) · Android \(app.identity.androidVersion)")
                Button("重新生成设备参数…") { confirmsRegenerate = true }
                Text("本应用以一组固定的兼容参数访问酷安接口，不读取这台设备的硬件信息。重新生成后可能需要再次完成人机验证。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: sync)
        .sheet(isPresented: $isShowingDeviceIdentity) {
            DeviceIdentitySheet()
        }
        .confirmationDialog("重新生成设备参数？", isPresented: $confirmsRegenerate) {
            Button("重新生成", role: .destructive) { app.regenerateDevice() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(app.hasSzlmID
                 ? "会生成新的随机安装标识，并清除已保存的数盟 ID 与当前会话。"
                 : "会生成新的安装标识并清除当前会话。")
        }
    }

    private func sync() {
        versionName = app.identity.versionName
        versionCode = app.identity.versionCode
        apiVersion = app.identity.apiVersion
    }
}

private struct FilterSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ContentFilterSettingsView(store: app.contentFilter)
    }
}

private struct BlockSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.library.blocked.isEmpty {
                ContentUnavailableView("没有屏蔽的用户", systemImage: "hand.raised",
                                       description: Text("在帖子或用户主页的菜单中选择“屏蔽”，其内容将不再出现在这台 Mac 的列表里。不会调用账号的拉黑接口。"))
            } else {
                List(app.library.blocked) { user in
                    HStack {
                        Text(user.username)
                        Text("UID \(user.uid)").foregroundStyle(.secondary)
                        Spacer()
                        Button("取消屏蔽") { app.library.unblock(uid: user.uid) }
                    }
                }
            }
        }
    }
}

private struct AboutSettings: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 12) {
            AppIconView()
                .frame(width: 88, height: 88)
            Text("酷果").font(.title2.bold())
            #if os(macOS)
            Text("macOS 版 \(version) · SwiftUI + AppKit").foregroundStyle(.secondary)
            #else
            Text("iPadOS 版 \(version) · SwiftUI + UIKit").foregroundStyle(.secondary)
            #endif
            Text("轻量的非官方酷安客户端。协议实现参考 c001apk（Flutter）与 coolapk-desktop。\n本项目与酷安官方无隶属关系，酷安名称、商标及服务内容归相应权利人所有。")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            HStack(spacing: 10) {
                Link("上游项目", destination: URL(string: "https://github.com/TG-Twilight/c001apk")!)
                Link("GNU AGPL v3", destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!)
            }
            .buttonStyle(.glass)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 关于页里的应用图标：macOS 取真实图标，iPadOS 画一个同款标识。
private struct AppIconView: View {
    var body: some View {
        #if os(macOS)
        Image(nsImage: NSApp.applicationIconImage).resizable()
        #else
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(Color.brandFill)
            .overlay {
                Image(systemName: "infinity")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
            }
        #endif
    }
}
