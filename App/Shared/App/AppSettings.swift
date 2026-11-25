import Observation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum ColumnMode: Int, CaseIterable, Identifiable {
    case automatic = 0, one, two, three, four
    var id: Int { rawValue }
    var title: String { self == .automatic ? "自动" : "\(rawValue) 列" }
}

/// 用户偏好设置，保存在 `UserDefaults`。
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    var showEmoji: Bool { didSet { defaults.set(showEmoji, forKey: "showEmoji") } }
    var columnMode: ColumnMode { didSet { defaults.set(columnMode.rawValue, forKey: "columnMode") } }
    var recordHistory: Bool { didSet { defaults.set(recordHistory, forKey: "recordHistory") } }
    var highQualityThumbnails: Bool { didSet { defaults.set(highQualityThumbnails, forKey: "highQualityThumbnails") } }
    var showReplyPreview: Bool { didSet { defaults.set(showReplyPreview, forKey: "showReplyPreview") } }

    /// “我不想看 HDR”：开启后静态大图始终按 SDR 显示，实况播放与原件保存不受影响。
    var disableHDR: Bool = AppSettings.isHDRDisabled {
        didSet { defaults.set(disableHDR, forKey: AppSettings.disableHDRKey) }
    }
    /// 打开大图时自动播放一次实况。
    var autoPlayLivePhotos: Bool = AppSettings.autoPlaysLivePhotos {
        didSet { defaults.set(autoPlayLivePhotos, forKey: AppSettings.autoPlayLivePhotosKey) }
    }

    nonisolated static let disableHDRKey = "disableHDR"
    nonisolated static let autoPlayLivePhotosKey = "autoPlayLivePhotos"
    /// 已保存的“我不想看 HDR”设置，供不在界面层的代码（如图片查看器）读取。
    nonisolated static var isHDRDisabled: Bool { UserDefaults.standard.bool(forKey: disableHDRKey) }
    /// 已保存的“自动播放实况”设置，默认开启。
    nonisolated static var autoPlaysLivePhotos: Bool {
        UserDefaults.standard.object(forKey: autoPlayLivePhotosKey) == nil
            || UserDefaults.standard.bool(forKey: autoPlayLivePhotosKey)
    }

    init() {
        defaults.register(defaults: [
            "fontSize": 14.0, "showEmoji": true, "recordHistory": true,
            "highQualityThumbnails": false, "showReplyPreview": true,
        ])
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        fontSize = defaults.double(forKey: "fontSize")
        showEmoji = defaults.bool(forKey: "showEmoji")
        columnMode = ColumnMode(rawValue: defaults.integer(forKey: "columnMode")) ?? .automatic
        recordHistory = defaults.bool(forKey: "recordHistory")
        highQualityThumbnails = defaults.bool(forKey: "highQualityThumbnails")
        showReplyPreview = defaults.bool(forKey: "showReplyPreview")
    }
}
