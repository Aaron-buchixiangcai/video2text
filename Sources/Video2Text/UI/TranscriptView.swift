import SwiftUI

struct TranscriptView: View {
    let transcript: Transcript
    let diarized: Bool
    let title: String

    @State private var format: TranscriptFormat = .plain
    @State private var renderedText = ""
    @State private var copied = false

    private var availableFormats: [TranscriptFormat] {
        diarized ? TranscriptFormat.allCases : [.plain, .timestamped]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            TranscriptTextView(text: renderedText)
        }
        .navigationTitle(TitleFormatter.shortDisplay(title))
        .onAppear {
            let initialFormat: TranscriptFormat = diarized ? .diarized : .plain
            format = initialFormat
            renderedText = TranscriptExporter.render(transcript, format: initialFormat)
        }
        .onChange(of: format) { _, newValue in
            renderedText = TranscriptExporter.render(transcript, format: newValue)
        }
        .onChange(of: diarized) { _, newValue in
            if newValue {
                format = .diarized
                renderedText = TranscriptExporter.render(transcript, format: .diarized)
            }
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

            Menu {
                ForEach(ExportFileType.allCases) { type in
                    Button(type.rawValue) {
                        TranscriptExporter.exportWithPanel(
                            transcript,
                            type: type,
                            diarized: diarized,
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
