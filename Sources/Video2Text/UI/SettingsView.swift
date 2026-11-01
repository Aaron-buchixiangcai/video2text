import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    // 直接观察 SettingsStore：否则改了模型只写入了值，视图不刷新，下拉框看起来"点了没反应"
    @ObservedObject var settingsStore: SettingsStore
    @State private var ytDlpVersion: String?
    @State private var updating = false
    @State private var updateMessage: String?

    private var settings: Binding<AppSettings> { $settingsStore.settings }

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
            }

            Section("视频下载") {
                Toggle("视频有字幕时直接用字幕", isOn: settings.preferSubtitles)
                Text("更快，不用下载音频和转写；但字幕没有说话人标注。YouTube 总是先找字幕；B站的 AI 字幕要登录才有，只在下方填了 cookies.txt 时尝试，也能避开部分视频音频下载失败（HTTP 567）的问题。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    "高级：cookies.txt 路径（通常无需填写）",
                    text: Binding(
                        get: { settings.wrappedValue.cookiesPath ?? "" },
                        set: { settings.wrappedValue.cookiesPath = $0.isEmpty ? nil : $0 }
                    )
                )
                Text("抖音会自动使用隔离的临时浏览器会话完成验证，不读取你的个人 Chrome 数据。只有登录后才能观看的视频才需要在这里指定 cookies.txt。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("总结（Claude）") {
                LabeledContent("claude 命令行", value: Summarizer.locateClaude()?.path ?? "未找到")
                Text("总结调用本机 Claude Code 的命令行版，用你自己的账号和额度，默认 \(Summarizer.model) 模型。提示未登录时，在终端运行 claude auth login。")
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
