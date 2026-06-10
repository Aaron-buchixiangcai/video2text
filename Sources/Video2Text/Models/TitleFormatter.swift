import Foundation

enum TitleFormatter {
    static func shortDisplay(_ title: String, maxCharacters: Int = 10) -> String {
        let value = normalized(title)
        guard value.count > maxCharacters else { return value }
        return String(value.prefix(maxCharacters)) + "…"
    }

    static func shortFileStem(_ title: String, maxCharacters: Int = 10) -> String {
        String(normalized(title).prefix(maxCharacters))
    }

    private static func normalized(_ title: String) -> String {
        let collapsed = title
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "文字稿" : collapsed
    }
}
