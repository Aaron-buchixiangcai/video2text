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

    let coordinator = PipelineCoordinator()
    let history = HistoryStore()
    let digests = DigestStore()
    let settingsStore = SettingsStore()
    let transcriptToggles = TranscriptTogglesStore()
    let batchSummary = BatchSummaryRunner()

    init() {
        AppPaths.ensureAll()
        ytDlpInstalled = YtDlpManager.isInstalled
        showSetup = !ytDlpInstalled
        coordinator.historyStore = history
    }

    /// 一段文字里有多个链接时逐个排队；没有链接时按原文提交（交给 yt-dlp 判断）
    func submit(urlString: String) {
        let urls = LinkExtractor.allURLStrings(in: urlString)
        if urls.count > 1 {
            for (index, url) in urls.enumerated() {
                enqueue(TranscriptionTask(source: .remote(url)), select: index == 0)
            }
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

    /// 搜索结果批量排队；autoSummarize 时等这批全部转写完，自动总结并生成汇总
    func submit(searchResults: [SearchResult], topic: String, autoSummarize: Bool) {
        var batch: [TranscriptionTask] = []
        for (index, result) in searchResults.enumerated() {
            let task = TranscriptionTask(source: .remote(result.url))
            task.title = result.displayTitle
            enqueue(task, select: index == 0)
            batch.append(task)
        }
        guard autoSummarize, !batch.isEmpty else { return }
        batchSummary.phase = .waitingForTranscription(batch.count)
        Task {
            await coordinator.waitForQueue()
            let completed = batch.filter { $0.stage == .completed }.map(\.id)
            guard !completed.isEmpty else {
                batchSummary.phase = .failed("这批视频都没有转写成功，未生成总结")
                return
            }
            runSummary(recordIDs: completed, topic: topic)
        }
    }

    /// 同一时间只跑一批总结
    func summarize(recordIDs: [UUID], topic: String) {
        guard !batchSummary.isRunning else { return }
        runSummary(recordIDs: recordIDs, topic: topic)
    }

    private func runSummary(recordIDs: [UUID], topic: String) {
        Task {
            let digest = await batchSummary.run(
                topic: topic, recordIDs: recordIDs, history: history, digests: digests
            )
            if let digest {
                selection = .digest(digest.id)
            } else if recordIDs.count == 1 {
                selection = .history(recordIDs[0])
            }
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
