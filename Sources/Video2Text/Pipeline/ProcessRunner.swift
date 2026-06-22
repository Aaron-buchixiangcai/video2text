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
        let state = ProcessRunState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let stdoutHandle = stdoutPipe.fileHandleForReading
                let stderrHandle = stderrPipe.fileHandleForReading

                func finishSuccess() {
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    continuation.resume(returning: ProcessResult(
                        exitCode: state.exitCode,
                        stdout: stdoutCollector.text,
                        stderr: stderrCollector.text
                    ))
                }

                // 用 readabilityHandler 持续读取并以"空数据=EOF"收尾，避免 readDataToEndOfFile
                // 在孙进程持有管道写端时永久阻塞，也消除与 terminationHandler 的并发读竞态。
                stdoutHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        if state.markStdoutEOF() { finishSuccess() }
                    } else {
                        stdoutCollector.append(data)
                    }
                }
                stderrHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        if state.markStderrEOF() { finishSuccess() }
                    } else {
                        stderrCollector.append(data)
                    }
                }

                let timeoutTimer: DispatchWorkItem? = timeout.map { seconds in
                    let item = DispatchWorkItem { state.terminateIfRunning(process) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
                    return item
                }

                process.terminationHandler = { proc in
                    timeoutTimer?.cancel()
                    if state.markTerminated(proc.terminationStatus) {
                        finishSuccess()
                    } else {
                        // 进程已退出但管道迟迟不 EOF（可能被孙进程持有）：2 秒后兜底收尾
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if state.forceFinish() { finishSuccess() }
                        }
                    }
                }

                do {
                    // 先置 launched，再 run：否则 run() 返回后到置位前若收到取消，
                    // terminateIfRunning 因 launched 仍为 false 而漏杀进程（run 抛错时
                    // isRunning 为 false，terminate 仍不会被调用，安全）。
                    state.markLaunched()
                    try process.run()
                } catch {
                    timeoutTimer?.cancel()
                    process.terminationHandler = nil
                    stdoutHandle.readabilityHandler = nil
                    stderrHandle.readabilityHandler = nil
                    if state.markResumed() {
                        continuation.resume(throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
                    }
                }
            }
        } onCancel: {
            state.terminateIfRunning(process)
        }
    }
}

/// ProcessRunner 的线程安全状态机：保证 continuation 只 resume 一次，
/// 且只对已 launch、仍在运行的进程调用 terminate()（否则 Foundation 会崩溃）。
private final class ProcessRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var launched = false
    private var resumed = false
    private var stdoutEOF = false
    private var stderrEOF = false
    private var terminated = false
    private var storedExitCode: Int32 = 0

    var exitCode: Int32 {
        lock.lock(); defer { lock.unlock() }
        return storedExitCode
    }

    func markLaunched() {
        lock.lock(); launched = true; lock.unlock()
    }

    /// 仅在进程确实启动过且仍在运行时终止，规避「task not launched」崩溃
    func terminateIfRunning(_ process: Process) {
        lock.lock(); let didLaunch = launched; lock.unlock()
        if didLaunch && process.isRunning { process.terminate() }
    }

    /// 进程退出。返回 true 表示此刻所有读取也已结束、应立即收尾
    func markTerminated(_ code: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        terminated = true
        storedExitCode = code
        return readyLocked()
    }

    func markStdoutEOF() -> Bool {
        lock.lock(); defer { lock.unlock() }
        stdoutEOF = true
        return readyLocked()
    }

    func markStderrEOF() -> Bool {
        lock.lock(); defer { lock.unlock() }
        stderrEOF = true
        return readyLocked()
    }

    /// 兜底：进程已退出但管道未 EOF 时强制收尾
    func forceFinish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard terminated, !resumed else { return false }
        resumed = true
        return true
    }

    /// 启动失败路径：抢占 resume 资格
    func markResumed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }

    private func readyLocked() -> Bool {
        guard terminated, stdoutEOF, stderrEOF, !resumed else { return false }
        resumed = true
        return true
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
