import AppKit
import Foundation
import UniformTypeIdentifiers

enum ExportFileType: String, CaseIterable, Identifiable {
    case txt = "文本 (.txt)"
    case docx = "Word (.docx)"
    case srt = "字幕 (.srt)"
    case vtt = "字幕 (.vtt)"
    case markdown = "Markdown (.md)"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .txt: return "txt"
        case .docx: return "docx"
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .markdown: return "md"
        }
    }

    var contentType: UTType {
        UTType(filenameExtension: fileExtension) ?? .plainText
    }
}

enum TranscriptExporter {
    /// 按两个独立开关组合渲染：时间戳、说话人可分别开关，也可同时开。
    static func render(_ transcript: Transcript, showTimestamps: Bool, showSpeakers: Bool) -> String {
        guard showTimestamps || showSpeakers else { return transcript.plainText }
        let source = showSpeakers ? transcript.coalesced().utterances : transcript.utterances
        return source.map { u in
            if u.isMarker { return u.text }
            let time = showTimestamps ? "[\(formatTimestamp(u.start))] " : ""
            let speaker = showSpeakers ? ((u.speaker.map { "说话人\($0 + 1)" } ?? "未知") + "：") : ""
            return time + speaker + u.text
        }.joined(separator: "\n")
    }

    static func renderFile(
        _ transcript: Transcript,
        type: ExportFileType,
        showTimestamps: Bool,
        showSpeakers: Bool
    ) -> String {
        switch type {
        case .txt, .docx:
            return render(transcript, showTimestamps: showTimestamps, showSpeakers: showSpeakers)
        case .srt:
            // 字幕格式天然带时间戳，仅说话人随开关
            return srt(transcript, includeSpeaker: showSpeakers)
        case .vtt:
            return vtt(transcript, includeSpeaker: showSpeakers)
        case .markdown:
            return markdown(transcript, diarized: showSpeakers)
        }
    }

    /// 字幕用的条目：去掉分P标题行；分P视频每P时间从 0 起算，字幕里接着前一P往后排，保证时间递增
    private static func subtitleCues(_ transcript: Transcript) -> [Utterance] {
        var cues: [Utterance] = []
        var offset = 0.0
        var latestEnd = 0.0
        for u in transcript.utterances {
            if u.isMarker {
                offset = latestEnd
                continue
            }
            var cue = u
            cue.start += offset
            cue.end += offset
            latestEnd = max(latestEnd, cue.end)
            cues.append(cue)
        }
        return cues
    }

    static func srt(_ transcript: Transcript, includeSpeaker: Bool) -> String {
        subtitleCues(transcript).enumerated().map { index, u in
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

    static func vtt(_ transcript: Transcript, includeSpeaker: Bool) -> String {
        let cues = subtitleCues(transcript).map { u in
            let speaker = includeSpeaker
                ? (u.speaker.map { "说话人\($0 + 1)：" } ?? "")
                : ""
            return """
            \(vttTime(u.start)) --> \(vttTime(u.end))
            \(speaker)\(u.text)
            """
        }.joined(separator: "\n\n")
        return "WEBVTT\n\n" + cues + "\n"
    }

    static func markdown(_ transcript: Transcript, diarized: Bool) -> String {
        var lines = ["# 文字稿", ""]
        if diarized {
            for u in transcript.coalesced().utterances {
                if u.isMarker {
                    lines.append("## \(u.text)")
                    lines.append("")
                    continue
                }
                let label = u.speaker.map { "说话人\($0 + 1)" } ?? "未知"
                lines.append("**\(label)**（\(formatTimestamp(u.start))）：\(u.text)")
                lines.append("")
            }
        } else {
            for u in transcript.utterances {
                if u.isMarker {
                    lines.append(contentsOf: ["", "## \(u.text)", ""])
                    continue
                }
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
    static func exportWithPanel(
        _ transcript: Transcript,
        type: ExportFileType,
        showTimestamps: Bool,
        showSpeakers: Bool,
        suggestedName: String
    ) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = false
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = sanitizedFileName(suggestedName, type: type)
        panel.allowedContentTypes = [type.contentType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let outputURL = url.pathExtension.isEmpty
            ? url.appendingPathExtension(type.fileExtension)
            : url
        let data = exportData(
            transcript, type: type,
            showTimestamps: showTimestamps, showSpeakers: showSpeakers,
            title: suggestedName
        )
        do {
            try data.write(to: outputURL, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "导出失败"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    static func exportData(
        _ transcript: Transcript,
        type: ExportFileType,
        showTimestamps: Bool,
        showSpeakers: Bool,
        title: String
    ) -> Data {
        if type == .docx {
            return WordDocumentExporter.docxData(title: title, transcript: transcript, diarized: showSpeakers)
        }
        return Data(renderFile(
            transcript, type: type,
            showTimestamps: showTimestamps, showSpeakers: showSpeakers
        ).utf8)
    }

    private static func srtTime(_ seconds: Double) -> String {
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d,%03d", total / 3600, (total % 3600) / 60, total % 60, ms)
    }

    private static func vttTime(_ seconds: Double) -> String {
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d.%03d", total / 3600, (total % 3600) / 60, total % 60, ms)
    }

    /// 把标题转成安全的文件名主干（剔除 / \ : 等文件系统非法字符，再缩短）。
    /// 单条与批量导出共用，避免标题含 "/" 时写盘失败。
    static func safeFileStem(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.components(separatedBy: invalid).joined(separator: "_")
        return shortFileTitle(cleaned.trimmingCharacters(in: .whitespaces))
    }

    private static func sanitizedFileName(_ name: String, type: ExportFileType) -> String {
        safeFileStem(name) + ".\(type.fileExtension)"
    }

    private static func shortFileTitle(_ title: String) -> String {
        TitleFormatter.shortFileStem(title)
    }
}
