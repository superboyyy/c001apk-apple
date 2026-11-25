import CoolapkKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 帖子导出的文件格式。
enum FeedExportFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown, html

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: return "Markdown（.md）"
        case .html: return "离线 HTML（.html）"
        }
    }

    var detail: String {
        switch self {
        case .markdown: return "可编辑，图片保留在线链接"
        case .html: return "图文排版，图片内嵌至单个文件"
        }
    }

    var systemImage: String {
        switch self {
        case .markdown: return "doc.plaintext"
        case .html: return "doc.richtext"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .html: return "html"
        }
    }

    var contentType: UTType {
        switch self {
        case .markdown: return UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
        case .html: return .html
        }
    }
}

/// 已生成、等待用户选择保存位置的导出结果。
struct PreparedFeedExport: Sendable {
    let format: FeedExportFormat
    /// 带扩展名的建议文件名。
    let fileName: String
    let data: Data
    /// 需要用户确认后才继续保存的缺失项（评论或图片未取得）。
    let warnings: [String]
    /// 写入文件的评论编号，按出现顺序。
    let commentIDs: [String]
}

/// 负责一次导出：单独读取热门评论和图片并生成文件数据，不改动详情页的任何状态。
/// 对应上游 Flutter 端的 `content_export_service.dart`；取消通过 Swift 的任务取消传递。
struct FeedExportService: Sendable {
    static let maxImageBytes = 8 * 1024 * 1024
    static let maxTotalBytes = 32 * 1024 * 1024
    static let maxImages = 60
    static let maxPixels = 32 * 1024 * 1024
    /// 全部图片的准备时限与单张图片的下载时限（秒）。
    static let totalTimeout: TimeInterval = 45
    static let imageTimeout: TimeInterval = 8

    /// 读取帖子的热门评论第一页。
    var loadPopular: @Sendable (String) async throws -> [Entity]
    /// 取图片原始字节，失败返回 nil。
    var loadImage: @Sendable (String) async -> Data?
    /// 本机屏蔽的用户，其评论不会写入文件。
    var blockedUIDs: Set<String>

    init(blockedUIDs: Set<String> = [],
         loadPopular: @escaping @Sendable (String) async throws -> [Entity],
         loadImage: @escaping @Sendable (String) async -> Data? = FeedExportService.pipelineImage) {
        self.blockedUIDs = blockedUIDs
        self.loadPopular = loadPopular
        self.loadImage = loadImage
    }

    /// 用应用的接口客户端和图片管线取数据。评论请求不会弹出人机验证，失败会体现在警告里。
    init(client: CoolapkClient, blockedUIDs: Set<String>) {
        self.init(blockedUIDs: blockedUIDs, loadPopular: { id in
            try await client.feedReplies(id: id, sort: .popular, page: 1, firstItem: nil, lastItem: nil).items
        })
    }

    /// 优先命中图片缓存，否则下载原图。
    static let pipelineImage: @Sendable (String) async -> Data? = { raw in
        guard let url = ImageURL.normalized(raw) else { return nil }
        return try? await ImagePipeline.shared.data(for: url)
    }

    func prepare(_ feed: Entity, format: FeedExportFormat) async throws -> PreparedFeedExport {
        try Task.checkCancellation()
        var warnings: [String] = []
        var notices: [String] = []
        if feed.isPublicCopy { notices.append("正文取自公开网页版，内容可能不完整。") }

        var popular: [Entity] = []
        do {
            popular = try await loadPopular(feed.entityID)
        } catch {
            let failure = APIError.from(error)
            if failure.kind == .cancelled { throw CancellationError() }
            warnings.append("热门评论读取失败，本次无法保证保存前三条评论。")
            popular = feed.hotReplyRows
            if !popular.isEmpty {
                notices.append("未能读取完整的热门评论，以下评论取自帖子自带的公开热评。")
            } else if failure.kind == .captcha || failure.kind == .authentication {
                notices.append("未能取得热门评论；可返回评论区完成验证后重试。本文件仅含已取得的置顶评论。")
            } else {
                notices.append("未能取得热门评论，本文件仅含已取得的置顶评论。")
            }
        }
        try Task.checkCancellation()

        let replies = popular.filter { $0.entityType.isEmpty || $0.entityType == "feed_reply" }
        let comments = ExportDocument.selectComments(pinned: feed.topReplyRows, popular: replies, blockedUIDs: blockedUIDs)
        let commentIDs = comments.map(\.entity.entityID)
        var document = ExportDocument(feed: feed, comments: comments, notices: notices)

        if format == .markdown {
            if !document.imageURLs.isEmpty {
                notices.append("Markdown 图片保留在线链接，离线阅读图片请另存为 HTML。")
                document = ExportDocument(feed: feed, comments: comments, notices: notices)
            }
            return PreparedFeedExport(format: format, fileName: "\(document.fileName).md",
                                      data: Data(document.markdown.utf8), warnings: warnings, commentIDs: commentIDs)
        }

        let urls = document.imageURLs
        var images: [String: String] = [:]
        var bytesUsed = 0
        let deadline = Date().addingTimeInterval(FeedExportService.totalTimeout)
        for url in urls.prefix(FeedExportService.maxImages) {
            try Task.checkCancellation()
            if Date() > deadline || bytesUsed >= FeedExportService.maxTotalBytes { break }
            let loadImage = loadImage
            guard let data = await FeedExportService.withTimeout(FeedExportService.imageTimeout, { await loadImage(url) }),
                  data.count <= FeedExportService.maxImageBytes,
                  bytesUsed + data.count <= FeedExportService.maxTotalBytes,
                  let uri = ExportDocument.dataURI(for: data),
                  FeedExportService.decodes(data)
            else { continue }
            bytesUsed += data.count
            images[url] = uri
        }
        try Task.checkCancellation()
        let missing = urls.count - images.count
        if missing > 0 {
            warnings.append("\(missing) 张图片未能保存，将以来源链接代替；这些图片无法离线查看。")
        }
        return PreparedFeedExport(format: format, fileName: "\(document.fileName).html",
                                  data: Data(document.offlineHTML(images: images).utf8),
                                  warnings: warnings, commentIDs: commentIDs)
    }

    /// 图片必须能被系统解码，且像素数不超过上限；截断或伪装的文件按缺失处理。
    static func decodes(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= maxPixels
        else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 16,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil
    }

    /// 在时限内等待结果；超时取消操作并返回 nil。
    private static func withTimeout(_ seconds: TimeInterval,
                                    _ operation: @escaping @Sendable () async -> Data?) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
