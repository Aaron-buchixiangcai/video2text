import Foundation

struct DownloadResult {
    let fileURL: URL
    let title: String
}

enum DownloaderError: LocalizedError {
    case ytDlpFailed(exitCode: Int32, stderr: String)
    case outputMissing
    case directDownloadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .ytDlpFailed(code, stderr):
            let hint = Self.hint(for: stderr)
            return "视频下载失败（yt-dlp 退出码 \(code)）\(hint)\n\(stderr.suffix(400))"
        case .outputMissing:
            return "yt-dlp 执行完成但找不到输出文件"
        case let .directDownloadFailed(reason):
            return "音频下载失败：\(reason)"
        }
    }

    private static func hint(for stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("fresh cookies") || lower.contains("cookies") {
            return "。自动验证未通过；请确认已安装 Google Chrome 后重试。只有登录可见视频才需要在高级设置中指定 cookies.txt"
        }
        if lower.contains("412") {
            return "。可能被平台风控拦截，请稍后重试；只有登录可见视频才需要在高级设置中指定 cookies.txt"
        }
        if lower.contains("unsupported url") {
            return "。该链接不被 yt-dlp 支持，可尝试在浏览器下载后把视频文件拖入本应用"
        }
        if lower.contains("no video") || lower.contains("requested format") || lower.contains("no formats") {
            return "。该笔记可能是图文笔记（无视频可转写）；若是视频请确认链接有效或在设置中配置 cookies"
        }
        return ""
    }
}

/// 用 yt-dlp 下载视频的音频轨：优先 m4a/mp4（AVFoundation 可直接解码，无需 ffmpeg）
enum Downloader {
    static let browserUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
    /// B 站 API 层会对「Mozilla 系 UA + Referer」组合返回 412，必须用非浏览器 UA 调 API；
    /// 而 CDN 层又要求浏览器 UA + Referer。所以 B 站走两段式下载。
    static let plainUA = "v2t-downloader/1.0"

    /// 进度行形如 "[download]  42.3% of 10.00MiB at ..."
    private static let progressRegex = try! NSRegularExpression(pattern: #"\[download\]\s+(\d+(?:\.\d+)?)%"#)
    private static let printPrefix = "V2T-RESULT|"

    static func download(
        url: String,
        cookiesFile: URL? = nil,
        destinationDir: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> DownloadResult {
        if isBilibili(url) {
            return try await downloadViaResolvedURL(
                url: url,
                referer: "https://www.bilibili.com/",
                cookiesFile: cookiesFile,
                destinationDir: destinationDir,
                progress: progress
            )
        }
        if isDouyin(url) {
            if let cookiesFile {
                do {
                    return try await downloadWithYtDlp(
                        url: url,
                        cookiesFile: cookiesFile,
                        destinationDir: destinationDir,
                        progress: progress
                    )
                } catch let error as DownloaderError {
                    guard isFreshCookiesFailure(error) else { throw error }
                    try Task.checkCancellation()
                }
            }
            return try await downloadDouyinWithIsolatedBrowser(
                url: url,
                destinationDir: destinationDir,
                progress: progress
            )
        }
        return try await downloadWithYtDlp(
            url: url, cookiesFile: cookiesFile,
            destinationDir: destinationDir, progress: progress
        )
    }

    private static func isBilibili(_ url: String) -> Bool {
        url.contains("bilibili.com") || url.contains("b23.tv")
    }

    private static func isDouyin(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        return host == "douyin.com"
            || host.hasSuffix(".douyin.com")
            || host == "iesdouyin.com"
            || host.hasSuffix(".iesdouyin.com")
    }

    private static func isFreshCookiesFailure(_ error: DownloaderError) -> Bool {
        guard case let .ytDlpFailed(_, stderr) = error else { return false }
        return stderr.lowercased().contains("fresh cookies")
    }

    private static func downloadDouyinWithIsolatedBrowser(
        url: String,
        destinationDir: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> DownloadResult {
        let maximumAttempts = 3
        var lastFreshCookiesError: DownloaderError?

        for attempt in 1...maximumAttempts {
            try Task.checkCancellation()
            let profileDir = try await DouyinBrowserSession.prepare(
                url: url,
                destinationDir: destinationDir
            )
            do {
                try Task.checkCancellation()
                let result = try await downloadWithYtDlp(
                    url: url,
                    cookiesFile: nil,
                    browserCookiesProfile: profileDir,
                    destinationDir: destinationDir,
                    progress: progress
                )
                await DouyinBrowserSession.remove(profileDir)
                return result
            } catch {
                await DouyinBrowserSession.remove(profileDir)
                if let downloaderError = error as? DownloaderError,
                   isFreshCookiesFailure(downloaderError),
                   attempt < maximumAttempts {
                    lastFreshCookiesError = downloaderError
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
                    continue
                }
                throw error
            }
        }

        throw lastFreshCookiesError ?? DownloaderError.outputMissing
    }

    // MARK: - 标准路径：yt-dlp 直接下载

    private static func downloadWithYtDlp(
        url: String,
        cookiesFile: URL?,
        browserCookiesProfile: URL? = nil,
        destinationDir: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> DownloadResult {
        guard let ytDlp = YtDlpManager.locate() else { throw YtDlpError.notInstalled }
        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)

        var args = [
            "-f", "ba[ext=m4a]/b[ext=mp4]/ba/b",
            "--no-playlist",
            "--retries", "10",
            "--fragment-retries", "10",
            "--newline",
            "--no-colors",
            "--progress",
            "--no-simulate",
            "--print", "after_move:\(printPrefix)%(title)s|%(filepath)s",
            "-o", "%(id)s.%(ext)s",
            "-P", destinationDir.path,
        ]
        if let cookiesFile {
            args.append(contentsOf: ["--cookies", cookiesFile.path])
        }
        if let browserCookiesProfile {
            args.append(contentsOf: [
                "--cookies-from-browser",
                DouyinBrowserSession.browserSpec(for: browserCookiesProfile),
            ])
        }
        args.append(contentsOf: ["--", url])

        let resultLine = ResultLineBox()
        let result = try await ProcessRunner.run(ytDlp, arguments: args, timeout: 3600) { line in
            if line.hasPrefix(printPrefix) {
                resultLine.set(String(line.dropFirst(printPrefix.count)))
            } else if let match = progressRegex.firstMatch(
                in: line, range: NSRange(line.startIndex..., in: line)
            ), let range = Range(match.range(at: 1), in: line), let pct = Double(line[range]) {
                progress?(pct / 100.0)
            }
        }

        guard result.exitCode == 0 else {
            throw DownloaderError.ytDlpFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        guard let line = resultLine.get(),
              let sepIndex = line.lastIndex(of: "|") else {
            throw DownloaderError.outputMissing
        }
        let title = String(line[..<sepIndex])
        let path = String(line[line.index(after: sepIndex)...])
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw DownloaderError.outputMissing
        }
        return DownloadResult(fileURL: fileURL, title: title)
    }

    // MARK: - 两段式路径：yt-dlp 仅解析直链，URLSession 带浏览器头下载

    private static func downloadViaResolvedURL(
        url: String,
        referer: String,
        cookiesFile: URL?,
        destinationDir: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> DownloadResult {
        guard let ytDlp = YtDlpManager.locate() else { throw YtDlpError.notInstalled }

        var args = [
            "-f", "ba[ext=m4a]/ba/b",
            "--no-playlist",
            "--user-agent", plainUA,
            "--print", "%(title)s",
            "--print", "urls",
        ]
        if let cookiesFile {
            args.append(contentsOf: ["--cookies", cookiesFile.path])
        }
        args.append(contentsOf: ["--", url])

        let result = try await ProcessRunner.run(ytDlp, arguments: args, timeout: 300)
        guard result.exitCode == 0 else {
            throw DownloaderError.ytDlpFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        let lines = result.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2,
              let mediaURL = URL(string: lines[lines.count - 1]) else {
            throw DownloaderError.outputMissing
        }
        let title = lines.dropLast().joined(separator: " ")

        var request = URLRequest(url: mediaURL)
        request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let fileURL = try await fetch(
            request: request,
            // CDN 常给 .m4s 等扩展名，AVURLAsset 不认；统一存成 .mp4
            to: destinationDir.appendingPathComponent("audio.mp4"),
            progress: progress
        )
        return DownloadResult(fileURL: fileURL, title: title)
    }

    /// 直链（.mp4/.m4a 等）绕过 yt-dlp 直接下载
    static func downloadDirect(
        url: URL,
        destinationDir: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> DownloadResult {
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let fileURL = try await fetch(
            request: URLRequest(url: url),
            to: destinationDir.appendingPathComponent("video.\(ext)"),
            progress: progress
        )
        let title = url.lastPathComponent.isEmpty ? "视频" : url.lastPathComponent
        return DownloadResult(fileURL: fileURL, title: title)
    }

    private static func fetch(
        request: URLRequest,
        to dest: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try await fetchOnce(request: request, to: dest, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: dest)
                guard attempt < 3 else { break }
                progress?(0)
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
        throw lastError ?? DownloaderError.directDownloadFailed("网络连接中断")
    }

    private static func fetchOnce(
        request: URLRequest,
        to dest: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DownloaderError.directDownloadFailed(
                "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
        }

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }

        let expected = response.expectedContentLength
        var chunk = Data(capacity: 1 << 16)
        var written: Int64 = 0
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 1 << 16 {
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                chunk.removeAll(keepingCapacity: true)
                if expected > 0 { progress?(Double(written) / Double(expected)) }
            }
        }
        try handle.write(contentsOf: chunk)
        progress?(1.0)
        return dest
    }
}

private final class ResultLineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}
