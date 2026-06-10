import Foundation
import SpeakerKit
import WhisperKit

/// SpeakerKit 封装：说话人分离 + 与转写结果合并为带说话人标签的 Transcript
actor Diarizer {
    private var speakerKit: SpeakerKit?

    func load(
        endpoint: String? = nil,
        downloadProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        if speakerKit != nil { return }
        let config = PyannoteConfig(
            downloadBase: AppPaths.models.path,
            modelEndpoint: endpoint ?? "https://huggingface.co",
            load: true,
            verbose: false,
            logLevel: .error
        )
        speakerKit = try await SpeakerKit(config)
    }

    /// 分离说话人并与 Whisper 转写合并。
    /// numberOfSpeakers 为 nil 时自动检测人数。
    func diarizedTranscript(
        audio: [Float],
        transcription: [TranscriptionResult],
        numberOfSpeakers: Int? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Transcript {
        guard let speakerKit else { throw DiarizerError.modelNotLoaded }

        let options = PyannoteDiarizationOptions(numberOfSpeakers: numberOfSpeakers)
        let result = try await speakerKit.diarize(
            audioArray: audio,
            options: options,
            progressCallback: progress.map { cb in
                { @Sendable p in cb(p.fractionCompleted) }
            }
        )

        let speakerSegments = result
            .addSpeakerInfo(to: transcription, strategy: .subsegment)
            .flatMap { $0 }
            .sorted { $0.startTime < $1.startTime }

        // 按首次发言顺序稳定编号：最先开口的是 说话人1
        var indexBySpeakerId: [Int: Int] = [:]
        var utterances: [Utterance] = []
        for seg in speakerSegments {
            let raw = seg.text.isEmpty ? (seg.transcription?.text ?? "") : seg.text
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            var speakerIndex: Int?
            if let sid = seg.speaker.speakerId {
                if indexBySpeakerId[sid] == nil {
                    indexBySpeakerId[sid] = indexBySpeakerId.count
                }
                speakerIndex = indexBySpeakerId[sid]
            }
            utterances.append(Utterance(
                speaker: speakerIndex,
                start: Double(seg.startTime),
                end: Double(seg.endTime),
                text: text
            ))
        }

        return Transcript(
            utterances: utterances,
            language: transcription.first?.language,
            speakerCount: max(indexBySpeakerId.count, result.speakerCount)
        )
    }

    func unload() {
        speakerKit = nil
    }
}

enum DiarizerError: LocalizedError {
    case modelNotLoaded
    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "说话人分离模型尚未加载"
        }
    }
}
