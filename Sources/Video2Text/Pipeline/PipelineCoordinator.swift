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

            // 1. 拿到本地媒体文件
            let mediaURL = try await fetchMedia(for: task, into: taskDir, settings: settings)
            try Task.checkCancellation()

            // 2. 解码 PCM
            task.stage = .extracting
            let audio = try await AudioExtractor.pcm(from: mediaURL)
            guard !audio.isEmpty else { throw AudioExtractorError.noAudioTrack }
            try Task.checkCancellation()

            // 3. 加载模型（带下载进度）
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
            try Task.checkCancellation()

            // 4. 转写
            task.stage = .transcribing(0)
            let cancelFlag = task.cancelFlag
            let results = try await transcriber.transcribe(
                audio,
                language: settings.languageOrNil,
                cancelFlag: cancelFlag,
                progress: { fraction in
                    Task { @MainActor in
                        if case .transcribing = task.stage {
                            task.stage = .transcribing(fraction)
                        }
                    }
                }
            )
            try Task.checkCancellation()

            // 转写结果先展示（不带说话人）
            let plain = Self.transcript(from: results).simplifiedChinese()
            task.transcript = plain

            // 5. 说话人分离（失败不影响已有转写结果）
            if settings.diarizationEnabled {
                task.stage = .diarizing(0)
                do {
                    try await diarizer.load(
                        downloadProgress: { progress in
                            Task { @MainActor in
                                if case .diarizing = task.stage {
                                    task.stage = .diarizing(progress.fractionCompleted * 0.2)
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
                                    task.stage = .diarizing(0.2 + fraction * 0.8)
                                }
                            }
                        }
                    )
                    task.transcript = labeled.coalesced().simplifiedChinese()
                    task.diarized = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // 保留纯转写结果，仅记录分离失败
                    NSLog("说话人分离失败: \(error.localizedDescription)")
                }
            }

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
                destinationDir: taskDir.appendingPathComponent("subs")
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
    ) async throws -> URL {
        switch task.source {
        case let .localFile(url):
            return url

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
                return result.fileURL
            }

            let result = try await Downloader.download(
                url: urlString,
                cookiesFile: settings.cookiesURL,
                destinationDir: taskDir,
                progress: onProgress
            )
            task.title = result.title
            return result.fileURL
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
