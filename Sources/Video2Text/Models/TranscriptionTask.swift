import Foundation

enum TaskSource: Hashable {
    case remote(String)
    case localFile(URL)

    var displayName: String {
        switch self {
        case let .remote(url): return url
        case let .localFile(url): return url.lastPathComponent
        }
    }
}

/// 文字稿来自哪里：平台字幕，或下载音频后 Whisper 转写
enum TranscriptSource: String, Codable, Hashable {
    case whisper
    case subtitles
}

enum TaskStage: Hashable {
    case queued
    case fetchingSubtitles
    case downloading(Double)
    case extracting
    case loadingModel(Double)
    case transcribing(Double)
    case diarizing(Double)
    case completed
    case failed(String)
    case cancelled

    var label: String {
        switch self {
        case .queued: return "排队中"
        case .fetchingSubtitles: return "获取字幕"
        case .downloading: return "下载音频"
        case .extracting: return "解码音频"
        case .loadingModel: return "加载模型"
        case .transcribing: return "转写中"
        case .diarizing: return "分离说话人"
        case .completed: return "完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    var progress: Double? {
        switch self {
        case let .downloading(p), let .loadingModel(p), let .transcribing(p), let .diarizing(p):
            return p
        default:
            return nil
        }
    }

    var percentText: String? {
        guard let progress else { return nil }
        let clamped = min(1, max(0, progress))
        return "\(Int((clamped * 100).rounded()))%"
    }

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

@MainActor
final class TranscriptionTask: ObservableObject, Identifiable {
    let id = UUID()
    let source: TaskSource
    let createdAt = Date()

    @Published var title: String
    @Published var stage: TaskStage = .queued
    /// 转写完成即填充（无说话人标签），说话人分离完成后被替换为带标签版本
    @Published var transcript: Transcript?
    @Published var diarized = false
    @Published var transcriptSource: TranscriptSource = .whisper

    /// 供 WhisperKit 回调提前终止用
    let cancelFlag = CancelFlag()

    init(source: TaskSource) {
        self.source = source
        self.title = source.displayName
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}
