import Foundation

/// 日志级别过滤器。原定义在菜单栏 UI 文件中，抽出以供 LogsViewModel / PresentLogsUseCase 复用。
enum LogLevelFilter: Hashable, CaseIterable {
    case info
    case warning
    case error

    var titleKey: String {
        switch self {
        case .info: "ui.log_filter.info"
        case .warning: "ui.log_filter.warning"
        case .error: "ui.log_filter.error"
        }
    }
}
