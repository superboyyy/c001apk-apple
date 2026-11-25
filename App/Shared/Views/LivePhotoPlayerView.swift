import AVFoundation
import Observation
import SwiftUI

/// 实况视频的播放控制：自动播放一次，或手动循环播放。macOS 与 iPadOS 的查看器共用。
@MainActor
@Observable
final class LivePhotoPlayback {
    enum State: Equatable {
        /// 未播放，界面显示静态图。
        case idle
        case playingOnce
        case looping
    }

    private(set) var state: State = .idle
    private(set) var hasVideo = false
    /// 默认静音，由用户手动打开声音。
    var isMuted = true {
        didSet { player.isMuted = isMuted }
    }

    @ObservationIgnored let player = AVPlayer()
    /// 状态变化回调，供不走 SwiftUI 观察的界面（AppKit 查看器）使用。
    @ObservationIgnored var onStateChange: ((State) -> Void)?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init() {
        player.isMuted = true
        player.actionAtItemEnd = .pause
    }

    /// 换成新的视频文件；传 nil 表示当前图片没有实况视频。
    func load(_ url: URL?) {
        stop()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        guard let url else {
            player.replaceCurrentItem(with: nil)
            hasVideo = false
            return
        }
        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didReachEnd() }
        }
        player.replaceCurrentItem(with: item)
        hasVideo = true
    }

    /// 从头播放一遍，结束后回到静态图。
    func playOnce() { start(.playingOnce) }

    /// 从头循环播放，直到调用 `stop()`。
    func playLoop() { start(.looping) }

    /// 手动按钮的行为：循环中则停止，否则开始循环。
    func toggleLoop() {
        if state == .looping { stop() } else { playLoop() }
    }

    func stop() {
        player.pause()
        setState(.idle)
    }

    private func start(_ next: State) {
        guard hasVideo else { return }
        player.seek(to: .zero)
        player.play()
        setState(next)
    }

    private func didReachEnd() {
        if state == .looping {
            player.seek(to: .zero)
            player.play()
        } else {
            setState(.idle)
        }
    }

    private func setState(_ next: State) {
        guard state != next else { return }
        state = next
        onStateChange?(next)
    }
}

#if os(macOS)
import AppKit

/// 承载 `AVPlayerLayer` 的平台视图。
final class PlayerLayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer = playerLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持从归档创建") }

    /// 画面只作展示，点击交给下面的图片。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostView { PlayerLayerHostView(player: player) }

    func updateNSView(_ view: PlayerLayerHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
#else
import UIKit

/// 承载 `AVPlayerLayer` 的平台视图。
final class PlayerLayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass 已保证图层类型。
        layer as! AVPlayerLayer
    }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("不支持从归档创建") }
}

private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerHostView { PlayerLayerHostView(player: player) }

    func updateUIView(_ view: PlayerLayerHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
#endif

/// 实况视频画面，叠在静态图上使用：不播放时完全透明，露出下面的图片。
struct LivePhotoPlayerView: View {
    let playback: LivePhotoPlayback

    var body: some View {
        PlayerLayerView(player: playback.player)
            .opacity(playback.state == .idle ? 0 : 1)
            .animation(.easeInOut(duration: 0.2), value: playback.state)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// 大图上的实况控制按钮：点按开始或停止循环播放。只有取得视频时才显示。
struct LivePhotoToggle: View {
    let playback: LivePhotoPlayback

    var body: some View {
        if playback.hasVideo {
            let looping = playback.state == .looping
            Button {
                playback.toggleLoop()
            } label: {
                Label(looping ? "停止播放" : "循环播放实况", systemImage: looping ? "stop.fill" : "livephoto.play")
            }
            .buttonStyle(.glass)
            .help(looping ? "停止播放实况" : "循环播放实况")
        }
    }
}
