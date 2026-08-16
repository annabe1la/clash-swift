import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置页：入站控制（端口/allow-lan/ipv6/bind-address/自定义 listeners）+ 按 App 分流（PROCESS 规则）。
struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                self.systemCard
                self.inboundCard
                self.listenersCard
                self.processCard
                self.advancedCard
                self.actionBar
            }
            .padding(20)
        }
        .navigationTitle(L("设置", "Settings"))
    }

    // MARK: 系统集成（TUN / 开机启动）

    private var systemCard: some View {
        Card(title: L("系统集成", "System")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { self.appModel.isTunEnabled },
                    set: { _ in Task { await self.appModel.toggleTun() } }))
                {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("TUN 模式（全局路由）", "TUN Mode (global route)"))
                        Text(L("网络层接管全部流量，无需系统代理。首次启用会请求管理员授权给内核 setuid。", "Captures all traffic at the network layer, no system proxy needed. First enable prompts admin to setuid the core."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(self.appModel.isBusy)

                Divider()

                Toggle(isOn: Binding(
                    get: { self.appModel.launchAtLogin },
                    set: { self.appModel.setLaunchAtLogin($0) }))
                {
                    Text(L("开机时启动", "Launch at login"))
                }
                .toggleStyle(.switch)

                Toggle(isOn: self.$appModel.autoRestartEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("内核异常时自动重启", "Auto-restart core on failure"))
                        Text(L("崩溃或 API 假死时自动重启，60 秒内最多 3 次，超限则停手并提示。",
                               "Restarts on crash or API hang, up to 3 times per 60s, then stops and warns."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider()

                HStack {
                    Text(L("语言", "Language"))
                    Spacer()
                    Picker("", selection: self.$appModel.language) {
                        Text("简体中文").tag(AppLanguage.zhHans)
                        Text("English").tag(AppLanguage.en)
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                HStack {
                    Text(L("外观", "Appearance"))
                    Spacer()
                    Picker("", selection: self.$appModel.appearance) {
                        Text(L("跟随系统", "System")).tag(AppAppearanceMode.system)
                        Text(L("浅色", "Light")).tag(AppAppearanceMode.light)
                        Text(L("深色", "Dark")).tag(AppAppearanceMode.dark)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    // MARK: 入站端口

    private var inboundCard: some View {
        Card(title: L("入站端口 / 局域网", "Inbound Ports / LAN")) {
            VStack(alignment: .leading, spacing: 12) {
                portField(L("混合端口 (mixed-port)", "Mixed port (mixed-port)"), value: self.$appModel.override.mixedPort, placeholder: "7890")
                portField(L("HTTP 端口 (port)", "HTTP port (port)"), value: self.$appModel.override.httpPort, placeholder: L("留空", "Empty"))
                portField(L("SOCKS 端口 (socks-port)", "SOCKS port (socks-port)"), value: self.$appModel.override.socksPort, placeholder: L("留空", "Empty"))
                Divider()
                Toggle(L("允许局域网连接 (allow-lan)", "Allow LAN (allow-lan)"), isOn: boolBinding(self.$appModel.override.allowLan))
                Toggle(L("启用 IPv6", "Enable IPv6"), isOn: boolBinding(self.$appModel.override.ipv6))
                HStack {
                    Text(L("绑定地址 (bind-address)", "Bind address (bind-address)")).frame(width: 180, alignment: .leading)
                    TextField(L("* 或 127.0.0.1", "* or 127.0.0.1"), text: stringBinding(self.$appModel.override.bindAddress))
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    // MARK: 自定义 listeners

    private var listenersCard: some View {
        Card(title: L("自定义入站 (listeners)", "Custom Inbound (listeners)")) {
            VStack(alignment: .leading, spacing: 10) {
                if self.appModel.override.listeners.isEmpty {
                    Text(L("无自定义监听器", "No custom listeners")).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(self.$appModel.override.listeners) { $listener in
                    HStack(spacing: 8) {
                        TextField(L("名称", "Name"), text: $listener.name)
                            .textFieldStyle(.roundedBorder).frame(width: 120)
                        Picker("", selection: $listener.type) {
                            ForEach(ListenerConfig.inboundTypes, id: \.self) { Text($0).tag($0) }
                        }.frame(width: 90)
                        TextField(L("端口", "Port"), value: $listener.port, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 70)
                        TextField(L("监听 IP", "Listen IP"), text: $listener.listen)
                            .textFieldStyle(.roundedBorder).frame(width: 110)
                        Button(role: .destructive) {
                            self.appModel.override.listeners.removeAll { $0.id == listener.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button {
                    self.appModel.override.listeners.append(
                        ListenerConfig(name: "in-\(self.appModel.override.listeners.count + 1)",
                                       type: "mixed", port: 7891, listen: "0.0.0.0"))
                } label: { Label(L("添加监听器", "Add listener"), systemImage: "plus") }
            }
        }
    }

    // MARK: 按 App 分流

    private var processCard: some View {
        Card(title: L("按 App / 进程分流", "Per-App Routing")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("为指定 App 强制走代理或直连（PROCESS-NAME / PROCESS-PATH，自动开启 find-process-mode）。", "Force a specific app to proxy or direct (PROCESS-NAME / PROCESS-PATH, find-process-mode auto-enabled)."))
                    .font(.caption).foregroundStyle(.secondary)
                if self.appModel.override.processRules.isEmpty {
                    Text(L("无分流规则", "No routing rules")).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(self.$appModel.override.processRules) { $rule in
                    HStack(spacing: 8) {
                        Picker("", selection: $rule.type) {
                            ForEach(ProcessRuleType.allCases) { Text($0.title).tag($0) }
                        }.frame(width: 100)
                        TextField(L("进程名/路径", "Process name/path"), text: $rule.value)
                            .textFieldStyle(.roundedBorder)
                        Picker("", selection: $rule.target) {
                            ForEach(self.targetOptions, id: \.self) { Text($0).tag($0) }
                        }.frame(width: 130)
                        Button(role: .destructive) {
                            self.appModel.override.processRules.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    Button {
                        self.pickApp(type: .processName)
                    } label: { Label(L("选择 App（按名称）", "Pick app (by name)"), systemImage: "app.badge") }
                    Button {
                        self.pickApp(type: .processPath)
                    } label: { Label(L("选择 App（按路径）", "Pick app (by path)"), systemImage: "folder.badge.gearshape") }
                }
            }
        }
    }

    private var targetOptions: [String] {
        var options = ["DIRECT", "PROXY", "REJECT"]
        options.append(contentsOf: self.appModel.proxyStore.proxyGroups.map(\.name))
        var seen = Set<String>()
        return options.filter { seen.insert($0).inserted }
    }

    // MARK: 高级（DNS/GEO/缓存/日志级别）

    private var advancedCard: some View {
        Card(title: L("高级", "Advanced")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("日志级别", "Log level"))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { self.appModel.logLevel },
                        set: { level in Task { await self.appModel.setLogLevel(level) } }))
                    {
                        ForEach(["silent", "error", "warning", "info", "debug"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(!self.appModel.isRunning)
                }
                Divider()
                HStack(spacing: 10) {
                    Button { Task { await self.appModel.updateGeoData() } } label: {
                        Label(L("更新 GEO 数据", "Update GEO"), systemImage: "globe")
                    }
                    Button { Task { await self.appModel.flushFakeIP() } } label: {
                        Label(L("清 FakeIP 缓存", "Flush FakeIP"), systemImage: "trash")
                    }
                    Button { Task { await self.appModel.flushDNS() } } label: {
                        Label(L("清 DNS 缓存", "Flush DNS"), systemImage: "trash")
                    }
                }
                .disabled(!self.appModel.isRunning)
                if let msg = self.appModel.actionMessage {
                    Text(msg).font(.caption).foregroundStyle(.green)
                }
            }
        }
    }

    // MARK: 应用栏

    private var actionBar: some View {
        HStack {
            Button {
                Task { await self.appModel.applyOverrides() }
            } label: {
                Label(self.appModel.isRunning ? L("应用并重启内核", "Apply & restart core") : L("保存", "Save"), systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(self.appModel.isBusy)

            Button(role: .destructive) {
                Task { await self.appModel.resetOverrides() }
            } label: { Text(L("清空覆盖层", "Clear overrides")) }
            .disabled(self.appModel.override.isEmpty || self.appModel.isBusy)

            Spacer()
            if !self.appModel.override.isEmpty {
                Text(L("覆盖层已启用 · 启动将使用 effective.yaml", "Overrides active · effective.yaml on launch"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func pickApp(type: ProcessRuleType) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        if panel.runModal() == .OK, let url = panel.url {
            self.appModel.addProcessRule(forAppAt: url, type: type, target: "PROXY")
        }
    }
}

// MARK: - 绑定辅助

private func portField(_ label: String, value: Binding<Int?>, placeholder: String) -> some View {
    HStack {
        Text(label).frame(width: 210, alignment: .leading)
        TextField(placeholder, text: intBinding(value))
            .textFieldStyle(.roundedBorder)
            .frame(width: 100)
    }
}

private func intBinding(_ source: Binding<Int?>) -> Binding<String> {
    Binding(
        get: { source.wrappedValue.map(String.init) ?? "" },
        set: { source.wrappedValue = Int($0.trimmingCharacters(in: .whitespaces)) })
}

private func stringBinding(_ source: Binding<String?>) -> Binding<String> {
    Binding(
        get: { source.wrappedValue ?? "" },
        set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
}

private func boolBinding(_ source: Binding<Bool?>) -> Binding<Bool> {
    Binding(
        get: { source.wrappedValue ?? false },
        set: { source.wrappedValue = $0 })
}
