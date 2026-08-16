import AppKit
import SwiftUI

/// 菜单栏快捷面板（Phase 1：状态 / 启停 / 模式 / 系统代理 / 流量）。
struct MenuBarContent: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var traffic: TrafficStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(self.appModel.isRunning ? L("内核运行中", "Core running") : L("内核已停止", "Core stopped"))

        Button(self.appModel.isRunning ? L("重启内核", "Restart core") : L("启动内核", "Start core")) {
            Task { await self.appModel.performPrimaryCoreAction() }
        }
        .disabled(self.appModel.isBusy)

        Button(L("停止内核", "Stop core")) {
            Task { await self.appModel.stopCore() }
        }
        .disabled(!self.appModel.isRunning || self.appModel.isBusy)

        Divider()

        Menu(L("模式", "Mode")) {
            self.modeButton(.rule, L("规则", "Rule"))
            self.modeButton(.global, L("全局", "Global"))
            self.modeButton(.direct, L("直连", "Direct"))
        }
        .disabled(!self.appModel.isRunning)

        Button(self.appModel.isSystemProxyEnabled ? L("关闭系统代理", "Disable system proxy") : L("开启系统代理", "Enable system proxy")) {
            Task { await self.appModel.toggleSystemProxy() }
        }
        .disabled(!self.appModel.isRunning)

        Divider()

        Text("↑ \(ValueFormatter.speed(self.traffic.traffic.up))   ↓ \(ValueFormatter.speed(self.traffic.traffic.down))")

        Divider()

        Button(L("打开主窗口", "Open window")) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }

        Button(L("退出", "Quit")) { NSApp.terminate(nil) }
    }

    private func modeButton(_ mode: CoreMode, _ title: String) -> some View {
        Button {
            Task { await self.appModel.switchMode(to: mode) }
        } label: {
            HStack {
                Text(title)
                if self.appModel.currentMode == mode { Image(systemName: "checkmark") }
            }
        }
    }
}
