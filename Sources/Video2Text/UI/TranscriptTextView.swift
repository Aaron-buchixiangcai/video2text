import AppKit
import SwiftUI

struct TranscriptTextView: NSViewRepresentable {
    let text: String
    /// 总结、汇总是 Markdown，排成带标题层级的富文本；文字稿按纯文本显示，分P标题行加粗
    var markdown = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.usesFindPanel = true
        textView.allowsUndo = false
        // 左右边距与上方工具栏、输入栏的 10pt 对齐
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 10, height: 14)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView ?? scrollView.documentView as? NSTextView else {
            return
        }
        let key = (markdown ? "md:" : "txt:") + text
        if context.coordinator.currentKey != key {
            context.coordinator.currentKey = key
            textView.textStorage?.setAttributedString(markdown ? MarkdownRenderer.render(text) : Self.plain(text))
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    private static let partTitle = try! NSRegularExpression(pattern: #"^【P\d+】.*$"#, options: .anchorsMatchLines)

    private static func plain(_ text: String) -> NSAttributedString {
        let size = NSFont.systemFontSize
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor]
        )
        let spaced = NSMutableParagraphStyle()
        spaced.paragraphSpacingBefore = 10
        spaced.paragraphSpacing = 2
        for match in partTitle.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            result.addAttributes(
                [.font: NSFont.systemFont(ofSize: size + 1, weight: .bold), .paragraphStyle: spaced],
                range: match.range
            )
        }
        return result
    }

    final class Coordinator {
        weak var textView: NSTextView?
        var currentKey = ""
    }
}
