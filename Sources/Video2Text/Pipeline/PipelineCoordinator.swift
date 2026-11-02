import Foundation
import WhisperKit

/// 串联 下载 → 解码 → 转写 → 说话人分离 的总调度。
/// 任务串行执行（转写/分离都吃 ANE/GPU，串行内存可控）。
@MainActor
final class PipelineCoordinator: ObservableObject {
    private let transcriber = Transcriber()
    private let diarizer = Diarizer()
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var queueTail: Task<Void, Never>?

    var historyStore: HistoryStore?

    /// 直链媒体扩展名（绕过 yt-dlp 用 URLSession 直接下）
    private static let directMediaExtensions: Set<String> = [
        "mp4", "m4a", "m4v", "mov", "mp3", "wav", "aac", "aiff", "caf", "flac",
    ]

    func enqueue(_ task: TranscriptionTask, settings: AppSettings) {
        let previous = queueTail
        let job = Task { [weak self] in
            _ = await previous?.value
            guard let self, !task.cancelFlag.isCancelled else { return }
            await self.process(task, settings: settings)
        }
        queueTail = job
        runningTasks[task.id] = job
    }

    /// 等到当前已排队的任务全部结束（之后再排队的不等）
    func waitForQueue() async {
        await queueTail?.value
    }

    func cancel(_ task: TranscriptionTask) {
        task.cancelFlag.cancel()
        runningTasks[task.id]?.cancel()
        runningTasks[task.id] = nil
        if !task.stage.isFinished {
            task.stage = .cancelled
        }
    }

    private func process(_ task: TranscriptionTask, settings: AppSettings) async {
        let taskDir = AppPaths.downloads.appendingPathComponent(task.id.uuidString)
        defer {
            runningTasks[task.id] = nil
            try? FileManager.default.removeItem(at: taskDir)
        }

        do {
            // 0. 有平台字幕就直接用，跳过下载和转写（B 站需配置 cookies 才有 AI 字幕）
            if try await useSubtitlesIfAvailable(for: task, into: taskDir, settings: settings) {
                return
            }

            // 1. 拿到本地媒体文件（B 站分P视频每P一个）
            let (parts, warning) = try await fetchMedia(for: task, into: taskDir, settings: settings)
            try Task.checkCancellation()
            // 分P视频（哪怕只剩一P能下）每P开头标标题
            let showMarkers = parts.contains { !$0.label.isEmpty }

            // 2–5 逐P做：内存只取决于最长的一P；每P的时间从 00:00 起算，与该P视频的进度一致；
            // 说话人在每P内单独编号
            let partCount = Double(parts.count)
            var finished: [Utterance] = warning.map { [Utterance.partMarker("【提示】\($0)")] } ?? []
            var language: String?
            var speakerCount: Int?
            var modelLoaded = false
            var transcribedAny = false
            var lastPartError: Error?
            for (index, part) in parts.enumerated() {
                let marker = showMarkers ? [Utterance.partMarker(part.label)] : []
                let overall: @Sendable (Double) -> Double = { (Double(index) + $0) / partCount }
                /// 多P里某一P解码或转写失败时只留标题并注明原因，继续下一P，已完成的P不丢
                func skipFailedPart(_ error: Error) throws {
                    if error is CancellationError || task.cancelFlag.isCancelled || parts.count == 1 { throw error }
                    NSLog("第 \(index + 1) P 处理失败: \(error.localizedDescription)")
                    lastPartError = error
                    finished.append(.partMarker("\(part.label)（这一P处理失败：\(error.localizedDescription)）"))
                }

                // 2. 解码 PCM
                task.stage = .extracting
                let audio: [Float]
                do {
                    audio = try await AudioExtractor.pcm(from: part.fileURL)
                    try Task.checkCancellation()
                    guard !audio.isEmpty else { throw AudioExtractorError.noAudioTrack }
                } catch {
                    try skipFailedPart(error)
                    continue
                }

                // 3. 加载模型（带下载进度）
                if !modelLoaded {
                    task.stage = .loadingModel(0)
                    try await transcriber.load(
                        model: settings.model,
                        downloadProgress: { progress in
                            Task { @MainActor in
                                if case .loadingModel = task.stage {
                                    task.stage = .loadingModel(progress.fractionCompleted)
                                }
                            }
                        }
                    )
                    modelLoaded = true
                    try Task.checkCancellation()
                }

                // 4. 转写
                task.stage = .transcribing(overall(0))
                let cancelFlag = task.cancelFlag
                let results: [TranscriptionResult]
                do {
                    results = try await transcriber.transcribe(
                        audio,
                        language: settings.languageOrNil,
                        cancelFlag: cancelFlag,
                        progress: { fraction in
                            Task { @MainActor in
                                if case .transcribing = task.stage {
                                    task.stage = .transcribing(overall(fraction))
                                }
                            }
                        }
                    )
                    try Task.checkCancellation()
                } catch {
                    try skipFailedPart(error)
                    continue
                }
                transcribedAny = true
                language = language ?? results.first?.language

                // 转写结果先展示（不带说话人）
                let plain = Self.transcript(from: results).simplifiedChinese()
                var partUtterances = plain.utterances
                task.transcript = Transcript(
                    utterances: finished + marker + partUtterances, language: language, speakerCount: speakerCount
                )

                // 5. 说话人分离（失败不影响已有转写结果）
                if settings.diarizationEnabled {
                    task.stage = .diarizing(overall(0))
                    do {
                        try await diarizer.load(
                            downloadProgress: { progress in
                                Task { @MainActor in
                                    if case .diarizing = task.stage {
                                        task.stage = .diarizing(overall(progress.fractionCompleted * 0.2))
                                    }
                                }
                            }
                        )
                        let labeled = try await diarizer.diarizedTranscript(
                            audio: audio,
                            transcription: results,
                            progress: { fraction in
                                Task { @MainActor in
                                    if case .diarizing = task.stage {
                                        task.stage = .diarizing(overall(0.2 + fraction * 0.8))
                                    }
                                }
                            }
                        )
                        let merged = labeled.coalesced().simplifiedChinese()
                        partUtterances = merged.utterances
                        speakerCount = max(speakerCount ?? 0, merged.speakerCount ?? 0)
                        task.diarized = true
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // 保留纯转写结果，仅记录分离失败
                        NSLog("说话人分离失败: \(error.localizedDescription)")
                    }
                }
                finished += marker + partUtterances
                task.transcript = Transcript(utterances: finished, language: language, speakerCount: speakerCount)
            }
            guard transcribedAny else { throw lastPartError ?? AudioExtractorError.noAudioTrack }
            // 末尾失败或无声的P的标题行也要进最终文字稿
            task.transcript = Transcript(utterances: finished, language: language, speakerCount: speakerCount)

            try Task.checkCancellation()
            task.stage = .completed
            historyStore?.save(task: task)
        } catch is CancellationError {
            task.stage = .cancelled
        } catch {
            if task.cancelFlag.isCancelled {
                task.stage = .cancelled
            } else {
                task.stage = .failed(error.localizedDescription)
            }
        }
    }

    /// 成功用上字幕返回 true；没有字幕或取字幕出错都返回 false，由调用方继续走转写
    private func useSubtitlesIfAvailable(
        for task: TranscriptionTask,
        into taskDir: URL,
        settings: AppSettings
    ) async throws -> Bool {
        guard settings.preferSubtitles,
              case let .remote(urlString) = task.source,
              SubtitleFetcher.isEligible(urlString, hasCookies: settings.cookiesURL != nil) else { return false }
        task.stage = .fetchingSubtitles
        let fetched: SubtitleFetcher.Result?
        do {
            fetched = try await SubtitleFetcher.fetch(
                url: urlString,
                cookiesFile: settings.cookiesURL,
                destinationDir: taskDir.appendingPathComponent("subs"),
                maxParts: settings.maxBilibiliParts
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("获取字幕失败，改用转写: \(error.localizedDescription)")
            return false
        }
        try Task.checkCancellation()
        guard let fetched else { return false }

        task.title = fetched.title
        task.transcript = fetched.transcript.simplifiedChinese()
        task.transcriptSource = .subtitles
        task.stage = .completed
        historyStore?.save(task: task)
        return true
    }

    private func fetchMedia(
        for task: TranscriptionTask,
        into taskDir: URL,
        settings: AppSettings
    ) async throws -> (parts: [MediaPart], warning: String?) {
        switch task.source {
        case let .localFile(url):
            return ([MediaPart(label: "", fileURL: url)], nil)

        case let .remote(urlString):
            task.stage = .downloading(0)
            let onProgress: @Sendable (Double) -> Void = { fraction in
                Task { @MainActor in
                    if case .downloading = task.stage {
                        task.stage = .downloading(fraction)
                    }
                }
            }

            if let url = URL(string: urlString),
               Self.directMediaExtensions.contains(url.pathExtension.lowercased()) {
                let result = try await Downloader.downloadDirect(
                    url: url, destinationDir: taskDir, progress: onProgress
                )
                task.title = result.title
                return ([MediaPart(label: "", fileURL: result.fileURL)], nil)
            }

            let result = try await Downloader.download(
                url: urlString,
                cookiesFile: settings.cookiesURL,
                destinationDir: taskDir,
                maxParts: settings.maxBilibiliParts,
                progress: onProgress
            )
            task.title = result.title
            return (result.parts.isEmpty ? [MediaPart(label: "", fileURL: result.fileURL)] : result.parts, result.warning)
        }
    }

    /// Whisper 分段 → 不带说话人的 Transcript
    static func transcript(from results: [TranscriptionResult]) -> Transcript {
        var utterances: [Utterance] = []
        for result in results {
            for seg in result.segments {
                let text = seg.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                utterances.append(Utterance(
                    speaker: nil,
                    start: Double(seg.start),
                    end: Double(seg.end),
                    text: text
                ))
            }
        }
        utterances.sort { $0.start < $1.start }
        return Transcript(
            utterances: utterances,
            language: results.first?.language,
            speakerCount: nil
        )
    }
}
