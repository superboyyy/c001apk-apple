import AVFoundation
import CoolapkKit
import UIKit

/// iPadOS 的图片查看器：原生 `UIPageViewController` 横向翻页、每页独立 `UIScrollView` 缩放、
/// 下拉关闭、实况播放、HDR、拷贝与分享。
/// 使用 `.overFullScreen` 呈现，避免关闭时底层页面触发 `viewDidAppear` 导致列表/详情重新刷新。
@MainActor
enum ImageViewer {
    private static weak var activeController: ImageViewerViewController?

    static func show(urls: [String], index: Int) {
        show(media: urls.map { FeedMedia(url: $0) }, index: index)
    }

    /// 带素材元数据的入口：能识别实况并播放视频。
    static func show(media: [FeedMedia], index: Int) {
        let valid = media.filter { ImageURL.normalized($0.originalURL) != nil }
        guard !valid.isEmpty else { return }
        let start = media.indices.contains(index) ? (valid.firstIndex(of: media[index]) ?? 0) : 0

        // 防止连点或手势穿透叠加多个全屏查看器。
        if let existing = activeController, existing.presentingViewController != nil, !existing.isBeingDismissed {
            return
        }
        guard let presenter = topViewController(), !presenter.isBeingPresented, !presenter.isBeingDismissed else {
            return
        }

        let viewer = ImageViewerViewController(items: valid, startIndex: start)
        viewer.modalPresentationStyle = .overFullScreen
        viewer.modalTransitionStyle = .crossDissolve
        viewer.modalPresentationCapturesStatusBarAppearance = true
        activeController = viewer
        presenter.present(viewer, animated: true)
    }

    /// 当前最上层的视图控制器，用来弹出查看器。
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene?.keyWindow ?? scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - 查看器主容器

@MainActor
private final class ImageViewerViewController: UIViewController,
    UIPageViewControllerDataSource,
    UIPageViewControllerDelegate,
    UIGestureRecognizerDelegate
{
    private let items: [FeedMedia]
    private var currentIndex: Int
    private var isDismissing = false
    private var chromeVisible = true

    private let backdropView = UIView()
    private let pageController: UIPageViewController

    private let closeButton = UIButton(type: .system)
    private let badgeContainer = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let badgeLabel = UILabel()

    private let controlsContainer = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let controlsStack = UIStackView()
    private let counterLabel = UILabel()
    private let liveButton = UIButton(type: .system)
    private let muteButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)

    private let playback = LivePhotoPlayback()
    private var currentVideo: LivePhotoVideo?
    private var liveTask: Task<Void, Never>?
    private var copyFeedbackTask: Task<Void, Never>?
    private var prefetchTasks: [Int: Task<Void, Never>] = [:]

    private var currentPage: ImagePageViewController? {
        pageController.viewControllers?.first as? ImagePageViewController
    }

    init(items: [FeedMedia], startIndex: Int) {
        self.items = items
        self.currentIndex = min(max(startIndex, 0), items.count - 1)
        self.pageController = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal,
            options: [.interPageSpacing: 20]
        )
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = .dark
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持从归档创建") }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var prefersStatusBarHidden: Bool { !chromeVisible }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        backdropView.backgroundColor = .black
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdropView)

        pageController.dataSource = self
        pageController.delegate = self
        addChild(pageController)
        pageController.view.backgroundColor = .clear
        pageController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)

        buildChrome()

        NSLayoutConstraint.activate([
            backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdropView.topAnchor.constraint(equalTo: view.topAnchor),
            backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            pageController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageController.view.topAnchor.constraint(equalTo: view.topAnchor),
            pageController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let dismissPan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
        dismissPan.delegate = self
        view.addGestureRecognizer(dismissPan)

        playback.onStateChange = { [weak self] _ in
            self?.syncLiveState()
        }

        let initialPage = makePage(at: currentIndex)
        pageController.setViewControllers([initialPage], direction: .forward, animated: false)
        onPageActivated(initialPage)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            cleanupResources()
        }
    }

    deinit {
        liveTask?.cancel()
        copyFeedbackTask?.cancel()
        for task in prefetchTasks.values { task.cancel() }
    }

    // MARK: - 界面控件

    private func buildChrome() {
        // 关闭按钮放在右上角（避开 iPadOS 26 左上角窗口控制按钮），保证 44×44pt 触控热区。
        var closeConfig = UIButton.Configuration.glass()
        closeConfig.image = UIImage(
            systemName: "xmark",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )
        closeConfig.cornerStyle = .capsule
        closeConfig.baseForegroundColor = .white
        closeButton.configuration = closeConfig
        closeButton.accessibilityLabel = "关闭"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        // 顶部居中的实况 / HDR 标记，同样避开左上角系统控件。
        badgeContainer.layer.cornerRadius = 13
        badgeContainer.clipsToBounds = true
        badgeContainer.isHidden = true
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.contentView.addSubview(badgeLabel)
        view.addSubview(badgeContainer)

        // 底部 Liquid Glass 控制条。
        controlsContainer.layer.cornerRadius = 24
        controlsContainer.clipsToBounds = true
        controlsContainer.translatesAutoresizingMaskIntoConstraints = false

        controlsStack.axis = .horizontal
        controlsStack.alignment = .center
        controlsStack.spacing = 6
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        controlsContainer.contentView.addSubview(controlsStack)

        counterLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        counterLabel.textColor = .white
        counterLabel.setContentHuggingPriority(.required, for: .horizontal)

        configureBarButton(liveButton, symbol: "livephoto.play", label: "循环播放实况", action: #selector(toggleLive))
        configureBarButton(muteButton, symbol: "speaker.slash", label: "打开声音", action: #selector(toggleMute))
        configureBarButton(copyButton, symbol: "doc.on.doc", label: "拷贝图片", action: #selector(copyImage))
        configureBarButton(shareButton, symbol: "square.and.arrow.up", label: "分享", action: #selector(shareImage))

        controlsStack.addArrangedSubview(counterLabel)
        controlsStack.addArrangedSubview(liveButton)
        controlsStack.addArrangedSubview(muteButton)
        controlsStack.addArrangedSubview(copyButton)
        controlsStack.addArrangedSubview(shareButton)
        view.addSubview(controlsContainer)

        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            badgeContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            badgeContainer.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            badgeLabel.leadingAnchor.constraint(equalTo: badgeContainer.contentView.leadingAnchor, constant: 12),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeContainer.contentView.trailingAnchor, constant: -12),
            badgeLabel.topAnchor.constraint(equalTo: badgeContainer.contentView.topAnchor, constant: 5),
            badgeLabel.bottomAnchor.constraint(equalTo: badgeContainer.contentView.bottomAnchor, constant: -5),

            controlsContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            controlsContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
            controlsContainer.heightAnchor.constraint(equalToConstant: 48),

            controlsStack.leadingAnchor.constraint(equalTo: controlsContainer.contentView.leadingAnchor, constant: 14),
            controlsStack.trailingAnchor.constraint(equalTo: controlsContainer.contentView.trailingAnchor, constant: -14),
            controlsStack.topAnchor.constraint(equalTo: controlsContainer.contentView.topAnchor, constant: 4),
            controlsStack.bottomAnchor.constraint(equalTo: controlsContainer.contentView.bottomAnchor, constant: -4),
        ])
    }

    private func configureBarButton(_ button: UIButton, symbol: String, label: String, action: Selector) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        )
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        button.configuration = config
        button.accessibilityLabel = label
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func updateBarButton(_ button: UIButton, symbol: String, label: String) {
        var config = button.configuration ?? UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        )
        button.configuration = config
        button.accessibilityLabel = label
    }

    // MARK: - 翻页与预加载

    private func makePage(at index: Int) -> ImagePageViewController {
        let page = ImagePageViewController(index: index, item: items[index])
        page.onSingleTap = { [weak self] in
            self?.toggleChrome()
        }
        page.onLoaded = { [weak self, weak page] in
            guard let self, let page, page.index == self.currentIndex else { return }
            self.updateControls()
            self.loadLiveVideo(for: page)
        }
        return page
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? ImagePageViewController, page.index > 0 else { return nil }
        return makePage(at: page.index - 1)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let page = viewController as? ImagePageViewController, page.index + 1 < items.count else { return nil }
        return makePage(at: page.index + 1)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        guard completed, let page = currentPage else { return }
        for old in previousViewControllers {
            if let oldPage = old as? ImagePageViewController, oldPage !== page {
                oldPage.detachLivePlayer()
            }
        }
        currentIndex = page.index
        onPageActivated(page)
    }

    private func onPageActivated(_ page: ImagePageViewController) {
        clearLive()
        updateControls()
        if page.loadedImage != nil {
            loadLiveVideo(for: page)
        }
        prefetchAdjacent(around: page.index)
    }

    private func prefetchAdjacent(around center: Int) {
        let keep = Set([center - 1, center + 1].filter { items.indices.contains($0) })
        for (idx, task) in prefetchTasks where !keep.contains(idx) {
            task.cancel()
            prefetchTasks[idx] = nil
        }
        for idx in keep where prefetchTasks[idx] == nil {
            guard let url = ImageURL.normalized(items[idx].originalURL) else { continue }
            prefetchTasks[idx] = Task {
                _ = try? await ImagePipeline.shared.data(for: url)
            }
        }
    }

    private func jump(to target: Int) {
        guard items.indices.contains(target), target != currentIndex else { return }
        let direction: UIPageViewController.NavigationDirection = target > currentIndex ? .forward : .reverse
        let previous = currentPage
        let next = makePage(at: target)
        currentIndex = target
        pageController.setViewControllers([next], direction: direction, animated: true) { [weak self] finished in
            guard let self, finished else { return }
            previous?.detachLivePlayer()
            self.onPageActivated(next)
        }
    }

    // MARK: - 实况与状态栏控制

    private func clearLive() {
        liveTask?.cancel()
        liveTask = nil
        playback.load(nil)
        if let currentVideo { LivePhotoLoader.discard(currentVideo) }
        currentVideo = nil
        currentPage?.detachLivePlayer()
        syncLiveState()
    }

    private func loadLiveVideo(for page: ImagePageViewController) {
        liveTask?.cancel()
        playback.load(nil)
        if let currentVideo { LivePhotoLoader.discard(currentVideo) }
        currentVideo = nil

        let position = page.index
        let item = items[position]
        let rawData = page.loadedData
        let isLive = item.isLivePhoto || item.videoURL != nil || (rawData.map(MotionPhoto.declaresVideo) ?? false)
        updateBadge(for: page, isLive: isLive)
        guard isLive else { return }

        liveTask = Task { [weak self, weak page] in
            guard let video = await LivePhotoLoader.video(for: item, imageData: rawData) else { return }
            guard let self, let page, !Task.isCancelled, self.currentIndex == position else {
                LivePhotoLoader.discard(video)
                return
            }
            self.currentVideo = video
            self.playback.load(video.fileURL)
            page.attachLivePlayer(self.playback.player)
            self.syncLiveState()
            if AppSettings.autoPlaysLivePhotos {
                self.playback.playOnce()
            }
        }
    }

    private func syncLiveState() {
        let hasVideo = playback.hasVideo
        liveButton.isHidden = !hasVideo
        muteButton.isHidden = !hasVideo
        let looping = playback.state == .looping
        updateBarButton(liveButton, symbol: looping ? "stop.fill" : "livephoto.play",
                        label: looping ? "停止播放实况" : "循环播放实况")
        updateBarButton(muteButton, symbol: playback.isMuted ? "speaker.slash" : "speaker.wave.2",
                        label: playback.isMuted ? "打开声音" : "静音")
        currentPage?.setLivePlayerVisible(playback.state != .idle)
        updateControlsContainerVisibility()
    }

    private func updateControls() {
        counterLabel.text = "\(currentIndex + 1) / \(items.count)"
        counterLabel.isHidden = items.count < 2

        let hasImage = currentPage?.loadedImage != nil
        copyButton.isHidden = !hasImage
        shareButton.isHidden = !hasImage

        if let page = currentPage {
            let item = items[page.index]
            let isLive = item.isLivePhoto || item.videoURL != nil
                || (page.loadedData.map(MotionPhoto.declaresVideo) ?? false)
            updateBadge(for: page, isLive: isLive)
        } else {
            badgeContainer.isHidden = true
        }
        syncLiveState()
    }

    private func updateControlsContainerVisibility() {
        let anyVisible = !counterLabel.isHidden || !liveButton.isHidden || !copyButton.isHidden || !shareButton.isHidden
        controlsContainer.isHidden = !anyVisible
    }

    private func updateBadge(for page: ImagePageViewController, isLive: Bool) {
        var parts: [String] = []
        if isLive { parts.append("实况") }
        if page.isHDR { parts.append(AppSettings.isHDRDisabled ? "HDR 已关闭" : "HDR") }
        badgeLabel.text = parts.joined(separator: " · ")
        badgeContainer.isHidden = parts.isEmpty
    }

    private func toggleChrome() {
        chromeVisible.toggle()
        let alpha: CGFloat = chromeVisible ? 1 : 0
        UIView.animate(withDuration: 0.2) {
            self.closeButton.alpha = alpha
            self.badgeContainer.alpha = alpha
            self.controlsContainer.alpha = alpha
            self.setNeedsStatusBarAppearanceUpdate()
        }
    }

    // MARK: - 按钮动作与键盘快捷键

    @objc private func closeTapped() {
        dismissViewer(animated: true)
    }

    private func dismissViewer(animated: Bool) {
        guard !isDismissing else { return }
        isDismissing = true
        cleanupResources()
        dismiss(animated: animated)
    }

    private func cleanupResources() {
        liveTask?.cancel()
        liveTask = nil
        copyFeedbackTask?.cancel()
        copyFeedbackTask = nil
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        playback.load(nil)
        if let currentVideo { LivePhotoLoader.discard(currentVideo) }
        currentVideo = nil
    }

    @objc private func toggleLive() {
        playback.toggleLoop()
    }

    @objc private func toggleMute() {
        playback.isMuted.toggle()
        syncLiveState()
    }

    @objc private func copyImage() {
        guard let image = currentPage?.loadedImage else { return }
        UIPasteboard.general.image = image
        copyFeedbackTask?.cancel()
        updateBarButton(copyButton, symbol: "checkmark", label: "已拷贝")
        copyFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.updateBarButton(self.copyButton, symbol: "doc.on.doc", label: "拷贝图片")
        }
    }

    @objc private func shareImage() {
        guard let image = currentPage?.loadedImage else { return }
        let activity = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = shareButton
            popover.sourceRect = shareButton.bounds
        }
        present(activity, animated: true)
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeTapped)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(showPrevious)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(showNext)),
            UIKeyCommand(input: "c", modifierFlags: .command, action: #selector(copyImage)),
        ]
    }

    @objc private func showPrevious() { jump(to: currentIndex - 1) }
    @objc private func showNext() { jump(to: currentIndex + 1) }

    // MARK: - 下拉关闭手势

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard currentPage?.isZoomed == false else { return false }
        let velocity = pan.velocity(in: view)
        // 只响应明确向下的竖直滑动，绝不抢占水平翻页手势。
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x) * 1.3
    }

    @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: view)
        let velocity = pan.velocity(in: view)
        switch pan.state {
        case .changed:
            let dy = max(0, translation.y)
            let progress = min(dy / 260, 1)
            let scale = max(1 - progress * 0.18, 0.82)
            pageController.view.transform = CGAffineTransform(translationX: translation.x * 0.35, y: dy)
                .scaledBy(x: scale, y: scale)
            backdropView.alpha = 1 - progress * 0.78
            let chromeAlpha = max(0, 1 - progress * 3)
            closeButton.alpha = chromeVisible ? chromeAlpha : 0
            badgeContainer.alpha = chromeVisible ? chromeAlpha : 0
            controlsContainer.alpha = chromeVisible ? chromeAlpha : 0
        case .ended, .cancelled, .failed:
            let shouldDismiss = pan.state == .ended && (translation.y > 110 || velocity.y > 700)
            if shouldDismiss {
                UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut]) {
                    self.pageController.view.alpha = 0
                    self.pageController.view.transform = self.pageController.view.transform
                        .translatedBy(x: 0, y: 80)
                        .scaledBy(x: 0.9, y: 0.9)
                    self.backdropView.alpha = 0
                    self.closeButton.alpha = 0
                    self.badgeContainer.alpha = 0
                    self.controlsContainer.alpha = 0
                } completion: { _ in
                    self.dismissViewer(animated: false)
                }
            } else {
                UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) {
                    self.pageController.view.transform = .identity
                    self.backdropView.alpha = 1
                    let alpha: CGFloat = self.chromeVisible ? 1 : 0
                    self.closeButton.alpha = alpha
                    self.badgeContainer.alpha = alpha
                    self.controlsContainer.alpha = alpha
                }
            }
        default:
            break
        }
    }
}

// MARK: - 单页图片与缩放视图

@MainActor
private final class ImagePageViewController: UIViewController, UIScrollViewDelegate {
    let index: Int
    let item: FeedMedia

    var onSingleTap: (() -> Void)?
    var onLoaded: (() -> Void)?

    private(set) var loadedImage: UIImage?
    private(set) var loadedData: Data?
    private(set) var isHDR = false

    var isZoomed: Bool { scrollView.zoomScale > 1.01 }

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var playerHost: PlayerLayerHostView?
    private let spinner = UIActivityIndicatorView(style: .large)
    private let errorLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    private var lastLayoutSize: CGSize = .zero

    init(index: Int, item: FeedMedia) {
        self.index = index
        self.item = item
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持从归档创建") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        // 未放大时禁用内层滚动，避免水平滑动与 UIPageViewController 冲突导致翻页卡在一半。
        scrollView.isScrollEnabled = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = false
        scrollView.addSubview(imageView)

        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)

        errorLabel.text = "图片加载失败"
        errorLabel.textColor = .secondaryLabel
        errorLabel.font = .preferredFont(forTextStyle: .callout)
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        loadImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = scrollView.bounds.size
        guard size.width > 0, size.height > 0, size != lastLayoutSize else { return }
        lastLayoutSize = size
        if loadedImage != nil {
            fitImageToBounds()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 滑走后自动复原缩放，下次滑回时恢复 1:1 适应屏幕。
        if scrollView.zoomScale != 1 {
            scrollView.setZoomScale(1, animated: false)
            scrollView.isScrollEnabled = false
            updateContentInsets()
        }
    }

    deinit {
        loadTask?.cancel()
    }

    private func loadImage() {
        guard let url = ImageURL.normalized(item.originalURL) else {
            errorLabel.isHidden = false
            return
        }
        spinner.startAnimating()
        let allowHDR = !AppSettings.isHDRDisabled
        loadTask = Task { [weak self] in
            let data = try? await ImagePipeline.shared.data(for: url)
            // 大图解码放后台，防止翻页手势途中卡顿主线程。
            let decoded = await Task.detached(priority: .userInitiated) {
                data.flatMap { HDRImage.platformImage(from: $0, allowHDR: allowHDR) }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.spinner.stopAnimationIfNeeded()
            guard let data, let decoded else {
                self.errorLabel.isHidden = false
                return
            }
            self.loadedData = data
            self.loadedImage = decoded.image
            self.isHDR = decoded.isHDR
            self.imageView.preferredImageDynamicRange = (decoded.isHDR && allowHDR) ? .high : .standard
            self.imageView.image = decoded.image
            self.fitImageToBounds()
            self.onLoaded?()
        }
    }

    private func fitImageToBounds() {
        guard let image = loadedImage else { return }
        let boundsSize = scrollView.bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0, image.size.width > 0, image.size.height > 0 else { return }

        scrollView.zoomScale = 1
        scrollView.isScrollEnabled = false

        let scale = min(boundsSize.width / image.size.width, boundsSize.height / image.size.height)
        let fitted = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted
        playerHost?.frame = imageView.bounds
        updateContentInsets()
    }

    private func updateContentInsets() {
        let boundsSize = scrollView.bounds.size
        let contentSize = scrollView.contentSize
        let horizontal = max((boundsSize.width - contentSize.width) * 0.5, 0)
        let vertical = max((boundsSize.height - contentSize.height) * 0.5, 0)
        scrollView.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    // MARK: - 实况叠加层

    func attachLivePlayer(_ player: AVPlayer) {
        detachLivePlayer()
        let host = PlayerLayerHostView(player: player)
        host.frame = imageView.bounds
        host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.alpha = 0
        imageView.addSubview(host)
        playerHost = host
    }

    func detachLivePlayer() {
        playerHost?.removeFromSuperview()
        playerHost = nil
    }

    func setLivePlayerVisible(_ visible: Bool) {
        guard let playerHost else { return }
        UIView.animate(withDuration: 0.2) {
            playerHost.alpha = visible ? 1 : 0
        }
    }

    // MARK: - UIScrollViewDelegate & 手势

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        loadedImage == nil ? nil : imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        scrollView.isScrollEnabled = scrollView.zoomScale > 1.01
        updateContentInsets()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        scrollView.isScrollEnabled = scale > 1.01
        updateContentInsets()
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard loadedImage != nil else { return }
        if scrollView.zoomScale > 1.01 {
            scrollView.setZoomScale(1, animated: true)
        } else {
            let targetScale: CGFloat = 2.5
            let point = recognizer.location(in: imageView)
            let width = scrollView.bounds.width / targetScale
            let height = scrollView.bounds.height / targetScale
            let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
            scrollView.zoom(to: rect, animated: true)
        }
    }
}

private extension UIActivityIndicatorView {
    func stopAnimationIfNeeded() {
        if isAnimating { stopAnimating() }
    }
}
