import AppKit
import SwiftUI

/// 菜单栏弹窗面板：紧凑仪表盘（状态 / 启停 / 模式 / 系统代理 / TUN / 流量）。
struct MenuBarContent: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var traffic: TrafficStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.header
            Divider()
            self.controls
            if self.appModel.isRunning {
                Divider()
                self.trafficRow
            }
            Divider()
            self.footer
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: 头部状态

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: self.appModel.isRunning ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                .font(.title2)
                .foregroundStyle(self.appModel.isRunning ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Clash Swift").font(.headline)
                Text(self.appModel.isRunning
                    ? "\(L("运行中", "Running")) · \(self.appModel.versionText)"
                    : L("已停止", "Stopped"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: 控制

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    Task { await self.appModel.performPrimaryCoreAction() }
                } label: {
                    Label(self.appModel.isRunning ? L("重启", "Restart") : L("启动", "Start"),
                          systemImage: self.appModel.isRunning ? "arrow.clockwise" : "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(self.appModel.isBusy)

                Button {
                    Task { await self.appModel.stopCore() }
                } label: {
                    Label(L("停止", "Stop"), systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .disabled(!self.appModel.isRunning || self.appModel.isBusy)
            }

            Picker("", selection: Binding(
                get: { self.appModel.currentMode },
                set: { m in Task { await self.appModel.switchMode(to: m) } }))
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
                Text(L("系统代理", "System Proxy")).font(.callout)
            }
            .toggleStyle(.switch)
            .disabled(!self.appModel.isRunning)

            Toggle(isOn: Binding(
                get: { self.appModel.isTunEnabled },
                set: { _ in Task { await self.appModel.toggleTun() } }))
            {
                Text(L("TUN 模式", "TUN Mode")).font(.callout)
            }
            .toggleStyle(.switch)
            .disabled(self.appModel.isBusy)
        }
    }

    // MARK: 流量

    private var trafficRow: some View {
        HStack {
            Label(ValueFormatter.speed(self.traffic.traffic.up), systemImage: "arrow.up")
                .font(.caption.monospacedDigit()).foregroundStyle(.blue)
            Spacer()
            Label(ValueFormatter.speed(self.traffic.traffic.down), systemImage: "arrow.down")
                .font(.caption.monospacedDigit()).foregroundStyle(.green)
            Spacer()
            Label(ValueFormatter.bytesCompact(self.traffic.memory.inuse), systemImage: "memorychip")
                .font(.caption.monospacedDigit()).foregroundStyle(.purple)
        }
    }

    // MARK: 底部

    private var footer: some View {
        HStack {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            } label: {
                Label(L("主窗口", "Window"), systemImage: "macwindow")
            }
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label(L("退出", "Quit"), systemImage: "power")
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }
}
