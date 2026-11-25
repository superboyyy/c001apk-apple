import Foundation

/// 安卓“动态照片”（Motion Photo）：一张 JPEG 末尾追加一段 MP4，并在 XMP 里声明。
/// 安卓相机的实况图普遍采用这种容器。
public enum MotionPhoto {
    /// 内嵌视频及其建议的扩展名。
    public struct Video: Sendable, Equatable {
        public let data: Data
        /// `mp4` 或 `mov`。
        public let fileExtension: String
    }

    /// 图片的 XMP 是否声明了内嵌视频。酷安图床会保留声明但去掉视频本身，所以这只是提示。
    public static func declaresVideo(_ data: Data) -> Bool {
        let header = xmpText(data)
        return header.contains("MotionPhoto=\"1\"") || header.contains("MicroVideo=\"1\"")
    }

    /// 取出内嵌的视频；文件里没有完整视频时返回 nil。
    public static func embeddedVideo(in data: Data) -> Video? {
        guard let range = embeddedVideoRange(in: data) else { return nil }
        let start = data.startIndex + range.lowerBound
        let video = data.subdata(in: start..<data.startIndex + range.upperBound)
        let brand = String(decoding: video.dropFirst(8).prefix(4), as: UTF8.self)
        return Video(data: video, fileExtension: brand.hasPrefix("qt") ? "mov" : "mp4")
    }

    /// 内嵌视频在文件中的字节范围（相对文件开头）。
    public static func embeddedVideoRange(in data: Data) -> Range<Int>? {
        let bytes = [UInt8](data)
        // JPEG 以 FF D8 开头；其它容器不处理。
        guard bytes.count > 16, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        for length in declaredLengths(xmpText(data)) where length > 8 && length < bytes.count {
            let offset = bytes.count - length
            if isVideoStart(bytes, at: offset) { return offset..<bytes.count }
        }
        // 声明缺失或不准时，直接找视频开头的 ftyp 盒。
        for position in 4..<bytes.count - 8 where bytes[position] == 0x66 && isVideoStart(bytes, at: position - 4) {
            return position - 4..<bytes.count
        }
        return nil
    }

    /// XMP 位于文件开头的 APP1 段，只需检查前一小段。
    private static func xmpText(_ data: Data) -> String {
        String(decoding: data.prefix(256 * 1024), as: UTF8.self)
    }

    /// 候选的视频长度：容器目录里视频条目及其后各条目的长度之和，或旧式的 `MicroVideoOffset`。
    private static func declaredLengths(_ xmp: String) -> [Int] {
        var result: [Int] = []
        if let offset = number(after: "MicroVideoOffset", in: xmp) { result.append(offset) }
        let items = xmp.components(separatedBy: "<Container:Item").dropFirst().map { item in
            item.split(separator: ">", maxSplits: 1).first.map(String.init) ?? item
        }
        if let video = items.firstIndex(where: { $0.contains("video/") }) {
            result.append(items[video...].reduce(0) { sum, item in
                sum + (number(after: "Item:Length", in: item) ?? 0) + (number(after: "Item:Padding", in: item) ?? 0)
            })
        }
        return result
    }

    /// 读取 `名称="数字"` 形式的属性值。
    private static func number(after name: String, in text: String) -> Int? {
        guard let range = text.range(of: name + "=\"") else { return nil }
        return Int(text[range.upperBound...].prefix { $0.isNumber })
    }

    /// HEIC、AVIF 等图片也用 ftyp 盒，按品牌排除。
    private static let imageBrands: Set<String> = ["heic", "heix", "hevc", "mif1", "msf1", "avif", "avis", "jxl "]

    private static func isVideoStart(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard offset >= 2, offset + 12 <= bytes.count, Array(bytes[offset + 4..<offset + 8]) == Array("ftyp".utf8) else {
            return false
        }
        let size = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        let brand = String(decoding: bytes[offset + 8..<offset + 12], as: UTF8.self)
        return size >= 12 && size <= 256 && offset + size <= bytes.count && !imageBrands.contains(brand)
    }
}
