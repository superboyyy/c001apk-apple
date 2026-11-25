import CoreGraphics
import Foundation
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// HDR 静态图的识别与解码，macOS 与 iPadOS 的查看器共用。
/// 酷安的 HDR 图是带增益图的 JPEG（文件名含 `-uhdr` 或 `-xhdr`），系统都按 ISO 增益图处理。
enum HDRImage {
    /// 解码后的大图，以及原图是否带 HDR 信息。
    struct Decoded {
        let image: PlatformImage
        let isHDR: Bool
    }

    /// 图片是否带 HDR 信息：增益图，或 PQ / HLG 传递函数。
    static func isHDR(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        for type in [kCGImageAuxiliaryDataTypeISOGainMap, kCGImageAuxiliaryDataTypeHDRGainMap] {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type) != nil { return true }
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let space = CGImageSourceCreateImageAtIndex(source, 0, options)?.colorSpace else { return false }
        return CGColorSpaceUsesITUR_2100TF(space)
    }

    /// 解码首帧并应用拍摄方向。`allowHDR` 为 false 时得到 SDR 图像（增益图图片取其基础图）。
    static func decode(_ data: Data, allowHDR: Bool) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // 缩略图接口既能套用方向，也接受 HDR / SDR 解码请求；尺寸取原图大小。
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceDecodeRequest: allowHDR ? kCGImageSourceDecodeToHDR : kCGImageSourceDecodeToSDR,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 解码成可直接显示的平台图片。普通图片（含 GIF 动图）保持系统默认解码；
    /// HDR 图片在 `allowHDR` 为 false 时换成 SDR 版本。可在后台线程调用。
    static func platformImage(from data: Data, allowHDR: Bool) -> Decoded? {
        let hdr = isHDR(data)
        if hdr, !allowHDR, let image = decode(data, allowHDR: false) {
            #if os(macOS)
            // 用位图表示，像素尺寸与原图一致。
            let converted = NSImage(size: NSSize(width: image.width, height: image.height))
            converted.addRepresentation(NSBitmapImageRep(cgImage: image))
            return Decoded(image: converted, isHDR: true)
            #else
            return Decoded(image: UIImage(cgImage: image), isHDR: true)
            #endif
        }
        #if os(macOS)
        // AppKit 读取增益图 JPEG 时自带 HDR 表示，是否显示高光由视图的动态范围决定。
        return NSImage(data: data).map { Decoded(image: $0, isHDR: hdr) }
        #else
        if hdr {
            var configuration = UIImageReader.Configuration()
            configuration.prefersHighDynamicRange = true
            if let image = UIImageReader(configuration: configuration).image(data: data) {
                return Decoded(image: image, isHDR: true)
            }
        }
        return UIImage(data: data).map { Decoded(image: $0, isHDR: hdr) }
        #endif
    }
}
