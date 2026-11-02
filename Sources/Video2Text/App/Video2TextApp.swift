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
            MainView(
                history: appState.history,
                digests: appState.digests,
                batchSummary: appState.batchSummary
            )
                .environmentObject(appState)
                .environmentObject(appState.transcriptToggles)
                .frame(minWidth: 760, minHeight: 480)
        }
        // 只用一个主窗口：搜索面板、多选状态都存在共享的 AppState 里，开第二个窗口会两边同步
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView(settingsStore: appState.settingsStore)
                .environmentObject(appState)
        }
    }
}
