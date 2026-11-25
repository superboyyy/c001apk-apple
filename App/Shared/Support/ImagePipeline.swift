import ImageIO
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// 酷安图片 CDN 的 URL 规则。
enum ImageURL {
    /// 升级为 HTTPS，并补全不带协议头的链接。
    static func normalized(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("//") { text = "https:" + text }
        if text.hasPrefix("http://") { text = "https://" + text.dropFirst("http://".count) }
        guard let url = URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""),
              url.scheme == "https", url.host != nil
        else { return nil }
        return url
    }

    enum Variant: String {
        /// 480px 方形裁剪
        case square = ".xs.jpg"
        /// 宽 720px
        case small = ".s.jpg"
        /// 宽 1080px
        case medium = ".m.jpg"
    }

    static func isGIF(_ raw: String) -> Bool {
        raw.lowercased().split(separator: "?").first?.hasSuffix(".gif") ?? false
    }

    /// CDN 按后缀提供动态图片的缩放版本。
    static func variant(_ raw: String, _ variant: Variant) -> URL? {
        guard let url = normalized(raw) else { return nil }
        guard url.host == "image.coolapk.com", url.query == nil, !isGIF(raw),
              !raw.hasSuffix(".s.jpg"), !raw.hasSuffix(".xs.jpg"), !raw.hasSuffix(".m.jpg"), !raw.hasSuffix(".t.jpg"),
              url.path.contains("@")
        else { return url }
        return URL(string: url.absoluteString + variant.rawValue) ?? url
    }

    /// 图片 URL 自带像素尺寸：`…@1440x2216.jpg`。
    static func pixelSize(_ raw: String) -> CGSize? {
        guard let at = raw.lastIndex(of: "@") else { return nil }
        let tail = raw[raw.index(after: at)...]
        let digits = tail.prefix { $0.isNumber || $0 == "x" }
        let parts = digits.split(separator: "x")
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]), width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

/// `NSCache` 本身线程安全，这层封装让它可以跨 actor 传递。
final class ImageMemoryCache: @unchecked Sendable {
    private let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    func image(for key: String) -> PlatformImage? { cache.object(forKey: key as NSString) }

    func store(_ image: PlatformImage, for key: String) {
        cache.setObject(image, forKey: key as NSString, cost: Int(image.size.width * image.size.height * 4))
    }

    func removeAll() { cache.removeAllObjects() }
}

/// 下载、解码并缓存远程图片。
actor ImagePipeline {
    static let shared = ImagePipeline()

    /// CDN 会拒绝未知客户端，这里伪装成桌面浏览器。
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    private nonisolated let memory = ImageMemoryCache()
    private let session: URLSession
    private nonisolated let diskCache: URLCache
    private var inflight: [String: Task<PlatformImage?, Never>] = [:]

    private init() {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("c001apk-images", isDirectory: true)
        diskCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 512 * 1024 * 1024, directory: directory)
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = diskCache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpAdditionalHeaders = ["User-Agent": ImagePipeline.userAgent]
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
    }

    nonisolated func cached(_ url: URL, maxPixel: CGFloat?) -> PlatformImage? {
        memory.image(for: ImagePipeline.key(url, maxPixel))
    }

    private static func key(_ url: URL, _ maxPixel: CGFloat?) -> String {
        "\(url.absoluteString)#\(maxPixel.map { String(Int($0)) } ?? "full")"
    }

    func image(for url: URL, maxPixel: CGFloat? = nil) async -> PlatformImage? {
        let key = ImagePipeline.key(url, maxPixel)
        if let cached = memory.image(for: key) { return cached }
        if let running = inflight[key] { return await running.value }
        let task = Task<PlatformImage?, Never>(priority: .userInitiated) { [session, memory] in
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
                  let image = ImagePipeline.decode(data, maxPixel: maxPixel)
            else { return nil }
            memory.store(image, for: key)
            return image
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        return image
    }

    /// 原始数据，用于保存、拷贝和动图播放。
    func data(for url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func decode(_ data: Data, maxPixel: CGFloat?) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        // 始终在主线程之外解码，同时限制超大原图的尺寸。
        options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel ?? 4096
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return PlatformImage(data: data)
        }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }

    nonisolated var diskUsage: Int { diskCache.currentDiskUsage }

    nonisolated func clearCaches() {
        memory.removeAll()
        diskCache.removeAllCachedResponses()
    }
}

/// 通过 `ImagePipeline` 加载的图片，带中性色占位。
struct RemoteImage: View {
    let url: URL?
    /// 原图地址，缩放版本不可用时改用它。
    var fallbackURL: URL?
    var maxPixel: CGFloat? = 1200
    var contentMode: ContentMode = .fill
    var placeholderSymbol = "photo"

    @State private var image: PlatformImage?
    @State private var failed = false

    init(_ raw: String, variant: ImageURL.Variant? = nil, maxPixel: CGFloat? = 1200,
         contentMode: ContentMode = .fill, placeholderSymbol: String = "photo") {
        let original = ImageURL.normalized(raw)
        url = variant.map { ImageURL.variant(raw, $0) } ?? original
        fallbackURL = original == url ? nil : original
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.placeholderSymbol = placeholderSymbol
    }

    var body: some View {
        ZStack {
            if let image = image ?? url.flatMap({ ImagePipeline.shared.cached($0, maxPixel: maxPixel) }) {
                Image(platformImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: failed ? "exclamationmark.triangle" : placeholderSymbol)
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .task(id: url) {
            guard let url else { failed = true; return }
            if let cached = ImagePipeline.shared.cached(url, maxPixel: maxPixel) {
                image = cached
                return
            }
            image = nil
            failed = false
            var loaded = await ImagePipeline.shared.image(for: url, maxPixel: maxPixel)
            if loaded == nil, !Task.isCancelled, let fallbackURL {
                loaded = await ImagePipeline.shared.image(for: fallbackURL, maxPixel: maxPixel)
            }
            guard !Task.isCancelled else { return }
            if let loaded {
                withAnimation(.easeOut(duration: 0.15)) { image = loaded }
            } else {
                failed = true
            }
        }
    }
}

struct AvatarView: View {
    let url: String
    var size: CGFloat = 36

    var body: some View {
        RemoteImage(url, maxPixel: size * 3, placeholderSymbol: "person.fill")
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}
