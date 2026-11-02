import SwiftUI
import UniformTypeIdentifiers

/// 展示一份汇总：视频列表 + Claude 写的综合报告
struct DigestView: View {
    let digest: DigestRecord
    @EnvironmentObject var appState: AppState
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(digest.recordIDs.count) 个视频 · \(digest.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Menu {
                    ForEach(Array(digest.recordIDs.enumerated()), id: \.offset) { index, id in
                        let title = index < digest.videoTitles.count ? digest.videoTitles[index] : ""
                        Button("V\(index + 1)：\(TitleFormatter.shortDisplay(title, maxCharacters: 30))") {
                            appState.selection = .history(id)
                        }
                        // 原记录被删除后无法跳转
                        .disabled(appState.record(for: id) == nil)
                    }
                } label: {
                    Label("视频列表", systemImage: "list.bullet")
                }
                .fixedSize()

                Button {
                    TranscriptExporter.copyToClipboard(digest.markdown)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                }

                Button {
                    MarkdownSaver.save(digest.markdown, suggestedName: digest.title)
                } label: {
                    Label("导出 .md", systemImage: "square.and.arrow.up")
                }
            }
            .padding(10)
            Divider()
            TranscriptTextView(text: digest.markdown, markdown: true)
        }
        .navigationTitle(digest.title)
    }
}

/// 总结、汇总都是 Markdown 文本，用保存面板导出为 .md
enum MarkdownSaver {
    @MainActor
    static func save(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = TranscriptExporter.safeFileStem(suggestedName) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "导出失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
