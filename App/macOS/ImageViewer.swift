import AppKit
import AVFoundation
import CoolapkKit
import UniformTypeIdentifiers

/// 原生图片窗口：捏合或滚动缩放、方向键翻页、拷贝、存储、共享，支持 HDR 显示与实况播放。
/// 用 AppKit 实现（`NSScrollView` 缩放 + `NSGlassEffectView` 控制条）。
@MainActor
enum ImageViewer {
    private static var controller: ImageViewerWindowController?

    /// 只有图片地址时的入口；实况与 HDR 按文件名标记和图片内容判断。
    static func show(urls: [String], index: Int) {
        show(media: urls.map { FeedMedia(url: $0) }, index: index)
    }

    /// 带素材元数据的入口，`index` 是要先显示的那一张。
    static func show(media: [FeedMedia], index: Int) {
        let valid = media.filter { ImageURL.normalized($0.originalURL) != nil }
        guard !valid.isEmpty else { return }
        let start = media.indices.contains(index) ? (valid.firstIndex(of: media[index]) ?? 0) : 0
        if let controller {
            controller.present(items: valid, index: start)
        } else {
            let created = ImageViewerWindowController()
            created.onClose = { controller = nil }
            controller = created
            created.present(items: valid, index: start)
        }
    }
}

/// 文档比可见区域小时让它保持居中。
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let frame = documentView.frame
        if frame.width < rect.width { rect.origin.x = (frame.width - rect.width) / 2 }
        if frame.height < rect.height { rect.origin.y = (frame.height - rect.height) / 2 }
        return rect
    }
}

@MainActor
final class ImageViewerWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    /// 取原图字节的方式，默认走图片管线；单独留出来便于不联网时检查查看器。
    var loadData: (URL) async throws -> Data = { try await ImagePipeline.shared.data(for: $0) }

    private var items: [FeedMedia] = []
    private var index = 0
    private var currentData: Data?
    private var currentVideo: LivePhotoVideo?
    private var loadTask: Task<Void, Never>?
    private var fitsWindow = true

    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    private let playback = LivePhotoPlayback()
    private lazy var playerView = PlayerLayerHostView(player: playback.player)
    private let spinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let counterLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeGlass = NSGlassEffectView()
    private var previousButton: NSButton!
    private var nextButton: NSButton!
    private var fitButton: NSButton!
    private var shareButton: NSButton!
    private var liveButton: NSButton!
    private var muteButton: NSButton!
    private var liveSeparator: NSView!

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.07, alpha: 1)
        window.minSize = NSSize(width: 480, height: 320)
        window.setFrameAutosaveName("ImageViewer")
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildContent()
        playback.onStateChange = { [weak self] _ in self?.updateLiveControls() }
        if window.frameAutosaveName.isEmpty || !window.setFrameUsingName("ImageViewer") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持从归档创建") }

    // MARK: 布局

    private func buildContent() {
        guard let window, let content = window.contentView else { return }

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 12
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleAxesIndependently
        imageView.animates = true
        imageView.imageFrameStyle = .none
        scrollView.documentView = imageView
        content.addSubview(scrollView)

        // 实况画面盖在静态图上，随图片一起缩放；不播放时隐藏。
        playerView.frame = imageView.bounds
        playerView.autoresizingMask = [.width, .height]
        playerView.isHidden = true
        imageView.addSubview(playerView)

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(toggleFit))
        doubleClick.numberOfClicksRequired = 2
        doubleClick.delaysPrimaryMouseButtonEvents = false
        scrollView.addGestureRecognizer(doubleClick)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(spinner)

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isHidden = true
        content.addSubview(statusLabel)

        // 左上角的“实况 / HDR”标记。
        badgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        badgeLabel.textColor = .labelColor
        let badgeStack = NSStackView(views: [badgeLabel])
        badgeStack.edgeInsets = NSEdgeInsets(top: 3, left: 9, bottom: 3, right: 9)
        badgeGlass.cornerRadius = 11
        badgeGlass.contentView = badgeStack
        badgeGlass.translatesAutoresizingMaskIntoConstraints = false
        badgeGlass.isHidden = true
        content.addSubview(badgeGlass)

        // 悬浮的 Liquid Glass 控制条。
        previousButton = makeButton("chevron.left", "上一张", #selector(showPrevious))
        nextButton = makeButton("chevron.right", "下一张", #selector(showNext))
        fitButton = makeButton("arrow.up.left.and.arrow.down.right", "实际大小 / 适应窗口", #selector(toggleFit))
        shareButton = makeButton("square.and.arrow.up", "共享", #selector(share(_:)))
        liveButton = makeButton("livephoto.play", "循环播放实况", #selector(toggleLive))
        muteButton = makeButton("speaker.slash", "打开实况声音", #selector(toggleMute))
        liveSeparator = separator()
        counterLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        counterLabel.textColor = .labelColor
        counterLabel.alignment = .center
        counterLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [
            previousButton, counterLabel, nextButton, separator(),
            makeButton("minus.magnifyingglass", "缩小", #selector(zoomOut)),
            makeButton("plus.magnifyingglass", "放大", #selector(zoomIn)),
            fitButton, separator(),
            liveButton, muteButton, liveSeparator,
            makeButton("doc.on.doc", "拷贝图片", #selector(copyImage)),
            makeButton("square.and.arrow.down", "存储原件…", #selector(saveImage)),
            shareButton,
        ])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

        let glass = NSGlassEffectView()
        glass.cornerRadius = 22
        glass.contentView = stack
        glass.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(glass)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            badgeGlass.heightAnchor.constraint(equalToConstant: 22),
            badgeGlass.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            badgeGlass.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 10),
            glass.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            glass.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            glass.heightAnchor.constraint(equalToConstant: 44),
        ])
        updateLiveControls()
    }

    private func makeButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .glass
        button.imagePosition = .imageOnly
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.contentTintColor = .labelColor
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.widthAnchor.constraint(equalToConstant: 30).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func setButton(_ button: NSButton, symbol: String, tooltip: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return box
    }

    // MARK: 内容

    func present(items: [FeedMedia], index: Int) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        show(items: items, index: index)
    }

    /// 换一组图片并载入其中一张，不改变窗口的显示状态。
    func show(items: [FeedMedia], index: Int) {
        self.items = items
        self.index = min(max(index, 0), items.count - 1)
        load()
    }

    private func load() {
        loadTask?.cancel()
        clearLive()
        guard items.indices.contains(index), let url = ImageURL.normalized(items[index].originalURL) else { return }
        let item = items[index]
        window?.title = items.count > 1 ? "图片 \(index + 1) / \(items.count)" : "图片"
        counterLabel.stringValue = "\(index + 1) / \(items.count)"
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index < items.count - 1
        previousButton.isHidden = items.count < 2
        nextButton.isHidden = items.count < 2
        counterLabel.isHidden = items.count < 2
        statusLabel.isHidden = true
        badgeGlass.isHidden = true
        imageView.image = nil
        currentData = nil
        fitsWindow = true
        spinner.startAnimation(nil)

        // “我不想看 HDR”只影响静态大图；每次载入时读取，改设置后翻页即生效。
        let allowHDR = !AppSettings.isHDRDisabled
        let loadData = loadData
        loadTask = Task { [weak self] in
            let data = try? await loadData(url)
            // 解码放到后台，大图不卡住窗口。
            let decoded = await Task.detached(priority: .userInitiated) {
                data.flatMap { HDRImage.platformImage(from: $0, allowHDR: allowHDR) }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.spinner.stopAnimation(nil)
            guard let data, let decoded else {
                self.statusLabel.stringValue = "图片加载失败"
                self.statusLabel.isHidden = false
                return
            }
            self.currentData = data
            self.display(decoded.image, showsHDR: decoded.isHDR && allowHDR)

            // 实况：元数据标明、带视频地址，或图片自身声明了内嵌视频时才去取视频。
            let isLive = item.isLivePhoto || item.videoURL != nil || MotionPhoto.declaresVideo(data)
            self.updateBadge(isLive: isLive, videoMissing: false, isHDR: decoded.isHDR, showsHDR: decoded.isHDR && allowHDR)
            guard isLive else { return }
            guard let video = await LivePhotoLoader.video(for: item, imageData: data) else {
                if !Task.isCancelled {
                    self.updateBadge(isLive: true, videoMissing: true, isHDR: decoded.isHDR, showsHDR: decoded.isHDR && allowHDR)
                }
                return
            }
            guard !Task.isCancelled else {
                LivePhotoLoader.discard(video)
                return
            }
            self.currentVideo = video
            self.playback.load(video.fileURL)
            self.updateLiveControls()
            if AppSettings.autoPlaysLivePhotos { self.playback.playOnce() }
        }
    }

    private func display(_ image: NSImage, showsHDR: Bool) {
        var size = image.size
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        // 100% 时一个图片像素对应一个设备像素。
        let scale = window?.backingScaleFactor ?? 2
        size = NSSize(width: size.width / scale, height: size.height / scale)
        image.size = size
        // 在支持的显示器上放开高光；否则限制在标准动态范围。
        imageView.preferredImageDynamicRange = showsHDR ? .high : .standard
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: size)
        applyFit(animated: false)
    }

    /// 更新左上角标记的文字与说明。
    private func updateBadge(isLive: Bool, videoMissing: Bool, isHDR: Bool, showsHDR: Bool) {
        var parts: [String] = []
        var tips: [String] = []
        if isLive {
            parts.append(videoMissing ? "实况（无视频）" : "实况")
            tips.append(videoMissing ? "实况图片，但没有取得可播放的视频" : "实况图片")
        }
        if isHDR {
            let screenSupportsHDR = (window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
            if !showsHDR {
                parts.append("HDR 已关闭")
                tips.append("已在设置中选择“我不想看 HDR”，按 SDR 显示")
            } else {
                parts.append("HDR")
                tips.append(screenSupportsHDR ? "HDR 图片" : "HDR 图片；当前显示器不支持 HDR，按 SDR 显示")
            }
        }
        badgeLabel.stringValue = parts.joined(separator: " · ")
        badgeGlass.toolTip = tips.joined(separator: "\n")
        badgeGlass.setAccessibilityLabel(tips.joined(separator: "，"))
        badgeGlass.isHidden = parts.isEmpty
    }

    private var fitMagnification: CGFloat {
        guard let size = imageView.image?.size, size.width > 0, size.height > 0 else { return 1 }
        let bounds = scrollView.bounds.insetBy(dx: 16, dy: 16)
        return min(bounds.width / size.width, (bounds.height - 60) / size.height, 1)
    }

    private func applyFit(animated: Bool) {
        let target = fitsWindow ? fitMagnification : 1
        if animated {
            scrollView.animator().magnification = target
        } else {
            scrollView.magnification = target
        }
        let symbol = fitsWindow ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left"
        fitButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: fitButton.toolTip)
    }

    // MARK: 实况

    /// 停止播放并清掉当前图片的实况视频。
    private func clearLive() {
        playback.load(nil)
        if let currentVideo { LivePhotoLoader.discard(currentVideo) }
        currentVideo = nil
        updateLiveControls()
    }

    /// 让控制条按钮和视频画面跟随播放状态。
    private func updateLiveControls() {
        let hasVideo = playback.hasVideo
        liveButton.isHidden = !hasVideo
        muteButton.isHidden = !hasVideo
        liveSeparator.isHidden = !hasVideo
        let looping = playback.state == .looping
        setButton(liveButton, symbol: looping ? "stop.fill" : "livephoto.play",
                  tooltip: looping ? "停止播放实况" : "循环播放实况")
        setButton(muteButton, symbol: playback.isMuted ? "speaker.slash" : "speaker.wave.2",
                  tooltip: playback.isMuted ? "打开实况声音" : "关闭实况声音")

        let playing = playback.state != .idle
        if playing { playerView.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            playerView.animator().alphaValue = playing ? 1 : 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.playback.state == .idle else { return }
                self.playerView.isHidden = true
            }
        }
    }

    @objc private func toggleLive() {
        playback.toggleLoop()
    }

    @objc private func toggleMute() {
        playback.isMuted.toggle()
        updateLiveControls()
    }

    // MARK: 操作

    @objc private func showPrevious() {
        guard index > 0 else { return }
        index -= 1
        load()
    }

    @objc private func showNext() {
        guard index < items.count - 1 else { return }
        index += 1
        load()
    }

    @objc private func toggleFit() {
        fitsWindow.toggle()
        applyFit(animated: true)
    }

    @objc private func zoomIn() {
        fitsWindow = false
        scrollView.animator().magnification = min(scrollView.magnification * 1.4, scrollView.maxMagnification)
    }

    @objc private func zoomOut() {
        fitsWindow = false
        scrollView.animator().magnification = max(scrollView.magnification / 1.4, scrollView.minMagnification)
    }

    @objc private func copyImage() {
        guard let image = imageView.image else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private var suggestedFileName: String {
        guard items.indices.contains(index), let url = ImageURL.normalized(items[index].originalURL) else {
            return "image.jpg"
        }
        let name = url.lastPathComponent
        return name.isEmpty ? "image.jpg" : name
    }

    /// 存储原件：普通图片存一个文件；实况同时存图片和视频，需要选一个文件夹。
    @objc private func saveImage() {
        guard let data = currentData, let window else { return }
        if let video = currentVideo {
            saveLivePhoto(image: data, video: video, in: window)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try data.write(to: destination, options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// 沙盒里保存面板只授权单个文件，所以实况的两个原件写进用户选定的文件夹。
    private func saveLivePhoto(image: Data, video: LivePhotoVideo, in window: NSWindow) {
        let imageName = suggestedFileName
        let videoName = (imageName as NSString).deletingPathExtension + "." + video.fileExtension
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "存储"
        panel.message = "选择文件夹，实况的图片与视频原件会一起存到这里"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let folder = panel.url else { return }
            do {
                try image.write(to: Self.availableURL(in: folder, name: imageName), options: .atomic)
                try video.data.write(to: Self.availableURL(in: folder, name: videoName), options: .atomic)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    /// 同名文件已存在时在文件名后加序号，不覆盖原有文件。
    private static func availableURL(in folder: URL, name: String) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(number)").appendingPathExtension(ext)
            number += 1
        }
        return candidate
    }

    @objc private func share(_ sender: NSButton) {
        guard let image = imageView.image else { return }
        NSSharingServicePicker(items: [image]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    // MARK: 键盘与窗口

    override func keyDown(with event: NSEvent) {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 123, 126: showPrevious()      // ← ↑
        case 124, 125: showNext()          // → ↓
        case 49: toggleFit()               // 空格
        case 53: close()                   // Esc
        default:
            switch event.charactersIgnoringModifiers {
            case "c" where command: copyImage()
            case "s" where command: saveImage()
            case "=" where command, "+" where command: zoomIn()
            case "-" where command: zoomOut()
            case "0" where command: fitsWindow = true; applyFit(animated: true)
            case "l" where !command && playback.hasVideo: toggleLive()
            case "m" where !command && playback.hasVideo: toggleMute()
            default: super.keyDown(with: event)
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        if fitsWindow { applyFit(animated: false) }
    }

    func windowWillClose(_ notification: Notification) {
        loadTask?.cancel()
        clearLive()
        imageView.image = nil
        currentData = nil
        onClose?()
    }
}
