import CoolapkKit
import SwiftUI
import UIKit

/// iPadOS 的图片查看器：全屏翻页、双指缩放、拷贝与分享。
@MainActor
enum ImageViewer {
    static func show(urls: [String], index: Int) {
        let valid = urls.filter { ImageURL.normalized($0) != nil }
        guard !valid.isEmpty, let presenter = topViewController() else { return }
        let start = urls.indices.contains(index) ? (valid.firstIndex(of: urls[index]) ?? 0) : 0
        let host = UIHostingController(rootView: ImageViewerScreen(urls: valid, index: start))
        host.modalPresentationStyle = .fullScreen
        host.view.backgroundColor = .black
        presenter.present(host, animated: true)
    }

    /// 带素材元数据的入口：与 macOS 查看器同名，这里取每项的原图地址。
    static func show(media: [FeedMedia], index: Int) {
        show(urls: media.map(\.originalURL), index: index)
    }

    /// 当前最上层的视图控制器，用来弹出查看器。
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// 查看器界面：横向翻页 + 底部玻璃控制条。
private struct ImageViewerScreen: View {
    let urls: [String]
    @State var index: Int

    @Environment(\.dismiss) private var dismiss
    @State private var images: [Int: UIImage] = [:]
    @State private var failed: Set<Int> = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(urls.indices, id: \.self) { position in
                    page(position).tag(position)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
        .overlay(alignment: .topLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).frame(width: 22, height: 26)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .padding(16)
            .accessibilityLabel("关闭")
        }
        .overlay(alignment: .bottom) { controls.padding(.bottom, 20) }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func page(_ position: Int) -> some View {
        if let image = images[position] {
            ZoomableImageView(image: image)
        } else if failed.contains(position) {
            Text("图片加载失败").foregroundStyle(.secondary)
        } else {
            ProgressView()
                .task {
                    guard let url = ImageURL.normalized(urls[position]) else { failed.insert(position); return }
                    // HDR 图片按“我不想看 HDR”设置决定用高动态范围还是 SDR 解码。
                    if let data = try? await ImagePipeline.shared.data(for: url),
                       let decoded = HDRImage.platformImage(from: data, allowHDR: !AppSettings.isHDRDisabled) {
                        images[position] = decoded.image
                    } else {
                        failed.insert(position)
                    }
                }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            if urls.count > 1 {
                Text("\(index + 1) / \(urls.count)")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
            }
            if let image = images[index] {
                Button {
                    UIPasteboard.general.image = image
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("拷贝图片")
                ShareLink(item: Image(uiImage: image), preview: SharePreview("图片", image: Image(uiImage: image))) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("分享")
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .glassEffect(.regular, in: .capsule)
    }
}

/// 可双指缩放、双击放大的图片视图（UIScrollView）。
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.preferredImageDynamicRange = .high
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.frame = scrollView.bounds
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func toggleZoom(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let size = CGSize(width: scrollView.bounds.width / 2.5, height: scrollView.bounds.height / 2.5)
                scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                           width: size.width, height: size.height), animated: true)
            }
        }
    }
}
