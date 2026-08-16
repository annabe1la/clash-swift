import SwiftUI

/// 连接页：实时连接列表、搜索、传输过滤、关闭。
struct ConnectionsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var connectionsStore: ConnectionsStore
    @State private var search = ""
    @State private var transport: ConnectionsTransportFilter = .all
    @State private var detail: ConnectionSummary?

    private var filtered: [ConnectionSummary] {
        self.connectionsStore.connections.filter { conn in
            self.transport.matches(conn.metadata?.network) && self.matchesSearch(conn)
        }
    }

    private var totalUp: Int64 { self.filtered.reduce(0) { $0 + ($1.upload ?? 0) } }
    private var totalDown: Int64 { self.filtered.reduce(0) { $0 + ($1.download ?? 0) } }

    var body: some View {
        VStack(spacing: 0) {
            self.toolbar
            Divider()
            if !self.appModel.isRunning {
                ContentUnavailableView(L("内核未运行", "Core not running"), systemImage: "network.slash")
                    .frame(maxHeight: .infinity)
            } else if self.filtered.isEmpty {
                ContentUnavailableView(L("暂无连接", "No connections"), systemImage: "link")
                    .frame(maxHeight: .infinity)
            } else {
                self.list
            }
        }
        .navigationTitle(L("连接", "Connections"))
        .sheet(item: self.$detail) { conn in
            ConnectionDetailView(conn: conn)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("搜索 host / IP / 链路", "Search host / IP / chain"), text: self.$search)
                .textFieldStyle(.plain)
            Picker("", selection: self.$transport) {
                ForEach(ConnectionsTransportFilter.allCases) { f in
                    Text(f.rawValue.uppercased()).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Text("↑\(ValueFormatter.bytesCompact(self.totalUp)) ↓\(ValueFormatter.bytesCompact(self.totalDown))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(self.connectionsStore.connectionsCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button(role: .destructive) {
                Task { await self.appModel.closeAllConnections() }
            } label: {
                Label(L("全部关闭", "Close all"), systemImage: "xmark.circle")
            }
            .controlSize(.small)
            .disabled(self.filtered.isEmpty)
        }
        .padding(12)
    }

    private var list: some View {
        List(self.filtered) { conn in
            ConnectionRow(conn: conn) {
                Task { await self.appModel.closeConnection(id: conn.id) }
            }
            .contentShape(Rectangle())
            .onTapGesture { self.detail = conn }
        }
        .listStyle(.inset)
    }

    private func matchesSearch(_ conn: ConnectionSummary) -> Bool {
        let q = self.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let haystack = [
            conn.metadata?.host,
            conn.metadata?.destinationIP,
            conn.metadata?.sourceIP,
            conn.rule,
            conn.rulePayload,
        ].compactMap { $0 }.joined(separator: " ").lowercased()
        let chains = (conn.chains ?? []).joined(separator: " ").lowercased()
        return haystack.contains(q) || chains.contains(q)
    }
}

private struct ConnectionRow: View {
    let conn: ConnectionSummary
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(self.title).font(.callout).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if let net = self.conn.metadata?.network {
                        Tag(net.uppercased())
                    }
                    if let chain = self.conn.chains?.first {
                        Text(chain).font(.caption).foregroundStyle(.secondary)
                    }
                    if let rule = self.conn.rule {
                        Text("· \(rule)").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("↑ \(ValueFormatter.bytesCompact(self.conn.upload ?? 0))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.blue)
                Text("↓ \(ValueFormatter.bytesCompact(self.conn.download ?? 0))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.green)
            }
            Button(action: self.onClose) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        let m = self.conn.metadata
        let host = m?.host?.trimmedNonEmpty ?? m?.destinationIP?.trimmedNonEmpty ?? "—"
        return host
    }
}

/// 连接详情弹窗。
private struct ConnectionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let conn: ConnectionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("连接详情", "Connection Detail")).font(.headline)
                Spacer()
                Button(L("关闭", "Close")) { self.dismiss() }
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    row(L("主机", "Host"), self.conn.metadata?.host)
                    row(L("目标 IP", "Dest IP"), self.conn.metadata?.destinationIP)
                    row(L("来源 IP", "Source IP"), self.conn.metadata?.sourceIP)
                    row(L("传输", "Network"), self.conn.metadata?.network?.uppercased())
                    row(L("规则", "Rule"), [self.conn.rule, self.conn.rulePayload].compactMap { $0 }.joined(separator: " / "))
                    row(L("代理链路", "Chains"), (self.conn.chains ?? []).joined(separator: " → "))
                    row(L("上传", "Upload"), ValueFormatter.bytesCompact(self.conn.upload ?? 0))
                    row(L("下载", "Download"), ValueFormatter.bytesCompact(self.conn.download ?? 0))
                    row(L("开始时间", "Started"), self.conn.start)
                }
                .padding(16)
            }
        }
        .frame(width: 460, height: 380)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                Text(value).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct Tag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(self.text)
            .font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }
}
