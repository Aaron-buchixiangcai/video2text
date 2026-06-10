import AppKit
import Foundation
import UniformTypeIdentifiers

enum TranscriptFormat: String, CaseIterable, Identifiable {
    case plain = "纯文字"
    case timestamped = "带时间戳"
    case diarized = "分发言人"

    var id: String { rawValue }
}

enum ExportFileType: String, CaseIterable, Identifiable {
    case txt = "文本 (.txt)"
    case srt = "字幕 (.srt)"
    case markdown = "Markdown (.md)"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .txt: return "txt"
        case .srt: return "srt"
        case .markdown: return "md"
        }
    }
}

enum TranscriptExporter {
    static func render(_ transcript: Transcript, format: TranscriptFormat) -> String {
        switch format {
        case .plain:
            return transcript.plainText
        case .timestamped:
            return transcript.utterances.map { u in
                "[\(formatTimestamp(u.start))] \(u.text)"
            }.joined(separator: "\n")
        case .diarized:
            return transcript.coalesced().utterances.map { u in
                let label = u.speaker.map { "说话人\($0 + 1)" } ?? "未知"
                return "[\(formatTimestamp(u.start))] \(label)：\(u.text)"
            }.joined(separator: "\n")
        }
    }

    static func renderFile(_ transcript: Transcript, type: ExportFileType, diarized: Bool) -> String {
        switch type {
        case .txt:
            return render(transcript, format: diarized ? .diarized : .timestamped)
        case .srt:
            return srt(transcript, includeSpeaker: diarized)
        case .markdown:
            return markdown(transcript, diarized: diarized)
        }
    }

    static func srt(_ transcript: Transcript, includeSpeaker: Bool) -> String {
        transcript.utterances.enumerated().map { index, u in
            let speaker = includeSpeaker
                ? (u.speaker.map { "说话人\($0 + 1)：" } ?? "")
                : ""
            return """
            \(index + 1)
            \(srtTime(u.start)) --> \(srtTime(u.end))
            \(speaker)\(u.text)
            """
        }.joined(separator: "\n\n") + "\n"
    }

    static func markdown(_ transcript: Transcript, diarized: Bool) -> String {
        var lines = ["# 文字稿", ""]
        if diarized {
            for u in transcript.coalesced().utterances {
                let label = u.speaker.map { "说话人\($0 + 1)" } ?? "未知"
                lines.append("**\(label)**（\(formatTimestamp(u.start))）：\(u.text)")
                lines.append("")
            }
        } else {
            for u in transcript.utterances {
                lines.append("- `\(formatTimestamp(u.start))` \(u.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// NSSavePanel 导出
    @MainActor
    static func exportWithPanel(_ transcript: Transcript, diarized: Bool, suggestedName: String) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sanitizeFileName(suggestedName)
        panel.allowedContentTypes = [
            UTType(filenameExtension: "txt")!,
            UTType(filenameExtension: "srt") ?? .plainText,
            UTType(filenameExtension: "md") ?? .plainText,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let type = ExportFileType.allCases.first {
            $0.fileExtension == url.pathExtension.lowercased()
        } ?? .txt
        let content = renderFile(transcript, type: type, diarized: diarized)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func srtTime(_ seconds: Double) -> String {
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d,%03d", total / 3600, (total % 3600) / 60, total % 60, ms)
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return (trimmed.isEmpty ? "文字稿" : String(trimmed.prefix(80))) + ".txt"
    }
}
