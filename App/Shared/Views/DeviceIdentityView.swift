import CoolapkKit
import SwiftUI

/// 获取数盟设备 ID 的状态、操作按钮与冷却提示，复用于设置页和独立弹窗。
struct SzlmAcquisitionView: View {
    @Environment(AppModel.self) private var app
    var onAcquired: (() -> Void)?
    var trailingActionTitle: String?
    var onTrailingAction: (() -> Void)?

    @State private var message: String?
    @State private var failed = false
    @State private var tick = 0

    private var nextAllowedAt: Date? {
        _ = tick
        return app.szlmNextAllowedAt
    }

    private var unavailableReason: String? {
        _ = tick
        return app.szlmUnavailableReason
    }

    var body: some View {
        let hasID = app.hasSzlmID
        let reason = unavailableReason
        let next = nextAllowedAt
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: hasID ? "checkmark.seal.fill" : "key.horizontal")
                    .foregroundStyle(hasID ? Color.green : Color.secondary)
                Text(hasID ? "已保存设备标识，将继续使用" : "本机尚未保存设备标识")
                    .font(.callout.weight(.medium))
            }

            Text("数盟 ID 用于酷安请求首字段，有助于减少重复人机验证。点击获取会向数字联盟发送不含账号信息的设备报文，标识仅保存在本机。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    Task { await acquire() }
                } label: {
                    HStack(spacing: 6) {
                        if app.isFetchingSzlmID {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "key")
                        }
                        Text(app.isFetchingSzlmID
                             ? "正在获取…"
                             : (hasID ? "重新获取数盟 ID" : "获取数盟 ID"))
                    }
                }
                .disabled(app.isFetchingSzlmID || reason != nil)

                if let trailingActionTitle, let onTrailingAction {
                    Button(trailingActionTitle, action: onTrailingAction)
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(failed ? Color.red : Color.accentColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let next {
                Text("可再次获取时间：\(SzlmIdentityService.formatLocalDateTime(next))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("仅主动点击时获取，不会自动更换。成功获取后需间隔 7 天（再次获取间隔，并非标识有效期）；失败后也有冷却与次数限制。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: nextAllowedAt) {
            guard let target = nextAllowedAt else { return }
            let remaining = target.timeIntervalSinceNow
            let delay = (remaining > 60 || remaining < 0) ? 60.0 : (remaining + 0.15)
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.15) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            tick &+= 1
        }
    }

    private func acquire() async {
        guard !app.isFetchingSzlmID, unavailableReason == nil else { return }
        message = nil
        failed = false
        do {
            try await app.acquireSzlmID()
            message = "已获取并保存设备标识，返回内容页刷新即可。"
            failed = false
            onAcquired?()
        } catch let error as SzlmDuidError {
            failed = true
            message = error.message
        } catch let error as OfficialDeviceIdentityError {
            failed = true
            message = error.message
        } catch {
            failed = true
            message = "获取或保存失败，请稍后重试，也可使用手动导入。"
        }
        tick &+= 1
    }
}

/// 完整的数盟设备标识弹窗：包含自动获取与从官方酷安手动粘贴导入（兜底）。
struct DeviceIdentitySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var onApplied: (() -> Void)?

    @State private var inputText = ""
    @State private var pendingText: String?
    @State private var importError: String?
    @State private var importSaved = false
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("数盟设备标识", systemImage: "key.horizontal")
                    .font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            Form {
                Section("获取数盟 ID") {
                    SzlmAcquisitionView(onAcquired: {
                        pendingText = nil
                        importError = nil
                        importSaved = false
                        onApplied?()
                    })
                }
                Section("手动导入（兜底）") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("也可从 Android 官方酷安手动导入，不占用获取次数：\n1. 进入官方酷安“检查日志和测试”页（OAID 界面）。\n2. 向下找到“复制 OAID”，在同一页面累计点击 5 次。\n3. 将复制的完整内容传到本机，在下方粘贴并保存。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Link(destination: OfficialDeviceIdentity.guideURL) {
                                Label("仓库图文说明", systemImage: "questionmark.circle")
                            }
                            .font(.caption)
                        }

                        Text("虽然官方按钮叫“复制 OAID”，这里实际只提取其中的 ShuzlmID（数盟 ID）。其余字段会被忽略，不会保存 AndroidID、UUID 等复制内容。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        TextField("粘贴官方复制的完整文本（含 ShuzlmID 字段）", text: $inputText, axis: .vertical)
                            .lineLimit(2...4)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .disabled(isSaving)
                            .onChange(of: inputText) { _, newValue in
                                guard !newValue.isEmpty else {
                                    if pendingText == nil { importError = nil }
                                    return
                                }
                                recognize(newValue)
                            }

                        if pendingText != nil {
                            Text("已识别数盟 ID，复制内容已隐藏。点击“保存并应用”后生效。")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        if importSaved {
                            Text("已保存。返回内容页后刷新即可，机型及其他设备参数已保留。")
                                .font(.caption)
                                .foregroundStyle(Color.green)
                        }
                        if let importError {
                            Text(importError)
                                .font(.caption)
                                .foregroundStyle(Color.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        HStack(spacing: 10) {
                            Button {
                                pasteFromClipboard()
                            } label: {
                                Label("粘贴并识别", systemImage: "doc.on.clipboard")
                            }
                            .disabled(isSaving)

                            Button(isSaving ? "正在保存…" : "保存并应用") {
                                savePending()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(pendingText == nil || isSaving)
                        }

                        Text("标识保存在本机，只用于酷安请求。请勿将复制内容或真实标识公开。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .formStyle(.grouped)
        }
        #if os(macOS)
        .frame(width: 520, height: 580)
        #endif
    }

    private func recognize(_ text: String) {
        do {
            let id = try OfficialDeviceIdentity.parse(text)
            inputText = ""
            pendingText = "ShuzlmID: \(id)"
            importError = nil
            importSaved = false
        } catch let error as OfficialDeviceIdentityError {
            pendingText = nil
            importError = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : error.message
            importSaved = false
        } catch {
            pendingText = nil
            importError = "数盟 ID 格式不正确，请重新从官方酷安复制"
            importSaved = false
        }
    }

    private func pasteFromClipboard() {
        pendingText = nil
        importSaved = false
        importError = nil
        guard let text = Platform.pasteText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            importError = "剪贴板没有文本，请先从官方酷安完成复制"
            return
        }
        recognize(text)
    }

    private func savePending() {
        guard let value = pendingText, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try app.importOfficialDeviceIdentity(value)
            pendingText = nil
            importSaved = true
            importError = nil
            app.showToast("已保存数盟设备标识")
            onApplied?()
        } catch let error as OfficialDeviceIdentityError {
            importError = error.message
        } catch {
            importError = "保存失败，请稍后重试"
        }
    }
}
