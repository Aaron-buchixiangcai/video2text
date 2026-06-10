import SwiftUI

struct TranscriptView: View {
    let transcript: Transcript
    let diarized: Bool
    let title: String

    @State private var format: TranscriptFormat = .plain
    @State private var copied = false

    private var availableFormats: [TranscriptFormat] {
        diarized ? TranscriptFormat.allCases : [.plain, .timestamped]
    }

    private var renderedText: String {
        TranscriptExporter.render(transcript, format: format)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                Text(renderedText)
                    .font(.body)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .navigationTitle(title)
        .onAppear {
            format = diarized ? .diarized : .plain
        }
        .onChange(of: diarized) { _, newValue in
            if newValue { format = .diarized }
        }
    }

    private var toolbar: some View {
        HStack {
            Picker("格式", selection: $format) {
                ForEach(availableFormats) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

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

            Button {
                TranscriptExporter.exportWithPanel(
                    transcript, diarized: diarized, suggestedName: title
                )
            } label: {
                Label("导出…", systemImage: "square.and.arrow.up")
            }
        }
        .padding(10)
    }
}
