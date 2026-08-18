//
//  AppModel.swift
//  clash-swift
//
//  宿主 ViewModel：替代 ClashBar 的 AppViewModel 上帝对象。
//  只保留全窗口应用需要的内核控制核心时序，剥离菜单栏专有状态。
//

import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    // MARK: 注入依赖

    let dependencies: AppDependencies
    private var coreRepository: any CoreRepository { self.dependencies.coreRepository }
    private var configRepository: any ConfigRepository { self.dependencies.configRepository }
    private var systemProxyRepository: any SystemProxyRepository { self.dependencies.systemProxyRepository }
    private var workingDirectory: WorkingDirectoryManager { self.dependencies.workingDirectoryManager }

    // MARK: 自持长生命周期对象

    let trafficStore = TrafficStore()
    let connectionsStore = ConnectionsStore()
    let proxyStore = ProxyStore()
    let logsStore = LogsStore()
    private let streamCoordinator = StreamCoordinator()

    /// API client 懒建：依赖 controller + secret，任何 API 调用前经 ensureAPIClient()。
    private var apiClient: MihomoAPIService?

    /// 覆盖层服务（入站控制 + 按 App 分流）。
    private let overrideService: ConfigOverrideService
    @Published var override = ConfigOverride()

    /// 系统代理免签名后备（networksetup + 管理员授权）。
    private let systemProxyFallback: SystemProxyFallbackService

    /// 诊断（内核进程扫描 + 系统代理读数）。
    private let diagnosticsService = DiagnosticsService()
    @Published private(set) var coreProcesses: [CoreProcessInfo] = []
    @Published private(set) var systemProxyReadout: SystemProxyReadout?

    /// 订阅服务（下载/流量头/元数据）。
    private let subscriptionService: SubscriptionService
    @Published private(set) var subscriptionMetas: [String: SubscriptionMeta] = [:]
    /// 订阅自动更新间隔（小时，0=关闭）。
    @Published var autoUpdateHours: Int = 0 {
        didSet { UserDefaults.standard.set(self.autoUpdateHours, forKey: "subAutoUpdateHours") }
    }
    private var autoUpdateTask: Task<Void, Never>?
    @Published private(set) var isTunEnabled = false
    @Published private(set) var launchAtLogin = false

    /// 界面语言（切换即时生效）。
    @Published var language: AppLanguage = .zhHans {
        didSet {
            LocalizationCenter.current = self.language
            UserDefaults.standard.set(self.language.rawValue, forKey: "appLanguage")
        }
    }

    /// 内核异常时自动重启（有限次+退避）。
    @Published var autoRestartEnabled = true {
        didSet { UserDefaults.standard.set(self.autoRestartEnabled, forKey: "autoRestartEnabled") }
    }

    /// 外观：跟随系统 / 浅色 / 深色。
    @Published var appearance: AppAppearanceMode = .system {
        didSet { UserDefaults.standard.set(self.appearance.rawValue, forKey: "appearance") }
    }

    /// 强调色主题。
    @Published var accent: AppAccent = .blue {
        didSet { UserDefaults.standard.set(self.accent.rawValue, forKey: "accent") }
    }

    /// 折叠的代理组名（持久化）。
    @Published var collapsedGroups: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(self.collapsedGroups), forKey: "collapsedGroups") }
    }

    // 健康监控内部状态
    private var shouldBeRunning = false
    private var healthMonitorTask: Task<Void, Never>?
    private var apiFailureStreak = 0
    private var restartTimestamps: [Date] = []
    private let healthCheckInterval: Duration = .seconds(5)
    private let apiDeathThreshold = 3          // 连续 API 失败判定“假死”
    private let restartWindow: TimeInterval = 60
    private let maxRestartsInWindow = 3

    // MARK: 内核参数（双 controller，见踩坑提醒 1）

    /// 传给内核 -ext-ctl 的原始解析值（可能含 0.0.0.0）。
    private var launchController = AppModel.defaultController
    /// 给 API client 用的归一值（0.0.0.0→127.0.0.1）。
    private var clientController = AppModel.defaultController
    private var controllerSecret: String?

    static let defaultController = "127.0.0.1:9090"

    // MARK: 发布给 UI 的状态

    @Published private(set) var lifecycle: CoreLifecycleStatus = .stopped
    @Published private(set) var apiStatus: APIHealth = .unknown
    @Published private(set) var currentMode: CoreMode = .rule
    @Published private(set) var logLevel: String = "info"
    @Published var actionMessage: String?
    @Published private(set) var versionText: String = "—"
    @Published private(set) var isBusy = false
    @Published private(set) var isSystemProxyEnabled = false
    @Published private(set) var systemProxyStatusText: String?
    @Published var errorMessage: String?
    @Published private(set) var selectedConfigName: String?
    @Published private(set) var configs: [URL] = []

    /// 延迟测速默认参数（组/节点无自带 testUrl 时使用）。
    static let defaultTestURL = "https://cp.cloudflare.com/generate_204"
    static let defaultTestTimeout = 5000

    var isRunning: Bool { self.coreRepository.isRunning }
    var controllerDisplay: String { self.clientController }

    /// 我们自己管理的内核 PID（用于诊断页区分自己 vs 其他内核）。
    var ourCorePID: Int32? {
        if case let .running(pid) = self.lifecycle { return pid }
        return nil
    }
    var detectedBinaryPath: String? { self.coreRepository.detectedBinaryPath }

    private var didBootstrap = false
    private var trafficHistoryCap = 60

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        let savedLang = UserDefaults.standard.string(forKey: "appLanguage")
            .flatMap(AppLanguage.init(rawValue:)) ?? .zhHans
        self.language = savedLang
        LocalizationCenter.current = savedLang
        self.autoRestartEnabled = (UserDefaults.standard.object(forKey: "autoRestartEnabled") as? Bool) ?? true
        self.appearance = UserDefaults.standard.string(forKey: "appearance")
            .flatMap(AppAppearanceMode.init(rawValue:)) ?? .system
        self.accent = UserDefaults.standard.string(forKey: "accent")
            .flatMap(AppAccent.init(rawValue:)) ?? .blue
        self.collapsedGroups = Set(UserDefaults.standard.stringArray(forKey: "collapsedGroups") ?? [])
        self.overrideService = ConfigOverrideService(
            workingDirectory: dependencies.workingDirectoryManager)
        self.systemProxyFallback = SystemProxyFallbackService(
            workingDirectory: dependencies.workingDirectoryManager)
        self.subscriptionService = SubscriptionService(
            workingDirectory: dependencies.workingDirectoryManager)
        self.autoUpdateHours = UserDefaults.standard.integer(forKey: "subAutoUpdateHours")
        self.configureStreamCoordinator()
    }

    // MARK: - 引导

    func bootstrap() {
        guard !self.didBootstrap else { return }
        self.didBootstrap = true

        do {
            try self.workingDirectory.bootstrapDirectories()
        } catch {
            self.errorMessage = "初始化工作目录失败：\(error.localizedDescription)"
        }

        // 关键：先把配置目录指向工作区 config 目录，否则扫描不到任何配置。
        self.configRepository.setConfigDirectory(self.workingDirectory.configDirectoryURL)
        _ = self.configRepository.reloadConfigs()
        if self.configRepository.availableConfigs.isEmpty {
            self.seedMinimalConfigIfNeeded()
            _ = self.configRepository.reloadConfigs()
        }
        if let selected = self.resolveSelectedConfigURL() {
            self.configRepository.selectConfig(selected)
            self.selectedConfigName = selected.lastPathComponent
            self.applyControllerAndSecret(fromConfigAt: selected.path)
        }
        self.configs = self.configRepository.availableConfigs
        self.override = self.overrideService.loadOverride()
        self.isTunEnabled = self.override.tunEnabled ?? false
        self.subscriptionMetas = self.subscriptionService.load()
        self.refreshLaunchAtLogin()
        self.startAutoUpdateTimer()
        self.ensureAPIClient()

        // 若内核已在运行（外部启动），尝试刷新一次
        Task { await self.refreshFromAPI(includeSlowCalls: true) }
    }

    /// 配置目录为空时种入一个最小可用配置（direct-only），保证核心就位后可一键启动。
    /// 真正的订阅/配置导入在 Phase 2。
    private func seedMinimalConfigIfNeeded() {
        let minimal = """
        mixed-port: 7890
        allow-lan: false
        mode: rule
        log-level: info
        ipv6: false
        external-controller: 127.0.0.1:9090
        proxies: []
        proxy-groups: []
        rules:
          - MATCH,DIRECT
        """
        let target = self.workingDirectory.configDirectoryURL
            .appendingPathComponent("default.yaml", isDirectory: false)
        do {
            try self.configRepository.writeConfigData(Data(minimal.utf8), to: target)
        } catch {
            self.errorMessage = "写入默认配置失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 内核生命周期

    /// 主按钮：运行中→重启，否则启动。
    func performPrimaryCoreAction() async {
        if self.isRunning {
            await self.restartCore()
        } else {
            await self.startCore()
        }
    }

    func startCore() async {
        guard !self.isBusy else { return }
        self.isBusy = true
        defer { self.isBusy = false }
        self.errorMessage = nil

        guard let configPath = self.resolveLaunchConfigPath() else {
            self.errorMessage = "没有可用配置，请先导入或选择一个配置文件。"
            return
        }

        // 启动前检测端口占用（控制器/入站被别的内核占用会导致启动失败）。
        if let conflict = await self.detectPortConflicts(configPath: configPath) {
            self.lifecycle = .failed(reason: conflict)
            self.errorMessage = conflict
            return
        }

        // 启动前必须校验配置（mihomo -t），否则会拉起后立刻崩。
        do {
            try await self.coreRepository.validateConfig(configPath: configPath)
        } catch {
            let raw = error.localizedDescription
            self.lifecycle = .failed(reason: raw)
            if raw.lowercased().contains("timed out") || raw.contains("MMDB") {
                self.errorMessage = L(
                    "配置校验超时——多半是首次启动在下载地理数据库(GeoIP/MMDB)，网络较慢或 geo 源被墙。请稍后重试（下载成功后会缓存，之后就快了）；若一直失败，改用国内可达的 geox-url。",
                    "Config test timed out — likely downloading GeoIP/MMDB on first run. Retry (it caches once done); if it keeps failing, switch to a reachable geox-url.")
            } else {
                self.errorMessage = "\(L("配置校验失败", "Config test failed"))：\(raw)"
            }
            return
        }

        self.launchController = self.rawControllerFromConfig(at: configPath) ?? Self.defaultController
        self.clientController = Self.normalizeControllerForClient(self.launchController)
        self.controllerSecret = self.secretFromConfig(at: configPath)

        do {
            self.lifecycle = .starting
            self.lifecycle = try await self.coreRepository.start(
                configPath: configPath,
                controller: self.launchController)
            await self.completeCoreBootstrap()
        } catch {
            self.lifecycle = .failed(reason: error.localizedDescription)
            self.errorMessage = "启动内核失败：\(error.localizedDescription)"
        }
    }

    func restartCore() async {
        guard !self.isBusy else { return }
        self.isBusy = true
        defer { self.isBusy = false }
        self.errorMessage = nil

        guard let configPath = self.resolveLaunchConfigPath() else {
            self.errorMessage = "没有可用配置。"
            return
        }
        do {
            try await self.coreRepository.validateConfig(configPath: configPath)
            self.launchController = self.rawControllerFromConfig(at: configPath) ?? Self.defaultController
            self.clientController = Self.normalizeControllerForClient(self.launchController)
            self.controllerSecret = self.secretFromConfig(at: configPath)
            self.lifecycle = .starting
            self.lifecycle = try await self.coreRepository.restart(
                configPath: configPath,
                controller: self.launchController)
            await self.completeCoreBootstrap()
        } catch {
            self.lifecycle = .failed(reason: error.localizedDescription)
            self.errorMessage = "重启内核失败：\(error.localizedDescription)"
        }
    }

    func stopCore() async {
        guard !self.isBusy else { return }
        self.isBusy = true
        defer { self.isBusy = false }

        // 用户主动停止：先关健康监控，避免被误判为崩溃触发自动重启。
        self.shouldBeRunning = false
        self.healthMonitorTask?.cancel()
        self.healthMonitorTask = nil

        // 顺序固定：先关系统代理 → stop 内核 → cancel 流 → 清 UI。
        if self.isSystemProxyEnabled {
            await self.setSystemProxy(enabled: false)
        }
        await self.coreRepository.stop()
        self.streamCoordinator.cancelAll()
        self.lifecycle = .stopped
        self.apiStatus = .unknown
        self.trafficStore.traffic = .init(up: 0, down: 0)
        self.connectionsStore.connections = []
        self.connectionsStore.connectionsCount = 0
    }

    /// App 退出时的同步清理。
    func shutdownForTermination() {
        self.systemProxyRepository.clearBlocking(timeout: 2)
        self.coreRepository.stopImmediately()
    }

    private func completeCoreBootstrap() async {
        self.apiStatus = .healthy
        self.ensureAPIClient()
        await self.refreshFromAPI(includeSlowCalls: true)
        await self.refreshProxies()
        await self.refreshRules()
        self.startStreams()
        self.shouldBeRunning = true
        self.apiFailureStreak = 0
        self.startHealthMonitor()
    }

    // MARK: - API client

    private func ensureAPIClient() {
        if let client = self.apiClient {
            client.updateCredentials(controller: self.clientController, secret: self.controllerSecret)
        } else {
            self.apiClient = MihomoAPIService(
                controller: self.clientController,
                secret: self.controllerSecret)
        }
    }

    private func client() throws -> MihomoAPIService {
        self.ensureAPIClient()
        guard let client = self.apiClient else {
            throw APIError.invalidResponse
        }
        return client
    }

    // MARK: - 刷新

    func refreshFromAPI(includeSlowCalls: Bool) async {
        guard self.isRunning else { return }
        do {
            let transport = try self.client()
            // Phase 1 只取 version + configs(拿 mode)；proxy groups 留到 Phase 2。
            let snapshot = try await FetchMediumFrequencySnapshotUseCase(
                transport: transport,
                includeProxyGroups: false).execute()
            self.versionText = snapshot.versionInfo.version
            self.applyRuntimeConfigSnapshot(snapshot.configSnapshot)
            self.apiStatus = .healthy
        } catch {
            self.apiStatus = .degraded
        }
    }

    private func applyRuntimeConfigSnapshot(_ snapshot: ConfigSnapshot) {
        if let mode = snapshot.mode, let parsed = CoreMode(rawValue: mode.lowercased()) {
            self.currentMode = parsed
        }
        if let level = snapshot.logLevel?.trimmedNonEmpty {
            self.logLevel = level
        }
    }

    // MARK: - 维护 / 高级（DNS·GEO·缓存·日志级别）

    func setLogLevel(_ level: String) async {
        let previous = self.logLevel
        self.logLevel = level
        do {
            try await self.client().requestNoResponse(.patchConfigs(body: ["log-level": .string(level)]))
        } catch {
            self.logLevel = previous
            self.errorMessage = "设置日志级别失败：\(error.localizedDescription)"
        }
    }

    func updateGeoData() async { await self.runMaintenance(.upgradeGeo, ok: L("GEO 数据更新已触发", "GEO update triggered")) }
    func flushFakeIP() async { await self.runMaintenance(.flushFakeIPCache, ok: L("已清空 FakeIP 缓存", "FakeIP cache flushed")) }
    func flushDNS() async { await self.runMaintenance(.flushDNSCache, ok: L("已清空 DNS 缓存", "DNS cache flushed")) }

    private func runMaintenance(_ endpoint: Endpoint, ok: String) async {
        guard self.isRunning else { return }
        do {
            try await self.client().requestNoResponse(endpoint)
            self.actionMessage = ok
        } catch {
            self.errorMessage = "\(L("操作失败", "Action failed"))：\(error.localizedDescription)"
        }
    }

    // MARK: - 模式切换

    func switchMode(to target: CoreMode) async {
        guard target != self.currentMode else { return }
        guard self.isRunning, self.apiStatus == .healthy else { return }
        let previous = self.currentMode
        self.currentMode = target // 乐观更新
        do {
            try await self.client().requestNoResponse(
                .patchConfigs(body: ["mode": .string(target.rawValue)]))
        } catch {
            self.currentMode = previous // 回滚
            self.errorMessage = "切换模式失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 系统代理

    func toggleSystemProxy() async {
        await self.setSystemProxy(enabled: !self.isSystemProxyEnabled)
    }

    private func setSystemProxy(enabled: Bool) async {
        self.proxyStore.isProxySyncing = true
        defer { self.proxyStore.isProxySyncing = false }

        let host = Self.hostComponent(of: self.clientController)
        let ports: SystemProxyPorts = enabled ? await self.resolveSystemProxyPorts() : .disabled

        if enabled, ports.primaryPort == nil {
            self.errorMessage = "无法确定代理端口，请检查 mixed-port / port 配置。"
            return
        }
        let port = ports.primaryPort ?? 0

        // 免签名后备：管理员授权调 networksetup（阻塞式，放到后台线程避免卡 UI）。
        let service = self.systemProxyFallback
        do {
            try await Task.detached {
                try service.apply(enabled: enabled, host: host, port: port)
            }.value
            self.isSystemProxyEnabled = enabled
            self.systemProxyStatusText = enabled ? "\(host):\(port)（HTTP/HTTPS/SOCKS）" : nil
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    /// 优先 mixed-port；否则 http=port、socks=socks-port。
    private func resolveSystemProxyPorts() async -> SystemProxyPorts {
        guard let snapshot = try? await self.client().request(.getConfigs) as ConfigSnapshot else {
            return .disabled
        }
        if let mixed = snapshot.mixedPort, (1...65535).contains(mixed) {
            return SystemProxyPorts(httpPort: mixed, httpsPort: mixed, socksPort: mixed)
        }
        let http = snapshot.port.flatMap { (1...65535).contains($0) ? $0 : nil }
        let socks = snapshot.socksPort.flatMap { (1...65535).contains($0) ? $0 : nil }
        return SystemProxyPorts(httpPort: http, httpsPort: http, socksPort: socks)
    }

    // MARK: - 节点 / 代理组（Phase 2）

    /// 拉取代理组 + Provider，构建展示并写入 proxyStore。
    func refreshProxies() async {
        guard self.isRunning else { return }
        do {
            let transport = try self.client()
            let snapshot = try await FetchProxyGroupsAndProvidersUseCase(transport: transport).execute()
            let presentation = BuildProxyGroupsPresentationUseCase().execute(
                response: snapshot.groups,
                proxyProviders: snapshot.providers,
                fallbackProxyProviders: self.proxyStore.proxyProvidersDetail)
            self.proxyStore.proxyGroups = presentation.groups
            self.proxyStore.proxyDelaySamples = presentation.delaySamples
            self.proxyStore.proxyNodeTypes = presentation.nodeTypes
            if !snapshot.providers.isEmpty {
                self.proxyStore.proxyProvidersDetail = snapshot.providers
            }
        } catch {
            self.errorMessage = "刷新节点失败：\(error.localizedDescription)"
        }
    }

    /// 组内切换选中节点。
    func switchProxy(group: String, to node: String) async {
        do {
            try await self.client().requestNoResponse(.switchProxy(name: group, target: node))
            await self.refreshProxies()
        } catch {
            self.errorMessage = "切换节点失败：\(error.localizedDescription)"
        }
    }

    /// 测试整组延迟。
    func testGroupDelay(group: ProxyGroup) async {
        let url = group.testUrl?.trimmedNonEmpty ?? Self.defaultTestURL
        let timeout = group.timeout.flatMap { $0 > 0 ? $0 : nil } ?? Self.defaultTestTimeout
        self.proxyStore.groupLatencyLoading.insert(group.name)
        defer { self.proxyStore.groupLatencyLoading.remove(group.name) }
        do {
            let result: GroupDelayMeasurement = try await self.client().request(
                .groupDelay(name: group.name, url: url, timeout: timeout))
            var samples = self.proxyStore.proxyDelaySamples
            for (node, delay) in result.values {
                samples[node] = [delay]
            }
            self.proxyStore.proxyDelaySamples = samples
        } catch {
            self.errorMessage = "组测速失败：\(error.localizedDescription)"
        }
    }

    /// 依次测试所有组延迟。
    func testAllGroups() async {
        for group in self.proxyStore.proxyGroups {
            await self.testGroupDelay(group: group)
        }
    }

    /// 测试单个节点延迟。
    func testNodeDelay(name: String) async {
        let key = ProxyLatencyTestKey(group: name, node: name)
        self.proxyStore.proxyLatencyTesting.insert(key)
        defer { self.proxyStore.proxyLatencyTesting.remove(key) }
        do {
            let result: DelayMeasurement = try await self.client().request(
                .proxyDelay(name: name, url: Self.defaultTestURL, timeout: Self.defaultTestTimeout))
            if let value = result.value {
                var samples = self.proxyStore.proxyDelaySamples
                samples[name] = [value]
                self.proxyStore.proxyDelaySamples = samples
            }
        } catch {
            self.errorMessage = "节点测速失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 规则 / 连接（Phase 3）

    /// 拉取规则列表写入 proxyStore。
    func refreshRules() async {
        guard self.isRunning else { return }
        do {
            let summary: RulesSummary = try await self.client().request(.rules)
            self.proxyStore.ruleItems = summary.rules
            self.proxyStore.rulesCount = summary.totalCount
            if let providers = try? await self.client().request(.ruleProviders) as ProviderSummary {
                self.proxyStore.ruleProviders = providers.providers
            }
        } catch {
            self.errorMessage = "刷新规则失败：\(error.localizedDescription)"
        }
    }

    /// 更新代理 Provider（重新拉取订阅）。
    func updateProxyProvider(_ name: String) async {
        do {
            try await self.client().requestNoResponse(.updateProxyProvider(name: name))
            await self.refreshProxies()
            self.actionMessage = "\(L("已更新", "Updated"))：\(name)"
        } catch {
            self.errorMessage = "\(L("更新失败", "Update failed"))：\(error.localizedDescription)"
        }
    }

    /// 对代理 Provider 做健康检查。
    func healthcheckProxyProvider(_ name: String) async {
        self.proxyStore.providerUpdating.insert(name)
        defer { self.proxyStore.providerUpdating.remove(name) }
        do {
            try await self.client().requestNoResponse(.proxyProviderHealthcheck(
                name: name, url: Self.defaultTestURL, timeout: Self.defaultTestTimeout))
            await self.refreshProxies()
        } catch {
            self.errorMessage = "\(L("健康检查失败", "Health check failed"))：\(error.localizedDescription)"
        }
    }

    /// 更新规则 Provider。
    func updateRuleProvider(_ name: String) async {
        do {
            try await self.client().requestNoResponse(.updateRuleProvider(name: name))
            await self.refreshRules()
            self.actionMessage = "\(L("已更新", "Updated"))：\(name)"
        } catch {
            self.errorMessage = "\(L("更新失败", "Update failed"))：\(error.localizedDescription)"
        }
    }

    /// 关闭单条连接。
    func closeConnection(id: String) async {
        try? await self.client().requestNoResponse(.closeConnection(id: id))
    }

    /// 关闭全部连接。
    func closeAllConnections() async {
        try? await self.client().requestNoResponse(.closeAllConnections)
    }

    // MARK: - 订阅 / 配置（Phase 2）

    func refreshConfigs() {
        self.configs = self.configRepository.reloadConfigs()
        self.selectedConfigName = self.configRepository.selectedConfig?.lastPathComponent
    }

    /// 从订阅 URL 导入。
    func importConfig(fromURL urlString: String) async {
        self.errorMessage = nil
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            self.errorMessage = L("无效的订阅链接，需以 http(s):// 开头。",
                                  "Invalid subscription link; must start with http(s)://.")
            return
        }
        do {
            let result = try await self.subscriptionService.download(from: url)
            let name = result.suggestedName
                ?? self.configRepository.inferredRemoteConfigFileName(from: url)
            let target = self.workingDirectory.configDirectoryURL
                .appendingPathComponent(name, isDirectory: false)
            try self.configRepository.writeConfigData(result.data, to: target)
            self.subscriptionMetas[target.lastPathComponent] = SubscriptionMeta(
                url: trimmed, userInfo: result.userInfo, updatedAt: Date())
            self.subscriptionService.save(self.subscriptionMetas)
            self.refreshConfigs()
            self.actionMessage = "\(L("已导入", "Imported"))：\(target.lastPathComponent)"
        } catch {
            self.errorMessage = "\(L("导入订阅失败", "Import failed"))：\(error.localizedDescription)"
        }
    }

    /// 重新下载并更新某个订阅配置。
    func updateSubscription(filename: String) async {
        guard let meta = self.subscriptionMetas[filename], let url = URL(string: meta.url) else {
            self.errorMessage = L("该配置没有记录订阅链接，无法更新。", "No subscription URL recorded for this config.")
            return
        }
        do {
            let result = try await self.subscriptionService.download(from: url)
            let target = self.workingDirectory.configDirectoryURL
                .appendingPathComponent(filename, isDirectory: false)
            try self.configRepository.writeConfigData(result.data, to: target)
            self.subscriptionMetas[filename] = SubscriptionMeta(
                url: meta.url, userInfo: result.userInfo ?? meta.userInfo, updatedAt: Date())
            self.subscriptionService.save(self.subscriptionMetas)
            self.refreshConfigs()
            self.actionMessage = "\(L("已更新订阅", "Subscription updated"))：\(filename)"
            if filename == self.configRepository.selectedConfig?.lastPathComponent, self.isRunning {
                await self.restartCore()
            }
        } catch {
            self.errorMessage = "\(L("更新订阅失败", "Subscription update failed"))：\(error.localizedDescription)"
        }
    }

    /// 定时自动更新到期的订阅（每 30 分钟检查一次）。
    private func startAutoUpdateTimer() {
        self.autoUpdateTask?.cancel()
        self.autoUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1800))
                guard let self, !Task.isCancelled else { return }
                guard self.autoUpdateHours > 0 else { continue }
                let deadline = Double(self.autoUpdateHours) * 3600
                for (filename, meta) in self.subscriptionMetas {
                    let age = meta.updatedAt.map { Date().timeIntervalSince($0) } ?? .infinity
                    if age >= deadline {
                        await self.updateSubscription(filename: filename)
                    }
                }
            }
        }
    }

    /// 从本地文件导入。
    func importConfig(fromFile fileURL: URL) {
        do {
            let data = try Data(contentsOf: fileURL)
            let name = self.configRepository.normalizedConfigFileName(
                fileURL.lastPathComponent, fallback: nil) ?? fileURL.lastPathComponent
            let target = self.workingDirectory.configDirectoryURL
                .appendingPathComponent(name, isDirectory: false)
            try self.configRepository.writeConfigData(data, to: target)
            self.refreshConfigs()
        } catch {
            self.errorMessage = "导入配置失败：\(error.localizedDescription)"
        }
    }

    /// 选中配置；若内核在运行则重启以应用。
    func selectConfig(_ url: URL) async {
        self.configRepository.selectConfig(url)
        self.selectedConfigName = url.lastPathComponent
        if self.isRunning {
            await self.restartCore()
        }
    }

    /// 读取配置文件文本。
    func readConfigText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// 保存配置文本；若为当前选中且内核在运行则重启应用。
    func saveConfigText(_ url: URL, text: String) async {
        do {
            try self.configRepository.writeConfigData(Data(text.utf8), to: url)
            self.actionMessage = "\(L("已保存", "Saved"))：\(url.lastPathComponent)"
            if url.lastPathComponent == self.configRepository.selectedConfig?.lastPathComponent, self.isRunning {
                await self.restartCore()
            }
        } catch {
            self.errorMessage = "\(L("保存配置失败", "Save failed"))：\(error.localizedDescription)"
        }
    }

    /// 删除配置文件。
    func deleteConfig(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        if self.subscriptionMetas.removeValue(forKey: url.lastPathComponent) != nil {
            self.subscriptionService.save(self.subscriptionMetas)
        }
        self.refreshConfigs()
    }

    // MARK: - 入站 / 分流（Phase 4）

    /// 启动用配置路径：有覆盖层则生成 effective.yaml，否则用原选中配置。
    private func resolveLaunchConfigPath() -> String? {
        guard let source = self.resolveSelectedConfigURL() else { return nil }
        guard !self.override.isEmpty else { return source.path }
        do {
            let effective = try self.overrideService.buildEffectiveConfig(
                from: source, override: self.override)
            return effective.path
        } catch {
            self.errorMessage = "生成生效配置失败：\(error.localizedDescription)"
            return source.path
        }
    }

    /// 持久化覆盖层；内核在运行则重启以应用（结构性变更走重启最稳）。
    func applyOverrides() async {
        do {
            try self.overrideService.saveOverride(self.override)
        } catch {
            self.errorMessage = "保存覆盖层失败：\(error.localizedDescription)"
            return
        }
        if self.isRunning {
            await self.restartCore()
        }
    }

    /// 清空覆盖层。
    func resetOverrides() async {
        self.override = ConfigOverride()
        await self.applyOverrides()
    }

    /// 从 .app 选取进程名/路径，加入分流规则。
    func addProcessRule(forAppAt appURL: URL, type: ProcessRuleType, target: String) {
        let value: String
        switch type {
        case .processName:
            value = Bundle(url: appURL)?.executableURL?.lastPathComponent
                ?? appURL.deletingPathExtension().lastPathComponent
        case .processPath:
            value = Bundle(url: appURL)?.executableURL?.path ?? appURL.path
        }
        self.override.processRules.append(ProcessRule(type: type, value: value, target: target))
    }

    // MARK: - 系统集成（Phase 5：TUN / 开机启动，免签名）

    /// TUN 开关：启用前确保 mihomo 有 setuid root（弹一次管理员授权，长期有效）。
    func toggleTun() async {
        let target = !self.isTunEnabled
        if target {
            let binary = self.coreRepository.detectedBinaryPath
                ?? self.workingDirectory.coreDirectoryURL
                .appendingPathComponent("mihomo", isDirectory: false).path
            do {
                if !self.dependencies.tunPermissionRepository.hasRequiredPermissions(binaryPath: binary) {
                    try await self.dependencies.tunPermissionRepository.grantPermissions(binaryPath: binary)
                }
            } catch {
                self.errorMessage = "授予 TUN 权限失败：\(error.localizedDescription)"
                return
            }
        }
        self.override.tunEnabled = target
        try? self.overrideService.saveOverride(self.override)

        if self.isRunning {
            do {
                try await self.client().requestNoResponse(
                    .patchConfigs(body: ["tun": .object(["enable": .bool(target)])]))
                self.isTunEnabled = target
            } catch {
                await self.restartCore() // PATCH 不支持时重启应用 effective.yaml
                self.isTunEnabled = target
            }
        } else {
            self.isTunEnabled = target
        }
    }

    func refreshLaunchAtLogin() {
        self.launchAtLogin = self.dependencies.launchAtLoginRepository.isEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try self.dependencies.launchAtLoginRepository.setEnabled(enabled)
            self.launchAtLogin = enabled
        } catch {
            self.errorMessage = "设置开机启动失败：\(error.localizedDescription)"
        }
    }

    /// 启动前检测配置中的端口（控制器 + 入站）是否已被其他进程占用。
    private func detectPortConflicts(configPath: String) async -> String? {
        var ports: [(port: Int, label: String)] = []
        if let ctrl = Self.parseYAMLTopLevelScalar(forKey: "external-controller", atPath: configPath),
           let colon = ctrl.lastIndex(of: ":"), let p = Int(ctrl[ctrl.index(after: colon)...]), p > 0
        {
            ports.append((p, "external-controller"))
        }
        for key in ["mixed-port", "port", "socks-port"] {
            if let value = Self.parseYAMLTopLevelScalar(forKey: key, atPath: configPath),
               let p = Int(value), p > 0
            {
                ports.append((p, key))
            }
        }
        let svc = self.diagnosticsService
        for entry in ports {
            let owner = await Task.detached { svc.portOwner(entry.port) }.value
            if let owner, owner.pid != self.ourCorePID {
                return "\(entry.label) \(L("端口", "port")) \(entry.port) "
                    + "\(L("已被占用", "is in use"))（\(owner.command) PID \(owner.pid)）——"
                    + L("请先停止占用它的程序，或修改配置端口。", "stop that process or change the port in the config.")
            }
        }
        return nil
    }

    // MARK: - 诊断（内核冲突 / 代理指向）

    func refreshDiagnostics() async {
        let svc = self.diagnosticsService
        let cores = await Task.detached { svc.scanCores() }.value
        let proxy = await Task.detached { svc.readSystemProxyState() }.value
        self.coreProcesses = cores
        self.systemProxyReadout = proxy
    }

    /// 结束其他（非本 App 管理的）内核进程；普通权限失败则升级到管理员授权。
    func killCore(pid: Int32) async {
        guard pid != self.ourCorePID else { return }
        self.errorMessage = nil
        var ok = kill(pid, SIGTERM) == 0
        if !ok {
            // root 拥有（如特权服务）→ 管理员授权结束
            let svc = self.diagnosticsService
            ok = await Task.detached { svc.killElevated(pid: pid) }.value
        }
        if ok {
            self.actionMessage = "\(L("已结束内核进程", "Terminated core")) \(pid)"
        } else {
            self.errorMessage = L("结束进程失败（可能已被系统服务守护并自动重启，请从对应客户端里关闭）。",
                                  "Failed to terminate (may be relaunched by a system service; stop it from its own client).")
        }
        try? await Task.sleep(for: .milliseconds(400))
        await self.refreshDiagnostics()
    }

    /// 清除当前系统代理设置（用于别的程序占用了系统代理时化解冲突）。走管理员 networksetup。
    func clearForeignSystemProxy() async {
        self.proxyStore.isProxySyncing = true
        defer { self.proxyStore.isProxySyncing = false }
        let service = self.systemProxyFallback
        do {
            try await Task.detached {
                try service.apply(enabled: false, host: "127.0.0.1", port: 0)
            }.value
            self.isSystemProxyEnabled = false
            self.systemProxyStatusText = nil
            self.actionMessage = L("已清除系统代理设置", "System proxy cleared")
            await self.refreshDiagnostics()
        } catch {
            self.errorMessage = "\(L("清除系统代理失败", "Failed to clear system proxy"))：\(error.localizedDescription)"
        }
    }

    // MARK: - 健康监控 / 崩溃自愈（方案 C）

    /// 周期性监控：进程存活 + API 假死；异常时按需有限自动重启。
    private func startHealthMonitor() {
        self.healthMonitorTask?.cancel()
        self.healthMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.shouldBeRunning {
                try? await Task.sleep(for: self.healthCheckInterval)
                guard !Task.isCancelled, self.shouldBeRunning else { return }

                // 1) 进程是否意外退出
                if !self.coreRepository.isRunning {
                    await self.handleCoreFailure(reason: L("内核进程意外退出", "core process exited"))
                    return
                }
                // 2) API 假死检测（进程在但 /version 连续无响应）
                do {
                    let _: VersionInfo = try await self.client().request(.version)
                    self.apiFailureStreak = 0
                    if self.apiStatus != .healthy { self.apiStatus = .healthy }
                } catch {
                    self.apiFailureStreak += 1
                    self.apiStatus = .degraded
                    if self.apiFailureStreak >= self.apiDeathThreshold {
                        await self.handleCoreFailure(reason: L("内核 API 无响应（假死）", "core API unresponsive"))
                        return
                    }
                }
            }
        }
    }

    private func handleCoreFailure(reason: String) async {
        self.shouldBeRunning = false
        self.healthMonitorTask?.cancel()
        self.healthMonitorTask = nil
        self.streamCoordinator.cancelAll()
        self.lifecycle = .failed(reason: reason)
        self.apiStatus = .failed
        self.appendLocalLog(level: "error", message: "\(L("内核异常", "Core failure"))：\(reason)")

        guard self.autoRestartEnabled else {
            self.errorMessage = "\(L("内核异常退出", "Core exited"))：\(reason)"
            return
        }
        guard self.withinRestartBudget() else {
            self.errorMessage = L(
                "内核反复异常，自动重启已达上限（60 秒内 3 次），请手动检查后重启。",
                "Core keeps failing; auto-restart limit reached (3/60s). Please restart manually.")
            return
        }
        self.restartTimestamps.append(Date())
        self.appendLocalLog(level: "warning", message: L("正在自动重启内核…", "Auto-restarting core…"))
        await self.restartCore()
    }

    private func withinRestartBudget() -> Bool {
        let now = Date()
        self.restartTimestamps = self.restartTimestamps.filter {
            now.timeIntervalSince($0) < self.restartWindow
        }
        return self.restartTimestamps.count < self.maxRestartsInWindow
    }

    private func appendLocalLog(level: String, message: String) {
        var logs = self.logsStore.errorLogs
        logs.append(AppErrorLogEntry(source: .clashbar, level: level, message: message))
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
        self.logsStore.errorLogs = logs
    }

    // MARK: - WebSocket 流

    private func configureStreamCoordinator() {
        self.streamCoordinator.shouldReconnect = { [weak self] in
            guard let self else { return false }
            return self.coreRepository.isRunning
        }
    }

    private func startStreams() {
        self.startTrafficStream()
        self.startConnectionsStream()
        self.startLogsStream()
    }

    private func startTrafficStream() {
        let normalize = NormalizeWebSocketPayloadUseCase()
        self.streamCoordinator.start(
            key: "traffic",
            makeWebSocket: { [weak self] in
                guard let self, let client = self.apiClient else { throw APIError.invalidResponse }
                return try client.makeWebSocketTask(for: .traffic)
            },
            onPayload: { [weak self] data in
                guard let self,
                      let snapshot = try? JSONDecoder().decode(TrafficSnapshot.self, from: data)
                else { return }
                self.applyTraffic(snapshot)
            },
            normalizePayload: { normalize.execute(message: $0) })
    }

    private func startConnectionsStream() {
        let normalize = NormalizeWebSocketPayloadUseCase()
        self.streamCoordinator.start(
            key: "connections",
            makeWebSocket: { [weak self] in
                guard let self, let client = self.apiClient else { throw APIError.invalidResponse }
                return try client.makeWebSocketTask(for: .connections(interval: nil))
            },
            onPayload: { [weak self] data in
                guard let self,
                      let snapshot = try? JSONDecoder().decode(ConnectionsSnapshot.self, from: data)
                else { return }
                self.connectionsStore.connections = snapshot.connections
                self.connectionsStore.connectionsCount = snapshot.totalCount
            },
            normalizePayload: { normalize.execute(message: $0) })
    }

    private func startLogsStream() {
        let normalize = NormalizeWebSocketPayloadUseCase()
        self.streamCoordinator.start(
            key: "logs",
            makeWebSocket: { [weak self] in
                guard let self, let client = self.apiClient else { throw APIError.invalidResponse }
                return try client.makeWebSocketTask(for: .logs(level: nil))
            },
            onPayload: { [weak self] data in
                guard let self,
                      let line = try? JSONDecoder().decode(LogLine.self, from: data),
                      let message = line.payload
                else { return }
                let entry = AppErrorLogEntry(
                    source: .mihomo,
                    level: line.type ?? "info",
                    message: message)
                var logs = self.logsStore.errorLogs
                logs.append(entry)
                if logs.count > 500 { logs.removeFirst(logs.count - 500) }
                self.logsStore.errorLogs = logs
            },
            normalizePayload: { normalize.execute(message: $0) })
    }

    private func applyTraffic(_ snapshot: TrafficSnapshot) {
        self.trafficStore.traffic = snapshot
        if let upTotal = snapshot.upTotal { self.trafficStore.displayUpTotal = upTotal }
        if let downTotal = snapshot.downTotal { self.trafficStore.displayDownTotal = downTotal }
        var up = self.trafficStore.trafficHistoryUp
        var down = self.trafficStore.trafficHistoryDown
        up.append(snapshot.up)
        down.append(snapshot.down)
        if up.count > self.trafficHistoryCap { up.removeFirst(up.count - self.trafficHistoryCap) }
        if down.count > self.trafficHistoryCap { down.removeFirst(down.count - self.trafficHistoryCap) }
        self.trafficStore.trafficHistoryUp = up
        self.trafficStore.trafficHistoryDown = down
    }

    // MARK: - 配置解析辅助

    private func resolveSelectedConfigURL() -> URL? {
        if let selected = self.configRepository.selectedConfig { return selected }
        return self.configRepository.availableConfigs.first
    }

    private func applyControllerAndSecret(fromConfigAt path: String) {
        self.launchController = self.rawControllerFromConfig(at: path) ?? Self.defaultController
        self.clientController = Self.normalizeControllerForClient(self.launchController)
        self.controllerSecret = self.secretFromConfig(at: path)
    }

    private func rawControllerFromConfig(at path: String) -> String? {
        Self.parseYAMLTopLevelScalar(forKey: "external-controller", atPath: path)
    }

    private func secretFromConfig(at path: String) -> String? {
        guard let raw = Self.parseYAMLTopLevelScalar(forKey: "secret", atPath: path) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "~" || trimmed == "null" { return nil }
        return trimmed
    }

    // MARK: - 静态工具

    /// 归一化 controller 给 client 用：0.0.0.0→127.0.0.1，::→::1。
    private static func normalizeControllerForClient(_ controller: String) -> String {
        var value = controller
        if value.hasPrefix("0.0.0.0") {
            value = value.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
        }
        return value
    }

    private static func hostComponent(of controller: String) -> String {
        // 形如 host:port，取最后一个冒号前的部分作为 host。
        guard let idx = controller.lastIndex(of: ":") else { return "127.0.0.1" }
        let host = String(controller[..<idx])
        return host.isEmpty ? "127.0.0.1" : host
    }

    /// 只扫顶层缩进的 YAML 标量解析（对齐 ClashBar parseYAMLScalarValue）。
    private static func parseYAMLTopLevelScalar(forKey key: String, atPath path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            // 仅顶层键（无前导空白）
            guard let first = line.first, !first.isWhitespace else { continue }
            guard line.hasPrefix(key) else { continue }
            let afterKey = line.dropFirst(key.count)
            guard let colonIdx = afterKey.firstIndex(of: ":") else { continue }
            // 确保冒号紧跟在 key 之后（避免 external-controller-xxx 误匹配）
            let between = afterKey[afterKey.startIndex..<colonIdx]
            guard between.allSatisfy({ $0.isWhitespace }) else { continue }
            var value = String(afterKey[afterKey.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
            // 去行内注释
            if let hashIdx = value.firstIndex(of: "#"),
               !(value.hasPrefix("\"") || value.hasPrefix("'")) {
                value = String(value[..<hashIdx]).trimmingCharacters(in: .whitespaces)
            }
            // 剥引号
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
                (value.hasPrefix("'") && value.hasSuffix("'")), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
