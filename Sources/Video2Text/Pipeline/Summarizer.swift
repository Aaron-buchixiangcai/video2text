import Foundation

enum SummarizerError: LocalizedError {
    case claudeNotFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "找不到 claude 命令行。请先安装 Claude Code（brew install claude），再在终端运行 claude auth login 登录。"
        case let .failed(reason):
            let lower = reason.lowercased()
            let hint = (lower.contains("401") || lower.contains("auth") || lower.contains("login"))
                ? "\n请在终端运行 claude auth login 重新登录。" : ""
            return "Claude 总结失败：\(reason.suffix(300))\(hint)"
        }
    }
}

/// 调用本机 Claude Code 命令行（claude -p）写总结，用的是用户自己的登录账号和额度
enum Summarizer {
    static let model = "sonnet"

    static let videoPrompt = """
    你会收到一个视频的元信息和文稿。文稿来自字幕或语音识别，可能有错别字和同音误识别。
    用简体中文写总结（文稿是繁体或外语也用简体中文），严格按以下结构输出 Markdown，不要输出其他内容：

    ## 一句话概括
    （一句话）

    ## 要点
    （5–10 条，每条一句；保留原文中的数字、术语、人名、产品名，附 [mm:ss] 时间）

    ## 主要论点与依据
    （视频的核心主张，以及它给出的理由、数据或例子）

    ## 可执行的信息
    （方法、步骤、工具、建议；没有就写"无"）

    ## 存疑之处
    （疑似识别错误的专有名词，或视频中缺乏依据的说法；没有就写"无"）

    只依据文稿内容，不补充文稿以外的信息。
    """

    static func digestPrompt(topic: String, count: Int) -> String {
        """
        你会收到关于主题「\(topic)」的 \(count) 个视频的单篇总结，每篇以 [V编号] 开头。
        用简体中文写一份综合报告，严格按以下结构输出 Markdown，不要输出其他内容：

        ## 总体概况
        ## 反复出现的观点
        （每条标注来源，如 [V1][V4]）
        ## 分歧与矛盾
        ## 只有个别视频提到的信息
        ## 推荐观看顺序
        （按信息密度排序，每个附一句理由）

        只依据给出的总结，不补充其他信息。
        """
    }

    /// GUI 应用启动的进程拿不到 shell 的 PATH，所以按固定位置找
    static func locateClaude() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// 单次调用的文稿上限（字符）。中文约一字一个 token，给模型上下文留足余量
    static let maxCharactersPerCall = 80_000

    static func summarize(_ record: HistoryRecord) async throws -> String {
        let header = """
        标题：\(record.title)
        来源：\(record.source)
        文稿来源：\(record.transcriptSource == .subtitles ? "平台字幕" : "语音识别")
        """
        let lines = compactLines(record.transcript, diarized: record.diarized)
        let body = lines.joined(separator: "\n")
        guard body.count > maxCharactersPerCall else {
            return try await run(prompt: videoPrompt, content: header + "\n\n" + body)
        }

        // 太长（多P合集）：分段整理笔记，再按同一格式合成一篇
        let chunks = chunked(lines, limit: maxCharactersPerCall)
        var notes: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let note = try await run(
                prompt: chunkPrompt(index: index + 1, count: chunks.count),
                content: header + "\n\n" + chunk
            )
            notes.append("【第 \(index + 1) 段笔记】\n\(note)")
        }
        return try await run(
            prompt: videoPrompt + "\n\n注意：这个视频很长，下面给的不是文稿原文，而是按顺序分段整理的笔记。时间是各分P内的 [mm:ss]，引用时一并写出分P标题。",
            content: header + "\n\n" + notes.joined(separator: "\n\n---\n\n")
        )
    }

    static func chunkPrompt(index: Int, count: Int) -> String {
        """
        你会收到一个长视频文稿的第 \(index)/\(count) 段，文稿来自字幕或语音识别，可能有同音误识别。
        用简体中文整理这一段的笔记，只输出以下内容：
        1. 要点：10–20 条，每条一句，保留数字、术语、人名、产品名，附 [mm:ss] 时间；文稿里有【P几】标题时按分P分组并写出标题。
        2. 可执行的信息：方法、步骤、工具、建议；没有就写"无"。
        3. 疑似识别错误的专有名词；没有就写"无"。
        只依据文稿，不补充文稿以外的信息。
        """
    }

    /// 给 Claude 的文稿：同一说话人约 30 秒并成一行、只标一次时间，比逐句标时间省约四分之一篇幅；
    /// 分P标题单独成行
    static func compactLines(_ transcript: Transcript, diarized: Bool) -> [String] {
        var lines: [String] = []
        var current: (start: Double, speaker: Int?, text: String)?
        func flush() {
            guard let block = current else { return }
            let who = diarized ? ((block.speaker.map { "说话人\($0 + 1)" } ?? "未知") + "：") : ""
            lines.append("[\(formatTimestamp(block.start))] \(who)\(block.text)")
            current = nil
        }
        for u in transcript.utterances {
            let text = u.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if u.isMarker {
                flush()
                lines.append(text)
            } else if var block = current, block.speaker == u.speaker, u.start - block.start < 30 {
                let cjk = { (c: Character?) in c?.unicodeScalars.first?.properties.isIdeographic == true }
                block.text += (cjk(block.text.last) && cjk(text.first) ? "" : " ") + text
                current = block
            } else {
                flush()
                current = (u.start, u.speaker, text)
            }
        }
        flush()
        return lines
    }

    /// 按行切块，每块不超过 limit 字符；块已过半时遇到分P标题就另起一块
    static func chunked(_ lines: [String], limit: Int) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var size = 0
        for line in lines {
            let isPartTitle = line.hasPrefix("【P")
            if !current.isEmpty, size + line.count > limit || (isPartTitle && size > limit / 2) {
                chunks.append(current.joined(separator: "\n"))
                current = []
                size = 0
            }
            current.append(line)
            size += line.count + 1
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }

    /// summaries 按 V1、V2… 的顺序排列
    static func digest(topic: String, summaries: [(title: String, summary: String)]) async throws -> String {
        let content = summaries.enumerated()
            .map { "[V\($0.offset + 1)] \($0.element.title)\n\n\($0.element.summary)" }
            .joined(separator: "\n\n---\n\n")
        return try await run(prompt: digestPrompt(topic: topic, count: summaries.count), content: content)
    }

    private static let timeout: TimeInterval = 900

    private static func run(prompt: String, content: String) async throws -> String {
        guard let claude = locateClaude() else { throw SummarizerError.claudeNotFound }

        // 文稿可能很长，写进临时文件当 stdin，避免命令行参数超长
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2t-summary-\(UUID().uuidString).txt")
        try content.write(to: input, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: input) }

        var environment = ProcessInfo.processInfo.environment
        // 从 Claude Code 会话里用 open 启动 App 时，会继承该会话的 CLAUDE_CODE_* 和 ANTHROPIC_BASE_URL，
        // claude 会改用宿主会话的登录通道并一直卡住。只要看到这类变量就全部去掉，用本机自己的登录
        if environment.keys.contains(where: { $0.hasPrefix("CLAUDECODE") || $0.hasPrefix("CLAUDE_CODE_") }) {
            environment = environment.filter { !$0.key.hasPrefix("CLAUDE") && $0.key != "ANTHROPIC_BASE_URL" }
        }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        // claude 会读取 PWD 指向的目录。从终端 open 启动 App 时 PWD 可能在桌面、文稿等受保护目录，
        // 系统会以本 App 的名义弹出访问授权并让 claude 一直等着，所以指向实际运行的临时目录
        let workingDirectory = FileManager.default.temporaryDirectory
        environment["PWD"] = workingDirectory.path
        environment["OLDPWD"] = nil

        let result = try await ProcessRunner.run(
            claude,
            arguments: [
                "-p", prompt,
                "--model", model,
                "--tools", "",
                "--no-session-persistence",
                // 用自己的系统提示并重置输出风格，避免套用用户全局设置里的页脚、字数上限等规则
                "--system-prompt", "你是视频内容总结助手，只按用户给出的格式输出。",
                "--settings", #"{"outputStyle": "default"}"#,
            ],
            // 在临时目录运行，不读取任何项目的 CLAUDE.md
            currentDirectory: workingDirectory,
            environment: environment,
            standardInputFile: input,
            timeout: timeout
        )
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !output.isEmpty else {
            var reason = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if reason.isEmpty {
                reason = result.timedOut
                    ? "claude 超过 \(Int(timeout / 60)) 分钟没有返回"
                    : "claude 没有输出（退出码 \(result.exitCode)）"
            }
            throw SummarizerError.failed(reason)
        }
        return output
    }
}
