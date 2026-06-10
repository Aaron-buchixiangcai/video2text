import SwiftUI

struct Video2TextApp: App {
    @StateObject private var appState = AppState()

    init() {
        // swift run 直接跑可执行文件时没有 bundle，需要手动升为前台应用
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("视频转文字") {
            MainView(history: appState.history)
                .environmentObject(appState)
                .frame(minWidth: 760, minHeight: 480)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
