import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: self.$selection) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
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

/// 侧边栏底部的内核状态摘要。
private struct SidebarStatusFooter: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(self.appModel.isRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(self.appModel.isRunning ? L("内核运行中", "Core running") : L("内核已停止", "Core stopped"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if self.appModel.isRunning {
                Text(self.appModel.currentMode.rawValue.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.tint)
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
