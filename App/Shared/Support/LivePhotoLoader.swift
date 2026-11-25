import CoolapkKit
import Foundation

/// 一段已落到临时文件、可播放也可另存的实况视频。
struct LivePhotoVideo: Sendable {
    /// 视频原始字节，保存原件时原样写出。
    let data: Data
    /// `mp4` 或 `mov`。
    let fileExtension: String
    /// 供播放器读取的临时文件。
    let fileURL: URL
}

/// 取得一张实况图的视频：优先用元数据里的视频地址，否则取原图里内嵌的视频（Motion Photo）。
enum LivePhotoLoader {
    /// 临时目录在每次启动后首次使用时清空，避免残留上次的视频。
    private static let directory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("c001apk-live", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// - Parameter imageData: 已下载的原图字节，用于查找内嵌视频。
    static func video(for media: FeedMedia, imageData: Data?) async -> LivePhotoVideo? {
        if let raw = media.videoURL, let url = ImageURL.normalized(raw),
           let data = try? await ImagePipeline.shared.data(for: url), !data.isEmpty {
            return store(data, fileExtension: fileExtension(for: url, data: data))
        }
        if let imageData, let embedded = MotionPhoto.embeddedVideo(in: imageData) {
            return store(embedded.data, fileExtension: embedded.fileExtension)
        }
        return nil
    }

    /// 播放结束或切换图片后删除临时文件。
    static func discard(_ video: LivePhotoVideo) {
        try? FileManager.default.removeItem(at: video.fileURL)
    }

    private static func store(_ data: Data, fileExtension: String) -> LivePhotoVideo? {
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        do {
            try data.write(to: url, options: .atomic)
            return LivePhotoVideo(data: data, fileExtension: fileExtension, fileURL: url)
        } catch {
            return nil
        }
    }

    /// 先看地址的扩展名，再看文件头里的 QuickTime 标记，默认 mp4。
    private static func fileExtension(for url: URL, data: Data) -> String {
        let name = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(name) { return name }
        let brand = String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self)
        return brand.hasPrefix("qt") ? "mov" : "mp4"
    }
}
