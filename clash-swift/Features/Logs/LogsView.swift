import SwiftUI

/// 日志页：mihomo 日志列表、级别过滤、搜索。
struct LogsView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var logsStore: LogsStore
    @State private var search = ""
    @State private var level: LogLevelFilter?

    private var filtered: [AppErrorLogEntry] {
        self.logsStore.errorLogs.filter { entry in
            self.matchesLevel(entry) && self.matchesSearch(entry)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            self.toolbar
            Divider()
            if self.filtered.isEmpty {
                ContentUnavailableView(L("暂无日志", "No logs"), systemImage: "doc.text",
                                       description: Text(self.appModel.isRunning ? L("等待日志输出…", "Waiting for logs…") : L("启动内核后开始记录。", "Logs will appear once the core starts.")))
                    .frame(maxHeight: .infinity)
            } else {
                self.list
            }
        }
        .navigationTitle(L("日志", "Logs"))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("搜索日志", "Search logs"), text: self.$search)
                .textFieldStyle(.plain)
            Picker("", selection: self.$level) {
                Text(L("全部", "All")).tag(LogLevelFilter?.none)
                Text(L("信息", "Info")).tag(LogLevelFilter?.some(.info))
                Text(L("警告", "Warn")).tag(LogLevelFilter?.some(.warning))
                Text(L("错误", "Error")).tag(LogLevelFilter?.some(.error))
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Text("\(self.logsStore.errorLogs.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button {
                self.logsStore.errorLogs = []
            } label: {
                Label(L("清空", "Clear"), systemImage: "trash")
            }
            .controlSize(.small)
            .disabled(self.logsStore.errorLogs.isEmpty)
        }
        .padding(12)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            List(self.filtered) { entry in
                LogRow(entry: entry).id(entry.id)
            }
            .listStyle(.inset)
            .onChange(of: self.filtered.count) {
                if let last = self.filtered.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func matchesLevel(_ entry: AppErrorLogEntry) -> Bool {
        guard let level = self.level else { return true }
        return Self.levelFilter(for: entry.level) == level
    }

    private func matchesSearch(_ entry: AppErrorLogEntry) -> Bool {
        let q = self.search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return entry.message.lowercased().contains(q)
    }

    static func levelFilter(for raw: String) -> LogLevelFilter {
        switch raw.lowercased() {
        case "warning", "warn": .warning
        case "error", "err": .error
        default: .info
        }
    }
}

private struct LogRow: View {
    let entry: AppErrorLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(self.color).frame(width: 6, height: 6).padding(.top, 6)
            Text(self.entry.message)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private var color: Color {
        switch LogsView.levelFilter(for: self.entry.level) {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
