import Charts
import SwiftUI

/// 概览仪表盘（参考 clash-verge home）：控制卡 + 统计卡网格 + 流量曲线。
struct OverviewView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var traffic: TrafficStore
    @EnvironmentObject private var connections: ConnectionsStore
    @EnvironmentObject private var proxyStore: ProxyStore

    private let statColumns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                self.controlCard
                self.statGrid
                if self.traffic.trafficHistoryUp.count > 1 {
                    self.trafficCard
                }
                if let error = self.appModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .textSelection(.enabled)
                }
            }
            .padding(20)
        }
        .navigationTitle(L("概览", "Overview"))
    }

    // MARK: 控制卡

    private var controlCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(self.appModel.isRunning ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: self.appModel.isRunning ? "bolt.horizontal.fill" : "bolt.horizontal")
                        .font(.title3)
                        .foregroundStyle(self.appModel.isRunning ? Color.green : .secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.statusText).font(.headline)
                    Text("\(L("版本", "Version")) \(self.appModel.versionText) · \(self.appModel.controllerDisplay)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let name = self.appModel.selectedConfigName {
                        Text(name).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        Task { await self.appModel.performPrimaryCoreAction() }
                    } label: {
                        Label(self.appModel.isRunning ? L("重启", "Restart") : L("启动", "Start"),
                              systemImage: self.appModel.isRunning ? "arrow.clockwise" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(self.appModel.isBusy)
                    Button {
                        Task { await self.appModel.stopCore() }
                    } label: { Image(systemName: "stop.fill") }
                        .disabled(!self.appModel.isRunning || self.appModel.isBusy)
                }
            }

            Picker("", selection: Binding(
                get: { self.appModel.currentMode },
                set: { m in Task { await self.appModel.switchMode(to: m) } }))
            {
                Text(L("规则", "Rule")).tag(CoreMode.rule)
                Text(L("全局", "Global")).tag(CoreMode.global)
                Text(L("直连", "Direct")).tag(CoreMode.direct)
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(!self.appModel.isRunning)

            HStack(spacing: 20) {
                Toggle(isOn: Binding(
                    get: { self.appModel.isSystemProxyEnabled },
                    set: { _ in Task { await self.appModel.toggleSystemProxy() } }))
                {
                    Text(L("系统代理", "System Proxy")).font(.callout)
                }
                .toggleStyle(.switch)
                .disabled(!self.appModel.isRunning || self.proxyStore.isProxySyncing)
                if self.proxyStore.isProxySyncing {
                    ProgressView().controlSize(.small)
                }

                Toggle(isOn: Binding(
                    get: { self.appModel.isTunEnabled },
                    set: { _ in Task { await self.appModel.toggleTun() } }))
                {
                    Text("TUN").font(.callout)
                }
                .toggleStyle(.switch).disabled(self.appModel.isBusy)
                Spacer()

                Button {
                    Task { await self.appModel.copyTerminalProxyCommand() }
                } label: {
                    Label(L("复制终端代理命令", "Copy terminal proxy cmd"), systemImage: "terminal")
                }
                .controlSize(.small)
                .disabled(!self.appModel.isRunning)
            }
            if let status = self.appModel.systemProxyStatusText {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let action = self.appModel.actionMessage {
                Text(action).font(.caption).foregroundStyle(.green)
                    .textSelection(.enabled).lineLimit(2)
            }
        }
        .cardSurface()
    }

    private var statusText: String {
        switch self.appModel.lifecycle {
        case .stopped: L("内核已停止", "Core stopped")
        case .starting: L("启动中…", "Starting…")
        case let .running(pid): "\(L("运行中", "Running")) · pid \(pid)"
        case let .failed(reason): "\(L("失败", "Failed"))：\(reason)"
        }
    }

    // MARK: 统计卡网格

    private var statGrid: some View {
        LazyVGrid(columns: self.statColumns, spacing: 12) {
            StatTile(icon: "arrow.up.circle.fill", tint: .blue,
                     title: L("上传", "Upload"), value: ValueFormatter.speed(self.traffic.traffic.up))
            StatTile(icon: "arrow.down.circle.fill", tint: .green,
                     title: L("下载", "Download"), value: ValueFormatter.speed(self.traffic.traffic.down))
            StatTile(icon: "tray.and.arrow.up.fill", tint: .indigo,
                     title: L("总上传", "Total Up"), value: ValueFormatter.bytesCompact(self.traffic.displayUpTotal))
            StatTile(icon: "tray.and.arrow.down.fill", tint: .teal,
                     title: L("总下载", "Total Down"), value: ValueFormatter.bytesCompact(self.traffic.displayDownTotal))
            StatTile(icon: "memorychip.fill", tint: .purple,
                     title: L("内存", "Memory"), value: ValueFormatter.bytesCompact(self.traffic.memory.inuse))
            StatTile(icon: "link.circle.fill", tint: .orange,
                     title: L("活跃连接", "Connections"), value: "\(self.connections.connectionsCount)")
        }
    }

    // MARK: 流量曲线

    private var trafficCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("实时流量", "Live Traffic"))
                .font(.subheadline.bold()).foregroundStyle(.secondary).textCase(.uppercase)
            Chart {
                ForEach(Array(self.traffic.trafficHistoryUp.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("t", i), y: .value("v", v), series: .value("s", "up"))
                        .foregroundStyle(.blue.opacity(0.12)).interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", i), y: .value("v", v), series: .value("s", "up"))
                        .foregroundStyle(.blue).interpolationMethod(.catmullRom)
                }
                ForEach(Array(self.traffic.trafficHistoryDown.enumerated()), id: \.offset) { i, v in
                    AreaMark(x: .value("t", i), y: .value("v", v), series: .value("s", "down"))
                        .foregroundStyle(.green.opacity(0.12)).interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", i), y: .value("v", v), series: .value("s", "down"))
                        .foregroundStyle(.green).interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Int64.self) { Text(ValueFormatter.speed(v)).font(.caption2) } }
                }
            }
            .frame(height: 150)
        }
        .cardSurface()
    }
}

/// 统计卡片单元。
struct StatTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: self.icon).font(.title2).foregroundStyle(self.tint)
            Text(self.value).font(.title3.monospacedDigit().bold()).lineLimit(1).minimumScaleFactor(0.6)
            Text(self.title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

/// 统一卡片容器（标题版，供其他页复用）。
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(self.title).font(.subheadline.bold()).foregroundStyle(.secondary).textCase(.uppercase)
            self.content
        }
        .cardSurface()
    }
}

/// 统一卡片外观修饰。
extension View {
    func cardSurface() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 0.5))
    }
}
