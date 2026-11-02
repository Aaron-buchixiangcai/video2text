import AppKit

/// 把 Claude 写的总结、汇总（Markdown）排成带标题层级的富文本。
/// 只处理这里用到的写法：# 标题、列表、分隔线、**粗体**、*斜体*、`代码`
enum MarkdownRenderer {
    static func render(_ markdown: String, baseSize: CGFloat = NSFont.systemFontSize) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        var inCodeBlock = false
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let newline = index < lines.count - 1 ? "\n" : ""

            // ``` 代码块原样等宽显示，里面的 # 和 - 不当标题、列表
            if line.hasPrefix("```") {
                inCodeBlock.toggle()
                continue
            }
            if inCodeBlock {
                output.append(NSAttributedString(
                    string: rawLine + newline,
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular),
                                 .foregroundColor: NSColor.labelColor]
                ))
                continue
            }

            if line.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                output.append(NSAttributedString(
                    string: String(repeating: "─", count: 24) + newline,
                    attributes: [.font: NSFont.systemFont(ofSize: baseSize), .foregroundColor: NSColor.tertiaryLabelColor,
                                 .paragraphStyle: paragraph(before: 4, after: 4)]
                ))
                continue
            }
            if let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                let level = line[match].filter { $0 == "#" }.count
                let size = level == 1 ? baseSize + 7 : level == 2 ? baseSize + 3 : baseSize + 1
                let text = String(line[match.upperBound...])
                output.append(inline(text, size: size, weight: .bold, paragraph: paragraph(before: level <= 2 ? 10 : 6, after: 4)))
                output.append(NSAttributedString(string: newline))
                continue
            }
            if let match = line.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                let marker = line[match].trimmingCharacters(in: .whitespaces)
                let bullet = marker.first?.isNumber == true ? marker : "•"
                // 子列表按原文缩进（每 2 个空格一级）往里排
                let level = min(rawLine.prefix { $0 == " " }.count / 2, 4)
                let style = paragraph(before: 2, after: 2, headIndent: 20 * CGFloat(level + 1), firstLineIndent: 20 * CGFloat(level))
                let item = NSMutableAttributedString(
                    string: "\(bullet)\t",
                    attributes: [.font: NSFont.systemFont(ofSize: baseSize), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
                )
                item.append(inline(String(line[match.upperBound...]), size: baseSize, weight: .regular, paragraph: style))
                output.append(item)
                output.append(NSAttributedString(string: newline))
                continue
            }
            output.append(inline(line, size: baseSize, weight: .regular, paragraph: paragraph(before: 0, after: line.isEmpty ? 0 : 4)))
            output.append(NSAttributedString(string: newline))
        }
        return output
    }

    private static func paragraph(before: CGFloat, after: CGFloat, headIndent: CGFloat = 0, firstLineIndent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineSpacing = 2
        if headIndent > 0 {
            style.headIndent = headIndent
            style.firstLineHeadIndent = firstLineIndent
            style.tabStops = [NSTextTab(textAlignment: .left, location: headIndent)]
        }
        return style
    }

    /// Foundation 按 CommonMark 规则判断粗体，「：**词**」这类紧挨中文标点的写法会被当成普通文字，这里补一遍
    private static let leftoverBold = try! NSRegularExpression(pattern: #"\*\*([^*\n]+?)\*\*"#)

    /// 行内的粗体、斜体、代码交给 Foundation 的 Markdown 解析，再换成 AppKit 字体
    private static func inline(_ text: String, size: CGFloat, weight: NSFont.Weight, paragraph: NSParagraphStyle) -> NSAttributedString {
        let parsed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = NSFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .bold : weight)
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: size - 1, weight: .regular)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            let text = String(parsed[run.range].characters)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
            guard intent.isEmpty, text.contains("**") else {
                result.append(NSAttributedString(string: text, attributes: attributes))
                continue
            }
            let bold = NSFont.systemFont(ofSize: size, weight: .bold)
            let ns = text as NSString
            var cursor = 0
            for match in leftoverBold.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                result.append(NSAttributedString(string: ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), attributes: attributes))
                var boldAttributes = attributes
                boldAttributes[.font] = bold
                result.append(NSAttributedString(string: ns.substring(with: match.range(at: 1)), attributes: boldAttributes))
                cursor = match.range.location + match.range.length
            }
            result.append(NSAttributedString(string: ns.substring(from: cursor), attributes: attributes))
        }
        return result
    }
}
