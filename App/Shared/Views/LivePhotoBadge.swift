import CoolapkKit
import SwiftUI

/// 缩略图上的“实况”角标。
struct LivePhotoBadge: View {
    var body: some View {
        ImageBadge(text: "实况", systemImage: "livephoto")
            .accessibilityLabel("实况图片")
    }
}

/// 缩略图上的“HDR”角标。
struct HDRBadge: View {
    var body: some View {
        ImageBadge(text: "HDR")
            .accessibilityLabel("HDR 图片")
    }
}

/// 按素材元数据显示“实况 / HDR”角标；两者都不是时不占位置。
struct MediaBadges: View {
    let media: FeedMedia

    init(_ media: FeedMedia) {
        self.media = media
    }

    /// 只有图片地址时，按酷安文件名里的标记判断。
    init(url: String) {
        self.init(FeedMedia(url: url))
    }

    var body: some View {
        if media.isLivePhoto || media.isHDR {
            HStack(spacing: 4) {
                if media.isLivePhoto { LivePhotoBadge() }
                if media.isHDR { HDRBadge() }
            }
        }
    }
}
