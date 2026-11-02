import Foundation

/// 一份汇总：对若干条历史记录的单篇总结再做的综合报告
struct DigestRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var date: Date
    /// 按 V1、V2… 的顺序
    var recordIDs: [UUID]
    var videoTitles: [String]
    var content: String

    var markdown: String {
        let list = videoTitles.enumerated()
            .map { "- V\($0.offset + 1)：\($0.element)" }
            .joined(separator: "\n")
        return "# \(title)\n\n\(list)\n\n\(content)\n"
    }
}

/// 汇总记录：每条一个 JSON 文件，存 App Support/Video2Text/digests/
@MainActor
final class DigestStore: ObservableObject {
    @Published private(set) var records: [DigestRecord] = []

    init() {
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.digests, includingPropertiesForKeys: nil
        )) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(DigestRecord.self, from: data)
            }
            .sorted { $0.date > $1.date }
    }

    func save(_ record: DigestRecord) {
        AppPaths.ensureAll()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(record) {
            try? data.write(to: fileURL(for: record.id))
        }
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
    }

    func delete(_ record: DigestRecord) {
        try? FileManager.default.removeItem(at: fileURL(for: record.id))
        records.removeAll { $0.id == record.id }
    }

    func record(for id: UUID) -> DigestRecord? {
        records.first { $0.id == id }
    }

    private func fileURL(for id: UUID) -> URL {
        AppPaths.digests.appendingPathComponent("\(id.uuidString).json")
    }
}
