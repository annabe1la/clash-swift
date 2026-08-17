//
//  clash_swiftApp.swift
//  clash-swift
//
//  原生 macOS Clash(mihomo) 客户端：全窗口 + 菜单栏。
//

import AppKit
import SwiftUI

@main
struct ClashSwiftApp: App {
    @StateObject private var appModel = AppModel(dependencies: .live)

    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .frame(minWidth: 820, minHeight: 560)
                .tint(self.appModel.accent.color)
                .preferredColorScheme(self.colorScheme(for: self.appModel.appearance))
                .environmentObject(self.appModel)
                .environmentObject(self.appModel.trafficStore)
                .environmentObject(self.appModel.connectionsStore)
                .environmentObject(self.appModel.proxyStore)
                .environmentObject(self.appModel.logsStore)
                .task { self.appModel.bootstrap() }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification))
                { _ in
                    self.appModel.shutdownForTermination()
                }
        }
        .defaultSize(width: 980, height: 640)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(self.appModel)
                .environmentObject(self.appModel.trafficStore)
        } label: {
            Image(systemName: self.appModel.isRunning ? "network" : "network.slash")
        }
        .menuBarExtraStyle(.window)
    }

    private func colorScheme(for mode: AppAppearanceMode) -> ColorScheme? {
        switch mode {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
