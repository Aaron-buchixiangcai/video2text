import AVFoundation
import Foundation

enum AudioExtractorError: LocalizedError {
    case noAudioTrack
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "文件中没有音轨"
        case let .readFailed(reason): return "音频解码失败：\(reason)"
        }
    }
}

/// 从任意 AVFoundation 可解码的容器（m4a/mp4/mov/...）抽出音轨，
/// 重采样为 16kHz 单声道 Float32 PCM —— WhisperKit / SpeakerKit 的统一输入。
enum AudioExtractor {
    static let sampleRate = 16_000.0

    static func pcm(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw AudioExtractorError.noAudioTrack }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)

        guard reader.startReading() else {
            throw AudioExtractorError.readFailed(reader.error?.localizedDescription ?? "无法开始读取")
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            let count = length / MemoryLayout<Float>.size
            let oldCount = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            samples.withUnsafeMutableBufferPointer { ptr in
                _ = CMBlockBufferCopyDataBytes(
                    blockBuffer, atOffset: 0, dataLength: length,
                    destination: ptr.baseAddress! + oldCount
                )
            }
        }

        if reader.status == .failed {
            throw AudioExtractorError.readFailed(reader.error?.localizedDescription ?? "未知错误")
        }
        return samples
    }
}
