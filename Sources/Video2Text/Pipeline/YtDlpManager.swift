import Foundation

enum YtDlpError: LocalizedError {
    case notInstalled
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "yt-dlp 尚未安装"
        case let .downloadFailed(reason): return "yt-dlp 下载失败：\(reason)"
        }
    }
}

/// 管理 yt-dlp 独立二进制：定位 / 首次下载 / 自更新
enum YtDlpManager {
    static let releaseURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    /// 已安装的 yt-dlp 路径：优先应用自管目录，其次 Homebrew / PATH
    static func locate() -> URL? {
        let candidates = [
            AppPaths.ytDlp,
            URL(fileURLWithPath: "/opt/homebrew/bin/yt-dlp"),
            URL(fileURLWithPath: "/usr/local/bin/yt-dlp"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static var isInstalled: Bool { locate() != nil }

    /// 下载独立二进制到 App Support，赋执行权限并去掉 quarantine
    static func install(progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        AppPaths.ensureAll()
        let dest = AppPaths.ytDlp

        let (tempURL, response) = try await URLSession.shared.download(from: releaseURL, progress: progress)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw YtDlpError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tempURL, to: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        // 去掉 quarantine 属性，避免 Gatekeeper 拦截 Process 启动
        removexattr(dest.path, "com.apple.quarantine", 0)
        return dest
    }

    /// yt-dlp -U 自更新（仅对独立二进制有效）
    static func update() async throws -> String {
        guard let binary = locate() else { throw YtDlpError.notInstalled }
        let result = try await ProcessRunner.run(binary, arguments: ["-U"], timeout: 300)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func version() async -> String? {
        guard let binary = locate() else { return nil }
        let result = try? await ProcessRunner.run(binary, arguments: ["--version"], timeout: 30)
        return result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension URLSession {
    /// download(from:) 带进度回调的版本
    func download(from url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> (URL, URLResponse) {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try await downloadOnce(from: url, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < 3 else { break }
                progress?(0)
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
        throw lastError ?? YtDlpError.downloadFailed("网络连接中断")
    }

    private func downloadOnce(from url: URL, progress: (@Sendable (Double) -> Void)?) async throws -> (URL, URLResponse) {
        let (bytes, response) = try await bytes(from: url)
        let expected = response.expectedContentLength
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        defer { try? handle.close() }

        var data = Data(capacity: 1 << 16)
        var written: Int64 = 0
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 1 << 16 {
                try handle.write(contentsOf: data)
                written += Int64(data.count)
                data.removeAll(keepingCapacity: true)
                if expected > 0 { progress?(Double(written) / Double(expected)) }
            }
        }
        try handle.write(contentsOf: data)
        progress?(1.0)
        return (tempURL, response)
    }
}
