import Foundation

/// 应用数据目录统一管理：~/Library/Application Support/Video2Text/
enum AppPaths {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Video2Text", isDirectory: true)
    }

    /// Whisper / SpeakerKit 模型下载根目录
    static var models: URL { root.appendingPathComponent("models", isDirectory: true) }
    /// yt-dlp 等外部二进制
    static var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    /// 历史记录 JSON
    static var history: URL { root.appendingPathComponent("history", isDirectory: true) }
    /// 下载中转目录（任务完成后清理）
    static var downloads: URL { root.appendingPathComponent("downloads", isDirectory: true) }
    /// 多条转写的汇总报告 JSON
    static var digests: URL { root.appendingPathComponent("digests", isDirectory: true) }

    static var ytDlp: URL { bin.appendingPathComponent("yt-dlp") }

    static func ensureAll() {
        for dir in [root, models, bin, history, downloads, digests] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
