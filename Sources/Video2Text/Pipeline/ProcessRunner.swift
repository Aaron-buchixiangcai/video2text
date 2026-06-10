import Foundation

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum ProcessRunnerError: LocalizedError {
    case timedOut
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: return "命令执行超时"
        case let .launchFailed(reason): return "无法启动命令：\(reason)"
        }
    }
}

/// Process 的 async 封装，支持逐行回调（解析 yt-dlp 进度）与取消
enum ProcessRunner {
    @discardableResult
    static func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = LineCollector(onLine: onStdoutLine)
        let stderrCollector = LineCollector(onLine: nil)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTimer: DispatchWorkItem? = timeout.map { seconds in
                    let item = DispatchWorkItem { [weak process] in process?.terminate() }
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
                    return item
                }
                process.terminationHandler = { proc in
                    timeoutTimer?.cancel()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    // 把管道里剩余数据读完
                    stdoutCollector.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    stderrCollector.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    continuation.resume(returning: ProcessResult(
                        exitCode: proc.terminationStatus,
                        stdout: stdoutCollector.text,
                        stderr: stderrCollector.text
                    ))
                }
                do {
                    try process.run()
                } catch {
                    timeoutTimer?.cancel()
                    process.terminationHandler = nil
                    continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}

/// 按行切分流式输出；线程安全（readabilityHandler 在后台队列回调）
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var all = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return all
    }

    func append(_ data: Data) {
        guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        all += chunk
        buffer += chunk
        var lines: [String] = []
        // \r 也当行分隔（yt-dlp 进度行可能用 \r 刷新）
        while let range = buffer.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n")) {
            lines.append(String(buffer[..<range.lowerBound]))
            buffer.removeSubrange(..<range.upperBound)
        }
        lock.unlock()
        if let onLine {
            for line in lines where !line.isEmpty { onLine(line) }
        }
    }
}
