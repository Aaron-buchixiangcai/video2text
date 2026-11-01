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

    static func summarize(_ record: HistoryRecord) async throws -> String {
        let body = TranscriptExporter.render(
            record.transcript, showTimestamps: true, showSpeakers: record.diarized
        )
        let content = """
        标题：\(record.title)
        来源：\(record.source)
        文稿来源：\(record.transcriptSource == .subtitles ? "平台字幕" : "语音识别")

        \(body)
        """
        return try await run(prompt: videoPrompt, content: content)
    }

    /// summaries 按 V1、V2… 的顺序排列
    static func digest(topic: String, summaries: [(title: String, summary: String)]) async throws -> String {
        let content = summaries.enumerated()
            .map { "[V\($0.offset + 1)] \($0.element.title)\n\n\($0.element.summary)" }
            .joined(separator: "\n\n---\n\n")
        return try await run(prompt: digestPrompt(topic: topic, count: summaries.count), content: content)
    }

    private static func run(prompt: String, content: String) async throws -> String {
        guard let claude = locateClaude() else { throw SummarizerError.claudeNotFound }

        // 文稿可能很长，写进临时文件当 stdin，避免命令行参数超长
        let input = FileManager.default.temporaryDirectory
            .appendingPathComponent("v2t-summary-\(UUID().uuidString).txt")
        try content.write(to: input, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: input) }

        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CLAUDECODE") }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")

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
            currentDirectory: FileManager.default.temporaryDirectory,
            environment: environment,
            standardInputFile: input,
            timeout: 900
        )
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !output.isEmpty else {
            let reason = result.stderr.isEmpty ? result.stdout : result.stderr
            throw SummarizerError.failed(reason.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
