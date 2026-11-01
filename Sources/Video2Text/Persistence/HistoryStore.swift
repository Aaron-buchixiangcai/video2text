import Foundation

struct HistoryRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var source: String
    var date: Date
    var transcript: Transcript
    var diarized: Bool
    // 以下为后加字段，旧记录里没有，解码时为 nil
    var transcriptSource: TranscriptSource?
    /// Claude 生成的单篇总结（Markdown）
    var summary: String?
}

/// 历史记录：每条一个 JSON 文件，存 App Support/Video2Text/history/
@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var records: [HistoryRecord] = []

    init() {
        load()
    }

    func load() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: AppPaths.history, includingPropertiesForKeys: nil))
            ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(HistoryRecord.self, from: data)
            }
            .sorted { $0.date > $1.date }
    }

    func save(task: TranscriptionTask) {
        guard let transcript = task.transcript else { return }
        let record = HistoryRecord(
            id: task.id,
            title: task.title,
            source: task.source.displayName,
            date: task.createdAt,
            transcript: transcript,
            diarized: task.diarized,
            transcriptSource: task.transcriptSource
        )
        persist(record)
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
    }

    func delete(_ record: HistoryRecord) {
        try? FileManager.default.removeItem(at: fileURL(for: record.id))
        records.removeAll { $0.id == record.id }
    }

    func delete(ids: Set<UUID>) {
        for id in ids {
            try? FileManager.default.removeItem(at: fileURL(for: id))
        }
        records.removeAll { ids.contains($0.id) }
    }

    func rename(_ record: HistoryRecord, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = records.firstIndex(where: { $0.id == record.id }) else { return }
        records[idx].title = trimmed
        persist(records[idx])
    }

    func setSummary(_ summary: String, for id: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == id }) else { return }
        records[idx].summary = summary
        persist(records[idx])
    }

    private func persist(_ record: HistoryRecord) {
        AppPaths.ensureAll()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(record) {
            try? data.write(to: fileURL(for: record.id))
        }
    }

    private func fileURL(for id: UUID) -> URL {
        AppPaths.history.appendingPathComponent("\(id.uuidString).json")
    }
}
