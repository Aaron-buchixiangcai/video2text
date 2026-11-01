import Foundation

struct DownloadResult {
    let fileURL: URL
    let title: String
    /// B 站分P视频按顺序每P一个文件（含 fileURL 那一P）；单P视频为空
    var parts: [MediaPart] = []
}

struct MediaPart {
    /// 拼进文字稿的分P标题行，如「【P2】p02 Episode2 闷蒸」
    let label: String
    let fileURL: URL
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
        maxParts: Int = 1,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> DownloadResult {
        if isBilibili(url) {
            return try await downloadViaResolvedURL(
                url: url,
                referer: "https://www.bilibili.com/",
                cookiesFile: cookiesFile,
                destinationDir: destinationDir,
                maxParts: maxParts,
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

    /// yt-dlp 每个条目先打印一行「序号\t合集标题\t标题」，再打印一行直链
    private static let entryPrefix = "V2T-ENTRY\t"

    private static func downloadViaResolvedURL(
        url: String,
        referer: String,
        cookiesFile: URL?,
        destinationDir: URL,
        maxParts: Int,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> DownloadResult {
        guard let ytDlp = YtDlpManager.locate() else { throw YtDlpError.notInstalled }

        // 不加 --no-playlist：yt-dlp 把多P视频当播放列表展开（链接带 ?p=N 时只取那一P），
        // 与 BBDown 的 -p 1-N 相同，只取前 maxParts P
        var args = [
            "-f", "ba[ext=m4a]/ba/b",
            "--playlist-items", "1:\(max(maxParts, 1))",
            "--user-agent", plainUA,
            "--print", "\(entryPrefix)%(playlist_index)s\t%(playlist_title)s\t%(title)s",
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

        var entries: [(fields: [String], mediaURL: URL)] = []
        var pending: [String]?
        for line in result.stdout.components(separatedBy: .newlines) {
            if line.hasPrefix(entryPrefix) {
                // 单P视频没有播放列表字段，yt-dlp 打印 NA
                pending = line.dropFirst(entryPrefix.count).components(separatedBy: "\t")
                    .map { $0 == "NA" ? "" : $0 }
            } else if let fields = pending, fields.count >= 3,
                      let mediaURL = URL(string: line.trimmingCharacters(in: .whitespaces)),
                      mediaURL.scheme?.hasPrefix("http") == true {
                entries.append((fields, mediaURL))
                pending = nil
            }
        }
        guard let first = entries.first else { throw DownloaderError.outputMissing }

        var parts: [MediaPart] = []
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            var request = URLRequest(url: entry.mediaURL)
            request.setValue(browserUA, forHTTPHeaderField: "User-Agent")
            request.setValue(referer, forHTTPHeaderField: "Referer")
            // 镜像节点 upos-sz-mirrorcosov 对不带 Range 的请求返回 HTTP 567
            // （Bilibili-Evolved #5857、yt-dlp #17847），带上整段 Range 后返回 206
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            let count = Double(entries.count)
            let fileURL = try await fetch(
                request: request,
                // CDN 常给 .m4s 等扩展名，AVURLAsset 不认；统一存成 .mp4
                to: destinationDir.appendingPathComponent("audio-\(index + 1).mp4"),
                progress: { progress?((Double(index) + $0) / count) }
            )
            parts.append(MediaPart(label: partLabel(entry.fields), fileURL: fileURL))
        }

        let playlistTitle = first.fields[1]
        let title = entries.count > 1 && !playlistTitle.isEmpty ? playlistTitle : first.fields[2]
        return DownloadResult(
            fileURL: parts[0].fileURL,
            title: title,
            parts: parts.count > 1 ? parts : []
        )
    }

    /// 「【P2】p02 Episode2 闷蒸」：yt-dlp 的分P标题是「合集标题 p02 分P名」，去掉重复的合集标题。
    /// 只取前几P时 yt-dlp 不给合集总P数，所以不标总数
    private static func partLabel(_ fields: [String]) -> String {
        let (index, playlistTitle) = (fields[0], fields[1])
        var title = fields[2]
        if !playlistTitle.isEmpty, title.hasPrefix(playlistTitle) {
            title = String(title.dropFirst(playlistTitle.count)).trimmingCharacters(in: .whitespaces)
        }
        return "【P\(index)】\(title)"
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
