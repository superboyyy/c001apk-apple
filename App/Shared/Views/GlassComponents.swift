import SwiftUI

/// 横向滚动的一排 Liquid Glass 胶囊，用作标签栏。
struct GlassTabBar<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    @Namespace private var namespace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        let isSelected = item == selection
                        Button {
                            withAnimation(.smooth(duration: 0.25)) { selection = item }
                        } label: {
                            Text(title(item))
                                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(
                            isSelected ? .regular.tint(.brandFill).interactive() : .regular.interactive(),
                            in: .capsule)
                        .glassEffectID(item, in: namespace)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .scrollClipDisabled()
    }
}

/// 浮在图片上的 Liquid Glass 小标签（计数、GIF 标记等）。
struct GlassBadge: View {
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(1)
        }
        .fixedSize()
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .glassEffect(.regular, in: .capsule)
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        Text(toast.message)
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 22)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
    }
}

extension Color {
    /// 酷安绿。设为应用的 tint，这样不受系统设置里强调色的影响。
    static let brand = Color("AccentColor")
    /// 填充控件用的固定绿色。与 `brand` 不同，它在深色模式下不会变浅，
    /// 白色文字在上面能保持对比度。
    static let brandFill = Color(red: 0.059, green: 0.616, blue: 0.345)
}

/// 关键操作专用的绿底白字 Liquid Glass 样式。
/// 文字颜色直接设在 label 上：否则 prominent 玻璃样式会从 tint 推导，
/// 在深色模式下得到浅绿色。
struct KeyActionButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.foregroundStyle(.white)
        }
        .buttonStyle(.glassProminent)
        .tint(.brandFill)
    }
}

extension View {
    func keyActionButtonStyle() -> some View { buttonStyle(KeyActionButtonStyle()) }
}

/// 整个窗口背后的柔和色彩。Liquid Glass 需要有东西可折射，
/// 在纯色窗口背景上卡片看起来只是普通面板。
struct AppBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        let strong = dark ? 0.42 : 0.34
        let soft = dark ? 0.22 : 0.18
        ZStack {
            Color.windowBackground
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.55, 0.45], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    Color.brand.opacity(strong), Color.teal.opacity(soft), Color.blue.opacity(soft),
                    Color.mint.opacity(soft), Color.clear, Color.brand.opacity(soft),
                    Color.blue.opacity(soft), Color.brand.opacity(soft), Color.mint.opacity(strong),
                ])
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// 卡片和列表行使用的 Liquid Glass 表面。
struct CardBackground: ViewModifier {
    var padding: CGFloat = 14
    var interactive = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.interactive(interactive), in: .rect(cornerRadius: 18, style: .continuous))
    }
}

extension View {
    func card(padding: CGFloat = 14, interactive: Bool = false) -> some View {
        modifier(CardBackground(padding: padding, interactive: interactive))
    }

    /// 用于标签和紧凑按钮的 Liquid Glass 胶囊。
    func glassChip(tint: Color? = nil, interactive: Bool = true) -> some View {
        glassEffect(.regular.tint(tint).interactive(interactive), in: .capsule)
    }
}

/// 计数（赞、回复等），显示为大小适中的玻璃胶囊。
struct GlassCounterLabel: View {
    let text: String
    let systemImage: String
    var isActive = false
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(text).monospacedDigit().lineLimit(1)
        }
        .fixedSize()
        .font(.system(size: compact ? 12 : 13, weight: .medium))
        .foregroundStyle(isActive ? Color.brand : Color.primary.opacity(0.8))
        .padding(.horizontal, compact ? 10 : 12)
        .padding(.vertical, compact ? 5 : 7)
        .contentShape(Capsule())
        .glassChip(tint: isActive ? Color.brand.opacity(0.28) : nil)
    }
}
