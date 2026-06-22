import SwiftUI

struct TranscriptView: View {
    let id: UUID
    let transcript: Transcript
    let diarized: Bool
    let title: String

    // 每条转录各自的开关状态，存在 store 里（按 id 区分，切换转录互不影响）
    @EnvironmentObject private var toggles: TranscriptTogglesStore
    @State private var copied = false

    private var current: TranscriptTogglesStore.Toggles { toggles.toggles(for: id) }

    private var renderedText: String {
        TranscriptExporter.render(
            transcript,
            showTimestamps: current.showTimestamps,
            showSpeakers: current.showSpeakers && diarized
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            TranscriptTextView(text: renderedText)
        }
        .navigationTitle(title)
    }

    private var toolbar: some View {
        HStack {
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

            Spacer()

            Button {
                TranscriptExporter.copyToClipboard(renderedText)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
            }

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
        .padding(10)
    }
}
