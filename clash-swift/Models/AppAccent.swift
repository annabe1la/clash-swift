import SwiftUI

/// 强调色主题。
enum AppAccent: String, CaseIterable, Identifiable {
    case blue, purple, indigo, teal, green, orange, pink, red

    var id: String { self.rawValue }

    var color: Color {
        switch self {
        case .blue: .blue
        case .purple: .purple
        case .indigo: .indigo
        case .teal: .teal
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        case .red: .red
        }
    }

    var title: String {
        switch self {
        case .blue: L("蓝", "Blue")
        case .purple: L("紫", "Purple")
        case .indigo: L("靛蓝", "Indigo")
        case .teal: L("青", "Teal")
        case .green: L("绿", "Green")
        case .orange: L("橙", "Orange")
        case .pink: L("粉", "Pink")
        case .red: L("红", "Red")
        }
    }
}
