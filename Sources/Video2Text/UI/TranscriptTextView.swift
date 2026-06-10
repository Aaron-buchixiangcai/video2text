import AppKit
import SwiftUI

struct TranscriptTextView: NSViewRepresentable {
    let text: String

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
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        applyStyle(to: textView)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView ?? scrollView.documentView as? NSTextView else {
            return
        }
        applyStyle(to: textView)
        if context.coordinator.currentText != text {
            context.coordinator.currentText = text
            textView.string = text
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    private func applyStyle(to textView: NSTextView) {
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
    }

    final class Coordinator {
        weak var textView: NSTextView?
        var currentText = ""
    }
}
