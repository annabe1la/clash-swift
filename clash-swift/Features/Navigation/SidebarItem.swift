import Foundation

/// 全窗口侧边栏导航项（Verge 式）。
enum SidebarItem: String, CaseIterable, Hashable, Identifiable {
    case overview
    case proxies
    case profiles
    case connections
    case rules
    case logs
    case settings

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .overview: L("概览", "Overview")
        case .proxies: L("节点", "Proxies")
        case .profiles: L("订阅", "Profiles")
        case .connections: L("连接", "Connections")
        case .rules: L("规则", "Rules")
        case .logs: L("日志", "Logs")
        case .settings: L("设置", "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .proxies: "square.grid.2x2.fill"
        case .profiles: "doc.on.doc.fill"
        case .connections: "link"
        case .rules: "arrow.left.arrow.right"
        case .logs: "doc.text.fill"
        case .settings: "gearshape.fill"
        }
    }
}
