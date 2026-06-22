import Foundation
import WhisperKit

/// 隐藏 CLI 模式：./Video2Text --smoke a.m4a [b.m4a ...]
/// 多个文件按顺序拼接 PCM（用于模拟多说话人对话），转写并打印分段。
/// M2 起加 --diarize 标志验证说话人分离。
enum SmokeTest {
    static func run(arguments: [String]) async {
        do {
            try await runThrowing(arguments: arguments)
            exit(0)
        } catch {
            FileHandle.standardError.write("[smoke] 失败: \(error.localizedDescription)\n\(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    private static func runThrowing(arguments: [String]) async throws {
        AppPaths.ensureAll()
        var files: [String] = []
        var model = Transcriber.defaultModel
        var language: String? = "zh"
        var diarize = false

        var remoteURL: String?
        var it = arguments.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--model": model = it.next() ?? model
            case "--language":
                let value = it.next() ?? "zh"
                language = value == "auto" ? nil : value
            case "--diarize": diarize = true
            case "--words": break
            case "--simplify-text":
                print(TextNormalizer.simplifiedChinese(it.next() ?? ""))
                exit(0)
            case "--extract-url":
                print(LinkExtractor.bestEffortURLString(from: it.next() ?? ""))
                exit(0)
            case "--sample-docx":
                let path = it.next() ?? "/tmp/video2text-sample.docx"
                let sample = Transcript(utterances: [
                    Utterance(speaker: 0, start: 1, end: 3, text: "这是第一句话。"),
                    Utterance(speaker: 1, start: 4, end: 7, text: "这是第二句话。"),
                ], language: "zh", speakerCount: 2)
                let data = TranscriptExporter.exportData(
                    sample,
                    type: .docx,
                    showTimestamps: true,
                    showSpeakers: true,
                    title: "这是一个非常长的视频标题需要缩短"
                )
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                print(path)
                exit(0)
            case "--url":
                remoteURL = it.next().map { LinkExtractor.bestEffortURLString(from: $0) }
            default: files.append(arg)
            }
        }

        // --url：走应用内 Downloader（验证 yt-dlp 参数与 B 站两段式路径）
        if let remoteURL {
            let dir = AppPaths.downloads.appendingPathComponent("smoke")
            try? FileManager.default.removeItem(at: dir)
            print("[smoke] 下载 \(remoteURL) ...")
            let result = try await Downloader.download(
                url: remoteURL, destinationDir: dir,
                progress: { p in
                    let pct = Int(p * 100)
                    if pct % 25 == 0 { print("[smoke] 下载 \(pct)%") }
                }
            )
            print("[smoke] 标题: \(result.title)")
            print("[smoke] 文件: \(result.fileURL.path)")
            files.append(result.fileURL.path)
        }

        guard !files.isEmpty else {
            print("用法: Video2Text --smoke [--model 名称] [--language zh|en|auto] [--diarize] [--url 链接] [音频文件...]")
            exit(2)
        }

        // 1. 解码并拼接 PCM
        var audio: [Float] = []
        for file in files {
            let url = URL(fileURLWithPath: file)
            let pcm = try await AudioExtractor.pcm(from: url)
            print("[smoke] 解码 \(url.lastPathComponent): \(pcm.count) samples (\(String(format: "%.1f", Double(pcm.count) / AudioExtractor.sampleRate))s)")
            audio.append(contentsOf: pcm)
        }
        print("[smoke] 总时长 \(String(format: "%.1f", Double(audio.count) / AudioExtractor.sampleRate))s")

        // 2. 转写
        let transcriber = Transcriber()
        print("[smoke] 加载模型 \(model) ...")
        let loadStart = Date()
        try await transcriber.load(model: model, downloadProgress: { progress in
            let pct = Int(progress.fractionCompleted * 100)
            if pct % 10 == 0 { print("[smoke] 模型下载 \(pct)%") }
        })
        print("[smoke] 模型就绪，耗时 \(String(format: "%.1f", -loadStart.timeIntervalSinceNow))s")

        let start = Date()
        let results = try await transcriber.transcribe(audio, language: language)
        let elapsed = -start.timeIntervalSinceNow
        let audioSeconds = Double(audio.count) / AudioExtractor.sampleRate
        print("[smoke] 转写耗时 \(String(format: "%.1f", elapsed))s（\(String(format: "%.1f", audioSeconds / elapsed))x 实时）")

        let showWords = arguments.contains("--words")
        for result in results {
            print("[smoke] 语言: \(result.language)")
            for seg in result.segments {
                let words = seg.words?.count ?? 0
                print("  [\(formatTimestamp(Double(seg.start))) → \(formatTimestamp(Double(seg.end)))] (\(words) words) \(seg.text.trimmingCharacters(in: .whitespaces))")
                if showWords, let segWords = seg.words {
                    for w in segWords {
                        print("      \(String(format: "%6.2f-%6.2f", w.start, w.end)) \"\(w.word)\" p=\(String(format: "%.2f", w.probability))")
                    }
                }
            }
        }

        // 3. 说话人分离（M2）
        if diarize {
            let diarizer = Diarizer()
            print("[smoke] 加载说话人分离模型 ...")
            try await diarizer.load(downloadProgress: { progress in
                let pct = Int(progress.fractionCompleted * 100)
                if pct % 20 == 0 { print("[smoke] 分离模型下载 \(pct)%") }
            })
            let dStart = Date()
            let transcript = try await diarizer.diarizedTranscript(audio: audio, transcription: results)
            print("[smoke] 分离耗时 \(String(format: "%.1f", -dStart.timeIntervalSinceNow))s，说话人数: \(transcript.speakerCount ?? 0)")
            for u in transcript.coalesced().utterances {
                let label = u.speaker.map { "说话人\($0 + 1)" } ?? "未知"
                print("  [\(formatTimestamp(u.start)) → \(formatTimestamp(u.end))] \(label)：\(u.text)")
            }
        }
    }
}
