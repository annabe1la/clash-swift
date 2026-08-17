import SwiftUI

/// 诊断页：内核冲突检测、系统代理指向、走代理的进程。
struct DiagnosticsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var connectionsStore: ConnectionsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                self.coresCard
                self.proxyCard
                self.processesCard
                if let msg = self.appModel.actionMessage {
                    Text(msg).font(.caption).foregroundStyle(.green)
                }
                if let err = self.appModel.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(20)
        }
        .navigationTitle(L("诊断", "Diagnostics"))
        .task { await self.appModel.refreshDiagnostics() }
        .toolbar {
            ToolbarItem {
                Button { Task { await self.appModel.refreshDiagnostics() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: 内核进程 / 冲突

    private var coresCard: some View {
        Card(title: L("内核进程", "Core Processes")) {
            VStack(alignment: .leading, spacing: 10) {
                let foreign = self.appModel.coreProcesses.filter { $0.pid != self.appModel.ourCorePID }
                if self.appModel.coreProcesses.count > 1 || !foreign.isEmpty && self.appModel.isRunning {
                    Label(L("检测到多个内核，可能与本应用冲突。建议只保留一个。",
                            "Multiple cores detected — may conflict. Keep only one."),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                } else if self.appModel.coreProcesses.isEmpty {
                    Text(L("未发现运行中的 mihomo / clash 内核。", "No running mihomo / clash core found."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(self.appModel.coreProcesses) { core in
                    coreRow(core)
                }
            }
        }
    }

    private func coreRow(_ core: CoreProcessInfo) -> some View {
        let isOurs = core.pid == self.appModel.ourCorePID
        return HStack(alignment: .top, spacing: 10) {
            Circle().fill(isOurs ? Color.green : Color.orange).frame(width: 8, height: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("PID \(core.pid)").font(.callout.bold())
                    if isOurs {
                        Text(L("本应用", "This app")).font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.green.opacity(0.18), in: Capsule()).foregroundStyle(.green)
                    } else {
                        Text(L("外部", "External")).font(.caption2)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
                    }
                    if !core.ports.isEmpty {
                        Text(L("端口", "Ports") + " " + core.ports.map(String.init).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(core.command).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer()
            if !isOurs {
                Button(role: .destructive) {
                    Task { await self.appModel.killCore(pid: core.pid) }
                } label: { Text(L("结束", "Kill")) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: 系统代理指向

    private var proxyCard: some View {
        Card(title: L("代理指向", "Proxy Target")) {
            VStack(alignment: .leading, spacing: 8) {
                infoRow(L("控制器", "Controller"), self.appModel.controllerDisplay)
                infoRow("TUN", self.appModel.isTunEnabled ? L("已开启（全局路由）", "On (global route)") : L("关闭", "Off"))
                if let readout = self.appModel.systemProxyReadout {
                    infoRow(L("网络服务", "Network service"), readout.service)
                    proxyLine("HTTP", readout.http)
                    proxyLine("HTTPS", readout.https)
                    proxyLine("SOCKS", readout.socks)
                    if readout.anyEnabled, !self.appModel.isSystemProxyEnabled {
                        Label(L("系统代理已开启，但不是本应用设置的——可能由其他 Clash 客户端占用，易冲突。",
                                "System proxy is on but not set by this app — likely another Clash client. May conflict."),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !readout.anyEnabled, !self.appModel.isTunEnabled {
                        Text(L("系统代理与 TUN 均未开启——流量不会经过本内核。",
                               "Neither system proxy nor TUN is on — traffic won't go through this core."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(L("读取中…", "Reading…")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func proxyLine(_ label: String, _ entry: ProxyEntry?) -> some View {
        if let entry, entry.enabled {
            infoRow(label, "\(entry.server):\(entry.port)", tint: .green)
        } else {
            infoRow(label, L("关闭", "Off"), tint: .secondary)
        }
    }

    // MARK: 走代理的进程

    private var processesCard: some View {
        Card(title: L("走代理的进程", "Proxied Processes")) {
            let grouped = self.processAggregates
            VStack(alignment: .leading, spacing: 8) {
                if grouped.isEmpty {
                    Text(self.appModel.isRunning
                        ? L("暂无活跃连接，或内核未开启 find-process-mode。",
                            "No active connections, or find-process-mode is off.")
                        : L("内核未运行。", "Core not running."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(grouped, id: \.name) { item in
                    HStack {
                        Image(systemName: "app.dashed").foregroundStyle(.tint)
                        Text(item.name).font(.callout)
                        Spacer()
                        Text("\(item.count) \(L("连接", "conns"))").font(.caption).foregroundStyle(.secondary)
                        Text("↑\(ValueFormatter.bytesCompact(item.up)) ↓\(ValueFormatter.bytesCompact(item.down))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private struct ProcessAggregate { let name: String; let count: Int; let up: Int64; let down: Int64 }

    private var processAggregates: [ProcessAggregate] {
        var map: [String: (count: Int, up: Int64, down: Int64)] = [:]
        for conn in self.connectionsStore.connections {
            let name = conn.metadata?.process?.trimmedNonEmpty
                ?? conn.metadata?.host?.trimmedNonEmpty
                ?? "—"
            var e = map[name] ?? (0, 0, 0)
            e.count += 1; e.up += conn.upload ?? 0; e.down += conn.download ?? 0
            map[name] = e
        }
        return map.map { ProcessAggregate(name: $0.key, count: $0.value.count, up: $0.value.up, down: $0.value.down) }
            .sorted { ($0.up + $0.down) > ($1.up + $1.down) }
    }

    // MARK: helpers

    private func infoRow(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).font(.callout).foregroundStyle(tint).textSelection(.enabled)
            Spacer()
        }
    }
}
