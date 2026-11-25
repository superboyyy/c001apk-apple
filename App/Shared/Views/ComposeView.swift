import CoolapkKit
import ImageIO
import SwiftUI

/// 编辑器要发布的内容：新动态，或对动态 / 回复的回复。
enum ComposeTarget: Identifiable, Hashable {
    /// 新动态。`targetType` / `targetID` 指定发布到的话题（`tag`）、数码（`product_phone`）
    /// 或应用（`apk`），`title` 是它的名称；都不填就是普通动态。
    case feed(targetType: String? = nil, targetID: String? = nil, title: String? = nil)
    /// 回复动态（`type == .feed`，`id` 为动态编号）或回复某条回复（`.reply`，`id` 为回复编号）。
    case reply(id: String, type: CoolapkClient.ReplyTarget, username: String)

    var id: String {
        switch self {
        case .feed(let targetType, let targetID, _): return "feed#\(targetType ?? "")#\(targetID ?? "")"
        case .reply(let id, let type, _): return "reply#\(type.rawValue)#\(id)"
        }
    }
}

/// 发布动态与回复共用的编辑器：文字、表情、配图，以及上传和发布的进度。
/// 通常用 `View.composer(_:onFinish:)` 浮在页面上方；移植自上游的 `ReplyPage` / `ReplyDialog`。
struct ComposeView: View {
    let target: ComposeTarget
    /// 用户取消或发布完成后调用，由外层收起编辑器。
    var onClose: () -> Void
    /// 发布成功后回调服务端返回的新动态或新回复，随后调用 `onClose`。
    var onFinish: (Entity) -> Void = { _ in }

    static let maxLength = 500
    static let maxImages = 9

    /// 占位文字与 `TextEditor` 首行对齐所需的上边距，两个平台的内边距不同。
    private static var placeholderTopInset: CGFloat {
        #if os(macOS)
        0
        #else
        8
        #endif
    }

    private enum Stage: Equatable {
        case editing
        case uploading(index: Int, total: Int, fraction: Double)
        case publishing
    }

    /// 已经传完的一批图片；重试发布时不必再传一遍。
    private struct Uploaded {
        let imageIDs: [UUID]
        let pics: [String]
    }

    @Environment(AppModel.self) private var app

    @State private var text: String
    @State private var selection: TextSelection?
    @State private var images: [PickedImage] = []
    @State private var optionOn = false
    @State private var showsEmoji = false
    @State private var stage = Stage.editing
    @State private var failure: String?
    @State private var uploaded: Uploaded?
    @State private var captcha: CaptchaPrompt?
    @FocusState private var editorFocused: Bool

    init(target: ComposeTarget, onClose: @escaping () -> Void, onFinish: @escaping (Entity) -> Void = { _ in }) {
        self.target = target
        self.onClose = onClose
        self.onFinish = onFinish
        // 发到话题下时预先写好话题标签。
        if case .feed("tag"?, _, let title?) = target, !title.isEmpty {
            _text = State(initialValue: "#\(title)# ")
        } else {
            _text = State(initialValue: "")
        }
    }

    private var isReply: Bool {
        if case .reply = target { return true }
        return false
    }

    private var title: String {
        switch target {
        case .feed(_, _, let title?) where !title.isEmpty: return "发布于：\(title)"
        case .feed: return "发布动态"
        case .reply(_, _, let username): return "回复：\(username)"
        }
    }

    private var isBusy: Bool { stage != .editing }

    private var canPublish: Bool {
        !isBusy && app.isLoggedIn && text.count <= Self.maxLength
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            editor
            if !images.isEmpty { imageStrip }
            toolbar
            statusRow
            if showsEmoji {
                EmojiPanel { emoji in
                    TextInsertion.insert(emoji, into: &text, selection: &selection)
                }
                .frame(minHeight: 120, idealHeight: 200, maxHeight: 220)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: showsEmoji)
        .animation(.smooth(duration: 0.2), value: images)
        .onAppear { editorFocused = true }
        .sheet(item: $captcha) { prompt in
            CaptchaCodeSheet(prompt: prompt) { publish() }
        }
    }

    // MARK: 组成部分

    private var header: some View {
        HStack(spacing: 10) {
            Text(title).font(.headline).lineLimit(1)
            Spacer(minLength: 8)
            Button("取消", action: onClose)
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                .disabled(isBusy)
            Button(isReply ? "回复" : "发布", action: publish)
                .keyActionButtonStyle()
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canPublish)
                .help(isReply ? "回复（⌘↩）" : "发布（⌘↩）")
        }
    }

    private var editor: some View {
        TextEditor(text: $text, selection: $selection)
            .font(.system(size: app.settings.fontSize))
            .scrollContentBackground(.hidden)
            .focused($editorFocused)
            // 高度有弹性：窗口矮、又展开了表情面板时，编辑区先让出空间。
            .frame(minHeight: 72, idealHeight: 150, maxHeight: showsEmoji ? 140 : 240)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(isReply ? "写下你的回复…" : "分享点什么…")
                        .font(.system(size: app.settings.fontSize))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .padding(.top, Self.placeholderTopInset)
                        .allowsHitTesting(false)
                }
            }
            .disabled(isBusy)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(images) { image in
                    thumbnail(image)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func thumbnail(_ image: PickedImage) -> some View {
        Group {
            if let preview = image.thumbnail {
                Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary).overlay { Image(systemName: "photo").foregroundStyle(.tertiary) }
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            Button {
                images.removeAll { $0.id == image.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .padding(3)
            .disabled(isBusy)
            .accessibilityLabel("移除这张图片")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("已选图片，\(image.upload.resolution)")
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $showsEmoji) {
                Label("表情", systemImage: "face.smiling")
            }
            .toggleStyle(.button)
            .buttonStyle(.glass)
            .help("表情")

            ImagePickerMenu(limit: Self.maxImages - images.count) { picked in
                images.append(contentsOf: picked.prefix(Self.maxImages - images.count))
                failure = nil
            } onFailure: { message in
                failure = message
            } label: {
                Label("图片", systemImage: "photo")
            }
            .buttonStyle(.glass)
            .help(images.count >= Self.maxImages ? "最多选择 \(Self.maxImages) 张图片" : "添加图片")

            Toggle(isOn: $optionOn) {
                Label(isReply ? "回复并转发" : "仅自己可见", systemImage: isReply ? "arrowshape.turn.up.right" : "lock")
            }
            .toggleStyle(.button)
            .buttonStyle(.glass)

            Spacer(minLength: 8)
            Text("\(text.count)/\(Self.maxLength)")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(text.count > Self.maxLength ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .accessibilityLabel("已输入 \(text.count) 字，上限 \(Self.maxLength) 字")
        }
        .labelStyle(.titleAndIcon)
        .disabled(isBusy)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch stage {
        case .uploading(let index, let total, let fraction):
            VStack(alignment: .leading, spacing: 4) {
                Text("正在上传图片 \(index + 1)/\(total)").font(.system(size: 12)).foregroundStyle(.secondary)
                ProgressView(value: (Double(index) + fraction) / Double(max(total, 1)))
            }
        case .publishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(isReply ? "正在回复…" : "正在发布…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .editing:
            if !app.isLoggedIn {
                notice("登录后才能发布。", symbol: "person.crop.circle.badge.exclamationmark")
            } else if let failure {
                notice(failure, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private func notice(_ message: String, symbol: String) -> some View {
        Label(message, systemImage: symbol)
            .font(.system(size: 12))
            .foregroundStyle(.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: 发布

    private func publish() {
        guard canPublish else { return }
        let message = text
        let picked = images
        let option = optionOn
        let client = app.client
        failure = nil
        stage = picked.isEmpty ? .publishing : .uploading(index: 0, total: picked.count, fraction: 0)
        Task {
            defer { stage = .editing }
            do {
                let pics: [String]
                if picked.isEmpty {
                    pics = []
                } else if let uploaded, uploaded.imageIDs == picked.map(\.id) {
                    pics = uploaded.pics
                } else {
                    pics = try await CoolapkClient.interactive {
                        try await client.uploadImages(picked.map(\.upload), scope: .feed) { progress in
                            Task { @MainActor in
                                // 进度回调可能晚于完成到达，只在仍处于上传阶段时采用。
                                guard case .uploading = stage else { return }
                                stage = .uploading(index: progress.index, total: progress.total, fraction: progress.fraction)
                            }
                        }
                    }
                    uploaded = Uploaded(imageIDs: picked.map(\.id), pics: pics)
                }
                stage = .publishing
                let created = try await CoolapkClient.interactive {
                    switch target {
                    case .feed(let targetType, let targetID, _):
                        return try await client.createFeed(
                            message: message, pics: pics, targetType: targetType, targetID: targetID, onlySelf: option)
                    case .reply(let id, let type, _):
                        return try await client.postReply(id: id, type: type, message: message, pics: pics, forward: option)
                    }
                }
                app.showToast(isReply ? "回复成功" : "发布成功")
                onFinish(created)
                onClose()
            } catch {
                await handle(error)
            }
        }
    }

    private func handle(_ error: Error) async {
        let problem = APIError.from(error)
        if problem.kind == .captcha, problem.serverStatus == "err_request_captcha" {
            // 服务端要求输入图形验证码：取图、让用户填写，通过后自动重新发布。
            do {
                captcha = CaptchaPrompt(image: try await app.client.captchaImage())
                failure = "需要输入验证码后才能发布"
            } catch {
                failure = "无法获取验证码：\(APIError.from(error).message)"
            }
            return
        }
        failure = problem.message
    }
}

extension View {
    /// 在当前页面上方浮出编辑器；把 `target` 设为非空即打开，取消或发布完成后自动置空。
    /// 这里不用系统 sheet：发布途中可能要弹出登录或人机验证的 sheet，它们挂在根视图上，
    /// 被另一个 sheet 挡住时无法出现。
    func composer(
        _ target: Binding<ComposeTarget?>, onFinish: @escaping (ComposeTarget, Entity) -> Void = { _, _ in }
    ) -> some View {
        modifier(ComposerOverlay(target: target, onFinish: onFinish))
    }
}

/// `composer(_:onFinish:)` 的实现：半透明遮罩加一张贴着底部的玻璃卡片。
private struct ComposerOverlay: ViewModifier {
    @Binding var target: ComposeTarget?
    let onFinish: (ComposeTarget, Entity) -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                if let current = target {
                    ZStack(alignment: .bottom) {
                        // 遮罩挡住下层的点击；为免误触丢稿，点遮罩不关闭，用“取消”或 Esc。
                        Color.black.opacity(0.28)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture {}
                            .accessibilityHidden(true)
                        ComposeView(target: current, onClose: { target = nil }) { created in
                            onFinish(current, created)
                        }
                        .id(current.id)
                        .card(padding: 16)
                        .frame(maxWidth: 620)
                        .padding(16)
                        .accessibilityAddTraits(.isModal)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .animation(.smooth(duration: 0.25), value: target)
    }
}

/// 一次图形验证码输入。
private struct CaptchaPrompt: Identifiable {
    let id = UUID()
    let image: Data
}

/// 输入图形验证码的小窗；验证通过后调用 `onVerified`。
private struct CaptchaCodeSheet: View {
    let prompt: CaptchaPrompt
    let onVerified: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var imageData: Data?
    @State private var code = ""
    @State private var message: String?
    @State private var isWorking = false

    private var picture: CGImage? {
        guard let source = CGImageSourceCreateWithData((imageData ?? prompt.image) as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("验证码").font(.headline)
            HStack(spacing: 12) {
                Group {
                    if let picture {
                        Image(decorative: picture, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 135, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("验证码图片")
                TextField("验证码", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit(submit)
                    .onChange(of: code) { _, value in
                        let cleaned = String(value.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(4))
                        if cleaned != value { code = cleaned }
                    }
            }
            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(.orange)
            }
            HStack {
                Button("换一张", action: reload).buttonStyle(.glass).disabled(isWorking)
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("验证并继续", action: submit)
                    .keyActionButtonStyle()
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || code.isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 320)
    }

    private func reload() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                imageData = try await app.client.captchaImage()
                code = ""
            } catch {
                message = "无法获取验证码：\(APIError.from(error).message)"
            }
        }
    }

    private func submit() {
        guard !code.isEmpty, !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await app.client.submitCaptcha(code: code)
                dismiss()
                onVerified()
            } catch {
                let problem = APIError.from(error)
                message = problem.kind == .captcha ? "验证码不正确，请重新输入" : problem.message
                if problem.kind == .captcha || problem.kind == .business {
                    imageData = try? await app.client.captchaImage()
                    code = ""
                }
            }
        }
    }
}
