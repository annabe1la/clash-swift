import SwiftUI

/// 节点页：代理组展示、节点切换、延迟测速。
struct ProxiesView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var proxyStore: ProxyStore
    @State private var sortByDelay = false

    var body: some View {
        Group {
            if !self.appModel.isRunning {
                ContentUnavailableView(L("内核未运行", "Core not running"), systemImage: "network.slash",
                                       description: Text(L("启动内核后可查看节点与测速。", "Start the core to view proxies and latency.")))
            } else if self.proxyStore.proxyGroups.isEmpty {
                ContentUnavailableView(L("暂无代理组", "No proxy groups"), systemImage: "square.grid.2x2",
                                       description: Text(L("当前配置没有代理组，或仍在加载。", "This config has no proxy groups, or is still loading.")))
            } else {
                self.groupList
            }
        }
        .navigationTitle(L("节点", "Proxies"))
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: self.$sortByDelay) {
                    Label(L("按延迟排序", "Sort by latency"), systemImage: "arrow.up.arrow.down")
                }
                .toggleStyle(.button)
                .disabled(!self.appModel.isRunning)

                Button {
                    Task { await self.appModel.testAllGroups() }
                } label: {
                    Label(L("全部测速", "Test all"), systemImage: "bolt.badge.clock")
                }
                .disabled(!self.appModel.isRunning)

                Button {
                    Task { await self.appModel.refreshProxies() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(!self.appModel.isRunning)
            }
        }
    }

    private var groupList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if !self.proxyStore.proxyProvidersDetail.isEmpty {
                    ProvidersCard()
                }
                ForEach(self.proxyStore.proxyGroups, id: \.name) { group in
                    ProxyGroupCard(group: group, sortByDelay: self.sortByDelay)
                }
            }
            .padding(20)
        }
    }
}

/// 订阅提供者卡片：显示订阅用量/到期，支持更新与健康检查。
private struct ProvidersCard: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var proxyStore: ProxyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("订阅提供者", "Providers"))
                .font(.subheadline.bold()).foregroundStyle(.secondary).textCase(.uppercase)
            ForEach(self.proxyStore.sortedProxyProviderNames, id: \.self) { name in
                if let detail = self.proxyStore.proxyProvidersDetail[name] {
                    providerRow(name: name, detail: detail)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private func providerRow(name: String, detail: ProviderDetail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name).font(.callout.bold())
                if let count = detail.proxies?.count {
                    Text("\(count) \(L("节点", "nodes"))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if self.proxyStore.providerUpdating.contains(name) {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L("更新", "Update")) { Task { await self.appModel.updateProxyProvider(name) } }
                        .controlSize(.small)
                    Button(L("测速", "Test")) { Task { await self.appModel.healthcheckProxyProvider(name) } }
                        .controlSize(.small)
                }
            }
            if let info = detail.subscriptionInfo, let usage = Self.usageText(info) {
                Text(usage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private static func usageText(_ info: ProviderSubscriptionInfo) -> String? {
        let used = (info.upload ?? 0) + (info.download ?? 0)
        var parts: [String] = []
        if let total = info.total, total > 0 {
            parts.append("\(ValueFormatter.bytesCompact(used)) / \(ValueFormatter.bytesCompact(total))")
        } else if used > 0 {
            parts.append(ValueFormatter.bytesCompact(used))
        }
        if let expire = info.expire, expire > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(expire))
            parts.append("\(L("到期", "Expires")) \(ValueFormatter.dateTime(date))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct ProxyGroupCard: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var proxyStore: ProxyStore
    let group: ProxyGroup
    let sortByDelay: Bool

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    /// 节点顺序：可选按延迟升序（无延迟数据的排最后）。
    private var orderedNodes: [String] {
        guard self.sortByDelay else { return self.group.all }
        return self.group.all.sorted { a, b in
            let da = self.proxyStore.proxyDelaySamples[a]?.last
            let db = self.proxyStore.proxyDelaySamples[b]?.last
            switch (da, db) {
            case let (.some(x), .some(y)): return x < y
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return false
            }
        }
    }

    private var isCollapsed: Bool { self.appModel.collapsedGroups.contains(self.group.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    if self.isCollapsed {
                        self.appModel.collapsedGroups.remove(self.group.name)
                    } else {
                        self.appModel.collapsedGroups.insert(self.group.name)
                    }
                } label: {
                    Image(systemName: self.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.bold()).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.group.name).font(.headline)
                    Text("\(self.group.type ?? "—") · \(self.group.all.count) \(L("个节点", "nodes")) · \(self.group.now ?? "—")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if self.proxyStore.groupLatencyLoading.contains(self.group.name) {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await self.appModel.testGroupDelay(group: self.group) }
                    } label: {
                        Label(L("测速", "Test"), systemImage: "bolt.fill").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if !self.isCollapsed {
                LazyVGrid(columns: self.columns, spacing: 10) {
                    ForEach(self.orderedNodes, id: \.self) { node in
                        ProxyNodeCell(
                            node: node,
                            isSelected: self.group.now == node,
                            delay: self.proxyStore.proxyDelaySamples[node]?.last)
                        {
                            Task { await self.appModel.switchProxy(group: self.group.name, to: node) }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ProxyNodeCell: View {
    let node: String
    let isSelected: Bool
    let delay: Int?
    let onTap: () -> Void

    var body: some View {
        Button(action: self.onTap) {
            HStack(spacing: 8) {
                Circle()
                    .fill(self.isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(self.node)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let delay = self.delay {
                    Text("\(delay)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(self.delayColor(delay))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                self.isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(self.isSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func delayColor(_ delay: Int) -> Color {
        switch delay {
        case ..<0, 0: .secondary
        case 1..<200: .green
        case 200..<500: .orange
        default: .red
        }
    }
}
