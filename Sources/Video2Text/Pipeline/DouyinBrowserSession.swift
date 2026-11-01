import Darwin
import Foundation

enum DouyinBrowserSessionError: LocalizedError {
    case chromeNotFound
    case chromeLaunchFailed(String)
    case chromeExitedEarly
    case startupTimedOut
    case cookiesMissing

    var errorDescription: String? {
        switch self {
        case .chromeNotFound:
            return "抖音自动验证需要 Google Chrome，但未找到 Chrome"
        case let .chromeLaunchFailed(reason):
            return "无法启动抖音自动验证：\(reason)"
        case .chromeExitedEarly:
            return "抖音自动验证窗口意外退出"
        case .startupTimedOut:
            return "抖音自动验证启动超时"
        case .cookiesMissing:
            return "抖音页面已打开，但没有生成可用的临时验证信息"
        }
    }
}

/// 用完全独立的临时 Chrome profile 执行抖音网页的 JavaScript 风控校验。
///
/// 这里不会读取用户日常 Chrome/Safari 的 profile。临时 profile 位于当前任务目录，
/// yt-dlp 读取完后由调用方立即删除，任务结束时 PipelineCoordinator 还会再次兜底清理。
enum DouyinBrowserSession {
    private static let startupTimeout: TimeInterval = 10
    // DevTools 先就绪不代表抖音的风控脚本已经写完验证 cookies。
    // 实测后半段的安全 cookies 可能在页面打开约 15 秒后才出现，因此留足 20 秒。
    private static let challengeWait: TimeInterval = 20

    static func prepare(
        url: String,
        destinationDir: URL
    ) async throws -> URL {
        guard let chrome = locateChrome() else {
            throw DouyinBrowserSessionError.chromeNotFound
        }

        let profileDir = destinationDir
            .appendingPathComponent(".douyin-browser-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: profileDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let process = Process()
        process.executableURL = chrome
        process.arguments = [
            "--headless=new",
            "--disable-gpu",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-extensions",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-sync",
            "--disable-default-apps",
            "--disable-client-side-phishing-detection",
            "--metrics-recording-only",
            "--no-pings",
            "--mute-audio",
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=0",
            "--user-data-dir=\(profileDir.path)",
            url,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: profileDir)
            throw DouyinBrowserSessionError.chromeLaunchFailed(error.localizedDescription)
        }

        do {
            try await waitUntilReady(process: process, profileDir: profileDir)
            try await Task.sleep(
                nanoseconds: UInt64(challengeWait * 1_000_000_000)
            )
            try Task.checkCancellation()
        } catch {
            await stop(process)
            await remove(profileDir)
            throw error
        }

        await stop(process)

        let cookiesDB = profileDir
            .appendingPathComponent("Default", isDirectory: true)
            .appendingPathComponent("Cookies")
        let cookieValues = try? cookiesDB.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard cookieValues?.isRegularFile == true,
              (cookieValues?.fileSize ?? 0) > 4_096 else {
            await remove(profileDir)
            throw DouyinBrowserSessionError.cookiesMissing
        }

        return profileDir
    }

    static func browserSpec(for profileDir: URL) -> String {
        "chrome:\(profileDir.path)"
    }

    static func remove(_ profileDir: URL) async {
        for _ in 0..<5 {
            do {
                try FileManager.default.removeItem(at: profileDir)
                return
            } catch {
                if !FileManager.default.fileExists(atPath: profileDir.path) {
                    return
                }
                await uncancellablePause(nanoseconds: 200_000_000)
            }
        }
    }

    private static func locateChrome() -> URL? {
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "\(NSHomeDirectory())/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func waitUntilReady(
        process: Process,
        profileDir: URL
    ) async throws {
        let readinessFile = profileDir.appendingPathComponent("DevToolsActivePort")
        let deadline = Date().addingTimeInterval(startupTimeout)

        while Date() < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: readinessFile.path) {
                return
            }
            if !process.isRunning {
                throw DouyinBrowserSessionError.chromeExitedEarly
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw DouyinBrowserSessionError.startupTimedOut
    }

    private static func stop(_ process: Process) async {
        guard process.isRunning else { return }
        process.interrupt()

        for _ in 0..<30 {
            if !process.isRunning { return }
            await uncancellablePause(nanoseconds: 100_000_000)
        }

        if process.isRunning {
            process.terminate()
        }
        for _ in 0..<20 {
            if !process.isRunning { return }
            await uncancellablePause(nanoseconds: 100_000_000)
        }

        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        for _ in 0..<10 {
            if !process.isRunning { return }
            await uncancellablePause(nanoseconds: 100_000_000)
        }
    }

    private static func uncancellablePause(nanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .nanoseconds(Int(nanoseconds))
            ) {
                continuation.resume()
            }
        }
    }
}
