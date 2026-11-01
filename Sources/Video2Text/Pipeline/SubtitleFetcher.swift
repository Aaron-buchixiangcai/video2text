import Foundation

/// 取平台自带字幕，省掉下载音频和转写。
/// YouTube 总是尝试；B 站的 AI 字幕要登录才拿得到，所以只在配置了 cookies.txt 时尝试。
/// 分P视频这里只取第 1P 的字幕（--no-playlist），多P一起转要走音频下载。
enum SubtitleFetcher {
    struct Result {
        let title: String
        let transcript: Transcript
    }

    static func isEligible(_ url: String, hasCookies: Bool) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") { return true }
        return hasCookies && isBilibili(host)
    }

    private static func isBilibili(_ host: String) -> Bool {
        host == "bilibili.com" || host.hasSuffix(".bilibili.com") || host == "b23.tv"
    }

    /// 没有合适字幕时返回 nil，调用方改走音频转写
    static func fetch(url: String, cookiesFile: URL?, destinationDir: URL) async throws -> Result? {
        guard let ytDlp = YtDlpManager.locate() else { return nil }
        var base = ["--ignore-config", "--no-warnings", "--no-playlist"]
        if let cookiesFile {
            base.append(contentsOf: ["--cookies", cookiesFile.path])
        }
        if let host = URL(string: url)?.host?.lowercased(), isBilibili(host) {
            // 与 Downloader 一致：B 站 API 层要用非浏览器 UA
            base.append(contentsOf: ["--user-agent", Downloader.plainUA])
        }

        let info = try await ProcessRunner.run(ytDlp, arguments: base + ["-J", "--", url], timeout: 120)
        guard info.exitCode == 0,
              let data = info.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let track = pickTrack(json) else { return nil }

        try FileManager.default.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        let args = base + [
            "--skip-download",
            track.automatic ? "--write-auto-subs" : "--write-subs",
            "--sub-langs", NSRegularExpression.escapedPattern(for: track.key),
            "--sub-format", "json3/srt/vtt/best",
            "-o", "subs.%(ext)s",
            "-P", destinationDir.path,
            "--", url,
        ]
        let result = try await ProcessRunner.run(ytDlp, arguments: args, timeout: 120)
        guard result.exitCode == 0 else { return nil }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: destinationDir, includingPropertiesForKeys: nil
        )) ?? []
        guard let file = files.first(where: {
            $0.lastPathComponent.hasPrefix("subs.") && ["json3", "srt", "vtt"].contains($0.pathExtension)
        }), let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        let utterances = file.pathExtension == "json3" ? parseJSON3(raw) : parseSRTOrVTT(raw)
        // 过短多半是只有音乐标注之类，不如转写
        guard utterances.map(\.text).joined().count >= 50 else { return nil }
        return Result(
            title: (json["title"] as? String) ?? url,
            transcript: Transcript(
                utterances: utterances,
                language: track.key.components(separatedBy: "-").first,
                speakerCount: nil
            )
        )
    }

    /// 优先人工字幕；没有则用视频原语言的自动字幕（键名以 -orig 结尾），不用机翻字幕
    private static func pickTrack(_ json: [String: Any]) -> (key: String, automatic: Bool)? {
        let language = ((json["language"] as? String) ?? "").components(separatedBy: "-").first?.lowercased() ?? ""
        func base(_ key: String) -> String { key.components(separatedBy: "-").first?.lowercased() ?? key }

        // live_chat 是 YouTube 直播聊天，danmaku 是 B 站弹幕，都不是字幕
        let manual = ((json["subtitles"] as? [String: Any]) ?? [:]).keys
            .filter { $0 != "live_chat" && $0 != "danmaku" }
            .sorted()
        if !manual.isEmpty {
            for preferred in [language, "zh", "en"] where !preferred.isEmpty {
                if let key = manual.first(where: { base($0) == preferred }) { return (key, false) }
            }
            return (manual[0], false)
        }

        let originals = ((json["automatic_captions"] as? [String: Any]) ?? [:]).keys
            .filter { $0.hasSuffix("-orig") }
            .sorted()
        if let key = originals.first(where: { !language.isEmpty && base($0) == language }) {
            return (key, true)
        }
        return originals.count == 1 ? (originals[0], true) : nil
    }

    private static func parseJSON3(_ raw: String) -> [Utterance] {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else { return [] }
        var cues: [Utterance] = []
        for event in events {
            guard let segs = event["segs"] as? [[String: Any]] else { continue }
            let text = segs.compactMap { $0["utf8"] as? String }.joined()
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let start = ((event["tStartMs"] as? Double) ?? 0) / 1000
            let duration = ((event["dDurationMs"] as? Double) ?? 0) / 1000
            cues.append(Utterance(speaker: nil, start: start, end: start + duration, text: text))
        }
        return dedupRolling(cues)
    }

    private static func parseSRTOrVTT(_ raw: String) -> [Utterance] {
        var cues: [Utterance] = []
        let blocks = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[timeIndex].components(separatedBy: "-->")
            guard times.count == 2 else { continue }
            let text = lines[(timeIndex + 1)...]
                .map { $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            cues.append(Utterance(
                speaker: nil,
                start: seconds(times[0]),
                end: seconds(times[1].components(separatedBy: " ").filter { !$0.isEmpty }.first ?? ""),
                text: text
            ))
        }
        return dedupRolling(cues)
    }

    /// "00:01:02,500" / "01:02.500" → 秒
    private static func seconds(_ value: String) -> Double {
        let parts = value.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: ":")
            .compactMap(Double.init)
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// YouTube 自动字幕是滚动显示的，相邻条目常互相包含
    private static func dedupRolling(_ cues: [Utterance]) -> [Utterance] {
        var result: [Utterance] = []
        for cue in cues {
            if let last = result.last {
                if cue.text == last.text || last.text.contains(cue.text) { continue }
                if cue.text.contains(last.text) {
                    result[result.count - 1].text = cue.text
                    result[result.count - 1].end = cue.end
                    continue
                }
            }
            result.append(cue)
        }
        return result
    }
}
