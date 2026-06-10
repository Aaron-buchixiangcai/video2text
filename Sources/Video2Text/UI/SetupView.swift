import SwiftUI

/// 首次运行：下载 yt-dlp。Whisper / 说话人分离模型在首个任务时自动下载。
struct SetupView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var downloading = false
    @State private var progress: Double = 0
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(Color.accentColor)

            Text("首次运行设置")
                .font(.title2.bold())

            Text("需要下载视频下载组件 yt-dlp（约 35MB）。\n语音识别模型（约 700MB）会在第一次转写时自动下载。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if downloading {
                ProgressView(value: progress) {
                    Text("正在下载 yt-dlp… \(Int(progress * 100))%")
                        .font(.caption)
                }
                .frame(width: 300)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 360)
            }

            HStack {
                Button("稍后再说") { dismiss() }
                Button(downloading ? "下载中…" : "开始下载") {
                    install()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(downloading)
            }
        }
        .padding(32)
        .frame(width: 460)
        .interactiveDismissDisabled(downloading)
    }

    private func install() {
        downloading = true
        errorMessage = nil
        Task {
            do {
                _ = try await YtDlpManager.install { fraction in
                    Task { @MainActor in progress = fraction }
                }
                appState.ytDlpInstalled = true
                dismiss()
            } catch {
                errorMessage = "下载失败：\(error.localizedDescription)\n也可以用 Homebrew 安装：brew install yt-dlp"
            }
            downloading = false
        }
    }
}
