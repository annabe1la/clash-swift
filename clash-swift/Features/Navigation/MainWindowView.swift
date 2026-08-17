import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selection: SidebarItem? = .overview

    private let monitorItems: [SidebarItem] = [.overview, .proxies, .profiles, .connections, .rules, .logs]
    private let systemItems: [SidebarItem] = [.diagnostics, .settings]

    var body: some View {
        NavigationSplitView {
            List(selection: self.$selection) {
                Section(L("监控", "Monitor")) {
                    ForEach(self.monitorItems) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                Section(L("系统", "System")) {
                    ForEach(self.systemItems) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
            .safeAreaInset(edge: .bottom) {
                SidebarStatusFooter()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        } detail: {
            detail(for: self.selection ?? .overview)
                .frame(minWidth: 580, minHeight: 500)
        }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        switch item {
        case .overview: OverviewView()
        case .proxies: ProxiesView()
        case .profiles: ProfilesView()
        case .connections: ConnectionsView()
        case .rules: RulesView()
        case .logs: LogsView()
        case .diagnostics: DiagnosticsView()
        case .settings: SettingsView()
        }
    }
}

/// 侧边栏底部的内核状态摘要 + 实时流量。
private struct SidebarStatusFooter: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var traffic: TrafficStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(self.appModel.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(self.appModel.isRunning ? L("运行中", "Running") : L("已停止", "Stopped"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if self.appModel.isRunning {
                    Text(self.appModel.currentMode.rawValue.uppercased())
                        .font(.caption2.bold()).foregroundStyle(.tint)
                }
            }
            if self.appModel.isRunning {
                HStack(spacing: 10) {
                    Label(ValueFormatter.speed(self.traffic.traffic.up), systemImage: "arrow.up")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.blue)
                    Label(ValueFormatter.speed(self.traffic.traffic.down), systemImage: "arrow.down")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.green)
                    Spacer()
                }
            }
        }
    }
}

struct PlaceholderPage: View {
    let title: String
    let note: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(self.title).font(.title2.bold())
            Text(self.note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(self.title)
    }
}
