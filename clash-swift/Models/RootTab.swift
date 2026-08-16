import Foundation

/// 主导航标签页。核心层（数据采集策略等）依赖此枚举；
/// Phase 1 起用于全窗口侧边栏导航，后续会扩展 home / profiles 等页。
enum RootTab: String, CaseIterable, Hashable {
    case proxy
    case rules
    case connections
    case logs
    case system

    var titleKey: String {
        switch self {
        case .proxy: "ui.tab.proxy"
        case .rules: "ui.tab.rules"
        case .connections: "ui.tab.connections"
        case .logs: "ui.tab.logs"
        case .system: "ui.tab.system"
        }
    }

    var symbolName: String {
        switch self {
        case .proxy: "square.grid.2x2.fill"
        case .rules: "arrow.left.arrow.right"
        case .connections: "link"
        case .logs: "doc.fill"
        case .system: "gearshape.fill"
        }
    }
}
