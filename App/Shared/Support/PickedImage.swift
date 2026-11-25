import CoolapkKit
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 用户选中的一张待发送图片：已读入内存、量好尺寸，并整理成可以上传的格式。
struct PickedImage: Identifiable, Equatable {
    let id = UUID()
    /// 交给 `CoolapkClient.uploadImages` 的内容。
    let upload: UploadImage
    /// 预览用的小图。
    let thumbnail: CGImage?

    static func == (lhs: PickedImage, rhs: PickedImage) -> Bool { lhs.id == rhs.id }

    /// 读图失败时给用户看的原因。
    struct LoadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 从文件读取。`fileImporter` 给的是沙盒外的地址，读取期间需要申请访问权。
    static func load(url: URL) async throws -> PickedImage {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                throw LoadError(message: "无法读取“\(url.lastPathComponent)”")
            }
            return try make(from: data)
        }.value
    }

    /// 从“照片”选择器的条目读取。
    static func load(item: PhotosPickerItem) async throws -> PickedImage {
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            throw LoadError(message: "无法读取所选照片")
        }
        return try await Task.detached(priority: .userInitiated) { try make(from: data) }.value
    }

    /// 解码图片数据。JPEG / PNG / GIF / WebP 原样上传，其余格式（HEIC、TIFF 等）转成 JPEG。
    static func make(from data: Data) throws -> PickedImage {
        let invalid = LoadError(message: "请选择有效的图片文件")
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              var height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else { throw invalid }
        // 方向标记为 5...8 的照片显示时宽高对调。
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360,
        ] as CFDictionary)

        if let contentType = UploadImage.sniffContentType(data) {
            return PickedImage(
                upload: UploadImage(data: data, width: width, height: height, contentType: contentType),
                thumbnail: thumbnail)
        }
        // 重新编码：按显示方向摆正像素，再存成 JPEG。
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ] as CFDictionary) else { throw invalid }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw invalid
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw invalid }
        return PickedImage(
            upload: UploadImage(data: output as Data, width: image.width, height: image.height, contentType: "image/jpeg"),
            thumbnail: thumbnail)
    }
}

/// 选图入口：从“照片”或文件里选图片，读入后回调。两个选择器都是 SwiftUI 自带的跨平台实现。
struct ImagePickerMenu<Label: View>: View {
    /// 这次最多还能选几张。
    var limit: Int
    var onPicked: ([PickedImage]) -> Void
    var onFailure: (String) -> Void
    @ViewBuilder var label: () -> Label

    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isLoading = false

    var body: some View {
        Menu {
            Button("从照片中选择", systemImage: "photo.on.rectangle") { showsPhotos = true }
            Button("从文件中选择", systemImage: "folder") { showsFiles = true }
        } label: {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                label()
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .disabled(isLoading || limit < 1)
        .photosPicker(
            isPresented: $showsPhotos, selection: $photoItems, maxSelectionCount: max(limit, 1),
            matching: .images, preferredItemEncoding: .compatible)
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image], allowsMultipleSelection: limit > 1) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            read(urls.count) { index in try await PickedImage.load(url: urls[index]) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            read(items.count) { index in try await PickedImage.load(item: items[index]) }
        }
    }

    /// 依次读入选中的图片；超出上限的部分丢弃并提示。
    private func read(_ count: Int, load: @escaping (Int) async throws -> PickedImage) {
        isLoading = true
        Task {
            defer { isLoading = false }
            var loaded: [PickedImage] = []
            var problem: String?
            for index in 0..<min(count, limit) {
                do {
                    loaded.append(try await load(index))
                } catch {
                    problem = error.localizedDescription
                }
            }
            if count > limit { problem = "最多还能选择 \(limit) 张图片" }
            if !loaded.isEmpty { onPicked(loaded) }
            if let problem { onFailure(problem) }
        }
    }
}
