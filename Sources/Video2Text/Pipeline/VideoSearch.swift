import Foundation

enum SearchPlatform: String, CaseIterable, Identifiable {
    case youtube = "YouTube"
    case bilibili = "B站"

    var id: String { rawValue }

    var supportedSorts: [SearchSort] {
        switch self {
        case .youtube: return [.relevance, .views]
        case .bilibili: return SearchSort.allCases
        }
    }
}

enum SearchSort: String, CaseIterable, Identifiable {
    case relevance = "综合"
    case views = "最多播放"
    case newest = "最新发布"

    var id: String { rawValue }
}

struct SearchResult: Identifiable, Hashable {
    let id: String
    let url: String
    let title: String?
    let duration: Double?
    let uploader: String?
    let viewCount: Int?

    /// 兜底：没拿到标题时显示编号，标题在下载时由 yt-dlp 补上
    var displayTitle: String { title ?? "视频 \(id)" }

    /// 163 万次播放 / 2.6 亿次播放
    var viewCountText: String? {
        guard let viewCount else { return nil }
        let value = Double(viewCount)
        if value >= 1e8 { return String(format: "%.1f 亿次播放", value / 1e8) }
        if value >= 1e4 { return String(format: "%.1f 万次播放", value / 1e4) }
        return "\(viewCount) 次播放"
    }
}

enum VideoSearchError: LocalizedError {
    case rateLimited
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "B站暂时限制了搜索（HTTP 412），请过几分钟再试。短时间内搜索次数越多，限制越久。"
        case let .failed(reason):
            return "搜索失败：\(reason)"
        }
    }
}

/// 用 yt-dlp 的站内搜索（--flat-playlist 只发一次请求，不逐条解析视频）
enum VideoSearch {
    static func search(
        keyword: String,
        platform: SearchPlatform,
        count: Int,
        sort: SearchSort = .relevance,
        onRetry: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [SearchResult] {
        guard let ytDlp = YtDlpManager.locate() else { throw YtDlpError.notInstalled }
        var args = ["--ignore-config", "--no-warnings", "--flat-playlist", "-J"]
        switch platform {
        case .youtube:
            if sort == .views {
                // yt-dlp 没有按播放量搜索的前缀，改用带排序参数的搜索页（sp=CAM= 即按观看次数）。
                // 按上传日期的 sp=CAI= 实测已不生效，所以 YouTube 不提供「最新发布」
                let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                let query = keyword.addingPercentEncoding(withAllowedCharacters: unreserved) ?? keyword
                args.append(contentsOf: [
                    "--playlist-end", "\(count)",
                    "--", "https://www.youtube.com/results?search_query=\(query)&sp=CAM%3D",
                ])
            } else {
                args.append(contentsOf: ["--", "ytsearch\(count):\(keyword)"])
            }
        case .bilibili:
            let key: String
            switch sort {
            case .relevance: key = "bilisortrank"
            case .views: key = "bilisortclick"
            case .newest: key = "bilisortpubdate"
            }
            args.append(contentsOf: [
                "--plugin-dirs", try YtDlpPlugins.ensureInstalled().path,
                "--user-agent", Downloader.plainUA,
                "--", "\(key)\(count):\(keyword)",
            ])
        }

        // B 站限流（412）时等一会儿再试；等待时间逐次加长
        let waits: [UInt64] = [20, 40]
        for attempt in 0...waits.count {
            let result = try await ProcessRunner.run(ytDlp, arguments: args, timeout: 120)
            var results = parse(result.stdout)
            if platform == .bilibili {
                // B 站搜索会混进课堂付费课程（/cheese/）等非普通视频，下载必然失败
                results = results.filter { $0.url.contains("/video/") }
            }
            if !results.isEmpty { return results }

            let errorLine = result.stderr
                .components(separatedBy: .newlines)
                .last { $0.hasPrefix("ERROR") }
            guard let errorLine else { return [] }
            guard errorLine.contains("412") else { throw VideoSearchError.failed(errorLine) }
            guard attempt < waits.count else { break }
            onRetry?(Int(waits[attempt]))
            try await Task.sleep(nanoseconds: waits[attempt] * 1_000_000_000)
        }
        throw VideoSearchError.rateLimited
    }

    private static func parse(_ stdout: String) -> [SearchResult] {
        guard let data = stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [Any] else { return [] }
        return entries.compactMap { item in
            guard let entry = item as? [String: Any],
                  let id = entry["id"] as? String else { return nil }
            var url = (entry["url"] as? String) ?? (entry["webpage_url"] as? String) ?? ""
            if !url.hasPrefix("http") {
                // YouTube 扁平结果的 url 有时只是视频 id
                url = "https://www.youtube.com/watch?v=\(id)"
            }
            return SearchResult(
                id: id,
                url: url,
                title: entry["title"] as? String,
                duration: (entry["duration"] as? NSNumber)?.doubleValue,
                uploader: (entry["channel"] as? String) ?? (entry["uploader"] as? String),
                viewCount: (entry["view_count"] as? NSNumber)?.intValue
            )
        }
    }
}
