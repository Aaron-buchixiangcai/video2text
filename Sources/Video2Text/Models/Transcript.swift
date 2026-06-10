import Foundation

/// 一段话：可选说话人编号（0 起，展示为"说话人 N+1"）+ 起止时间 + 文本
struct Utterance: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var speaker: Int?
    var start: Double
    var end: Double
    var text: String
}

struct Transcript: Codable, Hashable {
    var utterances: [Utterance]
    var language: String?
    var speakerCount: Int?

    var plainText: String {
        utterances.map { $0.text.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 相邻同说话人且间隔 < gap 秒的段落合并
    func coalesced(maxGap: Double = 1.0) -> Transcript {
        var merged: [Utterance] = []
        for u in utterances {
            if var last = merged.last,
               last.speaker == u.speaker,
               u.start - last.end < maxGap {
                last.end = u.end
                last.text = joinText(last.text, u.text)
                merged[merged.count - 1] = last
            } else {
                merged.append(u)
            }
        }
        return Transcript(utterances: merged, language: language, speakerCount: speakerCount)
    }

    /// 中文之间直接拼接，英文之间补空格
    private func joinText(_ a: String, _ b: String) -> String {
        let lhs = a.trimmingCharacters(in: .whitespaces)
        let rhs = b.trimmingCharacters(in: .whitespaces)
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        let lastChar = lhs.unicodeScalars.last!
        let firstChar = rhs.unicodeScalars.first!
        let isCJK: (Unicode.Scalar) -> Bool = { $0.properties.isIdeographic }
        if isCJK(lastChar) && isCJK(firstChar) {
            return lhs + rhs
        }
        return lhs + " " + rhs
    }
}

func formatTimestamp(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}
