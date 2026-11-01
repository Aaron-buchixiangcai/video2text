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

    var isRunning: Bool {
        switch phase {
        case .waitingForTranscription, .summarizing, .digesting: return true
        case .idle, .failed: return false
        }
    }

    /// 同时调用 claude 的上限
    private let maxConcurrent = 3

    /// 返回生成的汇总；只有一条或全部失败时返回 nil
    func run(topic: String, recordIDs: [UUID], history: HistoryStore, digests: DigestStore) async -> DigestRecord? {
        // 按转写时间从早到晚编号 V1、V2…
        let records = history.records
            .filter { recordIDs.contains($0.id) }
            .sorted { $0.date < $1.date }
        guard !records.isEmpty else {
            phase = .failed("所选记录不存在")
            return nil
        }

        let todo = records.filter { $0.summary == nil }
        var failures: [String] = []
        var done = 0
        phase = .summarizing(done: 0, total: todo.count)

        // 限制并发：先启动 maxConcurrent 个，每完成一个再补一个
        await withTaskGroup(of: (UUID, String, Result<String, Error>).self) { group in
            var pending = todo[...]
            func startNext() {
                guard let record = pending.popFirst() else { return }
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
                switch result {
                case let .success(summary): history.setSummary(summary, for: id)
                case let .failure(error): failures.append("\(title)：\(error.localizedDescription)")
                }
                done += 1
                phase = .summarizing(done: done, total: todo.count)
                startNext()
            }
        }

        let summarized = history.records
            .filter { recordIDs.contains($0.id) }
            .sorted { $0.date < $1.date }
            .compactMap { record in record.summary.map { (record.id, record.title, $0) } }

        guard summarized.count >= 2 else {
            phase = failures.isEmpty ? .idle : .failed(failures.joined(separator: "\n"))
            return nil
        }

        phase = .digesting
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
            digests.save(digest)
            phase = failures.isEmpty ? .idle : .failed("以下视频总结失败，未计入汇总：\n" + failures.joined(separator: "\n"))
            return digest
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
    }
}
