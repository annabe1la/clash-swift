import Foundation

/// 轻量本地化：调用处直接给中英两版文案，切换语言即时生效（无需 .strings / 重启）。
/// 生效机制：所有页面都观察 AppModel（@EnvironmentObject），language 变化触发重渲染，
/// L() 读取 LocalizationCenter.current 返回对应语言。
enum LocalizationCenter {
    /// 仅在主线程读写（AppModel @MainActor 写、SwiftUI 视图体读），故标注 unsafe 免并发检查。
    nonisolated(unsafe) static var current: AppLanguage = .zhHans
}

/// 返回当前语言对应文案。
func L(_ zh: String, _ en: String) -> String {
    switch LocalizationCenter.current {
    case .zhHans: zh
    case .en: en
    }
}
