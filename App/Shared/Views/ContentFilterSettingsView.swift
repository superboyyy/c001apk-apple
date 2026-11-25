import CoolapkKit
import SwiftUI

/// 内容过滤设置：开关、档位、规则分类、订阅、个人规则与例外。
struct ContentFilterSettingsView: View {
    let store: ContentFilterStore

    @State private var subscriptionDraft = ""
    @State private var subscriptionError: String?
    @State private var ruleKind = FilterRuleKind.text
    @State private var ruleDraft = ""
    @State private var ruleError: String?
    @State private var authorDraft = ""
    @State private var authorError: String?
    @State private var showsTextRules = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                switchCard
                levelCard
                categoryCard
                subscriptionCard
                personalRulesCard
                allowedAuthorsCard
                allowedContentCard
                Text("误屏蔽时可以临时查看、停用规则或添加例外。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            .frame(maxWidth: 720)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .navigationTitle("内容过滤")
        .onAppear { subscriptionDraft = store.filter.subscriptionURL }
    }

    // MARK: 开关与档位

    private var switchCard: some View {
        Toggle(isOn: Binding(get: { store.isEnabled }, set: { store.isEnabled = $0 })) {
            VStack(alignment: .leading, spacing: 3) {
                Text("内容过滤").font(.headline)
                Text("减少低俗内容打扰，让浏览更清爽。默认关闭，所有判断都在本机完成。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .card()
    }

    private var levelCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("过滤强度")
            Picker("过滤强度", selection: Binding(get: { store.level }, set: { store.level = $0 })) {
                Text("标准").tag(FilterLevel.standard)
                Text("严格").tag(FilterLevel.strict)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            hint(store.level == .strict ? "包含标准规则，过滤更强，误屏蔽可能更多。" : "使用审核过的名单与明确短语，尽量减少误屏蔽。")
        }
        .card()
    }

    // MARK: 规则与名单

    private var categoryCard: some View {
        let rules = store.filter.ruleSet.rules
        let textRules = rules.filter { $0.kind == .text }
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("规则与名单")
            listToggle("频繁发布低俗内容的用户", kind: .author, count: rules.filter { $0.kind == .author }.count)
            listToggle("低俗内容相关话题", kind: .topic, count: rules.filter { $0.kind == .topic }.count)
            if !textRules.isEmpty {
                DisclosureGroup("内容规则（\(textRules.count) 条）", isExpanded: $showsTextRules) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(textRules) { rule in
                            Toggle(isOn: Binding(get: { !store.isRuleDisabled(rule.id) },
                                                 set: { store.setRuleDisabled(rule.id, !$0) })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(rule.reason)
                                    Text(rule.level == .strict ? "仅严格档" : "标准与严格")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.switch)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .card()
    }

    private func listToggle(_ title: String, kind: FilterRuleKind, count: Int) -> some View {
        Toggle(isOn: Binding(get: { store.isListEnabled(kind) }, set: { store.setListEnabled(kind, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("\(count) 条名单规则").font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    // MARK: 订阅

    private var subscriptionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("规则更新")
            HStack {
                Text("规则版本 \(store.filter.ruleSet.revision)")
                Spacer()
                Text("上次成功检查：\(checkedText)").foregroundStyle(.secondary)
            }
            .font(.callout)
            HStack(spacing: 8) {
                TextField("订阅地址（https，留空则不联网）", text: $subscriptionDraft)
                    .textFieldStyle(.roundedBorder)
                    .plainInput(.url)
                    .onSubmit(saveSubscription)
                Button("保存", action: saveSubscription)
                    .buttonStyle(.glass)
                    .disabled(subscriptionDraft.trimmingCharacters(in: .whitespaces) == store.filter.subscriptionURL)
            }
            HStack(spacing: 8) {
                Button("检查规则更新") {
                    Task { await store.checkForUpdates(force: true) }
                }
                .buttonStyle(.glass)
                .disabled(store.isUpdating || store.filter.subscriptionURL.isEmpty)
                Menu("更多") {
                    Button("填入上游规则地址") { subscriptionDraft = ContentFilterStore.upstreamRulesURL }
                    Button("恢复内置规则") { store.resetToBuiltinRules() }
                }
                .menuStyle(.button)
                .buttonStyle(.glass)
                .fixedSize()
                if store.isUpdating { ProgressView().controlSize(.small) }
            }
            if let subscriptionError {
                problem(subscriptionError)
            } else {
                hint(store.updateMessage ?? "只有保存了订阅地址才会联网；更新失败会继续使用已有规则。订阅整体替换内置规则，不影响个人规则和例外。")
            }
        }
        .card()
    }

    private var checkedText: String {
        store.filter.lastCheckedAt?.formatted(date: .numeric, time: .shortened) ?? "尚未成功检查"
    }

    private func saveSubscription() {
        do {
            try store.setSubscriptionURL(subscriptionDraft)
            subscriptionDraft = store.filter.subscriptionURL
            subscriptionError = nil
            Task { await store.checkForUpdates() }
        } catch {
            subscriptionError = "订阅地址必须是 https 链接"
        }
    }

    // MARK: 个人规则

    private var personalRulesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("个人规则")
            Picker("类型", selection: $ruleKind) {
                ForEach([FilterRuleKind.text, .author, .topic], id: \.self) { Text(kindName($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 8) {
                TextField(kindName(ruleKind), text: $ruleDraft)
                    .textFieldStyle(.roundedBorder)
                    .plainInput(ruleKind == .author ? .number : .text)
                    .onSubmit(addRule)
                Button("添加", action: addRule)
                    .buttonStyle(.glass)
                    .disabled(ruleDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let ruleError {
                problem(ruleError)
            } else {
                hint(kindHint(ruleKind) + " 更新订阅不会覆盖个人规则。")
            }
            ForEach(store.filter.personalRules) { rule in
                entryRow(title: ruleValue(rule), subtitle: kindName(rule.kind), symbol: "trash",
                         label: "删除个人规则：\(ruleValue(rule))") {
                    store.removePersonalRule(rule.id)
                }
            }
        }
        .card()
        .onChange(of: ruleKind) { ruleError = nil }
    }

    private func addRule() {
        let value = ruleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try store.addPersonalRule(kind: ruleKind, value: value)
            ruleDraft = ""
            ruleError = nil
        } catch {
            ruleError = ruleKind == .text ? "该短语不能作为过滤规则" : "请填写有效的\(kindName(ruleKind))"
        }
    }

    private func kindName(_ kind: FilterRuleKind) -> String {
        switch kind {
        case .author: return "作者 UID"
        case .topic: return "话题"
        case .text: return "文本短语"
        }
    }

    private func kindHint(_ kind: FilterRuleKind) -> String {
        switch kind {
        case .author: return "只按实际作者 UID 匹配。"
        case .topic: return "填写完整话题名或话题 ID。"
        case .text: return "按完整短语匹配，不支持正则表达式。"
        }
    }

    private func ruleValue(_ rule: FilterRule) -> String {
        rule.kind == .text
            ? rule.groups.map { $0.joined(separator: " / ") }.joined(separator: " + ")
            : rule.values.joined(separator: "、")
    }

    // MARK: 例外

    private var allowedAuthorsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("允许显示的作者")
            HStack(spacing: 8) {
                TextField("作者 UID", text: $authorDraft)
                    .textFieldStyle(.roundedBorder)
                    .plainInput(.number)
                    .onSubmit(addAuthor)
                Button("添加", action: addAuthor)
                    .buttonStyle(.glass)
                    .disabled(authorDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let authorError {
                problem(authorError)
            } else {
                hint("始终让该作者的内容通过内容过滤；本机屏蔽名单需要单独管理。")
            }
            ForEach(store.filter.allowedAuthorUIDs.sorted(), id: \.self) { uid in
                entryRow(title: "UID \(uid)", subtitle: nil, symbol: "xmark", label: "移除作者例外：\(uid)") {
                    try? store.setAuthorAllowed(uid, false)
                }
            }
        }
        .card()
    }

    private func addAuthor() {
        let uid = authorDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty else { return }
        guard ContentFilter.isValidUID(uid), (try? store.setAuthorAllowed(uid, true)) != nil else {
            authorError = "请输入有效的作者 UID"
            return
        }
        authorDraft = ""
        authorError = nil
    }

    private var allowedContentCard: some View {
        let keys = store.filter.allowedContentKeys.sorted()
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("允许显示的内容")
            if keys.isEmpty {
                hint("暂无内容例外。在被过滤的内容上选择“始终显示”后会出现在这里；“仅本次查看”不会保存。")
            }
            ForEach(keys, id: \.self) { key in
                entryRow(title: contentTitle(key), subtitle: nil, symbol: "xmark", label: "移除内容例外：\(contentTitle(key))") {
                    try? store.setContentAllowed(key, false)
                }
            }
        }
        .card()
    }

    /// 把 `feed:123` 这样的键换成读得懂的说法。
    private func contentTitle(_ key: String) -> String {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let scope = FilterScope(rawValue: parts[0]) else { return key }
        switch scope {
        case .feed: return "动态 \(parts[1])"
        case .comment: return "回复 \(parts[1])"
        case .user: return "用户 \(parts[1])"
        }
    }

    // MARK: 小部件

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func problem(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
    }

    private func entryRow(title: String, subtitle: String?, symbol: String, label: String,
                          action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(2).textSelection(.enabled)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Button(action: action) {
                Image(systemName: symbol)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(label)
            .accessibilityLabel(label)
        }
    }
}

/// 设置页输入框的键盘类型。
private enum PlainInputKind { case text, number, url }

private extension View {
    /// 关闭自动纠错；在 iPadOS 上同时关闭首字母大写并选择合适的键盘。
    @ViewBuilder
    func plainInput(_ kind: PlainInputKind) -> some View {
        #if os(iOS)
        self.autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(kind == .number ? .numberPad : (kind == .url ? .URL : .default))
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
