import Foundation

enum LinkExtractor {
    private static let trailingCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "，。；;、！!？?）)]】》>\"'“”‘’"))

    static func firstURLString(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let detected = detectWithDataDetector(in: trimmed) {
            return sanitize(detected)
        }
        if let matched = detectWithRegex(in: trimmed) {
            return sanitize(matched)
        }
        return nil
    }

    /// 文中所有 http(s) 链接，去重并保持出现顺序（用于一次粘贴多个链接）
    static func allURLStrings(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        var seen = Set<String>()
        return detector.matches(in: trimmed, options: [], range: range)
            .compactMap(\.url)
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
            .map { sanitize($0.absoluteString) }
            .filter { seen.insert($0).inserted }
    }

    static func bestEffortURLString(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return firstURLString(in: trimmed) ?? trimmed
    }

    private static func detectWithDataDetector(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector
            .matches(in: text, options: [], range: range)
            .compactMap(\.url)
            .filter { url in
                guard let scheme = url.scheme?.lowercased() else { return false }
                return scheme == "http" || scheme == "https"
            }
            .map(\.absoluteString)
            .first
    }

    private static func detectWithRegex(in text: String) -> String? {
        let pattern = #"(?i)(https?://[^\s"'<>]+|(?:www\.)?(?:youtube\.com|youtu\.be|bilibili\.com|b23\.tv|douyin\.com|v\.douyin\.com|tiktok\.com|vm\.tiktok\.com|xiaohongshu\.com|xhslink\.com)/[^\s"'<>]+)"#
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        var value = String(text[range])
        if !value.lowercased().hasPrefix("http://"),
           !value.lowercased().hasPrefix("https://") {
            value = "https://" + value
        }
        return value
    }

    private static func sanitize(_ value: String) -> String {
        value.trimmingCharacters(in: trailingCharacters)
    }
}
