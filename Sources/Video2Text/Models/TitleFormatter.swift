import Foundation

enum TitleFormatter {
    /// 界面上显示的完整标题（合并空白）；长度交给 lineLimit 按列宽截断
    static func display(_ title: String) -> String {
        normalized(title)
    }

    static func shortDisplay(_ title: String, maxCharacters: Int = 10) -> String {
        let value = normalized(title)
        guard value.count > maxCharacters else { return value }
        return String(value.prefix(maxCharacters)).trimmingCharacters(in: .whitespaces) + "…"
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
