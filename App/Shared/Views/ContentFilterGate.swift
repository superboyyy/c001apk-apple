import CoolapkKit
import SwiftUI

/// 被过滤的内容先显示一张说明卡片，不构建原内容（图片也不会加载）；可临时查看、停用规则或加入例外。
/// 适合详情页和回复这类不便直接从列表里拿掉的位置；列表整行隐藏用 `ContentFilterStore.shouldHide`。
struct ContentFilterGate<Content: View>: View {
    let store: ContentFilterStore
    let entity: Entity
    /// 留空时按行类型推断；转发原文、楼中楼等可以明确指定。
    var scope: FilterScope?
    @ViewBuilder var content: () -> Content

    /// 本次查看已放行的内容键；换了内容自动失效。
    @State private var revealedKey: String?

    var body: some View {
        let key = ContentFilterProjection.key(of: entity, scope: scope)
        if revealedKey != key, let hit = store.match(entity, scope: scope) {
            VStack(alignment: .leading, spacing: 10) {
                Label("已过滤：\(hit.reason)", systemImage: "eye.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("仅本次查看") { revealedKey = key }
                    Menu("更多") {
                        Button("始终显示这条内容") {
                            store.allowContent(entity, scope: scope)
                            revealedKey = key
                        }
                        Button("停用此规则") { store.setRuleDisabled(hit.ruleID, true) }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                }
                .buttonStyle(.glass)
            }
            .card()
        } else {
            content()
        }
    }
}
