import Foundation
import SwiftUI

enum SidebarItem: Hashable {
    case task(UUID)
    case history(UUID)
    case digest(UUID)
}

@MainActor
final class AppState: ObservableObject {
    @Published var tasks: [TranscriptionTask] = []
    @Published var selection: SidebarItem?
    @Published var ytDlpInstalled: Bool
    @Published var showSetup = false
    /// 以下由界面和测试接口共用：搜索面板、历史多选、文字稿/总结切换（nil 表示不干预）
    @Published var showSearch = false
    @Published var selectMode = false
    @Published var forceSummaryTab: Bool?

    let coordinator = PipelineCoordinator()
    let history = HistoryStore()
    let digests = DigestStore()
    let settingsStore = SettingsStore()
    let transcriptToggles = TranscriptTogglesStore()
    let batchSummary = BatchSummaryRunner()
    private var testAPI: TestAPI?
    /// 正在进行的这批总结（含等待转写的阶段），「停止」时取消
    private var summaryJob: Task<Void, Never>?
    /// 由 MainView 注入 SwiftUI 的 openSettings，测试接口用它打开设置窗口
    var openSettingsAction: (() -> Void)?

    init() {
        AppPaths.ensureAll()
        PipelineCoordinator.removeLeftoverDownloads()
        ytDlpInstalled = YtDlpManager.isInstalled
        showSetup = !ytDlpInstalled
        coordinator.historyStore = history
        if let port = TestAPI.portFromArguments() {
            do {
                testAPI = try TestAPI(appState: self, port: port)
            } catch {
                NSLog("测试接口启动失败: \(error)")
            }
        }
    }

    /// 一段文字里有多个链接时逐个排队；没有链接时按原文提交（交给 yt-dlp 判断）
    func submit(urlString: String) {
        let urls = LinkExtractor.allURLStrings(in: urlString)
        if urls.count > 1 {
            enqueue(batch: urls.map { TranscriptionTask(source: .remote($0)) })
            return
        }
        let extracted = LinkExtractor.bestEffortURLString(from: urlString)
        guard !extracted.isEmpty else { return }
        let task = TranscriptionTask(source: .remote(extracted))
        enqueue(task)
    }

    func submit(fileURL: URL) {
        let task = TranscriptionTask(source: .localFile(fileURL))
        enqueue(task)
    }

    /// 搜索结果批量排队；autoSummarize 时等这批全部转写完，自动总结并生成汇总。
    /// 返回是否安排了自动总结（已有一批在跑或找不到 claude 时不安排）
    @discardableResult
    func submit(searchResults: [SearchResult], topic: String, autoSummarize: Bool) -> Bool {
        let batch = searchResults.map { result in
            let task = TranscriptionTask(source: .remote(result.url))
            // 没拿到标题时先显示链接，下载时由 yt-dlp 补上标题
            if let title = result.title { task.title = title }
            return task
        }
        enqueue(batch: batch)
        // 已有一批总结在跑时不再排第二批（界面上的开关也会禁用）
        guard autoSummarize, !batch.isEmpty, !batchSummary.isRunning, Summarizer.locateClaude() != nil else { return false }
        batchSummary.prepare(topic: topic, count: batch.count)
        summaryJob = Task {
            await coordinator.waitForQueue()
            guard !Task.isCancelled else { return }
            let completed = batch.filter { $0.stage == .completed }.map(\.id)
            guard !completed.isEmpty else {
                batchSummary.fail("这批视频都没有转写成功，未生成总结")
                return
            }
            await summarizeNow(recordIDs: completed, topic: topic)
        }
        return true
    }

    /// 取消正在等待或进行中的总结；转写任务不受影响
    func cancelSummary() {
        summaryJob?.cancel()
        summaryJob = nil
        batchSummary.invalidate()
    }

    /// 同一时间只跑一批总结；已有一批在跑时返回 false
    @discardableResult
    func summarize(recordIDs: [UUID], topic: String) -> Bool {
        guard !batchSummary.isRunning else { return false }
        runSummary(recordIDs: recordIDs, topic: topic)
        return true
    }

    private func runSummary(recordIDs: [UUID], topic: String) {
        summaryJob = Task { await summarizeNow(recordIDs: recordIDs, topic: topic) }
    }

    private func summarizeNow(recordIDs: [UUID], topic: String) async {
        let digest = await batchSummary.run(
            topic: topic, recordIDs: recordIDs, history: history, digests: digests
        )
        guard !Task.isCancelled else { return }
        if let digest {
            selection = .digest(digest.id)
        } else if recordIDs.count == 1 {
            selection = .history(recordIDs[0])
        }
    }

    /// 一批任务一次性插到列表顶部（按提交顺序，从上到下就是处理顺序），再选中第一个。
    /// 逐个插入并在中途改选中项时，侧栏的高亮会停在错的行上
    private func enqueue(batch: [TranscriptionTask]) {
        guard let first = batch.first else { return }
        tasks.insert(contentsOf: batch, at: 0)
        selection = .task(first.id)
        for task in batch {
            coordinator.enqueue(task, settings: settingsStore.settings)
        }
    }

    private func enqueue(_ task: TranscriptionTask, select: Bool = true) {
        tasks.insert(task, at: 0)
        if select { selection = .task(task.id) }
        coordinator.enqueue(task, settings: settingsStore.settings)
    }

    func cancel(_ task: TranscriptionTask) {
        coordinator.cancel(task)
    }

    func remove(_ task: TranscriptionTask) {
        coordinator.cancel(task)
        tasks.removeAll { $0.id == task.id }
        if selection == .task(task.id) { selection = nil }
    }

    func task(for id: UUID) -> TranscriptionTask? {
        tasks.first { $0.id == id }
    }

    func record(for id: UUID) -> HistoryRecord? {
        history.records.first { $0.id == id }
    }
}
