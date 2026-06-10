import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var ytDlpVersion: String?
    @State private var updating = false
    @State private var updateMessage: String?

    private var settings: Binding<AppSettings> {
        Binding(
            get: { appState.settingsStore.settings },
            set: { appState.settingsStore.settings = $0 }
        )
    }

    var body: some View {
        Form {
            Section("语音识别") {
                Picker("模型", selection: settings.model) {
                    ForEach(AppSettings.availableModels, id: \.id) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                Picker("语言", selection: settings.language) {
                    Text("中文为主").tag("zh")
                    Text("英文为主").tag("en")
                    Text("自动检测").tag("auto")
                }
                Toggle("区分发言人（说话人分离）", isOn: settings.diarizationEnabled)
                Toggle("使用 hf-mirror.com 镜像下载模型（国内网络）", isOn: settings.useMirror)
            }

            Section("视频下载") {
                LabeledContent("yt-dlp 版本", value: ytDlpVersion ?? "未安装")
                HStack {
                    Button(updating ? "更新中…" : "检查更新") {
                        updateYtDlp()
                    }
                    .disabled(updating || !appState.ytDlpInstalled)
                    if let updateMessage {
                        Text(updateMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                TextField(
                    "cookies.txt 路径（抖音 / B 站会员视频需要）",
                    text: Binding(
                        get: { settings.wrappedValue.cookiesPath ?? "" },
                        set: { settings.wrappedValue.cookiesPath = $0.isEmpty ? nil : $0 }
                    )
                )
                Text("抖音链接通常需要登录 cookies：用浏览器扩展「Get cookies.txt LOCALLY」导出后在此填路径。下载失败时也可直接把视频文件拖入主窗口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("数据") {
                LabeledContent("数据目录", value: AppPaths.root.path)
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.root])
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .task {
            ytDlpVersion = await YtDlpManager.version()
        }
    }

    private func updateYtDlp() {
        updating = true
        updateMessage = nil
        Task {
            defer { updating = false }
            do {
                let output = try await YtDlpManager.update()
                updateMessage = output.components(separatedBy: "\n").last
                ytDlpVersion = await YtDlpManager.version()
            } catch {
                updateMessage = "更新失败：\(error.localizedDescription)"
            }
        }
    }
}
