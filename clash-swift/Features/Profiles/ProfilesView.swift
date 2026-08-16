import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 订阅页：配置列表、URL/文件导入、切换、删除。
struct ProfilesView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var subscriptionURL = ""
    @State private var isImporting = false
    @State private var editorURL: IdentifiedURL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                self.importCard
                self.listCard
            }
            .padding(20)
        }
        .navigationTitle(L("订阅", "Profiles"))
        .sheet(item: self.$editorURL) { target in
            ConfigEditorView(url: target.url)
        }
    }

    private var importCard: some View {
        Card(title: L("导入配置", "Import Config")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField(L("订阅链接 https://…", "Subscription URL https://…"), text: self.$subscriptionURL)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        let url = self.subscriptionURL
                        self.subscriptionURL = ""
                        Task {
                            self.isImporting = true
                            await self.appModel.importConfig(fromURL: url)
                            self.isImporting = false
                        }
                    } label: {
                        if self.isImporting { ProgressView().controlSize(.small) }
                        else { Text(L("下载导入", "Download")) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(self.subscriptionURL.trimmingCharacters(in: .whitespaces).isEmpty || self.isImporting)
                }
                Button {
                    self.importFromFile()
                } label: {
                    Label(L("从本地文件导入…", "Import from file…"), systemImage: "folder")
                }
            }
        }
    }

    private var listCard: some View {
        Card(title: L("配置列表", "Configs")) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("订阅自动更新", "Auto-update")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: self.$appModel.autoUpdateHours) {
                        Text(L("关闭", "Off")).tag(0)
                        Text(L("每 6 小时", "Every 6h")).tag(6)
                        Text(L("每 12 小时", "Every 12h")).tag(12)
                        Text(L("每 24 小时", "Every 24h")).tag(24)
                    }
                    .labelsHidden().fixedSize()
                }
                Divider()
                if self.appModel.configs.isEmpty {
                    Text(L("暂无配置", "No configs")).font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(self.appModel.configs, id: \.self) { url in
                        ConfigRow(
                            url: url,
                            isSelected: url.lastPathComponent == self.appModel.selectedConfigName,
                            meta: self.appModel.subscriptionMetas[url.lastPathComponent],
                            onSelect: { Task { await self.appModel.selectConfig(url) } },
                            onUpdate: { Task { await self.appModel.updateSubscription(filename: url.lastPathComponent) } },
                            onEdit: { self.editorURL = IdentifiedURL(url: url) },
                            onDelete: { self.appModel.deleteConfig(url) })
                    }
                }
                if let msg = self.appModel.actionMessage {
                    Text(msg).font(.caption).foregroundStyle(.green)
                }
            }
        }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "yaml"),
            UTType(filenameExtension: "yml"),
            .yaml,
            .plainText,
        ].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url {
            self.appModel.importConfig(fromFile: url)
        }
    }
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { self.url.path }
}

/// 配置内联编辑器。
private struct ConfigEditorView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(self.url.lastPathComponent).font(.headline)
                Spacer()
                Button(L("取消", "Cancel")) { self.dismiss() }
                Button(L("保存", "Save")) {
                    Task {
                        await self.appModel.saveConfigText(self.url, text: self.text)
                        self.dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            Divider()
            TextEditor(text: self.$text)
                .font(.system(.callout, design: .monospaced))
                .frame(minWidth: 640, minHeight: 460)
        }
        .onAppear {
            guard !self.loaded else { return }
            self.text = self.appModel.readConfigText(self.url)
            self.loaded = true
        }
    }
}

private struct ConfigRow: View {
    let url: URL
    let isSelected: Bool
    let meta: SubscriptionMeta?
    let onSelect: () -> Void
    let onUpdate: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: self.isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(self.isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(self.url.lastPathComponent).font(.callout)
                if let usage = self.usageText {
                    Text(usage).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if self.meta != nil {
                Button(action: self.onUpdate) { Image(systemName: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.borderless)
                    .help(L("更新订阅", "Update subscription"))
            }
            Button(action: self.onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help(L("编辑配置", "Edit config"))
            if self.isSelected {
                Text(L("已选用", "In use")).font(.caption).foregroundStyle(.secondary)
            } else {
                Button(L("选用", "Use"), action: self.onSelect)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button(role: .destructive, action: self.onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(self.isSelected)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var usageText: String? {
        guard let info = self.meta?.userInfo else { return nil }
        var parts: [String] = []
        if let total = info.total, total > 0 {
            parts.append("\(ValueFormatter.bytesCompact(info.used)) / \(ValueFormatter.bytesCompact(total))")
        } else if info.used > 0 {
            parts.append(ValueFormatter.bytesCompact(info.used))
        }
        if let expire = info.expire, expire > 0 {
            parts.append("\(L("到期", "Expires")) \(ValueFormatter.dateTime(Date(timeIntervalSince1970: TimeInterval(expire))))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
