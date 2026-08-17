import SwiftUI

/// 连接页：表格化的实时连接列表、搜索、传输过滤、总量、详情、关闭。
struct ConnectionsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var connectionsStore: ConnectionsStore
    @State private var search = ""
    @State private var transport: ConnectionsTransportFilter = .all
    @State private var selection: ConnectionSummary.ID?
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
                self.table
            }
        }
        .navigationTitle(L("连接", "Connections"))
        .sheet(item: self.$detail) { ConnectionDetailView(conn: $0) }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("搜索 host / IP / 进程 / 链路", "Search host / IP / process / chain"), text: self.$search)
                .textFieldStyle(.plain)
            Picker("", selection: self.$transport) {
                ForEach(ConnectionsTransportFilter.allCases) { Text($0.rawValue.uppercased()).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()
            Text("↑\(ValueFormatter.bytesCompact(self.totalUp)) ↓\(ValueFormatter.bytesCompact(self.totalDown))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("\(self.connectionsStore.connectionsCount)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button(role: .destructive) {
                Task { await self.appModel.closeAllConnections() }
            } label: { Label(L("全部关闭", "Close all"), systemImage: "xmark.circle") }
                .controlSize(.small).disabled(self.filtered.isEmpty)
        }
        .padding(12)
    }

    private var table: some View {
        Table(self.filtered, selection: self.$selection) {
            TableColumn(L("主机 / 目标", "Host / Dest")) { conn in
                Text(self.host(conn)).lineLimit(1).truncationMode(.middle)
            }
            TableColumn(L("进程", "Process")) { conn in
                Text(conn.metadata?.process?.trimmedNonEmpty ?? "—")
                    .foregroundStyle(.secondary).lineLimit(1)
            }
            TableColumn(L("传输", "Net")) { conn in
                Text((conn.metadata?.network ?? "").uppercased()).foregroundStyle(.secondary)
            }.width(50)
            TableColumn(L("链路", "Chain")) { conn in
                Text((conn.chains ?? []).joined(separator: " → ")).foregroundStyle(.secondary).lineLimit(1)
            }
            TableColumn(L("规则", "Rule")) { conn in
                Text(conn.rule ?? "").foregroundStyle(.tertiary).lineLimit(1)
            }
            TableColumn("↑") { conn in
                Text(ValueFormatter.bytesCompact(conn.upload ?? 0))
                    .font(.caption.monospacedDigit()).foregroundStyle(.blue)
            }.width(70)
            TableColumn("↓") { conn in
                Text(ValueFormatter.bytesCompact(conn.download ?? 0))
                    .font(.caption.monospacedDigit()).foregroundStyle(.green)
            }.width(70)
        }
        .contextMenu(forSelectionType: ConnectionSummary.ID.self) { ids in
            if let id = ids.first {
                Button(L("查看详情", "Details")) {
                    self.detail = self.filtered.first { $0.id == id }
                }
                Button(role: .destructive, action: { Task { await self.appModel.closeConnection(id: id) } }) {
                    Text(L("关闭连接", "Close connection"))
                }
            }
        } primaryAction: { ids in
            if let id = ids.first { self.detail = self.filtered.first { $0.id == id } }
        }
    }

    private func host(_ conn: ConnectionSummary) -> String {
        conn.metadata?.host?.trimmedNonEmpty ?? conn.metadata?.destinationIP?.trimmedNonEmpty ?? "—"
    }

    private func matchesSearch(_ conn: ConnectionSummary) -> Bool {
        let q = self.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        let hay = [conn.metadata?.host, conn.metadata?.destinationIP, conn.metadata?.sourceIP,
                   conn.metadata?.process, conn.rule, conn.rulePayload]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let chains = (conn.chains ?? []).joined(separator: " ").lowercased()
        return hay.contains(q) || chains.contains(q)
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
                    row(L("进程", "Process"), self.conn.metadata?.process)
                    row(L("进程路径", "Process Path"), self.conn.metadata?.processPath)
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
        .frame(width: 480, height: 420)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                Text(value).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
