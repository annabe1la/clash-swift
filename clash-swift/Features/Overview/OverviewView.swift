import Charts
import SwiftUI

/// 概览页：内核启停、模式切换、系统代理、实时流量。
struct OverviewView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var traffic: TrafficStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                self.statusCard
                self.modeCard
                self.trafficCard
                if let error = self.appModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(20)
        }
        .navigationTitle(L("概览", "Overview"))
    }

    // MARK: 状态 / 启停

    private var statusCard: some View {
        Card(title: L("内核", "Core")) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(self.appModel.isRunning ? Color.green : Color.secondary)
                            .frame(width: 10, height: 10)
                        Text(self.statusText).font(.headline)
                    }
                    Text("\(L("版本", "Version")) \(self.appModel.versionText) · \(self.appModel.controllerDisplay)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let name = self.appModel.selectedConfigName {
                        Text("\(L("配置", "Config"))：\(name)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 10) {
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
                    } label: {
                        Label(L("停止", "Stop"), systemImage: "stop.fill")
                    }
                    .disabled(!self.appModel.isRunning || self.appModel.isBusy)
                }
            }
        }
    }

    private var statusText: String {
        switch self.appModel.lifecycle {
        case .stopped: L("已停止", "Stopped")
        case .starting: L("启动中…", "Starting…")
        case let .running(pid): "\(L("运行中", "Running")) (pid \(pid))"
        case let .failed(reason): "\(L("失败", "Failed"))：\(reason)"
        }
    }

    // MARK: 模式 + 系统代理

    private var modeCard: some View {
        Card(title: L("模式与系统代理", "Mode & System Proxy")) {
            VStack(alignment: .leading, spacing: 14) {
                Picker(L("模式", "Mode"), selection: Binding(
                    get: { self.appModel.currentMode },
                    set: { newValue in Task { await self.appModel.switchMode(to: newValue) } }))
                {
                    Text(L("规则", "Rule")).tag(CoreMode.rule)
                    Text(L("全局", "Global")).tag(CoreMode.global)
                    Text(L("直连", "Direct")).tag(CoreMode.direct)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!self.appModel.isRunning)

                Toggle(isOn: Binding(
                    get: { self.appModel.isSystemProxyEnabled },
                    set: { _ in Task { await self.appModel.toggleSystemProxy() } }))
                {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("系统代理", "System Proxy"))
                        if let status = self.appModel.systemProxyStatusText {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .toggleStyle(.switch)
                .disabled(!self.appModel.isRunning)
            }
        }
    }

    // MARK: 实时流量

    private var trafficCard: some View {
        Card(title: L("实时流量", "Live Traffic")) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 28) {
                    metric(symbol: "arrow.up", tint: .blue,
                           title: L("上传", "Upload"), value: ValueFormatter.speed(self.traffic.traffic.up))
                    metric(symbol: "arrow.down", tint: .green,
                           title: L("下载", "Download"), value: ValueFormatter.speed(self.traffic.traffic.down))
                    metric(symbol: "memorychip", tint: .purple,
                           title: L("内存", "Memory"), value: ValueFormatter.bytesCompact(self.traffic.memory.inuse))
                    Spacer()
                }
                if self.traffic.trafficHistoryUp.count > 1 {
                    self.trafficChart
                }
            }
        }
    }

    private var trafficChart: some View {
        Chart {
            ForEach(Array(self.traffic.trafficHistoryUp.enumerated()), id: \.offset) { index, value in
                LineMark(x: .value("t", index), y: .value("v", value),
                         series: .value("s", "up"))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)
            }
            ForEach(Array(self.traffic.trafficHistoryDown.enumerated()), id: \.offset) { index, value in
                LineMark(x: .value("t", index), y: .value("v", value),
                         series: .value("s", "down"))
                    .foregroundStyle(.green)
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Int64.self) {
                        Text(ValueFormatter.speed(v)).font(.caption2)
                    }
                }
            }
        }
        .frame(height: 130)
    }

    private func metric(symbol: String, tint: Color, title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value).font(.title3.monospacedDigit().bold())
        }
    }
}

/// 简单卡片容器。
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(self.title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            self.content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
