import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    // 直接观察 SettingsStore：否则改了模型只写入了值，视图不刷新，下拉框看起来"点了没反应"
    @ObservedObject var settingsStore: SettingsStore
    @State private var ytDlpVersion: String?
    @State private var versionLoaded = false
    @State private var updating = false
    @State private var updateMessage: String?

    private var settings: Binding<AppSettings> { $settingsStore.settings }

    var body: some View {
        // 分成三页：内容放在一页里时窗口装不下，下半部分被挡住又看不出能滚动
        TabView {
            transcriptionTab
                .tabItem { Label("转写", systemImage: "waveform") }
            downloadTab
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
            summaryTab
                .tabItem { Label("总结与数据", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 460)
        .task {
            ytDlpVersion = await YtDlpManager.version()
            versionLoaded = true
        }
    }

    private var transcriptionTab: some View {
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
        }
        .formStyle(.grouped)
    }

    private var downloadTab: some View {
        Form {
            Section("视频下载") {
                // 说明文字放进控件的标签里，表单会把它显示成同一行的副标题
                Toggle(isOn: settings.preferSubtitles) {
                    Text("视频有字幕时直接用字幕")
                    Text("更快，不用下载音频和转写，但字幕没有说话人标注。YouTube 总是先找字幕；B站的 AI 字幕要登录才有，只在填了 cookies.txt 时尝试。")
                }
                Stepper(value: settings.maxBilibiliParts, in: 1...50) {
                    Text("B站分P视频最多转写前 \(settings.wrappedValue.maxBilibiliParts)P")
                    Text("课程合集常有几十上百P，全转很久。每P开头标出分P标题；只想要某一P时，粘贴带 ?p=N 的链接。")
                }
                TextField(
                    text: Binding(
                        get: { settings.wrappedValue.cookiesPath ?? "" },
                        set: { settings.wrappedValue.cookiesPath = $0.isEmpty ? nil : $0 }
                    ),
                    prompt: Text("通常无需填写")
                ) {
                    Text("cookies.txt 路径")
                    Text("只有登录后才能看的视频需要。抖音会自动用隔离的临时浏览器会话验证，不读取你的个人 Chrome 数据。")
                }
            }
            Section("yt-dlp") {
                LabeledContent("版本") {
                    if !appState.ytDlpInstalled {
                        Text("未安装")
                    } else if let ytDlpVersion, !ytDlpVersion.isEmpty {
                        Text(ytDlpVersion)
                    } else if versionLoaded {
                        Text("未知")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                HStack {
                    Button(updating ? "更新中…" : "检查更新") {
                        updateYtDlp()
                    }
                    // 版本读出来之前不让点，否则无法判断是否真的更新了
                    .disabled(updating || !versionLoaded || !appState.ytDlpInstalled)
                    if let updateMessage {
                        Text(updateMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var summaryTab: some View {
        Form {
            Section {
                LabeledContent("claude 命令行", value: Summarizer.locateClaude()?.path ?? "未找到")
            } header: {
                Text("总结（Claude）")
            } footer: {
                Text("总结调用本机 Claude Code 的命令行版，用你自己的账号和额度，使用 \(Summarizer.modelDisplayName) 模型。提示未登录时，在终端运行 claude auth login。")
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
    }

    private func updateYtDlp() {
        updating = true
        updateMessage = nil
        Task {
            defer { updating = false }
            let before = ytDlpVersion
            do {
                try await YtDlpManager.update()
                let after = await YtDlpManager.version()
                ytDlpVersion = after
                updateMessage = after != nil && after == before ? "已是最新版本" : "已更新到 \(after ?? "新版本")"
            } catch {
                updateMessage = "更新失败：\(error.localizedDescription)"
            }
        }
    }
}
