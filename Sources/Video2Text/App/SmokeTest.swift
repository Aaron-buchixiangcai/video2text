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
        var downloadOnly = false
        var outputDir: URL?
        var outputTitle = "完整文字稿"
        var transcriptJSON: URL?

        var remoteURL: String?
        var maxParts = 1
        var searchSort = SearchSort.relevance
        var smokeCookies: URL?
        var it = arguments.makeIterator()
        while let arg = it.next() {
            switch arg {
            case "--model": model = it.next() ?? model
            case "--language":
                let value = it.next() ?? "zh"
                language = value == "auto" ? nil : value
            case "--diarize": diarize = true
            case "--download-only": downloadOnly = true
            case "--output-dir":
                outputDir = it.next().map { URL(fileURLWithPath: $0, isDirectory: true) }
            case "--output-title":
                outputTitle = it.next() ?? outputTitle
            case "--export-transcript-json":
                transcriptJSON = it.next().map { URL(fileURLWithPath: $0) }
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
            case "--max-parts":
                maxParts = Int(it.next() ?? "") ?? 1
            case "--canonical-bili":
                print(Downloader.canonicalBilibiliURL(it.next() ?? ""))
                exit(0)
            case "--extract-urls":
                LinkExtractor.allURLStrings(in: it.next() ?? "").forEach { print($0) }
                exit(0)
            case "--sort":
                // 写在 --search 前面：--sort views|newest|relevance
                switch it.next() {
                case "views": searchSort = .views
                case "newest": searchSort = .newest
                default: searchSort = .relevance
                }
            case "--search":
                // --search yt|bili 条数 关键词
                let platform: SearchPlatform = it.next() == "bili" ? .bilibili : .youtube
                let count = Int(it.next() ?? "") ?? 5
                let results = try await VideoSearch.search(
                    keyword: it.next() ?? "", platform: platform, count: count, sort: searchSort,
                    onRetry: { print("[smoke] 限流，\($0) 秒后重试") }
                )
                for r in results {
                    print("\(r.viewCountText ?? "-") | \(r.duration.map(formatTimestamp) ?? "-") | \(r.uploader ?? "-") | \(r.displayTitle) | \(r.url)")
                }
                exit(0)
            case "--cookies":
                // 写在 --subtitles 前面：--cookies cookies.txt 路径
                smokeCookies = it.next().map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            case "--subtitles":
                let url = it.next() ?? ""
                let dir = AppPaths.downloads.appendingPathComponent("smoke-subs-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: dir) }
                guard let fetched = try await SubtitleFetcher.fetch(url: url, cookiesFile: smokeCookies, destinationDir: dir) else {
                    print("[smoke] 没有可用字幕")
                    exit(0)
                }
                let text = TranscriptExporter.render(fetched.transcript.simplifiedChinese(), showTimestamps: true, showSpeakers: false)
                print("[smoke] \(fetched.title) | 语言 \(fetched.transcript.language ?? "-") | \(fetched.transcript.utterances.count) 段")
                print(String(text.prefix(800)))
                exit(0)
            case "--pipeline":
                // 走 App 内同一套流程（排队转写 → 每条总结 → 汇总），用当前设置，结果写进历史记录和汇总：
                // --pipeline 主题 链接1 链接2 ...
                let topic = it.next() ?? "冒烟测试"
                var urls: [String] = []
                while let next = it.next() { urls.append(next) }
                await runPipeline(topic: topic, urls: urls)
                exit(0)
            case "--summarize-latest":
                // 只打印，不写回历史记录：--summarize-latest [条数]，两条以上再打印汇总
                let count = Int(it.next() ?? "") ?? 1
                let records = await MainActor.run { HistoryStore().records }.prefix(count)
                var summaries: [(title: String, summary: String)] = []
                for record in records {
                    let summary = try await Summarizer.summarize(record)
                    summaries.append((record.title, summary))
                    print("===== \(record.title)\n\(summary)\n")
                }
                if summaries.count >= 2 {
                    print("===== 汇总\n" + (try await Summarizer.digest(topic: "冒烟测试", summaries: summaries)))
                }
                exit(0)
            default: files.append(arg)
            }
        }

        if let transcriptJSON {
            guard let outputDir else {
                throw CocoaError(.fileNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "--export-transcript-json 需要同时指定 --output-dir",
                ])
            }
            let data = try Data(contentsOf: transcriptJSON)
            let transcript = try JSONDecoder().decode(Transcript.self, from: data)
            try exportTranscript(
                transcript,
                to: outputDir,
                title: outputTitle,
                diarized: transcript.speakerCount != nil
            )
            exit(0)
        }

        // --url：走应用内 Downloader（验证 yt-dlp 参数与 B 站两段式路径）
        if let remoteURL {
            let dir = AppPaths.downloads.appendingPathComponent("smoke")
            try? FileManager.default.removeItem(at: dir)
            print("[smoke] 下载 \(remoteURL) ...")
            let result = try await Downloader.download(
                url: remoteURL, destinationDir: dir, maxParts: maxParts,
                progress: { p in
                    let pct = Int(p * 100)
                    if pct % 25 == 0 { print("[smoke] 下载 \(pct)%") }
                }
            )
            print("[smoke] 标题: \(result.title)")
            if result.parts.isEmpty {
                print("[smoke] 文件: \(result.fileURL.path)")
                files.append(result.fileURL.path)
            }
            for part in result.parts {
                print("[smoke] 分P: \(part.label) → \(part.fileURL.lastPathComponent)")
                files.append(part.fileURL.path)
            }
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
        if downloadOnly {
            print("[smoke] 下载与音频解码验证通过")
            exit(0)
        }

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
        var finalTranscript = transcript(from: results).simplifiedChinese()

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
            finalTranscript = transcript.coalesced().simplifiedChinese()
            print("[smoke] 分离耗时 \(String(format: "%.1f", -dStart.timeIntervalSinceNow))s，说话人数: \(transcript.speakerCount ?? 0)")
            for u in transcript.coalesced().utterances {
                let label = u.speaker.map { "说话人\($0 + 1)" } ?? "未知"
                print("  [\(formatTimestamp(u.start)) → \(formatTimestamp(u.end))] \(label)：\(u.text)")
            }
        }

        if let outputDir {
            try exportTranscript(
                finalTranscript,
                to: outputDir,
                title: outputTitle,
                diarized: diarize
            )
        }
    }

    @MainActor
    private static func runPipeline(topic: String, urls: [String]) async {
        // 直接运行可执行文件时没有 bundle，默认设置域不是 App 的，补上 App 的设置域
        if Bundle.main.bundleIdentifier == nil {
            UserDefaults.standard.addSuite(named: "com.haolinyu.video2text")
        }
        let settings = SettingsStore().settings
        let history = HistoryStore()
        let digests = DigestStore()
        let coordinator = PipelineCoordinator()
        coordinator.historyStore = history
        print("[smoke] 模型 \(settings.model)，分P上限 \(settings.maxBilibiliParts)，说话人分离 \(settings.diarizationEnabled)，优先字幕 \(settings.preferSubtitles)，cookies \(settings.cookiesURL?.path ?? "无")")

        let start = Date()
        let tasks = urls.map { TranscriptionTask(source: .remote($0)) }
        tasks.forEach { coordinator.enqueue($0, settings: settings) }
        await coordinator.waitForQueue()
        print("[smoke] 转写用时 \(Int(-start.timeIntervalSinceNow))s")
        for task in tasks {
            print("[smoke] \(task.stage) | \(task.transcriptSource) | \(task.title)")
            guard let transcript = task.transcript else { continue }
            let partLines = transcript.utterances.filter(\.isMarker)
            print("  \(transcript.utterances.count) 段，\(transcript.plainText.count) 字，分P标题 \(partLines.count) 行，说话人 \(transcript.speakerCount.map(String.init) ?? "-")")
            partLines.forEach { print("  \($0.text)") }
        }

        let completed = tasks.filter { $0.stage == .completed }.map(\.id)
        let summaryStart = Date()
        let digest = await BatchSummaryRunner().run(topic: topic, recordIDs: completed, history: history, digests: digests)
        print("[smoke] 总结用时 \(Int(-summaryStart.timeIntervalSinceNow))s")
        for id in completed {
            let record = history.records.first { $0.id == id }
            print("===== 总结：\(record?.title ?? "-")\n\(record?.summary ?? "（无）")\n")
        }
        print("===== 汇总\n\(digest?.content ?? "（未生成）")")
    }

    private static func exportTranscript(
        _ transcript: Transcript,
        to outputDir: URL,
        title: String,
        diarized: Bool
    ) throws {
        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )

        let exports: [(name: String, type: ExportFileType, timestamps: Bool)] = [
            ("完整文字稿.txt", .txt, false),
            ("带时间戳文字稿.md", .markdown, true),
            ("带时间戳文字稿.docx", .docx, true),
            ("字幕.srt", .srt, true),
        ]
        for item in exports {
            let data = TranscriptExporter.exportData(
                transcript,
                type: item.type,
                showTimestamps: item.timestamps,
                showSpeakers: diarized,
                title: title
            )
            let url = outputDir.appendingPathComponent(item.name)
            try data.write(to: url, options: .atomic)
            print("[smoke] 已导出: \(url.path)")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let jsonURL = outputDir.appendingPathComponent("结构化文字稿.json")
        try encoder.encode(transcript).write(to: jsonURL, options: .atomic)
        print("[smoke] 已导出: \(jsonURL.path)")
    }

    private static func transcript(from results: [TranscriptionResult]) -> Transcript {
        let utterances = results
            .flatMap(\.segments)
            .compactMap { segment -> Utterance? in
                let text = segment.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { return nil }
                return Utterance(
                    speaker: nil,
                    start: Double(segment.start),
                    end: Double(segment.end),
                    text: text
                )
            }
            .sorted { $0.start < $1.start }
        return Transcript(
            utterances: utterances,
            language: results.first?.language,
            speakerCount: nil
        )
    }
}
