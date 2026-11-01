import SwiftUI

struct TranscriptView: View {
    let id: UUID
    let transcript: Transcript
    let diarized: Bool
    let title: String
    /// 以下仅历史记录传入：已有的总结、是否正在总结、点「总结」时的动作
    var summary: String? = nil
    var isSummarizing = false
    var onSummarize: (() -> Void)? = nil

    // 每条转录各自的开关状态，存在 store 里（按 id 区分，切换转录互不影响）
    @EnvironmentObject private var toggles: TranscriptTogglesStore
    @State private var copied = false
    @State private var showSummary = false

    private var current: TranscriptTogglesStore.Toggles { toggles.toggles(for: id) }

    private var renderedText: String {
        TranscriptExporter.render(
            transcript,
            showTimestamps: current.showTimestamps,
            showSpeakers: current.showSpeakers && diarized
        )
    }

    private var displayingSummary: Bool { showSummary && summary != nil }
    private var displayedText: String { displayingSummary ? (summary ?? "") : renderedText }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            TranscriptTextView(text: displayedText)
        }
        .navigationTitle(title)
        .onChange(of: summary) { _, newValue in
            // 刚生成完总结时直接切过去看
            if newValue != nil { showSummary = true }
        }
    }

    private var toolbar: some View {
        HStack {
            if summary != nil {
                Picker("显示", selection: $showSummary) {
                    Text("文字稿").tag(false)
                    Text("总结").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            if !displayingSummary {
                Toggle("带时间戳", isOn: toggles.binding(for: id, keyPath: \.showTimestamps))
                    .toggleStyle(.button)
                // 无说话人信息时按钮禁用且强制显示为「关」，避免出现高亮却点不动的矛盾态
                Toggle("分发言人", isOn: diarized ? toggles.binding(for: id, keyPath: \.showSpeakers) : .constant(false))
                    .toggleStyle(.button)
                    .disabled(!diarized)

                if let count = transcript.speakerCount, diarized {
                    Text("\(count) 位说话人")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if summary == nil, let onSummarize {
                Button(action: onSummarize) {
                    Label(isSummarizing ? "总结中…" : "总结", systemImage: "sparkles")
                }
                .disabled(isSummarizing)
                .help("用本机 Claude Code 为这条文字稿写总结")
            }

            Button {
                TranscriptExporter.copyToClipboard(displayedText)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
            }

            if displayingSummary {
                Button {
                    MarkdownSaver.save(summary ?? "", suggestedName: "\(title) 总结")
                } label: {
                    Label("导出 .md", systemImage: "square.and.arrow.up")
                }
            } else {
                Menu {
                    ForEach(ExportFileType.allCases) { type in
                        Button(type.rawValue) {
                            // 导出跟随当前两个开关
                            TranscriptExporter.exportWithPanel(
                                transcript,
                                type: type,
                                showTimestamps: current.showTimestamps,
                                showSpeakers: current.showSpeakers && diarized,
                                suggestedName: title
                            )
                        }
                    }
                } label: {
                    Label("导出…", systemImage: "square.and.arrow.up")
                }
            }
        }
        .padding(10)
    }
}
