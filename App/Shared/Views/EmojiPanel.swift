import ImageIO
import SwiftUI

/// 表情面板：常用 / 牛牛 / 酷币 三组，点选后回调表情短码（如 `[doge]`）。移植自上游 `EmotePanel`。
struct EmojiPanel: View {
    let onPick: (String) -> Void

    private enum Category: String, CaseIterable {
        case common = "常用"
        case niuniu = "牛牛"
        case coin = "酷币"
    }

    @State private var category = Category.common

    private static let keys: [Category: [String]] = {
        func isCoin(_ key: String) -> Bool { key.contains("酷币") || key == "[新币1分]" }
        let all = EmojiOrder.panelKeys
        return [
            .common: all.filter { !$0.hasPrefix("[牛牛") && !isCoin($0) },
            .niuniu: all.filter { $0.hasPrefix("[牛牛") },
            .coin: all.filter(isCoin),
        ]
    }()

    var body: some View {
        VStack(spacing: 4) {
            GlassTabBar(items: Category.allCases, selection: $category) { $0.rawValue }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 38, maximum: 52), spacing: 4)], spacing: 4) {
                    ForEach(Self.keys[category] ?? [], id: \.self) { key in
                        Button {
                            onPick(key)
                        } label: {
                            EmojiIcon(key: key)
                                .frame(width: 28, height: 28)
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(key)
                        .accessibilityLabel(key.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
    }
}

/// 一个表情的图片；资源缺失时退回显示短码文字。
struct EmojiIcon: View {
    let key: String

    var body: some View {
        if let image = EmojiImages.image(for: key) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Text(key).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.5)
        }
    }
}

/// 表情图片的内存缓存，直接从应用包的 `emojis` 目录解码。
@MainActor
enum EmojiImages {
    private static var cache: [String: CGImage] = [:]

    static func image(for key: String) -> CGImage? {
        guard let file = EmojiMap.map[key] else { return nil }
        if let cached = cache[file] { return cached }
        guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "emojis"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        cache[file] = image
        return image
    }
}

/// 往输入框里插入文字的辅助方法。
enum TextInsertion {
    /// 在光标处插入 `fragment`（有选区则替换选区），并把光标移到插入内容之后；没有光标时追加到末尾。
    static func insert(_ fragment: String, into text: inout String, selection: inout TextSelection?) {
        var target: Range<String.Index>?
        if let selection, case .selection(let range) = selection.indices,
           range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex {
            target = range
        }
        guard let target else {
            text += fragment
            selection = TextSelection(insertionPoint: text.endIndex)
            return
        }
        let offset = text.distance(from: text.startIndex, to: target.lowerBound)
        text.replaceSubrange(target, with: fragment)
        let cursor = text.index(text.startIndex, offsetBy: offset + fragment.count, limitedBy: text.endIndex) ?? text.endIndex
        selection = TextSelection(insertionPoint: cursor)
    }
}
