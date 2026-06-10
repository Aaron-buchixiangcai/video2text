import Foundation
import WhisperKit

/// WhisperKit 封装：实例只活在本 actor 内，不跨界共享
actor Transcriber {
    static let defaultModel = "openai_whisper-large-v3-v20240930_626MB"

    private var whisperKit: WhisperKit?
    private(set) var loadedModel: String?

    /// 加载（必要时先下载）模型
    func load(
        model: String,
        endpoint: String? = nil,
        downloadProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        if whisperKit != nil, loadedModel == model { return }
        whisperKit = nil
        loadedModel = nil

        // 先显式下载（带进度），WhisperKit init 内再走一次会命中本地缓存
        _ = try await WhisperKit.download(
            variant: model,
            downloadBase: AppPaths.models,
            endpoint: endpoint ?? "https://huggingface.co",
            progressCallback: downloadProgress
        )

        let config = WhisperKitConfig(
            model: model,
            downloadBase: AppPaths.models,
            modelEndpoint: endpoint,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        whisperKit = try await WhisperKit(config)
        loadedModel = model
    }

    /// language: "zh"/"en"/nil(自动检测)；cancelFlag 置位后尽快提前终止
    func transcribe(
        _ audio: [Float],
        language: String?,
        cancelFlag: CancelFlag? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [TranscriptionResult] {
        guard let whisperKit else { throw TranscriberError.modelNotLoaded }

        let totalSeconds = Double(audio.count) / AudioExtractor.sampleRate
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            detectLanguage: language == nil ? true : nil,
            skipSpecialTokens: true,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        let tokenCallback: TranscriptionCallback = { _ in
            cancelFlag?.isCancelled == true ? false : nil
        }
        let segmentCallback: SegmentDiscoveryCallback = { segments in
            if let progress, let last = segments.last, totalSeconds > 0 {
                progress(min(1.0, Double(last.end) / totalSeconds))
            }
        }
        return try await whisperKit.transcribe(
            audioArray: audio,
            decodeOptions: options,
            callback: tokenCallback,
            segmentCallback: segmentCallback
        )
    }

    func unload() {
        whisperKit = nil
        loadedModel = nil
    }
}

enum TranscriberError: LocalizedError {
    case modelNotLoaded
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "语音识别模型尚未加载"
        }
    }
}
