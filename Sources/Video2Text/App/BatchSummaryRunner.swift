import Foundation

/// 批量总结：先逐条写单篇总结（已有的跳过），两条以上再写一份汇总
@MainActor
final class BatchSummaryRunner: ObservableObject {
    enum Phase: Equatable {
        case idle
        case waitingForTranscription(Int)
        case summarizing(done: Int, total: Int)
        case digesting
        case failed(String)
    }

    @Published var phase: Phase = .idle
    /// 当前这批的汇总标题，进度条上显示
    @Published private(set) var topic = ""

    var isRunning: Bool {
        switch phase {
        case .waitingForTranscription, .summarizing, .digesting: return true
        case .idle, .failed: return false
        }
    }

    /// 同时调用 claude 的上限
    private let maxConcurrent = 3

    /// 每批一个编号；停止后旧的那批即使还没收尾，也不能再改进度（否则会盖掉下一批的状态）
    private var generation = 0

    private func set(_ newPhase: Phase, for run: Int) {
        if run == generation { phase = newPhase }
    }

    /// 返回生成的汇总；只有一条或全部失败时返回 nil
    func run(topic: String, recordIDs: [UUID], history: HistoryStore, digests: DigestStore) async -> DigestRecord? {
        generation += 1
        let run = generation
        self.topic = topic
        // 按转写时间从早到晚编号 V1、V2…
        let records = history.records
            .filter { recordIDs.contains($0.id) }
            .sorted { $0.date < $1.date }
        guard !records.isEmpty else {
            set(.failed("所选记录不存在"), for: run)
            return nil
        }

        let todo = records.filter { $0.summary == nil }
        var failures: [String] = []
        var done = 0
        set(.summarizing(done: 0, total: todo.count), for: run)

        // 限制并发：先启动 maxConcurrent 个，每完成一个再补一个
        await withTaskGroup(of: (UUID, String, Result<String, Error>).self) { group in
            var pending = todo[...]
            func startNext() {
                // 停止后不再启动新的 claude 调用
                guard !Task.isCancelled, let record = pending.popFirst() else { return }
                group.addTask {
                    do {
                        return (record.id, record.title, .success(try await Summarizer.summarize(record)))
                    } catch {
                        return (record.id, record.title, .failure(error))
                    }
                }
            }
            for _ in 0..<maxConcurrent { startNext() }
            for await (id, title, result) in group {
                if Task.isCancelled {
                    // 停止前已经写好的总结照样保存；正在写的由 ProcessRunner 结束进程
                    if case let .success(summary) = result { history.setSummary(summary, for: id) }
                    group.cancelAll()
                    continue
                }
                switch result {
                case let .success(summary): history.setSummary(summary, for: id)
                case let .failure(error): failures.append("\(title)：\(error.localizedDescription)")
                }
                done += 1
                set(.summarizing(done: done, total: todo.count), for: run)
                startNext()
            }
        }

        // 用户点了「停止」：已写好的单篇总结保留，不再生成汇总
        if Task.isCancelled {
            set(.idle, for: run)
            return nil
        }

        let summarized = history.records
            .filter { recordIDs.contains($0.id) }
            .sorted { $0.date < $1.date }
            .compactMap { record in record.summary.map { (record.id, record.title, $0) } }

        guard summarized.count >= 2 else {
            set(failures.isEmpty ? .idle : .failed(failures.joined(separator: "\n")), for: run)
            return nil
        }

        set(.digesting, for: run)
        do {
            let content = try await Summarizer.digest(
                topic: topic,
                summaries: summarized.map { (title: $0.1, summary: $0.2) }
            )
            let digest = DigestRecord(
                id: UUID(),
                title: topic,
                date: Date(),
                recordIDs: summarized.map(\.0),
                videoTitles: summarized.map(\.1),
                content: content
            )
            guard !Task.isCancelled else {
                set(.idle, for: run)
                return nil
            }
            digests.save(digest)
            set(failures.isEmpty ? .idle : .failed("以下视频总结失败，未计入汇总：\n" + failures.joined(separator: "\n")), for: run)
            return digest
        } catch {
            set(Task.isCancelled ? .idle : .failed(error.localizedDescription), for: run)
            return nil
        }
    }

    /// 等待转写阶段也可以写标题（还没进入 run）
    func prepare(topic: String, count: Int) {
        generation += 1
        self.topic = topic
        phase = .waitingForTranscription(count)
    }

    /// 停止：作废当前这批，进度立即回到空闲
    func invalidate() {
        generation += 1
        phase = .idle
    }

    func fail(_ message: String) {
        phase = .failed(message)
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
    }
}
