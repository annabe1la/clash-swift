import SwiftUI

/// 规则页：规则列表、类型过滤、搜索、统计。
struct RulesView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var proxyStore: ProxyStore
    @State private var search = ""
    @State private var typeFilter: RulesTypeFilter = .all

    private var filtered: [RuleItem] {
        self.proxyStore.ruleItems.filter { rule in
            self.typeFilter.matches(rule.type) && self.matchesSearch(rule)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            self.toolbar
            Divider()
            if !self.proxyStore.ruleProviders.isEmpty {
                self.ruleProvidersBar
                Divider()
            }
            if !self.appModel.isRunning {
                ContentUnavailableView(L("内核未运行", "Core not running"), systemImage: "network.slash")
                    .frame(maxHeight: .infinity)
            } else if self.filtered.isEmpty {
                ContentUnavailableView(L("暂无规则", "No rules"), systemImage: "arrow.left.arrow.right")
                    .frame(maxHeight: .infinity)
            } else {
                List(Array(self.filtered.enumerated()), id: \.offset) { _, rule in
                    RuleRow(rule: rule)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(L("规则", "Rules"))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("搜索规则", "Search rules"), text: self.$search)
                .textFieldStyle(.plain)
            Picker("", selection: self.$typeFilter) {
                ForEach(RulesTypeFilter.allCases) { f in
                    Text(self.typeTitle(f)).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Text("\(self.proxyStore.rulesCount)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button {
                Task { await self.appModel.refreshRules() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(!self.appModel.isRunning)
        }
        .padding(12)
    }

    private var ruleProvidersBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(L("规则集", "Rule Providers")).font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(self.proxyStore.ruleProviders.keys.sorted(), id: \.self) { name in
                    Button {
                        Task { await self.appModel.updateRuleProvider(name) }
                    } label: {
                        Label(name, systemImage: "arrow.triangle.2.circlepath").font(.caption)
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func typeTitle(_ f: RulesTypeFilter) -> String {
        switch f {
        case .all: L("全部", "All")
        case .domain: L("域名", "Domain")
        case .ip: "IP"
        case .ruleSet: L("规则集", "Rule-set")
        case .other: L("其他", "Other")
        }
    }

    private func matchesSearch(_ rule: RuleItem) -> Bool {
        let q = self.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let hay = [rule.type, rule.payload, rule.proxy].compactMap { $0 }.joined(separator: " ").lowercased()
        return hay.contains(q)
    }
}

private struct RuleRow: View {
    let rule: RuleItem

    var body: some View {
        HStack(spacing: 10) {
            Text(self.rule.type ?? "—")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(self.rule.payload ?? "")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(self.rule.proxy ?? "")
                .font(.caption)
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 2)
    }
}
