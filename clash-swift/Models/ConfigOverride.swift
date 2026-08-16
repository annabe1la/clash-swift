import Foundation

/// 自定义入站监听器（mihomo listeners）。
struct ListenerConfig: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var type: String        // mixed / http / socks / tproxy / redir
    var port: Int
    var listen: String       // 绑定 IP，如 0.0.0.0 / 127.0.0.1

    static let inboundTypes = ["mixed", "http", "socks", "tproxy", "redir"]
}

/// 按进程/按 App 分流规则类型。
enum ProcessRuleType: String, Codable, CaseIterable, Identifiable {
    case processName = "PROCESS-NAME"
    case processPath = "PROCESS-PATH"

    var id: String { self.rawValue }
    var title: String {
        switch self {
        case .processName: "进程名"
        case .processPath: "进程路径"
        }
    }
}

/// 一条按 App 分流规则。
struct ProcessRule: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var type: ProcessRuleType
    var value: String        // 进程名(Foo) 或 可执行文件绝对路径
    var target: String       // DIRECT / PROXY / 某代理组名

    /// 序列化为 mihomo 规则行：PROCESS-NAME,Foo,DIRECT
    var ruleLine: String { "\(self.type.rawValue),\(self.value),\(self.target)" }
}

/// 用户覆盖层：入站控制 + 按 App 分流。深度合并进选中配置生成 effective.yaml。
struct ConfigOverride: Codable, Equatable {
    var mixedPort: Int?
    var httpPort: Int?       // 对应 mihomo `port`
    var socksPort: Int?
    var allowLan: Bool?
    var ipv6: Bool?
    var bindAddress: String?
    var tunEnabled: Bool?
    var listeners: [ListenerConfig] = []
    var processRules: [ProcessRule] = []

    var isEmpty: Bool {
        self.mixedPort == nil && self.httpPort == nil && self.socksPort == nil
            && self.allowLan == nil && self.ipv6 == nil && self.bindAddress == nil
            && self.tunEnabled == nil && self.listeners.isEmpty && self.processRules.isEmpty
    }
}
